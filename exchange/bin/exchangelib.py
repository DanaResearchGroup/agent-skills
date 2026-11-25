"""Shared parts of exchange-lint and exchange-init: the fixed tree, the planes file, AGENTS.md.

The tree's shape lives here once, so the generator and the checker cannot drift apart.
"""

from __future__ import annotations

import re
import string
from dataclasses import dataclass
from pathlib import Path

HUB = "hl"
SIDES = ("hl", "peer")
ZONES = ("any", "hl-only")
DEFAULT_PLANES = Path("~/.config/factory/planes")
TEMPLATE = Path(__file__).resolve().parent.parent / "templates" / "AGENTS.md.tmpl"

AGENTS = "AGENTS.md"
ARCHIVE = "archive"
STAMP = ".last-transfer"  # local, tool-owned; written by the transport on the receiving side
SHOW_ME = "show-me"
MANIFEST = "MANIFEST.sha256"

SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")

# The kinds under each direction. `to-peer` stands for `to-<peer>`.
TO_PEER_KINDS = ("instructions", "data")
TO_HL_KINDS = ("artifacts", "data", "gates")


class CannotRun(Exception):
    """The tool could not run: exit 2."""


@dataclass(frozen=True)
class Plane:
    slug: str
    repo: str
    owning_persona: str
    zone: str


def peer_slug(name: str) -> str:
    slug = name.strip().lower()
    if not SLUG_RE.match(slug):
        raise CannotRun(f"--peer {name!r} is not a slug (lowercase letters, digits, '-')")
    if slug == HUB:
        raise CannotRun("--peer names the other machine; it cannot be 'hl', the hub")
    return slug


def directions(peer: str) -> dict[str, tuple[str, ...]]:
    """Direction folder -> its kinds."""
    return {f"to-{peer}": TO_PEER_KINDS, f"to-{HUB}": TO_HL_KINDS}


def inbound(side: str, peer: str) -> str:
    """The direction folder this side only reads (the other side writes it)."""
    return f"to-{HUB}" if side == "hl" else f"to-{peer}"


def read_planes(path: Path) -> dict[str, Plane]:
    """Parse the planes file: `slug repo owning_persona zone` per row, `#` comments."""
    try:
        text = path.expanduser().read_text()
    except OSError as e:
        raise CannotRun(f"cannot read the planes file {path}: {e.strerror}") from None
    planes: dict[str, Plane] = {}
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        cols = line.split()
        if len(cols) != 4:
            raise CannotRun(f"planes file line {n}: want 4 columns, got {len(cols)}")
        plane = Plane(*cols)
        if not SLUG_RE.match(plane.slug):
            raise CannotRun(f"planes file line {n}: {plane.slug!r} is not a slug")
        if plane.zone not in ZONES:
            raise CannotRun(f"planes file line {n}: zone {plane.zone!r} is not one of {ZONES}")
        if plane.slug in planes:
            raise CannotRun(f"planes file line {n}: plane {plane.slug!r} is listed twice")
        planes[plane.slug] = plane
    return planes


def tree_dirs(peer: str, planes: dict[str, Plane]) -> list[str]:
    """Every folder exchange-init writes, relative to the tree root."""
    shared = sorted(p.slug for p in planes.values() if p.zone == "any")
    out = [ARCHIVE]
    for direction, kinds in directions(peer).items():
        out.append(direction)
        for kind in kinds:
            out.append(f"{direction}/{kind}")
            for slug in shared:
                out.append(f"{direction}/{kind}/{slug}")
                if kind == "artifacts":
                    out.append(f"{direction}/{kind}/{slug}/{SHOW_ME}")
    return out


def _tree_block(peer: str) -> str:
    rows = [
        ("./", ""),
        (f"├── {AGENTS}", "this file; tool-owned, read-only"),
        (f"├── to-{peer}/", f"HL writes; {peer.upper()} only reads"),
        ("│   ├── instructions/<plane>/", "orders, briefs, prompts"),
        ("│   └── data/<plane>/<item>/", "inputs, each with MANIFEST.sha256"),
        ("├── to-hl/", f"{peer.upper()} writes; HL only reads"),
        ("│   ├── artifacts/<plane>/", "pages, figures, reports for the owner"),
        ("│   │   └── show-me/", ""),
        ("│   ├── data/<plane>/<item>/", "results, each with MANIFEST.sha256"),
        ("│   └── gates/<plane>/", "a PM's question for its owning seat"),
        ("└── archive/<YYYY-MM>/", "moved by a tool after 30 days; never write here"),
    ]
    width = max(len(left) for left, _ in rows) + 2
    return "\n".join(f"{left.ljust(width)}# {note}" if note else left for left, note in rows)


def render_agents(side: str, peer: str) -> str:
    up = peer.upper()
    if side == "hl":
        side_line = (f"This copy is on HL. Here you write only under `to-{peer}/`. "
                     f"`to-hl/` is read-only to you.")
    else:
        side_line = (f"This copy is on {up}. Here you write only under `to-hl/`. "
                     f"`to-{peer}/` is read-only to you.")
    return string.Template(TEMPLATE.read_text()).substitute(
        peer=peer, PEER=up, side_line=side_line, tree=_tree_block(peer))
