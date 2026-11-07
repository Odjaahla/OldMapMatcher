import Foundation

/// A feature identified on both the old map (image pixels, origin top-left, y down)
/// and the modern world (lat/lon).
public struct ControlPoint: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var image: Vec2
    public var geo: LatLon
    /// Disabled points are kept but excluded from fitting (e.g. suspected misidentifications).
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String = "", image: Vec2, geo: LatLon, enabled: Bool = true) {
        self.id = id; self.name = name; self.image = image; self.geo = geo; self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey { case id, name, image, geo, enabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        image = try c.decode(Vec2.self, forKey: .image)
        geo = try c.decode(LatLon.self, forKey: .geo)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// Per-point diagnostics, all in metres on the ground.
public struct PointDiagnostics: Sendable {
    /// Distance between where the point was clicked on the modern map and where the fitted
    /// model puts it. Small by construction for flexible models.
    public let residual: Double
    /// Residual direction (east, north) in metres; plotted as arrows to reveal systematic warping.
    public let residualVector: Vec2
    /// Error when the point is left out of the fit — the honest accuracy estimate.
    public let leaveOneOut: Double
}

/// A fitted relationship between one old map image and the ground (SWEREF 99 TM).
public struct GeoReference: Sendable {
    public let kind: TransformKind
    /// Automatically chosen settings of the flexible models (nil for similarity/affine).
    public let parameters: ModelParameters?
    let forwardT: any PlanarTransform // image (y-up) → SWEREF
    let inverseT: any PlanarTransform // SWEREF → image (y-up)
    public let diagnostics: [UUID: PointDiagnostics]

    /// Image coordinates are flipped to y-up so that a similarity transform is a pure
    /// rotation + scale (no mirror) between the map and the ground.
    static func imageToPlane(_ p: Vec2) -> Vec2 { Vec2(p.x, -p.y) }
    static func planeToImage(_ p: Vec2) -> Vec2 { Vec2(p.x, -p.y) }

    public init?(points allPoints: [ControlPoint], kind: TransformKind) {
        let points = allPoints.filter(\.enabled)
        guard points.count >= kind.minimumPoints else { return nil }
        let src = points.map { GeoReference.imageToPlane($0.image) }
        let dst = points.map { Sweref99TM.project($0.geo) }

        // Approximate ground scale, so local-correction ranges can be given in metres in both directions.
        let pixelsPerMetre = Normalizer(src).scale / Normalizer(dst).scale
        let parameters = TransformFitter.bestParameters(kind, src: src, dst: dst, srcUnitsPerMetre: pixelsPerMetre)
        guard let f = TransformFitter.fit(kind, src: src, dst: dst, parameters: parameters, srcUnitsPerMetre: pixelsPerMetre),
              let i = TransformFitter.fit(kind, src: dst, dst: src, parameters: parameters, srcUnitsPerMetre: 1)
        else { return nil }
        self.kind = kind
        self.parameters = parameters
        forwardT = f
        inverseT = i

        let loo = TransformFitter.leaveOneOutErrors(kind, src: src, dst: dst, parameters: parameters, srcUnitsPerMetre: pixelsPerMetre)
        var diag: [UUID: PointDiagnostics] = [:]
        for (k, p) in points.enumerated() {
            let v = f.apply(src[k]) - dst[k]
            diag[p.id] = PointDiagnostics(residual: v.length, residualVector: v, leaveOneOut: loo?[k] ?? .infinity)
        }
        diagnostics = diag
    }

    public func imageToSweref(_ p: Vec2) -> Vec2 { forwardT.apply(GeoReference.imageToPlane(p)) }
    public func swerefToImage(_ p: Vec2) -> Vec2 { GeoReference.planeToImage(inverseT.apply(p)) }
    public func imageToGeo(_ p: Vec2) -> LatLon { Sweref99TM.unproject(imageToSweref(p)) }
    public func geoToImage(_ g: LatLon) -> Vec2 { swerefToImage(Sweref99TM.project(g)) }

    public var rmsResidual: Double { Self.rms(diagnostics.values.map(\.residual)) }
    /// nil when there are too few points to leave one out.
    public var rmsLeaveOneOut: Double? {
        let v = diagnostics.values.map(\.leaveOneOut)
        return v.allSatisfy(\.isFinite) && !v.isEmpty ? Self.rms(v) : nil
    }

    /// Ground metres per image pixel near the given image point (averaged over x and y).
    public func metresPerPixel(at p: Vec2) -> Double {
        let o = imageToSweref(p)
        let dx = (imageToSweref(p + Vec2(1, 0)) - o).length
        let dy = (imageToSweref(p + Vec2(0, 1)) - o).length
        return (dx + dy) / 2
    }

    /// Angle (degrees, clockwise) between the image's "up" and true north near the given point.
    /// For many 18th–19th century maps this reflects magnetic declination at survey time.
    public func northDeviationDegrees(at p: Vec2) -> Double {
        let up = imageToSweref(p + Vec2(0, -1)) - imageToSweref(p)
        return atan2(up.x, up.y) * 180 / .pi
    }

    static func rms(_ v: [Double]) -> Double {
        v.isEmpty ? 0 : (v.map { $0 * $0 }.reduce(0, +) / Double(v.count)).squareRoot()
    }
}
