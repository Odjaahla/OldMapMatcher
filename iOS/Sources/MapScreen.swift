import MapKit
import MapLayers
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
        if store.footprint != nil, !c.didFrameMaps, !c.hadSavedRegion, let f = store.footprint {
            c.didFrameMaps = true
            map.setVisibleMapRect(f, edgePadding: UIEdgeInsets(top: 40, left: 20, bottom: 40, right: 20), animated: true)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        weak var map: MKMapView?
        let locationManager = CLLocationManager()
        var warped: [MKOverlay] = []
        var renderers: [ObjectIdentifier: MKOverlayRenderer] = [:]
        var alphas: [ObjectIdentifier: CGFloat] = [:]
        var appliedBase: BaseMap?
        var tiles: OSMTileOverlay?
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
            case .openStreetMap:
                map.preferredConfiguration = MKStandardMapConfiguration()
                let t = OSMTileOverlay()
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
            default:
                return MKOverlayRenderer(overlay: overlay)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let r = mapView.region
            UserDefaults.standard.set([r.center.latitude, r.center.longitude, r.span.latitudeDelta, r.span.longitudeDelta],
                                      forKey: "region")
        }
    }
}
