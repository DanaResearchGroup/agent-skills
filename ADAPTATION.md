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
| 1 | …are on any machine (everyone) | `handoff/SKILL.md`, `slack-ask/SKILL.md`, `slack-notify/SKILL.md`, `babysit-arc/SKILL.md`, `SETUP.md` | Replace hardcoded `/home/alon/...` paths with **your** home dir. Notably `handoff` saves to `/home/alon/handoffs/`, and the Slack skills call `/home/alon/.claude/bin/cc-slack-post.py`. |
| 2 | …want Slack notifications | `slack-ask/SKILL.md`, `slack-notify/SKILL.md`, `SETUP.md`, `~/.claude/settings.json` | Create your own Slack bot token (`~/.claude/.slack-bot-token`, never committed), set your channel (default is `#cc-comm` / `CC_SLACK_CHANNEL`), and allowlist the helper path. Full walkthrough in [SETUP.md](SETUP.md). Otherwise mark N/A and ignore these skills. |
| 3 | …run ARC or T3 campaigns | `babysit-arc/*`, `babysit-t3/*` (incl. `arc_babysitter.sh`, `t3_babysitter.sh`) | Set your own `zeus`/PBS account (e.g. the `alon@zeus.technion.ac.il` SSH gate), workstation paths, conda envs (`t3_env`, `~/.arc/settings.py`), and run-folder locations. These encode the author's ARC/RMG/T3 layout. N/A if you don't run ARC/T3. |
| 4 | …use an Obsidian vault | `obsidian-vault/SKILL.md`, your private `~/.claude/CLAUDE.md` | Point it at **your** vault path (the author's is under Dropbox). N/A if you don't use Obsidian. |
| 5 | …everyone (global config) | `~/.claude/CLAUDE.md` (private, **not** in this repo) | Build your own global instructions: the gstack section (added in step 3), your Obsidian path, and any personal preferences. Don't copy the author's verbatim. |

## Checklist

- [ ] 1 — Home-directory paths point at my `$HOME`
- [ ] 2 — Slack wired up (or N/A)
- [ ] 3 — ARC/T3 paths + cluster account set (or N/A)
- [ ] 4 — Obsidian vault path set (or N/A)
- [ ] 5 — My own `~/.claude/CLAUDE.md` in place
- [ ] `python3 bin/lint-skills.py` passes after my edits

## Not in this repo (install separately)

- **gstack** — README step 3.
- **Superpowers** plugin — README step 4.
