# Installing the contract gate

The skill is inert until its two hooks are wired into `settings.json` and at
least one repo is enabled.

## 1. Wire the hooks

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write|NotebookEdit",
        "hooks": [{"type": "command", "command": "~/.claude/skills/contract/hooks/contract-gate.sh"}]
      }
    ],
    "SessionStart": [
      {
        "hooks": [{"type": "command", "command": "~/.claude/skills/contract/hooks/contract-inject.sh"}]
      }
    ]
  }
}
```

Both hooks fail open: with no enabled repo they exit 0 and change nothing, so
wiring them is safe before any repo opts in.

## 2. Enable a repo

```bash
cd ~/Code/ARC && ~/.claude/skills/contract/bin/contract enable
```

Enabling is keyed on the shared git dir, so this covers every worktree of the
repo at once (`ARC`, `ARC-adaptive`, `ARC-conformers`, `ARC-wt2` …).

## 3. Roll out on evidence

Start with two or three repos. The skip log is the instrument:

```bash
cat "$(git rev-parse --git-common-dir)/contract-skips.log"
```

A repo where skips dominate is a repo where the gate is noise — run
`contract disable` there. Expand only where the log shows the gate catching
real definition gaps.

## Limits

This is an audit trail, not a containment boundary. `Bash` is deliberately
left ungated, so a determined agent can still write files through a shell
regardless of gate state. The gate is a speed bump against inattention, not
containment: it buys a moment of forced definition before an `Edit`, `Write`,
or `NotebookEdit` call, nothing more. It cannot buy attention, and it cannot
stop a worker — deliberate or careless — that routes around it through `Bash`.
