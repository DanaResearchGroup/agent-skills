# Compounding — capture what should change the next session

A learning is something that should change how the **next** session behaves in this project: a
gate that lies, a suite that passes for the wrong reason, a tool whose defaults are a trap, a
preference you were told rather than guessed. A finding that merely describes the current diff is
not a learning — it belongs in the review artifact, which is about the diff and dies with it.

The store is `~/.skills/projects/<slug>/learnings.jsonl`, one canonical location per project.
Reach it through the absolute path below, never a repo-relative `bin/`: a relative lookup resolves
against whatever the cwd happens to be, and that is exactly how a shadow copy of these scripts in
one repo silently swallowed a store's worth of entries that nothing ever read back.

## Writing one

```bash
~/.claude/skills/bin/skill-learnings-log '{"type":"pitfall","key":"<kebab-slug>","insight":"...","confidence":8,"source":"observed"}'
```

- `type` — one of `pattern`, `pitfall`, `preference`, `architecture`, `tool`, `operational`,
  `investigation`. Anything else is rejected rather than coerced, so do not invent one.
- `key` — a kebab slug, and the dedupe handle. **Re-logging a key supersedes it**: the old line
  stays as history and searches return only the newest. Say in the insight that you are
  superseding and why — a learning that turned out half-right is itself worth knowing, and the
  most useful ones usually do.
- `confidence` — 1-10.
- `source` — `observed`, `user-stated`, `inferred`, `cross-model`. `user-stated` marks the record
  `trusted`; everything else is your own inference and a later reader weighs it accordingly. Never
  claim `user-stated` for something you concluded.

The insight is read back into a future agent's context, so it is an injection surface. The tool
rejects instruction-shaped text: write a fact about this project, not a directive to whoever
reads it next.

## Reading them back

```bash
~/.claude/skills/bin/skill-learnings-search --limit 5             # newest first
~/.claude/skills/bin/skill-learnings-search --type pitfall
~/.claude/skills/bin/skill-learnings-search --query parity        # substring match
```

Those three flags are the whole interface — `--type`, `--query`, `--limit`. There are no
positional search terms and no `--repo`: the project is resolved from your cwd via `skill-slug`,
so a search run outside the project it belongs to silently reads a different store, or none.

The output is written to be pasted into a subagent brief as-is.

## When to capture

At moments that already recur **and** already end in a judgement. A capture point bolted to a
skill nobody runs accumulates nothing — that is the entire failure mode, and the reason this list
is short and specific rather than "whenever you learn something".

| Point | Log when |
|---|---|
| [`spar`](spar/SKILL.md) | a Codex finding was confirmed against the code — above all one that inverted a premise you held |
| [`copilot-review`](copilot-review/SKILL.md) | a finding triaged as **address** turned out to be a defect *class*, not a one-off |
| [`merged`](merged/SKILL.md) | the review cycle taught something the two above did not already log |
| [`framing-decisions`](framing-decisions/SKILL.md) | the user overrode you — see below |
| [`fleet-review`](fleet-review/SKILL.md) | a finding meets the bar named in its own step |

**One learning per call.** Several in a session means several calls, each with its own key.
Batched into one record, everything after the first becomes unsearchable.

Logging is never a reason to stop, and never something to ask about. It is one command at the end
of work you were doing anyway; if it fails, say so in a line and carry on.

## The override rule

The highest-signal event available is the user picking something other than what you recommended,
rewriting an option, adding to the menu where you offered a choice, or rejecting the frame
outright. That is the moment your model of what they want was demonstrably wrong — worth more
than any amount of unprompted inference.

Log those as `"type":"preference","source":"user-stated"`.

Do **not** log every answered question. Most decisions are situational, and a store full of
one-off choices buries the few that generalise. The test is whether it would change your default
next time, in this project, on a question you have not been asked yet.

**What does not belong here:** how the user wants to be worked with *across* projects — tone,
cadence, what to ask about — is a memory file. This store is scoped to one project and answers
only "what does the next agent working here need to know".
