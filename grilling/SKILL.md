---
name: grilling
description: Grill the user relentlessly about a plan, decision, or idea. Use when the user wants to stress-test their thinking, or uses any 'grill' trigger phrases.
---

Interview the user relentlessly until you reach a shared understanding. Map this as a **design tree**: every decision branches into the decisions that hang off it.

Work the tree in **rounds**. The **frontier** is every decision whose prerequisites are already settled — the questions you can ask _now_ without guessing at answers you haven't heard yet. Ask the whole frontier in one round: number each question and give your recommended answer. Then wait for the user's answers before the next round.

Prefer presenting each round's questions through the `AskUserQuestion` tool, giving every question 2-4 concrete options rather than free-form prose — make your recommended answer the first option and mark it "(Recommended)" so the steer is visible at a glance. The tool takes up to 4 questions per call, so split a larger round across consecutive calls. When a question genuinely can't be framed as options, fall back to prose formatted like so:

```
❓ **Q1** - **<question title>**: <question body, might be multiple paragraphs, including multiple choices>

➡️ <your recommended answer>
```

Each round the user answers reshapes the tree — settled decisions push the frontier outward and unblock questions that depended on them. Recompute the frontier and ask the next round. A question whose answer depends on another question still open in this round belongs to a _later_ round, not this one.

Finding _facts_ is your job, never the user's. When a frontier question needs a fact from the environment (filesystem, tools, etc.), dispatch a sub-agent to find it — don't ask the user for anything you could look up yourself. Don't block on it: a running exploration is an unsettled prerequisite, so only the questions downstream of it wait for the sub-agent to report — ask the rest of the frontier now. When the fact itself is expensive to get and the question it feeds has wide downstream fan-out, put the deferral to the user as an option with its cost named, rather than silently stalling the round on it. The _decisions_ are the user's — put each to them and wait.

Grilling decides which questions enter a round — the frontier. Building each question's own option set: when the candidates are mechanisms rather than values, a pipeline running several of them in a chosen order is a required candidate too — "A proposes, B adjudicates," with the ordering named, not just the mechanisms picked alone. When the question is ontological — what something *is*, its unit, medium, atom, or state — offer candidate constraints the answer must satisfy, not finished answers; a finished option smuggles in a prior the user may not hold. See `ask-one-by-one` for the fuller protocol behind building any option set, including how to answer as the domain expert first.

The session is done when the frontier is empty: every branch of the design tree visited, nothing left silently assumed. Do not act on it until the user confirms you have reached a shared understanding.
