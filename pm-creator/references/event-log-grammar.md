# Event-log grammar (schema v=1) — the authoritative state record

This is the **keystone** of a generated PM repo. `.pm/events.log` is the single source of
truth for state. Markdown prose (`LEDGER.md`, `DISPATCHES.md`, …) is a human narrative and
is **never parsed for state**. `.pm/index.json` is a regenerable fold of this log.

Every `bin/` script depends on this grammar. It is a FROZEN contract: additive changes bump
the schema version; existing keys never change meaning.

> **Version note.** Grammar revision **1.1** (B2.2) ADDITIVELY introduces the `merged`
> event type (§3). The wire header stays `EVENT schema v=1`: no existing key changed
> meaning and pre-1.1 logs remain valid unchanged. The reverse direction is NOT benign:
> a pre-1.1 engine folding a 1.1 log quarantines every `merged` line as an unknown
> event type, and an unknown-type quarantine is UNATTRIBUTABLE — which trips the
> global G1.5 fail-safe and freezes auto-close REPO-WIDE (every issue, not just the
> marker's) until the lines are removed from the log. Upgrade all engines that read a
> log BEFORE recording any `merged` events into it. (Deliberate: quarantine
> attribution is never narrowed for unknown event types — using a `d=` token from a
> line the engine cannot parse to scope the blast radius would weaken the fail-safe.)

> **Version note.** Grammar revision **1.2** (B3) ADDITIVELY introduces the
> `spawn_intent` event type (§3) — the automation lane's durable spawn-intent lease.
> The wire header stays `EVENT schema v=1`: no existing key changed meaning and
> pre-1.2 logs remain valid unchanged. The reverse direction is NOT benign, exactly
> as with rev 1.1: a pre-1.2 engine folding a 1.2 log quarantines every
> `spawn_intent` line as an unknown event type, and an unknown-type quarantine is
> UNATTRIBUTABLE — which trips the global G1.5 fail-safe and freezes auto-close
> REPO-WIDE (every issue, not just the intent's dispatch) until the lines are
> removed from the log. Upgrade all engines that read a log BEFORE enabling
> `automation.auto_spawn` (or otherwise recording `spawn_intent` events) in it.

## 1. Record format

- One event per line, no wrapping:
  `EVENT <type> <key>=<value> <key>=<value> ...`
- The **first line of the file** is the schema header: `EVENT schema v=1`.
- Keys are a fixed set per `type` (§3). Order is not significant; a canonical order is
  recommended for readability. Duplicate keys on one line are malformed.
- **Values are token-safe:** charset `[A-Za-z0-9._:+/@-]`, non-empty, no spaces, no `=`, no
  newlines. This covers ids (`D-001`, `A-02`, `I-004`, `Q-007`), states (`DISPATCHED`),
  hex shas, ISO-8601-Z timestamps (`2026-07-23T18:00:00Z`), lane names, and the literal `?`.
- **No free text in the log.** Human prose lives in Markdown. Events carry only ids,
  states, hashes, timestamps, and `ref=` pointers (a token naming a tab/branch/path/anchor).

## 2. Append & fold discipline

- **Append** is atomic and lock-guarded: take the repo lock (`mkdir` lock), write exactly
  one `\n`-terminated line with `O_APPEND`, release. Never rewrite or reorder existing lines.
- **Log order is authority.** The fold applies events in file order; `at=` timestamps are
  informational only and are never used to sort (avoids clock-skew reordering).
- **Fold** (`fold_index`) reduces the stream to `.pm/index.json`:
  - per issue → current state;
  - per dispatch → current state, current attempt, lane, tab, last `result_sha`,
    `child_of`, `supersedes`;
  - lists: `quarantined[]`, `unregistered[]`, `open_questions[]`.
  - Rule: **last write wins per (entity, field)** in log order.

## 3. Event types & required keys

| type | required keys | optional keys | meaning |
|---|---|---|---|
| `schema` | `v` | — | header, first line only |
| `issue_state` | `i from to at` | `by` (D-###) | issue transitions |
| `dispatch_new` | `d i at` | `child_of supersedes` | register a dispatch in state READY |
| `dispatch_state` | `d from to lane at` | `a tab prompt_sha repo branch base_sha` | dispatch lifecycle transition |
| `result` | `d a status result_sha at` | — | a returned result artifact |
| `merged` | `d a merge_sha result_sha at` | `repo` | human-attested mainline-merge corroboration marker (B2.2) |
| `question` | `q state at` | `i a_of` | Q&A lifecycle (OPEN/ANSWERED) |
| `unregistered_execution` | `at ref` | — | reconcile found work with no dispatch |
| `adopt` | `d a at ref` | — | operator absorbs unregistered work into a dispatch |
| `note` | `at ref` | `d i` | pointer to a prose anchor (never parsed for state) |
| `spawn_intent` | `d a at` | `ref` | automation-lane durable spawn-intent lease (B3, grammar revision 1.2) |

- `lane` ∈ {`human`, `automation`}. `tab` is a herdr tab id or `?` (unknown at dispatch,
  resolved at ACK). `a` is `A-##`.
- `merged` (grammar revision 1.1, ADDITIVE — see the version note above) is a **pure
  corroboration record** for squash/rebase workflows, emitted by the human lane only
  (`record merged`): it attests that the result of attempt `(d, a)` landed on the
  configured mainline as commit `merge_sha`. The fold accepts it only when `d` is a
  registered dispatch, `a` is a real attempt of `d` with a recorded result, and
  `result_sha` equals that exact `(d, a)` result; `repo` (optional) must equal the
  dispatch's own recorded repo (else it is inherited). An accepted marker is stored per
  `(d, a)` (`dispatches[d].merged[a]`) and read ONLY by `track`'s auto-close G4 marker
  arm; it never transitions dispatch state, never touches issue state, never
  auto-VERIFIES, never overwrites `result_sha`. Deliberately **no `i=` and no
  `mainline_ref=` keys**: attribution comes from the fold's accepted maps and the
  mainline ref from config only (an event-supplied value would be a forged-token trap).
  A conflicting second marker for the same `(d, a)` (different `merge_sha`/`result_sha`)
  is refused at write and quarantined at fold — the FIRST accepted marker stands; an
  identical re-append is accepted idempotently.
- `spawn_intent` (grammar revision 1.2, ADDITIVE — see the version note above) is the
  automation lane's **durable spawn-intent lease**, appended by `track` under the repo
  lock BEFORE any herdr side effect (durability-before-effect): it records "track is
  about to spawn worker `ref=` for attempt `(d, a)`", so a crash between the intent and
  the spawn/ACK is recoverable next tick instead of silently double-spawning. The fold
  accepts it only when `d` is a registered dispatch, `a` is d's CURRENT attempt, the
  dispatch is currently DISPATCHED, and its lane is `automation` (a spawn intent against
  a human-lane dispatch always quarantines). An accepted intent is stored per `(d, a)`
  (`dispatches[d].spawn_intent[a]`) and read ONLY by `track`'s spawn stage; it never
  transitions dispatch state, never touches issue state, never ACKs by itself. A
  conflicting second intent for the same `(d, a)` (different `ref`) is refused at write
  and quarantined at fold — the FIRST accepted intent stands; an identical re-append is
  accepted idempotently.
- `repo`/`branch`/`base_sha` are OPTIONAL git-corroboration metadata, set (if at all) at
  mint time: `repo` names a configured repo, `branch` is the expected branch
  (`i<num>-<slug>` per `CONVENTIONS.md` §7), `base_sha` is the mainline commit the dispatch
  was cut from. `repo` and `branch` are, like `lane`, **immutable per dispatch** once first
  set. `base_sha` is instead **immutable per attempt** (`(d, a)`): each `MINTING_EDGES`
  transition (`READY → DISPATCHED` or a `FAILED → DISPATCHED` retry) starts a fresh attempt
  and may record its own `base_sha` against the repo's mainline HEAD at that moment, even if
  it differs from an earlier attempt's `base_sha`; within one attempt the value is still
  fixed once set. See `enforcement.md` §6.

## 4. State machines

### 4.1 Issue states
`OPEN ACTIVE IN-PROGRESS TODO PARKED BLOCKED NEEDS-USER CLOSED`.
Legality rule (checked by `ledger-check`): a transition's `from` MUST equal the issue's
current folded state. `CLOSED → *` is legal but WARNed as a reopen. There is no other
whitelist — the `from==current` check is the integrity guard against stale/rebased edits.

### 4.2 Dispatch lifecycle
```
        dispatch_new
            │
            ▼
         READY ──► DISPATCHED ──► ACKED ──► RETURNED ──► VERIFIED   (terminal-accept)
            ▲          │                        │
            │          ▼                        ▼
         FAILED ◄──(any active)            QUARANTINED ──► VERIFIED | ABANDONED
            │                                   ▲
            ▼                                   │
       (retry: new attempt)              (dup / late / superseded return)
                              ABANDONED  (terminal-reject)
```
Rules (checked by `ledger-check`):
- Every `dispatch_state.from` MUST equal the dispatch's current folded state.
- `READY → DISPATCHED` **mints a new attempt** `a=A-##` (monotonic per D: A-01, A-02, …).
  States from DISPATCHED through a terminal carry that same `a`.
- Active states = {READY, DISPATCHED, ACKED, RETURNED}. `FAILED` is reachable **only** from
  {DISPATCHED, ACKED, RETURNED} — **not** from READY (READY never minted an attempt, so there is
  nothing to fail; `READY → {ABANDONED, QUARANTINED}` covers rejecting an un-dispatched D).
  `FAILED → DISPATCHED` retries under the **same D, new attempt**.
- Any active → `ABANDONED` (terminal-reject). Any active → `QUARANTINED`.
- **Late events after a terminal** (VERIFIED/ABANDONED) are NOT transition errors: fold
  them as `QUARANTINED` for that D (they may hold useful work).
- **Duplicate `result` (two RETURNED for one d/a)** → both quarantined.
- `QUARANTINED` exits only to `VERIFIED` (accepted) or `ABANDONED` (rejected).

### 4.3 Attempts & superseding
- Replay of the same prompt → same `d`, new `a` (via FAILED→DISPATCHED or a fresh DISPATCHED).
- Changed intent → **new** `d` with `supersedes=D-###`. A late return on a superseded D →
  QUARANTINED.

### 4.4 Parent/child roll-up
- A parent (a `d` that is `child_of` of nobody but is referenced as `child_of` by others)
  MUST NOT be `VERIFIED` while any child is non-terminal (∉ {VERIFIED, ABANDONED}).
- A child entering `FAILED`/`QUARANTINED` while the parent is `VERIFIED` is a `ledger-check`
  error (parent should be reopened to `RETURNED`).

## 5. Validation levels

`ledger-check` reports at two levels; both are checkable and exhaustive over the log:

1. **Grammar (per line):** known `type`; all required keys present; no duplicate keys;
   every value matches the token charset. A failing line is appended to `.pm/quarantine.log`
   with a reason and EXCLUDED from the fold — **never silently dropped**. Count is reported.
2. **Sequence (per fold):** `from == current` for every transition; attempt monotonicity;
   dispatch lifecycle legality (§4.2); parent/child roll-up (§4.4); duplicate-result
   quarantine. Any violation is a non-zero exit with the offending line number(s).

## 6. Example (a clean human-lane round-trip)

```
EVENT schema v=1
EVENT issue_state i=I-001 from=OPEN to=ACTIVE at=2026-07-23T18:00:00Z
EVENT dispatch_new d=D-001 i=I-001 at=2026-07-23T18:01:00Z
EVENT dispatch_state d=D-001 a=A-01 from=READY to=DISPATCHED lane=human at=2026-07-23T18:02:00Z tab=? prompt_sha=ab12cd34
EVENT dispatch_state d=D-001 a=A-01 from=DISPATCHED to=ACKED lane=human at=2026-07-23T18:40:00Z tab=w1.i001
EVENT result d=D-001 a=A-01 status=RETURNED result_sha=ef56ab78 at=2026-07-23T18:41:00Z
EVENT dispatch_state d=D-001 a=A-01 from=RETURNED to=VERIFIED lane=human at=2026-07-23T18:45:00Z
EVENT issue_state i=I-001 from=ACTIVE to=CLOSED at=2026-07-23T18:46:00Z by=D-001
```
Note: `RETURNED` is reached **only** by the `result` event, never by a `dispatch_state`.
`dispatch_state … to=RETURNED` is **not** a legal event — the engine refuses it at write and
quarantines it at fold (see `enforcement.md` §4). The canonical rule is that a `result …
status=RETURNED` is what advances the dispatch to RETURNED; the fold derives the RETURNED
state from that result event.
