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
[ -f "$_HERE/lock-lib.sh" ] && . "$_HERE/lock-lib.sh" || exit 0
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
# The threshold alone must stop a busy session: the gate keys on a request file
# and the watcher only types into an idle pane, so a session that crosses
# THRESHOLD inside one long turn and never files its own request would run on
# until the turn ends. Past BUSY_MIN minutes of continuous work the sweep files
# the request for it. Anything but a positive integer falls back to the default
# (never to "off" or "immediately").
positive_integer_or_default(){
  local value=$1 fallback=$2
  case "$value" in ''|*[!0-9]*) printf '%s\n' "$fallback"; return ;; esac
  while [ "${value#0}" != "$value" ]; do value=${value#0}; done
  if [ -z "$value" ] || [ "${#value}" -gt 9 ]; then value=$fallback; fi
  printf '%s\n' "$value"
}
BUSY_MIN=$(positive_integer_or_default "${AUTODEV_BUSY_MINUTES:-20}" 20)
# Continuity: the sweep is the only observer, so two observations further apart
# than this (a skipped sweep, a stopped timer) do not prove the pane stayed busy.
BUSY_GAP=$(positive_integer_or_default "${AUTODEV_BUSY_GAP:-600}" 600)

log(){ printf '%s [%s] %s\n' "$(date +'%Y.%m.%d %H.%M.%S')" "$1" "$2" >> "$LOG"; }

# Global kill switch beats everything.
[ -f "$STATE/disable-auto-compact" ] && exit 0

now=$(date +%s)
mtime(){ date -r "$1" +%s 2>/dev/null || echo 0; }
fresh(){ [ -f "$1" ] && [ "$(( now - $(mtime "$1") ))" -le "$2" ]; }

# Take the per-session cycle lock only when its directory does not already
# exist. The watcher owns stale-lock reclamation; a sweep never removes a lock.
cycle_lock_take(){ # $1 = cycle lock path
  autodev_lock_publish "$1" "$$"
}

cycle_lock_release(){ # $1 = cycle lock path; release only our recorded lock
  autodev_lock_release_owned "$1" "$$"
}

cycle_lock_block_reason(){ # $1 = cycle lock path
  local lpid
  autodev_lock_path_present "$1" || { printf 'could not create lock'; return; }
  autodev_lock_read_owner "$1"
  lpid=$lock_owner_pid
  if [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null; then
    printf 'held by live pid %s' "$lpid"
  elif [ -n "$lock_owner_value" ]; then
    printf 'present with stale pid %s' "$lock_owner_value"
  else
    printf 'present without pid file'
  fi
}

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
  local sid=$1 kind=$2 rf key age msg pending=""
  if [ "$kind" = reload-attempt ]; then rf="$STATE/$sid.reload-attempt"
  else rf="$STATE/$sid.$kind"; fi
  [ -f "$rf" ] || return 0
  key="$kind:$(date -r "$rf" +%s%N 2>/dev/null)"
  [ "$(cat "$STATE/$sid.paged" 2>/dev/null)" = "$key" ] && return 0
  age=$(( (now - $(mtime "$rf")) / 60 ))
  if [ -f "$STATE/$sid.reload-attempt" ]; then
    [ -f "$STATE/$sid.reload-pending" ] && pending="reload retry"
    [ -f "$STATE/$sid.handoff-request" ] && pending="${pending:+$pending, }handoff-request"
    [ -f "$STATE/$sid.compact-request" ] && pending="${pending:+$pending, }compact-request"
    if [ -n "$pending" ]; then pending=" Pending work also waiting: $pending."; fi
    msg="autodev: tmux input for session $sid may contain staged text after $age min; inspect the pane before submitting anything.$pending"
  elif [ "$kind" = reload-pending ]; then
    msg="autodev: reload for session $sid pending $age min and the watcher keeps deferring (busy pane or open prompt) — continue it by hand"
  else
    msg="autodev: $kind for session $sid pending $age min and the watcher keeps deferring (busy pane or open prompt) — compact it by hand"
  fi
  # Record BEFORE paging, and refuse to page if the record cannot be kept: an
  # unrecorded page repeats on every sweep.
  if ! printf '%s\n' "$key" > "$STATE/$sid.paged" 2>/dev/null; then
    log "$sid" "PAGE-SKIP cannot record $STATE/$sid.paged — not paging (would repeat every sweep): $msg"
    return 0
  fi
  log "$sid" "PAGE $msg"
  # A timer-run sweeper has no session bus in its environment; point at the user's.
  [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "/run/user/$(id -u)/bus" ] &&
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus" && export DBUS_SESSION_BUS_ADDRESS
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
  reload_marker="$STATE/$sid.reload-pending"
  reload_attempt="$STATE/$sid.reload-attempt"
  lock="$STATE/$sid.cycle.lock"
  reload_retired_exit=0
  if [ -f "$reload_attempt" ] && [ -f "$STATE/$sid.idle" ] &&
     [ "$STATE/$sid.idle" -nt "$reload_attempt" ]; then
    if cycle_lock_take "$lock"; then
      if [ -f "$reload_attempt" ] && [ -f "$STATE/$sid.idle" ] &&
         [ "$STATE/$sid.idle" -nt "$reload_attempt" ]; then
        rm -f "$reload_attempt" 2>/dev/null
        log "$sid" "CLEAR tmux staged-input lock: newer idle turn consumed prior input"
      fi
      cycle_lock_release "$lock" || log "$sid" "ERROR could not release cycle lock after reload cleanup"
    else
      log "$sid" "SKIP reload cleanup: cycle lock $(cycle_lock_block_reason "$lock")"
    fi
  fi

  # A request is stale when satisfied (see request-lib.sh), never by age. Cleaned
  # before the pane checks so a dead session's leftovers go too.
  for kind in handoff-request compact-request; do
    if [ -f "$STATE/$sid.$kind" ] && remove_stale_request "$STATE" "$AUTODEV_HOME/handoffs" "$sid" "$kind"; then
      log "$sid" "SKIP stale $kind (handoff missing or predates the last compaction) — removed"
    fi
  done

  # Phoenix owns sessions that are waiting out a usage limit; typing at them
  # would only queue input behind a blocked prompt.
  if [ -f "$STATE/$sid.limit-wait" ]; then
    # The pane is waiting on a usage-limit reset, not continuously working.
    rm -f "$STATE/$sid.busy-since" 2>/dev/null
    continue
  fi

  # A reload is independent of context percentage and may outlive cooldown.
  # Retire it before paging/retrying if the session moved on or wrote a newer
  # handoff; the watcher repeats this check under the cycle lock.
  reload_pending=0
  if [ -f "$reload_marker" ]; then
    if cycle_lock_take "$lock"; then
      if [ -f "$reload_marker" ]; then
        retired=""
        command -v reload_marker_retire_reason >/dev/null 2>&1 &&
          retired=$(reload_marker_retire_reason "$STATE" "$AUTODEV_HOME/handoffs" "$sid" "$reload_marker" || true)
        case "$retired" in
          new-handoff-request)
            rm -f "$reload_marker" 2>/dev/null
            log "$sid" "DROP reload-pending: a newer handoff request superseded it"
            ;;
          new-handoff|completed-turn)
            rm -f "$reload_marker" 2>/dev/null
            log "$sid" "DROP reload-pending: superseded by $retired"
            reload_retired_exit=1
            ;;
          *) reload_pending=1 ;;
        esac
      fi
      cycle_lock_release "$lock" || log "$sid" "ERROR could not release cycle lock after reload cleanup"
    else
      reload_pending=1
      log "$sid" "SKIP reload cleanup: cycle lock $(cycle_lock_block_reason "$lock")"
    fi
  fi

  # A cycle genuinely in flight must not be piled onto. Reload cleanup above
  # took and released its own lock before this check.
  if autodev_lock_path_present "$lock"; then
    autodev_lock_read_owner "$lock"
    lpid=$lock_owner_pid
    [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null && continue
  fi
  # Dry-run threshold previews need a fresh busy observation every sweep. The
  # real watcher completes a dry cycle and stamps cooldown, but that cooldown
  # is longer than BUSY_GAP and would keep resetting the preview clock. Bypass
  # it only for an unarmed, over-threshold session with no pending request.
  dry_preview=0
  if [ -f "$STATE/$sid.cooldown" ] && [ ! -f "$STATE/auto-handoff.armed" ] \
     && [ ! -f "$STATE/$sid.handoff-request" ] && [ ! -f "$STATE/$sid.compact-request" ] \
     && [ -f "$STATE/$sid.ctx" ]; then
    cooldown_pct=$(sed -n 's/^pct=\([0-9.]*\).*/\1/p' "$STATE/$sid.ctx")
    if [ -n "$cooldown_pct" ] && awk "BEGIN{exit !($cooldown_pct > $THRESHOLD)}"; then
      dry_preview=1
    fi
  fi
  if fresh "$STATE/$sid.cooldown" "$COOLDOWN" && [ "$dry_preview" = 0 ] &&
     [ "$reload_pending" = 0 ] && [ ! -f "$reload_attempt" ]; then
    continue
  fi

  # A session whose cycles keep aborting is wedged, not slow. Stop driving it and
  # make it VISIBLE — a wedged session whose pane still reads healthy is the
  # failure mode this whole harness exists to prevent.
  aborts=0
  [ -f "$STATE/$sid.abort-count" ] && aborts=$(cat "$STATE/$sid.abort-count" 2>/dev/null || echo 0)
  case "$aborts" in ''|*[!0-9]*) aborts=0 ;; esac
  if [ "$aborts" -ge "$MAX_ABORTS" ] && [ "$reload_pending" = 0 ] &&
     [ ! -f "$reload_attempt" ]; then
    if [ ! -f "$STATE/$sid.stuck" ]; then
      printf 'aborted %s consecutive auto-handoff cycles\n' "$aborts" > "$STATE/$sid.stuck"
      log "$sid" "STUCK after $aborts consecutive aborted cycles — no longer auto-retrying (status line flags it)"
    fi
    continue
  fi

  # --- is there anything to do? ---------------------------------------------
  reason=""; thr=0
  if [ -f "$reload_attempt" ]; then
    reason="staged tmux input"
  elif [ "$reload_pending" = 1 ]; then
    reason="pending reload"
  elif [ -f "$STATE/$sid.handoff-request" ]; then
    reason="pending handoff-request"
    rm -f "$STATE/$sid.busy-since" 2>/dev/null
  elif [ -f "$STATE/$sid.compact-request" ]; then
    reason="pending compact-request"
    rm -f "$STATE/$sid.busy-since" 2>/dev/null
  else
    ctxf="$STATE/$sid.ctx"
    [ -f "$ctxf" ] || { rm -f "$STATE/$sid.busy-since" 2>/dev/null; continue; }
    pct=$(sed -n 's/^pct=\([0-9.]*\).*/\1/p' "$ctxf")
    [ -n "$pct" ] || { rm -f "$STATE/$sid.busy-since" 2>/dev/null; continue; }
    if awk "BEGIN{exit !($pct > $THRESHOLD)}"; then
      reason="pct=$pct > $THRESHOLD"; thr=1
    else
      # The busy clock only measures stretches that qualify for the threshold
      # path; time below threshold cannot contribute to a later stretch.
      rm -f "$STATE/$sid.busy-since" 2>/dev/null
    fi
    if [ "$thr" = 0 ] && [ ! -f "$STATE/disable-cold-cache-compact" ] \
         && awk "BEGIN{exit !($pct > $COLD_MIN)}" \
         && [ -f "$STATE/$sid.idle" ] \
         && [ "$(( now - $(cat "$STATE/$sid.idle" 2>/dev/null || echo "$now") ))" -ge "$CACHE_TTL" ]; then
      reason="pct=$pct > $COLD_MIN, idle >= ${CACHE_TTL}s (cold-cache)"
    elif [ "$thr" = 0 ] && [ -z "$reason" ]; then
      continue
    fi
    # Re-confirm the exception after selecting the trigger: if a request arrived
    # during the cooldown pre-check, this is no longer a dry threshold preview.
    if [ "$thr" != 1 ] || [ -f "$STATE/auto-handoff.armed" ]; then
      dry_preview=0
    fi
    # Guard against re-compacting an idle session forever: once a cycle has
    # COMPLETED, only fire again if the session has actually done something
    # since (its context reading moved). A session with aborted cycles is
    # exempt — retrying those is precisely the bug this sweeper fixes. Binds
    # BOTH branches above (threshold and cold-cache) — without it a session
    # sitting above COLD_MIN and idle would get compacted every COOLDOWN
    # period forever.
    if [ "$aborts" -eq 0 ] && [ -f "$STATE/$sid.cooldown" ] &&
       [ "$(mtime "$ctxf")" -le "$(mtime "$STATE/$sid.cooldown")" ] &&
       [ "$dry_preview" = 0 ]; then
      continue
    fi
  fi

  # --- stuck request: pending >= PAGE_AFTER and the watcher has only DEFERred ----
  # Page once per request. Its identity is its mtime in ns (a re-filed request has
  # a new one; the watcher's DEFER re-file restores the original exactly). The
  # DEFER must be newer than the request — an older one says nothing about it.
  for kind in handoff-request compact-request; do
    [ -f "$reload_attempt" ] && continue
    rf="$STATE/$sid.$kind"
    [ -f "$rf" ] && [ "$STATE/$sid.deferred" -nt "$rf" ] || continue
    [ "$(( now - $(mtime "$rf") ))" -ge "$PAGE_AFTER" ] || continue
    page_stuck "$sid" "$kind"
  done

  # --- the pane must be live AND still ours ---------------------------------
  # mux_pane_live only proves the pane exists; herdr recycles short pane ids, so
  # a live pane may now host a DIFFERENT session. Driving it would type /compact
  # into somebody else's work.
  if ! mux_init "$sid"; then
    [ "$thr" = 1 ] && rm -f "$STATE/$sid.busy-since" 2>/dev/null
    continue
  fi
  if [ "$MUX" = herdr ] && ! mux_session_reachable "$sid" &&
     { [ -z "${MUX_OWNER:-}" ] || [ "$MUX_OWNER" = "$sid" ]; }; then
    [ "$thr" = 1 ] && rm -f "$STATE/$sid.busy-since" 2>/dev/null
    continue
  fi
  if ! mux_pane_live; then
    [ "$thr" = 1 ] && rm -f "$STATE/$sid.busy-since" 2>/dev/null
    continue
  fi
  owner=$(mux_pane_owner)
  if [ -n "$owner" ] && [ "$owner" != "$sid" ]; then
    if [ "$reload_pending" = 1 ] || [ -f "$reload_attempt" ]; then
      if cycle_lock_take "$lock"; then
        owner_now=$(mux_pane_owner)
        if [ -n "$owner_now" ] && [ "$owner_now" != "$sid" ] &&
           { [ "$reload_pending" = 1 ] || [ -f "$reload_attempt" ]; }; then
          rm -f "$reload_marker" "$reload_attempt" 2>/dev/null
          log "$sid" "DROP reload-pending: pane is now owned by session $owner_now"
        fi
        cycle_lock_release "$lock" || log "$sid" "ERROR could not release cycle lock after reload cleanup"
      else
        log "$sid" "SKIP reload cleanup: cycle lock $(cycle_lock_block_reason "$lock")"
      fi
    fi
    [ "$thr" = 1 ] && rm -f "$STATE/$sid.busy-since" 2>/dev/null
    continue
  fi

  if [ -f "$reload_attempt" ]; then
    if [ "$(( now - $(mtime "$reload_attempt") ))" -ge "$PAGE_AFTER" ]; then
      if [ -f "$reload_marker" ]; then page_stuck "$sid" reload-pending
      else page_stuck "$sid" reload-attempt; fi
    fi
    log "$sid" "DEFER tmux staged-input lock: refusing all session sends until a newer idle turn or pane-owner change"
    continue
  fi
  [ "$reload_retired_exit" = 1 ] && continue
  if [ "$reload_pending" = 1 ] && [ "$(( now - $(mtime "$reload_marker") ))" -ge "$PAGE_AFTER" ]; then
    page_stuck "$sid" reload-pending
  fi

  # --- over threshold and working: raise the request the session never filed --
  # Only on the plain threshold path: a pending request (either kind) never gets
  # here with thr=1, and limit-wait, cooldown, cycle-lock and stuck sessions were
  # already skipped above. The clock <sid>.busy-since is "<start> <last>": start
  # of the stretch as first SEEN (a lower bound, so it can only delay a request),
  # last = latest observation. It resets whenever the pane is not working
  # (idle, or parked at a menu/prompt for the human), a Stop was recorded after
  # it began, or the observations have a gap.
  if [ "$thr" = 1 ]; then
    bsf="$STATE/$sid.busy-since"
    if mux_awaiting_human || ! mux_working; then
      rm -f "$bsf" 2>/dev/null
    else
      bs=0; bl=0
      [ -f "$bsf" ] && read -r bs bl < "$bsf" 2>/dev/null
      case "$bs$bl" in ''|*[!0-9]*) bs=0; bl=0 ;; esac
      idle_at=0; [ -f "$STATE/$sid.idle" ] && idle_at=$(cat "$STATE/$sid.idle" 2>/dev/null)
      case "$idle_at" in ''|*[!0-9]*) idle_at=0 ;; esac
      if [ "$bs" -eq 0 ] || [ "$idle_at" -gt "$bs" ] || [ "$(( now - bl ))" -gt "$BUSY_GAP" ]; then
        bs=$now
      fi
      printf '%s %s\n' "$bs" "$now" > "$bsf.tmp.$$" 2>/dev/null && mv -f "$bsf.tmp.$$" "$bsf" 2>/dev/null
      busy_min=$(( (now - bs) / 60 ))
      if [ "$busy_min" -ge "$BUSY_MIN" ] \
         && [ ! -f "$STATE/$sid.handoff-request" ] && [ ! -f "$STATE/$sid.compact-request" ]; then
        if [ ! -f "$STATE/auto-handoff.armed" ]; then
          log "$sid" "REQUEST would raise (threshold, busy ${busy_min}m) [dry-run]"
        # --if-absent: the session may file its own between the check above and
        # the write; the writer creates atomically and leaves its marker alone.
        elif "$_HERE/request-handoff.sh" "$sid" --if-absent --reason "threshold, busy ${busy_min}m" >/dev/null 2>&1; then
          rm -f "$bsf" 2>/dev/null
        else
          log "$sid" "REQUEST threshold writer failed (busy ${busy_min}m) — retry next sweep"
        fi
      fi
    fi
  fi

  log "$sid" "SWEEP re-arming watcher ($reason, aborts=$aborts)"
  setsid "$WATCH" "$sid" </dev/null >/dev/null 2>&1 &
done

exit 0
