---
name: merged
description: Use immediately after a PR is merged - sync local main, prune every fully-merged branch and its worktree, and offer to rebase the remaining open PRs onto the new main.
---

# merged

A PR just merged. Reconcile the local repo with the new `main` and offer the downstream cleanup:
**confirm** the merge → **sync** main → **prune** every merged branch → **rebase** the other open PRs.

**Invoke this yourself the moment a merge is confirmed** — it does not wait to be asked. What keeps
it safe is the tripwires, not who typed the command. The split is by act, not by step number: every
*local* act is recoverable and gates itself — `-d` refuses an unmerged branch, a worktree must be
clean before it is touched, and a dirty or detached worktree is a live session to report, not debris
to collect. The two *outward-facing* acts still stop for the user, and one of them sits inside a
step that is otherwise local: deleting a branch on the shared remote (the "On the remote" half of
step 3) and force-pushing a rebase (step 4).

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

## 3. Prune every merged branch, not just this one

Sweep **all** fully-merged local branches, not only `<headRefName>`. A branch whose own `/merged` run
never happened — the merge landed from the web UI, the session ended first — is invisible debris that
no later run will ever collect unless this step is a sweep. Expect to find some; treat a non-empty list
as normal, not as a sign something went wrong.

```bash
git branch --merged <remote>/main | grep -vE '^\*|^\s*main$'
```

Delete each name that comes back (including `<headRefName>`) once **both** checks pass — its worktree,
if it has one, is clean, and `-d` accepts it. Most branches have no worktree; resolve `<path>` from
`git worktree list` and skip the two worktree lines entirely when the branch isn't listed there:
```bash
git worktree list                  # <path> for <name>, if it has one at all
git -C <path> status --porcelain   # only if it does — must be empty before touching that branch
git worktree remove <path>         # only if it does
git branch -d <name>               # -d refuses an unmerged branch — a safety net, not an obstacle to force past
git worktree prune                 # drop worktree records whose directory is already gone
```
If either check fails, leave that branch and report why — a dirty worktree is a live session, not debris.

**On the remote:** `git fetch --prune` drops the remote-tracking ref only when GitHub deleted the head
branch on merge. Repos without auto-delete-on-merge silently accumulate merged heads, so list them too:
```bash
# anchor the exclusions, or a branch like <remote>/feature/main drops out of the list unnoticed
git branch -r --merged <remote>/main | sed 's|^ *<remote>/||' | grep -vE '^(main|HEAD)\b'
```
That strips the `<remote>/` prefix `git branch -r` prints, leaving the bare `<branch>` that
`git push <remote> --delete <branch>` actually expects. Capture each SHA **before** deleting
(`git rev-parse --short <remote>/<branch>`) — afterwards there's no ref left to resolve.

Each is fully contained in `main`. Skip any with an open PR, then **ask before deleting** — `git push
<remote> --delete <branch>` is outward-facing on a shared repo. It is recoverable (the commits live on
in `main`; `git push <remote> <sha>:refs/heads/<branch>` restores it), so report each SHA you captured.

**Done when:** every fully-merged local branch and its worktree are gone (or explicitly left with a
reason), `git worktree list` shows no stale entries, and merged remote branches are deleted-with-approval
or reported.

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

## 5. Capture what the cycle taught

A merge is the last moment the whole arc is still in context — what the PR set out to do, what
review caught, what turned out to be wrong on the way. Log anything durable that `spar` and
`copilot-review` did not already capture, and correct anything **their** captures got wrong now
that the work has landed.

```bash
~/.claude/skills/bin/skill-learnings-search --limit 5    # what is already there
~/.claude/skills/bin/skill-learnings-log '{"type":"architecture","key":"<kebab-slug>","insight":"...","confidence":8,"source":"observed"}'
```

Read before writing: a near-duplicate under a fresh slug is worse than nothing, because both
survive and neither supersedes the other. Re-logging an existing key supersedes it, so this is
where a learning that proved half-right gets corrected — say what changed and why. Rules:
[`COMPOUNDING.md`](../COMPOUNDING.md).

**Done when:** the arc's durable lessons are logged or explicitly judged already-captured, and any
superseded learning names what changed.
