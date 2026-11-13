---
name: copilot-review
description: Clear a PR's review comments — Copilot / Greptile / GitHub Advanced Security bots and human reviewers alike — triage each, fix the real ones, squash each fix into the commit it fixes, rebase onto the base if it has moved (resolving conflicts), force-push with lease, then reply to each thread and resolve the ones it addressed. Bot findings run to completion unattended; a human thread it disagrees with, or that asks a question, gets a reply but stays open and is flagged back to you. Invoking it is the approval to rewrite history and force-push.
disable-model-invocation: true
---

# copilot-review

Turn a PR's review comments — from the Copilot / Greptile / security **bots** and from **human reviewers**
alike — into fixes folded cleanly back into history: **target** the PR → **fetch** the comments →
**triage** them → fix → **fixup** into the right commits, **rebase** onto the base if it has moved,
force-push with lease, then **respond** to the threads and **resolve** the ones you addressed.

**This runs to completion in one pass.** Being invoked *is* the authorisation to rewrite history
and force-push: every finding you classify as **address** gets fixed, squashed into the commit that
owns it, and pushed, without stopping to confirm. Report the triage table as you go — that is
transparency, not a question. The only things that stop the run are the 5b tripwires (downstream
work, a dirty worktree elsewhere, a branch shared with collaborators) and a conflict you cannot
resolve confidently; those are safety checks, and they stop-and-report rather than ask permission.

**Bots and humans differ only at the edges.** The fetch, fix, fixup, rebase and force-push are one
shared flow. A human reviewer is the person whose approval merges the PR, so their comment is a
change to make unless you have a real technical objection — you don't skip it as noise the way you
skip a bot nit. And you close threads more conservatively: resolve a human thread only when you
actually made the change it asked for. A comment you disagree with, or one that asks a question
rather than requesting a change, gets a reply but **stays open** and is surfaced back to the user in
the run summary — resolving someone else's objection you didn't act on is not yours to do. These
deltas live in steps 3 (triage) and 6 (respond); everything between is identical.

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

## 2. Fetch the latest review comments

Two kinds of author to fetch: the **bots** (Copilot / Greptile / GitHub Advanced Security) and the
**human reviewers** (anyone who isn't you, the PR author). Greptile (`greptile-apps[bot]`) is a bot
everywhere below, never a human: its threads are triaged address/skip and resolved like Copilot's.
Match on author login, case-insensitive, newest review pass only. Copilot re-reviews on every push, so old bot comments may be stale — prefer the
most recent pass and skip threads already marked resolved.

Resolve the PR author first, so the human fetch can exclude your own comments. Export it — `gh`'s
`--jq` reads shell variables through gojq's `env`, and does **not** accept jq's `--arg` flag:
```bash
export ME=$(gh pr view N --json author -q .author.login)
```

### Bot comments

```bash
# Inline review comments — where Copilot and the security bot post line-level findings
gh api --paginate repos/OWNER/REPO/pulls/N/comments \
  --jq '.[] | select(.user.login|ascii_downcase|test("copilot|advanced-security|code-scanning|greptile"))
        | {id, login:.user.login, path, line, body, url:.html_url, created:.created_at}'

# Copilot's overall review verdict / summary
gh api --paginate repos/OWNER/REPO/pulls/N/reviews \
  --jq '.[] | select(.user.login|ascii_downcase|test("copilot|greptile"))
        | {login:.user.login, state, body, submitted:.submitted_at}'
```

Greptile's verdict is not a review object: its reviews carry empty bodies and keep stale commit SHAs
after a force-push. It is one top-level PR comment, edited in place each round, whose body starts
`<!-- greptile_summary -->`. Read its findings, its round count (`Reviews (K)`) and its
"Last reviewed commit" SHA:
```bash
gh api --paginate repos/OWNER/REPO/issues/N/comments \
  --jq '.[] | select(.user.login=="greptile-apps[bot]") | select(.body|startswith("<!-- greptile_summary -->"))
        | {id, updated:.updated_at, body,
           rounds:(.body|capture("Reviews \\((?<k>[0-9]+)\\)").k? // null),
           reviewed:(.body|capture("Last reviewed commit:[^\\n]*?/commit/(?<sha>[0-9a-f]{40})").sha? // null)}'
```

To avoid re-addressing threads already resolved, check thread resolution and keep only unresolved:
```bash
gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){
  pullRequest(number:$n){reviewThreads(first:100){nodes{id isResolved
  comments(first:1){nodes{author{login} path body url}}}}}}}' \
  -f o=OWNER -f r=REPO -F n=N \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[]
        | select(.isResolved==false)
        | select(.comments.nodes[0].author.login|ascii_downcase|test("copilot|advanced-security|code-scanning|greptile"))'
```

This query (and the step-6 listing and verification queries) caps at `reviewThreads(first:100)` — fine
for almost every PR, but on one with more than 100 threads paginate with `after:$cursor`/`pageInfo{hasNextPage endCursor}`
or you will silently miss the overflow.

Optionally pull code-scanning alerts scoped to the PR head for security findings not surfaced as
comments: `gh api repos/OWNER/REPO/code-scanning/alerts -f ref=refs/pull/N/head` (needs security read).

### Human reviewer comments

Same three surfaces, but keep every author who is neither a bot nor you (`$ME`). Humans leave
comments in three places — inline review comments, the review verdict body, and top-level PR
conversation comments — so fetch all three:

```bash
# Inline review comments from humans (exclude bots and yourself)
gh api --paginate repos/OWNER/REPO/pulls/N/comments \
  --jq '.[] | select((.user.login|ascii_downcase|test("copilot|advanced-security|code-scanning|greptile"))|not)
        | select((.user.login|ascii_downcase) != (env.ME|ascii_downcase))
        | {id, login:.user.login, path, line, body, url:.html_url, created:.created_at}'

# Human review verdicts (APPROVED / CHANGES_REQUESTED / COMMENTED) with a non-empty body
gh api --paginate repos/OWNER/REPO/pulls/N/reviews \
  --jq '.[] | select((.user.login|ascii_downcase) != (env.ME|ascii_downcase)) | select((.user.login|ascii_downcase|test("copilot|advanced-security|code-scanning|greptile"))|not)
        | select((.body // "") != "") | {login:.user.login, state, body, submitted:.submitted_at}'

# Top-level PR conversation comments (the "issue" comments, not tied to a line)
gh api --paginate repos/OWNER/REPO/issues/N/comments \
  --jq '.[] | select((.user.login|ascii_downcase) != (env.ME|ascii_downcase))
        | select((.user.login|ascii_downcase|test("copilot|advanced-security|code-scanning|greptile"))|not)
        | {id, login:.user.login, body, url:.html_url, created:.created_at}'
```

The unresolved-threads GraphQL query above already returns human threads too — widen its filter to
keep them: replace the bot-only `test("copilot|...|greptile")` filter with `select((.comments.nodes[0].author.login|ascii_downcase) != (env.ME|ascii_downcase))` so every non-author review thread lands in the same list, each with its thread `id` for step 6.

**Done when:** every unresolved comment from the latest pass — bot and human — is in hand with its
body; inline/thread comments also carry their `path`, `line`, and thread `id` (review-verdict bodies
and top-level PR conversation comments have none of those — body is all they have).

## 3. Triage

Classify **every** fetched comment, each with a one-line reason — no comment left unaccounted for.
Read the cited code before judging; don't trust the comment's framing. Bot and human comments use
different verbs.

**Bot comments** range from real bugs to noise — classify each **address** or **skip**:

- **Address**: real correctness/security bugs, resource leaks, missing error handling, genuine
  edge cases the diff introduced.
- **Skip**: stylistic nits already consistent with the codebase, false positives (the concern
  doesn't hold when you read the surrounding code — record as skipped, don't reshape code to silence
  them), suggestions that fight an existing project convention, or findings on code the PR didn't touch.

**Human comments** carry the reviewer's authority — bias hard toward **address**, and never file one
as "skip" the way you dismiss a bot nit. Classify each **address** or **discuss**:

- **Address**: any request for a change you agree with — which is most of them. A human reviewer's
  ask is a change to make unless you have a real, statable technical objection.
- **Discuss**: a comment you genuinely disagree with after reading the code, *or* one that asks a
  question rather than requesting a change. Neither gets silently dropped and neither gets resolved
  by you — both become a reply that leaves the thread open (step 6), and both get surfaced to the
  user in the run summary. When in doubt between address and discuss, address it; reserve discuss
  for a real objection or a genuine question.

Report the triage table (comment → address/skip/discuss → reason) and the fixup plan (which fix squashes
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

**On conflict:** resolve it, don't paper over it. Read both sides and keep the intent of each,
rather than taking whichever side makes the conflict markers disappear:

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

Once the new history is on the remote, close out the threads on GitHub — replying and resolving per
the bot and human rules below (which say when a reply can be skipped and when a thread stays open).
An open thread you *did* act on reads as ignored and the next reviewer re-treads it; a thread you
resolved without acting on it — a human's — steamrolls the reviewer. Bots and humans close
differently.

**Bot threads — resolve every one, addressed and skipped alike.** The end state is zero open bot
threads, each carrying a one-line reason it is closed. Two moves:

- **Reply to the addressed threads.** For a finding that was a real bug, a security issue, or where
  the fix isn't obvious from the diff, post a one-line reply saying what you changed — e.g. "Fixed in
  `abc1234` — now closes the file handle in a `finally`." A resolved thread with no comment is fine
  for a trivial, self-evident fix.
- **Reply to the skipped threads too**, with the one-line reason from your triage table — e.g.
  "Skipped — false positive: `as_dict` omits the key when None, so this payload never occurs." This
  is the same rationale you'd give the user; posting it on the thread means the next reviewer sees why
  it was rejected instead of re-opening the question. State the reason; don't argue or re-litigate.
  Then **resolve every bot thread** — addressed and skipped — whether or not the reply was trivial.

**When the fix is delegated, the resolve is still yours.** This skill assumes one agent triages,
fixes and closes out. If instead you triage here and hand the fixing to someone else — a worker
session, a subagent, a colleague — **the thread does not close itself when their fix lands.** Name
the owner explicitly, and default it to *you*: whoever ran the triage is the one who knows which
finding each thread carried and whether the fix actually answered it.

Two failure modes, both observed:

- **Nobody resolves.** You wait for the fixer to close the thread; the fixer never had the triage
  table and assumes the dispatcher or the reviewer will. The thread outlives the fix, and the next
  reviewer re-treads a finding that was dealt with hours ago.
- **You tell the fixer to leave it open**, reasoning that the thread is the reviewer's to close.
  That instinct is right for a **human** reviewer and wrong for a **bot** — a bot never comes back
  to close anything, so "leave it for the reviewer" means "leave it open forever." Don't let the
  human rule below leak onto a bot thread.

So when you delegate the fix, come back once it is pushed and run this step yourself against the
updated PR head: reply naming the commit that fixed it, then resolve. Verifying the fix before
resolving is the point — resolving on the fixer's say-so is how a thread gets closed over a fix that
did not actually answer the finding.

**Human threads — reply to every one, but resolve only what you addressed.** A human's thread is
theirs to close by convention; you resolve it only as the unambiguous signal "done, as asked."

- **Addressed** (you made the change): reply saying what you changed and where — e.g. "Done in
  `abc1234` — pulled the validation into `parse_config`." Then **resolve** the thread. Acting on the
  request is what earns the resolve.
- **Discuss — disagreement**: reply with your reasoning, courteously and once — state the technical
  case, don't re-litigate. **Leave the thread open** and list it in the run summary. Resolving your
  own rebuttal of a reviewer's objection is not yours to do.
- **Discuss — a question**: post a substantive answer, then **leave the thread open** — a question
  is the reviewer's to close once they're satisfied. Flag it in the summary too.

Reply to a review thread's comment (post under the same conversation):

```bash
# COMMENT_ID is the numeric `id` of the inline comment being replied to (bot or human; not the
# html_url) — step 2's fetch already emits it as `.id`. A top-level PR conversation comment (from the
# issues/N/comments fetch) has no thread; reply there with
# `gh api repos/OWNER/REPO/issues/N/comments -f body=...` instead.
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
        | select((.comments.nodes[0].author.login|ascii_downcase) != (env.ME|ascii_downcase))
        | {id, login:.comments.nodes[0].author.login, path:.comments.nodes[0].path, line:.comments.nodes[0].line}'

# Mark one thread resolved (THREAD_ID is the `id` above, e.g. PRRT_...):
gh api graphql -f query='mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{isResolved}}}' \
  -f t=THREAD_ID
```

Resolve every **bot** thread and every **addressed human** thread. Do **not** resolve a human
"discuss" thread (a disagreement or a question) — those stay open by design, so match them against
your triage table and skip them here.

The `resolveReviewThread` mutation returns `thread{isResolved}`, but a call can also fail silently
(permissions, an already-collapsed thread, a bad node id) and leave the thread open. So **verify**
after the mutations rather than trusting each return: re-run the listing query and confirm the only
threads still `isResolved:false` are exactly the human "discuss" ones you deliberately left open —
every bot thread and every addressed-human thread must now read `true`.

```bash
gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100){nodes{id isResolved comments(first:1){nodes{author{login} path line url}}}}}}}' \
  -f o=OWNER -f r=REPO -F n=N \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[]
        | select(.isResolved==false)
        | select((.comments.nodes[0].author.login|ascii_downcase) != (env.ME|ascii_downcase))
        | {tid:.id, by:.comments.nodes[0].author.login, path:.comments.nodes[0].path, line:.comments.nodes[0].line, url:.comments.nodes[0].url}'
        # every row must be a human "discuss" thread you chose to leave open — nothing else; the tid/url pinpoints any stray one to click shut
```

If a resolve or reply call fails (permissions, a thread that isn't resolvable via the API), don't
let it abort the run — report which threads you could not resolve so the user can click them shut.

**Greptile: gate on its summary, re-request only a new head.** Where Greptile reviews the repo, the
merge gate is its summary comment: its "Last reviewed commit" SHA equals the current PR head. Never
gate on Greptile's review objects — their SHAs go stale after a force-push. After the push, re-run
step 2's summary read as one snapshot: one GraphQL response that holds the summary and every
review request, so the reviewed SHA, the round count and the requests all come from the same moment:
```bash
export HEAD_SHA=$(gh pr view N --json headRefOid -q .headRefOid)
gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){comments(first:100){totalCount nodes{databaseId author{login} body createdAt}}}}}' \
  -f o=OWNER -f r=REPO -F n=N \
  --jq '.data.repository.pullRequest.comments as $c
        | [$c.nodes | to_entries[] | .value + {i:.key}] as $n
        | ($n | map(select(.author.login=="greptile-apps" and (.body|startswith("<!-- greptile_summary -->"))))) as $ss
        | ($ss | last) as $s
        | ($n | map(select(.body|test("^\\s*@greptileai\\s+review\\b";"i")))) as $req
        | (($s.body // "") | capture("Last reviewed commit:[^\\n]*?/commit/(?<sha>[0-9a-f]{40})").sha? // null) as $reviewed
        | (($s.body // "") | capture("Reviews \\((?<k>[0-9]+)\\)").k? // null | if . then tonumber else . end) as $rounds
        | ($rounds // 0) as $k
        | (if $k > 0 and ($req | map(select(.i < $ss[0].i)) | length) == 0 then 1 else 0 end) as $auto
        | ([($req|length), ([$k - $auto, 0] | max)] | min) as $answered
        | $req[$answered:] as $open
        | ($k + ($open|length)) as $spent
        | (if $reviewed == env.HEAD_SHA then []
           else $open | map(select((.body|contains("<!-- greptile-request head=" + env.HEAD_SHA + " -->"))
                                   or (.body|contains("<!-- greptile-request head=")|not)))
                      | map({id:.databaseId, at:.createdAt, marked:(.body|contains("<!-- greptile-request head=")),
                             stale:((.createdAt|fromdate) < (now - 3600))}) end) as $out
        | {head:env.HEAD_SHA, reviewed:$reviewed, rounds:$rounds, requests:($req|length),
           unanswered:($open|length), spent:$spent, outstanding:$out, truncated:($c.totalCount > 100),
           state:(if $reviewed == env.HEAD_SHA then "green"
                  elif ($out | map(select(.marked)) | length) > 0 then "pending"
                  elif ($out|length) > 0 then "pending (ambiguous)"
                  elif $spent < 2 then "request" else "capped" end)}'
```
A request is **answered** once a round has followed it. Greptile answers requests one round each, in
comment order, so the snapshot settles which ones are answered by position alone, with no clock:
`rounds` rounds have run; the first is unrequested (`auto` = 1) only when no request comes before
the summary comment, because Greptile writes that comment at its first round; every other round
answers the oldest request not yet answered. The last `unanswered` requests, any head, marked or
not, are still open. `spent` is `rounds` plus `unanswered`: every round run and every round still
owed, with each answered request counted once. A request that got no round of its own (two
requests answered by one round) stays open and keeps `spent` high, which errs on the cap's safe
side. No summary yet counts as 0 rounds, so every request is open; if a summary exists but `rounds`
reads null, count the rounds from its body before asking. If `truncated` is true, the PR has over 100
comments and the counts may be low: post nothing and report it.

An open request is **outstanding** when `reviewed` is not `HEAD_SHA` and the request either names
`HEAD_SHA` in its hidden marker (`marked`) or carries no marker. Every request this skill posts
names its head, so a marked request for an earlier head is not outstanding, but it still counts in
`spent`. An unmarked request (an older run of this skill, or a person) may be for `HEAD_SHA`; the
snapshot cannot tell. Greptile is in one of three states: green, pending, or capped out. The
`state` field picks one of four cases, in this order; `request` is the one action, and it leaves
the gate pending:
- **`green`: `reviewed` = `HEAD_SHA`** — the gate is green. Request nothing: a review of an
  unchanged head spends a round for nothing. A run that skipped every finding and pushed nothing
  lands here.
- **`pending` or `pending (ambiguous)`: an outstanding request** — post nothing: a second request
  for the same head gets no new review and can spend a round. For `pending`, a marked request for
  `HEAD_SHA` is open: report "Greptile re-review pending at `HEAD_SHA`" and end the run. For
  `pending (ambiguous)`, only unmarked requests are open: report "Greptile request pending, head
  unknown" with each unmarked row's `id`, and end the run. The user decides whether that request
  covers `HEAD_SHA` or should be deleted. In both, name every unmarked row's `id`. A round takes
  Greptile minutes; if a row in `outstanding` is `stale` (posted over an hour ago, by GitHub's
  clock), Greptile has likely dropped it, so the summary says so with the row's `id` and `at`, and
  leaves the re-request to the user.
- **`request`: no outstanding request, `spent` below 2** — ask for a fresh round. Greptile
  re-reviews only when asked by a PR comment, not through `requested_reviewers`. The second line is
  the marker; it renders as nothing:
  ```bash
  gh pr comment N --body "@greptileai review
  <!-- greptile-request head=$HEAD_SHA -->"
  ```
  The gate is now **pending**. Do not wait for it: report "Greptile re-review pending at `HEAD_SHA`"
  and end the run. Its new findings arrive later; the next run picks them up at step 2.
- **`capped`: no outstanding request, `spent` 2 or more** — the cap is spent: at most 2 rounds, then
  fix, file a follow-up, or rebut. Do not ask again. A request still open for an earlier head counts
  here, so a pending second round leaves no room for a third. Your own verification of the fix (the
  checks you ran on `HEAD_SHA`) closes the gate, and the run summary says plainly "unreviewed by
  Greptile since round 2: reviewed `<reviewed>`, head `HEAD_SHA`". Add "`<unanswered>` round(s)
  pending" if `unanswered` is above 0.

Never report the Greptile gate green for a head Greptile did not review.

**Done when:** every bot thread (addressed and skipped) and every addressed-human thread is resolved,
the non-trivial ones carrying a one-line reply; every human "discuss" thread carries a reply and is
intentionally left open; the verification query shows nothing open but those; Greptile, where it
reviews, is in exactly one of the three states above and the run summary names it (green at the
head, re-review pending at `HEAD_SHA` or pending with an unmarked request's `id` — the review is then
not complete, so do not report it so — or capped out with both SHAs); the run posted no request while
one was outstanding;
and the run summary tells the user which bot findings were skipped and why, and which human threads
were left open (disagreements and questions) for them to weigh in on — plus any threads the API
would not let you resolve.

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
