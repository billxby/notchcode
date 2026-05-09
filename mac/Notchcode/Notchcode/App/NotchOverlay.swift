// The bridge between SwiftUI (declarative) and AppKit (imperative).
//
// SwiftUI's `App` / `WindowGroup` can't make a borderless, screen-saver-level
// panel pinned to the notch — that requires AppKit's NSPanel. So we host our
// SwiftUI NotchView inside an NSHostingView, drop that into a NotchPanel, and
// position the panel at NSScreen.main.notchFrame.
//
// Lifecycle:
//   1. App launches → NotchcodeApp.init() calls NotchOverlay.shared.show()
//   2. show() resolves the notch frame, builds the panel, mounts SwiftUI
//   3. Panel is orderedFrontRegardless so it appears on top immediately
//   4. We retain a reference on the singleton so ARC doesn't deallocate it

import AppKit
import SwiftUI

@MainActor
final class NotchOverlay {
    /// Singleton — exactly one notch overlay per app process.
    /// (Multi-monitor support comes in v1.4.)
    static let shared = NotchOverlay()

    private var panel: NotchPanel?

    /// Mount the notch panel on the primary screen. Call once at launch.
    func show() {
        // Guard against double-show (e.g. if init() is called twice in dev).
        guard panel == nil else { return }

        // Resolve where the notch lives. On non-notch Macs notchFrame is nil;
        // for v0.1 we just bail. Later we'll fall back to a fake top-center bar.
        guard
            let screen = NSScreen.main,
            let frame = screen.notchFrame
        else {
            print("[Notchcode] No notch detected on primary screen — overlay skipped.")
            return
        }

        // The hardware cutout dimensions. We INFLATE these because the visible
        // shape needs to extend past the cutout: wider so the concave shoulders
        // peek out either side, taller so the convex bottom drops below the
        // menubar. If the panel were exactly cutout-sized, the entire shape
        // would hide inside the physical hole and you'd see nothing.
        let widthPadding: CGFloat = 60     // total extra width (30pt each side)
        let extraDrop: CGFloat = 40        // how far below the cutout to extend

        let panelFrame = NSRect(
            x: frame.minX - widthPadding / 2,
            y: frame.minY - extraDrop,     // y grows upward; minY moves DOWN
            width: frame.width + widthPadding,
            height: frame.height + extraDrop
        )

        let panel = NotchPanel(contentRect: panelFrame)

        // NSHostingView wraps a SwiftUI view so AppKit can host it as an
        // NSView. This is THE standard SwiftUI ↔ AppKit interop primitive.
        // We pass the shared engine in; SwiftUI auto-tracks @Observable reads.
        let hosting = NSHostingView(
            rootView: NotchView(size: panelFrame.size, engine: SessionStateEngine.shared)
        )
        hosting.frame = NSRect(origin: .zero, size: panelFrame.size)
        panel.contentView = hosting

        // Position in global screen coords. setFrame uses bottom-left origin.
        panel.setFrame(panelFrame, display: true)

        // orderFrontRegardless = "show even if app isn't active." Critical for
        // a background agent (LSUIElement = YES) that never activates.
        panel.orderFrontRegardless()

        self.panel = panel
    }

    /// Tear down — useful for settings changes or quit. Not called in v0.1.
    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
