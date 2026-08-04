#!/usr/bin/env bash
# Shared assertions + git sandbox for contract skill tests.
set -uo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT="$_HERE/bin/contract"
HOOKS="$_HERE/hooks"
FAILURES=0

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

finish() { sandbox_rm; exit "$FAILURES"; }
