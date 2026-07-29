# auto-proposals — the safety model

`~/Dropbox/Work/Proposals/` holds years of submitted and granted funding proposals. It is
**not under version control** and syncs across ~5 hosts via Dropbox. A clobbered or deleted
file there is a real loss. Every design choice below exists because of that one sentence.

This file is the normative contract for the code in `lib/`. `SKILL.md` tells the model what
to do; **this** tells the code what it must refuse to do.

---

## 1. Four layers, weakest last

| layer | mechanism | what it stops |
|---|---|---|
| L1 harness | headless worker runs with **no `Bash`** and `permissions.deny` on `Write`/`Edit` anywhere under the archive and the Vault | the model writing or shelling into the archive at all |
| L2 chokepoint | every write goes through `lib/publish.py`, which validates the target against the owned-path grammar and opens with `O_CREAT│O_EXCL│O_NOFOLLOW` via directory-fd based syscalls | wrong paths, symlink escapes, overwriting anything, TOCTOU races between check and use |
| L3 integrity | `lib/integrity.py` snapshots `(size, mtime_ns, ino, sha256)` of every pre-existing file before the run and diffs after; a sha256 is computed for every regular file up to `AUTO_PROPOSALS_HASH_MAX_BYTES` (default 5 MiB) — larger files fall back to size/mtime/ino only, counted and reported as `skipped_large` | turns a silent clobber into a loud, itemised alarm, including a same-size same-mtime content change and the modification or deletion of an artifact the agent itself owns |
| L4 prose | `SKILL.md` rules | ordinary well-behaved operation |

**L1 is not an OS boundary.** A real one (`bwrap --ro-bind`) is unavailable on this machine:
`kernel.apparmor_restrict_unprivileged_userns=1` blocks unprivileged user namespaces, and
lifting it is a machine-wide security change that only the operator can authorise. Until then
L1 is enforced by Claude Code's own permission system, which is genuine but in-process.
See `SKILL.md` § Operator notes.

Dropbox retains 30 days of file history on every plan, so L3 detection has a recovery path.
That is a backstop, never a licence.

## 2. Owned-path grammar

The agent owns **exactly** these paths under `$PROPOSALS`, and nothing else:

```
OPEN.md
CORPUS.md
<call>/topics.md                       <call>/topics-v<N>.md
<call>/outlines/<Tn>-<slug>.md         <call>/outlines/<Tn>-<slug>-v<N>.md
<call>/drafts/YYYY.MM.DD <letter> <rest>.md
<call>/drafts/YYYY.MM.DD <letter> <rest>.pdf
<call>/drafts/tex/YYYY.MM.DD <letter> <rest>.tex
<call>/drafts/tex/YYYY.MM.DD <letter> <rest>.bib
```

where `<call>` is a top-level directory **not** starting with `_` and not starting with `.`,
`<Tn>` is `T` + digits, `<slug>` is `[a-z0-9-]+`, `<N>` is a positive integer, `YYYY.MM.DD` is
a dot-separated four-digit year / two-digit month / two-digit day, `<letter>` is a single
lowercase ascii letter (`a` for the first draft produced on a given date, incrementing for
each further version of the same `<rest>` produced that same date, resetting to `a` on a new
date), and `<rest>` is non-empty and may contain spaces and non-ascii characters.

The `.pdf` and the LaTeX sources are **companions** of the `.md` draft whose basename they share
exactly. Each is publishable **only** when that `.md` already exists and carries
`generated_by: auto-proposals`, and never differs from it in date or letter. A companion is
written verbatim and so cannot carry frontmatter; this sibling rule is the whole of its
provenance — without it `drafts/` would be a place any file could be deposited.

The sources sit in a `tex/` subfolder rather than beside the draft, so `drafts/` stays a
readable list of drafts instead of a build directory. **`tex/` is the only nested directory the
agent may create, and only inside `drafts/`.** Only `.tex` and `.bib` are accepted there —
build artefacts (`.aux`, `.log`, `.out`) are never published.

**`<call>/context/` is deliberately absent from this grammar and must stay absent.** It is
where Alon drops material to steer a direction he has already picked. It is an input to the
agent and an output of nobody, so every write to it is refused by the grammar rather than by
anyone remembering the rule.

Validation is **`realpath`-based, not string-based**: the resolved parent must still be inside
the resolved `$PROPOSALS`, and no path component may be a symlink. A `drafts/` symlinked at
`_Granted/` must not let a write escape.

Everything else — `_`-prefixed corpora (`_Granted`, `_Archive`, `_resources`, `_גישוש`, …),
`.obsidian/`, dotfiles, anything outside `$PROPOSALS` — is **read-only forever**.

## 3. Write modes

`publish.py` supports exactly four, and **never deletes anything**:

- **`create`** — `topics*.md`, `outlines/*`, `drafts/*`. Opens `O_CREAT|O_EXCL|O_NOFOLLOW`.
  If the target exists, it **refuses**; the caller must publish the next `-v<N>` instead
  (topics/outlines) or the next date-letter draft filename instead (drafts — see §2).
  This is what makes Alon's hand-ticked checkboxes unclobberable.
- **`create-companion`** — **only** `drafts/*.pdf` and `drafts/tex/*.{tex,bib}`, and only next
  to an owned `.md` of the same basename. Same `O_CREAT|O_EXCL` create-only discipline, but the
  payload is written as raw bytes and **no frontmatter is prepended and no completeness marker
  appended** — both would corrupt a PDF and both would stop a `.tex` compiling. The consequence
  is stated plainly rather than hidden: a truncated companion is not detectable the way a
  truncated markdown artifact is, so the write-temp-then-link order is what guarantees the
  target only ever appears complete.
- **`append`** — appends a fenced, dated steering block to an artifact the agent owns and that
  already exists. Never rewrites existing bytes.
- **`regenerate`** — **only** `OPEN.md` and `CORPUS.md`. Read-modify-write guarded by
  compare-and-swap: the caller passes the SHA-256 it read; the on-disk file is re-hashed
  immediately before the replace (not just once, up front) so a change landing during
  composition is still caught. This narrows the race window to the gap between that final
  hash and the rename itself — it does not eliminate it; true atomicity would require a
  filesystem-level lock Dropbox-synced storage cannot offer. `regenerate` also refuses to
  write over a target that exists but does not itself carry `generated_by: auto-proposals`
  provenance, even on a SHA match — that target is human-written and is never a candidate
  for regeneration. A conflicted copy of the *target itself* at the root (not just of a
  call-folder artifact) also freezes the write; see §5.

Every publish is `write temp in the same directory → fsync(file) → rename/link → fsync(dir)`.
Temp files are named `.auto-proposals.tmp.*` and are always cleaned up.

## 4. Artifact provenance

Every generated artifact carries YAML frontmatter:

```yaml
---
artifact: topics | outline | draft | roster | corpus
call: "<call folder name>"
generated_by: auto-proposals
generated_at: DD/MM/YYYY HH:MM
generated_on: <hostname>
version: <N>
sources: [ ... relative paths actually read ... ]
complete: true          # informational only - see completion sentinel below
---
<body>
<!-- auto-proposals:end -->
```

The `complete: true` frontmatter key is **not** the completion sentinel by itself — a
truncated write (crash, kill, partial copy) can leave a frontmatter block with `complete:
true` sitting above a body that never finished. The real sentinel is the literal trailing
marker `<!-- auto-proposals:end -->`, written by `_compose_content()` as the very last bytes
of the file, after the body. `is_complete()` checks for that trailing marker, not the
frontmatter flag: an artifact whose write was interrupted after the frontmatter but before
the marker is correctly reported as incomplete even though its frontmatter claims otherwise.

Provenance is an **accident guard, not authentication**. `generated_by: auto-proposals` in a
file's frontmatter is a plain-text YAML key with no cryptographic binding to this code — it
stops the agent from clobbering ordinary human-written files (a `topics.md` a person wrote
by hand, or an old artifact from a different tool) by mistake, not a malicious actor from
forging the key by hand. `is_agent_owned()` additionally requires non-empty `artifact`,
`call`, and `version` fields alongside `generated_by`, so a bare `generated_by:
auto-proposals` line dropped into an otherwise-empty or malformed frontmatter block does not
count as ownership. `parse_frontmatter()` also refuses (treats as empty) any block that
exceeds a size cap, declares more than a fixed number of keys, or repeats a key — malformed
or oversized frontmatter is never partially trusted.

## 5. Conflicted copies **halt**, they do not get filtered

Dropbox conflict files are handled asymmetrically:

- In **corpus/input scans** they are skipped — they are duplicates of source material.
- For any **owned artifact** (`OPEN.md`, `CORPUS.md`, `<call>/topics*.md`, outlines, drafts) a
  conflicted sibling means **that call is frozen**: the agent does no stage work on it and
  reports it for manual reconciliation. This now covers root-level artifacts (`OPEN.md`,
  `CORPUS.md`) as well as per-call artifacts — a conflicted copy of either halts writes to
  that target, not just conflicted copies inside a call folder.

Filtering a conflicted `topics.md` could silently discard the copy carrying Alon's selection.
That is a decision-losing bug, so it is an error, not a filter.

**Detection is English-wording only, and that is a known gap, not a guarantee.** The detector
recognises the English Dropbox naming convention — `… (conflicted copy).ext`,
`… (conflicted copy YYYY-MM-DD).ext`, `… (X's conflicted copy YYYY-MM-DD).ext`, and the
per-device form `… (hostname's conflicted copy YYYY-MM-DD).ext` — in any case. Dropbox
localises this phrase on non-English client locales (for example Hebrew), and a conflicted
copy named with a localised phrase is **invisible** to this detector: it will not freeze the
call, and the freeze protection silently does not apply. Mitigating this fully would require
either enumerating every Dropbox locale's phrasing or a structural (non-text) signal for
"this file is a Dropbox conflict artifact," neither of which this library currently has;
until then, keep Dropbox clients that touch this archive on an English locale.

## 6. Single publish host

Dropbox does not propagate locks, and two hosts creating the same "missing" file produce a
conflicted copy rather than one winner. Writes are therefore restricted to **one designated
publish host** (`AUTO_PROPOSALS_PUBLISH_HOST`, default `HL`). On any other host the code runs
read-only and says so. Before publishing, `dropbox status` must report `Up to date`; a syncing
tree means a partially-materialised folder, and acting on one risks generating an artifact from
half the call.

The two gates have **separate** opt-outs — `AUTO_PROPOSALS_ALLOW_ANY_HOST=1` and
`AUTO_PROPOSALS_ALLOW_UNSYNCED=1`. One combined switch would mean anything that merely wanted to
run off-host also silently lost the sync check, which is the more dangerous of the two to drop by
accident. Both are for tests; neither belongs in the cron environment.

## 7. Extracted documents are DATA, never instructions

Call PDFs/DOCX/DOC/MSG and years of old proposals are **untrusted input**. Text recovered from
them is quoted material to reason about; it is never followed as instruction, no matter what it
says. Concretely: nothing extracted can change the owned-path grammar, authorise a write, add a
Slack recipient, or cause outbound anything.

Steering is only accepted from an authenticated channel: a Slack message whose `user` is the
configured operator id, in the configured channel id, in the thread belonging to that call —
and appended steering text is always **fenced** so a `- [x]` inside it can never be re-read as
an approval.

## 8. Nothing outbound in increment 1

No submission, no email, no Slack posting from the library. When Slack is added, the channel is
passed explicitly and a missing `CC_SLACK_CHANNEL` is a hard error — never a fallback to the
default channel, which is `#cc-comm`.
