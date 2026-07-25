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
# to its string value; structured placeholders (REPOS_JSON, AUTOMATION_JSON)
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
import json, os, re, subprocess, sys, stat

templates = os.environ["TEMPLATES"]
out = os.environ["OUT"]
values = json.load(open(os.environ["VALUES"], encoding="utf-8"))


def _git(path, *args):
    """Run a read-only git command in `path`; return stdout, or None on any failure."""
    try:
        p = subprocess.run(
            ("git", "-C", path) + args,
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return p.stdout if p.returncode == 0 else None


def _die(msg):
    print(f"scaffold.sh: {msg}", file=sys.stderr)
    sys.exit(3)


def _derive_mainline_ref(name, repo, mainline):
    """Derive a full mainline ref by PROBING the repo -- never by guessing a
    remote name. Returns the ref, or exits non-zero with an actionable message.

    Rules, in order:
      - exactly one `refs/remotes/<remote>/<mainline>` -> that ref;
      - several  -> FAIL LOUD with the candidates. Which remote is canonical
        is a judgment call (canonical org vs personal fork) and picking one
        silently is how work gets pushed to, or corroborated against, the
        wrong place;
      - none, but `refs/heads/<mainline>` exists -> local-only workflow;
      - none at all -> FAIL LOUD (the branch does not exist under that name).
    """
    path = repo.get("path")
    if not path:
        _die(
            f"repo '{name}' has no 'mainline_ref' and no 'path' to probe -- supply one "
            "of them (a full ref such as 'refs/remotes/<remote>/"
            f"{mainline}', or the repo path so the ref can be derived)"
        )
    if not os.path.isdir(path) or _git(path, "rev-parse", "--git-dir") is None:
        _die(
            f"repo '{name}' path {path!r} is not a git repository, so 'mainline_ref' "
            "cannot be derived -- create/clone the repo first, or supply 'mainline_ref' "
            "explicitly"
        )

    remote_refs = _git(path, "for-each-ref", "--format=%(refname)", f"refs/remotes/*/{mainline}")
    candidates = [r for r in (remote_refs or "").split("\n") if r.strip()]
    # `refs/remotes/<remote>/HEAD` is a symbolic pointer, not a branch.
    candidates = [r for r in candidates if not r.endswith("/HEAD")]

    if len(candidates) == 1:
        return candidates[0]
    if len(candidates) > 1:
        remotes = ", ".join(sorted(c.split("/")[2] for c in candidates))
        _die(
            f"repo '{name}': branch {mainline!r} exists on MORE THAN ONE remote "
            f"({remotes}) -- refusing to guess which is canonical. Set 'mainline_ref' "
            f"explicitly, e.g. \"mainline_ref\": \"{candidates[0]}\". "
            "This is usually a canonical-org remote alongside a personal fork; pick the "
            "one work actually lands on."
        )

    if _git(path, "show-ref", "--verify", "--quiet", f"refs/heads/{mainline}") is not None:
        return f"refs/heads/{mainline}"
    _die(
        f"repo '{name}': no ref matches branch {mainline!r} -- neither "
        f"refs/remotes/*/{mainline} nor refs/heads/{mainline} exists in {path}. Check the "
        "mainline branch name (it is NOT always 'main' -- long-lived integration branches "
        "are common), or fetch the remote first."
    )


def _check_ref_resolves(name, repo, mainline_ref):
    """WARN (never fatal) when an operator-supplied ref does not resolve today.

    Not fatal: declaring a repo before its first push is legitimate. Loud,
    because a ref that never resolves corroborates nothing and says nothing --
    the exact silent failure mode this pass exists to surface.
    """
    path = repo.get("path")
    if not path or not os.path.isdir(path):
        return
    if _git(path, "rev-parse", "--git-dir") is None:
        return
    if _git(path, "show-ref", "--verify", "--quiet", mainline_ref) is None:
        print(
            f"scaffold.sh: WARNING: repo '{name}' mainline_ref={mainline_ref!r} does not "
            f"resolve in {path} today. Nothing will corroborate against it until it does "
            "-- and it will fail silently, not loudly. Fetch the remote, push the branch, "
            "or fix the ref.",
            file=sys.stderr,
        )

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
            # B2.3: NEVER guess `origin`. Assuming the canonical remote is
            # named `origin` is the silent-failure bug this block exists to
            # prevent: if the remote is actually called something else, the
            # configured ref simply never resolves, so auto-close's ancestry
            # corroboration never fires -- and it never fires QUIETLY. The
            # campaign looks healthy and corroborates nothing. (Observed on a
            # 16-repo campaign where 7 repos used `official`, not `origin`.)
            #
            # So: probe the real repo and derive the ref from what is actually
            # there, failing loud on anything ambiguous rather than picking a
            # winner. Probing is only reached when the operator omitted
            # `mainline_ref`; an explicit ref is always honoured verbatim.
            repo["mainline_ref"] = _derive_mainline_ref(name, repo, mainline)
            repo.setdefault(
                "fetch_policy",
                "fetch" if repo["mainline_ref"].startswith("refs/remotes/") else "local-only",
            )
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
            # B2.3: honoured verbatim, but say so out loud if it is already
            # dead on arrival.
            _check_ref_resolves(name, repo, mainline_ref)
        if repo.get("fetch_policy") not in FETCH_POLICIES:
            print(
                f"scaffold.sh: repo '{name}' has fetch_policy={repo.get('fetch_policy')!r}, "
                f"must be one of {sorted(FETCH_POLICIES)}",
                file=sys.stderr,
            )
            sys.exit(3)
        # --- B2.2: marker-path opt-ins, complete-by-construction ---
        # merge_mode selects how track's auto-close G4 corroborates a repo:
        # "merge" (default; strict ancestry only) or "squash" (strict first,
        # then the human-attested `merged`-marker arm). FAIL LOUD on any
        # other value rather than silently defaulting.
        merge_mode = repo.setdefault("merge_mode", "merge")
        if merge_mode not in ("merge", "squash"):
            print(
                f"scaffold.sh: repo '{name}' has merge_mode={merge_mode!r}, "
                "must be one of ['merge', 'squash']",
                file=sys.stderr,
            )
            sys.exit(3)
        # allow_marker_branch_deleted (bool, default false): whether a
        # marker-path close may proceed when the dispatch's recorded branch
        # no longer resolves (normal post-squash cleanup). Type-checked --
        # a truthy string like "yes" must not silently widen the gate.
        allow_deleted = repo.setdefault("allow_marker_branch_deleted", False)
        if not isinstance(allow_deleted, bool):
            print(
                f"scaffold.sh: repo '{name}' has "
                f"allow_marker_branch_deleted={allow_deleted!r}, must be a JSON boolean",
                file=sys.stderr,
            )
            sys.exit(3)
        norm_repos.append(repo)
    values["REPOS_JSON"] = json.dumps(norm_repos)

# --- B3: automation normalization (complete-by-construction) ---
# AUTOMATION_JSON is an OPTIONAL caller-supplied JSON object; absent means
# "all defaults". Downstream (track's spawn stage) needs every key present
# and correctly typed, so this pass makes the config complete-by-
# construction with fail-safe defaults (everything OFF / minimal), and
# FAILS LOUD on any wrong type rather than letting a truthy string or a
# bool-masquerading-as-int silently widen an automation gate. Unknown extra
# keys are preserved (additive tolerance, same as repos normalization).
try:
    automation = json.loads(values.get("AUTOMATION_JSON") or "{}")
except (TypeError, json.JSONDecodeError) as e:
    print(f"scaffold.sh: AUTOMATION_JSON is not valid JSON: {e}", file=sys.stderr)
    sys.exit(3)
if not isinstance(automation, dict):
    print("scaffold.sh: AUTOMATION_JSON must be a JSON object", file=sys.stderr)
    sys.exit(3)
automation.setdefault("auto_close", False)
automation.setdefault("auto_spawn", False)
automation.setdefault("max_live_workers", 1)
automation.setdefault("spawn_ack_timeout_ticks", 3)
automation.setdefault("spawn_argv", [])
for _bkey in ("auto_close", "auto_spawn"):
    if not isinstance(automation[_bkey], bool):
        print(
            f"scaffold.sh: automation.{_bkey}={automation[_bkey]!r} must be a JSON boolean",
            file=sys.stderr,
        )
        sys.exit(3)
for _ikey in ("max_live_workers", "spawn_ack_timeout_ticks"):
    _ival = automation[_ikey]
    # bool is an int subclass in Python -- exclude it explicitly.
    if isinstance(_ival, bool) or not isinstance(_ival, int) or _ival < 1:
        print(
            f"scaffold.sh: automation.{_ikey}={_ival!r} must be a JSON integer >= 1",
            file=sys.stderr,
        )
        sys.exit(3)
_argv = automation["spawn_argv"]
if not isinstance(_argv, list) or any(not isinstance(el, str) or el == "" for el in _argv):
    print(
        f"scaffold.sh: automation.spawn_argv={_argv!r} must be a JSON array of "
        "non-empty strings",
        file=sys.stderr,
    )
    sys.exit(3)
if _argv and "{prompt}" not in _argv:
    print(
        "scaffold.sh: automation.spawn_argv must contain the literal element "
        "\"{prompt}\" (whole-element placeholder the durable prompt path "
        "substitutes into at spawn time)",
        file=sys.stderr,
    )
    sys.exit(3)
# scaffold/track validation parity (B3 fix P3-13): track's runtime verdict
# fail-closed refuses auto_spawn with an empty/placeholder-less spawn_argv,
# so that combination must not scaffold as valid either.
if automation["auto_spawn"] and (not _argv or "{prompt}" not in _argv):
    print(
        "scaffold.sh: automation.auto_spawn=true requires a non-empty "
        "automation.spawn_argv containing the literal \"{prompt}\" element "
        "(track would fail-closed refuse this config at runtime)",
        file=sys.stderr,
    )
    sys.exit(3)
values["AUTOMATION_JSON"] = json.dumps(automation)

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
        # REPOS_JSON, AUTOMATION_JSON) — interpolate raw, never re-escape.
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
# hostile REPOS_JSON/AUTOMATION_JSON) before it ever ships — those keys
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
