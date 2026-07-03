# autodev — autonomous build loop + automation harness

The `autodev` skill drives a long, autonomous feature build (implement → adversarial Codex
`/spar` at every milestone → verify → checkpoint) and ships the **automation harness** that
keeps such a run alive across the two things that normally kill it:

- **auto-handoff watcher** — past a context threshold, at an idle turn boundary, drives
  `/handoff` → `/compact` → `/rename` → "read the handoff and continue" via `tmux send-keys`.
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
    cc-statusline.sh           # statusLine: writes context % + tmux pane; renders the badge
    cc-stop-hook.sh            # Stop hook: marks idle, launches both watchers (via $HERE)
    cc-sessionstart-compact.sh # SessionStart(compact) hook: reload-after-compaction backup
    auto-handoff-watch.sh      # engine: context-threshold → handoff/compact/reload
    session-resume-watch.sh    # Phoenix engine: usage/session-limit → credits / wait → continue
```

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
Must run Claude Code **inside tmux** for the send-keys automation to work.

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

- `auto-handoff-watch.sh`: `THRESHOLD=25`, `COOLDOWN=900`, `WAIT_IDLE/WAIT_COMPACT`, `SETTLE`.
- `session-resume-watch.sh`: `BUFFER_MIN=4` (minutes past reset), `CREDITS_WAIT`, `WAKE`, `MAX_WAIT`.

## Known limits (the fragile, unsupported link)

- Driving CC via `tmux send-keys` is **not officially supported**; mid-typing collisions are
  possible. Both watchers gate on a real idle check and **defer** while the pane is busy
  (long turn, `/compact`, or background agents) — CC queues input while busy, so a
  perpetually-busy run may have no safe injection window until it next goes idle.
- `/compact` cannot be triggered by the model or a hook — only the user or the external
  watcher (via tmux). CC does not auto-continue after `/compact`; the watcher's explicit
  continue-send (and the `SessionStart(compact)` hook) is what resumes.
- **Phoenix unverified-live premises** (can't be probed without a real limit; the
  parse→wait→continue path is dry-run-verified): (a) that the `Stop` hook fires when a turn
  is cut off by the limit; (b) exactly what `/usage-credits` does in the TUI — if it opens a
  dialog Phoenix can't navigate, it correctly falls through to wait-for-reset.

## Uninstall

Restore the pre-install backup the installer wrote next to your settings
(`settings.json.bak.autodev.<epoch>`), or remove the three entries whose commands point at
`.../autodev/bin/` from `hooks.Stop`, `hooks.SessionStart`, and `statusLine`.
