#!/usr/bin/env bash
# pm-nudge-sweep.sh — nudge a PM session whose whole worker fleet has gone quiet.
#
# WHY A SWEEPER, NOT A HOOK. A multi-pane herdr campaign runs one PM
# (project-manager) Claude Code session plus N worker sessions. When the last
# worker finishes, the PM is left sitting idle with nothing to react to: the
# workers' completion produces no event inside the PM's own session, so no Stop
# hook ever fires there. "PM idle AND every worker idle/done/gone" is therefore a
# LEVEL, not an edge — exactly the class of condition auto-handoff-sweep.sh was
# written for, and for exactly the same reason it must be driven by a periodic
# timer and NEVER by a Claude Code hook. A hook-driven version would only wake
# when the PM took a turn, which is precisely the thing that has stopped
# happening.
#
# WHY DETECTION IS DETERMINISTIC AND THE MODEL ONLY WRITES PROSE. Deciding to
# type into somebody's live session is a safety decision, and a safety decision
# made by a sampled model is a safety decision with a failure rate. So the model
# never sees the firing question. This script decides — from `herdr workspace
# list` / `herdr pane list` JSON and file mtimes, with no LLM anywhere in the
# path — and only once it has already decided does it ask Haiku for the WORDS. If
# the model call fails, times out, or returns junk, the nudge still fires with a
# fixed baseline string. Model down must not mean campaign stalled.
#
# WHY A STANDALONE PYTHON SCRIPT AND NOT A CLAUDE CODE SUBAGENT. An in-session
# subagent turn pays a full prompt-prefix rewrite (100-400k tokens) before it
# thinks at all — ~$0.169/call measured on this machine. The same sentence out of
# a bare Haiku call through the anthropic SDK costs ~$0.01. Composing a two-line
# nudge is not worth a prefix rewrite, so the composer is a separate process with
# its own venv (see pm-nudge-compose.py / pm-nudge-install.sh).
#
# Usage:
#   pm-nudge-sweep.sh                 # DRY RUN (default): decide + log, touch nothing
#   pm-nudge-sweep.sh --report        # dry run, plus a human classification table on stdout
#   pm-nudge-sweep.sh --stage-only    # herdr pane send-text (stages the text, NO Enter)
#   pm-nudge-sweep.sh --send          # stage + Enter; requires $STATE/pm-nudge.armed
#
# Control files (under $AUTODEV_HOME/state, default ~/agents/state):
#   disable-pm-nudge        global kill switch, beats everything including --send
#   pm-nudge.armed          arms --send; without it --send degrades to a dry run
#   pm-nudge/<ws>.since     debounce marker: when the quiet condition first held
#   pm-nudge/<ws>.seen      workers observed during the current quiet window
#   pm-nudge/<ws>.cooldown  last time this workspace was actually nudged

set -u

: "${AUTODEV_HOME:=$HOME/agents}"; export AUTODEV_HOME
STATE="$AUTODEV_HOME/state"
LOGDIR="$AUTODEV_HOME/logs"
LOG="$LOGDIR/pm-nudge.log"
NSTATE="$STATE/pm-nudge"
mkdir -p "$STATE" "$LOGDIR" "$NSTATE" 2>/dev/null

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- tunables (all env-overridable) -----------------------------------------
# The PM/worker regexes are INFERRED from observed naming on this machine, not
# guaranteed by herdr or by any campaign tool. They are env-overridable on
# purpose: the day a campaign is laid out differently the fix must not be a code
# change.
#
#   PM pane := cwd basename matches PM_RE       (ckmg-pm4, carmel-pm, t3-pes-pm)
#   worker  := label matches WORKER_RE          (i017-verify-v3-...-D016A01)
#
# WORKER_RE is load-bearing beyond mere labelling: it RECLASSIFIES. A worker
# started inside the PM's own checkout has a PM-shaped cwd, so cwd alone would
# name it the PM and hand the nudge to a busy worker pane. Observed live in
# workspace wH: two panes, both cwd .../scm-pm2, one of them ticket-labelled.
# The ticket label wins.
: "${PM_NUDGE_PM_RE:=-pm[0-9]*$}"
: "${PM_NUDGE_WORKER_RE:=^i[0-9]+-.*-D\\S*A[0-9]+}"
# How long the quiet condition must hold before we believe it. A PM between tool
# calls can read as idle for a second or two; five minutes of continuous quiet
# across the whole workspace is not a gap, it is a stop.
: "${PM_NUDGE_DEBOUNCE:=300}"
# An idle PM stays idle. Without a cooldown the same workspace would be nudged
# on every timer tick forever.
: "${PM_NUDGE_COOLDOWN:=7200}"
# Hard ceiling on the nudge text. Also enforced inside the composer; duplicated
# here because this is the last point before the characters reach a live pane.
: "${PM_NUDGE_MAX_CHARS:=240}"
: "${PM_NUDGE_READ_LINES:=40}"
: "${PM_NUDGE_COMPOSE_TIMEOUT:=30}"
# fleet-digest.json is a nice-to-have extra fact source that does not exist on
# every machine, so it is read opportunistically and never gates anything.
: "${PM_NUDGE_DIGEST:=$STATE/fleet-digest.json}"
: "${PM_NUDGE_DIGEST_MAX_AGE:=3600}"
: "${PM_NUDGE_HERDR:=herdr}"
: "${PM_NUDGE_VENV:=$AUTODEV_HOME/venv/pm-nudge}"
: "${PM_NUDGE_PY:=$PM_NUDGE_VENV/bin/python}"
: "${PM_NUDGE_COMPOSER:=$_HERE/pm-nudge-compose.py}"
# -E (ignore PYTHON* env vars) -s (skip the user site dir). NOT cosmetic: this
# machine exports a PYTHONPATH listing RMG-Py, ARC, molecule, T3, CKMG and Carmel,
# and those directories land AHEAD of the venv's site-packages in sys.path — so a
# venv built precisely to be isolated is, by default, not. A daemon inherits
# whatever environment the timer hands it, so the isolation has to be asserted at
# the call, not assumed from the venv. Tests blank this to substitute a shell stub.
# `=` not `:=` — an explicitly EMPTY value must survive, so a caller (the test
# suite) can substitute a shell stub that would choke on python flags.
: "${PM_NUDGE_PY_ARGS=-E -s}"

# Two semantic anchors, not one. The composer is asked to say the one matching
# the workspace's actual situation; when it cannot (or fails outright), the
# matching literal string is what gets sent. They are kept as SEPARATE shell
# variables, chosen below by an if/else with no shared code path, precisely so
# that a workspace with zero workers ever observed can never fall back to a
# string that claims something finished, and vice versa. Do not collapse these
# back into one BASELINE var.
BASELINE_FINISHED="All your sessions are done, collect and close as needed. What's next?"
BASELINE_NO_WORKERS="Nothing has run in this campaign yet -- no worker sessions were ever seen. What should be dispatched?"

log(){ printf '%s [%s] %s\n' "$(date +'%Y.%m.%d %H.%M.%S')" "$1" "$2" >> "$LOG"; }

# --- argument parsing --------------------------------------------------------
MODE=dry           # dry | stage | send
REPORT=0
for a in "$@"; do
  case "$a" in
    --dry-run)    MODE=dry ;;
    --stage-only) MODE=stage ;;
    --send)       MODE=send ;;
    --report)     REPORT=1 ;;
    -h|--help)    sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
    *) echo "pm-nudge-sweep.sh: unknown argument '$a'" >&2; exit 2 ;;
  esac
done
# --report is an inspection mode; it must never be able to type at a pane.
[ "$REPORT" = 1 ] && MODE=dry

# --- gates that beat everything ---------------------------------------------
if [ -f "$STATE/disable-pm-nudge" ]; then
  [ "$REPORT" = 1 ] && echo "pm-nudge: DISABLED (kill switch $STATE/disable-pm-nudge)"
  exit 0
fi

# Arming is a separate, deliberate act, exactly as auto-handoff.armed is. Asking
# for --send without it is not an error — it is a dry run that says so, which is
# what you want the first time you wire the timer up.
if [ "$MODE" = send ] && [ ! -f "$STATE/pm-nudge.armed" ]; then
  log "-" "NOT ARMED: --send requested but $STATE/pm-nudge.armed is absent; falling back to dry run"
  MODE=dry
fi

command -v jq >/dev/null 2>&1 || { log "-" "ERROR jq not found; cannot parse herdr JSON"; exit 0; }
command -v "$PM_NUDGE_HERDR" >/dev/null 2>&1 || { log "-" "ERROR herdr not found ($PM_NUDGE_HERDR)"; exit 0; }

# --- cycle lock --------------------------------------------------------------
# One cycle can outlive a timer tick, because the composer is a network call.
# Overlapping cycles would double-nudge: both would read the same pre-cooldown
# state. mkdir is the atomic primitive; the pid file is what lets a crashed cycle
# be reclaimed instead of wedging the daemon forever.
LOCK="$STATE/pm-nudge.cycle.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  lpid=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null; then
    log "-" "SKIP cycle already running (pid $lpid)"
    exit 0
  fi
  rm -rf "$LOCK" 2>/dev/null
  mkdir "$LOCK" 2>/dev/null || { log "-" "SKIP could not take cycle lock"; exit 0; }
fi
printf '%s\n' "$$" > "$LOCK/pid"
trap 'rm -rf "$LOCK" 2>/dev/null' EXIT INT TERM

now=$(date +%s)
mtime(){ date -r "$1" +%s 2>/dev/null || echo 0; }
fresh(){ [ -f "$1" ] && [ "$(( now - $(mtime "$1") ))" -le "$2" ]; }

# --- pull the live picture ---------------------------------------------------
WSJSON=$("$PM_NUDGE_HERDR" workspace list 2>/dev/null) || WSJSON=""
PANEJSON=$("$PM_NUDGE_HERDR" pane list 2>/dev/null) || PANEJSON=""
if [ -z "$WSJSON" ] || [ -z "$PANEJSON" ]; then
  log "-" "ERROR herdr returned no data (workspace list / pane list); nothing to do"
  exit 0
fi
printf '%s' "$PANEJSON" | jq -e '.result.panes' >/dev/null 2>&1 || {
  log "-" "ERROR herdr pane list JSON has no .result.panes"; exit 0; }
printf '%s' "$WSJSON" | jq -e '.result.workspaces' >/dev/null 2>&1 || {
  log "-" "ERROR herdr workspace list JSON has no .result.workspaces"; exit 0; }

# --- classification (pure jq; no model, no heuristic beyond the two regexes) --
# Emits one NDJSON record per workspace. A workspace is a PM campaign iff at
# least one of its panes survives as a PM pane after the ticket-label
# reclassification. Every non-PM pane in a campaign workspace then counts as a
# worker for the quiet test — including panes carrying no ticket label at all.
# That is deliberately WIDER than "label matches WORKER_RE": an unlabelled busy
# pane in a campaign workspace is still somebody's live work, and the cost of
# waiting for it is one more timer tick, while the cost of typing over it is
# real.
CLASS=$(jq -n -c \
  --argjson ws "$WSJSON" --argjson pn "$PANEJSON" \
  --arg pmre "$PM_NUDGE_PM_RE" --arg workre "$PM_NUDGE_WORKER_RE" '
  (($ws.result.workspaces // []) | map({key: .workspace_id, value: (.label // "")}) | from_entries) as $wslabel
  | ($pn.result.panes // [])
  | map({
      pane_id, workspace_id,
      cwd:    (.cwd // ""),
      status: (.agent_status // "unknown"),
      label:  (.label // "")
    })
  | map(. + { base: (.cwd | sub("/+$"; "") | split("/") | last // "") })
  | map(. + {
      is_ticket: (((.label | length) > 0) and (.label | test($workre))),
      pm_cwd:    (.base | test($pmre; "i"))
    })
  | map(. + { is_pm: (.pm_cwd and (.is_ticket | not)) })
  | group_by(.workspace_id)
  | map(
      . as $all
      | (map(select(.is_pm))) as $pms
      | ($all[0].workspace_id) as $wsid
      | ($pms[0] // null) as $pm
      | (if $pm == null then $all else (map(select(.pane_id != $pm.pane_id))) end) as $workers
      | {
          ws:          $wsid,
          ws_label:    ($wslabel[$wsid] // ""),
          is_campaign: (($pms | length) > 0),
          pm_count:    ($pms | length),
          pm:          $pm,
          pane_count:  ($all | length),
          # `label:` must be spelled out: bare `label` is a jq KEYWORD (label/break),
          # so the {a, b} shorthand is a syntax error on exactly this one field.
          workers:     ($workers | map({pane_id, label: .label, cwd, status})),
          blocked:     ($all | map(select(.status == "blocked")) | map(.pane_id)),
          busy:        ($workers | map(select(.status != "idle" and .status != "done"))
                                 | map({pane_id, status}))
        }
    )
  | sort_by(.ws)[]
') || { log "-" "ERROR classification jq failed"; exit 0; }

# --- fleet digest (optional, never blocking) ---------------------------------
DIGEST=null
if fresh "$PM_NUDGE_DIGEST" "$PM_NUDGE_DIGEST_MAX_AGE"; then
  if jq -e . "$PM_NUDGE_DIGEST" >/dev/null 2>&1; then
    DIGEST=$(jq -c . "$PM_NUDGE_DIGEST")
  else
    log "-" "fleet digest present but not valid JSON; ignoring"
  fi
fi

# --- pane-buffer safety check ------------------------------------------------
# Three-valued on purpose:
#   0 clear        — nothing that looks like a menu; Enter is safe
#   1 menu         — something IS waiting for a keystroke; do not stage, do not send
#   2 inconclusive — herdr would not tell us; stage only, never Enter
#
# The three-way split is the whole point. A two-valued check has to fold
# "inconclusive" into one of the other two, and either choice is wrong: fold it
# into "clear" and a failed read becomes a blind Enter into an unknown pane; fold
# it into "menu" and one transient herdr hiccup silently kills the feature.
#
# Note this is stricter than the obvious design: a POSITIVE menu detection
# suppresses even send-text, because send-text into an open permission dialog
# types into that dialog's filter box rather than into a prompt.
MENU_RE='(Do you want to |Would you like to |❯[[:space:]]*[0-9]+\.|^[[:space:]]*[0-9]+\.[[:space:]]+(Yes|No)\b|\(y/n\)|\[y/N\]|\[Y/n\]|Select an option|Choose an option|esc to interrupt|Press Enter to continue)'
buffer_state(){ # $1 = pane id
  local out
  out=$("$PM_NUDGE_HERDR" pane read "$1" --source visible --lines "$PM_NUDGE_READ_LINES" --format text 2>/dev/null) || return 2
  [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ] || return 2
  printf '%s\n' "$out" | tail -n 15 | grep -Eq "$MENU_RE" && return 1
  return 0
}

# Re-read the pane's own status straight from herdr immediately before acting.
# The list snapshot taken at the top of this cycle can be tens of seconds old by
# the time the composer returns, and "was idle when we started thinking" is not
# the question — "is idle now" is.
pane_status_now(){ # $1 = pane id
  "$PM_NUDGE_HERDR" pane get "$1" 2>/dev/null \
    | jq -r '(.result.agent_status // .agent_status // "")' 2>/dev/null
}

# `done` counts as quiet. It is a real, live herdr status (7 panes carried it
# during development) that the upstream docs omit; mux-lib.sh has always
# enumerated it. A done pane is finished, not busy and not waiting on a human,
# so for the purpose of "is it safe and useful to nudge" it is exactly idle.
quiet_status(){ case "$1" in idle|done) return 0 ;; *) return 1 ;; esac; }

# --- the nudge text ----------------------------------------------------------
# Newlines are stripped unconditionally and last. herdr's send-text stages
# characters into the pane's input line, and an embedded newline in that payload
# submits it — which would silently turn --stage-only into a send. Nothing
# downstream of this function is allowed to reintroduce one.
sanitize(){ printf '%s' "$1" | tr '\n\r\t' '   ' | sed 's/  */ /g; s/^ //; s/ $//' | cut -c "1-$PM_NUDGE_MAX_CHARS"; }

compose(){ # $1 = facts JSON, $2 = ws (for the log) -> prints text, or fails
  [ -x "$PM_NUDGE_PY" ] || { log "$2" "composer: no interpreter at $PM_NUDGE_PY"; return 1; }
  [ -f "$PM_NUDGE_COMPOSER" ] || { log "$2" "composer: no script at $PM_NUDGE_COMPOSER"; return 1; }
  local out
  # PM_NUDGE_PY_ARGS is intentionally word-split (it is a flag list, not a path).
  # shellcheck disable=SC2086
  out=$(printf '%s' "$1" | timeout "$PM_NUDGE_COMPOSE_TIMEOUT" \
          "$PM_NUDGE_PY" $PM_NUDGE_PY_ARGS "$PM_NUDGE_COMPOSER" 2>>"$LOG") || return 1
  [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ] || return 1
  printf '%s' "$out"
}

# --- per-workspace decision --------------------------------------------------
report_rows=()
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  ws=$(printf '%s' "$rec" | jq -r '.ws')
  # ws becomes part of a file path and is written verbatim into a shared log.
  case "$ws" in ""|*[!A-Za-z0-9._-]*) continue ;; esac
  ws_label=$(printf '%s' "$rec" | jq -r '.ws_label')
  since_f="$NSTATE/$ws.since"
  seen_f="$NSTATE/$ws.seen"
  cool_f="$NSTATE/$ws.cooldown"

  # -- not a campaign: forget everything we ever knew about it ---------------
  if [ "$(printf '%s' "$rec" | jq -r '.is_campaign')" != "true" ]; then
    rm -f "$since_f" "$seen_f" 2>/dev/null
    report_rows+=("$ws|$ws_label|-|-|excluded: no pane cwd matches the PM regex")
    continue
  fi

  pm_pane=$(printf '%s' "$rec" | jq -r '.pm.pane_id')
  pm_status=$(printf '%s' "$rec" | jq -r '.pm.status')
  pm_cwd=$(printf '%s' "$rec" | jq -r '.pm.cwd')
  pm_count=$(printf '%s' "$rec" | jq -r '.pm_count')
  workers=$(printf '%s' "$rec" | jq -c '.workers')
  nworkers=$(printf '%s' "$rec" | jq -r '.workers | length')
  blocked=$(printf '%s' "$rec" | jq -r '.blocked | join(",")')
  busy=$(printf '%s' "$rec" | jq -r '.busy | map(.pane_id + "=" + .status) | join(",")')

  [ "$pm_count" -gt 1 ] && log "$ws" "NOTE $pm_count PM-shaped panes; using $pm_pane"

  # -- hard veto: anything blocked, anywhere in the workspace -----------------
  # Blocked means a pane is waiting on a human. Typing a nudge at the PM while
  # any pane in its workspace holds an open prompt is the one outcome this
  # daemon must never produce, so it is checked before everything else — and it
  # also RESETS the debounce window. A workspace that passed through a blocked
  # state has to earn its quiet period again from zero, rather than banking the
  # seconds it spent stuck.
  if [ -n "$blocked" ]; then
    rm -f "$since_f" "$seen_f" 2>/dev/null
    report_rows+=("$ws|$ws_label|$pm_pane|$pm_status|HOLD: blocked pane(s) $blocked")
    continue
  fi

  if ! quiet_status "$pm_status"; then
    rm -f "$since_f" "$seen_f" 2>/dev/null
    report_rows+=("$ws|$ws_label|$pm_pane|$pm_status|HOLD: PM is $pm_status")
    continue
  fi

  if [ -n "$busy" ]; then
    rm -f "$since_f" "$seen_f" 2>/dev/null
    report_rows+=("$ws|$ws_label|$pm_pane|$pm_status|HOLD: worker(s) busy $busy")
    continue
  fi

  # -- the quiet condition holds; is it OLD enough? --------------------------
  # The marker carries the PM pane id, because herdr recycles short pane ids. A
  # debounce window accumulated against one PM pane must not be spent on a
  # different session that later inherited that id.
  since=0; since_pane=""
  if [ -f "$since_f" ]; then
    read -r since since_pane < "$since_f" 2>/dev/null || true
    case "$since" in ''|*[!0-9]*) since=0 ;; esac
  fi
  if [ "$since" = 0 ] || [ "$since_pane" != "$pm_pane" ]; then
    since=$now
    printf '%s %s\n' "$since" "$pm_pane" > "$since_f"
    : > "$seen_f"
  fi
  quiet=$(( now - since ))

  # Remember every worker seen while the window is open, so a worker whose pane
  # has since been CLOSED can still be named in the nudge. "All five finished"
  # is a fact the PM can act on; "no workers are present" is not.
  {
    cat "$seen_f" 2>/dev/null
    printf '%s' "$rec" | jq -r '.workers[] | [.pane_id, (.label // ""), .cwd] | @tsv'
  } | awk -F'\t' 'NF && !seen[$1]++' > "$seen_f.tmp" 2>/dev/null && mv "$seen_f.tmp" "$seen_f"

  if [ "$quiet" -lt "$PM_NUDGE_DEBOUNCE" ]; then
    report_rows+=("$ws|$ws_label|$pm_pane|$pm_status|WAIT: quiet ${quiet}s < debounce ${PM_NUDGE_DEBOUNCE}s")
    continue
  fi

  if fresh "$cool_f" "$PM_NUDGE_COOLDOWN"; then
    age=$(( now - $(mtime "$cool_f") ))
    report_rows+=("$ws|$ws_label|$pm_pane|$pm_status|COOLDOWN: nudged ${age}s ago (< ${PM_NUDGE_COOLDOWN}s)")
    continue
  fi

  # -- ELIGIBLE ---------------------------------------------------------------
  # The vacuous case is deliberate: a campaign workspace with a PM pane and zero
  # workers satisfies "every worker is idle/done/gone" trivially, because the
  # workers are gone. That is a common shape of the situation this daemon
  # exists for, so suppressing it would gut the feature. It is spelled out here
  # rather than absorbed silently, because "fires on a workspace with no
  # workers in it" reads like a bug until you know why.
  #
  # But it is NOT the same situation as a fleet that actually ran and finished,
  # and the nudge text must not conflate the two: "collect and close" is a
  # false claim when nothing ever ran. So the branch is decided HERE, once, from
  # the deterministic count of workers ever seen during this quiet window
  # (seen_f, accumulated above regardless of which branch fires) — and every
  # downstream consumer (facts sent to the composer, and the code-level
  # fallback string) reads off this one decision rather than re-deriving it.
  gone_json='[]'
  if [ -s "$seen_f" ]; then
    gone_json=$(jq -R -s -c --argjson present "$workers" '
      split("\n")
      | map(select(length > 0) | split("\t") | {pane_id: .[0], label: (.[1] // ""), cwd: (.[2] // "")})
      | map(select(.pane_id as $p | ($present | map(.pane_id) | index($p)) == null))
    ' < "$seen_f") || gone_json='[]'
  fi
  ngone=$(printf '%s' "$gone_json" | jq -r 'length')
  total_seen=$(( nworkers + ngone ))

  vacuous=""
  if [ "$total_seen" = 0 ]; then
    SITUATION=no_workers_ever
    WS_BASELINE="$BASELINE_NO_WORKERS"
    vacuous=" (no worker panes present: vacuously quiet)"
  else
    SITUATION=workers_finished
    WS_BASELINE="$BASELINE_FINISHED"
  fi

  reason="PM $pm_pane $pm_status, ${nworkers} worker(s) all idle/done, ${ngone} gone, quiet ${quiet}s >= ${PM_NUDGE_DEBOUNCE}s, no blocked panes${vacuous} situation=$SITUATION message=\"$WS_BASELINE\""
  report_rows+=("$ws|$ws_label|$pm_pane|$pm_status|FIRE: $reason")

  if [ "$MODE" = dry ]; then
    # An unarmed daemon on a 5-minute timer would otherwise write the same
    # ELIGIBLE line about the same parked PM 288 times a day, forever — the
    # dry-run state is stable by definition, since nothing consumes it. The
    # notice is rate-limited to one per cooldown period, in a file DISTINCT
    # from the real cooldown: a dry run must never be able to suppress the
    # first genuine nudge after arming.
    noted_f="$NSTATE/$ws.dry-noted"
    if ! fresh "$noted_f" "$PM_NUDGE_COOLDOWN"; then
      log "$ws" "ELIGIBLE $reason [mode=dry]"
      log "$ws" "DRY RUN — no text staged, no keys sent (further notices suppressed for ${PM_NUDGE_COOLDOWN}s)"
      : > "$noted_f"
    fi
    continue
  fi
  log "$ws" "ELIGIBLE $reason [mode=$MODE]"

  # -- re-confirm against live herdr, not the cycle-opening snapshot ----------
  live=$(pane_status_now "$pm_pane")
  if [ -z "$live" ]; then
    log "$ws" "ABORT could not re-read $pm_pane status; refusing to act on a stale snapshot"
    continue
  fi
  if ! quiet_status "$live"; then
    log "$ws" "ABORT $pm_pane is now '$live' (was $pm_status); not acting"
    continue
  fi

  buffer_state "$pm_pane"; bstate=$?
  case "$bstate" in
    1) log "$ws" "ABORT $pm_pane shows an interactive prompt/menu; not staging anything"
       continue ;;
    2) log "$ws" "DEGRADE could not read $pm_pane's buffer; stage-only (never Enter)" ;;
  esac

  # -- compose (model), with the baseline as the guaranteed floor -------------
  facts=$(jq -n -c \
    --arg ws "$ws" --arg wslabel "$ws_label" \
    --arg pm_pane "$pm_pane" --arg pm_cwd "$pm_cwd" --arg pm_status "$pm_status" \
    --argjson quiet "$quiet" --argjson workers "$workers" --argjson gone "$gone_json" \
    --arg situation "$SITUATION" --argjson workers_seen_total "$total_seen" \
    --argjson workers_gone_count "$ngone" \
    --arg baseline "$WS_BASELINE" --argjson max_chars "$PM_NUDGE_MAX_CHARS" \
    --argjson digest "$DIGEST" '
    { workspace:       {id: $ws, label: $wslabel},
      pm:              {pane_id: $pm_pane, cwd: $pm_cwd, status: $pm_status, quiet_seconds: $quiet},
      situation:       $situation,
      workers_seen_total: $workers_seen_total,
      workers_gone_count: $workers_gone_count,
      workers_present: $workers,
      workers_gone:    $gone,
      baseline:        $baseline,
      max_chars:       $max_chars,
      fleet_digest:    $digest }')

  if text=$(compose "$facts" "$ws"); then
    text=$(sanitize "$text")
    src=haiku
  else
    text=""
    src=baseline
  fi
  [ -n "$text" ] || { text=$(sanitize "$WS_BASELINE"); src=baseline; }
  log "$ws" "TEXT ($src) $text"

  if ! "$PM_NUDGE_HERDR" pane send-text "$pm_pane" "$text" >/dev/null 2>&1; then
    log "$ws" "ERROR send-text failed for $pm_pane; nothing staged, no cooldown recorded"
    continue
  fi
  log "$ws" "STAGED into $pm_pane ($src, ${#text} chars)"

  if [ "$MODE" = send ] && [ "$bstate" = 0 ]; then
    if "$PM_NUDGE_HERDR" pane send-keys "$pm_pane" Enter >/dev/null 2>&1; then
      log "$ws" "SENT Enter to $pm_pane"
    else
      log "$ws" "ERROR send-keys Enter failed for $pm_pane; text remains staged"
    fi
  elif [ "$MODE" = send ]; then
    log "$ws" "STAGE-ONLY (degraded) — text is staged in $pm_pane but NOT submitted"
  fi

  # The cooldown is recorded once anything reached the pane, submitted or not:
  # re-staging on top of already-staged text is exactly the repeat-nudge this
  # cooldown exists to prevent.
  : > "$cool_f"
done <<< "$CLASS"

if [ "$REPORT" = 1 ]; then
  printf '%-4s %-10s %-9s %-8s %s\n' WS LABEL PM-PANE PM-ST VERDICT
  printf '%-4s %-10s %-9s %-8s %s\n' ---- ---------- --------- -------- -------
  for r in ${report_rows+"${report_rows[@]}"}; do
    IFS='|' read -r a b c d e <<<"$r"
    printf '%-4s %-10s %-9s %-8s %s\n' "$a" "$b" "$c" "$d" "$e"
  done
  printf '\nmode=%s debounce=%ss cooldown=%ss pm_re=%s worker_re=%s\n' \
    "$MODE" "$PM_NUDGE_DEBOUNCE" "$PM_NUDGE_COOLDOWN" "$PM_NUDGE_PM_RE" "$PM_NUDGE_WORKER_RE"
fi

exit 0
