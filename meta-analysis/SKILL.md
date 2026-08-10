---
name: meta-analysis
description: Analyse how a long design conversation or campaign moved, and produce a living document tracking what changed its trajectory and why.
disable-model-invocation: true
---

Fire this at a milestone, a campaign's end, or whenever the process itself — not the output —
needs examining. It does not restate what was decided; it points at the documents that do, and
analyses how the conversation got there.

## Before writing

Name the documents this analysis will point at instead of duplicate (design doc, roadmap, decision
log, evidence base). Every section below cites them by path rather than restating their content.

**Output.** Write to `docs/meta-analysis/<slug>.md`, `<slug>` naming the conversation or campaign.
If that file already exists, this is a re-run, not a new analysis: update it in place (§9) so two
runs converge on one document instead of spawning rivals.

**Done when** every numbered section below has content, or an explicit `N/A — <why>`, and the
ledger (§2) and predictions (§8) reflect this run.

## 1. Timeline from artefact evidence

Reconstruct the shape from sources that survive a clone, checkout, copy, scaffold, or archive
move: `git log`, `git log --follow` for renamed files, dated content inside the documents
themselves, tracker or issue timestamps. File mtimes (`ls -la --time-style=full-iso`) report when
a file arrived on *this* disk, not when the work on it happened — a clone, checkout, copy, or
archive move resets them to the operation's own time, which silently inverts the timeline while
looking like evidence. They are usable only when you can confirm nothing has moved, copied, or
re-checked-out the files since the work happened; state that check explicitly if you rely on them,
and prefer the commit/tracker record whenever one exists. Compute the headline yield ratio while
you're at it: how much of the final corpus's durable content came from what fraction of the
elapsed time or word count.

Done when the timeline is built from at least one mtime-independent source, or the mtime-reliance
check is stated explicitly.

## 2. Ledger of inflection points

One row per point where the trajectory changed: what changed, a cause code, what it changed. The
cause code is what turns a narrative into a distribution — pick from (or extend): EXT (external
stimulus) · RED (user redirection) · FREE (free-form answer replacing the menu) · REJ (user
rejected the recommendation) · ACC (user accepted a strong recommendation) · SELF (agent
self-correction) · PROBE (adversarial probe against the project's own claim) · ESC (protocol
escalation) · CORR (domain-expert correction).

Then name the handful that mattered most, and say why — including, explicitly, the ones that were
agent failures. A ledger that only credits good calls is not measuring anything.

Done when every row has a cause code and at least one agent-failure row is named, or the session
had none.

## 3. Input yield scoreboard

Rank every input — source, agent pass, tool run, human message — by durable contribution per unit
of cost, into tiers. Unsentimentally: the expensive input that turned out inert and the cheap one
that carried the project are the point of this section, not an embarrassment to soften. This is
what changes how the next session gets resourced.

Done when every input above a noise threshold you state has a tier.

## 4. The question mechanism

Tabulate how decisions actually got answered: composition, free-form replacing the menu, rejection
of the recommendation, domain correction, protocol escalation, deferral, override-with-addition,
acceptance — with instance counts and yield per mode. Ask what triggers which mode. The finding is
about the *kind* of question, not its difficulty — e.g. menus survive procedural questions and fail
ontological ones. State directly whether the menu itself was ever the limiting factor, and in what
recurring shape (a common one: mutually-exclusive options where the right answer was a composition
with an ordering).

Done when the verdict on whether the menu itself was ever limiting is stated, not merely implied
by the tally.

## 5. Agent failure modes

Numbered. Each gets a detectable early signal and a tripwire that would catch it next time. A
failure mode without a tripwire is a complaint, not a finding.

Done when every numbered mode carries a tripwire.

## 6. Waste accounting

Where effort went that bought nothing, ranked by size. Then split each item: avoidable ordering
(the work was necessary but done in the wrong sequence) vs. unavoidable cost of getting the verdict
(you cannot get the answer without paying for the analysis).

Done when every item is tagged avoidable or unavoidable.

## 7. Lessons split by party

Human and agent, in separate sections, each as imperatives. Splitting is the point — it tells each
participant what only they can change. A lesson that applies to both belongs in both, restated for
what that party controls.

Done when both sections are non-empty, or the empty one says why.

## 8. Inflection points predicted ahead

Record predictions about what changes the trajectory next, so they can be scored later. Never
delete a prediction: strike it through when refuted, mark it confirmed when confirmed. A wrong
prediction left visible is worth more than a right one — it is what stops the next analysis from
citing an inverted premise.

On a re-run, score every prediction already on the list — strike through or confirm — *before*
adding new ones. A prediction list that only grows is not being checked against what happened.

Done when no unscored prediction from a prior run remains, and at least one new prediction is
recorded for next time.

## 9. Keep it live

This document is not a tombstone. New inflection points get a ledger row (§2) and, if material, a
numbered subsection. Use the append template in [`append-template.md`](append-template.md).

Done when the ledger and §8 are current as of this run and no earlier section was left stale.

## Judgement throughout

- Cite artefacts by path and timestamp — this is an evidence document, not a recollection.
- For every inflection, ask not just what changed but whether the information was already on the
  table, and for how long. The gap between *available* and *used* is usually the real finding.
- Name the agent's failures explicitly, and the human's separately. A post-mortem that flatters
  either participant is worthless.
