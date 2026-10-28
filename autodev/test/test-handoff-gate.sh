#!/usr/bin/env bash
# Bug: a /goal manager ran ONE turn for ~6 h, filing four compact-requests while
# never going idle, so the watcher (which only sends /compact into an idle pane)
# only DEFERred and every request expired unserved.
#
# cc-handoff-gate.sh is a PreToolUse hook: while this session has a request
# pending it denies every tool call except the ones that finish the handoff, so
# the model ends its turn and the Stop hook can fire the watcher. From the 3rd
# denial of one request it returns {"continue":false,...}, which stops Claude
# outright even under /goal (a plain deny only asks the model to stop).

. "$(dirname "$0")/lib.sh"

SID=77777777-7777-7777-7777-777777777777
OTHER=88888888-8888-8888-8888-888888888888
REASON='handoff pending: end your turn now so the watcher can compact; do not start new work'
STOP='{"continue":false,"stopReason":"handoff pending: stopping so the watcher can compact"}'

setup() {
  sandbox_new
  session_new "$SID" 40 "w1:p1"
  H="$AUTODEV_HOME/handoffs"
  printf '%s\n' "$H/2026.01.01 00.00.00 handoff-x.md" > "$H/.latest.$SID"
}
pending() { : > "$STATE/$SID.compact-request"; }

# gate <tool_name> <tool_input json> [sid]  -> stdout of the hook
gate() {
  [ -n "${KEEP_COUNT:-}" ] || rm -f "$STATE/$SID.gate-denials"   # each call stands alone unless counting
  jq -nc --arg s "${3:-$SID}" --arg t "$1" --argjson i "$2" \
    '{session_id:$s,tool_name:$t,tool_input:$i,hook_event_name:"PreToolUse"}' |
    bash "$BIN/cc-handoff-gate.sh" 2>/dev/null
}
bash_gate() { gate Bash "$(jq -nc --arg c "$1" '{command:$c}')"; }
decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null; }
reason()   { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null; }

echo "== no request pending: everything allowed =="
setup
out=$(gate Bash '{"command":"make test"}')
assert_eq "no request -> no output (allow)" "$out" ""
sandbox_rm

echo "== request pending: deny with the documented reason =="
setup; pending
out=$(gate Bash '{"command":"make test"}')
assert_eq "non-allow-listed Bash is denied" "$(decision "$out")" deny
assert_eq "documented reason" "$(reason "$out")" "$REASON"
out=$(gate Skill '{"skill":"tdd"}')
assert_eq "a Skill call is denied" "$(decision "$out")" deny
out=$(gate Write "$(jq -nc --arg p "$SB/elsewhere.txt" '{file_path:$p,content:"x"}')")
assert_eq "a Write outside handoffs/ is denied" "$(decision "$out")" deny
out=$(gate Write "$(jq -nc --arg p "$H/../state/x" '{file_path:$p,content:"x"}')")
assert_eq "a Write that escapes handoffs/ via .. is denied" "$(decision "$out")" deny
sandbox_rm

echo "== allow-list =="
setup; pending
out=$(gate Write "$(jq -nc --arg p "$H/2026.10.21 12.00.00 handoff-y.md" '{file_path:$p,content:"x"}')")
assert_eq "a Write under handoffs/ is allowed" "$out" ""
out=$(gate Edit "$(jq -nc --arg p "$H/2026.10.21 12.00.00 handoff-y.md" '{file_path:$p,old_string:"a",new_string:"b"}')")
assert_eq "an Edit under handoffs/ is allowed" "$out" ""
out=$(gate Read "$(jq -nc --arg p "$STATE/$SID.ctx" '{file_path:$p}')")
assert_eq "reading this session's state file is allowed" "$out" ""
out=$(gate Read "$(jq -nc --arg p "$STATE/$OTHER.ctx" '{file_path:$p}')")
assert_eq "reading ANOTHER session's state file is denied" "$(decision "$out")" deny
out=$(bash_gate "bash /x/autodev/bin/request-handoff.sh --compact-only --handoff '$H/h.md'")
assert_eq "request-handoff.sh is allowed" "$out" ""
out=$(bash_gate "bash /x/autodev/bin/request-handoff.sh --cancel; rm -rf /")
assert_eq "request-handoff.sh chained with rm is denied" "$(decision "$out")" deny
out=$(bash_gate 'bash /x/autodev/bin/request-handoff.sh $(rm -rf /)')
assert_eq "request-handoff.sh with command substitution is denied" "$(decision "$out")" deny
out=$(bash_gate "cat $STATE/$SID.ctx | sh")
assert_eq "a pipe is denied" "$(decision "$out")" deny
sandbox_rm

echo "== the handoff skill's own finishing commands are never denied =="
setup; pending
# Literal commands from handoff/SKILL.md, Write Workflow (after filing).
seq_ok=1
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  out=$(bash_gate "$cmd")
  [ -z "$out" ] || { seq_ok=0; _fail "skill command denied" "$cmd"; }
done <<'EOF'
sid="${CLAUDE_CODE_SESSION_ID:-${CODEX_SESSION_ID:-${CODEX_THREAD_ID:-}}}"
ls -la "$HOME/agents/state/$sid".{compact-request,handoff-request} 2>/dev/null
ls -la "$HOME/agents/handoffs/.latest.$sid" 2>/dev/null
cat "$HOME/agents/state/$sid.ctx" 2>/dev/null
hf="/home/u/agents/handoffs/2026.10.21 12.00.00 handoff-y.md"; tmp="$HOME/agents/handoffs/.latest.tmp"; printf '%s\n' "$hf" > "$tmp" && mv "$tmp" "$HOME/agents/handoffs/.latest"
rh=""; for root in "$HOME/.agents/skills" "$HOME/.claude/skills" "$HOME/.codex/skills"; do [ -x "$root/autodev/bin/request-handoff.sh" ] && { rh="$root/autodev/bin/request-handoff.sh"; break; }; done; [ -x "$rh" ] && bash "$rh" --compact-only --handoff "$hf" 2>/dev/null || true
EOF
[ "$seq_ok" = 1 ] && _pass "none of the skill's verify/pointer/request commands is denied"
out=$(bash_gate 'ls -la "$HOME/agents/state/other-session.ctx"')
assert_eq "ls of a DIFFERENT session's state file is denied" "$(decision "$out")" deny
out=$(bash_gate 'ls -la /etc')
assert_eq "ls of an arbitrary path is denied" "$(decision "$out")" deny
out=$(bash_gate 'mv "$HOME/agents/handoffs/.latest.tmp" /etc/passwd')
assert_eq "mv out of handoffs/.latest* is denied" "$(decision "$out")" deny
sandbox_rm

echo "== escalation to continue:false from the 3rd denial =="
setup; pending
export KEEP_COUNT=1
o1=$(gate Bash '{"command":"a"}'); o2=$(gate Bash '{"command":"b"}'); o3=$(gate Bash '{"command":"c"}'); o4=$(gate Bash '{"command":"d"}')
assert_eq "1st denial is deny+reason" "$(decision "$o1")" deny
assert_eq "2nd denial is deny+reason" "$(decision "$o2")" deny
assert_eq "3rd denial is exactly the continue:false JSON" "$o3" "$STOP"
assert_eq "4th denial stays continue:false" "$o4" "$STOP"
out=$(bash_gate "cat $STATE/$SID.ctx")
assert_eq "an allowed call does not count and is still allowed" "$out" ""
# A new request (new mtime) resets the counter.
touch -d '2 minutes ago' "$STATE/$SID.compact-request"
rm -f "$STATE/$SID.gate-denials"
gate Bash '{"command":"a"}' >/dev/null; gate Bash '{"command":"b"}' >/dev/null; gate Bash '{"command":"c"}' >/dev/null
rm -f "$STATE/$SID.compact-request"; pending; touch -d '1 minute ago' "$STATE/$SID.compact-request"
out=$(gate Bash '{"command":"x"}')
assert_eq "a newly filed request resets the counter: deny+reason again" "$(decision "$out")" deny
unset KEEP_COUNT
sandbox_rm

echo "== tool names Claude Code sends =="
setup; pending
out=$(gate MultiEdit "$(jq -nc --arg p "$H/h.md" '{file_path:$p,edits:[]}')")
assert_eq "MultiEdit under handoffs/ is allowed" "$out" ""
out=$(gate MultiEdit "$(jq -nc --arg p "$SB/x" '{file_path:$p,edits:[]}')")
assert_eq "MultiEdit elsewhere is denied" "$(decision "$out")" deny
out=$(gate NotebookEdit "$(jq -nc --arg p "$H/n.ipynb" '{notebook_path:$p}')")
assert_eq "NotebookEdit under handoffs/ is allowed" "$out" ""
out=$(gate NotebookEdit "$(jq -nc --arg p "$SB/n.ipynb" '{notebook_path:$p}')")
assert_eq "NotebookEdit elsewhere is denied" "$(decision "$out")" deny
for t in mcp__slack__post Task Agent SendMessage TodoWrite WebFetch WebSearch ExitPlanMode; do
  out=$(gate "$t" '{}')
  assert_eq "$t is denied" "$(decision "$out")" deny
done
sandbox_rm

echo "== path forms that must not escape the handoffs/ match =="
setup; pending
for p in "handoffs/h.md" "~/agents/handoffs/h.md" '$HOME/agents/handoffs/h.md' "$H/sub/../../x"; do
  out=$(gate Write "$(jq -nc --arg p "$p" '{file_path:$p,content:"x"}')")
  assert_eq "Write to [$p] is denied (a file tool does not expand it)" "$(decision "$out")" deny
done
outside="$SB/outside"; mkdir -p "$outside"
ln -s "$outside" "$H/link"
out=$(gate Write "$(jq -nc --arg p "$H/link/x.md" '{file_path:$p,content:"x"}')")
assert_eq "Write through a symlink in handoffs/ that points out is denied" "$(decision "$out")" deny
out=$(gate Read "$(jq -nc --arg p "$H/link/x.md" '{file_path:$p}')")
assert_eq "Read through such a symlink is denied" "$(decision "$out")" deny
out=$(gate Write "$(jq -nc --arg p "$H/new/h.md" '{file_path:$p,content:"x"}')")
assert_eq "Write to a not-yet-existing subpath of handoffs/ is allowed" "$out" ""
ln -s "$outside/pwn" "$H/.latest.tmp"
out=$(bash_gate "printf '%s\\n' x > $H/.latest.tmp")
assert_eq "printf > a .latest.tmp that is a symlink is denied" "$(decision "$out")" deny
out=$(gate Read "$(jq -nc --arg p "$STATE/$SID.sub/x" '{file_path:$p}')")
assert_eq "Read of a path BELOW a <sid>.* name is denied" "$(decision "$out")" deny
sandbox_rm

echo "== request/compaction boundary is sub-second =="
setup; pending
touch -d '@1000000000.100000000' "$STATE/$SID.compact-request"
touch -d '@1000000000.900000000' "$STATE/$SID.compacted"
out=$(gate Bash '{"command":"make test"}')
assert_eq "compaction later in the SAME second as the request -> satisfied" "$out" ""
touch -d '@1000000000.900000000' "$STATE/$SID.compact-request"
touch -d '@1000000000.100000000' "$STATE/$SID.compacted"
out=$(gate Bash '{"command":"make test"}')
assert_eq "request filed after the compaction in the same second -> engaged" "$(decision "$out")" deny
touch -r "$STATE/$SID.compact-request" "$STATE/$SID.compacted"
out=$(gate Bash '{"command":"make test"}')
assert_eq "exact tie is kept (a lost request parks the session)" "$(decision "$out")" deny
sandbox_rm

echo "== denial counter keys on the exact request, not the second =="
setup; pending
export KEEP_COUNT=1
touch -d '@1000000000.100000000' "$STATE/$SID.compact-request"
gate Bash '{"command":"a"}' >/dev/null; gate Bash '{"command":"b"}' >/dev/null
touch -d '@1000000000.700000000' "$STATE/$SID.compact-request"
out=$(gate Bash '{"command":"c"}')
assert_eq "a new request within the same second resets the counter" "$(decision "$out")" deny
unset KEEP_COUNT
sandbox_rm

# Use this test process as the live owner; it cannot expire during assertions.
cycle_live() {
  /bin/ln -s "/dev/null/autodev-lock-owner/$$" "$STATE/$SID.cycle.lock"
  printf '%s\n' "$$" > "$STATE/$SID.cycle-handoff"
}

echo "== housekeeping and stale phase markers do not engage the gate =="
setup; cycle_live
rm -f "$STATE/$SID.cycle-handoff"
for t in Agent Task SendMessage Bash; do
  out=$(gate "$t" '{"command":"make test","run_in_background":true}')
  assert_eq "housekeeping lock without a phase: $t allowed" "$out" ""
done
# A different live PID is no more authoritative than a missing marker.
sleep 30 & other_pid=$!
printf '%s\n' "$other_pid" > "$STATE/$SID.cycle-handoff"
out=$(gate Agent '{}')
assert_eq "phase PID mismatches live lock owner -> Agent allowed" "$out" ""
kill "$other_pid" 2>/dev/null; wait "$other_pid" 2>/dev/null
out=$(gate Agent '{}')
assert_eq "dead phase PID mismatches live lock owner -> Agent allowed" "$out" ""
rm -f "$STATE/$SID.cycle.lock"
/bin/ln -s "/dev/null/autodev-lock-owner/$other_pid" "$STATE/$SID.cycle.lock"
out=$(gate Agent '{}')
assert_eq "matching phase and lock PID is dead -> Agent allowed" "$out" ""
rm -f "$STATE/$SID.cycle.lock"
out=$(gate Agent '{}')
assert_eq "orphan phase without a lock -> Agent allowed" "$out" ""
# A pending request remains sufficient regardless of the housekeeping phase.
/bin/ln -s "/dev/null/autodev-lock-owner/$$" "$STATE/$SID.cycle.lock"
pending
out=$(gate Agent '{}')
assert_eq "pending request still denies Agent during housekeeping" "$(decision "$out")" deny
sandbox_rm

echo "== live cycle blocks delegated/background work, with either request =="
for request in compact-request handoff-request; do
  setup; : > "$STATE/$SID.$request"; cycle_live
  for t in Agent Task SendMessage; do
    out=$(gate "$t" '{"resume":"existing-agent"}')
    assert_eq "$request: live cycle denies $t resume" "$(decision "$out")" deny
    assert_eq "$request: live cycle explains how to yield" "$(reason "$out")" "$REASON"
  done
  # Even an otherwise allowed handoff command must not escape in the background.
  cmd="bash /x/autodev/bin/request-handoff.sh --compact-only --handoff '$H/h.md'"
  out=$(gate Bash "$(jq -nc --arg c "$cmd" '{command:$c,run_in_background:true}')")
  assert_eq "$request: live cycle denies background handoff Bash" "$(decision "$out")" deny
  out=$(gate Bash "$(jq -nc --arg c "$cmd" '{command:$c,run_in_background:false}')")
  assert_eq "$request: foreground handoff Bash is allowed" "$out" ""
  out=$(gate Write "$(jq -nc --arg p "$H/h.md" '{file_path:$p,content:"handoff"}')")
  assert_eq "$request: handoff Write is allowed" "$out" ""
  out=$(bash_gate 'git add handoff.md && git commit -m "save handoff"')
  assert_eq "$request: live cycle allows foreground git add/commit" "$out" ""
  out=$(gate Skill '{"skill":"handoff"}')
  assert_eq "$request: live cycle allows other non-delegating tools" "$out" ""
  # The counter applies equally to all ways of starting delegated work.
  export KEEP_COUNT=1
  rm -f "$STATE/$SID.gate-denials"
  o1=$(gate Agent '{}'); o2=$(gate SendMessage '{}')
  o3=$(gate Bash "$(jq -nc --arg c "$cmd" '{command:$c,run_in_background:true}')")
  assert_eq "$request: first cycle denial" "$(decision "$o1")" deny
  assert_eq "$request: second cycle denial" "$(decision "$o2")" deny
  assert_eq "$request: third cycle denial stops the turn" "$o3" "$STOP"
  unset KEEP_COUNT
  sandbox_rm
done

echo "== live cycle without a request still gates new work =="
setup; cycle_live
for t in Agent Task SendMessage; do
  out=$(gate "$t" '{}')
  assert_eq "no request: live cycle denies $t launch" "$(decision "$out")" deny
done
out=$(gate Bash '{"command":"cat /dev/null","run_in_background":true}')
assert_eq "no request: background Bash is denied" "$(decision "$out")" deny
for t in Read Write Edit; do
  out=$(gate "$t" "$(jq -nc --arg p "$SB/project/file.md" '{file_path:$p}')")
  assert_eq "no request: live cycle allows handoff preparation via $t" "$out" ""
done
out=$(bash_gate 'bash /x/autodev/bin/request-handoff.sh --compact-only')
assert_eq "no request: live cycle allows filing the handoff request" "$out" ""
out=$(bash_gate 'git commit -m "save handoff"')
assert_eq "no request: live cycle allows git commit" "$out" ""
out=$(bash_gate 'make test')
assert_eq "no request: live cycle allows arbitrary foreground Bash" "$out" ""
out=$(gate Skill '{"skill":"handoff"}')
assert_eq "no request: live cycle allows other non-delegating tools" "$out" ""
export KEEP_COUNT=1
rm -f "$STATE/$SID.gate-denials"
o1=$(gate Agent '{}'); o2=$(gate Agent '{}'); o3=$(gate Agent '{}')
assert_eq "no request: first cycle denial" "$(decision "$o1")" deny
assert_eq "no request: second cycle denial" "$(decision "$o2")" deny
assert_eq "no request: third cycle denial stops the turn" "$o3" "$STOP"
# A replacement cycle must not inherit an exhausted counter from the last one.
rm -f "$STATE/$SID.cycle.lock"
mkdir "$STATE/$SID.cycle.lock"
printf '%s\n' "$$" > "$STATE/$SID.cycle.lock/pid"
out=$(gate Agent '{}')
assert_eq "replacement legacy cycle resets cycle-only denials" "$(decision "$out")" deny
unset KEEP_COUNT
rm -rf "$STATE/$SID.cycle.lock"
out=$(gate Agent '{}')
assert_eq "cycle released with no request -> normal tools allowed again" "$out" ""
sandbox_rm

echo "== only a live owner gives the handoff preparation exemption =="
setup; pending
sleep 30 & lp=$!
kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
/bin/ln -s "/dev/null/autodev-lock-owner/$lp" "$STATE/$SID.cycle.lock"
out=$(gate Write "$(jq -nc --arg p "$SB/project/file.md" '{file_path:$p}')")
assert_eq "dead cycle lock -> normal pending-request restrictions" "$(decision "$out")" deny
sandbox_rm

# Environments that cannot evaluate the allow-list fail OPEN, never closed.
setup; pending
fb="$SB/nort"; mkdir -p "$fb"
for t in jq date mv rm cat head basename dirname sed grep tr mkdir; do ln -s "$(command -v $t)" "$fb/$t"; done
out=$(jq -nc --arg s "$SID" --arg p "$SB/elsewhere" '{session_id:$s,tool_name:"Write",tool_input:{file_path:$p}}' | env PATH="$fb" "$(command -v bash)" "$BIN/cc-handoff-gate.sh" 2>/dev/null)
assert_eq "no realpath on this box -> allow (not deny every file tool)" "$out" ""
out=$(printf '{"session_id":"%s","tool_name":"Bash","tool_input":"oops"}' "$SID" | bash "$BIN/cc-handoff-gate.sh" 2>/dev/null)
assert_eq "a malformed tool_input fails open" "$out" ""
sandbox_rm

# A new request after a spent counter starts from zero.
setup; pending
export KEEP_COUNT=1
for c in a b c; do gate Bash "{\"command\":\"$c\"}" >/dev/null; done
rm -f "$STATE/$SID.compact-request"; : > "$STATE/$SID.compact-request"
out=$(gate Bash '{"command":"d"}')
assert_eq "a re-filed request is not born at continue:false" "$(decision "$out")" deny
unset KEEP_COUNT
sandbox_rm

# The marker is gone the moment the watcher commits to the cycle, so the very
# calls /handoff needs are not gated. (Consumed-at-TRIGGER is pinned in the
# watcher's own tests; here: no marker, nothing denied.)
setup
out=$(gate Skill '{"skill":"handoff"}')
assert_eq "with the marker consumed, the handoff skill's own calls pass" "$out" ""
sandbox_rm

echo "== never engaged =="
setup; pending
printf '%s\n' "$(date +%s)" > "$STATE/$SID.compacted"
touch -d '1 minute ago' "$STATE/$SID.compact-request"
out=$(gate Bash '{"command":"make test"}')
assert_eq "request older than the last compaction is satisfied -> allow" "$out" ""
sandbox_rm

setup; pending
out=$(gate Bash '{"command":"make test"}' "$OTHER")
assert_eq "another session's request denies nothing here" "$out" ""
sandbox_rm

setup; pending; rm -f "$STATE/$SID.herdr-pane"
out=$(gate Bash '{"command":"make test"}')
assert_eq "no registered pane (watcher can never act) -> allow" "$out" ""
sandbox_rm

setup; pending
out=$(AUTODEV_NO_HANDOFF_GATE=1 gate Bash '{"command":"make test"}')
assert_eq "env bypass allows" "$out" ""
: > "$STATE/$SID.no-handoff-gate"
out=$(gate Bash '{"command":"make test"}')
assert_eq "per-session flag file bypass allows" "$out" ""
rm -f "$STATE/$SID.no-handoff-gate"; : > "$STATE/disable-handoff-gate"
out=$(gate Bash '{"command":"make test"}')
assert_eq "global flag file bypass allows" "$out" ""
sandbox_rm

setup; pending
out=$(printf 'not json{' | bash "$BIN/cc-handoff-gate.sh" 2>/dev/null); rc=$?
assert_eq "garbage stdin fails open (no output)" "$out" ""
assert_eq "garbage stdin fails open (exit 0)" "$rc" 0
sandbox_rm

echo "== live cycle preserves bypasses and missing-pane fail-open =="
for request in none compact-request; do
  setup; cycle_live
  [ "$request" = none ] || pending
  for mode in env session global no-pane; do
    case "$mode" in
      env) export AUTODEV_NO_HANDOFF_GATE=1 ;;
      session) : > "$STATE/$SID.no-handoff-gate" ;;
      global) : > "$STATE/disable-handoff-gate" ;;
      no-pane) rm -f "$STATE/$SID.herdr-pane" ;;
    esac
    for t in Agent Task SendMessage Bash; do
      out=$(gate "$t" '{"command":"make test","run_in_background":true}')
      assert_eq "$request / $mode: $t allowed" "$out" ""
    done
    unset AUTODEV_NO_HANDOFF_GATE
    rm -f "$STATE/$SID.no-handoff-gate" "$STATE/disable-handoff-gate"
  done
  sandbox_rm
done

echo "== pending request without a cycle still denies background Bash =="
setup; pending
out=$(gate Bash "$(jq -nc --arg c "cat $STATE/$SID.ctx" '{command:$c,run_in_background:true}')")
assert_eq "allow-listed Bash cannot run in background with a pending request" "$(decision "$out")" deny
sandbox_rm

echo "== handoff-request also engages the gate =="
setup; : > "$STATE/$SID.handoff-request"
out=$(gate Bash '{"command":"make test"}')
assert_eq "handoff-request denies" "$(decision "$out")" deny
sandbox_rm

echo "== watcher publishes the phase before handoff and clears it on release =="
for mode in complete abort replaced; do
  setup; stub_mux; arm
  handoff_pointer "$SID"
  export MUX_LIVE_PANES="w1:p1" MUX_BUSY=0 PHASE_TEST_MODE="$mode"
  # Observe at the actual send boundary, then simulate the session responses.
  # Returning an error exercises release on ABORT without waiting for a timeout.
  cat >> "$BIN/mux-lib.sh" <<'STUB'
mux_send_line(){
  printf '%s\n' "$1" >> "$SB/sent.log"
  case "$1" in
    /handoff)
      printf '%s\n' "$$" > "$SB/watcher-pid"
      cat "$STATE/$sid.cycle-handoff" > "$SB/phase-at-handoff" 2>/dev/null
      autodev_lock_read_owner "$STATE/$sid.cycle.lock"
      printf '%s\n' "$lock_owner_pid" > "$SB/owner-at-handoff"
      jq -nc --arg s "$sid" '{session_id:$s,tool_name:"Agent",tool_input:{}}' |
        bash "$_HERE/cc-handoff-gate.sh" > "$SB/gate-at-handoff"
      case "$PHASE_TEST_MODE" in
        abort) return 1 ;;
        replaced) printf '%s\n' replacement-owner > "$STATE/$sid.cycle-handoff"; return 1 ;;
      esac
      printf '%s\n' "$(( $(date +%s) + 1 ))" > "$STATE/$sid.idle" ;;
    /compact)
      printf '%s\n' "$(( $(date +%s) + 1 ))" > "$STATE/$sid.compacted" ;;
  esac
  return 0
}
STUB
  AUTODEV_SETTLE=0 AUTODEV_WAIT_IDLE=5 AUTODEV_WAIT_COMPACT=5 \
    bash "$BIN/auto-handoff-watch.sh" "$SID" > "$SB/watcher.stdout" 2> "$SB/watcher.stderr"
  assert_file "$mode: watcher reached the handoff send" "$SB/watcher-pid"
  pid=$(cat "$SB/watcher-pid" 2>/dev/null)
  assert_eq "$mode: phase is published before the send" "$(cat "$SB/phase-at-handoff" 2>/dev/null)" "$pid"
  assert_eq "$mode: phase matches the lock owner" "$(cat "$SB/owner-at-handoff" 2>/dev/null)" "$pid"
  assert_eq "$mode: Agent denied during actual handoff" "$(decision "$(cat "$SB/gate-at-handoff" 2>/dev/null)")" deny
  assert_lock_absent "$mode: watcher released its lock" "$STATE/$SID.cycle.lock"
  if [ "$mode" = replaced ]; then
    assert_eq "cleanup preserves a replacement's phase" "$(cat "$STATE/$SID.cycle-handoff" 2>/dev/null)" replacement-owner
  else
    assert_no_file "$mode: watcher cleared its phase" "$STATE/$SID.cycle-handoff"
  fi
  if [ "$mode" = complete ]; then
    assert_contains "cycle completed after the handoff" "$(cat "$AUTODEV_HOME/logs/auto-handoff.log")" 'CYCLE COMPLETE'
  else
    assert_contains "$mode: abort path was exercised" "$(cat "$AUTODEV_HOME/logs/auto-handoff.log")" 'ABORT send failed'
  fi
  unset PHASE_TEST_MODE
  sandbox_rm
done

finish
