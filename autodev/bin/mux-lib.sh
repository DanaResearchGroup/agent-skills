#!/usr/bin/env bash
# mux-lib.sh — terminal-multiplexer abstraction for the autodev watchers.
#
# Lets the auto-handoff / Phoenix watchers drive a Claude Code session whether it
# was launched inside herdr (preferred) or tmux (fallback). herdr wins when a
# session is somehow registered under both (e.g. tmux running inside a herdr pane).
#
# Sourced by:
#   registration side — cc-statusline.sh, cc-stop-hook.sh  (run in CC's env)
#   driver side       — auto-handoff-watch.sh, session-resume-watch.sh (detached),
#                       pm-nudge-sweep.sh (sets MUX/PANE itself, no mux_init)
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

# "Awaiting the human" markers — an open AskUserQuestion menu, a permission
# prompt, or any other dialog. Typed text plus Enter into one of these does not
# queue: it ANSWERS it, with whatever option is pre-highlighted (usually the one
# the agent marked "(Recommended)"), and the agent receives that as the owner's
# decision. So these are matched on the dialog's own chrome, never on question
# wording, and only at the very bottom of the pane, where Claude Code draws the
# live dialog — the same strings further up are transcript, not a dialog.
#
#   footer (last 3 non-empty lines, case-insensitive): every question view
#     (single-select, multi-select, multi-question tabs, preview) ends in
#     "Enter to select · … to navigate · Esc to cancel"; permission prompts end
#     in "Esc to cancel · Tab to amend"; MCP forms in "Enter to confirm".
#   cursor (last 4 non-empty lines): a numbered row under the "❯" selector. The
#     "Review your answers" screen draws no footer at all, only
#     "❯ 1. Submit answers / 2. Cancel", so the footer alone misses it.
#   yes/no (last 6 non-empty lines): numbered Yes/No rows of a permission prompt
#     from builds that draw neither footer nor cursor on them.
# Fixtures: autodev/test/fixtures/panes/.
MUX_AWAIT_FOOTER_RE='esc to cancel|enter to select|enter to confirm|tab to amend|press enter to continue|\(y/n\)|\[y/n\]'
MUX_AWAIT_CURSOR_RE='^[[:space:]]*❯[[:space:]]*[0-9]+\.'
MUX_AWAIT_YESNO_RE='^[[:space:]]*(❯[[:space:]]*)?[0-9]+\.[[:space:]]+(Yes|No)([^[:alnum:]]|$)'

# The herdr executable. A seam for the tests and for pm-nudge-sweep.sh, which
# carries its own override (PM_NUDGE_HERDR).
: "${MUX_HERDR:=herdr}"

: "${AUTODEV_HOME:=$HOME/agents}"
: "${STATE:=$AUTODEV_HOME/state}"

# --- registration side (runs in CC's env, from the hooks) --------------------
# Record this session's backend pane id(s). Cheap by design: reads env vars only,
# no subprocess to herdr/tmux, so it is safe on every statusline render. Writes
# atomically. Records both files when a session is nested in both multiplexers.
# Reverse pane->owner mapping file for a (mux, pane-id) pair. The pane id is
# sanitized (':' and '%' -> '_') so it is a safe flat filename. This is the
# tmux-side (and herdr fallback) source of truth for "who currently owns this
# pane" — the last session to render a statusline in the pane wins, and a dead
# session never renders again, so it never reclaims a recycled pane id.
mux_owner_file(){ # $1 = mux, $2 = paneid
  printf '%s/.paneowner-%s-%s' "$STATE" "$1" "$(printf '%s' "$2" | tr ':%' '__')"
}

mux_register(){ # $1 = sid
  local sid="$1" f o
  [ -n "$sid" ] || return 0
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    f="$STATE/$sid.herdr-pane"
    printf '%s\n' "$HERDR_PANE_ID" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null
    o=$(mux_owner_file herdr "$HERDR_PANE_ID")
    printf '%s\n' "$sid" > "$o.tmp" 2>/dev/null && mv "$o.tmp" "$o" 2>/dev/null
  fi
  # The TAB owning this pane, for the label badges (cache-warm-watch.sh). herdr
  # exports it alongside the pane id, so this stays env-only and subprocess-free.
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_TAB_ID:-}" ]; then
    f="$STATE/$sid.herdr-tab"
    printf '%s\n' "$HERDR_TAB_ID" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    f="$STATE/$sid.tmux-pane"
    printf '%s\n' "$TMUX_PANE" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null
    o=$(mux_owner_file tmux "$TMUX_PANE")
    printf '%s\n' "$sid" > "$o.tmp" 2>/dev/null && mv "$o.tmp" "$o" 2>/dev/null
  fi
}

# --- driver side (runs detached in the watchers) -----------------------------
# Resolve MUX + PANE (+ TAB, when the backend has one) from the registered state
# files. herdr takes precedence.
# Returns 0 when a registration exists, 1 when none (caller should exit).
mux_init(){ # $1 = sid
  local sid="$1" v
  MUX=""; PANE=""; TAB=""
  [ -s "$STATE/$sid.herdr-tab" ] && TAB=$(cat "$STATE/$sid.herdr-tab" 2>/dev/null)
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
    herdr) "$MUX_HERDR" pane get "$PANE" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# Session uuid the pane is CURRENTLY bound to (0 args; uses MUX/PANE from
# mux_init). herdr recycles short pane ids (w1:pY, w1:pC...) when tabs/sessions
# close, so a live pane may now host a DIFFERENT session than the one that first
# registered it — mux_pane_live only proves the pane exists, not that it is still
# ours. This resolves the true current owner so callers can refuse to drive a
# recycled pane. herdr: authoritative live query (falls back to the reverse-owner
# file). tmux: the reverse-owner file. Prints the sid, or nothing if unknown.
mux_pane_owner(){
  local o v
  if [ "$MUX" = "herdr" ]; then
    v=$("$MUX_HERDR" pane get "$PANE" 2>/dev/null \
          | grep -o '"agent_session":{[^}]*}' \
          | grep -o '"value":"[^"]*"' | head -1 | cut -d'"' -f4)
    if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
  fi
  o=$(mux_owner_file "$MUX" "$PANE")
  [ -s "$o" ] && cat "$o" 2>/dev/null
}

# herdr agent state for the pane: prints idle|working|blocked|done|unknown.
# Prints nothing under tmux (no native state; callers fall back to the scrape).
mux_status(){
  case "$MUX" in
    herdr) "$MUX_HERDR" pane get "$PANE" 2>/dev/null \
             | grep -o '"agent_status":"[^"]*"' | head -1 | cut -d'"' -f4 ;;
    *) : ;;
  esac
}

# Print recent pane text (for the Phoenix usage-limit banner scrape).
mux_capture(){
  case "$MUX" in
    tmux)  tmux capture-pane -t "$PANE" -p 2>/dev/null ;;
    herdr) "$MUX_HERDR" pane read "$PANE" --source recent --lines 200 2>/dev/null ;;
    *) : ;;
  esac
}

# Print the pane's recent text with soft-wrapped lines joined, so a footer never
# splits across rows. Non-zero when the pane cannot be read.
mux_read_screen(){
  case "$MUX" in
    herdr) "$MUX_HERDR" pane read "$PANE" --source recent-unwrapped --lines 80 2>/dev/null ;;
    tmux)  tmux capture-pane -J -p -t "$PANE" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

# 0 = the pane text on stdin ends in a dialog waiting on the human. Pure: reads
# stdin only, so the fixtures test exactly what the watchers run.
mux_text_awaiting_human(){
  local bottom
  bottom=$(awk 'NF' | tail -n 6)
  printf '%s\n' "$bottom" | tail -n 3 | grep -Eiq "$MUX_AWAIT_FOOTER_RE" && return 0
  printf '%s\n' "$bottom" | tail -n 4 | grep -Eq "$MUX_AWAIT_CURSOR_RE" && return 0
  printf '%s\n' "$bottom" | grep -Eq "$MUX_AWAIT_YESNO_RE"
}

# 0 = the pane is waiting on the HUMAN (open question menu, permission prompt,
# any dialog), so nothing may be typed into it. Fails SAFE: an unreadable or
# blank pane counts as awaiting. Elsewhere this library fails open as a cost
# control; here failing open forges an owner decision, so it must not.
# herdr's own detector reports these dialogs as `blocked` (its claude manifest,
# rule live_blocked_form), which is trusted as a positive but never as a
# negative — `idle` is still checked against the screen.
mux_awaiting_human(){
  local out
  [ "$MUX" = herdr ] && [ "$(mux_status)" = blocked ] && return 0
  out=$(mux_read_screen) || return 0
  [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ] || return 0
  printf '%s\n' "$out" | mux_text_awaiting_human
}

# 0 = pane is BUSY (typed input would queue, or would answer a dialog), 1 = safe
# to send. A pane awaiting the human is busy: every watcher's retry loop then
# waits it out exactly as it waits out a running turn. Under herdr use native
# agent_status; fall back to the text scrape when state is unknown.
mux_busy(){
  local st
  mux_awaiting_human && return 0
  case "$MUX" in
    herdr)
      st=$(mux_status)
      case "$st" in
        working|blocked)   return 0 ;;                       # running a turn, or parked at a
                                                             # question/permission menu => busy:
                                                             # an injected Enter would answer it
        idle|done)         return 1 ;;                       # at the input prompt => safe
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

# --- tab label (the one surface that repaints while Claude Code is idle) -----
# Claude Code renders its status line only on conversation updates, so nothing
# time-varying can live there. The multiplexer's own tab bar can: herdr repaints
# it independently of the agent. These two are what cache-warm-watch.sh drives.
#
# tmux is a deliberate no-op here, following mux_session_name's precedent of
# printing nothing for the backend it cannot serve: tmux window names are shared
# by every pane in the window, so a per-session badge would fight its neighbours.

# Print the tab's current label; non-zero (and nothing) if the tab is gone.
mux_tab_label(){
  [ -n "${TAB:-}" ] || return 1
  case "$MUX" in
    herdr) "$MUX_HERDR" tab get "$TAB" 2>/dev/null \
             | grep -o '"label":"[^"]*"' | head -1 | cut -d'"' -f4 ;;
    *) return 1 ;;
  esac
}

# Set the tab's label. Non-zero if the backend has no tab or the call failed.
mux_tab_rename(){ # $1 = label
  [ -n "${TAB:-}" ] || return 1
  case "$MUX" in
    herdr) "$MUX_HERDR" tab rename "$TAB" "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# --- sending: every keystroke into a pane goes through here -----------------
# Each sender below refuses, returning MUX_REFUSED (3) and typing nothing, while
# mux_awaiting_human holds. The check sits here, at the keystroke, rather than
# only in mux_busy, because this is the one place no caller can route around:
# a future sender that forgets mux_busy still cannot answer a question, and the
# check runs as late as possible, after any wait the caller did. Callers log the
# refusal as `DEFER awaiting-human` and retry later exactly as for a busy pane;
# nothing escalates a refusal into a send.
MUX_REFUSED=3
_mux_refuse_if_awaiting(){
  mux_awaiting_human || return 0
  printf 'mux: refused: pane %s is awaiting the human (open question or prompt)\n' "$PANE" >&2
  return 1
}

# Send one literal line followed by Enter (the /handoff, /compact, continue text).
# tmux needs two commands for that operation, so re-check after staging the
# literal text and immediately before Enter. A dialog can open between the two
# commands; in that race, leave the text staged and refuse the decisive key.
mux_send_line(){ # $1 = text
  _mux_refuse_if_awaiting || return "$MUX_REFUSED"
  case "$MUX" in
    tmux)  tmux send-keys -t "$PANE" -l "$1" || return 1
           _mux_refuse_if_awaiting || return "$MUX_REFUSED"
           tmux send-keys -t "$PANE" Enter ;;
    herdr) "$MUX_HERDR" pane run "$PANE" "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# Type literal text into the input line WITHOUT Enter (pm-nudge --stage-only).
# Guarded too: in a select menu the typed characters are keystrokes, and a digit
# picks an option.
mux_stage_text(){ # $1 = text
  _mux_refuse_if_awaiting || return "$MUX_REFUSED"
  case "$MUX" in
    tmux)  tmux send-keys -t "$PANE" -l "$1" ;;
    herdr) "$MUX_HERDR" pane send-text "$PANE" "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# Send a single named key (e.g. Escape) with no literal text.
#   --own-prompt  skip the guard. ONLY for a dialog the caller itself opened a
#                 moment ago with its own command in this same cycle (Codex's
#                 /compact confirmation, the dialog /usage-credits opens on a
#                 limit-stopped session), where no human question can be open.
mux_send_key(){ # [--own-prompt] $1 = key
  if [ "${1:-}" = --own-prompt ]; then shift
  else _mux_refuse_if_awaiting || return "$MUX_REFUSED"; fi
  case "$MUX" in
    tmux)  tmux send-keys -t "$PANE" "$1" ;;
    herdr) "$MUX_HERDR" pane send-keys "$PANE" "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}
