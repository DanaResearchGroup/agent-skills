#!/usr/bin/env bash
# A dispatch brief must resolve every noun from its own text or the filesystem.
. "$(dirname "$0")/lib.sh"
sandbox_new

good="$SANDBOX/good.md"
cat > "$good" <<'EOF'
Fix the schema validator in /abs/path/repo/src/parser.py so it rejects a
negative `n_conformers`.

## Verifier
pytest /abs/path/repo/tests/test_parser.py -k schema  # exits 0
EOF
out=$("$CONTRACT" lint "$good" 2>&1); rc=$?
assert_eq 0 "$rc" "a self-contained brief passes"

bad_id="$SANDBOX/bad-id.md"
printf 'Continue the work from I-005.\n\n## Verifier\npytest x  # exits 0\n' > "$bad_id"
out=$("$CONTRACT" lint "$bad_id" 2>&1); rc=$?
assert_eq 1 "$rc" "a bare ticket id fails"
assert_contains "$out" "I-005" "the finding names the leaked identifier"

bad_deixis="$SANDBOX/bad-deixis.md"
printf 'Apply the fix as discussed above.\n\n## Verifier\npytest x  # exits 0\n' > "$bad_deixis"
out=$("$CONTRACT" lint "$bad_deixis" 2>&1); rc=$?
assert_eq 1 "$rc" "conversation-only deixis fails"
assert_contains "$out" "as discussed" "the finding names the offending phrase"

no_verifier="$SANDBOX/no-verifier.md"
printf 'Refactor /abs/path/repo/src/parser.py for clarity.\n' > "$no_verifier"
out=$("$CONTRACT" lint "$no_verifier" 2>&1); rc=$?
assert_eq 1 "$rc" "a brief with no Verifier section fails"
assert_contains "$out" "Verifier" "the finding names the missing section"

# Findings carry a line number so they are actionable.
assert_contains "$("$CONTRACT" lint "$bad_id" 2>&1)" ":1:" "findings carry a line number"

out=$("$CONTRACT" lint /nonexistent 2>&1); rc=$?
assert_eq 2 "$rc" "linting a missing file is a usage error, not a finding"

finish
