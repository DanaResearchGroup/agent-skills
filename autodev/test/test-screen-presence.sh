#!/usr/bin/env bash
# Send-boundary checks use the real mux library and a fixture-backed fake herdr.
. "$(dirname "$0")/lib.sh"
export AUTODEV_POLL=0.01

sleep() {
  printf '%s\n' "$*" >> "$SB/sleeps"
  command sleep "$@"
}

setup() {
  sandbox_new
  export MUX_HERDR="$SB/herdr"
  cat > "$MUX_HERDR" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SB/calls"
case "$1 $2" in
  'pane get')
    owner=sess-a
    [ -f "$SB/new-owner" ] && owner=sess-b
    offset=0
    [ -f "$SB/scroll-offset" ] && offset=$(cat "$SB/scroll-offset")
    printf '{"result":{"pane":{"agent_session":{"value":"%s"},"agent_status":"idle","scroll":{"offset_from_bottom":%s}}}}\n' "$owner" "$offset" ;;
  'pane read')
    if [ "$5" = visible ]; then
      [ -f "$SB/read-fails" ] && exit 1
      if [ -f "$SB/blank-reads" ] && [ "$(cat "$SB/read-count")" -le "$(cat "$SB/blank-reads")" ]; then
        exit 0
      fi
      if [ -f "$SB/visible" ]; then cat "$SB/visible"; else cat "$SB/screen"; fi
      exit 0
    fi
    [ -f "$SB/recent-fails" ] && { printf 'partial stale output'; exit 1; }
    [ -f "$SB/recent-empty" ] && exit 0
    [ -f "$SB/recent-blank" ] && { printf '  \n\t\n'; exit 0; }
    if [ "$7" = 5 ]; then
      n=0
      [ -f "$SB/read-count" ] && n=$(cat "$SB/read-count")
      n=$((n + 1)); printf '%s\n' "$n" > "$SB/read-count"
      if [ -f "$SB/blank-reads" ] && [ "$n" -le "$(cat "$SB/blank-reads")" ]; then
        [ -f "$SB/reassign-after-blank" ] && touch "$SB/new-owner"
        printf '\n\n'; exit 0
      fi
    fi
    [ -f "$SB/read-fails" ] && exit 1
    # Model a screen switch while the caller checks for an open dialog. The
    # subsequent send guard must inspect again rather than reuse that snapshot.
    if [ -f "$SB/switch-on-dialog" ] && [ "$7" = 80 ]; then
      touch "$SB/switch-exercised"
      cp "$SKILL_DIR/test/fixtures/panes/session-b-status.txt" "$SB/screen"
      cat "$SKILL_DIR/test/fixtures/panes/session-a-status.txt"
    else
      tail -n "$7" "$SB/screen"
    fi ;;
  'pane run'|'pane send-text'|'pane send-keys') printf '%s\n' "$*" >> "$SB/typed" ;;
  *) exit 1 ;;
esac
FAKE
  chmod +x "$MUX_HERDR"
  export SKILL_DIR
  : > "$SB/calls"
  : > "$SB/typed"
  : > "$SB/sleeps"
  session_new sess-a 40 w1:pX
  printf 'pct=30 ts=1\n' > "$STATE/sess-b.ctx"
  touch -d '1 minute ago' "$STATE/sess-b.ctx"
  printf 'claude\n' > "$STATE/sess-a.runtime"
  cp "$SKILL_DIR/test/fixtures/panes/session-b-status.txt" "$SB/screen"
  . "$BIN/mux-lib.sh"
  mux_init sess-a
}

send() {
  case "$1" in
    line) mux_send_line /compact ;;
    stage) mux_stage_text reload ;;
    key) mux_send_key Escape ;;
    own-key) mux_send_key --own-prompt Escape ;;
  esac
}

stop() {
  printf '{"session_id":"sess-a","hook_event_name":"Stop"}' |
    AUTODEV_NO_WATCHERS=1 bash "$BIN/cc-stop-hook.sh"
}

for method in line stage key own-key; do
  setup
  assert_eq "$method: stale metadata still favours session A" "$(mux_pane_owner)" sess-a
  send "$method" > "$SB/send.out" 2>&1; rc=$?
  assert_eq "$method: foreign screen refuses input" "$rc" 3
  assert_eq "$method: no keys or text sent" "$(cat "$SB/typed")" ''
  assert_file "$method: session marked unreachable" "$STATE/sess-a.unreachable"
  assert_contains "$method: reason identifies missing tag" "$(cat "$STATE/sess-a.unreachable")" 'lacks ⟨cc:sess-a⟩ before send'
  mux_session_reachable sess-a
  assert_file "$method: metadata cannot clear screen refusal" "$STATE/sess-a.unreachable"
  send "$method" > "$SB/send.out" 2>&1
  assert_eq "$method: repeated refusal logs once" "$(wc -l < "$AUTODEV_HOME/logs/auto-handoff.log")" 1
  cp "$SKILL_DIR/test/fixtures/panes/session-a-status.txt" "$SB/screen"
  send "$method" > "$SB/send.out" 2>&1; rc=$?
  assert_eq "$method: own tag permits input" "$rc" 0
  assert_eq "$method: exactly one send recorded" "$(wc -l < "$SB/typed")" 1
  assert_no_file "$method: screen recovery clears refusal" "$STATE/sess-a.unreachable"
  assert_contains "$method: bounded explicit text read" "$(cat "$SB/calls")" 'pane read w1:pX --source recent-unwrapped --lines 5 --format text'
  sandbox_rm
done

setup
cp "$SKILL_DIR/test/fixtures/panes/session-a-status.txt" "$SB/screen"
printf '2\n' > "$SB/blank-reads"
mux_send_line reload > "$SB/send.out" 2>&1; rc=$?
assert_eq 'two blank redraws recover and allow reload' "$rc" 0
assert_eq 'recovered redraw sends exactly the reload line' "$(cat "$SB/typed")" 'pane run w1:pX reload'
assert_eq 'redraw recovery waits only between failed attempts' "$(wc -l < "$SB/sleeps")" 2
assert_eq 'redraw retry honors AUTODEV_POLL' "$(sort -u "$SB/sleeps")" 0.01
assert_no_file 'transient redraw does not mark unreachable' "$STATE/sess-a.unreachable"
assert_no_file 'transient redraw produces no refusal log' "$AUTODEV_HOME/logs/auto-handoff.log"
sandbox_rm

setup
: > "$SB/screen"
mux_send_line reload > "$SB/send.out" 2>&1; rc=$?
assert_eq 'persistent blank screen refuses reload' "$rc" 3
assert_eq 'persistent blank screen stops after five reads' "$(cat "$SB/read-count")" 5
assert_eq 'persistent blank screen sleeps four times' "$(wc -l < "$SB/sleeps")" 4
assert_eq 'persistent blank screen never sends' "$(cat "$SB/typed")" ''
assert_eq 'persistent blank screen records one final refusal' "$(wc -l < "$AUTODEV_HOME/logs/auto-handoff.log")" 1
sandbox_rm

setup
cp "$SKILL_DIR/test/fixtures/panes/session-a-status.txt" "$SB/screen"
printf '1\n' > "$SB/blank-reads"
touch "$SB/reassign-after-blank"
printf 'pct=40 ts=1\n' > "$STATE/sess-b.ctx"
touch -d '1 minute ago' "$STATE/sess-a.ctx"
mux_send_line reload > "$SB/send.out" 2>&1; rc=$?
assert_eq 'ownership lost during redraw wait refuses reload' "$rc" 3
assert_eq 'ownership change during retry sends nothing' "$(cat "$SB/typed")" ''
assert_contains 'ownership change records the ownership reason' "$(cat "$STATE/sess-a.unreachable")" 'lost live ownership'
sandbox_rm

setup
cp "$SKILL_DIR/test/fixtures/panes/single-select.txt" "$SB/screen"
printf ' ⟨cc:sess-a⟩\n' >> "$SB/screen"
printf '1\n' > "$SB/blank-reads"
mux_send_key --own-prompt Escape > "$SB/send.out" 2>&1; rc=$?
assert_eq 'dialog opening during redraw wait refuses even an own-prompt key' "$rc" 3
assert_eq 'dialog appearing during retry gets no keys' "$(cat "$SB/typed")" ''
assert_eq 'dialog test reached tag recovery on the second read' "$(cat "$SB/read-count")" 2
assert_contains 'recovered own-prompt path rechecks the dialog screen' "$(cat "$SB/calls")" 'pane read w1:pX --source recent-unwrapped --lines 80'
sandbox_rm

for screen in empty unreadable old-tag; do
  setup
  case "$screen" in
    empty) : > "$SB/screen" ;;
    unreadable) touch "$SB/read-fails" ;;
    old-tag)
      cat "$SKILL_DIR/test/fixtures/panes/session-a-status.txt" > "$SB/screen"
      cat "$SKILL_DIR/test/fixtures/panes/session-b-status.txt" >> "$SB/screen" ;;
  esac
  mux_send_line /compact > "$SB/send.out" 2>&1; rc=$?
  assert_eq "$screen: presence unproved refuses" "$rc" 3
  assert_eq "$screen: no send" "$(cat "$SB/typed")" ''
  assert_file "$screen: unreachable is recorded" "$STATE/sess-a.unreachable"
  sandbox_rm
done

setup
touch "$SB/switch-on-dialog"
cp "$SKILL_DIR/test/fixtures/panes/session-a-status.txt" "$SB/screen"
mux_send_line /compact > "$SB/send.out" 2>&1; rc=$?
assert_eq 'screen switch after dialog check refuses at final boundary' "$rc" 3
assert_eq 'screen switch sends nothing' "$(cat "$SB/typed")" ''
assert_file 'dialog-read switch was exercised' "$SB/switch-exercised"
sandbox_rm

setup
arm
printf 'pct=35 ts=1\n' > "$STATE/sess-a.ctx"
mux_send_key --own-prompt Escape > "$SB/send.out" 2>&1; rc=$?
assert_eq 'Stop regression starts with a screen refusal' "$rc" 3
mux_session_reachable sess-a; rc=$?
assert_eq 'screen refusal retains metadata reachability for watcher retries' "$rc" 0
assert_file 'screen refusal persists before Stop fallback' "$STATE/sess-a.unreachable"
out=$(stop)
assert_eq 'screen refusal at threshold triggers Stop block' "$(printf '%s' "$out" | jq -r '.decision // empty')" block
assert_contains 'screen refusal fallback requests in-session handoff' "$(printf '%s' "$out" | jq -r '.reason // empty')" 'Run /handoff'
assert_file 'screen refusal fallback records cooldown' "$STATE/sess-a.fallback-cooldown"
assert_eq 'screen refusal fallback blocks only once within cooldown' "$(stop)" ''
assert_eq 'Stop fallback never types into the refused pane' "$(cat "$SB/typed")" ''
cp "$SKILL_DIR/test/fixtures/panes/session-a-status.txt" "$SB/screen"
mux_send_key --own-prompt Escape > "$SB/send.out" 2>&1; rc=$?
assert_eq 'own tag allows the next send-time retry' "$rc" 0
assert_no_file 'successful send-time check clears screen refusal before Stop' "$STATE/sess-a.unreachable"
# Recovery silence must follow from the cleared refusal, not the cooldown.
rm -f "$STATE/sess-a.fallback-cooldown"
assert_eq 'recovered screen makes Stop silent even without cooldown' "$(stop)" ''
assert_no_file 'recovered Stop consumes no fallback cooldown' "$STATE/sess-a.fallback-cooldown"
sandbox_rm

# After compaction, visible is the only usable source. Test the actual guard
# directly so neither a dialog precheck nor a fake send can hide its result.
for recent in empty blank fails; do
  setup
  touch "$SB/recent-$recent"
  sed 's/AUTO-HANDOFF: ARMED/AUTO-HANDOFF: ARMED ⟨cc:sess-a⟩/' \
    "$SKILL_DIR/test/fixtures/panes/post-compact-visible-idle.txt" > "$SB/visible"
  mux_awaiting_human; rc=$?
  assert_eq "$recent recent: visible idle screen is not awaiting" "$rc" 1
  mux_send_line reload > "$SB/send.out" 2>&1; rc=$?
  assert_eq "$recent recent: visible idle owner permits reload" "$rc" 0
  assert_eq "$recent recent: fake records exactly the reload" "$(cat "$SB/typed")" 'pane run w1:pX reload'
  : > "$SB/typed"
  _mux_refuse_unowned; rc=$?
  assert_eq "$recent recent: visible owner tag passes" "$rc" 0
  assert_contains "$recent recent: visible text was requested" "$(cat "$SB/calls")" 'pane read w1:pX --source visible --format text'
  printf '1\n' > "$SB/scroll-offset"
  _mux_refuse_unowned; rc=$?
  assert_eq "$recent recent: scrolled owner tag refuses" "$rc" 1
  assert_file "$recent recent: scrolled viewport records refusal" "$STATE/sess-a.unreachable"
  mux_send_key --own-prompt Escape > "$SB/send.out" 2>&1; rc=$?
  assert_eq "$recent recent: scrolled owner tag refuses own-prompt key" "$rc" 3
  assert_eq "$recent recent: scrolled viewport gets no key" "$(cat "$SB/typed")" ''
  printf '0\n' > "$SB/scroll-offset"
  _mux_refuse_unowned; rc=$?
  assert_eq "$recent recent: bottom owner tag passes after scrolling back" "$rc" 0
  assert_no_file "$recent recent: bottom recovery clears refusal" "$STATE/sess-a.unreachable"
  mux_send_key --own-prompt Escape > "$SB/send.out" 2>&1; rc=$?
  assert_eq "$recent recent: bottom owner tag permits own-prompt key" "$rc" 0
  assert_eq "$recent recent: bottom viewport gets exactly one key" "$(cat "$SB/typed")" 'pane send-keys w1:pX Escape'
  : > "$SB/typed"
  cp "$SKILL_DIR/test/fixtures/panes/session-b-status.txt" "$SB/visible"
  _mux_refuse_unowned; rc=$?
  assert_eq "$recent recent: visible foreign tag refuses" "$rc" 1
  assert_file "$recent recent: refusal is recorded" "$STATE/sess-a.unreachable"
  # The split is inside the tag, not just between the tag and nearby text.
  printf '❯\n────────────\n AUTO-HANDOFF: ARMED ⟨cc:ses\ns-a⟩ Claude\n auto mode on\n' > "$SB/visible"
  _mux_refuse_unowned; rc=$?
  assert_eq "$recent recent: wrapped visible owner tag recovers" "$rc" 0
  assert_no_file "$recent recent: recovery clears refusal" "$STATE/sess-a.unreachable"
  cat "$SKILL_DIR/test/fixtures/panes/session-a-status.txt" > "$SB/visible"
  printf 'one\ntwo\nthree\nfour\nfive\n' >> "$SB/visible"
  _mux_refuse_unowned; rc=$?
  assert_eq "$recent recent: old viewport tag outside bottom five refuses" "$rc" 1
  : > "$SB/visible"
  _mux_refuse_unowned; rc=$?
  assert_eq "$recent recent: blank visible refuses" "$rc" 1
  assert_eq "$recent recent: guard tests send no input" "$(cat "$SB/typed")" ''
  sandbox_rm
done

for runtime in codex unknown; do
  setup
  if [ "$runtime" = unknown ]; then rm "$STATE/sess-a.runtime"; else printf '%s\n' "$runtime" > "$STATE/sess-a.runtime"; fi
  # The own-prompt key bypasses dialog reads, so any pane read here would be a
  # new presence check for a runtime whose behavior must stay unchanged.
  mux_send_key --own-prompt Escape > "$SB/send.out" 2>&1; rc=$?
  assert_eq "$runtime: prior send behavior preserved" "$rc" 0
  assert_eq "$runtime: one key sent" "$(cat "$SB/typed")" 'pane send-keys w1:pX Escape'
  assert_not_contains "$runtime: no screen presence probe" "$(cat "$SB/calls")" 'pane read'
  sandbox_rm
done

setup
# Registration/status rendering must never perform a pane read, even with an
# existing screen refusal. Rendering also must not erase that refusal.
mux_send_key --own-prompt Escape > "$SB/send.out" 2>&1
: > "$SB/calls"
for pct in 40 null; do
  out=$(printf '{"session_id":"sess-a","context_window":{"used_percentage":%s}}' "$pct" |
    HERDR_ENV=1 HERDR_PANE_ID=w1:pX bash "$BIN/cc-statusline.sh")
  assert_contains "$pct: status line renders tag" "$out" '⟨cc:sess-a⟩'
  assert_contains "$pct: status line retains unreachable badge" "$out" 'AUTO-HANDOFF: UNREACHABLE'
done
assert_not_contains 'rendering never reads a pane screen' "$(cat "$SB/calls")" 'pane read'
out=$(printf '{"session_id":"ab12cd34-1234-5678-9012-123456789abc"}' | bash "$BIN/cc-statusline.sh")
assert_contains 'status tag uses first eight session characters' "$out" '⟨cc:ab12cd34⟩'
assert_not_contains 'status tag omits session suffix' "$out" '1234-5678'
out=$(printf '{}' | bash "$BIN/cc-statusline.sh")
assert_not_contains 'missing session id prints no tag' "$out" '⟨cc:'
sandbox_rm
finish
