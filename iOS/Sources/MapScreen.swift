import MapKit
import MapLayers
import MapMatchCore
import SwiftUI

/// The modern map with the old maps on top, your position and a follow-me button.
struct MapScreen: UIViewRepresentable {
    @ObservedObject var store: LayerStore

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let c = context.coordinator
        let container = UIView()
        let map = MKMapView()
        map.delegate = c
        map.showsUserLocation = true
        map.showsCompass = true
        map.showsScale = true
        map.pointOfInterestFilter = .excludingAll
        map.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(map)

        // Follow me / follow with heading, the same button as in Apple Maps.
        let track = MKUserTrackingButton(mapView: map)
        track.backgroundColor = .systemBackground.withAlphaComponent(0.9)
        track.layer.cornerRadius = 8
        track.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(track)

        NSLayoutConstraint.activate([
            map.topAnchor.constraint(equalTo: container.topAnchor),
            map.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            map.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            map.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            track.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            track.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 60),
            track.widthAnchor.constraint(equalToConstant: 44),
            track.heightAnchor.constraint(equalToConstant: 44),
        ])

        c.map = map
        c.locationManager.requestWhenInUseAuthorization()
        store.mapCenter = { [weak map] in map?.centerCoordinate }
        store.focusMap = { [weak map] coord in
            guard let map else { return }
            let span = min(map.region.span.latitudeDelta, 0.006)
            map.setRegion(MKCoordinateRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span * 2)), animated: true)
        }
        // The map has no size yet; a region set now would be fitted to a zero-sized view (zoomed far out).
        // Read it now, before the map's first region change saves over it.
        let saved = Coordinator.savedRegion
        DispatchQueue.main.async {
            if let r = saved {
                map.setRegion(r, animated: false)
            } else if let f = store.footprint {
                map.setVisibleMapRect(f, edgePadding: UIEdgeInsets(top: 40, left: 20, bottom: 40, right: 20), animated: false)
            }
        }
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {
        let c = context.coordinator
        guard let map = c.map else { return }
        c.applyBaseMap(store.baseMap)

        // Old maps, bottom layer first so the top layer is drawn last.
        let wanted = store.maps.reversed().compactMap { m in store.overlays[m.name] }
        if wanted.map({ ObjectIdentifier($0) }) != c.warped.map({ ObjectIdentifier($0) }) {
            map.removeOverlays(c.warped)
            c.renderers = [:]
            c.warped = wanted
            map.addOverlays(wanted, level: .aboveLabels)
        }
        c.alphas = Dictionary(uniqueKeysWithValues: store.maps.compactMap { m in
            store.overlays[m.name].map { (ObjectIdentifier($0), CGFloat(store.effectiveOpacity(m.name))) }
        })
        for (id, r) in c.renderers {
            if let a = c.alphas[id], abs(r.alpha - a) > 0.001 { r.alpha = a }
        }
        syncMarkers(map, c)
        if store.footprint != nil, !c.didFrameMaps, !c.hadSavedRegion, let f = store.footprint {
            c.didFrameMaps = true
            map.setVisibleMapRect(f, edgePadding: UIEdgeInsets(top: 40, left: 20, bottom: 40, right: 20), animated: true)
        }
    }

    /// Control points of the map being edited (at their position today) and the spots of a point
    /// being added, joined by a line.
    private func syncMarkers(_ map: MKMapView, _ c: Coordinator) {
        var wanted: [PointMarker] = []
        if store.showPoints, let m = store.editMap {
            for (i, p) in store.points(for: m).enumerated() {
                let style: PointMarker.Style = store.isPending(p.id, in: m) ? .pending : (p.enabled ? .normal : .disabled)
                // Road lines sit mid-stretch.
                let at = p.lineEnd.map { CLLocationCoordinate2D(latitude: (p.geo.lat + $0.lat) / 2, longitude: (p.geo.lon + $0.lon) / 2) }
                wanted.append(PointMarker(key: p.id.uuidString, coordinate: at ?? p.geo.coordinate, style: style,
                                          title: (p.name.isEmpty ? "Point \(i + 1)" : p.name) + (p.isLine ? " (road line)" : "")))
            }
        }
        if let o = store.draftOld { wanted.append(PointMarker(key: "draftOld", coordinate: o, style: .draftOld, title: "On the old map")) }
        if let n = store.draftNew { wanted.append(PointMarker(key: "draftNew", coordinate: n, style: .draftNew, title: "Today")) }
        let keys = wanted.map(\.signature)
        if keys != c.markerKeys {
            c.markerKeys = keys
            map.removeAnnotations(map.annotations.filter { $0 is PointMarker })
            map.addAnnotations(wanted)
        }
        let line: [CLLocationCoordinate2D] = [store.draftOld, store.draftNew].compactMap { $0 }
        let lineKey = line.flatMap { [$0.latitude, $0.longitude] }
        if lineKey != c.lineKey {
            c.lineKey = lineKey
            map.removeOverlays(map.overlays.filter { $0 is MKPolyline })
            if line.count == 2 { map.addOverlay(MKPolyline(coordinates: line, count: 2), level: .aboveLabels) }
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var markerKeys: [String] = []
        var lineKey: [Double] = []
        weak var map: MKMapView?
        let locationManager = CLLocationManager()
        var warped: [MKOverlay] = []
        var renderers: [ObjectIdentifier: MKOverlayRenderer] = [:]
        var alphas: [ObjectIdentifier: CGFloat] = [:]
        var appliedBase: BaseMap?
        var tiles: MKTileOverlay?
        var didFrameMaps = false
        /// Frame the maps on first launch only, not over a restored view.
        var hadSavedRegion = Coordinator.savedRegion != nil

        static var savedRegion: MKCoordinateRegion? {
            guard let r = UserDefaults.standard.array(forKey: "region") as? [Double], r.count == 4 else { return nil }
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: r[0], longitude: r[1]),
                                      span: MKCoordinateSpan(latitudeDelta: r[2], longitudeDelta: r[3]))
        }

        func applyBaseMap(_ base: BaseMap) {
            guard let map, base != appliedBase else { return }
            appliedBase = base
            if let tiles { map.removeOverlay(tiles); self.tiles = nil }
            switch base {
            case .appleStandard: map.preferredConfiguration = MKStandardMapConfiguration()
            case .appleMuted: map.preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: .muted)
            case .appleSatellite: map.preferredConfiguration = MKHybridMapConfiguration()
            case .openStreetMap, .terrain:
                map.preferredConfiguration = MKStandardMapConfiguration()
                let t: MKTileOverlay = base == .terrain ? HillshadeTileOverlay() : OSMTileOverlay()
                tiles = t
                map.addOverlay(t, level: .aboveLabels)
                // Keep the old maps above the tiles.
                for w in warped { map.removeOverlay(w); map.addOverlay(w, level: .aboveLabels) }
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            switch overlay {
            case let t as PackedTileOverlay:
                let r = MKTileOverlayRenderer(tileOverlay: t)
                r.alpha = alphas[ObjectIdentifier(t)] ?? 0.8
                renderers[ObjectIdentifier(t)] = r
                return r
            case let t as MKTileOverlay:
                return MKTileOverlayRenderer(tileOverlay: t)
            case let w as WarpedImageOverlay:
                let r = WarpedImageRenderer(overlay: w)
                r.alpha = alphas[ObjectIdentifier(w)] ?? 0.8
                renderers[ObjectIdentifier(w)] = r
                return r
            case let l as MKPolyline:
                let r = MKPolylineRenderer(polyline: l)
                r.strokeColor = .systemRed
                r.lineWidth = 3
                r.lineDashPattern = [6, 4]
                return r
            default:
                return MKOverlayRenderer(overlay: overlay)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let m = annotation as? PointMarker else { return nil }
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: "point") ?? MKAnnotationView(annotation: m, reuseIdentifier: "point")
            v.annotation = m
            v.image = m.style.image
            v.canShowCallout = true
            v.displayPriority = .required
            v.zPriority = m.style == .draftOld || m.style == .draftNew ? .max : .defaultUnselected
            return v
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let r = mapView.region
            UserDefaults.standard.set([r.center.latitude, r.center.longitude, r.span.latitudeDelta, r.span.longitudeDelta],
                                      forKey: "region")
        }
    }
}

final class PointMarker: NSObject, MKAnnotation {
    enum Style { case normal, pending, disabled, draftOld, draftNew }

    let key: String
    let coordinate: CLLocationCoordinate2D
    let style: Style
    let title: String?

    init(key: String, coordinate: CLLocationCoordinate2D, style: Style, title: String) {
        self.key = key; self.coordinate = coordinate; self.style = style; self.title = title
    }

    var signature: String { "\(key)|\(style)|\(coordinate.latitude)|\(coordinate.longitude)" }
}

extension PointMarker.Style {
    /// Small dots that don't hide the old map (purple, so they aren't mistaken for your own blue dot): purple = in the fit, orange = added or changed on the phone,
    /// grey = unticked; red ring = the feature on the old map, green = where it is today.
    var image: UIImage {
        let (fill, ring, size): (UIColor, UIColor, CGFloat) = switch self {
        case .normal: (.systemPurple, .white, 14)
        case .pending: (.systemOrange, .white, 14)
        case .disabled: (.systemGray, .white, 12)
        case .draftOld: (.clear, .systemRed, 22)
        case .draftNew: (.systemGreen, .white, 18)
        }
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            let r = CGRect(x: 2, y: 2, width: size - 4, height: size - 4)
            let path = UIBezierPath(ovalIn: r)
            fill.setFill(); path.fill()
            ring.setStroke(); path.lineWidth = self == .draftOld ? 3 : 2; path.stroke()
        }
    }
}

extension LatLon {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}
