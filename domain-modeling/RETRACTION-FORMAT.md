# Retraction Record Format

A retraction is not an ADR — no decision was made; a claim died. It lives in `RETRACTIONS.md` at the same root as `CONTEXT.md`, a single append-only document created lazily when the first claim is refuted.

## Template

```md
## {The claim, stated as it was asserted}

**Refuted by**: {the evidence, probe, or check that inverted it}
**Use instead**: {the repaired formulation}
```

## Example

```md
## The write model can stay in-process; nothing needs a queue

**Refuted by**: load test showed p99 write latency at 4x the budget once concurrent
callers exceeded 20 — the in-process path serializes on a single lock.
**Use instead**: writes go through a queue; the in-process path is the read model only.
```

## When to append

Whenever a probe or a check inverts something already written down — in `CONTEXT.md`, an ADR, or prose earlier in the session. Append immediately, not at session end.

## What matters

The repaired formulation is the load-bearing part. An entry that only says "this was wrong" lets the next session re-derive the same wrong thing. As with ADRs, the value is in recording *that* and *why* the claim died — not in filling out sections beyond the three above.

## Two homes, one write

A `pm-creator` campaign repo tracks refuted claims in its own `INSIGHTS.md` (status `retracted`).
When the same domain claim is tracked in both a campaign record and this codebase's
`RETRACTIONS.md`, write the retraction once — in whichever record the claim was originally
*asserted* — and cross-link it from the other, rather than duplicating the entry in both.

## Mark the original dead

A retraction entry alone doesn't stop a future session reading only `CONTEXT.md` or an ADR from ingesting the dead claim as live — mark the original in place too, pointing at its `RETRACTIONS.md` entry:

- **Glossary entry in `CONTEXT.md`**: prefix the definition with `[RETRACTED — see RETRACTIONS.md #N]`, N being the entry's position (first, second, ...).
- **ADR**: mark its status Retracted (or Superseded, if a replacement ADR exists) with a pointer to the same entry, the same way a superseding ADR is recorded.
