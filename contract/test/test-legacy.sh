#!/usr/bin/env bash
# Back-compat with state written before it moved out of the repo: a repo enabled
# by the old marker stays enabled, an old skip stays honoured, a contract in
# flight stays active and closable — and the two ways an in-repo leftover could
# hijack resolution (a stale ACTIVE with no note; a stale pair after migration)
# must not.
. "$(dirname "$0")/lib.sh"
sandbox_new

# 1. enable and skip markers written into .git by the old layout.
: > "$COMMON/contract-enabled"
assert_contains "$(cd "$WT" && "$CONTRACT" status)" "enabled=yes" "a pre-move enable marker still enables the gate"
mkdir -p "$COMMON/contract-skips"
: > "$COMMON/contract-skips/sess-old"
(cd "$WT" && "$CONTRACT" skipped sess-old); rc=$?
assert_eq 0 "$rc" "a pre-move skip marker still unblocks its session"
(cd "$WT" && "$CONTRACT" skipped sess-new); rc=$?
assert_eq 1 "$rc" "an unrelated session is still gated"

# 2. A contract in flight in the old in-worktree home stays active, and close
#    archives it where it already lives rather than stranding it.
mkdir -p "$WT/docs/contracts"
printf 'old-work\n' > "$WT/docs/contracts/ACTIVE"
printf '# Contract — old-work\n\n## Evidence\n' > "$WT/docs/contracts/old-work.md"
out=$(cd "$WT" && "$CONTRACT" status)
assert_contains "$out" "active=old-work"              "a mid-flight in-worktree contract stays active"
assert_contains "$out" "notes=$WT/docs/contracts"     "status names the legacy notes dir it is using"
printf 'ran the verifier\n' >> "$WT/docs/contracts/old-work.md"
(cd "$WT" && "$CONTRACT" close >/dev/null); rc=$?
assert_eq 0 "$rc" "a legacy contract can still be closed where the repo is writable"
assert_file "$WT/docs/contracts/closed/old-work.md" "the legacy note is archived in place"
assert_contains "$(cd "$WT" && "$CONTRACT" status)" "active=none" "closing the legacy contract clears it"

# 3. A stale in-repo ACTIVE whose NOTE is gone must never select the legacy dir.
#    It would send `new` back into the repo — unwritable in a skills tree, which
#    is the deadlock this layout exists to escape.
printf 'vanished\n' > "$WT/docs/contracts/ACTIVE"
out=$(cd "$WT" && "$CONTRACT" status)
assert_contains "$out" "notes=$WSTATE" "an ACTIVE with no note does not select the legacy dir"
assert_contains "$out" "active=none"   "and reads as no active contract"
(cd "$WT" && "$CONTRACT" new fresh >/dev/null); rc=$?
assert_eq 0 "$rc" "new succeeds past a note-less legacy ACTIVE"
assert_file "$WSTATE/fresh.md"                "and writes its note into external state"
assert_no_file "$WT/docs/contracts/fresh.md"  "not into the repo"
assert_file "$WSTATE/.external"               "opening a contract in state pins the worktree there"

# Pinned means pinned: a LIVE in-repo pair written afterwards — a leftover, or a
# stray file in a gitignored dir — must not mask the contract the gate is using.
printf 'zombie\n' > "$WT/docs/contracts/ACTIVE"
printf '# Contract — zombie\n' > "$WT/docs/contracts/zombie.md"
out=$(cd "$WT" && "$CONTRACT" status)
assert_contains "$out" "active=fresh"  "a live in-repo pair does not take over a pinned worktree"
assert_contains "$out" "notes=$WSTATE" "resolution stays external"
printf 'evidence\n' >> "$WSTATE/fresh.md"
(cd "$WT" && "$CONTRACT" close >/dev/null)
rm -rf "$WT/docs/contracts"

# 4. A LIVE in-repo pair wins in a worktree that has never used state — that is
#    the whole point of back-compat — and `migrate` is the way out: it adopts the
#    note into state and pins the worktree there. Run in the MAIN checkout, which
#    the steps above never touched, so nothing has pinned it. The pair lives in
#    the OLDER of the two homes, the one a real mid-flight contract used.
mkdir -p "$REPO/docs/superpowers/contracts"
printf 'old-home\n' > "$REPO/docs/superpowers/contracts/ACTIVE"
printf '# Contract — old-home\n' > "$REPO/docs/superpowers/contracts/old-home.md"
out=$(cd "$REPO" && "$CONTRACT" status)
assert_contains "$out" "active=old-home"                       "a live pair in the older in-repo home is honoured"
assert_contains "$out" "notes=$REPO/docs/superpowers/contracts" "and resolution follows it there"

out=$(cd "$REPO" && "$CONTRACT" migrate); rc=$?
assert_eq 0 "$rc" "migrate succeeds"
assert_contains "$out" "migrated old-home" "migrate names what it moved"
assert_file "$RSTATE/old-home.md"          "the note is now in state"
assert_file "$RSTATE/.external"            "and the worktree is pinned there"
assert_no_file "$REPO/docs/superpowers/contracts/old-home.md" "the in-repo copy is cleaned up where the repo is writable"
out=$(cd "$REPO" && "$CONTRACT" status)
assert_contains "$out" "notes=$RSTATE"  "resolution has moved out of the repo"
assert_contains "$out" "active=old-home" "and the contract is still the active one"
out=$(cd "$REPO" && "$CONTRACT" migrate)
assert_contains "$out" "already pinned" "migrate is idempotent"
(cd "$REPO" && "$CONTRACT" abandon "was never real" >/dev/null); rc=$?
assert_eq 0 "$rc" "the migrated contract can be abandoned from state"
assert_contains "$(cd "$REPO" && "$CONTRACT" status)" "active=none" "and the gate is re-armed"

# 5. Two live in-repo homes at once: picking one by list order would retire the
#    other's contract silently, so migrate must refuse and say which two.
WT2="$SANDBOX/wt2"
git -C "$REPO" worktree add -q "$WT2" -b second-feature
W2STATE="$STATE/worktrees/$(_pathkey "$WT2")"
for home in docs/contracts docs/superpowers/contracts; do
  mkdir -p "$WT2/$home"
  printf 'both\n' > "$WT2/$home/ACTIVE"
  printf '# Contract — both\n' > "$WT2/$home/both.md"
done
out=$(cd "$WT2" && "$CONTRACT" migrate 2>&1); rc=$?
assert_eq 2 "$rc" "migrate refuses while two in-repo homes hold live contracts"
assert_contains "$out" "docs/contracts"             "and names the first"
assert_contains "$out" "docs/superpowers/contracts" "and the second"
assert_no_file "$W2STATE/.external" "nothing is pinned by a refused migrate"

# 6. Migrating onto existing state would destroy it: an ACTIVE already in state
#    belongs to a contract of its own.
rm -rf "$WT2/docs/superpowers"
mkdir -p "$W2STATE"
printf 'already-there\n' > "$W2STATE/ACTIVE"
printf '# Contract — already-there\n' > "$W2STATE/already-there.md"
out=$(cd "$WT2" && "$CONTRACT" migrate 2>&1); rc=$?
assert_eq 2 "$rc" "migrate refuses to overwrite an active contract already in state"
assert_contains "$out" "already names an active contract" "and says why"
assert_contains "$(cat "$W2STATE/already-there.md")" "already-there" "the state-side note is untouched"
assert_contains "$(cat "$WT2/docs/contracts/both.md")" "both" "and so is the in-repo one"

finish
