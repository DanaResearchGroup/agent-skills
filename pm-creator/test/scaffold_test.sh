#!/usr/bin/env bash
# Test harness for scaffold.sh — hostile-input hardening (spar rounds 4-5).
#
# Covers: (1) values containing JSON-breaking characters (", \, newline) still
# produce a valid .pm/config.json; (2) a forced mid-scaffold failure leaves no
# partial --out dir behind, and a retry then succeeds; (3) a surviving
# lowercase/numeric {{placeholder}} makes scaffold fail loudly and name it;
# (4) a hostile *_JSON value that renders invalid JSON aborts with no
# published --out (H4); (5) publishing over a pre-existing --out (non-empty)
# never nests the temp dir inside it, and (5b) a pre-existing EMPTY --out is
# also refused rather than silently replaced by `mv -T` (H5), while (5c) a
# clean publish with no pre-existing --out still succeeds; (6) a SIGTERM
# mid-run leaves no .scaffold-tmp.* dir behind (M6); (7) a multi-line
# {{...}} placeholder is caught by the survivor guard even though grep is
# line-oriented (M7).
#
# This harness uses the `cond && ok || fail` assertion idiom throughout; ok/fail
# always return 0, so SC2015's "C may run when A is true" caveat cannot bite here.
# shellcheck disable=SC2015
#
# Run: bash test/scaffold_test.sh
set -u

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PM_CREATOR_DIR="$(cd "${THIS_DIR}/.." && pwd)"
SCAFFOLD="${PM_CREATOR_DIR}/scaffold.sh"
REAL_TEMPLATES="${PM_CREATOR_DIR}/templates"

PASS=0
FAIL=0
FAILED_NAMES=()

ok() {
  local name="$1"
  PASS=$((PASS + 1))
  printf 'ok      %s\n' "$name"
}

fail() {
  local name="$1"
  shift
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("$name")
  printf 'FAIL    %s -- %s\n' "$name" "$*"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pm-creator-scaffold-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Full values.json covering every placeholder in the real templates/ tree,
# with a hostile CAMPAIGN_NAME: a double quote, a backslash, and a newline.
write_full_values() {
  local out="$1" demo="$2"
  DEMO_PATH="$demo" python3 - "$out" <<'PY'
import json, os, sys
demo = os.environ["DEMO_PATH"]
v = {
  "CAMPAIGN_NAME": 'Op "Alpha"\\Beta\nLine2',
  "CAMPAIGN_SLUG": "hostile",
  "PRIMARY_REPO": "demo",
  "REPO_LIST": "`demo` -> `main`",
  "WORKTREE_ROOT": "/tmp/hostile-wt",
  "RUNS_ROOT": "/tmp/hostile-runs",
  "HERDR_WORKSPACE": "zzz-hostile",
  "MODEL_ROUTING": "| Sonnet | default worker |",
  "REMOTE_POLICY": "local-only",
  "UPLOAD_POLICY": "none (local-only)",
  "CAPACITY_NOTE": " (single dev box).",
  "OPTIONAL_SLOT_NOTE": ", `RUNS.md`",
  "ALWAYS_HUMAN_GATES": "merges to `main`, any push",
  "HARDWARE_TABLE": "| CPU | test box |",
  "CAPACITY_NOTES": "One generation at a time.",
  "CAPACITY_RULES": "1. Don't stack heavy jobs.",
  "REPOS_JSON": json.dumps([{"name": "demo", "path": demo, "mainline": "main"}]),
  "OPTIONAL_SLOTS_JSON": json.dumps({"runs": True, "machine": True}),
}
json.dump(v, open(sys.argv[1], "w"))
PY
}

# ---------------------------------------------------------------------------
# 1. Hostile characters in an interpolated value survive as valid JSON.
# ---------------------------------------------------------------------------
section_json_escaping() {
  local demo values out
  demo="$WORK/demo1"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values1.json"
  write_full_values "$values" "$demo"

  out="$WORK/out1"
  if bash "$SCAFFOLD" --values "$values" --out "$out" >"$WORK/s1.out" 2>"$WORK/s1.err"; then
    ok "scaffold succeeds with quote/backslash/newline in a value"
  else
    fail "scaffold succeeds with quote/backslash/newline in a value" "$(cat "$WORK/s1.err")"
    return
  fi

  if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$out/.pm/config.json" 2>"$WORK/s1.parse.err"; then
    ok "config.json is valid JSON despite hostile CAMPAIGN_NAME"
  else
    fail "config.json is valid JSON despite hostile CAMPAIGN_NAME" "$(cat "$WORK/s1.parse.err")"
  fi

  local roundtrip
  roundtrip="$(python3 -c "import json; print(json.load(open('$out/.pm/config.json'))['campaign'])")"
  local expected
  expected='Op "Alpha"\Beta
Line2'
  if [[ "$roundtrip" == "$expected" ]]; then
    ok "config.json campaign value round-trips exactly"
  else
    fail "config.json campaign value round-trips exactly" "got [$roundtrip]"
  fi

  # REPOS_JSON must stay raw JSON (not re-escaped into a JSON string).
  local repo_name
  repo_name="$(python3 -c "import json; print(json.load(open('$out/.pm/config.json'))['repos'][0]['name'])")"
  [[ "$repo_name" == "demo" ]] && ok "REPOS_JSON interpolated raw (not double-escaped)" \
    || fail "REPOS_JSON interpolated raw (not double-escaped)" "got [$repo_name]"
}

# ---------------------------------------------------------------------------
# 2. A forced mid-scaffold failure leaves no partial --out dir; retry works.
# ---------------------------------------------------------------------------
section_no_partial_dir() {
  local demo values out badtemplates
  demo="$WORK/demo2"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values2.json"
  write_full_values "$values" "$demo"

  # A templates tree that is a copy of the real one, but missing a required
  # placeholder's value on purpose isn't needed — instead we force failure by
  # pointing --templates at a copy with an unresolvable extra placeholder,
  # which fails the post-interpolation survivor guard after files were
  # already written into the (temp) output tree.
  badtemplates="$WORK/bad-templates"
  rm -rf "$badtemplates"
  cp -r "$REAL_TEMPLATES" "$badtemplates"
  printf '\nLEFTOVER: {{doesNotExist}}\n' >> "$badtemplates/README.md.tmpl"

  out="$WORK/out2"
  if bash "$SCAFFOLD" --values "$values" --out "$out" --templates "$badtemplates" >"$WORK/s2.out" 2>"$WORK/s2.err"; then
    fail "forced scaffold failure exits non-zero" "unexpectedly succeeded"
  else
    ok "forced scaffold failure exits non-zero"
  fi

  if [[ -e "$out" ]]; then
    fail "no partial --out dir left behind after failure" "found: $(ls -la "$out" 2>&1)"
  else
    ok "no partial --out dir left behind after failure"
  fi

  # no stray temp dirs left in the parent either
  local stray
  stray="$(find "$WORK" -maxdepth 1 -name '.scaffold-tmp.*' | wc -l | tr -d ' ')"
  [[ "$stray" == "0" ]] && ok "no stray .scaffold-tmp.* dirs left in parent" \
    || fail "no stray .scaffold-tmp.* dirs left in parent" "found $stray"

  # retry with the real (good) templates now succeeds at the same --out path
  if bash "$SCAFFOLD" --values "$values" --out "$out" >"$WORK/s2b.out" 2>"$WORK/s2b.err"; then
    ok "retry at same --out path succeeds after prior failure"
  else
    fail "retry at same --out path succeeds after prior failure" "$(cat "$WORK/s2b.err")"
  fi
}

# ---------------------------------------------------------------------------
# 3. A surviving lowercase/numeric {{placeholder}} fails loudly and is named.
# ---------------------------------------------------------------------------
section_broad_survivor_guard() {
  local demo values out badtemplates
  demo="$WORK/demo3"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values3.json"
  write_full_values "$values" "$demo"

  # Inject a literal {{...}} token that isn't a known ALL_CAPS placeholder, so
  # it is never a key in values.json and always survives interpolation
  # verbatim — the old [A-Z_]-only guard would miss this.
  badtemplates="$WORK/bad-templates-3"
  rm -rf "$badtemplates"
  cp -r "$REAL_TEMPLATES" "$badtemplates"
  printf '\n{{leftover_token42}}\n' >> "$badtemplates/README.md.tmpl"

  out="$WORK/out3"
  if bash "$SCAFFOLD" --values "$values" --out "$out" --templates "$badtemplates" >"$WORK/s3.out" 2>"$WORK/s3.err"; then
    fail "lowercase/numeric survivor makes scaffold exit non-zero" "unexpectedly succeeded"
  else
    ok "lowercase/numeric survivor makes scaffold exit non-zero"
  fi

  grep -q 'leftover_token42' "$WORK/s3.err" && ok "failure output names the surviving token" \
    || fail "failure output names the surviving token" "$(cat "$WORK/s3.err")"

  [[ -e "$out" ]] && fail "no partial --out dir left behind (broad-guard case)" "found: $out" \
    || ok "no partial --out dir left behind (broad-guard case)"
}

# ---------------------------------------------------------------------------
# 4. A hostile REPOS_JSON that renders invalid JSON aborts scaffold with no
#    published --out (H4 — malformed *_JSON values must be caught at scaffold
#    time, not shipped for campaign runtime to trip over).
# ---------------------------------------------------------------------------
section_invalid_json_value() {
  local demo values out
  demo="$WORK/demo4"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values4.json"
  write_full_values "$values" "$demo"
  # Corrupt REPOS_JSON in place so it is well-formed *string* JSON (a valid
  # values.json entry) but its *value*, once dropped raw into config.json.tmpl,
  # is not valid JSON: an unterminated array.
  python3 - "$values" <<'PY'
import json, sys
p = sys.argv[1]
v = json.load(open(p))
v["REPOS_JSON"] = '[{"name": "demo", "path": "x", "mainline": "main"'  # missing closes
json.dump(v, open(p, "w"))
PY

  out="$WORK/out4"
  if bash "$SCAFFOLD" --values "$values" --out "$out" >"$WORK/s4.out" 2>"$WORK/s4.err"; then
    fail "hostile REPOS_JSON makes scaffold exit non-zero" "unexpectedly succeeded"
  else
    ok "hostile REPOS_JSON makes scaffold exit non-zero"
  fi

  grep -qi 'json' "$WORK/s4.err" && ok "failure output names the JSON parse error" \
    || fail "failure output names the JSON parse error" "$(cat "$WORK/s4.err")"

  [[ -e "$out" ]] && fail "no --out published for invalid rendered JSON" "found: $out" \
    || ok "no --out published for invalid rendered JSON"
}

# ---------------------------------------------------------------------------
# 5. Publishing when $OUT already exists as a dir does not nest the temp
#    inside it, and aborts cleanly (H5 — mv-into-existing-dir race).
# ---------------------------------------------------------------------------
section_publish_race() {
  local demo values out
  demo="$WORK/demo5"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values5.json"
  write_full_values "$values" "$demo"

  out="$WORK/out5"
  # Simulate a race: $OUT is created by "another process" before scaffold's
  # own `mkdir "$OUT"` reservation runs. We approximate this by simply
  # pre-creating a non-empty $OUT and confirming the reservation refuses it.
  mkdir -p "$out"
  touch "$out/sentinel"

  if bash "$SCAFFOLD" --values "$values" --out "$out" >"$WORK/s5.out" 2>"$WORK/s5.err"; then
    fail "scaffold refuses to publish into a pre-existing --out" "unexpectedly succeeded"
  else
    ok "scaffold refuses to publish into a pre-existing --out"
  fi

  [[ -e "$out/sentinel" && ! -e "$out/.pm" ]] && \
    ok "pre-existing --out is untouched (no nested temp dir published inside it)" \
    || fail "pre-existing --out is untouched (no nested temp dir published inside it)" \
      "$(ls -la "$out" 2>&1)"

  local stray
  stray="$(find "$WORK" -maxdepth 1 -name '.scaffold-tmp.*' | wc -l | tr -d ' ')"
  [[ "$stray" == "0" ]] && ok "no stray .scaffold-tmp.* dirs left after publish race" \
    || fail "no stray .scaffold-tmp.* dirs left after publish race" "found $stray"
}

# ---------------------------------------------------------------------------
# 5b. Publishing when $OUT already exists as an EMPTY dir must also abort —
#     on GNU mv, `mv -T src dst` into an existing *empty* directory silently
#     succeeds and replaces it, so the empty case needs its own coverage
#     beyond 5's non-empty case (H5 round-6 repro — must now fail closed).
# ---------------------------------------------------------------------------
section_publish_race_empty_dir() {
  local demo values out
  demo="$WORK/demo5b"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values5b.json"
  write_full_values "$values" "$demo"

  out="$WORK/out5b"
  # Pre-existing --out with NOTHING in it: the case a plain `[[ -e "$OUT" ]]`
  # guard cannot distinguish from "safe to mv -T into".
  mkdir -p "$out"

  if bash "$SCAFFOLD" --values "$values" --out "$out" >"$WORK/s5b.out" 2>"$WORK/s5b.err"; then
    fail "scaffold refuses to publish into a pre-existing EMPTY --out" "unexpectedly succeeded"
  else
    ok "scaffold refuses to publish into a pre-existing EMPTY --out"
  fi

  [[ -d "$out" && ! -e "$out/.pm" ]] && \
    ok "pre-existing empty --out is not replaced/clobbered" \
    || fail "pre-existing empty --out is not replaced/clobbered" "$(ls -la "$out" 2>&1)"

  local stray
  stray="$(find "$WORK" -maxdepth 1 -name '.scaffold-tmp.*' | wc -l | tr -d ' ')"
  [[ "$stray" == "0" ]] && ok "no stray .scaffold-tmp.* dirs left after empty-dir publish race" \
    || fail "no stray .scaffold-tmp.* dirs left after empty-dir publish race" "found $stray"
}

# ---------------------------------------------------------------------------
# 5c. A clean publish (no pre-existing --out at all) still succeeds and
#     produces the full tree — regression guard for the mkdir-reservation
#     change replacing the old `[[ -e "$OUT" ]]` upfront guard.
# ---------------------------------------------------------------------------
section_clean_publish() {
  local demo values out
  demo="$WORK/demo5c"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values5c.json"
  write_full_values "$values" "$demo"

  out="$WORK/out5c"
  if bash "$SCAFFOLD" --values "$values" --out "$out" >"$WORK/s5c.out" 2>"$WORK/s5c.err"; then
    ok "clean publish (no pre-existing --out) succeeds"
  else
    fail "clean publish (no pre-existing --out) succeeds" "$(cat "$WORK/s5c.err")"
    return
  fi

  [[ -f "$out/.pm/config.json" && -f "$out/.pm/events.log" && -d "$out/bin" ]] && \
    ok "clean publish produces the full tree" \
    || fail "clean publish produces the full tree" "$(ls -la "$out" 2>&1)"

  [[ -d "$out/prompts" && -d "$out/messages" && -d "$out/reports" ]] && \
    ok "clean publish creates prompts/, messages/, and reports/" \
    || fail "clean publish creates prompts/, messages/, and reports/" "$(ls -la "$out" 2>&1)"

  [[ -d "$out/archive/messages" && -d "$out/archive/prompts" ]] && \
    ok "clean publish creates archive/messages/ and archive/prompts/" \
    || fail "clean publish creates archive/messages/ and archive/prompts/" "$(ls -la "$out/archive" 2>&1)"

  [[ -x "$out/bin/close" ]] && \
    ok "bin/close is copied and executable" \
    || fail "bin/close is copied and executable" "$(ls -la "$out/bin" 2>&1)"

  [[ -x "$out/bin/track" ]] && \
    ok "bin/track is copied and executable" \
    || fail "bin/track is copied and executable" "$(ls -la "$out/bin" 2>&1)"

  [[ -f "$out/TRACKER.md" ]] && \
    ok "TRACKER.md is rendered from the tmpl" \
    || fail "TRACKER.md is rendered from the tmpl" "$(ls -la "$out" 2>&1)"

  grep -q 'GENERATED:BEGIN tracker' "$out/TRACKER.md" 2>/dev/null && \
    grep -q 'GENERATED:END tracker' "$out/TRACKER.md" 2>/dev/null && \
    ok "TRACKER.md has the tracker GENERATED markers" \
    || fail "TRACKER.md has the tracker GENERATED markers" "$(cat "$out/TRACKER.md" 2>&1)"

  grep -qE '\{\{[A-Z_]+\}\}' "$out/TRACKER.md" 2>/dev/null && \
    fail "TRACKER.md has no unresolved {{PLACEHOLDER}}" "$(grep -E '\{\{[A-Z_]+\}\}' "$out/TRACKER.md")" \
    || ok "TRACKER.md has no unresolved {{PLACEHOLDER}}"
}

# ---------------------------------------------------------------------------
# 6. A SIGTERM mid-run leaves no .scaffold-tmp.* dir behind (M6 — cleanup
#    trap must also fire on INT/TERM, not just EXIT).
# ---------------------------------------------------------------------------
section_signal_cleanup() {
  local demo values out badtemplates
  demo="$WORK/demo6"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values6.json"
  write_full_values "$values" "$demo"

  # A templates tree with many files so the python interpolation pass takes
  # long enough to reliably catch it mid-run with a signal.
  badtemplates="$WORK/slow-templates"
  rm -rf "$badtemplates"
  cp -r "$REAL_TEMPLATES" "$badtemplates"
  local i
  for i in $(seq 1 200); do
    cp "$badtemplates/README.md.tmpl" "$badtemplates/README.md.tmpl.pad$i" 2>/dev/null || true
  done
  # Only *.tmpl files are interpolated by name pattern (out_path handles
  # README.md.tmpl); the padN copies aren't matched by out_path but are still
  # walked, so they merely add I/O without changing rendered output shape —
  # sufficient to slow the run down for the race window.

  out="$WORK/out6"
  bash "$SCAFFOLD" --values "$values" --out "$out" --templates "$badtemplates" \
    >"$WORK/s6.out" 2>"$WORK/s6.err" &
  local pid=$!
  sleep 0.05
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null

  local stray
  stray="$(find "$WORK" -maxdepth 1 -name '.scaffold-tmp.*' | wc -l | tr -d ' ')"
  [[ "$stray" == "0" ]] && ok "SIGTERM mid-scaffold leaves no .scaffold-tmp.* dir" \
    || fail "SIGTERM mid-scaffold leaves no .scaffold-tmp.* dir" "found $stray"

  [[ -e "$out" ]] && fail "SIGTERM mid-scaffold leaves no partial --out" "found: $out" \
    || ok "SIGTERM mid-scaffold leaves no partial --out"
}

# ---------------------------------------------------------------------------
# 7. A multi-line {{place\nholder}} in a template is caught and fails the
#    scaffold (M7 — the survivor guard must scan full file content, not just
#    line-by-line, since grep alone misses a token split across a newline).
# ---------------------------------------------------------------------------
section_multiline_survivor() {
  local demo values out badtemplates
  demo="$WORK/demo7"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values7.json"
  write_full_values "$values" "$demo"

  badtemplates="$WORK/bad-templates-7"
  rm -rf "$badtemplates"
  cp -r "$REAL_TEMPLATES" "$badtemplates"
  printf '\n{{multiline\nplaceholder}}\n' >> "$badtemplates/README.md.tmpl"

  out="$WORK/out7"
  if bash "$SCAFFOLD" --values "$values" --out "$out" --templates "$badtemplates" >"$WORK/s7.out" 2>"$WORK/s7.err"; then
    fail "multi-line {{...}} survivor makes scaffold exit non-zero" "unexpectedly succeeded"
  else
    ok "multi-line {{...}} survivor makes scaffold exit non-zero"
  fi

  grep -q 'multiline' "$WORK/s7.err" && ok "failure output names the multi-line surviving token" \
    || fail "failure output names the multi-line surviving token" "$(cat "$WORK/s7.err")"

  [[ -e "$out" ]] && fail "no partial --out dir left behind (multi-line guard case)" "found: $out" \
    || ok "no partial --out dir left behind (multi-line guard case)"
}

echo "== JSON escaping of hostile values =="
section_json_escaping
echo "== no partial dir left on forced failure =="
section_no_partial_dir
echo "== broad {{...}} survivor guard =="
section_broad_survivor_guard
echo "== hostile _JSON value fails to parse (H4) =="
section_invalid_json_value
echo "== publish race: pre-existing --out is not nested into (H5) =="
section_publish_race
echo "== publish race: pre-existing EMPTY --out is not clobbered (H5 empty-dir) =="
section_publish_race_empty_dir
echo "== clean publish with no pre-existing --out still succeeds =="
section_clean_publish
echo "== SIGTERM mid-scaffold cleans up temp dir (M6) =="
section_signal_cleanup
echo "== multi-line {{...}} survivor guard (M7) =="
section_multiline_survivor

echo
echo "-----------------------------------------"
echo "PASS: $PASS  FAIL: $FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  echo "Failed:"
  for n in "${FAILED_NAMES[@]}"; do
    echo "  - $n"
  done
  exit 1
fi
exit 0
