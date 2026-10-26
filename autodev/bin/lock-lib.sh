#!/usr/bin/env bash
# Shared owner-bearing lock operations for autodev session cycle locks.
# A new lock is a symlink whose target is a strict PID token. The target is
# deliberately below /dev/null: it is absolute, but cannot resolve because
# /dev/null is not a directory. Existing releases used directories with a pid
# file, so readers and owner-only release continue to support that format.

AUTODEV_LOCK_OWNER_PREFIX=/dev/null/autodev-lock-owner/

autodev_lock_pid_is_canonical(){
  case "$1" in
    ''|0*|*[!0-9]*) return 1 ;;
  esac
  # PID values are at most seven decimal digits under the shared Linux/BSD
  # ceiling, so reject oversized input before asking test(1) to compare it.
  [ "${#1}" -le 7 ] || return 1
  [ "$1" -le 4194304 ] 2>/dev/null
}

autodev_lock_token(){ # $1 = positive decimal PID
  autodev_lock_pid_is_canonical "$1" || return 1
  printf '%s%s\n' "$AUTODEV_LOCK_OWNER_PREFIX" "$1"
}

autodev_lock_parse_token(){ # $1 = exact symlink target; prints PID on success
  case "$1" in
    "$AUTODEV_LOCK_OWNER_PREFIX"*) ;;
    *) return 1 ;;
  esac
  local pid=${1#"$AUTODEV_LOCK_OWNER_PREFIX"}
  autodev_lock_pid_is_canonical "$pid" || return 1
  printf '%s\n' "$pid"
}

autodev_lock_publish(){ # $1 = lock path, $2 = positive decimal PID
  local lock_path=$1 pid=$2 token child child_target ln_status=0
  token=$(autodev_lock_token "$pid") || return 1

  # Avoid touching an existing legacy directory: ln's directory fall-through
  # would update its mtime even if the stray child were immediately removed.
  # A path that appears after this lstat-style precheck is handled below.
  if [ -L "$lock_path" ]; then
    return 1
  fi
  if [ -d "$lock_path" ] || [ -e "$lock_path" ]; then
    return 1
  fi

  # POSIX ln -s follows an existing directory at the destination and can
  # create a child entry there. Never infer success from ln's status alone.
  ln -s "$token" "$lock_path" 2>/dev/null || ln_status=$?
  if [ -L "$lock_path" ]; then
    child_target=$(readlink "$lock_path" 2>/dev/null) || child_target=
    if [ "$child_target" = "$token" ]; then
      return 0
    fi
  fi

  # Remove only the exact symlink this attempt may have created inside a
  # legacy directory (or through a symlink that resolves to a directory).
  child="$lock_path/${pid}"
  if [ -L "$child" ]; then
    child_target=$(readlink "$child" 2>/dev/null) || child_target=
    if [ "$child_target" = "$token" ]; then
      rm -f "$child" 2>/dev/null || true
    fi
  fi
  if ! autodev_lock_path_present "$lock_path" && [ "$ln_status" -eq 0 ]; then
    return 2
  fi
  return 1
}

autodev_lock_read_owner(){ # sets lock_owner_value, lock_owner_pid, lock_owner_readable, lock_owner_kind
  local lock_path=$1 target raw
  lock_owner_value=
  lock_owner_pid=
  lock_owner_readable=1
  lock_owner_kind=missing

  if [ -L "$lock_path" ]; then
    lock_owner_kind=symlink
    target=$(readlink "$lock_path" 2>/dev/null) || {
      lock_owner_readable=0
      return 0
    }
    lock_owner_value=$target
    lock_owner_pid=$(autodev_lock_parse_token "$target" 2>/dev/null) || lock_owner_pid=
    return 0
  fi

  if [ -d "$lock_path" ]; then
    lock_owner_kind=directory
    if [ -L "$lock_path/pid" ]; then
      lock_owner_readable=0
    elif [ -f "$lock_path/pid" ]; then
      raw=$(cat "$lock_path/pid" 2>/dev/null) || {
        lock_owner_readable=0
        return 0
      }
      lock_owner_value=$raw
      autodev_lock_pid_is_canonical "$raw" && lock_owner_pid=$raw
    elif [ -e "$lock_path/pid" ]; then
      lock_owner_readable=0
    fi
    return 0
  fi

  if [ -e "$lock_path" ]; then
    lock_owner_kind=other
    lock_owner_readable=0
  fi
}

autodev_lock_path_present(){ # true for normal paths and dangling symlinks
  [ -e "$1" ] || [ -L "$1" ]
}

autodev_lock_object_signature(){ # lstat-style identity and mtime on GNU/Linux and BSD/macOS
  local lock_path=$1 signature
  signature=$(stat -c '%d:%i:%s:%Y' "$lock_path" 2>/dev/null) \
    || signature=$(stat -f '%d:%i:%z:%m' "$lock_path" 2>/dev/null) \
    || return 1
  printf '%s\n' "$signature"
}

autodev_lock_owner_signature(){ # $1 = lock path; lstat the symlink or legacy pid entry
  local lock_path=$1 owner_path identity target
  if [ -L "$lock_path" ]; then
    identity=$(autodev_lock_object_signature "$lock_path") || return 1
    target=$(readlink "$lock_path" 2>/dev/null) || return 1
    printf 'symlink:%s:%s\n' "$identity" "$target"
    return 0
  fi
  owner_path="$lock_path/pid"
  if [ -L "$owner_path" ]; then
    identity=$(autodev_lock_object_signature "$owner_path") || return 1
    target=$(readlink "$owner_path" 2>/dev/null) || return 1
    printf 'pid-symlink:%s:%s\n' "$identity" "$target"
    return 0
  fi
  if [ ! -e "$owner_path" ]; then
    printf 'missing\n'
    return 0
  fi
  autodev_lock_object_signature "$owner_path"
}

autodev_lock_release_owned(){ # $1 = path, $2 = owner PID; false if ownership changed
  local lock_path=$1 expected_pid=$2 token before after owner_before owner_after
  token=$(autodev_lock_token "$expected_pid") || return 1
  autodev_lock_path_present "$lock_path" || return 1
  before=$(autodev_lock_object_signature "$lock_path") || return 1
  owner_before=$(autodev_lock_owner_signature "$lock_path") || return 1
  autodev_lock_read_owner "$lock_path"
  [ "$lock_owner_readable" = 1 ] && [ "$lock_owner_pid" = "$expected_pid" ] || return 1
  after=$(autodev_lock_object_signature "$lock_path") || return 1
  owner_after=$(autodev_lock_owner_signature "$lock_path") || return 1
  [ "$before" = "$after" ] && [ "$owner_before" = "$owner_after" ] || return 1

  if [ -L "$lock_path" ]; then
    [ "$(readlink "$lock_path" 2>/dev/null || true)" = "$token" ] || return 1
    rm -f "$lock_path" 2>/dev/null
    return $?
  fi
  [ -d "$lock_path" ] && [ ! -L "$lock_path" ] || return 1
  [ "$lock_owner_kind" = directory ] || return 1
  rm -rf "$lock_path" 2>/dev/null
}
