#!/usr/bin/env bash
# Path resolution must key the note on the WORKTREE and the markers on the
# SHARED git dir, so enabling a repo once covers all of its worktrees.
. "$(dirname "$0")/lib.sh"
sandbox_new

out=$(cd "$WT" && "$CONTRACT" status)
assert_contains "$out" "wt=$WT"          "worktree root resolves to the worktree, not the main repo"
assert_contains "$out" "common=$COMMON"  "common dir resolves to the shared .git of the main repo"
assert_contains "$out" "state=$STATE"    "repo state resolves under CONTRACT_STATE_DIR, keyed on the shared git dir"
assert_contains "$out" "notes=$WSTATE"   "notes resolve to this worktree's external dir"
assert_contains "$out" "enabled=no"      "a fresh repo is not enabled"
assert_contains "$out" "active=none"     "a fresh worktree has no active contract"

# No state path may point inside the worktree: a repo whose tree is write-denied
# (the skills repo itself) must still be able to open, skip and close.
assert_not_contains "$out" "notes=$WT/"  "notes do not live inside the worktree"
assert_not_contains "$out" "state=$WT/"  "state does not live inside the worktree"
assert_not_contains "$out" "state=$COMMON" "state does not live inside the git dir"

# Same shared common dir seen from the MAIN checkout, and its own notes dir.
out_main=$(cd "$REPO" && "$CONTRACT" status)
assert_contains "$out_main" "common=$COMMON" "main checkout resolves the same shared common dir"
assert_contains "$out_main" "wt=$REPO"       "main checkout resolves its own worktree root"
assert_contains "$out_main" "state=$STATE"   "both worktrees share one repo state dir"
assert_contains "$out_main" "notes=$RSTATE"  "each worktree gets its own notes dir"

# Outside a git repo, status must not crash.
out_nogit=$(cd "$SANDBOX" && "$CONTRACT" status 2>&1); rc=$?
assert_eq 0 "$rc" "status outside a git repo exits 0 (fail open)"
assert_contains "$out_nogit" "wt=none" "status outside a git repo reports wt=none"

finish
