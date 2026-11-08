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
        let t = try #require(TransformFitter.fit(.thinPlateSpline, src: src, dst: dst, parameters: .thinPlate(lambda: 0)))
        for (s, d) in zip(src, dst) { #expect((t.apply(s) - d).length < 1e-4) }
    }

    @Test func automaticSmoothingPrefersStiffModelForPureNoise() {
        let (src, dst) = syntheticPairs(noise: 5)
        guard case .thinPlate(let lambda) = TransformFitter.bestParameters(.thinPlateSpline, src: src, dst: dst) else {
            Issue.record("expected thin-plate parameters"); return
        }
        #expect(lambda >= 0.1)
    }

    @Test func leaveOneOutReflectsNoiseLevel() {
        let (src, dst) = syntheticPairs(noise: 3)
        let errs = TransformFitter.leaveOneOutErrors(.affine, src: src, dst: dst)!
        let rms = (errs.map { $0 * $0 }.reduce(0, +) / Double(errs.count)).squareRoot()
        #expect(rms > 1 && rms < 8) // uniform ±3 m noise per axis ≈ 2.4 m radial, a bit more out-of-sample
    }
}

@Suite struct LocalCorrectionTests {
    /// Random points (metres) mapped by an affine plus patch offsets: every point within a 1 km patch
    /// shares the same displacement, like a map compiled from separately surveyed pieces.
    /// About 5 points per patch, so each patch's offset can be learnt from its neighbours.
    func patchyPairs(noise: Double, patchOffset: Double, seed: UInt64 = 1, count: Int = 120) -> ([Vec2], [Vec2]) {
        var rng = SplitMix(seed: seed)
        var patches: [Int: Vec2] = [:]
        var src: [Vec2] = [], dst: [Vec2] = []
        for _ in 0..<count {
            let p = Vec2(rng.uniform(0, 6000), rng.uniform(0, 4000))
            let key = Int(p.x / 1000) * 100 + Int(p.y / 1000)
            let off = patches[key] ?? Vec2(rng.uniform(-patchOffset, patchOffset), rng.uniform(-patchOffset, patchOffset))
            patches[key] = off
            let n = Vec2(rng.uniform(-noise, noise), rng.uniform(-noise, noise))
            src.append(Vec2(p.x / 2, p.y / 2)) // "pixels" at 2 m/px
            dst.append(Vec2(670_000 + p.x * 0.999, 6_570_000 + p.y * 1.004) + off + n)
        }
        return (src, dst)
    }

    func rms(_ e: [Double]) -> Double { (e.map { $0 * $0 }.reduce(0, +) / Double(e.count)).squareRoot() }

    @Test(arguments: [ModelParameters.thinPlate(lambda: 0.05), .local(rangeMetres: 500, noiseRatio: 0.3)])
    func closedFormLeaveOneOutMatchesRefitting(_ p: ModelParameters) throws {
        let (src, dst) = patchyPairs(noise: 4, patchOffset: 20)
        let kind: TransformKind = if case .thinPlate = p { .thinPlateSpline } else { .localCorrection }
        let fast = try #require(TransformFitter.leaveOneOutErrors(kind, src: src, dst: dst, parameters: p, srcUnitsPerMetre: 0.5))
        // Brute force with the same normalisation as the closed form (fixed hyperparameters in normalised units).
        let ns = Normalizer(src), nd = Normalizer(dst)
        let s = src.map(ns.forward), d = dst.map(nd.forward)
        let kernel: RadialKernel, diag: Double
        switch p {
        case .thinPlate(let l): (kernel, diag) = (.thinPlate, l)
        case .local(let r, let q): (kernel, diag) = (.matern32(range: r * 0.5 / ns.scale), q * q)
        }
        for i in s.indices {
            var s2 = s, d2 = d
            s2.remove(at: i); d2.remove(at: i)
            let t = try #require(RadialBasisTransform.fit(s2, d2, kernel: kernel, diag: diag))
            let slow = (t.apply(s[i]) - d[i]).length * nd.scale
            #expect(abs(slow - fast[i]) < 1e-6 * max(1, slow))
        }
    }

    @Test func beatsAffineWhenErrorsComeInPatches() throws {
        let (src, dst) = patchyPairs(noise: 3, patchOffset: 25)
        let affine = rms(try #require(TransformFitter.leaveOneOutErrors(.affine, src: src, dst: dst)))
        let p = TransformFitter.bestParameters(.localCorrection, src: src, dst: dst, srcUnitsPerMetre: 0.5)
        let local = rms(try #require(TransformFitter.leaveOneOutErrors(.localCorrection, src: src, dst: dst, parameters: p,
                                                                        srcUnitsPerMetre: 0.5)))
        #expect(local < affine * 0.8)
        guard case .local(let range, _) = p else { Issue.record("expected local parameters"); return }
        #expect(range >= 250 && range <= 2000) // patches are 1 km across
    }

    @Test func pureNoiseIsNotTreatedAsLocalDisplacement() throws {
        let (src, dst) = patchyPairs(noise: 8, patchOffset: 0)
        let affine = rms(try #require(TransformFitter.leaveOneOutErrors(.affine, src: src, dst: dst)))
        let p = TransformFitter.bestParameters(.localCorrection, src: src, dst: dst, srcUnitsPerMetre: 0.5)
        let local = rms(try #require(TransformFitter.leaveOneOutErrors(.localCorrection, src: src, dst: dst, parameters: p,
                                                                        srcUnitsPerMetre: 0.5)))
        #expect(local < affine * 1.1) // no worse than affine to speak of
    }

    @Test func geoReferenceReportsRangeInMetres() throws {
        let (src, dst) = patchyPairs(noise: 3, patchOffset: 25)
        let points = zip(src, dst).map { ControlPoint(image: Vec2($0.x, -$0.y), geo: Sweref99TM.unproject(Vec2($1.x, $1.y))) }
        let g = try #require(GeoReference(points: points, kind: .localCorrection))
        guard case .local(let range, _) = g.parameters else { Issue.record("expected local parameters"); return }
        #expect(range >= 250 && range <= 2000)
        let back = g.geoToImage(g.imageToGeo(Vec2(1500, -1000)))
        #expect((back - Vec2(1500, -1000)).length < 1) // forward and inverse agree to within a pixel
    }

    @Test func kindNamesAreStableOnDisk() throws {
        let data = try JSONEncoder().encode([TransformKind.localCorrection, .thinPlateSpline])
        #expect(String(decoding: data, as: UTF8.self) == #"["localCorrection","thinPlateSpline"]"#)
    }
}

/// Small deterministic RNG so the statistical tests are reproducible.
@Suite struct UncertaintyTests {
    let local = LocalCorrectionTests()

    func points(_ src: [Vec2], _ dst: [Vec2]) -> [ControlPoint] {
        zip(src, dst).map { s, d in ControlPoint(image: Vec2(s.x, -s.y), geo: Sweref99TM.unproject(d)) }
    }

    @Test func matchesErrorsAtHeldOutPlaces() throws {
        // Fit on half the points; the predicted error at the other half should match the real error there.
        let (src, dst) = local.patchyPairs(noise: 3, patchOffset: 25, seed: 7, count: 240)
        let fitIdx = stride(from: 0, to: 240, by: 2).map { $0 }, testIdx = stride(from: 1, to: 240, by: 2).map { $0 }
        let fitPoints = points(fitIdx.map { src[$0] }, fitIdx.map { dst[$0] })
        let geo = try #require(GeoReference(points: fitPoints, kind: .localCorrection))
        let field = try #require(UncertaintyField(points: fitPoints))
        let actual = testIdx.map { (geo.imageToSweref(Vec2(src[$0].x, -src[$0].y)) - dst[$0]).length }
        let predicted = testIdx.map { field.rmsError(atSweref: dst[$0]) }
        let ratio = local.rms(actual) / local.rms(predicted)
        #expect(ratio > 0.6 && ratio < 1.6, "actual/predicted RMS = \(ratio)")
    }

    @Test func growsAwayFromThePoints() throws {
        let (src, dst) = local.patchyPairs(noise: 3, patchOffset: 25)
        let field = try #require(UncertaintyField(points: points(src, dst)))
        let inside = field.rmsError(atSweref: dst[0])
        let outside = field.rmsError(atSweref: Vec2(670_000 - 8000, 6_570_000 - 8000))
        #expect(outside > 2 * inside)
    }

    @Test func needsSixPoints() {
        let (src, dst) = local.patchyPairs(noise: 3, patchOffset: 25, count: 5)
        #expect(UncertaintyField(points: points(src, dst)) == nil)
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * Double(next() >> 11) / Double(1 << 53) }
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
