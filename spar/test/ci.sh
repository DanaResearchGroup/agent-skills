#!/usr/bin/env bash
# Tests for spar's repository binding: bin/spar-binding.sh and
# bin/migrate-spar-bindings.sh.
#
# The behaviour under test is "one repository, one identity, from every
# worktree" — so the fixtures build REAL git repositories and REAL linked
# worktrees. A mock would have re-asserted my own assumption about what
# `git rev-parse --git-common-dir` returns, which is precisely the thing that
# has to be checked: it prints a relative `.git` in the main worktree and an
# absolute path in a linked one.
set -uo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BINDING="$SKILL_DIR/bin/spar-binding.sh"
MIGRATE="$SKILL_DIR/bin/migrate-spar-bindings.sh"

PASS=0; FAIL=0
WORK=$(mktemp -d "${TMPDIR:-/tmp}/spar-binding-test-XXXXXX")
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

section() { printf '\n-- %s\n' "$1"; }
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

assert_eq() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}
assert_contains() { # <label> <needle> <haystack>
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "[$2] not found in: $3" ;; esac
}
assert_not_contains() {
  case "$3" in *"$2"*) bad "$1" "[$2] unexpectedly present" ;; *) ok "$1" ;; esac
}

# new_repo <name> -- a real git repo with one commit; echoes its path
new_repo() {
  local p="$WORK/$1"
  mkdir -p "$p"
  git -C "$p" init -q
  git -C "$p" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf '%s' "$p"
}

# new_store <name> [line...] -- a store dir, optionally with a .project
new_store() {
  local p="$WORK/store-$1"; shift
  mkdir -p "$p"
  [ $# -gt 0 ] && printf '%s\n' "$@" > "$p/.project"
  printf '%s' "$p"
}

# run_binding <store> <repo> -- sets RC, OUT, ERRTXT
run_binding() {
  local errf="$WORK/.err"
  OUT=$("$BINDING" "$1" "$2" 2>"$errf"); RC=$?
  ERRTXT=$(cat "$errf")
  return 0
}

# ---------------------------------------------------------------------------
section "the premise: one repository, one identity from every worktree"

repo_a=$(new_repo repo-a)
git -C "$repo_a" worktree add -q "$WORK/repo-a-feature" -b feature
main_id=$(cd "$repo_a" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
wt_id=$(cd "$WORK/repo-a-feature" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
assert_eq "main checkout and linked worktree resolve to one identity" "$main_id" "$wt_id"

# CANARY, not a behaviour assertion. These pin git's own output shape — the
# asymmetry that makes the naive fix wrong. The resolver's correctness is already
# covered by the assertion above, which would still pass if git changed. If only
# these two fail, git changed its contract and the cd + `pwd -P` canonicalisation
# may no longer be needed; that is news worth failing for, not a broken resolver.
assert_eq "CANARY: git prints a RELATIVE common-dir in the main checkout" \
  ".git" "$(cd "$repo_a" && git rev-parse --git-common-dir)"
case "$(cd "$WORK/repo-a-feature" && git rev-parse --git-common-dir)" in
  /*) ok "CANARY: git prints an ABSOLUTE common-dir in a linked worktree" ;;
  *)  bad "CANARY: git prints an ABSOLUTE common-dir in a linked worktree" "got a relative path" ;;
esac

# ---------------------------------------------------------------------------
section "a fresh store records a repository binding"

s=$(new_store fresh)
run_binding "$s" "$repo_a"
assert_eq "exit 0" 0 "$RC"
assert_eq "stdout carries the identity" "repo_id=$main_id" "$OUT"
assert_contains "repo_id written" "repo_id=$main_id" "$(cat "$s/.project")"
assert_contains "repo_root kept for humans" "repo_root=$repo_a" "$(cat "$s/.project")"

# ---------------------------------------------------------------------------
section "THE BUG: sparring from a feature worktree is accepted"

# This is the whole point. Bind from the main checkout, then spar from a linked
# worktree of the same repo — which is what the worktree-per-feature rule makes
# you do, and what used to hard-error.
run_binding "$s" "$WORK/repo-a-feature"
assert_eq "a linked worktree of the bound repo is accepted" 0 "$RC"
assert_eq "and resolves to the same identity" "repo_id=$main_id" "$OUT"

# ...and the binding does NOT accumulate a line per worktree, which is the
# hand-written workaround this replaces.
assert_eq "no second repo_id line was appended" 1 \
  "$(grep -c '^repo_id=' "$s/.project")"

# ---------------------------------------------------------------------------
section "a genuinely different repository is still refused"

repo_b=$(new_repo repo-b)
run_binding "$s" "$repo_b"
assert_eq "exit 1" 1 "$RC"
assert_contains "names the offending repo" "bound to a different repository" "$ERRTXT"
assert_contains "warns off /spar reset" "discards the Codex session" "$ERRTXT"

# ---------------------------------------------------------------------------
section "one arc may span two repositories (multiple repo_id lines)"

b_id=$(cd "$repo_b" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
s2=$(new_store spanning "repo_id=$main_id" "repo_id=$b_id")
run_binding "$s2" "$repo_a"; assert_eq "first repo accepted" 0 "$RC"
run_binding "$s2" "$repo_b"; assert_eq "second repo accepted" 0 "$RC"

# ---------------------------------------------------------------------------
section "only a whole line binds — a note that quotes one does not"

# Not hypothetical: the real stores carry note= lines that quote the binding
# syntax verbatim (the pr-radar store's note embeds "grep -qx repo_root=..."),
# so a substring match would let a comment silently become a binding.
s_note=$(new_store note-mentions-id \
  "repo_id=$b_id" \
  "note=this arc used to live at repo_id=$main_id before the split")
run_binding "$s_note" "$repo_a"
assert_eq "a repo_id quoted inside a note does not bind" 1 "$RC"

# And a longer identity must not be matched by a prefix of itself.
s_pfx=$(new_store prefix-collision "repo_id=$main_id-old")
run_binding "$s_pfx" "$repo_a"
assert_eq "a prefix collision does not bind" 1 "$RC"

# ---------------------------------------------------------------------------
section "legacy repo_root that still exists is upgraded, not refused"

# A store bound the old way, to a live worktree of this repo.
s3=$(new_store legacy-live "repo_root=$WORK/repo-a-feature" "created_at=2026.01.01 00.00.00")
run_binding "$s3" "$repo_a"
assert_eq "exit 0" 0 "$RC"
assert_contains "repo_id appended" "repo_id=$main_id" "$(cat "$s3/.project")"
assert_contains "records why" "migrated_at=" "$(cat "$s3/.project")"
assert_contains "notice on stderr" "upgraded" "$ERRTXT"
assert_contains "legacy line left intact" "repo_root=$WORK/repo-a-feature" "$(cat "$s3/.project")"

# ---------------------------------------------------------------------------
section "a legacy repo_root pointing at a LIVE other repo is refused"

# The one case where the old evidence is still good and says no. The `ARC` store
# bound to RMG-database is a real instance of this.
s4=$(new_store legacy-other "repo_root=$repo_b")
run_binding "$s4" "$repo_a"
assert_eq "exit 1" 1 "$RC"
assert_contains "cites the surviving path as the evidence" "$repo_b" "$ERRTXT"
assert_not_contains "did not adopt" "repo_id=" "$(cat "$s4/.project")"

# ---------------------------------------------------------------------------
section "a legacy repo_root whose path is gone is adopted and recorded"

s5=$(new_store legacy-dead "repo_root=$WORK/pruned-worktree-that-never-existed")
run_binding "$s5" "$repo_a"
assert_eq "exit 0" 0 "$RC"
assert_contains "adopts this repository" "repo_id=$main_id" "$(cat "$s5/.project")"
assert_contains "records the rebind" "rebound_at=" "$(cat "$s5/.project")"
assert_contains "says why" "every recorded repo_root path is gone" "$(cat "$s5/.project")"
assert_contains "NOTICE is loud on stderr" "NOTICE" "$ERRTXT"
assert_contains "tells the operator how to back out" "different slug" "$ERRTXT"

# A second round must be silent — the adoption already happened.
run_binding "$s5" "$repo_a"
assert_eq "second round accepted" 0 "$RC"
assert_not_contains "and prints no further notice" "NOTICE" "$ERRTXT"

# ---------------------------------------------------------------------------
section "a .project with no trailing newline is not mangled"

s6=$(new_store no-newline)
printf 'repo_root=%s' "$WORK/gone" > "$s6/.project"   # deliberately unterminated
run_binding "$s6" "$repo_a"
assert_eq "exit 0" 0 "$RC"
assert_eq "the appended line stands alone" "repo_id=$main_id" \
  "$(grep '^repo_id=' "$s6/.project")"
assert_eq "the original line survives whole" "repo_root=$WORK/gone" \
  "$(grep '^repo_root=' "$s6/.project")"

# ---------------------------------------------------------------------------
section "a plain directory that is not a git repo still binds"

# The 8.2.FormicAcid store sparring an Overleaf folder is a real instance.
plain="$WORK/not-a-repo"; mkdir -p "$plain"
s7=$(new_store plain)
run_binding "$s7" "$plain"
assert_eq "exit 0" 0 "$RC"
assert_eq "identity is the directory itself" "repo_id=$(cd "$plain" && pwd -P)" "$OUT"

# ---------------------------------------------------------------------------
section "the ambient git environment cannot redirect the identity"

# Measured before this guard existed: with GIT_DIR pointing at repo B, resolving
# repo A returned B's identity — so a store silently bound to the wrong project.
for var in GIT_DIR GIT_COMMON_DIR; do
  s_env=$(new_store "env-$var")
  ( export "$var=$repo_b/.git"; "$BINDING" "$s_env" "$repo_a" >"$WORK/.envout" 2>/dev/null )
  assert_eq "$var does not redirect the identity" "repo_id=$main_id" "$(cat "$WORK/.envout")"
done
s_env=$(new_store env-worktree)
( export GIT_WORK_TREE="$repo_b" GIT_DIR="$repo_b/.git"
  "$BINDING" "$s_env" "$repo_a" >"$WORK/.envout" 2>/dev/null )
assert_eq "GIT_WORK_TREE does not redirect the identity" "repo_id=$main_id" "$(cat "$WORK/.envout")"

# ---------------------------------------------------------------------------
section "a checkout git cannot resolve is refused, not guessed"

# A linked worktree whose gitdir is gone. Falling back to "plain directory" here
# would mint the WORKTREE path as the repository identity — the exact confusion
# this whole change exists to remove.
repo_c=$(new_repo repo-c)
git -C "$repo_c" worktree add -q "$WORK/repo-c-broken" -b broken
mv "$repo_c/.git/worktrees" "$WORK/hidden-worktrees"
s_broken=$(new_store broken-worktree)
run_binding "$s_broken" "$WORK/repo-c-broken"
assert_eq "exit 3" 3 "$RC"
assert_contains "says git cannot resolve it" "cannot resolve" "$ERRTXT"
assert_not_contains "did not mint the worktree path" "$WORK/repo-c-broken" "$OUT"
if [ -e "$s_broken/.project" ]; then bad "wrote no .project" "a .project was created"; else ok "wrote no .project"; fi
mv "$WORK/hidden-worktrees" "$repo_c/.git/worktrees"

# ---------------------------------------------------------------------------
section "a legacy path that exists but cannot be resolved is not silence"

# The dangerous middle state. Skipping it let a live broken checkout fall through
# to adoption, announcing that every recorded path was gone while it sat there.
git -C "$repo_c" worktree add -q "$WORK/repo-c-legacy" -b legacy
mv "$repo_c/.git/worktrees" "$WORK/hidden-worktrees"
s_brk=$(new_store legacy-broken "repo_root=$WORK/repo-c-legacy")
run_binding "$s_brk" "$repo_a"
assert_eq "refuses rather than adopting" 3 "$RC"
assert_contains "names the unreadable path" "$WORK/repo-c-legacy" "$ERRTXT"
assert_not_contains "does not claim the path is gone" "is gone" "$ERRTXT"
assert_not_contains "adopted nothing" "repo_id=" "$(cat "$s_brk/.project")"

# Migration must report it too, not fold it into "no surviving path".
adv_brk="$WORK/adv-broken"; mkdir -p "$adv_brk/brk"
printf 'repo_root=%s\n' "$WORK/repo-c-legacy" > "$adv_brk/brk/.project"
out=$("$MIGRATE" "$adv_brk" 2>&1)
assert_contains "migration flags it as BROKEN" "BROKEN   brk" "$out"
assert_not_contains "and not as a dead path" "DEFER    brk" "$out"
mv "$WORK/hidden-worktrees" "$repo_c/.git/worktrees"

# ---------------------------------------------------------------------------
section "legacy paths containing spaces resolve normally"

# Real store: /home/alon/Dropbox/Apps/Overleaf/8.2. Formic Acid
spaced="$WORK/dir with spaces"; mkdir -p "$spaced"
s_sp=$(new_store spaced "repo_root=$spaced")
run_binding "$s_sp" "$spaced"
assert_eq "upgraded, not word-split into a refusal" 0 "$RC"
assert_eq "identity keeps its spaces" "repo_id=$(cd "$spaced" && pwd -P)" "$OUT"

# ---------------------------------------------------------------------------
section "a .project recording no path at all says so"

s_empty=$(new_store no-paths "created_at=2026.01.01 00.00.00")
run_binding "$s_empty" "$repo_a"
assert_eq "adopted" 0 "$RC"
assert_contains "distinguishes it from all-paths-died" "records no repo_root path at all" "$ERRTXT"

# ---------------------------------------------------------------------------
section "repo_id is not authoritative on its own"

# Part-way through migration: repo_id=A was written when the store was sparred
# from A, while a legacy repo_root=B is still on disk and still legitimate.
# Reading only repo_id refused B — a repository the file plainly vouches for.
s_part=$(new_store partial "repo_id=$main_id" "repo_root=$repo_b")
run_binding "$s_part" "$repo_b"
assert_eq "the live legacy repo is accepted" 0 "$RC"
assert_eq "and topped up as a repo_id" 2 "$(grep -c '^repo_id=' "$s_part/.project")"
# Assert WHICH identities, not just how many — a duplicate or a wrong second id
# satisfies a count.
assert_eq "the original identity is intact" 1 "$(grep -cxF "repo_id=$main_id" "$s_part/.project")"
assert_eq "the added identity is repo B's" 1 "$(grep -cxF "repo_id=$b_id" "$s_part/.project")"
run_binding "$s_part" "$repo_a"
assert_eq "the original repo still works" 0 "$RC"

# ---------------------------------------------------------------------------
section "a refusal has no side effects"

s_ref=$(new_store refusal "repo_id=$b_id")
before=$(cat "$s_ref/.project")
run_binding "$s_ref" "$repo_a"
assert_eq "exit 1" 1 "$RC"
assert_eq "stdout is empty" "" "$OUT"
assert_eq ".project is untouched" "$before" "$(cat "$s_ref/.project")"

# ---------------------------------------------------------------------------
section "accepting an already-bound store writes nothing"

s_idem=$(new_store idempotent "repo_id=$main_id" "repo_id=$b_id")
before=$(cat "$s_idem/.project")
run_binding "$s_idem" "$repo_a"
assert_eq "stdout names this repository" "repo_id=$main_id" "$OUT"
assert_eq ".project is untouched" "$before" "$(cat "$s_idem/.project")"

# An upgrade must also settle: the second round appends nothing further.
s_up=$(new_store upgrade-once "repo_root=$repo_a")
run_binding "$s_up" "$repo_a"
run_binding "$s_up" "$repo_a"
assert_eq "upgrade appends exactly one repo_id" 1 "$(grep -c '^repo_id=' "$s_up/.project")"
assert_eq "and exactly one migrated_at" 1 "$(grep -c '^migrated_at=' "$s_up/.project")"

# ---------------------------------------------------------------------------
section "migration: dry run reports without writing"

adv="$WORK/adversarial"; mkdir -p "$adv"
mkdir -p "$adv/live" "$adv/dead" "$adv/done" "$adv/twoworktrees"
printf 'repo_root=%s\n' "$repo_a"                  > "$adv/live/.project"
printf 'repo_root=%s\n' "$WORK/no-such-path"       > "$adv/dead/.project"
printf 'repo_id=%s\n'   "$main_id"                 > "$adv/done/.project"
{ printf 'repo_root=%s\n' "$repo_a"
  printf 'repo_root=%s\n' "$WORK/repo-a-feature"; } > "$adv/twoworktrees/.project"

before=$(cat "$adv/live/.project")
out=$("$MIGRATE" "$adv" 2>&1); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_contains "reports the migratable store" "MIGRATE  live" "$out"
assert_contains "defers the dead one" "DEFER    dead" "$out"
assert_contains "says it is a dry run" "Dry run" "$out"
assert_eq "wrote nothing" "$before" "$(cat "$adv/live/.project")"

# ---------------------------------------------------------------------------
section "migration: --apply writes verified bindings only"

out=$("$MIGRATE" --apply "$adv" 2>&1)
assert_contains "live store migrated" "repo_id=$main_id" "$(cat "$adv/live/.project")"
assert_contains "and says why" "migrated_at=" "$(cat "$adv/live/.project")"
assert_not_contains "dead store untouched" "repo_id=" "$(cat "$adv/dead/.project")"
assert_eq "already-bound store untouched" "repo_id=$main_id" "$(cat "$adv/done/.project")"

# Two worktrees of ONE repo must collapse to ONE identity, not two lines.
assert_eq "two worktrees of one repo dedupe to a single repo_id" 1 \
  "$(grep -c '^repo_id=' "$adv/twoworktrees/.project")"

# Re-running must be a no-op, not a second append.
"$MIGRATE" --apply "$adv" >/dev/null 2>&1
assert_eq "migration is idempotent" 1 "$(grep -c '^repo_id=' "$adv/live/.project")"

# ---------------------------------------------------------------------------
section "migration: tops up a partially-migrated store"

# "has a repo_id" is not "fully migrated" — a live legacy root naming a second
# repository must still be converted, or the runtime refuses it.
mkdir -p "$adv/partial"
{ printf 'repo_id=%s\n' "$main_id"; printf 'repo_root=%s\n' "$repo_b"; } > "$adv/partial/.project"
out=$("$MIGRATE" --apply "$adv" 2>&1)
assert_contains "reports it as migratable" "MIGRATE  partial" "$out"
assert_eq "both identities present" 2 "$(grep -c '^repo_id=' "$adv/partial/.project")"
assert_eq "the pre-existing identity is intact" 1 "$(grep -cxF "repo_id=$main_id" "$adv/partial/.project")"
assert_eq "the added one is repo B's" 1 "$(grep -cxF "repo_id=$b_id" "$adv/partial/.project")"
# ...and a store whose only live root is ALREADY recorded is left alone.
mkdir -p "$adv/complete"
{ printf 'repo_id=%s\n' "$main_id"; printf 'repo_root=%s\n' "$repo_a"; } > "$adv/complete/.project"
before=$(cat "$adv/complete/.project")
"$MIGRATE" --apply "$adv" >/dev/null 2>&1
assert_eq "a fully-migrated store is untouched" "$before" "$(cat "$adv/complete/.project")"

# ---------------------------------------------------------------------------
section "migration: refuses to write into a store a live round holds"

# Both writers do cp -> append -> mv, which `mv` makes atomic only at the final
# replace; interleaving them loses lines. Migration takes the same .lock /spar
# takes, so a run during a live round waits and then skips rather than racing.
mkdir -p "$adv/locked"
printf 'repo_root=%s\n' "$repo_a" > "$adv/locked/.project"
before=$(cat "$adv/locked/.project")
mkdir "$adv/locked/.lock"                       # simulate a round in progress
out=$(SPAR_LOCK_WAIT=1 timeout 60 "$MIGRATE" --apply "$adv" 2>&1)
assert_contains "reports the store as skipped" "SKIP     locked" "$out"
assert_eq "and wrote nothing into it" "$before" "$(cat "$adv/locked/.project")"
rmdir "$adv/locked/.lock"
"$MIGRATE" --apply "$adv" >/dev/null 2>&1
assert_contains "migrates once the lock clears" "repo_id=$main_id" "$(cat "$adv/locked/.project")"
assert_eq "and left no lock behind" 0 "$(find "$adv" -maxdepth 2 -name .lock | wc -l)"

# ---------------------------------------------------------------------------
section "migration: a store spanning two repositories keeps both"

mkdir -p "$adv/spanning"
{ printf 'repo_root=%s\n' "$repo_a"; printf 'repo_root=%s\n' "$repo_b"; } > "$adv/spanning/.project"
"$MIGRATE" --apply "$adv" >/dev/null 2>&1
assert_eq "both repositories recorded" 2 "$(grep -c '^repo_id=' "$adv/spanning/.project")"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
