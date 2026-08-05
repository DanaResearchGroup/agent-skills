# Testing Specialist Review Checklist

Scope: Always-on (every review)
Output: JSON objects, one finding per line. Schema:
{"severity":"CRITICAL|INFORMATIONAL","confidence":N,"path":"file","line":N,"category":"testing","summary":"...","fix":"...","fingerprint":"path:line:testing","specialist":"testing","provenance":"executed|read"}
Optional: line, fix, fingerprint, evidence, test_stub.
`provenance` is required: `executed` only when you ran something and can quote its output, otherwise `read`. A finding reports CRITICAL only with `executed` provenance.
If no findings: output `NO FINDINGS` and nothing else.

---

## Mutation testing — run this first

Coverage tells you a line was executed. It cannot tell you an assertion would have caught the
line being wrong. Mutate the source, re-run the suite, and report every mutation that **survived**
— the suite ran, stayed green, and the code was broken.

This is the pass that pays for itself. On the review this checklist was written from, a module at
98.73% branch coverage with 56 green tests survived 14 of 34 applied mutations, and the PR
description's claim of "zero mutations survived" turned out to be a hypothesis nobody had re-run.

Work in a **disposable worktree**, never the review worktree. Restore it byte-identically when
done and quote `git status --short` verbatim in your output as proof.

**Mutate order, not just presence.** Deleting a call is the mutation a suite is most likely to
catch; *moving* it is the one that slips through. A suite can pin that a thing HAPPENS while
saying nothing about it happening FIRST — and ordering is where the real defects were:

- move a teardown/stop call to after the state it was meant to fence
- move a timestamp read to after the operation it was meant to precede
- swap the order of two appends, opens, or closes that share a lock
- flip a comparison boundary (`<` ↔ `<=`) on a guard
- replace a tuned constant (timeout, threshold, budget) with a neighbouring value

A surviving constant mutation usually means the test harness pins its own value and the shipped
default is never exercised.

Report each survivor with the mutation applied, the suite result, and the harm it implies if
real. That is `executed` provenance; a mutation you reasoned about but did not run is not.

## Categories

### Missing Negative-Path Tests
- New code paths that handle errors, rejections, or invalid input with NO corresponding test
- Guard clauses and early returns that are untested
- Error branches in try/catch, rescue, or error boundaries with no failure-path test
- Permission/auth checks that are asserted in code but never tested for the "denied" case

### Missing Edge-Case Coverage
- Boundary values: zero, negative, max-int, empty string, empty array, nil/null/undefined
- Single-element collections (off-by-one on loops)
- Unicode and special characters in user-facing inputs
- Concurrent access patterns with no race-condition test

### Test Isolation Violations
- Tests sharing mutable state (class variables, global singletons, DB records not cleaned up)
- Order-dependent tests (pass in sequence, fail when randomized)
- Tests that depend on system clock, timezone, or locale
- Tests that make real network calls instead of using stubs/mocks

### Flaky Test Patterns
- Timing-dependent assertions (sleep, setTimeout, waitFor with tight timeouts)
- Assertions on ordering of unordered results (hash keys, Set iteration, async resolution order)
- Tests that depend on external services (APIs, databases) without fallback
- Randomized test data without seed control

### Security Enforcement Tests Missing
- Auth/authz checks in controllers with no test for the "unauthorized" case
- Rate limiting logic with no test proving it actually blocks
- Input sanitization with no test for malicious input
- CSRF/CORS configuration with no integration test

### Coverage Gaps
- New public methods/functions with zero test coverage
- Changed methods where existing tests only cover the old behavior, not the new branch
- Utility functions called from multiple places but tested only indirectly
