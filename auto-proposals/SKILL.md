---
name: auto-proposals
description: Use when Alon wants funding-call work — suggest research topics for an open call, write an outline for a topic he picked, draft a proposal from an approved outline, or refresh the open-calls roster. Also when he asks "what calls are open", "what should we propose to X", or runs auto-proposals. Also the weekly scheduled funding sweep.
---

# auto-proposals — propose topics for open funding calls, then draft them

The group must not miss funding calls. For every open call in the archive this skill proposes
candidate research topics grounded in what the group has *actually* done, Alon picks, it writes
an outline, Alon approves, it writes a full draft. **Calls are supplied by hand — v1 does no
call scanning.**

**Read `SAFETY.md` in this directory before writing anything.** It is the normative contract for
every write, and the archive it writes into has no version control.

Archive: `~/Dropbox/Work/Proposals/` (override with `AUTO_PROPOSALS_ROOT`).

## The three stages, each gated by Alon

| stage | starts when | writes | who decides |
|---|---|---|---|
| 1 · topics | a call is `open`/`new` and has no `topics.md` | `<call>/topics.md` — 2–5 candidates, each with scope | Alon picks |
| 2 · outline | Alon ticks a topic in `topics.md` | `<call>/outlines/<Tn>-<slug>.md` — light, call-agnostic skeleton | Alon approves |
| 3 · draft | Alon ticks an outline | `<call>/drafts/YYYY.MM.DD a <slug>.md` **and `.pdf`** | Alon submits, never you |

Never run stage 2 for a topic Alon has not ticked, and never run stage 3 for an outline he has
not approved. Skipping a gate is the one failure that makes the whole thing useless to him.

## Two modes

- **skill** — Alon runs it in a live session. Markdown artifacts only, converse with him in the
  CLI, show him what you are about to do.
- **schedule** — unattended, set by `AUTO_PROPOSALS_UNATTENDED=1`. Same artifacts, plus **one
  Slack message per call** in `#cc-proposals`; he replies in that call's thread. Slack is
  currently notification-only under cron — see § Operator notes.

## Every run

1. **Scan.** `python3 -m lib.scan` → the roster: every call, its deadline, days remaining, state,
   whether stage 1 is done, whether it is frozen, plus **the workable calls in deadline order and
   every skipped call with its reason**. A top-level folder not starting with `_` is a call; its
   deadline parses from its name. Add `--json` for a machine-readable form, `--today YYYY-MM-DD`
   to pin the date. The scanner is read-only — it never writes to the archive.
2. **Regenerate `OPEN.md`** — the roster file. `python3 -m lib.scan --open-md` prints the new body
   on stdout; publishing it is the separate, explicit `lib.publish regenerate` call. Its `state`
   column is **human-owned**: the scanner reads it back out of the existing file, never overrides
   it. `open`/`new` are workable; `submitted`, `ignore` and `blocked` are not.
3. **Work only `workable()` calls**, nearest deadline first — the `*`-marked rows.
4. **Report what you did not do** — the scan's own "Not worked, and why" section is the source for
   this; pass it on rather than re-deriving it. Silence about a skipped call reads as coverage you
   do not have.

State is re-derived by scanning every run. There is no database: a ticked checkbox in an artifact
*is* the state, which survives hand-edits, renames and Dropbox conflicted copies.

## Grounding — every topic anchors to something real

Four layers, in this order. A topic that cannot point at all four is a topic you invented.

1. **The call itself.** Read the extracted text of the call's own files
   (`python3 -m lib.extract`), not a summary of them. Quote the call when you claim a fit.
2. **The Vault** — `~/Dropbox/Apps/remotely-save/Vault`, **read-only, never written to**. Search
   it for ideas rather than skimming fixed paths. Good starting points, not limits:
   `Research/Strategy/Publications Strategy.md` (Tier 4 is an explicit idea backlog),
   `Research/Strategy/Group Strategy Index.md`, `Code Development Strategy.md`,
   `Group/Retreat.md`, `HQ/Inbound.md` (untriaged raw ideas), `Code/<project>/*`,
   `knowledge/wiki/*`.
3. **`CORPUS.md`** — the distilled index of every past proposal in `_Granted/` and `_Archive/`.
   This is the group's actual track record. Prefer a topic continuous with something already
   funded over one that merely sounds fundable. `_Archive` means not-funded *or* superseded *or*
   withdrawn — never read an archived proposal as a rejected one.
   **`CORPUS.md` covers only `_Granted/` and `_Archive/`.** The *other* live call folders hold
   submitted-but-undecided proposals, which are the group's live commitments — read them too.
   Grounding on the corpus alone will confidently reject a topic that is already committed
   elsewhere, and get the collaborators wrong, because the evidence simply is not in the corpus.
4. **Funder material** — `_resources/<funder>/`, plus `General wording` and `Tips`.

## `<call>/context/` — Alon's own material, and it outranks everything above

Once he has ticked a topic, Alon may drop a **`context/` folder into the call folder** with
material to sharpen that direction: a paper, a partner's note, a competitor's funded abstract,
a scan of something he was told in a meeting. It appears **after** stage 1, so a call that had
no `context/` when you wrote `topics.md` may well have one by the time you write the outline.

**Read `context/` at the start of every stage 2 and stage 3 run, before writing anything.**
Check it even when you already have an outline in hand — it is the cheapest possible correction
to a direction that has drifted, and missing it means producing a draft against a brief he has
already superseded.

Three rules:

- **It is read-only, always.** `context/` is not in the owned-path grammar and the chokepoint
  refuses every write to it. Never put your own working notes there; that folder is his.
- **It outranks the corpus and the Vault.** If material in `context/` contradicts what you
  inferred from `CORPUS.md` or the Vault, he is right and your inference is stale. Say in the
  artifact which `context/` file changed your reading and how.
- **Say what you found.** List the `context/` files you read in the artifact's `sources`. A
  file you could not extract is worth reporting too — silence about it looks like it agreed
  with you.

If a `context/` file is a Dropbox conflicted copy, read neither and **ask** — two versions of
the steering material means you cannot tell which one he meant.

## The commitment check — run it before proposing, not after

Funders require the applicant to declare that **no other funding covers the same R&D**. So before
a topic reaches `topics.md`, and again before an outline is written, search every *other* call
folder (including submitted ones) and `_Granted/` for work that overlaps the topic's subject
matter, and state what you found **inside the artifact**. A granted, still-running overlap is far
more serious than a pending one, and an internal grant with its own exclusivity clause counts.

Report degree of overlap and what document would settle it. Never decide separability yourself —
it is a contractual question, and getting it wrong costs Alon more than a missed call would.

## Line length in every artifact you write

**Hard-wrap Markdown bodies at 90 characters.** Alon reads these in Notepad++ and in a terminal;
a paragraph on one 400-character line forces horizontal scrolling and makes the artifact
unreadable, which defeats the point of writing it.

Wrap prose, list items and blockquotes, using a hanging indent so continuation lines line up under
the text of their bullet rather than under its marker. Do **not** wrap, and do not count against
the limit: table rows, fenced code blocks, headings, link targets, and long unbroken tokens such
as file paths or URLs — breaking those changes their meaning or breaks rendering. A table that
genuinely cannot fit is a sign the table wants fewer columns, not a longer line.

## Language

**English by default, including for Hebrew calls** — translate extracted section names, never
carry them over verbatim. Two exceptions, in this precedence order:

1. **The call itself requires another language.** Detect it from the call text, quote the sentence
   that triggered it, and write in that language.
2. **Alon says otherwise.** Overrides everything, including a call that asks for Hebrew.

Whenever you write in anything other than English, say so at the top of the artifact with the
reason. A silent language switch is a defect.

## Writing artifacts

**Never use the `Write` or `Edit` tool on anything under the archive.** Every write goes through
the chokepoint:

```bash
python3 -m lib.publish create --root "$ROOT" --rel "<call>/topics.md" --file draft.md --frontmatter '{...}'
```

It refuses to overwrite, refuses to create a call folder, refuses a frozen call, and never
deletes. If it refuses, **it is right** — do not route around it. A revision is a new `-v2`
file, not an edit of the old one. For DRAFTS specifically, every filename starts with a
`YYYY.MM.DD <letter>` prefix: `<letter>` is `a` for the first draft of a given `<rest>` on
a given date, and increments (`a` → `b` → `c` …) for each further version of that same
`<rest>` produced the same date; a different date always starts back at `a`. A new version
is always a NEW file — the chokepoint never overwrites, it only adds new letter-suffixed
files. `lib.paths.next_draft_rel()` computes the next filename; never hand-construct it.

## Every draft ships as markdown **and** PDF

A draft Alon cannot hand to a colleague, print, or read away from a terminal is half-delivered.
So stage 3 publishes **two** files, sharing one basename:

```bash
# 1. the markdown - the editable source of truth
python3 -m lib.publish create --root "$ROOT" --rel "$MD_REL" --file draft.md --frontmatter '{...}'
# 2. the rendering - MD_REL's exact date and letter, via the helper, never hand-built
python3 -c "from lib.render import render_markdown_to_pdf; ..."   # writes out.pdf
python3 -m lib.publish create-pdf --root "$ROOT" --rel "$PDF_REL" --file out.pdf
```

`lib.paths.draft_pdf_rel_for(md_rel)` gives `$PDF_REL`. **The naming convention applies
unchanged** — the PDF carries the same `YYYY.MM.DD <letter>` as the markdown it renders, so a
new version means a new letter for both. `create-pdf` refuses a PDF whose markdown sibling is
not there and owned, so publish the markdown first.

**Structure the PDF like a document, not a memo.** Use real heading levels, tables for anything
tabular, and **include figures where a figure carries the argument** — a work-package Gantt, a
schematic of the proposed pipeline, a plot of preliminary data. Reference images by a path
relative to the call folder and pass that folder as `base_dir` so they resolve. A proposal that
is a wall of prose loses to one with a figure a reviewer can read in ten seconds.

**If rendering fails, say so out loud.** `lib.render` raises rather than returning quietly:
`RenderUnavailable` means no backend is installed, `RenderFailed` means one is installed and
broken. Either way, publish the markdown, **report the failure in your run summary**, and name
the fix. Never let a run look like it delivered a draft when it delivered half of one. Backends
are tried best-first — pandoc (with tectonic or xelatex), then weasyprint, then libreoffice;
`lib.render.available_backend()` reports which one *would* be tried, but only an actual render
tells you whether it works.

## References — drafts carry them, and every one is verified

**Every draft includes academic references.** A proposal that asserts a state of the art without
citing it reads as opinion, and reviewers are domain experts who will notice.

**Verify every reference before it goes in. Never write a citation from memory.** Confirm the
title, authors, year, venue and DOI resolve to a real paper that says what you are citing it for.
An invented or misattributed citation in a funding proposal is far worse than no citation: it is
the single fastest way to destroy a reviewer's trust in everything else in the document, and it is
the mistake a language model is most likely to make. If you cannot verify a reference, cite
something you can, or say plainly in the draft that the claim needs a source.

**Cite the group's own publications wherever they establish prior expertise.** Part of what the
reviewer is assessing is whether *this* group can do *this* work, so a claim backed by the group's
own prior paper does two jobs at once. Pull them from `CORPUS.md`, the Vault publications strategy,
and the group's repositories — and cite them for what they actually demonstrate, not as decoration.

**Exception — form-bound calls.** Some calls supply a template with fixed chapters, page limits
and no bibliography section. Follow the form; do not bolt a reference list onto a structure that
has no room for one. Say in the draft that references were omitted for that reason, so the
omission is visible rather than looking like an oversight.

## Steering — three equal channels

Alon steers by ticking a checkbox, by telling you in a CLI session, or by replying in the call's
Slack thread. Instructions arriving by CLI or Slack must be **written back into the affected
artifact as a dated block** (`lib.publish append`), so his intent never lives only in scrollback
and he can see how you read it. An ambiguous instruction means ask and change nothing.

A **fourth channel is passive**: material he leaves in `<call>/context/`. Nothing announces it,
so it only works if you look — which is why reading `context/` is a required first step of
stages 2 and 3 rather than a nicety. Unlike the other three it needs no write-back, because the
file he put there already says what he meant; cite it in `sources` instead.

## Not yours to decide

Which calls enter · which topics graduate · which outlines become drafts · **any submission** ·
arming the schedule. All Alon's. Nothing goes outbound from this skill.

## Operator notes

- **Bootstrap states are private and live outside this repo.** For a call with no row in
  `OPEN.md` (or before `OPEN.md` exists at all) the scanner may seed its state from
  `<root>/_auto-proposals/bootstrap-states.json` — override the full path with
  `AUTO_PROPOSALS_BOOTSTRAP_STATES`. Format: one flat JSON object, call folder name →
  state, e.g. `{"2026.10 ExampleFund": "open"}`. The file is optional: absent simply
  means no seed states, and `OPEN.md` stays authoritative. It is kept out of this public
  repo deliberately — which calls the group pursues is private. A file that exists but is
  malformed or holds an unknown state is a loud refusal, never a silent "no states".
- **Writes happen on one host only** (`AUTO_PROPOSALS_PUBLISH_HOST`, default `HL`) and only when
  `dropbox status` is clean. Dropbox propagates no locks; two hosts writing the same new file
  produce a conflicted copy rather than a winner.
- **Cron is not armed.** The agreed schedule is Tuesdays 17:00 (`0 17 * * 2`), to be armed only
  after Alon judges a real run good and says so explicitly.
- **Slack** is `#cc-proposals` (`C0BKZ6UCJK0`, private). Sending needs the bot invited to the
  channel; `CC_SLACK_CHANNEL` must be set explicitly, because the sender's default is `#cc-comm`
  and a proposal thread must never land there. Reading thread replies needs bot scopes
  `groups:history` + `groups:read`; until those exist, thread-reply steering does not work under
  cron and Slack is notification-only. Say that rather than shipping something that looks like it
  works.
- **No PDF backend works on HL as of 2026-07-29.** pandoc, weasyprint and every LaTeX engine
  are absent, and the LibreOffice on `PATH` is a **snap** whose confinement makes it fail every
  conversion — including a plain text file — so `available_backend()` answers `libreoffice` and
  the render still fails. Until `pandoc` + `tectonic` (preferred) or `weasyprint` is installed,
  stage 3 will publish the markdown and report the PDF as not produced. That is the designed
  behaviour, not a bug to work around.
- **There is no OS sandbox on this machine** — `kernel.apparmor_restrict_unprivileged_userns=1`
  blocks `bwrap`, so the write protection is the permission system plus `lib/publish.py` plus the
  integrity snapshot, not a kernel boundary. See `SAFETY.md` § 1.
