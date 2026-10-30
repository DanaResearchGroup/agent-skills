#!/usr/bin/env bash
# A request pending >= 30 min with the watcher only ever DEFERring means the
# session is stuck (busy pane / open prompt). Nobody was told. The sweeper now
# pages the user once per request.

. "$(dirname "$0")/lib.sh"

SID=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa

setup() {
  sandbox_new; stub_mux; stub_watcher; arm
  session_new "$SID" 12 "w1:p1"
  export MUX_LIVE_PANES="w1:p1" MUX_BUSY=0
  HF="$AUTODEV_HOME/handoffs/2026.01.01 00.00.00 handoff-h.md"
  printf 'h\n' > "$HF"; printf '%s\n' "$HF" > "$AUTODEV_HOME/handoffs/.latest.$SID"
  # notify-send stub on PATH: one line per page
  mkdir -p "$SB/fakebin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$SB/pages.log"\n' > "$SB/fakebin/notify-send"
  chmod +x "$SB/fakebin/notify-send"; : > "$SB/pages.log"
  export AUTODEV_PAGE_CMD="$SB/fakebin/notify-send"
}
sweep() { bash "$BIN/auto-handoff-sweep.sh" >/dev/null 2>&1; }
pages() { wc -l < "$SB/pages.log" | tr -d ' '; }
request() { : > "$STATE/$SID.compact-request"; touch -d "$1" "$STATE/$SID.compact-request"; }

setup
request '40 minutes ago'; : > "$STATE/$SID.deferred"
sweep
assert_eq "a 40-minute request that was only DEFERred pages once" "$(pages)" 1
assert_contains "the page names the session" "$(cat "$SB/pages.log")" "$SID"
sweep
assert_eq "the next sweep does not page again for the same request" "$(pages)" 1
rm -f "$STATE/$SID.compact-request"; request '35 minutes ago'
sweep
assert_eq "a NEW request that also gets stuck pages again" "$(pages)" 2
sandbox_rm

setup
request '10 minutes ago'; : > "$STATE/$SID.deferred"
sweep
assert_eq "a request pending < 30 min does not page" "$(pages)" 0
sandbox_rm

setup
request '40 minutes ago'
sweep
assert_eq "no DEFER recorded -> no page" "$(pages)" 0
sandbox_rm

setup
request '40 minutes ago'; : > "$STATE/$SID.deferred"
AUTODEV_PAGE_CMD=/nonexistent/notifier bash "$BIN/auto-handoff-sweep.sh" >/dev/null 2>&1
assert_contains "without notify-send the page falls back to the log" "$(cat "$AUTODEV_HOME/logs/auto-handoff.log")" "PAGE"
sandbox_rm

echo "== dedupe =="
# A DEFER re-file keeps the request's mtime exactly: still ONE page.
setup
request '@1000000000.250000000'; : > "$STATE/$SID.deferred"
sweep
assert_eq "old request pages" "$(pages)" 1
touch -d '@1000000000.250000000' "$STATE/$SID.compact-request"   # re-filed with its original mtime
touch "$STATE/$SID.deferred"
sweep
assert_eq "re-file with the same mtime does not page again" "$(pages)" 1
# A different request filed in the same SECOND is a different request.
touch -d '@1000000000.750000000' "$STATE/$SID.compact-request"
touch "$STATE/$SID.deferred"
sweep
assert_eq "a new request in the same second pages again" "$(pages)" 2
sandbox_rm

# A DEFER recorded before this request was filed says nothing about it.
setup
: > "$STATE/$SID.deferred"; touch -d '2 hours ago' "$STATE/$SID.deferred"
request '40 minutes ago'
sweep
assert_eq "a DEFER older than the request does not page it" "$(pages)" 0
sandbox_rm

# Two sweeps racing on the same request must page once.
setup
printf '#!/usr/bin/env bash\nsleep 1\nprintf "%%s\\n" "$*" >> "$SB/pages.log"\n' > "$SB/fakebin/notify-send"
request '40 minutes ago'; : > "$STATE/$SID.deferred"
bash "$BIN/auto-handoff-sweep.sh" >/dev/null 2>&1 &
bash "$BIN/auto-handoff-sweep.sh" >/dev/null 2>&1 &
wait; sleep 2
assert_eq "two concurrent sweeps page once" "$(pages)" 1
sandbox_rm

echo "== paging failures =="
# A notifier that fails (no display / bus under a timer) must not turn into a page per sweep.
setup
printf '#!/usr/bin/env bash\nexit 1\n' > "$SB/fakebin/notify-send"
request '40 minutes ago'; : > "$STATE/$SID.deferred"
sweep; sweep; sweep
assert_eq "a failing notifier still produces exactly one PAGE line" "$(grep -c ' PAGE autodev:' "$AUTODEV_HOME/logs/auto-handoff.log")" 1
assert_contains "and the log says the notification failed" "$(cat "$AUTODEV_HOME/logs/auto-handoff.log")" "notify failed"
sandbox_rm

# A notifier that hangs cannot wedge the sweeper.
setup
printf '#!/usr/bin/env bash\nsleep 60\n' > "$SB/fakebin/notify-send"
request '40 minutes ago'; : > "$STATE/$SID.deferred"
t0=$(date +%s); AUTODEV_PAGE_TIMEOUT=2 sweep; t1=$(date +%s)
assert_eq "a hanging notifier is cut off" "$([ $(( t1 - t0 )) -lt 30 ] && echo bounded || echo hung)" bounded
sandbox_rm

# If the page cannot be RECORDED, do not page at all (it would repeat every sweep).
setup
mkdir "$STATE/$SID.paged"
request '40 minutes ago'; : > "$STATE/$SID.deferred"
sweep; sweep
assert_eq "an unrecordable page is not sent" "$(pages)" 0
assert_contains "and the log says why" "$(cat "$AUTODEV_HOME/logs/auto-handoff.log")" "cannot record"
sandbox_rm

# No flock on the box: still pages once across sweeps.
setup
request '40 minutes ago'; : > "$STATE/$SID.deferred"
AUTODEV_NO_FLOCK=1 sweep; AUTODEV_NO_FLOCK=1 sweep
assert_eq "without flock, sequential sweeps still page once" "$(pages)" 1
sandbox_rm

# Reload paging must precede reachability checks, and use the same per-marker
# dedupe as requests. A missing pane cannot suppress the only alert.
setup
touch -d '2 hours ago' "$AUTODEV_HOME/handoffs/.latest.$SID"
printf 'reload fixture\n' > "$STATE/$SID.reload-pending"
touch -d '40 minutes ago' "$STATE/$SID.reload-pending"
: > "$STATE/$SID.deferred"
export MUX_LIVE_PANES=""
sweep; sweep
assert_eq "unreachable reload pages exactly once across sweeps" "$(pages)" 1
assert_contains "unreachable page identifies the reload" "$(cat "$SB/pages.log")" "reload for session $SID"
assert_file "paging retains the reload marker" "$STATE/$SID.reload-pending"
assert_eq "unreachable pane never launches watcher" "$(cat "$SB/launched.log")" ''
touch -d '35 minutes ago' "$STATE/$SID.reload-pending"
sweep
assert_eq "a different stuck reload marker pages again" "$(pages)" 2
# A compact request may coexist with the older reload. It must not displace
# reload's shared dedupe record while that reload remains the active work.
request '30 minutes ago'
sweep; sweep
assert_eq "coexisting compact request cannot re-page the same reload" "$(pages)" 2
sandbox_rm

setup
touch -d '2 hours ago' "$AUTODEV_HOME/handoffs/.latest.$SID"
printf 'reload fixture\n' > "$STATE/$SID.reload-pending"
touch -d '10 minutes ago' "$STATE/$SID.reload-pending"
export MUX_LIVE_PANES=""
sweep
assert_eq "a young unreachable reload does not page" "$(pages)" 0
sandbox_rm

setup
touch -d '2 hours ago' "$AUTODEV_HOME/handoffs/.latest.$SID"
printf 'reload fixture\n' > "$STATE/$SID.reload-pending"
touch -d '40 minutes ago' "$STATE/$SID.reload-pending"
export MUX_LIVE_PANES=""
printf '#!/usr/bin/env bash\nsleep 1\nprintf "%%s\\n" "$*" >> "$SB/pages.log"\n' > "$SB/fakebin/notify-send"
bash "$BIN/auto-handoff-sweep.sh" >/dev/null 2>&1 &
reload_sweep_a=$!
bash "$BIN/auto-handoff-sweep.sh" >/dev/null 2>&1 &
reload_sweep_b=$!
wait "$reload_sweep_a"; wait "$reload_sweep_b"
assert_eq "overlapping sweeps page a stuck reload exactly once" "$(pages)" 1
sandbox_rm

# Stale cycle locks are never reclaimed by a sweep, but cannot suppress the
# overdue reload page. Cover both owner-bearing symlinks and legacy locks.
for lock_kind in dead-symlink dead-directory missing-owner live-owner; do
  setup
  touch -d '2 hours ago' "$AUTODEV_HOME/handoffs/.latest.$SID"
  printf 'reload fixture\n' > "$STATE/$SID.reload-pending"
  touch -d '40 minutes ago' "$STATE/$SID.reload-pending"
  export MUX_LIVE_PANES=""
  (exit 0) & dead_pid=$!
  wait "$dead_pid"
  assert_eq "$lock_kind: fixture owner is dead" "$(kill -0 "$dead_pid" 2>/dev/null && echo live || echo dead)" dead
  lock="$STATE/$SID.cycle.lock"
  case "$lock_kind" in
    dead-symlink) ln -s "/dev/null/autodev-lock-owner/$dead_pid" "$lock" ;;
    *)
      mkdir "$lock"
      case "$lock_kind" in
        dead-directory) printf '%s\n' "$dead_pid" > "$lock/pid" ;;
        live-owner) printf '%s\n' "$$" > "$lock/pid" ;;
      esac ;;
  esac
  lock_before=$(stat -c '%i:%Y:%s' "$lock")
  sweep; sweep
  if [ "$lock_kind" = live-owner ]; then expected=0; else expected=1; fi
  assert_eq "$lock_kind: overdue reload pages once unless owner is live" "$(pages)" "$expected"
  assert_eq "$lock_kind: sweep does not reclaim or modify the cycle lock" "$(stat -c '%i:%Y:%s' "$lock")" "$lock_before"
  assert_file "$lock_kind: reload marker is retained" "$STATE/$SID.reload-pending"
  assert_eq "$lock_kind: no unreachable pane watcher launched" "$(cat "$SB/launched.log")" ''
  sandbox_rm
done

# Paging checks must happen after taking the page lock, since another
# watcher may have reclaimed a dead cycle owner in the intervening window.
setup
touch -d '2 hours ago' "$AUTODEV_HOME/handoffs/.latest.$SID"
printf 'reload fixture\n' > "$STATE/$SID.reload-pending"
touch -d '40 minutes ago' "$STATE/$SID.reload-pending"
mkdir "$STATE/$SID.cycle.lock"
export MUX_LIVE_PANES="" LOCK_TEST_LIVE_PID="$$" LOCK_TEST_SID="$SID"
real_flock=$(command -v flock)
printf '#!/usr/bin/env bash\nprintf "%%s\n" "$LOCK_TEST_LIVE_PID" > "$STATE/$LOCK_TEST_SID.cycle.lock/pid"\ntouch "$SB/page-lock-race"\nexec "%s" "$@"\n' "$real_flock" > "$SB/fakebin/flock"
chmod +x "$SB/fakebin/flock"
PATH="$SB/fakebin:$PATH" sweep
assert_file "page-lock ownership race was exercised" "$SB/page-lock-race"
assert_eq "late live cycle owner suppresses the reload page" "$(pages)" 0
assert_no_file "late live cycle owner consumes no paging dedupe" "$STATE/$SID.paged"
assert_eq "sweep leaves the late live owner untouched" "$(cat "$STATE/$SID.cycle.lock/pid")" "$$"
sandbox_rm

for marker_state in young superseded foreign-pane; do
  setup
  touch -d '2 hours ago' "$AUTODEV_HOME/handoffs/.latest.$SID"
  printf 'reload fixture\n' > "$STATE/$SID.reload-pending"
  touch -d '40 minutes ago' "$STATE/$SID.reload-pending"
  mkdir "$STATE/$SID.cycle.lock"
  export MUX_LIVE_PANES=""
  case "$marker_state" in
    young) touch -d '10 minutes ago' "$STATE/$SID.reload-pending" ;;
    superseded) touch "$STATE/$SID.idle" ;;
    foreign-pane)
      export MUX_LIVE_PANES="w1:p1"
      printf 'different-session\n' > "$STATE/.paneowner-herdr-w1_p1" ;;
  esac
  sweep
  assert_eq "$marker_state: blocked cleanup does not page obsolete or young work" "$(pages)" 0
  assert_file "$marker_state: sweep retains marker without owning the lock" "$STATE/$SID.reload-pending"
  sandbox_rm
done

finish
