import CoreLocation
import MapKit
import MapLayers
import MapMatchCore
import SwiftUI

/// Adding a point in three steps: put the cross on the feature on the old map, say where it is today
/// (GPS or the cross), then name and save it.
struct AddPointPanel: View {
    @EnvironmentObject var store: LayerStore
    let map: String
    let done: () -> Void

    enum Step { case old, today, confirm }
    @State private var step = Step.old
    @State private var image: Vec2?
    @State private var name = ""
    @State private var gpsAccuracy: Double?
    @State private var savedFade: Double?
    @StateObject private var gps = GPSAverager()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(instructions).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch step {
            case .old:
                HStack {
                    Button("Cancel", role: .cancel) { finish() }
                    Spacer()
                    Button("Mark old feature") { markOld() }.buttonStyle(.borderedProminent)
                }
            case .today:
                if gps.running {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Measuring… \(gps.fixes) fixes" + (gps.accuracy.map { String(format: ", ±%.0f m", $0) } ?? ""))
                            .font(.subheadline.monospacedDigit())
                    }
                }
                if let f = gps.failure { Text(f).font(.footnote).foregroundStyle(.red) }
                HStack {
                    Button("Back") { back() }
                    Spacer()
                    Button("Cross") { markToday(store.mapCenter?(), accuracy: nil) }
                        .buttonStyle(.bordered)
                        .disabled(gps.running)
                    Button { gps.start() } label: { Label("I'm at it", systemImage: "location.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(gps.running)
                }
            case .confirm:
                TextField("Name (optional), e.g. Fruängens gård", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                HStack {
                    Button("Back") { back() }
                    Spacer()
                    Button("Save point") { save() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .onChange(of: gps.result?.latitude) { _, _ in
            if let r = gps.result { markToday(r, accuracy: gps.accuracy) }
        }
        .onAppear {
            // Show the old map clearly while finding the feature.
            savedFade = store.fade
            store.fade = 1
        }
        .onDisappear { gps.stop() }
    }

    private var title: String {
        switch step {
        case .old: "1 · Find it on the old map"
        case .today: "2 · Where is it today?"
        case .confirm: "3 · Save the point"
        }
    }

    private var instructions: String {
        switch step {
        case .old:
            return "Move the map until the cross is on the feature, on the \(map) layer."
        case .today:
            return "Stand at it and tap \u{201C}I'm at it\u{201D} to use GPS, or move the cross onto it on the modern map and tap \u{201C}Cross\u{201D}."
        case .confirm:
            guard let o = store.draftOld, let n = store.draftNew else { return "" }
            let off = CLLocation(latitude: o.latitude, longitude: o.longitude)
                .distance(from: CLLocation(latitude: n.latitude, longitude: n.longitude))
            var s = String(format: "The overlay is %.0f m off here.", off)
            if let a = gpsAccuracy { s += String(format: " GPS: ±%.0f m.", a) }
            return s + " The point is used after the Mac merges it and you export again."
        }
    }

    private func markOld() {
        guard let c = store.mapCenter?(), let p = store.imagePoint(in: map, at: c) else {
            store.notify("The cross isn't on the \(map) map.")
            return
        }
        image = p
        store.draftOld = c
        store.fade = 0.35 // let the modern map show through
        step = .today
    }

    private func markToday(_ c: CLLocationCoordinate2D?, accuracy: Double?) {
        guard let c else { return }
        store.draftNew = c
        gpsAccuracy = accuracy
        step = .confirm
    }

    private func back() {
        gps.stop()
        switch step {
        case .old: break
        case .today:
            store.draftOld = nil
            store.fade = 1
            step = .old
        case .confirm:
            store.draftNew = nil
            step = .today
        }
    }

    private func save() {
        guard let image, let n = store.draftNew else { return }
        store.addPoint(to: map, image: image, today: n, name: name.trimmingCharacters(in: .whitespaces))
        store.editMap = map
        store.showPoints = true
        store.notify("Point added to \(map). Open the Mac app to merge it.")
        finish()
    }

    private func finish() {
        gps.stop()
        store.draftOld = nil
        store.draftNew = nil
        if let f = savedFade { store.fade = f }
        done()
    }
}

/// A cross at the centre of the screen, which is the centre of the map.
struct Crosshair: View {
    var body: some View {
        ZStack {
            Circle().stroke(.white, lineWidth: 4).frame(width: 30, height: 30)
            Circle().stroke(.red, lineWidth: 2).frame(width: 30, height: 30)
            ForEach(0..<4) { i in
                Rectangle().fill(.red).frame(width: 2, height: 12)
                    .offset(y: -21)
                    .rotationEffect(.degrees(Double(i) * 90))
            }
        }
        .allowsHitTesting(false)
        .shadow(color: .black.opacity(0.3), radius: 1)
    }
}

/// A map's points: untick or delete them, see how well each agrees with the others.
struct PointsList: View {
    @EnvironmentObject var store: LayerStore
    @Environment(\.dismiss) private var dismiss
    let map: String
    let closeSheet: () -> Void

    var body: some View {
        let points = store.points(for: map)
        let fit = store.fits[map]
        List {
            Section {
                Toggle("Show points on the map", isOn: Binding(
                    get: { store.showPoints && store.editMap == map },
                    set: { store.showPoints = $0; if $0 { store.editMap = map } }))
            } footer: {
                if store.pendingCount(for: map) > 0 {
                    Text("\(store.pendingCount(for: map)) change(s) made here are waiting for the Mac. They're merged when the Mac app next opens, and reach this map after the next export.")
                }
            }
            Section {
                ForEach(Array(points.enumerated()), id: \.element.id) { i, p in
                    row(i, p, fit)
                        .swipeActions {
                            Button("Delete", role: .destructive) { store.deletePoint(p.id, in: map) }
                        }
                }
            } header: {
                Text("\(points.filter(\.enabled).count) of \(points.count) points in use")
            } footer: {
                Text("“Left out” is how far the point is from where the others predict it. A large value can mean a misidentified feature: untick it rather than delete it, so it can be brought back. Tap a point to show it on the map.")
            }
        }
        .navigationTitle(map)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ i: Int, _ p: ControlPoint, _ fit: GeoReference?) -> some View {
        let pending = store.isPending(p.id, in: map)
        let loo = fit?.diagnostics[p.id]?.leaveOneOut
        let rms = fit?.rmsLeaveOneOut
        return HStack {
            Button {
                store.editMap = map
                store.showPoints = true
                store.focusMap?(p.geo.coordinate)
                closeSheet()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name.isEmpty ? "Point \(i + 1)" : "\(i + 1) · \(p.name)").lineLimit(1)
                        .foregroundStyle(p.enabled ? .primary : .secondary)
                    Group {
                        if pending {
                            Text("Changed on this phone").foregroundStyle(.orange)
                        } else if let loo, loo.isFinite {
                            Text(String(format: "Left out: %.0f m", loo))
                                .foregroundStyle(rms.map { loo > 2 * $0 } == true ? .red : .secondary)
                        }
                    }
                    .font(.caption)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Toggle("Use", isOn: Binding(get: { p.enabled }, set: { store.setEnabled($0, point: p.id, in: map) }))
                .labelsHidden()
        }
    }
}
