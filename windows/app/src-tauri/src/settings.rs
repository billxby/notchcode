// User-facing preferences — the Windows port of the Mac `AppSettings`.
//
// Persisted as JSON in the app config dir (%APPDATA%\<identifier>\settings.json),
// alongside overlay.json. Held in Tauri-managed state as a `Mutex<AppSettings>`
// so commands can read/replace it; the frontend mirrors it in React state and
// pushes the whole struct back through `set_settings` on any change.
//
// The engine deliberately does NOT read these — it reports raw token/$ numbers
// and the frontend derives the budget fraction + brake against the live
// settings. Keeps the hot loop free of settings coupling (see watcher.rs).

use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager};

/// A plan tier for one of the agents. Claude and Codex draw from disjoint
/// subsets of these cases; `Api` is shared and means pay-per-token, so usage
/// reads as dollars-vs-daily-cap instead of tokens-vs-weekly-budget. The
/// frontend decides which subset to offer per agent (see `PLAN_LABELS` in
/// types.ts) — Rust just needs to deserialize any of them.
#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum PlanTier {
    // Claude (Anthropic) subscription tiers.
    Free,
    Pro,
    Max5,
    Max20,
    // Codex (OpenAI / ChatGPT) subscription tiers. `CodexPro` is distinct from
    // Claude's `Pro` (different default budget) but displays as "Pro".
    Plus,
    CodexPro,
    Business,
    Enterprise,
    // Shared pay-per-token tier.
    Api,
}

impl PlanTier {
    /// Suggested weekly token budget per tier — the DEFAULT for the
    /// user-editable `weekly_token_budget`, not a hard limit. Counts input +
    /// output + cache-creation only (not cache reads). Neither Anthropic nor
    /// OpenAI publish token numbers, so these are rough gauges to tune by taste.
    pub fn default_weekly_token_budget(self) -> u64 {
        match self {
            PlanTier::Free => 1_000_000,
            PlanTier::Pro => 10_000_000,
            PlanTier::Max5 => 50_000_000,
            PlanTier::Max20 => 200_000_000,
            PlanTier::Plus => 10_000_000,
            PlanTier::CodexPro => 50_000_000,
            PlanTier::Business => 100_000_000,
            PlanTier::Enterprise => 300_000_000,
            PlanTier::Api => 0, // unused — dollar cap instead
        }
    }
}

/// The motion the notch shows while Claude is working. All render in Claude
/// orange; only the motion differs.
#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum WorkingAnimation {
    Spinner,
    Pulse,
    Mascot,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct AppSettings {
    // Per-agent plan/budget. Claude and Codex bill on separate plans, so each
    // carries its own tier, weekly token budget, and daily $ cap; the badge
    // and brake meter each agent against its own limits. The Claude trio keeps
    // the original (un-prefixed) field names so configs written before per-agent
    // budgets existed migrate transparently. The Codex trio is `serde(default)`
    // for the same reason — older configs simply get the Codex presets.
    pub plan_tier: PlanTier,
    /// Weekly token budget the brake measures against (subscription tiers).
    pub weekly_token_budget: u64,
    /// API-tier daily dollar cap. Only consulted when `plan_tier == Api`.
    pub daily_cap_usd: f64,
    /// Codex plan tier.
    #[serde(default = "default_codex_plan_tier")]
    pub codex_plan_tier: PlanTier,
    /// Codex weekly token budget.
    #[serde(default = "default_codex_weekly_budget")]
    pub codex_weekly_token_budget: u64,
    /// Codex API-tier daily dollar cap.
    #[serde(default = "default_codex_daily_cap")]
    pub codex_daily_cap_usd: f64,
    /// Master switch: when false, no cost/token UI surfaces at all.
    pub usage_tracking_enabled: bool,
    /// Per-agent chip visibility — the combined notch chip shows a segment (and
    /// brakes) only for agents whose toggle is on, so a user can watch both,
    /// either, or neither. `serde(default)` (both on) for configs predating it.
    #[serde(default = "default_true")]
    pub show_usage_claude: bool,
    #[serde(default = "default_true")]
    pub show_usage_codex: bool,
    /// Fraction of budget (or daily $ cap for API) at which the brake fires.
    /// Shared by both agents.
    pub brake_threshold_percent: f64,
    pub working_animation: WorkingAnimation,
    /// Post a toast when a session blocks on the user (a permission/approval
    /// request, or Codex's request_user_input). Defaults on. `serde(default)`
    /// so configs written before this field existed still parse.
    #[serde(default = "default_true")]
    pub notify_on_waiting: bool,
    /// Also raise the agent's terminal window the moment it starts waiting.
    /// Defaults on; the user can disable to avoid focus being pulled.
    #[serde(default = "default_true")]
    pub focus_terminal_on_waiting: bool,
}

/// serde default for the waiting-alert toggles — both opt-out, not opt-in.
fn default_true() -> bool {
    true
}

/// serde defaults for the Codex plan trio (configs predating per-agent budgets).
fn default_codex_plan_tier() -> PlanTier {
    PlanTier::Plus
}
fn default_codex_weekly_budget() -> u64 {
    PlanTier::Plus.default_weekly_token_budget()
}
fn default_codex_daily_cap() -> f64 {
    25.0
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            plan_tier: PlanTier::Max5,
            weekly_token_budget: PlanTier::Max5.default_weekly_token_budget(),
            daily_cap_usd: 25.0,
            codex_plan_tier: default_codex_plan_tier(),
            codex_weekly_token_budget: default_codex_weekly_budget(),
            codex_daily_cap_usd: default_codex_daily_cap(),
            usage_tracking_enabled: true,
            show_usage_claude: true,
            show_usage_codex: true,
            brake_threshold_percent: 0.85,
            working_animation: WorkingAnimation::Mascot,
            notify_on_waiting: true,
            focus_terminal_on_waiting: true,
        }
    }
}

/// Tauri-managed handle: the live settings behind a mutex.
pub type SharedSettings = std::sync::Mutex<AppSettings>;

fn store_path(app: &AppHandle) -> Option<PathBuf> {
    let dir = app.path().app_config_dir().ok()?;
    Some(dir.join("settings.json"))
}

/// Load persisted settings, falling back to defaults on a missing/corrupt file.
pub fn load(app: &AppHandle) -> AppSettings {
    store_path(app)
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

/// Persist settings to disk (best-effort).
pub fn save(app: &AppHandle, settings: &AppSettings) {
    let Some(path) = store_path(app) else {
        return;
    };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(text) = serde_json::to_string_pretty(settings) {
        let _ = std::fs::write(path, text);
    }
}
