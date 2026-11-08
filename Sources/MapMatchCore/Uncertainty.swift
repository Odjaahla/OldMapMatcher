import Foundation

/// How far off the fit is likely to be at any place on the ground: the kriging prediction error of
/// the map's displacement field, calibrated so it matches the leave-one-out errors of the points.
/// It is small near control points, grows between them and keeps growing outside the area they
/// cover (where the affine trend is extrapolated). Independent of which model is selected: it answers
/// "how well do the points pin the map down here?", which is what decides where new points help.
public struct UncertaintyField: Sendable {
    let norm: Normalizer          // ground coordinates → normalised
    let centers: [Vec2]           // control points, normalised
    let inverse: [Double]         // M⁻¹ of the bordered system, size × size
    let size: Int
    let kernel: RadialKernel
    let noise: Double             // nugget, as a share of the field variance
    let variance: Double          // per-component field variance, m²
    /// The automatically chosen correlation range and noise ratio.
    public let parameters: ModelParameters

    /// From a map's control points (disabled ones are ignored). Needs at least 6 enabled points.
    public init?(points allPoints: [ControlPoint]) {
        let points = allPoints.filter(\.enabled)
        let image = points.map { GeoReference.imageToPlane($0.image) }
        let ground = points.map { Sweref99TM.project($0.geo) }
        guard points.count >= 6 else { return nil }
        self.init(ground: ground, image: image, pixelsPerMetre: Normalizer(image).scale / Normalizer(ground).scale)
    }

    /// `ground`: control points in SWEREF metres; `image`: the same points on the old map (y up),
    /// in pixels; `pixelsPerMetre`: approximate map scale. Needs at least 6 points.
    public init?(ground: [Vec2], image: [Vec2], pixelsPerMetre: Double) {
        let n = ground.count
        guard n >= 6, image.count == n, pixelsPerMetre > 0 else { return nil }
        // Model where each ground position lands on the old map, in metres of map distance.
        let target = image.map { $0 * (1 / pixelsPerMetre) }
        guard let p = TransformFitter.bestParameters(.localCorrection, src: ground, dst: target),
              case .local(let range, let ratio) = p else { return nil }
        let ns = Normalizer(ground), nt = Normalizer(target)
        let c = ground.map(ns.forward), t = target.map(nt.forward)
        let kernel = RadialKernel.matern32(range: range / ns.scale)
        let noise = ratio * ratio
        let (A, B, size) = RadialBasisTransform.system(c, t, kernel: kernel, diag: noise)
        var I = [Double](repeating: 0, count: size * size)
        for i in 0..<size { I[i * size + i] = 1 }
        guard let inv = solveLinearSystem(A, I, n: size, rhsColumns: size) else { return nil }

        // Calibrate the variance: a left-out residual eᵢ has per-component variance σ²/(M⁻¹)ᵢᵢ,
        // so σ² is the average of |eᵢ|²/2 · (M⁻¹)ᵢᵢ.
        var sum = 0.0
        for i in 0..<n {
            var x = 0.0, y = 0.0
            for k in 0..<n { x += inv[i * size + k] * B[k * 2]; y += inv[i * size + k] * B[k * 2 + 1] }
            let d = inv[i * size + i]
            guard d > 0 else { return nil }
            let ex = x / d, ey = y / d
            sum += (ex * ex + ey * ey) / 2 * d
        }
        norm = ns; centers = c; inverse = inv; self.size = size; self.kernel = kernel; self.noise = noise
        variance = sum / Double(n) * nt.scale * nt.scale
        parameters = p
    }

    /// Expected error (radial RMS, metres) of a map feature's position at this ground point.
    public func rmsError(atSweref g: Vec2) -> Double {
        let q = norm.forward(g)
        let n = centers.count
        var v = [Double](repeating: 0, count: size)
        for i in 0..<n {
            let d = q - centers[i]
            v[i] = kernel.value(r2: d.x * d.x + d.y * d.y)
        }
        v[n] = 1; v[n + 1] = q.x; v[n + 2] = q.y
        // Universal kriging variance: k(0) + nugget − vᵀ M⁻¹ v.
        var quad = 0.0
        for i in 0..<size {
            var row = 0.0
            let base = i * size
            for j in 0..<size { row += inverse[base + j] * v[j] }
            quad += v[i] * row
        }
        let share = max(noise, 1 + noise - quad)
        return (2 * variance * share).squareRoot()
    }
}
