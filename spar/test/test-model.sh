#!/usr/bin/env bash
# Exercise the real launcher with isolated resolver and Codex stubs.
set -euo pipefail
SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home/.claude/skills/model-ladder/bin" "$WORK/bin"
export HOME="$WORK/home" PATH="$WORK/bin:$PATH"
unset SPAR_TIER
LADDER="$HOME/.claude/skills/model-ladder/bin/ladder.py"
cat > "$WORK/bin/codex" <<'STUB'
#!/usr/bin/env python3
import json, sys
print(json.dumps(sys.argv[1:]))
STUB
chmod +x "$WORK/bin/codex"
cat > "$LADDER" <<'STUB'
#!/usr/bin/env bash
[ "$1" = resolve ] || exit 2
case "$2" in
  review) printf 'review\tcodex\treview-model\tmedium\n' ;;
  hard) printf 'hard\tcodex\thard-model\txhigh\n' ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$LADDER"

check() {
  local label=$1 model=$2 effort=$3 mode
  for mode in fresh resume; do
    local args=()
    [ "$mode" = fresh ] || args+=(resume 'session id')
    args+=($'prompt with spaces\nand a newline' --skip-git-repo-check --json)
    bash "$SKILL_DIR/bin/spar-codex.sh" "${args[@]}" > "$WORK/argv.json"
    python3 - "$WORK/argv.json" "$model" "$effort" "${args[@]}" <<'PY'
import json, sys
path, model, effort, *args = sys.argv[1:]
prefix = ['exec']
if args[0] == 'resume':
    prefix.append(args.pop(0))
if model:
    prefix += ['-m', model]
expected = prefix + ['-c', f'model_reasoning_effort="{effort}"'] + args
actual = json.load(open(path))
assert actual == expected, f'expected {expected!r}, got {actual!r}'
PY
    printf 'PASS: %s (%s)\n' "$label" "$mode"
  done
}
check 'default review' review-model medium
export SPAR_TIER=hard
check 'tier override hard' hard-model xhigh
unset SPAR_TIER
mv "$LADDER" "$LADDER.saved"
check 'resolver absent' '' high
mv "$LADDER.saved" "$LADDER"
cat > "$LADDER" <<'STUB'
#!/usr/bin/env bash
printf 'review\tcodex\tignored-model\tlow\n'
exit 1
STUB
check 'resolver failure' '' high
