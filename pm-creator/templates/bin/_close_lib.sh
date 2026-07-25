#!/usr/bin/env bash
# _close_lib.sh — close-and-archive core, split out of _lib.sh (I24).
#
# Sourced by _lib.sh (never executed, never sourced directly): every script
# that sources _lib.sh keeps seeing pm_close_issue and its helpers with no
# consumer changes. Uses only _lib.sh public API (pm_apply / pm_fold /
# pm_lock / pm_unlock) plus the PM_ROOT pinning convention documented in
# _lib.sh; see the FROZEN API table there for the pm_close_issue signature.

# ---------------------------------------------------------------------------
# pm_close_issue — in-process, lock-reentrant core of `bin/close`
# ---------------------------------------------------------------------------

_pm_close_issue_state() {
  # _pm_close_issue_state <I-###> <index_json_path>
  # Echo the issue's current folded state, or "NONE" if it never appeared.
  # Mirrors record's / close's own local `_issue_state` (duplicated rather
  # than shared, same as record/close/dispatch-prep each keep their own
  # root-resolution copy — see the FROZEN API note at the top of this file).
  local id="$1" index="$2"
  ISSUE_ID="$id" python3 -c "
import json, os, sys
idx = json.load(open(sys.argv[1]))
i = os.environ['ISSUE_ID']
st = idx.get('issues', {}).get(i)
print((st or {}).get('state') or 'NONE')
" "$index"
}

pm_close_issue() {
  # pm_close_issue <repo_root> <I-###> [--dry-run]
  # Sourceable, in-process equivalent of `bin/close`'s core: transitions
  # <I-###> to CLOSED (idempotent: skipped if already CLOSED) and archives
  # its ephemeral prompts/<I-###>_* and messages/<I-###>_* files into
  # archive/{prompts,messages}/ (git-mv when tracked, else mv; skip with a
  # warning rather than clobber an existing archive/ file). `reports/` is
  # never touched.
  #
  # Both the issue_state transition and the audit `note --ref
  # archived:<I-###>` are emitted via `pm_apply` DIRECTLY, in-process —
  # never by shelling out to `record` as a subprocess. That is the entire
  # reason this function exists: `pm_lock` is reentrant only within a
  # single sourced shell process (depth counter), so a caller that already
  # holds `pm_lock` (e.g. a future `bin/track` auto-close pass) and invokes
  # this function in-process safely RE-ENTERS the same lock, whereas
  # shelling out to a `record` subprocess would try to acquire a brand-new
  # lock and block forever waiting on the lock its own parent process is
  # holding. A standalone caller with no pre-held lock gets a freshly
  # acquired lock around the whole operation, same net effect as before.
  #
  # Refuses (returns 1, message on stderr) if the issue was never
  # registered, or if any archive move fails partway through (see
  # _pm_close_issue_core). `--dry-run` prints what would happen and returns
  # 0 without emitting any event or moving any file. Returns 2 on a usage
  # error (no lock is taken in that case).
  #
  # This outer function is a thin lock/PM_ROOT unwind shell around
  # _pm_close_issue_core: cleanup (PM_ROOT restore + pm_unlock) always runs
  # exactly once on every path once the lock is held, because the core's
  # result is captured via an `if core; then ... else ...; fi` — a checked
  # context — rather than letting any internal failure inside the core
  # propagate as a bare `set -e` abort past this function's tail.
  local root="${1:-}" issue_id="${2:-}"
  if [[ $# -ge 2 ]]; then shift 2; else shift "$#"; fi
  local dry_run=0 arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry_run=1 ;;
      *)
        echo "close: unknown argument '$arg'" >&2
        return 2
        ;;
    esac
  done

  if [[ -z "$root" || -z "$issue_id" ]]; then
    echo "close: usage: pm_close_issue <repo_root> <I-###> [--dry-run]" >&2
    return 2
  fi
  if [[ ! "$issue_id" =~ ^I-[0-9]+$ ]]; then
    echo "close: issue id must look like I-### (got '$issue_id')" >&2
    return 2
  fi

  # pm_apply/pm_fold/pm_lock resolve root via $PM_ROOT (else cwd search),
  # not via an explicit argument — pin $PM_ROOT to the given root for the
  # duration so a caller whose cwd isn't the repo root still lands events
  # in the right place, then restore whatever the caller had.
  local had_pm_root=0 prev_pm_root=""
  if [[ -n "${PM_ROOT+x}" ]]; then
    had_pm_root=1
    prev_pm_root="$PM_ROOT"
  fi
  export PM_ROOT="$root"

  if ! pm_lock "$root"; then
    if [[ "$had_pm_root" -eq 1 ]]; then
      export PM_ROOT="$prev_pm_root"
    else
      unset PM_ROOT
    fi
    return 1
  fi

  local rc=0
  if _pm_close_issue_core "$root" "$issue_id" "$dry_run"; then
    rc=0
  else
    rc=$?
  fi

  if [[ "$had_pm_root" -eq 1 ]]; then
    export PM_ROOT="$prev_pm_root"
  else
    unset PM_ROOT
  fi

  pm_unlock
  return "$rc"
}

_pm_close_issue_core() {
  # _pm_close_issue_core <repo_root> <I-###> <dry_run:0|1>
  # The lock-held, PM_ROOT-pinned body of pm_close_issue. Every fallible
  # command in here is explicitly checked (never a bare command whose
  # failure would trigger an uncaught `set -e` abort) so that returning is
  # always reached and pm_close_issue's cleanup tail always runs.
  local root="$1" issue_id="$2" dry_run="$3"
  local rc=0
  local index="${root}/.pm/index.json"

  # P3-4: every refusal class below opens its stderr line with a STABLE
  # machine-readable token (close-refused-unfoldable-log /
  # close-refused-never-registered / close-refused-state-race), and a
  # durable-but-incomplete close additionally emits close-transition-durable
  # before returning -- callers (track's auto-close classifier) key on
  # these exact tokens; change them in both places or not at all.
  pm_fold "$root" || {
    echo "close-refused-unfoldable-log: pm_fold failed; refusing to close $issue_id against an unfoldable log" >&2
    rc=1
  }
  if [[ "$rc" -eq 0 && ! -f "$index" ]]; then
    echo "close: no index at $index after fold" >&2
    rc=1
  fi

  local from_state=""
  if [[ "$rc" -eq 0 ]]; then
    from_state="$(_pm_close_issue_state "$issue_id" "$index")"
    if [[ "$from_state" == "NONE" ]]; then
      echo "close-refused-never-registered: refusing to close $issue_id: it was never registered (no issue_state event on record). You cannot close an issue that was never opened." >&2
      rc=1
    fi
  fi

  # NOTE: `did_something` tracks whether at least one file was ACTUALLY
  # archived below -- it must NOT be set by the transition alone, or a
  # transition-succeeded-but-archive-entirely-failed run would still emit a
  # false `note --ref archived:<I>` audit event (FIX-1).
  #
  # `did_transition` (FIX-B) tracks separately whether the CLOSED
  # `issue_state` event was actually emitted this run. Pre-refactor `close`
  # semantics: the `archived:<I>` note fires whenever the transition
  # happened OR any file was archived -- a pure close with zero files to
  # archive must still get the note + "done" outcome (it is not a no-op).
  local did_something=0
  local did_transition=0
  if [[ "$rc" -eq 0 ]]; then
    if [[ "$from_state" == "CLOSED" ]]; then
      echo "close: $issue_id already CLOSED; skipping transition"
    elif [[ "$dry_run" -eq 1 ]]; then
      echo "would close $issue_id (currently $from_state)"
    else
      local apply_out
      if apply_out="$(pm_apply issue_state i="$issue_id" from="$from_state" to=CLOSED at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>&1 1>/dev/null)"; then
        did_transition=1
      else
        echo "close-refused-state-race: refusing to close $issue_id: current=$from_state requested=CLOSED ($apply_out). No event was emitted." >&2
        rc=1
      fi
    fi
  fi

  # Archive ephemeral working files. Deliberately still done under the same
  # held pm_lock as the transition above (atomic close+archive): archive
  # I/O here is fast local mkdir/mv/git-mv on a handful of files, so the
  # lock-contention window this adds for any other waiter is bounded; a
  # crash mid-archive leaves the log/index consistent (the transition event,
  # if any, is already durably appended) and a re-run of close/track's
  # auto-close finishes the archive idempotently.
  local archive_failed=0
  if [[ "$rc" -eq 0 ]]; then
    local subdir src_dir dest_dir f base dest relpath mkdir_err mv_err
    for subdir in prompts messages; do
      src_dir="${root}/${subdir}"
      dest_dir="${root}/archive/${subdir}"

      if [[ "$dry_run" -ne 1 ]]; then
        if ! mkdir_err="$(mkdir -p "$dest_dir" 2>&1)"; then
          echo "close: failed to create archive/${subdir}/ ($mkdir_err); ${subdir}/${issue_id}_* left unarchived" >&2
          archive_failed=1
          continue
        fi
      fi
      [[ -d "$src_dir" ]] || continue

      for f in "$src_dir/${issue_id}_"*; do
        [[ -e "$f" ]] || continue # no match (glob didn't expand)
        base="$(basename "$f")"
        dest="${dest_dir}/${base}"
        relpath="${subdir}/${base}"

        if [[ -e "$dest" ]]; then
          echo "close: WARNING: archive/${subdir}/${base} already exists; skipping (not clobbering)" >&2
          continue
        fi

        if [[ "$dry_run" -eq 1 ]]; then
          echo "would archive: ${subdir}/${base} -> archive/${subdir}/${base}"
          continue
        fi

        if git -C "$root" rev-parse --is-inside-work-tree > /dev/null 2>&1 \
          && git -C "$root" ls-files --error-unmatch "$relpath" > /dev/null 2>&1; then
          if ! mv_err="$(git -C "$root" mv "$relpath" "archive/${subdir}/${base}" 2>&1)"; then
            echo "close: failed to archive ${subdir}/${base} (git mv: $mv_err)" >&2
            archive_failed=1
            continue
          fi
        else
          if ! mv_err="$(mv "$f" "$dest" 2>&1)"; then
            echo "close: failed to archive ${subdir}/${base} (mv: $mv_err)" >&2
            archive_failed=1
            continue
          fi
        fi
        echo "close: archived ${subdir}/${base} -> archive/${subdir}/${base}"
        did_something=1
      done
    done
  fi

  # FIX-A: a failed/partial archive must never emit the `archived:<I>` note
  # -- fold `archive_failed` into `rc` BEFORE the note-emission decision
  # below, so a partial failure returns nonzero, emits NO note, and leaves
  # the CLOSED transition + already-moved files in place (idempotent). A
  # subsequent re-run (issue already CLOSED -> transition skipped) archives
  # the remaining files cleanly and emits the note exactly once.
  if [[ "$rc" -eq 0 && "$archive_failed" -eq 1 ]]; then
    rc=1
  fi

  if [[ "$rc" -eq 0 ]]; then
    if [[ "$dry_run" -eq 1 ]]; then
      echo "close: dry-run complete for $issue_id; nothing moved, no event emitted"
    elif [[ "$did_transition" -eq 1 || "$did_something" -eq 1 ]]; then
      # FIX-B: the note (and "done" outcome) fires whenever the CLOSED
      # transition happened this run OR any file was archived this run --
      # matches pre-refactor `close` semantics. A pure close with zero
      # files to archive is NOT a no-op.
      local note_out
      if note_out="$(pm_apply note at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" ref="archived:${issue_id}" i="$issue_id" 2>&1 1>/dev/null)"; then
        echo "close: $issue_id done (transition + archive recorded)"
      else
        echo "close: refusing note ref=archived:${issue_id} ($note_out). No event was emitted." >&2
        rc=1
      fi
    else
      echo "close: $issue_id already closed and nothing to archive; no-op"
    fi
  fi

  # P3-4: durability signal -- when the CLOSED transition is durably on the
  # log (emitted this run, or already there for the rearchive path) but a
  # LATER step (archive/note) failed, say so with a stable token so callers
  # can count the issue closed-with-pending-archive instead of "not closed".
  if [[ "$dry_run" -ne 1 && "$rc" -ne 0 ]]; then
    if [[ "$did_transition" -eq 1 || "$from_state" == "CLOSED" ]]; then
      echo "close-transition-durable: $issue_id is durably CLOSED on the log; a later archive/note step failed" >&2
    fi
  fi

  return "$rc"
}
