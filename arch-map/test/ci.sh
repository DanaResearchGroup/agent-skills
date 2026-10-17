#!/usr/bin/env bash
# arch-map skill test suite. Non-zero exit fails CI.
cd "$(dirname "$0")" && python3 -m unittest -v test_arch_map
