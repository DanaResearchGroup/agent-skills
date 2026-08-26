---
name: obsidian-vault
description: Search, create, and manage notes in the Obsidian vault with wikilinks and index notes. Use when user wants to find, create, or organize notes in Obsidian.
---

# Obsidian Vault

## Vault location

`~/Dropbox/Apps/remotely-save/Vault/`

(Synced via Dropbox / remotely-save.)

## Structure

Organized into topical **folders** at the root — place a note in the folder that fits its topic:

- `Code/` — dev/infra knowledge, per-project subfolders (`Code/ARC`, `Code/T3`, `Code/Carmel`)
- `knowledge/` — general knowledge (`knowledge/wiki/` for wiki-style runbooks/guides)
- `tools/` — tool cheatsheets & indexes
- `HQ/` — the HQ workspace (read `HQ/CLAUDE.md` before operating on it)
- `Research/`, `Companies/`, `Group/`, `Teaching/`, `Meetings/`, `ViceDean/` — domain notes
- `CLAUDE.md` at the vault root — **the authority for naming, dates and language (§ A5). Read it
  before naming any file, in the vault or elsewhere in Dropbox.** Also `learnings.md` and a few
  other loose notes.

When unsure where a note goes, search for sibling notes on the same topic and match their folder.

## Naming conventions

**Two different conventions live in the same Dropbox tree. Check which one applies before naming
anything.**

| Where | Convention |
|---|---|
| **Inside the Vault** (`~/Dropbox/Apps/remotely-save/Vault/`) | **Title Case**, no date — `Tools Index.md`. A few legacy index notes are lowercase (`knowledge/wiki/index.md`). |
| **Elsewhere in Dropbox** (`~/Dropbox/remote-work/`, and any other non-Vault Dropbox folder) | **`YYYY.MM.DD <a\|b\|c> <Name>.<ext>`** — e.g. `2026.08.26 a ERC B1 Science Skeleton.md`. The letter is a **same-day revision counter**, so the newest date+letter is the live version. A second revision the same day is `b`, not a new date. |

Authority: `Vault/CLAUDE.md` § A5 *"Naming, dates and language"*, which also fixes date formats
(`DD/MM/YYYY` in HQ, ISO `YYYY-MM-DD` in `knowledge/`), English for all structure (filenames,
frontmatter, headings — bodies follow the source language), and **preserving upstream spelling in
pointers including mistakes** (the Dropbox folder really is `02.1_Catalouge`).

⚠️ **The failure mode is real.** The Vault has *zero* files named with the dated pattern and
`remote-work/` has many, so matching whichever sibling file you happen to see first gets it wrong
half the time. Match the *location*, not the nearest filename — and when a folder's existing files
disagree with the rule, the rule wins.

- **Index notes** aggregate related topics (e.g. `Tools Index.md`, `knowledge/wiki/index.md`) — just lists of `[[wikilinks]]`

## Linking

- Use Obsidian `[[wikilinks]]` syntax: `[[Note Title]]`
- Link related/dependency notes at the bottom of each note
- Update or add to the relevant index note when creating a new note

## Workflows

### Search for notes

```bash
VAULT="$HOME/Dropbox/Apps/remotely-save/Vault"
# By filename
find "$VAULT" -name "*.md" | grep -i "keyword"
# By content
grep -rl "keyword" "$VAULT" --include="*.md"
```

Or use Grep/Glob tools directly on the vault path.

### Create a new note

1. Pick the right **folder** (match sibling notes on the topic)
2. Use **Title Case** for the filename — this is a Vault note. For a file landing *outside* the
   Vault in Dropbox, use `YYYY.MM.DD <a|b|c> <Name>.<ext>` instead (see Naming conventions)
3. Write content as a self-contained unit of learning
4. Add `[[wikilinks]]` to related notes at the bottom; add it to the relevant index note

### Find related notes (backlinks)

```bash
grep -rl "\\[\\[Note Title\\]\\]" "$HOME/Dropbox/Apps/remotely-save/Vault"
```

### Find index notes

```bash
find "$HOME/Dropbox/Apps/remotely-save/Vault" -iname "*Index*"
```
