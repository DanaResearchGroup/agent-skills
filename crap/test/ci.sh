#!/usr/bin/env bash
# crap skill test suite. Non-zero exit fails CI.
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 -m unittest -v "$HERE/test_crap.py"
