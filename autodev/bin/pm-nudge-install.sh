#!/usr/bin/env bash
# Installer for the PM-nudger daemon (pm-nudge-sweep.sh + pm-nudge-compose.py).
#
# Deliberately SEPARATE from install.sh. The auto-handoff installer edits your
# settings.json and owns three hooks; this daemon touches no hooks at all — it is
# a timer and a venv. Folding it in would put an optional, network-touching,
# API-key-using feature behind the switch that turns on the core harness, and
# would drag the core harness's installer tests along for every change here.
#
# What it wires:
#   1. $AUTODEV_HOME/venv/pm-nudge — a dedicated venv holding the anthropic SDK.
#      Dedicated because the ambient interpreter cannot be trusted: anaconda on
#      this machine fails to import the SDK at all
#      (`cannot import name 'validate_core_schema' from 'pydantic_core'`), and a
#      timer-fired daemon has no control over what $PATH looks like when it runs.
#      The sweeper therefore calls this interpreter by ABSOLUTE path, never
#      `python3`.
#   2. a systemd user timer running the sweeper every few minutes (cron fallback).
#
# The unit runs the sweeper with --send, which is safe by construction: --send
# without $AUTODEV_HOME/state/pm-nudge.armed degrades to a dry run and says so in
# the log. So installing does NOT arm anything — arming is a separate, deliberate
# touch, exactly as it is for auto-handoff.
#
# Usage:
#   bash pm-nudge-install.sh
#   bash pm-nudge-install.sh --no-venv         # timer only (venv already built / not wanted)
#   AUTODEV_HOME=~/agents PM_NUDGE_SWEEP_EVERY=3min bash pm-nudge-install.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${AUTODEV_HOME:=$HOME/agents}"
: "${PM_NUDGE_VENV:=$AUTODEV_HOME/venv/pm-nudge}"
: "${PM_NUDGE_SWEEP_EVERY:=5min}"

WANT_VENV=1
for a in "${@:-}"; do
  case "$a" in
    ""|--venv) ;;
    --no-venv) WANT_VENV=0 ;;
    -h|--help) sed -n '/^# Usage:/,/^set -/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//; /^set -/d'; exit 0 ;;
    *) echo "pm-nudge-install.sh: unknown argument '$a'" >&2; exit 2 ;;
  esac
done

SWEEP="$HERE/pm-nudge-sweep.sh"
COMPOSER="$HERE/pm-nudge-compose.py"
REQS="$HERE/pm-nudge-requirements.txt"
for f in "$SWEEP" "$COMPOSER" "$REQS"; do
  [ -f "$f" ] || { echo "error: missing $f" >&2; exit 1; }
done
chmod +x "$SWEEP" "$COMPOSER"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required (the classifier is pure jq)" >&2; exit 1; }
command -v herdr >/dev/null 2>&1 || echo "warning: herdr not on PATH — the sweeper will no-op until it is" >&2

mkdir -p "$AUTODEV_HOME/state/pm-nudge" "$AUTODEV_HOME/logs"

# --- 1. the venv -------------------------------------------------------------
venv_status="skipped (--no-venv)"
if [ "$WANT_VENV" = 1 ]; then
  # Candidates are PROVED, not assumed, and the probe checks all three of venv,
  # ssl and ensurepip. Both halves of that matter here and neither is obvious:
  # `python3` first on PATH is anaconda, whose base env cannot import the SDK at
  # all — but a venv built FROM it is a fresh site-packages and works fine —
  # while /usr/bin/python3 imports the SDK happily and yet cannot build a usable
  # venv, because Debian ships ensurepip in a separate python3-venv package that
  # is absent here. Probing only `venv, ssl` picks /usr/bin/python3 and produces
  # a pip-less venv that fails one step later.
  base=""
  for c in "${PM_NUDGE_PYTHON:-}" /usr/bin/python3 /usr/bin/python3.12 /usr/bin/python3.11 python3; do
    [ -n "$c" ] || continue
    command -v "$c" >/dev/null 2>&1 || continue
    "$c" -c 'import venv, ssl, ensurepip' >/dev/null 2>&1 || continue
    base="$c"; break
  done
  if [ -z "$base" ]; then
    venv_status="FAILED — no interpreter with venv + ssl + ensurepip (try: apt install python3-venv)"
  else
    # PYTHONPATH/PYTHONHOME are stripped for every step. This machine exports a
    # PYTHONPATH of six research checkouts; leaving it set lets those shadow the
    # venv during the build exactly as they would at run time.
    PY="$PM_NUDGE_VENV/bin/python"
    [ -x "$PY" ] || env -u PYTHONPATH -u PYTHONHOME "$base" -m venv "$PM_NUDGE_VENV"
    env -u PYTHONPATH -u PYTHONHOME "$PY" -E -s -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true
    if env -u PYTHONPATH -u PYTHONHOME "$PY" -E -s -m pip install --quiet -r "$REQS" >/dev/null 2>&1; then
      v=$(env -u PYTHONPATH -u PYTHONHOME "$PY" -E -s -c 'import anthropic; print(anthropic.__version__)' 2>/dev/null || echo '?')
      venv_status="$PM_NUDGE_VENV (base $base, anthropic $v)"
    else
      venv_status="FAILED — pip install -r $REQS did not succeed"
    fi
  fi
fi

# --- 2. the timer ------------------------------------------------------------
# Level trigger, same reasoning as auto-handoff-sweep.sh: an idle PM emits no
# further edges, so only a clock can ever notice it.
timer_status=""
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_DIR/pm-nudge-sweep.service" <<EOF
[Unit]
Description=Claude Code PM-nudger (nudge a PM whose worker fleet has gone quiet)

[Service]
Type=oneshot
# KillMode=process is the harness's standing rule for these units. Unlike
# auto-handoff-sweep.sh — which launches detached watchers via setsid and is
# GUTTED by the default KillMode=control-group, because systemd tears the cgroup
# down the instant ExecStart returns — this sweeper runs its whole cycle inline,
# so it does not depend on the guard for correctness. It is set anyway: the
# composer is a child process with its own timeout, and a unit in this family
# that quietly acquires a detached child later must not silently regress.
KillMode=process
# A wedged herdr or a hung network call must not pin the unit until the next
# boot. The composer has its own 30s timeout; this is the outer backstop.
TimeoutStartSec=180
Environment=AUTODEV_HOME=$AUTODEV_HOME
Environment=PM_NUDGE_VENV=$PM_NUDGE_VENV
# --send is the SAFE ExecStart, counter-intuitively: without
# $AUTODEV_HOME/state/pm-nudge.armed it degrades to a dry run, whereas
# --stage-only would write into panes unconditionally. Arming stays a manual act.
ExecStart=$SWEEP --send
EOF
  cat > "$UNIT_DIR/pm-nudge-sweep.timer" <<EOF
[Unit]
Description=Run the Claude Code PM-nudger every $PM_NUDGE_SWEEP_EVERY

[Timer]
OnBootSec=3min
OnUnitActiveSec=$PM_NUDGE_SWEEP_EVERY

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  if systemctl --user enable --now pm-nudge-sweep.timer >/dev/null 2>&1; then
    timer_status="systemd user timer (every $PM_NUDGE_SWEEP_EVERY)"
  fi
fi
if [ -z "$timer_status" ] && command -v crontab >/dev/null 2>&1; then
  # The trailing tag is what makes re-running idempotent: the old line is
  # filtered out by tag before the new one is appended.
  line="*/5 * * * * AUTODEV_HOME=$AUTODEV_HOME PM_NUDGE_VENV=$PM_NUDGE_VENV $SWEEP --send  # pm-nudge-sweep"
  if (crontab -l 2>/dev/null | grep -v '# pm-nudge-sweep$'; echo "$line") | crontab - 2>/dev/null; then
    timer_status="cron (every 5 min)"
  fi
fi
[ -z "$timer_status" ] && timer_status="NOT INSTALLED — run '$SWEEP --send' from a timer yourself"

# --- banner ------------------------------------------------------------------
echo "pm-nudge installed:"
echo "  sweeper (level trigger) -> $timer_status"
echo "  composer venv           -> $venv_status"
echo "  runtime home            -> $AUTODEV_HOME"
echo "  log                     -> $AUTODEV_HOME/logs/pm-nudge.log"
echo
echo "Default is DRY-RUN: the timer runs '--send', which without the armed file"
echo "only decides and logs. Nothing is typed at any pane until you arm it."
echo "  $SWEEP --report                                    # what it would do, right now"
echo "  touch \"$AUTODEV_HOME/state/pm-nudge.armed\"        # arm (stage + Enter)"
echo "  rm -f  \"$AUTODEV_HOME/state/pm-nudge.armed\"       # back to dry-run"
echo "  touch \"$AUTODEV_HOME/state/disable-pm-nudge\"      # global kill switch (beats armed)"
echo "  $SWEEP --stage-only                                # stage text, never press Enter"
