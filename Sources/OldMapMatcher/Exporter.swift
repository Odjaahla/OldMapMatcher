import CryptoKit
import Foundation
import MapLayers
import MapMatchCore

/// Writes every georeferenced map, cut into tiles at full resolution, to a folder in iCloud Drive
/// for the iPhone app. Maps whose points, model and image are unchanged keep their existing tiles.
enum Exporter {
    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Old Map Matcher", isDirectory: true)
    }

    struct Job: Sendable {
        let imageURL: URL
        let name: String
        let points: [ControlPoint]
        let geoRef: GeoReference
        let visible: Bool
        let opacity: Double
        let imageSize: Vec2?

        /// Adds what the phone needs for editing points: the points, model and image size.
        func describe(_ map: FieldMap) -> FieldMap {
            var m = map
            m.controlPoints = points
            m.kind = geoRef.kind
            m.smoothing = geoRef.smoothing
            m.imageWidth = imageSize?.x
            m.imageHeight = imageSize?.y
            return m
        }

        /// Changes whenever the result would: points, model or the image file itself.
        var fingerprint: String {
            var h = SHA256()
            let enc = JSONEncoder()
            enc.outputFormatting = .sortedKeys
            h.update(data: (try? enc.encode(points)) ?? Data())
            h.update(data: Data((geoRef.kind.rawValue + geoRef.smoothing.rawValue).utf8))
            let attrs = try? FileManager.default.attributesOfItem(atPath: imageURL.path)
            h.update(data: Data("\(attrs?[.size] ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)".utf8))
            return h.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    struct Result: Sendable {
        let maps: Int
        let rendered: Int
        let megabytes: Double
    }

    static func export(_ jobs: [Job], appliedEdits: [UUID], to folder: URL,
                       progress: @escaping @Sendable (String) -> Void) throws -> Result {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifestURL = folder.appendingPathComponent(FieldPack.manifestName)
        let previous = (try? Data(contentsOf: manifestURL)).flatMap { try? FieldPack.decode($0) }
        var maps: [FieldMap] = []
        var rendered = 0
        for (i, job) in jobs.enumerated() {
            let fp = job.fingerprint
            let file = job.name + ".tiles"
            let enabled = job.points.filter(\.enabled).count
            if let old = previous?.maps.first(where: { $0.name == job.name && $0.fingerprint == fp && $0.tiles == file }),
               fm.fileExists(atPath: folder.appendingPathComponent(file).path) {
                var m = old
                m.visible = job.visible; m.opacity = job.opacity
                maps.append(job.describe(m))
                continue
            }
            progress("Loading \(job.name) (\(i + 1) of \(jobs.count))…")
            guard let source = SourcePyramid.load(job.imageURL) else { continue }
            let name = job.name
            guard let made = TileMaker.make(source: source, geoRef: job.geoRef, progress: { share in
                progress("Cutting \(name) into tiles: \(Int(share * 100))%")
            }) else { continue }
            try TilePack.write(made.tiles, to: folder.appendingPathComponent(file))
            maps.append(job.describe(FieldMap(name: job.name, tiles: file, minZoom: made.minZoom, maxZoom: made.maxZoom, fingerprint: fp,
                                              rect: made.bounds, points: enabled, errorMetres: job.geoRef.rmsLeaveOneOut,
                                              model: job.geoRef.kind.displayName, visible: job.visible, opacity: job.opacity)))
            rendered += 1
        }
        // Manifest last, so the phone never sees it pointing at files that aren't written yet.
        try FieldPack(exported: Date(), maps: maps, appliedEdits: appliedEdits).encoded().write(to: manifestURL, options: .atomic)

        // Remove files of maps that are no longer exported, and single images from older exports.
        let keep = Set(maps.compactMap(\.tiles))
        var bytes = 0
        for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
            if ["heic", "tiles"].contains(url.pathExtension), !keep.contains(url.lastPathComponent) {
                try? fm.removeItem(at: url)
            } else {
                bytes += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        return Result(maps: maps.count, rendered: rendered, megabytes: Double(bytes) / 1_000_000)
    }
}
