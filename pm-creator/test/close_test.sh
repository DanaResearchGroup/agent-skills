#!/usr/bin/env bash
# Test harness for templates/bin/close (the close-and-archive step).
#
# Run: bash test/close_test.sh
# Exits non-zero if any assertion fails; prints a PASS/FAIL summary.
#
# This harness uses the `cond && ok ... || fail ...` idiom throughout; ok/fail
# always return 0, so SC2015's "C may run when A is true" caveat cannot bite.
# shellcheck disable=SC2015
set -u

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PM_CREATOR_DIR="$(cd "${THIS_DIR}/.." && pwd)"
LIB="${PM_CREATOR_DIR}/templates/bin/_lib.sh"
CLOSE="${PM_CREATOR_DIR}/templates/bin/close"

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

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    ok "$name"
  else
    fail "$name" "expected output NOT to contain [$needle], got [$haystack]"
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

assert_zero() {
  local name="$1" rc="$2"
  if [[ "$rc" -eq 0 ]]; then
    ok "$name"
  else
    fail "$name" "expected rc 0, got $rc"
  fi
}

# ---------------------------------------------------------------------------
# fixture: a fresh generated PM repo, with the working dirs `close` needs
# (scaffold.sh makes prompts/ + reports/; messages/ + archive/ are seeded
# here so the fixture doesn't depend on scaffold.sh's current layout).
# ---------------------------------------------------------------------------

new_tmp_repo() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-close-test.XXXXXX")"
  mkdir -p "$d/.pm" "$d/prompts" "$d/messages" "$d/archive/prompts" \
    "$d/archive/messages" "$d/reports"
  printf 'EVENT schema v=1\n' > "$d/.pm/events.log"
  echo "$d"
}

log_bytes() {
  wc -c < "$1/.pm/events.log" | tr -d ' '
}

# ---------------------------------------------------------------------------
# section: happy path
# ---------------------------------------------------------------------------

section_happy_path() {
  local repo out rc log
  repo="$(new_tmp_repo)"

  PM_ROOT="$repo" "${PM_CREATOR_DIR}/templates/bin/record" issue I-001 ACTIVE >/dev/null 2>&1

  : > "$repo/prompts/I-001_foo_2026-07-24.md"
  : > "$repo/messages/I-001_go_bar_2026-07-24.md"
  : > "$repo/prompts/I-002_other_2026-07-24.md"
  : > "$repo/reports/R-001_v1_2026-07-24_x.md"

  out="$(PM_ROOT="$repo" "$CLOSE" I-001 2>&1)"
  rc=$?
  assert_zero "happy: close I-001 exits 0" "$rc"

  [[ -f "$repo/archive/prompts/I-001_foo_2026-07-24.md" ]] \
    && ok "happy: I-001 prompt archived" \
    || fail "happy: I-001 prompt archived" "not found in archive/prompts"

  [[ -f "$repo/archive/messages/I-001_go_bar_2026-07-24.md" ]] \
    && ok "happy: I-001 message archived" \
    || fail "happy: I-001 message archived" "not found in archive/messages"

  [[ -f "$repo/prompts/I-002_other_2026-07-24.md" ]] \
    && ok "happy: I-002 prompt untouched (still in prompts/)" \
    || fail "happy: I-002 prompt untouched" "missing from prompts/"

  [[ -f "$repo/reports/R-001_v1_2026-07-24_x.md" ]] \
    && ok "happy: reports/ untouched" \
    || fail "happy: reports/ untouched" "report file missing"

  log="$(cat "$repo/.pm/events.log")"
  assert_contains "happy: issue_state -> CLOSED in log" \
    "$log" "EVENT issue_state i=I-001 from=ACTIVE to=CLOSED"
  assert_contains "happy: note ref=archived:I-001 in log" \
    "$log" "ref=archived:I-001"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: id-boundary (I-001 vs I-010)
# ---------------------------------------------------------------------------

section_id_boundary() {
  local repo rc
  repo="$(new_tmp_repo)"

  PM_ROOT="$repo" "${PM_CREATOR_DIR}/templates/bin/record" issue I-001 ACTIVE >/dev/null 2>&1
  PM_ROOT="$repo" "${PM_CREATOR_DIR}/templates/bin/record" issue I-010 ACTIVE >/dev/null 2>&1

  : > "$repo/prompts/I-001_a_2026-07-24.md"
  : > "$repo/prompts/I-010_b_2026-07-24.md"

  PM_ROOT="$repo" "$CLOSE" I-001 >/dev/null 2>&1
  rc=$?
  assert_zero "boundary: close I-001 exits 0" "$rc"

  [[ -f "$repo/archive/prompts/I-001_a_2026-07-24.md" ]] \
    && ok "boundary: I-001 file moved" \
    || fail "boundary: I-001 file moved" "not archived"

  [[ -f "$repo/prompts/I-010_b_2026-07-24.md" ]] \
    && ok "boundary: I-010 file left in place" \
    || fail "boundary: I-010 file left in place" "was moved (wrong prefix match)"

  [[ -f "$repo/archive/prompts/I-010_b_2026-07-24.md" ]] \
    && fail "boundary: I-010 not archived" "I-010 file was archived by close I-001" \
    || ok "boundary: I-010 not archived"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: idempotent re-close
# ---------------------------------------------------------------------------

section_idempotent_reclose() {
  local repo rc out lines_before lines_after
  repo="$(new_tmp_repo)"

  PM_ROOT="$repo" "${PM_CREATOR_DIR}/templates/bin/record" issue I-001 ACTIVE >/dev/null 2>&1
  : > "$repo/prompts/I-001_a_2026-07-24.md"

  PM_ROOT="$repo" "$CLOSE" I-001 >/dev/null 2>&1
  lines_before="$(wc -l < "$repo/.pm/events.log" | tr -d ' ')"

  out="$(PM_ROOT="$repo" "$CLOSE" I-001 2>&1)"
  rc=$?
  assert_zero "reclose: second close exits 0" "$rc"

  lines_after="$(wc -l < "$repo/.pm/events.log" | tr -d ' ')"
  assert_eq "reclose: no new events emitted on no-op re-close" \
    "$lines_before" "$lines_after"

  [[ -f "$repo/archive/prompts/I-001_a_2026-07-24.md" ]] \
    && ok "reclose: file still archived exactly once" \
    || fail "reclose: file still archived exactly once" "missing from archive"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: --dry-run
# ---------------------------------------------------------------------------

section_dry_run() {
  local repo out rc bytes_before bytes_after
  repo="$(new_tmp_repo)"

  PM_ROOT="$repo" "${PM_CREATOR_DIR}/templates/bin/record" issue I-001 ACTIVE >/dev/null 2>&1
  : > "$repo/prompts/I-001_a_2026-07-24.md"
  : > "$repo/messages/I-001_b_2026-07-24.md"

  bytes_before="$(log_bytes "$repo")"
  out="$(PM_ROOT="$repo" "$CLOSE" I-001 --dry-run 2>&1)"
  rc=$?
  assert_zero "dry-run: exits 0" "$rc"

  assert_contains "dry-run: reports intended close" "$out" "would close I-001"
  assert_contains "dry-run: reports intended prompts archive" \
    "$out" "would archive: prompts/I-001_a_2026-07-24.md -> archive/prompts/I-001_a_2026-07-24.md"
  assert_contains "dry-run: reports intended messages archive" \
    "$out" "would archive: messages/I-001_b_2026-07-24.md -> archive/messages/I-001_b_2026-07-24.md"

  [[ -f "$repo/prompts/I-001_a_2026-07-24.md" ]] \
    && ok "dry-run: prompts file NOT moved" \
    || fail "dry-run: prompts file NOT moved" "file missing from prompts/"
  [[ -f "$repo/messages/I-001_b_2026-07-24.md" ]] \
    && ok "dry-run: messages file NOT moved" \
    || fail "dry-run: messages file NOT moved" "file missing from messages/"
  [[ -f "$repo/archive/prompts/I-001_a_2026-07-24.md" ]] \
    && fail "dry-run: nothing landed in archive/prompts" "file present in archive" \
    || ok "dry-run: nothing landed in archive/prompts"

  bytes_after="$(log_bytes "$repo")"
  assert_eq "dry-run: events.log byte-identical" "$bytes_before" "$bytes_after"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: refuses unknown issue
# ---------------------------------------------------------------------------

section_refuses_unknown() {
  local repo out rc bytes_before bytes_after
  repo="$(new_tmp_repo)"

  bytes_before="$(log_bytes "$repo")"
  out="$(PM_ROOT="$repo" "$CLOSE" I-999 2>&1)"
  rc=$?
  assert_nonzero "unknown: close on never-registered issue exits non-zero" "$rc"
  assert_not_contains "unknown: no CLOSED event emitted" "$out" "EVENT"

  bytes_after="$(log_bytes "$repo")"
  assert_eq "unknown: events.log untouched" "$bytes_before" "$bytes_after"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: usage errors
# ---------------------------------------------------------------------------

section_usage_errors() {
  local repo rc
  repo="$(new_tmp_repo)"

  PM_ROOT="$repo" "$CLOSE" >/dev/null 2>&1
  rc=$?
  assert_eq "usage: no args exits 2" "2" "$rc"

  PM_ROOT="$repo" "$CLOSE" foo >/dev/null 2>&1
  rc=$?
  assert_eq "usage: bad issue id exits 2" "2" "$rc"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------

section_happy_path
section_id_boundary
section_idempotent_reclose
section_dry_run
section_refuses_unknown
section_usage_errors

echo "-----------------------------------------"
printf 'PASS: %d  FAIL: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  printf 'Failed: %s\n' "${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
