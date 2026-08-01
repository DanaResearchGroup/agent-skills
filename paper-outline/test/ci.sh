#!/usr/bin/env bash
# Entry point discovered by .github/workflows/ci.yml (the <skill>/test/ci.sh
# convention). Exits non-zero if any test fails.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# The renderer's one dependency. CI ships a bare python, so install it there;
# locally, leave whatever the user already has alone.
if ! python3 -c 'import docx' 2>/dev/null; then
  echo "installing python-docx"
  python3 -m pip install --quiet --disable-pip-version-check python-docx || {
    echo "could not install python-docx" >&2
    exit 1
  }
fi

rc=0
for t in "$HERE"/test-*.py; do
  printf '\n\033[1m--- %s\033[0m\n' "${t##*/}"
  python3 "$t" || rc=1
done

printf '\n'
if [ "$rc" -eq 0 ]; then
  printf '\033[32mALL TESTS PASSED\033[0m\n'
else
  printf '\033[31mSOME TESTS FAILED\033[0m\n'
fi
exit "$rc"
