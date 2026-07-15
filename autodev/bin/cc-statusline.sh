#!/usr/bin/env bash
# Claude Code status line + context-signal writer for the auto-handoff watcher.
# Reads the statusline JSON on stdin, writes the live context % and tmux pane to
# ~/agents/state/<session>.{ctx,tmux-pane}, then prints the user's status line
# (output preserved byte-for-byte from the original inline statusLine command).
input=$(cat)
: "${AUTODEV_HOME:=$HOME/agents}"; export AUTODEV_HOME
STATE="$AUTODEV_HOME/state"
mkdir -p "$STATE" 2>/dev/null

# Multiplexer abstraction (herdr | tmux) for pane registration.
_MUXLIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mux-lib.sh"
[ -f "$_MUXLIB" ] && . "$_MUXLIB"

sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
tpath=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
[ -z "$sid" ] && [ -n "$tpath" ] && sid=$(basename "$tpath" .jsonl)
pct=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty')

if [ -n "$sid" ]; then
  if [ -n "$pct" ]; then
    printf 'pct=%s ts=%s\n' "$pct" "$(date +%s)" > "$STATE/$sid.ctx.tmp" 2>/dev/null \
      && mv "$STATE/$sid.ctx.tmp" "$STATE/$sid.ctx" 2>/dev/null
  fi
  # Register the backend pane (herdr and/or tmux) for the watchers.
  if command -v mux_register >/dev/null 2>&1; then
    mux_register "$sid"
  elif [ -n "${TMUX_PANE:-}" ]; then
    # Fallback if mux-lib.sh is missing: preserve the original tmux behavior.
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
# Location segment (repo / branch / worktree / dirty) + context colour via the
# shared lib, so this stays identical to the group bin/cc-statusline.sh.
# Degrades to the original 2-colour, no-location behaviour if the lib is absent.
_ccsl_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../bin/lib" 2>/dev/null && pwd)/cc-statusline-lib.sh"
loc=""
if [ -f "$_ccsl_lib" ]; then
  # shellcheck source=/dev/null
  . "$_ccsl_lib"
  dir=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // empty')
  loc=$(cc_location "$dir")
fi
# Autodev-run badge: lit only when THIS session is marked as an autodev run.
# autodev/SKILL.md touches "$STATE/$sid.autodev" at run start and clears it at
# the end, so it never bleeds into other concurrent sessions.
ad_badge=""
[ -n "$sid" ] && [ -f "$STATE/$sid.autodev" ] && ad_badge="\033[1;97;44m AUTODEV \033[0m "

# Codex spar context %: shown when a spar round wrote a fresh reading (< 30 min
# old) via autodev/bin/codex-spar-ctx.sh — i.e. the context fill of the Codex
# sparring session you're currently bouncing off. The reading is keyed by project
# slug, so resolve THIS repo's slug from the current dir (same key the writer
# uses) and read only that file — the badge never bleeds across projects.
spar_badge=""
_sp_dir=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // empty')
_sp_slug=""
if [ -n "$_sp_dir" ]; then
  _GS="$HOME/.claude/skills/gstack/bin/gstack-slug"
  [ -x "$_GS" ] && _sp_slug=$( (cd "$_sp_dir" 2>/dev/null && eval "$("$_GS" 2>/dev/null)" 2>/dev/null; printf '%s' "${SLUG:-}") )
  [ -z "$_sp_slug" ] && _sp_slug=$(cd "$_sp_dir" 2>/dev/null && basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" | tr -cd 'a-zA-Z0-9._-')
fi
_sp_slug=$(printf '%s' "$_sp_slug" | tr -cd 'a-zA-Z0-9._-')
_scf="$STATE/codex-spar.$_sp_slug.ctx"
if [ -n "$_sp_slug" ] && [ -f "$_scf" ]; then
  _sp_pct=$(sed -n 's/^pct=\([0-9.]*\).*/\1/p' "$_scf")
  _sp_ts=$(sed -n 's/.*ts=\([0-9]*\).*/\1/p' "$_scf")
  if [ -n "$_sp_pct" ] && [ -n "$_sp_ts" ] && [ "$(( $(date +%s) - _sp_ts ))" -lt 1800 ]; then
    spar_badge=" \033[35mspar:${_sp_pct}%\033[0m"
  fi
fi

if [ -n "$pct" ]; then
  pct_fmt=$(printf '%s' "$pct" | awk '{printf "%.1f", $1}')
  if command -v cc_ctx_color >/dev/null 2>&1; then
    color=$(cc_ctx_color "$pct")
  elif awk "BEGIN{exit !($pct < 40)}"; then
    color="\033[32m"
  else
    color="\033[31m"
  fi
  printf "%b%b  %s %s %b(%s%%)\033[0m%b%b" "$badge" "$ad_badge" "$model" "$tok_fmt" "$color" "$pct_fmt" "$loc" "$spar_badge"
else
  printf "%b%b  %s %s%b%b" "$badge" "$ad_badge" "$model" "$tok_fmt" "$loc" "$spar_badge"
fi
