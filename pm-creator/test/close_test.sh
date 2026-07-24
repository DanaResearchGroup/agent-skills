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
# shellcheck disable=SC1091,SC1090
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
# section: pm_close_issue is callable in-process under an already-held
# pm_lock without deadlocking (B2.0a). `pm_lock` is reentrant only within a
# single sourced shell process (depth counter); this simulates a future
# `bin/track` auto-close pass that already holds the lock and calls
# `pm_close_issue` in-process. Wrapped in `timeout` so a regression (e.g.
# `pm_close_issue` shelling out to `record`/`pm_apply` as a subprocess,
# which would try to acquire a brand-new lock and block forever on the one
# its own parent process holds) FAILS this test instead of hanging the
# whole suite.
# ---------------------------------------------------------------------------

section_lock_held_in_process() {
  local repo out rc log
  repo="$(new_tmp_repo)"

  PM_ROOT="$repo" "${PM_CREATOR_DIR}/templates/bin/record" issue I-002 ACTIVE >/dev/null 2>&1
  : > "$repo/prompts/I-002_foo_2026-07-24.md"
  : > "$repo/messages/I-002_bar_2026-07-24.md"

  # Acquire pm_lock (simulating track already holding it), THEN call
  # pm_close_issue in-process while still holding it -- all inside one
  # `timeout`-wrapped subprocess so a deadlock fails the test rather than
  # hanging this suite.
  # shellcheck disable=SC2016  # $1/$2/$3 refer to the nested `bash -c`'s own args
  out="$(timeout 15 bash -c '
    source "$1"
    pm_lock "$2" || exit 1
    pm_close_issue "$2" "$3"
    rc=$?
    pm_unlock
    exit "$rc"
  ' _ "$LIB" "$repo" "I-002" 2>&1)"
  rc=$?

  assert_zero "lock-held: pm_close_issue completes while caller already holds pm_lock (no deadlock)" "$rc"

  [[ -f "$repo/archive/prompts/I-002_foo_2026-07-24.md" ]] \
    && ok "lock-held: prompt archived" \
    || fail "lock-held: prompt archived" "not found in archive/prompts (out=$out)"

  [[ -f "$repo/archive/messages/I-002_bar_2026-07-24.md" ]] \
    && ok "lock-held: message archived" \
    || fail "lock-held: message archived" "not found in archive/messages (out=$out)"

  log="$(cat "$repo/.pm/events.log")"
  assert_contains "lock-held: issue_state -> CLOSED in log" \
    "$log" "EVENT issue_state i=I-002 from=ACTIVE to=CLOSED"
  assert_contains "lock-held: note ref=archived:I-002 in log" \
    "$log" "ref=archived:I-002"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: archive move failure is surfaced, not swallowed (FIX-1)
#
# Makes archive/prompts a REGULAR FILE so `mkdir -p archive/prompts` fails.
# Calls pm_close_issue from a `set +e` shell (mirroring `track`'s shape,
# which sources _lib.sh and must never be aborted by a sourced function's
# internal failure). Must: return nonzero, NOT emit a false
# `note ref=archived:<I>` (no archiving actually happened), NOT leave the
# CLOSED transition un-emitted (the transition itself is independent of the
# archive step and still lands), and leave the untouched file exactly where
# it was.
# ---------------------------------------------------------------------------

section_archive_failure_not_swallowed() {
  local repo out rc log
  repo="$(new_tmp_repo)"
  rm -rf "$repo/archive/prompts"
  : > "$repo/archive/prompts" # regular file where a dir is expected

  PM_ROOT="$repo" "${PM_CREATOR_DIR}/templates/bin/record" issue I-777 ACTIVE >/dev/null 2>&1
  : > "$repo/prompts/I-777_bad_2026-07-24.md"

  out="$(
    set +e
    # shellcheck disable=SC1091,SC1090
    source "$LIB"
    pm_close_issue "$repo" I-777
  )"
  rc=$?

  assert_nonzero "archive-failure: pm_close_issue returns nonzero when a move fails" "$rc"

  log="$(cat "$repo/.pm/events.log")"
  assert_not_contains "archive-failure: no false note ref=archived:I-777 in log" \
    "$log" "ref=archived:I-777"

  assert_contains "archive-failure: CLOSED transition landed despite archive failure" \
    "$log" "EVENT issue_state i=I-777 from=ACTIVE to=CLOSED"

  [[ -f "$repo/prompts/I-777_bad_2026-07-24.md" ]] \
    && ok "archive-failure: unarchived file left in place" \
    || fail "archive-failure: unarchived file left in place" "file missing from prompts/ (out=$out)"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: partial archive failure -- one dir writable, one blocked (FIX-A)
#
# The I-234 repro shape: prompts/ moves OK, messages/ is blocked (a regular
# file where archive/messages/ should be a dir). Must: return nonzero, emit
# NO `archived:<I>` note (the partial archive is not "done"), still land the
# CLOSED transition, and leave the successfully-moved prompts file archived
# (idempotent partial progress) while the blocked messages file stays put.
# Then, once the block is removed, a re-run (transition already landed, so
# skipped) must archive the remaining file, return 0, and emit the
# `archived:<I>` note EXACTLY ONCE total across both runs (no duplicate).
# ---------------------------------------------------------------------------

section_partial_archive_failure_no_duplicate_note() {
  local repo out rc log note_count
  repo="$(new_tmp_repo)"
  rm -rf "$repo/archive/messages"
  : > "$repo/archive/messages" # regular file where a dir is expected

  PM_ROOT="$repo" "${PM_CREATOR_DIR}/templates/bin/record" issue I-234 ACTIVE >/dev/null 2>&1
  : > "$repo/prompts/I-234_ok_2026-07-24.md"
  : > "$repo/messages/I-234_blocked_2026-07-24.md"

  out="$(
    set +e
    # shellcheck disable=SC1091,SC1090
    source "$LIB"
    pm_close_issue "$repo" I-234
  )"
  rc=$?

  assert_nonzero "partial-archive: pm_close_issue returns nonzero on partial failure" "$rc"

  log="$(cat "$repo/.pm/events.log")"
  assert_not_contains "partial-archive: no archived:I-234 note after the failing run" \
    "$log" "ref=archived:I-234"
  assert_contains "partial-archive: CLOSED transition landed despite partial failure" \
    "$log" "EVENT issue_state i=I-234 from=ACTIVE to=CLOSED"

  [[ -f "$repo/archive/prompts/I-234_ok_2026-07-24.md" ]] \
    && ok "partial-archive: the writable-dir file WAS archived" \
    || fail "partial-archive: the writable-dir file WAS archived" "missing from archive/prompts (out=$out)"
  [[ -f "$repo/messages/I-234_blocked_2026-07-24.md" ]] \
    && ok "partial-archive: the blocked-dir file left in place" \
    || fail "partial-archive: the blocked-dir file left in place" "file missing from messages/"

  # unblock archive/messages and re-run
  rm -f "$repo/archive/messages"
  mkdir -p "$repo/archive/messages"

  out="$(PM_ROOT="$repo" "$CLOSE" I-234 2>&1)"
  rc=$?
  assert_zero "partial-archive: re-run after unblocking exits 0" "$rc"

  [[ -f "$repo/archive/messages/I-234_blocked_2026-07-24.md" ]] \
    && ok "partial-archive: re-run archives the remaining file" \
    || fail "partial-archive: re-run archives the remaining file" "still missing from archive/messages (out=$out)"

  log="$(cat "$repo/.pm/events.log")"
  note_count="$(grep -c "ref=archived:I-234" <<<"$log")"
  assert_eq "partial-archive: archived:I-234 note emitted EXACTLY ONCE total (no duplicate)" \
    "1" "$note_count"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: close with NO files to archive still emits the note (FIX-B)
#
# The I-123 repro shape: an ACTIVE issue with nothing in prompts/ or
# messages/. Pre-refactor `close` semantics: the transition alone is enough
# to emit the `archived:<I>` note and the "done" outcome -- this is NOT a
# no-op, and must not silently drop the audit trail.
# ---------------------------------------------------------------------------

section_close_with_no_files_still_notes() {
  local repo out rc log
  repo="$(new_tmp_repo)"

  PM_ROOT="$repo" "${PM_CREATOR_DIR}/templates/bin/record" issue I-123 ACTIVE >/dev/null 2>&1

  out="$(PM_ROOT="$repo" "$CLOSE" I-123 2>&1)"
  rc=$?
  assert_zero "no-files: close with nothing to archive still exits 0" "$rc"

  log="$(cat "$repo/.pm/events.log")"
  assert_contains "no-files: CLOSED transition landed" \
    "$log" "EVENT issue_state i=I-123 from=ACTIVE to=CLOSED"
  assert_contains "no-files: archived:I-123 note IS emitted (not a no-op)" \
    "$log" "ref=archived:I-123"
  assert_contains "no-files: output says done, not no-op" "$out" "done"
  assert_not_contains "no-files: output does not say no-op" "$out" "no-op"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: cleanup is unconditional even when the core fails, INCLUDING
# under `set -e` (FIX-2)
#
# Uses the same "archive/prompts is a regular file" trigger as FIX-1, but
# runs it inside a `set -e` sourced shell (the exact shape `track` sources
# _lib.sh into: `set -euo pipefail`), calling pm_close_issue as a BARE
# top-level statement (NOT wrapped in `if`/`&&`/`||`). That matters: per
# bash's documented -e semantics, wrapping a call in `cmd || ...` suspends
# `-e` for that call's *entire* dynamic extent, including everything it
# calls internally -- which would make a test pass trivially regardless of
# whether pm_close_issue's own internals are exception-safe. Note also that
# pm_close_issue's own honest nonzero return is itself enough to trigger a
# bare -e caller's abort right after it returns, whether or not its
# internal cleanup ran -- so the interesting question isn't "does the
# caller survive" (it never does, by design), it's "did pm_close_issue's
# own cleanup tail run BEFORE returning control".
#
# To observe that, this acquires pm_lock itself FIRST, exactly like a
# caller that already holds the lock around a larger operation (e.g. a
# future `bin/track` auto-close pass) and calls pm_close_issue in-process.
# pm_lock only installs its own self-healing `trap ... EXIT INT TERM` on a
# first acquire, never on a reentrant one (see pm_lock() -- reentrant
# acquires just bump the depth counter). So after our own first-acquire
# call, pm_close_issue's internal pm_lock call is a plain reentrant bump
# that leaves the trap alone, and OUR trap (registered right after our own
# acquire) remains the sole active EXIT trap for the rest of the script --
# surviving even a `set -e` abort inside pm_close_issue -- letting us
# report the post-call lock depth and $PM_ROOT no matter how the process
# terminates. (A trap registered *before* pm_lock's own first acquire would
# instead get silently replaced by pm_lock's trap, since bash EXIT traps
# are process-global and unstacked, not dynamically scoped to the
# installing function -- confirmed empirically.)
# ---------------------------------------------------------------------------

section_cleanup_unconditional_on_failure() {
  local repo out
  repo="$(new_tmp_repo)"
  rm -rf "$repo/archive/prompts"
  : > "$repo/archive/prompts" # regular file where a dir is expected

  PM_ROOT="$repo" "${PM_CREATOR_DIR}/templates/bin/record" issue I-998 ACTIVE >/dev/null 2>&1
  : > "$repo/prompts/I-998_bad_2026-07-24.md"

  # shellcheck disable=SC2016  # $1/$2/$3 refer to the nested `bash -c`'s own args
  out="$(timeout 15 bash -c '
    set -e
    source "$1"
    repo="$2"
    issue="$3"
    PM_ROOT="pre-existing-sentinel"
    pm_lock "$repo"
    report_state() {
      printf "trap_ran=yes depth=%s pm_root=%s\n" "$_PM_LOCK_DEPTH" "$PM_ROOT"
    }
    trap report_state EXIT
    pm_close_issue "$repo" "$issue"
    echo "call_returned_without_abort"
  ' _ "$LIB" "$repo" "I-998" 2>&1)"

  assert_contains "cleanup: EXIT trap fires (process terminated, cleanly or via set -e abort)" \
    "$out" "trap_ran=yes"
  assert_contains "cleanup: lock depth back to caller's own held level (1) after failure" \
    "$out" "depth=1"
  assert_contains "cleanup: PM_ROOT restored to caller's prior value after failure" \
    "$out" "pm_root=pre-existing-sentinel"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: pm_lock reentrancy is root-aware (FIX-3)
#
# Holds the lock for root A, then attempts a reentrant pm_lock for a
# DIFFERENT root B in the same process. Must refuse loudly (nonzero, stderr
# message) rather than silently sharing root A's lock with root B's
# operations, and must leave root A's lock depth/ownership untouched.
# ---------------------------------------------------------------------------

section_lock_reentrancy_is_root_aware() {
  local repoA repoB out rc
  repoA="$(new_tmp_repo)"
  repoB="$(new_tmp_repo)"

  out="$(
    # shellcheck disable=SC1091,SC1090
    source "$LIB"
    pm_lock "$repoA" || exit 9
    if pm_lock "$repoB" 2>&1; then
      echo "MISTAKENLY_SUCCEEDED"
    else
      echo "REFUSED rc=$?"
    fi
    printf 'depth_after=%s lockA_present=%s\n' "$_PM_LOCK_DEPTH" \
      "$([[ -d "$repoA/.pm/.lock" ]] && echo yes || echo no)"
    pm_unlock
  )"
  rc=$?

  assert_zero "lock-cross-root: outer script completed" "$rc"
  assert_not_contains "lock-cross-root: reentrant lock for a different root refused" \
    "$out" "MISTAKENLY_SUCCEEDED"
  assert_contains "lock-cross-root: refusal message present" "$out" "REFUSED rc="
  assert_contains "lock-cross-root: root A's lock depth untouched by the refused attempt" \
    "$out" "depth_after=1"
  assert_contains "lock-cross-root: root A's lock still held after the refused attempt" \
    "$out" "lockA_present=yes"

  rm -rf "$repoA" "$repoB"
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
section_lock_held_in_process
section_archive_failure_not_swallowed
section_cleanup_unconditional_on_failure
section_lock_reentrancy_is_root_aware
section_partial_archive_failure_no_duplicate_note
section_close_with_no_files_still_notes

echo "-----------------------------------------"
printf 'PASS: %d  FAIL: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  printf 'Failed: %s\n' "${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
