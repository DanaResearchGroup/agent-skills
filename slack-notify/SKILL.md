---
name: slack-notify
description: Send the user a one-way notification over Slack (no reply expected). Use to report progress, completion, or that a long/automated procedure finished or hit an error, when the user may be away from the terminal.
---

# slack-notify — one-way notification over Slack

Use this to ping the user when something happens and you do **not** need an
answer back. For questions that need a reply, use `slack-ask` instead.

Posts **as the bot** via the send helper, not via the connector: the claude.ai
connector posts *as the user*, which Slack never notifies the user about. The bot
identity is what actually triggers a notification.

## Config

- **Channel**: `#cc-comm` → `channel_id` = `C0B993YLDPT`.
- **Send helper**: `$HOME/.claude/bin/cc-slack-post.py "<message>"`
  — posts as the bot (token from `~/.claude/.slack-bot-token`), allowlisted so it
  runs without a prompt. The command may use `$HOME`, but the
  `~/.claude/settings.json` allow-rule must use the literal absolute helper path.
  To DM instead of the channel, set
  `CC_SLACK_CHANNEL=U01FB823VSR` in the environment for the call.

## Procedure

1. Run `hostname` so the message says which machine it came from.
2. Send via Bash:
   ```bash
   $HOME/.claude/bin/cc-slack-post.py "<emoji> *<machine>* — \`<task>\`
   <one-line status>
   <optional detail or link>"
   ```
   Use ✅ for success, ⚠️ for needs-attention, ❌ for failure.

Do not wait for a reply. If the helper prints `ERR …`, report it (token missing
or bot not in channel).
