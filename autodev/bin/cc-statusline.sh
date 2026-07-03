#!/usr/bin/env bash
# Claude Code status line + context-signal writer for the auto-handoff watcher.
# Reads the statusline JSON on stdin, writes the live context % and tmux pane to
# ~/agents/state/<session>.{ctx,tmux-pane}, then prints the user's status line
# (output preserved byte-for-byte from the original inline statusLine command).
input=$(cat)
: "${AUTODEV_HOME:=$HOME/agents}"; export AUTODEV_HOME
STATE="$AUTODEV_HOME/state"
mkdir -p "$STATE" 2>/dev/null

sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
tpath=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
[ -z "$sid" ] && [ -n "$tpath" ] && sid=$(basename "$tpath" .jsonl)
pct=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty')

if [ -n "$sid" ]; then
  if [ -n "$pct" ]; then
    printf 'pct=%s ts=%s\n' "$pct" "$(date +%s)" > "$STATE/$sid.ctx.tmp" 2>/dev/null \
      && mv "$STATE/$sid.ctx.tmp" "$STATE/$sid.ctx" 2>/dev/null
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf '%s\n' "$TMUX_PANE" > "$STATE/$sid.tmux-pane.tmp" 2>/dev/null \
      && mv "$STATE/$sid.tmux-pane.tmp" "$STATE/$sid.tmux-pane" 2>/dev/null
  fi
fi

# ---- auto-handoff state badge (very visible; kill switch beats armed) ----
# Phoenix (session-limit auto-resume) takes over the badge while it is waiting to resume.
lw="$STATE/$sid.limit-wait"
if [ -n "$sid" ] && [ -f "$lw" ]; then
  lw_h=$(sed -n 's/.*human=\([^ ]*\).*/\1/p' "$lw" 2>/dev/null)
  badge="\033[1;5;97;45m ⏳ AUTO-RESUME @ ${lw_h:-reset} \033[0m"  # bold + blink, white on magenta
elif [ -f "$STATE/disable-auto-compact" ]; then
  badge="\033[1;97;100m ⛔ AUTO-HANDOFF: OFF \033[0m"        # bold white on grey
elif [ -f "$STATE/auto-handoff.armed" ]; then
  badge="\033[1;5;97;41m 🔴 AUTO-HANDOFF: ARMED \033[0m"     # bold + blink, white on red
else
  badge="\033[1;30;43m 🟡 AUTO-HANDOFF: DRY-RUN \033[0m"     # bold black on yellow
fi

# ---- original status line rendering (preserved verbatim in behavior) ----
model=$(printf '%s' "$input" | jq -r '.model.display_name // "Claude"' | sed -E 's/ *\([^)]*\) *$//')
tok_fmt=$(printf '%s' "$input" | jq -r 'if (.context_window.total_input_tokens // 0) >= 1000 then ((.context_window.total_input_tokens / 1000) | tostring | split(".") | if .[1] then .[0] + "." + (.[1] | .[0:1]) else .[0] end) + "k" else (.context_window.total_input_tokens // 0 | tostring) end')
if [ -n "$pct" ]; then
  pct_fmt=$(printf '%s' "$pct" | awk '{printf "%.1f", $1}')
  if awk "BEGIN{exit !($pct < 40)}"; then color="\033[32m"; else color="\033[31m"; fi
  printf "%b  %s %s %b(%s%%)\033[0m" "$badge" "$model" "$tok_fmt" "$color" "$pct_fmt"
else
  printf "%b  %s %s" "$badge" "$model" "$tok_fmt"
fi
