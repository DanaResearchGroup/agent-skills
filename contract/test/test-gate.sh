#!/usr/bin/env bash
# The gate's decision matrix. Deny only when: git worktree AND enabled
# AND no active contract AND no session skip.
. "$(dirname "$0")/lib.sh"
sandbox_new
GATE="$HOOKS/contract-gate.sh"

hook() {  # tool file_path session_id
  printf '{"session_id":"%s","tool_name":"%s","tool_input":{"file_path":"%s"}}' "$3" "$1" "$2" \
    | bash "$GATE"
}

target="$WT/seed.txt"

# Not enabled -> allow.
assert_eq "" "$(hook Edit "$target" s1)" "an un-enabled repo is not gated"

(cd "$WT" && "$CONTRACT" enable >/dev/null)

# Enabled, no contract -> deny, and the message must be actionable.
out=$(hook Edit "$target" s1)
assert_contains "$out" '"permissionDecision":"deny"' "enabled with no contract denies Edit"
assert_contains "$out" 'contract new'  "the denial names how to open a contract"
assert_contains "$out" 'contract skip' "the denial names the escape hatch"

# The denial must hand the agent commands that actually run: the real session
# id (not a literal "<session_id>" placeholder that cmd_skip would reject) and
# the absolute CLI path (bare `contract` is not on PATH).
assert_contains "$out" 'skip s1' "the denial interpolates the real session id"
assert_not_contains "$out" '<session_id>' "the denial carries no session id placeholder"
assert_contains "$out" "$CONTRACT" "the denial names the absolute contract path"

assert_contains "$(hook Write "$target" s1)"        '"deny"' "Write is gated"
assert_contains "$(hook NotebookEdit "$target" s1)" '"deny"' "NotebookEdit is gated"

# Exploration must never be gated.
assert_eq "" "$(hook Read "$target" s1)" "Read is never gated"
assert_eq "" "$(hook Grep "$target" s1)" "Grep is never gated"
assert_eq "" "$(hook Bash "$target" s1)" "Bash is never gated"

# An empty session_id is gate-relevant state, not an infrastructure error: it
# must still deny (not be treated as a reason to fail open). Must be checked
# while still enabled with no active contract, so a deny can only come from
# correct empty-session_id handling.
out=$(printf '{"session_id":"","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$target" \
  | bash "$GATE")
assert_contains "$out" '"deny"' "an empty session_id still denies, it does not fail open"

# A file_path whose DIRECTORY component (not just its filename) contains an
# embedded quote must still resolve to the correct worktree, not a truncated
# ancestor. This is the discriminating case: the sed-only field() stops its
# capture at the raw quote byte inside the escaped \" sequence, so it yields
# "<SANDBOX>/\" (a trailing backslash, no worktree name). dirname() of that
# strips the bogus trailing component and lands on $SANDBOX itself -- which
# is not a git repo at all -- so the old code wrongly ALLOWS. The correct
# python3 parse yields the real path inside the quote-named worktree, whose
# dirname is still inside an enabled worktree with no active contract, so
# the fixed code correctly DENIES. A quote embedded only in the final
# filename segment (as opposed to a directory segment) would not discriminate:
# both implementations would still land on the same (correct) dirname.
QWT="$SANDBOX/\"qwt"
git -C "$REPO" worktree add -q "$QWT" -b quote-branch >/dev/null
(cd "$QWT" && "$CONTRACT" enable >/dev/null)
quoted_target="$QWT/seed.txt"
quoted_payload=$(python3 -c '
import json, sys
print(json.dumps({"session_id": "s4", "tool_name": "Edit", "tool_input": {"file_path": sys.argv[1]}}))
' "$quoted_target")
out=$(printf '%s' "$quoted_payload" | bash "$GATE")
assert_contains "$out" '"deny"' "a file_path with a quote in a directory segment resolves to the real worktree, not truncated to fail open"

# A NEW file in a not-yet-existing directory is the highest-value gated case
# (a fresh module). The gate must walk up to the nearest EXISTING ancestor and
# resolve git state from there, not fail open because dirname() does not exist.
out=$(hook Write "$WT/src/newmod/foo.py" sC3)
assert_contains "$out" '"deny"' "a new file in a not-yet-existing directory is still gated"
# Fail open is preserved when no existing ancestor is inside a git worktree.
assert_eq "" "$(hook Write "$SANDBOX/nodir/deep/foo.py" sC3)" "a new path outside any git repo still fails open"

# A skip unblocks that session only.
(cd "$WT" && "$CONTRACT" skip s1 "one-line typo" >/dev/null)
assert_eq "" "$(hook Edit "$target" s1)" "the skipping session may edit"
assert_contains "$(hook Edit "$target" s2)" '"deny"' "a different session is still gated"

# An active contract unblocks every session.
(cd "$WT" && "$CONTRACT" new real-work >/dev/null)
assert_eq "" "$(hook Edit "$target" s2)" "an active contract unblocks the gate"

# Fail open: paths outside any git repo, and malformed input, must allow.
assert_eq "" "$(hook Edit "$SANDBOX/loose.txt" s3)" "a path outside a git repo is not gated"
assert_eq "" "$(printf 'not json' | bash "$GATE")" "malformed hook input fails open"
assert_eq "" "$(printf '' | bash "$GATE")"         "empty hook input fails open"

finish
