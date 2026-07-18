#!/usr/bin/env bash
# Auto-handoff watcher. Launched (detached) by the Stop hook once per turn.
# Conservative + reversible by design:
#   - Global kill switch:  ~/agents/state/disable-auto-compact   (present => off)
#   - Arming:              ~/agents/state/auto-handoff.armed      (absent  => dry-run)
#   - Per-session pane:    ~/agents/state/<sid>.{herdr,tmux}-pane (required to act)
#   - Cycle lock + cooldown prevent recursion / double-sends.
#   - IDLE GATE: never send keys into a busy CC (which would queue them instead of
#     running the command). Confirms the pane is at an idle prompt first.
#   - Every decision and action is logged to ~/agents/logs/auto-handoff.log
#
# Sequence when triggered (armed, idle): /handoff -> wait idle -> /compact -> wait
# compaction -> /rename <session name> (re-assert the display name, which compaction
# can reset) -> "read <handoff> and continue execution".
sid="$1"
[ -n "$sid" ] || exit 0
# sid is used to build state-file paths (incl. `rm -rf` of the cycle lock), so
# reject anything that could escape $STATE via path traversal before any such use.
case "$sid" in */*|*..*) exit 0 ;; esac

: "${AUTODEV_HOME:=$HOME/agents}"; export AUTODEV_HOME
STATE="$AUTODEV_HOME/state"
LOGDIR="$AUTODEV_HOME/logs"
LOG="$LOGDIR/auto-handoff.log"
mkdir -p "$STATE" "$LOGDIR" 2>/dev/null

# Multiplexer abstraction (herdr | tmux). Provides mux_init/mux_pane_live/
# mux_busy/mux_send_line/mux_session_name. Absent => watcher safely no-ops.
_HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$_HERE/mux-lib.sh" ] && . "$_HERE/mux-lib.sh"

THRESHOLD=25        # act only when used_percentage > THRESHOLD
SETTLE=2            # settle before the first idle check
POLL=3             # poll interval while waiting
PRECHECK=45         # max seconds to wait for an idle window before deferring
WAIT_IDLE=420       # max seconds to wait for the /handoff turn to finish
WAIT_COMPACT=300    # max seconds to wait for compaction to complete
COOLDOWN=900        # suppress re-trigger after a cycle (success OR abort)
HEARTBEAT_EVERY=600 # emit at most one HEARTBEAT log line per this many seconds
REQUEST_MAX_AGE=3600 # a .handoff-request older than this is stale -> ignored + removed

log(){ printf '%s [%s] %s\n' "$(date +'%Y.%m.%d %H.%M.%S')" "$sid" "$*" >> "$LOG"; }

# --- global kill switch ---
if [ -f "$STATE/disable-auto-compact" ]; then exit 0; fi

# --- defer while Phoenix is handling a usage/session limit for this session ---
# (sending /handoff or /compact into a limited session would just be blocked/queued).
if [ -f "$STATE/$sid.limit-wait" ]; then log "SKIP session-limit resume pending"; exit 0; fi

# --- arm state: absent => dry-run (log only, never send keys) ---
DRY=1
[ -f "$STATE/auto-handoff.armed" ] && DRY=0

# --- read context % written by the statusline ---
ctxf="$STATE/$sid.ctx"
[ -f "$ctxf" ] || exit 0
pct=$(sed -n 's/^pct=\([0-9.]*\).*/\1/p' "$ctxf")
[ -n "$pct" ] || exit 0

# --- heartbeat (throttled) ---
# Proves the watcher is alive during quiet, BELOW-threshold periods, where every
# gate below exits silently. Without this a benign "nothing to do" is
# indistinguishable from a dead watcher — which is exactly what made past silence
# impossible to diagnose. Throttled to one line per HEARTBEAT_EVERY per session.
hbf="$STATE/$sid.heartbeat"; hb_now=$(date +%s)
hb_last=0; [ -f "$hbf" ] && hb_last=$(cat "$hbf" 2>/dev/null || echo 0)
if [ $(( hb_now - hb_last )) -ge "$HEARTBEAT_EVERY" ]; then
  idle_age="?"
  [ -f "$STATE/$sid.idle" ] && idle_age=$(( hb_now - $(cat "$STATE/$sid.idle" 2>/dev/null || echo "$hb_now") ))s
  log "HEARTBEAT pct=$pct thr=$THRESHOLD idle_age=$idle_age armed=$([ "$DRY" = 0 ] && echo 1 || echo 0)"
  printf '%s\n' "$hb_now" > "$hbf" 2>/dev/null
fi

# --- trigger gate: over threshold OR an explicit session handoff-request ---
# A quiesced session that knows its NEXT phase is heavy can drop
# $STATE/$sid.handoff-request to hand off at THIS clean boundary even below
# threshold (e.g. holding at a phase boundary at 22%). The request bypasses ONLY
# this gate — every safety gate below (cooldown, pane live/owned, cycle lock,
# idle) still applies, so it fires only when genuinely quiesced and safe.
req="$STATE/$sid.handoff-request"
reason=""
if [ -f "$req" ]; then
  req_age=$(( $(date +%s) - $(date -r "$req" +%s 2>/dev/null || echo 0) ))
  if [ "$req_age" -le "$REQUEST_MAX_AGE" ]; then
    reason=requested
  else
    log "SKIP stale handoff-request (age ${req_age}s > ${REQUEST_MAX_AGE}s) — removed (pct=$pct)"
    rm -f "$req" 2>/dev/null
  fi
fi
if [ -z "$reason" ]; then
  if awk "BEGIN{exit !($pct > $THRESHOLD)}"; then reason=threshold; else exit 0; fi
fi

# --- cooldown gate ---
cdf="$STATE/$sid.cooldown"
if [ -f "$cdf" ]; then
  last=$(cat "$cdf" 2>/dev/null || echo 0); now=$(date +%s)
  if [ $(( now - last )) -lt "$COOLDOWN" ]; then
    log "SKIP cooldown active (pct=$pct)"; exit 0
  fi
fi

# --- pane registration gate (herdr preferred, tmux fallback) ---
if ! command -v mux_init >/dev/null 2>&1 || ! mux_init "$sid"; then
  log "SKIP no pane registered (pct=$pct)"; exit 0
fi
pane="$PANE"
if ! mux_pane_live; then
  log "SKIP pane $pane ($MUX) not live (pct=$pct)"; exit 0
fi
# --- pane-OWNERSHIP gate ---
# A live pane is NOT proof it is still ours: herdr/tmux recycle pane ids, so the
# pane our stale registration points at may now host a DIFFERENT, live session.
# Injecting here would land /handoff+/compact in someone else's conversation.
# Refuse, and self-heal by dropping our stale pane binding.
owner=$(mux_pane_owner)
if [ -n "$owner" ] && [ "$owner" != "$sid" ]; then
  log "SKIP pane $pane reused by session $owner (not ours) — cleared stale binding (pct=$pct)"
  rm -f "$STATE/$sid.$MUX-pane" 2>/dev/null
  exit 0
fi
# Stable label to re-assert after compaction (tmux session name; empty under herdr).
SESSION_NAME=$(mux_session_name)

# --- cycle lock (atomic mkdir; blocks recursion + concurrent cycles) ---
# PID-aware so a crashed/SIGKILLed watcher (EXIT trap never ran) can't wedge every
# future cycle behind a permanent "already in progress". If the recorded holder is
# gone, reclaim the lock. A legacy pid-less lock (pre-upgrade watcher) is honored
# while still fresh, then reclaimed once clearly stale.
lock="$STATE/$sid.cycle.lock"
if ! mkdir "$lock" 2>/dev/null; then
  lpid=$(cat "$lock/pid" 2>/dev/null || true)
  if [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null; then
    log "SKIP cycle already in progress (pid $lpid, pct=$pct)"; exit 0
  fi
  lock_age=$(( $(date +%s) - $(date -r "$lock" +%s 2>/dev/null || echo 0) ))
  if [ -z "$lpid" ] && [ "$lock_age" -lt $(( WAIT_IDLE + WAIT_COMPACT )) ]; then
    log "SKIP cycle in progress (legacy lock, age ${lock_age}s, pct=$pct)"; exit 0
  fi
  log "reclaim stale cycle lock (holder ${lpid:-none}, age ${lock_age}s, pct=$pct)"
  rm -rf "$lock" 2>/dev/null
  mkdir "$lock" 2>/dev/null || { log "SKIP cycle lock race (pct=$pct)"; exit 0; }
fi
printf '%s\n' "$$" > "$lock/pid" 2>/dev/null
trap 'rm -rf "$lock" 2>/dev/null || true' EXIT

# --- idle helpers (pre-send safety gate; avoids queuing into a busy CC) ---
pane_busy(){ mux_busy; }  # 0 = busy (herdr agent_status, or tmux visible-pane scrape)
wait_pane_idle(){ # $1 timeout; 0 when idle (confirmed twice), 1 on timeout
  local deadline=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! pane_busy; then sleep 1; pane_busy || return 0; fi
    sleep "$POLL"
  done
  return 1
}
wait_turn_done(){ # $1 = since epoch, $2 = timeout: idle marker newer AND pane idle
  local since="$1" deadline=$(( $(date +%s) + $2 )) v
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -f "$STATE/$sid.idle" ]; then
      v=$(cat "$STATE/$sid.idle" 2>/dev/null || echo 0)
      if [ "${v:-0}" -gt "$since" ] 2>/dev/null && ! pane_busy; then return 0; fi
    fi
    sleep "$POLL"
  done
  return 1
}

send(){ # send one literal line + Enter to the registered pane (via herdr/tmux)
  local text="$1"
  if [ "$DRY" = 1 ]; then
    log "DRY would send: [$text]"
  else
    mux_send_line "$text" 2>>"$LOG"
    log "SENT: [$text]"
  fi
}

sleep "$SETTLE"

# --- Pre-send idle gate: never inject into a busy session (it would queue). ---
if [ "$DRY" = 0 ] && pane_busy; then
  if ! wait_pane_idle "$PRECHECK"; then
    log "DEFER busy pane (agents/turn/queued input) pct=$pct — retry next idle turn"
    exit 0    # no cooldown: a genuine idle Stop will retry cleanly
  fi
fi

# Re-check for a session-limit resume that Phoenix may have registered in the race window
# between our top-of-script check and now (both watchers launch on the same Stop).
if [ -f "$STATE/$sid.limit-wait" ]; then log "SKIP session-limit resume pending (late)"; exit 0; fi

log "TRIGGER ($reason) pct=$pct thr=$THRESHOLD pane=$pane dry=$DRY"
# Consume an explicit request NOW that we're committed to the cycle — before any
# send. A post-send abort (/handoff or /compact may already have landed) must NOT
# leave the marker to re-fire on the reloaded, already-compacted session; a fresh
# request is required to retry. Only touch the marker when it is what triggered us,
# so a request dropped DURING a threshold cycle survives to be honored next idle.
[ "$reason" = requested ] && rm -f "$req" 2>/dev/null

# 1) handoff
t0=$(date +%s)
send "/handoff"
if [ "$DRY" = 0 ]; then
  if ! wait_turn_done "$t0" "$WAIT_IDLE"; then
    log "ABORT /handoff did not complete within ${WAIT_IDLE}s"; date +%s > "$cdf"; exit 0
  fi
  log "/handoff turn completed"
fi

# 2) compact (only when idle)
if [ "$DRY" = 0 ] && ! wait_pane_idle 60; then
  log "ABORT pane busy before /compact"; date +%s > "$cdf"; exit 0
fi
t1=$(date +%s)
send "/compact"
if [ "$DRY" = 0 ]; then
  deadline=$(( t1 + WAIT_COMPACT )); ok=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -f "$STATE/$sid.compacted" ]; then
      cv=$(cat "$STATE/$sid.compacted" 2>/dev/null || echo 0)
      [ "${cv:-0}" -gt "$t1" ] 2>/dev/null && { ok=1; break; }
    fi
    sleep "$POLL"
  done
  if [ "$ok" != 1 ]; then log "ABORT /compact did not complete within ${WAIT_COMPACT}s"; date +%s > "$cdf"; exit 0; fi
  log "compaction completed"
fi

# 3) re-assert the session name (compaction can reset the display title), then continue
[ "$DRY" = 0 ] && wait_pane_idle 60
if [ -n "$SESSION_NAME" ]; then
  send "/rename $SESSION_NAME"
  [ "$DRY" = 0 ] && { sleep 2; wait_pane_idle 30; }
fi
hf=""; [ -f "$AUTODEV_HOME/handoffs/.latest" ] && hf=$(cat "$AUTODEV_HOME/handoffs/.latest" 2>/dev/null)
if [ -n "$hf" ] && { [ "$DRY" = 1 ] || [ -f "$hf" ]; }; then
  send "Read the handoff at \"$hf\" and continue execution from where it leaves off."
else
  send "Resume: read the newest handoff in $AUTODEV_HOME/handoffs and continue execution."
fi

# 4) stamp cooldown and finish. (An explicit request was already consumed at
#    TRIGGER, so nothing to clean up here.)
date +%s > "$cdf"
log "CYCLE COMPLETE ($reason, dry=$DRY)"
exit 0
