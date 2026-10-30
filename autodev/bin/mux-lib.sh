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
#     MUX_SESSION = owning session id
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
# The tails below exclude a recognized trailing status/footer block first.
# This keeps notices from hiding live dialog chrome while leaving older quoted
# dialog text above the live prompt outside the short matching windows.
#   footer (last 3 non-empty dialog lines, case-insensitive): every question view
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

# Shared by the Claude status line and the send-boundary presence check.
mux_session_tag(){ printf '⟨cc:%s⟩' "${1:0:8}"; }

# --- registration side (runs in CC's env, from the hooks) --------------------
# Reverse pane->owner mapping file for a (mux, pane-id) pair. The pane id is
# sanitized (':' and '%' -> '_') so it is a safe flat filename. This is the
# tmux-side source of truth: the last rendered session wins. For herdr, the
# reverse file is combined with the current label and ctx freshness; registration
# replaces an obsolete owner only after validating that evidence.
mux_owner_file(){ # $1 = mux, $2 = paneid
  printf '%s/.paneowner-%s-%s' "$STATE" "$1" "$(printf '%s' "$2" | tr ':%' '__')"
}

mux_register(){ # $1 = sid
  local sid="$1" f o
  [ -n "$sid" ] || return 0
  case "$sid" in *[!A-Za-z0-9._-]*|.|..) return 0 ;; esac
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    _mux_register_herdr "$sid"
  fi
  # The TAB owning this pane, for the label badges (cache-warm-watch.sh). herdr
  # exports it alongside the pane id; the tab registration remains env-only.
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

# Most statusline renders only read this stamp and the cached binding. Slow
# validation runs on a changed env/binding pair, an unreachable flag, or expiry.
# Cache BOTH ids so a permanently stale inherited env does not defeat the throttle.
_mux_register_herdr(){ # $1 sid
  local sid=$1 f="$STATE/$1.herdr-pane" stamp="$STATE/$1.herdr-register-check"
  local cached="" checked=0 checked_env="" checked_pane="" now
  if [ ! -s "$f" ]; then
    # Never replace a concurrent resolver's result during initial publication.
    printf '%s\n' "$HERDR_PANE_ID" > "$f.tmp.$$" 2>/dev/null &&
      ln "$f.tmp.$$" "$f" 2>/dev/null
    rm -f "$f.tmp.$$" 2>/dev/null
  fi
  [ -s "$f" ] && cached=$(cat "$f" 2>/dev/null)
  [ -f "$stamp" ] && read -r checked checked_env checked_pane < "$stamp"
  case "$checked" in ''|*[!0-9]*) checked=0 ;; esac
  now=$(date +%s)
  if [ -n "$cached" ] && [ ! -f "$STATE/$sid.unreachable" ] &&
     [ "$checked_env" = "$HERDR_PANE_ID" ] && [ "$checked_pane" = "$cached" ] &&
     [ "$(( now - checked ))" -ge 0 ] && [ "$(( now - checked ))" -lt 60 ]; then
    return 0
  fi

  # A background worker can carry the spawning pane's id indefinitely. Prefer
  # the resolved binding, trying the env only when that binding cannot be used.
  if ! mux_session_reachable "$sid" && [ "$PANE" != "$HERDR_PANE_ID" ]; then
    MUX=herdr; MUX_SESSION=$sid; PANE=$HERDR_PANE_ID
    if mux_pane_live && [ "$(mux_pane_owner)" = "$sid" ]; then
      printf '%s\n' "$PANE" > "$f.tmp.$$" 2>/dev/null && mv "$f.tmp.$$" "$f" 2>/dev/null
    fi
  fi
  if mux_session_reachable "$sid"; then
    if ! _mux_claim_herdr "$sid"; then
      mux_session_reachable "$sid" || true
      return 0
    fi
    # Recheck after the claim; a competing statusline can update its ctx while
    # waiting for the per-pane claim lock. Failed checks retain the visible flag.
    mux_session_reachable "$sid" || return 0
    printf '%s %s %s\n' "$now" "$HERDR_PANE_ID" "$PANE" > "$stamp.tmp.$$" 2>/dev/null &&
      mv "$stamp.tmp.$$" "$stamp" 2>/dev/null
  fi
  return 0
}

# Re-evaluate under the per-pane lock, then atomically REPLACE the reverse file.
# A dead former owner must not reserve a recycled pane forever. flock releases
# automatically on exit, so an interrupted registration leaves no stuck lock.
_mux_claim_herdr(){ # $1 sid; uses the resolved MUX/PANE
  (
    local sid=$1 o
    o=$(mux_owner_file herdr "$PANE")
    command -v flock >/dev/null 2>&1 || return 1
    exec 9>"$o.lock" || return 1
    flock -n 9 || return 1
    [ "$(mux_pane_owner)" = "$sid" ] || return 1
    printf '%s\n' "$sid" > "$o.tmp.$$" 2>/dev/null &&
      mv "$o.tmp.$$" "$o" 2>/dev/null
  )
}

# --- driver side (runs detached in the watchers) -----------------------------
# Resolve MUX + PANE (+ TAB, when the backend has one) from the registered state
# files. herdr takes precedence.
# Returns 0 when a registration exists, 1 when none (caller should exit).
mux_init(){ # $1 = sid
  local sid="$1" v
  MUX=""; PANE=""; TAB=""; MUX_SESSION="$sid"
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

_mux_ctx_fresher(){ # $1 possible live owner, $2 our session
  [ -f "$STATE/$1.ctx" ] &&
    { [ ! -f "$STATE/$2.ctx" ] || [ "$STATE/$1.ctx" -nt "$STATE/$2.ctx" ]; }
}

# Effective owner, shared by every watcher ownership gate. A stale herdr
# agent_session label alone cannot establish that a pane has been recycled.
# A reverse owner yields to our current label when its ctx is missing or not
# newer than ours. A fresher other ctx still proves live ownership and refuses.
# Unknown herdr ownership prints nothing; driving requires positive ownership.
mux_pane_owner(){
  local o registered="" hint="" ours="${MUX_SESSION:-}"
  o=$(mux_owner_file "$MUX" "$PANE")
  [ -s "$o" ] && registered=$(cat "$o" 2>/dev/null)
  if [ "$MUX" != herdr ]; then
    [ -n "$registered" ] && printf '%s\n' "$registered"
    return 0
  fi
  hint=$("$MUX_HERDR" pane get "$PANE" 2>/dev/null \
    | jq -r '(.result.pane // .result).agent_session.value // empty' 2>/dev/null)
  # Treat labels/reverse files as ids, never as paths supplied by the backend.
  case "$hint" in *[!A-Za-z0-9._-]*|.|..) hint="" ;; esac
  case "$registered" in *[!A-Za-z0-9._-]*|.|..) registered="" ;; esac
  if [ -n "$registered" ] && [ "$registered" != "$ours" ] &&
     { [ "$hint" != "$ours" ] || _mux_ctx_fresher "$registered" "$ours"; }; then
    printf '%s\n' "$registered"
  elif [ -n "$hint" ] && [ "$hint" != "$ours" ] &&
       _mux_ctx_fresher "$hint" "$ours"; then
    printf '%s\n' "$hint"
  elif [ -n "$ours" ] && { [ "$hint" = "$ours" ] ||
       { [ "$registered" = "$ours" ] && [ -f "$STATE/$ours.ctx" ]; }; }; then
    printf '%s\n' "$ours"
  fi
}

# One flag per unreachable episode. Screen refusals log once per failed guard
# (not per redraw poll), so a later watcher run leaves fresh diagnostic evidence.
# Keep the binding: a temporary refusal must not destroy retries.
mux_mark_unreachable(){ # $1 sid, $2 reason
  local sid=$1 reason=$2 created=0
  case "$sid" in ""|*[!A-Za-z0-9._-]*|.|..) return 1 ;; esac
  if (set -C; printf '%s\n' "$reason" > "$STATE/$sid.unreachable") 2>/dev/null; then
    created=1
  fi
  if [ "$created" = 1 ] || [[ "$reason" == 'screen presence unproved:'* ]]; then
    mkdir -p "$AUTODEV_HOME/logs" 2>/dev/null
    printf '%s [%s] UNREACHABLE %s\n' "$(date +'%Y.%m.%d %H.%M.%S')" "$sid" "$reason" \
      >> "$AUTODEV_HOME/logs/auto-handoff.log"
  fi
  return 1
}

# A pane id may have been renumbered. Resolve only a unique exact session label,
# then validate current ownership before publishing it. No pid/tty heuristic:
# a daemon-hosted background conversation may have no attached pane at all.
mux_resolve_herdr(){
  local found old=$PANE
  found=$("$MUX_HERDR" pane list 2>/dev/null | jq -er --arg sid "$MUX_SESSION" '
    [.result.panes[]? | select(.agent_session.value == $sid) | .pane_id]
    | select(length == 1) | .[0] | select(type == "string" and length > 0)' 2>/dev/null) || return 1
  PANE=$found
  if ! mux_pane_live || [ "$(mux_pane_owner)" != "$MUX_SESSION" ]; then
    PANE=$old
    return 1
  fi
  printf '%s\n' "$PANE" > "$STATE/$MUX_SESSION.herdr-pane.tmp.$$" &&
    mv "$STATE/$MUX_SESSION.herdr-pane.tmp.$$" "$STATE/$MUX_SESSION.herdr-pane"
}

# Positive reachability gate for herdr; tmux retains its prior unknown-owner
# behavior. Re-run at the send boundary as well as before taking cycle locks.
mux_session_reachable(){ # $1 sid
  local sid=$1 owner
  MUX_OWNER=""
  mux_init "$sid" || {
    mux_mark_unreachable "$sid" 'no pane registered'
    return 1
  }
  if ! mux_pane_live; then
    if [ "$MUX" != herdr ] || ! mux_resolve_herdr; then
      mux_mark_unreachable "$sid" "registered pane $PANE is not live; no unique session match"
      return 1
    fi
  fi
  owner=$(mux_pane_owner)
  MUX_OWNER=$owner
  if { [ -n "$owner" ] && [ "$owner" != "$sid" ]; } ||
     { [ "$MUX" = herdr ] && [ "$owner" != "$sid" ]; }; then
    mux_mark_unreachable "$sid" "pane $PANE ownership refused (owner: ${owner:-unproved})"
    return 1
  fi
  # Labels/mtimes cannot clear a screen refusal. Only a later send-boundary
  # screen check can confirm recovery; registration must not read the screen.
  if [ "$MUX" != herdr ] || [ "$(cat "$STATE/$sid.runtime" 2>/dev/null)" != claude ] ||
     ! grep -q '^screen presence unproved:' "$STATE/$sid.unreachable" 2>/dev/null; then
    rm -f "$STATE/$sid.unreachable" 2>/dev/null
  fi
  return 0
}

# Check the SAME pane immediately before a herdr keystroke. Resolving a new
# pane mid-cycle could send the tail of an old cycle into another attachment.
_mux_refuse_unowned(){
  local screen tag attempt snapshot present=0
  [ "$MUX" = herdr ] && [ -n "${MUX_SESSION:-}" ] || return 0
  if ! mux_pane_live || [ "$(mux_pane_owner)" != "$MUX_SESSION" ]; then
    MUX_REFUSAL_REASON=ownership
    mux_mark_unreachable "$MUX_SESSION" "pane $PANE lost live ownership before send"
    return 1
  fi
  if [ "$(cat "$STATE/$MUX_SESSION.runtime" 2>/dev/null)" = claude ]; then
    tag=$(mux_session_tag "$MUX_SESSION")
    # Compaction can leave the bottom region blank during a redraw. Keep this
    # bounded and at the send boundary; recheck ownership after every wait.
    for attempt in 1 2 3 4 5; do
      if [ "$attempt" -gt 1 ]; then
        sleep "${AUTODEV_POLL:-1}"
        if ! mux_pane_live || [ "$(mux_pane_owner)" != "$MUX_SESSION" ]; then
          MUX_REFUSAL_REASON=ownership
          mux_mark_unreachable "$MUX_SESSION" "pane $PANE lost live ownership before send"
          return 1
        fi
      fi
      screen=""
      # The newest rendered session must be ours. A tag left above another
      # session's short screen cannot prove presence, even inside this window.
      if mux_read_screen 200 screen &&
         { [ "$MUX_SCREEN_SOURCE" != visible ] || [ "$MUX_SCREEN_AT_BOTTOM" = 1 ]; } &&
         [ "$(printf '%s\n' "$screen" | awk 'NF' | tail -n 12 | tr -d '\n' |
              grep -oE '⟨cc:[A-Za-z0-9._-]{1,8}⟩' | tail -n 1)" = "$tag" ]; then
        present=1
        break
      fi
    done
    if [ "$present" != 1 ]; then
      MUX_REFUSAL_REASON=presence
      # Keep screen contents out of the shared log. A private temporary file
      # also replaces a pre-existing snapshot with permissive mode safely.
      snapshot=$(umask 077; mktemp "$STATE/$MUX_SESSION.unreachable-screen.XXXXXX")
      if [ -n "$snapshot" ]; then
        if printf '%s\n' "$screen" | awk 'NF' | tail -n 15 > "$snapshot" &&
           mv -f "$snapshot" "$STATE/$MUX_SESSION.unreachable-screen"; then :
        else rm -f "$snapshot"; fi
      fi
      mux_mark_unreachable "$MUX_SESSION" "screen presence unproved: pane $PANE lacks a live bottom-most $tag before send"
      return 1
    fi
    if grep -q '^screen presence unproved:' "$STATE/$MUX_SESSION.unreachable" 2>/dev/null; then
      rm -f "$STATE/$MUX_SESSION.unreachable" 2>/dev/null
    fi
    # A dialog may have opened while we waited, including on an own-prompt
    # send whose original permission to bypass that check is now stale.
    if [ "$attempt" -gt 1 ] && mux_awaiting_human; then
      MUX_REFUSAL_REASON=dialog
      return 1
    fi
  fi
  return 0
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

# Print recent unwrapped text, falling back to the possibly wrapped viewport.
# Optional $2 names a caller variable, avoiding a subshell when it also needs
# MUX_SCREEN_SOURCE and MUX_SCREEN_AT_BOTTOM for the visible-screen safeguards.
# Non-zero when neither source can be read; blank output still means fail safe.
mux_read_screen(){ # $1 = recent line limit (default 80), $2 = output variable
  local text at_bottom=0
  MUX_SCREEN_SOURCE=recent-unwrapped
  MUX_SCREEN_AT_BOTTOM=0
  case "$MUX" in
    herdr)
      if ! text=$("$MUX_HERDR" pane read "$PANE" --source recent-unwrapped --lines "${1:-80}" --format text 2>/dev/null) ||
         [ -z "$(printf '%s' "$text" | tr -d '[:space:]')" ]; then
        MUX_SCREEN_SOURCE=visible
        # Bracket the viewport read so both dialog and presence checks can
        # reject visible text when it is not confirmed at the live bottom.
        mux_herdr_visible_at_bottom && at_bottom=1
        text=$("$MUX_HERDR" pane read "$PANE" --source visible --format text 2>/dev/null) || return 1
        if [ "$at_bottom" = 1 ] && mux_herdr_visible_at_bottom; then
          MUX_SCREEN_AT_BOTTOM=1
        fi
      fi ;;
    tmux) text=$(tmux capture-pane -J -p -t "$PANE" 2>/dev/null) || return 1 ;;
    *) return 1 ;;
  esac
  if [ -n "${2:-}" ]; then printf -v "$2" '%s' "$text"; else printf '%s\n' "$text"; fi
}

# 0 = the pane text on stdin ends in a dialog waiting on the human. Pure: reads
# stdin only, so the fixtures test exactly what the watchers run.
mux_text_awaiting_human(){
  local bottom
  bottom=$(MUX_AWAIT_FOOTER_RE="$MUX_AWAIT_FOOTER_RE" \
    MUX_AWAIT_CURSOR_RE="$MUX_AWAIT_CURSOR_RE" \
    MUX_AWAIT_YESNO_RE="$MUX_AWAIT_YESNO_RE" awk '
    function terminal_footer(s, count) {
      # Never discard dialog chrome, even in a footer-looking row. ENVIRON
      # preserves regex backslashes without awk -v interpreting them again.
      if (tolower(s) ~ ENVIRON["MUX_AWAIT_FOOTER_RE"] ||
          s ~ ENVIRON["MUX_AWAIT_CURSOR_RE"] ||
          s ~ ENVIRON["MUX_AWAIT_YESNO_RE"]) return 0
      if (s ~ /^[[:space:]]*✔ Update installed · Restart to apply$/ ||
          s ~ /^[[:space:]]*Context:/ ||
          s ~ /^[[:space:]]*Background tasks:/ ||
          s ~ /^[[:space:]]*(⏵⏵[[:space:]]*)?auto mode on([[:space:]]|$)/ ||
          s ~ /^[[:space:]]*[^[:alnum:]]*AUTO-HANDOFF:.*⟨cc:[A-Za-z0-9._-]+⟩/) return 1
      count=gsub(/─/, "", s)
      gsub(/[[:space:]]/, "", s)
      return count >= 3 && length(s) == 0
    }
    { if (NF) row[++n]=$0 }
    END {
      while (n > 0 && terminal_footer(row[n])) n--
      for (i=1; i<=n; i++) print row[i]
    }' | tail -n 6)
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
mux_live_prompt_footer(){
  local screen tail
  screen=$(cat)
  tail=$(printf '%s\n' "$screen" | awk 'NF' | tail -n 8)
  [ -n "$tail" ] || return 1
  printf '%s\n' "$tail" | awk '
    function rule(s, count) {
      count=gsub(/─/, "", s)
      gsub(/[[:space:]]/, "", s)
      return count >= 3 && length(s) == 0
    }
    function mode_line(s) {
      return tolower(s) ~ /auto mode|shortcut|shift.*tab|for agents/
    }
    function right_notice(s, indent, body) {
      if (match(s, /^[[:space:]]+/) != 1) return 0
      indent=RLENGTH
      if (indent < 24) return 0
      body=substr(s, indent + 1)
      return body ~ /^✔ Update installed · Restart to apply$/ ||
             body ~ /^new task[?] \/clear to save [0-9]+([.][0-9]+)?k tokens$/
    }
    {
      row[++n]=$0
      if ($0 ~ /^[[:space:]]*❯([[:space:]]|$)/) prompt=n
    }
    END {
      mode=n
      if (right_notice(row[n])) mode=n-1
      if (mode < 1 || !mode_line(row[mode]) || !prompt || prompt < 2 || prompt + 1 >= mode) exit 1
      if (!rule(row[prompt-1]) || !rule(row[prompt+1])) exit 1
    }'
}

# Remove the verified live prompt footer by structure: the lower rule beneath
# the standalone prompt glyph and every live footer row after it. This keeps
# notice rows from pushing an open menu's own footer out of the matcher window.
mux_visible_dialog_text(){
  awk '
    function rule(s, count) {
      count=gsub(/─/, "", s)
      gsub(/[[:space:]]/, "", s)
      return count >= 3 && length(s) == 0
    }
    { if (NF) row[++n]=$0 }
    END {
      for (i=n-1; i>=2; i--) {
        if (row[i] ~ /^[[:space:]]*❯([[:space:]]|$)/ &&
            rule(row[i-1]) && i+1 <= n && rule(row[i+1])) {
          for (j=1; j<=i; j++) print row[j]
          exit 0
        }
      }
      exit 1
    }'
}

mux_herdr_visible_at_bottom(){
  local info
  info=$("$MUX_HERDR" pane get "$PANE" 2>/dev/null) || return 1
  printf '%s\n' "$info" | python3 -c '
import json
import sys

try:
    offset = json.load(sys.stdin)["result"]["pane"]["scroll"]["offset_from_bottom"]
except (json.JSONDecodeError, KeyError, TypeError):
    sys.exit(1)

sys.exit(0 if type(offset) is int and offset == 0 else 1)
' >/dev/null 2>&1
}

mux_awaiting_human(){
  local out dialog
  [ "$MUX" = herdr ] && [ "$(mux_status)" = blocked ] && return 0
  mux_read_screen 80 out || return 0
  [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ] || return 0
  if [ "$MUX" = herdr ] && [ "$MUX_SCREEN_SOURCE" = visible ]; then
    [ "$MUX_SCREEN_AT_BOTTOM" = 1 ] || return 0
    printf '%s\n' "$out" | mux_live_prompt_footer || return 0
    dialog=$(printf '%s\n' "$out" | mux_visible_dialog_text) || return 0
    printf '%s\n' "$dialog" | mux_text_awaiting_human
    return $?
  fi
  printf '%s\n' "$out" | mux_text_awaiting_human
}

# 0 = the pane is running a turn (typed input would queue). Not the same as
# busy: a pane parked at a menu is busy but not working. Under herdr use native
# agent_status; fall back to the text scrape when state is unknown or under tmux.
mux_working(){
  local st
  case "$MUX" in
    herdr)
      st=$(mux_status)
      case "$st" in
        working)           return 0 ;;
        blocked|idle|done) return 1 ;;
        *) mux_capture | tail -15 | grep -Eq "$MUX_BUSY_RE" ;; # unknown => scrape
      esac ;;
    tmux)  tmux capture-pane -t "$PANE" -p 2>/dev/null | tail -15 | grep -Eq "$MUX_BUSY_RE" ;;
    *) return 1 ;;
  esac
}

# 0 = pane is BUSY (typed input would queue, or would answer a dialog), 1 = safe
# to send. A pane awaiting the human is busy: every watcher's retry loop then
# waits it out exactly as it waits out a running turn. herdr `blocked` (parked at
# a question/permission menu) is busy too: an injected Enter would answer it.
mux_busy(){
  MUX_BUSY_REASON=dialog
  mux_awaiting_human && return 0
  [ "$MUX" = herdr ] && [ "$(mux_status)" = blocked ] && return 0
  MUX_BUSY_REASON=busy
  mux_working
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
# mux_awaiting_human holds or the tmux session has a staged-input lock. The check
# sits here, at the keystroke, rather than
# only in mux_busy, because this is the one place no caller can route around:
# a future sender that forgets mux_busy still cannot answer a question, and the
# check runs as late as possible, after any wait the caller did. Senders expose
# the guard in MUX_REFUSAL_REASON so callers can log why a retry was deferred;
# nothing escalates a refusal into a send.
MUX_REFUSED=3
_mux_refuse_staged_attempt(){
  [ "$MUX" = tmux ] || return 1
  [ "${MUX_ATTEMPT_SEND:-0}" = 1 ] && return 1
  local sid=${MUX_SESSION:-}
  [ -n "$sid" ] || sid=$(mux_pane_owner)
  [ -n "$sid" ] || return 1
  [ -f "$STATE/$sid.reload-attempt" ] || return 1
  MUX_REFUSAL_REASON=staged-input
  printf 'mux: refusing tmux input for session %s: staged-input lock is active\n' "$sid" >&2
  return 0
}
_mux_refuse_if_awaiting(){
  _mux_refuse_unowned || return 1
  mux_awaiting_human || return 0
  MUX_REFUSAL_REASON=dialog
  printf 'mux: refused: pane %s is awaiting the human (open question or prompt)\n' "$PANE" >&2
  return 1
}

# Send one literal line followed by Enter (the /handoff, /compact, continue text).
# tmux needs two commands for that operation, so re-check after staging the
# literal text and immediately before Enter. A dialog can open between the two
# commands; in that race, leave the text staged and refuse the decisive key.
mux_send_line(){ # $1 = text
  # tmux stages the literal before the final guard. Callers persisting a retry
  # must be able to distinguish a refusal before staging from one that may have
  # left text in the input line.
  MUX_LINE_STAGED=0
  MUX_REFUSAL_REASON=""
  _mux_refuse_staged_attempt && return "$MUX_REFUSED"
  _mux_refuse_if_awaiting || return "$MUX_REFUSED"
  case "$MUX" in
    tmux)  MUX_LINE_STAGED=1
           tmux send-keys -t "$PANE" -l "$1" || return 1
           _mux_refuse_if_awaiting || return "$MUX_REFUSED"
           tmux send-keys -t "$PANE" Enter ;;
    herdr) _mux_refuse_unowned || return "$MUX_REFUSED"
           "$MUX_HERDR" pane run "$PANE" "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# Type literal text into the input line WITHOUT Enter (pm-nudge --stage-only).
# Guarded too: in a select menu the typed characters are keystrokes, and a digit
# picks an option.
mux_stage_text(){ # $1 = text
  _mux_refuse_staged_attempt && return "$MUX_REFUSED"
  _mux_refuse_if_awaiting || return "$MUX_REFUSED"
  case "$MUX" in
    tmux)  tmux send-keys -t "$PANE" -l "$1" ;;
    herdr) _mux_refuse_unowned || return "$MUX_REFUSED"
           "$MUX_HERDR" pane send-text "$PANE" "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# Send a single named key (e.g. Escape) with no literal text.
#   --own-prompt  skip the guard. ONLY for a dialog the caller itself opened a
#                 moment ago with its own command in this same cycle (Codex's
#                 /compact confirmation, the dialog /usage-credits opens on a
#                 limit-stopped session), where no human question can be open.
mux_send_key(){ # [--own-prompt] $1 = key
  _mux_refuse_staged_attempt && return "$MUX_REFUSED"
  if [ "${1:-}" = --own-prompt ]; then
    _mux_refuse_unowned || return "$MUX_REFUSED"
    shift
  else _mux_refuse_if_awaiting || return "$MUX_REFUSED"; fi
  case "$MUX" in
    tmux)  tmux send-keys -t "$PANE" "$1" ;;
    herdr) _mux_refuse_unowned || return "$MUX_REFUSED"
           "$MUX_HERDR" pane send-keys "$PANE" "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}
