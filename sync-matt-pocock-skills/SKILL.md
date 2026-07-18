---
name: sync-matt-pocock-skills
description: Update the vendored Matt Pocock skills to a newer mattpocock/skills release, keeping our local modifications. Run periodically when upstream cuts a release.
disable-model-invocation: true
---

# sync-matt-pocock-skills

Reconcile the [`mattpocock/skills`](https://github.com/mattpocock/skills) copies vendored in this
repo with a newer upstream release **without losing our local modifications**. The whole skill is
one move done per skill: treat upstream's new version as the base and re-apply our edits on top — a
**stash** and pop.

`THIRD_PARTY_NOTICES.md` lists which skills are vendored — that list is the source of truth for what
this skill governs. Work in a git worktree, never the shared checkout.

## 1. Read the changelog first

Never diff blind — learn upstream's intent before touching a file:

```bash
gh release list --repo mattpocock/skills
gh release view <tag> --repo mattpocock/skills      # or read its CHANGELOG.md
```

Sort every change into four kinds: **renames** (`to-prd`→`to-spec`), **deletions** (`to-issues`
merged into `to-tickets`), **new skills**, and **per-skill edits**. Flag any new **cross-skill
dependency** — a skill that now calls a `/skill` we don't vendor yet (v1.1.0 pointed several skills
at the new `/grilling` primitive).

**Done when:** you have the target tag and a written change-list under those four headings.

## 2. Materialize the target version

Clone upstream and check out the target tag. Upstream nests skills under
`skills/{engineering,productivity,personal}/`; ours are flat top-level dirs — flatten by basename so
each `<name>/` lines up to diff against:

```bash
git clone https://github.com/mattpocock/skills <tmp> && git -C <tmp> checkout <tag>
```

**Done when:** a flat tree of the target's skills exists beside ours.

## 3. Classify each vendored skill

Our local modifications are our own commits after the vendor commit — read them, don't guess:

```bash
git log --oneline -- <skill>/     # commits titled only "vendor"/"sync" mean NO local edits
diff -r <skill>/ <target>/<skill>/
```

Put every vendored skill in one bucket:

- **Identical** — no diff. Skip.
- **Drift only** — differs, but every commit is a vendor/sync. **Overwrite** with the target.
- **Local superset / already newer** — a deep local adaptation, or vendored from a *later* commit
  than the target. **Keep ours** — overwriting would regress it.
- **Both changed** — upstream edited it *and* we hold local commits. **3-way merge**: take the target
  as the new base, re-apply only our local intent. Our edit may need to move — if upstream split a
  skill, the modification belongs in whichever new file now owns that behaviour.

**Done when:** every skill in the notices file has a bucket and a one-line reason.

## 4. Apply renames, deletions, and additions

`git rm` the deleted and renamed-away skills. Copy in the replacements, plus any new skill a
cross-dependency needs — a `/skill` reference dangles if its target isn't vendored.

**Done when:** `git status` matches the change-list from step 1.

## 5. Chase dangling references

```bash
git grep -nE '<deleted-skill-names>'    # empty outside THIRD_PARTY_NOTICES
```

Then confirm every `/skill` cross-reference in the changed files resolves to a skill that now exists.

**Done when:** no reference points at a skill that no longer exists.

## 6. Update the docs

- `THIRD_PARTY_NOTICES.md` — the vendored-skill list.
- `README.md` — the skills-count badge and the Matt Pocock attribution row.
- `ADAPTATION.md` — only if the update introduced a new machine- or group-specific assumption.

**Done when:** the docs name exactly the skills that now exist.

## 7. Verify and ship

```bash
python3 bin/lint-skills.py     # must pass
```

Spot-check that overwritten skills byte-match the target and merged skills still carry our local
intent. Then commit and open a PR per the repo's git rules. Once the PR is open, fold any
bot/reviewer findings back into the commit that introduced them before merge (see `/copilot-review`)
— a **3-way merge** most often drops an edit where a local modification met an upstream one.

**Done when:** lint is green and the work is on a branch with a PR.
