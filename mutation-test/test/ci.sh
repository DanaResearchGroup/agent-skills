#!/usr/bin/env bash
# mutation-test skill test suite. Non-zero exit fails CI.
# Needs cosmic-ray: uses $PYTHON (or python3) when it can import it, else a throwaway venv.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PY="${PYTHON:-python3}"
if ! "$PY" -c 'import cosmic_ray' 2>/dev/null; then
  venv="$(mktemp -d)/venv"
  trap 'rm -rf "$(dirname "$venv")"' EXIT
  python3 -m venv "$venv"
  "$venv/bin/pip" install -q 'cosmic-ray>=8.7,<9'
  PY="$venv/bin/python"
fi
"$PY" -m unittest -v "$HERE/test_mutation_test.py"
