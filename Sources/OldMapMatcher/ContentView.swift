import MapMatchCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationSplitView {
            LayerList()
                .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } detail: {
            if let doc = state.active {
                VSplitView {
                    VStack(spacing: 0) {
                        ControlBar()
                        Divider()
                        HSplitView {
                            if state.mode == .match {
                                ZStack {
                                    OldMapView(state: state)
                                    if doc.image == nil {
                                        if let e = doc.loadError { Text(e).foregroundStyle(.red).padding() } else { ProgressView() }
                                    }
                                }
                                .frame(minWidth: 300)
                            }
                            ModernMapView(state: state)
                                .frame(minWidth: 300)
                        }
                    }
                    .frame(minHeight: 300, idealHeight: 600)
                    PointsPanel()
                        .frame(minHeight: 120, idealHeight: 170, maxHeight: 400)
                }
            } else {
                VStack(spacing: 12) {
                    Text(state.workspace == nil ? "Open a project folder to begin." : "No map images found in images/.")
                        .foregroundStyle(.secondary)
                    if state.workspace == nil { Button("Open Project Folder…") { state.chooseWorkspace() } }
                }
            }
        }
        .navigationTitle(state.active?.name ?? "Old Map Matcher")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $state.mode) {
                    ForEach(Mode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .help("Match: pair features side by side (⌘1). Explore: stack georeferenced maps on the modern map (⌘2).")
            }
        }
    }
}

/// Sidebar: all maps. In explore mode each row is a layer with visibility and opacity; drag to reorder (top = drawn on top).
struct LayerList: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        List(selection: Binding(get: { state.active?.url }, set: { url in state.activate(state.documents.first { $0.url == url }) })) {
            Section(state.mode == .explore ? "Layers (top first)" : "Maps") {
                ForEach(state.documents) { doc in
                    LayerRow(doc: doc, explore: state.mode == .explore)
                        .tag(doc.url)
                }
                .onMove { state.moveLayers(from: $0, to: $1) }
            }
        }
    }
}

struct LayerRow: View {
    @ObservedObject var doc: MapDocument
    let explore: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if explore {
                Toggle("", isOn: $doc.visible)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(doc.geoRef == nil)
                    .help(doc.geoRef == nil ? "Add at least 2 points in Match mode first" : "Show as layer")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.name).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                if explore && doc.visible {
                    HStack(spacing: 4) {
                        Slider(value: $doc.opacity, in: 0...1).controlSize(.mini)
                        if doc.overlayBusy { ProgressView().controlSize(.mini) }
                    }
                }
            }
        }
        .padding(.vertical, 1)
    }

    var subtitle: String {
        let n = doc.enabledPointCount
        guard n > 0 else { return "no points" }
        var s = "\(n) point\(n == 1 ? "" : "s")"
        if let e = doc.geoRef?.rmsLeaveOneOut { s += String(format: " · ±%.0f m", e) }
        return s
    }
}

struct ControlBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 14) {
            if let doc = state.active {
                ModelPicker(doc: doc)
            }
            Picker("Base map", selection: $state.baseLayer) {
                ForEach(BaseLayer.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(width: 190)
            Toggle("Residuals", isOn: $state.showResiduals)
                .help("Arrows from each clicked point to where the model places it")
            switch state.mode {
            case .match:
                Toggle("Overlay", isOn: $state.showOverlay)
                    .help("Draw the warped old map on top of the modern map")
                    .disabled(state.geoRef == nil)
                Slider(value: $state.overlayOpacity, in: 0...1)
                    .frame(width: 110)
                    .disabled(!state.showOverlay)
                    .help("Overlay opacity")
                Button { state.syncImageToMap() } label: { Label("Align views", systemImage: "viewfinder") }
                    .disabled(state.geoRef == nil)
                    .keyboardShortcut("l", modifiers: .command)
                    .help("Show the old map at the same place and scale as the modern map (⌘L)")
            case .explore:
                Toggle("Points", isOn: $state.showMarkers)
                    .help("Show the active map's control points")
            }
            if state.overlayBusy { ProgressView().controlSize(.small) }
            Spacer()
            if state.mode == .explore {
                Text(state.peeking ? "Showing modern map" : "⌥-drag: correct active map · hold Space: hide layers")
                    .font(.caption)
                    .foregroundStyle(state.peeking ? .orange : .secondary)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

struct ModelPicker: View {
    @ObservedObject var doc: MapDocument

    var body: some View {
        Picker("Model", selection: $doc.kind) {
            ForEach(TransformKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.menu)
        .frame(width: 190)
        .help("Similarity: rotate/scale only. Affine: adds uneven stretch. Thin-plate spline: also smooth local bending.")
    }
}

struct PointsPanel: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Table(state.points, selection: $state.selection) {
                TableColumn("#") { p in Text("\(state.number(of: p.id) ?? 0)").monospacedDigit() }
                    .width(28)
                TableColumn("Name") { p in
                    TextField("feature", text: binding(p.id, \.name, default: ""))
                        .textFieldStyle(.plain)
                }
                TableColumn("Residual") { p in metres(state.geoRef?.diagnostics[p.id]?.residual) }
                    .width(70)
                TableColumn("Left-out error") { p in metres(state.geoRef?.diagnostics[p.id]?.leaveOneOut) }
                    .width(95)
                TableColumn("Use") { p in
                    Toggle("", isOn: binding(p.id, \.enabled, default: true)).labelsHidden()
                }
                .width(34)
            }
            .contextMenu(forSelectionType: ControlPoint.ID.self) { ids in
                Button("Delete") { state.selection = ids; state.deleteSelected() }
            } primaryAction: { ids in
                if let id = ids.first { state.focus(on: id) }
            }
            .onChange(of: state.selection) { _, sel in
                if sel.count == 1, let id = sel.first { state.focus(on: id) }
            }
            Divider()
            if let doc = state.active {
                StatsView(doc: doc)
                    .frame(width: 280)
                    .padding(10)
            }
        }
    }

    /// Flagging single points as outliers is only meaningful once there's redundancy to compare against.
    private var canFlag: Bool { (state.active?.enabledPointCount ?? 0) >= 6 }

    @ViewBuilder func metres(_ v: Double?) -> some View {
        if let v, v.isFinite {
            Text(v < 10 ? String(format: "%.1f m", v) : String(format: "%.0f m", v))
                .monospacedDigit()
                .foregroundStyle(canFlag && v > 3 * (state.geoRef?.rmsLeaveOneOut ?? .infinity) ? .red : .primary)
        } else {
            Text("–").foregroundStyle(.secondary)
        }
    }

    func binding<T>(_ id: UUID, _ key: WritableKeyPath<ControlPoint, T>, default d: T) -> Binding<T> {
        Binding(get: { state.points.first { $0.id == id }?[keyPath: key] ?? d },
                set: { v in
                    guard let doc = state.active, let i = doc.points.firstIndex(where: { $0.id == id }) else { return }
                    doc.points[i][keyPath: key] = v
                })
    }
}

struct StatsView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var doc: MapDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let enabled = doc.enabledPointCount
            Text("\(enabled) point\(enabled == 1 ? "" : "s") in use").font(.headline)
            if let g = doc.geoRef {
                if g.kind != doc.kind {
                    Text("Using \(g.kind.displayName.lowercased()) until there are \(doc.kind.minimumPoints) points.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    GridRow { Text("Fit residual (RMS)"); Text(String(format: "%.1f m", g.rmsResidual)) }
                    GridRow {
                        Text("Left-out error (RMS)")
                        Text(g.rmsLeaveOneOut.map { String(format: "%.1f m", $0) } ?? "needs more points")
                    }
                    if let size = doc.imageSize {
                        let c = size * 0.5
                        GridRow { Text("Scale at centre"); Text(String(format: "%.2f m/px", g.metresPerPixel(at: c))) }
                        GridRow { Text("Map up vs true north"); Text(String(format: "%+.1f°", g.northDeviationDegrees(at: c))) }
                    }
                    if let l = g.lambda { GridRow { Text("Smoothing (auto)"); Text(String(format: "%g", l)) } }
                }
                .font(.callout)
                .monospacedDigit()
                if !doc.modelComparison.isEmpty {
                    Text("Left-out error by model").font(.subheadline).padding(.top, 4)
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                        ForEach(TransformKind.allCases, id: \.self) { k in
                            GridRow {
                                Text(k.displayName)
                                Text(doc.modelComparison[k].map { String(format: "%.1f m", $0) } ?? "–")
                                if k == doc.bestModel {
                                    if k == doc.kind {
                                        Image(systemName: "checkmark").foregroundStyle(.green)
                                    } else {
                                        Button("Use") { doc.kind = k }.controlSize(.small)
                                    }
                                }
                            }
                        }
                    }
                    .font(.callout)
                    .monospacedDigit()
                    .help("Lower is better: how far off each point lands when the model is fitted without it.")
                }
            } else {
                Text("Add at least 2 point pairs to fit the map.").foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            HStack {
                if state.predictedGeo != nil || state.predictedImage != nil {
                    Button("Accept prediction") { state.acceptPrediction() }
                        .keyboardShortcut(.return, modifiers: [])
                        .help("Use the model's predicted location for the other map (↩)")
                }
                if state.pendingImage != nil || state.pendingGeo != nil {
                    Button("Cancel") { state.cancelPending() }.keyboardShortcut(.cancelAction)
                }
                Spacer()
                Button(role: .destructive) { state.deleteSelected() } label: { Image(systemName: "trash") }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(state.selection.isEmpty)
                    .help("Delete selected points (⌘⌫)")
            }
            Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    var hint: String {
        if state.mode == .explore {
            return doc.geoRef == nil
                ? "Add points in Match mode (⌘1) before this map can be shown as a layer."
                : "Option-drag from a feature on the \(doc.name) layer to where it is today to add a point."
        }
        if state.pendingImage != nil { return "Now click the same feature on the modern map." }
        if state.pendingGeo != nil { return "Now click the same feature on the old map." }
        return "Click a feature on either map, then the same feature on the other. Drag markers to adjust."
    }
}
