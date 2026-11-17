#!/usr/bin/env bash
# The auto-handoff loop that could not reach panes (2026-11-17).
#
#   1. A "screen presence unproved" <sid>.unreachable flag never expired: only a
#      later send removed it. One was written at 06:35 under a login picker and
#      was still there at 12:45 over a clear composer; 15 such flags existed.
#   2. With that flag and a pending compact request, the Stop hook (through the
#      PreToolUse gate's --stop notice) told the session to open an
#      AskUserQuestion menu: "automation cannot reach this pane".
#   3. That menu was then the open question the watcher must not answer: the
#      sweep's retries at 12:46:51, 12:49:51 and 12:52:50 each logged
#      "DEFER awaiting-human (pre-send)". Once the flags were moved away, the
#      watcher sent /compact at 12:55:11.
#
# These run the REAL mux-lib.sh, gate, Stop hook, sweep and watcher against a
# fake herdr that serves a screen and a pane list and logs every keystroke. The
# flag texts are the two shapes found in the backed-up flags, with the pane and
# session ids replaced by synthetic ones.

. "$(dirname "$0")/lib.sh"

SID=55555555-5555-5555-5555-555555555555
FX="$SKILL_DIR/test/fixtures/panes"
export TZ=Asia/Jerusalem
export AUTODEV_SETTLE=0 AUTODEV_POLL=1 AUTODEV_PRECHECK=2 AUTODEV_WAIT_IDLE=2 \
       AUTODEV_WAIT_COMPACT=2 AUTODEV_ALERT_TIMEOUT=5
ORIG_PATH="$PATH"
FLAG_NEW='screen presence unproved: pane w1:p7 lacks a live bottom-most ⟨cc:55555555⟩ before send'
FLAG_OLD='screen presence unproved: pane w1:p7 lacks ⟨cc:55555555⟩ before send'

# --- fake herdr ------------------------------------------------------------------
# $SB/herdr/screen.txt   what `pane read` returns
# $SB/herdr/panes        "pane_id session" rows for `pane list` (default: ours)
# $SB/typed.log          every pane run / send-keys
setup() {
  sandbox_new
  mkdir -p "$SB/herdr" "$SB/fakebin"
  : > "$SB/typed.log"
  printf 'idle\n' > "$SB/herdr/status"
  printf 'w1:p7 %s\n' "$SID" > "$SB/herdr/panes"
  cp "$FX/presence-clear.txt" "$SB/herdr/screen.txt"
  cat > "$SB/fakebin/herdr" <<'STUB'
#!/usr/bin/env bash
H="$SB/herdr"
case "${1:-} ${2:-}" in
  "pane get")
      grep -q "^$3 " "$H/panes" || exit 1
      printf '{"result":{"pane":{"pane_id":"%s","agent_status":"%s","agent_session":{"value":"%s"},"scroll":{"offset_from_bottom":0}}}}\n' \
        "$3" "$(cat "$H/status")" "$(awk -v p="$3" '$1==p{print $2}' "$H/panes")" ;;
  "pane list")
      awk 'BEGIN{printf "{\"result\":{\"panes\":["} NF{printf "%s{\"pane_id\":\"%s\",\"agent_session\":{\"value\":\"%s\"}}", (n++?",":""), $1, $2} END{print "]}}"}' "$H/panes" ;;
  "pane read") cat "$H/screen.txt" ;;
  "pane run") printf 'RUN %s\n' "$4" >> "$SB/typed.log" ;;
  "pane send-keys") printf 'KEY %s\n' "$4" >> "$SB/typed.log" ;;
  "pane send-text") printf 'TEXT %s\n' "$4" >> "$SB/typed.log" ;;
  "tab get") printf '{"result":{"tab":{"label":"fixture seat"}}}\n' ;;
  "tab rename") exit 0 ;;
  *) echo "fake herdr: unhandled [$*]" >&2; exit 64 ;;
esac
STUB
  chmod +x "$SB/fakebin/herdr"
  for c in slack lane; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$SB/%s.log"\nexit 0\n' "$c" > "$SB/fake-$c"
    chmod +x "$SB/fake-$c"
  done
  export PATH="$SB/fakebin:$ORIG_PATH" MUX_HERDR="$SB/fakebin/herdr" \
         AUTODEV_SLACK_CMD="$SB/fake-slack" AUTODEV_LANE_CMD="$SB/fake-lane"
  session_new "$SID" 21 "w1:p7"
  session_tab "$SID" "w1:t1" "fixture seat"
  printf 'claude\n' > "$STATE/$SID.runtime"
  printf '%s\n' "$SB" > "$STATE/$SID.workdir"
  arm
}
typed() { cat "$SB/typed.log"; }
LOG() { cat "$AUTODEV_HOME/logs/$1.log" 2>/dev/null; }
flag() { # $1 text, $2 age ("6 hours ago")
  printf '%s\n' "$1" > "$STATE/$SID.unreachable"
  touch -d "$2" "$STATE/$SID.unreachable"
}
request() { # a compact request with its handoff, filed $1 ago
  handoff_pointer "$SID"
  : > "$STATE/$SID.compact-request"
  touch -d "$1" "$STATE/$SID.compact-request"
}
hook_input() { jq -nc --arg s "$SID" --arg c "$SB" '{session_id:$s,cwd:$c,transcript_path:""}'; }
stop_hook() { hook_input | AUTODEV_NO_WATCHERS=1 timeout 30 bash "$BIN/cc-stop-hook.sh" 2>/dev/null; }
gate_call() {
  jq -nc --arg s "$SID" --arg c "$SB" '{session_id:$s,cwd:$c,tool_name:"Bash",tool_input:{command:"make test"}}' |
    timeout 30 bash "$BIN/cc-handoff-gate.sh" 2>/dev/null
}
sweep() { timeout 60 bash "$BIN/auto-handoff-sweep.sh" </dev/null >"$SB/sweep.out" 2>&1; }
wait_log() { # $1 log, $2 text, $3 timeout s
  local end=$(( $(date +%s) + ${3:-20} ))
  until grep -qF "$2" "$AUTODEV_HOME/logs/$1.log" 2>/dev/null || [ "$(date +%s)" -ge "$end" ]; do sleep 0.2; done
}

echo "== the incident: a picker's flag at T, picker closed, compact request at T+6h =="
for shape in new old; do
  setup
  if [ "$shape" = new ]; then flag "$FLAG_NEW" '6 hours ago'; else flag "$FLAG_OLD" '6 hours ago'; fi
  request '1 minute ago'
  out=$(stop_hook)
  assert_eq "[$shape flag] the Stop orders no menu (no block at all)" "$out" ""
  assert_not_contains "[$shape flag] and never names AskUserQuestion" "$out" "AskUserQuestion"
  assert_no_file "[$shape flag] the Stop re-checked the clear screen and dropped the flag" "$STATE/$SID.unreachable"
  sandbox_rm
done

setup
flag "$FLAG_NEW" '6 hours ago'
request '1 minute ago'
out=$(gate_call)
assert_not_contains "the tool gate orders no menu either" "$out" "AskUserQuestion tool now"
assert_contains "the request is gated as on any reachable pane (the turn ends)" "$out" '"permissionDecision":"deny"'
sandbox_rm

setup
flag "$FLAG_NEW" '6 hours ago'
request '1 minute ago'
sweep
assert_contains "one sweep: the flag clears on evidence" "$(LOG auto-handoff)" "CLEAR unreachable: pane w1:p7 shows a clear, live composer"
wait_log auto-handoff "SENT: [/compact]"
assert_contains "one sweep: /compact is sent" "$(typed)" "RUN /compact"
assert_not_contains "and no menu was ever ordered" "$(LOG auto-handoff)" "DEFER awaiting-human"
assert_contains "the sweep prints its summary line" "$(cat "$SB/sweep.out")" "SWEEP-SUMMARY flags_set=0 flags_cleared=1 flags_present=0 pending_over_10m=0"
sandbox_rm

# A "not live" flag written by a process that could not reach the backend,
# while the pane is in fact live and ours (seen in the first-use run).
setup
flag 'registered pane w1:p7 is not live; no unique session match' '1 minute ago'
request '1 minute ago'
out=$(gate_call)
assert_not_contains "a false 'not live' flag on a live pane orders no menu" "$out" "AskUserQuestion tool now"
assert_no_file "and the re-check removes it" "$STATE/$SID.unreachable"
sandbox_rm
setup
printf 'w8:p8 someone-else\n' > "$SB/herdr/panes"     # our pane is really gone
flag 'registered pane w1:p7 is not live; no unique session match' '1 minute ago'
request '1 minute ago'
out=$(gate_call)
assert_contains "a pane really gone still gets the notice (nothing else can reach it)" "$out" "AskUserQuestion tool now"
sandbox_rm

echo "== a covered pane: no menu, one needs-owner line, one Slack line =="
setup
cp "$FX/limit-login-picker.txt" "$SB/herdr/screen.txt"
flag "$FLAG_NEW" '2 minutes ago'
request '15 minutes ago'
out=$(stop_hook)
assert_eq "covered: the Stop still orders no menu" "$out" ""
assert_file "covered: the flag stays (the screen is still covered)" "$STATE/$SID.unreachable"
since=$(date -d '12 minutes ago' +%s)
printf '%s %s login\n' "$since" "$(date -d '1 minute ago' +%s)" > "$STATE/$SID.covered"
sweep
assert_eq "covered over 10 min with a request pending: one needs-owner line" "$(grep -c "^$SID" "$STATE/needs-owner.list" 2>/dev/null)" "1"
assert_contains "the line names the tab and the key" "$(cat "$STATE/needs-owner.list" 2>/dev/null)" "fixture seat	since="
assert_eq "one Slack line" "$(wc -l < "$SB/slack.log" 2>/dev/null)" "1"
assert_contains "the Slack line says a request is pending, not past the line" "$(cat "$SB/slack.log" 2>/dev/null)" "has a handoff request pending (context 21%)"
printf '%s %s login\n' "$since" "$(date -d '1 minute ago' +%s)" > "$STATE/$SID.covered"   # the same episode
sweep
assert_eq "a second sweep: still one needs-owner line" "$(grep -c "^$SID" "$STATE/needs-owner.list" 2>/dev/null)" "1"
assert_eq "a second sweep: no second Slack line" "$(wc -l < "$SB/slack.log" 2>/dev/null)" "1"
assert_contains "the summary counts the live pending request" "$(cat "$SB/sweep.out")" "pending_over_10m=1"
assert_eq "nothing is typed into the covered pane" "$(typed)" ""
cp "$FX/presence-clear.txt" "$SB/herdr/screen.txt"
sweep
assert_eq "the cover closes: the needs-owner line goes" "$(grep -c "^$SID" "$STATE/needs-owner.list" 2>/dev/null)" "0"
sandbox_rm

echo "== a flag older than one sweep interval is never a reason to act on the human =="
setup
printf 'pct=40 ts=%s\n' "$(date +%s)" > "$STATE/$SID.ctx"
cp "$FX/limit-login-picker.txt" "$SB/herdr/screen.txt"
flag "$FLAG_NEW" '10 minutes ago'
out=$(stop_hook)
assert_eq "covered, past the line, flag 10 min old: no Stop block" "$out" ""
sandbox_rm
setup
printf 'pct=40 ts=%s\n' "$(date +%s)" > "$STATE/$SID.ctx"
cp "$FX/limit-login-picker.txt" "$SB/herdr/screen.txt"
flag "$FLAG_NEW" '30 seconds ago'
out=$(stop_hook)
assert_contains "covered, past the line, flag fresh: only the in-session /handoff fallback" "$out" "Run /handoff"
assert_not_contains "and never a menu" "$out" "AskUserQuestion"
sandbox_rm

echo "== limit-wait is checked against the newest capture at each sweep =="
setup
# The real false detection: written 11:12 for a reset at 07:30 the next day,
# over a pane whose banner was in the scrollback (the real case's times).
printf 'until=%s reset=%s human=7:30am_Asia/Jerusalem ts=%s\n' \
  "$(date -d 'tomorrow 07:34' +%s)" "$(date -d 'tomorrow 07:30' +%s)" "$(date -d '-2 minutes' +%s)" > "$STATE/$SID.limit-wait"
cp "$FX/limit-scrollback.txt" "$SB/herdr/screen.txt"
sweep
assert_no_file "no live banner on the pane: the sweep removes limit-wait" "$STATE/$SID.limit-wait"
assert_contains "and logs it" "$(LOG auto-handoff)" "DROP limit-wait: pane w1:p7 shows no live usage-limit banner"
sandbox_rm
setup
printf 'until=%s reset=%s human=x ts=%s\n' "$(date -d '+20 minutes' +%s)" "$(date -d '+16 minutes' +%s)" "$(date -d '-2 minutes' +%s)" > "$STATE/$SID.limit-wait"
sed -e "s/done 6:35 AM/done $(date -d '-1 minutes' +'%-I:%M %p')/" -e "s/7:30am/$(date -d '+16 minutes' +'%-I:%M%P')/g" \
  "$FX/limit-live.txt" > "$SB/herdr/screen.txt"
sweep
assert_file "a live banner: the wait stays" "$STATE/$SID.limit-wait"
sandbox_rm

echo "== dead sessions are reaped; the pending count means live sessions =="
setup
DEAD=dddddddd-dddd-dddd-dddd-dddddddddddd
printf 'registered pane w9:p9 is not live; no unique session match\n' > "$STATE/$DEAD.unreachable"
printf 'w9:p9\n' > "$STATE/$DEAD.herdr-pane"
: > "$STATE/$DEAD.compact-request"; printf 'pct=50 ts=1\n' > "$STATE/$DEAD.ctx"
touch -d '25 hours ago' "$STATE/$DEAD.unreachable" "$STATE/$DEAD.herdr-pane" "$STATE/$DEAD.compact-request" "$STATE/$DEAD.ctx"
YOUNG=eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee
printf 'no pane registered\n' > "$STATE/$YOUNG.unreachable"; touch -d '2 hours ago' "$STATE/$YOUNG.unreachable"
: > "$STATE/$YOUNG.compact-request"; touch -d '2 hours ago' "$STATE/$YOUNG.compact-request"
OLDLIVE=ffffffff-ffff-ffff-ffff-ffffffffffff
printf 'w2:p2 %s\n' "$OLDLIVE" >> "$SB/herdr/panes"
printf 'registered pane w2:p2 is not live; no unique session match\n' > "$STATE/$OLDLIVE.unreachable"
touch -d '30 hours ago' "$STATE/$OLDLIVE.unreachable"
sweep
day=$(date +%Y-%m-%d)
assert_no_file "dead 25 h, no pane: its flag is moved" "$STATE/$DEAD.unreachable"
assert_no_file "dead 25 h, no pane: its request is moved" "$STATE/$DEAD.compact-request"
assert_file "into the archive" "$AUTODEV_HOME/state-archive/$day/$DEAD.unreachable"
assert_no_file "its pane binding goes too, so no later sweep re-flags it" "$STATE/$DEAD.herdr-pane"
assert_eq "one log line for it" "$(grep -c "\[$DEAD\] REAP dead session" "$AUTODEV_HOME/logs/auto-handoff.log")" "1"
assert_file "no pane, but written 2 h ago: kept" "$STATE/$YOUNG.unreachable"
assert_file "old, but its session is in a live pane: kept" "$STATE/$OLDLIVE.unreachable"
assert_contains "the young dead request counts nowhere as live pending" "$(cat "$SB/sweep.out")" "pending_over_10m=0"
sweep
assert_eq "a second sweep reaps nothing more" "$(grep -c "REAP dead session" "$AUTODEV_HOME/logs/auto-handoff.log")" "1"
assert_contains "and nothing re-flags the reaped session" "$(cat "$SB/sweep.out")" "flags_set=0 flags_cleared=0 flags_present=2"
assert_no_file "the reaped session has no flag again" "$STATE/$DEAD.unreachable"
rm -f "$STATE/$YOUNG.unreachable"
printf 'no pane registered\n' > "$STATE/$OLDLIVE.unreachable.tmp" && rm -f "$STATE/$OLDLIVE.unreachable"
printf 'x\n' > "$STATE/$SID.unreachable"
sweep
assert_contains "set and cleared are counted between runs" "$(cat "$SB/sweep.out")" "SWEEP-SUMMARY flags_set=1 flags_cleared=2 flags_present=1"
sandbox_rm

# --- review round 2 --------------------------------------------------------------
# The gate held a request under a standing presence flag until a compaction that
# might never come. It is bounded now: (a) the compaction, (b) the flag clearing,
# (c) AUTODEV_GATE_BOUND (600 s) from the stamp the gate writes itself.
req_key() { date -r "$STATE/$SID.compact-request" +%s%N; }
stamp_set() { printf '%s\n' "$1" > "$STATE/$SID.gate-bound.$(req_key)"; }   # $1 = start epoch
releases() { cat "$AUTODEV_HOME/logs/auto-handoff.log" 2>/dev/null | grep -c "GATE-RELEASE"; }
slack_lines() { if [ -f "$SB/slack.log" ]; then wc -l < "$SB/slack.log"; else echo 0; fi; }
covered_setup() { # a picker over the composer, its flag, a request, the watcher's episode
  setup
  cp "$FX/limit-login-picker.txt" "$SB/herdr/screen.txt"
  flag "$FLAG_NEW" '3 minutes ago'
  request '15 minutes ago'
  printf '%s %s login\n' "$(date -d '12 minutes ago' +%s)" "$(date -d '1 minute ago' +%s)" > "$STATE/$SID.covered"
}
DENY='"permissionDecision":"deny"'

echo "== the gate's bound: (c) 10 minutes from the gate's own stamp =="
covered_setup
out=$(gate_call)
assert_contains "covered, first call: the request is held" "$out" "$DENY"
stamp="$STATE/$SID.gate-bound.$(req_key)"
assert_file "the gate writes its own stamp" "$stamp"
st=$(head -n1 "$stamp"); [ $(( $(date +%s) - ${st:-0} )) -le 5 ]
assert_eq "the stamp holds the epoch of the first held call" "$?" 0
touch -d '20 minutes ago' "$stamp"
out=$(gate_call)
assert_contains "before 10 min the gate still holds, whatever the stamp's mtime says" "$out" "$DENY"
assert_eq "no release yet" "$(releases)" "0"
assert_eq "no Slack line yet" "$(slack_lines)" "0"
stamp_set "$(date -d '601 seconds ago' +%s)"
out=$(gate_call)
assert_eq "(c) at 10 min: tools pass" "$out" ""
assert_eq "(c) one GATE-RELEASE line in the handoff log" "$(releases)" "1"
assert_contains "(c) the line says what held and why it ends" "$(LOG auto-handoff)" "(bound 600s) under a covered screen (screen presence unproved) and no /compact came; tools pass for this request"
assert_eq "(c) one Slack line" "$(slack_lines)" "1"
assert_contains "(c) it is the sweep's covered-pane line" "$(cat "$SB/slack.log")" "seat 'fixture seat' has a handoff request pending (context 21%) and its pane has been covered for 12 min (reason: login screen). The handoff stays queued; a person must clear the screen or type /compact in that pane."
out=$(gate_call)
assert_eq "a second call after (c): tools still pass" "$out" ""
assert_eq "a second call after (c): no second Slack line" "$(slack_lines)" "1"
assert_eq "a second call after (c): no second log line" "$(releases)" "1"
sweep
assert_eq "the sweep's alert for the same episode sends no second Slack line" "$(slack_lines)" "1"
assert_eq "it sends only its lane line" "$(wc -l < "$SB/lane.log" 2>/dev/null)" "1"
sandbox_rm

covered_setup
rm -f "$STATE/$SID.covered"    # an episode the watcher never recorded
out=$(AUTODEV_GATE_BOUND=1 gate_call); sleep 2
out=$(AUTODEV_GATE_BOUND=1 gate_call)
assert_eq "the bound is read from AUTODEV_GATE_BOUND" "$out" ""
assert_eq "no episode on record: the gate starts one and still sends one line" "$(slack_lines)" "1"
assert_file "and records it, so the sweep cannot send a second" "$STATE/$SID.covered-alert"
sandbox_rm

covered_setup
stamp_set "$(date -d '601 seconds ago' +%s)"
since=$(cut -d' ' -f1 "$STATE/$SID.covered")
# The sweep holds the page lock and sends this episode's line while the gate waits.
( flock 9; sleep 2; printf 'episode=%s\nslack=sent %s\nlane=\n' "$since" "$(date +%s)" > "$STATE/$SID.covered-alert" ) 9>"$STATE/$SID.page.lock" &
lockp=$!; sleep 0.5
out=$(gate_call); wait "$lockp"
assert_eq "(c) while the sweep holds the page lock: tools pass" "$out" ""
assert_eq "(c) re-read under the lock: the sweep's line counts, no second Slack line" "$(slack_lines)" "0"
sandbox_rm

echo "== (a) and (b) end the bound early =="
covered_setup
stamp_set "$(date -d '700 seconds ago' +%s)"
date +%s > "$STATE/$SID.compacted"      # (a) newer than the request
out=$(gate_call)
assert_eq "(a) compacted: tools pass" "$out" ""
assert_eq "(a) no GATE-RELEASE" "$(releases)" "0"
assert_eq "(a) no Slack line" "$(slack_lines)" "0"
assert_eq "(a) the satisfied request's stamp is removed" "$(ls "$STATE" | grep -c 'gate-bound')" "0"
sandbox_rm

covered_setup
stamp_set "$(date -d '700 seconds ago' +%s)"
cp "$FX/presence-clear.txt" "$SB/herdr/screen.txt"   # (b) the picker closed
out=$(gate_call)
assert_no_file "(b) the re-check clears the flag" "$STATE/$SID.unreachable"
assert_contains "(b) the request is held as on any reachable pane (the turn ends, the watcher serves it)" "$out" "$DENY"
assert_eq "(b) no GATE-RELEASE" "$(releases)" "0"
assert_eq "(b) no Slack line" "$(slack_lines)" "0"
assert_eq "(b) the episode's stamp is removed" "$(ls "$STATE" | grep -c 'gate-bound')" "0"
cp "$FX/limit-login-picker.txt" "$SB/herdr/screen.txt"; flag "$FLAG_NEW" '1 minute ago'
out=$(gate_call)
assert_contains "(b) a later flag starts a new 10 minutes (held, not released)" "$out" "$DENY"
assert_eq "(b) still no release" "$(releases)" "0"
sandbox_rm

echo "== the bound's stamp: input classes =="
for kind in dangling loop dirlink; do
  covered_setup
  s="$STATE/$SID.gate-bound.$(req_key)"
  case "$kind" in
    dangling) ln -s "$SB/no-such-file" "$s" ;;
    loop) ln -s "$s" "$s" ;;
    dirlink) mkdir -p "$SB/somedir"; ln -s "$SB/somedir" "$s" ;;
  esac
  out=$(jq -nc --arg s "$SID" '{session_id:$s,tool_name:"Bash",tool_input:{command:"make test"}}' |
        bash "$BIN/cc-handoff-gate.sh" 2>"$SB/err")
  assert_contains "[$kind stamp] still held" "$out" "$DENY"
  assert_eq "[$kind stamp] replaced by a stamp of the gate's own" "$( [ -f "$s" ] && [ ! -L "$s" ] && head -n1 "$s" | grep -cE '^[0-9]+$')" "1"
  assert_eq "[$kind stamp] no error output" "$(cat "$SB/err")" ""
  sandbox_rm
done
covered_setup
mkdir -p "$STATE/$SID.gate-bound.$(req_key)"   # cannot be replaced: fail open
out=$(gate_call)
assert_eq "[a real directory at the stamp] the bound cannot be measured: fails open" "$out" ""
assert_eq "[a real directory at the stamp] and claims no release" "$(releases)" "0"
sandbox_rm
covered_setup
mkdir -p "$SB/cwd"; ln -s "$AUTODEV_HOME" "$SB/cwd/~"
out=$(cd "$SB/cwd" && HOME="$SB/fakehome" AUTODEV_HOME='~' gate_call)
assert_contains "[AUTODEV_HOME starting with an unexpanded ~] used as given: held" "$out" "$DENY"
assert_eq "[unexpanded ~] the stamp lands in that directory" "$(ls "$STATE" | grep -c 'gate-bound')" "1"
sandbox_rm
covered_setup
out=$(cd "$SB" && AUTODEV_HOME=agents gate_call)
assert_contains "[a relative AUTODEV_HOME] held" "$out" "$DENY"
assert_eq "[relative] the stamp lands in that directory" "$(ls "$STATE" | grep -c 'gate-bound')" "1"
sandbox_rm
covered_setup
odd="$SB/it's a \"home\""; cp -a "$AUTODEV_HOME" "$odd"
out=$(AUTODEV_HOME="$odd" gate_call)
assert_contains "[spaces and quotes in AUTODEV_HOME] held" "$out" "$DENY"
st=$(ls "$odd/state" | grep 'gate-bound'); printf '%s\n' "$(( $(date +%s) - 601 ))" > "$odd/state/$st"
out=$(AUTODEV_HOME="$odd" gate_call)
assert_eq "[spaces and quotes] released at 10 min" "$out" ""
assert_eq "[spaces and quotes] one log line there" "$(grep -c GATE-RELEASE "$odd/logs/auto-handoff.log")" "1"
sandbox_rm
covered_setup
chmod 000 "$AUTODEV_HOME"
out=$(jq -nc --arg s "$SID" '{session_id:$s,tool_name:"Bash",tool_input:{command:"make test"}}' |
      bash "$BIN/cc-handoff-gate.sh" 2>"$SB/err"); rc=$?
chmod 755 "$AUTODEV_HOME"
assert_eq "[a parent the gate cannot read] exit 0, tools pass" "$rc:$out" "0:"
assert_eq "[a parent the gate cannot read] no error output" "$(cat "$SB/err")" ""
sandbox_rm
covered_setup
date +%s > "$STATE/$SID.compacted"
out=$(jq -nc --arg s "$SID" '{session_id:$s,tool_name:"Bash",tool_input:{command:"make test"}}' |
      bash "$BIN/cc-handoff-gate.sh" 2>"$SB/err"); rc=$?
assert_eq "[no stamp: the cleanup glob matches nothing] exit 0, no error" "$rc:$(cat "$SB/err")" "0:"
assert_eq "[no stamp] and creates no file named by the pattern" "$(ls "$STATE" | grep -c '\*')" "0"
sandbox_rm

echo "== review 1: never drop a limit-wait a live resume cycle owns, nor on no-composer =="
lw_write() { printf 'until=%s reset=%s human=x ts=%s\n' "$(date -d '+20 minutes' +%s)" "$(date -d '+16 minutes' +%s)" "$(date -d '-2 minutes' +%s)" > "$STATE/$SID.limit-wait"; }
setup
lw_write
cp "$FX/limit-login-picker.txt" "$SB/herdr/screen.txt"   # the watcher's own picker: no composer
sweep
assert_file "a picker over the composer (no-composer) is no evidence: the wait stays" "$STATE/$SID.limit-wait"
assert_not_contains "and nothing is logged as dropped" "$(LOG auto-handoff)" "DROP limit-wait"
sandbox_rm
setup
lw_write
cp "$FX/presence-clear.txt" "$SB/herdr/screen.txt"
sleep 300 & holder=$!
( . "$BIN/limit-lib.sh"; autodev_resume_lock_take "$STATE" "$SID" "$holder" )
sweep
assert_file "a live resume cycle holds the session's lock: its wait stays" "$STATE/$SID.limit-wait"
assert_eq "and the sweep leaves its lock alone" "$(cat "$STATE/$SID.resume.lock/pid" 2>/dev/null)" "$holder"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
sweep
assert_no_file "the cycle gone and the composer clear with no banner: dropped" "$STATE/$SID.limit-wait"
sandbox_rm

echo "== review 2: a tmux-only install reaps a dead tmux session =="
setup
mkdir -p "$SB/tmuxbin" "$SB/home"
printf '#!/usr/bin/env bash\ncase "$1" in list-panes) printf "%%%%1\\n" ;; *) exit 1 ;; esac\n' > "$SB/tmuxbin/tmux"
chmod +x "$SB/tmuxbin/tmux"
rm -f "$STATE/$SID".*   # no herdr session here
TDEAD=abababab-abab-abab-abab-abababababab TLIVE=cdcdcdcd-cdcd-cdcd-cdcd-cdcdcdcdcdcd
printf '%%9\n' > "$STATE/$TDEAD.tmux-pane"; : > "$STATE/$TDEAD.compact-request"
printf 'no pane registered\n' > "$STATE/$TDEAD.unreachable"
printf '%%1\n' > "$STATE/$TLIVE.tmux-pane"; : > "$STATE/$TLIVE.compact-request"
handoff_pointer "$TDEAD"; handoff_pointer "$TLIVE"   # valid requests: only the reap may move them
touch -d '25 hours ago' "$STATE/$TDEAD".* "$STATE/$TLIVE".*
( unset MUX_HERDR; PATH="$SB/tmuxbin:/usr/bin:/bin" HOME="$SB/home" sweep )
assert_no_file "a dead tmux session's request is reaped with no herdr listing" "$STATE/$TDEAD.compact-request"
assert_file "into the archive" "$AUTODEV_HOME/state-archive/$(date +%Y-%m-%d)/$TDEAD.compact-request"
assert_eq "one log line for it" "$(grep -c "\[$TDEAD\] REAP dead session" "$AUTODEV_HOME/logs/auto-handoff.log")" "1"
assert_file "a live tmux session is kept" "$STATE/$TLIVE.compact-request"
assert_eq "the pending count is known (no '?') and counts the live one" "$(grep -o 'pending_over_10m=[0-9?]*' "$SB/sweep.out")" "pending_over_10m=1"
sandbox_rm

echo "== review 3: the sweep's own writes do not keep a dead session young =="
setup
D2=d2d2d2d2-d2d2-d2d2-d2d2-d2d2d2d2d2d2
printf 'registered pane w9:p9 is not live; no unique session match\n' > "$STATE/$D2.unreachable"
printf 'w9:p9\n' > "$STATE/$D2.herdr-pane"; : > "$STATE/$D2.compact-request"; printf 'pct=50 ts=1\n' > "$STATE/$D2.ctx"
handoff_pointer "$D2"
touch -d '25 hours ago' "$STATE/$D2".*
printf '%s %s owner\n' "$(date -d '25 hours ago' +%s)" "$(date +%s)" > "$STATE/$D2.covered"   # rewritten each pass
printf 'episode=1\nslack=\nlane=\n' > "$STATE/$D2.covered-alert"
printf '%s %s\n' "$(date +%s)" "$(date +%s)" > "$STATE/$D2.busy-since"
ln -s "$SB/no-such-file" "$STATE/$D2.heartbeat"      # a dangling link among the age inputs
ln -s "$STATE/$D2.idle" "$STATE/$D2.idle"            # and a link loop
sweep
assert_no_file "a fresh sweep-written .covered does not keep a dead session alive" "$STATE/$D2.compact-request"
assert_file "it is archived" "$AUTODEV_HOME/state-archive/$(date +%Y-%m-%d)/$D2.covered"
assert_file "its request with it" "$AUTODEV_HOME/state-archive/$(date +%Y-%m-%d)/$D2.compact-request"
assert_not_contains "a dangling link or a loop among the age inputs prints no error" "$(cat "$SB/sweep.out")" "$D2"
sandbox_rm

echo "== review 4: a landed send ends the episode and its needs-owner line =="
setup
request '1 minute ago'
printf '%s %s menu\n' "$(date -d '2 minutes ago' +%s)" "$(date -d '1 minute ago' +%s)" > "$STATE/$SID.covered"
( . "$BIN/limit-lib.sh"; autodev_needs_owner_set "$STATE" "$SID" "fixture seat" Escape "a menu" )
assert_eq "a menu-only refusal listed the pane (no presence flag)" "$(grep -c "^$SID" "$STATE/needs-owner.list")" "1"
sweep
wait_log auto-handoff "SENT: [/compact]"
assert_contains "the send lands" "$(typed)" "RUN /compact"
assert_no_file "the episode is over" "$STATE/$SID.covered"
assert_eq "and its needs-owner line goes with it" "$(grep -c "^$SID" "$STATE/needs-owner.list" 2>/dev/null)" "0"
sandbox_rm

finish
