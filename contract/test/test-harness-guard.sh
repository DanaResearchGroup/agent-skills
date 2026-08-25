#!/usr/bin/env bash
# Certifies the command_not_found_handle guard in lib.sh actually FAILS the
# suite -- not merely that the handler is present. A `grep -q
# command_not_found_handle` substring check would pass even if the handler
# never affected the exit code; that is exactly how the sibling private
# repo's version of this guard survived unfailable for years. So this test
# EXECUTES the real lib.sh, in a throwaway script, against both an undefined
# helper and a clean run.
. "$(dirname "$0")/lib.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/contract-guard-test.XXXXXX")"
LIB="$(dirname "$0")/lib.sh"

# The tripped case: a test calls a helper lib.sh never defined.
cat >"$TMP/tripped.sh" <<SCRIPT
#!/usr/bin/env bash
. "$LIB"
this_helper_does_not_exist_anywhere
finish
SCRIPT
out=$(bash "$TMP/tripped.sh" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  pass "guard trips: an undefined helper makes the suite exit non-zero"
else
  fail "guard trips: an undefined helper makes the suite exit non-zero (exited 0)"
fi
assert_contains "$out" "harness: unknown command" "guard trips: the failure is reported"

# The anti-tautology control: an otherwise identical script that calls NO
# undefined helper must exit 0. Without this control, a harness that always
# fails (or a handler wired to print but not to the exit code) would also
# pass the assertion above.
cat >"$TMP/clean.sh" <<SCRIPT
#!/usr/bin/env bash
. "$LIB"
finish
SCRIPT
bash "$TMP/clean.sh" >/dev/null 2>&1
rc2=$?
assert_eq 0 "$rc2" "control: a script with no undefined call exits 0"

rm -rf "$TMP"

finish
