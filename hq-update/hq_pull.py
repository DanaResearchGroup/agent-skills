#!/usr/bin/env python3
"""hq_pull.py — deterministic status pulls for the HQ daily refresh.

Two data sources, both cheap:
  --prs    Alon's open PRs (authored + review-requested) with live CI / mergeable / review state.
  --scan   Walk HQ/ nodes; compute deadline countdown, staleness, dead pointers, and a
           suggested traffic light from importance (manual) x urgency (derived).

Emits Markdown a CC `hq-update` session pastes into HQ boards/nodes. It NEVER writes files
itself — the session does, and only inside HQ/ (see HQ/CLAUDE.md). Schema/traffic-light rules
live in HQ/CLAUDE.md; this script only computes, it does not define policy.
"""
import argparse, json, os, re, subprocess, sys
from datetime import datetime, date

GH_USER = "alongd"


def _run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=90).stdout
    except Exception as e:
        return f"__ERR__ {e}"


def _loads(raw):
    """Parse gh's --json stdout, tolerating non-JSON (auth notice, warning) instead of
    aborting the whole run. Returns the parsed value, or None on any parse failure."""
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return None


def _ci(pr):
    roll = pr.get("statusCheckRollup") or []
    states = [c.get("conclusion") or c.get("state") for c in roll]
    if not states:
        return "—"
    return "green" if all(s in ("SUCCESS", "NEUTRAL", "SKIPPED", None) for s in states) else "red"


def pull_prs():
    out = ["## PR watch-list (live)", ""]
    for label, flag in (("Authored", f"--author={GH_USER}"), ("Review-requested", f"--review-requested={GH_USER}")):
        raw = _run(["gh", "search", "prs", flag, "--state=open", "--limit=40", "--json",
                    "repository,number,title,isDraft"])
        if raw.startswith("__ERR__") or not raw.strip():
            out.append(f"### {label}\n_(gh error or none: {raw.strip()[:60]})_\n")
            continue
        prs = _loads(raw)
        if prs is None:
            out.append(f"### {label}\n_(gh returned non-JSON: {raw.strip()[:60]})_\n")
            continue
        out.append(f"### {label} ({len(prs)})")
        # enrich each PR with CI/mergeable/review (one gh view per PR — bounded by --limit)
        for p in prs:
            repo = p["repository"]["nameWithOwner"]
            num = p["number"]
            detail = _run(["gh", "pr", "view", str(num), "-R", repo, "--json",
                           "mergeable,reviewDecision,statusCheckRollup"])
            ci = mrg = rev = "?"
            if not detail.startswith("__ERR__") and detail.strip():
                d = _loads(detail)
                if d is not None:  # non-JSON → leave fields as "?" and keep going
                    ci = _ci(d)
                    mrg = d.get("mergeable") or "?"
                    rev = d.get("reviewDecision") or "—"
            draft = " ·draft" if p.get("isDraft") else ""
            flag_ci = "🔴" if ci == "red" else ("🟢" if ci == "green" else "·")
            need_rebase = " ·needs-rebase" if mrg == "CONFLICTING" else ""
            url = f"https://github.com/{repo}/pull/{num}"  # PR refs are always live links
            out.append(f"- {flag_ci} **[{repo}#{num}]({url})** — {p['title'][:58]} "
                       f"(ci={ci} merge={mrg} review={rev}{need_rebase}{draft})")
        out.append("")
    return "\n".join(out)


# ---- HQ node scan -------------------------------------------------------------
FM_RE = re.compile(r"^---\s*$")


def _frontmatter(path):
    """Parse ONLY a real top-of-file YAML frontmatter block (first line must be ---).
    Never scans the body, so `---` fences inside code examples can't false-match."""
    fm = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        first = f.readline()
        if not FM_RE.match(first):
            return fm  # no top-of-file frontmatter → not a node
        for line in f:
            if FM_RE.match(line):
                break
            if ":" in line:
                k, _, v = line.partition(":")
                v = v.split("  #")[0].split(" #")[0]  # drop trailing inline comment
                fm[k.strip()] = v.strip().strip('"').strip("'")
    return fm


def _days_until(ddmmyyyy):
    try:
        d = datetime.strptime(ddmmyyyy, "%d/%m/%Y").date()
        return (d - date.today()).days
    except Exception:
        return None


def _light(importance, urgent):
    try:
        imp = int(importance)
    except Exception:
        imp = 0
    important = imp >= 4
    if important and urgent:
        return "🔴"
    if important or urgent:
        return "🟡"
    return "🔵"


def scan(vault):
    hq = os.path.join(vault, "HQ")
    lines = ["## Node scan (deadlines · staleness · pointers · suggested light)", ""]
    stale_days = 21
    for root, _dirs, files in os.walk(hq):
        if os.sep + "_archive" in root:
            continue
        for fn in files:
            if not fn.endswith(".md"):
                continue
            p = os.path.join(root, fn)
            fm = _frontmatter(p)
            if fm.get("type") != "hq-node":
                continue
            rel = os.path.relpath(p, vault)
            dl = fm.get("deadline", "")
            du = _days_until(dl) if dl else None
            urgent = du is not None and du <= 3
            if str(fm.get("urgency", "")).lower() == "high":
                urgent = True
            light = _light(fm.get("importance"), urgent)
            # `blocked` is ORTHOGONAL to the light: the dot stays honest (importance x urgency);
            # a blocked node just carries a ⛔ marker beside it — blocked != urgent.
            blocked = str(fm.get("blocked", "")).lower() in ("true", "yes", "1")
            marker = " ⛔" if blocked else ""
            note = []
            if blocked:
                note.append("⛔ blocked — needs an unblocking action")
            if du is not None:
                note.append(f"⏳{du}d" if du >= 0 else f"⚠OVERDUE {abs(du)}d")
            up = _days_until(fm.get("updated", "")) if fm.get("updated") else None
            if up is not None and -up > stale_days:
                note.append(f"🕸 stale {-up}d")
            loc = fm.get("local", "")
            if loc:
                lp = os.path.expanduser(loc.strip('"').split()[0]) if loc.strip() else ""
                if lp and not os.path.exists(lp):
                    note.append("⚠ dead local:")
            cur = fm.get("light", "")
            drift = "" if cur == light else f"  (was {cur} → suggest {light})"
            lines.append(f"- {light}{marker} `{rel}` — {fm.get('title','?')} "
                         f"[{' · '.join(note) if note else 'ok'}]{drift}")
    if len(lines) == 2:
        lines.append("_(no hq-node files found)_")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prs", action="store_true")
    ap.add_argument("--scan", action="store_true")
    ap.add_argument("--vault", default=os.path.expanduser("~/Dropbox/Apps/remotely-save/Vault"))
    a = ap.parse_args()
    if not (a.prs or a.scan):
        a.prs = a.scan = True
    blocks = []
    if a.scan:
        blocks.append(scan(a.vault))
    if a.prs:
        blocks.append(pull_prs())
    print(("\n\n".join(blocks)).strip())


if __name__ == "__main__":
    main()
