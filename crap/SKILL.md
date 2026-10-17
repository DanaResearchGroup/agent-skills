---
name: crap
description: Score Python functions by CRAP (cyclomatic complexity combined with test coverage) and gate on a threshold, scoped to the functions a diff touches. Use when cleaning up agent-written code before a PR, when a contract Verifier needs a complexity/coverage gate, when asked which functions are too complex or too untested, or when running a "cleaner" stage.
---

# CRAP

CRAP (Change Risk Anti-Patterns) scores one function as `cc² · (1 − cov)³ + cc`, where `cc` is
its cyclomatic complexity and `cov` is the fraction of it the tests exercise. Two properties make it
a good gate for agent code:

- **At full coverage the score equals `cc`.** Tests cannot rescue a function with too many paths;
  only splitting it can.
- **An untested function scores `cc² + cc`.** Even a modest one fails, so the fix is a test.

The default threshold is **6**. Uncle Bob keeps human code at 4 or below and lets agents go to 6;
raise it per repo only with a reason written down, never to get a red run green.

## Run it

1. Produce a coverage.py JSON report, with branch coverage, from the repo root, in the repo's own
   activated environment:

   ```bash
   pytest <tests> --cov=<package> --cov-branch --cov-report=
   coverage json -o "$TMPDIR/cov.json"
   ```

2. Score the functions the change touched:

   ```bash
   ~/.claude/skills/crap/bin/crap --coverage "$TMPDIR/cov.json" --diff <base>
   ```

   `--diff <base>` compares the working tree against `<base>`, usually the branch's merge-base
   with main; untracked new files count as changed in full. Without `--diff` it
   scores every function in every `.py` file under the root (git-tracked and unignored ones in a
   repo), including files the report lacks. That is useful for a survey, but **never gate a legacy repo
   on it**: on ARC one file has 35 of 81 functions above 6.

| Exit | Meaning |
|---|---|
| 0 | every scored function ≤ threshold |
| 1 | at least one above it: the rows marked `FAIL` |
| 2 | bad input: unreadable report, bad diff base, unparsable file |

Other flags: `--threshold N`, `--json`, `--top N`, `--exclude GLOB` (test files are excluded by
default), and trailing paths to limit the scope.

## The cleaner loop

As a contract Verifier, the command plus `exits 0` is the whole check. The loop:

1. Run it. For each `FAIL` row, read the `cc` and `cov` columns:
   - **`cov` low**: write tests for the untested paths.
   - **`cc` above the threshold**: split the function, or move its branching into a lookup or into
     smaller named helpers. More tests will not move the score.
2. Regenerate coverage and rerun until it exits 0.

Never pass the gate by:
- deleting or weakening tests,
- adding `# pragma: no cover`,
- excluding the file,
- raising the threshold.

Each of those makes the gate report clean while the code stays the same. If a function genuinely
cannot be split, stop and report it with its score rather than pass by any of those routes.

Because a deterministic check decides acceptance, the loop does not need a strong model: a
free-tier one can run it.

## Limits

- Python only.
- Coverage is statement plus branch coverage from coverage.py, not the basis-path coverage of the
  original CRAP paper. Functions missing from the report are scored as uncovered and counted in the
  summary line.
- `cc` is McCabe complexity from the AST: one point for each `if`/`elif`, loop, `except`, ternary,
  extra boolean operand, comprehension `for`/`if`, and refutable `case`.
- Nested functions are scored separately from their parent. A lambda counts toward the function
  that contains it; one at module or class level is scored on its own as `<lambda>`, always as
  uncovered: its line runs when it is defined, so the report cannot tell whether the body ever did.
  Above `cc` 2 that fails the gate whatever the tests do; make it a `def`.
