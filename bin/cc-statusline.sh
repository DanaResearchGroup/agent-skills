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
tok=$(printf '%s' "$input" | jq -r '
  if (.context_window.total_input_tokens // 0) >= 1000
  then ((.context_window.total_input_tokens / 1000) | tostring | split(".")
        | if .[1] then .[0] + "." + (.[1] | .[0:1]) else .[0] end) + "k"
  else (.context_window.total_input_tokens // 0 | tostring) end')

loc=''
command -v cc_location >/dev/null 2>&1 && loc=$(cc_location "$dir")

c_model='\033[0;36m' r='\033[0m'

if [ -n "$pct" ]; then
  pct_fmt=$(printf '%s' "$pct" | awk '{printf "%.1f", $1}')
  color='\033[33m'
  command -v cc_ctx_color >/dev/null 2>&1 && color=$(cc_ctx_color "$pct")
  printf '%b%s%b %s %b(%s%%)%b%b' "$c_model" "$model" "$r" "$tok" "$color" "$pct_fmt" "$r" "$loc"
else
  printf '%b%s%b %s%b' "$c_model" "$model" "$r" "$tok" "$loc"
fi
