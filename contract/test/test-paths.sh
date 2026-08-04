#!/usr/bin/env bash
# Path resolution must key the note on the WORKTREE and the markers on the
# SHARED git dir, so enabling a repo once covers all of its worktrees.
. "$(dirname "$0")/lib.sh"
sandbox_new

out=$(cd "$WT" && "$CONTRACT" status)
assert_contains "$out" "wt=$WT"          "worktree root resolves to the worktree, not the main repo"
assert_contains "$out" "common=$COMMON"  "common dir resolves to the shared .git of the main repo"
assert_contains "$out" "enabled=no"      "a fresh repo is not enabled"
assert_contains "$out" "active=none"     "a fresh worktree has no active contract"

# Same shared common dir seen from the MAIN checkout.
out_main=$(cd "$REPO" && "$CONTRACT" status)
assert_contains "$out_main" "common=$COMMON" "main checkout resolves the same shared common dir"
assert_contains "$out_main" "wt=$REPO"       "main checkout resolves its own worktree root"

# Outside a git repo, status must not crash.
out_nogit=$(cd "$SANDBOX" && "$CONTRACT" status 2>&1); rc=$?
assert_eq 0 "$rc" "status outside a git repo exits 0 (fail open)"
assert_contains "$out_nogit" "wt=none" "status outside a git repo reports wt=none"

finish
