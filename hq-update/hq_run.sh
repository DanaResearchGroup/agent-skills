#!/usr/bin/env bash
# hq_run.sh — the unattended, DETERMINISTIC half of the HQ daily refresh.
#
# Runs hq_pull.py (no LLM, cheap, safe) and regenerates HQ/Status.md — a snapshot
# of live PR/CI state, deadline countdowns, staleness, dead pointers, and suggested
# traffic lights. Judgment/curation (board next-actions, Inbound triage, strategy
# diffs) is NOT done here — that stays in the on-demand augmented `hq-update`
# session. See HQ/CLAUDE.md and Design.md §Freshness.
#
# Two-host coordination (per Alon):
#   HL  — runs 05:00 unconditionally:            hq_run.sh HL
#   OL  — runs 05:30 only if not refreshed today: HQ_DEFER=1 hq_run.sh OL
# OL reads the "Last refresh: DD/MM/YYYY" stamp in HQ/Status.md; if it already
# shows today's date (HL ran and Dropbox synced), OL skips. If Dropbox hasn't
# synced yet, OL runs too — harmless, the write is idempotent.
#
# gh auth: the token lives in the OS keyring, which a headless cron shell usually
# cannot unlock, so the PR block degrades gracefully (node scan still works). For
# full PR data unattended, drop a token into ~/.config/hq-update.env:
#     GH_TOKEN=ghp_xxx        # 600 perms; sourced below if present
set -uo pipefail

HOST_TAG="${1:-$(hostname)}"
VAULT="${HQ_VAULT:-$HOME/Dropbox/Apps/remotely-save/Vault}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS="$VAULT/HQ/Status.md"
TODAY="$(date +%d/%m/%Y)"
NOW="$(date '+%d/%m/%Y %H:%M')"

# Optional token env for unattended gh (keyring-free). 600-perm, user-owned.
[ -f "$HOME/.config/hq-update.env" ] && . "$HOME/.config/hq-update.env"

# OL defers to HL: skip if the vault was already refreshed today.
if [ "${HQ_DEFER:-0}" = "1" ] && [ -f "$STATUS" ] && grep -q "Last refresh: $TODAY" "$STATUS"; then
  echo "hq_run[$HOST_TAG]: already refreshed today ($TODAY) — skipping."
  exit 0
fi

mkdir -p "$VAULT/HQ"
# Capture stdout ONLY; let stderr flow to the terminal/cron log. Folding stderr into
# $BODY would let a Python traceback land in Status.md, defeating the deterministic snapshot.
ERRLOG="$(mktemp)"
BODY="$(python3 "$DIR/hq_pull.py" --vault "$VAULT" 2>"$ERRLOG")"
RC=$?
if [ "$RC" -ne 0 ] || [ -z "$BODY" ]; then
  echo "hq_run[$HOST_TAG]: hq_pull.py failed (exit $RC) or produced no output — leaving Status.md untouched." >&2
  [ -s "$ERRLOG" ] && sed 's/^/hq_run[stderr]: /' "$ERRLOG" >&2
  rm -f "$ERRLOG"
  exit 1
fi
rm -f "$ERRLOG"

{
  echo "---"
  echo "type: index"
  echo "title: HQ — Live Status Snapshot"
  echo "updated: \"$TODAY\""
  echo "---"
  echo
  echo "# HQ — Live Status Snapshot"
  echo
  echo "> _Last refresh: $NOW ($HOST_TAG)_ — deterministic pull, regenerated every run."
  echo "> Curation, Inbound triage, and PR next-actions happen in an augmented \`hq-update\`"
  echo "> session, not here. See [[CLAUDE|HQ CLAUDE.md]] · [[Dashboard]]."
  echo
  echo "$BODY"
} > "$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"

echo "hq_run[$HOST_TAG]: wrote $STATUS at $NOW"
