#!/usr/bin/env python3
"""Read a Claude Code pane's text on stdin and judge its usage-limit banner.

Pure: reads stdin and the clock (or --now), writes one line to stdout, and
touches no file. session-resume-watch.sh runs it on every check, so the tests
feed it exactly what the watcher reads.

A banner counts only when it is LIVE: the newest thing the session wrote. Read
from the bottom of the pane, the screen must hold, in this order and nothing
else:

  status rows      at most MAX_STATUS non-empty rows under the composer box
  composer box     a rule, the prompt row(s) starting with the prompt glyph, a rule
  trailer rows     only the rows Claude Code itself prints under a limit banner
                   (TRAILERS below); blank rows are skipped
  the banner       "⎿  You've hit your <kind> limit · resets <when>"

Anything else between the banner and the composer box (the session's own
output, a menu, a later prompt) means the banner is history, and nothing is
detected. A dialog drawn over the composer (the login picker) leaves no
composer box, so nothing is detected under it either.

Reset time. The banner gives a clock time ("7:30am"), sometimes with a date
("Nov 16, 8am"), and an optional IANA zone. The turn summary under it
("✻ Sautéed for 41s · done 6:35 AM") gives the banner's own clock time B, in
the host's local zone. The reset is:

  dated banner   that date and time (this year; next year if that is more
                 than half a year back);
  clock banner, B known
                 the first instance of the clock time at or after B: B's date
                 when the clock time is not earlier than B, else the next day.
                 So it is tomorrow only when the clock time has passed today
                 AND the banner is newer than it ("resets 12:05am" under
                 "done 11:57 PM" is the next day);
  clock banner, no turn summary
                 today only, and only while it is still ahead. Never tomorrow:
                 without B, tomorrow is a guess.

A reset that is not in the future detects nothing.

Output (one line):
  detect  "reset=<epoch> human=<label> kind=<kind>", exit 0
  none    "none reason=<token>", exit 1, token one of
          no-banner | no-composer | not-newest | no-reset | reset-passed |
          banner-time-unknown

Other modes:
  --live-only        exit 0 while a live banner is on screen, whatever its time
  --composer-clear   exit 0 when the screen ends in an EMPTY composer box
  --describe         print "key=<Escape|Ctrl-C> screen=<one line>": what the
                     bottom of the screen shows and the key that would clear it
"""

import argparse
import datetime as dt
import re
import sys
import time

MAX_STATUS = 6        # non-empty status rows allowed under the composer box
MAX_COMPOSER = 12     # prompt rows allowed inside the composer box

RULE = re.compile(r"^\s*─{3,}[─\s]*$")
PROMPT = re.compile(r"^\s*❯(\s|$)")
OPTION = re.compile(r"^\s*❯\s*\d+\.")

# herdr's unwrapped read can glue a full-width row to the next one, so the
# banner may follow a long run of padding on its row. Anything else before the
# tool-result glyph (prose quoting the banner) does not count.
BANNER = re.compile(
    r"(?:^|\s{2,})⎿\s+You['’]ve hit your (?P<kind>[^·]*?)\s*limit"
    r"(?:\s*·\s*resets\s+(?P<when>.+?))?\s*$")
ANY_BANNER = re.compile(r"hit your [^·]*limit", re.IGNORECASE)

WHEN = re.compile(
    r"^(?:(?P<mon>Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+"
    r"(?P<day>\d{1,2}),?\s+)?"
    r"(?P<h>\d{1,2})(?::(?P<m>\d{2}))?\s*(?P<ap>[ap])\.?m\.?"
    r"(?:\s*\((?P<tz>[A-Za-z_]+(?:/[A-Za-z0-9_+-]+)+|UTC)\))?\s*$",
    re.IGNORECASE)

DONE = re.compile(
    r"^✻\s+\S+\s+for\s+[0-9hms ]+·\s+done\s+"
    r"(?:(?P<wd>Mon|Tues|Wednes|Thurs|Fri|Satur|Sun)day\s+)?"
    r"(?P<h>\d{1,2}):(?P<m>\d{2})\s*(?P<ap>[AP])M(?:\s+·.*)?$")

TRAILERS = [
    re.compile(r"^/usage-credits to finish what you['’]re working on\.?$"),
    re.compile(r"^●\s+Usage limit reached(?: again)? · continuing automatically at .+ · esc to cancel$"),
    re.compile(r"^●\s+Goal paused · usage limit reached · continues automatically when it resets$"),
    DONE,
]

MONTHS = {m: i + 1 for i, m in enumerate(
    "jan feb mar apr may jun jul aug sep oct nov dec".split())}
WEEKDAYS = {"mon": 0, "tues": 1, "wednes": 2, "thurs": 3, "fri": 4, "satur": 5, "sun": 6}


# The multiplexer's unwrapped read glues a full-width row to the row after it:
# a rule runs straight into the prompt ("────❯ "), and a padded row into the
# next one's text. Split those back apart before reading the structure.
GLUE_SPACES = re.compile(r"\s{24,}")
LEAD_RULE = re.compile(r"^(\s*─{20,})(?=[^─\s])")
TAIL_RULE = re.compile(r"(?<=[^─\s])(─{20,}\s*)$")


def rows(text):
    out = []
    for raw in text.splitlines():
        for part in GLUE_SPACES.split(raw.rstrip()):
            m = LEAD_RULE.match(part)
            if m:
                out += [m.group(1), part[m.end():]]
                continue
            m = TAIL_RULE.search(part)
            if m:
                out += [part[:m.start()], m.group(1)]
                continue
            out.append(part)
    return [r.rstrip() for r in out if r.strip()]


def composer_box(lines):
    """(upper rule, lower rule) indexes of the live composer box, or None."""
    n = len(lines)
    for lo in range(n - 1, max(-1, n - 2 - MAX_STATUS), -1):
        if not RULE.match(lines[lo]):
            continue
        for hi in range(lo - 1, max(-1, lo - 2 - MAX_COMPOSER), -1):
            if RULE.match(lines[hi]):
                first = lines[hi + 1] if hi + 1 < lo else ""
                if PROMPT.match(first) and not OPTION.match(first):
                    return hi, lo
                return None
        return None
    return None


def live_banner(lines, extra=()):
    """(banner match, trailer rows) when the newest content is a banner, else (None, reason)."""
    box = composer_box(lines)
    if box is None:
        return None, "no-composer"
    trailer = []
    for i in range(box[0] - 1, -1, -1):
        row = lines[i]
        m = BANNER.search(row)
        if m:
            return m, trailer
        s = row.strip()
        if any(t.match(s) for t in TRAILERS) or any(t.match(s) for t in extra):
            trailer.append(s)
            continue
        return None, "not-newest"
    return None, "not-newest"


def local_zone():
    return dt.datetime.now().astimezone().tzinfo


def zone(name):
    if not name:
        return local_zone()
    try:
        from zoneinfo import ZoneInfo
        return ZoneInfo(name)
    except Exception:
        return None


def hour24(h, ap):
    h = int(h) % 12
    return h + 12 if ap.lower() == "p" else h


def banner_time(trailer, now):
    """Epoch of the turn summary under the banner (local zone), or None."""
    for s in trailer:
        m = DONE.match(s)
        if not m:
            continue
        n = dt.datetime.fromtimestamp(now).astimezone()
        t = n.replace(hour=hour24(m["h"], m["ap"]), minute=int(m["m"]), second=0, microsecond=0)
        if m["wd"]:
            t -= dt.timedelta(days=(n.weekday() - WEEKDAYS[m["wd"].lower()]) % 7)
        if t.timestamp() > now:
            t -= dt.timedelta(days=7 if m["wd"] else 1)
        return t.timestamp()
    return None


def reset_epoch(when, trailer, now):
    """(epoch, human) of the reset, or (None, reason)."""
    m = WHEN.match(when or "")
    if not m:
        return None, "no-reset"
    tz = zone(m["tz"])
    if tz is None:
        return None, "no-reset"
    h, mi = hour24(m["h"], m["ap"]), int(m["m"] or 0)
    human = "%s:%02d%sm" % (m["h"], mi, m["ap"].lower())
    n = dt.datetime.fromtimestamp(now, tz)
    if m["mon"]:
        try:
            r = dt.datetime(n.year, MONTHS[m["mon"][:3].lower()], int(m["day"]), h, mi, tzinfo=tz)
            if r.timestamp() < now - 183 * 86400:
                r = r.replace(year=n.year + 1)
        except ValueError:
            return None, "no-reset"
        human = "%s%s_%s" % (m["mon"][:3].title(), int(m["day"]), human)
    else:
        b = banner_time(trailer, now)
        if b is None:
            r = n.replace(hour=h, minute=mi, second=0, microsecond=0)
            if r.timestamp() <= now:
                return None, "banner-time-unknown"
        else:
            bd = dt.datetime.fromtimestamp(b, tz)
            r = bd.replace(hour=h, minute=mi, second=0, microsecond=0)
            if r < bd.replace(second=0, microsecond=0):
                r = (bd + dt.timedelta(days=1)).replace(hour=h, minute=mi, second=0, microsecond=0)
    if m["tz"]:
        human += "_" + m["tz"]
    r = r.timestamp()
    if r <= now:
        return None, "reset-passed"
    return int(r), human


def describe(lines):
    tail = [s.strip() for s in lines[-12:] if not RULE.match(s)]
    text = " ".join(tail)
    key = "Ctrl-C" if re.search(r"ctrl[- +]c", text, re.IGNORECASE) else "Escape"
    shown = " / ".join(tail[-4:]) if tail else "(blank screen)"
    shown = re.sub(r"[\x00-\x1f\x7f]", " ", shown)
    if len(shown) > 160:
        shown = shown[:157] + "..."
    return "key=%s screen=%s" % (key, shown)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--now", type=float)
    ap.add_argument("--live-only", action="store_true")
    ap.add_argument("--composer-clear", action="store_true")
    ap.add_argument("--describe", action="store_true")
    a = ap.parse_args(argv)
    now = a.now if a.now is not None else time.time()
    lines = rows(sys.stdin.read())

    if a.describe:
        print(describe(lines))
        return 0
    if a.composer_clear:
        box = composer_box(lines)
        return 0 if box and [s.strip() for s in lines[box[0] + 1:box[1]]] == ["❯"] else 1

    m, rest = live_banner(lines)
    if m is None:
        reason = rest if any(ANY_BANNER.search(s) for s in lines) else "no-banner"
        print("none reason=%s" % reason)
        return 1
    if a.live_only:
        print("live")
        return 0
    r, human = reset_epoch(m["when"], rest, now)
    if r is None:
        print("none reason=%s" % human)
        return 1
    kind = re.sub(r"\s+", "-", m["kind"].strip()) or "usage"
    print("reset=%d human=%s kind=%s" % (r, human, kind))
    return 0


if __name__ == "__main__":
    sys.exit(main())
