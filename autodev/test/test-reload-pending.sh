#!/usr/bin/env bash
# A reload refused just after compaction must survive until the session is safe,
# but it must be retired if a newer turn/handoff or a different pane owner wins.

. "$(dirname "$0")/lib.sh"

SID=12121212-1212-1212-1212-121212121212
OTHER=34343434-3434-3434-3434-343434343434
export SID
FX="$SKILL_DIR/test/fixtures/panes"
ORIG_PATH="$PATH"

setup() {
  sandbox_new
  mkdir -p "$SB/herdr" "$SB/fakebin"
  printf 'idle\n' > "$SB/herdr/status"
  printf '%s\n' "$SID" > "$SB/herdr/owner"
  cp "$FX/idle-prompt.txt" "$SB/herdr/recent.txt"
  cp "$FX/idle-prompt.txt" "$SB/herdr/visible.txt"
  : > "$SB/typed.log"
  cat > "$SB/fakebin/herdr" <<'STUB'
#!/usr/bin/env bash
H="$SB/herdr"
case "${1:-} ${2:-}" in
  "pane get")
      printf '{"result":{"pane_id":"%s","agent_status":"%s","agent_session":{"value":"%s"}}}\n' \
        "$3" "$(cat "$H/status")" "$(cat "$H/owner")" ;;
  "pane read")
      source=recent-unwrapped
      while [ "$#" -gt 0 ]; do
        if [ "$1" = --source ] && [ "$#" -ge 2 ]; then source=$2; shift 2; else shift; fi
      done
      case "$source" in
        visible) cat "$H/visible.txt" ;;
        *)
          n=$(( $(cat "$H/reads" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$H/reads"
          if [ -f "$H/postcompact" ] && [ "$n" -ge 3 ]; then exit 0; fi
          cat "$H/recent.txt" ;;
      esac ;;
  "pane run")
      printf 'RUN %s\n' "$4" >> "$SB/typed.log"
      if [ "$4" = /compact ]; then
        printf '%s\n' "$(( $(date +%s) + 1 ))" > "$STATE/$SID.compacted"
        : > "$H/postcompact"
        : > "$H/reads"
        cp "$H/menu.txt" "$H/visible.txt"
      fi ;;
  "tab get"|"tab rename") exit 1 ;;
  *) echo "fake herdr: unhandled [$*]" >&2; exit 64 ;;
esac
STUB
  cat > "$SB/fakebin/notify-send" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SB/pages.log"
STUB
  chmod +x "$SB/fakebin/herdr" "$SB/fakebin/notify-send"
  export PATH="$SB/fakebin:$ORIG_PATH" MUX_HERDR="$SB/fakebin/herdr"
  export AUTODEV_SETTLE=0 AUTODEV_POLL=0.01 AUTODEV_PRECHECK=1 \
         AUTODEV_WAIT_IDLE=1 AUTODEV_WAIT_COMPACT=3 AUTODEV_PAGE_CMD="$SB/fakebin/notify-send"
  session_new "$SID" 15 "w1:p7G"
  handoff_pointer "$SID"
  printf '%s\n' "$(( $(date +%s) - 600 ))" > "$STATE/$SID.idle"
  touch -d '10 minutes ago' "$STATE/$SID.idle"
  cat > "$SB/herdr/menu.txt" <<'MENU'
│ Choose an option
❯ 1. Continue
  2. Stop

Enter to select · Tab/Arrow keys to navigate · Esc to cancel
────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────
⏵⏵ auto mode on (shift+tab to cycle) · ← for agents
MENU
  arm
}

enable_tmux() {
  rm -f "$STATE/$SID.herdr-pane"
  printf '%%7\n' > "$STATE/$SID.tmux-pane"
  printf '%s\n' "$SID" > "$STATE/.paneowner-tmux-_7"
  : > "$SB/tmux-input.txt"
  : > "$SB/tmux-text-sends.log"
  cat > "$SB/fakebin/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  list-panes) printf '%%7\n' ;;
  capture-pane)
    n=$(( $(cat "$SB/tmux-reads" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$SB/tmux-reads"
    if [ -f "$SB/tmux-later.txt" ] && [ "$n" -ge "$(cat "$SB/tmux-later-from")" ]; then
      cat "$SB/tmux-later.txt"
    else
      cat "$SB/tmux-screen.txt"
    fi ;;
  send-keys)
    if [ "${4:-}" = -l ]; then
      printf '%s' "$5" >> "$SB/tmux-input.txt"
      printf '%s\n' "$5" >> "$SB/tmux-text-sends.log"
    elif [ "${4:-}" = Enter ]; then
      input=$(cat "$SB/tmux-input.txt" 2>/dev/null || true)
      printf 'SUBMIT %s\n' "$input" >> "$SB/tmux-submits.log"
      if [ "$input" = /handoff ] && [ -f "$SB/tmux-complete-handoff" ]; then
        printf '%s\n' "$(( $(date +%s) + 2 ))" > "$STATE/$SID.idle"
      fi
      if [ "$input" = /compact ] && [ -f "$SB/tmux-complete-compact" ]; then
        printf '%s\n' "$(( $(date +%s) + 2 ))" > "$STATE/$SID.compacted"
      fi
      : > "$SB/tmux-input.txt"
    fi ;;
  display-message) : ;;
  *) echo "fake tmux: unhandled [$*]" >&2; exit 64 ;;
esac
STUB
  chmod +x "$SB/fakebin/tmux"
  cat > "$SB/fakebin/mkdir" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "$STATE/$SID.cycle.lock" ] && [ -f "$SB/attempt-before-lock" ]; then
    printf 'staged\n' > "$STATE/$SID.reload-attempt"
    rm -f "$SB/attempt-before-lock"
  fi
done
exec /bin/mkdir "$@"
STUB
  chmod +x "$SB/fakebin/mkdir"
}

sweep() { bash "$BIN/auto-handoff-sweep.sh" >"$SB/sweep.out" 2>&1; }
LOG() { cat "$AUTODEV_HOME/logs/auto-handoff.log" 2>/dev/null; }
wait_log() {
  local needle=$1 end=$(( $(date +%s) + 10 ))
  until LOG | grep -Fq "$needle"; do
    if [ "$(date +%s)" -ge "$end" ]; then
      _fail "wait for log [$needle]" "timed out after 10s; watcher path was not observed"
      return 1
    fi
    sleep 0.05
  done
}
reload_line() { printf 'Read the handoff at "%s" and continue execution from where it leaves off.' "$(cat "$AUTODEV_HOME/handoffs/.latest.$SID")"; }
seed_reload() {
  printf '%s\n' "$(reload_line)" > "$STATE/$SID.reload-pending"
}
no_reload_typed() {
  assert_not_contains "$1" "$(cat "$SB/typed.log")" "Read the handoff at"
}

# The first cycle reaches compaction, then recent is blank while visible holds an
# open menu. The shared guard refuses the reload and the watcher persists it.
setup
: > "$STATE/$SID.compact-request"
bash "$BIN/auto-handoff-watch.sh" "$SID" >"$SB/watch.out" 2>&1
assert_file "a refused post-compaction reload leaves its marker" "$STATE/$SID.reload-pending"
assert_eq "the marker stores the exact reload line" "$(cat "$STATE/$SID.reload-pending")" "$(reload_line)"
assert_contains "the refusal is reported" "$(LOG)" "DEFER awaiting-human (refused [Read the handoff at"
assert_no_file "the compact request is consumed" "$STATE/$SID.compact-request"
no_reload_typed "refused reload was not typed"

# Once the visible pane returns to the live idle prompt, the next sweep re-arms
# the locked watcher, which retries through mux_send_line and clears the marker.
cp "$FX/idle-prompt.txt" "$SB/herdr/recent.txt"
cp "$FX/idle-prompt.txt" "$SB/herdr/visible.txt"
sweep
wait_log "RELOAD retry sent"
assert_no_file "successful sweep retry clears the marker" "$STATE/$SID.reload-pending"
assert_contains "the exact reload line reached the idle pane" "$(cat "$SB/typed.log")" "RUN $(reload_line)"
sandbox_rm

# A completed session turn after marker creation retires the stale command.
setup
seed_reload
touch -d "@$(( $(date +%s) + 2 ))" "$STATE/$SID.idle"
sweep
wait_log "DROP reload-pending: superseded by completed-turn"
assert_no_file "a newer completed turn retires the marker" "$STATE/$SID.reload-pending"
no_reload_typed "a newer completed turn is not replayed"
sandbox_rm

# A newer per-session handoff pointer supersedes the old reload.
setup
seed_reload
touch -d "@$(( $(date +%s) + 2 ))" "$AUTODEV_HOME/handoffs/.latest.$SID"
sweep
wait_log "DROP reload-pending: superseded by new-handoff"
assert_no_file "a newer handoff retires the old reload" "$STATE/$SID.reload-pending"
no_reload_typed "a superseded handoff is not replayed"
sandbox_rm

# Herdr can recycle pane ids. A new owner clears the old marker without a send.
setup
seed_reload
printf '%s\n' "$OTHER" > "$SB/herdr/owner"
sweep
assert_no_file "a reused pane retires the old marker" "$STATE/$SID.reload-pending"
assert_contains "the sweeper logs the new owner" "$(LOG)" "pane is now owned by session $OTHER"
no_reload_typed "a pane owned by another session is never sent the old reload"
sandbox_rm

# A malformed marker is retained for visibility but never typed into a pane.
setup
printf '%s\n' 'Read the handoff at a malformed payload' > "$STATE/$SID.reload-pending"
sweep
wait_log "DEFER reload-pending: malformed or superseded payload"
assert_file "a malformed reload marker remains for investigation" "$STATE/$SID.reload-pending"
no_reload_typed "a malformed marker is never sent"
sandbox_rm

# A long-refused reload uses the existing one-page-per-marker stuck path.
setup
seed_reload
touch -d '2 hours ago' "$AUTODEV_HOME/handoffs/.latest.$SID"
touch -d '40 minutes ago' "$STATE/$SID.reload-pending"
touch -d '3 hours ago' "$STATE/$SID.idle"
cp "$FX/single-select.txt" "$SB/herdr/recent.txt"
sweep
assert_eq "PAGE_AFTER sends one page for a stuck reload" "$(wc -l < "$SB/pages.log" | tr -d ' ')" 1
assert_contains "the page identifies reload work" "$(cat "$SB/pages.log")" "reload for session $SID"
wait_log "DEFER reload-pending: pane is busy or awaiting the human"
no_reload_typed "a stuck reload stays guarded"
sandbox_rm

# If the live guard refuses before tmux stages the reload line, drop only the
# attempt lock. Keep the pending reload for a later idle sweep to retry.
setup
enable_tmux
seed_reload
cp "$FX/idle-prompt.txt" "$SB/tmux-screen.txt"
cp "$FX/single-select.txt" "$SB/tmux-later.txt"
printf '3\n' > "$SB/tmux-later-from"
bash "$BIN/auto-handoff-watch.sh" "$SID" >"$SB/watch-unstaged.out" 2>&1
assert_no_file "pre-staging refusal clears the tmux attempt lock" "$STATE/$SID.reload-attempt"
assert_file "pre-staging refusal retains the pending reload" "$STATE/$SID.reload-pending"
assert_eq "pending reload keeps its exact text after refusal" \
  "$(cat "$STATE/$SID.reload-pending")" "$(reload_line)"
assert_eq "pre-staging refusal types no literal" \
  "$(wc -l < "$SB/tmux-text-sends.log" | tr -d ' ')" 0
assert_eq "pre-staging refusal leaves the input line empty" \
  "$(cat "$SB/tmux-input.txt")" ""
assert_contains "pre-staging refusal reaches the live human-input guard" \
  "$(LOG)" "DEFER awaiting-human (reload retry); marker retained"

rm -f "$SB/tmux-later.txt"
: > "$SB/tmux-reads"
sweep
wait_log "RELOAD retry sent"
assert_no_file "successful retry clears pending reload" "$STATE/$SID.reload-pending"
assert_no_file "successful retry clears tmux attempt lock" "$STATE/$SID.reload-attempt"
assert_eq "later idle sweep stages one reload literal" \
  "$(wc -l < "$SB/tmux-text-sends.log" | tr -d ' ')" 1
assert_contains "later idle sweep submits the exact reload" \
  "$(cat "$SB/tmux-submits.log")" "SUBMIT $(reload_line)"
sandbox_rm

# Reproduce tmux's two-command send race, then prove a durable reload retry does
# not append to the old input. The attempted/staged marker stops retries and the
# existing PAGE_AFTER path asks for manual inspection; no key clears the line.
setup
enable_tmux
seed_reload
cp "$FX/idle-prompt.txt" "$SB/tmux-screen.txt"
cp "$FX/single-select.txt" "$SB/tmux-later.txt"
printf '4\n' > "$SB/tmux-later-from"
bash "$BIN/auto-handoff-watch.sh" "$SID" >"$SB/watch.out" 2>&1
assert_eq "tmux refusal records possibly staged input" \
  "$(cat "$STATE/$SID.reload-attempt" 2>/dev/null)" staged
assert_eq "first tmux reload attempt stages exactly one line" \
  "$(cat "$SB/tmux-input.txt")" "$(reload_line)"
assert_eq "first tmux reload attempt sends one literal" \
  "$(wc -l < "$SB/tmux-text-sends.log" | tr -d ' ')" 1
assert_contains "watcher records why the staged reload cannot retry" \
  "$(LOG)" "prior tmux send may have left text staged"

assert_eq "shared tmux sender blocks a different command under the staged lock" \
  "$(. "$BIN/mux-lib.sh"; MUX=tmux PANE=%7 MUX_SESSION="$SID"; mux_send_line /handoff >/dev/null 2>&1; echo $?)" 3
assert_eq "shared tmux staging helper blocks under the staged lock" \
  "$(. "$BIN/mux-lib.sh"; MUX=tmux PANE=%7 MUX_SESSION="$SID"; mux_stage_text /handoff >/dev/null 2>&1; echo $?)" 3
assert_eq "shared tmux key helper blocks under the staged lock" \
  "$(. "$BIN/mux-lib.sh"; MUX=tmux PANE=%7 MUX_SESSION="$SID"; mux_send_key Enter >/dev/null 2>&1; echo $?)" 3
assert_eq "shared lock refusal does not add another literal" \
  "$(wc -l < "$SB/tmux-text-sends.log" | tr -d ' ')" 1

rm -f "$SB/tmux-later.txt"
: > "$SB/tmux-reads"
bash "$BIN/auto-handoff-watch.sh" "$SID" >"$SB/watch-retry.out" 2>&1
assert_eq "a later watcher does not append another reload" \
  "$(wc -l < "$SB/tmux-text-sends.log" | tr -d ' ')" 1
assert_eq "the staged input remains untouched for human review" \
  "$(cat "$SB/tmux-input.txt")" "$(reload_line)"

touch -d '3 hours ago' "$STATE/$SID.idle"
touch -d '2 hours ago' "$AUTODEV_HOME/handoffs/.latest.$SID"
touch -d '40 minutes ago' "$STATE/$SID.reload-pending"
touch -d '40 minutes ago' "$STATE/$SID.reload-attempt"
sweep
assert_eq "staged reload reaches the existing page path" \
  "$(wc -l < "$SB/pages.log" | tr -d ' ')" 1
assert_contains "page tells the operator to inspect staged input" \
  "$(cat "$SB/pages.log")" "inspect the pane before submitting anything"
assert_eq "sweeper does not re-stage the reload" \
  "$(wc -l < "$SB/tmux-text-sends.log" | tr -d ' ')" 1
assert_eq "sweeper leaves the input line untouched" \
  "$(cat "$SB/tmux-input.txt")" "$(reload_line)"
sandbox_rm

# An overlapping watcher may have passed its pre-lock observation before the
# other watcher records staged input. Inject that state at lock acquisition and
# prove the post-lock check blocks the second literal.
setup
enable_tmux
seed_reload
cp "$FX/idle-prompt.txt" "$SB/tmux-screen.txt"
: > "$SB/attempt-before-lock"
bash "$BIN/auto-handoff-watch.sh" "$SID" >"$SB/watch-overlap.out" 2>&1
assert_eq "overlapping watcher sees the attempt written before lock acquisition" \
  "$(cat "$STATE/$SID.reload-attempt")" staged
assert_eq "overlapping watcher sends no second literal" \
  "$(wc -l < "$SB/tmux-text-sends.log" | tr -d ' ')" 0
assert_contains "overlapping watcher logs the staged-input lock" \
  "$(LOG)" "no session sends are allowed"
sandbox_rm

# A newer handoff request may supersede the pending reload, but it cannot
# authorize /handoff over a possibly staged reload literal. The attempt lock
# remains, and PAGE_AFTER calls out both the staged input and waiting request.
setup
enable_tmux
seed_reload
touch -d '50 minutes ago' "$STATE/$SID.reload-pending"
printf 'staged\n' > "$STATE/$SID.reload-attempt"
touch -d '40 minutes ago' "$STATE/$SID.reload-attempt"
touch -d '3 hours ago' "$STATE/$SID.idle"
: > "$STATE/$SID.handoff-request"
bash "$BIN/auto-handoff-watch.sh" "$SID" >"$SB/watch-superseded.out" 2>&1
assert_no_file "new handoff supersedes only the stale reload marker" "$STATE/$SID.reload-pending"
assert_file "new handoff leaves the staged-input lock intact" "$STATE/$SID.reload-attempt"
assert_eq "staged lock prevents /handoff from being typed" \
  "$(wc -l < "$SB/tmux-text-sends.log" | tr -d ' ')" 0
assert_contains "watcher logs refusal of every send under the staged lock" \
  "$(LOG)" "no session sends are allowed"
sweep
assert_eq "staged lock pages once after PAGE_AFTER" \
  "$(wc -l < "$SB/pages.log" | tr -d ' ')" 1
assert_contains "page mentions the staged input" \
  "$(cat "$SB/pages.log")" "may contain staged text"
assert_contains "page identifies the waiting newer request" \
  "$(cat "$SB/pages.log")" "handoff-request"
assert_eq "sweeper does not stage /handoff" \
  "$(wc -l < "$SB/tmux-text-sends.log" | tr -d ' ')" 0
sandbox_rm

# A strictly newer .idle proves the staged line was submitted. The lock clears
# under the cycle lock, and a normal explicit handoff cycle can then proceed.
setup
enable_tmux
printf '%s\n' staged > "$STATE/$SID.reload-attempt"
touch -d '20 minutes ago' "$STATE/$SID.reload-attempt"
printf '%s\n' "$(( $(date +%s) + 2 ))" > "$STATE/$SID.idle"
: > "$STATE/$SID.handoff-request"
: > "$SB/tmux-complete-handoff"
: > "$SB/tmux-complete-compact"
cp "$FX/idle-prompt.txt" "$SB/tmux-screen.txt"
bash "$BIN/auto-handoff-watch.sh" "$SID" >"$SB/watch-after-idle.out" 2>&1
assert_no_file "newer idle clears the staged-input lock" "$STATE/$SID.reload-attempt"
assert_contains "normal cycle resumes with /handoff" \
  "$(cat "$SB/tmux-text-sends.log")" "/handoff"
assert_contains "normal cycle resumes with /compact" \
  "$(cat "$SB/tmux-text-sends.log")" "/compact"
assert_contains "normal cycle resumes and completes" \
  "$(cat "$SB/watch-after-idle.out")$(LOG)" "CYCLE COMPLETE"
assert_no_file "successful resumed cycle leaves no reload marker" "$STATE/$SID.reload-pending"
sandbox_rm

finish
