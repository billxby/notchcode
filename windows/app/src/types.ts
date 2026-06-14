// Shared types mirroring the Rust `sessions` structs and small display helpers.

export type Status = "idle" | "working" | "waiting" | "done";
export type Role = "user" | "assistant";

/** Which coding agent a session belongs to (mirrors the Rust `Agent`). */
export type Agent = "claude" | "codex";

export const AGENT_LABELS: Record<Agent, string> = {
  claude: "Claude",
  codex: "Codex",
};

/** Compact two-letter label for tight UI (session-row badge, chat role tag). */
export const AGENT_SHORT: Record<Agent, string> = {
  claude: "CC",
  codex: "CD",
};

/** Per-agent accent. Claude keeps its orange; Codex gets OpenAI's teal-green. */
export const AGENT_ACCENT: Record<Agent, string> = {
  claude: "#ff9d3d",
  codex: "#10a37f",
};

export type SessionInfo = {
  id: string;
  agent: Agent;
  project: string;
  status: Status;
  detail: string | null;
  cost_usd: number;
  runtime_secs: number;
  ended: boolean;
  has_terminal: boolean;
};

export type ActionInfo = {
  tool: string;
  detail: string | null;
};

export type MessageInfo = {
  role: Role;
  text: string;
};

export type SessionDetail = SessionInfo & {
  recent_actions: ActionInfo[];
  messages: MessageInfo[];
};

/** Per-agent usage figures (mirrors the Rust `AgentUsage`). */
export type AgentUsage = {
  weekly_tokens: number;
  weekly_dollars: number;
  today_tokens: number;
  dollars_today: number;
};

const EMPTY_USAGE: AgentUsage = {
  weekly_tokens: 0,
  weekly_dollars: 0,
  today_tokens: 0,
  dollars_today: 0,
};

export type NotchState = {
  status: Status;
  /** Agent driving a working aggregate, so the collapsed pill tints by agent. */
  agent: Agent | null;
  detail: string | null;
  sessions: SessionInfo[];
  /** Usage keyed by agent — each badge/brake reads its own entry. */
  usage: Record<Agent, AgentUsage>;
};

/** Usage for one agent, tolerating an absent entry (older backend payloads). */
export function agentUsage(state: NotchState, agent: Agent): AgentUsage {
  return state.usage?.[agent] ?? EMPTY_USAGE;
}

/** Agents with something to show (tokens this week or $ today). */
export function agentsWithUsage(state: NotchState): Agent[] {
  return (["claude", "codex"] as Agent[]).filter((a) => {
    const u = agentUsage(state, a);
    return u.weekly_tokens > 0 || u.dollars_today > 0;
  });
}

// ---- Settings (mirrors the Rust `settings::AppSettings`) --------------------

// Claude tiers + Codex tiers + the shared `api`. `codexpro` is distinct from
// Claude's `pro` (different default budget) but labels as "Pro".
export type PlanTier =
  | "free"
  | "pro"
  | "max5"
  | "max20"
  | "plus"
  | "codexpro"
  | "business"
  | "enterprise"
  | "api";
export type WorkingAnimation = "spinner" | "pulse" | "mascot";

export type AppSettings = {
  // Per-agent plan/budget. The Claude trio keeps the original un-prefixed field
  // names (migration); the Codex trio mirrors them.
  plan_tier: PlanTier;
  weekly_token_budget: number;
  daily_cap_usd: number;
  codex_plan_tier: PlanTier;
  codex_weekly_token_budget: number;
  codex_daily_cap_usd: number;
  usage_tracking_enabled: boolean;
  /** Per-agent chip visibility — show both, either, or neither. */
  show_usage_claude: boolean;
  show_usage_codex: boolean;
  /** Shared by both agents. */
  brake_threshold_percent: number;
  working_animation: WorkingAnimation;
  /** Toast when a session blocks on the user (permission / request_user_input). */
  notify_on_waiting: boolean;
  /** Auto-raise the agent's terminal the moment it starts waiting. */
  focus_terminal_on_waiting: boolean;
};

export const PLAN_LABELS: Record<PlanTier, string> = {
  free: "Free",
  pro: "Pro",
  max5: "Max (5×)",
  max20: "Max (20×)",
  plus: "Plus",
  codexpro: "Pro",
  business: "Business",
  enterprise: "Enterprise",
  api: "API key (pay-per-token)",
};

/** Tiers offered per agent's "Your plan" picker. */
export const PLAN_TIERS_FOR: Record<Agent, PlanTier[]> = {
  claude: ["free", "pro", "max5", "max20", "api"],
  codex: ["plus", "codexpro", "business", "enterprise", "api"],
};

/** Suggested weekly token budget per tier — mirrors PlanTier in settings.rs. */
export const PLAN_DEFAULT_BUDGET: Record<PlanTier, number> = {
  free: 1_000_000,
  pro: 10_000_000,
  max5: 50_000_000,
  max20: 200_000_000,
  plus: 10_000_000,
  codexpro: 50_000_000,
  business: 100_000_000,
  enterprise: 300_000_000,
  api: 0,
};

export const WORKING_ANIM_LABELS: Record<WorkingAnimation, string> = {
  spinner: "Spinner (CLI flower)",
  pulse: "Pulse (logo breathing)",
  mascot: "Mascot (walking)",
};

/** API users meter dollars vs a daily cap; everyone else tokens vs a budget. */
export function usesDollarBudget(tier: PlanTier): boolean {
  return tier === "api";
}

// ---- Per-agent settings accessors -------------------------------------------

export function planTierFor(settings: AppSettings, agent: Agent): PlanTier {
  return agent === "claude" ? settings.plan_tier : settings.codex_plan_tier;
}

export function weeklyBudgetFor(settings: AppSettings, agent: Agent): number {
  return agent === "claude"
    ? settings.weekly_token_budget
    : settings.codex_weekly_token_budget;
}

export function dailyCapFor(settings: AppSettings, agent: Agent): number {
  return agent === "claude" ? settings.daily_cap_usd : settings.codex_daily_cap_usd;
}

/** Whether this agent's segment should appear in the notch chip / brake. */
export function showUsageFor(settings: AppSettings, agent: Agent): boolean {
  return agent === "claude" ? settings.show_usage_claude : settings.show_usage_codex;
}

/**
 * 0…1 fraction of `agent`'s budget consumed. API: $ today vs the daily cap.
 * Subscription: weekly tokens vs the weekly budget. >1 is possible (over budget).
 */
export function usageFraction(
  state: NotchState,
  settings: AppSettings,
  agent: Agent
): number {
  const u = agentUsage(state, agent);
  if (usesDollarBudget(planTierFor(settings, agent))) {
    const cap = dailyCapFor(settings, agent);
    return cap > 0 ? u.dollars_today / cap : 0;
  }
  const budget = weeklyBudgetFor(settings, agent);
  return budget > 0 ? u.weekly_tokens / budget : 0;
}

/** 950 → "950", 8_234_000 → "8.2M", 1_050_000_000 → "1.1B". Drops ".0". */
export function compactTokens(n: number): string {
  const fmt = (v: number, suffix: string) => {
    const s = v.toFixed(1);
    return (s.endsWith(".0") ? s.slice(0, -2) : s) + suffix;
  };
  if (n >= 1_000_000_000) return fmt(n / 1_000_000_000, "B");
  if (n >= 1_000_000) return fmt(n / 1_000_000, "M");
  if (n >= 1_000) return fmt(n / 1_000, "K");
  return `${n}`;
}

/** 12345 → "12.3k", 1500000 → "1.5M". */
export function formatTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`;
  return `${n}`;
}

/** USD with sensible precision: $0.0042, $0.42, $12.30. */
export function formatCost(usd: number): string {
  if (usd === 0) return "$0";
  if (usd < 0.01) return `$${usd.toFixed(4)}`;
  if (usd < 1) return `$${usd.toFixed(3)}`;
  return `$${usd.toFixed(2)}`;
}

/** Seconds → "45s", "12m", "1h 03m". */
export function formatRuntime(secs: number): string {
  if (secs < 60) return `${secs}s`;
  const m = Math.floor(secs / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  const rem = m % 60;
  return `${h}h ${rem.toString().padStart(2, "0")}m`;
}
