---
name: deep-research-prompt
description: Draft one Deep Research prompt to send unchanged to several research tools (an LLM council — ChatGPT, Gemini, Claude, Perplexity deep research), with a fixed answer table so the responses can be consolidated. Use when a question needs a literature-grade sweep beyond one agent's search, or when the user asks for a deep research or DR prompt.
---

# Deep Research prompt

One question, written once, sent unchanged to every member of the **council**. The council exists
for error-correction, not breadth: several tools answering the *same* question can be checked
against each other, and tools given different angles cannot. Why this is so, and why the audit is
the valuable half, is in [`commissioning-research.md`](../probe/references/commissioning-research.md).
Read it first. `deep-research-consolidate` reads the answers this prompt asks for.

## 1. Pin the question

Write down, from the conversation and the project's records:

- **the decision** the answer feeds, and what each plausible answer would change;
- **the target**, quantitative wherever possible: the number, its units, the conditions it holds at,
  and the threshold that separates useful from useless. Where no number exists, state the
  qualitative criterion an answer must meet instead;
- **what is already ruled out**, each item with the evidence that ruled it out, so the council does
  not spend its budget re-proposing it;
- **what is already known to be true** and may be built on.

**Done when** the question is one sentence whose answer would change a named decision, and the
target is stated so an answer can score itself against it.

## 2. Make it portable

The prompt is published to outside services the moment it is pasted. Write it so it is
self-contained and says nothing confidential:

- describe the work by its field and its physics, never by a project, client or product name;
- replace internal ids, ticket numbers, branch names and local paths with what they denote;
- state numbers the answer needs; drop numbers that would identify unpublished work.

Then grep the draft for every term the user's instructions mark confidential (their global
instructions list them), and read it once more for sensitive data no list names: secrets and
access tokens, private or internal URLs, personal data, and unpublished results.

**Done when** the grep returns no hits, the read-through finds nothing sensitive, and a reader with
no access to the project could still answer the question.

## 3. Write the prompt

Use these sections, in this order:

1. **Context.** The system and the regime, the decision the answer feeds and what each plausible
   answer would change, and what is already known to be true. One short paragraph.
2. **Question.** The one sentence from step 1.
3. **Target.** The numbers, units, conditions and threshold, or the qualitative criterion. Ask
   each answer to score itself against it: arithmetic shown for a numeric target, a reasoned
   assessment for a qualitative one.
4. **Already ruled out.** Each item with its reason. Ask for new evidence only if it overturns the
   stated reason.
5. **Scope.** The source classes to search (for example: measured kinetics, model compounds,
   computed rates, reviews only as pointers to primary work), and anything out of scope.
6. **Answer format.** Require exactly this table, one row per candidate:

   | ID | claim or mechanism | primary source (authors, year, title, journal, DOI if any) | values as stated, with units and conditions | score against the target (arithmetic, or reasoned assessment if qualitative) | confidence | evidence against, with its source (or "none found") |
   | --- | --- | --- | --- | --- | --- | --- |

   Then require three short sections:
   - **Could not access:** paywalled or unretrievable sources, named;
   - **Against my top recommendation:** what it found that cuts against its own best candidate;
   - **Recommendation:** one next step.
7. **Rules.** Primary sources over secondary, with secondary sources used only to find primary
   ones. Never cite a source not actually read. Mark a value as "inferred" when it is derived rather
   than quoted.

**Done when** every section is present and the answer table's columns are fixed verbatim, since
the consolidator joins the responses on them.

## 4. Save and hand over

The run directory is `~/agents/deep-research/<YYYY.MM.DD>-<slug>/`, where `<slug>` is a short
kebab-case name for the question. If that directory already exists, it belongs to an earlier run:
ask the user whether to resume it, and otherwise append `-2`, `-3`, … until the name is free. A
fresh run never writes into an existing directory, since stale answers left there would be
consolidated as if they answered this prompt.

On a resume, keep the existing `prompt.md` unchanged and show it; the draft from step 3 is
discarded, since the answers already in `responses/` answered the saved prompt. On a fresh run,
save the prompt as `prompt.md` in the new run directory and create `responses/` beside it. Either
way, show the prompt to the user in a fenced block so it can be copied.

Tell them which tools to send it to, and to save each answer as `responses/<tool>.md` (for example
`responses/gemini.md`), beginning with two lines, `tool: <name and mode>` and
`date: <YYYY-MM-DD the research ran>`, above the pasted answer. When the answers are in, run
`deep-research-consolidate` on the run directory.

**Done when** the prompt file exists, the user has the absolute path to both the file and the
`responses/` directory, and the prompt is on screen.
