# shellcheck shell=bash
# threshold-lib.sh — when is a session's context full enough to hand off?
# Sourced by auto-handoff-watch.sh, auto-handoff-sweep.sh and cc-stop-hook.sh;
# this file is the only place the line lives, so the three cannot disagree.
#
# Two lines, one per session:
#   percent line  AUTODEV_PCT_LINE (35) of the window, from `pct=` in <sid>.ctx.
#                 Every session has it.
#   token line    only for a Persona seat: a session whose working folder is
#                 under $AUTODEV_PERSONA_ROOT/<name>/ (default ~/Persona), at any
#                 depth. 200,000 tokens by default, set in code so a seat needs no
#                 config; `compact_at_tokens = <n>` in <root>/<name>/PI/model.toml
#                 overrides it. A missing, unreadable or malformed value falls back
#                 to 200,000, never to "no line".
# The token line governs only when the reading has `tok=` and `win=` (written by
# cc-statusline.sh) and the window is larger than the line. Otherwise the percent
# line governs: a 200k-window seat, a `.ctx` from an older status line, a Codex
# reading. On a 1M window the 200k line is 20%, below the cold-cache branch's
# COLD_MIN (25%) in the watcher and the sweep, so a Persona seat reaches the
# token line first; that branch is left unchanged.
#
# The working folder is read from <sid>.workdir, which cc-statusline.sh writes.

AUTODEV_PCT_LINE=35
AUTODEV_PERSONA_TOKENS=200000

# autodev_token_line <workdir>: print the token line for a session working in
# <workdir>, or nothing when it is not a Persona seat.
autodev_token_line() {
  local dir=$1 root=${AUTODEV_PERSONA_ROOT:-$HOME/Persona} rel name n
  root=${root%/}
  [ -n "$dir" ] && [ -n "$root" ] || return 0
  case "$dir/" in "$root"/?*/*) ;; *) return 0 ;; esac
  rel=${dir#"$root"/}; name=${rel%%/*}
  case "$name" in .|..) return 0 ;; esac
  # Top-level TOML key only (stop at the first [table]); `200_000` is a valid
  # TOML integer. Anything else leaves n empty and takes the default.
  n=$(awk '
    /^[[:space:]]*\[/ { exit }
    /^[[:space:]]*compact_at_tokens[[:space:]]*=/ {
      v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]*(#.*)?$/, "", v)
      gsub(/_/, "", v); val = v
    }
    END { if (val ~ /^[0-9]+$/) print val }
  ' "$root/$name/PI/model.toml" 2>/dev/null)
  n=${n#"${n%%[!0]*}"}   # strip leading zeros so bash never reads it as octal
  case "$n" in ''|?????????????*) n=$AUTODEV_PERSONA_TOKENS ;; esac
  printf '%s\n' "$n"
}

# autodev_ctx_lines <state-dir> <sid>: print "<token line or -> <percent line>".
autodev_ctx_lines() {
  local wd="" tl
  [ -f "$1/$2.workdir" ] && wd=$(head -n1 "$1/$2.workdir" 2>/dev/null)
  tl=$(autodev_token_line "$wd")
  printf '%s %s\n' "${tl:--}" "$AUTODEV_PCT_LINE"
}

# autodev_ctx_over <state-dir> <sid> <gt|ge>
# Is the session's latest reading at or past its line? <gt|ge> is how the
# percent is compared (each caller keeps its own); tokens are always >= line.
# Returns 0 over, 1 below, 2 no usable reading. Sets ctx_pct, ctx_tok, ctx_win,
# ctx_rule (tokens|percent), ctx_line, and ctx_reason for log lines.
# shellcheck disable=SC2034  # the ctx_* results are read by the callers
autodev_ctx_over() {
  local state=$1 sid=$2 op=${3:-gt} line tl pl
  ctx_pct=""; ctx_tok=""; ctx_win=""; ctx_rule=""; ctx_line=""; ctx_reason=""
  [ -f "$state/$sid.ctx" ] || return 2
  line=$(head -n1 "$state/$sid.ctx" 2>/dev/null)
  ctx_pct=$(printf '%s\n' "$line" | sed -n 's/^pct=\([0-9.]*\).*/\1/p')
  [ -n "$ctx_pct" ] || return 2
  case " $line " in *" tok="[0-9]*) ctx_tok=${line#* tok=}; ctx_tok=${ctx_tok%% *} ;; esac
  case " $line " in *" win="[0-9]*) ctx_win=${line#* win=}; ctx_win=${ctx_win%% *} ;; esac
  case "$ctx_tok" in *[!0-9]*|?????????????*) ctx_tok="" ;; esac
  case "$ctx_win" in *[!0-9]*|?????????????*) ctx_win="" ;; esac
  read -r tl pl < <(autodev_ctx_lines "$state" "$sid")
  if [ "$tl" != - ] && [ -n "$ctx_tok" ] && [ -n "$ctx_win" ] && [ "$ctx_win" -gt "$tl" ]; then
    ctx_rule=tokens; ctx_line=$tl
    if [ "$ctx_tok" -ge "$tl" ]; then
      ctx_reason="tok=$ctx_tok >= $tl"; return 0
    fi
    ctx_reason="tok=$ctx_tok below $tl"; return 1
  fi
  ctx_rule=percent; ctx_line=$pl
  if [ "$op" = ge ]; then
    awk "BEGIN{exit !($ctx_pct >= $pl)}" && { ctx_reason="pct=$ctx_pct >= $pl"; return 0; }
  else
    awk "BEGIN{exit !($ctx_pct > $pl)}" && { ctx_reason="pct=$ctx_pct > $pl"; return 0; }
  fi
  ctx_reason="pct=$ctx_pct below $pl"; return 1
}
