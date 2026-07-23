#!/usr/bin/env bash
# Adversarial + concurrency test harness for the transactional _lib.sh API
# (pm_apply / pm_apply_batch / pm_fold quarantine / pm_raw_append).
# pm_raw_append itself does NOT ship in _lib.sh — it is sourced here from
# test/_seed.sh, the TEST-ONLY fixture seeder.
#
# Every adversarial case here asserts TWO things about the SAME illegal
# event:
#   1. pm_apply REFUSES it: non-zero exit, and the events.log line-count is
#      UNCHANGED (nothing was appended).
#   2. The identical raw line, injected via pm_raw_append (the TEST-ONLY
#      grammar-only bypass, from test/_seed.sh), is QUARANTINED by pm_fold
#      rather than silently folded into state or silently dropped.
#
# Run: bash test/enforce_test.sh
# Exits non-zero if any assertion fails; prints a PASS/FAIL summary.
# shellcheck disable=SC2016  # intentional: $1/$2 refer to the nested `bash -c`'s own args
set -u

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PM_CREATOR_DIR="$(cd "${THIS_DIR}/.." && pwd)"
LIB="${PM_CREATOR_DIR}/templates/bin/_lib.sh"
RECORD="${PM_CREATOR_DIR}/templates/bin/record"

# shellcheck source=../templates/bin/_lib.sh
# shellcheck disable=SC1091
source "${LIB}"
# shellcheck source=./_seed.sh
# shellcheck disable=SC1091
source "${THIS_DIR}/_seed.sh"

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

assert_true() {
  local name="$1"
  shift
  if "$@"; then
    ok "$name"
  else
    fail "$name" "command unexpectedly failed: $*"
  fi
}

assert_false() {
  local name="$1"
  shift
  if "$@"; then
    fail "$name" "command unexpectedly succeeded: $*"
  else
    ok "$name"
  fi
}

new_tmp_repo() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-enforce-test.XXXXXX")"
  mkdir -p "$d/.pm"
  echo "$d"
}

line_count() {
  # count of EVENT lines (excludes the schema header) in a repo's log.
  grep -c '^EVENT ' "$1/.pm/events.log" 2>/dev/null || echo 0
}

# assert_refused_and_quarantined <name-prefix> <repo> <raw-line-for-pm_raw_append...>
# Given a repo already primed to the point where <raw-line> (an already
# malformed/illegal `pm_apply`-style event, expressed as `<type> k=v k=v...`)
# would be refused by pm_apply, this:
#   - runs pm_apply with those exact args, asserts refusal + line-count
#     unchanged
#   - pm_raw_append's the SAME event into a throwaway copy of the repo,
#     pm_fold's it, and asserts the line landed in quarantine.log (not
#     silently folded/dropped).
assert_refused_and_quarantined() {
  local name="$1" repo="$2"
  shift 2

  local before after
  before="$(line_count "$repo")"
  assert_false "$name: pm_apply refuses" \
    bash -c 'PM_ROOT="$1"; shift; source "$1"; shift; pm_apply "$@" >/dev/null 2>&1' \
    _ "$repo" "$LIB" "$@"
  after="$(line_count "$repo")"
  assert_eq "$name: log line-count unchanged" "$before" "$after"

  local qrepo
  qrepo="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-enforce-quarantine-test.XXXXXX")"
  cp -r "$repo/.pm" "$qrepo/.pm"
  rm -f "$qrepo/.pm/index.json" "$qrepo/.pm/quarantine.log"
  local qc
  local before_q
  before_q="$(line_count "$qrepo")"
  ( PM_ROOT="$qrepo" pm_raw_append "$@" >/dev/null 2>&1 )
  pm_fold "$qrepo" >/dev/null 2>&1
  local after_q
  after_q="$(line_count "$qrepo")"
  assert_eq "$name: raw_append actually appended a new line" "$((before_q + 1))" "$after_q"
  qc="$(python3 -c "import json;print(len(json.load(open('$qrepo/.pm/index.json'))['quarantined']))" 2>/dev/null || echo 0)"
  assert_true "$name: raw-appended line is quarantined by pm_fold" \
    bash -c '[[ "$1" -gt 0 ]]' _ "$qc"

  rm -rf "$qrepo"
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---------------------------------------------------------------------------
section_illegal_edge_ready_to_verified() {
  local repo
  repo="$(new_tmp_repo)"
  PM_ROOT="$repo" pm_apply dispatch_new d=D-101 i=I-001 at="$(now_iso)" >/dev/null

  assert_refused_and_quarantined "illegal edge READY->VERIFIED" "$repo" \
    dispatch_state d=D-101 from=READY to=VERIFIED lane=human at="$(now_iso)"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
section_duplicate_dispatch_new() {
  local repo
  repo="$(new_tmp_repo)"
  PM_ROOT="$repo" pm_apply dispatch_new d=D-102 i=I-001 at="$(now_iso)" >/dev/null

  assert_refused_and_quarantined "duplicate dispatch_new" "$repo" \
    dispatch_new d=D-102 i=I-001 at="$(now_iso)"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
section_backward_reused_attempt() {
  local repo
  repo="$(new_tmp_repo)"
  PM_ROOT="$repo" pm_apply dispatch_new d=D-103 i=I-001 at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-103 from=READY to=DISPATCHED lane=human at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-103 from=DISPATCHED to=FAILED lane=human at="$(now_iso)" >/dev/null

  # retry mints A-02; a caller supplying the stale/reused a=A-01 must be refused.
  assert_refused_and_quarantined "backward/reused attempt (stale a=A-01 on remint)" "$repo" \
    dispatch_state d=D-103 a=A-01 from=FAILED to=DISPATCHED lane=human at="$(now_iso)"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
section_wrong_lane_later_transition() {
  local repo
  repo="$(new_tmp_repo)"
  PM_ROOT="$repo" pm_apply dispatch_new d=D-104 i=I-001 at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-104 from=READY to=DISPATCHED lane=human at="$(now_iso)" >/dev/null

  assert_refused_and_quarantined "wrong lane on later transition (human -> automation)" "$repo" \
    dispatch_state d=D-104 a=A-01 from=DISPATCHED to=ACKED lane=automation at="$(now_iso)"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
section_result_mismatched_attempt() {
  local repo
  repo="$(new_tmp_repo)"
  PM_ROOT="$repo" pm_apply dispatch_new d=D-105 i=I-001 at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-105 from=READY to=DISPATCHED lane=human at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-105 a=A-01 from=DISPATCHED to=ACKED lane=human at="$(now_iso)" >/dev/null

  assert_refused_and_quarantined "result with mismatched attempt" "$repo" \
    result d=D-105 a=A-99 status=RETURNED result_sha=deadbeef at="$(now_iso)"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
section_result_not_from_acked() {
  local repo
  repo="$(new_tmp_repo)"
  PM_ROOT="$repo" pm_apply dispatch_new d=D-106 i=I-001 at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-106 from=READY to=DISPATCHED lane=human at="$(now_iso)" >/dev/null
  # still DISPATCHED, never ACKED.

  assert_refused_and_quarantined "result not-from-ACKED (still DISPATCHED)" "$repo" \
    result d=D-106 a=A-01 status=RETURNED result_sha=deadbeef at="$(now_iso)"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
section_transition_out_of_terminal() {
  local repo
  repo="$(new_tmp_repo)"
  PM_ROOT="$repo" pm_apply dispatch_new d=D-107 i=I-001 at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-107 from=READY to=DISPATCHED lane=human at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-107 a=A-01 from=DISPATCHED to=ACKED lane=human at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply result d=D-107 a=A-01 status=RETURNED result_sha=deadbeef at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-107 a=A-01 from=RETURNED to=VERIFIED lane=human at="$(now_iso)" >/dev/null
  # D-107 is now VERIFIED (terminal).

  assert_refused_and_quarantined "transition out of terminal (VERIFIED -> ACKED)" "$repo" \
    dispatch_state d=D-107 a=A-01 from=VERIFIED to=ACKED lane=human at="$(now_iso)"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
section_result_on_superseded() {
  local repo
  repo="$(new_tmp_repo)"
  PM_ROOT="$repo" pm_apply dispatch_new d=D-108 i=I-001 at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-108 from=READY to=DISPATCHED lane=human at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-108 a=A-01 from=DISPATCHED to=ACKED lane=human at="$(now_iso)" >/dev/null
  # a fresh dispatch supersedes D-108 (marks it superseded=true).
  PM_ROOT="$repo" pm_apply dispatch_new d=D-109 i=I-001 at="$(now_iso)" supersedes=D-108 >/dev/null

  assert_refused_and_quarantined "result on superseded dispatch" "$repo" \
    result d=D-108 a=A-01 status=RETURNED result_sha=deadbeef at="$(now_iso)"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# C1: a `result` with a non-RETURNED status must be held to the exact same
# ACKED/attempt preconditions as a RETURNED result — no bypass for FAIL/PASS/
# etc.
section_result_fail_not_acked() {
  local repo
  repo="$(new_tmp_repo)"
  PM_ROOT="$repo" pm_apply dispatch_new d=D-111 i=I-001 at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-111 from=READY to=DISPATCHED lane=human at="$(now_iso)" >/dev/null
  # still DISPATCHED, never ACKED.

  assert_refused_and_quarantined "result status=FAIL not-from-ACKED" "$repo" \
    result d=D-111 a=A-01 status=FAIL result_sha=deadbeef at="$(now_iso)"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
section_result_fail_mismatched_attempt() {
  local repo
  repo="$(new_tmp_repo)"
  PM_ROOT="$repo" pm_apply dispatch_new d=D-112 i=I-001 at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-112 from=READY to=DISPATCHED lane=human at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-112 a=A-01 from=DISPATCHED to=ACKED lane=human at="$(now_iso)" >/dev/null

  assert_refused_and_quarantined "result status=FAIL mismatched attempt" "$repo" \
    result d=D-112 a=A-99 status=FAIL result_sha=deadbeef at="$(now_iso)"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# C2: a second RETURNED result for the same d/a must be quarantined as a
# duplicate (both the original and the duplicate line show up in
# quarantine.log, and the dispatch itself ends QUARANTINED), not silently
# refused on the generic "must be ACKED" precondition while D stays
# RETURNED from the first result.
section_duplicate_returned_result_quarantined() {
  local repo
  repo="$(new_tmp_repo)"
  PM_ROOT="$repo" pm_apply dispatch_new d=D-113 i=I-001 at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-113 from=READY to=DISPATCHED lane=human at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-113 a=A-01 from=DISPATCHED to=ACKED lane=human at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply result d=D-113 a=A-01 status=RETURNED result_sha=aaaa1111 at="$(now_iso)" >/dev/null

  # pm_apply must refuse the second RETURNED result outright (nothing new
  # committed to the transactional write path).
  local before after
  before="$(line_count "$repo")"
  assert_false "duplicate RETURNED result: pm_apply refuses" \
    bash -c 'PM_ROOT="$1"; shift; source "$1"; shift; pm_apply "$@" >/dev/null 2>&1' \
    _ "$repo" "$LIB" result d=D-113 a=A-01 status=RETURNED result_sha=bbbb2222 at="$(now_iso)"
  after="$(line_count "$repo")"
  assert_eq "duplicate RETURNED result: log line-count unchanged" "$before" "$after"

  # Raw-append the duplicate directly (bypassing pm_apply) and fold: both
  # the first and the duplicate line must be quarantined, and D-113 itself
  # must end QUARANTINED.
  PM_ROOT="$repo" pm_raw_append result d=D-113 a=A-01 status=RETURNED result_sha=bbbb2222 at="$(now_iso)" >/dev/null 2>&1
  PM_ROOT="$repo" pm_fold "$repo" >/dev/null 2>&1
  local qc d113_state
  qc="$(python3 -c "import json;print(len(json.load(open('$repo/.pm/index.json'))['quarantined']))" 2>/dev/null || echo 0)"
  d113_state="$(python3 -c "import json;print(json.load(open('$repo/.pm/index.json'))['dispatches']['D-113']['state'])" 2>/dev/null || echo '?')"
  assert_true "duplicate RETURNED result: at least 2 lines quarantined (original + duplicate)" \
    bash -c '[[ "$1" -ge 2 ]]' _ "$qc"
  assert_eq "duplicate RETURNED result: D-113 ends QUARANTINED" "QUARANTINED" "$d113_state"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# H2: issue_state to= must be whitelisted against the issue-state set.
section_issue_state_illegal_value() {
  local repo
  repo="$(new_tmp_repo)"
  # Prime events.log with a real event first: assert_refused_and_quarantined
  # expects pm_raw_append to add exactly one line to the copied qrepo, but on
  # a truly-empty repo pm_raw_append also auto-prepends the `EVENT schema
  # v=1` line (2 lines total), throwing off that count. Every other section
  # already has a prior dispatch_new by this point in its flow; do the same
  # here with an unrelated dispatch so the schema line already exists.
  PM_ROOT="$repo" pm_apply dispatch_new d=D-998 i=I-001 at="$(now_iso)" >/dev/null

  # pm_raw_append (test/_seed.sh) is grammar-only and does not auto-derive
  # `from` the way apply_event does, so it must be supplied explicitly here
  # even though a real `pm_apply` caller could omit it.
  assert_refused_and_quarantined "issue_state to=PWNED refused" "$repo" \
    issue_state i=I-999 from=OPEN to=PWNED at="$(now_iso)"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# H1: no derived field may ever serialize as a literal `None` into the log
# or into index.json, across a full happy-path lifecycle.
section_no_none_ever_serialized() {
  local repo
  repo="$(new_tmp_repo)"
  PM_ROOT="$repo" pm_apply dispatch_new d=D-114 i=I-001 at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-114 from=READY to=DISPATCHED lane=human at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-114 a=A-01 from=DISPATCHED to=ACKED lane=human at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply result d=D-114 a=A-01 status=RETURNED result_sha=deadbeef at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_fold "$repo" >/dev/null 2>&1

  # NOTE: `grep -c PATTERN FILE 2>/dev/null || echo 0` is broken when grep
  # legitimately finds zero matches in an existing file: grep -c prints "0"
  # but still exits 1 (no lines selected), so the `|| echo 0` fallback ALSO
  # fires, doubling the captured output to "0\n0". Use plain `||` assignment
  # instead (only overwrites on a real error, doesn't concatenate).
  local none_in_log none_in_index
  none_in_log="$(grep -c '=None\b' "$repo/.pm/events.log" 2>/dev/null)" || none_in_log=0
  none_in_index="$(grep -c '"None"' "$repo/.pm/index.json" 2>/dev/null)" || none_in_index=0
  assert_eq "no literal =None ever appended to events.log" "0" "$none_in_log"
  assert_eq "no literal \"None\" string ever written to index.json" "0" "$none_in_index"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# H3: `dispatch_new D-2 supersedes=D-1` folded BEFORE D-1's own dispatch_new
# must still mark D-1 superseded (order-independent), and a late result on
# D-1 must then quarantine.
section_supersede_forward_reference() {
  local repo
  repo="$(new_tmp_repo)"
  # D-116 supersedes D-115 BEFORE D-115 itself is registered.
  PM_ROOT="$repo" pm_raw_append dispatch_new d=D-116 i=I-001 supersedes=D-115 at="$(now_iso)" >/dev/null 2>&1
  PM_ROOT="$repo" pm_raw_append dispatch_new d=D-115 i=I-001 at="$(now_iso)" >/dev/null 2>&1
  PM_ROOT="$repo" pm_raw_append dispatch_state d=D-115 a=A-01 from=READY to=DISPATCHED lane=human at="$(now_iso)" >/dev/null 2>&1
  PM_ROOT="$repo" pm_raw_append dispatch_state d=D-115 a=A-01 from=DISPATCHED to=ACKED lane=human at="$(now_iso)" >/dev/null 2>&1
  PM_ROOT="$repo" pm_fold "$repo" >/dev/null 2>&1

  local d115_superseded
  d115_superseded="$(python3 -c "import json;print(json.load(open('$repo/.pm/index.json'))['dispatches']['D-115'].get('superseded'))" 2>/dev/null || echo '?')"
  assert_eq "forward-ref supersede: D-115 is marked superseded" "True" "$d115_superseded"

  # A late result on D-115 (now superseded) must be refused at write and
  # quarantined at fold, same as any other superseded-dispatch result.
  assert_refused_and_quarantined "forward-ref supersede: late result on D-115 quarantined" "$repo" \
    result d=D-115 a=A-01 status=RETURNED result_sha=deadbeef at="$(now_iso)"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# L2: a stale lock (owner PID provably dead) must be reclaimed rather than
# hanging until timeout.
section_stale_lock_reclaimed() {
  local repo lockdir
  repo="$(new_tmp_repo)"
  lockdir="$repo/.pm/.lock"
  mkdir -p "$lockdir"

  # Fabricate an owner PID that is definitely dead: `( : )` run in the
  # foreground never sets $!, so actually background a short-lived process,
  # kill it, and wait on it so its PID is guaranteed dead and reaped.
  ( sleep 60 ) &
  local dead_pid=$!
  kill "$dead_pid" 2>/dev/null || true
  wait "$dead_pid" 2>/dev/null || true
  printf '%s\n' "$dead_pid" > "$lockdir/pid"

  assert_true "stale lock: pm_lock reclaims a dead-owner lock instead of hanging" \
    bash -c '
      source "$1"
      pm_lock "$2"
    ' _ "$LIB" "$repo"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# `record dispatch <D> RETURNED` must always be refused, pointing at
# `record result` — this is a caller-facing UX guard in `record` itself, on
# top of (and in addition to) pm_apply's own to=RETURNED refusal.
section_record_dispatch_returned_refused() {
  local repo out rc
  repo="$(new_tmp_repo)"
  PM_ROOT="$repo" pm_apply dispatch_new d=D-110 i=I-001 at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-110 from=READY to=DISPATCHED lane=human at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-110 a=A-01 from=DISPATCHED to=ACKED lane=human at="$(now_iso)" >/dev/null

  local before after
  before="$(line_count "$repo")"
  out="$(PM_ROOT="$repo" "$RECORD" dispatch D-110 RETURNED 2>&1)"
  rc=$?
  after="$(line_count "$repo")"

  assert_true "record dispatch RETURNED: refuses (non-zero exit)" \
    bash -c '[[ "$1" -ne 0 ]]' _ "$rc"
  assert_eq "record dispatch RETURNED: log line-count unchanged" "$before" "$after"
  assert_true "record dispatch RETURNED: message points to record result" \
    bash -c '[[ "$1" == *"record result"* ]]' _ "$out"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# Concurrency: two parallel pm_apply attempts race to create+dispatch the
# SAME brand-new dispatch id. pm_lock (mkdir-based) serializes them; the
# loser must see the dispatch already registered and be refused (or refused
# on the dispatch_state half if it lost only the second race) — either way
# exactly one dispatch_new and exactly one minted A-01 must land in the log.
section_concurrent_same_new_dispatch() {
  local repo
  repo="$(new_tmp_repo)"

  local out1 out2
  out1="$(mktemp "${TMPDIR:-/tmp}/pm-creator-enforce-concurrency.XXXXXX")"
  out2="$(mktemp "${TMPDIR:-/tmp}/pm-creator-enforce-concurrency.XXXXXX")"

  (
    PM_ROOT="$repo" pm_apply_batch \
      -- dispatch_new d=D-999 i=I-001 at="$(now_iso)" \
      -- dispatch_state d=D-999 from=READY to=DISPATCHED lane=human at="$(now_iso)" \
      >"$out1" 2>&1
  ) &
  local pid1=$!

  (
    PM_ROOT="$repo" pm_apply_batch \
      -- dispatch_new d=D-999 i=I-001 at="$(now_iso)" \
      -- dispatch_state d=D-999 from=READY to=DISPATCHED lane=human at="$(now_iso)" \
      >"$out2" 2>&1
  ) &
  local pid2=$!

  wait "$pid1"
  local rc1=$?
  wait "$pid2"
  local rc2=$?

  assert_true "concurrent dispatch: exactly one of the two racers succeeds" \
    bash -c '[[ ("$1" -eq 0 && "$2" -ne 0) || ("$1" -ne 0 && "$2" -eq 0) ]]' _ "$rc1" "$rc2"

  local dn_count a01_count
  dn_count="$(grep -c '^EVENT dispatch_new d=D-999 ' "$repo/.pm/events.log")"
  a01_count="$(grep -c '^EVENT dispatch_state d=D-999 a=A-01 ' "$repo/.pm/events.log")"

  assert_eq "concurrent dispatch: exactly one dispatch_new for D-999" "1" "$dn_count"
  assert_eq "concurrent dispatch: exactly one A-01 dispatch_state for D-999" "1" "$a01_count"

  rm -f "$out1" "$out2"
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# H1: READY -> FAILED must be refused as an illegal edge (not silently
# accepted with a derived a=None) at write, and the same raw line must
# quarantine at fold -- write and fold must agree.
section_h1_ready_to_failed_illegal_edge() {
  local repo
  repo="$(new_tmp_repo)"
  PM_ROOT="$repo" pm_apply dispatch_new d=D-120 i=I-001 at="$(now_iso)" >/dev/null

  assert_refused_and_quarantined "H1: READY->FAILED illegal edge (no attempt minted)" "$repo" \
    dispatch_state d=D-120 from=READY to=FAILED lane=human at="$(now_iso)"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# H1 (sibling): READY -> ABANDONED / READY -> QUARANTINED remain legal and
# must now succeed cleanly -- the dispatch has no attempt yet, so the
# rendered line must OMIT `a` entirely rather than derive a literal None.
section_h1_ready_to_abandoned_omits_attempt() {
  local repo
  repo="$(new_tmp_repo)"
  PM_ROOT="$repo" pm_apply dispatch_new d=D-121 i=I-001 at="$(now_iso)" >/dev/null

  assert_true "H1: READY->ABANDONED (never dispatched) is accepted" \
    bash -c 'PM_ROOT="$1"; shift; source "$1"; shift; pm_apply "$@" >/dev/null 2>&1' \
    _ "$repo" "$LIB" dispatch_state d=D-121 from=READY to=ABANDONED lane=human at="$(now_iso)"

  local rendered_line
  rendered_line="$(grep '^EVENT dispatch_state d=D-121 ' "$repo/.pm/events.log")"
  assert_false "H1: rendered READY->ABANDONED line has no a= key at all" \
    bash -c 'printf "%s" "$1" | grep -Eq "(^| )a=[^ ]*"' _ "$rendered_line"

  PM_ROOT="$repo" pm_fold "$repo" >/dev/null 2>&1
  local none_in_log none_in_index
  none_in_log="$(grep -c '=None\b' "$repo/.pm/events.log" 2>/dev/null)" || none_in_log=0
  none_in_index="$(grep -c '"None"' "$repo/.pm/index.json" 2>/dev/null)" || none_in_index=0
  assert_eq "H1: no literal =None appended for READY->ABANDONED" "0" "$none_in_log"
  assert_eq "H1: no literal \"None\" in index.json for READY->ABANDONED" "0" "$none_in_index"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# C2: a duplicate result arriving AFTER the dispatch has already reached a
# true terminal state (VERIFIED) must still be classified as a duplicate
# (re-flagging the original), not as "late result after terminal".
section_duplicate_result_after_terminal() {
  local repo
  repo="$(new_tmp_repo)"
  PM_ROOT="$repo" pm_apply dispatch_new d=D-122 i=I-001 at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-122 from=READY to=DISPATCHED lane=human at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-122 a=A-01 from=DISPATCHED to=ACKED lane=human at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply result d=D-122 a=A-01 status=RETURNED result_sha=aaaa3333 at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-122 a=A-01 from=RETURNED to=VERIFIED lane=human at="$(now_iso)" >/dev/null
  # D-122 is now VERIFIED (terminal) -- a real result was already committed.

  # A duplicate result for the same d/a, appended raw (simulating a
  # delayed/replayed duplicate arriving after the terminal transition was
  # already folded), must still be classified as a duplicate.
  PM_ROOT="$repo" pm_raw_append result d=D-122 a=A-01 status=RETURNED result_sha=cccc4444 at="$(now_iso)" >/dev/null 2>&1
  PM_ROOT="$repo" pm_fold "$repo" >/dev/null 2>&1

  local reasons qc d122_state
  reasons="$(cat "$repo/.pm/quarantine.log" 2>/dev/null || true)"
  qc="$(python3 -c "import json;print(len(json.load(open('$repo/.pm/index.json'))['quarantined']))" 2>/dev/null || echo 0)"
  d122_state="$(python3 -c "import json;print(json.load(open('$repo/.pm/index.json'))['dispatches']['D-122']['state'])" 2>/dev/null || echo '?')"

  assert_true "C2: at least 2 lines quarantined (original + duplicate) after terminal" \
    bash -c '[[ "$1" -ge 2 ]]' _ "$qc"
  assert_eq "C2: D-122 ends QUARANTINED (not left VERIFIED)" "QUARANTINED" "$d122_state"
  assert_true "C2: quarantine reason classifies the pair as duplicate, not late-after-terminal" \
    bash -c '[[ "$1" == *"duplicate"* ]]' _ "$reasons"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# Medium: a late dispatch_state that gets quarantined (illegal transition out
# of a terminal state) must NOT mutate the standing dispatch's
# attempt/lane/tab -- those must be left exactly as last legitimately
# committed.
section_late_terminal_preserves_standing_state() {
  local repo
  repo="$(new_tmp_repo)"
  PM_ROOT="$repo" pm_apply dispatch_new d=D-123 i=I-001 at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-123 from=READY to=DISPATCHED lane=human at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-123 a=A-01 from=DISPATCHED to=ACKED lane=human at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply result d=D-123 a=A-01 status=RETURNED result_sha=deadfeed at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-123 a=A-01 from=RETURNED to=VERIFIED lane=human at="$(now_iso)" >/dev/null
  # D-123 is now VERIFIED with attempt=A-01, lane=human.

  local attempt_before lane_before
  attempt_before="$(python3 -c "import json;print(json.load(open('$repo/.pm/index.json'))['dispatches']['D-123']['attempt'])")"
  lane_before="$(python3 -c "import json;print(json.load(open('$repo/.pm/index.json'))['dispatches']['D-123']['lane'])")"

  # A late, illegal transition out of the terminal state, carrying a
  # DIFFERENT (bogus) lane -- if quarantine mutated fields before rejecting,
  # this bogus lane would leak into the standing dispatch.
  PM_ROOT="$repo" pm_raw_append dispatch_state d=D-123 a=A-01 from=VERIFIED to=ACKED lane=automation at="$(now_iso)" >/dev/null 2>&1
  PM_ROOT="$repo" pm_fold "$repo" >/dev/null 2>&1

  local attempt_after lane_after state_after
  attempt_after="$(python3 -c "import json;print(json.load(open('$repo/.pm/index.json'))['dispatches']['D-123']['attempt'])")"
  lane_after="$(python3 -c "import json;print(json.load(open('$repo/.pm/index.json'))['dispatches']['D-123']['lane'])")"
  state_after="$(python3 -c "import json;print(json.load(open('$repo/.pm/index.json'))['dispatches']['D-123']['state'])")"

  assert_eq "late-terminal quarantine: attempt unchanged" "$attempt_before" "$attempt_after"
  assert_eq "late-terminal quarantine: lane unchanged (not overwritten with bogus 'automation')" "$lane_before" "$lane_after"
  assert_eq "late-terminal quarantine: dispatch moves to QUARANTINED" "QUARANTINED" "$state_after"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# High: pm_apply_batch must be all-or-nothing. A batch whose second event is
# illegal must commit NOTHING -- not even the first, individually-valid
# event -- and must exit non-zero.
section_batch_atomicity_all_or_nothing() {
  local repo
  repo="$(new_tmp_repo)"
  PM_ROOT="$repo" pm_apply dispatch_new d=D-124 i=I-001 at="$(now_iso)" >/dev/null

  local before after rc
  before="$(line_count "$repo")"
  rc=0
  PM_ROOT="$repo" pm_apply_batch \
    -- dispatch_state d=D-124 from=READY to=DISPATCHED lane=human at="$(now_iso)" \
    -- dispatch_state d=D-124 a=A-01 from=DISPATCHED to=VERIFIED lane=human at="$(now_iso)" \
    >/dev/null 2>&1 || rc=$?
  after="$(line_count "$repo")"

  assert_true "batch atomicity: exit non-zero when any event in the batch is illegal" \
    bash -c '[[ "$1" -ne 0 ]]' _ "$rc"
  assert_eq "batch atomicity: events.log unchanged (nothing committed, incl. the valid first event)" \
    "$before" "$after"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# Low: a stale lock owned by a PID that is alive (reused) but whose recorded
# start-time identity no longer matches must be reclaimed, not hung until
# timeout.
section_stale_lock_reused_pid_identity_reclaimed() {
  local repo lockdir real_start
  repo="$(new_tmp_repo)"
  lockdir="$repo/.pm/.lock"
  mkdir -p "$lockdir"

  # Fabricate an owner "identity" using OUR OWN (very much alive) PID, but a
  # start-time token that cannot possibly match our own real start-time --
  # this is exactly what PID reuse looks like: the PID is alive, but it is
  # not the same process that acquired the lock.
  real_start="$(bash -c 'source "$1"; _pm_lock_pid_start "$$"' _ "$LIB" 2>/dev/null || true)"
  {
    printf '%s\n' "$$"
    printf '%s\n' "999999999"
  } > "$lockdir/pid"

  if [[ -z "$real_start" ]]; then
    # /proc not available on this platform -- the mismatch path degrades to
    # PID-liveness-only and correctly does NOT reclaim a live PID's lock.
    # Nothing to assert beyond "did not hang"; skip silently.
    rm -rf "$repo"
    return 0
  fi

  assert_true "stale lock: mismatched (reused-PID) identity is reclaimed via _pm_lock_try_reclaim_stale" \
    bash -c '
      source "$1"
      _pm_lock_try_reclaim_stale "$2"
    ' _ "$LIB" "$lockdir"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
echo "== adversarial: illegal edge READY->VERIFIED =="
section_illegal_edge_ready_to_verified
echo "== adversarial: duplicate dispatch_new =="
section_duplicate_dispatch_new
echo "== adversarial: backward/reused attempt =="
section_backward_reused_attempt
echo "== adversarial: wrong lane on later transition =="
section_wrong_lane_later_transition
echo "== adversarial: result with mismatched attempt =="
section_result_mismatched_attempt
echo "== adversarial: result not-from-ACKED =="
section_result_not_from_acked
echo "== adversarial: transition out of terminal =="
section_transition_out_of_terminal
echo "== adversarial: result on superseded dispatch =="
section_result_on_superseded
echo "== adversarial: result status=FAIL not-from-ACKED =="
section_result_fail_not_acked
echo "== adversarial: result status=FAIL mismatched attempt =="
section_result_fail_mismatched_attempt
echo "== adversarial: duplicate RETURNED result quarantined =="
section_duplicate_returned_result_quarantined
echo "== adversarial: issue_state illegal value =="
section_issue_state_illegal_value
echo "== adversarial: no literal None ever serialized =="
section_no_none_ever_serialized
echo "== adversarial: supersede forward reference =="
section_supersede_forward_reference
echo "== adversarial: stale lock reclaimed =="
section_stale_lock_reclaimed
echo "== adversarial: record dispatch RETURNED refused =="
section_record_dispatch_returned_refused
echo "== concurrency: two racers, one new dispatch =="
section_concurrent_same_new_dispatch
echo "== adversarial: H1 READY->FAILED illegal edge (write+fold parity) =="
section_h1_ready_to_failed_illegal_edge
echo "== adversarial: H1 READY->ABANDONED omits attempt (no None) =="
section_h1_ready_to_abandoned_omits_attempt
echo "== adversarial: C2 duplicate result after terminal (VERIFIED) =="
section_duplicate_result_after_terminal
echo "== adversarial: late-terminal quarantine preserves standing state =="
section_late_terminal_preserves_standing_state
echo "== adversarial: pm_apply_batch all-or-nothing atomicity =="
section_batch_atomicity_all_or_nothing
echo "== adversarial: stale lock reclaimed on reused-PID identity mismatch =="
section_stale_lock_reused_pid_identity_reclaimed

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
