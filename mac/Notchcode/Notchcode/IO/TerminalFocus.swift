// Bring the *specific* terminal window where Claude is waiting to the front,
// not just any window of the terminal app.
//
// macOS's `NSRunningApplication.activate(...)` only knows about bundle IDs,
// so when a user has three iTerm windows open it picks "most recent" — which
// is rarely the one Claude is asking for permission in. To target the right
// window we use the Accessibility API: enumerate the app's windows, match by
// title against the project name, then raise the match.
//
// Requires Accessibility permission (System Settings → Privacy & Security →
// Accessibility → Notchcode). If permission is missing or no window matches,
// we degrade gracefully to the old "just activate the app" behavior — every
// caller still gets the app brought to the front, just maybe not the precise
// window.

import AppKit
import ApplicationServices

@MainActor
enum TerminalFocus {

    /// Outcome of a focus attempt. Mostly for diagnostics / future UI ("we
    /// couldn't find the exact window — grant Accessibility?"), and so the
    /// hook caller can decide whether to also pop the panel as a fallback.
    enum Result {
        /// Found a window whose title matched and raised it.
        case raisedWindow(title: String)
        /// App brought forward but no specific window was targeted. The
        /// `reason` says why we didn't drill deeper.
        case activatedAppOnly(reason: Fallback)
        /// No running app for the given bundle ID — nothing to do.
        case appNotRunning
    }

    enum Fallback {
        case noAccessibilityPermission
        case axQueryFailed
        case noTitleMatch
    }

    /// Focus the terminal window most likely to belong to `projectHint`.
    /// `projectHint` is typically `Session.project` (the cwd basename) —
    /// case-insensitive substring match against each window's AX title.
    @discardableResult
    static func focus(bundleID: String, projectHint: String) -> Result {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return .appNotRunning
        }

        // Activate the app first. Two reasons: (1) AXRaise on a window of an
        // inactive app sometimes no-ops, (2) if AX isn't granted, the user
        // still gets the app brought forward.
        app.activate(options: [.activateAllWindows])

        guard isTrusted() else {
            return .activatedAppOnly(reason: .noAccessibilityPermission)
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        let copyStatus = AXUIElementCopyAttributeValue(
            axApp, kAXWindowsAttribute as CFString, &windowsRef
        )
        guard copyStatus == .success, let windows = windowsRef as? [AXUIElement] else {
            return .activatedAppOnly(reason: .axQueryFailed)
        }

        let needle = projectHint.lowercased()
        guard !needle.isEmpty else {
            return .activatedAppOnly(reason: .noTitleMatch)
        }

        for window in windows {
            guard let title = windowTitle(window) else { continue }
            if title.lowercased().contains(needle) {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                return .raisedWindow(title: title)
            }
        }

        return .activatedAppOnly(reason: .noTitleMatch)
    }

    /// Whether Notchcode has been granted Accessibility permission. Cheap
    /// to call; backs both the focus path and the Settings status row.
    static func isTrusted() -> Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    /// Open the Accessibility settings pane scrolled to Notchcode's row.
    /// macOS doesn't expose a "request AX" API the way it does for camera —
    /// `AXIsProcessTrustedWithOptions(prompt: true)` once showed a dialog,
    /// but recent macOS versions silently 404 if the entry isn't already
    /// present, so we deep-link to the pane and let the user toggle it.
    static func openAccessibilitySettings() {
        // The system-prompt option still nudges macOS to add Notchcode to
        // the list if it isn't there yet — required before the user can
        // toggle it on. After that we open the Settings pane.
        let opts: [String: Bool] = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Private

    private static func windowTitle(_ window: AXUIElement) -> String? {
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success else {
            return nil
        }
        return titleRef as? String
    }
}
