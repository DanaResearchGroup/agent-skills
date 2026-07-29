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
import sys
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

from lib.paths import (
    PathRefused,
    _default_root,
    is_call_dir,
    is_conflicted_copy,
    owned_artifact_conflicts,
    root_artifact_conflicts,
)
from lib.publish import is_agent_owned, is_complete, read_owned


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
    """Top-level call-material files: everything except owned artifacts,
    dotfiles, and Dropbox conflicted copies.

    Since full draft proposals are written into the call folder itself, this
    has to exclude them too. If it did not, a run would read its own previous
    draft back as though it were part of the call's own material, quote it as
    if the funder had written it, and get more confident with every version -
    a feedback loop, and the kind that looks like better grounding.

    Ownership here is decided by frontmatter, never by the filename, because
    Alon's own files use exactly the same `YYYY.MM.DD <letter> <name>`
    convention; a name-only rule would silently hide his documents from the
    grounding step.
    """
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
        if _is_owned_artifact_file(Path(entry.path)):
            continue
        material.append(Path(entry.path))
    return material


def _is_owned_artifact_file(path: Path) -> bool:
    """True for a file auto-proposals wrote: a markdown artifact whose
    frontmatter claims it, or the PDF companion of one.

    A companion carries no frontmatter, so it is identified by its markdown
    sibling exactly as the chokepoint does it.
    """
    if path.suffix == ".pdf":
        sibling = path.with_suffix(".md")
        if not sibling.is_file():
            return False
        path = sibling
    elif path.suffix != ".md":
        return False
    try:
        return is_agent_owned(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError):
        # Unreadable means "not provably ours", which keeps it visible as
        # material rather than silently dropping a file from the grounding.
        return False


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


def skip_reasons(call: CallInfo) -> list[str]:
    """Every reason this call is not workable, most serious first; empty when
    it is workable.

    workable() is defined in terms of this helper on purpose. SKILL.md
    requires every run to report what it did NOT do, and a report that
    computed "why skipped" separately from the filter that actually runs
    would eventually disagree with it - naming one reason while the filter
    dropped the call for another, or listing a call as skipped when it was
    worked. Deriving both from one function makes that drift impossible.
    """
    reasons: list[str] = []
    if call.frozen:
        names = ", ".join(sorted(p.name for p in call.frozen))
        reasons.append(f"frozen - Dropbox conflicted copy present: {names}")
    if call.state not in ("new", "open"):
        reasons.append(f"state is {call.state!r}, not new/open")
    if call.has_topics:
        reasons.append("topics.md already published (stage 1 is done here)")
    return reasons


# A ticked checkbox anywhere in an agent-owned outline means "write the
# draft". Deliberately ANY ticked box rather than one at a fixed line: Alon
# hand-edits these files (he added two whole topics to an RSCC topics.md by
# hand), and a gate that only recognises a checkbox in the exact position the
# generator put it would silently ignore an approval he typed himself. The
# cost of being permissive is bounded - the worst case is drafting something
# he marked for another reason, and a draft is never submitted by this skill.
_TICKED_RE = re.compile(r"^\s*[-*]\s*\[[xX]\]", re.MULTILINE)


def is_approved(text: str) -> bool:
    """True if an artifact carries at least one ticked checkbox."""
    return bool(_TICKED_RE.search(text))


def approved_outlines(call_dir: Path) -> list[Path]:
    """Every agent-owned outline in `call_dir` that Alon has ticked.

    Ownership is checked before approval: a human's own notes file dropped
    into outlines/ with a ticked box is not an instruction to this skill.
    Conflicted copies are skipped - a frozen call does no stage work at all,
    and this keeps the two checks from disagreeing.
    """
    out: list[Path] = []
    outlines_dir = Path(call_dir) / "outlines"
    try:
        entries = sorted(os.scandir(outlines_dir), key=lambda e: e.name)
    except OSError:
        return out
    for entry in entries:
        if not entry.name.endswith(".md") or is_conflicted_copy(entry.name):
            continue
        try:
            if not entry.is_file(follow_symlinks=False):
                continue
            text = Path(entry.path).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        if is_agent_owned(text) and is_approved(text):
            out.append(Path(entry.path))
    return out


def workable(calls: list[CallInfo]) -> list[CallInfo]:
    """The calls a run may actually act on: state new/open, not frozen, and
    (stage 1) not already carrying a complete, agent-owned topics.md."""
    return [c for c in calls if not skip_reasons(c)]


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


# ---------------------------------------------------------------------------
# CLI
#
# SKILL.md step 1 tells the agent to run `python3 -m lib.scan` and read the
# open calls off its output. Without this block that command exits 0 having
# printed nothing, and a run that trusted it would read "no calls" as
# "nothing open" - a silent, total loss of coverage that looks like a clean
# run. The CLI is strictly read-only: it never writes to the archive.
# ---------------------------------------------------------------------------

def _fmt_deadline_compact(call: CallInfo) -> str:
    """Terminal-column form of the deadline. _fmt_deadline() spells out
    "(month-precision)", which is right in OPEN.md but 28 characters wide -
    enough to overflow its column here and shove every later column out of
    alignment, which is exactly how a roster becomes unreadable."""
    if call.deadline is None:
        return "?"
    s = call.deadline.isoformat()
    if call.deadline_precision == "month":
        s += " (m)"
    return s


def _deadline_sort_key(call: CallInfo) -> tuple[bool, date, str]:
    """Nearest deadline first, undated calls last. A call with no parseable
    date is not urgent - it is unknown - so it must not sort to the top and
    push a real deadline down the list."""
    return (call.deadline is None, call.deadline or date.max, call.name)


def scan_archive(root: Path) -> tuple[list[CallInfo], list[Path]]:
    """The whole read-only scan: every call with its state resolved from the
    existing OPEN.md, plus any conflicted copies of OPEN.md itself.

    A conflicted OPEN.md is reported rather than ignored because it blocks
    the roster regeneration in step 2, and a run that quietly skipped that
    step would leave a stale roster looking current.
    """
    root = Path(root)
    found = read_owned(root, "OPEN.md")
    calls = find_calls(root)
    resolve_states(calls, found[0] if found else None)
    return calls, root_artifact_conflicts(root, "OPEN")


def render_report(
    calls: list[CallInfo],
    *,
    root: Path,
    today: date,
    open_md_conflicts: list[Path] | None = None,
) -> str:
    """The human/agent-facing roster written to stdout. Every call appears
    exactly once in the table, and every call that is not workable appears
    again under its reason - so the two lists always add up."""
    work = workable(calls)
    work_names = {c.name for c in work}
    lines: list[str] = []

    lines.append(f"root:  {root}")
    lines.append(f"today: {today.isoformat()}")
    lines.append(f"calls: {len(calls)} total, {len(work)} workable")
    lines.append("")

    if open_md_conflicts:
        lines.append(
            "WARNING: OPEN.md has Dropbox conflicted copies next to it - the "
            "roster cannot be regenerated until a human reconciles them:"
        )
        for p in open_md_conflicts:
            lines.append(f"  - {p.name}")
        lines.append("")

    if not calls:
        lines.append(
            "No call folders found. Either the archive root is wrong, or "
            "every top-level folder is `_`-prefixed. This is reported rather "
            "than returned as an empty success, because 'no calls' and "
            "'nothing open' are not the same statement."
        )
        return "\n".join(lines) + "\n"

    header = (
        f"{'W':<2} {'state':<9} {'deadline':<14} {'days':>5}  "
        f"{'topics':<14} {'frz':<3} call"
    )
    lines.append(header)
    lines.append("-" * len(header))
    for call in sorted(calls, key=_deadline_sort_key):
        lines.append(
            "{w:<2} {state:<9} {deadline:<14} {days:>5}  "
            "{topics:<14} {frz:<3} {name}".format(
                w="*" if call.name in work_names else "",
                state=call.state,
                deadline=_fmt_deadline_compact(call),
                days=_fmt_days(call, today),
                topics=_fmt_topics(call),
                frz="YES" if call.frozen else "-",
                name=call.name,
            )
        )

    lines.append("")
    lines.append("## Workable, nearest deadline first")
    lines.append("")
    if not work:
        lines.append("None - every call is skipped for a reason listed below.")
    else:
        for i, call in enumerate(sorted(work, key=_deadline_sort_key), start=1):
            lines.append(
                f"{i}. {call.name}"
                f"  [deadline {_fmt_deadline(call)}, {_fmt_days(call, today)} days, "
                f"funder={call.funder or '?'}, {len(call.material)} call file(s)]"
            )

    lines.append("")
    lines.append("## Not worked, and why")
    lines.append("")
    skipped = [c for c in sorted(calls, key=_deadline_sort_key) if c.name not in work_names]
    if not skipped:
        lines.append("Nothing skipped - every call in the archive is workable.")
    else:
        for call in skipped:
            for reason in skip_reasons(call):
                lines.append(f"- {call.name}: {reason}")

    undated = [c for c in calls if c.deadline is None]
    if undated:
        lines.append("")
        lines.append("## Unparseable folder dates")
        lines.append("")
        lines.append(
            "These names carry no `YYYY.MM`/`YYYY.MM.DD` prefix, so their "
            "deadline is unknown and they cannot be ordered by urgency:"
        )
        for call in undated:
            lines.append(f"- {call.name}")

    return "\n".join(lines) + "\n"


def _call_as_dict(call: CallInfo, today: date) -> dict:
    # One derivation, emitted twice: "workable" is *defined* as "no skip reasons", so
    # computing it separately would let the two fields disagree in the JSON.
    reasons = skip_reasons(call)
    return {
        "name": call.name,
        "path": str(call.path),
        "deadline": call.deadline.isoformat() if call.deadline else None,
        "deadline_precision": call.deadline_precision,
        "days_until": days_until(call, today),
        "funder": call.funder,
        "state": call.state,
        "has_topics": call.has_topics,
        "topics_versions": call.topics_versions,
        "material": [str(p) for p in call.material],
        "frozen": [str(p) for p in call.frozen],
        "workable": not reasons,
        "skip_reasons": reasons,
    }


def _main(argv: list[str] | None = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(
        prog="python3 -m lib.scan",
        description=(
            "Read-only roster of the proposal archive: which calls exist, "
            "their deadlines and states, which are workable, and which are "
            "not (with the reason). Writes nothing, ever."
        ),
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=None,
        help="Archive root (default: $AUTO_PROPOSALS_ROOT, else ~/Dropbox/Work/Proposals)",
    )
    parser.add_argument(
        "--today",
        default=None,
        metavar="YYYY-MM-DD",
        help="Treat this as today's date when computing days-to-deadline",
    )
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--json", action="store_true", help="Emit JSON instead of the report")
    group.add_argument(
        "--open-md",
        action="store_true",
        help=(
            "Emit the regenerated OPEN.md BODY on stdout instead of the "
            "report. This only prints it - publishing it is a separate, "
            "explicit `lib.publish regenerate` call."
        ),
    )
    args = parser.parse_args(argv)

    root = Path(args.root).expanduser() if args.root else _default_root()
    try:
        today = date.fromisoformat(args.today) if args.today else date.today()
    except ValueError:
        print(f"error: --today must be YYYY-MM-DD, got {args.today!r}", file=sys.stderr)
        return 2

    if not root.is_dir():
        print(f"error: archive root does not exist or is not a directory: {root}", file=sys.stderr)
        return 2

    try:
        calls, open_md_conflicts = scan_archive(root)
    except PathRefused as exc:
        # A refusal here means a config or artifact the scanner cannot safely
        # interpret. Reporting it as an error beats degrading to a partial
        # roster that looks complete.
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if args.json:
        print(
            json.dumps(
                {
                    "root": str(root),
                    "today": today.isoformat(),
                    "open_md_conflicts": [str(p) for p in open_md_conflicts],
                    "calls": [_call_as_dict(c, today) for c in sorted(calls, key=_deadline_sort_key)],
                },
                ensure_ascii=False,
                indent=2,
            )
        )
    elif args.open_md:
        sys.stdout.write(render_open_md(calls, today=today))
    else:
        sys.stdout.write(render_report(calls, root=root, today=today, open_md_conflicts=open_md_conflicts))
    return 0


if __name__ == "__main__":
    sys.exit(_main())
