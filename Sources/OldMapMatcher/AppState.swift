import AppKit
import Combine
import MapKit
import MapLayers
import MapMatchCore
import SwiftUI

enum BaseLayer: String, CaseIterable, Identifiable {
    case appleStandard, appleSatellite, openStreetMap
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .appleStandard: "Apple Maps"
        case .appleSatellite: "Satellite"
        case .openStreetMap: "OpenStreetMap"
        }
    }
}

enum Mode: String, CaseIterable, Identifiable {
    /// Old map beside the modern map; click pairs of features.
    case match
    /// Modern map with georeferenced old maps stacked as layers; option-drag to correct.
    case explore
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .match: "Match"
        case .explore: "Explore"
        }
    }
}

/// A request for a view to centre on something. The token makes repeated requests for the
/// same location distinct, so views can tell "already handled" from "new request".
struct FocusRequest<Value: Equatable>: Equatable {
    let value: Value
    let token = UUID()
}

/// Mouse position mirrored between the two views. Kept outside `AppState`'s published
/// properties so that moving the mouse doesn't re-render the whole window.
final class LinkedCursor {
    let geo = CurrentValueSubject<LatLon?, Never>(nil)   // shown on the modern map
    let image = CurrentValueSubject<Vec2?, Never>(nil)   // shown on the old map
}

@MainActor
final class AppState: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published private(set) var workspace: URL?
    /// All maps in layer order: first = top layer.
    @Published private(set) var documents: [MapDocument] = []
    /// The map whose points are being edited.
    @Published private(set) var active: MapDocument?

    @Published var mode = Mode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .match {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: "mode")
            cancelPending()
            cursor.geo.send(nil); cursor.image.send(nil)
            updateDocumentNeeds()
            if mode == .match { syncImageToMapSoon() }
        }
    }

    @Published private(set) var pendingImage: Vec2?
    @Published private(set) var pendingGeo: LatLon?
    @Published var selection: Set<ControlPoint.ID> = []

    @Published var baseLayer = BaseLayer(rawValue: UserDefaults.standard.string(forKey: "baseLayer") ?? "") ?? .appleStandard {
        didSet { defaults.set(baseLayer.rawValue, forKey: "baseLayer") }
    }
    @Published var showResiduals = UserDefaults.standard.object(forKey: "showResiduals") as? Bool ?? true {
        didSet { defaults.set(showResiduals, forKey: "showResiduals") }
    }
    @Published var showMarkers = UserDefaults.standard.object(forKey: "showMarkers") as? Bool ?? true {
        didSet { defaults.set(showMarkers, forKey: "showMarkers") }
    }
    /// Match mode: show the active map's overlay on the modern map.
    @Published var showOverlay = UserDefaults.standard.bool(forKey: "showOverlay") {
        didSet {
            defaults.set(showOverlay, forKey: "showOverlay")
            updateDocumentNeeds()
        }
    }
    /// Match mode overlay opacity (explore mode uses each layer's own opacity).
    @Published var overlayOpacity = UserDefaults.standard.object(forKey: "overlayOpacity") as? Double ?? 0.6 {
        didSet { defaults.set(overlayOpacity, forKey: "overlayOpacity") }
    }
    /// True while space is held: all overlays hidden to compare with the modern map.
    @Published var peeking = false

    @Published var imageFocus: FocusRequest<Vec2>?
    @Published var imageViewport: FocusRequest<ImageViewport>?
    /// Reads the modern map's current centre and ground scale (metres per view point). Set by the map view.
    var modernMapMetrics: (() -> (center: LatLon, metresPerPoint: Double)?)?
    @Published var geoFocus: FocusRequest<LatLon>?

    let cursor = LinkedCursor()
    /// Last visible region of the modern map, so it survives mode switches and relaunches.
    var mapRegion: MKCoordinateRegion? {
        didSet {
            guard let r = mapRegion else { return }
            defaults.set([r.center.latitude, r.center.longitude, r.span.latitudeDelta, r.span.longitudeDelta], forKey: "mapRegion")
        }
    }

    private var documentObservers: [AnyCancellable] = []

    init() {
        if let r = defaults.array(forKey: "mapRegion") as? [Double], r.count == 4 {
            mapRegion = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: r[0], longitude: r[1]),
                                           span: MKCoordinateSpan(latitudeDelta: r[2], longitudeDelta: r[3]))
        }
        if let path = defaults.string(forKey: "workspace"), FileManager.default.fileExists(atPath: path) {
            setWorkspace(URL(fileURLWithPath: path))
        } else {
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("images").path) {
                setWorkspace(cwd)
            }
        }
        if mode == .match { syncImageToMapSoon() }
        if CommandLine.arguments.contains("--export-for-phone") { exportAndQuit() }
    }

    /// `OldMapMatcher --export-for-phone`: export once fits are done, print the result and quit.
    private func exportAndQuit() {
        Task {
            while documents.contains(where: \.fitting) { try? await Task.sleep(for: .milliseconds(100)) }
            exportForPhone()
            while exporting { try? await Task.sleep(for: .milliseconds(100)) }
            print(exportMessage ?? "")
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: Export

    @Published private(set) var exporting = false
    /// Result of the last export, shown as an alert.
    @Published var exportMessage: String?

    /// Writes all georeferenced maps, in layer order, to iCloud Drive for the iPhone app.
    func exportForPhone() {
        guard !exporting else { return }
        let jobs = documents.compactMap { d in
            d.geoRef.map { Exporter.Job(imageURL: d.url, name: d.name, geoRef: $0, points: d.enabledPointCount,
                                        visible: d.visible, opacity: d.opacity) }
        }
        guard !jobs.isEmpty else { exportMessage = "No maps have enough points to export yet."; return }
        exporting = true
        let folder = Exporter.defaultFolder
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try Exporter.export(jobs, to: folder) } }.value
            exporting = false
            switch result {
            case .success(let n):
                exportMessage = "Exported \(n) map\(n == 1 ? "" : "s") to iCloud Drive › Old Map Matcher. They appear on the iPhone once iCloud has synced."
            case .failure(let e):
                exportMessage = "Export failed: \(e.localizedDescription)"
            }
        }
    }

    // MARK: Workspace

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the project folder (it should contain an images/ folder)."
        if panel.runModal() == .OK, let url = panel.url { setWorkspace(url) }
    }

    func setWorkspace(_ url: URL) {
        workspace = url
        defaults.set(url.path, forKey: "workspace")
        rescan()
    }

    private var layerKey: String { "layers:" + (workspace?.path ?? "") }

    func rescan() {
        guard let workspace else { return }
        let dir = workspace.appendingPathComponent("images").resolvingSymlinksInPath()
        let gcpDir = workspace.appendingPathComponent("gcps")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["jpg", "jpeg", "png", "tif", "tiff"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let existing = Dictionary(uniqueKeysWithValues: documents.map { ($0.url, $0) })
        var docs = files.map { existing[$0] ?? MapDocument(url: $0, gcpDirectory: gcpDir) }

        // Restore saved layer order and settings.
        let saved = defaults.dictionary(forKey: layerKey) ?? [:]
        let order = saved["order"] as? [String] ?? []
        docs.sort { a, b in
            let ia = order.firstIndex(of: a.url.lastPathComponent) ?? Int.max
            let ib = order.firstIndex(of: b.url.lastPathComponent) ?? Int.max
            return ia != ib ? ia < ib : a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
        let settings = saved["settings"] as? [String: [String: Any]] ?? [:]
        for d in docs where existing[d.url] == nil {
            if let s = settings[d.url.lastPathComponent] {
                d.visible = s["visible"] as? Bool ?? false
                d.opacity = s["opacity"] as? Double ?? 0.7
            }
        }
        documents = docs

        documentObservers = docs.map { d in
            d.onLayerChange = { [weak self] in self?.layersChanged() }
            // Forward document changes so views observing AppState refresh.
            return d.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }

        if active == nil || !docs.contains(where: { $0 === active }) {
            let last = defaults.string(forKey: "lastMap")
            activate(docs.first { $0.url.lastPathComponent == last } ?? docs.first)
        }
        updateDocumentNeeds()
    }

    private func layersChanged() {
        saveLayerSettings()
        updateDocumentNeeds()
    }

    private func saveLayerSettings() {
        var settings: [String: [String: Any]] = [:]
        for d in documents { settings[d.url.lastPathComponent] = ["visible": d.visible, "opacity": d.opacity] }
        defaults.set(["order": documents.map(\.url.lastPathComponent), "settings": settings], forKey: layerKey)
    }

    func moveLayers(from source: IndexSet, to destination: Int) {
        documents.move(fromOffsets: source, toOffset: destination)
        saveLayerSettings()
    }

    func activate(_ doc: MapDocument?) {
        guard doc !== active else { return }
        active = doc
        pendingImage = nil; pendingGeo = nil; selection = []
        cursor.geo.send(nil); cursor.image.send(nil)
        if let doc { defaults.set(doc.url.lastPathComponent, forKey: "lastMap") }
        updateDocumentNeeds()
        if mode == .match { syncImageToMap() }
    }

    /// Shows the old map at the same place and ground scale as the modern map.
    func syncImageToMap() {
        guard let g = geoRef, let m = modernMapMetrics?(), m.metresPerPoint > 0 else { return }
        let center = g.geoToImage(m.center)
        imageViewport = FocusRequest(value: ImageViewport(center: center, scale: g.metresPerPixel(at: center) / m.metresPerPoint))
    }

    /// After a mode switch the modern map is resized; read its metrics once the layout has settled.
    private func syncImageToMapSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard mode == .match else { return }
            syncImageToMap()
        }
    }

    /// Decides which documents need their full image and which need overlays.
    private func updateDocumentNeeds() {
        for d in documents {
            d.wantsFullImage = d === active && mode == .match
            d.wantsOverlay = mode == .explore ? d.visible : (d === active && showOverlay)
        }
    }

    /// Overlays to draw, bottom to top, with their opacity.
    var displayedOverlays: [(overlay: WarpedImageOverlay, opacity: Double)] {
        switch mode {
        case .match:
            guard showOverlay, let o = active?.overlay else { return [] }
            return [(o, overlayOpacity)]
        case .explore:
            return documents.reversed().compactMap { d in d.visible ? d.overlay.map { ($0, d.opacity) } : nil }
        }
    }

    var overlayBusy: Bool { documents.contains { $0.wantsOverlay && $0.overlayBusy } }

    // MARK: Editing the active map

    var points: [ControlPoint] { active?.points ?? [] }
    var geoRef: GeoReference? { active?.geoRef }

    var predictedGeo: LatLon? {
        guard let p = pendingImage, pendingGeo == nil else { return nil }
        return geoRef?.imageToGeo(p)
    }

    var predictedImage: Vec2? {
        guard let g = pendingGeo, pendingImage == nil else { return nil }
        return geoRef?.geoToImage(g)
    }

    func placeOnImage(_ p: Vec2) {
        pendingImage = p
        if pendingGeo != nil { commitPending() } else if let g = predictedGeo { geoFocus = FocusRequest(value: g) }
    }

    func placeOnMap(_ g: LatLon) {
        guard mode == .match else { return }
        pendingGeo = g
        if pendingImage != nil { commitPending() } else if let p = predictedImage { imageFocus = FocusRequest(value: p) }
    }

    /// Accepts the model's prediction for the missing side of a pending pair.
    func acceptPrediction() {
        if let g = predictedGeo { pendingGeo = g } else if let p = predictedImage { pendingImage = p }
        commitPending()
    }

    private func commitPending() {
        guard let p = pendingImage, let g = pendingGeo else { return }
        pendingImage = nil; pendingGeo = nil
        addPoint(ControlPoint(image: p, geo: g))
    }

    private func addPoint(_ point: ControlPoint) {
        active?.points.append(point)
        selection = [point.id]
    }

    func cancelPending() { pendingImage = nil; pendingGeo = nil }

    /// Explore mode: the feature drawn at `from` on the active map's overlay really lies at `to`.
    /// Returns false if `from` isn't on the old map.
    @discardableResult
    func addCorrection(from: LatLon, to: LatLon) -> Bool {
        guard let doc = active, let g = doc.geoRef, let size = doc.imageSize else { return false }
        let p = g.geoToImage(from)
        guard p.x >= 0, p.y >= 0, p.x < size.x, p.y < size.y else { return false }
        addPoint(ControlPoint(image: p, geo: to))
        return true
    }

    func moveImage(of id: UUID, to p: Vec2) {
        guard let doc = active, let i = doc.points.firstIndex(where: { $0.id == id }) else { return }
        doc.points[i].image = p
    }

    func moveGeo(of id: UUID, to g: LatLon) {
        guard let doc = active, let i = doc.points.firstIndex(where: { $0.id == id }) else { return }
        doc.points[i].geo = g
    }

    func select(_ id: UUID) { selection = [id] }

    func focus(on id: UUID) {
        guard let p = points.first(where: { $0.id == id }) else { return }
        if mode == .match { imageFocus = FocusRequest(value: p.image) }
        geoFocus = FocusRequest(value: p.geo)
    }

    func deleteSelected() {
        active?.points.removeAll { selection.contains($0.id) }
        selection = []
    }

    func number(of id: UUID) -> Int? { points.firstIndex { $0.id == id }.map { $0 + 1 } }

    // MARK: Linked cursor

    func hoverImage(_ p: Vec2?) { cursor.geo.send(p.flatMap { geoRef?.imageToGeo($0) }) }
    func hoverMap(_ g: LatLon?) {
        guard mode == .match else { return }
        cursor.image.send(g.flatMap { geoRef?.geoToImage($0) })
    }
}
