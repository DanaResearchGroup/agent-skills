#!/usr/bin/env bash
# Phoenix — session-limit auto-resume watcher.
# Sibling of auto-handoff-watch.sh, launched (detached) by the same Stop hook once per turn.
# Purpose: when a CC turn ends because the *usage/session limit* was hit (a pane banner like
#   "You've hit your session limit · resets 6:20am (Asia/Jerusalem)"
#   "/usage-credits to finish what you're working on."),
# automatically try to keep working:
#   1. run /usage-credits (the banner's own suggested action). If that clears the limit,
#      send "continue" and resume.
#   2. else parse the reset time, sleep until a few minutes PAST it, then send "continue".
#
# The context-% signal lives in the statusline JSON; the *limit* signal does NOT — it is only
# rendered in the pane. So this watcher detects it by reading the pane text (herdr or tmux), not a marker file.
#
# Conservative + reversible, same doctrine as the handoff watcher:
#   - Global kill switch:      ~/agents/state/disable-auto-compact   (present => whole system off)
#   - Phoenix-only kill switch: ~/agents/state/disable-auto-resume    (present => this off)
#   - Arming:                  ~/agents/state/auto-handoff.armed      (absent  => dry-run, log only)
#   - Skip paid credits:       ~/agents/state/no-usage-credits        (present => go straight to wait)
#   - Per-session pane:        ~/agents/state/<sid>.{herdr,tmux}-pane (required to act)
#   - Per-session lock:        only one resume waiter per session at a time.
#   - While waiting it writes  ~/agents/state/<sid>.limit-wait        (statusline badge +
#                              the handoff watcher defers while it exists).
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

BUFFER_MIN=4      # send "continue" this many minutes PAST the stated reset time
CREDITS_WAIT=8      # seconds to wait after /usage-credits before checking if the limit cleared
DETECT_RECHECK=3    # seconds between the two initial banner checks
WAKE=60             # re-check interval during the long wait-for-reset sleep
MAX_WAIT=93600      # 26h sanity cap; a parsed wait longer than this is treated as a parse error
POLL=3

# Usage/session-limit banner markers (Phoenix-specific; herdr has no native state
# for this, so the banner is always detected by reading pane text via mux_capture).
LIMIT_RE='hit your (session|usage|rate)[ ]?limit|(session|usage|rate) limit reached|limit reached ·|hit your limit'

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
pane="$PANE"
mux_pane_live || exit 0
# --- pane-OWNERSHIP gate (see auto-handoff-watch.sh) ---
# herdr/tmux recycle pane ids; a live pane may now host a different session.
# Refuse before we even read its banner, so we never resume/inject into someone
# else's conversation. Self-heal by dropping our stale pane binding.
owner=$(mux_pane_owner)
if [ -n "$owner" ] && [ "$owner" != "$sid" ]; then
  log "SKIP pane $pane reused by session $owner (not ours) — cleared stale binding"
  rm -f "$STATE/$sid.$MUX-pane" 2>/dev/null
  exit 0
fi

snapshot(){ mux_capture; }
has_limit(){ mux_capture | grep -Eiq "$LIMIT_RE"; }
pane_busy(){ mux_busy; }
pane_live(){ mux_pane_live; }

send(){ # one literal line + Enter to the pane (via herdr/tmux)
  local text="$1"
  if [ "$DRY" = 1 ]; then log "DRY would send: [$text]"; else
    mux_send_line "$text" 2>>"$LOG"
    log "SENT: [$text]"
  fi
}
send_key(){ # a named key (e.g. Escape), no literal
  local key="$1"
  if [ "$DRY" = 1 ]; then log "DRY would send-key: [$key]"; else
    mux_send_key "$key" 2>>"$LOG"; log "SENT key: [$key]"
  fi
}
wait_pane_idle(){ local d=$(( $(date +%s) + ${1:-30} )); while [ "$(date +%s)" -lt "$d" ]; do pane_busy || return 0; sleep "$POLL"; done; return 1; }

# --- detect the limit banner (two cheap checks; on a normal turn this exits fast) ---
has_limit || { sleep "$DETECT_RECHECK"; has_limit || exit 0; }

# --- one waiter per session ---
lock="$STATE/$sid.resume.lock"
if ! mkdir "$lock" 2>/dev/null; then log "SKIP resume already in progress"; exit 0; fi
cleanup(){ rmdir "$lock" 2>/dev/null || true; rm -f "$STATE/$sid.limit-wait" 2>/dev/null || true; }
trap cleanup EXIT

resetline=$(snapshot | grep -Ei 'resets' | head -1 | tr -s ' ')
log "LIMIT detected pane=$pane dry=$DRY reset='${resetline:-<none>}'"

# --- parse reset time (+ optional IANA tz in parens) from the banner ---
H=""; M="00"; AP=""; TZN=""; tgt=""
if [[ "$resetline" =~ resets[^0-9]*([0-9]{1,2})(:([0-9]{2}))?[[:space:]]*([AaPp])[Mm] ]]; then
  H="${BASH_REMATCH[1]}"; M="${BASH_REMATCH[3]:-00}"; AP="${BASH_REMATCH[4]}"
fi
[[ "$resetline" =~ \(([A-Za-z]+/[A-Za-z_]+)\) ]] && TZN="${BASH_REMATCH[1]}"
if [ -n "$H" ]; then
  ampm="${AP,,}m"; timestr="$H:$M $ampm"; now=$(date +%s)
  if [ -n "$TZN" ]; then
    tgt=$(TZ="$TZN" date -d "$timestr" +%s 2>/dev/null)
    [ -n "$tgt" ] && [ "$tgt" -le "$now" ] && tgt=$(TZ="$TZN" date -d "tomorrow $timestr" +%s 2>/dev/null)
  else
    tgt=$(date -d "$timestr" +%s 2>/dev/null)
    [ -n "$tgt" ] && [ "$tgt" -le "$now" ] && tgt=$(date -d "tomorrow $timestr" +%s 2>/dev/null)
  fi
  [ -n "$tgt" ] && tgt=$(( tgt + BUFFER_MIN*60 ))
fi
human="${H:+$H:$M$ampm}${TZN:+ $TZN}"; [ -n "$human" ] || human="unknown"
printf 'until=%s human=%s ts=%s\n' "${tgt:-0}" "$human" "$(date +%s)" > "$STATE/$sid.limit-wait" 2>/dev/null
log "parsed reset: human='$human' target_epoch='${tgt:-<unparsed>}'"

# --- step 1: try /usage-credits (banner's own suggested action), unless disabled ---
if [ ! -f "$STATE/no-usage-credits" ]; then
  send "/usage-credits"
  if [ "$DRY" = 0 ]; then
    sleep "$CREDITS_WAIT"
    if ! has_limit; then
      # limit cleared. If work auto-resumed (pane busy), don't inject a spurious "continue".
      sleep 2
      if pane_busy; then log "usage-credits cleared limit; work already resuming — no continue needed";
      else wait_pane_idle 20; send "continue"; log "usage-credits cleared limit; sent continue"; fi
      log "CYCLE COMPLETE via usage-credits (dry=$DRY)"; exit 0
    fi
    log "usage-credits did not clear the limit; falling back to wait-for-reset"
    send_key Escape   # dismiss any dialog it may have opened before we wait
    sleep 1
  fi
else
  log "usage-credits skipped (no-usage-credits set); waiting for reset"
fi

# --- step 2: wait until a few minutes past reset, then send continue ---
if [ -z "$tgt" ]; then
  log "WARN could not parse a reset time from the banner; leaving it to the user. Exiting."
  exit 0
fi
now=$(date +%s); wait_s=$(( tgt - now ))
if [ "$wait_s" -gt "$MAX_WAIT" ]; then
  log "WARN parsed reset is ${wait_s}s away (> ${MAX_WAIT}s cap); treating as parse error, leaving to user. Exiting."
  exit 0
fi
if [ "$wait_s" -lt 0 ]; then wait_s=0; fi
log "waiting ${wait_s}s (until $(date -d "@$tgt" +'%Y.%m.%d %H.%M.%S' 2>/dev/null || echo "$tgt")) then sending continue"

start=$(date +%s)
while [ "$(date +%s)" -lt "$tgt" ]; do
  # bail if the pane died, the system was disabled, or the user took over (a turn completed
  # after we started waiting -> the .idle marker advanced past our start).
  pane_live || { log "ABORT pane gone during wait"; exit 0; }
  [ -f "$STATE/disable-auto-compact" ] || [ -f "$STATE/disable-auto-resume" ] && { log "ABORT disabled during wait"; exit 0; }
  if [ -f "$STATE/$sid.idle" ]; then
    iv=$(cat "$STATE/$sid.idle" 2>/dev/null || echo 0)
    [ "${iv:-0}" -gt "$start" ] 2>/dev/null && { log "ABORT user took over during wait (a turn completed)"; exit 0; }
  fi
  sleep "$WAKE"
done

# reset time reached — resume.
pane_live || { log "ABORT pane gone at reset"; exit 0; }
[ "$DRY" = 0 ] && wait_pane_idle 30
send "continue"
log "CYCLE COMPLETE via wait-for-reset (dry=$DRY)"
exit 0
