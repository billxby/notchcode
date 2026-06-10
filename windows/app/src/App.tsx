import { useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import NotchShape from "./NotchShape";
import {
  formatCost,
  formatRuntime,
  formatTokens,
  type NotchState,
  type SessionDetail,
  type Status,
} from "./types";
import "./App.css";

const NOTCH_WIDTH = 200;
const NOTCH_HEIGHT = 32;

function StatusIndicator({ status }: { status: Status }) {
  if (status === "done") {
    return <span className="status-check">✓</span>;
  }
  return <span className={`status-dot status-${status}`} />;
}

// ---- Panel: session list ----------------------------------------------------

function SessionList({
  state,
  onSelect,
}: {
  state: NotchState;
  onSelect: (id: string) => void;
}) {
  return (
    <>
      <div className="panel-header">
        <span className="panel-title">Sessions</span>
        <span className="usage-badge" title="Tokens / cost over the last 7 days">
          {formatTokens(state.weekly_tokens)} · {formatCost(state.weekly_dollars)}
        </span>
      </div>
      {state.sessions.length === 0 ? (
        <div className="panel-empty">No active sessions</div>
      ) : (
        <ul className="session-list">
          {state.sessions.map((s) => (
            <li
              key={s.id}
              className={`session-row ${s.ended ? "session-ended" : ""}`}
              onClick={() => onSelect(s.id)}
            >
              <StatusIndicator status={s.status} />
              <span className="session-project">{s.project || "—"}</span>
              <span className="session-meta">
                {s.detail ? (
                  <span className="session-detail">{s.detail}</span>
                ) : (
                  <span className={`session-status session-status-${s.status}`}>
                    {s.status}
                  </span>
                )}
              </span>
              <span className="session-cost">{formatCost(s.cost_usd)}</span>
            </li>
          ))}
        </ul>
      )}
    </>
  );
}

// ---- Panel: per-session drill-down ------------------------------------------

function SessionDetailView({
  detail,
  onBack,
}: {
  detail: SessionDetail;
  onBack: () => void;
}) {
  return (
    <div className="detail">
      <div className="detail-top">
        <button className="back-btn" onClick={onBack}>
          ‹ Back
        </button>
        <span className="detail-project">{detail.project || "—"}</span>
      </div>

      <div className="detail-stats">
        <span className={`session-status session-status-${detail.status}`}>
          {detail.ended ? "ended" : detail.status}
        </span>
        <span>{formatRuntime(detail.runtime_secs)}</span>
        <span>{formatCost(detail.cost_usd)}</span>
      </div>

      <div className="detail-actions">
        {detail.status === "waiting" && (
          <button onClick={() => invoke("focus_terminal", { id: detail.id })}>
            Jump to terminal
          </button>
        )}
        {!detail.ended ? (
          <button
            className="danger"
            onClick={() => invoke("end_session", { id: detail.id })}
          >
            End session
          </button>
        ) : (
          <button onClick={() => invoke("remove_session", { id: detail.id })}>
            Remove
          </button>
        )}
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
                  {a.detail && <span className="action-detail">{a.detail}</span>}
                </li>
              ))}
          </ul>
        </div>
      )}

      <div className="detail-section detail-messages">
        <div className="section-label">Conversation</div>
        {detail.messages.length === 0 ? (
          <div className="panel-empty">No messages yet</div>
        ) : (
          detail.messages.map((m, i) => (
            <div key={i} className={`msg msg-${m.role}`}>
              <span className="msg-role">{m.role === "user" ? "You" : "Claude"}</span>
              <span className="msg-text">{m.text}</span>
            </div>
          ))
        )}
      </div>
    </div>
  );
}

// ---- App --------------------------------------------------------------------

function App() {
  const [state, setState] = useState<NotchState>({
    status: "idle",
    detail: null,
    sessions: [],
    weekly_tokens: 0,
    weekly_dollars: 0,
  });
  const [open, setOpen] = useState(false);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [detail, setDetail] = useState<SessionDetail | null>(null);

  useEffect(() => {
    const unlisten = listen<NotchState>("notch-state", (e) => setState(e.payload));
    return () => {
      unlisten.then((off) => off());
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

  function togglePanel() {
    const next = !open;
    setOpen(next);
    if (!next) setSelectedId(null);
    invoke("set_panel_open", { open: next });
  }

  function selectSession(id: string) {
    setSelectedId(id);
  }

  return (
    <div className="overlay-root">
      <div className="notch-wrap" onClick={togglePanel} title="Notchcode">
        <NotchShape width={NOTCH_WIDTH} height={NOTCH_HEIGHT}>
          <div className="pill-content">
            <StatusIndicator status={state.status} />
            {state.status === "working" && state.detail && (
              <span className="pill-detail">{state.detail}</span>
            )}
          </div>
        </NotchShape>
      </div>

      {open && (
        <div className="panel" onClick={(e) => e.stopPropagation()}>
          {detail ? (
            <SessionDetailView detail={detail} onBack={() => setSelectedId(null)} />
          ) : (
            <SessionList state={state} onSelect={selectSession} />
          )}
        </div>
      )}
    </div>
  );
}

export default App;
