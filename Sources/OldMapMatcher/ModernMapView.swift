import Combine
import MapKit
import MapLayers
import MapMatchCore
import SwiftUI

extension LatLon {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    init(_ c: CLLocationCoordinate2D) { self.init(lat: c.latitude, lon: c.longitude) }
}

final class ControlPointAnnotation: MKPointAnnotation {
    let pointID: UUID
    var number = 0
    var selected = false
    var enabled = true
    init(id: UUID) { pointID = id }
}

final class PendingAnnotation: MKPointAnnotation {}
final class PredictedAnnotation: MKPointAnnotation {}
final class CursorAnnotation: MKPointAnnotation {}
final class ResidualLine: MKPolyline {}

/// MKMapView that reports the coordinate under the mouse and hosts the correction-drag layer.
final class HoverMapView: MKMapView {
    var onHover: ((CLLocationCoordinate2D?) -> Void)?
    let correction = CorrectionDragView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        correction.frame = bounds
        correction.autoresizingMask = [.width, .height]
        addSubview(correction)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["hover"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: ["hover": true]))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHover?(convert(convert(event.locationInWindow, from: nil), toCoordinateFrom: self))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(nil)
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        // Keep the drag layer above MapKit's own subviews.
        if subview !== correction, correction.superview === self {
            addSubview(correction, positioned: .above, relativeTo: nil)
        }
    }
}

/// Transparent layer over the map that captures option-drags: from where a feature appears on
/// the old-map overlay to where it really is. Plain mouse events fall through to the map.
final class CorrectionDragView: NSView {
    var isEnabled = false
    var onCorrection: ((CGPoint, CGPoint) -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled, NSEvent.modifierFlags.contains(.option) else { return nil }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let s = start, let e = current, hypot(e.x - s.x, e.y - s.y) > 3 { onCorrection?(s, e) }
        start = nil; current = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let s = start, let e = current else { return }
        let path = NSBezierPath()
        path.move(to: s); path.line(to: e)
        // Arrow head.
        let angle = atan2(e.y - s.y, e.x - s.x)
        for da in [-0.45, 0.45] {
            path.move(to: e)
            path.line(to: CGPoint(x: e.x - 12 * cos(angle + da), y: e.y - 12 * sin(angle + da)))
        }
        path.appendOval(in: CGRect(x: s.x - 5, y: s.y - 5, width: 10, height: 10))
        path.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.9).setStroke(); path.lineWidth = 5; path.stroke()
        NSColor.systemOrange.setStroke(); path.lineWidth = 2.5; path.stroke()
    }
}

struct ModernMapView: NSViewRepresentable {
    @ObservedObject var state: AppState
    static let home = CLLocationCoordinate2D(latitude: 59.285, longitude: 17.955)

    final class Coordinator: NSObject, MKMapViewDelegate {
        var state: AppState
        weak var mapView: MKMapView?
        var appliedBase: BaseLayer?
        var tileOverlay: OSMTileOverlay?
        var annotations: [UUID: ControlPointAnnotation] = [:]
        let pending = PendingAnnotation()
        let predicted = PredictedAnnotation()
        let cursor = CursorAnnotation()
        var warped: [LiveWarpOverlay] = []
        var renderers: [ObjectIdentifier: LiveWarpRenderer] = [:]
        var opacities: [ObjectIdentifier: Double] = [:]
        var residualKey: [Double] = []
        var lastFocus: UUID?
        var cancellable: AnyCancellable?
        var keyMonitor: Any?

        init(state: AppState) { self.state = state }

        deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

        @MainActor @objc func clicked(_ g: NSClickGestureRecognizer) {
            guard let map = mapView, state.mode == .match else { return }
            let v = g.location(in: map)
            // Clicks on markers select/drag them rather than adding points.
            var hit = map.hitTest(v)
            while let h = hit, !(h is MKMapView) {
                if h is MKAnnotationView { return }
                hit = h.superview
            }
            state.placeOnMap(LatLon(map.convert(v, toCoordinateFrom: map)))
        }

        /// Hold space to hide all overlays (blink comparison). Ignored while typing.
        @MainActor func installKeyMonitor() {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self, event.keyCode == 49, event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                      !(event.window?.firstResponder is NSText) else { return event }
                if event.type == .keyDown {
                    if !event.isARepeat { self.state.peeking = true }
                } else {
                    self.state.peeking = false
                }
                return nil
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region
            Task { @MainActor in self.state.mapRegion = region }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            switch annotation {
            case let a as ControlPointAnnotation:
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "gcp") as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: a, reuseIdentifier: "gcp")
                v.annotation = a
                configure(v, for: a)
                v.isDraggable = true
                v.canShowCallout = false
                v.displayPriority = .required
                v.animatesWhenAdded = false
                return v
            case is PendingAnnotation:
                let v = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: nil)
                v.markerTintColor = .systemOrange
                v.glyphText = "+"
                v.displayPriority = .required
                return v
            case is PredictedAnnotation:
                return crosshairView(annotation, color: .systemPurple, size: 30, dashed: true)
            case is CursorAnnotation:
                let v = crosshairView(annotation, color: .systemTeal, size: 34, dashed: false)
                v.isEnabled = false
                return v
            default:
                return nil
            }
        }

        func configure(_ v: MKMarkerAnnotationView, for a: ControlPointAnnotation) {
            v.glyphText = "\(a.number)"
            v.markerTintColor = !a.enabled ? .systemGray : (a.selected ? .systemGreen : .systemBlue)
        }

        private func crosshairView(_ annotation: MKAnnotation, color: NSColor, size: CGFloat, dashed: Bool) -> MKAnnotationView {
            let v = MKAnnotationView(annotation: annotation, reuseIdentifier: nil)
            v.image = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
                let p = NSBezierPath()
                let c = CGPoint(x: r.midX, y: r.midY)
                p.move(to: CGPoint(x: r.minX + 2, y: c.y)); p.line(to: CGPoint(x: c.x - 4, y: c.y))
                p.move(to: CGPoint(x: c.x + 4, y: c.y)); p.line(to: CGPoint(x: r.maxX - 2, y: c.y))
                p.move(to: CGPoint(x: c.x, y: r.minY + 2)); p.line(to: CGPoint(x: c.x, y: c.y - 4))
                p.move(to: CGPoint(x: c.x, y: c.y + 4)); p.line(to: CGPoint(x: c.x, y: r.maxY - 2))
                if dashed { p.appendOval(in: r.insetBy(dx: 6, dy: 6)) }
                NSColor.white.withAlphaComponent(0.85).setStroke(); p.lineWidth = 4; p.stroke()
                color.setStroke(); p.lineWidth = 2; p.stroke()
                return true
            }
            v.centerOffset = .zero
            v.displayPriority = .required
            return v
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation else { return }
            if let a = annotation as? ControlPointAnnotation {
                Task { @MainActor in self.state.select(a.pointID) }
            }
            mapView.deselectAnnotation(annotation, animated: false)
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                     didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            guard newState == .ending || newState == .canceling else { return }
            view.dragState = .none
            if newState == .ending, let a = view.annotation as? ControlPointAnnotation {
                let c = a.coordinate
                Task { @MainActor in self.state.moveGeo(of: a.pointID, to: LatLon(c)) }
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            switch overlay {
            case let t as MKTileOverlay:
                return MKTileOverlayRenderer(tileOverlay: t)
            case let w as LiveWarpOverlay:
                let r = LiveWarpRenderer(overlay: w)
                r.alpha = CGFloat(opacities[ObjectIdentifier(w)] ?? 0.7)
                renderers[ObjectIdentifier(w)] = r
                return r
            case let l as ResidualLine:
                let r = MKPolylineRenderer(polyline: l)
                r.strokeColor = .systemRed
                r.lineWidth = 2.5
                return r
            default:
                return MKOverlayRenderer(overlay: overlay)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeNSView(context: Context) -> HoverMapView {
        let map = HoverMapView(frame: .zero)
        let c = context.coordinator
        map.delegate = c
        map.showsCompass = true
        map.showsScale = true
        map.showsZoomControls = true
        map.setRegion(state.mapRegion ?? MKCoordinateRegion(center: Self.home, latitudinalMeters: 4000, longitudinalMeters: 4000),
                      animated: false)
        let click = NSClickGestureRecognizer(target: c, action: #selector(Coordinator.clicked(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        map.addGestureRecognizer(click)
        map.onHover = { [weak state] p in state?.hoverMap(p.map(LatLon.init)) }
        map.correction.onCorrection = { [weak state, weak map] s, e in
            guard let state, let map else { return }
            let from = LatLon(map.convert(s, toCoordinateFrom: map.correction))
            let to = LatLon(map.convert(e, toCoordinateFrom: map.correction))
            if !state.addCorrection(from: from, to: to) { NSSound.beep() }
        }
        c.mapView = map
        c.installKeyMonitor()
        state.modernMapMetrics = { [weak map] in
            guard let map, map.bounds.width > 0 else { return nil }
            let y = map.bounds.midY
            let a = MKMapPoint(map.convert(CGPoint(x: 0, y: y), toCoordinateFrom: map))
            let b = MKMapPoint(map.convert(CGPoint(x: map.bounds.width, y: y), toCoordinateFrom: map))
            return (LatLon(map.centerCoordinate), a.distance(to: b) / map.bounds.width)
        }
        let cursor = c.cursor
        c.cancellable = state.cursor.geo
            .receive(on: RunLoop.main)
            .sink { [weak map] g in
                guard let map else { return }
                if let g {
                    cursor.coordinate = g.coordinate
                    if !map.annotations.contains(where: { $0 === cursor }) { map.addAnnotation(cursor) }
                } else if map.annotations.contains(where: { $0 === cursor }) {
                    map.removeAnnotation(cursor)
                }
            }
        return map
    }

    func updateNSView(_ map: HoverMapView, context: Context) {
        let c = context.coordinator
        c.state = state
        let correctionEnabled = state.mode == .explore && state.geoRef != nil
        if map.correction.isEnabled != correctionEnabled {
            map.correction.isEnabled = correctionEnabled
            map.window?.invalidateCursorRects(for: map.correction)
        }
        applyBaseLayer(map, c)
        syncControlPoints(map, c)
        syncSingle(map, c.pending, at: state.pendingGeo)
        syncSingle(map, c.predicted, at: state.predictedGeo)
        syncResiduals(map, c)
        syncWarpedOverlays(map, c)
        if let f = state.geoFocus, f.token != c.lastFocus {
            c.lastFocus = f.token
            map.setCenter(f.value.coordinate, animated: true)
        }
    }

    private func applyBaseLayer(_ map: MKMapView, _ c: Coordinator) {
        guard c.appliedBase != state.baseLayer else { return }
        c.appliedBase = state.baseLayer
        if let t = c.tileOverlay { map.removeOverlay(t); c.tileOverlay = nil }
        switch state.baseLayer {
        case .appleStandard: map.mapType = .standard
        case .appleSatellite: map.mapType = .hybrid
        case .openStreetMap:
            map.mapType = .standard
            let t = OSMTileOverlay()
            map.insertOverlay(t, at: 0, level: .aboveLabels)
            c.tileOverlay = t
        }
    }

    private func syncControlPoints(_ map: MKMapView, _ c: Coordinator) {
        let points = state.showMarkers || state.mode == .match ? state.points : []
        var seen = Set<UUID>()
        for (i, p) in points.enumerated() {
            seen.insert(p.id)
            let a = c.annotations[p.id] ?? {
                let a = ControlPointAnnotation(id: p.id)
                a.coordinate = p.geo.coordinate
                c.annotations[p.id] = a
                map.addAnnotation(a)
                return a
            }()
            let selected = state.selection.contains(p.id)
            if a.coordinate.latitude != p.geo.lat || a.coordinate.longitude != p.geo.lon { a.coordinate = p.geo.coordinate }
            if a.number != i + 1 || a.selected != selected || a.enabled != p.enabled {
                a.number = i + 1; a.selected = selected; a.enabled = p.enabled
                if let v = map.view(for: a) as? MKMarkerAnnotationView { c.configure(v, for: a) }
            }
        }
        for (id, a) in c.annotations where !seen.contains(id) {
            map.removeAnnotation(a)
            c.annotations[id] = nil
        }
    }

    private func syncSingle(_ map: MKMapView, _ a: MKPointAnnotation, at g: LatLon?) {
        let present = map.annotations.contains { $0 === a }
        if let g {
            a.coordinate = g.coordinate
            if !present { map.addAnnotation(a) }
        } else if present {
            map.removeAnnotation(a)
        }
    }

    /// Arrows from where each point was clicked to where the model puts it.
    /// Arrows that line up with their neighbours indicate real map distortion; random ones indicate noise.
    private func syncResiduals(_ map: MKMapView, _ c: Coordinator) {
        var lines: [ResidualLine] = []
        if state.showResiduals, let g = state.geoRef {
            for p in state.points where p.enabled {
                guard let d = g.diagnostics[p.id] else { continue }
                let from = Sweref99TM.project(p.geo)
                let to = Sweref99TM.unproject(from + d.residualVector)
                lines.append(ResidualLine(coordinates: [p.geo.coordinate, to.coordinate], count: 2))
            }
        }
        let key = lines.flatMap { l -> [Double] in
            var cs = [CLLocationCoordinate2D](repeating: .init(), count: 2)
            l.getCoordinates(&cs, range: NSRange(location: 0, length: 2))
            return cs.flatMap { [$0.latitude, $0.longitude] }
        }
        guard key != c.residualKey else { return }
        c.residualKey = key
        map.removeOverlays(map.overlays.filter { $0 is ResidualLine })
        map.addOverlays(lines, level: .aboveLabels)
    }

    private func syncWarpedOverlays(_ map: MKMapView, _ c: Coordinator) {
        let wanted = state.displayedOverlays
        for (o, opacity) in wanted { c.opacities[ObjectIdentifier(o)] = state.peeking ? 0 : opacity }

        if wanted.map({ ObjectIdentifier($0.overlay) }) != c.warped.map(ObjectIdentifier.init) {
            map.removeOverlays(c.warped)
            for o in c.warped where !wanted.contains(where: { $0.overlay === o }) {
                c.renderers[ObjectIdentifier(o)] = nil
                c.opacities[ObjectIdentifier(o)] = nil
            }
            // Bottom to top, above the base map and below the residual arrows.
            let base = c.tileOverlay == nil ? 0 : 1
            for (i, (o, _)) in wanted.enumerated() { map.insertOverlay(o, at: base + i, level: .aboveLabels) }
            c.warped = wanted.map(\.overlay)
        }
        for o in c.warped {
            let id = ObjectIdentifier(o)
            if let r = c.renderers[id], let a = c.opacities[id], abs(r.alpha - CGFloat(a)) > 0.001 {
                r.alpha = CGFloat(a)
                r.setNeedsDisplay()
            }
        }
    }
}
