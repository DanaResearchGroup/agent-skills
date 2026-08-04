---
name: review
description: Pre-landing review of a PR or diff. Scopes the agent fleet to the change's breadth and routes each pass to a model that fits its job.
disable-model-invocation: true
argument-hint: "[PR url | branch | base ref — defaults to the merge-base with the repo's default branch]"
---

# Review

Review a diff before it lands, with a fleet sized to the change and a model chosen per pass.

Two rules carry most of the weight, and both come from reviews that went wrong:

**Breadth, not length.** A change spread across twelve files is riskier than a deep change in
two. Sizing on line count sent seven Opus agents at a two-file PR — the line count was +3260,
the surface was one new module and its test file.

**Executed or it is not P0.** The most valuable finding in that review came from mutating the
code and re-running the suite; two of the reviewer's own confident theories died the moment
they were executed. Reasoning that has not been run is a hypothesis.

## Step 0 — Isolate

Create a detached worktree at the head commit and do the whole review there:

```bash
git worktree add --detach ../$(basename "$PWD")-review-<sha> <sha>
```

Other checkouts of this branch may be live sessions. The review reads; the author's tree stays
theirs.

One pass is exempt: the mutation pass in Step 4 must edit source to do its job. It gets its own
separate disposable worktree, and restores it byte-identically — its report quotes
`git status --short` verbatim as proof.

**Done when:** the review worktree exists at the head SHA, and every other checkout of this
branch is as it was.

## Step 1 — Pin the bookends

Resolve and record three values. Everything downstream quotes them, so a moving branch name is
not enough:

- **base** — `git merge-base <base-branch> HEAD`, the real fork point
- **head** — the exact SHA under review
- **files** — `git diff --name-status <base> <head>`

**Done when:** base SHA, head SHA, and the changed-file list are all written down.

## Step 2 — Measure breadth

```bash
SRC=$(git diff --name-only "$BASE" "$HEAD" \
  | grep -vE '(^|/)(tests?|spec|fixtures?)/|(^|/)(test_|conftest)|_test\.|\.spec\.' \
  | grep -E '\.(py|ts|tsx|js|jsx|rb|go|rs|sh|sql|ya?ml|toml)$')
BREADTH=$(printf '%s' "$SRC" | grep -c . || true)
PKGS=$(printf '%s' "$SRC" | cut -d/ -f1-2 | sort -u | grep -c . || true)
LINES=$(git diff --shortstat "$BASE" "$HEAD" | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | grep -oE '[0-9]+' | paste -sd+ | bc)
```

Test files are excluded from breadth deliberately: they are the *subject* of the testing pass,
not evidence that the change is wide.

Build and config files are *included*, and the reason is a hole this rule had when it was first
written. Filtering to source extensions alone scored a real PR at `BREADTH=1` by dropping its
`.github/workflows/ci.yml` — the one file in that diff carrying a credential-handling change. A
PR touching only a workflow file would have scored T0 and drawn zero passes.

| tier | trigger | agent cap |
|---|---|---|
| **T0** | `BREADTH ≤ 1` and `LINES < 50` | 0 specialists — critical pass only |
| **T1** | `BREADTH ≤ 3` | **3** |
| **T2** | `BREADTH 4–10` | **5** |
| **T3** | `BREADTH > 10` or `PKGS ≥ 3` | **7**, red team unlocked |

**Done when:** BREADTH, PKGS, LINES, and the resulting tier are all stated.

## Step 3 — Plan the dispatch, and show it

Select passes up to the tier cap, in this priority order: **testing → security → api-contract →
maintainability → performance → data-migration**. Codex adversarial is free of the cap and the
model budget; run it whenever the Codex CLI is available and authenticated.

**Risk override.** Some paths force-add the security pass above the cap, at any tier including
T0. Insurance passes stay in the fleet even when the tier would drop them:

- authentication, authorization, session, or credential handling
- database migrations
- **CI and release configuration** — `.github/workflows/`, and anything that runs with a token.
  A workflow change is a supply-chain surface: it executes with repository credentials, and a
  one-line diff there can reach further than a thousand-line diff in application code.
- any path the repo's `CLAUDE.md` declares hard-constrained. gracie declares recording and audio
  persistence, where a wrong call means an AI speaks unbidden in a classroom.

Print the plan:

```
Tier T1 (2 source files, 1 package, +3260/-7). Dispatching 3:
  testing(sonnet)  security(opus)  codex-adversarial
Gated by cap: maintainability, performance, api-contract, red-team, claude-adversarial
```

**Done when:** the plan is on screen and zero Agent calls have been made.

This gate exists because the failure it prevents already happened: the spend became visible only
when the user interrupted a run in progress. One line, printed first, makes it a one-keystroke
veto.

## Step 4 — Dispatch

Every pass is either **legwork** or **judgment**, and that decides the model. A legwork pass earns
its keep by *running* things — mutating, measuring, comparing what is declared against what is
used. A judgment pass earns its keep by *reasoning* under adversarial pressure.

| pass | kind | agent |
|---|---|---|
| testing / mutation | legwork | `code-implementer` (sonnet) |
| api-contract | legwork | `code-implementer` (sonnet) |
| data-migration | legwork | `code-implementer` (sonnet) |
| performance | legwork | `code-implementer` (sonnet) |
| maintainability | legwork | `snippet-classifier` (haiku) |
| security | judgment | `architecture-reviewer` (opus) |
| red team | judgment | `architecture-reviewer` (opus) — T3 or a confirmed CRITICAL |
| Codex adversarial | cross-model | `codex exec` — outside the model budget |
| Claude adversarial | judgment | `architecture-reviewer` (opus) — only when Codex is unavailable, or T3 |

Dispatch all selected passes in a **single message** so they run in parallel and none of them
reads another's conclusions.

Each pass receives:

1. its checklist from `specialists/`
2. the pinned base and head SHAs, and the review worktree path
3. the repo's accumulated learnings — `bin/skill-learnings-search --limit 5`
4. the repo's read prohibitions, quoted from its `CLAUDE.md`

That fourth item is load-bearing where a repo holds pre-registered evaluation splits or any other
data that reading would spend. State those paths to every agent, and say what reading them costs.

**Done when:** every selected pass has returned findings or `NO FINDINGS`, and any pass that
failed is reported as failed rather than counted as clean.

## Step 5 — Verify

Findings arrive as claims. Convert each to a **provenance** — how the claim was established, not
how strongly it reads:

- **executed** — a repro, a mutation, or a test was run, and its output is quoted
- **read** — derived from reading the code
- **cross-model** — an independent model reached it, and it was re-derived here against the source

**A finding reports at P0 only with `executed` provenance.** A read-only claim that would
otherwise be P0 reports at P1 with its reasoning intact. This is what separates a defect from a
theory: in the review this skill was built from, two confident P0 candidates evaporated on
execution — the settle window absorbed one, a tombstone refused the other.

Re-derive any cross-model finding against the source before accepting it. Adopt the finding, not
the other model's confidence.

**Done when:** every reported P0 quotes executed output, and every withdrawn theory is recorded as
a negative result rather than dropped.

## Step 6 — Report

Lead with the bookends table (repo, PR, head, base, scope, worktree, date), then:

- **Coverage disclosure** — which passes ran, which did not, and why. A pass that was stopped,
  failed, or was gated leaves a hole; name it at the top where it will be read.
- **Findings**, ordered by what to fix first, each carrying file:line, provenance, and confidence.
- **Negative results** — theories tested and withdrawn. These stop the next session re-treading
  them.
- **Not done** — what was deliberately left, and whose call it is.

State outcomes plainly. If a gate failed, say so with the output.

**Done when:** the report names every pass that did not run.

## Step 7 — Persist

```bash
bin/skill-review-log '{"tier":"T1","breadth":2,"agents":3,"findings":33,"critical":13,"head":"<sha>"}'
```

Record anything learned about *this repo* that the next review would otherwise rediscover:

```bash
bin/skill-learnings-log '{"type":"pitfall","key":"<slug>","insight":"...","confidence":8,"source":"observed"}'
```

**Done when:** the review record is written, and every learning worth reusing is stored.
