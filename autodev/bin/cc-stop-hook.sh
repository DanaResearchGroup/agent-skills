#!/usr/bin/env bash
# Claude Code Stop hook: fires when an assistant turn fully completes.
# Marks the session idle and launches the (detached) auto-handoff watcher.
# Normally silent. Single exception: at threshold, when the watcher cannot drive
# this session, block once to request an in-session handoff (or human /compact).
# Active Stop continuations (including /goal) use the same 900-second cooldown
# and once-per-request compact notice, so crossing threshold mid-loop is covered.
# Second exception: a refused herdr pane with a pending request gets the gate's
# AskUserQuestion instruction instead of the prose fallback: once if no tool call
# gave it, once more if the turn ended without the question (cc-handoff-gate.sh --stop).
input=$(cat)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${AUTODEV_HOME:=$HOME/agents}"; export AUTODEV_HOME
STATE="$AUTODEV_HOME/state"
mkdir -p "$STATE" 2>/dev/null

# Multiplexer abstraction (herdr | tmux) for pane registration.
[ -f "$HERE/mux-lib.sh" ] && . "$HERE/mux-lib.sh"
# limit-lib.sh: whether a session's usage-limit wait is still active (a stale
# <sid>.limit-wait is ignored and removed). Without it, fall back to presence.
[ -f "$HERE/limit-lib.sh" ] && . "$HERE/limit-lib.sh"
command -v autodev_limit_wait_active >/dev/null 2>&1 ||
  autodev_limit_wait_active(){ [ -f "$1/$2.limit-wait" ]; }

sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
tpath=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
[ -z "$sid" ] && [ -n "$tpath" ] && sid=$(basename "$tpath" .jsonl)
case "$sid" in ""|*[!A-Za-z0-9._-]*|.|..) exit 0 ;; esac

printf '%s\n' "$(date +%s)" > "$STATE/$sid.idle" 2>/dev/null
# Redundant pane capture (Stop hook inherits CC's herdr/tmux env).
if command -v mux_register >/dev/null 2>&1; then
  mux_register "$sid"
elif [ -n "${TMUX_PANE:-}" ]; then
  printf '%s\n' "$TMUX_PANE" > "$STATE/$sid.tmux-pane" 2>/dev/null
fi

# This path works inside the background worker even when no terminal hosts it.
# Serialize with watcher cycles; re-read context, reachability, requests, and
# cooldown AFTER taking the lock so overlapping Stops cannot double-block.

# Refused herdr pane (<sid>.unreachable) with a pending request: the PreToolUse
# gate owns the user instruction (exit 3), an AskUserQuestion notice instead of
# the fallback's prose "type /compact". If no tool call gave the notice yet, this
# Stop gives it; if one did and the turn ended without the question, it is
# repeated once; otherwise the Stop is silent. Any other exit: fallback as before.
gate_stop() {
  gate_out=$(printf '%s' "$input" | bash "$HERE/cc-handoff-gate.sh" --stop 2>/dev/null)
  gate_rc=$?
}

stop_fallback() (
  [ -f "$STATE/auto-handoff.armed" ] || return 1
  [ -f "$STATE/disable-auto-compact" ] && return 1
  autodev_limit_wait_active "$STATE" "$sid" && return 1
  [ -f "$HERE/lock-lib.sh" ] && . "$HERE/lock-lib.sh" || return 1
  [ -f "$HERE/threshold-lib.sh" ] && . "$HERE/threshold-lib.sh" || return 1
  local lock="$STATE/$sid.cycle.lock" busy_n=0 failed=0 now last=0 key="" kind f
  local pending=0 fresh_keys="" receipts="$STATE/$sid.fallback-request"
  autodev_lock_publish "$lock" "$$" || return 1
  trap 'autodev_lock_release_owned "$lock" "$$"' EXIT
  [ -f "$STATE/auto-handoff.armed" ] || return 1
  [ -f "$STATE/disable-auto-compact" ] && return 1
  autodev_limit_wait_active "$STATE" "$sid" && return 1
  [ "$STATE/$sid.compacted" -nt "$STATE/$sid.ctx" ] && return 1
  # Past the line: pct >= 35, or a Persona seat's token line (threshold-lib.sh).
  autodev_ctx_over "$STATE" "$sid" ge || {
    rm -f "$STATE/$sid.busy-deferrals" 2>/dev/null
    return 1
  }
  mux_session_reachable "$sid" || failed=1
  # Metadata stays reachable so the watcher can retry its screen check. A
  # persisted screen refusal still needs the in-session handoff fallback.
  if grep -q '^screen presence unproved:' "$STATE/$sid.unreachable" 2>/dev/null; then
    failed=1
  fi
  if [ -f "$STATE/$sid.busy-deferrals" ] &&
     ! [ "$STATE/$sid.compacted" -nt "$STATE/$sid.busy-deferrals" ]; then
    busy_n=$(cat "$STATE/$sid.busy-deferrals" 2>/dev/null)
  fi
  case "$busy_n" in ''|*[!0-9]*) busy_n=0 ;; esac
  [ "$failed" = 1 ] || [ "$busy_n" -ge 3 ] || return 1

  # Once a request exists, repeating /handoff would feed the pending-request
  # tool gate and /goal loop. One human instruction per request, independent of
  # the ordinary fallback cooldown; receipts prevent repeated continuation blocks.
  for kind in handoff-request compact-request; do
    f="$STATE/$sid.$kind"
    if [ -f "$f" ] && ! [ "$STATE/$sid.compacted" -nt "$f" ]; then
      pending=1
      key="$kind:$(date -r "$f" +%s%N 2>/dev/null)"
      if ! grep -qxF "$key" "$receipts" 2>/dev/null; then
        fresh_keys="$fresh_keys$key"$'\n'
      fi
    fi
  done
  if [ "$pending" = 1 ]; then
    # The reachability check above may have just refused the pane (a worker
    # with no herdr env registers nothing earlier): consult the gate again.
    gate_stop
    if [ "$gate_rc" = 3 ]; then
      [ -n "$gate_out" ] || return 1
      printf '%s\n' "$gate_out"
      return 0
    fi
    [ -n "$fresh_keys" ] || return 1
    # Keep receipts for earlier requests too: a superseding sibling marker
    # disappearing must not re-arm the notice for an already reported marker.
    { [ ! -f "$receipts" ] || cat "$receipts"; printf '%s' "$fresh_keys"; } > "$receipts.tmp.$$" &&
      mv "$receipts.tmp.$$" "$receipts" || return 1
    printf '%s\n' '{"decision":"block","reason":"type /compact"}'
    return 0
  fi

  now=$(date +%s)
  [ -f "$STATE/$sid.fallback-cooldown" ] && last=$(cat "$STATE/$sid.fallback-cooldown" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ "$(( now - last ))" -ge 900 ] || return 1
  printf '%s\n' "$now" > "$STATE/$sid.fallback-cooldown.tmp.$$" &&
    mv "$STATE/$sid.fallback-cooldown.tmp.$$" "$STATE/$sid.fallback-cooldown" || return 1
  local hf="$AUTODEV_HOME/handoffs/handoff-$sid.md" command
  printf -v command '%q %q --compact-only --handoff %q' "$HERE/request-handoff.sh" "$sid" "$hf"
  jq -nc --arg reason "Auto-handoff cannot drive this session. Run /handoff to write $hf, then run $command." \
    '{decision:"block",reason:$reason}'
)
gate_stop
if [ "$gate_rc" = 3 ]; then
  [ -n "$gate_out" ] && { printf '%s\n' "$gate_out"; exit 0; }
elif stop_fallback; then exit 0; fi

# Test seam shared with the Codex Stop hook; production launches normally.
[ "${AUTODEV_NO_WATCHERS:-0}" = 1 ] && exit 0

# Launch the watchers fully detached so they survive this hook returning and can
# poll for later turns. Each self-gates (threshold, lock, cooldown, arm).
#  - auto-handoff-watch: context-% threshold -> handoff/compact/reload.
#  - session-resume-watch (Phoenix): usage/session-limit banner -> usage-credits or
#    wait-for-reset -> continue.
#  - cache-warm-watch: prompt-cache TTL -> countdown in the tab label. Turn end is
#    exactly when the cache starts ageing unobserved, because the status line
#    stops being rendered the moment CC goes idle.
setsid "$HERE/auto-handoff-watch.sh" "$sid" </dev/null >/dev/null 2>&1 &
setsid "$HERE/session-resume-watch.sh" "$sid" </dev/null >/dev/null 2>&1 &
setsid "$HERE/cache-warm-watch.sh" "$sid" "$tpath" </dev/null >/dev/null 2>&1 &
exit 0
