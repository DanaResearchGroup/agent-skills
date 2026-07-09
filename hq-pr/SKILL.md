---
name: hq-pr
description: Use when Alon wants to triage his pull requests and refresh the Developer watch-list — "run hq-pr", "go through my PRs", "what should I do on my PRs" / "on ARC's PRs", "update the PR next-actions". An augmented, per-PR decision session over the curated Developer nodes.
---

# hq-pr — decide per-PR next-actions WITH Alon

The augmented PR session: walk the **curated** Developer watch-list against live PR state and, for
each PR, settle the **next-action** — *with Alon* — then write the agreed set into the Developer
node. **HQ's `CLAUDE.md` is the source of truth** for the schema and the Developer-hat rules — read
it; this skill only orchestrates and **must not duplicate its depth.** Vault:
`~/Dropbox/Apps/remotely-save/Vault/`.

## Iron rules
- **Write ONLY inside `HQ/`.** Never mutate the repos or `Status.md` (that's `hq-update`'s job).
- **Decisions are Alon's — you recommend, he decides.** The per-PR action, the priority order, and
  *which* PRs are even on the watch-list are HIS calls (the node says "decided with Alon"). Present
  recommendations and **do not write the node until he has weighed in.** This is NOT autonomous
  triage — collapsing it into "CC decides every action and writes them" is the exact failure this
  skill exists to prevent.

## Input
- **`Status.md` PR watch-list** — the deterministic live state (ci / merge / review / draft) per PR.
  If it's stale, refresh first (`hq-update`'s `hq_pull.py --prs`).
- **The Developer node's current `Next actions`** — the standing decisions to reconcile against.

## Flow
1. **Reconcile & detect drift.** For each PR already in the node's next-actions, compare its stated
   assumption to live state and **flag drift loudly**: a `ready-to-merge` on a now-`CONFLICTING` PR
   → action must become `rebase-first`; a merged PR → `drop`. Drift is the highest-value thing you
   surface — lead with it.
2. **Recommend, per curated PR** — current state + any drift + a suggested action (vocabulary below)
   + a one-line *why*. Rank by importance × urgency. Keep each to one verb-first line.
3. **Surface the edges as questions — do NOT decide them.** NEW strategic PRs from the live pull are
   **candidates to add → ask** (never auto-add); watch-list PRs now merged/closed are **candidates
   to drop → ask**; priority ties → ask. Guessing here is the same failure as deciding actions.
4. **Present to Alon; let him decide** — accept / re-word an action / reorder / add / drop. Only
   after he decides do you write.
5. **Write the agreed set** into the node's `Next actions` (verb-first, PRs live-linked, the action
   vocabulary), bump `updated:` (`DD/MM/YYYY`), and append one dated `Log` entry recording what was
   decided and which drift was resolved. Leave `Status.md` / `Dashboard.md` to `hq-update`.

## Action vocabulary
`review` (someone else's PR you owe a review) · `develop <what's left>` · `rebase-first` (live
CONFLICTING) · `fix-CI` (live ci=red) · `ready-to-merge` (green + mergeable, just needs merging) ·
`drop` / `close`. **Authored** PRs (his) take develop / rebase-first / fix-CI / ready-to-merge;
**review-requested** PRs (others') take review.

## What good looks like
> ARC: led with the drifts (a `ready-to-merge` line now `CONFLICTING` → recommend `rebase-first`);
> gave an action + priority per curated PR with a one-line why; surfaced the edges as questions —
> "add these new strategic PRs to the watch-list? drop #NNN (merged)? should the review-queue become
> to-dos?" — and did **not** decide them. Alon picked; only then wrote the agreed `Next actions` +
> a dated `Log` entry. `Status.md` untouched.
