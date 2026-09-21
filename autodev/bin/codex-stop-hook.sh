#!/usr/bin/env bash
# Codex Stop hook: persist the effective context fill and launch the shared
# auto-handoff watcher at a genuine idle turn boundary.
input=$(cat)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${AUTODEV_HOME:=$HOME/agents}"; export AUTODEV_HOME
STATE="$AUTODEV_HOME/state"
mkdir -p "$STATE" 2>/dev/null

[ -f "$HERE/mux-lib.sh" ] && . "$HERE/mux-lib.sh"

sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
tpath=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
[ -z "$sid" ] && [ -n "$tpath" ] && sid=$(basename "$tpath" .jsonl)
[ -z "$sid" ] && exit 0
case "$sid" in ""|*[!A-Za-z0-9._-]*) exit 0 ;; esac

# Codex's cumulative total_token_usage is the lifetime cost of the thread, not
# the active context. The TUI's effective context gauge is based on the newest
# token_count event's last_token_usage against model_context_window; record that
# same percentage so the 35% watcher threshold has the meaning the user sees.
if [ -n "$tpath" ] && [ -f "$tpath" ]; then
  if command -v tac >/dev/null 2>&1; then
    # A long Codex thread can be hundreds of MB. Read backwards and stop at the
    # first token event instead of rescanning the whole transcript every turn.
    token_line=$(tac "$tpath" 2>/dev/null | awk '
      index($0, "\"type\":\"event_msg\"") && index($0, "\"type\":\"token_count\"") { print; exit }
    ')
  else
    token_line=$(awk '
      index($0, "\"type\":\"event_msg\"") && index($0, "\"type\":\"token_count\"") { latest=$0 }
      END { if (latest != "") print latest }
    ' "$tpath" 2>/dev/null)
  fi
  if [ -n "$token_line" ]; then
    usage=$(printf '%s\n' "$token_line" | jq -r '
      .payload.info as $i
      | (($i.last_token_usage.total_tokens
          // (($i.last_token_usage.input_tokens // 0) + ($i.last_token_usage.output_tokens // 0)))) as $used
      | ($i.model_context_window // 0) as $window
      | if (($used | type) == "number" and ($window | type) == "number" and $window > 0)
        then "\($used) \($window)" else empty end
    ' 2>/dev/null)
    if [ -n "$usage" ]; then
      read -r used window <<EOF
$usage
EOF
      pct=$(awk -v used="$used" -v window="$window" 'BEGIN { printf "%.2f", used * 100 / window }')
      tmp="$STATE/$sid.ctx.tmp.$$"
      printf 'pct=%s used=%s win=%s ts=%s\n' "$pct" "$used" "$window" "$(date +%s)" > "$tmp" 2>/dev/null \
        && mv "$tmp" "$STATE/$sid.ctx" 2>/dev/null
    fi
  fi
fi

printf 'codex\n' > "$STATE/$sid.runtime.tmp.$$" 2>/dev/null \
  && mv "$STATE/$sid.runtime.tmp.$$" "$STATE/$sid.runtime" 2>/dev/null
printf '%s\n' "$(date +%s)" > "$STATE/$sid.idle" 2>/dev/null

if command -v mux_register >/dev/null 2>&1; then
  mux_register "$sid"
elif [ -n "${TMUX_PANE:-}" ]; then
  printf '%s\n' "$TMUX_PANE" > "$STATE/$sid.tmux-pane" 2>/dev/null
fi

# Test seam: context and identity behavior can be exercised without detaching a
# process that races the fixture teardown.
[ "${AUTODEV_NO_WATCHERS:-0}" = 1 ] && exit 0
setsid "$HERE/auto-handoff-watch.sh" "$sid" </dev/null >/dev/null 2>&1 &
exit 0
