---
name: copilot-review
description: Fix a PR's Copilot / GitHub Advanced Security bot review — triage each finding, fix the real ones, squash each fix into the commit it fixes, rebase onto the base if it has moved, force-push with lease, then reply briefly to the important threads and resolve every one it addressed. Runs start to finish without pausing for confirmation; invoking it is the approval.
disable-model-invocation: true
---

# copilot-review

Turn a PR's automated bot review into fixes folded cleanly back into history: **target** the PR →
**fetch** the bot comments → **triage** them → fix → **fixup** into the right commits, **rebase**
onto the base if it has moved, force-push with lease, then **respond** briefly to the important
threads and **resolve** every one you addressed.

**This runs to completion in one pass.** Being invoked *is* the authorisation to rewrite history
and force-push: every finding you classify as **address** gets fixed, squashed into the commit that
owns it, and pushed, without stopping to confirm. Report the triage table as you go — that is
transparency, not a question. The only things that stop the run are the 5b tripwires (downstream
work, a dirty worktree elsewhere, a branch shared with collaborators) and a conflict you cannot
resolve confidently; those are safety checks, and they stop-and-report rather than ask permission.

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
        | {id, login:.user.login, path, line, body, url:.html_url, created:.created_at}'

# Copilot's overall review verdict / summary
gh api --paginate repos/OWNER/REPO/pulls/N/reviews \
  --jq '.[] | select(.user.login|ascii_downcase|test("copilot"))
        | {login:.user.login, state, body, submitted:.submitted_at}'
```

To avoid re-addressing threads already resolved, check thread resolution and keep only unresolved:
```bash
gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){
  pullRequest(number:$n){reviewThreads(first:100){nodes{id isResolved
  comments(first:1){nodes{author{login} path body url}}}}}}}' \
  -f o=OWNER -f r=REPO -F n=N \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[]
        | select(.isResolved==false)
        | select(.comments.nodes[0].author.login|ascii_downcase|test("copilot|advanced-security|code-scanning"))'
```

This query (and the step-6 listing query) caps at `reviewThreads(first:100)` — fine for almost every
PR, but on one with more than 100 threads paginate with `after:$cursor`/`pageInfo{hasNextPage endCursor}`
or you will silently miss the overflow.

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

Report the triage table (comment → address/skip → reason) and the fixup plan (which fix squashes
into which commit), then **keep going** — do not stop here for a go-ahead. The classification is
yours to make and act on; the table exists so the user can see what you decided and push back
afterwards, not so they can unblock you. A borderline finding is a judgement call to make and
record in the table, not a reason to hand the run back.

**Done when:** every comment is classified with a reason and the table is reported.

## 4. Fix

Make the code changes for each **address** item. Run the repo's tests/linters if the change is
non-trivial and they're quick; report honestly if anything fails.

**Writing the fixes is NOT the end state.** Whoever makes the changes carries them all the way
through step 5 in the same session: squash each fix into the commit it fixes, then
`git push --force-with-lease`. Do not stop here and hand back a dirty worktree or a branch of
loose "address review" commits for someone else to fold in — you already hold the authorisation to
rewrite history and force-push, so finish the job. If a fix turns out to be blocked, squash and
push the ones that aren't and say plainly which you left and why.

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
reflects the new history. Then close the loop on GitHub — step 6.

## 6. Respond and resolve the threads

Once the new history is on the remote, close every thread you addressed on GitHub itself. This is
not optional — a fixed finding left as an open thread reads as ignored, and the next reviewer
re-treads it. Two moves, both on the **addressed** threads only:

- **Reply briefly to the important ones.** For a finding that was a real bug, a security issue, or
  where the fix isn't obvious from the diff, post a one-line reply saying what you changed — e.g.
  "Fixed in `abc1234` — now closes the file handle in a `finally`." Skip the reply for trivial or
  self-evident fixes; a resolved thread with no comment is fine there. Do **not** reply to threads
  you skipped in triage — those get accounted for to the user in the run summary, not argued with on
  the PR.
- **Resolve every addressed thread**, whether or not you replied. Resolution is the signal the
  finding is handled; leave only genuinely-open threads unresolved.

Reply to a review thread's comment (post under the same conversation):

```bash
# COMMENT_ID is the numeric `id` of the bot's inline comment (not the html_url) — step 2's fetch
# already emits it as `.id`.
gh api repos/OWNER/REPO/pulls/N/comments/COMMENT_ID/replies -f body='Fixed in abc1234 — <what changed>.'
```

Resolve a thread — needs the thread's GraphQL node id (`.id` per node, which the step-2 resolution
query already selects). The self-contained listing below re-fetches it alongside each thread's first
comment, to map finding → thread id:

```bash
gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){
  pullRequest(number:$n){reviewThreads(first:100){nodes{id isResolved
  comments(first:1){nodes{author{login} path line body}}}}}}}' \
  -f o=OWNER -f r=REPO -F n=N \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[]
        | select(.isResolved==false)
        | select(.comments.nodes[0].author.login|ascii_downcase|test("copilot|advanced-security|code-scanning"))
        | {id, path:.comments.nodes[0].path, line:.comments.nodes[0].line}'

# Mark one thread resolved (THREAD_ID is the `id` above, e.g. PRRT_...):
gh api graphql -f query='mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{isResolved}}}' \
  -f t=THREAD_ID
```

If a resolve or reply call fails (permissions, a thread that isn't resolvable via the API), don't
let it abort the run — report which threads you could not resolve so the user can click them shut.

**Done when:** every addressed thread is resolved, the important ones carry a one-line reply naming
the fix, and the run summary tells the user which comments were skipped and why (and any threads the
API would not let you resolve).

## 7. Capture the defect class

A finding you triaged as **address** and fixed is worth logging when it was an instance of a *class*
rather than a one-off — a shape of mistake makeable again in this repo. A vacuous assertion, a
guard that a whitespace change evades, a term colliding with an established one: those recur. A single
typo does not.

```bash
~/.claude/skills/bin/skill-learnings-log '{"type":"pitfall","key":"<kebab-slug>","insight":"<the class, and the tell that would catch it earlier>","confidence":8,"source":"observed"}'
```

A **skipped** finding is worth logging only when the bot was wrong for a reason that will recur —
a repo convention it keeps misreading — so the next run triages it faster. One call per learning,
after the push, never blocking it. Rules: [`COMPOUNDING.md`](../COMPOUNDING.md).

**Done when:** every addressed finding that was a class rather than a one-off is logged, or there
were none and the run summary says so.
