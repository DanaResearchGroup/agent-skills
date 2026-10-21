#!/usr/bin/env bash
# Bug: a compact/handoff request was discarded after REQUEST_MAX_AGE=3600 s by
# age alone. A /goal session whose pane never went idle lost four valid
# handoffs this way and redid them. A request is now stale only when the
# handoff it points to is OLDER than the session's last compaction (or there is
# no pointer); a handoff-request, which asks for a handoff not yet written, is
# stale only once a compaction is newer than the request. Age never removes.

. "$(dirname "$0")/lib.sh"

SID=99999999-9999-9999-9999-999999999999

setup() {
  sandbox_new; stub_mux; stub_watcher; arm
  session_new "$SID" 12 "w1:p1"
  export MUX_LIVE_PANES="w1:p1" MUX_BUSY=0
  HF="$AUTODEV_HOME/handoffs/2026.01.01 00.00.00 handoff-h.md"
  printf 'h\n' > "$HF"
  printf '%s\n' "$HF" > "$AUTODEV_HOME/handoffs/.latest.$SID"
}
sweep() { bash "$BIN/auto-handoff-sweep.sh" >/dev/null 2>&1; }
LOGF() { cat "$AUTODEV_HOME/logs/auto-handoff.log" 2>/dev/null; }

echo "== compact-request =="
setup
: > "$STATE/$SID.compact-request"; touch -d '3 hours ago' "$STATE/$SID.compact-request"
touch -d '4 hours ago' "$STATE/$SID.compacted"; touch -d '2 hours ago' "$HF"
sweep
assert_file "an old request whose handoff is newer than the last compaction is kept" "$STATE/$SID.compact-request"
assert_launched "and the watcher is re-armed for it" "$SID"
sandbox_rm

setup
: > "$STATE/$SID.compact-request"
touch -d '1 hour ago' "$STATE/$SID.compacted"; touch -d '2 hours ago' "$HF"
sweep
assert_no_file "a request whose handoff predates the last compaction is removed" "$STATE/$SID.compact-request"
assert_contains "and the removal is logged" "$(LOGF)" "SKIP stale compact-request"
assert_not_launched "and no watcher is launched" "$SID"
sandbox_rm

setup
: > "$STATE/$SID.compact-request"; rm -f "$AUTODEV_HOME/handoffs/.latest.$SID"
sweep
assert_no_file "a compact-request with no handoff pointer is removed" "$STATE/$SID.compact-request"
sandbox_rm

setup
: > "$STATE/$SID.compact-request"; touch -d '5 hours ago' "$STATE/$SID.compact-request"
sweep
assert_file "no compaction ever + pointer present: age alone never removes" "$STATE/$SID.compact-request"
sandbox_rm

# A dead session's stale request is cleaned too (before the pane check).
setup
export MUX_LIVE_PANES="w9:pNONE"
: > "$STATE/$SID.compact-request"
touch -d '1 hour ago' "$STATE/$SID.compacted"; touch -d '2 hours ago' "$HF"
sweep
assert_no_file "a stale request on a dead pane is removed too" "$STATE/$SID.compact-request"
sandbox_rm

echo "== handoff-request (the handoff is not written yet) =="
setup
rm -f "$AUTODEV_HOME/handoffs/.latest.$SID"
: > "$STATE/$SID.handoff-request"; touch -d '3 hours ago' "$STATE/$SID.handoff-request"
sweep
assert_file "an old handoff-request with no pointer is kept" "$STATE/$SID.handoff-request"
sandbox_rm

setup
: > "$STATE/$SID.handoff-request"; touch -d '3 hours ago' "$STATE/$SID.handoff-request"
touch -d '1 hour ago' "$STATE/$SID.compacted"
sweep
assert_no_file "a handoff-request older than the last compaction is removed" "$STATE/$SID.handoff-request"
sandbox_rm

echo "== boundary and ownership =="
setup
: > "$STATE/$SID.compact-request"
touch -d '@1000000000.100000000' "$STATE/$SID.compacted"; touch -d '@1000000000.900000000' "$HF"
sweep
assert_file "handoff written later in the same second as the compaction -> kept" "$STATE/$SID.compact-request"
sandbox_rm

setup
: > "$STATE/$SID.compact-request"
touch -d '@1000000000.900000000' "$STATE/$SID.compacted"; touch -d '@1000000000.100000000' "$HF"
sweep
assert_no_file "handoff written earlier in the same second -> removed" "$STATE/$SID.compact-request"
sandbox_rm

setup
: > "$STATE/$SID.handoff-request"
touch -d '@1000000000.100000000' "$STATE/$SID.handoff-request"; touch -d '@1000000000.900000000' "$STATE/$SID.compacted"
sweep
assert_no_file "handoff-request: compaction later in the same second -> removed" "$STATE/$SID.handoff-request"
sandbox_rm

# Only <sid>'s own pointer counts: another session's fresh pointer, or the shared
# .latest, must not keep this session's request alive.
setup
rm -f "${AUTODEV_HOME:?}/handoffs/.latest.$SID"
printf '%s\n' "$HF" > "$AUTODEV_HOME/handoffs/.latest.other-session"
printf '%s\n' "$HF" > "$AUTODEV_HOME/handoffs/.latest"
: > "$STATE/$SID.compact-request"
sweep
assert_no_file "another session's pointer / the shared .latest do not validate this request" "$STATE/$SID.compact-request"
sandbox_rm

echo "== the watcher and request-lib agree =="
# Same fixtures through both entry points: sweep removal must equal watcher removal.
for variant in valid nopointer predates; do
  setup; cp "$SKILL_DIR/bin/auto-handoff-watch.sh" "$BIN/"
  : > "$STATE/$SID.compact-request"
  case "$variant" in
    nopointer) rm -f "${AUTODEV_HOME:?}/handoffs/.latest.$SID" ;;
    predates) touch -d '1 hour ago' "$STATE/$SID.compacted"; touch -d '2 hours ago' "$HF" ;;
  esac
  AUTODEV_SETTLE=0 AUTODEV_PRECHECK=1 AUTODEV_WAIT_IDLE=1 MUX_BUSY=1 bash "$BIN/auto-handoff-watch.sh" "$SID" >/dev/null 2>&1
  [ -f "$STATE/$SID.compact-request" ] && w=kept || w=removed
  : > "$STATE/$SID.compact-request"
  stub_watcher
  sweep
  [ -f "$STATE/$SID.compact-request" ] && sw=kept || sw=removed
  assert_eq "watcher and sweep agree for [$variant]" "$w" "$sw"
  sandbox_rm
done

echo "== removal races =="
# remove_stale_request claims the file, re-validates, and only then deletes.
LIBCALL() { ( . "$SKILL_DIR/bin/request-lib.sh"; "$@" ); }
setup
: > "$STATE/$SID.compact-request"
touch -d '1 hour ago' "$STATE/$SID.compacted"; touch -d '2 hours ago' "$HF"
LIBCALL remove_stale_request "$STATE" "$AUTODEV_HOME/handoffs" "$SID" compact-request
assert_eq "a genuinely stale request is removed" "$([ -f "$STATE/$SID.compact-request" ] && echo kept || echo removed)" removed
assert_eq "and no claim file is left behind" "$(ls "$STATE" | grep -c 'compact-request\.')" 0
sandbox_rm

# A request that turns valid between the check and the delete (new handoff pointer
# landed) must survive: the first validity answer is "stale", the second "valid".
setup
: > "$STATE/$SID.compact-request"
( . "$SKILL_DIR/bin/request-lib.sh"; n=0
  request_valid(){ n=$((n+1)); [ "$n" -ge 2 ]; }
  remove_stale_request "$STATE" "$AUTODEV_HOME/handoffs" "$SID" compact-request )
assert_file "a request that became valid between check and delete survives" "$STATE/$SID.compact-request"
assert_eq "and no claim file is left behind" "$(ls "$STATE" | grep -c 'compact-request\.')" 0
sandbox_rm

# ...and restoring it never overwrites a NEWER request filed in that window.
setup
: > "$STATE/$SID.compact-request"
( . "$SKILL_DIR/bin/request-lib.sh"; n=0
  request_valid(){ n=$((n+1)); if [ "$n" -eq 2 ]; then printf 'newer\n' > "$STATE/$SID.compact-request"; return 0; fi; return 1; }
  remove_stale_request "$STATE" "$AUTODEV_HOME/handoffs" "$SID" compact-request )
assert_eq "restore does not clobber a request filed meanwhile" "$(cat "$STATE/$SID.compact-request")" newer
assert_eq "and leaves no claim file" "$(ls "$STATE" | grep -c 'compact-request\.')" 0
sandbox_rm

# Sweep + watcher both cleaning the same stale request: it ends removed, once, with no error.
setup; cp "$SKILL_DIR/bin/auto-handoff-watch.sh" "$BIN/"
: > "$STATE/$SID.compact-request"
touch -d '1 hour ago' "$STATE/$SID.compacted"; touch -d '2 hours ago' "$HF"
AUTODEV_SETTLE=0 AUTODEV_PRECHECK=1 AUTODEV_WAIT_IDLE=1 MUX_BUSY=1 bash "$BIN/auto-handoff-watch.sh" "$SID" >/dev/null 2>&1 &
stub_watcher
sweep
wait
assert_no_file "concurrent sweep + watcher cleanup leaves it removed" "$STATE/$SID.compact-request"
assert_eq "and no claim file is left behind" "$(ls "$STATE" | grep -c 'compact-request\.')" 0
sandbox_rm

echo "== the watcher applies the same rule =="
setup
cp "$SKILL_DIR/bin/auto-handoff-watch.sh" "$BIN/"   # setup stubbed it
: > "$STATE/$SID.compact-request"; touch -d '3 hours ago' "$STATE/$SID.compact-request"
AUTODEV_SETTLE=0 AUTODEV_PRECHECK=1 AUTODEV_WAIT_IDLE=1 AUTODEV_WAIT_COMPACT=1 MUX_BUSY=1 \
  bash "$BIN/auto-handoff-watch.sh" "$SID" >/dev/null 2>&1
assert_file "watcher leaves an old valid request in place when it defers" "$STATE/$SID.compact-request"
assert_not_contains "and does not call it stale" "$(LOGF)" "SKIP stale"
assert_file "and records the DEFER for the pager" "$STATE/$SID.deferred"
sandbox_rm

finish
