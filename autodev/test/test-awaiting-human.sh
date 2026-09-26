#!/usr/bin/env bash
# Bug: a pane injector answered the owner's open question by typing into it.
#
# The watchers type text + Enter into Claude Code panes (/handoff, /compact,
# continue, /usage-credits, the PM nudge) once the pane is "not busy". That
# check counted a pane sitting at an open AskUserQuestion menu as idle: herdr
# reports the form as `blocked`, and mux_busy mapped idle|done|blocked to
# "safe". The Enter then selected the pre-highlighted option — the one marked
# "(Recommended)" — and the agent recorded it as the owner's ruling. It happened
# twice on 2026-09-23 (/compact at 08.31.48, /handoff at 22.27.51, pane w1:p7G).
#
# Unlike the other watcher tests, these run the REAL mux-lib.sh. Only the herdr
# executable is faked: it serves a fixture screen and a status, and logs every
# keystroke it is asked to type instead of typing it. So the gate under test is
# the one the live watchers run, not a stub's idea of it.
#
# Screens are under fixtures/panes/. They are real herdr captures of Claude
# Code panes with the question wording neutralised (this repo is public); the
# chrome the detector keys on is untouched. multi-select.txt and other-row.txt
# are assembled from the same chrome, per the question view in the Claude Code
# bundle, because no capture of those states existed on disk.

. "$(dirname "$0")/lib.sh"

SID=55555555-5555-5555-5555-555555555555
FX="$SKILL_DIR/test/fixtures/panes"
export AUTODEV_SETTLE=0 AUTODEV_POLL=1 AUTODEV_PRECHECK=2 \
       AUTODEV_WAIT_IDLE=2 AUTODEV_WAIT_COMPACT=2

# --- fake herdr --------------------------------------------------------------
# $SB/herdr/screen.txt  what `pane read` returns (absent or read-fail => exit 1)
# $SB/herdr/status      agent_status for `pane get` (default idle)
# $SB/typed.log         every pane run / send-text / send-keys, one per line
setup() {
  sandbox_new
  mkdir -p "$SB/herdr" "$SB/fakebin"
  : > "$SB/typed.log"
  printf 'idle\n' > "$SB/herdr/status"
  cat > "$SB/fakebin/herdr" <<'STUB'
#!/usr/bin/env bash
H="$SB/herdr"
case "${1:-} ${2:-}" in
  "pane get")
      printf '{"result":{"pane_id":"%s","agent_status":"%s","agent_session":{"value":"%s"}}}\n' \
        "$3" "$(cat "$H/status")" "$(cat "$H/owner" 2>/dev/null)" ;;
  "pane read")
      [ -f "$H/read-fail" ] && exit 1
      n=$(( $(cat "$H/reads" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$H/reads"
      if [ -f "$H/later.txt" ] && [ "$n" -ge "$(cat "$H/later-from")" ]; then
        cat "$H/later.txt"; exit 0
      fi
      [ -f "$H/screen.txt" ] || exit 1
      cat "$H/screen.txt" ;;
  "pane run")
      [ -f "$H/run-fail" ] && exit 1
      printf 'RUN %s\n' "$4" >> "$SB/typed.log" ;;
  "pane send-text") printf 'TEXT %s\n' "$4" >> "$SB/typed.log" ;;
  "pane send-keys") printf 'KEY %s\n'  "$4" >> "$SB/typed.log" ;;
  "tab get"|"tab rename") exit 1 ;;
  *) echo "fake herdr: unhandled [$*]" >&2; exit 64 ;;
esac
STUB
  cat > "$SB/fakebin/tmux" <<'STUB'
#!/usr/bin/env bash
H="$SB/herdr"
case "${1:-}" in
  capture-pane)
      n=$(( $(cat "$H/tmux-reads" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$H/tmux-reads"
      if [ -f "$H/later.txt" ] && [ "$n" -ge "$(cat "$H/later-from")" ]; then
        cat "$H/later.txt"; exit 0
      fi
      [ -f "$H/screen.txt" ] || exit 1
      cat "$H/screen.txt" ;;
  send-keys)
      if [ "${4:-}" = -l ]; then printf 'TEXT %s\n' "$5" >> "$SB/typed.log"
      else printf 'KEY %s\n' "$4" >> "$SB/typed.log"
      fi ;;
  *) echo "fake tmux: unhandled [$*]" >&2; exit 64 ;;
esac
STUB
  chmod +x "$SB/fakebin/herdr" "$SB/fakebin/tmux"
  export PATH="$SB/fakebin:$ORIG_PATH" MUX_HERDR="$SB/fakebin/herdr"
  session_new "$SID" 15 "w1:p7G"
  printf '%s\n' "$SID" > "$SB/herdr/owner"
  arm
}
ORIG_PATH="$PATH"

screen() { cp "$FX/$1.txt" "$SB/herdr/screen.txt"; }
typed()  { cat "$SB/typed.log"; }
nothing_typed() { assert_eq "$1" "$(typed)" ""; }
LOG() { cat "$AUTODEV_HOME/logs/$1.log" 2>/dev/null; }

# Run a mux-lib function against the fake pane, in a subshell so the library's
# globals never leak between cases. Prints the function's exit status.
# shellcheck disable=SC2034  # MUX/PANE are read by the sourced library
mux() { ( . "$BIN/mux-lib.sh"; MUX=herdr PANE=w1:p7G; "$@" >/dev/null 2>&1; echo $? ); }
mux_tmux() { ( . "$BIN/mux-lib.sh"; MUX=tmux PANE=%7; "$@" >/dev/null 2>&1; echo $? ); }

MENUS="single-select multi-select multi-question preview other-row review-answers"

echo "== the detector: every question variant, on screen text alone =="
setup
for fx in $MENUS; do
  assert_eq "open $fx question is awaiting the human" \
    "$( . "$BIN/mux-lib.sh"; mux_text_awaiting_human < "$FX/$fx.txt"; echo $?)" 0
done
assert_eq "a Bash permission prompt is awaiting the human" \
  "$( . "$BIN/mux-lib.sh"; mux_text_awaiting_human < "$FX/permission-bash.txt"; echo $?)" 0
assert_eq "a plain idle prompt is not" \
  "$( . "$BIN/mux-lib.sh"; mux_text_awaiting_human < "$FX/idle-prompt.txt"; echo $?)" 1
assert_eq "footer text quoted higher up in the transcript is not" \
  "$( . "$BIN/mux-lib.sh"; mux_text_awaiting_human < "$FX/idle-after-answer.txt"; echo $?)" 1
sandbox_rm

echo "== the gate: herdr status + screen, failing safe =="
# The incident shape: herdr calls the pane idle (or blocked) while a menu is open.
setup; screen single-select
assert_eq "idle status + open menu => awaiting" "$(mux mux_awaiting_human)" 0
assert_eq "idle status + open menu => busy" "$(mux mux_busy)" 0
printf 'blocked\n' > "$SB/herdr/status"
assert_eq "blocked status => busy (was treated as safe)" "$(mux mux_busy)" 0
sandbox_rm

setup; screen idle-prompt
printf 'blocked\n' > "$SB/herdr/status"
assert_eq "blocked status alone => awaiting, whatever the screen says" "$(mux mux_awaiting_human)" 0
sandbox_rm

setup; screen idle-prompt
assert_eq "idle status + idle prompt => not awaiting" "$(mux mux_awaiting_human)" 1
assert_eq "idle status + idle prompt => not busy, so the watchers keep working" "$(mux mux_busy)" 1
assert_eq "idle prompt: mux_send_line types" "$(mux mux_send_line /compact)" 0
assert_eq "and the line reached the pane" "$(typed)" "RUN /compact"
sandbox_rm

setup; screen idle-prompt; : > "$SB/herdr/read-fail"
assert_eq "an unreadable pane is awaiting (fail safe)" "$(mux mux_awaiting_human)" 0
assert_eq "an unreadable pane is busy" "$(mux mux_busy)" 0
sandbox_rm

setup; printf '  \n\n' > "$SB/herdr/screen.txt"
assert_eq "a blank read is awaiting, not clear" "$(mux mux_awaiting_human)" 0
sandbox_rm

echo "== the chokepoint: every send helper refuses on an open question =="
setup; screen preview
assert_eq "mux_send_line refuses with MUX_REFUSED" "$(mux mux_send_line /handoff)" 3
assert_eq "mux_stage_text refuses" "$(mux mux_stage_text hello)" 3
assert_eq "mux_send_key refuses Enter" "$(mux mux_send_key Enter)" 3
assert_eq "mux_send_key refuses Escape (it would dismiss the question)" "$(mux mux_send_key Escape)" 3
nothing_typed "nothing reached the pane"
assert_eq "--own-prompt is the one deliberate bypass" "$(mux mux_send_key --own-prompt Escape)" 0
assert_eq "and it types" "$(typed)" "KEY Escape"
sandbox_rm

# tmux stages a line and submits it with two distinct commands. If a question
# opens after the text command, the second gate must withhold Enter.
setup; screen idle-prompt
cp "$FX/single-select.txt" "$SB/herdr/later.txt"; echo 2 > "$SB/herdr/later-from"
assert_eq "tmux re-checks a dialog that opens before Enter" "$(mux_tmux mux_send_line /compact)" 3
assert_eq "the literal text is staged but Enter is withheld" "$(typed)" "TEXT /compact"
sandbox_rm

echo "== auto-handoff-watch.sh: /compact must not answer the question =="
# Incident 1: a pending compact-request fires while a question is open.
for fx in $MENUS permission-bash; do
  setup; screen "$fx"
  : > "$STATE/$SID.compact-request"
  bash "$BIN/auto-handoff-watch.sh" "$SID" >/dev/null 2>&1
  nothing_typed "compact-request + open $fx: nothing typed"
  assert_contains "compact-request + open $fx: DEFER awaiting-human logged" \
    "$(LOG auto-handoff)" "DEFER awaiting-human"
  assert_file "compact-request + open $fx: the request survives for the retry" \
    "$STATE/$SID.compact-request"
  assert_no_file "compact-request + open $fx: no cooldown stamped" "$STATE/$SID.cooldown"
  assert_no_file "compact-request + open $fx: no abort counted" "$STATE/$SID.abort-count"
  sandbox_rm
done

# Incident 2: the cold-cache trigger at 30% sent /handoff into an open question.
setup; screen single-select
printf 'pct=30 ts=%s\n' "$(date +%s)" > "$STATE/$SID.ctx"
printf '%s\n' "$(( $(date +%s) - 1000 ))" > "$STATE/$SID.idle"
bash "$BIN/auto-handoff-watch.sh" "$SID" >/dev/null 2>&1
nothing_typed "cold-cache + open question: /handoff not typed"
assert_contains "cold-cache + open question: DEFER awaiting-human logged" \
  "$(LOG auto-handoff)" "DEFER awaiting-human"
sandbox_rm

# The question opens AFTER the pre-send gate passed, just before the keystroke.
# Reads 1-2 are the pre-send gate and busy check, 3-4 the confirmed-idle wait
# before /compact; the send helper's own re-check is read 5 and sees the menu.
# The request was consumed at TRIGGER, so refusing must re-file it — with its
# original age, not a fresh one.
setup; screen idle-prompt
cp "$FX/single-select.txt" "$SB/herdr/later.txt"; echo 5 > "$SB/herdr/later-from"
: > "$STATE/$SID.compact-request"
touch -d "@$(( $(date +%s) - 600 ))" "$STATE/$SID.compact-request"
bash "$BIN/auto-handoff-watch.sh" "$SID" >/dev/null 2>&1
nothing_typed "a question that opens mid-cycle is refused at the keystroke"
assert_contains "and logged as a deferral at the send" "$(LOG auto-handoff)" "DEFER awaiting-human (refused [/compact])"
assert_file "the consumed request is re-filed" "$STATE/$SID.compact-request"
age=$(( $(date +%s) - $(date -r "$STATE/$SID.compact-request" +%s) ))
assert_eq "with its original age" "$([ "$age" -ge 590 ] && echo old || echo "fresh (${age}s)")" old
sandbox_rm

# Re-running never escalates: the fifth deferral types exactly as much as the first.
setup; screen single-select
: > "$STATE/$SID.compact-request"
for _ in 1 2 3 4 5; do bash "$BIN/auto-handoff-watch.sh" "$SID" >/dev/null 2>&1; done
nothing_typed "five deferrals in a row: still nothing typed"
assert_no_file "and the session is never marked stuck" "$STATE/$SID.stuck"
sandbox_rm

# Control: the same trigger on an idle prompt still drives the cycle.
setup; screen idle-prompt
: > "$STATE/$SID.compact-request"
bash "$BIN/auto-handoff-watch.sh" "$SID" >/dev/null 2>&1
assert_contains "compact-request + idle prompt: /compact is typed" "$(typed)" "RUN /compact"
sandbox_rm

# A backend failure is not a successful send: it aborts the cycle and must not
# be logged or tracked as landed.
setup; screen idle-prompt; : > "$SB/herdr/run-fail"
: > "$STATE/$SID.compact-request"
bash "$BIN/auto-handoff-watch.sh" "$SID" >/dev/null 2>&1
nothing_typed "a failed backend send reaches no pane"
assert_contains "the failed send aborts the cycle" "$(LOG auto-handoff)" "ABORT send failed for [/compact]"
assert_not_contains "the failed send is never logged as SENT" "$(LOG auto-handoff)" "SENT: [/compact]"
sandbox_rm

echo "== auto-handoff-sweep.sh: the level trigger re-arms, the gate still holds =="
setup; screen multi-question
: > "$STATE/$SID.compact-request"
bash "$BIN/auto-handoff-sweep.sh" >/dev/null 2>&1
end=$(( $(date +%s) + 15 ))
until grep -q "DEFER awaiting-human" "$AUTODEV_HOME/logs/auto-handoff.log" 2>/dev/null \
      || [ "$(date +%s)" -ge "$end" ]; do sleep 0.3; done
sleep 1
nothing_typed "swept session with an open question: nothing typed"
assert_contains "the watcher it launched deferred" "$(LOG auto-handoff)" "DEFER awaiting-human"
sandbox_rm

echo "== session-resume-watch.sh (Phoenix): no /usage-credits, no Escape =="
setup
{ printf "  ⎿  You've hit your session limit\n     /usage-credits to finish what you're working on.\n\n"
  cat "$FX/single-select.txt"; } > "$SB/herdr/screen.txt"
bash "$BIN/session-resume-watch.sh" "$SID" >/dev/null 2>&1
nothing_typed "limit banner + open question: nothing typed, no Escape"
assert_contains "Phoenix logs DEFER awaiting-human" "$(LOG auto-resume)" "DEFER awaiting-human"
sandbox_rm

finish
