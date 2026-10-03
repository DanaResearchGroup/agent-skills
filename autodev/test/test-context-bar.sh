#!/usr/bin/env bash
# Optional context-window bar (autodev/bin/cc-context-bar.sh, row 2 of cc-statusline.sh)
# and the /context-bar toggle. Everything runs against a throwaway AUTODEV_HOME and HOME.

. "$(dirname "$0")/lib.sh"

SID=66666666-6666-6666-6666-666666666666
sandbox_new
export HOME="$SB/home"; mkdir -p "$HOME"
unset NO_COLOR PM_ROOT
TP="$SB/t.jsonl"
FLAG="$STATE/context-bar.on"
ESC=$'\033'

table() { # $1 = Messages tokens text; $2 = extra row (optional)
  printf '## Context Usage\n\n**Model:** m  \n**Tokens:** 172.3k / 1m (17%%)\n\n### Estimated usage by category\n\n| Category | Tokens | Percentage |\n|----------|--------|------------|\n| System prompt | 2k | 0.2%% |\n| System tools | 5.2k | 0.5%% |\n| MCP server instructions | 2k | 0.2%% |\n| MCP tools (deferred) | 148.5k | 14.9%% |\n| System tools (deferred) | 10.6k | 1.1%% |\n| Custom agents | 394 | 0.0%% |\n| Memory files | 9.6k | 1.0%% |\n| Skills | 8.3k | 0.8%% |\n| Messages | %s | 14.5%% |\n| Free space | 794.7k | 79.5%% |\n| Autocompact buffer | 33k | 3.3%% |\n%s\n### MCP Tools\n\n| Tool | Server | Tokens |\n|------|--------|--------|\n| mcp__x__y | x | 161 |\n' "$1" "${2:-}"
}
snapshot() { jq -nc --arg c "$(table "$@")" '{type:"user",message:{role:"user",content:$c}}' >> "$TP"; }
noise() { printf '{"type":"assistant","message":{"content":"hi"}}\n' >> "$TP"; }
render() { # $1 = used tokens (current_usage.input_tokens), $2 = window size
  printf '{"session_id":"%s","transcript_path":"%s","model":{"display_name":"Opus"},"context_window":{"used_percentage":17,"total_input_tokens":1234,"context_window_size":%s,"current_usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}' "$SID" "$TP" "$2" "$1" \
    | bash "$BIN/cc-statusline.sh"
}
# Cells of a given 256-colour background in the bar row (row 2).
cells() { # $1 = row, $2 = colour index
  printf '%s' "$1" | awk -v c="$2" 'BEGIN{RS="\033\\[0m"} index($0, "\033[48;5;" c "m") {s=$0; sub(/^.*m/, "", s); n+=length(s)} END{print n+0}'
}
row2() { printf '%s\n' "$1" | sed -n 2p; }

: > "$TP"; snapshot "144.8k"; noise

out=$(render 172300 1000000)
assert_not_contains "flag off: no bar" "$out" "run /context"
assert_eq "flag off: single row" "$(row2 "$out")" ""
assert_contains "flag off: line renders" "$out" "Opus"

: > "$FLAG"; out=$(render 172300 1000000); r=$(row2 "$out")
assert_contains "flag on: first row intact" "$(printf '%s\n' "$out" | sed -n 1p)" "Opus"
assert_contains "flag on: bar row present" "$r" "${ESC}[48;5;"
assert_eq "messages cells (144.8k of 1m x60, cumulative -> 8)" "$(cells "$r" 105)" "8"
assert_eq "skills cells (8.3k -> 1)" "$(cells "$r" 178)" "1"
assert_eq "free cells (60-10-2)" "$(cells "$r" 237)" "48"
assert_eq "autocompact hatch cells (33k -> 2)" "$(printf '%s' "$r" | grep -o '╱' | wc -l)" "2"
assert_not_contains "deferred rows excluded" "$r" "148"
assert_not_contains "deferred names excluded from legend" "$r" "deferred"
assert_contains "legend: largest first" "$r" "msgs 145k"
assert_contains "legend: totals" "$r" "172k/1m"

# Messages is live: more used tokens -> more message cells, static unchanged.
r=$(row2 "$(render 472300 1000000)")
assert_eq "live messages grow (444.8k -> 26)" "$(cells "$r" 105)" "26"
assert_eq "static unchanged" "$(cells "$r" 178)" "1"
# Used below the static sum clamps Messages at zero.
r=$(row2 "$(render 1000 1000000)")
assert_eq "messages clamp at zero" "$(cells "$r" 105)" "0"
# Window from stdin wins over the snapshot's.
r=$(row2 "$(render 172300 200000)")
assert_contains "window size from stdin" "$r" "172k/200k"

# Cache: reused and incremental -- a snapshot written AFTER the cache was built wins.
assert_file "cache written" "$STATE/$SID.ctxbar"
snapshot "50k"; noise
r=$(row2 "$(render 100000 1000000)")
assert_contains "newest snapshot wins" "$r" "${ESC}[48;5;105m"
assert_eq "newest snapshot: messages = used - static (100k-28.9k -> 4)" "$(cells "$r" 105)" "4"
# Messages is live, so it cannot prove the appended snapshot was read: change a STATIC
# category in a snapshot appended after the cache exists, and require its new size.
assert_eq "before the static change: skills 8.3k -> 1 cell" "$(cells "$r" 178)" "1"
jq -nc --arg c "$(table 1k | sed 's/| Skills | 8.3k/| Skills | 100k/')" '{type:"user",message:{role:"user",content:$c}}' >> "$TP"; noise
r=$(row2 "$(render 172300 1000000)")
assert_eq "appended static change read through the cache (skills 100k -> 6 cells)" "$(cells "$r" 178)" "6"
assert_contains "appended static change in legend" "$r" "skills 100k"

# A half-written final line is not claimed as scanned: once completed, it is read.
: > "$TP"; snapshot "144.8k"; noise; rm -f "$STATE/$SID.ctxbar"
render 172300 1000000 >/dev/null
line=$(jq -nc --arg c "$(table 1k | sed 's/| Skills | 8.3k/| Skills | 100k/')" '{type:"user",message:{role:"user",content:$c}}')
printf '%s' "${line:0:40}" >> "$TP"
render 172300 1000000 >/dev/null
printf '%s\n' "${line:40}" >> "$TP"
r=$(row2 "$(render 172300 1000000)")
assert_eq "partial line completed later is read (skills 100k -> 6 cells)" "$(cells "$r" 178)" "6"
# A transcript with two snapshots and NO cache must also pick the newest.
rm -f "$STATE/$SID.ctxbar"
jq -nc --arg c "$(table 1k | sed 's/| Skills | 8.3k/| Skills | 100k/')" '{type:"user",message:{role:"user",content:$c}}' >> "$TP"; noise
r=$(row2 "$(render 172300 1000000)")
assert_eq "no cache, two snapshots: newest (skills 100k -> 6 cells)" "$(cells "$r" 178)" "6"

# No snapshot: two segments and a hint.
: > "$TP"; noise; rm -f "$STATE/$SID.ctxbar"
r=$(row2 "$(render 172300 1000000)")
assert_contains "no snapshot: hint" "$r" "run /context for categories"
assert_eq "no snapshot: used cells (172.3k -> 10)" "$(cells "$r" 105)" "10"
assert_eq "no snapshot: free cells" "$(cells "$r" 237)" "50"
assert_not_contains "no snapshot: no other categories" "$r" "${ESC}[48;5;71m"

# Corrupt table: no row, first row intact.
: > "$TP"; jq -nc --arg c "$(table 'lots')" '{type:"user",message:{role:"user",content:$c}}' >> "$TP"
rm -f "$STATE/$SID.ctxbar"; out=$(render 172300 1000000)
assert_eq "corrupt table: no bar row" "$(row2 "$out")" ""
assert_contains "corrupt table: line intact" "$out" "Opus"

# Corrupt table: the status line still exits 0 (an empty row is not a failed render).
render 172300 1000000 >/dev/null; assert_eq "corrupt table: status line exits 0" "$?" "0"

# A newer table that fails to parse keeps the good categories already cached.
: > "$TP"; snapshot "144.8k"; noise; rm -f "$STATE/$SID.ctxbar"
render 172300 1000000 >/dev/null
jq -nc --arg c "$(table 'lots')" '{type:"user",message:{role:"user",content:$c}}' >> "$TP"; noise
r=$(row2 "$(render 172300 1000000)")
assert_not_contains "bad newer table: not degraded to no-snapshot" "$r" "run /context for categories"
assert_contains "bad newer table: legend kept" "$r" "mem 9.6k"

# A tool result that merely quotes the table (array content) is not a snapshot.
: > "$TP"; jq -nc --arg c "$(table 1k)" '{type:"user",message:{role:"user",content:[{type:"tool_result",content:$c}]}}' >> "$TP"
rm -f "$STATE/$SID.ctxbar"
assert_contains "quoted table ignored" "$(row2 "$(render 172300 1000000)")" "run /context for categories"

# NO_COLOR: letters, no escapes in the bar row.
: > "$TP"; snapshot "144.8k"; rm -f "$STATE/$SID.ctxbar"
r=$(row2 "$(NO_COLOR=1 render 172300 1000000)")
assert_not_contains "NO_COLOR: no escapes" "$r" "$ESC"
assert_contains "NO_COLOR: letters" "$r" "MMMMMMMM...."
assert_contains "NO_COLOR: buffer + free" "$r" "....#"

# Unusable stdin (no window anywhere): no row, no failure.
out=$(printf '{"session_id":"%s","model":{"display_name":"Opus"}}' "$SID" | bash "$BIN/cc-statusline.sh")
assert_eq "no usage fields: no bar row" "$(row2 "$out")" ""

# Toggle script.
TG="$SKILL_DIR/../context-bar/bin/toggle.sh"
rm -f "$FLAG"
assert_eq "toggle on" "$(bash "$TG")" "context bar: on"; assert_file "flag created" "$FLAG"
assert_eq "toggle off" "$(bash "$TG")" "context bar: off"; assert_no_file "flag removed" "$FLAG"

# The standard status line (repo-root bin/) renders the same row from the same flag.
STD="$SKILL_DIR/../bin/cc-statusline.sh"
: > "$TP"; snapshot "144.8k"; noise; rm -f "$STATE/$SID.ctxbar"; : > "$FLAG"
out=$(printf '{"session_id":"%s","transcript_path":"%s","model":{"display_name":"Opus"},"context_window":{"used_percentage":17,"total_input_tokens":1234,"context_window_size":1000000,"current_usage":{"input_tokens":172300,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}' "$SID" "$TP" | bash "$STD")
assert_contains "standard status line: bar row present" "$(row2 "$out")" "msgs"
rm -f "$FLAG"
out=$(printf '{"session_id":"%s","transcript_path":"%s","model":{"display_name":"Opus"},"context_window":{"used_percentage":17,"total_input_tokens":1234,"context_window_size":1000000}}' "$SID" "$TP" | bash "$STD")
assert_eq "standard status line: flag off, no row" "$(row2 "$out")" ""


sandbox_rm

finish
