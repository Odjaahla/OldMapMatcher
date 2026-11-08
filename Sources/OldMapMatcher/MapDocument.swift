import Combine
import CoreGraphics
import Foundation
import ImageIO
import MapLayers
import MapMatchCore

/// On-disk control points for one map: `gcps/<image file name>.json`.
struct ControlPointFile: Codable {
    var image: String
    var kind: TransformKind
    var points: [ControlPoint]
}

/// One old map: its control points, fitted transform and (when needed) its image and warped overlay.
/// Several documents can be live at once when they are shown as layers.
@MainActor
final class MapDocument: ObservableObject, Identifiable {
    let url: URL
    let gcpURL: URL
    nonisolated var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }

    @Published var points: [ControlPoint] = [] { didSet { if oldValue != points { changed() } } }
    @Published var kind: TransformKind = .similarity { didSet { if oldValue != kind { changed() } } }
    @Published private(set) var geoRef: GeoReference?
    /// True while a refit is running in the background.
    @Published private(set) var fitting = false
    /// Left-out error (RMS, metres) for each model on the current points; missing = too few points.
    @Published private(set) var modelComparison: [TransformKind: Double] = [:]
    @Published private(set) var loadError: String?

    /// Full-resolution image, loaded only while the map is being matched.
    @Published private(set) var image: CGImage?
    @Published private(set) var imageSize: Vec2?
    @Published private(set) var overlay: LiveWarpOverlay?
    /// Shading of how well the points pin the map down; nil with fewer than 6 points.
    @Published private(set) var uncertaintyOverlay: UncertaintyOverlay?
    @Published private(set) var overlayBusy = false

    // Layer settings (persisted by AppState).
    @Published var visible = false { didSet { if visible != oldValue { onLayerChange?() } } }
    @Published var opacity = 0.7 { didSet { if opacity != oldValue { onLayerChange?() } } }
    var onLayerChange: (() -> Void)?

    /// Whether something currently displays this map's overlay. Overlays are only computed when wanted.
    var wantsOverlay = false { didSet { if wantsOverlay != oldValue { updateOverlay() } } }
    /// Whether the full-resolution image is needed (it's large, so it's released when not).
    var wantsFullImage = false {
        didSet {
            guard wantsFullImage != oldValue else { return }
            if wantsFullImage { loadFullImage() } else { imageTask?.cancel(); image = nil }
        }
    }

    private var source: SourcePyramid?
    private var sourceTask: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?

    init(url: URL, gcpDirectory: URL) {
        self.url = url
        gcpURL = gcpDirectory.appendingPathComponent(url.lastPathComponent + ".json")
        if FileManager.default.fileExists(atPath: gcpURL.path) {
            do {
                let file = try JSONDecoder().decode(ControlPointFile.self, from: Data(contentsOf: gcpURL))
                kind = file.kind
                points = file.points
            } catch {
                loadError = "Could not read \(gcpURL.lastPathComponent): \(error.localizedDescription). It will not be overwritten until you add a point."
            }
        }
        // The pixel size from the file header, without decoding the image.
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            imageSize = Vec2(Double(w), Double(h))
        }
        refit()
    }

    var enabledPointCount: Int { points.filter(\.enabled).count }

    /// The model that best predicts points it wasn't fitted to.
    var bestModel: TransformKind? { modelComparison.min { $0.value < $1.value }?.key }

    // MARK: Fitting

    private func changed() {
        refit() // updates the overlay when done
        save()
    }

    private var fitTask: Task<Void, Never>?

    /// Fits all models in the background (automatic parameter selection gets slow with many points)
    /// and publishes the result unless a newer edit has superseded it.
    private func refit() {
        fitTask?.cancel()
        fitting = true
        let points = points, kind = kind
        fitTask = Task {
            let size = imageSize
            let (g, comparison, shading) = await Task.detached(priority: .userInitiated) {
                () -> (GeoReference?, [TransformKind: Double], UncertaintyOverlay?) in
                var fits: [TransformKind: GeoReference] = [:]
                for k in TransformKind.allCases { fits[k] = GeoReference(points: points, kind: k) }
                let g = fits[kind] ?? (kind != .similarity ? fits[.similarity] : nil)
                let shading = g.flatMap { g in
                    UncertaintyField(points: points).flatMap { f in size.flatMap { UncertaintyOverlay(field: f, geoRef: g, imageSize: $0) } }
                }
                return (g, fits.compactMapValues(\.rmsLeaveOneOut), shading)
            }.value
            guard !Task.isCancelled else { return }
            geoRef = g
            modelComparison = comparison
            uncertaintyOverlay = shading
            fitting = false
            updateOverlay()
        }
    }

    private func save() {
        let file = ControlPointFile(image: url.lastPathComponent, kind: kind, points: points)
        do {
            try FileManager.default.createDirectory(at: gcpURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(file).write(to: gcpURL, options: .atomic)
            loadError = nil
        } catch {
            NSLog("Failed to save control points: \(error)")
        }
    }

    // MARK: Images

    private func loadFullImage() {
        guard image == nil else { return }
        let url = url
        imageTask = Task {
            let img = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            }.value
            guard !Task.isCancelled, wantsFullImage else { return }
            if let img {
                image = img
                imageSize = Vec2(Double(img.width), Double(img.height))
            } else {
                loadError = "Could not read \(url.lastPathComponent)"
            }
        }
    }

    /// Loads the full-resolution source for the overlay (about 4 bytes per pixel, plus a third for the
    /// smaller copies); it's released again when no overlay is wanted.
    private func loadSource() {
        guard source == nil, sourceTask == nil else { return }
        let url = url
        overlayBusy = true
        sourceTask = Task {
            let result = await Task.detached(priority: .userInitiated) { SourcePyramid.load(url) }.value
            sourceTask = nil
            guard wantsOverlay else { overlayBusy = false; return }
            guard let result else { loadError = "Could not read \(url.lastPathComponent)"; overlayBusy = false; return }
            source = result
            if imageSize == nil { imageSize = result.imageSize }
            updateOverlay()
        }
    }

    // MARK: Overlay

    /// Tiles are warped as MapKit draws them, so a new fit only needs a new overlay object.
    private func updateOverlay() {
        guard wantsOverlay else {
            overlay = nil; overlayBusy = false; source = nil
            return
        }
        guard let source else { loadSource(); return }
        overlayBusy = false
        overlay = geoRef.flatMap { LiveWarpOverlay(source: source, geoRef: $0) }
    }
}
