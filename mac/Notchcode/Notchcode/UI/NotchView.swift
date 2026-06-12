// The SwiftUI view inside the notch panel.
//
// v0.7 has two modes matching NotchOverlay.DisplayMode:
//
//   PILL:    resting strip. At rest (no live session) the frame matches the
//   hardware cutout exactly and renders nothing — the notch looks stock.
//   When a Claude Code session is live, the overlay widens (see
//   NotchOverlay.setSessionActivity) and shows ONLY the StatusIndicator —
//   no text. The indicator's appearance follows engine.aggregateStatus
//   (orange spinner working, pulsing yellow exclamation mark waiting,
//   popping green checkmark done — sticky until the first tap dismisses
//   it). While waiting, a jump arrow also grows on the trailing shoulder
//   and the tap focuses the blocked session's terminal directly; otherwise
//   tap opens the popover.
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
    /// One terminal jump per waiting episode. The FIRST tap while waiting
    /// focuses the blocked session's terminal; after that the affordance is
    /// considered dismissed — the arrow hides and taps open the panel as
    /// usual. Reset when the waiting episode ends so the next one gets a
    /// fresh jump.
    @State private var terminalJumpConsumed = false

    var body: some View {
        ZStack {
            background

            switch overlay.displayMode {
            case .panel:
                expanded.transition(.opacity)
            case .pill:
                compact.transition(.opacity)
            case .settings:
                SettingsView(overlay: overlay).transition(.opacity)
            case .sessionDetail:
                SessionDetailView(engine: engine, overlay: overlay).transition(.opacity)
            }

            // ⌘, opens settings while the notch UI is open (panel or session
            // detail — settings itself already binds Escape to dismiss).
            // Invisible anchor button rather than a modifier on the gear so
            // one code path covers both modes.
            if overlay.displayMode == .panel || overlay.displayMode == .sessionDetail {
                Button("") { overlay.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                    .buttonStyle(.plain)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
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
        // Waiting episode ended → re-arm the one-shot terminal jump for the
        // next time Claude blocks on the user.
        .onChange(of: isWaiting) { _, waiting in
            if !waiting { terminalJumpConsumed = false }
        }
        // Collapsing the panel-family modes while everything reads done
        // counts as the acknowledgment — the user just had the full panel
        // open; making them tap the checkmark again after that would nag.
        // The pill's own first-tap acknowledge handles the resting case.
        .onChange(of: overlay.displayMode) { old, new in
            if old != .pill && new == .pill && isDone {
                engine.acknowledgeDone()
            }
        }
        // Session live ↔ idle → widen/narrow the resting pill. At rest the
        // overlay matches the hardware cutout exactly; only a running Claude
        // Code session (or the brake) earns the extra shoulder width that
        // makes the StatusIndicator visible.
        .onChange(of: hasLiveActivity) { _, active in
            overlay.setSessionActivity(active)
        }
        .onAppear {
            overlay.setSessionActivity(hasLiveActivity)
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

    /// While waiting on the user, the indicator becomes an exclamation mark
    /// and a jump arrow grows in on the trailing shoulder. The FIRST tap
    /// focuses the blocked session's terminal — that's where the permission
    /// prompt lives. Any tap after that opens the panel as usual: the jump
    /// already happened, treat the affordance as dismissed.
    ///
    /// The done checkmark uses the same first-tap-consumes routing: it stays
    /// pinned until the FIRST tap acknowledges it (pill contracts back to the
    /// bare cutout), and only the next tap opens the panel. The persistent
    /// checkmark is the "your task finished" reminder for anyone who wasn't
    /// staring at the menubar when Stop fired.
    private var compact: some View {
        HStack(spacing: 0) {
            StatusIndicator(
                status: engine.aggregateStatus,
                workingTint: .orange,
                agent: engine.aggregateWorkingAgent,
                forceColor: engine.brakeEngaged ? .orange : nil
            )
            Spacer(minLength: 0)
            if isWaiting && !terminalJumpConsumed {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.yellow)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .help("Focus the terminal Claude Code is waiting on")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.18), value: terminalJumpConsumed)
        .contentShape(Rectangle())
        .onTapGesture {
            if isWaiting && !terminalJumpConsumed {
                terminalJumpConsumed = true
                focusWaitingTerminal()
            } else if isDone {
                // First tap = "seen it." The aggregate falls back to idle,
                // hasLiveActivity flips, and the pill contracts on its own.
                engine.acknowledgeDone()
            } else {
                overlay.togglePanel()
            }
        }
        .help(isDone ? "Task finished — click to dismiss" : "")
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
            StatusIndicator(status: engine.aggregateStatus, workingTint: .orange, agent: engine.aggregateWorkingAgent)
            Text(headerLabel)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
            Spacer()
            if settings.usageTrackingEnabled && (engine.weeklyTokens > 0 || engine.dollarsToday > 0) {
                Button {
                    overlay.showSettings()
                } label: {
                    UsageBadge(
                        tier: settings.planTier,
                        weeklyTokens: engine.weeklyTokens,
                        todayTokens: engine.todayTokens,
                        weeklyUSD: engine.weeklyDollars,
                        usdToday: engine.dollarsToday,
                        fraction: engine.usageFraction,
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
            .help("Settings (⌘,)")
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
            // "Set up" CTA shows only when NEITHER agent is wired up. Once one
            // is installed, the quiet idle state takes over; the second agent
            // is managed from Settings.
            if installer.isInstalled(.claude) || installer.isInstalled(.codex) {
                emptyIdleState
            } else {
                installPromptState
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(engine.activeSessions) { session in
                        SessionRow(session: session, engine: engine)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                overlay.showSessionDetail(id: session.id)
                            }
                    }
                }
            }
        }
    }

    // MARK: - Brake pedal

    /// Fires when usageFraction crosses the threshold. Styled as a quiet
    /// inline strip — same typography and hairline dividers as the session
    /// list, just an orange dot for color — rather than a callout card. The
    /// one-time auto-expand already grabbed the user's attention; the strip
    /// only needs to persist the fact.
    private var brakeBanner: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(brakeTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(brakeSubtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                Button {
                    engine.dismissBrake()
                } label: {
                    Text("Dismiss")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Quiet this until tomorrow")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .help(settings.planTier.usesDollarBudget
                  ? "Measured against your daily $ cap from Settings."
                  : "Budget is your own gauge — adjust it in Settings.")

            Divider().overlay(.white.opacity(0.08))
        }
    }

    private var brakeTitle: String {
        if settings.planTier.usesDollarBudget {
            return "Approaching daily API budget"
        }
        return "Approaching weekly budget"
    }

    private var brakeSubtitle: String {
        let pct = Int((engine.usageFraction * 100).rounded())
        if settings.planTier.usesDollarBudget {
            return String(format: "≈$%.2f today · %d%%", engine.dollarsToday, pct)
        }
        return "\(compactTokenCount(engine.weeklyTokens)) of \(compactTokenCount(settings.weeklyTokenBudget)) · \(pct)%"
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
                Text("Notchcode needs a one-line entry in\n~/.claude/settings.json to see your sessions.\nAdd Codex in Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }

            Button {
                installer.runInstaller(.claude)
            } label: {
                HStack(spacing: 6) {
                    if installer.isWorking(.claude) {
                        ProgressView().controlSize(.mini).tint(.white)
                    }
                    Text(installer.isWorking(.claude) ? "Installing…" : "Install hooks")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow.opacity(0.85))
            .disabled(installer.isWorking(.claude))

            if let err = installer.lastError(.claude) {
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

    private var isDone: Bool {
        engine.aggregateStatus == .done
    }

    /// "A Claude Code session is doing something worth showing." Idle
    /// sessions don't count — the pill stays at hardware-notch size until
    /// real activity (working/waiting/done/error) or the brake shows up.
    private var hasLiveActivity: Bool {
        engine.aggregateStatus != .idle || engine.brakeEngaged
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
    /// Fallback working tint when no agent is supplied. For the regular working
    /// state we route through the user-selected animation in Claude orange.
    var workingTint: Color = .orange
    /// The agent driving the displayed status, when known (the collapsed pill
    /// passes the working session's agent). Tints the working animation by
    /// agent and forces Codex onto the pulsing dot — Codex never borrows the
    /// two Claude-branded motions. nil keeps the Claude default.
    var agent: Agent? = nil
    /// When set (e.g., brake engaged), overrides the per-status color to a
    /// single attention color so the pill reads "stop" regardless of what
    /// the underlying sessions are doing.
    var forceColor: Color? = nil
    @State private var settings = AppSettings.shared

    var body: some View {
        Group {
            if let forced = forceColor {
                // Brake state: a plain static dot. Deliberately quiet — the
                // user already got the one-time auto-expanded banner; the
                // resting pill just needs to hold the color, not nag.
                Dot(color: forced)
            } else {
                switch status {
                case .idle:    EmptyView()
                case .working:
                    if agent == .codex {
                        ClaudePulse(color: Agent.codex.accent)
                    } else {
                        switch settings.workingAnimation {
                        case .spinner: ClaudeSpinner(color: agent?.accent ?? workingTint)
                        case .pulse:   ClaudePulse(color: agent?.accent ?? workingTint)
                        case .mascot:  ClaudeMascot(color: agent?.accent ?? workingTint)
                        }
                    }
                case .waiting: WaitingExclamation()
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

// MARK: - Usage badge

/// Compact token-count formatter shared by the badge, brake banner, and
/// settings page: 950 → "950", 8_234_000 → "8.2M", 1_050_000_000 → "1.1B".
/// Whole multiples drop the ".0" ("50M", not "50.0M").
func compactTokenCount(_ n: Int) -> String {
    func fmt(_ value: Double, _ suffix: String) -> String {
        let s = String(format: "%.1f", value)
        return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + suffix
    }
    let d = Double(n)
    switch d {
    case 1_000_000_000...: return fmt(d / 1_000_000_000, "B")
    case 1_000_000...:     return fmt(d / 1_000_000, "M")
    case 1_000...:         return fmt(d / 1_000, "K")
    default:               return "\(n)"
    }
}

/// Usage pill in the expanded panel header. Renders differently per tier:
///   - API mode: dollars spent today (real money, measured vs the daily cap)
///   - Subscription: exact tokens used in the last 7 days on this Mac,
///     e.g. "8.2M wk". No reset countdown — Anthropic's window anchors
///     can't be known locally, so we don't pretend to know them.
private struct UsageBadge: View {
    let tier: AppSettings.PlanTier
    let weeklyTokens: Int
    let todayTokens: Int
    let weeklyUSD: Double
    let usdToday: Double
    let fraction: Double
    let braked: Bool

    var body: some View {
        Text(primaryLabel)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(textColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(bgColor))
            .help(helpText)
    }

    private var primaryLabel: String {
        if tier.usesDollarBudget {
            return usdToday < 10 ? String(format: "$%.2f", usdToday) : String(format: "$%.0f", usdToday)
        }
        return "\(compactTokenCount(weeklyTokens)) wk"
    }

    private var helpText: String {
        if tier.usesDollarBudget {
            return String(format: "≈$%.2f spent today at API rates (%d%% of your daily cap).",
                          usdToday, Int((fraction * 100).rounded()))
        }
        let pct = Int((fraction * 100).rounded())
        return "\(compactTokenCount(weeklyTokens)) tokens in the last 7 days on this Mac"
             + " · \(compactTokenCount(todayTokens)) today"
             + String(format: " · ≈$%.0f at API rates.", weeklyUSD)
             + " \(pct)% of your \(compactTokenCount(AppSettings.shared.weeklyTokenBudget)) weekly budget."
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

/// Waiting on the user — bold yellow exclamation mark with a gentle opacity
/// pulse. Replaces the old pulsing dot: an "!" reads as "action needed" at a
/// glance, where a dot just reads as "something is happening."
private struct WaitingExclamation: View {
    @State private var pulsed = false
    var body: some View {
        Image(systemName: "exclamationmark")
            .font(.system(size: 12, weight: .heavy))
            .foregroundStyle(.yellow)
            .opacity(pulsed ? 0.45 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    pulsed = true
                }
            }
    }
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

// MARK: - Session row (expanded)

private struct SessionRow: View {
    let session: SessionStateEngine.Session
    let engine: SessionStateEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // Working sessions get the same live animation the resting
                // pill uses (spinner/pulse/mascot per Settings) — a static
                // dot undersold "Claude is actively doing something" in the
                // expanded list. Other states keep the quiet color dot.
                SessionStatusIndicator(status: session.status, agent: session.agent)
                AgentBadge(agent: session.agent)
                Text(session.project.isEmpty ? "(unknown)" : session.project)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                // Status reads inline, right of the project name (matching the
                // Windows row) rather than pushed to the far edge.
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

                // Inline lifecycle controls — same actions as the drill-down
                // header, surfaced here so multi-session users don't need a
                // click-through per session. Buttons win the hit-test over
                // the row's tap gesture, so the row still opens the detail
                // view everywhere else.
                if !session.ended, session.terminalBundleID != nil {
                    RowIconButton(
                        systemName: "arrow.up.right",
                        tint: isWaiting ? .yellow : .white.opacity(0.6),
                        bg: isWaiting ? .yellow.opacity(0.18) : .white.opacity(0.08),
                        action: focusTerminal
                    )
                    .help(isWaiting
                          ? "Claude is waiting on you — focus its terminal"
                          : "Focus the terminal that owns this session")
                }
                if session.ended {
                    RowIconButton(
                        systemName: "xmark",
                        tint: .white.opacity(0.6),
                        bg: .white.opacity(0.08)
                    ) {
                        engine.dismissSession(id: session.id)
                    }
                    .help("Drop this ended session from the panel")
                } else {
                    // Same treatment as the drill-down header's End button
                    // (light-red glyph on red 0.22 capsule) so "end this
                    // session" reads identically on both surfaces. The glyph
                    // is a desaturated light red — full white-on-red was too
                    // harsh against the dark panel.
                    RowIconButton(
                        systemName: "stop.fill",
                        tint: Color(red: 1.0, green: 0.62, blue: 0.6),
                        bg: .red.opacity(0.22)
                    ) {
                        engine.endSession(id: session.id)
                    }
                    .help("End this Claude Code session (SIGTERM)")
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .opacity(session.ended ? 0.5 : 1.0)
    }

    private var isWaiting: Bool {
        if case .waiting = session.status { return true }
        return false
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

/// Small circular icon button used by the session rows' inline controls.
/// Mirrors the header gear's sizing so the right edge of the panel reads as
/// one consistent family of tap targets.
private struct RowIconButton: View {
    let systemName: String
    let tint: Color
    let bg: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(bg))
        }
        .buttonStyle(.plain)
    }
}

/// Per-row status glyph. Working → the working animation, tinted by agent
/// (Claude → its orange, Codex → its accent). Codex never borrows the two
/// Claude-branded motions (the CLI flower / walking mascot); it always pulses
/// in its own color so the animation reads as "this is Codex, not Claude."
/// Every other state → the static color dot.
private struct SessionStatusIndicator: View {
    let status: SessionStateEngine.Status
    let agent: Agent
    @State private var settings = AppSettings.shared

    var body: some View {
        Group {
            if case .working = status {
                if agent == .codex {
                    ClaudePulse(color: agent.accent)
                } else {
                    switch settings.workingAnimation {
                    case .spinner: ClaudeSpinner(color: agent.accent)
                    case .pulse:   ClaudePulse(color: agent.accent)
                    case .mascot:  ClaudeMascot(color: agent.accent)
                    }
                }
            } else {
                StatusDot(status: status)
            }
        }
        .frame(width: 14, height: 14)
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
