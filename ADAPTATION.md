# Adapting these skills to your setup

Several skills were written on the author's machine and assume our group's infrastructure.
This file is the **canonical catalog** of every spot a new group member may need to change.

**How to use it:** run the audit prompt in [README.md → step 2](README.md#2-find-which-skills-you-need-to-adapt)
to get a personal checklist, then work down the table below. Tick a row when it's done or N/A.
After edits, run `python3 bin/lint-skills.py` to confirm nothing broke.

> **Keep this current:** when you add a new machine- or group-specific assumption to a skill,
> add a row here. The whole point is that no assumption stays hidden.

## Adaptation points

| # | Applies if you… | Files | What to change |
| --- | --- | --- | --- |
| 1 | …are on any machine (everyone) | `handoff/SKILL.md`, `slack-ask/SKILL.md`, `slack-notify/SKILL.md`, `SETUP.md`, `~/.claude/settings.json` | Repo docs use `$HOME/...` and usually need no home-dir edits. `handoff` saves to `$HOME/agents/handoffs/`, and the Slack skills call `$HOME/.claude/bin/cc-slack-post.py`. The `~/.claude/settings.json` allow-rule is the exception: write the literal absolute helper path there, because allow-rules do not expand `$HOME`. |
| 2 | …want Slack notifications | `slack-ask/SKILL.md`, `slack-notify/SKILL.md`, `SETUP.md`, `~/.claude/settings.json` | Create your own Slack bot token (`~/.claude/.slack-bot-token`, never committed), set your channel id in `CC_SLACK_CHANNEL` (required — the helper refuses to send without it), and allowlist the helper path. Full walkthrough in [SETUP.md](SETUP.md). Otherwise mark N/A and ignore these skills. |
| 3 | …use an Obsidian vault | `obsidian-vault/SKILL.md`, your private `~/.claude/CLAUDE.md` | Point it at **your** vault path (the author's is under Dropbox). N/A if you don't use Obsidian. |
| 4 | …everyone (global config) | `~/.claude/CLAUDE.md` (private, **not** in this repo) | Build your own global instructions: your Obsidian path and any personal preferences. Don't copy the author's verbatim. |

## Deliberate drift from upstream (vendored Matt Pocock skills)

These are intentional local edits to vendored skills. `/sync-matt-pocock-skills` must
re-apply each one onto the new upstream base at every sync (current base: v1.2.2):

| File | Local edit |
| --- | --- |
| `grilling/SKILL.md` | Present each round's questions through the `AskUserQuestion` tool with 2-4 concrete options; the recommended answer is the first option, marked "(Recommended)"; upstream's prose format is kept as the fallback for questions that can't be framed as options. (Originally applied to `grill-me` before upstream moved the family's content into `grilling`.) |
| `grill-with-docs/SKILL.md` | Typo fix in the description: "ADR's" → "ADRs". |

## Checklist

- [ ] 1 — Home-directory paths point at my `$HOME`
- [ ] 2 — Slack wired up (or N/A)
- [ ] 3 — Obsidian vault path set (or N/A)
- [ ] 4 — My own `~/.claude/CLAUDE.md` in place
- [ ] `python3 bin/lint-skills.py` passes after my edits

## Not in this repo (install separately)

- **Superpowers** plugin — README step 3.
