---
name: mutation-test
description: Mutation-test the Python lines a diff touched with cosmic-ray, and fail on any surviving mutant — a line the tests execute but never check. Use when hardening agent-written code before a PR, when a contract Verifier needs proof the tests actually assert something, when asked whether tests are meaningful rather than just covering, or when running a "hardener" stage.
---

# Mutation test

Coverage says a line ran. A mutation test says whether any test would notice if the line were
wrong. The tool flips one thing at a time (`+` to `-`, `>` to `>=`, `True` to `False`, a
constant), reruns the tests, and records whether they fail ("killed") or still pass ("survived").
A survivor is a line whose behavior no assertion pins down.

This skill wraps [cosmic-ray](https://github.com/sixty-north/cosmic-ray) and mutates **only the
lines a diff changed**. Each mutant costs one full run of the test command, so whole-module runs
are a survey, not a gate: one 540-line module in a mid-size repo yields 575 mutants against 26 for
a small diff.

## Run it

From inside the repo, in the environment the tests run in (cosmic-ray must be importable there;
`pip install 'cosmic-ray>=8.7,<9'`):

```bash
python ~/.claude/skills/mutation-test/bin/mutation-test --diff <base> \
  --test-command 'pytest path/to/the_tests.py -x -q -p no:cacheprovider'
```

- `--diff <base>` compares the working tree against `<base>`, usually the branch's merge-base with
  main. Untracked new files count as changed in full. Test files are never mutated.
- `--test-command` is a shell command. Give it **only the tests that cover the changed files**:
  every mutant reruns it. Turn off parallel runners for it (`-n 0` under pytest-xdist): startup
  dominates a single file's run.
- The tool mutates files **in place** and restores them, so run it in your own worktree with no
  other process editing it. It checks every target byte-for-byte afterwards and restores any it
  finds changed.

| Exit | Meaning |
|---|---|
| 0 | every mutant killed (or nothing in scope) |
| 1 | at least one survived: each printed as `SURVIVED file:line operator` plus its diff |
| 2 | cannot judge: red baseline, compiled module shadowing a target, more than `--max-mutants`, a mutant run that crashed, or cosmic-ray missing |

Other flags: `--timeout S` per test run (a timeout counts as killed), `--max-mutants N`
(default 200), `--json`, `--exclude GLOB` (added to the test-file exclusions, which always apply), and trailing paths to narrow the scope (or, without
`--diff`, to mutate whole files).

## Before the first run: a green baseline

The tool runs the test command once, unmutated, and refuses (exit 2) if it fails: on a red
baseline every mutant would count as killed. Tests that fail for environmental reasons (a missing
binary, local settings) must be deselected in the command, not fixed by the gate:

```bash
--test-command 'pytest pkg/level_test.py -x -q -n 0 --deselect pkg/level_test.py::TestLevel::test_needs_onedmin'
```

## The hardener loop

As a contract Verifier, the command plus `exits 0` is the whole check. The loop:

1. Run it. For each `SURVIVED` row, read the diff: it is a behavior change the tests accepted.
2. Write the assertion that would have failed on it — usually a specific expected value, a
   boundary case, or a check on the branch not taken.
3. Rerun until it exits 0.

Never pass the gate by:

- deleting the code the survivor lives in only to make it disappear,
- weakening the test command to fewer tests than cover the change,
- raising `--timeout` so slow mutants count as killed, or lowering it so all of them do,
- deselecting tests that fail because of the mutant rather than the environment.

Some survivors are **equivalent mutants**: a change with no observable effect (`x * 1` vs `x`, a
reordered independent assignment). If no test could ever tell them apart, stop and report the row
with why it is equivalent rather than contort a test around it.

Because a deterministic check decides acceptance, the loop does not need a strong model: a
free-tier one can run it.

## Limits

- Python only, one process (cosmic-ray's local distributor). Cost is roughly mutants × one test
  run; on a repo whose single test file takes 8 s, 26 mutants took under 4 minutes.
- **Compiled modules are refused.** When a `.so`/`.pyd` for the same module sits beside the
  `.py` (Cython builds of plain `.py` files do this), Python imports the compiled one and mutating
  the source changes nothing: every mutant would survive. The tool exits 2 naming the file.
  Narrow the paths to the pure-Python modules.
- Any non-zero exit of the test command counts as a kill — including an import error. The green
  baseline guards the common case; a mutant that breaks imports is still killed, which is correct.
- A pure deletion (lines removed, none added) scopes the line just before the cut.
