# Context-bundle export — implementation plan

A new overseer-invokable command, `/mo-export-bundle`, that produces a
single markdown file describing the active feature's state, intended
for a fresh agent session that may not have access to this plugin's
data tree or this codebase. The bundle is **self-sufficient for
context** (every fact the receiving agent needs to reason about scope,
requirements, history, and open findings is inlined). It is **not**
free of workflow-internal vocabulary: workflow file paths and
`.md` filenames are mechanically scrubbed (§2.3, §8.2), but role and
tool words (`mo-workflow`, `millwright`, `overseer`, `seam`,
`cycle flavor`, finding ids like `IR-NNN`) may still appear in body
text where they were authored by humans or sub-agents in the source
files. The §5.1 prompt block tells the receiving agent to treat such
terms as opaque labels.

The bundle is **derived** and **disposable**. It reads canonical
workflow artifacts (`requirements.md`, `config.md`, `decisions.md`,
`grounding-report.md`, `summary.md`, `todo-list.md`,
`change-summary.md`, `manual-test-*.md`, `review-context.md`,
`overseer-review.md`) and emits a standalone document. The canonical
files remain the source of truth.

## Design history

This plan went through three conceptual revisions during the design
discussion of 2026-05-08, plus multiple rounds of review feedback
within v3 (see §13 for round-by-round traceability):

1. **v1 draft** — concatenate canonical files verbatim. Rejected:
   frontmatter/HTML comments/file paths/template scaffolding would
   leak to a stranger reader.
2. **v2 draft** — distill into task-neutral prose. Rejected (in part):
   a deterministic shell script with regex helpers cannot reliably
   *synthesize* prose; it can only *extract* and *reformat*. Promising
   semantic translation in a deterministic implementation is
   dishonest.
3. **v3 (this plan)** — **strict extractive rewriting**. The script
   extracts known sections from canonical files, strips frontmatter
   and HTML comments, drops plugin-internal section headings in favor
   of task-neutral ones the script controls, and emits the result as
   bullets and short paragraphs. The script does not paraphrase,
   summarize, or aggregate across files. Where source content is
   itself worded in plugin-specific terms (e.g., the word "seam" in
   `grounding-report.md`), that wording will appear in the bundle —
   the agent prompt block warns the receiver about this honestly. v2
   stays on the roadmap as an opt-in agent-composition mode.

## 1. Goal

When the overseer says "export the context" (or types
`/mo-export-bundle`), produce a single `.md` file at:

```
tmp/bundles/<feature>-stage<N>-<YYYYMMDD-HHMMSS>.md
```

The file is a **standalone agent brief**: extracted from the workflow's
canonical files, stripped of frontmatter and HTML scaffolding,
mechanically scrubbed of workflow file paths and `.md` filenames in
body text, structured under task-neutral section headers, and prefaced
with a prompt block telling the receiving session what kind of
document this is and what caveats to apply.

What the bundle **does not** promise: removal of every
workflow-flavored word from body text. The receiver must treat
unfamiliar role / tool / domain terms (`mo-workflow`, `millwright`,
`overseer`, `seam`, `cycle flavor`, finding ids) as opaque labels.
The prompt block restates this; the §1 paragraph above tells the
overseer the same thing before the bundle is even generated.

## 2. Principles

These are the rules `bundle.sh` follows when composing every section:

1. **Extract, don't synthesize.** Each section's body is composed by
   pulling specific subsections from one or more source files,
   stripping frontmatter / HTML comments / template scaffolding, and
   re-emitting under a task-neutral header. The script never writes
   new sentences from facts spread across files.
2. **Include every relevant fact, not every file.** A file with no
   meaningful content for the active feature is *omitted entirely*; a
   file with meaningful content is *extracted in part*.
3. **Strip workflow chrome at the boundary, then targeted-scrub paths
   from body.** Two passes, both deterministic:

   - **Chrome stripping** (always): frontmatter blocks, HTML comments,
     snapshot caveats addressed to internal consumers, sync-marker
     lines (`<!-- mo:sync-marker — … -->`), and template placeholder
     strings are removed entirely.
   - **Targeted body scrubbing** (always): inside extracted body
     text, the bundler does **deterministic regex substitutions** using
     the exact `BODY_SCRUB_TABLE` in §8.2. In prose, that table covers
     only:
     - Unambiguous workflow data-tree prefixes:
       `workflow-stream/...`, `quest/...`,
       `blueprints/current/...`, and `blueprints/history/vN/...`.
     - Known workflow-generated implementation records:
       `implementation/grounding-report.md`,
       `implementation/change-summary.md`,
       `implementation/review-context.md`, and
       `implementation/overseer-review.md`.
     - Manual-test artifacts under the feature-permanent `test/` folder:
       `test/manual-test-plan.md` and `test/manual-test-results.md`.
       (Legacy `implementation/manual-test-*` paths still match the
       implementation/ entry above for backwards compatibility with
       archived bundles referencing pre-relocation history.)
     - Bare workflow .md filenames matching the canonical list in §8.2
       (`progress.md`, `requirements.md`, `config.md`, etc.).

     The §8.2 table is canonical. This summary cannot broaden it.
     Regex matches are replaced with either `<internal path>` or
     `<an internal record>`, as specified in that table.
   - **Not scrubbed**: workflow role / tool / system words such as
     `mo-workflow`, `millwright`, `overseer`, `seam`, `cycle flavor`,
     `IR-NNN`. Removing these mechanically risks distorting
     human-authored sentences (e.g., "the overseer chose X" cannot
     be safely rewritten without changing meaning). The prompt block
     (§5.1) acknowledges these may appear and tells the receiving
     agent to read charitably.

   This is a closed, mechanical substitution — not synthesis. It
   does not violate Principle §2.1 ("extract, don't synthesize"). The
   substitutions are listed exhaustively in §8.2 so the bundler's
   behavior is testable byte-for-byte against fixtures.
4. **Use task-neutral section headers.** The script controls every
   header it emits. Source-file headings like "Goals (this cycle)",
   "Active scope", or "Implementation Review" are dropped; the bundle
   uses "Requirements and constraints", "Scope in this session",
   "Open review findings" instead.
5. **Be honest about leftover phrasing.** Body text inside the source
   files — bullets a human authored, prose a sub-agent wrote — is
   passed through unchanged **except for chrome stripping (Principle
   §2.3 first pass) and `scrub_body_paths` (Principle §2.3 second
   pass)**. Workflow-flavored role/tool words ("seam", "cycle
   flavor", `mo-workflow`, `millwright`, `overseer`) are deliberately
   not scrubbed and may appear; the prompt block (§5.1) tells the
   receiving agent to read the brief charitably.
6. **Fail honestly when content isn't there.** Stage-4+ artifacts may
   not exist at stage 3. Don't fabricate; just omit the section.

## 3. Non-goals

- **No semantic synthesis or paraphrasing.** The script does not
  rewrite sentences, aggregate across items, or compose narrative
  paragraphs. (See §11 for a v2 follow-up that adds an agent
  composition pass.)
- **No inline diffs or code excerpts.** v1 emits a *changed-files
  index* (paths + adds/dels + a required role/purpose annotation —
  see §5.14), not the diffs themselves. Documented in the prompt
  block so the receiving agent knows to ask.
- **No diagrams.** `.puml` sources are excluded.
- **No manifest file.** Inclusion is driven by file existence, not by
  a registry.
- **No multi-feature bundles.** The bundle is scoped to the **active
  feature**; other features in the same cycle each need their own
  export.
- **No automatic regeneration on stage advance.** The bundle is a
  point-in-time snapshot; the overseer runs the command again for a
  fresh copy.
- **No persistence inside the canonical tree.** Output goes to
  `tmp/bundles/`, never to `quest/<slug>/` or
  `workflow-stream/<feature>/`.
- **No hand-curation knobs in v1.** No `bundle-extras.md`, no
  `--include` / `--exclude` flags.

## 4. Output location and gitignore guarantee

```
tmp/bundles/<feature>-stage<N>-<YYYYMMDD-HHMMSS>.md
```

- `<feature>` is the active feature slug from
  `progress.md → active.feature`.
- `<N>` is `progress.md → active.current-stage`, used purely as a
  filename label.
- Timestamp is the local-time export moment.

### 4.1 Self-contained gitignore (review fix)

`tmp/` is gitignored in this plugin's own repo, but **not necessarily
in the user's project repo** where the plugin is installed. Relying on
the user to have an ignore rule is unsafe. Instead, on every export
the command idempotently writes:

```
tmp/bundles/.gitignore
```

with body:

```
*
!.gitignore
```

This makes the directory ignore itself — every bundle inside is
gitignored, but the `.gitignore` file is committable. The command
never modifies the project's root `.gitignore`. Subsequent runs
compare content rather than blindly overwriting; if the body is
already correct, the write is a no-op.

## 5. Bundle structure

Section order is fixed. Each section is **omitted** (not stubbed) when
its source file is missing or carries no meaningful content for the
active feature.

**Universal body contract.** Throughout this section, words like
"verbatim", "passed through", "unchanged", and "as-is" describe a
body that has already had Principle §2.3's two universal passes
applied: chrome stripping (frontmatter / HTML comments / sync markers
/ template placeholders) and `scrub_body_paths` (the canonical regex
table in §8.2). No section is exempt. Per-section text below adds
section-specific transformations (e.g., dropping a heading, filtering
to bullets in a particular state) on top of the universal passes.

### 5.1 Top prompt block (always emitted)

```markdown
# <Feature title in plain words> — agent handoff brief

> You are picking up work on a software feature. This document is
> self-contained: every fact you need to act is below. Do not assume
> access to files, repositories, or systems referenced inside any
> quoted material — only the prose in this brief is reliable.
>
> This brief was *extracted* from project planning records, not
> rewritten. Internal file paths and record names have been replaced
> with placeholders (`<internal path>`, `<an internal record>`); if
> you see those, you do not have access to what they refer to — ask
> the human if it matters.
>
> Some bullets may still use technical phrasing or refer to roles or
> tooling from the originating system. Read such phrasing charitably
> as natural language; nothing in this brief depends on you knowing
> what those terms mean.
>
> If you need to inspect specific code, diffs, or diagrams, ask the
> human who shared this brief; this document does not include them.
>
> If you are asked to review the work, focus on the "Requirements and
> constraints", "Out of scope", and "Open review findings" sections.
> If you are asked to continue the work, focus on "What the next agent
> should do".
```

The heading uses the active feature slug verbatim
(`# auth-jwt — agent handoff brief`). Earlier drafts called for
title-casing (`auth-jwt → Auth Jwt`), which produced poor results
for acronym-heavy slugs (`oauth-pkce → Oauth Pkce`,
`api-rate-limiter → Api Rate Limiter`). Verbatim is honest, matches
the Sources footer (§5.18), and avoids guessing capitalization the
bundler cannot get right deterministically.

### 5.2 Custom project instructions (review fix: include `config.md → Overseer Additions`)

Extracted from `blueprints/current/config.md → ## Overseer Additions`
— a section explicitly designated by the workflow as "preserved
verbatim" for human-authored project-specific prompts and
instructions. If the section's body is non-empty after stripping HTML
comments, it is included as:

```markdown
## Custom project instructions

<verbatim body of the Overseer Additions section, comments stripped>
```

The heading "Overseer Additions" is replaced with "Custom project
instructions" — the bundle controls the header. Body is passed
through subject only to the two universal passes from Principle
§2.3: chrome stripping and `scrub_body_paths`. No other rewriting
applies — human-authored content is otherwise verbatim.

If the section is empty (or contains only HTML comments), this
section is omitted.

### 5.3 Project-wide constraints (review fix: include `summary.md` cross-cutting)

Extracted from the active cycle's
`quest/<slug>/summary.md → ## Cross-cutting constraints`. These are
constraints that span features in the cycle and may not have been
copied into `requirements.md`. If non-empty:

```markdown
## Project-wide constraints

<bullets from the Cross-cutting constraints section, verbatim>
```

`summary.md`'s **other** per-feature sections (`## Feature: <other>`)
are not included — they describe sibling features, which are out of
scope for the receiving agent. The cross-cutting block above and the
active-feature block below (§5.4) are the only parts of `summary.md`
that cross into the bundle.

### 5.4 Feature background (review fix: include `summary.md → ## Feature: <active_feature>`)

Extracted from the active cycle's
`quest/<slug>/summary.md → ## Feature: <active_feature>` — the
journal-derived digest of what this feature is for, what depends on
it, and what acceptance hints surfaced during stage-1 intake. The
existing workflow already treats this section as **active context**
for primers and review snapshots (`templates/primer.md.tmpl:29`,
`docs/workflow-spec.md:646`); excluding it from the bundle would
strand the receiving agent without that distillation while still
having requirements and grounding-report context.

If non-empty:

```markdown
## Feature background

<verbatim body of `## Feature: <active_feature>` from summary.md,
 sub-headings preserved, frontmatter and HTML comments stripped>
```

The bundle controls the header — "Feature background" replaces the
workflow-flavored "Feature: <slug>". Sub-headings inside the
section (if any) are preserved verbatim because they carry the
journal author's structuring; their phrasing is human-authored
content, not workflow chrome.

If `summary.md` is missing (extreme edge case — the cycle never ran
stage 1) or the `## Feature: <active_feature>` section is absent or
empty, this bundle section is omitted.

### 5.5 Implementation rules to follow (review fix: extract `config.md → ## Rules`)

Extracted from `blueprints/current/config.md → ## Rules` — the
workflow's source for project constraints that govern this cycle's
implementation. The template format for each entry is
`- <name>: <one-line reason>; path: .claude/rules/<name>.md`. The
script:

- Strips the `; path: .claude/rules/<name>.md` tail from each bullet,
  since the path is workflow-internal.
- Re-emits the remainder (`<name>: <reason>`) as a bullet under the
  task-neutral header "Implementation rules to follow".
- Leaves `<name>` as-is even though it may be workflow-flavored —
  per Principle §2.5 the script does not paraphrase. The prompt
  block tells the receiver to read such names charitably.

`config.md → ## Skills` and `## Load on demand` remain dropped (§10);
they describe workflow tooling, not project constraints.

If `## Rules` is empty after stripping, this section is omitted.

### 5.6 Objective

The first paragraph of `blueprints/current/requirements.md`'s body
(after frontmatter, the `# Requirements — <feature>` heading, and
HTML comments are stripped). If the file's body has no leading
paragraph (only headings and bullet lists), this section is omitted —
the script does not synthesize one.

### 5.7 Scope in this session (review fixes: stage-2 PENDING + mid-cycle additions)

Earlier drafts filtered `todo-list.md` rows by `IMPLEMENTING`, which
silently empties at stage 2 (items are still `PENDING` until
`/mo-plan-implementation` flips them at stage 3 — see
`docs/workflow-spec.md:518`). The previous revision of this plan
fixed that by sourcing scope from `requirements.md → todo-item-ids`
alone. **That single source is also wrong**: per
`docs/blueprint-regeneration.md:169`, `todo-item-ids` captures the
items that *initiated* the cycle and is not retroactively updated
when an overseer adds a new item mid-cycle via
`/mo-update-todo-list add … IMPLEMENTING`.
`/mo-update-blueprint` likewise preserves the previous list as-is
(`commands/mo-update-blueprint.md:345`). So a single-source design
either misses stage-2 PENDING items or misses stage-3+ mid-cycle
additions.

**Dual-source contract.** Take the union of two sources, deduplicated
by id:

1. **`blueprints/current/requirements.md → todo-item-ids` frontmatter**
   — captures the items that initiated the cycle, regardless of
   state. This is the correct source for stage 2 (when items are
   `PENDING`) and the canonical record of the cycle's planned scope.
2. **Active-feature rows in `todo-list.md` whose state is
   `IMPLEMENTING`** — captures items pulled into scope mid-cycle by
   `/mo-update-todo-list add … IMPLEMENTING` after `requirements.md`
   was written. The active feature is `progress.md → active.feature`.

For every candidate id from either source, resolve the current row in
`todo-list.md` before emitting. If the current state is `CANCELED`,
exclude the item from "Scope in this session": the workflow defines
`CANCELED` as removed from active scope mid-cycle, so including it
would tell the receiving agent to work on something deliberately
dropped. If a future version wants cancellation history in the brief,
it can add a separate "Removed from scope" section; v1 keeps the scope
section action-oriented.

The bundler emits the remaining union, deduplicated by item id, in the
following order: items from source (1) first (preserving the order
they appear in `todo-item-ids`), then items from source (2) that are
not already in source (1) (preserving the order they appear in
`todo-list.md`).

**Emission format (unchanged):**

```
- <description from the matching todo row> (item <id>).
```

State labels, assignees, and other workflow-state-machine columns
are dropped. The trailing `(item <id>)` is preserved because review
feedback often references item ids.

**Edge cases:**

- **No `requirements.md` (pre-stage-2):** source (1) is empty. Fall
  back to source (2) only. If both are empty, omit the section.
- **`requirements.md` present but `todo-item-ids: []`:** source (1)
  is empty; rely on source (2). Continue normally.
- **An id from `todo-item-ids` currently has state `CANCELED`:**
  omit it from "Scope in this session". `CANCELED` is an explicit
  removal from active scope, not a work item for the receiving agent.
- **No active feature** (handled at the §6 refusal layer; the
  bundler never reaches this section in that case).
- **An id in `todo-item-ids` doesn't appear in `todo-list.md`**
  (workflow inconsistency, rare): emit
  `- (item <id>) — description not found in todo list.` rather
  than silently dropping it.

This dual-source design is **stage-independent (works at any stage
from 2 onward) and mid-cycle-resilient (survives todo additions and
cancellations)**: every committed non-canceled item appears in scope
regardless of the workflow stage and regardless of whether it was
selected at stage 1.5 or added later via `/mo-update-todo-list`.
Cancellation (a state filter) is the one exception by design — see
the second-to-last edge case above.

### 5.8 Requirements and constraints (review fix: correct canonical heading)

Extracted from `blueprints/current/requirements.md → ## Goals (this
cycle)`. The exact source heading is `## Goals (this cycle)` — the
v3-pre-round-3 draft used the shorter `## Goals`, which does not
match the workflow-generated heading and would silently omit the
entire section. The script:

- Strips frontmatter, the leading `# Requirements — <feature>`
  heading, and HTML comments.
- Drops the source heading "Goals (this cycle)"; the bundle emits the
  single header "Requirements and constraints".
- Re-emits each goal bullet verbatim under that header, preserving
  any sub-bullets the human or the workflow wrote.

The workflow does **not** generate separate `## Constraints` or
`## Acceptance criteria` top-level sections (per
`docs/blueprint-regeneration.md:139` and the requirements template,
constraints and acceptance hints are *per-goal* notes the millwright
weaves into individual Goals bullets). Earlier drafts of this plan
called for extracting those headings as separate sub-blocks; the
extraction would always have returned nothing. Removed in this
revision.

If the section ends up empty after stripping, the entire header is
omitted.

### 5.9 Planned for future work (review fix: include `## Planned (future cycles)`)

`blueprints/current/requirements.md` carries a third section,
`## Planned (future cycles)`, listing items that **will** be
implemented in later cycles but whose architectural seam this cycle
must keep open. Per `docs/blueprint-regeneration.md:167`, "Planned"
items are different from "Non-goals": the former WILL happen, the
latter WILL NOT.

For a fresh agent, this distinction matters: design decisions that
might look over-engineered are often there to accommodate a planned
future item. The bundle therefore extracts this section as:

```markdown
## Planned for future work

The implementation must keep architectural room for the following
items, which will be delivered in later cycles (not in this session):

<bullets verbatim from `## Planned (future cycles)`>
```

If the section is empty or absent, this bundle section is omitted.

### 5.10 Out of scope (review fix: correct canonical heading)

From `blueprints/current/requirements.md → ## Non-goals (out of
scope)`, same handling as §5.8. The exact source heading is
`## Non-goals (out of scope)` — the previous draft used `## Non-goals`,
which would silently omit the section. The bundle emits the single
header "Out of scope" and re-emits the bullets verbatim. Omitted if
empty.

### 5.11 Decisions already made (review fix: empty-detection)

Parsed from `workflow-stream/<feature>/decisions.md`. The template
ships with two stage headings (`## Stage 2 — Blueprint approval`,
`## Stage 5 — Findings canonicalization`) plus HTML comments — none
of that is content. The script:

1. Strips frontmatter, the leading `# Decisions — <feature>` heading,
   and all HTML comments.
2. Walks remaining content and counts **real bullet lines** — lines
   matching `^\s*-\s+\S` whose body is not pure template placeholder
   (`**YYYY-MM-DD**`, `<Goal/seam decision …>`).
3. **If zero real bullets, the section is omitted entirely** (no "no
   decisions" stub).
4. If real bullets exist, drop the `## Stage <N> — <label>` headings
   and re-emit each bullet under a flat list. Stage provenance is
   workflow-internal.

### 5.12 Existing system context

From `workflow-stream/<feature>/implementation/grounding-report.md` —
the stage-2 codebase-grounding sub-agent's audit. Without it a
reviewer can verify requirements alignment but cannot understand
integration shape.

The script extracts the file's content per todo item, with one
sub-bullet per documented field (`Seam`, `Pre-existing components`,
`Cycle flavor`, `Notes`):

```markdown
## Existing system context

The implementation builds on the following pre-existing parts of the
codebase:

- **Item <ITEM-ID> — <description>**
  - Seam: `<folder/path>` (existing files: `<file1>`, `<file2>`).
  - Pre-existing components: `<components>`.
  - Cycle flavor: `<greenfield | bugfix | improvement>`.
  - Notes: <notes line(s)>.

- **Overall:** <bullets from `## Overall seam summary`, verbatim>.
```

The script does **not** aggregate across items, collapse uniform
flavors, or synthesize a "risks" line. Per Principle §2.1 it
extracts; it does not synthesize. The "Risks" framing from v2 is
dropped. Cross-item summarization, if useful, can be added in v2 via
agent composition.

If `grounding-report.md` is missing (pre-stage-2 or unusual states),
the section is omitted.

### 5.13 Implementation summary (stage 4+, if `change-summary.md` exists)

Extracted from `change-summary.md`'s `## Detected entrypoints` and
`## Suspected flows` sections, **as bullet lists** (no prose
narrative). Headings inside the source are dropped; sub-headers
"Entrypoints introduced or modified" and "End-to-end flows" are
emitted by the bundler when the corresponding source section is
non-empty.

Staleness handling — see §5.14.

If both source sections are empty (rare), this section is omitted.

### 5.14 Changed areas (stage 4+, if `change-summary.md` exists; review fixes: staleness + purpose required)

Extracted from `change-summary.md`'s `## Changed files` section, with
two structural changes versus the source:

**Required role/purpose per file.** The `change-summary.md` template
allows but does not require a per-file `<one-line purpose>`
annotation. For an agent without codebase access, bare paths are
weak context. The bundle therefore splits the changed-files list into
two groups:

- **Annotated files** — files whose source bullet has a non-empty
  purpose annotation. Emitted as:
  ```
  - `<path>` (+adds/-dels): <purpose annotation>.
  ```
- **Files with no annotated purpose** — emitted under a sub-bullet
  group titled "Changed but purpose not annotated. Ask the human if
  these matter for your task.":
  ```
  - `<path>` (+adds/-dels)
  ```
  This group is always emitted with the explanatory sub-header when
  any unannotated files exist. Silent dropping is worse than visible
  caveat.

**Staleness handling (review fix).** The bundle compares
`change-summary.md`'s frontmatter `(base-commit, head)` against
`progress.md → active.base-commit` and `git rev-parse HEAD` (run by
the bundler in the project's working tree). If either differs, a
visible warning is prepended **above** the section:

```markdown
> ⚠ The change summary below was generated for an earlier commit
> range and may not reflect the latest commits. Recorded range:
> `<old-base>..<old-head>`. Current range: `<active-base>..<HEAD>`.
```

The section is still emitted in stale form. Omitting useful context
is worse than warning. The prior-version contradiction between §5.14
and §9 is resolved here in favor of "use with warning"; §9 will
inherit this behavior.

If `change-summary.md` is missing entirely, the section is omitted
(no warning to print).

**Scrub-table interaction (review fix, round 5).** Per the universal
body contract at the top of §5, every changed-file path in this
section flows through `scrub_body_paths` (§8.2). With the round-5
tightening, only paths under the four unambiguous workflow
prefixes (`workflow-stream/…`, `quest/…`, `blueprints/current/…`,
`blueprints/history/v\d+/…`) and the workflow-specific files under
`implementation/` are scrubbed. Project paths like `src/…`, `lib/…`,
`migrations/…`, or `implementation/CartService.ts` are passed
through verbatim.

Two residual edge cases are accepted, not fixed in v1:

- A project whose diff legitimately touches a file whose bare name
  collides with a workflow .md filename (e.g., a top-level
  `requirements.md` in the project) will see that path scrubbed to
  `<an internal record>` in the bundle. Rare enough to accept as a
  known false positive.
- Diffs in this plugin's own repo (where `commands/`, `scripts/`,
  `templates/`, `docs/` are project paths) emit those paths without
  scrubbing — correct behavior, not a bug, since those *are* the
  project for this repo.

If a future use case requires perfectly faithful project paths even
across the rare collision, §11 lists "context-aware scrubbing" as a
v2 candidate.

### 5.15 Tests run / manual checks (stage 5+, if `manual-test-*.md` exist)

If `test/manual-test-plan.md` exists: emit a "Planned manual checks:"
subsection with each scenario as a bullet (description verbatim,
scenario id dropped if present).

If `test/manual-test-results.md` exists: emit a "Results:" subsection
with each scenario's verdict (pass / fail / skipped) and the recorded
note. Each verdict-and-note pair becomes one bullet.

Either may be present without the other.

### 5.16 Open review findings (stage-independent — emitted whenever `overseer-review.md` has content; review fixes: gate on structured OR freeform, in-bundle legend)

`overseer-review.md` mixes overseer instructions for typing findings,
plain-sentence findings, and structured `### IR-NNN` blocks. The
script:

1. Strips the entire pre-amble (the "Plain sentences (easiest)" /
   "Structured blocks (precise)" / "Scope guide" / "How the loop
   works" instructional text — all addressed to the overseer, not to
   a stranger reviewer).
2. Strips the `## Implementation Review` heading.
3. For each `### IR-NNN — <summary>` block whose `status:` is `open`,
   emits a bullet. The bullet keeps three pieces of structured
   information from the source: the summary, the severity, and the
   recommended action (the source's `scope:` field, kept verbatim
   because it is the canonical hint for *how* to act on the finding).
   Format:

   ```
   - **<summary>** (<severity>): <details body> — Recommended action: <scope>.
   ```

   If the source block has no `scope:` line (the overseer-review
   template allows omitting it), emit
   `Recommended action: not specified.` so the receiver still sees
   the structural cue.

   `IR-NNN` ids, `source:`, `seed-id:`, and `fix-note:` keys are
   dropped — those are workflow bookkeeping with no value to the
   receiving agent.
4. For freeform paragraphs (text under `## Implementation Review` that
   is not part of a `### IR-NNN — …` block), emits each paragraph as
   a `- *(unclassified)*: <text>` bullet.
5. **Recommended-action legend (round-8 review fix).** When at least
   one bullet emitted in step 3 carried a structured `scope:` value,
   the section ends with a small legend bundler-authored block
   explaining the four scope values in plain English:

   ```markdown
   > _**Action labels.** "fix" = patch existing code, smallest
   > change. "re-implement" = redo the implementation against the
   > existing plan and spec. "re-plan" = revise the plan, then
   > re-implement. "re-spec" = revise the spec/design, then re-plan
   > and re-implement._
   ```

   The legend is bundler-authored chrome, not extracted source.
   Emit only when at least one structured bullet carried a real
   `scope:` value (`Recommended action: not specified.` does not
   trigger it). Suppress for freeform-only sections — they have no
   action labels to legend.

**Gating (review fix).** The earlier draft gated the entire section on
"open IR-NNN blocks present," which would silently skip the section
when the review file contained only unclassified freeform paragraphs.
Corrected gate: the section is omitted **only when both** of the
following are true:

- No `### IR-NNN — <summary>` block has `status: open`.
- No freeform reviewer text remains under `## Implementation Review`
  after stripping the pre-amble and the heading itself.

If either source is non-empty, the section is emitted with whichever
content is present (structured bullets only, freeform bullets only,
or both).

**Stage independence (round-8 review fix).** Earlier drafts labeled
the section "stage 6+" because that's when `mo-review` typically
runs. But `overseer-review.md` exists from stage 5 onward (the
overseer can write findings during stage-5 review even before
`/mo-continue` canonicalizes them — see `docs/workflow-spec.md:716`),
and per Principle §2.6 inclusion is driven by file existence, not by
stage. The section heading and §12 fixtures now reflect that:
emit whenever `overseer-review.md` has meaningful content, regardless
of stage.

### 5.17 What the next agent should do

A short, action-oriented paragraph computed from the current stage:

| Stage | Body |
| --- | --- |
| 2–3 (blueprint / implementation) | "Review the requirements above and continue implementing the listed scope. Surface clarifying questions before writing code." |
| 4–5 (post-impl, pre-review) | "Review the implementation against the requirements. Note discrepancies under 'Open review findings' format." |
| 6 (review session) | "Address the open review findings in priority order (blockers first). For each, propose the smallest change that resolves the finding without expanding scope." |
| 7–8 (review-completed / finalizing) | "The cycle is wrapping up. Validate that every open finding is closed and the changed areas match the requirements." |

If the stage is anything else, a generic line: "Continue this work in
whatever direction the human guides you."

This section is templated text, not synthesis — picking the right row
from a stage-keyed table is deterministic.

### 5.18 Sources (always emitted, last; review fix: neutral wording, phase label)

A small footer block, intentionally short and free of plugin
vocabulary:

```markdown
---

> _This brief was extracted from project planning and review records
> for feature **<feature-slug>** **<phase-label>** on
> **<timestamp>**. The originals (not included): planning records,
> codebase-context audit, change index, manual verification plan
> and results, and any open review findings. The brief above is an
> extract; the originals remain authoritative._
```

**Phase label (round-8 review fix).** Earlier drafts emitted "at
stage **<N>**", but stage numbers (3, 6, etc.) are workflow-internal
and meaningless to a receiver who doesn't know the mo-workflow
state machine. The bundler now derives a receiver-friendly phase
label from `current-stage`:

| Stage | Phase label |
| --- | --- |
| 2 | during planning |
| 3 | during implementation |
| 4 or 5 | post-implementation, before review |
| 6 | during review |
| 7 or 8 | review complete, finalizing |

Anything else (unexpected stages or null) falls back to "in progress".
The label replaces the numeric stage entirely in the footer; the
filename keeps `stage<N>` because filenames are local-disk
bookkeeping, not bundle content the receiver reads.

Strings explicitly NOT permitted in the footer: `mo-workflow`,
`millwright`, `overseer`, file paths beginning with `workflow-stream/`
or `quest/`, and the literal substring `stage ` followed by a digit
(the round-8 phase-label fix has to leave the footer numeric-free).
The §13 acceptance grep enforces this.

## 6. Stage detection and worktree anchoring (review fixes: ordering + worktree pinning)

Four checks run in this order. Each subsequent check assumes the
previous succeeded:

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"

# 1. Active cycle?
"$CLAUDE_PLUGIN_ROOT/scripts/quest.sh" current >/dev/null || {
  echo "Refused: no active cycle. Run /mo-init and /mo-run first." >&2
  exit 2
}

# 2. Active feature?
feature="$("$CLAUDE_PLUGIN_ROOT/scripts/progress.sh" get-active)"
if [[ -z "$feature" || "$feature" == "null" ]]; then
  echo "Refused: no active feature. Advance to stage 2 first (run /mo-continue or /mo-apply-impact)." >&2
  exit 2
fi

# 3. Active worktree fingerprint matches?
"$CLAUDE_PLUGIN_ROOT/scripts/progress.sh" check-worktree || {
  echo "Refused: invoked from a different worktree than the one that owns the active feature. Switch to the recorded worktree-path and re-run." >&2
  exit 2
}

# 4. Now safe to read fields that require active to be non-null.
stage="$("$CLAUDE_PLUGIN_ROOT/scripts/progress.sh" get current-stage)"
branch="$("$CLAUDE_PLUGIN_ROOT/scripts/progress.sh" get branch)"
base_commit="$("$CLAUDE_PLUGIN_ROOT/scripts/progress.sh" get base-commit)"
worktree_path="$("$CLAUDE_PLUGIN_ROOT/scripts/progress.sh" get worktree-path)"
slug_dir="$("$CLAUDE_PLUGIN_ROOT/scripts/quest.sh" dir)"
```

The earlier draft inverted (1) and (2): it tried `progress.sh get`
first, which calls `require_active` and would error before the
`get-active` null check ever ran (see `scripts/progress.sh:459`).

**Worktree pinning (round-7 review fix).** Step 3 invokes the
worktree-fingerprint guard (`mo_assert_worktree_match`, exposed via
`progress.sh check-worktree`; see `docs/workflow-spec.md:1042`). All
subsequent file-system operations — `mkdir -p tmp/bundles`,
`git rev-parse HEAD`, the bundle file write — must run **inside**
the recorded `worktree-path`. The bundler `cd "$worktree_path"`
once, before §8.2 step 3, and stays there for the rest of execution.
Without this anchor, a slash command invoked from a sibling worktree
or from a shifted `cwd` would (a) write the bundle into a wrong
repo's `tmp/bundles/` and (b) compare `change-summary.md` against
the wrong `git rev-parse HEAD`.

Stage is read **for the filename and the action-paragraph lookup
only**. Inclusion of optional sections is driven by file existence,
so the bundle is robust if the filesystem and `progress.md` briefly
disagree.

## 7. Triggers (review fix: be honest about mechanism)

Two invocation paths exist. Only one is contractually supported.

### 7.1 Slash-command trigger (primary, always works)

Overseer types `/mo-export-bundle` directly. Claude Code loads
`commands/mo-export-bundle.md` and runs the documented steps. No
arguments in v1.

This is the supported path. Documentation, error messages, and
acceptance tests assume the slash form.

### 7.2 Natural-language trigger (best-effort, harness-dependent)

The plan does **not** promise that "export the context" or similar
phrasing will reliably invoke the command. Whether it does depends on
the harness's available command-discovery mechanism, which varies
across Claude Code versions and plugin packaging:

- **In the current packaging**, every `commands/mo-*.md` file in this
  plugin is surfaced to the millwright as an entry in the
  available-skills list (`millwright-overseer-development-machine:mo-*`
  prefix). When this surface is present, the millwright can match a
  natural-language request against the command's `description`
  frontmatter and invoke via the `Skill` tool.
- **A separate `SlashCommand` tool** is documented in Claude Code's
  general slash-command docs as the official programmatic-invocation
  mechanism. It is not always present in the harness; when it is, it
  is the more durable path.
- **Fallback**: when neither path is available, the millwright should
  tell the overseer to type `/mo-export-bundle` directly.

Practically this means:

- The command's `description` should still be phrased to overlap with
  natural-language triggers ("export the context", "export the
  bundle", "build a context bundle", "create a prompt for another
  session") so whichever discovery path is active has the best
  chance of matching.
- v1 acceptance criteria do **not** test the natural-language path —
  it is best-effort. Only the slash-command path is asserted.
- Documentation visible to the overseer should mention the slash
  form first, with the natural-language phrasing as "you can also
  ask in plain English; if that doesn't work, use the slash form."

## 8. Implementation

### 8.1 New file: `commands/mo-export-bundle.md`

Frontmatter:

```yaml
---
description: Export a self-contained agent-handoff brief for the active feature. Extracts (does not synthesize) requirements, scope, custom project instructions, project-wide constraints, decisions, codebase-context audit, implementation summary, changed-files index, manual-test results, and open review findings into a single markdown file under tmp/bundles/, with workflow scaffolding stripped and task-neutral section headers. Run when the overseer asks to "export the context", "export the bundle", "build a context bundle", or "create a prompt for another session". The slash form is the supported invocation; natural-language matching is best-effort and harness-dependent.
---
```

Body sections:

1. **Why this command exists.** One paragraph: the brief is for
   sessions that lack workflow context.
2. **Invocation.** `/mo-export-bundle` (no arguments).
3. **Refusals.** Mirror §6.
4. **Execution.** A single shell snippet that calls
   `scripts/bundle.sh export`. The command markdown does not
   re-implement extraction logic; it only resolves preconditions and
   delegates.
5. **Notes.** What the bundle excludes (diagrams, inline diffs, prose
   synthesis), what it extracts (every section in §5), where the
   file lands, and that natural-language triggering is best-effort.

### 8.2 New file: `scripts/bundle.sh`

A single shell script following the pattern of the other
`scripts/*.sh` helpers. One subcommand in v1:

```
bundle.sh export
```

Behavior:

1. Resolve `data_root`, active slug, active feature, current-stage,
   branch, base-commit, **and `worktree-path`** per §6.
2. Refuse per §6 if preconditions fail (no active cycle, no active
   feature, or worktree-fingerprint mismatch).
3. **`cd "$worktree_path"`** before any file-system operation. All
   relative paths and `git` calls below execute inside the active
   worktree.
4. Compute the output path:
   ```bash
   ts="$(date +%Y%m%d-%H%M%S)"
   out="tmp/bundles/${feature}-stage${stage}-${ts}.md"
   mkdir -p tmp/bundles
   if [[ -e "$out" ]]; then
     out="tmp/bundles/${feature}-stage${stage}-${ts}-$$.md"
   fi
   ```
   The `$$` (shell pid) suffix on collision is the round-6
   concurrent-export tiebreaker (§9). Single retry only — second-level
   collisions are ignored as not realistic.
5. Ensure `tmp/bundles/.gitignore` exists with the canonical
   `*\n!.gitignore\n` body (§4.1). Compare-then-write; no-op if
   already correct.
6. Run `git rev-parse HEAD` to capture the live HEAD for §5.14
   staleness comparison. Because step 3 already `cd`'d into the
   recorded worktree, this hits the correct repo unconditionally.
7. Stream the bundle into `$out` section by section per §5. The
   script embeds the parsing/extraction as Python helpers (matching
   the embedded-Python style of `scripts/info-bar.sh`):
   - `strip_frontmatter(text)` — removes a leading `---\n…\n---\n`
     block.
   - `strip_html_comments(text)` — removes `<!-- … -->` spans
     (multi-line).
   - `strip_template_placeholders(text)` — removes lines that are
     entirely template scaffolding. Conservative: only literal
     placeholder strings, not anything that *contains* angle
     brackets.
   - `extract_section(text, heading)` — returns the body under a
     heading until the next equal-level heading.
   - `count_real_bullets(text)` — used by §5.11 emptiness detection.
   - `extract_grounding_items(text)` — implements §5.12's per-item
     emission (verbatim per-item; no aggregation).
   - `extract_change_summary_files(text)` — splits into
     annotated/unannotated groups for §5.14.
   - `compare_change_summary_range(file, active_base, head)` —
     returns `fresh | stale | missing` for §5.14 staleness.
   - `extract_open_findings(text)` — implements §5.16's IR-NNN
     stripping. Per the round-7 fix, the `scope:` field is **kept**
     (emitted as "Recommended action: <scope>"); only `source:`,
     `seed-id:`, and `fix-note:` are dropped. The `IR-NNN` id is
     dropped (the bullet's structural position is enough).
   - `extract_in_scope_items(requirements_md, todo_list_md, active_feature)` —
     implements §5.7's dual-source union. Source (1):
     `requirements.md` frontmatter `todo-item-ids` — read by file
     path, so `active_feature` is implicit (the path already names
     the feature). Source (2): rows in `todo-list.md`'s
     `## <active_feature>` section whose state is `IMPLEMENTING` —
     `active_feature` is needed to scope the section. Union the two
     id sets, source (1) first then source (2), deduplicate by id.
     For each id, look up the current row in `todo-list.md` and drop
     it if its current state is `CANCELED`. Returns an empty list
     when both sources contribute zero non-canceled ids.
   - `scrub_body_paths(text)` — implements §2 Principle 3's targeted
     body-scrubbing pass. Applied to every extracted body section
     **after** chrome stripping but **before** the section is
     written. The substitution table (regex → replacement) is the
     single canonical source for both the bundler and the §12
     acceptance grep:

     ```python
     BODY_SCRUB_TABLE = [
       # Unambiguous workflow path prefixes (no overlap with typical
       # project layouts — these directory names are exclusive to
       # the mo-workflow data tree).
       (r'\bworkflow-stream/[A-Za-z0-9_./-]+',           '<internal path>'),
       (r'\bquest/[A-Za-z0-9_./-]+',                     '<internal path>'),
       (r'\bblueprints/current/[A-Za-z0-9_./-]+',        '<internal path>'),
       (r'\bblueprints/history/v\d+/[A-Za-z0-9_./-]+',   '<internal path>'),
       # Workflow files when referenced under their typical
       # `implementation/` prefix. Tightened from "any .md under
       # implementation/" to the known workflow filenames only — so
       # legitimate project files like `implementation/CartService.ts`
       # or `implementation/MyProjectDoc.md` are NOT scrubbed.
       (r'\bimplementation/(?:grounding-report|change-summary|manual-test-plan|manual-test-results|review-context|overseer-review)\.md\b',
        '<an internal record>'),
       # Bare workflow .md filenames anywhere — catches references
       # without a recognized prefix (e.g., a decision bullet that
       # says "see decisions.md" verbatim).
       (r'\b(?:progress|requirements|config|decisions|summary|todo-list|change-summary|grounding-report|overseer-review|review-context|primer|manual-test-plan|manual-test-results)\.md\b',
        '<an internal record>'),
     ]
     ```

     Order matters: longer/more-specific patterns run first so they
     win against the bare-filename pattern when the filename is part
     of a workflow path. The substitutions are applied with `re.sub`
     in order. Headings and list-marker syntax are preserved (the
     regexes do not span newlines).

     **Patterns deliberately NOT in this table** (round-5 review fix):
     - `\bimplementation/[^/]+\.md\b` (broad). Was previously in the
       table; removed because legitimate project files under
       `implementation/` (any .md the project itself owns) would be
       destructively scrubbed.
     - `\.claude/(?:skills|rules|commands)/...`. Was previously in the
       table; removed because project rules under `.claude/rules/`
       can be legitimate non-workflow content. The `; path:
       .claude/rules/<name>.md` suffix that appears inside
       `config.md → ## Rules` is stripped by §5.5 itself, so removing
       this scrub pattern does not cause the rules section to leak
       paths.

     **Residual edge case (acknowledged, not fixed in v1).** If a
     project's diff legitimately includes a file whose bare name
     matches one of the workflow .md filenames (e.g., the project
     happens to have a top-level `requirements.md` that just got
     edited), the bare-filename pattern will still scrub it. This is
     accepted as a tolerable false positive given how rare those
     collisions are. Documented in §5.14 and §11.
8. After writing, print:
   ```
   Wrote tmp/bundles/<feature>-stage<N>-<timestamp>.md (<size> KB, ~<token-estimate> tokens)
   Tip: open it in your editor, or `cat` it to copy into another session.
   ```
   Token estimate is `bytes / 4` (advisory only).

All extraction helpers are inlined in `bundle.sh`. `internal/common.sh`
gains nothing; no other helper depends on `bundle.sh`.

### 8.3 Wiring

- No changes to existing commands.
- No new schema entries (the bundle is not a canonical artifact).
- No changes to `progress.sh`, `quest.sh`, `frontmatter.sh`, `todo.sh`,
  `commits.sh`, or any other helper.
- No changes to `mo-init` / `mo-doctor` — the new command is additive
  and works the moment its file lands in `commands/`.

### 8.4 Golden-fixture tests (new for v3 — extractive correctness)

Because the implementation contract is now strictly extractive,
correctness is testable. Add fixture-based tests under
`tests/bundle/` (matching the test layout used elsewhere in this
plugin):

- `tests/bundle/fixtures/<scenario>/input/` — a snapshot of
  `workflow-stream/<feature>/` and `quest/<slug>/` for a known
  scenario (stage 3 typical, stage 6 with findings, stage 4 with
  stale change-summary, decisions empty / non-empty, grounding-report
  with multiple items, etc.).
- `tests/bundle/fixtures/<scenario>/expected.md` — the expected
  output the bundler should produce for that input. Diffed
  byte-for-byte after both files are normalized for the timestamp in
  the filename and the stage-banner timestamp.
- `tests/bundle/run.sh` — runs each scenario, asserts equality, and
  runs the §13 grep-test (forbidden words must not appear).

A v2 enhancement (§11) that adds agent composition can introduce a
parallel "approximate match" test mode without invalidating the v1
fixtures.

## 9. Edge cases

- **Frontmatter and HTML comments.** Stripped from every source file
  before any parsing. The receiving session never sees `id:`,
  `requirements-id:`, `<!-- Generated artifact … -->`, or
  `<!-- mo:sync-marker — … -->` markers.
- **Template scaffolding leaking through.** If a human never populated
  a file (e.g., `requirements.md` body left empty), the corresponding
  section ends up empty after stripping and is omitted (§2 rule 6).
- **Empty `decisions.md`.** Handled by §5.11's bullet count.
- **Stage-banner accuracy.** The current stage is used only for the
  filename and §5.17 lookup. Mismatches between `progress.md` and the
  filesystem cannot break the bundle.
- **Concurrent exports.** Timestamps are second-resolution. If two
  exports collide, append `-<pid>` before writing.
- **Long feature slugs.** Slugs are kebab-case ASCII; the title-casing
  in §5.1 won't break on Unicode.
- **Stale `change-summary.md`.** Used with a visible stale warning
  prepended to §5.14 (resolved per §5.14; this edge-case entry
  exists only to point at §5.14 — there is no second policy here).
- **Missing `grounding-report.md` at stage 4+.** Possible if the
  feature was created via an unusual path. The §5.12 section is simply
  omitted; the rest of the bundle still emits.
- **`config.md → ## Overseer Additions` empty.** §5.2 is omitted.
- **`summary.md → ## Cross-cutting constraints` empty.** §5.3 is
  omitted.

## 10. What the bundle deliberately does NOT include (review fix: aligned with §5.2 and §5.3)

- **`config.md → ## Skills` and `## Load on demand`.** These reference
  plugin sub-agent / skill names — workflow tooling, not project
  constraints. The receiving agent cannot resolve them.
- **`config.md → ## GIT BRANCH`.** Single-line workflow bookkeeping;
  the receiving agent doesn't need to know the branch name.
- **`primer.md`.** Derived in-process artifact for a specific
  consumer; re-deriving for the bundle is cleaner than retransmitting.
- **`summary.md`'s sibling-feature sections.** Other features'
  `## Feature: <name>` sections are out of scope for the receiving
  agent. The active feature's `## Feature: <active_feature>` section
  IS included, via §5.4 ("Feature background"); only siblings are
  dropped.
- **Raw `todo-list.md` rows outside §5.7's scope resolution.**
  `PENDING` rows enter the bundle only when referenced by
  `requirements.md → todo-item-ids`; `IMPLEMENTING` rows enter only
  for the active feature; `CANCELED` and `IMPLEMENTED` rows are not
  emitted as current scope.
- **Diagrams.** See §3.
- **Inline diffs / code excerpts.** See §3 and §11.
- **Workflow file paths and bare workflow .md filenames in body
  text.** Replaced with the placeholders `<internal path>` and
  `<an internal record>` per §2 Principle 3's scrub table (canonical
  list in §8.2). Workflow paths are absent from the Sources footer
  by design (§5.18 forbids them in chrome). Workflow role/tool words
  (`mo-workflow`, `millwright`, `overseer`, `seam`, etc.) are **not**
  scrubbed and may appear in body text — see §11 for the reasoning
  and the v2 follow-up.
- **Raw frontmatter UUIDs / template scaffolding.** §2 rule 3.

The earlier "drop summary.md / drop config.md" framing was rejected
across multiple review rounds because both files carry load-bearing
content that isn't guaranteed to appear elsewhere: cross-cutting
constraints and per-feature journal context in `summary.md`;
Overseer Additions and Rules in `config.md`. §5.2 (Overseer
Additions), §5.3 (cross-cutting), §5.4 (active-feature journal),
and §5.5 (Rules) fix that.

## 11. v1 limitations and possible follow-ups

The "extractive only" contract leaves real gaps that v1 accepts as
known limitations:

- **No semantic synthesis.** Cross-item summarization in
  `grounding-report.md`, narrative prose for `change-summary.md`, and
  any "translate plugin vocabulary into stranger-friendly phrasing"
  are out of scope. v2 candidate: an opt-in `--compose` flag where
  `bundle.sh` writes raw extracts to a JSON intermediate and the
  millwright (in the slash-command's own session) composes the brief
  from that intermediate. Token-cost trade-off is real; would not be
  the default.
- **No code-level review possible.** Without inline diffs the
  receiving agent can verify requirements alignment but not
  implementation details. v2 candidate: a `--with-diffs` mode that
  inlines bounded excerpts using the same ≤ 50/file, ≤ 500 total
  bound that `change-summary.md` already enforces.
- **Hand-curated extras.** A future
  `workflow-stream/<feature>/bundle-extras.md` could let the overseer
  pin extra paths or exclude default sections.
- **Stage-targeted exports.** A flag like `--as-of-stage <N>`.
- **Compression.** A `--compact` mode for very large stage-7+ briefs.
- **Inline diagrams.** Pure additive change.
- **Auto-cleanup.** `tmp/bundles/` could prune entries older than N
  days on each run. Skipped in v1 for predictability.
- **Natural-language trigger reliability.** §7.2 is currently
  best-effort. If a future Claude Code version exposes the
  `SlashCommand` tool consistently, the command markdown can be
  updated to reference it as the durable path.
- **Context-aware path scrubbing.** v1 applies `scrub_body_paths`
  uniformly to every extracted body section (per §2.3 + §5
  universal-body-contract). The known false-positive case is a
  project diff whose bare path collides with a workflow .md filename
  (see §5.14). v2 candidate: scrub-context awareness — the changed-
  files index of `change-summary.md` could be exempted from the
  bare-filename pattern (since project diffs are the legitimate use
  case there), while every other body section keeps the universal
  pass.

## 12. Acceptance criteria

A mid-cycle smoke test exercises the path end-to-end.

### 12.1 Scope of forbidden-string checks (review fix)

The bundle has two distinct kinds of content:

1. **Bundler chrome** — text the bundler authors itself: the top
   prompt block (§5.1), every `##` section header listed in §5, the
   §5.14 staleness warning, the §5.14 "Changed but purpose not
   annotated" sub-header, the §5.17 action paragraph, and the §5.18
   Sources footer.
2. **Extracted body** — bullets, paragraphs, and code-fence content
   that the bundler pulled verbatim from canonical files after
   stripping frontmatter / HTML comments / template scaffolding.

Per Principle §2.5 the bundler does not paraphrase extracted body.
However, per Principle §2.3, it **does** apply the deterministic
path-scrub table from §8.2 (`scrub_body_paths`). So the body
guarantee splits into two pieces:

- **Workflow-relative file paths and bare workflow .md filenames**
  are guaranteed absent from body — they are mechanically replaced
  with placeholders before the body is written. This is testable
  against body too.
- **Workflow role / tool / system words** (`mo-workflow`,
  `millwright`, `overseer`, `seam`, `cycle flavor`, item ids) may
  appear in body. The bundler does not rewrite them.

**Two-level forbidden-string contract:**

- **Chrome slice** — must match zero times for every pattern in the
  full forbidden list below. Chrome is extracted by structure (the
  prompt block at the top, all bundler-emitted `## …` headers as
  listed in §5, the §5.14 sub-headers, the §5.14 staleness warning
  block, the §5.17 action paragraph, and the §5.18 footer block).
- **Body slice** (everything else after frontmatter is stripped from
  the bundle output) — must match zero times for the **path-only
  subset** of the forbidden list (the patterns covered by the
  §8.2 scrub table). Other forbidden patterns are not asserted
  against body.

This resolves the round-3 contradiction (chrome named tokens the
global test forbade) and the round-4 contradiction (body coupling
guarantees were inconsistent across §2, §10, §12).

### 12.2 Fixtures and checks

1. **Stage 3 fixture.** Cycle advanced to stage 3 with:
   - `requirements.md` populated, including `## Goals (this cycle)`,
     `## Planned (future cycles)` (with at least one item),
     `## Non-goals (out of scope)`, and a non-empty `todo-item-ids`
     frontmatter list.
   - `config.md` with non-empty `## Overseer Additions` and at least
     one real entry under `## Rules`.
   - `summary.md` with non-empty `## Cross-cutting constraints` and
     a non-empty `## Feature: <active_feature>` section for the
     active feature.
   - `decisions.md` with at least one real bullet.
   - `implementation/grounding-report.md` populated for one or more
     items.

   Run `/mo-export-bundle`. Verify:
   - File lands at `tmp/bundles/<feature>-stage3-<timestamp>.md`.
   - `tmp/bundles/.gitignore` exists with content `*\n!.gitignore\n`.
   - **Sections present** (in order): Top prompt block, Custom project
     instructions (§5.2), Project-wide constraints (§5.3), Feature
     background (§5.4), Implementation rules to follow (§5.5),
     Objective (if `requirements.md` has body prose, §5.6), Scope in
     this session (§5.7), Requirements and constraints (§5.8),
     Planned for future work (§5.9), Out of scope (§5.10), Decisions
     already made (§5.11), Existing system context (§5.12), What the
     next agent should do (§5.17), Sources (§5.18).
   - **Sections absent**: Implementation summary, Changed areas, Tests
     run, Open review findings.
   - **Chrome-scoped forbidden patterns** — full list (per §12.1;
     each must match 0 times in the chrome slice):
     - `IR-NNN`
     - `IMPLEMENTING|PENDING|CANCELED`
     - `progress\.md|requirements\.md|decisions\.md|grounding-report\.md|config\.md|summary\.md|todo-list\.md|change-summary\.md|overseer-review\.md|review-context\.md|primer\.md|manual-test`
     - `mo-workflow|millwright|overseer`
     - `Active scope`
     - `Cross-cutting constraints` (the workflow heading)
     - `Feature: ` (the workflow per-feature heading prefix; the
       bundle renames this to "Feature background")
     - `Goals \(this cycle\)`
     - `Non-goals \(out of scope\)`
     - `Planned \(future cycles\)`
     - `Implementation Review`
     - `mo:sync-marker`
     - `<!--`
     - `workflow-stream/|^quest/`
   - **Body-scoped forbidden patterns** — path-only subset (per §12.1;
     each must match 0 times in the body slice, validating that
     `scrub_body_paths` ran):
     - `\bworkflow-stream/[A-Za-z0-9_./-]+`
     - `\bquest/[A-Za-z0-9_./-]+`
     - `\bblueprints/current/[A-Za-z0-9_./-]+`
     - `\bblueprints/history/v\d+/[A-Za-z0-9_./-]+`
     - `\bimplementation/(grounding-report|change-summary|manual-test-plan|manual-test-results|review-context|overseer-review)\.md\b`
     - `\b(progress|requirements|config|decisions|summary|todo-list|change-summary|grounding-report|overseer-review|review-context|primer|manual-test-plan|manual-test-results)\.md\b`
   - **Section-content checks** (against extracted body):
     - Scope in this session section is non-empty (catches the
       round-4 stage-2-PENDING regression — at stage 3 items are
       `IMPLEMENTING`, but the test asserts the section is populated
       from `todo-item-ids` regardless of state).
     - In this fixture, each scope bullet ends with `(item <id>)`
       for an id that appears in `requirements.md`'s `todo-item-ids`
       frontmatter.
     - Decisions section contains the recorded bullet, with no
       `## Stage 2 — Blueprint approval` heading and no template
       placeholder lines.
     - Existing system context emits per-item bullets — not aggregated
       across items, not synthesized.
     - Requirements and constraints section is non-empty (i.e., the
       `## Goals (this cycle)` extraction succeeded — this catches
       the round-3 heading-mismatch bug).
     - Planned for future work section is non-empty (catches the same
       bug for the `## Planned (future cycles)` heading).
     - Out of scope section is non-empty (catches the same bug for
       `## Non-goals (out of scope)`).
     - Implementation rules to follow section contains the rule entry
       with the `; path: …` suffix removed.
     - Feature background section is non-empty and contains the
       active feature's `## Feature: <feature>` body verbatim
       (catches a regression where the new §5.4 extraction silently
       skips the section).
     - The Sources footer body says "project planning and review
       records" and is in chrome (so forbidden patterns above apply).
     - At least one body bullet (planted in fixture input by seeding
       e.g. `decisions.md` with a bullet that mentions
       `workflow-stream/<feature>/decisions.md`) becomes
       `<internal path>` in the bundle output, validating that
       `scrub_body_paths` is wired up and not a no-op.
2. **Stage 2 fixture (review fix: PENDING-state scope).** Cycle just
   ran `/mo-apply-impact`; items are still `PENDING`, requirements
   and config and grounding-report are written, but
   `/mo-plan-implementation` has not yet flipped any todo to
   `IMPLEMENTING`. Run `/mo-export-bundle`. Verify:
   - Scope in this session section is **non-empty** — its bullets are
     derived from `requirements.md → todo-item-ids` and exist even
     though no row is in state `IMPLEMENTING`. This is the direct
     regression test for the round-4 stage-2 finding.
   - The `IMPLEMENTING|PENDING|CANCELED` chrome-grep still matches
     zero times (the bundler dropped state labels per §5.7).
   - Sections expected to be absent at stage 2: Implementation summary
     (no `change-summary.md` yet), Changed areas, Tests run, Open
     review findings.
3. **Stage 3+ with mid-cycle scope changes.** Start from a feature
   whose `requirements.md → todo-item-ids` contains at least two ids.
   After stage 3 promotion, use `/mo-update-todo-list` to:
   - cancel one original id (`set-state <id> CANCELED` or
     `cancel <id>`), and
   - add a new active-feature item directly as `IMPLEMENTING` whose
     id does **not** appear in `todo-item-ids`.

   Run `/mo-export-bundle`. Verify:
   - Scope in this session includes the non-canceled `todo-item-ids`
     entries first, preserving frontmatter order.
   - The added `IMPLEMENTING` item appears after those entries,
     preserving its order from `todo-list.md`.
   - The canceled original id does **not** appear in Scope in this
     session.
   - No state labels (`PENDING`, `IMPLEMENTING`, `CANCELED`,
     `IMPLEMENTED`) appear in the emitted scope bullets.
4. **Stage 4 with stale change-summary.** Advance to stage 4, then
   commit something so `git rev-parse HEAD` differs from
   `change-summary.md`'s frontmatter `head`. Run `/mo-export-bundle`.
   Verify:
   - Implementation summary and Changed areas sections appear.
   - The Changed areas section is preceded by the staleness warning
     (`⚠ The change summary below was generated for an earlier commit
     range…`) — and that warning is part of chrome, so it must not trip
     the forbidden-pattern grep.
   - Files with annotated purpose appear with their annotation; files
     without appear under the "Changed but purpose not annotated"
     sub-bullet group with the explicit caveat.
5. **Stage 6 — structured findings only.** Cycle has at least one open
   `### IR-NNN` block in `overseer-review.md` with a non-empty
   `scope:` field, plus at least one open block whose `scope:` is
   omitted. **No** freeform paragraphs. Verify:
   - Open review findings section is present.
   - Findings emitted as plain bullets — `IR-NNN`, `severity:`,
     `source:`, `seed-id:`, `fix-note:` keys do not leak into chrome.
     (`scope:` is **kept** per the round-7 fix; see below.)
   - `## Implementation Review` does not appear.
   - **Recommended action emission (round-7 fix).** Each finding
     bullet ends with " — Recommended action: <text>." For the block
     with a `scope:` value, `<text>` is one of `fix`, `re-implement`,
     `re-plan`, `re-spec` verbatim. For the block without a `scope:`
     value, `<text>` is `not specified`.
   - The §5.17 body matches the stage-6 row of the table.
6. **Stage 6 — freeform-only findings (review fix).** Cycle has **no**
   structured `### IR-NNN` blocks but at least one freeform paragraph
   under `## Implementation Review`. Verify:
   - Open review findings section is **present** (not skipped — this
     catches the round-3 gating bug).
   - Each freeform paragraph appears as a `*(unclassified)*: …` bullet.
7. **Stage 6 — both kinds present.** Open structured findings AND
   freeform paragraphs. Verify both groups appear in the same section.
8. **Stage 6 — completely empty review file.** No structured open
   findings, no freeform paragraphs. Verify the section is omitted
   entirely.
9. **Stage 5 — populated `overseer-review.md` (round-8 review fix:
   stage independence).** Advance the cycle to stage 5 and write
   findings into `overseer-review.md` (mix of one structured
   `### IR-NNN` block with `status: open` and one freeform
   paragraph) **before** running `/mo-continue` to canonicalize.
   `progress.md → active.current-stage` is `5`, not `6`. Run
   `/mo-export-bundle`. Verify:
   - **Open review findings section is present** despite the stage
     being 5. This catches a regression where the section is gated on
     `stage >= 6` rather than on file content (the §5.16 contract is
     stage-independent).
   - The structured block emits its bullet with the round-7
     "Recommended action: <scope>" suffix.
   - The freeform paragraph emits as a `*(unclassified)*: …` bullet.
   - The §5.17 action paragraph matches the **stage-5 row** of the
     §5.17 table (post-impl, pre-review), not the stage-6 row.
   - The §5.18 footer phase label reads
     `post-implementation, before review`, not `during review`.
10. **Refusals.**
    - With no active cycle, the command exits non-zero with the §6
      message and no bundle file is created.
    - With an active cycle but null active feature, the command exits
      non-zero with the §6 message.
    - **Worktree mismatch (round-8 review fix).** From a sibling
      worktree of the same repo (one whose path differs from the
      `worktree-path` field recorded in `progress.md.active`), or
      from any directory that fails the `mo_assert_worktree_match`
      fingerprint, invoke `/mo-export-bundle`. Verify the command
      exits non-zero with the §6 worktree-mismatch refusal message
      and that `tmp/bundles/` in the wrong worktree contains **no
      bundle file** (the refusal must precede any `mkdir -p`). This
      proves the §6 step-3 guard runs early enough to prevent
      cross-worktree bundle pollution.
11. **Gitignore self-containment.** In a project repo where the root
    `.gitignore` does not include `tmp/`, run the command and confirm
    `git status` shows no untracked files inside `tmp/bundles/`. The
    `.gitignore` file itself may show as untracked the first time —
    that is expected.
12. **Golden-fixture tests** (§8.4). The committed fixtures under
    `tests/bundle/fixtures/<scenario>/expected.md` round-trip to
    bytewise equality with the bundler output (after timestamp
    normalization).
13. **Slash-form invocation.** `/mo-export-bundle` works when typed.
    The natural-language path is **not** part of acceptance — see §7.2.

## 13. Mapping of review findings to plan changes

For traceability against the review rounds applied to v3.

### Round-1 findings (resolved in v2 of this plan, retained in v3)

| Finding | Severity | Resolved in |
| --- | --- | --- |
| `grounding-report.md` was omitted | Major | §5.12 ("Existing system context"); §8.1 description; §12.2 check 1. |
| `tmp/bundles/` gitignore guarantee leaked outside this repo | Major | §4.1 (self-ignoring `.gitignore`); §12.2 check 11. |
| Empty-`decisions.md` detection used a nonexistent placeholder | Medium | §5.11 (real-bullet count). |
| Stage-detection ordering would never reach the null-feature refusal | Medium | §6 (cycle → feature → fields). |
| Frontmatter stripper claimed to live in `internal/common.sh` | Low | §8.2 (helpers inlined in `bundle.sh`). |
| Bundle was coupled to plugin/codebase vocabulary | Pivot | §2 principles, §5 task-neutral headers, §10 explicit drops, §12 grep checks. |

### Round-2 findings (resolved in v3 of this plan, retained)

| Finding | Severity | Resolved in |
| --- | --- | --- |
| Deterministic implementation cannot do semantic translation | Major | Design history pivot to v3 ("strict extractive rewriting"); §1, §2 principle 1, §3 first non-goal, §5.6/§5.12/§5.13 downgraded from synthesis to extraction; §8.4 adds golden-fixture tests; §11 lists v2 agent-composition mode as a candidate follow-up. |
| `summary.md` cross-cutting and `config.md` Overseer Additions are load-bearing and were dropped | Major | §5.2 ("Custom project instructions") includes Overseer Additions; §5.3 ("Project-wide constraints") includes cross-cutting; §10 updated to clarify what's still dropped (Skills, Load on demand, GIT BRANCH, sibling-feature sections) and why. |
| Skill / available-skills mechanism is plugin-specific, not Claude Code's official slash-invocation surface | Major | §7.2 rewritten: slash form is contractually supported; natural-language is best-effort and harness-dependent; v1 acceptance does not test the natural-language path; description still phrased to overlap with NL triggers for whichever discovery surface is active. |
| Sources footer violated own grep test by saying "mo-workflow" | Medium | §5.18 reworded to "project planning and review records"; §12.2 check 1 grep list includes `mo-workflow`. |
| `change-summary.md` staleness behavior was contradictory between §5.10 and §9 | Medium | Resolved unilaterally in §5.14 (use with visible warning, comparing frontmatter against `progress.md` + live `git rev-parse HEAD`); §9 edge-case entry now references §5.14 with no competing policy. |
| Changed areas could emit bare paths without role/purpose | Medium | §5.14 splits into annotated / "purpose not annotated" groups, the second carrying an explicit caveat sub-header. |

### Round-3 findings (resolved in this revision of the plan)

| Finding | Severity | Resolved in |
| --- | --- | --- |
| Requirements extraction pointed at the wrong canonical headings (`## Goals` vs `## Goals (this cycle)`) and omitted `## Planned (future cycles)` | Major | §5.8 (corrected to `## Goals (this cycle)`), §5.9 (new "Planned for future work" section pulling from `## Planned (future cycles)`), §5.10 (corrected to `## Non-goals (out of scope)`); §12.2 check 1 adds non-empty assertions for all three sections to catch silent-omission regressions. |
| Acceptance grep tests contradicted body-passthrough policy (e.g., prompt block contained `IR-NNN` while test forbade it; humans may write workflow vocabulary in body text the bundler cannot rewrite) | Major | §12.1 introduces a chrome-vs-body split and scopes forbidden-pattern grep tests to bundler-authored chrome only; §5.1 prompt block reworded to drop concrete forbidden-token examples while still warning about technical phrasing in body. |
| §2 Principle 3 claimed workflow paths are stripped from body text; other sections said body is passed through unchanged — incompatible | Medium | §2 Principle 3 rewritten: chrome (frontmatter, HTML comments, sync markers, template placeholders) is stripped at the boundary; body text is passed through unchanged. The prompt block and the §12.1 chrome-scoped grep tests are aligned with this single contract. |
| `config.md → ## Rules` was dropped wholesale, losing potentially load-bearing project constraints | Medium | §5.5 ("Implementation rules to follow") extracts rule entries with the `; path: .claude/rules/<name>.md` suffix stripped; §10 drop list updated to drop only Skills / Load on demand / GIT BRANCH from `config.md`. |
| Open review findings section was gated only on open `### IR-NNN` blocks; would skip the section if review file held only freeform paragraphs | Medium | §5.16 gating rewritten: section is omitted only when both structured open findings and freeform paragraphs are absent; §12.2 checks 5, 6, 7, 8 cover structured-only / freeform-only / both / empty configurations explicitly. |

### Round-4 findings (resolved in this revision of the plan)

| Finding | Severity | Resolved in |
| --- | --- | --- |
| Stage-2 exports could omit "Scope in this session" because items are still in `PENDING` (the IMPLEMENTING flip happens at stage 3 per `docs/workflow-spec.md:518`) | Major | §5.7 includes `requirements.md → todo-item-ids` as source (1), cross-referenced with `todo-list.md` for descriptions. State-independent for stage 2. §12.2 check 2 is a dedicated stage-2 fixture asserting the section is non-empty when items are PENDING. |
| Workflow-coupling guarantee was inconsistent across §2 (passthrough), §10 (paths stripped), and §12 (body exempt) — bundle could leak workflow paths/file names and still pass acceptance | Major | §2 Principle 3 rewritten to specify a deterministic path-scrub pass (the only mechanical body-side substitution); §8.2 adds `scrub_body_paths` with a closed regex/replacement table; §10 narrowed to match exactly what `scrub_body_paths` does; §12.1 introduces a two-level forbidden-string contract — full list against chrome, path-only subset against body — so leaked workflow paths or .md filenames in body fail acceptance. Role/tool words (`mo-workflow`, `millwright`, `overseer`, `seam`) remain unscrubbed by design and are documented honestly in the prompt block (§5.1). §12.2 check 1 adds a body-scrubbing positive-control assertion. |

### Round-5 findings (resolved in this revision of the plan)

| Finding | Severity | Resolved in |
| --- | --- | --- |
| `todo-item-ids` does not retroactively grow for mid-cycle scope expansions; `/mo-update-blueprint` preserves the previous IDs (per `docs/blueprint-regeneration.md:169` and `commands/mo-update-blueprint.md:345`), so a later `/mo-update-todo-list add … IMPLEMENTING` item could still be omitted from "Scope in this session" | Major | §5.7 reworked to a **dual-source contract**: union of (1) `requirements.md → todo-item-ids` and (2) active-feature rows in state `IMPLEMENTING` from `todo-list.md`, deduplicated by id. This combines stage-2 PENDING coverage (round-4 fix) with mid-cycle-additions coverage. §8.2's `extract_in_scope_items` signature and behavior updated to match. |
| Body-scrub contract was internally inconsistent: §8.2 says `scrub_body_paths` runs on every extracted body section, but §5.2 said Overseer Additions body is "passed through unchanged" and §2.5 said body is passed through "as-is after stripping" | Medium | §2 Principle 5 reworded to "passed through unchanged **except for chrome stripping and `scrub_body_paths`**"; §5.2 reworded to clarify body is "passed through subject only to the two universal passes from Principle §2.3"; new §5 opener establishes a single "universal body contract" that downstream sections inherit, so future passthrough/verbatim claims do not need per-section caveats. |
| `scrub_body_paths` could destructively scrub legitimate project paths: the prior table included broad `implementation/<file>.md` (would scrub project-authored .md files under `implementation/`) and `.claude/(skills\|rules\|commands)/...` (would scrub project-authored rules) | Medium | §8.2 scrub table tightened: dropped the broad `implementation/` and `.claude/...` patterns; replaced with a workflow-known-files-only `implementation/(grounding-report\|change-summary\|manual-test-plan\|manual-test-results\|review-context\|overseer-review)\.md` pattern. Bare-filename pattern (which already catches workflow .md files regardless of prefix) covers the rest. The change is documented inline in §8.2 with the rationale for each removed pattern. §5.14 (Changed areas) explicitly notes the new behavior — project paths under `src/`, `lib/`, `migrations/`, etc. pass through verbatim — and acknowledges two residual edge cases (rare workflow-name collisions in projects, and the bundler running in this plugin's own repo). §11 lists "context-aware scrubbing" as a v2 follow-up if perfectly faithful changed-files paths ever become a hard requirement. |

### Round-6 — round-5 follow-on tightenings (applied alongside the round-5 fixes)

These two entries surfaced while re-reading the plan immediately after
applying the round-5 review fixes. They were not a separate external
review pass; they are tightenings the round-5 work made possible.
Listed here for accuracy of the audit history.

| Finding | Severity | Resolved in |
| --- | --- | --- |
| Initial `todo-item-ids` can later be flipped to `CANCELED`, so source (1) could leak removed work back into "Scope in this session" | Major | §5.7 now resolves every candidate id against the current `todo-list.md` row and omits ids whose current state is `CANCELED`. §8.2's `extract_in_scope_items` helper contract includes the same cancellation filter. §12.2 check 3 asserts a canceled original id is absent from the emitted scope. |
| Scrub contract still disagreed after round 5: §2 and §12 retained broad `implementation/*.md` / `.claude/...` language while §8.2 had tightened the actual table | Major | §2 Principle 3 now explicitly defers to the exact `BODY_SCRUB_TABLE` in §8.2 and summarizes only the tightened patterns. §12.2 body-scoped forbidden patterns now match the tightened table: no broad `implementation/*.md`, no `.claude/...` pattern. |

### Round-7 findings (self-review + external review, resolved in this revision)

A meta-review of the plan after round-6 surfaced six issues; an
external re-review on top of that surfaced three more. All nine were
addressed together.

| Finding | Severity | Resolved in |
| --- | --- | --- |
| `## Constraints` / `## Acceptance criteria` extraction is fictional — the workflow does not generate those headings (per `docs/blueprint-regeneration.md:139` constraints/acceptance live as per-goal notes inside Goals bullets, not as separate top-level sections) | Major | §5.8 rewritten to extract only `## Goals (this cycle)` and to explicitly call out why constraints/acceptance criteria are not separate sections. The `Constraints:` / `Acceptance:` prefixed sub-bullets the prior draft promised would never have appeared. |
| `git rev-parse HEAD` and `tmp/bundles/` were not anchored to the active worktree — invocation from a sibling worktree or shifted cwd would write to the wrong repo and stale-check the wrong HEAD | Major | §6 adds a fourth pre-flight step that calls `progress.sh check-worktree` (the worktree-fingerprint guard, `docs/workflow-spec.md:1042`); §8.2 step 3 `cd "$worktree_path"` before any file-system or `git` operation. All relative paths and `git` calls run inside the recorded worktree. |
| Bundle drops active-feature journal context — `summary.md → ## Feature: <active_feature>` carries feature rationale, dependencies, and acceptance hints that primers and review-context already treat as active context (`templates/primer.md.tmpl:29`, `docs/workflow-spec.md:646`); excluding it strands the receiving agent without that distillation | Major | New §5.4 "Feature background" extracts `summary.md → ## Feature: <active_feature>` verbatim. §5.3 (Project-wide constraints) keeps the `## Cross-cutting constraints` slice as before. §10 (drops list) updated: `summary.md`'s sibling-feature sections remain dropped, but the active-feature section now crosses into the bundle. §12.2 fixture-1 acceptance lists Feature background among the present sections. |
| Open review findings discarded `scope:`, even though `templates/overseer-review.md.tmpl:25-44` defines `fix \| re-implement \| re-plan \| re-spec` as the canonical "how to act" hint — a standalone agent loses the recommended-action signal | Medium | §5.16 updated to keep `scope:` and emit it as "Recommended action: <scope>" appended to each finding bullet. The four scope values are passed through verbatim and explained inline in §5.16 so the receiver can read the escalation ladder without workflow context. §8.2's `extract_open_findings` docstring updated. Missing `scope:` becomes "Recommended action: not specified." |
| Round-6 entries were self-introduced cleanup, not a separate external review pass; listing them as "round 6" misrepresented the audit history | Medium | §13 round-6 heading now explicitly labels the entries as round-5 follow-on tightenings. The table contents are unchanged; only the framing was clarified. |
| §5.1 title-casing the slug (`auth-jwt → "Auth Jwt"`) produced poor results for acronym-heavy slugs (`oauth-pkce`, `api-rate-limiter`) | Medium | §5.1 now uses the slug verbatim in the heading (`# auth-jwt — agent handoff brief`). Honest, matches the Sources footer, and avoids guessing capitalization deterministically. |
| §5.7 closing claim "stage-independent" was technically correct but misleading after the round-6 CANCELED filter was added — the section is also state-filtered now | Medium | §5.7 closing reworded: "stage-independent (works at any stage from 2 onward) and mid-cycle-resilient (survives todo additions and cancellations)" with an explicit note that cancellation is the deliberate state-filter exception. |
| Concurrent-export pid suffix logic was specified in §9 edge-cases but missing from §8.2's enumerated behavior — an implementer would not add it | Medium | §8.2 step 4 explicitly checks `[[ -e "$out" ]]` and appends `$$` (pid) on collision. Single retry only. §9 edge-case entry now references §8.2 step 4. |
| Cleanup nits: §10 had a parenthetical bullet `(`config.md → ## Rules` is now extracted)` that read awkwardly; §8.2's `extract_in_scope_items` description didn't make clear that `active_feature` is only used for source (2); design-history wording undersold the number of review iterations | Low | §10 parenthetical bullet removed (the round-2 fold history is captured in §13 round-2 row). §8.2 docstring expanded. Design-history opener now says "three conceptual revisions … plus multiple rounds of review feedback within v3." |
| Acceptance did not prove the dual-source scope behavior | Medium | §12.2 check 3 adds a mid-cycle fixture with one canceled original id and one newly added `IMPLEMENTING` id absent from `todo-item-ids`; it asserts order, inclusion, cancellation filtering, and state-label stripping. |

### Round-8 findings (resolved in this revision of the plan)

| Finding | Severity | Resolved in |
| --- | --- | --- |
| The doc opener and §1 promised "no plugin / no codebase / no mo-workflow knowledge" but body text deliberately retained workflow vocabulary (`mo-workflow`, `millwright`, `overseer`, `IR-NNN`, `cycle flavor`, `seam`), and acceptance did not test those in body — overclaiming the guarantee | Major | Doc opener and §1 reworded to "self-sufficient for context, not free of workflow-internal vocabulary"; the §1 paragraph now lists the role/tool/domain words that may appear in body and points the receiver at the §5.1 prompt block for guidance. The acceptance contract was not weakened (chrome cleanliness is still asserted; body remains exempt from role/tool word checks per §12.1). |
| §5.18 Sources footer exposed `at stage **<N>**` — internal stage numbers are not meaningful outside the workflow | Medium | §5.18 reworded to use a receiver-friendly phase label (`during planning` / `during implementation` / `post-implementation, before review` / `during review` / `review complete, finalizing`) derived from `current-stage`. The numeric `stage<N>` remains in the filename only, which is local-disk bookkeeping, not bundle content. Footer-forbidden strings now include `stage \d+` to assert the numeric stage never reaches the footer. |
| Open review findings emitted "Recommended action: <scope>" without explaining what the scope values mean — the receiving agent could not act on the recommendation without external context | Medium | §5.16 step 5 adds an in-bundle "Action labels" legend, emitted as a small bundler-authored block at the end of the section when at least one structured finding carried a real `scope:` value. Plain-English glosses for `fix` / `re-implement` / `re-plan` / `re-spec`. Suppressed for freeform-only sections. The legend is chrome (bundler-authored), not extracted source; §12.1 chrome contract covers it implicitly. |
| §5.16 was labeled "stage 6+" even though `overseer-review.md` can have meaningful content at stage 5 (overseer types findings before `/mo-continue` canonicalizes); per Principle §2.6 inclusion is file-content-driven, not stage-driven | Medium | §5.16 heading reworded to drop the stage gate ("stage-independent — emitted whenever `overseer-review.md` has content"); §5.16's closing paragraph explains stage independence with `docs/workflow-spec.md:716` reference. §12.2 check 9 added: a stage-5 fixture with mixed structured + freeform content, asserting the section is emitted, the §5.17 action paragraph picks the stage-4-or-5 row, and the §5.18 phase label is `post-implementation, before review`. |
| §6 introduced the worktree-fingerprint guard as a refusal but §12 acceptance only covered no-active-cycle and null-active-feature refusals — the guard could regress without being caught | Medium | §12.2 check 10 (formerly the Refusals fixture) gains a third sub-case: invocation from a sibling worktree of the same repo or any path that fails `mo_assert_worktree_match`. Asserts non-zero exit, the §6 worktree-mismatch refusal message, and that no bundle file is created in `tmp/bundles/` (the refusal must precede `mkdir -p`). Existing §13 round-1 reference to "§12.2 check 10" for gitignore self-containment renumbered to check 11. |
