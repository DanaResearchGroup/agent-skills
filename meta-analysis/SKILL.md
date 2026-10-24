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

Name the cast before anything else: every participant — the human, the authoring agent and its
model, internal adversaries, external reviewers, worker agents — with the **model and access tier**
behind it (for example "external reviewer: the strongest model the user could reach, relayed by
hand"). Without the model names the yield scoreboard (§3) cannot tell "a harsh reviewer" from "a
different model family". If identities are disclosed late, add them and say they were.

**Output.** One analysis produces these files, sharing one `<slug>` that names the conversation or
campaign:

| File | Content |
|---|---|
| `<slug> summary.md` | the short, human-readable version (§0) |
| `<slug>.md` | the formal analysis, §§1–9 |
| `<slug> trajectory.json` | the chart data (§1) |
| `<slug> trajectory.png` | the static chart, for the summary and the PDF |
| `<slug>.pdf` | summary plus formal analysis as appendix, highlights kept (§10) |
| `<slug>.html` | the same, self-contained, with the interactive chart (§10) |

**Where.** Ask the user for the designated folder before writing anything, and wait for the
answer. Offer a dated subfolder, `<YYYY.MM.DD> <Slug>/`, inside the folder they name, and match
that folder's own file-naming convention in place of the `<slug>` names above. Inside a repo,
offer `docs/meta-analysis/` as the default. If the files already exist there, this is a re-run,
not a new analysis: update them in place (§9) so two runs converge on one document instead of
spawning rivals.

**Done when** the user named the folder, §0 and every numbered section below have content, or an
explicit `N/A — <why>`, the ledger (§2) and predictions (§8) reflect this run, and both renderings
(§10) were built and looked at.

## 0. The short version, first

Write `<slug> summary.md` for a reader who will read one page. It is the front of the PDF and
HTML, with the formal analysis behind it as an appendix. In order:

1. **Key findings**, three to five, each a bold lead-in and two or three plain sentences. Mark the
   one or two that should change how the next session runs as `==…==`; the renderers highlight
   them. If the user named the findings to highlight, use theirs.
2. **The chart** (§1), with one paragraph on how to read it, stating that the Y axis is judged.
3. **The cast** table (above).
4. **The initial prompt and the first question or goal, quoted verbatim.** They are the baseline
   every later turn is measured against; a paraphrase drifts toward what the work became.
5. **Phases**, five to seven, each with clock times, what happened, and where the question stood
   at its end. People navigate by phase; the ledger (§2) is for counting.
6. **The question-evolution table**: after each inflection that changed it, the question's (or
   goal's) wording in short form and a judged depth score. The formal sections track what changed
   the trajectory; this table shows what the trajectory changed.

Done when a reader of this page alone can say where the work started, where it ended, and which
two things mattered most.

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

**The trajectory chart.** Build `<slug> trajectory.json` from the timeline: one event per
interaction (user turn, adversarial round, external review round, returned compute result), in
order, each with its time, source, a judged depth-and-novelty score for the live question (0–10),
a short label, a one-sentence hover detail, and `key: true` on the turning points. Add markers for
compactions and long breaks. Render the static chart with
[`bin/trajectory.py`](bin/trajectory.py) (needs matplotlib); the JSON schema is in its docstring.
Use the reference categorical palette from the `dataviz` skill, one fixed hue and marker shape per
source, and run its validator. The score is a judgment: say so on the axis and in the summary,
and keep it consistent rather than precise. What the chart shows that tables do not is the shape:
early kills, the plateau where the question froze, and whether later gains came from reframing or
from evidence.

Done when the timeline is built from at least one mtime-independent source, or the mtime-reliance
check is stated explicitly, and the chart JSON covers every interaction in the timeline.

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

**Every tripwire names what it does not cover.** A tripwire is written against the failure that just
happened, and the next one arrives somewhere the tripwire cannot see — a process fix aimed at last
run's mode reads, on the next run, as protection it never offered. Say in one clause what class of
failure this tripwire would miss, so the next analysis starts from a known blind spot rather than a
false sense of coverage.

Done when every numbered mode carries a tripwire, and every tripwire states its blind spot.

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

## 10. Render the report

```bash
B=<this skill's directory>/bin
python3 $B/trajectory.py "<slug> trajectory.json" "<slug> trajectory.png"
python3 $B/md2pdf.py "<slug>.pdf" "<slug> summary.md" "<slug>.md"
python3 $B/report_html.py "<slug>.html" "<slug> summary.md" "<slug>.md" --chart "<slug> trajectory.json"
```

`md2pdf.py` needs xelatex (fontspec, soul, tcolorbox, xltabular) and the DejaVu fonts;
`report_html.py` needs only the standard library and writes one self-contained page whose chart
shows each event's detail on hover or keyboard focus, with a data table under it. Both read the
same Markdown subset ([`bin/mdlite.py`](bin/mdlite.py)): a paragraph that is wholly `==…==`
becomes a highlighted box, a shorter `==span==` or a list item an inline highlight. Open both
outputs and look at them: check that the highlights landed on the intended sentences, no table
overflows, and the chart labels do not collide.

Done when both files exist, open, and carry the highlights.

## Judgement throughout

- Cite artefacts by path and timestamp — this is an evidence document, not a recollection.
- For every inflection, ask not just what changed but whether the information was already on the
  table, and for how long. The gap between *available* and *used* is usually the real finding.
- Name the agent's failures explicitly, and the human's separately. A post-mortem that flatters
  either participant is worthless.
