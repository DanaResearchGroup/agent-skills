---
name: ask-one-by-one
description: Put decisions to the user through the AskUserQuestion tool rather than in prose — one decision at a time, each explained before its options, with the option set built from what a senior practitioner of the field would actually do. Use whenever you are about to put a decision, choice, or open question to the user; when the menu you drafted might not hold the right answer; when the question asks what something *is* rather than what to do; when a decision is expensive to unwind and a probe would settle it; or when the user asks to be questioned one at a time.
---

Route every decision you'd put to the user through this protocol: one decision at a time, explained, through the `AskUserQuestion` tool. It overrides any default that batches unrelated decisions into a single call.

The option set is the failure surface. A menu can be well-explained, well-recommended, and still worthless because the right answer was never on it — so most of this protocol runs before the options exist.

## The protocol

Work the open decisions in priority order, one pass per decision:

1. **One decision per call.** Send `AskUserQuestion` carrying that decision, then wait for the answer before composing the next. Questions that are facets of one decision may share a call; separate decisions get separate calls.
2. **Answer it as the expert first.** Before drafting any option, solve the decision yourself as a senior practitioner of the discipline it belongs to — the domain's own developer, the process engineer, the UX designer, the statistician — reasoning from the problem rather than from the options you were about to offer. On a hard, high-stakes, or multi-session call, spend real thought here, and dispatch a domain-expert subagent where the field is outside your strength; a menu built cheaply here costs weeks of building the wrong thing. **This answer is your recommendation** unless you find a stated reason to depart from it.
3. **Audit the menu against it.** Check the option set, and rewrite it when a check fails:
   - **The expert answer is on the menu.** If it isn't, the menu is wrong — fix the options, not the caveats.
   - **The options differ in kind, not just degree.** Expert answers often move the work **upstream**, to where the information is still intact, while a competent-but-non-expert menu patches downstream where the problem surfaces. When every option sits at the same layer, you have one option written four ways.
   - **Mechanisms compose.** When the options are mechanisms rather than values, a pipeline that runs several of them in a chosen order is a required candidate: "A proposes, B adjudicates," offered as its own option with the ordering you'd pick named.
   - **A losing option keeps a job — if it lost on merit.** Before cutting a mechanism the composed option didn't need at the top, ask what it would still be good for downstream — validation, a subordinate signal, a fallback — and give it that role instead. A mechanism rejected because it's unsafe, wrong, or refuted gets no such role: let it die, don't let it back in downstream as "validation" or a fallback.
   - **Ontology gets constraints, not menus.** When the decision is what something *is* — its unit, its medium, its atom, its state — finished-answer options encode a prior the domain expert may not hold; name which level the question is actually at first (the medium a claim runs on is not the subject it's about — a mismatch there loses whole rounds unnoticed). Offer candidate constraints or invariants instead of answers, plus an explicit option to name one none of them captures.
   - **The premise is named.** State in one line the assumption every option rests on, so the user can reject the frame instead of only the choices. This is where the out-of-the-box answer comes from.
4. **Explain first.** Before the options, say in plain language what is being decided and why it matters — the stake, the tradeoff, what turns on it. Give enough that the user can choose from the question alone, without rereading the analysis above it.
5. **Options with a steer.** Offer concrete options, never "what would you like to do?". Put your single recommendation first, marked `(Recommended)`, and make each option's `description` state what it means and what it costs.
6. **Defer where fan-out is high.** On a decision whose answer is expensive to unwind later, "defer — here is the probe that would settle it, and what the probe costs" is itself a legal option, not a fallback you reach for only once stuck.
7. **Adapt on the answer.** After each answer, re-derive what is still open: the next question may shift on what they just said, and some planned questions fall away. Compose the next one fresh rather than reading down a fixed list.

**Think long, write short.** The thinking in steps 2 and 3 runs deep; what reaches the screen stays lean — a few sentences of explanation, one line for the premise, one line per option. Cut prose that restates the options, recaps analysis the user just read, or pads the recommendation.

**Escalation means re-solve, not reformat.** Being asked by name to invoke this skill mid-conversation means the last answer was too thin, not merely the wrong shape — return to step 2 and spend real effort there before rebuilding the menu.

**Done when** no decision is left that would change what you do without guessing — a deferral with its probe now running counts as answered. Then stop asking and act.
