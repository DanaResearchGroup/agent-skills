#!/usr/bin/env bash
# migrate-spar-bindings.sh — upgrade existing sparring stores from a worktree
# binding (repo_root=) to a repository binding (repo_id=).
#
# Usage:  migrate-spar-bindings.sh [--apply] [adversarial-dir]
#         (dry run by default; --apply writes)
#
# Run this ONCE, while the evidence still exists. A store can only be migrated
# from a repo_root path that is still on disk — resolve it to its repository and
# the binding survives every future merge. Once that worktree is pruned the proof
# is gone for good, and the store falls back to the runtime adopt-and-record path
# in spar-binding.sh. Migrating early is what keeps a healthy store out of that
# bucket; it is not a cleanup of broken ones.
set -euo pipefail

APPLY=0
DIR="$HOME/agents/adversarial"
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) DIR=$arg ;;
  esac
done
[ -d "$DIR" ] || { echo "migrate-spar-bindings: no such directory: $DIR" >&2; exit 2; }

# Mirrors repo_identity in spar-binding.sh — same env clearing (GIT_DIR and
# friends otherwise describe a different repository) and the same refusal to
# guess for a checkout git cannot resolve.
repo_identity() {
  local d=$1 common
  common=$(cd "$d" 2>/dev/null && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR \
    -u GIT_CEILING_DIRECTORIES -u GIT_DISCOVERY_ACROSS_FILESYSTEM \
    -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
    git rev-parse --git-common-dir 2>/dev/null) || common=""
  if [ -n "$common" ]; then
    (cd "$d" && cd "$common" && pwd -P)
    return 0
  fi
  [ -e "$d/.git" ] && return 3      # broken checkout: refuse to mint an identity
  (cd "$d" && pwd -P)
}

# Seconds to wait for a store's .lock before skipping it. Overridable so the
# test suite does not spend 30s proving the lock is honoured.
LOCK_WAIT=${SPAR_LOCK_WAIT:-30}

NOW=$(date +"%Y.%m.%d %H.%M.%S")
migrated=0; already=0; deferred=0; unresolved=0

for meta in "$DIR"/*/.project; do
  [ -e "$meta" ] || continue
  slug=$(basename "$(dirname "$meta")")

  # Identities the file ALREADY records. A store part-way through migration can
  # hold repo_id=A while a legacy repo_root=B is still live and still valid, so
  # "has a repo_id" is not the same as "fully migrated" — top up what is missing
  # rather than skipping the file.
  have=()
  while IFS= read -r id; do
    [ -n "$id" ] && have+=("$id")
  done < <(sed -n 's/^repo_id=//p' "$meta")

  ids=()
  broken=()
  while IFS= read -r root; do
    [ -n "$root" ] && [ -d "$root" ] || continue
    # A live path we cannot resolve is not the same as a dead one. Reporting it
    # as "no surviving path" would silently discard live evidence.
    if ! id=$(repo_identity "$root"); then
      broken+=("$root")
      continue
    fi
    dup=0
    for seen in ${ids+"${ids[@]}"} ${have+"${have[@]}"}; do
      [ "$seen" = "$id" ] && { dup=1; break; }
    done
    [ "$dup" -eq 1 ] || ids+=("$id")
  done < <(sed -n 's/^repo_root=//p' "$meta")

  if [ ${#broken[@]} -gt 0 ]; then
    # Report every one, and never silently. A live path we could not read is the
    # one case where this script must not claim to have finished a store.
    for r in "${broken[@]}"; do
      printf 'BROKEN   %-42s %s exists but git cannot resolve it\n' "$slug" "$r"
    done
    unresolved=$((unresolved + 1))
  fi

  if [ ${#ids[@]} -eq 0 ] && [ ${#have[@]} -gt 0 ]; then
    already=$((already + 1))
    continue
  fi

  if [ ${#ids[@]} -eq 0 ]; then
    # Nothing can prove this store's repository now. Left for spar-binding.sh,
    # which adopts on the next round when nothing at all survives, and refuses
    # when a broken path is present.
    if [ ${#broken[@]} -eq 0 ]; then
      printf 'DEFER    %-42s no surviving repo_root path\n' "$slug"
      deferred=$((deferred + 1))
    fi
    continue
  fi

  printf 'MIGRATE  %-42s -> %s\n' "$slug" "${ids[*]}"
  migrated=$((migrated + 1))
  [ "$APPLY" -eq 1 ] || continue

  # Take the store's own lock, the same one /spar uses, so a migration run
  # during a live round cannot interleave with the binding's read-modify-write.
  lock="$(dirname "$meta")/.lock"
  waited=0
  until mkdir "$lock" 2>/dev/null; do
    waited=$((waited + 1))
    if [ "$waited" -gt "$LOCK_WAIT" ]; then
      printf 'SKIP     %-42s store is locked by a live round\n' "$slug"
      break
    fi
    sleep 1
  done
  [ "$waited" -gt "$LOCK_WAIT" ] && continue

  tmp="$meta.tmp.$$"
  cp "$meta" "$tmp"
  [ -n "$(tail -c1 "$tmp")" ] && printf '\n' >> "$tmp"
  for id in "${ids[@]}"; do printf 'repo_id=%s\n' "$id" >> "$tmp"; done
  printf 'migrated_at=%s reason=worktree binding resolved to repository identity\n' "$NOW" >> "$tmp"
  mv "$tmp" "$meta"
  rmdir "$lock" 2>/dev/null || true
done

printf -- '---\n%d to migrate, %d already bound by repo_id, %d deferred (no surviving path).\n' \
  "$migrated" "$already" "$deferred"
[ "$unresolved" -gt 0 ] && printf '%d store(s) have a live path git cannot resolve -- see BROKEN above.\n' "$unresolved"
[ "$APPLY" -eq 1 ] || printf 'Dry run. Re-run with --apply to write.\n'
exit 0
