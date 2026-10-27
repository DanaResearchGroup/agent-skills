# Handoff reachability

## Plan and background sessions

A daemon-hosted Claude Code background session inherits the pane environment of
its spawning terminal. A later `claude --resume` attachment can use a different,
unlabelled pane; after detachment there may be no hosting pane at all while the
worker continues writing context readings. An inherited `HERDR_PANE_ID` cannot
prove where that worker is currently attached.

The implementation follows this order:

1. Compare herdr's session label with reverse-owner registration and context
   freshness. When herdr labels the pane as ours, a former reverse owner with
   missing or no newer context is stale; registration atomically replaces it.
   A fresher context for the other session still proves live ownership and is
   refused. A different label alone does not prove reuse. Unknown ownership
   permits no herdr input. All watcher gates share `mux_pane_owner`.
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
   with `stop_hook_active: true` can also receive the notice. A `/goal` loop
   keeps that flag true after its first Stop, so suppressing all such Stops
   would miss a threshold crossed mid-loop. Ordinary fallback messages share
   the same 900-second cooldown for active and normal Stops; filed-request
   notices remain once per marker even after that cooldown expires.

The fallback preserves the handoff even when a detached worker cannot compact
itself. A human must attach and type `/compact` in that case. The watcher keeps
its existing thresholds and compact/reload sequence; it never types into a busy,
unreachable, or unproved pane to force progress.

## Registration cost

A successful herdr registration caches its validation time, inherited env pane,
and resolved pane. Repeated renders with that same pair make no herdr calls for
60 seconds. A changed env/binding pair, an unreachable flag, or expiry triggers
validation again. Tracking both ids also throttles a recovered session whose
inherited env id remains stale. Tab and tmux registration retain their cheap
local-file paths. Slow reverse-owner claims are serialized per pane with `flock`
and revalidated inside the lock before atomic replacement.

## Probes (2026-10-27)

The baseline fake-herdr fixture labelled a pane `sess-a`, while its reverse-owner
file named `sess-b` and `sess-b.ctx` was newer. The unchanged watcher logged
`SKIP ... reused by session sess-a` and deleted the binding, without driving it.
The regression now completes a fake `/handoff` → `/compact` → reload cycle.

Real `herdr --help` and `herdr pane --help` succeeded. The latter advertises
`pane process-info`, but does not document a process-to-pane mapping. Standalone
read-only `pane list` and `pane get` calls both returned `PermissionDenied`;
automatic approval review rejected escalated access under the execution policy.

The maintainer supplied the follow-up probe from a permitted terminal. Pane
records expose `agent`, optional `agent_session`, `agent_status`, `cwd`,
`foreground_cwd`, `focused`, `pane_id`, `revision`, `scroll`, `tab_id`,
`terminal_id`, and `workspace_id`. A present session label has the shape
`{agent, kind:"id", source:"herdr:claude", value:<session uuid>}`. The affected
attachment had no `agent` or `agent_session` even while Claude ran there, and
its `agent_status` was `unknown`.

The process environment exposes only `HERDR_ENV`, `HERDR_PANE_ID`,
`HERDR_TAB_ID`, `HERDR_WORKSPACE_ID`, and `HERDR_SOCKET_PATH`; it supplies no pid,
tty, or terminal id to join to the pane record. **No reliable process-to-pane
mapping exists in these reported fields.** The permitted-terminal result closes
the mapping probe. Recovery uses a unique exact session label when available;
the in-session Stop-hook fallback remains the primary path for missing or
unproved attachments, including a background worker with no hosting pane.

The installed Claude Code 2.1.311 bundle contains a shared Stop runner that
collects command-hook blocking feedback as meta user messages even with
`activeGoal` set. Its caller appends those messages to the next query and sets
the Stop continuation flag. An offline replay of that extracted runner, with
an active goal and one injected blocking result, returned the feedback in
`blockingErrors` and did not prevent continuation. This is a source-level replay,
not a live API/daemon experiment. It supports using the documented
`{"decision":"block","reason":...}` route; an additionalContext route is not
needed for that runner. The cooldown and once-per-marker guards are tested
separately with the real hook and fake herdr, including active goal continuations.

## Separate updater issue

The maintainer reports that npm's auto-updater repeatedly reinstalled the same
Claude Code version every few minutes, causing daemon restarts for upgrade and
the background session's death. That root-cause report was not independently
reproduced here. Repairing the updater is outside this change's scope.

## Verification

`bash autodev/test/test-handoff-reach.sh` exercises stale labels, confirmed reuse,
renumbering, ambiguous matches, detached/unlabelled background sessions, badge
recovery, threshold and cooldown gates, repeated busy evaluations, pending
request notices, overlapping Stops, and ownership/context changes during checks.
The suite runs against temporary state and a fake herdr and sends no real input.
