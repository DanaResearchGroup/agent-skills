#!/usr/bin/env bash
# Launch Codex with an optional model-ladder choice, preserving caller arguments.
set -euo pipefail

command_args=(codex exec)
if [ "${1:-}" = resume ]; then
  command_args+=(resume)
  shift
fi
model_args=()
effort=high
ladder="$HOME/.claude/skills/model-ladder/bin/ladder.py"
if [ -x "$ladder" ] && resolved=$("$ladder" resolve "${SPAR_TIER:-review}" 2>/dev/null); then
  IFS=$'\t' read -r tier harness model resolved_effort extra <<< "$resolved"
  # A non-Codex or incomplete result cannot supply a Codex model choice.
  if [ "$tier" = "${SPAR_TIER:-review}" ] && [ "$harness" = codex ] &&
     [ -n "$model" ] && [ -z "$extra" ]; then
    case "$resolved_effort" in
      none|minimal|low|medium|high|xhigh)
        model_args=(-m "$model")
        effort=$resolved_effort
        ;;
    esac
  fi
fi
exec "${command_args[@]}" "${model_args[@]}" -c "model_reasoning_effort=\"$effort\"" "$@"
