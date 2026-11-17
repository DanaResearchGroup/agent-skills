#!/usr/bin/env bash
# Phoenix — session-limit auto-resume watcher.
# Sibling of auto-handoff-watch.sh, launched (detached) by the same Stop hook once per turn.
# Purpose: when a CC turn ends because the *usage/session limit* was hit (a pane banner like
#   "You've hit your session limit · resets 6:20am (Asia/Jerusalem)"),
# wait until a few minutes PAST the reset, then send "continue".
#
# It never types the paid-credits command the banner suggests (owner order,
# 2026-11-17): on this host it opened a login picker in 12 of 19 sends, and
# that picker covered the pane for hours. autodev/test/ci.sh greps bin/ for
# the command and fails on any send of it.
#
# Only a LIVE banner counts: the newest content on the pane, with a reset that
# parses and lies ahead (limit-banner.py). The wait ends, typing nothing, when a
# turn completes or the banner stops being the newest content.
#
# The context-% signal lives in the statusline JSON; the *limit* signal does NOT — it is only
# rendered in the pane. So this watcher detects it by reading the pane text (herdr or tmux), not a marker file.
#
# Conservative + reversible, same doctrine as the handoff watcher:
#   - Global kill switch:      ~/agents/state/disable-auto-compact   (present => whole system off)
#   - Phoenix-only kill switch: ~/agents/state/disable-auto-resume    (present => this off)
#   - Arming:                  ~/agents/state/auto-handoff.armed      (absent  => dry-run, log only)
#   - Per-session pane:        ~/agents/state/<sid>.{herdr,tmux}-pane (required to act)
#   - Per-session lock:        only one resume waiter per session at a time.
#   - While waiting it writes  ~/agents/state/<sid>.limit-wait        (statusline badge +
#                              the handoff watcher defers while it is active;
#                              limit-lib.sh says when it is stale).
#   - Everything logged to     ~/agents/logs/auto-resume.log
sid="$1"
[ -n "$sid" ] || exit 0

: "${AUTODEV_HOME:=$HOME/agents}"; export AUTODEV_HOME
STATE="$AUTODEV_HOME/state"
LOGDIR="$AUTODEV_HOME/logs"
LOG="$LOGDIR/auto-resume.log"
mkdir -p "$STATE" "$LOGDIR" 2>/dev/null

# Multiplexer abstraction (herdr | tmux). Absent => watcher safely no-ops.
_HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$_HERE/mux-lib.sh" ] && . "$_HERE/mux-lib.sh"
# The limit-wait file, the resume lock and needs-owner.list (shared with the
# handoff watcher and the sweep), and the banner detector.
[ -f "$_HERE/limit-lib.sh" ] && . "$_HERE/limit-lib.sh" || exit 0
BANNER="$_HERE/limit-banner.py"
[ -f "$BANNER" ] || exit 0

BUFFER_MIN=4      # send "continue" this many minutes PAST the stated reset time
DETECT_RECHECK=${AUTODEV_DETECT_RECHECK:-3}  # seconds between the two initial banner checks
WAKE=${AUTODEV_RESUME_WAKE:-60}  # re-check interval during the long wait-for-reset sleep
MAX_WAIT=93600      # 26h sanity cap; a parsed wait longer than this is treated as a parse error
POLL=3

log(){ printf '%s [%s] %s\n' "$(date +'%Y.%m.%d %H.%M.%S')" "$sid" "$*" >> "$LOG"; }

# --- kill switches ---
[ -f "$STATE/disable-auto-compact" ] && exit 0
[ -f "$STATE/disable-auto-resume" ] && exit 0

# --- arm state: absent => dry-run ---
DRY=1
[ -f "$STATE/auto-handoff.armed" ] && DRY=0

# --- pane must be registered + live (herdr preferred, tmux fallback) ---
command -v mux_init >/dev/null 2>&1 || exit 0
mux_init "$sid" || exit 0
if [ "$MUX" = herdr ]; then
  mux_session_reachable "$sid" || exit 0
fi
pane="$PANE"
mux_pane_live || exit 0
# --- pane-OWNERSHIP gate (see auto-handoff-watch.sh) ---
# herdr/tmux recycle pane ids; a live pane may now host a different session.
# Refuse before we even read its banner, so we never resume/inject into someone
# else's conversation. Self-heal by dropping our stale pane binding.
owner=$(mux_pane_owner)
if [ -n "$owner" ] && [ "$owner" != "$sid" ]; then
  if [ "$MUX" = herdr ]; then
    mux_mark_unreachable "$sid" "pane $pane ownership refused (owner: $owner)"
    exit 0
  fi
  log "SKIP pane $pane reused by session $owner (not ours) — cleared stale binding"
  rm -f "$STATE/$sid.$MUX-pane" 2>/dev/null
  exit 0
fi

snapshot(){ local s; mux_read_screen 200 s || return 1; printf '%s\n' "$s"; }
# verdict [limit-banner.py flags]: the detector's one line on the pane read now.
verdict(){ snapshot | python3 "$BANNER" "$@"; }
pane_busy(){ mux_busy; }
pane_live(){ mux_pane_live; }

# The pane shows a question or prompt put to the HUMAN; typing would answer it.
# Stand down as for a busy pane: the next Stop re-launches this watcher, and
# nothing here ever escalates into sending anyway.
defer_awaiting(){ # $1 = what was refused
  log "DEFER awaiting-human: refused [$1]; pane shows an open question/permission prompt"
  exit 0
}
send(){ # one literal line + Enter to the pane (via herdr/tmux)
  local text="$1"
  if [ "$DRY" = 1 ]; then log "DRY would send: [$text]"; else
    mux_send_line "$text" 2>>"$LOG"
    [ "$?" = "${MUX_REFUSED:-3}" ] && defer_awaiting "$text"
    log "SENT: [$text]"
  fi
}
wait_pane_idle(){ local d=$(( $(date +%s) + ${1:-30} )); while [ "$(date +%s)" -lt "$d" ]; do pane_busy || return 0; sleep "$POLL"; done; return 1; }

# composer_clear: the composer box is live, empty, ours, and under no dialog.
composer_clear(){
  verdict --composer-clear >/dev/null || return 1
  if [ "$MUX" = herdr ] && [ "$(cat "$STATE/$sid.runtime" 2>/dev/null)" = claude ]; then
    mux_screen_present_once || return 1
  fi
  ! mux_awaiting_human
}

# --- a pane listed for the owner gets nothing typed until its screen is clear ---
if autodev_needs_owner_get "$STATE" "$sid" >/dev/null; then
  if composer_clear; then
    autodev_needs_owner_clear "$STATE" "$sid"
    log "CLEAR needs-owner: pane $pane shows an empty composer again"
  else
    log "SKIP pane $pane is on needs-owner.list; typing nothing"
    exit 0
  fi
fi

# --- detect a LIVE banner (two cheap checks; on a normal turn this exits fast) ---
# Only a banner that is the newest content on the pane, with a reset that parses
# and lies ahead, counts (limit-banner.py says how the day is chosen). A banner
# in the scrollback, a passed reset, prose quoting one, or no reset: nothing.
v=$(verdict) || { sleep "$DETECT_RECHECK"; v=$(verdict); } || {
  case "$v" in *reason=no-banner*|'') ;; *) log "NO-DETECT pane=$pane ${v#none }" ;; esac
  exit 0
}

# --- one waiter per session ---
# A reader removing a stale limit-wait holds this lock for a moment (limit-lib.sh),
# and it may run on the same Stop: retry briefly before deciding a cycle owns it.
tries=${AUTODEV_RESUME_LOCK_TRIES:-5}
until autodev_resume_lock_take "$STATE" "$sid"; do
  tries=$(( tries - 1 ))
  [ "$tries" -gt 0 ] || { log "SKIP resume already in progress"; exit 0; }
  sleep 1
done
cleanup(){ rm -f "$STATE/$sid.limit-wait" 2>/dev/null; autodev_resume_lock_release "$STATE" "$sid"; }
trap cleanup EXIT
# Re-check under the lock: the screen may have moved on while we waited for it.
v=$(verdict) || { log "NO-DETECT pane=$pane ${v#none } (re-check under the lock)"; exit 0; }

reset=""; human=""; kind=""
for kv in $v; do
  case "$kv" in reset=*) reset=${kv#reset=} ;; human=*) human=${kv#human=} ;; kind=*) kind=${kv#kind=} ;; esac
done
case "$reset" in ''|*[!0-9]*) log "WARN detector gave no reset epoch [$v]; typing nothing"; exit 0 ;; esac
now=$(date +%s); tgt=$(( reset + BUFFER_MIN*60 )); wait_s=$(( tgt - now ))
log "LIMIT detected pane=$pane dry=$DRY kind=$kind reset='${human//_/ }' ($(date -d "@$reset" +'%Y.%m.%d %H.%M' 2>/dev/null || echo "$reset")) wait=${wait_s}s"
if [ "$wait_s" -gt "$MAX_WAIT" ]; then
  log "WARN reset is ${wait_s}s away (> ${MAX_WAIT}s cap); leaving it to the user. Exiting."
  exit 0
fi
start=$now
printf 'until=%s reset=%s human=%s ts=%s\n' "$tgt" "$reset" "$human" "$start" > "$STATE/$sid.limit-wait" 2>/dev/null

# --- wait until a few minutes past reset, then send continue ---
# The wait ends early, typing nothing, when a turn completes or the banner is
# no longer the newest content on the pane.
live(){ verdict --live-only >/dev/null 2>&1; }
log "waiting ${wait_s}s (until $(date -d "@$tgt" +'%Y.%m.%d %H.%M.%S' 2>/dev/null || echo "$tgt")) then sending continue"
while [ "$(date +%s)" -lt "$tgt" ]; do
  pane_live || { log "ABORT pane gone during wait"; exit 0; }
  { [ -f "$STATE/disable-auto-compact" ] || [ -f "$STATE/disable-auto-resume" ]; } && { log "ABORT disabled during wait"; exit 0; }
  if [ -f "$STATE/$sid.idle" ]; then
    iv=$(cat "$STATE/$sid.idle" 2>/dev/null || echo 0)
    [ "${iv:-0}" -gt "$start" ] 2>/dev/null && { log "ABORT a turn completed during wait"; exit 0; }
  fi
  live || { log "ABORT banner gone from the live area during wait"; exit 0; }
  left=$(( tgt - $(date +%s) )); [ "$left" -gt "$WAKE" ] && left=$WAKE; [ "$left" -lt 1 ] && left=1
  sleep "$left"
done

# reset time reached — resume, if the session is still parked on the banner.
pane_live || { log "ABORT pane gone at reset"; exit 0; }
live || { log "ABORT banner gone from the live area at reset; no continue"; exit 0; }
if [ "$DRY" = 0 ] && ! wait_pane_idle 30; then log "ABORT pane busy at reset; no continue"; exit 0; fi
send "continue"
log "CYCLE COMPLETE via wait-for-reset (dry=$DRY)"
exit 0
