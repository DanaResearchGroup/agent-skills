#!/usr/bin/env bash
# Shared assertions + git sandbox for contract skill tests.
set -uo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT="$_HERE/bin/contract"
HOOKS="$_HERE/hooks"
FAILURES=0

# See the guard block below (near the assertion helpers) for why this file
# exists: it is the only channel out of a bash command_not_found_handle,
# which always runs in a subshell.
HARNESS_FAULTS="$(mktemp "${TMPDIR:-/tmp}/contract-harness-faults.XXXXXX")"

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILURES=1; }

assert_eq() {  # want got label
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (want '$1', got '$2')"; fi
}

assert_contains() {  # haystack needle label
  case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 (missing '$2')" ;; esac
}

assert_not_contains() {  # haystack needle label
  case "$1" in *"$2"*) fail "$3 (unexpectedly contains '$2')" ;; *) pass "$3" ;; esac
}

assert_file() {  # path label
  if [ -f "$1" ]; then pass "$2"; else fail "$2 (missing file: $1)"; fi
}

assert_no_file() {  # path label
  if [ -e "$1" ]; then fail "$2 (unexpected file: $1)"; else pass "$2"; fi
}

# An unknown command is a HARNESS failure, not a silence: a test that calls a
# helper this lib never defined prints "command not found" to stderr, and its
# assertions count as neither pass nor fail -- the suite reports green over a
# property nothing checked. (That is not hypothetical; it is why the sibling
# private repo grew this guard.)
#
# The handler runs in a SUBSHELL (probed, bash 5.2.21), so a counter it
# increments is discarded when the subshell exits. A subshell can still make a
# filesystem effect, so the fault is recorded as a file and `finish` fails on it.
command_not_found_handle() {
  fail "harness: unknown command '$1' -- a test called a helper this harness does not define; the assertions in that section did not run"
  printf '%s\n' "$1" >>"$HARNESS_FAULTS"
  return 127
}

# Temp repo + one linked worktree. Sets SANDBOX, REPO, WT, COMMON.
sandbox_new() {
  SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/contract-test-XXXXXX")
  REPO="$SANDBOX/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name tester
  echo seed > "$REPO/seed.txt"
  git -C "$REPO" add seed.txt
  git -C "$REPO" commit -qm init
  WT="$SANDBOX/wt"
  git -C "$REPO" worktree add -q "$WT" -b feature
  COMMON="$REPO/.git"
}

sandbox_rm() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; }

finish() {
  # The guard above runs in a SUBSHELL, so its fail never reached FAILURES
  # -- this file is the only channel out of it.
  if [ -s "$HARNESS_FAULTS" ]; then
    FAILURES=1
  fi
  rm -f "$HARNESS_FAULTS"

  sandbox_rm
  exit "$FAILURES"
}
