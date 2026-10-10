#!/usr/bin/env bash
# Bug: a PM at ~10% context gets a second /compact about 15 minutes after a
# watcher cycle already compacted it.
#
# The watcher drives /handoff; the handoff skill then runs
# `request-handoff.sh --compact-only`. Its mid-cycle deferral checks the
# watcher's lock pid with `kill -0`, and from a sandboxed session that pid is in
# another PID namespace, so the check fails and a compact-request is filed
# mid-cycle. The watcher compacts, and once the cooldown lapses the leftover
# marker fires again on the already-compacted session. Measured on the live log:
# the deferral last fired 2026-09-24 06:30, and 498 compact-only cycles since then
# ran within an hour of a completed cycle.
#
# These tests inject the marker the sandboxed request-handoff.sh files, rather
# than trying to reproduce the namespace, and pin what the watcher does with it.

. "$(dirname "$0")/lib.sh"

SID=66666666-6666-6666-6666-666666666666
export AUTODEV_SETTLE=0 AUTODEV_POLL=1 AUTODEV_WAIT_IDLE=30 AUTODEV_WAIT_COMPACT=30

setup() { # $1 = pct
  sandbox_new
  stub_mux
  arm
  session_new "$SID" "$1" "w1:p1"
  export MUX_LIVE_PANES="w1:p1" MUX_BUSY=0
  H="$AUTODEV_HOME/handoffs/2026.01.01 00.00.00 handoff-ours.md"
  printf 'ours\n' > "$H"
  printf '%s\n' "$H" > "$AUTODEV_HOME/handoffs/.latest.$SID"
}

# Play the session's side of a cycle. On /handoff: finish the turn and, like the
# handoff skill in a sandboxed session, file a compact-request mid-cycle. On
# /compact: write the completion marker CC's SessionStart hook would write,
# unless $1 = nocompact.
session_responder() { # $1 = compact | nocompact
  (
    handed=0
    for _ in $(seq 1 200); do
      if [ "$handed" = 0 ] && grep -qxF '/handoff' "$SB/sent.log" 2>/dev/null; then
        sleep 1
        : > "$STATE/$SID.compact-request"
        printf '%s\n' "$(date +%s)" > "$STATE/$SID.idle"
        handed=1
      fi
      if grep -qxF '/compact' "$SB/sent.log" 2>/dev/null; then
        [ "$1" = compact ] || exit 0
        sleep 1
        printf '%s\n' "$(date +%s)" > "$STATE/$SID.compacted"
        exit 0
      fi
      sleep 0.5
    done
  ) &
  responder=$!
}

run_watch() { bash "$BIN/auto-handoff-watch.sh" "$SID" >/dev/null 2>&1; wait "$responder" 2>/dev/null; }
LOGF() { echo "$AUTODEV_HOME/logs/auto-handoff.log"; }

echo "== a compact-request filed mid-cycle =="

# The live failure: a threshold cycle whose /handoff turn files a compact-request.
setup 40
session_responder compact
run_watch
log=$(cat "$(LOGF)")
assert_contains "the cycle itself completed" "$log" "CYCLE COMPLETE (threshold"
assert_no_file "the marker filed during the cycle is gone after compaction" "$STATE/$SID.compact-request"
assert_contains "the drop is logged" "$log" "DROP compact-request filed during this cycle"
# The symptom itself: once the cooldown lapses, the next idle Stop on the
# compacted session (now ~10%) must not compact it again.
session_new "$SID" 10 "w1:p1"
printf '%s\n' "$(( $(date +%s) - 3600 ))" > "$STATE/$SID.cooldown"
bash "$BIN/auto-handoff-watch.sh" "$SID" >/dev/null 2>&1
assert_eq "no second /compact after the cooldown lapses" "$(grep -cxF '/compact' "$SB/sent.log")" 1
sandbox_rm

# The cycle did NOT compact (the /compact never completed): the request has not
# been satisfied, so it must survive to be retried.
setup 40
AUTODEV_WAIT_COMPACT=3 session_responder nocompact
AUTODEV_WAIT_COMPACT=3 bash "$BIN/auto-handoff-watch.sh" "$SID" >/dev/null 2>&1
wait "$responder" 2>/dev/null
assert_file "an unsatisfied compact-request survives an aborted cycle" "$STATE/$SID.compact-request"
sandbox_rm

echo "== a compact-request filed around the compaction =="

# Play the session's side with the request filed relative to completion. pending:
# the request lands after /compact was sent but before .compacted is written, so
# the compaction that follows satisfies it. after: it lands just after
# .compacted, as the reloaded session would file a new ask; the short pause
# clears the filesystem's coarse timestamp tick but stays inside the stamp's
# one-second resolution, so the two compare equal by second.
# tie: it lands with exactly the completion stamp's mtime (one coarse clock tick),
# where the order is unknowable; it is kept, since a lost request parks the
# session while a kept one costs at most one extra /compact.
compact_responder() { # $1 = pending | after | tie
  (
    for _ in $(seq 1 200); do
      if grep -qxF '/handoff' "$SB/sent.log" 2>/dev/null; then
        sleep 1; printf '%s\n' "$(date +%s)" > "$STATE/$SID.idle"; break
      fi
      sleep 0.2
    done
    for _ in $(seq 1 200); do
      if grep -qxF '/compact' "$SB/sent.log" 2>/dev/null; then
        sleep 1
        [ "$1" = pending ] && { : > "$STATE/$SID.compact-request"; sleep 0.05; }
        printf '%s\n' "$(date +%s)" > "$STATE/$SID.compacted"
        [ "$1" = after ] && { sleep 0.05; : > "$STATE/$SID.compact-request"; }
        [ "$1" = tie ] && { : > "$STATE/$SID.compact-request"
          touch -r "$STATE/$SID.compacted" "$STATE/$SID.compact-request"; }
        exit 0
      fi
      sleep 0.2
    done
  ) &
  responder=$!
}

setup 40
compact_responder pending
run_watch
assert_no_file "a request filed while the compaction was pending is dropped" "$STATE/$SID.compact-request"
sandbox_rm

setup 40
compact_responder after
run_watch
assert_file "a request filed after the compaction completed is kept" "$STATE/$SID.compact-request"
sandbox_rm

setup 40
compact_responder tie
run_watch
assert_file "a request tied with the completion stamp is kept" "$STATE/$SID.compact-request"
sandbox_rm

finish
