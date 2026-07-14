#!/usr/bin/env bash
# hq_brief_run.sh — unattended weekly HQ "week ahead" brief.
#   Refreshes Status.md (deterministic), runs the hq-brief skill HEADLESS via Claude Code
#   to WRITE the brief + the short Slack text (LLM gets Read/Write/Edit only — NO shell),
#   then THIS wrapper (deterministic) posts the Slack text to #cc-comm.
#   Schedule: Saturday 18:00 HL (primary) · 18:30 OL (HQ_BRIEF_DEFER=1 backup).
#   Auth: relies on ~/.claude OAuth creds (works in a clean cron env; no secret needed).
#   Usage: hq_brief_run.sh [HOST_TAG]
#   Env:  HQ_VAULT, HQ_BRIEF_DEFER=1 (skip if week's brief exists), HQ_BRIEF_DRYRUN=1
#         (write brief but do NOT post to Slack), CLAUDE_BIN (override claude path).
set -euo pipefail

HOST_TAG="${1:-$(hostname)}"
VAULT="${HQ_VAULT:-$HOME/Dropbox/Apps/remotely-save/Vault}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_DIR="$(cd "$DIR/../hq-update" && pwd)"
TODAY="$(date +%d/%m/%Y)"
NOW="$(date '+%d/%m/%Y %H:%M')"
WEEK="$(date +%G-W%V)"
BRIEF="$VAULT/HQ/Briefings/$WEEK.md"
SLACKFILE="$VAULT/HQ/.hq-brief-slack.txt"   # transient; LLM writes it, wrapper posts + deletes

[ -f "$HOME/.config/hq-brief.env" ] && . "$HOME/.config/hq-brief.env"
echo "hq_brief[$HOST_TAG]: $NOW — week $WEEK"

# --- defer: OL runs only if HL hasn't already written this week's brief ---
if [ "${HQ_BRIEF_DEFER:-0}" = "1" ] && [ -f "$BRIEF" ]; then
  echo "hq_brief[$HOST_TAG]: $WEEK brief already exists — deferring to primary, exit 0."
  exit 0
fi

# --- 1. deterministic refresh so the brief reflects Saturday-evening reality ---
if ! HQ_VAULT="$VAULT" "$UPDATE_DIR/hq_run.sh" "$HOST_TAG"; then
  echo "hq_brief[$HOST_TAG]: WARN — Status.md refresh failed; proceeding on existing snapshot."
fi

# --- 2. headless Claude Code: WRITE the brief + the Slack text. NO shell tool. ---
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || true)}"
[ -z "$CLAUDE_BIN" ] && for c in "$HOME"/.nvm/versions/node/*/bin/claude "$HOME/.local/bin/claude" /usr/local/bin/claude; do
  [ -x "$c" ] && CLAUDE_BIN="$c" && break
done
# Fail fast: unattended in cron, an empty CLAUDE_BIN would otherwise blow up at the invocation
# below with a cryptic "command not found" (exit 127). Surface the real cause instead.
if [ -z "$CLAUDE_BIN" ]; then
  echo "hq_brief[$HOST_TAG]: ERROR — no 'claude' binary found (checked PATH, nvm, ~/.local/bin, /usr/local/bin). Set CLAUDE_BIN." >&2
  exit 1
fi
# cron PATH is minimal and lacks node; put claude's own dir (node lives beside it) on PATH.
export PATH="$(dirname "$CLAUDE_BIN"):$PATH"
rm -f "$SLACKFILE"

PROMPT="Read ~/Code/agent-skills/hq-brief/SKILL.md and follow it EXACTLY in UNATTENDED mode. \
Today is $TODAY, ISO week $WEEK; Status.md was just refreshed. Steps: read HQ/Status.md and the \
flagged node bodies; write the week-ahead brief to $BRIEF per the skill's output contract \
(urgent / strategic / open, curated to what matters this week — not everything); refresh the \
'Current brief' pointer line in HQ/Dashboard.md; and write ONLY the short Slack version as plain \
text (the one thing + up to 3 urgent moves + one strategic line + the success test) to the file \
$SLACKFILE. Use ONLY the Read, Write, and Edit tools — do NOT run any shell command. Write only \
inside HQ/. Print the brief path when done."

cd "$VAULT"
HQ_BRIEF_UNATTENDED=1 "$CLAUDE_BIN" -p "$PROMPT" \
  --permission-mode acceptEdits \
  --allowedTools "Read,Write,Edit" \
  --add-dir "$VAULT" --add-dir "$HOME/Code/agent-skills" \
  2>&1

# --- 3. deterministic outbound post (the wrapper, not the LLM) ---
if [ "${HQ_BRIEF_DRYRUN:-0}" = "1" ]; then
  echo "hq_brief[$HOST_TAG]: DRY-RUN — brief written, Slack NOT posted. Draft was:"
  cat "$SLACKFILE" 2>/dev/null || echo "(no slack draft produced)"
elif [ -s "$SLACKFILE" ]; then
  if python3 "$HOME/.claude/bin/cc-slack-post.py" "$(cat "$SLACKFILE")"; then
    echo "hq_brief[$HOST_TAG]: Slack posted to #cc-comm."
  else
    echo "hq_brief[$HOST_TAG]: WARN — Slack post failed (brief still written to vault)."
  fi
else
  echo "hq_brief[$HOST_TAG]: WARN — no Slack text produced; skipped post."
fi
rm -f "$SLACKFILE"
echo "hq_brief[$HOST_TAG]: done ($WEEK)."
