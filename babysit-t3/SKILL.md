---
name: babysit-t3
description: Autonomously run and babysit T3 (Tandem Tool) campaigns on the OL workstation — closed-loop RMG generation → sensitivity analysis (incl. IDT) → ARC QM refinement on zeus. Launches long-lived T3 processes, watches iterations, auto-fixes crashes and relaunches (T3 self-resumes), judges scientific quality per iteration, and consolidates validated learnings into the vault. Reaches the user over Slack only for a real blocker, a confirmed scientific deviation, or campaign completion. Use when asked to run/babysit a T3 campaign or T3-IDT run, run T3 on OL, or resume/monitor a T3 project.
---

# babysit-t3 — run + babysit T3 campaigns on OL (with Slack)

This skill **executes the vault's T3 Campaign Runbook autonomously on OL** and adds a thin Slack
layer for high-signal human-in-the-loop. **The vault notes are the source of truth — read them; this
file only orchestrates and must not duplicate their depth.** Run it with one line, e.g. *"load
`~/Projects/T3_CAMPAIGNS.md` and run it autonomously"*.

## Where it runs
**OL only** (`hostname Office`, on-network → reaches zeus directly, no VPN). T3 runs in **`t3_env`**
(which imports **ARC incore** from `~/Code/ARC`); incore RMG is a subprocess in **`rmg_env`**. Heavy
QM is on zeus (PBS, submitted by ARC-incore); RMG and Cantera SA are local and CPU/RAM-heavy.

## Step 0 — read the vault FIRST (authoritative)
Vault root on OL: `~/Dropbox/Apps/remotely-save/Vault/` (path per machine is in CC memory). Read:
- `knowledge/wiki/T3 Campaign Runbook.md` — the full process (mental model, autonomy rules,
  STATUS.md ledger, crash→fix→relaunch, success criteria, consolidation, teardown). **This governs
  everything below.**
- `Code/T3/T3 on OL — Troubleshooting & Knowledge.md` — OL config (`~/.t3/t3_settings.py` incore
  override), monitoring-signal table, the **T3-layer known-bug catalog**, open questions.
- For the ARC layer inside T3: `knowledge/wiki/Running ARC On Zeus.md` + `Code/ARC/ARC on OL — Zeus
  Troubleshooting & Knowledge.md` (zeus gate, `~/.arc/settings.py`, QM bug catalog, queue policy).

Then read the run's state files: the launch file `~/Projects/T3_CAMPAIGNS.md` and each campaign's
`RUN.md` (operating manual), `INDEX.md` (file map), and **`STATUS.md` — read this FIRST on any
(re)start; it is the resume ledger and single source of truth for what is running.**

## Autonomy contract
Run **without questions**, applying the documented defaults; **record every decision/anomaly/action
as a timestamped line in `STATUS.md`**, never halt for a choice the runbook already resolves. Reach
the user (Slack) **only** for the three cases in the Slack policy below. Never fabricate progress or
grind silently — on a true blocker, report honestly in `STATUS.md` and ask.

## Phase A — campaign prep (spec → project folder)
Follow the runbook's Phase A: build `input.yml` (rmg / t3 / qm blocks; for IDT campaigns the
`t3.sensitivity` IDT settings + `experimental_idt_path`), then **validate against the T3 schema
before launch** with the runbook's `InputBase` one-liner — **never launch a broken campaign.** Write
`RUN.md`/`INDEX.md`/`STATUS.md`/`ISSUES.md`/`FIXES.md`.

## Phase B — pre-flight (once per session)
Per the runbook + troubleshooting note (don't inline configs here): **branches** on the **main
checkouts** (T3 `idt` until merged; ARC/RMG-Py/RMG-database per `RUN.md`) and recompile if a switch
touched Cython; **envs** (`t3_env` imports `arc` from `~/Code/ARC`; `rmg_env` imports `rmgpy`);
**`~/.t3/t3_settings.py`** incore override present; **`~/.arc/settings.py`** zeus block + **zeus
gate** (`ssh -o BatchMode=yes -o ConnectTimeout=15 alon@zeus.technion.ac.il 'echo ok'`); apply the
**uncommitted** `arc/scheduler.py` poll edit `time.sleep(30)`→`time.sleep(180)` (T3 imports that
checkout incore, so it applies here too). **First T3 campaign on a host** — or whenever
`~/.t3/t3_settings.py` was just created/changed — run the **smoke run** (runbook Phase B: minimal
example in a scratch dir) before the real launch; this is a documented default, not a question.
Also clear the troubleshooting note's pre-IDT checks (e.g. the numpy-2.x `cantera_idt` item)
before an IDT campaign.

## Running unattended — supervisor poll-loop (keeps context low)
Prefer the bundled **`t3_babysitter.sh`** supervisor over one long session. It spawns a **fresh
headless `claude -p` per pass** (`--dangerously-skip-permissions`), sleeps ~30 min between passes,
and exits when the pool is `DONE` or `PAUSED`. It reads the spec at `$T3_SPEC` (default
`~/Projects/T3_CAMPAIGNS.md`), writes state to `~/Projects/.t3_babysitter.state` and its log to
`~/Projects/t3_babysitter.log` (all overridable via env — see the script header). Context never
grows, no `/compact`/handoff. Manual launch in tmux:
`tmux new -s t3 'bash ~/.claude/skills/babysit-t3/t3_babysitter.sh'`; relaunch the same line after
a reboot (the first pass rebuilds from `STATUS.md` — like `arc_babysitter.sh`, it does **not**
auto-restart itself).

**Per-pass contract (when supervised):** do **exactly one** babysitting pass, then **stop** — don't
stay resident or sleep. End each pass by writing one word to `~/Projects/.t3_babysitter.state`:
`DONE` (whole pool terminal **and** teardown done), `PAUSED` (a blocker — also `slack-ask`), or
`RUNNING`. On a blocker, `slack-ask` blocks within the pass until the reply or the pass timeout; if
the blocker still stands, record the open question in `STATUS.md` and write `PAUSED` — the
supervisor exits, and after resolving over Slack the user relaunches the same tmux line.

**Single orchestrator — shared with ARC.** T3 and ARC campaigns share zeus and the same `~/Code/ARC`
checkout. **Never run `t3_babysitter.sh` and `arc_babysitter.sh` at the same time** — check in
pre-flight (`pgrep -af babysitter.sh`); if the other pool is live, fold them (point `T3_SPEC` at a
combined spec that links both launch files) or finish one pool first.

## Launch + babysitting (per pass)
Launch one **detached** T3 process per campaign from its project dir
(`setsid conda run --no-capture-output -n t3_env python ~/Code/T3/T3.py input.yml >> t3_stdout.log
2>&1 &`; `echo $! > t3.pid`), record PID+time in `STATUS.md`; stagger launches so RMG phases don't
pile up on local RAM. Each pass, per campaign: detect the current phase from the newest
`iteration_N/`, check health per the runbook's phase table (PID alive; `RMG.log`/SA outputs/`arc.log`
advancing; zeus jobs cycling, not stuck `Q`; disk OK locally **and** on zeus), update the iteration
history (incl. **IDT RMSE(log10)** when logged), and append a **timestamped heartbeat** to
`STATUS.md`. **Respect the zeus SSH budget strictly** (vault: Running ARC On Zeus §0b — a spamming
account gets banned): all per-pass zeus checks in **one batched connection** (≤ 4 SSH ops/pass),
one `qstat -u $USER` for all jobs, < ~60 SSH/h combined incl. ARC-incore's own polling; back off
≥ 5 min on SSH failures, never tight-loop.

**Crash → fix → relaunch:** let T3's **inner** retries work first (RMG ×5 with memory bumps; ARC
`restart.yml`). If the T3 process dies: traceback → the **bug catalogs** (T3-layer: vault T3
troubleshooting note; ARC/zeus-layer: Running ARC On Zeus §4–5) → fix in the host checkout →
relaunch the same command (T3 auto-resumes) → **verify it resumed at the expected iteration** — if it
restarts from scratch, kill immediately and ask. Bounded budget (**3** per distinct failure), then
mark `blocked` and **continue with the rest of the pool**.

- **Record fixes by scope — code stays UNSTAGED (never `git add`/`git commit`):**
  - **Per-run fix:** leave the edit unstaged + log in the campaign's **`FIXES.md`** (bug, root
    cause, diff, files, timestamp). Re-apply uncommitted fixes after any fresh checkout.
  - **Validated, generalizable learning:** **consolidate into the vault** per the runbook — **merge
    into the relevant existing section, don't append duplicates; confirmed-only.** T3-layer →
    `T3 on OL — Troubleshooting & Knowledge` (bug catalog / newest-at-top log); ARC/zeus-layer →
    the ARC notes; process-level → the `T3 Campaign Runbook` itself. Silent (no Slack).

## Issues ledger (`ISSUES.md`, per campaign) — human follow-up
Distinct from `STATUS.md` (live ledger) and `FIXES.md` (code-fix log), and finer-grained. **Never
silently drop a failure:** every parked problem — a species ARC couldn't converge, a TS not found, an
iteration that exhausted RMG retries, a `blocked` campaign, a **questionable SA/IDT result** (e.g.
RMSE degrading after refinement, no NTC region, an exotic estimated reaction dominating SA) — gets a
row (item · type · what happened/tried · suggested human action · log/dir pointer). At completion,
finalize the **wins** summary (iterations, final model size, IDT convergence delta, NTC check,
experiment comparison, ARC coverage). Keeping it current is **silent** (no Slack).

## Success criteria — scientific correctness is the bar
Per the runbook: per-iteration (RMG banner + plausible core; SA outputs; sensible QM selections; ARC
results meeting the **ARC bar**; libraries consumed by the next iteration; RMSE trail not degrading)
and campaign-end (observable convergence < ~×1.5 between final iterations; **NTC region** present for
alkane fuels; within ~2–3× of experiment; SA dominated by expected players; ARC refinement coverage
≥ ~70 %). Never accept a converged-but-wrong mechanism.

## Scientific diagnosis & deviations (slack-ask before deviating)
Beyond pass/fail, **diagnose result quality**: is the LOT right for the flagged species (T1
diagnostic > 0.02 → multireference suspect)? Is a degrading IDT trail caused by a bad refined rate?
**Any** change to a campaign's `input.yml` (tolerances, LOT, observables, grid) must be **diagnosed,
reasoned, and confirmed via `slack-ask`**, then run as a **new sibling project dir**
(`<name>` → `<name>_b`) with a header comment explaining the change — original kept intact,
`INDEX.md`/`STATUS.md` rows linking child→parent. **Never delete a run; never edit a live
`input.yml` in place.**

## Post-processing & teardown
T3 consolidates ARC libraries into its shared T3 libraries itself (`t3/utils/libraries.py`) — verify
they exist and are consumed. When the **whole pool** (incl. any ARC campaigns sharing the checkout)
is terminal: revert the uncommitted `scheduler.py` poll edit (`git -C ~/Code/ARC checkout --
arc/scheduler.py`), finalize each `ISSUES.md` wins summary, note teardown in `STATUS.md`. Re-apply
the edit on any restart/resume. **Resume after outage:** read `STATUS.md`, re-run pre-flight,
relaunch every non-terminal campaign (T3 self-resumes), verify resumed iterations.

## Slack policy — minimal, high-signal (every message means "needs me")
Invoke the existing **`slack-ask`** / **`slack-notify`** skills (they post as the bot via
`/home/alon/.claude/bin/cc-slack-post.py` to `#cc-comm`). Send Slack **only** in these cases:
1. **Real blocker → `slack-ask`** (pause + wait): zeus unreachable, broken settings/branches/envs, a
   failure surviving the fix→relaunch budget, T3 restarting from scratch instead of resuming, disk/
   quota exhaustion, an ambiguous result you can't safely accept or reject.  Record in `STATUS.md`
   first; resume per the reply.
2. **Scientific deviation → `slack-ask`** (confirm first): any diagnosed change to `input.yml` or
   course-correction. Present diagnosis + recommendation; on approval, spawn the sibling-folder run.
3. **Campaign finished → `slack-notify`** (one summary): iterations + quality verdict (RMSE trail,
   NTC, coverage) + where the final mechanism/libraries are. With a shared pool, notify when the
   whole pool is terminal.

**Otherwise: no Slack.** Normal progress, routine auto-fixes/relaunches, and per-pass heartbeats go
to `STATUS.md` only.

## Related
Vault: `[[T3 Campaign Runbook]]` · `[[T3 on OL — Troubleshooting & Knowledge]]` ·
`[[Running ARC On Zeus]]` · `ARC on OL — Zeus Troubleshooting`. Skills: `slack-ask`, `slack-notify`,
`babysit-arc` (the sibling pattern for pure-ARC pools). Bundled: `t3_babysitter.sh` (supervisor
poll-loop).
