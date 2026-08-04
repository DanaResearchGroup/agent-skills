#!/usr/bin/env bash
# PreToolUse gate: deny Edit/Write/NotebookEdit in a worktree that has
# contract enabled but no active contract and no session skip. Fails
# OPEN on every unexpected condition — this must never block exploration.
set -uo pipefail

allow() { exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
CONTRACT="$(cd "$HERE/.." && pwd)/bin/contract"
[ -x "$CONTRACT" ] || allow

payload=$(cat) || allow
[ -n "$payload" ] || allow

# Pull a string field out of the hook's JSON payload without depending on jq.
# Prefer python3 (handles escaped quotes correctly); fall back to a sed-based
# extraction, which is best-effort and can be fooled by embedded \" bytes.
field() {
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
key = sys.argv[1]
val = d.get(key)
if val is None:
    ti = d.get("tool_input")
    if isinstance(ti, dict):
        val = ti.get(key)
if isinstance(val, str):
    sys.stdout.write(val)
' "$1"
    return 0
  fi
  printf '%s' "$payload" \
    | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
    | head -n 1
}

tool=$(field tool_name)
case "$tool" in
  Edit|Write|NotebookEdit) ;;
  *) allow ;;
esac

sid=$(field session_id)
path=$(field file_path)
[ -n "$path" ] || allow

# Walk up to the nearest EXISTING ancestor: a Write that creates a new file
# in a not-yet-existing directory (a fresh module) must still be gated by the
# worktree that directory will land in. Fail open only if no existing
# ancestor is inside a git worktree at all (resolved via `contract status`).
dir=$(dirname "$path")
while [ ! -d "$dir" ]; do
  parent=$(dirname "$dir")
  [ "$parent" != "$dir" ] || break
  dir="$parent"
done
[ -d "$dir" ] || allow

status=$(cd "$dir" 2>/dev/null && "$CONTRACT" status 2>/dev/null) || allow
[ -n "$status" ] || allow

enabled=$(printf '%s\n' "$status" | sed -n 's/^enabled=//p')
active=$(printf '%s\n' "$status" | sed -n 's/^active=//p')

[ "$enabled" = "yes" ] || allow
[ "$active" = "none" ] || allow

if [ -n "$sid" ] && (cd "$dir" 2>/dev/null && "$CONTRACT" skipped "$sid" 2>/dev/null); then
  allow
fi

sid_arg=${sid:-'<session_id>'}
reason="This worktree has contract enabled and no active contract for this change.
Before editing, open one: \`$CONTRACT new <slug>\` — states Intent / Verifier / Non-goals / Gates.
For a one-line or trivial change instead: \`$CONTRACT skip $sid_arg \"<reason>\"\` — the skip is logged, not silent."

esc=$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN{ORS="\\n"}1')
esc=${esc%\\n}
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$esc"
exit 0
