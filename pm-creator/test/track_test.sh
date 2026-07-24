#!/usr/bin/env bash
# Test harness for templates/bin/track --once.
#
# Run: bash test/track_test.sh
# Exits non-zero if any assertion fails; prints PASS/FAIL summary.
# shellcheck disable=SC2016  # intentional: $1/$2/$3 refer to the nested `bash -c`'s own args
set -u

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PM_CREATOR_DIR="$(cd "${THIS_DIR}/.." && pwd)"
LIB="${PM_CREATOR_DIR}/templates/bin/_lib.sh"
TRACK="${PM_CREATOR_DIR}/templates/bin/track"

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
    fail "$name" "command failed: $*"
  fi
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# git_or_die <label> <git-args...> -- runs a single fixture-building git
# command and aborts the WHOLE test run loudly (FATAL, non-zero exit) if it
# fails, instead of letting a broken fixture silently continue into a
# false-green assertion (F7). Use for every git branch/worktree
# add/checkout/commit that builds a fixture and isn't already inside an
# existing `(set -e ...)` guarded block.
git_or_die() {
  local label="$1"
  shift
  if ! git "$@" >&2; then
    echo "FATAL: fixture git setup failed ($label)" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# fixture: a fresh generated PM repo (just enough for bin/track), with
# TRACKER.md materialized exactly like scaffold.sh would render it from
# templates/TRACKER.md.tmpl.
# ---------------------------------------------------------------------------
new_tmp_repo() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-track-test.XXXXXX")"
  mkdir -p "$d/.pm" "$d/bin"
  cp "$LIB" "$d/bin/_lib.sh"
  cp "$TRACK" "$d/bin/track"
  chmod +x "$d/bin/track"
  cat >"$d/TRACKER.md" <<'EOF'
# TRACKER — live session auto-record ledger (narrative surface)

> Human narrative only. Authoritative state is the event log.

<!-- GENERATED:BEGIN tracker -->
(no track ticks recorded yet — run `bin/track --once`)
<!-- GENERATED:END tracker -->
EOF
  printf 'EVENT schema v=1\n' >"$d/.pm/events.log"
  cat >"$d/.pm/config.json" <<'EOF'
{"repos": {}, "herdr_workspace": "zzz-test-ws"}
EOF
  echo "$d"
}

# new_tmp_repo_with_git: same, plus a REAL git work tree ("demo-repo") with a
# mainline branch, for git-corroboration tests.
new_tmp_repo_with_git() {
  local d gitrepo
  d="$(new_tmp_repo)"
  gitrepo="$d/target-repo"
  mkdir -p "$gitrepo"
  (
    set -e
    cd "$gitrepo" || exit 1
    git init -q -b main .
    git config user.email test@example.com
    git config user.name test
    printf 'hello\n' >README.md
    git add README.md
    git commit -q -m 'initial commit'
  ) >&2 || { echo "FATAL: fixture git setup failed (new_tmp_repo_with_git: initial commit)" >&2; exit 1; }
  cat >"$d/.pm/config.json" <<JSON
{"repos": {"demo-repo": {"path": "$gitrepo", "mainline": "main"}}, "herdr_workspace": "zzz-test-ws"}
JSON
  echo "$d"
}

# seed_acked_dispatch <repo> <d> <issue> <tab> [<branch> <base_sha>]
# Seeds dispatch_new -> dispatch_state(DISPATCHED, w/ optional git meta) ->
# dispatch_state(ACKED, w/ tab) via the real enforcement engine (pm_apply),
# so the resulting index.json is exactly what a legitimate dispatch-prep +
# record round trip would produce.
seed_acked_dispatch() {
  local repo="$1" d="$2" issue="$3" tab="$4" branch="${5:-}" base_sha="${6:-}"
  PM_ROOT="$repo" pm_apply dispatch_new d="$d" i="$issue" at="$(now_iso)" >/dev/null
  if [[ -n "$branch" ]]; then
    PM_ROOT="$repo" pm_apply dispatch_state d="$d" from=READY to=DISPATCHED lane=human \
      at="$(now_iso)" repo=demo-repo branch="$branch" base_sha="$base_sha" >/dev/null
  else
    PM_ROOT="$repo" pm_apply dispatch_state d="$d" from=READY to=DISPATCHED lane=human \
      at="$(now_iso)" >/dev/null
  fi
  PM_ROOT="$repo" pm_apply dispatch_state d="$d" a=A-01 from=DISPATCHED to=ACKED lane=human \
    at="$(now_iso)" tab="$tab" >/dev/null
}

# run_track <repo_dir> [fixture_json] -- runs bin/track --once with
# cwd=<repo_dir>, herdr shadowed as a local function returning the given
# snapshot fixture JSON (or "herdr absent" if no fixture given), never
# touching the real herdr binary / live workspace w1.
run_track() {
  local repo="$1" fixture="${2:-}"
  if [[ -n "$fixture" ]]; then
    local fixture_file
    fixture_file="$(mktemp "${TMPDIR:-/tmp}/pm-creator-track-snapshot.XXXXXX")"
    printf '%s' "$fixture" >"$fixture_file"
    # shellcheck disable=SC2034  # TR_OUT is set for ad-hoc debugging (print on failure), not asserted on
    TR_OUT="$(
      cd "$repo" && \
      HERDR_SNAPSHOT_FIXTURE="$fixture_file" \
      PATH="/usr/bin:/bin" \
      bash -c '
        # shellcheck disable=SC2317,SC2329  # invoked indirectly by bin/track
        herdr() {
          case "$1 $2" in
            "api snapshot") cat "$HERDR_SNAPSHOT_FIXTURE" ;;
            *) return 1 ;;
          esac
        }
        export -f herdr
        bash bin/track --once
      ' 2>&1
    )"
    TR_RC=$?
    rm -f "$fixture_file"
  else
    # shellcheck disable=SC2034  # TR_OUT is set for ad-hoc debugging (print on failure), not asserted on
    TR_OUT="$(cd "$repo" && PATH="/usr/bin:/bin" bash bin/track --once 2>&1)"
    TR_RC=$?
  fi
}

snapshot_json() {
  # snapshot_json <tab_id> <agent_status> [<label>]
  # Every tab is always embedded in the "zzz-test-ws" workspace (matching
  # every fixture's configured herdr_workspace) so plain status/existence
  # cases don't also have to fight the F5 workspace filter.
  local tab="$1" status="$2" label="${3:-}"
  if [[ -n "$label" ]]; then
    printf '{"result": {"tabs": [{"tab_id": "%s", "agent_status": "%s", "label": "%s", "workspace_id": "zzz-test-ws"}]}}' \
      "$tab" "$status" "$label"
  else
    printf '{"result": {"tabs": [{"tab_id": "%s", "agent_status": "%s", "workspace_id": "zzz-test-ws"}]}}' "$tab" "$status"
  fi
}

# ---------------------------------------------------------------------------
# 1. Fully corroborated `done` tab -> auto-records RETURNED intake only.
# ---------------------------------------------------------------------------
section_fully_corroborated_records_returned() {
  local repo tip result_sha state status
  repo="$(new_tmp_repo_with_git)"
  local gitrepo="$repo/target-repo"
  local base_sha
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"

  git_or_die "fully-corroborated: branch i900-widget" -C "$gitrepo" branch i900-widget
  git_or_die "fully-corroborated: worktree add wt-900" -C "$gitrepo" worktree add -q "$repo/wt-900" i900-widget
  (
    set -e
    cd "$repo/wt-900" || exit 1
    printf 'more\n' >>README.md
    git add README.md
    git commit -q -m 'widget work'
  ) >&2 || { echo "FATAL: fixture git setup failed (fully-corroborated: widget commit)" >&2; exit 1; }
  tip="$(git -C "$repo/wt-900" rev-parse HEAD)"

  seed_acked_dispatch "$repo" D-900 I-900 zzz-test-tab-900 i900-widget "$base_sha"

  run_track "$repo" "$(snapshot_json zzz-test-tab-900 "done" "i900-widget")"
  assert_eq "fully corroborated: exit 0" "0" "$TR_RC"

  result_sha="$(python3 -c "
import json
idx = json.load(open('$repo/.pm/index.json'))
d = idx['dispatches']['D-900']
print(d.get('result_sha', ''))
" 2>/dev/null)"
  state="$(python3 -c "
import json
idx = json.load(open('$repo/.pm/index.json'))
print(idx['dispatches']['D-900']['state'])
")"
  status="$state"
  assert_eq "fully corroborated: dispatch state is RETURNED (intake only, not VERIFIED)" \
    "RETURNED" "$status"
  assert_eq "fully corroborated: result_sha == branch tip" "$tip" "$result_sha"

  assert_true "fully corroborated: recorded in TRACKER.md" \
    bash -c 'grep -q "D-900" "$1/TRACKER.md"' _ "$repo"
  assert_true "fully corroborated: exactly one result event appended" \
    bash -c '[[ "$(grep -c "^EVENT result d=D-900" "$1/.pm/events.log")" == "1" ]]' _ "$repo"

  git -C "$gitrepo" worktree remove --force "$repo/wt-900" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# 2. Each surface-only case is surfaced, never recorded.
# ---------------------------------------------------------------------------

assert_surfaced_not_recorded() {
  # assert_surfaced_not_recorded <label> <repo> <dispatch_id> <reason_substr>
  local label="$1" repo="$2" d="$3" reason="$4"
  assert_true "$label: exit 0 (informational, not fatal)" \
    bash -c '[[ "$1" == "0" ]]' _ "$TR_RC"
  assert_true "$label: surfaced in TRACKER.md with reason '$reason'" \
    bash -c 'grep -q "$1" "$2/TRACKER.md" && grep -q "$3" "$2/TRACKER.md"' _ "$d" "$repo" "$reason"
  assert_true "$label: no result event appended" \
    bash -c '[[ "$(grep -c "^EVENT result d=$1 " "$2/.pm/events.log" || true)" == "0" ]]' \
    _ "$d" "$repo"
}

section_surface_missing_metadata() {
  local repo
  repo="$(new_tmp_repo)"
  seed_acked_dispatch "$repo" D-910 I-910 zzz-test-tab-910
  run_track "$repo" "$(snapshot_json zzz-test-tab-910 "done")"
  assert_surfaced_not_recorded "missing-metadata" "$repo" "D-910" "missing-metadata"
  rm -rf "$repo"
}

section_surface_repo_not_configured() {
  local repo
  repo="$(new_tmp_repo)"
  # config.json has no "repos" entry named demo-repo at all
  cat >"$repo/.pm/config.json" <<'EOF'
{"repos": {}, "herdr_workspace": "zzz-test-ws"}
EOF
  seed_acked_dispatch "$repo" D-911 I-911 zzz-test-tab-911 i911-x deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  run_track "$repo" "$(snapshot_json zzz-test-tab-911 "done" "i911-x")"
  assert_surfaced_not_recorded "repo-not-configured" "$repo" "D-911" "repo-not-configured"
  rm -rf "$repo"
}

section_surface_base_sha_unreachable() {
  local repo gitrepo
  repo="$(new_tmp_repo_with_git)"
  gitrepo="$repo/target-repo"
  git_or_die "base-sha-unreachable: branch i912-x" -C "$gitrepo" branch i912-x
  seed_acked_dispatch "$repo" D-912 I-912 zzz-test-tab-912 i912-x deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  run_track "$repo" "$(snapshot_json zzz-test-tab-912 "done" "i912-x")"
  assert_surfaced_not_recorded "base-sha-unreachable" "$repo" "D-912" "base-sha-unreachable"
  rm -rf "$repo"
}

section_surface_branch_missing() {
  local repo gitrepo base_sha
  repo="$(new_tmp_repo_with_git)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  seed_acked_dispatch "$repo" D-913 I-913 zzz-test-tab-913 i913-nonexistent "$base_sha"
  run_track "$repo" "$(snapshot_json zzz-test-tab-913 "done" "i913-nonexistent")"
  assert_surfaced_not_recorded "branch-missing" "$repo" "D-913" "branch-missing"
  rm -rf "$repo"
}

section_surface_dirty_worktree() {
  local repo gitrepo base_sha
  repo="$(new_tmp_repo_with_git)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  git_or_die "dirty-worktree: branch i914-dirty" -C "$gitrepo" branch i914-dirty
  git_or_die "dirty-worktree: worktree add wt-914" -C "$gitrepo" worktree add -q "$repo/wt-914" i914-dirty
  (
    set -e
    cd "$repo/wt-914" || exit 1
    printf 'wip\n' >>README.md
    git add README.md
    git commit -q -m 'real work'
    printf 'uncommitted\n' >>README.md
  ) >&2 || { echo "FATAL: fixture git setup failed (dirty-worktree: real + uncommitted work)" >&2; exit 1; }
  seed_acked_dispatch "$repo" D-914 I-914 zzz-test-tab-914 i914-dirty "$base_sha"
  run_track "$repo" "$(snapshot_json zzz-test-tab-914 "done" "i914-dirty")"
  assert_surfaced_not_recorded "dirty-worktree" "$repo" "D-914" "dirty-worktree"
  git -C "$gitrepo" worktree remove --force "$repo/wt-914" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

section_surface_no_new_commit() {
  local repo gitrepo base_sha
  repo="$(new_tmp_repo_with_git)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  git_or_die "no-new-commit: branch i915-noop" -C "$gitrepo" branch i915-noop
  git_or_die "no-new-commit: worktree add wt-915" -C "$gitrepo" worktree add -q "$repo/wt-915" i915-noop
  seed_acked_dispatch "$repo" D-915 I-915 zzz-test-tab-915 i915-noop "$base_sha"
  run_track "$repo" "$(snapshot_json zzz-test-tab-915 "done" "i915-noop")"
  assert_surfaced_not_recorded "no-new-commit" "$repo" "D-915" "no-new-commit"
  git -C "$gitrepo" worktree remove --force "$repo/wt-915" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

section_surface_not_descendant() {
  local repo gitrepo base_sha
  repo="$(new_tmp_repo_with_git)"
  gitrepo="$repo/target-repo"
  # A base_sha that exists in the repo but is NOT an ancestor of the
  # worker's branch tip (a sibling branch cut from the same root, then the
  # worker's branch built as an independent line of history). Both branches
  # are given their OWN worktree via `worktree add -b`, so neither is ever
  # checked out in the primary worktree -- `worktree add` refuses to add a
  # worktree for a branch that's already checked out elsewhere (F7: this
  # used to silently fail setup because i916-worker was checked out in the
  # primary worktree when `worktree add` for wt-916 ran).
  git_or_die "not-descendant: worktree add -b i916-sibling" \
    -C "$gitrepo" worktree add -q -b i916-sibling "$repo/wt-916-sibling" main
  (
    set -e
    cd "$repo/wt-916-sibling" || exit 1
    printf 'sibling\n' >>README.md
    git add README.md
    git commit -q -m 'sibling commit'
  ) >&2 || { echo "FATAL: fixture git setup failed (not-descendant: sibling commit)" >&2; exit 1; }
  base_sha="$(git -C "$gitrepo" rev-parse i916-sibling)"

  git_or_die "not-descendant: worktree add -b i916-worker" \
    -C "$gitrepo" worktree add -q -b i916-worker "$repo/wt-916" main
  (
    set -e
    cd "$repo/wt-916" || exit 1
    printf 'unrelated\n' >>README.md
    git add README.md
    git commit -q -m 'unrelated work, not based on i916-sibling'
  ) >&2 || { echo "FATAL: fixture git setup failed (not-descendant: worker commit)" >&2; exit 1; }

  seed_acked_dispatch "$repo" D-916 I-916 zzz-test-tab-916 i916-worker "$base_sha"
  run_track "$repo" "$(snapshot_json zzz-test-tab-916 "done" "i916-worker")"
  assert_surfaced_not_recorded "not-descendant" "$repo" "D-916" "not-descendant"
  git -C "$gitrepo" worktree remove --force "$repo/wt-916" >/dev/null 2>&1 || true
  git -C "$gitrepo" worktree remove --force "$repo/wt-916-sibling" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

section_surface_worktree_missing() {
  local repo gitrepo base_sha
  repo="$(new_tmp_repo_with_git)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  # Branch exists but no worktree has it checked out.
  git_or_die "worktree-missing: branch i917-nowt" -C "$gitrepo" branch i917-nowt
  seed_acked_dispatch "$repo" D-917 I-917 zzz-test-tab-917 i917-nowt "$base_sha"
  run_track "$repo" "$(snapshot_json zzz-test-tab-917 "done" "i917-nowt")"
  assert_surfaced_not_recorded "worktree-missing" "$repo" "D-917" "worktree-missing"
  rm -rf "$repo"
}

section_surface_herdr_unavailable() {
  local repo gitrepo base_sha
  repo="$(new_tmp_repo_with_git)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  git_or_die "herdr-unavailable: branch i918-x" -C "$gitrepo" branch i918-x
  git_or_die "herdr-unavailable: worktree add wt-918" -C "$gitrepo" worktree add -q "$repo/wt-918" i918-x
  seed_acked_dispatch "$repo" D-918 I-918 zzz-test-tab-918 i918-x "$base_sha"
  # No fixture given -> herdr is absent from PATH entirely -> degrade
  # gracefully rather than hard-fail (deliberate divergence from reconcile).
  run_track "$repo"
  assert_eq "herdr-unavailable: exit 0 (degrade gracefully, not fatal)" "0" "$TR_RC"
  assert_true "herdr-unavailable: TRACKER.md notes herdr unavailable" \
    bash -c 'grep -qi "herdr" "$1/TRACKER.md" && grep -qi "unavailable" "$1/TRACKER.md"' _ "$repo"
  assert_true "herdr-unavailable: D-918 surfaced with reason herdr-unavailable" \
    bash -c 'grep -q "D-918" "$1/TRACKER.md" && grep -q "herdr-unavailable" "$1/TRACKER.md"' _ "$repo"
  assert_true "herdr-unavailable: no result event appended" \
    bash -c '[[ "$(grep -c "^EVENT result d=D-918 " "$1/.pm/events.log" || true)" == "0" ]]' _ "$repo"
  git -C "$gitrepo" worktree remove --force "$repo/wt-918" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# 3. Idempotent re-tick: second `track --once` re-renders an identical
# TRACKER.md block, and a same-tick duplicate corroborated dispatch cannot
# be double-recorded.
# ---------------------------------------------------------------------------
section_idempotent_retick() {
  local repo gitrepo base_sha tracker_after_1 tracker_after_2 result_count

  # --- 3a. Genuinely unchanged state (surface-only, dirty worktree) run
  # twice in a row: track/render is a pure function of index/snapshot/git,
  # so nothing here changes between ticks -> TRACKER.md must re-render
  # byte-identical both times, and neither tick records anything.
  repo="$(new_tmp_repo_with_git)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  git_or_die "idempotent 3a: branch i921-x" -C "$gitrepo" branch i921-x
  git_or_die "idempotent 3a: worktree add wt-921" -C "$gitrepo" worktree add -q "$repo/wt-921" i921-x
  (
    set -e
    cd "$repo/wt-921" || exit 1
    printf 'work\n' >>README.md
    git add README.md
    git commit -q -m 'work'
    printf 'dirty\n' >>README.md
  ) >&2 || { echo "FATAL: fixture git setup failed (idempotent 3a: dirty commit)" >&2; exit 1; }
  seed_acked_dispatch "$repo" D-921 I-921 zzz-test-tab-921 i921-x "$base_sha"

  run_track "$repo" "$(snapshot_json zzz-test-tab-921 "done" "i921-x")"
  assert_eq "idempotent: unchanged-state first tick exit 0" "0" "$TR_RC"
  tracker_after_1="$(cat "$repo/TRACKER.md")"
  result_count="$(grep -c "^EVENT result d=D-921" "$repo/.pm/events.log")"
  assert_eq "idempotent: unchanged-state first tick records nothing" "0" "$result_count"

  run_track "$repo" "$(snapshot_json zzz-test-tab-921 "done" "i921-x")"
  assert_eq "idempotent: unchanged-state second tick exit 0" "0" "$TR_RC"
  tracker_after_2="$(cat "$repo/TRACKER.md")"
  # The rendered block's only per-tick-varying content is the "_last tick:
  # <timestamp>_" footer (wall-clock, informational); everything else is a
  # pure function of index/snapshot/git and must be byte-identical when
  # those inputs are unchanged.
  assert_eq "idempotent: TRACKER.md re-renders byte-identical on unchanged state (modulo timestamp)" \
    "$(grep -v '^_last tick:' <<<"$tracker_after_1")" \
    "$(grep -v '^_last tick:' <<<"$tracker_after_2")"
  result_count="$(grep -c "^EVENT result d=D-921" "$repo/.pm/events.log")"
  assert_eq "idempotent: unchanged-state second tick still records nothing" "0" "$result_count"

  git -C "$gitrepo" worktree remove --force "$repo/wt-921" >/dev/null 2>&1 || true
  rm -rf "$repo"

  # --- 3b. A corroborated dispatch is auto-recorded exactly once even if
  # `track --once` is re-run after the fact (dispatch is RETURNED, not
  # ACKED, on the second tick -> no longer a stage-1 candidate at all, so
  # it cannot be double-recorded; this is the "no double-record" guarantee,
  # not a byte-identical-render guarantee).
  repo="$(new_tmp_repo_with_git)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  git_or_die "idempotent 3b: branch i920-x" -C "$gitrepo" branch i920-x
  git_or_die "idempotent 3b: worktree add wt-920" -C "$gitrepo" worktree add -q "$repo/wt-920" i920-x
  (
    set -e
    cd "$repo/wt-920" || exit 1
    printf 'work\n' >>README.md
    git add README.md
    git commit -q -m 'work'
  ) >&2 || { echo "FATAL: fixture git setup failed (idempotent 3b: work commit)" >&2; exit 1; }
  seed_acked_dispatch "$repo" D-920 I-920 zzz-test-tab-920 i920-x "$base_sha"

  run_track "$repo" "$(snapshot_json zzz-test-tab-920 "done" "i920-x")"
  assert_eq "idempotent: first tick exit 0" "0" "$TR_RC"
  result_count="$(grep -c "^EVENT result d=D-920" "$repo/.pm/events.log")"
  assert_eq "idempotent: exactly one result event after first tick" "1" "$result_count"

  # Second tick: dispatch is now RETURNED, not ACKED -> no longer a
  # candidate at all; the snapshot still shows the tab "done".
  run_track "$repo" "$(snapshot_json zzz-test-tab-920 "done" "i920-x")"
  assert_eq "idempotent: second tick exit 0" "0" "$TR_RC"
  result_count="$(grep -c "^EVENT result d=D-920" "$repo/.pm/events.log")"
  assert_eq "idempotent: still exactly one result event after second tick (no double-record)" \
    "1" "$result_count"

  git -C "$gitrepo" worktree remove --force "$repo/wt-920" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# 4. Missing-metadata dispatch surfaced (covered above as
#    section_surface_missing_metadata; kept as its own named section per the
#    brief's enumerated minimum coverage list).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 5. Forged/mismatched metadata: index.json claims a repo/branch/base_sha
# that do not correspond to real git state (seeded via pm_raw_append,
# bypassing dispatch-prep's own resolution step but still grammar-valid) --
# must be surfaced via track's OWN independent re-resolve against real git,
# never recorded, never trusted from the index.
# ---------------------------------------------------------------------------
section_forged_metadata_surfaced() {
  local repo gitrepo
  repo="$(new_tmp_repo_with_git)"
  gitrepo="$repo/target-repo"
  git_or_die "forged-metadata: branch i921-real" -C "$gitrepo" branch i921-real
  git_or_die "forged-metadata: worktree add wt-921" -C "$gitrepo" worktree add -q "$repo/wt-921" i921-real

  PM_ROOT="$repo" pm_apply dispatch_new d=D-921 i=I-921 at="$(now_iso)" >/dev/null
  # Forge a base_sha that looks well-formed (40 hex chars, passes grammar)
  # but does not exist in the real repo at all.
  PM_ROOT="$repo" pm_apply dispatch_state d=D-921 from=READY to=DISPATCHED lane=human \
    at="$(now_iso)" repo=demo-repo branch=i921-real \
    base_sha=cafefacecafefacecafefacecafefacecafeface >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-921 a=A-01 from=DISPATCHED to=ACKED lane=human \
    at="$(now_iso)" tab=zzz-test-tab-921 >/dev/null

  run_track "$repo" "$(snapshot_json zzz-test-tab-921 "done" "i921-real")"
  assert_surfaced_not_recorded "forged base_sha" "$repo" "D-921" "base-sha-unreachable"

  git -C "$gitrepo" worktree remove --force "$repo/wt-921" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# 6. `working`/`blocked` tab statuses are ignored: never surfaced, never
# recorded (only `done` tabs are evaluated at all this tick).
# ---------------------------------------------------------------------------
section_working_blocked_ignored() {
  local repo gitrepo base_sha
  repo="$(new_tmp_repo_with_git)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  git_or_die "working-blocked: branch i922-w" -C "$gitrepo" branch i922-w
  git_or_die "working-blocked: worktree add wt-922" -C "$gitrepo" worktree add -q "$repo/wt-922" i922-w
  git_or_die "working-blocked: branch i923-b" -C "$gitrepo" branch i923-b
  git_or_die "working-blocked: worktree add wt-923" -C "$gitrepo" worktree add -q "$repo/wt-923" i923-b

  seed_acked_dispatch "$repo" D-922 I-922 zzz-test-tab-922 i922-w "$base_sha"
  seed_acked_dispatch "$repo" D-923 I-923 zzz-test-tab-923 i923-b "$base_sha"

  local fixture
  fixture='{"result": {"tabs": [
    {"tab_id": "zzz-test-tab-922", "agent_status": "working", "workspace_id": "zzz-test-ws"},
    {"tab_id": "zzz-test-tab-923", "agent_status": "blocked", "workspace_id": "zzz-test-ws"}
  ]}}'
  run_track "$repo" "$fixture"
  assert_eq "working/blocked: exit 0" "0" "$TR_RC"
  assert_true "working/blocked: D-922 (working) not mentioned in TRACKER.md" \
    bash -c '! grep -q "D-922" "$1/TRACKER.md"' _ "$repo"
  assert_true "working/blocked: D-923 (blocked) not mentioned in TRACKER.md" \
    bash -c '! grep -q "D-923" "$1/TRACKER.md"' _ "$repo"
  assert_true "working/blocked: no result event appended for D-922" \
    bash -c '[[ "$(grep -c "^EVENT result d=D-922 " "$1/.pm/events.log" || true)" == "0" ]]' _ "$repo"
  assert_true "working/blocked: no result event appended for D-923" \
    bash -c '[[ "$(grep -c "^EVENT result d=D-923 " "$1/.pm/events.log" || true)" == "0" ]]' _ "$repo"
  local d922_state d923_state
  d922_state="$(python3 -c "import json;print(json.load(open('$repo/.pm/index.json'))['dispatches']['D-922']['state'])")"
  d923_state="$(python3 -c "import json;print(json.load(open('$repo/.pm/index.json'))['dispatches']['D-923']['state'])")"
  assert_eq "working/blocked: D-922 still ACKED (never touched)" "ACKED" "$d922_state"
  assert_eq "working/blocked: D-923 still ACKED (never touched)" "ACKED" "$d923_state"

  git -C "$gitrepo" worktree remove --force "$repo/wt-922" >/dev/null 2>&1 || true
  git -C "$gitrepo" worktree remove --force "$repo/wt-923" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# 7. F3: base_sha must be a literal object SHA, never a revision expression.
# ---------------------------------------------------------------------------
section_surface_base_sha_not_a_sha_head() {
  local repo gitrepo
  repo="$(new_tmp_repo_with_git)"
  gitrepo="$repo/target-repo"
  git_or_die "base_sha-not-a-sha (HEAD): branch i930-x" -C "$gitrepo" branch i930-x
  seed_acked_dispatch "$repo" D-930 I-930 zzz-test-tab-930 i930-x "HEAD"
  run_track "$repo" "$(snapshot_json zzz-test-tab-930 "done" "i930-x")"
  assert_surfaced_not_recorded "base_sha-not-a-sha (HEAD)" "$repo" "D-930" "sha-not-a-sha"
  rm -rf "$repo"
}

section_surface_base_sha_not_a_sha_branch_expr() {
  local repo gitrepo
  repo="$(new_tmp_repo_with_git)"
  gitrepo="$repo/target-repo"
  git_or_die "base_sha-not-a-sha (main): branch i931-x" -C "$gitrepo" branch i931-x
  seed_acked_dispatch "$repo" D-931 I-931 zzz-test-tab-931 i931-x "main"
  run_track "$repo" "$(snapshot_json zzz-test-tab-931 "done" "i931-x")"
  assert_surfaced_not_recorded "base_sha-not-a-sha (main)" "$repo" "D-931" "sha-not-a-sha"
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# 8. F1: refuse recording on mainline or a non-ticket branch.
# ---------------------------------------------------------------------------
section_surface_branch_is_mainline() {
  local repo gitrepo base_sha
  repo="$(new_tmp_repo_with_git)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  seed_acked_dispatch "$repo" D-932 I-932 zzz-test-tab-932 main "$base_sha"
  run_track "$repo" "$(snapshot_json zzz-test-tab-932 "done" "main")"
  assert_surfaced_not_recorded "branch-is-mainline" "$repo" "D-932" "branch-is-mainline"
  rm -rf "$repo"
}

section_surface_branch_not_a_ticket_branch() {
  local repo gitrepo base_sha
  repo="$(new_tmp_repo_with_git)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  git_or_die "branch-not-a-ticket-branch: branch feature-x" -C "$gitrepo" branch feature-x
  seed_acked_dispatch "$repo" D-933 I-933 zzz-test-tab-933 feature-x "$base_sha"
  run_track "$repo" "$(snapshot_json zzz-test-tab-933 "done" "feature-x")"
  assert_surfaced_not_recorded "branch-not-a-ticket-branch" "$repo" "D-933" "branch-not-a-ticket-branch"
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# 9. F5: positive tab-binding required (label present AND ticket-prefix
# matches the branch); absent/reused/mismatched labels are unconfirmed.
# ---------------------------------------------------------------------------
section_surface_tab_binding_unconfirmed_absent_label() {
  local repo gitrepo base_sha
  repo="$(new_tmp_repo_with_git)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  git_or_die "tab-binding-unconfirmed (absent label): branch i934-x" -C "$gitrepo" branch i934-x
  seed_acked_dispatch "$repo" D-934 I-934 zzz-test-tab-934 i934-x "$base_sha"
  run_track "$repo" "$(snapshot_json zzz-test-tab-934 "done")"
  assert_surfaced_not_recorded "tab-binding-unconfirmed (absent label)" "$repo" "D-934" "tab-binding-unconfirmed"
  rm -rf "$repo"
}

section_surface_tab_binding_unconfirmed_mismatched_label() {
  local repo gitrepo base_sha
  repo="$(new_tmp_repo_with_git)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  git_or_die "tab-binding-unconfirmed (mismatched label): branch i935-x" -C "$gitrepo" branch i935-x
  seed_acked_dispatch "$repo" D-935 I-935 zzz-test-tab-935 i935-x "$base_sha"
  # tab reused/mislabeled for a different ticket -- looks bound, isn't.
  run_track "$repo" "$(snapshot_json zzz-test-tab-935 "done" "i999-other")"
  assert_surfaced_not_recorded "tab-binding-unconfirmed (mismatched label)" "$repo" "D-935" "tab-binding-unconfirmed"
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# 10. F5/F6: tab present in the snapshot but outside the configured
# herdr_workspace -- filtered out of the workspace map, so it's exactly as
# absent as if herdr never reported it -> status-unknown (herdr itself is
# fine this tick; this specific tab just isn't in-workspace).
# ---------------------------------------------------------------------------
section_surface_status_unknown_wrong_workspace() {
  local repo gitrepo base_sha fixture
  repo="$(new_tmp_repo_with_git)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  git_or_die "status-unknown (wrong workspace): branch i936-x" -C "$gitrepo" branch i936-x
  seed_acked_dispatch "$repo" D-936 I-936 zzz-test-tab-936 i936-x "$base_sha"
  fixture='{"result": {"tabs": [{"tab_id": "zzz-test-tab-936", "agent_status": "done", "label": "i936-x", "workspace_id": "some-other-ws"}]}}'
  run_track "$repo" "$fixture"
  assert_surfaced_not_recorded "status-unknown (wrong workspace)" "$repo" "D-936" "status-unknown"
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# 10b. herdr is on PATH and `herdr api snapshot` exits 0, but the raw output
# is malformed (unparseable) JSON -- distinct from the wrong-workspace case
# above (herdr fine, snapshot parses, this tab just isn't in it): here the
# snapshot itself never parsed, so herdr must be treated as UNAVAILABLE this
# tick and the dispatch must surface herdr-unavailable, never status-unknown.
# ---------------------------------------------------------------------------
section_surface_herdr_unavailable_malformed_snapshot() {
  local repo gitrepo base_sha
  repo="$(new_tmp_repo_with_git)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  git_or_die "herdr-unavailable (malformed snapshot): branch i952-x" -C "$gitrepo" branch i952-x
  git_or_die "herdr-unavailable (malformed snapshot): worktree add wt-952" -C "$gitrepo" worktree add -q "$repo/wt-952" i952-x
  seed_acked_dispatch "$repo" D-952 I-952 zzz-test-tab-952 i952-x "$base_sha"
  run_track "$repo" 'not-json{{{'
  assert_eq "herdr-unavailable (malformed snapshot): exit 0 (degrade gracefully, not fatal)" "0" "$TR_RC"
  assert_true "herdr-unavailable (malformed snapshot): D-952 surfaced with reason herdr-unavailable" \
    bash -c 'grep -q "D-952" "$1/TRACKER.md" && grep -q "herdr-unavailable" "$1/TRACKER.md"' _ "$repo"
  assert_true "herdr-unavailable (malformed snapshot): NOT surfaced as status-unknown" \
    bash -c '! (grep -q "D-952" "$1/TRACKER.md" && grep -A2 "D-952" "$1/TRACKER.md" | grep -q "status-unknown")' _ "$repo"
  assert_true "herdr-unavailable (malformed snapshot): no result event appended" \
    bash -c '[[ "$(grep -c "^EVENT result d=D-952 " "$1/.pm/events.log" || true)" == "0" ]]' _ "$repo"
  git -C "$gitrepo" worktree remove --force "$repo/wt-952" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# 11. F2: stage 2 re-runs git corroboration fresh UNDER the lock; a change
# introduced at exactly that moment must surface, never record on stage 1's
# now-stale read. NEW-High fix: `bin/track` no longer has ANY test seam
# (the old PM_TR_TEST_STAGE2_HOOK env-driven `bash -c "${...}"` was itself an
# RCE risk in a template shipped into every generated PM repo, and has been
# removed from templates/bin/track entirely). This test instead drifts the
# repo via a test-side `git` shim -- see the section body below for exactly
# how it's scoped and why a shell function alone would not work here.
# ---------------------------------------------------------------------------
section_surface_corroboration_changed_under_lock() {
  local repo gitrepo base_sha shim_state shim_bin fixture_file
  repo="$(new_tmp_repo_with_git)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  git_or_die "corroboration-changed-under-lock: branch i937-x" -C "$gitrepo" branch i937-x
  git_or_die "corroboration-changed-under-lock: worktree add wt-937" -C "$gitrepo" worktree add -q "$repo/wt-937" i937-x
  (
    set -e
    cd "$repo/wt-937" || exit 1
    printf 'more\n' >>README.md
    git add README.md
    git commit -q -m 'work'
  ) >&2 || { echo "FATAL: fixture git setup failed (corroboration-changed-under-lock)" >&2; exit 1; }

  seed_acked_dispatch "$repo" D-937 I-937 zzz-test-tab-937 i937-x "$base_sha"

  # A real, single-purpose `git` *executable* is placed FIRST on PATH for
  # just this one `bin/track --once` invocation -- a bash function (like the
  # `herdr` shadow `run_track` normally uses) would NOT work here: `bin/track`
  # runs its git corroboration via python's `subprocess.run(["git", ...])`,
  # which does a PATH lookup for a real binary and never sees exported shell
  # functions. The shim delegates every call straight to the real
  # /usr/bin/git; it only mutates the worktree on the 2nd
  # `git worktree list --porcelain` call scoped to THIS test's own repo path
  # (stage 1's pre-lock read is the 1st such call, stage 2's under-lock
  # recheck is the 2nd), and only that once (a fired-sentinel file), so
  # stage 1 still observes CLEAN (passes) and stage 2 observes DIRTY (must
  # surface). All shim state lives under fresh per-test tmpdirs, removed at
  # the end of this function; PATH is otherwise the same restricted
  # "/usr/bin:/bin" every other run_track call uses. No other test/section is
  # affected, and the production template never gains this (or any) seam.
  shim_state="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-track-f2-state.XXXXXX")"
  shim_bin="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-track-f2-bin.XXXXXX")"
  printf '%s' "$gitrepo" >"$shim_state/target_repo"
  cat >"$shim_bin/git" <<'SHIM'
#!/usr/bin/env bash
# F2 test-only, single-fire git shim (see track_test.sh's
# section_surface_corroboration_changed_under_lock for the full rationale).
# Delegates every call to the REAL git; on the 2nd "worktree list
# --porcelain" call scoped to the target repo, and only that once, it
# appends a dirty line to the worktree BEFORE delegating.
set -u
real_git=/usr/bin/git
state_dir="${TR_F2_STATE_DIR:?}"
wt_readme="${TR_F2_WT_README:?}"
if [[ "${1:-}" == "worktree" && "${2:-}" == "list" ]]; then
  here="$(pwd -P)"
  target="$(cat "$state_dir/target_repo" 2>/dev/null || true)"
  if [[ "$here" == "$target" && ! -f "$state_dir/fired" ]]; then
    n=$(( $(cat "$state_dir/counter" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" >"$state_dir/counter"
    if [[ "$n" -ge 2 ]]; then
      printf 'dirty-under-lock\n' >>"$wt_readme"
      : >"$state_dir/fired"
    fi
  fi
fi
exec "$real_git" "$@"
SHIM
  chmod +x "$shim_bin/git"

  fixture_file="$(mktemp "${TMPDIR:-/tmp}/pm-creator-track-snapshot.XXXXXX")"
  printf '%s' "$(snapshot_json zzz-test-tab-937 "done" "i937-x")" >"$fixture_file"
  # shellcheck disable=SC2034  # TR_OUT is set for ad-hoc debugging (print on failure), not asserted on
  TR_OUT="$(
    cd "$repo" && \
    HERDR_SNAPSHOT_FIXTURE="$fixture_file" \
    TR_F2_STATE_DIR="$shim_state" \
    TR_F2_WT_README="$repo/wt-937/README.md" \
    PATH="$shim_bin:/usr/bin:/bin" \
    bash -c '
      # shellcheck disable=SC2317,SC2329  # invoked indirectly by bin/track
      herdr() {
        case "$1 $2" in
          "api snapshot") cat "$HERDR_SNAPSHOT_FIXTURE" ;;
          *) return 1 ;;
        esac
      }
      export -f herdr
      bash bin/track --once
    ' 2>&1
  )"
  TR_RC=$?
  rm -f "$fixture_file"
  rm -rf "$shim_state" "$shim_bin"

  assert_surfaced_not_recorded "corroboration-changed-under-lock" "$repo" "D-937" "corroboration-changed-under-lock"

  git -C "$gitrepo" worktree remove --force "$repo/wt-937" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# 12. F1: the branch's ticket number must equal the dispatch's OWN linked
# issue number (re-derived from the raw event log), not just "look like" a
# ticket branch -- a branch for a DIFFERENT issue must surface, never
# record. The dead `^i(\d+)$` regex (F1, pre-fix) could never match the
# stored `I-<digits>` form at all, so this mismatch previously fell through
# uncaught.
# ---------------------------------------------------------------------------
section_surface_branch_issue_mismatch() {
  local repo gitrepo base_sha
  repo="$(new_tmp_repo_with_git)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  git_or_die "branch-issue-mismatch: branch i999-x" -C "$gitrepo" branch i999-x
  # Dispatch is linked to issue I-123, but its branch is a ticket branch for
  # a DIFFERENT issue (999).
  seed_acked_dispatch "$repo" D-940 I-123 zzz-test-tab-940 i999-x "$base_sha"
  run_track "$repo" "$(snapshot_json zzz-test-tab-940 "done" "i999-x")"
  assert_surfaced_not_recorded "branch-issue-mismatch" "$repo" "D-940" "branch-issue-mismatch"
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# 13. F3: base_sha must be FULL-LENGTH hex -- a short hex PREFIX is also a
# valid git ref name (ref-name ambiguity risk: `<short>^{commit}` could
# resolve a moving branch/tag instead of an immutable object) and must be
# rejected before any git use of the value.
# ---------------------------------------------------------------------------
section_surface_base_sha_not_a_sha_short_hex() {
  local repo gitrepo
  repo="$(new_tmp_repo_with_git)"
  gitrepo="$repo/target-repo"
  git_or_die "base_sha-not-a-sha (short hex): branch i941-x" -C "$gitrepo" branch i941-x
  seed_acked_dispatch "$repo" D-941 I-941 zzz-test-tab-941 i941-x "deadbee"
  run_track "$repo" "$(snapshot_json zzz-test-tab-941 "done" "i941-x")"
  assert_surfaced_not_recorded "base_sha-not-a-sha (short hex)" "$repo" "D-941" "sha-not-a-sha"
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# 14. F3: a full-length 64-hex SHA-256 object name (dispatch-prep records
# 64-hex on sha256-object-format repos) must be ACCEPTED, not rejected as
# too-long. Real end-to-end corroboration against an actual
# sha256-object-format git repo (not just a regex-level assertion).
# ---------------------------------------------------------------------------
section_fully_corroborated_sha256_repo() {
  local repo gitrepo base_sha tip state
  repo="$(new_tmp_repo)"
  gitrepo="$repo/target-repo"
  mkdir -p "$gitrepo"
  (
    set -e
    cd "$gitrepo" || exit 1
    git init -q -b main --object-format=sha256 .
    git config user.email test@example.com
    git config user.name test
    printf 'hello\n' >README.md
    git add README.md
    git commit -q -m 'initial commit'
  ) >&2 || { echo "FATAL: fixture git setup failed (sha256-repo: initial commit)" >&2; exit 1; }
  cat >"$repo/.pm/config.json" <<JSON
{"repos": {"demo-repo": {"path": "$gitrepo", "mainline": "main"}}, "herdr_workspace": "zzz-test-ws"}
JSON
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  assert_eq "sha256-repo: base_sha is 64 hex chars" "64" "${#base_sha}"

  git_or_die "sha256-repo: branch i942-x" -C "$gitrepo" branch i942-x
  git_or_die "sha256-repo: worktree add wt-942" -C "$gitrepo" worktree add -q "$repo/wt-942" i942-x
  (
    set -e
    cd "$repo/wt-942" || exit 1
    printf 'more\n' >>README.md
    git add README.md
    git commit -q -m 'work'
  ) >&2 || { echo "FATAL: fixture git setup failed (sha256-repo: worker commit)" >&2; exit 1; }
  tip="$(git -C "$repo/wt-942" rev-parse HEAD)"
  assert_eq "sha256-repo: tip is 64 hex chars" "64" "${#tip}"

  seed_acked_dispatch "$repo" D-942 I-942 zzz-test-tab-942 i942-x "$base_sha"
  run_track "$repo" "$(snapshot_json zzz-test-tab-942 "done" "i942-x")"
  assert_eq "sha256-repo: exit 0" "0" "$TR_RC"

  state="$(python3 -c "
import json
idx = json.load(open('$repo/.pm/index.json'))
print(idx['dispatches']['D-942']['state'])
")"
  assert_eq "sha256-repo: state RETURNED" "RETURNED" "$state"
  assert_true "sha256-repo: result event appended" \
    bash -c '[[ "$(grep -c "^EVENT result d=D-942 " "$1/.pm/events.log" || true)" == "1" ]]' _ "$repo"

  git -C "$gitrepo" worktree remove --force "$repo/wt-942" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

section_surface_ref_name_dynamic_bypass_sha1_repo() {
  # A 64-hex string passes BASE_SHA_RE's shape gate but is NOT a valid
  # SHA-1 object id -- it CAN be a branch name in a sha1 repo. If treated
  # as a rev, base_sha would resolve to that branch's (movable) tip instead
  # of an immutable object. Must be surfaced, never recorded.
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo)"
  gitrepo="$repo/target-repo"
  mkdir -p "$gitrepo"
  base_sha="$(python3 -c "print('a1b2c3d4' * 8)")"
  assert_eq "sha1-repo-64hex-ref: base_sha is 64 hex chars" "64" "${#base_sha}"
  (
    set -e
    cd "$gitrepo" || exit 1
    git init -q -b main .
    git config user.email test@example.com
    git config user.name test
    printf 'hello\n' >README.md
    git add README.md
    git commit -q -m 'initial commit'
    git branch "$base_sha"
  ) >&2 || { echo "FATAL: fixture git setup failed (sha1-repo-64hex-ref: initial commit + ref)" >&2; exit 1; }
  cat >"$repo/.pm/config.json" <<JSON
{"repos": {"demo-repo": {"path": "$gitrepo", "mainline": "main"}}, "herdr_workspace": "zzz-test-ws"}
JSON

  git_or_die "sha1-repo-64hex-ref: branch i950-x" -C "$gitrepo" branch i950-x
  git_or_die "sha1-repo-64hex-ref: worktree add wt-950" -C "$gitrepo" worktree add -q "$repo/wt-950" i950-x
  (
    set -e
    cd "$repo/wt-950" || exit 1
    printf 'more\n' >>README.md
    git add README.md
    git commit -q -m 'work'
  ) >&2 || { echo "FATAL: fixture git setup failed (sha1-repo-64hex-ref: worker commit)" >&2; exit 1; }
  tip="$(git -C "$repo/wt-950" rev-parse HEAD)"
  assert_eq "sha1-repo-64hex-ref: tip is 40 hex chars" "40" "${#tip}"

  seed_acked_dispatch "$repo" D-950 I-950 zzz-test-tab-950 i950-x "$base_sha"
  run_track "$repo" "$(snapshot_json zzz-test-tab-950 "done" "i950-x")"
  assert_surfaced_not_recorded "sha1-repo-64hex-ref" "$repo" "D-950" "base-sha-wrong-length-for-repo"

  git -C "$gitrepo" worktree remove --force "$repo/wt-950" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

section_surface_ref_name_dynamic_bypass_sha256_repo() {
  # Symmetric case: a 40-hex string can be a branch name in a sha256 repo,
  # where valid object ids are 64 hex chars. Must be surfaced, never
  # recorded.
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo)"
  gitrepo="$repo/target-repo"
  mkdir -p "$gitrepo"
  base_sha="$(python3 -c "print('a1b2c3d4' * 5)")"
  assert_eq "sha256-repo-40hex-ref: base_sha is 40 hex chars" "40" "${#base_sha}"
  (
    set -e
    cd "$gitrepo" || exit 1
    git init -q -b main --object-format=sha256 .
    git config user.email test@example.com
    git config user.name test
    printf 'hello\n' >README.md
    git add README.md
    git commit -q -m 'initial commit'
    git branch "$base_sha"
  ) >&2 || { echo "FATAL: fixture git setup failed (sha256-repo-40hex-ref: initial commit + ref)" >&2; exit 1; }
  cat >"$repo/.pm/config.json" <<JSON
{"repos": {"demo-repo": {"path": "$gitrepo", "mainline": "main"}}, "herdr_workspace": "zzz-test-ws"}
JSON

  git_or_die "sha256-repo-40hex-ref: branch i951-x" -C "$gitrepo" branch i951-x
  git_or_die "sha256-repo-40hex-ref: worktree add wt-951" -C "$gitrepo" worktree add -q "$repo/wt-951" i951-x
  (
    set -e
    cd "$repo/wt-951" || exit 1
    printf 'more\n' >>README.md
    git add README.md
    git commit -q -m 'work'
  ) >&2 || { echo "FATAL: fixture git setup failed (sha256-repo-40hex-ref: worker commit)" >&2; exit 1; }
  tip="$(git -C "$repo/wt-951" rev-parse HEAD)"
  assert_eq "sha256-repo-40hex-ref: tip is 64 hex chars" "64" "${#tip}"

  seed_acked_dispatch "$repo" D-951 I-951 zzz-test-tab-951 i951-x "$base_sha"
  run_track "$repo" "$(snapshot_json zzz-test-tab-951 "done" "i951-x")"
  assert_surfaced_not_recorded "sha256-repo-40hex-ref" "$repo" "D-951" "base-sha-wrong-length-for-repo"

  git -C "$gitrepo" worktree remove --force "$repo/wt-951" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
echo "== track: fully corroborated done tab records RETURNED intake =="
section_fully_corroborated_records_returned
echo "== track: surface -- missing-metadata =="
section_surface_missing_metadata
echo "== track: surface -- repo-not-configured =="
section_surface_repo_not_configured
echo "== track: surface -- base-sha-unreachable =="
section_surface_base_sha_unreachable
echo "== track: surface -- branch-missing =="
section_surface_branch_missing
echo "== track: surface -- dirty-worktree =="
section_surface_dirty_worktree
echo "== track: surface -- no-new-commit =="
section_surface_no_new_commit
echo "== track: surface -- not-descendant (rewritten/sibling branch) =="
section_surface_not_descendant
echo "== track: surface -- worktree-missing =="
section_surface_worktree_missing
echo "== track: surface -- herdr unavailable degrades gracefully =="
section_surface_herdr_unavailable
echo "== track: idempotent re-tick, no double-record =="
section_idempotent_retick
echo "== track: forged/mismatched metadata surfaced via independent re-resolve =="
section_forged_metadata_surfaced
echo "== track: working/blocked tabs ignored entirely =="
section_working_blocked_ignored
echo "== track: surface -- base_sha-not-a-sha (HEAD) =="
section_surface_base_sha_not_a_sha_head
echo "== track: surface -- base_sha-not-a-sha (main) =="
section_surface_base_sha_not_a_sha_branch_expr
echo "== track: surface -- branch-is-mainline =="
section_surface_branch_is_mainline
echo "== track: surface -- branch-not-a-ticket-branch =="
section_surface_branch_not_a_ticket_branch
echo "== track: surface -- tab-binding-unconfirmed (absent label) =="
section_surface_tab_binding_unconfirmed_absent_label
echo "== track: surface -- tab-binding-unconfirmed (mismatched label) =="
section_surface_tab_binding_unconfirmed_mismatched_label
echo "== track: surface -- status-unknown (wrong workspace) =="
section_surface_status_unknown_wrong_workspace
echo "== track: surface -- herdr-unavailable (malformed snapshot) =="
section_surface_herdr_unavailable_malformed_snapshot
echo "== track: surface -- corroboration-changed-under-lock =="
section_surface_corroboration_changed_under_lock
echo "== track: surface -- branch-issue-mismatch =="
section_surface_branch_issue_mismatch
echo "== track: surface -- base_sha-not-a-sha (short hex) =="
section_surface_base_sha_not_a_sha_short_hex
echo "== track: fully corroborated done tab on a sha256-object-format repo =="
section_fully_corroborated_sha256_repo
echo "== track: surface -- 64-hex ref-name dynamic-bypass attempt in a sha1 repo =="
section_surface_ref_name_dynamic_bypass_sha1_repo
echo "== track: surface -- 40-hex ref-name dynamic-bypass attempt in a sha256 repo =="
section_surface_ref_name_dynamic_bypass_sha256_repo

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
