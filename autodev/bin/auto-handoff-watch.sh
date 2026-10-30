#!/usr/bin/env bash
# Auto-handoff watcher. Launched (detached) by the Stop hook once per turn.
# Conservative + reversible by design:
#   - Global kill switch:  ~/agents/state/disable-auto-compact   (present => off)
#   - Arming:              ~/agents/state/auto-handoff.armed      (absent  => dry-run)
#   - Per-session pane:    ~/agents/state/<sid>.{herdr,tmux}-pane (required to act)
#   - Cycle lock + cooldown prevent recursion / double-sends.
#   - IDLE GATE: never send keys into a busy agent (which would queue them instead of
#     running the command). Confirms the pane is at an idle prompt first.
#   - Every decision and action is logged to ~/agents/logs/auto-handoff.log
#
# Sequence when triggered (armed, idle): handoff skill -> wait idle -> /compact -> wait
# compaction -> /rename <session name> (re-assert the display name, which compaction
# can reset) -> "read <handoff> and continue execution".
# A .compact-request marker triggers a COMPACT-ONLY variant: the handoff step is
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
[ -f "$_HERE/lock-lib.sh" ] && . "$_HERE/lock-lib.sh" || exit 0
[ -f "$_HERE/mux-lib.sh" ] && . "$_HERE/mux-lib.sh"
[ -f "$_HERE/request-lib.sh" ] && . "$_HERE/request-lib.sh"
# Never let a missing lib make every request look stale: fall back to "exists".
command -v request_valid >/dev/null 2>&1 || request_valid(){ [ -f "${5:-$1/$3.$4}" ]; }
command -v remove_stale_request >/dev/null 2>&1 || remove_stale_request(){ return 1; }

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
# (requests never expire by age — see request-lib.sh for when one is stale)

log(){ printf '%s [%s] %s\n' "$(date +'%Y.%m.%d %H.%M.%S')" "$sid" "$*" >> "$LOG"; }

prepare_reload_line(){
  local ptr="$AUTODEV_HOME/handoffs/.latest.$sid" hf=""
  [ -f "$ptr" ] && hf=$(cat "$ptr" 2>/dev/null)
  if [ -n "$hf" ] && { [ "$DRY" = 1 ] || [ -f "$hf" ]; }; then
    pending_reload_line="Read the handoff at \"$hf\" and continue execution from where it leaves off."
    reload_has_handoff=1
  else
    pending_reload_line="A compaction just occurred, but no handoff is registered for THIS session. Do not read another session's handoff from $AUTODEV_HOME/handoffs — re-orient from this session's own transcript and continue, or ask the user."
    reload_has_handoff=0
  fi
}

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

reload_marker="$STATE/$sid.reload-pending"
reload_attempt="$STATE/$sid.reload-attempt"
reload_retry=0
reload_superseded=0
if [ -f "$reload_marker" ]; then
  if ! command -v reload_marker_retire_reason >/dev/null 2>&1; then
    log "SKIP reload-pending: request-lib retirement check unavailable"
    exit 0
  fi
  # Retirement is a mutation too. Never erase a reload belonging to an
  # in-flight cycle based on a pre-lock idle/handoff observation.
  reload_cleanup_lock="$STATE/$sid.cycle.lock"
  retired=$(reload_marker_retire_reason "$STATE" "$AUTODEV_HOME/handoffs" "$sid" "$reload_marker" || true)
  if [ -z "$retired" ]; then
    reload_retry=1
  elif autodev_lock_publish "$reload_cleanup_lock" "$$"; then
    if [ -f "$reload_marker" ]; then
      # The pre-lock observation only selected this cleanup path; it cannot
      # authorize deletion of a marker the current cycle replaced meanwhile.
      retired=$(reload_marker_retire_reason "$STATE" "$AUTODEV_HOME/handoffs" "$sid" "$reload_marker" || true)
      case "$retired" in
        new-handoff-request)
          rm -f "$reload_marker" 2>/dev/null
          log "DROP reload-pending: a newer handoff request superseded it"
          ;;
        new-handoff|completed-turn)
          rm -f "$reload_marker" 2>/dev/null
          reload_superseded=1
          log "DROP reload-pending: superseded by $retired"
          ;;
        *) reload_retry=1 ;;
      esac
    fi
    autodev_lock_release_owned "$reload_cleanup_lock" "$$" || true
  else
    # The ordinary lock path below can reclaim a dead owner. It will repeat
    # retirement checks under that lock before sending any pending reload.
    reload_retry=1
  fi
fi

# --- read context % written by the statusline ---
ctxf="$STATE/$sid.ctx"
if [ "$reload_retry" = 1 ]; then
  pct="unknown"
  [ -f "$ctxf" ] && pct=$(sed -n 's/^pct=\([0-9.]*\).*/\1/p' "$ctxf")
  [ -n "$pct" ] || pct="unknown"
else
  [ -f "$ctxf" ] || exit 0
  pct=$(sed -n 's/^pct=\([0-9.]*\).*/\1/p' "$ctxf")
  [ -n "$pct" ] || exit 0
fi
if [ "$pct" != unknown ] && awk "BEGIN{exit !($pct < $THRESHOLD)}" &&
   autodev_lock_publish "$STATE/$sid.cycle.lock" "$$"; then
  current_pct=$(sed -n 's/^pct=\([0-9.]*\).*/\1/p' "$ctxf" 2>/dev/null)
  if [ -n "$current_pct" ] && awk "BEGIN{exit !($current_pct < $THRESHOLD)}"; then
    rm -f "$STATE/$sid.busy-deferrals" 2>/dev/null
  fi
  autodev_lock_release_owned "$STATE/$sid.cycle.lock" "$$" || true
fi

# A missing runtime tag means a pre-upgrade Claude Code session. Codex writes
# its tag from the Stop hook and uses the host's explicit `$skill` syntax.
runtime=claude
[ -s "$STATE/$sid.runtime" ] && runtime=$(cat "$STATE/$sid.runtime" 2>/dev/null)
case "$runtime" in
  codex) handoff_cmd='$handoff' ;;
  *) runtime=claude; handoff_cmd='/handoff' ;;
esac

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

# --- trigger gate: pending reload OR over threshold / explicit request ---
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
if [ "$reload_retry" = 1 ]; then
  reason="pending reload"
elif request_valid "$STATE" "$AUTODEV_HOME/handoffs" "$sid" handoff-request; then
  reason=requested
elif remove_stale_request "$STATE" "$AUTODEV_HOME/handoffs" "$sid" handoff-request; then
  log "SKIP stale handoff-request (a compaction is newer than it) — removed (pct=$pct)"
fi
# compact-request is honored only when no full handoff-request is pending (a
# handoff-request means "write a fresh handoff too", which supersedes it).
if [ -z "$reason" ]; then
  if request_valid "$STATE" "$AUTODEV_HOME/handoffs" "$sid" compact-request; then
    reason=compact-requested; compact_only=1
  elif remove_stale_request "$STATE" "$AUTODEV_HOME/handoffs" "$sid" compact-request; then
    log "SKIP stale compact-request (its handoff is missing or predates the last compaction) — removed (pct=$pct)"
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
if [ "$reload_retry" != 1 ] && [ -f "$cdf" ]; then
  last=$(cat "$cdf" 2>/dev/null || echo 0); now=$(date +%s)
  if [ $(( now - last )) -lt "$COOLDOWN" ]; then
    log "SKIP cooldown active (pct=$pct)"; exit 0
  fi
fi

# --- pane registration gate (herdr preferred, tmux fallback) ---
if ! command -v mux_init >/dev/null 2>&1 || ! mux_init "$sid"; then
  mux_mark_unreachable "$sid" "no pane registered (pct=$pct)"
  exit 0
fi
if [ "$MUX" = herdr ]; then
  if ! mux_session_reachable "$sid" &&
     { [ -z "${MUX_OWNER:-}" ] || [ "$MUX_OWNER" = "$sid" ]; }; then exit 0; fi
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
  if [ "$MUX" = herdr ]; then
    # A genuine owner change can retire retry state, but only under the cycle
    # lock and after repeating the evidence check. Unproved ownership retains it.
    reused_lock="$STATE/$sid.cycle.lock"
    if autodev_lock_publish "$reused_lock" "$$"; then
      # Registration may have recovered onto another pane while we waited.
      mux_init "$sid" || true
      owner_now=$(mux_pane_owner)
      if [ -n "$owner_now" ] && [ "$owner_now" != "$sid" ]; then
        if [ -f "$reload_marker" ] || [ -f "$reload_attempt" ]; then
          rm -f "$reload_marker" "$reload_attempt" 2>/dev/null
          log "DROP reload-pending: pane is now owned by session $owner_now"
        fi
      fi
      autodev_lock_release_owned "$reused_lock" "$$" || true
    else
      log "SKIP reload cleanup: cycle lock held"
    fi
    exit 0
  fi
  log "SKIP pane $pane reused by session $owner (not ours) — cleared stale binding (pct=$pct)"
  if [ -f "$reload_marker" ] || [ -f "$reload_attempt" ]; then
    rm -f "$reload_marker" "$reload_attempt" 2>/dev/null
    log "DROP reload-pending: pane is now owned by session $owner"
  fi
  rm -f "$STATE/$sid.$MUX-pane" 2>/dev/null
  exit 0
fi
# Stable label to re-assert after compaction (tmux session name; empty under herdr).
SESSION_NAME=$(mux_session_name)

# --- cycle lock (atomic owner-bearing symlink; blocks recursion + concurrent cycles) ---
# A stale lock is removed only while holding a separate reclaim mutex, so a live
# cycle lock always remains visible to other watchers and the sweeper.
lock="$STATE/$sid.cycle.lock"
handoff_phase="$STATE/$sid.cycle-handoff"
reclaim_mutex="$lock.reclaim"
lock_stale_after=$(( WAIT_IDLE + WAIT_COMPACT ))
reclaim_mutex_stale_after=60

lock_directory_mtime(){ # $1 = lock directory; print mtime in epoch seconds
  local mtime
  mtime=$(stat -c '%Y' "$1" 2>/dev/null) \
    || mtime=$(stat -f '%m' "$1" 2>/dev/null) || return 1
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$mtime"
}

lock_directory_signature(){ # $1 = lock path; lstat identity, type, size, and mtime
  autodev_lock_object_signature "$1"
}

lock_pid_file_signature(){ # $1 = lock path; snapshot its owner representation without following links
  autodev_lock_owner_signature "$1"
}

lock_snapshot_matches(){ # path, pid, readable, directory signature, pid-file signature
  local path=$1 expected_pid=$2 expected_readable=$3 expected_dir_sig=$4 expected_pid_sig=$5
  local current_dir_sig current_pid_sig
  autodev_lock_path_present "$path" || return 1
  if [ -L "$path" ]; then :; else [ -d "$path" ] || return 1; fi
  current_dir_sig=$(lock_directory_signature "$path") || return 1
  [ "$current_dir_sig" = "$expected_dir_sig" ] || return 1
  current_pid_sig=$(lock_pid_file_signature "$path") || return 1
  [ "$current_pid_sig" = "$expected_pid_sig" ] || return 1
  read_lock_pid "$path"
  [ "$lock_pid_readable" = "$expected_readable" ] && [ "$lock_pid" = "$expected_pid" ]
}

lock_directory_age(){ # $1 = lock directory, optional $2 = snapshotted mtime
  local mtime now
  mtime=${2:-}
  [ -n "$mtime" ] || mtime=$(lock_directory_mtime "$1") || return 1
  now=$(date +%s 2>/dev/null) || return 1
  printf '%s\n' "$(( now - mtime ))"
}

read_lock_pid(){ # sets lock_pid and lock_pid_readable for a symlink or legacy directory
  autodev_lock_read_owner "$1"
  lock_pid_readable=$lock_owner_readable
  if [ "$lock_owner_kind" = symlink ]; then
    lock_pid=$lock_owner_pid
  else
    lock_pid=$lock_owner_value
  fi
}

publish_and_verify_lock(){ # publish and verify the owner-bearing symlink at $1
  local rc
  autodev_lock_publish "$1" "$$"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  if [ ! -L "$1" ] || [ "$(readlink "$1" 2>/dev/null || true)" != "$(autodev_lock_token "$$")" ]; then
    return 2
  fi
  return 0
}

release_reclaim_mutex(){
  [ "${reclaim_mutex_owned:-0}" = 1 ] || return 0
  autodev_lock_release_owned "$reclaim_mutex" "$$" || true
  reclaim_mutex_owned=0
}

release_cycle_lock(){
  # Clear our phase while we still exclude successors. A stale owner must never
  # remove a marker belonging to the watcher that replaced it.
  autodev_lock_read_owner "$lock"
  if [ "$lock_owner_pid" = "$$" ] &&
     [ "$(cat "$handoff_phase" 2>/dev/null)" = "$$" ]; then
    rm -f "$handoff_phase" 2>/dev/null
  fi
  autodev_lock_release_owned "$lock" "$$" || true
}

take_reclaim_mutex(){
  local mutex_pid mutex_pid_readable mutex_dir_sig mutex_pid_sig mutex_age rc
  publish_and_verify_lock "$reclaim_mutex"; rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  [ "$rc" -eq 2 ] && return 2
  autodev_lock_path_present "$reclaim_mutex" || return 1
  if [ -L "$reclaim_mutex" ]; then :; else [ -d "$reclaim_mutex" ] || return 1; fi

  read_lock_pid "$reclaim_mutex"
  mutex_pid=$lock_pid
  mutex_pid_readable=$lock_pid_readable
  mutex_dir_sig=$(lock_directory_signature "$reclaim_mutex") || return 1
  mutex_pid_sig=$(lock_pid_file_signature "$reclaim_mutex") || return 1
  if [ "$mutex_pid_readable" = 1 ] && autodev_lock_pid_is_canonical "$mutex_pid"; then
    if kill -0 "$mutex_pid" 2>/dev/null; then
      return 1
    fi
    # A normal reclaimer removes its mutex before exiting. If its PID is dead,
    # the same recorded PID and directory must remain, or a replacement owner
    # acquired the mutex during this check.
  fi
  mutex_age=$(lock_directory_age "$reclaim_mutex" "${mutex_dir_sig##*:}") || return 1
  [ "$mutex_age" -ge "$reclaim_mutex_stale_after" ] || return 1
  if ! lock_snapshot_matches "$reclaim_mutex" "$mutex_pid" "$mutex_pid_readable" \
      "$mutex_dir_sig" "$mutex_pid_sig"; then
    return 1
  fi
  # Concurrent stale-mutex recovery can race while removing/recreating the mutex.
  # That second-order window requires a prior reclaimer crash to leave it stale;
  # normal reclaim takes milliseconds, so the mutex is otherwise live and protected.
  if [ -L "$reclaim_mutex" ]; then
    rm -f "$reclaim_mutex" 2>/dev/null || return 1
  else
    rm -rf "$reclaim_mutex" 2>/dev/null || return 1
  fi
  publish_and_verify_lock "$reclaim_mutex"
}

publish_and_verify_lock "$lock"
lock_publish_rc=$?
if [ "$lock_publish_rc" -eq 0 ]; then
  :
else
  if [ "$lock_publish_rc" -eq 2 ]; then
    log "SKIP cycle lock ownership changed after atomic publication (pct=$pct)"; exit 0
  fi
  take_reclaim_mutex
  mutex_acquire_rc=$?
  if [ "$mutex_acquire_rc" -ne 0 ]; then
    if [ "$mutex_acquire_rc" -eq 2 ]; then
      log "SKIP reclaim mutex ownership could not be verified (pct=$pct)"
    else
      log "SKIP cycle already in progress or reclaim mutex held (pct=$pct)"
    fi
    exit 0
  fi
  reclaim_mutex_owned=1
  trap 'release_reclaim_mutex' EXIT

  stale_lock=0
  if autodev_lock_path_present "$lock"; then
    if [ -L "$lock" ]; then :; else
      if [ ! -d "$lock" ]; then
        log "SKIP cycle lock path is not a legacy directory (pct=$pct)"; exit 0
      fi
    fi
    read_lock_pid "$lock"
    lpid=$lock_pid
    lpid_readable=$lock_pid_readable
    lock_dir_sig=$(lock_directory_signature "$lock") || {
      log "SKIP cycle lock identity unavailable (pct=$pct)"; exit 0;
    }
    lock_pid_sig=$(lock_pid_file_signature "$lock") || {
      log "SKIP cycle lock PID identity unavailable (pct=$pct)"; exit 0;
    }
    if [ "$lpid_readable" = 1 ] && autodev_lock_pid_is_canonical "$lpid"; then
      if kill -0 "$lpid" 2>/dev/null; then
        log "SKIP cycle already in progress (pid $lpid, pct=$pct)"; exit 0
      fi
      # A normal owner removes its own lock before exiting. If its PID is now
      # dead but this same directory still names it, it was left by a crash;
      # with reclaimers excluded by the mutex and the sweeper never deleting an
      # unowned lock, nothing can replace it between this recheck and rm.
      if ! lock_snapshot_matches "$lock" "$lpid" "$lpid_readable" \
          "$lock_dir_sig" "$lock_pid_sig"; then
        log "SKIP cycle lock changed during stale recheck (pct=$pct)"; exit 0
      fi
      stale_lock=1
    else
      lock_age=$(lock_directory_age "$lock" "${lock_dir_sig##*:}") || {
        log "SKIP cycle lock age unavailable (pct=$pct)"; exit 0;
      }
      if [ "$lock_age" -ge "$lock_stale_after" ]; then
        if ! lock_snapshot_matches "$lock" "$lpid" "$lpid_readable" \
            "$lock_dir_sig" "$lock_pid_sig"; then
          log "SKIP cycle lock changed during stale recheck (pct=$pct)"; exit 0
        fi
        stale_lock=1
      else
        log "SKIP cycle in progress (legacy lock, age ${lock_age}s, pct=$pct)"; exit 0
      fi
    fi

    if [ "$stale_lock" = 1 ]; then
      lock_holder=$lpid
      if [ "$lpid_readable" != 1 ]; then lock_holder=unreadable
      elif ! autodev_lock_pid_is_canonical "$lpid"; then lock_holder=none
      fi
      log "reclaim stale cycle lock (holder $lock_holder, age ${lock_age:-unknown}, pct=$pct)"
      # The mutex is the sole authority to remove a rechecked stale cycle lock.
      if [ -L "$lock" ]; then
        rm -f "$lock" 2>/dev/null || {
          log "SKIP cycle lock reclaim failed (pct=$pct)"; exit 0;
        }
      else
        rm -rf "$lock" 2>/dev/null || {
          log "SKIP cycle lock reclaim failed (pct=$pct)"; exit 0;
        }
      fi
    fi
  fi

  # A fast-path watcher or the sweeper may win after removal; only ln's winner
  # proceeds, and owner readback below confirms the path still belongs to us.
  publish_and_verify_lock "$lock"
  lock_publish_rc=$?
  if [ "$lock_publish_rc" -ne 0 ]; then
    if [ "$lock_publish_rc" -eq 2 ]; then
      log "SKIP cycle lock ownership changed after reclaim (pct=$pct)"
    else
      log "SKIP cycle lock race after reclaim (pct=$pct)"
    fi
    exit 0
  fi
  release_reclaim_mutex
  trap - EXIT
fi

trap 'release_cycle_lock' EXIT

# Ownership can change while we wait for the lock. Never drive a pre-lock snapshot.
if [ "$MUX" = herdr ]; then
  mux_session_reachable "$sid" || exit 0
  pane="$PANE"
fi

# A staged tmux literal locks every send for this session, even if a newer
# request superseded the reload marker. Only a completed turn that is strictly
# newer than the attempt proves the input was consumed and releases the lock.
clear_reload_attempt_if_consumed(){
  [ "$MUX" = tmux ] || return 0
  [ -f "$reload_attempt" ] && [ -f "$STATE/$sid.idle" ] || return 0
  if [ "$STATE/$sid.idle" -nt "$reload_attempt" ]; then
    rm -f "$reload_attempt" 2>/dev/null
    log "CLEAR tmux staged-input lock: newer idle turn consumed prior input"
  fi
}
refile_consumed_request(){
  [ "$landed" = 0 ] && [ -n "${consumed:-}" ] || return 0
  # Never overwrite a request filed in the meantime; that one is newer.
  if [ ! -e "$consumed" ]; then
    rtmp="$consumed.refile.$$"
    { : > "$rtmp" && touch -d "@$consumed_mtime" "$rtmp" && mv -n "$rtmp" "$consumed"; } 2>/dev/null
    rm -f "$rtmp" 2>/dev/null
  fi
}
defer_staged_input(){ # $1 = action blocked by a prior possibly staged literal
  refile_consumed_request
  : > "$STATE/$sid.deferred" 2>/dev/null
  log "DEFER $1: tmux staged-input lock is active; refusing every send until a newer idle turn or pane-owner change"
  exit 0
}
clear_reload_attempt_if_consumed
if [ -f "$reload_attempt" ]; then
  log "DEFER tmux staged-input lock: inspect the pane; no session sends are allowed"
  exit 0
fi
if [ "$reload_superseded" = 1 ]; then exit 0; fi

# --- idle helpers (pre-send safety gate; avoids queuing into a busy agent) ---
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

# The pane is showing a question or prompt put to the HUMAN. Typing now would
# answer it, so stand down exactly as for a busy pane: no cooldown, no abort
# count, and the sweeper re-invokes us later. Nothing here ever escalates into
# sending anyway. If nothing has reached the pane yet this cycle, re-file the
# request marker consumed at TRIGGER (with its original age), so the refusal
# costs a retry, not the request.
landed=0
post_compaction=0
pending_reload_line=""
save_reload_pending(){
  local tmp="$reload_marker.tmp.$$"
  [ -n "$pending_reload_line" ] || return 1
  printf '%s\n' "$pending_reload_line" > "$tmp" 2>/dev/null &&
    mv -f "$tmp" "$reload_marker" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}
save_reload_attempt(){ # $1 = attempting|staged; atomically persist ambiguous send state
  local value=$1 tmp="$reload_attempt.tmp.$$"
  printf '%s\n' "$value" > "$tmp" 2>/dev/null &&
    mv -f "$tmp" "$reload_attempt" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}
defer_awaiting(){ # $1 = where
  local guard=${MUX_REFUSAL_REASON:-dialog}
  if [ "$post_compaction" = 1 ]; then
    if save_reload_pending; then
      log "RELOAD-PENDING saved after $1"
    else
      log "ERROR could not save reload-pending after $1"
    fi
  fi
  refile_consumed_request
  : > "$STATE/$sid.deferred" 2>/dev/null   # the sweeper pages on a long-pending, only-deferred request
  if [ "$guard" = dialog ]; then
    log "DEFER awaiting-human ($1): pane shows an open question/permission prompt pct=$pct — retry next sweep"
  else
    log "DEFER $guard ($1): send guard refused pct=$pct — retry next sweep"
  fi
  exit 0
}

send(){ # send one literal line + Enter to the registered pane (via herdr/tmux)
  local text="$1" rc track_reload=0 track_tmux=0
  if [ "$DRY" = 1 ]; then
    log "DRY would send: [$text]"
  else
    # This runs under the cycle lock. Repeat the staged-input check here so a
    # watcher that passed the pre-lock observation cannot append after another
    # watcher staged a literal in the intervening window.
    clear_reload_attempt_if_consumed
    [ "$MUX" != tmux ] || [ ! -f "$reload_attempt" ] || defer_staged_input "send [$text] refused"
    if [ "$post_compaction" = 1 ]; then
      if ! save_reload_pending; then
        abort_cycle "could not persist reload before post-compaction send"
      fi
      track_reload=1
    fi
    if [ "$MUX" = tmux ]; then
      if ! save_reload_attempt attempting; then
        abort_cycle "could not persist tmux send state"
      fi
      track_tmux=1
      MUX_ATTEMPT_SEND=1
    fi
    mux_send_line "$text" 2>>"$LOG"; rc=$?
    MUX_ATTEMPT_SEND=0
    if [ "$track_tmux" = 1 ]; then
      if [ "$rc" = 0 ]; then
        rm -f "$reload_attempt" 2>/dev/null
        [ "$track_reload" = 0 ] || rm -f "$reload_marker" 2>/dev/null
      elif [ "${MUX_LINE_STAGED:-0}" = 1 ]; then
        save_reload_attempt staged || log "ERROR could not update tmux reload-send state; retaining attempting state"
        log "TMUX input may contain staged text; every session send is locked pending inspection"
      else
        rm -f "$reload_attempt" 2>/dev/null
        log "TMUX send returned without staging; input lock cleared"
      fi
    elif [ "$track_reload" = 1 ] && [ "$rc" = 0 ]; then
      rm -f "$reload_marker" 2>/dev/null
    fi
    [ "$rc" = "${MUX_REFUSED:-3}" ] && defer_awaiting "refused [$text]"
    [ "$rc" = 0 ] || abort_cycle "send failed for [$text]"
    landed=1
    log "SENT: [$text]"
  fi
}

# The sweep re-arms this watcher for a refused reload. Retry under the same
# cycle lock and pane-owner check as a normal cycle, and through mux_send_line's
# last-moment human-input guard. Do not queue behind an active turn: once it
# completes, its newer .idle marker retires this stale reload instead.
if [ "$reload_retry" = 1 ]; then
  retired=$(reload_marker_retire_reason "$STATE" "$AUTODEV_HOME/handoffs" "$sid" "$reload_marker" || true)
  case "$retired" in
    new-handoff-request)
      rm -f "$reload_marker" 2>/dev/null
      log "DROP reload-pending: a newer handoff request superseded it"
      exit 0
      ;;
    new-handoff|completed-turn)
      rm -f "$reload_marker" 2>/dev/null
      log "DROP reload-pending: superseded by $retired"
      exit 0
      ;;
  esac
  [ -f "$reload_marker" ] || exit 0
  stored_reload_line=$(cat "$reload_marker" 2>/dev/null) || stored_reload_line=""
  prepare_reload_line
  case "$stored_reload_line" in *$'\n'*) log "DEFER reload-pending: malformed marker has multiple lines"; exit 0 ;; esac
  if [ -z "$stored_reload_line" ] || [ "$stored_reload_line" != "$pending_reload_line" ]; then
    log "DEFER reload-pending: malformed or superseded payload; retaining it"
    exit 0
  fi
  if [ "$DRY" = 1 ]; then
    log "DRY would retry reload-pending"
    exit 0
  fi
  if pane_busy; then
    log "DEFER reload-pending: ${MUX_BUSY_REASON:-busy} guard refused; marker retained"
    exit 0
  fi
  clear_reload_attempt_if_consumed
  if [ -f "$reload_attempt" ]; then
    defer_staged_input "reload retry refused"
  fi
  if [ "$MUX" = tmux ] && ! save_reload_attempt attempting; then
    log "DEFER reload-pending: could not persist tmux send state; marker retained"
    exit 0
  fi
  [ "$MUX" != tmux ] || MUX_ATTEMPT_SEND=1
  mux_send_line "$pending_reload_line" 2>>"$LOG"; rc=$?
  MUX_ATTEMPT_SEND=0
  if [ "$MUX" = tmux ]; then
    if [ "$rc" = 0 ]; then
      rm -f "$reload_marker" "$reload_attempt" 2>/dev/null
    elif [ "${MUX_LINE_STAGED:-0}" = 1 ]; then
      save_reload_attempt staged || log "ERROR could not update tmux reload-send state; retaining attempting state"
      log "DEFER reload-pending: prior tmux send may have left text staged; inspect the pane before retrying"
    else
      rm -f "$reload_attempt" 2>/dev/null
      log "DEFER reload-pending: tmux send returned without staging; retry is safe"
    fi
  fi
  if [ "$rc" = 0 ]; then
    rm -f "$reload_marker" "$reload_attempt" 2>/dev/null
    date +%s > "$cdf" 2>/dev/null
    rm -f "$STATE/$sid.abort-count" "$STATE/$sid.stuck" 2>/dev/null
    log "RELOAD retry sent"
  elif [ "$rc" = "${MUX_REFUSED:-3}" ]; then
    log "DEFER reload-pending: ${MUX_REFUSAL_REASON:-unknown} guard refused (reload retry); marker retained"
  else
    log "DEFER reload retry send failed rc=$rc; marker retained"
  fi
  exit 0
fi

sleep "$SETTLE"

# --- Pre-send gate: never answer the human's open question. Checked before the
# busy gate because waiting it out is pointless: it clears only when the human
# answers, and mux_busy would report it as busy and then log the wrong reason.
if [ "$DRY" = 0 ] && mux_awaiting_human; then defer_awaiting "pre-send"; fi

# --- Pre-send idle gate: never inject into a busy session (it would queue). ---
if [ "$DRY" = 0 ] && pane_busy; then
  if ! wait_pane_idle "$PRECHECK"; then
    : > "$STATE/$sid.deferred" 2>/dev/null
    # Serialized by the cycle lock. Three consecutive failed idle windows hand
    # control back to the session's Stop hook instead of waiting forever.
    busy_n=$(cat "$STATE/$sid.busy-deferrals" 2>/dev/null || echo 0)
    [ "$STATE/$sid.compacted" -nt "$STATE/$sid.busy-deferrals" ] && busy_n=0
    case "$busy_n" in ''|*[!0-9]*) busy_n=0 ;; esac
    busy_n=$(( busy_n < 3 ? busy_n + 1 : 3 ))
    printf '%s\n' "$busy_n" > "$STATE/$sid.busy-deferrals"
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

rm -f "$STATE/$sid.busy-deferrals" 2>/dev/null
rm -f "$STATE/$sid.deferred" 2>/dev/null   # committed to the cycle: no longer merely deferring
log "TRIGGER ($reason) pct=$pct thr=$THRESHOLD pane=$pane dry=$DRY"
# Consume an explicit request NOW that we're committed to the cycle — before any
# send. A post-send abort (/handoff or /compact may already have landed) must NOT
# leave the marker to re-fire on the reloaded, already-compacted session; a fresh
# request is required to retry. Only touch the marker when it is what triggered us,
# so a request dropped DURING a threshold cycle survives to be honored next idle.
consumed=""
if [ "$reason" = requested ]; then
  consumed="$req"; consumed_mtime=$(date -r "$req" +%s.%N 2>/dev/null || date +%s)
  rm -f "$req" 2>/dev/null
  [ -f "$req" ] && log "WARN could not remove handoff-request $req — may re-fire after cooldown"
elif [ "$reason" = compact-requested ]; then
  consumed="$creq"; consumed_mtime=$(date -r "$creq" +%s.%N 2>/dev/null || date +%s)
  rm -f "$creq" 2>/dev/null
  [ -f "$creq" ] && log "WARN could not remove compact-request $creq — may re-fire after cooldown"
fi

# 1) handoff — skipped in compact-only mode (a handoff is already written).
if [ "$compact_only" = 1 ]; then
  log "compact-only: skipping handoff (already written by session)"
else
  t0=$(date +%s)
  # A live cycle lock alone also describes housekeeping. Mark the handoff phase
  # before sending so its tool calls cannot start delegated/background work.
  if [ "$DRY" = 0 ] && ! printf '%s\n' "$$" > "$handoff_phase"; then
    refile_consumed_request
    abort_cycle "could not record handoff phase"
  fi
  send "$handoff_cmd"
  if [ "$DRY" = 0 ]; then
    if ! wait_turn_done "$t0" "$WAIT_IDLE"; then
      mux_awaiting_human && defer_awaiting "after /handoff"
      abort_cycle "handoff did not complete within ${WAIT_IDLE}s"
    fi
    log "handoff turn completed"
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
      log "legacy handoff: adopted .latest by mtime proof (written during our turn)"
    else
      rm -f "$per" 2>/dev/null
      log "WARN handoff wrote no per-session pointer, and .latest is not provably ours"
    fi
  fi
fi

# 2) compact (only when idle)
if [ "$DRY" = 0 ] && ! wait_pane_idle 60; then
  mux_awaiting_human && defer_awaiting "before /compact"
  abort_cycle "pane busy before /compact"
fi
t1=$(date +%s)
send "/compact"
if [ "$DRY" = 0 ]; then
  # Codex versions that present a compact confirmation remain idle/blocked at a
  # prompt rather than emitting SessionStart. Confirm only when the visible pane
  # contains an explicit compact/summarize question; never send Enter blindly.
  if [ "$runtime" = codex ]; then
    confirm_deadline=$(( $(date +%s) + ${AUTODEV_CODEX_CONFIRM_WAIT:-5} ))
    while [ "$(date +%s)" -lt "$confirm_deadline" ]; do
      [ -f "$STATE/$sid.compacted" ] && break
      compact_prompt=$(mux_capture | tail -30)
      if printf '%s\n' "$compact_prompt" | grep -Eiq \
        'confirm.*compact|compact.*context|summari[sz]e.*(chat|context)|press enter.*compact'; then
        mux_send_key --own-prompt Enter   # the dialog our own /compact just opened
        log "confirmed Codex /compact prompt"
        break
      fi
      sleep 1
    done
  fi
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
  # A compact-request filed before this compaction landed asked for exactly what
  # just happened. The usual source is the handoff skill running
  # `request-handoff.sh --compact-only` inside the /handoff turn we drove: its
  # mid-cycle deferral tests our lock pid with `kill -0`, which cannot see this
  # process from a sandboxed session (separate PID namespace), so it files the
  # marker anyway. Left in place, it fires a second /compact on the freshly
  # reloaded session once the cooldown lapses. Drop it here, where the cycle
  # knows it compacted. A request filed after the compaction completed is a new
  # ask and stays. Compare against the .compacted file's mtime with `-newer`, not
  # against the epoch second it contains, which ties with a request filed in the
  # compaction's own second. Drop only when the stamp is strictly newer: an equal
  # mtime (one coarse clock tick) cannot be ordered, and keeping it costs at most a
  # spare /compact where dropping a real ask parks the session. Claim the marker by
  # rename first, so a request filed between the check and the delete is never the
  # one deleted.
  done_stamp="$STATE/$sid.compacted"; claim="$creq.claim.$$"
  if [ -f "$done_stamp" ] && mv "$creq" "$claim" 2>/dev/null; then
    if [ -n "$(find "$done_stamp" -newer "$claim" 2>/dev/null)" ]; then
      rm -f "$claim" 2>/dev/null
      log "DROP compact-request filed during this cycle (superseded by this /compact)"
    else
      mv -n "$claim" "$creq" 2>/dev/null; rm -f "$claim" 2>/dev/null
    fi
  fi
fi

# 3) re-assert the session name (compaction can reset the display title), then continue.
# Prepare the reload before any post-compaction send so a refusal of /rename also
# leaves the required reload durable. Refresh again after rename before sending.
prepare_reload_line
post_compaction=1
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
prepare_reload_line
if [ "$reload_has_handoff" = 1 ]; then
  send "$pending_reload_line"
else
  log "WARN reloaded with no per-session pointer (.latest.$sid) — sent the fail-closed prompt"
  send "$pending_reload_line"
fi

# 4) stamp cooldown and finish. (An explicit request was already consumed at
#    TRIGGER, so nothing to clean up here.) A completed cycle clears the
#    consecutive-abort counter and any stuck flag the sweeper raised.
date +%s > "$cdf"
rm -f "$STATE/$sid.abort-count" "$STATE/$sid.stuck" 2>/dev/null
log "CYCLE COMPLETE ($reason, dry=$DRY)"
exit 0
