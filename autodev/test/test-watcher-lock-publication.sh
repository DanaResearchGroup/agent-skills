#!/usr/bin/env bash
# New cycle and reclaim locks must publish their owner in the path-creation
# operation, so an aged lock paused at publication still has a live owner.

. "$(dirname "$0")/lib.sh"

SID=77777777-7777-7777-7777-777777777777

setup() {
  sandbox_new
  stub_mux
  session_new "$SID" 55 "w1:p1"
  export MUX_LIVE_PANES="w1:p1" MUX_BUSY=0
  export AUTODEV_SETTLE=1 AUTODEV_PRECHECK=1 AUTODEV_WAIT_IDLE=60 AUTODEV_WAIT_COMPACT=60
  LOCK="$STATE/$SID.cycle.lock"
  export LOCK_PATH="$LOCK"
  mkdir -p "$SB/fakebin"
  cat > "$SB/fakebin/mkdir" <<'STUB'
#!/usr/bin/env bash
/bin/mkdir "$@"
rc=$?
dest=${!#}
if [ "$rc" -eq 0 ] && [ "$dest" = "${LOCK_PATH:-}" ] &&
   [ "${PAUSE_CYCLE_CREATE:-}" = 1 ] && [ ! -e "$SB/cycle-create-paused" ]; then
  : > "$SB/cycle-create-paused"
  while [ ! -e "$SB/release-cycle-create" ]; do /bin/sleep 0.02; done
fi
if [ "$rc" -eq 0 ] && [ "$dest" = "${LOCK_PATH:-}.reclaim" ] &&
   [ "${PAUSE_MUTEX_CREATE:-}" = 1 ] && [ ! -e "$SB/mutex-create-paused" ]; then
  : > "$SB/mutex-create-paused"
  while [ ! -e "$SB/release-mutex-create" ]; do /bin/sleep 0.02; done
fi
exit "$rc"
STUB
  cat > "$SB/fakebin/ln" <<'STUB'
#!/usr/bin/env bash
/bin/ln "$@"
rc=$?
dest=${!#}
if [ "$rc" -eq 0 ] && [ "$dest" = "${LOCK_PATH:-}" ] &&
   [ "${PAUSE_CYCLE_CREATE:-}" = 1 ] && [ ! -e "$SB/cycle-create-paused" ]; then
  : > "$SB/cycle-create-paused"
  while [ ! -e "$SB/release-cycle-create" ]; do /bin/sleep 0.02; done
fi
if [ "$rc" -eq 0 ] && [ "$dest" = "${LOCK_PATH:-}.reclaim" ] &&
   [ "${PAUSE_MUTEX_CREATE:-}" = 1 ] && [ ! -e "$SB/mutex-create-paused" ]; then
  : > "$SB/mutex-create-paused"
  while [ ! -e "$SB/release-mutex-create" ]; do /bin/sleep 0.02; done
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
  if [ -n "${AUTODEV_WATCH_SOURCE:-}" ]; then
    cp "$AUTODEV_WATCH_SOURCE" "$BIN/auto-handoff-watch.sh"
    chmod +x "$BIN/auto-handoff-watch.sh"
  fi
}

wait_file() {
  local ticks=$(( ${2:-10} * 20 ))
  while [ "$ticks" -gt 0 ]; do
    [ -e "$1" ] && return 0
    /bin/sleep 0.05
    ticks=$(( ticks - 1 ))
  done
  return 1
}

age_lock_path() {
  python3 -c 'import os,sys,time; old=time.time()-3600; os.utime(sys.argv[1],(old,old),follow_symlinks=False)' "$1"
}

trigger_count() {
  grep -c "\[$SID\] TRIGGER" "$AUTODEV_HOME/logs/auto-handoff.log" 2>/dev/null || true
}

run_cycle_publication_case() {
  echo "== an aged live cycle lock cannot be reclaimed during publication =="
  setup
  LOCK_PATH="$LOCK" PAUSE_CYCLE_CREATE=1 SLEEP_GATE=1 PATH="$SB/fakebin:$PATH" \
    bash "$BIN/auto-handoff-watch.sh" "$SID" >"$SB/first.out" 2>&1 &
  first=$!
  assert_eq "first watcher pauses after creating the cycle-lock path" \
    "$(wait_file "$SB/cycle-create-paused" && echo yes)" yes
  assert_eq "cycle owner is the absolute non-resolving PID token" \
    "$(test -L "$LOCK" && readlink "$LOCK")" "/dev/null/autodev-lock-owner/$first"
  assert_eq "cycle owner token cannot resolve to a filesystem object" \
    "$(test ! -e "$(readlink "$LOCK")" && echo yes)" yes
  age_lock_path "$LOCK"

  PATH="$SB/fakebin:$PATH" bash "$BIN/auto-handoff-watch.sh" "$SID" >"$SB/second.out" 2>&1
  assert_eq "second watcher stays out while first owner is live" "$(trigger_count)" 0

  : > "$SB/release-cycle-create"
  wait_file "$SB/settle-paused" 5 || true
  : > "$SB/release-settle"
  wait "$first"
  assert_eq "the original owner runs one cycle after resuming" "$(trigger_count)" 1
  sandbox_rm
}

run_mutex_publication_case() {
  echo "== an aged live reclaim mutex cannot be reclaimed during publication =="
  setup
  mkdir "$LOCK"
  printf '99999999\n' > "$LOCK/pid"
  age_lock_path "$LOCK"

  LOCK_PATH="$LOCK" PAUSE_MUTEX_CREATE=1 SLEEP_GATE=1 PATH="$SB/fakebin:$PATH" \
    bash "$BIN/auto-handoff-watch.sh" "$SID" >"$SB/first.out" 2>&1 &
  first=$!
  assert_eq "first watcher pauses after creating the reclaim-mutex path" \
    "$(wait_file "$SB/mutex-create-paused" && echo yes)" yes
  age_lock_path "$LOCK.reclaim"

  PATH="$SB/fakebin:$PATH" bash "$BIN/auto-handoff-watch.sh" "$SID" >"$SB/second.out" 2>&1
  assert_eq "second watcher honors the live mutex despite its age" "$(trigger_count)" 0

  : > "$SB/release-mutex-create"
  wait_file "$SB/settle-paused" 5 || true
  : > "$SB/release-settle"
  wait "$first"
  assert_eq "the mutex holder reclaims and runs one cycle" "$(trigger_count)" 1
  sandbox_rm
}

run_strict_token_case() {
  echo "== only canonical absolute owner tokens parse as PIDs =="
  setup
  . "$BIN/lock-lib.sh"
  assert_eq "canonical PID ceiling is accepted" \
    "$(autodev_lock_pid_is_canonical 4194304 && echo accepted || echo rejected)" accepted
  assert_eq "PID above the canonical ceiling is rejected" \
    "$(autodev_lock_pid_is_canonical 4194305 >/dev/null 2>&1 && echo accepted || echo rejected)" rejected
  assert_eq "leading-zero PID is rejected" \
    "$(autodev_lock_pid_is_canonical 0123 >/dev/null 2>&1 && echo accepted || echo rejected)" rejected
  assert_eq "oversized PID is rejected" \
    "$(autodev_lock_pid_is_canonical 99999999999999999999 >/dev/null 2>&1 && echo accepted || echo rejected)" rejected
  assert_eq "canonical owner token parses" \
    "$(autodev_lock_parse_token /dev/null/autodev-lock-owner/4194304)" 4194304
  assert_eq "relative numeric target is rejected" \
    "$(autodev_lock_parse_token 12345 >/dev/null 2>&1 && echo accepted || echo rejected)" rejected
  assert_eq "owner token suffix is rejected" \
    "$(autodev_lock_parse_token /dev/null/autodev-lock-owner/4194304x >/dev/null 2>&1 && echo accepted || echo rejected)" rejected
  assert_eq "noncanonical leading-zero PID is rejected" \
    "$(autodev_lock_parse_token /dev/null/autodev-lock-owner/0123 >/dev/null 2>&1 && echo accepted || echo rejected)" rejected
  assert_eq "oversized token PID is rejected" \
    "$(autodev_lock_parse_token /dev/null/autodev-lock-owner/99999999999999999999 >/dev/null 2>&1 && echo accepted || echo rejected)" rejected
  assert_eq "above-ceiling token PID is rejected" \
    "$(autodev_lock_parse_token /dev/null/autodev-lock-owner/4194305 >/dev/null 2>&1 && echo accepted || echo rejected)" rejected
  sandbox_rm
}

case "${AUTODEV_LOCK_PUBLICATION_CASE:-all}" in
  cycle) run_cycle_publication_case ;;
  mutex) run_mutex_publication_case ;;
  all) run_cycle_publication_case; run_mutex_publication_case; run_strict_token_case ;;
  *) echo "unknown AUTODEV_LOCK_PUBLICATION_CASE" >&2; exit 2 ;;
esac

finish
