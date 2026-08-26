#!/usr/bin/env python3
"""Lint the personal agent skills in this repo.

Checks, per top-level `<skill>/SKILL.md`:
  1. Frontmatter is present and closed (`---` ... `---`).
  2. `name:` exists and equals the skill's directory name.
  3. `description:` exists and is non-empty.
  4. Every relative markdown link target (`](foo.md)`, `](scripts/x.sh)`) exists.

Plus, across every tracked `.md` file in the repo:
  5. Every relative markdown link resolves — against the directory of the file
     containing the link, never the repo root.

Plus, across the whole repo root:
  6. No untracked top-level file or directory is silently dropped by
     .gitignore's deny-by-default allowlist with no rule of its own — see
     check_not_gitignored().
  7. No tracked top-level directory contains a nested .gitignore — see
     check_no_nested_gitignore().

Deliberately NOT checked: cross-skill `/other-skill` references — many legitimately
point at superpowers skills that don't live in this repo, so checking them
here would only produce false positives.

Run locally with `python3 bin/lint-skills.py`; exits non-zero if anything fails.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

# Vendored / non-skill directories that may exist locally but aren't ours to lint
# (used only by the glob fallback when not inside a git work tree).
EXCLUDE_DIRS = {"node_modules", "bin", ".git", ".github"}

LINK_RE = re.compile(r"\]\(([^)]+)\)")


def find_skills(root: Path) -> list[Path]:
    """Top-level `<skill>/SKILL.md` files that belong to this repo.

    Prefer git-tracked files so local runs match CI exactly (CI checks out only
    tracked content — untracked skills synced here by other tooling are not ours).
    """
    try:
        out = subprocess.run(
            ["git", "-C", str(root), "ls-files", "*/SKILL.md"],
            capture_output=True, text=True, check=True,
        ).stdout
        tracked = [
            root / line for line in out.splitlines()
            if line.count("/") == 1  # top-level skills only
        ]
        if tracked:
            return sorted(tracked)
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    return sorted(
        p for p in root.glob("*/SKILL.md")
        if p.parent.name not in EXCLUDE_DIRS and not p.parent.name.startswith(".")
    )


def strip_quotes(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def parse_frontmatter(text: str) -> tuple[dict[str, str] | None, str]:
    """Return (frontmatter_dict, body). frontmatter_dict is None if malformed."""
    if not text.startswith("---"):
        return None, text
    lines = text.splitlines()
    # find closing '---' after line 0
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            fm: dict[str, str] = {}
            for line in lines[1:i]:
                if ":" in line and not line.lstrip().startswith("#"):
                    key, _, val = line.partition(":")
                    fm[key.strip()] = val.strip()
            body = "\n".join(lines[i + 1 :])
            return fm, body
    return None, text


def strip_fenced_code(body: str) -> str:
    """Blank out ``` fenced blocks, keeping line count stable.

    A skill that documents markdown syntax writes example links inside a fence —
    make-pdf shows `![chart](data.png){width=full}` to teach its image options.
    Those are illustrations, not links, and resolving them against the filesystem
    reports four broken links in a skill that has none.
    """
    out, in_fence = [], False
    for line in body.splitlines():
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            out.append("")
            continue
        out.append("" if in_fence else line)
    return "\n".join(out)


def link_targets(body: str) -> list[str]:
    out = []
    for raw in LINK_RE.findall(strip_fenced_code(body)):
        target = raw.strip().split()[0] if raw.strip() else ""  # drop ` "title"`
        target = target.split("#", 1)[0]  # drop #anchor
        if not target:
            continue
        if re.match(r"^[a-z]+://", target) or target.startswith(("/", "mailto:", "#")):
            continue
        out.append(target)
    return out


def check_relative_links(root: Path, errors: list[str], skip: set[Path]) -> tuple[int, int]:
    """Assert every relative markdown link in every tracked `.md` file resolves.

    Targets are resolved against the directory of the file containing the link.
    That base matters: an external review tool once resolved them against the
    repo root instead and reported four perfectly-good links (in
    writing-for-agents, writing-great-skills, contract, probe) as dead.

    Two regions are excluded from the scan:
      - Fenced code blocks — illustrative, not real links (see strip_fenced_code).
      - YAML frontmatter — it is YAML, not markdown prose. A `description:`
        value that mentions `references/foo.md` (probe/SKILL.md does) is a
        plain-text path for the model, not a markdown link; treating
        frontmatter as prose would re-create exactly the false positives this
        check exists to kill. parse_frontmatter() hands back the body only.

    `skip` holds files already link-checked elsewhere (the top-level SKILL.md
    set), so a genuine break there is reported once, not twice.

    Returns (files_scanned, links_checked) for the summary line.
    """
    try:
        out = subprocess.run(
            ["git", "-C", str(root), "ls-files", "*.md"],
            capture_output=True, text=True, check=True,
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return 0, 0  # no git: the tracked-file set is unknowable here
    n_files = n_links = 0
    for line in out.splitlines():
        md = root / line
        if md in skip or not md.is_file():
            continue
        n_files += 1
        _, body = parse_frontmatter(md.read_text(encoding="utf-8"))
        for target in link_targets(body):
            n_links += 1
            if not (md.parent / target).exists():
                errors.append(f"{line}: broken relative link `{target}`")
    return n_files, n_links


def find_unignored_check_candidates(root: Path) -> list[Path]:
    """Every untracked top-level entry that isn't a symlink.

    Symlinked top-level entries are deliberately skipped: those are the
    private skills linked in from a separate private repo, and being
    git-ignored is the *correct* state for them — that's the whole point of
    the deny-by-default allowlist in .gitignore. This check exists to catch
    the opposite mistake: a real, meant-to-be-tracked top-level file or
    directory (a brand-new skill, CONTRIBUTING.md, a docs/ directory —
    anything, not just a directory containing SKILL.md) that got forgotten
    from the allowlist and is therefore silently invisible to `git add`,
    with no error and no warning from git itself.
    """
    try:
        out = subprocess.run(
            ["git", "-C", str(root), "ls-files"],
            capture_output=True, text=True, check=True,
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []  # no git available; nothing we can check here
    tracked_top = {line.split("/", 1)[0] for line in out.splitlines()}
    return sorted(
        p for p in root.iterdir()
        if p.name != ".git"
        and p.name not in tracked_top
        and not p.is_symlink()
    )


def check_not_gitignored(root: Path, errors: list[str]) -> None:
    """Flag any untracked top-level entry `git add` would silently skip.

    A deny-by-default `.gitignore` means an untracked top-level file or
    directory with no matching `!` re-include is invisible to `git add` — no
    error, no warning, just silence; CI can't catch this either, since a file
    that was never staged never reaches CI. That silence is *correct* for
    entries a specific rule already accounts for on purpose (cruft like
    __pycache__, secrets like *.token, scratch like docs/, named
    known-not-ours skill directories) — those are deliberate decisions and
    must stay quiet. It's a real gap for anything caught only by the blanket
    `/*` deny-all with no rule of its own: that's exactly a brand-new skill
    directory, a new root file like CONTRIBUTING.md, or any other top-level
    entry nobody has made a decision about yet.

    We tell the two apart by asking `git check-ignore -v` which .gitignore
    line matched: the bare `/*` deny-all vs. anything more specific. This
    does NOT weaken the allowlist itself — nothing here adds a `!` rule; it
    only decides which existing outcome deserves a loud error instead of
    silence.
    """
    candidates = find_unignored_check_candidates(root)
    if not candidates:
        return
    try:
        result = subprocess.run(
            # --no-index: evaluate .gitignore patterns regardless of whether the
            # path is already tracked. Plain `check-ignore` silently reports
            # tracked paths as "not ignored" even when a pattern matches them,
            # which would hide exactly the forgotten-allowlist-line case this
            # check exists to catch.
            ["git", "-C", str(root), "check-ignore", "--no-index", "-v",
             *[str(p) for p in candidates]],
            capture_output=True, text=True,
        )
    except FileNotFoundError:
        return  # no git available; nothing we can check here
    # Each matched line looks like "<source>:<line-no>:<pattern>\t<path>".
    matched_pattern: dict[str, str] = {}
    for line in result.stdout.splitlines():
        meta, _, path = line.partition("\t")
        matched_pattern[path] = meta.rsplit(":", 1)[-1]
    for p in candidates:
        pattern = matched_pattern.get(str(p))
        if pattern is None:
            continue  # not ignored at all — a plain `git status` already surfaces it
        if pattern != "/*":
            continue  # a specific rule accounts for it on purpose — not our concern
        rel = p.relative_to(root)
        suffix = "/" if p.is_dir() else ""
        errors.append(
            f"{rel}: untracked and silently ignored by the deny-by-default allowlist "
            f"(no rule covers it but the blanket `/*`) — add `!/{rel}{suffix}` to "
            f".gitignore to track it, or a specific ignore rule if it should stay out"
        )


def check_no_nested_gitignore(root: Path, errors: list[str]) -> None:
    """No tracked top-level directory may contain a nested .gitignore.

    .gitignore's deny-by-default allowlist re-includes a skill directory with
    `!/<skill>/`, but that re-inclusion does not reach *inside* the
    directory — rules further down (secrets, cruft) still apply there (see
    the comment above the allowlist in .gitignore). A .gitignore file nested
    inside a re-included directory can add its own `!` pattern that
    un-ignores something the root file deliberately keeps out, e.g.
    `!.slack-bot-token` — silently re-exposing that secret pattern for just
    that one directory. Verified empirically: a nested
    `some-skill/.gitignore` containing `!.slack-bot-token` makes
    `git check-ignore` report the token file as no longer ignored, and
    `git add -n` shows it would actually be staged.

    Disallowing nested .gitignore entirely (rather than trying to parse
    which un-ignore patterns are "secret-shaped", which needs a name
    heuristic that has to be kept in sync forever) is the simpler and more
    maintainable rule here: no skill in this repo has ever needed its own
    .gitignore, so banning the file outright costs nothing and closes the
    whole class of risk, not just today's known secret names.
    """
    try:
        out = subprocess.run(
            ["git", "-C", str(root), "ls-files"],
            capture_output=True, text=True, check=True,
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return
    tracked_top_dirs = {
        line.split("/", 1)[0] for line in out.splitlines() if "/" in line
    }
    for name in sorted(tracked_top_dirs):
        d = root / name
        if not d.is_dir() or d.is_symlink():
            continue
        for gi in sorted(d.rglob(".gitignore")):
            rel = gi.relative_to(root)
            errors.append(
                f"{rel}: nested .gitignore is not allowed inside a tracked skill "
                f"directory — its allowlist re-include does not extend to un-ignoring "
                f"secrets inside it; put any rule it needs in the root .gitignore instead"
            )


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    errors: list[str] = []
    skills = find_skills(root)
    if not skills:
        print("lint-skills: no SKILL.md files found", file=sys.stderr)
        return 1

    check_not_gitignored(root, errors)
    check_no_nested_gitignore(root, errors)
    n_md, n_links = check_relative_links(root, errors, skip=set(skills))

    for skill in skills:
        rel = skill.relative_to(root)
        dir_name = skill.parent.name
        text = skill.read_text(encoding="utf-8")

        fm, body = parse_frontmatter(text)
        if fm is None:
            errors.append(f"{rel}: missing or unclosed YAML frontmatter (`---` ... `---`)")
            continue

        name = strip_quotes(fm.get("name", ""))
        if not name:
            errors.append(f"{rel}: frontmatter missing `name`")
        elif name != dir_name:
            errors.append(f"{rel}: `name: {name}` does not match directory `{dir_name}`")

        if not strip_quotes(fm.get("description", "")):
            errors.append(f"{rel}: frontmatter missing non-empty `description`")

        for target in link_targets(body):
            if not (skill.parent / target).exists():
                errors.append(f"{rel}: broken relative link `{target}`")

    if errors:
        print(f"lint-skills: {len(errors)} problem(s) found:\n", file=sys.stderr)
        for e in errors:
            print(f"  ✗ {e}", file=sys.stderr)
        return 1

    print(
        f"lint-skills: OK — {len(skills)} skills passed; "
        f"{n_links} relative links resolved across {n_md} other tracked markdown files"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
