---
name: drop-review
description: Drop the review you just ran as a markdown artifact in the OS temp directory, written for the session that wrote the code.
disable-model-invocation: true
argument-hint: "[output path — defaults to <tmpdir>/<repo>-<sha>-review-<date>.md]"
---

# Drop Review

Turn the review already in this conversation into a file the **author** can act on — the
session that wrote the code, not the human who owns it. Synthesize what is there; run no
new passes. Write to the OS temp directory (`$TMPDIR`, falling back to `/tmp`, or `%TEMP%` on
Windows), not the session scratchpad.

The author knows the codebase; spend words only on what they don't. Order findings by what
to fix first, not by severity taxonomy.

## Provenance

A confidence score records **how the claim was established**, not how strongly you feel it.
Put this table in the artifact.

| Score | Established by |
| --- | --- |
| 10 | You executed it. Paste the output into the finding. |
| 8–9 | You read the specific lines and traced the path. |
| 6–7 | Someone read the lines and reasoned; nobody ran the failure. |
| ≤5 | Pattern match; check before acting. |

## Steps

1. **Sweep.** Every finding from every pass, including ones you downgraded, called a false
   positive, or corrected mid-review. Mark a correction as a correction and say whose.
2. **Stamp** each finding with its provenance, and — below 10 — the one action that would
   settle it.
3. **Write the negative results** as their own section: everything checked and found sound.
4. **Root the gaps.** Provisional findings usually share a few causes. Lead the closing
   section with the shortest chain: fix these two things and N findings stop being
   provisional.
5. **Name the thin coverage** — any pass sampled, run in summary mode, skipped, or died and
   never retried.
6. **Write the file**, then report its path and the one thing the author should do first.

## Bookends

Open with what was reviewed: repo, branch, resolved commit, the base the diff was taken
against, what the diff covered, the date, and whether anything was edited.

Pin the commit as a sha from `git rev-parse HEAD`, not a branch name — a branch moves. If
HEAD moved mid-review, record both shas and say which findings predate the move.

Close with method: which passes ran, how findings were deduplicated, where two passes
converged independently, and the environment any gates ran in.
