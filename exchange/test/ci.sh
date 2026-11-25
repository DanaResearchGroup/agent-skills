#!/usr/bin/env bash
# exchange skill test suite. Non-zero exit fails CI.
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE" && python3 -m unittest -v test_exchange
