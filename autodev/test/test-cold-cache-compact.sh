#!/usr/bin/env bash
# The "compact while the cache is already cold" trigger.
#
# Compaction always pays a full prompt-prefix rewrite. Whether that rewrite is
# expensive depends entirely on WHEN it happens: compacting while the cache is
# warm discards a live prefix and pays to rewrite the new one, but compacting
# after the 5-minute ephemeral prompt-cache TTL has already lapsed turns a
# rewrite the NEXT turn owed anyway into a rewrite of the small compacted
# context instead of the large one. This file guards:
#   - the pct/idle-age arithmetic in auto-handoff-watch.sh (edge trigger),
#   - that auto-handoff-sweep.sh's prefilter actually lets a cold-cache
#     candidate through (the watcher alone can never observe this condition,
#     since idle_age is ~0 at the turn-end edge that launches it),
#   - the disable-cold-cache-compact kill switch (suppresses only this branch),
#   - and that the existing anti-re-compaction guard (ctx mtime vs cooldown
#     mtime) still binds the new branch exactly as it binds the threshold one.

. "$(dirname "$0")/lib.sh"

SID=55555555-5555-5555-5555-555555555555

# DRY (unarmed) is used throughout the watch.sh section: it evaluates every
# gate up to and including the trigger decision and logs it. It does NOT
# return early — an unarmed cycle runs on to CYCLE COMPLETE. What keeps these
# tests fast is the opposite: every wait past the trigger IS gated on
# `DRY = 0` (the busy-pane check, both wait_pane_idle calls around /handoff
# and /compact, and the post-compact reload sleep), so an unarmed run reaches
# the end without blocking on any of them, and no sleep in this file waits on
# anything but its own SETTLE.
export AUTODEV_SETTLE=0 AUTODEV_POLL=1

setup_watch() {
  sandbox_new
  stub_mux
  session_new "$SID" "$1" "w1:p1"
  export MUX_LIVE_PANES="w1:p1" MUX_BUSY=0
}

setup_sweep() {
  sandbox_new
  stub_mux
  stub_watcher
  session_new "$SID" "$1" "w1:p1"
  export MUX_LIVE_PANES="w1:p1" MUX_BUSY=0
}

# .idle holds the epoch of the last completed turn (written by
# cc-stop-hook.sh); both auto-handoff-watch.sh's heartbeat block and this
# feature's cold-cache check read it the same way: cat its content, not mtime.
set_idle_age() { printf '%s\n' "$(( $(date +%s) - $2 ))" > "$STATE/$1.idle"; }

run_watch() { bash "$BIN/auto-handoff-watch.sh" "$SID" >/dev/null 2>&1; }
sweep()     { bash "$BIN/auto-handoff-sweep.sh" >/dev/null 2>&1; }

LOGF() { echo "$AUTODEV_HOME/logs/auto-handoff.log"; }
log_contains()     { grep -qF -- "$2" "$(LOGF)" 2>/dev/null && _pass "$1" || _fail "$1" "log does not contain [$2]: $(cat "$(LOGF)" 2>/dev/null)"; }
log_not_contains() { grep -qF -- "$2" "$(LOGF)" 2>/dev/null && _fail "$1" "log unexpectedly contains [$2]: $(cat "$(LOGF)" 2>/dev/null)" || _pass "$1"; }

echo "== auto-handoff-watch.sh: cold-cache trigger determination =="

# 1) below COLD_MIN, idle long: not enough context saved to be worth a cycle.
setup_watch 20
set_idle_age "$SID" 1000
run_watch
log_not_contains "below COLD_MIN with a long-idle cache does not trigger" "TRIGGER ("
sandbox_rm

# 2) above COLD_MIN, idle short: the cache has not gone cold yet, so compacting
# now would still discard a live prefix.
setup_watch 30
set_idle_age "$SID" 60
run_watch
log_not_contains "above COLD_MIN but idle < CACHE_TTL does not trigger" "TRIGGER ("
sandbox_rm

# 3) above COLD_MIN, idle >= CACHE_TTL: the cache has already expired, so this
# is exactly the opportunistic window.
setup_watch 30
set_idle_age "$SID" 350
run_watch
log_contains "above COLD_MIN with idle >= CACHE_TTL triggers cold-cache" "TRIGGER (cold-cache)"
sandbox_rm

# 4) above THRESHOLD still triggers as reason=threshold regardless of idle age
# (regression: the existing bare-threshold path must be unmodified).
setup_watch 90
set_idle_age "$SID" 10
run_watch
log_contains "above THRESHOLD still triggers threshold" "TRIGGER (threshold)"
sandbox_rm

# 5) kill switch suppresses ONLY the cold-cache branch.
setup_watch 30
set_idle_age "$SID" 350
: > "$STATE/disable-cold-cache-compact"
run_watch
log_not_contains "kill switch suppresses cold-cache trigger" "TRIGGER ("
sandbox_rm

setup_watch 90
: > "$STATE/disable-cold-cache-compact"
run_watch
log_contains "kill switch leaves the threshold trigger unaffected" "TRIGGER (threshold)"
sandbox_rm

echo "== auto-handoff-sweep.sh: the prefilter must not be dead code =="

# 6) A cold-cache candidate (pct between COLD_MIN and THRESHOLD, idle >=
# CACHE_TTL) must pass the sweep's prefilter and reach the trigger logic. If
# the sweep's own THRESHOLD-only prefilter were left unwidened, this candidate
# would never even reach the watcher, and the feature would be dead in the
# sweep path (the only path that can ever observe this condition).
setup_sweep 30
set_idle_age "$SID" 350
sweep
assert_launched "cold-cache candidate passes the sweep prefilter" "$SID"
sandbox_rm

# A candidate that is not yet cold must NOT pass.
setup_sweep 30
set_idle_age "$SID" 10
sweep
assert_not_launched "not-yet-cold candidate is left alone by the sweep" "$SID"
sandbox_rm

# The kill switch also applies inside the sweep's prefilter.
setup_sweep 30
set_idle_age "$SID" 350
: > "$STATE/disable-cold-cache-compact"
sweep
assert_not_launched "kill switch stops the sweep's cold-cache branch" "$SID"
sandbox_rm

echo "== the anti-re-compaction guard binds the cold-cache branch too =="

# 7) A session that already completed a cold-cache cycle, and whose .ctx has
# NOT been touched since (no new turns), must not re-trigger on a later sweep
# pass — otherwise it would get compacted every COOLDOWN period forever.
setup_sweep 30
set_idle_age "$SID" 350
touch -d '2 hours ago' "$STATE/$SID.ctx"
touch -d '1 hour ago' "$STATE/$SID.cooldown"
sweep
assert_not_launched "untouched .ctx since the last cycle is not re-swept" "$SID"
sandbox_rm

# ...but once the session has actually done something again (.ctx moves), it
# is fair game again — the guard must not become a permanent lockout.
setup_sweep 30
set_idle_age "$SID" 350
touch -d '1 hour ago' "$STATE/$SID.cooldown"
touch "$STATE/$SID.ctx"
sweep
assert_launched "a .ctx touched since the last cycle is swept again" "$SID"
sandbox_rm

finish
