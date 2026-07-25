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
# I25: track's auto-close pass and spawn stage live in sourced components
TRACK_AUTOCLOSE="${PM_CREATOR_DIR}/templates/bin/_track_autoclose"
TRACK_SPAWN="${PM_CREATOR_DIR}/templates/bin/_track_spawn"

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

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$name"
  else
    fail "$name" "expected output to contain [$needle]"
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
  cp "${LIB%_lib.sh}_close_lib.sh" "$d/bin/_close_lib.sh"
  cp "$TRACK" "$d/bin/track"
  cp "$TRACK_AUTOCLOSE" "$d/bin/_track_autoclose"
  cp "$TRACK_SPAWN" "$d/bin/_track_spawn"
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

# ---------------------------------------------------------------------------
# B2.1 auto-close fixtures
# ---------------------------------------------------------------------------

# new_tmp_repo_with_git_ac [auto_close=true]
# Like new_tmp_repo_with_git, but the "demo-repo" config entry carries a
# complete, FULL configured mainline_ref (refs/heads/main) + fetch_policy
# (local-only, so G4 never needs a real remote) -- the shape B2.0b's
# scaffold-time normalization produces -- plus automation.auto_close.
new_tmp_repo_with_git_ac() {
  local auto_close="${1:-true}"
  local d gitrepo
  d="$(new_tmp_repo_with_git)"
  gitrepo="$d/target-repo"
  cat >"$d/.pm/config.json" <<JSON
{"repos": {"demo-repo": {"path": "$gitrepo", "mainline": "main", "mainline_ref": "refs/heads/main", "fetch_policy": "local-only"}}, "herdr_workspace": "zzz-test-ws", "automation": {"auto_close": $auto_close}}
JSON
  echo "$d"
}

# seed_verified_dispatch <repo> <d> <issue> <tab> <branch> <base_sha> <result_sha>
# Extends seed_acked_dispatch through the real ACKED->RETURNED->VERIFIED
# path (result event, then a human dispatch_state VERIFIED transition) --
# the ONLY legal way to mint a VERIFIED dispatch via pm_apply.
seed_verified_dispatch() {
  local repo="$1" d="$2" issue="$3" tab="$4" branch="$5" base_sha="$6" result_sha="$7"
  seed_acked_dispatch "$repo" "$d" "$issue" "$tab" "$branch" "$base_sha"
  PM_ROOT="$repo" pm_apply result d="$d" a=A-01 status=RETURNED result_sha="$result_sha" \
    at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d="$d" a=A-01 from=RETURNED to=VERIFIED lane=human \
    at="$(now_iso)" >/dev/null
}

# seed_issue_state <repo> <issue> <from> <to>
# Registers (if new) and/or transitions an issue via issue_state. A
# never-before-seen issue's FIRST issue_state event may set any from=/to=
# pair (both merely need to be in ISSUE_STATES) since the grammar's
# from-vs-current consistency check is skipped when cur is None -- so this
# single call both registers AND activates a brand-new issue.
seed_issue_state() {
  local repo="$1" issue="$2" from="$3" to="$4"
  PM_ROOT="$repo" pm_apply issue_state i="$issue" from="$from" to="$to" \
    at="$(now_iso)" by=tester >/dev/null
}

# seed_question <repo> <q> <state> [<issue>]
# Seeds a `question` event, optionally scoped to an issue (i=). Omitting
# the issue seeds an UNSCOPED question (open_questions_unscoped).
seed_question() {
  local repo="$1" q="$2" state="$3" issue="${4:-}"
  if [[ -n "$issue" ]]; then
    PM_ROOT="$repo" pm_apply question q="$q" state="$state" at="$(now_iso)" i="$issue" >/dev/null
  else
    PM_ROOT="$repo" pm_apply question q="$q" state="$state" at="$(now_iso)" >/dev/null
  fi
}

# ac_merge_worker_tip_to_mainline <gitrepo> <tip_sha>
# Fast-forwards the local "main" branch ref to <tip_sha> directly (no
# checkout switch needed -- mainline_ref=refs/heads/main is resolved by
# tr_g4_check as a plain ref, and fetch_policy=local-only never fetches),
# simulating "the worker's branch was merged to mainline" for G4 tests.
ac_merge_worker_tip_to_mainline() {
  local gitrepo="$1" tip="$2"
  # update-ref (not `git branch -f`) -- main is checked out in the primary
  # worktree here, and `git branch -f` on a checked-out branch refuses with
  # "cannot force update the branch ... used by worktree"; update-ref moves
  # the ref directly without that worktree-safety check (we never rely on
  # the primary worktree's working-tree CONTENTS, only the ref value that
  # mainline_ref=refs/heads/main resolves to).
  git_or_die "merge worker tip to mainline" -C "$gitrepo" update-ref refs/heads/main "$tip"
}

# ac_make_worker_commit <gitrepo> <repo> <branch> -- branches off HEAD,
# worktree-adds it under $repo/wt-<branch>, commits one change, echoes the
# tip sha. Caller is responsible for `git worktree remove --force` cleanup.
ac_make_worker_commit() {
  local gitrepo="$1" repo="$2" branch="$3"
  git_or_die "ac_make_worker_commit: branch $branch" -C "$gitrepo" branch "$branch"
  git_or_die "ac_make_worker_commit: worktree add wt-$branch" \
    -C "$gitrepo" worktree add -q "$repo/wt-$branch" "$branch"
  (
    set -e
    cd "$repo/wt-$branch" || exit 1
    printf 'work\n' >>README.md
    git add README.md
    git commit -q -m 'work'
  ) >&2 || { echo "FATAL: fixture git setup failed (ac_make_worker_commit: $branch commit)" >&2; exit 1; }
  git -C "$repo/wt-$branch" rev-parse HEAD
}

# ---------------------------------------------------------------------------
# B2.2 marker-path fixtures
# ---------------------------------------------------------------------------

# new_tmp_repo_with_git_ac_squash [allow_marker_branch_deleted=false]
# Like new_tmp_repo_with_git_ac true, but demo-repo opts into the B2.2
# marker path: merge_mode=squash (+ the branch-deleted opt-in as given).
new_tmp_repo_with_git_ac_squash() {
  local allow_deleted="${1:-false}"
  local d gitrepo
  d="$(new_tmp_repo_with_git)"
  gitrepo="$d/target-repo"
  cat >"$d/.pm/config.json" <<JSON
{"repos": {"demo-repo": {"path": "$gitrepo", "mainline": "main", "mainline_ref": "refs/heads/main", "fetch_policy": "local-only", "merge_mode": "squash", "allow_marker_branch_deleted": $allow_deleted}}, "herdr_workspace": "zzz-test-ws", "automation": {"auto_close": true}}
JSON
  echo "$d"
}

# ac_squash_merge_to_mainline <gitrepo> <branch_tip>
# Simulates a SQUASH merge: builds a brand-new commit carrying the branch
# tip's TREE with the current main as sole parent (so the branch tip is NOT
# an ancestor of the new mainline -- exactly the topology strict G4 cannot
# corroborate), moves refs/heads/main to it, echoes the squash commit sha.
ac_squash_merge_to_mainline() {
  local gitrepo="$1" tip="$2"
  local main_sha squash_sha
  main_sha="$(git -C "$gitrepo" rev-parse refs/heads/main)" || {
    echo "FATAL: fixture git setup failed (ac_squash_merge_to_mainline: rev-parse main)" >&2
    exit 1
  }
  squash_sha="$(git -C "$gitrepo" commit-tree "${tip}^{tree}" -p "$main_sha" -m "squash-merge")" || {
    echo "FATAL: fixture git setup failed (ac_squash_merge_to_mainline: commit-tree)" >&2
    exit 1
  }
  git_or_die "ac_squash_merge_to_mainline: update-ref main" \
    -C "$gitrepo" update-ref refs/heads/main "$squash_sha"
  echo "$squash_sha"
}

# seed_merged_marker <repo> <d> <merge_sha> <result_sha>
# Appends a fold-accepted `merged` marker for (d, A-01) via the real
# enforcement engine (pm_apply) -- exactly what `record merged` emits.
seed_merged_marker() {
  local repo="$1" d="$2" merge_sha="$3" result_sha="$4"
  PM_ROOT="$repo" pm_apply merged d="$d" a=A-01 merge_sha="$merge_sha" \
    result_sha="$result_sha" at="$(now_iso)" >/dev/null
}

# ac_delete_worker_branch <gitrepo> <repo> <branch>
# Post-squash cleanup: removes the worker worktree and deletes the branch
# ref, leaving the recorded branch unresolvable.
ac_delete_worker_branch() {
  local gitrepo="$1" repo="$2" branch="$3"
  git -C "$gitrepo" worktree remove --force "$repo/wt-$branch" >/dev/null 2>&1 || true
  git_or_die "ac_delete_worker_branch: branch -D $branch" -C "$gitrepo" branch -D "$branch"
}

# ac_fetch_policy_config <repo> <gitrepo> <auto_close>
# Rewrites .pm/config.json with a fetch_policy=fetch demo-repo entry
# (mainline_ref refs/remotes/origin/main) -- caller must have set up a local
# bare "origin" remote (never a real network remote).
ac_fetch_policy_config() {
  local repo="$1" gitrepo="$2" auto_close="$3"
  cat >"$repo/.pm/config.json" <<JSON
{"repos": {"demo-repo": {"path": "$gitrepo", "mainline": "main", "mainline_ref": "refs/remotes/origin/main", "fetch_policy": "fetch"}}, "herdr_workspace": "zzz-test-ws", "automation": {"auto_close": $auto_close}}
JSON
}

# ac_add_local_origin <repo> <gitrepo> -- init a local bare origin.git inside
# the fixture and point demo-repo's "origin" remote at it; pushes current
# main. Echoes nothing.
ac_add_local_origin() {
  local repo="$1" gitrepo="$2"
  local origin_bare="$repo/origin.git"
  git_or_die "ac_add_local_origin: init bare origin" init -q --bare "$origin_bare"
  git_or_die "ac_add_local_origin: add origin remote" -C "$gitrepo" remote add origin "$origin_bare"
  git_or_die "ac_add_local_origin: push main to origin" -C "$gitrepo" push -q origin main
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
      HERDR_FIXTURES="${THIS_DIR}/fixtures" \
      HERDR_CALL_LOG="${HERDR_CALL_LOG:-}" \
      HERDR_TAB_CREATE_MODE="${HERDR_TAB_CREATE_MODE:-ok}" \
      HERDR_AGENT_START_MODE="${HERDR_AGENT_START_MODE:-ok}" \
      HERDR_RACE_APPEND="${HERDR_RACE_APPEND:-}" \
      HERDR_TAMPER_PROMPT="${HERDR_TAMPER_PROMPT:-}" \
      PATH="/usr/bin:/bin" \
      bash -c '
        # herdr shadow (B3-extended): `api snapshot` returns the fixture;
        # `tab create` / `agent start` / `tab close` emit the live-probed
        # herdr JSON shapes from test/fixtures/herdr_*.json (I21: version
        # pin + provenance in test/fixtures/herdr_README.md; sed fills the
        # __N__/__LABEL__/__NAME__/__TAB__ placeholders -- test labels stay
        # inside the pm token charset, so plain sed substitution is safe),
        # log their full argv to HERDR_CALL_LOG, and never touch the real
        # herdr binary or a live workspace. HERDR_RACE_APPEND injects a raw
        # event-log line during `tab create` -- inside track own
        # intent->ack window -- to reproduce the TOCTOU race
        # deterministically; HERDR_TAMPER_PROMPT appends junk to the named
        # file during `tab create`, landing in the NEXT candidate
        # plan->lock window (the under-lock re-hash TOCTOU).
        # HERDR_TAB_CREATE_MODE=ok_no_id returns exit 0 with the tab_id
        # field missing.
        # shellcheck disable=SC2317,SC2329  # invoked indirectly by bin/track
        herdr() {
          case "$1 $2" in
            "api snapshot") cat "$HERDR_SNAPSHOT_FIXTURE" ;;
            "tab create")
              if [[ -n "${HERDR_CALL_LOG:-}" ]]; then printf "%s\n" "$*" >>"$HERDR_CALL_LOG"; fi
              if [[ -n "${HERDR_RACE_APPEND:-}" ]]; then printf "%s\n" "$HERDR_RACE_APPEND" >>.pm/events.log; fi
              if [[ -n "${HERDR_TAMPER_PROMPT:-}" ]]; then printf "tampered mid-window\n" >>"$HERDR_TAMPER_PROMPT"; fi
              if [[ "${HERDR_TAB_CREATE_MODE:-ok}" == "fail" ]]; then
                cat "$HERDR_FIXTURES/herdr_tab_create_error.json"
                return 1
              fi
              if [[ "${HERDR_TAB_CREATE_MODE:-ok}" == "ok_no_id" ]]; then
                cat "$HERDR_FIXTURES/herdr_tab_created_no_id.json"
                return 0
              fi
              local label="" prev="" arg n=1
              for arg in "$@"; do
                if [[ "$prev" == "--label" ]]; then label="$arg"; fi
                prev="$arg"
              done
              if [[ -n "${HERDR_CALL_LOG:-}" ]]; then n="$(grep -c "^tab create" "$HERDR_CALL_LOG" 2>/dev/null)" || n=1; fi
              sed -e "s|__N__|$n|g" -e "s|__LABEL__|$label|g" "$HERDR_FIXTURES/herdr_tab_created.json"
              ;;
            "tab close")
              if [[ -n "${HERDR_CALL_LOG:-}" ]]; then printf "%s\n" "$*" >>"$HERDR_CALL_LOG"; fi
              cat "$HERDR_FIXTURES/herdr_tab_closed.json"
              ;;
            "agent start")
              if [[ -n "${HERDR_CALL_LOG:-}" ]]; then printf "%s\n" "$*" >>"$HERDR_CALL_LOG"; fi
              if [[ "${HERDR_AGENT_START_MODE:-ok}" == "fail" ]]; then
                cat "$HERDR_FIXTURES/herdr_agent_start_error.json"
                return 1
              fi
              local name="$3" tab="" prev="" arg
              for arg in "$@"; do
                if [[ "$prev" == "--tab" ]]; then tab="$arg"; fi
                prev="$arg"
              done
              sed -e "s|__NAME__|$name|g" -e "s|__TAB__|$tab|g" "$HERDR_FIXTURES/herdr_agent_started.json"
              ;;
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

# make_git_env_wrapper <wrapper_dir> <log_file> (Codex-sparred defect #4,
# Medium). Writes a `git` shim into <wrapper_dir> that appends one line per
# invocation to <log_file> -- "1|<argv...>" if GIT_NO_REPLACE_OBJECTS=1 was
# set in its own environment, "<unset>|<argv...>" otherwise -- then execs
# the REAL git (resolved via `command -v git` at wrapper-generation time, so
# the shim itself never recurses into itself). Used with
# run_track_with_git_wrapper to prove GIT_NO_REPLACE_OBJECTS=1 is set on
# EVERY G4 git call track makes, not just the ones inside tr_g4_check's own
# local run() closure -- including tr_verify_commit's identity anchor and
# tr_repo_has_grafts's graft probe, both called via the shared tr_run().
make_git_env_wrapper() {
  local wrapper_dir="$1" log_file="$2" real_git
  mkdir -p "$wrapper_dir"
  real_git="$(command -v git)"
  cat >"$wrapper_dir/git" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\${GIT_NO_REPLACE_OBJECTS:-<unset>}" "\$*" >>"$log_file"
exec "$real_git" "\$@"
EOF
  chmod +x "$wrapper_dir/git"
}

# run_track_with_git_wrapper <repo_dir> <wrapper_dir> -- like run_track's
# no-fixture branch (no herdr new intake -> pure AC-pass tick), but with
# <wrapper_dir> prepended to PATH so the make_git_env_wrapper shim
# intercepts every `git` invocation track makes.
run_track_with_git_wrapper() {
  local repo="$1" wrapper_dir="$2"
  # shellcheck disable=SC2034  # TR_OUT is set for ad-hoc debugging (print on failure), not asserted on
  TR_OUT="$(cd "$repo" && PATH="$wrapper_dir:/usr/bin:/bin" bash bin/track --once 2>&1)"
  TR_RC=$?
}

snapshot_json() {
  # snapshot_json <tab_id> <agent_status> [<label>] [<panes_json>]
  # Every tab is always embedded in the "zzz-test-ws" workspace (matching
  # every fixture's configured herdr_workspace) so plain status/existence
  # cases don't also have to fight the F5 workspace filter. B3: the
  # snapshot additionally carries panes[] (empty by default; override with
  # the 4th arg).
  local tab="$1" status="$2" label="${3:-}" panes="${4:-[]}"
  if [[ -n "$label" ]]; then
    printf '{"result": {"tabs": [{"tab_id": "%s", "agent_status": "%s", "label": "%s", "workspace_id": "zzz-test-ws"}], "panes": %s}}' \
      "$tab" "$status" "$label" "$panes"
  else
    printf '{"result": {"tabs": [{"tab_id": "%s", "agent_status": "%s", "workspace_id": "zzz-test-ws"}], "panes": %s}}' \
      "$tab" "$status" "$panes"
  fi
}

# ---------------------------------------------------------------------------
# B3 auto-spawn fixtures
# ---------------------------------------------------------------------------

spawn_snapshot_json() {
  # spawn_snapshot_json [<panes_json>] [<agents_json>] [<tabs_json>]
  # A snapshot with no interesting tabs (STAGE 1 idle) but explicit panes[]
  # and agents[] arrays for the B3 spawn stage.
  printf '{"result": {"tabs": %s, "panes": %s, "agents": %s}}' \
    "${3:-[]}" "${1:-[]}" "${2:-[]}"
}

pane_json() {
  # pane_json <name> <pane_id> <tab_id> [<workspace_id>]
  printf '{"name": "%s", "pane_id": "%s", "tab_id": "%s", "workspace_id": "%s"}' \
    "$1" "$2" "$3" "${4:-zzz-test-ws}"
}

agent_json() {
  # agent_json <pane_id> <tab_id> [<agent_status>] -- name is null, exactly
  # as the live-probed snapshot shape carries it.
  printf '{"name": null, "agent_status": "%s", "pane_id": "%s", "tab_id": "%s"}' \
    "${3:-working}" "$1" "$2"
}

# new_tmp_repo_spawn [auto_spawn=true] [max_live=2] [timeout=1] [argv_json]
# A fixture repo whose config carries the full B3 automation block.
new_tmp_repo_spawn() {
  local auto_spawn="${1:-true}" max_live="${2:-2}" timeout="${3:-1}"
  # NOTE: default assigned separately -- a literal `}` inside `${4:-...}`
  # would terminate the parameter expansion early.
  local argv_json="${4:-}"
  if [[ -z "$argv_json" ]]; then
    argv_json='["zzz-test-runner", "{prompt}"]'
  fi
  local d
  d="$(new_tmp_repo)"
  mkdir -p "$d/prompts"
  cat >"$d/.pm/config.json" <<JSON
{"repos": {}, "herdr_workspace": "zzz-test-ws", "automation": {"auto_close": false, "auto_spawn": $auto_spawn, "max_live_workers": $max_live, "spawn_ack_timeout_ticks": $timeout, "spawn_argv": $argv_json}}
JSON
  echo "$d"
}

# seed_automation_dispatch <repo> <d> <issue> <slug>
# Seeds an ACTIVE issue + an automation-lane dispatch via the REAL
# dispatch-prep --lane automation round trip (durable prompt copy + note
# binding + lane=automation tab=? mint), so the folded state is exactly
# what production would produce. Echoes nothing.
seed_automation_dispatch() {
  local repo="$1" d="$2" issue="$3" slug="$4"
  local base="I-${issue#I-}_${slug}_2026-07-25.md"
  printf 'Automation prompt for %s (%s).\n' "$d" "$slug" >"$repo/prompts/$base"
  seed_issue_state "$repo" "$issue" OPEN ACTIVE
  if ! PM_ROOT="$repo" "${PM_CREATOR_DIR}/templates/bin/dispatch-prep" \
    --dispatch "$d" --issue "$issue" --lane automation \
    --prompt "$repo/prompts/$base" >/dev/null 2>&1; then
    echo "FATAL: seed_automation_dispatch failed for $d" >&2
    exit 1
  fi
}

# seed_spawn_intent <repo> <d> <a> <ref>
# Appends a fold-accepted spawn_intent lease via the real engine (pm_apply)
# -- simulating a PRIOR tick's durable intent for crash-recovery tests.
seed_spawn_intent() {
  local repo="$1" d="$2" a="$3" ref="$4"
  PM_ROOT="$repo" pm_apply spawn_intent d="$d" a="$a" ref="$ref" at="$(now_iso)" >/dev/null
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

issue_state_in_index() {
  local repo="$1" issue="$2"
  python3 -c "
import json
idx = json.load(open('$repo/.pm/index.json'))
print(idx.get('issues', {}).get('$issue', {}).get('state', ''))
" 2>/dev/null
}

# assert_ac_closed <label> <repo> <issue>
# Asserts the auto-close pass CLOSED <issue> this tick: index.json state is
# CLOSED, and TRACKER.md's "Auto-closed this tick" section names it.
assert_ac_closed() {
  local label="$1" repo="$2" issue="$3"
  assert_true "$label: exit 0" bash -c '[[ "$1" == "0" ]]' _ "$TR_RC"
  assert_eq "$label: issue state is CLOSED" "CLOSED" "$(issue_state_in_index "$repo" "$issue")"
  assert_true "$label: named in TRACKER.md" \
    bash -c 'grep -q "$1" "$2/TRACKER.md"' _ "$issue" "$repo"
}

# assert_ac_surfaced <label> <repo> <issue> <reason_substr>
# Asserts the auto-close pass did NOT close <issue> this tick and surfaced
# it with the given reason substring; index.json state stays non-CLOSED.
# T5: issue AND reason must appear on the SAME rendered TRACKER.md line (a
# table row or a steady-state summary line) -- two independent whole-file
# greps could vacuously pass off two unrelated rows.
assert_ac_surfaced() {
  local label="$1" repo="$2" issue="$3" reason="$4"
  local state
  state="$(issue_state_in_index "$repo" "$issue")"
  assert_true "$label: exit 0" bash -c '[[ "$1" == "0" ]]' _ "$TR_RC"
  assert_true "$label: issue state is NOT CLOSED (got '$state')" \
    bash -c '[[ "$1" != "CLOSED" ]]' _ "$state"
  assert_true "$label: surfaced on one TRACKER.md row: '$issue' + '$reason'" \
    bash -c 'grep -- "$3" "$2/TRACKER.md" | grep -q -- "$1"' _ "$issue" "$repo" "$reason"
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

# C1 regression: a worker that does zero real work and simply resets its
# ticket branch onto a FOREIGN mainline tip (advanced by unrelated work
# after this dispatch's base_sha was minted) must NOT strictly
# git-corroborate. Before the C1 fix, branch_tip != base_sha (no-new-commit
# misses) and base_sha IS an ancestor of branch_tip (not-descendant misses,
# since mainline only moves forward) -- track would auto-RECORD the
# foreign commit as this worker's own result.
section_surface_branch_contains_no_new_work() {
  local repo gitrepo base_sha foreign_tip
  repo="$(new_tmp_repo_with_git)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"

  # Unrelated work advances mainline PAST this dispatch's base_sha, done
  # entirely by someone/something else -- not this ticket's worker.
  git_or_die "branch-contains-no-new-work: unrelated mainline commit" \
    -C "$gitrepo" commit --allow-empty -q -m 'unrelated work by another dispatch'
  foreign_tip="$(git -C "$gitrepo" rev-parse HEAD)"

  # The worker does zero work of its own: its ticket branch is simply cut
  # at (equivalent to `git reset --hard main` onto) the foreign tip.
  git_or_die "branch-contains-no-new-work: branch i918-forge at foreign tip" \
    -C "$gitrepo" branch i918-forge "$foreign_tip"
  git_or_die "branch-contains-no-new-work: worktree add wt-918" \
    -C "$gitrepo" worktree add -q "$repo/wt-918" i918-forge

  seed_acked_dispatch "$repo" D-918 I-918 zzz-test-tab-918 i918-forge "$base_sha"
  run_track "$repo" "$(snapshot_json zzz-test-tab-918 "done" "i918-forge")"
  assert_surfaced_not_recorded "branch-contains-no-new-work" "$repo" "D-918" \
    "branch-contains-no-new-work"
  git -C "$gitrepo" worktree remove --force "$repo/wt-918" >/dev/null 2>&1 || true
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
# 12b. F1 (Codex-sparred, round 3 -- the LAST remaining second-raw-log-parser):
# an EARLIER-in-file poisoned `dispatch_new` line for D-601 with a duplicate
# `i=` key (`i=I-601 ... i=I-602`) is grammar-invalid (parse_line rejects the
# duplicate key), so fold_lines quarantines it -- it never registers D-601 in
# the fold at all. The REAL dispatch_new for D-601 (legitimately linked to
# I-601) follows afterward and registers normally. The now-deleted
# `tr_find_issue_for_dispatch` used to re-scan the raw log itself with a
# naive first-match parser and would have returned the POISONED line's last
# `i=` (I-602) for D-601 -- a false branch-issue-mismatch surface (branch
# i601-x names I-601, but the poisoned raw scan derived I-602), blocking
# legitimate intake. STAGE 1 now reads the fold's authoritative
# `dispatch_issue_map` (built ONLY from validated, non-quarantined
# dispatch_new lines) instead -- the poison line is simply absent from it,
# D-601 correctly maps to I-601, F1 sees a MATCH, and intake proceeds
# normally (RETURNED recorded, no mismatch surfaced).
section_surface_branch_issue_mismatch_stage1_poison_resists() {
  local repo gitrepo base_sha
  repo="$(new_tmp_repo_with_git)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"

  git_or_die "stage1-poison: branch i601-x" -C "$gitrepo" branch i601-x
  git_or_die "stage1-poison: worktree add wt-601" -C "$gitrepo" worktree add -q "$repo/wt-601" i601-x
  (
    set -e
    cd "$repo/wt-601" || exit 1
    printf 'more\n' >>README.md
    git add README.md
    git commit -q -m 'i601 work'
  ) >&2 || { echo "FATAL: fixture git setup failed (stage1-poison: i601 commit)" >&2; exit 1; }

  # Poisoned line FIRST, in raw-file order, ahead of D-601's real
  # registration -- exploits the deleted parser's early-return-on-first-match.
  PM_ROOT="$repo" pm_raw_append_literal \
    "EVENT dispatch_new d=D-601 i=I-601 at=$(now_iso) i=I-602"
  # The REAL dispatch registration for D-601, legitimately linked to I-601.
  seed_acked_dispatch "$repo" D-601 I-601 zzz-test-tab-601 i601-x "$base_sha"

  run_track "$repo" "$(snapshot_json zzz-test-tab-601 "done" "i601-x")"
  assert_eq "stage1-poison: exit 0" "0" "$TR_RC"
  assert_true "stage1-poison: NOT surfaced as branch-issue-mismatch" \
    bash -c '! grep -q "branch-issue-mismatch" "$1/TRACKER.md"' _ "$repo"
  assert_eq "stage1-poison: dispatch D-601 state is RETURNED (intake succeeded, not blocked)" \
    "RETURNED" "$(python3 -c "
import json
idx = json.load(open('$repo/.pm/index.json'))
print(idx['dispatches']['D-601']['state'])
")"
  assert_eq "stage1-poison: authoritative map D-601 -> I-601 (unpoisoned)" \
    "I-601" "$(python3 -c "
import json
idx = json.load(open('$repo/.pm/index.json'))
print(idx.get('dispatch_issue_map', {}).get('D-601', ''))
")"

  git -C "$gitrepo" worktree remove --force "$repo/wt-601" >/dev/null 2>&1 || true
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

# ===========================================================================
# B2.1 auto-close pass (STRICT merged-path only, STAGE 2.5).
# ===========================================================================

# ---------------------------------------------------------------------------
# AC.0 Non-vacuous end-to-end: sole non-superseded VERIFIED dispatch,
# result_sha strictly merged into the configured local mainline ref, no
# open questions, automation.auto_close=true -> the tick CLOSES the issue.
# ---------------------------------------------------------------------------
section_ac_end_to_end_closes() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i960-x)"

  seed_verified_dispatch "$repo" D-960 I-960 zzz-test-tab-960 i960-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-960 OPEN ACTIVE
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"

  run_track "$repo"
  assert_ac_closed "ac end-to-end" "$repo" "I-960"
  assert_true "ac end-to-end: exactly one issue_state ...to=CLOSED for I-960" \
    bash -c '[[ "$(grep -c "^EVENT issue_state i=I-960 .*to=CLOSED" "$1/.pm/events.log")" == "1" ]]' \
    _ "$repo"
  assert_true "ac end-to-end: dispatch D-960 remains VERIFIED (close never mutates dispatches)" \
    bash -c '
      python3 -c "
import json
idx = json.load(open(\"$1/.pm/index.json\"))
print(idx[\"dispatches\"][\"D-960\"][\"state\"])
" | grep -qx VERIFIED
    ' _ "$repo"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i960-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# AC.G1 wrong-state variants: NEEDS-USER / BLOCKED / paused-non-active.
# ---------------------------------------------------------------------------
section_ac_g1_needs_user() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i961-x)"

  seed_verified_dispatch "$repo" D-961 I-961 zzz-test-tab-961 i961-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-961 OPEN ACTIVE
  seed_issue_state "$repo" I-961 ACTIVE NEEDS-USER
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"

  run_track "$repo"
  assert_ac_surfaced "ac g1 NEEDS-USER" "$repo" "I-961" "NEEDS-USER"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i961-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

section_ac_g1_blocked() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i962-x)"

  seed_verified_dispatch "$repo" D-962 I-962 zzz-test-tab-962 i962-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-962 OPEN ACTIVE
  seed_issue_state "$repo" I-962 ACTIVE BLOCKED
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"

  run_track "$repo"
  assert_ac_surfaced "ac g1 BLOCKED" "$repo" "I-962" "BLOCKED"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i962-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

section_ac_g1_paused_non_active() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i963-x)"

  seed_verified_dispatch "$repo" D-963 I-963 zzz-test-tab-963 i963-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-963 OPEN PARKED
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"

  run_track "$repo"
  assert_ac_surfaced "ac g1 paused/non-active" "$repo" "I-963" "paused/non-active"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i963-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# AC.G1 crash recovery: a CLOSED issue with leftover prompts/messages files
# is re-archived REGARDLESS of automation.auto_close (crash recovery finishes
# an already-decided close, it is not a new close decision).
# ---------------------------------------------------------------------------
section_ac_crash_recovery_rearchive() {
  local repo
  repo="$(new_tmp_repo_with_git_ac false)"
  seed_issue_state "$repo" I-964 OPEN CLOSED
  mkdir -p "$repo/prompts" "$repo/messages"
  printf 'leftover prompt\n' >"$repo/prompts/I-964_dispatch.md"
  printf 'leftover message\n' >"$repo/messages/I-964_note.md"

  run_track "$repo"
  assert_eq "ac crash-recovery: exit 0" "0" "$TR_RC"
  assert_true "ac crash-recovery: prompts leftover archived" \
    bash -c '[[ -f "$1/archive/prompts/I-964_dispatch.md" && ! -e "$1/prompts/I-964_dispatch.md" ]]' _ "$repo"
  assert_true "ac crash-recovery: messages leftover archived" \
    bash -c '[[ -f "$1/archive/messages/I-964_note.md" && ! -e "$1/messages/I-964_note.md" ]]' _ "$repo"
  assert_true "ac crash-recovery: reported as rearchive/CLOSED-but-archive-leftovers in TRACKER.md" \
    bash -c 'grep -q "I-964" "$1/TRACKER.md" && grep -q "CLOSED-but-archive-leftovers" "$1/TRACKER.md"' _ "$repo"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# AC.G1.5 quarantined-events gates (Codex-sparred defect #1, Critical).
#
# A raw line that fails the rule engine's *legality* checks at fold time is
# quarantined (never silently dropped), but until now `evaluate_issue` never
# consulted the quarantine at all -- an issue with a quarantined line naming
# it could still sail through every other gate and get auto-closed, even
# though the quarantined line names real, un-adjudicated semantic content
# (an invalid question state, a corrupt issue_state/dispatch_state/result
# touching the issue or one of its dispatches). `pm_raw_append` is the
# grammar-only, rule-engine-bypassing seeder (test/_seed.sh) used here to
# plant a grammar-VALID but rule-ILLEGAL line, so fold_lines quarantines it
# for the reason under test rather than rejecting it outright as malformed.
# ---------------------------------------------------------------------------

# Scoped (i=) question with a bogus state -- grammar-valid (BOGUS passes the
# token charset), rule-illegal (not a recognized question state) -> quarantined
# and attributed to I-981 via write_outputs' quarantine_by_issue. Must surface
# invalid-question-state and MUST NOT close, even though the issue is
# otherwise fully closeable (no other dispatches, ACTIVE state).
section_ac_g1p5_quarantined_question_for_issue() {
  local repo
  repo="$(new_tmp_repo_with_git_ac true)"
  seed_issue_state "$repo" I-981 OPEN ACTIVE
  PM_ROOT="$repo" pm_raw_append question q=Q-981 state=BOGUS at="$(now_iso)" i=I-981

  run_track "$repo"
  assert_ac_surfaced "ac g1.5 quarantined scoped question -> invalid-question-state" \
    "$repo" "I-981" "invalid-question-state"

  rm -rf "$repo"
}

# A quarantined issue_state line (illegal `to=`) touching I-982 directly --
# distinct code path from the question case, must surface the more general
# issue-related-quarantine reason (not invalid-question-state) and MUST NOT
# close.
section_ac_g1p5_quarantined_issue_state() {
  local repo
  repo="$(new_tmp_repo_with_git_ac true)"
  seed_issue_state "$repo" I-982 OPEN ACTIVE
  PM_ROOT="$repo" pm_raw_append issue_state i=I-982 from=ACTIVE to=BOGUS at="$(now_iso)"

  run_track "$repo"
  assert_ac_surfaced "ac g1.5 quarantined issue_state -> issue-related-quarantine" \
    "$repo" "I-982" "issue-related-quarantine"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# AC.G1.5 round-2 (Codex-sparred, Critical A + Critical B): the fold is the
# SINGLE source of truth for dispatch<->issue linkage and for quarantine
# attribution -- track's auto-close pass must never re-parse the raw event
# log itself. `pm_raw_append_literal` (test/_seed.sh) writes an exact,
# genuinely grammar-INVALID raw line (duplicate keys, quoted/trailing
# tokens, malformed key=value) that `pm_raw_append`'s own grammar checks
# would refuse to write -- reproducing exactly the adversarial lines
# `parse_line()` rejects and `fold_lines` quarantines with NO attribution
# (etype/kv never resolved), setting the global `quarantine_unattributable`
# flag that blocks every closeable issue that tick.
# ---------------------------------------------------------------------------

# Critical A: a quarantined `dispatch_new` line carries a DUPLICATE `i=`
# key (i=I-501 ... i=I-502) -- grammar-invalid (parse_line raises on the
# duplicate key), so fold_lines quarantines it unattributed. The now-DELETED
# `tr_build_dispatch_issue_map` used to re-scan the raw log with its own
# naive last-value-wins parser and would have reassigned D-501 (legitimately
# registered to, and VERIFIED+merged for, I-501) to I-502 -- closing I-502
# using I-501's verified work. track now reads index.json's fold-built
# `dispatch_issue_map` (built ONLY from validated, non-quarantined
# dispatch_new lines) instead, so the poisoned line is simply absent from
# it; the resulting global `quarantine_unattributable` flag additionally
# blocks EVERY closeable issue this tick (belt-and-suspenders), so neither
# I-501 nor I-502 auto-closes, and the map is proven unpoisoned directly.
section_ac_g1p5_dispatch_new_duplicate_i_poison() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i501-x)"

  seed_verified_dispatch "$repo" D-501 I-501 zzz-test-tab-501 i501-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-501 OPEN ACTIVE
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"
  seed_issue_state "$repo" I-502 OPEN ACTIVE

  PM_ROOT="$repo" pm_raw_append_literal \
    "EVENT dispatch_new d=D-501 i=I-501 at=$(now_iso) i=I-502"

  run_track "$repo"
  assert_ac_surfaced "ac g1.5 dispatch_new dup-i= poison: I-502 does NOT false-close" \
    "$repo" "I-502" "quarantine-unattributable-blocks-autoclose"
  assert_ac_surfaced "ac g1.5 dispatch_new dup-i= poison: I-501 evaluated on its own merits (globally blocked, not wrongly closed)" \
    "$repo" "I-501" "quarantine-unattributable-blocks-autoclose"
  assert_eq "ac g1.5 dispatch_new dup-i= poison: authoritative map D-501 -> I-501 (unpoisoned)" \
    "I-501" "$(python3 -c "
import json
idx = json.load(open('$repo/.pm/index.json'))
print(idx.get('dispatch_issue_map', {}).get('D-501', ''))
")"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i501-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# Critical B: 4 malformed-question variants, each a hard `parse_line`
# grammar failure that a naive reparse (the OLD quarantine_by_issue
# projection, which re-parsed entry["raw"] and silently `continue`d on
# ValueError) would have let slip through as unattributed -- allowing the
# issue it names to auto-close anyway. Each MUST now surface the global
# `quarantine-unattributable-blocks-autoclose` reason and MUST NOT close.
_ac_g1p5_unattributable_variant() {
  local label="$1" issue="$2" raw_line="$3"
  local repo
  repo="$(new_tmp_repo_with_git_ac true)"
  seed_issue_state "$repo" "$issue" OPEN ACTIVE
  PM_ROOT="$repo" pm_raw_append_literal "$raw_line"

  run_track "$repo"
  assert_ac_surfaced "ac g1.5 quarantine-unattributable ($label)" \
    "$repo" "$issue" "quarantine-unattributable-blocks-autoclose"

  rm -rf "$repo"
}

section_ac_g1p5_malformed_question_duplicate_i() {
  _ac_g1p5_unattributable_variant "duplicate i=" I-401 \
    "EVENT question q=Q-1 state=BOGUS at=$(now_iso) i=I-X i=I-401"
}

section_ac_g1p5_malformed_question_quoted_i() {
  _ac_g1p5_unattributable_variant "quoted i=" I-402 \
    "EVENT question q=Q-1 state=BOGUS at=$(now_iso) i=\"I-402\""
}

section_ac_g1p5_malformed_question_trailing_token() {
  _ac_g1p5_unattributable_variant "trailing token" I-403 \
    "EVENT question q=Q-1 state=BOGUS at=$(now_iso) i=I-403 trailing"
}

section_ac_g1p5_malformed_question_bad_q() {
  _ac_g1p5_unattributable_variant "malformed q=" I-404 \
    "EVENT question q=\"Q 4\" state=BOGUS at=$(now_iso) i=I-404"
}

# Regression guard: a CLEAN, otherwise-closeable issue with an EMPTY
# quarantine (no quarantined lines at all) must still close normally --
# `quarantine_unattributable` must NOT be set, and G1.5 must be a no-op.
section_ac_g1p5_no_regression_clean_quarantine_still_closes() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i995-x)"

  seed_verified_dispatch "$repo" D-995 I-995 zzz-test-tab-995 i995-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-995 OPEN ACTIVE
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"

  run_track "$repo"
  assert_ac_closed "ac g1.5 no-regression: clean quarantine still closes" "$repo" "I-995"
  assert_eq "ac g1.5 no-regression: quarantine_unattributable is false/absent" \
    "False" "$(python3 -c "
import json
idx = json.load(open('$repo/.pm/index.json'))
print(bool(idx.get('quarantine_unattributable')))
")"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i995-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# AC.G1.5 round-3 (Codex-sparred, round 25): the misattribution variant.
# Quarantine attribution must resolve a quarantined entry's blast radius
# through the fold's OWN authoritative maps (dispatch_issue_raw / questions),
# not the offending line's own forged `i=`. A bad line can carry a d=/q=
# whose REAL owner is issue A while forging i=B -- the fix must still block
# A (the real owner), not just B (whatever the forgery names), even though
# B is additively blocked too since B is itself a registered issue.
# ---------------------------------------------------------------------------

# Case 1: D-501 is VERIFIED+merged, authoritatively registered to I-501 (its
# real owner via dispatch_issue_raw, set at D-501's FIRST valid dispatch_new).
# A second, grammar-VALID dispatch_new for the SAME d= (a business-rule
# duplicate, not a grammar failure) forges i=I-502 -- fold quarantines it as
# a duplicate registration. Pre-fix, attribution trusted the forged i=I-502
# alone, leaving I-501 unblocked and free to auto-close on D-501's real
# VERIFIED+merged work despite the poisoned line right there in the log.
section_ac_g1p5_misattribution_dispatch_new() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i5011-x)"

  seed_verified_dispatch "$repo" D-501 I-501 zzz-test-tab-5011 i5011-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-501 OPEN ACTIVE
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"
  seed_issue_state "$repo" I-502 OPEN ACTIVE

  # Grammar-valid duplicate dispatch_new for D-501 forging i=I-502 (D-501's
  # real owner is I-501, per the first valid dispatch_new above).
  PM_ROOT="$repo" pm_raw_append dispatch_new d=D-501 i=I-502 at="$(now_iso)"

  run_track "$repo"
  assert_ac_surfaced "ac g1.5 misattribution (dispatch_new): I-501 (real owner of D-501) must NOT false-close" \
    "$repo" "I-501" "issue-related-quarantine"
  assert_true "ac g1.5 misattribution (dispatch_new): quarantine_by_issue contains I-501" \
    bash -c "python3 -c \"
import json
idx = json.load(open('$repo/.pm/index.json'))
assert 'I-501' in idx.get('quarantine_by_issue', {}), idx.get('quarantine_by_issue')
\""
  assert_eq "ac g1.5 misattribution (dispatch_new): authoritative dispatch_issue_map D-501 -> I-501 (unpoisoned)" \
    "I-501" "$(python3 -c "
import json
idx = json.load(open('$repo/.pm/index.json'))
print(idx.get('dispatch_issue_map', {}).get('D-501', ''))
")"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i5011-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# Companion to section_ac_g1p5_dispatch_new_duplicate_i_poison (grammar-
# INVALID double-`i=`-key line -> global quarantine_unattributable) and
# to section_ac_g1p5_misattribution_dispatch_new above: this variant is
# grammar-VALID (single `i=` key), so the duplicate `d=D-501` is quarantined
# only by apply_event's business-rule duplicate-registration check, exercising
# the authoritative-owner attribution path directly (not the parse-failure
# fallback). Asserts BOTH the authoritative owner (I-501, via
# dispatch_issue_raw) AND the forged-but-registered `i=I-502` are additively
# present in quarantine_by_issue, the map stays unpoisoned, the global
# unattributable flag is NOT set (this entry resolved cleanly), and the real
# owner I-501 -- otherwise fully closeable (VERIFIED + strict-merged) -- is
# blocked from auto-close with the scoped 'issue-related-quarantine' reason.
section_ac_g1p5_dispatch_new_duplicate_valid_grammar_attribution() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i5021-x)"

  seed_issue_state "$repo" I-501 OPEN ACTIVE
  seed_issue_state "$repo" I-502 OPEN ACTIVE
  seed_verified_dispatch "$repo" D-501 I-501 zzz-test-tab-5021 i5021-x "$base_sha" "$tip"
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"

  # Grammar-VALID duplicate dispatch_new for D-501 (single i= key) -- quarantined
  # only as a business-rule duplicate registration by apply_event, forging i=I-502.
  PM_ROOT="$repo" pm_raw_append dispatch_new d=D-501 i=I-502 at="$(now_iso)"

  run_track "$repo"

  assert_eq "ac g1.5 dispatch_new dup (valid grammar): quarantine_by_issue[I-501] reason" \
    "issue-related-quarantine" "$(python3 -c "
import json
idx = json.load(open('$repo/.pm/index.json'))
reasons = idx.get('quarantine_by_issue', {}).get('I-501', [])
print(reasons[0] if reasons else '')
")"
  assert_eq "ac g1.5 dispatch_new dup (valid grammar): quarantine_by_issue[I-502] reason (additive forged i=)" \
    "issue-related-quarantine" "$(python3 -c "
import json
idx = json.load(open('$repo/.pm/index.json'))
reasons = idx.get('quarantine_by_issue', {}).get('I-502', [])
print(reasons[0] if reasons else '')
")"
  assert_eq "ac g1.5 dispatch_new dup (valid grammar): authoritative dispatch_issue_map D-501 -> I-501 (unpoisoned)" \
    "I-501" "$(python3 -c "
import json
idx = json.load(open('$repo/.pm/index.json'))
print(idx.get('dispatch_issue_map', {}).get('D-501', ''))
")"
  assert_eq "ac g1.5 dispatch_new dup (valid grammar): quarantine_unattributable is NOT set (entry resolved cleanly)" \
    "False" "$(python3 -c "
import json
idx = json.load(open('$repo/.pm/index.json'))
print(bool(idx.get('quarantine_unattributable')))
")"
  assert_ac_surfaced "ac g1.5 dispatch_new dup (valid grammar): I-501 (real owner of D-501) must NOT false-close" \
    "$repo" "I-501" "issue-related-quarantine"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i5021-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# Case 2: Q-601 is validly, authoritatively linked to I-601 via a PRIOR
# successfully-applied `question` event (state["questions"]["Q-601"]["i"] ==
# I-601). A subsequent line reusing q=Q-601 with an illegal state=BOGUS
# forges i=I-602 -- fold quarantines it (invalid question state). Pre-fix,
# attribution trusted the forged i=I-602 alone, leaving I-601 (Q-601's real
# owner) unblocked and free to auto-close.
section_ac_g1p5_misattribution_question() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i601-x)"

  # T6: I-601 is OTHERWISE FULLY CLOSEABLE (VERIFIED + strictly merged) --
  # so an attribution regression (trusting the forged i=I-602 alone and
  # leaving Q-601's real owner unblocked) would ACTUALLY close it, not
  # just coincidentally leave it open for want of a dispatch.
  seed_verified_dispatch "$repo" D-601 I-601 zzz-test-tab-601 i601-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-601 OPEN ACTIVE
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"
  seed_issue_state "$repo" I-602 OPEN ACTIVE
  seed_question "$repo" Q-601 ANSWERED I-601

  PM_ROOT="$repo" pm_raw_append question q=Q-601 state=BOGUS at="$(now_iso)" i=I-602

  run_track "$repo"
  assert_ac_surfaced "ac g1.5 misattribution (question): I-601 (real owner of Q-601) must NOT false-close" \
    "$repo" "I-601" "invalid-question-state"
  assert_true "ac g1.5 misattribution (question): quarantine_by_issue contains I-601" \
    bash -c "python3 -c \"
import json
idx = json.load(open('$repo/.pm/index.json'))
assert 'I-601' in idx.get('quarantine_by_issue', {}), idx.get('quarantine_by_issue')
\""

  git -C "$gitrepo" worktree remove --force "$repo/wt-i601-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# Unknown-entity variant: a quarantined `question` event names a BRAND-NEW
# q= (never validly registered to any issue) and forges an i= that does not
# name any REGISTERED issue either. Neither q nor the forged i= resolves to
# anything authoritative or corroborated -- the entry must fall through to
# the global `quarantine_unattributable` flag (conservative), blocking every
# otherwise-closeable issue for the tick, rather than being scoped to the
# unregistered forged i=.
section_ac_g1p5_misattribution_unknown_entity() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i701-x)"

  # An unrelated, otherwise-fully-closeable issue that must be blocked ONLY
  # because the global flag fires (not because it is itself implicated).
  seed_verified_dispatch "$repo" D-701 I-701 zzz-test-tab-701 i701-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-701 OPEN ACTIVE
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"

  # Brand-new q=Q-702 (never seen before) with a forged i=I-999 that was
  # NEVER registered via issue_state -- no corroboration for either token.
  PM_ROOT="$repo" pm_raw_append question q=Q-702 state=BOGUS at="$(now_iso)" i=I-999

  run_track "$repo"
  assert_ac_surfaced "ac g1.5 misattribution unknown-entity: unrelated closeable I-701 blocked by global flag" \
    "$repo" "I-701" "quarantine-unattributable-blocks-autoclose"
  assert_eq "ac g1.5 misattribution unknown-entity: quarantine_unattributable is true" \
    "True" "$(python3 -c "
import json
idx = json.load(open('$repo/.pm/index.json'))
print(bool(idx.get('quarantine_unattributable')))
")"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i701-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# AC.G2 open-question gates.
# ---------------------------------------------------------------------------
section_ac_g2_open_question_for_issue() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i965-x)"

  seed_verified_dispatch "$repo" D-965 I-965 zzz-test-tab-965 i965-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-965 OPEN ACTIVE
  seed_question "$repo" Q-965 OPEN I-965
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"

  run_track "$repo"
  assert_ac_surfaced "ac g2 open-question-for-issue" "$repo" "I-965" "open-question-for-issue"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i965-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

section_ac_g2_open_question_unscoped() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i966-x)"

  seed_verified_dispatch "$repo" D-966 I-966 zzz-test-tab-966 i966-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-966 OPEN ACTIVE
  seed_question "$repo" Q-966 OPEN
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"

  run_track "$repo"
  assert_ac_surfaced "ac g2 open-question-unscoped" "$repo" "I-966" "open-question-unscoped"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i966-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# AC.G3 dispatch-graph gates.
# ---------------------------------------------------------------------------
section_ac_g3_dispatch_not_verified() {
  local repo
  repo="$(new_tmp_repo_with_git_ac true)"
  seed_acked_dispatch "$repo" D-967 I-967 zzz-test-tab-967
  seed_issue_state "$repo" I-967 OPEN ACTIVE

  run_track "$repo"
  assert_ac_surfaced "ac g3 dispatch-not-VERIFIED" "$repo" "I-967" "dispatch-not-VERIFIED"

  rm -rf "$repo"
}

# Cross-issue child_of roll-up: I-968's own dispatch D-968 is fully
# closeable, but a SEPARATE, still-active dispatch D-969 (belonging to a
# DIFFERENT issue I-969x) is child_of=D-968 -> blocks I-968's close.
section_ac_g3_parent_child_rollup() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i968-x)"

  seed_verified_dispatch "$repo" D-968 I-968 zzz-test-tab-968 i968-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-968 OPEN ACTIVE
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"
  seed_issue_state "$repo" I-969x OPEN ACTIVE
  PM_ROOT="$repo" pm_apply dispatch_new d=D-969 i=I-969x at="$(now_iso)" child_of=D-968 >/dev/null

  run_track "$repo"
  assert_ac_surfaced "ac g3 parent/child-roll-up-violation" "$repo" "I-968" "parent/child-roll-up-violation"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i968-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# Transitive child_of roll-up (Codex-sparred defect #2, Critical): a
# THREE-level chain where the middle dispatch is itself terminal but its own
# child (the grandchild, two hops from I-983's own dispatch) is still
# active. A direct-children-only walk would check D-984 (terminal ->
# "safe"), stop there, and never look past it -- falsely closing I-983
# while a live grandchild dispatch is still outstanding. Only a walk of the
# FULL descendant graph (any depth) catches this.
section_ac_g3_transitive_child_of_rollup() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i983-x)"

  seed_verified_dispatch "$repo" D-983 I-983 zzz-test-tab-983 i983-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-983 OPEN ACTIVE
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"

  # D-984 (different issue I-984x): child_of=D-983, itself TERMINAL
  # (ABANDONED).
  seed_issue_state "$repo" I-984x OPEN ACTIVE
  PM_ROOT="$repo" pm_apply dispatch_new d=D-984 i=I-984x at="$(now_iso)" child_of=D-983 >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-984 from=READY to=ABANDONED lane=human \
    at="$(now_iso)" >/dev/null
  # D-985 (yet another issue I-985x): child_of=D-984, left READY --
  # non-terminal, still active, and only reachable via a transitive walk.
  seed_issue_state "$repo" I-985x OPEN ACTIVE
  PM_ROOT="$repo" pm_apply dispatch_new d=D-985 i=I-985x at="$(now_iso)" child_of=D-984 >/dev/null

  run_track "$repo"
  assert_ac_surfaced "ac g3 transitive parent/child-roll-up-violation (active grandchild)" \
    "$repo" "I-983" "parent/child-roll-up-violation"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i983-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# Control: same 3-level chain, but the grandchild D-987b is ALSO terminal --
# every descendant anywhere in the graph is terminal, so I-986 closes
# normally. Guards against an over-broad fix that surfaces on the mere
# EXISTENCE of a child_of edge regardless of descendant state.
section_ac_g3_transitive_child_of_rollup_all_terminal() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i986-x)"

  seed_verified_dispatch "$repo" D-986 I-986 zzz-test-tab-986 i986-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-986 OPEN ACTIVE
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"

  seed_issue_state "$repo" I-987ax OPEN ACTIVE
  PM_ROOT="$repo" pm_apply dispatch_new d=D-987a i=I-987ax at="$(now_iso)" child_of=D-986 >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-987a from=READY to=ABANDONED lane=human \
    at="$(now_iso)" >/dev/null
  seed_issue_state "$repo" I-987bx OPEN ACTIVE
  PM_ROOT="$repo" pm_apply dispatch_new d=D-987b i=I-987bx at="$(now_iso)" child_of=D-987a >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-987b from=READY to=ABANDONED lane=human \
    at="$(now_iso)" >/dev/null

  run_track "$repo"
  assert_ac_closed "ac g3 transitive control: all descendants terminal -> closes" "$repo" "I-986"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i986-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# Superseded-by-other-issue: I-970 has TWO dispatches -- D-970 (non-superseded,
# keeps G3's first non-empty check alive) and D-971 (superseded by D-972,
# which belongs to a DIFFERENT issue I-973x) -> blocks I-970's close.
section_ac_g3_superseded_by_other_issue() {
  local repo
  repo="$(new_tmp_repo_with_git_ac true)"
  seed_issue_state "$repo" I-970 OPEN ACTIVE
  seed_acked_dispatch "$repo" D-970 I-970 zzz-test-tab-970
  PM_ROOT="$repo" pm_apply dispatch_new d=D-971 i=I-970 at="$(now_iso)" >/dev/null
  seed_issue_state "$repo" I-973x OPEN ACTIVE
  PM_ROOT="$repo" pm_apply dispatch_new d=D-972 i=I-973x at="$(now_iso)" supersedes=D-971 >/dev/null

  run_track "$repo"
  assert_ac_surfaced "ac g3 superseded-by-other-issue" "$repo" "I-970" "superseded-by-other-issue"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# AC.G4 STRICT git corroboration gates.
# ---------------------------------------------------------------------------

section_ac_g4_result_equals_base() {
  local repo gitrepo base_sha
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"

  seed_verified_dispatch "$repo" D-974 I-974 zzz-test-tab-974 i974-noop-branch "$base_sha" "$base_sha"
  seed_issue_state "$repo" I-974 OPEN ACTIVE

  run_track "$repo"
  assert_ac_surfaced "ac g4 result==base" "$repo" "I-974" "result==base"

  rm -rf "$repo"
}

section_ac_g4_not_descendant() {
  local repo gitrepo base_sha
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"

  git_or_die "ac g4 not-descendant: worktree add -b i975-sibling" \
    -C "$gitrepo" worktree add -q -b i975-sibling "$repo/wt-975-sibling" main
  (
    set -e
    cd "$repo/wt-975-sibling" || exit 1
    printf 'sibling\n' >>README.md
    git add README.md
    git commit -q -m 'sibling commit'
  ) >&2 || { echo "FATAL: fixture git setup failed (ac g4 not-descendant: sibling commit)" >&2; exit 1; }
  base_sha="$(git -C "$gitrepo" rev-parse i975-sibling)"

  git_or_die "ac g4 not-descendant: worktree add -b i975-worker" \
    -C "$gitrepo" worktree add -q -b i975-worker "$repo/wt-975" main
  (
    set -e
    cd "$repo/wt-975" || exit 1
    printf 'unrelated\n' >>README.md
    git add README.md
    git commit -q -m 'unrelated work, not based on i975-sibling'
  ) >&2 || { echo "FATAL: fixture git setup failed (ac g4 not-descendant: worker commit)" >&2; exit 1; }
  local tip
  tip="$(git -C "$repo/wt-975" rev-parse HEAD)"

  seed_verified_dispatch "$repo" D-975 I-975 zzz-test-tab-975 i975-worker "$base_sha" "$tip"
  seed_issue_state "$repo" I-975 OPEN ACTIVE

  run_track "$repo"
  assert_ac_surfaced "ac g4 result-not-descendant-of-base" "$repo" "I-975" "result-not-descendant-of-base"

  git -C "$gitrepo" worktree remove --force "$repo/wt-975" >/dev/null 2>&1 || true
  git -C "$gitrepo" worktree remove --force "$repo/wt-975-sibling" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

section_ac_g4_mainline_ref_not_configured() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  cat >"$repo/.pm/config.json" <<JSON
{"repos": {"demo-repo": {"path": "$gitrepo", "mainline": "main"}}, "herdr_workspace": "zzz-test-ws", "automation": {"auto_close": true}}
JSON
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i976-x)"

  seed_verified_dispatch "$repo" D-976 I-976 zzz-test-tab-976 i976-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-976 OPEN ACTIVE

  run_track "$repo"
  assert_ac_surfaced "ac g4 mainline-ref-not-configured" "$repo" "I-976" "mainline-ref-not-configured"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i976-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

section_ac_g4_mainline_ref_missing() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  # A short/unqualified ref value (not a full refs/... path, and also not an
  # existing ref) -- covers both the "doesn't start with refs/" shape check
  # and the "doesn't resolve" reachability check, which share this reason.
  cat >"$repo/.pm/config.json" <<JSON
{"repos": {"demo-repo": {"path": "$gitrepo", "mainline": "main", "mainline_ref": "main", "fetch_policy": "local-only"}}, "herdr_workspace": "zzz-test-ws", "automation": {"auto_close": true}}
JSON
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i977-x)"

  seed_verified_dispatch "$repo" D-977 I-977 zzz-test-tab-977 i977-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-977 OPEN ACTIVE

  run_track "$repo"
  assert_ac_surfaced "ac g4 mainline-ref-missing" "$repo" "I-977" "mainline-ref-missing"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i977-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# AC.G4 non-string `mainline` + fetch_policy=fetch (Codex-sparred defect #3,
# High, fix (c)): `mainline_ref` is well-formed (refs/remotes/origin/main,
# so the earlier shape checks pass and the fetch_policy=="fetch" branch is
# reached), but `mainline` itself is a JSON NUMBER, not a string. Pre-fix,
# `"+refs/heads/" + mainline + ...` raises TypeError deep inside
# tr_g4_check (string + int) -- this is the exact crash the per-issue
# try/except (fix 3b) and the driver-level belt-and-suspenders (fix 3a)
# exist to catch instead of vanishing silently. The type-guard (fix c)
# catches it earliest and most precisely (surfaces mainline-ref-missing
# WITHOUT ever needing a real "origin" remote -- the guard short-circuits
# before any fetch subprocess is attempted), so this is the first line of
# defense; the other two are the safety net behind it (see the red/green
# notes in the final report for how a staged revert of (c) then (b)
# exercises all three sub-fixes with this one scenario).
section_ac_g4_mainline_non_string_type_guard() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  cat >"$repo/.pm/config.json" <<JSON
{"repos": {"demo-repo": {"path": "$gitrepo", "mainline": 123, "mainline_ref": "refs/remotes/origin/main", "fetch_policy": "fetch"}}, "herdr_workspace": "zzz-test-ws", "automation": {"auto_close": true}}
JSON
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i990-x)"

  seed_verified_dispatch "$repo" D-990 I-990 zzz-test-tab-990 i990-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-990 OPEN ACTIVE

  run_track "$repo"
  assert_ac_surfaced "ac g4 non-string mainline + fetch_policy=fetch -> mainline-ref-missing (no crash)" \
    "$repo" "I-990" "mainline-ref-missing"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i990-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# no-strict-ancestry-and-no-valid-marker: result_sha is a real, valid,
# base-descendant commit, but was simply never merged to mainline (main
# stays put) -- the default, un-merged state of ac_make_worker_commit's
# output. STRICT topology alone (never patch-id/cherry/content-equivalence)
# refuses to call this "merged".
section_ac_g4_not_on_mainline() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i978-x)"

  seed_verified_dispatch "$repo" D-978 I-978 zzz-test-tab-978 i978-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-978 OPEN ACTIVE
  # deliberately no ac_merge_worker_tip_to_mainline call -- main is untouched.

  run_track "$repo"
  assert_ac_surfaced "ac g4 no-strict-ancestry-and-no-valid-marker" "$repo" "I-978" \
    "no-strict-ancestry-and-no-valid-marker"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i978-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# AC.G4 GIT_NO_REPLACE_OBJECTS=1 on EVERY git call (Codex-sparred defect #4,
# Medium) -- not just the ones inside tr_g4_check's own local run() closure.
# Runs a normal closing tick with a `git` shim (make_git_env_wrapper) on
# PATH and asserts: (1) the tick still closes normally (control -- the
# wrapper is transparent/exec's through to the real git); (2) EVERY logged
# git invocation carried GIT_NO_REPLACE_OBJECTS=1; (3) the specific graft
# probe (tr_repo_has_grafts: `rev-parse --git-path info/grafts`) and
# identity-anchor (tr_verify_commit: `rev-parse --verify --end-of-options
# <sha>^{commit}`) calls were both actually observed carrying it.
section_ac_g4_replace_objects_env_on_every_git_call() {
  local repo gitrepo base_sha tip wrapper_dir log_file
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i992-x)"

  seed_verified_dispatch "$repo" D-992 I-992 zzz-test-tab-992 i992-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-992 OPEN ACTIVE
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"

  wrapper_dir="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-git-wrapper.XXXXXX")"
  log_file="$(mktemp "${TMPDIR:-/tmp}/pm-creator-git-wrapper-log.XXXXXX")"
  make_git_env_wrapper "$wrapper_dir" "$log_file"

  run_track_with_git_wrapper "$repo" "$wrapper_dir"
  assert_ac_closed "ac g4 git-env-wrapper control: still closes with wrapper on PATH" "$repo" "I-992"

  if [[ ! -s "$log_file" ]]; then
    fail "ac g4 git-env-wrapper: git calls were logged" "wrapper never invoked -- $log_file is empty"
  else
    local missing_env
    missing_env="$(grep -vc '^1|' "$log_file")"
    if [[ "$missing_env" == "0" ]]; then
      ok "ac g4 git-env-wrapper: all logged git calls carried GIT_NO_REPLACE_OBJECTS=1"
    else
      fail "ac g4 git-env-wrapper: all logged git calls carried GIT_NO_REPLACE_OBJECTS=1" \
        "$missing_env call(s) missing it: $(grep -v '^1|' "$log_file" | tr '\n' ';')"
    fi
    if grep -q 'rev-parse --git-path info/grafts' "$log_file"; then
      ok "ac g4 git-env-wrapper: graft-probe call observed"
    else
      fail "ac g4 git-env-wrapper: graft-probe call observed" "no matching line in $log_file"
    fi
    if grep -q 'rev-parse --verify --end-of-options' "$log_file"; then
      ok "ac g4 git-env-wrapper: identity-anchor call observed"
    else
      fail "ac g4 git-env-wrapper: identity-anchor call observed" "no matching line in $log_file"
    fi
    if grep -q 'rev-parse --git-path info/grafts' "$log_file" && ! grep '^<unset>|' "$log_file" | grep -q 'rev-parse --git-path info/grafts'; then
      ok "ac g4 git-env-wrapper: graft-probe call carried GIT_NO_REPLACE_OBJECTS=1"
    else
      fail "ac g4 git-env-wrapper: graft-probe call carried GIT_NO_REPLACE_OBJECTS=1" \
        "grafts call missing or unset in $log_file"
    fi
    if grep -q 'rev-parse --verify --end-of-options' "$log_file" && ! grep '^<unset>|' "$log_file" | grep -q 'rev-parse --verify --end-of-options'; then
      ok "ac g4 git-env-wrapper: identity-anchor call carried GIT_NO_REPLACE_OBJECTS=1"
    else
      fail "ac g4 git-env-wrapper: identity-anchor call carried GIT_NO_REPLACE_OBJECTS=1" \
        "identity-anchor call missing or unset in $log_file"
    fi
  fi

  git -C "$gitrepo" worktree remove --force "$repo/wt-i992-x" >/dev/null 2>&1 || true
  rm -rf "$repo" "$wrapper_dir"
  rm -f "$log_file"
}

# ---------------------------------------------------------------------------
# AC.G4 fetch_policy=fetch (Codex-sparred defect #5, Low) -- previously
# untested; every other G4 fixture in this file uses fetch_policy=local-only.
# Uses a local BARE repo as "origin" (never a real network remote) so the
# real `git fetch` codepath in tr_g4_check actually runs, herdr-shadowed +
# zzz-test-* only, matching every other fixture here.
# ---------------------------------------------------------------------------
section_ac_g4_fetch_policy_success() {
  local repo gitrepo origin_bare base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  origin_bare="$repo/origin.git"

  git_or_die "fetch-success: init bare origin" init -q --bare "$origin_bare"
  git_or_die "fetch-success: add origin remote" -C "$gitrepo" remote add origin "$origin_bare"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  git_or_die "fetch-success: push initial main to origin" -C "$gitrepo" push -q origin main

  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i993-x)"
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"
  git_or_die "fetch-success: push merged main to origin" -C "$gitrepo" push -q origin main

  cat >"$repo/.pm/config.json" <<JSON
{"repos": {"demo-repo": {"path": "$gitrepo", "mainline": "main", "mainline_ref": "refs/remotes/origin/main", "fetch_policy": "fetch"}}, "herdr_workspace": "zzz-test-ws", "automation": {"auto_close": true}}
JSON

  seed_verified_dispatch "$repo" D-993 I-993 zzz-test-tab-993 i993-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-993 OPEN ACTIVE

  run_track "$repo"
  assert_ac_closed "ac g4 fetch_policy=fetch: successful fetch+close" "$repo" "I-993"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i993-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

section_ac_g4_fetch_policy_failed() {
  local repo gitrepo unreachable base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  unreachable="$repo/does-not-exist-origin.git"

  git_or_die "fetch-failed: add origin remote (unreachable path)" \
    -C "$gitrepo" remote add origin "$unreachable"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i994-x)"
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"

  cat >"$repo/.pm/config.json" <<JSON
{"repos": {"demo-repo": {"path": "$gitrepo", "mainline": "main", "mainline_ref": "refs/remotes/origin/main", "fetch_policy": "fetch"}}, "herdr_workspace": "zzz-test-ws", "automation": {"auto_close": true}}
JSON

  seed_verified_dispatch "$repo" D-994 I-994 zzz-test-tab-994 i994-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-994 OPEN ACTIVE

  run_track "$repo"
  assert_ac_surfaced "ac g4 fetch_policy=fetch: unreachable origin -> fetch-failed" \
    "$repo" "I-994" "fetch-failed"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i994-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# AC.OFF automation.auto_close=false (default) -- an otherwise fully
# closeable issue is surfaced, never closed.
# ---------------------------------------------------------------------------
section_ac_auto_close_disabled() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac false)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i979-x)"

  seed_verified_dispatch "$repo" D-979 I-979 zzz-test-tab-979 i979-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-979 OPEN ACTIVE
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"

  run_track "$repo"
  assert_ac_surfaced "ac auto_close OFF" "$repo" "I-979" "auto-close-disabled"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i979-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# AC.SAMETICK same-tick safety: a `done` tab RECORDED as RETURNED by THIS
# SAME tick's intake pass is not yet VERIFIED (human gate not yet applied),
# so G3 naturally blocks its issue from auto-closing in the same tick --
# no auto-record -> auto-close cascade in one tick.
#
# Deliberately does NOT pre-merge the worker's tip into mainline (unlike
# sibling AC sections that seed an already-RETURNED/VERIFIED dispatch): the
# C1 fix refuses stage-1 git corroboration (RECORD) for a branch tip that's
# already reachable from mainline (branch-contains-no-new-work) -- doing
# that here would prevent D-980 from ever reaching RETURNED this tick,
# which is orthogonal to what this section actually asserts (G3's
# dispatch-not-VERIFIED gate fires irrespective of mainline state).
# ---------------------------------------------------------------------------
section_ac_same_tick_safety() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i980-x)"

  seed_acked_dispatch "$repo" D-980 I-980 zzz-test-tab-980 i980-x "$base_sha"
  seed_issue_state "$repo" I-980 OPEN ACTIVE

  run_track "$repo" "$(snapshot_json zzz-test-tab-980 "done" "i980-x")"
  assert_eq "ac same-tick: exit 0" "0" "$TR_RC"
  assert_true "ac same-tick: dispatch D-980 recorded RETURNED this tick" \
    bash -c '
      python3 -c "
import json
idx = json.load(open(\"$1/.pm/index.json\"))
print(idx[\"dispatches\"][\"D-980\"][\"state\"])
" | grep -qx RETURNED
    ' _ "$repo"
  assert_ac_surfaced "ac same-tick: I-980 NOT auto-closed this same tick" "$repo" "I-980" "dispatch-not-VERIFIED"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i980-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# AC P2-1: G4's network fetch must never run in an OFF tick (zero git fetch
# invocations at all), and an ON tick fetches each configured (repo,ref) at
# most ONCE per tick (pre-fetch phase), not once per closeable issue.
# ---------------------------------------------------------------------------
section_ac_p21_off_mode_zero_network() {
  local repo gitrepo base_sha tip wrapper_dir log_file
  repo="$(new_tmp_repo_with_git_ac false)"
  gitrepo="$repo/target-repo"
  ac_add_local_origin "$repo" "$gitrepo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i201-x)"
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"
  git_or_die "p21 off: push merged main" -C "$gitrepo" push -q origin main
  ac_fetch_policy_config "$repo" "$gitrepo" false

  seed_verified_dispatch "$repo" D-201 I-201 zzz-test-tab-201 i201-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-201 OPEN ACTIVE

  wrapper_dir="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-git-wrapper.XXXXXX")"
  log_file="$(mktemp "${TMPDIR:-/tmp}/pm-creator-git-wrapper-log.XXXXXX")"
  make_git_env_wrapper "$wrapper_dir" "$log_file"
  run_track_with_git_wrapper "$repo" "$wrapper_dir"

  assert_ac_surfaced "ac p2-1 OFF-mode" "$repo" "I-201" "auto-close-disabled"
  assert_eq "ac p2-1 OFF-mode: zero 'git fetch' invocations in an OFF tick" \
    "0" "$(grep -c '|fetch ' "$log_file")"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i201-x" >/dev/null 2>&1 || true
  rm -rf "$repo" "$wrapper_dir"
  rm -f "$log_file"
}

section_ac_p21_one_fetch_per_repo_ref_per_tick() {
  local repo gitrepo base_sha tip2 tip3 wrapper_dir log_file
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  ac_add_local_origin "$repo" "$gitrepo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"

  # Two closeable issues sharing the SAME repo -- worker commits touch
  # DIFFERENT files so both merge cleanly into main.
  tip2="$(ac_make_worker_commit "$gitrepo" "$repo" i202-x)"
  git_or_die "p21 on: branch i203-x" -C "$gitrepo" branch i203-x main
  git_or_die "p21 on: worktree add wt-i203-x" -C "$gitrepo" worktree add -q "$repo/wt-i203-x" i203-x
  (
    set -e
    cd "$repo/wt-i203-x" || exit 1
    printf 'other work\n' >second.txt
    git add second.txt
    git commit -q -m 'other work'
  ) >&2 || { echo "FATAL: fixture git setup failed (p21 on: i203-x commit)" >&2; exit 1; }
  tip3="$(git -C "$repo/wt-i203-x" rev-parse HEAD)"

  # Merge BOTH branches into main (real merge commits, main checked out in
  # the primary worktree) and push, so both tips are strict main ancestors.
  git_or_die "p21 on: merge i202-x" -C "$gitrepo" merge -q -m 'merge i202-x' "$tip2"
  git_or_die "p21 on: merge i203-x" -C "$gitrepo" merge -q -m 'merge i203-x' "$tip3"
  git_or_die "p21 on: push merged main" -C "$gitrepo" push -q origin main
  ac_fetch_policy_config "$repo" "$gitrepo" true

  seed_verified_dispatch "$repo" D-202 I-202 zzz-test-tab-202 i202-x "$base_sha" "$tip2"
  seed_issue_state "$repo" I-202 OPEN ACTIVE
  seed_verified_dispatch "$repo" D-203 I-203 zzz-test-tab-203 i203-x "$base_sha" "$tip3"
  seed_issue_state "$repo" I-203 OPEN ACTIVE

  wrapper_dir="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-git-wrapper.XXXXXX")"
  log_file="$(mktemp "${TMPDIR:-/tmp}/pm-creator-git-wrapper-log.XXXXXX")"
  make_git_env_wrapper "$wrapper_dir" "$log_file"
  run_track_with_git_wrapper "$repo" "$wrapper_dir"

  assert_ac_closed "ac p2-1 ON single-fetch: I-202 closes" "$repo" "I-202"
  assert_ac_closed "ac p2-1 ON single-fetch: I-203 closes" "$repo" "I-203"
  assert_eq "ac p2-1 ON: exactly 1 'git fetch' for the shared (repo,ref) with 2 closeable issues" \
    "1" "$(grep -c '|fetch ' "$log_file")"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i202-x" >/dev/null 2>&1 || true
  git -C "$gitrepo" worktree remove --force "$repo/wt-i203-x" >/dev/null 2>&1 || true
  rm -rf "$repo" "$wrapper_dir"
  rm -f "$log_file"
}

# ---------------------------------------------------------------------------
# AC P2-2: G4 must bind result_sha to the dispatch's OWN recorded branch
# (branch tip == result_sha, or result_sha ancestor-of branch tip). A forged
# `result` naming ANY already-merged commit (e.g. the mainline tip itself)
# that never lived on the dispatch's branch must SURFACE, never close; a
# missing/deleted/unresolvable branch is fail-closed the same way.
# ---------------------------------------------------------------------------
section_ac_p22_forged_result_sha_mainline_tip() {
  local repo gitrepo base_sha main_tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  # Real worker branch with a real (un-merged) commit; its tip itself is
  # not needed -- the forged result below deliberately names main's tip.
  ac_make_worker_commit "$gitrepo" "$repo" i211-x >/dev/null
  # Advance mainline by an UNRELATED commit (descends from base, never on
  # the dispatch's branch) -- the forged result_sha.
  (
    set -e
    cd "$gitrepo" || exit 1
    printf 'unrelated mainline work\n' >>README.md
    git add README.md
    git commit -q -m 'unrelated mainline work'
  ) >&2 || { echo "FATAL: fixture git setup failed (p22 forged: mainline commit)" >&2; exit 1; }
  main_tip="$(git -C "$gitrepo" rev-parse HEAD)"

  # Forged result: result_sha = mainline tip, NOT on branch i211-x.
  seed_verified_dispatch "$repo" D-211 I-211 zzz-test-tab-211 i211-x "$base_sha" "$main_tip"
  seed_issue_state "$repo" I-211 OPEN ACTIVE

  run_track "$repo"
  assert_ac_surfaced "ac p2-2 forged result_sha=mainline-tip" "$repo" "I-211" "result-not-bound-to-branch"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i211-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

section_ac_p22_branch_deleted() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i212-x)"

  seed_verified_dispatch "$repo" D-212 I-212 zzz-test-tab-212 i212-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-212 OPEN ACTIVE
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"

  # Post-merge branch cleanup happened before the tick: worktree + branch
  # are gone. The binding gate can no longer corroborate result_sha against
  # the branch -> fail-closed surface, never close.
  git_or_die "p22 branch-deleted: worktree remove" -C "$gitrepo" worktree remove --force "$repo/wt-i212-x"
  git_or_die "p22 branch-deleted: branch -D i212-x" -C "$gitrepo" branch -q -D i212-x

  run_track "$repo"
  assert_ac_surfaced "ac p2-2 branch-deleted" "$repo" "I-212" "result-not-bound-to-branch"

  rm -rf "$repo"
}

# AC fix-pass-5b item 1: dispatch's own `branch` field (index-sourced, read
# straight from disp.get("branch") in G4) is unvalidated -- it is used to
# build `refs/heads/<branch>` for the P2-2 binding check with NO shape/
# ticket-convention check applied at G4 time (stage-1's F1 gate only runs
# at ACK-recording time; a corrupted/forged index `branch` field never
# passes back through F1). A REAL, non-ticket-convention branch ("evil",
# never matching TICKET_RE's `i<digits>-` prefix) with an otherwise fully
# satisfiable binding (its own tip == result_sha) must still be REJECTED
# at G4 -- reusing/mirroring F1's own TICKET_RE branch-shape check --
# rather than being allowed to silently satisfy the P2-2 binding predicate
# and close.
section_ac_p22_branch_not_ticket_convention() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" evil)"

  seed_verified_dispatch "$repo" D-213 I-213 zzz-test-tab-213 evil "$base_sha" "$tip"
  seed_issue_state "$repo" I-213 OPEN ACTIVE
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"

  run_track "$repo"
  assert_ac_surfaced "ac fix-pass-5b#1 non-ticket-convention branch 'evil' rejected at G4" \
    "$repo" "I-213" "result-not-bound-to-branch"

  git -C "$gitrepo" worktree remove --force "$repo/wt-evil" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# AC fix-pass-5b item 2: the close-outcome classifier
# (tr_ac_classify_close_failure, defined in templates/bin/_track_autoclose,
# track's sourced auto-close component) must key
# on WHOLE stderr LINES that _lib.sh itself emits with a `<token>: ...`
# prefix (P3-4) -- never a bare substring match over the captured blob,
# which embeds pm_apply's own output and could let attacker/data-controlled
# text (e.g. an echoed detail or filename) containing a token mid-line
# forge a classification. Extracts and sources ONLY the function
# definition (never the whole `track` script, which has no main-guard and
# would run real side effects) so this is a true unit-level test.
section_ac_close_classifier_line_anchored() {
  local track_bin="$TRACK_AUTOCLOSE" fn_file got
  fn_file="$(mktemp)"

  awk '/^tr_ac_classify_close_failure\(\) \{/,/^}/' "$track_bin" > "$fn_file"
  assert_true "fix-pass-5b#2: extracted classifier function is non-empty" \
    bash -c '[[ -s "$1" ]]' _ "$fn_file"
  # shellcheck disable=SC1090
  source "$fn_file"

  # A token forged MID-LINE (embedded inside an unrelated message, as a
  # real pm_apply detail or filename could be) must NOT classify.
  got="$(tr_ac_classify_close_failure "close: refusing note ref=archived:I-1 (detail mentions close-transition-durable in passing). No event was emitted.")"
  assert_true "fix-pass-5b#2: token embedded mid-line does NOT classify as closed-with-pending-archive" \
    bash -c '[[ "$1" != "closed-with-pending-archive" ]]' _ "$got"

  got="$(tr_ac_classify_close_failure "close: failed to archive prompts/I-1_close-refused-state-race-note.md (mv: some other real error)")"
  assert_true "fix-pass-5b#2: token embedded mid-line (filename) does NOT classify as close-race/refusal" \
    bash -c '[[ "$1" != "close-race/refusal" ]]' _ "$got"

  # A token on its OWN, properly-prefixed line still classifies correctly.
  got="$(tr_ac_classify_close_failure "$(printf 'close: some preamble\nclose-transition-durable: I-1 is durably CLOSED on the log; a later archive/note step failed\n')")"
  assert_true "fix-pass-5b#2: genuine line-anchored token still classifies as closed-with-pending-archive" \
    bash -c '[[ "$1" == "closed-with-pending-archive" ]]' _ "$got"

  got="$(tr_ac_classify_close_failure "$(printf 'close-refused-state-race: refusing to close I-1: current=ACTIVE requested=CLOSED. No event was emitted.\n')")"
  assert_true "fix-pass-5b#2: genuine line-anchored token still classifies as close-race/refusal" \
    bash -c '[[ "$1" == "close-race/refusal" ]]' _ "$got"

  rm -f "$fn_file"
}

# AC fix-pass-5b item 3: the AC driver (`_tr_ac_driver`, concatenated with
# _TR_CORROB_PY + _TR_CLOSE_PY at its real call site so REASONS is in
# scope) must enforce that every surfaced/rearchive verdict's `reason` is a
# REGISTERED token in the REASONS frozenset -- an unregistered token must
# NEVER be written verbatim into a verdict row (silent registry drift);
# it must instead fail LOUD as `auto-close-driver-error`. This is exercised
# by running the REAL, unmodified driver source (extracted verbatim from
# track by line range, not reproduced/rewritten) through python3 with
# `evaluate_issue` monkeypatched -- inserted as its own script segment
# AFTER _TR_CLOSE_PY defines the real one, BEFORE the driver's loop calls
# it -- to return a deliberately made-up, unregistered reason token. No
# test-only hook is added to track itself.
# extract_track_py <corrob|close|driver> <outfile>
# fix-pass-6 M1: heredoc-marker-anchored extraction of track's embedded
# python regions (replaces hardcoded sed line ranges, which silently rotted
# whenever edits shifted line numbers). Anchors are the unique heredoc /
# quoted-assignment delimiters themselves.
extract_track_py() {
  local which="$1" out="$2"
  case "$which" in
    corrob)
      awk "/^read -r -d '' _TR_CORROB_PY <<'PYEOF'/{f=1;next} f&&/^PYEOF\$/{exit} f" "$TRACK" > "$out"
      ;;
    close)
      awk "/^read -r -d '' _TR_CLOSE_PY <<'PYEOF'/{f=1;next} f&&/^PYEOF\$/{exit} f" "$TRACK_AUTOCLOSE" > "$out"
      ;;
    driver)
      awk "/^_tr_ac_driver='\$/{f=1;next} f&&/^'\$/{exit} f" "$TRACK_AUTOCLOSE" > "$out"
      ;;
    *)
      echo "extract_track_py: unknown region '$which'" >&2
      return 1
      ;;
  esac
}

section_ac_reasons_registry_enforced() {
  local corrob_f close_f driver_f override_f index_f out_f prefetch_f repos_f root_d reason detail

  corrob_f="$(mktemp)"; close_f="$(mktemp)"; driver_f="$(mktemp)"
  override_f="$(mktemp)"; index_f="$(mktemp)"; out_f="$(mktemp)"
  prefetch_f="$(mktemp)"; repos_f="$(mktemp)"
  root_d="$(mktemp -d)"

  extract_track_py corrob "$corrob_f"
  extract_track_py close "$close_f"
  extract_track_py driver "$driver_f"
  assert_true "fix-pass-5b#3: all three extracted driver segments are non-empty" \
    bash -c '[[ -s "$1" && -s "$2" && -s "$3" ]]' _ "$corrob_f" "$close_f" "$driver_f"
  assert_true "fix-pass-6 M1: extracted segments are anchored on the real regions" \
    bash -c 'grep -q "^REASONS = frozenset" "$1" && grep -q "def tr_g4_marker_check" "$1" && grep -q "_ac_results" "$2"' \
    _ "$close_f" "$driver_f"

  cat > "$override_f" <<'PYEOF'
def evaluate_issue(issue_id, *a, **kw):
    return "surface", "totally-made-up-reason-xyz"
PYEOF

  printf '{"issues": {"I-777": {}}, "dispatch_issue_map": {}}' > "$index_f"
  printf '{}' > "$prefetch_f"
  printf '{}' > "$repos_f"

  PM_TR_INDEX="$index_f" PM_TR_ROOT="$root_d" PM_TR_AUTO_CLOSE=1 \
    PM_TR_AC_OUT="$out_f" PM_TR_REPOS="$(cat "$repos_f")" PM_TR_PREFETCH="$prefetch_f" \
    bash -c 'cat "$1" "$2" "$3" "$4" | python3 -' _ "$corrob_f" "$close_f" "$override_f" "$driver_f"
  assert_true "fix-pass-5b#3: monkeypatched driver run produced a verdict file" \
    bash -c '[[ -s "$1" ]]' _ "$out_f"

  reason="$(python3 -c 'import json,sys; rows=json.load(open(sys.argv[1])); print(rows[0]["reason"])' "$out_f")"
  assert_true "fix-pass-5b#3: unregistered reason token 'totally-made-up-reason-xyz' does NOT reach the verdict row -- surfaces as auto-close-driver-error instead" \
    bash -c '[[ "$1" == "auto-close-driver-error" ]]' _ "$reason"
  # fix-pass-6 T2: the failure must be the REGISTRY refusal specifically --
  # any unrelated in-try crash also yields auto-close-driver-error, so pin
  # the detail text to the ValueError the registry check raises.
  detail="$(python3 -c 'import json,sys; rows=json.load(open(sys.argv[1])); print(rows[0].get("detail") or "")' "$out_f")"
  assert_true "fix-pass-6 T2: driver-error detail names the unregistered reason token check" \
    bash -c '[[ "$1" == *"unregistered auto-close reason token"* ]]' _ "$detail"

  rm -f "$corrob_f" "$close_f" "$driver_f" "$override_f" "$index_f" "$out_f" "$prefetch_f" "$repos_f"
  rm -rf "$root_d"
}

# ---------------------------------------------------------------------------
# AC P3-1: git argv hygiene -- a leading-dash remote segment parsed out of
# mainline_ref must be rejected outright (mainline-ref-missing) and must
# never reach a git fetch invocation's argv.
# ---------------------------------------------------------------------------
section_ac_p31_leading_dash_remote() {
  local repo gitrepo base_sha tip wrapper_dir log_file
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i221-x)"
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"
  cat >"$repo/.pm/config.json" <<JSON
{"repos": {"demo-repo": {"path": "$gitrepo", "mainline": "main", "mainline_ref": "refs/remotes/-evil/main", "fetch_policy": "fetch"}}, "herdr_workspace": "zzz-test-ws", "automation": {"auto_close": true}}
JSON

  seed_verified_dispatch "$repo" D-221 I-221 zzz-test-tab-221 i221-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-221 OPEN ACTIVE

  wrapper_dir="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-git-wrapper.XXXXXX")"
  log_file="$(mktemp "${TMPDIR:-/tmp}/pm-creator-git-wrapper-log.XXXXXX")"
  make_git_env_wrapper "$wrapper_dir" "$log_file"
  run_track_with_git_wrapper "$repo" "$wrapper_dir"

  assert_ac_surfaced "ac p3-1 leading-dash remote" "$repo" "I-221" "mainline-ref-missing"
  assert_eq "ac p3-1 leading-dash remote: no fetch invocation ever attempted" \
    "0" "$(grep -c '|fetch ' "$log_file")"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i221-x" >/dev/null 2>&1 || true
  rm -rf "$repo" "$wrapper_dir"
  rm -f "$log_file"
}

# ---------------------------------------------------------------------------
# AC P3-2: repo-redirecting git env (GIT_DIR & friends) inherited by track
# must be scrubbed before every corroboration git call -- otherwise a decoy
# repository in the caller's environment silently substitutes for the
# configured repo and a NOT-merged result false-closes.
# ---------------------------------------------------------------------------
section_ac_p32_git_dir_decoy_scrubbed() {
  local repo gitrepo decoy base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i222-x)"

  # Build the DECOY: a full copy of the repo in its merged state...
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"
  decoy="$repo/decoy-repo"
  cp -a "$gitrepo" "$decoy"
  # ...then WIND BACK the real repo to the un-merged state. Truth: result
  # was never merged to mainline -> must surface, never close.
  git_or_die "p3-2 decoy: unmerge real main" -C "$gitrepo" update-ref refs/heads/main "$base_sha"

  seed_verified_dispatch "$repo" D-222 I-222 zzz-test-tab-222 i222-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-222 OPEN ACTIVE

  # shellcheck disable=SC2034
  TR_OUT="$(cd "$repo" && GIT_DIR="$decoy/.git" PATH="/usr/bin:/bin" bash bin/track --once 2>&1)"
  TR_RC=$?

  assert_ac_surfaced "ac p3-2 GIT_DIR decoy scrubbed" "$repo" "I-222" \
    "no-strict-ancestry-and-no-valid-marker"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i222-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# AC P3-3(b): a WHOLE-driver crash (driver process dies before writing its
# verdict) must degrade to the loud sentinel row WITH the driver's stderr
# tail embedded as detail, and echo that tail to track's own stderr --
# never silently swallow it (pre-fix the stderr temp file was rm'd unread).
# Simulated via a python3 shim that dies ONLY for the auto-close driver
# invocation (keyed on PM_TR_AC_OUT in its env).
# ---------------------------------------------------------------------------
section_ac_p33_whole_driver_crash() {
  local repo shim real_python
  repo="$(new_tmp_repo_with_git_ac true)"
  seed_issue_state "$repo" I-232 OPEN ACTIVE

  shim="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-python-shim.XXXXXX")"
  real_python="$(command -v python3)"
  cat >"$shim/python3" <<EOF
#!/usr/bin/env bash
if [[ -n "\${PM_TR_AC_OUT:-}" ]]; then
  echo "zzz-test-simulated-driver-crash" >&2
  exit 1
fi
exec "$real_python" "\$@"
EOF
  chmod +x "$shim/python3"

  # shellcheck disable=SC2034
  TR_OUT="$(cd "$repo" && PATH="$shim:/usr/bin:/bin" bash bin/track --once 2>&1)"
  TR_RC=$?

  assert_eq "ac p3-3b whole-driver crash: exit 0 (degrade, not fatal)" "0" "$TR_RC"
  assert_true "ac p3-3b whole-driver crash: sentinel degradation row rendered" \
    bash -c 'grep -q "auto-close-driver-error" "$1/TRACKER.md"' _ "$repo"
  assert_true "ac p3-3b whole-driver crash: driver stderr tail echoed to track stderr" \
    bash -c '[[ "$1" == *zzz-test-simulated-driver-crash* ]]' _ "$TR_OUT"
  assert_true "ac p3-3b whole-driver crash: stderr tail embedded as detail in the fallback row" \
    bash -c 'grep "auto-close-driver-error" "$1/TRACKER.md" | grep -q "zzz-test-simulated-driver-crash"' _ "$repo"

  rm -rf "$repo" "$shim"
}

# ---------------------------------------------------------------------------
# AC P3-6 (+ P3-3(a) detail): an OSError from _ac_has_leftovers' listdir
# (unreadable prompts/ dir) must SURFACE for that issue -- pre-fix it was
# swallowed and read as "no leftovers", silently skipping crash-recovery
# re-archiving. Post-fix it propagates to the per-issue handler and surfaces
# auto-close-driver-error WITH a bounded traceback as detail.
# ---------------------------------------------------------------------------
section_ac_p36_leftover_listdir_error() {
  local repo
  repo="$(new_tmp_repo_with_git_ac true)"
  seed_issue_state "$repo" I-233 OPEN CLOSED
  mkdir -p "$repo/prompts"
  printf 'leftover\n' >"$repo/prompts/I-233_dispatch.md"
  chmod 000 "$repo/prompts"

  run_track "$repo"
  chmod 755 "$repo/prompts"

  assert_eq "ac p3-6 unreadable prompts/: exit 0" "0" "$TR_RC"
  assert_true "ac p3-6 unreadable prompts/: I-233 surfaced auto-close-driver-error (not silent no-leftovers skip)" \
    bash -c 'grep -q "I-233" "$1/TRACKER.md" && grep -q "auto-close-driver-error" "$1/TRACKER.md"' _ "$repo"
  assert_true "ac p3-6 unreadable prompts/: bounded traceback detail present (PermissionError)" \
    bash -c 'grep -q "PermissionError" "$1/TRACKER.md"' _ "$repo"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# P3-4: machine-readable close-refusal classes from pm_close_issue -- stable
# one-token stderr prefixes (unit level, direct in-process call).
# ---------------------------------------------------------------------------
section_p34_close_refusal_tokens() {
  local repo out rc
  # (ii) never-registered
  repo="$(new_tmp_repo)"
  out="$(pm_close_issue "$repo" I-777 2>&1)"
  rc=$?
  assert_true "p3-4 never-registered: nonzero rc" bash -c '[[ "$1" != "0" ]]' _ "$rc"
  assert_true "p3-4 never-registered: stable token close-refused-never-registered on stderr" \
    bash -c '[[ "$1" == *close-refused-never-registered* ]]' _ "$out"
  rm -rf "$repo"

  # (iii) unfoldable log -- pm_fold cannot write the index. A read-only
  # index.json no longer triggers this (C5: the fold writes <path>.tmp +
  # os.replace, which only needs DIRECTORY write permission); a read-only
  # .pm/ blocks the tmp-file creation itself. The .lock file already
  # exists (seed_issue_state applied events), so pm_lock's append-open
  # still succeeds against the read-only directory.
  repo="$(new_tmp_repo)"
  seed_issue_state "$repo" I-778 OPEN ACTIVE
  chmod 555 "$repo/.pm"
  out="$(pm_close_issue "$repo" I-778 2>&1)"
  rc=$?
  chmod 755 "$repo/.pm"
  assert_true "p3-4 unfoldable-log: nonzero rc" bash -c '[[ "$1" != "0" ]]' _ "$rc"
  assert_true "p3-4 unfoldable-log: refusal branch actually hit" \
    bash -c '[[ "$1" == *unfoldable* ]]' _ "$out"
  assert_true "p3-4 unfoldable-log: stable token close-refused-unfoldable-log on stderr" \
    bash -c '[[ "$1" == *close-refused-unfoldable-log* ]]' _ "$out"
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# AC P3-4: durable CLOSED transition + archive failure in the same close ->
# the issue IS closed (event durably on the log); track must render it as
# closed-with-pending-archive in the Auto-closed section (counted closed,
# flagged), NOT as a "not auto-closed" refusal.
# ---------------------------------------------------------------------------
section_ac_p34_closed_with_pending_archive() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i241-x)"

  seed_verified_dispatch "$repo" D-241 I-241 zzz-test-tab-241 i241-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-241 OPEN ACTIVE
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"
  # Sabotage the archive step ONLY: archive path exists as a FILE, so
  # mkdir -p archive/prompts fails AFTER the CLOSED transition landed.
  printf 'not a dir\n' >"$repo/archive"

  run_track "$repo"

  assert_eq "ac p3-4 durable-close+archive-fail: exit 0" "0" "$TR_RC"
  assert_eq "ac p3-4 durable-close+archive-fail: CLOSED transition durably emitted" \
    "CLOSED" "$(issue_state_in_index "$repo" "I-241")"
  assert_true "ac p3-4 durable-close+archive-fail: rendered closed-with-pending-archive" \
    bash -c 'grep "closed-with-pending-archive" "$1/TRACKER.md" | grep -q "I-241"' _ "$repo"
  assert_true "ac p3-4 durable-close+archive-fail: counted closed (stdout AUTO-CLOSED line)" \
    bash -c '[[ "$1" == *"AUTO-CLOSED I-241"* ]]' _ "$TR_OUT"
  assert_true "ac p3-4 durable-close+archive-fail: NOT misclassified close/archive-failure" \
    bash -c '! grep -q "close/archive-failure" "$1/TRACKER.md"' _ "$repo"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i241-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# AC P3-7: surfaced-output signal partition -- actionable/anomalous reasons
# render individually; steady-state reasons (paused/non-active,
# dispatch-not-VERIFIED, auto-close-disabled, issue-unregistered) collapse
# to one summary line each with a (truncated) id list.
# ---------------------------------------------------------------------------
section_ac_p37_output_partition() {
  local repo
  repo="$(new_tmp_repo_with_git_ac true)"
  # 2x steady-state noise
  seed_issue_state "$repo" I-251 OPEN PARKED
  seed_issue_state "$repo" I-252 OPEN PARKED
  # 2x phantom ids: dispatches to never-registered issues
  PM_ROOT="$repo" pm_apply dispatch_new d=D-253 i=I-253x at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_new d=D-254 i=I-254x at="$(now_iso)" >/dev/null
  # 1x actionable signal
  seed_issue_state "$repo" I-255 OPEN ACTIVE
  PM_ROOT="$repo" pm_raw_append question q=Q-255 state=BOGUS at="$(now_iso)" i=I-255

  run_track "$repo"

  assert_eq "ac p3-7: exit 0" "0" "$TR_RC"
  assert_true "ac p3-7: actionable reason rendered individually (issue+reason same line)" \
    bash -c 'grep "invalid-question-state" "$1/TRACKER.md" | grep -q "I-255"' _ "$repo"
  assert_eq "ac p3-7: paused/non-active collapsed to ONE summary line" \
    "1" "$(grep -c "paused/non-active" "$repo/TRACKER.md")"
  assert_true "ac p3-7: paused summary line carries both ids" \
    bash -c 'grep "paused/non-active" "$1/TRACKER.md" | grep "I-251" | grep -q "I-252"' _ "$repo"
  assert_eq "ac p3-7: issue-unregistered collapsed to ONE aggregated row" \
    "1" "$(grep -c "issue-unregistered" "$repo/TRACKER.md")"
  assert_true "ac p3-7: aggregated unregistered row lists the phantom ids" \
    bash -c 'grep "issue-unregistered" "$1/TRACKER.md" | grep "I-253x" | grep -q "I-254x"' _ "$repo"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# T2: AC.G3 negative variants -- each dispatch-graph shape must surface its
# specific reason and never close. All four cases live in one repo/tick
# (independent issues).
# ---------------------------------------------------------------------------
section_ac_t2_g3_negative_variants() {
  local repo
  repo="$(new_tmp_repo_with_git_ac true)"

  # (a) ABANDONED without a successor.
  seed_issue_state "$repo" I-261 OPEN ACTIVE
  PM_ROOT="$repo" pm_apply dispatch_new d=D-261 i=I-261 at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-261 from=READY to=ABANDONED lane=human at="$(now_iso)" >/dev/null

  # (b) FAILED dispatch.
  seed_issue_state "$repo" I-262 OPEN ACTIVE
  PM_ROOT="$repo" pm_apply dispatch_new d=D-262 i=I-262 at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-262 from=READY to=DISPATCHED lane=human at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-262 a=A-01 from=DISPATCHED to=FAILED lane=human at="$(now_iso)" >/dev/null

  # (c) QUARANTINED dispatch STATE via a LEGAL human transition
  # (READY->QUARANTINED through pm_apply) -- no quarantined LINE exists, so
  # G1.5's quarantine_by_issue is empty and G3's own QUARANTINED branch is
  # what must fire.
  seed_issue_state "$repo" I-263 OPEN ACTIVE
  PM_ROOT="$repo" pm_apply dispatch_new d=D-263 i=I-263 at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-263 from=READY to=QUARANTINED lane=human at="$(now_iso)" >/dev/null

  # (d) sole dispatch superseded (by another issue's dispatch) -> no
  # non-superseded dispatch left at all.
  seed_issue_state "$repo" I-264 OPEN ACTIVE
  PM_ROOT="$repo" pm_apply dispatch_new d=D-264 i=I-264 at="$(now_iso)" >/dev/null
  seed_issue_state "$repo" I-265x OPEN ACTIVE
  PM_ROOT="$repo" pm_apply dispatch_new d=D-265 i=I-265x at="$(now_iso)" supersedes=D-264 >/dev/null

  run_track "$repo"
  assert_ac_surfaced "ac t2 g3 ABANDONED-without-successor" "$repo" "I-261" "ABANDONED-without-same-issue-successor"
  assert_ac_surfaced "ac t2 g3 FAILED dispatch" "$repo" "I-262" "FAILED"
  assert_ac_surfaced "ac t2 g3 QUARANTINED dispatch state" "$repo" "I-263" "QUARANTINED"
  assert_ac_surfaced "ac t2 g3 no-non-superseded-dispatch" "$repo" "I-264" "no-non-superseded-dispatch"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# T3: graft/replace gates behaviorally -- history-rewriting mechanisms that
# FAKE the merged topology must never produce a close.
# ---------------------------------------------------------------------------

# (a) old-style .git/info/grafts faking "worker tip is a parent of main's
# tip": GIT_NO_REPLACE_OBJECTS does NOT neutralize grafts, so the explicit
# graft probe must refuse the whole repo (replace-affected). Inverting
# tr_repo_has_grafts makes the faked ancestry hold and this test close ->
# red.
section_ac_t3_graft_file_fakes_ancestry() {
  local repo gitrepo base_sha tip main_tip main_parent
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i271-x)"
  # Advance main so it has a graftable parent slot; worker tip NOT merged.
  (
    set -e
    cd "$gitrepo" || exit 1
    printf 'mainline drift\n' >>README.md
    git add README.md
    git commit -q -m 'mainline drift'
  ) >&2 || { echo "FATAL: fixture git setup failed (t3 grafts: mainline commit)" >&2; exit 1; }
  main_tip="$(git -C "$gitrepo" rev-parse HEAD)"
  main_parent="$(git -C "$gitrepo" rev-parse HEAD^)"

  seed_verified_dispatch "$repo" D-271 I-271 zzz-test-tab-271 i271-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-271 OPEN ACTIVE

  # Graft: pretend main's tip ALSO has the worker tip as a parent -- faked
  # "merged" ancestry via .git/info/grafts.
  mkdir -p "$gitrepo/.git/info"
  printf '%s %s %s\n' "$main_tip" "$main_parent" "$tip" >"$gitrepo/.git/info/grafts"

  run_track "$repo"
  assert_ac_surfaced "ac t3 grafts file fakes ancestry -> replace-affected" \
    "$repo" "I-271" "replace-affected"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i271-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# (b) modern `git replace --graft` faking the same ancestry: neutralized by
# GIT_NO_REPLACE_OBJECTS=1 on every corroboration call, so the un-merged
# truth prevails (no-strict-ancestry surface) -- behavioral proof the env
# var actually bites, beyond the env-presence wrapper test above.
section_ac_t3_replace_ref_fakes_ancestry() {
  local repo gitrepo base_sha tip main_tip main_parent
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i272-x)"
  (
    set -e
    cd "$gitrepo" || exit 1
    printf 'mainline drift\n' >>README.md
    git add README.md
    git commit -q -m 'mainline drift'
  ) >&2 || { echo "FATAL: fixture git setup failed (t3 replace: mainline commit)" >&2; exit 1; }
  main_tip="$(git -C "$gitrepo" rev-parse HEAD)"
  main_parent="$(git -C "$gitrepo" rev-parse HEAD^)"

  seed_verified_dispatch "$repo" D-272 I-272 zzz-test-tab-272 i272-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-272 OPEN ACTIVE

  git_or_die "t3 replace --graft" -C "$gitrepo" replace --graft "$main_tip" "$main_parent" "$tip"
  # Sanity: the replace ref DOES fake the ancestry when replace objects are
  # honored -- the fixture is genuinely adversarial.
  if git -C "$gitrepo" merge-base --is-ancestor "$tip" "$main_tip"; then
    ok "ac t3 replace-ref fixture: faked ancestry holds without the guard"
  else
    fail "ac t3 replace-ref fixture: faked ancestry holds without the guard" "replace --graft had no effect"
  fi

  run_track "$repo"
  assert_ac_surfaced "ac t3 replace ref neutralized -> no-strict-ancestry surfaces" \
    "$repo" "I-272" "no-strict-ancestry-and-no-valid-marker"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i272-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# T4: G4 per-issue surface coverage -- repo-not-configured, repo-not-on-disk,
# missing-repo-metadata, unreachable (garbage sha), all in one tick.
# ---------------------------------------------------------------------------
_t4_seed_verified() {
  # _t4_seed_verified <repo> <d> <issue> <repo_name> <branch> <base_sha|""> <result_sha>
  local repo="$1" d="$2" issue="$3" rname="$4" branch="$5" base="$6" rsha="$7"
  PM_ROOT="$repo" pm_apply dispatch_new d="$d" i="$issue" at="$(now_iso)" >/dev/null
  if [[ -n "$base" ]]; then
    PM_ROOT="$repo" pm_apply dispatch_state d="$d" from=READY to=DISPATCHED lane=human \
      at="$(now_iso)" repo="$rname" branch="$branch" base_sha="$base" >/dev/null
  else
    PM_ROOT="$repo" pm_apply dispatch_state d="$d" from=READY to=DISPATCHED lane=human \
      at="$(now_iso)" repo="$rname" branch="$branch" >/dev/null
  fi
  PM_ROOT="$repo" pm_apply dispatch_state d="$d" a=A-01 from=DISPATCHED to=ACKED lane=human \
    at="$(now_iso)" tab="zzz-test-tab-$d" >/dev/null
  PM_ROOT="$repo" pm_apply result d="$d" a=A-01 status=RETURNED result_sha="$rsha" \
    at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d="$d" a=A-01 from=RETURNED to=VERIFIED lane=human \
    at="$(now_iso)" >/dev/null
}

section_ac_t4_g4_surface_coverage() {
  local repo gitrepo head_sha garbage
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  head_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  garbage="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  cat >"$repo/.pm/config.json" <<JSON
{"repos": {"demo-repo": {"path": "$gitrepo", "mainline": "main", "mainline_ref": "refs/heads/main", "fetch_policy": "local-only"}, "gone-repo": {"path": "$repo/no-such-dir", "mainline": "main", "mainline_ref": "refs/heads/main", "fetch_policy": "local-only"}}, "herdr_workspace": "zzz-test-ws", "automation": {"auto_close": true}}
JSON

  seed_issue_state "$repo" I-281 OPEN ACTIVE
  _t4_seed_verified "$repo" D-281 I-281 gone-repo i281-x "$head_sha" "$head_sha"
  seed_issue_state "$repo" I-282 OPEN ACTIVE
  _t4_seed_verified "$repo" D-282 I-282 demo-repo i282-x "" "$head_sha"
  seed_issue_state "$repo" I-283 OPEN ACTIVE
  _t4_seed_verified "$repo" D-283 I-283 demo-repo i283-x "$head_sha" "$garbage"
  seed_issue_state "$repo" I-284 OPEN ACTIVE
  _t4_seed_verified "$repo" D-284 I-284 zzz-unconfigured-repo i284-x "$head_sha" "$head_sha"

  run_track "$repo"
  assert_ac_surfaced "ac t4 repo-not-on-disk" "$repo" "I-281" "repo-not-on-disk"
  assert_ac_surfaced "ac t4 missing-repo-metadata" "$repo" "I-282" "missing-repo-metadata"
  assert_ac_surfaced "ac t4 unreachable garbage sha" "$repo" "I-283" "unreachable"
  assert_ac_surfaced "ac t4 repo-not-configured" "$repo" "I-284" "repo-not-configured"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# T7: idempotence -- a second tick after a successful auto-close closes
# nothing new, emits no duplicate events, renders no duplicate rows.
# ---------------------------------------------------------------------------
section_ac_t7_idempotent_second_tick() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i291-x)"

  seed_verified_dispatch "$repo" D-291 I-291 zzz-test-tab-291 i291-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-291 OPEN ACTIVE
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"

  run_track "$repo"
  assert_ac_closed "ac t7 tick 1 closes" "$repo" "I-291"

  run_track "$repo"
  assert_eq "ac t7 tick 2: exit 0" "0" "$TR_RC"
  assert_true "ac t7 tick 2: closes nothing new (auto-closed: 0)" \
    bash -c '[[ "$1" == *"auto-closed: 0"* ]]' _ "$TR_OUT"
  assert_true "ac t7 tick 2: exactly one issue_state ...to=CLOSED event total" \
    bash -c '[[ "$(grep -c "^EVENT issue_state i=I-291 .*to=CLOSED" "$1/.pm/events.log")" == "1" ]]' _ "$repo"
  assert_true "ac t7 tick 2: exactly one archived note event total" \
    bash -c '[[ "$(grep -c "ref=archived:I-291" "$1/.pm/events.log")" == "1" ]]' _ "$repo"
  assert_true "ac t7 tick 2: steady-state CLOSED renders NO row at all" \
    bash -c '! grep -q "I-291" "$1/TRACKER.md"' _ "$repo"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i291-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# T8: G1 config variants -- absent automation key, and the STRING "true"
# (not boolean) -- must BOTH read as disabled: surface auto-close-disabled,
# never close, zero fetches.
# ---------------------------------------------------------------------------
_t8_config_variant() {
  # _t8_config_variant <label> <automation_json_suffix>
  local label="$1" automation="$2"
  local repo gitrepo base_sha tip wrapper_dir log_file
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  ac_add_local_origin "$repo" "$gitrepo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i295-x)"
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"
  git_or_die "t8 ($label): push merged main" -C "$gitrepo" push -q origin main
  cat >"$repo/.pm/config.json" <<JSON
{"repos": {"demo-repo": {"path": "$gitrepo", "mainline": "main", "mainline_ref": "refs/remotes/origin/main", "fetch_policy": "fetch"}}, "herdr_workspace": "zzz-test-ws"${automation}}
JSON

  seed_verified_dispatch "$repo" D-295 I-295 zzz-test-tab-295 i295-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-295 OPEN ACTIVE

  wrapper_dir="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-git-wrapper.XXXXXX")"
  log_file="$(mktemp "${TMPDIR:-/tmp}/pm-creator-git-wrapper-log.XXXXXX")"
  make_git_env_wrapper "$wrapper_dir" "$log_file"
  run_track_with_git_wrapper "$repo" "$wrapper_dir"

  assert_ac_surfaced "ac t8 ($label): disabled" "$repo" "I-295" "auto-close-disabled"
  assert_eq "ac t8 ($label): zero fetches" "0" "$(grep -c '|fetch ' "$log_file")"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i295-x" >/dev/null 2>&1 || true
  rm -rf "$repo" "$wrapper_dir"
  rm -f "$log_file"
}

section_ac_t8_g1_config_variants() {
  _t8_config_variant "absent automation key" ""
  _t8_config_variant "string \"true\"" ', "automation": {"auto_close": "true"}'
}

# ---------------------------------------------------------------------------
# B2.2 M1: squash workflow end-to-end -- strict topology fails (squash
# commit, branch tip not on mainline), a fold-accepted marker corroborates,
# branch still resolvable -> auto-close via the MARKER arm, legibly
# distinguished from strict closes in TRACKER.md AND in a durable audit
# note on the event log. Second tick is idempotent.
# ---------------------------------------------------------------------------
section_ac_marker_closes_squash() {
  local repo gitrepo base_sha tip squash_sha
  repo="$(new_tmp_repo_with_git_ac_squash false)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i310-x)"
  squash_sha="$(ac_squash_merge_to_mainline "$gitrepo" "$tip")"

  seed_verified_dispatch "$repo" D-310 I-310 zzz-test-tab-310 i310-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-310 OPEN ACTIVE
  seed_merged_marker "$repo" D-310 "$squash_sha" "$tip"

  run_track "$repo"
  assert_ac_closed "ac marker squash close" "$repo" "I-310"
  assert_true "ac marker squash close: TRACKER row is marker-attributed (auto-closed-marker)" \
    bash -c 'grep -- "I-310" "$1/TRACKER.md" | grep -q "| auto-closed-marker |"' _ "$repo"
  assert_true "ac marker squash close: durable audit note distinguishes the marker path" \
    bash -c 'grep -q "^EVENT note .*ref=auto-close:marker i=I-310" "$1/.pm/events.log"' _ "$repo"

  run_track "$repo"
  assert_true "ac marker squash close: second tick closes nothing new (idempotent)" \
    bash -c '[[ "$1" == *"auto-closed: 0"* ]]' _ "$TR_OUT"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i310-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B2.2 M2: post-squash branch deletion. With allow_marker_branch_deleted
# true the close proceeds, explicitly labeled as the branch-deleted variant;
# with it false/absent it surfaces marker-branch-absent-uncorroborated.
# ---------------------------------------------------------------------------
section_ac_marker_branch_deleted_allowed() {
  local repo gitrepo base_sha tip squash_sha
  repo="$(new_tmp_repo_with_git_ac_squash true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i311-x)"
  squash_sha="$(ac_squash_merge_to_mainline "$gitrepo" "$tip")"

  seed_verified_dispatch "$repo" D-311 I-311 zzz-test-tab-311 i311-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-311 OPEN ACTIVE
  seed_merged_marker "$repo" D-311 "$squash_sha" "$tip"
  ac_delete_worker_branch "$gitrepo" "$repo" i311-x

  run_track "$repo"
  assert_ac_closed "ac marker branch-deleted allowed" "$repo" "I-311"
  assert_true "ac marker branch-deleted allowed: TRACKER row names the branch-deleted variant" \
    bash -c 'grep -- "I-311" "$1/TRACKER.md" | grep -q "auto-closed-marker-branch-deleted"' _ "$repo"
  assert_true "ac marker branch-deleted allowed: audit note names the branch-deleted variant" \
    bash -c 'grep -q "^EVENT note .*ref=auto-close:marker-branch-deleted i=I-311" "$1/.pm/events.log"' _ "$repo"

  rm -rf "$repo"
}

section_ac_marker_branch_deleted_refused() {
  local repo gitrepo base_sha tip squash_sha
  repo="$(new_tmp_repo_with_git_ac_squash false)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i312-x)"
  squash_sha="$(ac_squash_merge_to_mainline "$gitrepo" "$tip")"

  seed_verified_dispatch "$repo" D-312 I-312 zzz-test-tab-312 i312-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-312 OPEN ACTIVE
  seed_merged_marker "$repo" D-312 "$squash_sha" "$tip"
  ac_delete_worker_branch "$gitrepo" "$repo" i312-x

  run_track "$repo"
  assert_ac_surfaced "ac marker branch-deleted refused (opt-in absent)" "$repo" "I-312" \
    "marker-branch-absent-uncorroborated"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B2.2 M3: squash repo with NO marker -> the existing fail-closed reason.
# ---------------------------------------------------------------------------
section_ac_marker_missing() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac_squash false)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i313-x)"
  ac_squash_merge_to_mainline "$gitrepo" "$tip" >/dev/null

  seed_verified_dispatch "$repo" D-313 I-313 zzz-test-tab-313 i313-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-313 OPEN ACTIVE

  run_track "$repo"
  assert_ac_surfaced "ac marker missing" "$repo" "I-313" "no-strict-ancestry-and-no-valid-marker"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i313-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B2.2 M4: marker whose merge_sha is a real commit NOT on mainline -> the
# marker's own mainline-ancestry leg refuses (marker-merge-not-on-mainline).
# ---------------------------------------------------------------------------
section_ac_marker_merge_not_on_mainline() {
  local repo gitrepo base_sha tip stray
  repo="$(new_tmp_repo_with_git_ac_squash false)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i314-x)"
  # a real, verifiable commit that was never merged anywhere near mainline
  # (distinct content -- an identical tree/parent/timestamp would mint the
  # SAME sha as $tip and hollow the test out)
  stray="$(ac_make_worker_commit "$gitrepo" "$repo" i314-stray)"
  (
    set -e
    cd "$repo/wt-i314-stray" || exit 1
    printf 'stray-only work\n' >stray.txt
    git add stray.txt
    git commit -q -m 'stray work'
  ) >&2 || { echo "FATAL: fixture git setup failed (m4: stray distinct commit)" >&2; exit 1; }
  stray="$(git -C "$repo/wt-i314-stray" rev-parse HEAD)"

  seed_verified_dispatch "$repo" D-314 I-314 zzz-test-tab-314 i314-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-314 OPEN ACTIVE
  seed_merged_marker "$repo" D-314 "$stray" "$tip"

  run_track "$repo"
  assert_ac_surfaced "ac marker merge not on mainline" "$repo" "I-314" "marker-merge-not-on-mainline"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i314-x" >/dev/null 2>&1 || true
  git -C "$gitrepo" worktree remove --force "$repo/wt-i314-stray" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B2.2 M5: marker whose merge_sha is sha-shaped but names no real commit ->
# tr_verify_commit's identity anchor refuses (marker-merge-sha-unverified).
# ---------------------------------------------------------------------------
section_ac_marker_merge_sha_unverified() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac_squash false)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i315-x)"
  ac_squash_merge_to_mainline "$gitrepo" "$tip" >/dev/null

  seed_verified_dispatch "$repo" D-315 I-315 zzz-test-tab-315 i315-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-315 OPEN ACTIVE
  seed_merged_marker "$repo" D-315 "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$tip"

  run_track "$repo"
  assert_ac_surfaced "ac marker merge sha unverified" "$repo" "I-315" "marker-merge-sha-unverified"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i315-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B2.2 M6: the marker path is consulted ONLY for merge_mode=squash repos --
# a marker on a default (merge-mode) repo changes nothing: strict failure
# still surfaces the existing reason.
# ---------------------------------------------------------------------------
section_ac_marker_ignored_in_merge_mode() {
  local repo gitrepo base_sha tip squash_sha
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i316-x)"
  squash_sha="$(ac_squash_merge_to_mainline "$gitrepo" "$tip")"

  seed_verified_dispatch "$repo" D-316 I-316 zzz-test-tab-316 i316-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-316 OPEN ACTIVE
  seed_merged_marker "$repo" D-316 "$squash_sha" "$tip"

  run_track "$repo"
  assert_ac_surfaced "ac marker ignored on merge-mode repo" "$repo" "I-316" \
    "no-strict-ancestry-and-no-valid-marker"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i316-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B2.2 M7: strict still runs FIRST on squash repos -- a fast-forward-merged
# result closes strictly (auto-closed-strict, no marker needed, no marker
# audit note).
# ---------------------------------------------------------------------------
section_ac_marker_strict_still_preferred() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac_squash false)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i317-x)"
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"

  seed_verified_dispatch "$repo" D-317 I-317 zzz-test-tab-317 i317-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-317 OPEN ACTIVE

  run_track "$repo"
  assert_ac_closed "ac squash repo strict-first close" "$repo" "I-317"
  assert_true "ac squash repo strict-first close: TRACKER row says auto-closed-strict" \
    bash -c 'grep -- "I-317" "$1/TRACKER.md" | grep -q "auto-closed-strict"' _ "$repo"
  assert_eq "ac squash repo strict-first close: no marker audit note emitted" \
    "0" "$(grep -c "ref=auto-close:" "$repo/.pm/events.log")"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i317-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B2.2 M8: runtime config validation is fail-closed -- an invalid
# merge_mode, or a non-bool allow_marker_branch_deleted, surfaces
# repo-config-invalid for that repo's issues (config.json is
# operator-editable post-scaffold; scaffold-time validity never trusted).
# ---------------------------------------------------------------------------
_m8_bad_config_variant() {
  # _m8_bad_config_variant <label> <repo_json_extras>
  local label="$1" extras="$2"
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i318-x)"
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"
  cat >"$repo/.pm/config.json" <<JSON
{"repos": {"demo-repo": {"path": "$gitrepo", "mainline": "main", "mainline_ref": "refs/heads/main", "fetch_policy": "local-only"${extras}}}, "herdr_workspace": "zzz-test-ws", "automation": {"auto_close": true}}
JSON

  seed_verified_dispatch "$repo" D-318 I-318 zzz-test-tab-318 i318-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-318 OPEN ACTIVE

  run_track "$repo"
  assert_ac_surfaced "ac m8 ($label)" "$repo" "I-318" "repo-config-invalid"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i318-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

section_ac_marker_repo_config_invalid() {
  _m8_bad_config_variant "invalid merge_mode enum" ', "merge_mode": "rebase"'
  _m8_bad_config_variant "non-bool allow_marker_branch_deleted" ', "allow_marker_branch_deleted": "yes"'
}

# ---------------------------------------------------------------------------
# B2.2 M9: BRANCH-BINDING IS NOT WAIVED on the marker path -- a forged
# result claiming the mainline squash commit itself (marker matches, merge
# on mainline) whose recorded branch still resolves but does NOT contain
# the result -> result-not-bound-to-branch, exactly as strict.
# ---------------------------------------------------------------------------
section_ac_marker_forged_result_not_on_branch() {
  local repo gitrepo base_sha tip squash_sha
  repo="$(new_tmp_repo_with_git_ac_squash false)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i319-x)"
  squash_sha="$(ac_squash_merge_to_mainline "$gitrepo" "$tip")"

  # forged: the recorded result IS the mainline squash commit (never on the
  # worker branch), and the marker faithfully repeats it.
  seed_verified_dispatch "$repo" D-319 I-319 zzz-test-tab-319 i319-x "$base_sha" "$squash_sha"
  seed_issue_state "$repo" I-319 OPEN ACTIVE
  seed_merged_marker "$repo" D-319 "$squash_sha" "$squash_sha"

  run_track "$repo"
  assert_ac_surfaced "ac marker forged result not on branch" "$repo" "I-319" \
    "result-not-bound-to-branch"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i319-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B2.2 fix-pass-6 F1(a): the marker-close audit note precedes the durable
# CLOSE and is DEDUP'd against the folded index -- crash-recovery replay: a
# tick that already emitted the note (then died before closing) must, on
# the next tick, close cleanly WITHOUT a second note.
# ---------------------------------------------------------------------------
section_ac_marker_note_precedes_close_replay() {
  local repo gitrepo base_sha tip squash_sha
  repo="$(new_tmp_repo_with_git_ac_squash false)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i320-x)"
  squash_sha="$(ac_squash_merge_to_mainline "$gitrepo" "$tip")"

  seed_verified_dispatch "$repo" D-320 I-320 zzz-test-tab-320 i320-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-320 OPEN ACTIVE
  seed_merged_marker "$repo" D-320 "$squash_sha" "$tip"
  # crash-sim replay: the audit note is ALREADY on the log (prior tick
  # emitted it, then died before pm_close_issue).
  PM_ROOT="$repo" pm_apply note at="$(now_iso)" ref=auto-close:marker i=I-320 >/dev/null

  run_track "$repo"
  assert_ac_closed "ac marker note-before-close replay" "$repo" "I-320"
  assert_eq "ac marker note-before-close replay: EXACTLY one audit note (dedup, no re-emit)" \
    "1" "$(grep -c "ref=auto-close:marker i=I-320" "$repo/.pm/events.log")"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i320-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B2.2 fix-pass-6 F1(b): if the audit-note emission FAILS, the close must
# NOT happen -- no marker close without its durable provenance record.
# Surfaces the registered reason marker-note-emit-failed; retried next tick.
# ---------------------------------------------------------------------------
section_ac_marker_note_emit_failed() {
  local repo gitrepo base_sha tip squash_sha
  repo="$(new_tmp_repo_with_git_ac_squash false)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i321-x)"
  squash_sha="$(ac_squash_merge_to_mainline "$gitrepo" "$tip")"

  seed_verified_dispatch "$repo" D-321 I-321 zzz-test-tab-321 i321-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-321 OPEN ACTIVE
  seed_merged_marker "$repo" D-321 "$squash_sha" "$tip"

  # Force pm_apply (the note append) to fail: read-only event log.
  chmod a-w "$repo/.pm/events.log"
  run_track "$repo"
  chmod u+w "$repo/.pm/events.log"

  local state
  state="$(python3 -c "import json;d=json.load(open('$repo/.pm/index.json'));print(d['issues'].get('I-321',{}).get('state'))" 2>/dev/null)"
  assert_true "ac marker note-emit-failed: issue NOT closed (fail-closed, no close without provenance)" \
    bash -c '[[ "$1" != "CLOSED" ]]' _ "$state"
  assert_true "ac marker note-emit-failed: surfaced with the dedicated reason" \
    bash -c 'grep -- "I-321" "$1/TRACKER.md" | grep -q "marker-note-emit-failed"' _ "$repo"

  # retry next tick with a healthy log -> closes, exactly one note.
  run_track "$repo"
  assert_ac_closed "ac marker note-emit-failed: healthy retry closes" "$repo" "I-321"
  assert_eq "ac marker note-emit-failed: healthy retry leaves exactly one audit note" \
    "1" "$(grep -c "ref=auto-close:marker i=I-321" "$repo/.pm/events.log")"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i321-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B2.2 fix-pass-6 F2 tripwire: result_sha == base_sha (zero new work) on a
# squash repo with a "valid" marker must surface result==base -- both via
# the eligible-set exclusion AND the in-arm re-check (mutation-checked).
# ---------------------------------------------------------------------------
section_ac_marker_result_equals_base() {
  local repo gitrepo base_sha squash_sha
  repo="$(new_tmp_repo_with_git_ac_squash false)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  # worker branch exists but carries NO new commit (tip == base).
  git_or_die "m-eqbase: worktree add" -C "$gitrepo" worktree add -q -b i322-x "$repo/wt-i322-x" main
  # a real commit lands on mainline (so the marker's merge_sha is genuine).
  squash_sha="$(ac_squash_merge_to_mainline "$gitrepo" "$base_sha")"

  seed_verified_dispatch "$repo" D-322 I-322 zzz-test-tab-322 i322-x "$base_sha" "$base_sha"
  seed_issue_state "$repo" I-322 OPEN ACTIVE
  seed_merged_marker "$repo" D-322 "$squash_sha" "$base_sha"

  run_track "$repo"
  assert_ac_surfaced "ac marker result==base refused" "$repo" "I-322" "result==base"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i322-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# review C2: a marker's merge_sha may be a REAL, verified, on-mainline
# commit and still be a lie -- if it landed BEFORE this dispatch's own
# base_sha, it proves nothing about this dispatch's work (it's some earlier,
# unrelated squash-merge the attacker recycled as the marker's merge_sha).
# merge_sha must not be an ancestor of (or equal to) base_sha -- i.e. it
# must not predate this dispatch's own base_sha -- otherwise refuse
# marker-merge-predates-dispatch. Never close.
# ---------------------------------------------------------------------------
section_ac_marker_merge_predates_dispatch() {
  local repo gitrepo old_tip old_squash_sha base_sha tip
  repo="$(new_tmp_repo_with_git_ac_squash false)"
  gitrepo="$repo/target-repo"
  # an EARLIER, unrelated squash-merge that already landed on mainline
  # before this dispatch's base_sha was ever cut.
  old_tip="$(ac_make_worker_commit "$gitrepo" "$repo" i335-earlier)"
  old_squash_sha="$(ac_squash_merge_to_mainline "$gitrepo" "$old_tip")"
  git -C "$gitrepo" worktree remove --force "$repo/wt-i335-earlier" >/dev/null 2>&1 || true

  # this dispatch's base_sha is cut AFTER that earlier merge landed.
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i335-x)"

  seed_verified_dispatch "$repo" D-335 I-335 zzz-test-tab-335 i335-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-335 OPEN ACTIVE
  # marker_result matches att_result (tip) so the mismatch check is
  # satisfied -- the forgery lives entirely in merge_sha, an old, genuine,
  # on-mainline commit that predates base_sha.
  seed_merged_marker "$repo" D-335 "$old_squash_sha" "$tip"

  run_track "$repo"
  assert_ac_surfaced "ac marker merge predates dispatch base" "$repo" "I-335" \
    "marker-merge-predates-dispatch"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i335-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B2.2 fix-pass-6 F3 e2e: a RAW merged line whose merge_sha is a revision
# expression ("main") quarantines at the FOLD -- the issue surfaces via the
# G1.5 quarantine gate and the marker never reaches any git call.
# ---------------------------------------------------------------------------
section_ac_marker_raw_shape_quarantined() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac_squash false)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i323-x)"
  ac_squash_merge_to_mainline "$gitrepo" "$tip" >/dev/null

  seed_verified_dispatch "$repo" D-323 I-323 zzz-test-tab-323 i323-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-323 OPEN ACTIVE
  PM_ROOT="$repo" pm_raw_append merged d=D-323 a=A-01 merge_sha=main result_sha="$tip" at="$(now_iso)"

  run_track "$repo"
  assert_ac_surfaced "ac marker raw shape gate" "$repo" "I-323" "issue-related-quarantine"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i323-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B2.2 fix-pass-6 F4 + T2: direct-function checks on tr_g4_marker_check
# (extracted via the anchored regions): the marker's att_result is itself
# identity-anchored (unreachable sha refused), and a marker/result mismatch
# returns marker-mismatch. Also pins the F2 in-arm result==base re-check.
# ---------------------------------------------------------------------------
section_ac_marker_direct_fn_guards() {
  local corrob_f close_f gitrepo real fake out
  corrob_f="$(mktemp)"; close_f="$(mktemp)"
  extract_track_py corrob "$corrob_f"
  extract_track_py close "$close_f"

  gitrepo="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-marker-fn.XXXXXX")"
  git_or_die "marker-fn: init" init -q -b main "$gitrepo"
  git_or_die "marker-fn: config email" -C "$gitrepo" config user.email t@t
  git_or_die "marker-fn: config name" -C "$gitrepo" config user.name t
  git_or_die "marker-fn: seed commit" -C "$gitrepo" commit -q --allow-empty -m init
  real="$(git -C "$gitrepo" rev-parse HEAD)"
  fake="cccccccccccccccccccccccccccccccccccccccc"

  out="$({ cat "$corrob_f" "$close_f"; cat <<PY
import json
base = "b" * 40
# T2: marker result_sha disagrees with the fold's per-attempt result
print(json.dumps(tr_g4_marker_check(
    "$gitrepo", "main", "refs/heads/main", "local-only", base, "$real",
    "i999-x", None, {"merge_sha": "$real", "result_sha": "$fake"}, False)))
# F4: att_result sha-shaped but names no real commit -> identity anchor refuses
print(json.dumps(tr_g4_marker_check(
    "$gitrepo", "main", "refs/heads/main", "local-only", base, "$fake",
    "i999-x", None, {"merge_sha": "$real", "result_sha": "$fake"}, False)))
# F2: att_result == base_sha (zero new work) -> in-arm re-check refuses
print(json.dumps(tr_g4_marker_check(
    "$gitrepo", "main", "refs/heads/main", "local-only", "$real", "$real",
    "i999-x", None, {"merge_sha": "$real", "result_sha": "$real"}, False)))
PY
  } | python3 - 2>&1)"

  assert_eq "fix-pass-6 T2: marker/result mismatch -> marker-mismatch" \
    '[null, "marker-mismatch"]' "$(printf '%s\n' "$out" | sed -n 1p)"
  assert_eq "fix-pass-6 F4: unreachable att_result refused by identity anchor" \
    '[null, "unreachable"]' "$(printf '%s\n' "$out" | sed -n 2p)"
  assert_eq "fix-pass-6 F2: in-arm result==base re-check refuses" \
    '[null, "result==base"]' "$(printf '%s\n' "$out" | sed -n 3p)"

  rm -f "$corrob_f" "$close_f"
  rm -rf "$gitrepo"
}

# ---------------------------------------------------------------------------
# B2.2 fix-pass-6 F5: marker arm x fetch policy. (a) reachable remote +
# valid marker -> auto-closed-marker with EXACTLY one fetch (the pre-lock
# prefetch; G4 itself never fetches); (b) unreachable remote with a STALE
# remote-tracking ref that WOULD satisfy the local ancestry check ->
# fetch-failed (the prefetch verdict rules, never the stale local ref
# alone); (c) leading-dash remote in mainline_ref -> mainline-ref-missing,
# zero fetch argv ever.
# ---------------------------------------------------------------------------
ac_squash_fetch_config() {
  local repo="$1" gitrepo="$2" mainline_ref="${3:-refs/remotes/origin/main}"
  cat >"$repo/.pm/config.json" <<JSON
{"repos": {"demo-repo": {"path": "$gitrepo", "mainline": "main", "mainline_ref": "$mainline_ref", "fetch_policy": "fetch", "merge_mode": "squash", "allow_marker_branch_deleted": false}}, "herdr_workspace": "zzz-test-ws", "automation": {"auto_close": true}}
JSON
}

section_ac_marker_fetch_policy_success() {
  local repo gitrepo origin_bare base_sha tip squash_sha wrapper_dir log_file
  repo="$(new_tmp_repo_with_git_ac_squash false)"
  gitrepo="$repo/target-repo"
  origin_bare="$repo/origin.git"

  git_or_die "m-fetch-success: init bare origin" init -q --bare "$origin_bare"
  git_or_die "m-fetch-success: add origin remote" -C "$gitrepo" remote add origin "$origin_bare"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i324-x)"
  squash_sha="$(ac_squash_merge_to_mainline "$gitrepo" "$tip")"
  git_or_die "m-fetch-success: push squashed main to origin" -C "$gitrepo" push -q origin main
  ac_squash_fetch_config "$repo" "$gitrepo"

  seed_verified_dispatch "$repo" D-324 I-324 zzz-test-tab-324 i324-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-324 OPEN ACTIVE
  seed_merged_marker "$repo" D-324 "$squash_sha" "$tip"

  wrapper_dir="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-git-wrapper.XXXXXX")"
  log_file="$(mktemp "${TMPDIR:-/tmp}/pm-creator-git-wrapper-log.XXXXXX")"
  make_git_env_wrapper "$wrapper_dir" "$log_file"
  run_track_with_git_wrapper "$repo" "$wrapper_dir"

  assert_ac_closed "ac marker fetch success" "$repo" "I-324"
  assert_true "ac marker fetch success: closed via the marker path" \
    bash -c 'grep -- "I-324" "$1/TRACKER.md" | grep -q "| auto-closed-marker |"' _ "$repo"
  assert_eq "ac marker fetch success: EXACTLY one fetch (pre-lock prefetch only)" \
    "1" "$(grep -c '|fetch ' "$log_file")"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i324-x" >/dev/null 2>&1 || true
  rm -rf "$repo" "$wrapper_dir"
  rm -f "$log_file"
}

section_ac_marker_fetch_policy_failed_stale_ref() {
  local repo gitrepo origin_bare base_sha tip squash_sha
  repo="$(new_tmp_repo_with_git_ac_squash false)"
  gitrepo="$repo/target-repo"
  origin_bare="$repo/origin.git"

  git_or_die "m-fetch-stale: init bare origin" init -q --bare "$origin_bare"
  git_or_die "m-fetch-stale: add origin remote" -C "$gitrepo" remote add origin "$origin_bare"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i325-x)"
  squash_sha="$(ac_squash_merge_to_mainline "$gitrepo" "$tip")"
  git_or_die "m-fetch-stale: push squashed main" -C "$gitrepo" push -q origin main
  # a STALE remote-tracking ref that already contains merge_sha ...
  git_or_die "m-fetch-stale: prime remote-tracking ref" -C "$gitrepo" fetch -q origin
  # ... then the remote goes away: prefetch MUST fail and rule.
  mv "$origin_bare" "${origin_bare}.gone"
  ac_squash_fetch_config "$repo" "$gitrepo"

  seed_verified_dispatch "$repo" D-325 I-325 zzz-test-tab-325 i325-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-325 OPEN ACTIVE
  seed_merged_marker "$repo" D-325 "$squash_sha" "$tip"

  run_track "$repo"
  assert_ac_surfaced "ac marker fetch stale-ref" "$repo" "I-325" "fetch-failed"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i325-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

section_ac_marker_fetch_policy_leading_dash() {
  local repo gitrepo base_sha tip squash_sha wrapper_dir log_file
  repo="$(new_tmp_repo_with_git_ac_squash false)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i326-x)"
  squash_sha="$(ac_squash_merge_to_mainline "$gitrepo" "$tip")"
  ac_squash_fetch_config "$repo" "$gitrepo" "refs/remotes/-evil/main"

  seed_verified_dispatch "$repo" D-326 I-326 zzz-test-tab-326 i326-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-326 OPEN ACTIVE
  seed_merged_marker "$repo" D-326 "$squash_sha" "$tip"

  wrapper_dir="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-git-wrapper.XXXXXX")"
  log_file="$(mktemp "${TMPDIR:-/tmp}/pm-creator-git-wrapper-log.XXXXXX")"
  make_git_env_wrapper "$wrapper_dir" "$log_file"
  run_track_with_git_wrapper "$repo" "$wrapper_dir"

  assert_ac_surfaced "ac marker leading-dash remote" "$repo" "I-326" "mainline-ref-missing"
  assert_eq "ac marker leading-dash remote: zero fetch argv ever" \
    "0" "$(grep -c '|fetch ' "$log_file")"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i326-x" >/dev/null 2>&1 || true
  rm -rf "$repo" "$wrapper_dir"
  rm -f "$log_file"
}

# ---------------------------------------------------------------------------
# B2.2 fix-pass-6 T1: a marker recorded for an OLD attempt does not carry
# over to the re-dispatched attempt -- current-(d,a) lookup only.
# ---------------------------------------------------------------------------
section_ac_marker_old_attempt_ignored() {
  local repo gitrepo base_sha tip1 tip2 squash1
  repo="$(new_tmp_repo_with_git_ac_squash false)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip1="$(ac_make_worker_commit "$gitrepo" "$repo" i327-x)"
  squash1="$(ac_squash_merge_to_mainline "$gitrepo" "$tip1")"
  # second attempt's commit on the same branch
  (
    set -e
    cd "$repo/wt-i327-x" || exit 1
    printf 'second attempt work\n' >again.txt
    git add again.txt
    git commit -q -m 'attempt two'
  ) >&2 || { echo "FATAL: fixture git setup failed (m-t1: attempt-two commit)" >&2; exit 1; }
  tip2="$(git -C "$repo/wt-i327-x" rev-parse HEAD)"
  ac_squash_merge_to_mainline "$gitrepo" "$tip2" >/dev/null

  seed_issue_state "$repo" I-327 OPEN ACTIVE
  local now
  now="$(now_iso)"
  PM_ROOT="$repo" pm_apply dispatch_new d=D-327 i=I-327 at="$now" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-327 from=READY to=DISPATCHED lane=human \
    at="$now" repo=demo-repo branch=i327-x base_sha="$base_sha" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-327 a=A-01 from=DISPATCHED to=ACKED lane=human \
    at="$now" tab=zzz-test-tab-327 >/dev/null
  PM_ROOT="$repo" pm_apply result d=D-327 a=A-01 status=RETURNED result_sha="$tip1" at="$now" >/dev/null
  # marker for the FIRST attempt only
  PM_ROOT="$repo" pm_apply merged d=D-327 a=A-01 merge_sha="$squash1" result_sha="$tip1" at="$now" >/dev/null
  # attempt one fails; re-dispatch mints A-02; attempt two returns + verifies
  PM_ROOT="$repo" pm_apply dispatch_state d=D-327 a=A-01 from=RETURNED to=FAILED lane=human at="$now" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-327 from=FAILED to=DISPATCHED lane=human \
    at="$now" base_sha="$base_sha" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-327 a=A-02 from=DISPATCHED to=ACKED lane=human \
    at="$now" tab=zzz-test-tab-327b >/dev/null
  PM_ROOT="$repo" pm_apply result d=D-327 a=A-02 status=RETURNED result_sha="$tip2" at="$now" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-327 a=A-02 from=RETURNED to=VERIFIED lane=human at="$now" >/dev/null

  run_track "$repo"
  assert_ac_surfaced "ac marker old-attempt ignored" "$repo" "I-327" \
    "no-strict-ancestry-and-no-valid-marker"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i327-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B2.2 fix-pass-6 T3: close_modes precedence -- one issue, dispatch A
# strict-corroborated, dispatch B marker-corroborated, same tick: the row
# says auto-closed-marker (the most permissive path used) and the audit
# note is present.
# ---------------------------------------------------------------------------
section_ac_marker_close_modes_precedence() {
  local repo gitrepo base_sha tip_a tip_b squash_b
  repo="$(new_tmp_repo_with_git_ac_squash false)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip_a="$(ac_make_worker_commit "$gitrepo" "$repo" i328-x)"
  # second worker branch touching a DIFFERENT file
  git_or_die "m-t3: branch i329-x" -C "$gitrepo" branch i329-x main
  git_or_die "m-t3: worktree add wt-i329-x" -C "$gitrepo" worktree add -q "$repo/wt-i329-x" i329-x
  (
    set -e
    cd "$repo/wt-i329-x" || exit 1
    printf 'other work\n' >second.txt
    git add second.txt
    git commit -q -m 'other work'
  ) >&2 || { echo "FATAL: fixture git setup failed (m-t3: i329-x commit)" >&2; exit 1; }
  tip_b="$(git -C "$repo/wt-i329-x" rev-parse HEAD)"

  # dispatch A's tip lands as a REAL merge (strict corroborates) ...
  git_or_die "m-t3: merge i328-x" -C "$gitrepo" merge -q -m 'merge i328-x' "$tip_a"
  # ... dispatch B's tip lands as a SQUASH (marker needed).
  squash_b="$(ac_squash_merge_to_mainline "$gitrepo" "$tip_b")"

  seed_verified_dispatch "$repo" D-328 I-328 zzz-test-tab-328 i328-x "$base_sha" "$tip_a"
  seed_verified_dispatch "$repo" D-329 I-328 zzz-test-tab-329 i329-x "$base_sha" "$tip_b"
  seed_issue_state "$repo" I-328 OPEN ACTIVE
  seed_merged_marker "$repo" D-329 "$squash_b" "$tip_b"

  run_track "$repo"
  assert_ac_closed "ac marker close-modes precedence" "$repo" "I-328"
  assert_true "ac marker close-modes precedence: row reason is auto-closed-marker" \
    bash -c 'grep -- "I-328" "$1/TRACKER.md" | grep -q "| auto-closed-marker |"' _ "$repo"
  assert_eq "ac marker close-modes precedence: audit note present" \
    "1" "$(grep -c "ref=auto-close:marker i=I-328" "$repo/.pm/events.log")"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i328-x" >/dev/null 2>&1 || true
  git -C "$gitrepo" worktree remove --force "$repo/wt-i329-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B2.2 fix-pass-6 T5: allow_marker_branch_deleted key ABSENT (legacy squash
# config, not merely false) + deleted branch -> fail-closed surface.
# ---------------------------------------------------------------------------
section_ac_marker_branch_deleted_key_absent() {
  local repo gitrepo base_sha tip squash_sha
  repo="$(new_tmp_repo_with_git_ac_squash false)"
  gitrepo="$repo/target-repo"
  # config WITHOUT the allow_marker_branch_deleted key at all
  cat >"$repo/.pm/config.json" <<JSON
{"repos": {"demo-repo": {"path": "$gitrepo", "mainline": "main", "mainline_ref": "refs/heads/main", "fetch_policy": "local-only", "merge_mode": "squash"}}, "herdr_workspace": "zzz-test-ws", "automation": {"auto_close": true}}
JSON
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i330-x)"
  squash_sha="$(ac_squash_merge_to_mainline "$gitrepo" "$tip")"

  seed_verified_dispatch "$repo" D-330 I-330 zzz-test-tab-330 i330-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-330 OPEN ACTIVE
  seed_merged_marker "$repo" D-330 "$squash_sha" "$tip"
  ac_delete_worker_branch "$gitrepo" "$repo" i330-x

  run_track "$repo"
  assert_ac_surfaced "ac marker allow-key absent" "$repo" "I-330" \
    "marker-branch-absent-uncorroborated"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B2.2 fix-pass-6 T6 (track half): a marker recorded on an ABANDONED
# dispatch's attempt never participates in the same-issue successor's close
# -- the successor needs its OWN marker.
# ---------------------------------------------------------------------------
section_ac_marker_abandoned_not_borrowed() {
  local repo gitrepo base_sha tip1 tip2 squash1 now
  repo="$(new_tmp_repo_with_git_ac_squash false)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip1="$(ac_make_worker_commit "$gitrepo" "$repo" i331-x)"
  squash1="$(ac_squash_merge_to_mainline "$gitrepo" "$tip1")"
  # successor's branch + commit, squash-merged too (so strict fails for it)
  git_or_die "m-t6: branch i332-x" -C "$gitrepo" branch i332-x main
  git_or_die "m-t6: worktree add wt-i332-x" -C "$gitrepo" worktree add -q "$repo/wt-i332-x" i332-x
  (
    set -e
    cd "$repo/wt-i332-x" || exit 1
    printf 'successor work\n' >succ.txt
    git add succ.txt
    git commit -q -m 'successor work'
  ) >&2 || { echo "FATAL: fixture git setup failed (m-t6: i332-x commit)" >&2; exit 1; }
  tip2="$(git -C "$repo/wt-i332-x" rev-parse HEAD)"
  ac_squash_merge_to_mainline "$gitrepo" "$tip2" >/dev/null

  seed_issue_state "$repo" I-331 OPEN ACTIVE
  now="$(now_iso)"
  # D-331: RETURNED with a marker, then ABANDONED.
  PM_ROOT="$repo" pm_apply dispatch_new d=D-331 i=I-331 at="$now" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-331 from=READY to=DISPATCHED lane=human \
    at="$now" repo=demo-repo branch=i331-x base_sha="$base_sha" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-331 a=A-01 from=DISPATCHED to=ACKED lane=human \
    at="$now" tab=zzz-test-tab-331 >/dev/null
  PM_ROOT="$repo" pm_apply result d=D-331 a=A-01 status=RETURNED result_sha="$tip1" at="$now" >/dev/null
  PM_ROOT="$repo" pm_apply merged d=D-331 a=A-01 merge_sha="$squash1" result_sha="$tip1" at="$now" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-331 a=A-01 from=RETURNED to=ABANDONED lane=human at="$now" >/dev/null
  # D-332: the SAME-ISSUE SUCCESSOR (supersedes=D-331, satisfying G3),
  # VERIFIED, squash-merged, NO marker of its own.
  PM_ROOT="$repo" pm_apply dispatch_new d=D-332 i=I-331 supersedes=D-331 at="$now" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-332 from=READY to=DISPATCHED lane=human \
    at="$now" repo=demo-repo branch=i332-x base_sha="$base_sha" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-332 a=A-01 from=DISPATCHED to=ACKED lane=human \
    at="$now" tab=zzz-test-tab-332 >/dev/null
  PM_ROOT="$repo" pm_apply result d=D-332 a=A-01 status=RETURNED result_sha="$tip2" at="$now" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-332 a=A-01 from=RETURNED to=VERIFIED lane=human at="$now" >/dev/null

  run_track "$repo"
  assert_ac_surfaced "ac marker abandoned-not-borrowed" "$repo" "I-331" \
    "no-strict-ancestry-and-no-valid-marker"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i331-x" >/dev/null 2>&1 || true
  git -C "$gitrepo" worktree remove --force "$repo/wt-i332-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B2.2 fix-pass-6 T7: repo-config-invalid has PER-REPO blast radius -- an
# invalid merge_mode on repo B never blocks an issue whose dispatch lives
# on valid repo A.
# ---------------------------------------------------------------------------
section_ac_marker_config_invalid_per_repo() {
  local repo gitrepo base_sha tip
  repo="$(new_tmp_repo_with_git_ac true)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i333-x)"
  ac_merge_worker_tip_to_mainline "$gitrepo" "$tip"
  cat >"$repo/.pm/config.json" <<JSON
{"repos": {"demo-repo": {"path": "$gitrepo", "mainline": "main", "mainline_ref": "refs/heads/main", "fetch_policy": "local-only"}, "other-repo": {"path": "$gitrepo", "mainline": "main", "mainline_ref": "refs/heads/main", "fetch_policy": "local-only", "merge_mode": "rebase"}}, "herdr_workspace": "zzz-test-ws", "automation": {"auto_close": true}}
JSON

  seed_verified_dispatch "$repo" D-333 I-333 zzz-test-tab-333 i333-x "$base_sha" "$tip"
  seed_issue_state "$repo" I-333 OPEN ACTIVE

  run_track "$repo"
  assert_ac_closed "ac marker per-repo config blast radius: valid-repo issue still closes" "$repo" "I-333"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i333-x" >/dev/null 2>&1 || true
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# B2.2 fix-pass-6 T9 (track half): the marker arm is reachable via the
# result-not-descendant-of-base eligible strict failure too (recorded base
# not an ancestor of the branch's result), and the marker then closes.
# ---------------------------------------------------------------------------
section_ac_marker_via_not_descendant() {
  local repo gitrepo base_sha tip stray squash_sha
  repo="$(new_tmp_repo_with_git_ac_squash false)"
  gitrepo="$repo/target-repo"
  base_sha="$(git -C "$gitrepo" rev-parse HEAD)"
  tip="$(ac_make_worker_commit "$gitrepo" "$repo" i334-x)"
  # a side commit that is NOT an ancestor of the worker tip -- recorded as
  # the dispatch's base_sha to force result-not-descendant-of-base.
  # (distinct content, else it would mint the same sha as $tip)
  stray="$(ac_make_worker_commit "$gitrepo" "$repo" i334-stray)"
  (
    set -e
    cd "$repo/wt-i334-stray" || exit 1
    printf 'stray-only work\n' >stray.txt
    git add stray.txt
    git commit -q -m 'stray work'
  ) >&2 || { echo "FATAL: fixture git setup failed (t9: stray distinct commit)" >&2; exit 1; }
  stray="$(git -C "$repo/wt-i334-stray" rev-parse HEAD)"
  squash_sha="$(ac_squash_merge_to_mainline "$gitrepo" "$tip")"

  seed_verified_dispatch "$repo" D-334 I-334 zzz-test-tab-334 i334-x "$stray" "$tip"
  seed_issue_state "$repo" I-334 OPEN ACTIVE
  seed_merged_marker "$repo" D-334 "$squash_sha" "$tip"

  run_track "$repo"
  assert_ac_closed "ac marker via not-descendant strict failure" "$repo" "I-334"
  assert_true "ac marker via not-descendant: marker-attributed close" \
    bash -c 'grep -- "I-334" "$1/TRACKER.md" | grep -q "| auto-closed-marker |"' _ "$repo"

  git -C "$gitrepo" worktree remove --force "$repo/wt-i334-x" >/dev/null 2>&1 || true
  git -C "$gitrepo" worktree remove --force "$repo/wt-i334-stray" >/dev/null 2>&1 || true
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
echo "== track: surface -- branch-contains-no-new-work (C1: foreign mainline reset) =="
section_surface_branch_contains_no_new_work
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
echo "== track: STAGE 1 resists earlier-in-file duplicate-key poison (dispatch_issue_map, not raw re-scan) =="
section_surface_branch_issue_mismatch_stage1_poison_resists
echo "== track: surface -- base_sha-not-a-sha (short hex) =="
section_surface_base_sha_not_a_sha_short_hex
echo "== track: fully corroborated done tab on a sha256-object-format repo =="
section_fully_corroborated_sha256_repo
echo "== track: surface -- 64-hex ref-name dynamic-bypass attempt in a sha1 repo =="
section_surface_ref_name_dynamic_bypass_sha1_repo
echo "== track: surface -- 40-hex ref-name dynamic-bypass attempt in a sha256 repo =="
section_surface_ref_name_dynamic_bypass_sha256_repo

echo "== track: B2.1 auto-close -- non-vacuous end-to-end close =="
section_ac_end_to_end_closes
echo "== track: B2.1 auto-close -- G1 surface NEEDS-USER =="
section_ac_g1_needs_user
echo "== track: B2.1 auto-close -- G1 surface BLOCKED =="
section_ac_g1_blocked
echo "== track: B2.1 auto-close -- G1 surface paused/non-active =="
section_ac_g1_paused_non_active
echo "== track: B2.1 auto-close -- crash recovery re-archive (regardless of auto_close) =="
section_ac_crash_recovery_rearchive
echo "== track: B2.1 auto-close -- G1.5 quarantined question-for-issue must surface, not silently pass (Codex-sparred defect #1) =="
section_ac_g1p5_quarantined_question_for_issue
echo "== track: B2.1 auto-close -- G1.5 quarantined issue-state event must surface, not silently pass (Codex-sparred defect #1) =="
section_ac_g1p5_quarantined_issue_state
echo "== track: B2.1 auto-close -- G1.5 quarantined dispatch_new dup-i= poison must not false-close wrong issue (Codex-sparred defect, round 2, Critical A) =="
section_ac_g1p5_dispatch_new_duplicate_i_poison
echo "== track: B2.1 auto-close -- G1.5 malformed quarantined question (duplicate i=) must not false-close (Codex-sparred defect, round 2, Critical B) =="
section_ac_g1p5_malformed_question_duplicate_i
echo "== track: B2.1 auto-close -- G1.5 malformed quarantined question (quoted i=) must not false-close (Codex-sparred defect, round 2, Critical B) =="
section_ac_g1p5_malformed_question_quoted_i
echo "== track: B2.1 auto-close -- G1.5 malformed quarantined question (trailing token) must not false-close (Codex-sparred defect, round 2, Critical B) =="
section_ac_g1p5_malformed_question_trailing_token
echo "== track: B2.1 auto-close -- G1.5 malformed quarantined question (malformed q=) must not false-close (Codex-sparred defect, round 2, Critical B) =="
section_ac_g1p5_malformed_question_bad_q
echo "== track: B2.1 auto-close -- G1.5 no-regression: clean quarantine still closes normally =="
section_ac_g1p5_no_regression_clean_quarantine_still_closes
echo "== track: B2.1 auto-close -- G1.5 misattribution: dispatch_new forged i= must not shield real owner (Codex-sparred defect, round 25) =="
section_ac_g1p5_misattribution_dispatch_new
echo "== track: B2.1 auto-close -- G1.5 misattribution: grammar-VALID duplicate dispatch_new exercises authoritative-owner attribution path (not parse-failure fallback) (Codex-sparred defect, round 25 hardening) =="
section_ac_g1p5_dispatch_new_duplicate_valid_grammar_attribution
echo "== track: B2.1 auto-close -- G1.5 misattribution: question forged i= must not shield real owner (Codex-sparred defect, round 25) =="
section_ac_g1p5_misattribution_question
echo "== track: B2.1 auto-close -- G1.5 misattribution: unknown entity + unregistered forged i= is globally unattributable (Codex-sparred defect, round 25) =="
section_ac_g1p5_misattribution_unknown_entity
echo "== track: B2.1 auto-close -- G2 surface open-question-for-issue =="
section_ac_g2_open_question_for_issue
echo "== track: B2.1 auto-close -- G2 surface open-question-unscoped =="
section_ac_g2_open_question_unscoped
echo "== track: B2.1 auto-close -- G3 surface dispatch-not-VERIFIED =="
section_ac_g3_dispatch_not_verified
echo "== track: B2.1 auto-close -- G3 surface parent/child-roll-up-violation =="
section_ac_g3_parent_child_rollup
echo "== track: B2.1 auto-close -- G3 surface superseded-by-other-issue =="
section_ac_g3_superseded_by_other_issue
echo "== track: B2.1 auto-close -- G3 child_of roll-up must be transitive across the full descendant graph (Codex-sparred defect #2) =="
section_ac_g3_transitive_child_of_rollup
echo "== track: B2.1 auto-close -- G3 transitive roll-up control: all-terminal descendants close cleanly =="
section_ac_g3_transitive_child_of_rollup_all_terminal
echo "== track: B2.1 auto-close -- G4 surface result==base =="
section_ac_g4_result_equals_base
echo "== track: B2.1 auto-close -- G4 surface result-not-descendant-of-base =="
section_ac_g4_not_descendant
echo "== track: B2.1 auto-close -- G4 surface mainline-ref-not-configured =="
section_ac_g4_mainline_ref_not_configured
echo "== track: B2.1 auto-close -- G4 surface mainline-ref-missing =="
section_ac_g4_mainline_ref_missing
echo "== track: B2.1 auto-close -- G4 surface no-strict-ancestry-and-no-valid-marker =="
section_ac_g4_not_on_mainline
echo "== track: B2.1 auto-close -- G4 non-string mainline + fetch_policy=fetch must not crash (Codex-sparred defect #3) =="
section_ac_g4_mainline_non_string_type_guard
echo "== track: B2.1 auto-close -- G4 GIT_NO_REPLACE_OBJECTS=1 on every git call, incl. identity-anchor + graft probe (Codex-sparred defect #4) =="
section_ac_g4_replace_objects_env_on_every_git_call
echo "== track: B2.1 auto-close -- G4 fetch_policy=fetch successful fetch+close (Codex-sparred defect #5) =="
section_ac_g4_fetch_policy_success
echo "== track: B2.1 auto-close -- G4 fetch_policy=fetch unreachable origin surfaces fetch-failed (Codex-sparred defect #5) =="
section_ac_g4_fetch_policy_failed
echo "== track: B2.1 auto-close -- automation.auto_close OFF surfaces auto-close-disabled =="
section_ac_auto_close_disabled
echo "== track: B2.1 auto-close -- same-tick safety (RETURNED this tick != VERIFIED) =="
section_ac_same_tick_safety
echo "== track: B2.1 auto-close -- P2-1 OFF tick performs zero network fetches =="
section_ac_p21_off_mode_zero_network
echo "== track: B2.1 auto-close -- P2-1 ON tick fetches once per (repo,ref), pre-lock =="
section_ac_p21_one_fetch_per_repo_ref_per_tick
echo "== track: B2.1 auto-close -- P2-2 forged result_sha=mainline-tip must not close =="
section_ac_p22_forged_result_sha_mainline_tip
echo "== track: B2.1 auto-close -- P2-2 deleted dispatch branch is fail-closed =="
section_ac_p22_branch_deleted
echo "== track: B2.1 auto-close -- fix-pass-5b#1 non-ticket-convention branch rejected at G4 =="
section_ac_p22_branch_not_ticket_convention
echo "== track: B2.1 auto-close -- fix-pass-5b#2 close-outcome classifier is line-anchored =="
section_ac_close_classifier_line_anchored
echo "== track: B2.1 auto-close -- fix-pass-5b#3 REASONS registry is enforced =="
section_ac_reasons_registry_enforced
echo "== track: B2.1 auto-close -- P3-1 leading-dash remote never reaches git argv =="
section_ac_p31_leading_dash_remote
echo "== track: B2.1 auto-close -- P3-2 GIT_DIR decoy env is scrubbed =="
section_ac_p32_git_dir_decoy_scrubbed
echo "== track: B2.1 auto-close -- P3-3b whole-driver crash degrades loudly with detail =="
section_ac_p33_whole_driver_crash
echo "== track: B2.1 auto-close -- P3-6 unreadable prompts/ surfaces, never 'no leftovers' =="
section_ac_p36_leftover_listdir_error
echo "== close: P3-4 stable close-refusal stderr tokens (unit) =="
section_p34_close_refusal_tokens
echo "== track: B2.1 auto-close -- P3-4 durable close + archive failure renders closed-with-pending-archive =="
section_ac_p34_closed_with_pending_archive
echo "== track: B2.1 auto-close -- P3-7 surfaced-output signal partition =="
section_ac_p37_output_partition
echo "== track: B2.1 auto-close -- T2 G3 negative variants =="
section_ac_t2_g3_negative_variants
echo "== track: B2.1 auto-close -- T3 grafts file faking ancestry -> replace-affected =="
section_ac_t3_graft_file_fakes_ancestry
echo "== track: B2.1 auto-close -- T3 git-replace faking ancestry is neutralized =="
section_ac_t3_replace_ref_fakes_ancestry
echo "== track: B2.1 auto-close -- T4 G4 surface coverage (repo/metadata/sha) =="
section_ac_t4_g4_surface_coverage
echo "== track: B2.1 auto-close -- T7 idempotent second tick =="
section_ac_t7_idempotent_second_tick
echo "== track: B2.1 auto-close -- T8 G1 config variants both read disabled =="
section_ac_t8_g1_config_variants
echo "== track: B2.2 marker -- M1 squash close via marker arm =="
section_ac_marker_closes_squash
echo "== track: B2.2 marker -- M2 branch deleted, opt-in present =="
section_ac_marker_branch_deleted_allowed
echo "== track: B2.2 marker -- M2 branch deleted, opt-in ABSENT =="
section_ac_marker_branch_deleted_refused
echo "== track: B2.2 marker -- M3 no marker recorded =="
section_ac_marker_missing
echo "== track: B2.2 marker -- M4 merge_sha not on mainline =="
section_ac_marker_merge_not_on_mainline
echo "== track: B2.2 marker -- M5 merge_sha unverifiable =="
section_ac_marker_merge_sha_unverified
echo "== track: B2.2 marker -- M6 marker ignored on merge-mode repo =="
section_ac_marker_ignored_in_merge_mode
echo "== track: B2.2 marker -- M7 strict-first still closes strictly =="
section_ac_marker_strict_still_preferred
echo "== track: B2.2 marker -- M8 invalid per-repo config fail-closed =="
section_ac_marker_repo_config_invalid
echo "== track: B2.2 marker -- M9 branch binding not waived (forged result) =="
section_ac_marker_forged_result_not_on_branch
echo "== track: B2.2 fix-pass-6 F1a note precedes close (crash replay dedup) =="
section_ac_marker_note_precedes_close_replay
echo "== track: B2.2 fix-pass-6 F1b note emission failure blocks close =="
section_ac_marker_note_emit_failed
echo "== track: B2.2 fix-pass-6 F2 result==base refused on marker path =="
section_ac_marker_result_equals_base
echo "== track: review C2 marker merge_sha must postdate dispatch base =="
section_ac_marker_merge_predates_dispatch
echo "== track: B2.2 fix-pass-6 F3 raw non-sha marker quarantined at fold =="
section_ac_marker_raw_shape_quarantined
echo "== track: B2.2 fix-pass-6 F4+T2 direct-function marker guards =="
section_ac_marker_direct_fn_guards
echo "== track: B2.2 fix-pass-6 F5a marker + fetch policy success =="
section_ac_marker_fetch_policy_success
echo "== track: B2.2 fix-pass-6 F5b marker + stale ref, unreachable remote =="
section_ac_marker_fetch_policy_failed_stale_ref
echo "== track: B2.2 fix-pass-6 F5c marker + leading-dash remote =="
section_ac_marker_fetch_policy_leading_dash
echo "== track: B2.2 fix-pass-6 T1 old-attempt marker ignored =="
section_ac_marker_old_attempt_ignored
echo "== track: B2.2 fix-pass-6 T3 close-modes precedence =="
section_ac_marker_close_modes_precedence
echo "== track: B2.2 fix-pass-6 T5 allow-key absent fail-closed =="
section_ac_marker_branch_deleted_key_absent
echo "== track: B2.2 fix-pass-6 T6 abandoned marker not borrowed =="
section_ac_marker_abandoned_not_borrowed
echo "== track: B2.2 fix-pass-6 T7 per-repo config blast radius =="
section_ac_marker_config_invalid_per_repo
echo "== track: B2.2 fix-pass-6 T9 marker via not-descendant leg =="
section_ac_marker_via_not_descendant

# ---------------------------------------------------------------------------
# B3 auto-spawn: helpers + sections
# ---------------------------------------------------------------------------
# 30b. B3 fix: a herdr_workspace LABEL is resolved to a workspace_id before it
# reaches `herdr tab create --workspace`.
#
# herdr's CLI resolves --workspace by ID ONLY -- `--workspace <label>` returns
# workspace_not_found. The snapshot filter has always accepted either, so a
# configured label filtered correctly and then made EVERY spawn fail. The
# resolution now happens once, in the shared snapshot parse.
# ---------------------------------------------------------------------------
section_spawn_workspace_label_resolves_to_id() {
  local repo call_log snapshot
  repo="$(new_tmp_repo_spawn true 2 1)"
  # Reconfigure with the human-readable LABEL rather than the id.
  REPO="$repo" python3 - <<'RECONF'
import json, os
p = os.path.join(os.environ["REPO"], ".pm", "config.json")
cfg = json.load(open(p))
cfg["herdr_workspace"] = "zzz-test-label"
json.dump(cfg, open(p, "w"))
RECONF
  seed_automation_dispatch "$repo" D-001 I-001 widget
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  # Snapshot carries the label -> id mapping, and the panes/agents live under
  # the ID (which is how herdr actually reports them).
  snapshot='{"result": {"tabs": [], "panes": [], "agents": [],
    "workspaces": [{"label": "zzz-test-label", "workspace_id": "zzz-test-ws"}]}}'

  HERDR_CALL_LOG="$call_log" run_track "$repo" "$snapshot"

  assert_eq "spawn ws-label: exit 0" "0" "$TR_RC"
  assert_eq "spawn ws-label: tab create used the resolved ID, not the label" \
    "tab create --workspace zzz-test-ws --label i001-widget --no-focus" \
    "$(sed -n '1p' "$call_log")"
  assert_contains "spawn ws-label: agent start also used the resolved ID" \
    "$(sed -n '2p' "$call_log")" "--workspace zzz-test-ws"
  # The whole point: the label must never reach herdr.
  if grep -q -- "--workspace zzz-test-label" "$call_log"; then
    fail "spawn ws-label: the raw label never reaches a herdr call" "$(cat "$call_log")"
  else
    ok "spawn ws-label: the raw label never reaches a herdr call"
  fi
  assert_eq "spawn ws-label: same-tick ACK still recorded" \
    "ACKED" "$(sp_idx "$repo" "d['dispatches']['D-001']['state']")"
}

# ---------------------------------------------------------------------------

sp_idx() {
  # sp_idx <repo> <python-expr over d(=index)>
  python3 -c "import json;d=json.load(open('$1/.pm/index.json'));print($2)" 2>/dev/null
}

# 30. Happy-path spawn: intent -> tab create -> agent start -> same-tick ACK.
section_spawn_happy_path() {
  local repo call_log
  repo="$(new_tmp_repo_spawn true 2 1)"
  seed_automation_dispatch "$repo" D-001 I-001 widget
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" run_track "$repo" "$(spawn_snapshot_json)"
  assert_eq "spawn happy: exit 0" "0" "$TR_RC"

  assert_eq "spawn happy: herdr tab create argv exact (workspace + ticket label + --no-focus)" \
    "tab create --workspace zzz-test-ws --label i001-widget --no-focus" \
    "$(sed -n '1p' "$call_log")"
  assert_eq "spawn happy: herdr agent start argv exact (name, tab from tab-create stdout, --no-focus, argv w/ substituted prompt path)" \
    "agent start i001-widget-D001A01 --workspace zzz-test-ws --tab zzz-test-ws:t91 --no-focus -- zzz-test-runner $repo/prompts/I-001_widget_2026-07-25.md" \
    "$(sed -n '2p' "$call_log")"
  assert_eq "spawn happy: exactly two herdr side-effect calls" "2" "$(wc -l < "$call_log" | tr -d ' ')"

  assert_eq "spawn happy: exactly ONE durable spawn_intent line" \
    "1" "$(grep -c '^EVENT spawn_intent d=D-001 a=A-01 ' "$repo/.pm/events.log")"
  assert_contains "spawn happy: intent carries the deterministic worker ref" \
    "$(grep '^EVENT spawn_intent' "$repo/.pm/events.log")" "ref=i001-widget-D001A01"
  assert_eq "spawn happy: same-tick ACK recorded" "ACKED" "$(sp_idx "$repo" "d['dispatches']['D-001']['state']")"
  assert_eq "spawn happy: ACK carries the tab-create stdout tab_id" \
    "zzz-test-ws:t91" "$(sp_idx "$repo" "d['dispatches']['D-001']['tab']")"
  assert_contains "spawn happy: stdout reports the spawn" "$TR_OUT" "SPAWNED D-001 a=A-01"
  assert_true "spawn happy: TRACKER.md automation section lists D-001" \
    bash -c "grep -q 'D-001' '$repo/TRACKER.md'"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 31. auto_spawn off + non-empty queue -> zero herdr spawn calls + steady count.
section_spawn_disabled_steady() {
  local repo call_log
  repo="$(new_tmp_repo_spawn false 2 1)"
  seed_automation_dispatch "$repo" D-011 I-011 widget
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" run_track "$repo" "$(spawn_snapshot_json)"
  assert_eq "spawn disabled: exit 0" "0" "$TR_RC"
  assert_eq "spawn disabled: zero herdr spawn calls" "0" "$(wc -l < "$call_log" | tr -d ' ')"
  assert_eq "spawn disabled: no spawn_intent appended" \
    "0" "$(grep -c '^EVENT spawn_intent' "$repo/.pm/events.log")"
  assert_eq "spawn disabled: dispatch stays DISPATCHED" \
    "DISPATCHED" "$(sp_idx "$repo" "d['dispatches']['D-011']['state']")"
  assert_contains "spawn disabled: steady-state auto-spawn-disabled count surfaced" \
    "$TR_OUT" "auto-spawn-disabled"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 32. capacity at/over -> no spawn + steady capacity-exceeded count.
section_spawn_capacity() {
  local repo call_log panes agents
  repo="$(new_tmp_repo_spawn true 1 1)"
  seed_automation_dispatch "$repo" D-021 I-021 widget
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"
  panes="[$(pane_json zzz-test-other-worker zzz-test-ws:p1 zzz-test-ws:t1)]"
  agents="[$(agent_json zzz-test-ws:p1 zzz-test-ws:t1)]"

  HERDR_CALL_LOG="$call_log" run_track "$repo" "$(spawn_snapshot_json "$panes" "$agents")"
  assert_eq "spawn capacity: exit 0" "0" "$TR_RC"
  assert_eq "spawn capacity: zero herdr spawn calls at capacity" "0" "$(wc -l < "$call_log" | tr -d ' ')"
  assert_eq "spawn capacity: no spawn_intent appended" \
    "0" "$(grep -c '^EVENT spawn_intent' "$repo/.pm/events.log")"
  assert_contains "spawn capacity: steady-state capacity-exceeded count surfaced" \
    "$TR_OUT" "capacity-exceeded"
  assert_eq "spawn capacity: dispatch stays DISPATCHED" \
    "DISPATCHED" "$(sp_idx "$repo" "d['dispatches']['D-021']['state']")"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 33. Queue exclusions: NEEDS-USER issue, BLOCKED issue, open question,
# human-lane dispatch, open spawn_intent -- none picked.
section_spawn_queue_exclusions() {
  local repo call_log
  repo="$(new_tmp_repo_spawn true 5 5)"
  # (a) issue NEEDS-USER
  seed_automation_dispatch "$repo" D-101 I-101 widgeta
  seed_issue_state "$repo" I-101 ACTIVE NEEDS-USER
  # (b) issue BLOCKED
  seed_automation_dispatch "$repo" D-102 I-102 widgetb
  seed_issue_state "$repo" I-102 ACTIVE BLOCKED
  # (c) open question on the issue
  seed_automation_dispatch "$repo" D-103 I-103 widgetc
  seed_question "$repo" Q-103 OPEN I-103
  # (d) human-lane dispatch (still tab=?)
  seed_issue_state "$repo" I-104 OPEN ACTIVE
  PM_ROOT="$repo" pm_apply dispatch_new d=D-104 i=I-104 at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-104 from=READY to=DISPATCHED lane=human \
    at="$(now_iso)" tab="?" >/dev/null
  # (e) open spawn_intent (prior tick)
  seed_automation_dispatch "$repo" D-105 I-105 widgete
  seed_spawn_intent "$repo" D-105 A-01 i105-widgete-D105A01
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" run_track "$repo" "$(spawn_snapshot_json)"
  assert_eq "spawn exclusions: exit 0" "0" "$TR_RC"
  assert_eq "spawn exclusions: zero herdr spawn calls" "0" "$(wc -l < "$call_log" | tr -d ' ')"
  local d
  for d in D-101 D-102 D-103 D-104 D-105; do
    assert_eq "spawn exclusions: $d stays DISPATCHED" \
      "DISPATCHED" "$(sp_idx "$repo" "d['dispatches']['$d']['state']")"
  done
  assert_eq "spawn exclusions: only the pre-seeded intent line exists (no new intents)" \
    "1" "$(grep -c '^EVENT spawn_intent' "$repo/.pm/events.log")"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 34. prompt-sha mismatch -> surface, NO herdr calls, NO durable intent.
section_spawn_prompt_sha_mismatch() {
  local repo call_log
  repo="$(new_tmp_repo_spawn true 2 1)"
  seed_automation_dispatch "$repo" D-031 I-031 widget
  printf 'tampered after prep\n' >>"$repo/prompts/I-031_widget_2026-07-25.md"
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" run_track "$repo" "$(spawn_snapshot_json)"
  assert_eq "spawn sha-mismatch: exit 0" "0" "$TR_RC"
  assert_contains "spawn sha-mismatch: prompt-sha-mismatch surfaced" "$TR_OUT" "prompt-sha-mismatch"
  assert_eq "spawn sha-mismatch: zero herdr spawn calls" "0" "$(wc -l < "$call_log" | tr -d ' ')"
  assert_eq "spawn sha-mismatch: no spawn_intent appended" \
    "0" "$(grep -c '^EVENT spawn_intent' "$repo/.pm/events.log")"
  assert_eq "spawn sha-mismatch: dispatch stays DISPATCHED" \
    "DISPATCHED" "$(sp_idx "$repo" "d['dispatches']['D-031']['state']")"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 35. Intended worker name already present in panes[] -> name-collision.
section_spawn_name_collision() {
  local repo call_log panes
  repo="$(new_tmp_repo_spawn true 2 1)"
  seed_automation_dispatch "$repo" D-041 I-041 widget
  panes="[$(pane_json i041-widget-D041A01 zzz-test-ws:p2 zzz-test-ws:t2)]"
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" run_track "$repo" "$(spawn_snapshot_json "$panes")"
  assert_eq "spawn name-collision: exit 0" "0" "$TR_RC"
  assert_contains "spawn name-collision: name-collision surfaced" "$TR_OUT" "name-collision"
  assert_eq "spawn name-collision: zero herdr spawn calls" "0" "$(wc -l < "$call_log" | tr -d ' ')"
  assert_eq "spawn name-collision: no spawn_intent appended" \
    "0" "$(grep -c '^EVENT spawn_intent' "$repo/.pm/events.log")"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 36. tab create fails -> surfaced with the herdr error code, NO agent
# start, intent stays durable (ages into recovery next ticks).
section_spawn_tab_create_failure() {
  local repo call_log
  repo="$(new_tmp_repo_spawn true 2 5)"
  seed_automation_dispatch "$repo" D-051 I-051 widget
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" HERDR_TAB_CREATE_MODE=fail run_track "$repo" "$(spawn_snapshot_json)"
  assert_eq "spawn tab-create-fail: exit 0" "0" "$TR_RC"
  assert_contains "spawn tab-create-fail: herdr-tab-create-failed surfaced" "$TR_OUT" "herdr-tab-create-failed"
  assert_contains "spawn tab-create-fail: herdr error code carried in detail" "$TR_OUT" "workspace_not_found"
  assert_eq "spawn tab-create-fail: only the tab create call happened (no agent start)" \
    "1" "$(wc -l < "$call_log" | tr -d ' ')"
  assert_eq "spawn tab-create-fail: intent is DURABLE despite the failure" \
    "1" "$(grep -c '^EVENT spawn_intent d=D-051 ' "$repo/.pm/events.log")"
  assert_eq "spawn tab-create-fail: dispatch stays DISPATCHED (no ACK)" \
    "DISPATCHED" "$(sp_idx "$repo" "d['dispatches']['D-051']['state']")"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 37. agent start fails -> surfaced with the herdr error code, NO ACK.
section_spawn_agent_start_failure() {
  local repo call_log
  repo="$(new_tmp_repo_spawn true 2 5)"
  seed_automation_dispatch "$repo" D-061 I-061 widget
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" HERDR_AGENT_START_MODE=fail run_track "$repo" "$(spawn_snapshot_json)"
  assert_eq "spawn agent-start-fail: exit 0" "0" "$TR_RC"
  assert_contains "spawn agent-start-fail: herdr-start-failed surfaced" "$TR_OUT" "herdr-start-failed"
  assert_contains "spawn agent-start-fail: herdr error code carried in detail" "$TR_OUT" "agent_placement_not_found"
  assert_eq "spawn agent-start-fail: create + start + best-effort close of the leaked tab" \
    "3" "$(wc -l < "$call_log" | tr -d ' ')"
  assert_contains "spawn agent-start-fail: the close targets the tab track created this tick" \
    "$(sed -n '3p' "$call_log")" "tab close zzz-test-ws:t91"
  assert_eq "spawn agent-start-fail: no ACK recorded" \
    "DISPATCHED" "$(sp_idx "$repo" "d['dispatches']['D-061']['state']")"
  assert_eq "spawn agent-start-fail: intent is DURABLE despite the failure" \
    "1" "$(grep -c '^EVENT spawn_intent d=D-061 ' "$repo/.pm/events.log")"
  assert_eq "spawn agent-start-fail: no ACKED transition appended" \
    "0" "$(grep -c 'to=ACKED' "$repo/.pm/events.log")"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 38. Crash recovery: PRIOR-tick intent + exactly one matching live pane ->
# track NEVER auto-ACKs on a name join (herdr allows duplicate names and
# the deterministic worker name is derivable from events.log, so a single
# impostor pane could otherwise silence the orphan surface forever).
# Instead: a `spawn-ack-unconfirmed` row naming the candidate pane and the
# exact manual record command. Dispatch stays DISPATCHED; intent stays open.
section_spawn_recovery_ack() {
  local repo call_log panes
  repo="$(new_tmp_repo_spawn true 2 5)"
  seed_automation_dispatch "$repo" D-301 I-301 widget
  seed_spawn_intent "$repo" D-301 A-01 i301-widget-D301A01
  panes="[$(pane_json i301-widget-D301A01 zzz-test-ws:p5 zzz-test-tab-777)]"
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" run_track "$repo" "$(spawn_snapshot_json "$panes")"
  assert_eq "spawn recovery: exit 0" "0" "$TR_RC"
  assert_contains "spawn recovery: spawn-ack-unconfirmed surfaced" "$TR_OUT" "spawn-ack-unconfirmed"
  assert_eq "spawn recovery: dispatch NOT auto-acked (stays DISPATCHED)" \
    "DISPATCHED" "$(sp_idx "$repo" "d['dispatches']['D-301']['state']")"
  assert_eq "spawn recovery: no ACKED transition appended" \
    "0" "$(grep -c 'to=ACKED' "$repo/.pm/events.log")"
  assert_contains "spawn recovery: row names the candidate pane name" "$TR_OUT" "i301-widget-D301A01"
  assert_contains "spawn recovery: row names the candidate pane tab_id" "$TR_OUT" "zzz-test-tab-777"
  assert_contains "spawn recovery: row names the candidate pane pane_id" "$TR_OUT" "zzz-test-ws:p5"
  assert_contains "spawn recovery: row carries the exact manual confirm command" \
    "$TR_OUT" "bin/record dispatch D-301 ACKED --tab zzz-test-tab-777"
  assert_eq "spawn recovery: zero new herdr side-effect calls" "0" "$(wc -l < "$call_log" | tr -d ' ')"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 38b. Single-impostor hardening: ONE pane matching the (derivable) worker
# name in the worker-absent window must NOT be auto-acked -- surfaced only,
# and the intent stays open (the impostor cannot silence the orphan path).
section_spawn_recovery_single_impostor() {
  local repo call_log panes
  repo="$(new_tmp_repo_spawn true 2 5)"
  seed_automation_dispatch "$repo" D-302 I-302 widget
  seed_spawn_intent "$repo" D-302 A-01 i302-widget-D302A01
  # the impostor: a pane whose name matches exactly (herdr allows dup names)
  panes="[$(pane_json i302-widget-D302A01 zzz-test-ws:p66 zzz-test-tab-666)]"
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" run_track "$repo" "$(spawn_snapshot_json "$panes")"
  assert_eq "spawn impostor: exit 0" "0" "$TR_RC"
  assert_contains "spawn impostor: surfaced (spawn-ack-unconfirmed), never acked" \
    "$TR_OUT" "spawn-ack-unconfirmed"
  assert_eq "spawn impostor: dispatch stays DISPATCHED" \
    "DISPATCHED" "$(sp_idx "$repo" "d['dispatches']['D-302']['state']")"
  assert_eq "spawn impostor: no ACKED transition appended" \
    "0" "$(grep -c 'to=ACKED' "$repo/.pm/events.log")"
  assert_eq "spawn impostor: zero herdr side-effect calls" "0" "$(wc -l < "$call_log" | tr -d ' ')"
  # the intent is still OPEN in the fold -- a later panes-absent tick still
  # ages it into suspected-orphan-intent
  assert_eq "spawn impostor: intent still open in the fold" \
    "True" "$(sp_idx "$repo" "'A-01' in d['dispatches']['D-302']['spawn_intent']")"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 39. Two live panes with the intent's name -> ambiguous-spawn-ack, no ACK.
section_spawn_recovery_ambiguous() {
  local repo call_log panes
  repo="$(new_tmp_repo_spawn true 2 5)"
  seed_automation_dispatch "$repo" D-311 I-311 widget
  seed_spawn_intent "$repo" D-311 A-01 i311-widget-D311A01
  panes="[$(pane_json i311-widget-D311A01 zzz-test-ws:p5 zzz-test-tab-771), $(pane_json i311-widget-D311A01 zzz-test-ws:p6 zzz-test-tab-772)]"
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" run_track "$repo" "$(spawn_snapshot_json "$panes")"
  assert_eq "spawn ambiguous: exit 0" "0" "$TR_RC"
  assert_contains "spawn ambiguous: ambiguous-spawn-ack surfaced" "$TR_OUT" "ambiguous-spawn-ack"
  assert_eq "spawn ambiguous: dispatch NOT acked" \
    "DISPATCHED" "$(sp_idx "$repo" "d['dispatches']['D-311']['state']")"
  assert_eq "spawn ambiguous: zero herdr side-effect calls" "0" "$(wc -l < "$call_log" | tr -d ' ')"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 40. Open intent, pane ABSENT, intent aged >= spawn_ack_timeout_ticks ->
# suspected-orphan-intent; track NEVER auto-abandons.
section_spawn_orphan_aged() {
  local repo call_log
  repo="$(new_tmp_repo_spawn true 2 1)"
  seed_automation_dispatch "$repo" D-321 I-321 widget
  seed_spawn_intent "$repo" D-321 A-01 i321-widget-D321A01
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" run_track "$repo" "$(spawn_snapshot_json)"
  assert_eq "spawn orphan aged: exit 0" "0" "$TR_RC"
  assert_contains "spawn orphan aged: suspected-orphan-intent surfaced" "$TR_OUT" "suspected-orphan-intent"
  assert_eq "spawn orphan aged: dispatch NOT auto-abandoned (stays DISPATCHED)" \
    "DISPATCHED" "$(sp_idx "$repo" "d['dispatches']['D-321']['state']")"
  assert_eq "spawn orphan aged: no ABANDONED transition appended" \
    "0" "$(grep -c 'to=ABANDONED' "$repo/.pm/events.log")"
  assert_eq "spawn orphan aged: no re-spawn while the intent is open" \
    "0" "$(wc -l < "$call_log" | tr -d ' ')"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 41. Open intent, pane ABSENT, younger than the timeout -> no row at all.
section_spawn_orphan_young() {
  local repo call_log
  repo="$(new_tmp_repo_spawn true 2 2)"
  seed_automation_dispatch "$repo" D-331 I-331 widget
  seed_spawn_intent "$repo" D-331 A-01 i331-widget-D331A01
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" run_track "$repo" "$(spawn_snapshot_json)"
  assert_eq "spawn orphan young: exit 0" "0" "$TR_RC"
  if [[ "$TR_OUT" == *"suspected-orphan-intent"* ]]; then
    fail "spawn orphan young: NO orphan row before the timeout" "row surfaced early"
  else
    ok "spawn orphan young: NO orphan row before the timeout"
  fi
  assert_eq "spawn orphan young: dispatch left for next tick (DISPATCHED)" \
    "DISPATCHED" "$(sp_idx "$repo" "d['dispatches']['D-331']['state']")"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 42. TOCTOU race: state changes between the durable intent and the ACK
# (injected during the herdr tab create call) -> benign surface, no crash,
# no ACK, the racing event stands.
section_spawn_toctou_race() {
  local repo call_log
  repo="$(new_tmp_repo_spawn true 2 5)"
  seed_automation_dispatch "$repo" D-401 I-401 widget
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" \
    HERDR_RACE_APPEND="EVENT dispatch_state d=D-401 a=A-01 from=DISPATCHED to=FAILED lane=automation at=2026-07-25T19:00:00Z" \
    run_track "$repo" "$(spawn_snapshot_json)"
  assert_eq "spawn toctou: exit 0 (benign, never a crash)" "0" "$TR_RC"
  assert_contains "spawn toctou: benign raced-refused surface" "$TR_OUT" "raced-refused"
  assert_eq "spawn toctou: racing FAILED transition stands" \
    "FAILED" "$(sp_idx "$repo" "d['dispatches']['D-401']['state']")"
  assert_eq "spawn toctou: no ACKED transition appended" \
    "0" "$(grep -c 'to=ACKED' "$repo/.pm/events.log")"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 43. Runtime-invalid spawn config (auto_spawn on, empty spawn_argv) ->
# fail-closed skip + spawn-config-invalid row, zero herdr side effects.
section_spawn_config_invalid() {
  local repo call_log
  repo="$(new_tmp_repo_spawn true 2 1 '[]')"
  seed_automation_dispatch "$repo" D-501 I-501 widget
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" run_track "$repo" "$(spawn_snapshot_json)"
  assert_eq "spawn config-invalid: exit 0" "0" "$TR_RC"
  assert_contains "spawn config-invalid: spawn-config-invalid surfaced" "$TR_OUT" "spawn-config-invalid"
  assert_eq "spawn config-invalid: zero herdr spawn calls (fail-closed skip)" \
    "0" "$(wc -l < "$call_log" | tr -d ' ')"
  assert_eq "spawn config-invalid: no spawn_intent appended" \
    "0" "$(grep -c '^EVENT spawn_intent' "$repo/.pm/events.log")"
  assert_eq "spawn config-invalid: dispatch stays DISPATCHED" \
    "DISPATCHED" "$(sp_idx "$repo" "d['dispatches']['D-501']['state']")"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 45. Two free slots, two candidates -> BOTH spawn, FIFO by dispatch
# number, each ACKed with its OWN tab id.
section_spawn_fifo_two_slots() {
  local repo call_log
  repo="$(new_tmp_repo_spawn true 2 1)"
  # seeded out of numeric order on purpose: FIFO must sort by dispatch number
  seed_automation_dispatch "$repo" D-602 I-602 gadget
  seed_automation_dispatch "$repo" D-601 I-601 widget
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" run_track "$repo" "$(spawn_snapshot_json)"
  assert_eq "spawn fifo: exit 0" "0" "$TR_RC"
  assert_eq "spawn fifo: four herdr side-effect calls (2 tabs + 2 starts)" \
    "4" "$(wc -l < "$call_log" | tr -d ' ')"
  assert_contains "spawn fifo: D-601 tab created FIRST (FIFO by dispatch number)" \
    "$(sed -n '1p' "$call_log")" "--label i601-widget"
  assert_contains "spawn fifo: D-602 tab created second" \
    "$(sed -n '3p' "$call_log")" "--label i602-gadget"
  assert_eq "spawn fifo: D-601 ACKED" "ACKED" "$(sp_idx "$repo" "d['dispatches']['D-601']['state']")"
  assert_eq "spawn fifo: D-602 ACKED" "ACKED" "$(sp_idx "$repo" "d['dispatches']['D-602']['state']")"
  assert_eq "spawn fifo: distinct tabs per worker" \
    "True" "$(sp_idx "$repo" "d['dispatches']['D-601']['tab'] != d['dispatches']['D-602']['tab']")"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 46. Inner (per-slot) capacity guard: 2 slots, 3 queued -> exactly 2
# spawned FIFO + 1 capacity-exceeded + exactly 4 herdr calls.
section_spawn_inner_capacity() {
  local repo call_log
  repo="$(new_tmp_repo_spawn true 2 5)"
  seed_automation_dispatch "$repo" D-701 I-701 widgeta
  seed_automation_dispatch "$repo" D-702 I-702 widgetb
  seed_automation_dispatch "$repo" D-703 I-703 widgetc
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" run_track "$repo" "$(spawn_snapshot_json)"
  assert_eq "spawn inner-capacity: exit 0" "0" "$TR_RC"
  assert_eq "spawn inner-capacity: exactly 4 herdr calls (2 creates + 2 starts)" \
    "4" "$(wc -l < "$call_log" | tr -d ' ')"
  assert_eq "spawn inner-capacity: D-701 ACKED" "ACKED" "$(sp_idx "$repo" "d['dispatches']['D-701']['state']")"
  assert_eq "spawn inner-capacity: D-702 ACKED" "ACKED" "$(sp_idx "$repo" "d['dispatches']['D-702']['state']")"
  assert_eq "spawn inner-capacity: D-703 NOT spawned" \
    "DISPATCHED" "$(sp_idx "$repo" "d['dispatches']['D-703']['state']")"
  assert_contains "spawn inner-capacity: capacity-exceeded steady names D-703" \
    "$TR_OUT" "SPAWN-STEADY (capacity-exceeded) count=1 ids=D-703"
  assert_eq "spawn inner-capacity: exactly two intent lines" \
    "2" "$(grep -c '^EVENT spawn_intent' "$repo/.pm/events.log")"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 47. Multi-tick orphan aging at a >1 timeout: the accumulator and the age
# file round-trip. timeout=3: no surface on ticks 1-2, surface on tick 3,
# age file accumulates 1 -> 2 -> 3.
section_spawn_orphan_multitick() {
  local repo
  repo="$(new_tmp_repo_spawn true 2 3)"
  seed_automation_dispatch "$repo" D-711 I-711 widget
  seed_spawn_intent "$repo" D-711 A-01 i711-widget-D711A01

  local tick n
  for tick in 1 2 3; do
    run_track "$repo" "$(spawn_snapshot_json)"
    assert_eq "spawn multitick: tick $tick exit 0" "0" "$TR_RC"
    n="$(python3 -c "import json;print(json.load(open('$repo/.pm/spawn-intent-age.json'))['D-711/A-01']['n'])" 2>/dev/null)"
    assert_eq "spawn multitick: age file accumulates to $tick on tick $tick" "$tick" "$n"
    if [[ "$tick" -lt 3 ]]; then
      if [[ "$TR_OUT" == *"suspected-orphan-intent"* ]]; then
        fail "spawn multitick: NO orphan surface on tick $tick" "surfaced early"
      else
        ok "spawn multitick: NO orphan surface on tick $tick"
      fi
    else
      assert_contains "spawn multitick: orphan surfaces on tick 3 (timeout reached)" \
        "$TR_OUT" "suspected-orphan-intent"
    fi
  done
  assert_eq "spawn multitick: dispatch never auto-abandoned" \
    "DISPATCHED" "$(sp_idx "$repo" "d['dispatches']['D-711']['state']")"

  rm -rf "$repo"
}

# 48. DURABLE under-lock capacity gate: the log already carries an ACKED
# automation dispatch, but the snapshot (lying/stale) shows zero live
# agents. Plan-time capacity would spawn; the under-lock durable count must
# refuse -- fail direction is UNDER-spawn.
section_spawn_durable_capacity_gate() {
  local repo call_log
  repo="$(new_tmp_repo_spawn true 1 5)"
  seed_automation_dispatch "$repo" D-801 I-801 widgeta
  PM_ROOT="$repo" pm_apply dispatch_state d=D-801 a=A-01 from=DISPATCHED to=ACKED \
    lane=automation tab=zzz-test-tab-801 at="$(now_iso)" >/dev/null
  seed_automation_dispatch "$repo" D-802 I-802 widgetb
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" run_track "$repo" "$(spawn_snapshot_json)"
  assert_eq "spawn durable-gate: exit 0" "0" "$TR_RC"
  assert_eq "spawn durable-gate: ZERO herdr calls despite the optimistic snapshot" \
    "0" "$(wc -l < "$call_log" | tr -d ' ')"
  assert_contains "spawn durable-gate: capacity-exceeded surfaced via the durable count" \
    "$TR_OUT" "durable capacity gate"
  assert_contains "spawn durable-gate: row names the slot holder" \
    "$TR_OUT" "held by: D-801"
  assert_eq "spawn durable-gate: no intent appended for D-802" \
    "0" "$(grep -c '^EVENT spawn_intent d=D-802 ' "$repo/.pm/events.log")"
  assert_eq "spawn durable-gate: D-802 stays DISPATCHED" \
    "DISPATCHED" "$(sp_idx "$repo" "d['dispatches']['D-802']['state']")"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 49. Under-lock prompt re-hash (plan->lock TOCTOU): the prompt is tampered
# DURING the previous candidate's tab create -- after D-902's plan-time
# hash passed, before its under-lock re-check. Must surface, no intent.
section_spawn_prompt_rehash_under_lock() {
  local repo call_log
  repo="$(new_tmp_repo_spawn true 2 5)"
  seed_automation_dispatch "$repo" D-901 I-901 widget
  seed_automation_dispatch "$repo" D-902 I-902 gadget
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" \
    HERDR_TAMPER_PROMPT="$repo/prompts/I-902_gadget_2026-07-25.md" \
    run_track "$repo" "$(spawn_snapshot_json)"
  assert_eq "spawn rehash: exit 0" "0" "$TR_RC"
  assert_eq "spawn rehash: D-901 spawned normally" \
    "ACKED" "$(sp_idx "$repo" "d['dispatches']['D-901']['state']")"
  assert_contains "spawn rehash: D-902 surfaced prompt-sha-mismatch from the under-lock re-hash" \
    "$TR_OUT" "under-lock re-hash"
  assert_eq "spawn rehash: no intent appended for D-902" \
    "0" "$(grep -c '^EVENT spawn_intent d=D-902 ' "$repo/.pm/events.log")"
  assert_eq "spawn rehash: only D-901's herdr calls happened" \
    "2" "$(wc -l < "$call_log" | tr -d ' ')"
  assert_eq "spawn rehash: D-902 stays DISPATCHED" \
    "DISPATCHED" "$(sp_idx "$repo" "d['dispatches']['D-902']['state']")"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 50. Stuck-intent lifecycle: tab create fails on tick 1; later ticks age
# the intent; the timeout tick surfaces the orphan WITH the known cause.
section_spawn_stuck_intent_cause() {
  local repo call_log
  repo="$(new_tmp_repo_spawn true 2 2)"
  seed_automation_dispatch "$repo" D-721 I-721 widget
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  # tick 1: intent appended durably, tab create fails, cause recorded
  HERDR_CALL_LOG="$call_log" HERDR_TAB_CREATE_MODE=fail run_track "$repo" "$(spawn_snapshot_json)"
  assert_eq "spawn stuck-cause: tick 1 exit 0" "0" "$TR_RC"
  assert_contains "spawn stuck-cause: tick 1 surfaces the create failure" "$TR_OUT" "herdr-tab-create-failed"
  # tick 2: ages (n=1 < 2), no orphan yet
  run_track "$repo" "$(spawn_snapshot_json)"
  if [[ "$TR_OUT" == *"suspected-orphan-intent"* ]]; then
    fail "spawn stuck-cause: no orphan before the timeout" "surfaced early"
  else
    ok "spawn stuck-cause: no orphan before the timeout"
  fi
  # tick 3: n=2 >= timeout -> orphan WITH the recorded cause
  run_track "$repo" "$(spawn_snapshot_json)"
  assert_contains "spawn stuck-cause: orphan surfaces at the timeout" "$TR_OUT" "suspected-orphan-intent"
  assert_contains "spawn stuck-cause: orphan row carries the known cause" \
    "$TR_OUT" "last known cause: herdr-tab-create-failed (workspace_not_found)"
  assert_eq "spawn stuck-cause: dispatch never auto-abandoned" \
    "DISPATCHED" "$(sp_idx "$repo" "d['dispatches']['D-721']['state']")"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 51. tab create exit 0 but NO result.tab.tab_id -> herdr-tab-create-failed,
# no agent start, intent durable.
section_spawn_tab_create_no_id() {
  local repo call_log
  repo="$(new_tmp_repo_spawn true 2 5)"
  seed_automation_dispatch "$repo" D-731 I-731 widget
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" HERDR_TAB_CREATE_MODE=ok_no_id run_track "$repo" "$(spawn_snapshot_json)"
  assert_eq "spawn no-id: exit 0" "0" "$TR_RC"
  assert_contains "spawn no-id: herdr-tab-create-failed surfaced" "$TR_OUT" "herdr-tab-create-failed"
  assert_contains "spawn no-id: detail names the missing tab_id" "$TR_OUT" "no result.tab.tab_id"
  assert_eq "spawn no-id: only the tab create call happened (no agent start)" \
    "1" "$(wc -l < "$call_log" | tr -d ' ')"
  assert_eq "spawn no-id: intent is DURABLE" \
    "1" "$(grep -c '^EVENT spawn_intent d=D-731 ' "$repo/.pm/events.log")"
  assert_eq "spawn no-id: dispatch stays DISPATCHED" \
    "DISPATCHED" "$(sp_idx "$repo" "d['dispatches']['D-731']['state']")"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 52. Under-lock pre-append re-check refusal: the owning issue flips to
# NEEDS-USER inside the plan->lock window (injected during the PREVIOUS
# candidate's tab create) -> raced-refused, ZERO herdr calls for that
# candidate, no intent.
section_spawn_underlock_recheck_refusal() {
  local repo call_log
  repo="$(new_tmp_repo_spawn true 5 5)"
  seed_automation_dispatch "$repo" D-911 I-911 widget
  seed_automation_dispatch "$repo" D-912 I-912 gadget
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" \
    HERDR_RACE_APPEND="EVENT issue_state i=I-912 from=ACTIVE to=NEEDS-USER at=2026-07-25T19:00:00Z" \
    run_track "$repo" "$(spawn_snapshot_json)"
  assert_eq "spawn recheck-refusal: exit 0" "0" "$TR_RC"
  assert_eq "spawn recheck-refusal: D-911 spawned normally" \
    "ACKED" "$(sp_idx "$repo" "d['dispatches']['D-911']['state']")"
  assert_contains "spawn recheck-refusal: D-912 benignly raced-refused" "$TR_OUT" "raced-refused"
  assert_eq "spawn recheck-refusal: zero herdr calls for D-912 (only D-911's two)" \
    "2" "$(wc -l < "$call_log" | tr -d ' ')"
  assert_eq "spawn recheck-refusal: no intent appended for D-912" \
    "0" "$(grep -c '^EVENT spawn_intent d=D-912 ' "$repo/.pm/events.log")"
  assert_eq "spawn recheck-refusal: D-912 stays DISPATCHED" \
    "DISPATCHED" "$(sp_idx "$repo" "d['dispatches']['D-912']['state']")"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 53. Plan-driver crash -> spawn-driver-error loud degrade: exit 0, row
# surfaced, stderr echoed, zero herdr side effects. (The FIXTURE's copy of
# bin/track is poisoned -- the source tree is never touched.)
section_spawn_driver_error() {
  local repo call_log
  repo="$(new_tmp_repo_spawn true 2 5)"
  seed_automation_dispatch "$repo" D-741 I-741 widget
  sed -i 's/^_sp_plan = {"spawn": \[\], "rows": \[\], "steady": {}, "age": {}, "ran": False}$/raise RuntimeError("zzz-test poison")/' \
    "$repo/bin/_track_spawn"
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" run_track "$repo" "$(spawn_snapshot_json)"
  assert_eq "spawn driver-error: exit 0 (loud degrade, not a crash)" "0" "$TR_RC"
  assert_contains "spawn driver-error: spawn-driver-error row surfaced" "$TR_OUT" "spawn-driver-error"
  assert_contains "spawn driver-error: stderr tail echoed loudly" "$TR_OUT" "auto-spawn plan driver failed"
  assert_contains "spawn driver-error: the actual poison message is visible" "$TR_OUT" "zzz-test poison"
  assert_eq "spawn driver-error: zero herdr side-effect calls" "0" "$(wc -l < "$call_log" | tr -d ' ')"
  assert_eq "spawn driver-error: no intent appended" \
    "0" "$(grep -c '^EVENT spawn_intent' "$repo/.pm/events.log")"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 53b. Registry drift through the spawn surface path: an unregistered
# reason forced through _sp_surface must crash the driver into the
# spawn-driver-error degrade (never render an unregistered token).
section_spawn_unregistered_reason() {
  local repo call_log
  repo="$(new_tmp_repo_spawn true 2 1)"
  seed_automation_dispatch "$repo" D-751 I-751 widget
  seed_spawn_intent "$repo" D-751 A-01 i751-widget-D751A01
  sed -i 's/_sp_surface(_sp_d, "suspected-orphan-intent", _sp_detail)/_sp_surface(_sp_d, "zzz-unregistered-reason", _sp_detail)/' \
    "$repo/bin/_track_spawn"
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" run_track "$repo" "$(spawn_snapshot_json)"
  assert_eq "spawn unregistered-reason: exit 0" "0" "$TR_RC"
  assert_contains "spawn unregistered-reason: degraded to spawn-driver-error" \
    "$TR_OUT" "spawn-driver-error"
  assert_contains "spawn unregistered-reason: names the drift" "$TR_OUT" "unregistered reason"
  assert_eq "spawn unregistered-reason: zero herdr side-effect calls" \
    "0" "$(wc -l < "$call_log" | tr -d ' ')"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 53c. Static registry check: every reason literal the BASH side of the
# spawn stage (_track_spawn) emits (not covered by the python-side runtime
# check) is a member of the REASONS frozenset (in _track_autoclose, in
# scope at every spawn-stage call site via the composed _TR_CLOSE_PY).
section_spawn_reason_literals_registered() {
  local reasons_block r
  reasons_block="$(sed -n '/^REASONS = frozenset({/,/^})/p' "$TRACK_AUTOCLOSE")"
  for r in raced-refused lease-held-elsewhere herdr-tab-create-failed \
    herdr-start-failed capacity-exceeded prompt-sha-mismatch \
    spawn-driver-error spawn-ack-unconfirmed; do
    if [[ "$reasons_block" == *"\"$r\""* ]]; then
      ok "spawn registry: bash-emitted reason '$r' is registered in REASONS"
    else
      fail "spawn registry: bash-emitted reason '$r' is registered in REASONS" "missing from REASONS"
    fi
  done
}

# 54. Prompt binding failures: (a) durable prompt deleted -> unreadable
# surface, no spawn; (b) automation dispatch with NO folded note binding ->
# "no folded prompt binding" surface, no spawn.
section_spawn_prompt_binding_failures() {
  local repo call_log
  repo="$(new_tmp_repo_spawn true 5 5)"
  # (a) deleted durable prompt
  seed_automation_dispatch "$repo" D-761 I-761 widget
  rm -f "$repo/prompts/I-761_widget_2026-07-25.md"
  # (b) no note binding at all (seeded via pm_apply, not dispatch-prep)
  seed_issue_state "$repo" I-762 OPEN ACTIVE
  PM_ROOT="$repo" pm_apply dispatch_new d=D-762 i=I-762 at="$(now_iso)" >/dev/null
  PM_ROOT="$repo" pm_apply dispatch_state d=D-762 from=READY to=DISPATCHED lane=automation \
    at="$(now_iso)" tab="?" prompt_sha=deadbeef >/dev/null
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" run_track "$repo" "$(spawn_snapshot_json)"
  assert_eq "spawn binding-failures: exit 0" "0" "$TR_RC"
  assert_contains "spawn binding-failures: deleted prompt surfaces unreadable" \
    "$TR_OUT" "unreadable"
  assert_contains "spawn binding-failures: missing note binding surfaces" \
    "$TR_OUT" "no folded prompt binding"
  assert_eq "spawn binding-failures: zero herdr side-effect calls" \
    "0" "$(wc -l < "$call_log" | tr -d ' ')"
  assert_eq "spawn binding-failures: no intents appended" \
    "0" "$(grep -c '^EVENT spawn_intent' "$repo/.pm/events.log")"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 55. Corrupt age file fails TOWARD surfacing: garbage in the advisory file
# + an open intent -> orphan surfaces immediately (never indefinitely
# suppressed by re-wiping the counter).
section_spawn_age_file_corrupt() {
  local repo
  repo="$(new_tmp_repo_spawn true 2 5)"
  seed_automation_dispatch "$repo" D-771 I-771 widget
  seed_spawn_intent "$repo" D-771 A-01 i771-widget-D771A01
  printf 'not json at all' >"$repo/.pm/spawn-intent-age.json"

  run_track "$repo" "$(spawn_snapshot_json)"
  assert_eq "spawn age-corrupt: exit 0" "0" "$TR_RC"
  assert_contains "spawn age-corrupt: orphan surfaces IMMEDIATELY despite timeout=5" \
    "$TR_OUT" "suspected-orphan-intent"
  assert_contains "spawn age-corrupt: row explains the corrupt counter" \
    "$TR_OUT" "age counter file was corrupt"
  assert_eq "spawn age-corrupt: dispatch never auto-abandoned" \
    "DISPATCHED" "$(sp_idx "$repo" "d['dispatches']['D-771']['state']")"

  rm -rf "$repo"
}

# 56. auto_spawn=true with an EMPTY herdr_workspace -> spawn-config-invalid
# (pane joins/capacity would run cross-workspace otherwise).
section_spawn_requires_workspace() {
  local repo call_log
  repo="$(new_tmp_repo_spawn true 2 5)"
  # seed FIRST (dispatch-prep itself requires a configured herdr_workspace),
  # then blank the workspace to exercise track's config verdict.
  seed_automation_dispatch "$repo" D-781 I-781 widget
  cat >"$repo/.pm/config.json" <<'JSON'
{"repos": {}, "herdr_workspace": "", "automation": {"auto_close": false, "auto_spawn": true, "max_live_workers": 2, "spawn_ack_timeout_ticks": 5, "spawn_argv": ["zzz-test-runner", "{prompt}"]}}
JSON
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" run_track "$repo" "$(spawn_snapshot_json)"
  assert_eq "spawn requires-ws: exit 0" "0" "$TR_RC"
  assert_contains "spawn requires-ws: spawn-config-invalid surfaced" "$TR_OUT" "spawn-config-invalid"
  assert_contains "spawn requires-ws: detail names herdr_workspace" "$TR_OUT" "herdr_workspace"
  assert_eq "spawn requires-ws: zero herdr side-effect calls" "0" "$(wc -l < "$call_log" | tr -d ' ')"
  assert_eq "spawn requires-ws: no intent appended" \
    "0" "$(grep -c '^EVENT spawn_intent' "$repo/.pm/events.log")"

  rm -f "$call_log"
  rm -rf "$repo"
}

# 57. Paste-injection guard: a hostile snapshot tab_id must never ride
# into the copy-pasteable confirm command of a spawn-ack-unconfirmed row.
section_spawn_ack_unconfirmed_hostile_id() {
  local repo panes
  repo="$(new_tmp_repo_spawn true 2 5)"
  seed_automation_dispatch "$repo" D-341 I-341 widget
  seed_spawn_intent "$repo" D-341 A-01 i341-widget-D341A01
  # hostile tab_id: shell metacharacters that would execute on paste
  panes='[{"name": "i341-widget-D341A01", "pane_id": "zzz-test-ws:p7", "tab_id": "zzz-evil;touch /tmp/pwned", "workspace_id": "zzz-test-ws"}]'

  run_track "$repo" "$(spawn_snapshot_json "$panes")"
  assert_eq "spawn hostile-id: exit 0" "0" "$TR_RC"
  assert_contains "spawn hostile-id: still surfaced spawn-ack-unconfirmed" \
    "$TR_OUT" "spawn-ack-unconfirmed"
  assert_contains "spawn hostile-id: row says the charset check failed" \
    "$TR_OUT" "charset check"
  if [[ "$TR_OUT" == *"bin/record dispatch D-341 ACKED"* ]]; then
    fail "spawn hostile-id: NO ready-to-paste command in the row" "command text present"
  else
    ok "spawn hostile-id: NO ready-to-paste command in the row"
  fi
  if [[ "$TR_OUT" == *"--tab zzz-evil"* ]]; then
    fail "spawn hostile-id: hostile id absent from the command position" "hostile id embedded after --tab"
  else
    ok "spawn hostile-id: hostile id absent from the command position"
  fi
  assert_eq "spawn hostile-id: dispatch NOT acked" \
    "DISPATCHED" "$(sp_idx "$repo" "d['dispatches']['D-341']['state']")"

  rm -rf "$repo"
}

# 58. Superseded dispatch with an open durable intent: the spawn stage must
# neither surface nor ACK it (human adjudication owns superseded work), and
# reconcile's unregistered_execution path must independently discover the
# live worker tab -- the backstop that makes the exclusion safe.
section_spawn_superseded_open_intent() {
  local repo call_log panes
  repo="$(new_tmp_repo_spawn true 2 1)"
  # DELIBERATELY no issue_state seed: reconcile's ticket-label discovery
  # keys on "no I-### ever logged", which is exactly the shape where the
  # unregistered_execution backstop fires.
  printf 'Automation prompt for D-905 (widget).\n' >"$repo/prompts/I-905_widget_2026-07-25.md"
  PM_ROOT="$repo" "${PM_CREATOR_DIR}/templates/bin/dispatch-prep" \
    --dispatch D-905 --issue I-905 --lane automation \
    --prompt "$repo/prompts/I-905_widget_2026-07-25.md" >/dev/null 2>&1 \
    || { echo "FATAL: superseded-intent fixture prep failed" >&2; exit 1; }
  seed_spawn_intent "$repo" D-905 A-01 i905-widget-D905A01
  # supersede it (registers D-906 READY and marks D-905 superseded)
  PM_ROOT="$repo" pm_apply dispatch_new d=D-906 i=I-905 at="$(now_iso)" supersedes=D-905 >/dev/null
  panes="[$(pane_json i905-widget-D905A01 zzz-test-ws:p9 zzz-test-tab-905)]"
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" run_track "$repo" "$(spawn_snapshot_json "$panes")"
  assert_eq "spawn superseded-intent: exit 0" "0" "$TR_RC"
  if [[ "$TR_OUT" == *"spawn-ack-unconfirmed"* || "$TR_OUT" == *"suspected-orphan-intent"* || "$TR_OUT" == *"ambiguous-spawn-ack"* ]]; then
    fail "spawn superseded-intent: NO Phase A row for a superseded dispatch" "row surfaced"
  else
    ok "spawn superseded-intent: NO Phase A row for a superseded dispatch"
  fi
  assert_eq "spawn superseded-intent: not acked" \
    "0" "$(grep -c 'to=ACKED' "$repo/.pm/events.log")"
  assert_eq "spawn superseded-intent: zero herdr side-effect calls" \
    "0" "$(wc -l < "$call_log" | tr -d ' ')"
  assert_eq "spawn superseded-intent: D-905 still DISPATCHED (human adjudication owns it)" \
    "DISPATCHED" "$(sp_idx "$repo" "d['dispatches']['D-905']['state']")"

  # --- the backstop: reconcile independently discovers the live tab ---
  cp "${PM_CREATOR_DIR}/templates/bin/reconcile" "$repo/bin/reconcile"
  chmod +x "$repo/bin/reconcile"
  local f marker
  for f in WORKTREES LEDGER DISPATCHES QUESTIONS SESSIONS; do
    case "$f" in
      WORKTREES) marker="worktrees" ;;
      LEDGER) marker="ledger-summary" ;;
      DISPATCHES) marker="dispatch-summary" ;;
      QUESTIONS) marker="open-questions" ;;
      SESSIONS) marker="sessions" ;;
    esac
    cat >"$repo/$f.md" <<EOF
# $f

<!-- GENERATED:BEGIN $marker -->
(empty)
<!-- GENERATED:END $marker -->
EOF
  done
  local tabs_fx ws_fx rc_out rc_rc
  tabs_fx="$(mktemp "${TMPDIR:-/tmp}/pm-creator-rc-tabs.XXXXXX")"
  ws_fx="$(mktemp "${TMPDIR:-/tmp}/pm-creator-rc-ws.XXXXXX")"
  printf '{"result": {"tabs": [{"tab_id": "zzz-test-tab-905", "label": "i905-widget", "agent_status": "working", "workspace_id": "zzz-test-ws"}]}}' >"$tabs_fx"
  printf '{"result": {"workspaces": [{"workspace_id": "zzz-test-ws", "label": "zzz-test-ws"}]}}' >"$ws_fx"
  # shellcheck disable=SC2034  # rc_out kept for ad-hoc debugging on failure
  rc_out="$(
    cd "$repo" && \
    HERDR_TABS_FIXTURE="$tabs_fx" HERDR_WS_FIXTURE="$ws_fx" \
    PATH="/usr/bin:/bin" \
    bash -c '
      # shellcheck disable=SC2317,SC2329  # invoked indirectly by bin/reconcile
      herdr() {
        case "$1 $2" in
          "tab list") cat "$HERDR_TABS_FIXTURE" ;;
          "workspace list") cat "$HERDR_WS_FIXTURE" ;;
          *) return 1 ;;
        esac
      }
      export -f herdr
      bash bin/reconcile
    ' 2>&1
  )"
  rc_rc=$?
  assert_eq "spawn superseded-intent: reconcile backstop exits 0" "0" "$rc_rc"
  assert_eq "spawn superseded-intent: reconcile emitted unregistered_execution for the live tab" \
    "1" "$(grep -c '^EVENT unregistered_execution .*ref=zzz-test-tab-905' "$repo/.pm/events.log")"

  rm -f "$call_log" "$tabs_fx" "$ws_fx"
  rm -rf "$repo"
}

# 44. herdr unavailable + auto_spawn on -> spawn stage skips like STAGE 1.
section_spawn_herdr_unavailable() {
  local repo
  repo="$(new_tmp_repo_spawn true 2 1)"
  seed_automation_dispatch "$repo" D-511 I-511 widget

  run_track "$repo"
  assert_eq "spawn herdr-unavailable: exit 0" "0" "$TR_RC"
  assert_eq "spawn herdr-unavailable: no spawn_intent appended" \
    "0" "$(grep -c '^EVENT spawn_intent' "$repo/.pm/events.log")"
  assert_eq "spawn herdr-unavailable: dispatch stays DISPATCHED" \
    "DISPATCHED" "$(sp_idx "$repo" "d['dispatches']['D-511']['state']")"

  rm -rf "$repo"
}

echo "== 30. B3: happy-path auto-spawn (intent -> tab -> start -> same-tick ACK) =="
section_spawn_happy_path
echo "== 30b. B3 fix: herdr_workspace label resolves to an id before spawn =="
section_spawn_workspace_label_resolves_to_id
echo "== 31. B3: auto_spawn disabled -> steady count, zero spawns =="
section_spawn_disabled_steady
echo "== 32. B3: capacity at/over -> steady count, zero spawns =="
section_spawn_capacity
echo "== 33. B3: queue exclusions (NEEDS-USER/BLOCKED/open-question/human-lane/open-intent) =="
section_spawn_queue_exclusions
echo "== 34. B3: prompt-sha mismatch -> surface, no spawn =="
section_spawn_prompt_sha_mismatch
echo "== 35. B3: name collision -> surface, no spawn =="
section_spawn_name_collision
echo "== 36. B3: tab create failure -> surfaced code, durable intent =="
section_spawn_tab_create_failure
echo "== 37. B3: agent start failure -> surfaced code, no ACK =="
section_spawn_agent_start_failure
echo "== 38. B3: crash recovery surfaces spawn-ack-unconfirmed (never auto-acks) =="
section_spawn_recovery_ack
echo "== 38b. B3: single impostor pane cannot buy an ACK =="
section_spawn_recovery_single_impostor
echo "== 39. B3: ambiguous recovery (two same-name panes) =="
section_spawn_recovery_ambiguous
echo "== 40. B3: aged orphan intent -> suspected-orphan-intent (never auto-abandon) =="
section_spawn_orphan_aged
echo "== 41. B3: young orphan intent -> no row yet =="
section_spawn_orphan_young
echo "== 42. B3: TOCTOU race between intent and ACK -> benign surface =="
section_spawn_toctou_race
echo "== 43. B3: runtime-invalid spawn config -> fail-closed skip + row =="
section_spawn_config_invalid
echo "== 44. B3: herdr unavailable -> spawn stage skips =="
section_spawn_herdr_unavailable
echo "== 45. B3: two free slots -> FIFO double spawn =="
section_spawn_fifo_two_slots
echo "== 46. B3 fix: inner per-slot capacity guard (2 slots, 3 queued) =="
section_spawn_inner_capacity
echo "== 47. B3 fix: multi-tick orphan aging at timeout=3 =="
section_spawn_orphan_multitick
echo "== 48. B3 fix: durable under-lock capacity gate vs lying snapshot =="
section_spawn_durable_capacity_gate
echo "== 49. B3 fix: under-lock prompt re-hash (plan->lock tamper) =="
section_spawn_prompt_rehash_under_lock
echo "== 50. B3 fix: stuck intent carries its failure cause into the orphan row =="
section_spawn_stuck_intent_cause
echo "== 51. B3 fix: tab create ok but no tab_id =="
section_spawn_tab_create_no_id
echo "== 52. B3 fix: under-lock re-check refusal (zero herdr calls) =="
section_spawn_underlock_recheck_refusal
echo "== 53. B3 fix: plan-driver crash -> loud spawn-driver-error degrade =="
section_spawn_driver_error
echo "== 53b. B3 fix: unregistered reason through the surface path degrades loudly =="
section_spawn_unregistered_reason
echo "== 53c. B3 fix: bash-emitted reason literals are REASONS members (static) =="
section_spawn_reason_literals_registered
echo "== 54. B3 fix: prompt binding failures (deleted copy / no note binding) =="
section_spawn_prompt_binding_failures
echo "== 55. B3 fix: corrupt age file fails toward surfacing =="
section_spawn_age_file_corrupt
echo "== 56. B3 fix: auto_spawn requires a non-empty herdr_workspace =="
section_spawn_requires_workspace
echo "== 57. B3 fix: hostile snapshot id withheld from the paste command =="
section_spawn_ack_unconfirmed_hostile_id
echo "== 58. B3 fix: superseded open intent excluded + reconcile backstop =="
section_spawn_superseded_open_intent

# ---------------------------------------------------------------------------
# 59. C6: SIGTERM delivered mid-tick must TERMINATE track (cleanup, then die
# with 128+SIGTERM), never let it continue into later stages. The shadow
# herdr's `api snapshot` blocks (marker + sleep) so the signal lands while
# track is deterministically inside its tick; a pre-C6 track would run the
# trap, CONTINUE, render TRACKER.md and exit 0. SIGINT shares the identical
# handler shape but cannot be delivered to a background child of a
# non-interactive shell (POSIX starts those with SIGINT ignored).
# ---------------------------------------------------------------------------
section_sigterm_mid_tick_terminates() {
  local repo tp rc i
  repo="$(new_tmp_repo)"
  # Backgrounded wrapper `exec`s track, so $! IS track's PID and the
  # signal reaches the process that owns the traps. Shadow herdr only;
  # zzz-test workspace; never the real binary.
  # shellcheck disable=SC2016
  PATH="/usr/bin:/bin" bash -c '
    cd "$1" || exit 9
    # shellcheck disable=SC2317,SC2329  # invoked indirectly by bin/track
    herdr() {
      if [[ "$1 $2" == "api snapshot" ]]; then
        touch .zzz-snapshot-called
        sleep 2
        printf "{}\n"
        return 0
      fi
      return 1
    }
    export -f herdr
    exec bash bin/track --once
  ' _ "$repo" >/dev/null 2>&1 &
  tp=$!
  i=0
  while [[ ! -e "$repo/.zzz-snapshot-called" ]]; do
    i=$((i + 1)); [[ "$i" -ge 50 ]] && break; sleep 0.1
  done
  assert_true "sigterm mid-tick: track observably reached the herdr snapshot" \
    bash -c '[[ "$1" -lt 50 ]]' _ "$i"
  kill -TERM "$tp" 2>/dev/null || true
  wait "$tp"
  rc=$?
  assert_eq "sigterm mid-tick: track dies with 128+SIGTERM (143), not a completed tick" \
    "143" "$rc"
  assert_true "sigterm mid-tick: later stages never ran (TRACKER.md untouched)" \
    grep -q "no track ticks recorded yet" "$repo/TRACKER.md"
  rm -rf "$repo"
}

echo "== 59. C6: SIGTERM mid-tick terminates track =="
section_sigterm_mid_tick_terminates

# ---------------------------------------------------------------------------
# 60. C8: a symlink planted at the spawn-intent-age *.tmp* name (not the
# destination itself -- that's already guarded) must not turn the advisory
# age-file write into an arbitrary-file clobber. Exercises
# _tr_sp_write_age_from_plan via the ordinary happy-path spawn tick, which
# always calls it once a plan actually "ran".
# ---------------------------------------------------------------------------
section_spawn_age_write_symlink_tmp_refused() {
  local repo call_log victim
  repo="$(new_tmp_repo_spawn true 2 1)"
  seed_automation_dispatch "$repo" D-901 I-901 widget
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"
  victim="$(mktemp "${TMPDIR:-/tmp}/pm-creator-victim.XXXXXX")"
  printf 'victim-original-content\n' >"$victim"
  ln -s "$victim" "$repo/.pm/spawn-intent-age.json.tmp"

  HERDR_CALL_LOG="$call_log" run_track "$repo" "$(spawn_snapshot_json)"
  assert_eq "spawn age symlink-tmp: exit 0 (advisory write failure never gates the tick)" \
    "0" "$TR_RC"
  assert_eq "spawn age symlink-tmp: spawn itself still happened (advisory-only)" \
    "1" "$(grep -c '^EVENT spawn_intent d=D-901 ' "$repo/.pm/events.log")"
  assert_eq "spawn age symlink-tmp: victim file untouched" \
    "victim-original-content" "$(cat "$victim")"
  assert_true "spawn age symlink-tmp: the planted symlink itself was never followed/replaced" \
    bash -c 'test -L "$1" && [[ "$(readlink "$1")" == "$2" ]]' \
    _ "$repo/.pm/spawn-intent-age.json.tmp" "$victim"

  rm -f "$call_log" "$victim"
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# 61. C8: same symlink-at-tmp-name attack against _tr_sp_note_cause, driven
# via the tab-create-failure spawn scenario (the one real call site that
# calls it with the age file already possibly pre-existing).
# ---------------------------------------------------------------------------
section_spawn_note_cause_symlink_tmp_refused() {
  local repo call_log victim
  repo="$(new_tmp_repo_spawn true 2 5)"
  seed_automation_dispatch "$repo" D-902 I-902 widget
  victim="$(mktemp "${TMPDIR:-/tmp}/pm-creator-victim.XXXXXX")"
  printf 'victim-original-content\n' >"$victim"
  ln -s "$victim" "$repo/.pm/spawn-intent-age.json.tmp"
  call_log="$(mktemp "${TMPDIR:-/tmp}/pm-creator-spawn-calls.XXXXXX")"

  HERDR_CALL_LOG="$call_log" HERDR_TAB_CREATE_MODE=fail run_track "$repo" "$(spawn_snapshot_json)"
  assert_eq "note-cause symlink-tmp: exit 0 (advisory write failure never gates the tick)" \
    "0" "$TR_RC"
  assert_contains "note-cause symlink-tmp: herdr-tab-create-failed still surfaced" \
    "$TR_OUT" "herdr-tab-create-failed"
  assert_eq "note-cause symlink-tmp: victim file untouched" \
    "victim-original-content" "$(cat "$victim")"
  assert_true "note-cause symlink-tmp: the planted symlink itself was never followed/replaced" \
    bash -c 'test -L "$1" && [[ "$(readlink "$1")" == "$2" ]]' \
    _ "$repo/.pm/spawn-intent-age.json.tmp" "$victim"

  rm -f "$call_log" "$victim"
  rm -rf "$repo"
}

echo "== 60. C8: symlink-planted spawn-age .tmp write is refused, not followed =="
section_spawn_age_write_symlink_tmp_refused
echo "== 61. C8: symlink-planted note-cause .tmp write is refused, not followed =="
section_spawn_note_cause_symlink_tmp_refused

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
