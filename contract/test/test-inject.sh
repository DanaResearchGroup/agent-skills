#!/usr/bin/env bash
# After a compaction the model must get the active contract back verbatim.
. "$(dirname "$0")/lib.sh"
sandbox_new
INJECT="$HOOKS/contract-inject.sh"

assert_eq "" "$(cd "$WT" && bash "$INJECT" </dev/null)" "no contract means no injected context"

(cd "$WT" && "$CONTRACT" enable >/dev/null)
(cd "$WT" && "$CONTRACT" new parser-fix >/dev/null)

# Put a distinctive verifier in the note, with a real embedded tab so the
# no-raw-tab assertion below actually exercises tab-escaping.
sed -i $'s|^<A command plus.*|pytest tests/test_parser.py -k schema\t# exits 0|' \
  "$WT/docs/superpowers/contracts/parser-fix.md"

out=$(cd "$WT" && bash "$INJECT" </dev/null)
assert_contains "$out" '"hookEventName":"SessionStart"' "emits a SessionStart hook object"
assert_contains "$out" 'additionalContext'              "emits additional context"
assert_contains "$out" 'parser-fix'                     "the injected context names the active slug"
assert_contains "$out" 'test_parser.py'                 "the verifier survives into the injected context"
assert_not_contains "$out" $'\t' "the JSON payload contains no raw tab"

# Outside a git repo it must be silent, not noisy.
assert_eq "" "$(cd "$SANDBOX" && bash "$INJECT" </dev/null)" "silent outside a git repo"

# Fallback path: with python3 absent from PATH, a note containing a raw CR,
# raw tab, double quote, backslash, and a non-ASCII em-dash must still
# produce output that is either empty or strictly valid JSON — never
# malformed JSON handed to the harness.
printf 'She said "hi"\tworld\\path\r\nem\xe2\x80\x94dash\n' >> "$WT/docs/superpowers/contracts/parser-fix.md"

NOPY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/contract-nopy-XXXXXX")
# `contract show` (invoked by the hook) needs its own external tools —
# omitting any of these makes the hook exit before ever reaching the
# fallback JSON-building code, which would make this test trivially pass
# without exercising anything.
for tool in bash sed awk tr cat dirname git date mkdir tail; do
  real=$(command -v "$tool" 2>/dev/null) || continue
  # Only symlink real external binaries — a bash builtin (e.g. printf) has
  # no filesystem path and would create a broken symlink here, silently
  # breaking the hook instead of exercising the fallback under test.
  case "$real" in /*) ln -s "$real" "$NOPY_DIR/$tool" ;; esac
done
fallback_out=$(cd "$WT" && PATH="$NOPY_DIR" bash "$INJECT" </dev/null)
rm -rf "$NOPY_DIR"

if [ -z "$fallback_out" ]; then
  pass "fallback (no python3) is empty or valid JSON on hostile input"
elif printf '%s' "$fallback_out" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
  pass "fallback (no python3) is empty or valid JSON on hostile input"
else
  fail "fallback (no python3) is empty or valid JSON on hostile input (got invalid JSON: $fallback_out)"
fi

finish
