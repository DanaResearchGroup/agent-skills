#!/usr/bin/env bash
# After a compaction the model must get the active contract back verbatim.
. "$(dirname "$0")/lib.sh"
sandbox_new
INJECT="$HOOKS/contract-inject.sh"

assert_eq "" "$(cd "$WT" && bash "$INJECT" </dev/null)" "no contract means no injected context"

(cd "$WT" && "$CONTRACT" enable >/dev/null)
(cd "$WT" && "$CONTRACT" new parser-fix >/dev/null)

# Put a distinctive verifier in the note.
sed -i 's|^<A command plus.*|pytest tests/test_parser.py -k schema  # exits 0|' \
  "$WT/docs/superpowers/contracts/parser-fix.md"

out=$(cd "$WT" && bash "$INJECT" </dev/null)
assert_contains "$out" '"hookEventName":"SessionStart"' "emits a SessionStart hook object"
assert_contains "$out" 'additionalContext'              "emits additional context"
assert_contains "$out" 'parser-fix'                     "the injected context names the active slug"
assert_contains "$out" 'test_parser.py'                 "the verifier survives into the injected context"
assert_not_contains "$out" $'\n\t' "the JSON payload contains no raw tab"

# Outside a git repo it must be silent, not noisy.
assert_eq "" "$(cd "$SANDBOX" && bash "$INJECT" </dev/null)" "silent outside a git repo"

finish
