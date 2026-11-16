#!/usr/bin/env bash
# ctx-over.sh: the checkpoint beat asks the watcher's own question.
#
# The autodev checkpoint beat used to read `pct` and yield only when pct > 35.
# On a Persona seat at 200,000 tokens of a 1M window that reads pct=20, so the
# model started the next phase instead of ending its turn, and the watcher never
# got its idle turn boundary. ctx-over.sh answers from threshold-lib.sh, so the
# model and the watcher use one line. This file pins:
#   - Persona seat at 200k of 1M: over (exit 0); non-Persona, same reading: below (1),
#   - the 35% rule (pct > 35, as the watcher's trigger) where the token line does not
#     govern: a 200k-window seat and a .ctx with no tok=,
#   - exit 2 with no session id or no reading,
#   - SKILL.md never tells the model to compare pct with 35 itself.

# shellcheck disable=SC2016  # the $-strings are literal SKILL.md text
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

SID=55555555-5555-5555-5555-555555555555

# $1 = workdir (persona|other), $2 = pct, $3 = tok (or -), $4 = win (or -)
ctx_set() {
  local wd=$1
  case "$wd" in
    persona) wd="$AUTODEV_PERSONA_ROOT/method" ;;
    other) wd="$SB/elsewhere" ;;
  esac
  printf '%s\n' "$wd" > "$STATE/$SID.workdir"
  if [ "$3" = - ]; then
    printf 'pct=%s ts=%s\n' "$2" "$(date +%s)" > "$STATE/$SID.ctx"
  else
    printf 'pct=%s tok=%s win=%s ts=%s\n' "$2" "$3" "$4" "$(date +%s)" > "$STATE/$SID.ctx"
  fi
}

# check <name> <expected exit> [<expected output fragment>] — runs ctx-over.sh $SID.
check() {
  local out rc
  out=$(bash "$BIN/ctx-over.sh" "${CHECK_SID-$SID}" 2>&1); rc=$?
  assert_eq "$1 (exit)" "$rc" "$2"
  [ -z "${3:-}" ] || assert_contains "$1 (output)" "$out" "$3"
}

sandbox_new
export AUTODEV_PERSONA_ROOT="$SB/Persona"
mkdir -p "$AUTODEV_PERSONA_ROOT/method/PI" "$SB/elsewhere"

echo "== the gate: 200,000 tokens of a 1M window =="
ctx_set persona 20 200000 1000000
check "Persona seat at 200k of 1M is over its line" 0 "over (tok=200000 >= 200000)"
ctx_set other 20 200000 1000000
check "non-Persona seat at 200k of 1M is below 35%" 1 "below (pct=20 below 35)"
ctx_set persona 20 199999 1000000
check "Persona seat one token below the line is below" 1 "below"
printf 'compact_at_tokens = 300000\n' > "$AUTODEV_PERSONA_ROOT/method/PI/model.toml"
ctx_set persona 25 250000 1000000
check "compact_at_tokens raises the Persona line" 1 "below 300000"
rm -f "$AUTODEV_PERSONA_ROOT/method/PI/model.toml"

echo "== the 35% rule where the token line does not govern =="
ctx_set persona 36 72000 200000
check "200k-window Persona seat past 35% is over" 0 "pct=36 > 35"
ctx_set persona 35 70000 200000
check "200k-window Persona seat at exactly 35% is below (pct > 35)" 1
ctx_set persona 36 - -
check "a .ctx with no tok= keeps the percent rule (over)" 0
ctx_set persona 20 - -
check "a .ctx with no tok= keeps the percent rule (below)" 1
ctx_set other 40 400000 1000000
check "non-Persona seat past 35% is over" 0

echo "== no usable reading =="
CHECK_SID="" check "no session id exits 2" 2 "unknown"
CHECK_SID=unknown check "MYSID=unknown exits 2" 2 "unknown"
rm -f "$STATE/$SID.ctx"
check "no .ctx exits 2" 2 "unknown"
sandbox_rm

echo "== SKILL.md: the checkpoint beat asks ctx-over.sh, never pct vs 35 =="
# A line that compares pct with 35 directly, in either order, with any operator.
pct_vs_35() {
  grep -nE 'pct[^A-Za-z0-9]{0,4}(>=?|<=?|-gt|-ge|-lt|-le)[^A-Za-z0-9]{0,4}35([^0-9]|$)|35[^A-Za-z0-9]{0,4}(>=?|<=?|-gt|-ge|-lt|-le)[^A-Za-z0-9]{0,4}pct' "$1"
}
probe=$(mktemp "${TMPDIR:-/tmp}/ctx-over-probe.XXXXXX")
for bad in '3. **If `pct > 35`**' 'the reactive `pct >= 35` beat' '[ "$pct" -gt 35 ]'; do
  printf '%s\n' "$bad" > "$probe"
  if pct_vs_35 "$probe" >/dev/null; then _pass "doc check catches [$bad]"
  else _fail "doc check catches [$bad]" "pattern missed it"; fi
done
rm -f "$probe"
hits=$(pct_vs_35 "$SKILL_DIR/SKILL.md")
assert_eq "SKILL.md never compares pct with 35 directly" "$hits" ""
assert_contains "SKILL.md checkpoint beat runs ctx-over.sh" "$(cat "$SKILL_DIR/SKILL.md")" 'bash "$AUTODEV_BIN/ctx-over.sh" "${MYSID:-unknown}"'

finish
