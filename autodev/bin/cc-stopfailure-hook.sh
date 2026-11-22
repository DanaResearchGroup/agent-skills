#!/usr/bin/env bash
# Claude Code StopFailure hook: the second judge for the limit-resume log-only
# proof (I-571). Logging only; Claude Code ignores this hook's output and exit.
#
# A turn that ends on an API error fires StopFailure INSTEAD of Stop: read from
# the Claude Code 2.1.330 bundle, its turn loop calls the StopFailure hooks and
# returns before the Stop hooks run. A usage/session limit ends a turn this way,
# with error=rate_limit. So cc-stop-hook.sh, which launches the resume watcher,
# does not run on the limit stop itself.
#
# On error rate_limit or billing_error it appends one line to auto-resume.log:
#   STOPFAILURE <sid> <error> <UTC>
# bin/auto-resume-report.py matches these against the watcher's LOG-ONLY lines.
input=$(cat)
: "${AUTODEV_HOME:=$HOME/agents}"
[ -f "$AUTODEV_HOME/state/disable-auto-compact" ] && exit 0
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
err=$(printf '%s' "$input" | jq -r '.error // empty' 2>/dev/null)
case "$sid" in ""|*[!A-Za-z0-9._-]*|.|..) exit 0 ;; esac
case "$err" in rate_limit|billing_error) ;; *) exit 0 ;; esac
mkdir -p "$AUTODEV_HOME/logs" 2>/dev/null
printf 'STOPFAILURE %s %s %s\n' "$sid" "$err" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  >> "$AUTODEV_HOME/logs/auto-resume.log" 2>/dev/null
exit 0
