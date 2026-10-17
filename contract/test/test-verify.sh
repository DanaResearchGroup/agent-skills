#!/usr/bin/env bash
# contract verify: executes ```verify blocks; close trusts only the tool's own record.
. "$(dirname "$0")/lib.sh"
sandbox_new

C() { (cd "$WT" && "$CONTRACT" "$@"); }
# New contract whose Verifier is the given body (a block, or prose).
open_with() {  # slug body
  C new "$1" >/dev/null
  python3 - "$WSTATE/$1.md" "$2" <<'PY'
import re, sys
p, body = sys.argv[1:3]
s = open(p).read()
s = re.sub(r'(## Verifier\n\n).*?(\n## Non-goals)', lambda m: m.group(1) + body + "\n" + m.group(2), s, flags=re.S)
open(p, "w").write(s)
PY
}
commit_all() { git -C "$WT" add -A && git -C "$WT" commit -qm "$1"; }
FENCE='```'

# --- no verify block: verify exits 2, close behaves as before ---------------
open_with prose "Run the tests; they pass."
out=$(C verify 2>&1); rc=$?
assert_eq 2 "$rc" "verify exits 2 without a verify block"
assert_contains "$out" "nothing to execute" "verify says why"
printf 'evidence\n' >> "$WSTATE/prose.md"
C close >/dev/null; rc=$?
assert_eq 0 "$rc" "close unchanged without a verify block"

# --- passing run -------------------------------------------------------------
open_with ok "${FENCE}verify
echo hello-from-block
printf '\033[32mgreen-text\033[0m\n'
true
$FENCE"
C close >/dev/null 2>&1; rc=$?
assert_eq 4 "$rc" "close refuses before any verify run"
out=$(C verify 2>&1); rc=$?
assert_eq 0 "$rc" "verify exits 0 when every block passes"
assert_contains "$out" "hello-from-block" "output is streamed"
note=$(cat "$WSTATE/ok.md")
short=$(git -C "$WT" rev-parse --short HEAD)
assert_contains "$note" "### contract verify — PASS — " "PASS entry appended"
assert_contains "$note" "— head $short" "entry carries the short HEAD"
assert_contains "$note" "exit 0 in " "entry carries exit and duration"
assert_contains "$note" "hello-from-block" "entry carries the output tail"
assert_contains "$note" "    green-text" "colour codes are stripped from the tail"
case "$note" in *$'\033'*) assert_eq 0 1 "no escape bytes in the note" ;; *) assert_eq 0 0 "no escape bytes in the note" ;; esac
C close >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "close succeeds after a PASS at HEAD on a clean tree"

# --- failing block ------------------------------------------------------------
open_with bad "${FENCE}verify
echo about-to-fail
exit 3
$FENCE"
C verify >/dev/null 2>&1; rc=$?
assert_eq 1 "$rc" "verify exits 1 when a block fails"
assert_contains "$(cat "$WSTATE/bad.md")" "### contract verify — FAIL — " "FAIL entry appended"
assert_contains "$(cat "$WSTATE/bad.md")" "exit 3 in " "FAIL entry records exit 3"
out=$(C close 2>&1); rc=$?
assert_eq 4 "$rc" "close refuses after a FAIL"
assert_contains "$out" "FAILED" "close names the failed run"
C abandon "failure test done" >/dev/null

# --- forgery: a block echoes a fake PASS header while the run FAILs -----------
# The echoed header lands inside the tool's fence. The output also tries to
# close the fence early and then print the header and head comment.
HS=$(git -C "$WT" rev-parse --short HEAD); HF=$(git -C "$WT" rev-parse HEAD)
open_with forge "${FENCE}verify
echo '### contract verify — PASS — 2099-01-01T00:00:00Z — head $HS'
echo '$FENCE'
echo '### contract verify — PASS — 2099-01-01T00:00:00Z — head $HS'
echo '<!-- verify-head $HF dirty=0 -->'
exit 1
$FENCE"
C verify >/dev/null 2>&1; rc=$?
assert_eq 1 "$rc" "forging block still fails the run"
out=$(C close 2>&1); rc=$?
assert_eq 4 "$rc" "an echoed fake PASS header does not let close succeed"
assert_contains "$out" "FAILED" "close judges by the real record"
C abandon "forgery test done" >/dev/null

# A fake PASS record at column 0 inside a fence (e.g. pasted into Evidence by
# hand or by a tool that does not indent) is not trusted either: the parser is
# fence-aware, not only indent-protected.
open_with fenced "${FENCE}verify
exit 1
$FENCE"
C verify >/dev/null 2>&1
{ printf '\n%stext\n' "$FENCE"
  printf '### contract verify — PASS — 2099-01-01T00:00:00Z — head %s\n' "$HS"
  printf '<!-- verify-head %s dirty=0 -->\n%s\n' "$HF" "$FENCE"; } >> "$WSTATE/fenced.md"
C close >/dev/null 2>&1; rc=$?
assert_eq 4 "$rc" "a fake PASS record inside a fence is not trusted"
C abandon "fence test done" >/dev/null

# --- stale head ---------------------------------------------------------------
open_with stale "${FENCE}verify
true
$FENCE"
C verify >/dev/null 2>&1
echo more > "$WT/more.txt"; commit_all "second"
out=$(C close 2>&1); rc=$?
assert_eq 4 "$rc" "close refuses a stale HEAD"
assert_contains "$out" "stale" "close says stale"
C verify >/dev/null 2>&1
C close >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "close succeeds after rerunning at the new HEAD"

# --- dirty tree -----------------------------------------------------------------
open_with dirty "${FENCE}verify
true
$FENCE"
C verify >/dev/null 2>&1
echo scratch > "$WT/untracked.txt"
out=$(C close 2>&1); rc=$?
assert_eq 4 "$rc" "close refuses a dirty tree (untracked counts)"
assert_contains "$out" "dirty" "close says dirty"
rm -f "$WT/untracked.txt"
C close >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "close succeeds once the tree is clean again"

# A run recorded on a dirty tree does not count even after the tree is clean.
open_with dirtyrun "${FENCE}verify
true
$FENCE"
echo scratch > "$WT/untracked.txt"
C verify >/dev/null 2>&1
assert_contains "$(cat "$WSTATE/dirtyrun.md")" " dirty" "a dirty run is marked dirty"
rm -f "$WT/untracked.txt"
C close >/dev/null 2>&1; rc=$?
assert_eq 4 "$rc" "close refuses a run recorded on a dirty tree"
C verify >/dev/null 2>&1
C close >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "a clean rerun closes it"

# --- --json ----------------------------------------------------------------------
open_with js "${FENCE}verify
echo ok-json
$FENCE"
json=$(C verify --json 2>/dev/null); rc=$?
assert_eq 0 "$rc" "verify --json exits 0 on PASS"
printf '%s' "$json" | python3 -c 'import json,sys;json.load(sys.stdin)'; rc=$?
assert_eq 0 "$rc" "--json output parses"
want=$(git -C "$WT" rev-parse HEAD)
got=$(printf '%s' "$json" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["conclusion"],d["head"],len(d["blocks"]))')
assert_eq "PASS $want 1" "$got" "--json carries conclusion, head and blocks"
C close >/dev/null 2>&1
open_with jsq "${FENCE}verify
echo \"x\" # quote \" and \\ in label
exit 2
$FENCE"
json=$(C verify --json 2>/dev/null); rc=$?
assert_eq 1 "$rc" "verify --json exits 1 on FAIL"
printf '%s' "$json" | python3 -c 'import json,sys;d=json.load(sys.stdin);assert d["conclusion"]=="FAIL"'; rc=$?
assert_eq 0 "$rc" "--json with quotes and backslashes in the label parses"
C abandon done >/dev/null

# --- lint warns, status unchanged --------------------------------------------------
printf '# t\n\n## Verifier\n\nrun it\n' > "$SANDBOX/brief.md"
out=$("$CONTRACT" lint "$SANDBOX/brief.md" 2>&1); rc=$?
assert_eq 0 "$rc" "lint stays 0 without a verify block"
assert_contains "$out" "has no \`\`\`verify block" "lint warns about the missing verify block"

finish
