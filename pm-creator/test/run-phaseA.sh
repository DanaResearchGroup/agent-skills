#!/usr/bin/env bash
# This harness uses the `cond && ok || bad` assertion idiom throughout; ok/bad always
# return 0, so SC2015's "C may run when A is true" caveat cannot bite here.
# shellcheck disable=SC2015
# run-phaseA.sh — end-to-end integration smoke for the pm-creator Phase-A core.
# Scaffolds a real sample PM repo via scaffold.sh, then drives a full human-lane
# round-trip against a throwaway git repo. Uses a SENTINEL herdr workspace so it
# can never touch a real one. All temp state under $TMPDIR; the worktree is not
# mutated. Exits non-zero on the first failure.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pm-phaseA.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok() { printf 'ok\t%s\n' "$1"; PASS=$((PASS+1)); return 0; }
bad() { printf 'FAIL\t%s\n' "$1"; FAIL=$((FAIL+1)); return 0; }
iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- a throwaway "campaign repo" for reconcile's git probe ---------------------
DEMO="$WORK/demo"
mkdir -p "$DEMO"; ( cd "$DEMO" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )

# --- build a values.json covering every placeholder ---------------------------
VALUES="$WORK/values.json"
DEMO_PATH="$DEMO" python3 - "$VALUES" <<'PY'
import json, os, sys
demo = os.environ["DEMO_PATH"]
v = {
  "CAMPAIGN_NAME": "Phase-A Smoke",
  "CAMPAIGN_SLUG": "smoke",
  "PRIMARY_REPO": "demo",
  "REPO_LIST": "`demo` → `main`",
  "WORKTREE_ROOT": "/tmp/smoke-wt",
  "RUNS_ROOT": "/tmp/smoke-runs",
  "HERDR_WORKSPACE": "zzz-phaseA-smoke",
  "MODEL_ROUTING": "| Sonnet | default worker |\n| Opus | verdicts |",
  "REMOTE_POLICY": "local-only",
  "UPLOAD_POLICY": "none (local-only)",
  "CAPACITY_NOTE": " (single dev box).",
  "OPTIONAL_SLOT_NOTE": ", `RUNS.md`",
  "ALWAYS_HUMAN_GATES": "merges to `main`, any push",
  "HARDWARE_TABLE": "| CPU | test box |",
  "CAPACITY_NOTES": "One generation at a time.",
  "CAPACITY_RULES": "1. Don't stack heavy jobs.",
  "REPOS_JSON": json.dumps([{"name":"demo","path":demo,"mainline":"main"}]),
  "OPTIONAL_SLOTS_JSON": json.dumps({"runs": True, "machine": True}),
}
json.dump(v, open(sys.argv[1], "w"))
PY

# --- 1. scaffold --------------------------------------------------------------
PM="$WORK/smoke-pm"
if bash "$SKILL_DIR/scaffold.sh" --values "$VALUES" --out "$PM" >/dev/null 2>"$WORK/scaffold.err"; then
  ok "scaffold.sh materialized the repo"
else
  bad "scaffold.sh failed: $(cat "$WORK/scaffold.err")"; echo "PASS:$PASS FAIL:$FAIL"; exit 1
fi
grep -rIqE '\{\{[A-Z_]+\}\}' "$PM" && bad "unresolved placeholders remain" || ok "no {{PLACEHOLDER}} left in output"
[ -x "$PM/bin/reconcile" ] && ok "bin/ copied executable" || bad "bin/ not executable"
[ "$(cat "$PM/.pm/events.log")" = "EVENT schema v=1" ] && ok "events.log seeded with header" || bad "events.log header wrong"
( cd "$PM" && git init -q -b main )
export PM_ROOT="$PM"

# --- 2. checks on the fresh repo ----------------------------------------------
( cd "$PM" && bin/ledger-check >/dev/null 2>&1 ) && ok "ledger-check clean on empty log" || bad "ledger-check failed on fresh repo"
( cd "$PM" && bin/reconcile >/dev/null 2>&1 ) && ok "reconcile ran on fresh repo" || bad "reconcile failed on fresh repo"
grep -q "GENERATED:BEGIN worktrees" "$PM/WORKTREES.md" && ok "WORKTREES has worktrees marker" || bad "WORKTREES marker missing"

# --- 3. record an issue (via bin/record) + lint a prompt ----------------------
( cd "$PM" && bin/record issue I-001 ACTIVE >/dev/null 2>&1 ) && ok "record issue I-001 ACTIVE" || bad "record issue failed"

mkdir -p "$PM/prompts"
cat > "$PM/prompts/I-001_demo.md" <<'EOF'
# Dispatch — demo

| Ticket | (operator-facing header) |

## Prompt (paste below this line)

Fix the failing test in `/tmp/smoke-wt/demo` at `src/foo.py:12`. Commit on a branch.
Cite D-001 when you report back so it can be filed.
EOF
( cd "$PM" && bin/lint-prompt prompts/I-001_demo.md >/dev/null 2>&1 ) && ok "lint-prompt passes a clean prompt" || bad "lint-prompt false-rejected a clean prompt"

cat > "$PM/prompts/leaky.md" <<'EOF'
## Prompt (paste below this line)
See I-005 and the tab i005-fix; the ledger tracks the rest.
EOF
( cd "$PM" && bin/lint-prompt prompts/leaky.md >/dev/null 2>&1 ) && bad "lint-prompt missed a leak" || ok "lint-prompt catches a leaked I-005/tab"

# --- 4. dispatch round-trip (human lane) --------------------------------------
if ( cd "$PM" && bin/dispatch-prep --dispatch D-001 --issue I-001 --prompt prompts/I-001_demo.md --tab i001-demo --repo demo >/dev/null 2>&1 ); then
  ok "dispatch-prep emitted dispatch_new + DISPATCHED"
else
  bad "dispatch-prep failed"
fi
# herdr must NOT have been spawned (dispatch-prep only prints)
if command -v herdr >/dev/null 2>&1; then
  herdr tab list --workspace zzz-phaseA-smoke 2>/dev/null | grep -q i001-demo && bad "dispatch-prep spawned a real herdr tab!" || ok "dispatch-prep did not spawn herdr (print-only)"
fi

# simulate the worker returning, driven through bin/record (auto from=/at=), per grammar §6
( cd "$PM" && bin/record dispatch D-001 ACKED --tab zzz-t1 >/dev/null 2>&1 ) && ok "record ACKED" || bad "record ACKED failed"
( cd "$PM" && bin/record result D-001 RETURNED --sha deadbeef >/dev/null 2>&1 ) && ok "record result RETURNED" || bad "record result failed"
( cd "$PM" && bin/record dispatch D-001 VERIFIED >/dev/null 2>&1 ) && ok "record VERIFIED" || bad "record VERIFIED failed"
( cd "$PM" && bin/record issue I-001 CLOSED --by D-001 >/dev/null 2>&1 ) && ok "record issue CLOSED" || bad "record issue CLOSED failed"

# --- 4b. bin/close: archive ephemeral files for an already-CLOSED issue ------
# (real integration check of close's idempotency: I-001 is CLOSED already at
# this point, so close must skip the transition gracefully and still archive)
mkdir -p "$PM/messages"
cat > "$PM/prompts/I-001_demo2.md" <<'EOF'
# Dispatch — demo2 (ephemeral, archived on close)
EOF
cat > "$PM/messages/I-001_go_x_2026-07-24.md" <<'EOF'
go x
EOF
( cd "$PM" && bin/close I-001 >/dev/null 2>&1 ) && ok "bin/close I-001" || bad "bin/close I-001 failed"
[ -f "$PM/archive/prompts/I-001_demo2.md" ] && ok "close archived prompts/I-001_demo2.md" || bad "close did not archive prompts/I-001_demo2.md"
[ -f "$PM/archive/messages/I-001_go_x_2026-07-24.md" ] && ok "close archived messages/I-001_go_x_2026-07-24.md" || bad "close did not archive messages/I-001_go_x_2026-07-24.md"
[ -z "$(find "$PM/reports" -mindepth 1 2>/dev/null)" ] && ok "close left reports/ untouched" || bad "close touched reports/"

# --- 4c. bin/track --once: corroborated auto-record within phase-A lifecycle --
# Proves track's intake dovetails with the existing human-gated verify/close flow:
# a real branch/worktree with a descendant worker commit, ACKED with a zzz-test-*
# sentinel tab, herdr shadowed (never touching live workspace w1) to report that
# tab "done", then track --once auto-records RETURNED (never VERIFIED), and a
# human record/pm_apply takes it the rest of the way to VERIFIED + issue CLOSED.
CORROB_BRANCH="i950-corrob"
CORROB_TAB="zzz-test-track-950"
( cd "$DEMO" && git branch "$CORROB_BRANCH" ) >/dev/null 2>&1
( cd "$DEMO" && git worktree add -q "$WORK/wt-950" "$CORROB_BRANCH" ) >/dev/null 2>&1
( cd "$WORK/wt-950" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'worker commit for I-950' ) >/dev/null 2>&1
worker_tip_950="$(git -C "$WORK/wt-950" rev-parse HEAD)"

( cd "$PM" && bin/record issue I-950 ACTIVE >/dev/null 2>&1 ) && ok "record issue I-950 ACTIVE" || bad "record issue I-950 ACTIVE failed"

cat > "$PM/prompts/I-950_corrob_2026-07-24.md" <<'EOF'
# Dispatch — corrob (git-corroborated auto-record leg)

| Ticket | (operator-facing header) |

## Prompt (paste below this line)

Commit a trivial change on your assigned branch.
EOF

if ( cd "$PM" && bin/dispatch-prep --dispatch D-950 --issue I-950 --prompt prompts/I-950_corrob_2026-07-24.md --tab i950-corrob --repo demo >/dev/null 2>&1 ); then
  ok "dispatch-prep D-950 emitted dispatch_new + DISPATCHED w/ git metadata"
else
  bad "dispatch-prep D-950 failed"
fi

( cd "$PM" && bin/record dispatch D-950 ACKED --tab "$CORROB_TAB" >/dev/null 2>&1 ) && ok "record ACKED D-950" || bad "record ACKED D-950 failed"

# shadow herdr (zzz-test-* sentinel tab, mirrors track_test.sh's run_track idiom);
# NEVER touches live workspace w1.
TRACK_FIXTURE="$WORK/track-fixture.json"
printf '{"result": {"tabs": [{"tab_id": "%s", "agent_status": "done", "label": "%s", "workspace_id": "zzz-phaseA-smoke"}]}}' \
  "$CORROB_TAB" "$CORROB_BRANCH" > "$TRACK_FIXTURE"

TRACK_OUT="$(
  cd "$PM" && \
  HERDR_SNAPSHOT_FIXTURE="$TRACK_FIXTURE" \
  PATH="/usr/bin:/bin" \
  bash -c '
    herdr() {
      case "$1 $2" in
        "api snapshot") cat "$HERDR_SNAPSHOT_FIXTURE" ;;
        *) return 1 ;;
      esac
    }
    export -f herdr
    bash bin/track --once
  ' 2>&1
)"
TRACK_RC=$?
[ "$TRACK_RC" -eq 0 ] && ok "track --once exits 0" || bad "track --once failed: $TRACK_OUT"

if WORKER_TIP_950="$worker_tip_950" python3 - "$PM/.pm/index.json" <<'PY'
import json, os, sys
idx = json.load(open(sys.argv[1]))
d = idx["dispatches"]["D-950"]
sys.exit(0 if (d.get("state") == "RETURNED" and d.get("result_sha") == os.environ["WORKER_TIP_950"]) else 1)
PY
then ok "D-950 auto-recorded RETURNED with result_sha == worker tip"; else bad "D-950 not auto-recorded correctly"; fi

[ "$(grep -c '^EVENT result d=D-950 ' "$PM/.pm/events.log")" = "1" ] && ok "exactly one result event for D-950" || bad "wrong number of result events for D-950"

grep -q "D-950" "$PM/TRACKER.md" && ok "TRACKER.md GENERATED block reflects D-950 auto-record" || bad "TRACKER.md missing D-950"

# human lane: advance RETURNED -> VERIFIED -> issue CLOSED
( cd "$PM" && bin/record dispatch D-950 VERIFIED >/dev/null 2>&1 ) && ok "record VERIFIED D-950" || bad "record VERIFIED D-950 failed"
( cd "$PM" && bin/record issue I-950 CLOSED --by D-950 >/dev/null 2>&1 ) && ok "record issue I-950 CLOSED" || bad "record issue I-950 CLOSED failed"

git -C "$DEMO" worktree remove --force "$WORK/wt-950" >/dev/null 2>&1 || true

# --- 5. final integrity + fold ------------------------------------------------
( cd "$PM" && bin/reconcile >/dev/null 2>&1 ) && ok "reconcile after round-trip" || bad "reconcile failed after round-trip"
( cd "$PM" && bin/ledger-check >/dev/null 2>&1 ) && ok "ledger-check clean after full VERIFIED round-trip" || bad "ledger-check failed after round-trip"
if python3 - "$PM/.pm/index.json" <<'PY'
import json, sys
idx = json.load(open(sys.argv[1]))
s = json.dumps(idx)
sys.exit(0 if ("VERIFIED" in s and "CLOSED" in s) else 1)
PY
then ok "index.json shows D-001 VERIFIED + I-001 CLOSED"; else bad "index.json final state wrong"; fi
if python3 - "$PM/.pm/index.json" <<'PY'
import json, sys
idx = json.load(open(sys.argv[1]))
d = idx["dispatches"]["D-950"]
i = idx["issues"]["I-950"]
sys.exit(0 if (d.get("state") == "VERIFIED" and i.get("state") == "CLOSED") else 1)
PY
then ok "index.json shows D-950 VERIFIED + I-950 CLOSED"; else bad "index.json final D-950/I-950 state wrong"; fi

echo "-----------------------------------------"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
