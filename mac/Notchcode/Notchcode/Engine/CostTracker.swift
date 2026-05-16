// Pricing math for Claude Code sessions.
//
// Anthropic exposes per-message token usage in the JSONL stream as a `usage`
// object on each assistant message. This file converts that object into USD
// using a static price table keyed by model name.
//
// Decoupled into its own file because:
//   - the price table changes more often than anything else here; one file to
//     edit when Anthropic updates pricing
//   - pure value types — easy to unit-test without standing up the engine
//   - keeps SessionStateEngine focused on lifecycle, not arithmetic
//
// IMPORTANT: prices below are estimates and MUST be verified against
// https://www.anthropic.com/pricing before the v1.0 launch. Inaccurate cost
// figures undermine the whole "brake pedal" value prop.

import Foundation

// `nonisolated` because the project defaults to @MainActor; this is pure math
// and needs to be callable from JSONLParser (its own actor) without hopping.
nonisolated enum CostTracker {

    // MARK: - Usage payload

    /// The fields we extract from `assistant_message.usage` in the JSONL.
    /// All optional because Claude Code has shipped slightly different shapes
    /// across versions; missing fields default to 0 in pricing math.
    struct Usage: Equatable {
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        /// Tokens written to the prompt cache. Anthropic charges a premium
        /// over normal input: 1.25× for 5-minute TTL, 2× for 1-hour TTL.
        var cacheCreate5mTokens: Int = 0
        var cacheCreate1hTokens: Int = 0
        /// Tokens read from a previously-warm cache. Discounted to 0.1× input.
        var cacheReadTokens: Int = 0
    }

    // MARK: - Models

    /// Models we know how to price. `unknown` is the fallback bucket — we
    /// still accumulate token counts under "unknown" so the user sees the
    /// session, but cost is reported as $0 until we add the model to the
    /// table. Better than silently misreporting.
    enum Model: String, CaseIterable {
        case opus4
        case sonnet4
        case haiku4
        case unknown

        /// Map a wire-format model string (e.g. "claude-opus-4-7",
        /// "claude-sonnet-4-6", "claude-haiku-4-5-20251001") into our bucket.
        /// Matches by substring on the family name; tolerant to suffix drift.
        static func from(_ raw: String?) -> Model {
            guard let raw = raw?.lowercased() else { return .unknown }
            if raw.contains("opus")   { return .opus4 }
            if raw.contains("sonnet") { return .sonnet4 }
            if raw.contains("haiku")  { return .haiku4 }
            return .unknown
        }
    }

    /// Price per million tokens, in USD. All five lanes are required for
    /// accurate Claude pricing — cache reads and writes are billed
    /// differently from baseline input.
    struct Pricing: Equatable {
        let input: Double
        let output: Double
        let cacheWrite5m: Double
        let cacheWrite1h: Double
        let cacheRead: Double
    }

    /// VERIFY BEFORE v1.0. Numbers below reflect the 4-family tiers; cache
    /// write/read are derived from the standard 1.25× / 2× / 0.1× multipliers.
    static let pricingTable: [Model: Pricing] = [
        .opus4: Pricing(
            input:        15.00,
            output:       75.00,
            cacheWrite5m: 18.75,
            cacheWrite1h: 30.00,
            cacheRead:     1.50
        ),
        .sonnet4: Pricing(
            input:         3.00,
            output:       15.00,
            cacheWrite5m:  3.75,
            cacheWrite1h:  6.00,
            cacheRead:     0.30
        ),
        .haiku4: Pricing(
            input:         1.00,
            output:        5.00,
            cacheWrite5m:  1.25,
            cacheWrite1h:  2.00,
            cacheRead:     0.10
        ),
    ]

    // MARK: - Math

    /// Convert a single assistant message's usage into USD. Returns 0 for
    /// unknown models — we'd rather under-report than fabricate.
    static func cost(for usage: Usage, model: Model) -> Double {
        guard let p = pricingTable[model] else { return 0 }
        let perToken = 1_000_000.0
        return (Double(usage.inputTokens)         * p.input        / perToken)
             + (Double(usage.outputTokens)        * p.output       / perToken)
             + (Double(usage.cacheCreate5mTokens) * p.cacheWrite5m / perToken)
             + (Double(usage.cacheCreate1hTokens) * p.cacheWrite1h / perToken)
             + (Double(usage.cacheReadTokens)     * p.cacheRead    / perToken)
    }
}
