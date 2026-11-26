#!/usr/bin/env bash
# Bug (2026-11-26 19:09): `request-handoff.sh --compact-only` run WITHOUT
# --handoff copied the machine-wide ~/agents/handoffs/.latest into this seat's
# reload pointer .latest.<sid>, logged a WARN, and filed the compact-request.
# The shared .latest names whichever seat handed off last, so the pointer named
# ANOTHER seat's handoff, the watcher sent /compact, and the reload would have
# resumed the wrong mission.
#
# Contract pinned here: without --handoff, --compact-only files a marker only
# when this seat's own .latest.<sid> already names an existing regular file. It
# never copies the shared .latest. Otherwise it refuses — non-zero, one stderr
# line naming the fix, no marker — on the mid-cycle path too.

. "$(dirname "$0")/lib.sh"

SID=63163163-1631-6316-3163-163163163163

setup() {
  sandbox_new
  stub_mux
  session_new "$SID" 20 "w1:p1"
  H="$AUTODEV_HOME/handoffs"
  FOREIGN="$H/2026.01.01 00.00.00 handoff-another-seats-mission.md"
  OURS="$H/2026.01.02 00.00.00 handoff-our-own-mission.md"
  printf 'mission of another seat\n' > "$FOREIGN"
  printf 'our mission\n' > "$OURS"
  printf '%s\n' "$FOREIGN" > "$H/.latest"   # another seat handed off last
  PER="$H/.latest.$SID"
  REQ="$STATE/$SID.compact-request"
}

# run_rh [args...] -> sets $rc, $out (stdout), $err (stderr)
run_rh() {
  local o e
  o="$SB/rh.out"; e="$SB/rh.err"
  bash "$BIN/request-handoff.sh" "$SID" --compact-only "$@" >"$o" 2>"$e"
  rc=$?
  out=$(cat "$o"); err=$(cat "$e")
}

FIX='pass --handoff <absolute path>'

# A refusal: non-zero, the fix named on stderr, no marker, pointer as before.
assert_refused() { # $1 = label
  [ "$rc" -ne 0 ] && _pass "$1: exits non-zero" || _fail "$1: exits non-zero" "rc=$rc"
  assert_contains "$1: stderr names the fix" "$err" "$FIX"
  assert_eq "$1: the refusal is one stderr line" "$(printf '%s\n' "$err" | grep -c .)" 1
  assert_no_file "$1: no compact-request filed" "$REQ"
}

# Write this seat's pointer by hand, with an old mtime, so "unchanged" is checkable.
pointer() { # $1 = content
  printf '%s\n' "$1" > "$PER"
  touch -d '2026-01-03 00:00:00' "$PER"
}
pointer_state() { printf '%s|%s' "$(cat "$PER" 2>/dev/null)" "$(stat -c %Y "$PER" 2>/dev/null)"; }

echo "== no --handoff, no own pointer, shared .latest names another seat =="
setup
run_rh
assert_refused "no own pointer"
assert_no_file "no own pointer: .latest.<sid> still absent" "$PER"
[ -L "$PER" ] && _fail "no own pointer: .latest.<sid> is not a symlink" "$PER" ||
  _pass "no own pointer: .latest.<sid> is not a symlink"
assert_not_contains "no own pointer: the log records no copy of the shared .latest" \
  "$(cat "$AUTODEV_HOME/logs/auto-handoff.log" 2>/dev/null)" "legacy copy"
sandbox_rm

echo "== same, while the watcher is mid-cycle =="
setup
hold_cycle_lock "$SID"
run_rh
release_cycle_lock
assert_refused "mid-cycle, no own pointer"
assert_no_file "mid-cycle, no own pointer: .latest.<sid> still absent" "$PER"
assert_not_contains "mid-cycle, no own pointer: not reported as a deferral" "$out" "already mid-cycle"
sandbox_rm

echo "== own pointer names an existing file: marker filed, pointer unchanged =="
setup
pointer "$OURS"
before=$(pointer_state)
run_rh
assert_eq "own pointer: exits 0" "$rc" 0
assert_file "own pointer: compact-request filed" "$REQ"
assert_eq "own pointer: pointer content and mtime unchanged" "$(pointer_state)" "$before"
assert_contains "own pointer: reports the marker" "$out" "compact-request raised for $SID"
sandbox_rm

echo "== own pointer names an existing file, mid-cycle: deferred as today =="
setup
pointer "$OURS"
before=$(pointer_state)
hold_cycle_lock "$SID"
run_rh
release_cycle_lock
assert_eq "own pointer, mid-cycle: exits 0" "$rc" 0
assert_no_file "own pointer, mid-cycle: no marker (the cycle compacts)" "$REQ"
assert_contains "own pointer, mid-cycle: says why nothing was filed" "$out" "already mid-cycle"
assert_eq "own pointer, mid-cycle: pointer unchanged" "$(pointer_state)" "$before"
assert_eq "own pointer, mid-cycle: no warning on stderr" "$err" ""
sandbox_rm

echo "== own pointer names a missing file =="
setup
pointer "$H/2026.01.04 00.00.00 handoff-deleted.md"
before=$(pointer_state)
run_rh
assert_refused "pointer to a missing file"
assert_eq "pointer to a missing file: pointer unchanged" "$(pointer_state)" "$before"
sandbox_rm

echo "== own pointer is empty =="
setup
: > "$PER"
run_rh
assert_refused "empty pointer"
sandbox_rm

echo "== --handoff <file>: unchanged =="
setup
run_rh --handoff "$OURS"
assert_eq "--handoff: exits 0" "$rc" 0
assert_file "--handoff: compact-request filed" "$REQ"
assert_eq "--handoff: pointer names the given file" "$(cat "$PER")" "$OURS"
sandbox_rm
setup
hold_cycle_lock "$SID"
run_rh --handoff "$OURS"
release_cycle_lock
assert_eq "--handoff, mid-cycle: exits 0" "$rc" 0
assert_no_file "--handoff, mid-cycle: no marker" "$REQ"
assert_eq "--handoff, mid-cycle: pointer recorded" "$(cat "$PER")" "$OURS"
sandbox_rm

echo "== --cancel needs no pointer =="
setup
: > "$REQ"
run_rh --cancel
assert_eq "--cancel without a pointer: exits 0" "$rc" 0
assert_no_file "--cancel without a pointer: marker removed" "$REQ"
sandbox_rm

echo "== input forms of the own pointer =="

# 1. A dangling symbolic link — as the pointer's target, and as the pointer itself.
setup
ln -s "$H/no-such-handoff.md" "$H/dangling.md"
pointer "$H/dangling.md"
run_rh
assert_refused "pointer names a dangling symlink"
sandbox_rm
setup
ln -s "$H/no-such-pointer" "$PER"
run_rh
assert_refused ".latest.<sid> is a dangling symlink"
sandbox_rm

# 2. A symbolic link loop.
setup
ln -s "$H/loop-b.md" "$H/loop-a.md"; ln -s "$H/loop-a.md" "$H/loop-b.md"
pointer "$H/loop-a.md"
run_rh
assert_refused "pointer names a symlink loop"
sandbox_rm
setup
ln -s "$PER" "$PER"
run_rh
assert_refused ".latest.<sid> is a symlink loop"
sandbox_rm

# 3. A symbolic link to a directory — and the pointer itself a symlink to the
#    shared .latest, which names a real (foreign) file: adopting it is the bug.
setup
mkdir "$H/a-dir"; ln -s "$H/a-dir" "$H/dir-link.md"
pointer "$H/dir-link.md"
run_rh
assert_refused "pointer names a symlink to a directory"
sandbox_rm
setup
pointer "$H"
run_rh
assert_refused "pointer names a directory"
sandbox_rm
setup
ln -s "$H/.latest" "$PER"
run_rh
assert_refused ".latest.<sid> is a symlink to the shared .latest"
assert_eq ".latest.<sid> symlink: the shared .latest is untouched" "$(cat "$H/.latest")" "$FOREIGN"
sandbox_rm

# 4. A path that starts with an unexpanded ~ (resolvable if a reader expanded it).
setup
ORIG_HOME=$HOME; export HOME="$SB/home"; mkdir -p "$HOME"; printf 'x\n' > "$HOME/h.md"
# shellcheck disable=SC2088  # the literal, unexpanded ~ is the input under test
pointer '~/h.md'
run_rh
export HOME="$ORIG_HOME"
assert_refused "pointer starts with an unexpanded ~"
sandbox_rm

# 5. A relative path (resolvable from the cwd the helper runs in).
setup
pointer "handoffs/2026.01.02 00.00.00 handoff-our-own-mission.md"
( cd "$AUTODEV_HOME" && bash "$BIN/request-handoff.sh" "$SID" --compact-only >"$SB/rh.out" 2>"$SB/rh.err" )
rc=$?; out=$(cat "$SB/rh.out"); err=$(cat "$SB/rh.err")
assert_refused "pointer is a relative path"
sandbox_rm

# 6. Spaces and quotes in file and directory names (AUTODEV_HOME included).
setup
# shellcheck disable=SC2089,SC2090  # the quotes are literal parts of the name under test
export AUTODEV_HOME="$SB/a b 'c' \"d\"/agents"
STATE="$AUTODEV_HOME/state"
# shellcheck disable=SC2090
export STATE
mkdir -p "$STATE" "$AUTODEV_HOME/logs" "$AUTODEV_HOME/handoffs/dir with 'q' \"x\""
session_new "$SID" 20 "w1:p1"
PER="$AUTODEV_HOME/handoffs/.latest.$SID"; REQ="$STATE/$SID.compact-request"
QF="$AUTODEV_HOME/handoffs/dir with 'q' \"x\"/2026.01.05 00.00.00 handoff-it's \"quoted\".md"
printf 'quoted\n' > "$QF"
pointer "$QF"
before=$(pointer_state)
run_rh
assert_eq "quoted names: own pointer accepted" "$rc" 0
assert_file "quoted names: compact-request filed" "$REQ"
assert_eq "quoted names: pointer unchanged" "$(pointer_state)" "$before"
rm -f "$REQ" "$PER"
run_rh
assert_refused "quoted names: no own pointer still refused"
run_rh --handoff "$QF"
assert_eq "quoted names: --handoff accepted" "$rc" 0
assert_eq "quoted names: --handoff pointer" "$(cat "$PER")" "$QF"
sandbox_rm

# 7. A parent directory the process cannot read — of the target, and of the pointer.
if [ "$(id -u)" = 0 ]; then
  _pass "unreadable-parent cases skipped: root reads through mode 000"
else
  setup
  mkdir "$SB/locked"; printf 'x\n' > "$SB/locked/h.md"; chmod 000 "$SB/locked"
  pointer "$SB/locked/h.md"
  run_rh
  chmod 700 "$SB/locked"
  assert_refused "pointer target's parent is unreadable"
  sandbox_rm
  setup
  pointer "$OURS"
  chmod 000 "$H"
  run_rh
  chmod 700 "$H"
  assert_refused "pointer's own directory is unreadable"
  sandbox_rm
fi

# 8. A glob that matches nothing — and one that would match if expanded.
setup
pointer "$H/*.nomatch"
run_rh
assert_refused "pointer is a glob that matches nothing"
sandbox_rm
setup
pointer "$H/2026.01.02*.md"
run_rh
assert_refused "pointer is a glob, never expanded"
sandbox_rm

finish
