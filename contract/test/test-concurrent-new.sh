#!/usr/bin/env bash
# Two stale-lock reapers must not remove a live creator's replacement lock.
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 "$HERE/concurrent-new.py" "$HERE/../bin/contract" 1
