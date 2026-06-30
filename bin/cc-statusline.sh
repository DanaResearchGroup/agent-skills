#!/usr/bin/env bash
# Claude Code status line: model name + context-window usage bar + percentage.
# Reads the statusline JSON on stdin.
input=$(cat)
model=$(echo "$input" | jq -r '.model.display_name // "Claude"')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

if [ -n "$used" ]; then
    used_int=$(printf '%.0f' "$used")
    filled=$(( used_int * 20 / 100 ))
    empty=$(( 20 - filled ))
    bar=""
    for i in $(seq 1 $filled); do bar="${bar}#"; done
    for i in $(seq 1 $empty); do bar="${bar}-"; done
    printf "\033[0;36m%s\033[0m [\033[0;33m%s\033[0m] \033[0;33m%d%%\033[0m" "$model" "$bar" "$used_int"
else
    printf "\033[0;36m%s\033[0m" "$model"
fi
