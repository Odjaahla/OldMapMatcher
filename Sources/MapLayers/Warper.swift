import CoreGraphics
import Foundation
import ImageIO
import MapKit
import MapMatchCore

/// An RGBA copy of the old map (possibly downsampled) used as the source for warping.
public struct SourceRaster: @unchecked Sendable {
    public let width: Int
    public let height: Int
    let pixels: [UInt8] // premultiplied RGBA, row 0 = top of image
    /// Original image pixels per raster pixel.
    public let factor: Double

    public static let maxDimension = 4096

    /// `image` may be a downsampled thumbnail; `originalWidth` is the full image's width in pixels,
    /// which is the coordinate system control points use.
    public init(_ image: CGImage, originalWidth: Int, maxDimension: Int = SourceRaster.maxDimension) {
        let f = max(1, Double(max(image.width, image.height)) / Double(maxDimension))
        width = Int((Double(image.width) / f).rounded())
        height = Int((Double(image.height) / f).rounded())
        factor = Double(originalWidth) / Double(width)
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        let (w, h) = (width, height)
        buf.withUnsafeMutableBytes { ptr in
            let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        pixels = buf
    }

    private init(width: Int, height: Int, pixels: [UInt8], factor: Double) {
        self.width = width; self.height = height; self.pixels = pixels; self.factor = factor
    }

    /// Half the size in each direction, each pixel the average of a 2×2 block.
    func halved() -> SourceRaster {
        let w = max(1, width / 2), h = max(1, height / 2), sw = width
        var out = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<h {
                    let r0 = 2 * y * sw * 4, r1 = r0 + sw * 4
                    for x in 0..<w {
                        let a = r0 + 2 * x * 4, b = r1 + 2 * x * 4, d = (y * w + x) * 4
                        for c in 0..<4 {
                            let sum = Int(s[a + c]) + Int(s[a + 4 + c]) + Int(s[b + c]) + Int(s[b + 4 + c])
                            o[d + c] = UInt8((sum + 2) / 4)
                        }
                    }
                }
            }
        }
        return SourceRaster(width: w, height: h, pixels: out, factor: factor * Double(width) / Double(w))
    }

    /// Reads a downsampled copy of an image file without decoding it at full size.
    /// Returns the raster and the full image's size in pixels (the control points' coordinate system).
    public static func load(_ url: URL) -> (SourceRaster, Vec2)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        return (SourceRaster(thumb, originalWidth: w), Vec2(Double(w), Double(h)))
    }
}

/// The old map at full resolution plus successively halved copies, so tiles can be warped on demand
/// at any zoom without sampling far more source pixels than they show.
public final class SourcePyramid: @unchecked Sendable {
    public let levels: [SourceRaster]
    /// Full image size in pixels (the control points' coordinate system).
    public let imageSize: Vec2

    /// Full resolution is capped at this size to bound memory (≈1 GB at the cap).
    public static let maxDimension = 16384

    init(levels: [SourceRaster], imageSize: Vec2) {
        self.levels = levels
        self.imageSize = imageSize
    }

    public static func load(_ url: URL) -> SourcePyramid? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var levels = [SourceRaster(image, originalWidth: image.width, maxDimension: maxDimension)]
        while max(levels.last!.width, levels.last!.height) > 512 { levels.append(levels.last!.halved()) }
        return SourcePyramid(levels: levels, imageSize: Vec2(Double(image.width), Double(image.height)))
    }

    /// The smallest level that still has at least one source pixel per output pixel.
    func level(forSourcePixelsPerOutputPixel s: Double) -> SourceRaster {
        var best = levels[0]
        for l in levels where l.factor <= s { best = l }
        return best
    }
}

/// The old map warped into Web Mercator so MapKit can draw it on top of the modern map.
public final class WarpedImageOverlay: NSObject, MKOverlay, @unchecked Sendable {
    public let image: CGImage
    public let boundingMapRect: MKMapRect
    public var coordinate: CLLocationCoordinate2D { MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate }

    public init(image: CGImage, rect: MKMapRect) {
        self.image = image
        boundingMapRect = rect
    }
}

public final class WarpedImageRenderer: MKOverlayRenderer {
    override public func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let o = overlay as? WarpedImageOverlay else { return }
        Warper.drawFlipped(o.image, in: rect(for: o.boundingMapRect), context: context)
    }
}

/// The old map warped tile by tile as MapKit draws it, at the resolution of the screen.
public final class LiveWarpOverlay: NSObject, MKOverlay, @unchecked Sendable {
    public let source: SourcePyramid
    public let geoRef: GeoReference
    public let boundingMapRect: MKMapRect
    public var coordinate: CLLocationCoordinate2D { MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate }

    /// nil when the fit doesn't give a sensible footprint.
    public init?(source: SourcePyramid, geoRef: GeoReference) {
        guard let rect = Warper.footprint(imageSize: source.imageSize, geoRef: geoRef) else { return nil }
        self.source = source
        self.geoRef = geoRef
        boundingMapRect = rect
    }
}

public final class LiveWarpRenderer: MKOverlayRenderer {
    override public func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let o = overlay as? LiveWarpOverlay else { return }
        let tile = mapRect.intersection(o.boundingMapRect)
        guard !tile.isEmpty else { return }
        let r = rect(for: tile)
        let device = context.convertToDeviceSpace(r)
        let w = min(2048, max(1, Int(abs(device.width).rounded()))), h = min(2048, max(1, Int(abs(device.height).rounded())))
        guard let image = Warper.render(o.source, geoRef: o.geoRef, mapRect: tile, width: w, height: h) else { return }
        Warper.drawFlipped(image, in: r, context: context)
    }
}

public enum Warper {
    static let maxOutputDimension = 4096
    static let gridStep = 8

    /// The old map's outline traced onto the map, as a Web Mercator rectangle.
    /// nil when the fit is nonsense (e.g. two points almost on top of each other).
    static func footprint(imageSize: Vec2, geoRef: GeoReference) -> MKMapRect? {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        var minE = Double.infinity, maxE = -Double.infinity, minN = Double.infinity, maxN = -Double.infinity
        let steps = 32
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            for p in [Vec2(t * imageSize.x, 0), Vec2(t * imageSize.x, imageSize.y),
                      Vec2(0, t * imageSize.y), Vec2(imageSize.x, t * imageSize.y)] {
                let s = geoRef.imageToSweref(p)
                minE = min(minE, s.x); maxE = max(maxE, s.x); minN = min(minN, s.y); maxN = max(maxN, s.y)
                let g = Sweref99TM.unproject(s)
                let mp = MKMapPoint(CLLocationCoordinate2D(latitude: g.lat, longitude: g.lon))
                minX = min(minX, mp.x); maxX = max(maxX, mp.x); minY = min(minY, mp.y); maxY = max(maxY, mp.y)
            }
        }
        // A footprint bigger than 100 km means the fit is nonsense.
        guard minX.isFinite, maxE - minE < 100_000, maxN - minN < 100_000, maxX > minX, maxY > minY else { return nil }
        return MKMapRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Resamples the whole old map onto one Web Mercator image (used for the iPhone export).
    public static func warp(_ src: SourceRaster, imageSize: Vec2, geoRef: GeoReference) -> WarpedImageOverlay? {
        guard let rect = footprint(imageSize: imageSize, geoRef: geoRef) else { return nil }
        let aspect = rect.width / rect.height
        let longSide = min(maxOutputDimension, Int(Double(max(src.width, src.height)) * 1.5))
        let outW = aspect >= 1 ? longSide : max(1, Int(Double(longSide) * aspect))
        let outH = aspect >= 1 ? max(1, Int(Double(longSide) / aspect)) : longSide
        let grid = sourceGrid(rect, outW, outH, geoRef)
        return resample(src, grid, outW, outH).map { WarpedImageOverlay(image: $0, rect: rect) }
    }

    /// Warps one map tile, picking the pyramid level that matches the tile's resolution.
    static func render(_ source: SourcePyramid, geoRef: GeoReference, mapRect: MKMapRect, width: Int, height: Int) -> CGImage? {
        let grid = sourceGrid(mapRect, width, height, geoRef)
        // Original-image pixels per output pixel, from the grid spacing near the middle.
        let k = ((grid.height - 2) / 2) * grid.width + (grid.width - 2) / 2
        let dx = hypot(Double(grid.x[k + 1] - grid.x[k]), Double(grid.y[k + 1] - grid.y[k])) / Double(gridStep)
        let dy = hypot(Double(grid.x[k + grid.width] - grid.x[k]), Double(grid.y[k + grid.width] - grid.y[k])) / Double(gridStep)
        return resample(source.level(forSourcePixelsPerOutputPixel: min(dx, dy)), grid, width, height)
    }

    /// Where each grid node of the output falls on the old map, in original-image pixels.
    /// The exact model is evaluated every `gridStep` output pixels and interpolated in between.
    private struct Grid { let x: [Float], y: [Float], width: Int, height: Int }

    private static func sourceGrid(_ rect: MKMapRect, _ outW: Int, _ outH: Int, _ geoRef: GeoReference) -> Grid {
        let gw = outW / gridStep + 2, gh = outH / gridStep + 2
        var gx = [Float](repeating: 0, count: gw * gh)
        var gy = [Float](repeating: 0, count: gw * gh)
        for j in 0..<gh {
            for i in 0..<gw {
                let mp = MKMapPoint(x: rect.minX + Double(i * gridStep) / Double(outW) * rect.width,
                                    y: rect.minY + Double(j * gridStep) / Double(outH) * rect.height)
                let c = mp.coordinate
                let ip = geoRef.geoToImage(LatLon(lat: c.latitude, lon: c.longitude))
                gx[j * gw + i] = Float(ip.x)
                gy[j * gw + i] = Float(ip.y)
            }
        }
        return Grid(x: gx, y: gy, width: gw, height: gh)
    }

    /// Inverse mapping: for each output pixel, interpolate its source position from the grid and
    /// sample the source bilinearly. Pixels that fall outside the old map stay transparent.
    private static func resample(_ src: SourceRaster, _ grid: Grid, _ outW: Int, _ outH: Int) -> CGImage? {
        var out = [UInt8](repeating: 0, count: outW * outH * 4)
        let sw = src.width, sh = src.height, gw = grid.width
        let step = Float(gridStep), scale = Float(1 / src.factor)
        src.pixels.withUnsafeBufferPointer { sp in
            out.withUnsafeMutableBufferPointer { op in
                grid.x.withUnsafeBufferPointer { gx in
                    grid.y.withUnsafeBufferPointer { gy in
                        for y in 0..<outH {
                            let fy = Float(y) / step
                            let j0 = Int(fy), ty = fy - Float(j0)
                            for x in 0..<outW {
                                let fx = Float(x) / step
                                let i0 = Int(fx), tx = fx - Float(i0)
                                let k = j0 * gw + i0
                                let sx = (gx[k] * (1 - tx) + gx[k + 1] * tx) * (1 - ty) + (gx[k + gw] * (1 - tx) + gx[k + gw + 1] * tx) * ty
                                let sy = (gy[k] * (1 - tx) + gy[k + 1] * tx) * (1 - ty) + (gy[k + gw] * (1 - tx) + gy[k + gw + 1] * tx) * ty
                                // Bilinear sample of the source (pixel centres at +0.5).
                                let u = sx * scale - 0.5, v = sy * scale - 0.5
                                guard u >= 0, v >= 0, u < Float(sw - 1), v < Float(sh - 1) else { continue }
                                let x0 = Int(u), y0 = Int(v)
                                let ax = u - Float(x0), ay = v - Float(y0)
                                let p00 = (y0 * sw + x0) * 4, p10 = p00 + 4, p01 = p00 + sw * 4, p11 = p01 + 4
                                let o = (y * outW + x) * 4
                                for c in 0..<4 {
                                    let top = Float(sp[p00 + c]) * (1 - ax) + Float(sp[p10 + c]) * ax
                                    let bot = Float(sp[p01 + c]) * (1 - ax) + Float(sp[p11 + c]) * ax
                                    op[o + c] = UInt8(top * (1 - ay) + bot * ay + 0.5)
                                }
                            }
                        }
                    }
                }
            }
        }
        let data = Data(out) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: outW, height: outH, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: outW * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Map-point space has y growing southwards; flip so the image's top row lands at the north edge.
    static func drawFlipped(_ image: CGImage, in r: CGRect, context: CGContext) {
        context.saveGState()
        context.interpolationQuality = .high
        context.translateBy(x: r.minX, y: r.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        context.restoreGState()
    }
}

/// OpenStreetMap tiles with an identifying User-Agent, as the OSM tile policy asks.
public final class OSMTileOverlay: MKTileOverlay {
    public init() {
        super.init(urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
        canReplaceMapContent = true
        maximumZ = 19
    }

    override public func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        var req = URLRequest(url: url(forTilePath: path))
        req.setValue("OldMapMatcher/0.1 (personal historical map research)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, error in result(data, error) }.resume()
    }
}
