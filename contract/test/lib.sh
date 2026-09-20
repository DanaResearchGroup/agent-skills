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
HARNESS_FAULTS="$(mktemp "${TMPDIR:-/tmp}/contract-harness-faults.XXXXXX")" || exit 1
# Without this file the unknown-command guard below has no channel out of its
# subshell, so a test calling an undefined helper would go back to passing
# silently — the exact failure the guard exists to stop.
[ -f "$HARNESS_FAULTS" ] || { printf 'harness: cannot create the fault file\n' >&2; exit 1; }

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

# Path -> state key: readable tail plus a digest of the whole path. Deliberately
# a second copy of the formula in bin/contract — a test that asked the tool under
# test where its state lives could not catch it putting state somewhere else.
_pathkey() {
  local tail hash
  tail=$(printf '%s' "$1" | sed 's|.*/\([^/]*/[^/]*\)$|\1|' \
    | tr -c 'A-Za-z0-9._-' '-' | sed 's/^-*//' | cut -c1-60)
  if command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$1" | sha256sum | cut -c1-16)
  elif command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$1" | shasum -a 256 | cut -c1-16)
  else
    hash=$(printf '%s' "$1" | cksum | tr -dc '0-9' | cut -c1-16)
  fi
  printf '%s-%s\n' "$tail" "$hash"
}

# Temp repo + one linked worktree. Sets SANDBOX, REPO, WT, COMMON, and the
# external state paths: STATE (per repo), WSTATE (notes for WT), RSTATE (notes
# for the main checkout). CONTRACT_STATE_DIR is EXPORTED — it must reach the
# gate hook's own `contract` subprocess, and it keeps a test run from writing
# into the real ~/agents/state.
sandbox_new() {
  # An empty SANDBOX would aim every path below at /state, /repo and /wt — real
  # root-level paths a privileged CI run could actually create or modify.
  SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/contract-test-XXXXXX") || exit 1
  [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { printf 'harness: mktemp -d failed\n' >&2; exit 1; }
  export CONTRACT_STATE_DIR="$SANDBOX/state"
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
  STATE="$CONTRACT_STATE_DIR/$(_pathkey "$COMMON")"
  WSTATE="$STATE/worktrees/$(_pathkey "$WT")"
  RSTATE="$STATE/worktrees/$(_pathkey "$REPO")"
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
