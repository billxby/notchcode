// The bridge between SwiftUI (declarative) and AppKit (imperative).
//
// v0.7 has two visual modes:
//
//   - Pill:   resting strip — cutout + shoulder padding. Shoulders extend into
//             the menubar, revealing the StatusIndicator. Always present.
//   - Panel:  large rounded rectangle — the popover, user-initiated by tap.
//
// The expansion is the same NSPanel resizing — NOT an NSPopover. This
// preserves the "notch unfurling" feel and avoids Apple's popover chrome.
// SwiftUI inside NotchView crossfades between two shape backgrounds
// (NotchShape ↔ RoundedRectangle) as the panel grows/shrinks.

import AppKit
import SwiftUI

@Observable
@MainActor
final class NotchOverlay {
    static let shared = NotchOverlay()

    enum DisplayMode {
        case pill
        /// Auto-engaged when aggregate status is `.waiting` and the user
        /// hasn't already expanded into a larger mode. Slightly wider/taller
        /// than `.pill` to fit a single "Open terminal" action so the user
        /// can jump straight to the blocked Claude Code session — the
        /// terminal owns the permission prompt itself.
        case waitingPill
        case panel
        /// v0.9 — inline settings page. Same shape as `.panel` but routes
        /// to the settings UI. Entered by tapping the usage badge, exited
        /// by the Done button or clicking outside.
        case settings
        /// v0.95 — per-conversation drill-down. Same frame as `.panel`,
        /// renders one session's chronological message list. The target
        /// session is in `selectedSessionId`. Entered by tapping a row in
        /// `.panel`; exited via the back button or outside-click.
        case sessionDetail
    }

    /// Current visual state. Read by NotchView for layout branching; mutated
    /// only by `togglePanel()` / `setMediumPrompt(...)` so the panel frame and
    /// SwiftUI body stay in sync.
    private(set) var displayMode: DisplayMode = .pill

    /// v0.95 — the session being shown in `.sessionDetail`. Decoupled from
    /// `displayMode` so it survives transient mode changes (e.g., a
    /// permission prompt taking over and then dismissing).
    private(set) var selectedSessionId: String? = nil

    private var panel: NotchPanel?
    private var hosting: NSHostingView<NotchView>?
    private var pillFrame: NSRect = .zero
    private var waitingPillFrame: NSRect = .zero
    private var panelFrame: NSRect = .zero
    private var settingsFrame: NSRect = .zero
    private var globalClickMonitor: Any?

    private init() {}

    /// Mount the panel on the primary screen. Call once at app launch.
    func show() {
        guard panel == nil else { return }
        guard let screen = NSScreen.main else { return }

        // v0.9: support non-notch Macs by synthesizing a virtual notch in
        // the same screen position the hardware one would occupy. The user
        // gets the same pill UX, just without the hardware indent behind it.
        let cutout: NSRect
        if let hardware = screen.notchFrame {
            cutout = hardware
        } else {
            let virtualWidth: CGFloat = 200
            let menubarHeight = screen.frame.maxY - screen.visibleFrame.maxY
            let height = max(menubarHeight, 32)
            cutout = NSRect(
                x: screen.frame.midX - virtualWidth / 2,
                y: screen.frame.maxY - height,
                width: virtualWidth,
                height: height
            )
            print("[Notchcode] No hardware notch — using a virtual one at \(cutout).")
        }

        // Pill frame — cutout plus shoulder padding so the concave shoulders
        // (and the StatusIndicator drawn at the leading edge) are visible
        // alongside the menubar.
        let shoulderPad: CGFloat = 80
        pillFrame = NSRect(
            x: cutout.minX - shoulderPad / 2,
            y: cutout.minY,
            width: cutout.width + shoulderPad,
            height: cutout.height
        )

        // Waiting-pill frame — same width as the resting pill (so it doesn't
        // sweep out across the menubar), just drops downward to make room for
        // a centered "Open terminal" button below the indicator. Reads as
        // "the notch grew a chin", not "the notch grew an arm."
        let waitingPillExtraHeight: CGFloat = 36
        waitingPillFrame = NSRect(
            x: pillFrame.minX,
            y: pillFrame.maxY - (pillFrame.height + waitingPillExtraHeight),
            width: pillFrame.width,
            height: pillFrame.height + waitingPillExtraHeight
        )

        // Full popover panel — large rounded rectangle centered horizontally,
        // top-aligned with the hardware notch top edge.
        let panelWidth: CGFloat = 560
        let panelHeight: CGFloat = 440
        let topY = cutout.maxY
        panelFrame = NSRect(
            x: screen.frame.midX - panelWidth / 2,
            y: topY - panelHeight,
            width: panelWidth,
            height: panelHeight
        )

        // Settings page frame — same width as the panel, slightly taller
        // to fit the plan picker, threshold slider, and hook controls
        // without scrolling on first paint.
        let settingsWidth: CGFloat = 560
        let settingsHeight: CGFloat = 520
        settingsFrame = NSRect(
            x: screen.frame.midX - settingsWidth / 2,
            y: topY - settingsHeight,
            width: settingsWidth,
            height: settingsHeight
        )

        let p = NotchPanel(contentRect: pillFrame)

        let host = NSHostingView(
            rootView: NotchView(engine: SessionStateEngine.shared, overlay: self)
        )
        host.frame = NSRect(origin: .zero, size: pillFrame.size)
        // Without autoresizingMask the hosting view stays stuck at its initial
        // size while the panel grows underneath it.
        host.autoresizingMask = [.width, .height]
        p.contentView = host

        p.setFrame(pillFrame, display: true)
        p.orderFrontRegardless()

        self.panel = p
        self.hosting = host

        observeScreenChanges()
    }

    // MARK: - Screen reconfiguration (v0.9)

    private var screenObserver: NSObjectProtocol?

    /// Tear down and re-mount whenever displays change — lid close/open,
    /// monitor plug/unplug, resolution change, etc. Without this the panel
    /// would float at the OLD screen's coordinates after the user docks/undocks.
    private func observeScreenChanges() {
        if screenObserver != nil { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                NotchOverlay.shared.remount()
            }
        }
    }

    /// Drop the existing panel and re-create it against the (possibly new)
    /// primary screen geometry. Preserves displayMode across the remount.
    private func remount() {
        let preservedMode = displayMode
        hide()
        displayMode = .pill   // show() sets up in pill geometry
        show()
        if preservedMode != .pill {
            setMode(preservedMode)
        }
    }

    func hide() {
        stopMonitoringOutsideClicks()
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Mode transitions

    /// Tap on the notch surface — toggles between the resting pill (or its
    /// waitingPill variant) and the full popover.
    func togglePanel() {
        let newMode: DisplayMode = (displayMode == .panel) ? .pill : .panel
        setMode(newMode)
    }

    /// Auto-driven by NotchView when the aggregate status flips to/from
    /// `.waiting` while the user is at rest. Only transitions between
    /// `.pill` and `.waitingPill` — leaves panel/settings/drill-down alone
    /// so the user's explicit expansion isn't yanked back.
    func setWaitingExpansion(_ on: Bool) {
        switch displayMode {
        case .pill where on:         setMode(.waitingPill)
        case .waitingPill where !on: setMode(.pill)
        default: break
        }
    }

    /// v0.7 redux: brake first engages → expand once so the banner can't be
    /// missed.
    func expandForBrake() {
        if displayMode != .panel { setMode(.panel) }
    }

    /// v0.9: open the inline settings page. Click outside or tap Done to close.
    func showSettings() {
        if displayMode != .settings { setMode(.settings) }
    }

    /// Close settings, return to pill.
    func dismissSettings() {
        if displayMode == .settings { setMode(.pill) }
    }

    /// v0.95 — drill into a session from the panel row tap.
    func showSessionDetail(id: String) {
        selectedSessionId = id
        if displayMode != .sessionDetail { setMode(.sessionDetail) }
    }

    /// v0.95 — back button on the drill-down view. Returns to the session
    /// list (`.panel`) rather than the pill so the user lands where they
    /// came from.
    func dismissSessionDetail() {
        if displayMode == .sessionDetail { setMode(.panel) }
    }

    private func setMode(_ newMode: DisplayMode) {
        guard newMode != displayMode else { return }
        displayMode = newMode

        let target: NSRect = {
            switch newMode {
            case .pill:          return pillFrame
            case .waitingPill:   return waitingPillFrame
            case .panel:         return panelFrame
            case .settings:      return settingsFrame
            case .sessionDetail: return panelFrame   // same shape, different content
            }
        }()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel?.animator().setFrame(target, display: true)
        }

        // Outside-click dismiss for the panel-family modes. The permission
        // prompt is modal-flavored — must be resolved via the buttons.
        if newMode == .panel || newMode == .settings || newMode == .sessionDetail {
            startMonitoringOutsideClicks()
        } else {
            stopMonitoringOutsideClicks()
        }
    }

    // MARK: - Outside-click dismiss

    /// Global event monitor fires only for events going to OTHER apps — i.e.,
    /// clicks anywhere outside our own panel. Perfect for "click outside to
    /// dismiss" without intercepting clicks inside the panel (which need to
    /// reach the buttons SwiftUI renders).
    private func startMonitoringOutsideClicks() {
        stopMonitoringOutsideClicks()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                switch self.displayMode {
                case .panel:         self.togglePanel()
                case .settings:      self.dismissSettings()
                case .sessionDetail: self.setMode(.pill)
                default:             break
                }
            }
        }
    }

    private func stopMonitoringOutsideClicks() {
        if let m = globalClickMonitor {
            NSEvent.removeMonitor(m)
            globalClickMonitor = nil
        }
    }
}
