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
    /// Affine plus corrections that only reach a limited distance from each point (kriging with a
    /// Matérn kernel). Suits maps compiled from many separately surveyed pieces, where errors are
    /// shared by nearby features but unrelated further away.
    case localCorrection
    /// Affine plus smooth bending of the whole sheet (thin-plate spline), with automatic smoothing.
    case thinPlateSpline

    public var minimumPoints: Int {
        switch self {
        case .similarity: 2
        case .affine, .localCorrection, .thinPlateSpline: 3
        }
    }

    public var displayName: String {
        switch self {
        case .similarity: "Similarity"
        case .affine: "Affine"
        case .localCorrection: "Affine + local correction"
        case .thinPlateSpline: "Thin-plate spline"
        }
    }

    var isFlexible: Bool { self == .localCorrection || self == .thinPlateSpline }
}

/// How closely the flexible models follow the points.
public enum Smoothing: String, Codable, CaseIterable, Sendable {
    /// Chosen by cross-validation: best at predicting points it wasn't fitted to, over the whole map.
    /// Tends to smooth over sharp local distortions that only a few points show.
    case automatic
    /// Passes within a few metres of every point, so features you've matched line up exactly. Costs a
    /// little in overall left-out error, and a wrong point bends the map around it.
    case followPoints

    public var displayName: String {
        switch self {
        case .automatic: "Automatic smoothing"
        case .followPoints: "Follow points closely"
        }
    }
}

/// Settings for the flexible models, normally chosen automatically by cross-validation.
public enum ModelParameters: Sendable, Equatable {
    /// Thin-plate smoothing in normalised units: 0 = exact interpolation, large ≈ affine.
    case thinPlate(lambda: Double)
    /// Local correction: how far (metres on the ground) a point's correction reaches, and how much of
    /// each point's error is treated as noise rather than real local displacement (noise / signal).
    case local(rangeMetres: Double, noiseRatio: Double)
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

/// Type-erased transform, so least-squares fits of either stiff kind can be wrapped alike.
struct AnyTransform: PlanarTransform {
    let base: any PlanarTransform
    init(_ base: any PlanarTransform) { self.base = base }
    func apply(_ p: Vec2) -> Vec2 { base.apply(p) }
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

/// Radial basis functions used by the flexible models.
enum RadialKernel: Sendable {
    /// r² log r: bends the whole sheet smoothly; influence never dies out.
    case thinPlate
    /// Matérn 3/2 correlation: influence fades over `range` (normalised units).
    case matern32(range: Double)

    @inline(__always) func value(r2: Double) -> Double {
        switch self {
        case .thinPlate:
            return r2 > 0 ? 0.5 * r2 * log(r2) : 0
        case .matern32(let range):
            let t = 3.0.squareRoot() * r2.squareRoot() / range
            return (1 + t) * exp(-t)
        }
    }
}

/// Affine part plus a weighted sum of radial kernels centred on the control points.
/// With the thin-plate kernel this is a thin-plate spline; with the Matérn kernel it is
/// universal kriging (affine drift + locally correlated corrections).
struct RadialBasisTransform: PlanarTransform {
    let centers: [Vec2]
    let weights: [Vec2]
    let affine: [Double] // a0, ax, ay for x' then for y'
    let kernel: RadialKernel

    func apply(_ p: Vec2) -> Vec2 {
        var x = affine[0] + affine[1] * p.x + affine[2] * p.y
        var y = affine[3] + affine[4] * p.x + affine[5] * p.y
        for (c, w) in zip(centers, weights) {
            let dx = p.x - c.x, dy = p.y - c.y
            let u = kernel.value(r2: dx * dx + dy * dy)
            x += w.x * u
            y += w.y * u
        }
        return Vec2(x, y)
    }

    /// The bordered system [[K + diag·I, P], [Pᵀ, 0]] and right-hand side [dst; 0].
    static func system(_ src: [Vec2], _ dst: [Vec2], kernel: RadialKernel, diag: Double) -> (A: [Double], B: [Double], size: Int) {
        let n = src.count
        let size = n + 3
        var A = [Double](repeating: 0, count: size * size)
        var B = [Double](repeating: 0, count: size * 2)
        for i in 0..<n {
            for j in i..<n {
                let d = src[i] - src[j]
                let k = kernel.value(r2: d.x * d.x + d.y * d.y)
                A[i * size + j] = k
                A[j * size + i] = k
            }
            A[i * size + i] += diag
            A[i * size + n] = 1; A[i * size + n + 1] = src[i].x; A[i * size + n + 2] = src[i].y
            A[n * size + i] = 1; A[(n + 1) * size + i] = src[i].x; A[(n + 2) * size + i] = src[i].y
            B[i * 2] = dst[i].x; B[i * 2 + 1] = dst[i].y
        }
        return (A, B, size)
    }

    static func fit(_ src: [Vec2], _ dst: [Vec2], kernel: RadialKernel, diag: Double) -> RadialBasisTransform? {
        let n = src.count
        guard n >= 3 else { return nil }
        let (A, B, size) = system(src, dst, kernel: kernel, diag: diag)
        guard let X = solveLinearSystem(A, B, n: size, rhsColumns: 2) else { return nil }
        let weights = (0..<n).map { Vec2(X[$0 * 2], X[$0 * 2 + 1]) }
        let affine = [X[n * 2], X[(n + 1) * 2], X[(n + 2) * 2],
                      X[n * 2 + 1], X[(n + 1) * 2 + 1], X[(n + 2) * 2 + 1]]
        return RadialBasisTransform(centers: src, weights: weights, affine: affine, kernel: kernel)
    }

    /// Leave-one-out residuals without refitting: for this bordered linear system the error at point i
    /// when it is left out equals (M⁻¹b)ᵢ / (M⁻¹)ᵢᵢ. One matrix inversion instead of n fits.
    static func leaveOneOutResiduals(_ src: [Vec2], _ dst: [Vec2], kernel: RadialKernel, diag: Double) -> [Vec2]? {
        let n = src.count
        guard n >= 4 else { return nil }
        let (A, B, size) = system(src, dst, kernel: kernel, diag: diag)
        var I = [Double](repeating: 0, count: size * size)
        for i in 0..<size { I[i * size + i] = 1 }
        guard let inv = solveLinearSystem(A, I, n: size, rhsColumns: size) else { return nil }
        var out: [Vec2] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            var x = 0.0, y = 0.0
            for k in 0..<n {
                x += inv[i * size + k] * B[k * 2]
                y += inv[i * size + k] * B[k * 2 + 1]
            }
            let d = inv[i * size + i]
            guard abs(d) > 1e-300 else { return nil }
            out.append(Vec2(x / d, y / d))
        }
        return out
    }
}

public enum TransformFitter {
    /// Thin-plate smoothing levels tried by automatic selection, in normalised units.
    static let thinPlateCandidates: [Double] = [0, 1e-4, 1e-3, 1e-2, 3e-2, 0.1, 0.3, 1, 3, 10]
    /// Local-correction ranges (metres) and noise/signal ratios tried by automatic selection.
    static let rangeCandidates: [Double] = [150, 250, 400, 600, 900, 1400, 2000, 3000]
    static let noiseRatioCandidates: [Double] = [0.1, 0.2, 0.35, 0.5, 0.75, 1, 1.5, 2.5]

    /// Defaults while there are too few points to choose by cross-validation: stay close to affine.
    static func defaultParameters(_ kind: TransformKind) -> ModelParameters? {
        switch kind {
        case .thinPlateSpline: .thinPlate(lambda: 1)
        case .localCorrection: .local(rangeMetres: 600, noiseRatio: 1)
        default: nil
        }
    }

    /// Fits `kind` mapping src → dst. For flexible models, `parameters` nil means "choose by
    /// leave-one-out cross-validation". `srcUnitsPerMetre` converts the local-correction range
    /// (given in ground metres) into source units, e.g. 1/(metres per pixel) for image coordinates.
    public static func fit(_ kind: TransformKind, src: [Vec2], dst: [Vec2], lines: [LineConstraint] = [],
                           parameters: ModelParameters? = nil, srcUnitsPerMetre: Double = 1) -> (any PlanarTransform)? {
        guard src.count == dst.count, src.count >= kind.minimumPoints else { return nil }
        if !lines.isEmpty {
            let ns = Normalizer(src + lines.map(\.src)), nd = Normalizer(dst + lines.map(\.point))
            let (obs, _) = DirectionalFit.observations(src: src, dst: dst, lines: lines, ns: ns, nd: nd)
            if !kind.isFlexible {
                return DirectionalFit.fitStiff(kind, obs).map { NormalizedTransform(src: ns, dst: nd, inner: AnyTransform($0)) }
            }
            let p = parameters ?? bestParameters(kind, src: src, dst: dst, lines: lines, srcUnitsPerMetre: srcUnitsPerMetre)
            guard let p else { return nil }
            let (kernel, diag) = radial(p, ns, srcUnitsPerMetre)
            return DirectionalFit.fitRadial(obs, kernel: kernel, diag: diag).map { NormalizedTransform(src: ns, dst: nd, inner: $0) }
        }
        let ns = Normalizer(src), nd = Normalizer(dst)
        let s = src.map(ns.forward), d = dst.map(nd.forward)
        switch kind {
        case .similarity:
            return SimilarityTransform.fit(s, d).map { NormalizedTransform(src: ns, dst: nd, inner: $0) }
        case .affine:
            return AffineTransform.fit(s, d).map { NormalizedTransform(src: ns, dst: nd, inner: $0) }
        case .localCorrection, .thinPlateSpline:
            let p = parameters ?? bestParameters(kind, src: src, dst: dst, srcUnitsPerMetre: srcUnitsPerMetre)
            guard let p else { return nil }
            let (kernel, diag) = radial(p, ns, srcUnitsPerMetre)
            return RadialBasisTransform.fit(s, d, kernel: kernel, diag: diag)
                .map { NormalizedTransform(src: ns, dst: nd, inner: $0) }
        }
    }

    private static func radial(_ p: ModelParameters, _ ns: Normalizer, _ srcUnitsPerMetre: Double) -> (RadialKernel, Double) {
        switch p {
        case .thinPlate(let lambda): (.thinPlate, lambda)
        case .local(let range, let ratio): (.matern32(range: range * srcUnitsPerMetre / ns.scale), ratio * ratio)
        }
    }

    /// Thin-plate smoothing and local-correction noise ratio used by `.followPoints`.
    static let followLambda = 0.001
    static let followNoiseRatio = 0.05

    /// Picks the parameters that best predict each held-out point. With `.followPoints` the smoothing
    /// is fixed low and only the local-correction reach is chosen.
    public static func bestParameters(_ kind: TransformKind, src: [Vec2], dst: [Vec2], lines: [LineConstraint] = [],
                                      srcUnitsPerMetre: Double = 1, smoothing: Smoothing = .automatic) -> ModelParameters? {
        guard kind.isFlexible else { return nil }
        if smoothing == .followPoints, kind == .thinPlateSpline { return .thinPlate(lambda: followLambda) }
        guard src.count >= 6 else { return defaultParameters(kind) } // too few to tell noise from real displacement
        let ratios = smoothing == .followPoints ? [followNoiseRatio] : noiseRatioCandidates
        let candidates: [ModelParameters] = kind == .thinPlateSpline
            ? thinPlateCandidates.map { .thinPlate(lambda: $0) }
            : rangeCandidates.flatMap { r in ratios.map { .local(rangeMetres: r, noiseRatio: $0) } }
        var best: (p: ModelParameters, error: Double)?
        for p in candidates {
            guard let e = leaveOneOutErrors(kind, src: src, dst: dst, lines: lines, parameters: p, srcUnitsPerMetre: srcUnitsPerMetre),
                  e.allSatisfy(\.isFinite) else { continue }
            let rms = (e.map { $0 * $0 }.reduce(0, +) / Double(e.count)).squareRoot()
            if rms < best?.error ?? .infinity { best = (p, rms) }
        }
        return best?.p ?? defaultParameters(kind)
    }

    /// For each point, the error (in dst units) when the model is fitted without it.
    /// This is the honest accuracy estimate: residuals of the full fit are always optimistic.
    /// Returns nil when there are too few points to leave one out.
    /// With `lines`, the result lists the points' errors and then the lines' (distance across the line).
    public static func leaveOneOutErrors(_ kind: TransformKind, src: [Vec2], dst: [Vec2], lines: [LineConstraint] = [],
                                         parameters: ModelParameters? = nil, srcUnitsPerMetre: Double = 1) -> [Double]? {
        guard src.count > kind.minimumPoints else { return nil }
        if !lines.isEmpty {
            if kind.isFlexible {
                guard let p = parameters ?? defaultParameters(kind) else { return nil }
                let ns = Normalizer(src + lines.map(\.src)), nd = Normalizer(dst + lines.map(\.point))
                let (obs, groups) = DirectionalFit.observations(src: src, dst: dst, lines: lines, ns: ns, nd: nd)
                let (kernel, diag) = radial(p, ns, srcUnitsPerMetre)
                return DirectionalFit.leaveOneOutRadial(obs, groups: groups, kernel: kernel, diag: diag)?.map { $0.length * nd.scale }
            }
            let pointErrors: [Double] = src.indices.map { i in
                var s = src, d = dst
                s.remove(at: i); d.remove(at: i)
                guard let t = fit(kind, src: s, dst: d, lines: lines) else { return .infinity }
                return (t.apply(src[i]) - dst[i]).length
            }
            let lineErrors: [Double] = lines.indices.map { i in
                var l = lines
                l.remove(at: i)
                guard let t = fit(kind, src: src, dst: dst, lines: l) else { return .infinity }
                return abs(lines[i].offset(t.apply(lines[i].src)))
            }
            return pointErrors + lineErrors
        }
        if kind.isFlexible {
            guard let p = parameters ?? defaultParameters(kind) else { return nil }
            let ns = Normalizer(src), nd = Normalizer(dst)
            let (kernel, diag) = radial(p, ns, srcUnitsPerMetre)
            return RadialBasisTransform.leaveOneOutResiduals(src.map(ns.forward), dst.map(nd.forward), kernel: kernel, diag: diag)?
                .map { $0.length * nd.scale }
        }
        return src.indices.map { i in
            var s = src, d = dst
            s.remove(at: i); d.remove(at: i)
            guard let t = fit(kind, src: s, dst: d) else { return .infinity }
            return (t.apply(src[i]) - dst[i]).length
        }
    }
}
