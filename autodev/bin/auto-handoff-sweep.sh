#!/usr/bin/env bash
# auto-handoff-sweep.sh — the LEVEL trigger for the auto-handoff watcher.
#
# Driven by a systemd user timer (or cron) every few minutes. NEVER by a Claude
# Code hook — that is the entire point of this script.
#
# auto-handoff-watch.sh is EDGE-triggered: cc-stop-hook.sh launches it once per
# turn end, it evaluates once, and it exits. The condition it guards, however,
# is a LEVEL: "this session is parked with a full context". A parked session
# emits no further turn-end edges, and an idle session's context % never rises,
# so any evaluation that declines to act — DEFER (busy pane), ABORT (/handoff or
# /compact unconfirmed), SKIP (cooldown, cycle lock) — is FINAL. The session then
# waits forever for a watcher that will never run again. The request marker makes
# this worse, not better: it is consumed before the sends, so an aborted cycle
# leaves no trigger behind at all.
#
# cc-stall-watchdog.sh already learned this lesson ("NEVER by a Claude Code hook:
# hook-driven watchers only wake when a turn ends, which is exactly the blind spot
# that produced 36 h stalls"). This is that same lesson applied to auto-handoff.
#
# The sweeper makes NO decisions of its own. It applies a cheap file-only
# prefilter (200+ dead sessions accumulate in ~/agents/state, and must cost
# nothing), confirms the pane is live and still OURS, then re-invokes the real
# watcher — which re-applies every safety gate exactly as it does from the Stop
# hook. Anything this script gets wrong, the watcher still refuses.

set -u

: "${AUTODEV_HOME:=$HOME/agents}"; export AUTODEV_HOME
STATE="$AUTODEV_HOME/state"
LOGDIR="$AUTODEV_HOME/logs"
LOG="$LOGDIR/auto-handoff.log"
mkdir -p "$STATE" "$LOGDIR" 2>/dev/null

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$_HERE/mux-lib.sh" ] && . "$_HERE/mux-lib.sh"
WATCH="$_HERE/auto-handoff-watch.sh"
[ -x "$WATCH" ] || exit 0
command -v mux_init >/dev/null 2>&1 || exit 0

# These MUST match auto-handoff-watch.sh. The sweeper only prefilters; every one
# of these is re-checked authoritatively by the watcher itself.
THRESHOLD=30
COOLDOWN=900
REQUEST_MAX_AGE=3600
# After this many consecutive aborted cycles, stop retrying and mark the session
# stuck (the status line surfaces it) rather than typing /compact at a wedged
# pane every few minutes forever.
MAX_ABORTS=5

log(){ printf '%s [%s] %s\n' "$(date +'%Y.%m.%d %H.%M.%S')" "$1" "$2" >> "$LOG"; }

# Global kill switch beats everything.
[ -f "$STATE/disable-auto-compact" ] && exit 0

now=$(date +%s)
mtime(){ date -r "$1" +%s 2>/dev/null || echo 0; }
fresh(){ [ -f "$1" ] && [ "$(( now - $(mtime "$1") ))" -le "$2" ]; }

shopt -s nullglob
seen=" "
for pf in "$STATE"/*.herdr-pane "$STATE"/*.tmux-pane; do
  sid=${pf##*/}; sid=${sid%.herdr-pane}; sid=${sid%.tmux-pane}
  # sid becomes part of file paths and is written verbatim into a shared log.
  case "$sid" in ""|*[!A-Za-z0-9._-]*) continue ;; esac
  # A session registered under both multiplexers appears twice.
  case "$seen" in *" $sid "*) continue ;; esac
  seen="$seen$sid "

  # Phoenix owns sessions that are waiting out a usage limit; typing at them
  # would only queue input behind a blocked prompt.
  [ -f "$STATE/$sid.limit-wait" ] && continue

  # A cycle genuinely in flight must not be piled onto.
  lock="$STATE/$sid.cycle.lock"
  if [ -d "$lock" ]; then
    lpid=$(cat "$lock/pid" 2>/dev/null || true)
    [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null && continue
  fi

  # A cycle that just ran (either outcome) gets left alone for the cooldown.
  fresh "$STATE/$sid.cooldown" "$COOLDOWN" && continue

  # A session whose cycles keep aborting is wedged, not slow. Stop driving it and
  # make it VISIBLE — a wedged session whose pane still reads healthy is the
  # failure mode this whole harness exists to prevent.
  aborts=0
  [ -f "$STATE/$sid.abort-count" ] && aborts=$(cat "$STATE/$sid.abort-count" 2>/dev/null || echo 0)
  case "$aborts" in ''|*[!0-9]*) aborts=0 ;; esac
  if [ "$aborts" -ge "$MAX_ABORTS" ]; then
    if [ ! -f "$STATE/$sid.stuck" ]; then
      printf 'aborted %s consecutive auto-handoff cycles\n' "$aborts" > "$STATE/$sid.stuck"
      log "$sid" "STUCK after $aborts consecutive aborted cycles — no longer auto-retrying (status line flags it)"
    fi
    continue
  fi

  # --- is there anything to do? ---------------------------------------------
  reason=""
  if fresh "$STATE/$sid.handoff-request" "$REQUEST_MAX_AGE"; then
    reason="pending handoff-request"
  elif fresh "$STATE/$sid.compact-request" "$REQUEST_MAX_AGE"; then
    reason="pending compact-request"
  else
    ctxf="$STATE/$sid.ctx"
    [ -f "$ctxf" ] || continue
    pct=$(sed -n 's/^pct=\([0-9.]*\).*/\1/p' "$ctxf")
    [ -n "$pct" ] || continue
    awk "BEGIN{exit !($pct > $THRESHOLD)}" || continue
    # Guard against re-compacting an idle session forever: once a cycle has
    # COMPLETED, only fire again if the session has actually done something
    # since (its context reading moved). A session with aborted cycles is
    # exempt — retrying those is precisely the bug this sweeper fixes.
    if [ "$aborts" -eq 0 ] && [ -f "$STATE/$sid.cooldown" ] &&
       [ "$(mtime "$ctxf")" -le "$(mtime "$STATE/$sid.cooldown")" ]; then
      continue
    fi
    reason="pct=$pct > $THRESHOLD"
  fi

  # --- the pane must be live AND still ours ---------------------------------
  # mux_pane_live only proves the pane exists; herdr recycles short pane ids, so
  # a live pane may now host a DIFFERENT session. Driving it would type /compact
  # into somebody else's work.
  mux_init "$sid" || continue
  mux_pane_live || continue
  owner=$(mux_pane_owner)
  [ -n "$owner" ] && [ "$owner" != "$sid" ] && continue

  log "$sid" "SWEEP re-arming watcher ($reason, aborts=$aborts)"
  setsid "$WATCH" "$sid" </dev/null >/dev/null 2>&1 &
done

exit 0
