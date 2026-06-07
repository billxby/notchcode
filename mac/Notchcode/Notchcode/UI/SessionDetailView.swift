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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(items) { entry in
                            row(for: entry)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                }
                // Chat-style bottom anchoring. The previous ScrollViewReader +
                // scrollTo(onAppear) approach forced layout of EVERY row (up
                // to 200 markdown parses + AttributedString inits) in a single
                // main-thread frame just to find the bottom — that was the
                // drill-down open lag. defaultScrollAnchor starts at the
                // bottom without defeating LazyVStack, and keeps tailing new
                // turns while the user is at the bottom (and stops when they
                // scroll up to read — strictly better than the forced tail).
                .defaultScrollAnchor(.bottom)
            }
        } else {
            sessionGoneState
        }
    }

    @ViewBuilder
    private func row(for entry: Entry) -> some View {
        switch entry {
        // .equatable() lets SwiftUI skip a row's body when its Message is
        // unchanged — without it, every engine mutation (JSONL appends, the
        // 1s clock tick reaching NotchView) could re-run the markdown parse
        // for every visible row.
        case .message(let m): MessageRow(message: m).equatable()
        case .action(let a):  ActionRow(action: a)
        }
    }

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

private struct MessageRow: View, Equatable {
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
            MarkdownText(text: message.text, cacheKey: message.id)
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

    /// Shared formatter — DateFormatter() is one of the most expensive
    /// common Foundation inits (~ms); allocating one per row body eval was
    /// a measurable chunk of the drill-down open cost. @MainActor because
    /// DateFormatter isn't Sendable; all rows render on main anyway.
    @MainActor private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var timestamp: String {
        Self.timeFormatter.string(from: message.timestamp)
    }
}

// MARK: - Markdown rendering

/// Lightweight markdown renderer for chat turns.
///
/// Why not just `Text(message.text)`: a `String` variable renders verbatim —
/// users see raw `**bold**` and backticks. Why not just
/// `AttributedString(markdown:)`: Foundation's parser handles INLINE styles
/// (bold, italic, `code`, links) but flattens BLOCK structure — code fences,
/// lists, and headers all collapse into one run-on paragraph, which is most
/// of what Claude actually writes.
///
/// So we split blocks ourselves (fenced code / headers / list items /
/// paragraphs) and hand each block's text to the inline parser. Not a full
/// CommonMark implementation — tables and blockquotes render as plain
/// paragraphs — but it covers the real shape of Claude Code conversations.
private struct MarkdownText: View {
    let text: String
    /// Message id used to memoize the block parse. Message text is immutable
    /// once recorded (each JSONL line is a complete turn), so a parse keyed
    /// by id never goes stale. Without this, LazyVStack re-parses a row's
    /// full markdown every time it scrolls back into view.
    var cacheKey: UUID? = nil

    /// Parse memo. @MainActor (all rendering is main-thread); bounded by a
    /// dumb full-clear well above messageHistoryLimit so it can't grow
    /// unboundedly across many sessions.
    @MainActor private static var blockCache: [UUID: [Block]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Index-keyed ForEach is safe here: blocks are recomputed in full
            // whenever `text` changes, never partially mutated.
            ForEach(Array(cachedBlocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    private var cachedBlocks: [Block] {
        guard let key = cacheKey else { return blocks }
        if let hit = Self.blockCache[key] { return hit }
        let parsed = blocks
        if Self.blockCache.count > 512 { Self.blockCache.removeAll(keepingCapacity: true) }
        Self.blockCache[key] = parsed
        return parsed
    }

    // MARK: Block model

    private enum Block {
        case paragraph(String)
        case header(String)
        /// (marker, content) pairs — marker is "•" for unordered items or
        /// the literal "3." for ordered ones.
        case list([(marker: String, content: String)])
        case code(String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var listItems: [(marker: String, content: String)] = []
        var codeLines: [String] = []
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            result.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }
        func flushList() {
            guard !listItems.isEmpty else { return }
            result.append(.list(listItems))
            listItems = []
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Fence toggles win over everything else.
            if line.hasPrefix("```") {
                if inCode {
                    result.append(.code(codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCode = false
                } else {
                    flushParagraph(); flushList()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(rawLine)   // keep original indentation
                continue
            }

            if line.isEmpty {
                flushParagraph(); flushList()
                continue
            }

            // Headers: "# " through "###### ", rendered uniformly — a chat
            // bubble has no room for a six-level type scale.
            if line.hasPrefix("#") {
                let stripped = line.drop(while: { $0 == "#" })
                if stripped.first == " " {
                    flushParagraph(); flushList()
                    result.append(.header(stripped.trimmingCharacters(in: .whitespaces)))
                    continue
                }
            }

            if let item = Self.listItem(from: line) {
                flushParagraph()
                listItems.append(item)
                continue
            }

            flushList()
            paragraph.append(line)
        }

        // Unterminated fence (mid-stream message) — show what we have.
        if inCode && !codeLines.isEmpty {
            result.append(.code(codeLines.joined(separator: "\n")))
        }
        flushParagraph(); flushList()
        return result
    }

    /// "- x" / "* x" / "+ x" → ("•", "x");  "12. x" → ("12.", "x").
    private static func listItem(from line: String) -> (marker: String, content: String)? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            return ("•", String(line.dropFirst(prefix.count)))
        }
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") {
                return ("\(digits).", String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    // MARK: Block views

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .paragraph(let s):
            Text(inline(s))
                .font(.system(size: 12))

        case .header(let s):
            Text(inline(s))
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 2)

        case .list(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .font(.system(size: 12, design: item.marker == "•" ? .default : .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                        Text(inline(item.content))
                            .font(.system(size: 12))
                    }
                }
            }

        case .code(let s):
            // Verbatim — no inline parsing inside fences. ScrollView keeps
            // long lines from blowing the bubble width.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(0.05))
            )
        }
    }

    /// Inline markdown (bold / italic / `code` / links) via Foundation.
    /// `.inlineOnlyPreservingWhitespace` keeps intra-paragraph newlines
    /// instead of collapsing them. Falls back to the raw string on malformed
    /// markdown — never drop user content.
    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
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
