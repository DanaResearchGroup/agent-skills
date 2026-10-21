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
[ -f "$_HERE/request-lib.sh" ] && . "$_HERE/request-lib.sh"
# Never let a missing lib make every request look stale: fall back to "exists".
command -v request_valid >/dev/null 2>&1 || request_valid(){ [ -f "${5:-$1/$3.$4}" ]; }
command -v remove_stale_request >/dev/null 2>&1 || remove_stale_request(){ return 1; }
WATCH="$_HERE/auto-handoff-watch.sh"
[ -x "$WATCH" ] || exit 0
command -v mux_init >/dev/null 2>&1 || exit 0

# These MUST match auto-handoff-watch.sh. The sweeper only prefilters; every one
# of these is re-checked authoritatively by the watcher itself.
THRESHOLD=35
COOLDOWN=900
# A request is never expired by age (see request-lib.sh). A request pending this
# long with the watcher only ever DEFERring is stuck, and the user is paged once.
PAGE_AFTER=1800
# Opportunistic "compact while the cache is already cold" trigger — see
# auto-handoff-watch.sh for the full rationale. Compacting once the cache has
# already expired turns an already-owed full-context prefix rewrite into a
# rewrite of the small compacted context instead, at zero incremental cost.
# COLD_MIN and CACHE_TTL MUST match auto-handoff-watch.sh; a divergence
# between the two would be silent. The watcher alone can never observe this
# condition (at turn end idle_age is ~0) — only this sweeper, polling a
# parked/idle session later, can see idle_age >= CACHE_TTL.
COLD_MIN=25
CACHE_TTL=300
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

# Page once for <sid>'s <kind> request. Serialised per session: two sweeps can
# overlap (timer tick while a slow one runs), and both would otherwise read
# "not paged yet". The identity is re-read under the lock.
page_stuck(){
  local sid=$1 kind=$2 rf key age
  rf="$STATE/$sid.$kind"
  # Without flock (or with AUTODEV_NO_FLOCK=1) two overlapping sweeps could still
  # both page; sequential sweeps are deduped by .paged either way.
  if [ -n "${AUTODEV_NO_FLOCK:-}" ] || ! command -v flock >/dev/null 2>&1; then
    _page_locked "$sid" "$kind"; return
  fi
  (
    flock -n 9 || exit 0
    _page_locked "$sid" "$kind"
  ) 9>"$STATE/$sid.page.lock"
}
_page_locked(){
  local sid=$1 kind=$2 rf key age msg
  rf="$STATE/$sid.$kind"
  [ -f "$rf" ] || return 0
  key="$kind:$(date -r "$rf" +%s%N 2>/dev/null)"
  [ "$(cat "$STATE/$sid.paged" 2>/dev/null)" = "$key" ] && return 0
  age=$(( (now - $(mtime "$rf")) / 60 ))
  msg="autodev: $kind for session $sid pending $age min and the watcher keeps deferring (busy pane or open prompt) — compact it by hand"
  # Record BEFORE paging, and refuse to page if the record cannot be kept: an
  # unrecorded page repeats on every sweep.
  if ! printf '%s\n' "$key" > "$STATE/$sid.paged" 2>/dev/null; then
    log "$sid" "PAGE-SKIP cannot record $STATE/$sid.paged — not paging (would repeat every sweep): $msg"
    return 0
  fi
  log "$sid" "PAGE $msg"
  # A timer-run sweeper has no session bus in its environment; point at the user's.
  [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "/run/user/$(id -u)/bus" ] &&
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
  local -a runner=(); command -v timeout >/dev/null 2>&1 && runner=(timeout "${AUTODEV_PAGE_TIMEOUT:-10}")
  "${runner[@]}" "${AUTODEV_PAGE_CMD:-notify-send}" "autodev: handoff stuck" "$msg" >/dev/null 2>&1 ||
    log "$sid" "PAGE notify failed — the PAGE line above is the only record; handled once, not retried"
}

shopt -s nullglob
seen=" "
for pf in "$STATE"/*.herdr-pane "$STATE"/*.tmux-pane; do
  sid=${pf##*/}; sid=${sid%.herdr-pane}; sid=${sid%.tmux-pane}
  # sid becomes part of file paths and is written verbatim into a shared log.
  case "$sid" in ""|*[!A-Za-z0-9._-]*) continue ;; esac
  # A session registered under both multiplexers appears twice.
  case "$seen" in *" $sid "*) continue ;; esac
  seen="$seen$sid "

  # A request is stale when satisfied (see request-lib.sh), never by age. Cleaned
  # before the pane checks so a dead session's leftovers go too.
  for kind in handoff-request compact-request; do
    if [ -f "$STATE/$sid.$kind" ] && remove_stale_request "$STATE" "$AUTODEV_HOME/handoffs" "$sid" "$kind"; then
      log "$sid" "SKIP stale $kind (handoff missing or predates the last compaction) — removed"
    fi
  done

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
  if [ -f "$STATE/$sid.handoff-request" ]; then
    reason="pending handoff-request"
  elif [ -f "$STATE/$sid.compact-request" ]; then
    reason="pending compact-request"
  else
    ctxf="$STATE/$sid.ctx"
    [ -f "$ctxf" ] || continue
    pct=$(sed -n 's/^pct=\([0-9.]*\).*/\1/p' "$ctxf")
    [ -n "$pct" ] || continue
    if awk "BEGIN{exit !($pct > $THRESHOLD)}"; then
      reason="pct=$pct > $THRESHOLD"
    elif [ ! -f "$STATE/disable-cold-cache-compact" ] \
         && awk "BEGIN{exit !($pct > $COLD_MIN)}" \
         && [ -f "$STATE/$sid.idle" ] \
         && [ "$(( now - $(cat "$STATE/$sid.idle" 2>/dev/null || echo "$now") ))" -ge "$CACHE_TTL" ]; then
      reason="pct=$pct > $COLD_MIN, idle >= ${CACHE_TTL}s (cold-cache)"
    else
      continue
    fi
    # Guard against re-compacting an idle session forever: once a cycle has
    # COMPLETED, only fire again if the session has actually done something
    # since (its context reading moved). A session with aborted cycles is
    # exempt — retrying those is precisely the bug this sweeper fixes. Binds
    # BOTH branches above (threshold and cold-cache) — without it a session
    # sitting above COLD_MIN and idle would get compacted every COOLDOWN
    # period forever.
    if [ "$aborts" -eq 0 ] && [ -f "$STATE/$sid.cooldown" ] &&
       [ "$(mtime "$ctxf")" -le "$(mtime "$STATE/$sid.cooldown")" ]; then
      continue
    fi
  fi

  # --- stuck request: pending >= PAGE_AFTER and the watcher has only DEFERred ----
  # Page once per request. Its identity is its mtime in ns (a re-filed request has
  # a new one; the watcher's DEFER re-file restores the original exactly). The
  # DEFER must be newer than the request — an older one says nothing about it.
  for kind in handoff-request compact-request; do
    rf="$STATE/$sid.$kind"
    [ -f "$rf" ] && [ "$STATE/$sid.deferred" -nt "$rf" ] || continue
    [ "$(( now - $(mtime "$rf") ))" -ge "$PAGE_AFTER" ] || continue
    page_stuck "$sid" "$kind"
  done

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
