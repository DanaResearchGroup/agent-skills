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
  "STRATEGY_PATH_MD": "Ship the hostile-op integration end to end.",
  "STRATEGY_MILESTONES_MD": "- [ ] M1: scaffold the demo repo\n- [ ] M2: ship it",
  "STRATEGY_WORKPLAN_MD": "1. Scaffold demo\n2. Wire CI",
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
  "REPOS_JSON": json.dumps([{
    "name": "demo", "path": demo, "mainline": "main",
    "mainline_ref": "refs/heads/main", "fetch_policy": "local-only",
  }]),
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

  # B2.0b: automation.auto_close defaults OFF (literal in the template, not
  # operator-required) and the per-repo full mainline_ref + fetch_policy
  # (opaque REPOS_JSON pass-through) render intact, valid JSON.
  local auto_close
  auto_close="$(python3 -c "import json; print(json.load(open('$out/.pm/config.json'))['automation']['auto_close'])")"
  [[ "$auto_close" == "False" ]] && ok "config.json automation.auto_close defaults to false" \
    || fail "config.json automation.auto_close defaults to false" "got [$auto_close]"

  local mainline_ref fetch_policy
  mainline_ref="$(python3 -c "import json; print(json.load(open('$out/.pm/config.json'))['repos'][0]['mainline_ref'])")"
  fetch_policy="$(python3 -c "import json; print(json.load(open('$out/.pm/config.json'))['repos'][0]['fetch_policy'])")"
  [[ "$mainline_ref" == "refs/heads/main" ]] && \
    ok "config.json repos[0].mainline_ref == refs/heads/main (full ref, never short 'main')" \
    || fail "config.json repos[0].mainline_ref == refs/heads/main (full ref, never short 'main')" "got [$mainline_ref]"
  [[ "$fetch_policy" == "local-only" ]] && ok "config.json repos[0].fetch_policy == local-only" \
    || fail "config.json repos[0].fetch_policy == local-only" "got [$fetch_policy]"
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

  [[ -f "$out/STRATEGY.md" ]] && \
    ok "STRATEGY.md is rendered from the tmpl" \
    || fail "STRATEGY.md is rendered from the tmpl" "$(ls -la "$out" 2>&1)"

  grep -q 'Ship the hostile-op integration end to end.' "$out/STRATEGY.md" 2>/dev/null && \
    grep -q 'M1: scaffold the demo repo' "$out/STRATEGY.md" 2>/dev/null && \
    grep -q 'Wire CI' "$out/STRATEGY.md" 2>/dev/null && \
    ok "STRATEGY.md contains the interpolated path/milestones/workplan content" \
    || fail "STRATEGY.md contains the interpolated path/milestones/workplan content" "$(cat "$out/STRATEGY.md" 2>&1)"

  grep -qE '\{\{[A-Z_]+\}\}' "$out/STRATEGY.md" 2>/dev/null && \
    fail "STRATEGY.md has no unresolved {{PLACEHOLDER}}" "$(grep -E '\{\{[A-Z_]+\}\}' "$out/STRATEGY.md")" \
    || ok "STRATEGY.md has no unresolved {{PLACEHOLDER}}"
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

# ---------------------------------------------------------------------------
# 8. B2.0b config completeness: a REPOS_JSON repo with only the legacy
#    {name, path, mainline} shape (no mainline_ref/fetch_policy at all) must
#    have scaffold DERIVE the full mainline_ref + a default fetch_policy --
#    config must be complete-by-construction, not pass-through.
# ---------------------------------------------------------------------------
section_repos_derive_default() {
  local demo values out
  demo="$WORK/demo8"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values8.json"
  write_full_values "$values" "$demo"
  # Strip mainline_ref/fetch_policy back to the legacy minimal shape.
  python3 - "$values" "$demo" <<'PY'
import json, sys
p, demo = sys.argv[1], sys.argv[2]
v = json.load(open(p))
v["REPOS_JSON"] = json.dumps([{"name": "demo", "path": demo, "mainline": "main"}])
json.dump(v, open(p, "w"))
PY

  out="$WORK/out8"
  if bash "$SCAFFOLD" --values "$values" --out "$out" >"$WORK/s8.out" 2>"$WORK/s8.err"; then
    ok "legacy {name,path,mainline}-only REPOS_JSON still scaffolds successfully"
  else
    fail "legacy {name,path,mainline}-only REPOS_JSON still scaffolds successfully" "$(cat "$WORK/s8.err")"
  fi

  local mainline_ref fetch_policy
  mainline_ref="$(python3 -c "import json; print(json.load(open('$out/.pm/config.json'))['repos'][0]['mainline_ref'])" 2>/dev/null)"
  fetch_policy="$(python3 -c "import json; print(json.load(open('$out/.pm/config.json'))['repos'][0]['fetch_policy'])" 2>/dev/null)"
  [[ "$mainline_ref" == "refs/remotes/origin/main" ]] && \
    ok "config.json repos[0].mainline_ref derived as refs/remotes/origin/main when absent" \
    || fail "config.json repos[0].mainline_ref derived as refs/remotes/origin/main when absent" "got [$mainline_ref]"
  [[ "$fetch_policy" == "fetch" ]] && ok "config.json repos[0].fetch_policy defaults to fetch when absent" \
    || fail "config.json repos[0].fetch_policy defaults to fetch when absent" "got [$fetch_policy]"

  python3 -c "import json; json.load(open('$out/.pm/config.json'))" 2>"$WORK/s8.parse.err" \
    && ok "config.json still valid JSON with derived repo fields" \
    || fail "config.json still valid JSON with derived repo fields" "$(cat "$WORK/s8.parse.err")"
}

# ---------------------------------------------------------------------------
# 9. An operator-supplied full mainline_ref (differing from a naive
#    derivation, so a stale/pass-through implementation could not fake this)
#    must be preserved verbatim, never recomputed from `mainline`.
# ---------------------------------------------------------------------------
section_repos_preserve_explicit_ref() {
  local demo values out
  demo="$WORK/demo9"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values9.json"
  write_full_values "$values" "$demo"
  python3 - "$values" "$demo" <<'PY'
import json, sys
p, demo = sys.argv[1], sys.argv[2]
v = json.load(open(p))
# mainline says "main" but the operator supplies an explicit full ref that
# points at a *different* branch (refs/heads/release) -- proves this is
# preserved verbatim and NOT recomputed as refs/remotes/origin/main.
v["REPOS_JSON"] = json.dumps([{
    "name": "demo", "path": demo, "mainline": "main",
    "mainline_ref": "refs/heads/release",
}])
json.dump(v, open(p, "w"))
PY

  out="$WORK/out9"
  bash "$SCAFFOLD" --values "$values" --out "$out" >"$WORK/s9.out" 2>"$WORK/s9.err"

  local mainline_ref fetch_policy
  mainline_ref="$(python3 -c "import json; print(json.load(open('$out/.pm/config.json'))['repos'][0]['mainline_ref'])" 2>/dev/null)"
  fetch_policy="$(python3 -c "import json; print(json.load(open('$out/.pm/config.json'))['repos'][0]['fetch_policy'])" 2>/dev/null)"
  [[ "$mainline_ref" == "refs/heads/release" ]] && \
    ok "explicit repos[0].mainline_ref preserved verbatim, not recomputed from mainline" \
    || fail "explicit repos[0].mainline_ref preserved verbatim, not recomputed from mainline" "got [$mainline_ref]"
  [[ "$fetch_policy" == "local-only" ]] && \
    ok "fetch_policy defaults to local-only for a refs/heads/* ref when unsupplied" \
    || fail "fetch_policy defaults to local-only for a refs/heads/* ref when unsupplied" "got [$fetch_policy]"
}

# ---------------------------------------------------------------------------
# 10. A repo missing 'mainline' entirely cannot have a ref derived -- scaffold
#     must FAIL LOUD (nonzero exit, clear error) with no partial --out left.
# ---------------------------------------------------------------------------
section_repos_missing_mainline_fails() {
  local demo values out
  demo="$WORK/demo10"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values10.json"
  write_full_values "$values" "$demo"
  python3 - "$values" "$demo" <<'PY'
import json, sys
p, demo = sys.argv[1], sys.argv[2]
v = json.load(open(p))
v["REPOS_JSON"] = json.dumps([{"name": "demo", "path": demo}])  # no mainline at all
json.dump(v, open(p, "w"))
PY

  out="$WORK/out10"
  if bash "$SCAFFOLD" --values "$values" --out "$out" >"$WORK/s10.out" 2>"$WORK/s10.err"; then
    fail "repo missing 'mainline' makes scaffold exit non-zero" "unexpectedly succeeded"
  else
    ok "repo missing 'mainline' makes scaffold exit non-zero"
  fi

  grep -qi "mainline" "$WORK/s10.err" && ok "failure output names the missing 'mainline' field" \
    || fail "failure output names the missing 'mainline' field" "$(cat "$WORK/s10.err")"

  [[ -e "$out" ]] && fail "no partial --out dir left behind (missing mainline case)" "found: $out" \
    || ok "no partial --out dir left behind (missing mainline case)"
}

# ---------------------------------------------------------------------------
# 11. A short/unqualified mainline_ref (e.g. "main", no refs/ prefix) is
#     exactly the short-`main` trap B2.0b exists to prevent -- scaffold must
#     FAIL LOUD rather than silently guess, with no partial --out left.
# ---------------------------------------------------------------------------
section_repos_short_mainline_ref_fails() {
  local demo values out
  demo="$WORK/demo11"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values11.json"
  write_full_values "$values" "$demo"
  python3 - "$values" "$demo" <<'PY'
import json, sys
p, demo = sys.argv[1], sys.argv[2]
v = json.load(open(p))
v["REPOS_JSON"] = json.dumps([{"name": "demo", "path": demo, "mainline": "main", "mainline_ref": "main"}])
json.dump(v, open(p, "w"))
PY

  out="$WORK/out11"
  if bash "$SCAFFOLD" --values "$values" --out "$out" >"$WORK/s11.out" 2>"$WORK/s11.err"; then
    fail "short mainline_ref='main' makes scaffold exit non-zero" "unexpectedly succeeded"
  else
    ok "short mainline_ref='main' makes scaffold exit non-zero"
  fi

  grep -qi "mainline_ref" "$WORK/s11.err" && ok "failure output names the short mainline_ref" \
    || fail "failure output names the short mainline_ref" "$(cat "$WORK/s11.err")"

  [[ -e "$out" ]] && fail "no partial --out dir left behind (short mainline_ref case)" "found: $out" \
    || ok "no partial --out dir left behind (short mainline_ref case)"
}

# ---------------------------------------------------------------------------
# 12. Round-21 Low hardening: a non-string REPOS_JSON value (e.g. a JSON
#     number) must clean-fail (sys.exit(3) + message), not raise an
#     uncaught TypeError out of the scaffold's python heredoc.
# ---------------------------------------------------------------------------
section_repos_json_non_string_fails() {
  local demo values out
  demo="$WORK/demo12"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values12.json"
  write_full_values "$values" "$demo"
  python3 - "$values" <<'PY'
import json, sys
p = sys.argv[1]
v = json.load(open(p))
v["REPOS_JSON"] = 42  # not a string at all
json.dump(v, open(p, "w"))
PY

  out="$WORK/out12"
  if bash "$SCAFFOLD" --values "$values" --out "$out" >"$WORK/s12.out" 2>"$WORK/s12.err"; then
    fail "non-string REPOS_JSON makes scaffold exit non-zero" "unexpectedly succeeded"
  else
    ok "non-string REPOS_JSON makes scaffold exit non-zero"
  fi

  grep -qi "traceback" "$WORK/s12.err" && fail "non-string REPOS_JSON fails cleanly (no Python traceback)" \
    "$(cat "$WORK/s12.err")" \
    || ok "non-string REPOS_JSON fails cleanly (no Python traceback)"

  grep -qi "REPOS_JSON" "$WORK/s12.err" && ok "failure output names REPOS_JSON" \
    || fail "failure output names REPOS_JSON" "$(cat "$WORK/s12.err")"

  [[ -e "$out" ]] && fail "no partial --out dir left behind (non-string REPOS_JSON case)" "found: $out" \
    || ok "no partial --out dir left behind (non-string REPOS_JSON case)"
}

# ---------------------------------------------------------------------------
# 13. Round-21 Low hardening: a truthy non-string 'mainline' (e.g. ["main"])
#     must fail loud, not get silently stringified into a bogus
#     full-looking ref like refs/remotes/origin/['main'].
# ---------------------------------------------------------------------------
section_repos_mainline_non_string_fails() {
  local demo values out
  demo="$WORK/demo13"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values13.json"
  write_full_values "$values" "$demo"
  python3 - "$values" "$demo" <<'PY'
import json, sys
p, demo = sys.argv[1], sys.argv[2]
v = json.load(open(p))
v["REPOS_JSON"] = json.dumps([{"name": "demo", "path": demo, "mainline": ["main"]}])
json.dump(v, open(p, "w"))
PY

  out="$WORK/out13"
  if bash "$SCAFFOLD" --values "$values" --out "$out" >"$WORK/s13.out" 2>"$WORK/s13.err"; then
    fail "non-string 'mainline' makes scaffold exit non-zero" "unexpectedly succeeded"
  else
    ok "non-string 'mainline' makes scaffold exit non-zero"
  fi

  grep -qi "mainline" "$WORK/s13.err" && ok "failure output names 'mainline'" \
    || fail "failure output names 'mainline'" "$(cat "$WORK/s13.err")"

  [[ -e "$out" ]] && fail "no partial --out dir left behind (non-string mainline case)" "found: $out" \
    || ok "no partial --out dir left behind (non-string mainline case)"
}

# ---------------------------------------------------------------------------
# 14. Round-21 Low hardening: a non-string explicit 'mainline_ref' (e.g. a
#     number) must fail loud, not raise AttributeError out of `.startswith`.
# ---------------------------------------------------------------------------
section_repos_mainline_ref_non_string_fails() {
  local demo values out
  demo="$WORK/demo14"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values14.json"
  write_full_values "$values" "$demo"
  python3 - "$values" "$demo" <<'PY'
import json, sys
p, demo = sys.argv[1], sys.argv[2]
v = json.load(open(p))
v["REPOS_JSON"] = json.dumps([{"name": "demo", "path": demo, "mainline": "main", "mainline_ref": 7}])
json.dump(v, open(p, "w"))
PY

  out="$WORK/out14"
  if bash "$SCAFFOLD" --values "$values" --out "$out" >"$WORK/s14.out" 2>"$WORK/s14.err"; then
    fail "non-string 'mainline_ref' makes scaffold exit non-zero" "unexpectedly succeeded"
  else
    ok "non-string 'mainline_ref' makes scaffold exit non-zero"
  fi

  grep -qi "traceback" "$WORK/s14.err" && fail "non-string mainline_ref fails cleanly (no Python traceback)" \
    "$(cat "$WORK/s14.err")" \
    || ok "non-string mainline_ref fails cleanly (no Python traceback)"

  grep -qi "mainline_ref" "$WORK/s14.err" && ok "failure output names 'mainline_ref'" \
    || fail "failure output names 'mainline_ref'" "$(cat "$WORK/s14.err")"

  [[ -e "$out" ]] && fail "no partial --out dir left behind (non-string mainline_ref case)" "found: $out" \
    || ok "no partial --out dir left behind (non-string mainline_ref case)"
}

# ---------------------------------------------------------------------------
# 15. Round-21 Low hardening: an explicit fetch_policy outside the
#     {fetch, local-only} enum must fail loud at scaffold time (cheap
#     scaffold-side guard -- deeper runtime enforcement stays B2.1's job).
# ---------------------------------------------------------------------------
section_repos_bad_fetch_policy_fails() {
  local demo values out
  demo="$WORK/demo15"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values15.json"
  write_full_values "$values" "$demo"
  python3 - "$values" "$demo" <<'PY'
import json, sys
p, demo = sys.argv[1], sys.argv[2]
v = json.load(open(p))
v["REPOS_JSON"] = json.dumps([{
    "name": "demo", "path": demo, "mainline": "main",
    "mainline_ref": "refs/heads/main", "fetch_policy": "sometimes",
}])
json.dump(v, open(p, "w"))
PY

  out="$WORK/out15"
  if bash "$SCAFFOLD" --values "$values" --out "$out" >"$WORK/s15.out" 2>"$WORK/s15.err"; then
    fail "fetch_policy='sometimes' makes scaffold exit non-zero" "unexpectedly succeeded"
  else
    ok "fetch_policy='sometimes' makes scaffold exit non-zero"
  fi

  grep -qi "fetch_policy" "$WORK/s15.err" && ok "failure output names 'fetch_policy'" \
    || fail "failure output names 'fetch_policy'" "$(cat "$WORK/s15.err")"

  [[ -e "$out" ]] && fail "no partial --out dir left behind (bad fetch_policy case)" "found: $out" \
    || ok "no partial --out dir left behind (bad fetch_policy case)"
}

# ---------------------------------------------------------------------------
# 15b. B2.2: per-repo merge_mode + allow_marker_branch_deleted are
#      normalized at scaffold time -- defaults ("merge" / false) added when
#      absent (config complete-by-construction), explicit valid values
#      preserved, invalid enum/type FAIL LOUD with no partial --out.
# ---------------------------------------------------------------------------
section_repos_merge_mode_defaults() {
  local demo values out
  demo="$WORK/demo15b"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values15b.json"
  write_full_values "$values" "$demo"
  # legacy minimal shape: no merge_mode / allow_marker_branch_deleted at all
  python3 - "$values" "$demo" <<'PY'
import json, sys
p, demo = sys.argv[1], sys.argv[2]
v = json.load(open(p))
v["REPOS_JSON"] = json.dumps([{"name": "demo", "path": demo, "mainline": "main"}])
json.dump(v, open(p, "w"))
PY

  out="$WORK/out15b"
  bash "$SCAFFOLD" --values "$values" --out "$out" >"$WORK/s15b.out" 2>"$WORK/s15b.err" \
    || fail "merge_mode defaults: scaffold succeeds on legacy shape" "$(cat "$WORK/s15b.err")"

  local merge_mode allow_deleted
  merge_mode="$(python3 -c "import json; print(json.load(open('$out/.pm/config.json'))['repos'][0]['merge_mode'])" 2>/dev/null)"
  allow_deleted="$(python3 -c "import json; print(json.load(open('$out/.pm/config.json'))['repos'][0]['allow_marker_branch_deleted'])" 2>/dev/null)"
  [[ "$merge_mode" == "merge" ]] && ok "config.json repos[0].merge_mode defaults to 'merge'" \
    || fail "config.json repos[0].merge_mode defaults to 'merge'" "got [$merge_mode]"
  [[ "$allow_deleted" == "False" ]] && ok "config.json repos[0].allow_marker_branch_deleted defaults to false" \
    || fail "config.json repos[0].allow_marker_branch_deleted defaults to false" "got [$allow_deleted]"
}

section_repos_merge_mode_explicit_squash() {
  local demo values out
  demo="$WORK/demo15c"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values15c.json"
  write_full_values "$values" "$demo"
  python3 - "$values" "$demo" <<'PY'
import json, sys
p, demo = sys.argv[1], sys.argv[2]
v = json.load(open(p))
v["REPOS_JSON"] = json.dumps([{
    "name": "demo", "path": demo, "mainline": "main",
    "mainline_ref": "refs/heads/main", "fetch_policy": "local-only",
    "merge_mode": "squash", "allow_marker_branch_deleted": True,
}])
json.dump(v, open(p, "w"))
PY

  out="$WORK/out15c"
  bash "$SCAFFOLD" --values "$values" --out "$out" >"$WORK/s15c.out" 2>"$WORK/s15c.err" \
    || fail "merge_mode explicit: scaffold succeeds" "$(cat "$WORK/s15c.err")"

  local merge_mode allow_deleted
  merge_mode="$(python3 -c "import json; print(json.load(open('$out/.pm/config.json'))['repos'][0]['merge_mode'])" 2>/dev/null)"
  allow_deleted="$(python3 -c "import json; print(json.load(open('$out/.pm/config.json'))['repos'][0]['allow_marker_branch_deleted'])" 2>/dev/null)"
  [[ "$merge_mode" == "squash" ]] && ok "explicit merge_mode='squash' preserved verbatim" \
    || fail "explicit merge_mode='squash' preserved verbatim" "got [$merge_mode]"
  [[ "$allow_deleted" == "True" ]] && ok "explicit allow_marker_branch_deleted=true preserved verbatim" \
    || fail "explicit allow_marker_branch_deleted=true preserved verbatim" "got [$allow_deleted]"
}

section_repos_bad_merge_mode_fails() {
  local demo values out
  demo="$WORK/demo15d"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values15d.json"
  write_full_values "$values" "$demo"
  python3 - "$values" "$demo" <<'PY'
import json, sys
p, demo = sys.argv[1], sys.argv[2]
v = json.load(open(p))
v["REPOS_JSON"] = json.dumps([{
    "name": "demo", "path": demo, "mainline": "main",
    "mainline_ref": "refs/heads/main", "fetch_policy": "local-only",
    "merge_mode": "rebase-ff",
}])
json.dump(v, open(p, "w"))
PY

  out="$WORK/out15d"
  if bash "$SCAFFOLD" --values "$values" --out "$out" >"$WORK/s15d.out" 2>"$WORK/s15d.err"; then
    fail "merge_mode='rebase-ff' makes scaffold exit non-zero" "unexpectedly succeeded"
  else
    ok "merge_mode='rebase-ff' makes scaffold exit non-zero"
  fi
  grep -qi "merge_mode" "$WORK/s15d.err" && ok "failure output names 'merge_mode'" \
    || fail "failure output names 'merge_mode'" "$(cat "$WORK/s15d.err")"
  [[ -e "$out" ]] && fail "no partial --out dir left behind (bad merge_mode case)" "found: $out" \
    || ok "no partial --out dir left behind (bad merge_mode case)"
}

section_repos_bad_allow_marker_fails() {
  local demo values out
  demo="$WORK/demo15e"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values15e.json"
  write_full_values "$values" "$demo"
  python3 - "$values" "$demo" <<'PY'
import json, sys
p, demo = sys.argv[1], sys.argv[2]
v = json.load(open(p))
v["REPOS_JSON"] = json.dumps([{
    "name": "demo", "path": demo, "mainline": "main",
    "mainline_ref": "refs/heads/main", "fetch_policy": "local-only",
    "allow_marker_branch_deleted": "yes",
}])
json.dump(v, open(p, "w"))
PY

  out="$WORK/out15e"
  if bash "$SCAFFOLD" --values "$values" --out "$out" >"$WORK/s15e.out" 2>"$WORK/s15e.err"; then
    fail "allow_marker_branch_deleted='yes' (string) makes scaffold exit non-zero" "unexpectedly succeeded"
  else
    ok "allow_marker_branch_deleted='yes' (string) makes scaffold exit non-zero"
  fi
  grep -qi "allow_marker_branch_deleted" "$WORK/s15e.err" && ok "failure output names 'allow_marker_branch_deleted'" \
    || fail "failure output names 'allow_marker_branch_deleted'" "$(cat "$WORK/s15e.err")"
  [[ -e "$out" ]] && fail "no partial --out dir left behind (bad allow_marker case)" "found: $out" \
    || ok "no partial --out dir left behind (bad allow_marker case)"
}

section_repos_null_merge_mode_fails() {
  # fix-pass-6 T9 (scaffold half): an EXPLICIT "merge_mode": null is not
  # "absent" -- it fails loud rather than silently defaulting.
  local demo values out
  demo="$WORK/demo15f"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values15f.json"
  write_full_values "$values" "$demo"
  python3 - "$values" "$demo" <<'PY'
import json, sys
p, demo = sys.argv[1], sys.argv[2]
v = json.load(open(p))
v["REPOS_JSON"] = json.dumps([{
    "name": "demo", "path": demo, "mainline": "main",
    "mainline_ref": "refs/heads/main", "fetch_policy": "local-only",
    "merge_mode": None,
}])
json.dump(v, open(p, "w"))
PY

  out="$WORK/out15f"
  if bash "$SCAFFOLD" --values "$values" --out "$out" >"$WORK/s15f.out" 2>"$WORK/s15f.err"; then
    fail "merge_mode=null makes scaffold exit non-zero" "unexpectedly succeeded"
  else
    ok "merge_mode=null makes scaffold exit non-zero"
  fi
  grep -qi "merge_mode" "$WORK/s15f.err" && ok "null-merge_mode failure output names 'merge_mode'" \
    || fail "null-merge_mode failure output names 'merge_mode'" "$(cat "$WORK/s15f.err")"
}

# ---------------------------------------------------------------------------
# 16a. Round-21 Low hardening: a repo whose string field contains hostile
#      content (quotes, backslashes, a control char) must round-trip intact
#      through the repos-normalization re-serialize -- proving json.dumps
#      preserves the hardened escaping guarantee end-to-end.
# ---------------------------------------------------------------------------
section_repos_hostile_field_round_trips() {
  local demo values out
  demo="$WORK/demo16"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values16.json"
  write_full_values "$values" "$demo"
  local hostile_note
  hostile_note=$'quote:" backslash:\\ ctrl:\x01 done'
  python3 - "$values" "$demo" "$hostile_note" <<'PY'
import json, sys
p, demo, note = sys.argv[1], sys.argv[2], sys.argv[3]
v = json.load(open(p))
v["REPOS_JSON"] = json.dumps([{
    "name": "demo", "path": demo, "mainline": "main",
    "mainline_ref": "refs/heads/main", "fetch_policy": "local-only",
    "note": note,
}])
json.dump(v, open(p, "w"))
PY

  out="$WORK/out16"
  if bash "$SCAFFOLD" --values "$values" --out "$out" >"$WORK/s16.out" 2>"$WORK/s16.err"; then
    ok "hostile repo field (quotes/backslash/ctrl char) still scaffolds successfully"
  else
    fail "hostile repo field (quotes/backslash/ctrl char) still scaffolds successfully" "$(cat "$WORK/s16.err")"
  fi

  python3 -c "import json; json.load(open('$out/.pm/config.json'))" 2>"$WORK/s16.parse.err" \
    && ok "config.json remains valid JSON with hostile repo field" \
    || fail "config.json remains valid JSON with hostile repo field" "$(cat "$WORK/s16.parse.err")"

  local got
  got="$(python3 -c "import json; print(json.load(open('$out/.pm/config.json'))['repos'][0]['note'])" 2>/dev/null)"
  [[ "$got" == "$hostile_note" ]] && ok "hostile repo field round-trips byte-for-byte intact" \
    || fail "hostile repo field round-trips byte-for-byte intact" "got [$got]"
}

# ---------------------------------------------------------------------------
# 16b. A {{...}}-shaped literal token sitting inside repo field data (not a
#      real template placeholder) must still be caught by the PRE-EXISTING
#      broad survivor guard (M7 / section_broad_survivor_guard) after
#      passing through the repos-normalization re-serialize -- proving the
#      normalization pass doesn't accidentally smuggle a placeholder-looking
#      token past that guard. (The guard is deliberately broad: no literal
#      {{...}} may ever survive into shipped output, including inside data
#      fields -- this is existing hardened behavior, not something new here.)
# ---------------------------------------------------------------------------
section_repos_field_placeholder_token_still_guarded() {
  local demo values out
  demo="$WORK/demo16b"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values16b.json"
  write_full_values "$values" "$demo"
  python3 - "$values" "$demo" <<'PY'
import json, sys
p, demo = sys.argv[1], sys.argv[2]
v = json.load(open(p))
v["REPOS_JSON"] = json.dumps([{
    "name": "demo", "path": demo, "mainline": "main",
    "mainline_ref": "refs/heads/main", "fetch_policy": "local-only",
    "note": "token:{{FOO}}",
}])
json.dump(v, open(p, "w"))
PY

  out="$WORK/out16b"
  if bash "$SCAFFOLD" --values "$values" --out "$out" >"$WORK/s16b.out" 2>"$WORK/s16b.err"; then
    fail "{{...}}-shaped repo field data trips the broad survivor guard" "unexpectedly succeeded"
  else
    ok "{{...}}-shaped repo field data trips the broad survivor guard"
  fi

  grep -q '{{FOO}}' "$WORK/s16b.err" && ok "failure output names the surviving {{FOO}} token" \
    || fail "failure output names the surviving {{FOO}} token" "$(cat "$WORK/s16b.err")"

  [[ -e "$out" ]] && fail "no partial --out dir left behind ({{...}}-in-repo-field case)" "found: $out" \
    || ok "no partial --out dir left behind ({{...}}-in-repo-field case)"
}

# ---------------------------------------------------------------------------
# 17. STRATEGY.md's placeholders participate in the FAIL-LOUD completeness
#     check like every other placeholder: omitting one aborts scaffold with
#     no partial --out, naming the missing key.
# ---------------------------------------------------------------------------
section_strategy_missing_key_fails() {
  local demo values out
  demo="$WORK/demo17"
  mkdir -p "$demo"
  (cd "$demo" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

  values="$WORK/values17.json"
  write_full_values "$values" "$demo"
  python3 - "$values" <<'PY'
import json, sys
p = sys.argv[1]
v = json.load(open(p))
del v["STRATEGY_WORKPLAN_MD"]
json.dump(v, open(p, "w"))
PY

  out="$WORK/out17"
  if bash "$SCAFFOLD" --values "$values" --out "$out" >"$WORK/s17.out" 2>"$WORK/s17.err"; then
    fail "missing STRATEGY_WORKPLAN_MD makes scaffold exit non-zero" "unexpectedly succeeded"
  else
    ok "missing STRATEGY_WORKPLAN_MD makes scaffold exit non-zero"
  fi

  grep -q 'STRATEGY_WORKPLAN_MD' "$WORK/s17.err" && ok "failure output names the missing STRATEGY_WORKPLAN_MD key" \
    || fail "failure output names the missing STRATEGY_WORKPLAN_MD key" "$(cat "$WORK/s17.err")"

  [[ -e "$out" ]] && fail "no partial --out dir left behind (missing STRATEGY key case)" "found: $out" \
    || ok "no partial --out dir left behind (missing STRATEGY key case)"
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
echo "== B2.0b: legacy repo shape derives full mainline_ref + fetch_policy =="
section_repos_derive_default
echo "== B2.0b: explicit mainline_ref preserved verbatim =="
section_repos_preserve_explicit_ref
echo "== B2.0b: repo missing 'mainline' fails loud, no partial --out =="
section_repos_missing_mainline_fails
echo "== B2.0b: short/unqualified mainline_ref fails loud, no partial --out =="
section_repos_short_mainline_ref_fails
echo "== round-21: non-string REPOS_JSON fails cleanly (no TypeError) =="
section_repos_json_non_string_fails
echo "== round-21: non-string 'mainline' fails loud =="
section_repos_mainline_non_string_fails
echo "== round-21: non-string explicit 'mainline_ref' fails loud (no AttributeError) =="
section_repos_mainline_ref_non_string_fails
echo "== round-21: fetch_policy outside {fetch,local-only} enum fails loud =="
section_repos_bad_fetch_policy_fails
echo "== B2.2: merge_mode/allow_marker_branch_deleted defaults added =="
section_repos_merge_mode_defaults
echo "== B2.2: explicit merge_mode=squash + allow_marker preserved =="
section_repos_merge_mode_explicit_squash
echo "== B2.2: invalid merge_mode fails loud =="
section_repos_bad_merge_mode_fails
echo "== B2.2: non-bool allow_marker_branch_deleted fails loud =="
section_repos_bad_allow_marker_fails
echo "== B2.2 fix-pass-6 T9: explicit merge_mode=null fails loud =="
section_repos_null_merge_mode_fails
echo "== round-21: hostile repo field round-trips through normalization =="
section_repos_hostile_field_round_trips
echo "== round-21: {{...}}-shaped repo field data still trips the broad survivor guard =="
section_repos_field_placeholder_token_still_guarded
echo "== STRATEGY.md: missing new placeholder key fails loud =="
section_strategy_missing_key_fails

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
