import Foundation

/// A point in a planar coordinate system. For SWEREF 99 TM, `x` is easting and `y` is northing (metres).
public struct Vec2: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public var length: Double { (x * x + y * y).squareRoot() }
}

/// Geographic coordinate in degrees (WGS84 / SWEREF 99 — identical at map precision).
public struct LatLon: Hashable, Codable, Sendable {
    public var lat: Double
    public var lon: Double
    public init(lat: Double, lon: Double) { self.lat = lat; self.lon = lon }
}

/// SWEREF 99 TM (EPSG:3006) using Lantmäteriet's Gauss–Krüger formulas.
/// All fitting is done in this metric system so residuals are in metres.
public enum Sweref99TM {
    private static let a = 6_378_137.0
    private static let f = 1.0 / 298.257222101
    private static let lon0 = 15.0 * .pi / 180
    private static let k0 = 0.9996
    private static let falseNorthing = 0.0
    private static let falseEasting = 500_000.0

    private static let e2 = f * (2 - f)
    private static let n = f / (2 - f)
    private static let aHat = a / (1 + n) * (1 + n * n / 4 + n * n * n * n / 64)

    public static func project(_ p: LatLon) -> Vec2 {
        let phi = p.lat * .pi / 180
        let lambda = p.lon * .pi / 180
        let A = e2
        let B = (5 * e2 * e2 - e2 * e2 * e2) / 6
        let C = (104 * pow(e2, 3) - 45 * pow(e2, 4)) / 120
        let D = (1237 * pow(e2, 4)) / 1260
        let s2 = sin(phi) * sin(phi)
        let phiStar = phi - sin(phi) * cos(phi) * (A + B * s2 + C * s2 * s2 + D * s2 * s2 * s2)
        let dLambda = lambda - lon0
        let xiP = atan(tan(phiStar) / cos(dLambda))
        let etaP = atanh(cos(phiStar) * sin(dLambda))
        let beta = [
            n / 2 - 2 * n * n / 3 + 5 * pow(n, 3) / 16 + 41 * pow(n, 4) / 180,
            13 * n * n / 48 - 3 * pow(n, 3) / 5 + 557 * pow(n, 4) / 1440,
            61 * pow(n, 3) / 240 - 103 * pow(n, 4) / 140,
            49561 * pow(n, 4) / 161280,
        ]
        var xi = xiP, eta = etaP
        for (i, b) in beta.enumerated() {
            let k = Double(2 * (i + 1))
            xi += b * sin(k * xiP) * cosh(k * etaP)
            eta += b * cos(k * xiP) * sinh(k * etaP)
        }
        let northing = k0 * aHat * xi + falseNorthing
        let easting = k0 * aHat * eta + falseEasting
        return Vec2(easting, northing)
    }

    public static func unproject(_ p: Vec2) -> LatLon {
        let xi = (p.y - falseNorthing) / (k0 * aHat)
        let eta = (p.x - falseEasting) / (k0 * aHat)
        let delta = [
            n / 2 - 2 * n * n / 3 + 37 * pow(n, 3) / 96 - pow(n, 4) / 360,
            n * n / 48 + pow(n, 3) / 15 - 437 * pow(n, 4) / 1440,
            17 * pow(n, 3) / 480 - 37 * pow(n, 4) / 840,
            4397 * pow(n, 4) / 161280,
        ]
        var xiP = xi, etaP = eta
        for (i, d) in delta.enumerated() {
            let k = Double(2 * (i + 1))
            xiP -= d * sin(k * xi) * cosh(k * eta)
            etaP -= d * cos(k * xi) * sinh(k * eta)
        }
        let phiStar = asin(sin(xiP) / cosh(etaP))
        let dLambda = atan(sinh(etaP) / cos(xiP))
        let As = e2 + e2 * e2 + pow(e2, 3) + pow(e2, 4)
        let Bs = -(7 * e2 * e2 + 17 * pow(e2, 3) + 30 * pow(e2, 4)) / 6
        let Cs = (224 * pow(e2, 3) + 889 * pow(e2, 4)) / 120
        let Ds = -(4279 * pow(e2, 4)) / 1260
        let s2 = sin(phiStar) * sin(phiStar)
        let phi = phiStar + sin(phiStar) * cos(phiStar) * (As + Bs * s2 + Cs * s2 * s2 + Ds * s2 * s2 * s2)
        return LatLon(lat: phi * 180 / .pi, lon: (lon0 + dLambda) * 180 / .pi)
    }
}
