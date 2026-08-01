---
name: paper-outline
description: Plan a scientific paper with the user by filling out the group's Outline document, one decision at a time.
disable-model-invocation: true
---

Plan a new paper — or sharpen one already underway — by filling out the group's Outline
document together with the user.

Two artifacts, side by side in the paper's folder: `Outline.md`, where the work happens, and
`Outline.docx`, what co-authors read.

## The spine: every claim gets earned

A paper is a set of **claims**. The outline is where each one is **earned** — backed by a
result the work actually produces — and **closed** — restated as a conclusion.

Keep a **ledger**, visible to the user and updated as you go: one row per objective,
carrying the subsection and key figure that earn it and the conclusion that closes it.

| Objective | Earned by | Closed by |
|---|---|---|
| the claim, one sentence | subsection + key figure | conclusion |

An objective no result reaches is **unearned** — the work is missing, or the claim is too big
for it. A result no objective reaches is **orphaned** — either it deserves an objective of its
own, or it belongs in a different paper. Both are findings; put each to the user rather than
quietly balancing the table yourself.

The ledger is what makes this session worth having. Reach it early and keep it on screen.

## 1. Ground yourself

Read what the user hands you at invocation — that input is the brief, and it outranks
anything you infer. Then read the paper's folder: prior drafts, data, figures, the group's
related papers.

When `Outline.md` or `Outline.docx` already exists there, load it: this run sharpens that
outline rather than opening a blank one.

Facts you can find, find. Decisions are the user's.

**Done when** you can state the scope, the objectives so far, and which results already exist —
without having asked the user a single question of fact.

## 2. Grill

Run the interview per `grilling`: one question at a time, `AskUserQuestion` with your
recommendation first, and wait for the answer before the next one.

Walk the outline in the order below. Each row names what that section has to settle — arrive
with a proposed answer drawn from your legwork, and grill the **gap** hardest of all, because
an intro that misidentifies it costs the whole paper.

| Section | What to settle |
|---|---|
| Title | The claim a reader should carry away. |
| Scope | One sentence: what this paper covers, and what it deliberately leaves out. |
| Paper Objective(s) | The claims, as bullets. Each defensible with results in hand or planned. |
| Introduction | The funnel — broad, narrowing, state-of-the-art, the **gap**, then the goal. Name who came closest to the gap and why it is still open. |
| Methods | Each tool and method, and which objective's evidence it produces. |
| Results and discussion | One subsection per claim: the key figure, and what it shows that earns the claim. |
| Conclusions | One per objective, in the same order — the ledger's closing column. |

**Done when** every ledger row is closed, or parked with the user's explicit say-so.

## 3. Write and render

Write `Outline.md` in the paper's folder, in the shape `bin/render_outline.py` documents, then
render it:

```bash
python3 bin/render_outline.py <paper-folder>/Outline.md
```

That fills the group template (`assets/Outline-template.docx`), so the headings, fonts, and
bullets match every other outline the group writes.

**Done when** both files sit in the paper's folder and `Outline.docx` carries the group's
headings.

## 4. Hand it back

Show the user the closed ledger and the two paths. Drafting the paper is a separate act —
start it only when they ask.
