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
# $SB/herdr/cwd              the pane cwd `pane get` reports (absent: none)
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
      printf '{"result":{"pane":{"pane_id":"%s","agent_status":"%s","agent_session":{"value":"%s"},"cwd":"%s","scroll":{"offset_from_bottom":0}}}}\n' \
        "$3" "$(cat "$H/status")" "$(cat "$H/owner" 2>/dev/null)" "$(cat "$H/cwd" 2>/dev/null)" ;;
  "pane read")
      # hold-read: the read waits while it exists, so a watcher stays running.
      while [ -f "$H/hold-read" ]; do sleep 0.1; done
      n=$(( $(cat "$H/reads" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$H/reads"
      if [ -f "$H/from-read-2.txt" ] && [ "$n" -ge 2 ]; then cat "$H/from-read-2.txt"; else cat "$H/screen.txt"; fi
      # owner-after-read: "<n> <sid>" — another session takes the pane once read n is served.
      if [ -f "$H/owner-after-read" ] && [ "$n" -ge "$(cut -d' ' -f1 "$H/owner-after-read")" ]; then
        cut -d' ' -f2 "$H/owner-after-read" > "$H/owner"
      fi ;;
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
# wait_log returns at once on text an earlier step in the same sandbox already
# logged. After a repeated event, wait for the new count instead.
wait_count() { # $1 log, $2 regex (grep -E), $3 count, $4 timeout s
  local end=$(( $(date +%s) + ${4:-15} ))
  until [ "$(grep -cE -- "$2" "$AUTODEV_HOME/logs/$1.log" 2>/dev/null)" -ge "$3" ] 2>/dev/null \
    || [ "$(date +%s)" -ge "$end" ]; do sleep 0.2; done
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

# pin_tz HH:MM:SS: a fixed-offset zone in which the local clock reads that time
# now. It moves date, python and the watcher's log stamps together; a date shim
# on PATH cannot, because the detector reads python's clock.
pin_tz() {
  local want off a sign=-
  want=$(( 10#${1:0:2}*3600 + 10#${1:3:2}*60 + 10#${1:6:2} ))
  off=$(( ((want - $(date -u +%s) % 86400) % 86400 + 86400) % 86400 ))   # seconds east
  [ "$off" -gt 43200 ] && off=$(( off - 86400 ))
  [ "$off" -lt 0 ] && sign=+                     # POSIX TZ counts west as positive
  a=${off#-}
  printf 'PIN%s%d:%02d:%02d\n' "$sign" $(( a / 3600 )) $(( a % 3600 / 60 )) $(( a % 60 ))
}
# future_reset_case LABEL [SED] [RESET]: banner a minute ago, reset 3 minutes
# ahead; SED edits the screen, RESET (a date string) is the reset it must give.
future_reset_case() {
  local p=$1 lw w exp wpid reset_epoch
  setup
  live_screen -1 3 | sed -e "${2:-}" > "$SB/herdr/screen.txt"
  # Keep the date: from 23:57 the reset 3 minutes ahead falls tomorrow.
  reset_epoch=$(date -d "$(date -d '3 minutes' +'%Y-%m-%d %H:%M')" +%s)
  bash "$BIN/session-resume-watch.sh" "$SID" </dev/null >/dev/null 2>&1 &
  wpid=$!
  wait_log auto-resume "then sending continue"
  lw=$(cat "$STATE/$SID.limit-wait" 2>/dev/null)
  [ -z "${3:-}" ] || assert_contains "$p: the reset is $3" "$lw" " reset=$(date -d "$3" +%s) "
  assert_contains "$p: limit-wait until= is the reset plus the 4-minute buffer" "$lw" "until=$(( reset_epoch + 240 )) reset=$reset_epoch "
  assert_contains "$p: the log names the detection and the wait" "$(LOG auto-resume)" "LIMIT detected pane=w1:p7 dry=0 kind=5-hour"
  w=$(sed -n 's/.* wait=\([0-9]*\)s$/\1/p' "$AUTODEV_HOME/logs/auto-resume.log" | head -n1)
  exp=$(( reset_epoch + 240 - $(date +%s) ))
  [ -n "$w" ] && [ $(( w - exp )) -le 3 ] && [ $(( exp - w )) -le 3 ]
  assert_eq "$p: the logged wait is the time to reset+buffer (got ${w:-none}, expected ~$exp)" "$?" 0
  # The session prints new output under the banner: the wait ends, nothing typed.
  cp "$FX/limit-after-output.txt" "$SB/herdr/screen.txt"
  wait_exit "$wpid"
  assert_contains "$p: banner gone from the live area: the wait ends" "$(LOG auto-resume)" "ABORT banner gone from the live area during wait"
  assert_no_file "$p: and limit-wait is gone with it" "$STATE/$SID.limit-wait"
  assert_eq "$p: nothing typed during the wait" "$(typed)" ""
  sandbox_rm
}

echo "== watcher: a live banner with a future reset =="
future_reset_case "now"

echo "== watcher: across midnight, clock pinned to 23:58, 'resets 12:01am' is tomorrow =="
TZ=$(pin_tz 23:58:02)
# Drop the zone tag: it would read the reset in Asia/Jerusalem, not the pinned zone.
future_reset_case "23:58" 's/ (Asia\/Jerusalem)//' "tomorrow 00:01"
TZ=Asia/Jerusalem

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
assert_eq "stale, under a pid-less lock from the earlier watcher: its waiter may still run, active" "$rc" 0
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
assert_eq "stale and a live resume cycle holds the lock: that cycle owns it, active" "$rc" 0
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

echo "== log-only (I-571): the detector runs on the pane, nothing is typed =="
# Every mux function that can type into a pane records the call in sent.log, on
# top of the fake herdr's typed.log. send() is the watcher's own: its two log
# words (DRY would send, SENT:) are its record. A log-only run must leave all
# three empty.
record_sends() {
  cat >> "$BIN/mux-lib.sh" <<'REC'
mux_send_line(){ printf 'mux_send_line %s\n' "$*" >> "$SB/sent.log"; }
mux_send_key(){ printf 'mux_send_key %s\n' "$*" >> "$SB/sent.log"; }
mux_stage_text(){ printf 'mux_stage_text %s\n' "$*" >> "$SB/sent.log"; }
REC
  : > "$SB/sent.log"
}
sends() { # every send call this run made, from all three records
  cat "$SB/sent.log" "$SB/typed.log" 2>/dev/null
  grep -E 'DRY would send|SENT:' "$AUTODEV_HOME/logs/auto-resume.log" 2>/dev/null
}
screens_dir() { printf '%s/logs/auto-resume-screens' "$AUTODEV_HOME"; }
screens() { find "$(screens_dir)" -type f 2>/dev/null | wc -l; }
mode() { stat -c %a "$1" 2>/dev/null; }
# state_list: every path under $STATE with its mtime, to prove log-only writes none.
state_list() { find "$STATE" -printf '%p %T@\n' 2>/dev/null | sort; }

# The switch table. Columns: disable-auto-compact, auto-resume.log-only,
# disable-auto-resume, auto-handoff.armed; then what must happen on a live banner.
#   off     nothing runs: no log line, no limit-wait, nothing sent
#   logonly LOG-ONLY line and a saved screen; no limit-wait, no lock, nothing sent
#   wait    the armed path: LIMIT detected (dry=0|1) and a limit-wait; nothing sent yet
while read -r c l r a want; do
  case "$c" in '#'*|'') continue ;; esac
  row="compact=$c log-only=$l disable-resume=$r armed=$a"
  setup; record_sends
  rm -f "$STATE/auto-handoff.armed"
  [ "$c" = 1 ] && : > "$STATE/disable-auto-compact"
  [ "$l" = 1 ] && : > "$STATE/auto-resume.log-only"
  [ "$r" = 1 ] && : > "$STATE/disable-auto-resume"
  [ "$a" = 1 ] && : > "$STATE/auto-handoff.armed"
  live_screen -1 3 > "$SB/herdr/screen.txt"
  before=$(state_list)
  if [ "$want" = wait ]; then
    bash "$BIN/session-resume-watch.sh" "$SID" </dev/null >/dev/null 2>&1 &
    wpid=$!
    wait_log auto-resume "then sending continue"
    assert_contains "$row: the armed path detects" "$(LOG auto-resume)" "LIMIT detected pane=w1:p7 dry=$(( 1 - a ))"
    assert_file "$row: and waits (limit-wait)" "$STATE/$SID.limit-wait"
    cp "$FX/limit-after-output.txt" "$SB/herdr/screen.txt"
    wait_exit "$wpid"
    assert_not_contains "$row: no LOG-ONLY line" "$(LOG auto-resume)" "LOG-ONLY"
  else
    resume
    assert_no_file "$row: no limit-wait" "$STATE/$SID.limit-wait"
    assert_eq "$row: nothing under state/ written" "$(state_list)" "$before"
    if [ "$want" = logonly ]; then
      assert_contains "$row: LOG-ONLY detection logged" "$(LOG auto-resume)" "LOG-ONLY would send [continue] pane=w1:p7 kind=5-hour reset="
      assert_eq "$row: one screen saved" "$(screens)" 1
      assert_not_contains "$row: the armed path never ran" "$(LOG auto-resume)" "LIMIT detected"
    else
      assert_eq "$row: no log line at all" "$(LOG auto-resume)" ""
      assert_eq "$row: no screen saved" "$(screens)" 0
    fi
  fi
  assert_eq "$row: no send call" "$(sends)" ""
  sandbox_rm
done <<'TABLE'
# c l r a want
1 0 0 0 off
1 0 0 1 off
1 0 1 0 off
1 0 1 1 off
1 1 0 0 off
1 1 0 1 off
1 1 1 0 off
1 1 1 1 off
0 1 0 0 logonly
0 1 0 1 logonly
0 1 1 0 logonly
0 1 1 1 logonly
0 0 1 0 off
0 0 1 1 off
0 0 0 0 wait
0 0 0 1 wait
TABLE

# An armed wait already running when the owner sets log-only never types.
setup; record_sends
live_screen -1 3 > "$SB/herdr/screen.txt"
bash "$BIN/session-resume-watch.sh" "$SID" </dev/null >/dev/null 2>&1 &
wpid=$!
wait_log auto-resume "then sending continue"
assert_file "an armed wait is running" "$STATE/$SID.limit-wait"
: > "$STATE/auto-resume.log-only"
wait_exit "$wpid"
assert_contains "log-only set during an armed wait: it stops" "$(LOG auto-resume)" "ABORT log-only set during wait; no continue"
assert_no_file "and its limit-wait goes" "$STATE/$SID.limit-wait"
assert_eq "and no send call" "$(sends)" ""
sandbox_rm

echo "== log-only: what it logs and saves =="
setup; record_sends
: > "$STATE/auto-resume.log-only"; : > "$STATE/disable-auto-resume"
live_screen -1 3 > "$SB/herdr/screen.txt"
resume
line=$(grep -F 'LOG-ONLY would send' "$AUTODEV_HOME/logs/auto-resume.log")
assert_contains "the line carries the verdict fields" "$line" "human="
assert_contains "and the time it would send" "$line" " until="
assert_contains "and a UTC stamp" "$line" " at=20"
f=$(find "$(screens_dir)" -type f)
assert_contains "the screen file is <UTC stamp>-<sid>.txt" "${f##*/}" "Z-$SID.txt"
assert_contains "the log names the saved file" "$(LOG auto-resume)" "LOG-ONLY screen-saved ${f##*/}"
assert_eq "the saved screen is mode 600" "$(mode "$f")" 600
assert_eq "its directory is mode 700" "$(mode "$(screens_dir)")" 700
assert_eq "it is the screen the detector judged" "$(cat "$f")" "$(cat "$SB/herdr/screen.txt")"
resume
assert_eq "a second detection the same second gets its own file" "$(screens)" 2
assert_eq "no send call" "$(sends)" ""
sandbox_rm

setup; record_sends
: > "$STATE/auto-resume.log-only"
cp "$FX/limit-scrollback.txt" "$SB/herdr/screen.txt"
resume
assert_contains "a scrollback banner: LOG-ONLY NO-DETECT with the reason" "$(LOG auto-resume)" "LOG-ONLY NO-DETECT pane=w1:p7 reason=not-newest"
assert_not_contains "and no detection" "$(LOG auto-resume)" "LOG-ONLY would send"
assert_eq "and no screen" "$(screens)" 0
assert_eq "and no send call" "$(sends)" ""
sandbox_rm

setup; record_sends
: > "$STATE/auto-resume.log-only"
live_screen -1 3 > "$SB/herdr/screen.txt"
printf 'someone-else\n' > "$SB/herdr/owner"
printf '%s\n' someone-else > "$STATE/.paneowner-herdr-w1_p7"
printf 'pct=1 ts=%s\n' "$(( $(date +%s) + 5 ))" > "$STATE/someone-else.ctx"
resume
assert_contains "a pane not proved ours: skipped" "$(LOG auto-resume)" "LOG-ONLY SKIP pane=w1:p7 not proved ours"
assert_no_file "and its screen is never read" "$SB/herdr/reads"
assert_eq "and no send call" "$(sends)" ""
sandbox_rm

# Another session takes the pane during the recheck wait. The first read shows
# no banner; the second would show the new owner's live banner. Proved ours
# before the second read (case 1) and before it is judged (case 2), or skipped.
for n in 1 2; do
  setup; record_sends
  : > "$STATE/auto-resume.log-only"
  printf 'plain output, no banner\n' > "$SB/herdr/screen.txt"
  live_screen -1 3 > "$SB/herdr/from-read-2.txt"
  printf 'pct=1 ts=%s\n' "$(( $(date +%s) + 5 ))" > "$STATE/someone-else.ctx"
  printf '%s someone-else\n' "$n" > "$SB/herdr/owner-after-read"
  resume
  assert_contains "owner changes after read $n: skipped" "$(LOG auto-resume)" "LOG-ONLY SKIP pane=w1:p7 not proved ours (owner: someone-else)"
  assert_not_contains "owner changes after read $n: no detection logged" "$(LOG auto-resume)" "LOG-ONLY would send"
  assert_eq "owner changes after read $n: no screen file" "$(screens)" 0
  assert_eq "owner changes after read $n: reads taken" "$(cat "$SB/herdr/reads")" "$n"
  assert_eq "owner changes after read $n: no send call" "$(sends)" ""
  sandbox_rm
done

echo "== log-only: a pane under a no-save prefix is counted, not saved =="
for case_ in listed unknown-cwd unlisted; do
  setup; record_sends
  : > "$STATE/auto-resume.log-only"
  live_screen -1 3 > "$SB/herdr/screen.txt"
  printf '# local list\n\n  %s/work/held  \n' "$SB" > "$STATE/auto-resume.no-save"
  case "$case_" in
    listed)      printf '%s/work/held/sub' "$SB" > "$SB/herdr/cwd" ;;
    unknown-cwd) rm -f "$SB/herdr/cwd" ;;
    unlisted)    printf '%s/work/open' "$SB" > "$SB/herdr/cwd" ;;
  esac
  resume
  assert_contains "$case_: the detection is counted" "$(LOG auto-resume)" "LOG-ONLY would send"
  if [ "$case_" = unlisted ]; then
    assert_eq "$case_: its screen is saved" "$(screens)" 1
    assert_not_contains "$case_: not withheld" "$(LOG auto-resume)" "screen-withheld"
  else
    assert_contains "$case_: logged as withheld" "$(LOG auto-resume)" "LOG-ONLY screen-withheld pane=w1:p7"
    assert_eq "$case_: no screen file written" "$(screens)" 0
    assert_not_contains "$case_: the log names no cwd" "$(LOG auto-resume)" "$SB/work"
  fi
  assert_eq "$case_: no send call" "$(sends)" ""
  sandbox_rm
done

echo "== log-only: each record carries the proof fields on its own line =="
# The owner judges the 48-hour log-only run from these lines alone, so every
# detection and every NO-DETECT with a reason names: seat=, cwd=, screen_sha256=,
# banner=, verdict= and would_type=. Values are read back the way a shell would.
field() { # $1 log line, $2 key: the value of key=, shell-unquoted; exit 1 if absent
  python3 - "$1" "$2" <<'PY'
import shlex, sys
for tok in shlex.split(sys.argv[1]):
    k, _, v = tok.partition("=")
    if k == sys.argv[2]:
        print(v)
        sys.exit(0)
sys.exit(1)
PY
}
sha() { sha256sum | cut -d' ' -f1; }
banner_row() { grep -F 'hit your' "$1" | sed 's/^[[:space:]]*//'; }
# The text the armed path's send() types, read from the watcher itself, so
# would_type= cannot drift from it.
SEND_TEXT=$(sed -n 's/^send "\([^"]*\)"$/\1/p' "$SKILL_DIR/bin/session-resume-watch.sh")
assert_eq "the armed path sends one fixed text" "$SEND_TEXT" continue

setup; record_sends
: > "$STATE/auto-resume.log-only"
printf '%s/work/open dir' "$SB" > "$SB/herdr/cwd"
live_screen -1 3 > "$SB/herdr/screen.txt"
resume
line=$(grep -F 'LOG-ONLY would send' "$AUTODEV_HOME/logs/auto-resume.log")
f=$(find "$(screens_dir)" -type f)
assert_eq "detection: seat= is the session" "$(field "$line" seat)" "$SID"
assert_eq "detection: cwd= is the pane cwd" "$(field "$line" cwd)" "$SB/work/open dir"
assert_eq "detection: screen_sha256= is the hash of the screen judged (the saved file)" \
  "$(field "$line" screen_sha256)" "$(sha < "$f")"
assert_eq "detection: banner= is the matched banner line" "$(field "$line" banner)" "$(banner_row "$SB/herdr/screen.txt")"
assert_contains "detection: banner= is quoted" "$line" "banner='"
assert_eq "detection: verdict=live" "$(field "$line" verdict)" live
assert_eq "detection: would_type= is what send() would type" "$(field "$line" would_type)" "$SEND_TEXT"
assert_contains "detection: would_type= is quoted" "$line" "would_type='$SEND_TEXT'"
assert_eq "detection: still no send call" "$(sends)" ""
sandbox_rm

setup; record_sends
: > "$STATE/auto-resume.log-only"
printf '%s/work/open' "$SB" > "$SB/herdr/cwd"
cp "$FX/limit-scrollback.txt" "$SB/herdr/screen.txt"
resume
line=$(grep -F 'LOG-ONLY NO-DETECT' "$AUTODEV_HOME/logs/auto-resume.log")
assert_eq "NO-DETECT: seat=" "$(field "$line" seat)" "$SID"
assert_eq "NO-DETECT: cwd=" "$(field "$line" cwd)" "$SB/work/open"
assert_eq "NO-DETECT: screen_sha256= of the screen judged" \
  "$(field "$line" screen_sha256)" "$(printf '%s\n' "$(cat "$SB/herdr/screen.txt")" | sha)"
assert_eq "NO-DETECT: banner= is the banner line it saw" "$(field "$line" banner)" "$(banner_row "$SB/herdr/screen.txt")"
assert_eq "NO-DETECT: verdict=history:<the detector's reason>" "$(field "$line" verdict)" "history:not-newest"
field "$line" would_type >/dev/null
assert_eq "NO-DETECT: would_type= is present" "$?" 0
assert_eq "NO-DETECT: and empty: nothing would be typed" "$(field "$line" would_type)" ""
sandbox_rm

# Another session takes the pane just after a first read that detects: the
# cwd read next is the new owner's, so nothing is logged or kept.
setup; record_sends
: > "$STATE/auto-resume.log-only"
printf '%s/work/theirs' "$SB" > "$SB/herdr/cwd"
live_screen -1 3 > "$SB/herdr/screen.txt"
printf 'pct=1 ts=%s\n' "$(( $(date +%s) + 5 ))" > "$STATE/someone-else.ctx"
printf '1 someone-else\n' > "$SB/herdr/owner-after-read"
resume
assert_contains "owner changes after a detecting read: skipped" "$(LOG auto-resume)" "LOG-ONLY SKIP pane=w1:p7 not proved ours (owner: someone-else)"
assert_not_contains "owner changes after a detecting read: no detection logged" "$(LOG auto-resume)" "LOG-ONLY would send"
assert_not_contains "owner changes after a detecting read: the new owner's cwd is not logged" "$(LOG auto-resume)" "$SB/work/theirs"
assert_eq "owner changes after a detecting read: no screen file" "$(screens)" 0
assert_eq "owner changes after a detecting read: no send call" "$(sends)" ""
sandbox_rm

# A withheld pane: no cwd, no banner text, but the hash all the same.
setup; record_sends
: > "$STATE/auto-resume.log-only"
printf '%s/work/held\n' "$SB" > "$STATE/auto-resume.no-save"
printf '%s/work/held/sub' "$SB" > "$SB/herdr/cwd"
live_screen -1 3 > "$SB/herdr/screen.txt"
resume
line=$(grep -F 'LOG-ONLY would send' "$AUTODEV_HOME/logs/auto-resume.log")
assert_eq "withheld: seat=" "$(field "$line" seat)" "$SID"
assert_contains "withheld: cwd=withheld" "$line" " cwd=withheld "
assert_contains "withheld: banner=withheld" "$line" " banner=withheld "
assert_eq "withheld: screen_sha256= is still the screen's hash" \
  "$(field "$line" screen_sha256)" "$(printf '%s\n' "$(cat "$SB/herdr/screen.txt")" | sha)"
assert_eq "withheld: verdict=live" "$(field "$line" verdict)" live
assert_not_contains "withheld: the log names no cwd" "$(LOG auto-resume)" "$SB/work"
assert_not_contains "withheld: the log quotes no banner" "$(LOG auto-resume)" "hit your"
sandbox_rm

# A screen-save failure still hashes the screen.
setup; record_sends
: > "$STATE/auto-resume.log-only"
live_screen -1 3 > "$SB/herdr/screen.txt"
mkdir -p "$(dirname "$(screens_dir)")"; : > "$(screens_dir)"   # a file where the directory goes
resume
line=$(grep -F 'LOG-ONLY would send' "$AUTODEV_HOME/logs/auto-resume.log")
assert_contains "save failed: logged" "$(LOG auto-resume)" "LOG-ONLY screen-save-failed"
assert_eq "save failed: screen_sha256= is still the screen's hash" \
  "$(field "$line" screen_sha256)" "$(printf '%s\n' "$(cat "$SB/herdr/screen.txt")" | sha)"
sandbox_rm

# A prose row quoting a banner, hostile to a shell and longer than 200 chars:
# banner= reads back as the row (its first 200 characters), and evaluating the line runs nothing.
setup; record_sends
: > "$STATE/auto-resume.log-only"
long="You've hit your usage limit \$(touch $SB/pwned) \`touch $SB/pwned\` ; touch $SB/pwned '\" $(printf 'x%.0s' $(seq 1 300))"
{ printf '● %s\n\n' "$long"; sed -n '/^────/,$p' "$FX/limit-live.txt"; } > "$SB/herdr/screen.txt"
resume
line=$(grep -F 'LOG-ONLY NO-DETECT' "$AUTODEV_HOME/logs/auto-resume.log")
b=$(field "$line" banner)
assert_eq "hostile banner: read back as the row, cut to 200 chars" "$b" "$(python3 -c 'import sys; print(sys.argv[1][:200])' "● $long")"
assert_eq "hostile banner: verdict=history:not-newest" "$(field "$line" verdict)" "history:not-newest"
( eval "set -- ${line#*LOG-ONLY }" ) 2>/dev/null
assert_no_file "hostile banner: evaluating the line runs nothing" "$SB/pwned"
sandbox_rm

echo "== StopFailure hook: the second judge =="
# The launch is tested in its own section below: here the hook only logs.
sf() { printf '%s' "$1" | AUTODEV_NO_WATCHERS=1 bash "$BIN/cc-stopfailure-hook.sh"; }
setup
sf "{\"session_id\":\"$SID\",\"hook_event_name\":\"StopFailure\",\"error\":\"rate_limit\"}"
assert_eq "rate_limit: one STOPFAILURE line" \
  "$(grep -cE "^STOPFAILURE $SID rate_limit [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$" "$AUTODEV_HOME/logs/auto-resume.log")" 1
sf "{\"session_id\":\"$SID\",\"error\":\"billing_error\"}"
assert_contains "billing_error: logged too" "$(LOG auto-resume)" "STOPFAILURE $SID billing_error "
sf "{\"session_id\":\"$SID\",\"error\":\"server_error\"}"
sf '{"session_id":"../x","error":"rate_limit"}'
assert_eq "another error, or a bad session id: nothing" "$(wc -l < "$AUTODEV_HOME/logs/auto-resume.log")" 2
: > "$STATE/disable-auto-compact"
sf "{\"session_id\":\"$SID\",\"error\":\"rate_limit\"}"
assert_eq "disable-auto-compact: nothing" "$(wc -l < "$AUTODEV_HOME/logs/auto-resume.log")" 2
sandbox_rm

echo "== StopFailure launches the watcher (I-575) =="
# A limit stop fires StopFailure, never Stop, so this hook is what puts the
# watcher on a live banner. Its own session id: the checks count watcher
# processes by command line.
SID_A=$SID
SID=57557557-5755-5755-5755-$(printf '%012d' "$$")
sfh() { # $1 error (default rate_limit): the hook, as Claude Code runs it
  printf '{"session_id":"%s","transcript_path":"/x/%s.jsonl","hook_event_name":"StopFailure","error":"%s","last_assistant_message":"API Error"}' \
    "$SID" "$SID" "${1:-rate_limit}" | bash "$BIN/cc-stopfailure-hook.sh"
}
# One watcher per session id: its $(...) subshells carry its command line too.
watchers() {
  local p; p=$(pgrep -f "session-resume-watch\\.sh $SID\$" | tr '\n' ',')
  if [ -n "$p" ]; then ps -o sid= -p "${p%,}" | sort -u | wc -l; else echo 0; fi
}
wait_watchers() { # $1 count, $2 label: bounded; the watchers this test started reach it
  local end=$(( $(date +%s) + 30 ))
  until [ "$(watchers)" = "$1" ] || [ "$(date +%s)" -ge "$end" ]; do sleep 0.1; done
  assert_eq "$2" "$(watchers)" "$1"
}
lines() { grep -c -- "$1" "$AUTODEV_HOME/logs/auto-resume.log" 2>/dev/null; }
sent_calls() { wc -l < "$SB/sent.log"; }

# First use, with the switches as the owner runs the proof: log-only on, the
# watcher off, armed. One live banner: one detection with every proof field,
# verdict=live, nothing typed, and the report pairs it true.
setup; record_sends
: > "$STATE/auto-resume.log-only"; : > "$STATE/disable-auto-resume"
printf '%s/work/live' "$SB" > "$SB/herdr/cwd"
live_screen -1 3 > "$SB/herdr/screen.txt"
sfh
wait_log auto-resume "LOG-ONLY would send"
wait_watchers 0 "first use: the launched watcher has ended"
assert_eq "first use: one STOPFAILURE line" "$(lines "^STOPFAILURE $SID rate_limit ")" 1
assert_eq "first use: one STOPFAILURE-LAUNCH line" "$(lines "^STOPFAILURE-LAUNCH $SID ")" 1
assert_eq "first use: one detection" "$(lines 'LOG-ONLY would send')" 1
line=$(grep -F 'LOG-ONLY would send' "$AUTODEV_HOME/logs/auto-resume.log")
f=$(find "$(screens_dir)" -type f)
assert_eq "first use: seat=" "$(field "$line" seat)" "$SID"
assert_eq "first use: cwd=" "$(field "$line" cwd)" "$SB/work/live"
assert_eq "first use: screen_sha256= of the saved screen" "$(field "$line" screen_sha256)" "$(sha < "$f")"
assert_eq "first use: banner=" "$(field "$line" banner)" "$(banner_row "$SB/herdr/screen.txt")"
assert_eq "first use: verdict=live" "$(field "$line" verdict)" live
assert_eq "first use: would_type=" "$(field "$line" would_type)" "$SEND_TEXT"
assert_eq "first use: the mux send mock was called 0 times" "$(sent_calls)" 0
assert_eq "first use: nothing typed, nothing sent" "$(sends)" ""
assert_no_file "first use: no limit-wait" "$STATE/$SID.limit-wait"
assert_lock_absent "first use: no resume lock" "$STATE/$SID.resume.lock"
out=$(python3 "$BIN/auto-resume-report.py" --now "$(( $(date +%s) + 1 ))" --days 1 --fixtures "$FX")
assert_contains "first use: the report row is true" \
  "$(printf '%s\n' "$out" | sed -n '/^per detection/,$p' | grep -F " $SID " | tr -s ' ')" " $SID true "
assert_contains "first use: true stops detected 1 of 1" "$out" "true stops detected: 1 of 1 "
assert_contains "first use: B is live from today" "$out" "StopFailure launch live since: $(date -u +%Y-%m-%d) "
assert_contains "first use: a screen no fixture has is the first real stop" "$out" " $SID screen_sha256=$(sha < "$f")"
sandbox_rm

# History only: the banner sits in the scrollback. verdict=history:<reason>, no detection.
setup; record_sends
: > "$STATE/auto-resume.log-only"; : > "$STATE/disable-auto-resume"
cp "$FX/limit-scrollback.txt" "$SB/herdr/screen.txt"
sfh
wait_log auto-resume "LOG-ONLY NO-DETECT"
wait_watchers 0 "history: the launched watcher has ended"
line=$(grep -F 'LOG-ONLY NO-DETECT' "$AUTODEV_HOME/logs/auto-resume.log")
assert_eq "history: verdict=history:not-newest" "$(field "$line" verdict)" "history:not-newest"
assert_eq "history: no detection" "$(lines 'LOG-ONLY would send')" 0
assert_eq "history: the mux send mock was called 0 times" "$(sent_calls)" 0
assert_eq "history: nothing typed, nothing sent" "$(sends)" ""
out=$(python3 "$BIN/auto-resume-report.py" --now "$(( $(date +%s) + 1 ))" --days 1 --fixtures "$FX")
assert_contains "history: true stops detected 0 of 1" "$out" "true stops detected: 0 of 1 "
assert_contains "history: the stop is missed" "$(printf '%s\n' "$out" | grep -E "^  $SID " | tr -s ' ')" " 0 0 1"
assert_contains "history: no real stop" "$out" "first real stop: none yet"
sandbox_rm

# The switches, read by the hook as the watcher reads them.
setup; record_sends
: > "$STATE/disable-auto-compact"; : > "$STATE/auto-resume.log-only"
live_screen -1 3 > "$SB/herdr/screen.txt"
sfh; sleep 1
assert_eq "disable-auto-compact: no log line at all" "$(LOG auto-resume)" ""
assert_eq "disable-auto-compact: no watcher" "$(watchers)" 0
rm -f "$STATE/disable-auto-compact" "$STATE/auto-resume.log-only"; : > "$STATE/disable-auto-resume"
sfh; sleep 1
assert_eq "disable-auto-resume, no log-only: the STOPFAILURE line" "$(lines "^STOPFAILURE $SID ")" 1
assert_eq "disable-auto-resume, no log-only: no launch" "$(lines '^STOPFAILURE-')" 0
assert_eq "disable-auto-resume, no log-only: no watcher ran" "$(lines "\\[$SID\\]")" 0
rm -f "$STATE/disable-auto-resume"; : > "$STATE/auto-resume.log-only"
sfh server_error; sleep 1
assert_eq "another error: no launch" "$(lines '^STOPFAILURE-')" 0
sfh billing_error
wait_log auto-resume "LOG-ONLY would send"
wait_watchers 0 "billing_error: the launched watcher has ended"
assert_eq "billing_error: launched" "$(lines "^STOPFAILURE-LAUNCH $SID ")" 1
assert_eq "all switches: nothing sent" "$(sends)" ""
sandbox_rm

# No double watcher. A StopFailure-launched watcher holds the lock it was
# started under for its whole run; a second StopFailure then starts none.
setup; record_sends
: > "$STATE/auto-resume.log-only"; : > "$STATE/disable-auto-resume"
live_screen -1 3 > "$SB/herdr/screen.txt"
: > "$SB/herdr/hold-read"
sfh
wait_watchers 1 "double: the first StopFailure starts a watcher"
sfh
sleep 1
assert_eq "double: still one watcher after a second StopFailure" "$(watchers)" 1
assert_eq "double: one launch" "$(lines "^STOPFAILURE-LAUNCH $SID ")" 1
assert_eq "double: the second is logged as not launched" "$(lines "^STOPFAILURE-NOLAUNCH $SID watcher-running ")" 1
rm -f "$SB/herdr/hold-read"
wait_watchers 0 "double: the watcher has ended"
assert_eq "double: one detection" "$(lines 'LOG-ONLY would send')" 1
# The lock goes with the watcher: the next stop starts one again.
# The first stop's lines are already in the log: wait for the second of each,
# so the new watcher has started and detected before waiting for it to end.
sfh
wait_count auto-resume "^STOPFAILURE-LAUNCH $SID " 2
wait_count auto-resume 'LOG-ONLY would send' 2
wait_watchers 0 "double: the next stop's watcher has ended"
assert_eq "double: the next stop launches" "$(lines "^STOPFAILURE-LAUNCH $SID ")" 2
assert_eq "double: and detects" "$(lines 'LOG-ONLY would send')" 2
# A watcher the Stop hook started (no lock): found by its command line.
: > "$SB/herdr/hold-read"
setsid "$BIN/session-resume-watch.sh" "$SID" </dev/null >/dev/null 2>&1 &
wait_watchers 1 "double: a Stop-launched watcher runs"
sfh
sleep 1
assert_eq "double: a StopFailure beside it starts none" "$(watchers)" 1
assert_eq "double: logged as not launched" "$(lines "^STOPFAILURE-NOLAUNCH $SID watcher-running ")" 2
rm -f "$SB/herdr/hold-read"
wait_watchers 0 "double: the Stop-launched watcher has ended"
assert_eq "double: nothing sent" "$(sends)" ""
sandbox_rm
SID=$SID_A

echo "== auto-resume-report.py: the days of proof =="
setup
REP="$BIN/auto-resume-report.py"
NOW=$(date -u -d '2026-11-22 12:00:00' +%s)
lo() { # $1 sid, $2 UTC time, $3 what
  printf '2026.11.22 00.00.00 [%s] LOG-ONLY %s at=%s\n' "$1" "$3" "$(date -u -d "$2" +%Y-%m-%dT%H:%M:%SZ)"
}
{
  lo aaa '2026-11-22 10:00:00' 'would send [continue] pane=w1:p1 kind=5-hour'
  lo aaa '2026-11-22 10:00:00' 'screen-saved x.txt'
  printf 'STOPFAILURE aaa rate_limit 2026-11-22T09:57:00Z\n'
  lo bbb '2026-11-21 08:00:00' 'would send [continue] pane=w1:p2 kind=5-hour'
  lo bbb '2026-11-21 08:00:00' 'screen-withheld pane=w1:p2'
  printf 'STOPFAILURE ccc rate_limit 2026-11-21T09:00:00Z\n'
  printf 'STOPFAILURE bbb rate_limit 2026-11-21T07:50:00Z\n'
  lo ddd '2026-11-10 08:00:00' 'would send [continue] pane=w1:p3 kind=5-hour'
  lo ddd '2026-11-10 08:00:00' 'screen-saved y.txt'
  printf '2026.11.22 00.00.00 [eee] LOG-ONLY NO-DETECT pane=w1:p4 reason=not-newest at=2026-11-22T11:00:00Z\n'
} > "$AUTODEV_HOME/logs/auto-resume.log"
out=$(python3 "$REP" --now "$NOW")
assert_contains "default window is 7 days" "$out" "log-only report: 7 day(s)"
assert_contains "detections in the window" "$out" "detections: 2"
assert_contains "screens saved" "$out" "screens saved: 1"
assert_contains "screens withheld" "$out" "screens withheld: 1"
assert_contains "StopFailure events" "$out" "StopFailure events: 3"
assert_contains "a detection 3 min after its StopFailure is matched; 10 min is not" "$out" "detections with no StopFailure within 5 min: 1"
assert_not_contains "the unmatched detection of a withheld seat is counted, not listed" "$out" "  2026-11-21T08:00:00Z bbb"
assert_contains "StopFailure events no detection saw" "$out" "StopFailure events with no detection within 5 min: 2"
out=$(AUTODEV_LOGONLY_DAYS=30 python3 "$REP" --now "$NOW")
assert_contains "AUTODEV_LOGONLY_DAYS sets the window" "$out" "log-only report: 30 day(s)"
assert_contains "and the older detection counts" "$out" "detections: 3"
out=$(AUTODEV_LOGONLY_DAYS=30 python3 "$REP" --now "$NOW" --days 1)
assert_contains "--days beats the env" "$out" "detections: 1"
AUTODEV_LOGONLY_DAYS=0 python3 "$REP" --now "$NOW" >/dev/null 2>&1
assert_eq "a days setting of 0 is refused" "$?" 1
sum_before=$(md5sum < "$AUTODEV_HOME/logs/auto-resume.log")
python3 "$REP" >/dev/null
assert_eq "the report only reads" "$(md5sum < "$AUTODEV_HOME/logs/auto-resume.log")" "$sum_before"
# A pair split by a window edge is matched both ways; only its in-window half is counted.
{
  lo fff '2026-11-21 11:58:00' 'would send [continue] pane=w1:p5 kind=5-hour'   # 2 min before the start
  printf 'STOPFAILURE fff rate_limit 2026-11-21T12:01:00Z\n'                    # 1 min after it
} > "$AUTODEV_HOME/logs/auto-resume.log"
out=$(python3 "$REP" --now "$NOW" --days 1)
assert_contains "window start: the StopFailure is counted" "$out" "StopFailure events: 1"
assert_contains "window start: the detection is not" "$out" "detections: 0"
assert_contains "window start: no unmatched detection" "$out" "detections with no StopFailure within 5 min: 0"
assert_contains "window start: no unmatched StopFailure" "$out" "StopFailure events with no detection within 5 min: 0"
{
  printf 'STOPFAILURE ggg rate_limit 2026-11-22T11:59:00Z\n'                    # 1 min before the end
  lo ggg '2026-11-22 12:02:00' 'would send [continue] pane=w1:p6 kind=5-hour'   # 2 min after it
} > "$AUTODEV_HOME/logs/auto-resume.log"
out=$(python3 "$REP" --now "$NOW" --days 1)
assert_contains "window end: the StopFailure is counted" "$out" "StopFailure events: 1"
assert_contains "window end: the detection is not" "$out" "detections: 0"
assert_contains "window end: no unmatched detection" "$out" "detections with no StopFailure within 5 min: 0"
assert_contains "window end: no unmatched StopFailure" "$out" "StopFailure events with no detection within 5 min: 0"

echo "== auto-resume-report.py: one row per detection, paired true / false / missed =="
SHA_H=$(printf 'h' | sha256sum | cut -d' ' -f1)
SHA_J=$(printf 'j' | sha256sum | cut -d' ' -f1)
proof() { # $1 sid, $2 sha, $3 cwd field, $4 banner field: the proof fields as the watcher writes them
  printf "pane=w1:p1 kind=5-hour seat=%s cwd=%s screen_sha256=%s banner=%s verdict=live would_type='continue'" "$1" "$3" "$2" "$4"
}
{
  lo hhh '2026-11-22 10:00:00' "would send [continue] $(proof hhh "$SHA_H" "'/work/a b'" "'⎿  You'\\''ve hit your 5-hour limit · resets 7:30am'")"
  printf 'STOPFAILURE hhh rate_limit 2026-11-22T09:58:00Z\n'
  lo iii '2026-11-22 11:00:00' "would send [continue] $(proof iii "$SHA_H" "'/work/c'" "'⎿  You'\\''ve hit your 5-hour limit · resets 9am'")"
  lo jjj '2026-11-22 10:30:00' "would send [continue] $(proof jjj "$SHA_J" withheld withheld)"
  lo jjj '2026-11-22 10:30:00' 'screen-withheld pane=w1:p1'
  printf 'STOPFAILURE jjj rate_limit 2026-11-22T10:29:00Z\n'
  printf 'STOPFAILURE jjj rate_limit 2026-11-22T06:00:00Z\n'
  printf 'STOPFAILURE kkk billing_error 2026-11-22T08:00:00Z\n'
  lo lll '2026-11-22 11:30:00' 'NO-DETECT pane=w1:p9 reason=not-newest seat=lll cwd=withheld screen_sha256=0 banner=withheld verdict=history:not-newest would_type='\'\'
} > "$AUTODEV_HOME/logs/auto-resume.log"
out=$(python3 "$REP" --now "$NOW" --days 1)
row() { printf '%s\n' "$out" | grep -E "^  $1 " ; }
# drow <time> <sid>: that detection-table row, runs of spaces squeezed to one.
drow() { printf '%s\n' "$out" | sed -n '/^per detection/,$p' | grep -E "^  $1 +$2 " | tr -s ' '; }
assert_eq "seat table: a detection with a StopFailure is true" "$(row hhh | tr -s ' ')" " hhh 1 0 0"
assert_eq "seat table: a detection without one is false" "$(row iii | tr -s ' ')" " iii 0 1 0"
assert_eq "seat table: a StopFailure no detection saw is missed" "$(row kkk | tr -s ' ')" " kkk 0 0 1"
assert_eq "seat table: a withheld seat shows counts only" "$(row jjj | tr -s ' ')" " jjj 1 0 1 withheld: counts only"
r=$(drow 2026-11-22T10:00:00Z hhh)
assert_contains "detection row: pair true, with its StopFailure" "$r" " true 2026-11-22T09:58:00Z rate_limit "
assert_contains "detection row: verdict" "$r" " live "
assert_contains "detection row: would_type, quoted" "$r" " 'continue' "
assert_contains "detection row: screen_sha256" "$r" " $SHA_H "
assert_contains "detection row: cwd, quoted" "$r" " '/work/a b' "
assert_contains "detection row: banner, quoted" "$r" "'⎿ You'\"'\"'ve hit your 5-hour limit · resets 7:30am'"
r=$(drow 2026-11-22T11:00:00Z iii)
assert_contains "detection row: pair false, no StopFailure" "$r" " false - "
r=$(drow 2026-11-22T08:00:00Z kkk)
assert_contains "missed row: the StopFailure no detection saw" "$r" " missed 2026-11-22T08:00:00Z billing_error "
assert_eq "withheld seat: no detection or missed row" \
  "$(printf '%s\n' "$out" | sed -n '/^per detection/,$p' | grep -cE '^  2026-[^ ]+ +jjj ')" 0
assert_not_contains "withheld seat: its hash is not shown" "$out" "$SHA_J"
assert_eq "a NO-DETECT is no detection row" "$(printf '%s\n' "$out" | grep -c ' lll ')" 0
# A withheld seat's unmatched events: counted in both totals, never listed.
{
  lo sss '2026-11-22 10:00:00' "would send [continue] pane=w1:p88 kind=5-hour reset=1 $(proof sss "$SHA_J" withheld withheld | sed 's/^pane=w1:p1 kind=5-hour //')"
  lo sss '2026-11-22 10:00:00' 'screen-withheld pane=w1:p88'
  printf 'STOPFAILURE sss billing_error 2026-11-22T08:00:00Z\n'
  lo ttt '2026-11-22 11:00:00' "would send [continue] $(proof ttt "$SHA_H" "'/work/t'" "'b'")"
  printf 'STOPFAILURE ttt rate_limit 2026-11-22T07:00:00Z\n'
} > "$AUTODEV_HOME/logs/auto-resume.log"
out=$(python3 "$REP" --now "$NOW" --days 1)
assert_contains "withheld unmatched: both detections counted" "$out" "detections with no StopFailure within 5 min: 2"
assert_contains "withheld unmatched: both StopFailures counted" "$out" "StopFailure events with no detection within 5 min: 2"
assert_not_contains "withheld unmatched: no pane id of the withheld seat" "$out" "w1:p88"
assert_not_contains "withheld unmatched: no event line for the withheld seat" "$out" "Z sss "
assert_contains "withheld unmatched: an open seat's detection is listed" "$out" "  2026-11-22T11:00:00Z ttt "
assert_contains "withheld unmatched: an open seat's StopFailure is listed" "$out" "  2026-11-22T07:00:00Z ttt rate_limit"
sandbox_rm

echo "== auto-resume-report.py: B's first day, true stops, the first real stop =="
setup
REP="$BIN/auto-resume-report.py"
SHA_FX=$(printf '%s\n' "$(cat "$FX/limit-live.txt")" | sha256sum | cut -d' ' -f1)
SHA_R=$(printf 'real' | sha256sum | cut -d' ' -f1)
{
  printf 'STOPFAILURE mmm rate_limit 2026-11-20T09:00:00Z\n'                    # out of the window
  printf 'STOPFAILURE nnn rate_limit 2026-11-22T09:00:00Z\n'
  printf 'STOPFAILURE-LAUNCH nnn 2026-11-22T09:00:00Z\n'
  lo nnn '2026-11-22 09:00:03' "would send [continue] $(proof nnn "$SHA_FX" "'/w'" "'b'")"   # a fixture's screen
  printf 'STOPFAILURE ooo rate_limit 2026-11-22T10:00:00Z\n'
  lo ooo '2026-11-22 10:00:03' "would send [continue] $(proof ooo "$SHA_R" "'/w'" "'b'")"    # no launch line
  printf 'STOPFAILURE ppp rate_limit 2026-11-22T11:00:00Z\n'
  printf 'STOPFAILURE-LAUNCH ppp 2026-11-22T11:00:00Z\n'
  lo ppp '2026-11-22 11:00:03' "would send [continue] $(proof ppp "$SHA_R" "'/w'" "'b'")"
  printf 'STOPFAILURE qqq rate_limit 2026-11-22T11:30:00Z\n'
  printf 'STOPFAILURE-NOLAUNCH qqq watcher-running 2026-11-22T11:30:00Z\n'
} > "$AUTODEV_HOME/logs/auto-resume.log"
out=$(python3 "$REP" --now "$NOW" --days 1 --fixtures "$FX")
assert_contains "true stops: those with a detection, of all in the window" "$out" "true stops detected: 3 of 4 "
assert_contains "B live since: the first STOPFAILURE-LAUNCH" "$out" \
  "StopFailure launch live since: 2026-11-22 (first STOPFAILURE-LAUNCH 2026-11-22T09:00:00Z"
assert_contains "first real stop: launched from StopFailure, a screen no fixture has" "$out" \
  "first real stop: 2026-11-22T11:00:03Z ppp screen_sha256=$SHA_R"
assert_contains "a NOLAUNCH line is no StopFailure event" "$out" "StopFailure events: 4"
out=$(python3 "$REP" --now "$NOW" --days 1 --fixtures "$SB/no-such-dir")
assert_contains "no fixtures: the first real stop is unknown" "$out" "first real stop: unknown"
grep -v ppp "$AUTODEV_HOME/logs/auto-resume.log" > "$SB/log2"
out=$(python3 "$REP" --log "$SB/log2" --now "$NOW" --days 1 --fixtures "$FX")
assert_contains "a fixture's screen is no real stop" "$out" "first real stop: none yet"
printf 'STOPFAILURE rrr rate_limit 2026-11-22T11:00:00Z\n' > "$SB/log3"
out=$(python3 "$REP" --log "$SB/log3" --now "$NOW" --days 1 --fixtures "$FX")
assert_contains "no launch yet: B is not live" "$out" "StopFailure launch live since: never"
# A withheld seat's first launch and first real stop: counted, never its time, sid or hash.
SHA_W=$(printf 'withheld-real' | sha256sum | cut -d' ' -f1)
{
  printf 'STOPFAILURE www rate_limit 2026-11-22T08:41:17Z\n'
  printf 'STOPFAILURE-LAUNCH www 2026-11-22T08:41:17Z\n'
  lo www '2026-11-22 08:41:19' "would send [continue] $(proof www "$SHA_W" withheld withheld)"
  lo www '2026-11-22 08:41:19' 'screen-withheld pane=w1:p1'
  cat "$AUTODEV_HOME/logs/auto-resume.log"
} > "$SB/log4"
out=$(python3 "$REP" --log "$SB/log4" --now "$NOW" --days 1 --fixtures "$FX")
assert_contains "withheld first stop: a real stop is still reported" "$out" \
  "first real stop: yes (withheld seat; counts only)"
assert_contains "withheld first launch: B's first day still shows" "$out" \
  "StopFailure launch live since: 2026-11-22 (first STOPFAILURE-LAUNCH from a withheld seat; proof days count from then)"
assert_not_contains "withheld first stop: no hash" "$out" "$SHA_W"
assert_not_contains "withheld first stop: no launch time" "$out" "08:41:17"
assert_not_contains "withheld first stop: no detection time" "$out" "08:41:19"
assert_eq "withheld first stop: no sid outside the seat table" \
  "$(printf '%s\n' "$out" | grep -v -E '^  www +[0-9]+ +[0-9]+ +[0-9]+ +withheld: counts only$' | grep -c www)" 0
sandbox_rm

finish
