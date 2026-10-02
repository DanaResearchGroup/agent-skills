#!/usr/bin/env bash
# PM deferred-user-questions badge in autodev/bin/cc-statusline.sh. It reads ONLY
# <pm-root>/.pm/state/user-questions.json; every failure must leave the rest of the
# line intact, and outside a PM root the output must carry no trace of the badge.

. "$(dirname "$0")/lib.sh"

SID=55555555-5555-5555-5555-555555555555
sandbox_new
unset PM_ROOT

PM="$SB/pm"; mkdir -p "$PM/.pm/state" "$PM/sub/deep" "$SB/plain"
printf '{}' > "$PM/.pm/config.json"
: > "$PM/.pm/events.log"
CACHE="$PM/.pm/state/user-questions.json"

render() { # $1 = cwd
  printf '{"session_id":"%s","model":{"display_name":"Opus"},"context_window":{"used_percentage":12.3,"total_input_tokens":1234},"workspace":{"current_dir":"%s"}}' "$SID" "$1" \
    | bash "$BIN/cc-statusline.sh"
}
cache() { # $1 = count, $2 = blocked
  printf '{"schema":"pm-user-questions/1","count":%s,"blocked":%s,"questions":[]}' "$1" "$2" > "$CACHE"
  touch -d '1 minute ago' "$PM/.pm/events.log"   # cache is newer than the log
}
AMBER=$'\033[1;30;43m'; RED=$'\033[1;97;41m'; DIM_AMBER=$'\033[2;30;43m'; DIM_RED=$'\033[2;97;41m'

out=$(render "$SB/plain")
assert_not_contains "no PM root: no badge" "$out" "❓"
assert_contains "no PM root: line still renders" "$out" "Opus 1.2k"

cache 0 false
assert_not_contains "count 0: nothing" "$(render "$PM")" "❓"

cache 3 false; out=$(render "$PM")
assert_contains "count 3: text" "$out" "❓ 3 Qs"
assert_contains "count 3: amber" "$out" "$AMBER"
assert_not_contains "count 3 unblocked: not waiting" "$out" "WAITING"
assert_contains "count 3: rest of line intact" "$out" "Opus 1.2k"

cache 2 true; out=$(render "$PM")
assert_contains "blocked: red waiting text" "$out" "❓ 2 Qs — WAITING ON YOU"
assert_contains "blocked: red" "$out" "$RED"

rm -f "$CACHE"; out=$(render "$PM")
assert_contains "missing cache: ?" "$out" "❓ ?"
assert_contains "missing cache: rest of line intact" "$out" "Opus 1.2k"

printf '{not json' > "$CACHE"; out=$(render "$PM")
assert_contains "corrupt cache: ?" "$out" "❓ ?"
assert_contains "corrupt cache: rest of line intact" "$out" "Opus 1.2k"

printf '{"schema":"pm-user-questions/1","count":"x","blocked":false}' > "$CACHE"
assert_contains "non-numeric count: ?" "$(render "$PM")" "❓ ?"

cache 3 false; touch "$PM/.pm/events.log"   # log newer than cache
out=$(render "$PM")
assert_contains "stale cache: dimmed amber" "$out" "$DIM_AMBER"
assert_contains "stale cache: still counts" "$out" "❓ 3 Qs"
cache 2 true; touch "$PM/.pm/events.log"
assert_contains "stale blocked cache: dimmed red" "$(render "$PM")" "$DIM_RED"

cache 3 false
assert_contains "nested subdirectory cwd finds the root" "$(render "$PM/sub/deep")" "❓ 3 Qs"

assert_contains "PM_ROOT honoured from outside the tree" "$(PM_ROOT="$PM" render "$SB/plain")" "❓ 3 Qs"

cache 0 true; out=$(render "$PM")
assert_contains "count 0 blocked: waiting text" "$out" "❓ 0 Qs — WAITING ON YOU"
assert_contains "count 0 blocked: red" "$out" "$RED"

cache 0 false; touch "$PM/.pm/events.log"
out=$(render "$PM")
assert_contains "stale zero: dimmed unknown" "$out" "${DIM_AMBER} ❓ ? "

printf '{"schema":"pm-user-questions/1","count":3,"questions":[]}' > "$CACHE"; touch -d '1 minute ago' "$PM/.pm/events.log"
assert_contains "missing blocked: ?" "$(render "$PM")" "❓ ?"
printf '{"schema":"pm-user-questions/1","count":3,"blocked":{"a":1}}' > "$CACHE"
assert_contains "object blocked: ?" "$(render "$PM")" "❓ ?"
printf '{"schema":"pm-user-questions/1","count":3,"blocked":"true"}' > "$CACHE"
out=$(render "$PM")
assert_contains "string blocked: ?" "$out" "❓ ?"
assert_not_contains "string blocked: not a count" "$out" "Qs"

# single read: a fake jq counts invocations on the cache
cache 3 false
mkdir -p "$SB/fakebin"; REAL_JQ=$(command -v jq)
printf '#!/bin/sh\ncase "$*" in *user-questions.json*) echo x >> "%s/jqcalls";; esac\nexec "%s" "$@"\n' "$SB" "$REAL_JQ" > "$SB/fakebin/jq"; chmod +x "$SB/fakebin/jq"
rm -f "$SB/jqcalls"; out=$(PATH="$SB/fakebin:$PATH" render "$PM")
assert_contains "fake jq path still renders" "$out" "❓ 3 Qs"
n=$(grep -c x "$SB/jqcalls" 2>/dev/null || echo 0)
assert_contains "cache read by exactly one jq call" "calls=$n" "calls=1"

sandbox_rm
finish
