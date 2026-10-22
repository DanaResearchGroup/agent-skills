#!/usr/bin/env bash
# Bug: the context threshold depended on the model choosing to file a request.
#
# cc-handoff-gate.sh denies new work only while a <sid>.handoff-request exists,
# and the watcher types only into an idle pane. A session that crosses
# THRESHOLD inside one long busy turn and never files its own request was
# therefore never stopped: it ran past 40% until the turn ended on its own.
#
# The sweep now files the request itself when the session is over THRESHOLD,
# its pane has been working continuously for more than N minutes (default 20,
# AUTODEV_BUSY_MINUTES), no request is pending, and the pane is not awaiting
# the human. Nothing records when a busy stretch began, so the sweep keeps
# <sid>.busy-since ("<start> <last>", epoch seconds) from its own observations.
#
# Like test-awaiting-human.sh this runs the REAL mux-lib.sh and fakes only the
# herdr executable. Time is controlled by seeding busy-since with old epochs.

. "$(dirname "$0")/lib.sh"

SID=66666666-6666-6666-6666-666666666666
FX="$SKILL_DIR/test/fixtures/panes"

setup() {
  sandbox_new
  mkdir -p "$SB/herdr" "$SB/fakebin"
  printf 'working\n' > "$SB/herdr/status"
  printf 'live\n' > "$SB/herdr/live"
  cp "$FX/idle-prompt.txt" "$SB/herdr/screen.txt"
  cat > "$SB/fakebin/herdr" <<'STUB'
#!/usr/bin/env bash
H="$SB/herdr"
case "${1:-} ${2:-}" in
  "pane get")
      [ "$(cat "$H/live")" = live ] || exit 1
      printf '{"result":{"pane_id":"%s","agent_status":"%s","agent_session":{"value":"%s"}}}\n' \
        "$3" "$(cat "$H/status")" "$(cat "$H/owner" 2>/dev/null)" ;;
  "pane read") cat "$H/screen.txt" ;;
  "tab get"|"tab rename") exit 1 ;;
  *) echo "fake herdr: unhandled [$*]" >&2; exit 64 ;;
esac
STUB
  chmod +x "$SB/fakebin/herdr"
  export PATH="$SB/fakebin:$ORIG_PATH" MUX_HERDR="$SB/fakebin/herdr"
  stub_watcher
  session_new "$SID" 40 "w1:p1"
  printf '%s\n' "$SID" > "$SB/herdr/owner"
  arm
  unset AUTODEV_BUSY_MINUTES AUTODEV_BUSY_GAP
  REQ="$STATE/$SID.handoff-request"
  CLOCK="$STATE/$SID.busy-since"
}
ORIG_PATH="$PATH"
REAL_LN=$(command -v ln)

sweep() {
  local launches_before rearms_before rearms_after i
  launches_before=$(wc -l < "$SB/launched.log")
  rearms_before=$(grep -c 'SWEEP re-arming watcher' "$AUTODEV_HOME/logs/auto-handoff.log" 2>/dev/null || true)
  rearms_before=${rearms_before:-0}
  bash "$BIN/auto-handoff-sweep.sh" >"$SB/sweep.out" 2>&1
  rearms_after=$(grep -c 'SWEEP re-arming watcher' "$AUTODEV_HOME/logs/auto-handoff.log" 2>/dev/null || true)
  rearms_after=${rearms_after:-0}
  [ "$rearms_after" -gt "$rearms_before" ] || return 0
  for i in $(seq 1 20); do
    [ "$(wc -l < "$SB/launched.log")" -gt "$launches_before" ] && return 0
    sleep 0.05
  done
}
status() { printf '%s\n' "$1" > "$SB/herdr/status"; }
screen() { cp "$FX/$1.txt" "$SB/herdr/screen.txt"; }
LOG()    { cat "$AUTODEV_HOME/logs/auto-handoff.log" 2>/dev/null; }
# Seed a busy stretch that began <start_ago> seconds ago, last seen <last_ago> ago.
clock() { local n; n=$(date +%s); printf '%s %s\n' "$(( n - $1 ))" "$(( n - ${2:-60} ))" > "$CLOCK"; }
raised() { LOG | grep -c 'REQUEST raised (threshold, busy' ; }
would_raise() { LOG | grep -c 'REQUEST would raise (threshold, busy' ; }
inode() { stat -c %i "$1"; }
mt()    { stat -c %Y "$1"; }
signature() { stat -c '%i %y' "$1"; }

gate_decision() {
  jq -nc --arg s "$SID" '{session_id:$s,tool_name:"Bash",tool_input:{command:"make test"},hook_event_name:"PreToolUse"}' |
    bash "$BIN/cc-handoff-gate.sh" 2>/dev/null |
    jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null
}

echo "== over threshold, busy past N minutes: one request, then the gate denies =="
setup; clock 1500
sweep
assert_file "request filed" "$REQ"
assert_contains "logged as a threshold request" "$(LOG)" "REQUEST raised (threshold, busy 25m)"
assert_eq "the gate now denies a non-handoff tool call" "$(gate_decision)" deny
assert_no_file "the busy clock is spent" "$CLOCK"
i=$(inode "$REQ"); m=$(mt "$REQ")
sweep; sweep
assert_eq "repeated sweeps raise exactly once" "$(raised)" 1
assert_eq "and leave the same file" "$(inode "$REQ") $(mt "$REQ")" "$i $m"
sandbox_rm

echo "== unarmed threshold is dry-run =="
setup; rm -f "$STATE/auto-handoff.armed"; clock 1500
sweep
assert_no_file "unarmed threshold: no request filed" "$REQ"
assert_contains "unarmed threshold logs would-raise" "$(LOG)" "REQUEST would raise (threshold, busy 25m) [dry-run]"
assert_file "unarmed threshold keeps the busy clock" "$CLOCK"
sandbox_rm

echo "== unarmed preview survives a real dry-run watcher cooldown =="
setup; rm -f "$STATE/auto-handoff.armed"; clock 1500
cp "$SKILL_DIR/bin/auto-handoff-watch.sh" "$BIN/auto-handoff-watch-real.sh"
cat > "$BIN/auto-handoff-watch.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$SB/launched.log"
exec bash "$(dirname "$0")/auto-handoff-watch-real.sh" "$@"
STUB
chmod +x "$BIN/auto-handoff-watch.sh"
export AUTODEV_SETTLE=0 AUTODEV_POLL=0.01
sweep
for i in $(seq 1 100); do
  [ "$(LOG | grep -c 'CYCLE COMPLETE' || true)" -ge 1 ] && break
  sleep 0.02
done
assert_eq "first dry-run pass logs a preview" "$(would_raise)" 1
assert_file "real dry-run watcher stamps cooldown" "$STATE/$SID.cooldown"
assert_no_file "real dry-run watcher files no request" "$REQ"
clock 1500
sweep
assert_eq "second sweep previews despite the real watcher's cooldown" "$(would_raise)" 2
for i in $(seq 1 100); do
  LOG | grep -q 'SKIP cooldown active' && break
  sleep 0.02
done
assert_contains "real watcher still observes its cooldown" "$(LOG)" "SKIP cooldown active"
assert_eq "first real dry-run cycle completed" "$(LOG | grep -c 'CYCLE COMPLETE' || true)" 1
assert_file "dry-run preview keeps the busy clock" "$CLOCK"
sandbox_rm

echo "== no request =="
setup; clock 1500; session_new "$SID" 30 "w1:p1"
sweep
assert_no_file "under threshold" "$REQ"
assert_no_file "under threshold: busy clock cleared" "$CLOCK"
session_new "$SID" 40 "w1:p1"
sweep
assert_no_file "crossing threshold starts a fresh busy clock" "$REQ"
assert_file "crossing threshold starts its clock now" "$CLOCK"
sandbox_rm

setup; clock 600
sweep
assert_no_file "busy for 10m < 20m" "$REQ"
assert_file "the clock keeps running" "$CLOCK"
sandbox_rm

setup
sweep
assert_no_file "first sighting alone never raises" "$REQ"
assert_file "but it starts the clock" "$CLOCK"
sandbox_rm

for fx in single-select permission-bash rate-limit-menu; do
  setup; clock 1500; screen "$fx"
  sweep
  assert_no_file "awaiting the human ($fx): no request" "$REQ"
  assert_eq "awaiting the human ($fx): nothing raised" "$(raised)" 0
  sandbox_rm
done

setup; clock 1500; status blocked
sweep
assert_no_file "herdr blocked: no request" "$REQ"
sandbox_rm

setup; clock 1500; : > "$STATE/$SID.limit-wait"
sweep
assert_no_file "limit-wait session: no request" "$REQ"
assert_no_file "limit-wait clears the busy clock" "$CLOCK"
rm -f "$STATE/$SID.limit-wait"
sweep
assert_no_file "working after limit-wait starts a fresh duration" "$REQ"
assert_file "working after limit-wait starts a fresh clock" "$CLOCK"
sandbox_rm

echo "== a request already pending is never duplicated or overwritten =="
for kind in handoff-request compact-request; do
  setup; clock 1500; handoff_pointer "$SID"
  f="$STATE/$SID.$kind"; : > "$f"; touch -d '2 hours ago' "$f"
  i=$(inode "$f"); m=$(mt "$f")
  sweep
  assert_eq "pending $kind: same inode and mtime" "$(inode "$f") $(mt "$f")" "$i $m"
  assert_eq "pending $kind: nothing raised" "$(raised)" 0
  [ "$kind" = compact-request ] && assert_no_file "pending compact-request: no second marker" "$REQ"
  sandbox_rm
done

echo "== the marker appears between the re-check and the write =="
# Inject the session-owned request after the sweep's re-check. For a compact
# request, inject after the writer's link succeeds to exercise its post-link path.
race() { # $1 = marker kind the session files
  setup; clock 1500; handoff_pointer "$SID"
  if [ "$1" = compact-request ]; then
    cat > "$SB/fakebin/ln" <<STUB
#!/usr/bin/env bash
"$REAL_LN" "\$@" || exit \$?
f="\$STATE/$SID.compact-request"; : > "\$f"; touch -d '2 hours ago' "\$f"
stat -c '%i %y' "\$f" > "$SB/race.before"
STUB
    chmod +x "$SB/fakebin/ln"
    sweep
    return
  fi
  mv "$BIN/request-handoff.sh" "$BIN/request-handoff-real.sh"
  cat > "$BIN/request-handoff.sh" <<STUB
#!/usr/bin/env bash
f="$STATE/$SID.$1"; : > "\$f"; touch -d '2 hours ago' "\$f"
stat -c '%i %y' "\$f" > "$SB/race.before"
exec bash "\$(dirname "\$0")/request-handoff-real.sh" "\$@"
STUB
  chmod +x "$BIN/request-handoff.sh"
  sweep
}
race handoff-request
f="$STATE/$SID.handoff-request"
assert_eq "T8b injected handoff keeps inode and mtime" "$(signature "$f")" "$(cat "$SB/race.before")"
assert_eq "own handoff-request keeps its mtime" "$(( $(date +%s) - $(mt "$f") > 3600 ))" 1
assert_eq "no sweep temp file left behind" "$(find "$STATE" -name '*request.tmp*' | wc -l)" 0
assert_contains "skip is logged" "$(LOG)" "REQUEST skipped (session filed its own)"
assert_eq "nothing logged as raised" "$(raised)" 0
sandbox_rm

race compact-request
assert_eq "T8b injected compact keeps inode and mtime" "$(signature "$STATE/$SID.compact-request")" "$(cat "$SB/race.before")"
assert_file "T8b leaves the handoff marker beside its compact marker" "$REQ"
assert_contains "T8b logs that handoff supersedes compact" "$(LOG)" "REQUEST raised alongside a session compact-request (handoff-request supersedes)"
assert_eq "T8b leaves no temp file" "$(find "$STATE" -name '*request.tmp*' | wc -l)" 0
sandbox_rm

# Same through the real writer directly: inode and mtime of an existing marker.
setup
f="$STATE/$SID.handoff-request"; : > "$f"; touch -d '2 hours ago' "$f"
i=$(signature "$f")
bash "$BIN/request-handoff.sh" "$SID" --if-absent --reason "threshold, busy 21m" >/dev/null 2>&1
assert_eq "--if-absent on an existing marker: same inode and mtime" "$(signature "$f")" "$i"
sandbox_rm

echo "== writer failure without a competing marker retries =="
setup; clock 1500
cat > "$SB/fakebin/ln" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$SB/fakebin/ln"
if out=$(bash "$BIN/request-handoff.sh" "$SID" --if-absent --reason "threshold, busy 25m" 2>&1); then rc=0; else rc=$?; fi
assert_eq "ln failure without an existing request exits 2" "$rc" 2
assert_contains "writer reports failed to write" "$out" "failed to write"
assert_no_file "failed writer leaves no request" "$REQ"
sweep
assert_file "sweep keeps the clock after writer failure" "$CLOCK"
assert_contains "sweep logs writer failure for retry" "$(LOG)" "REQUEST threshold writer failed (busy 25m)"
assert_no_file "sweep does not lose the request" "$REQ"
sandbox_rm

echo "== the busy clock resets =="
setup; clock 1500
status idle; sweep
assert_no_file "idle pane: clock deleted" "$CLOCK"
assert_no_file "idle pane: no request" "$REQ"
status working; sweep
assert_no_file "busy again: a fresh clock, no request" "$REQ"
assert_file "busy again: clock restarted" "$CLOCK"
assert_eq "restarted clock begins now" "$(( $(date +%s) - $(cut -d' ' -f1 "$CLOCK") < 5 ))" 1
sandbox_rm

setup; clock 1500
printf 'gone\n' > "$SB/herdr/live"
sweep
assert_no_file "missing pane: clock deleted" "$CLOCK"
printf 'live\n' > "$SB/herdr/live"
sweep
assert_no_file "pane returning: no request until a fresh duration" "$REQ"
assert_eq "pane returning: clock restarted" "$(( $(date +%s) - $(cut -d' ' -f1 "$CLOCK") < 5 ))" 1
sandbox_rm

setup; clock 1500
printf 'another-session\n' > "$SB/herdr/owner"
sweep
assert_no_file "reassigned pane: clock deleted" "$CLOCK"
printf '%s\n' "$SID" > "$SB/herdr/owner"
sweep
assert_no_file "reassigned pane returning: no request" "$REQ"
assert_eq "reassigned pane returning: clock restarted" "$(( $(date +%s) - $(cut -d' ' -f1 "$CLOCK") < 5 ))" 1
sandbox_rm

setup; clock 1500
printf '%s\n' "$(( $(date +%s) - 300 ))" > "$STATE/$SID.idle"   # a Stop landed mid-stretch
sweep
assert_no_file "a Stop since the clock started resets it" "$REQ"
assert_eq "and restarts it" "$(( $(date +%s) - $(cut -d' ' -f1 "$CLOCK") < 5 ))" 1
sandbox_rm

setup; clock 1500 1000                                          # last seen 1000 s ago
sweep
assert_no_file "an observation gap over 600s breaks continuity" "$REQ"
sandbox_rm

echo "== configuration =="
setup; clock 90; export AUTODEV_BUSY_MINUTES=1
sweep
assert_file "AUTODEV_BUSY_MINUTES=1 raises after 90s" "$REQ"
sandbox_rm

setup; clock 90; export AUTODEV_BUSY_MINUTES=01
sweep
assert_file "AUTODEV_BUSY_MINUTES=01 is a positive decimal override" "$REQ"
sandbox_rm

for bad in abc 0 00 -5 ""; do
  setup; clock 600; export AUTODEV_BUSY_MINUTES="$bad"
  sweep
  assert_no_file "AUTODEV_BUSY_MINUTES='$bad' falls back to 20 (10m: none)" "$REQ"
  sandbox_rm
  setup; clock 1500; export AUTODEV_BUSY_MINUTES="$bad"
  sweep
  assert_file "AUTODEV_BUSY_MINUTES='$bad' falls back to 20 (25m: raised)" "$REQ"
  sandbox_rm
done

setup; clock 1500 60; export AUTODEV_BUSY_GAP=00
sweep
assert_file "AUTODEV_BUSY_GAP=00 falls back to the 600s default" "$REQ"
sandbox_rm

echo "== the writer's default is unchanged =="
setup
bash "$BIN/request-handoff.sh" "$SID" >/dev/null 2>&1
assert_contains "no flags: the voluntary log line" "$(LOG)" "REQUEST raised (voluntary handoff-request"
rm -f "$REQ"
bash "$BIN/request-handoff.sh" "$SID" --reason "threshold, busy 21m" >/dev/null 2>&1
assert_contains "--reason replaces the label" "$(LOG)" "REQUEST raised (threshold, busy 21m)"
sandbox_rm

finish
