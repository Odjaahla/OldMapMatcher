import AppKit
import Combine
import MapKit
import MapLayers
import MapMatchCore
import SwiftUI

enum BaseLayer: String, CaseIterable, Identifiable {
    case appleStandard, appleSatellite, openStreetMap, terrain
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .appleStandard: "Apple Maps"
        case .appleSatellite: "Satellite"
        case .openStreetMap: "OpenStreetMap"
        case .terrain: "Terrain (LiDAR)"
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
    /// Road-line mode: the second end of the stretch on the modern map.
    @Published private(set) var pendingLineEnd: LatLon?

    enum AddKind: String, CaseIterable, Identifiable {
        /// A feature on both maps.
        case point
        /// A spot on an old road matched to a stretch of the same road today; fixes only the direction across it.
        case line
        var id: String { rawValue }
        var displayName: String { self == .point ? "Point" : "Road line" }
    }
    @Published var addKind = AddKind.point { didSet { if addKind != oldValue { cancelPending() } } }
    @Published var selection: Set<ControlPoint.ID> = []

    @Published var baseLayer = BaseLayer(rawValue: UserDefaults.standard.string(forKey: "baseLayer") ?? "") ?? .appleStandard {
        didSet { defaults.set(baseLayer.rawValue, forKey: "baseLayer") }
    }
    /// Dark modern map: the old maps' paper colours stand out better against it.
    @Published var darkMap = UserDefaults.standard.object(forKey: "darkMap") as? Bool ?? true {
        didSet { defaults.set(darkMap, forKey: "darkMap") }
    }
    @Published var showResiduals = UserDefaults.standard.object(forKey: "showResiduals") as? Bool ?? true {
        didSet { defaults.set(showResiduals, forKey: "showResiduals") }
    }
    @Published var showMarkers = UserDefaults.standard.object(forKey: "showMarkers") as? Bool ?? true {
        didSet { defaults.set(showMarkers, forKey: "showMarkers") }
    }
    /// Shade the active map's area by how far off the fit is likely to be.
    @Published var showUncertainty = UserDefaults.standard.bool(forKey: "showUncertainty") {
        didSet { defaults.set(showUncertainty, forKey: "showUncertainty") }
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
    /// What the export is doing right now, shown while it runs.
    @Published private(set) var exportStatus: String?
    /// Result of the last export, shown as an alert.
    @Published var exportMessage: String?

    /// Writes all georeferenced maps, in layer order, to iCloud Drive for the iPhone app.
    /// Merges the phone's edits first, so they are part of the export.
    func exportForPhone() {
        guard !exporting else { return }
        exporting = true
        exportStatus = "Exporting…"
        mergePhoneEdits(announce: false)
        Task {
            // Wait for refits started by merged edits.
            while documents.contains(where: \.fitting) { try? await Task.sleep(for: .milliseconds(100)) }
            let jobs = documents.compactMap { d in
                d.geoRef.map { Exporter.Job(imageURL: d.url, name: d.name, points: d.points, geoRef: $0,
                                            visible: d.visible, opacity: d.opacity, imageSize: d.imageSize) }
            }
            guard !jobs.isEmpty else {
                exporting = false; exportStatus = nil
                exportMessage = "No maps have enough points to export yet."
                return
            }
            let folder = Exporter.defaultFolder, applied = Array(appliedPhoneEdits)
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try Exporter.export(jobs, appliedEdits: applied, to: folder) { status in
                        Task { @MainActor in if self.exporting { self.exportStatus = status } }
                    }
                }
            }.value
            exporting = false
            exportStatus = nil
            switch result {
            case .success(let r):
                let unchanged = r.maps - r.rendered
                exportMessage = (pendingMergeNote.map { $0 + "\n\n" } ?? "")
                    + "Exported \(r.maps) map\(r.maps == 1 ? "" : "s") to iCloud Drive › Old Map Matcher "
                    + "(\(r.rendered) updated\(unchanged > 0 ? ", \(unchanged) unchanged" : ""); \(Int(r.megabytes.rounded())) MB in all). "
                    + "They appear on the iPhone once iCloud has synced."
            case .failure(let e):
                exportMessage = "Export failed: \(e.localizedDescription)"
            }
            pendingMergeNote = nil
        }
    }

    // MARK: Edits from the iPhone

    /// IDs of phone edits already merged, so each is applied once.
    private var appliedPhoneEdits: Set<UUID> {
        get { Set((defaults.stringArray(forKey: "appliedPhoneEdits") ?? []).compactMap(UUID.init)) }
        set { defaults.set(newValue.map(\.uuidString), forKey: "appliedPhoneEdits") }
    }
    private var pendingMergeNote: String?

    /// Applies points added, unticked or deleted on the phone to the maps' point files.
    func mergePhoneEdits(announce: Bool = true) {
        let url = Exporter.defaultFolder.appendingPathComponent(PhoneEdits.fileName)
        // The coordinated read waits for iCloud to download the file if needed; a missing file reads as nil.
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        var data: Data?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { data = try? Data(contentsOf: $0) }
        guard let data, let all = try? PhoneEdits.decode(data) else { return }
        var applied = appliedPhoneEdits
        let new = all.edits.filter { !applied.contains($0.id) }
        var summary: [String] = []
        for doc in documents {
            let mine = new.filter { $0.map == doc.name }
            guard !mine.isEmpty else { continue }
            doc.points = PhoneEdits.apply(mine, to: doc.points)
            applied.formUnion(mine.map(\.id))
            let adds = mine.filter { $0.action == .add }.count, other = mine.count - adds
            summary.append("\(doc.name): " + [adds > 0 ? "\(adds) added" : nil, other > 0 ? "\(other) changed" : nil]
                .compactMap { $0 }.joined(separator: ", "))
        }
        appliedPhoneEdits = applied
        guard !summary.isEmpty else { return }
        let note = "Merged points from the iPhone:\n" + summary.joined(separator: "\n")
        if announce { exportMessage = note + "\n\nExport for iPhone (⌘E) to update the maps there." } else { pendingMergeNote = note }
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
        mergePhoneEdits()
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
        pendingImage = nil; pendingGeo = nil; pendingLineEnd = nil; selection = []
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
    var displayedOverlays: [(overlay: LiveWarpOverlay, opacity: Double)] {
        switch mode {
        case .match:
            guard showOverlay, let o = active?.overlay else { return [] }
            return [(o, overlayOpacity)]
        case .explore:
            return documents.reversed().compactMap { d in d.visible ? d.overlay.map { ($0, d.opacity) } : nil }
        }
    }

    var displayedUncertainty: UncertaintyOverlay? { showUncertainty && !peeking ? active?.uncertaintyOverlay : nil }

    var overlayBusy: Bool { documents.contains { $0.wantsOverlay && $0.overlayBusy } }

    // MARK: Editing the active map

    var points: [ControlPoint] { active?.points ?? [] }
    var geoRef: GeoReference? { active?.geoRef }

    var predictedGeo: LatLon? {
        guard let p = pendingImage, pendingGeo == nil else { return nil }
        return geoRef?.imageToGeo(p)
    }

    var predictedImage: Vec2? {
        guard let g = pendingGeo, pendingImage == nil, addKind == .point else { return nil }
        return geoRef?.geoToImage(g)
    }

    /// What the next click should be, for the hint in the toolbar.
    var nextStep: String {
        switch addKind {
        case .point:
            return pendingImage != nil ? "Click the same feature on the modern map" :
                pendingGeo != nil ? "Click the same feature on the old map" : "Click a feature on either map"
        case .line:
            let modern = pendingGeo == nil ? "click one end of the road's stretch today" : "click the other end of the stretch"
            return pendingImage == nil ? "Click the old road on the old map, and " + modern : "Now " + modern
        }
    }

    func placeOnImage(_ p: Vec2) {
        pendingImage = p
        if isComplete { commitPending() } else if pendingGeo == nil, let g = predictedGeo { geoFocus = FocusRequest(value: g) }
    }

    func placeOnMap(_ g: LatLon) {
        guard mode == .match else { return }
        if addKind == .line, pendingGeo != nil { pendingLineEnd = g } else { pendingGeo = g }
        if isComplete { commitPending() } else if let p = predictedImage { imageFocus = FocusRequest(value: p) }
    }

    private var isComplete: Bool {
        pendingImage != nil && pendingGeo != nil && (addKind == .point || pendingLineEnd != nil)
    }

    /// Accepts the model's prediction for the missing side of a pending pair (points only).
    func acceptPrediction() {
        guard addKind == .point else { return }
        if let g = predictedGeo { pendingGeo = g } else if let p = predictedImage { pendingImage = p }
        commitPending()
    }

    private func commitPending() {
        guard let p = pendingImage, let g = pendingGeo else { return }
        let end = addKind == .line ? pendingLineEnd : nil
        if addKind == .line, end == nil { return }
        pendingImage = nil; pendingGeo = nil; pendingLineEnd = nil
        addPoint(ControlPoint(image: p, geo: g, lineEnd: end))
    }

    private func addPoint(_ point: ControlPoint) {
        active?.points.append(point)
        selection = [point.id]
    }

    func cancelPending() { pendingImage = nil; pendingGeo = nil; pendingLineEnd = nil }

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

    /// Moves a road line's stretch as a whole so its middle lands on `centre`.
    func moveLine(of id: UUID, centreTo centre: LatLon) {
        guard let doc = active, let i = doc.points.firstIndex(where: { $0.id == id }), let end = doc.points[i].lineEnd else { return }
        let a = Sweref99TM.project(doc.points[i].geo), b = Sweref99TM.project(end)
        let shift = Sweref99TM.project(centre) - (a + b) * 0.5
        doc.points[i].geo = Sweref99TM.unproject(a + shift)
        doc.points[i].lineEnd = Sweref99TM.unproject(b + shift)
    }

    func moveLineEnd(of id: UUID, to g: LatLon) {
        guard let doc = active, let i = doc.points.firstIndex(where: { $0.id == id }), doc.points[i].isLine else { return }
        doc.points[i].lineEnd = g
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
