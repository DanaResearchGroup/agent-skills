#!/usr/bin/env bash
# A usage-limit wait past its until= while the resume cycle still holds the
# session's resume lock (limit-lib.sh, autodev_limit_wait_active).
#
# What went wrong (I-460): once until= passed, the wait read as over even while
# the resume cycle that wrote it was alive. That cycle was then reading the pane
# and could wait up to 30 s more for an idle pane before sending "continue", so
# a handoff watcher running in that gap sent /handoff or /compact on top of it.
# A resume lock held by an owner that is not provably gone (_limit_lock_dead)
# now counts as an active wait; a lock whose owner is gone keeps the old path,
# where the stale wait is reaped.

. "$(dirname "$0")/lib.sh"

SID=46046046-0460-0460-0460-046046046046
export AUTODEV_SETTLE=0 AUTODEV_POLL=1 AUTODEV_WAIT_IDLE=2 AUTODEV_WAIT_COMPACT=2

setup() {
  sandbox_new
  stub_mux
  arm
  session_new "$SID" 50 "w1:p1"          # past the line: the watcher would send
  export MUX_LIVE_PANES="w1:p1" MUX_BUSY=0
  holder=""
}
teardown() {
  [ -n "$holder" ] && { kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; }
  holder=""
  sandbox_rm
}
LOG() { cat "$AUTODEV_HOME/logs/auto-handoff.log" 2>/dev/null; }
sent() { cat "$SB/sent.log" 2>/dev/null; }
expired_wait() { # until= passed 10 s ago, the wait began an hour ago
  local now; now=$(date +%s)
  printf 'until=%s reset=%s human=7:30am ts=%s\n' "$(( now - 10 ))" "$(( now - 250 ))" "$(( now - 3600 ))" \
    > "$STATE/$SID.limit-wait"
}
hold_lock() { # a live resume cycle: a sleep child owns the lock
  sleep 300 & holder=$!
  ( . "$BIN/limit-lib.sh"; autodev_resume_lock_take "$STATE" "$SID" "$holder" )
}
kill_holder() { kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; }
active() { ( . "$BIN/limit-lib.sh"; autodev_limit_wait_active "$STATE" "$SID" "$@" ); }
lock_pid() { cat "$STATE/$SID.resume.lock/pid" 2>/dev/null; }
handoff() { timeout 30 bash "$BIN/auto-handoff-watch.sh" "$SID" </dev/null >/dev/null 2>&1; }

echo "== live_lock_holds_expired_wait: until= passed, a live cycle holds the lock =="
setup
expired_wait; hold_lock
active; rc=$?
assert_eq "an expired wait under a live owner's lock is active" "$rc" 0
assert_file "the wait is kept for that cycle to end" "$STATE/$SID.limit-wait"
assert_eq "the lock is left with its owner" "$(lock_pid)" "$holder"
teardown

echo "== handoff_watcher_holds_off: the watcher sends nothing while the cycle lives =="
setup
expired_wait; hold_lock
handoff
assert_contains "the watcher skips the session" "$(LOG)" "SKIP session-limit resume pending"
assert_not_contains "and does not drop the wait" "$(LOG)" "DROP stale limit-wait"
assert_eq "nothing is sent to the pane" "$(sent)" ""
assert_file "the wait is kept" "$STATE/$SID.limit-wait"
assert_eq "the lock is left with its owner" "$(lock_pid)" "$holder"
kill_holder

echo "== dead_holder_reaps_and_proceeds: the same state once the cycle is gone =="
handoff
assert_contains "the stale wait is dropped" "$(LOG)" "DROP stale limit-wait (its wait is over); proceeding"
assert_no_file "and removed" "$STATE/$SID.limit-wait"
assert_lock_absent "the dead owner's lock is reclaimed and released" "$STATE/$SID.resume.lock"
assert_contains "the watcher proceeds and sends" "$(sent)" "/handoff"
teardown

echo "== pidless_young_lock_holds: a lock between its mkdir and its pid write =="
setup
expired_wait
mkdir "$STATE/$SID.resume.lock"
active; rc=$?
assert_eq "a pid-less lock younger than the grace is a live owner: active" "$rc" 0
assert_file "the wait is kept" "$STATE/$SID.limit-wait"
touch -d '27 hours ago' "$STATE/$SID.resume.lock"
active; rc=$?
assert_eq "a pid-less lock older than the grace is gone: not active" "$rc" 1
assert_no_file "and the stale wait is reaped" "$STATE/$SID.limit-wait"
teardown

echo "== no_reap_reads_lock_only: the status line neither takes nor breaks the lock =="
setup
expired_wait; hold_lock
ino=$(stat -c %i "$STATE/$SID.resume.lock")
active --no-reap; rc=$?
assert_eq "--no-reap, live owner: active" "$rc" 0
assert_eq "--no-reap leaves the owner's pid" "$(lock_pid)" "$holder"
assert_eq "--no-reap leaves the same lock directory" "$(stat -c %i "$STATE/$SID.resume.lock")" "$ino"
assert_file "--no-reap keeps the wait" "$STATE/$SID.limit-wait"
kill_holder
active --no-reap; rc=$?
assert_eq "--no-reap, dead owner: not active" "$rc" 1
assert_eq "--no-reap does not reclaim a dead owner's lock" "$(stat -c %i "$STATE/$SID.resume.lock" 2>/dev/null)" "$ino"
assert_file "--no-reap still keeps the stale wait" "$STATE/$SID.limit-wait"
rm -rf "$STATE/$SID.resume.lock"
active --no-reap; rc=$?
assert_eq "--no-reap, no lock: not active" "$rc" 1
assert_lock_absent "--no-reap creates no lock" "$STATE/$SID.resume.lock"
teardown

echo "== statusline_badge_during_gap: the badge stays on while the cycle lives =="
setup
expired_wait; hold_lock
badge() { printf '{"session_id":"%s","model":{"display_name":"Opus"}}' "$SID" |
          bash "$BIN/cc-statusline.sh" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'; }
assert_contains "until= passed, live owner: the AUTO-RESUME badge stays" "$(badge)" "⏳ AUTO-RESUME @ 7:30am"
assert_eq "and the status line leaves the lock with its owner" "$(lock_pid)" "$holder"
kill_holder
assert_not_contains "the owner gone: no AUTO-RESUME badge" "$(badge)" "AUTO-RESUME"
assert_file "and the status line leaves the stale wait to the watchers" "$STATE/$SID.limit-wait"
teardown

echo "== lock_taken_while_reaper_reaches_it: a cycle starts between the read and the lock =="
# The reaper reads an expired wait; before its take, a new live cycle takes the
# lock. The take is refused, and the reaper must read that as an active wait.
setup
expired_wait
sleep 300 & holder=$!
( . "$BIN/limit-lib.sh"
  eval "orig_take() $(declare -f autodev_resume_lock_take | tail -n +2)"
  autodev_resume_lock_take(){ orig_take "$1" "$2" "$holder"; orig_take "$@"; }
  autodev_limit_wait_active "$STATE" "$SID" ); rc=$?
assert_eq "a live cycle took the lock first: active" "$rc" 0
assert_file "the wait is kept" "$STATE/$SID.limit-wait"
assert_eq "the lock is the new cycle's" "$(lock_pid)" "$holder"
teardown

echo "== owner_ends_while_reaper_reaches_it: the cycle ends after the refused take =="
# The take is refused by a live cycle, which then ends (removes its wait, then
# its lock) before the reaper looks at the lock: the wait is over.
setup
expired_wait; hold_lock
( . "$BIN/limit-lib.sh"
  eval "orig_take() $(declare -f autodev_resume_lock_take | tail -n +2)"
  autodev_resume_lock_take(){
    orig_take "$@" && return 0
    rm -f "$1/$2.limit-wait"; autodev_resume_lock_release "$1" "$2"
    return 1
  }
  autodev_limit_wait_active "$STATE" "$SID" ); rc=$?
assert_eq "the owner ended in between: not active" "$rc" 1
assert_lock_absent "and no lock is left behind" "$STATE/$SID.resume.lock"
teardown

echo "== active_wait_unchanged: a wait before its until= needs no lock =="
setup
now=$(date +%s)
printf 'until=%s reset=%s human=x ts=%s\n' "$(( now + 600 ))" "$(( now + 360 ))" "$(( now - 60 ))" > "$STATE/$SID.limit-wait"
active; rc=$?
assert_eq "active by its values alone" "$rc" 0
assert_lock_absent "and no lock is taken for it" "$STATE/$SID.resume.lock"
teardown

finish
