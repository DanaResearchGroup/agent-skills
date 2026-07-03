#!/usr/bin/env bash
# Installer for the autodev automation harness (auto-handoff watcher + Phoenix
# session-limit auto-resume + context-signal status line).
#
# Wires three Claude Code hooks/statusLine into your settings.json, all pointing at
# THIS skill's bundled bin/ (so the whole implementation stays inside the skill and is
# portable to any machine): copy the autodev skill, run this, done.
#
# Idempotent: re-running replaces our own entries, never duplicates them, and preserves
# any other hooks you already have (gstack, superpowers, etc.).
#
# Usage:
#   bash install.sh                 # installs into ~/.claude/settings.json
#   CLAUDE_SETTINGS=/path bash install.sh
#   AUTODEV_HOME=~/somewhere bash install.sh   # where runtime state/handoffs live (default ~/agents)
#
# Requires: jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
: "${AUTODEV_HOME:=$HOME/agents}"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }
for f in cc-statusline.sh cc-stop-hook.sh cc-sessionstart-compact.sh auto-handoff-watch.sh session-resume-watch.sh; do
  [ -f "$HERE/$f" ] || { echo "error: missing $HERE/$f" >&2; exit 1; }
  chmod +x "$HERE/$f"
done

mkdir -p "$(dirname "$SETTINGS")" "$AUTODEV_HOME/state" "$AUTODEV_HOME/logs" "$AUTODEV_HOME/handoffs"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.autodev.$(date +%s)"

SL="$HERE/cc-statusline.sh"
STOP="$HERE/cc-stop-hook.sh"
SC="$HERE/cc-sessionstart-compact.sh"

# Strip any prior entries pointing at our three commands, then (re)add fresh ones.
# .statusLine is simply overwritten to ours.
jq \
  --arg sl "$SL" --arg stop "$STOP" --arg sc "$SC" '
  .statusLine = {type:"command", command:$sl}
  | .hooks = (.hooks // {})
  | .hooks.Stop = (((.hooks.Stop // [])
        | map(select((any(.hooks[]?; .command==$stop)) | not)))
        + [{hooks:[{type:"command", command:$stop}]}])
  | .hooks.SessionStart = (((.hooks.SessionStart // [])
        | map(select((any(.hooks[]?; .command==$sc)) | not)))
        + [{matcher:"compact", hooks:[{type:"command", command:$sc}]}])
' "$SETTINGS" > "$SETTINGS.tmp"
mv "$SETTINGS.tmp" "$SETTINGS"

echo "installed into: $SETTINGS"
echo "  statusLine        -> $SL"
echo "  Stop hook         -> $STOP"
echo "  SessionStart(compact) -> $SC"
echo "  runtime home (AUTODEV_HOME) -> $AUTODEV_HOME"
echo
echo "Takes effect for NEW Claude Code sessions (hooks load at session start)."
echo "Default is DRY-RUN (logs only, never touches your pane). To go live:"
echo "  touch \"$AUTODEV_HOME/state/auto-handoff.armed\"     # arm (badge -> 🔴 ARMED)"
echo "  touch \"$AUTODEV_HOME/state/disable-auto-compact\"   # global kill switch (badge -> ⛔)"
echo "  touch \"$AUTODEV_HOME/state/disable-auto-resume\"    # Phoenix off only"
echo "  touch \"$AUTODEV_HOME/state/no-usage-credits\"       # Phoenix: skip paid credits, wait for reset"
echo "Logs: $AUTODEV_HOME/logs/{auto-handoff,auto-resume}.log"
