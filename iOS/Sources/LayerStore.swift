import CoreGraphics
import Foundation
import ImageIO
import MapKit
import MapLayers
import MapMatchCore

enum BaseMap: String, CaseIterable, Identifiable {
    case appleStandard, appleMuted, appleSatellite, openStreetMap
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .appleStandard: "Apple Maps"
        case .appleMuted: "Apple Maps (muted)"
        case .appleSatellite: "Satellite"
        case .openStreetMap: "OpenStreetMap"
        }
    }
}

/// The exported maps and how they're shown. The pack folder (in iCloud Drive) is copied into the
/// app's own storage on every change, so the maps work without a connection.
@MainActor
final class LayerStore: ObservableObject {
    private let defaults = UserDefaults.standard

    /// Maps in layer order, first = top.
    @Published private(set) var maps: [FieldMap] = []
    @Published private(set) var exported: Date?
    @Published private(set) var folderName: String?
    @Published var status: String?
    @Published private(set) var loading = false
    /// Overlays of visible maps: tile layers, or decoded images from older exports.
    @Published private(set) var overlays: [String: MKOverlay] = [:]

    @Published var visible: Set<String> = [] { didSet { saveLayerSettings(); loadVisibleImages() } }
    @Published var opacity: [String: Double] = [:] { didSet { saveLayerSettings() } }
    /// Master fade: 0 = modern map only, 1 = old maps at their own opacity.
    @Published var fade = UserDefaults.standard.object(forKey: "fade") as? Double ?? 1 {
        didSet { defaults.set(fade, forKey: "fade") }
    }
    @Published var baseMap = BaseMap(rawValue: UserDefaults.standard.string(forKey: "baseMap") ?? "") ?? .appleMuted {
        didSet { defaults.set(baseMap.rawValue, forKey: "baseMap") }
    }

    // Editing points (see LayerStore+Points.swift).
    /// Changes made on the phone that the Mac hasn't merged and exported yet, oldest first.
    @Published var edits: [PhoneEdit] = []
    /// Each map's model, refitted from its exported points: turns a spot on the overlay into old-map pixels.
    @Published var fits: [String: GeoReference] = [:]
    /// The map whose points are listed, shown and added to.
    @Published var editMap: String? = UserDefaults.standard.string(forKey: "editMap") {
        didSet { defaults.set(editMap, forKey: "editMap") }
    }
    @Published var showPoints = UserDefaults.standard.bool(forKey: "showPoints") {
        didSet { defaults.set(showPoints, forKey: "showPoints") }
    }
    /// Spots marked while adding a point: the feature on the old map and where it is today.
    @Published var draftOld: CLLocationCoordinate2D?
    @Published var draftNew: CLLocationCoordinate2D?
    /// Set by the map view.
    var mapCenter: (() -> CLLocationCoordinate2D?)?
    var focusMap: ((CLLocationCoordinate2D) -> Void)?

    let cacheDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pack", isDirectory: true)
    private var loadingImages: Set<String> = []

    init() {
        folderName = defaults.string(forKey: "folderName")
        loadEdits()
        if let data = try? Data(contentsOf: cacheDir.appendingPathComponent(FieldPack.manifestName)),
           let pack = try? FieldPack.decode(data) {
            apply(pack)
        }
    }

    func effectiveOpacity(_ name: String) -> Double { (opacity[name] ?? 0.8) * fade }

    // MARK: Folder

    func setFolder(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { status = "No access to that folder."; return }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            defaults.set(try url.bookmarkData(), forKey: "folderBookmark")
            defaults.set(url.lastPathComponent, forKey: "folderName")
            folderName = url.lastPathComponent
            refresh()
        } catch {
            status = "Could not remember the folder: \(error.localizedDescription)"
        }
    }

    /// Copies the pack from the chosen folder if it changed since the last copy.
    func refresh() {
        guard !loading, let bookmark = defaults.data(forKey: "folderBookmark") else { return }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else {
            status = "The maps folder can't be found. Choose it again."
            return
        }
        if stale, let fresh = try? folder.bookmarkData() { defaults.set(fresh, forKey: "folderBookmark") }
        pushEdits() // retry, in case an earlier save happened offline
        loading = true
        let current = exported, cacheDir = cacheDir
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try LayerStore.copyPack(from: folder, to: cacheDir, unlessExported: current) }
            }.value
            loading = false
            switch result {
            case .success(let pack?):
                overlays = [:]
                apply(pack)
                status = nil
            case .success(nil):
                status = nil
            case .failure(let e):
                status = maps.isEmpty ? "Couldn't read the maps: \(e.localizedDescription)" : "Showing the last copied maps (\(e.localizedDescription))"
            }
        }
    }

    /// Returns the new pack, or nil if it's unchanged. Maps whose fingerprint matches the copy
    /// already in the app are reused, so only changed maps are copied.
    nonisolated private static func copyPack(from folder: URL, to cache: URL, unlessExported current: Date?) throws -> FieldPack? {
        guard folder.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
        defer { folder.stopAccessingSecurityScopedResource() }
        let manifestData = try coordinatedRead(folder.appendingPathComponent(FieldPack.manifestName))
        let pack = try FieldPack.decode(manifestData)
        if pack.exported == current { return nil }

        let fm = FileManager.default
        let old = (try? Data(contentsOf: cache.appendingPathComponent(FieldPack.manifestName))).flatMap { try? FieldPack.decode($0) }
        let staging = cache.deletingLastPathComponent().appendingPathComponent("Pack-incoming", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        for map in pack.maps {
            guard let file = map.tiles ?? map.file else { continue }
            let cached = cache.appendingPathComponent(file)
            if let fp = map.fingerprint, old?.maps.contains(where: { $0.fingerprint == fp && ($0.tiles ?? $0.file) == file }) == true,
               fm.fileExists(atPath: cached.path) {
                try fm.copyItem(at: cached, to: staging.appendingPathComponent(file)) // a clone on APFS: instant
            } else {
                try coordinatedCopy(folder.appendingPathComponent(file), to: staging.appendingPathComponent(file))
            }
        }
        try manifestData.write(to: staging.appendingPathComponent(FieldPack.manifestName))
        try? fm.removeItem(at: cache)
        try fm.moveItem(at: staging, to: cache)
        return pack
    }

    /// Reading through a file coordinator makes iCloud Drive download the file first if needed.
    nonisolated private static func coordinatedRead(_ url: URL) throws -> Data {
        var data = Data()
        try coordinated(url) { data = try Data(contentsOf: $0) }
        return data
    }

    /// Copies without loading the file into memory (tile packs can be hundreds of megabytes).
    nonisolated private static func coordinatedCopy(_ url: URL, to dest: URL) throws {
        try coordinated(url) { try FileManager.default.copyItem(at: $0, to: dest) }
    }

    nonisolated private static func coordinated(_ url: URL, _ body: (URL) throws -> Void) throws {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        var coordError: NSError?
        var inner: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            do { try body(u) } catch { inner = error }
        }
        if let e = coordError ?? inner { throw e }
    }

    // MARK: Layers

    private func apply(_ pack: FieldPack) {
        maps = pack.maps
        exported = pack.exported
        // Settings saved on the phone win; new maps start as they were on the Mac.
        let saved = defaults.dictionary(forKey: "layers") as? [String: [String: Any]] ?? [:]
        var vis: Set<String> = [], op: [String: Double] = [:]
        for m in pack.maps {
            let s = saved[m.name]
            if s?["visible"] as? Bool ?? m.visible { vis.insert(m.name) }
            op[m.name] = s?["opacity"] as? Double ?? m.opacity
        }
        if vis.isEmpty, let first = pack.maps.first { vis.insert(first.name) }
        opacity = op
        visible = vis
        packChanged(pack)
    }

    private func saveLayerSettings() {
        guard !maps.isEmpty else { return }
        var saved = defaults.dictionary(forKey: "layers") as? [String: [String: Any]] ?? [:]
        for m in maps {
            saved[m.name] = ["visible": visible.contains(m.name), "opacity": opacity[m.name] ?? 0.8]
        }
        defaults.set(saved, forKey: "layers")
    }

    /// Opens tile packs of visible maps (cheap: tiles load as they're shown) and releases hidden ones.
    /// Maps from older exports are single images, decoded in the background (~50 MB each).
    private func loadVisibleImages() {
        for name in overlays.keys where !visible.contains(name) { overlays[name] = nil }
        for m in maps where visible.contains(m.name) && overlays[m.name] == nil && !loadingImages.contains(m.name) {
            if let tiles = m.tiles {
                if let reader = TilePack.Reader(url: cacheDir.appendingPathComponent(tiles)) {
                    overlays[m.name] = PackedTileOverlay(reader: reader, minZoom: m.minZoom ?? 0, maxZoom: m.maxZoom ?? 21, bounds: m.mapRect)
                }
                continue
            }
            guard let file = m.file else { continue }
            loadingImages.insert(m.name)
            let url = cacheDir.appendingPathComponent(file), rect = m.mapRect, name = m.name
            Task {
                let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                    return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                }.value
                loadingImages.remove(name)
                guard visible.contains(name), let image else { return }
                overlays[name] = WarpedImageOverlay(image: image, rect: rect)
            }
        }
    }

    /// Union of all maps' footprints, for the first view.
    var footprint: MKMapRect? {
        maps.map(\.mapRect).reduce(nil) { acc, r in acc.map { $0.union(r) } ?? r }
    }
}
