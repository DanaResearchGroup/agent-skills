# Dispatch: fix flaky retry loop

| field | value |
| --- | --- |
| ticket | I-005 |
| tab | i005-fix-retry |

## Prompt (paste below this line)

You are working in the worktree at `/home/alon/Code/example-app-fix-retry`
on branch `fix-retry`. Run `pytest tests/test_retry.py -x` and make it pass
without changing the public API of `retry.py`.

When you report back, cite D-005 so the result gets filed correctly.

Ground truth: the flaky assertion is at `tests/test_retry.py:42`. The
commit that introduced it is `a1b2c3d4`.
