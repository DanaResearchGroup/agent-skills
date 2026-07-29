#!/usr/bin/env bash
# An aborted cycle used to be terminal: the request marker is consumed BEFORE the
# sends, a cooldown is stamped, and the watcher exits. Nothing was left to say
# the cycle had failed, and nothing would run again, because the only launcher
# was the Stop hook and a parked session produces no more turn ends.
#
# The consecutive-abort counter is what lets auto-handoff-sweep.sh tell "retry
# this" from "this session is wedged — stop typing at it and put it on screen".

. "$(dirname "$0")/lib.sh"

SID=44444444-4444-4444-4444-444444444444

# Keep a failing cycle short: we WANT the /compact confirmation to time out.
export AUTODEV_WAIT_COMPACT=4 AUTODEV_POLL=1 AUTODEV_SETTLE=0

setup() {
  sandbox_new
  stub_mux
  arm
  session_new "$SID" 55 "w1:p1"
  export MUX_LIVE_PANES="w1:p1" MUX_BUSY=0
  H="$AUTODEV_HOME/handoffs/2026.01.03 00.00.00 handoff-ours.md"
  printf 'ours\n' > "$H"
  printf '%s\n' "$H" > "$AUTODEV_HOME/handoffs/.latest.$SID"
}

run_failing_cycle() {
  : > "$STATE/$SID.compact-request"
  rm -f "$STATE/$SID.cooldown"
  bash "$BIN/auto-handoff-watch.sh" "$SID" >/dev/null 2>&1
}

echo "== an aborted cycle leaves evidence =="

setup
run_failing_cycle
assert_eq "first abort is counted" "$(cat "$STATE/$SID.abort-count" 2>/dev/null)" "1"
run_failing_cycle
assert_eq "consecutive aborts accumulate" "$(cat "$STATE/$SID.abort-count" 2>/dev/null)" "2"
sandbox_rm

echo "== a completed cycle clears it =="

setup
printf '3\n' > "$STATE/$SID.abort-count"
: > "$STATE/$SID.stuck"
: > "$STATE/$SID.compact-request"
(
  for _ in $(seq 1 200); do
    if grep -qxF '/compact' "$SB/sent.log" 2>/dev/null; then
      sleep 1; printf '%s\n' "$(date +%s)" > "$STATE/$SID.compacted"; exit 0
    fi
    sleep 0.5
  done
) &
bash "$BIN/auto-handoff-watch.sh" "$SID" >/dev/null 2>&1
assert_no_file "a completed cycle clears the abort counter" "$STATE/$SID.abort-count"
assert_no_file "a completed cycle clears the stuck flag" "$STATE/$SID.stuck"
sandbox_rm

echo "== the sweeper retries, then gives up loudly =="

# A session that aborted is exactly what the sweeper exists to retry.
setup
stub_watcher
printf '2\n' > "$STATE/$SID.abort-count"
bash "$BIN/auto-handoff-sweep.sh" >/dev/null 2>&1
assert_launched "a session with aborted cycles is retried" "$SID"
sandbox_rm

# ...but not forever. A wedged pane must stop being typed at, and must become
# visible instead of quietly sitting there looking healthy.
setup
stub_watcher
printf '5\n' > "$STATE/$SID.abort-count"
bash "$BIN/auto-handoff-sweep.sh" >/dev/null 2>&1
assert_not_launched "a wedged session stops being driven" "$SID"
assert_file "a wedged session is flagged for the status line" "$STATE/$SID.stuck"
sandbox_rm

echo "== a completed cycle does not re-fire on an idle session =="

# Without this guard the sweeper would re-handoff a parked session every cooldown
# forever, because its context % stays above the threshold and never moves.
setup
stub_watcher
touch -d '2 hours ago' "$STATE/$SID.ctx"
touch -d '1 hour ago' "$STATE/$SID.cooldown"
bash "$BIN/auto-handoff-sweep.sh" >/dev/null 2>&1
assert_not_launched "idle session with no progress since its last cycle is left alone" "$SID"
sandbox_rm

# But once the session actually does something again, it is fair game.
setup
stub_watcher
touch -d '1 hour ago' "$STATE/$SID.cooldown"
touch "$STATE/$SID.ctx"
bash "$BIN/auto-handoff-sweep.sh" >/dev/null 2>&1
assert_launched "session that has made progress since its last cycle is swept" "$SID"
sandbox_rm

finish
