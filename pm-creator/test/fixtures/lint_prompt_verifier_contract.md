# Dispatch header (operator-facing)

| Field | Value |
|---|---|
| Ticket | I-042 |
| Tab | i042-widget-parser |
| Model | Sonnet |

--- paste below this line ---

You are fixing a widget-parser crash in the repo at /home/dev/Code/widget-tools
(branch fix-empty-widgets, worktree /home/dev/Code/widget-tools-fix-empty-widgets).

The crash: parsing a config with an empty `widgets:` list raises IndexError in
src/widget_tools/parser.py:88.

Verifier (the concrete check that proves this work is done):
run `pytest -q tests/test_parser.py` in the worktree — all tests pass, including a
new regression test covering the empty-list case.

Approval gates (do NOT do these without explicit user approval): merging to main,
pushing to any remote, deleting branches.

Structure your final report in exactly three sections:
1. Completed — what you did, with file paths and commit SHAs.
2. Verification — run the verifier above and paste its outcome; if you could not
   run it, say so plainly and why.
3. Remaining Work — anything left undone, blocked, or discovered out of scope.

Cite D-042 when you report so the result can be filed.
