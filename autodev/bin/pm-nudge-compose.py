#!/usr/bin/env python3
"""pm-nudge-compose.py — turn already-decided facts into one short nudge sentence.

Reads a facts JSON object on stdin, prints the nudge text on stdout, and exits 0.
On ANY failure — bad input, missing SDK, missing key, API error, empty or
unusable completion — it prints a diagnostic on stderr and exits non-zero, and
pm-nudge-sweep.sh falls back to its fixed baseline string. That asymmetry is the
contract: the nudge always fires, the model only ever changes the wording.

WHY THIS IS A SEPARATE PROCESS. Asking an in-session Claude Code subagent for
this sentence pays a full prompt-prefix rewrite (100-400k tokens) before it
thinks at all — ~$0.169/call measured on this machine — against ~$0.01 for a bare
Haiku call through the SDK. A two-line nudge is not worth a prefix rewrite. It
also keeps the model strictly out of the firing decision: this script is only
ever invoked AFTER the sweeper has decided to nudge, and it has no way to say no.

WHY ITS OWN VENV. The ambient anaconda python on this machine cannot import the
SDK at all (`cannot import name 'validate_core_schema' from 'pydantic_core'`), and
a daemon must not inherit whichever interpreter happens to be first on $PATH at
timer-fire time. pm-nudge-install.sh builds $AUTODEV_HOME/venv/pm-nudge and the
sweeper invokes that interpreter by absolute path.

Model id is the BARE, undated `claude-haiku-4-5`. Date-suffixed ids are pinned
snapshots; the bundled claude-api reference carries a standing warning against
appending them, and the same bare id is what the plugin tree's own pricing table
keys on ($1.00 / $5.00 per 1M input / output tokens).

Usage:  echo '<facts json>' | pm-nudge-compose.py [--facts FILE] [--dry-prompt]
"""

import json
import os
import re
import sys

MODEL = "claude-haiku-4-5"
PRICE_IN_PER_MTOK = 1.00
PRICE_OUT_PER_MTOK = 5.00
MAX_TOKENS = 150
# Belt and braces against a runaway completion. max_tokens caps the API's work;
# this caps what can reach a live pane, which is a different question — a model
# that answers in 150 tokens of one long line is still 600 characters typed at
# somebody's session.
DEFAULT_MAX_CHARS = 240
HARD_MAX_CHARS = 400

# This script is fired by the sweeper's own timer, PM_NUDGE_SWEEP_EVERY, every
# 5 minutes (pm-nudge-install.sh). The anthropic SDK's default timeout is on
# the order of 10 minutes and it retries transient failures on top of that --
# fine for an interactive call, dangerous here: a slow or hanging request
# could still be in flight when the next sweep fires, stacking a second
# invocation on top of it against facts that are already stale. Keep both
# short and bounded so a bad call fails fast and falls back to the baseline
# string well within one sweep interval, rather than overlapping the next one.
HTTP_TIMEOUT_SECONDS = 20
HTTP_MAX_RETRIES = 1

# Two situations, two system prompts. `situation` is decided deterministically
# by the sweeper (never by this script) and handed in verbatim; which prompt is
# selected is a plain if/else in main(), with no shared branch, so a "nothing
# ran" workspace can never be steered by the "fleet finished" wording and vice
# versa. Compare pm-nudge-sweep.sh's BASELINE_FINISHED / BASELINE_NO_WORKERS
# split, which is the same separation enforced at the fallback-string layer.
SYSTEM_COMMON = (
    "You write a single short nudge message that will be typed into a project-manager "
    "Claude Code session.\n"
    "Rules, all mandatory:\n"
    "- Use ONLY the facts in the JSON you are given. Invent nothing: no ticket numbers, "
    "no outcomes, no file names, no judgements about whether work succeeded.\n"
    "- One or two sentences, plain text, no markdown, no quotes around it, no preamble, "
    "no sign-off, no line breaks.\n"
    "- Stay strictly under the `max_chars` character limit.\n"
    "- Address the PM directly in the second person.\n"
    "Output the message and nothing else."
)

SYSTEM_WORKERS_FINISHED = SYSTEM_COMMON + (
    "\nSituation: the worker sessions in this campaign have all finished (idle, done, or their "
    "panes are gone). Keep the meaning of the anchor sentence in `baseline`: the fleet is done, "
    "collect and close, ask what is next."
)

SYSTEM_NO_WORKERS = SYSTEM_COMMON + (
    "\nSituation: this campaign's PM has NO worker sessions running and none were ever observed "
    "during this quiet window (workers_seen_total is 0). Nothing has finished and there is "
    "nothing to collect or close — do NOT say or imply that anything finished, was collected, "
    "was closed, or was done. Keep the meaning of the anchor sentence in `baseline`: nothing is "
    "running in this campaign, ask what should be dispatched next."
)

# Words a no-workers-ever message must never contain, because they claim a
# completion that did not happen. Checked in code (not left to the model)
# because the model call is exactly the point where nothing is watching if the
# API is degraded — enforcing this only in the prompt would not hold then.
_FINISHED_CLAIM_RE = re.compile(
    r"\b(done|finished|complete[d]?|collect(ed)?|close[d]?|wrapped up)\b", re.I
)


def die(msg: str) -> "None":
    print(f"pm-nudge-compose: {msg}", file=sys.stderr)
    sys.exit(1)


def load_facts() -> dict:
    src = None
    args = sys.argv[1:]
    if "--facts" in args:
        i = args.index("--facts")
        try:
            with open(args[i + 1], encoding="utf-8") as fh:
                src = fh.read()
        except (IndexError, OSError) as exc:
            die(f"cannot read --facts file: {exc}")
    else:
        src = sys.stdin.read()
    if not src or not src.strip():
        die("no facts on stdin")
    try:
        facts = json.loads(src)
    except json.JSONDecodeError as exc:
        die(f"facts are not valid JSON: {exc}")
    if not isinstance(facts, dict):
        die("facts must be a JSON object")
    if not facts.get("baseline"):
        die("facts carry no baseline anchor")
    return facts


def build_user_prompt(facts: dict) -> str:
    """Hand the model a compact, already-summarised view rather than raw herdr JSON.

    Raw pane records carry revisions, terminal ids and scroll state that cost input
    tokens and give the model more surface to hallucinate from. Everything below is
    a fact the sweeper already established deterministically.
    """
    ws = facts.get("workspace", {}) or {}
    pm = facts.get("pm", {}) or {}
    present = facts.get("workers_present", []) or []
    gone = facts.get("workers_gone", []) or []
    quiet_s = int(pm.get("quiet_seconds", 0) or 0)
    quiet_min = max(1, quiet_s // 60)

    def name(w):
        return (w.get("label") or "").strip() or os.path.basename(
            (w.get("cwd") or "").rstrip("/")
        ) or w.get("pane_id", "?")

    view = {
        "campaign": ws.get("label") or ws.get("id"),
        "situation": facts.get("situation"),
        "pm_working_dir": os.path.basename((pm.get("cwd") or "").rstrip("/")),
        "pm_status": pm.get("status"),
        "pm_quiet_for_minutes": quiet_min,
        "workers_seen_total": int(facts.get("workers_seen_total") or 0),
        "workers_gone_count": int(facts.get("workers_gone_count") or 0),
        "finished_workers_still_open": [
            {"name": name(w), "status": w.get("status")} for w in present
        ],
        "workers_whose_panes_are_gone": [name(w) for w in gone],
        "worker_count_total": len(present) + len(gone),
        "baseline": facts.get("baseline"),
        "max_chars": int(facts.get("max_chars") or DEFAULT_MAX_CHARS),
    }
    digest = facts.get("fleet_digest")
    if isinstance(digest, dict) and digest:
        # Opportunistic extra context, included only when it is small enough to
        # be free. This file is produced by another tool entirely, so its size is
        # not our contract and an unbounded one must not inflate every call.
        blob = json.dumps(digest, sort_keys=True)
        view["fleet_digest"] = digest if len(blob) <= 1500 else "(present, too large to include)"

    return (
        "Facts (JSON):\n"
        + json.dumps(view, indent=2, sort_keys=True)
        + f"\n\nWrite the nudge, under {view['max_chars']} characters."
    )


def clean(text: str, max_chars: int) -> str:
    """Collapse to one line, strip decoration, and cap length IN CODE.

    A newline that survives to the sweeper would be staged into the pane's input
    line and submit it, turning --stage-only into a send. Stripping happens here
    as well as in the shell because neither layer should have to trust the other.
    """
    text = re.sub(r"\s+", " ", text).strip()
    text = text.strip('"').strip("'").strip()
    text = re.sub(r"^(?:here(?:'s| is)[^:]*:|nudge:|message:)\s*", "", text, flags=re.I).strip()
    if len(text) > max_chars:
        cut = text[:max_chars]
        # Prefer a clean word boundary, but only if it does not gut the sentence.
        sp = cut.rfind(" ")
        text = (cut[:sp] if sp > max_chars * 0.6 else cut).rstrip(" ,;:-") + "…"
    return text


def main() -> int:
    facts = load_facts()
    max_chars = int(facts.get("max_chars") or DEFAULT_MAX_CHARS)
    max_chars = max(40, min(max_chars, HARD_MAX_CHARS))
    prompt = build_user_prompt(facts)
    situation = facts.get("situation")
    no_workers = situation == "no_workers_ever"
    SYSTEM = SYSTEM_NO_WORKERS if no_workers else SYSTEM_WORKERS_FINISHED

    if "--dry-prompt" in sys.argv[1:]:
        # Lets the prompt be inspected (and diffed in review) without spending a
        # token or needing a key.
        print(SYSTEM + "\n\n---\n\n" + prompt)
        return 0

    try:
        import anthropic
    except ImportError as exc:
        die(f"anthropic SDK unavailable in {sys.executable}: {exc}")

    if not (os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN")):
        die("ANTHROPIC_API_KEY is not set")

    try:
        client = anthropic.Anthropic(
            timeout=HTTP_TIMEOUT_SECONDS, max_retries=HTTP_MAX_RETRIES
        )
        resp = client.messages.create(
            model=MODEL,
            max_tokens=MAX_TOKENS,
            system=SYSTEM,
            messages=[{"role": "user", "content": prompt}],
        )
    except anthropic.AuthenticationError as exc:
        die(f"auth rejected (401): {exc}")
    except anthropic.PermissionDeniedError as exc:
        die(f"permission denied (403): {exc}")
    except anthropic.NotFoundError as exc:
        die(f"model or endpoint not found (404) for '{MODEL}': {exc}")
    except anthropic.BadRequestError as exc:
        die(f"bad request (400): {exc}")
    except anthropic.RateLimitError as exc:
        # Deliberately NOT retried. This call is on a timer that fires again in
        # minutes, and the sweeper's baseline covers the gap; a retry loop here
        # would only hold the cycle lock while the pane state goes stale.
        retry = getattr(getattr(exc, "response", None), "headers", {}) or {}
        die(f"rate limited (429), retry-after={retry.get('retry-after', 'n/a')}; not retrying")
    except anthropic.APIConnectionError as exc:
        die(f"could not reach the API: {exc}")
    except anthropic.APIStatusError as exc:
        kind = "server error" if getattr(exc, "status_code", 0) >= 500 else "API error"
        die(f"{kind} ({getattr(exc, 'status_code', '?')}): {exc}")
    except Exception as exc:  # noqa: BLE001 — the daemon must degrade, never traceback
        die(f"unexpected failure: {type(exc).__name__}: {exc}")

    parts = [b.text for b in (resp.content or []) if getattr(b, "type", None) == "text"]
    text = clean(" ".join(parts), max_chars)
    if not text:
        die("model returned no usable text")
    if no_workers and _FINISHED_CLAIM_RE.search(text):
        # The one guard that cannot live in the prompt alone: this is exactly the
        # call site where nothing else is watching if the model drifts. A
        # no-workers-ever nudge that says "done"/"collect"/"close" is the false
        # claim this whole fix exists to prevent, so treat it as a failed
        # completion and let the sweeper fall back to BASELINE_NO_WORKERS.
        die(f"model output for situation=no_workers_ever contains a finished-claim word: {text!r}")

    usage = getattr(resp, "usage", None)
    if usage is not None:
        cost = (
            usage.input_tokens * PRICE_IN_PER_MTOK
            + usage.output_tokens * PRICE_OUT_PER_MTOK
        ) / 1_000_000
        print(
            f"pm-nudge-compose: model={MODEL} input_tokens={usage.input_tokens} "
            f"output_tokens={usage.output_tokens} cost_usd={cost:.6f}",
            file=sys.stderr,
        )

    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
