#!/usr/bin/env bash
# Shared harness for the autodev watcher tests.
#
# Every test runs against a throwaway AUTODEV_HOME and a COPY of bin/, so the
# real ~/agents state is never touched and the multiplexer can be stubbed out
# (no herdr/tmux required, nothing is ever typed into a real pane).

TESTS_RUN=0
TESTS_FAIL=0
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- sandbox ---------------------------------------------------------------
sandbox_new() {
  SB=$(mktemp -d "${TMPDIR:-/tmp}/autodev-test.XXXXXX")
  export SB   # stubs run in detached children and write their logs under $SB
  export AUTODEV_HOME="$SB/agents"
  export STATE="$AUTODEV_HOME/state"
  mkdir -p "$STATE" "$AUTODEV_HOME/logs" "$AUTODEV_HOME/handoffs"
  BIN="$SB/bin"
  mkdir -p "$BIN"
  cp "$SKILL_DIR"/bin/*.sh "$BIN"/
  chmod +x "$BIN"/*.sh
  # Tests drive the watcher directly; never let a stray env id leak in.
  unset CLAUDE_CODE_SESSION_ID HERDR_ENV HERDR_PANE_ID TMUX_PANE
}

sandbox_rm() { [ -n "${SB:-}" ] && rm -rf "$SB"; }

arm() { : > "$STATE/auto-handoff.armed"; }

# Register a session: context %, pane, and pane ownership.
session_new() { # $1 = sid, $2 = pct, $3 = pane id
  printf 'pct=%s ts=%s\n' "$2" "$(date +%s)" > "$STATE/$1.ctx"
  printf '%s\n' "$3" > "$STATE/$1.herdr-pane"
  printf '%s\n' "$1" > "$STATE/.paneowner-herdr-$(printf '%s' "$3" | tr ':%' '__')"
}

# --- multiplexer stub ------------------------------------------------------
# Replaces mux-lib.sh inside the sandboxed bin/. Behaviour is driven by env:
#   MUX_LIVE_PANES  space-separated pane ids that are "live"
#   MUX_BUSY        1 => pane is busy (input would queue), 0 => idle
# Every line the watcher would type is appended to $SB/sent.log instead.
stub_mux() {
  cat > "$BIN/mux-lib.sh" <<'STUB'
: "${AUTODEV_HOME:=$HOME/agents}"
: "${STATE:=$AUTODEV_HOME/state}"
MUX_BUSY_RE='esc to interrupt'
mux_owner_file(){ printf '%s/.paneowner-%s-%s' "$STATE" "$1" "$(printf '%s' "$2" | tr ':%' '__')"; }
mux_register(){ :; }
mux_init(){
  MUX=""; PANE=""
  [ -s "$STATE/$1.herdr-pane" ] || return 1
  PANE=$(cat "$STATE/$1.herdr-pane"); MUX="herdr"; [ -n "$PANE" ]
}
mux_pane_live(){ case " ${MUX_LIVE_PANES:-} " in *" $PANE "*) return 0;; *) return 1;; esac; }
mux_pane_owner(){ local o; o=$(mux_owner_file "$MUX" "$PANE"); [ -s "$o" ] && cat "$o"; }
mux_status(){ [ "${MUX_BUSY:-0}" = 1 ] && echo working || echo idle; }
mux_capture(){ :; }
mux_busy(){ [ "${MUX_BUSY:-0}" = 1 ]; }
mux_session_name(){ :; }
mux_send_line(){ printf '%s\n' "$1" >> "$SB/sent.log"; }
mux_send_key(){ :; }
STUB
  : > "$SB/sent.log"
}

# --- assertions ------------------------------------------------------------
_pass() { TESTS_RUN=$((TESTS_RUN + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
_fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAIL=$((TESTS_FAIL + 1))
  printf '  \033[31mFAIL\033[0m %s\n        %s\n' "$1" "${2:-}"
}

assert_eq()           { [ "$2" = "$3" ] && _pass "$1" || _fail "$1" "expected [$3], got [$2]"; }
assert_contains()     { case "$2" in *"$3"*) _pass "$1";; *) _fail "$1" "expected to contain [$3], got [$2]";; esac; }
assert_not_contains() { case "$2" in *"$3"*) _fail "$1" "must NOT contain [$3], got [$2]";; *) _pass "$1";; esac; }
# For config files, assert on a WHOLE LINE, never a substring. The generated
# systemd unit carries comments explaining its own directives, so a substring
# match for "KillMode=process" also matches the prose describing it and passes
# with the directive deleted — a guard that guards nothing.
assert_line()       { printf '%s\n' "$2" | grep -qxF -- "$3" && _pass "$1" || _fail "$1" "no line exactly [$3]"; }
assert_line_start() { printf '%s\n' "$2" | grep -qF -- "$3" && printf '%s\n' "$2" | grep -q "^$(printf '%s' "$3" | sed 's/[][\.*^$\/]/\\&/g')" && _pass "$1" || _fail "$1" "no line starting [$3]"; }

assert_file()         { [ -f "$2" ] && _pass "$1" || _fail "$1" "missing file: $2"; }
assert_no_file()      { [ -f "$2" ] && _fail "$1" "file should not exist: $2" || _pass "$1"; }

# Replace the watcher with a recorder, so sweeper tests observe which sessions
# would be driven without running a real cycle.
stub_watcher() {
  cat > "$BIN/auto-handoff-watch.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$SB/launched.log"
STUB
  chmod +x "$BIN/auto-handoff-watch.sh"
  : > "$SB/launched.log"
}

# The sweeper detaches its children, so poll rather than assume.
wait_for_line() { # $1 = needle, $2 = timeout (default 8s)
  local end=$(( $(date +%s) + ${2:-8} ))
  while [ "$(date +%s)" -lt "$end" ]; do
    grep -qxF "$1" "$SB/launched.log" 2>/dev/null && return 0
    sleep 0.3
  done
  return 1
}

assert_launched()     { wait_for_line "$2" && _pass "$1" || _fail "$1" "watcher was never launched for $2"; }
assert_not_launched() { sleep 2; grep -qxF "$2" "$SB/launched.log" 2>/dev/null && _fail "$1" "watcher was launched for $2" || _pass "$1"; }

finish() {
  printf '\n%s: %d run, %d failed\n' "${0##*/}" "$TESTS_RUN" "$TESTS_FAIL"
  [ "$TESTS_FAIL" -eq 0 ]
}
