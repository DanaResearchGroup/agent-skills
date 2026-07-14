---
name: hq-update
description: Use when refreshing the HQ vault — the daily or on-demand HQ status update. Pulls live PR/CI/mergeable/review state, computes deadline countdowns, staleness, dead pointers, and suggested traffic lights, then writes them into HQ boards/nodes. Use when asked to run hq-update, refresh HQ, update the HQ dashboard/boards, or "what changed in HQ".
---

# hq-update — refresh the HQ dashboard & boards

Runs the deterministic half of HQ. **HQ's `CLAUDE.md` is the source of truth** for the schema,
the traffic-light rule, and governance — read it; this skill only orchestrates and **must not
duplicate its depth**. Vault: `~/Dropbox/Apps/remotely-save/Vault/` (path per machine in CC memory).

## Where & when
Any always-on host with `gh` auth + the vault (**HL** or **ol**). Daily (not hourly) or on demand.

## Two halves: scheduled (deterministic) vs augmented (this skill)
- **Scheduled/unattended** = `hq_run.sh` via cron (HL 05:00; OL 05:30 deferring to HL's stamp).
  It runs `hq_pull.py` and regenerates **`HQ/Status.md`** — a live snapshot (PR/CI, countdowns,
  staleness, suggested lights). **No LLM, no curation, writes only `Status.md`.** Read it first.
- **Augmented** = *this skill*, run by a CC session on demand. It reads `Status.md` + live state
  and does the judgment: board next-actions, drift fixes, Inbound triage, proposed strategy
  diffs. Everything below is the augmented flow.

## Iron rule
**Write ONLY inside `HQ/`.** Read repos, `~/Projects`, `Research/Strategy`, `knowledge/` — never
mutate them. Strategy changes are *proposed as a diff Alon approves*, never auto-committed.

## Step 1 — pull deterministic state
```bash
python3 ~/Code/agent-skills/hq-update/hq_pull.py            # both blocks
python3 ~/Code/agent-skills/hq-update/hq_pull.py --scan     # HQ nodes only (no network)
python3 ~/Code/agent-skills/hq-update/hq_pull.py --prs      # live PR watch-list only
```
The helper **computes, never writes**. It emits: a node scan (deadline countdown, staleness,
dead `local:` pointers, and a *suggested* light from `importance` × derived urgency) and the live
PR watch-list (authored + review-requested, each with ci=green/red, merge=MERGEABLE/CONFLICTING,
review decision, draft).

## Step 2 — apply into HQ (targets)
| Target | Action |
|---|---|
| `update-repos` | For each Developer node, refresh its PR lines' ci/merge/review from `--prs`. **Flag drift**: a `ready-to-merge` next-action on a now-`CONFLICTING` PR → change to `rebase`. New strategic PRs → list for Alon to curate (don't auto-add). |
| `update-deadlines` | Write each node's `⏳Nd` / `⚠OVERDUE`; bump `urgency` where a deadline crossed a threshold. |
| `update-staleness` | Nodes flagged `🕸 stale` → surface on the board's review line. Don't edit content. |
| `update-integrity` | Dead `local:`/repo pointers → `⚠ dead pointer` on the node; never delete. |
| `update-dashboard` | Rebuild [[Dashboard]] "Top of mind" (importance×urgency across all hats) + the capped circle clusters (≤5/color). Apply suggested lights, but a **manual `light:` override wins** — only change a light Alon set if he set `urgency: auto`. |
| `update-all` | The daily default = all of the above. |

## Step 3 — Inbound triage
Read `HQ/Inbound.md` "Unsorted". Propose a routing (hat/node) under "Triaged" for each; clear only
what Alon has confirmed. Ask when a line is ambiguous — never guess a hat silently.

## Step 4 — close out
Bump `updated:` (`DD/MM/YYYY`) on every node you touched. Summarize to Alon: what changed, what
drifted, what needs his judgment (curation, ambiguous inbound, proposed strategy diffs).

## Traffic-light rule (defer to HQ/CLAUDE.md; summarized only)
🔴 important(≥4) AND urgent · 🟡 important OR urgent · 🔵 neither. Urgency is `deadline ≤ 3d`,
CI-red, or manual `urgency: high`. Done ⇒ archived to `HQ/_archive/`, never recolored.
`blocked: true` → render **⛔ beside the light** (orthogonal — don't force red; blocked ≠ urgent).

## PR references
Always live links that **carry the PR's title**: `[#878 sp_composite focal-point/CBS protocols](https://github.com/<owner>/<repo>/pull/878)`
— never a bare `#878`, never a number without its title. `hq_pull.py` emits title-bearing linked
PRs into [[Status]]; match that in every board/node you write (defer to HQ/CLAUDE.md).

## What good looks like
> #878 sp_composite: live `CONFLICTING` → node next-action flipped `ready-to-merge` → `rebase`;
> #909 NMD CI-red → 🔴 flag on ARC node; Dashboard Top-of-mind rebuilt; 1 inbound routed (pending
> Alon's OK); ARC-paper `updated:` bumped. No writes outside HQ/.
