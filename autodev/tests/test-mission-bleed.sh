#!/usr/bin/env bash
# Bug: a compacting session can be handed ANOTHER session's handoff and silently
# resume the wrong mission, while its pane still reads healthy.
#
# ~/agents/handoffs/.latest is a single machine-wide, last-writer-wins pointer.
# With ~25 concurrent sessions on this box, every consumer that reads it — or
# that tells the agent to "read the newest handoff" — is reading whichever
# session happened to hand off most recently. These tests pin the contract:
# a session may only ever be pointed at ITS OWN handoff.

. "$(dirname "$0")/lib.sh"

# H1 below belongs to some other session on the box; S2 is the session under test.
S2=22222222-2222-2222-2222-222222222222

setup() {
  sandbox_new
  stub_mux
  H1="$AUTODEV_HOME/handoffs/2026.01.01 00.00.00 handoff-someone-elses-mission.md"
  H2="$AUTODEV_HOME/handoffs/2026.01.02 00.00.00 handoff-our-own-mission.md"
  printf 'mission belonging to S1\n' > "$H1"
  printf 'mission belonging to S2\n' > "$H2"
}

hook_ctx() { # $1 = sid -> the additionalContext the SessionStart hook injects
  printf '{"session_id":"%s"}' "$1" \
    | bash "$BIN/cc-sessionstart-compact.sh" \
    | jq -r '.hookSpecificOutput.additionalContext'
}

# Answer the watcher's /compact by writing the completion marker CC's
# SessionStart hook would normally write.
compaction_responder() { # $1 = sid
  (
    for _ in $(seq 1 200); do
      if grep -qxF '/compact' "$SB/sent.log" 2>/dev/null; then
        sleep 1
        printf '%s\n' "$(date +%s)" > "$STATE/$1.compacted"
        exit 0
      fi
      sleep 0.5
    done
  ) &
}

echo "== SessionStart(compact) hook =="

# The CKMG failure mode: CC's own built-in auto-compaction fires with no
# per-session pointer written, so the hook falls back to the shared .latest.
setup
printf '%s\n' "$H1" > "$AUTODEV_HOME/handoffs/.latest"
ctx=$(hook_ctx "$S2")
assert_not_contains "hook: no pointer => does not name another session's handoff" "$ctx" "$H1"
assert_not_contains "hook: no pointer => does not say 'read the newest'" "$ctx" "newest"
sandbox_rm

# The legitimate path must keep working.
setup
printf '%s\n' "$H1" > "$AUTODEV_HOME/handoffs/.latest"
printf '%s\n' "$H2" > "$AUTODEV_HOME/handoffs/.latest.$S2"
ctx=$(hook_ctx "$S2")
assert_contains "hook: own pointer => names our own handoff" "$ctx" "$H2"
assert_not_contains "hook: own pointer => never names the foreign one" "$ctx" "$H1"
sandbox_rm

echo "== request-handoff.sh =="

# The pointer must be derived from the path the session actually wrote, not
# copied out of a shared file another session may already have clobbered.
setup
printf '%s\n' "$H1" > "$AUTODEV_HOME/handoffs/.latest"   # clobbered by S1 already
bash "$BIN/request-handoff.sh" "$S2" --compact-only --handoff "$H2" >/dev/null 2>&1
got=$(cat "$AUTODEV_HOME/handoffs/.latest.$S2" 2>/dev/null)
assert_eq "request-handoff: --handoff wins over a clobbered .latest" "$got" "$H2"
sandbox_rm

echo "== auto-handoff-watch.sh reload =="

# Watcher, compact-only cycle, no per-session pointer: it must not fall back to
# the shared pointer nor tell the agent to read "the newest handoff".
setup
arm
session_new "$S2" 45 "w1:p1"
export MUX_LIVE_PANES="w1:p1" MUX_BUSY=0
printf '%s\n' "$H1" > "$AUTODEV_HOME/handoffs/.latest"
: > "$STATE/$S2.compact-request"
compaction_responder "$S2"
bash "$BIN/auto-handoff-watch.sh" "$S2" >/dev/null 2>&1
sent=$(cat "$SB/sent.log")
assert_not_contains "watcher: no pointer => never sends a foreign handoff path" "$sent" "$H1"
assert_not_contains "watcher: no pointer => never says 'newest handoff'" "$sent" "newest handoff"
sandbox_rm

# Same cycle, but our own pointer exists: it must be used verbatim.
setup
arm
session_new "$S2" 45 "w1:p1"
export MUX_LIVE_PANES="w1:p1" MUX_BUSY=0
printf '%s\n' "$H1" > "$AUTODEV_HOME/handoffs/.latest"
printf '%s\n' "$H2" > "$AUTODEV_HOME/handoffs/.latest.$S2"
: > "$STATE/$S2.compact-request"
compaction_responder "$S2"
bash "$BIN/auto-handoff-watch.sh" "$S2" >/dev/null 2>&1
sent=$(cat "$SB/sent.log")
assert_contains "watcher: own pointer => reloads our own handoff" "$sent" "$H2"
assert_not_contains "watcher: own pointer => never the foreign one" "$sent" "$H1"
sandbox_rm

finish
