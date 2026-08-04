#!/usr/bin/env bash
# A skip unblocks ONE session and is recorded permanently.
. "$(dirname "$0")/lib.sh"
sandbox_new
(cd "$WT" && "$CONTRACT" enable >/dev/null)

(cd "$WT" && "$CONTRACT" skipped sess-A); rc=$?
assert_eq 1 "$rc" "no skip present before one is taken"

(cd "$WT" && "$CONTRACT" skip sess-A "typo in a comment" >/dev/null); rc=$?
assert_eq 0 "$rc" "skip succeeds"

(cd "$WT" && "$CONTRACT" skipped sess-A); rc=$?
assert_eq 0 "$rc" "the skipping session is unblocked"

# A different session must be re-armed — a skip cannot leak into later work.
(cd "$WT" && "$CONTRACT" skipped sess-B); rc=$?
assert_eq 1 "$rc" "a different session is still gated"

log=$(cat "$COMMON/contract-skips.log")
assert_contains "$log" "typo in a comment" "the reason is recorded permanently"
assert_contains "$log" "sess-A"            "the session id is recorded"

# The log is shared, so a skip taken in the worktree is reviewable from the main checkout.
(cd "$REPO" && "$CONTRACT" skipped sess-A); rc=$?
assert_eq 0 "$rc" "the skip is visible across worktrees of the same repo"

# A reason is mandatory: a silent hatch is what the design rejects.
out=$(cd "$WT" && "$CONTRACT" skip sess-C 2>&1); rc=$?
assert_eq 2 "$rc" "skip without a reason is refused"
(cd "$WT" && "$CONTRACT" skipped sess-C); rc=$?
assert_eq 1 "$rc" "a refused skip does not unblock"

# Log integrity: embedded newline and tab must not corrupt the one-record-per-line invariant.
lines_before=$(wc -l < "$COMMON/contract-skips.log")
(cd "$WT" && "$CONTRACT" skip sess-D "reason with
embedded	tabs" >/dev/null); rc=$?
assert_eq 0 "$rc" "skip with embedded newline and tab succeeds"
lines_after=$(wc -l < "$COMMON/contract-skips.log")
lines_added=$((lines_after - lines_before))
assert_eq 1 "$lines_added" "exactly one physical line added to log"
log=$(cat "$COMMON/contract-skips.log")
assert_contains "$log" "sess-D" "session id is in sanitized log line"
# Verify the whitespace is collapsed to spaces (newline and tab both become spaces)
assert_contains "$log" "reason with embedded tabs" "newline and tab collapsed to spaces"

finish
