// Launch-at-login via SMAppService (macOS 13+).
//
// Deliberately NOT mirrored into AppSettings/UserDefaults: the system owns
// this state (System Settings → General → Login Items can flip it behind our
// back), so the single source of truth is `SMAppService.mainApp.status` and
// the settings UI re-reads it on appear — same pattern as the Accessibility
// check in SettingsView.

import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers/unregisters the app as a login item. Throws if the system
    /// refuses (e.g. the user denied it in System Settings); the caller
    /// should re-read `isEnabled` to resync the UI either way.
    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
