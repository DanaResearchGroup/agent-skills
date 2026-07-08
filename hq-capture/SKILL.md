---
name: hq-capture
description: Use when Alon wants to record what happened in a work session into HQ — "capture this to HQ", "update HQ with this", "log this session to HQ", "put this in my HQ". Runs from ANY CC session (usually outside HQ — a repo or project session) to push the session's decisions, next-actions, blockers, and pointers into the owning HQ node.
---

# hq-capture — push a session's outcomes into HQ

Turn what just happened in a working session into durable HQ state: update the **owning node's
next-actions, status, blockers, and log** so the next HQ session — and the Saturday `hq-brief` —
see it. Alon invokes this from any session, usually **outside** HQ (a repo/project session).
**HQ's `CLAUDE.md` is the source of truth** for the node schema, the traffic-light rule,
pointers-not-copies, and governance — read it; this skill only orchestrates and **must not
duplicate its depth.** Vault: `~/Dropbox/Apps/remotely-save/Vault/` (HQ at `.../HQ/`).

## Iron rule
**Write ONLY inside `HQ/`.** The session's real artifacts (code, PR, commit, files) stay where they
are — HQ *points* to them, never copies them in. Don't restate an analysis that lives in the PR;
link the PR and capture the **decision**.

## Flow
1. **Extract the outcomes worth keeping** — decisions, next-actions, new blockers, status changes,
   and any durable pointer (PR, commit, file, wiki) the node should hold. Drop the play-by-play.
2. **Locate the owning node.** Search `HQ/` for the node that owns this work — match by repo
   (`repos:` / `local:`), topic, or an existing pointer (an ARC session → `HQ/Developer/ARC/repo.md`).
   A session may touch two nodes (a repo node **and** the paper it feeds) — capture each where it
   belongs and cross-link; don't paste the same prose into both.
3. **Route — ask when it isn't obvious.** Owning node clear → proceed. **If routing is ambiguous, or
   you'd have to CREATE a node, or choose a hat — STOP and ask Alon** (propose your best guess). Never
   guess a hat or spawn a node silently: it's his knowledge, and a wrong home is worse than a question.
4. **Write the capture** (see contract). Bump `updated:` (`DD/MM/YYYY`). Leave `Status.md` and
   `Dashboard.md` alone — `hq-update` regenerates those; hand-edits get clobbered.
5. **Summarize** to Alon: which node(s), what changed, what you left for him to decide.

## What goes where — do NOT duplicate
- **Next action** — the crisp *current* action + live state, verb-first, **one line**. This is the
  point of the node. Update the existing item **in place**; never stack a second copy of it.
- **Log** — one dated (`DD/MM/YYYY`), append-only entry carrying the **narrative** (decision + what
  happened), terse, PRs live-linked. The story lives HERE — not also in the next action.
- **Pointers** (`repos:`/`local:`/`wiki:`/`links:`) — add one only if the session produced a durable
  artifact the node should reach.
- **Frontmatter state** (`light`/`blocked`/`status`/`importance`) — touch only if the *whole node's*
  state changed, and say so. A single stuck PR is a per-item `⛔` on its next-action, **not** a
  node-level `blocked` flip — the node's light stays honest (defer to CLAUDE.md).

## PR references
Always live links: `[owner/repo#NNN](https://github.com/owner/repo/pull/NNN)`, matching the rest of HQ.

## What good looks like
> ARC #909 session → `Developer/ARC/repo.md`: the #909 next-action updated in place to its current
> state (one line, live-linked); ONE 08/07 Log entry with the decision + why (narrative only here,
> not echoed in the next-action); per-item `⛔`, no node-level flip. A cross-cutting "reuse the test
> helper for #887" noted once on the #887 item. `updated:` bumped; Status/Dashboard untouched. The
> vague "follow up with the consulting client" had no node and an unclear hat → asked Alon, didn't
> invent one.
