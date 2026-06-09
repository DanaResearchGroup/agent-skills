---
name: slack-ask
description: Ask the user a question over Slack and block until they reply. Use during automated/unattended procedures when you need human input or a decision and the user is away from the terminal. Posts to the #cc-comm channel as a bot (so the user actually gets notified) and waits for a threaded reply, so the asking instance catches its own answer.
---

# slack-ask — bidirectional human-in-the-loop over Slack

Use this when a procedure needs input from the user but they may not be watching
the terminal. You post a question to Slack **as a bot** (so Slack notifies the
user — the claude.ai connector posts *as the user*, which Slack never notifies
about), the user replies **in the thread**, and you read that reply back via the
connector and continue. Because you only watch the thread you created, the reply
is routed to *this* CC instance even if other instances on other machines are
also asking.

## Config

- **Channel**: `#cc-comm` → `channel_id` = `C0B993YLDPT` (stable across machines).
- **Send helper**: `/home/alon/.claude/bin/cc-slack-post.py "<message>" [thread_ts]`
  — posts as the bot (reads the bot token from `~/.claude/.slack-bot-token`),
  prints `OK` then the message `ts`. It's allowlisted in settings.json, so it
  runs without a permission prompt (unattended-safe). Do **not** use inline
  `curl` with heredocs — that trips the "expansion obfuscation" guard and prompts.
- **Human user id**: `U01FB823VSR` (Alon). Only a reply from this user (not the
  bot, not yourself) counts as the answer.
- **Poll schedule** (backoff): every **30s for the first 5 min**, then every
  **15 min for the next hour**, then every **30 min** thereafter. Adjust per task.

## Procedure

1. **Identify context.** Run `hostname` and note the current working directory so
   the user knows *which machine / which task* is asking.

2. **Post the question as the bot** and capture the thread root `ts`. Run the
   helper via Bash (mind shell quoting; the message uses Slack mrkdwn —
   `*bold*`, `_italic_`, `` `code` ``, `\n` for newlines):
   ```bash
   /home/alon/.claude/bin/cc-slack-post.py "❓ *<machine>* needs input — \`<task>\`
   <cwd>

   <your question, with concrete options if it's a choice>

   _Reply in this thread._"
   ```
   The first output line is `OK`; the **second line is the thread root `ts`** —
   keep it, it's your routing key. (If it prints `ERR …`, report it and stop;
   common causes: token file missing, or the bot isn't in the channel.)

3. **Wait for a reply (polling loop with backoff).** Foreground `sleep` is
   blocked in this harness, so wait by running a **backgrounded** Bash command
   (`sleep <N>` with `run_in_background: true`). When it completes you are
   re-invoked; then check for the reply. Track elapsed time to pick the interval:

   | Elapsed since you posted | Sleep between polls |
   |---|---|
   | 0–5 min       | `sleep 30`  (every 30s)  |
   | 5–65 min      | `sleep 900` (every 15 min) |
   | 65 min onward | `sleep 1800` (every 30 min) |

   On each wake:
   - Call `slack_read_thread` with `channel_id` `C0B993YLDPT` and
     `message_ts = <ts>`.
   - Look for the **last** message whose `user` is `U01FB823VSR` and whose `ts`
     is greater than the root `ts`.
   - If found → that text is the answer. Go to step 4.
   - If not found → start the next backgrounded `sleep` per the table and repeat.
   - Keep going at the 30-min cadence until answered, or stop after an overall
     budget (default ~4 h) and report a timeout to the user.

   Note: background-task completion events are NOT the user's reply — only a
   `slack_read_thread` message from `U01FB823VSR` counts.

4. **Acknowledge and continue.** Post a short threaded confirmation by passing
   the root `ts` as the second arg, then use the answer to proceed:
   ```bash
   /home/alon/.claude/bin/cc-slack-post.py "✅ Got it — continuing." "<ts>"
   ```

## Notes

- If the answer is ambiguous, ask a follow-up **in the same thread** (pass the
  root `ts` again) rather than starting a new message.
- Never treat your own/bot messages as the answer — filter strictly on
  `user == U01FB823VSR`.
- On a machine with a different home dir, adjust the helper path here and the
  matching allow-rule in `settings.json`.
- For a one-way notification that needs no reply, use the `slack-notify` skill.
