# Pane-screen fixtures

Bottom-of-pane text for `test-awaiting-human.sh` and `test-pm-nudge.sh`, as
`herdr pane read` returns it. `mux_text_awaiting_human` (in `bin/mux-lib.sh`)
must flag every file here except the two `idle-*` ones.

| File | State | Source |
|---|---|---|
| `single-select.txt` | AskUserQuestion, one question tab of several, long option descriptions, "Type something." row | real capture |
| `multi-question.txt` | AskUserQuestion, multi-question tab bar | real capture |
| `preview.txt` | AskUserQuestion with a preview pane and notes; the `❯` row sits far above the footer | real capture |
| `review-answers.txt` | the "Review your answers" submit screen, which has **no** footer | real capture |
| `permission-bash.txt` | Bash permission prompt (`Do you want to proceed?`) | real capture |
| `idle-prompt.txt` | plain idle prompt with the status line | real capture |
| `multi-select.txt` | AskUserQuestion multi-select (`[ ]`/`[✔]` rows, Submit row) | assembled |
| `other-row.txt` | single-select with the cursor on the free-text "Other" row, text typed | assembled |
| `idle-after-answer.txt` | idle prompt whose transcript quotes a dialog footer higher up | assembled |

The real captures come from herdr's saved scrollback (`~/.config/herdr/session-history.json`).
This repo is public, so the question and option wording was replaced with neutral text. The chrome
the detector keys on was left exactly as captured: footers, `❯`, the tab bar, box glyphs, and
spacing. The assembled files follow the question view in the installed Claude Code bundle. It
draws one shared footer (`Enter to select · … to navigate · Esc to cancel`) under both the
single-select and multi-select lists, and draws multi-select rows as `[ ]`/`[✔]`. No live
capture of these states existed on disk.
