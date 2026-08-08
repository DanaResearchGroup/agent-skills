#!/usr/bin/env bash
# Bug: the status line reports the prompt cache as "hot" long after it has gone
# cold, and only corrects itself when you send a prompt — by which time the
# information is worthless.
#
# Root cause: Claude Code invokes the statusLine command only on conversation
# updates. Measured directly on a live session: across 120 s of idle, the state
# file the status line rewrites on every invocation was never touched — zero
# renders. So the status line is a photograph. Anything in it that decays with
# wall-clock time is a lie the instant the session goes idle, and the countdown
# and expiry states can never appear at all, because idle is precisely when
# nothing redraws.
#
# The fix is two-part, and this file guards both halves:
#   1. The status-line segment stops decaying. It prints the absolute wall-clock
#      time the cache lapses, which stays true however stale the render is.
#   2. The live countdown moves to a surface that repaints on its own — the
#      multiplexer tab label — driven by a detached watcher, since no process
#      inside Claude Code gets to run while it is idle.

. "$(dirname "$0")/lib.sh"

SID=44444444-4444-4444-4444-444444444444
TAB=w1:t7

setup() {
  sandbox_new
  stub_mux
  TPATH="$SB/transcript.jsonl"
  session_new "$SID" 12 "w1:p1"
  session_tab "$SID" "$TAB" "proj"
  export CC_CACHE_NAP_MAX=1     # keep the lazy poll from outlasting the test
}

# Run the watcher in the background; $WPID is its pid.
watch_bg() { bash "$BIN/cache-warm-watch.sh" "$SID" "$TPATH" >/dev/null 2>&1 & WPID=$!; }
watch_stop() { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }

# Poll until the tab label matches, rather than sleeping a guessed interval.
wait_label() { # $1 = expected label, $2 = timeout (default 8s)
  local end=$(( $(date +%s) + ${2:-8} ))
  while [ "$(date +%s)" -lt "$end" ]; do
    [ "$(tab_label "$TAB")" = "$1" ] && return 0
    sleep 0.2
  done
  return 1
}
wait_label_matching() { # $1 = grep -E pattern, $2 = timeout
  local end=$(( $(date +%s) + ${2:-8} ))
  while [ "$(date +%s)" -lt "$end" ]; do
    printf '%s' "$(tab_label "$TAB")" | grep -Eq "$1" && return 0
    sleep 0.2
  done
  return 1
}
wait_exit() { # $1 = pid, $2 = timeout
  local end=$(( $(date +%s) + ${2:-8} ))
  while [ "$(date +%s)" -lt "$end" ]; do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.2
  done
  return 1
}
assert_label()   { wait_label "$2" "${3:-8}" && _pass "$1" || _fail "$1" "label is [$(tab_label "$TAB")], wanted [$2]"; }
assert_matches() { wait_label_matching "$2" "${3:-8}" && _pass "$1" || _fail "$1" "label is [$(tab_label "$TAB")], wanted /$2/"; }
assert_exited()  { wait_exit "$2" "${3:-8}" && _pass "$1" || _fail "$1" "watcher $2 is still running"; }

echo "== the tab label carries what the status line cannot =="

# Plenty of TTL left: the badge must stay out of the way entirely.
setup
transcript_aged "$TPATH" 0
CC_CACHE_TTL=300 CC_CACHE_WARN=30 watch_bg
sleep 2
assert_eq "quiet while the cache is comfortably warm" "$(tab_label "$TAB")" "proj"
watch_stop; sandbox_rm

# Inside the warning window: a live countdown appears WITHOUT the session doing
# anything. This is the case the status line structurally cannot serve.
setup
transcript_aged "$TPATH" 275          # 25 s left of a 300 s window
CC_CACHE_TTL=300 CC_CACHE_WARN=30 watch_bg
assert_matches "countdown appears while the session sits idle" '^proj ⌛[0-9]+s$'
watch_stop; sandbox_rm

# ...and it counts DOWN on its own, which is the whole point.
setup
transcript_aged "$TPATH" 275
CC_CACHE_TTL=300 CC_CACHE_WARN=30 watch_bg
wait_label_matching '^proj ⌛[0-9]+s$' 8
first=$(tab_label "$TAB")
sleep 3
second=$(tab_label "$TAB")
[ -n "$first" ] && [ "$first" != "$second" ] \
  && _pass "the countdown advances with no conversation update" \
  || _fail "the countdown advances with no conversation update" "stuck at [$first]"
watch_stop; sandbox_rm

# Past the TTL: say so plainly.
setup
transcript_aged "$TPATH" 400          # already 100 s past a 300 s window
CC_CACHE_TTL=300 CC_CACHE_WARN=30 watch_bg
assert_label "lapsed cache is marked cold" "proj •cold"
watch_stop; sandbox_rm

echo "== it stands down the moment the cache is refreshed =="

setup
transcript_aged "$TPATH" 400
CC_CACHE_TTL=300 CC_CACHE_WARN=30 watch_bg
wait_label "proj •cold" 8
transcript_aged "$TPATH" 0            # a new API call: cache is hot again
assert_label "badge cleared once a fresh entry appears" "proj"
assert_exited "watcher stands down after clearing" "$WPID"
sandbox_rm

# The user renaming their tab mid-countdown must survive. The watcher reads the
# LIVE label every time it acts and only strips its own suffix, so it can never
# restore a stale name it memorised earlier.
setup
transcript_aged "$TPATH" 400
CC_CACHE_TTL=300 CC_CACHE_WARN=30 watch_bg
wait_label "proj •cold" 8
printf '%s' "renamed •cold" > "$SB/tab-$TAB"
transcript_aged "$TPATH" 0
assert_label "a rename made behind the watcher's back is preserved" "renamed"
sandbox_rm

# A suffix left behind by a watcher that was killed must be cleaned up by the
# next turn's watcher, not inherited as if it were part of the name.
setup
transcript_aged "$TPATH" 0
printf '%s' "proj ⌛7s" > "$SB/tab-$TAB"   # leftover from a dead predecessor
CC_CACHE_TTL=300 CC_CACHE_WARN=30 watch_bg
assert_label "a dead watcher's leftover badge is reconciled away" "proj"
watch_stop; sandbox_rm

echo "== a new turn drops the badge immediately, not one poll later =="

# Once cold the watcher polls lazily (no inotify, and there can be dozens of idle
# sessions), so the badge would otherwise still be sitting there while you are
# already typing. The status line runs ONLY on a conversation update, which makes
# its execution proof that the cache was just refreshed — so it does the clearing.
setup
transcript_aged "$TPATH" 400
CC_CACHE_TTL=300 CC_CACHE_WARN=30 CC_CACHE_NAP_MAX=600 watch_bg
wait_label "proj •cold" 8
assert_file "a live badge is advertised to the status line" "$STATE/$SID.cachewarm-badge"

payload=$(printf '{"session_id":"%s","transcript_path":"%s","model":{"display_name":"Opus"},"context_window":{"used_percentage":12.3,"total_input_tokens":1234},"workspace":{"current_dir":"%s"}}' "$SID" "$TPATH" "$SB")
printf '%s' "$payload" | bash "$BIN/cc-statusline.sh" >/dev/null 2>&1
assert_label "one status-line render clears the stale badge" "proj"
assert_no_file "and the advertisement is withdrawn" "$STATE/$SID.cachewarm-badge"
watch_stop; sandbox_rm

# The status line must not pay for this on every render — only when there is
# something to clear.
setup
transcript_aged "$TPATH" 0
payload=$(printf '{"session_id":"%s","transcript_path":"%s","model":{"display_name":"Opus"},"context_window":{"used_percentage":12.3,"total_input_tokens":1234},"workspace":{"current_dir":"%s"}}' "$SID" "$TPATH" "$SB")
printf '%s' "$payload" | bash "$BIN/cc-statusline.sh" >/dev/null 2>&1
sleep 1
assert_eq "no badge, no rename traffic" "$(cat "$SB/renames.log")" ""
sandbox_rm

# --clear works even with the kill switch on: switching the feature off must tidy
# up after itself rather than freezing a badge onto the tab.
setup
transcript_aged "$TPATH" 400
CC_CACHE_TTL=300 CC_CACHE_WARN=30 CC_CACHE_NAP_MAX=600 watch_bg
wait_label "proj •cold" 8
watch_stop
: > "$STATE/disable-cache-badge"
bash "$BIN/cache-warm-watch.sh" --clear "$SID"
assert_eq "--clear tidies up even when badging is disabled" "$(tab_label "$TAB")" "proj"
sandbox_rm

echo "== two watchers never fight over one label =="

setup
transcript_aged "$TPATH" 400
CC_CACHE_TTL=300 CC_CACHE_WARN=30 watch_bg
wait_label "proj •cold" 8
printf '%s\n' "999999" > "$STATE/$SID.cachewarm-owner"   # a later turn took over
assert_exited "a superseded watcher exits" "$WPID"
assert_eq "and leaves the label to its successor" "$(tab_label "$TAB")" "proj •cold"
sandbox_rm

echo "== it stays out of the way when it should =="

# Kill switch, set before launch.
setup
transcript_aged "$TPATH" 400
: > "$STATE/disable-cache-badge"
CC_CACHE_TTL=300 CC_CACHE_WARN=30 watch_bg
wait_exit "$WPID" 8
assert_eq "kill switch stops the watcher dead" "$(tab_label "$TAB")" "proj"
sandbox_rm

# Kill switch, thrown while a badge is showing: it must clean up after itself.
setup
transcript_aged "$TPATH" 400
CC_CACHE_TTL=300 CC_CACHE_WARN=30 watch_bg
wait_label "proj •cold" 8
: > "$STATE/disable-cache-badge"
assert_label "kill switch clears a badge already on screen" "proj"
assert_exited "and the watcher exits" "$WPID"
sandbox_rm

# No tab registered (a backend with no tab surface): nothing may be renamed.
setup
rm -f "$STATE/$SID.herdr-tab"
transcript_aged "$TPATH" 400
CC_CACHE_TTL=300 CC_CACHE_WARN=30 watch_bg
wait_exit "$WPID" 8
assert_eq "a session with no registered tab renames nothing" "$(cat "$SB/renames.log")" ""
sandbox_rm

# Tab closed underneath the watcher: give up, do not spin.
setup
transcript_aged "$TPATH" 400
CC_CACHE_TTL=300 CC_CACHE_WARN=30 watch_bg
wait_label "proj •cold" 8
rm -f "$SB/tab-$TAB"
transcript_aged "$TPATH" 200          # forces a reconcile attempt against a dead tab
assert_exited "watcher gives up when its tab is closed" "$WPID"
sandbox_rm

echo "== the status-line half prints a deadline, not a decaying state =="

# Both shipped status lines must render the absolute lapse time, so that a render
# frozen on screen for ten minutes is still telling the truth.
setup
now=$(date +%s)                       # one clock read: see transcript_aged
transcript_aged "$TPATH" 0 "$now"
expected=$(date -d "@$(( now + 300 ))" +%H:%M:%S)
payload=$(printf '{"session_id":"%s","transcript_path":"%s","model":{"display_name":"Opus"},"context_window":{"used_percentage":12.3,"total_input_tokens":1234},"workspace":{"current_dir":"%s"}}' "$SID" "$TPATH" "$SB")

out=$(printf '%s' "$payload" | CC_CACHE_TTL=300 bash "$SKILL_DIR/../bin/cc-statusline.sh")
assert_contains "group status line prints the lapse time" "$out" "cache⌛$expected"
assert_not_contains "group status line no longer claims a decaying state" "$out" "cache:hot"

out=$(printf '%s' "$payload" | CC_CACHE_TTL=300 bash "$SKILL_DIR/bin/cc-statusline.sh")
assert_contains "autodev status line prints the lapse time" "$out" "cache⌛$expected"
assert_not_contains "autodev status line no longer claims a decaying state" "$out" "cache:hot"

# No transcript, no claim.
payload=$(printf '{"session_id":"%s","model":{"display_name":"Opus"},"context_window":{"used_percentage":12.3,"total_input_tokens":1234},"workspace":{"current_dir":"%s"}}' "$SID" "$SB")
out=$(printf '%s' "$payload" | bash "$SKILL_DIR/../bin/cc-statusline.sh")
assert_not_contains "no transcript means no cache claim at all" "$out" "cache"
sandbox_rm

# A subagent turn rides a different prompt prefix, so it does not refresh this
# session's cache and must not be read as activity.
setup
now=$(date +%s)                       # one clock read: see transcript_aged
transcript_aged "$TPATH" 200 "$now"
printf '{"type":"assistant","isSidechain":true,"timestamp":"%s"}\n' \
  "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%S.000Z)" >> "$TPATH"
expected=$(date -d "@$(( now - 200 + 300 ))" +%H:%M:%S)
payload=$(printf '{"session_id":"%s","transcript_path":"%s","model":{"display_name":"Opus"},"context_window":{"used_percentage":12.3,"total_input_tokens":1234},"workspace":{"current_dir":"%s"}}' "$SID" "$TPATH" "$SB")
out=$(printf '%s' "$payload" | CC_CACHE_TTL=300 bash "$SKILL_DIR/../bin/cc-statusline.sh")
assert_contains "a subagent turn does not count as refreshing this cache" "$out" "cache⌛$expected"
sandbox_rm

echo "== the watcher is reachable as an executable =="

# Both call sites invoke it as a program: the Stop hook via setsid, and the status
# line behind an -x guard that would SILENTLY skip clearing if the bit were lost.
[ -x "$SKILL_DIR/bin/cache-warm-watch.sh" ] \
  && _pass "cache-warm-watch.sh is executable in the repo" \
  || _fail "cache-warm-watch.sh is executable in the repo" "mode is $(stat -c %A "$SKILL_DIR/bin/cache-warm-watch.sh" 2>/dev/null)"
assert_contains "install.sh chmods it alongside the other engines" \
  "$(grep -E '^for f in ' "$SKILL_DIR/bin/install.sh")" "cache-warm-watch.sh"
assert_contains "the Stop hook launches it" \
  "$(cat "$SKILL_DIR/bin/cc-stop-hook.sh")" "cache-warm-watch.sh"

finish
