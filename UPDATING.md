# Updating your agent-skills clone

You cloned this repo (you did not fork it), so updates are a plain pull. Tell
your Claude Code: **"update my agent-skills"** and it will run this runbook.

## Normal case (no local edits)

```bash
cd ~/Code/agent-skills
git fetch origin
git pull --ff-only
```

`--ff-only` refuses to create a merge commit. If it succeeds, you are done — the
symlink at `~/.claude/skills` already points here, so new/updated skills are live
on your next Claude Code session.

## If `--ff-only` fails

It fails for one reason: you have local commits or uncommitted edits to skills.
Claude Code should:

1. **Inspect** what diverged:
   ```bash
   git -C ~/Code/agent-skills status
   git -C ~/Code/agent-skills log --oneline origin/main..HEAD   # your local-only commits
   git -C ~/Code/agent-skills stash list
   ```
2. **Decide with the user:**
   - Uncommitted edits you want to keep → `git stash`, `git pull --ff-only`,
     `git stash pop`, then resolve any conflict hunks.
   - Local edits you do **not** need → `git checkout -- <file>` (or
     `git reset --hard origin/main` to discard everything local — destructive,
     confirm first).
   - Local commits worth keeping → `git pull --rebase` and resolve conflicts
     file-by-file, keeping upstream's structure and re-applying your intent.
3. **Verify** after: `git -C ~/Code/agent-skills status` is clean and
   `git -C ~/Code/agent-skills log --oneline -3` shows the upstream tip.

## Why there is no personalize step

Paths in this repo use `$HOME`, not a hardcoded home directory, so there is
nothing to re-personalize after a pull.
