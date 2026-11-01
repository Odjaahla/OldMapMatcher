import AppKit
import SwiftUI

struct OldMapMatcherApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Old Map Matcher") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1000, minHeight: 650)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Project Folder…") { state.chooseWorkspace() }
                    .keyboardShortcut("o")
                Button("Rescan Images") { state.rescan() }
                    .keyboardShortcut("r")
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
