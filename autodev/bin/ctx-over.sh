#!/usr/bin/env bash
# ctx-over.sh <sid> — is this session past its handoff line?
#
# The model-facing half of threshold-lib.sh. The autodev checkpoint beat calls
# this instead of comparing `pct` with 35 itself, so the model and the watcher
# ask one question with one answer: 35% for most sessions, the token line
# (200,000 by default) for a Persona seat on a window larger than that line.
# It compares the percent as the watcher's trigger does (pct > line).
#
# Prints one line, e.g. `ctx: over (tok=210000 >= 200000)` or
# `ctx: below (pct=20 below 35)`.
# Exit: 0 over the line, 1 below it, 2 no usable reading (no sid or no .ctx).
# Read-only: it never writes state and never triggers anything.

: "${AUTODEV_HOME:=$HOME/agents}"
STATE="$AUTODEV_HOME/state"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=threshold-lib.sh
. "$HERE/threshold-lib.sh" || { echo "ctx: unknown (threshold-lib.sh missing)"; exit 2; }

sid=${1:-}
case "$sid" in
  ''|unknown|*/*) echo "ctx: unknown (no session id)"; exit 2 ;;
esac

autodev_ctx_over "$STATE" "$sid" gt; rc=$?
# shellcheck disable=SC2154  # ctx_reason is set by autodev_ctx_over
case "$rc" in
  0) echo "ctx: over ($ctx_reason)" ;;
  1) echo "ctx: below ($ctx_reason)" ;;
  *) echo "ctx: unknown (no reading in $STATE/$sid.ctx)"; rc=2 ;;
esac
exit "$rc"
