---
name: spar
description: Use when you want adversarial "try to break this" feedback from Codex on the current code, plan, or decision, want a persistent per-project sparring record, or are mid-decision and want a second opinion before committing to an approach.
argument-hint: "What should Codex challenge? (or a round number to review)"
---

Run an adversarial Codex sparring round and persist the exchange under
`~/agents/adversarial/{slug}/`.

Use this skill as an inline Codex wrapper, not as a manual two-terminal file drop. Claude Code
composes the question artifact, invokes `codex exec`, writes the answer artifact, updates the log,
and then presents Codex's findings verbatim.

## Subcommands

- `/spar <topic>`: start a new round.
- `/spar review [round-N]`: re-read the latest answer, or the requested round answer.
- `/spar log`: show `sparring-log.md`.
- `/spar reset`: archive `.session-id` so the next round starts a fresh Codex session (a hard
  reset — no handoff summary).

Codex context is kept healthy automatically: when the persistent session crosses 35% fill,
`/spar <topic>` has the outgoing session summarize itself and rotates to a fresh, reseeded session
before asking the new question. See **Codex Context Auto-Handoff** below.

## Setup

Run setup before any new round:

```bash
eval "$(~/.claude/skills/gstack/bin/gstack-slug 2>/dev/null)" 2>/dev/null || true
[ -z "${SLUG:-}" ] && SLUG=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" | tr -cd 'a-zA-Z0-9._-')
SLUG="${SLUG:-unknown}"
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
STORE="$HOME/agents/adversarial/$SLUG"
umask 077
mkdir -p "$STORE"
chmod 700 "$HOME/agents" "$HOME/agents/adversarial" "$STORE" 2>/dev/null || true
```

Run the Codex auth probe:

```bash
~/.claude/skills/gstack/bin/gstack-codex-probe
```

If it prints `AUTH_FAILED` or exits non-zero, stop and tell the user:
`No Codex authentication found. Run codex login or set $CODEX_API_KEY / $OPENAI_API_KEY, then re-run /spar.`

Bind the store to the current repo before using any persisted session. This avoids accidentally
resuming a session from another repo with the same slug:

```bash
META_FILE="$STORE/.project"
CANON_ROOT=$(cd "$REPO_ROOT" && pwd -P)
if [ -f "$META_FILE" ] && ! grep -qx "repo_root=$CANON_ROOT" "$META_FILE"; then
  echo "ERROR: $STORE is already bound to a different repo root. Use a different slug or /spar reset."
  exit 1
fi
if [ ! -f "$META_FILE" ]; then
  {
    printf 'repo_root=%s\n' "$CANON_ROOT"
    printf 'created_at=%s\n' "$(date +"%Y.%m.%d %H.%M.%S")"
  } > "$META_FILE.tmp" && mv "$META_FILE.tmp" "$META_FILE"
fi
```

Take a per-project lock before computing round numbers or touching `.session-id`, round files, or
`sparring-log.md`:

```bash
LOCKDIR="$STORE/.lock"
until mkdir "$LOCKDIR" 2>/dev/null; do sleep 1; done
trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT
```

## Codex Context Auto-Handoff

Before composing a **substantive** round (`/spar <topic>` — NOT `reset`, `log`, or `review`),
keep the persistent Codex session from silently saturating. Because the session is resumed every
round, its context window fills monotonically; a saturated session degrades **without warning**
exactly when the late, highest-stakes reviews run. When the session crosses **35% fill**, have
the outgoing session write its own successor handoff, then rotate to a fresh session seeded with
it. This is automatic and self-contained — the user does not ask for it.

Run this right after taking the lock:

```bash
THRESHOLD=35                       # Codex context %; at/above this, rotate to a fresh session.
HANDOFF_FILE="$STORE/.handoff.md"
PENDING_HANDOFF=0
PYTHON_CMD=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)

if [ -f "$STORE/.session-id" ] && [ -n "$PYTHON_CMD" ]; then
  OLD_SID=$(cat "$STORE/.session-id")
  # Fresh, per-session fill % straight from THIS session's rollout via the script's stdout
  # (not the shared global status-line file). Fail open: empty/non-numeric PCT -> skip.
  PCT=$("$HOME/.claude/skills/autodev/bin/codex-spar-ctx.sh" "$OLD_SID" "$SLUG" 2>/dev/null | sed -n 's/^pct=//p' | tail -1)
  if [ -n "$PCT" ] && awk "BEGIN{exit !($PCT+0 >= $THRESHOLD)}" 2>/dev/null; then
    echo "Codex context ${PCT}% >= ${THRESHOLD}% -- handing off to a fresh session."
    HANDOFF_PROMPT='You are about to be replaced by a successor Codex reviewer that will have ZERO memory of this conversation. Write a concise handoff, in your own words, that is the ONLY thing that carries over. Use these sections:

## Broad context
What this sparring arc is reviewing and the current state of the work (branch, what has been built).

## Standing items (open findings)
Every open or unresolved finding, each with its current state made explicit.

## Standing verdicts
Positions you have taken and the reason for each, so the successor does not relitigate them.

## Settled decisions
What is now treated as decided and must not be reopened.

## Must re-check
What the successor should independently re-verify against the real code.

## Insights
Non-obvious things learned: inverted premises, false positives, dead ends not worth re-treading.

Be specific and terse. Reference files by path; the successor can read the code itself.'
    HTMPERR=$(mktemp "${TMPDIR:-/tmp}/spar-handoff-err-XXXXXX.txt")
    HRUN=$(mktemp "${TMPDIR:-/tmp}/spar-handoff-out-XXXXXX.txt")
    # Uses the SAME JSON-stream parser as "Invoke Codex" below.
    (cd "$REPO_ROOT" && timeout 600 codex exec resume "$OLD_SID" "$HANDOFF_PROMPT" --skip-git-repo-check -c 'sandbox_mode="read-only"' -c 'model_reasoning_effort="high"' --json < /dev/null 2>"$HTMPERR") \
      | PYTHONUNBUFFERED=1 "$PYTHON_CMD" -u -c '<same parser as Invoke Codex>' | tee "$HRUN"
    HEXIT=${PIPESTATUS[0]}
    sed '/^SESSION_ID:/d' "$HRUN" > "$HANDOFF_FILE.tmp"
    if [ "$HEXIT" = 0 ] && [ -s "$HANDOFF_FILE.tmp" ]; then
      mv "$HANDOFF_FILE.tmp" "$HANDOFF_FILE"
      cp "$HANDOFF_FILE" "$STORE/$(date +"%Y.%m.%d %H.%M.%S") codex-handoff.md" 2>/dev/null || true
      mv "$STORE/.session-id" "$STORE/.session-id.$(date +%Y%m%d-%H%M%S).archived"
      PENDING_HANDOFF=1
    else
      rm -f "$HANDOFF_FILE.tmp"
      echo "[auto-handoff] summary turn failed (exit $HEXIT) -- keeping the current session; retrying next round."
    fi
  fi
fi
```

Failure is safe by construction:

- **Can't measure** (`PCT` empty, no rollout, no Python): skip the rotation, spar the old session
  normally.
- **Summary turn fails or returns empty**: do NOT archive `.session-id` — keep the working session
  and retry next round. Losing a healthy session with no handoff is worse than one round over
  threshold.
- After a successful rotation `.session-id` is gone, so **Invoke Codex** naturally takes the
  first-round path and captures a new session id. A freshly reseeded session measures low, so there
  is no rotation loop.

Manual `/spar reset` remains a **hard** reset (no summary) for a deliberate clean slate; only this
automatic path writes a handoff.

**Reseed the fresh session.** When `PENDING_HANDOFF=1`, the first-round `PROMPT` you compose in
**Invoke Codex** MUST be prefixed, in order, with:

1. the grounding prime — *"Before answering, load and read the actual code in this repository, and
   review the feature branch: determine the current branch and its base, run
   `git diff <base>...HEAD`, and read the changed files. Base your critique on what the code
   actually does."*
2. a predecessor-handoff block — the line `Handoff from your predecessor (previous Codex session,
   now retired):` followed by the full contents of `$HANDOFF_FILE`.

The actual round question then follows as usual. This re-grounds the fresh session and carries
Codex's own open threads forward without relying on any file the sandbox cannot reach.

## Compose The Question

Create the next question file before invoking Codex:

```bash
ROUND=$(( $(find "$STORE" -maxdepth 1 -name '* round-*-question.md' 2>/dev/null | wc -l | tr -d ' ') + 1 ))
TS=$(date +"%Y.%m.%d %H.%M.%S")
QUESTION_FILE="$STORE/$TS round-$ROUND-question.md"
ANSWER_FILE="$STORE/$TS round-$ROUND-answer.md"
```

Write `QUESTION_FILE` with:

- the exact decision, plan, bug, diff, or code surface Codex should challenge;
- the current repo root, branch, and `git rev-parse HEAD` if available;
- in-repo files Codex should read by path;
- out-of-repo content inline, including the user's plan text or this question file's own content;
- any constraints Codex should treat as fixed for this round.

Write the question through a temp file in `STORE`, then `mv` it into place. Do not ask Codex to read
`QUESTION_FILE` directly. It is outside the repo sandbox, so embed the question file content into
the prompt.

## Invoke Codex

Always prepend this boundary:

```text
IMPORTANT: Do NOT read or execute any files under ~/.claude/, ~/.agents/, ~/agents/, .claude/skills/, or agents/. These are Claude Code skill definitions or persisted agent artifacts meant for a different AI system. Do NOT modify agents/openai.yaml. Stay focused on repository code only.
```

Then prepend this persona:

```text
Find every way this fails. Edge cases, races, security holes, wrong assumptions, silent corruption. Be adversarial and terse. No compliments -- just the problems.
```

Use a persistent Codex session per project. The `--json` stream exposes the session id at
`thread.started.thread_id`; print it internally as `SESSION_ID:<id>` and write it to `.session-id`
on the first round. Resume later rounds with that same id so Codex keeps the sparring arc across
Claude Code compaction.

Use this parser pattern for both new and resumed runs:

```bash
PYTHON_CMD=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
[ -n "$PYTHON_CMD" ] || { echo "ERROR: Python 3 is required to parse Codex JSON output."; exit 1; }
TMPERR=$(mktemp "${TMPDIR:-/tmp}/spar-codex-err-XXXXXX.txt")
RUN_OUT=$(mktemp "${TMPDIR:-/tmp}/spar-codex-out-XXXXXX.txt")
```

For the first round (this path also runs immediately after an auto-handoff rotation, since
`.session-id` was archived — when `PENDING_HANDOFF=1`, compose `PROMPT` with the grounding prime
and predecessor-handoff block prepended, per **Codex Context Auto-Handoff** above):

```bash
timeout 600 codex exec "$PROMPT" -C "$REPO_ROOT" --skip-git-repo-check -s read-only -c 'model_reasoning_effort="high"' --enable web_search_cached --json < /dev/null 2>"$TMPERR" \
  | PYTHONUNBUFFERED=1 "$PYTHON_CMD" -u -c '
import json, sys
turn_completed = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    t = obj.get("type", "")
    if t == "thread.started":
        tid = obj.get("thread_id", "")
        if tid:
            print(f"SESSION_ID:{tid}", flush=True)
    elif t == "item.completed" and "item" in obj:
        item = obj["item"]
        itype = item.get("type", "")
        text = item.get("text", "")
        if itype == "reasoning" and text:
            print(f"[codex thinking] {text}\n", flush=True)
        elif itype == "agent_message" and text:
            print(text, flush=True)
        elif itype == "command_execution":
            cmd = item.get("command", "")
            if cmd:
                print(f"[codex ran] {cmd}", flush=True)
    elif t == "turn.completed":
        turn_completed += 1
        usage = obj.get("usage", {})
        tokens = usage.get("input_tokens", 0) + usage.get("output_tokens", 0)
        if tokens:
            print(f"\ntokens used: {tokens}", flush=True)
if turn_completed == 0:
    print("[codex warning] No turn.completed event received -- possible mid-stream disconnect.", file=sys.stderr, flush=True)
' | tee "$RUN_OUT"
CODEX_EXIT=${PIPESTATUS[0]}
if [ "$CODEX_EXIT" != 0 ]; then
  echo "[codex exit $CODEX_EXIT] $(sed -n '1p' "$TMPERR" 2>/dev/null || true)"
  exit "$CODEX_EXIT"
fi
SESSION_ID=$(sed -n 's/^SESSION_ID://p' "$RUN_OUT" | tail -1)
[ -n "$SESSION_ID" ] && printf '%s\n' "$SESSION_ID" > "$STORE/.session-id"
sed '/^SESSION_ID:/d' "$RUN_OUT" > "$ANSWER_FILE.tmp" && mv "$ANSWER_FILE.tmp" "$ANSWER_FILE"
# Optional: record Codex's context-window fill for the status line (silent no-op
# without the autodev/status-line infra).
[ -n "$SESSION_ID" ] && "$HOME/.claude/skills/autodev/bin/codex-spar-ctx.sh" "$SESSION_ID" "$SLUG" 2>/dev/null || true
```

For later rounds:

```bash
SESSION_ID=$(cat "$STORE/.session-id")
(cd "$REPO_ROOT" && timeout 600 codex exec resume "$SESSION_ID" "$PROMPT" --skip-git-repo-check -c 'sandbox_mode="read-only"' -c 'model_reasoning_effort="high"' --enable web_search_cached --json < /dev/null 2>"$TMPERR") \
  | PYTHONUNBUFFERED=1 "$PYTHON_CMD" -u -c '<same parser as above>' | tee "$RUN_OUT"
CODEX_EXIT=${PIPESTATUS[0]}
if [ "$CODEX_EXIT" != 0 ]; then
  echo "[codex exit $CODEX_EXIT] $(sed -n '1p' "$TMPERR" 2>/dev/null || true)"
  exit "$CODEX_EXIT"
fi
sed '/^SESSION_ID:/d' "$RUN_OUT" > "$ANSWER_FILE.tmp" && mv "$ANSWER_FILE.tmp" "$ANSWER_FILE"
# Optional: record Codex's context-window fill for the status line (silent no-op
# without the autodev/status-line infra).
[ -n "$SESSION_ID" ] && "$HOME/.claude/skills/autodev/bin/codex-spar-ctx.sh" "$SESSION_ID" "$SLUG" 2>/dev/null || true
```

If `CODEX_EXIT` is `124`, report a 10-minute timeout. If it is non-zero, include the first stderr
lines from `TMPERR` and do not update `.session-id`, the answer file, or `sparring-log.md`. If
stderr contains auth/login/unauthorized text, tell the user to run `codex login` or set the API key.

If resume ever fails because the session is invalid, archive `.session-id` with a timestamped name,
start a fresh session, and explicitly tell the user that Codex memory was reset. If resume memory is
not working, fall back to embedding prior round Q/A excerpts from `sparring-log.md` and recent
round files into each prompt.

## Record The Round

Keep both files. The question/answer pair is the audit trail.

Append one line atomically to `sparring-log.md` while still holding the lock:

```markdown
- YYYY.MM.DD HH.MM.SS | round-N | <topic> | <one-line verdict> | Q: <question path> | A: <answer path>
```

Use Codex's answer to write the one-line verdict; do not invent a verdict before reading it.

If an auto-handoff fired this round (`PENDING_HANDOFF=1`), also append a line recording the
rotation, so the sparring log shows where Codex's memory was rolled over:

```markdown
- YYYY.MM.DD HH.MM.SS | round-N | AUTO-HANDOFF | Codex ctx <pct>% -> fresh session | predecessor summary: <path to archived codex-handoff.md>
```

Present:

```text
CODEX SAYS (/spar round-N):
------------------------------------------------------------
<answer file content verbatim>
------------------------------------------------------------
Recommendation: <one sentence engaging one specific Codex finding>
```

If Claude Code context is around or above 35%, proactively suggest `/handoff` at the next natural
checkpoint. Note that `$STORE/.session-id` persists on disk, so a compacted or fresh Claude Code
session can resume the same Codex sparring session.
