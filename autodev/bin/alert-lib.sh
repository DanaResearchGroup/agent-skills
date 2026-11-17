#!/usr/bin/env bash
# alert-lib.sh — the covered-pane Slack line, shared by auto-handoff-sweep.sh
# (its stuck-seat alert) and cc-handoff-gate.sh (the bound on a request held
# under a covered screen). Both send the SAME line and record it in the same
# <sid>.covered-alert, keyed by the episode (<sid>.covered's <since>), so one
# episode gets one Slack line whichever of them sends first.
#
# <sid>.covered-alert: "episode=<since>", "slack=<state>", "lane=<state>", one
# per line; a state is "sent <epoch>[ <id>]", "unposted <epoch> no-channel" or
# "failed <epoch> <why>" (retried).
#
# Callers set STATE and AUTODEV_HOME, and $now (epoch) for the line's minutes;
# alert_seat_label needs mux_init, and alert_covered_text autodev_ctx_over
# (threshold-lib.sh). Sourcing runs nothing.

# alert_log <sid> <message>: one line in the handoff log, the sweep's format.
alert_log(){
  mkdir -p "$AUTODEV_HOME/logs" 2>/dev/null
  printf '%s [%s] %s\n' "$(date +'%Y.%m.%d %H.%M.%S')" "$1" "$2" >> "$AUTODEV_HOME/logs/auto-handoff.log"
}

# alert_record_read <sid>: sets al_episode, al_slack, al_lane from <sid>.covered-alert.
alert_record_read(){
  local key val
  al_episode=""; al_slack=""; al_lane=""
  [ -f "$STATE/$1.covered-alert" ] || return 0
  while IFS='=' read -r key val; do
    case "$key" in
      episode) al_episode=$val ;;
      slack) al_slack=$val ;;
      lane) al_lane=$val ;;
    esac
  done < "$STATE/$1.covered-alert"
}
alert_record_write(){ # $1 sid; writes al_episode, al_slack, al_lane
  local rec="$STATE/$1.covered-alert" tmp="$STATE/$1.covered-alert.tmp.$$"
  { printf 'episode=%s\nslack=%s\nlane=%s\n' "$al_episode" "$al_slack" "$al_lane" > "$tmp" &&
    mv -f "$tmp" "$rec"; } 2>/dev/null && return 0
  rm -f "$tmp" 2>/dev/null
  alert_log "$1" "ALERT-SKIP cannot record $rec — no send until it can be recorded (an unrecorded send would repeat every tick)"
  return 1
}
alert_sent(){ case "$1" in 'sent '*|'unposted '*) return 0 ;; esac; return 1; }   # unposted: settled, logged by the poster

# The seat's name: its herdr tab label (without the cache badge), never a pane id.
alert_seat_label(){ # $1 sid; needs mux_init
  local l=""
  command -v mux_tab_label >/dev/null 2>&1 && l=$(mux_tab_label 2>/dev/null | head -n1)
  # The lane refuses control and format characters (an emoji's zero-width
  # joiner is one), and a byte cut could split a character: work in characters.
  l=$(printf '%s' "$l" | sed -E 's/ (⌛[0-9]+s|•cold)$//' | python3 -c '
import sys, unicodedata
s = sys.stdin.buffer.read().decode("utf-8", "replace")
s = "".join(c for c in s if unicodedata.category(c)[0] != "C" and unicodedata.category(c) not in ("Zl", "Zp"))
print(s.strip()[:80], end="")' 2>/dev/null) || l=""
  if [ -n "$l" ]; then printf "'%s'" "$l"; else printf 'an unlabelled seat (session %s)' "${1:0:8}"; fi
}

# One line of a command's output for the state file and the log: printable, short.
alert_why(){ # $1 output, $2 exit code
  local w
  w=$(printf '%s\n' "$1" | awk 'NF' | head -n1 | tr -d '\000-\037\177' | cut -c1-120)
  printf '%s' "${w:-exit $2}"
}

alert_send_slack(){ # $1 text; sets alert_out, returns the helper's exit code
  # The poster finds the channel itself (its env, else Claude Code's settings
  # file), so a timer that lacks Claude Code's env still reaches Slack.
  local cmd=${AUTODEV_SLACK_CMD:-$HOME/.claude/bin/cc-slack-post.py} rc
  local -a runner=(); command -v timeout >/dev/null 2>&1 && runner=(timeout "${AUTODEV_ALERT_TIMEOUT:-30}")
  alert_out=$(CC_SLACK_CALLER=autodev-sweep "${runner[@]}" "$cmd" "$1" 2>&1 </dev/null); rc=$?
  return "$rc"
}

# alert_no_channel_notice <sid>: the poster's once-a-day "slack: no channel"
# line for this caller, into the handoff log and onto stderr.
alert_no_channel_notice(){
  local cmd=${AUTODEV_SLACK_CMD:-$HOME/.claude/bin/cc-slack-post.py} line
  # The same limit as the sends: a stalled notice must not hold back the lane line.
  local -a runner=(); command -v timeout >/dev/null 2>&1 && runner=(timeout "${AUTODEV_ALERT_TIMEOUT:-30}")
  line=$("${runner[@]}" "$cmd" --no-channel-notice autodev-sweep 2>/dev/null </dev/null | head -n1) || true
  [ -n "$line" ] || return 0
  alert_log "$1" "$line"
  printf '%s\n' "$line" >&2
}

# shellcheck disable=SC2034,SC2154  # sets alert_text for the caller; $now is the caller's
# alert_covered_text <sid> <kind> <since>: sets alert_text (the line without
# the host prefix) and alert_label. kind: menu | login | other (a covered
# screen) or owner | nopane (a pane not ours, or gone). Needs mux_init.
alert_covered_text(){
  local sid=$1 kind=$2 since=$3 ctxtxt why_line kindtxt mins
  alert_label=$(alert_seat_label "$sid")
  # shellcheck disable=SC2154  # set by autodev_ctx_over (threshold-lib.sh)
  if command -v autodev_ctx_over >/dev/null 2>&1 && autodev_ctx_over "$STATE" "$sid" gt; then
    ctxtxt="context ${ctx_pct}%${ctx_tok:+, $ctx_tok tokens}"; why_line="is past its handoff line"
  else
    ctxtxt="context ${ctx_pct:-?}%"; why_line="has a handoff request pending"
  fi
  mins=$(( (now - since) / 60 ))
  case "$kind" in
    owner|nopane)
      if [ "$kind" = owner ]; then kindtxt="pane not owned"; else kindtxt="no pane"; fi
      alert_text="seat $alert_label $why_line ($ctxtxt) and automation has not reached its pane for $mins min (reason: $kindtxt). The handoff stays queued; a person must find the session and type /compact in it." ;;
    *)
      case "$kind" in login) kindtxt="login screen" ;; *) kindtxt=$kind ;; esac
      alert_text="seat $alert_label $why_line ($ctxtxt) and its pane has been covered for $mins min (reason: $kindtxt). The handoff stays queued; a person must clear the screen or type /compact in that pane." ;;
  esac
}

# alert_slack_once <sid> <text>: send the Slack line unless this episode's
# record (al_* from alert_record_read, al_episode set by the caller) already
# holds one, then record the outcome. 1 when the record cannot be kept. The
# caller holds <sid>.page.lock.
alert_slack_once(){
  local sid=$1 text=$2 host rc why
  alert_sent "$al_slack" && return 0
  host=$(hostname 2>/dev/null || echo unknown-host)
  alert_send_slack "⚠️ *$host* — \`autodev\` $text"; rc=$?
  if [ "$rc" = 0 ]; then
    al_slack="sent $now"; alert_log "$sid" "ALERT slack sent: $text"
  elif [ "$rc" = 78 ]; then
    # No channel: the poster logged the line as unposted. Settle it for this
    # episode, so the unposted count is one per episode, not one per tick.
    al_slack="unposted $now no-channel"; alert_log "$sid" "ALERT slack not posted: no channel (in the unposted log)"
    alert_no_channel_notice "$sid"
  else
    why=$(alert_why "$alert_out" "$rc")
    al_slack="failed $now $why"; alert_log "$sid" "ALERT slack failed: $why — retry next tick"
  fi
  alert_record_write "$sid"
}
