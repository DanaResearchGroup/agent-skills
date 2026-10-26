# request-lib.sh — when is a compact/handoff request still worth honouring?
# Sourced by auto-handoff-watch.sh and auto-handoff-sweep.sh; they MUST agree.
#
# Age never decides. A /goal session can run one turn for hours with the pane
# never idle, so a perfectly good request outlives any TTL and was being deleted
# unserved. A request is stale only when it has been SATISFIED or cannot be:
#   compact-request  the handoff it points to (handoffs/.latest.<sid>) is missing,
#                    or is OLDER than the session's last compaction
#                    (<sid>.compacted) — that compaction already consumed it.
#   handoff-request  asks for a handoff that is not written yet, so no pointer is
#                    expected; stale only once a compaction is newer than the request.
# Comparisons use -nt (sub-second where available); an exact tie keeps the request,
# since a lost request parks the session while a kept one costs one extra /compact.
# $1 = state dir, $2 = handoffs dir, $3 = sid, $4 = compact-request|handoff-request,
# $5 = optional path of the request file to judge (default: the live marker)
request_valid() {
  local state=$1 handoffs=$2 sid=$3 kind=$4 req comp
  req=${5:-$state/$sid.$kind}; comp="$state/$sid.compacted"
  [ -f "$req" ] || return 1
  if [ "$kind" = handoff-request ]; then
    [ -f "$comp" ] || return 0
    ! [ "$comp" -nt "$req" ]
    return
  fi
  local ptr hf
  ptr=$(head -n1 "$handoffs/.latest.$sid" 2>/dev/null) || return 1
  [ -n "$ptr" ] && [ -f "$ptr" ] || return 1
  [ -f "$comp" ] || return 0
  ! [ "$comp" -nt "$ptr" ]
}

# Remove a stale request without ever deleting a valid one. Judging then rm'ing is
# a race: between the two, the session can land a new handoff pointer (or file a
# new request), and a plain rm would destroy it. So: claim the file with an atomic
# mv, judge the CLAIMED file again, and only then delete; if it turned valid,
# put it back — never over a newer request filed meanwhile (mv -n).
# Returns 0 if a stale request was removed, 1 otherwise (valid, or none).
remove_stale_request() { # same args as request_valid
  local state=$1 sid=$3 kind=$4 req claim
  req="$state/$sid.$kind"
  request_valid "$@" && return 1
  [ -f "$req" ] || return 1
  claim="$req.stale.$$"
  mv -f "$req" "$claim" 2>/dev/null || return 1   # lost the race to another cleaner
  if request_valid "$1" "$2" "$3" "$4" "$claim"; then
    mv -n "$claim" "$req" 2>/dev/null
    rm -f "$claim" 2>/dev/null                    # still there only if a newer request won
    return 1
  fi
  rm -f "$claim" 2>/dev/null
  return 0
}

# A refused post-compaction reload is obsolete once its session has completed
# another turn or filed/written a newer handoff. Shared by the watcher and the
# sweeper so they agree on when a durable retry is superseded.
reload_marker_retire_reason() { # $1 = state, $2 = handoffs, $3 = sid, $4 = marker
  local state=$1 handoffs=$2 sid=$3 marker=$4
  if [ -f "$state/$sid.handoff-request" ] && [ "$state/$sid.handoff-request" -nt "$marker" ]; then
    printf 'new-handoff-request\n'
    return 0
  fi
  if [ -f "$handoffs/.latest.$sid" ] && [ "$handoffs/.latest.$sid" -nt "$marker" ]; then
    printf 'new-handoff\n'
    return 0
  fi
  if [ -f "$state/$sid.idle" ] && [ "$state/$sid.idle" -nt "$marker" ]; then
    printf 'completed-turn\n'
    return 0
  fi
  return 1
}
