---
name: writing-great-skills
description: Use when authoring, editing, reviewing, or shrinking a skill in this repo — its frontmatter, description, or the model-invoked vs user-invoked choice. Wraps writing-for-agents with this repo's skill conventions.
---

Authoring or editing a skill? The general craft — information hierarchy, progressive disclosure, completion criteria, pruning, leading words, the failure modes, and the model-invoked vs user-invoked mechanics — lives in [`writing-for-agents`](../writing-for-agents/SKILL.md) and its [`SKILL-MECHANICS.md`](../writing-for-agents/SKILL-MECHANICS.md). Read those first: a skill is just one kind of agent-read document, and **predictability** — the agent taking the same process every run — is the root virtue there too.

This skill adds only what is specific to a skill living in *this* repo.

## In this repo

- **Lint gate.** Every skill must pass `bin/lint-skills.py`; run it before you commit.
- **Flat layout.** Skills are top-level `<name>/` directories here, not nested under `skills/{engineering,productivity,personal}/` the way upstream ships them.
- **Vendored vs ours.** Skills vendored from Matt Pocock are listed in `THIRD_PARTY_NOTICES.md`. Editing one creates drift the next `/sync-matt-pocock-skills` must reconcile, so keep local edits minimal and record any deep adaptation in `ADAPTATION.md`. A skill that is ours stays out of both.
- **Invocation default.** Default to model-invoked, so the agent and other skills can reach it; set `disable-model-invocation: true` only for a skill fired solely by hand, and route a pile-up of those through a user-invoked router. Group-internal skills that carry personal context live in a separate private repo, not here.
- **Count badge.** Adding or removing a skill changes the README `skills-N` badge; update it in the same change.
