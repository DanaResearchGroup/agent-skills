---
name: ask-me
description: Sweep the conversation for every decision that was never actually put to the user — buried in a summary, softened into "let me know if", deferred, or silently settled by an assumption — then put each one through `framing-decisions` as its own AskUserQuestion call. Use when the user says "ask me", "use AskUserQuestion", "my gates", "what's still open", or asks for the questions as choices rather than prose; and before ending any message that would leave a decision, assumption, or open fork sitting in text they have to mine.
---

A decision written into prose is not a decision put to the user. It sits inside a summary they may skim, with no handle to grab but retyping it. This skill finds those and turns each into a gate.

Division of labour: [`framing-decisions`](../framing-decisions/SKILL.md) builds one question — solve it as the field's own expert, audit that the option set can hold that answer, send it explained. **This skill decides what to ask and in what order.** Invoke it for every question; nothing about composing a single one is restated here.

## 1. Harvest

Sweep everything since the user's last decision-bearing turn — your messages *and* the artifacts you wrote in them (plan, handoff, PR body, spec, commit message). Four classes, in ascending order of how easily they are missed:

- **Asked in prose.** A question mark inside a paragraph. "Should I…", "do you want…", "one open question is…".
- **Softened.** "Let me know if you'd rather…", "happy to change this", "I went with X for now". A decision handed over with nothing to click.
- **Deferred.** "We can decide that later", a TODO, an *open* row in a plan, a `?` in a table.
- **Silently settled.** A fork you took without narrating it, where the other branch was defensible on the evidence you had. The user never saw these, so they cannot ask for them — which makes them the highest-value catch here, and the reason this skill is not just a re-read of your last message. Reconstruct them by asking, of each non-trivial thing you built: what else could this have been, and did I have a stated reason to rule that out?

Being invoked by name means the last message buried something. Sweep the whole message, not just the sentence with the question mark in it.

## 2. Cut

Drop anything that fails one of these — asking it spends the user's attention on nothing:

- **It changes nothing.** Both answers lead to the same next action. State the assumption in a line and move on.
- **You can settle it yourself.** Reachable by reading the code, checking the file, or running the cheap check — go settle it (see [`probe`](../probe/SKILL.md)) and ask only what survives.
- **They already answered it.** Search back before asking; a re-ask reads as not listening.

## 3. Order

By fan-out, not by the order you happened to write them down. First the decision whose answer would re-derive the others — ontological, premise-fragile, or a parent whose contents the rest allocate. Ask it, wait, then re-derive the remaining list against the answer; some of it will have dissolved.

## 4. Run, then report

One `AskUserQuestion` call per decision, composed under `framing-decisions`, each awaiting its answer before the next is drafted.

Being invoked by name means decisions were already going unasked here, so these answers are unusually likely to correct a default you did not know you held. Log every answer that **overrode** your recommendation, per `framing-decisions`' capture rule and [`COMPOUNDING.md`](../COMPOUNDING.md) — one call per override, never a reason to pause the work.

When the gates are closed, spend two lines on what you surfaced that they had not seen — the silently-settled calls — and act. Don't summarize their own answers back to them.

**Done when** nothing is left that would change what you do next without guessing, and every assumption still in play has been said out loud rather than buried.
