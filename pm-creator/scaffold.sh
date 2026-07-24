#!/usr/bin/env bash
# scaffold.sh — pm-creator's deterministic repo materializer.
#
# SKILL-INTERNAL (lives in the pm-creator skill dir; NOT copied into generated
# repos). Given a JSON values file (one key per {{PLACEHOLDER}}) and an output
# dir, it materializes a generated PM repo from templates/: interpolates every
# *.md.tmpl / pm/*.tmpl, copies bin/* verbatim (+x), writes .gitignore and the
# .pm/ config, and seeds the authoritative event log header. It does NOT git-init
# or add a remote — the SKILL step 3 does that after this returns.
#
# Usage: scaffold.sh --values <values.json> --out <target_dir> [--templates <dir>]
#
# The values JSON is a flat object mapping each placeholder name (without braces)
# to its string value; structured placeholders (REPOS_JSON, OPTIONAL_SLOTS_JSON)
# carry a JSON *string* the caller pre-rendered. Every {{PLACEHOLDER}} present in
# any template MUST have a key, or scaffolding fails loudly (no silent blanks).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="$SELF_DIR/templates"
VALUES="" OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --values) VALUES="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --templates) TEMPLATES="$2"; shift 2 ;;
    *) echo "scaffold.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$VALUES" && -n "$OUT" ]] || { echo "usage: scaffold.sh --values <json> --out <dir> [--templates <dir>]" >&2; exit 2; }
[[ -f "$VALUES" ]] || { echo "scaffold.sh: values file not found: $VALUES" >&2; exit 2; }
[[ -d "$TEMPLATES" ]] || { echo "scaffold.sh: templates dir not found: $TEMPLATES" >&2; exit 2; }

# Materialize into a sibling temp dir first, so a failure partway through never
# leaves a partial directory sitting at $OUT for the next run to trip over.
OUT_PARENT="$(dirname "$OUT")"
[[ -d "$OUT_PARENT" ]] || mkdir -p "$OUT_PARENT"

# Reserve $OUT atomically, up front. `mkdir` is an exclusive create: it fails
# if $OUT exists at all, empty or not — that failure IS the collision check,
# and it closes the window a separate `[[ -e "$OUT" ]]` test would leave open.
# (An empty pre-existing $OUT would pass `-e` fine, then `mv -T` a moment
# later replaces an existing empty directory without complaint — silently
# clobbering it. Reserving with `mkdir` first means nobody else can ever hold
# an empty $OUT for us to race against: our own `mkdir` is the only way $OUT
# comes to exist before publish.)
mkdir "$OUT" || { echo "scaffold.sh: target already exists (create-only): $OUT" >&2; exit 2; }

TMP_OUT="$(mktemp -d "$OUT_PARENT/.scaffold-tmp.XXXXXX")"
cleanup() {
  local sig="${1:-EXIT}"
  [[ -n "${TMP_OUT:-}" && -d "$TMP_OUT" ]] && rm -rf "$TMP_OUT"
  # Only reaps our own still-empty reservation — `rmdir` no-ops (fails
  # harmlessly) once `mv -T` has published the real tree there, so a trap
  # that fires after a successful publish can never delete published output.
  [[ -n "${OUT:-}" && -d "$OUT" ]] && rmdir "$OUT" 2>/dev/null
  if [[ "$sig" != "EXIT" ]]; then
    trap - EXIT INT TERM
    kill -s "$sig" "$$"
  fi
}
trap cleanup EXIT
trap 'cleanup INT' INT
trap 'cleanup TERM' TERM

mkdir -p "$TMP_OUT/.pm" "$TMP_OUT/bin" "$TMP_OUT/reports" "$TMP_OUT/prompts" \
  "$TMP_OUT/messages" "$TMP_OUT/archive/messages" "$TMP_OUT/archive/prompts"

# Interpolate all templates + write config, via one python pass (robust to
# multi-line / special-char values; fails if any placeholder lacks a value).
TEMPLATES="$TEMPLATES" OUT="$TMP_OUT" VALUES="$VALUES" python3 - <<'PY'
import json, os, re, sys, stat

templates = os.environ["TEMPLATES"]
out = os.environ["OUT"]
values = json.load(open(os.environ["VALUES"], encoding="utf-8"))

# --- B2.0b: repos normalization (complete-by-construction mainline_ref) ---
# REPOS_JSON is a caller-supplied JSON array of repo objects. Downstream
# (B2.1's auto-close merged-predicate) needs a FULL mainline ref on every
# repo -- never a short `main` -- so this pass makes the config
# complete-by-construction rather than relying on the caller to have
# supplied it: derive a default when absent, but FAIL LOUD (no silent
# guess) on anything ambiguous. Re-serializes via json.dumps, so the
# hardened REPOS_JSON escaping guarantee below (raw, never re-escaped)
# still holds for the normalized value.
if "REPOS_JSON" in values:
    try:
        repos = json.loads(values["REPOS_JSON"])
    except (TypeError, json.JSONDecodeError) as e:
        print(f"scaffold.sh: REPOS_JSON is not valid JSON: {e}", file=sys.stderr)
        sys.exit(3)
    if not isinstance(repos, list):
        print("scaffold.sh: REPOS_JSON must be a JSON array of repo objects", file=sys.stderr)
        sys.exit(3)
    FETCH_POLICIES = {"fetch", "local-only"}
    norm_repos = []
    for idx, repo in enumerate(repos):
        if not isinstance(repo, dict):
            print(f"scaffold.sh: REPOS_JSON[{idx}] is not a JSON object", file=sys.stderr)
            sys.exit(3)
        name = repo.get("name", f"#{idx}")
        mainline = repo.get("mainline")
        if not mainline:
            print(
                f"scaffold.sh: repo '{name}' is missing required 'mainline' "
                "(cannot derive a mainline_ref without it)",
                file=sys.stderr,
            )
            sys.exit(3)
        if not isinstance(mainline, str):
            print(
                f"scaffold.sh: repo '{name}' has a non-string 'mainline' "
                f"({mainline!r}) -- cannot derive a mainline_ref from it",
                file=sys.stderr,
            )
            sys.exit(3)
        repo = dict(repo)
        mainline_ref = repo.get("mainline_ref")
        if mainline_ref is None:
            # Default for pushed workflows (event-log-grammar.md / B2 design):
            # fetch `origin/<mainline>` and compare against it.
            repo["mainline_ref"] = f"refs/remotes/origin/{mainline}"
            repo.setdefault("fetch_policy", "fetch")
        elif not isinstance(mainline_ref, str):
            print(
                f"scaffold.sh: repo '{name}' has a non-string 'mainline_ref' "
                f"({mainline_ref!r}) -- must be a full ref string",
                file=sys.stderr,
            )
            sys.exit(3)
        elif not mainline_ref.startswith("refs/"):
            # The exact short-`main` trap B2.0b exists to prevent -- reject
            # rather than silently treat it as a branch name.
            print(
                f"scaffold.sh: repo '{name}' mainline_ref='{mainline_ref}' is a short/"
                "unqualified ref (must start with 'refs/' -- e.g. "
                f"'refs/remotes/origin/{mainline}' for a pushed workflow or "
                f"'refs/heads/{mainline}' for local-only; never a short branch name)",
                file=sys.stderr,
            )
            sys.exit(3)
        else:
            # Operator-supplied full ref: preserved verbatim. Default the
            # fetch policy from the ref's own shape only if not also given.
            repo.setdefault(
                "fetch_policy",
                "fetch" if mainline_ref.startswith("refs/remotes/") else "local-only",
            )
        if repo.get("fetch_policy") not in FETCH_POLICIES:
            print(
                f"scaffold.sh: repo '{name}' has fetch_policy={repo.get('fetch_policy')!r}, "
                f"must be one of {sorted(FETCH_POLICIES)}",
                file=sys.stderr,
            )
            sys.exit(3)
        norm_repos.append(repo)
    values["REPOS_JSON"] = json.dumps(norm_repos)

PH = re.compile(r"\{\{([A-Za-z0-9_]+)\}\}")
missing = set()

def interp(text, where, is_json):
    def sub(m):
        k = m.group(1)
        if k not in values:
            missing.add(f"{k} (in {where})")
            return m.group(0)
        v = str(values[k])
        # Keys ending in _JSON already carry a pre-rendered JSON value (e.g.
        # REPOS_JSON, OPTIONAL_SLOTS_JSON) — interpolate raw, never re-escape.
        if is_json and not k.endswith("_JSON"):
            # json.dumps a bare string and strip the surrounding quotes, so the
            # result drops in place of the placeholder inside the template's
            # own quoted "..." string, with \, ", and control chars escaped
            # per JSON string rules.
            return json.dumps(v)[1:-1]
        return v
    return PH.sub(sub, text)

# Map template path -> output path.
def out_path(rel):
    # pm/foo.tmpl -> .pm/foo ; gitignore.tmpl -> .gitignore ; X.md.tmpl -> X.md
    if rel.startswith("pm/"):
        base = rel[len("pm/"):]
        base = base[:-len(".tmpl")] if base.endswith(".tmpl") else base
        return os.path.join(out, ".pm", base)
    if rel == "gitignore.tmpl":
        return os.path.join(out, ".gitignore")
    if rel.endswith(".tmpl"):
        return os.path.join(out, rel[:-len(".tmpl")])
    return None  # non-template (bin/, etc.) handled in bash

for dirpath, _dirs, files in os.walk(templates):
    for f in files:
        full = os.path.join(dirpath, f)
        rel = os.path.relpath(full, templates)
        if rel.startswith("bin/"):
            continue  # copied verbatim in bash
        dst = out_path(rel)
        if dst is None:
            continue
        text = open(full, encoding="utf-8").read()
        rendered = interp(text, rel, rel.endswith(".json.tmpl"))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        open(dst, "w", encoding="utf-8").write(rendered)

if missing:
    print("scaffold.sh: missing values for placeholders:", file=sys.stderr)
    for m in sorted(missing):
        print("  - " + m, file=sys.stderr)
    sys.exit(3)
PY

# Copy bin/ verbatim (these are shipped tools, not templates) and make executable.
for f in "$TEMPLATES"/bin/*; do
  name="$(basename "$f")"
  cp "$f" "$TMP_OUT/bin/$name"
  chmod +x "$TMP_OUT/bin/$name"
done

# Seed the authoritative event log with exactly its schema header.
printf 'EVENT schema v=1\n' > "$TMP_OUT/.pm/events.log"

# Fail loudly if any placeholder survived (the SKILL's own guard, enforced here too).
# Broad on purpose: any {{...}} token — not just [A-Z_] — must be caught, since a
# lowercase/mixed/numeric placeholder slipping through is exactly as unresolved.
# Templates contain no legitimate literal {{...}} that must survive into output.
# Scanned per-file over the FULL content (not line-by-line via grep), so a
# placeholder split across a newline (e.g. "{{foo\nbar}}") is caught too.
TMP_OUT="$TMP_OUT" python3 - <<'PY'
import os, re, sys

tmp_out = os.environ["TMP_OUT"]
pat = re.compile(r"\{\{.*?\}\}", re.DOTALL)
hits = []
for dirpath, _dirs, files in os.walk(tmp_out):
    for f in files:
        full = os.path.join(dirpath, f)
        try:
            with open(full, encoding="utf-8") as fh:
                content = fh.read()
        except (UnicodeDecodeError, OSError):
            continue
        m = pat.search(content)
        if m:
            hits.append((full, m.group(0)))

if hits:
    print("scaffold.sh: unresolved {{PLACEHOLDER}} tokens remain in output:", file=sys.stderr)
    for full, token in sorted(hits):
        print(f"  - {full}: {token}", file=sys.stderr)
    sys.exit(3)
PY

# Parse every rendered *.json file to catch a malformed _JSON value (e.g. a
# hostile REPOS_JSON/OPTIONAL_SLOTS_JSON) before it ever ships — those keys
# are dropped in raw, unescaped, so a bad input yields invalid JSON that
# would otherwise only be discovered at campaign runtime.
TMP_OUT="$TMP_OUT" python3 - <<'PY'
import json, os, sys

tmp_out = os.environ["TMP_OUT"]
errors = []
for dirpath, _dirs, files in os.walk(tmp_out):
    for f in files:
        if not f.endswith(".json"):
            continue
        full = os.path.join(dirpath, f)
        try:
            with open(full, encoding="utf-8") as fh:
                json.load(fh)
        except (json.JSONDecodeError, UnicodeDecodeError, OSError) as e:
            errors.append((full, str(e)))

if errors:
    print("scaffold.sh: rendered JSON file(s) failed to parse:", file=sys.stderr)
    for full, err in sorted(errors):
        print(f"  - {full}: {err}", file=sys.stderr)
    sys.exit(3)
PY

# Success — atomically publish the finished tree at the real target, and
# disarm the cleanup trap so it isn't removed out from under us. $OUT is our
# own empty reservation from the `mkdir` above (nothing else could have
# created it), so `mv -T` replacing that empty directory with $TMP_OUT is
# safe: no concurrent scaffold could ever be holding $OUT to race against.
if mv -T "$TMP_OUT" "$OUT"; then
  trap - EXIT INT TERM
else
  echo "scaffold.sh: failed to publish to $OUT (already exists?)" >&2
  exit 2
fi

echo "scaffolded PM repo at: $OUT"
