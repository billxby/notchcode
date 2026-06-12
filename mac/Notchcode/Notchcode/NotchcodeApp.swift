// The @main entry point. SwiftUI's `App` protocol is the modern alternative
// to AppKit's NSApplicationDelegate — you describe scenes (windows, menubar
// items) declaratively and the framework wires up the lifecycle.
//
// We do NOT use a WindowGroup because Notchcode is a background agent: there
// is no main window to open. There's no menubar icon either — the app lives
// ENTIRELY on the notch (settings, hook install, quit are all inside the
// notch UI). The App protocol requires at least one Scene, so we declare a
// MenuBarExtra that is never inserted (`isInserted: .constant(false)`); the
// real UI is a borderless NSPanel mounted imperatively in init().

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
        ClaudeProjectsWatcher.shared.start(engine: SessionStateEngine.shared)

        // Codex transcript watcher. The Codex analog of ClaudeProjectsWatcher —
        // tails ~/.codex/sessions/**/rollout-*.jsonl for project, messages,
        // tokens, and cost. Harmless no-op until the user runs Codex.
        CodexSessionsWatcher.shared.start(engine: SessionStateEngine.shared)

        // Hook HTTP server (v0.3). Receives Claude Code's lifecycle events
        // (PreToolUse, PostToolUse, UserPromptSubmit, Stop) via curl POSTs
        // installed in ~/.claude/settings.json. Sub-second precision; carries
        // tool names and the "waiting on user" signal that file mtimes can't.
        HookServer.shared.start(engine: SessionStateEngine.shared)

        // v0.8: detect whether Notchcode's hook entries are wired into
        // ~/.claude/settings.json. Drives the panel empty-state hint and the
        // settings page's integration section.
        HookInstaller.shared.refresh()

        // Notification banners for "an agent is blocked on you." Sets the
        // delegate and requests permission up front so the first real waiting
        // event can post immediately.
        Notifier.shared.bootstrap()
    }

    var body: some Scene {
        // Placeholder scene, never shown. The App protocol demands a Scene,
        // but every real surface (sessions, settings, hook install, quit)
        // lives on the notch — a menubar icon would be a second, redundant
        // home. `isInserted: .constant(false)` keeps the NSStatusItem out
        // of the menubar entirely.
        MenuBarExtra(
            "Notchcode",
            systemImage: "circle.dotted",
            isInserted: .constant(false)
        ) {
            EmptyView()
        }
    }
}
