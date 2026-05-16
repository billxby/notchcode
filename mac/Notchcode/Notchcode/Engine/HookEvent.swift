// A normalized representation of a Claude Code hook payload.
//
// Claude Code passes the full hook event JSON on stdin to whatever shell
// command we register. Our HookServer receives that JSON over HTTP, decodes
// only the fields we care about, and discards the rest (Codable ignores
// unknown keys by default — that's our "tolerant decoder" for free).
//
// Why a separate struct instead of decoding into Session directly:
//   - clean test surface (we can construct fake events in unit tests later)
//   - decouples wire format from internal model — if Anthropic renames a key,
//     we adjust here, not in the engine
//
// Flutter analogy: this is the "DTO" — Data Transfer Object — that you'd use
// at the network boundary before mapping into your domain model.

import Foundation

struct HookEvent: Equatable {
    /// The lifecycle moment. We parse this from the URL path our server
    /// receives (e.g. POST /hook/PreToolUse), NOT from the JSON body —
    /// Claude doesn't include the event name inside the payload itself.
    enum Kind: String, Equatable {
        case preToolUse        = "PreToolUse"
        case postToolUse       = "PostToolUse"
        case userPromptSubmit  = "UserPromptSubmit"
        case permissionRequest = "PermissionRequest"   // Claude is waiting on user approval
        case stop              = "Stop"
    }

    let kind: Kind
    let sessionId: String?      // payload key: "session_id"
    let projectPath: String?    // payload key: "cwd" or "project_dir"
    let toolName: String?       // payload key: "tool_name" — only present on PreToolUse / PostToolUse
    /// One short human phrase derived from `tool_input` (e.g. "main.py",
    /// "npm test"). Pre-formatted at decode time so the view layer doesn't
    /// have to understand Claude Code's wire-level argument shapes.
    let toolDetail: String?
    /// v0.95 — Claude Code's process ID, captured by the install-hooks.sh
    /// shim via `$PPID` and forwarded as the `X-Claude-PID` request header.
    /// Lets us SIGTERM a single session from the notch and detect per-session
    /// death without nuking sibling sessions when the global pgrep check
    /// would otherwise come up empty. nil for sessions that landed before
    /// hooks were upgraded — those fall back to a soft-end.
    let claudePid: Int32?
    let receivedAt: Date

    /// Parse a Claude Code hook payload. Returns a HookEvent even if the JSON
    /// is partially malformed — missing optional fields just become nil. We
    /// only fully fail (return nil) if the body is unrecoverable garbage.
    static func decode(kind: Kind, body: Data, claudePid: Int32? = nil, receivedAt: Date = .now) -> HookEvent {
        // Inner structs match Claude's snake_case keys verbatim.
        // Optional everywhere so any subset works.
        struct ToolInput: Decodable {
            let file_path: String?
            let command: String?
            let pattern: String?
            let url: String?
        }
        struct Payload: Decodable {
            let session_id: String?
            let cwd: String?
            let project_dir: String?
            let tool_name: String?
            let tool_input: ToolInput?
        }

        let payload = try? JSONDecoder().decode(Payload.self, from: body)

        // Pick the most informative single field per tool. We don't try to
        // be exhaustive — unknown tools fall through to just the tool name.
        let detail: String? = {
            guard let name = payload?.tool_name, let input = payload?.tool_input else { return nil }
            switch name {
            case "Edit", "Write", "MultiEdit", "Read", "NotebookEdit":
                return input.file_path.map { URL(fileURLWithPath: $0).lastPathComponent }
            case "Bash":
                // Trim to 28 chars so the notch stays glanceable on long commands.
                return input.command.map { $0.count > 28 ? String($0.prefix(28)) + "…" : $0 }
            case "Glob", "Grep":
                return input.pattern
            case "WebFetch", "WebSearch":
                return input.url
            default:
                return nil
            }
        }()

        return HookEvent(
            kind: kind,
            sessionId: payload?.session_id,
            // Claude has used both keys across versions; prefer project_dir
            // when present, fall back to cwd.
            projectPath: payload?.project_dir ?? payload?.cwd,
            toolName: payload?.tool_name,
            toolDetail: detail,
            claudePid: claudePid,
            receivedAt: receivedAt
        )
    }
}
