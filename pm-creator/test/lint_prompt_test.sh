#!/usr/bin/env bash
# Test harness for templates/bin/lint-prompt.
#
# Run: bash test/lint_prompt_test.sh
# Exits non-zero if any assertion fails; prints a PASS/FAIL summary.
set -u

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PM_CREATOR_DIR="$(cd "${THIS_DIR}/.." && pwd)"
LINT_PROMPT="${PM_CREATOR_DIR}/templates/bin/lint-prompt"
FIXTURES="${THIS_DIR}/fixtures"

PASS=0
FAIL=0
FAILED_NAMES=()

ok() {
  local name="$1"
  PASS=$((PASS + 1))
  printf 'ok      %s\n' "$name"
}

fail() {
  local name="$1"
  shift
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("$name")
  printf 'FAIL    %s -- %s\n' "$name" "$*"
}

assert_exit() {
  local name="$1" expected_rc="$2" file="$3"
  local out rc
  out="$("$LINT_PROMPT" "$file" 2>&1)"
  rc=$?
  if [[ "$rc" -eq "$expected_rc" ]]; then
    ok "$name"
  else
    fail "$name" "expected exit $expected_rc got $rc -- output:"$'\n'"$out"
  fi
}

assert_output_contains() {
  local name="$1" file="$2" needle="$3"
  local out
  out="$("$LINT_PROMPT" "$file" 2>&1)"
  if [[ "$out" == *"$needle"* ]]; then
    ok "$name"
  else
    fail "$name" "expected output to contain [$needle] -- output:"$'\n'"$out"
  fi
}

section_clean() {
  local f="${FIXTURES}/lint_prompt_clean.md"
  assert_exit "clean prompt: exit 0" 0 "$f"
  assert_output_contains "clean prompt: necessary-not-sufficient footer" "$f" \
    "necessary-not-sufficient"
}

section_leaky() {
  local f="${FIXTURES}/lint_prompt_leaky.md"
  assert_exit "leaky prompt: non-zero exit" 1 "$f"
  assert_output_contains "leaky prompt: flags bare I-### ticket token" "$f" \
    "internal ticket token leaked: I-005"
  assert_output_contains "leaky prompt: flags herdr tab-name shape" "$f" \
    "herdr tab-name leaked: i005-fix-retry"
  assert_output_contains "leaky prompt: flags 'the ledger' phrase" "$f" \
    "manager-context phrase leaked: \"the ledger\""
}

section_report_cite_exception() {
  local f="${FIXTURES}/lint_prompt_clean.md"
  # The clean fixture cites D-005 on a "report" line below the marker; that
  # single occurrence must be allowed, not flagged as a leaked ticket token.
  assert_exit "report/cite exception: clean fixture still exits 0" 0 "$f"
  local out
  out="$("$LINT_PROMPT" "$f" 2>&1)"
  if [[ "$out" != *"D-005"* ]]; then
    ok "report/cite exception: D-005 on report line not flagged"
  else
    fail "report/cite exception: D-005 on report line not flagged" "output:"$'\n'"$out"
  fi
}

section_secret_warn() {
  local f="${FIXTURES}/lint_prompt_secret.md"
  # Secrets are WARN-only: they must not fail the build.
  assert_exit "secret prompt: exit 0 (WARN does not fail build)" 0 "$f"
  assert_output_contains "secret prompt: warns on AWS-key-like token" "$f" \
    "WARN"
  assert_output_contains "secret prompt: warns on AWS-key-like token (specific)" "$f" \
    "AWS-key-like token"
  assert_output_contains "secret prompt: warns on token= assignment" "$f" \
    "token= assignment"
}

section_no_marker() {
  local f="${FIXTURES}/lint_prompt_no_marker.md"
  assert_exit "no-marker prompt: exit 0" 0 "$f"
  assert_output_contains "no-marker prompt: warns marker not found" "$f" \
    "no 'paste below this line' marker found"
}

# Verifier-contract regression: a prompt body carrying the declared
# verifier, approval gates, and the Completed / Verification / Remaining
# Work return structure (CONVENTIONS §8-9) must lint clean -- the contract
# phrasing itself must never trip the leak checks. Only the dispatch's own
# id may appear, as the report-back label.
section_verifier_contract_shape() {
  local f="${FIXTURES}/lint_prompt_verifier_contract.md"
  assert_exit "verifier-contract prompt: exit 0 (contract phrasing lints clean)" 0 "$f"
}

section_usage() {
  if "$LINT_PROMPT" >/dev/null 2>&1; then
    fail "usage: no args exits non-zero" "unexpectedly succeeded"
  else
    ok "usage: no args exits non-zero"
  fi
  if "$LINT_PROMPT" "${FIXTURES}/does-not-exist.md" >/dev/null 2>&1; then
    fail "usage: missing file exits non-zero" "unexpectedly succeeded"
  else
    ok "usage: missing file exits non-zero"
  fi
}

echo "== clean prompt =="
section_clean
echo "== leaky prompt =="
section_leaky
echo "== report/cite own-id exception =="
section_report_cite_exception
echo "== secret WARN =="
section_secret_warn
echo "== no marker found =="
section_no_marker
echo "== usage errors =="
section_usage
echo "== verifier-contract prompt shape lints clean =="
section_verifier_contract_shape

echo
echo "-----------------------------------------"
echo "PASS: $PASS  FAIL: $FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  echo "Failed:"
  for n in "${FAILED_NAMES[@]}"; do
    echo "  - $n"
  done
  exit 1
fi
exit 0
