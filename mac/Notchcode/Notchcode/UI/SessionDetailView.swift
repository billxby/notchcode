// v0.95 — per-conversation drill-down.
//
// Rendered when overlay.displayMode == .sessionDetail. The target session is
// pulled from overlay.selectedSessionId; if it's nil or no longer in the
// engine's dict (long-stale session), we render a minimal "session ended"
// fallback and let the back button take the user back to the panel list.
//
// Layout matches the rest of the notch surface:
//   header  — back button · project label · status indicator · Focus terminal
//   body    — chronological timeline: text messages and tool commands
//             interleaved by timestamp (the natural Claude flow is "say
//             something, then run a command"). Tails to the bottom on entry
//             and on each live append.
//
// Tool results and image blocks are still excluded — JSONLParser strips them
// upstream. Commands appear via the hook stream (session.recentActions).

import SwiftUI
import AppKit

struct SessionDetailView: View {
    let engine: SessionStateEngine
    let overlay: NotchOverlay

    /// v0.95 — non-persistent toast for the End button. Tells the user
    /// whether we actually SIGTERM'd Claude or fell back to a local hide.
    @State private var endHint: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.1))
            if let hint = endHint {
                endHintBanner(hint)
            }
            timeline
        }
    }

    private func endHintBanner(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.05))
    }

    // MARK: - Timeline entries

    /// One row in the scroll view. Messages and actions are merged into a
    /// single chronologically-sorted stream so a user reading the page sees
    /// the same flow Claude produced: a sentence, then the tool call it
    /// triggered, then the next sentence.
    private enum Entry: Identifiable {
        case message(SessionStateEngine.Message)
        case action(SessionStateEngine.Action)

        var id: UUID {
            switch self {
            case .message(let m): return m.id
            case .action(let a):  return a.id
            }
        }

        var timestamp: Date {
            switch self {
            case .message(let m): return m.timestamp
            case .action(let a):  return a.timestamp
            }
        }
    }

    private func entries(for s: SessionStateEngine.Session) -> [Entry] {
        let msgs = s.messages.map(Entry.message)
        let acts = s.recentActions.map(Entry.action)
        return (msgs + acts).sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Resolved session

    private var session: SessionStateEngine.Session? {
        guard let id = overlay.selectedSessionId else { return nil }
        return engine.sessions[id]
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                overlay.dismissSessionDetail()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Back")
            .keyboardShortcut(.cancelAction)

            StatusDot(status: session?.status ?? .idle)

            Text(session?.project.isEmpty == false ? session!.project : "Session")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)

            Spacer()

            if let s = session, s.terminalBundleID != nil {
                Button(action: focusTerminal) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Focus")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .background(Capsule().fill(.white.opacity(0.12)))
                .help("Bring the terminal that owns this session to the front")
            }

            // v0.95 lifecycle controls. Live sessions get End (SIGTERM the
            // captured PID, falling back to a soft hide if hooks haven't
            // been reinstalled with PID forwarding yet); ended sessions
            // get Remove (drop from the panel + forget messages).
            if let s = session {
                if s.ended {
                    Button {
                        let id = s.id
                        overlay.dismissSessionDetail()
                        engine.dismissSession(id: id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Remove")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .background(Capsule().fill(.white.opacity(0.12)))
                    .help("Drop this ended session from the panel")
                } else {
                    Button {
                        let signaled = engine.endSession(id: s.id)
                        endHint = signaled
                            ? "Sent SIGTERM to Claude Code."
                            : "Hidden locally. Reinstall hooks in Settings to enable real termination."
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10, weight: .semibold))
                            Text("End")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .background(Capsule().fill(.red.opacity(0.22)))
                    .help("Send SIGTERM to this Claude Code session")
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Timeline (messages + commands, chronological)

    @ViewBuilder
    private var timeline: some View {
        if let s = session {
            let items = entries(for: s)
            if items.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(items) { entry in
                                row(for: entry).id(entry.id)
                            }
                            // Anchor at the bottom so scrollTo can tail-follow
                            // as new turns / commands stream in.
                            Color.clear.frame(height: 1).id(Self.tailAnchor)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                    }
                    .onAppear {
                        proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
                    }
                    // Watch the combined count so a new command also tails the
                    // scroll, not just a new message.
                    .onChange(of: s.messages.count + s.recentActions.count) { _, _ in
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
                        }
                    }
                }
            }
        } else {
            sessionGoneState
        }
    }

    @ViewBuilder
    private func row(for entry: Entry) -> some View {
        switch entry {
        case .message(let m): MessageRow(message: m)
        case .action(let a):  ActionRow(action: a)
        }
    }

    private static let tailAnchor = "notchcode.session-detail.tail"

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.25))
            Text("No messages parsed yet")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
            Text("New turns will appear here as Claude Code writes them.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private var sessionGoneState: some View {
        VStack(spacing: 8) {
            Image(systemName: "circle.dotted")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.25))
            Text("Session ended")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func focusTerminal() {
        guard let s = session, let bundleID = s.terminalBundleID else { return }
        TerminalFocus.focus(bundleID: bundleID, projectHint: s.project)
    }
}

// MARK: - Message row

private struct MessageRow: View {
    let message: SessionStateEngine.Message

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(roleLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(roleColor)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Text(timestamp)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
                Spacer()
            }
            Text(message.text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(message.role == .user ? 0.06 : 0.03))
        )
    }

    private var roleLabel: String { message.role == .user ? "You" : "Claude" }
    private var roleColor: Color { message.role == .user ? .blue.opacity(0.85) : .green.opacity(0.85) }

    private var timestamp: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: message.timestamp)
    }
}

// MARK: - Status dot (mirrors the one in NotchView)

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
