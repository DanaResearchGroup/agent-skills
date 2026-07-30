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
    cc-statusline.sh           # statusLine: writes context % + herdr/tmux pane; renders the badge
    cc-stop-hook.sh            # Stop hook: marks idle, launches both watchers (via $HERE)
    cc-sessionstart-compact.sh # SessionStart(compact) hook: reload-after-compaction backup
    auto-handoff-watch.sh      # engine: context-threshold (or handoff-request marker) → handoff/compact/reload
    auto-handoff-sweep.sh      # LEVEL trigger: timer-driven; re-arms the engine for parked sessions
    request-handoff.sh         # helper: raise/cancel a voluntary below-threshold handoff-request for this session
    session-resume-watch.sh    # Phoenix engine: usage/session-limit → credits / wait → continue
  tests/                       # bash tests: run tests/run-all.sh (uses a sandbox, never your real ~/agents)
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

Status-line badge: 🟡 DRY-RUN · 🔴 ARMED · ⛔ OFF · ⏳ AUTO-RESUME @ `<time>` (Phoenix waiting).
Logs: `$AUTODEV_HOME/logs/{auto-handoff,auto-resume}.log`.

## Tunables (top of the engine scripts)

- `auto-handoff-watch.sh`: `THRESHOLD=30`, `COOLDOWN=900`, `WAIT_IDLE/WAIT_COMPACT`, `SETTLE`.
- `session-resume-watch.sh`: `BUFFER_MIN=4` (minutes past reset), `CREDITS_WAIT`, `WAKE`, `MAX_WAIT`.
- `auto-handoff-watch.sh`: `REQUEST_MAX_AGE=3600` — TTL for a `handoff-request` / `compact-request` marker.

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
reload. The reactive `THRESHOLD` gate never fires below 30%, and a plain `handoff-request` would
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
`~/agents/handoffs/.latest.<sid>`, naming the file the session just wrote.

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

## Known limits (the fragile, unsupported link)

- Driving CC by sending keys to its pane (herdr or tmux) is **not officially supported**; mid-typing collisions are
  possible. Both watchers gate on a real idle check and **defer** while the pane is busy
  (long turn, `/compact`, or background agents) — CC queues input while busy, so a
  perpetually-busy run may have no safe injection window until it next goes idle.
- `/compact` cannot be triggered by the model or a hook — only the user or the external
  watcher (via herdr or tmux). CC does not auto-continue after `/compact`; the watcher's explicit
  continue-send (and the `SessionStart(compact)` hook) is what resumes.
- **Phoenix unverified-live premises** (can't be probed without a real limit; the
  parse→wait→continue path is dry-run-verified): (a) that the `Stop` hook fires when a turn
  is cut off by the limit; (b) exactly what `/usage-credits` does in the TUI — if it opens a
  dialog Phoenix can't navigate, it correctly falls through to wait-for-reset.

## Uninstall

Restore the pre-install backup the installer wrote next to your settings
(`settings.json.bak.autodev.<epoch>`), or remove the three entries whose commands point at
`.../autodev/bin/` from `hooks.Stop`, `hooks.SessionStart`, and `statusLine`.
