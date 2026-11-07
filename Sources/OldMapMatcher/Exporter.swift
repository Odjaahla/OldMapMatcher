import Foundation
import ImageIO
import MapLayers
import MapMatchCore
import UniformTypeIdentifiers

/// Writes every georeferenced map, pre-warped, to a folder in iCloud Drive for the iPhone app.
enum Exporter {
    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Old Map Matcher", isDirectory: true)
    }

    struct Job: Sendable {
        let imageURL: URL
        let name: String
        let geoRef: GeoReference
        let points: Int
        let visible: Bool
        let opacity: Double
    }

    /// Returns the number of maps exported.
    static func export(_ jobs: [Job], to folder: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var maps: [FieldMap] = []
        for job in jobs {
            guard let (raster, size) = SourceRaster.load(job.imageURL),
                  let overlay = Warper.warp(raster, imageSize: size, geoRef: job.geoRef)
            else { continue }
            let file = job.name + ".heic"
            try write(overlay.image, to: folder.appendingPathComponent(file))
            maps.append(FieldMap(name: job.name, file: file, rect: overlay.boundingMapRect, points: job.points,
                                 errorMetres: job.geoRef.rmsLeaveOneOut, model: job.geoRef.kind.displayName,
                                 visible: job.visible, opacity: job.opacity))
        }
        // Manifest last, so the phone never sees it pointing at images that aren't written yet.
        try FieldPack(exported: Date(), maps: maps).encoded()
            .write(to: folder.appendingPathComponent(FieldPack.manifestName), options: .atomic)

        // Remove images of maps that are no longer exported.
        let keep = Set(maps.map(\.file))
        for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "heic" && !keep.contains(url.lastPathComponent) {
            try? fm.removeItem(at: url)
        }
        return maps.count
    }

    /// HEIC keeps transparency outside the map's footprint at a fraction of PNG's size.
    private static func write(_ image: CGImage, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).heic")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
