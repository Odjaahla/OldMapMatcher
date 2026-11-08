import Foundation
import ImageIO
import MapKit
import MapMatchCore

/// One map's tiles (standard z/x/y Web Mercator tiles, 256 px) in a single file, so iCloud syncs one
/// file instead of thousands. Layout, little-endian:
///   "OMT1", UInt32 count, then count × (UInt8 z, UInt32 x, UInt32 y, UInt64 offset, UInt32 length),
///   then the tile images (HEIC with transparency). Tiles that would be empty are left out.
public enum TilePack {
    static let magic = Array("OMT1".utf8)
    static let entrySize = 1 + 4 + 4 + 8 + 4

    public struct Key: Hashable, Sendable {
        public let z: Int, x: Int, y: Int
        public init(z: Int, x: Int, y: Int) { self.z = z; self.x = x; self.y = y }
    }

    public static func write(_ tiles: [(Key, Data)], to url: URL) throws {
        var header = Data(magic)
        header.appendLE(UInt32(tiles.count))
        var offset = UInt64(magic.count + 4 + tiles.count * entrySize)
        for (k, d) in tiles {
            header.append(UInt8(k.z)); header.appendLE(UInt32(k.x)); header.appendLE(UInt32(k.y))
            header.appendLE(offset); header.appendLE(UInt32(d.count))
            offset += UInt64(d.count)
        }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tiles")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let h = try FileHandle(forWritingTo: tmp)
        try h.write(contentsOf: header)
        for (_, d) in tiles { try h.write(contentsOf: d) }
        try h.close()
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    /// Reads tiles on demand; safe to use from MapKit's tile-loading threads.
    public final class Reader: @unchecked Sendable {
        let fd: Int32
        let index: [Key: (offset: UInt64, length: Int)]

        public init?(url: URL) {
            let fd = open(url.path, O_RDONLY)
            guard fd >= 0 else { return nil }
            func read(_ n: Int, at off: UInt64) -> Data? {
                var buf = Data(count: n)
                let got = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, n, off_t(off)) }
                return got == n ? buf : nil
            }
            guard let head = read(8, at: 0), Array(head.prefix(4)) == TilePack.magic else { close(fd); return nil }
            let count = Int(head.readLE(UInt32.self, at: 4))
            guard let table = read(count * TilePack.entrySize, at: 8) else { close(fd); return nil }
            var index: [Key: (UInt64, Int)] = [:]
            index.reserveCapacity(count)
            for i in 0..<count {
                let b = i * TilePack.entrySize
                let k = Key(z: Int(table[table.startIndex + b]), x: Int(table.readLE(UInt32.self, at: b + 1)),
                            y: Int(table.readLE(UInt32.self, at: b + 5)))
                index[k] = (table.readLE(UInt64.self, at: b + 9), Int(table.readLE(UInt32.self, at: b + 17)))
            }
            self.fd = fd
            self.index = index
        }

        deinit { close(fd) }

        public func tile(_ k: Key) -> Data? {
            guard let e = index[k] else { return nil }
            var buf = Data(count: e.length)
            let got = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, e.length, off_t(e.offset)) }
            return got == e.length ? buf : nil
        }
    }
}

/// Draws a map from its tile pack. Areas without tiles (outside the old map) stay transparent.
/// Past the pack's deepest level, the matching part of a deepest tile is enlarged: the scan has no
/// more detail to show, but the map stays visible however far you zoom in.
public final class PackedTileOverlay: MKTileOverlay, @unchecked Sendable {
    let reader: TilePack.Reader
    let bounds: MKMapRect
    let packMaxZoom: Int

    public init(reader: TilePack.Reader, minZoom: Int, maxZoom: Int, bounds: MKMapRect) {
        self.reader = reader
        self.bounds = bounds
        packMaxZoom = maxZoom
        super.init(urlTemplate: nil)
        minimumZ = minZoom
        maximumZ = 22
        canReplaceMapContent = false
    }

    override public var boundingMapRect: MKMapRect { bounds }

    override public func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        if path.z <= packMaxZoom {
            result(reader.tile(TilePack.Key(z: path.z, x: path.x, y: path.y)) ?? Data(), nil)
            return
        }
        let shift = path.z - packMaxZoom
        let parent = TilePack.Key(z: packMaxZoom, x: path.x >> shift, y: path.y >> shift)
        guard let data = reader.tile(parent) else { result(Data(), nil); return }
        result(Self.enlarge(data, part: (path.x & ((1 << shift) - 1), path.y & ((1 << shift) - 1)), of: 1 << shift), nil)
    }

    /// The `part` of an `of`×`of` grid over the tile, scaled up to a full tile.
    static func enlarge(_ data: Data, part: (Int, Int), of n: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let side = Double(image.width) / Double(n)
        guard let crop = image.cropping(to: CGRect(x: Double(part.0) * side, y: Double(part.1) * side, width: side, height: side))
        else { return nil }
        let size = TileMaker.tileSize
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let out = ctx.makeImage() else { return nil }
        let png = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, out, nil)
        return CGImageDestinationFinalize(dest) ? png as Data : nil
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    func readLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var v: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &v) { copyBytes(to: $0, from: (startIndex + offset)..<(startIndex + offset + MemoryLayout<T>.size)) }
        return T(littleEndian: v)
    }
}

public enum TileMaker {
    public static let tileSize = 256

    /// Deepest zoom level: the first whose pixels are at least as fine as the old map's own.
    public static func maxZoom(geoRef: GeoReference, imageSize: Vec2) -> Int {
        let centre = imageSize * 0.5
        let mpp = geoRef.metresPerPixel(at: centre)
        let lat = geoRef.imageToGeo(centre).lat
        let z = log2(156_543.033_92 * cos(lat * .pi / 180) / max(mpp, 0.05))
        return min(19, max(10, Int(z.rounded(.up))))
    }

    /// Renders all tiles from `minZoom` (whole map in a tile or two) to the map's own resolution.
    /// `progress` gets the share done, from any thread.
    public static func make(source: SourcePyramid, geoRef: GeoReference, quality: Double = 0.7,
                            progress: (@Sendable (Double) -> Void)? = nil)
        -> (tiles: [(TilePack.Key, Data)], minZoom: Int, maxZoom: Int, bounds: MKMapRect)? {
        guard let rect = Warper.footprint(imageSize: source.imageSize, geoRef: geoRef) else { return nil }
        let zMax = maxZoom(geoRef: geoRef, imageSize: source.imageSize)
        let world = MKMapSize.world.width
        // Coarsest level: the map spans at most two tiles.
        var zMin = zMax
        while zMin > 0, max(rect.width, rect.height) > 2 * world / pow(2, Double(zMin)) { zMin -= 1 }
        var keys: [TilePack.Key] = []
        for z in zMin...zMax {
            let ts = world / pow(2, Double(z))
            for y in Int(rect.minY / ts)...Int(rect.maxY / ts) {
                for x in Int(rect.minX / ts)...Int(rect.maxX / ts) { keys.append(.init(z: z, x: x, y: y)) }
            }
        }
        var out = [Data?](repeating: nil, count: keys.count)
        let lock = NSLock()
        var done = 0
        out.withUnsafeMutableBufferPointer { buf in
            nonisolated(unsafe) let buf = buf
            DispatchQueue.concurrentPerform(iterations: keys.count) { i in
                let k = keys[i]
                let ts = world / pow(2, Double(k.z))
                let tileRect = MKMapRect(x: Double(k.x) * ts, y: Double(k.y) * ts, width: ts, height: ts)
                if let img = Warper.render(source, geoRef: geoRef, mapRect: tileRect, width: tileSize, height: tileSize),
                   !isEmpty(img) {
                    buf[i] = encode(img, quality: quality)
                }
                lock.lock(); done += 1; let d = done; lock.unlock()
                if d % 200 == 0 { progress?(Double(d) / Double(keys.count)) }
            }
        }
        let tiles = zip(keys, out).compactMap { k, d in d.map { (k, $0) } }
        return (tiles, zMin, zMax, rect)
    }

    static func isEmpty(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return false }
        let n = CFDataGetLength(data)
        var i = 3
        while i < n { if p[i] != 0 { return false }; i += 4 }
        return true
    }

    static func encode(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
