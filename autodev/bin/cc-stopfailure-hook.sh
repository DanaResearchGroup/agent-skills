#!/usr/bin/env bash
# Claude Code StopFailure hook: the second judge for the limit-resume log-only
# proof (I-571), and the launcher of the resume watcher on a limit stop (I-575).
# Claude Code ignores this hook's output and exit.
#
# A turn that ends on an API error fires StopFailure INSTEAD of Stop: read from
# the Claude Code 2.1.330 bundle, its turn loop calls the StopFailure hooks and
# returns before the Stop hooks run. A usage/session limit ends a turn this way,
# with error=rate_limit. So cc-stop-hook.sh, which launches the resume watcher,
# does not run on the limit stop itself: this hook launches it instead.
#
# On error rate_limit or billing_error it appends one line to auto-resume.log:
#   STOPFAILURE <sid> <error> <UTC>
# then launches session-resume-watch.sh for the session, detached, exactly as
# the Stop hook does, and logs one more line:
#   STOPFAILURE-LAUNCH <sid> <UTC>                    a watcher was started
#   STOPFAILURE-NOLAUNCH <sid> watcher-running <UTC>  one already runs for <sid>
# bin/auto-resume-report.py matches these against the watcher's LOG-ONLY lines.
#
# Switches, the watcher's precedence: disable-auto-compact => nothing at all, no
# STOPFAILURE line either. auto-resume.log-only => launch; the watcher then only
# detects and logs. Else disable-auto-resume => the STOPFAILURE line, no launch.
#
# One watcher per session: the watcher inherits fd 9, which holds a flock on
# <sid>.resume-watch.lock, so the lock lives exactly as long as the watcher it
# started. A watcher the Stop hook started holds no such lock, so under the lock
# a running one is also looked for by its command line.
input=$(cat)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${AUTODEV_HOME:=$HOME/agents}"; export AUTODEV_HOME
STATE="$AUTODEV_HOME/state"
LOG="$AUTODEV_HOME/logs/auto-resume.log"
[ -f "$STATE/disable-auto-compact" ] && exit 0
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
err=$(printf '%s' "$input" | jq -r '.error // empty' 2>/dev/null)
case "$sid" in ""|*[!A-Za-z0-9._-]*|.|..) exit 0 ;; esac
case "$err" in rate_limit|billing_error) ;; *) exit 0 ;; esac
mkdir -p "$AUTODEV_HOME/logs" "$STATE" 2>/dev/null
utc(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
printf 'STOPFAILURE %s %s %s\n' "$sid" "$err" "$(utc)" >> "$LOG" 2>/dev/null

# Test seam shared with the Stop hooks; production launches normally.
[ "${AUTODEV_NO_WATCHERS:-0}" = 1 ] && exit 0

# Every check below runs under the lock, so two StopFailures for one session
# cannot both find no watcher and both start one.
if command -v flock >/dev/null 2>&1; then
  exec 9>>"$STATE/$sid.resume-watch.lock" || exit 0
  flock -n 9 || { printf 'STOPFAILURE-NOLAUNCH %s watcher-running %s\n' "$sid" "$(utc)" >> "$LOG"; exit 0; }
fi
[ -f "$STATE/disable-auto-compact" ] && exit 0
[ -f "$STATE/disable-auto-resume" ] && [ ! -f "$STATE/auto-resume.log-only" ] && exit 0
if pgrep -f "session-resume-watch\\.sh ${sid//./\\.}\$" >/dev/null 2>&1; then
  printf 'STOPFAILURE-NOLAUNCH %s watcher-running %s\n' "$sid" "$(utc)" >> "$LOG"
  exit 0
fi
# Logged first, so the watcher's own lines follow its launch line in the log.
printf 'STOPFAILURE-LAUNCH %s %s\n' "$sid" "$(utc)" >> "$LOG" 2>/dev/null
setsid "$HERE/session-resume-watch.sh" "$sid" </dev/null >/dev/null 2>&1 &
exit 0
