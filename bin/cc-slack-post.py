#!/usr/bin/env python3
"""Post a message to the CC comms Slack channel as the bot.

Usage:
    cc-slack-post.py "<message>" [thread_ts]
    cc-slack-post.py --which-channel
    cc-slack-post.py --no-channel-notice <caller>
    cc-slack-post.py --unposted [--since <YYYY-MM-DD | ISO time>] [--json]

Posting prints "OK" then the message ts, and exits 0.

Exit codes:
    0   posted (or, for the read-only modes, done)
    1   post failed: token unreadable, network error, or a Slack error.
        One line is appended to the unposted log, with its reason.
    2   usage error; nothing is logged.
    78  no channel (EX_CONFIG): nothing was sent and no request was made.
        Prints one "ERR" line that says where to set the channel, and appends
        one line to the unposted log.

Channel, first match wins (resolve_channel()):
    1. CC_SLACK_CHANNEL in this process's environment.
    2. env.CC_SLACK_CHANNEL in the Claude Code settings file,
       $CLAUDE_CONFIG_DIR/settings.json, else ~/.claude/settings.json.
       The file is opened read-only and only that one key is taken; nothing
       else in it is printed, logged or copied. A missing, empty, unreadable or
       malformed file, or a value that is not a non-empty string, is no channel.
    Systemd units and plain shells never see Claude Code's settings `env`
    block, which is why the poster reads the file itself.

Unposted log: ${AUTODEV_HOME:-$HOME/agents}/state/slack-unposted.jsonl, one JSON
line per line not posted: {"ts", "caller", "reason", "message_len", "detail"}.
The message text is never written. Reasons: no-channel, token-unreadable,
request-failed, slack-error. `--unposted` counts them by reason, with the time
each reason was first seen; a missing or empty log counts as 0.

`--no-channel-notice <caller>` is for callers that got exit 78: it prints
"slack: no channel" at most once per day per caller, through a dated marker
state/slack-no-channel.<caller>.<YYYY-MM-DD>, and always exits 0.

Other environment:
    CC_SLACK_TOKEN_FILE  default "~/.claude/.slack-bot-token"
    CC_SLACK_CALLER      the calling program's name for the unposted log;
                         default: the parent process's name
    CC_SLACK_API_URL     tests only: a loopback (127.0.0.1/localhost) URL that
                         replaces Slack's chat.postMessage endpoint
    CC_SLACK_TODAY       tests only: YYYY-MM-DD that replaces today's date
"""
import datetime
import glob
import json
import os
import re
import stat
import sys
import urllib.parse
import urllib.request

EXIT_POST_FAILED = 1
EXIT_USAGE = 2
EXIT_NO_CHANNEL = 78

API_URL = "https://slack.com/api/chat.postMessage"
UNPOSTED_LOG = "slack-unposted.jsonl"
NOTICE_PREFIX = "slack-no-channel."
LOOPBACK_HOSTS = ("127.0.0.1", "localhost", "::1")


def _home(env):
    return env.get("HOME") or os.path.expanduser("~")


def _expand(path, env):
    """Expand a leading ~ against env's HOME (a systemd unit never expands it)."""
    if path == "~" or path.startswith("~/"):
        return _home(env) + path[1:]
    return os.path.expanduser(path)


def settings_path(env=None):
    """Path of the Claude Code settings file the channel may come from."""
    env = os.environ if env is None else env
    base = env.get("CLAUDE_CONFIG_DIR") or os.path.join(_home(env), ".claude")
    return os.path.join(_expand(base, env), "settings.json")


def _read_settings_channel(path):
    """(channel, None) from env.CC_SLACK_CHANNEL in `path`, else (None, why)."""
    try:
        # O_NONBLOCK: a FIFO in the settings file's place must not hang a timer.
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0))
    except FileNotFoundError:
        return None, "is missing"
    except OSError as e:
        return None, "is unreadable (%s)" % (e.strerror or type(e).__name__)
    try:
        with os.fdopen(fd, "rb") as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                return None, "is not a regular file"
            raw = f.read()
    except OSError as e:
        return None, "is unreadable (%s)" % (e.strerror or type(e).__name__)
    if not raw.strip():
        return None, "is empty"
    try:
        data = json.loads(raw.decode("utf-8"))
    except (ValueError, RecursionError):
        return None, "is not valid JSON"
    block = data.get("env") if isinstance(data, dict) else None
    value = block.get("CC_SLACK_CHANNEL") if isinstance(block, dict) else None
    if value is None:
        return None, "has no env.CC_SLACK_CHANNEL"
    if not isinstance(value, str):
        return None, "has a non-string env.CC_SLACK_CHANNEL"
    if not value.strip():
        return None, "has an empty env.CC_SLACK_CHANNEL"
    return value.strip(), None


def resolve_channel(env=None):
    """Which channel, and from where; never posts.

    Returns (channel, source). On success source is "env CC_SLACK_CHANNEL" or
    "settings <path>". With no channel, channel is None and source says why,
    e.g. "<path> is missing". Import from another tool with
    importlib.util.spec_from_file_location (the file name has dashes), or run
    `cc-slack-post.py --which-channel`.
    """
    env = os.environ if env is None else env
    value = env.get("CC_SLACK_CHANNEL") or ""
    if value.strip():
        return value.strip(), "env CC_SLACK_CHANNEL"
    path = settings_path(env)
    channel, why = _read_settings_channel(path)
    if channel:
        return channel, "settings " + path
    return None, "%s %s" % (path, why)


def state_dir(env=None):
    env = os.environ if env is None else env
    base = env.get("AUTODEV_HOME") or os.path.join(_home(env), "agents")
    return os.path.join(_expand(base, env), "state")


def unposted_log_path(env=None):
    return os.path.join(state_dir(env), UNPOSTED_LOG)


def _clean_name(name):
    name = re.sub(r"[^A-Za-z0-9._-]", "_", name or "")[:64].strip("._")
    return name or "unknown"


def caller_name(env=None):
    """CC_SLACK_CALLER, else the parent process's script or program name."""
    env = os.environ if env is None else env
    if env.get("CC_SLACK_CALLER"):
        return _clean_name(env["CC_SLACK_CALLER"])
    try:
        with open("/proc/%d/cmdline" % os.getppid(), "rb") as f:
            argv = [a.decode("utf-8", "replace") for a in f.read().split(b"\0") if a]
    except OSError:
        return "unknown"
    if not argv:
        return "unknown"
    prog = os.path.basename(argv[0])
    interpreters = ("python", "python3", "bash", "sh", "dash", "zsh", "env", "node")
    if prog in interpreters and len(argv) > 1 and not argv[1].startswith("-"):
        prog = os.path.basename(argv[1])
    return _clean_name(prog)


def _now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def append_unposted(reason, message_len, detail="", env=None):
    """Append one line to the unposted log. Returns None, or why it failed."""
    env = os.environ if env is None else env
    record = {
        "ts": _now_iso(),
        "caller": caller_name(env),
        "reason": reason,
        "message_len": message_len,
        "detail": str(detail)[:200],
    }
    line = (json.dumps(record, ensure_ascii=False) + "\n").encode("utf-8")
    path = unposted_log_path(env)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        # One write on an O_APPEND descriptor: concurrent posters never interleave.
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_CLOEXEC", 0), 0o600)
        try:
            os.write(fd, line)
        finally:
            os.close(fd)
    except OSError as e:
        return "%s: %s" % (path, e.strerror or type(e).__name__)
    return None


def _today(env):
    forced = env.get("CC_SLACK_TODAY", "")
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", forced):
        return forced
    return datetime.date.today().isoformat()


def no_channel_notice(caller, env=None):
    """The once-a-day line for `caller`, or "" when today's was already given.

    The marker is created with O_EXCL, so two callers racing on the same day
    print exactly one line between them; there is no check-then-create window.
    """
    env = os.environ if env is None else env
    caller = _clean_name(caller)
    sdir = state_dir(env)
    marker = os.path.join(sdir, "%s%s.%s" % (NOTICE_PREFIX, caller, _today(env)))
    try:
        os.makedirs(sdir, exist_ok=True)
        os.close(os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
    except FileExistsError:
        return ""
    except OSError as e:
        # Loud beats quiet: with no record of today, say it every time.
        return "slack: no channel (cannot record today's notice: %s)" % (e.strerror or type(e).__name__)
    # Drop only older days' markers: a caller whose clock read was just before
    # midnight must not delete the marker another caller made for the new day.
    stem = NOTICE_PREFIX + caller + "."
    for old in glob.glob(os.path.join(glob.escape(sdir), glob.escape(stem) + "*")):
        if os.path.basename(old)[len(stem):] < _today(env):
            try:
                os.unlink(old)
            except OSError:
                pass
    return "slack: no channel"


def _parse_time(text):
    """A date (UTC midnight) or ISO time as an aware datetime; None if invalid."""
    text = (text or "").strip()
    try:
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", text):
            return datetime.datetime.strptime(text, "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc)
        t = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=datetime.timezone.utc)


def count_unposted(since=None, env=None):
    """Count unposted lines at or after `since` (aware datetime or None).

    Returns {"log", "total", "reasons": {reason: {"count", "first"}}, "skipped"}.
    A missing log counts as 0; an unreadable one raises OSError, so a watchdog
    never reads a log it cannot open as all clear.
    """
    path = unposted_log_path(env)
    out = {"log": path, "total": 0, "reasons": {}, "skipped": 0}
    try:
        with open(path, "rb") as f:
            lines = f.read().decode("utf-8", "replace").splitlines()
    except FileNotFoundError:
        return out
    for line in lines:
        if not line.strip():
            continue
        try:
            rec = json.loads(line)
            if not isinstance(rec["ts"], str):  # a number or null is unreadable, not a crash
                raise TypeError("ts is not a string")
            ts = _parse_time(rec["ts"])
            reason = str(rec["reason"])
        except (ValueError, KeyError, TypeError):
            ts = None
        if ts is None:
            out["skipped"] += 1
            continue
        if since is not None and ts < since:
            continue
        out["total"] += 1
        slot = out["reasons"].setdefault(reason, {"count": 0, "first": rec["ts"]})
        slot["count"] += 1
        if ts < _parse_time(slot["first"]):
            slot["first"] = rec["ts"]
    return out


def _cmd_unposted(args):
    since, as_json = None, False
    i = 0
    while i < len(args):
        if args[i] == "--json":
            as_json = True
        elif args[i] == "--since" and i + 1 < len(args):
            since = _parse_time(args[i + 1])
            if since is None:
                print("ERR --since takes YYYY-MM-DD or an ISO time, got %r" % args[i + 1])
                return EXIT_USAGE
            i += 1
        else:
            print("usage: cc-slack-post.py --unposted [--since <date>] [--json]")
            return EXIT_USAGE
        i += 1
    try:
        res = count_unposted(since)
    except OSError as e:
        print("ERR cannot read %s: %s" % (unposted_log_path(), e.strerror or type(e).__name__))
        return EXIT_POST_FAILED
    # An offset --since filters correctly; print it in UTC so the Z is true.
    res["since"] = since.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if since else None
    if as_json:
        print(json.dumps(res, sort_keys=True))
        return 0
    head = "unposted %d" % res["total"]
    head += " since %s" % res["since"] if since else " (all time)"
    print(head + " — log %s" % res["log"])
    for reason, slot in sorted(res["reasons"].items()):
        print("  %s %d first %s" % (reason, slot["count"], slot["first"]))
    if res["skipped"]:
        print("  (%d unreadable line(s) skipped)" % res["skipped"])
    return 0


def _api_url(env):
    url = env.get("CC_SLACK_API_URL")
    if not url:
        return API_URL
    host = urllib.parse.urlsplit(url).hostname or ""
    return url if host in LOOPBACK_HOSTS else None


def _post_failed(reason, message, detail):
    why = append_unposted(reason, len(message), detail)
    print("ERR " + detail + (" (could not log it: %s)" % why if why else ""))
    return EXIT_POST_FAILED


def post(message, thread=None):
    channel, source = resolve_channel()
    if not channel:
        why = append_unposted("no-channel", len(message), source)
        logged = "could not log it: %s" % why if why else "logged to %s" % unposted_log_path()
        print(
            "ERR CC_SLACK_CHANNEL is not set: not in the environment, and %s — not posted, %s. "
            "Set env.CC_SLACK_CHANNEL in %s or export CC_SLACK_CHANNEL (see SETUP.md)."
            % (source, logged, settings_path())
        )
        return EXIT_NO_CHANNEL

    url = _api_url(os.environ)
    if url is None:
        print("ERR CC_SLACK_API_URL must be a loopback URL (it is for tests only)")
        return EXIT_USAGE

    token_file = os.path.expanduser(
        os.environ.get("CC_SLACK_TOKEN_FILE", "~/.claude/.slack-bot-token")
    )
    try:
        with open(token_file) as f:
            token = f.read().strip()
    except OSError as e:
        return _post_failed("token-unreadable", message, "cannot read token file %s: %s" % (token_file, e))

    payload = {"channel": channel, "text": message}
    if thread:
        payload["thread_ts"] = thread
        # Always broadcast thread replies to the channel ("Also send to channel"):
        # plain thread replies do not trigger a Slack alert, so the user never
        # sees that a message is pending.
        payload["reply_broadcast"] = True

    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json; charset=utf-8",
        },
    )
    try:
        resp = json.load(urllib.request.urlopen(req, timeout=30))
    except Exception as e:
        return _post_failed("request-failed", message, "request failed: %s" % e)
    if not isinstance(resp, dict):
        return _post_failed("slack-error", message, "unexpected reply from Slack")

    if resp.get("ok"):
        print("OK")
        print(resp.get("ts", ""))
        return 0
    return _post_failed("slack-error", message, str(resp.get("error")))


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    first = args[0] if args else ""
    if first == "--unposted":
        return _cmd_unposted(args[1:])
    if first == "--which-channel":
        channel, source = resolve_channel()
        if channel:
            print("%s\t%s" % (channel, source))
            return 0
        print("ERR CC_SLACK_CHANNEL is not set: not in the environment, and %s" % source)
        return EXIT_NO_CHANNEL
    if first == "--no-channel-notice":
        line = no_channel_notice(args[1] if len(args) > 1 else "")
        if line:
            print(line)
        return 0
    if first in ("-h", "--help"):
        print(__doc__)
        return 0
    if not first.strip():
        print("usage: cc-slack-post.py <message> [thread_ts]", file=sys.stderr)
        return EXIT_USAGE
    thread = args[1] if len(args) > 1 and args[1] not in ("", "-") else None
    return post(first, thread)


if __name__ == "__main__":
    sys.exit(main())
