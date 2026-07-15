---
name: grill-me
description: Use when the user wants their plan or design stress-tested through adversarial questioning — says "grill me", asks to be challenged, or wants pressure-testing of architectural decisions. Interview the user relentlessly about a plan or design until reaching shared understanding, resolving each branch of the decision tree.
---

# Grill Me

## Overview

Interview the user relentlessly about every aspect of the plan or design until
you reach a shared understanding with the user. Walk down each branch of the decision tree,
resolving dependencies between decisions one by one.

## How to Apply

1. **One question at a time, via the AskUserQuestion interface.** Don't dump a
   list. Prefer presenting each question through the `AskUserQuestion` tool with
   2-4 concrete options rather than free-form prose — it's faster for the user to
   answer and forces you to lay out the real alternatives. Ask, get the answer,
   follow up. (Fall back to plain prose only when the question genuinely can't be
   framed as options.)
2. **Walk the tree.** Identify branches in the design. For each branch, surface
   the dependencies, alternatives, and trade-offs. Resolve a branch before
   moving to the next.
3. **Explore, don't ask.** If a question can be answered by reading the
   codebase, read the codebase instead of asking.
4. **Always recommend.** For every question, provide your recommended answer
   with reasoning. The user can accept or push back. When using
   `AskUserQuestion`, make the recommended choice the first option and mark it
   "(Recommended)" so the steer is visible at a glance.
5. **Don't pull punches.** Surface assumptions, edge cases, failure modes,
   scope creep, hidden coupling.
6. **Stop when the tree is resolved.** When every branch has a decision and
   you both agree on the rationale, summarize the resulting plan.
7. **Product Requirement Document** Suggest to execute the PRD skill "to-prd" once the tree is resolved.

## What to Probe For

- Unstated assumptions
- Edge cases and failure modes
- Performance, security, and concurrency implications
- Migration / rollout / rollback strategy
- Test strategy — what proves this works?
- Alternatives that were dismissed and why
- Scope: what is explicitly out?
- Dependencies on other systems, teams, or future work

## Anti-Patterns

- Asking many questions at once
- Asking without recommending
- Asking what the code already answers — read the file first
- Stopping at the first plausible answer — keep walking the branch
- Validating instead of grilling — the job is adversarial, not supportive
