// The single source of truth for "what are Claude Code sessions doing right now."
//
// Architecture (Flutter analogy):
//   - @Observable        ≈ Riverpod Notifier. Properties read inside a SwiftUI
//                          `body` auto-subscribe; mutating them re-renders the
//                          view tree. No manual notifyListeners() call.
//   - @MainActor         ≈ "this lives on the UI isolate." All methods must be
//                          called from the main thread. Compiler enforces it.
//   - shared singleton   ≈ a top-level Riverpod provider — one instance per app.
//
// State design:
//   - We track sessions in a dict keyed by sessionId (the JSONL filename UUID).
//   - A session's `lastUpdate` is bumped every time its file is touched.
//   - "Active" means lastUpdate is within the last `activeWindow` seconds.
//   - A 1-second timer ticks `clockTick` to force the computed `aggregateStatus`
//     to re-evaluate as time passes (otherwise SwiftUI wouldn't know to redraw
//     just because 5 seconds elapsed — observation tracks property reads, not
//     wall-clock time).

import Foundation
import Observation

@Observable
@MainActor
final class SessionStateEngine {
    static let shared = SessionStateEngine()

    enum Status: Equatable {
        case idle
        case working    // v0.2: any session active. Tool name comes in v0.3 hooks.
        // .waiting / .done / .error land in v0.3+.
    }

    struct Session: Identifiable, Equatable {
        let id: String          // JSONL filename UUID
        var project: String     // human-readable project name
        var lastUpdate: Date
    }

    /// All sessions we've ever seen this app run. Inactive ones stay in the
    /// dict so we can show "12 sessions today" later — they just don't count
    /// toward `aggregateStatus`.
    private(set) var sessions: [String: Session] = [:]

    /// A session counts as "working" if its file was touched within this
    /// window. Tunable; 5s is a reasonable bet given Claude Code typically
    /// streams tokens / writes JSONL several times per second when active.
    private let activeWindow: TimeInterval = 5

    /// Bumped every second by `decayTimer`. Reading it from a computed
    /// property causes SwiftUI to re-evaluate that property each tick — this
    /// is how the notch "decays back to idle" without manual UI invalidation.
    private var clockTick: Int = 0

    private var decayTimer: Timer?

    private init() {
        // Schedule a heartbeat. Closure runs on main run loop. We bump
        // clockTick which @Observable picks up as a state change.
        decayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            // Timer callbacks aren't main-actor-isolated by default in modern
            // Swift concurrency; hop onto MainActor explicitly.
            Task { @MainActor [weak self] in
                self?.clockTick &+= 1   // &+= = wrapping add, never overflows
            }
        }
    }

    // MARK: - Inputs (called by ProjectsWatcher / HookServer)

    /// File watcher tells us "this session's JSONL was just modified."
    func sessionFileTouched(sessionId: String, project: String, at date: Date = .now) {
        if var existing = sessions[sessionId] {
            existing.lastUpdate = date
            existing.project = project   // refresh in case the slug changed
            sessions[sessionId] = existing
        } else {
            sessions[sessionId] = Session(id: sessionId, project: project, lastUpdate: date)
        }
    }

    // MARK: - Outputs (read by NotchView)

    /// Sessions whose file was touched within `activeWindow`. The read of
    /// `clockTick` here is intentional — it forces SwiftUI to re-call this
    /// computed property every second so decay is reflected in the UI.
    var activeSessions: [Session] {
        _ = clockTick   // dependency hook; never delete this
        let cutoff = Date().addingTimeInterval(-activeWindow)
        return sessions.values.filter { $0.lastUpdate >= cutoff }
    }

    var aggregateStatus: Status {
        activeSessions.isEmpty ? .idle : .working
    }
}
