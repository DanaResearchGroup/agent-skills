# Setup

Personal Claude Code skills. Most skills are self-contained — clone, symlink into
`~/.claude/skills`, done. The **Slack skills** (`slack-ask`, `slack-notify`) need
a little extra per-machine wiring (a bot token + an allowlist) so they can notify
you and run unattended.

## Quick start (any machine)

```bash
# 1. Clone this repo
git clone https://github.com/alongd/agent-skills ~/Code/agent-skills

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

Place the token on each machine (keep it out of git — paste it directly in a
terminal, e.g. via Claude Code's `!` prefix):
```bash
install -m 600 /dev/null ~/.claude/.slack-bot-token
printf '%s' 'xoxb-...' > ~/.claude/.slack-bot-token
```

### 3. Allowlist (so it runs without prompts) — per machine
Merge into `~/.claude/settings.json` (not in this repo):
```json
{
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
| `CC_SLACK_CHANNEL` | `C0B993YLDPT` (#cc-comm) | Target channel id; set to a user id to DM |
| `CC_SLACK_TOKEN_FILE` | `~/.claude/.slack-bot-token` | Path to the `xoxb-` token |

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
