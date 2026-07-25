#!/usr/bin/env bash
# ci.sh — the single entrypoint CI uses to run every pm-creator suite.
#
# Convention: a skill that ships tests provides `test/ci.sh`, exits 0 only when
# everything passed, and needs nothing but bash + python3 + git. CI discovers
# these by path, so a new skill opts in by adding the file — no workflow edit.
#
# Run locally exactly as CI does:  bash pm-creator/test/ci.sh
set -uo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$THIS_DIR/.."

# Several suites create fixture repos with a bare `git commit`, which aborts on
# a fresh runner where no identity is configured. Set one for this process tree
# only -- never touch the developer's global config.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-pm-creator-ci}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-ci@example.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-pm-creator-ci}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-ci@example.invalid}"
# Fixture repos must not inherit a developer's hooks/templates/signing config.
export GIT_CONFIG_NOSYSTEM=1
export GIT_TEMPLATE_DIR=""

SUITES=(
  test/lib_test.sh
  test/enforce_test.sh
  test/ledger_check_test.sh
  test/record_test.sh
  test/dispatch_prep_test.sh
  test/lint_prompt_test.sh
  test/close_test.sh
  test/scaffold_test.sh
  test/reconcile_test.sh
  test/track_test.sh
  test/run-phaseA.sh
)

failed=()
for suite in "${SUITES[@]}"; do
  echo "::group::${suite}"
  if bash "$suite"; then
    echo "PASSED ${suite}"
  else
    echo "FAILED ${suite}"
    failed+=("$suite")
  fi
  echo "::endgroup::"
done

echo
echo "==============================================="
if ((${#failed[@]} == 0)); then
  echo "pm-creator: all ${#SUITES[@]} suites passed"
  exit 0
fi
echo "pm-creator: ${#failed[@]} of ${#SUITES[@]} suites FAILED"
for s in "${failed[@]}"; do echo "  - $s"; done
exit 1
