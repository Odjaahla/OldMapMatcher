import AppKit
import Combine
import ImageIO
import MapMatchCore
import SwiftUI

struct MapEntry: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

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

/// A request for a view to centre on something. The token makes repeated requests for the
/// same location distinct, so views can tell "already handled" from "new request".
struct FocusRequest<Value: Equatable>: Equatable {
    let value: Value
    let token = UUID()
}

/// On-disk control points for one map: `gcps/<image file name>.json`.
struct ControlPointFile: Codable {
    var image: String
    var kind: TransformKind
    var points: [ControlPoint]
}

/// Mouse position mirrored between the two views. Kept outside `AppState`'s published
/// properties so that moving the mouse doesn't re-render the whole window.
final class LinkedCursor {
    let geo = CurrentValueSubject<LatLon?, Never>(nil)   // shown on the modern map
    let image = CurrentValueSubject<Vec2?, Never>(nil)   // shown on the old map
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var workspace: URL?
    @Published private(set) var maps: [MapEntry] = []
    @Published var selectedMap: MapEntry? { didSet { if oldValue != selectedMap { loadSelectedMap() } } }
    @Published private(set) var image: CGImage?
    @Published private(set) var loadError: String?

    @Published var points: [ControlPoint] = [] { didSet { if oldValue != points { pointsChanged() } } }
    @Published var kind: TransformKind = .affine { didSet { if oldValue != kind { pointsChanged() } } }
    @Published private(set) var geoRef: GeoReference?

    @Published private(set) var pendingImage: Vec2?
    @Published private(set) var pendingGeo: LatLon?
    @Published var selection: Set<ControlPoint.ID> = []

    @Published var baseLayer = BaseLayer(rawValue: UserDefaults.standard.string(forKey: "baseLayer") ?? "") ?? .appleStandard {
        didSet { UserDefaults.standard.set(baseLayer.rawValue, forKey: "baseLayer") }
    }
    @Published var showResiduals = UserDefaults.standard.object(forKey: "showResiduals") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showResiduals, forKey: "showResiduals") }
    }
    @Published var showOverlay = UserDefaults.standard.bool(forKey: "showOverlay") {
        didSet {
            UserDefaults.standard.set(showOverlay, forKey: "showOverlay")
            if showOverlay != oldValue { rebuildOverlay() }
        }
    }
    @Published var overlayOpacity = UserDefaults.standard.object(forKey: "overlayOpacity") as? Double ?? 0.6 {
        didSet { UserDefaults.standard.set(overlayOpacity, forKey: "overlayOpacity") }
    }
    @Published private(set) var overlay: WarpedImageOverlay?
    @Published private(set) var overlayBusy = false

    @Published var imageFocus: FocusRequest<Vec2>?
    @Published var geoFocus: FocusRequest<LatLon>?

    let cursor = LinkedCursor()

    private var raster: SourceRaster?
    private var overlayTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    init() {
        if let path = UserDefaults.standard.string(forKey: "workspace"),
           FileManager.default.fileExists(atPath: path) {
            setWorkspace(URL(fileURLWithPath: path))
        } else {
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("images").path) {
                setWorkspace(cwd)
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
        UserDefaults.standard.set(url.path, forKey: "workspace")
        rescan()
    }

    func rescan() {
        guard let workspace else { return }
        let dir = workspace.appendingPathComponent("images").resolvingSymlinksInPath()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        maps = files
            .filter { ["jpg", "jpeg", "png", "tif", "tiff"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(MapEntry.init)
        if selectedMap == nil || !maps.contains(selectedMap!) {
            let last = UserDefaults.standard.string(forKey: "lastMap")
            selectedMap = maps.first { $0.url.lastPathComponent == last } ?? maps.first
        }
    }

    private var gcpURL: URL? {
        guard let workspace, let selectedMap else { return nil }
        return workspace.appendingPathComponent("gcps")
            .appendingPathComponent(selectedMap.url.lastPathComponent + ".json")
    }

    private func loadSelectedMap() {
        loadTask?.cancel()
        overlayTask?.cancel()
        image = nil; raster = nil; overlay = nil; loadError = nil
        pendingImage = nil; pendingGeo = nil; selection = []
        cursor.geo.send(nil); cursor.image.send(nil)
        guard let map = selectedMap else { points = []; return }
        UserDefaults.standard.set(map.url.lastPathComponent, forKey: "lastMap")

        isLoading = true
        if let url = gcpURL, FileManager.default.fileExists(atPath: url.path) {
            do {
                let file = try JSONDecoder().decode(ControlPointFile.self, from: Data(contentsOf: url))
                kind = file.kind
                points = file.points
            } catch {
                points = []
                loadError = "Could not read \(url.lastPathComponent): \(error.localizedDescription). It will not be overwritten until you add a point."
            }
        } else {
            points = []
        }
        isLoading = false
        pointsChanged(save: false)

        loadTask = Task {
            let decoded = await Task.detached(priority: .userInitiated) { () -> (CGImage, SourceRaster)? in
                guard let src = CGImageSourceCreateWithURL(map.url as CFURL, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                else { return nil }
                return (img, SourceRaster(img, maxDimension: 4096))
            }.value
            guard !Task.isCancelled, selectedMap == map else { return }
            if let (img, r) = decoded {
                image = img; raster = r
                rebuildOverlay()
            } else {
                loadError = "Could not read \(map.url.lastPathComponent)"
            }
        }
    }

    private var isLoading = false

    private func save() {
        guard let url = gcpURL, let selectedMap else { return }
        let file = ControlPointFile(image: selectedMap.url.lastPathComponent, kind: kind, points: points)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(file).write(to: url, options: .atomic)
        } catch {
            NSLog("Failed to save control points: \(error)")
        }
    }

    // MARK: Fitting

    /// Left-out error (RMS, metres) for each model on the current points; nil = too few points.
    @Published private(set) var modelComparison: [TransformKind: Double] = [:]

    /// The model that best predicts points it wasn't fitted to.
    var bestModel: TransformKind? { modelComparison.min { $0.value < $1.value }?.key }

    /// Flagging single points as outliers is only meaningful once there's redundancy to compare against.
    var enoughPointsToFlagOutliers: Bool { points.filter(\.enabled).count >= 6 }

    private func pointsChanged(save shouldSave: Bool = true) {
        guard !isLoading else { return }
        geoRef = GeoReference(points: points, kind: kind)
            ?? (kind != .similarity ? GeoReference(points: points, kind: .similarity) : nil)
        var comparison: [TransformKind: Double] = [:]
        for k in TransformKind.allCases {
            if k == geoRef?.kind, let v = geoRef?.rmsLeaveOneOut {
                comparison[k] = v
            } else if let v = GeoReference(points: points, kind: k)?.rmsLeaveOneOut {
                comparison[k] = v
            }
        }
        modelComparison = comparison
        if shouldSave { save() }
        rebuildOverlay()
    }

    /// Kind actually in use (falls back to similarity while there are too few points).
    var effectiveKind: TransformKind? { geoRef?.kind }

    var predictedGeo: LatLon? {
        guard let p = pendingImage, pendingGeo == nil else { return nil }
        return geoRef?.imageToGeo(p)
    }

    var predictedImage: Vec2? {
        guard let g = pendingGeo, pendingImage == nil else { return nil }
        return geoRef?.geoToImage(g)
    }

    // MARK: Editing

    func placeOnImage(_ p: Vec2) {
        pendingImage = p
        if pendingGeo != nil { commitPending() } else if let g = predictedGeo { geoFocus = FocusRequest(value: g) }
    }

    func placeOnMap(_ g: LatLon) {
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
        let point = ControlPoint(image: p, geo: g)
        pendingImage = nil; pendingGeo = nil
        points.append(point)
        selection = [point.id]
    }

    func cancelPending() { pendingImage = nil; pendingGeo = nil }

    func moveImage(of id: UUID, to p: Vec2) {
        if let i = points.firstIndex(where: { $0.id == id }) { points[i].image = p }
    }

    func moveGeo(of id: UUID, to g: LatLon) {
        if let i = points.firstIndex(where: { $0.id == id }) { points[i].geo = g }
    }

    func select(_ id: UUID) {
        selection = [id]
    }

    func focus(on id: UUID) {
        guard let p = points.first(where: { $0.id == id }) else { return }
        imageFocus = FocusRequest(value: p.image)
        geoFocus = FocusRequest(value: p.geo)
    }

    func deleteSelected() {
        points.removeAll { selection.contains($0.id) }
        selection = []
    }

    func toggleEnabledSelected() {
        for i in points.indices where selection.contains(points[i].id) { points[i].enabled.toggle() }
    }

    func number(of id: UUID) -> Int? { points.firstIndex { $0.id == id }.map { $0 + 1 } }

    // MARK: Linked cursor

    func hoverImage(_ p: Vec2?) {
        cursor.geo.send(p.flatMap { geoRef?.imageToGeo($0) })
    }

    func hoverMap(_ g: LatLon?) {
        cursor.image.send(g.flatMap { geoRef?.geoToImage($0) })
    }

    // MARK: Overlay

    private func rebuildOverlay() {
        overlayTask?.cancel()
        guard showOverlay, let geoRef, let raster, let image else {
            if !showOverlay { overlay = nil }
            overlayBusy = false
            return
        }
        overlayBusy = true
        let size = Vec2(Double(image.width), Double(image.height))
        overlayTask = Task {
            try? await Task.sleep(for: .milliseconds(150)) // coalesce bursts of edits
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                Warper.warp(raster, imageSize: size, geoRef: geoRef)
            }.value
            guard !Task.isCancelled else { return }
            overlay = result
            overlayBusy = false
        }
    }
}
