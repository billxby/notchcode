// Inline settings page rendered INSIDE the notch overlay panel.
//
// Not a separate SwiftUI Settings window — we want the configuration UI to
// feel part of the notch itself. Same dark surface as the rest of the
// overlay, same typography scale as the expanded session list.
//
// Sections:
//   1. Usage tracking — plan tier, brake threshold (or $ cap), master toggle,
//      approximation disclosure
//   2. Claude Code integration — install / reinstall / remove hooks
//   3. General — open at login
//   4. About — version and tagline
//
// Closed by the Done button at the top-right OR clicking outside the notch
// (NotchOverlay routes outside-click to `dismissSettings()`).

import SwiftUI

struct SettingsView: View {
    let overlay: NotchOverlay
    @State private var settings = AppSettings.shared
    @State private var installer = HookInstaller.shared
    /// AX trust is checked synchronously and refreshed on appear (and after
    /// the user clicks Grant) — the system doesn't give us a callback when
    /// they toggle the switch in System Settings, so a manual re-check covers
    /// the round-trip.
    @State private var axTrusted: Bool = TerminalFocus.isTrusted()
    /// Login-item state is owned by the system (SMAppService), not
    /// UserDefaults — read it on appear and after every toggle so the switch
    /// stays honest even if the user flips it in System Settings.
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.1))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    usageSection
                    notificationsSection
                    appearanceSection
                    integrationSection
                    systemAccessSection
                    generalSection
                    aboutSection
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
        }
        .onAppear {
            axTrusted = TerminalFocus.isTrusted()
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text("Settings")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
            Spacer()
            Button {
                overlay.dismissSettings()
            } label: {
                Text("Done")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .background(
                Capsule().fill(.white.opacity(0.12))
            )
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - General

    private var generalSection: some View {
        SectionCard(title: "General") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        do {
                            try LaunchAtLogin.set(newValue)
                            launchAtLoginError = nil
                        } catch {
                            launchAtLoginError = error.localizedDescription
                        }
                        // Re-read rather than trust newValue — registration
                        // can be deferred or refused by the system.
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                )) {
                    Text("Open at login")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                }
                .toggleStyle(.switch)
                .tint(.blue)

                Text("Start Notchcode automatically when you log in to this Mac.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)

                if let err = launchAtLoginError {
                    Text(err)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.85))
                        .lineLimit(3)
                }
            }
            // Unlike the other cards, nothing in here has a Spacer() row to
            // stretch the card — force full width to match.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        SectionCard(title: "Notifications") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(
                        get: { settings.notifyOnWaiting },
                        set: { settings.notifyOnWaiting = $0 }
                    )) {
                        Text("Notify when an agent needs input")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    .toggleStyle(.switch)
                    .tint(.blue)

                    Text("Post a banner when Claude or Codex blocks on an approval. Click it to jump to that terminal window.")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(
                        get: { settings.focusTerminalOnWaiting },
                        set: { settings.focusTerminalOnWaiting = $0 }
                    )) {
                        Text("Focus terminal automatically")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    .toggleStyle(.switch)
                    .tint(.blue)

                    Text("Bring the agent's terminal window to the front the moment it starts waiting, without clicking. Precise-window focus needs Accessibility access (below).")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Usage tracking

    private var usageSection: some View {
        SectionCard(title: "Usage tracking") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { settings.usageTrackingEnabled },
                    set: { settings.usageTrackingEnabled = $0 }
                )) {
                    Text("Show usage in the notch")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                }
                .toggleStyle(.switch)
                .tint(.blue)

                HStack {
                    Text("Your plan")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { settings.planTier },
                        set: { settings.planTier = $0 }
                    )) {
                        ForEach(AppSettings.PlanTier.allCases) { tier in
                            Text(tier.displayName).tag(tier)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .disabled(!settings.usageTrackingEnabled)
                }

                if settings.planTier.usesDollarBudget {
                    HStack {
                        Text("Daily $ cap")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.75))
                        Spacer()
                        Stepper(
                            value: Binding(
                                get: { settings.dailyCapUSD },
                                set: { settings.dailyCapUSD = $0 }
                            ),
                            in: 1...500,
                            step: 5
                        ) {
                            Text(String(format: "$%.0f", settings.dailyCapUSD))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 60, alignment: .trailing)
                        }
                        .disabled(!settings.usageTrackingEnabled)
                    }
                } else {
                    // Weekly token budget — what the badge color and the
                    // brake measure against. Seeded by the tier preset above;
                    // fully user-editable. Coarser steps at higher budgets so
                    // a Max 20× user isn't clicking through 200 stops.
                    HStack {
                        Text("Weekly budget")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.75))
                        Spacer()
                        Stepper {
                            Text("\(compactTokenCount(settings.weeklyTokenBudget)) tokens")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 90, alignment: .trailing)
                        } onIncrement: {
                            settings.weeklyTokenBudget += budgetStep(settings.weeklyTokenBudget)
                        } onDecrement: {
                            let step = budgetStep(settings.weeklyTokenBudget - 1)
                            settings.weeklyTokenBudget = max(1_000_000, settings.weeklyTokenBudget - step)
                        }
                        .disabled(!settings.usageTrackingEnabled)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Brake fires at")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.75))
                            Spacer()
                            Text("\(Int(settings.brakeThresholdPercent * 100))% of budget")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        Slider(
                            value: Binding(
                                get: { settings.brakeThresholdPercent },
                                set: { settings.brakeThresholdPercent = $0 }
                            ),
                            in: 0.5...1.0,
                            step: 0.05
                        )
                        .tint(.orange)
                        .disabled(!settings.usageTrackingEnabled)
                    }
                }

                approximationNote
            }
        }
    }

    /// 1M steps below 10M, 5M above — keeps the stepper usable across the
    /// whole free→Max 20× range.
    private func budgetStep(_ current: Int) -> Int {
        current < 10_000_000 ? 1_000_000 : 5_000_000
    }

    private var approximationNote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 2)
            Text("Token counts are exact, parsed from this Mac's Claude Code logs — sessions on other devices aren't counted. The weekly budget is your own gauge; Anthropic doesn't publish per-plan token limits.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(0.04))
        )
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        SectionCard(title: "Appearance") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Working animation")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { settings.workingAnimation },
                        set: { settings.workingAnimation = $0 }
                    )) {
                        ForEach(AppSettings.WorkingAnimation.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                Text("How the notch shows that Claude is doing something. Spinner cycles the Claude Code CLI dingbats; pulse breathes the chat-logo star.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Integration

    /// One card holding an independent install row per agent. Installing or
    /// removing one agent's hooks never touches the other's config file, so a
    /// user can monitor Claude Code and Codex together or either alone.
    private var integrationSection: some View {
        SectionCard(title: "Agent integration") {
            VStack(alignment: .leading, spacing: 16) {
                agentIntegrationRow(.claude)
                Divider().overlay(.white.opacity(0.08))
                agentIntegrationRow(.codex)
            }
        }
    }

    @ViewBuilder
    private func agentIntegrationRow(_ agent: Agent) -> some View {
        let isInstalled = installer.isInstalled(agent)
        let isWorking = installer.isWorking(agent)
        let configName = agent == .claude ? "~/.claude/settings.json" : "~/.codex/hooks.json"
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: isInstalled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(isInstalled ? .green : .yellow)
                Text("\(agent.displayName) — \(isInstalled ? "hooks installed" : "hooks not installed")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
            }
            Text(isInstalled
                 ? "Notchcode is wired into \(configName). Reinstall to refresh after a \(agent.displayName) update."
                 : "Notchcode can't see your \(agent.displayName) sessions until the hook entries are added to \(configName).")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if isInstalled {
                    Button("Reinstall") { installer.runInstaller(agent) }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue.opacity(0.85))
                        .controlSize(.small)
                        .disabled(isWorking)
                    Button("Remove") { installer.runUninstaller(agent) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isWorking)
                } else {
                    Button {
                        installer.runInstaller(agent)
                    } label: {
                        HStack(spacing: 4) {
                            if isWorking {
                                ProgressView().controlSize(.mini).tint(.white)
                            }
                            Text(isWorking ? "Installing…" : "Install hooks")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.yellow.opacity(0.85))
                    .controlSize(.small)
                    .disabled(isWorking)
                }
                Spacer()
            }

            if let err = installer.lastError(agent) {
                Text(err)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.red.opacity(0.85))
                    .lineLimit(3)
            }
        }
    }

    // MARK: - System access

    /// Accessibility permission gates the precise-window terminal focus.
    /// Without it, clicking "Open terminal" still raises the app — just not
    /// necessarily the specific window Claude is waiting in.
    private var systemAccessSection: some View {
        SectionCard(title: "System access") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: axTrusted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(axTrusted ? .green : .yellow)
                    Text(axTrusted ? "Accessibility granted" : "Accessibility not granted")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                }
                Text(axTrusted
                     ? "Notchcode can target the specific terminal window where Claude is waiting."
                     : "Without Accessibility access, Open Terminal brings the app forward but can't pick the exact window.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)

                if !axTrusted {
                    HStack(spacing: 8) {
                        Button("Grant access") {
                            TerminalFocus.openAccessibilitySettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.yellow.opacity(0.85))
                        .controlSize(.small)
                        Button("Re-check") {
                            axTrusted = TerminalFocus.isTrusted()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        SectionCard(title: "About") {
            HStack(spacing: 10) {
                // The real app icon (from AppIcon.icns), not an SF Symbol —
                // applicationIconImage already carries the rounded-rect mask.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Notchcode")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    Text("Ambient monitor for Claude Code")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                    if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                        Text("v\(v)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                Spacer()
                Link(destination: URL(string: "https://github.com/billxby/notchcode")!) {
                    Text("GitHub")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(0.08)))
                }
                .help("github.com/billxby/notchcode")
                // Quit lives here because Notchcode has no Dock icon and no
                // main window — without this, the menubar extra is the only
                // way out, and not everyone discovers it.
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("Quit Notchcode")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Quit Notchcode (⌘Q from the menubar also works)")
            }
        }
    }
}

// MARK: - Section card

/// Thin dark-on-dark grouping primitive used by the settings page. Keeps
/// the typography consistent with the expanded session list.
private struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .tracking(0.8)
            content()
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.06), lineWidth: 1)
                )
        }
    }
}
