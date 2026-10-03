---
name: context-bar
description: Toggle the second status-line row that draws the context window as a stacked bar, one colour per /context category. Use when asked to show, hide, or toggle the context bar.
disable-model-invocation: true
---

Run `bash ~/.claude/skills/context-bar/bin/toggle.sh` and report its one-line output (`context bar: on|off`). The row appears on the next status-line render when the configured status line is this repo's `bin/cc-statusline.sh` or `autodev/bin/cc-statusline.sh` (both read the flag); a different status-line command will not show it. Run `/context` once so the bar has categories to draw.
