#!/usr/bin/env bash
# The PM-nudger: classification, the firing gates, and the safety ladder.
#
# NOTHING here touches a real herdr, a real pane, or the network. `herdr` is a
# fake executable inside the sandbox, installed BOTH as $PM_NUDGE_HERDR and first
# on $PATH — belt and braces, so that even a bare `herdr` call added to the
# daemon later cannot escape to the real multiplexer. Every write subcommand it
# understands (send-text, send-keys) only appends to a log file. The composer is
# a shell script, so no python, no SDK and no API key are involved.
#
# The properties under test are the ones where being wrong means typing into
# somebody's live session: never while anything is blocked, never before the
# debounce, never twice inside the cooldown, and never Enter when the pane's
# buffer could not be read.

. "$(dirname "$0")/lib.sh"

# --- fixtures ----------------------------------------------------------------
setup_nudge() {
  sandbox_new
  # The installer test needs the composer and requirements next to the copied
  # scripts; sandbox_new only copies bin/*.sh.
  cp "$SKILL_DIR"/bin/pm-nudge-compose.py "$SKILL_DIR"/bin/pm-nudge-requirements.txt "$BIN"/ 2>/dev/null
  mkdir -p "$SB/herdr" "$SB/fakebin"
  : > "$SB/sent-text.log"
  : > "$SB/sent-keys.log"
  : > "$SB/herdr/ws.tsv"
  : > "$SB/herdr/panes.tsv"

  cat > "$SB/fakebin/herdr" <<'STUB'
#!/usr/bin/env bash
# Fake herdr: fixtures in, write-attempts logged, never a real pane.
H="$SB/herdr"
safe(){ printf '%s' "$1" | tr ':/' '__'; }
case "${1:-} ${2:-}" in
  "workspace list") cat "$H/workspaces.json" ;;
  "pane list")      cat "$H/panes.json" ;;
  "pane get")
      p="$3"
      if [ -f "$H/get-$(safe "$p").status" ]; then
        printf '{"result":{"agent_status":"%s"}}\n' "$(cat "$H/get-$(safe "$p").status")"
      else
        jq -c --arg p "$p" '{result:(.result.panes[]|select(.pane_id==$p))}' "$H/panes.json"
      fi ;;
  "pane read")
      [ -f "$H/read-fail" ] && exit 1
      f="$H/read-$(safe "$3").txt"; [ -f "$f" ] || exit 1
      cat "$f" ;;
  "pane send-text")
      [ -f "$H/sendtext-fail" ] && exit 1
      shift 2; p="$1"; shift
      printf '%s\t%s\n' "$p" "$*" >> "$SB/sent-text.log" ;;
  "pane send-keys")
      shift 2; p="$1"; shift
      printf '%s\t%s\n' "$p" "$*" >> "$SB/sent-keys.log" ;;
  *) echo "fake herdr: unhandled [$*]" >&2; exit 64 ;;
esac
exit 0
STUB
  chmod +x "$SB/fakebin/herdr"

  # Default composer: echoes a fixed, recognisable sentence and records the facts
  # it was handed, so tests can assert on what the daemon told the model.
  cat > "$SB/compose.sh" <<'CMP'
cat > "$SB/facts.json"
printf 'MODEL SAYS: wrap it up\n'
CMP
}

fx_ws()   { printf '%s\t%s\n' "$1" "$2" >> "$SB/herdr/ws.tsv"; }
fx_pane() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5-}" >> "$SB/herdr/panes.tsv"; }
fx_build() {
  jq -R -s -c 'split("\n")|map(select(length>0)|split("\t"))
    |{result:{workspaces: map({workspace_id:.[0], label:.[1]})}}' \
    < "$SB/herdr/ws.tsv" > "$SB/herdr/workspaces.json"
  jq -R -s -c 'split("\n")|map(select(length>0)|split("\t"))
    |{result:{panes: map({workspace_id:.[0], pane_id:.[1], agent_status:.[2], cwd:.[3],
                          label:(if (.[4]//"")=="" then null else .[4] end)})}}' \
    < "$SB/herdr/panes.tsv" > "$SB/herdr/panes.json"
}

# Backdate the debounce marker so the quiet window counts as already satisfied.
quiet_since() { # $1 = ws, $2 = pm pane, $3 = seconds ago
  mkdir -p "$STATE/pm-nudge"
  printf '%s %s\n' "$(( $(date +%s) - $3 ))" "$2" > "$STATE/pm-nudge/$1.since"
}

# Backdate the cooldown marker so the cooldown window counts as already
# lapsed. The sweeper judges the cooldown by the marker's MTIME, not its
# content (fresh() in pm-nudge-sweep.sh calls `date -r` on the file), so
# proving the cooldown lapses does not need a real sleep -- touch -d sets the
# mtime straight into the past, which is exact and does not depend on how
# fast the machine running the test happens to be.
cooldown_since() { # $1 = ws, $2 = seconds ago
  mkdir -p "$STATE/pm-nudge"
  local f="$STATE/pm-nudge/$1.cooldown"
  : > "$f"
  touch -d "@$(( $(date +%s) - $2 ))" "$f"
}

run_sweep() {
  env AUTODEV_HOME="$AUTODEV_HOME" SB="$SB" PATH="$SB/fakebin:$PATH" \
      PM_NUDGE_HERDR="$SB/fakebin/herdr" \
      PM_NUDGE_PY=/bin/sh PM_NUDGE_PY_ARGS= PM_NUDGE_COMPOSER="$SB/compose.sh" \
      PM_NUDGE_DIGEST="$SB/no-such-digest.json" \
      PM_NUDGE_DEBOUNCE="${DEBOUNCE:-300}" PM_NUDGE_COOLDOWN="${COOLDOWN:-7200}" \
      PM_NUDGE_MAX_CHARS="${MAXCHARS:-240}" \
      bash "$BIN/pm-nudge-sweep.sh" "$@" >"$SB/sweep.out" 2>"$SB/sweep.err"
}

staged()   { cut -f2- "$SB/sent-text.log" 2>/dev/null; }
report()   { cat "$SB/sweep.out"; }
nudgelog() { cat "$AUTODEV_HOME/logs/pm-nudge.log" 2>/dev/null; }

# A workspace that is unambiguously ready to nudge: PM idle, one done worker.
fx_ready() {
  fx_ws wG Gracie
  fx_pane wG wG:p4F idle /home/alon/Code/gracie-pm2 ''
  fx_pane wG wG:p7F 'done' /home/alon/Code/gracie-i098-audible-display ''
  fx_build
  quiet_since wG wG:p4F 900
}

# =============================================================================
echo "== classification: which workspaces are PM campaigns =="
# Modelled on the real machine, including the shapes that are easy to get wrong:
# a worker living inside the PM's own checkout (wH), a PM with no workers at all
# (wJ), and four of Alon's ordinary working spaces that must never be campaigns.
setup_nudge
fx_ws w7 main;   fx_ws w8 ARC;   fx_ws w9 Papers; fx_ws wE House
fx_ws w1 CKMG;   fx_ws wF plasma; fx_ws wH SCM;   fx_ws wJ NS
fx_ws wG Gracie; fx_ws wP Carmel
fx_pane w7 w7:p5  idle /home/alon/Dropbox/Work/Office_of_Vice_Dean_UG i007-bsc-catalogue-D002A01
fx_pane w7 w7:p2J idle /home/alon/Dropbox/Work/Proposals ''
fx_pane w8 w8:pF  idle /home/alon/Code/ARC ''
fx_pane w9 w9:p4  'done' '/home/alon/Dropbox/Apps/Overleaf/54. BEES' i010-bees-D-006A01
fx_pane wE wE:pB  idle /home/alon/Code/agent-skills ''
fx_pane w1 w1:p7G idle /home/alon/Code/ckmg-pm4 ''
fx_pane w1 w1:p9N 'done' /home/alon/Code/CKMG-fast-subsystem ''
fx_pane wF wF:p1R 'done' /home/alon/Code/plasma-pm2 plasma-PM
fx_pane wF wF:p5Y idle /home/alon/Code/RMG-Py-i151-m5-gate i151-m5-gate-D067A01
fx_pane wH wH:p1B 'done' /home/alon/Code/scm-pm2 ''
fx_pane wH wH:p28 'done' /home/alon/Code/scm-pm2 i017-verify-v3-against-all-98-D016A01
fx_pane wJ wJ:p2Z idle /home/alon/Code/ns-pm2 ''
fx_pane wG wG:p4F idle /home/alon/Code/gracie-pm2 ''
fx_pane wP wP:p1  idle /home/alon/Code/carmel-pm ''
fx_build
run_sweep --report
R=$(report)

for ws in w7 w8 w9 wE; do
  assert_contains "$ws is NOT a campaign (no PM-shaped cwd)" "$R" "$ws"
  printf '%s\n' "$R" | grep -E "^$ws " | grep -q "excluded" \
    && _pass "$ws is reported as excluded" \
    || _fail "$ws is reported as excluded" "got: $(printf '%s\n' "$R" | grep -E "^$ws ")"
done
for ws in w1 wF wH wJ wG wP; do
  printf '%s\n' "$R" | grep -E "^$ws " | grep -q "excluded" \
    && _fail "$ws IS a campaign" "reported excluded: $(printf '%s\n' "$R" | grep -E "^$ws ")" \
    || _pass "$ws IS a campaign"
done
# THE reclassification case: both wH panes sit in .../scm-pm2, so cwd alone would
# pick whichever came first. The ticket label demotes wH:p28 to worker.
assert_contains "wH's PM is the unlabelled pane, not the ticket-labelled one" \
  "$(printf '%s\n' "$R" | grep -E '^wH ')" "wH:p1B"
assert_not_contains "wH's ticket-labelled pane is never the PM" \
  "$(printf '%s\n' "$R" | grep -E '^wH ')" "wH:p28"
# plasma-PM is a label that is NOT ticket-shaped, so it must not demote the PM.
assert_contains "a non-ticket label leaves a PM pane a PM" \
  "$(printf '%s\n' "$R" | grep -E '^wF ')" "wF:p1R"
sandbox_rm

# =============================================================================
echo "== the firing gates =="
setup_nudge; fx_ready
run_sweep --stage-only
assert_contains "fires when the PM and every worker are quiet past the debounce" \
  "$(staged)" "MODEL SAYS: wrap it up"
assert_eq "one nudge, staged into the PM pane" "$(cut -f1 "$SB/sent-text.log")" "wG:p4F"
assert_eq "--stage-only never presses Enter" "$(wc -l < "$SB/sent-keys.log")" "0"
sandbox_rm

setup_nudge
fx_ws wG Gracie
fx_pane wG wG:p4F idle /home/alon/Code/gracie-pm2 ''
fx_pane wG wG:p7F working /home/alon/Code/gracie-i098 i098-x-D001A01
fx_build; quiet_since wG wG:p4F 900
run_sweep --stage-only
assert_eq "does NOT fire while a worker is still working" "$(wc -l < "$SB/sent-text.log")" "0"
sandbox_rm

setup_nudge
fx_ws wG Gracie
fx_pane wG wG:p4F working /home/alon/Code/gracie-pm2 ''
fx_pane wG wG:p7F 'done' /home/alon/Code/gracie-i098 ''
fx_build; quiet_since wG wG:p4F 900
run_sweep --stage-only
assert_eq "does NOT fire while the PM itself is working" "$(wc -l < "$SB/sent-text.log")" "0"
sandbox_rm

setup_nudge
fx_ws wG Gracie
fx_pane wG wG:p4F idle /home/alon/Code/gracie-pm2 ''
fx_pane wG wG:p7F unknown /home/alon/Code/gracie-i098 ''
fx_build; quiet_since wG wG:p4F 900
run_sweep --stage-only
assert_eq "an 'unknown' worker counts as busy, not as quiet" "$(wc -l < "$SB/sent-text.log")" "0"
sandbox_rm

echo "== blocked is an absolute veto =="
setup_nudge
fx_ws wG Gracie
fx_pane wG wG:p4F idle /home/alon/Code/gracie-pm2 ''
fx_pane wG wG:p7F blocked /home/alon/Code/gracie-i098 ''
fx_build; quiet_since wG wG:p4F 900
run_sweep --stage-only
assert_eq "NEVER fires while a WORKER is blocked, even with the PM idle" \
  "$(wc -l < "$SB/sent-text.log")" "0"
assert_no_file "a blocked pane RESETS the debounce window" "$STATE/pm-nudge/wG.since"
sandbox_rm

setup_nudge
fx_ws wG Gracie
fx_pane wG wG:p4F blocked /home/alon/Code/gracie-pm2 ''
fx_pane wG wG:p7F 'done' /home/alon/Code/gracie-i098 ''
fx_build; quiet_since wG wG:p4F 900
run_sweep --stage-only
assert_eq "NEVER fires while the PM is blocked" "$(wc -l < "$SB/sent-text.log")" "0"
sandbox_rm

echo "== debounce and cooldown =="
setup_nudge
fx_ws wG Gracie
fx_pane wG wG:p4F idle /home/alon/Code/gracie-pm2 ''
fx_pane wG wG:p7F 'done' /home/alon/Code/gracie-i098 ''
fx_build
run_sweep --stage-only          # no .since yet: the window opens on this pass
assert_eq "first sighting only opens the debounce window" "$(wc -l < "$SB/sent-text.log")" "0"
assert_file "the debounce marker is recorded" "$STATE/pm-nudge/wG.since"
run_sweep --stage-only          # still inside the window
assert_eq "still silent inside the debounce window" "$(wc -l < "$SB/sent-text.log")" "0"
quiet_since wG wG:p4F 900       # now backdate it
run_sweep --stage-only
assert_eq "fires once the window is satisfied" "$(wc -l < "$SB/sent-text.log")" "1"
run_sweep --stage-only
assert_eq "the cooldown suppresses the immediate re-nudge" "$(wc -l < "$SB/sent-text.log")" "1"
run_sweep --report
assert_contains "and --report attributes the silence to the cooldown" "$(report)" "COOLDOWN:"
COOLDOWN=1 run_sweep --stage-only
cooldown_since wG 2
COOLDOWN=1 run_sweep --stage-only
assert_eq "fires again once the cooldown has lapsed" "$(wc -l < "$SB/sent-text.log")" "2"
sandbox_rm

# A debounce window earned by one PM pane must not be spent by whatever session
# inherits that recycled pane id.
setup_nudge; fx_ready
quiet_since wG wG:pOLD 900
run_sweep --stage-only
assert_eq "a changed PM pane id restarts the debounce" "$(wc -l < "$SB/sent-text.log")" "0"
sandbox_rm

echo "== the kill switch =="
setup_nudge; fx_ready
: > "$STATE/disable-pm-nudge"
run_sweep --stage-only
assert_eq "the kill switch stops --stage-only dead" "$(wc -l < "$SB/sent-text.log")" "0"
run_sweep --report
assert_contains "--report says why it did nothing" "$(report)" "DISABLED"
sandbox_rm

echo "== dry run is the default and is inert =="
setup_nudge; fx_ready
run_sweep
assert_eq "the default mode stages nothing" "$(wc -l < "$SB/sent-text.log")" "0"
assert_eq "the default mode sends no keys" "$(wc -l < "$SB/sent-keys.log")" "0"
assert_contains "but it does log that it WOULD have fired" "$(nudgelog)" "ELIGIBLE"
assert_contains "and names the mode" "$(nudgelog)" "DRY RUN"
# Nothing consumes dry-run state, so without a rate limit the same notice would
# repeat on every tick of a 5-minute timer, forever.
run_sweep
assert_eq "the dry-run notice is rate-limited, not repeated every tick" \
  "$(nudgelog | grep -c 'DRY RUN')" "1"
assert_no_file "and the rate limit does NOT consume the real cooldown" "$STATE/pm-nudge/wG.cooldown"
run_sweep --stage-only
assert_eq "so the first pass after arming still fires" "$(wc -l < "$SB/sent-text.log")" "1"
sandbox_rm

setup_nudge; fx_ready
run_sweep --report
assert_eq "--report cannot stage either" "$(wc -l < "$SB/sent-text.log")" "0"
assert_contains "--report explains the firing decision" "$(report)" "FIRE:"
sandbox_rm

echo "== --send is gated on the armed file =="
setup_nudge; fx_ready
printf 'nothing interesting here\n> \n' > "$SB/herdr/read-wG_p4F.txt"
run_sweep --send
assert_eq "--send without the armed file stages nothing" "$(wc -l < "$SB/sent-text.log")" "0"
assert_contains "and says it fell back to a dry run" "$(nudgelog)" "NOT ARMED"
: > "$STATE/pm-nudge.armed"
run_sweep --send
assert_eq "armed + a clear buffer stages the text" "$(wc -l < "$SB/sent-text.log")" "1"
assert_contains "armed + a clear buffer presses Enter" "$(cat "$SB/sent-keys.log")" "Enter"
sandbox_rm

echo "== the pre-send buffer check =="
setup_nudge; fx_ready; : > "$STATE/pm-nudge.armed"
: > "$SB/herdr/read-fail"          # herdr will not tell us what is on screen
run_sweep --send
assert_eq "an unreadable buffer still stages" "$(wc -l < "$SB/sent-text.log")" "1"
assert_eq "an unreadable buffer NEVER presses Enter" "$(wc -l < "$SB/sent-keys.log")" "0"
assert_contains "the degrade is logged" "$(nudgelog)" "DEGRADE"
sandbox_rm

setup_nudge; fx_ready; : > "$STATE/pm-nudge.armed"
printf '   \n\n  \n' > "$SB/herdr/read-wG_p4F.txt"   # readable, but empty
run_sweep --send
assert_eq "a blank buffer reads as inconclusive, not as clear" "$(wc -l < "$SB/sent-keys.log")" "0"
sandbox_rm

setup_nudge; fx_ready; : > "$STATE/pm-nudge.armed"
cat > "$SB/herdr/read-wG_p4F.txt" <<'BUF'
  Bash(rm -rf build/)
  Do you want to proceed?
  1. Yes
  2. No, and tell Claude what to do differently
BUF
run_sweep --send
assert_eq "an open permission menu blocks Enter" "$(wc -l < "$SB/sent-keys.log")" "0"
assert_eq "an open permission menu blocks send-text too" "$(wc -l < "$SB/sent-text.log")" "0"
assert_contains "and is logged as an abort" "$(nudgelog)" "interactive prompt/menu"
sandbox_rm

echo "== re-confirmation against live herdr, not the opening snapshot =="
setup_nudge; fx_ready; : > "$STATE/pm-nudge.armed"
printf 'clear\n' > "$SB/herdr/read-wG_p4F.txt"
printf 'working\n' > "$SB/herdr/get-wG_p4F.status"   # it woke up mid-cycle
run_sweep --send
assert_eq "a PM that woke up between list and act is not typed at" "$(wc -l < "$SB/sent-text.log")" "0"
assert_contains "the abort is logged" "$(nudgelog)" "is now 'working'"
sandbox_rm

setup_nudge; fx_ready; : > "$STATE/pm-nudge.armed"
printf 'clear\n' > "$SB/herdr/read-wG_p4F.txt"
printf '\n' > "$SB/herdr/get-wG_p4F.status"          # herdr answers, but with nothing
run_sweep --send
assert_eq "an unreadable live status aborts rather than trusting the snapshot" \
  "$(wc -l < "$SB/sent-text.log")" "0"
sandbox_rm

echo "== the model only supplies words, never the decision =="
setup_nudge; fx_ready
cat > "$SB/compose.sh" <<'CMP'
cat > /dev/null
exit 1
CMP
run_sweep --stage-only
assert_contains "a failed composer falls back to the fixed baseline" \
  "$(staged)" "All your sessions are done, collect and close as needed. What's next?"
assert_contains "the fallback source is recorded" "$(nudgelog)" "(baseline)"
sandbox_rm

setup_nudge; fx_ready
cat > "$SB/compose.sh" <<'CMP'
cat > /dev/null
printf '   \n'
CMP
run_sweep --stage-only
assert_contains "an empty completion also falls back to the baseline" \
  "$(staged)" "All your sessions are done"
sandbox_rm

setup_nudge; fx_ready
cat > "$SB/compose.sh" <<'CMP'
cat > /dev/null
printf 'first line\nsecond line\n'
CMP
run_sweep --stage-only
assert_eq "a multi-line completion is flattened to ONE staged line" \
  "$(wc -l < "$SB/sent-text.log")" "1"
assert_contains "with the newline turned into a space" "$(staged)" "first line second line"
sandbox_rm

setup_nudge; fx_ready
cat > "$SB/compose.sh" <<'CMP'
cat > /dev/null
printf 'x%.0s' $(seq 1 500); printf '\n'
CMP
MAXCHARS=60 run_sweep --stage-only
n=$(staged | wc -c)
[ "$n" -le 61 ] && _pass "the character cap is enforced before anything is staged" \
  || _fail "the character cap is enforced before anything is staged" "staged $n bytes, cap 60"
sandbox_rm

echo "== the facts handed to the composer =="
setup_nudge
fx_ws wG Gracie
fx_pane wG wG:p4F idle /home/alon/Code/gracie-pm2 ''
fx_pane wG wG:p7F 'done' /home/alon/Code/gracie-i098 i098-audible-D001A01
fx_build; quiet_since wG wG:p4F 900
run_sweep --stage-only
F="$SB/facts.json"
assert_file "the composer is handed a facts file" "$F"
jq -e . "$F" >/dev/null 2>&1 && _pass "the facts are valid JSON" || _fail "the facts are valid JSON" "$(cat "$F")"
assert_eq "facts name the PM pane"      "$(jq -r '.pm.pane_id' "$F")" "wG:p4F"
assert_eq "facts carry the quiet time"  "$(jq -r '.pm.quiet_seconds >= 900' "$F")" "true"
assert_eq "facts list the worker"       "$(jq -r '.workers_present[0].label' "$F")" "i098-audible-D001A01"
assert_eq "facts carry the baseline anchor" \
  "$(jq -r '.baseline' "$F")" "All your sessions are done, collect and close as needed. What's next?"
assert_eq "facts carry the character cap" "$(jq -r '.max_chars' "$F")" "240"
assert_eq "facts mark this situation as workers_finished" \
  "$(jq -r '.situation' "$F")" "workers_finished"
assert_eq "facts count the one worker ever seen" \
  "$(jq -r '.workers_seen_total' "$F")" "1"
assert_eq "facts count zero workers gone (still present)" \
  "$(jq -r '.workers_gone_count' "$F")" "0"
sandbox_rm

echo "== a PM whose workers are all gone (the vacuous case) =="
# Deliberate, not an accident: "every worker is idle/done/gone" is satisfied when
# there are no workers left, and a PM alone in its workspace with the fleet
# closed is the commonest shape of the situation this daemon exists for.
setup_nudge
fx_ws wJ NS
fx_pane wJ wJ:p2Z idle /home/alon/Code/ns-pm2 ''
fx_build; quiet_since wJ wJ:p2Z 900
run_sweep --stage-only
assert_eq "a single-pane PM workspace does fire" "$(wc -l < "$SB/sent-text.log")" "1"
assert_contains "and the reason names the vacuous case" "$(nudgelog)" "vacuously quiet"
F="$SB/facts.json"
assert_eq "facts mark this situation as no_workers_ever" \
  "$(jq -r '.situation' "$F")" "no_workers_ever"
assert_eq "facts count zero workers ever seen" "$(jq -r '.workers_seen_total' "$F")" "0"
assert_eq "facts count zero workers gone" "$(jq -r '.workers_gone_count' "$F")" "0"
sandbox_rm

echo "== the no-workers-ever fallback is honest, and the two fallbacks never leak =="
# The API-down / bad-output path is exactly where nothing else is watching, so
# it is the fallback STRING (not the composed text) that must be provably
# right: a workspace with zero workers ever seen must fall back to the
# dispatch-oriented baseline, never the "collect and close" one, and vice versa.
setup_nudge
fx_ws wJ NS
fx_pane wJ wJ:p2Z idle /home/alon/Code/ns-pm2 ''
fx_build; quiet_since wJ wJ:p2Z 900
cat > "$SB/compose.sh" <<'CMP'
cat > /dev/null
exit 1
CMP
run_sweep --stage-only
assert_contains "a workspace with no workers ever falls back to the dispatch-oriented baseline" \
  "$(staged)" "Nothing has run in this campaign yet"
assert_not_contains "and NEVER falls back to the 'collect and close' baseline" \
  "$(staged)" "collect and close"
sandbox_rm

setup_nudge; fx_ready
cat > "$SB/compose.sh" <<'CMP'
cat > /dev/null
exit 1
CMP
run_sweep --stage-only
assert_contains "a workspace whose workers actually finished falls back to 'collect and close'" \
  "$(staged)" "collect and close as needed"
assert_not_contains "and NEVER falls back to the dispatch-oriented baseline" \
  "$(staged)" "Nothing has run in this campaign yet"
sandbox_rm

echo "== a worker whose pane closed is still reported as finished =="
setup_nudge
fx_ws wG Gracie
fx_pane wG wG:p4F idle /home/alon/Code/gracie-pm2 ''
fx_pane wG wG:p7F 'done' /home/alon/Code/gracie-i098 i098-audible-D001A01
fx_build
run_sweep --stage-only                    # opens the window, records the worker
: > "$SB/herdr/panes.tsv"                 # the worker's pane is then closed
fx_pane wG wG:p4F idle /home/alon/Code/gracie-pm2 ''
fx_build
quiet_since wG wG:p4F 900
run_sweep --stage-only
assert_eq "the departed worker is remembered by name" \
  "$(jq -r '.workers_gone[0].label' "$SB/facts.json")" "i098-audible-D001A01"
sandbox_rm

echo "== failures on the herdr side are refusals, not guesses =="
setup_nudge; fx_ready
: > "$SB/herdr/sendtext-fail"
run_sweep --stage-only
assert_no_file "a failed send-text records no cooldown, so the next pass retries" \
  "$STATE/pm-nudge/wG.cooldown"
assert_contains "and the failure is logged" "$(nudgelog)" "send-text failed"
sandbox_rm

# =============================================================================
echo "== the generated systemd unit =="
# systemctl and crontab are stubbed and HOME redirected; the real user manager
# and the real crontab are never touched. --no-venv keeps pip and the network out.
setup_nudge
printf '#!/usr/bin/env bash\necho "systemctl $*" >> "%s/calls.log"\nexit 0\n' "$SB" > "$SB/fakebin/systemctl"
printf '#!/usr/bin/env bash\necho "crontab $*" >> "%s/calls.log"\ncat >/dev/null 2>&1\nexit 0\n' "$SB" > "$SB/fakebin/crontab"
chmod +x "$SB/fakebin"/*
: > "$SB/calls.log"; mkdir -p "$SB/home"
env PATH="$SB/fakebin:$PATH" HOME="$SB/home" AUTODEV_HOME="$SB/home/agents" \
    bash "$BIN/pm-nudge-install.sh" --no-venv > "$SB/install.out" 2>&1
svc="$SB/home/.config/systemd/user/pm-nudge-sweep.service"
tmr="$SB/home/.config/systemd/user/pm-nudge-sweep.timer"
assert_file "the installer writes a service unit" "$svc"
assert_file "the installer writes a timer unit" "$tmr"
# Line-anchored: the unit's own comments discuss KillMode, so a substring match
# would pass with the directive deleted.
assert_line "the service sets KillMode=process" "$(cat "$svc")" "KillMode=process"
assert_line "the service is a oneshot" "$(cat "$svc")" "Type=oneshot"
assert_line "the service runs the sweeper with --send" "$(cat "$svc")" "ExecStart=$BIN/pm-nudge-sweep.sh --send"
assert_line "the service pins AUTODEV_HOME" "$(cat "$svc")" "Environment=AUTODEV_HOME=$SB/home/agents"
assert_line_start "the service bounds its own runtime" "$(cat "$svc")" "TimeoutStartSec="
assert_line_start "the timer repeats on an interval" "$(cat "$tmr")" "OnUnitActiveSec="
assert_line "the timer is wanted by timers.target" "$(cat "$tmr")" "WantedBy=timers.target"
assert_contains "the installer enables the timer" "$(cat "$SB/calls.log")" "enable --now pm-nudge-sweep.timer"
# The point of shipping --send in the unit: it is inert until armed, whereas
# --stage-only would type into panes from the moment the timer starts.
assert_contains "the installer does NOT arm anything" "$(cat "$SB/install.out")" "DRY-RUN"
assert_no_file "no armed file is created by installing" "$SB/home/agents/state/pm-nudge.armed"
assert_contains "the banner names the kill switch" "$(cat "$SB/install.out")" "disable-pm-nudge"
sandbox_rm

setup_nudge
printf '#!/usr/bin/env bash\nexit 1\n' > "$SB/fakebin/systemctl"
printf '#!/usr/bin/env bash\necho "crontab $*" >> "%s/calls.log"\ncat >/dev/null 2>&1\nexit 0\n' "$SB" > "$SB/fakebin/crontab"
chmod +x "$SB/fakebin"/*
: > "$SB/calls.log"; mkdir -p "$SB/home"
env PATH="$SB/fakebin:$PATH" HOME="$SB/home" AUTODEV_HOME="$SB/home/agents" \
    bash "$BIN/pm-nudge-install.sh" --no-venv > "$SB/install.out" 2>&1
assert_contains "falls back to cron when systemd is unavailable" "$(cat "$SB/calls.log")" "crontab"
assert_contains "and reports it did" "$(cat "$SB/install.out")" "cron"
sandbox_rm

# =============================================================================
echo "== the composer degrades instead of throwing =="
# Runs the REAL python composer with a deliberately broken environment. It must
# exit non-zero with a diagnostic, never a traceback, because the sweeper reads
# only the exit status. No network: it fails before any client is constructed.
setup_nudge
if command -v python3 >/dev/null 2>&1; then
  out=$(printf 'not json at all' | env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
        python3 "$BIN/pm-nudge-compose.py" 2>&1); rc=$?
  assert_eq "malformed facts exit non-zero" "$rc" "1"
  assert_contains "with a one-line diagnostic" "$out" "pm-nudge-compose:"
  assert_not_contains "and no traceback" "$out" "Traceback"

  out=$(printf '{"baseline":"x"}' | env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
        python3 "$BIN/pm-nudge-compose.py" 2>&1); rc=$?
  assert_eq "a missing API key exits non-zero" "$rc" "1"
  assert_not_contains "without a traceback" "$out" "Traceback"

  # --dry-prompt is the seam that lets the prompt be reviewed without a key or a
  # token being spent.
  out=$(printf '{"baseline":"anchor sentence","workspace":{"id":"wG","label":"Gracie"},"pm":{"cwd":"/x/gracie-pm2","status":"idle","quiet_seconds":600},"workers_present":[],"workers_gone":[],"max_chars":240}' \
        | python3 "$BIN/pm-nudge-compose.py" --dry-prompt 2>&1)
  assert_contains "--dry-prompt renders the prompt offline" "$out" "anchor sentence"
  assert_contains "the prompt forbids invention" "$out" "Invent nothing"
  assert_not_contains "and never reaches the API" "$out" "Traceback"

  # situation=no_workers_ever must select the system prompt that forbids
  # claiming a finish, never the "fleet is done" one.
  out=$(printf '{"baseline":"nothing running anchor","situation":"no_workers_ever","workspace":{"id":"wJ","label":"NS"},"pm":{"cwd":"/x/ns-pm2","status":"idle","quiet_seconds":900},"workers_seen_total":0,"workers_gone_count":0,"workers_present":[],"workers_gone":[],"max_chars":240}' \
        | python3 "$BIN/pm-nudge-compose.py" --dry-prompt 2>&1)
  assert_contains "no_workers_ever selects the no-collect system prompt" "$out" "do NOT say or imply that anything finished"
  assert_not_contains "and never the fleet-finished system prompt" "$out" "the fleet is done, collect"

  # situation=workers_finished must select the opposite system prompt.
  out=$(printf '{"baseline":"fleet done anchor","situation":"workers_finished","workspace":{"id":"wG","label":"Gracie"},"pm":{"cwd":"/x/gracie-pm2","status":"idle","quiet_seconds":900},"workers_seen_total":1,"workers_gone_count":0,"workers_present":[{"pane_id":"wG:p7F","label":"x"}],"workers_gone":[],"max_chars":240}' \
        | python3 "$BIN/pm-nudge-compose.py" --dry-prompt 2>&1)
  assert_contains "workers_finished selects the fleet-finished system prompt" "$out" "the fleet is done, collect"
  assert_not_contains "and never the no-collect system prompt" "$out" "do NOT say or imply that anything finished"
fi
sandbox_rm

# =============================================================================
echo "== the API client is built with a bounded timeout and retry count =="
# This is a cron job firing every 5 minutes (see pm-nudge-compose.py's own
# comment next to HTTP_TIMEOUT_SECONDS/HTTP_MAX_RETRIES): the SDK's own defaults
# (timeout ~10 minutes, several retries) could leave a call from one sweep
# still in flight when the next sweep fires, stacking invocations against
# facts that are already stale. A real end-to-end timeout test would mean
# blocking the suite for the real ~20s bound (or mocking a hanging server) for
# every run, which is not worth paying on every invocation of this suite; the
# ambient python3 on this machine cannot even import the SDK (see the module's
# own "WHY ITS OWN VENV" docstring), and CI has no reason to have the
# dedicated venv pm-nudge-install.sh builds. So: prefer exercising the REAL
# construction code path (main(), for real, up to but not including the
# network call) wherever an interpreter with the SDK installed is reachable;
# fall back to a static check of the source only if none is.
setup_nudge
PY_WITH_SDK=""
for cand in "$HOME/agents/venv/pm-nudge/bin/python3" "$(command -v python3 2>/dev/null)"; do
  [ -n "$cand" ] && [ -x "$cand" ] || continue
  "$cand" -c "import anthropic" >/dev/null 2>&1 && { PY_WITH_SDK="$cand"; break; }
done
if [ -n "$PY_WITH_SDK" ]; then
  out=$("$PY_WITH_SDK" - "$BIN/pm-nudge-compose.py" <<'PYEOF' 2>&1
import importlib.util, sys, unittest.mock

mod_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("pm_nudge_compose", mod_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

captured = {}

class _FakeMessages:
    def create(self, **kwargs):
        raise RuntimeError("network call reached — should not happen in this test")

class _FakeClient:
    def __init__(self, **kwargs):
        captured.update(kwargs)
        self.messages = _FakeMessages()

import anthropic
with unittest.mock.patch.object(anthropic, "Anthropic", _FakeClient), \
     unittest.mock.patch.object(sys, "argv", ["pm-nudge-compose.py"]), \
     unittest.mock.patch.object(
         sys, "stdin",
         unittest.mock.MagicMock(read=lambda: '{"baseline":"anchor"}'),
     ), \
     unittest.mock.patch.dict("os.environ", {"ANTHROPIC_API_KEY": "sk-test-not-real"}):
    try:
        mod.main()
    except SystemExit:
        pass  # expected: main()'s own except-Exception catches the fake
              # network error and calls die() -> sys.exit(1); the client's
              # constructor kwargs were already captured before that point.

assert captured.get("timeout") == mod.HTTP_TIMEOUT_SECONDS, captured
assert captured.get("max_retries") == mod.HTTP_MAX_RETRIES, captured
print(f"OK timeout={captured.get('timeout')} max_retries={captured.get('max_retries')}")
PYEOF
)
  rc=$?
  assert_eq "real construction path: exercised via $PY_WITH_SDK, no static fallback" "$rc" "0"
  assert_contains "client is constructed with the module's timeout/retry constants" "$out" "OK "
else
  echo "  (no python3 with the anthropic SDK importable here or in the pm-nudge venv;"
  echo "   falling back to a static source check, not a real construction call)"
  src=$(cat "$BIN/pm-nudge-compose.py")
  assert_contains "static fallback: Anthropic() is constructed with timeout=" "$src" "timeout=HTTP_TIMEOUT_SECONDS"
  assert_contains "static fallback: Anthropic() is constructed with max_retries=" "$src" "max_retries=HTTP_MAX_RETRIES"
fi
sandbox_rm

finish
