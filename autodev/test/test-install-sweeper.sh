#!/usr/bin/env bash
# The sweeper is a launcher: it spawns detached watchers and exits at once. That
# makes the generated systemd unit load-bearing in a way the sweeper's own logic
# tests cannot see — they run it from a plain shell, where a backgrounded child
# survives the parent exiting.
#
# Under systemd it does not. With the default KillMode=control-group, systemd
# tears the service cgroup down as soon as a Type=oneshot ExecStart returns and
# kills every watcher the sweep just launched. The failure is silent and reads as
# success: the log fills with "SWEEP re-arming watcher (pct=... > 35)" every few
# minutes while no cycle ever runs, because the watcher lives just long enough to
# write its heartbeat. That shipped once; these tests exist so it cannot again.
#
# systemctl and crontab are stubbed and HOME is redirected, so this never touches
# the real user manager or the real crontab.

. "$(dirname "$0")/lib.sh"

setup_install() {
  sandbox_new
  FAKEBIN="$SB/fakebin"; mkdir -p "$FAKEBIN" "$SB/home"
  printf '#!/usr/bin/env bash\necho "systemctl $*" >> "%s/calls.log"\nexit 0\n' "$SB" > "$FAKEBIN/systemctl"
  printf '#!/usr/bin/env bash\necho "crontab $*" >> "%s/calls.log"\ncat >/dev/null 2>&1\nexit 0\n' "$SB" > "$FAKEBIN/crontab"
  chmod +x "$FAKEBIN"/*
  : > "$SB/calls.log"
}

run_install() { # any args are extra VAR=value assignments, applied after ours
  env PATH="$FAKEBIN:$PATH" HOME="$SB/home" \
      CLAUDE_SETTINGS="$SB/settings.json" AUTODEV_HOME="$SB/home/agents" \
      "$@" bash "$BIN/install.sh" >"$SB/install.out" 2>&1
}

run_codex_install() {
  env PATH="$FAKEBIN:$PATH" HOME="$SB/home" \
      CODEX_HOOKS="$SB/hooks.json" AUTODEV_HOME="$SB/home/agents" \
      bash "$BIN/install.sh" --codex >"$SB/install.out" 2>&1
}

UNIT_DIR_REL=".config/systemd/user"

echo "== the generated systemd unit =="

setup_install
run_install
svc="$SB/home/$UNIT_DIR_REL/auto-handoff-sweep.service"
tmr="$SB/home/$UNIT_DIR_REL/auto-handoff-sweep.timer"

assert_file "install writes the sweeper service unit" "$svc"
assert_file "install writes the sweeper timer unit" "$tmr"

# THE regression guard. Without this line the sweeper is installed but inert.
# Line-anchored deliberately: the unit carries comments that mention
# KillMode=process, so a substring match passes even with the directive deleted.
assert_line "service sets KillMode=process so spawned watchers survive" "$(cat "$svc")" "KillMode=process"
assert_line "service is a oneshot" "$(cat "$svc")" "Type=oneshot"
assert_line "service runs the sweeper" "$(cat "$svc")" "ExecStart=$BIN/auto-handoff-sweep.sh"
assert_line "service pins AUTODEV_HOME" "$(cat "$svc")" "Environment=AUTODEV_HOME=$SB/home/agents"
assert_line_start "timer repeats on an interval" "$(cat "$tmr")" "OnUnitActiveSec="
assert_line "default sweep interval is 3min" "$(cat "$tmr")" "OnUnitActiveSec=3min"
assert_line "timer is wanted by timers.target" "$(cat "$tmr")" "WantedBy=timers.target"
assert_contains "install enables the timer" "$(cat "$SB/calls.log")" "enable --now auto-handoff-sweep.timer"
assert_contains "install reports how the sweeper was wired" "$(cat "$SB/install.out")" "sweeper"
sandbox_rm

echo "== Codex hooks preserve existing configuration =="

setup_install
cat > "$SB/hooks.json" <<'JSON'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"existing-session-hook"}]}]}}
JSON
run_codex_install
run_codex_install
stop=$(jq -r '[.hooks.Stop[]?.hooks[]?.command] | map(select(test("codex-stop-hook"))) | length' "$SB/hooks.json")
assert_eq "Codex install adds one Stop hook idempotently" "$stop" "1"
ss=$(jq -r '[.hooks.SessionStart[]? | select(.matcher == "^compact$") | .hooks[]?.command] | map(select(test("sessionstart-compact"))) | length' "$SB/hooks.json")
assert_eq "Codex install adds one compact SessionStart hook" "$ss" "1"
assert_eq "Codex install preserves an existing SessionStart hook" \
  "$(jq -r '[.hooks.SessionStart[]?.hooks[]?.command] | index("existing-session-hook") != null' "$SB/hooks.json")" "true"
assert_contains "Codex install explains hook trust" "$(cat "$SB/install.out")" "/hooks"
sandbox_rm

echo "== the sweep interval is configurable =="

# The assertions above pin the DEFAULT interval. This one pins the plumbing:
# AUTODEV_SWEEP_EVERY has to survive install.sh and land in the generated unit.
# Without it the variable could quietly stop being honoured — the unit would
# still carry a valid OnUnitActiveSec, so every other assertion here would pass
# while the operator's chosen cadence was silently ignored.
setup_install
run_install AUTODEV_SWEEP_EVERY=45s
tmr="$SB/home/$UNIT_DIR_REL/auto-handoff-sweep.timer"
assert_line "AUTODEV_SWEEP_EVERY reaches the generated timer" "$(cat "$tmr")" "OnUnitActiveSec=45s"
assert_contains "install reports the configured interval" "$(cat "$SB/install.out")" "45s"
sandbox_rm

echo "== hooks are still registered, without duplicates =="

setup_install
run_install
run_install    # idempotence: our own entries are replaced, never doubled
hooks=$(jq -r '[.hooks.Stop[]?.hooks[]?.command] | map(select(test("cc-stop-hook"))) | length' "$SB/settings.json")
assert_eq "re-running install does not duplicate the Stop hook" "$hooks" "1"
ss=$(jq -r '[.hooks.SessionStart[]?.hooks[]?.command] | map(select(test("cc-sessionstart-compact"))) | length' "$SB/settings.json")
assert_eq "re-running install does not duplicate the SessionStart hook" "$ss" "1"
assert_contains "statusLine points at our script" "$(jq -r '.statusLine.command' "$SB/settings.json")" "cc-statusline.sh"
sandbox_rm

echo "== cron fallback when systemd is unavailable =="

# install.sh gates on `systemctl --user show-environment` succeeding, so that is
# what we make fail — the real case being systemd present but no user manager
# (a plain ssh session, a container). The stub STAYS on PATH: deleting it would
# just expose the machine's real systemctl and drive the real user manager.
setup_install
printf '#!/usr/bin/env bash\necho "systemctl $*" >> "%s/calls.log"\n[ "$1 $2" = "--user show-environment" ] && exit 1\nexit 0\n' "$SB" > "$FAKEBIN/systemctl"
chmod +x "$FAKEBIN/systemctl"
run_install
assert_contains "falls back to cron when systemd is absent" "$(cat "$SB/calls.log")" "crontab"
assert_contains "cron line invokes the sweeper" "$(cat "$SB/install.out")" "cron"
sandbox_rm

echo "== the PreToolUse handoff gate is installed into the (fixture) settings =="

setup_install
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/other/hook.sh"}]}]}}\n' > "$SB/settings.json"
run_install
run_install
gate_n=$(jq --arg g "$BIN/cc-handoff-gate.sh" '[.hooks.PreToolUse[]?.hooks[]? | select(.command==$g)] | length' "$SB/settings.json")
assert_eq "install adds the gate once, idempotently" "$gate_n" 1
other_n=$(jq '[.hooks.PreToolUse[]?.hooks[]? | select(.command=="/other/hook.sh")] | length' "$SB/settings.json")
assert_eq "install preserves other PreToolUse hooks" "$other_n" 1
sandbox_rm

echo "== install.sh vs unusual existing settings =="

gate_count() { jq --arg g "$BIN/cc-handoff-gate.sh" '[.hooks.PreToolUse[]?.hooks[]? | select(.command==$g)] | length' "$SB/settings.json"; }

# Other matchers survive.
setup_install
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/a.sh"}]},{"matcher":"Edit|Write","hooks":[{"type":"command","command":"/b.sh"}]}]}}\n' > "$SB/settings.json"
run_install
assert_eq "PreToolUse with several matchers: both kept, gate added once" "$(jq '.hooks.PreToolUse | length' "$SB/settings.json")" 3
sandbox_rm

# The same command under a different matcher, and sharing an entry with another hook.
setup_install
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"%s/cc-handoff-gate.sh"},{"type":"command","command":"/keep.sh"}]}]}}\n' "$BIN" > "$SB/settings.json"
run_install
assert_eq "gate under another matcher is not duplicated" "$(gate_count)" 1
assert_eq "a hook sharing the entry with the gate is NOT deleted" "$(jq '[.hooks.PreToolUse[]?.hooks[]? | select(.command=="/keep.sh")] | length' "$SB/settings.json")" 1
sandbox_rm

# Same protection for the Stop hook install had before.
setup_install
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s/cc-stop-hook.sh"},{"type":"command","command":"/keep-stop.sh"}]}]}}\n' "$BIN" > "$SB/settings.json"
run_install
assert_eq "a hook sharing an entry with the Stop hook is NOT deleted" "$(jq '[.hooks.Stop[]?.hooks[]? | select(.command=="/keep-stop.sh")] | length' "$SB/settings.json")" 1
sandbox_rm

# hooks.PreToolUse as a single object (not an array) is wrapped, not crashed on.
setup_install
printf '{"hooks":{"PreToolUse":{"matcher":"Bash","hooks":[{"type":"command","command":"/solo.sh"}]}}}\n' > "$SB/settings.json"
run_install
assert_eq "object-valued PreToolUse: gate installed" "$(gate_count)" 1
assert_eq "object-valued PreToolUse: the original hook is kept" "$(jq '[.hooks.PreToolUse[]?.hooks[]? | select(.command=="/solo.sh")] | length' "$SB/settings.json")" 1
sandbox_rm

# A settings file install cannot safely edit is left byte-for-byte alone and install fails loudly.
setup_install
printf '{"hooks":{"PreToolUse":"oops"}}\n' > "$SB/settings.json"; cp "$SB/settings.json" "$SB/settings.orig"
run_install; rc=$?
assert_eq "a string-valued PreToolUse is left untouched" "$(cmp -s "$SB/settings.json" "$SB/settings.orig" && echo same || echo changed)" same
assert_eq "and install exits non-zero rather than clobbering it" "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" nonzero
sandbox_rm

# Re-install is a fixed point.
setup_install
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/a.sh"}]}]}}\n' > "$SB/settings.json"
run_install; cp "$SB/settings.json" "$SB/once.json"
run_install
assert_eq "second install changes nothing" "$(cmp -s "$SB/settings.json" "$SB/once.json" && echo same || echo changed)" same
sandbox_rm

finish
