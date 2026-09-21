#!/usr/bin/env bash
# Codex uses the same state machine as Claude Code, but reaches it through a
# different context source, skill invocation, session-id environment and hook
# installer. Exercise those seams together so a nominally "shared" watcher
# cannot silently remain Claude-only.

. "$(dirname "$0")/lib.sh"

SID=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee

setup() {
  sandbox_new
  stub_mux
  export MUX_LIVE_PANES="w1:p1" MUX_BUSY=0
  export MUX_CAPTURE_TEXT='Confirm compact context? Press Enter to compact.'
}

codex_payload() { # $1 = transcript
  printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Stop","cwd":"%s"}' \
    "$SID" "$1" "$SB"
}

echo "== Codex effective context extraction =="

setup
transcript="$SB/codex.jsonl"
cat > "$transcript" <<'JSONL'
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":9999999},"last_token_usage":{"input_tokens":40000,"output_tokens":2000,"total_tokens":42000},"model_context_window":200000}}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":12345678},"last_token_usage":{"input_tokens":87000,"output_tokens":3000,"total_tokens":90000},"model_context_window":200000}}}
JSONL
codex_payload "$transcript" | AUTODEV_NO_WATCHERS=1 bash "$BIN/codex-stop-hook.sh"
ctx=$(cat "$STATE/$SID.ctx" 2>/dev/null)
assert_contains "Stop hook records latest effective percentage" "$ctx" "pct=45.00"
assert_not_contains "Stop hook ignores cumulative thread usage" "$ctx" "6172"
assert_eq "Stop hook tags the session runtime" "$(cat "$STATE/$SID.runtime" 2>/dev/null)" "codex"
assert_file "Stop hook marks the Codex session idle" "$STATE/$SID.idle"
sandbox_rm

echo "== Codex session identity =="

setup
handoff="$AUTODEV_HOME/handoffs/2026.09.21 00.00.00 handoff-codex.md"
printf 'codex mission\n' > "$handoff"
export CODEX_SESSION_ID="$SID" CODEX_THREAD_ID="$SID"
out=$(bash "$BIN/request-handoff.sh" --compact-only --handoff "$handoff" 2>&1)
assert_file "request helper resolves CODEX_SESSION_ID" "$STATE/$SID.compact-request"
assert_eq "request helper records Codex's own handoff" \
  "$(cat "$AUTODEV_HOME/handoffs/.latest.$SID" 2>/dev/null)" "$handoff"
assert_contains "request helper reports the Codex session" "$out" "$SID"
sandbox_rm

echo "== Codex watcher command sequence =="

setup
arm
session_new "$SID" 45 "w1:p1"
printf 'codex\n' > "$STATE/$SID.runtime"
handoff="$AUTODEV_HOME/handoffs/2026.09.21 00.00.00 handoff-codex.md"
printf 'codex mission\n' > "$handoff"

# Model the two lifecycle edges the live Codex hooks produce: Stop after the
# $handoff turn, then SessionStart(source=compact) after /compact completes.
(
  for _ in $(seq 1 100); do
    if grep -qxF '$handoff' "$SB/sent.log" 2>/dev/null; then
      sleep 2
      printf '%s\n' "$handoff" > "$AUTODEV_HOME/handoffs/.latest.$SID"
      printf '%s\n' "$(date +%s)" > "$STATE/$SID.idle"
      break
    fi
    sleep 0.1
  done
  for _ in $(seq 1 100); do
    if grep -qxF '/compact' "$SB/sent.log" 2>/dev/null; then
      sleep 2
      printf '{"session_id":"%s","source":"compact"}' "$SID" \
        | bash "$BIN/sessionstart-compact.sh" >/dev/null
      break
    fi
    sleep 0.1
  done
) & responder=$!
AUTODEV_SETTLE=0 AUTODEV_POLL=1 AUTODEV_PRECHECK=3 \
  AUTODEV_WAIT_IDLE=12 AUTODEV_WAIT_COMPACT=12 \
  bash "$BIN/auto-handoff-watch.sh" "$SID" >/dev/null 2>&1
wait "$responder"
sent=$(cat "$SB/sent.log")
assert_line "Codex invokes a skill with dollar syntax" "$sent" '$handoff'
assert_no_line "Codex never sends Claude's slash-skill syntax" "$sent" "/handoff"
assert_line "Codex still uses the built-in compact command" "$sent" "/compact"
assert_line "Codex confirms an explicit compact prompt" "$sent" "KEY:Enter"
assert_contains "Codex reloads its per-session handoff" "$sent" "$handoff"
sandbox_rm

finish
