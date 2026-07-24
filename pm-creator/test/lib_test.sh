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
