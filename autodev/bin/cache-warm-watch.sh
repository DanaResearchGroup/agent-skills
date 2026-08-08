#!/usr/bin/env bash
# Prompt-cache warmth badge. Launched (detached) by the Stop hook once per turn.
#
# WHY THIS EXISTS AS A SEPARATE PROCESS
# Claude Code invokes its statusLine command only on conversation updates —
# measured directly: across 120 s of idle it is not called once. So the status
# line cannot show anything that changes with wall-clock time; whatever it last
# printed is frozen there until the next turn. A cache countdown belongs on a
# surface that repaints on its own, and the multiplexer's tab bar is one. This
# watcher owns that surface; bin/lib/cc-statusline-lib.sh's cc_cache_seg owns the
# status-line half (an absolute deadline, which stays true however stale).
#
# WHAT IT DOES
# Appends a suffix to this session's herdr tab label as its prompt cache ages:
#   (nothing)   more than $CC_CACHE_WARN seconds of TTL left
#   " ⌛<n>s"   the final $CC_CACHE_WARN seconds
#   " •cold"    the TTL has lapsed
# and strips the suffix the moment a newer transcript entry proves a fresh API
# call refreshed the cache.
#
# SAFETY
#   - Global kill switch: ~/agents/state/disable-cache-badge. Checked at each
#     poll (so within $CC_CACHE_NAP_MAX), and it strips any badge on its way out.
#   - Never invents a label. It reads the tab's CURRENT label every time it acts
#     and only appends/strips its own suffix, so it cannot clobber a rename the
#     user made meanwhile, and a crashed watcher leaves nothing to restore from.
#   - Only ever touches the tab registered to THIS session id.
#   - Last writer wins: each turn's watcher publishes its pid as the owner, and
#     an older watcher exits without touching the label as soon as it sees it has
#     been superseded. Two watchers can never fight over one label.
#   - Gives up after $CC_CACHE_MAXLIFE, stripping the suffix, so an abandoned
#     session does not leave a badge on the tab bar forever.
#   - `--clear <sid>` strips the badge and exits. The status line calls it: a
#     status-line render only ever happens on a conversation update, so the fact
#     that it ran at all is proof the cache was just refreshed and the badge is
#     stale. Without inotify the watcher polls lazily once cold (there can be
#     dozens of idle sessions), so this is what makes a stale badge vanish on the
#     first render of a new turn instead of up to one poll interval later.
mode=""
if [ "$1" = "--clear" ]; then mode="clear"; shift; fi
sid="$1"
tpath="$2"
[ -n "$sid" ] || exit 0
# sid builds state-file paths; reject anything that could escape $STATE.
case "$sid" in */*|*..*) exit 0 ;; esac

: "${AUTODEV_HOME:=$HOME/agents}"; export AUTODEV_HOME
STATE="$AUTODEV_HOME/state"
mkdir -p "$STATE" 2>/dev/null

# The kill switch stops badging, but never stops UNbadging: --clear must still be
# able to tidy up a badge that was already on the tab when the switch was thrown.
[ -f "$STATE/disable-cache-badge" ] && [ "$mode" != clear ] && exit 0
[ "$mode" = clear ] || { [ -n "$tpath" ] && [ -f "$tpath" ] || exit 0; }

_HERE="$(cd "$(dirname "$0")" && pwd)"

# Multiplexer abstraction (herdr | tmux): mux_init/mux_tab_label/mux_tab_rename.
[ -f "$_HERE/mux-lib.sh" ] && . "$_HERE/mux-lib.sh"
command -v mux_init >/dev/null 2>&1 || exit 0

# The cache clock itself lives in the status-line lib, so this watcher and the
# status line can never disagree about when the cache lapses. CC_STATUSLINE_LIB
# is the test seam; the real path is the repo's shared lib.
_LIB="${CC_STATUSLINE_LIB:-$_HERE/../../bin/lib/cc-statusline-lib.sh}"
[ -f "$_LIB" ] && . "$_LIB"

TTL=${CC_CACHE_TTL:-300}          # sliding prompt-cache window, seconds
WARN=${CC_CACHE_WARN:-30}         # start the visible countdown this long before it lapses
MAXLIFE=${CC_CACHE_MAXLIFE:-7200} # stop badging an abandoned session after this long
NAPMAX=${CC_CACHE_NAP_MAX:-60}    # longest poll gap; overridable so tests run in seconds

mux_init "$sid" || exit 0
[ -n "${TAB:-}" ] || exit 0       # backend has no tab surface (or none registered)

strip_badge(){ printf '%s' "$1" | sed -E 's/ (⌛[0-9]+s|•cold)$//'; }

# Records the suffix currently on the tab, so the status line can tell in one
# stat(2) whether there is anything to clear — it must stay cheap on the path
# that runs on every single render.
BADGE="$STATE/$sid.cachewarm-badge"

# Reconcile the tab label to carry exactly the suffix in $1 ("" = none). Reads
# the live label first, so a tab the user renamed keeps its new name. Returns
# non-zero when the tab is gone, which is the caller's signal to stop.
set_badge(){ # $1 = suffix
  local cur base
  cur=$(mux_tab_label) || return 1
  [ -n "$cur" ] || return 1
  base=$(strip_badge "$cur")
  if [ -n "$1" ]; then printf '%s' "$1" > "$BADGE" 2>/dev/null
  else                 rm -f "$BADGE" 2>/dev/null
  fi
  [ "$base$1" = "$cur" ] && return 0
  mux_tab_rename "$base$1"
}

if [ "$mode" = clear ]; then set_badge ""; exit 0; fi

command -v cc_cache_epoch >/dev/null 2>&1 || exit 0

# Publish ownership. A watcher that finds someone else's pid here has been
# superseded by a later turn's watcher and must leave the label alone.
OWNER="$STATE/$sid.cachewarm-owner"
printf '%s\n' "$$" > "$OWNER.tmp" 2>/dev/null && mv "$OWNER.tmp" "$OWNER" 2>/dev/null
superseded(){ [ "$(cat "$OWNER" 2>/dev/null)" != "$$" ]; }

baseline=$(cc_cache_epoch "$tpath") || exit 0
applied="__unreconciled__"   # forces one reconcile pass, clearing a dead watcher's leftovers
start=$(date +%s)

while :; do
  superseded && exit 0

  if [ -f "$STATE/disable-cache-badge" ]; then
    [ "$applied" = "" ] || set_badge ""
    exit 0
  fi

  now=$(date +%s)
  if [ $(( now - start )) -ge "$MAXLIFE" ]; then
    set_badge ""
    exit 0
  fi

  epoch=$(cc_cache_epoch "$tpath") || epoch=""
  if [ -z "$epoch" ]; then sleep 5; continue; fi

  # A newer entry than we started with: an API call refreshed the cache. Clear
  # the badge and stand down — this turn's Stop hook will launch a fresh watcher.
  if [ "$epoch" -gt "$baseline" ]; then
    set_badge ""
    exit 0
  fi

  remaining=$(( TTL - ( now - epoch ) ))
  if   [ "$remaining" -gt "$WARN" ]; then want=""
  elif [ "$remaining" -gt 0 ];       then want=" ⌛${remaining}s"
  else                                    want=" •cold"
  fi

  if [ "$want" != "$applied" ]; then
    set_badge "$want" || exit 0    # tab closed
    applied="$want"
  fi

  # Sleep straight through to the warning window while there is nothing to show,
  # tick every second through the countdown, and idle once cold — by then the
  # only thing left to catch is the session waking up, and the status line beats
  # us to that anyway (--clear). One watcher per idle session polling every few
  # seconds would be real load on a machine with dozens of them open.
  if   [ "$remaining" -gt $(( WARN + 5 )) ]; then
    nap=$(( remaining - WARN )); [ "$nap" -gt "$NAPMAX" ] && nap="$NAPMAX"
  elif [ "$remaining" -gt 0 ]; then nap=1
  else                              nap="$NAPMAX"
  fi
  sleep "$nap"
done
