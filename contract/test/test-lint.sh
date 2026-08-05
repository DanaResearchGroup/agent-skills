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

no_verifier="$SANDBOX/no-verifier.md"
printf 'Refactor /abs/path/repo/src/parser.py for clarity.\n' > "$no_verifier"
out=$("$CONTRACT" lint "$no_verifier" 2>&1); rc=$?
assert_eq 1 "$rc" "a brief with no Verifier section fails"
assert_contains "$out" "Verifier" "the finding names the missing section"

# Findings carry a line number so they are actionable.
assert_contains "$("$CONTRACT" lint "$bad_id" 2>&1)" ":1:" "findings carry a line number"

out=$("$CONTRACT" lint /nonexistent 2>&1); rc=$?
assert_eq 2 "$rc" "linting a missing file is a usage error, not a finding"

# Marker-awareness: a ticket id ABOVE a "paste below this line" marker is the
# dispatcher's own bookkeeping and never reaches the worker, so it is not a
# leak. Only the below-marker region is scanned for identifiers.
above="$SANDBOX/above-marker.md"
cat > "$above" <<'EOF'
Contract for I-005 / D-012 — dispatcher bookkeeping, not seen by the worker.

## Verifier
pytest /abs/path/repo/tests/test_parser.py  # exits 0

--- paste below this line ---

Fix the schema validator in /abs/path/repo/src/parser.py.
EOF
out=$("$CONTRACT" lint "$above" 2>&1); rc=$?
assert_eq 0 "$rc" "a ticket id above the paste marker is not a leak"
assert_not_contains "$out" "I-005" "no finding for identifiers above the marker"

# A ticket id BELOW the marker is a real leak: the worker sees it and cannot
# resolve it. The finding's line number points below the marker.
below="$SANDBOX/below-marker.md"
cat > "$below" <<'EOF'
Contract header.

## Verifier
pytest x  # exits 0

--- paste below this line ---

Continue the work from D-012 in /abs/path/repo/src/parser.py.
EOF
out=$("$CONTRACT" lint "$below" 2>&1); rc=$?
assert_eq 1 "$rc" "a ticket id below the paste marker is a leak"
assert_contains "$out" "D-012" "the finding names the below-marker leak"
assert_contains "$out" ":8:" "the finding points at the below-marker line"

# A Verifier declared as a bolded prose label is a definition of done just as
# much as a ## heading is — the check must accept it, not force a heading.
prose_v="$SANDBOX/prose-verifier.md"
cat > "$prose_v" <<'EOF'
Fix the schema validator in /abs/path/repo/src/parser.py.

**Verifier.** pytest /abs/path/repo/tests/test_parser.py  # exits 0
EOF
out=$("$CONTRACT" lint "$prose_v" 2>&1); rc=$?
assert_eq 0 "$rc" "a bolded prose Verifier label satisfies the check"
assert_not_contains "$out" "no Verifier" "no missing-Verifier finding for a prose label"

finish
