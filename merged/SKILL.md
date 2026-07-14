---
name: merged
description: After a PR merges, sync local main, prune the merged branch and its worktree, and offer to rebase the remaining open PRs onto the new main.
disable-model-invocation: true
---

# merged

A PR just merged. Reconcile the local repo with the new `main` and offer the downstream cleanup:
**confirm** the merge → **sync** main → **prune** the merged branch → **rebase** the other open PRs.

Anchor to the PR this session just discussed or merged — don't re-derive it. If none is in hand, ask
which one merged. The canonical remote is whatever `git remote -v` shows (often `official`, not
`origin`) — resolve it once, don't assume.

## 1. Confirm the merge

Resolve to exactly one PR and confirm GitHub reports it MERGED, not merely closed:
```bash
gh pr view N --json number,title,state,headRefName,mergedAt
```
If `state` isn't `MERGED`, stop and report — this skill is for merged PRs only.

**Done when:** one PR confirmed MERGED, with its head branch name in hand.

## 2. Sync main

Fetch with prune, then fast-forward local `main` in the main worktree:
```bash
git fetch <remote> --prune
git merge --ff-only <remote>/main
```
Fast-forward only. If it refuses, local `main` has diverged — stop and report rather than merging or
resetting over it.

**Done when:** `git rev-parse main` equals `git rev-parse <remote>/main`.

## 3. Prune the merged branch

Only after **both** checks pass — the worktree is clean (`git status --porcelain` empty) and the branch
is fully merged (`git branch --merged <remote>/main` lists it):
```bash
git worktree remove <path>    # if the branch lived in its own worktree
git branch -d <headRefName>   # -d refuses an unmerged branch — a safety net, not an obstacle to force past
```
`git fetch --prune` already dropped the remote-tracking ref. If either check fails, leave the branch and
report why — a dirty worktree is a live session, not debris.

**Done when:** the merged branch's worktree and local branch are gone (or explicitly left with a reason),
and `git worktree list` is clean.

## 4. Rebase the other open PRs

List the still-open PRs and find which now sit behind the new main:
```bash
gh pr list --state open --json number,headRefName,mergeStateStatus
```
Every PR reporting `BEHIND` is a rebase candidate. **Suggest them to the user by number and get a
go-ahead before rewriting any history** — this is the skill's one force-push gate.

Before rebasing each approved branch, clear the three tripwires the global git rule names:
- **No downstream branch** builds on its tip — `git branch --contains <tip>` names only the branch
  itself. Rebasing a shared base strands every branch below it onto dead SHAs.
- **Its worktree is clean** — never rebase a branch checked out dirty elsewhere.
- Rebase **in that branch's own worktree**, onto `<remote>/main`, then `git push --force-with-lease`
  (never bare `--force`; if the lease is stale, re-fetch and reconcile).

**Done when:** every `BEHIND` open PR is either rebased-and-force-pushed (no longer BEHIND) or left with
a one-line reason, and each rebase was approved before its force-push.
