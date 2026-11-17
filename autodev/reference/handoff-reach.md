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
   notices remain once per marker even after that cooldown expires. This prose
   notice is only for a pane the watcher has not refused: when
   `<sid>.unreachable` exists for a herdr binding, step 6 owns the request and
   the Stop gets the `AskUserQuestion` instruction instead, without the
   fallback's arming or threshold conditions.

6. The PreToolUse handoff gate (`cc-handoff-gate.sh`) stands down while
   `<sid>.unreachable` exists for a herdr binding, as it does with no pane: a
   refused session cannot be compacted by the watcher, so denying tools would
   park it. Each pending request gets one notice telling the model to call
   `AskUserQuestion` before any other work: one question saying automation
   cannot reach the pane (with the reason) and the user must type `/compact` in
   it, with the options "I will type /compact now" (recommended) and "Continue
   without compacting". A pending question blocks the pane in the fleet view,
   where prose scrolls past. The gate allows `AskUserQuestion` in every state.
   The first event delivers the notice. Either the first tool call is held once
   with it, or, on the normal handoff path where the session files the request
   and ends its turn with no further tool call, the Stop hook runs
   `cc-handoff-gate.sh --stop`, which blocks that Stop once with it. The Stop
   hook asks the gate before its fallback, and again after the fallback's own
   reachability check, so a refusal found during that Stop is covered too. If a
   turn ends with no question after the notice, the next Stop repeats it once;
   after a question, or after the repeat, Stops are silent. The user sees at
   most the question, never the step 5 prose. A Persona seat (working folder
   under `~/Persona/<name>/`, the test `threshold-lib.sh` uses for the 200k
   line) is the exception. It runs unattended, and an open menu is the cover
   that parks it and holds its lane messages. Its notice says not to call
   `AskUserQuestion` and to end its turn. Its Stop is never blocked: the Stop
   claims the notice silently and launches the watcher, and step 7's alert
   reaches a person if the pane stays unreachable, for every reason in the
   flag (covered screen, ownership, missing or detached pane, unproved
   presence). The sweep judges a Persona seat from `<sid>.workdir` alone, so
   the gate writes the hook's cwd there when the file is missing. Each time
   the gate spares a Persona seat the menu it touches `<sid>.spared`, the
   proof step 7 needs that the seat was alive while its flag stood. The flag is not compared with the request's mtime: it is
   written once per episode, so it usually predates the request. For an
   ownership, no-pane or pane-gone refusal, a successful herdr reachability
   check removes the flag, and registration skips its throttle while it exists,
   so a stale flag lasts only until the next re-check (status-line render,
   Stop, watcher). A Claude session's `screen presence unproved:` flag is
   different (step 3): `mux_session_reachable` keeps it even after a successful
   ownership check, and only a successful screen check at the send boundary,
   which the watcher runs just before it sends input, clears it. A status-line
   render or a Stop alone does not restore normal gating for that refusal. The
   tmux path never clears the flag, so a tmux-only binding ignores it.

7. A covered pane keeps its handoff queued, and a stuck seat is made loud.
   The watcher never types under a menu or overlay. On a dialog refusal or a
   screen-presence refusal it re-files the request it consumed and records
   the refusal in `<sid>.covered` as `<since> <last> <kind>`. Since is the
   episode start, last is the latest refusal, and kind is `menu`, `login` or
   `other`. On a Persona seat the sweep also records its own reachability
   refusals there, as `owner` (the pane is live but not proved this
   session's) or `nopane` (the pane is gone and no other pane carries the
   session): the gate orders such a seat no menu for any reason, so this
   alert is all that reaches a person. It does so only when `<sid>.spared`
   is not older than `<sid>.unreachable`, that is when the gate has spared
   the live seat the menu since the flag was raised. A session that died
   with its request pending, its pane since recycled or closed, is refused
   at every tick but never runs the gate, so it starts no episode and pages
   no one. Other seats record no `owner` or `nopane` episode and keep the
   gate's menu. One writer,
   `autodev_cover_record` in `mux-lib.sh`, serves both. A send that lands
   deletes the file, which ends the episode. A compaction after `since`, or
   a gap of more than 15 minutes between two refusals, starts a new episode.
   Only a refusal recorded by this code starts one: an `<sid>.unreachable`
   flag alone, however old, never does, so a flag left from before the
   install starts its 10 minutes at the first refusal recorded after it. The
   sweep re-arms the watcher on every tick, so a seat compacts on the first
   tick after its screen clears.
   A seat can be past its line (`ctx-over.sh`), unreachable for more than 10
   minutes, refused within the last 15 minutes, with no compaction since the
   episode began and no turn running. Such a seat gets one Slack line to the
   owner (`cc-slack-post.py`; the channel comes from `CC_SLACK_CHANNEL`, else
   from `env` in Claude Code's `settings.json`). It also gets one session-lane
   line to `persona:method`, sent once per episode. Each line names the seat
   by its herdr tab label (never a pane id), its context reading and the
   reason: `menu`, `login screen`, `other`, `pane not owned` or `no pane`.
   `<sid>.covered-alert` records the episode and each send, so a
   later sweep process never sends again. A failed send is recorded there
   with its first output line and retried on the next tick. Lane retries
   reuse one message id per episode. The sweep repeats every check under
   `<sid>.page.lock` before it sends, and reads the pane again: ownership
   first, so another session's status or screen is never read. A pane gone
   or not this session's alerts a Persona seat only, with that reason. A pane
   that is ours again is read with the watcher's own presence and dialog
   tests (`mux_screen_present_once`, `mux_awaiting_human`). `<sid>.covered`
   outlives a cover that the person closed before the watcher's next send. A
   reachable pane with a clear screen ends the episode with no alert: the
   sweep deletes the file if it still holds the line it read. Alerts are sent only after the sweep has re-armed every
   watcher, so a slow send never delays a handoff. At most 4 run at once
   (`AUTODEV_ALERT_PARALLEL`). None starts after 60 s
   (`AUTODEV_ALERT_BUDGET`); a skipped alert is retried on the next tick,
   ahead of the others (`state/.alert-skipped`), so slow early sends cannot
   starve the seats after them. With
   the 10 s lock wait and two 30 s sends, delivery ends inside the 3-minute
   sweep interval. Overrides: `AUTODEV_SLACK_CMD`,
   `AUTODEV_LANE_CMD`, `AUTODEV_ALERT_LANE_TO`, `AUTODEV_CLAUDE_SETTINGS`.

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

`bash autodev/test/test-covered-seat.sh` drives the real sweep, watcher and
mux library against a fake herdr serving menu, login and other screens, with
fake Slack and lane commands. It covers a marker kept across covered ticks
with nothing typed, compaction on the first clear tick, one Slack line and
one lane line after 10 minutes and none before, a second episode, failed
sends retried, an episode that ends while the sweep waits for the lock, a
screen cleared before the alert, alerts sent only after every watcher is
re-armed, and the parallel and time bounds on delivery. On a Persona seat it
covers a pane not owned and a pane gone (no menu, one alert after 10 minutes,
none at 9), a flag from before the install that starts no episode, a dead seat
the gate never spared that starts none either, a pane lost
while the alert waits for the lock, and a pane given back. A seat outside
`~/Persona` refused for ownership keeps the menu and gets no alert. With three
slow seats and a budget for one send, each seat is tried within three ticks.
