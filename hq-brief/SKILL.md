---
name: hq-brief
description: Use when Alon wants his weekly HQ focus brief — what to focus on this week across his hats — or asks to run hq-brief, write/refresh the weekly briefing, or "what should I focus on this week". Also at the start of a new work-week in HQ.
---

# hq-brief — write the weekly HQ focus brief

Produce the **one artifact that tells Alon what to focus on this week** across the six hats, save
it to the vault, and (with his OK) post a short version to Slack. **HQ's `CLAUDE.md` is the source
of truth** for the schema, traffic-light rule, and governance — read it; this skill only
orchestrates and **must not duplicate its depth**. Vault: `~/Dropbox/Apps/remotely-save/Vault/`.

This is an **augmented** skill — a CC session runs it *with* Alon. It is NOT the deterministic
cron job. Do **not** wire it into unattended cron: a weekly brief is a judgment artifact, and
`Design.md` §Freshness reserves the scheduled job for deterministic pulls only.

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

1. **The one thing** — the single highest-leverage move this week, with *why* (what it unblocks).
2. **Focus this week** — ordered list, **≤ ~4 items**, each a concrete verb-first action linked to
   its node.
3. **Also on radar** — don't-start-don't-drop items, one line each.
4. **Needs fixing** — every integrity flag Status.md raised (`⚠ dead local:`, `🕸 stale`, dead
   repo pointer) becomes a fix-action here. **Never smooth a broken pointer into "keep warm."**
   Write "none" if Status.md raised none.
5. **Deferred — deliberately not this week** — with the reason (usually a far deadline).
6. **Hat load at a glance** — a 6-row table (hat · live light · this week).
7. **Success test** — "By Friday: …", plus the tie-breaker ("if only one happens, make it X").

**Blocked items:** for every `⛔` node, put the concrete **unblocking action** into *The one
thing* or *Focus* — surface it as the thing to DO, never park the blocked node in *Deferred* as if
stuck = low-priority. The blocked node's own downstream work stays behind its unblocker.

After writing: bump `updated:` and refresh the **Current brief** pointer line in `[[Dashboard]]`
so the brief isn't a graph orphan.

## Slack version — draft, then post ONLY on Alon's OK
Compose a **short** Slack message: the one thing, ≤3 focus items, the Friday success test — that's
it. Full detail lives in the vault brief, not Slack.

Posting to Slack is an **outbound side effect** → show Alon the draft and post only after he
approves (or if he already said "post it"). The poster takes the message as a **positional**
argument (defaults to `#cc-comm`); pass multi-line text via a variable so it stays intact:
```bash
python3 ~/.claude/bin/cc-slack-post.py "$MSG"      # prints "OK" + message ts on success
```
Never auto-post from an unattended context.

## Provenance
Every claim traces to `Status.md` or a node body. Do **not** invent PRs, deadlines, review items,
or facts — if it isn't in the snapshot or a node, don't assert it. PR references are always live
links (`[owner/repo#NNN](https://github.com/owner/repo/pull/NNN)`), matching `Status.md`.

## What good looks like
> W28: *one thing* = land ARC #878 (unblocks the ⛔ benchmark paper + FA/HOCO + SAF); focus =
> #878→ready, #909 CI-red fix, freeze benchmark set (parallel, doesn't wait on #878); **needs
> fixing** = AI-Fluency node's dead `local:` pointer; Group/ViceDean/Companies = no live nodes;
> success test = #878 merged, #909 green, set frozen. Vault brief written, Dashboard pointer
> updated, Slack draft shown to Alon — posted after his OK.
