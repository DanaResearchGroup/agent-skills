#!/usr/bin/env bash
# fleet-digest: a read-only, no-judgment collector of "what is the state of
# the fleet" — sessions, herdr panes, git worktrees, open PRs — into one JSON
# file. Cron'd (or systemd-timered) separately from any Claude session, so a
# PM/fleet session reads ONE file instead of firing twenty-plus Bash calls
# whose results then get re-served in its prompt prefix on every later turn.
#
# The governing rule, and the reason this file is not smarter than it looks:
# externalise the EVIDENCE GATHERING, never the verdict. This script collects
# facts. It makes no decisions, takes no actions, and never writes anywhere
# except its own --out file. No LLM is involved anywhere in this version.
#
# Output contract (see autodev/README.md "fleet-digest" section for the full
# writeup a consumer should read before trusting a field):
#   - written ATOMICALLY: built in a temp file on the same filesystem as
#     --out, then `mv`'d into place. A reader never sees a half-written file.
#   - EVERY section carries its own ok / error / collected_at. A consumer
#     must be able to tell "no open PRs" apart from "the PR scan failed" --
#     those must never look the same. A failed section reports ok:false with
#     an error string and whatever partial data it managed, never an empty
#     list dressed up as a clean result. One failing section must never stop
#     the others from populating, and the run as a whole still writes a
#     digest with the good sections intact.
#   - bounded runtime: every external call (herdr, gh, git) carries its own
#     timeout, the PR scan (the dominant cost -- one `gh` call per remote)
#     is parallelised, and the whole run is capped by --timeout, past which
#     it writes whatever it has and marks the unfinished sections ok:false.
#
# Usage:
#   fleet-digest.sh [--out PATH] [--summary-out PATH] [--root PATH]...
#                    [--session-max-age SECS] [--timeout SECS] [-h|--help]
#
# Writes TWO files: the full digest at --out, and a companion summary (a few
# KB: counts, failed sources, PRs labelled mine, dirty/ahead/behind
# worktrees) at --summary-out. A consumer should read the summary by
# default -- the full digest runs ~250KB and defeats its own purpose if
# that lands in a session's prompt prefix on every turn.
#
# Exit code: 0 when a digest was written (even a partial one). Non-zero ONLY
# when no digest could be written at all (e.g. --out's directory does not
# exist and could not be created, or every section crashed before producing
# valid JSON and even the all-failed fallback digest could not be written).
set -uo pipefail
export LC_ALL=C

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

json_str() { # best-effort shell-side JSON string escaping for tiny fragments
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ===========================================================================
# Collectors. Each is re-exec'd as its own process (see dispatch below) and
# must print exactly one JSON object to stdout: {"ok":..., "error":...,
# "collected_at":..., ...data...}. Nothing else may go to stdout.
# ===========================================================================

# --- sessions --------------------------------------------------------------
# ~/agents/state/*.ctx is 5,431+ files, most of them dead history (months
# stale). Without the age filter this section is useless noise; WITH it, a
# consumer sees only sessions that plausibly still exist. filtered_out_count
# lets a consumer see the filter actually did something, rather than silently
# trusting an empty-looking cutoff.
collect_sessions() {
  local state="$1" max_age="$2"
  local now; now=$(date +%s)
  echo '{"ok": true, "error": null, "collected_at": "'"$(now_iso)"'", "max_age_s": '"$max_age"', "sessions": ['
  local first=1 filtered=0 total=0
  shopt -s nullglob
  for ctxf in "$state"/*.ctx; do
    total=$((total + 1))
    local base uuid line pct ts age
    base=$(basename "$ctxf" .ctx)
    # Companion state files live beside <uuid>.ctx as <uuid>.<suffix>; only a
    # real 36-char UUID basename is trusted as a session (a handful of stray
    # non-UUID .ctx files exist on this box from ad hoc testing).
    case "$base" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
      *) continue ;;
    esac
    uuid="$base"
    line=$(cat "$ctxf" 2>/dev/null)
    # Format is `pct=NN ts=EPOCH`; a line that doesn't match is a corrupt or
    # foreign file -- skip it rather than emit garbage pct/ts.
    case "$line" in
      pct=*' ts='*) ;;
      *) continue ;;
    esac
    pct=${line#pct=}; pct=${pct%% *}
    ts=${line##* ts=}
    case "$pct" in ''|*[!0-9]*) continue ;; esac
    case "$ts" in ''|*[!0-9]*) continue ;; esac
    age=$(( now - ts ))
    if [ "$age" -gt "$max_age" ]; then
      filtered=$((filtered + 1))
      continue
    fi
    local companions="{" cfirst=1 f suffix content
    for f in "$state/$uuid".*; do
      [ -e "$f" ] || continue
      suffix=${f##*.}
      [ "$suffix" = "ctx" ] && continue
      content=$(head -c 200 "$f" 2>/dev/null | tr -d '\n')
      [ $cfirst -eq 1 ] || companions+=", "
      companions+="$(json_str "$suffix"): $(json_str "$content")"
      cfirst=0
    done
    companions+="}"
    [ $first -eq 1 ] || echo ','
    first=0
    printf '{"uuid": %s, "pct": %s, "ts": %s, "age_s": %s, "companions": %s}' \
      "$(json_str "$uuid")" "$pct" "$ts" "$age" "$companions"
  done
  echo ']'
  printf ', "filtered_out_count": %s, "total_ctx_files": %s}\n' "$filtered" "$total"
}

# --- panes -------------------------------------------------------------
collect_panes() {
  local errf out rc
  errf=$(mktemp)
  out=$(timeout 15 herdr pane list 2>"$errf")
  rc=$?
  local err; err=$(tr -d '\n' <"$errf" 2>/dev/null); rm -f "$errf"
  if [ $rc -ne 0 ] || [ -z "$out" ]; then
    printf '{"ok": false, "error": %s, "collected_at": %s, "panes": []}\n' \
      "$(json_str "herdr pane list failed (exit $rc): $err")" "$(json_str "$(now_iso)")"
    return 0
  fi
  # herdr already speaks JSON; python3 reshapes {result:{panes:[...]}} into
  # our section envelope rather than us hand-building pane objects in bash.
  python3 -c '
import json, sys, datetime
raw = sys.stdin.read()
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
try:
    doc = json.loads(raw)
    panes = doc.get("result", {}).get("panes", [])
    out = []
    for p in panes:
        sess = p.get("agent_session") or {}
        out.append({
            "pane_id": p.get("pane_id"),
            "tab_id": p.get("tab_id"),
            "workspace_id": p.get("workspace_id"),
            "agent": p.get("agent"),
            "agent_status": p.get("agent_status"),
            "label": p.get("label"),
            "cwd": p.get("cwd"),
            "agent_session_id": sess.get("value"),
        })
    print(json.dumps({"ok": True, "error": None, "collected_at": now, "panes": out}))
except Exception as e:
    print(json.dumps({"ok": False, "error": "failed to parse herdr output: %r" % (e,), "collected_at": now, "panes": []}))
' <<<"$out"
}

# --- worktrees ---------------------------------------------------------
# Never runs `git fetch` -- read-only observer. ahead/behind is only as
# fresh as the last manual fetch of each remote-tracking ref.
collect_worktrees() {
  local roots=("$@")
  local list_file err_file
  list_file=$(mktemp); err_file=$(mktemp)
  local errors=() root
  for root in "${roots[@]}"; do
    local root_err
    root_err=$(mktemp)
    if ! find "$root" -name .git -print -prune >>"$list_file" 2>"$root_err"; then
      errors+=("walking $root: $(tr -d '\n' <"$root_err")")
    fi
    rm -f "$root_err"
  done
  sort -u -o "$list_file" "$list_file"

  # Per-worktree git calls are the dominant cost here (measured: ~28s
  # sequential across ~370 worktrees on this box, mostly process-spawn
  # overhead rather than any single call being slow). Fan them out with
  # bounded concurrency -- each worktree's JSON object is written to its own
  # numbered file by a backgrounded subshell, throttled to MAX_JOBS in
  # flight at once so we don't fork 370 processes simultaneously.
  local per_wt_dir; per_wt_dir=$(mktemp -d)
  local MAX_JOBS=16
  local running=0 idx=0 gitfile
  while IFS= read -r gitfile; do
    [ -n "$gitfile" ] || continue
    idx=$((idx + 1))
    (
      dir=$(dirname "$gitfile")
      status=$(timeout 5 git -C "$dir" status --porcelain=v2 --branch 2>/dev/null) || exit 0
      [ -n "$status" ] || exit 0
      branch=$(printf '%s\n' "$status" | awk '/^# branch\.head /{print $3; exit}')
      oid=$(printf '%s\n' "$status" | awk '/^# branch\.oid /{print $3; exit}')
      ab=$(printf '%s\n' "$status" | awk '/^# branch\.ab /{print $3, $4; exit}')
      ahead=0; behind=0
      if [ -n "$ab" ]; then
        ahead=${ab%% *}; ahead=${ahead#+}
        behind=${ab##* }; behind=${behind#-}
      fi
      dirty=$(printf '%s\n' "$status" | grep -vc '^#')
      # Prefer the `official` remote; fall back to `origin` -- many repos
      # here have no `origin` at all (see autodev README's git conventions).
      url=$(timeout 5 git -C "$dir" config --get remote.official.url 2>/dev/null)
      [ -n "$url" ] || url=$(timeout 5 git -C "$dir" config --get remote.origin.url 2>/dev/null)
      if [ -z "$url" ]; then
        url=$(timeout 5 git -C "$dir" config --get-regexp '^remote\..*\.url$' 2>/dev/null | head -1 | awk '{print $2}')
      fi
      [ -n "$url" ] && remote=$(json_str "$url") || remote=null
      printf '{"path": %s, "remote_url": %s, "branch": %s, "head_sha": %s, "dirty_count": %s, "ahead": %s, "behind": %s}' \
        "$(json_str "$dir")" "$remote" "$(json_str "${branch:-}")" "$(json_str "${oid:-}")" "${dirty:-0}" "${ahead:-0}" "${behind:-0}" \
        >"$per_wt_dir/$idx.json"
    ) &
    running=$((running + 1))
    if [ "$running" -ge "$MAX_JOBS" ]; then
      wait -n 2>/dev/null || wait
      running=$((running - 1))
    fi
  done <"$list_file"
  wait

  local arr_file; arr_file=$(mktemp)
  {
    echo -n '['
    local first=1 f
    for f in "$per_wt_dir"/*.json; do
      [ -e "$f" ] || continue
      [ $first -eq 1 ] || echo ','
      first=0
      cat "$f"
    done
    echo ']'
  } >"$arr_file"
  local wt_json; wt_json=$(cat "$arr_file")
  rm -rf "$arr_file" "$list_file" "$err_file" "$per_wt_dir"

  local ok=true errmsg=null
  if [ ${#errors[@]} -gt 0 ]; then
    ok=false
    errmsg="$(python3 -c 'import json,sys; print(json.dumps("; ".join(sys.argv[1:])))' "${errors[@]}")"
  fi
  printf '{"ok": %s, "error": %s, "collected_at": %s, "roots": %s, "worktrees": %s}\n' \
    "$ok" "$errmsg" "$(json_str "$(now_iso)")" \
    "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${roots[@]}")" "$wt_json"
}

# --- prs -----------------------------------------------------------------
collect_prs() {
  local roots=("$@")
  if ! command -v gh >/dev/null 2>&1; then
    printf '{"ok": false, "error": "gh not found on PATH", "collected_at": %s, "my_login": null, "remote_count": 0, "remotes": []}\n' "$(json_str "$(now_iso)")"
    return 0
  fi

  # Resolve the authenticated gh user ONCE per run (not once per PR) so each
  # PR can be labelled is_mine vs. someone-else's. Most repos under a broad
  # --root are clones of upstream projects the user doesn't own -- without
  # this label the digest is mostly noise a consumer has to re-filter by
  # hand every time. Never dropped: an unresolved login still yields every
  # PR with is_mine:null (not false -- false would silently misreport
  # "definitely not mine" for data we simply couldn't check).
  local my_login
  my_login=$(timeout 10 gh api user -q .login 2>/dev/null)
  [ -n "$my_login" ] || my_login=""

  # Distinct GitHub remotes across all worktrees under the configured roots.
  # This re-walks the same roots the worktrees collector does (cheap: config
  # reads, no network) rather than depending on that collector's output, so
  # the two sections stay failure-independent, per the section-isolation rule.
  local remotes_file; remotes_file=$(mktemp)
  local root gitfile dir url
  for root in "${roots[@]}"; do
    find "$root" -name .git -print -prune 2>/dev/null | while IFS= read -r gitfile; do
      dir=$(dirname "$gitfile")
      url=$(timeout 5 git -C "$dir" config --get remote.official.url 2>/dev/null)
      [ -n "$url" ] || url=$(timeout 5 git -C "$dir" config --get remote.origin.url 2>/dev/null)
      [ -n "$url" ] && echo "$url"
    done
  done | sort -u >"$remotes_file"

  # Normalise github.com URLs (https or ssh form) to owner/repo; non-GitHub
  # remotes are skipped since `gh` only speaks GitHub.
  local slugs_file; slugs_file=$(mktemp)
  python3 -c '
import re, sys
seen = set()
for line in sys.stdin:
    u = line.strip()
    m = re.search(r"github\.com[:/]+([^/]+)/([^/.]+?)(\.git)?/?$", u)
    if not m:
        continue
    slug = "%s/%s" % (m.group(1), m.group(2))
    if slug not in seen:
        seen.add(slug)
        print(slug)
' <"$remotes_file" >"$slugs_file"
  rm -f "$remotes_file"

  local n_slugs; n_slugs=$(wc -l <"$slugs_file" | tr -d ' ')
  local resdir; resdir=$(mktemp -d)
  local slug i=0
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    i=$((i + 1))
    (
      local pr_json rc emsg
      pr_json=$(timeout 20 gh pr list --repo "$slug" --state open \
        --json number,title,headRefName,mergeStateStatus,reviewDecision,isDraft,updatedAt,url,author 2>"$resdir/$i.err")
      rc=$?
      if [ $rc -eq 0 ] && [ -n "$pr_json" ]; then
        local tagged_json
        tagged_json=$(python3 -c '
import json, sys
prs = json.loads(sys.argv[1])
my_login = sys.argv[2] or None
out = []
for p in prs:
    author = (p.get("author") or {}).get("login")
    p["author_login"] = author
    p["is_mine"] = (author == my_login) if my_login is not None else None
    out.append(p)
print(json.dumps(out))
' "$pr_json" "$my_login")
        printf '{"remote": %s, "ok": true, "error": null, "prs": %s}\n' "$(json_str "$slug")" "$tagged_json" >"$resdir/$i.json"
      else
        emsg=$(tr -d '\n' <"$resdir/$i.err" 2>/dev/null)
        printf '{"remote": %s, "ok": false, "error": %s, "prs": []}\n' "$(json_str "$slug")" "$(json_str "gh pr list exit $rc: $emsg")" >"$resdir/$i.json"
      fi
    ) &
  done <"$slugs_file"
  wait
  rm -f "$slugs_file"

  local combined_file; combined_file=$(mktemp)
  {
    echo -n '['
    local first=1 f
    for f in "$resdir"/*.json; do
      [ -e "$f" ] || continue
      [ $first -eq 1 ] || echo ','
      first=0
      cat "$f"
    done
    echo ']'
  } >"$combined_file"
  local combined; combined=$(cat "$combined_file")
  rm -rf "$resdir" "$combined_file"

  # An unresolved login is a real, reportable degradation (every PR's
  # is_mine reads null instead of a real answer) even though PR data itself
  # still collected fine -- surface it via error without flipping ok:false,
  # since the section's actual job (listing PRs) succeeded.
  local login_field prs_error
  if [ -n "$my_login" ]; then
    login_field="$(json_str "$my_login")"
    prs_error=null
  else
    login_field=null
    prs_error="$(json_str "could not resolve authenticated gh user via 'gh api user' -- is_mine is null for every PR in this run")"
  fi

  printf '{"ok": true, "error": %s, "collected_at": %s, "my_login": %s, "remote_count": %s, "remotes": %s}\n' \
    "$prs_error" "$(json_str "$(now_iso)")" "$login_field" "$n_slugs" "$combined"
}

# --- internal dispatch -------------------------------------------------
# Each collector above is invoked as a SEPARATE process, wrapped in its own
# `timeout`, by re-executing this same file with a leading __collect_* verb.
# That is what lets one hung `git`/`gh`/`herdr` call be killed without taking
# the other three sections down with it -- a plain shell function backgrounded
# in-process shares no such isolation (a wedged external command run via `&`
# still leaves the *shell* alive and waitable, but SIGKILLing "the section"
# then means SIGKILLing the whole script). Re-exec is the boring, portable way
# to get a real process boundary out of bash.
case "${1:-}" in
  __collect_sessions)  shift; collect_sessions "$@"; exit $? ;;
  __collect_panes)     shift; collect_panes "$@"; exit $? ;;
  __collect_worktrees) shift; collect_worktrees "$@"; exit $? ;;
  __collect_prs)       shift; collect_prs "$@"; exit $? ;;
esac

# --- args ----------------------------------------------------------------
OUT="${AUTODEV_HOME:-$HOME/agents}/state/fleet-digest.json"
SUMMARY_OUT=""
ROOTS=()
SESSION_MAX_AGE=86400
TIMEOUT=60
STATE_DIR="${AUTODEV_HOME:-$HOME/agents}/state"

usage() {
  cat <<'EOF'
fleet-digest.sh -- collect one fleet-state JSON snapshot (evidence only, no verdicts).

  --out PATH                where to write the full digest (default: $AUTODEV_HOME/state/fleet-digest.json,
                             i.e. ~/agents/state/fleet-digest.json)
  --summary-out PATH         where to write the companion summary (default: --out with
                              ".json" replaced by "-summary.json"). A PM/fleet session should
                              read THIS file by default -- it is the few-KB slice a consumer
                              actually needs (counts, failed sources, PRs labelled mine,
                              worktrees that are dirty/ahead/behind). Reach for the full
                              --out digest only when the summary's counts say there's more
                              to look at than the summary itself carries.
  --root PATH                a root to walk for git worktrees (repeatable; default: ~/Code)
  --session-max-age SECS     drop .ctx sessions older than this (default: 86400 = 24h)
  --timeout SECS             overall wall-clock budget; unfinished sections are written
                              ok:false rather than blocking forever (default: 60)
  -h, --help                 this text

Exit code: 0 when a digest (even a partial one) was written. Non-zero ONLY when
no digest could be written at all. A summary-write failure is logged to stderr
but does not fail the run -- the full digest is the authoritative artifact.

Never runs `git fetch` -- ahead/behind is computed against whatever remote-tracking
refs already exist locally, which are only as fresh as the last manual fetch.

PRs are labelled, never dropped: each PR carries author_login and is_mine (true/false),
compared against the authenticated `gh` user (resolved once per run via `gh api user`).
If that resolution fails, is_mine is null (not false) for every PR, and the prs section's
error field says so -- an unknown label must never silently read as "not mine".
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --summary-out) SUMMARY_OUT="$2"; shift 2 ;;
    --root) ROOTS+=("$2"); shift 2 ;;
    --session-max-age) SESSION_MAX_AGE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fleet-digest.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ ${#ROOTS[@]} -eq 0 ] && ROOTS=("$HOME/Code")
[ -n "$SUMMARY_OUT" ] || SUMMARY_OUT="${OUT%.json}-summary.json"

START_MS=$(( $(date +%s%N) / 1000000 ))

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-digest.XXXXXX") || { echo "fleet-digest.sh: mktemp failed" >&2; exit 1; }
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ===========================================================================
# Orchestration: launch each collector as its own re-exec'd, `timeout`-capped
# process, wait for all of them (bounded by --timeout since every child is
# itself timeout-capped at --timeout), then assemble whatever landed.
# ===========================================================================

run_section() { # $1 = name, remaining args = collector-specific args
  local name="$1"; shift
  # NOTE: this subshell is forked AFTER the parent's `trap cleanup EXIT` is
  # set, so without `trap - EXIT` here it would INHERIT that trap -- and the
  # first section subshell to finish would rm -rf "$WORK" out from under its
  # still-running siblings. Reset it explicitly; only the parent script's own
  # exit should trigger cleanup.
  ( trap - EXIT; timeout "$TIMEOUT" "$SELF" "__collect_$name" "$@" >"$WORK/$name.json" 2>"$WORK/$name.err" ) &
  echo $!
}

PID_sessions=$(run_section sessions "$STATE_DIR" "$SESSION_MAX_AGE")
PID_panes=$(run_section panes)
PID_worktrees=$(run_section worktrees "${ROOTS[@]}")
PID_prs=$(run_section prs "${ROOTS[@]}")

wait "$PID_sessions" 2>/dev/null
wait "$PID_panes" 2>/dev/null
wait "$PID_worktrees" 2>/dev/null
wait "$PID_prs" 2>/dev/null

section_or_fallback() { # $1 = name
  local name="$1"
  local f="$WORK/$name.json"
  if [ -s "$f" ] && python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" >/dev/null 2>&1; then
    cat "$f"
  else
    local errtext
    errtext=$(tail -c 500 "$WORK/$name.err" 2>/dev/null | tr -d '\n')
    [ -n "$errtext" ] || errtext="collector produced no valid JSON (timed out or crashed)"
    python3 -c '
import json, sys, datetime
print(json.dumps({"ok": False, "error": sys.argv[1], "collected_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}))
' "$errtext"
  fi
}

SESSIONS_JSON=$(section_or_fallback sessions)
PANES_JSON=$(section_or_fallback panes)
WORKTREES_JSON=$(section_or_fallback worktrees)
PRS_JSON=$(section_or_fallback prs)

END_MS=$(( $(date +%s%N) / 1000000 ))
DURATION_MS=$(( END_MS - START_MS ))
GEN_EPOCH=$(date +%s)
GEN_ISO=$(now_iso)
HOST=$(hostname 2>/dev/null || echo unknown)

OUT_DIR=$(dirname "$OUT")
mkdir -p "$OUT_DIR" 2>/dev/null

DIGEST=$(python3 -c '
import json, sys
sessions, panes, worktrees, prs = (json.loads(a) for a in sys.argv[1:5])
digest = {
    "schema_version": 1,
    "generated_at": int(sys.argv[5]),
    "generated_at_iso": sys.argv[6],
    "duration_ms": int(sys.argv[7]),
    "host": sys.argv[8],
    "sessions": sessions,
    "panes": panes,
    "worktrees": worktrees,
    "prs": prs,
}
print(json.dumps(digest, indent=2))
' "$SESSIONS_JSON" "$PANES_JSON" "$WORKTREES_JSON" "$PRS_JSON" "$GEN_EPOCH" "$GEN_ISO" "$DURATION_MS" "$HOST")
RC=$?

if [ $RC -ne 0 ] || [ -z "$DIGEST" ]; then
  echo "fleet-digest.sh: failed to assemble final digest" >&2
  exit 1
fi

# Atomic write: temp file on the SAME filesystem as --out, then mv. A reader
# must never observe a half-written file.
TMPOUT="$OUT_DIR/.fleet-digest.json.tmp.$$"
if ! printf '%s\n' "$DIGEST" >"$TMPOUT"; then
  echo "fleet-digest.sh: could not write $TMPOUT" >&2
  rm -f "$TMPOUT"
  exit 1
fi
if ! mv -f "$TMPOUT" "$OUT"; then
  echo "fleet-digest.sh: could not move digest into place at $OUT" >&2
  rm -f "$TMPOUT"
  exit 1
fi

# ===========================================================================
# Companion summary: the full digest above runs ~250KB (measured: ~64k
# tokens), which defeats the point of a single artifact if the consumer is a
# PM/fleet session -- that whole file would land in its prompt prefix and get
# re-served every later turn, worse than the 20+ Bash calls it replaces. The
# summary is the few-KB slice an agent should actually read by default:
# per-section counts, the failed-source list with errors, PRs labelled mine,
# and worktrees that are dirty/ahead/behind rather than all of them. A
# summary-build/write failure is logged but never fails the run -- the full
# digest above already succeeded and remains the authoritative artifact.
# ===========================================================================
SUMMARY=$(python3 -c '
import json, sys
# Read the full digest from disk (it was just written to $OUT) rather than
# passing its content as an argv string -- a fleet with a few hundred
# worktrees/PRs produces a $DIGEST well past ARG_MAX, which made this fail
# with "Argument list too long" while pretending (via warning-only) to be a
# harmless summary-write failure.
out_path = sys.argv[1]
with open(out_path) as f:
    digest = json.load(f)
s = digest["sessions"]; p = digest["panes"]; w = digest["worktrees"]; pr = digest["prs"]

failed_sources = []
for name, sect in (("sessions", s), ("panes", p), ("worktrees", w), ("prs", pr)):
    if not sect.get("ok", False):
        failed_sources.append({"section": name, "source": name, "error": sect.get("error")})
for r in pr.get("remotes", []) or []:
    if not r.get("ok", True):
        failed_sources.append({"section": "prs", "source": r.get("remote"), "error": r.get("error")})

dirty_worktrees = [
    wt for wt in (w.get("worktrees", []) or [])
    if wt.get("dirty_count", 0) or wt.get("ahead", 0) or wt.get("behind", 0)
]

mine_prs = []
total_pr_count = 0
for r in pr.get("remotes", []) or []:
    items = r.get("prs", []) or []
    total_pr_count += len(items)
    for item in items:
        if item.get("is_mine") is True:
            e = dict(item)
            e["remote"] = r.get("remote")
            mine_prs.append(e)

summary = {
    "schema_version": digest["schema_version"],
    "generated_at": digest["generated_at"],
    "generated_at_iso": digest["generated_at_iso"],
    "duration_ms": digest["duration_ms"],
    "host": digest["host"],
    "full_digest": out_path,
    "sessions": {
        "ok": s.get("ok"), "error": s.get("error"), "collected_at": s.get("collected_at"),
        "count": len(s.get("sessions", []) or []),
        "filtered_out_count": s.get("filtered_out_count"),
        "total_ctx_files": s.get("total_ctx_files"),
    },
    "panes": {
        "ok": p.get("ok"), "error": p.get("error"), "collected_at": p.get("collected_at"),
        "count": len(p.get("panes", []) or []),
    },
    "worktrees": {
        "ok": w.get("ok"), "error": w.get("error"), "collected_at": w.get("collected_at"),
        "count": len(w.get("worktrees", []) or []),
        "dirty_or_ahead_behind_count": len(dirty_worktrees),
        "entries": dirty_worktrees,
    },
    "prs": {
        "ok": pr.get("ok"), "error": pr.get("error"), "collected_at": pr.get("collected_at"),
        "my_login": pr.get("my_login"),
        "remote_count": pr.get("remote_count"),
        "total_pr_count": total_pr_count,
        "mine_count": len(mine_prs),
        "entries": mine_prs,
    },
    "failed_sources": failed_sources,
}
print(json.dumps(summary, indent=2))
' "$OUT")
SUMMARY_RC=$?

if [ $SUMMARY_RC -ne 0 ] || [ -z "$SUMMARY" ]; then
  echo "fleet-digest.sh: WARNING: failed to assemble summary (full digest at $OUT is still valid)" >&2
else
  SUMMARY_DIR=$(dirname "$SUMMARY_OUT")
  mkdir -p "$SUMMARY_DIR" 2>/dev/null
  TMPSUM="$SUMMARY_DIR/.$(basename "$SUMMARY_OUT").tmp.$$"
  if printf '%s\n' "$SUMMARY" >"$TMPSUM" && mv -f "$TMPSUM" "$SUMMARY_OUT"; then
    :
  else
    echo "fleet-digest.sh: WARNING: failed to write summary to $SUMMARY_OUT (full digest at $OUT is still valid)" >&2
    rm -f "$TMPSUM"
  fi
fi

echo "fleet-digest.sh: wrote $OUT and $SUMMARY_OUT (${DURATION_MS}ms)"
exit 0
