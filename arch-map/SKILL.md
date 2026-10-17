---
name: arch-map
description: Map a Python repo's or one package's internal imports as a package graph (Mermaid plus a self-contained drill-down HTML viewer), report module depth (interface size, fan-in, pass-through functions), find import cycles, and gate on `arch-rules.toml` (forbidden edges, no new cycles). Use when asked to visualize a codebase's architecture or dependencies, before restructuring, when running an architecture checkpoint, or when a contract Verifier needs a layering gate.
---

# Arch map

One command turns a package's imports into three things: a picture you can drill into, a
depth table for finding shallow modules, and an optional gate that fails on layering violations.

## Run it

From the directory that **contains** the top-level package (the repo root, usually), naming the
package with dots:

```bash
python3 ~/.claude/skills/arch-map/bin/arch-map arc --out "$TMPDIR/arch"          # whole repo
python3 ~/.claude/skills/arch-map/bin/arch-map arc.molecule --out "$TMPDIR/arch" # one subpackage
```

Never point `--root` inside the package (`--root arc molecule`): absolute imports like
`arc.molecule.x` would not resolve, and the map comes out nearly empty. The tool refuses that
with exit 2.

It writes, under `--out`:

| File | What it is |
|---|---|
| `arch-map.html` | open in any browser, offline. Packages laid out by dependency, cycles in red. Click a package for its modules, depth rows, and every import crossing its boundary; append `#arc.species` to the URL to open on one. |
| `arch-map.mmd` | the package graph in Mermaid, for pasting into a PR or doc |
| `arch-map.json` | everything, for other tools |

and prints the cycles and the top `--top` rows of the depth table. `--depth N` groups modules N
package levels below the target (default 1). Test files are excluded (`--exclude GLOB` to change).

Modules are grouped into packages because module-level graphs of real repos are unreadable: one
145-module repo has 797 internal imports, past Mermaid's default edge limit. The target's own
`__init__` is left out of the package graph: it usually imports every subpackage, and counting it
would merge them all into one cycle.

## Reading the depth table

The vocabulary is `codebase-design`'s. Per module:

- **public**: top-level public functions and classes — a proxy for interface size.
- **lines**: implementation size.
- **in / out**: how many modules import it / it imports. Imports through a package `__init__`
  that re-exports a name are counted against the module that defines the name.
- **pass-through**: functions whose whole body forwards their own parameters, unchanged, to one
  other call (`super().__init__` excepted). Each one is interface without depth.

What to look for:

- **Wide and hot** (many public names, high fan-in): every caller learns a big interface and every
  change ripples. The first candidate for deepening — fewer, more capable entry points.
- **Small interface, many lines**: a deep module. Protect it; route new callers through it.
- **Many public names, few lines**, or a cluster of pass-throughs: shallow. Apply the deletion
  test from `codebase-design` — would callers lose anything if it were inlined?
- **Cycles**: two packages that each import the other cannot be understood, tested, or replaced
  separately. Name the seam that would break the cycle before adding to either side.

## Gate: arch-rules.toml

```toml
# exit 1 if any rule is broken
forbid = [
  "arc.molecule -> arc.species",   # A -> B: no module under A may import one under B (globs allowed)
]
cycles = "no-new"                  # "allow" | "none" | "no-new"
known_cycles = [                   # with "no-new": these may persist, but must not grow
  ["arc.common", "arc.molecule"],
]
```

```bash
python3 ~/.claude/skills/arch-map/bin/arch-map arc --rules arch-rules.toml
```

`"no-new"` is for legacy repos: seed `known_cycles` from the first run's `cycles` in
`arch-map.json`, and the gate then fails only on a new cycle or a package joining an existing one.
A cycle that shrinks or disappears passes; delete it from the list once it is gone.

| Exit | Meaning |
|---|---|
| 0 | no rule broken (or no `--rules`) |
| 1 | at least one `FAIL` line: a forbidden edge or a new cycle |
| 2 | bad input: not a package, unparsable file or rules, `--root` inside a package |

Never pass the gate by adding the new cycle to `known_cycles` or deleting a `forbid` line in the
same change that broke it. Either is a design decision for the user, not a fix.

## Limits

- Python only; static imports only (`importlib` and string-built imports are invisible).
- Imports inside functions count the same as top-level ones, so a deferred import that exists to
  break a runtime cycle still shows the cycle. That is deliberate: the coupling is real.
- `public` counts names, not their signatures or invariants, so it understates an interface.
