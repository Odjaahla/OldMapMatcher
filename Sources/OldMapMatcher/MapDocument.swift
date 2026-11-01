import Combine
import CoreGraphics
import Foundation
import ImageIO
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
    /// Left-out error (RMS, metres) for each model on the current points; missing = too few points.
    @Published private(set) var modelComparison: [TransformKind: Double] = [:]
    @Published private(set) var loadError: String?

    /// Full-resolution image, loaded only while the map is being matched.
    @Published private(set) var image: CGImage?
    @Published private(set) var imageSize: Vec2?
    @Published private(set) var overlay: WarpedImageOverlay?
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

    private var raster: SourceRaster?
    private var rasterTask: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?
    private var overlayTask: Task<Void, Never>?

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
        refit()
    }

    var enabledPointCount: Int { points.filter(\.enabled).count }

    /// The model that best predicts points it wasn't fitted to.
    var bestModel: TransformKind? { modelComparison.min { $0.value < $1.value }?.key }

    // MARK: Fitting

    private func changed() {
        refit()
        save()
        updateOverlay()
    }

    private func refit() {
        geoRef = GeoReference(points: points, kind: kind)
            ?? (kind != .similarity ? GeoReference(points: points, kind: .similarity) : nil)
        var comparison: [TransformKind: Double] = [:]
        for k in TransformKind.allCases {
            let g = k == geoRef?.kind ? geoRef : GeoReference(points: points, kind: k)
            if let v = g?.rmsLeaveOneOut { comparison[k] = v }
        }
        modelComparison = comparison
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

    /// Loads a downsampled copy for warping without decoding the full image.
    private func loadRaster() {
        guard raster == nil, rasterTask == nil else { return }
        let url = url
        rasterTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (SourceRaster, Vec2)? in
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                      let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
                      let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceThumbnailMaxPixelSize: SourceRaster.maxDimension,
                          kCGImageSourceCreateThumbnailWithTransform: true,
                      ] as CFDictionary)
                else { return nil }
                return (SourceRaster(thumb, originalWidth: w), Vec2(Double(w), Double(h)))
            }.value
            rasterTask = nil
            guard let (r, size) = result else { loadError = "Could not read \(url.lastPathComponent)"; return }
            raster = r
            if imageSize == nil { imageSize = size }
            updateOverlay()
        }
    }

    // MARK: Overlay

    private func updateOverlay() {
        overlayTask?.cancel()
        guard wantsOverlay else {
            overlay = nil; overlayBusy = false; raster = nil
            return
        }
        guard let raster, let size = imageSize else { loadRaster(); return }
        guard let geoRef else { overlay = nil; overlayBusy = false; return }
        overlayBusy = true
        overlayTask = Task {
            try? await Task.sleep(for: .milliseconds(120)) // coalesce bursts of edits
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
