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
# run
# ---------------------------------------------------------------------------

section_fresh_dispatch
section_refuse_double_dispatch
section_retry_after_failed

echo "-----------------------------------------"
printf 'PASS: %d  FAIL: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  printf 'Failed: %s\n' "${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
