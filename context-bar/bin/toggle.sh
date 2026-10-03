#!/usr/bin/env bash
# Flip the context-bar flag read by both status lines (bin/ and autodev/bin/cc-statusline.sh).
flag="${AUTODEV_HOME:-$HOME/agents}/state/context-bar.on"
mkdir -p "$(dirname "$flag")" || exit 1
if [ -f "$flag" ]; then rm -f "$flag" && echo "context bar: off"
else : > "$flag" && echo "context bar: on"; fi
