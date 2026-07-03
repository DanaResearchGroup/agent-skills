# agent-skills

[![CI](https://github.com/alongd/agent-skills/actions/workflows/ci.yml/badge.svg)](https://github.com/alongd/agent-skills/actions/workflows/ci.yml)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-skills-8A2BE2)](https://docs.anthropic.com/en/docs/claude-code)
[![skills](https://img.shields.io/badge/skills-20-blue)](#whats-in-here)
[![secret scan](https://img.shields.io/badge/secret%20scan-gitleaks-success)](https://github.com/alongd/agent-skills/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Personal [Claude Code](https://docs.anthropic.com/en/docs/claude-code) skills for our
research group. A skill is a Markdown playbook (`<skill>/SKILL.md`) that Claude Code loads
on demand — debugging discipline, TDD, issue triage, running ARC/T3 campaigns, Slack
notifications, and more.

This repo **is** your skills directory: you symlink the whole thing into
`~/.claude/skills`, so every skill here becomes available in Claude Code everywhere.

> **New group member?** Do the four steps below in order. Budget ~15 minutes.

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and signed in
  (`claude --version` works).
- `git` and `python3`.

## Setup

### 1. Clone and make it your skills directory

```bash
git clone https://github.com/alongd/agent-skills ~/Code/agent-skills
ln -s ~/Code/agent-skills ~/.claude/skills
```

Open a Claude Code session — the personal skills are now live. (The **Slack** skills need
a little extra per-machine wiring; see [SETUP.md](SETUP.md).)

### 2. Find which skills you need to adapt

Several skills carry assumptions from the original author's machine and our group's
infrastructure — hardcoded home paths, a specific Slack channel, the `zeus` cluster, the
ARC/T3 workflow, an Obsidian vault. **[ADAPTATION.md](ADAPTATION.md) is the canonical list
of every such spot.**

Get your *personal* punch-list by letting Claude Code audit the repo against it:

```bash
cd ~/Code/agent-skills
claude "Read ADAPTATION.md, then review each adaptation point against my setup. Ask me
what I actually use (Slack? Obsidian? ARC/T3 on zeus? my home directory?), then give me
an exact, file-and-line checklist of what I must change — and mark the rest N/A."
```

Work through the list it produces. Re-run `python3 bin/lint-skills.py` after edits to make
sure you didn't break a skill.

### 3. Install gstack

[gstack](https://github.com/garrytan/gstack) is a separate suite of ~23 skills (review, QA,
ship, design, browse, …). Easiest path — paste this to a Claude Code session and let it run:

> Install gstack: run `git clone --single-branch --depth 1 https://github.com/garrytan/gstack.git ~/.claude/skills/gstack && cd ~/.claude/skills/gstack && ./setup`, then add a "gstack" section to my CLAUDE.md listing the available gstack skills and telling you to use `/browse` for all web browsing.

Because `~/.claude/skills` is this repo, gstack lands in `agent-skills/gstack/` and its skills
sync into top-level folders. Those are **git-ignored** (see [.gitignore](.gitignore)) — don't
commit them; update gstack with `/gstack-upgrade`.

### 4. Install the Superpowers plugin

[Superpowers](https://github.com/obra/superpowers) is a Claude Code **plugin** (not a skill in
this repo) that adds disciplines like brainstorming, systematic-debugging, and TDD. Install it
from the official marketplace inside a Claude Code session:

```text
/plugin install superpowers@claude-plugins-official
```

If that marketplace isn't registered yet, add it first, then install:

```text
/plugin marketplace add obra/superpowers-marketplace
/plugin install superpowers@superpowers-marketplace
```

Verify with `/plugin` — you should see `superpowers` enabled. Full docs:
<https://github.com/obra/superpowers>.

### Optional extras

- **[ui-ux-pro-max](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill)** — a UI/UX
  design plugin (web & mobile). Only useful if you build UIs/dashboards; not needed for
  research work. Install with `git clone https://github.com/nextlevelbuilder/ui-ux-pro-max-skill.git ~/.claude/skills/ui-ux-pro-max-skill`.

## What's in here

| Group | Skills |
| --- | --- |
| **Research automation** | `babysit-arc`, `babysit-t3` — run/babysit ARC & T3 campaigns -- Please **NEVER** automate agents on a server without consulting the server owner (your PI) first! |
| **Notifications** | `slack-ask`, `slack-notify` — reach you over Slack during unattended runs |
| **Matt Pocock** ([`mattpocock/skills`](https://github.com/mattpocock/skills), MIT — see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)) | `tdd`, `to-issues`, `to-prd`, `triage`, `prototype`, `codebase-design`, `domain-modeling`, `improve-codebase-architecture`, `grill-me`, `grill-with-docs`, `resolving-merge-conflicts`, `setup-matt-pocock-skills`, `writing-great-skills`, `handoff`, `edit-article`, `obsidian-vault` |
| **Workflow** | `writing-git-commits`, `copilot-review` — fold a PR's Copilot/security bot review back into history |

Plus **gstack** (installed in step 3) and the **Superpowers** plugin (step 4).

## Other agents (Codex, Copilot CLI, Gemini)

The skills here are **agent-agnostic in format**: a `<skill>/SKILL.md` with `name`/`description`
frontmatter is loaded natively by Claude Code, OpenAI Codex, Copilot CLI, and Gemini CLI alike.
What changes per agent is **where you symlink the repo**:

| Agent | Skills directory (symlink target for step 1) |
| --- | --- |
| Claude Code | `~/.claude/skills` |
| Codex | `~/.codex/skills` (or the shared `~/.agents/skills`) |
| Copilot CLI / Gemini CLI | `~/.agents/skills` (shared cross-runtime path) |

So on Codex, do step 1 as `ln -s ~/Code/agent-skills ~/.codex/skills` instead. Caveats:

- The **Slack** and **babysit** skills hard-code `~/.claude/...` paths — adapt them to your
  agent's home (e.g. `~/.codex`) per [ADAPTATION.md](ADAPTATION.md).
- **gstack** (step 3) is Claude-Code-specific — skip it on other agents.
- **Superpowers** (step 4) ships its own Codex/Copilot/Gemini install — see
  [its docs](https://github.com/obra/superpowers).
- Skills that dispatch sub-agents need Codex's multi-agent tools enabled in `~/.codex/config.toml`.

## Maintaining this repo

- **Lint locally before pushing:** `python3 bin/lint-skills.py` (also runs in CI on every PR).
- CI also runs a [gitleaks](https://github.com/gitleaks/gitleaks) secret scan — never commit
  tokens. The Slack bot token lives outside the repo (see [SETUP.md](SETUP.md)).
- Pull skill updates from upstream (Matt Pocock): <https://github.com/mattpocock/skills>.

## License

[MIT](LICENSE) © 2026 Alon Grinberg Dana.

Bundled third-party skills retain their own copyright and license — see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
