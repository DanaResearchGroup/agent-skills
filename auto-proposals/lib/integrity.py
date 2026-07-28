"""Turns a silent clobber into a loud, itemised alarm (SAFETY.md #3, layer
L3). Every run snapshots (size, mtime_ns, ino, content hash) for every file
under the archive root before doing anything, and diffs against a fresh
snapshot afterwards. Anything that changed and wasn't one of the artifacts we
deliberately wrote this run is worth stopping and looking at - Dropbox keeps
30 days of file history, but by the time a human notices a file is wrong,
"which of the last 30 days broke it" is a much worse question than "what did
this run touch."

(size, mtime_ns) alone is a weak fingerprint: a same-length edit that lands
inside the same mtime tick (coarse filesystem clocks, or a deliberately
crafted `os.utime` call) is invisible to it. Regular files up to
AUTO_PROPOSALS_HASH_MAX_BYTES (default 5 MiB) get a real sha256 of their
content instead; larger files fall back to (size, mtime_ns, ino) only,
recorded as such via LARGE_FILE_SKIPPED so callers can see how much of the
tree that run's fingerprint actually covers.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path

DEFAULT_HASH_MAX_BYTES = 5 * 1024 * 1024

# Sentinel stored in place of a sha256 hex digest when a regular file was too
# large to hash under the configured cap - kept distinct from `None` (used
# for symlinks, which we deliberately never hash) so diff() can report how
# many entries in a snapshot fell back to size/mtime/ino-only coverage.
LARGE_FILE_SKIPPED = "size-cap-exceeded"


def _hash_max_bytes() -> int:
    raw = os.environ.get("AUTO_PROPOSALS_HASH_MAX_BYTES")
    if not raw:
        return DEFAULT_HASH_MAX_BYTES
    try:
        return int(raw)
    except ValueError:
        return DEFAULT_HASH_MAX_BYTES


def _hash_file(path: str) -> str | None:
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            while True:
                chunk = f.read(65536)
                if not chunk:
                    break
                h.update(chunk)
    except OSError:
        # A file that vanishes or becomes unreadable mid-hash is a race, not
        # a reason to drop the whole snapshot entry - fall back to no hash
        # for this file rather than raising.
        return None
    return h.hexdigest()


def snapshot(root: Path) -> dict[str, tuple[int, int, int, str | None]]:
    """Walk `root` and record relpath -> (size, mtime_ns, ino, sha256) for
    every file (including symlinks, recorded via their own lstat so a
    swapped symlink target shows up as a change too - symlinks are never
    hashed, so their sha256 field is always None). Skips nothing on purpose
    - we want to detect a change anywhere in the tree, not just in paths we
    think we understand. Unreadable entries (permissions races, a file that
    vanishes between scandir and stat) are skipped rather than raising,
    since a snapshot is best-effort inventory, not a guarantee every byte
    was read.
    """
    root = Path(root)
    result: dict[str, tuple[int, int, int, str | None]] = {}
    max_hash_bytes = _hash_max_bytes()

    def _walk(dir_path: str) -> None:
        try:
            entries = list(os.scandir(dir_path))
        except OSError:
            return
        for entry in entries:
            try:
                if entry.is_dir(follow_symlinks=False):
                    _walk(entry.path)
                    continue
                # Regular file or symlink (including a symlink to a
                # directory, which we do NOT traverse into - that would
                # both risk infinite loops and silently include content
                # outside root).
                st = entry.stat(follow_symlinks=False)
                rel = os.path.relpath(entry.path, root)

                sha: str | None
                if entry.is_symlink():
                    sha = None
                elif st.st_size > max_hash_bytes:
                    sha = LARGE_FILE_SKIPPED
                else:
                    sha = _hash_file(entry.path)

                result[rel] = (st.st_size, st.st_mtime_ns, st.st_ino, sha)
            except OSError:
                continue

    _walk(str(root))
    return result


def diff(before: dict, after: dict, owned_rels: set,
         expected_modified: set | None = None) -> dict:
    """Compare two snapshots. `owned_rels` is the set of paths this run was
    allowed to create; anything in it is expected to appear as new and is
    not an alarm. Everything else that changed, disappeared, or newly
    appeared is reported - that's the whole point of this module.

    `owned_rels` is deliberately NOT consulted for the modified/deleted
    checks below: publish.py only ever *creates* new owned artifacts (or
    appends/regenerates through its own CAS-guarded paths, never bypassing
    this module), so an owned artifact that this run did not itself publish
    turning up modified or deleted is exactly the class of silent clobber
    L3 exists to catch, not a false positive to suppress. Only *creation* of
    an owned path is expected and excluded below.

    `expected_modified` is the narrow exception: a regenerate of an
    already-existing OPEN.md or CORPUS.md legitimately modifies a file, and
    the caller has to be able to say so. It is a separate argument from
    `owned_rels` on purpose - declaring "I am about to rewrite this exact
    path" is a much stronger statement than "I may create files of this
    shape", and conflating the two would silently excuse every future
    modification of anything the agent happens to own.
    """
    expected_modified = expected_modified or set()
    modified = []
    deleted = []
    created_unowned = []

    for rel, before_stat in before.items():
        after_stat = after.get(rel)
        if after_stat is None:
            deleted.append(rel)
        elif after_stat != before_stat and rel not in expected_modified:
            modified.append(rel)

    for rel in after:
        if rel in owned_rels:
            continue
        if rel not in before:
            created_unowned.append(rel)

    skipped_large = sum(
        1 for rec in after.values() if len(rec) > 3 and rec[3] == LARGE_FILE_SKIPPED
    )

    return {
        "modified": sorted(modified),
        "deleted": sorted(deleted),
        "created_unowned": sorted(created_unowned),
        "skipped_large": skipped_large,
    }


def format_report(d: dict) -> str:
    """Short human-readable report; empty string when the diff is clean so
    callers can just do `if report: alarm(report)`. `skipped_large` alone
    (files whose content wasn't hashed because they're over the size cap)
    does not make an otherwise-clean diff non-empty - it's informational
    about coverage, not itself an alarm."""
    modified = d.get("modified", [])
    deleted = d.get("deleted", [])
    created_unowned = d.get("created_unowned", [])
    skipped_large = d.get("skipped_large", 0)

    if not modified and not deleted and not created_unowned:
        return ""

    lines = ["INTEGRITY ALARM - unexpected filesystem changes detected:"]
    if modified:
        lines.append(f"  modified ({len(modified)}):")
        lines.extend(f"    {rel}" for rel in modified)
    if deleted:
        lines.append(f"  deleted ({len(deleted)}):")
        lines.extend(f"    {rel}" for rel in deleted)
    if created_unowned:
        lines.append(f"  created, not owned by this run ({len(created_unowned)}):")
        lines.extend(f"    {rel}" for rel in created_unowned)
    if skipped_large:
        lines.append(
            f"  note: {skipped_large} file(s) skipped content hashing (over "
            "the AUTO_PROPOSALS_HASH_MAX_BYTES cap) - those entries rely on "
            "size/mtime/inode only for change detection"
        )
    return "\n".join(lines)
