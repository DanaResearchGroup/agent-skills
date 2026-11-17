#!/usr/bin/env bash
# A seat past its handoff line whose pane is covered (an open menu, a login
# screen, any screen without its composer) must keep its handoff queued, have
# nothing typed into it, compact on the first tick after the screen clears, and
# be made loud once per episode: one Slack line and one session-lane line after
# 10 minutes covered, none before. (I-429)
#
# Real sweep, real watcher, real mux library; a fake herdr serves fixture
# screens, and fake Slack and lane commands record what would be sent. Nothing
# reaches a real pane, Slack or the lane.
. "$(dirname "$0")/lib.sh"

SID=sess-a               # the screen fixtures carry ⟨cc:sess-a⟩
PANE=w1:pX
ORIG_PATH=$PATH
FIX="$SKILL_DIR/test/fixtures/panes"
export AUTODEV_SETTLE=0 AUTODEV_POLL=0.01 AUTODEV_PRECHECK=0
export AUTODEV_WAIT_IDLE=3 AUTODEV_WAIT_COMPACT=3 AUTODEV_NO_WATCHERS=1

setup() {
  sandbox_new
  mkdir -p "$SB/fakebin"
  export PATH="$SB/fakebin:$ORIG_PATH" MUX_HERDR="$SB/fakebin/herdr" TEST_SID="$SID"
  export CC_SLACK_CHANNEL=CTEST0000
  : > "$SB/typed"; : > "$SB/slack.log"; : > "$SB/lane.log"
  cat > "$MUX_HERDR" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SB/herdr-calls"
case "$1 $2" in
  'pane list')
    # More seats, sess-b on w1:pY and sess-c on w1:pZ, exist only when a test
    # adds them (seat_b, seat_c). $SB/pane-gone removes sess-a's pane;
    # $SB/pane-owner hands it to another session.
    jq -nc --arg s "$(cat "$SB/status")" --arg b "$([ -f "$SB/seat-b" ] && echo 1)" \
      --arg c "$([ -f "$SB/seat-c" ] && echo 1)" --arg g "$([ -f "$SB/pane-gone" ] && echo 1)" \
      --arg o "$(cat "$SB/pane-owner" 2>/dev/null || echo sess-a)" \
      '{result:{panes:((if $g == "1" then [] else [{pane_id:"w1:pX",agent_session:{value:$o},agent_status:$s}] end)
        + (if $b == "1" then [{pane_id:"w1:pY",agent_session:{value:"sess-b"},agent_status:"blocked"}] else [] end)
        + (if $c == "1" then [{pane_id:"w1:pZ",agent_session:{value:"sess-c"},agent_status:"blocked"}] else [] end))}}' ;;
  'pane get')
    case "$3" in
      w1:pX) [ -f "$SB/pane-gone" ] && exit 1
             jq -nc --arg s "$(cat "$SB/status")" --arg o "$(cat "$SB/pane-owner" 2>/dev/null || echo sess-a)" \
               '{result:{pane:{pane_id:"w1:pX",agent_session:{value:$o},agent_status:$s,scroll:{offset_from_bottom:0}}}}' ;;
      w1:pY) [ -f "$SB/seat-b" ] || exit 1
             jq -nc '{result:{pane:{pane_id:"w1:pY",agent_session:{value:"sess-b"},agent_status:"blocked",scroll:{offset_from_bottom:0}}}}' ;;
      w1:pZ) [ -f "$SB/seat-c" ] || exit 1
             jq -nc '{result:{pane:{pane_id:"w1:pZ",agent_session:{value:"sess-c"},agent_status:"blocked",scroll:{offset_from_bottom:0}}}}' ;;
      *) exit 1 ;;
    esac ;;
  'pane read') case "$3" in w1:pY) cat "$SB/screen-b" ;; w1:pZ) cat "$SB/screen-c" ;; *) cat "$SB/screen" ;; esac ;;
  'tab get') lf="$SB/tab-label"; [ -f "$SB/tab-label.$3" ] && lf="$SB/tab-label.$3"
             printf '{"result":{"tab":{"tab_id":"%s","label":"%s"}}}\n' "$3" "$(cat "$lf")" ;;
  'pane run')
    printf '%s %s\n' "$3" "$4" >> "$SB/typed"
    case "$4" in
      /handoff)
        printf '%s\n' "$(( $(date +%s) + 2 ))" > "$STATE/$TEST_SID.idle" ;;
      /compact) printf '%s\n' "$(( $(date +%s) + 2 ))" > "$STATE/$TEST_SID.compacted" ;;
    esac ;;
  'pane send-keys'|'pane send-text') printf '%s\n' "$*" >> "$SB/typed" ;;
  *) exit 1 ;;
esac
FAKE
  # Fake Slack helper: one line per call; $SB/slack-fail makes it fail like the
  # real helper does. It records whether a channel reached it, never a token.
  cat > "$SB/fakebin/slack" <<'FAKE'
#!/usr/bin/env bash
printf 'channel=%s text=%s\n' "${CC_SLACK_CHANNEL:-<unset>}" "$1" >> "$SB/slack.log"
# $SB/slack-slow (seconds): a slow send that keeps the sweep's log as it stood
# when the send began, and counts the sends in flight at that moment.
if [ -f "$SB/slack-slow" ]; then
  cp "$AUTODEV_HOME/logs/auto-handoff.log" "$SB/log-at-slack.$$" 2>/dev/null
  mkdir -p "$SB/inflight"; : > "$SB/inflight/$$"
  ls "$SB/inflight" | wc -l >> "$SB/concurrency"
  sleep "$(cat "$SB/slack-slow")"
  rm -f "$SB/inflight/$$"
fi
[ -f "$SB/slack-fail" ] && { echo "ERR channel_not_found"; exit 1; }
printf 'OK\n1700000000.000100\n'
FAKE
  # Fake session-send: QUEUED (75) is the lane's normal answer from a timer.
  cat > "$SB/fakebin/session-send" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SB/lane.log"
[ -f "$SB/lane-fail" ] && { echo "REFUSED reason=unknown-persona"; exit 3; }
echo "QUEUED m-000000000000 reason=enqueued"; exit 75
FAKE
  chmod +x "$MUX_HERDR" "$SB/fakebin/slack" "$SB/fakebin/session-send"
  export AUTODEV_SLACK_CMD="$SB/fakebin/slack" AUTODEV_LANE_CMD="$SB/fakebin/session-send"
  session_new "$SID" 40 "$PANE"
  printf 'claude\n' > "$STATE/$SID.runtime"
  printf 't7\n' > "$STATE/$SID.herdr-tab"
  printf 'Engineer ⌛120s' > "$SB/tab-label"
  handoff_pointer "$SID"
  : > "$STATE/$SID.compact-request"
  arm
  covered menu
}

covered() { # the pane's cover: menu | login | other | none
  case "$1" in
    menu)  cp "$FIX/session-a-menu-notice.txt" "$SB/screen"; echo blocked > "$SB/status" ;;
    login) cp "$FIX/login-screen.txt" "$SB/screen"; echo idle > "$SB/status" ;;
    other) printf ' Resuming conversation…\n\n   ⎿ loading 2 of 7\n' > "$SB/screen"; echo idle > "$SB/status" ;;
    none)  cp "$FIX/session-a-status.txt" "$SB/screen"; echo idle > "$SB/status" ;;
  esac
}

# One timer tick: the real sweep, then every watcher it launched runs to its end.
tick() {
  bash "$BIN/auto-handoff-sweep.sh" >/dev/null 2>&1
  local end=$(( $(date +%s) + 30 ))
  while pgrep -f "$BIN/auto-handoff-watch.sh" >/dev/null 2>&1 && [ "$(date +%s)" -lt "$end" ]; do
    sleep 0.1
  done
}
# Move the episode's start back to <seconds> ago, keeping its latest refusal.
age_episode() { # $1 seconds, $2 sid (default $SID)
  local _since last kind f="$STATE/${2:-$SID}.covered"
  read -r _since last kind < "$f"
  AGED=$(( $(date +%s) - $1 ))
  printf '%s %s %s\n' "$AGED" "$last" "$kind" > "$f"
}
# A second seat past its line, sess-b on w1:pY, covered by a menu.
seat_b() {
  : > "$SB/seat-b"
  session_new sess-b 40 w1:pY
  printf 'claude\n' > "$STATE/sess-b.runtime"
  printf 't8\n' > "$STATE/sess-b.herdr-tab"
  handoff_pointer sess-b
  : > "$STATE/sess-b.compact-request"
  cp "$FIX/session-a-menu-notice.txt" "$SB/screen-b"   # sess-a's tag: no presence for sess-b
}
# A third seat past its line, sess-c on w1:pZ, covered by a menu.
seat_c() {
  : > "$SB/seat-c"
  session_new sess-c 40 w1:pZ
  printf 'claude\n' > "$STATE/sess-c.runtime"
  printf 't9\n' > "$STATE/sess-c.herdr-tab"
  handoff_pointer sess-c
  : > "$STATE/sess-c.compact-request"
  cp "$FIX/session-a-menu-notice.txt" "$SB/screen-c"
}
# Make sess-a a Persona seat: its working folder under the Persona root.
persona() {
  export AUTODEV_PERSONA_ROOT="$SB/Persona"
  mkdir -p "$AUTODEV_PERSONA_ROOT/method/PI"
  printf '%s\n' "$AUTODEV_PERSONA_ROOT/method" > "$STATE/$SID.workdir"
}
# sess-a's pane becomes unreachable: owner (another live session holds it) or
# nopane (gone from herdr, with no other pane carrying the session).
lose_pane() { # $1 = owner | nopane
  case "$1" in
    owner)  echo sess-z > "$SB/pane-owner"
            printf 'pct=10 ts=%s\n' "$(date +%s)" > "$STATE/sess-z.ctx"
            touch -d '+1 hour' "$STATE/sess-z.ctx" ;;   # a fresher owner proves the pane recycled
    nopane) : > "$SB/pane-gone" ;;
  esac
}
# The handoff gate, run as sess-a's own PreToolUse hook would run it.
gate_reason() {
  jq -nc --arg s "$SID" '{session_id:$s,tool_name:"Bash",tool_input:{command:"a"},hook_event_name:"PreToolUse"}' |
    bash "$BIN/cc-handoff-gate.sh" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null
}
# A Persona seat's pane is lost; the seat, alive, runs its gate once (spared
# the menu); the next tick records the episode.
start_lost_episode() { # $1 = owner | nopane
  lose_pane "$1"
  tick
  gate_reason >/dev/null
  tick
}
since() { cut -d' ' -f1 "$STATE/$SID.covered" 2>/dev/null; }
lines() { awk 'NF' "$1" | wc -l | tr -d ' '; }
log_text() { cat "$AUTODEV_HOME/logs/auto-handoff.log" 2>/dev/null; }

echo '== a covered seat keeps its marker, gets nothing typed, and is loud once =='
setup
tick
assert_file 'first covered tick keeps the compact-request' "$STATE/$SID.compact-request"
assert_file 'first covered tick starts an episode' "$STATE/$SID.covered"
assert_contains 'the episode records the cover as a menu' "$(cat "$STATE/$SID.covered")" ' menu'
first=$(since)
assert_eq 'nothing typed under the menu' "$(cat "$SB/typed")" ''
age_episode 540
tick
assert_eq 'at 9 min covered: no Slack line' "$(lines "$SB/slack.log")" 0
assert_eq 'at 9 min covered: no lane line' "$(lines "$SB/lane.log")" 0
assert_file 'second covered tick still keeps the marker' "$STATE/$SID.compact-request"
assert_eq 'a repeat refusal keeps the episode start' "$(since)" "$AGED"
age_episode 660
tick
assert_eq 'past 10 min covered: exactly one Slack line' "$(lines "$SB/slack.log")" 1
assert_eq 'past 10 min covered: exactly one lane line' "$(lines "$SB/lane.log")" 1
slack=$(cat "$SB/slack.log"); lane=$(cat "$SB/lane.log")
assert_contains 'Slack line names the seat by its tab label, badge stripped' "$slack" "seat 'Engineer' is past its handoff line"
assert_contains 'Slack line gives the context reading' "$slack" '(context 40%)'
assert_contains 'Slack line gives the reason' "$slack" '(reason: menu)'
assert_contains 'Slack line says how long' "$slack" 'covered for 11 min'
assert_not_contains 'Slack line never names a pane code' "$slack" "$PANE"
assert_contains 'lane line goes to the Method Persona' "$lane" '--to persona:method --from autodev-sweep'
assert_contains 'lane line names the seat and reason' "$lane" "seat 'Engineer' is past its handoff line (context 40%) and its pane has been covered for 11 min (reason: menu)"
assert_not_contains 'lane line never names a pane code' "$lane" "$PANE"
rec=$(cat "$STATE/$SID.covered-alert")
assert_contains 'state records the episode' "$rec" "episode=$(since)"
assert_contains 'state records the Slack send' "$rec" 'slack=sent '
assert_contains 'state records the lane send' "$rec" 'lane=sent '
: > "$SB/herdr-calls"
tick; tick
assert_eq 'later ticks (fresh sweep processes) send no second Slack line' "$(lines "$SB/slack.log")" 1
assert_not_contains 'a fully sent episode does not read the tab label again' "$(cat "$SB/herdr-calls")" 'tab get'
assert_eq 'later ticks send no second lane line' "$(lines "$SB/lane.log")" 1
assert_eq 'nothing typed in five covered ticks' "$(cat "$SB/typed")" ''
assert_file 'marker still queued after five covered ticks' "$STATE/$SID.compact-request"

echo '== the first tick after the menu clears compacts it =='
covered none
tick
assert_contains 'cleared menu: /compact typed on the first tick' "$(cat "$SB/typed")" "$PANE /compact"
assert_contains 'cleared menu: the cycle completes' "$(log_text)" 'CYCLE COMPLETE (compact-requested'
assert_no_file 'a landed send ends the episode' "$STATE/$SID.covered"
assert_eq 'the clear sends no alert' "$(lines "$SB/slack.log")" 1

echo '== a second episode sends again =='
printf '%s\n' "$(( $(date +%s) - 3600 ))" > "$STATE/$SID.compacted"
rm -f "$STATE/$SID.cooldown"
printf 'pct=41 ts=%s\n' "$(date +%s)" > "$STATE/$SID.ctx"
: > "$SB/typed"
covered menu
tick
assert_file 'second episode recorded' "$STATE/$SID.covered"
if [ "$(since)" != "$first" ]; then _pass 'second episode has its own start'
else _fail 'second episode has its own start' "since=$(since)"; fi
age_episode 700
tick
assert_eq 'second episode: a second Slack line' "$(lines "$SB/slack.log")" 2
assert_eq 'second episode: a second lane line' "$(lines "$SB/lane.log")" 2
assert_contains 'second episode reads the new context' "$(tail -n1 "$SB/slack.log")" '(context 41%)'
id1=$(sed -n 1p "$SB/lane.log" | grep -o -- '--id m-[0-9a-f]*'); id2=$(sed -n 2p "$SB/lane.log" | grep -o -- '--id m-[0-9a-f]*')
if [ -n "$id1" ] && [ "$id1" != "$id2" ]; then _pass 'each episode has its own lane message id'
else _fail 'each episode has its own lane message id' "$id1 / $id2"; fi
assert_eq 'threshold-only seat: nothing typed under the menu' "$(cat "$SB/typed")" ''
assert_no_file 'no real Slack or lane was ever called' "$SB/real-send-attempt"
sandbox_rm

echo '== reasons: login screen and other =='
for kind in login other; do
  setup
  covered "$kind"
  tick
  assert_eq "$kind: nothing typed" "$(cat "$SB/typed")" ''
  assert_file "$kind: marker kept" "$STATE/$SID.compact-request"
  age_episode 660
  tick
  case "$kind" in login) want='reason: login screen' ;; *) want='reason: other' ;; esac
  assert_contains "$kind: Slack line gives the reason" "$(cat "$SB/slack.log")" "($want)"
  assert_eq "$kind: one lane line" "$(lines "$SB/lane.log")" 1
  assert_eq "$kind: still nothing typed" "$(cat "$SB/typed")" ''
  sandbox_rm
done

echo '== failed sends are recorded and retried on the next tick, once each =='
setup
tick; age_episode 660
touch "$SB/slack-fail" "$SB/lane-fail"
tick
rec=$(cat "$STATE/$SID.covered-alert")
assert_contains 'state says Slack failed, with why' "$rec" 'ERR channel_not_found'
assert_contains 'state says the lane failed, with why' "$rec" 'REFUSED reason=unknown-persona'
assert_contains 'the log says it will retry' "$(log_text)" 'ALERT slack failed: ERR channel_not_found — retry next tick'
rm -f "$SB/slack-fail"
tick
assert_eq 'Slack retried once and sent' "$(lines "$SB/slack.log")" 2
assert_contains 'state now records the Slack send' "$(cat "$STATE/$SID.covered-alert")" 'slack=sent '
assert_eq 'the lane, still failing, is retried each tick' "$(lines "$SB/lane.log")" 2
rm -f "$SB/lane-fail"
tick; tick
assert_eq 'a sent Slack line is not resent while the lane retries' "$(lines "$SB/slack.log")" 2
assert_eq 'lane sent on its retry, then never again' "$(lines "$SB/lane.log")" 3
ids=$(grep -o -- '--id m-[0-9a-f]*' "$SB/lane.log" | sort -u | wc -l | tr -d ' ')
assert_eq 'every lane retry reuses the episode message id' "$ids" 1
sandbox_rm

echo '== a sent lane line is not resent while Slack keeps failing =='
setup
printf 'Res\xe2\x80\x8dearch\x01 ⌛30s' > "$SB/tab-label"   # a zero-width joiner and a control byte
tick; age_episode 660
touch "$SB/slack-fail"
tick; tick
assert_eq 'Slack retried on each tick while it fails' "$(lines "$SB/slack.log")" 2
assert_eq 'the lane line, sent on the first tick, is not resent' "$(lines "$SB/lane.log")" 1
assert_contains 'the label loses its format and control characters' "$(cat "$SB/lane.log")" "seat 'Research' is past"
sandbox_rm

echo '== a record that cannot be written sends nothing =='
setup
tick; age_episode 660
: > "$STATE/$SID.page.lock"                  # the lock opens; only new files fail
chmod 555 "$STATE"                          # no file can be created there
tick; tick
chmod 755 "$STATE"
assert_eq 'unrecordable alert: no Slack line' "$(lines "$SB/slack.log")" 0
assert_eq 'unrecordable alert: no lane line' "$(lines "$SB/lane.log")" 0
assert_contains 'unrecordable alert: the log says why' "$(log_text)" 'ALERT-SKIP cannot record'
sandbox_rm

echo '== no Slack channel: the real poster logs it, the sweep goes on, one notice a day =='
# The real poster, with no channel in its env or in a fixture settings file.
# Its API URL and proxies point at a closed loopback port, so even a poster that
# tried to post could reach nothing.
no_channel_tick() { # $1 day (YYYY-MM-DD); one tick of a new episode
  rm -f "$STATE/$SID.covered-alert"
  age_episode "$2"
  CC_SLACK_TODAY=$1 bash "$BIN/auto-handoff-sweep.sh" >/dev/null 2>"$SB/sweep.err"; SWEEP_RC=$?
  local end=$(( $(date +%s) + 30 ))
  while pgrep -f "$BIN/auto-handoff-watch.sh" >/dev/null 2>&1 && [ "$(date +%s)" -lt "$end" ]; do sleep 0.1; done
}
notices() { grep -c 'slack: no channel' "$AUTODEV_HOME/logs/auto-handoff.log" 2>/dev/null || true; }
setup
unset CC_SLACK_CHANNEL
mkdir -p "$SB/claude-config"
printf '{"env":{"OTHER":"x"}}\n' > "$SB/claude-config/settings.json"
export CLAUDE_CONFIG_DIR="$SB/claude-config" CC_SLACK_API_URL=http://127.0.0.1:9/api \
  http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9
export AUTODEV_SLACK_CMD="$SKILL_DIR/../bin/cc-slack-post.py"
tick; age_episode 660
no_channel_tick 2026-11-17 660
assert_eq 'no channel: the sweep exits 0' "$SWEEP_RC" 0
assert_eq 'no channel: the lane line still goes out' "$(lines "$SB/lane.log")" 1
assert_contains 'no channel: the episode records the line as unposted' "$(cat "$STATE/$SID.covered-alert")" 'slack=unposted '
assert_contains 'no channel: the sweep log says so' "$(log_text)" 'ALERT slack not posted: no channel'
assert_eq 'no channel: one unposted line, from the sweep' \
  "$(jq -r '[.reason, .caller] | join(" ")' "$STATE/slack-unposted.jsonl")" 'no-channel autodev-sweep'
assert_eq 'no channel: first run of the day prints the notice' "$(notices)" 1
assert_contains 'no channel: the notice reaches stderr too' "$(cat "$SB/sweep.err")" 'slack: no channel'
tick
assert_eq 'no channel: the settled episode is not retried' "$(awk 'NF' "$STATE/slack-unposted.jsonl" | wc -l | tr -d ' ')" 1
no_channel_tick 2026-11-17 700
assert_eq 'no channel: a second episode logs a second line' "$(awk 'NF' "$STATE/slack-unposted.jsonl" | wc -l | tr -d ' ')" 2
assert_eq 'no channel: the same day prints no second notice' "$(notices)" 1
assert_eq 'no channel: second run exits 0' "$SWEEP_RC" 0
no_channel_tick 2026-11-18 740
assert_eq 'no channel: the next day prints it again' "$(notices)" 2
assert_eq 'no channel: the lane got one line per episode' "$(lines "$SB/lane.log")" 3
unset CLAUDE_CONFIG_DIR CC_SLACK_API_URL http_proxy https_proxy HTTPS_PROXY
sandbox_rm

echo '== a notice that hangs does not hold back the lane line =='
# The send says "no channel" (78); the notice then hangs far past the limit.
setup
cat > "$SB/fakebin/stall-poster" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = --no-channel-notice ]; then echo $$ > "$SB/notice.pid"; exec sleep 120; fi
echo "ERR slack: no channel"; exit 78
FAKE
chmod +x "$SB/fakebin/stall-poster"
export AUTODEV_SLACK_CMD="$SB/fakebin/stall-poster" AUTODEV_ALERT_TIMEOUT=2
tick; age_episode 660
t0=$(date +%s); tick; took=$(( $(date +%s) - t0 ))
assert_eq 'stalled notice: the notice was asked for' "$([ -f "$SB/notice.pid" ] && echo yes)" yes
assert_eq 'stalled notice: the lane line still goes out' "$(lines "$SB/lane.log")" 1
assert_eq 'stalled notice: the tick ends near the limit, not the hang' "$([ "$took" -lt 20 ] && echo yes || echo "no ($took s)")" yes
kill "$(cat "$SB/notice.pid" 2>/dev/null)" 2>/dev/null || true
unset AUTODEV_ALERT_TIMEOUT
sandbox_rm

echo '== the poster, not the sweep, finds the channel in Claude Code settings =='
setup
unset CC_SLACK_CHANNEL
mkdir -p "$CLAUDE_CONFIG_DIR"
printf '{"env":{"CC_SLACK_CHANNEL":"CFROMSETTINGS"}}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
tick; age_episode 660; tick
assert_contains 'the sweep passes no channel of its own' "$(cat "$SB/slack.log")" 'channel=<unset> '
sandbox_rm

echo '== no alert unless the seat is still stuck =='
for case_ in below-line working stale compacted unlabelled; do
  setup
  tick; age_episode 660
  case "$case_" in
    below-line) printf 'pct=20 ts=%s\n' "$(date +%s)" > "$STATE/$SID.ctx"; rm -f "$STATE/$SID.compact-request" ;;
    working)    echo working > "$SB/status" ;;
    stale)      printf '%s %s menu\n' "$(( $(date +%s) - 3000 ))" "$(( $(date +%s) - 1000 ))" > "$STATE/$SID.covered" ;;
    compacted)  printf '%s\n' "$(( $(date +%s) - 60 ))" > "$STATE/$SID.compacted" ;;
    unlabelled) rm -f "$STATE/$SID.herdr-tab" ;;
  esac
  if [ "$case_" = unlabelled ]; then
    tick
    assert_contains 'no tab: the seat is named by session, never by pane' "$(cat "$SB/slack.log")" 'seat an unlabelled seat (session sess-a)'
    assert_not_contains 'no tab: still no pane code' "$(cat "$SB/slack.log")" "$PANE"
  else
    bash "$BIN/auto-handoff-sweep.sh" >/dev/null 2>&1
    pkill -f "$BIN/auto-handoff-watch.sh" 2>/dev/null
    assert_eq "$case_: no Slack line" "$(lines "$SB/slack.log")" 0
    assert_eq "$case_: no lane line" "$(lines "$SB/lane.log")" 0
  fi
  sandbox_rm
done

echo '== the watcher opens a new episode after a gap or a compaction =='
for case_ in gap compacted; do
  setup
  old=$(( $(date +%s) - 4000 ))
  if [ "$case_" = gap ]; then
    printf '%s %s menu\n' "$old" "$(( $(date +%s) - 1000 ))" > "$STATE/$SID.covered"
  else
    printf '%s %s menu\n' "$old" "$(( $(date +%s) - 60 ))" > "$STATE/$SID.covered"
    printf '%s\n' "$(( old + 100 ))" > "$STATE/$SID.compacted"
  fi
  bash "$BIN/auto-handoff-watch.sh" "$SID" >/dev/null 2>&1
  s=$(since)
  if [ -n "$s" ] && [ "$s" -gt "$old" ]; then _pass "$case_: a refusal after it starts a new episode"
  else _fail "$case_: a refusal after it starts a new episode" "since=$s old=$old"; fi
  sandbox_rm
done

echo '== the alert re-checks the episode after waiting for the page lock =='
setup
tick; age_episode 660
( exec 9>"$STATE/$SID.page.lock"; flock 9; : > "$SB/held"
  while [ ! -f "$SB/release" ]; do sleep 0.05; done ) &
holder=$!
while [ ! -f "$SB/held" ]; do sleep 0.05; done
bash "$BIN/auto-handoff-sweep.sh" >/dev/null 2>&1 &
sweeper=$!
end=$(( $(date +%s) + 10 ))
until grep -q 'ALERT waiting for the page lock' "$AUTODEV_HOME/logs/auto-handoff.log" 2>/dev/null ||
      [ "$(date +%s)" -ge "$end" ]; do sleep 0.05; done
assert_contains 'the sweep reached the lock and waited' "$(log_text)" 'ALERT waiting for the page lock'
rm -f "$STATE/$SID.covered"      # a send landed while the sweep waited
: > "$SB/release"
wait "$holder" "$sweeper"
pkill -f "$BIN/auto-handoff-watch.sh" 2>/dev/null
assert_eq 'an episode that ended during the wait sends no Slack line' "$(lines "$SB/slack.log")" 0
assert_eq 'an episode that ended during the wait sends no lane line' "$(lines "$SB/lane.log")" 0
sandbox_rm

echo '== a screen cleared before the alert ends the episode with no alert =='
# The person closed the menu, and no watcher send has landed yet to remove
# <sid>.covered: here the watcher runs dry (unarmed), so only the sweep's own
# screen read can see that the cover is gone.
setup
tick; age_episode 660
assert_file 'the episode is recorded and past 10 min' "$STATE/$SID.covered"
rm -f "$STATE/auto-handoff.armed"
covered none
tick
assert_eq 'cleared screen: no Slack line' "$(lines "$SB/slack.log")" 0
assert_eq 'cleared screen: no lane line' "$(lines "$SB/lane.log")" 0
assert_no_file 'cleared screen: the episode is over' "$STATE/$SID.covered"
assert_contains 'cleared screen: the log says why' "$(log_text)" 'ALERT-CLEAR the pane is reachable and its screen is clear'
arm; covered menu
: > "$STATE/$SID.compact-request"; rm -f "$STATE/$SID.cooldown"   # the dry cycle used both up
tick
s=$(since)
if [ -n "$s" ] && [ "$s" -gt "$AGED" ]; then _pass 'the next cover starts a new episode'
else _fail 'the next cover starts a new episode' "since=$s aged=$AGED"; fi
assert_eq 'a new episode is not alerted at once' "$(lines "$SB/slack.log")" 0
sandbox_rm

echo '== slow alert sends start only after every watcher is re-armed =='
setup; seat_b
tick; age_episode 660; age_episode 660 sess-b
echo 1 > "$SB/slack-slow"
: > "$AUTODEV_HOME/logs/auto-handoff.log"   # only this tick's re-arm lines count
tick
assert_eq 'two stuck seats: two Slack lines' "$(lines "$SB/slack.log")" 2
for f in "$SB"/log-at-slack.*; do
  assert_contains "when a Slack send began, sess-a's watcher was re-armed" "$(cat "$f")" '[sess-a] SWEEP re-arming watcher'
  assert_contains "when a Slack send began, sess-b's watcher was re-armed" "$(cat "$f")" '[sess-b] SWEEP re-arming watcher'
done
assert_eq 'the two alerts ran side by side' "$(sort -n "$SB/concurrency" | tail -n1)" 2
sandbox_rm

echo '== at most AUTODEV_ALERT_PARALLEL alerts at once =='
setup; seat_b
tick; age_episode 660; age_episode 660 sess-b
echo 1 > "$SB/slack-slow"
AUTODEV_ALERT_PARALLEL=1 tick
assert_eq 'parallel 1: both seats alerted' "$(lines "$SB/slack.log")" 2
assert_eq 'parallel 1: never two sends in flight' "$(sort -n "$SB/concurrency" | tail -n1)" 1
sandbox_rm

echo '== no alert starts once the budget is spent; the next tick sends it =='
setup
tick; age_episode 660
AUTODEV_ALERT_BUDGET=0 tick
assert_eq 'budget spent: no Slack line' "$(lines "$SB/slack.log")" 0
assert_eq 'budget spent: no lane line' "$(lines "$SB/lane.log")" 0
assert_no_file 'budget spent: nothing recorded as sent' "$STATE/$SID.covered-alert"
assert_contains 'budget spent: the log says so' "$(log_text)" "ALERT-SKIP the sweep's alert budget (0s) is spent"
tick
assert_eq 'next tick: one Slack line' "$(lines "$SB/slack.log")" 1
assert_eq 'next tick: one lane line' "$(lines "$SB/lane.log")" 1
sandbox_rm

echo '== slow sends cannot starve later seats: each is tried within three ticks =='
# Three seats whose sends are slow and keep failing, so all three stay due. A
# budget of 1 s with one alert at a time fits one send per tick. Without the
# skipped-first order the first seat in file order would take every tick.
setup; seat_b; seat_c
printf 'Alpha' > "$SB/tab-label.t7"; printf 'Beta' > "$SB/tab-label.t8"; printf 'Gamma' > "$SB/tab-label.t9"
tick
for s in "$SID" sess-b sess-c; do age_episode 660 "$s"; done
echo 2 > "$SB/slack-slow"; touch "$SB/slack-fail" "$SB/lane-fail"
for t in 1 2 3; do
  AUTODEV_ALERT_PARALLEL=1 AUTODEV_ALERT_BUDGET=1 tick
  assert_eq "rotation tick $t: one seat tried" "$(lines "$SB/slack.log")" "$t"
done
for l in Alpha Beta Gamma; do
  assert_contains "rotation: seat '$l' tried within three ticks" "$(cat "$SB/slack.log")" "seat '$l' is past"
done
assert_contains 'rotation: a skipped seat is told it goes first next tick' "$(log_text)" 'retry next tick, first in line'
sandbox_rm

echo '== a Persona seat whose pane is lost: no menu, one alert per episode =='
for kind in owner nopane; do
  case "$kind" in owner) want='pane not owned' ;; nopane) want='no pane' ;; esac
  setup; persona; lose_pane "$kind"
  : > "$SB/herdr-calls"
  tick
  assert_file "$kind: the sweep raises the unreachable flag" "$STATE/$SID.unreachable"
  assert_no_file "$kind: no episode before the gate has spared the seat the menu" "$STATE/$SID.covered"
  r=$(gate_reason)
  assert_contains "$kind: the gate gives the Persona notice" "$r" 'This is a Persona seat'
  assert_not_contains "$kind: the gate orders no menu" "$r" 'call the AskUserQuestion tool now'
  tick
  assert_contains "$kind: the sweep records the refusal" "$(cat "$STATE/$SID.covered" 2>/dev/null)" " $kind"
  assert_file "$kind: the marker stays queued" "$STATE/$SID.compact-request"
  assert_eq "$kind: nothing typed" "$(cat "$SB/typed")" ''
  age_episode 540
  tick
  assert_eq "$kind: at 9 min: no Slack line" "$(lines "$SB/slack.log")" 0
  assert_eq "$kind: at 9 min: no lane line" "$(lines "$SB/lane.log")" 0
  assert_eq "$kind: a repeat refusal keeps the episode start" "$(since)" "$AGED"
  age_episode 660
  tick
  assert_eq "$kind: past 10 min: exactly one Slack line" "$(lines "$SB/slack.log")" 1
  assert_eq "$kind: past 10 min: exactly one lane line" "$(lines "$SB/lane.log")" 1
  assert_contains "$kind: the Slack line names the reason" "$(cat "$SB/slack.log")" "(reason: $want)"
  assert_contains "$kind: the lane line names seat, context and reason" "$(cat "$SB/lane.log")" \
    "seat 'Engineer' is past its handoff line (context 40%) and automation has not reached its pane for 11 min (reason: $want)"
  assert_not_contains "$kind: no pane code in the Slack line" "$(cat "$SB/slack.log")" "$PANE"
  assert_not_contains "$kind: another session's screen is never read" "$(cat "$SB/herdr-calls")" "pane read $PANE"
  tick; tick
  assert_eq "$kind: later ticks send no second Slack line" "$(lines "$SB/slack.log")" 1
  assert_eq "$kind: later ticks send no second lane line" "$(lines "$SB/lane.log")" 1
  assert_eq "$kind: still nothing typed" "$(cat "$SB/typed")" ''
  assert_no_file "$kind: no real Slack or lane was called" "$SB/real-send-attempt"
  sandbox_rm
done

echo '== an unreachable flag from before this code starts no episode =='
setup; persona; lose_pane owner
printf 'pane %s ownership refused (owner: sess-z)\n' "$PANE" > "$STATE/$SID.unreachable"
touch -d '-2 hours' "$STATE/$SID.unreachable"
gate_reason >/dev/null               # the live seat is spared the menu, after the install
start=$(date +%s)
tick; tick
assert_eq 'old flag: no Slack line' "$(lines "$SB/slack.log")" 0
assert_eq 'old flag: no lane line' "$(lines "$SB/lane.log")" 0
s=$(since)
if [ -n "$s" ] && [ "$s" -ge "$start" ]; then _pass 'old flag: the episode starts at the first refusal recorded now'
else _fail 'old flag: the episode starts at the first refusal recorded now' "since=$s start=$start"; fi
sandbox_rm

echo '== a dead Persona seat (no gate since its flag) starts no episode =='
# The session died with its request pending; its pane was recycled. The sweep
# refuses it at every tick, but its gate never ran after the flag was raised.
setup; persona
touch -d '-1 hour' "$STATE/$SID.spared"   # spared once, long before
lose_pane owner
tick; tick
assert_file 'dead seat: the flag is raised' "$STATE/$SID.unreachable"
assert_no_file 'dead seat: no episode' "$STATE/$SID.covered"
assert_eq 'dead seat: no Slack line' "$(lines "$SB/slack.log")" 0
sandbox_rm

echo '== a seat outside ~/Persona whose pane is lost keeps the menu and gets no alert =='
setup; lose_pane owner
tick
assert_no_file 'non-Persona: no episode for a lost pane' "$STATE/$SID.covered"
assert_contains 'non-Persona: the gate still orders the menu' "$(gate_reason)" 'call the AskUserQuestion tool now'
printf '%s %s owner\n' "$(( $(date +%s) - 700 ))" "$(date +%s)" > "$STATE/$SID.covered"
tick
assert_eq 'non-Persona: an owner episode on file alerts no one' "$(lines "$SB/slack.log")" 0
assert_eq 'non-Persona: and sends no lane line' "$(lines "$SB/lane.log")" 0
sandbox_rm

echo '== the pane is lost while the alert waits for the page lock =='
# A covered seat is queued; while its alert waits for the lock, another session
# takes the pane. The locked half reads the pane again: a Persona seat is
# alerted with the reason as it now stands, any other seat is not alerted.
for who in persona other; do
  setup
  [ "$who" = persona ] && persona
  tick; age_episode 660
  ( exec 9>"$STATE/$SID.page.lock"; flock 9; : > "$SB/held"
    while [ ! -f "$SB/release" ]; do sleep 0.05; done ) &
  holder=$!
  while [ ! -f "$SB/held" ]; do sleep 0.05; done
  bash "$BIN/auto-handoff-sweep.sh" >/dev/null 2>&1 &
  sweeper=$!
  end=$(( $(date +%s) + 10 ))
  until grep -q 'ALERT waiting for the page lock' "$AUTODEV_HOME/logs/auto-handoff.log" 2>/dev/null ||
        [ "$(date +%s)" -ge "$end" ]; do sleep 0.05; done
  assert_contains "$who: the alert waited for the lock" "$(log_text)" 'ALERT waiting for the page lock'
  lose_pane owner
  : > "$SB/release"
  wait "$holder" "$sweeper"
  pkill -f "$BIN/auto-handoff-watch.sh" 2>/dev/null
  if [ "$who" = persona ]; then
    assert_eq 'Persona, pane lost during the wait: one Slack line' "$(lines "$SB/slack.log")" 1
    assert_contains 'Persona, pane lost during the wait: the reason read under the lock' "$(cat "$SB/slack.log")" '(reason: pane not owned)'
  else
    assert_eq 'non-Persona, pane lost during the wait: no Slack line' "$(lines "$SB/slack.log")" 0
    assert_eq 'non-Persona, pane lost during the wait: no lane line' "$(lines "$SB/lane.log")" 0
  fi
  sandbox_rm
done

echo '== a Persona pane given back with a clear screen ends the episode, no alert =='
setup; persona; start_lost_episode owner; age_episode 660
rm -f "$SB/pane-owner" "$STATE/sess-z.ctx" "$STATE/auto-handoff.armed"; covered none
tick
assert_eq 'given back: no Slack line' "$(lines "$SB/slack.log")" 0
assert_no_file 'given back: the episode is over' "$STATE/$SID.covered"
sandbox_rm

echo '== a Persona pane given back under a menu keeps its episode and alerts as a menu =='
setup; persona; start_lost_episode owner; age_episode 660
rm -f "$SB/pane-owner" "$STATE/sess-z.ctx"; covered menu
tick
assert_eq 'given back under a menu: one Slack line' "$(lines "$SB/slack.log")" 1
assert_contains 'given back under a menu: the reason is the menu' "$(cat "$SB/slack.log")" '(reason: menu)'
assert_eq 'given back under a menu: nothing typed' "$(cat "$SB/typed")" ''
sandbox_rm
unset AUTODEV_PERSONA_ROOT

finish
