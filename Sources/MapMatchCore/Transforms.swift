import Foundation

/// A mapping between two planar coordinate systems.
public protocol PlanarTransform: Sendable {
    func apply(_ p: Vec2) -> Vec2
}

/// The kinds of model we can fit, from stiffest to most flexible.
public enum TransformKind: String, Codable, CaseIterable, Sendable {
    /// Scale, rotation, translation (4 parameters). Old maps' magnetic-north rotation and scale.
    case similarity
    /// Adds independent x/y scale and shear (6 parameters). Uneven paper shrinkage.
    case affine
    /// Affine plus smooth local bending (thin-plate spline), with automatic smoothing.
    case thinPlateSpline

    public var minimumPoints: Int {
        switch self {
        case .similarity: 2
        case .affine, .thinPlateSpline: 3
        }
    }

    public var displayName: String {
        switch self {
        case .similarity: "Similarity"
        case .affine: "Affine"
        case .thinPlateSpline: "Thin-plate spline"
        }
    }
}

/// Centres and scales a point set so fitting is well-conditioned regardless of units
/// (image pixels in the thousands, SWEREF coordinates in the millions).
struct Normalizer: Sendable {
    let center: Vec2
    let scale: Double

    init(_ points: [Vec2]) {
        let n = Double(max(points.count, 1))
        let c = Vec2(points.map(\.x).reduce(0, +) / n, points.map(\.y).reduce(0, +) / n)
        let rms = (points.map { ($0 - c).length * ($0 - c).length }.reduce(0, +) / n).squareRoot()
        center = c
        scale = rms > 0 ? rms : 1
    }

    func forward(_ p: Vec2) -> Vec2 { (p - center) * (1 / scale) }
    func inverse(_ p: Vec2) -> Vec2 { p * scale + center }
}

/// Wraps a transform fitted in normalised space.
struct NormalizedTransform<Inner: PlanarTransform>: PlanarTransform {
    let src: Normalizer
    let dst: Normalizer
    let inner: Inner
    func apply(_ p: Vec2) -> Vec2 { dst.inverse(inner.apply(src.forward(p))) }
}

/// x' = a·x − b·y + tx,  y' = b·x + a·y + ty
public struct SimilarityTransform: PlanarTransform {
    public let a, b, tx, ty: Double
    public func apply(_ p: Vec2) -> Vec2 { Vec2(a * p.x - b * p.y + tx, b * p.x + a * p.y + ty) }
    public var scale: Double { (a * a + b * b).squareRoot() }
    /// Counter-clockwise rotation in degrees.
    public var rotationDegrees: Double { atan2(b, a) * 180 / .pi }

    static func fit(_ src: [Vec2], _ dst: [Vec2]) -> SimilarityTransform? {
        guard src.count >= 2 else { return nil }
        var design: [Double] = [], targets: [Double] = []
        for (s, d) in zip(src, dst) {
            design += [s.x, -s.y, 1, 0]; targets.append(d.x)
            design += [s.y, s.x, 0, 1]; targets.append(d.y)
        }
        guard let p = leastSquares(design: design, rows: src.count * 2, k: 4, targets: targets, m: 1) else { return nil }
        return SimilarityTransform(a: p[0], b: p[1], tx: p[2], ty: p[3])
    }
}

/// x' = c0 + c1·x + c2·y,  y' = c3 + c4·x + c5·y
public struct AffineTransform: PlanarTransform {
    public let c: [Double]
    public func apply(_ p: Vec2) -> Vec2 {
        Vec2(c[0] + c[1] * p.x + c[2] * p.y, c[3] + c[4] * p.x + c[5] * p.y)
    }

    static func fit(_ src: [Vec2], _ dst: [Vec2]) -> AffineTransform? {
        guard src.count >= 3 else { return nil }
        var design: [Double] = [], targets: [Double] = []
        for (s, d) in zip(src, dst) {
            design += [1, s.x, s.y]
            targets += [d.x, d.y]
        }
        guard let p = leastSquares(design: design, rows: src.count, k: 3, targets: targets, m: 2) else { return nil }
        // p is 3×2: column 0 → x', column 1 → y'
        return AffineTransform(c: [p[0], p[2], p[4], p[1], p[3], p[5]])
    }
}

/// Thin-plate spline: an affine part plus radial basis terms that bend the map
/// smoothly through the control points. `lambda` > 0 relaxes exact interpolation,
/// which keeps a few bad points from crumpling the map.
public struct ThinPlateSpline: PlanarTransform {
    let centers: [Vec2]
    let weights: [Vec2]
    let affine: [Double] // a0, ax, ay for x' then for y'
    public let lambda: Double

    static func kernel(_ r2: Double) -> Double { r2 > 0 ? 0.5 * r2 * log(r2) : 0 } // r² log r

    public func apply(_ p: Vec2) -> Vec2 {
        var x = affine[0] + affine[1] * p.x + affine[2] * p.y
        var y = affine[3] + affine[4] * p.x + affine[5] * p.y
        for (c, w) in zip(centers, weights) {
            let dx = p.x - c.x, dy = p.y - c.y
            let u = ThinPlateSpline.kernel(dx * dx + dy * dy)
            x += w.x * u
            y += w.y * u
        }
        return Vec2(x, y)
    }

    static func fit(_ src: [Vec2], _ dst: [Vec2], lambda: Double) -> ThinPlateSpline? {
        let n = src.count
        guard n >= 3 else { return nil }
        let size = n + 3
        var A = [Double](repeating: 0, count: size * size)
        var B = [Double](repeating: 0, count: size * 2)
        for i in 0..<n {
            for j in 0..<n {
                let d = src[i] - src[j]
                A[i * size + j] = kernel(d.x * d.x + d.y * d.y)
            }
            A[i * size + i] += lambda
            A[i * size + n] = 1; A[i * size + n + 1] = src[i].x; A[i * size + n + 2] = src[i].y
            A[n * size + i] = 1; A[(n + 1) * size + i] = src[i].x; A[(n + 2) * size + i] = src[i].y
            B[i * 2] = dst[i].x; B[i * 2 + 1] = dst[i].y
        }
        guard let X = solveLinearSystem(A, B, n: size, rhsColumns: 2) else { return nil }
        let weights = (0..<n).map { Vec2(X[$0 * 2], X[$0 * 2 + 1]) }
        let affine = [X[n * 2], X[(n + 1) * 2], X[(n + 2) * 2],
                      X[n * 2 + 1], X[(n + 1) * 2 + 1], X[(n + 2) * 2 + 1]]
        return ThinPlateSpline(centers: src, weights: weights, affine: affine, lambda: lambda)
    }
}

public enum TransformFitter {
    /// Smoothing levels tried by automatic selection, in normalised units.
    /// 0 = exact interpolation; large values approach a plain affine fit.
    public static let smoothingCandidates: [Double] = [0, 1e-4, 1e-3, 1e-2, 3e-2, 0.1, 0.3, 1, 3, 10]

    /// Fits `kind` mapping src → dst. For thin-plate splines, `lambda` nil means "choose by
    /// leave-one-out cross-validation".
    public static func fit(_ kind: TransformKind, src: [Vec2], dst: [Vec2], lambda: Double? = nil) -> (any PlanarTransform)? {
        guard src.count == dst.count, src.count >= kind.minimumPoints else { return nil }
        let ns = Normalizer(src), nd = Normalizer(dst)
        let s = src.map(ns.forward), d = dst.map(nd.forward)
        switch kind {
        case .similarity:
            return SimilarityTransform.fit(s, d).map { NormalizedTransform(src: ns, dst: nd, inner: $0) }
        case .affine:
            return AffineTransform.fit(s, d).map { NormalizedTransform(src: ns, dst: nd, inner: $0) }
        case .thinPlateSpline:
            let chosen = lambda ?? bestSmoothing(src: src, dst: dst)
            return ThinPlateSpline.fit(s, d, lambda: chosen).map { NormalizedTransform(src: ns, dst: nd, inner: $0) }
        }
    }

    /// Picks the TPS smoothing that best predicts each held-out point.
    public static func bestSmoothing(src: [Vec2], dst: [Vec2]) -> Double {
        guard src.count >= 5 else { return 1 } // too few points to bend credibly: stay near-affine
        var best = (lambda: 1.0, error: Double.infinity)
        for lambda in smoothingCandidates {
            let errors = leaveOneOutErrors(.thinPlateSpline, src: src, dst: dst, lambda: lambda)
            guard errors.allSatisfy({ $0.isFinite }) else { continue }
            let rms = (errors.map { $0 * $0 }.reduce(0, +) / Double(errors.count)).squareRoot()
            if rms < best.error { best = (lambda, rms) }
        }
        return best.lambda
    }

    /// For each point, fit without it and measure how far off its prediction lands (in dst units).
    /// This is the honest accuracy estimate: residuals of the full fit are always optimistic.
    public static func leaveOneOutErrors(_ kind: TransformKind, src: [Vec2], dst: [Vec2], lambda: Double? = nil) -> [Double] {
        guard src.count > kind.minimumPoints else { return src.map { _ in .infinity } }
        return src.indices.map { i in
            var s = src, d = dst
            s.remove(at: i); d.remove(at: i)
            guard let t = fit(kind, src: s, dst: d, lambda: lambda ?? (kind == .thinPlateSpline ? 1 : nil)) else { return .infinity }
            return (t.apply(src[i]) - dst[i]).length
        }
    }
}
