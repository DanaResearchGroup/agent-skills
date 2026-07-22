---
name: handoff
description: Compact the current conversation into a handoff document for another agent to pick up.
argument-hint: "What will the next session be used for?"
---

Write or load a handoff document so a fresh agent can continue the work after compaction.

Save handoffs into `$HOME/agents/handoffs/` - not the current workspace and not the OS temp
directory. Create the directory if it does not already exist. Name new files:
`$(date +"%Y.%m.%d %H.%M.%S") handoff-<short-kebab-topic>.md`.

Files in `$HOME/agents/handoffs/` older than one month are auto-pruned by an external monthly
cron job. If the cron still targets `$HOME/handoffs/`, update it outside this skill.

## Load

If the user asks `/handoff load`, read `$HOME/agents/handoffs/.latest`, then read and present
that handoff document. If `.latest` is missing or points to a missing file, list the newest
timestamped handoffs in `$HOME/agents/handoffs/` and ask which one to load.

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

## Write Workflow

Before writing, migrate old handoffs once if needed. Preserve the `~/agents/` timestamp naming
convention by prefixing each migrated file with its original modification time:

```bash
mkdir -p "$HOME/agents/handoffs"
for f in "$HOME"/handoffs/*.md; do
  [ -e "$f" ] || continue
  epoch=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")
  ts=$(date -d "@$epoch" +"%Y.%m.%d %H.%M.%S" 2>/dev/null || date -r "$epoch" +"%Y.%m.%d %H.%M.%S")
  base=$(basename "$f")
  mv "$f" "$HOME/agents/handoffs/$ts $base"
done
```

When composing **Standing items**, cross-reference by path:

- latest sparring artifacts under `~/agents/adversarial/{slug}/`, including `.session-id`,
  `sparring-log.md`, and the latest round Q/A if present;
- latest gstack checkpoint if present.

After writing the handoff, update the deterministic reload pointer, then file a
compact-request so the auto-handoff watcher (if installed) finishes the cycle:

```bash
tmp="$HOME/agents/handoffs/.latest.tmp"
printf '%s\n' "<full handoff path>" > "$tmp" && mv "$tmp" "$HOME/agents/handoffs/.latest"

# Tell the auto-handoff watcher a handoff is ready so it runs /compact + reload on
# its own — even below the 30% context threshold. Without this a below-threshold
# /handoff would leave the watcher with no trigger and it would never compact.
# No-op when autodev is not installed; defers automatically when the watcher is
# already mid-cycle (it will compact itself); also snapshots .latest per-session.
rh="$HOME/.claude/skills/autodev/bin/request-handoff.sh"
[ -x "$rh" ] && bash "$rh" --compact-only 2>/dev/null || true
```

Then emit this explicit instruction block:

```text
Handoff written, .latest updated, compact-request filed.

• If this session's status line shows the 🔴 AUTO-HANDOFF badge: do NOTHING — the auto-handoff
  watcher will run /compact and reload automatically at the next idle Stop (the compact-request
  filed above makes this fire even below the 30% threshold). It CANNOT act while a background
  agent or turn is still running (input would be queued), so make sure nothing is left running
  and end the turn.
• If there is NO badge (an older session started before the watcher was installed, or not in
  tmux): the automation is not attached here — run /compact yourself now.

Reload contract: after compaction, the next Claude Code turn is handed the handoff to read (via
the SessionStart hook, or `cat ~/agents/handoffs/.latest`) and re-orients from it before continuing.
```

Claude Code cannot self-trigger `/compact` — only the user or the (badge-confirmed) watcher can.
The badge is the definitive signal for whether this session has the automation attached.
