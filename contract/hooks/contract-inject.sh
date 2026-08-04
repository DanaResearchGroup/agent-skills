#!/usr/bin/env bash
# SessionStart hook: re-inject the active contract note so it survives
# context compaction / auto-handoff. Silent, exit 0, on every unexpected
# condition — this must never surface noise or block a session start.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONTRACT="$HERE/../bin/contract"
[ -x "$CONTRACT" ] || exit 0

note=$("$CONTRACT" show 2>/dev/null) || exit 0
[ -n "$note" ] || exit 0

# Build the JSON payload. Prefer python3 (json.dumps handles quotes,
# backslashes, tabs, and embedded newlines correctly); fall back to a
# sed/awk escape only if python3 is unavailable, and stay silent if
# neither path can produce valid JSON.
payload=$(printf '%s' "$note" | python3 -c '
import json, sys
note = sys.stdin.read()
ctx = "Active contract (re-injected after compaction):\n\n" + note
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": ctx}}, separators=(",", ":")))
' 2>/dev/null)

if [ -z "$payload" ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    # JSON strings forbid raw control characters. Strip every C0 control
    # byte except tab and newline (both escaped explicitly below) before
    # doing the backslash/quote/tab/newline escaping — otherwise a raw
    # \r (or other control byte) in the note produces invalid JSON.
    esc=$(printf '%s' "$note" \
      | tr -d '\000-\010\013-\037' \
      | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' \
      | awk 'BEGIN{ORS="\\n"}1')
    esc=${esc%\\n}
    if [ -n "$esc" ]; then
      payload=$(printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"Active contract (re-injected after compaction):\\n\\n%s"}}' "$esc")
    fi
  fi
fi

[ -n "$payload" ] || exit 0
printf '%s\n' "$payload"
exit 0
