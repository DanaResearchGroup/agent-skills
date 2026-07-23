#!/usr/bin/env bash
# _lib.sh — pm-creator keystone library.
#
# This is a TEMPLATE file: it is copied verbatim into a generated PM repo's
# `bin/` directory and `source`-d by sibling scripts (reconcile, lint-prompt,
# ledger-check, dispatch-prep, record, ...). It is self-contained (bash +
# python3 only, no jq) and locates `.pm/` relative to the caller's cwd (or an
# explicit repo-root argument / $PM_ROOT override) rather than to its own
# path, since the generated repo root is wherever the sibling script runs.
#
# FROZEN API — every function signature below is depended on by downstream
# scripts. Treat signature changes as breaking; add, don't rename/reshape.
#
#   pm_lock        [repo_root]                -- acquire .pm/.lock (mkdir-based)
#   pm_unlock                                  -- release the most recent pm_lock
#   pm_apply        <type> <k=v> [<k=v> ...]   -- validate + atomically apply ONE event
#   pm_apply_batch  -- <type> <k=v>... [-- <type> <k=v>...]
#                                               -- validate + atomically apply SEVERAL
#                                                  events as one transaction
#   pm_fold        [repo_root]                -- fold .pm/events.log -> .pm/index.json
#   pm_git_probe   <repo_path>                 -- echo JSON snapshot of a repo's real state
#   esc_shell      <string>                    -- echo a shell-safe single-quoted token
#   esc_md         <string>                    -- echo a Markdown-safe token
#   esc_json       <string>                    -- echo a JSON-string-safe token (no quotes)
#   esc_path       <string>                    -- echo a path-safe token (no leading '-', no glob hazard)
#   esc_gitref     <string>                    -- echo a git-ref-safe token
#
# `pm_raw_append` (formerly the public `pm_emit`) does NOT exist in this
# shipped file: a grammar-only, rule-engine-bypassing appender must never be
# reachable from a generated repo. The test-only equivalent (grammar-only
# validation + lock-guarded raw append, WITHOUT transition legality, attempt
# minting, or duplicate/supersede/lane checks) lives in `test/_seed.sh`,
# which tests `source` AFTER this file so it can reuse the grammar tables
# below. The only sanctioned way to append to the log, in shipped code, is
# `pm_apply` / `pm_apply_batch`.
#
# Root resolution (pm_lock / pm_apply / pm_fold): if $PM_ROOT is set, use it;
# else search upward from $PWD for a directory containing `.pm/`; else error.
# pm_git_probe takes an explicit repo path and never consults $PM_ROOT.
#
# NOTE (grammar ambiguity): the frozen grammar doc (references/event-log-grammar.md)
# defines the required/optional key table per event type but does not say
# whether OTHER keys are forbidden. The broader pm-creator spec explicitly
# says "unknown keys are ignored by old parsers" (forward-compat header
# versioning intent) — so the engine accepts and silently passes through any
# key not in a type's known set, rather than treating it as a grammar error.
#
# NOTE (enforcement, per references/enforcement.md): there is ONE rule set
# (shared python function `apply_event`, embedded once as `_PM_ENGINE_PY`),
# applied at exactly two points: `pm_apply`/`pm_apply_batch` (write path,
# strict mode — refuses and appends nothing on violation) and `pm_fold`
# (read path, quarantine mode — routes violating lines to
# .pm/quarantine.log and excludes them from the fold). `pm_apply` also runs
# the SAME engine in quarantine mode once, internally, to re-establish
# current state from the existing log before validating the new candidate
# event(s) in strict mode — this is not a third enforcement point, it is
# `pm_fold`'s own logic reused to answer "what is current state right now".
#
# NOTE (grammar ambiguity, resolved per enforcement.md §8): `unregistered[]`
# entries are deduped by `ref` (first occurrence wins) when `index.json` is
# written.
#
# NOTE (grammar ambiguity): `adopt` (d a at ref) is recorded informationally
# on the dispatch (field `adopted_ref`) but does not remove/consume matching
# entries from `unregistered[]`, since the grammar gives no key that
# guarantees a 1:1 match between an `unregistered_execution.ref` and an
# `adopt.ref` (ref is a free token). Left for `reconcile`/`ledger-check` to
# reconcile with richer context; noted here rather than guessed at.

# ---------------------------------------------------------------------------
# internals
# ---------------------------------------------------------------------------

_PM_LOCK_DEPTH=0
_PM_LOCK_DIR=""

_pm_root() {
  # Usage: _pm_root [explicit_root]
  local explicit="${1:-}"
  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  if [[ -n "${PM_ROOT:-}" ]]; then
    printf '%s\n' "$PM_ROOT"
    return 0
  fi
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    if [[ -d "$dir/.pm" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  if [[ -d "/.pm" ]]; then
    printf '%s\n' "/"
    return 0
  fi
  echo "pm-creator: could not locate .pm/ (searched upward from $PWD; set \$PM_ROOT to override)" >&2
  return 1
}

# ---------------------------------------------------------------------------
# pm_lock / pm_unlock
# ---------------------------------------------------------------------------

pm_lock() {
  # pm_lock [repo_root]
  # Acquire an mkdir-based lock at <repo_root>/.pm/.lock. Re-entrant within a
  # single script's lifetime (nested pm_lock/pm_unlock pairs just adjust a
  # depth counter); a trap on EXIT/INT/TERM guarantees the lock directory is
  # removed even if the script is interrupted mid-critical-section. The
  # owner's PID is recorded in "$lockdir/pid" so a crashed/killed holder's
  # lock can be reclaimed (see _pm_lock_try_reclaim_stale, L2).
  local root
  root="$(_pm_root "${1:-}")" || return 1
  local lockdir="$root/.pm/.lock"

  if [[ "$_PM_LOCK_DEPTH" -gt 0 ]]; then
    _PM_LOCK_DEPTH=$((_PM_LOCK_DEPTH + 1))
    return 0
  fi

  local waited=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    if _pm_lock_try_reclaim_stale "$lockdir"; then
      continue
    fi
    if [[ "$waited" -ge 100 ]]; then
      echo "pm-creator: timed out waiting for lock $lockdir" >&2
      return 1
    fi
    sleep 0.1
    waited=$((waited + 1))
  done

  # L-low: a bare PID is a weak owner identity — PIDs get reused, so a
  # dead original holder's PID can be picked up by an unrelated live
  # process, making a genuinely stale lock look "live" and hang the
  # waiter for the full timeout instead of reclaiming it. Record PID +
  # process start-time (/proc/<pid>/stat field 22 on Linux) as a
  # composite identity; where /proc is unavailable this degrades to the
  # PID-only liveness check pm_lock already had.
  {
    printf '%s\n' "$$"
    _pm_lock_pid_start "$$" 2>/dev/null
  } > "$lockdir/pid" 2>/dev/null || true
  _PM_LOCK_DIR="$lockdir"
  _PM_LOCK_DEPTH=1
  # shellcheck disable=SC2064
  trap "_pm_lock_release_all" EXIT INT TERM
  return 0
}

_pm_lock_pid_start() {
  # _pm_lock_pid_start <pid> -- print that pid's process start-time token
  # (field 22 of /proc/<pid>/stat, Linux-only) or nothing if unavailable.
  # The comm field (field 2) is parenthesized and may itself contain
  # spaces/parens, so fields are counted from the LAST ')' rather than by
  # naive whitespace-splitting the whole line.
  local pid="$1" statfile content rest
  statfile="/proc/$pid/stat"
  [[ -r "$statfile" ]] || return 1
  content="$(cat "$statfile" 2>/dev/null)" || return 1
  rest="${content##*) }"
  [[ "$rest" == "$content" ]] && return 1
  local -a fields
  read -r -a fields <<< "$rest"
  # rest[0] is field 3 (state); field 22 (starttime) is therefore
  # rest[22-3] = rest[19].
  [[ -n "${fields[19]:-}" ]] || return 1
  printf '%s\n' "${fields[19]}"
}

_pm_lock_try_reclaim_stale() {
  # _pm_lock_try_reclaim_stale <lockdir>
  # L2: after a hard crash / `kill -9`, the mkdir-lock is never released and
  # a plain timeout just fails forever. If <lockdir>/pid names a PID that is
  # provably dead (kill -0 fails), reclaim the lock. L-low: also reclaim
  # when the PID is alive but its recorded start-time identity no longer
  # matches (the PID was reused by an unrelated, later process — the
  # original holder is just as gone as if it were dead). Race-safe: a
  # nested mkdir "<lockdir>/.reclaiming" is itself atomic, so of any number
  # of waiters that independently notice the same stale lock, exactly one
  # wins the right to remove it; the rest fall through and retry on the
  # next loop iteration.
  local lockdir="$1"
  local pidfile="$lockdir/pid"
  [[ -d "$lockdir" ]] || return 1
  local owner_pid="" owner_start=""
  if [[ -f "$pidfile" ]]; then
    owner_pid="$(sed -n '1p' "$pidfile" 2>/dev/null)"
    owner_start="$(sed -n '2p' "$pidfile" 2>/dev/null)"
  fi
  # A missing/unreadable/non-numeric pid file might mean a concurrent
  # racer is still between mkdir and writing its pid — do not reclaim.
  [[ "$owner_pid" =~ ^[0-9]+$ ]] || return 1
  local reason=""
  if ! kill -0 "$owner_pid" 2>/dev/null; then
    reason="owner pid $owner_pid is dead"
  else
    # PID is alive. Only treat it as a genuine identity mismatch (reused
    # PID) when we recorded a start-time AND can read the live process's
    # current start-time and the two disagree — if either is unavailable
    # (e.g. no /proc), we cannot prove mismatch, so degrade to the old
    # PID-liveness-only behavior and do not reclaim.
    if [[ -n "$owner_start" ]]; then
      local live_start
      live_start="$(_pm_lock_pid_start "$owner_pid" 2>/dev/null)"
      if [[ -n "$live_start" && "$live_start" != "$owner_start" ]]; then
        reason="owner pid $owner_pid is alive but its identity (start-time) no longer matches — PID reused"
      fi
    fi
  fi
  [[ -n "$reason" ]] || return 1
  if ! mkdir "$lockdir/.reclaiming" 2>/dev/null; then
    return 1
  fi
  echo "pm-creator: reclaiming stale lock $lockdir ($reason)" >&2
  rm -rf "$lockdir"
  return 0
}

_pm_lock_release_all() {
  if [[ -n "$_PM_LOCK_DIR" && -d "$_PM_LOCK_DIR" ]]; then
    rm -f "$_PM_LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$_PM_LOCK_DIR" 2>/dev/null || true
  fi
  _PM_LOCK_DIR=""
  _PM_LOCK_DEPTH=0
}

pm_unlock() {
  # pm_unlock
  # Release one level of the lock acquired by pm_lock. Only the outermost
  # pm_unlock in a nested pair actually removes the lock directory.
  if [[ "$_PM_LOCK_DEPTH" -le 0 ]]; then
    return 0
  fi
  _PM_LOCK_DEPTH=$((_PM_LOCK_DEPTH - 1))
  if [[ "$_PM_LOCK_DEPTH" -eq 0 ]]; then
    _pm_lock_release_all
  fi
  return 0
}

# ---------------------------------------------------------------------------
# grammar tables (bash associative arrays; single source of truth for
# test/_seed.sh's pm_raw_append grammar-only validation; the python engine
# below carries its own copy since it cannot source bash arrays, but the two
# are kept in lockstep by hand — see _PM_ENGINE_PY's
# REQUIRED/OPTIONAL/KEY_ORDER dicts). These tables are pure data (no
# appending), so they stay in the shipped engine for reuse by both.
# ---------------------------------------------------------------------------

declare -gA _PM_REQUIRED_KEYS=(
  [schema]="v"
  [issue_state]="i from to at"
  [dispatch_new]="d i at"
  [dispatch_state]="d from to lane at"
  [result]="d a status result_sha at"
  [question]="q state at"
  [unregistered_execution]="at ref"
  [adopt]="d a at ref"
  [note]="at ref"
)

declare -gA _PM_OPTIONAL_KEYS=(
  [schema]=""
  [issue_state]="by"
  [dispatch_new]="child_of supersedes"
  [dispatch_state]="a tab prompt_sha"
  [result]=""
  [question]="i a_of"
  [unregistered_execution]=""
  [adopt]=""
  [note]="d i"
)

# canonical key order for emitted lines (readability only; order is not
# grammar-significant per §1).
declare -gA _PM_KEY_ORDER=(
  [schema]="v"
  [issue_state]="i from to at by"
  [dispatch_new]="d i at child_of supersedes"
  [dispatch_state]="d a from to lane at tab prompt_sha"
  [result]="d a status result_sha at"
  [question]="q state at i a_of"
  [unregistered_execution]="at ref"
  [adopt]="d a at ref"
  [note]="at ref d i"
)

# NOTE (grammar ambiguity): §1 lists the value charset as
# `[A-Za-z0-9._:+/@-]` but then says in the same sentence that this "covers
# ... the literal `?`" (used for an unresolved `tab=?` at dispatch time,
# resolved at ACK). `?` is not actually in the printed charset, so the two
# clauses conflict. Strictest-but-still-usable reading: treat `?` as an
# additional allowed token value (the grammar's own prose says it must be
# accepted), rather than rejecting the exact token the spec's example uses.
_PM_TOKEN_RE='^[A-Za-z0-9._:+/@?-]+$'

# NOTE: `pm_raw_append` (TEST/FIXTURE-ONLY grammar-only append, bypassing the
# rule engine entirely) has been relocated to `test/_seed.sh`, which sources
# this file first and reuses the grammar tables above. It must never ship in
# this file — see the file-header NOTE.

# ---------------------------------------------------------------------------
# shared rule engine (python, embedded once) — the ONE validation rule set
# per enforcement.md §1: known type, required/duplicate/charset grammar
# (§2), issue transitions (§3), dispatch lifecycle incl. duplicate
# dispatch_new / RETURNED-not-a-dispatch_state / late-terminal (§4), result
# rules (§4.1), attempt minting/matching (§5), lane immutability (§6),
# superseding (§7). Two small drivers below invoke it: one for pm_fold
# (quarantine mode over the whole log), one for pm_apply/pm_apply_batch
# (quarantine mode once to re-establish current state, then strict mode per
# candidate event).
# ---------------------------------------------------------------------------

read -r -d '' _PM_ENGINE_PY <<'PYEOF' || true
import json
import os
import re
import sys

TOKEN_RE = re.compile(r'^[A-Za-z0-9._:+/@?-]+$')

REQUIRED = {
    "schema": ["v"],
    "issue_state": ["i", "from", "to", "at"],
    "dispatch_new": ["d", "i", "at"],
    "dispatch_state": ["d", "from", "to", "lane", "at"],
    "result": ["d", "a", "status", "result_sha", "at"],
    "question": ["q", "state", "at"],
    "unregistered_execution": ["at", "ref"],
    "adopt": ["d", "a", "at", "ref"],
    "note": ["at", "ref"],
}

# Relaxed requirement set for brand-new CANDIDATE events proposed to
# pm_apply/pm_apply_batch, distinct from REQUIRED (which governs parsing of
# already-persisted raw log lines). apply_event() auto-derives `from`
# (issue_state/dispatch_state), `lane` (dispatch_state), and `a`
# (dispatch_state/result) when the caller omits them, so callers need not
# supply them up front; by the time a candidate event is rendered to a log
# line, apply_event has filled them in and REQUIRED is satisfied.
REQUIRED_FOR_APPLY = {
    "schema": ["v"],
    "issue_state": ["i", "to", "at"],
    "dispatch_new": ["d", "i", "at"],
    "dispatch_state": ["d", "to", "at"],
    "result": ["d", "status", "result_sha", "at"],
    "question": ["q", "state", "at"],
    "unregistered_execution": ["at", "ref"],
    "adopt": ["d", "a", "at", "ref"],
    "note": ["at", "ref"],
}

OPTIONAL = {
    "schema": [],
    "issue_state": ["by"],
    "dispatch_new": ["child_of", "supersedes"],
    "dispatch_state": ["a", "tab", "prompt_sha"],
    "result": [],
    "question": ["i", "a_of"],
    "unregistered_execution": [],
    "adopt": [],
    "note": ["d", "i"],
}

# canonical key order for rendered log lines (readability only; order is not
# grammar-significant per §1). Must mirror bash's _PM_KEY_ORDER exactly.
KEY_ORDER = {
    "schema": ["v"],
    "issue_state": ["i", "from", "to", "at", "by"],
    "dispatch_new": ["d", "i", "at", "child_of", "supersedes"],
    "dispatch_state": ["d", "a", "from", "to", "lane", "at", "tab", "prompt_sha"],
    "result": ["d", "a", "status", "result_sha", "at"],
    "question": ["q", "state", "at", "i", "a_of"],
    "unregistered_execution": ["at", "ref"],
    "adopt": ["d", "a", "at", "ref"],
    "note": ["at", "ref", "d", "i"],
}

TERMINAL = {"VERIFIED", "ABANDONED"}

# Legal dispatch_state edges per enforcement.md §4 table (and NOTHING else).
DISPATCH_EDGES = {
    ("READY", "DISPATCHED"),
    ("DISPATCHED", "ACKED"),
    ("RETURNED", "VERIFIED"),
    ("FAILED", "DISPATCHED"),
    # NOTE (H1): READY -> FAILED is deliberately NOT a legal edge. "FAILED"
    # means an attempt was made and did not succeed; a dispatch still in
    # READY has never minted an attempt (attempt=None), so it cannot have
    # failed one. A dispatch that should never be pursued goes READY ->
    # ABANDONED/QUARANTINED instead (both remain legal below).
    ("DISPATCHED", "FAILED"),
    ("ACKED", "FAILED"),
    ("RETURNED", "FAILED"),
    ("READY", "ABANDONED"),
    ("DISPATCHED", "ABANDONED"),
    ("ACKED", "ABANDONED"),
    ("RETURNED", "ABANDONED"),
    ("READY", "QUARANTINED"),
    ("DISPATCHED", "QUARANTINED"),
    ("ACKED", "QUARANTINED"),
    ("RETURNED", "QUARANTINED"),
    ("QUARANTINED", "VERIFIED"),
    ("QUARANTINED", "ABANDONED"),
}
# Edges that mint a new attempt (§5).
MINTING_EDGES = {("READY", "DISPATCHED"), ("FAILED", "DISPATCHED")}

# Legal issue_state values per event-log-grammar.md / enforcement.md §... —
# the full and only whitelist for issue_state's `to=`/`from=` (H2).
ISSUE_STATES = {
    "OPEN", "ACTIVE", "IN-PROGRESS", "TODO", "PARKED", "BLOCKED",
    "NEEDS-USER", "CLOSED",
}


class RuleViolation(Exception):
    pass


def new_state():
    return {
        "issues": {},
        "dispatches": {},
        "questions": {},
        "unregistered": [],
        "quarantined": [],
        "quarantine_lines": [],
        "returned_marker": {},  # (d, a) -> line_no of the RETURNED result
        "pending_superseded": set(),  # dispatch ids superseded before they were registered
    }


def quarantine_line(state, line_no, raw, reason):
    state["quarantined"].append({"line": line_no, "reason": reason, "raw": raw})
    state["quarantine_lines"].append(f"{raw}\t# quarantined: {reason} (line {line_no})")


def parse_line(raw):
    """Return (type, dict) or raise ValueError(reason) for grammar failures."""
    if not raw.startswith("EVENT "):
        raise ValueError("does not start with 'EVENT '")
    rest = raw[len("EVENT "):]
    parts = rest.split(" ")
    if not parts or not parts[0]:
        raise ValueError("missing event type")
    etype = parts[0]
    if etype not in REQUIRED:
        raise ValueError(f"unknown event type '{etype}'")
    kv = {}
    for tok in parts[1:]:
        if not tok:
            continue
        if "=" not in tok:
            raise ValueError(f"malformed pair '{tok}'")
        k, v = tok.split("=", 1)
        if k in kv:
            raise ValueError(f"duplicate key '{k}'")
        if v == "":
            raise ValueError(f"empty value for key '{k}'")
        if not TOKEN_RE.match(v):
            raise ValueError(f"value for key '{k}' fails token charset: '{v}'")
        kv[k] = v
    for req in REQUIRED[etype]:
        if req not in kv:
            raise ValueError(f"missing required key '{req}' for type '{etype}'")
    # NOTE: unknown keys are accepted (forward-compat), not an error.
    return etype, kv


def render_line(etype, kv):
    parts = [f"EVENT {etype}"]
    emitted = set()
    for k in KEY_ORDER.get(etype, []):
        if k in kv:
            parts.append(f"{k}={kv[k]}")
            emitted.add(k)
    for k in kv:
        if k not in emitted:
            parts.append(f"{k}={kv[k]}")
    return " ".join(parts)


def _next_attempt(disp):
    cur = disp.get("attempt")
    if not cur or not str(cur).startswith("A-"):
        return "A-01"
    try:
        n = int(str(cur)[2:])
    except ValueError:
        return "A-01"
    return f"A-{n + 1:02d}"


def apply_event(state, etype, kv, line_no, raw, mode):
    """
    The ONE rule set (enforcement.md §2-§7), applied at two enforcement
    points via `mode`:

    mode == "quarantine" (pm_fold's whole-log walk; also used internally by
        pm_apply to re-establish current state from the existing log): on a
        rule violation, quarantine the line (state mutated as needed to
        reflect the quarantine, e.g. marking a dispatch QUARANTINED) and
        return False; never raises.

    mode == "strict" (pm_apply/pm_apply_batch validating a brand-new
        candidate event): on a rule violation, raise RuleViolation WITHOUT
        mutating `state`, aborting the whole transaction. On success,
        auto-derives/mints `from`/`lane`/`a` into `kv` IN PLACE (so the
        rendered, persisted log line always carries explicit values) and
        mutates `state`, returning True.
    """

    def fail(reason):
        if mode == "quarantine":
            quarantine_line(state, line_no, raw, reason)
            return False
        raise RuleViolation(reason)

    issues = state["issues"]
    dispatches = state["dispatches"]
    questions = state["questions"]

    if etype == "schema":
        if mode == "quarantine" and line_no != 1:
            return fail("schema header not on first line")
        return True

    if etype == "issue_state":
        i = kv["i"]
        if kv["to"] not in ISSUE_STATES:
            return fail(f"illegal issue_state to='{kv['to']}': not in {sorted(ISSUE_STATES)}")
        cur = issues.get(i)
        if "from" not in kv:
            kv["from"] = cur["state"] if cur is not None else "OPEN"
        if kv["from"] not in ISSUE_STATES:
            return fail(f"illegal issue_state from='{kv['from']}': not in {sorted(ISSUE_STATES)}")
        if cur is not None and cur["state"] != kv["from"]:
            return fail(f"illegal issue transition: from={kv['from']} current={cur['state']}")
        issues[i] = {"state": kv["to"]}
        return True

    if etype == "dispatch_new":
        d = kv["d"]
        if d in dispatches:
            return fail(f"duplicate dispatch_new for '{d}': dispatch already registered")
        dispatches[d] = {
            "state": "READY",
            "attempt": None,
            "lane": None,
            "tab": None,
            "result_sha": None,
            "child_of": kv.get("child_of"),
            "supersedes": kv.get("supersedes"),
            "adopted_ref": None,
            # Order-independent supersede resolution (H3): a dispatch is
            # superseded either because its own supersessor already exists
            # and points at it (handled below), or because it was named as
            # `supersedes=` by an earlier-in-log dispatch_new before it was
            # itself registered — recorded in pending_superseded and
            # consumed here.
            "superseded": d in state["pending_superseded"],
        }
        state["pending_superseded"].discard(d)
        sup = kv.get("supersedes")
        if sup:
            if sup in dispatches:
                dispatches[sup]["superseded"] = True
            else:
                state["pending_superseded"].add(sup)
        return True

    if etype == "dispatch_state":
        d = kv["d"]
        to = kv["to"]
        if to == "RETURNED":
            return fail(
                "to=RETURNED is not a legal dispatch_state; RETURNED is reached only "
                "via a `result` event (use `record result`, not `record dispatch ... RETURNED`)"
            )
        disp = dispatches.get(d)
        if disp is None:
            return fail(f"dispatch_state for unregistered dispatch '{d}'")
        cur_state = disp["state"]

        if "from" not in kv:
            kv["from"] = cur_state
        frm = kv["from"]

        if cur_state in TERMINAL:
            if mode == "quarantine":
                # Medium finding: quarantine must not mutate the standing
                # dispatch's attempt/lane/tab from the offending (illegal)
                # event's fields — only its lifecycle `state` moves to
                # QUARANTINED. The prior, already-committed values of
                # attempt/lane/tab are left intact so a late/bogus event
                # can never overwrite legitimate history before being
                # rejected.
                disp["state"] = "QUARANTINED"
                quarantine_line(state, line_no, raw, f"late dispatch_state after terminal for '{d}'")
                return False
            return fail(f"late transition for '{d}' refused: current state is terminal ({cur_state})")

        if frm != cur_state:
            return fail(f"illegal dispatch transition: from={frm} current={cur_state}")

        edge = (frm, to)
        if edge not in DISPATCH_EDGES:
            return fail(f"illegal dispatch transition: {frm} -> {to} is not a legal edge")

        if disp.get("superseded") and to not in TERMINAL:
            return fail(f"dispatch_state on superseded dispatch '{d}' refused (needs human adjudication)")

        if edge in MINTING_EDGES:
            if "lane" not in kv:
                if disp["lane"] is not None:
                    kv["lane"] = disp["lane"]
                else:
                    return fail(f"dispatch_state to=DISPATCHED for '{d}' missing lane")
            elif disp["lane"] is not None and kv["lane"] != disp["lane"]:
                return fail(f"lane mismatch for '{d}': fixed lane={disp['lane']}, got {kv['lane']}")
            minted = _next_attempt(disp)
            if "a" in kv and kv["a"] != minted:
                return fail(f"attempt mismatch for '{d}': expected mint {minted}, got {kv['a']}")
            kv["a"] = minted
        else:
            if "lane" not in kv:
                kv["lane"] = disp["lane"]
            elif disp["lane"] is not None and kv["lane"] != disp["lane"]:
                return fail(f"lane mismatch for '{d}': fixed lane={disp['lane']}, got {kv['lane']}")
            if "a" not in kv:
                # `a` is OPTIONAL for dispatch_state (an undispatched
                # dispatch legitimately has no attempt yet — e.g. READY ->
                # ABANDONED/QUARANTINED). Only carry it forward when one
                # actually exists; leaving it unset (rather than deriving
                # a literal None) keeps write/fold in parity — see H1.
                if disp["attempt"] is not None:
                    kv["a"] = disp["attempt"]
            elif kv["a"] != disp["attempt"]:
                return fail(f"attempt mismatch for '{d}': current attempt={disp['attempt']}, got {kv['a']}")

        disp["state"] = to
        if kv.get("lane") is not None:
            disp["lane"] = kv["lane"]
        if kv.get("a") is not None:
            disp["attempt"] = kv["a"]
        if "tab" in kv:
            disp["tab"] = kv["tab"]
        return True

    if etype == "result":
        d = kv["d"]
        disp = dispatches.get(d)
        if disp is None:
            return fail(f"result for unregistered dispatch '{d}'")

        if "a" not in kv:
            kv["a"] = disp["attempt"]
        a = kv["a"]

        # C2: duplicate-result detection runs BEFORE both the terminal
        # check and the ACKED/attempt preconditions below. A second
        # `result` for the same d/a must always be classified as a
        # duplicate (and re-flag the original) per enforcement.md §4.1 —
        # even when a later event has since driven the dispatch to a
        # terminal state (VERIFIED/ABANDONED). Checking terminal-ness
        # first would misclassify a duplicate arriving after terminal as
        # merely "late result after terminal", silently dropping the
        # duplicate-result re-flag of the original RETURNED line that
        # enforcement.md promises.
        key = (d, a)
        prior_line = state["returned_marker"].get(key)
        if prior_line is not None:
            if mode == "quarantine":
                disp["state"] = "QUARANTINED"
                quarantine_line(
                    state, prior_line, "(see original RETURNED line)",
                    f"duplicate result: superseded by line {line_no}",
                )
                quarantine_line(state, line_no, raw, f"duplicate result for {d}/{a} (first at line {prior_line})")
                return False
            return fail(f"duplicate result for {d}/{a} refused (first recorded at line {prior_line})")

        if disp["state"] in TERMINAL:
            if mode == "quarantine":
                disp["state"] = "QUARANTINED"
                disp["result_sha"] = kv["result_sha"]
                quarantine_line(state, line_no, raw, f"late result after terminal for '{d}'")
                return False
            return fail(f"result for '{d}' refused: dispatch is terminal ({disp['state']})")

        if disp.get("superseded"):
            return fail(f"result on superseded dispatch '{d}' refused (needs human adjudication)")

        # Every `result`, whatever its `status` value (RETURNED/FAIL/PASS/
        # ...), is legal only when the dispatch is currently ACKED and `a`
        # matches the dispatch's current attempt (enforcement.md §4.1);
        # `status` is metadata carried on the result, not a separate
        # lifecycle. A legal result always advances the dispatch to
        # RETURNED, the one intake state.
        if disp["state"] != "ACKED":
            return fail(
                f"result for '{d}' refused: current state is {disp['state']}, must be ACKED"
            )
        if a != disp["attempt"]:
            return fail(f"result attempt mismatch for '{d}': current attempt={disp['attempt']}, got {a}")

        state["returned_marker"][key] = line_no
        disp["state"] = "RETURNED"
        disp["result_sha"] = kv["result_sha"]
        return True

    if etype == "question":
        q = kv["q"]
        questions[q] = kv["state"]
        return True

    if etype == "unregistered_execution":
        state["unregistered"].append({"line": line_no, "at": kv["at"], "ref": kv["ref"]})
        return True

    if etype == "adopt":
        d = kv["d"]
        disp = dispatches.get(d)
        if disp is not None:
            disp["adopted_ref"] = kv["ref"]
        return True

    if etype == "note":
        # never parsed for state.
        return True

    return fail(f"unhandled event type '{etype}'")


def fold_lines(raw_lines):
    """Whole-log quarantine-mode fold. Never raises."""
    state = new_state()
    for line_no, raw in enumerate(raw_lines, start=1):
        if raw.strip() == "":
            continue
        try:
            etype, kv = parse_line(raw)
        except ValueError as e:
            quarantine_line(state, line_no, raw, str(e))
            continue
        apply_event(state, etype, kv, line_no, raw, "quarantine")
    return state


def write_outputs(state, index_path, quarantine_path):
    open_questions = sorted([q for q, st in state["questions"].items() if st == "OPEN"])

    seen_refs = set()
    dedup_unregistered = []
    for u in state["unregistered"]:
        if u["ref"] in seen_refs:
            continue
        seen_refs.add(u["ref"])
        dedup_unregistered.append(u)

    index = {
        "schema_v": "1",
        "issues": state["issues"],
        "dispatches": state["dispatches"],
        "quarantined": state["quarantined"],
        "unregistered": dedup_unregistered,
        "open_questions": open_questions,
    }

    with open(index_path, "w") as f:
        json.dump(index, f, indent=2, sort_keys=True)
        f.write("\n")

    if state["quarantine_lines"]:
        with open(quarantine_path, "w") as f:
            f.write("\n".join(state["quarantine_lines"]) + "\n")
    elif os.path.exists(quarantine_path):
        os.remove(quarantine_path)
PYEOF

# ---------------------------------------------------------------------------
# pm_fold driver
# ---------------------------------------------------------------------------

read -r -d '' _PM_FOLD_DRIVER_PY <<'PYEOF' || true
log_path = os.environ["PM_FOLD_LOG"]
index_path = os.environ["PM_FOLD_INDEX"]
quarantine_path = os.environ["PM_FOLD_QUARANTINE"]

with open(log_path, "r") as f:
    raw_lines = f.read().split("\n")
if raw_lines and raw_lines[-1] == "":
    raw_lines = raw_lines[:-1]

state = fold_lines(raw_lines)
write_outputs(state, index_path, quarantine_path)
sys.exit(0)
PYEOF

pm_fold() {
  # pm_fold [repo_root]
  # Read .pm/events.log in file order (log order is authority; `at=` is
  # never used to sort), route rule-violating lines to .pm/quarantine.log
  # (with a reason; never silently dropped), and write .pm/index.json per
  # the shared rule engine (enforcement.md §1-§8). This is enforcement
  # point #2 (quarantine mode); pm_apply is enforcement point #1 (strict
  # mode) and shares the exact same rule set (_PM_ENGINE_PY).
  local root
  root="$(_pm_root "${1:-}")" || return 1
  local pmdir="$root/.pm"
  local log="$pmdir/events.log"
  local index="$pmdir/index.json"
  local quarantine="$pmdir/quarantine.log"

  if [[ ! -f "$log" ]]; then
    echo "pm_fold: no events log at $log" >&2
    return 1
  fi

  (
    export PM_FOLD_LOG="$log" PM_FOLD_INDEX="$index" PM_FOLD_QUARANTINE="$quarantine"
    printf '%s\n%s\n' "$_PM_ENGINE_PY" "$_PM_FOLD_DRIVER_PY" | python3 -
  )
}

# ---------------------------------------------------------------------------
# pm_apply / pm_apply_batch driver
# ---------------------------------------------------------------------------

read -r -d '' _PM_APPLY_DRIVER_PY <<'PYEOF' || true
log_path = os.environ["PM_APPLY_LOG"]
index_path = os.environ["PM_APPLY_INDEX"]
quarantine_path = os.environ["PM_APPLY_QUARANTINE"]
events = json.loads(os.environ["PM_APPLY_EVENTS"])

if os.path.exists(log_path):
    with open(log_path, "r") as f:
        raw_lines = f.read().split("\n")
    if raw_lines and raw_lines[-1] == "":
        raw_lines = raw_lines[:-1]
else:
    raw_lines = []

# Re-establish current state from the existing log (same engine, quarantine
# mode — this is NOT a third enforcement point, just pm_fold's own logic
# reused to know "what is current state right now" under the held lock).
state = fold_lines(raw_lines)

need_header = (not raw_lines) and (not any(e.get("type") == "schema" for e in events))

new_lines = []
line_no = len(raw_lines)

if need_header:
    line_no += 1
    new_lines.append("EVENT schema v=1")

for ev in events:
    etype = ev.get("type")
    kv = ev.get("kv") or {}
    if etype not in REQUIRED:
        print(f"pm_apply: unknown event type '{etype}'")
        sys.exit(1)
    for k, v in kv.items():
        if not TOKEN_RE.match(v):
            print(f"pm_apply: value for key '{k}' fails token charset: '{v}'")
            sys.exit(1)
    for req in REQUIRED_FOR_APPLY[etype]:
        if req not in kv:
            print(f"pm_apply: missing required key '{req}' for type '{etype}'")
            sys.exit(1)
    line_no += 1
    try:
        apply_event(state, etype, kv, line_no, "", "strict")
    except RuleViolation as e:
        print(f"pm_apply: refused: {e}")
        sys.exit(1)
    # H1: apply_event may have derived additional fields (a=, lane=, ...)
    # into kv above; revalidate those derived values too — not just their
    # presence — before ever rendering a log line. A None or malformed
    # derived value must never reach render_line/the log. This must walk
    # the FULL derived kv (every key apply_event may have set, required
    # OR optional — e.g. dispatch_state's engine-derived `a` is OPTIONAL,
    # not REQUIRED, and a None `a` here must still be caught before
    # render_line), not merely REQUIRED[etype], or a derived-None can slip
    # through write while pm_fold would quarantine the same line (H1).
    for req in REQUIRED[etype]:
        if req not in kv:
            print(f"pm_apply: internal error: key '{req}' not derived for type '{etype}'")
            sys.exit(1)
    for k, v in kv.items():
        if v is None or not TOKEN_RE.match(str(v)):
            print(f"pm_apply: internal error: derived key '{k}' invalid for type '{etype}': {v!r}")
            sys.exit(1)
    new_lines.append(render_line(etype, kv))

# H2: the log append is the FINAL durable commit point. It MUST be a
# single write() call — not a per-line loop — so a crash mid-append can
# never leave a partial multi-event batch in the log (all-or-nothing at
# the OS level, not just at the Python-loop level).
batch_text = "".join(line + "\n" for line in new_lines)
with open(log_path, "a") as f:
    f.write(batch_text)

# H2: once the append above has returned, the batch is COMMITTED — the
# rule for callers is "exit non-zero => nothing was committed; exit zero
# => everything was committed (index may be stale-but-recoverable)".
# Refolding to rebuild index.json/quarantine.log is a best-effort
# convenience, not part of the commit: if it fails, the already-appended
# events are still valid and durable, so we must NOT report failure here
# (that would contradict what was actually committed). Warn instead and
# leave the stale index for the next pm_fold/reconcile to regenerate.
try:
    with open(log_path, "r") as f:
        all_raw = f.read().split("\n")
    if all_raw and all_raw[-1] == "":
        all_raw = all_raw[:-1]
    final_state = fold_lines(all_raw)
    write_outputs(final_state, index_path, quarantine_path)
except Exception as e:
    print(
        f"pm_apply: WARNING: batch committed to {log_path} but post-commit "
        f"refold failed ({e}); index.json/quarantine.log are stale — "
        f"re-run pm_fold/reconcile to regenerate them",
        file=sys.stderr,
    )

for line in new_lines:
    if line.startswith("EVENT schema "):
        continue
    print(line)
sys.exit(0)
PYEOF

_pm_kv_to_json() {
  # _pm_kv_to_json <type> <k=v> [<k=v> ...]
  # Convert one event's bash key=value tokens into a JSON object
  # {"type": "...", "kv": {...}}. Detects malformed pairs, duplicate keys,
  # and empty values here (defense in depth; the python engine re-validates
  # charset/required-keys too).
  local type="${1:-}"
  if [[ -z "$type" ]]; then
    echo "pm_apply: missing <type>" >&2
    return 1
  fi
  shift
  PM_TYPE="$type" python3 -c '
import json, os, sys
type_ = os.environ["PM_TYPE"]
kv = {}
for pair in sys.argv[1:]:
    if "=" not in pair:
        print(f"pm_apply: malformed pair {pair!r} (expected key=value)", file=sys.stderr)
        sys.exit(1)
    k, v = pair.split("=", 1)
    if k in kv:
        print(f"pm_apply: duplicate key {k!r}", file=sys.stderr)
        sys.exit(1)
    if v == "":
        print(f"pm_apply: empty value for key {k!r}", file=sys.stderr)
        sys.exit(1)
    kv[k] = v
print(json.dumps({"type": type_, "kv": kv}))
' "$@"
}

pm_apply_batch() {
  # pm_apply_batch -- <type> <k=v> [<k=v> ...] [-- <type> <k=v> ...]
  # Applies one or more events as ONE atomic transaction, under ONE held
  # pm_lock: folds the current log to in-memory state, validates each
  # candidate event IN ORDER against the evolving state (shared rule
  # engine, strict mode — each event sees the effects of the ones applied
  # before it in this same batch), and ONLY IF ALL PASS appends all
  # rendered lines and refolds .pm/index.json. On ANY failure: nothing is
  # appended, returns non-zero, prints a one-line reason to stderr. On
  # success: prints each committed rendered log line to stdout (the
  # auto-inserted schema header, if any, is not printed) and returns 0.
  if [[ "${1:-}" != "--" ]]; then
    echo "pm_apply_batch: arguments must start with '--' before the first event type" >&2
    return 1
  fi
  shift

  local root
  root="$(_pm_root "")" || return 1
  local pmdir="$root/.pm"
  mkdir -p "$pmdir"
  local log="$pmdir/events.log"
  local index="$pmdir/index.json"
  local quarantine="$pmdir/quarantine.log"

  local -a objs=()
  local -a cur=()
  local arg one
  while [[ $# -gt 0 ]]; do
    arg="$1"
    shift
    if [[ "$arg" == "--" ]]; then
      one="$(_pm_kv_to_json "${cur[@]}")" || return 1
      objs+=("$one")
      cur=()
      continue
    fi
    cur+=("$arg")
  done
  one="$(_pm_kv_to_json "${cur[@]}")" || return 1
  objs+=("$one")

  local groups_json
  groups_json="$(python3 -c '
import json, sys
print(json.dumps([json.loads(a) for a in sys.argv[1:]]))
' "${objs[@]}")" || return 1

  pm_lock "$root" || return 1
  local out rc
  out="$(
    export PM_APPLY_LOG="$log" PM_APPLY_INDEX="$index" PM_APPLY_QUARANTINE="$quarantine" PM_APPLY_EVENTS="$groups_json"
    printf '%s\n%s\n' "$_PM_ENGINE_PY" "$_PM_APPLY_DRIVER_PY" | python3 -
  )"
  rc=$?
  pm_unlock

  if [[ "$rc" -ne 0 ]]; then
    printf '%s\n' "$out" >&2
    return 1
  fi
  if [[ -n "$out" ]]; then
    printf '%s\n' "$out"
  fi
  return 0
}

pm_apply() {
  # pm_apply <type> <k=v> [<k=v> ...]
  # Single-event convenience wrapper around pm_apply_batch (one-event
  # transaction). See pm_apply_batch for the full contract.
  pm_apply_batch -- "$@"
}

# ---------------------------------------------------------------------------
# pm_git_probe
# ---------------------------------------------------------------------------

pm_git_probe() {
  # pm_git_probe <repo_path>
  # Echo a JSON summary of a repo's real git state: branch, detached-HEAD,
  # dirty, ahead/behind vs upstream, untracked count, stash count,
  # submodule-dirty flag, worktree list. Gracefully reports (never crashes)
  # if repo_path is not a git repository.
  local repo_path="${1:-}"
  if [[ -z "$repo_path" ]]; then
    echo "pm_git_probe: missing <repo_path>" >&2
    return 1
  fi
  PM_PROBE_PATH="$repo_path" python3 - <<'PYEOF'
import json
import os
import subprocess

path = os.environ["PM_PROBE_PATH"]


def run(args, cwd):
    try:
        r = subprocess.run(
            ["git"] + args, cwd=cwd, capture_output=True, text=True, timeout=10
        )
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except Exception as e:  # pragma: no cover - defensive
        return 1, "", str(e)


out = {"path": path, "is_repo": False}

if not os.path.isdir(path):
    out["error"] = "path does not exist or is not a directory"
    print(json.dumps(out))
    raise SystemExit(0)

rc, _, _ = run(["rev-parse", "--is-inside-work-tree"], path)
if rc != 0:
    out["error"] = "not a git repository"
    print(json.dumps(out))
    raise SystemExit(0)

out["is_repo"] = True

rc, branch, _ = run(["symbolic-ref", "--short", "-q", "HEAD"], path)
if rc == 0 and branch:
    out["branch"] = branch
    out["detached"] = False
else:
    out["branch"] = None
    out["detached"] = True

rc, status_porcelain, _ = run(["status", "--porcelain"], path)
tracked_dirty = any(
    line[:2].strip() and not line.startswith("??")
    for line in status_porcelain.splitlines()
)
untracked_lines = [l for l in status_porcelain.splitlines() if l.startswith("??")]
out["untracked_count"] = len(untracked_lines)
out["dirty"] = bool(tracked_dirty or untracked_lines)

ahead = behind = 0
rc, upstream, _ = run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], path)
if rc == 0 and upstream:
    rc2, counts, _ = run(["rev-list", "--left-right", "--count", "HEAD...@{u}"], path)
    if rc2 == 0 and counts:
        parts = counts.split()
        if len(parts) == 2:
            ahead, behind = int(parts[0]), int(parts[1])
out["ahead"] = ahead
out["behind"] = behind

rc, stash_list, _ = run(["stash", "list"], path)
out["stash_count"] = len([l for l in stash_list.splitlines() if l.strip()]) if rc == 0 else 0

submodule_dirty = False
rc, sm_status, _ = run(["submodule", "status", "--recursive"], path)
if rc == 0:
    for line in sm_status.splitlines():
        if line.strip().startswith(("+", "-", "U")):
            submodule_dirty = True
            break
out["submodule_dirty"] = submodule_dirty

worktrees = []
rc, wt_out, _ = run(["worktree", "list", "--porcelain"], path)
if rc == 0:
    cur = {}
    for line in wt_out.splitlines():
        if not line.strip():
            if cur:
                worktrees.append(cur)
                cur = {}
            continue
        if " " in line:
            k, v = line.split(" ", 1)
            cur[k] = v
        else:
            cur[line] = True
    if cur:
        worktrees.append(cur)
out["worktrees"] = worktrees

print(json.dumps(out))
PYEOF
}

# ---------------------------------------------------------------------------
# escapers — one function per context, each round-trips or neutralizes
# hostile input (spaces, newlines, $(), backticks, ;, |, glob chars, quotes,
# leading -).
# ---------------------------------------------------------------------------

esc_shell() {
  # esc_shell <string>
  # Echo a POSIX-sh-safe single-quoted token: wraps in single quotes,
  # escaping embedded single quotes as '\'' . Safe to eval/interpolate as one
  # word; neutralizes $(), backticks, ;, |, globs, leading '-'.
  local s="${1-}"
  printf "'%s'" "${s//\'/\'\\\'\'}"
}

esc_md() {
  # esc_md <string>
  # Escape Markdown special characters so the string renders as literal text
  # rather than being interpreted as Markdown syntax.
  local s="${1-}"
  s="${s//\\/\\\\}"
  local special='`*_{}[]()#+.!|<>~-'
  local i out=""
  for ((i = 0; i < ${#s}; i++)); do
    local c="${s:i:1}"
    if [[ "$special" == *"$c"* ]]; then
      out+="\\$c"
    else
      out+="$c"
    fi
  done
  printf '%s' "$out"
}

esc_json() {
  # esc_json <string>
  # Echo a JSON-string-safe token WITHOUT surrounding quotes (caller wraps in
  # "..."). Delegates to python3 json.dumps and strips the outer quotes.
  local s="${1-}"
  PM_ESC_INPUT="$s" python3 -c '
import json, os
s = os.environ.get("PM_ESC_INPUT", "")
print(json.dumps(s)[1:-1], end="")
'
}

esc_path() {
  # esc_path <string>
  # Neutralize a string for safe use as a single path COMPONENT/argument:
  # prefix a leading '-' with './' (arg-injection guard). REJECTS (returns
  # non-zero, prints nothing) a string containing an embedded newline,
  # rather than silently stripping it — stripping is unsafe because it can
  # collide distinct inputs (e.g. "a\nc" and "ac" would both silently
  # become "ac", and "a\nc" would previously become "ac" while looking like
  # a no-op to a caller not checking the return code).
  #
  # NOT A CONTAINMENT CHECK: this does not resolve or reject '..' path
  # segments, symlinks, or absolute-path escapes — a caller needing to keep
  # a path inside some root must additionally validate that itself. This
  # function only guards against the string being parsed as a flag and
  # against embedded newlines corrupting whatever line-oriented format it's
  # placed into.
  local s="${1-}"
  if [[ "$s" == *$'\n'* ]]; then
    echo "esc_path: refusing string with embedded newline" >&2
    return 1
  fi
  if [[ "$s" == -* ]]; then
    s="./$s"
  fi
  printf '%s' "$s"
}

esc_gitref() {
  # esc_gitref <string>
  # Sanitize a string into something safe to use as (part of) a git ref
  # name per `git check-ref-format` (no space ~ ^ : ? * [ \ control chars,
  # no consecutive dots, no leading dot / trailing dot, no double slash, no
  # leading/trailing slash, no trailing '.lock'). '.' is treated as
  # not-safe-on-its-own and mapped away entirely (simpler than tracking
  # per-component dot placement) so callers get a single unambiguous rule.
  #
  # NEUTRALIZES RATHER THAN PRESERVES IDENTITY: this is a many-to-one
  # mapping (e.g. every disallowed character collapses to the same '-'), so
  # two distinct hostile inputs can legitimately sanitize to the same
  # output. Callers must not assume the result round-trips back to the
  # original string, or that distinct inputs stay distinct after
  # sanitizing — only that the output is always a safe ref token.
  local s="${1-}"
  s="${s//$'\n'/-}"
  local out="" i c
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z0-9_/-]) out+="$c" ;;
      *) out+="-" ;;
    esac
  done
  # collapse repeated slashes/dashes; trim leading/trailing separators
  # (repeatedly — they can alternate, e.g. "-/-" — until both ends are clean).
  while [[ "$out" == *"//"* ]]; do out="${out//\/\//\/}"; done
  while [[ "$out" == *"--"* ]]; do out="${out//--/-}"; done
  while [[ "$out" == -* || "$out" == /* || "$out" == *- || "$out" == */ ]]; do
    out="${out#[-/]}"
    out="${out%[-/]}"
  done
  out="${out%.lock}"
  if [[ -z "$out" ]]; then
    out="ref"
  fi
  printf '%s' "$out"
}
