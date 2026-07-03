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

ptr="$AUTODEV_HOME/handoffs/.latest"
ctx="A compaction just occurred. If a recent handoff exists in $AUTODEV_HOME/handoffs, read the newest one and continue."
if [ -f "$ptr" ]; then
  hf=$(cat "$ptr" 2>/dev/null)
  if [ -n "$hf" ] && [ -f "$hf" ]; then
    ctx="A handoff was written just before this compaction. Read it now with the Read tool and continue execution from where it leaves off: $hf"
  fi
fi
jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
exit 0
