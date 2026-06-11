// File watcher + engine loop for ~/.claude/projects/ — Windows analog of the
// Mac `ProjectsWatcher` (notchcode-plan.md §0.2, §11.3).
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

use crate::hooks::{self, HookEvent, HookKind};
use crate::sessions::{
    decode_project_slug, parse_new, SessionEngine, SessionInfo, Status,
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

fn projects_dir() -> Option<PathBuf> {
    let home = std::env::var_os("USERPROFILE")?;
    Some(Path::new(&home).join(".claude").join("projects"))
}

fn run(app: AppHandle, engine: SharedEngine) {
    let dir = match projects_dir() {
        Some(d) => d,
        None => {
            eprintln!("[notchcode] USERPROFILE not set; file watcher disabled.");
            return;
        }
    };
    if !dir.exists() {
        eprintln!(
            "[notchcode] {} not found yet. Run Claude Code once to create it.",
            dir.display()
        );
        return;
    }

    let (tx, rx) = channel::<Msg>();

    let fs_tx = tx.clone();
    let mut watcher = match notify::recommended_watcher(move |res| {
        let _ = fs_tx.send(Msg::Fs(res));
    }) {
        Ok(w) => w,
        Err(e) => {
            eprintln!("[notchcode] failed to create watcher: {e}. File watcher disabled.");
            return;
        }
    };
    if let Err(e) = watcher.watch(&dir, RecursiveMode::Recursive) {
        eprintln!("[notchcode] failed to watch {}: {e}.", dir.display());
        return;
    }
    eprintln!("[notchcode] watching {}", dir.display());

    hooks::start(tx);

    let mut offsets: HashMap<PathBuf, u64> = HashMap::new();
    let mut last_state: Option<NotchState> = None;
    let mut ticks: u32 = 0;

    // Boot scan: surface pre-launch usage and currently-idle sessions before the
    // first live event arrives. Runs after the watch is established, so any write
    // during the scan is queued on the channel and reconciled against the same
    // cursors (offset-guarded `parse_new` — no double counting).
    catch_up(&dir, &engine, &mut offsets);

    loop {
        match rx.recv_timeout(TICK) {
            Ok(Msg::Fs(Ok(event))) => {
                handle_fs_event(event, &engine, &mut offsets);
            }
            Ok(Msg::Fs(Err(_))) => {}
            Ok(Msg::Hook(event)) => {
                // Capture the terminal HWND at hook-arrival time for the events
                // where we'll want to jump back to it (the §0.5 waiting jump).
                let foreground = if matches!(
                    event.kind,
                    HookKind::PermissionRequest | HookKind::UserPromptSubmit
                ) {
                    winutil::foreground_window()
                } else {
                    None
                };
                if let Ok(mut e) = engine.lock() {
                    e.handle_hook(&event, foreground);
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

/// One-time boot scan of `~/.claude/projects` so usage + currently-idle
/// sessions from before launch are visible immediately — the Windows analog of
/// the Mac `ProjectsWatcher.catchUpWeek`. Parses every JSONL written in the last
/// 7 days, oldest first (so the rolling buffers stay chronological), seeding the
/// per-file read cursors to EOF so the live watcher resumes without re-counting.
fn catch_up(dir: &Path, engine: &SharedEngine, offsets: &mut HashMap<PathBuf, u64>) {
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
        let result = parse_new(&path, offsets);
        let project = result.project.unwrap_or(slug_project);
        if let Ok(mut e) = engine.lock() {
            e.catch_up_file(&session_id, &project, mtime, result.messages, &result.usages);
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
        let Some(session_id) = path.file_stem().and_then(|s| s.to_str()).map(str::to_string) else {
            continue;
        };
        let slug = path
            .parent()
            .and_then(|p| p.file_name())
            .and_then(|s| s.to_str())
            .unwrap_or_default();

        let result = parse_new(&path, offsets);
        let project = result.project.unwrap_or_else(|| decode_project_slug(slug));

        let Ok(mut e) = engine.lock() else {
            continue;
        };
        e.record_activity(&session_id, project.clone());
        for (role, text) in result.messages {
            e.record_message(&session_id, &project, role, text);
        }
        for (usage, model) in result.usages {
            e.record_usage(&session_id, &project, &usage, model);
        }
    }
}
