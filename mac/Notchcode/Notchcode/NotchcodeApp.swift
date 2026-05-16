// The @main entry point. SwiftUI's `App` protocol is the modern alternative
// to AppKit's NSApplicationDelegate — you describe scenes (windows, menubar
// items) declaratively and the framework wires up the lifecycle.
//
// We do NOT use a WindowGroup because Notchcode is a background agent: there
// is no main window to open. Instead the only Scene is a MenuBarExtra (the
// little icon in the top-right of the menu bar), and the actual UI lives on a
// borderless NSPanel that we mount imperatively in init().

import SwiftUI
import AppKit

@main
struct NotchcodeApp: App {
    // `init` runs once at process launch, before `body` is queried.
    // We use it to bootstrap the AppKit panel and any background services.
    init() {
        // Single-instance guard: if another copy of Notchcode is already
        // running it owns port 9876 (the HookServer listener). Launching a
        // second copy would race for that port and lose with "Address already
        // in use". Activate the existing instance and exit immediately.
        if let existing = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })
        {
            existing.activate(options: [.activateAllWindows])
            exit(0)
        }

        // Mount the borderless panel that overlays the hardware notch.
        // (See App/NotchOverlay.swift for the AppKit/SwiftUI bridge.)
        NotchOverlay.shared.show()

        // File watcher (v0.2). Coarse "session is alive" signal; bumps
        // lastUpdate on every .jsonl modification.
        ProjectsWatcher.shared.start(engine: SessionStateEngine.shared)

        // Hook HTTP server (v0.3). Receives Claude Code's lifecycle events
        // (PreToolUse, PostToolUse, UserPromptSubmit, Stop) via curl POSTs
        // installed in ~/.claude/settings.json. Sub-second precision; carries
        // tool names and the "waiting on user" signal that file mtimes can't.
        HookServer.shared.start(engine: SessionStateEngine.shared)

        // v0.8: detect whether Notchcode's hook entries are wired into
        // ~/.claude/settings.json. Drives both the menubar action and the
        // panel empty-state hint.
        HookInstaller.shared.refresh()
    }

    var body: some Scene {
        // MenuBarExtra is SwiftUI's wrapper around NSStatusItem. The label
        // and systemImage become the menubar icon; clicking it opens the menu.
        // `.menu` style = classic dropdown (vs `.window` for popovers).
        MenuBarExtra("Notchcode", systemImage: "circle.dotted") {
            MenuBarContent()
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Extracted so we can observe `HookInstaller.shared` and re-render the
/// install/uninstall items based on current state.
private struct MenuBarContent: View {
    @State private var installer = HookInstaller.shared

    var body: some View {
        if installer.isInstalled {
            Button("Reinstall Claude Code hooks") { installer.runInstaller() }
                .disabled(installer.isWorking)
            Button("Remove Claude Code hooks") { installer.runUninstaller() }
                .disabled(installer.isWorking)
        } else {
            Button("Install Claude Code hooks…") { installer.runInstaller() }
                .disabled(installer.isWorking)
        }

        Divider()

        Button("Settings…") {
            NotchOverlay.shared.showSettings()
        }
        .keyboardShortcut(",")

        Divider()
        Button("Quit Notchcode") {
            // NSApplication.shared is the AppKit singleton. terminate(nil)
            // posts the standard quit notification so any cleanup runs.
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")  // ⌘Q while the menu is open
    }
}
