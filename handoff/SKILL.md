---
name: handoff
description: Compact the current conversation into a handoff document for another agent to pick up.
argument-hint: "What will the next session be used for?"
---

Write a handoff document summarising the current conversation so a fresh agent can continue the work. Save it into `/home/alon/handoffs/` (a persistent directory on disk that survives reboots) - not the current workspace and not the OS temp directory (the OS temp dir is wiped on every reboot). Name the file `handoff-<short-kebab-topic>.md`. Create the `/home/alon/handoffs/` directory if it does not already exist. Files in this directory older than one month are auto-pruned by a monthly cron job.

## Required sections

Every handoff MUST contain these sections, in this order. Do not drop any of them even for a "small" handoff — scale each to the work, but cover all.

1. **Broad context** — orient a reader with ZERO prior context: what this work is, why it matters, where it sits in the larger effort, and the current state (repo, branch, tip commit, what's shipped, what's green, what's pushed). Give the through-line of the whole arc, not just the latest task. Reference artifacts by path/URL for detail rather than duplicating them.
2. **Standing items** — every open thread with its state made EXPLICIT (e.g. DONE / DEFERRED-with-named-closer / BLOCKED-on-X / AWAITING-USER). Include what's waiting on the user specifically (pushes, approvals, rebases, decisions) and each blocker's unblock condition.
3. **Next phases / steps** — the concrete sequence of work the next session should pick up, in order, with any ordering constraints or dependencies between steps spelled out ("do X before Y because …").
4. **CC's recommendation** — your explicit, opinionated recommendation for how to tackle the next steps: which item to start with and why, the approach you would take, the traps to avoid, and any sequencing/leverage judgment. Make the call you would make — this is your judgment, not a neutral menu of options.
5. **Insights from this session** — the non-obvious things learned that are NOT captured in code or commits: inverted premises, false-positives found, decisions and their *why*, antipatterns avoided, dead ends not worth re-treading, and any discipline/meta-lessons. These are the most perishable and often the most valuable part of the handoff — record them so the next session does not rediscover them the hard way.
6. **Suggested skills** — skills the next agent should invoke (e.g. brainstorming, writing-plans, subagent-driven-development), each with a one-line reason.

## Rules

- Do not duplicate content already captured in other artifacts (PRDs, plans, ADRs, issues, commits, diffs). Reference them by path or URL instead — but DO synthesise the through-line and the cross-artifact state that no single document captures.
- Redact any sensitive information, such as API keys, passwords, or personally identifiable information.
- If the user passed arguments, treat them as a description of what the next session will focus on and tailor the doc's emphasis accordingly — but still include ALL required sections above; the arguments shape emphasis, not coverage.
