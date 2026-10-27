#!/usr/bin/env bash
# Exercise the real mux library and hooks with fake herdr and controlled lock
# boundary shims. A daemon-hosted worker can run without an attached terminal.
. "$(dirname "$0")/lib.sh"

SID=sess-b
ORIG_PATH=$PATH
export AUTODEV_SETTLE=0 AUTODEV_POLL=0.01 AUTODEV_PRECHECK=0
export AUTODEV_WAIT_IDLE=3 AUTODEV_WAIT_COMPACT=3 AUTODEV_NO_WATCHERS=1

setup() {
  sandbox_new
  mkdir -p "$SB/fakebin"
  export PATH="$SB/fakebin:$ORIG_PATH" MUX_HERDR="$SB/fakebin/herdr" TEST_SID="$SID"
  cp "$SKILL_DIR/test/fixtures/panes/idle-prompt.txt" "$SB/screen"
  : > "$SB/typed"
  : > "$SB/herdr-calls"
  cat > "$MUX_HERDR" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SB/herdr-calls"
case "$1 $2" in
  'pane list') [ -f "$SB/list-unavailable" ] && exit 1; cat "$SB/panes.json" ;;
  'pane get')
    jq -ec --arg p "$3" '{result:{pane:(.result.panes[] | select(.pane_id==$p))}}' "$SB/panes.json" ;;
  'pane read')
    if [ -f "$SB/reassign-on-read" ]; then
      printf 'sess-a\n' > "$STATE/.paneowner-herdr-w1_pX"
      touch -d '1 minute ago' "$STATE/$TEST_SID.ctx"
      printf 'pct=40 ts=1\n' > "$STATE/sess-a.ctx"
    fi
    cat "$SB/screen" ;;
  'pane run')
    printf '%s %s\n' "$3" "$4" >> "$SB/typed"
    case "$4" in
      /handoff)
        printf '%s\n' "$(( $(date +%s) + 2 ))" > "$STATE/$TEST_SID.idle"
        hf="$AUTODEV_HOME/handoffs/fixture.md"
        printf 'fixture\n' > "$hf"
        printf '%s\n' "$hf" > "$AUTODEV_HOME/handoffs/.latest.$TEST_SID" ;;
      /compact) printf '%s\n' "$(( $(date +%s) + 2 ))" > "$STATE/$TEST_SID.compacted" ;;
    esac ;;
  'pane send-keys'|'pane send-text') printf '%s\n' "$*" >> "$SB/typed" ;;
  *) exit 1 ;;
esac
FAKE
  chmod +x "$MUX_HERDR"
  session_new "$SID" 40 w1:pX
  arm
  panes w1:pX sess-b idle
}

panes() { # one attached pane, or no pane
  if [ "$#" = 0 ]; then printf '{"result":{"panes":[]}}' > "$SB/panes.json"; return; fi
  jq -nc --arg p "$1" --arg s "$2" --arg st "$3" \
    '{result:{panes:[{pane_id:$p,agent_session:{value:$s},agent_status:$st}]}}' > "$SB/panes.json"
}
reach() ( . "$BIN/mux-lib.sh"; mux_session_reachable "$SID"; )
owner() ( . "$BIN/mux-lib.sh"; mux_init "$SID"; mux_pane_owner; )
register() ( export HERDR_ENV=1 HERDR_PANE_ID="$1"; . "$BIN/mux-lib.sh"; mux_register "$SID"; )
watch() { bash "$BIN/auto-handoff-watch.sh" "$SID" > "$SB/watch.out" 2>&1; }
stop() {
  jq -nc --arg sid "$SID" --argjson active "${1:-false}" \
    '{session_id:$sid,hook_event_name:"Stop",stop_hook_active:$active}' |
    bash "$BIN/cc-stop-hook.sh"
}
badge() {
  jq -nc --arg sid "$SID" '{session_id:$sid,context_window:{used_percentage:40}}' |
    bash "$BIN/cc-statusline.sh"
}
log_text() { cat "$AUTODEV_HOME/logs/auto-handoff.log"; }
block() { printf '%s' "$1" | jq -r '.decision // empty'; }
why() { printf '%s' "$1" | jq -r '.reason // empty'; }

echo '== stale session labels and genuine reuse =='
setup
panes w1:pX sess-a idle
printf 'pct=40 ts=0\n' > "$STATE/sess-a.ctx"
touch -d '10 minutes ago' "$STATE/sess-a.ctx"
assert_eq 'newer statusline owner defeats stale label' "$(owner)" "$SID"
watch
assert_contains 'stale label now reaches /handoff' "$(cat "$SB/typed")" 'w1:pX /handoff'
assert_contains 'stale label reaches /compact' "$(cat "$SB/typed")" 'w1:pX /compact'
assert_contains 'stale-label cycle completes' "$(log_text)" 'CYCLE COMPLETE'
assert_no_file 'stale label does not leave unreachable' "$STATE/$SID.unreachable"
sandbox_rm

setup
panes w1:pX sess-a idle
printf 'sess-a\n' > "$STATE/.paneowner-herdr-w1_pX"
watch
assert_eq 'reverse-owner evidence refuses recycled pane' "$(cat "$SB/typed")" ''
assert_file 'ownership refusal is visible' "$STATE/$SID.unreachable"
out=$(stop)
assert_eq 'refused ownership uses the primary Stop fallback' "$(block "$out")" block
assert_contains 'fallback asks this session to hand off' "$(why "$out")" /handoff
sandbox_rm

setup
panes w1:pX sess-a idle
printf 'pct=40 ts=1\n' > "$STATE/sess-a.ctx"
touch -d '1 minute ago' "$STATE/$SID.ctx"
assert_eq 'fresher other ctx also proves reuse' "$(owner)" sess-a
sandbox_rm

echo '== new sessions replace dead reverse owners =='
for previous in stale missing; do
  setup
  printf 'sess-a\n' > "$STATE/.paneowner-herdr-w1_pX"
  if [ "$previous" = stale ]; then
    printf 'pct=40 ts=1\n' > "$STATE/sess-a.ctx"
    touch -d '2 days ago' "$STATE/sess-a.ctx"
  fi
  register w1:pX
  assert_eq "$previous context: registration replaces dead reverse owner" "$(cat "$STATE/.paneowner-herdr-w1_pX")" "$SID"
  assert_eq "$previous context: current session owns the recycled pane" "$(owner)" "$SID"
  assert_no_file "$previous context: new session remains reachable" "$STATE/$SID.unreachable"
  watch
  assert_contains "$previous context: watcher drives the new session" "$(cat "$SB/typed")" 'w1:pX /handoff'
  assert_contains "$previous context: new session completes its cycle" "$(log_text)" 'CYCLE COMPLETE'
  sandbox_rm
done

setup
printf 'sess-a\n' > "$STATE/.paneowner-herdr-w1_pX"
printf 'pct=40 ts=1\n' > "$STATE/sess-a.ctx"
touch -d '1 minute ago' "$STATE/$SID.ctx"
register w1:pX
assert_eq 'fresher previous owner prevents reverse-file replacement' "$(cat "$STATE/.paneowner-herdr-w1_pX")" sess-a
assert_eq 'fresher previous owner is still refused despite our label' "$(owner)" sess-a
watch
assert_eq 'live previous owner receives no input' "$(cat "$SB/typed")" ''
assert_file 'live previous owner keeps unreachable visible' "$STATE/$SID.unreachable"
sandbox_rm

echo '== repeated registration uses a query-free fast path =='
setup
register w1:pX
calls=$(wc -l < "$SB/herdr-calls")
[ "$calls" -gt 0 ] && _pass 'initial registration actually queries herdr' || _fail 'initial registration actually queries herdr'
register w1:pX
assert_eq 'second immediate registration makes no herdr call' "$(wc -l < "$SB/herdr-calls")" "$calls"
printf '%s w1:pX w1:pX\n' "$(( $(date +%s) - 61 ))" > "$STATE/$SID.herdr-register-check"
register w1:pX
later_calls=$(wc -l < "$SB/herdr-calls")
[ "$later_calls" -gt "$calls" ] && _pass 'expired validation stamp queries herdr again' || _fail 'expired validation stamp queries herdr again'
panes w1:pY sess-b idle
register w1:pY
assert_eq 'changed environment pane bypasses the registration throttle' "$(cat "$STATE/$SID.herdr-pane")" w1:pY
sandbox_rm

setup
panes w1:pY sess-b idle
register w1:pX
calls=$(wc -l < "$SB/herdr-calls")
register w1:pX
assert_eq 'stable recovered binding with stale env also avoids herdr calls' "$(wc -l < "$SB/herdr-calls")" "$calls"
sandbox_rm

setup
register w1:pX
panes
reach
calls=$(wc -l < "$SB/herdr-calls")
panes w1:pX sess-b idle
register w1:pX
[ "$(wc -l < "$SB/herdr-calls")" -gt "$calls" ] && _pass 'unreachable flag bypasses a fresh registration stamp' || _fail 'unreachable flag bypasses a fresh registration stamp'
assert_no_file 'forced validation clears the recovered unreachable flag' "$STATE/$SID.unreachable"
sandbox_rm

setup
printf 'sess-a\n' > "$STATE/.paneowner-herdr-w1_pX"
cat > "$SB/fakebin/flock" <<'FAKE'
#!/usr/bin/env bash
# The competitor becomes live after initial validation but before the claim.
touch -d '1 minute ago' "$STATE/$TEST_SID.ctx"
printf 'pct=40 ts=1\n' > "$STATE/sess-a.ctx"
touch "$SB/claim-race-exercised"
exec /usr/bin/flock "$@"
FAKE
chmod +x "$SB/fakebin/flock"
register w1:pX
assert_file 'claim-lock ownership race was exercised' "$SB/claim-race-exercised"
assert_eq 'claim rechecks live ownership before replacing the reverse file' "$(cat "$STATE/.paneowner-herdr-w1_pX")" sess-a
assert_file 'failed late claim leaves a visible unreachable flag' "$STATE/$SID.unreachable"
assert_no_file 'failed late claim publishes no registration stamp' "$STATE/$SID.herdr-register-check"
sandbox_rm

echo '== renumbering, detach, and later registration =='
setup
panes w1:pY sess-b idle
reach
assert_eq 'renumbered pane is persisted' "$(cat "$STATE/$SID.herdr-pane")" w1:pY
register w1:pX
assert_eq 'stale inherited env cannot overwrite recovery' "$(cat "$STATE/$SID.herdr-pane")" w1:pY
assert_no_file 'resolved registration is reachable' "$STATE/$SID.unreachable"
sandbox_rm

setup
panes w1:pY sess-b idle
jq '.result.panes += [.result.panes[0] + {pane_id:"w1:pZ"}]' "$SB/panes.json" > "$SB/panes.tmp"
mv "$SB/panes.tmp" "$SB/panes.json"
reach
assert_file 'ambiguous session matches remain unreachable' "$STATE/$SID.unreachable"
assert_eq 'ambiguous resolution retains the old id' "$(cat "$STATE/$SID.herdr-pane")" w1:pX
sandbox_rm

setup
panes
reach; reach
assert_file 'background worker without an attachment is unreachable' "$STATE/$SID.unreachable"
assert_eq 'unreachable reason logs once per episode' "$(log_text | grep -c UNREACHABLE)" 1
assert_contains 'badge exposes unreachable state' "$(badge)" 'AUTO-HANDOFF: UNREACHABLE'
out=$(stop)
assert_eq 'no attached pane immediately triggers fallback' "$(block "$out")" block
assert_contains 'fallback names the compact-only request step' "$(why "$out")" '--compact-only --handoff'
assert_eq 'fallback once per cooldown' "$(stop)" ''
printf '%s\n' "$(( $(date +%s) - 901 ))" > "$STATE/$SID.fallback-cooldown"
assert_eq 'fallback can fire after cooldown' "$(block "$(stop)")" block
assert_eq 'no keys sent while detached' "$(cat "$SB/typed")" ''
panes w1:pY sess-b idle
register w1:pX
assert_no_file 'later re-resolution clears unreachable' "$STATE/$SID.unreachable"
assert_contains 'recovered badge reads armed' "$(badge)" 'AUTO-HANDOFF: ARMED'
assert_eq 'reachable session does not block' "$(stop)" ''
sandbox_rm

setup
# A separate attachment has no agent_session and no reverse registration.
panes w1:pY '' idle
printf 'w1:pY\n' > "$STATE/$SID.herdr-pane"
register w1:pY
assert_eq 'registration cannot invent ownership of an unlabelled attachment' "$(owner)" ''
assert_file 'unproved attached pane remains unreachable' "$STATE/$SID.unreachable"
assert_eq 'unproved pane uses the in-session fallback' "$(block "$(stop)")" block
assert_eq 'unproved pane receives no keys' "$(cat "$SB/typed")" ''
sandbox_rm

setup
panes w1:pX sess-a idle
printf 'sess-a\n' > "$STATE/.paneowner-herdr-w1_pX"
reach
panes w1:pY sess-b idle
register w1:pY
assert_eq 'new env registration can replace a recycled cached id' "$(cat "$STATE/$SID.herdr-pane")" w1:pY
assert_no_file 'new real attachment clears refusal' "$STATE/$SID.unreachable"
sandbox_rm

setup
panes w1:pY sess-b idle
rm "$STATE/$SID.herdr-pane"
touch "$SB/list-unavailable"
cat > "$SB/fakebin/ln" <<'FAKE'
#!/usr/bin/env bash
if [ "$2" = "$STATE/$TEST_SID.herdr-pane" ]; then
  printf 'w1:pY\n' > "$STATE/$TEST_SID.herdr-pane"
  touch "$SB/resolver-won"
fi
exec /bin/ln "$@"
FAKE
chmod +x "$SB/fakebin/ln"
register w1:pX
assert_file 'concurrent binding publication race was exercised' "$SB/resolver-won"
assert_eq 'initial stale env cannot clobber a concurrent resolved binding' "$(cat "$STATE/$SID.herdr-pane")" w1:pY
assert_no_file 'concurrent resolved binding remains reachable without pane list' "$STATE/$SID.unreachable"
sandbox_rm

echo '== Stop fallback gates and busy evaluations =='
setup; panes
printf 'pct=34 ts=1\n' > "$STATE/$SID.ctx"
assert_eq 'below threshold does not block' "$(stop)" ''
printf 'pct=35 ts=1\n' > "$STATE/$SID.ctx"
assert_eq 'at threshold uses fallback' "$(block "$(stop)")" block
sandbox_rm

setup; panes
printf 'pct=34 ts=1\n' > "$STATE/$SID.ctx"
assert_eq 'active goal below threshold stays silent' "$(stop true)" ''
printf 'pct=40 ts=1\n' > "$STATE/$SID.ctx"
out=$(stop true); stop_rc=$?
assert_eq 'active Stop returns success while reporting a block' "$stop_rc" 0
assert_eq 'goal crossing threshold mid-loop receives fallback' "$(block "$out")" block
assert_file 'active Stop preserves the idle signal used by watcher cycles' "$STATE/$SID.idle"
assert_file 'active goal fallback records the shared cooldown' "$STATE/$SID.fallback-cooldown"
assert_eq 'next active goal Stop is silent within cooldown' "$(stop true)" ''
assert_eq 'ordinary Stop shares the same active goal cooldown' "$(stop)" ''
printf '%s\n' "$(( $(date +%s) - 901 ))" > "$STATE/$SID.fallback-cooldown"
assert_eq 'active goal can receive fallback after cooldown expires' "$(block "$(stop true)")" block
sandbox_rm

setup; panes
rm "$STATE/auto-handoff.armed"
assert_eq 'dry run does not block' "$(stop)" ''
arm; touch "$STATE/disable-auto-compact"
assert_eq 'kill switch does not block' "$(stop)" ''
sandbox_rm

setup
panes w1:pX sess-b working
watch; watch
assert_eq 'two busy deferrals do not block' "$(stop)" ''
watch
assert_eq 'three consecutive busy deferrals are recorded' "$(cat "$STATE/$SID.busy-deferrals")" 3
assert_eq 'third busy deferral triggers fallback' "$(block "$(stop)")" block
assert_eq 'busy fallback does not inject into a pane' "$(cat "$SB/typed")" ''
printf 'pct=20 ts=1\n' > "$STATE/$SID.ctx"
watch
assert_no_file 'below-threshold evaluation resets busy streak' "$STATE/$SID.busy-deferrals"
sandbox_rm

setup
printf '3\n' > "$STATE/$SID.busy-deferrals"
touch -d '1 minute ago' "$STATE/$SID.busy-deferrals"
touch "$STATE/$SID.compacted"
printf 'pct=40 ts=1\n' > "$STATE/$SID.ctx"
assert_eq 'old busy streak does not survive compaction' "$(stop)" ''
panes
touch "$STATE/$SID.compacted"
assert_eq 'compaction newer than context suppresses stale-threshold fallback' "$(stop)" ''
sandbox_rm

echo '== pending requests and active Stop continuations stay bounded =='
for active in false true; do
  for kind in handoff-request compact-request; do
    setup; panes
    touch "$STATE/$SID.$kind"
    [ "$kind" = compact-request ] && handoff_pointer "$SID"
    out=$(stop "$active"); stop_rc=$?
    assert_eq "$kind active=$active: hook returns success" "$stop_rc" 0
    assert_eq "$kind active=$active: pending request blocks once" "$(block "$out")" block
    assert_eq "$kind active=$active: reason only addresses human compaction" "$(why "$out")" 'type /compact'
    assert_file "$kind active=$active: notice receipt is recorded" "$STATE/$SID.fallback-request"
    assert_eq "$kind active=$active: repeated active continuation is silent" "$(stop true)" ''
    assert_eq "$kind active=$active: repeated normal Stop is silent" "$(stop)" ''
    printf '1\n' > "$STATE/$SID.fallback-cooldown"
    assert_eq "$kind active=$active: cooldown expiry cannot repeat notice" "$(stop "$active")" ''
    assert_eq "$kind active=$active: no keys sent" "$(cat "$SB/typed")" ''
    sandbox_rm
  done
done

setup; panes
touch "$STATE/$SID.compact-request"
assert_eq 'a filed compact marker without its pointer still says only compact' "$(why "$(stop)")" 'type /compact'
assert_eq 'a marker without its pointer is still reported only once' "$(stop)" ''
sandbox_rm

setup; panes
touch "$STATE/$SID.handoff-request"
stop > "$SB/first"
handoff_pointer "$SID"
touch "$STATE/$SID.compact-request"
assert_eq 'new sibling request gets one compact notice' "$(why "$(stop)")" 'type /compact'
rm "$STATE/$SID.compact-request"
assert_eq 'removing sibling cannot re-arm an old request notice' "$(stop)" ''
sandbox_rm

setup; panes
stop > "$SB/first" & p1=$!
stop > "$SB/second" & p2=$!
wait "$p1"; wait "$p2"
assert_eq 'overlapping Stops emit exactly one block' "$(cat "$SB/first" "$SB/second" | jq -s length)" 1
assert_lock_absent 'fallback releases cycle lock' "$STATE/$SID.cycle.lock"
sandbox_rm

echo '== ownership and context changes across safety checks =='
setup
touch "$SB/reassign-on-read"
out=$( ( . "$BIN/mux-lib.sh"; mux_init "$SID"; mux_send_line /handoff; printf 'rc=%s' "$?"; ) 2>/dev/null)
assert_eq 'ownership changing during screen read refuses the send' "$out" rc=3
assert_eq 'late ownership change receives no input' "$(cat "$SB/typed")" ''
assert_file 'late ownership refusal is visible' "$STATE/$SID.unreachable"
sandbox_rm

setup
cat > "$SB/fakebin/ln" <<'FAKE'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "$STATE/$TEST_SID.cycle.lock" ]; then
    printf 'sess-a\n' > "$STATE/.paneowner-herdr-w1_pX"
    touch -d '1 minute ago' "$STATE/$TEST_SID.ctx"
    printf 'pct=40 ts=1\n' > "$STATE/sess-a.ctx"
  fi
done
exec /bin/ln "$@"
FAKE
chmod +x "$SB/fakebin/ln"
touch "$STATE/$SID.handoff-request"
watch
assert_eq 'post-lock owner recheck prevents a drive' "$(cat "$SB/typed")" ''
assert_file 'post-lock refusal retains pending handoff' "$STATE/$SID.handoff-request"
assert_file 'post-lock refusal marks unreachable' "$STATE/$SID.unreachable"
sandbox_rm

setup
panes w1:pX sess-a idle
printf 'sess-a\n' > "$STATE/.paneowner-herdr-w1_pX"
jq '.result.panes += [{pane_id:"w1:pY",agent_session:{value:"sess-b"},agent_status:"idle"}]' "$SB/panes.json" > "$SB/panes.tmp"
mv "$SB/panes.tmp" "$SB/panes.json"
handoff_pointer "$SID"
printf 'Read the handoff at "%s" and continue execution from where it leaves off.\n' \
  "$(cat "$AUTODEV_HOME/handoffs/.latest.$SID")" > "$STATE/$SID.reload-pending"
cat > "$SB/fakebin/ln" <<'FAKE'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "$STATE/$TEST_SID.cycle.lock" ]; then
    printf 'w1:pY\n' > "$STATE/$TEST_SID.herdr-pane"
    touch "$SB/rebound-during-lock"
  fi
done
exec /bin/ln "$@"
FAKE
chmod +x "$SB/fakebin/ln"
watch
assert_file 'concurrent rebind during reuse cleanup was exercised' "$SB/rebound-during-lock"
assert_eq 'reuse cleanup retains a concurrent recovered binding' "$(cat "$STATE/$SID.herdr-pane")" w1:pY
assert_file 'reuse cleanup retains reload state for the recovered pane' "$STATE/$SID.reload-pending"
assert_eq 'reuse cleanup sends nothing during the ownership transition' "$(cat "$SB/typed")" ''
sandbox_rm

setup; panes
cat > "$SB/fakebin/ln" <<'FAKE'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "$STATE/$TEST_SID.cycle.lock" ]; then
    printf 'pct=20 ts=1\n' > "$STATE/$TEST_SID.ctx"
  fi
done
exec /bin/ln "$@"
FAKE
chmod +x "$SB/fakebin/ln"
assert_eq 'post-lock lower context prevents stale fallback' "$(stop)" ''
assert_no_file 'stale fallback consumes no cooldown' "$STATE/$SID.fallback-cooldown"
sandbox_rm

finish
