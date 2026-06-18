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
//   - **Crash-safe**: the live file is replaced via an atomic temp+rename, so a
//     crash mid-write can never leave a half-written settings.json.
//
// The hook command itself is unchanged from the Mac one-liner. Per §11.3,
// Claude Code on Windows runs hook commands through Git Bash, so `$PPID`,
// `curl`, and the `|| true` fire-and-forget all work as-is. (This is the top
// open risk to validate on a real install — see the milestone notes.)

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Map, Value};

use crate::agent::Agent;
use crate::hooks::HOOK_PORT;

/// Current-format marker — the distinctive subcommand every hook we install
/// carries. Identifies our entries regardless of the exe path (which varies by
/// install location). Must match the dispatch token in `main.rs`.
const HOOK_MARKER: &str = "__notch_hook";

/// Legacy marker from the original bash one-liner installs. We still recognize
/// it so re-running the installer *upgrades* those broken entries (strips them,
/// adds the shell-agnostic forwarder form) instead of leaving them stranded.
const LEGACY_MARKER: &str = "127.0.0.1:9876";

/// The five lifecycle events we register, matching the hook server's routes.
const EVENTS: [&str; 5] = [
    "PreToolUse",
    "PostToolUse",
    "UserPromptSubmit",
    "PermissionRequest",
    "Stop",
];

/// The agent's hook config file: `%USERPROFILE%\.claude\settings.json` or
/// `%USERPROFILE%\.codex\hooks.json`.
fn config_path(agent: Agent) -> Option<PathBuf> {
    agent.hook_config_file()
}

/// The hook command for one event: our own exe in forwarder mode, tagged with
/// the agent so the forwarder POSTs to `/<agent>/hook/<Event>`. Carries no shell
/// metacharacters — a bare quoted exe path + args runs identically under cmd.exe
/// and Git Bash. The forwarder reads stdin, resolves the agent PID natively, and
/// POSTs to the loopback server with a 1s budget (see `hooks::forward`).
///
/// The path is emitted with forward slashes: `CreateProcess` accepts them on
/// Windows, and they avoid the backslash-as-escape mangling that breaks a
/// `C:\...` path when the agent runs the hook through Git Bash.
fn hook_command(exe: &str, agent: Agent, event: &str) -> String {
    let exe = exe.replace('\\', "/");
    format!("\"{exe}\" {HOOK_MARKER} {} {event}", agent.segment())
}

/// A command string is one of ours iff it carries the current or legacy marker.
fn command_is_ours(cmd: &str) -> bool {
    cmd.contains(HOOK_MARKER) || cmd.contains(LEGACY_MARKER)
}

/// A command string is current-format (forwarder) iff it carries the current
/// marker. Legacy (bash one-liner) commands deliberately read as "not current"
/// so startup's `ensure_installed` upgrades them.
fn command_is_current(cmd: &str) -> bool {
    cmd.contains(HOOK_MARKER)
}

/// Every command string across all hook groups in a `hooks` object.
fn iter_commands(hooks: &Map<String, Value>) -> impl Iterator<Item = &str> {
    hooks
        .values()
        .filter_map(Value::as_array)
        .flatten()
        .filter_map(|group| group.get("hooks").and_then(Value::as_array))
        .flatten()
        .filter_map(|h| h.get("command").and_then(Value::as_str))
}

/// True if settings.json already carries our *current-format* hooks. Legacy
/// (bash one-liner) entries deliberately read as "not installed" so startup's
/// `ensure_installed` upgrades them to the forwarder form.
pub fn is_installed(agent: Agent) -> bool {
    let Some(path) = config_path(agent) else {
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
        .map(|hooks| iter_commands(hooks).any(command_is_current))
        .unwrap_or(false)
}

/// Strip only Notchcode's hook *commands* from a `hooks` object, in place.
///
/// Works at the command level rather than the group level: within each matcher
/// group we drop only the commands that are ours, and remove a group solely when
/// *we* emptied it. This makes uninstall the exact inverse of install and stops
/// a "mixed" group (one that pairs a Notchcode command with a foreign one) from
/// either being left stranded or causing a fresh group to be appended on every
/// startup. A foreign command sharing a group with ours is preserved untouched.
///
/// Returns whether any command of ours was actually removed (so callers can
/// no-op a write when there was nothing to strip).
fn strip_our_hooks(hooks: &mut Map<String, Value>) -> bool {
    let mut removed = false;
    for groups in hooks.values_mut() {
        let Some(list) = groups.as_array_mut() else {
            continue;
        };
        list.retain_mut(|group| {
            let Some(cmds) = group.get_mut("hooks").and_then(Value::as_array_mut) else {
                return true; // not a normal command group — leave it alone
            };
            let before = cmds.len();
            cmds.retain(|h| {
                !h.get("command")
                    .and_then(Value::as_str)
                    .map(command_is_ours)
                    .unwrap_or(false)
            });
            if cmds.len() != before {
                removed = true;
                // Drop the group only if our removal is what emptied it; never
                // delete a group a user authored.
                if cmds.is_empty() {
                    return false;
                }
            }
            true
        });
    }
    // Drop events whose group list is now empty (structural cleanup; does not
    // affect the `removed` signal, which tracks our-command removals only).
    hooks.retain(|_, groups| !groups.as_array().map(|l| l.is_empty()).unwrap_or(false));
    removed
}

/// Pure merge: strip our prior entries from `cfg`, then append a fresh group per
/// event. Operates on a parsed `Value` so it can be unit-tested without disk.
fn apply_install(cfg: &mut Value, exe: &str, agent: Agent) -> Result<(), String> {
    if !cfg.is_object() {
        return Err("settings.json is not a JSON object.".into());
    }
    let hooks = cfg
        .as_object_mut()
        .unwrap()
        .entry("hooks")
        .or_insert_with(|| json!({}));
    let hooks = hooks
        .as_object_mut()
        .ok_or("`hooks` in settings.json is not an object")?;

    strip_our_hooks(hooks);

    for event in EVENTS {
        let group = json!({
            "matcher": agent.matcher(),
            "hooks": [{ "type": "command", "command": hook_command(exe, agent, event) }],
        });
        hooks
            .entry(event.to_string())
            .or_insert_with(|| json!([]))
            .as_array_mut()
            .ok_or_else(|| format!("`hooks.{event}` is not an array"))?
            .push(group);
    }
    Ok(())
}

/// Pure removal: strip our entries from `cfg` and drop an emptied top-level
/// `hooks` object. Returns whether anything of ours was removed.
fn apply_uninstall(cfg: &mut Value) -> bool {
    let removed = match cfg.get_mut("hooks").and_then(Value::as_object_mut) {
        Some(hooks) => {
            let r = strip_our_hooks(hooks);
            if hooks.is_empty() {
                cfg.as_object_mut().unwrap().remove("hooks");
            }
            r
        }
        None => false,
    };
    removed
}

/// Crash-safe write: stage the bytes to a sibling temp file, fsync, then
/// atomically rename over the target. A crash mid-write leaves the original
/// settings.json intact (the rename is atomic on NTFS) rather than truncated.
fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let tmp = path.with_extension("json.notchcode-tmp");
    {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
    }
    match std::fs::rename(&tmp, path) {
        Ok(()) => Ok(()),
        Err(_) => {
            // Windows can refuse a rename-over-existing if the target is briefly
            // open by another handle; remove and retry once.
            let _ = std::fs::remove_file(path);
            std::fs::rename(&tmp, path)
        }
    }
}

/// Write a timestamped backup copy of `path` next to it. Best-effort surface for
/// the caller to bubble an error.
fn backup(path: &Path) -> Result<(), String> {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let dest = path.with_extension(format!("json.notchcode-backup-{stamp}"));
    std::fs::copy(path, &dest)
        .map(|_| ())
        .map_err(|e| format!("failed to write backup {}: {e}", dest.display()))
}

/// Merge our hook entries into settings.json: back up, strip any prior entries
/// of ours, append fresh ones for each event. Additive and idempotent.
/// Returns a short human status string on success, or an error message.
pub fn install(agent: Agent) -> Result<String, String> {
    let path = config_path(agent).ok_or("USERPROFILE not set")?;

    // The hook command invokes this very binary in forwarder mode, so resolve
    // its absolute path now and bake it into each entry.
    let exe = std::env::current_exe()
        .map_err(|e| format!("can't resolve own exe path: {e}"))?
        .to_string_lossy()
        .into_owned();

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
        backup(&path)?;
    }

    apply_install(&mut cfg, &exe, agent)?;

    // Pretty-print to stay diff-friendly with hand-edited settings.
    let serialized = serde_json::to_string_pretty(&cfg)
        .map_err(|e| format!("failed to serialize settings: {e}"))?;
    write_atomic(&path, (serialized + "\n").as_bytes())
        .map_err(|e| format!("failed to write {}: {e}", path.display()))?;

    Ok(format!(
        "Notchcode {} hooks installed on port {HOOK_PORT}: {}",
        agent.display_name(),
        EVENTS.join(", ")
    ))
}

/// Remove only our entries from settings.json, leaving everyone else's hooks
/// intact. A true no-op when nothing of ours is present: no backup is written
/// and the file is left byte-for-byte untouched (so we never reformat a
/// hand-edited config we had no reason to change).
pub fn uninstall(agent: Agent) -> Result<String, String> {
    let path = config_path(agent).ok_or("USERPROFILE not set")?;

    let Ok(text) = std::fs::read_to_string(&path) else {
        return Ok("No config file — nothing to remove.".into());
    };
    if text.trim().is_empty() {
        return Ok("Config file is empty — nothing to remove.".into());
    }
    let mut cfg: Value = serde_json::from_str(&text).map_err(|e| {
        format!(
            "{} is not valid JSON: {e}. Fix or remove it and retry.",
            path.display()
        )
    })?;

    if !apply_uninstall(&mut cfg) {
        return Ok(format!(
            "No Notchcode {} hooks present — nothing to remove.",
            agent.display_name()
        ));
    }

    // Only now that we know we're changing the file: back it up, then write.
    backup(&path)?;

    let serialized = serde_json::to_string_pretty(&cfg)
        .map_err(|e| format!("failed to serialize settings: {e}"))?;
    write_atomic(&path, (serialized + "\n").as_bytes())
        .map_err(|e| format!("failed to write {}: {e}", path.display()))?;

    Ok(format!("Notchcode {} hooks removed.", agent.display_name()))
}

/// Install hooks if they aren't already present. Run at startup so the overlay
/// can receive precise states without the user hunting for a button (there's no
/// settings UI until w0.6). Idempotent and backed up, so a no-op when already
/// wired. Logs the outcome; never panics the app over a settings.json problem.
/// Auto-install only Claude Code's hooks at startup (the primary agent). Codex
/// is opt-in from Settings — we don't write to a user's ~/.codex unprompted.
pub fn ensure_installed() {
    if is_installed(Agent::Claude) {
        eprintln!("[notchcode] Claude hooks already present in settings.json");
        return;
    }
    match install(Agent::Claude) {
        Ok(msg) => eprintln!("[notchcode] {msg}"),
        Err(e) => eprintln!("[notchcode] hook install skipped: {e}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn our_cmd(agent: Agent, event: &str) -> String {
        hook_command("C:/Program Files/app.exe", agent, event)
    }

    fn notch_group_count(cfg: &Value, event: &str) -> usize {
        cfg["hooks"][event]
            .as_array()
            .map(|groups| {
                groups
                    .iter()
                    .filter(|g| {
                        g["hooks"]
                            .as_array()
                            .map(|cmds| {
                                cmds.iter().any(|h| {
                                    h["command"]
                                        .as_str()
                                        .map(command_is_current)
                                        .unwrap_or(false)
                                })
                            })
                            .unwrap_or(false)
                    })
                    .count()
            })
            .unwrap_or(0)
    }

    #[test]
    fn install_twice_is_idempotent_and_preserves_foreign() {
        let mut cfg = json!({
            "hooks": {
                "PreToolUse": [
                    { "matcher": "*", "hooks": [{ "type": "command", "command": "my-foreign-tool --x" }] }
                ]
            }
        });
        apply_install(&mut cfg, "C:/Program Files/app.exe", Agent::Claude).unwrap();
        apply_install(&mut cfg, "C:/Program Files/app.exe", Agent::Claude).unwrap();

        // Foreign hook still there exactly once.
        let foreign = cfg["hooks"]["PreToolUse"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|g| g["hooks"][0]["command"] == "my-foreign-tool --x")
            .count();
        assert_eq!(foreign, 1, "foreign hook must be preserved");

        // Exactly one Notchcode group per event despite installing twice.
        for ev in EVENTS {
            assert_eq!(notch_group_count(&cfg, ev), 1, "one notch group for {ev}");
        }
    }

    #[test]
    fn strip_keeps_foreign_command_in_a_mixed_group() {
        let mut cfg = json!({
            "hooks": {
                "Stop": [
                    { "matcher": "*", "hooks": [
                        { "type": "command", "command": our_cmd(Agent::Claude, "Stop") },
                        { "type": "command", "command": "keep-me" }
                    ]}
                ]
            }
        });
        assert!(apply_uninstall(&mut cfg));
        let stop = cfg["hooks"]["Stop"].as_array().unwrap();
        assert_eq!(stop.len(), 1, "group survives because foreign command remains");
        let cmds = stop[0]["hooks"].as_array().unwrap();
        assert_eq!(cmds.len(), 1);
        assert_eq!(cmds[0]["command"], "keep-me");
    }

    #[test]
    fn uninstall_is_a_noop_when_nothing_is_ours() {
        let mut cfg = json!({
            "hooks": {
                "PreToolUse": [
                    { "matcher": "*", "hooks": [{ "type": "command", "command": "foreign" }] }
                ]
            }
        });
        let before = cfg.clone();
        assert!(!apply_uninstall(&mut cfg), "must report nothing removed");
        assert_eq!(cfg, before, "config must be left untouched");
    }

    #[test]
    fn install_then_uninstall_round_trips_to_clean() {
        let mut cfg = json!({});
        apply_install(&mut cfg, "C:/Program Files/app.exe", Agent::Claude).unwrap();
        assert!(apply_uninstall(&mut cfg));
        assert!(
            cfg.get("hooks").is_none(),
            "an emptied hooks object should be pruned entirely"
        );
    }

    #[test]
    fn legacy_marker_is_recognized_and_upgraded() {
        // A legacy bash one-liner entry (carries the loopback marker, not the
        // current __notch_hook token) must be stripped on reinstall.
        let mut cfg = json!({
            "hooks": {
                "Stop": [
                    { "matcher": "*", "hooks": [
                        { "type": "command", "command": "curl ... 127.0.0.1:9876/hook/Stop || true" }
                    ]}
                ]
            }
        });
        apply_install(&mut cfg, "C:/Program Files/app.exe", Agent::Claude).unwrap();
        assert_eq!(notch_group_count(&cfg, "Stop"), 1, "exactly one current group");
        // The legacy command is gone (no group still carries the bare loopback
        // marker without the current token).
        let lingering_legacy = cfg["hooks"]["Stop"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|g| g["hooks"].as_array().unwrap())
            .filter(|h| {
                let c = h["command"].as_str().unwrap();
                c.contains(LEGACY_MARKER) && !c.contains(HOOK_MARKER)
            })
            .count();
        assert_eq!(lingering_legacy, 0, "legacy entry upgraded away");
    }
}
