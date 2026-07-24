#!/usr/bin/env bash
# Test harness for templates/bin/dispatch-prep (human-gated dispatch prep).
#
# Run: bash test/dispatch_prep_test.sh
# Exits non-zero if any assertion fails; prints a PASS/FAIL summary.
set -u

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PM_CREATOR_DIR="$(cd "${THIS_DIR}/.." && pwd)"
LIB="${PM_CREATOR_DIR}/templates/bin/_lib.sh"
DISPATCH_PREP="${PM_CREATOR_DIR}/templates/bin/dispatch-prep"

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

assert_true() {
  local name="$1"
  shift
  if "$@"; then
    ok "$name"
  else
    fail "$name" "command failed: $*"
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$name"
  else
    fail "$name" "expected output to contain [$needle]"
  fi
}

# ---------------------------------------------------------------------------
# fixture: a fresh generated PM repo (just enough of one for dispatch-prep)
# ---------------------------------------------------------------------------

new_tmp_repo() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-dispatch-prep-test.XXXXXX")"
  mkdir -p "$d/.pm" "$d/prompts"
  cat > "$d/.pm/config.json" <<'JSON'
{
  "campaign": "Test Campaign",
  "slug": "test-campaign",
  "schema_version": 1,
  "herdr_workspace": "zzz-test-ws",
  "worktree_root": "/tmp/worktrees",
  "runs_root": "/tmp/runs",
  "remote_policy": "local-only",
  "repos": {
    "demo-repo": {"path": "/tmp/demo-repo", "mainline": "main"}
  },
  "optional_slots": {}
}
JSON
  printf 'EVENT schema v=1\n' > "$d/.pm/events.log"
  printf 'Do the thing. Be self-contained.\n' > "$d/prompts/I-004_foo_2026-07-23.md"
  echo "$d"
}

# ---------------------------------------------------------------------------
# section: fresh dispatch
# ---------------------------------------------------------------------------

section_fresh_dispatch() {
  local repo out rc
  repo="$(new_tmp_repo)"

  out="$(PM_ROOT="$repo" "$DISPATCH_PREP" \
    --dispatch D-007 --issue I-004 \
    --prompt "$repo/prompts/I-004_foo_2026-07-23.md" \
    --tab zzz-test-tab --repo demo-repo 2>&1)"
  rc=$?
  assert_eq "fresh dispatch: exits 0" "0" "$rc"

  local log
  log="$(cat "$repo/.pm/events.log")"
  assert_contains "fresh dispatch: emits dispatch_new for D-007/I-004" \
    "$log" "EVENT dispatch_new d=D-007 i=I-004 at="
  assert_contains "fresh dispatch: emits DISPATCHED transition at attempt A-01" \
    "$log" "EVENT dispatch_state d=D-007 a=A-01 from=READY to=DISPATCHED lane=human"
  assert_contains "fresh dispatch: DISPATCHED event carries tab=? prompt_sha=" \
    "$log" "tab=? prompt_sha="

  assert_contains "fresh dispatch: prints D-007 in summary" "$out" "D-007"
  assert_contains "fresh dispatch: prints attempt A-01 in summary" "$out" "A-01"
  assert_contains "fresh dispatch: prints herdr command with quoted workspace" \
    "$out" "herdr tab create --workspace 'zzz-test-ws' --label 'zzz-test-tab'"
  assert_contains "fresh dispatch: prints --cwd for the resolved repo path" \
    "$out" "--cwd '/tmp/demo-repo'"

  # The printed command must be exactly reproducible by eval (properly
  # quoted) WITHOUT ever invoking the real herdr binary: shadow it with a
  # local function that just captures its argv, so eval only proves the
  # quoting round-trips (this is the human-gated lane — nothing here may
  # spawn a real herdr tab).
  local cmd_line captured
  cmd_line="$(printf '%s\n' "$out" | grep '^  herdr tab create')"
  cmd_line="${cmd_line#  }"
  # shellcheck disable=SC2329  # invoked indirectly via eval below
  herdr() { printf '%s\x1f' "$@"; }
  captured="$(eval "$cmd_line")"
  unset -f herdr
  assert_eq "fresh dispatch: printed command round-trips through eval as separate argv words (no herdr binary invoked)" \
    "tab$(printf '\x1f')create$(printf '\x1f')--workspace$(printf '\x1f')zzz-test-ws$(printf '\x1f')--label$(printf '\x1f')zzz-test-tab$(printf '\x1f')--cwd$(printf '\x1f')/tmp/demo-repo$(printf '\x1f')" \
    "$captured"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: refuse double dispatch (same D, still active)
# ---------------------------------------------------------------------------

section_refuse_double_dispatch() {
  local repo out rc
  repo="$(new_tmp_repo)"

  PM_ROOT="$repo" "$DISPATCH_PREP" \
    --dispatch D-007 --issue I-004 \
    --prompt "$repo/prompts/I-004_foo_2026-07-23.md" \
    --tab zzz-test-tab >/dev/null 2>&1

  local lines_after_first
  lines_after_first="$(wc -l < "$repo/.pm/events.log" | tr -d ' ')"

  out="$(PM_ROOT="$repo" "$DISPATCH_PREP" \
    --dispatch D-007 --issue I-004 \
    --prompt "$repo/prompts/I-004_foo_2026-07-23.md" \
    --tab zzz-test-tab 2>&1)"
  rc=$?
  # shellcheck disable=SC2016  # $1 is intentionally expanded inside the bash -c subshell, not here
  assert_true "refuse: second prep of same non-terminal D exits non-zero" \
    bash -c '[[ "$1" -ne 0 ]]' _ "$rc"
  assert_contains "refuse: message names the offending dispatch" "$out" "D-007"

  local lines_after_second
  lines_after_second="$(wc -l < "$repo/.pm/events.log" | tr -d ' ')"
  assert_eq "refuse: no new events were emitted on refusal" \
    "$lines_after_first" "$lines_after_second"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: retry after FAILED mints a new attempt
# ---------------------------------------------------------------------------

section_retry_after_failed() {
  local repo out rc
  repo="$(new_tmp_repo)"

  PM_ROOT="$repo" "$DISPATCH_PREP" \
    --dispatch D-009 --issue I-004 \
    --prompt "$repo/prompts/I-004_foo_2026-07-23.md" \
    --tab zzz-test-tab >/dev/null 2>&1

  PM_ROOT="$repo" pm_apply dispatch_state \
    d=D-009 a=A-01 from=DISPATCHED to=FAILED lane=human at=2026-07-23T19:00:00Z >/dev/null

  out="$(PM_ROOT="$repo" "$DISPATCH_PREP" \
    --dispatch D-009 --issue I-004 \
    --prompt "$repo/prompts/I-004_foo_2026-07-23.md" \
    --tab zzz-test-tab 2>&1)"
  rc=$?
  assert_eq "retry after FAILED: exits 0" "0" "$rc"
  assert_contains "retry after FAILED: mints attempt A-02" "$out" "A-02"

  local log
  log="$(cat "$repo/.pm/events.log")"
  assert_contains "retry after FAILED: emits FAILED->DISPATCHED at A-02" \
    "$log" "EVENT dispatch_state d=D-009 a=A-02 from=FAILED to=DISPATCHED lane=human"
  assert_contains "retry after FAILED: does not re-emit dispatch_new" \
    "$log" "EVENT dispatch_new d=D-009 i=I-004"
  local dispatch_new_count
  dispatch_new_count="$(grep -c "EVENT dispatch_new d=D-009" "$repo/.pm/events.log")"
  assert_eq "retry after FAILED: dispatch_new emitted exactly once" "1" "$dispatch_new_count"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# fixture: a fresh generated PM repo whose --repo entry points at a REAL git
# work tree with a mainline branch (for git-corroboration metadata tests).
# ---------------------------------------------------------------------------

new_tmp_repo_with_git() {
  local d gitrepo
  d="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-dispatch-prep-test.XXXXXX")"
  gitrepo="$d/target-repo"
  mkdir -p "$d/.pm" "$d/prompts" "$gitrepo"
  (
    cd "$gitrepo" || exit 1
    git init -q -b main .
    git config user.email test@example.com
    git config user.name test
    printf 'hello\n' > README.md
    git add README.md
    git commit -q -m 'initial commit'
  ) >&2
  cat > "$d/.pm/config.json" <<JSON
{
  "campaign": "Test Campaign",
  "slug": "test-campaign",
  "schema_version": 1,
  "herdr_workspace": "zzz-test-ws",
  "worktree_root": "/tmp/worktrees",
  "runs_root": "/tmp/runs",
  "remote_policy": "local-only",
  "repos": [
    {"name": "demo-repo", "path": "$gitrepo", "mainline": "main"}
  ],
  "optional_slots": {}
}
JSON
  printf 'EVENT schema v=1\n' > "$d/.pm/events.log"
  printf 'Do the thing. Be self-contained.\n' > "$d/prompts/I-004_foo_2026-07-23.md"
  echo "$d"
}

# ---------------------------------------------------------------------------
# section: git-corroboration metadata (B1.1) -- resolvable --repo captures
# repo/branch/base_sha at the mint
# ---------------------------------------------------------------------------

section_git_meta_resolvable_repo() {
  local repo out rc
  repo="$(new_tmp_repo_with_git)"

  local head_sha
  head_sha="$(git -C "$repo/target-repo" rev-parse main)"

  out="$(PM_ROOT="$repo" "$DISPATCH_PREP" \
    --dispatch D-020 --issue I-004 \
    --prompt "$repo/prompts/I-004_foo_2026-07-23.md" \
    --tab zzz-test-tab --repo demo-repo 2>&1)"
  rc=$?
  assert_eq "git-meta resolvable: exits 0" "0" "$rc"

  local log
  log="$(cat "$repo/.pm/events.log")"
  assert_contains "git-meta resolvable: DISPATCHED event carries repo=demo-repo" \
    "$log" "repo=demo-repo"
  assert_contains "git-meta resolvable: DISPATCHED event carries branch=i004-foo" \
    "$log" "branch=i004-foo"
  assert_contains "git-meta resolvable: DISPATCHED event carries base_sha==mainline HEAD" \
    "$log" "base_sha=$head_sha"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: git-corroboration metadata -- --repo omitted emits none of the
# three, dispatch still succeeds
# ---------------------------------------------------------------------------

section_git_meta_repo_omitted() {
  local repo out rc
  repo="$(new_tmp_repo_with_git)"

  out="$(PM_ROOT="$repo" "$DISPATCH_PREP" \
    --dispatch D-021 --issue I-004 \
    --prompt "$repo/prompts/I-004_foo_2026-07-23.md" \
    --tab zzz-test-tab 2>&1)"
  rc=$?
  assert_eq "git-meta omitted: exits 0" "0" "$rc"

  local log
  log="$(cat "$repo/.pm/events.log")"
  # shellcheck disable=SC2016  # $1 is intentionally expanded inside the bash -c subshell, not here
  assert_true "git-meta omitted: DISPATCHED event carries no repo=" \
    bash -c '[[ "$1" != *"repo="* ]]' _ "$log"
  # shellcheck disable=SC2016  # $1 is intentionally expanded inside the bash -c subshell, not here
  assert_true "git-meta omitted: DISPATCHED event carries no branch=" \
    bash -c '[[ "$1" != *"branch="* ]]' _ "$log"
  # shellcheck disable=SC2016  # $1 is intentionally expanded inside the bash -c subshell, not here
  assert_true "git-meta omitted: DISPATCHED event carries no base_sha=" \
    bash -c '[[ "$1" != *"base_sha="* ]]' _ "$log"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: git-corroboration metadata -- resolved repo_path that is NOT a
# git work tree omits base_sha (and branch, since mainline can't resolve
# either) but never aborts the dispatch
# ---------------------------------------------------------------------------

section_git_meta_repo_path_not_a_git_repo() {
  local repo out rc
  repo="$(new_tmp_repo)"
  mkdir -p /tmp/demo-repo 2>/dev/null || true

  out="$(PM_ROOT="$repo" "$DISPATCH_PREP" \
    --dispatch D-022 --issue I-004 \
    --prompt "$repo/prompts/I-004_foo_2026-07-23.md" \
    --tab zzz-test-tab --repo demo-repo 2>&1)"
  rc=$?
  assert_eq "git-meta non-git repo_path: exits 0" "0" "$rc"

  local log
  log="$(cat "$repo/.pm/events.log")"
  assert_contains "git-meta non-git repo_path: still carries repo=demo-repo" \
    "$log" "repo=demo-repo"
  # shellcheck disable=SC2016  # $1 is intentionally expanded inside the bash -c subshell, not here
  assert_true "git-meta non-git repo_path: no base_sha= emitted" \
    bash -c '[[ "$1" != *"base_sha="* ]]' _ "$log"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: B1.1 FIX 1 regression -- retry after FAILED when the repo's
# mainline HEAD has MOVED since the first attempt. base_sha is
# attempt-scoped, so this must be ACCEPTED (was refused pre-fix), and both
# attempts' base_sha are retained in index.json.
# ---------------------------------------------------------------------------

section_retry_after_failed_with_moved_mainline() {
  local repo out rc
  repo="$(new_tmp_repo_with_git)"

  local s1
  s1="$(git -C "$repo/target-repo" rev-parse main)"

  PM_ROOT="$repo" "$DISPATCH_PREP" \
    --dispatch D-030 --issue I-004 \
    --prompt "$repo/prompts/I-004_foo_2026-07-23.md" \
    --tab zzz-test-tab --repo demo-repo >/dev/null 2>&1

  PM_ROOT="$repo" pm_apply dispatch_state \
    d=D-030 a=A-01 from=DISPATCHED to=FAILED lane=human at=2026-07-23T19:00:00Z >/dev/null

  # advance mainline so the retry's base_sha (S2) differs from A-01's (S1)
  (
    cd "$repo/target-repo" || exit 1
    printf 'second commit\n' >> README.md
    git add README.md
    git commit -q -m 'second commit'
  ) >&2
  local s2
  s2="$(git -C "$repo/target-repo" rev-parse main)"

  out="$(PM_ROOT="$repo" "$DISPATCH_PREP" \
    --dispatch D-030 --issue I-004 \
    --prompt "$repo/prompts/I-004_foo_2026-07-23.md" \
    --tab zzz-test-tab --repo demo-repo 2>&1)"
  rc=$?
  assert_eq "retry with moved mainline: exits 0 (accepted, not refused)" "0" "$rc"
  assert_contains "retry with moved mainline: mints attempt A-02" "$out" "A-02"

  local a1_sha a2_sha
  a1_sha="$(python3 -c "import json;print(json.load(open('$repo/.pm/index.json'))['dispatches']['D-030']['attempts']['A-01']['base_sha'])")"
  a2_sha="$(python3 -c "import json;print(json.load(open('$repo/.pm/index.json'))['dispatches']['D-030']['attempts']['A-02']['base_sha'])")"
  assert_eq "retry with moved mainline: attempts.A-01.base_sha == S1 (retained)" "$s1" "$a1_sha"
  assert_eq "retry with moved mainline: attempts.A-02.base_sha == S2 (new attempt's own)" "$s2" "$a2_sha"
  # shellcheck disable=SC2016  # $1 is intentionally expanded inside the bash -c subshell, not here
  assert_true "retry with moved mainline: S1 != S2 (sanity: mainline actually moved)" \
    bash -c '[[ "$1" != "$2" ]]' _ "$s1" "$s2"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: dispatch-prep LOCAL VALIDATION -- a malformed derived field is
# OMITTED (with a stderr warning), never aborts the dispatch.
# ---------------------------------------------------------------------------

section_git_meta_bad_repo_name_omitted() {
  local repo out rc
  repo="$(new_tmp_repo_with_git)"
  local gitrepo
  gitrepo="$(python3 -c "import json;print(json.load(open('$repo/.pm/config.json'))['repos'][0]['path'])")"
  python3 -c "
import json
p = '$repo/.pm/config.json'
cfg = json.load(open(p))
cfg['repos'][0]['name'] = 'bad name'
json.dump(cfg, open(p, 'w'))
"

  out="$(PM_ROOT="$repo" "$DISPATCH_PREP" \
    --dispatch D-031 --issue I-004 \
    --prompt "$repo/prompts/I-004_foo_2026-07-23.md" \
    --tab zzz-test-tab --repo 'bad name' 2>&1)"
  rc=$?
  assert_eq "bad repo name: dispatch still succeeds" "0" "$rc"
  assert_contains "bad repo name: warns on stderr" "$out" "warning:"
  assert_contains "bad repo name: warning names the safe token charset" "$out" "safe token charset"

  local log
  log="$(cat "$repo/.pm/events.log")"
  # shellcheck disable=SC2016  # $1 is intentionally expanded inside the bash -c subshell, not here
  assert_true "bad repo name: DISPATCHED event carries no repo=" \
    bash -c '[[ "$1" != *"repo="* ]]' _ "$log"

  rm -rf "$repo"
}

section_git_meta_bad_mainline_omitted() {
  local repo out rc
  repo="$(new_tmp_repo_with_git)"
  python3 -c "
import json
p = '$repo/.pm/config.json'
cfg = json.load(open(p))
cfg['repos'][0]['mainline'] = 'does-not-exist-branch'
json.dump(cfg, open(p, 'w'))
"

  out="$(PM_ROOT="$repo" "$DISPATCH_PREP" \
    --dispatch D-032 --issue I-004 \
    --prompt "$repo/prompts/I-004_foo_2026-07-23.md" \
    --tab zzz-test-tab --repo demo-repo 2>&1)"
  rc=$?
  assert_eq "bad mainline: dispatch still succeeds" "0" "$rc"
  assert_contains "bad mainline: warns on stderr" "$out" "warning: could not resolve a single commit for base_sha"

  local log
  log="$(cat "$repo/.pm/events.log")"
  assert_contains "bad mainline: DISPATCHED event still carries repo=demo-repo" \
    "$log" "repo=demo-repo"
  # shellcheck disable=SC2016  # $1 is intentionally expanded inside the bash -c subshell, not here
  assert_true "bad mainline: DISPATCHED event carries no base_sha=" \
    bash -c '[[ "$1" != *"base_sha="* ]]' _ "$log"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: branch/issue mismatch -- prompt's leading I-### disagrees with
# --issue: branch is omitted (never the wrong-issue branch name), dispatch
# still succeeds.
# ---------------------------------------------------------------------------

section_git_meta_branch_issue_mismatch() {
  local repo out rc
  repo="$(new_tmp_repo_with_git)"
  printf 'Do the thing. Be self-contained.\n' > "$repo/prompts/I-999_foo_2026-07-24.md"

  out="$(PM_ROOT="$repo" "$DISPATCH_PREP" \
    --dispatch D-033 --issue I-004 \
    --prompt "$repo/prompts/I-999_foo_2026-07-24.md" \
    --tab zzz-test-tab --repo demo-repo 2>&1)"
  rc=$?
  assert_eq "branch/issue mismatch: dispatch still succeeds" "0" "$rc"
  assert_contains "branch/issue mismatch: warns on stderr" "$out" "warning:"
  assert_contains "branch/issue mismatch: warning names I-999 vs I-004" "$out" "I-999"

  local log
  log="$(cat "$repo/.pm/events.log")"
  # shellcheck disable=SC2016  # $1 is intentionally expanded inside the bash -c subshell, not here
  assert_true "branch/issue mismatch: DISPATCHED event carries no branch=" \
    bash -c '[[ "$1" != *"branch="* ]]' _ "$log"
  # shellcheck disable=SC2016  # $1 is intentionally expanded inside the bash -c subshell, not here
  assert_true "branch/issue mismatch: does NOT record i004-foo" \
    bash -c '[[ "$1" != *"i004-foo"* ]]' _ "$log"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: round-10 blocker fix -- a derived branch that PASSES
# `git check-ref-format --branch` but contains a character outside the pm
# event TOKEN charset (comma) must be OMITTED + WARNED, never emitted (a
# charset-illegal token would make pm_apply REFUSE the whole dispatch, an
# abort -- the opposite of the omit+warn contract).
# ---------------------------------------------------------------------------

section_branch_bad_pm_charset_omitted() {
  local repo out rc
  repo="$(new_tmp_repo_with_git)"
  printf 'Do the thing. Be self-contained.\n' > "$repo/prompts/I-004_foo,bar_2026-07-23.md"

  out="$(PM_ROOT="$repo" "$DISPATCH_PREP" \
    --dispatch D-040 --issue I-004 \
    --prompt "$repo/prompts/I-004_foo,bar_2026-07-23.md" \
    --tab zzz-test-tab --repo demo-repo 2>&1)"
  rc=$?
  assert_eq "branch bad pm-charset (comma): dispatch still succeeds" "0" "$rc"
  assert_contains "branch bad pm-charset (comma): warns on stderr" "$out" "warning:"
  assert_contains "branch bad pm-charset (comma): warning names the derived branch" "$out" "i004-foo,bar"

  local log
  log="$(cat "$repo/.pm/events.log")"
  # shellcheck disable=SC2016  # $1 is intentionally expanded inside the bash -c subshell, not here
  assert_true "branch bad pm-charset (comma): DISPATCHED event carries no branch=" \
    bash -c '[[ "$1" != *"branch="* ]]' _ "$log"
  # committed WITHOUT a branch key, but repo= is still present -- omission
  # of one field must not abort the rest of the dispatch.
  assert_contains "branch bad pm-charset (comma): still carries repo=demo-repo" \
    "$log" "repo=demo-repo"

  rm -rf "$repo"
}

section_branch_gitinvalid_dotdot_omitted() {
  local repo out rc
  repo="$(new_tmp_repo_with_git)"
  printf 'Do the thing. Be self-contained.\n' > "$repo/prompts/I-004_foo..bar_2026-07-23.md"

  out="$(PM_ROOT="$repo" "$DISPATCH_PREP" \
    --dispatch D-041 --issue I-004 \
    --prompt "$repo/prompts/I-004_foo..bar_2026-07-23.md" \
    --tab zzz-test-tab --repo demo-repo 2>&1)"
  rc=$?
  assert_eq "branch git-invalid (..): dispatch still succeeds" "0" "$rc"
  assert_contains "branch git-invalid (..): warns on stderr" "$out" "warning:"

  local log
  log="$(cat "$repo/.pm/events.log")"
  # shellcheck disable=SC2016  # $1 is intentionally expanded inside the bash -c subshell, not here
  assert_true "branch git-invalid (..): DISPATCHED event carries no branch=" \
    bash -c '[[ "$1" != *"branch="* ]]' _ "$log"

  rm -rf "$repo"
}

section_branch_gitinvalid_lock_omitted() {
  local repo out rc
  repo="$(new_tmp_repo_with_git)"
  printf 'Do the thing. Be self-contained.\n' > "$repo/prompts/I-004_foo.lock_2026-07-23.md"

  out="$(PM_ROOT="$repo" "$DISPATCH_PREP" \
    --dispatch D-042 --issue I-004 \
    --prompt "$repo/prompts/I-004_foo.lock_2026-07-23.md" \
    --tab zzz-test-tab --repo demo-repo 2>&1)"
  rc=$?
  assert_eq "branch git-invalid (.lock): dispatch still succeeds" "0" "$rc"
  assert_contains "branch git-invalid (.lock): warns on stderr" "$out" "warning:"

  local log
  log="$(cat "$repo/.pm/events.log")"
  # shellcheck disable=SC2016  # $1 is intentionally expanded inside the bash -c subshell, not here
  assert_true "branch git-invalid (.lock): DISPATCHED event carries no branch=" \
    bash -c '[[ "$1" != *"branch="* ]]' _ "$log"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: round-10 medium #3 -- a --prompt whose basename does NOT match
# I-###_<slug>_YYYY-MM-DD.md must warn on stderr (branch omitted for that
# reason), matching the existing omit+warn style.
# ---------------------------------------------------------------------------

section_prompt_basename_no_match_warns() {
  local repo out rc
  repo="$(new_tmp_repo_with_git)"
  printf 'Do the thing. Be self-contained.\n' > "$repo/prompts/not-a-conventional-name.md"

  out="$(PM_ROOT="$repo" "$DISPATCH_PREP" \
    --dispatch D-043 --issue I-004 \
    --prompt "$repo/prompts/not-a-conventional-name.md" \
    --tab zzz-test-tab --repo demo-repo 2>&1)"
  rc=$?
  assert_eq "prompt basename mismatch: dispatch still succeeds" "0" "$rc"
  assert_contains "prompt basename mismatch: warns on stderr" "$out" "warning:"
  assert_contains "prompt basename mismatch: warning names the pattern" "$out" "I-###_<slug>_YYYY-MM-DD.md"

  local log
  log="$(cat "$repo/.pm/events.log")"
  # shellcheck disable=SC2016  # $1 is intentionally expanded inside the bash -c subshell, not here
  assert_true "prompt basename mismatch: DISPATCHED event carries no branch=" \
    bash -c '[[ "$1" != *"branch="* ]]' _ "$log"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# section: round-10 medium #4 -- a repo that resolves in config but has NO
# 'mainline' field at all (distinct from section_git_meta_bad_mainline_omitted,
# where 'mainline' IS present but names a nonexistent branch) must warn on
# stderr and omit base_sha, dispatch still succeeding.
# ---------------------------------------------------------------------------

section_repo_no_mainline_field_warns() {
  local repo out rc
  repo="$(new_tmp_repo_with_git)"
  python3 -c "
import json
p = '$repo/.pm/config.json'
cfg = json.load(open(p))
del cfg['repos'][0]['mainline']
json.dump(cfg, open(p, 'w'))
"

  out="$(PM_ROOT="$repo" "$DISPATCH_PREP" \
    --dispatch D-044 --issue I-004 \
    --prompt "$repo/prompts/I-004_foo_2026-07-23.md" \
    --tab zzz-test-tab --repo demo-repo 2>&1)"
  rc=$?
  assert_eq "repo no mainline field: dispatch still succeeds" "0" "$rc"
  assert_contains "repo no mainline field: warns on stderr" "$out" "warning:"
  assert_contains "repo no mainline field: warning names no mainline field" "$out" "no 'mainline' field"

  local log
  log="$(cat "$repo/.pm/events.log")"
  assert_contains "repo no mainline field: still carries repo=demo-repo" \
    "$log" "repo=demo-repo"
  # shellcheck disable=SC2016  # $1 is intentionally expanded inside the bash -c subshell, not here
  assert_true "repo no mainline field: DISPATCHED event carries no base_sha=" \
    bash -c '[[ "$1" != *"base_sha="* ]]' _ "$log"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------

section_fresh_dispatch
section_refuse_double_dispatch
section_retry_after_failed
section_git_meta_resolvable_repo
section_git_meta_repo_omitted
section_git_meta_repo_path_not_a_git_repo
section_retry_after_failed_with_moved_mainline
section_git_meta_bad_repo_name_omitted
section_git_meta_bad_mainline_omitted
section_git_meta_branch_issue_mismatch
section_branch_bad_pm_charset_omitted
section_branch_gitinvalid_dotdot_omitted
section_branch_gitinvalid_lock_omitted
section_prompt_basename_no_match_warns
section_repo_no_mainline_field_warns

echo "-----------------------------------------"
printf 'PASS: %d  FAIL: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  printf 'Failed: %s\n' "${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
