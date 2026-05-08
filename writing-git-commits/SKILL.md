---
name: writing-git-commits
description: Use when about to run `git commit` (or being asked to commit, stage, or split changes into commits) — keeps commit messages short and readable, splits work into one logical unit per commit, and avoids destructive or unauthorized git actions.
---

# Writing Git Commits

## Overview

This user prefers commit messages that read like log lines, not essays. Default
to a single short subject; only add a body line when the *why* is non-obvious.
The diff already shows the *what*.

## Subject Line

- **Imperative, lowercase after the topic prefix**, ≤ ~60 chars total.
- Optional `<topic>:` prefix when the change is scoped to one area
  (e.g. `scheduler:`, `ipython:`, `common:`).
- No trailing period. No issue numbers in the subject unless asked.

## Body

- provide commit description only if needed.
- If one short line genuinely adds context, add it
- One line, wrapped at ~72 chars. Never multiple paragraphs.
- If the commit adds a non-trivial behavior, OK to summarize it as a single short paragraph in the commit description.

## Granularity

- One logical change per commit. If the diff spans unrelated areas, split
  by `git add <paths>` into separate commits.
- Group a helper and its tests into the same commit; group the consumer of
  that helper into the *next* commit.

## Hard Don'ts

- No `git push` unless the user explicitly asks.
- No `--amend` on already-pushed commits, no force-push to `main`/`master`.
- No `--no-verify`, `--no-gpg-sign`, or other hook/sign bypass flags.
- No `git add -A` / `git add .` — stage explicit paths only.
- Never edit `.git/config` or alter the user's git identity.

## Examples

Good (one-line):
```
ipython: fix parser import in 1D torsion scan
```

Good (with brief body):
```
scheduler: snapshot running jobs to running_jobs.yml hourly

Append per-hour snapshot only when changed; otherwise emit a
one-line heartbeat in ARC.log.
```

Good (with brief body):
```
Break down driver tests

So that they can run independently by different CI workers
```

Good (with a short description)
```
Update test assertions for Python 3.14 compatibility

- Conformers: updated RDKit force field expected values/coordinates
- xTB-GSM: updated HNO/HON optimized coordinates
- Reaction: updated dict key ordering and species coordinates
- OB SMILES C(1)CC(1) → C1CC1 in species test
- Various: path handling, deprecated assertDictEqual removal
```


Bad (verbose body restating the diff):
```
ipython: fix parser import in 1D torsion scan notebook

arc.parser is a package; import from arc.parser.parser.
```
The body restates what the subject already says — drop it.


Good (long is OK sometimes if necessary):
```
mapping/engine: two-pass pairing to reject formula-only matches

r_cut_p_cut_isomorphic matched purely on molecular-formula fingerprint OR
graph isomorphism, so constitutional isomers sharing a formula (e.g. the
alpha vs beta pentyl-ether radicals in H-abstraction between identical
donors) got paired as "isomorphic" and handed to map_two_species, which
then failed to superimpose them and returned None.

Add a strict flag that requires full graph isomorphism, and run
pairing_reactants_and_products_for_mapping in two passes: strict first,
then the loose fingerprint-or-isomorphic fallback for any unmatched
r-cuts so rearrangements whose cuts aren't strictly isomorphic (e.g.
Intra_Disproportionation, ring-openings) still work.

Also guard glue_maps against a None per-pair map so the caller sees a
clean None instead of a TypeError when a future mapping regression slips
through.
```
