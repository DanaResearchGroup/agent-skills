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
   A fresher context for the other session is treated as ownership evidence and is
   refused. A different label alone does not prove reuse. Unknown ownership
   permits no herdr input. All watcher gates share `mux_pane_owner`.
2. If a registered pane is gone, accept a unique exact session match from
   `pane list`, then verify its live ownership. Keep that binding across later
   renders carrying a stale environment id. An unlabelled attachment or no
   attachment remains unreachable, rather than guessing from a working directory.
3. Immediately before each herdr send for a `claude` runtime, require the
   session's status-line tag in a five-line `recent-unwrapped` text read.
   Labels and timestamps cannot establish screen presence. Record
   `<sid>.unreachable` and its reason once per episode, showing
   `AUTO-HANDOFF: UNREACHABLE`. Metadata-only reachability and registration
   checks preserve screen refusals; a successful send-boundary screen check
   clears them. Refusal retains the pane binding and pending retry state.
4. At 35% or above, the Claude Stop hook is the primary route when driving is
   impossible: ask the session to run `/handoff` and file its own compact-only
   request. A persisted screen-presence refusal triggers this fallback even
   when metadata remains reachable for watcher retries. For an owned but
   continuously busy pane, use this fallback after
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

## Screen-presence probe (2026-10-28)

Standalone read-only `herdr pane list` and
`herdr pane read <pane> --source recent-unwrapped --lines 5 --format text`
calls succeeded with sandbox escalation. Two Claude Code panes, one idle and
one working, both included the status line in those bottom five lines. Both
also included the prompt separator and mode footer; the working pane included
an update notice. Two Codex panes showed `Ask Codex to do anything`, followed
by model, reasoning level, directory, context usage, task title, shortcuts and
warning counts. Neither showed a session id or equivalent stable marker.
Only these bottom regions were sampled; the probe did not drive any pane.

Before this change, `cc-statusline.sh` printed the handoff state badge,
optional AUTODEV badge, model, input token count, context percentage, and
optional cache, location, spar-context and deferred-question segments. An
optional context bar occupied a second row. It printed no session identity.
It now prints `⟨cc:ab12cd34⟩` after the handoff badge, using the first eight
session-id characters. The fixed `⟨cc:…⟩` wrapper distinguishes the tag from
ordinary prose and bare ids; it is an accidental-misrouting guard, not an
authentication token. The renderer and sender share `mux_session_tag`.

The screen check runs only in `_mux_refuse_unowned`, including the final
check after any dialog read and the own-prompt key path. To tolerate a
post-compaction redraw, it tries up to five reads, waiting one second between
attempts (`AUTODEV_POLL` overrides that delay). Ownership is rechecked after
each wait, and recovery after a wait also rechecks for an open human dialog.
Empty, unreadable or tagless screens produce one final refusal after the
bound. A tag outside the bottom five lines does not
qualify. Status-line registration never reads the screen. Codex and unknown
runtimes retain the metadata-based behavior because the probe found no stable
visible session marker for them; tmux behavior is unchanged. Existing Claude
sessions need a status-line refresh with the tagged renderer before watcher
sends can pass. The short tag can collide for ids sharing eight characters,
and separate read/send socket calls cannot make attachment changes atomic.

`bash autodev/test/test-screen-presence.sh` uses synthetic status-line fixtures
and a fake herdr to exercise every send method, stale metadata, successful
recovery, persistent refusal across renders, unreadable/empty screens, old
scrollback tags, a screen switch after the dialog check, and Codex/unknown
runtime compatibility. No real pane receives input.

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
