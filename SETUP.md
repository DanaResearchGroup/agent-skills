# Setup

Personal Claude Code skills. Most skills are self-contained — clone, symlink into
`~/.claude/skills`, done. The **Slack skills** (`slack-ask`, `slack-notify`) need
a little extra per-machine wiring (a bot token + an allowlist) so they can notify
you and run unattended.

## New member — Claude Code only (start here)

The minimal path to mirror the environment. Skips Codex, Slack, and MCP for now
(see [DRGScripts/onboarding/ONBOARDING.md](https://github.com/DanaResearchGroup/DRGScripts/blob/main/onboarding/ONBOARDING.md)
for the full guided runbook your Claude Code can execute).

```bash
# 1. Clone (not fork) into ~/Code
git clone https://github.com/DanaResearchGroup/agent-skills ~/Code/agent-skills

# 2. Make it your Claude Code skills dir
ln -s ~/Code/agent-skills ~/.claude/skills

# 3. Wire the context-% status line in ~/.claude/settings.json:
#      "statusLine": { "type": "command",
#        "command": "<absolute path to>/agent-skills/bin/cc-statusline.sh" }
chmod +x ~/Code/agent-skills/bin/cc-statusline.sh
```

Updates later: see [UPDATING.md](./UPDATING.md) (or tell Claude Code "update my
agent-skills"). That is all the non-Slack skills need.

## Quick start (any machine)

```bash
# 1. Clone this repo
git clone https://github.com/DanaResearchGroup/agent-skills ~/Code/agent-skills

# 2. Make it your skills dir (whole repo) + link the Slack sender
ln -s ~/Code/agent-skills ~/.claude/skills
mkdir -p ~/.claude/bin
ln -s ~/Code/agent-skills/bin/cc-slack-post.py ~/.claude/bin/cc-slack-post.py
chmod +x ~/Code/agent-skills/bin/cc-slack-post.py
```

That's all that's needed for the non-Slack skills. For Slack, continue below.

## Slack skills — extra wiring

The Slack skills talk to a private channel **#cc-comm** and use a **hybrid**
design: they **send** as a Slack bot (so you actually get a notification) and
**read** your replies through the claude.ai Slack connector. Two things travel
with the repo (the wrapper script + the skills); two things are per-machine and
**never** committed (the bot token + the allowlist).

### 1. Slack connector (read side) — automatic
Sign into the **same claude.ai account** in Claude Code. The Slack connector
follows your account, so `claude mcp list` should show
`claude.ai Slack … ✓ Connected`. No per-machine config.

### 2. Bot token (send side) — the only secret
Create once (workspace-global; reuse the same token on every machine):
1. https://api.slack.com/apps → **Create New App → From scratch** → pick the
   workspace.
2. **OAuth & Permissions** → Bot Token Scopes → add **`chat:write`** →
   **Install to Workspace** → copy the **Bot User OAuth Token** (`xoxb-…`).
3. In Slack, invite the bot to the channel: `/invite @<your app>` in **#cc-comm**.
4. Note the channel's id for the next step: channel name → **About** →
   **Copy channel ID** (ids look like `C0123456789`).

Place the token on each machine (keep it out of git **and** out of shell
history — `read -s` takes the value from the terminal without echoing it or
passing it as a command-line argument):
```bash
install -m 600 /dev/null ~/.claude/.slack-bot-token
read -r -s -p 'Slack bot token: ' token
printf '%s' "$token" > ~/.claude/.slack-bot-token && unset token
```
If you ever entered the token as a literal command-line argument instead (an
earlier revision of this page showed that form), treat it as exposed — it is
recorded in your shell history — and rotate it: reinstall the app at
api.slack.com to mint a fresh token, then redo this step.

### 3. Channel id + allowlist — per machine
Merge into `~/.claude/settings.json` (not in this repo), with your own channel
id from step 2 (there is no default channel — the helper refuses to send
without `CC_SLACK_CHANNEL`):
```json
{
  "env": {
    "CC_SLACK_CHANNEL": "C0123456789"
  },
  "permissions": {
    "allow": [
      "Bash(/home/USER/.claude/bin/cc-slack-post.py:*)",
      "Bash(sleep:*)",
      "mcp__claude_ai_Slack__slack_read_thread",
      "mcp__claude_ai_Slack__slack_search_channels"
    ]
  }
}
```
Replace `/home/USER` with your actual absolute home path (for example,
`/Users/alice` on macOS).

### 4. Verify
Open a Claude Code session and say *"use slack-notify to send a test ping"*.
You should get a Slack notification in **#cc-comm** with no permission prompt.

## Configuration reference

The sender (`bin/cc-slack-post.py`) reads:

| Env var | Default | Meaning |
|---|---|---|
| `CC_SLACK_CHANNEL` | — (required) | Target channel id, e.g. `C0123456789`; set to a member id to DM. The helper exits with an error when unset |
| `CC_SLACK_TOKEN_FILE` | `~/.claude/.slack-bot-token` | Path to the `xoxb-` token |

The `slack-ask` skill additionally reads `CC_SLACK_USER` — your own Slack member id, e.g.
`U0123456789` (Profile → ⋮ → Copy member ID). It is how the skill tells your reply from the bot's
or anyone else's, so a thread answer is only recognised when that id is set.

## Portability note

The `slack-ask` / `slack-notify` skills call
`$HOME/.claude/bin/cc-slack-post.py`; the shell expands `$HOME`, so those repo
files usually need no per-user path edits.

The allow-rule in `~/.claude/settings.json` is different: use the literal
absolute helper path, such as
`Bash(/home/alice/.claude/bin/cc-slack-post.py:*)` or
`Bash(/Users/alice/.claude/bin/cc-slack-post.py:*)`. Permission allow-rules do
not expand `$HOME`.

## What is NOT in this repo (by design)

- `~/.claude/.slack-bot-token` — the Slack bot secret
- `~/.claude/settings.json` — local permissions/config
- anything else under `~/.claude` (credentials, transcripts) — `~/.claude` is not
  a git repo
