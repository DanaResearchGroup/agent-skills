---
name: fleet-review
description: Pre-landing review of a PR or diff. Scopes the agent fleet to the change's breadth and routes each pass to a model that fits its job.
disable-model-invocation: true
argument-hint: "[PR url | branch | base ref — defaults to the merge-base with the repo's default branch]"
---

# Review

Review a diff before it lands, with a **fleet** sized to the change and a model chosen per pass.

Two rules carry the weight, and both were paid for:

**Breadth, not length.** A change spread across twelve files is riskier than a deep change in
two. Sizing on line count sent seven Opus agents at a two-file PR — +3260 lines, but the surface
was one new module and its test file.

**Executed or it is not P0.** In that same review the best finding came from mutating the code
and re-running the suite, while two of the reviewer's most confident theories died the moment
they were executed. Reasoning that has not been run is a hypothesis.

## Step 0 — Isolate

Resolve the head commit, then create a detached worktree at it and do the whole review there:

```bash
HEAD_SHA=$(git rev-parse HEAD)          # or the PR head, if reviewing someone else's branch
git worktree add --detach "../$(basename "$PWD")-review-${HEAD_SHA:0:7}" "$HEAD_SHA"
```

Other checkouts of this branch may be live sessions. The review reads; the author's tree stays
theirs.

The mutation pass in Step 4 is the one exception, because editing source *is* its job. It gets
its own separate disposable worktree and restores it byte-identically, quoting
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
  | grep -E '\.(py|ts|tsx|js|jsx|rb|go|rs|sh|sql|ya?ml|toml)$' || true)
BREADTH=$(printf '%s' "$SRC" | grep -c . || true)
PKGS=$(printf '%s' "$SRC" | cut -d/ -f1-2 | sort -u | grep -c . || true)
LINES=$(git diff --numstat "$BASE" "$HEAD" | awk '{a+=$1; d+=$2} END{print a+d+0}')
```

Tests are excluded because they are the *subject* of the testing pass, not evidence of width.
Build and config files are included: filtering to source extensions once scored a real PR at
`BREADTH=1` by dropping the `.github/workflows/ci.yml` that carried its credential change.

| tier | trigger | agent cap |
|---|---|---|
| **T0** | `BREADTH ≤ 1` and `LINES < 50` | 0 specialists — critical pass only |
| **T1** | `BREADTH ≤ 3` | **3** |
| **T2** | `BREADTH 4–10` | **5** |
| **T3** | `BREADTH > 10` or `PKGS ≥ 3` | **7**, red team unlocked |

**Done when:** BREADTH, PKGS, LINES, and the resulting tier are all stated.

## Step 3 — Preflight the fleet

Nothing launches until the plan is on screen. Select passes up to the tier cap in this priority
order — **testing → security → api-contract → maintainability → performance → data-migration**.
Codex adversarial sits outside the cap and outside the model budget; run it whenever the Codex
CLI is available and authenticated.

**Risk override.** These paths force-add the security pass above the cap, at any tier including
T0. Insurance passes stay in the fleet even when the tier would drop them:

- authentication, authorization, session, or credential handling
- database migrations
- **CI and release configuration** — `.github/workflows/`, and anything that runs with a token.
  A one-line diff there executes with repository credentials and reaches further than a
  thousand-line diff in application code.
- any path the repo's `CLAUDE.md` declares hard-constrained. gracie declares recording and audio
  persistence, where a wrong call means an AI speaks unbidden in a classroom.

Print the plan:

```
Tier T1 (2 source files, 1 package, +3260/-7). Dispatching 3:
  testing(sonnet)  security(opus)  codex-adversarial
Gated by cap: maintainability, performance, api-contract, red-team, claude-adversarial
```

**At T2 and above, the plan is the last thing in the turn.** End there and let the user approve
the spend before a single agent starts. At T1 and below the cap is three, which is the cheap
case this gate exists to protect — continue straight into Step 4.

**Done when:** the preflight is on screen, and either the tier is T1 or below, or the turn has
ended on it.

## Step 4 — Dispatch

Every pass is **legwork** or **judgment**, and that decides the model. A legwork pass earns its
keep by *running* things — mutating, measuring, comparing what is declared against what is used.
A judgment pass earns its keep by *reasoning* under adversarial pressure.

| pass | kind | agent | checklist |
|---|---|---|---|
| testing / mutation | legwork | `code-implementer` (sonnet) | `specialists/testing.md` |
| api-contract | legwork | `code-implementer` (sonnet) | `specialists/api-contract.md` |
| data-migration | legwork | `code-implementer` (sonnet) | `specialists/data-migration.md` |
| performance | legwork | `code-implementer` (sonnet) | `specialists/performance.md` |
| maintainability | legwork | `snippet-classifier` (haiku) | `specialists/maintainability.md` |
| security | judgment | `architecture-reviewer` (opus) | `specialists/security.md` |
| red team | judgment | `architecture-reviewer` (opus) — T3 or a confirmed CRITICAL | `specialists/red-team.md` |
| Codex adversarial | cross-model | `codex exec` — outside the model budget | — |
| Claude adversarial | judgment | `architecture-reviewer` (opus) — only when Codex is unavailable, or T3 | — |

Dispatch every selected pass in a **single message**, so they run in parallel and none of them
reads another's conclusions.

Each pass receives:

1. its checklist, read from the file named above
2. the pinned base and head SHAs, and the review worktree path
3. the repo's accumulated learnings — `bin/skill-learnings-search --limit 5`
4. the repo's read prohibitions, quoted from its `CLAUDE.md`

That fourth item is load-bearing where a repo holds pre-registered evaluation splits or other
data that reading would spend. Name those paths to every agent, and say what reading them costs.

**Done when:** every selected pass has returned findings or `NO FINDINGS`, and any pass that
failed is reported as failed rather than counted as clean.

## Step 5 — Verify

Findings arrive as claims. Convert each to a **provenance** — how the claim was established, not
how strongly it reads:

- **executed** — a repro, a mutation, or a test was run, and its output is quoted
- **read** — derived from reading the code
- **cross-model** — an independent model reached it, and it was re-derived here against the source

A finding reports at P0 only with `executed` provenance. A read-only claim that would otherwise
be P0 reports at P1 with its reasoning intact.

Re-derive any cross-model finding against the source before accepting it. Adopt the finding, not
the other model's confidence.

**Done when:** every finding carries a provenance, and every P0 quotes executed output.

## Step 6 — Report

Lead with the bookends table (repo, PR, head, base, scope, worktree, date), then:

- **Coverage disclosure** — which passes ran, which did not, and why. A pass that was stopped,
  failed, or was gated leaves a hole; name it at the top where it will be read.
- **Findings**, ordered by what to fix first, each carrying file:line, provenance, and confidence.
- **Negative results** — theories tested and withdrawn, so the next session does not re-tread them.
- **Not done** — what was deliberately left, and whose call it is.

**Done when:** the report names every pass that did not run.

## Step 7 — Persist

The Step 6 report lives only in this conversation, and the reader who has to act on it is
usually the session that wrote the code. Drop it as a standalone artifact — run `drop-review`.
It reuses what this review already pinned: the bookends from Step 1 and the per-finding
provenance from Step 5, which land straight on its own scale. It synthesizes what is here; it
runs no new passes.

Then log the metric line, so the next review of this repo sizes itself against this one:

```bash
bin/skill-review-log '{"tier":"T1","breadth":2,"agents":3,"findings":33,"critical":13,"head":"<sha>"}'
```

And store every finding that would change how the *next* review of this repo behaves — a gate
that lies, a suite that passes for the wrong reason, a constant no test pins:

```bash
bin/skill-learnings-log '{"type":"pitfall","key":"<slug>","insight":"...","confidence":8,"source":"observed"}'
```

**Done when:** the artifact is dropped, the review record is written, and every finding meeting
that bar is stored.
