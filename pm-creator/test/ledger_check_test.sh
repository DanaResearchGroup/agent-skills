#!/usr/bin/env bash
# Test harness for templates/bin/ledger-check.
#
# Run: bash test/ledger_check_test.sh
# Exits non-zero if any assertion fails; prints PASS/FAIL summary.
# shellcheck disable=SC2016  # intentional: $1 refers to the nested `bash -c`'s own arg
set -u

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PM_CREATOR_DIR="$(cd "${THIS_DIR}/.." && pwd)"
LIB="${PM_CREATOR_DIR}/templates/bin/_lib.sh"
LEDGER_CHECK="${PM_CREATOR_DIR}/templates/bin/ledger-check"
FIXTURES="${THIS_DIR}/fixtures"

# shellcheck source=../templates/bin/_lib.sh
# shellcheck disable=SC1091
source "${LIB}"

PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=()

ok() {
  local name="$1"
  PASS=$((PASS + 1))
  printf 'ok %s\n' "$name"
}

fail() {
  local name="$1"
  shift
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("$name")
  printf 'FAIL %s -- %s\n' "$name" "$*"
}

# I20: a section that cannot run in this environment must be COUNTED, not
# silently returned out of -- a vanished section otherwise shrinks the
# assertion total while the suite still exits 0.
skip() {
  local name="$1"
  shift
  SKIP=$((SKIP + 1))
  printf 'skip %s -- %s\n' "$name" "$*"
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    ok "$name"
  else
    fail "$name" "expected [$expected] got [$actual]"
  fi
}

assert_true() {
  local name="$1"
  shift
  if "$@"; then
    ok "$name"
  else
    fail "$name" "command failed: $*"
  fi
}

# new_tmp_repo: sets up a fresh temp dir with .pm/ and a bin/ containing the
# frozen lib + the script under test (mirrors how it is copied into a real
# generated repo).
new_tmp_repo() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-ledger-check-test.XXXXXX")"
  mkdir -p "$d/.pm" "$d/bin"
  cp "$LIB" "$d/bin/_lib.sh"
  cp "${LIB%_lib.sh}_close_lib.sh" "$d/bin/_close_lib.sh"
  cp "$LEDGER_CHECK" "$d/bin/ledger-check"
  echo "$d"
}

# run_ledger_check <repo_dir> -- runs bin/ledger-check with cwd=<repo_dir>,
# captures stdout+exit code into globals LC_OUT / LC_RC.
run_ledger_check() {
  local repo="$1"
  LC_OUT="$(cd "$repo" && bash bin/ledger-check 2>&1)"
  LC_RC=$?
}

# ---------------------------------------------------------------------------
section_clean_log() {
  local repo
  repo="$(new_tmp_repo)"
  cp "$FIXTURES/good.events.log" "$repo/.pm/events.log"

  run_ledger_check "$repo"
  assert_eq "clean log: exit 0" "0" "$LC_RC"
  assert_true "clean log: prints OK for quarantine" \
    bash -c '[[ "$1" == *"OK: no quarantined events"* ]]' _ "$LC_OUT"
  assert_true "clean log: prints OK for roll-up" \
    bash -c '[[ "$1" == *"OK: no parent/child roll-up violations"* ]]' _ "$LC_OUT"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
section_empty_but_valid_log() {
  local repo
  repo="$(new_tmp_repo)"
  printf 'EVENT schema v=1\n' > "$repo/.pm/events.log"

  run_ledger_check "$repo"
  assert_eq "empty-but-valid log: exit 0" "0" "$LC_RC"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
section_quarantine_fails() {
  local repo
  repo="$(new_tmp_repo)"
  cp "$FIXTURES/corrupt.events.log" "$repo/.pm/events.log"

  run_ledger_check "$repo"
  assert_true "quarantine: exit non-zero" bash -c '[[ "$1" -ne 0 ]]' _ "$LC_RC"
  assert_true "quarantine: reports FAIL with quarantined count" \
    bash -c '[[ "$1" == *"FAIL: "*" quarantined event(s)"* ]]' _ "$LC_OUT"
  assert_true "quarantine: includes offending line number" \
    bash -c '[[ "$1" == *"line 5:"* ]]' _ "$LC_OUT"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# A parent VERIFIED while its child is still non-terminal (§4.4) must fail,
# even though pm_fold folds it cleanly (no quarantine).
section_rollup_violation_fails() {
  local repo
  repo="$(new_tmp_repo)"
  cat > "$repo/.pm/events.log" <<'EOF'
EVENT schema v=1
EVENT issue_state i=I-001 from=OPEN to=ACTIVE at=2026-07-23T18:00:00Z
EVENT dispatch_new d=D-001 i=I-001 at=2026-07-23T18:01:00Z
EVENT dispatch_state d=D-001 a=A-01 from=READY to=DISPATCHED lane=human at=2026-07-23T18:02:00Z tab=? prompt_sha=ab12cd34
EVENT dispatch_state d=D-001 a=A-01 from=DISPATCHED to=ACKED lane=human at=2026-07-23T18:03:00Z tab=w1.i001
EVENT result d=D-001 a=A-01 status=RETURNED result_sha=ef56ab78 at=2026-07-23T18:04:00Z
EVENT dispatch_state d=D-001 a=A-01 from=RETURNED to=VERIFIED lane=human at=2026-07-23T18:05:00Z
EVENT dispatch_new d=D-002 i=I-001 at=2026-07-23T18:06:00Z child_of=D-001
EVENT dispatch_state d=D-002 a=A-01 from=READY to=DISPATCHED lane=automation at=2026-07-23T18:07:00Z tab=w2.i001 prompt_sha=cd34ef56
EOF

  run_ledger_check "$repo"
  assert_true "roll-up: exit non-zero" bash -c '[[ "$1" -ne 0 ]]' _ "$LC_RC"
  assert_true "roll-up: reports FAIL with parent/child violation" \
    bash -c '[[ "$1" == *"FAIL: "*" parent/child roll-up violation(s)"* ]]' _ "$LC_OUT"
  assert_true "roll-up: names the offending parent D-001" \
    bash -c '[[ "$1" == *"parent D-001 is VERIFIED"*"child D-002"* ]]' _ "$LC_OUT"
  assert_true "roll-up: still exits non-zero even though quarantine is clean" \
    bash -c '[[ "$1" == *"OK: no quarantined events"* ]]' _ "$LC_OUT"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# A child FAILED while the parent is VERIFIED (the other §4.4 bullet).
section_rollup_child_failed_fails() {
  local repo
  repo="$(new_tmp_repo)"
  cat > "$repo/.pm/events.log" <<'EOF'
EVENT schema v=1
EVENT issue_state i=I-001 from=OPEN to=ACTIVE at=2026-07-23T18:00:00Z
EVENT dispatch_new d=D-001 i=I-001 at=2026-07-23T18:01:00Z
EVENT dispatch_state d=D-001 a=A-01 from=READY to=DISPATCHED lane=human at=2026-07-23T18:02:00Z tab=? prompt_sha=ab12cd34
EVENT dispatch_state d=D-001 a=A-01 from=DISPATCHED to=ACKED lane=human at=2026-07-23T18:03:00Z tab=w1.i001
EVENT result d=D-001 a=A-01 status=RETURNED result_sha=ef56ab78 at=2026-07-23T18:04:00Z
EVENT dispatch_state d=D-001 a=A-01 from=RETURNED to=VERIFIED lane=human at=2026-07-23T18:05:00Z
EVENT dispatch_new d=D-002 i=I-001 at=2026-07-23T18:06:00Z child_of=D-001
EVENT dispatch_state d=D-002 a=A-01 from=READY to=DISPATCHED lane=automation at=2026-07-23T18:07:00Z tab=w2.i001 prompt_sha=cd34ef56
EVENT dispatch_state d=D-002 a=A-01 from=DISPATCHED to=FAILED lane=automation at=2026-07-23T18:08:00Z
EOF

  run_ledger_check "$repo"
  assert_true "roll-up (child FAILED): exit non-zero" bash -c '[[ "$1" -ne 0 ]]' _ "$LC_RC"
  assert_true "roll-up (child FAILED): message calls out reopening the parent" \
    bash -c '[[ "$1" == *"child D-002 is FAILED"*"reopened to RETURNED"* ]]' _ "$LC_OUT"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# A non-terminal dispatch alone (no rollup relationship) is INFO, not a
# failure -- this is a health check, not a completeness gate.
section_non_terminal_is_info_not_failure() {
  local repo
  repo="$(new_tmp_repo)"
  cat > "$repo/.pm/events.log" <<'EOF'
EVENT schema v=1
EVENT issue_state i=I-001 from=OPEN to=ACTIVE at=2026-07-23T18:00:00Z
EVENT dispatch_new d=D-001 i=I-001 at=2026-07-23T18:01:00Z
EVENT dispatch_state d=D-001 a=A-01 from=READY to=DISPATCHED lane=human at=2026-07-23T18:02:00Z tab=? prompt_sha=ab12cd34
EOF

  run_ledger_check "$repo"
  assert_eq "non-terminal alone: exit 0" "0" "$LC_RC"
  assert_true "non-terminal alone: reported as INFO" \
    bash -c '[[ "$1" == *"INFO: "*" dispatch(es) in a non-terminal state"* ]]' _ "$LC_OUT"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# CLOSED-with-live-worktree is WARN only and never fails the exit code.
section_closed_live_worktree_warns_only() {
  if ! command -v git >/dev/null 2>&1; then
    skip "section_closed_live_worktree_warns_only" "git not available"
    return
  fi
  local gitrepo repo
  gitrepo="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-ledger-check-gitrepo.XXXXXX")"
  (
    cd "$gitrepo" || exit 1
    git init -q -b main
    git config user.email test@example.com
    git config user.name test
    touch a.txt
    git add a.txt
    git commit -qm init
    git worktree add -q -b i001-fix-thing "${gitrepo}-wt" >/dev/null
  )

  repo="$(new_tmp_repo)"
  cat > "$repo/.pm/events.log" <<'EOF'
EVENT schema v=1
EVENT issue_state i=I-001 from=OPEN to=CLOSED at=2026-07-23T18:00:00Z
EOF
  cat > "$repo/.pm/config.json" <<EOF
{"repos": {"MyRepo": {"path": "${gitrepo}", "mainline": "main"}}}
EOF

  run_ledger_check "$repo"
  assert_eq "CLOSED-live-worktree: exit 0 (WARN never fails)" "0" "$LC_RC"
  assert_true "CLOSED-live-worktree: WARN mentions the issue and repo" \
    bash -c '[[ "$1" == *"WARN: "*"CLOSED issue I-001"*"MyRepo"* ]]' _ "$LC_OUT"

  git -C "$gitrepo" worktree remove --force "${gitrepo}-wt" >/dev/null 2>&1 || true
  rm -rf "$gitrepo" "${gitrepo}-wt" "$repo"
}

# ---------------------------------------------------------------------------
echo "== ledger-check: clean log =="
section_clean_log
echo "== ledger-check: empty-but-valid log =="
section_empty_but_valid_log
echo "== ledger-check: quarantine fails =="
section_quarantine_fails
echo "== ledger-check: roll-up violation (parent VERIFIED, child non-terminal) fails =="
section_rollup_violation_fails
echo "== ledger-check: roll-up violation (child FAILED, parent VERIFIED) fails =="
section_rollup_child_failed_fails
echo "== ledger-check: non-terminal dispatch alone is INFO not failure =="
section_non_terminal_is_info_not_failure
echo "== ledger-check: CLOSED-with-live-worktree WARN only =="
section_closed_live_worktree_warns_only

echo
echo "-----------------------------------------"
echo "PASS: $PASS  FAIL: $FAIL  SKIP: $SKIP"
if [[ "$FAIL" -gt 0 ]]; then
  echo "Failed:"
  for n in "${FAILED_NAMES[@]}"; do
    echo "  - $n"
  done
  exit 1
fi
exit 0
