// Shared types mirroring the Rust `sessions` structs and small display helpers.

export type Status = "idle" | "working" | "waiting" | "done";
export type Role = "user" | "assistant";

export type SessionInfo = {
  id: string;
  project: string;
  status: Status;
  detail: string | null;
  cost_usd: number;
  runtime_secs: number;
  ended: boolean;
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

export type NotchState = {
  status: Status;
  detail: string | null;
  sessions: SessionInfo[];
  weekly_tokens: number;
  weekly_dollars: number;
};

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
