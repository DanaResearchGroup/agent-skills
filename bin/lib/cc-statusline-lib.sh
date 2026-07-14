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
#   green    <25    comfortable
#   yellow   25..<40 watch it (the ~25% handoff nudge lives in this band)
#   bold red >=40   handoff territory
cc_ctx_color() {
  awk -v p="${1:-0}" 'BEGIN{
    if (p < 25)      printf "\033[32m";
    else if (p < 40) printf "\033[33m";
    else             printf "\033[1;31m";
  }'
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
