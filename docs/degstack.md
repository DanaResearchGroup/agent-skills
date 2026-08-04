# Removing gstack

A staged migration off gstack, so this repo owns the skills it actually runs.
This document is the plan of record; each phase lands as its own PR.

## Why

`~/.claude/skills` is a symlink to this repo, but `/review`, `/ship`, `/spec` and
about fifty other live skills are not ours: `gstack/` is gitignored here and owned
upstream, `review/SKILL.md` is a symlink into it, and that file is itself
auto-generated from `SKILL.md.tmpl`. Three layers deep, there is nowhere to put a
fix that survives — an edit to the generated file dies at the next
`gen:skill-docs`, an edit to the template dies at the next `gstack-upgrade`.

That stopped being theoretical. gstack's review skill dispatches every specialist
as `subagent_type: "general-purpose"` with no model field anywhere in it, so each
one inherits the session model. On an Opus session reviewing a two-source-file PR,
that meant seven Opus subagents and a mid-run abort. The fix is model routing per
specialist — which depends on the four role agents in `~/.claude/agents/`, which
are ours and which upstream has no reason to know about.

## What is actually coupled

The raw number is alarming and the shape is not. 56 live skills invoke
`gstack/bin/*`, but almost entirely through one ~100-line preamble copy-pasted
into every skill, which calls sixteen binaries before any skill does any work:
upgrade checks, telemetry, activation markers, proactive prompts, routing
injection, host adaptation, vendoring warnings. Every one of those is worth
nothing here — telemetry is off, one user, one host, no team — and it is why
`review/SKILL.md` is 105 KB, roughly 26k tokens loaded before it reads a line of
diff.

Strip the preamble and the real substrate is small:

| binary | used by | keep? |
|---|---|---|
| `gstack-slug` | everything, incl. our `autodev` + `spar` | **yes** — vendored |
| `gstack-codex-probe` | our `spar` | **yes** — vendored |
| `gstack-diff-scope` | review-family skills | yes, when `/review` is rebuilt |
| `gstack-review-log`, `gstack-learnings-*`, `gstack-specialist-stats` | review-family skills | yes, when `/review` is rebuilt |
| the other ~68 | gstack's own ceremony | no |

`gstack-session-update` — the global `SessionStart` hook in
`~/.claude/settings.json` — turned out to be nothing but a throttled `git pull` of
gstack. It has no other function, so it gets deleted rather than replaced.

## Phases

### Phase 0 — cut the hard dependency (this PR)

Our own skills stop needing gstack on disk.

- `bin/skill-slug` — vendored from `gstack-slug`. The slug **algorithm is
  preserved byte-for-byte**: project memory is keyed by slug, and changing it
  would silently detach every accumulated learning from its project. Verified to
  produce output identical to `gstack-slug` in a real repo.
- `bin/skill-codex-probe` — vendored from `gstack-codex-probe`, minus telemetry
  and the hang-handler that wrote through gstack's learnings store.
- `bin/migrate-gstack-state` — copies `~/.gstack/{projects,slug-cache}` to
  `~/.skills/`. Never deletes from the source, never overwrites in the
  destination. `diff -r` verifies clean; re-running copies 0 and skips 170.
- `autodev` and `spar` repointed at the vendored copies. Both call sites already
  had basename fallbacks, so neither can hard-fail.
- Fixed a live bug found while repointing: `spar` *executed* `gstack-codex-probe`,
  which only defines functions — it printed nothing and returned 0, so the
  `AUTH_FAILED` check could never fire. It is now sourced.

Also done outside this repo, and reversible: `gstack-config set auto_upgrade
false`. The SessionStart hook had been pulling gstack hourly, which would have let
it churn under the migration.

Not done in Phase 0: `diff-scope`, `review-log`, `learnings-*` and
`specialist-stats` are deliberately left behind. They are only consumed by the
review-family skills, and their shape should be decided *with* the new `/review`
rather than ported first and retrofitted. Vendoring them now would mean designing
the substrate before the thing that uses it.

### Phase 1 — rebuild the skills we actually run

One at a time, each discussed before it is written and put through
`/writing-great-skills`. Order is by demonstrated pain. Each rebuild keeps
gstack's checklist prose — that content is data, it is good, and copying it
carries no dependency — and drops the preamble entirely.

**`/review` — done.** Ours now: `review/` is tracked, removed from the gstack
block in `.gitignore`, and the symlink into `gstack/review/` is gone. It is
user-invoked (`disable-model-invocation: true`), so it costs no context in any
turn of any session.

What it gained that upstream could not give it:

- **Breadth, not length.** Agent count scales on distinct non-test source files,
  with a hard cap per tier. Validated against the PR that motivated this: 2 files,
  T1, cap 3 — against the 7 Opus agents that actually ran.
- **Legwork vs judgment.** A pass that earns its value by *running* things routes
  to sonnet or haiku; a pass that earns it by *reasoning* adversarially gets opus.
  The highest-value pass in that review was mutation testing — pure legwork.
- **A dispatch plan printed before any agent launches**, so the spend is a
  one-keystroke veto rather than a mid-run interruption.
- **Executed or it is not P0.** A CRITICAL finding must quote output from
  something that was run. Two confident P0 candidates in that review evaporated on
  execution.
- **Mutation testing**, which gstack's testing checklist does not mention at all,
  with the instruction that matters: mutate *order*, not just presence.

After a few real PRs, decide what else earns a fork. Everything not forked keeps
running off gstack until Phase 2.

### Phase 2 — delete

Remove `gstack/`, drop the `SessionStart` hook, and cut the 35-skill
advertisement from the global `CLAUDE.md`. The ~46 gstack skills we never forked
go with it, which is the intended outcome — they were never ours and mostly never
used.

## Verifying before you delete anything

```bash
bin/migrate-gstack-state --dry-run          # writes nothing
bin/migrate-gstack-state
diff -r ~/.gstack/projects   ~/.skills/projects     # must be silent
diff -r ~/.gstack/slug-cache ~/.skills/slug-cache   # must be silent
```

At time of writing that is 19 projects, 48 learnings, 33 review records and 23
timeline entries — including the 15 gracie learnings that caught the
Hypothesis-blind-CI pitfall. `~/.gstack` is never modified by any of this; removing
it stays a separate, deliberate act.
