// Incremental parser for ~/.claude/projects/<slug>/<session-id>.jsonl.
//
// Each line in the JSONL is one event (user message, assistant message, tool
// result, etc.). We only care about `type == "assistant"` lines, which carry
// `message.usage` and `message.model` — those are the source of truth for
// cost tracking.
//
// Why incremental:
//   - JSONL files grow append-only during a session. Re-parsing the whole
//     file on every FSEvent would scale O(history) instead of O(new).
//   - We track per-URL byte offsets in `lastReadOffset`; only bytes past the
//     offset are read and parsed.
//   - The last byte we successfully cleared (i.e., ended with `\n`) is the
//     new offset. Partial trailing lines are left for the next read.
//
// Threading: every public entry point hops off the main actor. Parsing a
// 1 MB JSONL on the main thread would stutter the notch animation.

import Foundation

actor JSONLParser {
    static let shared = JSONLParser()
    private init() {}

    /// Per-file resume cursors. Path → byte offset of next-byte-to-read.
    /// Untracked files start at 0 (full parse on first encounter, which is
    /// fine because Claude Code rotates session files frequently).
    private var lastReadOffset: [URL: UInt64] = [:]

    /// A single cost-bearing event extracted from a JSONL line.
    struct CostEvent: Equatable {
        let sessionId: String
        let project: String
        let model: CostTracker.Model
        let usage: CostTracker.Usage
        let timestamp: Date
    }

    /// A single user or assistant message extracted from a JSONL line.
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

    /// Both event streams produced by a single pass over the new bytes.
    struct ParseResult {
        var costs: [CostEvent] = []
        var messages: [MessageEvent] = []
    }

    /// Read every new line in `url` since the last call. Returns the events
    /// found AND the updated offset is committed internally — callers don't
    /// need to track it themselves. Project label comes from the parent
    /// directory slug; the caller can override for a friendlier name.
    func parseNew(at url: URL, project: String) -> ParseResult {
        let startOffset = lastReadOffset[url] ?? 0
        let empty = ParseResult()

        guard let handle = try? FileHandle(forReadingFrom: url) else { return empty }
        defer { try? handle.close() }

        // Seek to where we left off. If the file was truncated/rotated,
        // seek will silently clamp; we detect that by reading 0 bytes and
        // resetting the offset.
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

        // Edge case: file shrunk (rotated, truncated, or replaced by a
        // shorter file). Reset and skip this round — next FSEvent retries.
        if data.isEmpty && startOffset > 0 {
            let onDiskSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
            if onDiskSize < startOffset {
                lastReadOffset[url] = 0
            }
            return empty
        }

        // Split on newline. Anything after the final newline is an
        // incomplete tail; defer it to the next read by NOT advancing past it.
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
        // Commit offset only as far as the last full line.
        lastReadOffset[url] = startOffset + UInt64(lastCompleteLineEnd)

        var result = ParseResult()
        result.costs.reserveCapacity(lines.count)
        for line in lines {
            Self.decode(line: line, fallbackProject: project, into: &result)
        }
        return result
    }

    /// Reset cursor for a file — used when ProjectsWatcher sees the file
    /// disappear/rotate, or on app launch if we want a full rescan.
    func resetCursor(for url: URL) {
        lastReadOffset[url] = 0
    }

    // MARK: - Line decoding

    private struct Line: Decodable {
        let type: String?
        let sessionId: String?
        let timestamp: String?
        let cwd: String?
        let message: Message?

        struct Message: Decodable {
            let model: String?
            let usage: UsageWire?
            let content: Content?
        }
        struct UsageWire: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
            let cache_read_input_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_creation: CacheCreation?

            struct CacheCreation: Decodable {
                let ephemeral_5m_input_tokens: Int?
                let ephemeral_1h_input_tokens: Int?
            }
        }

        /// `message.content` ships as either a raw string (older user
        /// messages, simple prompts) or an array of typed blocks (text /
        /// tool_use / tool_result / image). Decode both shapes; expose only
        /// the concatenated text — tool calls and binary blocks are dropped
        /// because the drill-down view is a reading surface.
        enum Content: Decodable {
            case string(String)
            case blocks([Block])

            struct Block: Decodable {
                let type: String?
                let text: String?
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) {
                    self = .string(s)
                } else if let blocks = try? c.decode([Block].self) {
                    self = .blocks(blocks)
                } else {
                    self = .blocks([])
                }
            }

            var text: String {
                switch self {
                case .string(let s):
                    return s
                case .blocks(let blocks):
                    return blocks
                        .compactMap { $0.type == "text" ? $0.text : nil }
                        .joined(separator: "\n")
                }
            }
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Decode one JSONL line and append any extracted events into `result`.
    /// One line may produce a cost event (assistant + usage), a message event
    /// (assistant or user with text content), both, or neither.
    private static func decode(line: Data, fallbackProject: String, into result: inout ParseResult) {
        guard !line.isEmpty,
              let parsed = try? JSONDecoder().decode(Line.self, from: line),
              let sessionId = parsed.sessionId
        else { return }

        let ts = parsed.timestamp.flatMap { isoFormatter.date(from: $0) } ?? Date()
        let project = projectFromCwd(parsed.cwd) ?? fallbackProject

        // Cost — assistant messages carry a `usage` block.
        if parsed.type == "assistant",
           let msg = parsed.message,
           let wire = msg.usage {
            let cache5m = wire.cache_creation?.ephemeral_5m_input_tokens
            let cache1h = wire.cache_creation?.ephemeral_1h_input_tokens
            let cacheCreate5m = cache5m ?? wire.cache_creation_input_tokens ?? 0
            let cacheCreate1h = cache1h ?? 0

            let usage = CostTracker.Usage(
                inputTokens:         wire.input_tokens ?? 0,
                outputTokens:        wire.output_tokens ?? 0,
                cacheCreate5mTokens: cacheCreate5m,
                cacheCreate1hTokens: cacheCreate1h,
                cacheReadTokens:     wire.cache_read_input_tokens ?? 0
            )

            result.costs.append(CostEvent(
                sessionId: sessionId,
                project: project,
                model: CostTracker.Model.from(msg.model),
                usage: usage,
                timestamp: ts
            ))
        }

        // Message text — both user and assistant lines, when they carry
        // non-empty text. Trimmed because Claude Code occasionally emits
        // whitespace-only filler turns.
        if let role = MessageEvent.Role(rawValue: parsed.type ?? ""),
           let content = parsed.message?.content {
            let trimmed = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let sanitized = sanitizeUserContent(trimmed), !sanitized.isEmpty {
                result.messages.append(MessageEvent(
                    sessionId: sessionId,
                    project: project,
                    role: role,
                    text: sanitized,
                    timestamp: ts
                ))
            }
        }
    }

    /// Claude Code wraps slash-command invocations and their local stdout in
    /// XML-ish tags inside user JSONL turns. Surface them as readable text:
    /// `<command-name>/exit</command-name>...` → `/exit`, stdout blocks become
    /// the bare stdout, and the `<local-command-caveat>` block — which is a
    /// system instruction telling the model to ignore the wrapped messages —
    /// is dropped entirely so it doesn't leak into the user-facing transcript.
    /// Returns nil if the line should be hidden.
    private static func sanitizeUserContent(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }

        if text.hasPrefix("<local-command-caveat>") {
            return nil
        }

        if let name = extractTag("command-name", from: text) {
            let args = extractTag("command-args", from: text)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return args.isEmpty ? name : "\(name) \(args)"
        }

        if let stdout = extractTag("local-command-stdout", from: text) {
            let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return text
    }

    private static func extractTag(_ tag: String, from text: String) -> String? {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard let openRange = text.range(of: open),
              let closeRange = text.range(of: close, range: openRange.upperBound..<text.endIndex)
        else { return nil }
        return String(text[openRange.upperBound..<closeRange.lowerBound])
    }

    private static func projectFromCwd(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}
