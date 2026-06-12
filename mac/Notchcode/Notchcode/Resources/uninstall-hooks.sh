#!/usr/bin/env bash
# uninstall-hooks.sh — remove Notchcode entries for a coding agent.
#
# Usage: uninstall-hooks.sh [claude|codex]   (defaults to claude)
#
# Mirrors install-hooks.sh's identification logic: a matcher-group is
# considered ours iff every command inside it contains "127.0.0.1:9876".
# Anything else is left untouched. Each agent has its own config file, so
# removing one agent's hooks never disturbs the other's.

set -euo pipefail

AGENT="${1:-claude}"
case "$AGENT" in
    claude) SETTINGS="${HOME}/.claude/settings.json" ;;
    codex)  SETTINGS="${HOME}/.codex/hooks.json"     ;;
    *) echo "ERROR: unknown agent '$AGENT' (expected claude|codex)" >&2; exit 2 ;;
esac

PORT="9876"
MARKER="127.0.0.1:${PORT}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${SETTINGS}.notchcode-backup-${STAMP}"

if [ ! -f "$SETTINGS" ]; then
    echo "Nothing to do — ${SETTINGS} doesn't exist."
    exit 0
fi

cp "$SETTINGS" "$BACKUP"

python3 - "$SETTINGS" "$MARKER" <<'PYEOF'
import json
import sys

settings_path, marker = sys.argv[1], sys.argv[2]

with open(settings_path, "r") as f:
    try:
        cfg = json.load(f)
    except json.JSONDecodeError as e:
        sys.stderr.write(f"ERROR: {settings_path} is not valid JSON: {e}\n")
        sys.exit(1)

hooks = cfg.get("hooks") or {}

def is_ours(group):
    commands = [h.get("command", "") for h in group.get("hooks", [])]
    return bool(commands) and all(marker in c for c in commands)

removed = 0
for event_name, groups in list(hooks.items()):
    if not isinstance(groups, list):
        continue
    before = len(groups)
    hooks[event_name] = [g for g in groups if not is_ours(g)]
    removed += before - len(hooks[event_name])
    if not hooks[event_name]:
        del hooks[event_name]

if not hooks and "hooks" in cfg:
    del cfg["hooks"]

with open(settings_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

print(f"Removed {removed} Notchcode hook entr{'y' if removed == 1 else 'ies'}.")
PYEOF

echo "Backup written to: ${BACKUP}"
