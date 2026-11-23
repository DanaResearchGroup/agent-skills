#!/usr/bin/env python3
"""Summarise the limit-resume log-only proof (I-571). Read-only.

Over the last N days of auto-resume.log it prints: detections (LOG-ONLY would
send), screens saved, screens withheld, StopFailure events (cc-stopfailure-hook.sh),
the detections with no StopFailure for the same session within 5 minutes, and
the StopFailure events with no detection within 5 minutes. Matching, both
ways, looks at events over the window widened by 5 minutes on each side, so an
event near a window edge is matched to its partner just outside it; only the
events being counted are held to the window.

Then two tables. Per seat: true (detections with a StopFailure for the same
session within 5 minutes), false (detections with none) and missed (StopFailure
events no detection saw). Per detection: its UTC time, seat, pair (true/false,
and missed rows for the unseen StopFailure events), the StopFailure it pairs
with, and the proof fields its LOG-ONLY line carries (verdict, would_type,
screen_sha256, cwd, banner), shell-quoted. A seat with any withheld record
(cwd=withheld, banner=withheld or screen-withheld) shows in the seat table only:
the two unmatched lists count its events but print no line for them.

Since the StopFailure hook launches the watcher (I-575) it also prints: true
stops detected (the window's StopFailure events with a detection within 5
minutes, out of all of them); the first day a watcher was launched from
StopFailure (the first STOPFAILURE-LAUNCH line in the whole log), from which
the days of proof count; and the first real stop: the first detection in the
whole log that a STOPFAILURE-LAUNCH for its session started (at most 5 minutes
before it) and whose screen_sha256 differs from the hash of every fixture
screen in --fixtures (default: this skill's test/fixtures/panes). When either
of these belongs to a withheld seat, its line keeps the day or says "yes", and
prints no time, seat or hash.

N is the days of proof: --days, else AUTODEV_LOGONLY_DAYS, else 7.

Usage: auto-resume-report.py [--days N] [--log PATH] [--now EPOCH] [--fixtures DIR]
"""
import hashlib
import argparse
import datetime as dt
import os
import re
import shlex
import sys

MATCH_S = 300
LOGONLY = re.compile(r"^\S+ \S+ \[(?P<sid>[^\]]+)\] LOG-ONLY (?P<what>\S+)(?P<rest>.*)$")
AT = re.compile(r" at=(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)$")
PROOF = ("seat", "cwd", "screen_sha256", "banner", "verdict", "would_type")
STOPFAIL = re.compile(r"^STOPFAILURE (\S+) (\S+) (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)$")
LAUNCH = re.compile(r"^STOPFAILURE-LAUNCH (\S+) (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)$")
FIXTURES = os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "test", "fixtures", "panes")


def epoch(iso):
    return int(dt.datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ")
               .replace(tzinfo=dt.timezone.utc).timestamp())


def utc(t):
    return dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def proof_fields(rest):
    """The proof fields of a LOG-ONLY line, read back the way a shell reads them."""
    try:
        toks = shlex.split(rest)
    except ValueError:
        return {}
    out = {}
    for tok in toks:
        k, sep, v = tok.partition("=")
        if sep and k in PROOF:
            out.setdefault(k, v)
    return out


def quoted(v):
    """v single-quoted always, so an empty or plain value still reads as a value."""
    return "'" + v.replace("'", "'\"'\"'") + "'"


def table(rows):
    """Rows of cells, every column but the last padded to its widest cell."""
    w = [max(len(r[i]) for r in rows) for i in range(len(rows[0]) - 1)]
    return ["  " + "  ".join([c.ljust(w[i]) for i, c in enumerate(r[:-1])] + [r[-1]]).rstrip()
            for r in rows]


def fixture_hashes(d):
    """sha256 of each fixture screen, raw and as the watcher hashes a read of it
    (trailing newlines cut, one added back). None when there is no fixture."""
    out = set()
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return None
    for n in names:
        try:
            with open(os.path.join(d, n), "rb") as fh:
                b = fh.read()
        except OSError:
            continue
        out.add(hashlib.sha256(b).hexdigest())
        out.add(hashlib.sha256(b.rstrip(b"\n") + b"\n").hexdigest())
    return out or None


def days_setting(arg):
    raw = arg if arg is not None else os.environ.get("AUTODEV_LOGONLY_DAYS", "7")
    if not re.fullmatch(r"[1-9][0-9]*", str(raw)):
        sys.exit(f"auto-resume-report: days must be a positive integer, got {raw!r}")
    return int(raw)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--days")
    ap.add_argument("--log")
    ap.add_argument("--now", type=int)
    ap.add_argument("--fixtures", default=FIXTURES)
    a = ap.parse_args()
    days = days_setting(a.days)
    home = os.environ.get("AUTODEV_HOME") or os.path.expanduser("~/agents")
    path = a.log or os.path.join(home, "logs", "auto-resume.log")
    now = a.now if a.now is not None else int(dt.datetime.now(dt.timezone.utc).timestamp())
    since = now - days * 86400

    detections, saved, withheld, failures, held_seats = [], 0, 0, [], set()
    launches, every_det = [], []
    lo, hi = since - MATCH_S, now + MATCH_S
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except FileNotFoundError:
        lines = []
    for line in lines:
        m = STOPFAIL.match(line)
        if m:
            failures.append((m.group(1), m.group(2), epoch(m.group(3))))
            continue
        m = LAUNCH.match(line)
        if m:
            launches.append((m.group(1), epoch(m.group(2))))
            continue
        m = LOGONLY.match(line)
        if not m:
            continue
        at = AT.search(line)
        if not at:
            continue
        t = epoch(at.group(1))
        what, sid = m.group("what"), m.group("sid")
        rest = m.group("rest")[:-len(at.group(0))].strip()
        proof = proof_fields(rest)
        if what == "screen-withheld" or "withheld" in (proof.get("cwd"), proof.get("banner")):
            held_seats.add(sid)
        if what == "would":
            every_det.append((sid, t, proof))
        if what == "would" and lo <= t <= hi:
            detections.append((sid, t, rest.split(" seat=")[0], proof))
        if not since <= t <= now:
            continue
        if what == "screen-saved":
            saved += 1
        elif what == "screen-withheld":
            withheld += 1

    def nearest(sid, t, pool):
        hits = [p for p in pool if p[0] == sid and abs(p[1] - t) <= MATCH_S]
        return min(hits, key=lambda p: abs(p[1] - t)) if hits else None

    def near(sid, t, pool):
        return nearest(sid, t, pool) is not None

    # Matched against: the widened window. Counted: the window itself.
    sf_pool = [(s, t, e) for s, e, t in failures if lo <= t <= hi]
    det_pool = [(s, t) for s, t, _, _ in detections]
    detections = [d for d in detections if since <= d[1] <= now]
    window_fail = [f for f in failures if since <= f[2] <= now]
    lone_det = [d for d in detections if not near(d[0], d[1], sf_pool)]
    lone_fail = [f for f in window_fail if not near(f[0], f[2], det_pool)]

    print(f"log-only report: {days} day(s), {utc(since)} .. {utc(now)}")
    print(f"log: {path}")
    print(f"detections: {len(detections)}")
    print(f"screens saved: {saved}")
    print(f"screens withheld: {withheld}")
    print(f"StopFailure events: {len(window_fail)}")
    print(f"detections with no StopFailure within 5 min: {len(lone_det)}")
    # A withheld seat is counted in both totals but has no per-event line.
    for sid, t, rest, _ in lone_det:
        if sid not in held_seats:
            print(f"  {utc(t)} {sid} {rest}")
    print(f"StopFailure events with no detection within 5 min: {len(lone_fail)}")
    for sid, err, t in lone_fail:
        if sid not in held_seats:
            print(f"  {utc(t)} {sid} {err}")
    print(f"true stops detected: {len(window_fail) - len(lone_fail)} of {len(window_fail)}"
          " (StopFailure events with a detection within 5 min)")
    first_launch = min(launches, key=lambda r: r[1], default=None)
    if first_launch is None:
        print("StopFailure launch live since: never (no STOPFAILURE-LAUNCH in the log)")
    else:
        sid, t = first_launch
        # A withheld seat's launch gives the day only: no time, no sid.
        which = "from a withheld seat" if sid in held_seats else utc(t)
        print(f"StopFailure launch live since: {utc(t)[:10]} (first STOPFAILURE-LAUNCH {which};"
              " proof days count from then)")
    fx = fixture_hashes(a.fixtures)

    def launched(sid, t):
        return any(s == sid and 0 <= t - lt <= MATCH_S for s, lt in launches)
    if fx is None:
        print(f"first real stop: unknown (no fixture screens in {a.fixtures})")
    else:
        real = [(t, sid, p) for sid, t, p in every_det
                if launched(sid, t) and p.get("screen_sha256") and p["screen_sha256"] not in fx]
        if not real:
            print("first real stop: none yet")
        else:
            t, sid, p = min(real, key=lambda r: r[0])
            if sid in held_seats:  # caught, but no time, sid or hash
                print("first real stop: yes (withheld seat; counts only)")
            else:
                print(f"first real stop: {utc(t)} {sid} screen_sha256={p['screen_sha256']}")

    seats = {}
    rows = []
    for sid, t, _, proof in detections:
        sf = nearest(sid, t, sf_pool)
        pair = "true" if sf else "false"
        seats.setdefault(sid, {"true": 0, "false": 0, "missed": 0})[pair] += 1
        if sid in held_seats:
            continue
        q = {k: quoted(proof[k]) if k in proof else "-" for k in PROOF}
        rows.append((t, [utc(t), sid, pair, f"{utc(sf[1])} {sf[2]}" if sf else "-",
                         proof.get("verdict", "-"), q["would_type"], proof.get("screen_sha256", "-"),
                         q["cwd"], q["banner"]]))
    for sid, err, t in lone_fail:
        seats.setdefault(sid, {"true": 0, "false": 0, "missed": 0})["missed"] += 1
        if sid not in held_seats:
            rows.append((t, [utc(t), sid, "missed", f"{utc(t)} {err}"] + ["-"] * 5))
    print("per seat (true: a StopFailure within 5 min; false: none; missed: a StopFailure no detection saw):")
    if seats:
        seat_rows = [["seat", "true", "false", "missed", ""]]
        for sid in sorted(seats):
            c = seats[sid]
            seat_rows.append([sid, str(c["true"]), str(c["false"]), str(c["missed"]),
                              "withheld: counts only" if sid in held_seats else ""])
        print("\n".join(table(seat_rows)))
    print("per detection (withheld seats not listed):")
    if rows:
        head = ["at", "seat", "pair", "stopfailure", "verdict", "would_type",
                "screen_sha256", "cwd", "banner"]
        print("\n".join(table([head] + [r for _, r in sorted(rows, key=lambda r: r[0])])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
