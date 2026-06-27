#!/usr/bin/env python3
"""Lint the personal agent skills in this repo.

Checks, per top-level `<skill>/SKILL.md`:
  1. Frontmatter is present and closed (`---` ... `---`).
  2. `name:` exists and equals the skill's directory name.
  3. `description:` exists and is non-empty.
  4. Every relative markdown link target (`](foo.md)`, `](scripts/x.sh)`) exists.

Deliberately NOT checked: cross-skill `/other-skill` references — many legitimately
point at gstack / superpowers skills that don't live in this repo, so checking them
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
EXCLUDE_DIRS = {"gstack", "node_modules", "bin", ".git", ".github"}

LINK_RE = re.compile(r"\]\(([^)]+)\)")


def find_skills(root: Path) -> list[Path]:
    """Top-level `<skill>/SKILL.md` files that belong to this repo.

    Prefer git-tracked files so local runs match CI exactly (CI checks out only
    tracked content — untracked, locally-synced gstack skills are not ours).
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


def link_targets(body: str) -> list[str]:
    out = []
    for raw in LINK_RE.findall(body):
        target = raw.strip().split()[0] if raw.strip() else ""  # drop ` "title"`
        target = target.split("#", 1)[0]  # drop #anchor
        if not target:
            continue
        if re.match(r"^[a-z]+://", target) or target.startswith(("/", "mailto:", "#")):
            continue
        out.append(target)
    return out


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    errors: list[str] = []
    skills = find_skills(root)
    if not skills:
        print("lint-skills: no SKILL.md files found", file=sys.stderr)
        return 1

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

    print(f"lint-skills: OK — {len(skills)} skills passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
