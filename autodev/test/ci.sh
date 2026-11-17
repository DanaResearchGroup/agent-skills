#!/usr/bin/env bash
# Run every autodev watcher test. Exits non-zero if any test fails.
HERE="$(cd "$(dirname "$0")" && pwd)"
rc=0
# Owner order 2026-11-17: nothing under bin/ ever sends /usage-credits. The one
# allowed hit is limit-banner.py's pattern for the banner's own hint line.
hits=$( { grep -rniE 'usage[-_ ]?credits' "$HERE/../bin" | grep -vF "limit-banner.py:"
          grep -niE 'usage[-_ ]?credits' "$HERE/../bin/limit-banner.py" |
            grep -vF 're.compile(r"^/usage-credits to finish what you'; } )
if [ -n "$hits" ]; then
  printf '\033[31mFAIL\033[0m autodev/bin names /usage-credits (owner order: never send it):\n%s\n' "$hits"
  rc=1
fi
for t in "$HERE"/test-*.sh; do
  printf '\n\033[1m--- %s\033[0m\n' "${t##*/}"
  bash "$t" || rc=1
done
printf '\n'
[ "$rc" -eq 0 ] && printf '\033[32mALL TESTS PASSED\033[0m\n' || printf '\033[31mSOME TESTS FAILED\033[0m\n'
exit "$rc"
