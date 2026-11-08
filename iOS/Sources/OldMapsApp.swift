import MapLayers
import SwiftUI

@main
struct OldMapsApp: App {
    @StateObject private var store = LayerStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onChange(of: scenePhase) { _, phase in
                    // Pick up a new export from the Mac whenever the app comes to the front.
                    if phase == .active { store.refresh() }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: LayerStore
    @State private var showLayers = false
    @State private var choosingFolder = false
    /// The map a point is being added to; nil when not adding.
    @State private var adding: String?
    @State private var choosingMap = false

    var body: some View {
        ZStack(alignment: .bottom) {
            MapScreen(store: store)
                .ignoresSafeArea()
            if adding != nil {
                Crosshair()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            }

            VStack(spacing: 10) {
                if let s = store.status {
                    Text(s).font(.footnote).padding(8).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                if store.maps.isEmpty {
                    emptyState
                } else if let m = adding {
                    AddPointPanel(map: m) { adding = nil }
                } else {
                    fadeBar
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showLayers) {
            LayerSheet(choosingFolder: $choosingFolder)
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Add a point to which map?", isPresented: $choosingMap, titleVisibility: .visible) {
            ForEach(addableMaps) { m in Button(m.name) { adding = m.name } }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { store.setFolder(url) }
        }
    }

    /// Old ↔ modern crossfade, the main control while walking.
    private var fadeBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "map").foregroundStyle(.secondary)
            Slider(value: $store.fade, in: 0...1)
            Image(systemName: "scroll").foregroundStyle(.secondary)
            Button { startAdding() } label: {
                Image(systemName: "mappin.and.ellipse").font(.title3)
            }
            Button { showLayers = true } label: {
                Image(systemName: "square.3.layers.3d").font(.title3)
            }
            .overlay(alignment: .topTrailing) {
                if store.loading { ProgressView().controlSize(.mini).offset(x: 8, y: -8) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
    }

    /// Visible maps that can take new points.
    private var addableMaps: [FieldMap] { store.editableMaps.filter { store.visible.contains($0.name) } }

    private func startAdding() {
        let maps = addableMaps
        if maps.isEmpty {
            store.notify(store.editableMaps.isEmpty
                ? "Export again from the Mac app first: older exports don't include the points needed for adding."
                : "Show the map you want to add a point to (Layers), then try again.")
        } else if maps.count == 1 {
            adding = maps[0].name
        } else if let e = store.editMap, maps.contains(where: { $0.name == e }), store.showPoints {
            adding = e
        } else {
            choosingMap = true
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No maps yet").font(.headline)
            Text("On the Mac, choose File › Export for iPhone. Then pick the “Old Map Matcher” folder in iCloud Drive here.")
                .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Choose Folder…") { choosingFolder = true }
                .buttonStyle(.borderedProminent)
                .disabled(store.loading)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct LayerSheet: View {
    @EnvironmentObject var store: LayerStore
    @Binding var choosingFolder: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Old maps (top first)") {
                    ForEach(store.maps) { m in row(m) }
                }
                if !store.editableMaps.isEmpty {
                    Section("Points") {
                        ForEach(store.editableMaps) { m in
                            NavigationLink {
                                PointsList(map: m.name) { dismiss() }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.name).lineLimit(1).truncationMode(.middle)
                                    let pending = store.pendingCount(for: m.name)
                                    Text("\(store.points(for: m.name).count) points" + (pending > 0 ? " · \(pending) waiting for the Mac" : ""))
                                        .font(.caption).foregroundStyle(pending > 0 ? .orange : .secondary)
                                }
                            }
                        }
                    }
                }
                Section("Modern map") {
                    Picker("Base map", selection: $store.baseMap) {
                        ForEach(BaseMap.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                Section {
                    LabeledContent("Folder", value: store.folderName ?? "None")
                    if let d = store.exported {
                        LabeledContent("Exported", value: d.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button("Check for New Export") { store.refresh() }.disabled(store.loading)
                    Button("Choose Folder…") {
                        dismiss()
                        // The picker can't open while the sheet is still closing.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { choosingFolder = true }
                    }
                } footer: {
                    Text("Add points on the Mac, then File › Export for iPhone. New exports are picked up when the app opens.")
                }
            }
            .navigationTitle("Layers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func row(_ m: FieldMap) -> some View {
        let on = Binding(get: { store.visible.contains(m.name) },
                         set: { if $0 { store.visible.insert(m.name) } else { store.visible.remove(m.name) } })
        let opacity = Binding(get: { store.opacity[m.name] ?? 0.8 }, set: { store.opacity[m.name] = $0 })
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: on) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.name).lineLimit(1).truncationMode(.middle)
                    Text(subtitle(m)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if on.wrappedValue {
                Slider(value: opacity, in: 0.1...1)
            }
        }
    }

    private func subtitle(_ m: FieldMap) -> String {
        var s = "\(m.points) points"
        if let e = m.errorMetres { s += String(format: " · ±%.0f m", e) }
        return s
    }
}
