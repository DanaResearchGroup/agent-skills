#!/usr/bin/env bash
# Installer for the autodev automation harness. Claude Code gets the complete
# status-line/Phoenix setup; Codex gets context-aware handoff/compact/reload.
#
# Wires runtime hooks to THIS skill's bundled bin/ so the implementation remains
# self-locating and portable.
#
# Idempotent: re-running replaces our own entries, never duplicates them, and preserves
# any other hooks you already have (superpowers, etc.).
#
# Usage:
#   bash install.sh                 # Claude Code: ~/.claude/settings.json
#   bash install.sh --codex         # Codex: ~/.codex/hooks.json
#   CLAUDE_SETTINGS=/path bash install.sh
#   CODEX_HOOKS=/path bash install.sh --codex
#   AUTODEV_HOME=~/somewhere bash install.sh   # where runtime state/handoffs live (default ~/agents)
#
# Requires: jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME=claude
case "${1:-}" in
  "") ;;
  --codex) RUNTIME=codex ;;
  *) echo "usage: $(basename "$0") [--codex]" >&2; exit 2 ;;
esac
: "${AUTODEV_HOME:=$HOME/agents}"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }
for f in cc-statusline.sh cc-stop-hook.sh codex-stop-hook.sh cc-sessionstart-compact.sh sessionstart-compact.sh auto-handoff-watch.sh auto-handoff-sweep.sh session-resume-watch.sh request-handoff.sh cache-warm-watch.sh; do
  [ -f "$HERE/$f" ] || { echo "error: missing $HERE/$f" >&2; exit 1; }
  chmod +x "$HERE/$f"
done

mkdir -p "$AUTODEV_HOME/state" "$AUTODEV_HOME/logs" "$AUTODEV_HOME/handoffs"

if [ "$RUNTIME" = codex ]; then
  SETTINGS="${CODEX_HOOKS:-$HOME/.codex/hooks.json}"
  STOP="$HERE/codex-stop-hook.sh"
  SC="$HERE/sessionstart-compact.sh"
  mkdir -p "$(dirname "$SETTINGS")"
  [ -f "$SETTINGS" ] || echo '{"hooks":{}}' > "$SETTINGS"
  cp "$SETTINGS" "$SETTINGS.bak.autodev.$(date +%s)"
  jq --arg stop "$STOP" --arg sc "$SC" '
    .hooks = (.hooks // {})
    | .hooks.Stop = (((.hooks.Stop // [])
          | map(select((any(.hooks[]?; .command==$stop)) | not)))
          + [{hooks:[{type:"command", command:$stop, timeout:10}]}])
    | .hooks.SessionStart = (((.hooks.SessionStart // [])
          | map(select((any(.hooks[]?; .command==$sc)) | not)))
          + [{matcher:"^compact$", hooks:[{type:"command", command:$sc, timeout:10, additionalContextLimit:2500}]}])
  ' "$SETTINGS" > "$SETTINGS.tmp"
  mv "$SETTINGS.tmp" "$SETTINGS"
else
  SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
  SL="$HERE/cc-statusline.sh"
  STOP="$HERE/cc-stop-hook.sh"
  SC="$HERE/cc-sessionstart-compact.sh"
  mkdir -p "$(dirname "$SETTINGS")"
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  cp "$SETTINGS" "$SETTINGS.bak.autodev.$(date +%s)"
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
fi

# --- level trigger: auto-handoff-sweep.sh on a timer ------------------------
# The Stop hook only fires the watcher at a turn end, so a session that parks
# (busy pane, aborted cycle, cooldown) is never re-evaluated and waits forever.
# The sweeper supplies the missing level trigger. Installed as a systemd user
# timer where available, cron otherwise. Idempotent either way.
SWEEP="$HERE/auto-handoff-sweep.sh"
SWEEP_EVERY="${AUTODEV_SWEEP_EVERY:-3min}"
sweep_installed=""
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_DIR/auto-handoff-sweep.service" <<EOF
[Unit]
Description=Agent auto-handoff sweeper (level trigger for parked sessions)

[Service]
Type=oneshot
# KillMode=process is REQUIRED, not a tuning knob. The sweeper's whole job is to
# launch detached watchers and exit immediately. Under the default
# KillMode=control-group, systemd tears down the service cgroup the moment
# ExecStart returns — killing every watcher it just spawned, setsid or not. The
# sweeper then looks perfectly healthy in the log ("SWEEP re-arming watcher...")
# while nothing ever happens: the watcher survives just long enough to write its
# heartbeat and dies before any gate that logs. Verified both ways: with the
# default the child is reaped, with KillMode=process it survives.
KillMode=process
Environment=AUTODEV_HOME=$AUTODEV_HOME
ExecStart=$SWEEP
EOF
  cat > "$UNIT_DIR/auto-handoff-sweep.timer" <<EOF
[Unit]
Description=Run the agent auto-handoff sweeper every $SWEEP_EVERY

[Timer]
OnBootSec=2min
OnUnitActiveSec=$SWEEP_EVERY

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  if systemctl --user enable --now auto-handoff-sweep.timer >/dev/null 2>&1; then
    sweep_installed="systemd user timer (every $SWEEP_EVERY)"
  fi
fi
if [ -z "$sweep_installed" ] && command -v crontab >/dev/null 2>&1; then
  line="*/5 * * * * AUTODEV_HOME=$AUTODEV_HOME $SWEEP  # autodev-sweep"
  if (crontab -l 2>/dev/null | grep -v '# autodev-sweep$'; echo "$line") | crontab - 2>/dev/null; then
    sweep_installed="cron (every 5 min)"
  fi
fi
[ -z "$sweep_installed" ] && sweep_installed="NOT INSTALLED — run $SWEEP from a timer yourself"

echo "installed into: $SETTINGS"
if [ "$RUNTIME" = codex ]; then
  echo "  Codex Stop hook   -> $STOP"
  echo "  Codex SessionStart(compact) -> $SC"
else
  echo "  statusLine        -> $SL"
  echo "  Stop hook         -> $STOP"
  echo "  SessionStart(compact) -> $SC"
fi
echo "  sweeper (level trigger) -> $sweep_installed"
echo "  runtime home (AUTODEV_HOME) -> $AUTODEV_HOME"
echo
if [ "$RUNTIME" = codex ]; then
  echo "Takes effect for NEW Codex sessions. Open /hooks once to review and trust the new hooks."
  echo "Codex lifecycle hooks must be enabled (features.hooks=true; stable builds enable them by default)."
else
  echo "Takes effect for NEW Claude Code sessions (hooks load at session start)."
fi
echo "Default is DRY-RUN (logs only, never touches your pane). To go live:"
echo "  touch \"$AUTODEV_HOME/state/auto-handoff.armed\"     # arm (badge -> 🔴 ARMED)"
echo "  touch \"$AUTODEV_HOME/state/disable-auto-compact\"   # global kill switch (badge -> ⛔)"
echo "  touch \"$AUTODEV_HOME/state/disable-auto-resume\"    # Phoenix off only"
echo "  touch \"$AUTODEV_HOME/state/no-usage-credits\"       # Phoenix: skip paid credits, wait for reset"
echo "Logs: $AUTODEV_HOME/logs/{auto-handoff,auto-resume}.log"
