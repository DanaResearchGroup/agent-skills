#!/usr/bin/env bash
# Claude Code SessionStart hook (matcher: compact). Fires after a compaction.
# 1) Writes a completion marker the watcher waits on.
# 2) Injects a reload instruction as additionalContext (backup path so the
#    handoff is loaded even if no external watcher is driving the session).
input=$(cat)
: "${AUTODEV_HOME:=$HOME/agents}"; export AUTODEV_HOME
STATE="$AUTODEV_HOME/state"
mkdir -p "$STATE" 2>/dev/null

sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
tpath=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
[ -z "$sid" ] && [ -n "$tpath" ] && sid=$(basename "$tpath" .jsonl)
[ -n "$sid" ] && printf '%s\n' "$(date +%s)" > "$STATE/$sid.compacted" 2>/dev/null

# Read THIS session's own pointer, and only it.
#
# This hook also fires on Claude Code's OWN built-in auto-compaction, which no
# watcher drove and which therefore wrote no pointer. The shared .latest is a
# machine-wide, last-writer-wins file: on a box running many concurrent sessions
# it names whichever session handed off most recently. Falling back to it here —
# or telling the agent to "read the newest handoff" — is how a worker silently
# resumes someone else's mission after a compaction it never asked for, while its
# pane still reads healthy. Fail closed: no handoff beats the wrong handoff.
ctx="A compaction just occurred and no handoff is registered for THIS session. Do not adopt another session's handoff from $AUTODEV_HOME/handoffs — re-orient from this session's own transcript and continue, or ask the user."
if [ -n "$sid" ] && [ -f "$AUTODEV_HOME/handoffs/.latest.$sid" ]; then
  hf=$(cat "$AUTODEV_HOME/handoffs/.latest.$sid" 2>/dev/null)
  if [ -n "$hf" ] && [ -f "$hf" ]; then
    ctx="A handoff was written just before this compaction. Read it now with the Read tool and continue execution from where it leaves off: $hf"
  fi
fi
jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
exit 0
