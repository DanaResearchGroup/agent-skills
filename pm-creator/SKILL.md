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
  shipped auto-close merged-predicate) a full **mainline ref** — `refs/remotes/origin/<mainline>`
  for a pushed/fetched workflow or `refs/heads/<mainline>` for local-only — and a **fetch
  policy** (e.g. `fetch` or `local-only`); never a short `main`
- per-repo **merge_mode** (`merge` = strict-ancestry auto-close only, the default; `squash` =
  additionally accept the human-attested `merged`-marker arm) and
  **allow_marker_branch_deleted** (bool, default false: may a marker-path close proceed after
  the ticket branch was deleted post-squash?) — a squash-workflow campaign that keeps the
  default `merge` can never auto-close
- the **automation block** (`AUTOMATION_JSON`): `auto_close` + `auto_spawn` (both default
  **false** — ask explicitly whether this campaign opts in), `max_live_workers`,
  `spawn_ack_timeout_ticks`, and `spawn_argv` (must contain the literal `{prompt}` element
  when auto_spawn is on)
- worktree root (default `~/Code`), runs root (only if long-running jobs — see optional slots)
- herdr workspace name
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

Tell the user: the repo path, the remote disposition, and that a manager session starts by
pasting/reading `RESUME.md`. State plainly that this skill is done and the repo is now
self-resuming. Bow out — do not stay on as the manager.

## Scope note

This scaffolds the **Phase-A core**: event-log state, dispatch identity, and the
human-gated lane, with `reconcile` / `lint-prompt` / `ledger-check` / `dispatch-prep` /
`record` / `close` / `track`. Automation-lane **auto-close and auto-spawn ship and work**
(via `track`), but both default **OFF** in `automation` — they run only when the operator
opts in at grilling time. Only a `doctor`/`diff` drift check remains a later phase; do not
promise that one as working in the generated repo.
