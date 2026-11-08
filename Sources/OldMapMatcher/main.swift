import AppKit
import SwiftUI

struct OldMapMatcherApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Old Map Matcher") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1000, minHeight: 650)
                // Pick up points added on the iPhone whenever the app comes to the front.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    state.mergePhoneEdits()
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Project Folder…") { state.chooseWorkspace() }
                    .keyboardShortcut("o")
                Button("Rescan Images") { state.rescan() }
                    .keyboardShortcut("r")
                Divider()
                Button(state.exporting ? "Exporting for iPhone…" : "Export for iPhone") { state.exportForPhone() }
                    .keyboardShortcut("e")
                    .disabled(state.exporting)
            }
            CommandMenu("Mode") {
                Button("Match Points") { state.mode = .match }
                    .keyboardShortcut("1")
                Button("Explore Layers") { state.mode = .explore }
                    .keyboardShortcut("2")
            }
        }
    }
}

// Ensure a proper foreground app with a Dock icon and menu bar even when launched from the terminal.
NSApplication.shared.setActivationPolicy(.regular)
OldMapMatcherApp.main()
