"""Read-only scanner over the proposals archive: what open calls exist, what
state each one is in, and the OPEN.md roster renderer.

Nothing in this module ever touches the filesystem for writing - publishing
the roster this module renders is entirely the caller's job through
lib/publish.py (SAFETY.md #3). This module only reads: it lists call
directories, reads topics.md files to check ownership/completeness, reads
the optional private bootstrap-states file (see load_bootstrap_states), and
parses whatever OPEN.md text the caller hands it back in.
"""

from __future__ import annotations

import calendar
import json
import os
import re
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

from lib.paths import (
    PathRefused,
    _default_root,
    is_call_dir,
    is_conflicted_copy,
    owned_artifact_conflicts,
)
from lib.publish import is_agent_owned, is_complete


# ---------------------------------------------------------------------------
# CallInfo
# ---------------------------------------------------------------------------

@dataclass
class CallInfo:
    name: str
    path: Path
    deadline: date | None
    deadline_precision: str  # "day" | "month" | "none"
    funder: str
    material: list[Path] = field(default_factory=list)
    has_topics: bool = False
    topics_versions: list[int] = field(default_factory=list)
    frozen: list[Path] = field(default_factory=list)
    state: str = "new"


# ---------------------------------------------------------------------------
# Deadline parsing
# ---------------------------------------------------------------------------

# Leading "YYYY.MM" or "YYYY.MM.DD" at the start of a call folder name, e.g.
# "2026.10 ExampleFund" or "2026.04.21 SampleProg CALL-XX-2026-01-TOPIC-04".
_DATE_RE = re.compile(r"^(\d{4})\.(\d{2})(?:\.(\d{2}))?(?:\s+(.*))?$")


def _parse_deadline(name: str) -> tuple[date | None, str, str]:
    """Parse the leading date out of a call folder name.

    Returns (deadline, precision, rest_of_name). Month-only precision
    resolves to the LAST day of that month - a call due "in October" is not
    missed by assuming the 1st. A name that does not start with a parseable
    date returns (None, "none", name) and never raises: callers must be able
    to report an unparseable call, not crash on it.
    """
    m = _DATE_RE.match(name)
    if not m:
        return None, "none", name

    year_s, month_s, day_s, rest = m.groups()
    rest = rest or ""
    try:
        year = int(year_s)
        month = int(month_s)
        if not (1 <= month <= 12):
            return None, "none", name
        if day_s is not None:
            day = int(day_s)
            deadline = date(year, month, day)
            return deadline, "day", rest
        last_day = calendar.monthrange(year, month)[1]
        deadline = date(year, month, last_day)
        return deadline, "month", rest
    except ValueError:
        # Out-of-range month/day (e.g. .13 or .31 in a 30-day month) - treat
        # as unparseable rather than raising, per the "never crash" contract.
        return None, "none", name


def _funder_from(rest: str, name: str) -> str:
    """Best-effort funder token: the first whitespace-separated token after
    the date, or the first token of the whole name if there was no date."""
    source = rest if rest else name
    tokens = source.split()
    return tokens[0] if tokens else ""


# ---------------------------------------------------------------------------
# Material / topics.md / frozen inspection
# ---------------------------------------------------------------------------

_TOPICS_NAME_RE = re.compile(r"^topics(-v\d+)?\.md$")
_TOPICS_V_RE = re.compile(r"^topics-v(\d+)\.md$")


def _scan_material(call_dir: Path) -> list[Path]:
    """Top-level call-material files: everything except topics*.md (an owned
    artifact, not material), dotfiles, and Dropbox conflicted copies."""
    material: list[Path] = []
    try:
        entries = sorted(os.scandir(call_dir), key=lambda e: e.name)
    except OSError:
        return material
    for entry in entries:
        name = entry.name
        if name.startswith("."):
            continue
        try:
            if not entry.is_file(follow_symlinks=False):
                continue
        except OSError:
            continue
        if is_conflicted_copy(name):
            continue
        if _TOPICS_NAME_RE.match(name):
            continue
        material.append(Path(entry.path))
    return material


def _scan_topics(call_dir: Path) -> tuple[bool, list[int]]:
    topics_path = call_dir / "topics.md"
    has_topics = False
    if topics_path.is_file() and not os.path.islink(topics_path):
        try:
            text = topics_path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            # UnicodeDecodeError is NOT an OSError. A single legacy-encoded
            # topics.md - entirely plausible in an archive this old, synced
            # across machines - would otherwise abort the whole scan rather
            # than costing us one call. An unreadable file simply is not
            # provably agent-owned, which is the safe conclusion: it means we
            # never treat it as ours and never touch it.
            text = ""
        has_topics = is_agent_owned(text) and is_complete(text)

    versions: list[int] = []
    try:
        entries = os.scandir(call_dir)
    except OSError:
        entries = []
    for entry in entries:
        m = _TOPICS_V_RE.match(entry.name)
        if m:
            try:
                if entry.is_file(follow_symlinks=False):
                    versions.append(int(m.group(1)))
            except OSError:
                continue
    return has_topics, sorted(versions)


# ---------------------------------------------------------------------------
# find_calls / days_until
# ---------------------------------------------------------------------------

def find_calls(root: Path) -> list[CallInfo]:
    """Every top-level call directory under `root`, sorted by folder name."""
    root = Path(root)
    try:
        entries = sorted(os.scandir(root), key=lambda e: e.name)
    except OSError:
        return []

    calls: list[CallInfo] = []
    for entry in entries:
        p = Path(entry.path)
        if not is_call_dir(p):
            continue
        name = entry.name
        deadline, precision, rest = _parse_deadline(name)
        funder = _funder_from(rest, name)
        material = _scan_material(p)
        has_topics, topics_versions = _scan_topics(p)
        frozen = owned_artifact_conflicts(p)

        calls.append(
            CallInfo(
                name=name,
                path=p,
                deadline=deadline,
                deadline_precision=precision,
                funder=funder,
                material=material,
                has_topics=has_topics,
                topics_versions=topics_versions,
                frozen=frozen,
                state="new",
            )
        )

    calls.sort(key=lambda c: c.name)
    return calls


def days_until(call: CallInfo, today: date) -> int | None:
    """Days from `today` to the call's deadline, or None if the deadline is
    unparseable. Negative when the deadline is in the past."""
    if call.deadline is None:
        return None
    return (call.deadline - today).days


# ---------------------------------------------------------------------------
# State model
# ---------------------------------------------------------------------------

_VALID_STATES = {"new", "open", "submitted", "ignore", "blocked"}

# Bootstrap states live in an OPTIONAL per-machine JSON file, deliberately
# OUTSIDE this (public) repo: which calls exist and what state each is in is
# private information about the group's funding strategy. The file's default
# home is a "_"-prefixed folder inside the archive, which is_call_dir() /
# find_calls() already skip, so it is never mistaken for a call folder.
# Format: one flat JSON object mapping call folder name -> state, e.g.
# {"2026.10 ExampleFund": "open"}. It is used ONLY as a fallback for a call
# that has no row in an existing OPEN.md (or when OPEN.md does not exist at
# all) - it must never override a state a human has since written into
# OPEN.md. See resolve_states() below.


def bootstrap_states_path() -> Path:
    """The bootstrap-states file location: $AUTO_PROPOSALS_BOOTSTRAP_STATES
    if set, else `<root>/_auto-proposals/bootstrap-states.json`. The root is
    re-read from the environment on every call (like paths._default_root's
    contract) so tests swapping env vars between cases see fresh values."""
    override = os.environ.get("AUTO_PROPOSALS_BOOTSTRAP_STATES")
    if override:
        return Path(override).expanduser()
    return _default_root() / "_auto-proposals" / "bootstrap-states.json"


def load_bootstrap_states() -> dict[str, str]:
    """Read the bootstrap-states file, if there is one.

    A missing file is the normal case on most machines and returns {} - no
    seed states, OPEN.md stays authoritative. But a file that EXISTS and is
    unreadable, is not valid JSON, is not a JSON object, or carries a value
    outside _VALID_STATES raises PathRefused naming the file: silently
    degrading a corrupt file to "no states" would silently change which
    calls get worked on. Deliberately uncached - every call re-reads the
    file, so no module-level state can bleed between test cases.
    """
    path = bootstrap_states_path()
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return {}
    except UnicodeDecodeError as exc:
        # Loud, not silent: a config file we cannot decode must not degrade to
        # "no bootstrap states", because that would quietly change which calls
        # are considered workable.
        raise PathRefused(
            f"bootstrap-states file {path} is not valid UTF-8: {exc}"
        ) from exc
    except OSError as exc:
        raise PathRefused(f"could not read bootstrap-states file {path}: {exc}") from exc

    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise PathRefused(f"bootstrap-states file {path} is not valid JSON: {exc}") from exc

    if not isinstance(data, dict):
        raise PathRefused(
            f"bootstrap-states file {path} must hold a single JSON object "
            f"(call folder name -> state), got {type(data).__name__}"
        )

    for call, state in data.items():
        if not isinstance(state, str) or state not in _VALID_STATES:
            raise PathRefused(
                f"bootstrap-states file {path}: state {state!r} for call "
                f"{call!r} is not one of {sorted(_VALID_STATES)}"
            )

    return data

# Table row: "| call | deadline | days | state | topics | note |"
_TABLE_ROW_RE = re.compile(r"^\|(.+)\|\s*$")


def read_states(open_md_text: str) -> dict[str, str]:
    """Parse the per-call state markers out of an existing OPEN.md.

    Tolerant of hand-editing: unknown state words, reordered rows, extra
    prose around the table, and missing rows are all fine - we just read
    whatever's in the "state" column (4th column) of every table row that
    looks like a data row, and skip anything that doesn't.
    """
    states: dict[str, str] = {}
    for line in open_md_text.splitlines():
        m = _TABLE_ROW_RE.match(line.strip())
        if not m:
            continue
        cells = [c.strip() for c in m.group(1).split("|")]
        if len(cells) < 4:
            continue
        call = cells[0]
        if not call:
            continue
        # Skip header row and markdown separator rows ("---", ":---:", ...).
        if call.lower() == "call":
            continue
        if re.fullmatch(r"[-: ]+", call):
            continue
        state = cells[3]
        if not state or re.fullmatch(r"[-: ]+", state):
            continue
        states[call] = state
    return states


def resolve_states(calls: list[CallInfo], existing_open_md: str | None) -> None:
    """Set `.state` on each call in place.

    Precedence: an existing OPEN.md's state for that call always wins; else
    the bootstrap-states file (load_bootstrap_states) is used as a one-time
    seed (only meaningful the first time OPEN.md is generated); else "new".
    The bootstrap file is never consulted for a call that already has a row
    in OPEN.md, even if that row's state differs from what the file says -
    the human's edit to the live file always wins.
    """
    existing_states = read_states(existing_open_md) if existing_open_md else {}
    bootstrap_states = load_bootstrap_states()
    for call in calls:
        if call.name in existing_states:
            call.state = existing_states[call.name]
        elif call.name in bootstrap_states:
            call.state = bootstrap_states[call.name]
        else:
            call.state = "new"


def workable(calls: list[CallInfo]) -> list[CallInfo]:
    """The calls a run may actually act on: state new/open, not frozen, and
    (stage 1) not already carrying a complete, agent-owned topics.md."""
    return [
        c
        for c in calls
        if c.state in ("new", "open") and not c.frozen and not c.has_topics
    ]


# ---------------------------------------------------------------------------
# Renderer
# ---------------------------------------------------------------------------

def _fmt_deadline(call: CallInfo) -> str:
    if call.deadline is None:
        return "?"
    s = call.deadline.isoformat()
    if call.deadline_precision == "month":
        s += " (month-precision)"
    return s


def _fmt_days(call: CallInfo, today: date) -> str:
    d = days_until(call, today)
    if d is None:
        return "?"
    return str(d)


def _fmt_topics(call: CallInfo) -> str:
    if call.has_topics:
        return "yes"
    if call.topics_versions:
        return f"draft (v{max(call.topics_versions)})"
    return "no"


def render_open_md(calls: list[CallInfo], *, today: date) -> str:
    """Render the OPEN.md body (not the frontmatter - the caller adds that
    via lib.publish.render_frontmatter). This file is regenerated on every
    run, but its `state` column is human-owned: resolve_states() reads it
    back out of the previous version before a new one is written, so a
    human's edit to that column always survives a regeneration.
    """
    lines: list[str] = []
    lines.append(
        "This roster is regenerated by auto-proposals on every scan. "
        "Every column except **state** is recomputed from the archive each "
        "time; the **state** column is owned by you (Alon) - hand-edit it "
        "freely, it is read back out of this file before the next "
        "regeneration and will never be overwritten by a default."
    )
    lines.append("")
    lines.append("| call | deadline | days | state | topics | note |")
    lines.append("|---|---|---|---|---|---|")

    frozen_calls = [c for c in calls if c.frozen]
    undated_calls = [c for c in calls if c.deadline is None]

    for call in calls:
        note = ""
        if call.frozen:
            note = "frozen - see below"
        elif call.deadline is None:
            note = "unparseable date - see below"
        lines.append(
            "| {call} | {deadline} | {days} | {state} | {topics} | {note} |".format(
                call=call.name,
                deadline=_fmt_deadline(call),
                days=_fmt_days(call, today),
                state=call.state,
                topics=_fmt_topics(call),
                note=note,
            )
        )

    lines.append("")
    lines.append("## Frozen calls")
    lines.append("")
    if not frozen_calls:
        lines.append("None.")
    else:
        lines.append(
            "These calls have Dropbox conflicted copies of an owned artifact "
            "next to them. auto-proposals does no stage work on them until a "
            "human reconciles the conflict by hand (SAFETY.md #5)."
        )
        lines.append("")
        for call in frozen_calls:
            names = ", ".join(p.name for p in call.frozen)
            lines.append(f"- **{call.name}**: {names}")

    lines.append("")
    lines.append("## Calls with no parseable date")
    lines.append("")
    if not undated_calls:
        lines.append("None.")
    else:
        lines.append(
            "These call folder names don't start with a `YYYY.MM` or "
            "`YYYY.MM.DD` prefix, so no deadline could be parsed. Rename the "
            "folder to add one, or track the deadline by hand."
        )
        lines.append("")
        for call in undated_calls:
            lines.append(f"- **{call.name}**")

    lines.append("")
    return "\n".join(lines)
