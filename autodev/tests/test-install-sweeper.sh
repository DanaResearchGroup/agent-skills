#!/usr/bin/env bash
# The sweeper is a launcher: it spawns detached watchers and exits at once. That
# makes the generated systemd unit load-bearing in a way the sweeper's own logic
# tests cannot see — they run it from a plain shell, where a backgrounded child
# survives the parent exiting.
#
# Under systemd it does not. With the default KillMode=control-group, systemd
# tears the service cgroup down as soon as a Type=oneshot ExecStart returns and
# kills every watcher the sweep just launched. The failure is silent and reads as
# success: the log fills with "SWEEP re-arming watcher (pct=... > 30)" every few
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

run_install() { # extra env assignments passed through
  env PATH="$FAKEBIN:$PATH" HOME="$SB/home" \
      CLAUDE_SETTINGS="$SB/settings.json" AUTODEV_HOME="$SB/home/agents" \
      bash "$BIN/install.sh" >"$SB/install.out" 2>&1
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
assert_contains "service sets KillMode=process so spawned watchers survive" "$(cat "$svc")" "KillMode=process"
assert_contains "service runs the sweeper" "$(cat "$svc")" "auto-handoff-sweep.sh"
assert_contains "service pins AUTODEV_HOME" "$(cat "$svc")" "AUTODEV_HOME=$SB/home/agents"
assert_contains "timer repeats on an interval" "$(cat "$tmr")" "OnUnitActiveSec="
assert_contains "timer is wanted by timers.target" "$(cat "$tmr")" "WantedBy=timers.target"
assert_contains "install enables the timer" "$(cat "$SB/calls.log")" "enable --now auto-handoff-sweep.timer"
assert_contains "install reports how the sweeper was wired" "$(cat "$SB/install.out")" "sweeper"
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

finish
