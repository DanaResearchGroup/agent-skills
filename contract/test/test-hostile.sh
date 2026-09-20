#!/usr/bin/env bash
# The ways state keyed on a path, and a gate driven by one string of status
# output, were made to lie. Each case here failed before the fix it names.
. "$(dirname "$0")/lib.sh"
sandbox_new
GATE="$HOOKS/contract-gate.sh"

hook() {  # tool file_path session_id
  printf '{"session_id":"%s","tool_name":"%s","tool_input":{"file_path":"%s"}}' "$3" "$1" "$2" \
    | bash "$GATE"
}

# --- Key collisions. /a/b and /a-b slug to the same string, so two unrelated
# repos shared one enablement marker, one skip log and one ACTIVE: a contract
# opened in either opened the other's gate.
mkdir -p "$SANDBOX/collide/a"
R1="$SANDBOX/collide/a/b"; R2="$SANDBOX/collide/a-b"
for r in "$R1" "$R2"; do
  git init -q -b main "$r"; git -C "$r" config user.email t@example.com
  git -C "$r" config user.name tester; echo x > "$r/f.txt"
  git -C "$r" add f.txt; git -C "$r" commit -qm init
done
(cd "$R1" && "$CONTRACT" enable >/dev/null && "$CONTRACT" new from-one >/dev/null)
assert_contains "$(cd "$R2" && "$CONTRACT" status)" "enabled=no" \
  "a repo whose path slugs like another's does not inherit its enablement"
assert_contains "$(cd "$R2" && "$CONTRACT" status)" "active=none" \
  "nor its active contract"
s1=$(cd "$R1" && "$CONTRACT" status | sed -n 's/^state=//p')
s2=$(cd "$R2" && "$CONTRACT" status | sed -n 's/^state=//p')
if [ "$s1" != "$s2" ]; then pass "colliding paths get distinct state dirs"
else fail "colliding paths get distinct state dirs (both $s1)"; fi

# --- A path long enough to blow NAME_MAX as one flattened component. Keys must
# stay usable, or a deep checkout could not hold state at all.
DEEP="$SANDBOX/$(printf 'd%.0s' $(seq 1 60))/$(printf 'e%.0s' $(seq 1 60))/$(printf 'f%.0s' $(seq 1 60))/$(printf 'g%.0s' $(seq 1 60))/repo"
mkdir -p "$DEEP"
git init -q -b main "$DEEP"; git -C "$DEEP" config user.email t@example.com
git -C "$DEEP" config user.name tester
(cd "$DEEP" && "$CONTRACT" enable >/dev/null); rc=$?
assert_eq 0 "$rc" "enable works in a checkout whose path exceeds NAME_MAX when flattened"
(cd "$DEEP" && "$CONTRACT" new deep-work >/dev/null); rc=$?
assert_eq 0 "$rc" "and a contract can be opened there"

# --- A relative CONTRACT_STATE_DIR resolved against each caller's cwd — the
# CLI's and the hook's differ — and could land state inside the repo.
out=$(cd "$WT" && CONTRACT_STATE_DIR=state "$CONTRACT" status 2>&1); rc=$?
assert_contains "$out" "absolute" "a relative CONTRACT_STATE_DIR is refused, with the reason"
assert_no_file "$WT/state" "and no state directory is created inside the worktree"

# --- Ambient git env vars made `git -C <dir>` describe a different repository,
# so the gate consulted, and the CLI keyed state on, somebody else's repo.
(cd "$WT" && "$CONTRACT" enable >/dev/null)
out=$(cd "$WT" && GIT_DIR="$R1/.git" GIT_WORK_TREE="$R1" "$CONTRACT" status)
assert_contains "$out" "wt=$WT" "an inherited GIT_DIR does not redirect resolution to another repo"
out=$(GIT_DIR="$R1/.git" GIT_WORK_TREE="$R1" hook Edit "$WT/f.txt" sG)
assert_contains "$out" '"deny"' "nor does it let an edit past the gate of the repo it is in"

# --- "none" is the sentinel the gate reads out of `status`, so a contract named
# none was active while status reported active=none: the gate kept denying and
# nothing could clear it.
out=$(cd "$WT" && "$CONTRACT" new none 2>&1); rc=$?
assert_eq 2 "$rc" "a contract may not be named none"
assert_contains "$out" "none" "and the refusal says so"
for bad in . ..; do
  (cd "$WT" && "$CONTRACT" new "$bad" >/dev/null 2>&1); rc=$?
  assert_eq 2 "$rc" "a contract may not be named '$bad'"
done

# --- A hand-edited ACTIVE is untrusted input: a traversal value must read as no
# contract rather than reaching a file outside the notes dir.
(cd "$WT" && "$CONTRACT" new real >/dev/null)
printf '../../../../etc/passwd\n' > "$WSTATE/ACTIVE"
assert_contains "$(cd "$WT" && "$CONTRACT" status)" "active=none" \
  "a traversal slug in ACTIVE reads as no active contract"
assert_eq "" "$(cd "$WT" && "$CONTRACT" show)" "and show discloses nothing"
printf 'real\n' > "$WSTATE/ACTIVE"

# --- The skip is "the only bypass that leaves a record", so it must not happen
# when the record cannot be written.
# A directory where the log file belongs makes the append fail for any caller,
# root included — chmod would not, and a chmod on a not-yet-created log is a
# no-op that makes this test pass vacuously.
rm -f "$STATE/skips.log"; mkdir -p "$STATE/skips.log"
out=$(cd "$WT" && "$CONTRACT" skip sess-unloggable "log is unwritable" 2>&1); rc=$?
rmdir "$STATE/skips.log"
assert_eq 2 "$rc" "skip refuses when its log cannot be appended"
(cd "$WT" && "$CONTRACT" skipped sess-unloggable); rc=$?
assert_eq 1 "$rc" "and no unlogged bypass is left behind"

# --- Closing a reused slug twice silently overwrote the first record.
printf 'evidence\n' >> "$WSTATE/real.md"
(cd "$WT" && "$CONTRACT" close >/dev/null)
(cd "$WT" && "$CONTRACT" new real >/dev/null)
printf 'second run evidence\n' >> "$WSTATE/real.md"
(cd "$WT" && "$CONTRACT" close >/dev/null)
kept=$(find "$WSTATE/closed" -name 'real*.md' | wc -l | tr -d ' ')
assert_eq 2 "$kept" "closing a reused slug keeps both archived notes"
# And a timestamp alone was not enough: fifteen closes inside one second
# collapsed to three files, because the suffix has one-second resolution.
for i in $(seq 1 15); do
  (cd "$WT" && "$CONTRACT" new repeat >/dev/null)
  printf 'evidence %s\n' "$i" >> "$WSTATE/repeat.md"
  (cd "$WT" && "$CONTRACT" close >/dev/null)
done
kept=$(find "$WSTATE/closed" -name 'repeat*.md' | wc -l | tr -d ' ')
assert_eq 15 "$kept" "fifteen closes of one slug inside a second keep fifteen archives"

# --- A crashed run can leave a note with no ACTIVE; `new` must not truncate it.
printf '# Contract — orphaned\nirreplaceable\n' > "$WSTATE/orphaned.md"
out=$(cd "$WT" && "$CONTRACT" new orphaned 2>&1); rc=$?
assert_eq 2 "$rc" "new refuses to overwrite an existing note"
assert_contains "$(cat "$WSTATE/orphaned.md")" "irreplaceable" "the orphaned note is intact"

# --- Two sessions opening a contract in one worktree at the same instant both
# passed the already-active check, and the loser's note was orphaned with no
# ACTIVE pointing at it.
# Both children spin on a barrier file, so they enter `new` together: started
# sequentially, one could finish before the other began and the old racy code
# would pass too.
BARRIER="$SANDBOX/go"
rm -f "$BARRIER"
racer() { until [ -f "$BARRIER" ]; do :; done; cd "$WT" && "$CONTRACT" new "$1" >/dev/null 2>&1; }
racer racer-a & p1=$!
racer racer-b & p2=$!
sleep 0.3
: > "$BARRIER"
wait $p1; r1=$?
wait $p2; r2=$?
if { [ "$r1" = 0 ] && [ "$r2" = 3 ]; } || { [ "$r1" = 3 ] && [ "$r2" = 0 ]; }; then
  pass "concurrent new: exactly one wins, the other is refused as already-active"
else
  fail "concurrent new: exactly one wins (got rc $r1 and $r2)"
fi
opened=$(find "$WSTATE" -maxdepth 1 -name 'racer-*.md' | wc -l | tr -d ' ')
assert_eq 1 "$opened" "and only the winner's note exists"
(cd "$WT" && "$CONTRACT" abandon "race probe" >/dev/null)
assert_no_file "$STATE/.lock" "the lock is released when the command exits"

# --- A dead lock holder must not gate the tool forever: a lock whose pid is
# gone is stolen rather than waited out.
mkdir -p "$STATE/.lock"
printf '999999\n' > "$STATE/.lock/pid"   # pid that cannot be running
out=$(cd "$WT" && "$CONTRACT" new after-crash 2>&1); rc=$?
assert_eq 0 "$rc" "a lock left by a dead process is stolen, not waited out"
assert_contains "$out" "stealing the lock" "and says so"
(cd "$WT" && "$CONTRACT" abandon "stale-lock probe" >/dev/null)
# A lock held by a LIVE process is respected, and the failure names contention
# rather than something else.
mkdir -p "$STATE/.lock"; printf '%s\n' "$$" > "$STATE/.lock/pid"
out=$(cd "$WT" && "$CONTRACT" new blocked-by-live 2>&1); rc=$?
rm -rf "$STATE/.lock"
assert_eq 2 "$rc" "a lock held by a live process is respected"
assert_contains "$out" "is holding" "and the refusal names the holder"

# --- State holds Intent, Gates and the skip log: not world-readable — but the
# state ROOT is the user's own directory and must not be re-permissioned.
perms=$(stat -c '%a' "$STATE" 2>/dev/null || stat -f '%Lp' "$STATE")
assert_eq 700 "$perms" "the repo state dir is private to its owner"
SHARED="$SANDBOX/shared-root"
mkdir -p "$SHARED"; chmod 755 "$SHARED"
(cd "$WT" && CONTRACT_STATE_DIR="$SHARED" "$CONTRACT" enable >/dev/null 2>&1)
(cd "$WT" && CONTRACT_STATE_DIR="$SHARED" "$CONTRACT" new in-shared-root >/dev/null 2>&1)
perms=$(stat -c '%a' "$SHARED" 2>/dev/null || stat -f '%Lp' "$SHARED")
assert_eq 755 "$perms" "a state root the user chose keeps its own permissions"

# --- An absolute root INSIDE the worktree is the deadlock again, wearing the
# absolute-path check as a disguise.
out=$(cd "$WT" && CONTRACT_STATE_DIR="$WT/.contract-state" "$CONTRACT" status 2>&1)
assert_contains "$out" "inside the worktree" "a state root inside the worktree is refused"
assert_no_file "$WT/.contract-state" "and nothing is created there"

# --- A gate that cannot tell whether a worktree is gated must say so, not read
# as "no gate here": a broken root used to silently disarm it.
out=$(cd "$WT" && CONTRACT_STATE_DIR="$WT/inside" "$CONTRACT" status)
assert_contains "$out" "enabled=unknown" "an unusable state root reports enabled=unknown"
out=$(CONTRACT_STATE_DIR="$WT/inside" hook Edit "$WT/f.txt" sBad)
assert_contains "$out" '"deny"' "and the gate denies rather than failing open"
assert_contains "$out" "state root" "naming what to fix"

# --- The gate hands `skipped` its session id straight from the payload, so an
# id naming an existing file under the skips dir once unblocked every session.
(cd "$WT" && "$CONTRACT" skip real-session "a real skip" >/dev/null)
(cd "$WT" && "$CONTRACT" skipped '../skips.log'); rc=$?
assert_eq 1 "$rc" "a traversal session id is not a skip"
assert_contains "$(hook Edit "$WT/f.txt" '../skips.log')" '"deny"' \
  "and the gate does not let it through"

# --- A session id of "." would log a skip and then fail to write its marker: an
# audit record of a bypass that never happened.
for bad in . ..; do
  out=$(cd "$WT" && "$CONTRACT" skip "$bad" "traversal id" 2>&1); rc=$?
  assert_eq 2 "$rc" "skip refuses a session id of '$bad'"
  assert_not_contains "$(cat "$STATE/skips.log" 2>/dev/null)" "traversal id"     "and logs nothing for it"
done

finish
