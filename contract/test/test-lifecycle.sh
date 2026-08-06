#!/usr/bin/env bash
# enable/new/show/close, and the evidence requirement on close.
. "$(dirname "$0")/lib.sh"
sandbox_new

# enable is keyed on the shared dir, so it is visible from every worktree.
(cd "$WT" && "$CONTRACT" enable >/dev/null)
assert_contains "$(cd "$WT" && "$CONTRACT" status)"   "enabled=yes" "enable is visible from the worktree"
assert_contains "$(cd "$REPO" && "$CONTRACT" status)" "enabled=yes" "enable is visible from the main checkout"

# new creates the note and sets ACTIVE.
(cd "$WT" && "$CONTRACT" new add-parser >/dev/null)
assert_contains "$(cd "$WT" && "$CONTRACT" status)" "active=add-parser" "new sets the active slug"
assert_file "$WT/docs/contracts/add-parser.md" "note file created"

note=$(cd "$WT" && "$CONTRACT" show)
assert_contains "$note" "## Intent"    "note has an Intent section"
assert_contains "$note" "## Verifier"  "note has a Verifier section"
assert_contains "$note" "## Non-goals" "note has a Non-goals section"
assert_contains "$note" "## Gates"     "note has a Gates section"
assert_contains "$note" "## Evidence"  "note has an Evidence section"

# A second new must refuse rather than silently clobber the active contract.
out=$(cd "$WT" && "$CONTRACT" new other 2>&1); rc=$?
assert_eq 3 "$rc" "new refuses while a contract is active"
assert_contains "$(cd "$WT" && "$CONTRACT" status)" "active=add-parser" "the active slug is unchanged"

# close refuses while Evidence is empty.
out=$(cd "$WT" && "$CONTRACT" close 2>&1); rc=$?
assert_eq 4 "$rc" "close refuses with empty Evidence"
assert_contains "$out" "Evidence" "close explains that Evidence is required"

# With evidence recorded, close archives the note and clears ACTIVE.
printf 'ran: pytest -k parser\n1 passed\n' >> "$WT/docs/contracts/add-parser.md"
(cd "$WT" && "$CONTRACT" close >/dev/null); rc=$?
assert_eq 0 "$rc" "close succeeds once Evidence non-empty"
assert_contains "$(cd "$WT" && "$CONTRACT" status)" "active=none" "close clears the active slug"
assert_file "$WT/docs/contracts/closed/add-parser.md" "closed note archived"

# ACTIVE is keyed on the worktree, NOT the shared dir: the main checkout
# never had a contract active in this one work worktree.
assert_contains "$(cd "$REPO" && "$CONTRACT" status)" "active=none" "active state does not leak across worktrees"

# new must make the contracts dir self-ignoring: rollout repos do not
# globally ignore docs/superpowers/, so a bare `git add -A` there would
# commit contract notes.
(cd "$WT" && "$CONTRACT" new second >/dev/null)
assert_eq "*" "$(cat "$WT/docs/contracts/.gitignore" 2>/dev/null)" "new writes a self-ignoring contracts/.gitignore"
if git -C "$WT" check-ignore -q docs/contracts/second.md; then
  pass "the note is gitignored in the worktree"
else
  fail "the note is gitignored in the worktree (git check-ignore says it is NOT ignored)"
fi
(cd "$WT" && "$CONTRACT" new second-again 2>/dev/null); rc=$?
assert_eq 3 "$rc" "an existing contracts/.gitignore is left alone (new still refuses on active)"
printf 'evidence\n' >> "$WT/docs/contracts/second.md"
(cd "$WT" && "$CONTRACT" close >/dev/null)

# A contract can be walked away from: abandon archives the note with an
# ABANDONED marker, clears ACTIVE, and re-arms the gate — a never-closed
# contract must not leave the worktree ungated forever.
(cd "$WT" && "$CONTRACT" new dead-end >/dev/null)
(cd "$WT" && "$CONTRACT" abandon "wrong direction" >/dev/null); rc=$?
assert_eq 0 "$rc" "abandon succeeds on an active contract"
assert_contains "$(cd "$WT" && "$CONTRACT" status)" "active=none" "abandon clears the active slug"
assert_file "$WT/docs/contracts/closed/dead-end.md" "abandoned note is archived"
assert_contains "$(cat "$WT/docs/contracts/closed/dead-end.md")" "ABANDONED" \
  "the archived note carries the ABANDONED marker"
assert_contains "$(cat "$COMMON/contract-abandons.log" 2>/dev/null)" "dead-end" "the abandon is logged"
out=$(cd "$WT" && "$CONTRACT" abandon 2>&1); rc=$?
assert_eq 2 "$rc" "abandon refuses when nothing is active"

# A hand-deleted note must read as NO active contract (fail safe, gate
# re-armed), not as a phantom slug that disables the gate and breaks close.
(cd "$WT" && "$CONTRACT" new vanishing >/dev/null)
rm "$WT/docs/contracts/vanishing.md"
assert_contains "$(cd "$WT" && "$CONTRACT" status)" "active=none" "a deleted note reads as no active contract"
(cd "$WT" && "$CONTRACT" show); rc=$?
assert_eq 0 "$rc" "show does not error on a deleted note"
(cd "$WT" && "$CONTRACT" new recovered >/dev/null); rc=$?
assert_eq 0 "$rc" "new recovers after a deleted note"
rm "$WT/docs/contracts/recovered.md"
(cd "$WT" && "$CONTRACT" abandon "note deleted by hand" >/dev/null); rc=$?
assert_eq 0 "$rc" "abandon clears state even when the note is already gone"
assert_contains "$(cd "$WT" && "$CONTRACT" status)" "active=none" "state is clean after abandoning a gone note"

# new must fail loudly when it cannot write, and leave no partial state — a
# quiet rc=0 with nothing created means status says active=none, the gate
# keeps denying, and re-running new never trips the already-active guard.
mkdir -p "$REPO/docs"
chmod a-w "$REPO/docs"
out=$(cd "$REPO" && "$CONTRACT" new blocked 2>&1); rc=$?
assert_eq 2 "$rc" "new fails loudly when the contracts dir cannot be created"
assert_not_contains "$out" "opened" "no success message on a failed new"
assert_contains "$(cd "$REPO" && "$CONTRACT" status)" "active=none" "a failed new leaves no active slug"
assert_no_file "$REPO/docs/contracts/blocked.md" "a failed new leaves no note file"
chmod u+w "$REPO/docs"

# If the note is written but ACTIVE cannot be, the orphan note must be
# removed — a note on disk with no ACTIVE would claim success while the gate
# still denies.
mkdir -p "$WT/docs/contracts/ACTIVE"
out=$(cd "$WT" && "$CONTRACT" new orphan 2>&1); rc=$?
assert_eq 2 "$rc" "new fails loudly when ACTIVE cannot be written"
assert_no_file "$WT/docs/contracts/orphan.md" "no orphan note left when ACTIVE cannot be written"
rmdir "$WT/docs/contracts/ACTIVE"

finish
