#!/usr/bin/env bash
# factory-machine tests; CI runs every */test/ci.sh. Exits non-zero on any failure.
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 -m unittest discover -s "$HERE" -p 'test_*.py' -v
