import AppKit
import Combine
import MapMatchCore
import SwiftUI

struct CanvasMarker: Equatable {
    let id: UUID
    let number: Int
    let position: Vec2
    let selected: Bool
    let enabled: Bool
}

/// Pan/zoom viewer for a large scanned map.
/// - Trackpad scroll pans, pinch zooms; mouse wheel zooms around the cursor.
/// - Click places a point; drag on empty map pans; drag a marker to move it.
final class OldMapCanvas: NSView {
    var onClick: ((Vec2) -> Void)?
    var onHover: ((Vec2?) -> Void)?
    var onSelect: ((UUID) -> Void)?
    var onMove: ((UUID, Vec2) -> Void)?

    var image: CGImage? {
        didSet {
            guard image !== oldValue else { return }
            imageLayer.contents = image
            needsInitialFit = true
            needsLayout = true
        }
    }
    var markers: [CanvasMarker] = [] { didSet { if markers != oldValue { overlay.needsDisplay = true } } }
    var pending: Vec2? { didSet { if pending != oldValue { overlay.needsDisplay = true } } }
    var predicted: Vec2? { didSet { if predicted != oldValue { overlay.needsDisplay = true } } }
    var linkedCursor: Vec2? { didSet { if linkedCursor != oldValue { overlay.needsDisplay = true } } }

    /// View points per image pixel.
    private(set) var scale: CGFloat = 0.1
    /// View location of image pixel (0, 0).
    private var offset = CGPoint.zero
    private var needsInitialFit = true

    private let imageLayer = CALayer()
    private lazy var overlay = MarkerOverlay(canvas: self)

    private enum DragState { case none, panning(last: CGPoint), marker(UUID, start: CGPoint), pending(start: CGPoint) }
    private var drag = DragState.none
    private var draggedMarkerPosition: (UUID, Vec2)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        imageLayer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "contents": NSNull()]
        layer?.addSublayer(imageLayer)
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Geometry

    func viewPoint(_ p: Vec2) -> CGPoint { CGPoint(x: offset.x + CGFloat(p.x) * scale, y: offset.y + CGFloat(p.y) * scale) }
    func imagePoint(_ v: CGPoint) -> Vec2 { Vec2(Double((v.x - offset.x) / scale), Double((v.y - offset.y) / scale)) }

    override func layout() {
        super.layout()
        if needsInitialFit, let image, bounds.width > 0 {
            needsInitialFit = false
            scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height)) * 0.95
            offset = CGPoint(x: (bounds.width - CGFloat(image.width) * scale) / 2,
                             y: (bounds.height - CGFloat(image.height) * scale) / 2)
        }
        applyTransform()
    }

    private func applyTransform() {
        guard let image else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = CGRect(x: offset.x, y: offset.y, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        CATransaction.commit()
        overlay.needsDisplay = true
    }

    private func zoom(by factor: CGFloat, around v: CGPoint) {
        guard let image else { return }
        let fit = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let newScale = min(max(scale * factor, fit * 0.3), 8)
        let anchor = imagePoint(v)
        scale = newScale
        offset = CGPoint(x: v.x - CGFloat(anchor.x) * scale, y: v.y - CGFloat(anchor.y) * scale)
        applyTransform()
    }

    func center(on p: Vec2) {
        // Zoom in to a working scale if we're far out.
        if let image, scale < min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height)) * 3 {
            scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height)) * 3
        }
        offset = CGPoint(x: bounds.midX - CGFloat(p.x) * scale, y: bounds.midY - CGFloat(p.y) * scale)
        applyTransform()
    }

    // MARK: Events

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            offset.x += event.scrollingDeltaX
            offset.y += event.scrollingDeltaY
            applyTransform()
        } else {
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
            zoom(by: exp(dy), around: convert(event.locationInWindow, from: nil))
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let v = convert(event.locationInWindow, from: nil)
        if let hit = markerAt(v) {
            drag = .marker(hit, start: v)
            onSelect?(hit)
        } else {
            drag = .pending(start: v)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        switch drag {
        case .pending(let start) where hypot(v.x - start.x, v.y - start.y) > 3:
            drag = .panning(last: start)
            mouseDragged(with: event)
        case .panning(let last):
            offset.x += v.x - last.x
            offset.y += v.y - last.y
            drag = .panning(last: v)
            applyTransform()
        case .marker(let id, let start) where hypot(v.x - start.x, v.y - start.y) > 2 || draggedMarkerPosition != nil:
            draggedMarkerPosition = (id, imagePoint(v))
            overlay.needsDisplay = true
        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        switch drag {
        case .pending:
            if event.clickCount <= 1 { onClick?(imagePoint(v)) }
        case .marker:
            if let (id, p) = draggedMarkerPosition { onMove?(id, p) }
        default:
            break
        }
        drag = .none
        draggedMarkerPosition = nil
        overlay.needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { onHover?(imagePoint(convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }

    private func markerAt(_ v: CGPoint) -> UUID? {
        markers.min { hypot(viewPoint($0.position).x - v.x, viewPoint($0.position).y - v.y) < hypot(viewPoint($1.position).x - v.x, viewPoint($1.position).y - v.y) }
            .flatMap { m in
                let p = viewPoint(m.position)
                return hypot(p.x - v.x, p.y - v.y) <= 10 ? m.id : nil
            }
    }

    fileprivate func displayedMarkers() -> [CanvasMarker] {
        guard let (id, p) = draggedMarkerPosition else { return markers }
        return markers.map { $0.id == id ? CanvasMarker(id: id, number: $0.number, position: p, selected: $0.selected, enabled: $0.enabled) : $0 }
    }
}

/// Draws markers in view coordinates so they keep a constant on-screen size at any zoom.
private final class MarkerOverlay: NSView {
    unowned let canvas: OldMapCanvas
    init(canvas: OldMapCanvas) { self.canvas = canvas; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        for m in canvas.displayedMarkers() {
            let p = canvas.viewPoint(m.position)
            let color: NSColor = !m.enabled ? .systemGray : (m.selected ? .systemGreen : .systemBlue)
            drawCrosshair(at: p, color: color, radius: 9, lineWidth: m.selected ? 2.5 : 1.5)
            let label = NSAttributedString(string: "\(m.number)", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 11),
                .foregroundColor: color,
                .strokeColor: NSColor.white, .strokeWidth: -3,
            ])
            label.draw(at: CGPoint(x: p.x + 8, y: p.y - 20))
        }
        if let pending = canvas.pending {
            drawCrosshair(at: canvas.viewPoint(pending), color: .systemOrange, radius: 11, lineWidth: 2.5)
        }
        if let predicted = canvas.predicted {
            drawCrosshair(at: canvas.viewPoint(predicted), color: .systemPurple, radius: 14, lineWidth: 2, dashed: true)
        }
        if let c = canvas.linkedCursor {
            drawCrosshair(at: canvas.viewPoint(c), color: .systemTeal, radius: 16, lineWidth: 1.5, open: true)
        }
    }

    private func drawCrosshair(at p: CGPoint, color: NSColor, radius r: CGFloat, lineWidth: CGFloat, dashed: Bool = false, open: Bool = false) {
        let path = NSBezierPath()
        if !open { path.appendOval(in: CGRect(x: p.x - r / 2, y: p.y - r / 2, width: r, height: r)) }
        let gap: CGFloat = open ? 4 : 0
        path.move(to: CGPoint(x: p.x - r, y: p.y)); path.line(to: CGPoint(x: p.x - gap, y: p.y))
        path.move(to: CGPoint(x: p.x + gap, y: p.y)); path.line(to: CGPoint(x: p.x + r, y: p.y))
        path.move(to: CGPoint(x: p.x, y: p.y - r)); path.line(to: CGPoint(x: p.x, y: p.y - gap))
        path.move(to: CGPoint(x: p.x, y: p.y + gap)); path.line(to: CGPoint(x: p.x, y: p.y + r))
        if dashed { path.setLineDash([4, 3], count: 2, phase: 0) }
        // White halo for legibility on busy map backgrounds.
        NSColor.white.withAlphaComponent(0.85).setStroke()
        path.lineWidth = lineWidth + 2
        path.stroke()
        color.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }
}

struct OldMapView: NSViewRepresentable {
    @ObservedObject var state: AppState

    final class Coordinator {
        var lastFocus: UUID?
        var cancellable: AnyCancellable?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> OldMapCanvas {
        let canvas = OldMapCanvas(frame: .zero)
        canvas.onClick = { [weak state] p in state?.placeOnImage(p) }
        canvas.onHover = { [weak state] p in state?.hoverImage(p) }
        canvas.onSelect = { [weak state] id in state?.select(id) }
        canvas.onMove = { [weak state] id, p in state?.moveImage(of: id, to: p) }
        context.coordinator.cancellable = state.cursor.image
            .receive(on: RunLoop.main)
            .sink { [weak canvas] p in canvas?.linkedCursor = p }
        return canvas
    }

    func updateNSView(_ canvas: OldMapCanvas, context: Context) {
        canvas.image = state.image
        canvas.markers = state.points.enumerated().map { i, p in
            CanvasMarker(id: p.id, number: i + 1, position: p.image, selected: state.selection.contains(p.id), enabled: p.enabled)
        }
        canvas.pending = state.pendingImage
        canvas.predicted = state.predictedImage
        if let f = state.imageFocus, f.token != context.coordinator.lastFocus {
            context.coordinator.lastFocus = f.token
            canvas.center(on: f.value)
        }
    }
}
