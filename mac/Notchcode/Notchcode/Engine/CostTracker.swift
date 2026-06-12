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
// Prices verified against platform.claude.com/docs/en/about-claude/models
// on 2026-06-07. Re-check whenever Anthropic ships a new model family —
// inaccurate cost figures undermine the whole "brake pedal" value prop.

import Foundation

// `nonisolated` because the project defaults to @MainActor; this is pure math
// and needs to be callable from ClaudeJSONLParser (its own actor) without hopping.
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
        // OpenAI / Codex models. Codex reports usage with a different token
        // breakdown (input / cached_input / output / reasoning_output); we map
        // cached_input onto the cacheRead lane and fold reasoning into output,
        // so the same `cost(for:model:)` math applies. See Agent/Codex parser.
        // The buckets are split by price tier (the Codex CLI default model has
        // changed over releases — gpt-5-codex → gpt-5.x-codex → gpt-5.5).
        case gpt5Codex      // gpt-5-codex (original)
        case gpt5xCodex     // gpt-5.2/5.3/5.4-codex (specialized tier)
        case gpt55          // gpt-5.5 (flagship tier, incl. gpt-5.5 in Codex)
        case gpt5           // gpt-5 (base)
        case unknown

        /// Map a wire-format model string into our bucket. Matches by substring
        /// on the family name; tolerant to suffix drift. Claude families are
        /// checked first; OpenAI/Codex slugs fall through to the OpenAI buckets.
        static func from(_ raw: String?) -> Model {
            guard let raw = raw?.lowercased() else { return .unknown }
            if raw.contains("opus")   { return .opus4 }
            if raw.contains("sonnet") { return .sonnet4 }
            if raw.contains("haiku")  { return .haiku4 }
            // gpt-5.5 is a distinct (higher) price tier — check it before the
            // generic codex/gpt-5 buckets so "gpt-5.5-codex" isn't underpriced.
            if raw.contains("5.5")    { return .gpt55 }
            if raw.contains("codex") {
                if raw.contains("5.2") || raw.contains("5.3") || raw.contains("5.4") {
                    return .gpt5xCodex
                }
                return .gpt5Codex
            }
            if raw.contains("gpt-5") || raw.contains("gpt5") { return .gpt5 }
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

    /// Verified 2026-06-07 against Anthropic's models overview. Cache
    /// write/read are derived from the standard 1.25× / 2× / 0.1× multipliers.
    /// Known approximation: Opus 4.1 and earlier were $15/$75, but they're
    /// deprecated and effectively absent from Claude Code traffic, so all
    /// "opus" matches use the Opus 4.5+ rates.
    static let pricingTable: [Model: Pricing] = [
        .opus4: Pricing(
            input:         5.00,
            output:       25.00,
            cacheWrite5m:  6.25,
            cacheWrite1h: 10.00,
            cacheRead:     0.50
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
        // Verified 2026-06-11 against OpenAI's pricing page
        // (developers.openai.com/api/docs/pricing) + pricepertoken.com. OpenAI
        // bills only input / cached-input / output (no separate cache-WRITE
        // tier), so cacheWrite lanes are 0 and `cacheRead` carries the
        // cached-input rate (≈10% of input). Reasoning tokens bill at the
        // output rate and are folded into outputTokens by the Codex parser.
        .gpt5Codex: Pricing(      // gpt-5-codex
            input:         1.25,
            output:       10.00,
            cacheWrite5m:  0.00,
            cacheWrite1h:  0.00,
            cacheRead:     0.125
        ),
        .gpt5xCodex: Pricing(     // gpt-5.2 / 5.3 / 5.4-codex
            input:         1.75,
            output:       14.00,
            cacheWrite5m:  0.00,
            cacheWrite1h:  0.00,
            cacheRead:     0.175
        ),
        .gpt55: Pricing(          // gpt-5.5 (flagship)
            input:         5.00,
            output:       30.00,
            cacheWrite5m:  0.00,
            cacheWrite1h:  0.00,
            cacheRead:     0.50
        ),
        .gpt5: Pricing(           // gpt-5 (base)
            input:         1.25,
            output:       10.00,
            cacheWrite5m:  0.00,
            cacheWrite1h:  0.00,
            cacheRead:     0.125
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
