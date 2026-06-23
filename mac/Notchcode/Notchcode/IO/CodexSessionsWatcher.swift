// Watches ~/.codex/sessions/ recursively and pings the engine whenever a Codex
// rollout JSONL is created or modified. The Codex analog of ClaudeProjectsWatcher.
//
// Layout differs from Claude Code:
//   ~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl
// so we watch recursively (the date dirs nest three deep) and derive the
// session id from the filename's trailing UUID — which matches the session_id
// Codex sends in its hook payloads, so hook-driven and transcript-driven rows
// for the same session collapse into one (namespaced `codex:<uuid>`).
//
// Parsing is delegated to CodexRolloutParser; engine writes mirror
// ClaudeProjectsWatcher exactly, just with `agent: .codex` and the Codex model.

import Foundation

@MainActor
final class CodexSessionsWatcher {
    static let shared = CodexSessionsWatcher()
    private init() {}

    private var stream: FSEventStreamRef?
    private weak var engine: SessionStateEngine?

    private var watchPath: String { Agent.codex.transcriptRoot.path }

    func start(engine: SessionStateEngine) {
        guard stream == nil else { return }   // idempotent
        self.engine = engine

        let path = watchPath
        if !FileManager.default.fileExists(atPath: path) {
            print("[Notchcode] ~/.codex/sessions/ not found yet. Run Codex once to create it.")
        }

        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info = info else { return }
            let watcher = Unmanaged<CodexSessionsWatcher>.fromOpaque(info).takeUnretainedValue()
            let pathArray = unsafeBitCast(paths, to: NSArray.self) as! [String]
            Task { @MainActor in
                for p in pathArray { watcher.handle(rawPath: p) }
            }
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
            )
        )

        guard let stream else {
            print("[Notchcode] Codex FSEventStreamCreate returned nil. Codex watcher disabled.")
            return
        }

        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        print("[Notchcode] Watching \(path)")

        // Live stream starts BEFORE the catch-up scan on purpose — see the long
        // note in ClaudeProjectsWatcher.start(). Both paths share the single
        // `CodexRolloutParser` actor's atomic per-file cursor, so interleaving
        // can't double-count; starting the stream first avoids dropping writes
        // that land mid-scan (FSEvents won't replay pre-start writes).
        catchUpWeek(rootPath: path)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: - Boot-time catch-up

    /// Recursively walk the date dirs once, parsing every rollout file whose
    /// mtime falls within the engine's 7-day usage window.
    private func catchUpWeek(rootPath: String) {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: rootPath)
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else { return }

        let windowStart = Date().addingTimeInterval(-SessionStateEngine.weekSeconds)
        var recentFiles: [URL] = []
        for case let url as URL in enumerator {
            guard Self.isRolloutFile(url) else { continue }
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let mtime = vals?.contentModificationDate ?? .distantPast
            if mtime >= windowStart { recentFiles.append(url) }
        }
        guard !recentFiles.isEmpty else { return }

        Task.detached(priority: .utility) { [weak engine = self.engine] in
            var allCosts: [CostEvent] = []
            var allMessages: [MessageEvent] = []
            var allLifecycle: [LifecycleEvent] = []
            for url in recentFiles {
                let sid = Self.sessionId(from: url)
                let result = await CodexRolloutParser.shared.parseNew(at: url, sessionId: sid, fallbackProject: "")
                allCosts.append(contentsOf: result.costs)
                allMessages.append(contentsOf: result.messages)
                allLifecycle.append(contentsOf: result.lifecycle)
            }
            allCosts.removeAll { $0.timestamp < windowStart }
            allCosts.sort { $0.timestamp < $1.timestamp }
            allMessages.sort { $0.timestamp < $1.timestamp }
            // Lifecycle status is recency-gated in the engine; sorting keeps
            // the last boundary per session winning if a turn straddles boot.
            allLifecycle.sort { $0.timestamp < $1.timestamp }

            guard let engine,
                  !allCosts.isEmpty || !allMessages.isEmpty || !allLifecycle.isEmpty
            else { return }
            let costs = allCosts
            let messages = allMessages
            let lifecycle = allLifecycle
            await MainActor.run {
                Self.ingest(costs: costs, messages: messages, lifecycle: lifecycle, into: engine)
            }
        }
    }

    // MARK: - Event handling

    private func handle(rawPath: String) {
        let url = URL(fileURLWithPath: rawPath)
        guard Self.isRolloutFile(url) else { return }

        let sessionId = Self.sessionId(from: url)
        // Liveness bump (project filled in once a session_meta line is parsed).
        engine?.sessionFileTouched(sessionId: sessionId, agent: .codex, project: "")

        Task.detached(priority: .utility) { [weak engine = self.engine] in
            let result = await CodexRolloutParser.shared.parseNew(at: url, sessionId: sessionId, fallbackProject: "")
            guard !result.costs.isEmpty || !result.messages.isEmpty || !result.lifecycle.isEmpty,
                  let engine else { return }
            await MainActor.run {
                Self.ingest(costs: result.costs, messages: result.messages, lifecycle: result.lifecycle, into: engine)
            }
        }
    }

    /// Shared engine-write path for both catch-up and live events.
    private static func ingest(
        costs: [CostEvent],
        messages: [MessageEvent],
        lifecycle: [LifecycleEvent],
        into engine: SessionStateEngine
    ) {
        for ev in costs {
            let usd = CostTracker.cost(for: ev.usage, model: ev.model)
            // input + output(+reasoning) + cached-input. Codex has no separate
            // cache-write lane, so this is the full billable token count.
            let tokens = ev.usage.inputTokens
                         + ev.usage.outputTokens
                         + ev.usage.cacheReadTokens
            guard tokens > 0 else { continue }
            engine.recordUsage(
                sessionId: ev.sessionId,
                agent: .codex,
                project: ev.project,
                tokens: tokens,
                usd: usd,
                at: ev.timestamp
            )
        }
        for msg in messages {
            engine.recordMessage(
                sessionId: msg.sessionId,
                agent: .codex,
                project: msg.project,
                role: msg.role == .user ? .user : .assistant,
                text: msg.text,
                at: msg.timestamp
            )
        }
        // Applied last so the session's running/idle status reflects the most
        // recent turn boundary, not whatever order costs/messages landed in.
        for ev in lifecycle {
            engine.recordLifecycle(
                sessionId: ev.sessionId,
                agent: .codex,
                project: ev.project,
                kind: ev.kind,
                at: ev.timestamp
            )
        }
    }

    // MARK: - Filename helpers

    nonisolated private static func isRolloutFile(_ url: URL) -> Bool {
        url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-")
    }

    /// Extract the trailing UUID from `rollout-<timestamp>-<uuid>.jsonl`. The
    /// UUID is the final five hyphen-delimited groups (8-4-4-4-12). Matches the
    /// `session_id` Codex sends in hook payloads so the two ingestion paths key
    /// to the same session. Falls back to the full stem if no UUID is found.
    nonisolated static func sessionId(from url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent   // rollout-<ts>-<uuid>
        let parts = stem.split(separator: "-")
        if parts.count >= 5 {
            let candidate = parts.suffix(5).joined(separator: "-")
            if isUUID(candidate) { return candidate }
        }
        return stem
    }

    /// True if `s` is a canonical 8-4-4-4-12 hex UUID. The old `count == 36`
    /// check accepted any 36-character string, so a rollout filename whose
    /// timestamp carried extra hyphens (e.g. `…T10-00-00-<uuid>`) could slip a
    /// non-UUID trailing token past it — keying the file path differently from
    /// the hook payload's `session_id` and splitting the session's state across
    /// the two ingestion paths.
    nonisolated static func isUUID(_ s: String) -> Bool {
        let groups = s.split(separator: "-", omittingEmptySubsequences: false)
        let widths = [8, 4, 4, 4, 12]
        guard groups.count == widths.count else { return false }
        for (group, width) in zip(groups, widths) {
            guard group.count == width,
                  group.allSatisfy(\.isHexDigit) else { return false }
        }
        return true
    }
}
