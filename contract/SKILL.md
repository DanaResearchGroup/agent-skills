---
name: contract
description: Use before changing code for anything bigger than a typo, when writing a subagent dispatch brief, or when closing work out against its Verifier.
---

# Contract

The expensive failure is **correct code, wrong thing**: a clean implementation of a misread
request, discovered only after the tokens are spent. A contract spends a little definition up
front to save the rework.

Announce: "Using contract to define the work before implementing."

## Procedure

**1. Explore first.** `Read`, `Grep` and `Bash` are never gated: the gate stops you writing
before you have read, nothing more. An Intent written without reading the code is the misread
it exists to catch.

**2. Negotiate the fields with the user.** Intent, Verifier, Non-goals, and Gates are always
present. Premise is conditional — include it whenever the work rests on a load-bearing claim
worth checking; skip it when the ground is already firm.

- **Intent** — one paragraph *in your own words*. Restate the request; a paraphrase makes a
  misread visible where a verbatim echo hides it. When the user corrects your restatement, the
  skill has just paid for itself.
- **Premise** *(conditional)* — the load-bearing claim the work rests on, the cheapest check
  that would kill it, and that check's result. See [probe](../probe/SKILL.md) for how to run the
  check. Most tickets rest on nothing worth probing: **omit the field entirely** rather than
  writing `none`. An honest omission beats a ritual line, and a field that is always present
  is a mandatory field wearing a conditional label. Carry it when skipping it would mean
  building on an unverified premise. `contract new` seeds a placeholder comment for this field;
  answer it with a real `## Premise` section or delete the placeholder block outright — `contract
  lint` fails on the sentinel if the boilerplate survives untouched, so omission stays legal but
  indecision does not.
- **Verifier** — a command plus its expected outcome, or an artifact plus what makes it
  correct. "Tests pass" is not a verifier; a command that exits 0 is. Where none exists yet,
  write one or name the artifact review that makes correctness visible — and if you catch
  yourself inventing a verifier to fill the field, say so out loud. That invention is the
  failure this skill exists to catch.
- **Non-goals** — answer every category in [landmines](reference/landmines.md), or mark it
  N/A. Free text decays into boilerplate; the checklist names the real landmines.
- **Gates** — what needs explicit approval before execution: pushes, merges, deletions, schema
  changes, spend, work on a shared branch.

**3. Open the note.**

```bash
contract new <slug>
```

Fill it in. The gate opens as soon as the note exists.

**4. Implement.** Dispatching a subagent? Paste the contract, then a `paste below this line`
marker, then the task detail the worker sees, then:

```bash
contract lint <brief-file>
```

Lint scans only what the worker sees — the region below the `paste below this line` marker (the
same marker `pm-creator`'s briefs carry; with no marker the whole file is worker-facing). It
flags leaked bare identifiers (`I-005`, `D-012`) there and a missing Verifier anywhere in the
brief — a `## Verifier` heading and a `**Verifier.**` prose label both count. It cannot check
phrasing, so hold that rule by hand: **a worker sees only the brief.** Below the marker every
noun resolves from the brief's own text or the filesystem — absolute paths and SHAs, never a
label that lives only in this conversation.

Workers report in three sections — **Completed / Verification / Remaining work** — where
Verification is the verifier command actually run, plus its actual output.

**5. Close.** Run the verifier, paste its real output under `## Evidence`, then:

```bash
contract close
```

`close` refuses while Evidence is empty. Treat a worker's self-report as intake, not truth:
corroborate anything load-bearing yourself with `git log` or by re-running the verifier.

Walking away instead of finishing? `contract abandon "<reason>"` archives the note and re-arms
the gate, so a stale contract never leaves the worktree ungated.

## The escape hatch

```bash
contract skip <session_id> "<reason>"
```

Unblocks one session and leaves a permanent log entry. Spend it freely on real typos.
"Impatient, context is thin" is the moment **correct code, wrong thing** is most likely, and
the log is what makes that pattern visible later.

It is also the only bypass that leaves a record, which is what makes it the only one to take: a
file written via `Bash` lands the same edit and leaves nothing behind, and a gate nobody can see
being skipped has already stopped working.

## The Verifier is the ceiling

The Verifier bounds the work, it does not merely end it. Of every component you are about to
build and every decision you are about to escalate, ask: **does this change whether the
Verifier passes?**

- No → **YAGNI**. Say so, record it under Non-goals, and leave it unbuilt. If it was a
  decision rather than a component, make it yourself and note it, rather than spending the
  user's attention.
- Yes → build it, or ask with concrete options and your recommendation.

Adding a helper, a migration, a compatibility shim, or a second mechanism "while we're here"
is **yak shaving** with extra steps. **Offer the cut instead** — the smallest thing that passes
the Verifier, with what you are leaving out named. Deletion is a cut too, and usually cheaper
than the migration you were about to write. Unsure whether something is in scope? It is not;
offer the cut and ask.

This skill's own construction is the worked example. Its dispatch-brief linter grew an
English-phrase check no Verifier needed, which then cried wolf on `"the ticket price"` — and
the question of how to tune it went to the user while the gate, the part that actually catches
**correct code, wrong thing**, was already finished and green. Cutting the check was the move,
twice over.

## Scale

| Shape | Use |
|---|---|
| typo, rename, one-line fix | `contract skip` |
| one ticket, one worktree | this skill |
| feature, unknown shape | `superpowers:brainstorming` + `superpowers:writing-plans` |
| multi-repo, multi-agent campaign | `pm-creator` |

Field names match `pm-creator`'s ledger exactly, so a ticket that outgrows this tier moves into
the PM repo with no translation.

## Installing

See [install](reference/install.md). The gate is opt-in per repo, keyed on the shared git dir —
enabling one repo covers all of its worktrees.
