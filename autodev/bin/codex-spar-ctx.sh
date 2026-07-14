#!/usr/bin/env bash
# codex-spar-ctx.sh <codex-session-id>
# Persist the Codex context-window usage of a spar session so the PI's status
# line can show it (bin/../autodev/bin/cc-statusline.sh reads the file). Called
# by the /spar skill after each round. Best-effort: any failure is silent.
#
# Writes $AUTODEV_HOME/state/codex-spar.ctx:  pct=<n> used=<n> win=<n> ts=<epoch>
set -euo pipefail

sid=${1:-}
[ -n "$sid" ] || exit 0

: "${AUTODEV_HOME:=$HOME/agents}"
state="$AUTODEV_HOME/state"
mkdir -p "$state" 2>/dev/null || exit 0

sessions="$HOME/.codex/sessions"
[ -d "$sessions" ] || exit 0

rollout=$(find "$sessions" -name "rollout-*-$sid.jsonl" 2>/dev/null | head -1)
[ -n "$rollout" ] || exit 0

py=$(command -v python3 2>/dev/null || command -v python 2>/dev/null) || exit 0

"$py" - "$rollout" "$state/codex-spar.ctx" <<'PY' || exit 0
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
PY
