#!/usr/bin/env bash
# install-hooks.sh — register Notchcode hook entries for a coding agent.
#
# Usage: install-hooks.sh [claude|codex]   (defaults to claude)
#
#   claude → ~/.claude/settings.json   (hooks under the "hooks" key)
#   codex  → ~/.codex/hooks.json       (same {hooks:{Event:[…]}} shape)
#
# Additive : existing hooks from other tools are preserved.
# Idempotent: safe to re-run; old Notchcode entries (this agent's) are removed first.
# Identifier: every entry contains "127.0.0.1:9876". That marker is how this
#             script (and the uninstaller) tells our entries apart. The two
#             agents write to two different files, so installing one never
#             touches the other.
#
# Wire shape is fire-and-forget on a 1s timeout — Notchcode being down never
# blocks the agent.

set -euo pipefail

AGENT="${1:-claude}"
case "$AGENT" in
    claude) SETTINGS="${HOME}/.claude/settings.json"; MATCHER="*"  ;;
    codex)  SETTINGS="${HOME}/.codex/hooks.json";     MATCHER=".*" ;;  # Codex matchers are regexes
    *) echo "ERROR: unknown agent '$AGENT' (expected claude|codex)" >&2; exit 2 ;;
esac

PORT="9876"
MARKER="127.0.0.1:${PORT}"
SEGMENT="$AGENT"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${SETTINGS}.notchcode-backup-${STAMP}"

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"

cp "$SETTINGS" "$BACKUP"

python3 - "$SETTINGS" "$MARKER" "$SEGMENT" "$MATCHER" <<'PYEOF'
import json
import sys

settings_path, marker, segment, matcher = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

with open(settings_path, "r") as f:
    try:
        cfg = json.load(f)
    except json.JSONDecodeError as e:
        sys.stderr.write(f"ERROR: {settings_path} is not valid JSON: {e}\n")
        sys.stderr.write("Restore from the .notchcode-backup-* file and try again.\n")
        sys.exit(1)

cfg.setdefault("hooks", {})
hooks = cfg["hooks"]

# A matcher-group is "ours" if every command inside it points at our loopback
# port. Mixed groups (which shouldn't normally happen) are left alone — we'd
# rather under-remove than nuke a user's unrelated hook by accident.
def is_ours(group):
    commands = [h.get("command", "") for h in group.get("hooks", [])]
    return bool(commands) and all(marker in c for c in commands)

for event_name, groups in list(hooks.items()):
    if isinstance(groups, list):
        hooks[event_name] = [g for g in groups if not is_ours(g)]
        if not hooks[event_name]:
            del hooks[event_name]

def cmd(kind):
    # $PPID is the parent of the shell running this curl — i.e., the agent
    # process itself. Forwarding it as X-Notch-PID lets Notchcode track a
    # per-session PID, enabling per-session SIGTERM ("End session") and
    # per-session death detection instead of the global pgrep-all check.
    # The /<segment>/hook/ prefix tells the server which agent fired.
    return (
        "curl -s --max-time 1 --connect-timeout 1 "
        f"-H \"X-Notch-PID: $PPID\" "
        "-X POST --data-binary @- "
        f"http://{marker}/{segment}/hook/{kind} 2>/dev/null || true"
    )

events = ["PreToolUse", "PostToolUse", "UserPromptSubmit", "PermissionRequest", "Stop"]

for event in events:
    group = {
        "matcher": matcher,
        "hooks": [{"type": "command", "command": cmd(event)}],
    }
    hooks.setdefault(event, []).append(group)

with open(settings_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

print("Notchcode hooks installed: " + ", ".join(events))
PYEOF

echo "Backup written to: ${BACKUP}"
echo "Notchcode is now wired into ${SETTINGS} on port ${PORT} (agent: ${AGENT})."
