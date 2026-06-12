// File watcher + engine loop — Windows analog of the Mac ClaudeProjectsWatcher
// and CodexSessionsWatcher (notchcode-plan.md §0.2, §11.3). Watches both agents'
// transcript roots and routes each file to its parser (claude_jsonl /
// codex_rollout).
//
// `notify` (ReadDirectoryChangesW) and the hook server both feed one channel,
// consumed by a single loop that owns the per-file read cursors and drives the
// shared `SessionEngine`. The engine is shared (Arc<Mutex>) so Tauri commands
// (drill-down, lifecycle) can read/mutate it too; this loop is the only writer
// on the hot path.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use notify::{EventKind, RecursiveMode, Watcher};
use serde::Serialize;
use tauri::{AppHandle, Emitter};

use crate::agent::Agent;
use crate::claude_jsonl;
use crate::codex_rollout;
use crate::hooks::{self, HookEvent, HookKind};
use crate::sessions::{
    decode_project_slug, is_blocking_tool, SessionEngine, SessionInfo, Status, WaitingNotice,
};
use crate::winutil;

/// Event name the frontend listens on for state changes.
const STATE_EVENT: &str = "notch-state";

/// Loop tick — also the working→idle re-evaluation cadence.
const TICK: Duration = Duration::from_millis(500);

/// Run the PID liveness crash check every ~10s (this many ticks).
const CRASH_CHECK_TICKS: u32 = 20;

/// Shared engine handle stored in Tauri state and used by the loop + commands.
pub type SharedEngine = Arc<Mutex<SessionEngine>>;

/// What the frontend gets on every change: pill status + detail, the session
/// list, and weekly usage. Emitted only when it changes.
#[derive(Serialize, PartialEq, Clone)]
struct NotchState {
    status: Status,
    /// Agent driving a working aggregate, so the collapsed pill tints by agent.
    agent: Option<Agent>,
    detail: Option<String>,
    sessions: Vec<SessionInfo>,
    weekly_tokens: u64,
    weekly_dollars: f64,
    today_tokens: u64,
    dollars_today: f64,
}

/// Messages the engine loop consumes from both producers.
pub enum Msg {
    Fs(notify::Result<notify::Event>),
    Hook(HookEvent),
}

/// Spawn the watcher + hook server against a shared engine. Returns immediately.
pub fn start(app: AppHandle, engine: SharedEngine) {
    std::thread::spawn(move || run(app, engine));
}

fn run(app: AppHandle, engine: SharedEngine) {
    let claude_dir = Agent::Claude.transcript_root();
    let codex_dir = Agent::Codex.transcript_root();

    let (tx, rx) = channel::<Msg>();

    let fs_tx = tx.clone();
    let mut watcher = match notify::recommended_watcher(move |res| {
        let _ = fs_tx.send(Msg::Fs(res));
    }) {
        Ok(w) => w,
        Err(e) => {
            eprintln!("[notchcode] failed to create watcher: {e}. File watcher disabled.");
            // Still run the hook server below — live status works without
            // transcript tailing.
            hooks::start(tx);
            run_loop(app, engine, rx, HashMap::new());
            return;
        }
    };

    // Watch whichever agents' transcript dirs exist. A user may have only one
    // agent installed; the other dir simply isn't watched.
    for (label, dir) in [("Claude", &claude_dir), ("Codex", &codex_dir)] {
        if let Some(dir) = dir {
            if dir.exists() {
                if let Err(e) = watcher.watch(dir, RecursiveMode::Recursive) {
                    eprintln!("[notchcode] failed to watch {}: {e}.", dir.display());
                } else {
                    eprintln!("[notchcode] watching {}", dir.display());
                }
            } else {
                eprintln!(
                    "[notchcode] {} not found yet. Run {} once to create it.",
                    dir.display(),
                    label
                );
            }
        }
    }

    hooks::start(tx);

    let mut offsets: HashMap<PathBuf, u64> = HashMap::new();

    // Boot scan for each agent: surface pre-launch usage and currently-idle
    // sessions before the first live event arrives. Offset-guarded so the live
    // watcher resumes without re-counting.
    if let Some(dir) = &claude_dir {
        if dir.exists() {
            catch_up_claude(dir, &engine, &mut offsets);
        }
    }
    if let Some(dir) = &codex_dir {
        if dir.exists() {
            catch_up_codex(dir, &engine, &mut offsets);
        }
    }

    // Keep the watcher alive for the lifetime of the loop.
    let _watcher = watcher;
    run_loop(app, engine, rx, offsets);
}

/// The state-emitting event loop, factored out so `run` can also enter it on the
/// degraded path where the file watcher failed to construct.
fn run_loop(
    app: AppHandle,
    engine: SharedEngine,
    rx: std::sync::mpsc::Receiver<Msg>,
    mut offsets: HashMap<PathBuf, u64>,
) {
    let mut last_state: Option<NotchState> = None;
    let mut ticks: u32 = 0;

    loop {
        match rx.recv_timeout(TICK) {
            Ok(Msg::Fs(Ok(event))) => {
                handle_fs_event(event, &engine, &mut offsets);
            }
            Ok(Msg::Fs(Err(_))) => {}
            Ok(Msg::Hook(event)) => {
                // Capture the terminal HWND at hook-arrival time for the events
                // we may jump back to: the §0.5 waiting jump (PermissionRequest,
                // plus Codex's blocking tool calls that arrive as PreToolUse)
                // and the prompt-submit terminal record.
                let foreground = if matches!(
                    event.kind,
                    HookKind::PermissionRequest | HookKind::UserPromptSubmit
                ) || (event.kind == HookKind::PreToolUse
                    && event
                        .tool_name
                        .as_deref()
                        .map(is_blocking_tool)
                        .unwrap_or(false))
                {
                    winutil::foreground_window()
                } else {
                    None
                };
                // Lock released before notify/focus — never hold it across Win32.
                let notice = engine
                    .lock()
                    .ok()
                    .and_then(|mut e| e.handle_hook(&event, foreground));
                if let Some(notice) = notice {
                    notify_waiting(&app, &notice);
                }
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break,
        }

        ticks = ticks.wrapping_add(1);

        let state = {
            let Ok(mut e) = engine.lock() else {
                continue;
            };
            if ticks % CRASH_CHECK_TICKS == 0 {
                e.crash_check();
            }
            e.prune();
            NotchState {
                status: e.aggregate_status(),
                agent: e.aggregate_working_agent(),
                detail: e.aggregate_detail(),
                sessions: e.snapshot(),
                weekly_tokens: e.weekly_tokens(),
                weekly_dollars: e.weekly_dollars(),
                today_tokens: e.today_tokens(),
                dollars_today: e.dollars_today(),
            }
        };

        if Some(&state) != last_state.as_ref() {
            // Tray mirrors the pill, but only redraws on a *status* change —
            // not on every cost/runtime tick that also dirties the state.
            if last_state.as_ref().map(|s| s.status) != Some(state.status) {
                crate::tray::update(&app, state.status);
            }
            let _ = app.emit(STATE_EVENT, &state);
            last_state = Some(state);
        }
    }
}

/// Post a toast and (optionally) raise the terminal for a session that just
/// started waiting on the user. Reads the user's notify/focus toggles (both
/// default on). Runs off the engine lock. Toast click-to-focus isn't reliable
/// with the Windows toast plugin, so we auto-focus instead — which is also what
/// "Focus terminal automatically" asks for.
fn notify_waiting(app: &AppHandle, notice: &WaitingNotice) {
    use tauri::Manager;

    let (notify_on, focus_on) = app
        .try_state::<crate::settings::SharedSettings>()
        .and_then(|s| {
            s.lock()
                .ok()
                .map(|g| (g.notify_on_waiting, g.focus_terminal_on_waiting))
        })
        .unwrap_or((true, true));

    if notify_on {
        use tauri_plugin_notification::NotificationExt;
        let title = format!("{} needs your input", notice.agent.display_name());
        let body = match notice.detail.as_deref() {
            Some(d) if !d.is_empty() => format!("{} · {}", notice.project, d),
            _ if !notice.project.is_empty() => notice.project.clone(),
            _ => "Waiting for your approval".to_string(),
        };
        let _ = app.notification().builder().title(title).body(body).show();
    }

    if focus_on {
        // Same resolution order as the focus_terminal command: the precise
        // window hosting the agent PID, else the HWND captured at hook time.
        let target = notice
            .claude_pid
            .and_then(|p| winutil::session_window(p, &notice.project, notice.terminal_hwnd))
            .or(notice.terminal_hwnd);
        if let Some(hwnd) = target {
            winutil::focus_window(hwnd);
        }
    }
}

/// One-time boot scan of `~/.claude/projects` so usage + currently-idle
/// sessions from before launch are visible immediately — the Windows analog of
/// the Mac `ProjectsWatcher.catchUpWeek`. Parses every JSONL written in the last
/// 7 days, oldest first (so the rolling buffers stay chronological), seeding the
/// per-file read cursors to EOF so the live watcher resumes without re-counting.
fn catch_up_claude(dir: &Path, engine: &SharedEngine, offsets: &mut HashMap<PathBuf, u64>) {
    const WEEK: Duration = Duration::from_secs(7 * 24 * 60 * 60);
    let window_start = SystemTime::now().checked_sub(WEEK);

    let Ok(projects) = std::fs::read_dir(dir) else {
        return;
    };
    let mut recent: Vec<(PathBuf, String, SystemTime)> = Vec::new();
    for proj in projects.flatten() {
        let proj_path = proj.path();
        if !proj_path.is_dir() {
            continue;
        }
        let slug = proj_path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or_default()
            .to_string();
        let project = decode_project_slug(&slug);
        let Ok(files) = std::fs::read_dir(&proj_path) else {
            continue;
        };
        for f in files.flatten() {
            let path = f.path();
            if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                continue;
            }
            let mtime = f
                .metadata()
                .ok()
                .and_then(|m| m.modified().ok())
                .unwrap_or(SystemTime::UNIX_EPOCH);
            if window_start.map(|w| mtime >= w).unwrap_or(true) {
                recent.push((path, project.clone(), mtime));
            }
        }
    }
    // Chronological: weekly buffer stays front-oldest, messages read in order.
    recent.sort_by_key(|(_, _, mtime)| *mtime);

    for (path, slug_project, mtime) in recent {
        let Some(session_id) = path.file_stem().and_then(|s| s.to_str()).map(str::to_string) else {
            continue;
        };
        let result = claude_jsonl::parse_new(&path, offsets);
        let project = result.project.unwrap_or(slug_project);
        if let Ok(mut e) = engine.lock() {
            e.catch_up_file(
                Agent::Claude,
                &session_id,
                &project,
                mtime,
                result.messages,
                &result.usages,
                None, // Claude transcripts emit no lifecycle events.
            );
        }
    }
}

/// Boot scan of `~/.codex/sessions` — the Codex analog of `catch_up_claude`.
/// Walks the date dirs recursively for rollout-*.jsonl written in the last 7
/// days, oldest first, seeding cursors to EOF.
fn catch_up_codex(dir: &Path, engine: &SharedEngine, offsets: &mut HashMap<PathBuf, u64>) {
    const WEEK: Duration = Duration::from_secs(7 * 24 * 60 * 60);
    let window_start = SystemTime::now().checked_sub(WEEK);

    let mut recent: Vec<(PathBuf, SystemTime)> = Vec::new();
    collect_rollouts(dir, window_start, &mut recent);
    recent.sort_by_key(|(_, mtime)| *mtime);

    for (path, mtime) in recent {
        let Some(session_id) = codex_rollout::session_id_from_path(&path) else {
            continue;
        };
        let result = codex_rollout::parse_new(&path, offsets);
        let project = result.project.unwrap_or_default();
        // The tail boundary tells us if this rollout was mid-turn at launch.
        let last_lifecycle = result.lifecycle.last().copied();
        if let Ok(mut e) = engine.lock() {
            e.catch_up_file(
                Agent::Codex,
                &session_id,
                &project,
                mtime,
                result.messages,
                &result.usages,
                last_lifecycle,
            );
        }
    }
}

/// Recursively collect rollout-*.jsonl files newer than `window_start`.
fn collect_rollouts(dir: &Path, window_start: Option<SystemTime>, out: &mut Vec<(PathBuf, SystemTime)>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_rollouts(&path, window_start, out);
        } else if codex_rollout::is_rollout_file(&path) {
            let mtime = entry
                .metadata()
                .ok()
                .and_then(|m| m.modified().ok())
                .unwrap_or(SystemTime::UNIX_EPOCH);
            if window_start.map(|w| mtime >= w).unwrap_or(true) {
                out.push((path, mtime));
            }
        }
    }
}

/// Parse a JSONL create/modify into session activity, conversation, and usage.
fn handle_fs_event(
    event: notify::Event,
    engine: &SharedEngine,
    offsets: &mut HashMap<PathBuf, u64>,
) {
    if !matches!(event.kind, EventKind::Create(_) | EventKind::Modify(_)) {
        return;
    }

    for path in event.paths {
        if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
            continue;
        }

        // Route by layout: Codex rollout files vs Claude project JSONLs.
        if codex_rollout::is_rollout_file(&path) {
            let Some(session_id) = codex_rollout::session_id_from_path(&path) else {
                continue;
            };
            let result = codex_rollout::parse_new(&path, offsets);
            let project = result.project.unwrap_or_default();
            let Ok(mut e) = engine.lock() else {
                continue;
            };
            e.record_activity(Agent::Codex, &session_id, project.clone());
            for (role, text) in result.messages {
                e.record_message(Agent::Codex, &session_id, &project, role, text);
            }
            for (usage, model) in result.usages {
                e.record_usage(Agent::Codex, &session_id, &project, &usage, model);
            }
            // Turn boundaries drive Codex's running/idle status (its hooks
            // can't). Applied after activity so the latest boundary wins.
            for kind in result.lifecycle {
                e.record_lifecycle(Agent::Codex, &session_id, &project, kind);
            }
            continue;
        }

        let Some(session_id) = path.file_stem().and_then(|s| s.to_str()).map(str::to_string) else {
            continue;
        };
        let slug = path
            .parent()
            .and_then(|p| p.file_name())
            .and_then(|s| s.to_str())
            .unwrap_or_default();

        let result = claude_jsonl::parse_new(&path, offsets);
        let project = result.project.unwrap_or_else(|| decode_project_slug(slug));

        let Ok(mut e) = engine.lock() else {
            continue;
        };
        e.record_activity(Agent::Claude, &session_id, project.clone());
        for (role, text) in result.messages {
            e.record_message(Agent::Claude, &session_id, &project, role, text);
        }
        for (usage, model) in result.usages {
            e.record_usage(Agent::Claude, &session_id, &project, &usage, model);
        }
    }
}
