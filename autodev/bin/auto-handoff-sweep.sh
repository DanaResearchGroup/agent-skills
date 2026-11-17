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

log(){ printf '%s [%s] %s\n' "$(date +'%Y.%m.%d %H.%M.%S')" "$1" "$2" >> "$LOG"; }

positive_integer_or_default(){
  local value=$1 fallback=$2
  case "$value" in ''|*[!0-9]*) printf '%s\n' "$fallback"; return ;; esac
  while [ "${value#0}" != "$value" ]; do value=${value#0}; done
  if [ -z "$value" ] || [ "${#value}" -gt 9 ]; then value=$fallback; fi
  printf '%s\n' "$value"
}

snapshot_failed(){
  local marker="$STATE/.herdr-panes.failing"
  if ( umask 077; set -o noclobber; : > "$marker" ) 2>/dev/null; then
    log "-" "HERDR snapshot failed: $1"
  elif [ ! -e "$marker" ]; then
    log "-" "HERDR snapshot failed: $1"
  fi
  return 0
}

snapshot_recovered(){
  local marker="$STATE/.herdr-panes.failing"
  if [ -f "$marker" ] && rm -f "$marker" 2>/dev/null; then
    log "-" "HERDR snapshot RECOVERED"
  fi
  return 0
}

publish_herdr_panes(){
  local herdr_cmd
  if [ -n "${MUX_HERDR:-}" ]; then
    herdr_cmd=$MUX_HERDR
  elif herdr_cmd=$(command -v herdr 2>/dev/null); then
    :
  elif [ -x "$HOME/.local/bin/herdr" ]; then
    herdr_cmd="$HOME/.local/bin/herdr"
  else
    return 0
  fi

  local timeout_cmd
  if ! timeout_cmd=$(command -v timeout 2>/dev/null); then
    snapshot_failed "timeout command unavailable"
    return 0
  fi

  local pane_json captured_at snapshot_json snapshot tmp timeout_seconds
  snapshot="$STATE/herdr-panes.json"
  timeout_seconds=$(positive_integer_or_default "${AUTODEV_HERDR_TIMEOUT:-10}" 10)
  if ! pane_json=$("$timeout_cmd" -k 5 "$timeout_seconds" "$herdr_cmd" pane list 2>/dev/null); then
    snapshot_failed "pane list command failed"
    return 0
  fi
  if ! captured_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null); then
    snapshot_failed "could not capture pane list timestamp"
    return 0
  fi
  if ! printf '%s\n' "$pane_json" | jq -e '.result.panes | type == "array"' >/dev/null 2>&1; then
    snapshot_failed "could not validate pane list JSON"
    return 0
  fi
  if ! snapshot_json=$(printf '%s\n' "$pane_json" | jq -e --arg captured_at "$captured_at" '. + {captured_at: $captured_at}' 2>/dev/null); then
    snapshot_failed "could not add pane list timestamp"
    return 0
  fi

  if ! tmp=$(mktemp "$STATE/.herdr-panes.json.XXXXXX" 2>/dev/null); then
    snapshot_failed "could not create temporary file"
    return 0
  fi
  if ! printf '%s\n' "$snapshot_json" > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    snapshot_failed "could not write temporary file"
    return 0
  fi
  if ! chmod 600 "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    snapshot_failed "could not set file mode"
    return 0
  fi
  if ! mv -f "$tmp" "$snapshot" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    snapshot_failed "could not publish snapshot"
    return 0
  fi
  snapshot_recovered
}

publish_herdr_panes

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$_HERE/lock-lib.sh" ] && . "$_HERE/lock-lib.sh" || exit 0
[ -f "$_HERE/mux-lib.sh" ] && . "$_HERE/mux-lib.sh"
[ -f "$_HERE/request-lib.sh" ] && . "$_HERE/request-lib.sh"
[ -f "$_HERE/threshold-lib.sh" ] && . "$_HERE/threshold-lib.sh" || exit 0
# Never let a missing lib make every request look stale: fall back to "exists".
command -v request_valid >/dev/null 2>&1 || request_valid(){ [ -f "${5:-$1/$3.$4}" ]; }
command -v remove_stale_request >/dev/null 2>&1 || remove_stale_request(){ return 1; }
WATCH="$_HERE/auto-handoff-watch.sh"
[ -x "$WATCH" ] || exit 0
command -v mux_init >/dev/null 2>&1 || exit 0

# These MUST match auto-handoff-watch.sh. The sweeper only prefilters; every one
# of these is re-checked authoritatively by the watcher itself. The handoff line
# (35%, or a Persona seat's token line) is shared through threshold-lib.sh.
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
# its handoff line inside one long turn and never files its own request would run on
# until the turn ends. Past BUSY_MIN minutes of continuous work the sweep files
# the request for it. Anything but a positive integer falls back to the default
# (never to "off" or "immediately").
BUSY_MIN=$(positive_integer_or_default "${AUTODEV_BUSY_MINUTES:-20}" 20)
# Continuity: the sweep is the only observer, so two observations further apart
# than this (a skipped sweep, a stopped timer) do not prove the pane stayed busy.
BUSY_GAP=$(positive_integer_or_default "${AUTODEV_BUSY_GAP:-600}" 600)
# A dead session is only one whose watcher heartbeat and context reading are
# both old AND whose pane is absent from a fresh successful backend listing.
DEFAULT_DEAD_SESSION_HOURS=24
DEAD_SESSION_HOURS=$(positive_integer_or_default "${AUTODEV_DEAD_SESSION_HOURS:-$DEFAULT_DEAD_SESSION_HOURS}" "$DEFAULT_DEAD_SESSION_HOURS")
[ "$DEAD_SESSION_HOURS" -le 87600 ] || DEAD_SESSION_HOURS=$DEFAULT_DEAD_SESSION_HOURS
DEAD_SESSION_AGE=$(( DEAD_SESSION_HOURS * 3600 ))
# One sweep may send a few detailed pages, then one summary for the rest.
DEFAULT_PAGE_BUDGET=3
PAGE_BUDGET=$(positive_integer_or_default "${AUTODEV_PAGE_BUDGET:-$DEFAULT_PAGE_BUDGET}" "$DEFAULT_PAGE_BUDGET")
[ "$PAGE_BUDGET" -le 100 ] || PAGE_BUDGET=$DEFAULT_PAGE_BUDGET

# Global kill switch beats everything.
[ -f "$STATE/disable-auto-compact" ] && exit 0

now=$(date +%s)
mtime(){ date -r "$1" +%s 2>/dev/null || echo 0; }
fresh(){ [ -f "$1" ] && [ "$(( now - $(mtime "$1") ))" -le "$2" ]; }

# The page functions can run in a flock subshell. Keep sweep-wide counts in a
# private temporary file so those updates are visible to the parent sweep.
PAGE_COUNT_FILE="$STATE/.page-count.$$"
PAGE_COUNT_READY=1
if ! printf '0 0\n' > "$PAGE_COUNT_FILE" 2>/dev/null; then
  PAGE_COUNT_READY=0
  log "-" "PAGE-SKIP cannot initialize per-sweep page budget; continuing without pages"
else
  trap 'rm -f "$PAGE_COUNT_FILE"' EXIT
fi

page_count_read(){
  [ "$PAGE_COUNT_READY" = 1 ] || return 1
  local detailed=0 summarized=0
  read -r detailed summarized < "$PAGE_COUNT_FILE" 2>/dev/null || true
  case "$detailed$summarized" in ''|*[!0-9]*) detailed=0; summarized=0 ;; esac
  PAGE_DETAILED_COUNT=$detailed
  PAGE_SUMMARY_COUNT=$summarized
}
page_count_write(){ [ "$PAGE_COUNT_READY" = 1 ] && printf '%s %s\n' "$1" "$2" > "$PAGE_COUNT_FILE" 2>/dev/null; }

# A missing pane is proven only by a fresh successful listing for its backend.
# mux_pane_live alone cannot distinguish absence from an unavailable backend.
pane_absence_proven(){
  local sid=$1 timeout_cmd listing timeout_seconds
  mux_init "$sid" || return 1
  timeout_seconds=$(positive_integer_or_default "${AUTODEV_HERDR_TIMEOUT:-10}" 10)
  case "$MUX" in
    herdr)
      command -v timeout >/dev/null 2>&1 || return 1
      timeout_cmd=$(command -v timeout) || return 1
      listing=$("$timeout_cmd" -k 5 "$timeout_seconds" "$MUX_HERDR" pane list 2>/dev/null) || return 1
      printf '%s\n' "$listing" | jq -e --arg pane "$PANE" \
        '.result.panes | type == "array" and all(.[]; (.pane_id | type) == "string") and ([.[] | select(.pane_id == $pane)] | length == 0)' \
        >/dev/null 2>&1
      ;;
    tmux)
      command -v timeout >/dev/null 2>&1 || return 1
      timeout_cmd=$(command -v timeout) || return 1
      listing=$("$timeout_cmd" -k 5 "$timeout_seconds" tmux list-panes -a -F '#{pane_id}' 2>/dev/null) || return 1
      if [ -n "$listing" ] && printf '%s\n' "$listing" | grep -Ev '^%[0-9]+$' | grep -q .; then return 1; fi
      ! printf '%s\n' "$listing" | grep -qxF -- "$PANE"
      ;;
    *) return 1 ;;
  esac
}

has_pending_marker(){
  local sid=$1 kind
  for kind in handoff-request compact-request reload-pending reload-attempt; do
    [ -f "$STATE/$sid.$kind" ] && return 0
  done
  return 1
}

dead_session_eligible(){
  local sid=$1 hb="$STATE/$1.heartbeat" ctx="$STATE/$1.ctx"
  has_pending_marker "$sid" || return 1
  [ -f "$hb" ] && [ -f "$ctx" ] || return 1
  [ "$(( now - $(mtime "$hb") ))" -ge "$DEAD_SESSION_AGE" ] || return 1
  [ "$(( now - $(mtime "$ctx") ))" -ge "$DEAD_SESSION_AGE" ] || return 1
  pane_absence_proven "$sid"
}

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
_notify_page(){ # $1 sid, $2 message
  local sid=$1 msg=$2
  log "$sid" "PAGE $msg"
  [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "/run/user/$(id -u)/bus" ] &&
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus" && export DBUS_SESSION_BUS_ADDRESS
  local -a runner=(); command -v timeout >/dev/null 2>&1 && runner=(timeout "${AUTODEV_PAGE_TIMEOUT:-10}")
  "${runner[@]}" "${AUTODEV_PAGE_CMD:-notify-send}" "autodev: handoff stuck" "$msg" >/dev/null 2>&1 ||
    log "$sid" "PAGE notify failed — the PAGE line above is the only record; handled once, not retried"
}
_dead_page_locked(){ # $1 sid; caller holds the same per-session page lock as marker pages
  local sid=$1 key msg notify=0
  dead_session_eligible "$sid" || return 0
  [ -f "$STATE/$sid.dead-session.paged" ] && return 0
  page_count_read || return 0
  key="dead-session:$(mtime "$STATE/$sid.heartbeat"):$(mtime "$STATE/$sid.ctx")"
  msg="autodev: dead session $sid has pending markers left behind; inspect and clean them up by hand"
  page_count_read
  local detailed=$PAGE_DETAILED_COUNT summarized=$PAGE_SUMMARY_COUNT
  if [ "$detailed" -lt "$PAGE_BUDGET" ]; then detailed=$(( detailed + 1 )); notify=1; else summarized=$(( summarized + 1 )); fi
  page_count_write "$detailed" "$summarized" || return 0
  if ! printf '%s\n' "$key" > "$STATE/$sid.dead-session.paged" 2>/dev/null; then
    page_count_write "$PAGE_DETAILED_COUNT" "$PAGE_SUMMARY_COUNT" || true
    log "$sid" "PAGE-SKIP cannot record dead-session page — not paging"
    return 0
  fi
  if [ "$notify" = 1 ]; then _notify_page "$sid" "$msg"; fi
}
page_dead_session(){
  local sid=$1
  if [ -n "${AUTODEV_NO_FLOCK:-}" ] || ! command -v flock >/dev/null 2>&1; then
    _dead_page_locked "$sid"; return
  fi
  ( flock -n 9 || exit 0; _dead_page_locked "$sid" ) 9>"$STATE/$sid.page.lock"
}
_page_locked(){
  local sid=$1 kind=$2 rf key age msg owner retired pending="" record detailed summarized notify=0
  if [ "$kind" = reload-attempt ]; then rf="$STATE/$sid.reload-attempt"
  else rf="$STATE/$sid.$kind"; fi
  [ -f "$rf" ] || return 0
  if [ "$kind" = handoff-request ] || [ "$kind" = compact-request ]; then
    [ -f "$STATE/$sid.deferred" ] &&
      [ "$STATE/$sid.deferred" -nt "$rf" ] || return 0
    [ "$(( now - $(mtime "$rf") ))" -ge "$PAGE_AFTER" ] || return 0
  fi
  if [ "$kind" = reload-pending ] || [ "$kind" = reload-attempt ]; then
    [ "$(( now - $(mtime "$rf") ))" -ge "$PAGE_AFTER" ] || return 0
  fi
  if [ "$kind" = reload-pending ]; then
    # A stale/missing lock owner must not suppress the alert. Recheck inside
    # the page lock: a watcher may have reclaimed it since the sweep's check.
    # A lock held by this sweep is the ordinary cleanup-and-page path.
    autodev_lock_read_owner "$STATE/$sid.cycle.lock"
    if [ -n "$lock_owner_pid" ] && [ "$lock_owner_pid" != "$$" ] &&
       kill -0 "$lock_owner_pid" 2>/dev/null; then return 0; fi
    if [ ! -f "$STATE/$sid.reload-attempt" ]; then
      [ "$(( now - $(mtime "$rf") ))" -ge "$PAGE_AFTER" ] || return 0
      retired=""
      command -v reload_marker_retire_reason >/dev/null 2>&1 &&
        retired=$(reload_marker_retire_reason "$STATE" "$AUTODEV_HOME/handoffs" "$sid" "$rf" || true)
      [ -z "$retired" ] || return 0
    fi
  fi
  # Re-read ownership at the page boundary, under the dedupe lock. A reload
  # for a confirmed reused pane is no longer actionable. Unproved ownership
  # (including an unavailable pane) must still be visible to the user.
  if [ "$kind" = reload-pending ] && mux_init "$sid" && mux_pane_live; then
    owner=$(mux_pane_owner)
    [ -z "$owner" ] || [ "$owner" = "$sid" ] || return 0
  fi
  key="$kind:$(date -r "$rf" +%s%N 2>/dev/null)"
  record="$STATE/$sid.paged.$kind"
  [ "$(cat "$record" 2>/dev/null)" = "$key" ] && return 0
  # Upgrade compatibility: the previous single-slot record may still describe
  # this marker. Read it, but leave it untouched.
  [ "$(cat "$STATE/$sid.paged" 2>/dev/null)" = "$key" ] && return 0
  age=$(( (now - $(mtime "$rf")) / 60 ))
  if [ -f "$STATE/$sid.reload-attempt" ]; then
    [ -f "$STATE/$sid.reload-pending" ] && pending="reload retry"
    [ -f "$STATE/$sid.handoff-request" ] && pending="${pending:+$pending, }handoff-request"
    [ -f "$STATE/$sid.compact-request" ] && pending="${pending:+$pending, }compact-request"
    if [ -n "$pending" ]; then pending=" Pending work also waiting: $pending."; fi
    msg="autodev: tmux input for session $sid may contain staged text after $age min; inspect the pane before submitting anything.$pending"
  elif [ "$kind" = reload-pending ]; then
    msg="autodev: reload for session $sid pending $age min and the watcher keeps deferring (presence, dialog, or busy guard) — inspect the pane and continue it by hand"
  else
    msg="autodev: $kind for session $sid pending $age min and the watcher keeps deferring (busy pane or open prompt) — compact it by hand"
  fi
  # Record BEFORE paging, and refuse to page if the record cannot be kept: an
  # unrecorded page repeats on every sweep.
  page_count_read || return 0
  detailed=$PAGE_DETAILED_COUNT; summarized=$PAGE_SUMMARY_COUNT
  if [ "$detailed" -lt "$PAGE_BUDGET" ]; then detailed=$(( detailed + 1 )); notify=1; else summarized=$(( summarized + 1 )); fi
  if ! page_count_write "$detailed" "$summarized"; then return 0; fi
  if ! printf '%s\n' "$key" > "$record" 2>/dev/null; then
    page_count_write "$PAGE_DETAILED_COUNT" "$PAGE_SUMMARY_COUNT" || true
    log "$sid" "PAGE-SKIP cannot record $record — not paging (would repeat every sweep): $msg"
    return 0
  fi
  if [ "$notify" = 1 ]; then _notify_page "$sid" "$msg"; fi
}

# --- stuck-seat alert: a seat past its line that automation cannot reach -----
# The watcher never types under a menu or overlay. It re-files its request and
# the sweep re-arms it every tick, so the handoff stays queued, but the seat is
# parked until a person clears the screen. Each refusal is recorded in
# <sid>.covered ("<since> <last> <kind>", autodev_cover_record in mux-lib.sh):
# the watcher records a covered screen (menu, login, other) on any seat, and the
# sweep records a pane not owned (owner) or gone (nopane) on a Persona seat,
# whose handoff gate orders no AskUserQuestion menu for any reason, so this alert
# is all that reaches a person. Once a seat past its line has been unreachable
# for more than STUCK_ALERT_AFTER, send one Slack line to the owner and one
# session-lane line to the Method Persona, once per episode.
# <sid>.covered-alert records what was sent for which episode, so a restart
# does not send again; a failed send is recorded there and retried on the next
# tick.
STUCK_ALERT_AFTER=600
# The latest refusal must be this recent: an unreachable seat is retried every
# tick, so an older one says nothing about the pane now.
COVER_FRESH=${AUTODEV_COVER_GAP:-900}
ALERT_LANE_TO=${AUTODEV_ALERT_LANE_TO:-persona:method}

# Alerts are delivered after the loop has re-armed every watcher, so a slow
# Slack or lane send never holds up a handoff. At most ALERT_PARALLEL run at
# once, and none starts once ALERT_BUDGET seconds have passed (the rest retry
# next tick). One alert is bounded by the page-lock wait (10 s) and two sends
# (30 s each), so with these defaults delivery ends inside ~135 s, below the
# 3-minute sweep interval (install.sh SWEEP_EVERY).
ALERT_PARALLEL=$(positive_integer_or_default "${AUTODEV_ALERT_PARALLEL:-}" 4)
ALERT_BUDGET=${AUTODEV_ALERT_BUDGET:-60}
case "$ALERT_BUDGET" in ''|*[!0-9]*) ALERT_BUDGET=60 ;; esac
alert_queue=()
# Seats whose alert the budget skipped last tick go first this tick, so slow
# early sends cannot starve the seats after them (one sid per line).
ALERT_SKIPPED="$STATE/.alert-skipped"

# covered_due <sid>: the file-only half of the alert's checks. 0 when the seat
# is past its line and its unreachable episode is over STUCK_ALERT_AFTER old and
# still current. Sets cov_line, cov_since, cov_kind and the ctx_* readings.
covered_due(){
  local sid=$1 f="$STATE/$1.covered" comp=0 _rest
  cov_line=""; cov_since=""; cov_last=""; cov_kind=""
  [ -f "$f" ] || return 1
  cov_line=$(head -n1 "$f" 2>/dev/null) || return 1
  read -r cov_since cov_last cov_kind _rest <<< "$cov_line" || return 1
  case "$cov_since" in ''|*[!0-9]*) return 1 ;; esac
  case "$cov_last" in ''|*[!0-9]*) return 1 ;; esac
  case "$cov_kind" in menu|login|other|owner|nopane) ;; *) cov_kind=other ;; esac
  [ $(( now - cov_since )) -gt "$STUCK_ALERT_AFTER" ] || return 1
  [ $(( now - cov_last )) -le "$COVER_FRESH" ] || return 1
  [ -f "$STATE/$sid.compacted" ] && comp=$(head -n1 "$STATE/$sid.compacted" 2>/dev/null)
  case "$comp" in ''|*[!0-9]*) comp=0 ;; esac
  [ "$comp" -lt "$cov_since" ] || return 1
  autodev_ctx_over "$STATE" "$sid" gt
}

# note_unreachable <sid> <kind>: the sweep found a seat's herdr pane gone
# (nopane) or not its own (owner). On a seat that the handoff gate has spared
# the menu (a Persona seat, the only kind it spares) since this unreachable
# flag was raised, record the refusal, and queue the alert once its episode is
# due. Other seats keep the gate's menu. Without that proof the session may be
# dead, its request left pending and its pane recycled or closed: such a seat
# stays unreachable at every tick and would page again after every pause of
# the sweep.
note_unreachable(){
  case "$2" in owner|nopane) ;; *) return 0 ;; esac
  # True too when there is no <sid>.spared at all.
  [ "$STATE/$1.unreachable" -nt "$STATE/$1.spared" ] && return 0
  autodev_cover_record "$1" "$2" || log "$1" "ALERT-SKIP cannot record the unreachable pane ($2) in $STATE/$1.covered"
  covered_due "$1" && alert_queue+=("$1")
  return 0
}

# alert_screen_covered <sid>: 0 when the pane is covered right now, judged by
# the watcher's own tests at the send boundary (mux-lib.sh): on a Claude seat,
# no proof that its composer is the bottom-most screen; on any seat, a dialog
# awaiting the human. Needs mux_init.
alert_screen_covered(){
  if [ "$MUX" = herdr ] && [ "$(cat "$STATE/$1.runtime" 2>/dev/null)" = claude ]; then
    mux_screen_present_once || return 0
  fi
  mux_awaiting_human
}

# alert_episode_end <sid> <why>: the seat is reachable and its screen clear, so
# the episode is over (a person closed the cover or gave the pane back). Remove
# <sid>.covered only while it still holds the line read: a refusal recorded
# meanwhile starts its own count.
alert_episode_end(){
  local f="$STATE/$1.covered"
  if [ "$(head -n1 "$f" 2>/dev/null)" = "$cov_line" ] && rm -f "$f" 2>/dev/null; then
    log "$1" "ALERT-CLEAR $2 — episode over, no alert"
  fi
}

# alert_stuck_now <sid>: read the pane now. Sets al_kind, the reason the alert
# names. 0 = stuck, alert; 1 = no alert now (a turn is running, or the pane is
# lost on a seat that is not a Persona); 2 = the seat is reachable and its
# screen clear, so the episode is over. Ownership is read first: the status and
# screen of a pane that is not ours belong to another session. Needs mux_init.
alert_stuck_now(){
  local owner
  al_kind=""
  if ! mux_pane_live; then
    al_kind=nopane
  else
    owner=$(mux_pane_owner)
    if [ "$owner" != "$1" ] && { [ -n "$owner" ] || [ "$MUX" = herdr ]; }; then
      al_kind=owner
    fi
  fi
  if [ -n "$al_kind" ]; then
    # Only a Persona seat on herdr was spared the gate's menu for these.
    [ "$MUX" = herdr ] && autodev_persona_seat "$STATE" "$1" && return 0
    return 1
  fi
  mux_working && return 1
  # <sid>.covered outlives a cover the person closed before the watcher's next
  # send: alert only while the screen is still covered.
  alert_screen_covered "$1" || return 2
  case "$cov_kind" in
    menu|login|other) al_kind=$cov_kind ;;
    *) if mux_awaiting_human; then al_kind=menu; else al_kind=other; fi ;;
  esac
  return 0
}

# alert_record_read <sid>: sets al_episode, al_slack, al_lane from <sid>.covered-alert.
alert_record_read(){
  local key val
  al_episode=""; al_slack=""; al_lane=""
  [ -f "$STATE/$1.covered-alert" ] || return 0
  while IFS='=' read -r key val; do
    case "$key" in
      episode) al_episode=$val ;;
      slack) al_slack=$val ;;
      lane) al_lane=$val ;;
    esac
  done < "$STATE/$1.covered-alert"
}
alert_record_write(){ # $1 sid; writes al_episode, al_slack, al_lane
  local rec="$STATE/$1.covered-alert" tmp="$STATE/$1.covered-alert.tmp.$$"
  { printf 'episode=%s\nslack=%s\nlane=%s\n' "$al_episode" "$al_slack" "$al_lane" > "$tmp" &&
    mv -f "$tmp" "$rec"; } 2>/dev/null && return 0
  rm -f "$tmp" 2>/dev/null
  log "$1" "ALERT-SKIP cannot record $rec — no send until it can be recorded (an unrecorded send would repeat every tick)"
  return 1
}
alert_sent(){ case "$1" in 'sent '*) return 0 ;; esac; return 1; }

# The seat's name: its herdr tab label (without the cache badge), never a pane id.
alert_seat_label(){ # $1 sid; needs mux_init
  local l=""
  command -v mux_tab_label >/dev/null 2>&1 && l=$(mux_tab_label 2>/dev/null | head -n1)
  # The lane refuses control and format characters (an emoji's zero-width
  # joiner is one), and a byte cut could split a character: work in characters.
  l=$(printf '%s' "$l" | sed -E 's/ (⌛[0-9]+s|•cold)$//' | python3 -c '
import sys, unicodedata
s = sys.stdin.buffer.read().decode("utf-8", "replace")
s = "".join(c for c in s if unicodedata.category(c)[0] != "C" and unicodedata.category(c) not in ("Zl", "Zp"))
print(s.strip()[:80], end="")' 2>/dev/null) || l=""
  if [ -n "$l" ]; then printf "'%s'" "$l"; else printf 'an unlabelled seat (session %s)' "${1:0:8}"; fi
}

# One line of a command's output for the state file and the log: printable, short.
alert_why(){ # $1 output, $2 exit code
  local w
  w=$(printf '%s\n' "$1" | awk 'NF' | head -n1 | tr -d '\000-\037\177' | cut -c1-120)
  printf '%s' "${w:-exit $2}"
}

alert_send_slack(){ # $1 text; sets alert_out, returns the helper's exit code
  local cmd=${AUTODEV_SLACK_CMD:-$HOME/.claude/bin/cc-slack-post.py} chan=${CC_SLACK_CHANNEL:-} rc
  local settings=${AUTODEV_CLAUDE_SETTINGS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json}
  # A timer does not inherit Claude Code's env, where the channel id lives.
  [ -n "$chan" ] || chan=$(jq -r '.env.CC_SLACK_CHANNEL // empty' "$settings" 2>/dev/null)
  local -a runner=(); command -v timeout >/dev/null 2>&1 && runner=(timeout "${AUTODEV_ALERT_TIMEOUT:-30}")
  if [ -n "$chan" ]; then
    alert_out=$(CC_SLACK_CHANNEL=$chan "${runner[@]}" "$cmd" "$1" 2>&1 </dev/null); rc=$?
  else
    alert_out=$("${runner[@]}" "$cmd" "$1" 2>&1 </dev/null); rc=$?
  fi
  return "$rc"
}

alert_send_lane(){ # $1 text, $2 message id; sets alert_out. QUEUED (75) is success.
  local cmd=${AUTODEV_LANE_CMD:-} rc
  if [ -z "$cmd" ]; then
    cmd=$(command -v session-send 2>/dev/null) || cmd="$HOME/.local/bin/session-send"
  fi
  local -a runner=(); command -v timeout >/dev/null 2>&1 && runner=(timeout "${AUTODEV_ALERT_TIMEOUT:-30}")
  alert_out=$("${runner[@]}" "$cmd" --to "$ALERT_LANE_TO" --from autodev-sweep --id "$2" --wait 1 "$1" 2>&1 </dev/null); rc=$?
  [ "$rc" = 75 ] && rc=0
  return "$rc"
}

_alert_covered_locked(){ # $1 sid; caller holds <sid>.page.lock
  local sid=$1 label ctxtxt kindtxt mins host text mid rc why
  # Re-check under the lock: a send may have landed, or another sweep may have
  # sent the alert, while this one waited.
  covered_due "$sid" || return 0
  alert_record_read "$sid"
  if [ "$al_episode" != "$cov_since" ]; then al_episode=$cov_since; al_slack=""; al_lane=""; fi
  { alert_sent "$al_slack" && alert_sent "$al_lane"; } && return 0   # skips the herdr reads
  alert_stuck_now "$sid"; rc=$?
  if [ "$rc" = 2 ]; then alert_episode_end "$sid" "the pane is reachable and its screen is clear"; return 0; fi
  [ "$rc" = 0 ] || return 0
  # Record before sending: a send whose record cannot be kept would repeat
  # on every tick.
  alert_record_write "$sid" || return 0
  label=$(alert_seat_label "$sid")
  # shellcheck disable=SC2154  # set by autodev_ctx_over (threshold-lib.sh)
  ctxtxt="context ${ctx_pct}%${ctx_tok:+, $ctx_tok tokens}"
  mins=$(( (now - cov_since) / 60 ))
  case "$al_kind" in
    owner|nopane)
      if [ "$al_kind" = owner ]; then kindtxt="pane not owned"; else kindtxt="no pane"; fi
      text="seat $label is past its handoff line ($ctxtxt) and automation has not reached its pane for $mins min (reason: $kindtxt). The handoff stays queued; a person must find the session and type /compact in it." ;;
    *)
      case "$al_kind" in login) kindtxt="login screen" ;; *) kindtxt=$al_kind ;; esac
      text="seat $label is past its handoff line ($ctxtxt) and its pane has been covered for $mins min (reason: $kindtxt). The handoff stays queued; a person must clear the screen or type /compact in that pane." ;;
  esac
  if ! alert_sent "$al_slack"; then
    host=$(hostname 2>/dev/null || echo unknown-host)
    alert_send_slack "⚠️ *$host* — \`autodev\` $text"; rc=$?
    if [ "$rc" = 0 ]; then
      al_slack="sent $now"; log "$sid" "ALERT slack sent: $text"
    else
      why=$(alert_why "$alert_out" "$rc")
      al_slack="failed $now $why"; log "$sid" "ALERT slack failed: $why — retry next tick"
    fi
    alert_record_write "$sid" || return 0
  fi
  if ! alert_sent "$al_lane"; then
    # One id per episode: a retry after a timeout resumes the same message.
    mid="m-$(printf '%s:%s' "$sid" "$cov_since" | sha256sum | cut -c1-12)"
    alert_send_lane "autodev: $text" "$mid"; rc=$?
    if [ "$rc" = 0 ]; then
      al_lane="sent $now $mid"; log "$sid" "ALERT lane sent to $ALERT_LANE_TO ($mid)"
    else
      why=$(alert_why "$alert_out" "$rc")
      al_lane="failed $now $why"; log "$sid" "ALERT lane failed: $why — retry next tick"
    fi
    alert_record_write "$sid" || return 0
  fi
}

alert_covered(){ # $1 sid; caller ran mux_init
  local sid=$1
  # A cheap filter only; the locked half repeats every check.
  covered_due "$sid" || return 0
  if [ -n "${AUTODEV_NO_FLOCK:-}" ] || ! command -v flock >/dev/null 2>&1; then
    _alert_covered_locked "$sid"; return 0
  fi
  (
    if ! flock -n 9; then
      log "$sid" "ALERT waiting for the page lock"
      flock -w "${AUTODEV_ALERT_LOCK_WAIT:-10}" 9 || { log "$sid" "ALERT page lock busy — retry next tick"; exit 0; }
    fi
    _alert_covered_locked "$sid"
  ) 9>"$STATE/$sid.page.lock"
}

# alert_deliver_one <sid>: one queued alert, in its own background process. It
# re-resolves the pane and reads the clock anew (the checks and the alert text
# read $now, set here for this call only); alert_stuck_now reads the pane again
# under the lock.
alert_deliver_one(){
  local sid=$1 now
  now=$(date +%s)
  mux_init "$sid" || return 0
  alert_covered "$sid"
}

# alert_order: print the queue, the seats skipped last tick first (in the order
# they were skipped), then the rest in file order.
alert_order(){
  local sid q=" ${alert_queue[*]} " first=" "
  if [ -f "$ALERT_SKIPPED" ]; then
    while IFS= read -r sid; do
      case "$sid" in ""|*[!A-Za-z0-9._-]*) continue ;; esac
      case "$q" in *" $sid "*) ;; *) continue ;; esac
      case "$first" in *" $sid "*) continue ;; esac
      first="$first$sid "; printf '%s\n' "$sid"
    done < "$ALERT_SKIPPED"
  fi
  for sid in "${alert_queue[@]}"; do
    case "$first" in *" $sid "*) continue ;; esac
    first="$first$sid "; printf '%s\n' "$sid"
  done
}

# alert_deliver: run the queued alerts in the background. Called after the loop.
alert_deliver(){
  local sid pid start=$SECONDS n skipped="" tmp="$ALERT_SKIPPED.tmp.$$"
  local -a pids=() order=()
  mapfile -t order < <(alert_order)
  for sid in "${order[@]}"; do
    while :; do
      n=0
      for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && n=$(( n + 1 )); done
      [ "$n" -lt "$ALERT_PARALLEL" ] && break
      sleep 0.2
    done
    if [ $(( SECONDS - start )) -ge "$ALERT_BUDGET" ]; then
      log "$sid" "ALERT-SKIP the sweep's alert budget (${ALERT_BUDGET}s) is spent — retry next tick, first in line"
      skipped="$skipped$sid"$'\n'
      continue
    fi
    alert_deliver_one "$sid" </dev/null &
    pids+=("$!")
  done
  if [ -n "$skipped" ]; then
    { printf '%s' "$skipped" > "$tmp" && mv -f "$tmp" "$ALERT_SKIPPED"; } 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$ALERT_SKIPPED" 2>/dev/null
  fi
  # Only the alert processes: the watchers this sweep launched are not waited for.
  [ "${#pids[@]}" -eq 0 ] || wait "${pids[@]}" 2>/dev/null
  return 0
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

  # A marker may be left behind by a dead process. Preserve the existing
  # satisfied-request cleanup above; only page if pending work remains after it.
  if [ -f "$STATE/$sid.heartbeat" ] && [ -f "$STATE/$sid.ctx" ] &&
     [ "$(( now - $(mtime "$STATE/$sid.heartbeat") ))" -ge "$DEAD_SESSION_AGE" ] &&
     [ "$(( now - $(mtime "$STATE/$sid.ctx") ))" -ge "$DEAD_SESSION_AGE" ] &&
     has_pending_marker "$sid" && pane_absence_proven "$sid"; then
    page_dead_session "$sid"
    continue
  fi

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
          *)
            reload_pending=1
            # Page before reachability can skip the session. Hold the cycle
            # lock so a successful retry or supersession cannot replace the
            # marker between retirement/age checks and page_stuck's dedupe.
            if [ ! -f "$reload_attempt" ] &&
               [ "$(( now - $(mtime "$reload_marker") ))" -ge "$PAGE_AFTER" ]; then
              page_stuck "$sid" reload-pending
            fi
            ;;
        esac
      fi
      cycle_lock_release "$lock" || log "$sid" "ERROR could not release cycle lock after reload cleanup"
    else
      reload_pending=1
      log "$sid" "SKIP reload cleanup: cycle lock $(cycle_lock_block_reason "$lock")"
      # The pager has its own lock and repeats marker/owner checks there.
      # Notify without reclaiming this cycle lock or changing reload state.
      if [ -f "$reload_marker" ] &&
         [ "$(( now - $(mtime "$reload_marker") ))" -ge "$PAGE_AFTER" ]; then
        page_stuck "$sid" reload-pending
      fi
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
    if autodev_ctx_over "$STATE" "$sid" gt; then
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
    if autodev_ctx_over "$STATE" "$sid" gt; then
      # shellcheck disable=SC2154  # set by autodev_ctx_over (threshold-lib.sh)
      reason=$ctx_reason; thr=1
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
    # Reload has priority. Alternating two identities in the shared .paged
    # record would page both markers again on every sweep.
    [ "$reload_pending" = 1 ] && continue
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
  if [ "$MUX" = herdr ] && ! mux_session_reachable "$sid"; then
    # A Persona seat gets no menu from the gate: this refusal is its alert's.
    note_unreachable "$sid" "${MUX_UNREACHABLE_KIND:-}"
    if [ -z "${MUX_OWNER:-}" ] || [ "$MUX_OWNER" = "$sid" ]; then
      [ "$thr" = 1 ] && rm -f "$STATE/$sid.busy-since" 2>/dev/null
      continue
    fi
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

  # A seat past its line whose pane has stayed covered: tell a person once,
  # after the loop (alert_deliver), so no send delays any watcher.
  covered_due "$sid" && alert_queue+=("$sid")

  log "$sid" "SWEEP re-arming watcher ($reason, aborts=$aborts)"
  setsid "$WATCH" "$sid" </dev/null >/dev/null 2>&1 &
done

alert_deliver

# If the sweep covered more eligible marker identities than its detailed-page
# budget, send one final page with the count. This page is outside that budget.
if page_count_read && [ "$PAGE_SUMMARY_COUNT" -gt 0 ]; then
  _notify_page "-" "autodev: $PAGE_SUMMARY_COUNT additional stale marker(s) were covered by this sweep's page budget"
fi

exit 0
