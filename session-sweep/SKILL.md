---
name: session-sweep
description: Sweep and triage the overseer/PM session's worker fleet. Use when the PM needs to reconcile its sessions — scan every session relevant to THIS project, classify each RUN / CLOSE / MESSAGE / ESCALATE against ground truth (never stale pane status), and auto-write-and-send any message a worker needs. Triggers — user asks for the status of all sessions, which sessions need attention or a message, "sweep/muster the sessions", or the PM reconciling after a watcher wake.
---

# session-sweep

**Sweep** every session relevant to this project and **triage** each into one verdict, acting only where the PM's own lane lets it. The four verdicts:

- **RUN** — actively doing real work; healthy. Leave it; report it.
- **CLOSE** — work done and committed, or stood down; nothing live owns it. Recommend closure (don't kill a pane unilaterally — that's the user's call).
- **MESSAGE** — blocked or drifting on something the PM can resolve **within its own authority**. Write the directive and **send it now**.
- **ESCALATE** — blocked on a decision only the user can make (ratification, a fork, an irreversible or cross-repo action). Surface it to the user; never send it into the worker.

MESSAGE vs ESCALATE is the **lane test**: can the PM resolve this within its own strategic authority? → MESSAGE. Only the user can? → ESCALATE. Invoking this skill authorizes the auto-send for MESSAGE; a directive that would trigger an irreversible or cross-repo action is ESCALATE regardless.

## 1. Scope to relevant sessions

`herdr pane list` shows every pane on the machine. Keep only those relevant to **this** project — cwd inside the project tree, or owning a run/ticket in the PM ledger — and drop the rest (unrelated repos, other projects' agents).

**Completion:** a roster mapping each relevant session → pane id → what it owns (which run or ticket). Unrelated panes explicitly excluded, not silently forgotten.

## 2. Reconcile each against ground truth

Pane status (`done` / `idle` / `working`) **lags reality** — a `done` pane routinely still owns a live run or sits blocked awaiting a decision. Reconcile before you classify; this is the step the whole skill turns on.

For each session: read the recent pane content (`herdr pane read <pane> --source recent-unwrapped --lines 60 --format text` — unwrapped joins soft-wrapped lines, so a terminal marker greps cleanly) **and** verify the underlying work against its authoritative live artifact —
- a **run**: the live process (`ps` / `kill -0` on the *true* parent PID) and the live log's terminal marker (completed / crash-signature / still-writing);
- a **ticket**: the committed deliverable.

Trust the live artifact over any sibling — a stale `*_killed_*` log or an old status line will lie to you.

**Completion:** every session carries a reconciled real state derived from ground truth, none left as a bare pane-status label.

## 3. Triage into a verdict

Assign each session exactly one verdict — RUN / CLOSE / MESSAGE / ESCALATE — each with a one-line reason grounded in step 2's real state.

**Completion:** every relevant session carries a verdict + reason; none left unknown.

## 4. Act — send the messages

Only **MESSAGE** acts automatically. For each:
- Write the directive so the worker can act on it alone. This is a direct message to a running session, so it **may name internal ticket/PM ids freely** (that is the exception to dispatch-prompt self-containment).
- Send it: `herdr pane run <pane> "<directive>"` — this sends the text and Enter together, so there's no `send-text`/`send-keys` timing to coordinate.
- Re-read the pane to confirm it landed (the selection registered / the worker resumed).

RUN, CLOSE, and ESCALATE are **reported, not actioned**: leave RUN alone, recommend CLOSE, and frame ESCALATE for the user.

**Completion:** every MESSAGE sent and confirmed-landed; every ESCALATE framed; nothing auto-sent that belonged in ESCALATE.

## 5. Report and record

Give the user one compact table — session → verdict → reason → action taken — so the whole fleet reads at a glance. Record any consequential verdict or sent directive in the PM ledger.

**Completion:** the table is delivered and the ledger reflects anything that changed a worker's course.
