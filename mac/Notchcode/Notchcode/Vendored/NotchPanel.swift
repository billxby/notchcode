// Vendored from MrKai77/DynamicNotchKit (MIT). See CREDITS.md.
//
// NSPanel vs NSWindow: NSPanel is a lightweight floating window. We use it
// because:
//   - .borderless          → no titlebar, traffic-light buttons, or chrome
//   - .nonactivatingPanel  → clicking it doesn't steal focus from your editor
//   - .screenSaver level   → floats ABOVE normal windows, even fullscreen apps
//   - canJoinAllSpaces     → follows you across Mission Control spaces
//
// This is the surface our SwiftUI notch view lives on.

import AppKit

final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,    // standard CoreAnimation-backed drawing
            defer: true            // don't allocate the window server resource
                                   // until we actually show it (cheap init)
        )
        self.hasShadow = false                  // notch shouldn't cast a shadow on the wallpaper
        self.backgroundColor = .clear           // we draw our own black notch shape
        self.isOpaque = false                   // allow transparent regions
        self.level = .screenSaver               // above app windows AND the menubar
        self.collectionBehavior = [
            .canJoinAllSpaces,                  // visible on every Space
            .stationary,                        // don't slide with Mission Control
            .fullScreenAuxiliary                // visible over fullscreen apps
        ]
        self.ignoresMouseEvents = false         // we want clicks (for popover later)
    }

    // Borderless panels are non-key by default; let the notch receive events.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
