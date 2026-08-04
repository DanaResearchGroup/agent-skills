---
name: contract
description: Use before changing code for any work bigger than a typo - agrees Intent, Verifier, Non-goals and Gates with the user and records them in a durable note, so "correct code, wrong thing" is caught before implementation rather than after. Also use when a contract gate denies an edit, when writing a subagent dispatch brief, or when closing out work.
---

# Contract

The expensive failure mode is **correct code, wrong thing**: an implementation
that matches a misread request, discovered only after the tokens are spent.
This skill spends a little up front on definition to save a lot of rework.

Announce: "Using contract to define the work before implementing."

## Any work bigger than a typo

If the gate is enabled and there is no active contract, an `Edit` or `Write`
is denied with a reason. Do not route around it through `Bash`.

## Procedure

**1. Explore first.** Exploration informs the Intent; it is never gated. An
Intent written before reading the code is a misread waiting to happen.

**2. Negotiate four fields with the user.**

- **Intent** — one paragraph, *in your own words*. Never paste the request
  back verbatim; restating is what makes a misread visible. If the user
  corrects your restatement, that correction is the whole point of the skill.
- **Verifier** — a command plus its expected outcome, or an artifact plus
  what makes it correct. "Tests pass" is not a verifier; a command that exits
  0 is. If no such command exists yet, say so (write one, or name the doc/
  artifact review that will make correctness visible) rather than inventing
  one to fill the field.
- **Non-goals** — answer every category in [landmines](reference/landmines.md),
  or mark it N/A. Free-text non-goals decay into boilerplate; the checklist
  names the real landmines.
- **Gates** — actions needing explicit approval before execution: pushes,
  merges, deletions, schema changes, spend, work on a shared branch.

There is no minimum-effort escape from the Verifier field: it must be a
runnable command. If you notice yourself *inventing* one just to fill the
field, say so out loud — that invention is exactly the failure this skill
exists to catch.

**3. Open the note.**

```bash
contract new <slug>
```

Fill in the note the command opens. The gate stops blocking as soon as it
exists.

**4. Implement.** When dispatching a subagent, paste the contract above the
task detail, then lint the brief:

```bash
contract lint <brief-file>
```

Lint mechanically checks two things: leaked bare identifiers (`I-005`,
`D-012`) that mean nothing to a fresh worker, and a missing Verifier section.
It does not check for conversation-only phrasing ("as discussed above", "the
ticket") — that check produced real false positives (`"the ticket price"`,
`"the above-mentioned constraint"`) and was cut. The underlying rule still
stands by hand, it is simply no longer machine-checked for phrasing: below
the paste marker, every noun must resolve from the brief's own text or the
filesystem — absolute paths and SHAs, never a label that exists only in this
conversation. A worker sees ONLY the brief. Workers report in three sections
— **Completed / Verification / Remaining work** — where Verification is the
verifier command actually run, plus its actual output.

**5. Close.** Run the verifier, paste its real output under `## Evidence`,
then:

```bash
contract close
```

`close` refuses if Evidence is empty. Treat the worker's self-report as
intake, not truth — corroborate anything load-bearing yourself (`git log`,
re-running the verifier) rather than trusting it verbatim.

## The escape hatch

Genuinely trivial work takes the logged escape hatch:

```bash
contract skip <session_id> "<reason>"
```

This unblocks one session and leaves a permanent log entry. Use it freely for
real typos, but not as "I'm just impatient" when context is thin — the skip
log exists precisely so that pattern becomes visible later.

## Staying on target

The Intent is the target. Before escalating any decision to the user, ask:
**does this change whether the Verifier passes?**

- No → decide it yourself, note the decision, move on. Do not spend the
  user's attention.
- Yes → ask, with concrete options and your recommendation.

Drift looks like polishing a component no Intent depends on, or asking the
user to adjudicate a detail that does not move the Verifier. When you notice
it, cut scope back to the Intent instead of perfecting the detour.

This skill's own construction is the worked example: the dispatch-brief
linter's regex false-positives were escalated to the user for adjudication
while the gate — the thing that actually catches "correct code, wrong
thing" — was already finished and green. The right move was to cut the noisy
check, not to tune it.

## Scale

| Shape | Use |
|---|---|
| typo, rename, one-line fix | `contract skip` |
| one ticket, one worktree | this skill |
| feature, unknown shape | `superpowers:brainstorming` + `superpowers:writing-plans` |
| multi-repo, multi-agent campaign | `pm-creator` |

Field names match `pm-creator`'s ledger exactly, so a ticket that outgrows
this tier moves into the PM repo with no translation.

## Installing

See [install](reference/install.md). The gate is opt-in per repo, keyed on
the shared git dir — enabling in one repo covers all of its worktrees.
