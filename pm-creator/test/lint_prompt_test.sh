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

section_prefixed_secret_warn() {
  # I23: `\bpassword`/`\btoken`-style patterns never match immediately
  # after `_` (`_` is a \w char, so no boundary exists before "TOKEN" in
  # "GH_TOKEN="). This fixture covers the four named prefixed-token
  # shapes that used to slip past lint-prompt entirely.
  local f="${FIXTURES}/lint_prompt_prefixed_secret.md"
  assert_exit "prefixed secret prompt: exit 0 (WARN does not fail build)" 0 "$f"
  assert_output_contains "prefixed secret prompt: warns on GH_TOKEN=ghp_... (known prefix)" "$f" \
    "known secret-token prefix"
  assert_output_contains "prefixed secret prompt: warns on github_pat_... value" "$f" \
    "github_pat_"
  assert_output_contains "prefixed secret prompt: warns on SLACK_BOT_TOKEN=xoxb-... value" "$f" \
    "xoxb-"
  assert_output_contains "prefixed secret prompt: warns on api_key: ... (key-style, colon syntax)" "$f" \
    "key-style secret assignment"
}

assert_output_lacks() {
  local name="$1" file="$2" needle="$3"
  local out
  out="$("$LINT_PROMPT" "$file" 2>&1)"
  if [[ "$out" != *"$needle"* ]]; then
    ok "$name"
  else
    fail "$name" "expected output NOT to contain [$needle] -- output:"$'\n'"$out"
  fi
}

section_paths_are_not_secrets() {
  # The "long hex/base64 blob" pattern's char class includes `/`, so an
  # ordinary absolute path matched as one long blob and warned. That made
  # lint-prompt warn on the single thing CONVENTIONS §8 rule 4 most wants a
  # prompt to contain -- grounded absolute paths -- which trains the
  # operator to skim the output, which is how a real leak gets waved
  # through. Paths must be silent; genuine blobs must still warn.
  local f="${FIXTURES}/lint_prompt_paths_not_secrets.md"
  assert_exit "path-heavy prompt: exit 0" 0 "$f"
  assert_output_lacks "path-heavy prompt: absolute paths do NOT warn as secrets" "$f" \
    "possible secret (long hex/base64 blob): home/alon"
  assert_output_lacks "path-heavy prompt: no blob warning on any ARC path" "$f" \
    "arc/job/adapters"
  # ...and the suppressor must not have disarmed the pattern itself: a real
  # slash-free base64 blob on the same page still warns.
  assert_output_contains "path-heavy prompt: a real base64 blob still warns" "$f" \
    "possible secret (long hex/base64 blob): aGVsbG8"
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
echo "== prefixed-token secret WARN (I23) =="
section_prefixed_secret_warn
echo "== absolute paths are not secret-shaped =="
section_paths_are_not_secrets
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
