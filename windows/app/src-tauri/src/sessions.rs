// Session state engine — Windows logic port of the Mac `SessionStateEngine` +
// `JSONLParser` (notchcode-plan.md §0.2, §0.6, §0.7, §11.3).
//
// Inputs: file activity (the watcher) and hooks (the hook server). File parsing
// extracts the project name, conversation text, and token usage from each
// session's JSONL; hooks supply precise lifecycle status. Outputs: an aggregate
// status + detail for the pill, a session list for the panel, and per-session
// drill-down detail (messages, recent actions, cost) on demand.

use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

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
    pub project: String,
    pub status: Status,
    pub detail: Option<String>,
    pub cost_usd: f64,
    pub runtime_secs: u64,
    pub ended: bool,
}

/// Full drill-down payload for one session (returned by the `get_session` cmd).
#[derive(Clone, Debug, Serialize)]
pub struct SessionDetail {
    pub id: String,
    pub project: String,
    pub status: Status,
    pub detail: Option<String>,
    pub cost_usd: f64,
    pub runtime_secs: u64,
    pub ended: bool,
    pub recent_actions: Vec<ActionInfo>,
    pub messages: Vec<MessageInfo>,
}

struct Session {
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
    fn new(project: String, status: Status, now: Instant) -> Self {
        Self {
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
    tokens: u64,
    usd: f64,
    at: Instant,
}

pub struct SessionEngine {
    sessions: HashMap<String, Session>,
    usage: Vec<UsageTick>,
    weekly_tokens: u64,
    weekly_dollars: f64,
}

impl SessionEngine {
    pub fn new() -> Self {
        Self {
            sessions: HashMap::new(),
            usage: Vec::new(),
            weekly_tokens: 0,
            weekly_dollars: 0.0,
        }
    }

    // ---- Inputs --------------------------------------------------------------

    /// File watcher: this session's JSONL was written. Fallback working signal;
    /// never overrides a hook-set waiting/done.
    pub fn record_activity(&mut self, session_id: &str, project: String) {
        let now = Instant::now();
        let entry = self
            .sessions
            .entry(session_id.to_string())
            .or_insert_with(|| Session::new(project.clone(), Status::Working, now));
        if !project.is_empty() {
            entry.project = project;
        }
        entry.last_update = now;
        if matches!(entry.status, Status::Idle | Status::Working) {
            entry.status = Status::Working;
        }
    }

    /// Hook: authoritative lifecycle event. `foreground` is the captured
    /// foreground HWND (the terminal) for waiting/prompt events.
    pub fn handle_hook(&mut self, event: &HookEvent, foreground: Option<isize>) {
        let Some(session_id) = event.session_id.clone() else {
            return;
        };
        let now = Instant::now();
        let project = event
            .project_path
            .as_deref()
            .map(project_from_cwd)
            .unwrap_or_default();

        let entry = self
            .sessions
            .entry(session_id)
            .or_insert_with(|| Session::new(project.clone(), Status::Idle, now));
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
                entry.status = Status::Waiting;
                if !was_waiting {
                    entry.terminal_hwnd = foreground.or(entry.terminal_hwnd);
                }
            }
            HookKind::Stop => {
                entry.status = Status::Done;
                entry.detail = None;
            }
        }
    }

    /// Assistant message usage → per-session cost + weekly rolling totals.
    pub fn record_usage(&mut self, session_id: &str, project: &str, usage: &Usage, model: Model) {
        let usd = cost::cost(usage, model);
        let tokens = usage.billable_tokens();
        if tokens == 0 {
            return;
        }
        let now = Instant::now();
        self.usage.push(UsageTick { tokens, usd, at: now });
        self.weekly_tokens += tokens;
        self.weekly_dollars += usd;

        let entry = self
            .sessions
            .entry(session_id.to_string())
            .or_insert_with(|| Session::new(project.to_string(), Status::Working, now));
        if !project.is_empty() {
            entry.project = project.to_string();
        }
        entry.cost_usd += usd;
    }

    /// Append a parsed conversation turn (capped FIFO).
    pub fn record_message(&mut self, session_id: &str, project: &str, role: Role, text: String) {
        let now = Instant::now();
        let entry = self
            .sessions
            .entry(session_id.to_string())
            .or_insert_with(|| Session::new(project.to_string(), Status::Working, now));
        if !project.is_empty() {
            entry.project = project.to_string();
        }
        entry.messages.push(MessageInfo { role, text });
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

    /// The captured terminal HWND for a session, used by the waiting jump.
    pub fn terminal_hwnd(&self, id: &str) -> Option<isize> {
        self.sessions.get(id).and_then(|s| s.terminal_hwnd)
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

    /// Detail text for the pill: the tool phrase of a fresh working session.
    pub fn aggregate_detail(&self) -> Option<String> {
        let now = Instant::now();
        self.sessions
            .values()
            .find(|s| !s.ended && effective_status(s, now) == Status::Working && s.detail.is_some())
            .and_then(|s| s.detail.clone())
    }

    pub fn weekly_tokens(&self) -> u64 {
        self.weekly_tokens
    }

    pub fn weekly_dollars(&self) -> f64 {
        self.weekly_dollars
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
                project: s.project.clone(),
                status: effective_status(s, now),
                detail: s.detail.clone(),
                cost_usd: s.cost_usd,
                runtime_secs: now.duration_since(s.first_seen).as_secs(),
                ended: s.ended,
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
            project: s.project.clone(),
            status: effective_status(s, now),
            detail: s.detail.clone(),
            cost_usd: s.cost_usd,
            runtime_secs: now.duration_since(s.first_seen).as_secs(),
            ended: s.ended,
            recent_actions: s.recent_actions.clone(),
            messages: s.messages.clone(),
        })
    }

    // ---- Maintenance ---------------------------------------------------------

    pub fn prune(&mut self) {
        let now = Instant::now();
        self.sessions
            .retain(|_, s| now.duration_since(s.last_update) < SESSION_TTL);

        // Age out usage ticks past the 7-day window, decrementing the totals.
        let mut removed_tokens = 0u64;
        let mut removed_dollars = 0.0f64;
        self.usage.retain(|t| {
            if now.duration_since(t.at) < WEEK {
                true
            } else {
                removed_tokens += t.tokens;
                removed_dollars += t.usd;
                false
            }
        });
        self.weekly_tokens = self.weekly_tokens.saturating_sub(removed_tokens);
        self.weekly_dollars = (self.weekly_dollars - removed_dollars).max(0.0);
    }
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

fn project_from_cwd(cwd: &str) -> String {
    cwd.trim_end_matches(['/', '\\'])
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(cwd)
        .to_string()
}

// ---- JSONL parsing (full port of the Mac JSONLParser) -----------------------

/// Everything a single pass over the new bytes produces.
#[derive(Default)]
pub struct ParseResult {
    pub project: Option<String>,
    pub messages: Vec<(Role, String)>,
    pub usages: Vec<(Usage, Model)>,
}

#[derive(Deserialize)]
struct WireLine {
    #[serde(rename = "type")]
    kind: Option<String>,
    cwd: Option<String>,
    message: Option<WireMessage>,
}

#[derive(Deserialize)]
struct WireMessage {
    model: Option<String>,
    usage: Option<WireUsage>,
    content: Option<WireContent>,
}

#[derive(Deserialize)]
struct WireUsage {
    input_tokens: Option<u64>,
    output_tokens: Option<u64>,
    cache_read_input_tokens: Option<u64>,
    cache_creation_input_tokens: Option<u64>,
    cache_creation: Option<WireCacheCreation>,
}

#[derive(Deserialize)]
struct WireCacheCreation {
    ephemeral_5m_input_tokens: Option<u64>,
    ephemeral_1h_input_tokens: Option<u64>,
}

/// `message.content` is either a raw string or an array of typed blocks.
#[derive(Deserialize)]
#[serde(untagged)]
enum WireContent {
    Text(String),
    Blocks(Vec<WireBlock>),
}

#[derive(Deserialize)]
struct WireBlock {
    #[serde(rename = "type")]
    kind: Option<String>,
    text: Option<String>,
}

impl WireContent {
    fn text(&self) -> String {
        match self {
            WireContent::Text(s) => s.clone(),
            WireContent::Blocks(blocks) => blocks
                .iter()
                .filter(|b| b.kind.as_deref() == Some("text"))
                .filter_map(|b| b.text.clone())
                .collect::<Vec<_>>()
                .join("\n"),
        }
    }
}

/// Read new bytes since last call and extract project + messages + usage. The
/// incremental cursor (offsets) and lock/rotation handling match the Mac
/// `JSONLParser.parseNew`.
pub fn parse_new(path: &Path, offsets: &mut HashMap<PathBuf, u64>) -> ParseResult {
    let mut result = ParseResult::default();

    let Some(mut file) = open_with_retry(path) else {
        return result;
    };
    let Ok(meta) = file.metadata() else {
        return result;
    };
    let len = meta.len();

    let mut start = offsets.get(path).copied().unwrap_or(0);
    if len < start {
        start = 0; // rotated/truncated
    }
    if file.seek(SeekFrom::Start(start)).is_err() {
        return result;
    }
    let mut buf = Vec::new();
    if file.read_to_end(&mut buf).is_err() {
        return result;
    }

    let Some(last_nl) = buf.iter().rposition(|&b| b == b'\n') else {
        return result;
    };
    offsets.insert(path.to_path_buf(), start + last_nl as u64 + 1);

    for line in buf[..=last_nl].split(|&b| b == b'\n') {
        if line.is_empty() {
            continue;
        }
        decode_line(line, &mut result);
    }
    result
}

fn decode_line(line: &[u8], result: &mut ParseResult) {
    let Ok(parsed) = serde_json::from_slice::<WireLine>(line) else {
        return;
    };

    if let Some(cwd) = &parsed.cwd {
        result.project = Some(project_from_cwd(cwd));
    }

    // Cost: assistant messages carry a usage block.
    if parsed.kind.as_deref() == Some("assistant") {
        if let Some(msg) = &parsed.message {
            if let Some(w) = &msg.usage {
                let cache5m = w
                    .cache_creation
                    .as_ref()
                    .and_then(|c| c.ephemeral_5m_input_tokens)
                    .or(w.cache_creation_input_tokens)
                    .unwrap_or(0);
                let cache1h = w
                    .cache_creation
                    .as_ref()
                    .and_then(|c| c.ephemeral_1h_input_tokens)
                    .unwrap_or(0);
                let usage = Usage {
                    input_tokens: w.input_tokens.unwrap_or(0),
                    output_tokens: w.output_tokens.unwrap_or(0),
                    cache_create_5m_tokens: cache5m,
                    cache_create_1h_tokens: cache1h,
                    cache_read_tokens: w.cache_read_input_tokens.unwrap_or(0),
                };
                result
                    .usages
                    .push((usage, Model::from_wire(msg.model.as_deref())));
            }
        }
    }

    // Message text: user or assistant lines with non-empty, sanitized text.
    let role = match parsed.kind.as_deref() {
        Some("user") => Some(Role::User),
        Some("assistant") => Some(Role::Assistant),
        _ => None,
    };
    if let (Some(role), Some(msg)) = (role, &parsed.message) {
        if let Some(content) = &msg.content {
            let trimmed = content.text();
            let trimmed = trimmed.trim();
            if let Some(text) = sanitize_user_content(trimmed) {
                if !text.is_empty() {
                    result.messages.push((role, text));
                }
            }
        }
    }
}

/// Surface slash-command invocations / stdout as readable text; drop the
/// `<local-command-caveat>` system block. Port of the Mac `sanitizeUserContent`.
fn sanitize_user_content(text: &str) -> Option<String> {
    if text.is_empty() {
        return None;
    }
    if text.starts_with("<local-command-caveat>") {
        return None;
    }
    if let Some(name) = extract_tag(text, "command-name") {
        let args = extract_tag(text, "command-args").unwrap_or_default();
        let args = args.trim();
        return Some(if args.is_empty() {
            name.trim().to_string()
        } else {
            format!("{} {}", name.trim(), args)
        });
    }
    if let Some(stdout) = extract_tag(text, "local-command-stdout") {
        let trimmed = stdout.trim();
        return if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        };
    }
    Some(text.to_string())
}

fn extract_tag(text: &str, tag: &str) -> Option<String> {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    let start = text.find(&open)? + open.len();
    let end = text[start..].find(&close)? + start;
    Some(text[start..end].to_string())
}

fn open_with_retry(path: &Path) -> Option<File> {
    for attempt in 0..3 {
        match File::open(path) {
            Ok(f) => return Some(f),
            Err(_) if attempt < 2 => std::thread::sleep(Duration::from_millis(20)),
            Err(_) => return None,
        }
    }
    None
}
