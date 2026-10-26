#!/usr/bin/env bash
# Stale cycle-lock reclaim must serialize contenders, verify ownership after mkdir,
# and preserve locks that have changed owner while a watcher is acquiring them.

. "$(dirname "$0")/lib.sh"

SID=88888888-8888-8888-8888-888888888888

setup() {
  sandbox_new
  stub_mux
  session_new "$SID" 55 "w1:p1"
  export MUX_LIVE_PANES="w1:p1" MUX_BUSY=0
  export AUTODEV_SETTLE=0 AUTODEV_PRECHECK=1 AUTODEV_WAIT_IDLE=60 AUTODEV_WAIT_COMPACT=60
  LOCK="$STATE/$SID.cycle.lock"
  mkdir -p "$SB/fakebin"
  cat > "$SB/fakebin/rm" <<'STUB'
#!/usr/bin/env bash
if [ "${PAUSE_RECLAIM_RM:-}" = 1 ]; then
  for arg in "$@"; do
    if [ "$arg" = "${LOCK_PATH:-}" ]; then
      : > "$SB/reclaim-rm-paused"
      while [ ! -e "$SB/release-reclaim-rm" ]; do /bin/sleep 0.02; done
      unset PAUSE_RECLAIM_RM
      break
    fi
  done
fi
exec /bin/rm "$@"
STUB
  cat > "$SB/fakebin/mkdir" <<'STUB'
#!/usr/bin/env bash
/bin/mkdir "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ "${1:-}" = "${LOCK_PATH:-}" ] && [ "${PAUSE_LOCK_MKDIR:-}" = 1 ]; then
  : > "$SB/mkdir-lock-paused"
  while [ ! -e "$SB/release-mkdir-lock" ]; do /bin/sleep 0.02; done
fi
if [ "$rc" -eq 0 ] && [ "${1:-}" = "${LOCK_PATH:-}.reclaim" ] && [ "${PAUSE_MUTEX_MKDIR:-}" = 1 ]; then
  : > "$SB/mkdir-mutex-paused"
  while [ ! -e "$SB/release-mkdir-mutex" ]; do /bin/sleep 0.02; done
fi
exit "$rc"
STUB
  cat > "$SB/fakebin/ln" <<'STUB'
#!/usr/bin/env bash
dest=${!#}
if [ "$dest" = "${LOCK_PATH:-}" ] && [ "${INJECT_LEGACY_DIR_BEFORE_LN:-}" = 1 ] &&
   [ ! -e "$SB/injected-legacy-dir" ]; then
  /bin/mkdir "$dest"
  printf '%s\n' "$INJECT_LEGACY_PID" > "$dest/pid"
  : > "$SB/injected-legacy-dir"
fi
if [ "$dest" = "${LOCK_PATH:-}" ] && [ -n "${INJECT_DIRECTORY_LINK_TARGET:-}" ] &&
   [ ! -e "$SB/injected-directory-symlink" ]; then
  /bin/ln -s "$INJECT_DIRECTORY_LINK_TARGET" "$dest"
  : > "$SB/injected-directory-symlink"
fi
/bin/ln "$@"
rc=$?
dest=${!#}
if [ "$rc" -eq 0 ] && [ "$dest" = "${LOCK_PATH:-}" ] && [ "${PAUSE_LOCK_MKDIR:-}" = 1 ]; then
  : > "$SB/mkdir-lock-paused"
  while [ ! -e "$SB/release-mkdir-lock" ]; do /bin/sleep 0.02; done
fi
if [ "$rc" -eq 0 ] && [ "$dest" = "${LOCK_PATH:-}.reclaim" ] && [ "${PAUSE_MUTEX_MKDIR:-}" = 1 ]; then
  : > "$SB/mkdir-mutex-paused"
  while [ ! -e "$SB/release-mkdir-mutex" ]; do /bin/sleep 0.02; done
fi
exit "$rc"
STUB
  cat > "$SB/fakebin/sleep" <<'STUB'
#!/usr/bin/env bash
if [ "${SLEEP_GATE:-}" = 1 ] && [ "${1:-}" = "${AUTODEV_SETTLE:-}" ]; then
  : > "$SB/settle-paused"
  while [ ! -e "$SB/release-settle" ]; do /bin/sleep 0.02; done
  exit 0
fi
exec /bin/sleep "$@"
STUB
  chmod +x "$SB/fakebin/"*
}

wait_file() { # $1 = path, $2 = seconds
  local ticks=$(( ${2:-10} * 20 ))
  while [ "$ticks" -gt 0 ]; do
    [ -e "$1" ] && return 0
    /bin/sleep 0.05
    ticks=$(( ticks - 1 ))
  done
  return 1
}

run_watch() {
  bash "$BIN/auto-handoff-watch.sh" "$SID" >/dev/null 2>&1
}

lock_owner_for_test() { # $1 = symlink lock or legacy directory
  if [ -L "$1" ]; then
    target=$(readlink "$1" 2>/dev/null || true)
    printf '%s' "${target##*/}"
  elif [ -d "$1" ] && [ ! -L "$1" ]; then
    cat "$1/pid" 2>/dev/null || true
  fi
}

trigger_count() {
  local count
  count=$(grep -c "\[$SID\] TRIGGER" "$AUTODEV_HOME/logs/auto-handoff.log" 2>/dev/null || true)
  printf '%s' "${count:-0}"
}

assert_dir() { [ -d "$2" ] && _pass "$1" || _fail "$1" "missing directory: $2"; }
assert_absent() { [ ! -e "$2" ] && [ ! -L "$2" ] && _pass "$1" || _fail "$1" "path still exists: $2"; }
age_directory_old() { python3 -c 'import os, sys, time; t=time.time()-3600; os.utime(sys.argv[1], (t, t), follow_symlinks=False)' "$1"; }
set_mtime_offset() { python3 -c 'import os, sys, time; t=time.time()+float(sys.argv[2]); os.utime(sys.argv[1], (t, t), follow_symlinks=False)' "$1" "$2"; }
stub_unreadable_pid_cat() {
  cat > "$SB/fakebin/cat" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  "${UNREADABLE_PID_PATH:-__no_match__}"|"${UNREADABLE_PID_PREFIX:-__no_match__}"*/pid)
    if [ -n "${UNREADABLE_PID_READ_LIMIT:-}" ]; then
      reads=$(/bin/cat "$SB/unreadable-pid-reads" 2>/dev/null || printf '0')
      reads=$(( reads + 1 ))
      printf '%s\n' "$reads" > "$SB/unreadable-pid-reads"
      [ "$reads" -le "$UNREADABLE_PID_READ_LIMIT" ] && exit 1
    else
      exit 1
    fi
    ;;
esac
exec /bin/cat "$@"
STUB
  chmod +x "$SB/fakebin/cat"
}
stub_pause_cycle_pid_read() {
  REAL_READLINK=$(command -v readlink); export REAL_READLINK
  cat > "$SB/fakebin/cat" <<'STUB'
#!/usr/bin/env bash
if [ "${PAUSE_FIRST_CYCLE_PID_READ:-}" = 1 ] \
    && [ "${1:-}" = "${PAUSE_PID_READ_TARGET:-${LOCK_PATH:-__no_match__}}/pid" ] \
    && [ ! -e "$SB/cycle-pid-read-paused" ]; then
  /bin/cat "$@"
  : > "$SB/cycle-pid-read-paused"
  while [ ! -e "$SB/release-cycle-pid-read" ]; do /bin/sleep 0.02; done
  exit 0
fi
exec /bin/cat "$@"
STUB
  chmod +x "$SB/fakebin/cat"
  cat > "$SB/fakebin/readlink" <<'STUB'
#!/usr/bin/env bash
"${REAL_READLINK:-/usr/bin/readlink}" "$@"
rc=$?
if [ "${PAUSE_FIRST_CYCLE_PID_READ:-}" = 1 ] \
    && [ "${1:-}" = "${PAUSE_PID_READ_TARGET:-${LOCK_PATH:-__no_match__}}" ] \
    && [ ! -e "$SB/cycle-pid-read-paused" ]; then
  : > "$SB/cycle-pid-read-paused"
  while [ ! -e "$SB/release-cycle-pid-read" ]; do /bin/sleep 0.02; done
fi
exit "$rc"
STUB
  chmod +x "$SB/fakebin/readlink"
}

echo "== uncontended dead-PID lock is reclaimed and released =="
setup
mkdir "$LOCK"
printf '99999999\n' > "$LOCK/pid"
run_watch
assert_eq "stale PID lock permits one cycle" "$(trigger_count)" "1"
assert_absent "cycle exit releases the owned lock" "$LOCK"
assert_absent "reclaim mutex is released" "$LOCK.reclaim"
sandbox_rm

echo "== two reclaimers serialize on the mutex =="
setup
mkdir "$LOCK"
printf '99999999\n' > "$LOCK/pid"
LOCK_PATH="$LOCK" PAUSE_RECLAIM_RM=1 SLEEP_GATE=1 AUTODEV_SETTLE=1 PATH="$SB/fakebin:$PATH" \
  bash "$BIN/auto-handoff-watch.sh" "$SID" >"$SB/a.out" 2>&1 &
watcher_a=$!
assert_eq "first reclaimer pauses after stale recheck" "$(wait_file "$SB/reclaim-rm-paused" && echo yes)" "yes"
LOCK_PATH="$LOCK" PATH="$SB/fakebin:$PATH" bash "$BIN/auto-handoff-watch.sh" "$SID" >"$SB/b.out" 2>&1 &
watcher_b=$!
wait "$watcher_b"
assert_eq "second contender cannot run alongside mutex holder" "$(trigger_count)" "0"
assert_eq "old lock remains present during serialized reclaim" "$(test -d "$LOCK" && echo yes)" "yes"
: > "$SB/release-reclaim-rm"
assert_eq "first reclaimer reaches its cycle after acquiring lock" "$(wait_file "$SB/settle-paused" && lock_owner_for_test "$LOCK")" "$watcher_a"
assert_absent "mutex is released before cycle work" "$LOCK.reclaim"
: > "$SB/release-settle"
wait "$watcher_a"
assert_eq "exactly one contender runs a cycle" "$(trigger_count)" "1"
assert_absent "winning cycle releases its lock" "$LOCK"
sandbox_rm

echo "== crashed reclaimer mutex is recovered after its grace period =="
setup
mkdir "$LOCK" "$LOCK.reclaim"
printf '99999999\n' > "$LOCK/pid"
printf '99999999\n' > "$LOCK.reclaim/pid"
age_directory_old "$LOCK.reclaim"
run_watch
assert_eq "dead stale mutex allows recovery and one cycle" "$(trigger_count)" "1"
assert_absent "recovered mutex is released" "$LOCK.reclaim"
assert_absent "recovery cycle releases lock" "$LOCK"
sandbox_rm

setup
mkdir "$LOCK" "$LOCK.reclaim"
printf '99999999\n' > "$LOCK/pid"
printf 'garbage\n' > "$LOCK.reclaim/pid"
age_directory_old "$LOCK.reclaim"
run_watch
assert_eq "old malformed-PID mutex permits recovery and one cycle" "$(trigger_count)" "1"
assert_absent "recovered malformed-PID mutex is released" "$LOCK.reclaim"
assert_absent "malformed-mutex recovery releases cycle lock" "$LOCK"
sandbox_rm

echo "== aged live reclaimer mutex remains protected =="
setup
sleep 300 &
live_reclaimer=$!
mkdir "$LOCK" "$LOCK.reclaim"
printf '99999999\n' > "$LOCK/pid"
printf '%s\n' "$live_reclaimer" > "$LOCK.reclaim/pid"
age_directory_old "$LOCK.reclaim"
run_watch
assert_eq "aged live mutex prevents cycle acquisition" "$(trigger_count)" "0"
assert_eq "live mutex PID remains intact" "$(cat "$LOCK.reclaim/pid")" "$live_reclaimer"
assert_eq "stale cycle lock remains untouched" "$(cat "$LOCK/pid")" "99999999"
kill "$live_reclaimer" 2>/dev/null || true
wait "$live_reclaimer" 2>/dev/null || true
sandbox_rm

echo "== fresh PID-less legacy lock is honored =="
setup
mkdir "$LOCK"
run_watch
assert_eq "fresh legacy lock skips the cycle" "$(trigger_count)" "0"
assert_dir "fresh legacy lock remains in place" "$LOCK"
sandbox_rm

echo "== an ln destination directory is not mistaken for lock ownership =="
setup
sleep 300 &
live_directory_owner=$!
mkdir "$LOCK"
printf '%s\n' "$live_directory_owner" > "$LOCK/pid"
run_watch
assert_eq "live legacy directory owner prevents a cycle" "$(trigger_count)" "0"
assert_eq "ln fall-through leaves no stray child in the legacy lock" \
  "$(find "$LOCK" -mindepth 1 -maxdepth 1 ! -name pid -print)" ""
assert_eq "legacy directory PID remains unchanged" "$(cat "$LOCK/pid")" "$live_directory_owner"
kill "$live_directory_owner" 2>/dev/null || true
wait "$live_directory_owner" 2>/dev/null || true
sandbox_rm

setup
sleep 300 &
injected_directory_owner=$!
LOCK_PATH="$LOCK" INJECT_LEGACY_DIR_BEFORE_LN=1 INJECT_LEGACY_PID="$injected_directory_owner" \
  PATH="$SB/fakebin:$PATH" run_watch
assert_eq "concurrent legacy directory creation defeats ln ownership" "$(trigger_count)" "0"
assert_eq "failed ln fall-through cleans only its own child link" \
  "$(find "$LOCK" -mindepth 1 -maxdepth 1 ! -name pid -print)" ""
assert_eq "concurrent legacy owner remains unchanged" "$(cat "$LOCK/pid")" "$injected_directory_owner"
kill "$injected_directory_owner" 2>/dev/null || true
wait "$injected_directory_owner" 2>/dev/null || true
sandbox_rm

setup
sleep 300 &
symlink_directory_owner=$!
mkdir "$SB/legacy-lock-target"
printf '%s\n' "$symlink_directory_owner" > "$SB/legacy-lock-target/pid"
/bin/ln -s "$SB/legacy-lock-target" "$LOCK"
run_watch
assert_eq "symlink-to-directory collision cannot authorize a cycle" "$(trigger_count)" "0"
assert_eq "ln fall-through through a directory symlink leaves no stray child" \
  "$(find "$SB/legacy-lock-target" -mindepth 1 -maxdepth 1 ! -name pid -print)" ""
assert_eq "directory symlink target PID remains unchanged" \
  "$(cat "$SB/legacy-lock-target/pid")" "$symlink_directory_owner"
kill "$symlink_directory_owner" 2>/dev/null || true
wait "$symlink_directory_owner" 2>/dev/null || true
sandbox_rm

setup
sleep 300 &
injected_symlink_directory_owner=$!
mkdir "$SB/injected-directory-target"
printf '%s\n' "$injected_symlink_directory_owner" > "$SB/injected-directory-target/pid"
LOCK_PATH="$LOCK" INJECT_DIRECTORY_LINK_TARGET="$SB/injected-directory-target" \
  PATH="$SB/fakebin:$PATH" run_watch
assert_eq "concurrent directory symlink defeats ln ownership" "$(trigger_count)" "0"
assert_eq "failed ln through directory symlink leaves no child link" \
  "$(find "$SB/injected-directory-target" -mindepth 1 -maxdepth 1 ! -name pid -print)" ""
assert_eq "symlink target directory owner remains unchanged" \
  "$(cat "$SB/injected-directory-target/pid")" "$injected_symlink_directory_owner"
kill "$injected_symlink_directory_owner" 2>/dev/null || true
wait "$injected_symlink_directory_owner" 2>/dev/null || true
sandbox_rm

echo "== unusable PID values follow the legacy age threshold =="
setup
mkdir "$LOCK"
printf 'garbage\n' > "$LOCK/pid"
age_directory_old "$LOCK"
run_watch
assert_eq "old garbage-PID lock permits one cycle" "$(trigger_count)" "1"
assert_absent "old garbage-PID lock is reclaimed" "$LOCK"
sandbox_rm

setup
mkdir "$LOCK"
printf 'garbage\n' > "$LOCK/pid"
run_watch
assert_eq "fresh garbage-PID lock skips the cycle" "$(trigger_count)" "0"
assert_dir "fresh garbage-PID lock remains" "$LOCK"
sandbox_rm

setup
mkdir "$LOCK"
printf '000\n' > "$LOCK/pid"
age_directory_old "$LOCK"
run_watch
assert_eq "old zero-PID lock permits one cycle" "$(trigger_count)" "1"
assert_absent "old zero-PID lock is reclaimed" "$LOCK"
sandbox_rm

setup
mkdir "$LOCK"
printf '000\n' > "$LOCK/pid"
run_watch
assert_eq "fresh zero-PID lock skips the cycle" "$(trigger_count)" "0"
assert_dir "fresh zero-PID lock remains" "$LOCK"
sandbox_rm

setup
mkdir "$LOCK"
: > "$LOCK/pid"
age_directory_old "$LOCK"
run_watch
assert_eq "old empty-PID lock permits one cycle" "$(trigger_count)" "1"
assert_absent "old empty-PID lock is reclaimed" "$LOCK"
sandbox_rm

setup
mkdir "$LOCK"
: > "$LOCK/pid"
run_watch
assert_eq "fresh empty-PID lock skips the cycle" "$(trigger_count)" "0"
assert_dir "fresh empty-PID lock remains" "$LOCK"
sandbox_rm

echo "== live PID remains honored after legacy age =="
setup
sleep 300 &
live_holder=$!
mkdir "$LOCK"
printf '%s\n' "$live_holder" > "$LOCK/pid"
age_directory_old "$LOCK"
run_watch
assert_eq "aged live-PID lock still skips the cycle" "$(trigger_count)" "0"
assert_eq "aged live-PID lock keeps its PID" "$(cat "$LOCK/pid")" "$live_holder"
kill "$live_holder" 2>/dev/null || true
wait "$live_holder" 2>/dev/null || true
sandbox_rm

echo "== unreadable PID locks age out but fresh locks are honored =="
setup
mkdir "$LOCK"
printf '%s\n' "$$" > "$LOCK/pid"
age_directory_old "$LOCK"
stub_unreadable_pid_cat
UNREADABLE_PID_PATH="$LOCK/pid" UNREADABLE_PID_READ_LIMIT=2 \
  PATH="$SB/fakebin:$PATH" run_watch
assert_eq "old unreadable-PID lock permits one cycle" "$(trigger_count)" "1"
assert_absent "old unreadable-PID lock is reclaimed" "$LOCK"
sandbox_rm

setup
mkdir "$LOCK"
printf '%s\n' '99999999' > "$LOCK/pid"
age_directory_old "$LOCK"
stub_unreadable_pid_cat
UNREADABLE_PID_PATH="$LOCK/pid" UNREADABLE_PID_READ_LIMIT=1 \
  PATH="$SB/fakebin:$PATH" run_watch
assert_eq "PID that becomes readable during stale check is not reclaimed" "$(trigger_count)" "0"
assert_dir "changed PID read state leaves the lock intact" "$LOCK"
sandbox_rm

setup
mkdir "$LOCK"
printf '%s\n' "$$" > "$LOCK/pid"
stub_unreadable_pid_cat
UNREADABLE_PID_PATH="$LOCK/pid" PATH="$SB/fakebin:$PATH" run_watch
assert_eq "fresh unreadable-PID lock skips the cycle" "$(trigger_count)" "0"
assert_dir "fresh unreadable-PID lock remains" "$LOCK"
sandbox_rm

echo "== owner verification rejects a lock renamed away after publication =="
setup
LOCK_PATH="$LOCK" PAUSE_LOCK_MKDIR=1 PATH="$SB/fakebin:$PATH" \
  bash "$BIN/auto-handoff-watch.sh" "$SID" >"$SB/watch.out" 2>&1 &
watcher=$!
assert_eq "watcher pauses after atomic publication" "$(wait_file "$SB/mkdir-lock-paused" && echo yes)" "yes"
/bin/mv "$LOCK" "$SB/moved-lock"
: > "$SB/release-mkdir-lock"
wait "$watcher"
assert_eq "renamed-away lock cannot authorize a cycle" "$(trigger_count)" "0"
assert_contains "renamed-away publication cannot authorize a cycle" "$(cat "$AUTODEV_HOME/logs/auto-handoff.log")" "SKIP cycle lock ownership changed after atomic publication"
sandbox_rm

echo "== reclaim mutex owner verification rejects a renamed-away mutex =="
setup
mkdir "$LOCK"
printf '99999999\n' > "$LOCK/pid"
LOCK_PATH="$LOCK" PAUSE_MUTEX_MKDIR=1 PATH="$SB/fakebin:$PATH" \
  bash "$BIN/auto-handoff-watch.sh" "$SID" >"$SB/watch.out" 2>&1 &
watcher=$!
assert_eq "watcher pauses after mutex atomic publication" "$(wait_file "$SB/mkdir-mutex-paused" && echo yes)" "yes"
/bin/mv "$LOCK.reclaim" "$SB/moved-reclaim-mutex"
: > "$SB/release-mkdir-mutex"
wait "$watcher"
assert_eq "unverified mutex cannot reclaim the cycle lock" "$(trigger_count)" "0"
assert_eq "stale cycle lock remains intact" "$(cat "$LOCK/pid")" "99999999"
assert_absent "renamed-away mutex path is not recreated" "$LOCK.reclaim"
assert_contains "mutex readback failure is logged" "$(cat "$AUTODEV_HOME/logs/auto-handoff.log")" "SKIP reclaim mutex ownership could not be verified"
sandbox_rm

echo "== EXIT preserves a replacement owner's lock =="
setup
LOCK_PATH="$LOCK" SLEEP_GATE=1 AUTODEV_SETTLE=1 PATH="$SB/fakebin:$PATH" \
  bash "$BIN/auto-handoff-watch.sh" "$SID" >"$SB/watch.out" 2>&1 &
watcher=$!
assert_eq "watcher enters its controlled cycle" "$(wait_file "$SB/settle-paused" && echo yes)" "yes"
/bin/mv "$LOCK" "$SB/original-lock"
sleep 300 &
replacement_owner=$!
mkdir "$LOCK"
printf '%s\n' "$replacement_owner" > "$LOCK/pid"
: > "$SB/release-settle"
wait "$watcher"
assert_eq "EXIT leaves replacement PID untouched" "$(cat "$LOCK/pid")" "$replacement_owner"
kill "$replacement_owner" 2>/dev/null || true
wait "$replacement_owner" 2>/dev/null || true
sandbox_rm

echo "== reclaimer preserves a replacement lock after normal owner exit =="
setup
LOCK_PATH="$LOCK" SLEEP_GATE=1 AUTODEV_SETTLE=1 PATH="$SB/fakebin:$PATH" \
  bash "$BIN/auto-handoff-watch.sh" "$SID" >"$SB/old-owner.out" 2>&1 &
old_owner=$!
assert_eq "old owner pauses in its cycle" "$(wait_file "$SB/settle-paused" && lock_owner_for_test "$LOCK")" "$old_owner"
stub_pause_cycle_pid_read
LOCK_PATH="$LOCK" PAUSE_FIRST_CYCLE_PID_READ=1 PATH="$SB/fakebin:$PATH" \
  bash "$BIN/auto-handoff-watch.sh" "$SID" >"$SB/reclaimer.out" 2>&1 &
reclaimer=$!
assert_eq "reclaimer pauses after reading old owner PID" \
  "$(wait_file "$SB/cycle-pid-read-paused" && echo yes)" "yes"
: > "$SB/release-settle"
wait "$old_owner"
assert_absent "normal old owner releases its lock before exit" "$LOCK"
assert_eq "old owner completed its original cycle" "$(trigger_count)" "1"
rm -f "$STATE/$SID.cooldown"
rm -f "$SB/settle-paused" "$SB/release-settle"
LOCK_PATH="$LOCK" SLEEP_GATE=1 AUTODEV_SETTLE=1 PATH="$SB/fakebin:$PATH" \
  bash "$BIN/auto-handoff-watch.sh" "$SID" >"$SB/new-owner.out" 2>&1 &
new_owner=$!
assert_eq "fast-path watcher acquires replacement lock" \
  "$(wait_file "$SB/settle-paused" && lock_owner_for_test "$LOCK")" "$new_owner"
: > "$SB/release-cycle-pid-read"
wait "$reclaimer"
assert_eq "reclaimer skips changed dead-holder snapshot" \
  "$(grep -c 'SKIP cycle lock changed during stale recheck' "$AUTODEV_HOME/logs/auto-handoff.log")" "1"
assert_eq "replacement lock remains owned by fast-path watcher" "$(lock_owner_for_test "$LOCK")" "$new_owner"
assert_eq "reclaimer adds no overlapping cycle" "$(trigger_count)" "1"
: > "$SB/release-settle"
wait "$new_owner"
assert_eq "replacement watcher runs exactly one cycle" "$(trigger_count)" "2"
assert_absent "replacement cycle releases its own lock" "$LOCK"
sandbox_rm

echo "== stale mutex recovery preserves a replacement mutex owner =="
setup
mkdir "$LOCK"
printf '99999999\n' > "$LOCK/pid"
(
  while [ ! -e "$SB/release-old-mutex-owner" ]; do /bin/sleep 0.02; done
  /bin/rm -rf "$LOCK.reclaim"
) &
old_mutex_owner=$!
mkdir "$LOCK.reclaim"
printf '%s\n' "$old_mutex_owner" > "$LOCK.reclaim/pid"
age_directory_old "$LOCK.reclaim"
stub_pause_cycle_pid_read
LOCK_PATH="$LOCK" PAUSE_PID_READ_TARGET="$LOCK.reclaim" \
  PAUSE_FIRST_CYCLE_PID_READ=1 PATH="$SB/fakebin:$PATH" \
  bash "$BIN/auto-handoff-watch.sh" "$SID" >"$SB/stale-mutex-reclaimer.out" 2>&1 &
stale_mutex_reclaimer=$!
assert_eq "stale-mutex recovery pauses after reading old owner PID" \
  "$(wait_file "$SB/cycle-pid-read-paused" && echo yes)" "yes"
: > "$SB/release-old-mutex-owner"
wait "$old_mutex_owner"
assert_absent "old mutex owner releases before exit" "$LOCK.reclaim"
LOCK_PATH="$LOCK" PAUSE_MUTEX_MKDIR=1 PATH="$SB/fakebin:$PATH" \
  bash "$BIN/auto-handoff-watch.sh" "$SID" >"$SB/new-mutex-owner.out" 2>&1 &
new_mutex_owner=$!
assert_eq "fast-path reclaimer creates replacement mutex" \
  "$(wait_file "$SB/mkdir-mutex-paused" && test -L "$LOCK.reclaim" && lock_owner_for_test "$LOCK.reclaim")" "$new_mutex_owner"
set_mtime_offset "$LOCK.reclaim" -3600
: > "$SB/release-cycle-pid-read"
wait "$stale_mutex_reclaimer"
assert_eq "stale recovery skips the changed mutex owner" "$(trigger_count)" "0"
assert_eq "replacement mutex still blocks other reclaimers" \
  "$(test -L "$LOCK.reclaim" && lock_owner_for_test "$LOCK.reclaim")" "$new_mutex_owner"
: > "$SB/release-mkdir-mutex"
wait "$new_mutex_owner"
assert_eq "replacement mutex owner runs one cycle" "$(trigger_count)" "1"
assert_absent "replacement cycle releases its cycle lock" "$LOCK"
assert_absent "replacement cycle releases its mutex" "$LOCK.reclaim"
sandbox_rm

echo "== sweeper sees the lock throughout a stale reclaim =="
setup
mkdir "$LOCK"
printf '99999999\n' > "$LOCK/pid"
LOCK_PATH="$LOCK" PAUSE_RECLAIM_RM=1 PAUSE_LOCK_MKDIR=1 SLEEP_GATE=1 AUTODEV_SETTLE=1 \
  PATH="$SB/fakebin:$PATH" bash "$BIN/auto-handoff-watch.sh" "$SID" >"$SB/watch.out" 2>&1 &
watcher=$!
assert_eq "watcher pauses with old lock still present" "$(wait_file "$SB/reclaim-rm-paused" && test -d "$LOCK" && echo yes)" "yes"
printf 'staged\n' > "$STATE/$SID.reload-attempt"
set_mtime_offset "$STATE/$SID.reload-attempt" -1200
: > "$STATE/$SID.idle"
set_mtime_offset "$STATE/$SID.idle" 2
printf 'reload\n' > "$STATE/$SID.reload-pending"
set_mtime_offset "$STATE/$SID.reload-pending" 3
bash "$BIN/auto-handoff-sweep.sh" >"$SB/sweep-old.out" 2>&1
assert_file "sweeper preserves attempt during reclaim" "$STATE/$SID.reload-attempt"
assert_file "sweeper preserves pending marker during reclaim" "$STATE/$SID.reload-pending"
: > "$SB/release-reclaim-rm"
assert_eq "new owner is visible at atomic lock creation" "$(wait_file "$SB/mkdir-lock-paused" && test -L "$LOCK" && lock_owner_for_test "$LOCK")" "$watcher"
bash "$BIN/auto-handoff-sweep.sh" >"$SB/sweep-new.out" 2>&1
assert_file "sweeper preserves attempt while new owner acquires" "$STATE/$SID.reload-attempt"
assert_file "sweeper preserves pending marker while new owner acquires" "$STATE/$SID.reload-pending"
rm -f "$STATE/$SID.reload-attempt" "$STATE/$SID.reload-pending"
: > "$SB/release-mkdir-lock"
assert_eq "watcher enters cycle with verified lock" "$(wait_file "$SB/settle-paused" && lock_owner_for_test "$LOCK")" "$watcher"
printf 'staged\n' > "$STATE/$SID.reload-attempt"
set_mtime_offset "$STATE/$SID.reload-attempt" -1200
: > "$STATE/$SID.idle"
set_mtime_offset "$STATE/$SID.idle" 2
printf 'reload\n' > "$STATE/$SID.reload-pending"
set_mtime_offset "$STATE/$SID.reload-pending" 3
bash "$BIN/auto-handoff-sweep.sh" >"$SB/sweep-live.out" 2>&1
assert_file "live owner keeps attempt from sweeper cleanup" "$STATE/$SID.reload-attempt"
assert_file "live owner keeps pending marker from sweeper cleanup" "$STATE/$SID.reload-pending"
assert_contains "sweeper reports the held lock" "$(cat "$AUTODEV_HOME/logs/auto-handoff.log")" "SKIP reload cleanup: cycle lock held by live pid $watcher"
rm -f "$STATE/$SID.reload-attempt" "$STATE/$SID.reload-pending"
: > "$SB/release-settle"
wait "$watcher"
sandbox_rm

echo "== watcher honors a cycle lock atomically published by the sweeper =="
setup
printf 'staged\n' > "$STATE/$SID.reload-attempt"
set_mtime_offset "$STATE/$SID.reload-attempt" -1200
: > "$STATE/$SID.idle"
set_mtime_offset "$STATE/$SID.idle" 2
export MUX_BUSY=1
LOCK_PATH="$LOCK" PAUSE_LOCK_MKDIR=1 PATH="$SB/fakebin:$PATH" \
  bash "$BIN/auto-handoff-sweep.sh" >"$SB/sweep-owner.out" 2>&1 &
sweeper=$!
assert_eq "sweeper pauses after atomic cycle-lock publication" \
  "$(wait_file "$SB/mkdir-lock-paused" && test -L "$LOCK" && lock_owner_for_test "$LOCK")" "$sweeper"
bash "$BIN/auto-handoff-watch.sh" "$SID" >"$SB/watch-contender.out" 2>&1
assert_eq "watcher does not run beside the live sweeper" "$(trigger_count)" "0"
assert_file "sweeper owner keeps staged-input state protected" "$STATE/$SID.reload-attempt"
: > "$SB/release-mkdir-lock"
wait "$sweeper"
assert_absent "sweeper releases its cycle lock" "$LOCK"
assert_absent "sweeper clears the consumed staged-input marker" "$STATE/$SID.reload-attempt"
sandbox_rm

finish
