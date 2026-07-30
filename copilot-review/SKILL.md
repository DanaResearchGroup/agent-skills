---
name: copilot-review
description: Fix a PR's Copilot / GitHub Advanced Security bot review — triage each finding, fix the real ones, then squash each fix into the commit it fixes, rebase onto the base if it has moved, and force-push with lease.
disable-model-invocation: true
---

# copilot-review

Turn a PR's automated bot review into fixes folded cleanly back into history: **target** the PR →
**fetch** the bot comments → **triage** them → fix → **fixup** into the right commits, **rebase**
onto the base if it has moved, and force-push with lease.

## 1. Target the PR

Resolve to exactly one PR before fetching anything. Its state must be OPEN.

`<remote>` below is the canonical remote — whatever `git remote -v` shows, often `official`, **not**
`origin`. Resolve it once and substitute it in every command; many repos have no `origin` at all, so
a copy-pasted `origin/...` fails outright. `BASE` is the PR's `baseRefName` (usually `main`).

- If this session just created or discussed a specific PR, that's the target — confirm its
  number, don't re-derive it.
- Otherwise, read the current branch's PR on the official remote:
  ```bash
  gh repo view --json nameWithOwner -q .nameWithOwner        # → owner/repo
  gh pr view --json number,title,url,state,headRefName,baseRefName
  ```
- If the branch has no PR, or several PRs are plausibly "the relevant one," list candidates and
  **ask the user to pick** — offer the numbered options and let them type a different number:
  ```bash
  gh pr list --state open --json number,title,headRefName,updatedAt,author \
    --template '{{range .}}#{{.number}} {{.title}} ({{.headRefName}}, {{.author.login}}){{"\n"}}{{end}}'
  ```

**Done when:** you hold one confirmed `owner/repo` + PR number + head/base branch, PR open.

## 2. Fetch the latest bot comments

The two sources, matched by author login (case-insensitive), newest review pass only. Copilot
re-reviews on every push, so old comments may be stale — prefer the most recent pass and skip
threads already marked resolved.

```bash
# Inline review comments — where Copilot and the security bot post line-level findings
gh api --paginate repos/OWNER/REPO/pulls/N/comments \
  --jq '.[] | select(.user.login|ascii_downcase|test("copilot|advanced-security|code-scanning"))
        | {login:.user.login, path, line, body, url:.html_url, created:.created_at}'

# Copilot's overall review verdict / summary
gh api --paginate repos/OWNER/REPO/pulls/N/reviews \
  --jq '.[] | select(.user.login|ascii_downcase|test("copilot"))
        | {login:.user.login, state, body, submitted:.submitted_at}'
```

To avoid re-addressing threads already resolved, check thread resolution and keep only unresolved:
```bash
gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){
  pullRequest(number:$n){reviewThreads(first:100){nodes{isResolved
  comments(first:1){nodes{author{login} path body url}}}}}}}' \
  -f o=OWNER -f r=REPO -F n=N \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[]
        | select(.isResolved==false)
        | select(.comments.nodes[0].author.login|ascii_downcase|test("copilot|advanced-security|code-scanning"))'
```

Optionally pull code-scanning alerts scoped to the PR head for security findings not surfaced as
comments: `gh api repos/OWNER/REPO/code-scanning/alerts -f ref=refs/pull/N/head` (needs security read).

**Done when:** every unresolved Copilot/security comment from the latest pass is in hand, each with
its `path`, `line`, and body.

## 3. Triage

Bot comments range from real bugs to noise. Classify **every** fetched comment as **address** or
**skip**, each with a one-line reason — no comment left unaccounted for. Read the cited code before
judging; don't trust the comment's framing.

- **Address**: real correctness/security bugs, resource leaks, missing error handling, genuine
  edge cases the diff introduced.
- **Skip**: stylistic nits already consistent with the codebase, false positives (the concern
  doesn't hold when you read the surrounding code — record as skipped, don't reshape code to silence
  them), suggestions that fight an existing project convention, or findings on code the PR didn't touch.

Present the triage table (comment → address/skip → reason) and the fixup plan (which fix squashes
into which commit) and get the user's go-ahead before rewriting history — per the repo's git-history
rule, history rewrites and force-pushes need approval.

**Done when:** every comment is classified with a reason and the user has approved the plan.

## 4. Fix

Make the code changes for each **address** item. Run the repo's tests/linters if the change is
non-trivial and they're quick; report honestly if anything fails.

**Writing the fixes is NOT the end state.** Whoever makes the changes carries them all the way
through step 5 in the same session: squash each fix into the commit it fixes, then
`git push --force-with-lease`. Do not stop here and hand back a dirty worktree or a branch of
loose "address review" commits for someone else to fold in — the approval you obtained in step 3
was approval to rewrite history and force-push, so finish the job. If a fix turns out to be
blocked, squash and push the ones that aren't and say plainly which you left and why.

**Done when:** every **address**-classified item from step 3 has a corresponding code change (or is
explicitly re-classified as skip with a one-line reason), and any tests/linters you ran are reported.

## 5. Fixup into history, rebase if behind, force-push

Fold each fix into the commit that introduced the reviewed line rather than stacking "address
review" commits — one logical change per commit in the final history. If the base branch has moved
while the PR sat in review, rebase onto it in the same pass, so the whole rewrite costs one
force-push rather than two.

### 5a — Fixup & autosquash

Create one `--fixup` commit per target commit, then autosquash them in.

```bash
git log --oneline $(git merge-base HEAD <remote>/BASE)..HEAD   # find the target commit per fix
git blame -L START,END -- path/to/file                         # confirm which commit owns the line
git add path/to/file && git commit --fixup=TARGET_SHA          # one fixup per target commit
# ...repeat for each fix, then autosquash them in. A no-op sequence editor makes the interactive
# rebase run non-interactively — plain `git rebase --autosquash` (without -i) does NOT squash:
GIT_SEQUENCE_EDITOR=true git rebase -i --autosquash --autostash $(git merge-base HEAD <remote>/BASE)
```

A fix with no natural home (addresses freshly added code with no clear owning commit) can stay a
normal commit — squash only where a target commit clearly owns the line.

### 5b — Rebase onto the base branch if it has moved

Only if the PR is behind its base. Check first and skip this whole sub-step when it is zero —
rebasing a branch that is already current rewrites history for nothing:

```bash
git fetch <remote> --prune
git rev-list --count HEAD..<remote>/BASE      # 0 => already current, skip to 5c
```

Do this **after** 5a, never before: autosquashing first means any conflict is resolved once,
against the final content, instead of once per loose fixup commit.

Clear the same three tripwires the global git rule names before rewriting:

- **No downstream branch** builds on this tip — `git branch --contains HEAD` names only this
  branch. Rebasing a shared base strands every branch below it on dead SHAs.
- **The worktree is clean**, and it is **this branch's own** worktree — never rebase a branch that
  is checked out dirty somewhere else; that is a live session, not debris.
- If the branch is **shared with collaborators**, do not rebase it. Merge `<remote>/BASE` in
  instead, or leave it and say why — a force-push can clobber commits they have already based work on.

```bash
git rebase <remote>/BASE
```

**On conflict:** resolve it, don't paper over it. Use the `resolving-merge-conflicts` skill — the
short version is to read both sides and keep the intent of each, rather than taking whichever side
makes the conflict markers disappear:

```bash
git status --short                 # UU = both modified; resolve each
# ...edit each conflicted file, keeping BOTH sides' intent...
git add <resolved-file>
git rebase --continue              # repeat until the rebase completes
git rebase --abort                 # bail out cleanly; leaves the branch exactly as it was
```

A conflict that you cannot resolve confidently is a stop-and-report, not a guess: `git rebase
--abort` and tell the user which files collided and why. Re-run the repo's tests after a
non-trivial conflict resolution — a clean rebase is not proof the merged logic is right.

### 5c — Verify, then push

Verify the squash landed **before** pushing, then push:

```bash
git log --oneline $(git merge-base HEAD <remote>/BASE)..HEAD   # verify: zero `fixup!` subjects remain
```

**Done when / blocking:** `git log --oneline $(git merge-base HEAD <remote>/BASE)..HEAD` shows ZERO
`fixup!` entries and the expected commit count; only THEN run `git push --force-with-lease`. A stray
`fixup!` commit reaching the remote is the exact failure this skill exists to prevent, so treat this
zero-`fixup!` check as a hard gate, not a formality.

```bash
git push --force-with-lease
```

Use `--force-with-lease` (never bare `--force`) so a concurrent push on the branch aborts you instead
of getting clobbered. If the lease is stale, re-fetch and reconcile — don't override with `--force`.

**Done when:** each fix is squashed into its target commit, the branch sits on top of the current
base (or is explicitly left behind it with a reason), it is force-pushed with lease, and the PR head
reflects the new history. Optionally reply to or resolve the addressed threads and tell the user
which comments were skipped and why.
