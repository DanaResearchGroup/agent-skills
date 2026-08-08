#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers for the Claude Code status line, used by both the group
# script (bin/cc-statusline.sh) and the PI's auto-handoff variant
# (autodev/bin/cc-statusline.sh) so the two never drift.
#
# Pure functions: sourcing this file has no side effects. Depends on awk
# (always present) and git (optional — the location segment is simply omitted
# when git is absent or the directory is not a work tree).

# cc_ctx_color <pct> -> prints the ANSI colour escape for a context-usage %.
#   green    <35    comfortable
#   yellow   35..<40 watch it (the ~35% handoff nudge lives in this band)
#   bold red >=40   handoff territory
cc_ctx_color() {
  awk -v p="${1:-0}" 'BEGIN{
    if (p < 35)      printf "\033[32m";
    else if (p < 40) printf "\033[33m";
    else             printf "\033[1;31m";
  }'
}

# cc_cache_seg <transcript_path> -> prints the prompt-cache segment, or nothing
# when the transcript is missing/unreadable.
#
# Claude's ephemeral prompt cache has a sliding TTL (default 5 min, override with
# CC_CACHE_TTL) refreshed on every API call, so the newest transcript timestamp
# plus the TTL is the wall-clock moment the cache lapses.
#
# This prints that DEADLINE rather than a hot/cold state, deliberately: Claude
# Code invokes the statusLine command only on conversation updates — measured, it
# is not called once across 120 s of idle — so whatever this returns is frozen on
# screen until the next turn. A decaying state ("hot", "12s") becomes a lie the
# moment it stops being redrawn, and the countdown and expiry states could never
# appear while idle, which is the only time they carry information. An absolute
# clock time stays true however stale the render is. The colour is fixed for the
# same reason: one derived from remaining-at-render-time would freeze and lie
# exactly like the text did.
#
# The live countdown lives where it can actually redraw — autodev/bin/
# cache-warm-watch.sh puts it in the herdr tab label, which herdr repaints on its
# own cadence while Claude Code sits idle.
cc_cache_seg() {
  local last_epoch when
  last_epoch=$(cc_cache_epoch "${1:-}") || return 0
  [ -n "$last_epoch" ] || return 0
  when=$(date -d "@$(( last_epoch + ${CC_CACHE_TTL:-300} ))" +%H:%M:%S 2>/dev/null) || return 0
  [ -n "$when" ] || return 0
  printf '%b' " \033[2;36mcache⌛${when}\033[0m"
}

# cc_cache_epoch <transcript_path> -> prints the epoch seconds of the newest
# transcript entry that represents an API call on THIS session's prompt prefix,
# i.e. the moment the prompt cache was last refreshed. Prints nothing and
# returns non-zero when that cannot be determined.
#
# Shared by cc_cache_seg (which turns it into a deadline) and by
# autodev/bin/cache-warm-watch.sh (which turns it into a live countdown), so the
# two halves of the cache badge can never disagree about when the cache lapses.
cc_cache_epoch() {
  local tpath=${1:-} last_ts
  [ -n "$tpath" ] && [ -f "$tpath" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  # -R + fromjson? tolerates a half-written trailing line while CC is appending.
  # isSidechain entries are subagent turns: they ride a different prompt prefix
  # and so do not refresh THIS session's cache — they must not read as activity.
  last_ts=$(tail -20 "$tpath" 2>/dev/null \
    | jq -rR 'fromjson? | select(.timestamp and (.isSidechain != true)) | .timestamp' 2>/dev/null \
    | tail -1)
  [ -n "$last_ts" ] || return 1
  date -d "$last_ts" +%s 2>/dev/null
}

# cc_location <dir> -> prints "  repo@branch[*] [marker]" (ANSI-coloured), or
# nothing when <dir> is empty, git is absent, or <dir> is not in a work tree.
#   repo       cyan    main repo name — stable across worktrees
#   @branch    yellow  current branch (short SHA if detached)
#   *          red     working tree has uncommitted changes
#   [wt:name]  magenta you are in a linked worktree (the group default)
#   [primary]  dim     you are in the primary checkout, clean
#   [!primary] red     you are editing the primary checkout (dirty) — the
#                      anti-pattern the group's "work in a worktree" rule warns
#                      against, so it is flagged loudly.
cc_location() {
  local dir=${1:-}
  [ -n "$dir" ] || return 0
  command -v git >/dev/null 2>&1 || return 0

  local top
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 0
  [ -n "$top" ] || return 0

  local branch
  branch=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null) \
    || branch=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null) \
    || branch='?'

  local dirty=''
  [ -n "$(git -C "$dir" status --porcelain 2>/dev/null | head -n1)" ] && dirty='*'

  local gitdir
  gitdir=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) \
    || gitdir=$(git -C "$dir" rev-parse --git-dir 2>/dev/null)

  local repo wt=''
  case "$gitdir" in
    */worktrees/*)
      # A linked worktree: git-dir is <mainrepo>/.git/worktrees/<name>.
      repo=$(basename "$(dirname "${gitdir%%/worktrees/*}")")
      wt=$(basename "$top")
      ;;
    *)
      repo=$(basename "$top")
      ;;
  esac

  local c_repo='\033[36m' c_br='\033[33m' c_dirty='\033[31m'
  local c_wt='\033[35m' c_pri='\033[2m' c_warn='\033[1;31m' r='\033[0m'

  local marker
  if [ -n "$wt" ]; then
    marker="${c_wt}[wt:${wt}]${r}"
  elif [ -n "$dirty" ]; then
    marker="${c_warn}[!primary]${r}"
  else
    marker="${c_pri}[primary]${r}"
  fi

  printf '%b' "  ${c_repo}${repo}${r}@${c_br}${branch}${r}${c_dirty}${dirty}${r} ${marker}"
}
