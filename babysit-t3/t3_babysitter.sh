#!/usr/bin/env bash
# T3 Babysitter Supervisor — stateless poll loop (bundled with the babysit-t3 skill).
#
# The mother process for an unattended T3 pool. Each iteration runs ONE headless Claude Code
# babysitting pass, then sleeps. The agent gets a FRESH context every pass, so context never grows —
# no /compact or handoff is ever needed. Durable job state lives entirely in the per-campaign
# STATUS.md / ISSUES.md files; this script holds none.
#
# SINGLE orchestrator: do not run a second copy, do not run arc_babysitter.sh at the same time
# (T3 and ARC pools share zeus and the same ~/Code/ARC checkout — one supervisor babysits both),
# and do not also drive Claude interactively on these campaigns while it runs.
#
# Launch (manual, in tmux — does NOT auto-restart after a reboot; relaunch the same line):
#     tmux new -s t3 'bash ~/.claude/skills/babysit-t3/t3_babysitter.sh'
#     detach: Ctrl-b d   ·   reattach: tmux attach -t t3   ·   watch: tail -f ~/Projects/t3_babysitter.log
#
# Override defaults via env: T3_SPEC, T3_STATE_FILE, T3_LOG, T3_BABYSITTER_INTERVAL (sec),
# T3_BABYSITTER_PASS_TIMEOUT.

set -uo pipefail

SPEC="${T3_SPEC:-$HOME/Projects/T3_CAMPAIGNS.md}"
STATE_FILE="${T3_STATE_FILE:-$HOME/Projects/.t3_babysitter.state}"
LOG="${T3_LOG:-$HOME/Projects/t3_babysitter.log}"
INTERVAL="${T3_BABYSITTER_INTERVAL:-1800}"        # seconds between passes (default 30 min)
PASS_TIMEOUT="${T3_BABYSITTER_PASS_TIMEOUT:-30m}" # max wall time for one pass

PASS_PROMPT="Use the babysit-t3 skill. Read $SPEC, then do EXACTLY ONE babysitting pass of the T3 \
campaigns and STOP (end the session) — do not stay resident or sleep; this external supervisor \
handles cadence. First pass after a (re)boot: run the idempotent shared pre-flight. Each pass: check \
the zeus gate; for every campaign detect the current phase from the newest iteration folder and \
health-check it (T3 PID alive, RMG.log/SA outputs/arc.log advancing, zeus jobs cycling, disk OK \
locally and on zeus); relaunch dead T3 processes (T3 self-resumes — verify it resumed at the \
expected iteration, never from scratch) and fix crashes per the bug catalogs within the retry \
budget; update the iteration history (incl. IDT RMSE when logged); keep both STATUS.md (live \
ledger, timestamped heartbeat) and each campaign's ISSUES.md (human follow-up: unconverged species, \
exhausted retries, questionable SA/IDT results) current. Be GENTLE with zeus SSH (account-ban \
risk): batch all per-pass zeus checks into ONE connection, one qstat -u \$USER for all jobs, never \
tight-loop on SSH failures — per the SSH budget in the vault (Running ARC On Zeus section 0b). When \
the pass is finished, write EXACTLY \
ONE word to $STATE_FILE: DONE (every campaign in the pool is terminal AND teardown is complete), \
PAUSED (a blocker needs the user — also slack-ask and record it in STATUS.md), or RUNNING (work \
continues). Write nothing else to that file."

echo "$(date '+%F %T') supervisor start (interval=${INTERVAL}s, timeout=${PASS_TIMEOUT})" >> "$LOG"
while true; do
  echo "$(date '+%F %T') --- pass start ---" >> "$LOG"
  echo RUNNING > "$STATE_FILE"  # reset ephemeral state so a crashed/timed-out pass never inherits a stale DONE/PAUSED (e.g. after a relaunch)
  timeout "$PASS_TIMEOUT" claude -p "$PASS_PROMPT" --dangerously-skip-permissions >> "$LOG" 2>&1
  rc=$?
  [ "$rc" -eq 124 ] && echo "$(date '+%F %T') pass TIMED OUT after ${PASS_TIMEOUT}" >> "$LOG"
  state="$(tr -d '[:space:]' < "$STATE_FILE" 2>/dev/null || echo RUNNING)"
  echo "$(date '+%F %T') --- pass end (rc=$rc, state=${state:-RUNNING}) ---" >> "$LOG"
  case "$state" in
    DONE)   echo "$(date '+%F %T') pool DONE — supervisor exiting." >> "$LOG"; exit 0 ;;
    PAUSED) echo "$(date '+%F %T') PAUSED — a blocker needs the user. Supervisor stopping; resolve, then relaunch." >> "$LOG"; exit 2 ;;
    *)      sleep "$INTERVAL" ;;
  esac
done
