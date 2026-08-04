#!/usr/bin/env bash
# Contract skill test suite. Non-zero exit fails CI.
HERE="$(cd "$(dirname "$0")" && pwd)"
rc=0
for t in "$HERE"/test-*.sh; do
  printf '\n\033[1m--- %s\033[0m\n' "${t##*/}"
  bash "$t" || rc=1
done
printf '\n'
if [ "$rc" -eq 0 ]; then
  printf '\033[32mALL TESTS PASSED\033[0m\n'
else
  printf '\033[31mSOME TESTS FAILED\033[0m\n'
fi
exit "$rc"
