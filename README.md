# agent-skills

[![CI](https://github.com/DanaResearchGroup/agent-skills/actions/workflows/ci.yml/badge.svg)](https://github.com/DanaResearchGroup/agent-skills/actions/workflows/ci.yml)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-skills-8A2BE2)](https://docs.anthropic.com/en/docs/claude-code)
[![skills](https://img.shields.io/badge/skills-31-blue)](#whats-in-here)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Personal [Claude Code](https://docs.anthropic.com/en/docs/claude-code) skills for our
research group. A skill is a Markdown playbook (`<skill>/SKILL.md`) that Claude Code loads
on demand — debugging discipline, TDD, running ARC/T3 campaigns, Slack
notifications, and more.

This repo **is** your skills directory: you symlink the whole thing into
`~/.claude/skills`, so every skill here becomes available in Claude Code everywhere.

> **New group member?** Do the three steps below in order. Budget ~15 minutes.

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and signed in
  (`claude --version` works).
- `git` and `python3`.

## Setup

### 1. Clone and make it your skills directory

```bash
git clone https://github.com/DanaResearchGroup/agent-skills ~/Code/agent-skills
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

### 3. Install the Superpowers plugin

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
| **Notifications** | `slack-ask`, `slack-notify` — reach you over Slack during unattended runs |
| **Matt Pocock** ([`mattpocock/skills`](https://github.com/mattpocock/skills), MIT — see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)) | `tdd`, `to-spec`, `implement`, `code-review`, `domain-modeling`, `grilling`, `grill-me`, `grill-with-docs`, `resolving-merge-conflicts`, `setup-matt-pocock-skills`, `writing-for-agents`, `handoff`, `obsidian-vault` |
| **Review** | `fleet-review` — pre-landing review of a PR or diff, sizing the agent fleet to the change's breadth and routing each pass to a model that fits its job; `copilot-review` — fold a PR's Copilot/security bot review back into history; `drop-review` — drop the review you just ran as a markdown artifact in the OS temp directory, written for the session that wrote the code |
| **Workflow** | `writing-git-commits`; `contract` — settle what a change must do, and how you'll know it did it, before writing it; `merged` — after a PR lands, sync `main` and rebase the open PRs onto it; `sync-matt-pocock-skills` — pull a newer `mattpocock/skills` release into our vendored copies, keeping local edits; `writing-great-skills` — this repo's skill-authoring conventions, a thin wrapper over `writing-for-agents`; `framing-decisions` — put one decision at a time to the user: solve it as the field's expert first, audit that the option set can even hold that answer (parent settled, mechanisms composed, premise named), then send it through `AskUserQuestion` explained, with the next question re-derived from the last answer; `ask-me` — sweep a conversation for every decision left buried in prose, softened, deferred, or silently settled, cut what changes nothing, order the rest by fan-out, and gate each one through `framing-decisions` |
| **Epistemics** | `probe` — check a load-bearing premise empirically before you propose or build on it, and report what you could not reach; `meta-analysis` — post-mortem how a long conversation or campaign actually moved: inflection ledger, input-yield scoreboard, failure modes with tripwires, and forward predictions that get scored rather than deleted |
| **Research writing** | `paper-outline` — plan a scientific paper with you by filling out the group's Outline document, one decision at a time |
| **Autonomous development** | `autodev` — drive a large feature build end-to-end in one autonomous session, with adversarial Codex review at every milestone and automatic context handoff/compact/resume past 35%; `spar` — run an adversarial "try to break this" Codex sparring round against your current code, plan, or decision, persisted per-project; `herdr` — inspect and control Herdr (a terminal multiplexer for coding agents) panes, tabs, workspaces, and cross-agent communication |

Plus the **Superpowers** plugin (step 3).

## Recommended workflow

The Matt Pocock engineering skills chain into one *idea → shipped* flow. For a
non-trivial feature, drive them in order:

1. **`/grill-with-docs`** — interview the idea into a sharp, documented design
   (ADRs + glossary).
2. **`/to-spec`** — synthesize the conversation into a spec on your issue tracker.
3. **`/implement`** — build against the spec; drives **`/tdd`** as its red-green engine.
4. **`/code-review`** — review the diff against your repo's standards and the spec.

Run **`/setup-matt-pocock-skills`** once per repo first, so the skills know where
your issue tracker, triage labels, and domain docs live.

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
- **Superpowers** (step 3) ships its own Codex/Copilot/Gemini install — see
  [its docs](https://github.com/obra/superpowers).
- Skills that dispatch sub-agents need Codex's multi-agent tools enabled in `~/.codex/config.toml`.

## Maintaining this repo

- **Lint locally before pushing:** `python3 bin/lint-skills.py` (also runs in CI on every PR).
- **Adding a new top-level skill or root file?** `.gitignore` is deny-by-default — everything at
  the repo root is ignored unless explicitly re-included with a `!/name/` (or `!/name.md`) line.
  A brand-new skill directory or a new root file like `CONTRIBUTING.md` is otherwise silently
  invisible to `git add`: no error, just nothing staged. `lint-skills.py` catches this locally
  (it can't run in CI — an ignored, never-staged file never reaches CI) and tells you the exact
  `.gitignore` line to add.
- CI also runs a [gitleaks](https://github.com/gitleaks/gitleaks) secret scan — never commit
  tokens. The Slack bot token lives outside the repo (see [SETUP.md](SETUP.md)). Scan scope,
  history policy, and how to report a finding: [SECURITY.md](SECURITY.md).
- Pull vendored skill updates from upstream (Matt Pocock) with the `sync-matt-pocock-skills` skill —
  it reconciles our copies with a new [`mattpocock/skills`](https://github.com/mattpocock/skills)
  release while preserving local edits.

## License

[MIT](LICENSE) © 2026 Alon Grinberg Dana.

Bundled third-party skills retain their own copyright and license — see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
