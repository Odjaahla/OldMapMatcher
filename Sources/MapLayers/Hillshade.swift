import CoreGraphics
import Foundation
import ImageIO
import MapKit

/// Today's bare ground, shaded as if lit from the north-west: Lantmäteriet's 1 m LiDAR terrain model
/// (no buildings or trees), served as elevation tiles by Mapterhorn. Old road beds, cuttings and
/// banks show up well. Tiles are shaded on the device; past the deepest level (~0.6 m) the
/// elevations are interpolated, so zooming in stays smooth.
public final class HillshadeTileOverlay: MKTileOverlay, @unchecked Sendable {
    public let dark: Bool
    /// Deepest level Mapterhorn has (512-pixel tiles).
    static let sourceMaxZoom = 16
    static let sourceSize = 512

    private static let elevations = NSCache<NSString, ElevationTile>()
    private static let shaded = NSCache<NSString, NSData>()

    public init(dark: Bool = false) {
        self.dark = dark
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
        maximumZ = 22
        Self.elevations.countLimit = 48
        Self.shaded.countLimit = 256
    }

    override public func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let key = "\(path.z)/\(path.x)/\(path.y)/\(dark)" as NSString
        if let png = Self.shaded.object(forKey: key) { result(png as Data, nil); return }
        // A 256-pixel tile at level z is a quarter of a 512-pixel source tile at z − 1.
        let s = max(0, min(path.z - 1, Self.sourceMaxZoom))
        let d = path.z - s
        let parent = (x: path.x >> d, y: path.y >> d)
        let dark = dark
        Self.elevation(z: s, x: parent.x, y: parent.y) { tile, error in
            guard let tile else { result(nil, error); return }
            let n = 1 << d
            let side = Double(Self.sourceSize) / Double(n)
            let origin = (Double(path.x & (n - 1)) * side, Double(path.y & (n - 1)) * side)
            let png = Self.shade(tile, origin: origin, side: side, z: path.z, y: path.y, dark: dark)
            if let png { Self.shaded.setObject(png as NSData, forKey: key) }
            result(png, nil)
        }
    }

    // MARK: Elevation tiles

    final class ElevationTile {
        let metres: [Float] // sourceSize², row 0 = north
        init(metres: [Float]) { self.metres = metres }

        /// Bilinear; extrapolated linearly past the edges, so slopes at tile seams stay right.
        func at(_ x: Double, _ y: Double) -> Float {
            let n = HillshadeTileOverlay.sourceSize
            let fx = x - 0.5, fy = y - 0.5
            let x0 = max(0, min(Int(fx.rounded(.down)), n - 2)), y0 = max(0, min(Int(fy.rounded(.down)), n - 2))
            let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
            let a = metres[y0 * n + x0], b = metres[y0 * n + x0 + 1]
            let c = metres[(y0 + 1) * n + x0], e = metres[(y0 + 1) * n + x0 + 1]
            return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + e * tx) * ty
        }
    }

    static func elevation(z: Int, x: Int, y: Int, done: @escaping (ElevationTile?, Error?) -> Void) {
        let key = "\(z)/\(x)/\(y)" as NSString
        if let t = elevations.object(forKey: key) { done(t, nil); return }
        var req = URLRequest(url: URL(string: "https://tiles.mapterhorn.com/\(z)/\(x)/\(y).webp")!)
        req.setValue("OldMapMatcher/0.1 (personal historical map research)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, error in
            guard let data, let tile = decode(data) else { done(nil, error); return }
            elevations.setObject(tile, forKey: key)
            done(tile, nil)
        }.resume()
    }

    /// Terrarium encoding: metres = R·256 + G + B/256 − 32768.
    static func decode(_ data: Data) -> ElevationTile? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              image.width == sourceSize, image.height == sourceSize else { return nil }
        let n = sourceSize
        var rgba = [UInt8](repeating: 0, count: n * n * 4)
        // Draw in the image's own colour space so the encoded values aren't colour-converted.
        let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let ok = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return nil }
        var metres = [Float](repeating: 0, count: n * n)
        for i in 0..<(n * n) {
            metres[i] = Float(rgba[i * 4]) * 256 + Float(rgba[i * 4 + 1]) + Float(rgba[i * 4 + 2]) / 256 - 32768
        }
        return ElevationTile(metres: metres)
    }

    // MARK: Shading

    static func shade(_ tile: ElevationTile, origin: (Double, Double), side: Double, z: Int, y: Int, dark: Bool) -> Data? {
        let size = 256
        let step = side / Double(size)
        // Ground size of an output pixel, at the tile's middle latitude.
        let n = Double(1 << z)
        let lat = atan(sinh(.pi * (1 - 2 * (Double(y) + 0.5) / n)))
        let metresPerPixel = 40_075_016.686 * cos(lat) / (n * Double(size))
        // Elevations with a one-pixel border, for the slopes at the edges.
        let w = size + 2
        var h = [Float](repeating: 0, count: w * w)
        for j in 0..<w {
            for i in 0..<w {
                h[j * w + i] = tile.at(origin.0 + (Double(i) - 0.5) * step, origin.1 + (Double(j) - 0.5) * step)
            }
        }
        // Exaggerated a little so low banks and road beds show.
        let k = 2.0 / (8 * metresPerPixel)
        let az = 315.0 * .pi / 180, alt = 45.0 * .pi / 180
        let (lx, ly, lz) = (sin(az) * cos(alt), cos(az) * cos(alt), sin(alt))
        var gray = [UInt8](repeating: 0, count: size * size)
        for j in 0..<size {
            for i in 0..<size {
                @inline(__always) func e(_ di: Int, _ dj: Int) -> Double { Double(h[(j + 1 + dj) * w + i + 1 + di]) }
                // Sobel slopes; east and north positive.
                let dzdx = ((e(1, -1) + 2 * e(1, 0) + e(1, 1)) - (e(-1, -1) + 2 * e(-1, 0) + e(-1, 1))) * k
                let dzdy = ((e(-1, -1) + 2 * e(0, -1) + e(1, -1)) - (e(-1, 1) + 2 * e(0, 1) + e(1, 1))) * k
                let len = (dzdx * dzdx + dzdy * dzdy + 1).squareRoot()
                let lit = max(0, (-dzdx * lx - dzdy * ly + lz) / len)
                let v = dark ? 0.05 + 0.5 * lit : 0.2 + 0.8 * lit
                gray[j * size + i] = UInt8(min(255, max(0, v * 255)))
            }
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData),
              let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let png = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? png as Data : nil
    }
}
