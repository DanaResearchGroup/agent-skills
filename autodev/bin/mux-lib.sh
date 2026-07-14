#!/usr/bin/env bash
# mux-lib.sh — terminal-multiplexer abstraction for the autodev watchers.
#
# Lets the auto-handoff / Phoenix watchers drive a Claude Code session whether it
# was launched inside herdr (preferred) or tmux (fallback). herdr wins when a
# session is somehow registered under both (e.g. tmux running inside a herdr pane).
#
# Sourced by:
#   registration side — cc-statusline.sh, cc-stop-hook.sh  (run in CC's env)
#   driver side       — auto-handoff-watch.sh, session-resume-watch.sh (detached)
#
# Registration writes ~/agents/state/<sid>.{herdr-pane,tmux-pane}.
# The driver calls `mux_init "<sid>"` once, which sets two globals:
#     MUX  = herdr | tmux | ""     ("" => no registered pane; caller should skip)
#     PANE = backend pane id       (herdr "w1:p1", tmux "%3")
# and then runs every pane operation through the mux_* helpers below.
#
# This file only defines constants + functions. Sourcing it runs nothing and
# changes no shell options (a library must not impose `set -eu` on its callers).

# CC "busy" markers — while any is on screen, typed input is QUEUED, not run.
# Used for tmux busy-detection and as the herdr fallback when agent_status is
# unavailable. Single source of truth (was duplicated in each watcher).
MUX_BUSY_RE='esc to interrupt|Crunching|Compacting|Waiting for [0-9]|Press up to edit queued|Running [0-9]+ (shell|command)|Running .*command…|Running .*shell'

: "${AUTODEV_HOME:=$HOME/agents}"
: "${STATE:=$AUTODEV_HOME/state}"

# --- registration side (runs in CC's env, from the hooks) --------------------
# Record this session's backend pane id(s). Cheap by design: reads env vars only,
# no subprocess to herdr/tmux, so it is safe on every statusline render. Writes
# atomically. Records both files when a session is nested in both multiplexers.
mux_register(){ # $1 = sid
  local sid="$1" f
  [ -n "$sid" ] || return 0
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    f="$STATE/$sid.herdr-pane"
    printf '%s\n' "$HERDR_PANE_ID" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    f="$STATE/$sid.tmux-pane"
    printf '%s\n' "$TMUX_PANE" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null
  fi
}

# --- driver side (runs detached in the watchers) -----------------------------
# Resolve MUX + PANE from the registered state files. herdr takes precedence.
# Returns 0 when a registration exists, 1 when none (caller should exit).
mux_init(){ # $1 = sid
  local sid="$1" v
  MUX=""; PANE=""
  if [ -s "$STATE/$sid.herdr-pane" ]; then
    v=$(cat "$STATE/$sid.herdr-pane" 2>/dev/null)
    if [ -n "$v" ]; then MUX="herdr"; PANE="$v"; return 0; fi
  fi
  if [ -s "$STATE/$sid.tmux-pane" ]; then
    v=$(cat "$STATE/$sid.tmux-pane" 2>/dev/null)
    if [ -n "$v" ]; then MUX="tmux"; PANE="$v"; return 0; fi
  fi
  return 1
}

# Is the registered pane still live? 0 = live, 1 = gone/unknown.
mux_pane_live(){
  case "$MUX" in
    tmux)  tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$PANE" ;;
    herdr) herdr pane get "$PANE" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# herdr agent state for the pane: prints idle|working|blocked|done|unknown.
# Prints nothing under tmux (no native state; callers fall back to the scrape).
mux_status(){
  case "$MUX" in
    herdr) herdr pane get "$PANE" 2>/dev/null \
             | grep -o '"agent_status":"[^"]*"' | head -1 | cut -d'"' -f4 ;;
    *) : ;;
  esac
}

# Print recent pane text (for the Phoenix usage-limit banner scrape).
mux_capture(){
  case "$MUX" in
    tmux)  tmux capture-pane -t "$PANE" -p 2>/dev/null ;;
    herdr) herdr pane read "$PANE" --source recent --lines 200 2>/dev/null ;;
    *) : ;;
  esac
}

# 0 = pane is BUSY (typed input would queue), 1 = safe to send. Under herdr use
# native agent_status; fall back to the text scrape when state is unknown.
mux_busy(){
  local st
  case "$MUX" in
    herdr)
      st=$(mux_status)
      case "$st" in
        working)           return 0 ;;                       # running a turn => busy
        idle|done|blocked) return 1 ;;                       # at a prompt => safe
        *) mux_capture | tail -15 | grep -Eq "$MUX_BUSY_RE" ;; # unknown => scrape
      esac ;;
    tmux)  tmux capture-pane -t "$PANE" -p 2>/dev/null | tail -15 | grep -Eq "$MUX_BUSY_RE" ;;
    *) return 1 ;;
  esac
}

# A stable human label to re-assert after compaction (the tmux session name).
# herdr has no tmux-style session name — prints empty, so callers skip /rename.
mux_session_name(){
  case "$MUX" in
    tmux)  tmux display-message -p -t "$PANE" '#{session_name}' 2>/dev/null ;;
    *) : ;;
  esac
}

# Send one literal line followed by Enter (the /handoff, /compact, continue text).
mux_send_line(){ # $1 = text
  case "$MUX" in
    tmux)  tmux send-keys -t "$PANE" -l "$1" && tmux send-keys -t "$PANE" Enter ;;
    herdr) herdr pane run "$PANE" "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# Send a single named key (e.g. Escape) with no literal text.
mux_send_key(){ # $1 = key
  case "$MUX" in
    tmux)  tmux send-keys -t "$PANE" "$1" ;;
    herdr) herdr pane send-keys "$PANE" "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}
