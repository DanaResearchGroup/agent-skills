#!/usr/bin/env bash
# prune-stale-panes.sh — conservative cleanup of stale pane registrations.
#
# Over time ~/agents/state accumulates <sid>.{herdr,tmux}-pane files from dead
# sessions. Two kinds are stale:
#   1. the pane no longer exists at all (session gone), or
#   2. the pane is live but herdr/tmux recycled its id to a DIFFERENT session
#      (the shadow that used to mis-target the watchers — see mux-lib.sh).
# Removing either is safe. This NEVER removes a binding for a session that still
# owns a live pane, so it cannot disturb a running session.
#
# Usage:
#   prune-stale-panes.sh            # dry-run: list what WOULD be removed
#   prune-stale-panes.sh --apply    # actually remove
set -u
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1

: "${AUTODEV_HOME:=$HOME/agents}"
STATE="$AUTODEV_HOME/state"
_HERE="$(cd "$(dirname "$0")" && pwd)"
. "$_HERE/mux-lib.sh"

removed=0 kept=0 checked=0
for f in "$STATE"/*.herdr-pane "$STATE"/*.tmux-pane; do
  [ -e "$f" ] || continue
  checked=$((checked+1))
  base="$(basename "$f")"
  case "$base" in
    *.herdr-pane) MUX=herdr; sid="${base%.herdr-pane}" ;;
    *.tmux-pane)  MUX=tmux;  sid="${base%.tmux-pane}" ;;
  esac
  PANE="$(cat "$f" 2>/dev/null)"
  [ -n "$PANE" ] || { echo "PRUNE (empty)      $base"; [ "$APPLY" = 1 ] && rm -f "$f"; removed=$((removed+1)); continue; }

  if ! mux_pane_live; then
    echo "PRUNE (pane gone)  $base -> $PANE"
    [ "$APPLY" = 1 ] && rm -f "$f"; removed=$((removed+1)); continue
  fi
  owner="$(mux_pane_owner)"
  if [ -n "$owner" ] && [ "$owner" != "$sid" ]; then
    echo "PRUNE (reused)     $base -> $PANE now owned by $owner"
    [ "$APPLY" = 1 ] && rm -f "$f"; removed=$((removed+1)); continue
  fi
  kept=$((kept+1))   # pane live and (owner==sid, or owner unknown) => keep
done

echo "----"
echo "checked=$checked  would_remove=$removed  kept(live+ours)=$kept  mode=$([ "$APPLY" = 1 ] && echo APPLY || echo DRY-RUN)"