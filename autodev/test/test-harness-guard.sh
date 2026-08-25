#!/usr/bin/env bash
# Certifies the command_not_found_handle guard in lib.sh actually FAILS the
# suite -- not merely that the handler is present. A `grep -q
# command_not_found_handle` substring check would pass even if the handler
# never affected the exit code; that is exactly how the sibling private
# repo's version of this guard survived unfailable for years. So this test
# EXECUTES the real lib.sh, in a throwaway script, against both an undefined
# helper and a clean run.

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/autodev-guard-test.XXXXXX")"

# The tripped case: a test calls a helper lib.sh never defined.
cat >"$TMP/tripped.sh" <<SCRIPT
#!/usr/bin/env bash
. "$HERE/lib.sh"
this_helper_does_not_exist_anywhere
finish
SCRIPT
out=$(bash "$TMP/tripped.sh" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  _pass "guard trips: an undefined helper makes the suite exit non-zero"
else
  _fail "guard trips: an undefined helper makes the suite exit non-zero" "exited 0"
fi
assert_contains "guard trips: the failure is reported" "$out" "harness: unknown command"

# The anti-tautology control: an otherwise identical script that calls NO
# undefined helper must exit 0. Without this control, a harness that always
# fails (or a handler wired to print but not to the exit code) would also
# pass the assertion above.
cat >"$TMP/clean.sh" <<SCRIPT
#!/usr/bin/env bash
. "$HERE/lib.sh"
finish
SCRIPT
bash "$TMP/clean.sh" >/dev/null 2>&1
rc2=$?
assert_eq "control: a script with no undefined call exits 0" "$rc2" "0"

rm -rf "$TMP"

finish
