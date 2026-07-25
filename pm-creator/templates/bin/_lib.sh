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
#   pm_lock        [repo_root]                -- acquire .pm/.lock (flock-based)
#   pm_unlock                                  -- release the most recent pm_lock
#   pm_apply        <type> <k=v> [<k=v> ...]   -- validate + atomically apply ONE event
#   pm_apply_batch  -- <type> <k=v>... [-- <type> <k=v>...]
#                                               -- validate + atomically apply SEVERAL
#                                                  events as one transaction
#   pm_fold        [repo_root]                -- fold .pm/events.log -> .pm/index.json
#   pm_close_issue <repo_root> <I-###> [--dry-run]
#                                               -- close+archive core (in-process, lock-reentrant)
#   pm_git_probe   <repo_path>                 -- echo JSON snapshot of a repo's real state
#   pm_config_repos <config.json path>         -- echo normalized `repos` JSON list (THE one parser)
#   esc_shell      <string>                    -- echo a shell-safe single-quoted token
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
_PM_LOCK_FD=""
_PM_LOCK_ROOT=""

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
  # Acquire an flock(2)-based lock on the regular file <repo_root>/.pm/.lock.
  # Re-entrant within a single script's lifetime (nested pm_lock/pm_unlock
  # pairs just adjust a depth counter); a trap on EXIT/INT/TERM releases the
  # lock if the script is interrupted mid-critical-section.
  #
  # Why flock and not mkdir (C3/I4): the kernel releases an flock when the
  # holding process dies -- ANY death, including kill -9 / OOM -- so there is
  # no stale-lock state, no reclaim protocol, and therefore no ABA window in
  # which two waiters can both "reclaim" and both hold the lock (the mkdir
  # protocol's `.reclaiming` marker lived inside the directory being deleted
  # and was reproducibly defeated by two concurrent reclaimers). The lock
  # file itself is never deleted; ownership lives in the kernel lock, not in
  # the file's existence.
  #
  # FD inheritance note: the lock fd is inherited by children forked while
  # the lock is held. That is safe here because every child spawned under
  # the lock (python engine, git, sed) is short-lived and awaited before
  # pm_unlock; no code path backgrounds a long-lived process while holding
  # the lock (herdr spawn calls are explicitly made OUTSIDE the lock -- see
  # track's spawn stage). A long-lived child would otherwise keep the
  # kernel lock alive via its inherited fd after the parent released.
  #
  # Timeout is PM_LOCK_TIMEOUT seconds (default 10, matching the old
  # 100 x 0.1s wait loop); on timeout: non-zero return + operator message.
  local root
  root="$(_pm_root "${1:-}")" || return 1
  local lockfile="$root/.pm/.lock"

  if [[ "$_PM_LOCK_DEPTH" -gt 0 ]]; then
    # Reentrant acquire: refuse to silently share the held lock with a
    # DIFFERENT root. Without this guard, a caller that rewrites $PM_ROOT
    # mid-call-stack (e.g. pm_close_issue pinning $PM_ROOT to its own
    # explicit root argument) could reenter the depth counter while
    # actually operating against a different repo than the one whose lock
    # is held, letting pm_apply write into repo B while only repo A's lock
    # is held.
    if [[ "$root" != "$_PM_LOCK_ROOT" ]]; then
      echo "pm-creator: refusing reentrant pm_lock for '$root': lock is already held for a different root '$_PM_LOCK_ROOT'" >&2
      return 1
    fi
    _PM_LOCK_DEPTH=$((_PM_LOCK_DEPTH + 1))
    return 0
  fi

  # NOTE: no stderr redirect on the `exec` -- a redirection attached to a
  # bare `exec` would permanently rebind the SCRIPT's stderr, not just this
  # open. A failed open prints bash's own diagnostic, which is what we want.
  local fd=""
  if ! exec {fd}>>"$lockfile"; then
    echo "pm-creator: cannot open lock file $lockfile" >&2
    return 1
  fi
  if ! flock -w "${PM_LOCK_TIMEOUT:-10}" "$fd"; then
    exec {fd}>&-
    echo "pm-creator: timed out waiting for lock $lockfile" >&2
    return 1
  fi
  _PM_LOCK_FD="$fd"
  _PM_LOCK_ROOT="$root"
  _PM_LOCK_DEPTH=1
  # C6: signal handlers must TERMINATE, not just clean up. A handler that
  # releases the lock and then lets the script keep running would continue
  # the critical section WITHOUT the lock (and, in track's case, could
  # still reach the spawn stage after the operator hit Ctrl-C). EXIT only
  # releases; INT/TERM release, restore default disposition, and re-raise
  # so the process dies with the correct 128+signum status. BASHPID (not
  # $$) so a subshell that acquired the lock kills itself, not its parent
  # script. Callers that install their own traps after pm_lock (track,
  # reconcile) must follow the same terminate-on-signal shape.
  trap '_pm_lock_release_all' EXIT
  trap '_pm_lock_release_all; trap - EXIT INT TERM; kill -INT "${BASHPID:-$$}"' INT
  trap '_pm_lock_release_all; trap - EXIT INT TERM; kill -TERM "${BASHPID:-$$}"' TERM
  return 0
}

_pm_lock_release_all() {
  # Closing the fd releases the flock. If the process dies without ever
  # getting here (kill -9, OOM), the kernel closes the fd and releases the
  # lock anyway -- that is the whole point of the flock design. No stderr
  # redirect on the bare `exec` (it would permanently rebind the script's
  # stderr); _PM_LOCK_FD is only ever set to a successfully-opened fd and
  # cleared right after closing, so a double-close cannot happen.
  if [[ -n "$_PM_LOCK_FD" ]]; then
    exec {_PM_LOCK_FD}>&- || true
  fi
  _PM_LOCK_FD=""
  _PM_LOCK_ROOT=""
  _PM_LOCK_DEPTH=0
}

pm_unlock() {
  # pm_unlock
  # Release one level of the lock acquired by pm_lock. Only the outermost
  # pm_unlock in a nested pair actually releases the flock (closes the fd).
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
  [merged]="d a merge_sha result_sha at"
  [question]="q state at"
  [unregistered_execution]="at ref"
  [adopt]="d a at ref"
  [note]="at ref"
  [spawn_intent]="d a at"
)

declare -gA _PM_OPTIONAL_KEYS=(
  [schema]=""
  [issue_state]="by"
  [dispatch_new]="child_of supersedes"
  [dispatch_state]="a tab prompt_sha repo branch base_sha"
  [result]=""
  [merged]="repo"
  [question]="i a_of"
  [unregistered_execution]=""
  [adopt]=""
  [note]="d i"
  [spawn_intent]="ref"
)

# canonical key order for emitted lines (readability only; order is not
# grammar-significant per §1).
declare -gA _PM_KEY_ORDER=(
  [schema]="v"
  [issue_state]="i from to at by"
  [dispatch_new]="d i at child_of supersedes"
  [dispatch_state]="d a from to lane at tab prompt_sha repo branch base_sha"
  [result]="d a status result_sha at"
  [merged]="d a merge_sha result_sha at repo"
  [question]="q state at i a_of"
  [unregistered_execution]="at ref"
  [adopt]="d a at ref"
  [note]="at ref d i"
  [spawn_intent]="d a at ref"
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

# \A/\Z (not ^/$): Python's $ matches just before a trailing "\n", so
# "token\n" would satisfy ^...+$ without the char class ever having to
# accept \n -- a value with an embedded trailing newline would validate as
# a clean token and then corrupt a rendered grammar line on append. \A/\Z
# anchor to the true start/end of the string, with no such exception.
TOKEN_RE = re.compile(r'\A[A-Za-z0-9._:+/@?-]+\Z')

# B2.2 fix-pass-6 F3: full git object-name shape (sha1=40 / sha256=64
# lowercase hex) for the sha fields of `merged` corroboration markers. The
# fold's trust boundary is symmetric with track's close-time BASE_SHA_RE:
# a revision expression ("main", "HEAD~1") or short hex must never fold
# into a marker and wait for close time to be refused.
FULL_SHA_RE = re.compile(r'\A([0-9a-f]{40}|[0-9a-f]{64})\Z')

REQUIRED = {
    "schema": ["v"],
    "issue_state": ["i", "from", "to", "at"],
    "dispatch_new": ["d", "i", "at"],
    "dispatch_state": ["d", "from", "to", "lane", "at"],
    "result": ["d", "a", "status", "result_sha", "at"],
    "merged": ["d", "a", "merge_sha", "result_sha", "at"],
    "question": ["q", "state", "at"],
    "unregistered_execution": ["at", "ref"],
    "adopt": ["d", "a", "at", "ref"],
    "note": ["at", "ref"],
    "spawn_intent": ["d", "a", "at"],
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
    "merged": ["d", "merge_sha", "result_sha", "at"],
    "question": ["q", "state", "at"],
    "unregistered_execution": ["at", "ref"],
    "adopt": ["d", "a", "at", "ref"],
    "note": ["at", "ref"],
    "spawn_intent": ["d", "a", "at"],
}

OPTIONAL = {
    "schema": [],
    "issue_state": ["by"],
    "dispatch_new": ["child_of", "supersedes"],
    "dispatch_state": ["a", "tab", "prompt_sha", "repo", "branch", "base_sha"],
    "result": [],
    "merged": ["repo"],
    "question": ["i", "a_of"],
    "unregistered_execution": [],
    "adopt": [],
    "note": ["d", "i"],
    "spawn_intent": ["ref"],
}

# canonical key order for rendered log lines (readability only; order is not
# grammar-significant per §1). Must mirror bash's _PM_KEY_ORDER exactly.
KEY_ORDER = {
    "schema": ["v"],
    "issue_state": ["i", "from", "to", "at", "by"],
    "dispatch_new": ["d", "i", "at", "child_of", "supersedes"],
    "dispatch_state": ["d", "a", "from", "to", "lane", "at", "tab", "prompt_sha", "repo", "branch", "base_sha"],
    "result": ["d", "a", "status", "result_sha", "at"],
    "merged": ["d", "a", "merge_sha", "result_sha", "at", "repo"],
    "question": ["q", "state", "at", "i", "a_of"],
    "unregistered_execution": ["at", "ref"],
    "adopt": ["d", "a", "at", "ref"],
    "note": ["at", "ref", "d", "i"],
    "spawn_intent": ["d", "a", "at", "ref"],
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

# Legal question `state=` values per event-log-grammar.md (Q&A lifecycle: OPEN/ANSWERED).
QUESTION_STATES = {"OPEN", "ANSWERED"}


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
        # fix-pass-6 F1: {issue_id: [auto-close:* note refs]} -- the
        # durable marker-close provenance records, folded queryably for
        # track's pre-close dedup.
        "auto_close_notes": {},
    }


def quarantine_line(state, line_no, raw, reason, attributed_issues=None, category=None):
    # attributed_issues/category are captured AT quarantine time, from the
    # fold's own already-parsed kv (never a later reparse of `raw`) -- see
    # _quarantine_attribution(). attributed_issues is the SET of issues the
    # offending line's blast radius touches (an entity's line may implicate
    # more than one issue: the entity's AUTHORITATIVE owner, resolved via
    # the fold's own validated maps, PLUS -- additively, never in place of
    # the authoritative owner -- the line's own (possibly forged) `i=`
    # token). It is empty/falsy whenever the line cannot be cleanly and
    # unambiguously tied to ANY known issue (a bare grammar failure with no
    # coherent etype/kv at all, or a rule violation whose q/d/i all fail to
    # resolve to a known entity); write_outputs() treats that as globally
    # unattributable and blocks ALL auto-close for the tick rather than
    # risk silently missing the issue it was meant for.
    state["quarantined"].append({
        "line": line_no,
        "reason": reason,
        "raw": raw,
        "attributed_issues": sorted(attributed_issues) if attributed_issues else [],
        "category": category,
    })
    state["quarantine_lines"].append(f"{raw}\t# quarantined: {reason} (line {line_no})")


def _quarantine_attribution(state, etype, kv):
    """Resolve (attributed_issues, category) for a quarantined event.

    attributed_issues is the SET of issues this quarantined line's blast
    radius affects, resolved through the fold's OWN authoritative,
    already-validated state -- never by trusting the offending line's own
    (possibly forged) `i=`/`q=`/`d=` tokens as the sole source, and never
    by a second raw-log parse:

      - `question` events: the entity is the question `q`. Its authoritative
        owner is `state["questions"][q]["i"]`, set only by PRIOR
        successfully-applied `question` events (a quarantined line never
        reaches that assignment). A brand-new `q` that only ever appears on
        bad lines has no authoritative owner and resolves to nothing here.
      - `dispatch_new`/`dispatch_state`/`result`/`merged` events: the
        entity is the dispatch `d`. Its authoritative owner is
        `state["dispatch_issue_raw"][d]`, built from the first ACCEPTED
        (successfully-applied) `dispatch_new` event for that `d` (see
        fold_lines; P3-5) -- i.e. the REAL registration, not whatever `i=`
        the offending (e.g. duplicate) line itself forges.
      - `issue_state` events: `i` IS the entity being addressed directly
        (there is no separate owner to resolve), so it is used as-is.

    For `question`/`dispatch_new`/`dispatch_state`/`result` events, the
    line's own `i=` token (if present) is ADDED to the resolved set
    defensively (a bad line naming i=X might genuinely pertain to X too) but
    never REPLACES the authoritative resolution above -- so a forged `i=`
    can only ever widen the blast radius, never redirect it away from the
    entity's real owner. That widening is itself gated on `i=` naming a
    REGISTERED issue (present in `state["issues"]`, populated only by
    successfully-applied `issue_state` events -- never by a quarantined
    line): a forged `i=` pointing at a real, known issue may plausibly be a
    genuine (if sloppy) reference to it, but a forged `i=` naming an issue
    that has never been registered at all cannot be trusted as a defensive
    hint -- there is nothing to corroborate it against. So when the entity
    itself (q/d) is also unresolved AND `i=` does not name a registered
    issue, the entry resolves to nothing here and falls through to the
    global `quarantine_unattributable` flag (conservative) rather than
    inventing a scoped attribution out of an unregistered forged token.
    """
    affected = set()
    category = None
    known_issues = state.get("issues", {})
    if etype == "question":
        category = "question"
        q = kv.get("q")
        if q:
            prev = state["questions"].get(q)
            if prev is not None and prev.get("i"):
                affected.add(prev["i"])
    elif etype == "issue_state":
        category = "issue"
        # i IS the entity here; no separate owner map to resolve -- always
        # trust it directly, no widening gate needed.
        i = kv.get("i")
        if i:
            affected.add(i)
        return affected, category
    elif etype in ("dispatch_new", "dispatch_state", "result", "merged", "spawn_intent"):
        category = "issue"
        d = kv.get("d")
        if d:
            issue = state.get("dispatch_issue_raw", {}).get(d)
            if issue:
                affected.add(issue)
    else:
        return affected, None
    # Additive widening: the line's own `i=` only widens the blast radius
    # when it names a registered (known) issue -- see docstring.
    i = kv.get("i")
    if i and i in known_issues:
        affected.add(i)
    return affected, category


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
            _ai, _cat = _quarantine_attribution(state, etype, kv)
            quarantine_line(state, line_no, raw, reason, attributed_issues=_ai, category=_cat)
            return False
        raise RuleViolation(reason)

    issues = state["issues"]
    dispatches = state["dispatches"]
    questions = state["questions"]

    if etype == "schema":
        # I7: loud-fail on any grammar revision this tooling does not
        # understand -- silently folding a v!=1 log as if it were v=1 could
        # misread state the newer grammar encodes differently. Quarantining
        # the header also flips quarantine_unattributable, which blocks
        # every auto-close (fail-closed).
        if kv["v"] != "1":
            return fail(
                f"unsupported schema version v='{kv['v']}' "
                "(this tooling understands only v=1)"
            )
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
            "repo": None,
            "branch": None,
            "attempts": {},
            "result_sha": None,
            # B2.2: accepted `merged` corroboration markers, keyed by
            # attempt id -- {a: {merge_sha, result_sha}}. Read ONLY by
            # track's G4 marker arm.
            "merged": {},
            # B3: accepted `spawn_intent` lease records, keyed by attempt
            # id -- {a: {ref, at, line}}. A PURE record read ONLY by
            # track's spawn stage; never transitions dispatch/issue state.
            "spawn_intent": {},
            # B3: the last recorded prompt hash (dispatch_state
            # prompt_sha=) and durable prompt copy binding (note
            # ref=prompts/... d=), folded queryably for track's D2
            # re-hash guard.
            "prompt_sha": None,
            "prompt_ref": None,
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
                _ai, _cat = _quarantine_attribution(state, etype, kv)
                quarantine_line(
                    state, line_no, raw,
                    f"late dispatch_state after terminal for '{d}'",
                    attributed_issues=_ai, category=_cat,
                )
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

        # git-corroboration metadata (repo/branch/base_sha): OPTIONAL. repo
        # and branch are dispatch-scoped and, once set (typically at the
        # READY|FAILED->DISPATCHED mint), immutable per dispatch, mirroring
        # lane (enforcement.md §6). base_sha is ATTEMPT-scoped: it is keyed
        # by (d, a) rather than d alone, because a retry (a FAILED-
        # >DISPATCHED mint of a new attempt) legitimately rebases onto a
        # mainline HEAD that has moved since the prior attempt -- refusing
        # that would make retries after mainline advances impossible. A
        # differing base_sha for the SAME (d, a) is still refused/
        # quarantined; a new attempt sets its own base_sha with no
        # conflict. Omit any of the three to inherit the folded value;
        # absence is never an error (git corroboration is best-effort
        # metadata, not required for the dispatch lifecycle).
        for meta_key in ("repo", "branch"):
            if meta_key not in kv:
                if disp.get(meta_key) is not None:
                    kv[meta_key] = disp[meta_key]
            elif disp.get(meta_key) is not None and kv[meta_key] != disp[meta_key]:
                return fail(
                    f"{meta_key} mismatch for '{d}': fixed {meta_key}={disp[meta_key]}, got {kv[meta_key]}"
                )

        attempt_id = kv["a"] if "a" in kv else disp.get("attempt")

        # base_sha is ATTEMPT-scoped (keyed by (d, a)); an event that
        # carries base_sha but has NO attempt (attempt_id is None -- a
        # non-mint / hand-built / hostile event, since a legitimate mint
        # always sets `a`) has nowhere to record it. Refusing/quarantining
        # keeps write and fold in parity: silently accepting-then-dropping
        # it here would let the write path succeed while the fold path
        # discards it, the same class of bug as H1's dropped `a`.
        if "base_sha" in kv and attempt_id is None:
            return fail(f"base_sha for '{d}' refused: no attempt to scope it to")

        cur_base_sha = (
            disp["attempts"].get(attempt_id, {}).get("base_sha")
            if attempt_id is not None
            else None
        )
        if "base_sha" not in kv:
            if cur_base_sha is not None:
                kv["base_sha"] = cur_base_sha
        elif cur_base_sha is not None and kv["base_sha"] != cur_base_sha:
            return fail(
                f"base_sha mismatch for '{d}' attempt {attempt_id}: "
                f"fixed base_sha={cur_base_sha}, got {kv['base_sha']}"
            )

        disp["state"] = to
        if kv.get("lane") is not None:
            disp["lane"] = kv["lane"]
        if kv.get("a") is not None:
            disp["attempt"] = kv["a"]
        if "tab" in kv:
            disp["tab"] = kv["tab"]
        # B3: fold prompt_sha queryably (last write wins per dispatch --
        # each mint records the CURRENT attempt's finalized prompt hash,
        # and track's spawn stage only ever reads it for the current
        # attempt). Pure metadata: never gates the transition itself.
        if "prompt_sha" in kv:
            disp["prompt_sha"] = kv["prompt_sha"]
        for meta_key in ("repo", "branch"):
            if kv.get(meta_key) is not None:
                disp[meta_key] = kv[meta_key]
        if kv.get("base_sha") is not None and attempt_id is not None:
            disp["attempts"].setdefault(attempt_id, {})["base_sha"] = kv["base_sha"]
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
                _ai, _cat = _quarantine_attribution(state, etype, kv)
                quarantine_line(
                    state, prior_line, "(see original RETURNED line)",
                    f"duplicate result: superseded by line {line_no}",
                    attributed_issues=_ai, category=_cat,
                )
                quarantine_line(
                    state, line_no, raw,
                    f"duplicate result for {d}/{a} (first at line {prior_line})",
                    attributed_issues=_ai, category=_cat,
                )
                return False
            return fail(f"duplicate result for {d}/{a} refused (first recorded at line {prior_line})")

        if disp["state"] in TERMINAL:
            if mode == "quarantine":
                disp["state"] = "QUARANTINED"
                disp["result_sha"] = kv["result_sha"]
                _ai, _cat = _quarantine_attribution(state, etype, kv)
                quarantine_line(
                    state, line_no, raw,
                    f"late result after terminal for '{d}'",
                    attributed_issues=_ai, category=_cat,
                )
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
        # B2.2 prerequisite: ALSO store the result per-attempt, so a later
        # `merged` marker validates against the result of its OWN (d, a)
        # rather than the dispatch-level last-write-wins value. Additive to
        # the attempts entry (which may already carry base_sha); existing
        # consumers of dispatch-level result_sha are unaffected.
        if a is not None:
            disp["attempts"].setdefault(a, {})["result_sha"] = kv["result_sha"]
        return True

    if etype == "merged":
        # B2.2: a PURE corroboration record -- the human-attested "this
        # attempt's result landed on mainline as merge_sha" marker consumed
        # ONLY by track's G4 marker arm for squash/rebase workflows. It
        # never transitions dispatch state, never touches issue state,
        # never auto-VERIFIES, never overwrites result_sha. Deliberately NO
        # `i=` and NO `mainline_ref=` keys: attribution comes from the
        # fold's accepted maps, mainline_ref from config ONLY (an
        # event-supplied value would be a forged-token trap).
        d = kv["d"]
        disp = dispatches.get(d)
        if disp is None:
            return fail(f"merged marker for unregistered dispatch '{d}'")

        # F3: both sha fields must be full object names (40/64 lowercase
        # hex) -- shape-gated HERE, at the fold's trust boundary, not
        # deferred to track's close-time BASE_SHA_RE.
        for _shakey in ("merge_sha", "result_sha"):
            if not FULL_SHA_RE.match(kv[_shakey]):
                return fail(
                    f"merged marker for '{d}' refused: {_shakey}={kv[_shakey]} is not a "
                    "full 40/64-char lowercase-hex commit sha"
                )

        if "a" not in kv:
            if disp["attempt"] is None:
                return fail(f"merged marker for '{d}' refused: no attempt on record")
            kv["a"] = disp["attempt"]
        a = kv["a"]

        # `a` must be a REAL attempt of d with a recorded result, and the
        # marker's result_sha must equal that exact (d, a) result -- the
        # per-attempt store, never the dispatch-level last-write-wins one.
        att_result = (disp["attempts"].get(a) or {}).get("result_sha")
        if att_result is None:
            return fail(
                f"merged marker for {d}/{a} refused: no recorded result for that attempt "
                "(record the result first)"
            )
        if kv["result_sha"] != att_result:
            return fail(
                f"merged marker for {d}/{a} refused: result_sha={kv['result_sha']} does not "
                f"match the recorded result {att_result}"
            )

        # repo=: if present it must equal the dispatch's own recorded repo;
        # if absent, inherit it (may legitimately be unset on both).
        if "repo" in kv:
            if disp.get("repo") != kv["repo"]:
                return fail(
                    f"merged marker for {d}/{a} refused: repo={kv['repo']} does not match "
                    f"the dispatch's repo {disp.get('repo')}"
                )
        elif disp.get("repo") is not None:
            kv["repo"] = disp["repo"]

        # Duplicate markers for the same (d, a): an IDENTICAL re-append is
        # accepted idempotently; a CONFLICTING one (different merge_sha or
        # result_sha) is refused/quarantined -- conflict = surface, never
        # silently replace (no last-write-wins for corroboration records).
        # M4: read-only lookup here -- no setdefault mutation ahead of a
        # possible fail() on a conflicting marker; mutate only on accept.
        prior = (disp.get("merged") or {}).get(a)
        if prior is not None:
            if (prior.get("merge_sha") == kv["merge_sha"]
                    and prior.get("result_sha") == kv["result_sha"]):
                return True
            return fail(
                f"conflicting merged marker for {d}/{a}: prior merge_sha={prior.get('merge_sha')} "
                f"result_sha={prior.get('result_sha')}, got merge_sha={kv['merge_sha']} "
                f"result_sha={kv['result_sha']}"
            )

        disp.setdefault("merged", {})[a] = {
            "merge_sha": kv["merge_sha"], "result_sha": kv["result_sha"],
        }
        return True

    if etype == "question":
        q = kv["q"]
        st = kv["state"]
        if st not in QUESTION_STATES:
            return fail(f"illegal question state='{st}': not in {sorted(QUESTION_STATES)}")
        prev = questions.get(q)
        # Carry the issue link forward: a later event for the same question
        # that OMITS `i=` must NOT null out a previously-recorded link (the
        # known B2.0b trap — naive "latest line wins" loses the join).
        i = kv.get("i")
        if i is None and prev is not None:
            i = prev.get("i")
        questions[q] = {"state": st, "i": i}
        return True

    if etype == "unregistered_execution":
        state["unregistered"].append({"line": line_no, "at": kv["at"], "ref": kv["ref"]})
        return True

    if etype == "adopt":
        # Fail closed like every sibling handler (I2): an adopt naming an
        # unregistered dispatch is refused at write / quarantined at fold,
        # never a silent no-op ("never silently dropped", essence.md).
        d = kv["d"]
        disp = dispatches.get(d)
        if disp is None:
            return fail(f"adopt for unregistered dispatch '{d}'")
        disp["adopted_ref"] = kv["ref"]
        return True

    if etype == "spawn_intent":
        # B3: a PURE spawn-intent lease record for the automation lane --
        # appended durably by track BEFORE any herdr side effect, read ONLY
        # by track's spawn stage (crash recovery / duplicate-spawn
        # exclusion). It NEVER transitions dispatch or issue state. Legal
        # only when `d` is a registered dispatch, `a` is d's CURRENT
        # attempt, the dispatch is currently DISPATCHED, and its lane is
        # `automation` (the automation-lane guard: a spawn intent against a
        # human-lane dispatch is always a violation). The lease is
        # EXCLUSIVE (C4): ANY second intent for a (d, a) that already has
        # an open intent is refused at write / quarantined at fold, the
        # FIRST stands. Identical ref included -- track computes a
        # deterministic worker ref, so two concurrent tracks always
        # collide on the SAME ref, and treating that duplicate as
        # idempotent success made the loser believe it WON the lease and
        # spawn a second live agent. Refusing removes a spawn path
        # (fail-closed); the identical-ref refusal carries the distinct
        # `spawn-lease-held` token so track's spawn stage can classify
        # "lease held elsewhere -- skip" apart from a benign race.
        # Crash-replay stays convergent: a track that crashed after
        # appending its own intent never re-applies it on rerun -- the
        # plan stage's open-intent filter (fold-driven) routes that
        # dispatch down the ACK/orphan-surface path instead.
        d = kv["d"]
        disp = dispatches.get(d)
        if disp is None:
            return fail(f"spawn_intent for unregistered dispatch '{d}'")
        a = kv["a"]
        if disp["state"] != "DISPATCHED":
            return fail(
                f"spawn_intent for '{d}' refused: current state is "
                f"{disp['state']}, must be DISPATCHED"
            )
        if a != disp["attempt"]:
            return fail(
                f"spawn_intent attempt mismatch for '{d}': current "
                f"attempt={disp['attempt']}, got {a}"
            )
        if disp.get("lane") != "automation":
            return fail(
                f"spawn_intent for '{d}' refused: lane={disp.get('lane')}, "
                "spawn intents are automation-lane only"
            )
        prior = (disp.get("spawn_intent") or {}).get(a)
        if prior is not None:
            if prior.get("ref") == kv.get("ref"):
                return fail(
                    f"spawn-lease-held: duplicate spawn_intent for {d}/{a} "
                    f"refused: an open intent (ref={prior.get('ref')}) "
                    "already holds the exclusive lease -- a duplicate "
                    "append NEVER means the lease was won"
                )
            return fail(
                f"conflicting spawn_intent for {d}/{a}: prior "
                f"ref={prior.get('ref')}, got ref={kv.get('ref')}"
            )
        disp.setdefault("spawn_intent", {})[a] = {
            "ref": kv.get("ref"),
            "at": kv["at"],
            "line": line_no,
        }
        return True

    if etype == "note":
        # Never parsed for ISSUE/DISPATCH state. Sole exception (fix-pass-6
        # F1): auto-close provenance notes (ref=auto-close:* with an i=)
        # are folded QUERYABLY into state["auto_close_notes"] so track's
        # marker-close can dedup its pre-close audit note across crash
        # recovery -- reading the FOLD, never re-scanning the raw log.
        ref = kv.get("ref") or ""
        i = kv.get("i")
        if i and ref.startswith("auto-close:"):
            refs = state["auto_close_notes"].setdefault(i, [])
            if ref not in refs:
                refs.append(ref)
        # B3 second exception, same pattern: a durable prompt-copy binding
        # (ref=prompts/... with a d= naming a REGISTERED dispatch) is
        # folded queryably into dispatches[d].prompt_ref so track's spawn
        # stage re-resolves the prompt path from the FOLD (then re-hashes
        # it against the recorded prompt_sha) -- never from a raw-log
        # re-parse. Last write wins (a retry mint re-binds the same path).
        # Still never parsed for issue/dispatch STATE.
        d = kv.get("d")
        if d and ref.startswith("prompts/") and d in dispatches:
            dispatches[d]["prompt_ref"] = ref
        return True

    return fail(f"unhandled event type '{etype}'")


def fold_lines(raw_lines):
    """Whole-log quarantine-mode fold. Never raises."""
    state = new_state()
    state["dispatch_issue_raw"] = {}
    for line_no, raw in enumerate(raw_lines, start=1):
        if raw.strip() == "":
            continue
        try:
            etype, kv = parse_line(raw)
        except ValueError as e:
            quarantine_line(state, line_no, raw, str(e))
            continue
        # d->i attribution map, populated ONLY after apply_event ACCEPTS the
        # dispatch_new (P3-5). It feeds both (a) later attribution of OTHER
        # quarantined lines (dispatch_state/result) touching `d` back to an
        # issue, and (b) index.json's exported `dispatch_issue_map`. First
        # ACCEPTED registration wins (a later duplicate `d` is quarantined
        # by apply_event and never reaches the setdefault); today the sole
        # failable dispatch_new rule IS the duplicate check, so this is
        # semantics-preserving -- but gating on acceptance kills any future
        # divergence if dispatch_new ever grows more failable rules.
        accepted = apply_event(state, etype, kv, line_no, raw, "quarantine")
        if accepted and etype == "dispatch_new":
            d = kv.get("d")
            i = kv.get("i")
            if d and i:
                state["dispatch_issue_raw"].setdefault(d, i)
    return state


def write_outputs(state, index_path, quarantine_path):
    questions = state["questions"]
    open_questions = sorted([q for q, rec in questions.items() if rec["state"] == "OPEN"])

    # Per-issue view of OPEN questions (B2.0b / B2.1's G2 gate) — scoped ones
    # bucket by their carried `i`; OPEN questions with no issue link (never
    # set, or omitted from every event) surface separately so a later gate
    # can raise `open-question-unscoped` instead of silently missing them.
    open_questions_by_issue = {}
    open_questions_unscoped = []
    for q in open_questions:
        i = questions[q].get("i")
        if i:
            open_questions_by_issue.setdefault(i, []).append(q)
        else:
            open_questions_unscoped.append(q)
    for i in open_questions_by_issue:
        open_questions_by_issue[i].sort()
    open_questions_unscoped.sort()

    seen_refs = set()
    dedup_unregistered = []
    for u in state["unregistered"]:
        if u["ref"] in seen_refs:
            continue
        seen_refs.add(u["ref"])
        dedup_unregistered.append(u)

    # Per-issue view of QUARANTINED events (B2.1 auto-close hardening,
    # Codex-sparred defect #1, hardened further against defect #4/#5 in the
    # next round). A quarantined line represents a rule violation the fold
    # never accepted into standing state, but it still carries semantic
    # weight (an invalid question state, a corrupt dispatch/issue_state/
    # result touching an issue) that MUST block that issue's auto-close
    # rather than being silently invisible to it.
    #
    # Attribution is read ENTIRELY off `attributed_issues`/`category`, which
    # apply_event()/fold_lines() stamped onto each entry at the moment it
    # was quarantined, from the fold's own already-parsed etype/kv resolved
    # through the fold's OWN authoritative maps (dispatch_issue_raw /
    # questions) -- never by re-parsing `entry["raw"]` here, and never by
    # trusting the offending line's own (possibly forged) `i=`/`q=`/`d=`
    # tokens as the sole source. A second, independent parse of the same
    # line can disagree with the fold's own parse (e.g. it may accept a
    # line the fold's strict grammar rejected as a duplicate key), and a
    # forged `i=` on the offending line could otherwise redirect the block
    # away from the entity's REAL owner (Codex-sparred defect: the
    # misattribution variant) -- both are exactly the classes of divergence
    # this schema exists to rule out by construction. attributed_issues is
    # a SET: a quarantined line blocks EVERY issue it touches (its entity's
    # authoritative owner, plus -- additively -- its own claimed `i=`), not
    # just one.
    #
    # Any entry with an EMPTY attributed_issues (a bare grammar failure with
    # no coherent etype/kv at all, or a rule violation whose q/d/i all fail
    # to resolve to any known issue) is globally unattributable: it could
    # plausibly belong to ANY issue, so `quarantine_unattributable` blocks
    # ALL closeable issues for the tick rather than risk silently closing
    # the one it was meant for.
    # P3-9 cross-reference: templates/bin/track's _TR_CLOSE_PY defines these
    # SAME two constants (same names, same values) -- its auto-close G1.5
    # gate keys on the exact strings emitted here, so they must change in
    # BOTH places or not at all.
    REASON_INVALID_QUESTION_STATE = "invalid-question-state"
    REASON_ISSUE_RELATED_QUARANTINE = "issue-related-quarantine"

    quarantine_by_issue = {}
    quarantine_unattributable = False
    for entry in state["quarantined"]:
        issues = entry.get("attributed_issues") or []
        category = entry.get("category")
        if issues:
            reason = REASON_INVALID_QUESTION_STATE if category == "question" else REASON_ISSUE_RELATED_QUARANTINE
            for issue in issues:
                quarantine_by_issue.setdefault(issue, set()).add(reason)
        else:
            quarantine_unattributable = True
    quarantine_by_issue = {i: sorted(r) for i, r in quarantine_by_issue.items()}

    index = {
        "schema_v": "1",
        "issues": state["issues"],
        "dispatches": state["dispatches"],
        "quarantined": state["quarantined"],
        "unregistered": dedup_unregistered,
        "questions": questions,
        "open_questions": open_questions,
        "open_questions_by_issue": open_questions_by_issue,
        "open_questions_unscoped": open_questions_unscoped,
        "quarantine_by_issue": quarantine_by_issue,
        "quarantine_unattributable": quarantine_unattributable,
        # Authoritative dispatch_new -> issue map (Codex-sparred defect #1,
        # round 2; tightened by P3-5): populated ONLY from ACCEPTED
        # (successfully-applied) dispatch_new events -- fold_lines runs the
        # setdefault strictly AFTER apply_event returns True, so a
        # quarantined duplicate `d` (business-rule failure) never touches
        # it, and a HARD parse failure (e.g. a duplicate-key poison line)
        # never reaches it either. Consumers (track's B2.1 auto-close
        # pass) MUST read this map instead of re-scanning the raw event log
        # themselves; the fold is the single source of truth for
        # dispatch<->issue linkage. Additive
        # to the schema -- existing consumers of index.json are unaffected.
        "dispatch_issue_map": dict(state.get("dispatch_issue_raw", {})),
        # fix-pass-6 F1: marker-close provenance notes, per issue (additive).
        "auto_close_notes": state.get("auto_close_notes", {}),
    }

    # C5: never truncate the authoritative index/quarantine in place -- a
    # concurrent reader must only ever see a complete OLD file or a
    # complete NEW file, never a half-written one. Write to a same-dir tmp
    # and os.replace() (atomic rename on POSIX). No fsync here: both files
    # are DERIVED state, fully regenerable from events.log by the next
    # fold, so crash-durability is not part of their contract.
    index_tmp = index_path + ".tmp"
    with open(index_tmp, "w") as f:
        json.dump(index, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(index_tmp, index_path)

    if state["quarantine_lines"]:
        quarantine_tmp = quarantine_path + ".tmp"
        with open(quarantine_tmp, "w") as f:
            f.write("\n".join(state["quarantine_lines"]) + "\n")
        os.replace(quarantine_tmp, quarantine_path)
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

  # C5: fold under the repo lock. Without it, an unlocked fold that read
  # events.log BEFORE a lock-holder's append could finish writing
  # index.json AFTER that holder's own refold, silently reverting the
  # index to pre-commit state. pm_lock is reentrant, so callers already
  # holding the lock (pm_apply's post-commit refold path, track's
  # under-lock refolds) pay nothing. The fold's python never re-enters
  # bash, so no lock-ordering cycle is possible. Note the lock is taken
  # in THIS shell (not the subshell) so reentrancy depth is tracked
  # correctly in the caller's process.
  pm_lock "$root" || return 1
  local rc
  (
    export PM_FOLD_LOG="$log" PM_FOLD_INDEX="$index" PM_FOLD_QUARANTINE="$quarantine"
    printf '%s\n%s\n' "$_PM_ENGINE_PY" "$_PM_FOLD_DRIVER_PY" | python3 -
  )
  rc=$?
  pm_unlock
  return "$rc"
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
    _rendered = render_line(etype, kv)
    # I1 belt-and-suspenders: TOKEN_RE/FULL_SHA_RE et al gate every value
    # BEFORE this point, but a single embedded "\n" reaching render_line
    # (a future new field, a regex weakened by a future edit, ...) would
    # silently split one committed event into two log lines -- corrupting
    # line-oriented parse/quarantine attribution downstream. Refuse the
    # whole batch outright rather than stripping/escaping it: a value that
    # made it this far with a newline in it means a upstream guard already
    # failed, and silently sanitizing would hide that failure instead of
    # surfacing it.
    if "\n" in _rendered:
        print(f"pm_apply: internal error: rendered line for type '{etype}' contains a newline")
        sys.exit(1)
    new_lines.append(_rendered)

# H2/I3: the log append is the FINAL commit point. It is issued as one
# f.write() -- not a per-line loop -- to MINIMIZE the window for a partial
# multi-event batch (this is tear-minimizing, not a hard all-or-nothing
# guarantee: a payload larger than the stdio buffer can still split into
# multiple write(2) syscalls). It is then flushed and fsync'ed BEFORE
# success is reported, so no caller can order an external side effect
# (e.g. track's herdr spawn after a spawn_intent lease) ahead of the
# commit actually reaching disk -- a power loss after exit 0 must never
# lose an event the caller already acted on.
batch_text = "".join(line + "\n" for line in new_lines)
with open(log_path, "a") as f:
    f.write(batch_text)
    f.flush()
    os.fsync(f.fileno())

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
# pm_config_repos — THE one parser of config.json's `repos` (I6)
# ---------------------------------------------------------------------------

pm_config_repos() {
  # pm_config_repos <config.json path>
  # Echo a normalized JSON LIST of repo objects:
  #   {"name", "path", "mainline", "mainline_ref", "fetch_policy",
  #    "merge_mode", "allow_marker_branch_deleted"}
  # (absent per-entry keys -> null; unknown extra keys are preserved).
  # Every tool that reads `repos` MUST call this instead of re-parsing, so
  # shape tolerance can never diverge between tools again (I6: four
  # independent parsers accepted four different subsets). Canonical shape is
  # scaffold's -- a LIST of {name, path, ...} objects; a legacy dict
  # {name: {...}} / {name: "path"} is tolerated. Any entry without BOTH a
  # non-empty name and a non-empty path is skipped WITH a stderr warning
  # (surfaced, never silent -- and uniformly: previously ledger-check
  # probed nameless entries that track dropped without a word). VALUE
  # validation (e.g. mainline_ref well-formedness) stays with each
  # consumer's own fail-closed runtime checks. An unreadable/invalid
  # config yields [] plus a warning, never a crash.
  local config_path="${1:-}"
  if [[ -z "$config_path" ]]; then
    echo "pm_config_repos: missing <config.json path>" >&2
    return 1
  fi
  PM_CFG_PATH="$config_path" python3 - <<'PYEOF'
import json
import os
import sys

cfg_path = os.environ["PM_CFG_PATH"]
try:
    with open(cfg_path) as f:
        cfg = json.load(f)
except Exception as e:
    print(f"pm_config_repos: WARN: cannot read {cfg_path}: {e}", file=sys.stderr)
    print("[]")
    raise SystemExit(0)

repos = cfg.get("repos")
KNOWN = (
    "mainline",
    "mainline_ref",
    "fetch_policy",
    "merge_mode",
    "allow_marker_branch_deleted",
)
out = []


def add(name, val, where):
    entry = {}
    if isinstance(val, dict):
        entry = dict(val)
        path = entry.get("path") or ""
    elif isinstance(val, str):
        path = val
    else:
        print(
            f"pm_config_repos: WARN: skipping repos entry {where}: "
            f"not an object or path string",
            file=sys.stderr,
        )
        return
    if not (isinstance(name, str) and name) or not (isinstance(path, str) and path):
        print(
            f"pm_config_repos: WARN: skipping repos entry {where}: "
            "missing a non-empty name and/or path (canonical shape is a list "
            'of {"name", "path", "mainline", ...} objects)',
            file=sys.stderr,
        )
        return
    entry["name"] = name
    entry["path"] = path
    for k in KNOWN:
        entry.setdefault(k, None)
    out.append(entry)


if isinstance(repos, dict):
    for name, val in repos.items():
        add(name, val, f"'{name}'")
elif isinstance(repos, list):
    for idx, val in enumerate(repos):
        name = val.get("name") if isinstance(val, dict) else None
        add(name, val, f"[{idx}]")
elif repos is not None:
    print(
        f"pm_config_repos: WARN: repos has unsupported type "
        f"{type(repos).__name__}; treating as empty",
        file=sys.stderr,
    )

print(json.dumps(out))
PYEOF
}

# ---------------------------------------------------------------------------
# _PM_MD_PY — shared Markdown-surface python helpers (single-sourced, I8)
# ---------------------------------------------------------------------------
# The ONE copy of the GENERATED-block writer (render_marker) and the
# Markdown-injection escapers (esc_md_inline / esc_md_cell / esc_md_heading)
# used by track's and reconcile's embedded python. Consumers PREPEND this
# snippet to their driver -- never copy-paste it -- the same way track
# composes _TR_CORROB_PY:
#   bash -c 'printf "%s\n%s\n" "$1" "$2" | python3 -' _ "${_PM_MD_PY}" "${driver}"
# Contract: render_marker appends its skip notices to a global `conflicts`
# list, which the DRIVER must define before calling it.
# shellcheck disable=SC2034  # consumed by sourcing scripts (track/reconcile)
read -r -d '' _PM_MD_PY <<'PYEOF' || true
import os
import re


def esc_md_inline(value):
    # Backslash-escape GFM inline-Markdown-active characters so a value we
    # did not author cannot be reinterpreted as emphasis, code spans,
    # links, or (if it lands at the very start of a line) a heading/list/
    # blockquote marker. Must run AFTER any "&"/pipe HTML-entity escaping
    # so the backslashes it inserts are never themselves re-escaped.
    s = "" if value is None else str(value)
    s = re.sub(r"([`*_\[\]()~])", r"\\\1", s)
    s = re.sub(r"^([#>+-])", r"\\\1", s)
    # Ordered-list marker: the backslash must precede the "." (CommonMark
    # does not treat "\<digit>" as an escape -- only "\." is), not the digits.
    s = re.sub(r"^(\d+)\.", r"\1\\.", s)
    return s


def esc_md_cell(value):
    # Sanitize a value for use inside a Markdown table cell: neutralize
    # embedded HTML, pipes, line breaks, and inline Markdown syntax so a
    # value we did not author (a repo path, branch name, herdr tab label,
    # or status string) can never break out of its row/column, fabricate
    # extra table rows, render as live HTML, or render as live Markdown
    # (emphasis, code spans, links). Order matters: escape "&" first so the
    # entities produced by the later replacements are not themselves
    # re-escaped, then pipes, then the inline-Markdown backslash-escapes.
    s = "" if value is None else str(value)
    s = s.replace("&", "&amp;")
    s = s.replace("<", "&lt;").replace(">", "&gt;")
    # GFM table-cell pipe escaping via "\|" is ambiguous next to other
    # backslashes; the HTML entity is unambiguous regardless of context.
    s = s.replace("|", "&#124;")
    s = s.replace("\r\n", " ").replace("\r", " ").replace("\n", " ")
    s = esc_md_inline(s)
    return s


def esc_md_heading(value):
    # Sanitize a value for use as Markdown heading text (e.g. "### {name}"):
    # strip CR/LF so it cannot inject a new line that starts its own
    # heading/fence, escape HTML so it cannot render as live markup,
    # neutralize inline Markdown syntax (emphasis, code spans, links) so
    # the value renders literally, and neutralize a leading "#" or
    # backtick by escaping just that first character -- CommonMark's
    # ATX-heading rule only fires when "#" is the very first character of
    # the line, so a leading "\#"/"\`" can never be reinterpreted as a
    # heading marker or code-fence opener. Order matters: HTML entities
    # first, then the inline-Markdown backslash-escapes, so the escaping
    # backslashes are not themselves re-escaped.
    s = "" if value is None else str(value)
    s = s.replace("\r\n", " ").replace("\r", " ").replace("\n", " ")
    s = s.replace("&", "&amp;")
    s = s.replace("<", "&lt;").replace(">", "&gt;")
    s = esc_md_inline(s)
    return s


def render_marker(md_path, key, body):
    # The GENERATED-block writer: replace ONLY the bytes between the
    # BEGIN/END markers for `key`, never anything outside them (hand-
    # authored prose is sacred). Missing file / missing markers append a
    # skip notice to the driver's global `conflicts` list -- surfaced,
    # never fatal.
    if not os.path.isfile(md_path):
        conflicts.append(f"{os.path.basename(md_path)}: file not found at {md_path} -- skipped")
        return
    with open(md_path, "r") as f:
        content = f.read()
    begin = f"<!-- GENERATED:BEGIN {key} -->"
    end = f"<!-- GENERATED:END {key} -->"
    pattern = re.compile(re.escape(begin) + r".*?" + re.escape(end), re.DOTALL)
    if not pattern.search(content):
        conflicts.append(
            f"{os.path.basename(md_path)}: no '{key}' GENERATED markers found -- skipped "
            f"(scaffold may not have materialized them yet)"
        )
        return
    replacement = f"{begin}\n{body}\n{end}"
    # NOTE: pass the replacement via a lambda so re.sub treats it as a
    # literal string -- it must NOT go through re.sub's plain-string
    # replacement path (which interprets backslash escapes / \g<...>
    # group references and would corrupt any literal backslash in a
    # label or path inside `body`).
    new_content = pattern.sub(lambda _m: replacement, content, count=1)
    if new_content != content:
        with open(md_path, "w") as f:
            f.write(new_content)
PYEOF

# ---------------------------------------------------------------------------
# pm_close_issue — in-process, lock-reentrant core of `bin/close`.
# The close-and-archive block (~275 lines: _pm_close_issue_state /
# pm_close_issue / _pm_close_issue_core) lives in the sibling
# _close_lib.sh (I24); sourcing it here keeps the FROZEN API surface of
# this file unchanged for every existing consumer.
# ---------------------------------------------------------------------------
# shellcheck source=./_close_lib.sh
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_close_lib.sh"

# ---------------------------------------------------------------------------
# escapers — esc_shell is the ONE bash escaper with real call sites
# (dispatch-prep's printed herdr command). The former esc_md / esc_json /
# esc_path / esc_gitref were deleted (I14): zero call sites in any shipped
# script, while the Markdown job is actually done by the shared _PM_MD_PY
# python helpers above -- keeping dead near-duplicates of a security
# surface invites drift. Re-add a context-specific escaper only WITH its
# first real caller.
# ---------------------------------------------------------------------------

esc_shell() {
  # esc_shell <string>
  # Echo a POSIX-sh-safe single-quoted token: wraps in single quotes,
  # escaping embedded single quotes as '\'' . Safe to eval/interpolate as one
  # word; neutralizes $(), backticks, ;, |, globs, leading '-'.
  local s="${1-}"
  printf "'%s'" "${s//\'/\'\\\'\'}"
}
