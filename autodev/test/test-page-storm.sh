#!/usr/bin/env bash
# Regression coverage for per-kind dedupe, dead sessions, and the per-sweep page budget.
. "$(dirname "$0")/lib.sh"

setup_pages() {
  sandbox_new; stub_mux; stub_watcher; arm
  unset AUTODEV_PAGE_BUDGET AUTODEV_DEAD_SESSION_HOURS AUTODEV_NO_FLOCK MUX_HERDR
  mkdir -p "$SB/fakebin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$SB/pages.log"\n' > "$SB/fakebin/notify-send"
  chmod +x "$SB/fakebin/notify-send"
  : > "$SB/pages.log"
  export AUTODEV_PAGE_CMD="$SB/fakebin/notify-send"
}
sweep() { bash "$BIN/auto-handoff-sweep.sh" >/dev/null 2>&1; }
pages() { wc -l < "$SB/pages.log" | tr -d ' '; }
old_request() {
  local sid=$1 kind=$2
  : > "$STATE/$sid.$kind"
  touch -d '40 minutes ago' "$STATE/$sid.$kind"
  touch "$STATE/$sid.deferred"
}

# Two marker kinds keep independent records over repeated sweeps.
setup_pages
SID=session-a
session_new "$SID" 20 "w1:p1"
export MUX_LIVE_PANES=""
handoff_pointer "$SID"
old_request "$SID" handoff-request
old_request "$SID" compact-request
for i in $(seq 1 20); do sweep; done
assert_eq "two pending kinds page exactly twice over 20 sweeps" "$(pages)" 2
assert_file "handoff kind has its own dedupe record" "$STATE/$SID.paged.handoff-request"
assert_file "compact kind has its own dedupe record" "$STATE/$SID.paged.compact-request"
sandbox_rm

# A dead session is paged once only when the current successful listing proves
# its pane absent; both marker files remain in place.
setup_pages
SID=session-dead
session_new "$SID" 20 "w9:p9"
: > "$STATE/$SID.heartbeat"; touch -d '48 hours ago' "$STATE/$SID.heartbeat"
touch -d '48 hours ago' "$STATE/$SID.ctx"
old_request "$SID" handoff-request
cat > "$SB/fakebin/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"result":{"panes":[]}}'
STUB
chmod +x "$SB/fakebin/herdr"
export MUX_HERDR="$SB/fakebin/herdr" MUX_LIVE_PANES="" AUTODEV_DEAD_SESSION_HOURS=invalid
for i in $(seq 1 20); do sweep; done
assert_eq "dead session pages once over 20 sweeps" "$(grep -c 'dead session' "$SB/pages.log")" 1
assert_file "dead session request marker is retained" "$STATE/$SID.handoff-request"
assert_file "dead session context marker is retained" "$STATE/$SID.ctx"
sandbox_rm

# Satisfied-request cleanup runs first; if it removes the last marker, there is
# no dead-session page to send.
setup_pages
SID=session-satisfied
session_new "$SID" 20 "w9:p9"
: > "$STATE/$SID.heartbeat"; touch -d '48 hours ago' "$STATE/$SID.heartbeat"
touch -d '48 hours ago' "$STATE/$SID.ctx"
: > "$STATE/$SID.compact-request"
cat > "$SB/fakebin/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"result":{"panes":[]}}'
STUB
chmod +x "$SB/fakebin/herdr"
export MUX_HERDR="$SB/fakebin/herdr" MUX_LIVE_PANES=""
sweep
assert_no_file "satisfied request is cleaned by the existing cleanup" "$STATE/$SID.compact-request"
assert_not_contains "no remaining marker means no dead-session page" "$(cat "$SB/pages.log")" "dead session"
sandbox_rm

# A failed pane listing is unknown, not proof that a session is dead.
setup_pages
SID=session-unknown
session_new "$SID" 20 "w9:p9"
: > "$STATE/$SID.heartbeat"; touch -d '48 hours ago' "$STATE/$SID.heartbeat"
touch -d '48 hours ago' "$STATE/$SID.ctx"
: > "$STATE/$SID.handoff-request"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SB/fakebin/herdr"
chmod +x "$SB/fakebin/herdr"
export MUX_HERDR="$SB/fakebin/herdr" MUX_LIVE_PANES=""
sweep
assert_not_contains "pane listing outage does not page dead-session notice" "$(cat "$SB/pages.log")" "dead session"
assert_file "unknown pane state retains its marker" "$STATE/$SID.handoff-request"
cat > "$SB/fakebin/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"result":{"panes":"unknown"}}'
STUB
chmod +x "$SB/fakebin/herdr"
sweep
assert_not_contains "malformed successful listing does not prove absence" "$(cat "$SB/pages.log")" "dead session"
sandbox_rm

# Ten eligible sessions exercise the global budget through the default flock
# path. The shim records calls and delegates to real flock.
setup_pages
REAL_FLOCK=$(command -v flock)
export REAL_FLOCK AUTODEV_PAGE_BUDGET=invalid
printf '#!/usr/bin/env bash\nprintf "called\\n" >> "$SB/flock.log"\nexec "$REAL_FLOCK" "$@"\n' > "$SB/fakebin/flock"
chmod +x "$SB/fakebin/flock"
for n in $(seq 1 10); do
  sid="session-$n"
  session_new "$sid" 20 "w1:p$n"
  old_request "$sid" handoff-request
done
export MUX_LIVE_PANES=""
for i in $(seq 1 20); do PATH="$SB/fakebin:$PATH" sweep; done
assert_file "budget check exercised default flock path" "$SB/flock.log"
assert_eq "budget allows at most three detailed pages plus one summary" "$(pages)" 4
assert_eq "one summary names the seven additional markers" "$(grep -c '7 additional stale marker' "$SB/pages.log")" 1
sandbox_rm

# An old single-slot record is read as migration history.
setup_pages
SID=session-legacy
session_new "$SID" 20 "w1:p1"
export MUX_LIVE_PANES=""
handoff_pointer "$SID"
old_request "$SID" compact-request
sweep
assert_eq "legacy fixture first pages once" "$(pages)" 1
cp "$STATE/$SID.paged.compact-request" "$STATE/$SID.paged"
rm "$STATE/$SID.paged.compact-request"
for i in $(seq 1 20); do sweep; done
assert_eq "matching legacy single-slot record prevents re-page" "$(pages)" 1
assert_file "legacy record remains intact" "$STATE/$SID.paged"
sandbox_rm

# Change eligibility immediately before the nonblocking lock is taken.
setup_pages
SID=session-race
session_new "$SID" 20 "w1:p1"
export MUX_LIVE_PANES=""
old_request "$SID" handoff-request
REAL_FLOCK=$(command -v flock)
export REAL_FLOCK LOCK_TEST_SID="$SID"
printf '#!/usr/bin/env bash\nrm -f "$STATE/$LOCK_TEST_SID.deferred"\nexec "$REAL_FLOCK" "$@"\n' > "$SB/fakebin/flock"
chmod +x "$SB/fakebin/flock"
PATH="$SB/fakebin:$PATH" sweep
assert_eq "changed eligibility before lock produces no page" "$(pages)" 0
assert_no_file "changed eligibility consumes no dedupe record" "$STATE/$SID.paged.handoff-request"
sandbox_rm

finish
