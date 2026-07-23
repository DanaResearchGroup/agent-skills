#!/usr/bin/env bash
# Test harness for templates/bin/record (the pm_apply ergonomic wrapper).
#
# Run: bash test/record_test.sh
# Exits non-zero if any assertion fails; prints a PASS/FAIL summary.
set -u

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PM_CREATOR_DIR="$(cd "${THIS_DIR}/.." && pwd)"
LIB="${PM_CREATOR_DIR}/templates/bin/_lib.sh"
RECORD="${PM_CREATOR_DIR}/templates/bin/record"

# shellcheck source=../templates/bin/_lib.sh
# shellcheck disable=SC1091
source "${LIB}"

PASS=0
FAIL=0
FAILED_NAMES=()

ok() {
  local name="$1"
  PASS=$((PASS + 1))
  printf 'ok\t%s\n' "$name"
}

fail() {
  local name="$1"
  shift
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("$name")
  printf 'FAIL\t%s -- %s\n' "$name" "$*"
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    ok "$name"
  else
    fail "$name" "expected [$expected] got [$actual]"
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$name"
  else
    fail "$name" "expected output to contain [$needle], got [$haystack]"
  fi
}

# shellcheck disable=SC2016  # $1 is intentionally expanded inside the nested bash -c, not here
assert_nonzero() {
  local name="$1" rc="$2"
  if bash -c '[[ "$1" -ne 0 ]]' _ "$rc"; then
    ok "$name"
  else
    fail "$name" "expected non-zero rc, got $rc"
  fi
}

# ---------------------------------------------------------------------------
# fixture: a fresh generated PM repo (just enough of one for `record`).
# All state lives under $TMPDIR; sentinel names only, no real herdr.
# ---------------------------------------------------------------------------

new_tmp_repo() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-record-test.XXXXXX")"
  mkdir -p "$d/.pm"
  printf 'EVENT schema v=1\n' > "$d/.pm/events.log"
  echo "$d"
}

line_count() {
  wc -l < "$1/.pm/events.log" | tr -d ' '
}

# ---------------------------------------------------------------------------
# section: record issue (auto from=OPEN, auto at=)
# ---------------------------------------------------------------------------

section_issue_first_transition() {
  local repo out rc
  repo="$(new_tmp_repo)"

  out="$(PM_ROOT="$repo" "$RECORD" issue I-001 ACTIVE 2>&1)"
  rc=$?
  assert_eq "issue: first transition exits 0" "0" "$rc"

  local log
  log="$(cat "$repo/.pm/events.log")"
  assert_contains "issue: emits from=OPEN (no prior state) to=ACTIVE" \
    "$log" "EVENT issue_state i=I-001 from=OPEN to=ACTIVE at="
  assert_contains "issue: at= looks like an ISO-8601-Z timestamp" \
    "$log" "T"

  out="$(PM_ROOT="$repo" "$RECORD" issue I-001 CLOSED --by D-009 2>&1)"
  rc=$?
  assert_eq "issue: second transition (with --by) exits 0" "0" "$rc"
  log="$(cat "$repo/.pm/events.log")"
  assert_contains "issue: derives from=ACTIVE (current folded state) automatically" \
    "$log" "EVENT issue_state i=I-001 from=ACTIVE to=CLOSED"
  assert_contains "issue: carries by=D-009" "$log" "by=D-009"

  rm -rf "$repo"
}

section_issue_refuses_noop() {
  local repo out rc lines_before lines_after
  repo="$(new_tmp_repo)"
  PM_ROOT="$repo" "$RECORD" issue I-002 ACTIVE >/dev/null 2>&1
  lines_before="$(line_count "$repo")"

  out="$(PM_ROOT="$repo" "$RECORD" issue I-002 ACTIVE 2>&1)"
  rc=$?
  assert_nonzero "issue: refuses a no-op transition (already at target state)" "$rc"
  assert_contains "issue: no-op refusal names current state" "$out" "ACTIVE"
  lines_after="$(line_count "$repo")"
  assert_eq "issue: no-op refusal emits nothing" "$lines_before" "$lines_after"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: record dispatch — the exact event for `record dispatch D-001
# VERIFIED` after a full ACKED->RETURNED round trip, plus attempt carrying.
# RETURNED is reached only via `record result` (never `record dispatch ...
# RETURNED`, which is always refused — see
# section_record_dispatch_returned_refused in test/enforce_test.sh).
# ---------------------------------------------------------------------------

section_dispatch_full_roundtrip() {
  local repo out rc
  repo="$(new_tmp_repo)"

  PM_ROOT="$repo" pm_apply dispatch_new d=D-001 i=I-001 at=2026-07-23T18:01:00Z >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-001 from=READY to=DISPATCHED lane=human at=2026-07-23T18:02:00Z tab=? prompt_sha=ab12cd34 >/dev/null

  out="$(PM_ROOT="$repo" "$RECORD" dispatch D-001 ACKED --tab zzz-tab-1 2>&1)"
  rc=$?
  assert_eq "dispatch: DISPATCHED->ACKED exits 0" "0" "$rc"
  local log
  log="$(cat "$repo/.pm/events.log")"
  assert_contains "dispatch: ACKED carries auto a=A-01 and default lane=human" \
    "$log" "EVENT dispatch_state d=D-001 a=A-01 from=DISPATCHED to=ACKED lane=human"
  assert_contains "dispatch: ACKED carries the given --tab" "$log" "tab=zzz-tab-1"

  out="$(PM_ROOT="$repo" "$RECORD" result D-001 --sha deadbeef 2>&1)"
  assert_eq "dispatch: ACKED->RETURNED (via record result) exits 0" "0" "$?"

  out="$(PM_ROOT="$repo" "$RECORD" dispatch D-001 VERIFIED 2>&1)"
  rc=$?
  assert_eq "dispatch: RETURNED->VERIFIED exits 0" "0" "$rc"
  log="$(cat "$repo/.pm/events.log")"
  assert_contains "dispatch: exact VERIFIED event carries from=RETURNED a=A-01 lane=human" \
    "$log" "EVENT dispatch_state d=D-001 a=A-01 from=RETURNED to=VERIFIED lane=human at="

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: record dispatch refuses an illegal/stale transition (DISPATCHED
# -> VERIFIED, skipping ACKED/RETURNED) without emitting anything.
# ---------------------------------------------------------------------------

section_dispatch_refuses_illegal() {
  local repo out rc lines_before lines_after
  repo="$(new_tmp_repo)"

  PM_ROOT="$repo" pm_apply dispatch_new d=D-002 i=I-001 at=2026-07-23T18:01:00Z >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-002 from=READY to=DISPATCHED lane=human at=2026-07-23T18:02:00Z tab=? prompt_sha=ab12cd34 >/dev/null
  lines_before="$(line_count "$repo")"

  out="$(PM_ROOT="$repo" "$RECORD" dispatch D-002 VERIFIED 2>&1)"
  rc=$?
  assert_nonzero "dispatch: refuses DISPATCHED -> VERIFIED (illegal, must go through ACKED/RETURNED)" "$rc"
  assert_contains "dispatch: illegal-transition message names current=DISPATCHED" "$out" "current=DISPATCHED"
  assert_contains "dispatch: illegal-transition message names requested=VERIFIED" "$out" "requested=VERIFIED"

  lines_after="$(line_count "$repo")"
  assert_eq "dispatch: illegal transition emits nothing (line-count unchanged)" \
    "$lines_before" "$lines_after"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: record result — auto attempt, default STATUS=RETURNED, required
# --sha, and the ACKED gate.
# ---------------------------------------------------------------------------

section_result() {
  local repo out rc
  repo="$(new_tmp_repo)"

  PM_ROOT="$repo" pm_apply dispatch_new d=D-003 i=I-001 at=2026-07-23T18:01:00Z >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-003 from=READY to=DISPATCHED lane=human at=2026-07-23T18:02:00Z tab=? prompt_sha=ab12cd34 >/dev/null

  out="$(PM_ROOT="$repo" "$RECORD" result D-003 --sha deadbeef 2>&1)"
  rc=$?
  assert_nonzero "result: refuses RETURNED before ACKED" "$rc"

  PM_ROOT="$repo" "$RECORD" dispatch D-003 ACKED >/dev/null 2>&1

  out="$(PM_ROOT="$repo" "$RECORD" result D-003 --sha deadbeef 2>&1)"
  rc=$?
  assert_eq "result: exits 0 once ACKED (STATUS defaults RETURNED)" "0" "$rc"
  local log
  log="$(cat "$repo/.pm/events.log")"
  assert_contains "result: emits result with auto a=A-01, status=RETURNED, given sha" \
    "$log" "EVENT result d=D-003 a=A-01 status=RETURNED result_sha=deadbeef at="

  out="$(PM_ROOT="$repo" "$RECORD" result D-003 2>&1)"
  rc=$?
  assert_nonzero "result: refuses when --sha is missing" "$rc"
  assert_contains "result: missing --sha message is friendly" "$out" "--sha"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: record question / adopt / note
# ---------------------------------------------------------------------------

section_question() {
  local repo log
  repo="$(new_tmp_repo)"

  PM_ROOT="$repo" "$RECORD" question Q-001 OPEN --issue I-001 >/dev/null 2>&1
  assert_eq "question: exits 0" "0" "$?"
  log="$(cat "$repo/.pm/events.log")"
  assert_contains "question: emits q=Q-001 state=OPEN i=I-001" \
    "$log" "EVENT question q=Q-001 state=OPEN"
  assert_contains "question: carries i=I-001" "$log" "i=I-001"

  PM_ROOT="$repo" "$RECORD" question Q-002 ANSWERED --answers Q-001 >/dev/null 2>&1
  log="$(cat "$repo/.pm/events.log")"
  assert_contains "question: carries a_of=Q-001 from --answers" "$log" "a_of=Q-001"

  rm -rf "$repo"
}

section_adopt() {
  local repo log rc
  repo="$(new_tmp_repo)"

  PM_ROOT="$repo" pm_apply dispatch_new d=D-004 i=I-001 at=2026-07-23T18:01:00Z >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-004 from=READY to=DISPATCHED lane=human at=2026-07-23T18:02:00Z tab=? prompt_sha=ab12cd34 >/dev/null

  PM_ROOT="$repo" "$RECORD" adopt D-004 --ref zzz-adopt-ref >/dev/null 2>&1
  rc=$?
  assert_eq "adopt: exits 0" "0" "$rc"
  log="$(cat "$repo/.pm/events.log")"
  assert_contains "adopt: emits d=D-004 a=A-01 ref=zzz-adopt-ref" \
    "$log" "EVENT adopt d=D-004 a=A-01 at="
  assert_contains "adopt: carries ref" "$log" "ref=zzz-adopt-ref"

  rm -rf "$repo"
}

section_note() {
  local repo log rc
  repo="$(new_tmp_repo)"

  PM_ROOT="$repo" "$RECORD" note --ref zzz-note-anchor --issue I-001 >/dev/null 2>&1
  rc=$?
  assert_eq "note: exits 0" "0" "$rc"
  log="$(cat "$repo/.pm/events.log")"
  assert_contains "note: emits at= ref=zzz-note-anchor i=I-001" \
    "$log" "EVENT note at="
  assert_contains "note: carries ref" "$log" "ref=zzz-note-anchor"
  assert_contains "note: carries i=I-001" "$log" "i=I-001"

  PM_ROOT="$repo" "$RECORD" note >/dev/null 2>&1
  assert_nonzero "note: refuses when --ref is missing" "$?"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: usage errors
# ---------------------------------------------------------------------------

section_usage_errors() {
  local rc
  "$RECORD" bogus-subcommand >/dev/null 2>&1
  rc=$?
  assert_nonzero "usage: unknown subcommand exits non-zero" "$rc"

  "$RECORD" >/dev/null 2>&1
  rc=$?
  assert_nonzero "usage: no subcommand exits non-zero" "$rc"

  "$RECORD" issue I-001 >/dev/null 2>&1
  rc=$?
  assert_nonzero "usage: record issue missing TO_STATE exits non-zero" "$rc"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------

section_issue_first_transition
section_issue_refuses_noop
section_dispatch_full_roundtrip
section_dispatch_refuses_illegal
section_result
section_question
section_adopt
section_note
section_usage_errors

echo "-----------------------------------------"
printf 'PASS: %d  FAIL: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  printf 'Failed: %s\n' "${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
