#!/usr/bin/env bash
# Bug: a question put to the user was answered with no human input.
#
# Root cause: the watchers' pre-send idle gate is mux_busy, and on herdr it
# classified agent_status `blocked` as "at a prompt => safe". herdr reports
# `blocked` while an agent waits on the USER — an AskUserQuestion menu or a
# permission prompt. A cold-cache handoff then sent "/handoff" + Enter; the menu
# swallowed the text and Enter picked the highlighted (Recommended) option. On a
# permission prompt the same Enter approves the action.
#
# Every other test stubs mux_busy out (lib.sh), so this one sources the REAL
# mux-lib.sh and stubs only its two inputs: agent status and a readable idle
# screen. An unreadable screen is deliberately busy under the stronger gate.

. "$(dirname "$0")/lib.sh"

busy_for() ( # $1 = herdr agent_status; prints busy|safe from the real mux_busy
  MUX=herdr STUB_STATUS="$1"
  . "$(dirname "$0")/../bin/mux-lib.sh"
  mux_status(){ printf '%s\n' "$STUB_STATUS"; }
  mux_read_screen(){ cat "$SKILL_DIR/test/fixtures/panes/idle-prompt.txt"; }
  mux_busy && echo busy || echo safe
)

echo "== herdr agent_status -> pre-send gate (real mux-lib.sh) =="
assert_eq "working is busy"                              "$(busy_for working)" busy
assert_eq "blocked (question/permission menu) is busy"   "$(busy_for blocked)" busy
assert_eq "idle is safe"                                 "$(busy_for idle)"    safe
assert_eq "done is safe"                                 "$(busy_for done)"    safe

finish
