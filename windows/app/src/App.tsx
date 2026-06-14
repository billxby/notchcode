import { useEffect, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import {
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
import "./App.css";

const NOTCH_WIDTH = 200;
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

type DragState = {
  target: Element;
  pointerId: number;
  startSX: number;
  startSY: number;
  startWX: number;
  startWY: number;
  monLeft: number;
  monWidth: number;
  monTop: number;
  monHeight: number;
  /** Current window size (logical px) for clamping/snapping — the pill and
      the expanded sheet windows differ, so it's read live at drag start. */
  winW: number;
  winH: number;
  moved: boolean;
  ready: boolean;
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
  glyph,
  variant,
  onClick,
}: {
  glyph: string;
  variant?: string;
  onClick: () => void;
}) {
  return (
    <button
      className={`row-btn ${variant ?? ""}`}
      onClick={(e) => {
        e.stopPropagation();
        onClick();
      }}
    >
      {glyph}
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
          ⚙
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
              <div className="empty-glyph">◌</div>
              <div className="empty-text">No active sessions</div>
            </div>
          ) : (
            <div className="empty-state install">
              <div className="empty-glyph warn">⚡</div>
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
                    glyph="✕"
                    onClick={() => invoke("remove_session", { id: s.id })}
                  />
                ) : (
                  <>
                    {s.has_terminal && (
                      <RowButton
                        glyph="↗"
                        variant={s.status === "waiting" ? "warn" : undefined}
                        onClick={() => invoke("focus_terminal", { id: s.id })}
                      />
                    )}
                    <RowButton
                      glyph="■"
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
          <button className="gear-btn" onClick={onBack}>
            ‹
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
          ‹
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
      winW: PILL_WINDOW_WIDTH,
      winH: PILL_WINDOW_HEIGHT,
      moved: false,
      ready: false,
    };

    const wnd = getCurrentWindow();
    Promise.all([
      wnd.scaleFactor(),
      wnd.outerPosition(),
      currentMonitor(),
      wnd.outerSize(),
    ]).then(([scale, pos, mon, size]) => {
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
    }
    if (!d.moved || !d.ready) return;

    const nx = clamp(d.startWX + dx, d.monLeft, d.monLeft + d.monWidth - d.winW);
    const ny = clamp(d.startWY + dy, d.monTop, d.monTop + d.monHeight - d.winH);
    getCurrentWindow().setPosition(new LogicalPosition(Math.round(nx), Math.round(ny)));
  }

  function onPointerUp(e: React.PointerEvent) {
    const d = drag.current;
    drag.current = null;
    if (!d) return;
    if (d.target.hasPointerCapture(e.pointerId)) {
      d.target.releasePointerCapture(e.pointerId);
    }

    if (!d.moved) {
      if (viewRef.current === "pill") onPillClick();
      // Expanded: a plain press is a click on sheet chrome (e.g. the header's
      // collapse) — let the click event do its job.
      return;
    }
    // A drag's release also fires a click on whatever it ends over — swallow it.
    suppressClick.current = true;

    const wnd = getCurrentWindow();
    Promise.all([wnd.scaleFactor(), wnd.outerPosition()]).then(async ([scale, pos]) => {
      let xL = pos.x / scale;
      let yL = pos.y / scale;
      const shouldDock = yL <= d.monTop + SNAP_Y;
      if (shouldDock) {
        xL = d.monLeft + (d.monWidth - d.winW) / 2;
        yL = d.monTop;
        await wnd.setPosition(new LogicalPosition(Math.round(xL), Math.round(yL)));
      }
      updateDocked(shouldDock);
      invoke("set_docked", { docked: shouldDock });
      // Persist the pill-equivalent top-left (the windows share a center
      // axis), so restarting restores the blob where the user expects it.
      invoke("save_overlay_pos", {
        x: Math.round(xL + (d.winW - PILL_WINDOW_WIDTH) / 2),
        y: Math.round(yL),
        docked: shouldDock,
      });
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
            <NotchShape width={NOTCH_WIDTH} height={NOTCH_HEIGHT}>
              {PillContent}
            </NotchShape>
          ) : (
            <BlobShape width={NOTCH_WIDTH} height={NOTCH_HEIGHT}>
              {PillContent}
            </BlobShape>
          )}
        </div>
      ) : (
        <div
          className={`sheet ${docked ? "docked" : "floating"} view-${view}`}
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
              onCollapse={() => goTo("pill")}
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
