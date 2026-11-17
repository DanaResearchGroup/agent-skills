#!/usr/bin/env bash
# The limit-resume watcher (session-resume-watch.sh) and the usage-limit wait it
# shares with the handoff watcher, the sweep and the status line (limit-lib.sh).
#
# What went wrong (2026-11-17): the watcher matched a limit banner anywhere in
# the pane's last 200 rows, so an old banner in the scrollback started a fresh
# wait (once of about 20 hours, from a reset that had already passed), and
# while <sid>.limit-wait existed the handoff watcher skipped the session. Its
# /usage-credits opened a login picker in 12 of 19 sends, and six sessions sat
# on the picker for hours. The owner then ordered the watcher never to type
# that command again: the path is gone, and a check here and in ci.sh fails on
# any send of it from bin/.
#
# Detector cases run limit-banner.py on fixed screens at a fixed clock
# (TZ=Asia/Jerusalem). Watcher cases run the REAL mux-lib.sh against a fake
# herdr that serves a screen, swaps it when a command or key is typed, and
# logs every keystroke instead of typing it.

. "$(dirname "$0")/lib.sh"

SID=55555555-5555-5555-5555-555555555555
FX="$SKILL_DIR/test/fixtures/panes"
DET="$SKILL_DIR/bin/limit-banner.py"
export TZ=Asia/Jerusalem
export AUTODEV_POLL=0 AUTODEV_DETECT_RECHECK=0 AUTODEV_RESUME_WAKE=1
ORIG_PATH="$PATH"

at() { date -d "$1" +%s; }                     # a wall-clock instant, local zone
detect() { # $1 fixture, $2 "now" ("YYYY-mm-dd HH:MM"), then extra flags
  local f=$1 n=$2; shift 2
  python3 "$DET" --now "$(at "$n")" "$@" < "$FX/$f.txt"
}

echo "== detector: what is NOT a live banner detects nothing =="
assert_eq "banner in the scrollback, session output after it" \
  "$(detect limit-scrollback '2026-11-17 11:12')" "none reason=not-newest"
assert_eq "banner followed by the session's own new output" \
  "$(detect limit-after-output '2026-11-17 06:40')" "none reason=not-newest"
assert_eq "live banner whose reset has passed (read at 11:12, reset 7:30am, banner at 6:35)" \
  "$(detect limit-live '2026-11-17 11:12')" "none reason=reset-passed"
assert_eq "prose quoting the banner" \
  "$(detect limit-prose '2026-11-17 06:41')" "none reason=not-newest"
assert_eq "a live limit banner with no reset time" \
  "$(detect limit-no-reset '2026-11-17 06:41')" "none reason=no-reset"
assert_eq "a dialog (login picker) over the composer" \
  "$(detect limit-login-picker '2026-11-17 06:40')" "none reason=no-composer"
assert_eq "an idle pane with no banner" \
  "$(detect idle-prompt '2026-11-17 06:40')" "none reason=no-banner"
assert_eq "no turn summary and the clock time has passed: never tomorrow" \
  "$(detect limit-no-done '2026-11-17 08:00')" "none reason=banner-time-unknown"

echo "== detector: a live banner, and the day its reset falls on =="
assert_eq "live banner, reset ahead today" \
  "$(detect limit-live '2026-11-17 06:40')" \
  "reset=$(at '2026-11-17 07:30') human=7:30am_Asia/Jerusalem kind=5-hour"
assert_eq "live banner in an unwrapped read that glued full-width rows together" \
  "$(detect limit-live-glued '2026-11-17 06:40')" \
  "reset=$(at '2026-11-17 07:30') human=7:30am_Asia/Jerusalem kind=5-hour"
assert_eq "midnight: 'resets 12:05am' under 'done 11:57 PM', read at 23:58, is tomorrow" \
  "$(detect limit-midnight '2026-11-17 23:58')" \
  "reset=$(at '2026-11-18 00:05') human=12:05am_Asia/Jerusalem kind=5-hour"
assert_eq "midnight: the same screen read at 00:03 is still the same reset" \
  "$(detect limit-midnight '2026-11-18 00:03')" \
  "reset=$(at '2026-11-18 00:05') human=12:05am_Asia/Jerusalem kind=5-hour"
assert_eq "two banners on screen: only the newest counts" \
  "$(detect limit-two-banners '2026-11-17 06:40')" \
  "reset=$(at '2026-11-17 07:30') human=7:30am_Asia/Jerusalem kind=5-hour"
assert_eq "no turn summary, reset still ahead: today" \
  "$(detect limit-no-done '2026-11-17 07:00')" \
  "reset=$(at '2026-11-17 07:30') human=7:30am_Asia/Jerusalem kind=5-hour"
assert_eq "weekly banner with a date" \
  "$(detect limit-weekly '2026-11-17 06:40')" \
  "reset=$(at '2026-11-20 08:00') human=Nov20_8:00am_Asia/Jerusalem kind=weekly"
assert_eq "--live-only: a live banner whose reset passed is still on screen" \
  "$(detect limit-live '2026-11-17 11:12' --live-only)" "live"
for gone in --after-credits "--own-dialog x"; do
  # shellcheck disable=SC2086
  python3 "$DET" $gone < "$FX/limit-live.txt" >/dev/null 2>&1
  assert_eq "the detector has no $gone mode left (the credits path is gone)" "$?" 2
done
python3 "$DET" --composer-clear < "$FX/presence-clear.txt"
assert_eq "--composer-clear: empty composer box" "$?" 0
python3 "$DET" --composer-clear < "$FX/limit-login-picker.txt"
assert_eq "--composer-clear: a picker is not a clear composer" "$?" 1
assert_contains "--describe: the picker names Ctrl-C" \
  "$(python3 "$DET" --describe < "$FX/limit-login-picker.txt")" "key=Ctrl-C screen="

# --- fake herdr ------------------------------------------------------------------
# $SB/herdr/screen.txt       what `pane read` returns
# $SB/herdr/after-run.txt    swapped in when a line is typed (pane run)
# $SB/herdr/after-key.txt    swapped in when a key is sent (pane send-keys)
# $SB/typed.log              every pane run / send-keys, one per line
setup() {
  sandbox_new
  mkdir -p "$SB/herdr" "$SB/fakebin"
  : > "$SB/typed.log"
  printf 'idle\n' > "$SB/herdr/status"
  cat > "$SB/fakebin/herdr" <<'STUB'
#!/usr/bin/env bash
H="$SB/herdr"
case "${1:-} ${2:-}" in
  "pane get")
      printf '{"result":{"pane":{"pane_id":"%s","agent_status":"%s","agent_session":{"value":"%s"},"scroll":{"offset_from_bottom":0}}}}\n' \
        "$3" "$(cat "$H/status")" "$(cat "$H/owner" 2>/dev/null)" ;;
  "pane read")
      n=$(( $(cat "$H/reads" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$H/reads"
      if [ -f "$H/from-read-2.txt" ] && [ "$n" -ge 2 ]; then cat "$H/from-read-2.txt"; else cat "$H/screen.txt"; fi ;;
  "pane run")
      printf 'RUN %s\n' "$4" >> "$SB/typed.log"
      [ -f "$H/after-run.txt" ] && cp "$H/after-run.txt" "$H/screen.txt"
      exit 0 ;;
  "pane send-keys")
      printf 'KEY %s\n' "$4" >> "$SB/typed.log"
      [ -f "$H/after-key.txt" ] && cp "$H/after-key.txt" "$H/screen.txt"
      exit 0 ;;
  "pane send-text") printf 'TEXT %s\n' "$4" >> "$SB/typed.log" ;;
  "tab get") printf '{"result":{"tab":{"label":"fixture tab"}}}\n' ;;
  "tab rename") exit 0 ;;
  *) echo "fake herdr: unhandled [$*]" >&2; exit 64 ;;
esac
STUB
  chmod +x "$SB/fakebin/herdr"
  export PATH="$SB/fakebin:$ORIG_PATH" MUX_HERDR="$SB/fakebin/herdr"
  session_new "$SID" 40 "w1:p7"
  session_tab "$SID" "w1:t1" "fixture tab"
  printf 'claude\n' > "$STATE/$SID.runtime"
  printf '%s\n' "$SID" > "$SB/herdr/owner"
  arm
}
typed() { cat "$SB/typed.log"; }
LOG() { cat "$AUTODEV_HOME/logs/$1.log" 2>/dev/null; }
resume() { timeout 30 bash "$BIN/session-resume-watch.sh" "$SID" </dev/null >/dev/null 2>&1; }
# A screen whose banner was printed at $1 minutes from now, reset $2 minutes from now.
live_screen() { # $1 banner offset (min), $2 reset offset (min)
  local done_at reset_at
  done_at=$(date -d "$1 minutes" +'%-I:%M %p')
  reset_at=$(date -d "$2 minutes" +'%-I:%M%P')
  sed -e "s/done 6:35 AM/done $done_at/" -e "s/7:30am/$reset_at/g" "$FX/limit-live.txt"
}
wait_exit() { # $1 pid: bounded wait; a watcher still running after 30 s is a failure
  local end=$(( $(date +%s) + 30 ))
  while kill -0 "$1" 2>/dev/null && [ "$(date +%s)" -lt "$end" ]; do sleep 0.2; done
  if kill -0 "$1" 2>/dev/null; then
    kill "$1" 2>/dev/null; _fail "the watcher ended within 30 s" "still running; killed"
  fi
  wait "$1" 2>/dev/null
}
wait_log() { # $1 log, $2 text, $3 timeout s
  local end=$(( $(date +%s) + ${3:-15} ))
  until grep -qF "$2" "$AUTODEV_HOME/logs/$1.log" 2>/dev/null || [ "$(date +%s)" -ge "$end" ]; do sleep 0.2; done
}

echo "== watcher: what is not a live banner types nothing =="
for fx in limit-scrollback limit-prose limit-no-reset limit-after-output; do
  setup
  cp "$FX/$fx.txt" "$SB/herdr/screen.txt"
  resume
  assert_eq "$fx: nothing typed" "$(typed)" ""
  assert_no_file "$fx: no limit-wait" "$STATE/$SID.limit-wait"
  sandbox_rm
done
setup
live_screen -300 -60 > "$SB/herdr/screen.txt"     # banner 5h ago, reset 1h ago
resume
assert_eq "live banner, reset passed: nothing typed" "$(typed)" ""
assert_no_file "live banner, reset passed: no limit-wait" "$STATE/$SID.limit-wait"
assert_contains "live banner, reset passed: logged why" "$(LOG auto-resume)" "NO-DETECT pane=w1:p7 reason=reset-passed"
sandbox_rm

echo "== watcher: a live banner with a future reset =="
setup
live_screen -1 3 > "$SB/herdr/screen.txt"
reset_epoch=$(date -d "$(date -d '3 minutes' +'%H:%M')" +%s)
bash "$BIN/session-resume-watch.sh" "$SID" </dev/null >/dev/null 2>&1 &
wpid=$!
wait_log auto-resume "then sending continue"
lw=$(cat "$STATE/$SID.limit-wait" 2>/dev/null)
assert_contains "limit-wait until= is the reset plus the 4-minute buffer" "$lw" "until=$(( reset_epoch + 240 )) reset=$reset_epoch "
assert_contains "the log names the detection and the wait" "$(LOG auto-resume)" "LIMIT detected pane=w1:p7 dry=0 kind=5-hour"
w=$(sed -n 's/.* wait=\([0-9]*\)s$/\1/p' "$AUTODEV_HOME/logs/auto-resume.log" | head -n1)
exp=$(( reset_epoch + 240 - $(date +%s) ))
[ -n "$w" ] && [ $(( w - exp )) -le 3 ] && [ $(( exp - w )) -le 3 ]
assert_eq "the logged wait is the time to reset+buffer (got ${w:-none}, expected ~$exp)" "$?" 0
# The session prints new output under the banner: the wait ends, nothing typed.
cp "$FX/limit-after-output.txt" "$SB/herdr/screen.txt"
wait_exit "$wpid"
assert_contains "banner gone from the live area: the wait ends" "$(LOG auto-resume)" "ABORT banner gone from the live area during wait"
assert_no_file "and limit-wait is gone with it" "$STATE/$SID.limit-wait"
assert_eq "nothing typed during the wait" "$(typed)" ""
sandbox_rm

setup
live_screen -1 3 > "$SB/herdr/screen.txt"
bash "$BIN/session-resume-watch.sh" "$SID" </dev/null >/dev/null 2>&1 &
wpid=$!
wait_log auto-resume "then sending continue"
date -d '+5 seconds' +%s > "$STATE/$SID.idle"   # a turn completes after the wait began
wait_exit "$wpid"
assert_contains "a completed turn ends the wait" "$(LOG auto-resume)" "ABORT a turn completed during wait"
assert_no_file "a completed turn removes limit-wait" "$STATE/$SID.limit-wait"
sandbox_rm

# The condition changes while the watcher takes the resume lock: the first read
# shows a live banner, the read under the lock shows the session moved on.
setup
live_screen -1 3 > "$SB/herdr/screen.txt"
cp "$FX/limit-after-output.txt" "$SB/herdr/from-read-2.txt"
resume
assert_contains "the re-check under the lock sees the banner is no longer live" "$(LOG auto-resume)" "NO-DETECT pane=w1:p7 reason=not-newest (re-check under the lock)"
assert_no_file "and no limit-wait is written" "$STATE/$SID.limit-wait"
assert_eq "and nothing is typed" "$(typed)" ""
sandbox_rm

# A reader that is removing a stale wait holds the resume lock for a moment;
# the watcher waits it out instead of dropping a fresh detection.
setup
live_screen -1 3 > "$SB/herdr/screen.txt"
sleep 30 & holder=$!
( . "$BIN/limit-lib.sh"; autodev_resume_lock_take "$STATE" "$SID" "$holder" )
( sleep 2; . "$BIN/limit-lib.sh"; autodev_resume_lock_release "$STATE" "$SID" ) &
bash "$BIN/session-resume-watch.sh" "$SID" </dev/null >/dev/null 2>&1 &
wpid=$!
wait_log auto-resume "then sending continue"
assert_contains "a lock held for a moment: the watcher still detects" "$(LOG auto-resume)" "LIMIT detected pane=w1:p7"
assert_not_contains "and does not skip" "$(LOG auto-resume)" "SKIP resume already in progress"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
cp "$FX/limit-after-output.txt" "$SB/herdr/screen.txt"
wait_exit "$wpid"
sandbox_rm

echo "== the watcher never types /usage-credits (owner order 2026-11-17) =="
# No script under bin/ sends it; the one allowed hit is the detector's pattern
# for the banner's own hint line, which it reads and never sends.
hits=$(grep -rniE 'usage[-_ ]?credits' "$SKILL_DIR/bin" | grep -vF "limit-banner.py:" ; \
       grep -niE 'usage[-_ ]?credits' "$SKILL_DIR/bin/limit-banner.py" | grep -vF 're.compile(r"^/usage-credits to finish what you')
assert_eq "no script under autodev/bin names /usage-credits outside the banner pattern" "$hits" ""
setup
live_screen -1 3 > "$SB/herdr/screen.txt"
bash "$BIN/session-resume-watch.sh" "$SID" </dev/null >/dev/null 2>&1 &
wpid=$!
wait_log auto-resume "then sending continue"
assert_not_contains "a live banner, armed, no switch set: /usage-credits is never typed" "$(typed)" "usage-credits"
assert_eq "nothing at all is typed while it waits" "$(typed)" ""
assert_file "it waits for the reset instead" "$STATE/$SID.limit-wait"
: > "$STATE/disable-auto-resume"
wait_exit "$wpid"
assert_contains "disable-auto-resume set during the wait: it stops" "$(LOG auto-resume)" "ABORT disabled during wait"
assert_no_file "and its limit-wait goes" "$STATE/$SID.limit-wait"
assert_eq "nothing typed" "$(typed)" ""
sandbox_rm

setup
: > "$STATE/disable-auto-resume"
live_screen -1 3 > "$SB/herdr/screen.txt"
resume
assert_eq "disable-auto-resume set: a live banner gets nothing typed" "$(typed)" ""
assert_no_file "and no limit-wait" "$STATE/$SID.limit-wait"
assert_eq "and no log line (the switch is checked first)" "$(LOG auto-resume)" ""
sandbox_rm

echo "== a pane on needs-owner.list gets nothing typed until its screen is clear =="
setup
cp "$FX/limit-login-picker.txt" "$SB/herdr/screen.txt"   # still covered
( . "$BIN/limit-lib.sh"; autodev_needs_owner_set "$STATE" "$SID" "fixture tab" Ctrl-C "a login picker" )
line=$(cat "$STATE/needs-owner.list" 2>/dev/null)
assert_contains "the line names the session and its tab" "$line" "$SID	fixture tab	since="
assert_contains "the line names the key that would clear it" "$line" "key=Ctrl-C"
since=$(sed -n 's/.*since=\([^	]*\).*/\1/p' "$STATE/needs-owner.list")
resume
assert_eq "a listed pane gets nothing typed" "$(typed)" ""
assert_contains "and says why" "$(LOG auto-resume)" "is on needs-owner.list; typing nothing"
( . "$BIN/limit-lib.sh"; sleep 1; autodev_needs_owner_set "$STATE" "$SID" "fixture tab" Escape "again" )
assert_eq "written twice for the same pane: still one line" "$(wc -l < "$STATE/needs-owner.list")" "1"
assert_contains "updated in place, first since= kept" "$(cat "$STATE/needs-owner.list")" "since=$since	key=Escape	screen=again"
cp "$FX/presence-clear.txt" "$SB/herdr/screen.txt"   # the owner closed it
resume
assert_contains "a clear composer takes the pane off the list" "$(LOG auto-resume)" "CLEAR needs-owner: pane w1:p7 shows an empty composer again"
assert_eq "no line left for the pane" "$(grep -c "^$SID" "$STATE/needs-owner.list")" "0"
sandbox_rm

echo "== limit-wait never outlives the limit =="
lw_write() { # $1 until offset (s), $2 ts offset (s)
  printf 'until=%s reset=%s human=7:30am ts=%s\n' "$(( $(date +%s) + $1 ))" "$(( $(date +%s) + $1 - 240 ))" "$(( $(date +%s) + $2 ))" > "$STATE/$SID.limit-wait"
}
# Context below the line: past the limit-wait check the watcher has nothing to
# do and exits at once, so these cases test only how it treats the wait.
handoff() {
  printf 'pct=10 ts=%s\n' "$(date +%s)" > "$STATE/$SID.ctx"
  timeout 20 bash "$BIN/auto-handoff-watch.sh" "$SID" </dev/null >/dev/null 2>&1
}
setup; stub_mux; export MUX_LIVE_PANES="w1:p7" MUX_BUSY=0
lw_write -10 -3600
handoff
assert_no_file "stale (past until=): removed by the handoff watcher" "$STATE/$SID.limit-wait"
assert_contains "and it says so and proceeds" "$(LOG auto-handoff)" "DROP stale limit-wait (its wait is over); proceeding"
assert_not_contains "it does not skip the session" "$(LOG auto-handoff)" "SKIP session-limit resume pending"
sandbox_rm
setup; stub_mux; export MUX_LIVE_PANES="w1:p7" MUX_BUSY=0
lw_write 3600 -60
handoff
assert_file "active: kept" "$STATE/$SID.limit-wait"
assert_contains "active: the handoff watcher skips" "$(LOG auto-handoff)" "SKIP session-limit resume pending"
sandbox_rm
setup; stub_mux; export MUX_LIVE_PANES="w1:p7" MUX_BUSY=0
lw_write 3600 -60; date +%s > "$STATE/$SID.idle"
handoff
assert_no_file "a turn completed after it began: stale, removed" "$STATE/$SID.limit-wait"
sandbox_rm
setup; stub_mux; export MUX_LIVE_PANES="w1:p7" MUX_BUSY=0
printf 'until=0 human=unknown ts=1\n' > "$STATE/$SID.limit-wait"
handoff
assert_no_file "until=0 (an unparsed reset): stale, removed" "$STATE/$SID.limit-wait"
sandbox_rm
setup; stub_mux; export MUX_LIVE_PANES="w1:p7" MUX_BUSY=0
printf 'until=%s human=7:30am Asia/Jerusalem ts=%s\n' "$(( $(date +%s) + 70000 ))" "$(( $(date +%s) - 60 ))" > "$STATE/$SID.limit-wait"
handoff
assert_no_file "a file from the earlier watcher (no reset=, a day-long until=): stale, removed" "$STATE/$SID.limit-wait"
sandbox_rm
setup
lw_write -10 -3600
mkdir "$STATE/$SID.resume.lock"          # the earlier watcher's lock: no pid file
( . "$BIN/limit-lib.sh"; autodev_limit_wait_active "$STATE" "$SID" ); rc=$?
assert_eq "stale, under a pid-less lock from the earlier watcher: ignored" "$rc" 1
assert_file "and left alone while that waiter may still run" "$STATE/$SID.limit-wait"
touch -d '27 hours ago' "$STATE/$SID.resume.lock"
( . "$BIN/limit-lib.sh"; autodev_limit_wait_active "$STATE" "$SID" ); rc=$?
assert_no_file "a pid-less lock older than 26 hours is reclaimed and the file removed" "$STATE/$SID.limit-wait"
sandbox_rm

echo "== the resume lock: a stale wait is removed only under it, re-checked there =="
setup
lw_write -10 -3600
sleep 300 & holder=$!
( . "$BIN/limit-lib.sh"; autodev_resume_lock_take "$STATE" "$SID" "$holder" )
( . "$BIN/limit-lib.sh"; autodev_limit_wait_active "$STATE" "$SID" ); rc=$?
assert_eq "stale and a live resume cycle holds the lock: ignored" "$rc" 1
assert_file "and left for that cycle to remove" "$STATE/$SID.limit-wait"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
( . "$BIN/limit-lib.sh"; autodev_limit_wait_active "$STATE" "$SID" ); rc=$?
assert_eq "its holder dead: still ignored" "$rc" 1
assert_no_file "and the dead holder's lock is reclaimed to remove it" "$STATE/$SID.limit-wait"
# The condition changes while the reaper waits for the lock: a new resume cycle
# writes a fresh wait between the reaper's first read and its lock.
lw_write -10 -3600
( . "$BIN/limit-lib.sh"
  eval "orig_take() $(declare -f autodev_resume_lock_take | tail -n +2)"
  autodev_resume_lock_take(){
    printf 'until=%s reset=1 human=x ts=%s\n' "$(( $(date +%s) + 600 ))" "$(date +%s)" > "$1/$2.limit-wait"
    orig_take "$@"
  }
  autodev_limit_wait_active "$STATE" "$SID" ); rc=$?
assert_eq "a fresh wait written while the reaper took the lock: active" "$rc" 0
assert_file "and not removed" "$STATE/$SID.limit-wait"
assert_no_file "the lock is released" "$STATE/$SID.resume.lock"
sandbox_rm

echo "== flags clear on evidence; a dead pane is not UNREACHABLE =="
setup
printf 'screen presence unproved: pane w1:p7 lacks a live bottom-most ⟨cc:55555555⟩ before send\n' > "$STATE/$SID.unreachable"
cp "$FX/presence-clear.txt" "$SB/herdr/screen.txt"
timeout 60 bash "$BIN/auto-handoff-sweep.sh" </dev/null >/dev/null 2>&1
assert_no_file "clear, live composer: the sweep drops the flag" "$STATE/$SID.unreachable"
assert_contains "and logs it" "$(LOG auto-handoff)" "CLEAR unreachable: pane w1:p7 shows a clear, live composer"
sandbox_rm
setup
printf 'screen presence unproved: pane w1:p7 lacks a live bottom-most ⟨cc:55555555⟩ before send\n' > "$STATE/$SID.unreachable"
cp "$FX/limit-login-picker.txt" "$SB/herdr/screen.txt"
timeout 60 bash "$BIN/auto-handoff-sweep.sh" </dev/null >/dev/null 2>&1
assert_file "covered by a picker: the flag stays" "$STATE/$SID.unreachable"
sandbox_rm
setup
printf 'pct=50 ts=%s\n' "$(date +%s)" > "$STATE/$SID.ctx"
printf 'screen presence unproved: pane w1:p7 lacks a live bottom-most ⟨cc:55555555⟩ before send\n' > "$STATE/$SID.unreachable"
cp "$FX/presence-clear.txt" "$SB/herdr/screen.txt"
stub_watcher 2>/dev/null || true
timeout 60 bash "$BIN/auto-handoff-sweep.sh" </dev/null >/dev/null 2>&1
assert_no_file "over the threshold: the flag clears" "$STATE/$SID.unreachable"
assert_contains "and the same pass re-arms the handoff" "$(LOG auto-handoff)" "SWEEP re-arming watcher"
sandbox_rm

badge() { printf '{"session_id":"%s","model":{"display_name":"Opus"}}' "$SID" | bash "$BIN/cc-statusline.sh" 2>/dev/null; }
setup
printf 'registered pane w1:p9 is not live; no unique session match\n' > "$STATE/$SID.unreachable"
assert_contains "dead-pane flag: NO PANE badge" "$(badge)" "AUTO-HANDOFF: NO PANE"
assert_not_contains "dead-pane flag: not UNREACHABLE" "$(badge)" "UNREACHABLE"
printf 'no pane registered\n' > "$STATE/$SID.unreachable"
assert_contains "no pane registered: NO PANE badge" "$(badge)" "AUTO-HANDOFF: NO PANE"
printf 'screen presence unproved: pane w1:p7 lacks a live bottom-most ⟨cc:55555555⟩ before send\n' > "$STATE/$SID.unreachable"
assert_contains "covered live pane: still UNREACHABLE" "$(badge)" "AUTO-HANDOFF: UNREACHABLE"
rm -f "$STATE/$SID.unreachable"
lw_write 3600 -60
assert_contains "active wait: AUTO-RESUME badge with the time" "$(badge)" "AUTO-RESUME @ 7:30am "
lw_write -10 -3600
assert_not_contains "stale wait: no AUTO-RESUME badge" "$(badge)" "AUTO-RESUME"
assert_file "the status line only reads: it leaves the file to the watchers" "$STATE/$SID.limit-wait"
sandbox_rm

echo "== input classes: the paths limit-lib.sh reads and writes =="
setup
. "$BIN/limit-lib.sh"
for kind in dangling loop dir; do
  rm -rf "$STATE/$SID.limit-wait" "$SB/target-dir"
  case "$kind" in
    dangling) ln -s "$SB/no-such-file" "$STATE/$SID.limit-wait" ;;
    loop) ln -s "$STATE/$SID.limit-wait" "$STATE/$SID.limit-wait" ;;
    dir) mkdir "$SB/target-dir"; ln -s "$SB/target-dir" "$STATE/$SID.limit-wait" ;;
  esac
  autodev_limit_wait_active "$STATE" "$SID" 2>"$SB/err"; rc=$?
  assert_eq "limit-wait as a $kind symlink: not active" "$rc" 1
  assert_eq "limit-wait as a $kind symlink: no error output" "$(cat "$SB/err")" ""
  [ -L "$STATE/$SID.limit-wait" ] && left=link || left=gone
  assert_eq "limit-wait as a $kind symlink: the link is removed" "$left" gone
done
[ -d "$SB/target-dir" ]; assert_eq "a symlinked directory itself is left alone" "$?" 0
mkdir -p "$SB/cwd/~/st" && cd "$SB/cwd" || exit 1
printf 'until=%s reset=1 ts=1\n' "$(( $(date +%s) + 600 ))" > "$SB/cwd/~/st/$SID.limit-wait"
HOME="$SB/fakehome" autodev_limit_wait_active "~/st" "$SID"
assert_eq "a state path starting with an unexpanded ~ is used as given (writer and reader agree)" "$?" 0
assert_no_file "and nothing under \$HOME is touched" "$SB/fakehome"
mkdir -p rel/state
printf 'until=%s reset=1 ts=1\n' "$(( $(date +%s) + 600 ))" > "rel/state/$SID.limit-wait"
autodev_limit_wait_active rel/state "$SID"
assert_eq "a relative state path works" "$?" 0
autodev_needs_owner_set rel/state "$SID" "tab" Escape "screen"
assert_eq "needs-owner.list under a relative path" "$(wc -l < rel/state/needs-owner.list)" "1"
cd "$SKILL_DIR" || exit 1
odd="$SB/dir with 'single' and \"double\" quotes/state"
mkdir -p "$odd"
printf 'until=%s ts=1\n' "$(( $(date +%s) - 5 ))" > "$odd/$SID.limit-wait"
autodev_limit_wait_active "$odd" "$SID"
assert_eq "spaces and quotes: a stale wait is not active" "$?" 1
assert_no_file "spaces and quotes: and is removed" "$odd/$SID.limit-wait"
autodev_needs_owner_set "$odd" "$SID" "a 'quoted' tab" Escape "a \"screen\""
autodev_needs_owner_set "$odd" "$SID" "a 'quoted' tab" Escape "a \"screen\" again"
assert_eq "spaces and quotes: one needs-owner line" "$(wc -l < "$odd/needs-owner.list")" "1"
autodev_needs_owner_clear "$odd" "$SID"
assert_eq "spaces and quotes: cleared" "$(wc -l < "$odd/needs-owner.list")" "0"
locked="$SB/locked/state"; mkdir -p "$locked"
printf 'until=%s reset=1 ts=1\n' "$(( $(date +%s) + 600 ))" > "$locked/$SID.limit-wait"
chmod 000 "$SB/locked"
autodev_limit_wait_active "$locked" "$SID" 2>"$SB/err"; rc=$?
assert_eq "a parent the process cannot read: not active (the handoff is not held)" "$rc" 1
assert_eq "a parent the process cannot read: no error output" "$(cat "$SB/err")" ""
autodev_needs_owner_get "$locked" "$SID" >/dev/null 2>"$SB/err"; rc=$?
assert_eq "a parent the process cannot read: no needs-owner line read" "$rc" 1
chmod 755 "$SB/locked"
empty="$SB/empty/state"; mkdir -p "$empty"
autodev_needs_owner_clear "$empty" "$SID"; rc=$?
assert_eq "no list file (a glob that matches nothing): clear is a no-op" "$rc" 0
assert_no_file "and creates nothing" "$empty/needs-owner.list"
AUTODEV_HOME="$SB/empty-home" STATE="$SB/empty-home/state" bash "$BIN/auto-handoff-sweep.sh" > "$SB/out" 2>&1; rc=$?
assert_eq "a sweep over a state dir whose pane glob matches nothing: exit 0" "$rc" 0
assert_eq "and only its one-line summary" "$(cat "$SB/out")" "SWEEP-SUMMARY flags_set=0 flags_cleared=0 flags_present=0 pending_over_10m=0"
sandbox_rm

finish
