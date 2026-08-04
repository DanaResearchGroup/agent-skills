# Non-goal landmine categories

Free-text non-goals decay into boilerplate ("does not refactor unrelated code").
Answer each category below, or mark it `N/A` explicitly. An unanswered category
is an unwritten contract.

- **Data migration / schema change** — does this alter any persisted shape?
- **External API or file-format compatibility** — does anything downstream parse this?
- **Compute spend** — cluster jobs, QM calculations, paid API calls.
- **Shared or dirty checkouts** — other worktrees on this repo, live sessions elsewhere.
- **Other people's files** — students, collaborators, shared archives.
- **Shared branches** — anything already pushed or based on by another branch.
- **Deletion** — of existing artifacts, results, or history.
