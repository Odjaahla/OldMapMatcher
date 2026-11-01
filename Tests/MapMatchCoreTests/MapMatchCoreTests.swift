import Foundation
import Testing
@testable import MapMatchCore

@Suite struct SwerefTests {
    @Test func centralMeridianOnEquatorIsFalseEasting() {
        let p = Sweref99TM.project(LatLon(lat: 0, lon: 15))
        #expect(abs(p.x - 500_000) < 1e-6)
        #expect(abs(p.y) < 1e-6)
    }

    @Test(arguments: [
        // Reference values from PROJ (pyproj, EPSG:4326 → EPSG:3006).
        (17.955, 59.285, 668330.8297, 6575520.7489),
        (12.0, 56.0, 312928.5609, 6210141.3267),
        (23.5, 67.9, 855933.5805, 7556235.1011),
    ])
    func matchesProj(lon: Double, lat: Double, e: Double, n: Double) {
        let p = Sweref99TM.project(LatLon(lat: lat, lon: lon))
        #expect(abs(p.x - e) < 0.001 && abs(p.y - n) < 0.001)
    }

    @Test func roundTripIsSubMillimetre() {
        for lat in stride(from: 55.0, through: 69.0, by: 1.7) {
            for lon in stride(from: 10.5, through: 24.5, by: 1.3) {
                let g = LatLon(lat: lat, lon: lon)
                let back = Sweref99TM.unproject(Sweref99TM.project(g))
                #expect(abs(back.lat - lat) < 1e-8 && abs(back.lon - lon) < 1e-8)
            }
        }
    }

    @Test func distancesNearStockholmAreMetric() {
        // 0.01° latitude ≈ 1113 m at 59°N; projected scale on easting ~674 km is ≈ 1.0017.
        let a = Sweref99TM.project(LatLon(lat: 59.28, lon: 17.95))
        let b = Sweref99TM.project(LatLon(lat: 59.29, lon: 17.95))
        let d = (b - a).length
        #expect(d > 1112 && d < 1118)
        #expect(a.y > 6_560_000 && a.y < 6_590_000)
        #expect(a.x > 660_000 && a.x < 680_000)
    }
}

@Suite struct TransformTests {
    // A synthetic "old map": rotated 10°, scaled, and stretched 2% in y — like shrunk paper drawn to magnetic north.
    func syntheticPairs(noise: Double = 0) -> ([Vec2], [Vec2]) {
        var rng = SystemRandomNumberGenerator()
        var src: [Vec2] = [], dst: [Vec2] = []
        let th = 10.0 * .pi / 180
        for i in 0..<6 {
            for j in 0..<6 {
                let p = Vec2(Double(i) * 1000 + 37, Double(j) * 900 + 11)
                let q = Vec2(p.x, p.y * 1.02)
                let r = Vec2(cos(th) * q.x - sin(th) * q.y, sin(th) * q.x + cos(th) * q.y) * 0.25
                let n = Vec2(Double.random(in: -noise...noise, using: &rng), Double.random(in: -noise...noise, using: &rng))
                src.append(p)
                dst.append(r + Vec2(670_000, 6_575_000) + n)
            }
        }
        return (src, dst)
    }

    @Test func similarityRecoversRotationAndScale() throws {
        let src = [Vec2(0, 0), Vec2(100, 0), Vec2(0, 100), Vec2(100, 100)]
        let th = 0.3
        let dst = src.map { Vec2(2 * (cos(th) * $0.x - sin(th) * $0.y) + 5, 2 * (sin(th) * $0.x + cos(th) * $0.y) - 7) }
        let t = try #require(TransformFitter.fit(.similarity, src: src, dst: dst))
        for (s, d) in zip(src, dst) { #expect((t.apply(s) - d).length < 1e-6) }
    }

    @Test func affineIsExactOnAffineData() throws {
        let (src, dst) = syntheticPairs()
        let t = try #require(TransformFitter.fit(.affine, src: src, dst: dst))
        for (s, d) in zip(src, dst) { #expect((t.apply(s) - d).length < 1e-5) }
        let sim = try #require(TransformFitter.fit(.similarity, src: src, dst: dst))
        let worst = zip(src, dst).map { (sim.apply($0) - $1).length }.max()!
        #expect(worst > 5) // the 2% stretch is not representable by a similarity
    }

    @Test func tpsInterpolatesExactlyWithoutSmoothing() throws {
        var (src, dst) = syntheticPairs()
        dst = dst.enumerated().map { i, p in p + Vec2(sin(Double(i)) * 20, cos(Double(i) * 0.7) * 20) }
        let t = try #require(TransformFitter.fit(.thinPlateSpline, src: src, dst: dst, lambda: 0))
        for (s, d) in zip(src, dst) { #expect((t.apply(s) - d).length < 1e-4) }
    }

    @Test func automaticSmoothingPrefersStiffModelForPureNoise() {
        let (src, dst) = syntheticPairs(noise: 5)
        let lambda = TransformFitter.bestSmoothing(src: src, dst: dst)
        #expect(lambda >= 0.1)
    }

    @Test func leaveOneOutReflectsNoiseLevel() {
        let (src, dst) = syntheticPairs(noise: 3)
        let errs = TransformFitter.leaveOneOutErrors(.affine, src: src, dst: dst)
        let rms = (errs.map { $0 * $0 }.reduce(0, +) / Double(errs.count)).squareRoot()
        #expect(rms > 1 && rms < 8) // uniform ±3 m noise per axis ≈ 2.4 m radial, a bit more out-of-sample
    }
}

@Suite struct GeoReferenceTests {
    @Test func imageAndGeoRoundTripAndNorth() throws {
        // Image north rotated 12° clockwise from true north, 0.5 m/px.
        let origin = Sweref99TM.project(LatLon(lat: 59.285, lon: 17.955))
        let th = -12.0 * .pi / 180
        func truth(_ px: Vec2) -> LatLon {
            let up = Vec2(px.x, -px.y) * 0.5
            let r = Vec2(cos(th) * up.x - sin(th) * up.y, sin(th) * up.x + cos(th) * up.y)
            return Sweref99TM.unproject(origin + r)
        }
        let pixels = [Vec2(100, 100), Vec2(4000, 300), Vec2(300, 3500), Vec2(3800, 3900), Vec2(2000, 2100)]
        let points = pixels.map { ControlPoint(image: $0, geo: truth($0)) }
        let g = try #require(GeoReference(points: points, kind: .similarity))
        #expect(g.rmsResidual < 0.01)
        #expect(abs(g.metresPerPixel(at: Vec2(2000, 2000)) - 0.5) < 1e-3)
        #expect(abs(g.northDeviationDegrees(at: Vec2(2000, 2000)) - 12) < 0.01)
        let back = g.geoToImage(g.imageToGeo(Vec2(1234, 2345)))
        #expect((back - Vec2(1234, 2345)).length < 1e-3)
    }

    @Test func disabledPointsAreIgnored() {
        let p = [ControlPoint(image: Vec2(0, 0), geo: LatLon(lat: 59.28, lon: 17.95)),
                 ControlPoint(image: Vec2(100, 0), geo: LatLon(lat: 59.28, lon: 17.96), enabled: false)]
        #expect(GeoReference(points: p, kind: .similarity) == nil)
    }
}
