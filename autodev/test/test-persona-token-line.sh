#!/usr/bin/env bash
# A Persona seat hands off at a fixed token count, not at 35%.
#
# A Persona is an always-on Claude seat working under ~/Persona/<name>/. On a
# 1M-token window 35% is 350k, far past the 200k a Persona seat must hand off at.
# threshold-lib.sh gives such a session a 200,000-token line (overridable by
# `compact_at_tokens` in <root>/<name>/PI/model.toml); every other session keeps
# the 35% line. This file pins:
#   - the token line itself (default, override, malformed/unreadable fallback),
#   - the status line recording tok=/win= between pct= and ts=, and the workdir,
#   - the watcher, the sweep and the Stop-hook fallback all applying it,
#   - the 35% rule surviving for a 200k-window seat and for a .ctx with no tok=,
#   - the token line (20% of 1M) firing before the cold-cache branch (25%),
#   - the busy-deferral re-check under the cycle lock seeing a reading that
#     moved while the watcher waited for the lock.

. "$(dirname "$0")/lib.sh"

SID=44444444-4444-4444-4444-444444444444
export SID
export AUTODEV_SETTLE=0 AUTODEV_POLL=1

LOGF() { echo "$AUTODEV_HOME/logs/auto-handoff.log"; }
log_contains()     { grep -qF -- "$2" "$(LOGF)" 2>/dev/null && _pass "$1" || _fail "$1" "log does not contain [$2]: $(cat "$(LOGF)" 2>/dev/null)"; }
log_not_contains() { grep -qF -- "$2" "$(LOGF)" 2>/dev/null && _fail "$1" "log unexpectedly contains [$2]: $(cat "$(LOGF)" 2>/dev/null)" || _pass "$1"; }

# A Persona root inside the sandbox; the real ~/Persona is never read.
persona_env() {
  export AUTODEV_PERSONA_ROOT="$SB/Persona"
  mkdir -p "$AUTODEV_PERSONA_ROOT/method/PI" "$SB/elsewhere"
}

# $1 = workdir (persona|other|<path>), $2 = pct, $3 = tok (or -), $4 = win (or -)
ctx_set() {
  local wd=$1
  case "$wd" in
    persona) wd="$AUTODEV_PERSONA_ROOT/method" ;;
    other) wd="$SB/elsewhere" ;;
  esac
  printf '%s\n' "$wd" > "$STATE/$SID.workdir"
  if [ "$3" = - ]; then
    printf 'pct=%s ts=%s\n' "$2" "$(date +%s)" > "$STATE/$SID.ctx"
  else
    printf 'pct=%s tok=%s win=%s ts=%s\n' "$2" "$3" "$4" "$(date +%s)" > "$STATE/$SID.ctx"
  fi
}

setup_watch() {
  sandbox_new; stub_mux; persona_env
  session_new "$SID" 0 "w1:p1"
  export MUX_LIVE_PANES="w1:p1" MUX_BUSY=0
}
setup_sweep() { setup_watch; stub_watcher; arm; }
run_watch() { bash "$BIN/auto-handoff-watch.sh" "$SID" >/dev/null 2>&1; }
sweep()     { bash "$BIN/auto-handoff-sweep.sh" >/dev/null 2>&1; }
line_for()  ( . "$BIN/threshold-lib.sh"; autodev_token_line "$1" )

echo "== threshold-lib.sh: the token line =="
sandbox_new; persona_env
P=$AUTODEV_PERSONA_ROOT
assert_eq "Persona seat, no model.toml: 200000 from code" "$(line_for "$P/method")" 200000
assert_eq "any depth under the Persona folder" "$(line_for "$P/method/aide/x y/z")" 200000
assert_eq "non-Persona session has no token line" "$(line_for "$SB/elsewhere")" ""
assert_eq "the Persona root itself is not a seat" "$(line_for "$P")" ""
assert_eq "a sibling folder sharing the prefix is not a seat" "$(line_for "${P}2/method")" ""
assert_eq "no working folder: no token line" "$(line_for "")" ""
printf 'model = "x"\ncompact_at_tokens = 300_000  # owner 2026-11-16\n' > "$P/method/PI/model.toml"
assert_eq "compact_at_tokens overrides the default" "$(line_for "$P/method")" 300000
for bad in '"abc"' '0' '-5' '"300000"' '' '1e6' '99999999999999'; do
  printf 'compact_at_tokens = %s\n' "$bad" > "$P/method/PI/model.toml"
  assert_eq "malformed compact_at_tokens [$bad] falls back to 200000" "$(line_for "$P/method")" 200000
done
printf '[other]\ncompact_at_tokens = 300000\n' > "$P/method/PI/model.toml"
assert_eq "a key inside a [table] is not the top-level setting" "$(line_for "$P/method")" 200000
printf 'compact_at_tokens = 300000\n' > "$P/method/PI/model.toml"
chmod 000 "$P/method/PI/model.toml"
if [ -r "$P/method/PI/model.toml" ]; then
  _pass "unreadable model.toml (skipped: running as a user who can read mode 000)"
else
  assert_eq "unreadable model.toml falls back to 200000" "$(line_for "$P/method")" 200000
fi
chmod 600 "$P/method/PI/model.toml"
sandbox_rm

echo "== cc-statusline.sh records tokens, window and working folder =="
sandbox_new; persona_env
render() { printf '%s' "$1" | bash "$BIN/cc-statusline.sh" >/dev/null 2>&1; }
render "$(jq -nc --arg sid "$SID" --arg wd "$AUTODEV_PERSONA_ROOT/method" \
  '{session_id:$sid,context_window:{used_percentage:20,total_input_tokens:9999999,context_window_size:1000000,
    current_usage:{input_tokens:1000,cache_creation_input_tokens:9000,cache_read_input_tokens:190000}},
    workspace:{project_dir:$wd,current_dir:"/somewhere/else"}}')"
ctx=$(cat "$STATE/$SID.ctx")
assert_line_start "pct= stays first and unchanged" "$ctx" "pct=20 tok=200000 win=1000000 ts="
assert_contains "token count is current_usage, not cumulative total_input_tokens" "$ctx" " tok=200000 "
case "$ctx" in *' ts='[0-9]*) ts_tail=${ctx##* ts=} ;; *) ts_tail="" ;; esac
case "$ts_tail" in ''|*[!0-9]*) _fail "ts= stays the last field" "$ctx" ;; *) _pass "ts= stays the last field" ;; esac
assert_eq "working folder is the session's project_dir" "$(cat "$STATE/$SID.workdir")" "$AUTODEV_PERSONA_ROOT/method"
render "$(jq -nc --arg sid "$SID" '{session_id:$sid,context_window:{used_percentage:20.5,context_window_size:1000000}}')"
assert_line_start "no current_usage: tok from used_percentage x size" "$(cat "$STATE/$SID.ctx")" "pct=20.5 tok=205000 win=1000000 ts="
render "$(jq -nc --arg sid "$SID" '{session_id:$sid,context_window:{used_percentage:20}}')"
assert_not_contains "no window size: no tok= field" "$(cat "$STATE/$SID.ctx")" "tok="
sandbox_rm

echo "== auto-handoff-watch.sh: the gate test =="
# GATE: a Persona seat at 200,000 tokens of a 1M window hands off.
setup_watch
ctx_set persona 20 200000 1000000
run_watch
log_contains "Persona seat at 200k of 1M triggers a handoff" "TRIGGER (threshold)"
sandbox_rm

# GATE: the same reading in an ordinary session does not.
setup_watch
ctx_set other 20 200000 1000000
run_watch
log_not_contains "non-Persona session at 200k of 1M does not hand off" "TRIGGER"
sandbox_rm

setup_watch
ctx_set persona 19.99 199999 1000000
run_watch
log_not_contains "Persona seat one token below the line does not hand off" "TRIGGER"
sandbox_rm

setup_watch
printf 'compact_at_tokens = 300000\n' > "$AUTODEV_PERSONA_ROOT/method/PI/model.toml"
ctx_set persona 25 250000 1000000
run_watch
log_not_contains "compact_at_tokens = 300000 holds a seat at 250k" "TRIGGER"
sandbox_rm

echo "== auto-handoff-watch.sh: where the 35% rule still governs =="
# A 200k-window Persona seat: the window is not larger than the line, so 35%.
setup_watch
ctx_set persona 34 68000 200000
run_watch
log_not_contains "200k-window Persona seat at 34% keeps waiting for 35%" "TRIGGER"
sandbox_rm
setup_watch
ctx_set persona 36 72000 200000
run_watch
log_contains "200k-window Persona seat past 35% hands off by percent" "TRIGGER (threshold)"
sandbox_rm

# A .ctx with no tok= (older status line, Codex hook) falls back to percent.
setup_watch
ctx_set persona 20 - -
run_watch
log_not_contains "Persona .ctx without tok= at 20% does not hand off" "TRIGGER"
sandbox_rm
setup_watch
ctx_set persona 40 - -
run_watch
log_contains "Persona .ctx without tok= past 35% hands off by percent" "TRIGGER (threshold)"
sandbox_rm

echo "== the token line comes before the cold-cache branch =="
# COLD_MIN stays 25. On a 1M window the 200k line is 20%, so a Persona seat
# hands off on the token line while the cold branch still cannot fire.
setup_watch
ctx_set persona 20 200000 1000000
printf '%s\n' "$(( $(date +%s) - 900 ))" > "$STATE/$SID.idle"
run_watch
log_contains "idle Persona seat at 20% fires on the token line" "TRIGGER (threshold)"
log_not_contains "not on the cold-cache branch" "TRIGGER (cold-cache)"
sandbox_rm

echo "== auto-handoff-sweep.sh: a parked seat =="
setup_sweep
ctx_set persona 20 200000 1000000
sweep
assert_launched "parked Persona seat past its token line is driven" "$SID"
sandbox_rm
setup_sweep
ctx_set other 20 200000 1000000
sweep
assert_not_launched "parked non-Persona session at 200k of 1M is left alone" "$SID"
sandbox_rm
setup_sweep
ctx_set persona 20 200000 1000000
: > "$STATE/disable-auto-compact"
sweep
assert_not_launched "the kill switch still beats the token line" "$SID"
sandbox_rm

echo "== cc-stop-hook.sh: the in-session fallback =="
stop_out() {
  jq -nc --arg sid "$SID" '{session_id:$sid,hook_event_name:"Stop",stop_hook_active:false}' |
    AUTODEV_NO_WATCHERS=1 bash "$BIN/cc-stop-hook.sh"
}
setup_watch; arm
export MUX_LIVE_PANES=""          # the watcher cannot reach this pane
ctx_set persona 20 200000 1000000
out=$(stop_out)
assert_contains "unreachable Persona seat at 200k is told to hand off" "$out" '"decision":"block"'
sandbox_rm
setup_watch; arm
export MUX_LIVE_PANES=""
ctx_set other 20 200000 1000000
out=$(stop_out)
assert_eq "unreachable non-Persona session at 200k of 1M is not blocked" "$out" ""
sandbox_rm

echo "== busy deferrals: the below-line check is repeated under the cycle lock =="
# Wrap the lock so that publishing it moves the reading past the line, as a
# status-line write landing while the watcher waits for the lock would.
lock_flip_shim() {
  cat >> "$BIN/lock-lib.sh" <<'SHIM'
eval "orig_$(declare -f autodev_lock_publish)"
autodev_lock_publish() {
  if [ -f "$SB/flip-on-lock" ]; then
    rm -f "$SB/flip-on-lock"
    printf 'pct=25 tok=250000 win=1000000 ts=1\n' > "$STATE/$SID.ctx"
  fi
  orig_autodev_lock_publish "$@"
}
SHIM
}
setup_watch
lock_flip_shim
export MUX_LIVE_PANES=""          # stop before any cycle: only the deferral clear runs
ctx_set persona 15 150000 1000000
printf '2\n' > "$STATE/$SID.busy-deferrals"
run_watch
assert_no_file "control: below the token line clears busy deferrals" "$STATE/$SID.busy-deferrals"
sandbox_rm
setup_watch
lock_flip_shim
export MUX_LIVE_PANES=""
ctx_set persona 15 150000 1000000
printf '2\n' > "$STATE/$SID.busy-deferrals"
: > "$SB/flip-on-lock"
run_watch
assert_no_file "the shim fired while the lock was taken" "$SB/flip-on-lock"
assert_file "reading past the line under the lock keeps busy deferrals" "$STATE/$SID.busy-deferrals"
sandbox_rm

finish
