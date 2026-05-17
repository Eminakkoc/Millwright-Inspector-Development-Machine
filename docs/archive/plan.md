---
status: draft
audience: implementer
related:
  - docs/workflow-spec.md
  - commands/mi-run.md
  - commands/mi-init.md
  - scripts/folder-id.sh
---

# `mi-archive-quest` implementation plan

A quest cycle, once finished, leaves three trees of folders behind: the `quest/<slug>/`
subfolder, the `journal/<topic>/` folders it was built from, and the
`workflow-stream/<feature>/` folders it produced. Today these stay in the live workspace
forever — `quest/` and `workflow-stream/` grow without bound, and the inspector cannot
tell at a glance which folders belong to closed work versus active work.

`mi-archive-quest` retires a finished quest cycle as a unit. Given a quest slug, it reads
that cycle's `reference.md`, gathers the linked journal and workflow-stream folders, and
moves the whole set into a new top-level `archive/` folder — keeping the links intact so
an archived cycle stays as queryable as a live one.

This builds directly on the ID-based folder linking shipped in v1.1.0 (`id.md` markers +
`reference.md` link tables). Without that linking there would be no reliable way to know
which journal and workflow-stream folders belong to a given cycle.

> **Naming.** The feature was originally requested as `mi-archive-feature`, but the unit
> it archives is a whole quest cycle (one quest folder + its journal folders + its feature
> folders), not a single feature. The inspector chose **`mi-archive-quest`**; review also
> floated `mi-archive-cycle` ("quest cycle" is the spec's term for the unit). Either reads
> correctly — this plan uses `mi-archive-quest` per the inspector's pick; a rename is a
> one-line change if preferred.

## 1. Goals

1. Add a fourth top-level workspace folder, `archive/`, created by `/mi-init` alongside
   `journal/`, `quest/`, and `workflow-stream/`.
2. Add a `/mi-archive-quest <quest-folder-name>` command that retires one finished quest
   cycle: it moves the `quest/<slug>/` subfolder and every journal and workflow-stream
   folder that cycle's `reference.md` links to, into `archive/`.
3. Keep the archived set self-contained and internally linked — `reference.md`'s
   `id.md`-based links must still resolve after the move.
4. Never break a live quest cycle: if any folder in the set is still depended on by
   another live cycle, refuse the archive outright (see §6).
5. Be safe to interrupt and re-run — a half-finished archive run leaves a recoverable
   state, never a corrupt one.

## 2. Non-goals

- **No un-archive / restore command.** Moving a bundle back out of `archive/` is a manual
  `mv` for now. A `/mi-restore` command can be a later follow-up.
- **No automatic archiving.** `mi-archive-quest` is inspector-invoked only. No command
  auto-fires it; `/mi-complete-workflow` still only archives the `quest/active.md`
  *pointer*, not the folders on disk.
- **No deletion.** Archiving only ever moves folders. Nothing is deleted.
- **No partial-cycle archiving.** The unit is one whole quest cycle. There is no flag to
  archive a single feature out of a still-relevant cycle.
- **No partial archives.** An archive either moves the cycle's complete linked set or does
  nothing — see the blocking rule in §6.
- **No change to `id.md` / `reference.md` formats.** This feature consumes the v1.1.0
  linking artifacts as-is.

## 3. Trigger and surface

The inspector invokes:

```
/mi-archive-quest <quest-folder-name>
/mi-archive-quest <quest-folder-name> --dry-run
```

- **`<quest-folder-name>`** (required, positional) — the slug of a quest cycle subfolder,
  e.g. `2026-04-27-pricing-meeting+auth-rfc`. Must be a direct child of `quest/`.
- **`--dry-run`** (optional flag) — print the archive plan (what would move, and any
  sharing conflicts that would block it) and exit without moving anything.

### 3.1 Argument validation

`<quest-folder-name>` is interpolated into `mv` source/destination paths, so it is
validated before any path is built — an unchecked value could point the move logic
outside the intended tree:

- Reject an empty string, the literal `.` and `..`, and any value containing `/`.
- Require the value to match the canonical slug pattern
  `^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9][a-z0-9+-]*$` — the same pattern the `active-quest`
  schema enforces for slugs.
- After joining to `quest/<slug>`, canonicalize with `realpath` and assert the result is
  a direct child of the resolved `quest/` directory. A path that escapes `quest/` (via
  traversal or a symlink) is rejected.

Only a value that passes all three checks is treated as the target slug.

The command always shows the plan and asks for explicit `y/n` confirmation before moving
anything (unless `--dry-run`, which never moves and never prompts).

## 4. The `archive/` folder

A new top-level folder under the workflow data root:

```
millwright-inspector/
├── journal/
├── quest/
├── workflow-stream/
└── archive/            ← new
```

### 4.1 Created by `/mi-init`

`commands/mi-init.md` Step 5 currently scaffolds three folders:

```bash
mkdir -p "$data_root/journal" "$data_root/quest" "$data_root/workflow-stream"
```

Add `archive/` to the same idempotent `mkdir -p`:

```bash
mkdir -p "$data_root/journal" "$data_root/quest" "$data_root/workflow-stream" "$data_root/archive"
```

`mi-archive-quest` must also create `archive/` on demand (`mkdir -p`) so it works in
workspaces that were scaffolded before this change shipped — it must not depend on
`/mi-init` having been re-run.

### 4.2 Path helper

Add to `scripts/internal/common.sh`, next to `mi_quest_dir` / `mi_journal_dir` /
`mi_stream_dir`:

```bash
mi_archive_dir() { echo "$(mi_data_root)/archive"; }
```

All archive paths resolve through this helper so a custom `data_root` keeps working.

## 5. What gets archived — resolving the linked set

Given a target quest slug `S`, the archived set is derived from
`quest/<S>/reference.md`:

1. **The quest folder** — `quest/<S>/` itself (always moved).
2. **Journal folders** — for each UUID in `reference.md`'s `journal-refs` frontmatter
   array, resolve it to a folder with `folder-id.sh resolve <id>`.
3. **Workflow-stream folders** — for each UUID in `feature-refs`, resolve likewise.

If `quest/<S>/reference.md` is missing (a cycle created before v1.1.0), the command can
only archive the quest folder itself; it must warn that journal and workflow-stream
folders cannot be auto-gathered and ask whether to proceed with a quest-only archive.

Resolution failures (an ID that resolves to nothing — folder manually deleted/renamed
outside the tooling) are non-fatal: warn, skip that entry, and record it in the manifest
(§9) as `unresolved`. An unresolved ID is *not* a sharing conflict and does not block the
archive — the folder is simply gone.

## 6. The shared-folder rule — block on conflict

This is the correctness-critical part of the design.

A journal folder can seed more than one quest cycle (`/mi-run folderA folderB`, later
`/mi-run folderA folderC` — `folderA` is reused). A workflow-stream feature folder can
likewise be referenced by more than one cycle across re-spec cascades. **Moving a folder
that another live cycle still links to would silently break that cycle's
`reference.md`.**

Therefore, before moving anything, the command checks every journal and workflow-stream
folder in the target's set against the `journal-refs` / `feature-refs` of **every other
quest cycle still live under `quest/`** (every `quest/*/reference.md` except the
target's):

- **No folder is shared** → proceed with the archive.
- **Any folder is shared** → **refuse the entire archive.** Print each shared folder, the
  ID, and the conflicting cycle slug(s), and tell the inspector to archive (or otherwise
  resolve) the conflicting cycle(s) first. Nothing is moved.

The archive is all-or-nothing: only a quest cycle whose complete linked set is
independent of every other live cycle can be archived. This guarantees every archive
bundle is complete (§8) and that no live cycle is ever broken. The quest folder
`quest/<S>/` itself is never shared — slugs are unique.

Because the check only consults *live* quests under `quest/`, archiving cycles in
dependency order works naturally: archive the cycle that reused `folderA` last, then the
earlier one is no longer blocked.

## 7. Active-cycle guard

The command refuses to archive the quest cycle that is currently active:

```bash
active_slug="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh current 2>/dev/null || true)"
[[ "$target_slug" == "$active_slug" ]] && error "refusing to archive the active quest cycle"
```

An active cycle has in-flight features and a live `quest/active.md` pointer; archiving it
would strand the workflow. The inspector must finish or `--archive-active` the cycle
(flipping its status via `/mi-complete-workflow` or `/mi-run --archive-active`) before its
folders can be moved to disk. Note the two senses of "archive": the pointer-status
`archived` (cycle is closed) is the *precondition* for the on-disk archive this command
performs.

## 8. Archive layout

Archived cycles are stored as **self-contained bundles**, one directory per archived
cycle, mirroring the live tree's substructure:

```
archive/
└── <quest-slug>/
    ├── archive-manifest.md         ← what was archived, when, anything unresolved
    ├── quest/
    │   └── <quest-slug>/           ← the moved quest/<slug>/ subfolder
    ├── journal/
    │   ├── <topic-a>/              ← moved journal folders
    │   └── <topic-b>/
    └── workflow-stream/
        └── <feature>/              ← moved feature folders
```

Rationale for the grouped-bundle layout (over a flat `archive/quest/`, `archive/journal/`,
`archive/workflow-stream/` mirror):

- The linked set stays physically together — the same "moves together" intent behind the
  v1.1.0 linking work.
- The per-cycle `<quest-slug>/` namespace makes name collisions impossible (two archived
  cycles can each have a `journal/notes/` without clashing).
- Browsing `archive/` shows one directory per retired cycle — a clean ledger.

Because of the blocking rule (§6), every bundle holds the cycle's *complete* linked set —
there are never inputs left behind in the live tree.

### 8.1 Resolution after archiving

`folder-id.sh resolve <id>` currently scans `journal/*/id.md` and
`workflow-stream/*/id.md`. After archiving, those folders live under
`archive/<slug>/journal/...` and won't be found.

Extend `folder-id.sh resolve` (and `list`) to also scan the archive tree, e.g.
`archive/*/journal/*/id.md` and `archive/*/workflow-stream/*/id.md`. This keeps an
archived cycle's `reference.md` fully resolvable — a key goal (§1.3). The depth-2 `find`
in `folder-id.sh` becomes a depth-2 scan under each archive bundle's `journal/` and
`workflow-stream/` subdirs.

Two constraints on the extended scan:

- **Exclude `*.partial/` bundles.** A staging bundle (§10) is not yet committed; its
  folders must not become globally resolvable before the commit-point rename, or the
  `.partial` safety model is weakened. The scan only descends into finalized
  `archive/<slug>/` directories, never `archive/<slug>.partial/`.
- **Error on ambiguous matches.** Today `resolve` returns the first `id.md` whose `id`
  matches. Archiving — and any future manual restore — raises the chance of two `id.md`
  files carrying the same UUID (e.g. a folder copied instead of moved). `resolve` should
  be hardened to **fail with a clear error when more than one folder matches an ID**
  rather than silently returning the first hit. This is a small change to the v1.1.0
  `resolve` logic and is in scope for this feature.

## 9. The archive manifest and recovery record

Each bundle carries `archive-manifest.md`. It is written **first — before any folder is
moved** — and serves three roles at once: the persisted archive plan, the recovery source
of truth, and the final audit record.

```markdown
---
id: <uuid>
state: in-progress | complete
quest-slug: <quest-slug>
quest-id: <reference.md's own id, or null>
archived-at: <ISO-8601 timestamp>
journal-archived: [<id>, ...]
feature-archived: [<id>, ...]
unresolved: [<id>, ...]
---

# Archive manifest — <quest-slug>

Human-readable record: one bullet per folder, pairing the ID with the folder name and
the subtree it came from. `unresolved` IDs (a referenced folder gone at archive time) are
listed with a note.
```

- **Written first, so the plan is persisted before any move.** Once it exists, recovery
  (§10) can re-derive the full intended move set from it — it never needs to re-read
  `quest/<slug>/reference.md`, which may itself already have been moved. Each folder is
  recorded by ID *and* basename (basenames are unique within `journal/` and within
  `workflow-stream/`), which is enough for recovery to relocate it.
- **`state`** is `in-progress` while the bundle is staged under `archive/<slug>.partial/`,
  flipped to `complete` immediately before the commit-point rename (§10). The
  authoritative completeness signal is the directory name (`.partial` vs final); `state`
  just makes the file self-describing and lets recovery report cleanly.
- **`quest-id`** is `null` for a pre-v1.1.0 quest-only archive that had no `reference.md`
  (§5, §11); the schema admits it as `oneOf: [null, uuid-v4]`. `journal-archived` /
  `feature-archived` are then empty arrays.
- **Atomic, validated write.** The manifest is rendered to a temp path, validated with
  `frontmatter.sh validate <tmp> archive-manifest`, then `mv`'d into place — so a
  truncated or schema-invalid manifest never appears even momentarily. `frontmatter.sh
  init` already does render-then-validate; the atomic `mv` is the added step. The
  `hooks/validate-on-write.sh` case below covers only hand-edits — script-driven `mv`s
  do **not** fire the hook — so `scripts/archive.sh` validating directly is mandatory,
  not optional.
- A new schema `schemas/archive-manifest.schema.yaml` validates it; a new template
  `templates/archive-manifest.md.tmpl`; a new hook case in `hooks/validate-on-write.sh`
  maps `*/archive/*/archive-manifest.md` to the schema (for manual edits).

## 10. Execution flow and partial-run safety

Moving N folders is not atomic. An interruption between moves must leave a recoverable
state, never a corrupt one. The command **persists its plan before touching anything**,
then uses a `.partial` staging directory whose atomic rename is the single commit point —
mirroring `blueprints.sh rotate`.

1. **Resolve & classify.** Validate the slug (§3.1). Read `quest/<slug>/reference.md`,
   resolve every `journal-refs` / `feature-refs` ID (§5), and build the move set.
2. **Guard.** Refuse if the cycle is active (§7) or if a finalized `archive/<slug>/`
   already exists. If `archive/<slug>.partial/` exists, this is a resumed run — skip
   straight to step 8.
3. **Sharing check.** Run the shared-folder check (§6). If any folder is shared, print the
   conflicts and refuse — nothing is staged or moved.
4. **Preview & confirm.** Print the plan. On `--dry-run`, stop here. Otherwise
   `read -p "Proceed? (y/n): "`.
5. **Stage.** `mkdir -p archive/<slug>.partial/{quest,journal,workflow-stream}`.
6. **Persist the plan.** Render `archive/<slug>.partial/archive-manifest.md` with
   `state: in-progress` and the full resolved set, validate it, and `mv` it into place
   (§9). **After this step the plan survives any interruption** — recovery reads it and
   never depends on the now-movable `reference.md`.
7. **Move.** `mv` each folder in the set into the staging dir.
8. **(Resume entry point.)** Read the staged `archive-manifest.md` for the intended set.
   For each folder, detect whether it is still at its source or already under `.partial/`
   (folder basenames are unique within `journal/` and within `workflow-stream/`) and `mv`
   any that have not moved yet. A folder already at its destination is skipped — the step
   is idempotent.
9. **Finalize.** Flip the manifest's `state` to `complete`, then atomically rename
   `archive/<slug>.partial/` → `archive/<slug>/`.

The commit point is the step-9 rename: either `archive/<slug>/` exists (complete) or
`archive/<slug>.partial/` exists (resumable). A resumed run re-enters at step 8 and reads
its plan from the staged manifest — so even an interruption *after* `quest/<slug>/` (and
its `reference.md`) was moved is fully recoverable, because the plan no longer lives in
`reference.md`.

A backing script `scripts/archive.sh` owns this deterministic logic (subcommands such as
`plan <slug>`, `run <slug>`, `resume <slug>`); `commands/mi-archive-quest.md` is the
runbook that calls it and handles the inspector-facing preview/confirm dialogue — the same
script-plus-runbook split used across the codebase.

## 11. Edge cases

- **`reference.md` missing** (pre-v1.1.0 cycle) — offer a quest-folder-only archive with a
  warning; cannot auto-gather journal/feature folders. The manifest is written with
  `quest-id: null` and empty `journal-archived` / `feature-archived` (§9).
- **Target slug not found** under `quest/` — error listing available quest subfolders.
- **Target is the active cycle** — refuse (§7).
- **`archive/<slug>/` already exists** — refuse; the cycle is already archived.
- **Any journal/feature folder shared with another live cycle** — refuse the whole
  archive, naming the conflicting cycle(s) (§6).
- **An ID resolves to nothing** — warn, skip, record as `unresolved`; does not block (§5).
- **Empty `feature-refs`** (cycle archived before any feature was built) — fine; archive
  the quest folder and journal folders only.
- **Workspace predates `archive/`** — `mi-archive-quest` creates it on demand (§4.1).

## 12. Files to add / change

| Action | File | Purpose |
|--------|------|---------|
| **add** | `commands/mi-archive-quest.md` | Command runbook (auto-registers via `plugin.json`'s `commands: ./commands/`) |
| **add** | `scripts/archive.sh` | Backing script: `plan` / `run` / `resume` |
| **add** | `templates/archive-manifest.md.tmpl` | Manifest template |
| **add** | `schemas/archive-manifest.schema.yaml` | Manifest schema |
| **edit** | `scripts/internal/common.sh` | Add `mi_archive_dir()` helper |
| **edit** | `scripts/folder-id.sh` | `resolve` / `list` scan `archive/*/...` excluding `*.partial/`; `resolve` errors on ambiguous matches (§8.1) |
| **edit** | `commands/mi-init.md` | Add `archive/` to the Step 5 `mkdir -p` |
| **edit** | `hooks/validate-on-write.sh` | Add `*/archive/*/archive-manifest.md` → `archive-manifest` case |
| **edit** | `docs/workflow-spec.md`, `README.md` | Document the 4-folder layout and the new command |
| **edit** | `CHANGELOG.md`, version | New minor release entry |

## 13. Testing plan

Exercise `scripts/archive.sh` against a scratch `MI_DATA_ROOT`, mirroring the v1.1.0
`folder-id.sh` tests:

1. **Happy path** — two journal folders, two features, none shared → bundle contains
   `quest/`, both `journal/` folders, both `workflow-stream/` folders, and a manifest;
   live `quest/`, `journal/`, `workflow-stream/` no longer contain them.
2. **Sharing conflict blocks** — folder A seeds the target cycle *and* a second live cycle
   → archive is refused, the conflicting cycle is named, nothing is moved.
3. **Dependency-order archiving** — after archiving the second (reusing) cycle, archiving
   the first now succeeds.
4. **Resolution after archive** — `folder-id.sh resolve <id>` finds archived folders in
   the bundle.
5. **Active-cycle guard** — archiving the active slug is refused.
6. **Idempotent re-entry, mid-move** — interrupt after step 7 with some folders staged
   (including the case where `quest/<slug>/` has already moved, so `reference.md` is no
   longer at its live path), re-run → resume reads the staged manifest and completes.
7. **Interruption after manifest write, before final rename** — `state: complete` (or
   `in-progress`) `.partial` bundle present, re-run → finalized exactly once; never
   double-applied.
8. **`--dry-run`** — prints the plan, moves nothing.
9. **Missing `reference.md`** — offers quest-only archive; manifest has `quest-id: null`.
10. **Path-traversal rejection** — slugs like `..`, `a/b`, empty string, or a symlinked
    `quest/<slug>` escaping the tree are rejected before any path is built (§3.1).
11. **Duplicate ID after archive scanning** — once `folder-id.sh resolve` scans
    `archive/`, an ID present in two `id.md` files makes `resolve` error, not silently
    pick one (§8.1).
12. Re-run the rename-leakage lint guard (`tests/lint/run.sh`).

## 14. Open questions

1. **Restore** — is a `/mi-restore <slug>` follow-up wanted, or is manual `mv` acceptable
   indefinitely? (Currently a non-goal — §2.)
