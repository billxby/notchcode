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
// State design:
//   - `sessions` is the persistent dict; both pipelines mutate it.
//   - Once a session shows up, it stays visible until the `claude` process it
//     belongs to dies. The crash-check timer (`pgrep claude` every 10s) is the
//     eviction mechanism — there's no time-based decay that hides idle sessions
//     while the terminal is still alive.
//   - A 1-second `clockTick` forces SwiftUI to re-evaluate computed properties
//     as time passes. @Observable tracks property reads, not wall-clock time —
//     without this tick, time-sensitive UI (e.g. action timestamps, usage
//     windows rolling over) wouldn't redraw.

import Foundation
import Observation
import AppKit
import Darwin   // kill(), SIGTERM, errno — v0.95 per-session lifecycle controls

@Observable
@MainActor
final class SessionStateEngine {
    static let shared = SessionStateEngine()

    enum Status: Equatable {
        case idle
        /// `tool` nil if hook didn't include it (PostToolUse / streaming) or
        /// file-watcher only. `detail` is a pre-formatted human phrase from
        /// the tool's input (e.g. "main.py", "npm test") — nil if no specific
        /// argument is meaningful or the tool is unknown.
        case working(tool: String?, detail: String?)
        case waiting                  // permission requested — Claude blocked on user
        case done                     // .Stop fired; sticky until acknowledged (see acknowledgeDone)
        case error(String)
    }

    struct Session: Identifiable, Equatable {
        let id: String
        var project: String
        var lastUpdate: Date
        var status: Status = .idle
        /// Bundle ID of the terminal app that was frontmost when the session
        /// last transitioned into `.waiting`. Tapping the notch while this
        /// session is waiting activates this app. nil if no PermissionRequest
        /// has fired yet for this session.
        var terminalBundleID: String? = nil
        /// Capped FIFO of the last 5 tool calls. Populated on each PreToolUse.
        /// Used by the v0.6 popover for the per-session recent-activity feed.
        var recentActions: [Action] = []
        /// v0.7 — running cost for this session in USD, accumulated from
        /// every assistant-message usage block we've parsed out of the JSONL.
        var costUSD: Double = 0
        /// v0.95 — rolling buffer of recent user/assistant text messages,
        /// drives the drill-down view. Capped at `messageHistoryLimit` so a
        /// long-running session can't unbounded the buffer.
        var messages: [Message] = []
        /// v0.95 — Claude Code's process ID for this session, supplied by
        /// the install-hooks.sh shim via X-Claude-PID. Refreshed on every
        /// hook event so a resumed session (`claude -r`) picks up its new
        /// PID. nil for sessions whose hooks haven't sent it yet (legacy
        /// installs) — those fall back to a soft-end.
        var claudePid: Int32? = nil
        /// v0.95 — Claude has exited (detected via per-PID liveness check,
        /// or user clicked End session). Kept in the panel with messages
        /// readable; rendered grayed out. Cleared only by `dismissSession`.
        var ended: Bool = false
    }

    /// One text turn in a conversation. Tool calls, results, and image
    /// blocks are deliberately excluded — see JSONLParser.MessageEvent.
    struct Message: Identifiable, Equatable {
        let id: UUID = UUID()
        let role: Role
        let text: String
        let timestamp: Date

        enum Role: String, Equatable { case user, assistant }
    }

    /// One historical tool invocation. Tied to a Session via the session dict.
    struct Action: Identifiable, Equatable {
        let id: UUID = UUID()
        let toolName: String
        let detail: String?
        let timestamp: Date
    }

    /// Cap on how many actions we retain per session. Read by the popover.
    static let actionHistoryLimit = 5

    /// v0.95 — cap on how many text messages we retain per session for the
    /// drill-down view. 200 turns comfortably covers a multi-hour session
    /// without ballooning memory on a long-running one.
    static let messageHistoryLimit = 200

    /// All sessions seen this app run. Inactive ones stay in the dict so we
    /// can show "12 sessions today" later — they just don't affect aggregate.
    private(set) var sessions: [String: Session] = [:]

    // MARK: - Usage state (rolling 7-day token window)
    //
    // v1.0 redesign: we no longer try to model Anthropic's 5-hour session
    // blocks. The block anchor can only be inferred from events we happen to
    // see locally, so the derived "resets in" time and %-of-plan were wrong
    // whenever the user worked from another device or the app missed events.
    // Instead we report what we can actually measure: exact token counts
    // from this Mac's JSONLs, over windows with no hidden anchor — a rolling
    // 7 days (primary) and the current calendar day. The brake compares the
    // weekly total against a USER-SET budget, not a guessed plan limit.

    /// One observed assistant-message worth of usage, timestamped.
    struct UsageEvent: Equatable {
        let sessionId: String
        let tokens: Int       // input + output + cache_create (NOT cache_read)
        let usd: Double       // API-rate equivalent
        let at: Date
    }

    /// Rolling buffer of all events in (now - weekSeconds, now]. Order is
    /// insertion order (≈ chronological). Pruned lazily on each access.
    private var usageBuffer: [UsageEvent] = []
    nonisolated static let weekSeconds: TimeInterval = 7 * 24 * 60 * 60

    /// Running totals over the buffer — incremented in `recordUsage`,
    /// decremented in `pruneExpired` as events age out. Kept as counters
    /// because the clockTick-driven computed properties re-evaluate every
    /// second; reducing a week's worth of events each tick is too hot.
    private var weeklyTokensTotal: Int = 0
    private var weeklyDollarsTotal: Double = 0

    /// Tokens observed in the last 7 days. Drives the badge and (against the
    /// user's weekly budget) the brake threshold check.
    var weeklyTokens: Int {
        _ = clockTick
        pruneExpired()
        return weeklyTokensTotal
    }

    /// API-rate dollar total over the last 7 days. Informational for
    /// subscription tiers ("≈$X if billed at API rates").
    var weeklyDollars: Double {
        _ = clockTick
        pruneExpired()
        return weeklyDollarsTotal
    }

    /// Tokens observed today (calendar day, local time). Walks the buffer
    /// from the back and stops at the first pre-midnight event, so the cost
    /// scales with today's activity, not the whole week.
    var todayTokens: Int {
        _ = clockTick
        pruneExpired()
        let startOfDay = Calendar.current.startOfDay(for: Date())
        var total = 0
        for ev in usageBuffer.reversed() {
            if ev.at < startOfDay { break }
            total += ev.tokens
        }
        return total
    }

    /// API-rate dollars spent today. The primary metric for `.api` tier —
    /// matches the "Daily $ cap" setting's actual semantics.
    var dollarsToday: Double {
        _ = clockTick
        pruneExpired()
        let startOfDay = Calendar.current.startOfDay(for: Date())
        var total: Double = 0
        for ev in usageBuffer.reversed() {
            if ev.at < startOfDay { break }
            total += ev.usd
        }
        return total
    }

    /// 0…1 fraction of the user's budget consumed. API tier: $ today vs the
    /// daily cap. Subscription: weekly tokens vs the user-set weekly budget.
    /// > 1.0 is possible (you blew through the budget); UI caps display at 100%.
    var usageFraction: Double {
        let settings = AppSettings.shared
        if settings.planTier.usesDollarBudget {
            let cap = settings.dailyCapUSD
            return cap > 0 ? dollarsToday / cap : 0
        }
        let budget = Double(settings.weeklyTokenBudget)
        return budget > 0 ? Double(weeklyTokens) / budget : 0
    }

    /// True once usageFraction crosses the user-set threshold AND the user
    /// hasn't dismissed today.
    private var brakeDismissedAt: Date? = nil
    var brakeEngaged: Bool {
        _ = clockTick
        guard AppSettings.shared.usageTrackingEnabled else { return false }
        // "Dismiss for today" — quiet until the calendar day rolls over.
        if let dismissedAt = brakeDismissedAt,
           Calendar.current.isDate(dismissedAt, inSameDayAs: Date()) {
            return false
        }
        return usageFraction >= AppSettings.shared.brakeThresholdPercent
    }

    /// Drop events older than `weekSeconds`, keeping the running totals in
    /// sync. Called from every reader so the buffer stays bounded without a
    /// separate timer.
    private func pruneExpired() {
        let cutoff = Date().addingTimeInterval(-Self.weekSeconds)
        while let first = usageBuffer.first, first.at < cutoff {
            weeklyTokensTotal -= first.tokens
            weeklyDollarsTotal -= first.usd
            usageBuffer.removeFirst()
        }
    }

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
        let wasWaiting = (session.status == .waiting)
        session.lastUpdate = event.receivedAt
        if !project.isEmpty { session.project = project }
        // v0.95 — refresh the PID on every hook event. A resumed session
        // (`claude -r`) gets a new PID; keep ours current. Receiving any
        // hook also un-ends the session: Claude has clearly come back to
        // life (e.g., user reopened the terminal and resumed).
        if let pid = event.claudePid {
            session.claudePid = pid
            session.ended = false
        }

        switch event.kind {
        case .preToolUse:
            session.status = .working(tool: event.toolName, detail: event.toolDetail)
            // Append to the history feed, evicting the oldest if we'd exceed
            // the cap. Only PreToolUse contributes — PostToolUse and Stop
            // describe state transitions, not new invocations.
            if let name = event.toolName {
                let action = Action(toolName: name, detail: event.toolDetail, timestamp: event.receivedAt)
                session.recentActions.append(action)
                if session.recentActions.count > Self.actionHistoryLimit {
                    session.recentActions.removeFirst(session.recentActions.count - Self.actionHistoryLimit)
                }
            }
        case .postToolUse:
            // Brief gap before the next preToolUse OR a Stop. Keep it as
            // "working" without a tool name so the UI doesn't jitter to idle.
            session.status = .working(tool: nil, detail: nil)
        case .userPromptSubmit:
            // User just hit enter — Claude is now THINKING, not waiting on user.
            // The naming is confusing: "UserPromptSubmit" means the user
            // already submitted; from this moment forward Claude owns the turn.
            session.status = .working(tool: nil, detail: nil)
            // The user JUST typed in the terminal running `claude`, so the
            // frontmost app is the most reliable terminal capture we get —
            // better than waiting for a PermissionRequest that may never
            // fire (auto-approved sessions). Refresh on every submit: a
            // resumed session (`claude -r`) can move to a different terminal.
            session.terminalBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        case .permissionRequest:
            // Real "waiting on you" — Claude is paused, blocked on the user
            // approving a tool action. Stays waiting until the next
            // preToolUse (granted) or Stop (denied/cancelled) flips it.
            session.status = .waiting
            // Capture the frontmost app at hook fire time so the notch can
            // activate it on tap. Claude Code is synchronously blocked on
            // this hook, so whatever's frontmost right now is almost always
            // the terminal running `claude`. Only refresh on the entry edge —
            // re-firing PermissionRequest shouldn't overwrite the recorded
            // terminal if the user has since switched away.
            if !wasWaiting {
                session.terminalBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            }
        case .stop:
            // Sticky by design: the checkmark persists until the user taps
            // the pill (acknowledgeDone) or the session does new work. A 2s
            // flash was trivially missed by anyone not staring at the menubar;
            // a checkmark that waits to be dismissed doubles as the "your
            // task finished, go look at it" reminder.
            session.status = .done
        }

        sessions[id] = session
    }

    // MARK: - Usage ingestion

    /// Called by ProjectsWatcher for each parsed assistant message. Appends
    /// to the rolling window AND updates per-session running totals. Caller
    /// is responsible for not double-counting (JSONLParser handles that via
    /// per-file byte offsets).
    ///
    /// Session-row gating: the weekly catch-up replays up to 7 days of
    /// history, and we don't want a launch to resurrect a week of dead
    /// sessions in the panel. Usage always lands in the buffer; the
    /// per-session cost only updates sessions that already exist or whose
    /// event is recent enough to be a live session (the hooks/file-watcher
    /// create the row within seconds for anything actually running).
    func recordUsage(
        sessionId: String,
        project: String,
        tokens: Int,
        usd: Double,
        at date: Date = .now
    ) {
        // Buffer is event-level; bounded by pruneExpired() on every read.
        usageBuffer.append(UsageEvent(sessionId: sessionId, tokens: tokens, usd: usd, at: date))
        weeklyTokensTotal += tokens
        weeklyDollarsTotal += usd

        let isRecent = Date().timeIntervalSince(date) < staleTimeout
        guard var session = sessions[sessionId]
            ?? (isRecent ? Session(id: sessionId, project: project, lastUpdate: date) : nil)
        else { return }
        if !project.isEmpty { session.project = project }
        session.costUSD += usd
        sessions[sessionId] = session
    }

    /// v0.95 — append a parsed text message to the session's rolling buffer.
    /// Capped at `messageHistoryLimit`; oldest entries evicted FIFO. Caller
    /// is responsible for de-duping via JSONLParser's per-file byte cursor.
    /// Same session-row gating as `recordUsage` — week-old transcripts
    /// shouldn't materialize dead sessions in the panel.
    func recordMessage(
        sessionId: String,
        project: String,
        role: Message.Role,
        text: String,
        at date: Date = .now
    ) {
        let isRecent = Date().timeIntervalSince(date) < staleTimeout
        guard var session = sessions[sessionId]
            ?? (isRecent ? Session(id: sessionId, project: project, lastUpdate: date) : nil)
        else { return }
        if !project.isEmpty { session.project = project }
        session.messages.append(Message(role: role, text: text, timestamp: date))
        if session.messages.count > Self.messageHistoryLimit {
            session.messages.removeFirst(session.messages.count - Self.messageHistoryLimit)
        }
        sessions[sessionId] = session
    }

    /// User clicked "Dismiss for today" — quiet the brake until the calendar
    /// day rolls over.
    func dismissBrake() {
        brakeDismissedAt = Date()
    }

    /// The "I saw it" acknowledgment for the sticky done checkmark. Flips
    /// every done session back to idle so the pill contracts. Fired by the
    /// first tap on the pill while the checkmark shows (the second tap opens
    /// the panel as usual), and when the panel collapses while everything
    /// reads done — having the full panel open counts as seeing it.
    func acknowledgeDone() {
        for (id, var session) in sessions where session.status == .done {
            session.status = .idle
            sessions[id] = session
        }
    }

    // MARK: - Lifecycle controls (v0.95)

    /// User clicked End session in the drill-down. Sends SIGTERM to the
    /// captured Claude Code PID (so it shuts down gracefully and flushes the
    /// JSONL) and marks the session as ended so the panel renders it grayed.
    /// If no PID is known (legacy hooks that didn't forward X-Claude-PID), we
    /// soft-end: just flip the flag — the user has to `/exit` in the
    /// terminal themselves.
    @discardableResult
    func endSession(id: String) -> Bool {
        guard var session = sessions[id] else { return false }
        var signaled = false
        if let pid = session.claudePid, Self.isProcessAlive(pid) {
            // SIGTERM, not SIGKILL — let claude trap and flush.
            _ = kill(pid, SIGTERM)
            signaled = true
        }
        session.ended = true
        session.status = .idle
        sessions[id] = session
        return signaled
    }

    /// User clicked Remove on an ended session. Drop it from the panel
    /// entirely — messages are forgotten. The drill-down view's
    /// selectedSessionId will resolve to nil after this, and the view's
    /// "session ended" fallback takes over until the user navigates back.
    func dismissSession(id: String) {
        sessions.removeValue(forKey: id)
    }

    // MARK: - Outputs (read by NotchView)

    /// Sessions that are "alive" right now. A session sticks around once we've
    /// seen it — only `runCrashCheck` (claude process death) evicts it. Idle
    /// is a real state, not a "fade out" state; users want the row visible so
    /// they can see the project name and recent actions until they kill the
    /// terminal.
    ///
    /// `staleTimeout` is a hard ceiling for *mid-turn* sessions only: if a
    /// .working/.waiting session hasn't updated in 10 minutes, we assume
    /// Claude Code crashed mid-turn without sending Stop. Idle and done
    /// sessions bypass this — they completed cleanly; done in particular is
    /// deliberately sticky (the checkmark must outlive any timeout until the
    /// user acknowledges it), and only process death should hide either.
    ///
    /// The read of `clockTick` forces SwiftUI to re-call this as time passes.
    var activeSessions: [Session] {
        _ = clockTick
        let staleCutoff = Date().addingTimeInterval(-staleTimeout)
        return sessions.values.filter { session in
            if session.status == .idle || session.status == .done { return true }
            return session.lastUpdate >= staleCutoff
        }
    }

    /// Aggregated status across all active sessions. Priority order:
    ///   .error > .waiting > .working(with tool) > .working(plain) > .done > .idle
    ///
    /// Idle sessions aggregate to idle — they hang around in the panel until
    /// the terminal dies (see `runCrashCheck`), but they shouldn't make the
    /// pill animate as if work is happening. Only explicit .working / .waiting
    /// / .error from hooks promote the aggregate out of idle.
    ///
    /// Ended sessions are excluded: they're visible in the panel for history
    /// purposes but shouldn't keep the pill working/waiting after the
    /// terminal closed.
    var aggregateStatus: Status {
        _ = clockTick
        let actives = activeSessions.filter { !$0.ended }
        guard !actives.isEmpty else { return .idle }

        var hasWaiting = false
        var workingNamed: (tool: String, detail: String?)? = nil
        var hasWorkingPlain = false
        var hasDone = false

        for s in actives {
            switch s.status {
            case .error(let msg):
                return .error(msg)              // short-circuit highest priority
            case .waiting:
                hasWaiting = true
            case .working(let tool?, let detail):
                if workingNamed == nil { workingNamed = (tool, detail) }
            case .working(nil, _):
                hasWorkingPlain = true
            case .done:
                hasDone = true
            case .idle:
                break                            // idle never promotes
            }
        }

        if hasWaiting           { return .waiting }
        if let w = workingNamed { return .working(tool: w.tool, detail: w.detail) }
        if hasWorkingPlain      { return .working(tool: nil, detail: nil) }
        if hasDone              { return .done }
        return .idle
    }

    // MARK: - Internals

    /// Turn `/Users/you/notchcode` into `notchcode` for display. Full path
    /// decoding (slug → real path) lives in v0.6 popover.
    private static func decodeProject(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: - Crash detection (v0.95: per-PID liveness)

    /// Runs every 10s. For each non-ended session with a captured PID, checks
    /// `kill -0 pid`; if the process is gone we mark the session ended (NOT
    /// removed — messages stay readable until the user dismisses). Sessions
    /// without a captured PID fall back to the legacy pgrep-all check so
    /// users still on old hooks don't get permanently-ghosted sessions.
    private func runCrashCheck() async {
        guard !sessions.isEmpty else { return }

        // Per-PID liveness: cheap, off-main not needed (kill -0 is a syscall).
        var changed = false
        for (id, var session) in sessions where !session.ended {
            guard let pid = session.claudePid else { continue }
            if !Self.isProcessAlive(pid) {
                session.ended = true
                session.status = .idle
                sessions[id] = session
                changed = true
            }
        }
        if changed {
            print("[Notchcode] Per-PID liveness check ended one or more sessions.")
        }

        // Legacy fallback for sessions that never reported a PID. If no
        // claude process is alive *anywhere*, those sessions are definitely
        // dead — mark them ended too.
        let untracked = sessions.values.contains { !$0.ended && $0.claudePid == nil }
        guard untracked else { return }

        let anyAlive = await Self.isAnyClaudeProcessRunning()
        guard !anyAlive else { return }

        for (id, var session) in sessions where !session.ended && session.claudePid == nil {
            session.ended = true
            session.status = .idle
            sessions[id] = session
        }
        print("[Notchcode] No `claude` processes found — ending PID-less sessions.")
    }

    /// `kill(pid, 0)` is the canonical POSIX liveness probe — sends no
    /// signal, just returns 0 if the process exists (and we have permission
    /// to signal it). Errno ESRCH means the PID is gone.
    nonisolated static func isProcessAlive(_ pid: Int32) -> Bool {
        return kill(pid, 0) == 0 || errno == EPERM
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
