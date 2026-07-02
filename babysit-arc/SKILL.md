---
name: babysit-arc
description: Autonomously run and babysit ARC (Automated Rate Calculator) campaigns on the OL workstation — generate run folders from a reaction/species spec, launch instances that submit QM jobs to the zeus PBS cluster, watch them, auto-fix known crashes and restart, and judge scientific correctness. Reaches the user over Slack only when it truly needs them (a real blocker or a confirmed scientific deviation) or when a campaign finishes. Use when asked to run/babysit an ARC campaign, run ARC on OL/zeus, compute k(T) or thermo for a set of reactions, or resume/monitor an ARC run.
---

# babysit-arc — run + babysit ARC campaigns on OL (with Slack)

This skill **executes the vault's ARC Campaign Runbook autonomously on OL** and adds a thin Slack
layer for high-signal human-in-the-loop. **The vault notes are the source of truth — read them; this
file only orchestrates and must not duplicate their depth.** Run it with one line, e.g. *"load
`~/Projects/ARC_CAMPAIGNS.md` and run it autonomously"*.

## Where it runs
**OL only** (`hostname Office`, on-network → reaches zeus directly, no VPN). ARC runs in **`arc_env`**;
RMG/Arkane in **`rmg_env`**. Heavy QM is on zeus (PBS); locally each instance is orchestration + Arkane.

## Step 0 — read the vault FIRST (authoritative)
Vault root on OL: `~/Dropbox/Apps/remotely-save/Vault/` (path per machine is in CC memory). Read:
- `knowledge/wiki/ARC Campaign Runbook.md` — the full process (autonomy rules, STATUS.md ledger,
  crash→fix→restart, success criteria, consolidation, teardown). **This governs everything below.**
- `knowledge/wiki/Running ARC On Zeus.md` — operational guide + failure modes.
- `Code/ARC/ARC on OL — Zeus Troubleshooting & Knowledge.md` — OL→zeus config, the **known-bug
  catalog**, validated `~/.arc/settings.py`/`submit.py`, queue policy.

Then read the run's state files: the launch file `~/Projects/ARC_CAMPAIGNS.md` and each campaign's
`RUN.md` (operating manual), `INDEX.md` (file map), and **`STATUS.md` — read this FIRST on any
(re)start; it is the resume ledger and single source of truth for what is running.**

## Autonomy contract
Run **without questions**, applying the documented defaults; **record every decision/anomaly/action as
a timestamped line in `STATUS.md`**, never halt for a choice the runbook already resolves. Reach the
user (Slack) **only** for the three cases in the Slack policy below. Never fabricate progress or grind
silently — on a true blocker, report honestly in `STATUS.md` and ask.

## Phase A — generation (spec → run folders)
Follow the runbook's Phase A: resolve species (SMILES; RMG adjacency lists for fragile aromatics/
radicals), confirm each reaction is an **elementary single-TS path** (`ARCReaction.determine_family()`)
and **prune only net / well-skipping** reactions (keep every elementary reaction, any molecularity),
partition into instances, write one `input.yml` per folder via the project's `gen_arc_inputs.py`, then
(re)generate `INDEX.md`/`STATUS.md` rows.

**TS-adapter family gate (set expectations before burning compute)** — from the OL troubleshooting
note's adapter findings: **`R_Recombination` reactions are barrierless (no saddle-point TS), so ARC
cannot compute them** → **quietly exclude them during generation (no Slack)** and **list each one in the
artifact** (`REPORT.md`/`ISSUES.md`) with the clear reason — *"barrierless bond fission, no TS for ARC
to locate."* Reactions handled by the **`linear`** adapter (R_Addition / Intra_R_Add / 1,2_Insertion)
have a **low TS-guess success rate** (no guesses, sub-threshold imaginary freq, 2nd-order saddles,
non-converging opt, CPU-spin hangs) → flag them in `STATUS.md`, **validate one early** before fanning
out, and don't expect the `heuristics`-grade hit rate H_Abstraction enjoys.

**Validate every `input.yml` by loading an ARC object — before launching ANY instance** (catches bad
job-type keys, malformed LOT, unresolved species, bad family early; runnable on **any** machine with
ARC importable — even before copying to OL). Mirror exactly what `ARC.py` does *before* `.execute()`:
read the input with ARC's own `read_yaml_file` (adjacency-list + `project_directory` preprocessing
plain `yaml.safe_load` misses), construct `ARC(**input_dict)`, and **never call `execute()`**.
Constructing the object runs all of ARC's input parsing/validation (species resolution,
`determine_family`, LOT lookup) and submits **no jobs**. (ARC has **no `from_dict()` classmethod** —
the `ARC(**input_dict)` constructor *is* the from-dict path.)
```bash
conda run -n arc_env python -c "import sys; from arc.common import read_yaml_file; from arc.main import ARC; ARC(**read_yaml_file(path=sys.argv[1], project_directory='.')); print('OK', sys.argv[1])" <instance>/input.yml
```
A failed load → fix the input; **never launch a broken instance.** Re-run this check on **every newly
generated deviation sibling folder** (`…b`/`…c`) before launching it, not just the originals.

## Phase B — pre-flight (once per session)
Per the runbook + troubleshooting note (don't inline the configs here): correct **branches** on the
**main checkout** (not a worktree) and **recompile** if a branch switch touched Cython (`make-compile`
in `arc_env` / `make` in `rmg_env`); apply the **uncommitted** `arc/scheduler.py` server-poll edit
`time.sleep(30)`→`time.sleep(180)`; confirm **zeus is defined in `~/.arc/settings.py` and reachable**
(`ssh -o BatchMode=yes -o ConnectTimeout=15 alon@zeus.technion.ac.il 'echo ok'`); verify envs.

## Running unattended — supervisor poll-loop (keeps context low)
Prefer running under the bundled **`arc_babysitter.sh`** supervisor rather than one long session. It
is the mother process: it spawns a **fresh headless `claude -p` per pass** (`--dangerously-skip-
permissions`), sleeps ~30 min between passes, exits when the pool is `DONE`, and on `PAUSED` **stays
resident slow-polling the state file** until you resolve the blocker and flip it back to `RUNNING`
(it does **not** exit on a blocker anymore). A fresh process each pass means **context never grows — no
`/compact` or handoff is ever needed** (the agent can't self-`/compact` or self-respawn anyway; the
supervisor owns the lifecycle). It also takes a **single-orchestrator lockfile**
(`~/Projects/.arc_babysitter.lock`) so a second copy can't start and double-book zeus.

**Launch options:**
- **Reboot-resilient (recommended for multi-day runs):** the bundled **`arc-babysitter.service`**
  systemd *user* unit auto-starts the supervisor on boot, rebuilding from `STATUS.md`
  (`systemctl --user enable --now arc-babysitter`; needs `loginctl enable-linger alon`). See USAGE.md.
- **Manual tmux:** `tmux new -s arc 'bash ~/.claude/skills/babysit-arc/arc_babysitter.sh'`; relaunch
  the same line after a reboot (manual tmux does **not** auto-restart — the first pass rebuilds state).

**Resume after a blocker:** fix the cause, then `echo RUNNING > ~/Projects/.arc_babysitter.state` — the
resident supervisor picks it up and runs the next pass (which re-evaluates; if still blocked it
re-`PAUSED`s).

**Per-pass contract (when supervised):** do **exactly one** babysitting pass, then **stop** — don't
stay resident or sleep. End each pass by writing one word to `~/Projects/.arc_babysitter.state`:
`DONE` (whole pool terminal **and** teardown done), `PAUSED` (a blocker — also `slack-notify` and
record it in `STATUS.md`; do **not** block on `slack-ask`), or `RUNNING`. Sequential passes preserve
the single-orchestrator / one-pool invariant automatically.

## Phase B — launch + babysitting (per pass)
Launch one **detached** ARC process per instance from its dir (`setsid python ~/Code/ARC/ARC.py
input.yml &`), record PID+time in `STATUS.md`; **single orchestrator / one pool** across campaigns.
**Batch size is bounded by the SSH budget, not just host resources:** autodetect from host (`nproc`,
`free -g`, ~1–2 GB/Arkane) and the zeus queue (`qstat -u $USER` vs `max_simultaneous_jobs`), **then cap
so ARC's own polling stays under budget** — each running ARC process spends ~20 SSH/h at the 180 s poll,
so ~2–3 concurrent ARC processes already consume the < ~60 SSH/h ceiling (leaving room for babysitter
checks). The heavy compute is on zeus; more local processes add queue/SSH pressure, not throughput.

Each pass, for every `running` instance check health (PID alive, `arc.log` advancing, jobs cycling
opt→freq→scan→sp, `restart.yml` updating, zeus jobs not stuck `Q`) and append a **timestamped
heartbeat** line to `STATUS.md`. **Respect the zeus SSH budget strictly** (vault: Running ARC On Zeus
§0b — a spamming account gets banned, killing all future projects): all per-pass zeus checks in **one
batched connection** (`ssh zeus 'qstat -u $USER; quota -s'`, ≤ 4 SSH ops/pass), one `qstat -u $USER`
for all instances, < ~60 SSH/h combined incl. ARC's own polling; back off ≥ 5 min on SSH failures,
never tight-loop.

**Zeus home-quota guard (a known pool-killer — check every pass, free in the batched connection).**
zeus home is quota-capped (soft/hard, e.g. 300/330 GB) and ARC outputs grow ~1.8 GB/hr, so a long
campaign steadily re-approaches the cap; crossing the **hard** limit makes *every* instance's SFTP
write fail at once → simultaneous pool-wide `OSError: [Errno 28] No space left` (even on local writes —
don't be fooled, OL disk is fine). From the batched `quota -s`: **over soft → warn in `STATUS.md` and
lower `max_simultaneous_jobs` / hold new launches**; **near hard → pause launches and `slack-ask`/
`slack-notify`** (free zeus home space or request a bump — the durable fix). No work is lost: every
`restart.yml` lives on OL.

**Stalled-but-alive escalation (not every wedge is a crash).** A live PID with **no `arc.log` /
`restart.yml` advance** is *unhealthy* even without a traceback (e.g. the `linear`/BDE conformer
CPU-spin hang — hours stuck on a tiny fragment, or a job re-submitted in a loop). If an instance shows
no progress for **> ~3 h** (and zeus jobs aren't merely queued), **kill+restart it** (resumes from
`restart.yml`; counts against the retry budget); on exhausting the budget mark `blocked`/`crashed`,
record the signature in `ISSUES.md`, and continue with the pool.

**Crash → fix → restart:** match the traceback to the vault **known-bug catalog** → fix in the host's
ARC/RMG checkout → restart from the instance dir (ARC resumes from `restart.yml`); bounded **retry
budget (3)**, then mark `blocked`/`crashed` and **continue with the others** (one bad instance never
stalls the pool).

- **Record fixes by scope — code stays UNSTAGED (never `git add`/`git commit`):**
  - **Per-run fix** (one crash's diff in this campaign): **feel free to apply bug fixes directly to the
    local ARC/RMG checkout** to unblock the pool — just **never commit/push them**. Leave every edit
    **unstaged** and log it in a **per-project `FIXES.md`** with a fixed, reviewable schema so the user
    can later inspect and decide what to commit: **timestamp · bug/symptom · root cause · files touched
    · the fix (inline unified diff or a `git -C <repo> diff -- <file>` pointer) · which instance(s) it
    unblocked.** Re-apply unstaged fixes after a fresh checkout. (The user reviews accumulated edits via
    `git -C ~/Code/ARC diff` after several runs — keep `FIXES.md` the faithful index of that diff.)
  - **Validated, generalizable learning** (a genuinely new failure mode + fix, or a confirmed
    config/queue/LOT gotcha): **consolidate it into the vault** per the runbook — **merge and
    integrate into the relevant existing section, don't append duplicates; confirmed-only, never
    speculation.** Put OL/zeus-environment issues in `Code/ARC/ARC on OL — Zeus Troubleshooting &
    Knowledge.md` (its newest-at-top log) and general ARC/RMG code/failure-mode learnings in
    `knowledge/wiki/Running ARC On Zeus.md` (§4–5 bug catalog). This vault update is silent (no Slack).

## Issues ledger (`ISSUES.md`, per project) — human follow-up
The per-project **`ISSUES.md`** is the human punch-list for after the run, distinct from `STATUS.md`
(live job ledger) and `FIXES.md` (code-fix log), and **finer-grained** (one instance may be fine yet
have a single unconverged species or a TS ARC couldn't locate). **Never silently drop a failure:**
whenever you park a problem rather than solve it — an **unconverged species**, a **TS not found**, a
`blocked`/`crashed` instance, or a **scientifically questionable result** — add a row (item · type ·
what happened/what was tried · suggested human action · `arc.log`/job-dir pointer). At completion,
finalize the **wins** summary (accepted k(T)/k∞/thermo) + counts. This is what the user works from
afterward; keeping it current is **silent** (no Slack).

## `REPORT.md` (per project) — the single clean human deliverable
`STATUS.md`/`ISSUES.md`/`FIXES.md` are **working files**; `REPORT.md` is the **one thing the user
reads** when a campaign finishes (or pauses). Generate/refresh it at any terminal state and on PAUSED.
Keep it **minimal, skimmable, and informative** — fixed sections, newest decisive facts first, no
process noise:
- **Wins** — what converged and was **accepted** (k(T)/k∞/thermo) with the LOT, one line each.
- **Didn't converge / blocked** — each unconverged species, TS-not-found, or `blocked`/`crashed`
  instance with **why** (root cause in plain terms) and a **recommendation** (next LOT, adapter, manual
  step), and a job-dir/`arc.log` pointer.
- **Code fixes applied** — concise list mirroring `FIXES.md`, plus a `git -C ~/Code/ARC diff --stat`
  (and RMG-Py if touched) snapshot so the user sees every accumulated unstaged edit at a glance before
  deciding what to commit.
- **Deviations** — any LOT/method changes (sibling folders) and their outcome.
- **Next actions** — the short human punch-list distilled from `ISSUES.md`.

The completion `slack-notify` (below) is a one-line pointer to this file; do not paste the report into
Slack. Writing/refreshing `REPORT.md` is **silent** (no Slack of its own).

## Success criteria — scientific correctness is the bar
Mark an instance `processed` only when the result exists **and** is scientifically sane (per the
runbook): rates → Arkane k(T); TS has exactly one imaginary freq of the right mode; IRC connects the
intended reactants↔products; rotors treated; SP at the intended high level. Thermo → NASA polynomials;
true minima; sane vs the estimate replaced. Never accept a converged-but-wrong number.

## Scientific diagnosis & input deviations (slack-ask before deviating)
Beyond pass/fail, **diagnose result quality and deep-think** about whether the LOT fits the goal.
Example: for a rate goal, a **TS T1 diagnostic > 0.02 at CCSD(T)** signals multireference character —
the single-reference LOT is suspect → recommend a higher-level method (e.g. **MRCI** or **HEAT**).
**Any** proposed departure from the original `input.yml` (LOT/basis/method) must be **diagnosed,
reasoned, and confirmed via `slack-ask`** before running — never changed silently.

**Deviation runs — folder convention:** restart in place for resume, but **never delete a run**. To
change an input, create a **new sibling subfolder** with a related name (`xt1001` → `xt1001b`, `…c`),
**comment in the new `input.yml` what changed and why** (header), keep the original intact for
diagnosis, and add an `INDEX.md`/`STATUS.md` row linking child→parent.

## Post-processing & teardown
Tag pressure-dependent (unimolecular) entries `elementary_high_p=True` via the project's
`add_elementary_high_p.py` before consolidating. When all instances of a project are done, merge their
per-instance RMG libraries into one project library reusing **T3**'s
`t3/utils/libraries.py` (`append_to_rmg_library` / `append_to_rmg_libraries`). When the **whole pool**
is terminal, **revert** the uncommitted `scheduler.py` poll edit (`git -C ~/Code/ARC checkout --
arc/scheduler.py`); re-apply on any restart/resume. **Resume after outage:** read `STATUS.md`,
re-launch every non-`processed` instance, re-run pre-flight.

## Slack policy — minimal, high-signal (every message means "needs me")
Invoke the existing **`slack-ask`** / **`slack-notify`** skills (they post as the bot via
`$HOME/.claude/bin/cc-slack-post.py` to `#cc-comm`). Send Slack **only** in these cases:
1. **Real blocker** (zeus unreachable, broken `~/.arc/settings.py`/branches, a failure surviving the
   fix→restart budget, near the zeus hard quota, an ambiguous result you can't safely accept or reject,
   any infra loss that stalls the run). Record it in `STATUS.md` first. **Mode matters:**
   - **Interactive (single session): `slack-ask`** (blocking) — pause + wait, resume per the reply.
   - **Supervised (poll-loop): `slack-notify`** the blocker + **set state `PAUSED`** (do **not** block
     on `slack-ask` — it would stall the one-pass timeout). The supervisor then waits for you to fix it
     and flip state back to `RUNNING`; the next pass re-evaluates.
2. **Scientific deviation → `slack-ask`** (confirm first; supervised → `slack-notify` + `PAUSED`): a
   diagnosed LOT/method change or any departure from the original input. Present diagnosis +
   recommendation; on approval, spawn the new sibling-folder run keeping the original.
3. **Campaign finished → `slack-notify`** (one line): `processed`/`blocked` counts + a **pointer to
   `REPORT.md`** and where the consolidated libraries are. With a shared pool, notify when the whole
   pool is terminal. Do not paste the report body into Slack.
4. **Long-run liveness → `slack-notify`** (at most **once/day**): for multi-day campaigns, a single
   terse "still alive — N processed / M running / K blocked" so silence never means "stuck or dead."
   Throttle to one per 24 h; skip if the pool finished or paused that day (those already notify).

**Otherwise: no Slack.** Normal progress, routine auto-fixes, quota warnings below the threshold, and
per-pass heartbeats go to `STATUS.md` only — do not spam the channel.

## Related
Vault: `[[ARC Campaign Runbook]]` · `[[Running ARC On Zeus]]` · `ARC on OL — Zeus Troubleshooting`.
Slack: `slack-ask`, `slack-notify`. Bundled: `arc_babysitter.sh` (supervisor poll-loop) ·
`arc-babysitter.service` (reboot-resilient systemd user unit). Deliverable: per-project `REPORT.md`.
