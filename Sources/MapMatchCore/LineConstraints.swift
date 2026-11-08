import Foundation

/// A spot on the old map (`src`) that must land somewhere on a line in the target space: the line
/// through `point` with unit normal `normal`. Gives one equation (across the line) instead of a
/// point's two.
public struct LineConstraint: Sendable {
    public var src: Vec2
    public var point: Vec2
    public var normal: Vec2

    public init(src: Vec2, point: Vec2, normal: Vec2) {
        self.src = src; self.point = point; self.normal = normal
    }

    /// Signed distance of `p` from the line.
    public func offset(_ p: Vec2) -> Double { (p - point).x * normal.x + (p - point).y * normal.y }
}

/// Fitting with observations that each have a direction: a point pair gives two (x and y), a line
/// constraint one (across the line). The x and y components are modelled alike but are coupled
/// through the line observations, so they are solved together. With points only this gives exactly
/// the same result as fitting x and y separately.
struct Observation {
    var src: Vec2
    var dir: Vec2
    var value: Double
}

enum DirectionalFit {
    /// Observations, in normalised coordinates, grouped by the point or line they came from.
    static func observations(src: [Vec2], dst: [Vec2], lines: [LineConstraint], ns: Normalizer, nd: Normalizer)
        -> (obs: [Observation], groups: [[Int]]) {
        var obs: [Observation] = [], groups: [[Int]] = []
        for (s, d) in zip(src, dst) {
            let a = ns.forward(s), b = nd.forward(d)
            groups.append([obs.count, obs.count + 1])
            obs.append(Observation(src: a, dir: Vec2(1, 0), value: b.x))
            obs.append(Observation(src: a, dir: Vec2(0, 1), value: b.y))
        }
        for l in lines {
            let b = nd.forward(l.point)
            groups.append([obs.count])
            obs.append(Observation(src: ns.forward(l.src), dir: l.normal, value: l.normal.x * b.x + l.normal.y * b.y))
        }
        return (obs, groups)
    }

    // MARK: Stiff models (least squares)

    /// Design row for one observation; unknowns as in `SimilarityTransform` / `AffineTransform`.
    static func row(_ kind: TransformKind, _ o: Observation) -> [Double] {
        let (x, y, dx, dy) = (o.src.x, o.src.y, o.dir.x, o.dir.y)
        switch kind {
        case .similarity: return [dx * x + dy * y, -dx * y + dy * x, dx, dy]
        default: return [dx, dx * x, dx * y, dy, dy * x, dy * y]
        }
    }

    static func fitStiff(_ kind: TransformKind, _ obs: [Observation]) -> (any PlanarTransform)? {
        let k = kind == .similarity ? 4 : 6
        guard obs.count >= k else { return nil }
        let design = obs.flatMap { row(kind, $0) }
        guard let p = leastSquares(design: design, rows: obs.count, k: k, targets: obs.map(\.value), m: 1) else { return nil }
        return kind == .similarity ? SimilarityTransform(a: p[0], b: p[1], tx: p[2], ty: p[3]) as any PlanarTransform
            : AffineTransform(c: p) as any PlanarTransform
    }

    // MARK: Flexible models (bordered radial basis system)

    /// [[K̃ + diag·I, P̃], [P̃ᵀ, 0]] with K̃ₖₗ = (dₖ·dₗ) K(pₖ, pₗ) and P̃ₖ = dₖ ⊗ [1, x, y].
    static func system(_ obs: [Observation], kernel: RadialKernel, diag: Double) -> (A: [Double], B: [Double], size: Int) {
        let n = obs.count, size = n + 6
        var A = [Double](repeating: 0, count: size * size)
        var B = [Double](repeating: 0, count: size)
        for i in 0..<n {
            let oi = obs[i]
            for j in i..<n {
                let oj = obs[j]
                let dot = oi.dir.x * oj.dir.x + oi.dir.y * oj.dir.y
                guard dot != 0 else { continue }
                let d = oi.src - oj.src
                let v = dot * kernel.value(r2: d.x * d.x + d.y * d.y)
                A[i * size + j] = v; A[j * size + i] = v
            }
            A[i * size + i] += diag
            let p = [oi.dir.x, oi.dir.x * oi.src.x, oi.dir.x * oi.src.y, oi.dir.y, oi.dir.y * oi.src.x, oi.dir.y * oi.src.y]
            for c in 0..<6 { A[i * size + n + c] = p[c]; A[(n + c) * size + i] = p[c] }
            B[i] = oi.value
        }
        return (A, B, size)
    }

    static func fitRadial(_ obs: [Observation], kernel: RadialKernel, diag: Double) -> DirectionalRBF? {
        guard obs.count >= 6 else { return nil }
        let (A, B, size) = system(obs, kernel: kernel, diag: diag)
        guard let X = solveLinearSystem(A, B, n: size, rhsColumns: 1) else { return nil }
        let n = obs.count
        return DirectionalRBF(centers: obs.map(\.src), dirs: obs.map(\.dir), alpha: Array(X[0..<n]),
                              affine: Array(X[n..<(n + 6)]), kernel: kernel)
    }

    /// Leave-one-out residual of each group without refitting: (M⁻¹_GG)⁻¹ (M⁻¹b)_G, the block form of
    /// the single-observation formula. A point's residual is a vector; a line's is along its normal.
    static func leaveOneOutRadial(_ obs: [Observation], groups: [[Int]], kernel: RadialKernel, diag: Double) -> [Vec2]? {
        let (A, B, size) = system(obs, kernel: kernel, diag: diag)
        var I = [Double](repeating: 0, count: size * size)
        for i in 0..<size { I[i * size + i] = 1 }
        guard let inv = solveLinearSystem(A, I, n: size, rhsColumns: size) else { return nil }
        let n = obs.count
        var c = [Double](repeating: 0, count: n)
        for i in 0..<n { for k in 0..<n { c[i] += inv[i * size + k] * B[k] } }
        var out: [Vec2] = []
        for g in groups {
            if g.count == 1 {
                let d = inv[g[0] * size + g[0]]
                guard abs(d) > 1e-300 else { return nil }
                out.append(obs[g[0]].dir * (c[g[0]] / d))
            } else {
                let (i, j) = (g[0], g[1])
                let a = inv[i * size + i], b = inv[i * size + j], e = inv[j * size + i], d = inv[j * size + j]
                let det = a * d - b * e
                guard abs(det) > 1e-300 else { return nil }
                // Observations i and j are the x and y of one point.
                out.append(Vec2((d * c[i] - b * c[j]) / det, (-e * c[i] + a * c[j]) / det))
            }
        }
        return out
    }
}

/// Affine part plus kernels centred on each observation, each acting along its direction.
struct DirectionalRBF: PlanarTransform {
    let centers: [Vec2]
    let dirs: [Vec2]
    let alpha: [Double]
    let affine: [Double] // a0, ax, ay for x' then for y'
    let kernel: RadialKernel

    func apply(_ p: Vec2) -> Vec2 {
        var x = affine[0] + affine[1] * p.x + affine[2] * p.y
        var y = affine[3] + affine[4] * p.x + affine[5] * p.y
        for k in centers.indices {
            let dx = p.x - centers[k].x, dy = p.y - centers[k].y
            let w = alpha[k] * kernel.value(r2: dx * dx + dy * dy)
            x += w * dirs[k].x
            y += w * dirs[k].y
        }
        return Vec2(x, y)
    }
}
