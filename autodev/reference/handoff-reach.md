# Handoff reachability

## Plan and background sessions

A daemon-hosted Claude Code background session inherits the pane environment of
its spawning terminal. A later `claude --resume` attachment can use a different,
unlabelled pane; after detachment there may be no hosting pane at all while the
worker continues writing context readings. An inherited `HERDR_PANE_ID` cannot
prove where that worker is currently attached.

The implementation follows this order:

1. Compare herdr's session label with reverse-owner registration and context
   freshness. A different reverse owner or fresher context for the labelled
   session proves reuse; the label alone does not. Unknown ownership permits no
   herdr input. All watcher gates share `mux_pane_owner`.
2. If a registered pane is gone, accept a unique exact session match from
   `pane list`, then verify its live ownership. Keep that binding across later
   renders carrying a stale environment id. An unlabelled attachment or no
   attachment remains unreachable, rather than guessing from a working directory.
3. Record `<sid>.unreachable` and its reason once per episode. Show
   `AUTO-HANDOFF: UNREACHABLE`; clear it after verified recovery. Refusal of
   unknown ownership retains pending retry state.
4. At 35% or above, the Claude Stop hook is the primary route when driving is
   impossible: ask the session to run `/handoff` and file its own compact-only
   request. For an owned but continuously busy pane, use this fallback after
   three consecutive failed idle windows. Ordinary fallback notices have a
   900-second cooldown. Arming, the kill switch, and active cycle locks apply.
5. Once an unsatisfied handoff/compact request is filed, the fallback reason is exactly
   `type /compact`, addressed to the human. Each request gets that notice once;
   removing a superseding request does not re-arm an earlier notice. A Stop
   with `stop_hook_active: true` succeeds silently and consumes no notice.

The fallback preserves the handoff even when a detached worker cannot compact
itself. A human must attach and type `/compact` in that case. The watcher keeps
its existing thresholds and compact/reload sequence; it never types into a busy,
unreachable, or unproved pane to force progress.

## Probes (2026-10-27)

The baseline fake-herdr fixture labelled a pane `sess-a`, while its reverse-owner
file named `sess-b` and `sess-b.ctx` was newer. The unchanged watcher logged
`SKIP ... reused by session sess-a` and deleted the binding, without driving it.
The regression now completes a fake `/handoff` → `/compact` → reload cycle.

Real `herdr --help` and `herdr pane --help` succeeded. The latter advertises
`pane process-info`, but does not document a process-to-pane mapping. Standalone
read-only `pane list` and `pane get` calls both returned `PermissionDenied`;
automatic approval review rejected escalated access under the execution policy.
**No reliable pid/tty/terminal mapping was established.** Recovery therefore uses
the existing `result.panes[].agent_session.value` schema, already exercised by
the repository's herdr fixtures. A live mapping probe remains outstanding.

The installed Claude Code 2.1.311 bundle contains a shared Stop runner that
collects command-hook blocking feedback as meta user messages even with
`activeGoal` set. Its caller appends those messages to the next query and sets
the Stop continuation flag. An offline replay of that extracted runner, with
an active goal and one injected blocking result, returned the feedback in
`blockingErrors` and did not prevent continuation. This is a source-level replay,
not a live API/daemon experiment. It supports using the documented
`{"decision":"block","reason":...}` route; an additionalContext route is not
needed for that runner. The hook's one-shot guards are tested separately with
the real hook and fake herdr.

## Verification

`bash autodev/test/test-handoff-reach.sh` exercises stale labels, confirmed reuse,
renumbering, ambiguous matches, detached/unlabelled background sessions, badge
recovery, threshold and cooldown gates, repeated busy evaluations, pending
request notices, overlapping Stops, and ownership/context changes during checks.
The suite runs against temporary state and a fake herdr and sends no real input.
