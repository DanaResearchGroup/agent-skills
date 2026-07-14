#!/usr/bin/env bash
# Claude Code Stop hook: fires when an assistant turn fully completes.
# Marks the session idle and launches the (detached) auto-handoff watcher.
# Prints nothing (Stop hook stdout is not needed) and never blocks CC.
input=$(cat)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${AUTODEV_HOME:=$HOME/agents}"; export AUTODEV_HOME
STATE="$AUTODEV_HOME/state"
mkdir -p "$STATE" 2>/dev/null

# Multiplexer abstraction (herdr | tmux) for pane registration.
[ -f "$HERE/mux-lib.sh" ] && . "$HERE/mux-lib.sh"

sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
tpath=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
[ -z "$sid" ] && [ -n "$tpath" ] && sid=$(basename "$tpath" .jsonl)
[ -z "$sid" ] && exit 0

printf '%s\n' "$(date +%s)" > "$STATE/$sid.idle" 2>/dev/null
# Redundant pane capture (Stop hook inherits CC's herdr/tmux env).
if command -v mux_register >/dev/null 2>&1; then
  mux_register "$sid"
elif [ -n "${TMUX_PANE:-}" ]; then
  printf '%s\n' "$TMUX_PANE" > "$STATE/$sid.tmux-pane" 2>/dev/null
fi

# Launch the watchers fully detached so they survive this hook returning and can
# poll for later turns. Each self-gates (threshold, lock, cooldown, arm).
#  - auto-handoff-watch: context-% threshold -> handoff/compact/reload.
#  - session-resume-watch (Phoenix): usage/session-limit banner -> usage-credits or
#    wait-for-reset -> continue.
setsid "$HERE/auto-handoff-watch.sh" "$sid" </dev/null >/dev/null 2>&1 &
setsid "$HERE/session-resume-watch.sh" "$sid" </dev/null >/dev/null 2>&1 &
exit 0
