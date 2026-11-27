#!/usr/bin/env bash
# Tests for show-me/bin/show-me-place: where a page lands, and whether a
# browser is called, on HL and on a peer. CI runs every */test/ci.sh.
#
# The fixtures are fake machine.env and planes files, passed to the real
# factory-machine helper through FACTORY_MACHINE_ENV and FACTORY_PLANES, and
# a fake xdg-open (and open) on PATH that records every call. HOME points at
# the scratch tree, so nothing can land in a real folder.
set -uo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PLACE="$SKILL_DIR/bin/show-me-place"

PASS=0; FAIL=0
WORK=$(mktemp -d "${TMPDIR:-/tmp}/show-me-place-test-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

section() { printf '\n-- %s\n' "$1"; }
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

assert_eq() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}
assert_contains() { # <label> <needle> <haystack>
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "[$2] not found in: $3" ;; esac
}
assert_file() { # <label> <path>
  if [ -f "$2" ]; then ok "$1"; else bad "$1" "no file at $2"; fi
}

# A fake opener: records "<name> <args>" to $OPEN_LOG and succeeds.
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
for opener in xdg-open open; do
  cat > "$FAKEBIN/$opener" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$opener" "\$*" >> "\$OPEN_LOG"
EOF
  chmod +x "$FAKEBIN/$opener"
done

# Fixture files.
FIX="$WORK/fix"; mkdir -p "$FIX"
cat > "$FIX/planes" <<'EOF'
# slug repo owning_persona zone
alpha alpha-repo method any
beta  beta-repo  method hl-only
EOF
cat > "$FIX/hl.env" <<'EOF'
MACHINE=HL
HAS_DISPLAY=1
EXCHANGE_ROOT=~/exchange
PEERS="LMF OL"
EOF
cat > "$FIX/lmf.env" <<'EOF'
MACHINE=LMF
HAS_DISPLAY=0
EXCHANGE_ROOT=~/exchange/hl
PEERS=HL
HL_EXCHANGE_ROOT=/hl-home/exchange/LMF
EOF

# A plane checkout: .pm/config.json names beta; a subfolder to run from.
PLANE_DIR="$WORK/plane-beta"; mkdir -p "$PLANE_DIR/.pm" "$PLANE_DIR/sub/dir"
printf '{"slug": "beta", "persona": "method"}\n' > "$PLANE_DIR/.pm/config.json"
ALPHA_DIR="$WORK/plane-alpha"; mkdir -p "$ALPHA_DIR/.pm"
printf '{"slug": "alpha"}\n' > "$ALPHA_DIR/.pm/config.json"
NOPLANE="$WORK/noplane"; mkdir -p "$NOPLANE"
BAD_DIR="$WORK/plane-bad"; mkdir -p "$BAD_DIR/.pm"
printf '{"persona": "method"}\n' > "$BAD_DIR/.pm/config.json"

# The no-plane tests need no .pm/config.json between $WORK and /.
d="$WORK"; ABOVE_PLANE=""
while [ "$d" != / ]; do
  d=$(dirname "$d"); [ -f "$d/.pm/config.json" ] && ABOVE_PLANE="$d"
done

DAY=$(date +%Y.%m.%d)
TESTHOME="$WORK/home"; mkdir -p "$TESTHOME"
OPEN_LOG="$WORK/open.log"

# run_place <cwd> <env file> <subcommand> [args...] -- sets RC, OUT, ERR
# Extra environment goes in the array EXTRA (KEY=value words).
EXTRA=()
run_place() {
  local cwd=$1 envf=$2; shift 2
  local errf="$WORK/.err"
  OUT=$(cd "$cwd" && env -u SHOW_ME_PLANE -u SHOW_ME_DIR HOME="$TESTHOME" \
    PATH="$FAKEBIN:$PATH" OPEN_LOG="$OPEN_LOG" \
    FACTORY_MACHINE_ENV="$envf" FACTORY_PLANES="$FIX/planes" \
    ${EXTRA[@]+"${EXTRA[@]}"} "$PLACE" "$@" 2>"$errf"); RC=$?
  ERR=$(cat "$errf")
  return 0
}
opener_calls() { if [ -f "$OPEN_LOG" ]; then wc -l < "$OPEN_LOG" | tr -d ' '; else echo 0; fi; }
html_count() { find "$WORK" -name '*.html' -type f | wc -l | tr -d ' '; }
line_count() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }
reset() { rm -f "$OPEN_LOG"; find "$WORK" -name '*.html' -type f -delete; EXTRA=(); }

section "HL: saves in SHOW_ME_DIR and opens once"
reset
SMD="$WORK/show-me-hl"
EXTRA=(SHOW_ME_DIR="$SMD" SHOW_ME_PLANE=alpha)
run_place "$NOPLANE" "$FIX/hl.env" new "Session Event Flow"
assert_eq "new exits 0" 0 "$RC"
assert_eq "new prints the file in SHOW_ME_DIR" "$SMD/$DAY a Session Event Flow.html" "$OUT"
assert_file "the empty file exists" "$SMD/$DAY a Session Event Flow.html"
F=$OUT
run_place "$NOPLANE" "$FIX/hl.env" open "$F"
assert_eq "open exits 0" 0 "$RC"
assert_eq "the opener is called once" 1 "$(opener_calls)"
assert_contains "xdg-open gets the file" "xdg-open $F" "$(cat "$OPEN_LOG" 2>/dev/null)"

section "HL: a plane from .pm/config.json works the same"
reset
EXTRA=(SHOW_ME_DIR="$SMD")
run_place "$ALPHA_DIR" "$FIX/hl.env" new "Config Plane"
assert_eq "new exits 0" 0 "$RC"
assert_eq "file in SHOW_ME_DIR" "$SMD/$DAY a Config Plane.html" "$OUT"

section "HL: an hl-only plane is fine on HL"
reset
EXTRA=(SHOW_ME_DIR="$SMD")
run_place "$PLANE_DIR/sub/dir" "$FIX/hl.env" new "Hub Only"
assert_eq "new exits 0" 0 "$RC"
assert_eq "file in SHOW_ME_DIR" "$SMD/$DAY a Hub Only.html" "$OUT"

section "HL: same name and date twice gets letters a and b"
reset
EXTRA=(SHOW_ME_DIR="$SMD" SHOW_ME_PLANE=alpha)
run_place "$NOPLANE" "$FIX/hl.env" new "Twice"
assert_eq "first run gets a" "$SMD/$DAY a Twice.html" "$OUT"
run_place "$NOPLANE" "$FIX/hl.env" new "Twice"
assert_eq "second run gets b" "$SMD/$DAY b Twice.html" "$OUT"

section "LMF: saves under to-hl/artifacts/alpha/show-me, prints the HL path, never opens"
reset
EXTRA=(SHOW_ME_PLANE=alpha)
run_place "$NOPLANE" "$FIX/lmf.env" new "Peer Page"
assert_eq "new exits 0" 0 "$RC"
PEER_DIR="$TESTHOME/exchange/hl/to-hl/artifacts/alpha/show-me"
assert_eq "line 1 is the file here" "$PEER_DIR/$DAY a Peer Page.html" "$(printf '%s\n' "$OUT" | sed -n 1p)"
assert_eq "line 2 is the path on HL" \
  "/hl-home/exchange/LMF/to-hl/artifacts/alpha/show-me/$DAY a Peer Page.html" \
  "$(printf '%s\n' "$OUT" | sed -n 2p)"
assert_eq "two lines, no more" 2 "$(line_count "$OUT")"
assert_file "the empty file exists" "$PEER_DIR/$DAY a Peer Page.html"
run_place "$NOPLANE" "$FIX/lmf.env" open "$PEER_DIR/$DAY a Peer Page.html"
assert_eq "open exits 0 on a peer" 0 "$RC"
assert_eq "the opener is never called" 0 "$(opener_calls)"
assert_contains "open names the HL path" \
  "/hl-home/exchange/LMF/to-hl/artifacts/alpha/show-me/$DAY a Peer Page.html" "$OUT$ERR"

section "LMF: same name and date twice gets letters a and b"
reset
EXTRA=(SHOW_ME_PLANE=alpha)
run_place "$NOPLANE" "$FIX/lmf.env" new "Twice"
assert_eq "first run gets a" "$PEER_DIR/$DAY a Twice.html" "$(printf '%s\n' "$OUT" | sed -n 1p)"
run_place "$NOPLANE" "$FIX/lmf.env" new "Twice"
assert_eq "second run gets b" "$PEER_DIR/$DAY b Twice.html" "$(printf '%s\n' "$OUT" | sed -n 1p)"

section "SHOW_ME_PLANE beats .pm/config.json"
reset
EXTRA=(SHOW_ME_PLANE=alpha)
run_place "$PLANE_DIR/sub/dir" "$FIX/lmf.env" new "Env Wins"
assert_eq "new exits 0 (beta is hl-only, alpha is not)" 0 "$RC"
assert_eq "file under alpha" "$PEER_DIR/$DAY a Env Wins.html" "$(printf '%s\n' "$OUT" | sed -n 1p)"

section "LMF: a plane from .pm/config.json"
reset
run_place "$ALPHA_DIR" "$FIX/lmf.env" new "From Config"
assert_eq "new exits 0" 0 "$RC"
assert_eq "file under alpha" "$PEER_DIR/$DAY a From Config.html" "$(printf '%s\n' "$OUT" | sed -n 1p)"

# stopped <label> -- the run refused: non-zero, one stderr line, no page, no opener call
stopped() {
  if [ "$RC" -ne 0 ]; then ok "$1: exits non-zero ($RC)"; else bad "$1: exits non-zero" "rc 0"; fi
  assert_eq "$1: one line on stderr" 1 "$(line_count "$ERR")"
  assert_eq "$1: nothing on stdout" "" "$OUT"
  assert_eq "$1: no page created" 0 "$(html_count)"
  assert_eq "$1: no opener call" 0 "$(opener_calls)"
}

section "No machine.env: stop, name the file, save nothing"
reset
EXTRA=(SHOW_ME_DIR="$SMD" SHOW_ME_PLANE=alpha)
run_place "$NOPLANE" "$FIX/missing.env" new "Nowhere"
stopped "new"
assert_contains "the line names machine.env" "$FIX/missing.env" "$ERR"
touch "$WORK/stray.page"
run_place "$NOPLANE" "$FIX/missing.env" open "$WORK/stray.page"
if [ "$RC" -ne 0 ]; then ok "open: exits non-zero"; else bad "open: exits non-zero" "rc 0"; fi
assert_eq "open: no opener call" 0 "$(opener_calls)"
assert_contains "open: the line names machine.env" "$FIX/missing.env" "$ERR"

section "Malformed machine.env: stop the same way"
reset
printf 'MACHINE=HL\nHAS_DISPLAY=maybe\n' > "$FIX/bad.env"
EXTRA=(SHOW_ME_DIR="$SMD" SHOW_ME_PLANE=alpha)
run_place "$NOPLANE" "$FIX/bad.env" new "Nowhere"
stopped "new"
assert_contains "the line names the file" "$FIX/bad.env" "$ERR"

section "Peer with an hl-only plane: stop"
reset
EXTRA=(SHOW_ME_PLANE=beta)
run_place "$NOPLANE" "$FIX/lmf.env" new "Secret"
stopped "new"
assert_contains "the line says hl-only" "hl-only" "$ERR"
run_place "$PLANE_DIR/sub/dir" "$FIX/lmf.env" new "Secret"
stopped "new from the plane checkout"

section "Peer with an unknown plane: stop"
reset
EXTRA=(SHOW_ME_PLANE=gamma)
run_place "$NOPLANE" "$FIX/lmf.env" new "Unknown"
stopped "new"
assert_contains "the line names the plane" "gamma" "$ERR"

section "A .pm/config.json with no slug: stop"
reset
run_place "$BAD_DIR" "$FIX/lmf.env" new "No Slug"
stopped "new"
assert_contains "the line names the config" "$BAD_DIR/.pm/config.json" "$ERR"

if [ -n "$ABOVE_PLANE" ]; then
  printf '\n-- SKIP no-plane tests: %s/.pm/config.json is above the scratch tree\n' "$ABOVE_PLANE"
else
  section "Peer with no plane: stop"
  reset
  run_place "$NOPLANE" "$FIX/lmf.env" new "No Plane"
  stopped "new"
  assert_contains "the line asks for SHOW_ME_PLANE" "SHOW_ME_PLANE" "$ERR"

  section "HL with no plane and no factory row: stop"
  reset
  EXTRA=(SHOW_ME_DIR="$SMD")
  run_place "$NOPLANE" "$FIX/hl.env" new "No Plane"
  stopped "new"
fi

section "Names that are not one file name are refused"
reset
EXTRA=(SHOW_ME_DIR="$SMD" SHOW_ME_PLANE=alpha)
run_place "$NOPLANE" "$FIX/hl.env" new "a/b"
stopped "a name with a slash"
run_place "$NOPLANE" "$FIX/hl.env" new ""
stopped "an empty name"

section "26 pages with one name and date: stop"
reset
EXTRA=(SHOW_ME_DIR="$SMD" SHOW_ME_PLANE=alpha)
mkdir -p "$SMD"
for L in a b c d e f g h i j k l m n o p q r s t u v w x y z; do : > "$SMD/$DAY $L Full.html"; done
run_place "$NOPLANE" "$FIX/hl.env" new "Full"
if [ "$RC" -ne 0 ]; then ok "exits non-zero"; else bad "exits non-zero" "rc 0"; fi
assert_eq "nothing on stdout" "" "$OUT"

section "HL with no display: saves, never opens"
reset
sed 's/HAS_DISPLAY=1/HAS_DISPLAY=0/' "$FIX/hl.env" > "$FIX/hl-dark.env"
EXTRA=(SHOW_ME_DIR="$SMD" SHOW_ME_PLANE=alpha)
run_place "$NOPLANE" "$FIX/hl-dark.env" new "Dark"
assert_eq "new exits 0" 0 "$RC"
assert_eq "file in SHOW_ME_DIR" "$SMD/$DAY a Dark.html" "$OUT"
run_place "$NOPLANE" "$FIX/hl-dark.env" open "$OUT"
assert_eq "open exits 0" 0 "$RC"
assert_eq "the opener is never called" 0 "$(opener_calls)"

# The SKILL.md block's own lines that find show-me-place: everything in the
# bash block under "### The file" before the first OUT= line.
resolve_lines() {
  awk '/^### The file/ {f=1} f && /^```bash/ {b=1; next} b && /^OUT=/ {exit} b {print}' \
    "$SKILL_DIR/SKILL.md"
}

for INSTALL in .codex/skills .agents/skills; do
  section "SKILL.md finds show-me-place when installed only under ~/$INSTALL"
  reset
  FAKEHOME="$WORK/home-${INSTALL%%/*}"; rm -rf "$FAKEHOME"
  mkdir -p "$FAKEHOME/$INSTALL"
  ln -s "$SKILL_DIR" "$FAKEHOME/$INSTALL/show-me"
  ln -s "$SKILL_DIR/../factory-machine" "$FAKEHOME/$INSTALL/factory-machine"
  LINES=$(resolve_lines)
  assert_contains "the block has resolution lines" 'P=' "$LINES"
  FOUND=$(cd "$NOPLANE" && HOME="$FAKEHOME" bash -c "$LINES"$'\nprintf %s "$P"' 2>/dev/null)
  assert_eq "P is the installed script" "$FAKEHOME/$INSTALL/show-me/bin/show-me-place" "$FOUND"
  # The found script reaches factory-machine through its own folder.
  if [ -x "$FOUND" ]; then
    PLACE_SAVED=$PLACE; PLACE=$FOUND
    EXTRA=(SHOW_ME_DIR="$SMD" SHOW_ME_PLANE=alpha)
    run_place "$NOPLANE" "$FIX/hl.env" new "Installed ${INSTALL%%/*}"
    PLACE=$PLACE_SAVED
    assert_eq "the found script makes a page" 0 "$RC"
  else
    bad "the found script makes a page" "not executable: [$FOUND]"
  fi
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
