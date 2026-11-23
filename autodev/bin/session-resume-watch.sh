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
#   - Log-only:                ~/agents/state/auto-resume.log-only    (present => detect and log,
#                              type nothing; beats disable-auto-resume and armed)
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

# --- log-only mode (I-571): run the detector on the real pane, type nothing ---
# The owner turns the watcher back on only once its detections are proven true.
# This mode is the instrument: per detection it logs one LOG-ONLY line with the
# verdict and saves the screen it judged (mode 600, directory 700) to
# $LOGDIR/auto-resume-screens/<UTC stamp>-<sid>.txt. It never reaches send(),
# any mux send/key function, the resume lock or <sid>.limit-wait, and it writes
# nothing under $STATE. A pane whose cwd starts with a prefix listed in
# $STATE/auto-resume.no-save (one per line, local only) is counted, not saved.
# bin/auto-resume-report.py summarises the log over AUTODEV_LOGONLY_DAYS.
logonly_log(){ log "$* at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
# 0 = withhold this pane's screen. $1 is the pane's cwd list (mux_pane_cwd).
# An unreadable list, or a list with a pane whose cwd cannot be read, withholds
# too: no proof the pane is not listed.
logonly_withheld(){
  local list="$STATE/auto-resume.no-save" cwds="$1" p c
  [ -e "$list" ] || return 1
  [ -r "$list" ] || return 0
  [ -n "$cwds" ] || return 0
  while IFS= read -r p || [ -n "$p" ]; do
    p=${p%$'\r'}
    p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
    # shellcheck disable=SC2088  # a literal leading ~ in the list, expanded here
    case "$p" in ''|'#'*) continue ;; "~"|"~/"*) p="$HOME${p#\~}" ;; esac
    while IFS= read -r c; do
      case "$c" in "$p"*) return 0 ;; esac
    done <<< "$cwds"
  done < "$list"
  return 1
}
# $1 single-quoted, so a shell (or shlex) reads the field back as $1 exactly.
logonly_quote(){ local s=$1 q="'\\''"; printf "'%s'" "${s//\'/$q}"; }
# Save $1 (the screen judged) under a fresh name; print that name.
logonly_save(){
  local dir="$LOGDIR/auto-resume-screens" f
  [ -L "$dir" ] && return 1
  ( umask 077; mkdir -p "$dir" ) 2>/dev/null && chmod 700 "$dir" 2>/dev/null || return 1
  f="$dir/$(date -u +%Y%m%dT%H%M%SZ)-$sid.txt"
  [ -e "$f" ] || [ -L "$f" ] && f="${f%.txt}-$$.txt"
  ( umask 077; set -C; printf '%s\n' "$1" > "$f" ) 2>/dev/null || return 1
  chmod 600 "$f" 2>/dev/null || return 1
  printf '%s\n' "${f##*/}"
}
# Go on only for a pane proved ours (herdr: positively; tmux: no other owner),
# so the instrument never reads or keeps another seat's screen. Else log a skip
# ($1 says what was not done) and exit. Read-only: no flag is set.
logonly_owned(){
  local owner
  owner=$(mux_pane_owner)
  if [ "$owner" != "$sid" ] && { [ "$MUX" = herdr ] || [ -n "$owner" ]; }; then
    logonly_log "LOG-ONLY SKIP pane=$pane not proved ours (owner: ${owner:-unproved}); $1"
    exit 0
  fi
}
logonly_run(){ # never returns
  local screen v ev rc kv reset="" human="" kind="" tgt f what would="" cwds cwd held=1
  local verdict="unknown" banner="''" sha
  command -v mux_init >/dev/null 2>&1 || exit 0
  mux_init "$sid" || exit 0
  pane="$PANE"
  mux_pane_live || exit 0
  logonly_owned "screen not read"
  # The same two checks as the armed path, each on one held screen, so the
  # file saved is exactly the screen the detector judged. Another session can
  # take the pane during the recheck wait, so the second read is proved ours
  # both before it is taken and before it is judged.
  screen=""; mux_read_screen 200 screen
  v=$(printf '%s\n' "$screen" | python3 "$BANNER" --evidence); rc=$?
  if [ "$rc" != 0 ]; then
    sleep "$DETECT_RECHECK"
    logonly_owned "screen not read"
    screen=""; mux_read_screen 200 screen
    logonly_owned "screen not kept"
    v=$(printf '%s\n' "$screen" | python3 "$BANNER" --evidence); rc=$?
  fi
  # limit-banner.py --evidence: line 1 is the verdict the armed path reads,
  # line 2 "verdict=live|history:<reason> banner=<quoted row>", taken as given.
  ev=""; case "$v" in *$'\n'*) ev=${v#*$'\n'}; v=${v%%$'\n'*} ;; esac
  case "$ev" in "verdict="*" banner="*)
    verdict=${ev%% banner=*}; verdict=${verdict#verdict=}; banner=${ev#* banner=} ;;
  esac
  if [ "$rc" != 0 ]; then
    case "$v" in *reason=no-banner*|'') exit 0 ;; esac
    what="NO-DETECT pane=$pane ${v#none }"
  else
    for kv in $v; do
      case "$kv" in reset=*) reset=${kv#reset=} ;; human=*) human=${kv#human=} ;; kind=*) kind=${kv#kind=} ;; esac
    done
    # what send() would type: the armed path types nothing without a reset
    # epoch; test-limit-resume.sh pins this text to its send line.
    case "$reset" in ''|*[!0-9]*) tgt="" ;; *) tgt=$(( reset + BUFFER_MIN*60 )); would="continue" ;; esac
    what="would send [$would] pane=$pane kind=$kind reset=$reset human=$human until=$tgt wait=$(( ${tgt:-0} - $(date +%s) ))s"
  fi
  # The proof fields: the owner judges the run from these lines alone. A
  # withheld pane keeps its hash but names neither its cwd nor its banner.
  cwds=$(mux_pane_cwd 2>/dev/null)
  # The screen and the cwd were both read while the pane was ours, or neither
  # is logged or kept: another session can take it after a read that detects.
  logonly_owned "screen not kept"
  logonly_withheld "$cwds" && held=0
  sha=$(printf '%s\n' "$screen" | sha256sum 2>/dev/null); sha=${sha%% *}
  if [ "$held" = 0 ]; then
    cwd=withheld; banner=withheld
  else
    cwd=${cwds%%$'\n'*}
    if [ -n "$cwd" ]; then cwd=$(logonly_quote "$cwd"); else cwd=unknown; fi
  fi
  logonly_log "LOG-ONLY $what seat=$sid cwd=$cwd screen_sha256=${sha:-unknown} banner=$banner verdict=$verdict would_type=$(logonly_quote "$would")"
  [ "$rc" = 0 ] || exit 0
  if [ "$held" = 0 ]; then
    logonly_log "LOG-ONLY screen-withheld pane=$pane"
  elif f=$(logonly_save "$screen"); then
    logonly_log "LOG-ONLY screen-saved $f"
  else
    logonly_log "LOG-ONLY screen-save-failed pane=$pane"
  fi
  exit 0
}

# --- kill switches ---
# Precedence (I-571): disable-auto-compact => nothing at all. auto-resume.log-only
# => detect and log only, whatever the other switches say. Otherwise
# disable-auto-resume => exit before detection.
[ -f "$STATE/disable-auto-compact" ] && exit 0
[ -f "$STATE/auto-resume.log-only" ] && logonly_run
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
  [ -f "$STATE/auto-resume.log-only" ] && { log "ABORT log-only set during wait; no continue"; exit 0; }
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
# Log-only, set at any time before this line, means nothing is ever typed.
[ -f "$STATE/auto-resume.log-only" ] && { log "ABORT log-only set at reset; no continue"; exit 0; }
send "continue"
log "CYCLE COMPLETE via wait-for-reset (dry=$DRY)"
exit 0
