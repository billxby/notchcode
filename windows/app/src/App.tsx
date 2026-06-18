import { useEffect, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import {
  availableMonitors,
  currentMonitor,
  getCurrentWindow,
  LogicalPosition,
} from "@tauri-apps/api/window";
import NotchShape from "./NotchShape";
import BlobShape from "./BlobShape";
import SettingsView from "./Settings";
import MarkdownText from "./MarkdownText";
import { StatusIndicator, StatusDot } from "./Indicators";
import {
  IconGear,
  IconChevronLeft,
  IconX,
  IconJump,
  IconStop,
  IconBolt,
  IconRing,
} from "./Icons";
import {
  compactTokens,
  formatCost,
  formatRuntime,
  usageFraction,
  usesDollarBudget,
  planTierFor,
  weeklyBudgetFor,
  showUsageFor,
  agentUsage,
  agentsWithUsage,
  AGENT_ACCENT,
  AGENT_SHORT,
  AGENT_LABELS,
  type Agent,
  type AppSettings,
  type NotchState,
  type SessionDetail,
} from "./types";
import { tween, reduceMotion } from "./motion";
import "./App.css";

// The painted pill has two widths: a minimal resting form so it's barely there
// when nothing is happening, expanding to the full pill while a session is live.
// The OS window stays a constant size (PILL_WINDOW_*, transparent shadow room) —
// only the SVG silhouette tweens, so there's no janky per-state window resize.
const NOTCH_WIDTH = 200; // active (working / waiting / done / brake)
const NOTCH_WIDTH_IDLE = 112; // resting, nothing live
const NOTCH_HEIGHT = 32;

// Collapsed window size (logical px), kept in sync with overlay.rs PILL_SIZE.
// Larger than the visible pill on purpose — the extra is transparent shadow room.
const PILL_WINDOW_WIDTH = 272;
const PILL_WINDOW_HEIGHT = 64;
// Distance from the top edge (logical px) within which a release snaps to a notch.
const SNAP_Y = 24;
// Pointer travel before a press counts as a drag rather than a click.
const DRAG_THRESHOLD = 4;
// User-resizable sheet width (logical px), dragged at the sheet's right edge
// and persisted across runs.
const SHEET_MIN_WIDTH = 300;
const SHEET_MAX_WIDTH = 560;
const SHEET_DEFAULT_WIDTH = 340;

type View = "pill" | "panel" | "settings" | "detail";

const DEFAULT_SETTINGS: AppSettings = {
  plan_tier: "max5",
  weekly_token_budget: 50_000_000,
  daily_cap_usd: 25,
  codex_plan_tier: "plus",
  codex_weekly_token_budget: 10_000_000,
  codex_daily_cap_usd: 25,
  usage_tracking_enabled: true,
  show_usage_claude: true,
  show_usage_codex: true,
  brake_threshold_percent: 0.85,
  working_animation: "mascot",
  notify_on_waiting: true,
  focus_terminal_on_waiting: true,
};

/** One monitor in logical px (window scale); `name` is the OS monitor id. */
type MonitorRect = {
  name: string | null;
  left: number;
  top: number;
  width: number;
  height: number;
};

type DragState = {
  target: Element;
  pointerId: number;
  startSX: number;
  startSY: number;
  startWX: number;
  startWY: number;
  /** The monitor the drag started on (logical px) — snap fallback. */
  monLeft: number;
  monWidth: number;
  monTop: number;
  monHeight: number;
  /** Every connected monitor in logical px (window scale), so the drag can
      travel onto any of them and a release can dock to the one it lands on. */
  monitors: MonitorRect[];
  /** Union rect of all monitors (logical px) — the drag travel bounds. */
  uLeft: number;
  uTop: number;
  uRight: number;
  uBottom: number;
  /** Current window size (logical px) for clamping/snapping — the pill and
      the expanded sheet windows differ, so it's read live at drag start. */
  winW: number;
  winH: number;
  moved: boolean;
  ready: boolean;
  /** Eased-follow state (logical px). `cur` is where the window actually is,
      `target` is where the cursor wants it; each frame `cur` eases toward
      `target`, and the per-frame delta becomes `vel` for release momentum. */
  curX: number;
  curY: number;
  targetX: number;
  targetY: number;
  velX: number;
  velY: number;
  /** Active rAF handle for the follow loop (0 = not running). */
  raf: number;
};

function clamp(v: number, lo: number, hi: number): number {
  return Math.min(Math.max(v, lo), hi);
}

// ---- Usage badge ------------------------------------------------------------

function UsageBadge({
  state,
  settings,
  agents,
  brakedAgents,
  onClick,
}: {
  state: NotchState;
  settings: AppSettings;
  agents: Agent[];
  brakedAgents: Agent[];
  onClick: () => void;
}) {
  // One chip, a segment per visible agent ("CC 8.2M · CD 4M"). Each segment is
  // colored by its own level; the chip background follows the hottest one.
  const segments = agents.map((agent) => {
    const fraction = usageFraction(state, settings, agent);
    const u = agentUsage(state, agent);
    const dollar = usesDollarBudget(planTierFor(settings, agent));
    const amount = dollar
      ? u.dollars_today < 10
        ? `$${u.dollars_today.toFixed(2)}`
        : `$${u.dollars_today.toFixed(0)}`
      : compactTokens(u.weekly_tokens);
    const level = brakedAgents.includes(agent) ? 2 : fraction >= 0.6 ? 1 : 0;
    return { agent, text: `${AGENT_SHORT[agent]} ${amount}`, level };
  });
  const maxLevel = Math.max(0, ...segments.map((s) => s.level));
  const chipLevel = maxLevel === 2 ? "braked" : maxLevel === 1 ? "warn" : "";
  return (
    <button
      className={`usage-badge ${chipLevel}`}
      onClick={(e) => {
        e.stopPropagation();
        onClick();
      }}
    >
      {segments.flatMap((s, i) => {
        const seg = (
          <span key={s.agent} className={`usage-seg lvl-${s.level}`}>
            {s.text}
          </span>
        );
        return i === 0
          ? [seg]
          : [
              <span key={`sep-${s.agent}`} className="usage-sep">
                ·
              </span>,
              seg,
            ];
      })}
    </button>
  );
}

// ---- Brake banner -----------------------------------------------------------

function BrakeBanner({
  state,
  settings,
  agent,
  onDismiss,
}: {
  state: NotchState;
  settings: AppSettings;
  agent: Agent;
  onDismiss: () => void;
}) {
  const dollar = usesDollarBudget(planTierFor(settings, agent));
  const pct = Math.round(usageFraction(state, settings, agent) * 100);
  const u = agentUsage(state, agent);
  const who = AGENT_LABELS[agent];
  const title = dollar
    ? `${who}: approaching daily API budget`
    : `${who}: approaching weekly budget`;
  const sub = dollar
    ? `≈$${u.dollars_today.toFixed(2)} today · ${pct}%`
    : `${compactTokens(u.weekly_tokens)} of ${compactTokens(
        weeklyBudgetFor(settings, agent)
      )} · ${pct}%`;
  return (
    <div className="brake-banner">
      <span className="brake-dot" />
      <span className="brake-title">{title}</span>
      <span className="spacer" />
      <span className="brake-sub">{sub}</span>
      <button className="pill-btn" onClick={onDismiss}>
        Dismiss
      </button>
    </div>
  );
}

// ---- Panel: session list ----------------------------------------------------

function RowButton({
  icon,
  variant,
  title,
  onClick,
}: {
  icon: React.ReactNode;
  variant?: string;
  title?: string;
  onClick: () => void;
}) {
  return (
    <button
      className={`row-btn ${variant ?? ""}`}
      title={title}
      onClick={(e) => {
        e.stopPropagation();
        onClick();
      }}
    >
      {icon}
    </button>
  );
}

function PanelView({
  state,
  settings,
  braked,
  brakedAgents,
  hooksInstalled,
  onSelect,
  onCollapse,
  onSettings,
  onDismissBrake,
}: {
  state: NotchState;
  settings: AppSettings;
  braked: boolean;
  brakedAgents: Agent[];
  hooksInstalled: boolean;
  onSelect: (id: string) => void;
  onCollapse: () => void;
  onSettings: () => void;
  onDismissBrake: () => void;
}) {
  const n = state.sessions.length;
  const headerLabel = n === 0 ? "Notchcode" : n === 1 ? "1 session" : `${n} sessions`;
  const usageAgents = settings.usage_tracking_enabled
    ? agentsWithUsage(state).filter((a) => showUsageFor(settings, a))
    : [];

  return (
    <div className="sheet-inner">
      <div className="sheet-header" onClick={onCollapse}>
        <StatusIndicator
          status={state.status}
          anim={settings.working_animation}
          agent={state.agent ?? undefined}
          forceColor={braked ? "#ff9d3d" : undefined}
        />
        <span className="header-title">{headerLabel}</span>
        <span className="spacer" />
        {/* One combined chip: a segment per visible agent ("CC X · CD X"). */}
        {usageAgents.length > 0 && (
          <UsageBadge
            state={state}
            settings={settings}
            agents={usageAgents}
            brakedAgents={brakedAgents}
            onClick={onSettings}
          />
        )}
        <button
          className="gear-btn"
          onClick={(e) => {
            e.stopPropagation();
            onSettings();
          }}
          title="Settings"
        >
          <IconGear />
        </button>
      </div>
      <div className="sheet-divider" />

      <div className="sheet-body">
        {/* One banner per agent over its threshold. */}
        {settings.usage_tracking_enabled &&
          brakedAgents.map((agent) => (
            <BrakeBanner
              key={agent}
              state={state}
              settings={settings}
              agent={agent}
              onDismiss={onDismissBrake}
            />
          ))}

        {state.sessions.length === 0 ? (
          hooksInstalled ? (
            <div className="empty-state">
              <div className="empty-glyph">
                <IconRing size={30} />
              </div>
              <div className="empty-text">No active sessions</div>
            </div>
          ) : (
            <div className="empty-state install">
              <div className="empty-glyph warn">
                <IconBolt size={28} />
              </div>
              <div className="empty-title">Hooks not installed</div>
              <div className="empty-text">
                Open Settings to wire Notchcode into Claude Code.
              </div>
              <button className="btn accent" onClick={onSettings}>
                Open Settings
              </button>
            </div>
          )
        ) : (
          <ul className="session-list">
            {state.sessions.map((s) => (
              <li
                key={s.id}
                className={`session-row ${s.ended ? "ended" : ""}`}
                onClick={() => onSelect(s.id)}
              >
                {s.status === "working" ? (
                  <StatusIndicator
                    status="working"
                    anim={settings.working_animation}
                    agent={s.agent}
                  />
                ) : (
                  <StatusDot status={s.status} />
                )}
                <span className="session-label">
                  <span
                    className="agent-badge"
                    style={{
                      color: AGENT_ACCENT[s.agent],
                      backgroundColor: `${AGENT_ACCENT[s.agent]}29`,
                    }}
                  >
                    {AGENT_SHORT[s.agent]}
                  </span>
                  <span className="session-project">{s.project || "—"}</span>
                  <span className="session-meta">
                    {s.detail ? s.detail : s.status}
                  </span>
                </span>
                <span className="spacer" />
                {settings.usage_tracking_enabled &&
                  showUsageFor(settings, s.agent) &&
                  usesDollarBudget(planTierFor(settings, s.agent)) &&
                  s.cost_usd > 0 && (
                    <span className="session-cost">{formatCost(s.cost_usd)}</span>
                  )}
                {s.ended ? (
                  <RowButton
                    icon={<IconX size={13} />}
                    title="Remove"
                    onClick={() => invoke("remove_session", { id: s.id })}
                  />
                ) : (
                  <>
                    {s.has_terminal && (
                      <RowButton
                        icon={<IconJump size={13} />}
                        title="Focus terminal"
                        variant={s.status === "waiting" ? "warn" : undefined}
                        onClick={() => invoke("focus_terminal", { id: s.id })}
                      />
                    )}
                    <RowButton
                      icon={<IconStop size={11} />}
                      title="End session"
                      variant="danger"
                      onClick={() => invoke("end_session", { id: s.id })}
                    />
                  </>
                )}
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}

// ---- Detail: per-session drill-down -----------------------------------------

function DetailView({
  detail,
  onBack,
}: {
  detail: SessionDetail | null;
  onBack: () => void;
}) {
  if (!detail) {
    return (
      <div className="sheet-inner">
        <div className="sheet-header">
          <button className="gear-btn" onClick={onBack} title="Back">
            <IconChevronLeft />
          </button>
          <span className="header-title">Session</span>
        </div>
        <div className="sheet-divider" />
        <div className="empty-state">
          <div className="empty-glyph">◌</div>
          <div className="empty-text">Session ended</div>
        </div>
      </div>
    );
  }

  return (
    <div className="sheet-inner">
      <div className="sheet-header">
        <button className="gear-btn" onClick={onBack} title="Back">
          <IconChevronLeft />
        </button>
        <StatusDot status={detail.status} />
        <span className="header-title">{detail.project || "Session"}</span>
        <span className="spacer" />
        {detail.has_terminal && (
          <button
            className="pill-btn"
            onClick={() => invoke("focus_terminal", { id: detail.id })}
          >
            Focus
          </button>
        )}
        {!detail.ended ? (
          <button
            className="pill-btn danger"
            onClick={() => invoke("end_session", { id: detail.id })}
          >
            End
          </button>
        ) : (
          <button
            className="pill-btn"
            onClick={() => {
              invoke("remove_session", { id: detail.id });
              onBack();
            }}
          >
            Remove
          </button>
        )}
      </div>
      <div className="sheet-divider" />

      <div className="sheet-body detail-body">
        <div className="detail-stats">
          <span className={`stat-status status-text-${detail.status}`}>
            {detail.ended ? "ended" : detail.status}
          </span>
          <span>{formatRuntime(detail.runtime_secs)}</span>
          <span>{formatCost(detail.cost_usd)}</span>
        </div>

        {detail.recent_actions.length > 0 && (
          <div className="detail-section">
            <div className="section-label">Recent activity</div>
            <ul className="action-list">
              {detail.recent_actions
                .slice()
                .reverse()
                .map((a, i) => (
                  <li key={i}>
                    <span className="action-tool">{a.tool}</span>
                    {a.detail && (
                      <span className="action-detail">{a.detail}</span>
                    )}
                  </li>
                ))}
            </ul>
          </div>
        )}

        <div className="detail-section">
          <div className="section-label">Conversation</div>
          {detail.messages.length === 0 ? (
            <div className="empty-text small">No messages yet</div>
          ) : (
            detail.messages.map((m, i) => (
              <div key={i} className={`msg msg-${m.role}`}>
                <span className="msg-role">
                  {m.role === "user" ? "You" : AGENT_SHORT[detail.agent]}
                </span>
                <MarkdownText text={m.text} />
              </div>
            ))
          )}
        </div>
      </div>
    </div>
  );
}

// ---- App --------------------------------------------------------------------

function App() {
  const [state, setState] = useState<NotchState>({
    status: "idle",
    agent: null,
    detail: null,
    sessions: [],
    usage: {
      claude: { weekly_tokens: 0, weekly_dollars: 0, today_tokens: 0, dollars_today: 0 },
      codex: { weekly_tokens: 0, weekly_dollars: 0, today_tokens: 0, dollars_today: 0 },
    },
  });
  const [settings, setSettings] = useState<AppSettings>(DEFAULT_SETTINGS);
  const [view, setView] = useState<View>("pill");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [detail, setDetail] = useState<SessionDetail | null>(null);
  const [docked, setDocked] = useState(true);
  const [hooksInstalled, setHooksInstalled] = useState(true);
  const [brakeDismissedDay, setBrakeDismissedDay] = useState<string | null>(null);
  const [sheetWidth, setSheetWidth] = useState(() => {
    const stored = localStorage.getItem("sheet_width");
    const v = stored ? Number(stored) : NaN;
    return Number.isFinite(v)
      ? clamp(v, SHEET_MIN_WIDTH, SHEET_MAX_WIDTH)
      : SHEET_DEFAULT_WIDTH;
  });
  // Painted width of the resting pill, tweened between idle and active forms.
  const [pillWidth, setPillWidth] = useState(NOTCH_WIDTH_IDLE);
  // True while the panel plays its exit animation before collapsing to the pill.
  const [closing, setClosing] = useState(false);

  const drag = useRef<DragState | null>(null);
  const resize = useRef<{ startX: number; startW: number; lastW: number } | null>(
    null
  );
  const sheetRef = useRef<HTMLDivElement | null>(null);
  // Set when a window drag just ended, to swallow the click that release fires.
  const suppressClick = useRef(false);
  const dockedRef = useRef(true);
  const viewRef = useRef<View>("pill");
  // Fresh-closure handle for listeners registered once on mount (tray events).
  const goToRef = useRef<(next: View) => void>(() => {});
  const prevBrake = useRef(false);
  // Single-shot terminal jump per waiting episode (matches the Mac affordance).
  const jumpConsumed = useRef(false);
  // Live painted pill width + the cancel handle for an in-flight width tween, so
  // a new idle↔active transition interrupts the old one cleanly.
  const pillWidthRef = useRef(NOTCH_WIDTH_IDLE);
  const widthCancel = useRef<() => void>(() => {});
  // Pending collapse-animation timer (cleared on unmount / re-entry).
  const closeTimer = useRef<number | null>(null);

  useEffect(() => {
    const unlisten = listen<NotchState>("notch-state", (e) => setState(e.payload));
    // Tray companion: left-click / menu items ask for a view by name.
    const unlistenTray = listen<string>("open-view", (e) => {
      goToRef.current(e.payload === "settings" ? "settings" : "panel");
    });
    invoke<boolean>("overlay_docked").then(updateDocked);
    invoke<AppSettings>("get_settings").then(setSettings);
    invoke<boolean>("hooks_installed", { agent: "claude" }).then(setHooksInstalled);
    return () => {
      unlisten.then((off) => off());
      unlistenTray.then((off) => off());
    };
  }, []);

  // Keep the open drill-down fresh as new messages/usage stream in.
  useEffect(() => {
    if (!selectedId) {
      setDetail(null);
      return;
    }
    let cancelled = false;
    invoke<SessionDetail | null>("get_session", { id: selectedId }).then((d) => {
      if (!cancelled) setDetail(d);
    });
    return () => {
      cancelled = true;
    };
  }, [selectedId, state]);

  // Re-arm the one-shot terminal jump when a waiting episode ends.
  useEffect(() => {
    if (state.status !== "waiting") jumpConsumed.current = false;
  }, [state.status]);

  // Fit the window snugly around the sheet as its content grows/shrinks (the
  // session list loads at most ~5 rows) and as the user drags the width
  // handle. The sheet's size is content/state-driven, never window-driven, so
  // this can't feed back on itself. No-op in pill view (no sheet mounted).
  useEffect(() => {
    const el = sheetRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => {
      const r = el.getBoundingClientRect();
      invoke("resize_sheet", {
        width: Math.ceil(r.width),
        height: Math.ceil(r.height),
      });
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, [view]);

  // ---- Usage brake -------------------------------------------------------

  const today = new Date().toDateString();
  // Per-agent brake: an agent fires when its own usage crosses the shared
  // threshold. One "dismiss for today" quiets both until the day rolls over.
  const brakedAgents: Agent[] =
    settings.usage_tracking_enabled && brakeDismissedDay !== today
      ? (["claude", "codex"] as Agent[]).filter(
          (a) =>
            showUsageFor(settings, a) &&
            usageFraction(state, settings, a) >= settings.brake_threshold_percent
        )
      : [];
  const brakeEngaged = brakedAgents.length > 0;

  // ---- Idle ↔ active pill width ------------------------------------------
  // The pill rests minimal and grows only while something is live, so it's
  // barely there at idle. Tween the painted SVG width (the window is unchanged).
  const pillActive = state.status !== "idle" || brakeEngaged;
  useEffect(() => {
    const to = pillActive ? NOTCH_WIDTH : NOTCH_WIDTH_IDLE;
    const from = pillWidthRef.current;
    if (Math.round(from) === to) return;
    widthCancel.current();
    widthCancel.current = tween(220, (e) => {
      const w = from + (to - from) * e;
      pillWidthRef.current = w;
      setPillWidth(w);
    });
    return () => widthCancel.current();
  }, [pillActive]);

  // First engage → auto-expand the panel once so it can't be missed.
  useEffect(() => {
    if (brakeEngaged && !prevBrake.current && viewRef.current === "pill") {
      goTo("panel");
    }
    prevBrake.current = brakeEngaged;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [brakeEngaged]);

  function updateDocked(v: boolean) {
    dockedRef.current = v;
    setDocked(v);
  }

  function updateSettings(next: AppSettings) {
    setSettings(next);
    invoke("set_settings", { value: next });
  }

  // Move between views, resizing the window only when crossing the pill boundary.
  function goTo(next: View) {
    const wasPill = viewRef.current === "pill";
    const willPill = next === "pill";
    // Collapsing the panel while everything reads done counts as seeing it —
    // the checkmark dismisses (Mac acknowledgeDone parity).
    if (willPill && !wasPill && state.status === "done") {
      invoke("acknowledge_done");
    }
    viewRef.current = next;
    setView(next);
    if (willPill) setSelectedId(null);
    if (wasPill !== willPill) {
      invoke("set_panel_open", { open: !willPill });
    }
  }
  goToRef.current = goTo;

  // Collapse the open sheet back to the pill, playing a short exit animation
  // first so it eases away instead of vanishing. Reduced motion collapses
  // instantly. Guarded against double-entry while the exit is mid-flight.
  function collapseToPill() {
    if (viewRef.current === "pill" || closeTimer.current !== null) return;
    if (reduceMotion()) {
      goTo("pill");
      return;
    }
    setClosing(true);
    closeTimer.current = window.setTimeout(() => {
      closeTimer.current = null;
      setClosing(false);
      goTo("pill");
    }, 150);
  }

  function onPillClick() {
    if (state.status === "waiting" && !jumpConsumed.current) {
      jumpConsumed.current = true;
      const waiter = state.sessions.find((s) => s.status === "waiting");
      if (waiter) {
        invoke("focus_terminal", { id: waiter.id });
        return;
      }
    }
    if (state.status === "done") {
      invoke("acknowledge_done");
      return;
    }
    goTo("panel");
  }

  // ---- Dragging the blob -------------------------------------------------
  // The window doesn't snap 1:1 to the cursor: a rAF loop eases its position
  // toward the cursor (smooth follow), the per-frame delta becomes release
  // velocity, and letting go either flings with friction or glides into the
  // dock. Reduced motion collapses all of this to the old instant behavior.

  /** Fire-and-forget window move, logical px (matches the old drag contract). */
  function setWinPos(x: number, y: number) {
    getCurrentWindow().setPosition(new LogicalPosition(Math.round(x), Math.round(y)));
  }
  // Clamp to the union of all monitors so the eased follow + fling can travel
  // across displays (the union bounds are computed at drag start).
  const clampX = (d: DragState, x: number) => clamp(x, d.uLeft, d.uRight - d.winW);
  const clampY = (d: DragState, y: number) => clamp(y, d.uTop, d.uBottom - d.winH);

  /** rAF loop: ease `cur` toward `target`, recording the delta as velocity. */
  function followStep() {
    const d = drag.current;
    if (!d || d.raf === 0) return;
    if (!d.ready) {
      d.raf = requestAnimationFrame(followStep);
      return;
    }
    const k = reduceMotion() ? 1 : 0.4; // higher = snappier follow, less lag
    const nx = d.curX + (d.targetX - d.curX) * k;
    const ny = d.curY + (d.targetY - d.curY) * k;
    d.velX = nx - d.curX;
    d.velY = ny - d.curY;
    d.curX = nx;
    d.curY = ny;
    setWinPos(nx, ny);
    d.raf = requestAnimationFrame(followStep);
  }

  function onPointerDown(e: React.PointerEvent) {
    // In the expanded views, only empty chrome starts a window drag — pressing
    // a button, a session row, message text, or the width grip must keep its
    // own behavior.
    if (
      viewRef.current !== "pill" &&
      (e.target as Element).closest(
        "button, a, input, select, textarea, label, .session-row, .msg, .sheet-resize"
      )
    ) {
      return;
    }

    // Capture deliberately deferred to the drag threshold (onPointerMove):
    // capturing here would retarget the eventual click to this element,
    // swallowing clicks on children like the header's collapse.
    const target = e.currentTarget;

    drag.current = {
      target,
      pointerId: e.pointerId,
      startSX: e.screenX,
      startSY: e.screenY,
      startWX: 0,
      startWY: 0,
      monLeft: 0,
      monWidth: window.screen.width,
      monTop: 0,
      monHeight: window.screen.height,
      monitors: [],
      uLeft: 0,
      uTop: 0,
      uRight: window.screen.width,
      uBottom: window.screen.height,
      winW: PILL_WINDOW_WIDTH,
      winH: PILL_WINDOW_HEIGHT,
      moved: false,
      ready: false,
      curX: 0,
      curY: 0,
      targetX: 0,
      targetY: 0,
      velX: 0,
      velY: 0,
      raf: 0,
    };

    const wnd = getCurrentWindow();
    Promise.all([
      wnd.scaleFactor(),
      wnd.outerPosition(),
      currentMonitor(),
      wnd.outerSize(),
      availableMonitors(),
    ]).then(([scale, pos, mon, size, monitors]) => {
      const d = drag.current;
      if (!d) return;
      d.startWX = pos.x / scale;
      d.startWY = pos.y / scale;
      d.winW = size.width / scale;
      d.winH = size.height / scale;
      if (mon) {
        d.monLeft = mon.position.x / scale;
        d.monWidth = mon.size.width / scale;
        d.monTop = mon.position.y / scale;
        d.monHeight = mon.size.height / scale;
      }
      // All monitors in one logical coordinate space (window scale), so the
      // pill can be dragged across the seam between displays and the union
      // becomes the travel bounds — previously the clamp was the single
      // start-monitor, so the pill could never reach a second monitor.
      const rects = (monitors ?? []).map((m) => ({
        name: m.name ?? null,
        left: m.position.x / scale,
        top: m.position.y / scale,
        width: m.size.width / scale,
        height: m.size.height / scale,
      }));
      if (rects.length) {
        d.monitors = rects;
        d.uLeft = Math.min(...rects.map((r) => r.left));
        d.uTop = Math.min(...rects.map((r) => r.top));
        d.uRight = Math.max(...rects.map((r) => r.left + r.width));
        d.uBottom = Math.max(...rects.map((r) => r.top + r.height));
      }
      // Seed the eased-follow state at the window's real position so the first
      // frame doesn't lurch from (0,0).
      d.curX = d.targetX = d.startWX;
      d.curY = d.targetY = d.startWY;
      d.ready = true;
    });
  }

  function onPointerMove(e: React.PointerEvent) {
    const d = drag.current;
    if (!d) return;

    const dx = e.screenX - d.startSX;
    const dy = e.screenY - d.startSY;
    if (!d.moved && (Math.abs(dx) > DRAG_THRESHOLD || Math.abs(dy) > DRAG_THRESHOLD)) {
      d.moved = true;
      d.target.setPointerCapture(d.pointerId);
      if (dockedRef.current) updateDocked(false);
      d.raf = requestAnimationFrame(followStep); // begin eased follow
    }
    if (!d.moved || !d.ready) return;

    // Set the eased-follow target (the rAF loop moves the window toward it),
    // clamped to the union of all monitors so the pill can cross displays.
    d.targetX = clampX(d, d.startWX + dx);
    d.targetY = clampY(d, d.startWY + dy);
  }

  function onPointerUp(e: React.PointerEvent) {
    const d = drag.current;
    if (!d) return;
    if (d.raf) cancelAnimationFrame(d.raf);
    d.raf = 0;
    if (d.target.hasPointerCapture(e.pointerId)) {
      d.target.releasePointerCapture(e.pointerId);
    }
    drag.current = null;

    if (!d.moved) {
      if (viewRef.current === "pill") onPillClick();
      // Expanded: a plain press is a click on sheet chrome (e.g. the header's
      // collapse) — let the click event do its job.
      return;
    }
    // A drag's release also fires a click on whatever it ends over — swallow it.
    suppressClick.current = true;

    if (!d.ready) {
      // Geometry never arrived — commit current position without animating.
      settleFloating(d);
      return;
    }
    // Dock to whichever monitor the pill's (eased) center is over — not the
    // drag-start monitor — so dropping near the top of display 2 docks there.
    const host = hostMonitor(d);
    if (d.curY <= host.top + SNAP_Y) snapToDock(d, host);
    else fling(d);
  }

  /** The monitor under the pill's current (eased) center, else the start one. */
  function hostMonitor(d: DragState): MonitorRect {
    const cx = d.curX + d.winW / 2;
    const cy = d.curY + d.winH / 2;
    return (
      d.monitors.find(
        (r) => cx >= r.left && cx < r.left + r.width && cy >= r.top && cy < r.top + r.height
      ) ?? {
        name: null,
        left: d.monLeft,
        top: d.monTop,
        width: d.monWidth,
        height: d.monHeight,
      }
    );
  }

  /** Glide into the host monitor's top-center, then hand docking + persistence
      to Rust (DPI-correct physical-px centering, and it remembers the display
      so the watch loop keeps the notch there instead of the primary). */
  function snapToDock(d: DragState, host: MonitorRect) {
    const sx = host.left + (host.width - d.winW) / 2;
    const sy = host.top;
    const x0 = d.curX;
    const y0 = d.curY;
    tween(
      190,
      (e) => setWinPos(x0 + (sx - x0) * e, y0 + (sy - y0) * e),
      () => {
        updateDocked(true);
        invoke("dock_to_monitor", { name: host.name ?? "" });
      }
    );
  }

  /** Carry release momentum with friction, clamped to the monitor union, then settle. */
  function fling(d: DragState) {
    let vx = d.velX * 1.4;
    let vy = d.velY * 1.4;
    if (reduceMotion() || Math.hypot(vx, vy) < 0.5) {
      settleFloating(d);
      return;
    }
    const step = () => {
      vx *= 0.9;
      vy *= 0.9;
      d.curX = clampX(d, d.curX + vx);
      d.curY = clampY(d, d.curY + vy);
      setWinPos(d.curX, d.curY);
      if (Math.hypot(vx, vy) > 0.4) requestAnimationFrame(step);
      else settleFloating(d);
    };
    requestAnimationFrame(step);
  }

  /** Persist the blob's resting position + floating state + the monitor it's over. */
  function settleFloating(d: DragState) {
    const host = hostMonitor(d);
    updateDocked(false);
    invoke("set_docked", { docked: false });
    invoke("save_overlay_pos", {
      x: Math.round(d.curX + (d.winW - PILL_WINDOW_WIDTH) / 2),
      y: Math.round(d.curY),
      docked: false,
      monitor: host.name ?? null,
    });
  }

  // ---- Resizing the sheet width --------------------------------------------

  function onResizeDown(e: React.PointerEvent) {
    e.stopPropagation();
    e.currentTarget.setPointerCapture(e.pointerId);
    resize.current = { startX: e.screenX, startW: sheetWidth, lastW: sheetWidth };
  }

  function onResizeMove(e: React.PointerEvent) {
    const r = resize.current;
    if (!r) return;
    // The window keeps the sheet centered as it resizes, so the right edge
    // only moves half of any width change — double the pointer delta so the
    // edge tracks the cursor.
    const w = Math.round(
      clamp(r.startW + (e.screenX - r.startX) * 2, SHEET_MIN_WIDTH, SHEET_MAX_WIDTH)
    );
    r.lastW = w;
    setSheetWidth(w);
  }

  function onResizeUp(e: React.PointerEvent) {
    const r = resize.current;
    if (!r) return;
    resize.current = null;
    e.currentTarget.releasePointerCapture(e.pointerId);
    localStorage.setItem("sheet_width", String(r.lastW));
  }

  const PillContent = (
    <div className="pill-content">
      <StatusIndicator
        status={state.status}
        anim={settings.working_animation}
        agent={state.agent ?? undefined}
        forceColor={brakeEngaged ? "#ff9d3d" : undefined}
      />
      {state.status === "working" && state.detail && (
        <span className="pill-detail">{state.detail}</span>
      )}
    </div>
  );

  return (
    <div className="overlay-root">
      {view === "pill" ? (
        <div
          className={`notch-wrap ${docked ? "docked" : "floating"}`}
          onPointerDown={onPointerDown}
          onPointerMove={onPointerMove}
          onPointerUp={onPointerUp}
          title="Notchcode — drag to move, drag to the top to dock"
        >
          {docked ? (
            <NotchShape width={Math.round(pillWidth)} height={NOTCH_HEIGHT}>
              {PillContent}
            </NotchShape>
          ) : (
            <BlobShape width={Math.round(pillWidth)} height={NOTCH_HEIGHT}>
              {PillContent}
            </BlobShape>
          )}
        </div>
      ) : (
        <div
          className={`sheet ${docked ? "docked" : "floating"} view-${view} ${
            closing ? "closing" : ""
          }`}
          style={{ width: sheetWidth }}
          ref={sheetRef}
          onPointerDown={onPointerDown}
          onPointerMove={onPointerMove}
          onPointerUp={onPointerUp}
          onClickCapture={(e) => {
            if (suppressClick.current) {
              suppressClick.current = false;
              e.preventDefault();
              e.stopPropagation();
            }
          }}
        >
          {view === "panel" && (
            <PanelView
              state={state}
              settings={settings}
              braked={brakeEngaged}
              brakedAgents={brakedAgents}
              hooksInstalled={hooksInstalled}
              onSelect={(id) => {
                setSelectedId(id);
                goTo("detail");
              }}
              onCollapse={collapseToPill}
              onSettings={() => goTo("settings")}
              onDismissBrake={() => setBrakeDismissedDay(today)}
            />
          )}
          {view === "settings" && (
            <SettingsView
              settings={settings}
              onChange={updateSettings}
              onClose={() => goTo("panel")}
            />
          )}
          {view === "detail" && (
            <DetailView detail={detail} onBack={() => goTo("panel")} />
          )}
          <div
            className="sheet-resize"
            title="Drag to resize"
            onPointerDown={onResizeDown}
            onPointerMove={onResizeMove}
            onPointerUp={onResizeUp}
          />
        </div>
      )}
    </div>
  );
}

export default App;
