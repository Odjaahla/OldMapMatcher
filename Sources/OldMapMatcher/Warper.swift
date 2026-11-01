import CoreGraphics
import MapKit
import MapMatchCore

/// A downsampled RGBA copy of the old map used as the source for warping.
struct SourceRaster: @unchecked Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt8] // premultiplied RGBA, row 0 = top of image
    /// Original image pixels per raster pixel.
    let factor: Double

    init(_ image: CGImage, maxDimension: Int) {
        let f = max(1, Double(max(image.width, image.height)) / Double(maxDimension))
        width = Int((Double(image.width) / f).rounded())
        height = Int((Double(image.height) / f).rounded())
        factor = f
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
}

/// The old map warped into Web Mercator so MapKit can draw it on top of the modern map.
final class WarpedImageOverlay: NSObject, MKOverlay, @unchecked Sendable {
    let image: CGImage
    let boundingMapRect: MKMapRect
    var coordinate: CLLocationCoordinate2D { MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate }

    init(image: CGImage, rect: MKMapRect) {
        self.image = image
        boundingMapRect = rect
    }
}

final class WarpedImageRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let o = overlay as? WarpedImageOverlay else { return }
        let r = rect(for: o.boundingMapRect)
        context.saveGState()
        context.interpolationQuality = .high
        // Map-point space has y growing southwards; flip so the image's top row lands at the north edge.
        context.translateBy(x: r.minX, y: r.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(o.image, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        context.restoreGState()
    }
}

enum Warper {
    static let maxOutputDimension = 4096
    static let gridStep = 8

    /// Resamples the old map onto a Web Mercator grid by inverse mapping:
    /// for each output pixel, ask the fitted model where it lies on the old map.
    /// The exact model is evaluated on a coarse grid and interpolated in between.
    static func warp(_ src: SourceRaster, imageSize: Vec2, geoRef: GeoReference) -> WarpedImageOverlay? {
        // Footprint: trace the image border onto the ground.
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
        // A footprint bigger than 100 km means the fit is nonsense (e.g. two points almost on top of each other).
        guard minX.isFinite, maxE - minE < 100_000, maxN - minN < 100_000, maxX > minX, maxY > minY else { return nil }
        let rect = MKMapRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        let aspect = rect.width / rect.height
        let longSide = min(maxOutputDimension, Int(Double(max(src.width, src.height)) * 1.5))
        let outW = aspect >= 1 ? longSide : max(1, Int(Double(longSide) * aspect))
        let outH = aspect >= 1 ? max(1, Int(Double(longSide) / aspect)) : longSide

        // Source raster coordinates at each grid node.
        let gw = outW / gridStep + 2, gh = outH / gridStep + 2
        var gx = [Float](repeating: 0, count: gw * gh)
        var gy = [Float](repeating: 0, count: gw * gh)
        for j in 0..<gh {
            for i in 0..<gw {
                let mp = MKMapPoint(x: rect.minX + Double(i * gridStep) / Double(outW) * rect.width,
                                    y: rect.minY + Double(j * gridStep) / Double(outH) * rect.height)
                let c = mp.coordinate
                let ip = geoRef.geoToImage(LatLon(lat: c.latitude, lon: c.longitude))
                gx[j * gw + i] = Float(ip.x / src.factor)
                gy[j * gw + i] = Float(ip.y / src.factor)
            }
        }

        var out = [UInt8](repeating: 0, count: outW * outH * 4)
        let sw = src.width, sh = src.height
        let step = Float(gridStep)
        src.pixels.withUnsafeBufferPointer { sp in
            out.withUnsafeMutableBufferPointer { op in
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
                        let u = sx - 0.5, v = sy - 0.5
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

        let data = Data(out) as CFData
        guard let provider = CGDataProvider(data: data),
              let cg = CGImage(width: outW, height: outH, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: outW * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return WarpedImageOverlay(image: cg, rect: rect)
    }
}
