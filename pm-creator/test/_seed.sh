#!/usr/bin/env bash
# test/_seed.sh — TEST-ONLY fixture seeder.
#
# Provides `pm_raw_append`, the old public `pm_emit`: a grammar-only,
# rule-engine-bypassing append (no transition legality, no attempt minting,
# no duplicate/supersede/lane checks). It must NEVER ship in
# templates/bin/_lib.sh (a generated repo must not have a raw-append escape
# hatch reachable) — it exists solely so tests can seed a log with a
# specific (possibly-adversarial) raw line without going through the rule
# engine's legality checks.
#
# Must be sourced AFTER templates/bin/_lib.sh: it reuses _lib.sh's grammar
# tables (_PM_REQUIRED_KEYS / _PM_OPTIONAL_KEYS / _PM_KEY_ORDER /
# _PM_TOKEN_RE) and its lock/root helpers (pm_lock / pm_unlock / _pm_root),
# none of which are appenders themselves.
#
# Run indirectly via: bash test/enforce_test.sh / bash test/lib_test.sh

pm_raw_append() {
  # pm_raw_append <type> <k=v> [<k=v> ...]
  # TEST/FIXTURE-ONLY. Validate against the grammar (types, required/known
  # keys, charset, no duplicate keys) and atomically append exactly one
  # \n-terminated line to .pm/events.log under pm_lock. Writes nothing and
  # returns non-zero on ANY validation failure. Auto-writes the
  # `EVENT schema v=1` header first if the log is empty (and this call
  # itself is not the schema event). Does NOT validate transition legality,
  # mint attempts, or enforce anything from enforcement.md — use pm_apply /
  # pm_apply_batch for that.
  local type="${1:-}"
  if [[ -z "$type" ]]; then
    echo "pm_raw_append: missing <type>" >&2
    return 1
  fi
  shift

  if [[ -z "${_PM_REQUIRED_KEYS[$type]+x}" ]]; then
    echo "pm_raw_append: unknown event type '$type'" >&2
    return 1
  fi

  local -A seen=()
  local -A kv=()
  local pair key value
  for pair in "$@"; do
    if [[ "$pair" != *=* ]]; then
      echo "pm_raw_append: malformed pair '$pair' (expected key=value)" >&2
      return 1
    fi
    key="${pair%%=*}"
    value="${pair#*=}"
    if [[ -n "${seen[$key]+x}" ]]; then
      echo "pm_raw_append: duplicate key '$key'" >&2
      return 1
    fi
    seen[$key]=1
    if [[ -z "$value" ]]; then
      echo "pm_raw_append: empty value for key '$key'" >&2
      return 1
    fi
    if [[ ! "$value" =~ $_PM_TOKEN_RE ]]; then
      echo "pm_raw_append: value for key '$key' fails token charset: '$value'" >&2
      return 1
    fi
    kv[$key]="$value"
  done

  local k
  for k in ${_PM_REQUIRED_KEYS[$type]}; do
    if [[ -z "${kv[$k]+x}" ]]; then
      echo "pm_raw_append: missing required key '$k' for type '$type'" >&2
      return 1
    fi
  done

  # NOTE: unknown/extra keys are accepted and passed through (forward-compat;
  # see _lib.sh's file-header NOTE). They are appended after the canonical
  # order.
  local root
  root="$(_pm_root "")" || return 1
  local pmdir="$root/.pm"
  local log="$pmdir/events.log"
  mkdir -p "$pmdir"

  local line="EVENT $type"
  local -A emitted=()
  for k in ${_PM_KEY_ORDER[$type]}; do
    if [[ -n "${kv[$k]+x}" ]]; then
      line+=" $k=${kv[$k]}"
      emitted[$k]=1
    fi
  done
  for k in "${!kv[@]}"; do
    if [[ -z "${emitted[$k]+x}" ]]; then
      line+=" $k=${kv[$k]}"
    fi
  done

  pm_lock "$root" || return 1
  (
    if [[ ! -s "$log" && "$type" != "schema" ]]; then
      printf 'EVENT schema v=1\n' >> "$log"
    fi
    printf '%s\n' "$line" >> "$log"
  )
  local rc=$?
  pm_unlock
  return $rc
}
