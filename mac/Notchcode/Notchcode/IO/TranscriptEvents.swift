// Agent-neutral events produced by parsing a coding agent's transcript.
//
// Both transcript parsers — ClaudeJSONLParser (Claude Code's ~/.claude/projects
// JSONL) and CodexRolloutParser (Codex's ~/.codex/sessions rollout JSONL) —
// produce these same types, so the watcher → SessionStateEngine path is
// identical regardless of which agent wrote the file.

import Foundation

/// A single cost-bearing event extracted from one transcript line.
struct CostEvent: Equatable {
    let sessionId: String
    let project: String
    let model: CostTracker.Model
    let usage: CostTracker.Usage
    let timestamp: Date
}

/// A single user or assistant message extracted from one transcript line.
/// Text-only — tool_use / tool_result / image blocks are dropped (the
/// drill-down view is a reading surface, not a tool log).
struct MessageEvent: Equatable {
    enum Role: String, Equatable { case user, assistant }
    let sessionId: String
    let project: String
    let role: Role
    let text: String
    let timestamp: Date
}

/// A coarse turn-boundary signal extracted from a transcript. Currently only
/// Codex emits these: its rollout brackets every turn with `task_started` /
/// `task_complete` event_msg lines, which is the only reliable running/idle
/// signal we have for Codex. Its hook stream can't carry this — Codex fires no
/// `Stop` hook at all, and built-in tools (web search, reasoning) fire no
/// PreToolUse hook, so a hook-only Codex session gets stuck on the wrong
/// status. Claude doesn't need this path (its Stop hook covers it), so
/// ClaudeJSONLParser leaves this array empty.
struct LifecycleEvent: Equatable {
    enum Kind: Equatable {
        case turnStarted     // task_started — Codex is actively running a turn
        case turnCompleted   // task_complete — turn finished
    }
    let sessionId: String
    let project: String
    let kind: Kind
    let timestamp: Date
}

/// Every event stream produced by a single pass over new transcript bytes.
struct ParseResult {
    var costs: [CostEvent] = []
    var messages: [MessageEvent] = []
    var lifecycle: [LifecycleEvent] = []
}
