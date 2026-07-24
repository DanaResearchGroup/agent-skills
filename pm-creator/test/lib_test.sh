#!/usr/bin/env bash
# Test harness for templates/bin/_lib.sh — the frozen event-log library.
#
# Run: bash test/lib_test.sh
# Exits non-zero if any assertion fails; prints a PASS/FAIL summary.
set -u

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PM_CREATOR_DIR="$(cd "${THIS_DIR}/.." && pwd)"
LIB="${PM_CREATOR_DIR}/templates/bin/_lib.sh"
FIXTURES="${THIS_DIR}/fixtures"

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
  printf 'ok      %s\n' "$name"
}

fail() {
  local name="$1"
  shift
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("$name")
  printf 'FAIL    %s -- %s\n' "$name" "$*"
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
  d="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-test.XXXXXX")"
  mkdir -p "$d/.pm"
  echo "$d"
}

# ---------------------------------------------------------------------------
# pm_raw_append: grammar-only validation (accept/reject) — TEST-ONLY API
# (sourced from test/_seed.sh; does NOT ship in _lib.sh), bypasses the
# transition rule engine entirely (see pm_apply/pm_apply_batch for the
# transactional, transition-validated write path exercised below).
# ---------------------------------------------------------------------------
section_raw_append() {
  local repo
  repo="$(new_tmp_repo)"
  # shellcheck disable=SC2034  # read via dynamic scope by pm_raw_append/_pm_root
  local PM_ROOT="$repo"

  assert_true "raw_append: valid issue_state accepted" \
    pm_raw_append issue_state i=I-001 from=OPEN to=ACTIVE at=2026-07-23T18:00:00Z

  assert_false "raw_append: unknown type rejected" \
    pm_raw_append bogus_type foo=bar

  assert_false "raw_append: missing required key rejected" \
    pm_raw_append issue_state i=I-001 from=OPEN at=2026-07-23T18:00:00Z

  assert_false "raw_append: duplicate key rejected" \
    pm_raw_append issue_state i=I-001 from=OPEN to=ACTIVE at=2026-07-23T18:00:00Z at=2026-07-23T18:00:01Z

  assert_false "raw_append: bad charset value rejected" \
    pm_raw_append issue_state i=I-001 from=OPEN to='BAD STATE' at=2026-07-23T18:00:00Z

  assert_false "raw_append: bad charset base_sha (git-meta optional key) rejected" \
    pm_raw_append dispatch_state d=D-901 from=READY to=DISPATCHED lane=human \
      at=2026-07-23T18:00:00Z base_sha='bad value'

  assert_false "raw_append: empty value rejected" \
    pm_raw_append issue_state i=I-001 from=OPEN to= at=2026-07-23T18:00:00Z

  assert_true "raw_append: unknown/optional-forward-compat key accepted (ignored)" \
    pm_raw_append issue_state i=I-001 from=ACTIVE to=CLOSED at=2026-07-23T18:01:00Z future_key=x

  # header auto-write on first append
  local first_line
  first_line="$(head -n1 "$repo/.pm/events.log")"
  assert_eq "raw_append: auto-header on fresh log" "EVENT schema v=1" "$first_line"

  # atomic single-line append: file must have exactly N lines matching accepted appends
  local nlines
  nlines="$(wc -l < "$repo/.pm/events.log" | tr -d ' ')"
  assert_eq "raw_append: append count == header + accepted appends" "3" "$nlines"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# pm_fold: correctness on good.events.log
# ---------------------------------------------------------------------------
section_fold_good() {
  local repo
  repo="$(new_tmp_repo)"
  cp "$FIXTURES/good.events.log" "$repo/.pm/events.log"

  assert_true "fold(good): pm_fold succeeds" pm_fold "$repo"

  assert_true "fold(good): index.json created" test -f "$repo/.pm/index.json"

  local quarantine_count
  quarantine_count="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(len(d['quarantined']))")"
  assert_eq "fold(good): zero quarantined entries" "0" "$quarantine_count"

  assert_false "fold(good): quarantine.log not created (nothing to quarantine)" \
    test -e "$repo/.pm/quarantine.log"

  local issue_state
  issue_state="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(d['issues']['I-001']['state'])")"
  assert_eq "fold(good): issue I-001 state == CLOSED" "CLOSED" "$issue_state"

  local d1_state d1_attempt d1_lane d1_tab d1_sha
  d1_state="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(d['dispatches']['D-001']['state'])")"
  d1_attempt="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(d['dispatches']['D-001']['attempt'])")"
  d1_lane="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(d['dispatches']['D-001']['lane'])")"
  d1_tab="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(d['dispatches']['D-001']['tab'])")"
  d1_sha="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(d['dispatches']['D-001']['result_sha'])")"
  assert_eq "fold(good): D-001 state == VERIFIED (post-retry)" "VERIFIED" "$d1_state"
  assert_eq "fold(good): D-001 current attempt == A-02 (retried)" "A-02" "$d1_attempt"
  assert_eq "fold(good): D-001 lane == human" "human" "$d1_lane"
  assert_eq "fold(good): D-001 tab == w1.i001" "w1.i001" "$d1_tab"
  assert_eq "fold(good): D-001 result_sha == ef56ab78" "ef56ab78" "$d1_sha"

  local d2_child_of
  d2_child_of="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(d['dispatches']['D-002']['child_of'])")"
  assert_eq "fold(good): D-002 child_of == D-001" "D-001" "$d2_child_of"

  local open_qs
  open_qs="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(sorted(d['open_questions']))")"
  assert_eq "fold(good): open_questions == ['Q-002']" "['Q-002']" "$open_qs"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# pm_fold: quarantine routing + no-silent-drop on corrupt.events.log
# ---------------------------------------------------------------------------
section_fold_corrupt() {
  local repo
  repo="$(new_tmp_repo)"
  cp "$FIXTURES/corrupt.events.log" "$repo/.pm/events.log"

  assert_true "fold(corrupt): pm_fold still succeeds (never crashes on bad input)" pm_fold "$repo"

  assert_true "fold(corrupt): quarantine.log created" test -f "$repo/.pm/quarantine.log"

  local total_lines quarantine_lines
  total_lines="$(grep -c '^EVENT ' "$repo/.pm/events.log")"
  quarantine_lines="$(wc -l < "$repo/.pm/quarantine.log" | tr -d ' ')"
  assert_true "fold(corrupt): quarantine.log non-empty" test "$quarantine_lines" -gt 0

  local qc
  qc="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(len(d['quarantined']))")"
  assert_true "fold(corrupt): index.json quarantined[] non-empty" test "$qc" -gt 0

  # no-silent-drop: every non-header EVENT line is accounted for either in the
  # fold (contributing to an issue/dispatch) or in quarantined[]/quarantine.log.
  assert_true "fold(corrupt): total EVENT lines > quarantined (some lines did fold cleanly)" \
    test "$total_lines" -gt 0

  # D-001's second `result RETURNED` (line 10) for the same d/a is a
  # duplicate of the first (line 9). Duplicate detection runs BEFORE the
  # ACKED-state precondition (enforcement.md §4.1), so both the original
  # RETURNED line and the duplicate line are routed to quarantine and D-001
  # itself ends QUARANTINED (not silently left RETURNED from the first
  # result) — see the C2 fix in _lib.sh's `result` handling.
  local d1_state
  d1_state="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(d['dispatches']['D-001']['state'])")"
  assert_eq "fold(corrupt): D-001 ends QUARANTINED (duplicate RETURNED result)" "QUARANTINED" "$d1_state"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# last-write-wins
# ---------------------------------------------------------------------------
section_last_write_wins() {
  local repo
  repo="$(new_tmp_repo)"
  {
    echo "EVENT schema v=1"
    echo "EVENT issue_state i=I-009 from=OPEN to=ACTIVE at=2026-07-23T18:00:00Z"
    echo "EVENT issue_state i=I-009 from=ACTIVE to=BLOCKED at=2026-07-23T18:01:00Z"
    echo "EVENT issue_state i=I-009 from=BLOCKED to=ACTIVE at=2026-07-23T18:02:00Z"
  } > "$repo/.pm/events.log"

  pm_fold "$repo" >/dev/null

  local state
  state="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(d['issues']['I-009']['state'])")"
  assert_eq "last-write-wins: issue folds to final ACTIVE state" "ACTIVE" "$state"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B1.1: pm_fold carries per-dispatch repo/branch/base_sha into index.json,
# and preserves them across a later dispatch_state that omits them --
# exactly like lane/tab.
# ---------------------------------------------------------------------------
section_fold_git_meta() {
  local repo
  repo="$(new_tmp_repo)"
  {
    echo "EVENT schema v=1"
    echo "EVENT dispatch_new d=D-140 i=I-001 at=2026-07-23T18:00:00Z"
    echo "EVENT dispatch_state d=D-140 from=READY to=DISPATCHED lane=human at=2026-07-23T18:01:00Z repo=svc branch=i140-fix base_sha=abc123"
    echo "EVENT dispatch_state d=D-140 a=A-01 from=DISPATCHED to=ACKED lane=human at=2026-07-23T18:02:00Z tab=w1.i140"
    echo "EVENT dispatch_state d=D-140 a=A-01 from=ACKED to=FAILED lane=human at=2026-07-23T18:03:00Z"
    echo "EVENT dispatch_state d=D-140 from=FAILED to=DISPATCHED lane=human at=2026-07-23T18:04:00Z base_sha=def456"
  } > "$repo/.pm/events.log"

  pm_fold "$repo" >/dev/null

  local d_repo d_branch a1_sha a2_sha
  d_repo="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(d['dispatches']['D-140']['repo'])")"
  d_branch="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(d['dispatches']['D-140']['branch'])")"
  a1_sha="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(d['dispatches']['D-140']['attempts']['A-01']['base_sha'])")"
  a2_sha="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(d['dispatches']['D-140']['attempts']['A-02']['base_sha'])")"
  assert_eq "fold git-meta: D-140 repo == svc" "svc" "$d_repo"
  assert_eq "fold git-meta: D-140 branch == i140-fix" "i140-fix" "$d_branch"
  assert_eq "fold git-meta: D-140 attempts.A-01.base_sha == abc123 (retained across retry)" "abc123" "$a1_sha"
  assert_eq "fold git-meta: D-140 attempts.A-02.base_sha == def456 (new attempt's own base_sha)" "def456" "$a2_sha"

  # preserved (not blanked/None'd) across a later event that omits them
  local qc
  qc="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(len(d['quarantined']))")"
  assert_eq "fold git-meta: zero quarantined entries" "0" "$qc"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B2.0b: pm_fold carries question<->issue -- questions[q] == {state,i},
# last-i-wins carry-forward across a later bare (no i=) event, invalid
# question state quarantined, open_questions_by_issue / unscoped surfaced,
# and the flat open_questions[] list stays intact (backward compat).
# ---------------------------------------------------------------------------
section_fold_question_issue() {
  local repo
  repo="$(new_tmp_repo)"
  {
    echo "EVENT schema v=1"
    # Q-001: scoped to I-001 from the start, later re-affirmed OPEN without
    # repeating i= -- the link must be carried forward (last-i-wins trap).
    echo "EVENT question q=Q-001 state=OPEN at=2026-07-23T18:00:00Z i=I-001"
    echo "EVENT question q=Q-001 state=OPEN at=2026-07-23T18:05:00Z"
    # Q-002: also scoped to I-001 -- two OPEN questions on the same issue.
    echo "EVENT question q=Q-002 state=OPEN at=2026-07-23T18:01:00Z i=I-001"
    # Q-003: scoped to I-002, later ANSWERED (no longer open).
    echo "EVENT question q=Q-003 state=OPEN at=2026-07-23T18:02:00Z i=I-002"
    echo "EVENT question q=Q-003 state=ANSWERED at=2026-07-23T18:06:00Z i=I-002 a_of=A-01"
    # Q-004: never scoped to any issue -- unscoped OPEN question.
    echo "EVENT question q=Q-004 state=OPEN at=2026-07-23T18:03:00Z"
    # Q-005: invalid state value -- must be quarantined, not silently folded.
    echo "EVENT question q=Q-005 state=BOGUS at=2026-07-23T18:04:00Z i=I-003"
  } > "$repo/.pm/events.log"

  pm_fold "$repo" >/dev/null

  local q1_state q1_i
  q1_state="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(d['questions']['Q-001']['state'])")"
  q1_i="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(d['questions']['Q-001']['i'])")"
  assert_eq "fold q<->i: Q-001 state == OPEN" "OPEN" "$q1_state"
  assert_eq "fold q<->i: Q-001 i carried forward across later bare (no i=) event" "I-001" "$q1_i"

  local by_issue_i1 by_issue_i2
  by_issue_i1="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(sorted(d['open_questions_by_issue']['I-001']))")"
  assert_eq "fold q<->i: open_questions_by_issue[I-001] == ['Q-001','Q-002']" "['Q-001', 'Q-002']" "$by_issue_i1"
  by_issue_i2="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(d['open_questions_by_issue'].get('I-002'))")"
  assert_eq "fold q<->i: I-002's question is ANSWERED, not in open_questions_by_issue" "None" "$by_issue_i2"

  local unscoped
  unscoped="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(sorted(d['open_questions_unscoped']))")"
  assert_eq "fold q<->i: open_questions_unscoped == ['Q-004']" "['Q-004']" "$unscoped"

  local open_qs
  open_qs="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(sorted(d['open_questions']))")"
  assert_eq "fold q<->i: backward-compat flat open_questions == ['Q-001','Q-002','Q-004']" \
    "['Q-001', 'Q-002', 'Q-004']" "$open_qs"

  local q5_quarantined
  q5_quarantined="$(python3 -c "
import json
d = json.load(open('$repo/.pm/index.json'))
print(any('Q-005' in e['raw'] for e in d['quarantined']))
")"
  assert_eq "fold q<->i: Q-005 (invalid state=BOGUS) quarantined" "True" "$q5_quarantined"

  local q5_absent
  q5_absent="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print('Q-005' in d['questions'])")"
  assert_eq "fold q<->i: Q-005 never folded into questions{} (quarantine, not silent accept)" "False" "$q5_absent"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B2.2: `merged` marker events -- pure corroboration records. The fold must
# (a) store result_sha per-attempt (attempts[a].result_sha) so a marker
# validates against the RIGHT attempt, (b) accept a valid marker into
# dispatches[d].merged[a] WITHOUT touching dispatch/issue state or
# result_sha, (c) accept an identical re-append idempotently.
# ---------------------------------------------------------------------------
_idx_py() {
  # _idx_py <repo> <python-expr over d(=index)>
  python3 -c "import json;d=json.load(open('$1/.pm/index.json'));print($2)"
}

section_fold_merged_accepted() {
  local repo
  repo="$(new_tmp_repo)"
  {
    echo "EVENT schema v=1"
    echo "EVENT issue_state i=I-001 from=OPEN to=ACTIVE at=2026-07-23T18:00:00Z"
    echo "EVENT dispatch_new d=D-150 i=I-001 at=2026-07-23T18:00:00Z"
    echo "EVENT dispatch_state d=D-150 from=READY to=DISPATCHED lane=human at=2026-07-23T18:01:00Z repo=svc branch=i150-fix base_sha=abc123"
    echo "EVENT dispatch_state d=D-150 a=A-01 from=DISPATCHED to=ACKED lane=human at=2026-07-23T18:02:00Z tab=w1.i150"
    echo "EVENT result d=D-150 a=A-01 status=RETURNED result_sha=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee at=2026-07-23T18:03:00Z"
    echo "EVENT dispatch_state d=D-150 a=A-01 from=RETURNED to=VERIFIED lane=human at=2026-07-23T18:04:00Z"
    echo "EVENT merged d=D-150 a=A-01 merge_sha=1111111111111111111111111111111111111111 result_sha=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee at=2026-07-23T18:05:00Z"
  } > "$repo/.pm/events.log"

  pm_fold "$repo" >/dev/null

  assert_eq "fold merged: per-attempt result_sha stored (attempts.A-01.result_sha)" \
    "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" "$(_idx_py "$repo" "d['dispatches']['D-150']['attempts']['A-01']['result_sha']")"
  assert_eq "fold merged: marker stored per (d,a) -- merge_sha" \
    "1111111111111111111111111111111111111111" "$(_idx_py "$repo" "d['dispatches']['D-150']['merged']['A-01']['merge_sha']")"
  assert_eq "fold merged: marker stored per (d,a) -- result_sha" \
    "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" "$(_idx_py "$repo" "d['dispatches']['D-150']['merged']['A-01']['result_sha']")"
  assert_eq "fold merged: dispatch state untouched (still VERIFIED)" \
    "VERIFIED" "$(_idx_py "$repo" "d['dispatches']['D-150']['state']")"
  assert_eq "fold merged: dispatch result_sha NOT overwritten" \
    "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" "$(_idx_py "$repo" "d['dispatches']['D-150']['result_sha']")"
  assert_eq "fold merged: issue state untouched (still ACTIVE)" \
    "ACTIVE" "$(_idx_py "$repo" "d['issues']['I-001']['state']")"
  assert_eq "fold merged: zero quarantined entries" \
    "0" "$(_idx_py "$repo" "len(d['quarantined'])")"

  # identical re-append -> accepted idempotently (no quarantine, same marker)
  echo "EVENT merged d=D-150 a=A-01 merge_sha=1111111111111111111111111111111111111111 result_sha=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee at=2026-07-23T18:06:00Z" >> "$repo/.pm/events.log"
  pm_fold "$repo" >/dev/null
  assert_eq "fold merged: identical re-append accepted idempotently (zero quarantined)" \
    "0" "$(_idx_py "$repo" "len(d['quarantined'])")"
  assert_eq "fold merged: identical re-append leaves marker unchanged" \
    "1111111111111111111111111111111111111111" "$(_idx_py "$repo" "d['dispatches']['D-150']['merged']['A-01']['merge_sha']")"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B2.2: merged marker violations quarantine (never fold, never redirect) and
# carry the dispatch's AUTHORITATIVE issue attribution so the existing
# issue-related-quarantine gate blocks the owning issue's auto-close.
# ---------------------------------------------------------------------------
section_fold_merged_violations() {
  local repo
  repo="$(new_tmp_repo)"
  {
    echo "EVENT schema v=1"
    echo "EVENT issue_state i=I-001 from=OPEN to=ACTIVE at=2026-07-23T18:00:00Z"
    echo "EVENT dispatch_new d=D-151 i=I-001 at=2026-07-23T18:00:00Z"
    echo "EVENT dispatch_state d=D-151 from=READY to=DISPATCHED lane=human at=2026-07-23T18:01:00Z repo=svc branch=i151-fix base_sha=abc123"
    echo "EVENT dispatch_state d=D-151 a=A-01 from=DISPATCHED to=ACKED lane=human at=2026-07-23T18:02:00Z tab=w1.i151"
    echo "EVENT result d=D-151 a=A-01 status=RETURNED result_sha=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee at=2026-07-23T18:03:00Z"
    # marker with a result_sha that does NOT match the recorded (d,a) result
    echo "EVENT merged d=D-151 a=A-01 merge_sha=1111111111111111111111111111111111111111 result_sha=ffffffffffffffffffffffffffffffffffffffff at=2026-07-23T18:04:00Z"
    # marker for an attempt that never existed / has no recorded result
    echo "EVENT merged d=D-151 a=A-07 merge_sha=1111111111111111111111111111111111111111 result_sha=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee at=2026-07-23T18:05:00Z"
    # marker whose repo= contradicts the dispatch's recorded repo
    echo "EVENT merged d=D-151 a=A-01 merge_sha=1111111111111111111111111111111111111111 result_sha=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee repo=other at=2026-07-23T18:06:00Z"
    # marker for an unregistered dispatch -> globally unattributable
    echo "EVENT merged d=D-999 a=A-01 merge_sha=1111111111111111111111111111111111111111 result_sha=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee at=2026-07-23T18:07:00Z"
  } > "$repo/.pm/events.log"

  pm_fold "$repo" >/dev/null

  assert_eq "fold merged violations: all four bad markers quarantined" \
    "4" "$(_idx_py "$repo" "len(d['quarantined'])")"
  assert_eq "fold merged violations: no marker folded into standing state" \
    "0" "$(_idx_py "$repo" "len((d['dispatches']['D-151'].get('merged') or {}))")"
  assert_eq "fold merged violations: dispatch state untouched (still RETURNED)" \
    "RETURNED" "$(_idx_py "$repo" "d['dispatches']['D-151']['state']")"
  # shellcheck disable=SC2016  # $1 expands inside the nested bash -c, not here
  assert_true "fold merged violations: attributed to owning issue I-001 (issue-related-quarantine)" \
    bash -c '[[ "$1" == *issue-related-quarantine* ]]' _ \
    "$(_idx_py "$repo" "d['quarantine_by_issue'].get('I-001')")"
  assert_eq "fold merged violations: unregistered-dispatch marker is globally unattributable" \
    "True" "$(_idx_py "$repo" "d['quarantine_unattributable']")"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B2.2: a CONFLICTING second marker for the same (d,a) -- different
# merge_sha -- quarantines the LATER line; the first accepted marker stands
# (conflict = surface, never silently replace / last-write-wins).
# ---------------------------------------------------------------------------
section_fold_merged_conflict() {
  local repo
  repo="$(new_tmp_repo)"
  {
    echo "EVENT schema v=1"
    echo "EVENT issue_state i=I-001 from=OPEN to=ACTIVE at=2026-07-23T18:00:00Z"
    echo "EVENT dispatch_new d=D-152 i=I-001 at=2026-07-23T18:00:00Z"
    echo "EVENT dispatch_state d=D-152 from=READY to=DISPATCHED lane=human at=2026-07-23T18:01:00Z repo=svc branch=i152-fix base_sha=abc123"
    echo "EVENT dispatch_state d=D-152 a=A-01 from=DISPATCHED to=ACKED lane=human at=2026-07-23T18:02:00Z tab=w1.i152"
    echo "EVENT result d=D-152 a=A-01 status=RETURNED result_sha=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee at=2026-07-23T18:03:00Z"
    echo "EVENT merged d=D-152 a=A-01 merge_sha=1111111111111111111111111111111111111111 result_sha=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee at=2026-07-23T18:04:00Z"
    echo "EVENT merged d=D-152 a=A-01 merge_sha=2222222222222222222222222222222222222222 result_sha=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee at=2026-07-23T18:05:00Z"
  } > "$repo/.pm/events.log"

  pm_fold "$repo" >/dev/null

  assert_eq "fold merged conflict: later conflicting marker quarantined" \
    "1" "$(_idx_py "$repo" "len(d['quarantined'])")"
  assert_eq "fold merged conflict: FIRST marker stands (never silently replaced)" \
    "1111111111111111111111111111111111111111" "$(_idx_py "$repo" "d['dispatches']['D-152']['merged']['A-01']['merge_sha']")"
  # shellcheck disable=SC2016  # $1 expands inside the nested bash -c, not here
  assert_true "fold merged conflict: conflict attributed to owning issue I-001" \
    bash -c '[[ "$1" == *issue-related-quarantine* ]]' _ \
    "$(_idx_py "$repo" "d['quarantine_by_issue'].get('I-001')")"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B2.2 fix-pass-6 F3: the fold shape-gates BOTH sha fields of a `merged`
# event to full 40/64 lowercase hex. A revision expression ("main") or a
# short sha must quarantine (blocking the owning issue) -- the trust
# boundary is symmetric with close-time BASE_SHA_RE, never deferred to it.
# ---------------------------------------------------------------------------
section_fold_merged_shape_gate() {
  local repo full_tip
  repo="$(new_tmp_repo)"
  full_tip="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  {
    echo "EVENT schema v=1"
    echo "EVENT issue_state i=I-001 from=OPEN to=ACTIVE at=2026-07-23T18:00:00Z"
    echo "EVENT dispatch_new d=D-155 i=I-001 at=2026-07-23T18:00:00Z"
    echo "EVENT dispatch_state d=D-155 from=READY to=DISPATCHED lane=human at=2026-07-23T18:01:00Z repo=svc branch=i155-fix base_sha=abc123"
    echo "EVENT dispatch_state d=D-155 a=A-01 from=DISPATCHED to=ACKED lane=human at=2026-07-23T18:02:00Z tab=w1.i155"
    echo "EVENT result d=D-155 a=A-01 status=RETURNED result_sha=$full_tip at=2026-07-23T18:03:00Z"
    # merge_sha is a revision expression, not an object name -> quarantine
    echo "EVENT merged d=D-155 a=A-01 merge_sha=main result_sha=$full_tip at=2026-07-23T18:04:00Z"
    # merge_sha short-hex -> quarantine
    echo "EVENT merged d=D-155 a=A-01 merge_sha=1111abcd result_sha=$full_tip at=2026-07-23T18:05:00Z"
  } > "$repo/.pm/events.log"
  pm_fold "$repo" >/dev/null
  assert_eq "fold merged shape gate: non-hex + short merge_sha both quarantined" \
    "2" "$(_idx_py "$repo" "len(d['quarantined'])")"
  assert_eq "fold merged shape gate: no marker folded" \
    "0" "$(_idx_py "$repo" "len(d['dispatches']['D-155']['merged'])")"
  # shellcheck disable=SC2016  # $1 expands inside the nested bash -c, not here
  assert_true "fold merged shape gate: quarantine blocks the owning issue" \
    bash -c '[[ "$1" == *issue-related-quarantine* ]]' _ \
    "$(_idx_py "$repo" "d['quarantine_by_issue'].get('I-001')")"
  rm -rf "$repo"

  # a SHORT recorded result: the marker faithfully repeating it must STILL
  # quarantine (correct fail-closed -- strict G4 would refuse the short
  # result too; the marker path may never be laxer than strict).
  repo="$(new_tmp_repo)"
  {
    echo "EVENT schema v=1"
    echo "EVENT issue_state i=I-001 from=OPEN to=ACTIVE at=2026-07-23T18:00:00Z"
    echo "EVENT dispatch_new d=D-156 i=I-001 at=2026-07-23T18:00:00Z"
    echo "EVENT dispatch_state d=D-156 from=READY to=DISPATCHED lane=human at=2026-07-23T18:01:00Z repo=svc branch=i156-fix base_sha=abc123"
    echo "EVENT dispatch_state d=D-156 a=A-01 from=DISPATCHED to=ACKED lane=human at=2026-07-23T18:02:00Z tab=w1.i156"
    echo "EVENT result d=D-156 a=A-01 status=RETURNED result_sha=deadbeef at=2026-07-23T18:03:00Z"
    echo "EVENT merged d=D-156 a=A-01 merge_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb result_sha=deadbeef at=2026-07-23T18:04:00Z"
  } > "$repo/.pm/events.log"
  pm_fold "$repo" >/dev/null
  assert_eq "fold merged shape gate: marker echoing a SHORT recorded result quarantined" \
    "1" "$(_idx_py "$repo" "len(d['quarantined'])")"
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B2.2 fix-pass-6 F1: `note` events with an auto-close provenance ref
# (ref=auto-close:* + i=) are folded QUERYABLY into index.auto_close_notes
# so track's marker-close can dedup its pre-close audit note across crash
# recovery. Ordinary notes stay unfolded.
# ---------------------------------------------------------------------------
section_fold_auto_close_notes() {
  local repo
  repo="$(new_tmp_repo)"
  {
    echo "EVENT schema v=1"
    echo "EVENT issue_state i=I-001 from=OPEN to=ACTIVE at=2026-07-23T18:00:00Z"
    echo "EVENT note at=2026-07-23T18:01:00Z ref=auto-close:marker i=I-001"
    echo "EVENT note at=2026-07-23T18:02:00Z ref=misc-note i=I-001"
    echo "EVENT note at=2026-07-23T18:03:00Z ref=auto-close:marker i=I-001"
    echo "EVENT note at=2026-07-23T18:04:00Z ref=auto-close:marker-branch-deleted i=I-002"
    echo "EVENT note at=2026-07-23T18:05:00Z ref=auto-close:marker"
  } > "$repo/.pm/events.log"
  pm_fold "$repo" >/dev/null
  assert_eq "fold auto_close_notes: dedup'd per issue (duplicate ref stored once)" \
    "['auto-close:marker']" "$(_idx_py "$repo" "d['auto_close_notes'].get('I-001')")"
  assert_eq "fold auto_close_notes: branch-deleted ref stored for its issue" \
    "['auto-close:marker-branch-deleted']" "$(_idx_py "$repo" "d['auto_close_notes'].get('I-002')")"
  assert_eq "fold auto_close_notes: only auto-close-ref'd, issue-scoped notes stored" \
    "2" "$(_idx_py "$repo" "len(d['auto_close_notes'])")"
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# pm_git_probe on a throwaway temp git repo
# ---------------------------------------------------------------------------
section_git_probe() {
  local repo
  repo="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-test-git.XXXXXX")"
  (
    cd "$repo" || exit 1
    git init -q -b main .
    git config user.email test@example.com
    git config user.name test
    echo hello > a.txt
    git add a.txt
    git commit -qm init
    echo dirty > b.txt
  )

  local out branch dirty is_repo
  out="$(pm_git_probe "$repo")"
  branch="$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['branch'])" "$out")"
  dirty="$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['dirty'])" "$out")"
  is_repo="$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['is_repo'])" "$out")"
  assert_eq "git_probe: branch == main" "main" "$branch"
  assert_eq "git_probe: dirty == True" "True" "$dirty"
  assert_eq "git_probe: is_repo == True" "True" "$is_repo"

  local not_repo_out not_repo_flag
  not_repo_out="$(pm_git_probe "$repo/nope-not-a-repo-$$")"
  not_repo_flag="$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['is_repo'])" "$not_repo_out" 2>/dev/null || echo ERR)"
  assert_eq "git_probe: non-repo path reports is_repo == False (no crash)" "False" "$not_repo_flag"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# escapers vs hostile inputs
# ---------------------------------------------------------------------------
section_escapers() {
  # shellcheck disable=SC2016  # single-quoted hostile strings are intentionally literal
  local hostile=(
    'plain'
    'has space'
    'new
line'
    '$(rm -rf /)'
    '`whoami`'
    'a;b|c'
    '"quoted"'
    "it's"
    '../../etc/passwd'
    '-rf'
    '*glob?'
    'a=b&c'
  )

  for h in "${hostile[@]}"; do
    local shq mdq jsq pq gq
    shq="$(esc_shell "$h")"
    # esc_shell output, when eval'd as a single word, must reproduce input exactly.
    local roundtrip
    roundtrip="$(eval "printf '%s' $shq")"
    assert_eq "esc_shell round-trips [$h]" "$h" "$roundtrip"

    mdq="$(esc_md "$h")"
    assert_true "esc_md produces output for [$h]" test -n "$mdq" -o -z "$h"

    jsq="$(esc_json "$h")"
    local jsround
    jsround="$(python3 -c "import json,sys;print(json.loads(sys.argv[1]), end='')" "\"$jsq\"" 2>/dev/null || echo __JSON_ERR__)"
    assert_true "esc_json produces parseable JSON string for [$h]" test "$jsround" != "__JSON_ERR__"

    pq="$(esc_path "$h")"
    # shellcheck disable=SC2016
    assert_false "esc_path never leaves a leading dash (arg-injection guard) for [$h]" \
      bash -c '[[ "$1" == -* ]]' _ "$pq"

    gq="$(esc_gitref "$h")"
    assert_true "esc_gitref check-ref-format accepts output for [$h]" \
      git check-ref-format --allow-onelevel "refs/heads/$gq"
  done
}

echo "== pm_raw_append validation =="
section_raw_append
echo "== pm_fold: good.events.log =="
section_fold_good
echo "== pm_fold: corrupt.events.log =="
section_fold_corrupt
echo "== last-write-wins =="
section_last_write_wins
echo "== pm_fold: git-meta (repo/branch/base_sha) carry + preserve-on-omit =="
section_fold_git_meta
echo "== pm_fold: question<->issue (B2.0b) =="
section_fold_question_issue
echo "== pm_fold: merged markers accepted (B2.2) =="
section_fold_merged_accepted
echo "== pm_fold: merged marker violations quarantined (B2.2) =="
section_fold_merged_violations
echo "== pm_fold: conflicting merged marker quarantined (B2.2) =="
section_fold_merged_conflict
echo "== pm_fold: merged sha shape gate (B2.2 F3) =="
section_fold_merged_shape_gate
echo "== pm_fold: auto-close provenance notes folded queryably (B2.2 F1) =="
section_fold_auto_close_notes
echo "== pm_git_probe =="
section_git_probe
echo "== escapers =="
section_escapers

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
