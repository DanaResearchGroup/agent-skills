#!/usr/bin/env bash
# Checkout and environment modules cannot replace the guard's real fcntl.
. "$(dirname "$0")/lib.sh"
sandbox_new

mkdir "$SANDBOX/pythonpath"
cat > "$WT/fcntl.py" <<'PY'
import os
open(os.environ['CONTRACT_TEST_CWD_MARKER'], 'w').close()
raise ImportError('checkout module executed')
PY
cat > "$SANDBOX/pythonpath/fcntl.py" <<'PY'
import os
open(os.environ['CONTRACT_TEST_ENV_MARKER'], 'w').close()
raise ImportError('environment module executed')
PY
export CONTRACT_TEST_CWD_MARKER="$SANDBOX/cwd-executed"
export CONTRACT_TEST_ENV_MARKER="$SANDBOX/env-executed"
export PYTHONPATH="$SANDBOX/pythonpath"

out=$(cd "$WT" && "$CONTRACT" new isolated 2>"$SANDBOX/stderr"); rc=$?
assert_eq 0 "$rc" "new succeeds with hostile modules in cwd and PYTHONPATH"
assert_file "$WSTATE/isolated.md" "isolated new creates its note"
assert_eq "" "$(cat "$SANDBOX/stderr")" "hostile modules cause no diagnostics"
assert_no_file "$CONTRACT_TEST_CWD_MARKER" "the checkout fcntl module never executes"
assert_no_file "$CONTRACT_TEST_ENV_MARKER" "the PYTHONPATH fcntl module never executes"
(cd "$WT" && "$CONTRACT" abandon "isolation probe" >/dev/null)

# An independently held OS lock proves isolation still uses real flock.
# FD 8 keeps the lock held in this shell after the interpreter exits.
exec 8>> "$STATE/.lock.guard"
python3 -I -c 'import fcntl; fcntl.flock(8, fcntl.LOCK_EX)' || exit 1
out=$(exec 8>&-; cd "$WT" && "$CONTRACT" new guarded 2>&1); rc=$?
exec 8>&-
assert_eq 2 "$rc" "the isolated helper respects a real flock holder"
assert_contains "$out" "is holding" "real flock contention reports a timeout"
assert_no_file "$WSTATE/guarded.md" "real flock contention leaves no note"
assert_no_file "$CONTRACT_TEST_CWD_MARKER" "contention does not execute the checkout module"
assert_no_file "$CONTRACT_TEST_ENV_MARKER" "contention does not execute the PYTHONPATH module"
finish
