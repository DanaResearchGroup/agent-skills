#!/usr/bin/env bash
# Bug: a session reports high context, stops, and waits for the auto-handoff —
# and nothing ever happens.
#
# Root cause: auto-handoff-watch.sh is EDGE-triggered. cc-stop-hook.sh launches
# it once per turn end; it evaluates once and exits. But the condition it guards
# is a LEVEL ("this session is parked with high context"). A parked session
# emits no further turn-end edges, and an idle session's context % never rises,
# so every declined evaluation — DEFER (busy pane), ABORT (/handoff or /compact
# unconfirmed), SKIP (cooldown, cycle lock) — is terminal. Worse, the request
# marker is consumed BEFORE the sends, so an aborted cycle leaves no trigger
# behind at all. The session parks forever.
#
# cc-stall-watchdog.sh already learned this lesson ("NEVER by a Claude Code
# hook: hook-driven watchers only wake when a turn ends, which is exactly the
# blind spot that produced 36 h stalls") but the auto-handoff watcher was never
# migrated. auto-handoff-sweep.sh supplies the missing level trigger.

. "$(dirname "$0")/lib.sh"

SID=33333333-3333-3333-3333-333333333333

setup() {
  sandbox_new
  stub_mux
  stub_watcher
  arm
}

sweep() { bash "$BIN/auto-handoff-sweep.sh" >/dev/null 2>&1; }

echo "== the parked session =="

# No markers, no edges, nobody typing: exactly the state a session is left in
# after it says "I'll wait for the auto-handoff".
setup
session_new "$SID" 47 "w1:p1"
export MUX_LIVE_PANES="w1:p1" MUX_BUSY=0
sweep
assert_launched "parked session above threshold gets re-evaluated" "$SID"
sandbox_rm

# A voluntary request below the threshold must also survive having no edges.
setup
session_new "$SID" 12 "w1:p1"
export MUX_LIVE_PANES="w1:p1" MUX_BUSY=0
: > "$STATE/$SID.compact-request"
sweep
assert_launched "below-threshold session with a pending request is re-evaluated" "$SID"
sandbox_rm

echo "== the sweeper must stay cheap and safe =="

# 200+ dead sessions' .ctx files linger in ~/agents/state forever. Sweeping must
# not spawn a watcher for each one every tick.
setup
session_new "$SID" 90 "w9:pDEAD"
export MUX_LIVE_PANES="w1:p1" MUX_BUSY=0     # this session's pane is gone
sweep
assert_not_launched "dead pane is never driven" "$SID"
sandbox_rm

# The kill switch must beat everything.
setup
session_new "$SID" 90 "w1:p1"
export MUX_LIVE_PANES="w1:p1" MUX_BUSY=0
: > "$STATE/disable-auto-compact"
sweep
assert_not_launched "global kill switch stops the sweep" "$SID"
sandbox_rm

# A cycle that is genuinely in flight must not be piled onto.
setup
session_new "$SID" 90 "w1:p1"
export MUX_LIVE_PANES="w1:p1" MUX_BUSY=0
mkdir -p "$STATE/$SID.cycle.lock"
sleep 300 & printf '%s\n' "$!" > "$STATE/$SID.cycle.lock/pid"
LOCKPID=$!
sweep
assert_not_launched "live cycle lock is respected" "$SID"
kill "$LOCKPID" 2>/dev/null
sandbox_rm

# A cycle that just ran must not immediately re-run.
setup
session_new "$SID" 90 "w1:p1"
export MUX_LIVE_PANES="w1:p1" MUX_BUSY=0
date +%s > "$STATE/$SID.cooldown"
sweep
assert_not_launched "fresh cooldown is respected" "$SID"
sandbox_rm

# Below threshold with nothing pending is simply not our business.
setup
session_new "$SID" 8 "w1:p1"
export MUX_LIVE_PANES="w1:p1" MUX_BUSY=0
sweep
assert_not_launched "quiet low-context session is left alone" "$SID"
sandbox_rm

# A pane that herdr has since recycled onto a different session must never be
# driven — that would hand someone else's session our /compact.
setup
session_new "$SID" 90 "w1:p1"
printf '%s\n' "99999999-9999-9999-9999-999999999999" > "$STATE/.paneowner-herdr-w1_p1"
export MUX_LIVE_PANES="w1:p1" MUX_BUSY=0
sweep
assert_not_launched "recycled pane owned by another session is not driven" "$SID"
sandbox_rm

finish
