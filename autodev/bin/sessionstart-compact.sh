#!/usr/bin/env bash
# SessionStart hook (matcher/source: compact), shared by Claude Code and Codex.
# It records compaction completion and injects this session's reload instruction.
input=$(cat)
: "${AUTODEV_HOME:=$HOME/agents}"; export AUTODEV_HOME
STATE="$AUTODEV_HOME/state"
mkdir -p "$STATE" 2>/dev/null

sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
tpath=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
[ -z "$sid" ] && [ -n "$tpath" ] && sid=$(basename "$tpath" .jsonl)
[ -n "$sid" ] && printf '%s\n' "$(date +%s)" > "$STATE/$sid.compacted" 2>/dev/null

# Read THIS session's own pointer, and only it. Built-in auto-compaction can fire
# with no handoff, while the shared .latest pointer may belong to another live
# session. Missing session-local state therefore fails closed.
ctx="A compaction just occurred and no handoff is registered for THIS session. Do not adopt another session's handoff from $AUTODEV_HOME/handoffs — re-orient from this session's own transcript and continue, or ask the user."
if [ -n "$sid" ] && [ -f "$AUTODEV_HOME/handoffs/.latest.$sid" ]; then
  hf=$(cat "$AUTODEV_HOME/handoffs/.latest.$sid" 2>/dev/null)
  if [ -n "$hf" ] && [ -f "$hf" ]; then
    ctx="A handoff was written just before this compaction. Read it now and continue execution from where it leaves off: $hf"
  fi
fi
jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
exit 0
