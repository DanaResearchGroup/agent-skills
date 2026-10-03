#!/usr/bin/env bash
# Second status-line row: the session's context window as a stacked bar, one
# colour per /context category. Called by cc-statusline.sh ONLY when the
# ~/agents/state/context-bar.on flag exists (toggled by the /context-bar skill).
#
# usage: cc-context-bar.sh <state-dir> <session-id> <transcript-path>   (status-line JSON on stdin)
#
# Prints one line, or nothing on any failure -- the caller must never be broken by it.
#
# Static categories come from the NEWEST `/context` snapshot persisted in the transcript
# (a "user" line whose string content holds the "Estimated usage by category" table).
# Rows marked "(deferred)" are not in context and are skipped. Messages is live: current
# input tokens (documented .context_window.current_usage, else used_percentage x size)
# minus the static categories. The parsed snapshot is cached in <state>/<sid>.ctxbar with
# the transcript offset already scanned, so a render only reads the bytes added since.
STATE=$1 sid=$2 tpath=$3
BAR_WIDTH=${CONTEXT_BAR_WIDTH:-60}
[ -d "$STATE" ] || exit 0
input=$(cat)

read -r used win < <(printf '%s' "$input" | jq -r '
  .context_window as $c
  | ( if ($c.current_usage // null) != null
        then (($c.current_usage.input_tokens // 0) + ($c.current_usage.cache_creation_input_tokens // 0)
              + ($c.current_usage.cache_read_input_tokens // 0))
      elif ($c.used_percentage // null) != null and ($c.context_window_size // null) != null
        then (($c.used_percentage * $c.context_window_size / 100) | round)
      else "-" end ) as $u
  | "\($u) \($c.context_window_size // "-")"' 2>/dev/null)
case $used in ''|*[!0-9]*) exit 0;; esac
case $win in *[!0-9]*) win=-;; esac

# ---- /context table -> TSV: "win<TAB>n", "c<TAB>name<TAB>tokens", or "bad" ----
parse_table() {
  awk '
    function tok(s,  u, n) {
      gsub(/[ ,]/, "", s); u = tolower(substr(s, length(s))); n = substr(s, 1, length(s) - 1)
      if ((u == "k" || u == "m") && n ~ /^[0-9]+(\.[0-9]+)?$/) return int(n * (u == "k" ? 1000 : 1000000) + 0.5)
      if (s ~ /^[0-9]+$/) return s + 0
      return -1
    }
    /^\*\*Tokens:\*\*/ { s = $0; sub(/^.*\//, "", s); sub(/\(.*/, "", s); w = tok(s); if (w > 0) win = w }
    /Estimated usage by category/ { intab = 1; next }
    intab && /^\|/ {
      n = split($0, f, "|"); nm = f[2]; gsub(/^ +| +$/, "", nm)
      if (nm == "" || nm == "Category" || nm ~ /^:?-+:?$/) next
      rows++
      if (nm ~ /\(deferred\)/) next
      t = tok(f[3]); if (t < 0) { bad = 1; next }
      out = out "c\t" nm "\t" t "\n"; ok++
      next
    }
    intab && rows > 0 { intab = 0 }
    END {
      if (bad || !ok) { print "bad"; exit }
      if (win) print "win\t" win
      printf "%s", out
    }'
}

# tac is GNU-only; BSD/macOS has tail -r.
_rev() { if command -v tac >/dev/null 2>&1; then tac; else tail -r; fi; }

# ---- newest snapshot in transcript bytes [from, to) ----
find_snapshot() {
  local from=$1 to=$2 line c
  while IFS= read -r line; do
    c=$(printf '%s' "$line" | jq -r 'select(.type == "user" and (.message.content | type) == "string") | .message.content' 2>/dev/null)
    case $c in *"Estimated usage by category"*) printf '%s\n' "$c"; return 0;; esac
  done < <(tail -c +$((from + 1)) "$tpath" 2>/dev/null | head -c $((to - from)) | _rev \
             | grep -a 'Estimated usage by category' | head -n 30)
  return 1
}

cache="$STATE/${sid:-nosid}.ctxbar"
snap=""
if [ -n "$sid" ] && [ -n "$tpath" ] && [ -f "$tpath" ]; then
  size=$(wc -c < "$tpath" 2>/dev/null | tr -d ' ') || exit 0
  case $size in ''|*[!0-9]*) exit 0;; esac
  # Scan only through the last complete line at or before $size. Measured on the same
  # $size-byte prefix, so a line appended between the two reads cannot hide a partial one.
  to=$size
  # tail -c +N seeks, so this reads one byte, not the whole transcript.
  if [ "$size" -gt 0 ] && [ "$(tail -c +"$size" "$tpath" 2>/dev/null | head -c 1 | wc -l | tr -d ' ')" != 1 ]; then
    # Rare (a write in flight): measure the partial line inside a bounded window of the prefix.
    w=$((size < 1048576 ? size : 1048576))
    to=$((size - $(tail -c +$((size - w + 1)) "$tpath" 2>/dev/null | head -c "$w" | tail -n 1 | wc -c | tr -d ' ')))
  fi
  case $to in ''|*[!0-9]*) exit 0;; esac
  cached=""
  [ -f "$cache" ] && cached=$(sed -n 's/^size\t\([0-9][0-9]*\)$/\1/p' "$cache")
  if [ -n "$cached" ] && [ "$cached" -le "$to" ]; then
    if [ "$to" -gt "$cached" ]; then
      if c=$(find_snapshot "$cached" "$to"); then
        snap=$c
      else
        { printf 'size\t%s\n' "$to"; grep -v '^size	' "$cache"; } > "$cache.tmp.$$" 2>/dev/null \
          && mv "$cache.tmp.$$" "$cache" 2>/dev/null
      fi
    fi
  else
    start=$((to > 4194304 ? to - 4194304 : 0))
    if c=$(find_snapshot "$start" "$to") || { [ "$start" -gt 0 ] && c=$(find_snapshot 0 "$to"); }; then
      snap=$c
    else
      printf 'size\t%s\nnone\n' "$to" > "$cache.tmp.$$" 2>/dev/null && mv "$cache.tmp.$$" "$cache" 2>/dev/null
    fi
  fi
  if [ -n "$snap" ]; then
    parsed=$(printf '%s' "$snap" | parse_table)
    # A newer table that fails to parse must not erase good categories already cached:
    # keep them and only advance the scanned offset.
    if [ "$parsed" = bad ] && [ -f "$cache" ] && grep -q '^c	' "$cache"; then
      { printf 'size\t%s\n' "$to"; grep -v '^size	' "$cache"; } > "$cache.tmp.$$" 2>/dev/null \
        && mv "$cache.tmp.$$" "$cache" 2>/dev/null
    else
      { printf 'size\t%s\n' "$to"; printf '%s\n' "$parsed"; } > "$cache.tmp.$$" 2>/dev/null \
        && mv "$cache.tmp.$$" "$cache" 2>/dev/null
    fi
  fi
fi

nc=0; [ -n "${NO_COLOR-}" ] && nc=1
{ [ -f "$cache" ] && [ -n "$sid" ] && cat "$cache" || printf 'none\n'; } | awk -F'\t' \
  -v used="$used" -v livewin="$win" -v W="$BAR_WIDTH" -v nc="$nc" '
  function fmt(n,  s) {
    if (n >= 1000000) { s = sprintf("%.1f", n / 1000000); sub(/\.0$/, "", s); return s "m" }
    if (n >= 10000) return sprintf("%d", n / 1000 + 0.5) "k"
    if (n >= 1000) return sprintf("%.1f", n / 1000) "k"
    return n
  }
  function short(nm) {
    if (nm == "System prompt") return "sys"
    if (nm == "System tools") return "tools"
    if (nm == "MCP server instructions") return "mcp"
    if (nm == "Custom agents") return "agents"
    if (nm == "Memory files") return "mem"
    if (nm == "Skills") return "skills"
    if (nm == "Messages") return "msgs"
    if (nm == "used") return "used"
    split(tolower(nm), p, " "); return p[1]
  }
  function color(nm) {
    if (nm == "System prompt") return 245
    if (nm == "System tools") return 67
    if (nm == "MCP server instructions") return 133
    if (nm == "Custom agents") return 172
    if (nm == "Memory files") return 71
    if (nm == "Skills") return 178
    if (nm == "Messages") return 105
    if (nm == "used") return 105
    return other[(nu++) % 4 + 1]
  }
  function letter(nm,  s) {
    s = short(nm)
    if (s == "msgs" || s == "used") return "M"
    if (s == "mem") return "m"
    if (s == "skills") return "S"
    if (s == "tools") return "T"
    if (s == "sys") return "P"
    if (s == "mcp") return "I"
    if (s == "agents") return "A"
    return "O"
  }
  function rep(ch, n,  r) { r = ""; while (n-- > 0) r = r ch; return r }
  BEGIN { ESC = sprintf("%c", 27); other[1] = 30; other[2] = 96; other[3] = 131; other[4] = 101 }
  $1 == "win"  { swin = $2 }
  $1 == "bad"  { bad = 1 }
  $1 == "none" { none = 1 }
  $1 == "c"    { n++; nm[n] = $2; tk[n] = $3 + 0 }
  END {
    if (bad) exit 1
    win = livewin + 0; if (win <= 0) win = swin + 0; if (win <= 0) exit 1
    m = 0; buf = 0; stat = 0; midx = 0
    if (none || n == 0) {
      m = 1; sn[1] = "used"; st[1] = used
    } else {
      for (i = 1; i <= n; i++) {
        if (nm[i] == "Free space") continue
        if (nm[i] == "Autocompact buffer") { buf = tk[i]; continue }
        m++; sn[m] = nm[i]; st[m] = tk[i]
        if (nm[i] == "Messages") midx = m; else stat += tk[i]
      }
      if (!midx) { m++; sn[m] = "Messages"; st[m] = 0; midx = m }
      msgs = used - stat; if (msgs < 0) msgs = 0
      st[midx] = msgs
    }
    total = 0; for (i = 1; i <= m; i++) total += st[i]
    bc = int(buf * W / win + 0.5); usable = W - bc; if (usable < 0) usable = 0
    row = ""; cum = 0; prev = 0
    for (i = 1; i <= m; i++) {
      cum += st[i]; b = int(cum * W / win + 0.5); if (b > usable) b = usable
      cells = b - prev; prev = b; col[i] = color(sn[i])
      if (cells > 0) row = row (nc ? rep(letter(sn[i]), cells) : ESC "[48;5;" col[i] "m" rep(" ", cells) ESC "[0m")
    }
    fc = usable - prev
    if (fc > 0) row = row (nc ? rep(".", fc) : ESC "[48;5;237m" rep(" ", fc) ESC "[0m")
    if (bc > 0) row = row (nc ? rep("#", bc) : ESC "[38;5;245;48;5;235m" rep("╱", bc) ESC "[0m")
    # legend: largest four non-empty categories
    for (i = 1; i <= m; i++) ord[i] = i
    for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++) if (st[ord[j]] > st[ord[i]]) { t = ord[i]; ord[i] = ord[j]; ord[j] = t }
    leg = ""; shown = 0; nz = 0
    for (i = 1; i <= m; i++) if (st[ord[i]] > 0) {
      nz++
      if (shown < 4) {
        k = ord[i]
        sw = nc ? letter(sn[k]) : ESC "[38;5;" col[k] "m■" ESC "[0m"
        leg = leg (shown ? " · " : "") sw " " short(sn[k]) " " fmt(st[k]); shown++
      }
    }
    if (nz > shown) leg = leg " …"
    leg = leg "  " fmt(total) "/" fmt(win)
    if (none || n == 0) leg = leg " · run /context for categories"
    print row " " leg
  }' 2>/dev/null
exit 0
