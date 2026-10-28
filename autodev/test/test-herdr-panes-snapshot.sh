#!/usr/bin/env bash
# The timer-driven sweep publishes one validated, private herdr pane snapshot.

. "$(dirname "$0")/lib.sh"

setup_paths() {
  WITH_HERDR="$SB/with-herdr"
  WITHOUT_HERDR="$SB/without-herdr"
  WITHOUT_TIMEOUT="$SB/without-timeout"
  mkdir -p "$WITH_HERDR" "$WITHOUT_HERDR" "$WITHOUT_TIMEOUT" "$SB/home"
  for tool in bash sh dirname mkdir date jq mktemp chmod mv cat rm sleep; do
    path=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$path" "$WITH_HERDR/$tool"
    ln -sf "$path" "$WITHOUT_HERDR/$tool"
    ln -sf "$path" "$WITHOUT_TIMEOUT/$tool"
  done
  REAL_TIMEOUT=$(command -v timeout 2>/dev/null || true)
  if [ -n "$REAL_TIMEOUT" ]; then
    export REAL_TIMEOUT
    cat > "$SB/timeout" <<'TIMEOUT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SB/timeout-calls"
exec "$REAL_TIMEOUT" "$@"
TIMEOUT
    chmod +x "$SB/timeout"
    ln -s "$SB/timeout" "$WITH_HERDR/timeout"
    ln -s "$SB/timeout" "$WITHOUT_HERDR/timeout"
  fi
  cat > "$WITH_HERDR/herdr" <<'HERDR'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SB/herdr-calls"
case "${HERDR_MODE:-success}" in
  success) printf '%s\n' '{"result":{"panes":[{"cwd":"/tmp/fake-pane"}]}}' ;;
  nonzero) exit 7 ;;
  malformed) printf '%s\n' '{not-json' ;;
  wrong-shape) printf '%s\n' '{"result":{"panes":{}}}' ;;
  sleep) exec sleep 30 ;;
  ignore-term)
    trap '' TERM
    : > "$SB/term-ignore-ready"
    while :; do sleep 1; done
    ;;
esac
HERDR
  chmod +x "$WITH_HERDR/herdr"
  ln -s "$WITH_HERDR/herdr" "$WITHOUT_TIMEOUT/herdr"
}

sweep_with_path() { # $1 = isolated PATH
  HOME="$SB/home" PATH="$1" "$BIN/auto-handoff-sweep.sh"
}

sandbox_new
setup_paths
: > "$STATE/disable-auto-compact"
snapshot="$STATE/herdr-panes.json"
failing_marker="$STATE/.herdr-panes.failing"
LOG="$AUTODEV_HOME/logs/auto-handoff.log"

sweep_with_path "$WITH_HERDR"
assert_file 'valid herdr output publishes the pane snapshot' "$snapshot"
valid=$(jq -e '.result.panes | type == "array"' "$snapshot" >/dev/null 2>&1 && echo yes || echo no)
assert_eq 'published snapshot has a result.panes array' "$valid" yes
mode=$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$snapshot" 2>/dev/null)
assert_eq 'published snapshot is private' "$mode" 0o600
calls=0
[ ! -f "$SB/herdr-calls" ] || calls=$(wc -l < "$SB/herdr-calls")
assert_eq 'herdr pane list is called once' "$calls" 1
assert_eq 'herdr receives pane list arguments' "$(cat "$SB/herdr-calls" 2>/dev/null)" 'pane list'
if [ -n "$REAL_TIMEOUT" ]; then
  assert_eq 'available timeout bounds herdr once' "$(cat "$SB/timeout-calls" 2>/dev/null)" "-k 5 10 $WITH_HERDR/herdr pane list"
fi

rm -f "$snapshot"
: > "$SB/herdr-calls"
override_rc=0
HOME="$SB/home" PATH="$WITHOUT_HERDR" MUX_HERDR="$WITH_HERDR/herdr" "$BIN/auto-handoff-sweep.sh" || override_rc=$?
assert_eq 'MUX_HERDR resolves herdr outside PATH' "$override_rc" 0
assert_file 'MUX_HERDR publishes the pane snapshot' "$snapshot"
assert_eq 'MUX_HERDR pane list is called once' "$(wc -l < "$SB/herdr-calls")" 1
assert_eq 'MUX_HERDR receives pane list arguments' "$(cat "$SB/herdr-calls")" 'pane list'

local_home="$SB/local-home"
mkdir -p "$local_home/.local/bin"
cp "$WITH_HERDR/herdr" "$local_home/.local/bin/herdr"
chmod +x "$local_home/.local/bin/herdr"
rm -f "$snapshot"
: > "$SB/herdr-calls"
fallback_rc=0
env -u MUX_HERDR HOME="$local_home" PATH="$WITHOUT_HERDR" "$BIN/auto-handoff-sweep.sh" || fallback_rc=$?
assert_eq 'HOME local-bin herdr fallback succeeds outside PATH' "$fallback_rc" 0
assert_file 'HOME local-bin herdr fallback publishes the snapshot' "$snapshot"
assert_eq 'HOME local-bin herdr is called once' "$(wc -l < "$SB/herdr-calls")" 1

failure_count() {
  local count
  count=$(grep -c 'HERDR snapshot failed' "$LOG" 2>/dev/null || true)
  printf '%s\n' "${count:-0}"
}
recovered_count() {
  local count
  count=$(grep -c 'HERDR snapshot RECOVERED' "$LOG" 2>/dev/null || true)
  printf '%s\n' "${count:-0}"
}
assert_failed_publication_preserves_old() { # $1 = fake-herdr mode, $2 = description, $3 = expected new failure-log lines
  local before_mtime after_mtime before_failures after_failures before_calls after_calls bytes_ok
  cp "$snapshot" "$SB/expected-snapshot"
  before_mtime=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$snapshot")
  before_failures=$(failure_count)
  before_calls=$(wc -l < "$SB/herdr-calls")
  HERDR_MODE="$1" sweep_with_path "$WITH_HERDR"
  after_calls=$(wc -l < "$SB/herdr-calls")
  assert_eq "$2 calls herdr pane list once" "$((after_calls - before_calls))" 1
  bytes_ok=no
  cmp -s "$SB/expected-snapshot" "$snapshot" && bytes_ok=yes
  assert_eq "$2 leaves the previous snapshot bytes untouched" "$bytes_ok" yes
  after_mtime=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$snapshot")
  assert_eq "$2 leaves the previous snapshot mtime untouched" "$after_mtime" "$before_mtime"
  after_failures=$(failure_count)
  assert_eq "$2 logs expected failure count" "$((after_failures - before_failures))" "$3"
  assert_file "$2 leaves the failure marker" "$failing_marker"
  assert_eq "$2 does not leave a temporary file" "$(find "$STATE" -maxdepth 1 -name '.herdr-panes.json.*' -print | wc -l)" 0
}

assert_failed_publication_preserves_old nonzero 'first herdr failure' 1
assert_failed_publication_preserves_old malformed 'second consecutive herdr failure' 0
assert_eq 'two consecutive failures produce one log line' "$(failure_count)" 1
assert_failed_publication_preserves_old wrong-shape 'third consecutive herdr failure' 0

recovered_before=$(recovered_count)
HERDR_MODE=success sweep_with_path "$WITH_HERDR"
assert_no_file 'successful publication clears the failure marker' "$failing_marker"
assert_eq 'successful publication logs one recovery' "$(recovered_count)" "$((recovered_before + 1))"
HERDR_MODE=success sweep_with_path "$WITH_HERDR"
assert_eq 'later success does not repeat the recovery log' "$(recovered_count)" "$((recovered_before + 1))"

# Zero must use the positive default (10s), not GNU timeout's no-deadline mode.
if [ -n "$REAL_TIMEOUT" ]; then
  zero_timeout_calls_before=$(wc -l < "$SB/herdr-calls")
  zero_timeout_failures_before=$(failure_count)
  zero_timeout_started=$(date +%s)
  zero_timeout_rc=0
  HOME="$SB/home" PATH="$WITH_HERDR" SB="$SB" HERDR_MODE=sleep AUTODEV_HERDR_TIMEOUT=0 "$REAL_TIMEOUT" 15 "$BIN/auto-handoff-sweep.sh" || zero_timeout_rc=$?
  zero_timeout_elapsed=$(( $(date +%s) - zero_timeout_started ))
  assert_eq 'zero herdr timeout still lets the sweep return' "$zero_timeout_rc" 0
  assert_eq 'zero herdr timeout falls back to 10 seconds' "$(tail -n 1 "$SB/timeout-calls")" "-k 5 10 $WITH_HERDR/herdr pane list"
  assert_eq 'zero herdr timeout returns within about 15 seconds' "$( [ "$zero_timeout_elapsed" -ge 9 ] && [ "$zero_timeout_elapsed" -le 13 ] && echo yes || echo no )" yes
  assert_eq 'zero herdr timeout invokes the fake once' "$(($(wc -l < "$SB/herdr-calls") - zero_timeout_calls_before))" 1
  assert_eq 'zero herdr timeout logs one failure' "$(( $(failure_count) - zero_timeout_failures_before ))" 1
  assert_file 'zero herdr timeout records the failure marker' "$failing_marker"
  HERDR_MODE=success sweep_with_path "$WITH_HERDR"
  assert_no_file 'success after zero timeout clears the failure marker' "$failing_marker"
else
  _fail 'zero-timeout test has a watchdog' 'timeout is unavailable on the test host'
fi

# The fake ignores TERM. The inner timeout must escalate to KILL after five
# seconds; an outer watchdog keeps a regression from wedging the test suite.
if [ -n "$REAL_TIMEOUT" ]; then
  cp "$snapshot" "$SB/expected-term-ignore-snapshot"
  term_ignore_mtime_before=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$snapshot")
  term_ignore_failures_before=$(failure_count)
  term_ignore_calls_before=$(wc -l < "$SB/herdr-calls")
  term_ignore_started=$(date +%s)
  term_ignore_rc=0
  HOME="$SB/home" PATH="$WITH_HERDR" SB="$SB" HERDR_MODE=ignore-term AUTODEV_HERDR_TIMEOUT=1 "$REAL_TIMEOUT" 8 "$BIN/auto-handoff-sweep.sh" || term_ignore_rc=$?
  term_ignore_elapsed=$(( $(date +%s) - term_ignore_started ))
  assert_eq 'TERM-ignoring herdr still lets the sweep return' "$term_ignore_rc" 0
  assert_file 'fake herdr installed its TERM-ignore trap' "$SB/term-ignore-ready"
  assert_eq 'TERM-ignoring herdr is invoked once' "$(($(wc -l < "$SB/herdr-calls") - term_ignore_calls_before))" 1
  assert_eq 'timeout escalates after its grace period' "$( [ "$term_ignore_elapsed" -ge 5 ] && [ "$term_ignore_elapsed" -le 7 ] && echo yes || echo no )" yes
  assert_eq 'timeout wrapper receives the kill-after bound' "$(tail -n 1 "$SB/timeout-calls")" "-k 5 1 $WITH_HERDR/herdr pane list"
  term_ignore_snapshot_ok=no
  cmp -s "$SB/expected-term-ignore-snapshot" "$snapshot" && term_ignore_snapshot_ok=yes
  assert_eq 'TERM timeout leaves the old snapshot untouched' "$term_ignore_snapshot_ok" yes
  term_ignore_mtime_after=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$snapshot")
  assert_eq 'TERM timeout leaves the old snapshot to age' "$term_ignore_mtime_after" "$term_ignore_mtime_before"
  assert_eq 'TERM timeout logs one failure' "$(( $(failure_count) - term_ignore_failures_before ))" 1
  assert_file 'TERM timeout records the failure marker' "$failing_marker"
  HERDR_MODE=success sweep_with_path "$WITH_HERDR"
  assert_no_file 'success after TERM timeout clears the failure marker' "$failing_marker"
else
  _fail 'TERM escalation test has a timeout watchdog' 'timeout is unavailable on the test host'
fi

# With no timeout in the timer-like PATH, do not invoke herdr at all. The
# absolute timeout here is only a test watchdog, outside the simulated PATH.
if [ -n "$REAL_TIMEOUT" ]; then
  timeout_hidden_rc=0
  PATH="$WITHOUT_TIMEOUT" bash -c 'command -v timeout >/dev/null 2>&1' || timeout_hidden_rc=$?
  assert_eq 'timeout is hidden from the simulated PATH' "$timeout_hidden_rc" 1
  fake_sleep_rc=0
  HOME="$SB/home" PATH="$WITHOUT_TIMEOUT" SB="$SB" HERDR_MODE=sleep "$REAL_TIMEOUT" 1 "$WITHOUT_TIMEOUT/herdr" pane list || fake_sleep_rc=$?
  assert_eq 'fake herdr blocks when invoked without the watchdog' "$fake_sleep_rc" 124
  cp "$snapshot" "$SB/expected-snapshot"
  snapshot_mtime_before=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$snapshot")
  failures_before=$(failure_count)
  calls_before=$(wc -l < "$SB/herdr-calls")
  no_timeout_rc=0
  HOME="$SB/home" PATH="$WITHOUT_TIMEOUT" HERDR_MODE=sleep "$REAL_TIMEOUT" 3 "$BIN/auto-handoff-sweep.sh" || no_timeout_rc=$?
  assert_eq 'missing timeout lets the sweep return promptly' "$no_timeout_rc" 0
  snapshot_bytes_ok=no
  cmp -s "$SB/expected-snapshot" "$snapshot" && snapshot_bytes_ok=yes
  assert_eq 'missing timeout does not publish a new snapshot' "$snapshot_bytes_ok" yes
  snapshot_mtime_after=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$snapshot")
  assert_eq 'missing timeout leaves the old snapshot to age' "$snapshot_mtime_after" "$snapshot_mtime_before"
  assert_eq 'missing timeout does not invoke sleeping herdr' "$(wc -l < "$SB/herdr-calls")" "$calls_before"
  assert_eq 'missing timeout logs one deduplicated failure' "$(( $(failure_count) - failures_before ))" 1
  assert_file 'missing timeout records the failing marker' "$failing_marker"
else
  _fail 'timeout-unavailable behavior has a test watchdog' 'timeout is unavailable on the test host'
fi

# A successful call cannot publish when STATE is read-only. Because the marker
# also cannot be created, snapshot_failed must still write its failure line.
HERDR_MODE=success sweep_with_path "$WITH_HERDR"
assert_no_file 'recovery clears the missing-timeout marker' "$failing_marker"
readonly_failures_before=$(failure_count)
cp "$snapshot" "$SB/expected-readonly-snapshot"
readonly_mtime_before=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$snapshot")
chmod 555 "$STATE"
readonly_state_rc=0
HERDR_MODE=success sweep_with_path "$WITH_HERDR" || readonly_state_rc=$?
chmod 700 "$STATE"
assert_eq 'read-only STATE does not fail the sweep' "$readonly_state_rc" 0
assert_no_file 'read-only STATE cannot create the failing marker' "$failing_marker"
assert_eq 'read-only STATE failure is still logged' "$(failure_count)" "$((readonly_failures_before + 1))"
readonly_bytes_ok=no
cmp -s "$SB/expected-readonly-snapshot" "$snapshot" && readonly_bytes_ok=yes
assert_eq 'read-only STATE leaves the old snapshot untouched' "$readonly_bytes_ok" yes
readonly_mtime_after=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$snapshot")
assert_eq 'read-only STATE leaves the old snapshot to age' "$readonly_mtime_after" "$readonly_mtime_before"

rm -f "$snapshot"
failures_before=$(failure_count)
calls_before_missing_herdr=$(wc -l < "$SB/herdr-calls")
no_herdr_rc=0
HOME="$SB/home" PATH="$WITHOUT_HERDR" "$BIN/auto-handoff-sweep.sh" >"$SB/no-herdr.stdout" 2>"$SB/no-herdr.stderr" || no_herdr_rc=$?
assert_eq 'missing herdr does not fail the sweep' "$no_herdr_rc" 0
assert_no_file 'missing herdr writes no pane snapshot' "$snapshot"
assert_eq 'missing herdr emits no stderr' "$(cat "$SB/no-herdr.stderr")" ''
assert_eq 'missing herdr emits no stdout' "$(cat "$SB/no-herdr.stdout")" ''
assert_eq 'missing herdr is not invoked' "$(wc -l < "$SB/herdr-calls")" "$calls_before_missing_herdr"
assert_eq 'missing herdr logs no snapshot failure' "$(failure_count)" "$failures_before"

sandbox_rm
finish
