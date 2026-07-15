#!/usr/bin/env bash
# codex-spar-ctx.sh <codex-session-id> [slug]
# Persist the Codex context-window usage of a spar session so the status line can
# show it (autodev/bin/cc-statusline.sh reads the file). Called by the /spar skill
# after each round. Best-effort: any failure is silent.
#
# Writes $AUTODEV_HOME/state/codex-spar.<slug>.ctx:  pct=<n> used=<n> win=<n> ts=<epoch>
# The file is keyed by project slug so the badge reflects THIS repo's spar
# session, not whichever project sparred last. If the caller omits <slug> it is
# derived from the current directory (gstack-slug, falling back to the git
# toplevel basename) so the status line resolves the same key.
# Also echoes `pct=<n>` to stdout so callers can read this specific session's
# fresh fill % directly.
set -euo pipefail

sid=${1:-}
slug=${2:-}
[ -n "$sid" ] || exit 0

: "${AUTODEV_HOME:=$HOME/agents}"
state="$AUTODEV_HOME/state"
mkdir -p "$state" 2>/dev/null || exit 0

if [ -z "$slug" ]; then
  GS="$HOME/.claude/skills/gstack/bin/gstack-slug"
  [ -x "$GS" ] && slug=$( (eval "$("$GS" 2>/dev/null)" 2>/dev/null; printf '%s' "${SLUG:-}") )
  [ -z "$slug" ] && slug=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" | tr -cd 'a-zA-Z0-9._-')
fi
slug=$(printf '%s' "${slug:-unknown}" | tr -cd 'a-zA-Z0-9._-')

sessions="$HOME/.codex/sessions"
[ -d "$sessions" ] || exit 0

rollout=$(find "$sessions" -name "rollout-*-$sid.jsonl" 2>/dev/null | head -1)
[ -n "$rollout" ] || exit 0

py=$(command -v python3 2>/dev/null || command -v python 2>/dev/null) || exit 0

"$py" - "$rollout" "$state/codex-spar.$slug.ctx" <<'PY' || exit 0
import json, os, sys, time

rollout, out = sys.argv[1], sys.argv[2]
win = used = 0
with open(rollout) as f:
    for line in f:
        try:
            obj = json.loads(line)
        except Exception:
            continue
        payload = obj.get("payload", obj)
        if payload.get("type") == "token_count":
            info = payload.get("info") or {}
            win = info.get("model_context_window") or win
            last = info.get("last_token_usage") or {}
            used = last.get("input_tokens") or used

if not win:
    sys.exit(0)
pct = round(100 * used / win, 1)
tmp = out + ".tmp"
with open(tmp, "w") as f:
    f.write("pct=%s used=%s win=%s ts=%d\n" % (pct, used, win, int(time.time())))
os.replace(tmp, out)
# Also emit the fill % to stdout so callers (e.g. the /spar auto-handoff gate)
# can read THIS session's fresh value without trusting the shared global file.
print("pct=%s" % pct)
PY
