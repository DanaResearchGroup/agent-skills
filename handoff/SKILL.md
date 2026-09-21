---
name: handoff
description: Compact the current conversation into a handoff document for another agent to pick up.
argument-hint: "What will the next session be used for?"
---

Write or load a handoff document so a fresh agent can continue the work after compaction.

Explicit invocation is runtime-specific: Claude Code uses `/handoff`; Codex uses `$handoff`.

Save handoffs into `$HOME/agents/handoffs/` - not the current workspace and not the OS temp
directory. Create the directory if it does not already exist. Name new files:
`$(date +"%Y.%m.%d %H.%M.%S") handoff-<short-kebab-topic>.md`.

Files in `$HOME/agents/handoffs/` older than one month are auto-pruned by an external monthly
cron job. If the cron still targets `$HOME/handoffs/`, update it outside this skill.

## Load

If the user asks `/handoff load` (Claude Code) or `$handoff load` (Codex), resolve this session's
identity exactly as the writer does: `${CLAUDE_CODE_SESSION_ID}` for Claude Code, or
`${CODEX_SESSION_ID:-${CODEX_THREAD_ID:-}}` for Codex. Read
`$HOME/agents/handoffs/.latest.<resolved-session-id>`, then read and present that handoff document.
Do not infer a Codex identity from a scratchpad path.

If that pointer is missing, do NOT silently fall back to `$HOME/agents/handoffs/.latest` or to
"the newest file in the directory". Both are machine-wide and last-writer-wins: on a box with
several concurrent sessions they usually name somebody else's mission. Instead, list the newest
timestamped handoffs and ask the user which one to load.

## Required sections

Every handoff MUST contain these sections, in this order. Do not drop any of them even for a "small" handoff — scale each to the work, but cover all.

1. **Broad context** — orient a reader with ZERO prior context: what this work is, why it matters, where it sits in the larger effort, and the current state (repo, branch, tip commit, what's shipped, what's green, what's pushed). Give the through-line of the whole arc, not just the latest task. Reference artifacts by path/URL for detail rather than duplicating them.
2. **Standing items** — every open thread with its state made EXPLICIT (e.g. DONE / DEFERRED-with-named-closer / BLOCKED-on-X / AWAITING-USER). Include what's waiting on the user specifically (pushes, approvals, rebases, decisions) and each blocker's unblock condition.
3. **Next phases / steps** — the concrete sequence of work the next session should pick up, in order, with any ordering constraints or dependencies between steps spelled out ("do X before Y because …").
4. **Recommendation** — your explicit, opinionated recommendation for how to tackle the next steps: which item to start with and why, the approach you would take, the traps to avoid, and any sequencing/leverage judgment. Make the call you would make — this is your judgment, not a neutral menu of options.
5. **Insights from this session** — the non-obvious things learned that are NOT captured in code or commits: inverted premises, false-positives found, decisions and their *why*, antipatterns avoided, dead ends not worth re-treading, and any discipline/meta-lessons. These are the most perishable and often the most valuable part of the handoff — record them so the next session does not rediscover them the hard way. Write every one of them down here; the only question is whether a *copy* also belongs somewhere permanent. Handoffs are pruned after a month, so an insight that would still be true long after this work ends outlives its handoff: if the project has a durable home for it — a PM repo's `INSIGHTS.md`, an ADR, the repo's own docs — put it there too and cite that path here. Where no such home exists, this section is the home.
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
# even below the 35% threshold. No-op when autodev is not installed; defers on
# its own when the watcher is already mid-cycle.
rh=""
for root in "$HOME/.agents/skills" "$HOME/.claude/skills" "$HOME/.codex/skills"; do
  [ -x "$root/autodev/bin/request-handoff.sh" ] && { rh="$root/autodev/bin/request-handoff.sh"; break; }
done
[ -x "$rh" ] && bash "$rh" --compact-only --handoff "$hf" 2>/dev/null || true
```

**ALWAYS print the handoff's absolute path to the user — every time, no exceptions.** The full
expanded path exactly as `$hf` holds it: not `~/agents/handoffs/…`, not a bare filename, not "the
handoff file". The user has to open, move, or hand that file to another session, and a path they
must reconstruct is a path they cannot click. This holds when the write was routine, when a tool
call already showed the filename, and when nothing else in the turn is worth saying.

**Then VERIFY the trigger exists — do not assume the script filed one.** `request-handoff.sh`
legitimately declines to file when the watcher is already mid-cycle, and it is a silent no-op
when autodev is not installed. Running it is therefore not proof that anything will happen:

```bash
sid="${CLAUDE_CODE_SESSION_ID:-${CODEX_SESSION_ID:-${CODEX_THREAD_ID:-}}}"
ls -la "$HOME/agents/state/$sid".{compact-request,handoff-request} 2>/dev/null
ls -la "$HOME/agents/handoffs/.latest.$sid" 2>/dev/null   # the reload pointer
cat "$HOME/agents/state/$sid.ctx" 2>/dev/null             # authoritative pct — never guess it
```

Resolve as follows:

- **A marker file exists** → the cycle will run. Emit the block below and end the turn.
- **No marker, but the script said it was already mid-cycle** → fine, the in-flight cycle will
  compact. This is the *normal* outcome when the watcher itself invoked the handoff skill you are
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
Handoff written: <absolute path — the full expanded $hf, always, no exceptions>
.latest updated, compact-request filed.

• End the turn only when the marker and this session's registered pane were verified above. The
  watcher will run /compact and reload at the next idle Stop; the marker is what makes this fire
  below the 35% threshold. It cannot act while a background agent or turn is still running because
  input would be queued. "Do nothing" is correct only because the state was verified.
• Claude Code also shows the 🔴 AUTO-HANDOFF badge when attached. Codex uses its native status
  line and has no custom badge, so its marker, `.ctx`, `.runtime`, and registered pane files are
  the authority. If the required state is absent, run /compact yourself now.

Reload contract: after compaction, the next agent turn is handed THIS session's handoff to read,
via the SessionStart hook reading ~/agents/handoffs/.latest.<resolved-session-id> (using
CLAUDE_CODE_SESSION_ID, or CODEX_SESSION_ID with CODEX_THREAD_ID as its fallback). If that pointer
is missing the reload fails closed on purpose — it will never hand you the shared ~/agents/handoffs/.latest,
because that file is machine-wide and would resume another session's mission.
```

The agent cannot self-trigger the interactive `/compact` command — only the user or the
state-verified watcher can. On Codex, the watcher confirms the command only when the pane visibly
contains an explicit compact/summarize confirmation prompt.
