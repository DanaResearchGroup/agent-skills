#!/usr/bin/env bash
# limit-lib.sh — the usage-limit wait shared by session-resume-watch.sh (which
# writes it) and every reader that defers to it: auto-handoff-watch.sh,
# auto-handoff-sweep.sh, cc-stop-hook.sh and the status line.
#
# <sid>.limit-wait is one line, "until=<epoch> reset=<epoch> human=<h> ts=<epoch>":
#   until  when the resume watcher types "continue" (the reset plus its buffer);
#   ts     when the wait began.
# It is ACTIVE only while all hold:
#   - until is a number in the future;
#   - reset is a number: a file without it was written by the watcher before
#     it read only live banners, whose waits (up to a day, from scrollback
#     banners) cannot be trusted;
#   - no turn completed since ts (<sid>.idle, written by the Stop hook, is not
#     newer than ts): a completed turn means the session is working again.
# Any other file is STALE: readers ignore it, and autodev_limit_wait_active
# removes it under the session's resume lock, re-checking it there, so a fresh
# file a new resume cycle wrote in between is never removed. The resume watcher
# also ends the wait itself when the banner leaves the pane's live area.
#
# <sid>.resume.lock is a directory holding "pid": one resume cycle per session.
# A lock whose pid is dead is reclaimed, serialised by flock on
# <sid>.resume.reclaim. A lock with no pid is either a cycle between its mkdir
# and its pid write, or one taken by the earlier watcher, which wrote no pid and
# could wait up to 26 hours: it is reclaimed only after LIMIT_LOCK_GRACE.
#
# needs-owner.list holds one line per pane the resume watcher stopped typing
# into because a dialog it opened would not close:
#   <sid> TAB <tab label> TAB since=<date time> TAB key=<key> TAB screen=<what it shows>
# Written twice for the same session it stays one line (the first since= kept).
#
# Sourcing runs nothing and sets no shell options. Every path is used exactly as
# given: a leading "~" is NOT expanded, because the writer (the resume watcher)
# and the readers all build the state path the same way and must agree on it.

LIMIT_LOCK_GRACE=93600

_limit_path(){ printf '%s' "$1"; }   # one place to change if that ever must

_limit_num(){ case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# autodev_limit_wait_read <state> <sid>: sets LW_UNTIL LW_RESET LW_HUMAN LW_TS
# from the file (empty when absent or unreadable). 1 when there is no file.
autodev_limit_wait_read(){
  local f line kv
  f="$(_limit_path "$1")/$2.limit-wait"
  LW_UNTIL=""; LW_RESET=""; LW_HUMAN=""; LW_TS=""
  [ -f "$f" ] || return 1
  IFS= read -r line 2>/dev/null < "$f" || [ -n "$line" ] || return 0
  for kv in $line; do
    case "$kv" in
      until=*) LW_UNTIL=${kv#until=} ;;
      reset=*) LW_RESET=${kv#reset=} ;;
      human=*) LW_HUMAN=${kv#human=} ;;
      ts=*) LW_TS=${kv#ts=} ;;
    esac
  done
  return 0
}

# 0 when the values autodev_limit_wait_read set describe an active wait.
_limit_wait_values_active(){ # $1 state, $2 sid, $3 now
  local idle=0
  _limit_num "$LW_UNTIL" && [ "$LW_UNTIL" -gt "$3" ] || return 1
  _limit_num "$LW_RESET" || return 1
  _limit_num "$LW_TS" || LW_TS=0
  [ -f "$1/$2.idle" ] && idle=$(head -n1 "$1/$2.idle" 2>/dev/null)
  _limit_num "$idle" || idle=0
  [ "$idle" -le "$LW_TS" ]
}

# autodev_limit_wait_active <state> <sid> [--no-reap]: 0 while the session's
# usage-limit wait is active. A stale file is removed unless --no-reap (the
# status line only reads).
autodev_limit_wait_active(){
  local st sid=$2 now f
  st=$(_limit_path "$1"); f="$st/$sid.limit-wait"
  case "$sid" in ""|*[!A-Za-z0-9._-]*|.|..) return 1 ;; esac
  [ -e "$f" ] || [ -L "$f" ] || return 1
  now=$(date +%s)
  autodev_limit_wait_read "$st" "$sid"
  _limit_wait_values_active "$st" "$sid" "$now" && return 0
  [ "${3:-}" = --no-reap ] && return 1
  autodev_resume_lock_take "$st" "$sid" || return 1
  # Re-check under the lock: a resume cycle may have written a fresh wait
  # between the read above and the lock.
  autodev_limit_wait_read "$st" "$sid"
  if _limit_wait_values_active "$st" "$sid" "$(date +%s)"; then
    autodev_resume_lock_release "$st" "$sid"
    return 0
  fi
  rm -f "$f" 2>/dev/null
  LIMIT_WAIT_REAPED=1
  autodev_resume_lock_release "$st" "$sid"
  return 1
}

_limit_lock_dead(){ # $1 lock dir; 0 when its owner is provably gone
  local pid age
  if [ -f "$1/pid" ]; then
    pid=$(head -n1 "$1/pid" 2>/dev/null)
    _limit_num "$pid" || return 0
    kill -0 "$pid" 2>/dev/null && return 1
    [ -d "/proc/$pid" ] && return 1
    return 0
  fi
  age=$(( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || date +%s) ))
  [ "$age" -gt "$LIMIT_LOCK_GRACE" ]
}

# autodev_resume_lock_take <state> <sid> [pid]: 0 when this process now holds
# the session's resume lock.
autodev_resume_lock_take(){
  local st sid=$2 pid=${3:-${BASHPID:-$$}} lock
  st=$(_limit_path "$1"); lock="$st/$sid.resume.lock"
  if ! mkdir "$lock" 2>/dev/null; then
    [ -d "$lock" ] && _limit_lock_dead "$lock" || return 1
    if command -v flock >/dev/null 2>&1; then
      ( flock -w 5 9 || exit 1
        # Re-check under the flock: another reclaimer may have replaced it.
        _limit_lock_dead "$lock" || exit 1
        rm -rf "$lock" 2>/dev/null ) 9>"$st/$sid.resume.reclaim" || return 1
    else
      rm -rf "$lock" 2>/dev/null
    fi
    mkdir "$lock" 2>/dev/null || return 1
  fi
  printf '%s\n' "$pid" > "$lock/pid" 2>/dev/null
  return 0
}

autodev_resume_lock_release(){ # $1 state, $2 sid
  local lock
  lock="$(_limit_path "$1")/$2.resume.lock"
  rm -f "$lock/pid" 2>/dev/null
  rmdir "$lock" 2>/dev/null
  return 0
}

# --- needs-owner.list ----------------------------------------------------------
_limit_field(){ printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-200; }

_limit_list_edit(){ # $1 state, $2 sid, $3 new line ("" = remove); runs under flock
  local list="$1/needs-owner.list" tmp="$1/needs-owner.list.tmp.${BASHPID:-$$}"
  { if [ -f "$list" ]; then awk -F '\t' -v s="$2" '$1 != s' "$list"; fi
    if [ -n "$3" ]; then printf '%s\n' "$3"; fi
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$list" 2>/dev/null && return 0
  rm -f "$tmp" 2>/dev/null
  return 1
}

_limit_list_locked(){ # $1 state, then the command to run under the list lock
  local st=$1; shift
  if command -v flock >/dev/null 2>&1; then
    ( flock -w 5 9 || exit 1; "$@" ) 9>"$st/needs-owner.list.lock"
  else
    "$@"
  fi
}

# autodev_needs_owner_get <state> <sid>: print the session's line; 1 when none.
autodev_needs_owner_get(){
  local list
  list="$(_limit_path "$1")/needs-owner.list"
  [ -f "$list" ] || return 1
  awk -F '\t' -v s="$2" '$1 == s { print; f=1 } END { exit !f }' "$list" 2>/dev/null
}

# autodev_needs_owner_set <state> <sid> <label> <key> <screen>
autodev_needs_owner_set(){
  local st sid=$2 label key screen since="" old
  st=$(_limit_path "$1")
  case "$sid" in ""|*[!A-Za-z0-9._-]*|.|..) return 1 ;; esac
  label=$(_limit_field "$3"); key=$(_limit_field "$4"); screen=$(_limit_field "$5")
  [ -n "$label" ] || label="session ${sid:0:8}"
  _limit_list_locked "$st" _limit_needs_owner_set_locked "$st" "$sid" "$label" "$key" "$screen"
}
_limit_needs_owner_set_locked(){
  local old since
  old=$(autodev_needs_owner_get "$1" "$2")
  since=$(printf '%s\n' "$old" | tr '\t' '\n' | sed -n 's/^since=//p' | head -n1)
  [ -n "$since" ] || since=$(date +'%Y-%m-%d %H:%M:%S')
  _limit_list_edit "$1" "$2" "$(printf '%s\t%s\tsince=%s\tkey=%s\tscreen=%s' "$2" "$3" "$since" "$4" "$5")"
}

# autodev_needs_owner_clear <state> <sid>: drop the session's line, if any.
autodev_needs_owner_clear(){
  local st
  st=$(_limit_path "$1")
  autodev_needs_owner_get "$st" "$2" >/dev/null || return 0
  _limit_list_locked "$st" _limit_list_edit "$st" "$2" ""
}
