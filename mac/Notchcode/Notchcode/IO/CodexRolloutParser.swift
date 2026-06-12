// Incremental parser for OpenAI Codex rollout transcripts:
//   ~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl
//
// Codex's rollout format differs from Claude Code's JSONL, so this is a
// separate decoder — but it deliberately produces the SAME engine-facing
// events (CostEvent / .MessageEvent) so the watcher → engine path
// is identical for both agents.
//
// Rollout line shape:  { "timestamp": "<UTC ISO8601>", "type": "<T>", "payload": {…} }
//   type "session_meta"  → payload.cwd / payload.id  (project + session id)
//   type "response_item" → payload.type == "message" → role + content[] text
//   type "event_msg"     → payload.type == "token_count" → token usage
//
// Same incremental strategy as ClaudeJSONLParser: per-file byte cursor, only parse
// past the offset, never load a whole file (Codex rollouts can reach GBs and
// are world-readable — we always tail from the last offset).
//
// Token accounting caveat: Codex's `token_count` events may carry both a
// cumulative `total_token_usage` and a per-turn `last_token_usage`. We use the
// per-turn delta (`last_token_usage`) so summing across events is correct, the
// same way the Claude parser sums per-message usage. Verify against a real
// rollout file (and cross-check cost vs `ccusage`) before relying on the number.

import Foundation

actor CodexRolloutParser {
    static let shared = CodexRolloutParser()
    private init() {}

    /// Per-file resume cursors. Path → byte offset of next-byte-to-read.
    private var lastReadOffset: [URL: UInt64] = [:]

    /// Read every new line in `url` since the last call. `sessionId` is the
    /// session key derived from the rollout filename (Codex lines don't repeat
    /// it on every entry); `fallbackProject` is used until a `session_meta`
    /// line supplies the real cwd.
    func parseNew(at url: URL, sessionId: String, fallbackProject: String) -> ParseResult {
        let startOffset = lastReadOffset[url] ?? 0
        let empty = ParseResult()

        guard let handle = try? FileHandle(forReadingFrom: url) else { return empty }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: startOffset)
        } catch {
            lastReadOffset[url] = 0
            return empty
        }

        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        } catch {
            return empty
        }

        // File shrunk (rotated/replaced) — reset and retry next event.
        if data.isEmpty && startOffset > 0 {
            let onDiskSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
            if onDiskSize < startOffset {
                lastReadOffset[url] = 0
            }
            return empty
        }

        // Split on newline; defer any incomplete trailing line.
        let newline = UInt8(ascii: "\n")
        var lines: [Data] = []
        var lineStart = 0
        var lastCompleteLineEnd = 0
        for i in 0..<data.count {
            if data[i] == newline {
                lines.append(data.subdata(in: lineStart..<i))
                lineStart = i + 1
                lastCompleteLineEnd = i + 1
            }
        }
        lastReadOffset[url] = startOffset + UInt64(lastCompleteLineEnd)

        var result = ParseResult()
        var project = fallbackProject
        // The active model, learned from session_meta / turn_context lines and
        // applied to subsequent token_count events for correct pricing. Default
        // to the original Codex model if a file never names one.
        var model = "gpt-5-codex"
        for line in lines {
            Self.decode(line: line, sessionId: sessionId, project: &project, model: &model, into: &result)
        }
        return result
    }

    func resetCursor(for url: URL) {
        lastReadOffset[url] = 0
    }

    // MARK: - Line decoding

    /// Top-level rollout wrapper. `payload` is decoded lazily per `type`.
    private struct RolloutLine: Decodable {
        let timestamp: String?
        let type: String?
        let payload: Payload?

        struct Payload: Decodable {
            // session_meta
            let cwd: String?
            // model slug, when present (session_meta / turn_context)
            let model: String?
            // response_item (message) + event_msg both carry a nested "type"
            let type: String?
            let role: String?
            let content: [ContentBlock]?
            // event_msg token_count — token usage may sit directly on the
            // payload or under one of these nests; we probe several.
            let info: TokenInfo?
            let usage: TokenUsage?
            let last_token_usage: TokenUsage?
            let total_token_usage: TokenUsage?
            // direct fields (some event shapes inline the counts)
            let input_tokens: Int?
            let cached_input_tokens: Int?
            let output_tokens: Int?
            let reasoning_output_tokens: Int?
        }

        struct ContentBlock: Decodable {
            let type: String?
            let text: String?
        }

        struct TokenInfo: Decodable {
            let last_token_usage: TokenUsage?
            let total_token_usage: TokenUsage?
        }

        struct TokenUsage: Decodable {
            let input_tokens: Int?
            let cached_input_tokens: Int?
            let output_tokens: Int?
            let reasoning_output_tokens: Int?
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ s: String?) -> Date {
        guard let s else { return Date() }
        return isoFormatter.date(from: s) ?? isoFormatterNoFraction.date(from: s) ?? Date()
    }

    private static func decode(
        line: Data,
        sessionId: String,
        project: inout String,
        model: inout String,
        into result: inout ParseResult
    ) {
        guard !line.isEmpty,
              let parsed = try? JSONDecoder().decode(RolloutLine.self, from: line),
              let payload = parsed.payload
        else { return }

        let ts = parseDate(parsed.timestamp)

        // The model can appear on session_meta or turn_context; capture it
        // wherever it shows up so token_count events price against the real one.
        if let m = payload.model, !m.isEmpty { model = m }

        switch parsed.type {
        case "session_meta":
            if let cwd = payload.cwd, !cwd.isEmpty {
                project = URL(fileURLWithPath: cwd).lastPathComponent
            }

        case "response_item":
            // Only "message" items carry conversation text. function_call /
            // function_call_output (tool calls) are dropped — the drill-down
            // view is a reading surface, mirroring the Claude parser.
            guard payload.type == "message",
                  let roleRaw = payload.role,
                  let blocks = payload.content else { return }
            // Codex roles: "assistant", "user", "developer", "system". We only
            // surface user + assistant, like Claude.
            let role: MessageEvent.Role
            switch roleRaw {
            case "user":      role = .user
            case "assistant": role = .assistant
            default:          return
            }
            let text = blocks
                .compactMap { b -> String? in
                    switch b.type {
                    case "text", "input_text", "output_text": return b.text
                    default: return nil
                    }
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            result.messages.append(MessageEvent(
                sessionId: sessionId,
                project: project,
                role: role,
                text: text,
                timestamp: ts
            ))

        case "event_msg":
            // Two kinds of event_msg matter here. Turn-boundary signals drive
            // the session's running/idle status (Codex's hook stream can't —
            // see LifecycleEvent); token_count drives cost. Everything else
            // (agent_message, web_search_end, …) is ignored.
            switch payload.type {
            case "task_started":
                result.lifecycle.append(LifecycleEvent(
                    sessionId: sessionId, project: project, kind: .turnStarted, timestamp: ts))
                return
            case "task_complete":
                result.lifecycle.append(LifecycleEvent(
                    sessionId: sessionId, project: project, kind: .turnCompleted, timestamp: ts))
                return
            case "token_count":
                break   // fall through to token accounting below
            default:
                return
            }

            // Token usage. Prefer the per-turn delta so summing across events
            // is correct. Probe the locations Codex has used across versions.
            let delta = payload.last_token_usage
                ?? payload.info?.last_token_usage
                ?? payload.usage
                ?? (payload.input_tokens != nil
                    ? RolloutLine.TokenUsage(
                        input_tokens: payload.input_tokens,
                        cached_input_tokens: payload.cached_input_tokens,
                        output_tokens: payload.output_tokens,
                        reasoning_output_tokens: payload.reasoning_output_tokens)
                    : nil)
            guard let u = delta else { return }

            // Map Codex's breakdown onto our 5-lane Usage:
            //   input         → inputTokens
            //   cached_input  → cacheReadTokens (discounted lane)
            //   output + reasoning_output → outputTokens
            //   (no cache-WRITE concept on OpenAI → cacheCreate lanes stay 0)
            let usage = CostTracker.Usage(
                inputTokens:     u.input_tokens ?? 0,
                outputTokens:    (u.output_tokens ?? 0) + (u.reasoning_output_tokens ?? 0),
                cacheReadTokens: u.cached_input_tokens ?? 0
            )
            // Skip empty/zero usage events (Codex emits frequent token_count
            // pings; only the ones with real deltas matter).
            guard usage.inputTokens + usage.outputTokens + usage.cacheReadTokens > 0 else { return }
            result.costs.append(CostEvent(
                sessionId: sessionId,
                project: project,
                model: CostTracker.Model.from(model),
                usage: usage,
                timestamp: ts
            ))

        default:
            return
        }
    }
}
