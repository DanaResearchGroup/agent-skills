#!/usr/bin/env bash
# Missing Python/fcntl falls back silently; a guard timeout still refuses.
. "$(dirname "$0")/lib.sh"
sandbox_new

# Exercise the helper's real ImportError path, rather than only its exit code.
mkdir "$SANDBOX/no-fcntl"
export CONTRACT_TEST_PYTHON="$(command -v python3)"
export CONTRACT_TEST_IMPORT_BLOCKED="$SANDBOX/import-blocked"
cat > "$SANDBOX/no-fcntl/python3" <<'PY'
#!/bin/bash
: > "$CONTRACT_TEST_IMPORT_BLOCKED"
if [ "${1:-}" = -I ]; then shift; fi
exec "$CONTRACT_TEST_PYTHON" -I -c '
import sys
sys.modules["fcntl"] = None
sys.argv = sys.argv[1:]
exec(compile(sys.stdin.read(), "<guard>", "exec"))
' "$@"
PY
chmod +x "$SANDBOX/no-fcntl/python3"
out=$(cd "$WT" && PATH="$SANDBOX/no-fcntl:$PATH" "$CONTRACT" new no-module 2>"$SANDBOX/stderr"); rc=$?
assert_eq 0 "$rc" "new succeeds when importing fcntl fails"
assert_file "$CONTRACT_TEST_IMPORT_BLOCKED" "the isolated import-blocking interpreter ran"
assert_file "$WSTATE/no-module.md" "the fallback creates the note"
assert_eq "" "$(cat "$SANDBOX/stderr")" "missing fcntl emits no diagnostics"
(cd "$WT" && "$CONTRACT" abandon "fallback probe" >/dev/null)

mkdir "$SANDBOX/shims"
cat > "$SANDBOX/shims/python3" <<'PY'
#!/bin/bash
exit 3
PY
chmod +x "$SANDBOX/shims/python3"
out=$(cd "$WT" && PATH="$SANDBOX/shims:$PATH" "$CONTRACT" new unavailable 2>"$SANDBOX/stderr"); rc=$?
assert_eq 0 "$rc" "helper exit 3 falls back to the mkdir lock"
assert_file "$WSTATE/unavailable.md" "exit 3 still creates a note"
assert_eq "" "$(cat "$SANDBOX/stderr")" "exit 3 emits no diagnostics"
(cd "$WT" && "$CONTRACT" abandon "fallback probe" >/dev/null)

# A timeout is a different result from an unavailable locking module.
printf '#!/bin/bash\nexit 2\n' > "$SANDBOX/shims/python3"
out=$(cd "$WT" && PATH="$SANDBOX/shims:$PATH" "$CONTRACT" new timed-out 2>&1); rc=$?
assert_eq 2 "$rc" "helper exit 2 refuses creation"
assert_contains "$out" "cannot acquire" "a timeout reports the guard failure"
assert_no_file "$WSTATE/timed-out.md" "a timeout leaves no note"

# Supply the CLI's shell utilities without a Python executable on PATH.
mkdir "$SANDBOX/no-python"
for command in bash git sed tr cut sha256sum shasum realpath readlink mkdir cat rmdir rm date dirname; do
  resolved=$(command -v "$command") || continue
  ln -s "$resolved" "$SANDBOX/no-python/$command"
done
out=$(cd "$WT" && PATH="$SANDBOX/no-python" "$CONTRACT" new no-python 2>"$SANDBOX/stderr"); rc=$?
assert_eq 0 "$rc" "new succeeds when python3 is absent from PATH"
assert_file "$WSTATE/no-python.md" "missing Python still creates the note"
assert_eq "" "$(cat "$SANDBOX/stderr")" "missing Python emits no diagnostics"
assert_no_file "$STATE/.lock" "fallback releases the directory lock"
finish
