#!/usr/bin/env bash
# spar-binding.sh — resolve and enforce a sparring store's repository binding.
#
# Usage:  spar-binding.sh <store-dir> [repo-dir]
# Stdout: repo_id=<canonical repository identity>
# Stderr: a human notice when the binding was created, upgraded, or rebound
# Exit:   0 bound, 1 refused (the store belongs to a different repository),
#         2 usage error
#
# WHY THIS EXISTS
#
# The store used to bind to `git rev-parse --show-toplevel` — the WORKTREE path.
# Under the worktree-per-feature rule that path is deleted at every merge, so the
# binding names a directory that no longer exists and the next round hard-errors.
# 26 of 67 stores on this machine reached that state; the `gracie` store carries
# seven hand-written rebinds. A store's identity is its REPOSITORY, not the
# directory a branch happened to be checked out in.
#
# `git rev-parse --git-common-dir` is the same for every worktree of one repo —
# but it prints a RELATIVE `.git` in the main worktree and an absolute path in a
# linked one, so it only canonicalises after cd + `pwd -P`. That asymmetry is the
# whole trap; resolve it once, here.
set -euo pipefail

STORE=${1:-}
REPO=${2:-$PWD}
[ -n "$STORE" ] || { echo "usage: spar-binding.sh <store-dir> [repo-dir]" >&2; exit 2; }
[ -d "$REPO" ] || { echo "spar-binding: no such repo dir: $REPO" >&2; exit 2; }

# KNOWN LIMITS, deliberately not handled:
#   - a repository reachable through two different absolute paths (bind mounts,
#     /home vs /export/home) records two identities. `pwd -P` resolves symlinks,
#     not mounts, and reading /proc/mounts to do better costs more than the case
#     is worth. Add the second `repo_id=` line by hand if it ever happens.
#   - git identities and plain-directory identities share one namespace. A
#     collision needs a non-git path equal to some repo's .git path, which cannot
#     arise from a directory inside a repo (git resolves those) and is otherwise
#     contrived.

# repo_identity <dir> -- canonical identity of the repository containing <dir>,
# or the canonicalised directory itself when it is not a git repository at all
# (spar is used on plain directories too — see the 8.2.FormicAcid store).
#
# The ambient git environment is cleared first. GIT_DIR, GIT_COMMON_DIR and
# GIT_WORK_TREE each make `git rev-parse` describe a DIFFERENT repository than
# the one at <dir> — measured: with GIT_DIR set to repo B, resolving repo A
# returns B's identity, so a store silently binds to the wrong project. The
# discovery vars are cleared for the mirror-image reason: GIT_CEILING_DIRECTORIES
# can make discovery fail from inside a real repository, which would land in the
# plain-directory fallback below.
repo_identity() {
  local d=$1 common
  common=$(cd "$d" 2>/dev/null && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR \
    -u GIT_CEILING_DIRECTORIES -u GIT_DISCOVERY_ACROSS_FILESYSTEM \
    -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
    git rev-parse --git-common-dir 2>/dev/null) || common=""
  if [ -n "$common" ]; then
    (cd "$d" && cd "$common" && pwd -P)
    return 0
  fi
  # Not resolvable as a repository. Distinguish "plain directory" from "git
  # checkout whose gitdir is broken" — a linked worktree whose .git file points
  # at a deleted gitdir resolves to nothing, and silently calling that a plain
  # directory would mint the WORKTREE path as the repository's identity.
  if [ -e "$d/.git" ]; then
    printf 'spar: %s looks like a git checkout (%s exists) but git cannot resolve it.\n' "$d" "$d/.git" >&2
    printf '  Refusing to guess an identity for it — repair the checkout first.\n' >&2
    return 3
  fi
  (cd "$d" && pwd -P)
}

REPO_ID=$(repo_identity "$REPO") || exit 3
CANON_ROOT=$(cd "$REPO" && pwd -P)
META_FILE="$STORE/.project"
NOW=$(date +"%Y.%m.%d %H.%M.%S")

# append_lines <file> <line>... -- append atomically, tolerating a file that
# ends without a newline (hand-edited .project files routinely do).
append_lines() {
  local f=$1; shift
  local tmp="$f.tmp.$$"
  if [ -s "$f" ]; then
    cp "$f" "$tmp"
    [ -n "$(tail -c1 "$tmp")" ] && printf '\n' >> "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s\n' "$@" >> "$tmp"
  mv "$tmp" "$f"
}

# ---- no binding yet: create one ------------------------------------------
if [ ! -f "$META_FILE" ]; then
  mkdir -p "$STORE"
  tmp="$META_FILE.tmp.$$"
  {
    printf 'repo_id=%s\n' "$REPO_ID"
    printf 'repo_root=%s\n' "$CANON_ROOT"
    printf 'created_at=%s\n' "$NOW"
  } > "$tmp" && mv "$tmp" "$META_FILE"
  printf 'repo_id=%s\n' "$REPO_ID"
  exit 0
fi

# ---- gather every identity the file already vouches for --------------------
#
# Two kinds of evidence, and BOTH must be read before deciding. Reading the
# `repo_id=` lines alone was wrong: a store part-way through migration can hold
# `repo_id=A` (written when it was sparred from A) plus a legacy `repo_root=B`
# that is still on disk and still legitimate. Treating repo_id as authoritative
# on its own refused B — a repository the file plainly vouches for. An arc may
# span two repositories (the DanaResearchGroup-agent-skills store is exactly
# that), so any vouched identity matching is a match.
bound_ids=()        # from repo_id= lines — already-migrated bindings
live_ids=()         # from repo_root= paths that still exist
live_roots=()

while IFS= read -r id; do
  [ -n "$id" ] && bound_ids+=("$id")
done < <(sed -n 's/^repo_id=//p' "$META_FILE")

# A dead path proves nothing either way, so it is not evidence of a mismatch.
# A path that EXISTS but cannot be resolved is a third state and must not be
# quietly folded into either: it is evidence that the store belongs to
# something, just not evidence of what. Skipping it let a live broken checkout
# reach the adoption path below, under a message announcing that every recorded
# path was gone while the path was sitting right there.
broken_roots=()
while IFS= read -r root; do
  [ -n "$root" ] || continue
  [ -d "$root" ] || continue
  if ! id=$(repo_identity "$root" 2>/dev/null); then
    broken_roots+=("$root")
    continue
  fi
  live_roots+=("$root")
  live_ids+=("$id")
done < <(sed -n 's/^repo_root=//p' "$META_FILE")

# 1. Already bound to this repository — the common case, writes nothing.
for id in ${bound_ids+"${bound_ids[@]}"}; do
  if [ "$id" = "$REPO_ID" ]; then
    printf 'repo_id=%s\n' "$REPO_ID"
    exit 0
  fi
done

# 2. A surviving legacy path resolves here: record it as a repo_id and accept.
for id in ${live_ids+"${live_ids[@]}"}; do
  if [ "$id" = "$REPO_ID" ]; then
    append_lines "$META_FILE" \
      "repo_id=$REPO_ID" \
      "migrated_at=$NOW reason=legacy repo_root resolved to this repository"
    printf 'spar: upgraded %s to a repository binding (repo_id=%s).\n' "$META_FILE" "$REPO_ID" >&2
    printf 'repo_id=%s\n' "$REPO_ID"
    exit 0
  fi
done

# 3. A recorded path exists but cannot be resolved. Nothing here says the store
#    is this repository's, and the unresolvable path may well name it. Fail
#    closed rather than adopt on the strength of evidence we could not read.
if [ ${#broken_roots[@]} -gt 0 ] && [ ${#bound_ids[@]} -eq 0 ] && [ ${#live_roots[@]} -eq 0 ]; then
  {
    printf 'spar: %s records a path that exists but cannot be resolved:\n' "$STORE"
    for r in "${broken_roots[@]}"; do printf '    %s\n' "$r"; done
    printf '  Refusing rather than adopting this repository: that path may be the\n'
    printf '  store'"'"'s real owner, and a broken checkout is not proof of anything.\n'
    printf '  Repair it, or delete the line if it is genuinely dead.\n'
  } >&2
  exit 3
fi

# 4. The file vouches for some repository, and it is not this one. Refuse.
if [ ${#bound_ids[@]} -gt 0 ] || [ ${#live_roots[@]} -gt 0 ]; then
  {
    printf 'spar: %s is bound to a different repository.\n' "$STORE"
    printf '  this repository: %s\n' "$REPO_ID"
    printf '  bound to:\n'
    for id in ${bound_ids+"${bound_ids[@]}"}; do printf '    %s\n' "$id"; done
    for i in ${live_roots+"${!live_roots[@]}"}; do
      printf '    %s (via the still-existing %s)\n' "${live_ids[$i]}" "${live_roots[$i]}"
    done
    for r in ${broken_roots+"${broken_roots[@]}"}; do
      printf '    (and %s exists but cannot be resolved)\n' "$r"
    done
    printf '  Use a different slug, or add the line "repo_id=%s" to %s if this\n' "$REPO_ID" "$META_FILE"
    printf '  arc really does span both repositories. Do NOT use /spar reset to clear\n'
    printf '  this: it discards the Codex session and the whole sparring arc with it.\n'
  } >&2
  exit 1
fi

# Nothing on disk vouches for any repository, so nothing can say which one this
# arc belonged to. Adopt the current one and RECORD that we did, rather than
# hard-erroring: the operator's own remedy for this has always been to hand-edit
# the file (seven times in the gracie store). The notice below is what makes the
# adoption reviewable — if it is wrong, the round output says so.
#
# Two distinct states land here and the message must not conflate them: every
# recorded path died (the common case, 26 stores), or the file never recorded a
# path at all (malformed or truncated). Same decision, different cause.
if grep -q '^repo_root=' "$META_FILE"; then
  why="every recorded repo_root path is gone"
else
  why="the file records no repo_root path at all"
fi
append_lines "$META_FILE" \
  "repo_id=$REPO_ID" \
  "rebound_at=$NOW reason=$why; adopted the repository sparring from"
{
  printf 'spar: NOTICE — for %s, %s,\n' "$STORE" "$why"
  printf '  so nothing proved which repository it belonged to. Adopted this one and\n'
  printf '  recorded the rebind:\n'
  printf '    repo_id=%s\n' "$REPO_ID"
  printf '  If this arc is not yours, stop and use a different slug — you are about to\n'
  printf '  resume another project'"'"'s Codex review session.\n'
} >&2
printf 'repo_id=%s\n' "$REPO_ID"
exit 0
