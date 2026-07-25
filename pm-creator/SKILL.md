---
name: pm-creator
description: Scaffold a self-resuming <campaign>-pm control-plane repo (event-log state, dispatch identity, human-gated dispatch lane) for overseeing a multi-repo, multi-agent campaign.
disable-model-invocation: true
---

# pm-creator

Generate a **manager repo**: a control plane for one session that oversees a multi-repo,
multi-agent campaign — owning state + coordination, never product code. This skill runs
ONCE per campaign to scaffold the repo, then bows out; the generated repo is self-resuming
and drives campaigns on its own via its `RESUME.md`.

The generated repo's law and rationale live in `templates/CONVENTIONS.md.tmpl` and
`references/essence.md` — read `references/essence.md` before step 1 so the design choices
read as deliberate. Grammar of the authoritative state record:
`references/event-log-grammar.md`.

Announce "Using pm-creator to scaffold a <campaign> manager repo", then work the steps in
order. Create a todo per step.

## Step 1 — Grill the config (via grill-with-docs)

Invoke the `grill-with-docs` skill to interview the user and record the decisions as ADRs +
a glossary. Extract every value the templates need:

- campaign name + slug
- the repo list, each with its **mainline branch** and absolute path, plus (for `track`'s
  shipped auto-close merged-predicate) a full **mainline ref** — `refs/remotes/<remote>/<mainline>`
  for a pushed/fetched workflow or `refs/heads/<mainline>` for local-only — and a **fetch
  policy** (e.g. `fetch` or `local-only`); never a short `main`.
  ⚠️ **Probe each repo; do not assume.** Two premises fail often enough that you should treat
  them as likely-wrong until measured, because both fail *silently* — a mainline ref that never
  resolves corroborates nothing and reports nothing:
  - **The remote is often not called `origin`.** Run `git -C <path> remote -v`. Group workflows
    routinely use `official`/`upstream` for the canonical repo alongside a personal fork.
  - **The mainline is often not `main`.** Long-lived integration branches (`polymer`, `develop`)
    are where work actually lands. Ask "where does work land?", not "what's the default branch?"

  You may omit `mainline_ref` and let `scaffold.sh` derive it by probing the repo — it uses
  what is actually there, and **fails loud** if the branch exists on several remotes (it will
  not pick between a canonical remote and a fork for you) or on none. Supplying it explicitly
  is still better when you know the answer; scaffold then honours it verbatim and only warns if
  it does not resolve today.
- per-repo **merge_mode** (`merge` = strict-ancestry auto-close only, the default; `squash` =
  additionally accept the human-attested `merged`-marker arm) and
  **allow_marker_branch_deleted** (bool, default false: may a marker-path close proceed after
  the ticket branch was deleted post-squash?) — a squash-workflow campaign that keeps the
  default `merge` can never auto-close
- the **automation block** (`AUTOMATION_JSON`): `auto_close` + `auto_spawn` (both default
  **false** — ask explicitly whether this campaign opts in), `max_live_workers`,
  `spawn_ack_timeout_ticks`, and `spawn_argv` (must contain the literal `{prompt}` element
  when auto_spawn is on). Two things worth getting right here:
  - **`spawn_argv` is argv, not a shell line**, and `{prompt}` is substituted as a *whole
    element* (replaced with the durable prompt's **absolute** path). Since `claude` takes a
    single positional prompt, the working shape is a `bash -lc` wrapper that receives the path
    as `$1`:

    ```json
    ["bash", "-lc",
     "exec claude \"Read the dispatch prompt file at $1 and carry it out exactly as written. Report back in three sections: Completed / Verification / Remaining Work.\"",
     "pm-worker", "{prompt}"]
    ```

    (`bash -lc SCRIPT NAME ARG` sets `$0`=NAME, `$1`=ARG.) Note the worker starts with default
    permissions and will therefore **stop at permission prompts** — fine when someone is
    watching, a stall when the point was an unattended background fleet. Raise it with the
    user as a deliberate choice rather than deciding it for them.
  - **`max_live_workers` counts every live agent in the workspace**, including hand-spawned
    ones, not just auto-spawned. Size it against the actual constraints — API rate limits and
    how many returning results a human can review — rather than CPU, since agent sessions are
    near-idle processes. Set it as a runaway bound comfortably above expected concurrency; a
    cap tight enough to throttle a planned day-one fleet costs real time for no resource
    reason.
- worktree root (default `~/Code`), runs root (only if long-running jobs — see optional slots)
- herdr workspace — ⚠️ grill for the workspace **id** (`herdr workspace list` → `workspace_id`,
  e.g. `w7`) in preference to its human label. `herdr`'s CLI resolves `--workspace` by id
  only. `track` resolves a configured label to an id from the snapshot's `workspaces[]` before
  spawning, so a label usually works — but it falls back to passing the value through
  unchanged when the snapshot carries no `workspaces[]`, and a label then fails every spawn
  with `workspace_not_found`/`herdr-tab-create-failed` while `reconcile`, which accepts
  either, still looks healthy. An id needs no resolution and cannot reach that fallback
- model-routing defaults (offer a Haiku/Sonnet/Opus/Fable-by-work-shape table; flag it
  rot-prone)
- capacity profile (hardware, parallelism ceiling) → `MACHINE.md`
- the campaign's path (its through-line/end state), high-level milestones, and an initial
  workplan — devise these WITH the user, not for them; seeds `STRATEGY.md`
- per-issue **verifiers** and **approval gates** for the initial issues (and as the standing
  habit for every issue filed later): a verifier is the concrete command, check, or artifact
  that proves the issue is done; approval gates are the actions that require explicit user
  approval — devise these WITH the user, not for them; they live on each `LEDGER.md` issue
  and are carried into every dispatch prompt (`CONVENTIONS.md` §4/§9)
- remote policy for THIS PM repo: local-only, or a **private** GitHub repo
- per-repo upload policy + always-human gates (merges to shared branches, pushes, NEEDS-USER)
- which optional slots are active: `RUNS.md` (long jobs), `MACHINE.md` (heavy compute).
  Slot activation is carried by three placeholders (so an un-activated scaffold ships zero
  dangling references): `OPTIONAL_SLOT_NOTE` (RESUME reading list, e.g.
  `` , `RUNS.md`, `MACHINE.md` `` or empty), `OPTIONAL_SLOT_ROWS` (README layout-table rows
  for the active slots, or empty), and `CAPACITY_NOTE` (the whole CONVENTIONS capacity
  bullet — name `MACHINE.md` in it only when that slot is active)

**Completion:** every `{{PLACEHOLDER}}` in `templates/` maps to a concrete grilled value,
and the user has confirmed the repo list + mainlines + remote policy. No placeholder is left
to a guess.

## Step 2 — Fix the target and confirm

Target path defaults to `<worktree_root>/<slug>-pm`. Confirm it doesn't already exist (if it
does, STOP — this skill is create-only; do not overwrite). Restate the remote policy for
explicit confirmation, since a private-GitHub choice will push campaign state.

**Completion:** an unused absolute target path + a confirmed remote decision.

## Step 3 — Scaffold the repo

Materialization is deterministic — do NOT hand-interpolate. Write a `values.json` (a flat
object with one key per `{{PLACEHOLDER}}` — see the full list with
`grep -rhoE '\{\{[A-Za-z0-9_]+\}\}' templates/ | sort -u` (the same character class
`scaffold.sh` itself matches — keep the two in lockstep); structured keys `REPOS_JSON` and
`AUTOMATION_JSON` carry a pre-rendered JSON string), then run the skill's scaffolder:

```
scaffold.sh --values <values.json> --out <target_dir>
```

It interpolates every template, copies `bin/*` executable, writes `.gitignore` + `.pm/`
config, seeds `.pm/events.log` with its schema header, and FAILS LOUDLY if any placeholder
lacks a value or any `{{...}}` survives. Then, in the target, IN THIS ORDER: (1) delete the
optional slot files (`RUNS.md` / `MACHINE.md`) the user did not activate, so they never enter
history; (2) `git init`, stage, one initial commit; (3) if the remote policy is a private
GitHub repo, create it **private** and push, otherwise add no remote.

**Completion:** `scaffold.sh` exited 0, the target is a git repo with an initial commit,
`bin/` is executable, `.pm/events.log` carries only its header, and `grep -rn '{{' <target>`
finds nothing.

## Step 4 — Verify the generated repo

From the target repo, run `bin/ledger-check` (must exit 0 on the empty-but-valid log) and
`bin/reconcile --allow-degraded` (must fold the header-only log and render the empty
generated blocks without error). The `--allow-degraded` flag is correct — and required on a
machine without `herdr` — at scaffold time: a fresh repo has no herdr sessions yet, and
plain `bin/reconcile` hard-fails by design when herdr machine-readable output is
unavailable. Fix any scaffolding defect before handing off.

**Completion:** `ledger-check` and `reconcile` both exit 0, and `grep -rn '{{' .` finds
nothing.

## Step 5 — Hand off

Tell the user: the repo path, the remote disposition, and **how to actually start the
manager** — do not just say "it's self-resuming" and stop, because the first question after
handoff is invariably *how do I run this thing?* The manager is a plain Claude Code session
whose cwd is the generated repo; there is no daemon and nothing to install. Give them the
literal commands:

```bash
# In the campaign workspace (get the id from `herdr workspace list`):
herdr tab create --workspace <workspace-id> --label <slug>-PM

# In that tab:
cd <repo path>
claude "Read RESUME.md in this directory and resume as the campaign manager."
```

Say the three things that are not obvious from those commands:

- **Cwd matters.** The `bin/` tools find the repo by searching upward from `$PWD` for `.pm/`,
  so a session started elsewhere will not see the ledger (`PM_ROOT=<repo>` is the override).
- **Run one manager at a time.** Concurrent managers do not corrupt the log — the lock holds —
  but they will make contradictory plans. Workers are what you run many of.
- **Without herdr, step 2 alone still works.** You lose the automation lane (auto-spawn needs
  herdr); every `bin/` tool and the whole human-gated lane are unaffected.

The same block is at the top of the generated `RESUME.md`, so it survives the conversation.
Then state plainly that this skill is done and the repo is now self-resuming. Bow out — do not
stay on as the manager.

## Scope note

This scaffolds the **Phase-A core**: event-log state, dispatch identity, and the
human-gated lane, with `reconcile` / `lint-prompt` / `ledger-check` / `dispatch-prep` /
`record` / `close` / `track`. Automation-lane **auto-close and auto-spawn ship and work**
(via `track`), but both default **OFF** in `automation` — they run only when the operator
opts in at grilling time. Only a `doctor`/`diff` drift check remains a later phase; do not
promise that one as working in the generated repo.
