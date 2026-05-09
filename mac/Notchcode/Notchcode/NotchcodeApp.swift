// The @main entry point. SwiftUI's `App` protocol is the modern alternative
// to AppKit's NSApplicationDelegate — you describe scenes (windows, menubar
// items) declaratively and the framework wires up the lifecycle.
//
// We do NOT use a WindowGroup because Notchcode is a background agent: there
// is no main window to open. Instead the only Scene is a MenuBarExtra (the
// little icon in the top-right of the menu bar), and the actual UI lives on a
// borderless NSPanel that we mount imperatively in init().

import SwiftUI

@main
struct NotchcodeApp: App {
    // `init` runs once at process launch, before `body` is queried.
    // We use it to bootstrap the AppKit panel and any background services.
    init() {
        // Mount the borderless panel that overlays the hardware notch.
        // (See App/NotchOverlay.swift for the AppKit/SwiftUI bridge.)
        NotchOverlay.shared.show()

        // Start watching ~/.claude/projects/. The watcher pings the engine on
        // every .jsonl modification; the engine's @Observable state propagates
        // into NotchView automatically.
        ProjectsWatcher.shared.start(engine: SessionStateEngine.shared)
    }

    var body: some Scene {
        // MenuBarExtra is SwiftUI's wrapper around NSStatusItem. The label
        // and systemImage become the menubar icon; clicking it opens the menu.
        // `.menu` style = classic dropdown (vs `.window` for popovers).
        MenuBarExtra("Notchcode", systemImage: "circle.dotted") {
            Button("About Notchcode") {
                // TODO(v0.9): open About window
            }
            Divider()
            Button("Quit Notchcode") {
                // NSApplication.shared is the AppKit singleton. terminate(nil)
                // posts the standard quit notification so any cleanup runs.
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")  // ⌘Q while the menu is open
        }
        .menuBarExtraStyle(.menu)
    }
}
