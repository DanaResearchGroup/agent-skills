#!/usr/bin/env bash
# Claude Code PreToolUse hook: once this session has filed a compact-request or
# handoff-request, stop it starting new work so its turn can end.
#
# Why: the watcher only sends /compact into an IDLE pane (keys sent into a busy
# agent queue instead of running). A session that keeps working after filing its
# request never goes idle — a /goal manager ran one 6 h turn, filed four
# requests, and every one expired unserved. This gate denies every tool call
# except the ones that finish the handoff. The model ends its turn, the Stop
# hook fires the watcher, the watcher compacts.
#
# Escalation: a plain deny only ASKS the model to stop, and /goal re-prompts it.
# The first two denials of one request return deny + reason; from the third on
# the hook returns {"continue":false,...}, which stops Claude outright.
#
# Allow-list (minimal): writes under handoffs/, request-handoff.sh, reading this
# session's own state files / the handoffs dir, and the exact read-only and
# pointer-writing shapes the handoff skill runs after filing.
#
# Liveness aid, not a security boundary: ANY error fails OPEN (exit 0, no
# output). The gate is also a no-op when the request is already satisfied (a
# compaction is newer than it), when no pane is registered (the watcher can never
# act, so denying would deadlock the session), or when bypassed:
#   AUTODEV_NO_HANDOFF_GATE=1        this process tree
#   $STATE/<sid>.no-handoff-gate     this session
#   $STATE/disable-handoff-gate      every session
# Claude Code only; Codex hooks have a different contract and are out of scope.

input=$(cat) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
# The allow-list resolves real paths; without realpath it cannot be evaluated, and
# denying every file tool for the life of a pending request would be the failure.
command -v realpath >/dev/null 2>&1 || exit 0
: "${AUTODEV_HOME:=$HOME/agents}"
STATE="$AUTODEV_HOME/state"
HANDOFFS="$AUTODEV_HOME/handoffs"

sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
case "$sid" in ""|*[!A-Za-z0-9._-]*) exit 0 ;; esac

[ -n "${AUTODEV_NO_HANDOFF_GATE:-}" ] && exit 0
[ -f "$STATE/disable-handoff-gate" ] && exit 0
[ -f "$STATE/$sid.no-handoff-gate" ] && exit 0

# Newest still-unsatisfied request for THIS session. Compared with -nt (sub-second
# where the filesystem has it): a compaction strictly newer than the request
# satisfies it; an exact tie is kept, since a lost request parks the session while
# a kept one costs at most one extra /compact. The key is the request's mtime in
# ns, so two requests filed within one second are still told apart.
req_key=0
for k in compact-request handoff-request; do
  f="$STATE/$sid.$k"
  [ -f "$f" ] || continue
  [ -f "$STATE/$sid.compacted" ] && [ "$STATE/$sid.compacted" -nt "$f" ] && continue
  m=$(date -r "$f" +%s%N 2>/dev/null) || exit 0
  [ "$m" -gt "$req_key" ] && req_key=$m
done
[ "$req_key" -gt 0 ] || exit 0

# The watcher can only act on a session with a registered pane.
[ -e "$STATE/$sid.herdr-pane" ] || [ -e "$STATE/$sid.tmux-pane" ] || exit 0

# The watcher is driving this session's cycle right now (it holds the cycle lock
# with a live pid): /handoff must be free to run its own steps, and a request
# marker may legitimately still exist (a compact-request filed mid-cycle).
lpid=$(cat "$STATE/$sid.cycle.lock/pid" 2>/dev/null)
[ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null && exit 0

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ -n "$tool" ] || exit 0

# --- path helpers ------------------------------------------------------------
# Two kinds of caller. Bash commands are expanded by the shell AFTER this hook
# approves them, so $HOME / ~ spellings are legitimate there (matched textually,
# then checked against the real filesystem). File tools (Write, Read, ...) never
# expand anything: they take an absolute path, and only that is accepted.
# Either way the REAL path must stay inside the directory — a symlink in
# handoffs/ pointing out must not carry a write with it.
rest=""
strip_dir() { # $1 = word, $2 = handoffs|state ; sets $rest
  local w=$1 p
  local -a pre
  if [ "$2" = handoffs ]; then
    pre=("$HANDOFFS" '$HOME/agents/handoffs' '${HOME}/agents/handoffs' '~/agents/handoffs' '$AUTODEV_HOME/handoffs' '${AUTODEV_HOME}/handoffs')
  else
    pre=("$STATE" '$HOME/agents/state' '${HOME}/agents/state' '~/agents/state' '$AUTODEV_HOME/state' '${AUTODEV_HOME}/state')
  fi
  for p in "${pre[@]}"; do
    case "$w" in "$p"/*) rest=${w#"$p"/}; return 0 ;; esac
  done
  return 1
}
no_dotdot() { case "/$1/" in */../*) return 1 ;; esac; return 0; }
# real_inside <path> <dir>: <path> resolves (symlinks followed, not required to exist) to <dir> or below it.
real_inside() {
  local rp rd
  rp=$(realpath -m -- "$1" 2>/dev/null) && rd=$(realpath -m -- "$2" 2>/dev/null) || return 1
  case "$rp" in "$rd"|"$rd"/*) return 0 ;; esac
  return 1
}
# readable_ok (Bash words): under handoffs/, or this session's own state file.
readable_ok() {
  local w=$1 s
  no_dotdot "$w" || return 1
  if strip_dir "$w" handoffs; then real_inside "$HANDOFFS/$rest" "$HANDOFFS"; return; fi
  if strip_dir "$w" state; then
    case "$rest" in */*) return 1 ;; esac
    for s in "$sid" '$sid' '${sid}'; do
      case "$rest" in "$s".*|"$s") real_inside "$STATE/$rest" "$STATE"; return ;; esac
    done
  fi
  return 1
}
# latest_ok (Bash words): a handoffs/.latest* file (pointer writes).
latest_ok() {
  no_dotdot "$1" || return 1
  strip_dir "$1" handoffs || return 1
  case "$rest" in */*) return 1 ;; .latest*) real_inside "$HANDOFFS/$rest" "$HANDOFFS"; return ;; esac
  return 1
}
# File tools: absolute, real path under handoffs/ (or, for reads, this session's state file).
file_write_ok() { case "$1" in /*) real_inside "$1" "$HANDOFFS" ;; *) return 1 ;; esac; }
file_read_ok() {
  local rp rs
  case "$1" in /*) ;; *) return 1 ;; esac
  real_inside "$1" "$HANDOFFS" && return 0
  rp=$(realpath -m -- "$1" 2>/dev/null) && rs=$(realpath -m -- "$STATE" 2>/dev/null) || return 1
  case "$rp" in "$rs"/*) rp=${rp#"$rs"/} ;; *) return 1 ;; esac
  case "$rp" in */*) return 1 ;; "$sid"|"$sid".*) return 0 ;; esac
  return 1
}

declare -A VARS=()
unq() { local w=$1; w=${w//\"/}; w=${w//\'/}; printf '%s' "$w"; }
resolve() { # $1 = word -> path text, resolving variables set earlier in this command
  local w; w=$(unq "$1")
  case "$w" in
    '$'[A-Za-z_]*|'${'*'}')
      local n=${w#\$}; n=${n#\{}; n=${n%\}}
      if [ -n "${VARS[$n]+x}" ]; then printf '%s' "${VARS[$n]}"; return; fi ;;
  esac
  printf '%s' "$w"
}

# --- one simple statement of a Bash command ----------------------------------
stmt_ok() {
  local s=$1 cmd w
  s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}
  s=${s#do }; s=${s#\{ }; s=${s% \}}; s=${s#then }
  s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}
  case "$s" in ""|done|break|fi|true|"}"|"{") return 0 ;; esac

  # 'for x in "word" "word"' — loop header
  if [[ "$s" =~ ^for\ [A-Za-z_][A-Za-z0-9_]*\ in\ [-A-Za-z0-9_./\$\"\{\}~\ ]+$ ]]; then return 0; fi

  # NAME=value — remember handoffs/.latest* targets so $tmp resolves later
  if [[ "$s" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(\"[^\"]*\"|\'[^\']*\'|[^[:space:]\"\']*)$ ]]; then
    local n=${BASH_REMATCH[1]} v; v=$(unq "${BASH_REMATCH[2]}")
    VARS[$n]=$v
    return 0
  fi

  # [ -x "path" ]
  if [[ "$s" =~ ^\[\ -[a-z]\ \"[^\"]*\"\ \]$ ]]; then return 0; fi

  # printf ... > handoffs/.latest*   (the only output redirection allowed)
  if [[ "$s" =~ ^printf\ (.*)\ \>\ ([^[:space:]]+)$ ]]; then
    local pargs=${BASH_REMATCH[1]} ptarget=${BASH_REMATCH[2]}
    [[ "$pargs" =~ ^[-A-Za-z0-9_./\$\"\'\{\}%\\~\ ]+$ ]] || return 1
    latest_ok "$(resolve "$ptarget")" && return 0
    return 1
  fi
  case "$s" in *'>'*|*'<'*) return 1 ;; esac

  read -r cmd s <<<"$s"
  case "$cmd" in
    ls|cat|stat)
      local -a words; read -ra words <<<"$s"
      for w in "${words[@]}"; do
        case "$w" in -*) continue ;; esac
        readable_ok "$(resolve "$w")" || return 1
      done
      [ "${#words[@]}" -gt 0 ] || return 1
      return 0 ;;
    mv)
      local -a words; read -ra words <<<"$s"
      [ "${#words[@]}" -eq 2 ] || return 1
      latest_ok "$(resolve "${words[0]}")" && latest_ok "$(resolve "${words[1]}")" ;;
    bash|sh)
      [[ "$s" =~ ^(\"?[^[:space:]\"]*request-handoff\.sh\"?|\"?\$\{?rh\}?\"?)([\ ].*)?$ ]] || return 1
      [[ "${BASH_REMATCH[2]:-}" =~ ^[-A-Za-z0-9_=./:@,+\$\"\'\{\}~\ ]*$ ]] ;;
    *) return 1 ;;
  esac
}

bash_ok() {
  local c=$1 stmt
  case "$c" in *'$('*|*'`'*|*'<'*|*'('*|*')'*) return 1 ;; esac
  c=${c//2>\/dev\/null/}; c=${c//2>&1/}; c=${c//>\/dev\/null/}
  c=${c//&&/;}; c=${c//||/;}; c=${c//$'\n'/;}
  case "$c" in *'|'*|*'&'*) return 1 ;; esac
  local IFS=';'
  # shellcheck disable=SC2086
  set -f; set -- $c; set +f
  IFS=$' \t\n'
  for stmt in "$@"; do stmt_ok "$stmt" || return 1; done
  return 0
}

allowed() {
  local p
  case "$tool" in
    Write|Edit|MultiEdit|NotebookEdit)
      p=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null) || exit 0
      [ -n "$p" ] && file_write_ok "$p" ;;
    Read|Grep|Glob|LS)
      p=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null) || exit 0
      [ -n "$p" ] && file_read_ok "$p" ;;
    Bash)
      p=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
      [ -n "$p" ] && bash_ok "$p" ;;
    *) return 1 ;;
  esac
}

allowed && exit 0

# --- deny, escalating to continue:false from the 3rd denial of this request ----
cnt=0
if [ -f "$STATE/$sid.gate-denials" ]; then
  read -r dk dc < "$STATE/$sid.gate-denials" 2>/dev/null || true
  [ "${dk:-}" = "$req_key" ] && case "${dc:-}" in ''|*[!0-9]*) ;; *) cnt=$dc ;; esac
fi
cnt=$((cnt + 1))
printf '%s %s\n' "$req_key" "$cnt" > "$STATE/$sid.gate-denials.tmp.$$" 2>/dev/null &&
  mv -f "$STATE/$sid.gate-denials.tmp.$$" "$STATE/$sid.gate-denials" 2>/dev/null ||
  rm -f "$STATE/$sid.gate-denials.tmp.$$" 2>/dev/null

if [ "$cnt" -ge 3 ]; then
  printf '%s\n' '{"continue":false,"stopReason":"handoff pending: stopping so the watcher can compact"}'
else
  jq -nc --arg r 'handoff pending: end your turn now so the watcher can compact; do not start new work' \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi
exit 0
