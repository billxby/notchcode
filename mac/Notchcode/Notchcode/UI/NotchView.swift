// The SwiftUI view inside the notch panel.
//
// v0.7 has two modes matching NotchOverlay.DisplayMode:
//
//   PILL:    resting strip. Shows ONLY the StatusIndicator — no text. The
//   indicator's appearance follows engine.aggregateStatus (gray idle, blue
//   spinner working, pulsing yellow waiting, popping green checkmark done).
//   Tap to open the popover.
//
//   PANEL:   the full popover. Shows active sessions with their current
//   state + recent actions. Click outside (or tap the header) to collapse.
//
// Both share the same NSPanel; what differs is the frame size and the inner
// content. SwiftUI cross-fades between the notch silhouette and the rounded
// rectangle as the panel resizes underneath.

import SwiftUI
import AppKit

struct NotchView: View {
    let engine: SessionStateEngine
    let overlay: NotchOverlay
    @State private var installer = HookInstaller.shared
    @State private var settings = AppSettings.shared

    var body: some View {
        ZStack {
            background

            switch overlay.displayMode {
            case .panel:
                expanded.transition(.opacity)
            case .pill:
                compact.transition(.opacity)
            case .waitingPill:
                waitingCompact.transition(.opacity)
            case .settings:
                SettingsView(overlay: overlay).transition(.opacity)
            case .sessionDetail:
                SessionDetailView(engine: engine, overlay: overlay).transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: overlay.displayMode)
        .animation(.easeInOut(duration: 0.18), value: engine.aggregateStatus)
        .animation(.easeInOut(duration: 0.25), value: engine.brakeEngaged)
        // Brake first engages → auto-expand the panel once so the user can't
        // miss it. Subsequent re-engagements (after dismissal in the same
        // 5h window are suppressed by the engine) don't re-fire this.
        .onChange(of: engine.brakeEngaged) { _, engaged in
            if engaged {
                overlay.expandForBrake()
            }
        }
        // Waiting → auto-expand the resting knob to surface "Open terminal".
        // Only toggles between .pill ↔ .waitingPill — other modes are left
        // alone so an open panel / settings / drill-down isn't yanked back.
        .onChange(of: isWaiting) { _, waiting in
            overlay.setWaitingExpansion(waiting)
        }
    }

    // MARK: - Background shape

    /// Crossfade between the notch silhouette and a rounded rectangle as the
    /// panel resizes. Both shapes fill the available rect, so visually the
    /// black surface stays continuous while the silhouette morphs.
    @ViewBuilder
    private var background: some View {
        ZStack {
            NotchShape()
                .fill(.black)
                .opacity(overlay.displayMode == .pill ? 1 : 0)

            // Expanded silhouette: flat top (flush with screen edge, continuous
            // with the hardware notch above) and only the bottom corners
            // rounded. Reads as "the notch is dropping a sheet downward."
            // Shared by every non-pill mode (`.waitingPill`, `.panel`,
            // `.settings`, `.sessionDetail`) at different frame sizes.
            UnevenRoundedRectangle(
                cornerRadii: .init(
                    topLeading: 0,
                    bottomLeading: 22,
                    bottomTrailing: 22,
                    topTrailing: 0
                ),
                style: .continuous
            )
            .fill(.black)
            .opacity(overlay.displayMode == .pill ? 0 : 1)
        }
    }

    // MARK: - Pill layout — indicator only, no text.

    private var compact: some View {
        HStack(spacing: 0) {
            StatusIndicator(
                status: engine.aggregateStatus,
                workingTint: .orange,
                forceColor: engine.brakeEngaged ? .orange : nil
            )
            // Brake state: tight breathing halo around the dot only. Drawn
            // here (not on the outer HStack) so it doesn't fill the entire
            // pill with an orange rectangle.
            .overlay {
                if engine.brakeEngaged {
                    BrakePulse()
                        .allowsHitTesting(false)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .scaleEffect(isWaiting ? 1.04 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            overlay.togglePanel()
        }
    }

    // MARK: - Waiting pill — dot + "Open terminal" action

    /// Compact-but-actionable knob shown when any session is blocked on a
    /// permission prompt. Tapping the empty area still toggles the full
    /// panel; the button itself short-circuits to focus the waiting
    /// session's terminal so the user can answer Claude immediately.
    private var waitingCompact: some View {
        VStack(spacing: 4) {
            // Top row mirrors the resting pill exactly — indicator anchored
            // to the leading edge over the notch shoulder. Keeps the visual
            // identity continuous when expanding/contracting.
            HStack(spacing: 0) {
                StatusIndicator(status: engine.aggregateStatus, workingTint: .orange)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)

            // Centered chin button hanging below the indicator.
            Button(action: focusWaitingTerminal) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Open terminal")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.black.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.yellow.opacity(0.95)))
            }
            .buttonStyle(.plain)
            .help("Focus the terminal Claude Code is waiting on")
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            overlay.togglePanel()
        }
    }

    /// Pick the first session currently in `.waiting` and bring ITS terminal
    /// window to the front (not just any window of the terminal app — see
    /// `TerminalFocus`). Falls back to togglePanel() if no session reports a
    /// captured bundle ID (legacy hooks that pre-date PermissionRequest).
    private func focusWaitingTerminal() {
        let waiter = engine.activeSessions.first { session in
            if case .waiting = session.status { return true }
            return false
        }
        guard let waiter, let bundleID = waiter.terminalBundleID else {
            overlay.togglePanel()
            return
        }
        TerminalFocus.focus(bundleID: bundleID, projectHint: waiter.project)
    }

    // MARK: - Expanded (popover) layout

    private var expanded: some View {
        VStack(spacing: 0) {
            // Header doubles as the close target — clicking the "notch" area
            // (top strip of the expanded panel) collapses back to compact.
            // No X button: the gesture replaces the chrome.
            header
                .contentShape(Rectangle())
                .onTapGesture { overlay.togglePanel() }
            Divider().overlay(.white.opacity(0.1))
            body_
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusIndicator(status: engine.aggregateStatus, workingTint: .orange)
            Text(headerLabel)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
            Spacer()
            if settings.usageTrackingEnabled && (engine.tokensInWindow > 0 || engine.dollarsInWindow > 0) {
                Button {
                    overlay.showSettings()
                } label: {
                    UsageBadge(
                        tier: settings.planTier,
                        tokens: engine.tokensInWindow,
                        usd: engine.dollarsInWindow,
                        fraction: engine.usageFraction,
                        secondsLeft: engine.secondsUntilReset,
                        braked: engine.brakeEngaged
                    )
                }
                .buttonStyle(.plain)
            }
            // Persistent settings entry — visible even when there's no usage
            // data yet, so users have an obvious affordance to configure
            // their plan and brake threshold on first launch.
            Button {
                overlay.showSettings()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var body_: some View {
        if settings.usageTrackingEnabled && engine.brakeEngaged {
            brakeBanner
        }

        if engine.activeSessions.isEmpty {
            if installer.isInstalled {
                emptyIdleState
            } else {
                installPromptState
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(engine.activeSessions.enumerated()), id: \.element.id) { idx, session in
                        if idx > 0 {
                            Divider().overlay(.white.opacity(0.08))
                        }
                        SessionRow(session: session)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                overlay.showSessionDetail(id: session.id)
                            }
                    }
                }
            }
        }
    }

    // MARK: - Brake pedal (v0.7 redux)

    /// Fires when usageFraction crosses the threshold. Phrased as an
    /// approximation — the limits aren't published by Anthropic.
    private var brakeBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.orange)
                Text(brakeTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Spacer()
                Text(brakeSubtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
            }
            Text("Approximate — Anthropic doesn't publish exact limits.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
            Button {
                engine.dismissBrake()
            } label: {
                Text("Dismiss for this window")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange.opacity(0.85))
            .controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.orange.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.orange.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var brakeTitle: String {
        if settings.planTier.usesDollarBudget {
            return "Approaching daily API budget"
        }
        return "Approaching session limit"
    }

    private var brakeSubtitle: String {
        let pct = Int((engine.usageFraction * 100).rounded())
        if settings.planTier.usesDollarBudget {
            return String(format: "≈$%.2f spent · %d%%", engine.dollarsInWindow, pct)
        }
        return "\(pct)% of \(settings.planTier.displayName)"
    }

    // MARK: - Empty-state branches

    /// Hooks ARE installed; we're just genuinely idle.
    private var emptyIdleState: some View {
        VStack(spacing: 10) {
            Image(systemName: "circle.dotted")
                .font(.system(size: 30))
                .foregroundStyle(.white.opacity(0.25))
            Text("No active sessions")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Hooks NOT installed — pitch the one-tap install. This is the most
    /// likely state on first launch and the biggest adoption hurdle, so the
    /// CTA gets visual weight.
    private var installPromptState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 26))
                .foregroundStyle(.yellow.opacity(0.7))

            VStack(spacing: 4) {
                Text("Hooks not installed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text("Notchcode needs a one-line entry in\n~/.claude/settings.json to see your sessions.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }

            Button {
                installer.runInstaller()
            } label: {
                HStack(spacing: 6) {
                    if installer.isWorking {
                        ProgressView().controlSize(.mini).tint(.white)
                    }
                    Text(installer.isWorking ? "Installing…" : "Install hooks")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow.opacity(0.85))
            .disabled(installer.isWorking)

            if let err = installer.lastError {
                Text(err)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.red.opacity(0.85))
                    .lineLimit(2)
                    .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    // MARK: - Derived

    private var isWaiting: Bool {
        engine.aggregateStatus == .waiting
    }

    private var headerLabel: String {
        let n = engine.activeSessions.count
        if n == 0 { return "Notchcode" }
        if n == 1 { return "1 session" }
        return "\(n) sessions"
    }
}

// MARK: - Status indicator (compact)

private struct StatusIndicator: View {
    let status: SessionStateEngine.Status
    /// Brake state forces a specific working tint (orange). For the regular
    /// working state we route through the user-selected animation, which
    /// is always orange — Claude's brand color for both shapes.
    var workingTint: Color = .orange
    /// When set (e.g., brake engaged), overrides the per-status color to a
    /// single attention color so the pill reads "stop" regardless of what
    /// the underlying sessions are doing.
    var forceColor: Color? = nil
    @State private var settings = AppSettings.shared

    var body: some View {
        Group {
            if let forced = forceColor {
                PulsingDot(color: forced)
            } else {
                switch status {
                case .idle:    EmptyView()
                case .working:
                    switch settings.workingAnimation {
                    case .spinner: ClaudeSpinner(color: workingTint)
                    case .pulse:   ClaudePulse(color: workingTint)
                    case .mascot:  ClaudeMascot(color: workingTint)
                    }
                case .waiting: PulsingDot(color: .yellow)
                case .done:    CheckmarkBadge()
                case .error:   Dot(color: .red)
                }
            }
        }
        .frame(width: 14, height: 14)
    }
}

// MARK: - Working animations

/// The Claude Code CLI's spinner — cycles a hand-picked subset of the unicode
/// dingbats/florettes (asterisks + stars) at ~80ms per frame. Reverse-engineered
/// from the CLI's behavior; the actual frame array is proprietary, this is the
/// public-glyph equivalent that reads the same way.
private struct ClaudeSpinner: View {
    let color: Color
    @State private var index = 0

    /// Six frames is enough to read as rotation without flickering. Spacing
    /// out by visual weight (light → heavy → light) gives a "breathing"
    /// sub-feel on top of the spin.
    private static let frames: [String] = ["✦", "✱", "✶", "✷", "✸", "✺"]
    private static let interval: TimeInterval = 0.08

    var body: some View {
        Text(Self.frames[index])
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(color)
            // `.task` ties the loop to the view lifetime: cancelled on
            // disappear, so no leaked timer when the indicator swaps state.
            .task {
                let step = UInt64(Self.interval * 1_000_000_000)
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: step)
                    index = (index + 1) % Self.frames.count
                }
            }
    }
}

/// The chunky pixel-art figure from the Claude Code CLI banner — orange
/// square body, two black eyes, four little feet. Animated by alternating
/// which pair of feet is raised, with a sub-pixel body bob to sell the walk.
/// Drawn in raw `Rectangle`s rather than as an asset so it stays crisp at
/// any scale and inherits the working tint cleanly.
private struct ClaudeMascot: View {
    let color: Color
    @State private var stepping = false

    var body: some View {
        ZStack {
            // Body — a slightly rounded square. The CLI banner's version is
            // pure pixel-art so we keep the radius minimal (just enough to
            // not look like a UIKit button).
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 8)
                .offset(y: stepping ? -0.5 : 0)   // tiny body bob

            // Eyes
            HStack(spacing: 2) {
                Rectangle().fill(.black).frame(width: 2, height: 2)
                Rectangle().fill(.black).frame(width: 2, height: 2)
            }
            .offset(y: -1)

            // Feet. Two pairs with a gap between the inner two, mirroring the
            // CLI banner's silhouette. Each foot is one of two phases: the
            // "raised" foot loses a row of pixels so its top edge sits flush
            // with the body — visually it tucked up.
            HStack(spacing: 0) {
                Foot(raised: !stepping)
                Spacer().frame(width: 1)
                Foot(raised: stepping)
                Spacer().frame(width: 2)
                Foot(raised: !stepping)
                Spacer().frame(width: 1)
                Foot(raised: stepping)
            }
            .offset(y: 5)
        }
        .frame(width: 14, height: 14)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 220_000_000)
                stepping.toggle()
            }
        }
    }

    private struct Foot: View {
        let raised: Bool
        var body: some View {
            Rectangle()
                .fill(.black)
                .frame(width: 1.5, height: raised ? 1 : 2)
                .offset(y: raised ? -0.5 : 0)
        }
    }
}

/// The claude.ai chat logo, transposed: a single 8-point star scaling and
/// fading in a steady breath. Same orange, different motion — the "alternative"
/// users can opt into from Settings.
private struct ClaudePulse: View {
    let color: Color
    @State private var contracted = false

    var body: some View {
        Text("✱")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(color)
            .scaleEffect(contracted ? 0.7 : 1.05)
            .opacity(contracted ? 0.55 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    contracted = true
                }
            }
    }
}

// MARK: - Usage badge (v0.7 redux)

/// Session-block usage pill in the expanded panel header. Renders differently
/// per plan tier:
///   - API mode: dollar value (real money)
///   - Anything else: percentage of estimated session limit, prefixed "~"
///     so users see at a glance that this is an approximation
private struct UsageBadge: View {
    let tier: AppSettings.PlanTier
    let tokens: Int
    let usd: Double
    let fraction: Double
    let secondsLeft: TimeInterval
    let braked: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(primaryLabel)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
            if secondsLeft > 0 {
                Text("·")
                    .foregroundStyle(textColor.opacity(0.5))
                Text(resetLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(textColor.opacity(0.7))
            }
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(bgColor))
        .help(helpText)
    }

    private var primaryLabel: String {
        if tier.usesDollarBudget {
            return usd < 10 ? String(format: "$%.2f", usd) : String(format: "$%.0f", usd)
        }
        let pct = Int((fraction * 100).rounded())
        return "~\(pct)%"
    }

    private var resetLabel: String {
        let mins = Int(secondsLeft / 60)
        if mins >= 60 {
            return "\(mins / 60)h \(mins % 60)m"
        }
        return "\(mins)m"
    }

    private var helpText: String {
        if tier.usesDollarBudget {
            return "≈\(usd) spent in the last 5 hours at API rates."
        }
        return "Approximate share of your \(tier.displayName) 5-hour session limit. Anthropic doesn't publish exact limits — this is a community-derived estimate."
    }

    private var bgColor: Color {
        if braked          { return .orange.opacity(0.25) }
        if fraction >= 0.6 { return .yellow.opacity(0.20) }
        return .white.opacity(0.08)
    }
    private var textColor: Color {
        if braked          { return .orange }
        if fraction >= 0.6 { return .yellow }
        return .white.opacity(0.75)
    }
}

private struct CheckmarkBadge: View {
    @State private var settled = false
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(.green)
            .scaleEffect(settled ? 1.0 : 1.6)
            .onAppear {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) {
                    settled = true
                }
            }
    }
}

private struct Dot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 8, height: 8) }
}

private struct PulsingDot: View {
    let color: Color
    @State private var pulsed = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(pulsed ? 0.35 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    pulsed = true
                }
            }
    }
}

/// Tight breathing orange halo around the status dot when the brake is engaged.
/// A faint inner fill plus an outer ring that scales 1.0 ↔ 1.8 while fading.
/// Sized to overlay the 14pt StatusIndicator — no stretched capsule across
/// the whole pill.
private struct BrakePulse: View {
    @State private var breathing = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.orange, lineWidth: 1.5)
                .opacity(breathing ? 0.0 : 0.7)
                .scaleEffect(breathing ? 1.8 : 1.0)
            Circle()
                .fill(Color.orange.opacity(0.22))
                .scaleEffect(breathing ? 1.1 : 0.9)
        }
        .frame(width: 18, height: 18)
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                breathing = true
            }
        }
    }
}

// MARK: - Session row (expanded)

private struct SessionRow: View {
    let session: SessionStateEngine.Session

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusDot(status: session.status)
                Text(session.project.isEmpty ? "(unknown)" : session.project)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Spacer()
                // Only surface per-session $ when the user actually pays per
                // token — for Pro/Max subscribers, API-rate dollars are noise
                // and routinely look alarmingly high without being actionable.
                if AppSettings.shared.usageTrackingEnabled
                    && AppSettings.shared.planTier.usesDollarBudget
                    && session.costUSD > 0 {
                    Text(String(format: "$%.2f", session.costUSD))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
                if session.ended {
                    Text("ENDED")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(0.08)))
                } else {
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }

            if case .waiting = session.status {
                Button(action: focusTerminal) {
                    Label("Focus terminal", systemImage: "arrow.up.right.square")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .controlSize(.small)
            }

            // Global view shows just the latest command per session — the full
            // command history lives in the per-session detail page so this row
            // stays compact when many sessions are stacked.
            if let latest = session.recentActions.last {
                ActionRow(action: latest)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .opacity(session.ended ? 0.5 : 1.0)
    }

    private var statusText: String {
        switch session.status {
        case .idle:                          return "idle"
        case .working(let tool, let detail):
            if let tool, let detail { return "\(tool) · \(detail)" }
            if let tool             { return tool }
            return "working"
        case .waiting:                       return "waiting"
        case .done:                          return "done"
        case .error(let msg):                return msg
        }
    }

    private func focusTerminal() {
        guard let bundleID = session.terminalBundleID else { return }
        TerminalFocus.focus(bundleID: bundleID, projectHint: session.project)
    }
}

struct ActionRow: View {
    let action: SessionStateEngine.Action

    var body: some View {
        HStack(spacing: 6) {
            Text(timeAgo)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 32, alignment: .leading)
            Text(action.toolName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
            if let detail = action.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private var timeAgo: String {
        let s = Int(Date().timeIntervalSince(action.timestamp))
        if s < 60   { return "\(s)s" }
        let m = s / 60
        if m < 60   { return "\(m)m" }
        let h = m / 60
        return "\(h)h"
    }
}

private struct StatusDot: View {
    let status: SessionStateEngine.Status
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
    private var color: Color {
        switch status {
        case .idle:    return .gray.opacity(0.55)
        case .working: return .blue
        case .waiting: return .yellow
        case .done:    return .green
        case .error:   return .red
        }
    }
}

#Preview("Compact") {
    NotchView(engine: SessionStateEngine.shared, overlay: NotchOverlay.shared)
        .frame(width: 240, height: 44)
        .padding(40)
        .background(.gray)
}
