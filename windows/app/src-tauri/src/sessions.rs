// Session state engine — Windows logic port of the Mac `SessionStateEngine`
// (notchcode-plan.md §0.2, §0.6, §0.7, §11.3).
//
// Inputs: file activity (the watcher) and hooks (the hook server). The
// per-format transcript decoders live in their own modules (claude_jsonl.rs for
// Claude Code, codex_rollout.rs for Codex) and both emit the shared
// `ParseResult` defined here; hooks supply precise lifecycle status. Outputs: an
// aggregate status + detail for the pill, a session list for the panel, and
// per-session drill-down detail (messages, recent actions, cost) on demand.

use std::collections::HashMap;
use std::fs::File;
use std::path::Path;
use std::time::{Duration, Instant, SystemTime};

use chrono::{DateTime, Local};

use serde::{Deserialize, Serialize};

use crate::agent::Agent;
use crate::cost::{self, Model, Usage};
use crate::hooks::{HookEvent, HookKind};
use crate::winutil;

/// File-only (no hooks) working window. Hooks make this irrelevant (they end
/// work with Stop); it's the fallback recency signal.
const WORKING_WINDOW: Duration = Duration::from_secs(4);
/// Crash ceiling for a silent hook-driven working/waiting session.
const STALE_TIMEOUT: Duration = Duration::from_secs(600);
/// Forget sessions untouched this long.
const SESSION_TTL: Duration = Duration::from_secs(3600);
/// Absolute ceiling for a *Done* session that has no live process. Done is
/// normally sticky (it survives timeouts so the checkmark persists until the
/// user acknowledges it), but a file-only Done session has no PID to
/// crash-detect and may never be acknowledged — without a ceiling it would live
/// in the map forever (unbounded growth). 6h is far longer than any real
/// "did you notice it finished" window.
const DONE_TTL: Duration = Duration::from_secs(6 * 60 * 60);
/// Rolling usage window (7 days), in seconds.
const WEEK: Duration = Duration::from_secs(7 * 24 * 60 * 60);
/// Per-session caps (mirror the Mac limits).
const ACTION_LIMIT: usize = 5;
const MESSAGE_LIMIT: usize = 200;

/// Aggregate / per-session status. `Error` reserved for later.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Idle,
    Working,
    Waiting,
    Done,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    User,
    Assistant,
}

/// Returned by `handle_hook` on the entry edge of a waiting transition so the
/// caller (the watcher loop, which owns the AppHandle + Win32) can post a toast
/// and raise the terminal. The engine stays free of Tauri/notification deps.
#[derive(Clone, Debug)]
pub struct WaitingNotice {
    pub agent: Agent,
    pub project: String,
    pub detail: Option<String>,
    /// Terminal window captured at hook-fire time (best-effort focus target).
    pub terminal_hwnd: Option<isize>,
    /// Owning agent PID, to resolve the precise hosting window for the jump.
    pub claude_pid: Option<u32>,
}

/// Tool names that mean "the agent is blocked on the user," not "doing work."
/// Codex models its interactive prompts as tool calls, so these arrive as
/// PreToolUse hooks; without this they'd read as `working` and never alert.
/// Claude routes the same intent through PermissionRequest, so this set is
/// Codex-shaped. (Pulled from the Codex 0.139 protocol enum.)
pub fn is_blocking_tool(name: &str) -> bool {
    matches!(
        name,
        "request_user_input"
            | "request_permissions"
            | "exec_approval_request"
            | "apply_patch_approval_request"
            | "elicitation_request"
    )
}

/// One historical tool invocation (panel recent-activity feed).
#[derive(Clone, PartialEq, Eq, Debug, Serialize)]
pub struct ActionInfo {
    pub tool: String,
    pub detail: Option<String>,
}

/// One conversation turn (drill-down view). Text-only.
#[derive(Clone, PartialEq, Eq, Debug, Serialize)]
pub struct MessageInfo {
    pub role: Role,
    pub text: String,
}

/// A panel row.
#[derive(Clone, PartialEq, Debug, Serialize)]
pub struct SessionInfo {
    pub id: String,
    /// Which coding agent this session belongs to (drives the UI badge/accent).
    pub agent: Agent,
    pub project: String,
    pub status: Status,
    pub detail: Option<String>,
    pub cost_usd: f64,
    pub runtime_secs: u64,
    pub ended: bool,
    /// Whether the session has something to jump to — a Claude PID to resolve
    /// the hosting window from, or a hook-captured HWND. Gates the Focus
    /// affordance (the Mac equivalent is `terminalBundleID != nil`).
    pub has_terminal: bool,
}

/// Full drill-down payload for one session (returned by the `get_session` cmd).
#[derive(Clone, Debug, Serialize)]
pub struct SessionDetail {
    pub id: String,
    pub agent: Agent,
    pub project: String,
    pub status: Status,
    pub detail: Option<String>,
    pub cost_usd: f64,
    pub runtime_secs: u64,
    pub ended: bool,
    pub has_terminal: bool,
    pub recent_actions: Vec<ActionInfo>,
    pub messages: Vec<MessageInfo>,
}

struct Session {
    agent: Agent,
    project: String,
    status: Status,
    detail: Option<String>,
    last_update: Instant,
    first_seen: Instant,
    hook_driven: bool,
    recent_actions: Vec<ActionInfo>,
    cost_usd: f64,
    messages: Vec<MessageInfo>,
    claude_pid: Option<u32>,
    terminal_hwnd: Option<isize>,
    ended: bool,
}

impl Session {
    fn new(agent: Agent, project: String, status: Status, now: Instant) -> Self {
        Self {
            agent,
            project,
            status,
            detail: None,
            last_update: now,
            first_seen: now,
            hook_driven: false,
            recent_actions: Vec::new(),
            cost_usd: 0.0,
            messages: Vec::new(),
            claude_pid: None,
            terminal_hwnd: None,
            ended: false,
        }
    }
}

struct UsageTick {
    /// Which agent this usage belongs to — weekly/today totals meter per agent
    /// because Claude and Codex bill on separate plans with separate budgets.
    agent: Agent,
    tokens: u64,
    usd: f64,
    /// Wall-clock time (not Instant) so "today" can mean the local calendar day.
    at: SystemTime,
}

/// True if `t` falls on the current local calendar day.
fn is_today(t: SystemTime) -> bool {
    let dt: DateTime<Local> = t.into();
    dt.date_naive() == Local::now().date_naive()
}

pub struct SessionEngine {
    sessions: HashMap<String, Session>,
    usage: Vec<UsageTick>,
    /// Running per-agent 7-day totals (kept as counters so state builds don't
    /// re-sum a week of ticks); decremented in `prune` as ticks age out.
    weekly_tokens: HashMap<Agent, u64>,
    weekly_dollars: HashMap<Agent, f64>,
}

impl SessionEngine {
    pub fn new() -> Self {
        Self {
            sessions: HashMap::new(),
            usage: Vec::new(),
            weekly_tokens: HashMap::new(),
            weekly_dollars: HashMap::new(),
        }
    }

    // ---- Inputs --------------------------------------------------------------

    /// File watcher: this session's JSONL was written. Fallback working signal;
    /// never overrides a hook-set waiting/done.
    pub fn record_activity(&mut self, agent: Agent, session_id: &str, project: String) {
        let now = Instant::now();
        let key = agent.session_key(session_id);
        let entry = self
            .sessions
            .entry(key)
            .or_insert_with(|| Session::new(agent, project.clone(), Status::Working, now));
        if !project.is_empty() {
            entry.project = project;
        }
        entry.last_update = now;
        if matches!(entry.status, Status::Idle | Status::Working) {
            entry.status = Status::Working;
        }
    }

    /// Hook: authoritative lifecycle event. `foreground` is the captured
    /// foreground HWND (the terminal) for waiting/prompt events. Returns a
    /// `WaitingNotice` on the entry edge of a waiting transition so the caller
    /// can alert + focus; `None` for everything else.
    pub fn handle_hook(
        &mut self,
        event: &HookEvent,
        foreground: Option<isize>,
    ) -> Option<WaitingNotice> {
        let session_id = event.session_id.clone()?;
        let key = event.agent.session_key(&session_id);
        let now = Instant::now();
        let project = event
            .project_path
            .as_deref()
            .map(project_from_cwd)
            .unwrap_or_default();

        let entry = self
            .sessions
            .entry(key)
            .or_insert_with(|| Session::new(event.agent, project.clone(), Status::Idle, now));
        let was_waiting = entry.status == Status::Waiting;
        if !project.is_empty() {
            entry.project = project;
        }
        entry.last_update = now;
        entry.hook_driven = true;
        if let Some(pid) = event.claude_pid {
            entry.claude_pid = Some(pid);
            entry.ended = false; // a hook means it's alive again
        }

        match event.kind {
            HookKind::PreToolUse => {
                // Codex surfaces "ask the user" / "approve this" as ordinary
                // tool calls (request_user_input, *_approval_request) rather
                // than a PermissionRequest hook — so a naive PreToolUse would
                // read as `working` and never alert. Route those through the
                // same waiting path; everything else is real work.
                if event.tool_name.as_deref().map(is_blocking_tool).unwrap_or(false) {
                    return enter_waiting(entry, was_waiting, foreground, event.tool_detail.clone());
                }
                entry.status = Status::Working;
                entry.detail = event.tool_detail.clone().or_else(|| event.tool_name.clone());
                if let Some(tool) = &event.tool_name {
                    entry.recent_actions.push(ActionInfo {
                        tool: tool.clone(),
                        detail: event.tool_detail.clone(),
                    });
                    let overflow = entry.recent_actions.len().saturating_sub(ACTION_LIMIT);
                    if overflow > 0 {
                        entry.recent_actions.drain(0..overflow);
                    }
                }
            }
            HookKind::PostToolUse => {
                entry.status = Status::Working;
                entry.detail = None;
            }
            HookKind::UserPromptSubmit => {
                entry.status = Status::Working;
                entry.detail = None;
                entry.terminal_hwnd = foreground.or(entry.terminal_hwnd);
            }
            HookKind::PermissionRequest => {
                return enter_waiting(entry, was_waiting, foreground, event.tool_detail.clone());
            }
            HookKind::Stop => {
                entry.status = Status::Done;
                entry.detail = None;
            }
        }
        None
    }

    /// Assistant message usage → per-session cost + weekly rolling totals.
    pub fn record_usage(
        &mut self,
        agent: Agent,
        session_id: &str,
        project: &str,
        usage: &Usage,
        model: Model,
    ) {
        let usd = cost::cost(usage, model);
        let tokens = usage.billable_tokens();
        if tokens == 0 {
            return;
        }
        let now = Instant::now();
        self.usage.push(UsageTick {
            agent,
            tokens,
            usd,
            at: SystemTime::now(),
        });
        *self.weekly_tokens.entry(agent).or_insert(0) += tokens;
        *self.weekly_dollars.entry(agent).or_insert(0.0) += usd;

        let key = agent.session_key(session_id);
        let entry = self
            .sessions
            .entry(key)
            .or_insert_with(|| Session::new(agent, project.to_string(), Status::Working, now));
        if !project.is_empty() {
            entry.project = project.to_string();
        }
        entry.cost_usd += usd;
    }

    /// Append a parsed conversation turn (capped FIFO).
    pub fn record_message(
        &mut self,
        agent: Agent,
        session_id: &str,
        project: &str,
        role: Role,
        text: String,
    ) {
        let now = Instant::now();
        let key = agent.session_key(session_id);
        let entry = self
            .sessions
            .entry(key)
            .or_insert_with(|| Session::new(agent, project.to_string(), Status::Working, now));
        if !project.is_empty() {
            entry.project = project.to_string();
        }
        entry.messages.push(MessageInfo { role, text });
        let overflow = entry.messages.len().saturating_sub(MESSAGE_LIMIT);
        if overflow > 0 {
            entry.messages.drain(0..overflow);
        }
    }

    /// Codex-only: a coarse turn boundary parsed from the rollout transcript.
    /// `TurnStarted` → working, `TurnCompleted` → done. This is Codex's
    /// running/idle backbone because its hooks can't provide one (no Stop hook;
    /// built-in tools fire no PreToolUse). Marked `hook_driven` so the status
    /// gets the long staleness window — a turn can run minutes between writes,
    /// and the 4s file window would otherwise decay it to idle mid-turn.
    pub fn record_lifecycle(
        &mut self,
        agent: Agent,
        session_id: &str,
        project: &str,
        kind: Lifecycle,
    ) {
        let now = Instant::now();
        let key = agent.session_key(session_id);
        let entry = self
            .sessions
            .entry(key)
            .or_insert_with(|| Session::new(agent, project.to_string(), Status::Idle, now));
        if !project.is_empty() {
            entry.project = project.to_string();
        }
        entry.last_update = now;
        entry.hook_driven = true;
        entry.ended = false;
        match kind {
            Lifecycle::TurnStarted => {
                entry.status = Status::Working;
                entry.detail = None;
            }
            Lifecycle::TurnCompleted => {
                entry.status = Status::Done;
                entry.detail = None;
            }
        }
    }

    /// Boot-time catch-up ingestion for one historical JSONL — the Windows
    /// analog of the Mac `ProjectsWatcher.catchUpWeek` recency gate. `mtime` is
    /// the file's last-write wall-clock, used to both age the usage ticks and
    /// decide whether the session is fresh enough to surface as a panel row.
    ///
    /// Usage always feeds the rolling weekly totals, so the badge reflects work
    /// done before launch. A session row is only created when the file was
    /// written within `STALE_TIMEOUT` — i.e. it belongs to a live, merely-idle
    /// session. Week-old transcripts thus update the weekly figures without
    /// resurrecting a week of dead sessions into the panel.
    pub fn catch_up_file(
        &mut self,
        agent: Agent,
        session_id: &str,
        project: &str,
        mtime: SystemTime,
        messages: Vec<(Role, String)>,
        usages: &[(Usage, Model)],
        last_lifecycle: Option<Lifecycle>,
    ) {
        // Usage → weekly window. Stamp ticks with the file's real mtime so the
        // "today"/7-day buckets and the prune horizon stay honest for history.
        let mut row_usd = 0.0;
        for (usage, model) in usages {
            let tokens = usage.billable_tokens();
            if tokens == 0 {
                continue;
            }
            let usd = cost::cost(usage, *model);
            self.usage.push(UsageTick {
                agent,
                tokens,
                usd,
                at: mtime,
            });
            *self.weekly_tokens.entry(agent).or_insert(0) += tokens;
            *self.weekly_dollars.entry(agent).or_insert(0.0) += usd;
            row_usd += usd;
        }

        // Only recent files map to a live session worth showing. Backdate the
        // row's timestamps from the mtime so the snapshot's staleness filter
        // treats it exactly like a session that went idle that long ago.
        let age = SystemTime::now()
            .duration_since(mtime)
            .unwrap_or(Duration::ZERO);
        if age >= STALE_TIMEOUT {
            return;
        }
        let now = Instant::now();
        let stamp = now.checked_sub(age).unwrap_or(now);
        let key = agent.session_key(session_id);
        let entry = self
            .sessions
            .entry(key)
            .or_insert_with(|| Session::new(agent, project.to_string(), Status::Idle, stamp));
        if !project.is_empty() {
            entry.project = project.to_string();
        }
        entry.last_update = stamp;
        if stamp < entry.first_seen {
            entry.first_seen = stamp;
        }
        // A turn boundary from the tail of a recent rollout means the session
        // was mid-turn (working) or just finished (done) at launch — surface
        // that instead of a flat idle. hook_driven so it keeps the long window.
        if let Some(kind) = last_lifecycle {
            entry.hook_driven = true;
            entry.status = match kind {
                Lifecycle::TurnStarted => Status::Working,
                Lifecycle::TurnCompleted => Status::Done,
            };
        }
        entry.cost_usd += row_usd;
        for (role, text) in messages {
            entry.messages.push(MessageInfo { role, text });
        }
        let overflow = entry.messages.len().saturating_sub(MESSAGE_LIMIT);
        if overflow > 0 {
            entry.messages.drain(0..overflow);
        }
    }

    // ---- Lifecycle controls (w0.7) ------------------------------------------

    /// SIGTERM-equivalent: terminate the captured Claude PID and gray the row.
    pub fn end_session(&mut self, id: &str) -> bool {
        let Some(s) = self.sessions.get_mut(id) else {
            return false;
        };
        if let Some(pid) = s.claude_pid {
            winutil::terminate(pid);
        }
        s.ended = true;
        s.status = Status::Idle;
        true
    }

    /// Drop a session from the panel entirely.
    pub fn remove_session(&mut self, id: &str) {
        self.sessions.remove(id);
    }

    /// First-tap acknowledgment of the sticky done checkmark: done → idle.
    pub fn acknowledge_done(&mut self) {
        for s in self.sessions.values_mut() {
            if s.status == Status::Done {
                s.status = Status::Idle;
            }
        }
    }

    /// Everything the focus jump needs: the Claude PID (to resolve the hosting
    /// terminal/IDE window live), the hook-captured foreground HWND (fallback),
    /// and the project name (title hint for multi-window apps).
    pub fn focus_target(&self, id: &str) -> Option<(Option<u32>, Option<isize>, String)> {
        self.sessions
            .get(id)
            .map(|s| (s.claude_pid, s.terminal_hwnd, s.project.clone()))
    }

    /// Mark sessions whose Claude process has died as ended (per-PID liveness).
    pub fn crash_check(&mut self) {
        for s in self.sessions.values_mut() {
            if s.ended {
                continue;
            }
            if let Some(pid) = s.claude_pid {
                if !winutil::is_alive(pid) {
                    s.ended = true;
                    s.status = Status::Idle;
                }
            }
        }
    }

    // ---- Outputs -------------------------------------------------------------

    pub fn aggregate_status(&self) -> Status {
        let now = Instant::now();
        let mut waiting = false;
        let mut working = false;
        let mut done = false;
        for s in self.sessions.values() {
            if s.ended {
                continue;
            }
            match effective_status(s, now) {
                Status::Waiting => waiting = true,
                Status::Working => working = true,
                Status::Done => done = true,
                Status::Idle => {}
            }
        }
        if waiting {
            Status::Waiting
        } else if working {
            Status::Working
        } else if done {
            Status::Done
        } else {
            Status::Idle
        }
    }

    /// The agent driving the aggregate when it's working, so the collapsed pill
    /// can tint its spinner by agent (and force Codex onto the pulse). Prefers
    /// the agent of a working session with a tool detail — the one whose phrase
    /// the pill shows — then any plain working session. `None` when nothing is
    /// working; mixed agents resolve to whichever wins that order.
    pub fn aggregate_working_agent(&self) -> Option<Agent> {
        let now = Instant::now();
        let mut named: Option<Agent> = None;
        let mut plain: Option<Agent> = None;
        for s in self.sessions.values() {
            if s.ended || effective_status(s, now) != Status::Working {
                continue;
            }
            if s.detail.is_some() {
                named.get_or_insert(s.agent);
            } else {
                plain.get_or_insert(s.agent);
            }
        }
        named.or(plain)
    }

    /// Detail text for the pill: the tool phrase of a fresh working session.
    pub fn aggregate_detail(&self) -> Option<String> {
        let now = Instant::now();
        self.sessions
            .values()
            .find(|s| !s.ended && effective_status(s, now) == Status::Working && s.detail.is_some())
            .and_then(|s| s.detail.clone())
    }

    pub fn weekly_tokens(&self, agent: Agent) -> u64 {
        self.weekly_tokens.get(&agent).copied().unwrap_or(0)
    }

    pub fn weekly_dollars(&self, agent: Agent) -> f64 {
        self.weekly_dollars.get(&agent).copied().unwrap_or(0.0)
    }

    /// Tokens observed today (local calendar day) for `agent`. Scales the
    /// brake/today figures with today's activity, not the whole week.
    pub fn today_tokens(&self, agent: Agent) -> u64 {
        self.usage
            .iter()
            .filter(|t| t.agent == agent && is_today(t.at))
            .map(|t| t.tokens)
            .sum()
    }

    /// API-rate dollars spent today by `agent` — the primary metric for the
    /// API tier, matching the "daily $ cap" setting's semantics.
    pub fn dollars_today(&self, agent: Agent) -> f64 {
        self.usage
            .iter()
            .filter(|t| t.agent == agent && is_today(t.at))
            .map(|t| t.usd)
            .sum()
    }

    /// Recently-active sessions for the panel, stable-sorted by id.
    pub fn snapshot(&self) -> Vec<SessionInfo> {
        let now = Instant::now();
        let mut out: Vec<SessionInfo> = self
            .sessions
            .iter()
            .filter(|(_, s)| {
                s.status == Status::Done || now.duration_since(s.last_update) < STALE_TIMEOUT
            })
            .map(|(id, s)| SessionInfo {
                id: id.clone(),
                agent: s.agent,
                project: s.project.clone(),
                status: effective_status(s, now),
                detail: s.detail.clone(),
                cost_usd: s.cost_usd,
                runtime_secs: now.duration_since(s.first_seen).as_secs(),
                ended: s.ended,
                has_terminal: s.terminal_hwnd.is_some() || s.claude_pid.is_some(),
            })
            .collect();
        out.sort_by(|a, b| a.id.cmp(&b.id));
        out
    }

    /// Full drill-down detail for one session.
    pub fn get_session(&self, id: &str) -> Option<SessionDetail> {
        let now = Instant::now();
        self.sessions.get(id).map(|s| SessionDetail {
            id: id.to_string(),
            agent: s.agent,
            project: s.project.clone(),
            status: effective_status(s, now),
            detail: s.detail.clone(),
            cost_usd: s.cost_usd,
            runtime_secs: now.duration_since(s.first_seen).as_secs(),
            ended: s.ended,
            has_terminal: s.terminal_hwnd.is_some() || s.claude_pid.is_some(),
            recent_actions: s.recent_actions.clone(),
            messages: s.messages.clone(),
        })
    }

    // ---- Maintenance ---------------------------------------------------------

    pub fn prune(&mut self) {
        let now = Instant::now();
        // Done is deliberately sticky (the Mac rule): the checkmark must
        // outlive every timeout until the user acknowledges it or the Claude
        // process dies (crash_check). TTL only forgets non-done sessions.
        self.sessions.retain(|_, s| {
            if s.status == Status::Done {
                // Sticky, but not forever: a Done session with a live process
                // stays until the PID dies or the user acknowledges it; a
                // file-only Done session (no PID) is forgotten once it's been
                // sitting well past the normal TTL, so the map can't grow without
                // bound from many short transcript-only sessions.
                s.claude_pid.is_some() || now.duration_since(s.last_update) < DONE_TTL
            } else {
                now.duration_since(s.last_update) < SESSION_TTL
            }
        });

        // Age out usage ticks past the 7-day window, decrementing the totals.
        // Wall-clock here (usage ticks are SystemTime); a clock that jumped
        // backwards just keeps the tick (treat as still fresh).
        let wall = SystemTime::now();
        // Accumulate removals into locals first — the retain closure can't also
        // borrow self.weekly_* while self.usage is mutably borrowed.
        let mut removed_tokens: HashMap<Agent, u64> = HashMap::new();
        let mut removed_dollars: HashMap<Agent, f64> = HashMap::new();
        self.usage.retain(|t| {
            if wall.duration_since(t.at).map(|d| d < WEEK).unwrap_or(true) {
                true
            } else {
                *removed_tokens.entry(t.agent).or_insert(0) += t.tokens;
                *removed_dollars.entry(t.agent).or_insert(0.0) += t.usd;
                false
            }
        });
        for (agent, tok) in removed_tokens {
            let e = self.weekly_tokens.entry(agent).or_insert(0);
            *e = e.saturating_sub(tok);
        }
        for (agent, usd) in removed_dollars {
            let e = self.weekly_dollars.entry(agent).or_insert(0.0);
            *e = (*e - usd).max(0.0);
        }
    }
}

/// Flip a session into `Waiting` and, on the entry edge, capture its terminal
/// and emit a `WaitingNotice`. Shared by the PermissionRequest hook and Codex's
/// blocking tool calls — both mean "the agent is parked until the user answers."
/// `was_waiting` guards the notice to the entry edge so a re-fired hook doesn't
/// re-alert or re-steal focus.
fn enter_waiting(
    entry: &mut Session,
    was_waiting: bool,
    foreground: Option<isize>,
    detail: Option<String>,
) -> Option<WaitingNotice> {
    entry.status = Status::Waiting;
    entry.detail = detail.clone();
    if was_waiting {
        return None;
    }
    entry.terminal_hwnd = foreground.or(entry.terminal_hwnd);
    Some(WaitingNotice {
        agent: entry.agent,
        project: entry.project.clone(),
        detail,
        terminal_hwnd: entry.terminal_hwnd,
        claude_pid: entry.claude_pid,
    })
}

/// A session's status accounting for staleness. Working/Waiting decay to Idle
/// past the freshness window; Done is sticky.
fn effective_status(s: &Session, now: Instant) -> Status {
    let window = if s.hook_driven {
        STALE_TIMEOUT
    } else {
        WORKING_WINDOW
    };
    let fresh = now.duration_since(s.last_update) < window;
    match s.status {
        Status::Done => Status::Done,
        Status::Working if fresh => Status::Working,
        Status::Waiting if fresh => Status::Waiting,
        _ => Status::Idle,
    }
}

/// Claude Code folder-name slug → display label (last segment after `-`).
pub fn decode_project_slug(slug: &str) -> String {
    slug.rsplit('-')
        .find(|s| !s.is_empty())
        .unwrap_or(slug)
        .to_string()
}

/// cwd path → display label (last path segment). Shared by the engine and the
/// Claude transcript parser (claude_jsonl).
pub fn project_from_cwd(cwd: &str) -> String {
    cwd.trim_end_matches(['/', '\\'])
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(cwd)
        .to_string()
}

// ---- Shared transcript-parse types ------------------------------------------
//
// The Claude JSONL parser (claude_jsonl.rs) and the Codex rollout parser
// (codex_rollout.rs) both produce a `ParseResult`, so the watcher → engine path
// is identical for both agents. The per-format decoders live in their own
// modules; only the shared result type and the file/cwd helpers live here.

/// A coarse turn boundary parsed from a transcript. Only Codex emits these —
/// its rollout brackets every turn with `task_started` / `task_complete`
/// event_msg lines, the only reliable running/idle signal it has. Codex's hook
/// stream can't carry it: there's no `Stop` hook, and built-in tools (web
/// search, reasoning) fire no PreToolUse, so a hook-only Codex session would
/// sit on the wrong status. Claude doesn't need this (its Stop hook covers it),
/// so the Claude parser leaves `lifecycle` empty.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Lifecycle {
    TurnStarted,
    TurnCompleted,
}

/// Everything a single pass over new transcript bytes produces.
#[derive(Default)]
pub struct ParseResult {
    pub project: Option<String>,
    pub messages: Vec<(Role, String)>,
    pub usages: Vec<(Usage, Model)>,
    pub lifecycle: Vec<Lifecycle>,
}

/// Open a file with a short retry — transcript files can be briefly locked
/// mid-write on Windows. Shared by both transcript parsers.
pub fn open_with_retry(path: &Path) -> Option<File> {
    for attempt in 0..3 {
        match File::open(path) {
            Ok(f) => return Some(f),
            Err(_) if attempt < 2 => std::thread::sleep(Duration::from_millis(20)),
            Err(_) => return None,
        }
    }
    None
}
