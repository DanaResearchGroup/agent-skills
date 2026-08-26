# Security

## Reporting

Found a secret, a token, or anything else sensitive in this repo — in the
current files **or** in git history? Report it privately via GitHub's
[private vulnerability reporting](https://github.com/DanaResearchGroup/agent-skills/security/advisories/new)
(**Security → Report a vulnerability**), or contact the maintainer directly.
Please don't open a public issue that quotes the finding.

## Known history, deliberately not purged

This repo began as a personal skills directory and was published with its
history intact. Two early revisions — commit `4c732d8`, and `ADAPTATION.md` as
of `94cc788` — contain a filesystem path that identifies a private machine.

We decided against rewriting history to remove it: the path is location
detail, not a credential — it grants no access — and a purge would invalidate
every existing clone, fork, and open PR to delete something already public.
The current tree carries no such references.

## What was hardened instead

- **CI secret scan** — the `secret-scan` job in
  [`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs
  [gitleaks](https://github.com/gitleaks/gitleaks) with the repo's
  `.gitleaks.toml` on every PR (diff-scoped: only the commits the PR
  introduces) and every push (working tree). A finding fails the build.
- **No baked-in private ids** — the Slack helper (`bin/cc-slack-post.py`)
  requires `CC_SLACK_CHANNEL` and refuses to send without it, instead of
  defaulting to a real private channel id.
- **No secrets in argv** — [SETUP.md](SETUP.md) enters the bot token via
  `read -s`, never as a command-line literal, into a mode-600 file outside
  the repo.
