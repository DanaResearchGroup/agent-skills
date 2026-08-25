#!/usr/bin/env bash
# Shared harness for the autodev watcher tests.
#
# Every test runs against a throwaway AUTODEV_HOME and a COPY of bin/, so the
# real ~/agents state is never touched and the multiplexer can be stubbed out
# (no herdr/tmux required, nothing is ever typed into a real pane).

TESTS_RUN=0
TESTS_FAIL=0
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# See the guard block below (near the assertion helpers) for why this file
# exists: it is the only channel out of a bash command_not_found_handle,
# which always runs in a subshell.
HARNESS_FAULTS="$(mktemp "${TMPDIR:-/tmp}/autodev-harness-faults.XXXXXX")"

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
  # The prompt-cache clock lives in the repo-root status-line lib, outside
  # autodev/bin, so the sandboxed copy cannot resolve it by relative path. Point
  # the watcher at the REAL lib through its test seam — the clock the status line
  # uses is then the clock under test, which is the whole point of sharing it.
  export CC_STATUSLINE_LIB="$SKILL_DIR/../bin/lib/cc-statusline-lib.sh"
  # Tests drive the watcher directly; never let a stray env id leak in.
  unset CLAUDE_CODE_SESSION_ID HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID TMUX_PANE
}

sandbox_rm() { [ -n "${SB:-}" ] && rm -rf "$SB"; }

arm() { : > "$STATE/auto-handoff.armed"; }

# Register a session: context %, pane, and pane ownership.
session_new() { # $1 = sid, $2 = pct, $3 = pane id
  printf 'pct=%s ts=%s\n' "$2" "$(date +%s)" > "$STATE/$1.ctx"
  printf '%s\n' "$3" > "$STATE/$1.herdr-pane"
  printf '%s\n' "$1" > "$STATE/.paneowner-herdr-$(printf '%s' "$3" | tr ':%' '__')"
}

# Give a session a tab with a starting label. The label lives in a file the mux
# stub reads and writes, so a test can inspect it, rename it behind the watcher's
# back, or delete it to model the tab being closed.
session_tab() { # $1 = sid, $2 = tab id, $3 = initial label
  printf '%s\n' "$2" > "$STATE/$1.herdr-tab"
  printf '%s' "$3" > "$SB/tab-$2"
}
tab_label() { cat "$SB/tab-$1" 2>/dev/null; }

# A transcript whose newest entry is <age> seconds old — i.e. the session last
# hit the API that long ago, which is what the cache clock reads.
#
# Pass $3 whenever the test also derives an expected deadline from the clock:
# reading `date` a second time can straddle a second boundary, leaving the
# expectation one second ahead of what the code under test computed.
transcript_aged() { # $1 = path, $2 = age in seconds, $3 = "now" epoch (default: read the clock)
  local now=${3:-$(date +%s)}
  printf '{"type":"assistant","isSidechain":false,"timestamp":"%s"}\n' \
    "$(date -u -d "@$(( now - $2 ))" +%Y-%m-%dT%H:%M:%S.000Z)" > "$1"
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
  MUX=""; PANE=""; TAB=""
  [ -s "$STATE/$1.herdr-tab" ] && TAB=$(cat "$STATE/$1.herdr-tab")
  [ -s "$STATE/$1.herdr-pane" ] || return 1
  PANE=$(cat "$STATE/$1.herdr-pane"); MUX="herdr"; [ -n "$PANE" ]
}
# Tab labels live in $SB/tab-<id>. A missing file means the tab is gone, which is
# how the real herdr backend reports a closed tab: the query simply fails.
mux_tab_label(){ [ -n "${TAB:-}" ] && [ -f "$SB/tab-$TAB" ] && cat "$SB/tab-$TAB"; }
mux_tab_rename(){
  [ -n "${TAB:-}" ] && [ -f "$SB/tab-$TAB" ] || return 1
  printf '%s' "$1" > "$SB/tab-$TAB"
  printf '%s\n' "$1" >> "$SB/renames.log"
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
  : > "$SB/renames.log"
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

# An unknown command is a HARNESS failure, not a silence: a test that calls a
# helper this lib never defined prints "command not found" to stderr, and its
# assertions count as neither pass nor fail -- the suite reports green over a
# property nothing checked. (That is not hypothetical; it is why the sibling
# private repo grew this guard.)
#
# The handler runs in a SUBSHELL (probed, bash 5.2.21), so a counter it
# increments is discarded when the subshell exits. A subshell can still make a
# filesystem effect, so the fault is recorded as a file and `finish` fails on it.
command_not_found_handle() {
  _fail "harness: unknown command '$1'" \
    "a test called a helper this harness does not define; the assertions in that section did not run"
  printf '%s\n' "$1" >>"$HARNESS_FAULTS"
  return 127
}

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
  # The guard above runs in a SUBSHELL, so its fail never reached these counters
  # -- this file is the only channel out of it.
  if [ -s "$HARNESS_FAULTS" ]; then
    while IFS= read -r _missing; do
      TESTS_RUN=$((TESTS_RUN + 1))
      TESTS_FAIL=$((TESTS_FAIL + 1))
    done <"$HARNESS_FAULTS"
  fi
  rm -f "$HARNESS_FAULTS"

  printf '\n%s: %d run, %d failed\n' "${0##*/}" "$TESTS_RUN" "$TESTS_FAIL"
  [ "$TESTS_FAIL" -eq 0 ]
}
