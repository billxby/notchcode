// Native settings.json hook installer — the Windows port of the Mac
// `install-hooks.sh` + `HookInstaller` (notchcode-plan.md §4.7, §11.3).
//
// The plan's call (§11.3): do the JSON merge natively in Rust rather than
// shipping a PowerShell script, sidestepping execution-policy friction
// entirely. Properties carried over from the bash installer:
//   - **Additive**: hooks from other tools are preserved.
//   - **Idempotent**: re-running first strips our old entries, then re-adds.
//   - **Identified**: every entry we own contains "127.0.0.1:9876"; that marker
//     is how we tell ours apart from anything else the user wired up.
//   - **Backed up**: a timestamped copy is written before any change.
//
// The hook command itself is unchanged from the Mac one-liner. Per §11.3,
// Claude Code on Windows runs hook commands through Git Bash, so `$PPID`,
// `curl`, and the `|| true` fire-and-forget all work as-is. (This is the top
// open risk to validate on a real install — see the milestone notes.)

use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

use crate::hooks::HOOK_PORT;

/// Loopback marker — the single identifier tying our entries to this app. Must
/// match what the hook server binds (`hooks::HOOK_PORT`).
const MARKER: &str = "127.0.0.1:9876";

/// The five lifecycle events we register, matching the hook server's routes.
const EVENTS: [&str; 5] = [
    "PreToolUse",
    "PostToolUse",
    "UserPromptSubmit",
    "PermissionRequest",
    "Stop",
];

/// `%USERPROFILE%\.claude\settings.json`.
fn settings_path() -> Option<PathBuf> {
    let home = std::env::var_os("USERPROFILE")?;
    Some(PathBuf::from(home).join(".claude").join("settings.json"))
}

/// The fire-and-forget curl one-liner for one event. Identical in spirit to the
/// Mac `cmd()`: 1s timeouts so Notchcode being down never blocks Claude Code,
/// `$PPID` forwarded as `X-Claude-PID` for per-session PID tracking (w0.7).
fn hook_command(event: &str) -> String {
    format!(
        "curl -s --max-time 1 --connect-timeout 1 -H \"X-Claude-PID: $PPID\" \
         -X POST --data-binary @- http://{MARKER}/hook/{event} 2>/dev/null || true"
    )
}

/// True if any hook command in settings.json carries our marker.
pub fn is_installed() -> bool {
    let Some(path) = settings_path() else {
        return false;
    };
    let Ok(text) = std::fs::read_to_string(&path) else {
        return false;
    };
    let Ok(cfg) = serde_json::from_str::<Value>(&text) else {
        return false;
    };
    cfg.get("hooks")
        .and_then(Value::as_object)
        .map(|hooks| hooks.values().any(group_list_contains_marker))
        .unwrap_or(false)
}

/// A matcher-group is "ours" iff it has commands and *every* command points at
/// our loopback marker. Mixed groups are left alone — better to under-remove
/// than nuke a user's unrelated hook (the Mac `is_ours` rule).
fn group_is_ours(group: &Value) -> bool {
    let Some(hooks) = group.get("hooks").and_then(Value::as_array) else {
        return false;
    };
    let commands: Vec<&str> = hooks
        .iter()
        .filter_map(|h| h.get("command").and_then(Value::as_str))
        .collect();
    !commands.is_empty() && commands.iter().all(|c| c.contains(MARKER))
}

fn group_list_contains_marker(groups: &Value) -> bool {
    groups
        .as_array()
        .map(|list| list.iter().any(group_is_ours))
        .unwrap_or(false)
}

/// Merge our hook entries into settings.json: back up, strip any prior entries
/// of ours, append fresh ones for each event. Additive and idempotent.
/// Returns a short human status string on success, or an error message.
pub fn install() -> Result<String, String> {
    let path = settings_path().ok_or("USERPROFILE not set")?;

    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("can't create {}: {e}", dir.display()))?;
    }

    // Load existing settings (or start from {}). Refuse to touch invalid JSON —
    // mirrors the bash installer's hard stop so we never clobber a hand-edited
    // file we can't safely round-trip.
    let mut cfg: Value = match std::fs::read_to_string(&path) {
        Ok(text) if !text.trim().is_empty() => serde_json::from_str(&text).map_err(|e| {
            format!(
                "{} is not valid JSON: {e}. Fix or remove it and retry.",
                path.display()
            )
        })?,
        _ => json!({}),
    };
    if !cfg.is_object() {
        return Err(format!("{} is not a JSON object.", path.display()));
    }

    // Timestamped backup before any write (only if the file already exists).
    if path.exists() {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let backup = path.with_extension(format!("json.notchcode-backup-{stamp}"));
        std::fs::copy(&path, &backup)
            .map_err(|e| format!("failed to write backup {}: {e}", backup.display()))?;
    }

    let hooks = cfg
        .as_object_mut()
        .unwrap()
        .entry("hooks")
        .or_insert_with(|| json!({}));
    let hooks = hooks
        .as_object_mut()
        .ok_or("`hooks` in settings.json is not an object")?;

    // Strip our prior entries from every event, dropping events left empty.
    for groups in hooks.values_mut() {
        if let Some(list) = groups.as_array_mut() {
            list.retain(|g| !group_is_ours(g));
        }
    }
    hooks.retain(|_, groups| !groups.as_array().map(|l| l.is_empty()).unwrap_or(false));

    // Append a fresh group per event.
    for event in EVENTS {
        let group = json!({
            "matcher": "*",
            "hooks": [{ "type": "command", "command": hook_command(event) }],
        });
        hooks
            .entry(event.to_string())
            .or_insert_with(|| json!([]))
            .as_array_mut()
            .ok_or_else(|| format!("`hooks.{event}` is not an array"))?
            .push(group);
    }

    // Pretty-print to stay diff-friendly with hand-edited settings.
    let serialized = serde_json::to_string_pretty(&cfg)
        .map_err(|e| format!("failed to serialize settings: {e}"))?;
    std::fs::write(&path, serialized + "\n")
        .map_err(|e| format!("failed to write {}: {e}", path.display()))?;

    Ok(format!(
        "Notchcode hooks installed on port {HOOK_PORT}: {}",
        EVENTS.join(", ")
    ))
}

/// Install hooks if they aren't already present. Run at startup so the overlay
/// can receive precise states without the user hunting for a button (there's no
/// settings UI until w0.6). Idempotent and backed up, so a no-op when already
/// wired. Logs the outcome; never panics the app over a settings.json problem.
pub fn ensure_installed() {
    if is_installed() {
        eprintln!("[notchcode] hooks already present in settings.json");
        return;
    }
    match install() {
        Ok(msg) => eprintln!("[notchcode] {msg}"),
        Err(e) => eprintln!("[notchcode] hook install skipped: {e}"),
    }
}
