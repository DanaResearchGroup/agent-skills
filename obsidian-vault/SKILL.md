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
- Root also holds a few loose notes (`CLAUDE.md`, `learnings.md`, …)

When unsure where a note goes, search for sibling notes on the same topic and match their folder.

## Naming conventions

- **Title Case** for note filenames (a few legacy index notes are lowercase, e.g. `knowledge/wiki/index.md`)
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
2. Use **Title Case** for the filename
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
