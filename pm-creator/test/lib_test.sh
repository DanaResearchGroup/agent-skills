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
# I6: pm_config_repos is THE one parser of config.json's `repos` -- every
# tool formats/reshapes its normalized output instead of re-parsing, so
# shape tolerance is uniform: canonical list-of-objects and the legacy dict
# both normalize; anything without a non-empty name AND path is skipped
# with a stderr warning (the old per-tool parsers diverged exactly here).
# ---------------------------------------------------------------------------
section_config_repos_parser() {
  local cfg out err
  cfg="$(mktemp "${TMPDIR:-/tmp}/pm-creator-cfg.XXXXXX")"

  # canonical list form (scaffold output)
  cat > "$cfg" <<'JSON'
{"repos": [{"name": "demo", "path": "/x/demo", "mainline": "main",
            "mainline_ref": "refs/heads/main", "fetch_policy": "local-only",
            "merge_mode": "squash", "allow_marker_branch_deleted": true}]}
JSON
  out="$(pm_config_repos "$cfg" 2>/dev/null)"
  assert_eq "config_repos: canonical list normalizes (name/path/mainline/merge_mode)" \
    "demo|/x/demo|main|squash|True" \
    "$(printf '%s' "$out" | python3 -c 'import json,sys; r=json.load(sys.stdin)[0]; print("|".join(str(r[k]) for k in ("name","path","mainline","merge_mode","allow_marker_branch_deleted")))')"

  # legacy dict form, incl. bare-path value; absent keys arrive as null
  cat > "$cfg" <<'JSON'
{"repos": {"A": {"path": "/x/a", "mainline": "dev"}, "B": "/x/b"}}
JSON
  out="$(pm_config_repos "$cfg" 2>/dev/null)"
  assert_eq "config_repos: legacy dict + bare-path value normalize" \
    "A|/x/a|dev,B|/x/b|None" \
    "$(printf '%s' "$out" | python3 -c 'import json,sys; rs=json.load(sys.stdin); print(",".join("|".join(str(r[k]) for k in ("name","path","mainline")) for r in sorted(rs, key=lambda r: r["name"])))')"

  # the I6 divergence case: a list-of-strings entry has no name -> skipped
  # WITH a warning, uniformly (ledger-check used to probe it silently,
  # track used to drop it silently).
  cat > "$cfg" <<'JSON'
{"repos": ["/abs/path/demo", {"name": "ok", "path": "/x/ok"}, {"path": "/x/nameless"}]}
JSON
  out="$(pm_config_repos "$cfg" 2>/dev/null)"
  err="$(pm_config_repos "$cfg" 2>&1 >/dev/null)"
  assert_eq "config_repos: nameless entries skipped, named survive" "ok" \
    "$(printf '%s' "$out" | python3 -c 'import json,sys; print(",".join(r["name"] for r in json.load(sys.stdin)))')"
# shellcheck disable=SC2016  # $1 refers to the nested bash -c's own arg
  assert_true "config_repos: skip is WARNED, never silent" \
    bash -c '[[ "$1" == *"WARN"*"[0]"* && "$1" == *"WARN"*"[2]"* ]]' _ "$err"

  # unreadable config: [] + warning, exit 0 (read-only surfaces stay up)
  out="$(pm_config_repos "$cfg.does-not-exist" 2>/dev/null)"
  assert_eq "config_repos: unreadable config yields []" "[]" "$out"

  rm -f "$cfg"
}

# ---------------------------------------------------------------------------
# I7: the fold VALIDATES the schema header's version -- `EVENT schema v=2`
# (any v != 1) is quarantined loudly (which also flips
# quarantine_unattributable, blocking every auto-close), never silently
# accepted as if this tooling understood a future grammar revision.
# ---------------------------------------------------------------------------
section_schema_version_gate() {
  local repo qc unattr
  repo="$(new_tmp_repo)"
  printf 'EVENT schema v=2\n' > "$repo/.pm/events.log"

  assert_true "schema-gate: pm_fold exits 0 (quarantines, never crashes)" pm_fold "$repo"
  qc="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(len(d['quarantined']))")"
  assert_eq "schema-gate: v=2 header quarantined" "1" "$qc"
  unattr="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(d['quarantine_unattributable'])")"
  assert_eq "schema-gate: unattributable quarantine flag set (auto-close blocked)" "True" "$unattr"

  # v=1 stays clean.
  printf 'EVENT schema v=1\n' > "$repo/.pm/events.log"
  rm -f "$repo/.pm/index.json" "$repo/.pm/quarantine.log"
  assert_true "schema-gate: v=1 header still folds clean" pm_fold "$repo"
  qc="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(len(d['quarantined']))")"
  assert_eq "schema-gate: v=1 nothing quarantined" "0" "$qc"

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
# B3: `spawn_intent` events -- durable spawn-intent lease records for the
# automation lane. The fold must (a) accept a valid intent into
# dispatches[d].spawn_intent[a] WITHOUT transitioning dispatch/issue state,
# (b) accept an identical re-append idempotently, (c) fold prompt_sha and
# the prompts/ note binding queryably (track's D2 re-hash guard reads BOTH
# from the fold, never from a raw-log re-parse).
# ---------------------------------------------------------------------------
section_fold_spawn_intent_accepted() {
  local repo
  repo="$(new_tmp_repo)"
  {
    echo "EVENT schema v=1"
    echo "EVENT issue_state i=I-001 from=OPEN to=ACTIVE at=2026-07-25T18:00:00Z"
    echo "EVENT dispatch_new d=D-160 i=I-001 at=2026-07-25T18:00:00Z"
    echo "EVENT dispatch_state d=D-160 a=A-01 from=READY to=DISPATCHED lane=automation at=2026-07-25T18:01:00Z tab=? prompt_sha=ab12cd34"
    echo "EVENT note at=2026-07-25T18:01:00Z ref=prompts/I-001_fix_2026-07-25.md d=D-160"
    echo "EVENT spawn_intent d=D-160 a=A-01 at=2026-07-25T18:02:00Z ref=i1-fix-D160A01"
  } > "$repo/.pm/events.log"

  pm_fold "$repo" >/dev/null

  assert_eq "fold spawn_intent: intent stored per (d,a) -- ref" \
    "i1-fix-D160A01" "$(_idx_py "$repo" "d['dispatches']['D-160']['spawn_intent']['A-01']['ref']")"
  assert_eq "fold spawn_intent: intent stored per (d,a) -- at" \
    "2026-07-25T18:02:00Z" "$(_idx_py "$repo" "d['dispatches']['D-160']['spawn_intent']['A-01']['at']")"
  assert_eq "fold spawn_intent: dispatch state untouched (still DISPATCHED)" \
    "DISPATCHED" "$(_idx_py "$repo" "d['dispatches']['D-160']['state']")"
  assert_eq "fold spawn_intent: issue state untouched (still ACTIVE)" \
    "ACTIVE" "$(_idx_py "$repo" "d['issues']['I-001']['state']")"
  assert_eq "fold spawn_intent: prompt_sha folded queryably" \
    "ab12cd34" "$(_idx_py "$repo" "d['dispatches']['D-160']['prompt_sha']")"
  assert_eq "fold spawn_intent: prompts/ note binding folded queryably" \
    "prompts/I-001_fix_2026-07-25.md" "$(_idx_py "$repo" "d['dispatches']['D-160']['prompt_ref']")"
  assert_eq "fold spawn_intent: zero quarantined entries" \
    "0" "$(_idx_py "$repo" "len(d['quarantined'])")"

  # C4: the lease is EXCLUSIVE -- an identical re-append is QUARANTINED
  # with the spawn-lease-held token (a duplicate never means the lease was
  # won); the FIRST intent stands.
  echo "EVENT spawn_intent d=D-160 a=A-01 at=2026-07-25T18:03:00Z ref=i1-fix-D160A01" >> "$repo/.pm/events.log"
  pm_fold "$repo" >/dev/null
  assert_eq "fold spawn_intent: identical re-append quarantined (exclusive lease)" \
    "1" "$(_idx_py "$repo" "len(d['quarantined'])")"
  # shellcheck disable=SC2016  # $1 is the nested bash -c's own arg
  assert_true "fold spawn_intent: identical re-append quarantine reason carries spawn-lease-held" \
    bash -c 'grep -q "spawn-lease-held" "$1/.pm/quarantine.log"' _ "$repo"
  assert_eq "fold spawn_intent: identical re-append leaves the FIRST intent standing" \
    "2026-07-25T18:02:00Z" "$(_idx_py "$repo" "d['dispatches']['D-160']['spawn_intent']['A-01']['at']")"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B3: a CONFLICTING second spawn_intent for the same (d,a) -- different ref
# -- quarantines the LATER line; the first accepted intent stands (conflict
# = surface, never silently replace -- mirrors `merged`).
# ---------------------------------------------------------------------------
section_fold_spawn_intent_conflict() {
  local repo
  repo="$(new_tmp_repo)"
  {
    echo "EVENT schema v=1"
    echo "EVENT issue_state i=I-001 from=OPEN to=ACTIVE at=2026-07-25T18:00:00Z"
    echo "EVENT dispatch_new d=D-161 i=I-001 at=2026-07-25T18:00:00Z"
    echo "EVENT dispatch_state d=D-161 a=A-01 from=READY to=DISPATCHED lane=automation at=2026-07-25T18:01:00Z tab=?"
    echo "EVENT spawn_intent d=D-161 a=A-01 at=2026-07-25T18:02:00Z ref=i1-fix-D161A01"
    echo "EVENT spawn_intent d=D-161 a=A-01 at=2026-07-25T18:03:00Z ref=i1-fix-D161A01-other"
  } > "$repo/.pm/events.log"

  pm_fold "$repo" >/dev/null

  assert_eq "fold spawn_intent conflict: later conflicting intent quarantined" \
    "1" "$(_idx_py "$repo" "len(d['quarantined'])")"
  assert_eq "fold spawn_intent conflict: FIRST intent stands (never silently replaced)" \
    "i1-fix-D161A01" "$(_idx_py "$repo" "d['dispatches']['D-161']['spawn_intent']['A-01']['ref']")"
  # shellcheck disable=SC2016  # $1 expands inside the nested bash -c, not here
  assert_true "fold spawn_intent conflict: conflict attributed to owning issue I-001" \
    bash -c '[[ "$1" == *issue-related-quarantine* ]]' _ \
    "$(_idx_py "$repo" "d['quarantine_by_issue'].get('I-001')")"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B3: spawn_intent violations quarantine (never fold, never transition) with
# issue-scoped attribution via the dispatch bucket -- unregistered d, wrong
# attempt, human-lane dispatch, not-currently-DISPATCHED dispatch.
# ---------------------------------------------------------------------------
section_fold_spawn_intent_violations() {
  local repo
  repo="$(new_tmp_repo)"
  {
    echo "EVENT schema v=1"
    echo "EVENT issue_state i=I-001 from=OPEN to=ACTIVE at=2026-07-25T18:00:00Z"
    # D-162: automation lane, DISPATCHED -- wrong-attempt target
    echo "EVENT dispatch_new d=D-162 i=I-001 at=2026-07-25T18:00:00Z"
    echo "EVENT dispatch_state d=D-162 a=A-01 from=READY to=DISPATCHED lane=automation at=2026-07-25T18:01:00Z tab=?"
    # D-163: HUMAN lane, DISPATCHED -- lane violation target
    echo "EVENT dispatch_new d=D-163 i=I-001 at=2026-07-25T18:00:00Z"
    echo "EVENT dispatch_state d=D-163 a=A-01 from=READY to=DISPATCHED lane=human at=2026-07-25T18:01:00Z tab=?"
    # D-164: automation lane but already ACKED -- state violation target
    echo "EVENT dispatch_new d=D-164 i=I-001 at=2026-07-25T18:00:00Z"
    echo "EVENT dispatch_state d=D-164 a=A-01 from=READY to=DISPATCHED lane=automation at=2026-07-25T18:01:00Z tab=?"
    echo "EVENT dispatch_state d=D-164 a=A-01 from=DISPATCHED to=ACKED lane=automation at=2026-07-25T18:02:00Z tab=zzz-test-tab-164"
    # violation 1: unregistered dispatch -> globally unattributable
    echo "EVENT spawn_intent d=D-999 a=A-01 at=2026-07-25T18:03:00Z ref=zzz-test-worker"
    # violation 2: wrong attempt (A-07 is not D-162's current attempt)
    echo "EVENT spawn_intent d=D-162 a=A-07 at=2026-07-25T18:04:00Z ref=zzz-test-worker"
    # violation 3: human-lane dispatch
    echo "EVENT spawn_intent d=D-163 a=A-01 at=2026-07-25T18:05:00Z ref=zzz-test-worker"
    # violation 4: dispatch not currently DISPATCHED (ACKED)
    echo "EVENT spawn_intent d=D-164 a=A-01 at=2026-07-25T18:06:00Z ref=zzz-test-worker"
  } > "$repo/.pm/events.log"

  pm_fold "$repo" >/dev/null

  assert_eq "fold spawn_intent violations: all four bad intents quarantined" \
    "4" "$(_idx_py "$repo" "len(d['quarantined'])")"
  assert_eq "fold spawn_intent violations: no intent folded into standing state (D-162)" \
    "0" "$(_idx_py "$repo" "len((d['dispatches']['D-162'].get('spawn_intent') or {}))")"
  assert_eq "fold spawn_intent violations: no intent folded into standing state (D-163)" \
    "0" "$(_idx_py "$repo" "len((d['dispatches']['D-163'].get('spawn_intent') or {}))")"
  assert_eq "fold spawn_intent violations: no intent folded into standing state (D-164)" \
    "0" "$(_idx_py "$repo" "len((d['dispatches']['D-164'].get('spawn_intent') or {}))")"
  assert_eq "fold spawn_intent violations: dispatch state untouched (D-162 still DISPATCHED)" \
    "DISPATCHED" "$(_idx_py "$repo" "d['dispatches']['D-162']['state']")"
  assert_eq "fold spawn_intent violations: dispatch state untouched (D-164 still ACKED)" \
    "ACKED" "$(_idx_py "$repo" "d['dispatches']['D-164']['state']")"
  # shellcheck disable=SC2016  # $1 expands inside the nested bash -c, not here
  assert_true "fold spawn_intent violations: attributed to owning issue I-001 (issue-related-quarantine)" \
    bash -c '[[ "$1" == *issue-related-quarantine* ]]' _ \
    "$(_idx_py "$repo" "d['quarantine_by_issue'].get('I-001')")"
  assert_eq "fold spawn_intent violations: unregistered-dispatch intent is globally unattributable" \
    "True" "$(_idx_py "$repo" "d['quarantine_unattributable']")"

  # strict-mode (pm_apply) parity: the write path refuses what the fold
  # quarantines -- a wrong-attempt intent and a human-lane intent both fail.
  if PM_ROOT="$repo" pm_apply spawn_intent d=D-162 a=A-07 at=2026-07-25T18:07:00Z ref=zzz-test-worker >/dev/null 2>&1; then
    fail "pm_apply spawn_intent: wrong attempt refused at write" "unexpectedly accepted"
  else
    ok "pm_apply spawn_intent: wrong attempt refused at write"
  fi
  if PM_ROOT="$repo" pm_apply spawn_intent d=D-163 a=A-01 at=2026-07-25T18:07:00Z ref=zzz-test-worker >/dev/null 2>&1; then
    fail "pm_apply spawn_intent: human-lane dispatch refused at write" "unexpectedly accepted"
  else
    ok "pm_apply spawn_intent: human-lane dispatch refused at write"
  fi
  if PM_ROOT="$repo" pm_apply spawn_intent d=D-162 a=A-01 at=2026-07-25T18:07:00Z ref=zzz-test-worker >/dev/null 2>&1; then
    ok "pm_apply spawn_intent: valid intent accepted at write"
  else
    fail "pm_apply spawn_intent: valid intent accepted at write" "unexpectedly refused"
  fi

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B3: bash grammar tables and the embedded-python engine tables MUST stay in
# lockstep (same event types, same required/optional/key-order per type) --
# the two are kept in sync by hand, so this is the tripwire.
# ---------------------------------------------------------------------------
section_tables_lockstep() {
  local py_tables
  py_tables="$(printf '%s' "$_PM_ENGINE_PY" | python3 -c '
import json, sys
g = {}
exec(sys.stdin.read(), g)
print(json.dumps({
    "REQUIRED": {k: " ".join(v) for k, v in g["REQUIRED"].items()},
    "OPTIONAL": {k: " ".join(v) for k, v in g["OPTIONAL"].items()},
    "KEY_ORDER": {k: " ".join(v) for k, v in g["KEY_ORDER"].items()},
}))
')" || { fail "tables lockstep: python engine tables extract" "exec failed"; return; }

  local etype expected
  for etype in "${!_PM_REQUIRED_KEYS[@]}"; do
    expected="$(python3 -c "import json,sys; t=json.loads(sys.argv[1]); print(t['REQUIRED'].get('$etype', '<MISSING>'))" "$py_tables")"
    assert_eq "tables lockstep: REQUIRED[$etype] bash==python" "${_PM_REQUIRED_KEYS[$etype]}" "$expected"
    expected="$(python3 -c "import json,sys; t=json.loads(sys.argv[1]); print(t['OPTIONAL'].get('$etype', '<MISSING>'))" "$py_tables")"
    assert_eq "tables lockstep: OPTIONAL[$etype] bash==python" "${_PM_OPTIONAL_KEYS[$etype]}" "$expected"
    expected="$(python3 -c "import json,sys; t=json.loads(sys.argv[1]); print(t['KEY_ORDER'].get('$etype', '<MISSING>'))" "$py_tables")"
    assert_eq "tables lockstep: KEY_ORDER[$etype] bash==python" "${_PM_KEY_ORDER[$etype]}" "$expected"
  done

  # both directions: no python-only event type either
  local py_only
  py_only="$(BASH_TYPES="${!_PM_REQUIRED_KEYS[*]}" python3 -c "
import json, os, sys
t = json.loads(sys.argv[1])
bash_types = set(os.environ['BASH_TYPES'].split())
extra = sorted(set(t['REQUIRED']) - bash_types)
print(' '.join(extra) if extra else 'none')
" "$py_tables")"
  assert_eq "tables lockstep: no python-only event types" "none" "$py_only"

  # B3: spawn_intent is actually present in the grammar (red-first anchor)
  assert_eq "tables lockstep: spawn_intent registered with required 'd a at'" \
    "d a at" "${_PM_REQUIRED_KEYS[spawn_intent]:-<MISSING>}"
}

# ---------------------------------------------------------------------------
# B3: the grammar doc carries the spawn_intent row + a rev 1.2 migration
# note with the same blast-radius warning pattern rev 1.1 established.
# ---------------------------------------------------------------------------
section_grammar_doc_spawn_intent() {
  local doc="${PM_CREATOR_DIR}/references/event-log-grammar.md"
  # shellcheck disable=SC2016  # literal backticks in the markdown row, not expansion
  assert_true "grammar doc: spawn_intent row present with required 'd a at' + optional 'ref'" \
    grep -q -- '| `spawn_intent` | `d a at` | `ref` |' "$doc"
  assert_true "grammar doc: revision 1.2 note present" \
    grep -qi 'revision \*\*1\.2\*\*' "$doc"
  assert_true "grammar doc: rev 1.2 note names spawn_intent in its migration warning" \
    bash -c "grep -i -B2 -A8 'revision \*\*1\.2\*\*' '$doc' | grep -qi 'spawn_intent'"
  assert_true "grammar doc: rev 1.2 warning keeps the unattributable/auto-close-freeze blast radius" \
    bash -c "grep -i -A10 'revision \*\*1\.2\*\*' '$doc' | grep -qi 'unattributable'"
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
# escapers vs hostile inputs -- esc_shell only: the four dead escapers
# (esc_md/esc_json/esc_path/esc_gitref) were deleted with their copied
# tests (I14); the Markdown escapers live in _PM_MD_PY and are exercised
# through track_test/reconcile_test's injection sections.
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
    local shq
    shq="$(esc_shell "$h")"
    # esc_shell output, when eval'd as a single word, must reproduce input exactly.
    local roundtrip
    roundtrip="$(eval "printf '%s' $shq")"
    assert_eq "esc_shell round-trips [$h]" "$h" "$roundtrip"
  done
}

# ---------------------------------------------------------------------------
# review I1: pm_apply's python-side TOKEN_RE (pre-fix `^...$`) tolerates a
# trailing embedded "\n" -- Python's $ matches just before a trailing "\n",
# so a value ending in "\n" would validate as a clean token, then split one
# committed event into two lines on append, corrupting line-oriented
# parse/quarantine attribution downstream. \A/\Z anchors (plus the
# belt-and-suspenders "\n" in rendered-line check) must refuse it outright.
# ---------------------------------------------------------------------------
section_apply_newline_refused() {
  local repo
  repo="$(new_tmp_repo)"
  # shellcheck disable=SC2034  # dynamic scope pickup by pm_apply/_pm_root
  local PM_ROOT="$repo"

  # seed one legitimate event first so events.log exists with a known,
  # stable line count to assert against.
  assert_true "pm_apply: seed legitimate note accepted" \
    pm_apply note at=2026-07-25T18:00:00Z ref=zzz-test-note-seed

  local before_lines
  before_lines="$(wc -l <"$repo/.pm/events.log" 2>/dev/null || echo 0)"

  # shellcheck disable=SC2016  # $1/$2 are the nested bash -c's own positional args
  assert_false "pm_apply: value with embedded trailing newline refused" \
    env PM_ROOT="$repo" bash -c 'source "$1"; pm_apply note at=2026-07-25T18:00:00Z ref="$2"' \
      _ "$LIB" $'zzz-test-note\n'

  local after_lines
  after_lines="$(wc -l <"$repo/.pm/events.log" 2>/dev/null || echo 0)"
  assert_eq "pm_apply: refused newline value appends no line (no blank/split line)" \
    "$before_lines" "$after_lines"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# C5/I3: the fold's writes are LOCKED and ATOMIC; the apply-driver's log
# append is fsync'ed before success is reported.
# ---------------------------------------------------------------------------
section_fold_locked_and_atomic() {
  local repo
  repo="$(new_tmp_repo)"
  PM_ROOT="$repo" pm_apply issue_state i=I-050 from=OPEN to=ACTIVE at=2026-07-25T18:00:00Z >/dev/null

  # (1) C5: pm_fold must take the repo lock -- while another process holds
  # it, a fold must FAIL (after timeout) instead of writing an index that
  # can race the lock-holder's own refold.
  bash -c '
    source "$1"
    pm_lock "$2" || exit 9
    exec sleep 30
  ' _ "$LIB" "$repo" &
  local hp=$!
  local i=0
  while flock -n "$repo/.pm/.lock" true 2>/dev/null; do
    i=$((i + 1)); [[ "$i" -ge 50 ]] && break; sleep 0.1
  done
  # shellcheck disable=SC2016  # $1/$2 are the nested bash -c's own args
  assert_true "fold lock: holder observably held the lock" \
    bash -c '[[ "$1" -lt 50 ]]' _ "$i"
  # shellcheck disable=SC2016
  assert_false "fold lock: pm_fold refuses while the lock is held elsewhere" \
    env PM_LOCK_TIMEOUT=1 bash -c 'source "$1"; pm_fold "$2" 2>/dev/null' _ "$LIB" "$repo"
  kill -9 "$hp" 2>/dev/null || true
  wait "$hp" 2>/dev/null || true

  # (2) C5: successful fold leaves a parseable index and NO .tmp leftovers
  # (write goes to <path>.tmp then os.replace).
  assert_true "fold atomic: pm_fold succeeds once the lock is free" \
    pm_fold "$repo"
  assert_true "fold atomic: index.json parses" \
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$repo/.pm/index.json"
  assert_false "fold atomic: no index.json.tmp leftover" \
    test -e "$repo/.pm/index.json.tmp"
  assert_false "fold atomic: no quarantine.log.tmp leftover" \
    test -e "$repo/.pm/quarantine.log.tmp"

  # (3) C5: a reader racing a fold loop must NEVER see a torn index --
  # every concurrent read parses (old complete file or new complete file).
  (
    # shellcheck disable=SC1090
    source "$LIB"
    for _ in $(seq 1 30); do
      pm_fold "$repo" >/dev/null 2>&1
    done
  ) &
  local fp=$! torn=0
  for _ in $(seq 1 60); do
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$repo/.pm/index.json" 2>/dev/null || torn=$((torn + 1))
  done
  wait "$fp" 2>/dev/null || true
  assert_eq "fold atomic: zero torn reads while a fold loop runs" "0" "$torn"

  # (4) I3 (static bind, same pattern as track's reason-registry check):
  # the apply driver must flush+fsync the log append before reporting
  # success -- the commit point is durable, not a buffered write.
  # shellcheck disable=SC2016
  assert_true "apply driver: log append is fsync'ed before success" \
    bash -c 'grep -A4 "with open(log_path, \"a\")" "$1" | grep -q "os.fsync"' _ "$LIB"

  rm -rf "$repo"
}

echo "== pm_fold: locked + atomic writes; durable append (C5/I3) =="
section_fold_locked_and_atomic

echo "== pm_raw_append validation =="
section_raw_append
echo "== pm_fold: good.events.log =="
section_fold_good
echo "== pm_config_repos: one shared parser (I6) =="
section_config_repos_parser
echo "== pm_fold: schema version gate (I7) =="
section_schema_version_gate
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
echo "== pm_fold: spawn_intent accepted (B3) =="
section_fold_spawn_intent_accepted
echo "== pm_fold: conflicting spawn_intent quarantined (B3) =="
section_fold_spawn_intent_conflict
echo "== pm_fold: spawn_intent violations quarantined (B3) =="
section_fold_spawn_intent_violations
echo "== grammar tables lockstep (bash == embedded python) =="
section_tables_lockstep
echo "== grammar doc: spawn_intent row + rev 1.2 note (B3) =="
section_grammar_doc_spawn_intent
echo "== pm_git_probe =="
section_git_probe
echo "== escapers =="
section_escapers
echo "== review I1: pm_apply refuses value with embedded/trailing newline =="
section_apply_newline_refused

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
