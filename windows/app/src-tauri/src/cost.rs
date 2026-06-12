// Pricing math for Claude Code sessions — port of the Mac `CostTracker.swift`
// (notchcode-plan.md §0.7). Converts the per-message `usage` block from the
// JSONL into USD via a static price table keyed by model family.
//
// Prices mirror the Mac table (verified 2026-06-07 against Anthropic's models
// overview). Re-check whenever a new model family ships — wrong cost figures
// undermine the usage/brake value prop.

/// The token fields we extract from `assistant_message.usage`. All default to 0
/// since Claude Code has shipped slightly different shapes across versions.
#[derive(Clone, Copy, Default, Debug)]
pub struct Usage {
    pub input_tokens: u64,
    pub output_tokens: u64,
    /// Cache writes are billed at a premium over input: 1.25× (5m), 2× (1h).
    pub cache_create_5m_tokens: u64,
    pub cache_create_1h_tokens: u64,
    /// Cache reads are discounted to 0.1× input.
    pub cache_read_tokens: u64,
}

impl Usage {
    /// "Fresh compute" tokens — input + output + cache writes, excluding cache
    /// reads (bulk re-served, billed 10× less and not what the quota meter
    /// charges against). This is what the weekly token total counts.
    pub fn billable_tokens(&self) -> u64 {
        self.input_tokens
            + self.output_tokens
            + self.cache_create_5m_tokens
            + self.cache_create_1h_tokens
    }
}

/// Model families we know how to price. `Unknown` still accumulates tokens but
/// reports $0 — better to under-report than fabricate.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Model {
    Opus4,
    Sonnet4,
    Haiku4,
    // OpenAI / Codex models. Codex reports usage differently (input /
    // cached_input / output / reasoning_output); the Codex parser maps
    // cached_input onto the cache_read lane and folds reasoning into output, so
    // the same `cost()` math applies. Split by price tier (the Codex CLI
    // default has changed across releases: gpt-5-codex → gpt-5.x-codex → 5.5).
    Gpt5Codex,  // gpt-5-codex (original)
    Gpt5xCodex, // gpt-5.2/5.3/5.4-codex (specialized tier)
    Gpt55,      // gpt-5.5 (flagship tier)
    Gpt5,       // gpt-5 (base)
    Unknown,
}

impl Model {
    /// Map a wire model string into a bucket by family substring — tolerant to
    /// suffix drift. Claude families first; OpenAI/Codex slugs fall through.
    pub fn from_wire(raw: Option<&str>) -> Self {
        let Some(raw) = raw.map(str::to_ascii_lowercase) else {
            return Self::Unknown;
        };
        if raw.contains("opus") {
            Self::Opus4
        } else if raw.contains("sonnet") {
            Self::Sonnet4
        } else if raw.contains("haiku") {
            Self::Haiku4
        } else if raw.contains("5.5") {
            // gpt-5.5 is a distinct (higher) tier — check before generic codex.
            Self::Gpt55
        } else if raw.contains("codex") {
            if raw.contains("5.2") || raw.contains("5.3") || raw.contains("5.4") {
                Self::Gpt5xCodex
            } else {
                Self::Gpt5Codex
            }
        } else if raw.contains("gpt-5") || raw.contains("gpt5") {
            Self::Gpt5
        } else {
            Self::Unknown
        }
    }
}

/// Price per million tokens, USD. Cache write/read derived from the standard
/// 1.25× / 2× / 0.1× multipliers.
struct Pricing {
    input: f64,
    output: f64,
    cache_write_5m: f64,
    cache_write_1h: f64,
    cache_read: f64,
}

fn pricing(model: Model) -> Option<Pricing> {
    match model {
        Model::Opus4 => Some(Pricing {
            input: 5.00,
            output: 25.00,
            cache_write_5m: 6.25,
            cache_write_1h: 10.00,
            cache_read: 0.50,
        }),
        Model::Sonnet4 => Some(Pricing {
            input: 3.00,
            output: 15.00,
            cache_write_5m: 3.75,
            cache_write_1h: 6.00,
            cache_read: 0.30,
        }),
        Model::Haiku4 => Some(Pricing {
            input: 1.00,
            output: 5.00,
            cache_write_5m: 1.25,
            cache_write_1h: 2.00,
            cache_read: 0.10,
        }),
        // Verified 2026-06-11 against developers.openai.com/api/docs/pricing +
        // pricepertoken.com. OpenAI bills only input / cached-input / output (no
        // cache-WRITE tier), so cache_write lanes are 0 and cache_read carries
        // the cached-input rate (≈10% of input). Reasoning tokens bill at the
        // output rate (folded into output by the Codex parser).
        Model::Gpt5Codex | Model::Gpt5 => Some(Pricing {
            input: 1.25,
            output: 10.00,
            cache_write_5m: 0.0,
            cache_write_1h: 0.0,
            cache_read: 0.125,
        }),
        Model::Gpt5xCodex => Some(Pricing {
            input: 1.75,
            output: 14.00,
            cache_write_5m: 0.0,
            cache_write_1h: 0.0,
            cache_read: 0.175,
        }),
        Model::Gpt55 => Some(Pricing {
            input: 5.00,
            output: 30.00,
            cache_write_5m: 0.0,
            cache_write_1h: 0.0,
            cache_read: 0.50,
        }),
        Model::Unknown => None,
    }
}

/// Convert one assistant message's usage into USD. Returns 0 for unknown models.
pub fn cost(usage: &Usage, model: Model) -> f64 {
    let Some(p) = pricing(model) else {
        return 0.0;
    };
    let per = 1_000_000.0;
    (usage.input_tokens as f64 * p.input
        + usage.output_tokens as f64 * p.output
        + usage.cache_create_5m_tokens as f64 * p.cache_write_5m
        + usage.cache_create_1h_tokens as f64 * p.cache_write_1h
        + usage.cache_read_tokens as f64 * p.cache_read)
        / per
}
