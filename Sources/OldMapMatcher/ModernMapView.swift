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
    /// A road line: the marker sits mid-stretch and dragging it moves the whole stretch.
    var isLine = false
    init(id: UUID) { pointID = id }
}

/// Draggable handle at either end of a road line's stretch.
final class LineEndAnnotation: MKPointAnnotation {
    let pointID: UUID
    let isEnd: Bool
    init(id: UUID, isEnd: Bool) { pointID = id; self.isEnd = isEnd }
}

/// The modern stretch of a road line.
final class ControlLineOverlay: MKPolyline {
    var enabled = true
    var pending = false
}

final class PendingAnnotation: MKPointAnnotation {}
final class PredictedAnnotation: MKPointAnnotation {}
final class CursorAnnotation: MKPointAnnotation {}
final class ResidualLine: MKPolyline {}

/// MKMapView that reports the coordinate under the mouse and hosts the correction-drag layer.
final class HoverMapView: MKMapView {
    var onHover: ((CLLocationCoordinate2D?) -> Void)?
    let correction = CorrectionDragView()
    let nudge = NudgeDragView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [correction, nudge] as [NSView] {
            v.frame = bounds
            v.autoresizingMask = [.width, .height]
            addSubview(v)
        }
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
        // Keep the drag layers above MapKit's own subviews.
        if subview !== correction, subview !== nudge, correction.superview === self, nudge.superview === self {
            addSubview(correction, positioned: .above, relativeTo: nil)
            addSubview(nudge, positioned: .above, relativeTo: nil)
        }
    }
}

/// Transparent layer over the map that captures ⌘-drags: the selected marker (or the nearest) moves by
/// as much as the mouse, wherever the drag starts, so it can be placed precisely.
final class NudgeDragView: NSView {
    /// The marker to move for a drag starting at a view point: its id and coordinate.
    var target: ((CGPoint) -> (UUID, CLLocationCoordinate2D)?)?
    var onChange: ((UUID, CLLocationCoordinate2D) -> Void)?
    var onEnd: ((UUID, CLLocationCoordinate2D) -> Void)?
    private var drag: (id: UUID, start: CGPoint, from: CGPoint)?
    private var last: CLLocationCoordinate2D?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard NSEvent.modifierFlags.contains(.command), let p = superview?.convert(point, to: self), target?(p) != nil else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard let map = superview as? MKMapView else { return }
        let v = convert(event.locationInWindow, from: nil)
        guard let (id, c) = target?(v) else { return }
        drag = (id, v, map.convert(c, toPointTo: self))
        last = nil
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let map = superview as? MKMapView, let d = drag else { return }
        let v = convert(event.locationInWindow, from: nil)
        let c = map.convert(CGPoint(x: d.from.x + v.x - d.start.x, y: d.from.y + v.y - d.start.y), toCoordinateFrom: self)
        last = c
        onChange?(d.id, c)
    }

    override func mouseUp(with event: NSEvent) {
        if let d = drag, let c = last { onEnd?(d.id, c) }
        if drag != nil { NSCursor.pop() }
        drag = nil; last = nil
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
        var appliedDark: Bool?
        var tileOverlay: MKTileOverlay?
        var annotations: [UUID: ControlPointAnnotation] = [:]
        var lineEnds: [UUID: (LineEndAnnotation, LineEndAnnotation)] = [:]
        /// The marker being ⌘-dragged; its annotation follows the mouse until the drag ends.
        var nudging: UUID?
        var lineKey: [Double] = []
        let pending = PendingAnnotation()
        let predicted = PredictedAnnotation()
        let cursor = CursorAnnotation()
        var warped: [LiveWarpOverlay] = []
        var renderers: [ObjectIdentifier: LiveWarpRenderer] = [:]
        var opacities: [ObjectIdentifier: Double] = [:]
        var uncertainty: UncertaintyOverlay?
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
            case let a as LineEndAnnotation:
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "lineEnd") ?? MKAnnotationView(annotation: a, reuseIdentifier: "lineEnd")
                v.annotation = a
                v.image = Self.lineHandle
                v.isDraggable = true
                v.displayPriority = .required
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
            v.markerTintColor = !a.enabled ? .systemGray : (a.selected ? .systemGreen : (a.isLine ? .systemTeal : .systemBlue))
        }

        static let lineHandle = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            let p = NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2))
            NSColor.white.setFill(); p.fill()
            NSColor.systemTeal.setStroke(); p.lineWidth = 2.5; p.stroke()
            return true
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
                if a.isLine {
                    Task { @MainActor in self.state.moveLine(of: a.pointID, centreTo: LatLon(c)) }
                } else {
                    Task { @MainActor in self.state.moveGeo(of: a.pointID, to: LatLon(c)) }
                }
            }
            if newState == .ending, let a = view.annotation as? LineEndAnnotation {
                let c = a.coordinate
                Task { @MainActor in
                    if a.isEnd { self.state.moveLineEnd(of: a.pointID, to: LatLon(c)) } else { self.state.moveGeo(of: a.pointID, to: LatLon(c)) }
                }
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            switch overlay {
            case let t as MKTileOverlay:
                return MKTileOverlayRenderer(tileOverlay: t)
            case let u as UncertaintyOverlay:
                return UncertaintyRenderer(overlay: u)
            case let w as LiveWarpOverlay:
                let r = LiveWarpRenderer(overlay: w)
                r.alpha = CGFloat(opacities[ObjectIdentifier(w)] ?? 0.7)
                renderers[ObjectIdentifier(w)] = r
                return r
            case let l as ControlLineOverlay:
                let r = MKPolylineRenderer(polyline: l)
                r.strokeColor = l.pending ? .systemOrange : (l.enabled ? .systemTeal : .systemGray)
                r.lineWidth = 4
                r.lineCap = .round
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
        map.nudge.target = { [weak state, weak map, weak c] v in
            guard let state, let map, let c, state.mode == .match else { return nil }
            let candidates = state.points.compactMap { p in c.annotations[p.id].map { (p.id, $0.coordinate) } }
            // The selected point, but only while it's in view: moving one you can't see is a mistake.
            if let id = state.selection.first, let hit = candidates.first(where: { $0.0 == id }),
               map.nudge.bounds.contains(map.convert(hit.1, toPointTo: map.nudge)) { return hit }
            let near = candidates.min { a, b in
                let pa = map.convert(a.1, toPointTo: map.nudge), pb = map.convert(b.1, toPointTo: map.nudge)
                return hypot(pa.x - v.x, pa.y - v.y) < hypot(pb.x - v.x, pb.y - v.y)
            }
            guard let near else { return nil }
            let p = map.convert(near.1, toPointTo: map.nudge)
            return hypot(p.x - v.x, p.y - v.y) <= 80 ? near : nil
        }
        map.nudge.onChange = { [weak state, weak c] id, coord in
            guard let c else { return }
            if c.nudging == nil { c.nudging = id; state?.select(id) }
            c.annotations[id]?.coordinate = coord
        }
        map.nudge.onEnd = { [weak state, weak c] id, coord in
            c?.nudging = nil
            guard let state else { return }
            if state.points.first(where: { $0.id == id })?.isLine == true {
                state.moveLine(of: id, centreTo: LatLon(coord))
            } else {
                state.moveGeo(of: id, to: LatLon(coord))
            }
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
        syncUncertainty(map, c)
        if let f = state.geoFocus, f.token != c.lastFocus {
            c.lastFocus = f.token
            map.setCenter(f.value.coordinate, animated: true)
        }
    }

    private func applyBaseLayer(_ map: MKMapView, _ c: Coordinator) {
        guard c.appliedBase != state.baseLayer || c.appliedDark != state.darkMap else { return }
        c.appliedBase = state.baseLayer
        c.appliedDark = state.darkMap
        map.appearance = NSAppearance(named: state.darkMap ? .darkAqua : .aqua)
        if let t = c.tileOverlay { map.removeOverlay(t); c.tileOverlay = nil }
        switch state.baseLayer {
        case .appleStandard: map.mapType = .standard
        case .appleSatellite: map.mapType = .hybrid
        case .openStreetMap:
            map.mapType = .standard
            let t = OSMTileOverlay(dark: state.darkMap)
            map.insertOverlay(t, at: 0, level: .aboveLabels)
            c.tileOverlay = t
        case .terrain:
            map.mapType = .standard
            let t = HillshadeTileOverlay(dark: state.darkMap)
            map.insertOverlay(t, at: 0, level: .aboveLabels)
            c.tileOverlay = t
        }
    }

    private func syncControlPoints(_ map: MKMapView, _ c: Coordinator) {
        let points = state.showMarkers || state.mode == .match ? state.points : []
        var seen = Set<UUID>()
        for (i, p) in points.enumerated() {
            seen.insert(p.id)
            let where_ = Self.markerPosition(p)
            let a = c.annotations[p.id] ?? {
                let a = ControlPointAnnotation(id: p.id)
                a.coordinate = where_
                c.annotations[p.id] = a
                map.addAnnotation(a)
                return a
            }()
            let selected = state.selection.contains(p.id)
            if c.nudging != p.id, a.coordinate.latitude != where_.latitude || a.coordinate.longitude != where_.longitude { a.coordinate = where_ }
            if a.number != i + 1 || a.selected != selected || a.enabled != p.enabled || a.isLine != p.isLine {
                a.number = i + 1; a.selected = selected; a.enabled = p.enabled; a.isLine = p.isLine
                if let v = map.view(for: a) as? MKMarkerAnnotationView { c.configure(v, for: a) }
            }
            if let end = p.lineEnd {
                let (h0, h1) = c.lineEnds[p.id] ?? {
                    let h = (LineEndAnnotation(id: p.id, isEnd: false), LineEndAnnotation(id: p.id, isEnd: true))
                    c.lineEnds[p.id] = h
                    map.addAnnotations([h.0, h.1])
                    return h
                }()
                if h0.coordinate.latitude != p.geo.lat || h0.coordinate.longitude != p.geo.lon { h0.coordinate = p.geo.coordinate }
                if h1.coordinate.latitude != end.lat || h1.coordinate.longitude != end.lon { h1.coordinate = end.coordinate }
            }
        }
        for (id, a) in c.annotations where !seen.contains(id) {
            map.removeAnnotation(a)
            c.annotations[id] = nil
        }
        for (id, h) in c.lineEnds where !points.contains(where: { $0.id == id && $0.isLine }) {
            map.removeAnnotations([h.0, h.1])
            c.lineEnds[id] = nil
        }

        // The stretches themselves, plus the one being added.
        var stretches: [ControlLineOverlay] = points.compactMap { p in
            guard let end = p.lineEnd else { return nil }
            let l = ControlLineOverlay(coordinates: [p.geo.coordinate, end.coordinate], count: 2)
            l.enabled = p.enabled
            return l
        }
        if let a = state.pendingGeo, let b = state.pendingLineEnd {
            let l = ControlLineOverlay(coordinates: [a.coordinate, b.coordinate], count: 2)
            l.pending = true
            stretches.append(l)
        }
        let key = stretches.flatMap { l -> [Double] in
            var cs = [CLLocationCoordinate2D](repeating: .init(), count: 2)
            l.getCoordinates(&cs, range: NSRange(location: 0, length: 2))
            return cs.flatMap { [$0.latitude, $0.longitude] } + [l.enabled ? 1 : 0, l.pending ? 1 : 0]
        }
        guard key != c.lineKey else { return }
        c.lineKey = key
        map.removeOverlays(map.overlays.filter { $0 is ControlLineOverlay })
        map.addOverlays(stretches, level: .aboveLabels)
    }

    /// Points sit where they were clicked; road lines' markers sit mid-stretch.
    static func markerPosition(_ p: ControlPoint) -> CLLocationCoordinate2D {
        guard let end = p.lineEnd else { return p.geo.coordinate }
        return Sweref99TM.unproject((Sweref99TM.project(p.geo) + Sweref99TM.project(end)) * 0.5).coordinate
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
                if p.isLine {
                    // From the line to where the model puts the old road: straight across the road.
                    let tip = g.imageToSweref(p.image)
                    let foot = tip - d.residualVector
                    lines.append(ResidualLine(coordinates: [Sweref99TM.unproject(foot).coordinate, Sweref99TM.unproject(tip).coordinate], count: 2))
                } else {
                    let from = Sweref99TM.project(p.geo)
                    let to = Sweref99TM.unproject(from + d.residualVector)
                    lines.append(ResidualLine(coordinates: [p.geo.coordinate, to.coordinate], count: 2))
                }
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

    /// Above the old maps, below the residual arrows.
    private func syncUncertainty(_ map: MKMapView, _ c: Coordinator) {
        let wanted = state.displayedUncertainty
        guard wanted !== c.uncertainty else { return }
        if let old = c.uncertainty { map.removeOverlay(old) }
        c.uncertainty = wanted
        if let wanted {
            let base = (c.tileOverlay == nil ? 0 : 1) + c.warped.count
            map.insertOverlay(wanted, at: base, level: .aboveLabels)
        }
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
            if let u = c.uncertainty { map.removeOverlay(u); c.uncertainty = nil } // re-added on top by syncUncertainty
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
