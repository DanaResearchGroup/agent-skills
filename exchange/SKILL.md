---
name: exchange
description: Write and check the exchange tree that moves files between HL (the hub) and a peer machine — a fixed folder tree with nine rules, a generator (`exchange-init`) and a checker (`exchange-lint`). Use when setting up an exchange folder for a peer, when an agent must put a file into or read a file from an exchange folder, or when an exchange tree needs a check before or after a transfer.
---

# Exchange

Files move between HL, the hub, and each peer machine through one exchange folder per peer. On
HL it is `~/exchange/<peer>/`; on the peer it is `~/exchange/hl/`. The tree is the same on both
ends. Its `AGENTS.md`, written from [`templates/AGENTS.md.tmpl`](templates/AGENTS.md.tmpl), states
the tree and the nine rules for an agent that lands there. Read that template for the rules.

This skill has no transport. Nothing here copies, syncs or schedules.

## Write a tree

```bash
~/.claude/skills/exchange/bin/exchange-init ~/exchange/lmf --side hl --peer lmf
~/.claude/skills/exchange/bin/exchange-init ~/exchange/hl --side peer --peer lmf   # on LMF
```

It writes the folders for every plane whose zone is `any` in the planes file
(`~/.config/factory/planes`, rows `slug repo owning_persona zone`; `--planes FILE` overrides),
and a read-only `AGENTS.md` for this side. It is safe to re-run: a new plane gets its folders.
Exit 0 written, 2 could not run.

## Check a tree

```bash
~/.claude/skills/exchange/bin/exchange-lint ~/exchange/lmf --side hl --peer lmf --terms FILE
```

| Exit | Meaning |
|---|---|
| 0 | clean |
| 1 | defects, one line each: `rule N: <path in the tree>: <what is wrong>` |
| 2 | could not run: bad arguments, a missing or bad planes or terms file, a bad stamp |

- `--terms FILE` is required. One term per line, matched as a whole word in any case; a line
  `re:<regex>` is a regex. `#` starts a comment. The lint refuses to run without terms, so the
  term check never passes silently. It never prints a term: a path that holds a term or a secret
  value prints with that part as `[withheld]`.
- `--max-item-bytes N` sets the rule 6 limit (default 1 GB, 10^9 bytes). A data item counts as
  the sum of its files.
- `--side` picks which direction is inbound: `to-hl/` on HL, `to-<peer>/` on the peer.

## The transfer stamp

Rule 2 needs the time of the last inbound transfer. The tree keeps it in `.last-transfer` at its
top: one ISO 8601 time with a zone, for example `2026-11-25T14:00:00Z`. The transport, when it
exists, writes it on the receiving side after each transfer and never carries it across. Until
then no file has arrived, so every file in the inbound folder is a rule 2 defect. `AGENTS.md` is
local to each side too: it names the side, so the lint compares it with this side's text.

## What the lint does not check

- Inside `archive/` it checks only rules 1 (month folders), 7 and links; a tool moves things there.
- Files inside a data item have free names; the item folder and its manifest carry the rules.
- Rule 2 compares file times only; a new empty folder is not a defect.
- Rule 7 reads text files only (no NUL byte in the first 8 KB), so UTF-16 text is not scanned.
- Rule 8's shape test reads the first 8 KB: front matter with a `description:`, an opening like
  "You are a/the …" or "Your task", or the phrase "paste below this line".
