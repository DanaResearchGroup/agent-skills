#!/usr/bin/env python3
"""Tests for bin/cc-slack-post.py: where the channel comes from, the no-channel
exit, the unposted log, the once-a-day notice and the count (I-441).

Every run is a subprocess with a hand-built environment: a fixture HOME,
CLAUDE_CONFIG_DIR, AUTODEV_HOME and token file, never a copy of os.environ.
Nothing reaches Slack: CC_SLACK_API_URL points at a loopback server this test
owns, and http(s)_proxy point at a closed loopback port, so even a poster that
ignored CC_SLACK_API_URL (official/main does) cannot reach slack.com.
"""
import datetime
import http.server
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
POSTER = os.path.join(os.path.dirname(HERE), "cc-slack-post.py")
NO_CHANNEL = 78
DEAD = "http://127.0.0.1:9"   # discard port: nothing listens, connect fails fast


class FakeSlack(http.server.BaseHTTPRequestHandler):
    """chat.postMessage stand-in; records each request's JSON body."""

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.server.hits.append(json.loads(body or b"{}"))
        reply = json.dumps(self.server.reply).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    def log_message(self, *a):
        pass


def load_poster():
    spec = importlib.util.spec_from_file_location("cc_slack_post", POSTER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class PosterCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="cc slack 'q\" ")   # spaces and quotes
        self.home = os.path.join(self.tmp, "home")
        self.config = os.path.join(self.tmp, "claude config")
        self.agents = os.path.join(self.tmp, "agents")
        os.makedirs(self.home)
        os.makedirs(self.config)
        self.token = os.path.join(self.tmp, "token")
        with open(self.token, "w") as f:
            f.write("xoxb-test-not-a-real-token\n")
        self.server = http.server.HTTPServer(("127.0.0.1", 0), FakeSlack)
        self.server.hits = []
        self.server.reply = {"ok": True, "ts": "1700000000.000100"}
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.api = "http://127.0.0.1:%d/api/chat.postMessage" % self.server.server_port

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        for root, dirs, _ in os.walk(self.tmp):
            for d in dirs:
                try:
                    os.chmod(os.path.join(root, d), 0o755)
                except OSError:
                    pass
        shutil.rmtree(self.tmp, ignore_errors=True)

    def env(self, **extra):
        e = {
            "HOME": self.home,
            "PATH": "/usr/bin:/bin",
            "CLAUDE_CONFIG_DIR": self.config,
            "AUTODEV_HOME": self.agents,
            "CC_SLACK_TOKEN_FILE": self.token,
            "CC_SLACK_API_URL": self.api,
            "CC_SLACK_CALLER": "poster-test",
            "http_proxy": DEAD, "https_proxy": DEAD,
            "HTTP_PROXY": DEAD, "HTTPS_PROXY": DEAD,
            "no_proxy": "127.0.0.1,localhost", "NO_PROXY": "127.0.0.1,localhost",
        }
        for k, v in extra.items():
            if v is None:
                e.pop(k, None)
            else:
                e[k] = v
        return e

    def run_poster(self, *args, cwd=None, **extra):
        return subprocess.run(
            [sys.executable, POSTER, *args], env=self.env(**extra), cwd=cwd,
            capture_output=True, text=True, timeout=60,
        )

    def write_settings(self, content, config=None):
        path = os.path.join(config or self.config, "settings.json")
        with open(path, "w") as f:
            f.write(content if isinstance(content, str) else json.dumps(content))
        return path

    @property
    def log(self):
        return os.path.join(self.agents, "state", "slack-unposted.jsonl")

    def log_lines(self):
        try:
            with open(self.log) as f:
                return [json.loads(x) for x in f if x.strip()]
        except FileNotFoundError:
            return []

    def assert_no_channel(self, r, why_part=None):
        self.assertEqual(r.returncode, NO_CHANNEL, r.stdout + r.stderr)
        out = r.stdout.strip().splitlines()
        self.assertEqual(len(out), 1, r.stdout)
        self.assertTrue(out[0].startswith("ERR CC_SLACK_CHANNEL is not set"), out[0])
        self.assertIn("env.CC_SLACK_CHANNEL", out[0])
        self.assertIn("settings.json", out[0])
        self.assertNotIn("Traceback", r.stderr)
        if why_part:
            self.assertIn(why_part, out[0])
        self.assertEqual(self.server.hits, [], "no-channel must make no request")


class ChannelSource(PosterCase):
    def test_env_wins_over_settings(self):
        self.write_settings({"env": {"CC_SLACK_CHANNEL": "CFROMSETTINGS"}})
        r = self.run_poster("hello", CC_SLACK_CHANNEL="CFROMENV")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual(r.stdout.splitlines(), ["OK", "1700000000.000100"])
        self.assertEqual([h["channel"] for h in self.server.hits], ["CFROMENV"])

    def test_settings_alone(self):
        self.write_settings({"env": {"CC_SLACK_CHANNEL": "CFROMSETTINGS", "OTHER": "x"}})
        r = self.run_poster("hello", CC_SLACK_CHANNEL=None)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual([h["channel"] for h in self.server.hits], ["CFROMSETTINGS"])
        self.assertEqual(self.log_lines(), [])

    def test_default_settings_under_home(self):
        dot = os.path.join(self.home, ".claude")
        os.makedirs(dot)
        self.write_settings({"env": {"CC_SLACK_CHANNEL": "CHOMEDEFAULT"}}, config=dot)
        r = self.run_poster("hello", CLAUDE_CONFIG_DIR=None)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual([h["channel"] for h in self.server.hits], ["CHOMEDEFAULT"])

    def test_empty_env_falls_through_to_settings(self):
        self.write_settings({"env": {"CC_SLACK_CHANNEL": "CFROMSETTINGS"}})
        r = self.run_poster("hello", CC_SLACK_CHANNEL="  ")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual([h["channel"] for h in self.server.hits], ["CFROMSETTINGS"])

    def test_thread_reply_is_broadcast(self):
        r = self.run_poster("hello", "1700000000.000001", CC_SLACK_CHANNEL="CENV")
        self.assertEqual(r.returncode, 0, r.stdout)
        hit = self.server.hits[0]
        self.assertEqual(hit["thread_ts"], "1700000000.000001")
        self.assertIs(hit["reply_broadcast"], True)

    def test_malformed_settings_are_no_channel(self):
        cases = {
            "missing": None,
            "empty": "",
            "whitespace": "  \n",
            "not json": "{not json",
            "list": "[1, 2]",
            "env not object": json.dumps({"env": "CFOO"}),
            "no key": json.dumps({"env": {"OTHER": "x"}}),
            "number": json.dumps({"env": {"CC_SLACK_CHANNEL": 12345}}),
            "null": json.dumps({"env": {"CC_SLACK_CHANNEL": None}}),
            "list value": json.dumps({"env": {"CC_SLACK_CHANNEL": ["C1"]}}),
            "empty value": json.dumps({"env": {"CC_SLACK_CHANNEL": ""}}),
            "bad utf8": b"\xff\xfe{",
            "deep": "[" * 100000 + "]" * 100000,
        }
        for name, content in cases.items():
            with self.subTest(name):
                path = os.path.join(self.config, "settings.json")
                if os.path.exists(path):
                    os.unlink(path)
                if isinstance(content, bytes):
                    with open(path, "wb") as f:
                        f.write(content)
                elif content is not None:
                    self.write_settings(content)
                r = self.run_poster("hello", CC_SLACK_CHANNEL=None)
                self.assert_no_channel(r)

    def test_settings_values_never_echoed(self):
        self.write_settings({"env": {"CC_SLACK_CHANNEL": 7, "SECRET_THING": "sekrit-value-9"}})
        r = self.run_poster("hello", CC_SLACK_CHANNEL=None)
        self.assert_no_channel(r)
        self.assertNotIn("sekrit-value-9", r.stdout + r.stderr)
        with open(self.log) as f:
            self.assertNotIn("sekrit-value-9", f.read())


class PathForms(PosterCase):
    """The input classes for every path the poster reads or writes."""

    def no_channel_with_settings_at(self, make):
        path = os.path.join(self.config, "settings.json")
        make(path)
        r = self.run_poster("hello", CC_SLACK_CHANNEL=None)
        self.assert_no_channel(r)
        return r

    def test_dangling_symlink(self):
        r = self.no_channel_with_settings_at(lambda p: os.symlink(os.path.join(self.tmp, "nowhere"), p))
        self.assertIn("is missing", r.stdout)

    def test_symlink_loop(self):
        def make(p):
            other = os.path.join(self.config, "loop2")
            os.symlink(other, p)
            os.symlink(p, other)
        r = self.no_channel_with_settings_at(make)
        self.assertIn("is unreadable", r.stdout)

    def test_symlink_to_directory(self):
        def make(p):
            d = os.path.join(self.tmp, "a dir")
            os.makedirs(d)
            os.symlink(d, p)
        r = self.no_channel_with_settings_at(make)
        self.assertIn("is unreadable", r.stdout)

    def test_fifo_does_not_hang(self):
        r = self.no_channel_with_settings_at(os.mkfifo)
        self.assertIn("is not a regular file", r.stdout)

    def test_symlink_to_good_file_is_followed(self):
        real = os.path.join(self.tmp, "real settings.json")
        with open(real, "w") as f:
            json.dump({"env": {"CC_SLACK_CHANNEL": "CVIALINK"}}, f)
        os.symlink(real, os.path.join(self.config, "settings.json"))
        r = self.run_poster("hello", CC_SLACK_CHANNEL=None)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual([h["channel"] for h in self.server.hits], ["CVIALINK"])

    def test_unexpanded_tilde(self):
        cfg = os.path.join(self.home, "tilde cfg")
        os.makedirs(cfg)
        self.write_settings({"env": {"CC_SLACK_CHANNEL": "CTILDE"}}, config=cfg)
        r = self.run_poster("hello", CC_SLACK_CHANNEL=None, CLAUDE_CONFIG_DIR="~/tilde cfg",
                            AUTODEV_HOME="~/agents-tilde")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual([h["channel"] for h in self.server.hits], ["CTILDE"])
        os.unlink(os.path.join(cfg, "settings.json"))
        r = self.run_poster("hello", CC_SLACK_CHANNEL=None, CLAUDE_CONFIG_DIR="~/tilde cfg",
                            AUTODEV_HOME="~/agents-tilde")
        self.assertEqual(r.returncode, NO_CHANNEL, r.stdout)
        self.assertTrue(os.path.isfile(os.path.join(self.home, "agents-tilde", "state", "slack-unposted.jsonl")))
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "~")))

    def test_relative_paths(self):
        cwd = os.path.join(self.tmp, "work dir")
        os.makedirs(os.path.join(cwd, "rel cfg"))
        self.write_settings({"env": {"CC_SLACK_CHANNEL": "CREL"}}, config=os.path.join(cwd, "rel cfg"))
        r = self.run_poster("hello", cwd=cwd, CC_SLACK_CHANNEL=None, CLAUDE_CONFIG_DIR="rel cfg")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual([h["channel"] for h in self.server.hits], ["CREL"])
        r = self.run_poster("hello", cwd=cwd, CC_SLACK_CHANNEL=None, CLAUDE_CONFIG_DIR="nope",
                            AUTODEV_HOME="rel agents")
        self.assertEqual(r.returncode, NO_CHANNEL, r.stdout)
        self.assertTrue(os.path.isfile(os.path.join(cwd, "rel agents", "state", "slack-unposted.jsonl")))

    def test_spaces_and_quotes(self):
        cfg = os.path.join(self.tmp, "it's a \"cfg\" dir")
        os.makedirs(cfg)
        self.write_settings({"env": {"CC_SLACK_CHANNEL": "CQUOTED"}}, config=cfg)
        r = self.run_poster("hello", CC_SLACK_CHANNEL=None, CLAUDE_CONFIG_DIR=cfg)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual([h["channel"] for h in self.server.hits], ["CQUOTED"])

    @unittest.skipIf(os.geteuid() == 0, "root reads any directory")
    def test_unreadable_parent(self):
        self.write_settings({"env": {"CC_SLACK_CHANNEL": "CHIDDEN"}})
        os.chmod(self.config, 0)
        r = self.run_poster("hello", CC_SLACK_CHANNEL=None)
        self.assert_no_channel(r, "is unreadable")

    @unittest.skipIf(os.geteuid() == 0, "root writes any directory")
    def test_unwritable_state_still_no_channel_exit(self):
        os.makedirs(os.path.join(self.agents, "state"))
        os.chmod(os.path.join(self.agents, "state"), 0o555)
        r = self.run_poster("hello", CC_SLACK_CHANNEL=None)
        self.assert_no_channel(r, "could not log it")
        n = self.run_poster("--no-channel-notice", "x", CC_SLACK_CHANNEL=None)
        self.assertEqual(n.returncode, 0)
        self.assertTrue(n.stdout.startswith("slack: no channel"), n.stdout)

    def test_glob_characters_are_literal(self):
        r = self.run_poster("hello", CC_SLACK_CHANNEL=None,
                            CLAUDE_CONFIG_DIR=os.path.join(self.tmp, "no*match?[x]"))
        self.assert_no_channel(r, "is missing")
        # A notice caller whose old-marker glob matches nothing still works.
        n = self.run_poster("--no-channel-notice", "fresh*caller")
        self.assertEqual(n.stdout.strip(), "slack: no channel")


class NoChannel(PosterCase):
    def test_exit_err_log_and_no_request(self):
        r = self.run_poster("first-use test message", CC_SLACK_CHANNEL=None)
        self.assert_no_channel(r)
        self.assertIn("not posted, logged to " + self.log, r.stdout)
        lines = self.log_lines()
        self.assertEqual(len(lines), 1)
        rec = lines[0]
        self.assertEqual(rec["reason"], "no-channel")
        self.assertEqual(rec["caller"], "poster-test")
        self.assertEqual(rec["message_len"], len("first-use test message"))
        self.assertRegex(rec["ts"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
        with open(self.log) as f:
            self.assertNotIn("first-use test message", f.read())

    def test_no_token_read_without_channel(self):
        r = self.run_poster("hello", CC_SLACK_CHANNEL=None, CC_SLACK_TOKEN_FILE=os.path.join(self.tmp, "absent"))
        self.assert_no_channel(r)

    def test_which_channel(self):
        r = self.run_poster("--which-channel", CC_SLACK_CHANNEL=None)
        self.assertEqual(r.returncode, NO_CHANNEL)
        self.assertEqual(self.log_lines(), [], "asking which channel posts nothing and logs nothing")
        self.write_settings({"env": {"CC_SLACK_CHANNEL": "CWHICH"}})
        r = self.run_poster("--which-channel", CC_SLACK_CHANNEL=None)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip().split("\t")[0], "CWHICH")
        self.assertEqual(self.server.hits, [])

    def test_importable_resolver(self):
        mod = load_poster()
        self.write_settings({"env": {"CC_SLACK_CHANNEL": "CIMPORT"}})
        self.assertEqual(mod.resolve_channel(self.env(CC_SLACK_CHANNEL=None)),
                         ("CIMPORT", "settings " + os.path.join(self.config, "settings.json")))
        self.assertEqual(mod.resolve_channel(self.env(CC_SLACK_CHANNEL="CE"))[0], "CE")
        ch, why = mod.resolve_channel(self.env(CC_SLACK_CHANNEL=None, CLAUDE_CONFIG_DIR=self.tmp))
        self.assertIsNone(ch)
        self.assertIn("is missing", why)

    def test_usage_is_not_post_failed(self):
        r = self.run_poster(CC_SLACK_CHANNEL=None)
        self.assertEqual(r.returncode, 2)
        self.assertEqual(self.log_lines(), [])

    def test_non_loopback_api_url_refused(self):
        r = self.run_poster("hello", CC_SLACK_CHANNEL="CENV", CC_SLACK_API_URL="http://example.invalid/x")
        self.assertEqual(r.returncode, 2, r.stdout)
        self.assertEqual(self.server.hits, [])


class FailedPost(PosterCase):
    def test_slack_error(self):
        self.server.reply = {"ok": False, "error": "channel_not_found"}
        r = self.run_poster("hello there", CC_SLACK_CHANNEL="CENV")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertEqual(r.stdout.strip(), "ERR channel_not_found")
        lines = self.log_lines()
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0]["reason"], "slack-error")
        self.assertEqual(lines[0]["detail"], "channel_not_found")
        self.assertEqual(lines[0]["message_len"], len("hello there"))

    def test_network_error(self):
        r = self.run_poster("hello", CC_SLACK_CHANNEL="CENV", CC_SLACK_API_URL=DEAD + "/api")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertTrue(r.stdout.startswith("ERR request failed"), r.stdout)
        lines = self.log_lines()
        self.assertEqual([rec["reason"] for rec in lines], ["request-failed"])

    def test_token_unreadable(self):
        r = self.run_poster("hello", CC_SLACK_CHANNEL="CENV", CC_SLACK_TOKEN_FILE=os.path.join(self.tmp, "absent"))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertEqual([rec["reason"] for rec in self.log_lines()], ["token-unreadable"])
        self.assertEqual(self.server.hits, [])


class Notice(PosterCase):
    def notice(self, caller, day):
        return self.run_poster("--no-channel-notice", caller, CC_SLACK_TODAY=day)

    def test_once_per_day_per_caller(self):
        a = self.notice("slack-notify", "2026-11-17")
        b = self.notice("slack-notify", "2026-11-17")
        c = self.notice("slack-ask", "2026-11-17")
        d = self.notice("slack-notify", "2026-11-18")
        for r in (a, b, c, d):
            self.assertEqual(r.returncode, 0)
        self.assertEqual(a.stdout.strip(), "slack: no channel")
        self.assertEqual(b.stdout.strip(), "")
        self.assertEqual(c.stdout.strip(), "slack: no channel")
        self.assertEqual(d.stdout.strip(), "slack: no channel")
        markers = sorted(f for f in os.listdir(os.path.join(self.agents, "state")) if f.startswith("slack-no-channel."))
        self.assertEqual(markers, ["slack-no-channel.slack-ask.2026-11-17",
                                   "slack-no-channel.slack-notify.2026-11-18"])

    def test_late_caller_keeps_newer_marker(self):
        self.assertEqual(self.notice("slack-notify", "2026-11-18").stdout.strip(), "slack: no channel")
        # A caller whose date was read just before midnight runs after it.
        self.assertEqual(self.notice("slack-notify", "2026-11-17").stdout.strip(), "slack: no channel")
        self.assertEqual(self.notice("slack-notify", "2026-11-18").stdout.strip(), "")

    def test_racing_callers_print_one_line(self):
        procs = [subprocess.Popen([sys.executable, POSTER, "--no-channel-notice", "racer"],
                                  env=self.env(CC_SLACK_TODAY="2026-11-17"),
                                  stdout=subprocess.PIPE, text=True) for _ in range(8)]
        outs = [p.communicate(timeout=60)[0] for p in procs]
        self.assertEqual(sum(o.strip() == "slack: no channel" for o in outs), 1, outs)


class Count(PosterCase):
    FIXTURE = [
        {"ts": "2026-11-10T08:00:00Z", "caller": "a", "reason": "no-channel", "message_len": 5, "detail": ""},
        {"ts": "2026-11-16T09:00:00Z", "caller": "a", "reason": "no-channel", "message_len": 5, "detail": ""},
        {"ts": "2026-11-17T07:00:00Z", "caller": "b", "reason": "slack-error", "message_len": 3, "detail": "x"},
        {"ts": "2026-11-17T06:00:00Z", "caller": "c", "reason": "no-channel", "message_len": 1, "detail": ""},
    ]

    def write_log(self, recs, extra=""):
        os.makedirs(os.path.dirname(self.log), exist_ok=True)
        with open(self.log, "w") as f:
            f.write("".join(json.dumps(r) + "\n" for r in recs) + extra)

    def count(self, *args):
        r = self.run_poster("--unposted", *args, "--json")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return json.loads(r.stdout)

    def test_counts_by_reason_and_first_seen(self):
        self.write_log(self.FIXTURE, extra="not json\n\n")
        res = self.count()
        self.assertEqual(res["total"], 4)
        self.assertEqual(res["reasons"]["no-channel"], {"count": 3, "first": "2026-11-10T08:00:00Z"})
        self.assertEqual(res["reasons"]["slack-error"], {"count": 1, "first": "2026-11-17T07:00:00Z"})
        self.assertEqual(res["skipped"], 1)
        res = self.count("--since", "2026-11-16")
        self.assertEqual(res["total"], 3)
        self.assertEqual(res["reasons"]["no-channel"], {"count": 2, "first": "2026-11-16T09:00:00Z"})
        res = self.count("--since", "2026-11-17T06:30:00Z")
        self.assertEqual(res["total"], 1)
        self.assertEqual(list(res["reasons"]), ["slack-error"])

    def test_text_output(self):
        self.write_log(self.FIXTURE)
        r = self.run_poster("--unposted", "--since", "2026-11-16")
        self.assertEqual(r.returncode, 0)
        lines = r.stdout.splitlines()
        self.assertTrue(lines[0].startswith("unposted 3 since 2026-11-16T00:00:00Z"), lines[0])
        self.assertIn("  no-channel 2 first 2026-11-16T09:00:00Z", lines)
        self.assertIn("  slack-error 1 first 2026-11-17T07:00:00Z", lines)

    def test_offset_since_prints_utc(self):
        self.write_log(self.FIXTURE)
        # 08:30+02:00 is 06:30Z: one line is at or after it.
        res = self.count("--since", "2026-11-17T08:30:00+02:00")
        self.assertEqual((res["since"], res["total"]), ("2026-11-17T06:30:00Z", 1))
        r = self.run_poster("--unposted", "--since", "2026-11-17T08:30:00+02:00")
        self.assertTrue(r.stdout.startswith("unposted 1 since 2026-11-17T06:30:00Z —"), r.stdout)

    def test_non_string_ts_is_skipped_not_a_crash(self):
        good = dict(self.FIXTURE[0])
        self.write_log([dict(good, ts=1700000000), dict(good, ts=None), good])
        res = self.count()
        self.assertEqual((res["total"], res["skipped"]), (1, 2))
        r = self.run_poster("--unposted")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("  (2 unreadable line(s) skipped)", r.stdout.splitlines())

    def test_missing_and_empty_log_is_zero(self):
        self.assertEqual(self.count()["total"], 0)
        self.write_log([])
        res = self.count("--since", "2026-01-01")
        self.assertEqual((res["total"], res["reasons"]), (0, {}))

    def test_counts_real_poster_lines(self):
        for _ in range(2):
            self.run_poster("hello", CC_SLACK_CHANNEL=None)
        today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
        res = self.count("--since", today)
        self.assertEqual(res["reasons"]["no-channel"]["count"], 2)

    @unittest.skipIf(os.geteuid() == 0, "root reads any file")
    def test_unreadable_log_is_not_zero(self):
        self.write_log(self.FIXTURE)
        os.chmod(self.log, 0)
        r = self.run_poster("--unposted")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertTrue(r.stdout.startswith("ERR cannot read"), r.stdout)

    def test_bad_since(self):
        r = self.run_poster("--unposted", "--since", "last tuesday")
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
