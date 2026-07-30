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

If the user asks `/handoff load`, read this session's own pointer,
`$HOME/agents/handoffs/.latest.<session-uuid>` (the uuid in your scratchpad path), then read
and present that handoff document.

If that pointer is missing, do NOT silently fall back to `$HOME/agents/handoffs/.latest` or to
"the newest file in the directory". Both are machine-wide and last-writer-wins: on a box with
several concurrent sessions they usually name somebody else's mission. Instead, list the newest
timestamped handoffs and ask the user which one to load.

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
hf="<full handoff path>"

# .latest is a SHARED, machine-wide, last-writer-wins pointer. It is for humans
# ("what handed off most recently on this box"), and it is NOT what your session
# reloads from — with several sessions running concurrently, whoever writes last
# wins and everyone else would resume the wrong mission.
tmp="$HOME/agents/handoffs/.latest.tmp"
printf '%s\n' "$hf" > "$tmp" && mv "$tmp" "$HOME/agents/handoffs/.latest"

# This is the one that matters. --handoff records the PER-SESSION reload pointer
# (.latest.<sid>) naming the file you just wrote, which is the only thing the
# watcher and the SessionStart hook will read back after compaction. Pass it
# ALWAYS: without it the helper can only copy the shared .latest, which another
# session may already have clobbered.
#
# It also files the compact-request that makes the watcher run /compact + reload
# even below the 30% threshold. No-op when autodev is not installed; defers on
# its own when the watcher is already mid-cycle.
rh="$HOME/.claude/skills/autodev/bin/request-handoff.sh"
[ -x "$rh" ] && bash "$rh" --compact-only --handoff "$hf" 2>/dev/null || true
```

**Then VERIFY the trigger exists — do not assume the script filed one.** `request-handoff.sh`
legitimately declines to file when the watcher is already mid-cycle, and it is a silent no-op
when autodev is not installed. Running it is therefore not proof that anything will happen:

```bash
sid=<session-uuid from your scratchpad path>
ls -la "$HOME/agents/state/$sid".{compact-request,handoff-request} 2>/dev/null
ls -la "$HOME/agents/handoffs/.latest.$sid" 2>/dev/null   # the reload pointer
cat "$HOME/agents/state/$sid.ctx" 2>/dev/null             # authoritative pct — never guess it
```

Resolve as follows:

- **A marker file exists** → the cycle will run. Emit the block below and end the turn.
- **No marker, but the script said it was already mid-cycle** → fine, the in-flight cycle will
  compact. This is the *normal* outcome when the watcher itself sent the `/handoff` you are
  answering: its cycle lock is live for the whole turn. Say so explicitly in your message so the
  user can see why nothing was filed, and check `.latest.$sid` below — the pointer is recorded even
  on this path, so if it is missing something else is wrong.
- **No marker and no mid-cycle** → retry the script; if it still files nothing, tell the user
  plainly that automation is not attached and ask them to run `/compact`. Never end the turn
  silently here.
- **`.latest.$sid` is missing** → the reload after compaction will deliberately fail closed
  (you will be told to re-orient from your own transcript rather than handed a handoff). Re-run
  the `--handoff` command above so the pointer exists.

The pct threshold does not fire on its own from an idle session: the Stop-hook watcher evaluates
once per turn end, and an idle session's pct never rises. `auto-handoff-sweep.sh` (systemd timer,
every few minutes) is the safety net that re-evaluates parked sessions — but it is a backstop, not
a substitute for filing and verifying the marker. Do both.

Then emit this explicit instruction block:

```text
Handoff written, .latest updated, compact-request filed.

• If this session's status line shows the 🔴 AUTO-HANDOFF badge AND the marker was verified to
  exist above: end the turn — the auto-handoff watcher will run /compact and reload at the next
  idle Stop (the verified compact-request is what makes this fire below the 30% threshold; the
  threshold alone never fires on an idle session). It CANNOT act while a background agent or
  turn is still running (input would be queued), so make sure nothing is left running.
  "Do nothing" is correct ONLY because a marker was verified — it is never correct on its own.
• If there is NO badge (an older session started before the watcher was installed, or not in
  tmux): the automation is not attached here — run /compact yourself now.

Reload contract: after compaction, the next Claude Code turn is handed THIS session's handoff to
read, via the SessionStart hook reading ~/agents/handoffs/.latest.<session-uuid>. If that pointer
is missing the reload fails closed on purpose — it will never hand you the shared ~/agents/handoffs/.latest,
because that file is machine-wide and would resume another session's mission.
```

Claude Code cannot self-trigger `/compact` — only the user or the (badge-confirmed) watcher can.
The badge is the definitive signal for whether this session has the automation attached.
