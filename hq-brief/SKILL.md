---
name: hq-brief
description: Use when Alon wants his weekly HQ focus brief — what to focus on this week across his hats — or asks to run hq-brief, write/refresh the weekly briefing, or "what should I focus on this week". Also at the start of a new work-week in HQ.
---

# hq-brief — write the weekly "week ahead" HQ brief

Produce the **one artifact that tells Alon what to focus on the week ahead** across the six hats,
save it to the vault, and post a short version to Slack. It answers three questions and curates —
**what's URGENT, what's STRATEGIC, what's OPEN — chosen down to what actually matters this week,
not a list of everything.** **HQ's `CLAUDE.md` is the source of truth** for the schema,
traffic-light rule, and schema — read it; this skill only orchestrates and **must not duplicate
its depth**. Vault: `~/Dropbox/Apps/remotely-save/Vault/`.

## Two modes
- **Unattended (scheduled, the default).** Runs weekly by cron — **Saturday 18:00** on HL (OL 18:30
  as defer-backup) via `hq_brief_run.sh`, which refreshes `Status.md` first (deterministic) then
  runs this skill headless and **auto-posts to Slack — no approval gate.** Alon reads it async and
  corrects the board if he disagrees. Detect this mode by the `HQ_BRIEF_UNATTENDED=1` env var (the
  wrapper sets it) or the phrase "unattended mode" in your instructions.
- **On-demand (augmented).** Alon runs it in a live session. Same artifact, but you **show him the
  Slack draft and post only on his OK** (see the Slack section).

Alon deliberately chose unattended auto-post for the weekly brief (it summarizes the already-
deterministic `Status.md`, so the hallucination surface is small); this revises the earlier
"no unattended LLM" stance in `Design.md` §Freshness — recorded there as a decision.

## Input (read, don't re-pull the world)
1. **`HQ/Status.md` first** — the deterministic snapshot (live PR/CI, deadline countdowns,
   staleness, dead pointers, suggested lights). If its `Last refresh:` isn't today, regenerate it
   (`python3 ~/Code/agent-skills/hq-update/hq_pull.py`) or note the staleness in the brief.
2. **The flagged node bodies** — for each node Status.md surfaces, read its `Next actions` and
   `Objective` (Status.md has live state, not the *decided* next-actions). That's your material.

## The brief is a FOCUS artifact, not a status dump
The 37-PR watch-list and full node scan are **input**. The brief names the **top handful
cross-hat, then the per-hat priority** — never restates every node or PR. Rank by importance ×
urgency (defer to CLAUDE.md's light rule). A hat with no live nodes gets **one line** ("no live
nodes — nothing due"), not manufactured content. It is fine for one hat to dominate when that is
where the live work genuinely is.

## Output contract — `HQ/Briefings/YYYY-Www.md` (ISO week)
Frontmatter (`type: index`, `hat: all`, `title`, `created`/`updated` `DD/MM/YYYY`, `status`,
`sources:` listing `[[Status]]` + every node cited). Then these sections, in order:

1. **The one thing** — the single highest-leverage move for the week ahead, with *why* (what it
   unblocks).
2. **Urgent — do this week** — ordered list, **≤ ~4 items**, each a concrete verb-first action
   linked to its node. Urgent = important AND time-pressed (deadline ≤~1wk, CI-red, or blocking
   another node). This is the "must move" list.
3. **Strategic — important, not urgent** — the moves that matter for the big picture but aren't
   time-pressed; **one line each.** These are the first thing a busy week crowds out, so they get
   their own section rather than being buried — pick the 2–4 worth keeping in view.
4. **Open threads** — on the radar, don't-start / don't-drop; one line each.
5. **Needs fixing** — every integrity flag Status.md raised (`⚠ dead local:`, `🕸 stale`, dead
   repo pointer) becomes a fix-action here. **Never smooth a broken pointer into "keep warm."**
   Write "none" if Status.md raised none.
6. **Hat load at a glance** — a 6-row table (hat · live light · the week ahead).
7. **Success test** — "By next Saturday: …", plus the tie-breaker ("if only one happens, make it X").

**Blocked items:** for every `⛔` node, put the concrete **unblocking action** into *The one
thing* or *Urgent* — surface it as the thing to DO, never park the blocked node in *Strategic/Open*
as if stuck = low-priority. The blocked node's own downstream work stays behind its unblocker.

After writing: bump `updated:` and refresh the **Current brief** pointer line in `[[Dashboard]]`
so the brief isn't a graph orphan.

## Slack version
Compose a **short** Slack message: the one thing, the ≤3 most urgent moves, the one-line strategic
callout, and the success test — that's it. Full detail lives in the vault brief, not Slack. The
poster takes the message as a **positional** argument (defaults to `#cc-comm`); pass multi-line
text via a variable so it stays intact:
```bash
python3 ~/.claude/bin/cc-slack-post.py "$MSG"      # prints "OK" + message ts on success
```

**When to post — depends on mode:**
- **Unattended** (`HQ_BRIEF_UNATTENDED=1` / scheduled): **post automatically**, no approval. That
  is the whole point of the Saturday job.
- **On-demand** (augmented session): posting is an outbound side effect → **show Alon the draft and
  post only after he approves** (or if he already said "post it").

## Provenance
Every claim traces to `Status.md` or a node body. Do **not** invent PRs, deadlines, review items,
or facts — if it isn't in the snapshot or a node, don't assert it. PR references are always live
links (`[owner/repo#NNN](https://github.com/owner/repo/pull/NNN)`), matching `Status.md`.

## What good looks like
> W28: *one thing* = land ARC #878 (unblocks the ⛔ benchmark paper + FA/HOCO + SAF); focus =
> #878→ready, #909 CI-red fix, freeze benchmark set (parallel, doesn't wait on #878); **needs
> fixing** = AI-Fluency node's dead `local:` pointer; Group/ViceDean/Companies = no live nodes;
> success test = #878 merged, #909 green, set frozen. Vault brief written, Dashboard pointer
> updated. Unattended (Saturday): Slack version auto-posted to `#cc-comm`. On-demand: draft shown
> to Alon first, posted on his OK.
