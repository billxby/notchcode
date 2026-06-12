// Which coding agent a session belongs to.
//
// Notchcode started as a Claude Code monitor; `Agent` is the seam that lets it
// observe a second first-party agent (OpenAI Codex) through the same two
// ingestion paths — hooks → loopback server, and transcript tailing — without
// the engine hard-coding "claude" everywhere.
//
// Everything agent-specific (config paths, the hook config file, the transcript
// root, the process name we pgrep for liveness, the display label) hangs off
// this enum. Adding a third agent later is "add a case + fill in the switches."
//
// Kept Foundation-only on purpose: the engine/IO layers stay free of SwiftUI.
// The accent COLOR for each agent lives in the UI layer (see Agent+UI / Theme).

import Foundation

enum Agent: String, CaseIterable, Equatable, Codable, Sendable {
    case claude
    case codex

    /// Human label shown in the UI (role tags, badges, settings rows).
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        }
    }

    /// Root config dir: ~/.claude or ~/.codex.
    var configDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".\(rawValue)", isDirectory: true)
    }

    /// The JSON file we additively install hook entries into.
    ///   Claude → ~/.claude/settings.json   (hooks live under the "hooks" key)
    ///   Codex  → ~/.codex/hooks.json        (same {hooks:{Event:[…]}} shape)
    var hookConfigFile: URL {
        switch self {
        case .claude: return configDir.appendingPathComponent("settings.json")
        case .codex:  return configDir.appendingPathComponent("hooks.json")
        }
    }

    /// Root directory under which per-session transcript JSONL lives.
    ///   Claude → ~/.claude/projects/<slug>/<session-id>.jsonl
    ///   Codex  → ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl
    var transcriptRoot: URL {
        switch self {
        case .claude: return configDir.appendingPathComponent("projects", isDirectory: true)
        case .codex:  return configDir.appendingPathComponent("sessions", isDirectory: true)
        }
    }

    /// Substring passed to `pgrep` for the legacy "is any session alive at all"
    /// fallback used when a session never reported its PID.
    var processName: String {
        switch self {
        case .claude: return "claude"
        case .codex:  return "codex"
        }
    }

    /// URL path segment that tags a hook callback: POST /<segment>/hook/<Event>.
    /// The installer bakes this into the curl command so the server knows which
    /// agent fired without inspecting the payload.
    var hookURLSegment: String { rawValue }

    /// Namespace a raw, agent-supplied session id so two agents handing us the
    /// same UUID can never collide in the engine's keyed store.
    func sessionKey(_ rawId: String) -> String { "\(rawValue):\(rawId)" }

    /// Inverse of `sessionKey` — recover the agent from a namespaced key.
    /// Defaults to `.claude` for un-prefixed keys (back-compat / safety).
    static func from(sessionKey key: String) -> Agent {
        guard let colon = key.firstIndex(of: ":") else { return .claude }
        return Agent(rawValue: String(key[key.startIndex..<colon])) ?? .claude
    }
}
