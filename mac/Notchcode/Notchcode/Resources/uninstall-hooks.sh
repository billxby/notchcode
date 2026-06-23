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

python3 - "$SETTINGS" "$MARKER" "$BACKUP" <<'PYEOF'
import json
import os
import sys
import tempfile

settings_path, marker, backup_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(settings_path, "r") as f:
    original = f.read()

try:
    cfg = json.loads(original)
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

# True no-op when nothing of ours is present: don't back up and don't rewrite a
# hand-edited config (which would reformat/normalize it for no reason).
if removed == 0:
    print("Nothing to remove — no Notchcode hooks present.")
    sys.exit(0)

if not hooks and "hooks" in cfg:
    del cfg["hooks"]


def write_atomic(path, text):
    # temp file in the same dir, fsync, atomic rename — never truncate the
    # user's config mid-write.
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".notchcode-tmp-")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# We're about to modify the file — back up the original first, then swap.
with open(backup_path, "w") as f:
    f.write(original)
write_atomic(settings_path, json.dumps(cfg, indent=2) + "\n")

print(f"Removed {removed} Notchcode hook entr{'y' if removed == 1 else 'ies'}.")
print(f"Backup written to: {backup_path}")
PYEOF
