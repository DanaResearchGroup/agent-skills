#!/usr/bin/env bash
# Claude Code status line: model name, token count, colour-coded context-window
# %, and git location (repo, branch, worktree, dirty flag).
# Reads the statusline JSON on stdin. Requires jq; git is optional (the
# location segment is omitted when git is absent or the dir is not a repo).
input=$(cat)

_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/lib/cc-statusline-lib.sh
[ -f "$_here/lib/cc-statusline-lib.sh" ] && . "$_here/lib/cc-statusline-lib.sh"

model=$(printf '%s' "$input" | jq -r '.model.display_name // "Claude"' | sed -E 's/ *\([^)]*\) *$//')
pct=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty')
dir=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // empty')
tpath=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
tok=$(printf '%s' "$input" | jq -r '
  if (.context_window.total_input_tokens // 0) >= 1000
  then ((.context_window.total_input_tokens / 1000) | tostring | split(".")
        | if .[1] then .[0] + "." + (.[1] | .[0:1]) else .[0] end) + "k"
  else (.context_window.total_input_tokens // 0 | tostring) end')

loc=''
command -v cc_location >/dev/null 2>&1 && loc=$(cc_location "$dir")

c_model='\033[0;36m' r='\033[0m'

# ---- prompt-cache TTL segment (hot / <30s countdown / cold) ----
# Claude's ephemeral prompt cache has a sliding TTL (default 5 min) refreshed on
# every API call. The newest transcript entry's timestamp is when we last hit the
# API, so elapsed-since-then vs the TTL tells us the cache state. Stateless: it's
# correct whenever the status line renders (override the window with CC_CACHE_TTL).
cache_seg=''
: "${CC_CACHE_TTL:=300}"
if [ -n "$tpath" ] && [ -f "$tpath" ]; then
  last_ts=$(tail -20 "$tpath" 2>/dev/null | jq -r 'select(.timestamp) | .timestamp' 2>/dev/null | tail -1)
  if [ -n "$last_ts" ]; then
    last_epoch=$(date -d "$last_ts" +%s 2>/dev/null)
    if [ -n "$last_epoch" ]; then
      remaining=$(( CC_CACHE_TTL - ( $(date +%s) - last_epoch ) ))
      if [ "$remaining" -gt 30 ]; then
        cache_seg=' \033[32mcache:hot\033[0m'          # green
      elif [ "$remaining" -gt 0 ]; then
        cache_seg=" \033[33mcache:${remaining}s\033[0m" # yellow countdown
      else
        cache_seg=' \033[90mcache:cold\033[0m'          # dim grey
      fi
    fi
  fi
fi

if [ -n "$pct" ]; then
  pct_fmt=$(printf '%s' "$pct" | awk '{printf "%.1f", $1}')
  color='\033[33m'
  command -v cc_ctx_color >/dev/null 2>&1 && color=$(cc_ctx_color "$pct")
  printf '%b%s%b %s %b(%s%%)%b%b%b' "$c_model" "$model" "$r" "$tok" "$color" "$pct_fmt" "$r" "$cache_seg" "$loc"
else
  printf '%b%s%b %s%b%b' "$c_model" "$model" "$r" "$tok" "$cache_seg" "$loc"
fi
