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

- **Channel**: the helper finds it itself: `CC_SLACK_CHANNEL` in its env, else
  `env.CC_SLACK_CHANNEL` in `~/.claude/settings.json` (e.g. `C0123456789`; find
  yours in Slack via channel name → About → **Copy channel ID**). Nothing needs
  exporting — wiring in [SETUP.md](../SETUP.md).
- **Send helper**: `$HOME/.claude/bin/cc-slack-post.py "<message>"`
  — posts as the bot (token from `~/.claude/.slack-bot-token`), allowlisted so it
  runs without a prompt. The command may use `$HOME`, but the
  `~/.claude/settings.json` allow-rule must use the literal absolute helper path.
  To DM instead of the channel, set `CC_SLACK_CHANNEL` to your Slack member id
  (e.g. `U0123456789` — profile → **Copy member ID**) for the call.

## Procedure

1. Run `hostname` so the message says which machine it came from.
2. Send via Bash:
   ```bash
   $HOME/.claude/bin/cc-slack-post.py "<emoji> *<machine>* — \`<task>\`
   <one-line status>
   <optional detail or link>"
   ```
   Use ✅ for success, ⚠️ for needs-attention, ❌ for failure.

Do not wait for a reply. Read the helper's exit code:

- **0** — posted.
- **78** — no channel is set: nothing was sent, and the helper logged the line
  as unposted. Do not retry and do not fail the task for it; keep reporting in
  the session as usual. Then run
  `$HOME/.claude/bin/cc-slack-post.py --no-channel-notice slack-notify` and
  repeat any line it prints (`slack: no channel`, at most once a day).
- **1** — the post failed (`ERR …`: token missing, bot not in the channel, or a
  network error); it is logged as unposted too. Report it.
