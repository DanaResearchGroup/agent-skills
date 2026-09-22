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

## Where the state lives

Notes, the `ACTIVE` marker, skips and the logs live under
`~/agents/state/contracts/<repo-key>/`, keyed on the path of the git common dir
and of the worktree. `contract status` prints `state=` and `notes=` for the
worktree you are in — always check those two lines rather than assuming a
location. `CONTRACT_STATE_DIR` overrides the root and must be absolute; the test
suite sets it so a run stays out of the real state dir.

That is not a tidiness choice: Claude Code denies `Bash` writes anywhere inside
a skills/hooks tree, so with state in the repo, the skills repo itself could
neither open a contract nor take a skip while the gate stayed armed — only a
shell outside the sandbox could break the deadlock.

`enable` still prefers a marker inside the git dir (`.git/contract-enabled`), so
a renamed or moved checkout stays gated; it falls back to the state dir only
where that write is refused. A pre-move skip marker in `.git/contract-skips/` is
still honoured too.

Two things a path key cannot do, both visible in `status`:

- **A path is the identity, so moving one loses state and reusing one inherits
  it.** After `git worktree move` or a relocated checkout, the active note does
  not follow: the worktree reads as having no contract (gate armed, `new`
  works). A *new* repo cloned at a path some earlier repo used inherits
  everything that was keyed to that path — skips, logs, the external enable
  marker, and an `ACTIVE` with its note, which means an old contract can open
  the new repo's gate. `contract status` prints `state=`; that directory is the
  thing to delete when a path is recycled.
- **Two roots are two realities.** The CLI and the hook each read
  `CONTRACT_STATE_DIR` from their own environment. Exporting it in a shell but
  not in the harness gives you a contract the gate cannot see. Set it in
  `settings.json` `env`, or not at all. It must be absolute and outside the
  worktree; anything else is refused.

Enablement survives a move only where the marker could go in the git dir. In a
repo that denies writes there — the skills repo — it is path-keyed like
everything else, so a moved checkout comes back un-enabled.

### A contract left in the old in-repo home

`docs/contracts/` (and the older `docs/superpowers/contracts/`) is still honoured
while it holds a live contract — an `ACTIVE` whose note exists. Where the repo is
writable, that contract closes in place and nothing else is needed. Where it is
not — the skills repo — `close` cannot archive it, so adopt it first:

```bash
contract migrate
```

That copies the note into the state dir, pins the worktree there permanently (a
`.external` marker, which `new` writes too), and removes the in-repo copies if it
can — reporting when it cannot. After that, `close` and `abandon` work from a
sandboxed session, and any leftover file under `docs/contracts/` is ignored
rather than able to re-arm the gate. `migrate` refuses rather than guessing when
both in-repo homes hold live contracts, or when state already holds an active
contract of its own.

## 3. Put `contract` on your PATH

The hooks call the CLI by absolute path and the gate's denial message names
that absolute path, so nothing breaks without this step. But for typing
`contract new <slug>` by hand, link it somewhere on your PATH:

```bash
ln -s ~/.claude/skills/contract/bin/contract ~/.local/bin/contract
```

## 4. Roll out on evidence

Start with two or three repos. The skip log is the instrument:

```bash
cat "$(contract status | sed -n 's/^state=//p')/skips.log"
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
