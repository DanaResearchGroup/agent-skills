#!/usr/bin/env bash
# fleet-digest.sh -- collector correctness and, most importantly, per-section
# failure isolation: a missing `gh` or an unreadable worktree root must mark
# ONLY the affected section ok:false, with a real error, while every sibling
# section still populates and the digest is still written as valid JSON.
# Happy-path-only tests would not catch a regression that quietly makes one
# section's failure take the whole digest down with it -- the two forced
# failures below are the point of this file, not an afterthought.

. "$(dirname "$0")/lib.sh"

SID1=11111111-1111-1111-1111-111111111111
SID2=22222222-2222-2222-2222-222222222222

# A small, fast, controlled worktree root -- NOT the real ~/Code -- so these
# tests are deterministic and don't depend on the state of the machine they
# happen to run on.
make_repo() { # $1 = path
  mkdir -p "$1"
  git -C "$1" init -q
  # An explicit identity here means this suite never depends on ambient
  # global git config -- a machine or CI image with no user.name/user.email
  # set would otherwise fail this commit outright.
  git -c user.name="fleet-digest test" -c user.email="fleet-digest-test@example.invalid" \
    -C "$1" commit --allow-empty -q -m init
}

# fleet-digest only reads the .ctx file itself; the pane/pane-owner
# companions lib.sh's session_new() also writes are for the watcher tests.
session_new_ctx() { # $1 = uuid, $2 = pct
  printf 'pct=%s ts=%s\n' "$2" "$(date +%s)" > "$STATE/$1.ctx"
}

is_valid_json() { python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$1" >/dev/null 2>&1; }

# Read a dotted field out of the digest (e.g. "prs.ok", "sessions.ok").
# Booleans print as "true"/"false" so assert_eq can compare against a
# literal, matching the string comparisons the rest of this harness uses.
jget() { # $1 = path to json file, $2 = dotted field path
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
cur = doc
for part in sys.argv[2].split("."):
    cur = cur[part]
print(str(cur).lower() if isinstance(cur, bool) else cur)
' "$1" "$2" 2>/dev/null
}

has_field() { # $1 = path to json file, $2 = dotted field path
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
cur = doc
for part in sys.argv[2].split("."):
    cur = cur[part]
' "$1" "$2" >/dev/null 2>&1
}

count_array() { # $1 = path to json file, $2 = dotted field path to an array
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
cur = doc
for part in sys.argv[2].split("."):
    cur = cur[part]
print(len(cur))
' "$1" "$2" 2>/dev/null
}

# Write a fake `herdr` into $1 that answers exactly the `herdr pane list`
# call fleet-digest.sh makes, with two canned panes shaped like real herdr
# output (compare to `herdr pane list`'s real JSON: {"result":{"panes":
# [...]}}, reshaped by collect_panes()). Whichever machine or CI runner
# executes this suite may or may not have a real herdr on PATH -- and even
# where it does, that herdr reports THAT machine's live panes, which is
# both nondeterministic and unrelated to the fixture under test. Every
# PATH shim below must supply this rather than falling through to ambient
# herdr, or a happy-path run is only "happy" on a machine that has herdr.
write_fake_herdr() { # $1 = shim dir
  cat > "$1/herdr" <<'FAKEHERDR'
#!/usr/bin/env bash
if [ "$1" = "pane" ] && [ "$2" = "list" ]; then
  cat <<'PANEJSON'
{"id":"cli:pane:list","result":{"panes":[
  {"agent":"claude","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"aaaaaaaa-0000-0000-0000-000000000001"},"agent_status":"idle","cwd":"/tmp/fake-a","pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"},
  {"agent":"claude","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"aaaaaaaa-0000-0000-0000-000000000002"},"agent_status":"working","cwd":"/tmp/fake-b","pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1"}
],"type":"pane_list"}}
PANEJSON
  exit 0
fi
exit 1
FAKEHERDR
  chmod +x "$1/herdr"
}

# A directory of symlinks to every tool fleet-digest.sh legitimately needs,
# EXCEPT gh -- so running with this on PATH forces a real "gh not found"
# failure without also breaking find/git/python3 (an empty PATH would take
# the whole script down for the wrong reason and prove nothing gh-specific).
# herdr is still a fake (not ambient) so the panes section stays hermetic
# even though this fixture isn't the one exercising panes behaviour.
build_gh_less_path() {
  local shim="$SB/path-shim"
  mkdir -p "$shim"
  local tool real
  for tool in bash sh python3 timeout sort cat mktemp wc date tr head tail dirname \
              basename hostname env awk mv mkdir rm git; do
    real=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$real" "$shim/$tool"
  done
  # find/grep are shadowed as shell FUNCTIONS in some interactive dev shells
  # (wrapping bfs/ugrep); `command -v` would then resolve to the bare name
  # and produce a broken self-referential symlink. `type -P` still bypasses
  # that shadowing (it only ever looks at PATH, never at functions) without
  # hardcoding a location that isn't guaranteed to exist on every system.
  ln -sf "$(type -P find)" "$shim/find"
  ln -sf "$(type -P grep)" "$shim/grep"
  write_fake_herdr "$shim"
  echo "$shim"
}

# A directory of symlinks to every tool fleet-digest.sh needs, PLUS a fake
# `herdr` and a minimal fake `gh` that only ever answers "not authenticated"
# / "no PRs" -- deterministic, no network, no dependence on whether the
# machine running this suite happens to have a real gh session or a real
# herdr. Used by fixtures that don't exercise gh- or herdr-specific
# behaviour (that's what build_fake_gh_path is for) but still run the real
# fleet-digest.sh end to end, so they must not fall through to the ambient
# PATH for either tool.
build_hermetic_path() {
  local shim="$SB/hermetic-shim"
  mkdir -p "$shim"
  local tool real
  for tool in bash sh python3 timeout sort cat mktemp wc date tr head tail dirname \
              basename hostname env awk mv mkdir rm git; do
    real=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$real" "$shim/$tool"
  done
  ln -sf "$(type -P find)" "$shim/find"
  ln -sf "$(type -P grep)" "$shim/grep"
  write_fake_herdr "$shim"
  cat > "$shim/gh" <<'FAKEGH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [ "$2" = "user" ]; then
  exit 1
fi
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  echo '[]'
  exit 0
fi
exit 1
FAKEGH
  chmod +x "$shim/gh"
  echo "$shim"
}

# A directory of symlinks to every tool fleet-digest.sh needs, PLUS a fake
# `gh` that answers `gh api user -q .login` and `gh pr list ... --json
# ...,author` with canned data instead of hitting the network -- so the
# authorship-labelling logic can be tested deterministically. $1 = the login
# `gh api user` should report (empty string means "resolution fails"); that
# same login is always used as the "mine" PR's author so the test can assert
# is_mine:true regardless of whether resolution itself succeeds.
build_fake_gh_path() { # $1 = login to report from `gh api user` ("" = unresolvable)
  local login="$1"
  # The "mine" PR's author is always the same login `gh api user` would
  # report when resolution succeeds, so a caller passing a different login
  # gets a matching "mine" PR -- that coupling is the useful behaviour this
  # fixture models, not an incidental hardcode. When resolution is meant to
  # fail ("" is passed) there is no real login to reuse, so fall back to a
  # fixed placeholder purely so the PR JSON has *some* author string.
  local mine_login="${login:-testuser}"
  local shim="$SB/gh-shim"
  mkdir -p "$shim"
  local tool real
  for tool in bash sh python3 timeout sort cat mktemp wc date tr head tail dirname \
              basename hostname env awk mv mkdir rm git; do
    real=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$real" "$shim/$tool"
  done
  # find/grep: see build_gh_less_path's comment above -- same shadowing
  # concern, same `type -P` fix.
  ln -sf "$(type -P find)" "$shim/find"
  ln -sf "$(type -P grep)" "$shim/grep"
  # herdr: a fake, not the ambient one -- see write_fake_herdr's comment.
  write_fake_herdr "$shim"
  cat > "$shim/gh" <<FAKEGH
#!/usr/bin/env bash
# Fake gh for tests: answers exactly the two calls fleet-digest.sh makes.
if [ "\$1" = "api" ] && [ "\$2" = "user" ]; then
  login="$login"
  if [ -z "\$login" ]; then
    exit 1
  fi
  echo "\$login"
  exit 0
fi
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
  cat <<'PRJSON'
[
  {"number": 1, "title": "mine PR", "headRefName": "feat-a", "mergeStateStatus": "CLEAN", "reviewDecision": "", "isDraft": false, "updatedAt": "2026-01-01T00:00:00Z", "url": "https://github.com/owner/repo/pull/1", "author": {"login": "$mine_login"}},
  {"number": 2, "title": "not mine PR", "headRefName": "feat-b", "mergeStateStatus": "CLEAN", "reviewDecision": "", "isDraft": false, "updatedAt": "2026-01-01T00:00:00Z", "url": "https://github.com/owner/repo/pull/2", "author": {"login": "someone-else"}}
]
PRJSON
  exit 0
fi
exit 1
FAKEGH
  chmod +x "$shim/gh"
  echo "$shim"
}

echo "== happy path =="

sandbox_new
ROOT1="$SB/code-root"
make_repo "$ROOT1/repo-a"
make_repo "$ROOT1/repo-b"
session_new_ctx "$SID1" 40
session_new_ctx "$SID2" 55
OUT="$SB/digest.json"
SHIM=$(build_hermetic_path)
env PATH="$SHIM" "$BIN/fleet-digest.sh" --out "$OUT" --root "$ROOT1" --timeout 30 >/dev/null 2>&1
RC=$?
assert_eq "exits 0 on a clean run" "$RC" "0"
assert_file "digest file is written" "$OUT"
if [ -f "$OUT" ]; then
  is_valid_json "$OUT" && _pass "output parses as JSON" || _fail "output parses as JSON" "invalid JSON in $OUT"
  assert_eq "schema_version is 1" "$(jget "$OUT" schema_version)" "1"
  has_field "$OUT" generated_at && _pass "generated_at is present" || _fail "generated_at is present" "missing"
  assert_eq "sessions section reports ok" "$(jget "$OUT" sessions.ok)" "true"
  assert_eq "worktrees section reports ok" "$(jget "$OUT" worktrees.ok)" "true"
  assert_eq "prs section reports ok" "$(jget "$OUT" prs.ok)" "true"
  has_field "$OUT" panes.ok && _pass "panes section carries an ok field" || _fail "panes section carries an ok field" "missing"
  assert_eq "both repos under the root are found" "$(count_array "$OUT" worktrees.worktrees)" "2"
  assert_eq "both sessions are found" "$(count_array "$OUT" sessions.sessions)" "2"
fi
sandbox_rm

echo "== forced failure: gh missing on PATH =="

sandbox_new
ROOT1="$SB/code-root"
make_repo "$ROOT1/repo-a"
session_new_ctx "$SID1" 40
SHIM=$(build_gh_less_path)
OUT="$SB/digest.json"
env PATH="$SHIM" "$BIN/fleet-digest.sh" --out "$OUT" --root "$ROOT1" --timeout 30 >/dev/null 2>&1
assert_file "digest is still written when gh is missing" "$OUT"
if [ -f "$OUT" ]; then
  is_valid_json "$OUT" && _pass "digest is still valid JSON" || _fail "digest is still valid JSON" "invalid"
  assert_eq "prs section reports ok:false" "$(jget "$OUT" prs.ok)" "false"
  assert_contains "prs error mentions gh" "$(jget "$OUT" prs.error)" "gh"
  assert_eq "sessions section still ok despite gh missing" "$(jget "$OUT" sessions.ok)" "true"
  assert_eq "worktrees section still ok despite gh missing" "$(jget "$OUT" worktrees.ok)" "true"
fi
sandbox_rm

echo "== forced failure: unreadable worktree root =="

sandbox_new
GOOD_ROOT="$SB/code-root"
make_repo "$GOOD_ROOT/repo-a"
BAD_ROOT="$SB/locked-root"
mkdir -p "$BAD_ROOT/inner"
make_repo "$BAD_ROOT/inner/repo-hidden"
chmod 000 "$BAD_ROOT"
session_new_ctx "$SID1" 40
OUT="$SB/digest.json"
SHIM=$(build_hermetic_path)
env PATH="$SHIM" "$BIN/fleet-digest.sh" --out "$OUT" --root "$GOOD_ROOT" --root "$BAD_ROOT" --timeout 30 >/dev/null 2>&1
chmod 755 "$BAD_ROOT"   # restore so sandbox_rm can actually delete the tree
assert_file "digest is still written when a root is unreadable" "$OUT"
if [ -f "$OUT" ]; then
  is_valid_json "$OUT" && _pass "digest is still valid JSON" || _fail "digest is still valid JSON" "invalid"
  assert_eq "worktrees section reports ok:false" "$(jget "$OUT" worktrees.ok)" "false"
  assert_contains "worktrees error mentions permission" "$(jget "$OUT" worktrees.error)" "ermission"
  assert_eq "worktree from the readable root is still collected" "$(count_array "$OUT" worktrees.worktrees)" "1"
  assert_eq "sessions section still ok despite worktrees failure" "$(jget "$OUT" sessions.ok)" "true"
  assert_eq "prs section still ok despite worktrees failure" "$(jget "$OUT" prs.ok)" "true"
fi
sandbox_rm

echo "== argument handling =="

sandbox_new
HELP=$("$BIN/fleet-digest.sh" --help 2>&1)
assert_contains "--help documents --out" "$HELP" "--out PATH"
assert_contains "--help documents the never-fetches guarantee" "$HELP" "git fetch"
"$BIN/fleet-digest.sh" --bogus-flag >/dev/null 2>&1
assert_eq "an unknown flag exits non-zero" "$?" "2"
sandbox_rm

echo "== PR authorship labelling: login resolves =="

sandbox_new
ROOT1="$SB/code-root"
make_repo "$ROOT1/repo-a"
git -C "$ROOT1/repo-a" remote add origin https://github.com/owner/repo.git
session_new_ctx "$SID1" 40
SHIM=$(build_fake_gh_path "testuser")
OUT="$SB/digest.json"
env PATH="$SHIM" "$BIN/fleet-digest.sh" --out "$OUT" --root "$ROOT1" --timeout 30 >/dev/null 2>&1
assert_file "digest is written with a fake gh present" "$OUT"
if [ -f "$OUT" ]; then
  is_valid_json "$OUT" && _pass "digest is valid JSON" || _fail "digest is valid JSON" "invalid"
  assert_eq "prs section reports ok" "$(jget "$OUT" prs.ok)" "true"
  assert_eq "my_login resolves to the fake gh login" "$(jget "$OUT" prs.my_login)" "testuser"
  assert_eq "prs.error is null when login resolves" "$(jget "$OUT" prs.error)" "None"
  assert_eq "one github remote is discovered" "$(jget "$OUT" prs.remote_count)" "1"
  # jget only walks plain dict keys, not list indices -- pull the two PR
  # objects out directly instead.
  PYOUT=$(python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
prs = doc["prs"]["remotes"][0]["prs"]
by_num = {p["number"]: p for p in prs}
print(by_num[1]["is_mine"], by_num[1]["author_login"])
print(by_num[2]["is_mine"], by_num[2]["author_login"])
' "$OUT")
  assert_contains "PR #1 (testuser) is labelled is_mine True" "$PYOUT" "True testuser"
  assert_contains "PR #2 (someone-else) is labelled is_mine False" "$PYOUT" "False someone-else"
fi
sandbox_rm

echo "== PR authorship labelling: login unresolvable => null, never false =="

sandbox_new
ROOT1="$SB/code-root"
make_repo "$ROOT1/repo-a"
git -C "$ROOT1/repo-a" remote add origin https://github.com/owner/repo.git
session_new_ctx "$SID1" 40
SHIM=$(build_fake_gh_path "")
OUT="$SB/digest.json"
env PATH="$SHIM" "$BIN/fleet-digest.sh" --out "$OUT" --root "$ROOT1" --timeout 30 >/dev/null 2>&1
assert_file "digest is written when gh user resolution fails" "$OUT"
if [ -f "$OUT" ]; then
  is_valid_json "$OUT" && _pass "digest is valid JSON" || _fail "digest is valid JSON" "invalid"
  assert_eq "prs section still reports ok (PR listing itself succeeded)" "$(jget "$OUT" prs.ok)" "true"
  assert_eq "my_login is null, not empty string" "$(jget "$OUT" prs.my_login)" "None"
  assert_contains "prs.error explains the unresolved login" "$(jget "$OUT" prs.error)" "resolve"
  PYOUT=$(python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
prs = doc["prs"]["remotes"][0]["prs"]
for p in prs:
    assert p["is_mine"] is None, p
print("all-null-ok")
' "$OUT")
  assert_eq "every PR is_mine is JSON null (never false) when login is unresolvable" "$PYOUT" "all-null-ok"
  assert_eq "sessions section unaffected by gh-user-resolution failure" "$(jget "$OUT" sessions.ok)" "true"
  assert_eq "worktrees section unaffected by gh-user-resolution failure" "$(jget "$OUT" worktrees.ok)" "true"
fi
sandbox_rm

echo "== companion summary file =="

sandbox_new
ROOT1="$SB/code-root"
make_repo "$ROOT1/repo-a"
make_repo "$ROOT1/repo-b"
git -C "$ROOT1/repo-a" remote add origin https://github.com/owner/repo.git
# Dirty repo-b (untracked file, uncommitted) so the summary's dirty-only
# filter has exactly one worktree to keep and one to drop.
touch "$ROOT1/repo-b/untracked-file"
session_new_ctx "$SID1" 40
SHIM=$(build_fake_gh_path "testuser")
OUT="$SB/digest.json"
SUMMARY_OUT="$SB/digest-summary.json"
env PATH="$SHIM" "$BIN/fleet-digest.sh" --out "$OUT" --summary-out "$SUMMARY_OUT" --root "$ROOT1" --timeout 30 >/dev/null 2>&1
assert_file "full digest is written" "$OUT"
assert_file "summary file is written" "$SUMMARY_OUT"
if [ -f "$OUT" ] && [ -f "$SUMMARY_OUT" ]; then
  is_valid_json "$SUMMARY_OUT" && _pass "summary parses as JSON" || _fail "summary parses as JSON" "invalid JSON in $SUMMARY_OUT"
  assert_eq "summary worktrees.count matches full digest's worktree array length" \
    "$(jget "$SUMMARY_OUT" worktrees.count)" "$(count_array "$OUT" worktrees.worktrees)"
  assert_eq "summary worktrees.count is 2 (both repos found)" "$(jget "$SUMMARY_OUT" worktrees.count)" "2"
  assert_eq "summary keeps only the dirty worktree" "$(jget "$SUMMARY_OUT" worktrees.dirty_or_ahead_behind_count)" "1"
  assert_eq "summary dirty-only entries list length matches its own count" \
    "$(count_array "$SUMMARY_OUT" worktrees.entries)" "$(jget "$SUMMARY_OUT" worktrees.dirty_or_ahead_behind_count)"
  assert_eq "summary prs.total_pr_count matches the two canned PRs" "$(jget "$SUMMARY_OUT" prs.total_pr_count)" "2"
  assert_eq "summary prs.mine_count is 1 (only the testuser-authored PR)" "$(jget "$SUMMARY_OUT" prs.mine_count)" "1"
  assert_eq "summary prs.entries length matches mine_count" \
    "$(count_array "$SUMMARY_OUT" prs.entries)" "$(jget "$SUMMARY_OUT" prs.mine_count)"
  assert_eq "summary sessions.count matches full digest" \
    "$(jget "$SUMMARY_OUT" sessions.count)" "$(count_array "$OUT" sessions.sessions)"
  has_field "$SUMMARY_OUT" failed_sources && _pass "summary carries a failed_sources list" || _fail "summary carries a failed_sources list" "missing"
  assert_eq "no failed sources on this happy-path run" "$(count_array "$SUMMARY_OUT" failed_sources)" "0"
  assert_eq "summary is much smaller than the full digest" "1" \
    "$([ "$(wc -c <"$SUMMARY_OUT")" -lt "$(wc -c <"$OUT")" ] && echo 1 || echo 0)"
fi
sandbox_rm

echo "== companion summary file: default path derivation =="

sandbox_new
ROOT1="$SB/code-root"
make_repo "$ROOT1/repo-a"
session_new_ctx "$SID1" 40
OUT="$SB/digest.json"
SHIM=$(build_hermetic_path)
env PATH="$SHIM" "$BIN/fleet-digest.sh" --out "$OUT" --root "$ROOT1" --timeout 30 >/dev/null 2>&1
assert_file "default-derived summary path exists" "$SB/digest-summary.json"
if [ -f "$SB/digest-summary.json" ]; then
  is_valid_json "$SB/digest-summary.json" && _pass "default-derived summary parses as JSON" || _fail "default-derived summary parses as JSON" "invalid"
fi
sandbox_rm

finish
