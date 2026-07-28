#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
proposals_dir="$(dirname "$here")"

export PYTHONPATH="${proposals_dir}${PYTHONPATH:+:${PYTHONPATH}}"

echo "auto-proposals: running unit tests from ${here}"
python3 -m unittest discover -s "$here" -p 'test_*.py' -v
echo "auto-proposals: all tests passed"
