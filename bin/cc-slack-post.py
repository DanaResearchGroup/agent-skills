#!/usr/bin/env python3
"""Post a message to the CC comms Slack channel as the bot.

Usage:
    cc-slack-post.py "<message>" [thread_ts]

Prints "OK" then the message ts on success; "ERR <error>" and exits 1 on failure.
Config via env (with sane defaults):
    CC_SLACK_CHANNEL     default "C0B993YLDPT" (#cc-comm)
    CC_SLACK_TOKEN_FILE  default "~/.claude/.slack-bot-token"
"""
import json
import os
import sys
import urllib.request

CHANNEL = os.environ.get("CC_SLACK_CHANNEL", "C0B993YLDPT")
TOKEN_FILE = os.path.expanduser(
    os.environ.get("CC_SLACK_TOKEN_FILE", "~/.claude/.slack-bot-token")
)


def main():
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        sys.exit("usage: cc-slack-post.py <message> [thread_ts]")
    message = sys.argv[1]
    thread = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] not in ("", "-") else None

    try:
        with open(TOKEN_FILE) as f:
            token = f.read().strip()
    except OSError as e:
        print(f"ERR cannot read token file {TOKEN_FILE}: {e}")
        sys.exit(1)

    payload = {"channel": CHANNEL, "text": message}
    if thread:
        payload["thread_ts"] = thread
        # Always broadcast thread replies to the channel ("Also send to channel"):
        # plain thread replies do not trigger a Slack alert, so the user never
        # sees that a message is pending.
        payload["reply_broadcast"] = True

    req = urllib.request.Request(
        "https://slack.com/api/chat.postMessage",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json; charset=utf-8",
        },
    )
    try:
        resp = json.load(urllib.request.urlopen(req, timeout=30))
    except Exception as e:
        print(f"ERR request failed: {e}")
        sys.exit(1)

    if resp.get("ok"):
        print("OK")
        print(resp.get("ts", ""))
    else:
        print("ERR " + str(resp.get("error")))
        sys.exit(1)


if __name__ == "__main__":
    main()
