# Enforcement contract (schema v=1) — how events are validated

Companion to `event-log-grammar.md`. The grammar says what a valid *line* looks like; this
says what a valid *transition* is and WHERE it is enforced. Written after spar round 4, which
found the original split-enforcement design under-validated and raced.

## Principle: one rule set, two enforcement points, one critical section

There is ONE validation rule set (§2–§5). It is applied at exactly two points, and NOWHERE
else (wrappers must not re-implement it):

1. **`pm_apply` (write path) — transactional.** A single function that, under ONE held repo
   lock: (a) folds the current log to in-memory current state, (b) validates the proposed
   event(s) against current state using the shared rule set, (c) on pass appends the line(s)
   atomically, (d) refolds `.pm/index.json`, (e) releases the lock. On failure it appends
   NOTHING and returns non-zero with a one-line reason. A batch form applies several events
   as one atomic transaction (each validated against the evolving in-memory state). The lock
   itself (`pm_lock`/`pm_unlock`, mkdir-based) records its owner identity — PID *and* that
   PID's process start-time (`/proc/<pid>/stat` field 22, where available) — and reclaims a
   stale lock left behind by a crashed/`kill -9`'d holder once that PID is provably dead, OR
   once a live PID's start-time no longer matches what was recorded (the PID was reused by an
   unrelated later process, so the original holder is just as gone as if it were dead), instead
   of failing forever on timeout. Where `/proc` is unavailable this degrades gracefully to a
   PID-liveness-only check (the pre-existing behavior).
   - **Write/fold parity (invariant):** `pm_apply`/`pm_apply_batch` MUST refuse (non-zero,
     append NOTHING) exactly what `pm_fold` would quarantine — never write-then-later-quarantine
     the same line. Concretely: after `apply_event` derives any additional fields onto a
     candidate event (e.g. `dispatch_state`'s engine-derived `a`, `lane`), EVERY field that will
     actually be serialized by `render_line` — not merely the type's `REQUIRED` subset — is
     revalidated as non-`None` and token-charset-valid before the line is ever rendered. A field
     that has no meaningful value yet (e.g. `a` on a `dispatch_state` for a dispatch that was
     never minted an attempt) is left OUT of the rendered line entirely (it is `OPTIONAL`) rather
     than serialized as a literal `None` — a literal `a=None` is indistinguishable on re-parse
     from the token string `"None"`, which is exactly the round-trip bug this guards against.
   - **Batch commit-is-final semantics.** The log append is the single durable commit point. The
     whole validated batch is written with ONE buffered `write()` (never a per-line loop), so
     under normal operation a batch commits all-or-nothing and the rule for callers holds:
     **exit non-zero ⇒ nothing was committed; exit zero ⇒ everything was committed**
     (`.pm/index.json` may be stale-but-recoverable). This is **validation-atomic and
     best-effort-durable, NOT a crash/ENOSPC atomicity guarantee**: a single buffered `write()`
     is not a guaranteed single kernel `write(2)`, so a process kill or a full disk mid-append
     can still leave a truncated trailing line on disk. That case is caught not by the write but
     by the **fold**: the grammar is strict and line-oriented, so `pm_fold` quarantines any
     malformed/partial trailing record — the log's integrity backstop, consistent with the
     write/fold-parity invariant. Once the append returns cleanly, rebuilding
     `index.json`/`quarantine.log` is best-effort — if that refold fails,
     `pm_apply`/`pm_apply_batch` still exits 0 (the events are valid and already committed) and
     warns that the index is stale and a `pm_fold`/reconcile re-run is needed, rather than
     returning a failure that would contradict what was actually committed.
2. **`pm_fold` (read path) — quarantine.** When folding a log that may have been hand-edited
   or externally appended, the SAME rule set runs; a violating line is routed to
   `.pm/quarantine.log` with a reason and excluded from the fold (never silently dropped).

`pm_emit` (raw grammar-only append, later renamed `pm_raw_append`) does NOT exist in shipped
`templates/bin/_lib.sh` at all — a rule-engine-bypassing appender must never be reachable from
a generated repo. The only sanctioned way to append to the log in shipped code is `pm_apply` /
`pm_apply_batch`. A test-only equivalent (grammar-only validation, no transition legality, no
attempt minting, no duplicate/supersede/lane checks) lives in `test/_seed.sh`, which is sourced
by test suites AFTER `_lib.sh` and reuses its grammar tables purely as fixture-seeding
plumbing — it is never part of the product surface. Wrappers (`dispatch-prep`, `record`)
become thin: gather args → call `pm_apply` → report. They hold NO legality tables and do NO
separate read-decide-then-emit (that was the TOCTOU).

## §2 Grammar (unchanged)
Known type; all required keys present; no duplicate keys; every value matches the token
charset `[A-Za-z0-9._:+/@?-]`.

## §3 Issue transitions (`issue_state`)
- First event for an issue establishes its state; `from` is recorded as given (default: current
  state, or `OPEN` if the issue has no prior state).
- Both `to` and `from` MUST be one of `OPEN ACTIVE IN-PROGRESS TODO PARKED BLOCKED NEEDS-USER
  CLOSED` (the issue-state set from `event-log-grammar.md`) — any other value (e.g. `to=PWNED`)
  is refused (write) / quarantined (read). This is checked before the transition-legality check
  below, so an illegal value never has a chance to also fail on "from != current".
- Thereafter `from` MUST equal current. Any `to` in the issue-state set is legal.
- `CLOSED → *` is legal but WARNed (reopen).

## §4 Dispatch lifecycle
`dispatch_new`: the `d` MUST NOT already exist. A duplicate `dispatch_new` is REFUSED (write
path) / QUARANTINED (read path) — it must never silently reset an existing dispatch.

Legal `dispatch_state` edges (and NOTHING else):
| from | to | notes |
|---|---|---|
| READY | DISPATCHED | mints a new attempt (§5) |
| DISPATCHED | ACKED | |
| RETURNED | VERIFIED | |
| FAILED | DISPATCHED | retry — mints a new attempt |
| DISPATCHED/ACKED/RETURNED | FAILED | an in-flight attempt did not succeed |
| READY/DISPATCHED/ACKED/RETURNED | ABANDONED | any active → ABANDONED (terminal) |
| READY/DISPATCHED/ACKED/RETURNED | QUARANTINED | |
| QUARANTINED | VERIFIED | accept |
| QUARANTINED | ABANDONED | reject |

- **`READY → FAILED` is deliberately NOT a legal edge (H1).** `FAILED` means an attempt was
  made and did not succeed; a dispatch still in `READY` has never minted an attempt
  (`attempt=None`), so it cannot have failed one. A dispatch that should never be pursued goes
  `READY → ABANDONED`/`QUARANTINED` instead (both remain legal above). Attempting `record
  dispatch <D> FAILED` on a `READY` dispatch is refused (write) / quarantined (read) as an
  illegal edge, not silently accepted with a null attempt.
- For the other `READY → {ABANDONED, QUARANTINED}` edges, the dispatch legitimately has no
  attempt yet: the rendered `dispatch_state` line simply omits `a` (it is `OPTIONAL`) rather
  than deriving a literal `None` — see the write/fold-parity note in §1.
- **`to=RETURNED` is NOT a legal `dispatch_state`.** RETURNED is reached ONLY by a `result`
  event (§4.1). `record dispatch <D> RETURNED` must be refused, pointing the user at `record
  result`.
- `from` MUST equal current. An edge not in the table is refused/quarantined.
- **Late/terminal:** a transition out of a terminal (VERIFIED/ABANDONED) is refused (write)
  / quarantined (read). It is NOT treated as a normal transition. On the read path, quarantine
  moves ONLY the dispatch's `state` to `QUARANTINED` — it does NOT overwrite the standing
  dispatch's `attempt`/`lane`/`tab` with fields from the offending (illegal) event. Those
  fields keep whatever values were last legitimately committed, so a late/bogus event can
  never clobber real history on its way to being rejected.

### §4.1 result
`result d a status result_sha at`. `status` (RETURNED/FAIL/PASS/…) is metadata carried on
the result, not a separate lifecycle — a legal result of ANY `status` value is legal only
when the dispatch's current state is `ACKED` and `a == the dispatch's current attempt`, and
it always advances the dispatch to `RETURNED` (the one intake state). There is no bypass for
non-`RETURNED` statuses: `record result D FAIL --sha …` is held to the exact same
preconditions as `record result D RETURNED --sha …`.
- Duplicate detection runs BEFORE both the terminal-state check and the ACKED/attempt
  preconditions below: a second `result` for the same `d/a` (whatever its `status`) is a
  duplicate of the first, **even if the dispatch has already reached a true terminal state
  (VERIFIED/ABANDONED) by the time the duplicate is seen.** This matters because a legal
  `result` advances the dispatch to `RETURNED`, and a subsequent `dispatch_state RETURNED ->
  VERIFIED` can land before a delayed/replayed duplicate `result` arrives; without checking
  duplicate-first, that duplicate would be classified as "late result after terminal" instead
  of "duplicate", and the original result line would never be re-flagged. The first result is
  already committed and cannot be un-applied, but the duplicate line is quarantined, the
  original RETURNED line is *also* re-flagged in quarantine.log pointing at the duplicate, and
  the dispatch itself is moved to `QUARANTINED` (not left silently `RETURNED`/`VERIFIED`) —
  this is a data integrity conflict that needs human adjudication, not something a later reader
  can silently reconcile by picking "the first one wins". Precisely: the first-committed result
  stays applied in the log, but every later result for that `d/a` is quarantined-as-duplicate
  and drags the dispatch to `QUARANTINED`, regardless of what terminal state it had already
  reached.
- A `result` on a superseded dispatch, or with a mismatched attempt, or in a non-ACKED
  state (and not a duplicate per the rule above) → refused (write) / quarantined (read).
- After `apply_event` derives any additional fields (e.g. `a`, when the caller omitted it),
  EVERY field that will actually be rendered — not just the type's required keys — is
  revalidated before the event is ever written to the log: a `None` or malformed derived value
  can never be rendered into a log line (`pm_apply: internal error: derived key … invalid for
  type …`). This is the general form of the write/fold-parity guarantee described in §1.

## §5 Attempts
- Attempts are `A-01, A-02, …`, minted by `pm_apply` (NOT the caller) on each transition to
  DISPATCHED: `a = max_attempt_so_far + 1`. If a caller supplies `a`, it MUST equal that
  value or the event is refused.
- Every non-mint dispatch_state / result carries `a == current attempt`. Backward, reused, or
  skipped attempts are refused/quarantined.

## §6 Lane ownership (immutable per dispatch)
- `lane` is fixed when the dispatch first enters DISPATCHED. Every later `dispatch_state`
  for that dispatch MUST carry the same `lane` (or omit it and inherit). A differing `lane`
  is refused/quarantined. (This makes lane ownership immutable, per the design.)

## §7 Superseding
- `dispatch_new … supersedes=D-x` marks D-x superseded. This is order-independent: if D-x's
  own `dispatch_new` has not yet been folded when the superseding event is seen, the
  supersede is recorded as pending and applied to D-x retroactively the moment D-x is
  registered — so a forward reference (`dispatch_new D-2 supersedes=D-1` appearing before
  `D-1`'s own `dispatch_new`) still marks D-1 superseded, regardless of log order.
- Any later `result` or non-terminal `dispatch_state` on a superseded dispatch → quarantined
  (may hold useful work; needs human adjudication), never applied.

## §8 index.json (schema preserved)
`pm_fold` keeps the existing top-level keys `dispatches` (dict), `issues` (dict),
`open_questions` (list), `quarantined` (list), `unregistered` (list), `schema_v` (str), and
per-dispatch fields already consumed by `reconcile`/`ledger-check` (`state`, `attempt`,
`lane`, `tab`, `result_sha`, `child_of`, `supersedes`). New enforcement may ADD fields but
must not rename/remove these. `unregistered` entries are deduped by `ref`.
