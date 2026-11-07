// Makes the app icons from one square artwork image.
// Usage: swift scripts/make_icons.swift <artwork.png>
//
// The artwork may come with its own rounded square on a white background. The script crops to that
// square and fills the white corners by extending the background gradient, giving full-bleed square
// art (Resources/icon-master.png). From that it writes:
//   - the iPhone icon (iOS masks the corners itself, so it must be full-bleed and opaque)
//   - the Mac icon: the art clipped to Apple's rounded shape at 824 of 1024 px with a soft shadow
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Bitmap {
    let size: Int
    var px: [UInt8] // RGBA, row 0 = top

    init(size: Int, drawing image: CGImage, from rect: CGRect) {
        self.size = size
        px = [UInt8](repeating: 0, count: size * size * 4)
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            // Place `rect` (top-left origin) of the image onto the whole bitmap.
            let s = Double(size) / rect.width
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: -rect.minX * s, y: (rect.maxY - Double(image.height)) * s,
                                       width: Double(image.width) * s, height: Double(image.height) * s))
        }
    }

    subscript(x: Int, y: Int, c: Int) -> UInt8 {
        get { px[(y * size + x) * 4 + c] }
        set { px[(y * size + x) * 4 + c] = newValue }
    }

    var image: CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        _ = px.withUnsafeBytes { memcpy(ctx.data!, $0.baseAddress!, $0.count) }
        return ctx.makeImage()!
    }
}

func load(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("Can't read \(path)") }
    return img
}

func writePNG(_ image: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Can't write \(path)") }
}

func resized(_ image: CGImage, to size: Int, alpha: Bool) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

// MARK: 1. Crop to the artwork's own rounded square

let input = load(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")
let probe = Bitmap(size: input.width, drawing: input, from: CGRect(x: 0, y: 0, width: input.width, height: input.width))
func isWhite(_ b: Bitmap, _ x: Int, _ y: Int) -> Bool { min(b[x, y, 0], b[x, y, 1], b[x, y, 2]) > 225 }
var lo = (x: probe.size, y: probe.size), hi = (x: 0, y: 0)
for y in 0..<probe.size { for x in 0..<probe.size where !isWhite(probe, x, y) {
    lo = (min(lo.x, x), min(lo.y, y)); hi = (max(hi.x, x), max(hi.y, y))
} }
// Trim 3 px so the square's soft outline doesn't end up as a light line along the edges.
let side = Double(max(hi.x - lo.x, hi.y - lo.y) + 1) - 6
let crop = CGRect(x: Double(lo.x + hi.x + 1) / 2 - side / 2, y: Double(lo.y + hi.y + 1) / 2 - side / 2, width: side, height: side)
print("Artwork square: \(crop.integral) in a \(input.width)×\(input.height) image")

let N = 1024
var art = Bitmap(size: N, drawing: input, from: crop)

// MARK: 2. Fill the white corners from the background gradient

// The outside is the white region connected to the bitmap's corners.
var dist = [Int](repeating: Int.max / 2, count: N * N)
var stack = [(0, 0), (N - 1, 0), (0, N - 1), (N - 1, N - 1)].filter { isWhite(art, $0.0, $0.1) }
for (x, y) in stack { dist[y * N + x] = 0 }
while let (x, y) = stack.popLast() {
    for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)] where nx >= 0 && ny >= 0 && nx < N && ny < N {
        if dist[ny * N + nx] != 0 && isWhite(art, nx, ny) { dist[ny * N + nx] = 0; stack.append((nx, ny)) }
    }
}
// Chamfer distance (in pixels, approximately Euclidean) from the outside.
for y in 0..<N { for x in 0..<N {
    var d = dist[y * N + x]
    if x > 0 { d = min(d, dist[y * N + x - 1] + 10) }
    if y > 0 { d = min(d, dist[(y - 1) * N + x] + 10) }
    if x > 0 && y > 0 { d = min(d, dist[(y - 1) * N + x - 1] + 14) }
    if x < N - 1 && y > 0 { d = min(d, dist[(y - 1) * N + x + 1] + 14) }
    dist[y * N + x] = d
} }
for y in stride(from: N - 1, through: 0, by: -1) { for x in stride(from: N - 1, through: 0, by: -1) {
    var d = dist[y * N + x]
    if x < N - 1 { d = min(d, dist[y * N + x + 1] + 10) }
    if y < N - 1 { d = min(d, dist[(y + 1) * N + x] + 10) }
    if x < N - 1 && y < N - 1 { d = min(d, dist[(y + 1) * N + x + 1] + 14) }
    if x > 0 && y < N - 1 { d = min(d, dist[(y + 1) * N + x - 1] + 14) }
    dist[y * N + x] = d
} }

// Fit each colour channel as a cubic in (x, y) to a band of background just inside the edge.
// Distances in tenths of a pixel. The artwork has a ~10 px glossy rim inside its edge; fill past it.
let fillWithin = 120, blendTo = 200, bandTo = 450
func terms(_ x: Int, _ y: Int) -> [Double] {
    let u = Double(x) / Double(N) - 0.5, v = Double(y) / Double(N) - 0.5
    return [1, u, v, u * u, u * v, v * v, u * u * u, u * u * v, u * v * v, v * v * v]
}
let T = 10
var ata = [Double](repeating: 0, count: T * T), atb = [[Double]](repeating: [Double](repeating: 0, count: T), count: 3)
var samples = 0
for y in stride(from: 0, to: N, by: 2) { for x in stride(from: 0, to: N, by: 2) {
    let d = dist[y * N + x]
    guard d > blendTo, d <= bandTo, dist[y * N + x] < Int.max / 4 else { continue }
    let r = Double(art[x, y, 0]), g = Double(art[x, y, 1]), b = Double(art[x, y, 2])
    guard b > r + 60 else { continue } // background is blue-teal; skip any artwork
    let t = terms(x, y)
    for i in 0..<T { for j in 0..<T { ata[i * T + j] += t[i] * t[j] }; atb[0][i] += t[i] * r; atb[1][i] += t[i] * g; atb[2][i] += t[i] * b }
    samples += 1
} }
func solve(_ a: [Double], _ b: [Double]) -> [Double] {
    var m = a, v = b
    for c in 0..<T {
        let p = (c..<T).max { abs(m[$0 * T + c]) < abs(m[$1 * T + c]) }!
        for k in 0..<T { m.swapAt(c * T + k, p * T + k) }; v.swapAt(c, p)
        for r in 0..<T where r != c {
            let f = m[r * T + c] / m[c * T + c]
            for k in 0..<T { m[r * T + k] -= f * m[c * T + k] }; v[r] -= f * v[c]
        }
    }
    return (0..<T).map { v[$0] / m[$0 * T + $0] }
}
let coef = (0..<3).map { solve(ata, atb[$0]) }
func model(_ x: Int, _ y: Int, _ c: Int) -> Double { zip(terms(x, y), coef[c]).reduce(0) { $0 + $1.0 * $1.1 } }

var sq = 0.0, filled = 0
for y in stride(from: 0, to: N, by: 2) { for x in stride(from: 0, to: N, by: 2) where dist[y * N + x] > blendTo && dist[y * N + x] <= bandTo {
    if Double(art[x, y, 2]) > Double(art[x, y, 0]) + 60 { for c in 0..<3 { let e = model(x, y, c) - Double(art[x, y, c]); sq += e * e } }
} }
print("Background fit on \(samples) samples: RMS \(String(format: "%.1f", (sq / Double(3 * samples)).squareRoot())) levels")

for y in 0..<N { for x in 0..<N {
    let d = dist[y * N + x]
    guard d <= blendTo else { continue }
    let w = d <= fillWithin ? 1 : Double(blendTo - d) / Double(blendTo - fillWithin)
    for c in 0..<3 { art[x, y, c] = UInt8(max(0, min(255, (model(x, y, c) * w + Double(art[x, y, c]) * (1 - w)).rounded()))) }
    art[x, y, 3] = 255
    filled += 1
} }
print("Filled \(filled) corner and edge pixels")

let master = art.image
writePNG(master, "Resources/icon-master.png")

// MARK: 3. iPhone: full-bleed and opaque

let iosDir = "iOS/Resources/Assets.xcassets/AppIcon.appiconset"
writePNG(resized(master, to: 1024, alpha: false), "\(iosDir)/AppIcon.png")
try! """
{
  "images" : [ { "filename" : "AppIcon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""".write(toFile: "\(iosDir)/Contents.json", atomically: true, encoding: .utf8)
try! #"{ "info" : { "author" : "xcode", "version" : 1 } }"#
    .write(toFile: "iOS/Resources/Assets.xcassets/Contents.json", atomically: true, encoding: .utf8)

// MARK: 4. Mac: Apple's icon grid, a superellipse body of 824 px centred on 1024 px, with shadow

func superellipse(in r: CGRect, n: Double = 5) -> CGPath {
    let path = CGMutablePath()
    for i in 0...720 {
        let t = Double(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = r.midX + r.width / 2 * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = r.midY + r.height / 2 * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}
let mac = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 1024 * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = superellipse(in: body)
mac.saveGState()
mac.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
mac.addPath(shape); mac.setFillColor(CGColor(gray: 0.5, alpha: 1)); mac.fillPath()
mac.restoreGState()
mac.addPath(shape); mac.clip()
mac.interpolationQuality = .high
mac.draw(master, in: body)
let macIcon = mac.makeImage()!

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for s in [16, 32, 128, 256, 512] {
    writePNG(resized(macIcon, to: s, alpha: true), iconset.appendingPathComponent("icon_\(s)x\(s).png").path)
    writePNG(resized(macIcon, to: s * 2, alpha: true), iconset.appendingPathComponent("icon_\(s)x\(s)@2x.png").path)
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", "-o", "Resources/AppIcon.icns", iconset.path]
try! p.run(); p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
writePNG(macIcon, FileManager.default.temporaryDirectory.appendingPathComponent("mac-icon-preview.png").path)
print("Wrote Resources/icon-master.png, Resources/AppIcon.icns and \(iosDir)")
