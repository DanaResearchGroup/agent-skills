---
name: probe
description: Probe a load-bearing premise empirically before proposing or building on it — a claim that is pleasingly convenient, a design's central technical question, a conditional finding whose antecedent needs checking here, or a novelty/prior-art claim inherited from your own evidence base. Use in the same turn you form a recommendation, not after it is accepted; for a check too large to run inline, see references/commissioning-research.md.
---

# Probe

A probe is a cheap empirical check run against a load-bearing premise before it enters your
reasoning. The doctrine — probe before building — lives in the user's global instructions; this
is the procedure.

**Timing is the lever.** A probe run inside the same round that forms a recommendation costs one
round of reasoning. The same probe run after the recommendation is accepted costs a full decision
cycle plus a retraction. Probe *before proposing*, not before committing.

**The tripwire is convenience.** When a premise is the load-bearing step of a recommendation you
are about to make, and it is exactly what the argument needs, that is the trigger to probe it —
in the same turn, not the next one.

## Procedure

1. **Name the load-bearing claim.** Of the premises under the recommendation, which one, if
   false, changes the answer? Probe that one, not the easy one beside it.

2. **Cheapest probe first.** Before commissioning a search, try to refute the claim by one line of
   derivation on its own terms — arithmetic, a derivative, a Bayes update.

3. **Audit inherited claims.** A claim you are carrying from your own evidence base — a novelty
   claim, a "no prior work found," a summary written by an earlier pass — is not verified because
   it is written down. Check its own provenance tag (inference vs. search) before it does more
   work.

4. **Re-run prior art when the frame changes fields.** If the current framing moved the problem
   into an adjacent field, the old literature sweep does not cover it. Re-run from scratch in the
   new field; do not patch the old sweep.

5. **Resolve conditionals now.** A finding of the shape "X degrades when Y" is a live query, not a
   settled fact, until you check whether Y holds *here*. Do it at the moment you hold the finding,
   not later.

6. **Kill-check before deep adjudication.** Before reasoning at length about a technical question,
   ask whether a cheap measurement settles it outright. If a measurement gate exists, run it
   first; prose adjudication is only for what survives the gate.

7. **Pair the thesis with its kill-test.** When you land on a synthesis, state in the same move
   what observation would break it. A synthesis with no attached falsification is a single point
   of failure.

8. **Report retrieval status.** State what you searched, what came back, and — first, in bold —
   what you could NOT reach. An unstated hole reads as a covered one.

9. **Default to inverted — for what's unverified.** Treat an unverified load-bearing premise as
   likely wrong and plan for the inversion, not the confirmation. A directly observed fact — a
   test failing at a known line, a stack trace — needs no inversion ceremony, just a fix. A
   premise that cannot be probed empirically is a design risk to surface, not a footnote to drop.

## When the probe inverts the premise

Don't just note it and move on — the repair is part of the record, paired with the evidence that
killed the premise. See [`../domain-modeling/SKILL.md`](../domain-modeling/SKILL.md) for where
that retraction belongs.

## Too big to run inline

When the check requires a real literature or codebase sweep rather than a one-line derivation, see
[`references/commissioning-research.md`](references/commissioning-research.md) before dispatching
it.
