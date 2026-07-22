#!/usr/bin/env bash
# request-handoff.sh — voluntarily ask the auto-handoff watcher to hand off THIS
# Claude Code session at the next idle Stop, even below the context threshold.
#
# Why: the watcher (auto-handoff-watch.sh) normally fires /handoff -> /compact ->
# reload only when context % > THRESHOLD. A session quiesced at a clean phase
# boundary that KNOWS its next phase is heavy has no way to hand off *before*
# opening it. This helper drops a `~/agents/state/<sid>.handoff-request` marker,
# which the watcher treats as a second trigger path that bypasses ONLY the
# threshold gate — every other safety gate (cooldown, pane-live, pane-ownership,
# cycle-lock, idle) still applies. The marker has a TTL in the watcher
# (REQUEST_MAX_AGE), so a forgotten request cannot fire arbitrarily far in the
# future.
#
# This helper NEVER triggers anything itself. It only writes (or removes) the
# marker and logs it; the watcher, on the next idle Stop, does the actual work.
#
# Usage:
#   request-handoff.sh [sid] [--cancel] [--compact-only]
#     (no args)      raise a handoff-request (full /handoff -> /compact -> reload)
#     --compact-only raise a compact-request instead: the handoff is ALREADY
#                    written, so the watcher skips /handoff and only compacts +
#                    reloads. Also snapshots .latest into a per-session pointer.
#                    Defers silently if the watcher is already mid-cycle.
#     --cancel       remove a pending request for the current session (pairs with
#                    --compact-only to cancel a compact-request)
#     sid            operate on an explicit session id instead of auto-resolving
#                    (order-independent with flags; mainly for testing/scripts)
#
# Exit status: 0 on success (marker written/removed, or already absent on cancel),
# 2 on a usage error (bad flag / unresolvable or unsafe sid).

set -u

: "${AUTODEV_HOME:=$HOME/agents}"; export AUTODEV_HOME
STATE="$AUTODEV_HOME/state"
LOGDIR="$AUTODEV_HOME/logs"
LOG="$LOGDIR/auto-handoff.log"

_HERE="$(cd "$(dirname "$0")" && pwd)"
# mux-lib gives mux_owner_file() for the reverse pane->owner lookup. Optional:
# without it we fall back to $CLAUDE_CODE_SESSION_ID.
[ -f "$_HERE/mux-lib.sh" ] && . "$_HERE/mux-lib.sh"

usage(){ echo "usage: $(basename "$0") [sid] [--cancel] [--compact-only]" >&2; exit 2; }

# --- parse args (a lone non-flag token is an explicit sid) ---
# --compact-only raises a *compact-request* instead of a handoff-request: the
# session has ALREADY written its handoff and only needs the watcher to finish
# (skip /handoff, go straight to /compact -> reload). It also snapshots the
# global .latest pointer into a per-session .latest.<sid> so the reload is immune
# to another concurrent session clobbering .latest.
CANCEL=0
COMPACT_ONLY=0
SID_ARG=""
for a in "$@"; do
  case "$a" in
    --cancel) CANCEL=1 ;;
    --compact-only) COMPACT_ONLY=1 ;;
    -h|--help) usage ;;
    -*) echo "unknown option: $a" >&2; usage ;;
    *) [ -n "$SID_ARG" ] && { echo "too many arguments" >&2; usage; }; SID_ARG="$a" ;;
  esac
done

# --- resolve this session's sid ---
# Priority: explicit arg > $CLAUDE_CODE_SESSION_ID > reverse pane-owner file.
#
# The env var is the AUTHORITATIVE identity of the calling process — it cannot
# mis-name us as a different session. The reverse pane-owner file is a *shared*,
# last-writer-wins resource: because herdr recycles short pane ids, a stale entry
# can name a DIFFERENT live session that now occupies "our" pane id, and the
# watcher's ownership gate would then happily hand THAT session off. So the env
# var wins, and the pane-owner file is only a fallback for an older Claude Code
# that doesn't export it. If BOTH resolve and DISAGREE, we refuse to guess (it
# signals a recycled pane, or the helper being run from a subagent whose child
# sid differs from the pane's owner) and require an explicit sid.
pane_owner_sid(){
  command -v mux_owner_file >/dev/null 2>&1 || return 1
  local o v
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    o=$(mux_owner_file herdr "$HERDR_PANE_ID"); v=$(cat "$o" 2>/dev/null)
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    o=$(mux_owner_file tmux "$TMUX_PANE"); v=$(cat "$o" 2>/dev/null)
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  fi
  return 1
}

if [ -n "$SID_ARG" ]; then
  sid="$SID_ARG"
else
  env_sid="${CLAUDE_CODE_SESSION_ID:-}"
  pane_sid=$(pane_owner_sid || true)
  if [ -n "$env_sid" ] && [ -n "$pane_sid" ] && [ "$env_sid" != "$pane_sid" ]; then
    echo "refusing to guess: session env id '$env_sid' disagrees with pane owner '$pane_sid'" >&2
    echo "(recycled pane, or run from a subagent) — pass the target sid explicitly: $(basename "$0") <sid>" >&2
    exit 2
  fi
  sid="${env_sid:-$pane_sid}"
  [ -n "$sid" ] || { echo "could not resolve session id — pass it explicitly: $(basename "$0") <sid>" >&2; exit 2; }
fi

# --- sid safety guard: positive charset only. The sid becomes part of a file
# path we create/remove AND is written verbatim into the shared log, so anything
# outside [A-Za-z0-9._-] (path separators, "..", whitespace, control/ANSI bytes)
# is refused — that blocks path traversal and log injection in one check. Real
# session ids are UUIDs, well within this set. ---
case "$sid" in
  ""|*[!A-Za-z0-9._-]*) echo "refusing unsafe session id: '$sid'" >&2; exit 2 ;;
esac

mkdir -p "$STATE" "$LOGDIR" 2>/dev/null
log(){ printf '%s [%s] %s\n' "$(date +'%Y.%m.%d %H.%M.%S')" "$sid" "$*" >> "$LOG"; }

# Which marker this invocation operates on. compact-only uses a distinct marker
# so the watcher can tell "already handed off, just compact" from "do the full
# handoff+compact cycle" — they must not alias.
if [ "$COMPACT_ONLY" = 1 ]; then
  req="$STATE/$sid.compact-request"; kind="compact-request"
else
  req="$STATE/$sid.handoff-request"; kind="handoff-request"
fi

if [ "$CANCEL" = 1 ]; then
  if [ -e "$req" ]; then
    rm -f "$req" 2>/dev/null
    log "REQUEST cancelled (voluntary, $kind)"
    echo "$kind cancelled for $sid"
  else
    echo "no pending $kind for $sid"
  fi
  exit 0
fi

# --- compact-only: defer when a watcher cycle is already in progress. ---
# If the watcher holds this session's cycle lock, it is (or is about to be) doing
# the /handoff -> /compact -> reload itself. Filing a compact-request here would
# survive that cycle and fire a SECOND, spurious /compact on the reloaded session.
# So detect the live lock and defer — the watcher will compact on its own.
if [ "$COMPACT_ONLY" = 1 ]; then
  lock="$STATE/$sid.cycle.lock"
  if [ -d "$lock" ]; then
    lpid=$(cat "$lock/pid" 2>/dev/null || true)
    if [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null; then
      log "COMPACT-REQUEST deferred — watcher cycle in progress (pid $lpid)"
      echo "auto-handoff watcher is already mid-cycle for $sid — it will compact; no marker filed"
      exit 0
    fi
  fi
fi

# Soft sanity check: the watcher can only act with BOTH a context file (it reads
# pct and exits early without one) AND a registered pane. If EITHER is missing the
# request is valid but won't fire until the gap closes (usually the next statusline
# render), so warn precisely rather than promising the next idle Stop. We still
# write the marker — it's harmless, idempotent, and typically becomes live shortly.
have_ctx=0;  [ -e "$STATE/$sid.ctx" ] && have_ctx=1
have_pane=0; { [ -e "$STATE/$sid.herdr-pane" ] || [ -e "$STATE/$sid.tmux-pane" ]; } && have_pane=1
warn=""
[ "$have_ctx" = 0 ]  && warn="${warn}no .ctx; "
[ "$have_pane" = 0 ] && warn="${warn}no registered pane; "

# Atomic write via tmp+mv so we (a) never follow a symlink at "$req" and truncate
# its target, and (b) set a clean, current mtime for the watcher's TTL. The marker
# body stays empty — mtime is the whole contract.
tmp="$req.tmp.$$"
: > "$tmp" 2>/dev/null && mv -f "$tmp" "$req" 2>/dev/null || {
  rm -f "$tmp" 2>/dev/null; echo "failed to write $req" >&2; exit 2; }

# For compact-only, snapshot the global .latest pointer into a per-session copy
# NOW, while it still names THIS session's just-written handoff. The reload step
# (watcher / SessionStart hook) prefers .latest.<sid>, so a later clobber of the
# shared .latest by another concurrent session cannot redirect our reload.
if [ "$COMPACT_ONLY" = 1 ]; then
  gl="$AUTODEV_HOME/handoffs/.latest"
  per="$AUTODEV_HOME/handoffs/.latest.$sid"
  if [ -s "$gl" ]; then
    ptmp="$per.tmp.$$"
    cp -f "$gl" "$ptmp" 2>/dev/null && mv -f "$ptmp" "$per" 2>/dev/null || rm -f "$ptmp" 2>/dev/null
    log "snapshot .latest -> .latest.$sid"
  fi
fi

log "REQUEST raised (voluntary $kind${warn:+; ${warn%; }})"
act="hand off"; [ "$COMPACT_ONLY" = 1 ] && act="compact and reload"
if [ -n "$warn" ]; then
  echo "$kind raised for $sid, but it will NOT fire yet — ${warn%; }" >&2
  echo "(it becomes live once the session registers; the watcher acts on the next idle Stop after that)" >&2
else
  echo "$kind raised for $sid — the auto-handoff watcher will $act at the next idle Stop"
fi
exit 0
