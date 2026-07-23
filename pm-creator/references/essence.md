# The essence — why a PM repo is shaped this way

Read this once before generating a repo, so the choices below read as deliberate, not
arbitrary. Generated from the pattern proven on a multi-repo scientific-software campaign.

## The one idea: a manager that owns state, never code

A campaign spanning several repos and many worker agents drowns a single session. The move
is to split the roles: one **manager** session owns *state + coordination and never writes
product code*; it delegates every code change to **worker** sessions. The manager's entire
substance is a **control plane** — a repo of records, not a codebase. This is the load-
bearing constraint; everything else serves it.

The manager still *acts* — it edits its own ledger and runs the `bin/` tools. "Never writes
code" means never writes *product* code, not "never mutates anything".

## Why an event log is the source of truth

The naive version stores state in Markdown tables and greps them. That is a database with no
schema, and it rots the instant a human wraps a line or fat-fingers a state. So state lives
in **`.pm/events.log`** — a strict, append-only, one-line-per-fact record that scripts parse
and humans don't. Markdown becomes pure narrative: edit it freely; the machine never reads it
for state. `.pm/index.json` is a throwaway fold of the log. On any disagreement, the log +
live git/herdr win and the prose is re-rendered. This is what makes the whole thing safe to
hand-edit.

## Why dispatch identity (`D-###` / `A-##`)

A single operator holds "which tab is doing which ticket on which branch" in their head. A
generalized tool can't. So every dispatch gets an immutable **`D-###`** that threads issue →
prompt → tab → branch → result, and each retry is an **attempt `A-##`** under it. Without the
join key, a pasted-twice or out-of-order result silently corrupts state; with it, duplicates
go to quarantine and replays are distinguishable from intent-changes (a new `D` that
`supersedes` the old).

## Why two lanes, and why the human stays

Dispatch runs through either an **automation lane** (a script spawns the worker tab and
collects the result) or a **human-gated lane** (the operator does it). Both always ship; the
operator directs which handles a given dispatch. The automation lane relieves the human
throughput ceiling; the human lane is the universal fallback and the approval gate. Certain
actions — merges to shared branches, pushes, anything marked `NEEDS-USER` — never
auto-execute in either lane. And because a human can always work out-of-band, bypass is
*detected and absorbed* (`unregistered_execution` → `adopt`), never pretended away.

## Why §8 is the crown jewel

A worker session sees ONLY the pasted prompt — no ledger, no numbering, no memory. A prompt
that leaks `I-005` or a tab name produces an agent guessing at scope. So the prompt
self-containment rules are absolute: below the paste marker, every noun resolves from the
text or the filesystem (paths, SHAs), never from an internal label. `bin/lint-prompt`
mechanizes a floor for this — necessary, never sufficient.

## What this deliberately does NOT promise

The result contract is a disciplined intake + audit trail, corroborated by an independent git
read — not a security boundary. It cannot prove tests ran, catch omitted files, or verify a
worker's self-report beyond what git shows. For a single trusted operator that is the right
trade: discipline and auditability, not cryptographic proof.
