import CoreLocation
import Foundation
import MapLayers
import MapMatchCore

/// Adding, unticking and deleting control points on the phone. Edits are kept locally and written to
/// `edits from iPhone.json` in the maps folder; the Mac merges them and lists their IDs in the next
/// export, after which they are dropped here.
extension LayerStore {
    private var editsURL: URL { cacheDir.deletingLastPathComponent().appendingPathComponent("edits.json") }

    /// Maps that can be edited: exported with their points and model (Mac app from November 2026 on).
    var editableMaps: [FieldMap] { maps.filter { fits[$0.name] != nil && $0.imageWidth != nil } }

    /// The map's points as they will be once the Mac has merged the pending edits.
    func points(for map: String) -> [ControlPoint] {
        PhoneEdits.apply(edits.filter { $0.map == map }, to: maps.first { $0.name == map }?.controlPoints ?? [])
    }

    func pendingCount(for map: String) -> Int { edits.filter { $0.map == map }.count }

    /// True for points added or changed on the phone and not yet part of an export.
    func isPending(_ id: UUID, in map: String) -> Bool {
        edits.contains { $0.map == map && ($0.point?.id == id || $0.pointID == id) }
    }

    /// The old-map pixel under a spot on the overlay, or nil outside the old map.
    func imagePoint(in map: String, at c: CLLocationCoordinate2D) -> Vec2? {
        guard let fit = fits[map], let m = maps.first(where: { $0.name == map }),
              let w = m.imageWidth, let h = m.imageHeight else { return nil }
        let p = fit.geoToImage(LatLon(lat: c.latitude, lon: c.longitude))
        return p.x >= 0 && p.y >= 0 && p.x <= w && p.y <= h ? p : nil
    }

    func addPoint(to map: String, image: Vec2, today: CLLocationCoordinate2D, name: String) {
        let p = ControlPoint(name: name, image: image, geo: LatLon(lat: today.latitude, lon: today.longitude))
        record(PhoneEdit(map: map, action: .add, point: p))
    }

    func setEnabled(_ enabled: Bool, point id: UUID, in map: String) {
        record(PhoneEdit(map: map, action: enabled ? .enable : .disable, pointID: id))
    }

    func deletePoint(_ id: UUID, in map: String) {
        record(PhoneEdit(map: map, action: .delete, pointID: id))
    }

    /// Shows a message over the map for a few seconds.
    func notify(_ message: String) {
        status = message
        Task {
            try? await Task.sleep(for: .seconds(5))
            if status == message { status = nil }
        }
    }

    // MARK: Storage and sync

    private func record(_ e: PhoneEdit) {
        edits.append(e)
        saveEdits()
    }

    func loadEdits() {
        if let data = try? Data(contentsOf: editsURL), let e = try? PhoneEdits.decode(data) { edits = e.edits }
    }

    private func saveEdits() {
        try? PhoneEdits(edits: edits).encoded().write(to: editsURL, options: .atomic)
        pushEdits()
    }

    /// Writes the pending edits to the maps folder in iCloud Drive, where the Mac reads them.
    func pushEdits() {
        guard let bookmark = UserDefaults.standard.data(forKey: "folderBookmark") else { return }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale),
              let data = try? PhoneEdits(edits: edits).encoded() else { return }
        Task.detached(priority: .utility) {
            guard folder.startAccessingSecurityScopedResource() else { return }
            defer { folder.stopAccessingSecurityScopedResource() }
            let url = folder.appendingPathComponent(PhoneEdits.fileName)
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: nil) { u in
                try? data.write(to: u, options: .atomic)
            }
        }
    }

    /// After a new export: drop edits the Mac has merged, and refit each map from its points.
    func packChanged(_ pack: FieldPack) {
        let applied = Set(pack.appliedEdits ?? [])
        if edits.contains(where: { applied.contains($0.id) }) {
            edits.removeAll { applied.contains($0.id) }
            saveEdits()
        }
        let maps = pack.maps
        Task {
            let fitted = await Task.detached(priority: .userInitiated) { () -> [String: GeoReference] in
                var out: [String: GeoReference] = [:]
                for m in maps {
                    if let pts = m.controlPoints, let g = GeoReference(points: pts, kind: m.kind ?? .similarity) { out[m.name] = g }
                }
                return out
            }.value
            fits = fitted
            if let e = editMap, fitted[e] == nil { editMap = nil }
        }
    }
}

/// Averages a few seconds of GPS fixes for a more precise position than a single fix.
@MainActor
final class GPSAverager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var running = false
    @Published private(set) var fixes = 0
    /// Typical accuracy (metres) of the fixes used.
    @Published private(set) var accuracy: Double?
    @Published private(set) var result: CLLocationCoordinate2D?
    @Published private(set) var failure: String?

    private let manager = CLLocationManager()
    private var samples: [CLLocation] = []
    private var firstGood: Date?
    private var timeout: Task<Void, Never>?

    static let duration: TimeInterval = 6
    static let worstAccuracy = 30.0

    func start() {
        samples = []; fixes = 0; accuracy = nil; result = nil; failure = nil; firstGood = nil
        running = true
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
        timeout?.cancel()
        timeout = Task {
            try? await Task.sleep(for: .seconds(25))
            guard running else { return }
            if samples.isEmpty {
                stop()
                failure = "No precise GPS position (better than \(Int(Self.worstAccuracy)) m). Try in the open, or use the cross instead."
            } else { finish() }
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        running = false
        timeout?.cancel()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.add(locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            guard self.running, (error as? CLError)?.code == .denied else { return }
            self.stop()
            self.failure = "Location access is off. Allow it for Old Maps in Settings, or use the cross instead."
        }
    }

    private func add(_ locations: [CLLocation]) {
        guard running else { return }
        for l in locations where l.horizontalAccuracy > 0 && l.horizontalAccuracy <= Self.worstAccuracy
            && abs(l.timestamp.timeIntervalSinceNow) < 5 {
            samples.append(l)
            if firstGood == nil { firstGood = Date() }
        }
        fixes = samples.count
        accuracy = samples.map(\.horizontalAccuracy).sorted().dropFirst(samples.count / 2).first
        if let t = firstGood, Date().timeIntervalSince(t) >= Self.duration, samples.count >= 3 { finish() }
    }

    /// Mean weighted by 1/accuracy², so the best fixes count most.
    private func finish() {
        stop()
        var lat = 0.0, lon = 0.0, wsum = 0.0
        for s in samples {
            let w = 1 / (s.horizontalAccuracy * s.horizontalAccuracy)
            lat += s.coordinate.latitude * w; lon += s.coordinate.longitude * w; wsum += w
        }
        result = CLLocationCoordinate2D(latitude: lat / wsum, longitude: lon / wsum)
    }
}
