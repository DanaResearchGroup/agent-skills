# babysit-arc — Usage & Examples

Quick reference for **how to invoke** the skill. Depth lives in `SKILL.md` and the vault
(`ARC Campaign Runbook`, `Running ARC On Zeus`). Runs on **OL only** (reaches zeus directly).

## TL;DR
There are two ways to run, depending on whether you want to babysit it yourself or leave it unattended:

1. **Unattended (recommended)** — start the supervisor; it runs fresh one-pass Claude sessions on a
   loop so context never grows:
   ```bash
   tmux new -s arc 'bash ~/.claude/skills/babysit-arc/arc_babysitter.sh'
   # detach: Ctrl-b d   ·   reattach: tmux attach -t arc   ·   watch: tail -f ~/Projects/arc_babysitter.log
   ```
   Relaunch the same line after a reboot — it rebuilds state from `STATUS.md`.

2. **Interactive (one session)** — just tell Claude what to do; the skill auto-activates on any
   "run/babysit ARC", "ARC on OL/zeus", or "compute k(T)/thermo" request. Canonical prompt:
   > **Use the babysit-arc skill: read `~/Projects/ARC_CAMPAIGNS.md` and run both campaigns autonomously.**

The skill reads the vault + the run's `STATUS.md` first, then acts. It only pings you on **Slack** for
a real blocker, a proposed scientific deviation, or when the pool finishes — otherwise it's silent.

## Example prompts

**Run a prepared campaign** (the launch spec + per-project `RUN.md`/`STATUS.md` already exist):
> Use babysit-arc: read `~/Projects/ARC_CAMPAIGNS.md` and run it autonomously.

**Generate a new campaign from a spec, then run it** (Phase A → B):
> Use babysit-arc to set up a new ARC campaign under `~/Projects/EPDM/`: compute **rate coefficients**
> for these reactions at **wB97X-D/def2-TZVP // DLPNO-CCSD(T)-F12/cc-pVTZ-F12 (ORCA)** —
> `butenal + OH <=> C4H5O + H2O`, `butenal + H <=> C4H5O + H2`, … . Resolve species, prune any
> net/well-skipping reactions, generate the run folders + INDEX/STATUS/ISSUES, validate each
> `input.yml`, then launch and babysit.

**Resume after an outage / reboot:**
> Use babysit-arc to resume: read the `STATUS.md` files under `~/Projects/THF/M10` and
> `~/Projects/TCHSF/arc`, re-run pre-flight, and relaunch every instance that isn't `processed`.

**One status pass** (what the supervisor calls each cycle):
> Use babysit-arc. Read `~/Projects/ARC_CAMPAIGNS.md`, do **one** babysitting pass, update
> `STATUS.md`/`ISSUES.md`, then stop.

**Triage / report only** (no changes):
> Use babysit-arc to summarise current campaign status from the `STATUS.md`/`ISSUES.md` files —
> what's running, done, blocked, and what needs me — without launching or changing anything.

## What it does / doesn't
- **Autonomous:** applies the runbook's defaults, logs every action as a timestamped line in
  `STATUS.md`, auto-fixes known crashes (bounded retries) and restarts; never asks about routine
  choices.
- **Asks (Slack `slack-ask`) only** for a true blocker (e.g. can't reach zeus) or a proposed LOT/method
  deviation; **notifies (`slack-notify`) once** when the whole pool finishes.
- **Scientific correctness is the bar** — never marks a result `processed` unless it's sane.

## Files it maintains (per project)
`STATUS.md` (live job ledger / resume source) · `ISSUES.md` (human follow-up punch-list) ·
`FIXES.md` (code-fix log, unstaged) · the consolidated RMG libraries · and validated learnings merged
back into the vault.

## See also
`SKILL.md` (full process) · `arc_babysitter.sh` (the supervisor) · vault `ARC Campaign Runbook` /
`Running ARC On Zeus`.
