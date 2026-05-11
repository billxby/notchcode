// The single source of truth for "what are Claude Code sessions doing right now."
//
// Two input pipelines feed this engine:
//   1. ProjectsWatcher (FSEventStream) → sessionFileTouched(...) — coarse,
//      "this session is alive" signal. Bumps lastUpdate; doesn't change status.
//   2. HookServer (NWListener) → handleHookEvent(...) — precise per-event signal
//      from Claude Code's hook system. Sets explicit status (.working / .waiting / etc.)
//
// One output pipeline:
//   3. NotchView reads `aggregateStatus` and `activeSessions` — @Observable
//      auto-tracking re-renders on any mutation here.
//
// Architecture (Flutter analogy):
//   - @Observable        ≈ Riverpod Notifier; reads inside `body` auto-subscribe
//   - @MainActor         ≈ "this lives on the UI isolate"
//   - shared singleton   ≈ a top-level provider, one per app
//
// State design:
//   - `sessions` is the persistent dict; both pipelines mutate it.
//   - "Active" means lastUpdate is within `activeWindow` seconds. Inactive
//     sessions stay in the dict (for future "history" features) but stop
//     contributing to aggregateStatus.
//   - A 1-second `clockTick` forces SwiftUI to re-evaluate computed properties
//     as time passes. @Observable tracks property reads, not wall-clock time —
//     without this tick, "decay back to idle 5s later" wouldn't redraw.

import Foundation
import Observation

@Observable
@MainActor
final class SessionStateEngine {
    static let shared = SessionStateEngine()

    enum Status: Equatable {
        case idle
        case working(tool: String?)   // tool nil if hook didn't include it (PostToolUse) or file-watcher only
        case waiting                  // user prompt expected
        case done                     // .Stop fired; transient (~2s) before idle
        case error(String)
    }

    struct Session: Identifiable, Equatable {
        let id: String
        var project: String
        var lastUpdate: Date
        var status: Status = .idle
    }

    /// All sessions seen this app run. Inactive ones stay in the dict so we
    /// can show "12 sessions today" later — they just don't affect aggregate.
    private(set) var sessions: [String: Session] = [:]

    /// File-watcher fallback: how long after a JSONL mtime nudge a session
    /// without explicit hook status stays "alive." Short because the v0.2
    /// signal is continuous while Claude streams — 5s covers brief stream gaps.
    private let activeWindow: TimeInterval = 5

    /// Safety horizon for sessions whose status is explicit (.working, .waiting,
    /// etc.) but haven't seen ANY update — meaning Claude Code probably crashed
    /// mid-turn before sending Stop. 10 min comfortably covers slow Bash calls
    /// like `npm install` while still eventually clearing stale state.
    private let staleTimeout: TimeInterval = 600

    /// Bumped every second by `decayTimer`. Reading it inside computed
    /// properties forces SwiftUI to re-evaluate them every tick.
    private var clockTick: Int = 0

    private var decayTimer: Timer?
    private var crashCheckTimer: Timer?

    private init() {
        decayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.clockTick &+= 1
            }
        }

        // Active crash detector. Every 10s, if we're tracking any non-idle
        // session, shell out to `pgrep claude` off-main; if nothing matches,
        // every active session is dead (Ctrl-C, closed terminal, killed
        // process). Evict immediately instead of waiting 10 min for the
        // staleTimeout safety net to kick in.
        crashCheckTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.runCrashCheck()
            }
        }
    }

    // MARK: - Inputs

    /// File watcher signal: "this session's JSONL was just modified."
    /// Doesn't override hook-supplied status; only bumps lastUpdate so the
    /// session keeps showing up in `activeSessions`.
    func sessionFileTouched(sessionId: String, project: String, at date: Date = .now) {
        if var existing = sessions[sessionId] {
            existing.lastUpdate = date
            existing.project = project
            sessions[sessionId] = existing
        } else {
            sessions[sessionId] = Session(id: sessionId, project: project, lastUpdate: date)
        }
    }

    /// Hook signal: a precise lifecycle event from Claude Code.
    func handleHookEvent(_ event: HookEvent) {
        // Sessions without an ID are still useful (Claude Code generally
        // includes session_id, but be defensive) — bucket them all together.
        let id = event.sessionId ?? "anonymous"
        let project = Self.decodeProject(event.projectPath)
        var session = sessions[id] ?? Session(id: id, project: project, lastUpdate: event.receivedAt)
        session.lastUpdate = event.receivedAt
        if !project.isEmpty { session.project = project }

        switch event.kind {
        case .preToolUse:
            session.status = .working(tool: event.toolName)
        case .postToolUse:
            // Brief gap before the next preToolUse OR a Stop. Keep it as
            // "working" without a tool name so the UI doesn't jitter to idle.
            session.status = .working(tool: nil)
        case .userPromptSubmit:
            // User just hit enter — Claude is now THINKING, not waiting on user.
            // The naming is confusing: "UserPromptSubmit" means the user
            // already submitted; from this moment forward Claude owns the turn.
            session.status = .working(tool: nil)
        case .permissionRequest:
            // Real "waiting on you" — Claude is paused, blocked on the user
            // approving a tool action. Stays waiting until the next
            // preToolUse (granted) or Stop (denied/cancelled) flips it.
            session.status = .waiting
        case .stop:
            session.status = .done
            scheduleDecayToIdle(sessionId: id)
        }

        sessions[id] = session
    }

    // MARK: - Outputs (read by NotchView)

    /// Sessions that are "alive" right now. Two rules:
    ///
    ///  1. A session with explicit hook status (.working / .waiting / .done /
    ///     .error) is alive until the status itself changes — long Bash calls
    ///     or slow tool runs must not silently flip the notch to idle just
    ///     because no hook has fired in 5s. The next hook event will replace
    ///     the status; that's how it leaves "alive."
    ///  2. A session with .idle status (file-watcher signal only) decays after
    ///     `activeWindow` of mtime silence — same as v0.2 behavior.
    ///
    /// `staleTimeout` is a hard ceiling: if a session's `lastUpdate` is older
    /// than 10 minutes regardless of status, we assume Claude Code crashed
    /// mid-turn without sending Stop, and drop it from the active set.
    ///
    /// The read of `clockTick` forces SwiftUI to re-call this as time passes.
    var activeSessions: [Session] {
        _ = clockTick
        let now = Date()
        let staleCutoff = now.addingTimeInterval(-staleTimeout)
        let activityCutoff = now.addingTimeInterval(-activeWindow)
        return sessions.values.filter { session in
            // Hard ceiling — drop genuinely stale sessions.
            guard session.lastUpdate >= staleCutoff else { return false }
            // Explicit status sticks until a hook contradicts it.
            if session.status != .idle { return true }
            // Pure file-watcher signal — use the short activity window.
            return session.lastUpdate >= activityCutoff
        }
    }

    /// Aggregated status across all active sessions. Priority order:
    ///   .error > .waiting > .working(with tool) > .working(plain) > .done > .idle
    ///
    /// A session whose status is .idle but was recently touched (file-watcher
    /// only, no hooks) counts as plain working — that's the "degraded mode"
    /// when the user hasn't installed hooks yet.
    var aggregateStatus: Status {
        _ = clockTick
        let actives = activeSessions
        guard !actives.isEmpty else { return .idle }

        var hasWaiting = false
        var workingWithTool: String? = nil
        var hasWorkingPlain = false
        var hasDone = false
        var hasIdleButTouched = false

        for s in actives {
            switch s.status {
            case .error(let msg):
                return .error(msg)              // short-circuit highest priority
            case .waiting:
                hasWaiting = true
            case .working(let tool?):
                if workingWithTool == nil { workingWithTool = tool }
            case .working(nil):
                hasWorkingPlain = true
            case .done:
                hasDone = true
            case .idle:
                hasIdleButTouched = true        // file-watcher signal only
            }
        }

        if hasWaiting                  { return .waiting }
        if let tool = workingWithTool  { return .working(tool: tool) }
        if hasWorkingPlain || hasIdleButTouched { return .working(tool: nil) }
        if hasDone                     { return .done }
        return .idle
    }

    // MARK: - Internals

    /// After a Stop, leave the "done" badge visible for 2s, then decay to idle.
    private func scheduleDecayToIdle(sessionId: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            if var s = self.sessions[sessionId], s.status == .done {
                s.status = .idle
                self.sessions[sessionId] = s
            }
        }
    }

    /// Turn `/Users/you/notchcode` into `notchcode` for display. Full path
    /// decoding (slug → real path) lives in v0.6 popover.
    private static func decodeProject(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: - Crash detection

    /// Runs every 10s. Skips entirely if no session is currently non-idle (no
    /// work to do). Otherwise probes `pgrep claude` off-main; if zero Claude
    /// Code processes are alive but we still have non-idle sessions, the user
    /// has killed every Claude session — evict them all immediately.
    private func runCrashCheck() async {
        let hasNonIdle = sessions.values.contains { $0.status != .idle }
        guard hasNonIdle else { return }

        let alive = await Self.isAnyClaudeProcessRunning()
        guard !alive else { return }

        print("[Notchcode] No `claude` processes found — evicting \(sessions.count) tracked session(s).")
        for (id, var session) in sessions where session.status != .idle {
            session.status = .idle
            // Stamp into the past so activeSessions excludes it immediately,
            // regardless of which branch (status / activity window) it matched.
            session.lastUpdate = .distantPast
            sessions[id] = session
        }
    }

    /// `pgrep claude` — substring match against process names. Exit code 0 = at
    /// least one match. We deliberately keep the match loose so installations
    /// like `claude-1m` or `claude-code` also count as "alive."
    ///
    /// Runs off the main actor via Task.detached because `Process.run()` blocks
    /// until the child exits (typically <5ms for pgrep, but never on main).
    nonisolated private static func isAnyClaudeProcessRunning() async -> Bool {
        await Task.detached(priority: .utility) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            task.arguments = ["claude"]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            do {
                try task.run()
                task.waitUntilExit()
                return task.terminationStatus == 0
            } catch {
                // pgrep failed for some reason (PATH issue, exec error). Don't
                // false-evict — pretend everything is fine.
                return true
            }
        }.value
    }
}
