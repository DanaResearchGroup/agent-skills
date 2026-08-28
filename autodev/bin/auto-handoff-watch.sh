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
# A .compact-request marker triggers a COMPACT-ONLY variant: the /handoff step is
# skipped (a handoff is already written) and the cycle starts at /compact.
# Triggers: pct > THRESHOLD | pct > COLD_MIN and idle >= CACHE_TTL (cold-cache) |
# .handoff-request (full cycle) | .compact-request (compact-only).
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

THRESHOLD=35        # act only when used_percentage > THRESHOLD
# Opportunistic "compact while the cache is already cold" trigger. Compaction
# always pays a full prompt-prefix rewrite; whether that rewrite is expensive
# depends entirely on WHEN it happens. Compact while the cache is warm and you
# discard a live prefix and pay to rewrite the new one. Compact after the cache
# has already expired and the next turn owed a full rewrite of the WHOLE
# context anyway — compacting first makes the rewrite it owes a rewrite of the
# small compacted context instead of the large one, and the saving is the
# difference between those two sizes. Measured across 4,625 transcripts:
# writes following a gap of 5-60 minutes are 18.5% of all cache-write volume,
# $7,409 — and they are rewrites of full-size contexts. The 5-minute ephemeral
# TTL is what makes 300s the threshold below.
COLD_MIN=25          # only contexts big enough for the saved rewrite to be worth a cycle
CACHE_TTL=300        # the 5m ephemeral prompt-cache TTL
# Wait timings are env-overridable so the tests can drive a whole cycle in
# seconds. THRESHOLD, COOLDOWN, COLD_MIN and CACHE_TTL deliberately are NOT —
# auto-handoff-sweep.sh hard-codes the same values, and a divergence between
# the two would be silent.
SETTLE=${AUTODEV_SETTLE:-2}              # settle before the first idle check
POLL=${AUTODEV_POLL:-3}                  # poll interval while waiting
PRECHECK=${AUTODEV_PRECHECK:-45}         # max seconds to wait for an idle window before deferring
WAIT_IDLE=${AUTODEV_WAIT_IDLE:-420}      # max seconds to wait for the /handoff turn to finish
WAIT_COMPACT=${AUTODEV_WAIT_COMPACT:-300} # max seconds to wait for compaction to complete
COOLDOWN=900        # suppress re-trigger after a cycle (success OR abort)
HEARTBEAT_EVERY=600 # emit at most one HEARTBEAT log line per this many seconds
REQUEST_MAX_AGE=3600 # a .handoff-request / .compact-request older than this is stale -> ignored + removed

log(){ printf '%s [%s] %s\n' "$(date +'%Y.%m.%d %H.%M.%S')" "$sid" "$*" >> "$LOG"; }

# Abandon this cycle. Stamps the cooldown and bumps the consecutive-abort
# counter that auto-handoff-sweep.sh reads to tell "retry it" from "this session
# is wedged — stop typing at it and flag it". Cleared on a completed cycle.
# Only real failures call this; a withdrawn request is not an abort.
abort_cycle(){ # $1 = what failed
  local n=0
  [ -f "$STATE/$sid.abort-count" ] && n=$(cat "$STATE/$sid.abort-count" 2>/dev/null || echo 0)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$(( n + 1 ))
  printf '%s\n' "$n" > "$STATE/$sid.abort-count" 2>/dev/null
  log "ABORT $1 (consecutive aborts: $n)"
  date +%s > "$cdf"
  exit 0
}

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

# --- trigger gate: over threshold OR an explicit handoff/compact request ---
# A quiesced session that knows its NEXT phase is heavy can drop
# $STATE/$sid.handoff-request to hand off at THIS clean boundary even below
# threshold (e.g. holding at a phase boundary at 22%). A session that has ALREADY
# written its own handoff can instead drop $STATE/$sid.compact-request, which
# triggers a COMPACT-ONLY cycle: skip /handoff, go straight to /compact -> reload
# (no redundant second handoff). Both bypass ONLY this gate — every safety gate
# below (cooldown, pane live/owned, cycle lock, idle) still applies, so they fire
# only when genuinely quiesced and safe.
req="$STATE/$sid.handoff-request"
creq="$STATE/$sid.compact-request"
reason=""
compact_only=0
if [ -f "$req" ]; then
  req_age=$(( $(date +%s) - $(date -r "$req" +%s 2>/dev/null || echo 0) ))
  if [ "$req_age" -le "$REQUEST_MAX_AGE" ]; then
    reason=requested
  else
    log "SKIP stale handoff-request (age ${req_age}s > ${REQUEST_MAX_AGE}s) — removed (pct=$pct)"
    rm -f "$req" 2>/dev/null
  fi
fi
# compact-request is honored only when no full handoff-request is pending (a
# handoff-request means "write a fresh handoff too", which supersedes it).
if [ -z "$reason" ] && [ -f "$creq" ]; then
  creq_age=$(( $(date +%s) - $(date -r "$creq" +%s 2>/dev/null || echo 0) ))
  if [ "$creq_age" -le "$REQUEST_MAX_AGE" ]; then
    reason=compact-requested; compact_only=1
  else
    log "SKIP stale compact-request (age ${creq_age}s > ${REQUEST_MAX_AGE}s) — removed (pct=$pct)"
    rm -f "$creq" 2>/dev/null
  fi
fi
if [ -z "$reason" ]; then
  if awk "BEGIN{exit !($pct > $THRESHOLD)}"; then
    reason=threshold
  elif [ ! -f "$STATE/disable-cold-cache-compact" ] && awk "BEGIN{exit !($pct > $COLD_MIN)}" \
       && [ -f "$STATE/$sid.idle" ]; then
    idle_age=$(( $(date +%s) - $(cat "$STATE/$sid.idle" 2>/dev/null || echo "$(date +%s)") ))
    [ "$idle_age" -ge "$CACHE_TTL" ] && reason=cold-cache
  fi
  [ -n "$reason" ] || exit 0
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

# Honor a late cancel: reason=requested was latched before the idle-gate wait, so
# request-handoff.sh --cancel (or a manual rm) may have removed the marker in the
# window since. Re-check right before we commit; if it's gone, the request was
# withdrawn — abort without a cooldown stamp (nothing failed, nothing to suppress).
if [ "$reason" = requested ] && [ ! -f "$req" ]; then
  log "ABORT handoff-request withdrawn before trigger (pct=$pct)"; exit 0
fi
if [ "$reason" = compact-requested ] && [ ! -f "$creq" ]; then
  log "ABORT compact-request withdrawn before trigger (pct=$pct)"; exit 0
fi

log "TRIGGER ($reason) pct=$pct thr=$THRESHOLD pane=$pane dry=$DRY"
# Consume an explicit request NOW that we're committed to the cycle — before any
# send. A post-send abort (/handoff or /compact may already have landed) must NOT
# leave the marker to re-fire on the reloaded, already-compacted session; a fresh
# request is required to retry. Only touch the marker when it is what triggered us,
# so a request dropped DURING a threshold cycle survives to be honored next idle.
if [ "$reason" = requested ]; then
  rm -f "$req" 2>/dev/null
  [ -f "$req" ] && log "WARN could not remove handoff-request $req — may re-fire after cooldown"
elif [ "$reason" = compact-requested ]; then
  rm -f "$creq" 2>/dev/null
  [ -f "$creq" ] && log "WARN could not remove compact-request $creq — may re-fire after cooldown"
fi

# 1) handoff — skipped in compact-only mode (a handoff is already written).
if [ "$compact_only" = 1 ]; then
  log "compact-only: skipping /handoff (handoff already written by session)"
else
  t0=$(date +%s)
  send "/handoff"
  if [ "$DRY" = 0 ]; then
    if ! wait_turn_done "$t0" "$WAIT_IDLE"; then
      abort_cycle "/handoff did not complete within ${WAIT_IDLE}s"
    fi
    log "/handoff turn completed"
  fi
  # The handoff skill writes THIS session's own pointer (.latest.<sid>) directly,
  # so there is normally nothing to do here. Copying the shared .latest — as this
  # used to do unconditionally — is a race, not a safeguard: between our /handoff
  # turn ending and the copy, any of the ~25 concurrent sessions on this box can
  # clobber .latest, and we would then cache THEIR mission as ours, permanently
  # and invisibly. So only adopt the shared pointer as a bridge for older handoff
  # skills, and only when the file it names was written during the turn we just
  # drove (mtime >= t0) — the one moment it is provably ours.
  per="$AUTODEV_HOME/handoffs/.latest.$sid"
  if [ ! -s "$per" ] || [ "$(date -r "$per" +%s 2>/dev/null || echo 0)" -lt "$t0" ]; then
    cand=""; [ -s "$AUTODEV_HOME/handoffs/.latest" ] &&
      cand=$(cat "$AUTODEV_HOME/handoffs/.latest" 2>/dev/null)
    if [ -n "$cand" ] && [ -f "$cand" ] &&
       [ "$(date -r "$cand" +%s 2>/dev/null || echo 0)" -ge "$t0" ]; then
      ptmp="$per.tmp.$$"
      printf '%s\n' "$cand" > "$ptmp" 2>/dev/null &&
        mv -f "$ptmp" "$per" 2>/dev/null || rm -f "$ptmp" 2>/dev/null
      log "legacy /handoff: adopted .latest by mtime proof (written during our turn)"
    else
      rm -f "$per" 2>/dev/null
      log "WARN /handoff wrote no per-session pointer, and .latest is not provably ours"
    fi
  fi
fi

# 2) compact (only when idle)
if [ "$DRY" = 0 ] && ! wait_pane_idle 60; then
  abort_cycle "pane busy before /compact"
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
  if [ "$ok" != 1 ]; then abort_cycle "/compact did not complete within ${WAIT_COMPACT}s"; fi
  log "compaction completed"
fi

# 3) re-assert the session name (compaction can reset the display title), then continue
[ "$DRY" = 0 ] && wait_pane_idle 60
if [ -n "$SESSION_NAME" ]; then
  send "/rename $SESSION_NAME"
  [ "$DRY" = 0 ] && { sleep 2; wait_pane_idle 30; }
fi
# Reload from THIS session's own pointer, and only from it.
#
# ~/agents/handoffs/.latest is a single machine-wide, last-writer-wins file. On a
# box running ~25 concurrent sessions it names whichever session handed off most
# recently — almost never us. Falling back to it (or to "the newest handoff in
# the directory") is exactly how a worker comes back from compaction running
# someone else's mission while its pane still reads perfectly healthy, silently
# ending whatever it was actually monitoring. A missing pointer must therefore
# fail closed: no handoff is strictly better than another session's handoff.
ptr="$AUTODEV_HOME/handoffs/.latest.$sid"
hf=""; [ -f "$ptr" ] && hf=$(cat "$ptr" 2>/dev/null)
if [ -n "$hf" ] && { [ "$DRY" = 1 ] || [ -f "$hf" ]; }; then
  send "Read the handoff at \"$hf\" and continue execution from where it leaves off."
else
  log "WARN reloaded with no per-session pointer (.latest.$sid) — sent the fail-closed prompt"
  send "A compaction just occurred, but no handoff is registered for THIS session. Do not read another session's handoff from $AUTODEV_HOME/handoffs — re-orient from this session's own transcript and continue, or ask the user."
fi

# 4) stamp cooldown and finish. (An explicit request was already consumed at
#    TRIGGER, so nothing to clean up here.) A completed cycle clears the
#    consecutive-abort counter and any stuck flag the sweeper raised.
date +%s > "$cdf"
rm -f "$STATE/$sid.abort-count" "$STATE/$sid.stuck" 2>/dev/null
log "CYCLE COMPLETE ($reason, dry=$DRY)"
exit 0
