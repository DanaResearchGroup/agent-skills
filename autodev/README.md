# autodev — autonomous build loop + automation harness

The `autodev` skill drives a long, autonomous feature build (implement → adversarial Codex
`/spar` at every milestone → verify → checkpoint) and ships the **automation harness** that
keeps such a run alive across the two things that normally kill it:

- **auto-handoff watcher** — past a context threshold, at an idle turn boundary, drives
  `/handoff` → `/compact` → `/rename` → "read the handoff and continue" by sending keys to the
  session's pane (herdr or tmux). A session can also **voluntarily** request this below the
  threshold via `request-handoff.sh` (see below) — e.g. to hand off *before* opening a heavy phase.
- **Phoenix** (session-limit auto-resume) — on a usage/session-limit stop, runs
  `/usage-credits` or waits until past the stated reset time, then sends `continue`.
- **PM-nudger** — in a multi-pane campaign, notices when the PM session has gone quiet *and* its
  whole worker fleet has finished, and nudges the PM to collect and close. Separate installer,
  separate kill switch — see [PM-nudger](#pm-nudger-nudge-a-pm-whose-fleet-has-finished).

It also ships the **cache-warmth badge**, which counts the prompt cache down to expiry in the
herdr *tab label* rather than the status line — see [Cache warmth](#cache-warmth-why-the-tab-label).

Everything is **bundled inside this skill** (`bin/`) and self-locating, so it is reusable on
any machine: copy the skill, run `bin/install.sh`, arm it.

## Layout

```
autodev/
  SKILL.md                     # the skill the model follows
  README.md                    # this file
  bin/
    install.sh                 # wire the hooks/statusLine into ~/.claude/settings.json
    mux-lib.sh                 # multiplexer abstraction (herdr preferred, tmux fallback)
    cc-statusline.sh           # statusLine: writes context % + herdr/tmux pane/tab; renders the badge
    cc-stop-hook.sh            # Stop hook: marks idle, launches the watchers (via $HERE)
    cache-warm-watch.sh        # prompt-cache TTL → countdown in the tab label (`--clear` strips it)
    cc-sessionstart-compact.sh # SessionStart(compact) hook: reload-after-compaction backup
    auto-handoff-watch.sh      # engine: context-threshold (or handoff-request marker) → handoff/compact/reload
    auto-handoff-sweep.sh      # LEVEL trigger: timer-driven; re-arms the engine for parked sessions
    request-handoff.sh         # helper: raise/cancel a voluntary below-threshold handoff-request for this session
    session-resume-watch.sh    # Phoenix engine: usage/session-limit → credits / wait → continue
    fleet-digest.sh            # cron'able: one JSON snapshot of sessions/panes/worktrees/PRs (evidence only)
    pm-nudge-sweep.sh          # LEVEL trigger: PM idle + fleet finished → nudge the PM
    pm-nudge-compose.py        # the nudge's WORDS only: one bare Haiku call, in its own venv
    pm-nudge-requirements.txt  # that venv's single pinned dependency
    pm-nudge-install.sh        # PM-nudger's own timer + venv installer (touches no hooks)
  test/                        # bash tests: sandboxed, never touch your real ~/agents
    ci.sh                      # the repo's CI entrypoint (fixed name); runs every suite below
    lib.sh                     # harness: throwaway AUTODEV_HOME, copied bin/, stubbed multiplexer
    test-mission-bleed.sh      # a session may only ever be pointed at its OWN handoff
    test-parked-session.sh     # the sweeper re-arms a session the Stop hook can no longer reach
    test-abort-recovery.sh     # aborts are counted, retried, then surfaced as STUCK
    test-install-sweeper.sh    # the generated systemd unit (incl. the KillMode=process guard)
    test-cache-warmth.sh       # the cache badge: countdown in the tab, deadline in the status line
    test-fleet-digest.sh       # forced gh-missing / unreadable-root failures: section isolation, not just happy path
    test-pm-nudge.sh           # PM-nudger: classification, firing gates, and the safety ladder
```

**Edge vs. level.** `cc-stop-hook.sh` launches the watcher at a *turn end* — an edge. The
condition the watcher guards ("this session is parked with a full context") is a *level*. A
parked session emits no more edges and its context % never rises, so every declined evaluation
(busy pane, cooldown, aborted cycle) used to be final and the session waited forever.
`auto-handoff-sweep.sh` runs from a systemd user timer (cron fallback) every few minutes and
re-invokes the watcher for any session that still looks like it needs a cycle. It decides
nothing itself — the watcher re-applies every gate. After `MAX_ABORTS` consecutive aborted
cycles it stops retrying and raises `<sid>.stuck`, which the status line shows as
**⚠ AUTO-HANDOFF STUCK**, so a wedged session cannot keep looking healthy.

**Code vs. data.** The scripts live in the skill (version-controlled). Runtime *data* —
state, logs, handoffs, sparring records, autodev progress — lives under **`AUTODEV_HOME`**
(default `~/agents`), never in the repo. Override with the `AUTODEV_HOME` env var.

## Install (any system)

```bash
bash ~/.claude/skills/autodev/bin/install.sh
# or, custom data home / settings path:
AUTODEV_HOME=~/agents CLAUDE_SETTINGS=~/.claude/settings.json bash .../bin/install.sh
```

Requires `jq`. Idempotent (re-running never duplicates entries) and preserves any other hooks
you already have. Takes effect for **new** Claude Code sessions (hooks load at session start).
Must run Claude Code **inside herdr or tmux** for the send-keys automation to work (herdr preferred).

## Control switches (`$AUTODEV_HOME/state/`, default `~/agents/state/`)

| File | Effect |
|------|--------|
| `auto-handoff.armed` | **Arm** — real `send-keys`. Absent ⇒ **dry-run** (logs only). Default: dry-run. |
| `disable-auto-compact` | Global kill switch (beats armed). Badge ⇒ ⛔. |
| `disable-auto-resume` | Phoenix only off. |
| `no-usage-credits` | Phoenix skips the paid `/usage-credits` step; always waits for the free reset. |
| `pm-nudge.armed` / `disable-pm-nudge` | PM-nudger arm / kill switch — see [PM-nudger](#pm-nudger-nudge-a-pm-whose-fleet-has-finished). Independent of the files above. |
| `disable-cache-badge` | Cache-warmth badge off. Honoured at the next poll (≤ `CC_CACHE_NAP_MAX`), and it strips any badge already on a tab on its way out. |

Status-line badge: 🟡 DRY-RUN · 🔴 ARMED · ⛔ OFF · ⏳ AUTO-RESUME @ `<time>` (Phoenix waiting).
Logs: `$AUTODEV_HOME/logs/{auto-handoff,auto-resume}.log`.

## Tunables (top of the engine scripts)

- `auto-handoff-watch.sh`: `THRESHOLD=35`, `COOLDOWN=900`, `WAIT_IDLE/WAIT_COMPACT`, `SETTLE`.
- `session-resume-watch.sh`: `BUFFER_MIN=4` (minutes past reset), `CREDITS_WAIT`, `WAKE`, `MAX_WAIT`.
- `auto-handoff-watch.sh`: `REQUEST_MAX_AGE=3600` — TTL for a `handoff-request` / `compact-request` marker.
- `cache-warm-watch.sh` (env, not constants): `CC_CACHE_TTL=300` (the prompt-cache window),
  `CC_CACHE_WARN=30` (when the countdown appears), `CC_CACHE_MAXLIFE=7200`, `CC_CACHE_NAP_MAX=60`.

## Cache warmth: why the tab label

Claude Code invokes the `statusLine` command **only on conversation updates**. Measured on a live
session: across 120 s of idle it was not invoked once. So the status line is a photograph, and
anything in it that decays with wall-clock time becomes a lie the moment the session goes idle —
a `cache:hot` that stays green for an hour, with the countdown and expiry states unreachable
precisely when they would be useful. The split follows from that:

| Surface | Shows | Why there |
|---|---|---|
| status line (`cc_cache_seg`) | `cache⌛07:06:12` — the wall-clock time the cache lapses | An absolute deadline is still true however stale the render is. Fixed colour, for the same reason. |
| herdr tab label (`cache-warm-watch.sh`) | ` ⌛28s` in the last 30 s, then ` •cold` | herdr repaints its own tab bar while Claude Code is idle, so it can actually count down. |

The watcher is launched per turn by the Stop hook, exits as soon as a newer transcript entry shows
the cache was refreshed, and never memorises a label: it reads the live one and appends or strips
only its own suffix, so renaming a tab mid-countdown is safe and a killed watcher leaves nothing
to restore. The status line clears a stale badge on its first render of a new turn (`--clear`),
since a render happening at all is proof the cache was just refreshed.

## Voluntary handoff-request (hand off below threshold)

`THRESHOLD` is reactive: the watcher fires only *after* context crosses it. But a session
quiesced at a clean phase boundary sometimes *knows* the next phase is heavy and will blow past
the threshold *inside* the phase — where there is no idle window for the watcher to use. It can
ask to hand off *before* opening that phase:

```bash
bash ~/.claude/skills/autodev/bin/request-handoff.sh            # raise for THIS session
bash ~/.claude/skills/autodev/bin/request-handoff.sh --cancel   # withdraw it
bash ~/.claude/skills/autodev/bin/request-handoff.sh <sid>      # operate on an explicit session id
```

This drops an empty `~/agents/state/<sid>.handoff-request` marker — a **second trigger path**
into the same watcher. On the next idle Stop the watcher runs the normal
`/handoff` → `/compact` → reload **even below `THRESHOLD`**. The marker bypasses *only* the
threshold gate; every other safety gate (idle, pane-live, pane-ownership, cooldown, cycle-lock)
still applies, and it is consumed the moment the watcher commits, so it fires **once**. A marker
older than `REQUEST_MAX_AGE` (default 1h) is treated as stale, ignored, and removed, so a
forgotten request can't fire arbitrarily later.

### Compact-request (handoff already written — just compact + reload)

`--compact-only` is a **third trigger path** for the case where a handoff is *already written*
(you ran `/handoff` yourself, or the `handoff` skill did) and all that's left is the compact +
reload. The reactive `THRESHOLD` gate never fires below 35%, and a plain `handoff-request` would
make the watcher write a *second, redundant* handoff — so neither fits.

```bash
bash ~/.claude/skills/autodev/bin/request-handoff.sh --compact-only            # raise
bash ~/.claude/skills/autodev/bin/request-handoff.sh --compact-only --cancel   # withdraw
```

This drops `~/agents/state/<sid>.compact-request`. The watcher honors it as a **compact-only**
cycle: it **skips `/handoff`** and goes straight to `/compact` → reload (same safety gates, same
TTL, consumed once). The `handoff` skill files this automatically after every `/handoff`, which
is what makes a below-threshold handoff actually compact instead of silently stalling. It
**defers** (no marker) when the watcher is already mid-cycle, so a watcher-driven `/handoff`
never double-fires a compact.

`--compact-only --handoff <path>` records the **per-session** reload pointer
`~/agents/handoffs/.latest.<sid>`, naming the file the session just wrote. It does so **before**
the deferral above, and therefore records it even when no marker is filed. That ordering is
load-bearing rather than tidy: on the threshold path the watcher sends the `/handoff` itself, so
its cycle lock is *always* live while the handoff skill runs, and the deferral is the common case,
not an edge case. A pointer written after the check would never be written on the harness's main
route — the reload would fall back to the mtime bridge below, which a concurrent writer can
defeat. Recording which handoff *we* wrote is bookkeeping about ourselves: idempotent, racing
nothing, and correct whether or not a cycle gets filed.

This is the only pointer that is ever read back. `~/agents/handoffs/.latest` is shared,
machine-wide and last-writer-wins: on a box running many concurrent sessions it names whoever
handed off most recently. The watcher and the post-compaction SessionStart hook therefore read
**only** `.latest.<sid>` and **never fall back** to the shared file (nor to "the newest handoff
in the directory"). A missing pointer **fails closed** — the session is told to re-orient from
its own transcript. Resuming nothing is recoverable; silently resuming another session's mission
while the pane still reads healthy is not.

Always pass `--handoff`. Without it the helper can only *copy* the shared `.latest`, which is a
race, not a safeguard: another session can clobber it between the handoff being written and the
copy, permanently caching their mission as ours. That legacy path is kept only for older handoff
skills and logs a `WARN`. In the threshold path the watcher accepts the shared `.latest` solely
when the file it names was written during the `/handoff` turn the watcher itself just drove
(mtime proof) — the one moment it is provably ours.

Resolution of "this session" is `explicit arg` → `$CLAUDE_CODE_SESSION_ID` → the reverse
pane-owner file, and it **hard-fails if the env id and the pane owner disagree** rather than
risk targeting a different live session (herdr recycles pane ids). Call it only from the
**mother** session — a subagent resolves to its own child id, not the driving session.

## fleet-digest: one JSON snapshot instead of 20+ Bash calls

`fleet-digest.sh` is a read-only, no-judgment **collector**, not a decision-maker: it snapshots
fleet state — recent Claude Code sessions (`*.ctx`), herdr panes, git worktrees under one or
more roots, and open GitHub PRs per remote — into one atomically-written JSON file. Nothing in
it fetches, writes, or acts; it exists so a PM/fleet session (or any future consumer) can read
one small file instead of firing 20+ Bash calls whose output then sits in its prompt prefix on
every later turn. No LLM involved.

```bash
bash ~/.claude/skills/autodev/bin/fleet-digest.sh                      # writes $AUTODEV_HOME/state/fleet-digest.json (+ a companion summary, see below)
bash .../fleet-digest.sh --out /path/to/digest.json --root ~/Code --root ~/other-code
bash .../fleet-digest.sh --session-max-age 3600 --timeout 45           # tune windows
```

**Output contract** (`schema_version: 1`): a top-level `generated_at`/`generated_at_iso`,
`duration_ms`, `host`, and four sections — `sessions`, `panes`, `worktrees`, `prs`. Every
section independently carries `ok` (bool), `error` (string or `null`), and `collected_at`, so a
consumer can tell **"empty" apart from "failed"** — an empty `worktrees` array with `ok:true`
means no repos were found; `ok:false` means the walk itself broke, and any array present alongside
it is a **partial, best-effort result** (e.g. worktrees from every root except the one that
failed), never a silent empty-vs-failure conflation. Sections fail independently: a missing `gh`
only downs `prs`; an unreadable root only downs `worktrees`; `sessions` and `panes` are unaffected
either way. `ok` and `error` are not strictly coupled: `prs` can be `ok:true` with a non-null
`error` when PR listing itself succeeded but a secondary step degraded (see PR labelling below) —
`ok:false` is reserved for "the section's actual job broke." The digest is always written, even
if every section failed, via an atomic write-to-temp-then-`mv` in the output directory.

**PR authorship is labelled, never dropped.** Under a broad `--root` most PRs found belong to
upstream repos you don't own (clones of e.g. googletest, Catch2) — real signal, not something to
filter out, since dropping data reintroduces the exact "not collected" vs. "not present" ambiguity
the ok/error contract exists to prevent. Instead every PR carries `author_login` and `is_mine`
(`true`/`false`), compared against the authenticated `gh` user — resolved **once per run**
(`gh api user -q .login`, not once per PR) and exposed at `prs.my_login`. If that resolution
fails, `prs.my_login` is `null`, every PR's `is_mine` is `null` (never `false` — `false` would
assert "definitely not mine" about data that was never actually checked), and `prs.error` says so
even though `prs.ok` stays `true` (PR listing itself still worked).

**The companion summary is what a session should read by default.** The full digest runs
~250 KB (~64k tokens) on a machine with a few hundred worktrees and remotes — reading the whole
thing on every turn defeats the point of collecting it out-of-band in the first place, costing
more prefix than the 20+ Bash calls it replaces. `fleet-digest.sh` also writes a second file,
`--summary-out` (default: `--out` with `.json` replaced by `-summary.json`, e.g.
`fleet-digest-summary.json`), with the same atomic-write discipline, containing only:
per-section counts, a `failed_sources` list (section + source + error, so a consumer knows what
to distrust without re-deriving it), worktrees that are dirty/ahead/behind (not all of them), and
PRs where `is_mine:true` (not all of them). Measured on this machine the summary is ~50 KB against
the full digest's ~320 KB — an 84% cut, but not the "few KB" the design aimed at, because the
signal itself is genuinely that big: ~100 of ~375 worktrees really are dirty or diverged, and ~29
open PRs really are yours. That is worth knowing before you plan around this file: at ~13k tokens
the summary is cheap to `jq` a projection out of and still expensive to read whole, so **project
what you need rather than reading either file end to end** — `jq '.prs.remotes[].prs[]'`,
`jq '.worktrees.entries[] | select(.dirty)'`, and so on. **Read the summary by default; reach
for the full `--out` digest only when the summary's counts say there's more to look at than the
summary itself carries** (e.g. `worktrees.count` is much larger than
`worktrees.dirty_or_ahead_behind_count`, and you need every worktree's path, not just the dirty
ones). A summary build/write failure is logged to stderr as a warning but never fails the run or
rolls back the full digest, which by that point has already been written and remains the
authoritative artifact.

**Staleness caveat.** The collector never runs `git fetch` — `worktrees`' ahead/behind counts and
`prs`' open-PR lists reflect whatever the last fetch (by you, or anything else) already pulled
down, not live upstream state. Treat the digest as a cache of local knowledge, not a live query.

**Scheduling.** Not wired into `install.sh` (it's a standalone artifact, not a hook/watcher pair);
run it from cron or a systemd user timer the same way `auto-handoff-sweep.sh` is scheduled (see
`bin/install.sh` for the timer-with-cron-fallback pattern this repo already uses):

```
*/15 * * * * bash ~/.claude/skills/autodev/bin/fleet-digest.sh >>~/agents/logs/fleet-digest.log 2>&1
```

Bounded runtime (parallelized per-worktree/per-remote collection; ~25s observed against ~370
worktrees and ~57 remotes on the reference machine) makes a 15-minute cadence comfortable; tune
`--timeout` down if a section is timing out rather than genuinely erroring, or the interval down
if the fleet is much smaller.
## PM-nudger: nudge a PM whose fleet has finished

A herdr campaign runs one PM (project-manager) session plus N worker sessions, one pane each.
When the last worker finishes, nothing tells the PM: the workers' completion produces no event
inside the PM's session, so no Stop hook fires there and the PM sits idle indefinitely.
`pm-nudge-sweep.sh` supplies the missing signal.

**Same edge-vs-level lesson as `auto-handoff-sweep.sh`.** "PM idle AND every worker idle/done/gone"
is a *level*. An idle PM emits no further edges, so only a clock can ever notice it — which is why
this is a timer, never a hook.

**Detection is deterministic; the model only writes prose.** Whether to type into a live session
is a safety decision, and a safety decision made by a sampled model has a failure rate. The
sweeper decides entirely from `herdr workspace list` / `herdr pane list` JSON and file mtimes, with
no LLM in the path. Only *after* it has decided does `pm-nudge-compose.py` ask Haiku for the words,
and if that call fails, times out, or returns junk, the nudge fires anyway with the fixed baseline
**"All your sessions are done, collect and close as needed. What's next?"**. Model down must not
mean campaign stalled.

### Classification

| | Rule | Env override |
|---|---|---|
| PM pane | `cwd` basename matches `-pm[0-9]*$` (case-insensitive) **and** the label is not ticket-shaped | `PM_NUDGE_PM_RE` |
| worker | ticket-shaped label `^i[0-9]+-.*-D\S*A[0-9]+` | `PM_NUDGE_WORKER_RE` |
| campaign | a workspace with ≥ 1 surviving PM pane | — |

The worker regex **reclassifies**: a worker started inside the PM's own checkout has a PM-shaped
cwd, so cwd alone would name it the PM and hand the nudge to a busy worker. The ticket label wins.
Both regexes are inferred from observed naming, not guaranteed by herdr — hence the overrides.

For the *quiet* test, every non-PM pane in a campaign workspace counts as a worker, including
unlabelled ones. That is wider than "matches the worker regex" on purpose: an unlabelled busy pane
is still somebody's live work, and waiting costs one timer tick while typing over it does not.

### Firing rules

Fires only when the PM is `idle` or `done`, every other pane in its workspace is `idle`/`done`/gone,
and that has held continuously for `PM_NUDGE_DEBOUNCE` (default 300 s). It **never** fires while any
pane in the workspace is `blocked` — and a blocked pane *resets* the debounce window, so a workspace
that passed through a block earns its quiet period again from zero. `PM_NUDGE_COOLDOWN` (default
7200 s) stops an idle PM being re-nudged every tick.

Two things worth stating outright rather than leaving to be discovered:

- **`done` is a real herdr `agent_status`** alongside `idle`/`working`/`blocked`/`unknown`, and it
  is treated exactly like `idle` here: finished, not busy, not waiting on a human. Upstream herdr
  docs omit it; `mux-lib.sh` has always enumerated it. `unknown` is *not* quiet — it counts as busy.
- **A PM workspace with zero workers fires.** "Every worker is idle/done/gone" is vacuously true
  when the workers are gone, and a lone PM whose fleet finished and whose panes were then closed is
  the commonest shape of the exact situation this daemon exists for. Suppressing it would gut the
  feature, so the log says `(no worker panes present: vacuously quiet)` when this is why it fired.

### Safety ladder

| Mode | What it does |
|---|---|
| *(default)* | Dry run: decide and log, touch nothing. |
| `--report` | Dry run plus a per-workspace classification table on stdout. Cannot stage; `--report` forces dry mode. |
| `--stage-only` | `herdr pane send-text` — the text lands in the PM's input line, **unsubmitted**. |
| `--send` | Stage, then `send-keys Enter`. Requires `$STATE/pm-nudge.armed`; without it, degrades to a dry run and logs `NOT ARMED`. |

Before acting, `--send`/`--stage-only` re-read the pane's status **live** (the list snapshot can be
tens of seconds stale by the time the composer returns) and inspect the visible buffer. The buffer
check is three-valued, which is the whole point: *clear* → Enter is allowed; *menu detected* → stage
nothing at all (send-text into an open permission dialog types into that dialog's filter box);
*inconclusive*, because herdr would not answer → stage, but **never** Enter. A two-valued check has
to fold "inconclusive" into one of the others, and both choices are wrong.

Newlines are stripped from the nudge text, in the composer and again in the shell. An embedded
newline in a `send-text` payload submits it — which would silently turn `--stage-only` into a send.

### The composer

`pm-nudge-compose.py` reads a facts JSON on stdin, prints one sentence on stdout, and exits
non-zero on *any* problem so the sweeper falls back to the baseline. It is a standalone process,
not a Claude Code subagent turn: an in-session turn pays a 100–400 k-token prefix rewrite before it
thinks at all (~$0.169/call measured here) against ~$0.0005 for a bare Haiku call. Model id is the
**bare, undated** `claude-haiku-4-5` at $1.00 / $5.00 per 1 M input / output tokens.

`--dry-prompt` renders the exact prompt without a key or a token, so it can be reviewed and diffed.

Facts fed to it: the campaign label, the PM's working directory and how long it has been quiet, the
labels of workers still present, the labels of workers whose panes have closed *since the quiet
window opened* (tracked in `pm-nudge/<ws>.seen`, so "all five finished" stays sayable after the
panes go), and — only if `~/agents/state/fleet-digest.json` exists, is fresh, and is small —
whatever that file holds. That last one is opportunistic: it does not exist on this machine, and
nothing degrades when it is absent.

### Install

```bash
bash ~/.claude/skills/autodev/bin/pm-nudge-install.sh
bash ~/.claude/skills/autodev/bin/pm-nudge-install.sh --no-venv   # timer only
AUTODEV_HOME=~/agents PM_NUDGE_SWEEP_EVERY=5min bash .../pm-nudge-install.sh
```

Deliberately **separate from `install.sh`**, which edits `settings.json` and owns three hooks. This
daemon touches no hooks at all — it is a timer and a venv — and folding it in would put an optional,
network-touching, API-key-using feature behind the switch that turns on the core harness.

It writes a systemd user timer (`pm-nudge-sweep.timer`, `OnBootSec=3min`, `OnUnitActiveSec=5min`)
with `KillMode=process` and a `TimeoutStartSec` backstop, falling back to a tagged cron line.
`ExecStart` is `pm-nudge-sweep.sh --send`, which is the *safe* choice and not the bold one: without
the armed file `--send` is inert, whereas `--stage-only` would write into panes from the moment the
timer started. **Installing arms nothing.**

The venv lands at `$AUTODEV_HOME/venv/pm-nudge` — under the runtime home, not in the repo, per the
code-vs-data rule above — and the sweeper invokes `$PM_NUDGE_VENV/bin/python` by absolute path,
never `python3`. Two traps the installer works around, both live on this machine:

- `python3` first on `$PATH` is anaconda, whose base env cannot import the SDK at all
  (`cannot import name 'validate_core_schema' from 'pydantic_core'`) — but a venv built *from* it
  gets a clean site-packages and works. `/usr/bin/python3` imports the SDK fine yet cannot build a
  usable venv, because Debian ships `ensurepip` in a separate `python3-venv` package. The
  interpreter probe therefore requires **`venv`, `ssl` *and* `ensurepip`** and proves each candidate
  before use.
- A `PYTHONPATH` exporting six research checkouts puts them *ahead* of the venv's site-packages, so
  a venv built precisely to be isolated is not. Every composer call runs `python -E -s`
  (`PM_NUDGE_PY_ARGS`), and the installer strips `PYTHONPATH`/`PYTHONHOME` while building.

### Control switches and tunables

| File under `$AUTODEV_HOME/state/` | Effect |
|---|---|
| `pm-nudge.armed` | Arm `--send` (stage **and** Enter). Absent ⇒ `--send` is a dry run. |
| `disable-pm-nudge` | Global kill switch. Beats armed, beats every mode. |
| `pm-nudge/<ws>.since` | Debounce marker: when the quiet window opened, plus the PM pane id it was earned against (herdr recycles pane ids). |
| `pm-nudge/<ws>.seen` | Workers observed during the open window, so departed ones stay nameable. |
| `pm-nudge/<ws>.cooldown` | mtime of the last actual nudge. |
| `pm-nudge/<ws>.dry-noted` | Rate-limits the dry-run "would have fired" notice to one per cooldown. Nothing consumes dry-run state, so an unarmed daemon would otherwise log the same line 288×/day forever. Deliberately a *separate* file: a dry run must never be able to suppress the first real nudge after arming. |

Env tunables: `PM_NUDGE_DEBOUNCE=300`, `PM_NUDGE_COOLDOWN=7200`, `PM_NUDGE_MAX_CHARS=240`,
`PM_NUDGE_READ_LINES=40`, `PM_NUDGE_COMPOSE_TIMEOUT=30`, `PM_NUDGE_PM_RE`, `PM_NUDGE_WORKER_RE`,
`PM_NUDGE_HERDR`, `PM_NUDGE_VENV`, `PM_NUDGE_PY`, `PM_NUDGE_PY_ARGS`, `PM_NUDGE_COMPOSER`,
`PM_NUDGE_DIGEST`, `PM_NUDGE_DIGEST_MAX_AGE`. Log: `$AUTODEV_HOME/logs/pm-nudge.log`.

### What the rule actually selects here

`pm-nudge-sweep.sh --report`, run read-only against live herdr on 2026.08.28 23.41:

```
WS   LABEL      PM-PANE   PM-ST    VERDICT
w1   CKMG       w1:p7G    blocked  HOLD: blocked pane(s) w1:p7G
w7   main       -         -        excluded: no pane cwd matches the PM regex
w8   ARC        -         -        excluded: no pane cwd matches the PM regex
w9   Papers     -         -        excluded: no pane cwd matches the PM regex
wB   T3         wB:p21    blocked  HOLD: blocked pane(s) wB:p21
wE   House      -         -        excluded: no pane cwd matches the PM regex
wF   plasma     wF:p1R    done     HOLD: blocked pane(s) wF:p50
wG   Gracie     wG:p4F    idle     FIRE: 1 worker all idle/done, quiet 464s >= 300s
wH   SCM        wH:p1B    done     FIRE: 1 worker all idle/done, quiet 464s >= 300s
wJ   NS         wJ:p2Z    idle     FIRE: 0 workers (vacuously quiet), quiet 464s >= 300s
wP   Carmel     wP:p1     working  HOLD: PM is working
```

Seven campaigns (`w1 wB wF wG wH wJ wP`); Alon's four ordinary working spaces (`w7` main, `w8` ARC,
`w9` Papers, `wE` House) are correctly *not* campaigns — none of their pane cwds is PM-shaped, even
though several of their panes carry ticket-shaped labels. `wH` is the reclassification case: both
its panes sit in `.../scm-pm2`, and the ticket label on `wH:p28` is what makes `wH:p1B` the PM.
`wJ` is the vacuous case. Statuses move minute to minute; re-run `--report` for the current picture.

## Known limits (the fragile, unsupported link)

- Driving CC by sending keys to its pane (herdr or tmux) is **not officially supported**; mid-typing collisions are
  possible. Both watchers gate on a real idle check and **defer** while the pane is busy
  (long turn, `/compact`, or background agents) — CC queues input while busy, so a
  perpetually-busy run may have no safe injection window until it next goes idle.
- `/compact` cannot be triggered by the model or a hook — only the user or the external
  watcher (via herdr or tmux). CC does not auto-continue after `/compact`; the watcher's explicit
  continue-send (and the `SessionStart(compact)` hook) is what resumes.
- **PM-nudger's pane-buffer check is a heuristic over rendered text**, not a supported API: it
  greps the visible buffer for permission-prompt and menu markers. It is deliberately biased —
  an unreadable or ambiguous buffer degrades to stage-only rather than pressing Enter — but a
  novel dialog it has never seen could still read as "clear". The classification regexes are
  likewise inferred from observed campaign naming, not guaranteed by herdr; both are
  env-overridable for exactly that reason.
- **Phoenix unverified-live premises** (can't be probed without a real limit; the
  parse→wait→continue path is dry-run-verified): (a) that the `Stop` hook fires when a turn
  is cut off by the limit; (b) exactly what `/usage-credits` does in the TUI — if it opens a
  dialog Phoenix can't navigate, it correctly falls through to wait-for-reset.

## Uninstall

Restore the pre-install backup the installer wrote next to your settings
(`settings.json.bak.autodev.<epoch>`), or remove the three entries whose commands point at
`.../autodev/bin/` from `hooks.Stop`, `hooks.SessionStart`, and `statusLine`.
