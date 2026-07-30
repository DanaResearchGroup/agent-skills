#!/usr/bin/env bash
# Run every autodev watcher test. Exits non-zero if any test fails.
HERE="$(cd "$(dirname "$0")" && pwd)"
rc=0
for t in "$HERE"/test-*.sh; do
  printf '\n\033[1m--- %s\033[0m\n' "${t##*/}"
  bash "$t" || rc=1
done
printf '\n'
[ "$rc" -eq 0 ] && printf '\033[32mALL TESTS PASSED\033[0m\n' || printf '\033[31mSOME TESTS FAILED\033[0m\n'
exit "$rc"
