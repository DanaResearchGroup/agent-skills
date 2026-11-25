---
name: factory-machine
description: Ask which machine this is (HL, LMF or OL) and what it may do — open a browser, reach the vault, Slack or herdr — and where an artifact for the owner goes, from the owner's machine.env and planes files. Use whenever a skill would otherwise test the host name, open a browser, write a file the owner must see, or map a path between a peer and HL.
---

Skills run on three machines. **HL** has a display and is the hub; **LMF** and **OL** are peers
with no display. A skill never guesses which one it is on, and never reads the host name. It asks
`factory-machine`, which reads two files the owner's install writes and answers from them alone.

```bash
FM=~/.claude/skills/factory-machine/bin/factory-machine
"$FM" may-open-browser && xdg-open "$page"
```

## Rules for a calling skill

- **Exit 2 means stop.** The helper prints one line naming the file and the fault (a missing
  file, a malformed line, an unknown `MACHINE`, a peer without `HL_EXCHANGE_ROOT`, an unknown key,
  a refused plane). Stop and show that line. Do not fall back to the host name or a default.
- **Exit 1 means no** for `may-open-browser` and `has`; exit 0 means yes.
- The helper reads only. It creates no folder, copies nothing, and touches no network.

## Subcommands

| Command | Answer |
| --- | --- |
| `get KEY` | the value; a key outside the contract, or one not set here, is exit 2 |
| `show` | every value, `KEY=value`, one per line |
| `may-open-browser` | 0 only when `MACHINE=HL` and `HAS_DISPLAY=1` |
| `artifact-dir PLANE [KIND]` | where a file for the owner goes (below) |
| `hl-path PATH` | peer only: a path under `EXCHANGE_ROOT`, as HL sees the same file |
| `exchange-dir PEER` | HL only: `$EXCHANGE_ROOT/PEER`; `PEER` must be in `PEERS` |
| `has vault\|slack\|herdr\|display` | 0 when the flag is 1 |
| `planes [--zone any\|hl-only]` | plane slugs from the planes file |
| `plane SLUG` | the slug's row; a slug not in the file is refused (deny by default) |

`artifact-dir` refuses a plane the planes file does not list. On HL it prints the show-me folder,
`${SHOW_ME_DIR:-~/Dropbox/remote-work/show-me}`, whatever the kind. On a peer it prints
`$EXCHANGE_ROOT/to-hl/artifacts/PLANE/KIND` (`KIND` defaults to `show-me`), and refuses a plane
whose zone is `hl-only`, because that plane's files never leave HL.

## The files

`~/.config/factory/machine.env` (override: `FACTORY_MACHINE_ENV`). Shell `KEY=value` lines, one
per line; `#` comments, `export`, quotes, a leading `~` and `$HOME` are read as a shell would
read them. Anything else a shell would expand or run is refused. The owner writes it once per
machine; no skill writes it.

```text
MACHINE=HL|LMF|OL
HAS_DISPLAY=1|0
EXCHANGE_ROOT=<path>      # HL: ~/exchange (one folder per peer below it); peer: ~/exchange/hl
PEERS="<peers>"           # HL: "LMF OL"; a peer: HL
HL_EXCHANGE_ROOT=<path>   # peers only: the same tree on HL (~/exchange/<this peer>)
HAS_VAULT=1|0             # optional, like HAS_SLACK and HAS_HERDR; missing means 0
```

`~/.config/factory/planes` (override: `FACTORY_PLANES`). The plane registry: one row per plane,
columns `slug repo owning_persona zone`, with `zone` either `any` or `hl-only`. The owner's
install is its one writer.

## The lint

`bin/lint-host-name` at the repository root refuses any tracked file that reads the host name
(`hostname`, `uname -n`, `$HOSTNAME`, `socket.gethostname`, `platform.node`, `/etc/hostname`).
A use that only records the host, such as a message's sender, goes in
`bin/lint-host-name.allow` with a one-line reason. Known uses that branch on the host and are not
fixed yet are in `bin/lint-host-name.baseline`.
