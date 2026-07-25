#!/usr/bin/env bash
# Test harness for templates/bin/reconcile.
#
# Run: bash test/reconcile_test.sh
# Exits non-zero if any assertion fails; prints PASS/FAIL summary.
# shellcheck disable=SC2016  # intentional: $1 refers to the nested `bash -c`'s own arg
set -u

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PM_CREATOR_DIR="$(cd "${THIS_DIR}/.." && pwd)"
LIB="${PM_CREATOR_DIR}/templates/bin/_lib.sh"
RECONCILE="${PM_CREATOR_DIR}/templates/bin/reconcile"

# shellcheck source=../templates/bin/_lib.sh
# shellcheck disable=SC1091
source "${LIB}"

PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=()

ok() {
  local name="$1"
  PASS=$((PASS + 1))
  printf 'ok %s\n' "$name"
}

fail() {
  local name="$1"
  shift
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("$name")
  printf 'FAIL %s -- %s\n' "$name" "$*"
}

# I20: a section that cannot run in this environment must be COUNTED, not
# silently returned out of -- a vanished section otherwise shrinks the
# assertion total while the suite still exits 0.
skip() {
  local name="$1"
  shift
  SKIP=$((SKIP + 1))
  printf 'skip %s -- %s\n' "$name" "$*"
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

# ---------------------------------------------------------------------------
# GENERATED-marker registry file bodies (mirror the real .tmpl files, but
# with the WORKTREES.md marker already materialized -- scaffolding, which
# would perform the {{PER_REPO_WORKTREE_BLOCKS}} -> marker substitution, is
# out of this script's scope).
# ---------------------------------------------------------------------------

write_registry_files() {
  local repo="$1"

  cat > "$repo/WORKTREES.md" <<'EOF'
# WORKTREES — live git state across configured repos

Dispositions: KEEP / LIVE / CLEANUP / DECIDE / DORMANT.

> `bin/reconcile` rebuilds per-repo tables below from live `git worktree list`
> + `pm_git_probe` across configured repos. Hand-typed notes outside markers
> are kept.

<!-- GENERATED:BEGIN worktrees -->
(run bin/reconcile to populate)
<!-- GENERATED:END worktrees -->

---

## Notes (hand-authored, kept across reconcile)

(operator notes go here)
EOF

  cat > "$repo/LEDGER.md" <<'EOF'
# LEDGER — numbered issues (narrative surface)

> This file is the human narrative. Authoritative state is `.pm/events.log`.

<!-- GENERATED:BEGIN ledger-summary -->
(no issues yet — run bin/reconcile after the first issue is logged)
<!-- GENERATED:END ledger-summary -->

---

## Open

(hand-authored issue prose)
EOF

  cat > "$repo/DISPATCHES.md" <<'EOF'
# DISPATCHES — numbered dispatches (narrative surface)

<!-- GENERATED:BEGIN dispatch-summary -->
(no dispatches yet)
<!-- GENERATED:END dispatch-summary -->

---

## Log (newest first)

(hand-authored dispatch prose)
EOF

  cat > "$repo/QUESTIONS.md" <<'EOF'
# QUESTIONS — numbered Q&A with worker agents

<!-- GENERATED:BEGIN open-questions -->
(none open yet)
<!-- GENERATED:END open-questions -->

---

(hand-authored Q/A prose)
EOF

  cat > "$repo/SESSIONS.md" <<'EOF'
# SESSIONS — herdr session registry

<!-- GENERATED:BEGIN sessions -->
(run bin/reconcile to populate from live herdr state)
<!-- GENERATED:END sessions -->

---

## Notes (hand-authored, kept across reconcile)

(operator notes go here)
EOF
}

# new_tmp_repo: sets up a fresh temp dir with .pm/, bin/, and the registry
# Markdown files (mirrors how a generated repo looks after scaffolding).
new_tmp_repo() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-reconcile-test.XXXXXX")"
  mkdir -p "$d/.pm" "$d/bin"
  cp "$LIB" "$d/bin/_lib.sh"
  cp "${LIB%_lib.sh}_close_lib.sh" "$d/bin/_close_lib.sh"
  cp "$RECONCILE" "$d/bin/reconcile"
  chmod +x "$d/bin/reconcile"
  write_registry_files "$d"
  echo "$d"
}

# run_reconcile <repo_dir> -- runs bin/reconcile with cwd=<repo_dir>, without
# a real `herdr` on PATH (a minimal PATH excluding it) so the herdr-absent
# path is exercised deterministically in most sections. herdr is mandated by
# design (L3), so a herdr-less run now hard-fails by default -- this harness
# opts every *existing* section into the legacy warn-and-continue behavior via
# PM_RECONCILE_ALLOW_DEGRADED=1 so their exit-0 assertions keep testing what
# they were written to test; the hard-fail-by-default behavior itself gets
# its own dedicated section (section_herdr_unavailable_hard_fails_by_default)
# below, which deliberately does NOT set this override.
run_reconcile() {
  local repo="$1"
  RC_OUT="$(cd "$repo" && PATH="/usr/bin:/bin" PM_RECONCILE_ALLOW_DEGRADED=1 bash bin/reconcile 2>&1)"
  RC_RC=$?
}

# ---------------------------------------------------------------------------
section_empty_but_valid_log() {
  local repo
  repo="$(new_tmp_repo)"
  printf 'EVENT schema v=1\n' > "$repo/.pm/events.log"
  cat > "$repo/.pm/config.json" <<'EOF'
{"repos": {}, "herdr_workspace": ""}
EOF

  run_reconcile "$repo"
  assert_eq "empty-but-valid log: exit 0" "0" "$RC_RC"
  assert_true "empty-but-valid log: renders empty ledger block" \
    bash -c 'grep -q "no issues yet" "$1/LEDGER.md"' _ "$repo"
  assert_true "empty-but-valid log: renders empty dispatch block" \
    bash -c 'grep -q "no dispatches yet" "$1/DISPATCHES.md"' _ "$repo"
  assert_true "empty-but-valid log: renders empty questions block" \
    bash -c 'grep -q "no open questions" "$1/QUESTIONS.md"' _ "$repo"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# Out-of-marker bytes (header prose, hand-authored notes sections) must be
# preserved byte-for-byte across a reconcile run.
section_preserves_bytes_outside_markers() {
  local repo before_ledger after_ledger
  repo="$(new_tmp_repo)"
  printf 'EVENT schema v=1\n' > "$repo/.pm/events.log"
  cat > "$repo/.pm/config.json" <<'EOF'
{"repos": {}, "herdr_workspace": ""}
EOF

  # everything before the BEGIN marker and after the END marker
  before_ledger="$(sed -n '1,/GENERATED:BEGIN ledger-summary/p' "$repo/LEDGER.md")"
  after_ledger="$(sed -n '/GENERATED:END ledger-summary/,$p' "$repo/LEDGER.md")"

  run_reconcile "$repo"
  assert_eq "preserves bytes: exit 0" "0" "$RC_RC"

  local before_ledger2 after_ledger2
  before_ledger2="$(sed -n '1,/GENERATED:BEGIN ledger-summary/p' "$repo/LEDGER.md")"
  after_ledger2="$(sed -n '/GENERATED:END ledger-summary/,$p' "$repo/LEDGER.md")"

  assert_eq "preserves bytes: text before BEGIN marker unchanged" "$before_ledger" "$before_ledger2"
  assert_eq "preserves bytes: text after END marker unchanged" "$after_ledger" "$after_ledger2"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# Idempotency: running twice on an unchanged repo produces no new events and
# byte-identical rendered blocks.
section_idempotent_on_rerun() {
  local repo events_after_1 ledger_after_1 dispatches_after_1
  repo="$(new_tmp_repo)"
  cat > "$repo/.pm/events.log" <<'EOF'
EVENT schema v=1
EVENT issue_state i=I-001 from=OPEN to=ACTIVE at=2026-07-23T18:00:00Z
EVENT dispatch_new d=D-001 i=I-001 at=2026-07-23T18:01:00Z
EVENT dispatch_state d=D-001 a=A-01 from=READY to=DISPATCHED lane=human at=2026-07-23T18:02:00Z tab=? prompt_sha=ab12cd34
EOF
  cat > "$repo/.pm/config.json" <<'EOF'
{"repos": {}, "herdr_workspace": ""}
EOF

  run_reconcile "$repo"
  assert_eq "idempotent: first run exit 0" "0" "$RC_RC"
  events_after_1="$(cat "$repo/.pm/events.log")"
  ledger_after_1="$(cat "$repo/LEDGER.md")"
  dispatches_after_1="$(cat "$repo/DISPATCHES.md")"

  run_reconcile "$repo"
  assert_eq "idempotent: second run exit 0" "0" "$RC_RC"
  assert_eq "idempotent: events.log unchanged after second run" \
    "$events_after_1" "$(cat "$repo/.pm/events.log")"
  assert_eq "idempotent: LEDGER.md byte-identical after second run" \
    "$ledger_after_1" "$(cat "$repo/LEDGER.md")"
  assert_eq "idempotent: DISPATCHES.md byte-identical after second run" \
    "$dispatches_after_1" "$(cat "$repo/DISPATCHES.md")"
  assert_true "idempotent: DISPATCHES.md mentions D-001" \
    bash -c 'grep -q "D-001" "$1/DISPATCHES.md"' _ "$repo"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# An unregistered branch (ticket-shaped name, no matching issue ever logged)
# produces exactly one unregistered_execution event, and a second run does
# not duplicate it.
section_unregistered_branch_emits_once() {
  if ! command -v git >/dev/null 2>&1; then
    skip "section_unregistered_branch_emits_once" "git not available"
    return
  fi
  local gitrepo repo emit_count_1 emit_count_2
  gitrepo="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-reconcile-gitrepo.XXXXXX")"
  (
    cd "$gitrepo" || exit 1
    git init -q -b main
    git config user.email test@example.com
    git config user.name test
    touch a.txt
    git add a.txt
    git commit -qm init
    git branch i099-mystery-work
  )

  repo="$(new_tmp_repo)"
  printf 'EVENT schema v=1\n' > "$repo/.pm/events.log"
  cat > "$repo/.pm/config.json" <<EOF
{"repos": {"MyRepo": {"path": "${gitrepo}", "mainline": "main"}}, "herdr_workspace": ""}
EOF

  # git worktree add so pm_git_probe's `git worktree list` actually surfaces
  # the branch as a worktree entry.
  git -C "$gitrepo" worktree add -q "${gitrepo}-wt" i099-mystery-work >/dev/null

  run_reconcile "$repo"
  assert_eq "unregistered branch: exit 0 (informational, not fatal)" "0" "$RC_RC"
  assert_true "unregistered branch: CONFLICTS mentions it" \
    bash -c '[[ "$1" == *"unregistered execution"*"i099-mystery-work"* ]]' _ "$RC_OUT"

  emit_count_1="$(grep -c "^EVENT unregistered_execution " "$repo/.pm/events.log" || true)"
  assert_eq "unregistered branch: exactly one unregistered_execution event" "1" "$emit_count_1"

  run_reconcile "$repo"
  assert_eq "unregistered branch: second run exit 0" "0" "$RC_RC"
  emit_count_2="$(grep -c "^EVENT unregistered_execution " "$repo/.pm/events.log" || true)"
  assert_eq "unregistered branch: no duplicate emission on second run" "1" "$emit_count_2"

  git -C "$gitrepo" worktree remove --force "${gitrepo}-wt" >/dev/null 2>&1 || true
  rm -rf "$gitrepo" "${gitrepo}-wt" "$repo"
}

# ---------------------------------------------------------------------------
# I5: known_refs/known_question_ids must come from the FOLD (index.json),
# never a second raw scan of events.log. A QUARANTINED line that happens to
# carry ref=<branch> in its raw text (here: a duplicate-`ref=`-key
# unregistered_execution the fold refused) must NOT count as "already
# known" -- the real divergence for that branch still gets emitted.
section_quarantined_ref_does_not_suppress_emission() {
  if ! command -v git >/dev/null 2>&1; then
    skip "section_quarantined_ref_does_not_suppress_emission" "git not available"
    return
  fi
  local gitrepo repo emit_count
  gitrepo="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-reconcile-gitrepo4.XXXXXX")"
  (
    cd "$gitrepo" || exit 1
    git init -q -b main
    git config user.email test@example.com
    git config user.name test
    touch a.txt
    git add a.txt
    git commit -qm init
    git branch i008-y
  )

  repo="$(new_tmp_repo)"
  # Seed a line the fold QUARANTINES (duplicate `ref=` key) whose raw text
  # still carries ref=i008-y -- the exact line a raw-log regex scan would
  # wrongly count into known_refs, suppressing the branch's real divergence.
  cat > "$repo/.pm/events.log" <<'EOF'
EVENT schema v=1
EVENT unregistered_execution at=2026-07-23T18:00:00Z ref=i007-x ref=i008-y
EOF
  cat > "$repo/.pm/config.json" <<EOF
{"repos": {"MyRepo": {"path": "${gitrepo}", "mainline": "main"}}, "herdr_workspace": ""}
EOF
  git -C "$gitrepo" worktree add -q "${gitrepo}-wt" i008-y >/dev/null

  run_reconcile "$repo"
  assert_eq "quarantined-ref: exit 0" "0" "$RC_RC"
  # The emitted line's shape is `EVENT unregistered_execution at=<iso>
  # ref=i008-y` -- the single-`ref=` anchor cannot match the seeded
  # duplicate-key line.
  emit_count="$(grep -cE '^EVENT unregistered_execution at=[^ ]+ ref=i008-y$' "$repo/.pm/events.log" || true)"
  assert_eq "quarantined-ref: divergence for i008-y still emitted" "1" "$emit_count"
  assert_true "quarantined-ref: CONFLICTS mentions i008-y" \
    bash -c '[[ "$1" == *"unregistered execution"*"i008-y"* ]]' _ "$RC_OUT"

  git -C "$gitrepo" worktree remove --force "${gitrepo}-wt" >/dev/null 2>&1 || true
  rm -rf "$gitrepo" "${gitrepo}-wt" "$repo"
}

# ---------------------------------------------------------------------------
# C7: a git-legal but pm-token-illegal branch name (comma, '=' in the
# ticket-shaped remainder) must not silence reconcile permanently. It gets
# reported as a conflict/surface line only -- never handed to pm_apply --
# and every OTHER discovery in the same run still lands.
section_pm_illegal_branch_does_not_abort_reconcile() {
  if ! command -v git >/dev/null 2>&1; then
    skip "section_pm_illegal_branch_does_not_abort_reconcile" "git not available"
    return
  fi
  local gitrepo repo bad_branch good_branch
  bad_branch="i099-mystery,work=x"
  good_branch="i098-safe-work"
  gitrepo="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-reconcile-gitrepo3.XXXXXX")"
  (
    cd "$gitrepo" || exit 1
    git init -q -b main
    git config user.email test@example.com
    git config user.name test
    touch a.txt
    git add a.txt
    git commit -qm init
    git branch "$bad_branch"
    git branch "$good_branch"
  )

  repo="$(new_tmp_repo)"
  printf 'EVENT schema v=1\n' > "$repo/.pm/events.log"
  cat > "$repo/.pm/config.json" <<EOF
{"repos": {"MyRepo": {"path": "${gitrepo}", "mainline": "main"}}, "herdr_workspace": ""}
EOF

  # git worktree add for both branches so pm_git_probe's `git worktree
  # list` surfaces them.
  git -C "$gitrepo" worktree add -q "${gitrepo}-wt-bad" "$bad_branch" >/dev/null
  git -C "$gitrepo" worktree add -q "${gitrepo}-wt-good" "$good_branch" >/dev/null

  run_reconcile "$repo"
  assert_eq "pm-illegal branch: reconcile completes (does not abort)" "0" "$RC_RC"
  assert_true "pm-illegal branch: surfaced as a conflict/surface line" \
    bash -c '[[ "$1" == *"mystery,work=x"* ]]' _ "$RC_OUT"
  assert_true "pm-illegal branch: no unregistered_execution event for it" \
    bash -c '! grep -q "^EVENT unregistered_execution ref=${2}" "$1/.pm/events.log"' \
    _ "$repo" "$bad_branch"
  assert_true "pm-illegal branch: other discoveries still land (good branch got its event)" \
    bash -c 'grep -q "^EVENT unregistered_execution .*ref=${2}" "$1/.pm/events.log"' \
    _ "$repo" "$good_branch"

  git -C "$gitrepo" worktree remove --force "${gitrepo}-wt-bad" >/dev/null 2>&1 || true
  git -C "$gitrepo" worktree remove --force "${gitrepo}-wt-good" >/dev/null 2>&1 || true
  rm -rf "$gitrepo" "${gitrepo}-wt-bad" "${gitrepo}-wt-good" "$repo"
}

# ---------------------------------------------------------------------------
# WORKTREES.md gets a real per-repo table rendered from pm_git_probe.
section_worktrees_table_rendered() {
  if ! command -v git >/dev/null 2>&1; then
    skip "section_worktrees_table_rendered" "git not available"
    return
  fi
  local gitrepo repo
  gitrepo="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-reconcile-gitrepo2.XXXXXX")"
  (
    cd "$gitrepo" || exit 1
    git init -q -b main
    git config user.email test@example.com
    git config user.name test
    touch a.txt
    git add a.txt
    git commit -qm init
  )

  repo="$(new_tmp_repo)"
  printf 'EVENT schema v=1\n' > "$repo/.pm/events.log"
  cat > "$repo/.pm/config.json" <<EOF
{"repos": {"MyRepo": {"path": "${gitrepo}", "mainline": "main"}}, "herdr_workspace": ""}
EOF

  run_reconcile "$repo"
  assert_eq "worktrees table: exit 0" "0" "$RC_RC"
  assert_true "worktrees table: mentions the repo name" \
    bash -c 'grep -q "MyRepo" "$1/WORKTREES.md"' _ "$repo"
  assert_true "worktrees table: mainline branch is KEEP" \
    bash -c '[[ "$1" == *"| main | no"* ]] || grep -q "| main |" "$2/WORKTREES.md"' _ "" "$repo"
  assert_true "worktrees table: mentions KEEP disposition for main" \
    bash -c 'grep -q "KEEP" "$1/WORKTREES.md"' _ "$repo"

  rm -rf "$gitrepo" "$repo"
}

# ---------------------------------------------------------------------------
# I19: the `herdr worktree list` leg and the LIVE disposition it feeds --
# a worktree whose path a (shadowed) herdr reports with an
# open_workspace_id must render LIVE, while the mainline worktree in the
# same table stays KEEP. Uses the pinned fixture shape
# (test/fixtures/herdr_worktree_list.json; see herdr_README.md).
section_worktree_live_disposition_from_herdr() {
  if ! command -v git >/dev/null 2>&1; then
    skip "section_worktree_live_disposition_from_herdr" "git not available"
    return
  fi
  local gitrepo repo wt fixture_wt fixture_tabs fixture_ws
  gitrepo="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-reconcile-gitrepo5.XXXXXX")"
  (
    cd "$gitrepo" || exit 1
    git init -q -b main
    git config user.email test@example.com
    git config user.name test
    touch a.txt
    git add a.txt
    git commit -qm init
    git branch i042-live-work
  )
  wt="${gitrepo}-wt-live"
  git -C "$gitrepo" worktree add -q "$wt" i042-live-work >/dev/null

  repo="$(new_tmp_repo)"
  printf 'EVENT schema v=1\nEVENT issue_state i=I-042 from=OPEN to=ACTIVE at=2026-07-23T18:00:00Z\n' > "$repo/.pm/events.log"
  cat > "$repo/.pm/config.json" <<EOF
{"repos": {"MyRepo": {"path": "${gitrepo}", "mainline": "main"}}, "herdr_workspace": "zzz-test-ws"}
EOF

  fixture_wt="$(mktemp "${TMPDIR:-/tmp}/pm-creator-herdr-wt.XXXXXX")"
  fixture_tabs="$(mktemp "${TMPDIR:-/tmp}/pm-creator-herdr-tabs-live.XXXXXX")"
  fixture_ws="$(mktemp "${TMPDIR:-/tmp}/pm-creator-herdr-ws-live.XXXXXX")"
  sed -e "s|__WT_PATH__|${wt}|g" "${THIS_DIR}/fixtures/herdr_worktree_list.json" > "$fixture_wt"
  sed -e "s|__LABEL__|zzz-live-tab|g" "${THIS_DIR}/fixtures/herdr_tab_list.json" > "$fixture_tabs"
  cp "${THIS_DIR}/fixtures/herdr_workspace_list.json" "$fixture_ws"

  HERDR_WT_FIXTURE="$fixture_wt" HERDR_TABS_FIXTURE="$fixture_tabs" HERDR_WS_FIXTURE="$fixture_ws"
  export HERDR_WT_FIXTURE HERDR_TABS_FIXTURE HERDR_WS_FIXTURE
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by the nested reconcile process
  herdr() {
    case "$1 $2" in
      "worktree list") cat "$HERDR_WT_FIXTURE" ;;
      "tab list") cat "$HERDR_TABS_FIXTURE" ;;
      "workspace list") cat "$HERDR_WS_FIXTURE" ;;
      *) return 1 ;;
    esac
  }
  export -f herdr

  run_reconcile "$repo"

  unset -f herdr
  unset HERDR_WT_FIXTURE HERDR_TABS_FIXTURE HERDR_WS_FIXTURE

  assert_eq "herdr LIVE: exit 0" "0" "$RC_RC"
  assert_true "herdr LIVE: herdr-reported worktree row is LIVE" \
    bash -c 'grep -E "^\|[^|]*wt-live[^|]*\|" "$1/WORKTREES.md" | grep -q "| LIVE |"' _ "$repo"
  assert_true "herdr LIVE: mainline worktree row stays KEEP (not blanket-LIVE)" \
    bash -c 'grep -E "^\| [^|]+ \| main \|" "$1/WORKTREES.md" | grep -q "| KEEP |"' _ "$repo"

  git -C "$gitrepo" worktree remove --force "$wt" >/dev/null 2>&1 || true
  rm -f "$fixture_wt" "$fixture_tabs" "$fixture_ws"
  rm -rf "$gitrepo" "$wt" "$repo"
}

# ---------------------------------------------------------------------------
# I21 drift check -- OPT-IN, OPERATOR-ONLY: gated behind PM_TEST_REAL_HERDR=1
# (OFF by default; the default suite must NEVER touch a real herdr). When an
# operator deliberately opts in on a box with a live herdr, assert the
# promised key paths of `herdr tab list` / `herdr workspace list` (the
# shapes pinned in test/fixtures/herdr_README.md) still hold. Read-only
# herdr queries; no tab/agent is ever created.
section_real_herdr_contract_opt_in() {
  if [[ "${PM_TEST_REAL_HERDR:-0}" != "1" ]]; then
    skip "section_real_herdr_contract_opt_in" "opt-in only (set PM_TEST_REAL_HERDR=1 on an operator box)"
    return
  fi
  if ! command -v herdr >/dev/null 2>&1; then
    skip "section_real_herdr_contract_opt_in" "PM_TEST_REAL_HERDR=1 but no herdr on PATH"
    return
  fi
  local tabs_raw ws_raw
  tabs_raw="$(herdr tab list 2>/dev/null)"
  assert_eq "real-herdr contract: tab list exits 0" "0" "$?"
  ws_raw="$(herdr workspace list 2>/dev/null)"
  assert_eq "real-herdr contract: workspace list exits 0" "0" "$?"
  assert_true "real-herdr contract: result.tabs[] with tab_id/label/agent_status/workspace_id" \
    python3 -c '
import json, sys
tabs = json.loads(sys.argv[1])["result"]["tabs"]
assert isinstance(tabs, list)
for t in tabs:
    for k in ("tab_id", "label", "agent_status", "workspace_id"):
        assert k in t, f"missing {k}"
' "$tabs_raw"
  assert_true "real-herdr contract: result.workspaces[] with workspace_id/label" \
    python3 -c '
import json, sys
ws = json.loads(sys.argv[1])["result"]["workspaces"]
assert isinstance(ws, list)
for w in ws:
    for k in ("workspace_id", "label"):
        assert k in w, f"missing {k}"
' "$ws_raw"
}

# ---------------------------------------------------------------------------
# A missing GENERATED marker in a target file is a WARN/skip, not a crash.
section_missing_marker_warns_not_fatal() {
  local repo
  repo="$(new_tmp_repo)"
  printf 'EVENT schema v=1\n' > "$repo/.pm/events.log"
  cat > "$repo/.pm/config.json" <<'EOF'
{"repos": {}, "herdr_workspace": ""}
EOF
  # strip the markers from QUESTIONS.md entirely
  cat > "$repo/QUESTIONS.md" <<'EOF'
# QUESTIONS — no markers here at all

(hand-authored, no GENERATED block)
EOF

  run_reconcile "$repo"
  assert_eq "missing marker: still exits 0" "0" "$RC_RC"
  assert_true "missing marker: reports it under CONFLICTS/skip" \
    bash -c '[[ "$1" == *"QUESTIONS.md"*"skipped"* ]]' _ "$RC_OUT"
  assert_true "missing marker: file content otherwise untouched" \
    bash -c 'grep -q "no markers here at all" "$1/QUESTIONS.md"' _ "$repo"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# Markdown-table injection: a branch name containing a literal '|' must not
# corrupt the WORKTREES.md table (extra/broken columns).
section_table_injection_pipe_neutralized() {
  local repo row_count
  repo="$(new_tmp_repo)"
  printf 'EVENT schema v=1\n' > "$repo/.pm/events.log"
  # Not a real path on disk -> takes the "not a git repo" table row, which
  # interpolates `path` directly (avoids also exercising pm_apply's `ref=`
  # token-charset validation, which is a separate, unrelated constraint from
  # markdown-table escaping and does not accept '|' in event field values).
  cat > "$repo/.pm/config.json" <<'EOF'
{"repos": {"Bad|Repo": {"path": "/tmp/does-not-exist-pipe|repo", "mainline": "main"}}, "herdr_workspace": ""}
EOF

  run_reconcile "$repo"
  assert_eq "table injection (pipe): exit 0" "0" "$RC_RC"
  # "\|" escaping is GFM-ambiguous next to other backslashes (M1) -- the
  # HTML entity &#124; is unambiguous regardless of context, so that's what
  # the rendered cell must contain instead of a literal '|' or a "\|".
  assert_true "table injection (pipe): pipe is escaped as &#124; in the rendered cell" \
    bash -c 'grep -qF '\''does-not-exist-pipe&#124;repo'\'' "$1/WORKTREES.md"' _ "$repo"
  assert_true "table injection (pipe): no raw backslash-pipe escaping present" \
    bash -c '! grep -qF '\''does-not-exist-pipe\|repo'\'' "$1/WORKTREES.md"' _ "$repo"
  # exactly one data row expected (header + separator rows excluded) -- an
  # unescaped '|' in the path would fabricate extra columns/rows.
  row_count="$(grep -c '^| /' "$repo/WORKTREES.md")"
  assert_eq "table injection (pipe): no fabricated extra table rows" "1" "$row_count"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# Markdown-table injection: a herdr tab label containing a newline must
# render as a single, well-formed SESSIONS.md table row (newline neutralized
# to a space), not split into broken rows/lines.
section_table_injection_newline_neutralized() {
  local repo fixture_tabs fixture_ws
  repo="$(new_tmp_repo)"
  printf 'EVENT schema v=1\n' > "$repo/.pm/events.log"
  cat > "$repo/.pm/config.json" <<'EOF'
{"repos": {}, "herdr_workspace": "zzz-test-ws"}
EOF

  fixture_tabs="$(mktemp "${TMPDIR:-/tmp}/pm-creator-herdr-tabs.XXXXXX")"
  fixture_ws="$(mktemp "${TMPDIR:-/tmp}/pm-creator-herdr-ws.XXXXXX")"
  cat > "$fixture_tabs" <<'EOF'
{"result": {"tabs": [{"tab_id": "zzz-nl-tab", "label": "q020-line1\nline2", "agent_status": "idle", "workspace_id": "zzz-test-ws"}]}}
EOF
  cat > "$fixture_ws" <<'EOF'
{"result": {"workspaces": [{"workspace_id": "zzz-test-ws", "label": "zzz-test-ws"}]}}
EOF

  # Shadow herdr with a local function (never invokes the real binary) that
  # just cats fixed sentinel fixtures; exported so the nested `bash
  # bin/reconcile` process (run by run_reconcile) sees it too.
  HERDR_TABS_FIXTURE="$fixture_tabs" HERDR_WS_FIXTURE="$fixture_ws"
  export HERDR_TABS_FIXTURE HERDR_WS_FIXTURE
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by the nested reconcile process
  herdr() {
    case "$1 $2" in
      "tab list") cat "$HERDR_TABS_FIXTURE" ;;
      "workspace list") cat "$HERDR_WS_FIXTURE" ;;
      *) return 1 ;;
    esac
  }
  export -f herdr

  run_reconcile "$repo"

  unset -f herdr
  unset HERDR_TABS_FIXTURE HERDR_WS_FIXTURE

  assert_eq "table injection (newline): exit 0" "0" "$RC_RC"
  assert_true "table injection (newline): label rendered on one line, joined with a space" \
    bash -c 'grep -qF "line1 line2" "$1/SESSIONS.md"' _ "$repo"
  assert_true "table injection (newline): no orphaned second half of the label on its own line" \
    bash -c '! grep -qxF "line2" "$1/SESSIONS.md"' _ "$repo"

  rm -f "$fixture_tabs" "$fixture_ws"
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# render_marker must not double backslashes in generated content (a repo
# path or label containing a literal '\' must survive unchanged).
section_render_marker_preserves_backslashes() {
  local repo
  repo="$(new_tmp_repo)"
  printf 'EVENT schema v=1\n' > "$repo/.pm/events.log"
  # NOT a real path on disk -> takes the "not a git repo" row, which
  # interpolates `path` into WORKTREES.md verbatim (through render_marker).
  cat > "$repo/.pm/config.json" <<'EOF'
{"repos": {"BadRepo": {"path": "/tmp/does-not-exist\\config", "mainline": "main"}}, "herdr_workspace": ""}
EOF

  run_reconcile "$repo"
  assert_eq "render_marker backslash: exit 0" "0" "$RC_RC"
  assert_true "render_marker backslash: single backslash preserved, not doubled" \
    bash -c 'grep -qF '\''/tmp/does-not-exist\config'\'' "$1/WORKTREES.md"' _ "$repo"
  assert_true "render_marker backslash: no doubled backslash present" \
    bash -c '! grep -qF '\''\\\\config'\'' "$1/WORKTREES.md"' _ "$repo"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# herdr JSON is read via a file path, not an environment variable, so a
# large payload (well beyond typical env-size limits) still parses instead
# of silently degrading to "herdr unavailable".
section_herdr_large_payload_via_file_not_env() {
  local repo fixture_tabs fixture_ws
  repo="$(new_tmp_repo)"
  printf 'EVENT schema v=1\n' > "$repo/.pm/events.log"
  cat > "$repo/.pm/config.json" <<'EOF'
{"repos": {}, "herdr_workspace": "zzz-test-ws"}
EOF

  fixture_tabs="$(mktemp "${TMPDIR:-/tmp}/pm-creator-herdr-tabs-big.XXXXXX")"
  fixture_ws="$(mktemp "${TMPDIR:-/tmp}/pm-creator-herdr-ws-big.XXXXXX")"
  # ~3MB single label -- comfortably past this system's ARG_MAX (getconf
  # ARG_MAX), which is the ceiling that would silently trip the old
  # env-var-based transport into the "herdr unavailable" degrade path. Built
  # and written entirely inside python (never passed through argv/env) so
  # building the *fixture itself* doesn't trip this same shell-side limit.
  python3 - "$fixture_tabs" <<'PYEOF'
import json
import sys

out_path = sys.argv[1]
big_label = "q099-" + ("x" * 3000000)
with open(out_path, "w") as f:
    json.dump(
        {
            "result": {
                "tabs": [
                    {
                        "tab_id": "zzz-big-tab",
                        "label": big_label,
                        "agent_status": "idle",
                        "workspace_id": "zzz-test-ws",
                    }
                ]
            }
        },
        f,
    )
PYEOF
  cat > "$fixture_ws" <<'EOF'
{"result": {"workspaces": [{"workspace_id": "zzz-test-ws", "label": "zzz-test-ws"}]}}
EOF

  HERDR_TABS_FIXTURE="$fixture_tabs" HERDR_WS_FIXTURE="$fixture_ws"
  export HERDR_TABS_FIXTURE HERDR_WS_FIXTURE
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by the nested reconcile process
  herdr() {
    case "$1 $2" in
      "tab list") cat "$HERDR_TABS_FIXTURE" ;;
      "workspace list") cat "$HERDR_WS_FIXTURE" ;;
      *) return 1 ;;
    esac
  }
  export -f herdr

  run_reconcile "$repo"

  unset -f herdr
  unset HERDR_TABS_FIXTURE HERDR_WS_FIXTURE

  assert_eq "herdr large payload: exit 0" "0" "$RC_RC"
  assert_true "herdr large payload: parsed successfully (tab id present, not degraded)" \
    bash -c 'grep -q "zzz-big-tab" "$1/SESSIONS.md"' _ "$repo"
  assert_true "herdr large payload: did not fall back to unavailable message" \
    bash -c '! grep -q "herdr machine-readable output unavailable" "$1/SESSIONS.md"' _ "$repo"

  rm -f "$fixture_tabs" "$fixture_ws"
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# Concurrent reconciles racing on the same unregistered branch must not
# double-emit unregistered_execution: the read(known refs)->decide->emit
# window is held under one pm_lock, so the second run re-folds/re-reads
# after the first commits and sees the ref as already known.
section_unregistered_race_no_duplicate_under_concurrency() {
  if ! command -v git >/dev/null 2>&1; then
    skip "section_unregistered_race_no_duplicate_under_concurrency" "git not available"
    return
  fi
  local gitrepo repo emit_count rc1 rc2
  gitrepo="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-reconcile-gitrepo4.XXXXXX")"
  (
    cd "$gitrepo" || exit 1
    git init -q -b main
    git config user.email test@example.com
    git config user.name test
    touch a.txt
    git add a.txt
    git commit -qm init
    git branch i088-race-work
  )
  git -C "$gitrepo" worktree add -q "${gitrepo}-wt" i088-race-work >/dev/null

  repo="$(new_tmp_repo)"
  printf 'EVENT schema v=1\n' > "$repo/.pm/events.log"
  cat > "$repo/.pm/config.json" <<EOF
{"repos": {"MyRepo": {"path": "${gitrepo}", "mainline": "main"}}, "herdr_workspace": ""}
EOF

  (cd "$repo" && PATH="/usr/bin:/bin" PM_RECONCILE_ALLOW_DEGRADED=1 bash bin/reconcile >"$repo/.race_out1" 2>&1; echo $? >"$repo/.race_rc1") &
  local pid1=$!
  (cd "$repo" && PATH="/usr/bin:/bin" PM_RECONCILE_ALLOW_DEGRADED=1 bash bin/reconcile >"$repo/.race_out2" 2>&1; echo $? >"$repo/.race_rc2") &
  local pid2=$!
  wait "$pid1" "$pid2"

  rc1="$(cat "$repo/.race_rc1")"
  rc2="$(cat "$repo/.race_rc2")"
  assert_eq "unregistered race: run 1 exit 0" "0" "$rc1"
  assert_eq "unregistered race: run 2 exit 0" "0" "$rc2"

  emit_count="$(grep -c "^EVENT unregistered_execution " "$repo/.pm/events.log" || true)"
  assert_eq "unregistered race: exactly one unregistered_execution event under concurrency" "1" "$emit_count"

  git -C "$gitrepo" worktree remove --force "${gitrepo}-wt" >/dev/null 2>&1 || true
  rm -rf "$gitrepo" "${gitrepo}-wt" "$repo"
}

# ---------------------------------------------------------------------------
# M2: raw HTML embedded in a value that lands in a Markdown table cell must
# render as inert escaped text, not live markup.
section_table_cell_html_escaped() {
  local repo
  repo="$(new_tmp_repo)"
  printf 'EVENT schema v=1\n' > "$repo/.pm/events.log"
  # Not a real path on disk -> takes the "not a git repo" row, which
  # interpolates `path` directly into the WORKTREES.md table cell.
  cat > "$repo/.pm/config.json" <<'EOF'
{"repos": {"HtmlRepo": {"path": "/tmp/does-not-exist-<img src=x onerror=alert(1)>", "mainline": "main"}}, "herdr_workspace": ""}
EOF

  run_reconcile "$repo"
  assert_eq "table cell HTML: exit 0" "0" "$RC_RC"
  # Parens are also backslash-escaped now (inline-Markdown neutralization,
  # since "(" "…" ")" can form a Markdown link target) -- the entities
  # themselves (the property this assertion checks) are unaffected.
  assert_true "table cell HTML: angle brackets escaped to entities" \
    bash -c 'grep -qF "&lt;img src=x onerror=alert\(1\)&gt;" "$1/WORKTREES.md"' _ "$repo"
  assert_true "table cell HTML: raw <img ...> tag not present (would render live)" \
    bash -c '! grep -qF "<img src=x onerror=alert(1)>" "$1/WORKTREES.md"' _ "$repo"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# M3: a repo name injected as a raw Markdown heading (### {name}) must not be
# able to restructure the document (leading '#') or inject new lines/HTML.
# Table-cell escaping (esc_md_cell) is the wrong tool here -- this exercises
# the dedicated esc_md_heading path.
section_heading_injection_neutralized() {
  local repo
  repo="$(new_tmp_repo)"
  printf 'EVENT schema v=1\n' > "$repo/.pm/events.log"
  # Repo name uses "\r" (not "\n") as the injected line-break: the
  # bash<->python repo-list handoff elsewhere in reconcile is itself
  # newline-delimited, so an embedded "\n" would be truncated well before
  # reaching esc_md_heading -- a separate, pre-existing constraint of that
  # unrelated plumbing, not something M3's heading sanitizer needs to (or
  # can) work around. "\r" survives that handoff intact and still exercises
  # esc_md_heading's CR/LF-stripping + leading-"#" escaping.
  cat > "$repo/.pm/config.json" <<'EOF'
{"repos": {"#Evil\rRepo<script>bad</script>": {"path": "/tmp/does-not-exist-heading-inj", "mainline": "main"}}, "herdr_workspace": ""}
EOF

  run_reconcile "$repo"
  assert_eq "heading injection: exit 0" "0" "$RC_RC"
  assert_true "heading injection: leading '#' escaped, cannot restructure heading level" \
    bash -c 'grep -qF "### \#Evil" "$1/WORKTREES.md"' _ "$repo"
  assert_true "heading injection: embedded newline neutralized to a single line" \
    bash -c '[[ "$(grep -c "^### " "$1/WORKTREES.md")" == "1" ]]' _ "$repo"
  assert_true "heading injection: HTML in name escaped, not live" \
    bash -c 'grep -qF "&lt;script&gt;bad&lt;/script&gt;" "$1/WORKTREES.md"' _ "$repo"
  assert_true "heading injection: raw <script> tag not present" \
    bash -c '! grep -qF "<script>bad</script>" "$1/WORKTREES.md"' _ "$repo"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# Low spar finding: esc_md_cell neutralized HTML/pipes/CR-LF but left inline
# Markdown syntax (backtick, *, _, [text](url)) live, so a config/herdr/git-
# derived value containing it would render AS Markdown (e.g. a branch named
# `*hot*` rendering italic) instead of literally. Exercises the table-cell
# path via the same "not a git repo" row used by M2 above.
section_table_cell_inline_markdown_escaped() {
  local repo raw_code esc_code raw_em esc_em raw_link esc_link
  repo="$(new_tmp_repo)"
  # Expected raw/escaped substrings built as data (not interpolated into any
  # bash -c script text) so the literal backtick below is never at risk of
  # being parsed as command substitution.
  raw_code='`code`'
  esc_code='\`code\`'
  raw_em='*bold*'
  esc_em='\*bold\*'
  raw_link='[link](http://evil)'
  esc_link='\[link\]\(http://evil\)'
  printf 'EVENT schema v=1\n' > "$repo/.pm/events.log"
  cat > "$repo/.pm/config.json" <<'EOF'
{"repos": {"MdRepo": {"path": "/tmp/does-not-exist-`code`*bold*[link](http://evil)", "mainline": "main"}}, "herdr_workspace": ""}
EOF

  run_reconcile "$repo"
  assert_eq "table cell inline markdown: exit 0" "0" "$RC_RC"
  assert_true "table cell inline markdown: backtick escaped, no live code span" \
    grep -qF -- "$esc_code" "$repo/WORKTREES.md"
  assert_true "table cell inline markdown: raw backtick code span not present" \
    bash -c '! grep -qF -- "$2" "$1"' _ "$repo/WORKTREES.md" "$raw_code"
  assert_true "table cell inline markdown: asterisks escaped, no live emphasis" \
    grep -qF -- "$esc_em" "$repo/WORKTREES.md"
  assert_true "table cell inline markdown: raw emphasis markers not present" \
    bash -c '! grep -qF -- "$2" "$1"' _ "$repo/WORKTREES.md" "$raw_em"
  assert_true "table cell inline markdown: link syntax escaped, no live link" \
    grep -qF -- "$esc_link" "$repo/WORKTREES.md"
  assert_true "table cell inline markdown: raw link syntax not present" \
    bash -c '! grep -qF -- "$2" "$1"' _ "$repo/WORKTREES.md" "$raw_link"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# Low spar finding (heading path): esc_md_heading has the same gap -- a repo
# name containing backtick/*/[text](url) rendered live inline Markdown in the
# "### {name}" heading instead of literally.
section_heading_inline_markdown_escaped() {
  local repo raw_code esc_code raw_em esc_em raw_link esc_link
  repo="$(new_tmp_repo)"
  raw_code='`code`'
  esc_code='\`code\`'
  raw_em='*bold*'
  esc_em='\*bold\*'
  raw_link='[link](http://evil)'
  esc_link='\[link\]\(http://evil\)'
  printf 'EVENT schema v=1\n' > "$repo/.pm/events.log"
  cat > "$repo/.pm/config.json" <<'EOF'
{"repos": {"Evil`code`*bold*[link](http://evil)Repo": {"path": "/tmp/does-not-exist-heading-md-inj", "mainline": "main"}}, "herdr_workspace": ""}
EOF

  run_reconcile "$repo"
  assert_eq "heading inline markdown: exit 0" "0" "$RC_RC"
  assert_true "heading inline markdown: backtick escaped, no live code span" \
    grep -qF -- "$esc_code" "$repo/WORKTREES.md"
  assert_true "heading inline markdown: raw backtick code span not present" \
    bash -c '! grep -qF -- "$2" "$1"' _ "$repo/WORKTREES.md" "$raw_code"
  assert_true "heading inline markdown: asterisks escaped, no live emphasis" \
    grep -qF -- "$esc_em" "$repo/WORKTREES.md"
  assert_true "heading inline markdown: raw emphasis markers not present" \
    bash -c '! grep -qF -- "$2" "$1"' _ "$repo/WORKTREES.md" "$raw_em"
  assert_true "heading inline markdown: link syntax escaped, no live link" \
    grep -qF -- "$esc_link" "$repo/WORKTREES.md"
  assert_true "heading inline markdown: raw link syntax not present" \
    bash -c '! grep -qF -- "$2" "$1"' _ "$repo/WORKTREES.md" "$raw_link"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# M4: every temp file reconcile creates is registered in the cleanup trap AT
# CREATION time (via _rc_mktemp), so an early exit -- here, the L3 herdr-
# mandated hard failure, which fires after the herdr tabs/workspaces temp
# files already exist -- can never leak one.
section_herdr_tmpfiles_cleaned_on_early_exit() {
  local repo tmp_scratch leftover
  repo="$(new_tmp_repo)"
  printf 'EVENT schema v=1\n' > "$repo/.pm/events.log"
  cat > "$repo/.pm/config.json" <<'EOF'
{"repos": {}, "herdr_workspace": ""}
EOF

  tmp_scratch="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-reconcile-tmpdir-test.XXXXXX")"

  # herdr absent + no --allow-degraded -> hits the L3 hard-fail exit(1) path,
  # which happens AFTER _rc_mktemp already created (and registered) the
  # herdr tabs/workspaces temp files -- exactly the early-exit-between-
  # creation-and-explicit-rm gap M4 closes via the cleanup trap.
  RC_OUT="$(cd "$repo" && PATH="/usr/bin:/bin" TMPDIR="$tmp_scratch" bash bin/reconcile 2>&1)"
  RC_RC=$?

  assert_eq "herdr temp cleanup: early exit is non-zero (hard fail, no --allow-degraded)" "1" "$RC_RC"
  leftover="$(find "$tmp_scratch" -maxdepth 1 -type f -name 'pm-reconcile-*' | wc -l | tr -d ' ')"
  assert_eq "herdr temp cleanup: no leaked pm-reconcile-* temp files after early exit" "0" "$leftover"

  rm -rf "$tmp_scratch" "$repo"
}

# ---------------------------------------------------------------------------
# L3: herdr is mandated by design (file header §5) -- a herdr-unavailable run
# must hard-fail by default, and only degrade (warn + continue) under the
# explicit --allow-degraded flag or PM_RECONCILE_ALLOW_DEGRADED=1 env var.
section_herdr_unavailable_hard_fails_by_default() {
  local repo
  repo="$(new_tmp_repo)"
  printf 'EVENT schema v=1\n' > "$repo/.pm/events.log"
  cat > "$repo/.pm/config.json" <<'EOF'
{"repos": {}, "herdr_workspace": ""}
EOF

  # Default: herdr absent, no opt-out -> hard failure.
  RC_OUT="$(cd "$repo" && PATH="/usr/bin:/bin" bash bin/reconcile 2>&1)"
  RC_RC=$?
  assert_eq "herdr mandated: exit non-zero by default when herdr unavailable" "1" "$RC_RC"
  assert_true "herdr mandated: error message names herdr as mandated" \
    bash -c '[[ "$1" == *"herdr is mandated"* ]]' _ "$RC_OUT"

  # --allow-degraded flag opts back into the legacy warn-and-continue path.
  RC_OUT="$(cd "$repo" && PATH="/usr/bin:/bin" bash bin/reconcile --allow-degraded 2>&1)"
  RC_RC=$?
  assert_eq "herdr mandated: --allow-degraded restores exit 0" "0" "$RC_RC"
  assert_true "herdr mandated: --allow-degraded prints WARN, not ERROR" \
    bash -c '[[ "$1" == *"WARN: herdr"* ]]' _ "$RC_OUT"

  # PM_RECONCILE_ALLOW_DEGRADED=1 env var achieves the same opt-out.
  RC_OUT="$(cd "$repo" && PATH="/usr/bin:/bin" PM_RECONCILE_ALLOW_DEGRADED=1 bash bin/reconcile 2>&1)"
  RC_RC=$?
  assert_eq "herdr mandated: PM_RECONCILE_ALLOW_DEGRADED=1 restores exit 0" "0" "$RC_RC"

  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# A configured herdr_workspace that matches no live herdr workspace is
# interpolated into the SESSIONS.md "no workspace matching" GENERATED line --
# a hostile value (pipe, raw HTML tag, backtick) must render escaped, not as
# live Markdown/HTML.
section_sessions_no_match_herdr_workspace_escaped() {
  local repo fixture_tabs fixture_ws
  repo="$(new_tmp_repo)"
  printf 'EVENT schema v=1\n' > "$repo/.pm/events.log"
  cat > "$repo/.pm/config.json" <<'EOF'
{"repos": {}, "herdr_workspace": "zzz|<b>`tick`"}
EOF

  fixture_tabs="$(mktemp "${TMPDIR:-/tmp}/pm-creator-herdr-tabs-nomatch.XXXXXX")"
  fixture_ws="$(mktemp "${TMPDIR:-/tmp}/pm-creator-herdr-ws-nomatch.XXXXXX")"
  cat > "$fixture_tabs" <<'EOF'
{"result": {"tabs": []}}
EOF
  # herdr IS available, but no workspace matches the configured
  # herdr_workspace value above (this fixture's workspace_id/label differ).
  cat > "$fixture_ws" <<'EOF'
{"result": {"workspaces": [{"workspace_id": "zzz-other-ws", "label": "zzz-other-ws"}]}}
EOF

  HERDR_TABS_FIXTURE="$fixture_tabs" HERDR_WS_FIXTURE="$fixture_ws"
  export HERDR_TABS_FIXTURE HERDR_WS_FIXTURE
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by the nested reconcile process
  herdr() {
    case "$1 $2" in
      "tab list") cat "$HERDR_TABS_FIXTURE" ;;
      "workspace list") cat "$HERDR_WS_FIXTURE" ;;
      *) return 1 ;;
    esac
  }
  export -f herdr

  run_reconcile "$repo"

  unset -f herdr
  unset HERDR_TABS_FIXTURE HERDR_WS_FIXTURE

  assert_eq "sessions no-match herdr_workspace: exit 0" "0" "$RC_RC"
  assert_true "sessions no-match herdr_workspace: pipe escaped as &#124;" \
    bash -c 'grep -qF "zzz&#124;" "$1/SESSIONS.md"' _ "$repo"
  assert_true "sessions no-match herdr_workspace: angle bracket escaped as &lt;" \
    bash -c 'grep -qF "&lt;b&gt;" "$1/SESSIONS.md"' _ "$repo"
  assert_true "sessions no-match herdr_workspace: no raw pipe from the config value present" \
    bash -c '! grep -qF "zzz|<b>" "$1/SESSIONS.md"' _ "$repo"
  assert_true "sessions no-match herdr_workspace: no raw <b> tag present" \
    bash -c '! grep -qF "<b>\`tick\`" "$1/SESSIONS.md"' _ "$repo"

  rm -f "$fixture_tabs" "$fixture_ws"
  rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# The temp-file manifest itself (_rc_tmpmanifest) is created via a plain
# mktemp, outside the _rc_mktemp registration helper -- the cleanup trap must
# be installed BEFORE that mktemp call so the manifest file is covered even
# on an early-exit path, not just the temp files it registers.
section_tmpmanifest_reaped_on_early_exit() {
  local repo tmp_scratch leftover_manifest leftover_any
  repo="$(new_tmp_repo)"
  printf 'EVENT schema v=1\n' > "$repo/.pm/events.log"
  cat > "$repo/.pm/config.json" <<'EOF'
{"repos": {}, "herdr_workspace": ""}
EOF

  tmp_scratch="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-reconcile-manifest-test.XXXXXX")"

  # herdr absent + no --allow-degraded -> L3 hard-fail exit(1), well after the
  # manifest itself has been mktemp'd -- exercises the ordering fix end to
  # end (trap installed before the manifest exists, still reaps it on exit).
  RC_OUT="$(cd "$repo" && PATH="/usr/bin:/bin" TMPDIR="$tmp_scratch" bash bin/reconcile 2>&1)"
  RC_RC=$?

  assert_eq "tmpmanifest reaped: early exit is non-zero (hard fail, no --allow-degraded)" "1" "$RC_RC"
  leftover_manifest="$(find "$tmp_scratch" -maxdepth 1 -type f -name 'pm-reconcile-tmpmanifest.*' | wc -l | tr -d ' ')"
  assert_eq "tmpmanifest reaped: manifest file itself not leaked after early exit" "0" "$leftover_manifest"
  leftover_any="$(find "$tmp_scratch" -maxdepth 1 -type f -name 'pm-reconcile-*' | wc -l | tr -d ' ')"
  assert_eq "tmpmanifest reaped: no leftover pm-reconcile-* temp files at all" "0" "$leftover_any"

  rm -rf "$tmp_scratch" "$repo"
}

# ---------------------------------------------------------------------------
echo "== reconcile: empty-but-valid log =="
section_empty_but_valid_log
echo "== reconcile: preserves bytes outside markers =="
section_preserves_bytes_outside_markers
echo "== reconcile: idempotent on rerun =="
section_idempotent_on_rerun
echo "== reconcile: unregistered branch emits exactly one event, once =="
section_unregistered_branch_emits_once
echo "== reconcile: WORKTREES.md table rendered from pm_git_probe =="
section_worktrees_table_rendered
echo "== reconcile: missing GENERATED marker warns, does not crash =="
section_missing_marker_warns_not_fatal
echo "== reconcile: table injection - pipe in branch name neutralized =="
section_table_injection_pipe_neutralized
echo "== reconcile: table injection - newline in herdr tab label neutralized =="
section_table_injection_newline_neutralized
echo "== reconcile: render_marker preserves literal backslashes =="
section_render_marker_preserves_backslashes
echo "== reconcile: herdr large payload parses via file, not env var =="
section_herdr_large_payload_via_file_not_env
echo "== reconcile: unregistered_execution not duplicated under concurrency =="
section_unregistered_race_no_duplicate_under_concurrency
echo "== reconcile: table cell HTML escaped, not live (M2) =="
section_table_cell_html_escaped
echo "== reconcile: heading injection neutralized (M3) =="
section_heading_injection_neutralized
echo "== reconcile: table cell inline markdown escaped, not live =="
section_table_cell_inline_markdown_escaped
echo "== reconcile: heading inline markdown escaped, not live =="
section_heading_inline_markdown_escaped
echo "== reconcile: herdr temp files cleaned up on early exit (M4) =="
section_herdr_tmpfiles_cleaned_on_early_exit
echo "== reconcile: herdr-unavailable hard-fails by default, degrades via opt-out (L3) =="
section_herdr_unavailable_hard_fails_by_default
echo "== reconcile: SESSIONS.md no-match herdr_workspace value escaped =="
section_sessions_no_match_herdr_workspace_escaped
echo "== reconcile: tmpmanifest itself reaped on early exit (trap-before-mktemp ordering) =="
section_tmpmanifest_reaped_on_early_exit
echo "== reconcile: pm-illegal branch name does not abort reconcile (C7) =="
section_pm_illegal_branch_does_not_abort_reconcile
echo "== reconcile: quarantined ref does not suppress emission (I5) =="
section_quarantined_ref_does_not_suppress_emission
echo "== reconcile: herdr-reported worktree renders LIVE (I19) =="
section_worktree_live_disposition_from_herdr
echo "== reconcile: real-herdr contract (opt-in, PM_TEST_REAL_HERDR=1) =="
section_real_herdr_contract_opt_in

echo
echo "-----------------------------------------"
echo "PASS: $PASS  FAIL: $FAIL  SKIP: $SKIP"
if [[ "$FAIL" -gt 0 ]]; then
  echo "Failed:"
  for n in "${FAILED_NAMES[@]}"; do
    echo "  - $n"
  done
  exit 1
fi
exit 0
