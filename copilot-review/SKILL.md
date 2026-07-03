---
name: copilot-review
description: Triage and fix a PR's automated bot review (Copilot + GitHub Advanced Security), squashing each fix into its commit and force-pushing with lease.
disable-model-invocation: true
---

# copilot-review

Turn a PR's automated bot review into fixes folded cleanly back into history: **target** the PR →
**fetch** the bot comments → **triage** them → fix → **fixup** into the right commits and force-push
with lease.

## 1. Target the PR

Resolve to exactly one PR before fetching anything. Its state must be OPEN.

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
  doesn't hold when you read the surrounding code), suggestions that fight an existing project
  convention, or findings on code the PR didn't touch.

Don't reshape code merely to silence a bot — a change made only to make a finding disappear
validates nothing. Fix the defect when it's real; record the false positive as skipped when it's not.

Present the triage table (comment → address/skip → reason) and the fixup plan (which fix squashes
into which commit) and get the user's go-ahead before rewriting history — per the repo's git-history
rule, history rewrites and force-pushes need approval.

**Done when:** every comment is classified with a reason and the user has approved the plan.

## 4. Fix

Make the code changes for each **address** item. Run the repo's tests/linters if the change is
non-trivial and they're quick; report honestly if anything fails.

## 5. Fixup into history and force-push

Fold each fix into the commit that introduced the reviewed line rather than stacking "address
review" commits — one logical change per commit in the final history.

```bash
git log --oneline $(git merge-base HEAD origin/BASE)..HEAD   # find the target commit per fix
git blame -L START,END -- path/to/file                       # confirm which commit owns the line
git add path/to/file && git commit --fixup=TARGET_SHA        # one fixup per target commit
# ...repeat for each fix, then autosquash them in. A no-op sequence editor makes the interactive
# rebase run non-interactively — plain `git rebase --autosquash` (without -i) does NOT squash:
GIT_SEQUENCE_EDITOR=true git rebase -i --autosquash --autostash $(git merge-base HEAD origin/BASE)
git log --oneline $(git merge-base HEAD origin/BASE)..HEAD   # verify: no `fixup!` commits remain
git push --force-with-lease
```

Notes:
- **Verify the squash landed** before pushing — the log above must show zero `fixup!` subjects. A
  stray `fixup!` commit on the remote is the exact failure this skill exists to prevent.
- A fix with no natural home (addresses freshly added code with no clear owning commit) can stay a
  normal commit — squash only where a target commit clearly owns the line.
- `--force-with-lease` (never bare `--force`) so a concurrent push on the branch aborts you instead
  of getting clobbered. If the lease is stale, re-fetch and reconcile — don't override with `--force`.

**Done when:** each fix is squashed into its target commit, the branch is force-pushed with lease,
and the PR head reflects the new history. Optionally reply to or resolve the addressed threads and
tell the user which comments were skipped and why.
