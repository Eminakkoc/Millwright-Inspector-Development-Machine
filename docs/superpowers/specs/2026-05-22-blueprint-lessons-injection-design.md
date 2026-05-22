# Blueprint-lessons injection at stage 2 — design

**Status:** approved (brainstorming → ready for implementation plan)
**Date:** 2026-05-22
**Scope:** stage 2 (`mi-apply-impact`) only. Mid-cycle refresh in `/mi-update-blueprint` is a follow-up.

## 1. Problem

`lessons-learned.md` records mistakes surfaced by past PR reviews. Today it is
read only at stage 3 and later: `config.md`'s `## Lessons learned` section points
at it, and the planning/implementation chains read it before writing code. The
file does not influence stage 2, so blueprint mistakes the inspector has already
caught in prior cycles can recur in fresh blueprints — and the codex blueprint
review at stage 2 cannot flag them either.

This design adds a single, deterministic injection point at stage 2 so the
producer (main + `codebase-grounder`) and the reviewer (codex via
`/mi-blueprint-review`) both see blueprint-relevant prior lessons before they
work.

## 2. Goals (this cycle)

1. Add a `lessons-filter` sub-agent that runs as the first step of
   `mi-apply-impact`, judges each `## L-NNN` block in `lessons-learned.md` for
   blueprint-creation relevance, and writes a small disk artifact
   `workflow-stream/<feature>/implementation/blueprint-lessons.md`.

2. Inject the filtered lessons into two stage-2 producer surfaces:
   - main itself, while composing `requirements.md` Goals / Planned / Non-goals.
   - the `codebase-grounder` sub-agent's spawn prompt.

3. Inject the filtered lessons into the codex blueprint review at stage 2 — both
   the `blueprint-consistency-reviewer` (Phases 1 and 4) and the
   `blueprint-item-reviewer` (Phase 3) prompts.

4. Honor existing graceful-degradation patterns: a missing `lessons-learned.md`,
   a filter that returns `blocked`, or zero selected lessons must not block
   stage 2.

## 3. Non-goals (out of scope)

- The `blueprint-diagrammer` sub-agent — diagrams do not receive lessons.
- Mid-cycle blueprint regeneration in `/mi-update-blueprint` — a parallel filter
  call there is a follow-up, not part of this spec.
- Any change to how `pr-review-fixer` writes new lessons (no schema changes to
  `lessons-learned.md`; no category/tag field added).
- Backfilling or rewriting existing `lessons-learned.md` content.
- Filtering or injection at stages other than 2.

## 4. Architecture

```
mi-apply-impact (stage 2)
  ├─ Step Pre-A:
  │     [GUARD] if <data_root>/lessons-learned.md does not exist, skip the whole step.
  │     main initializes workflow-stream/<feature>/implementation/blueprint-lessons.md
  │       with frontmatter.sh init blueprint-lessons (selected-count=0, requirements-id=null,
  │       lessons-source-mtime set by main from stat)
  │     spawns lessons-filter sub-agent
  │       reads:  <data_root>/lessons-learned.md
  │               quest/<active-slug>/summary.md (active feature + cross-cutting)
  │       writes: body of blueprint-lessons.md + updates selected-count via frontmatter.sh set
  │       (main owns id, feature, requirements-id, lessons-source-mtime)
  │
  ├─ Step A: main composes requirements.md
  │     reads:  blueprint-lessons.md (when present, selected-count > 0)
  │     spawns: codebase-grounder
  │             prompt includes a `## Lessons to honor` block pointing at
  │             blueprint-lessons.md
  │     writes: requirements.md
  │             then frontmatter.sh set blueprint-lessons.md requirements-id <id>
  │
  ├─ Step B: main writes config.md (unchanged by this spec)
  │
  ├─ Step B.5: /mi-blueprint-review codex 3 5 ...
  │     orchestrator computes lessons_block string via sibling-detection
  │       (../../implementation/blueprint-lessons.md, selected-count > 0)
  │     orchestrator passes lessons_block as a new spawn input to:
  │       - blueprint-consistency-reviewer (Phases 1 + 4)
  │       - blueprint-item-reviewer (Phase 3)
  │     each reviewer sub-agent substitutes {{LESSONS_BLOCK}} when rendering
  │       its own template (renders happen inside the sub-agents, not in main)
  │
  └─ Step C: blueprint-diagrammer (unchanged — no lessons injection)
```

One filter call → one disk artifact → three consumers (main, codebase-grounder,
codex). The artifact rotates into `history/v[N+1]/implementation/` at stage 8
alongside `grounding-report.md`.

## 5. The `lessons-filter` sub-agent

**New file:** `agents/lessons-filter.md`.

**Frontmatter:**

```yaml
---
name: lessons-filter
description: Blueprint-lessons filter sub-agent. Spawned by mi-apply-impact at stage 2. Reads lessons-learned.md, picks entries relevant to blueprint creation for the active feature, and writes implementation/blueprint-lessons.md.
model: haiku
effort: medium
tools: [Read, Edit, Bash]
---
```

`haiku` is sufficient — this is a single-pass classification task with a small
input (lessons file + one feature section of summary.md) and a structured
output. `effort: medium` keeps the per-lesson judgments tight without burning
budget. Tools are `Read` (for sources), `Edit` (for the body of the
pre-initialized artifact), and `Bash` (for `scripts/frontmatter.sh set` to
update `selected-count` only — `lessons-source-mtime` is owned by main, see
§5.1).

### 5.1 Main pre-initializes the artifact (guarded on lessons-learned.md presence)

Following the `grounding-report.md` pattern in `docs/blueprint-regeneration.md`
Step A: main creates `blueprint-lessons.md` with valid frontmatter before
spawning the sub-agent, so the file is writable by Edit and the PostToolUse
hook is satisfied on every intermediate save.

The init is **guarded on the source file existing**. `scripts/lessons.sh path`
returns a path unconditionally — it does not check existence — so the guard
must live at the call site:

```bash
impl_dir="$data_root/workflow-stream/$active_feature/implementation"
blueprint_lessons_path="$impl_dir/blueprint-lessons.md"
lessons_path="$($CLAUDE_PLUGIN_ROOT/scripts/lessons.sh path)"

if [[ ! -f "$lessons_path" ]]; then
  # No lessons-learned.md yet — skip the artifact and the sub-agent entirely.
  # Consumers (main Step A, codebase-grounder, /mi-blueprint-review) check
  # for the file's existence and degrade gracefully (§8).
  echo "info: lessons-learned.md not present; skipping blueprint-lessons injection"
else
  mkdir -p "$impl_dir"
  lessons_mtime="$(stat -f %m "$lessons_path" 2>/dev/null \
                   || stat -c %Y "$lessons_path" 2>/dev/null \
                   || echo 0)"
  $CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init blueprint-lessons \
    "$blueprint_lessons_path" \
    "FEATURE=$active_feature" \
    "LESSONS_SOURCE_MTIME=$lessons_mtime" \
    "SELECTED_COUNT=0"
  # Spawn the sub-agent (§5.2) only on this branch.
fi
```

`requirements-id` is initialized to `null` by the template; main backfills it
after writing `requirements.md` (see §7.1). `selected-count=0` is a placeholder
the sub-agent overwrites via `frontmatter.sh set`. `lessons-source-mtime` is
set by main at init time and **never updated by the sub-agent** — main is the
sole owner of that field (Finding 4 fix).

### 5.2 Spawn prompt template

Composed by `mi-apply-impact`; placeholders in `<angle brackets>`.

```
You are a fresh sub-agent invoked from mi-apply-impact's Pre-Step A. Your job
is to filter <data_root>/lessons-learned.md to the lessons that should
influence the blueprint for the "<active_feature>" feature in this cycle.

Main has already created <blueprint_lessons_path> with valid frontmatter
(id, feature, requirements-id=null, lessons-source-mtime, selected-count=0).
Your job is to fill the body and update exactly ONE frontmatter field —
`selected-count`. You do NOT create the file from scratch and you do NOT
touch any other frontmatter field.

Required reads:

1. <lessons_path> — every ## L-NNN block in lessons-learned.md.
2. <quest_dir>/summary.md — read `## Cross-cutting constraints` and
   `## Feature: <active_feature>` ONLY. Do not read other features' sections.

For each ## L-NNN block, judge blueprint-creation relevance:

  Blueprint-relevant means the lesson should influence WHAT goes into
  requirements.md (Goals / Planned / Non-goals wording, scope discipline,
  acceptance-criteria altitude, seam-naming, scope-tier picks, items added
  or dropped) OR how codebase-grounder classifies seams / picks
  pre-existing components.

  NOT blueprint-relevant: code-level rules, framework quirks, runtime
  behavior, library-specific traps — those apply at stage 3 (planning /
  implementation chain) and are already covered via config.md's
  ## Lessons learned pointer.

For every lesson you select, write a one-line `relevance:` reason that ties
it to a concrete concern in this cycle (a Goals item id, a cross-cutting
constraint, or a feature concern from summary.md). If you cannot articulate
a tie-back in one line, drop the lesson — non-tied lessons add noise.

Write the body of <blueprint_lessons_path> using Edit, replacing the
template body placeholder. Body format:

  # Blueprint-relevant lessons

  Filtered from `lessons-learned.md` for the "<active_feature>" feature at
  stage 2.

  ## Selected lessons

  ### L-NNN — <title from source>
  - source: <copied verbatim from the source block>
  - relevance: <one line tying this lesson to this cycle's blueprint>
  - lesson: |
      <verbatim copy of the source `lesson:` body>

  (repeat per selected L-ID; when zero are selected, keep the
  ## Selected lessons heading with an empty body)

Then update the single frontmatter field you own — `selected-count`:

  scripts/frontmatter.sh set <blueprint_lessons_path> selected-count <N>

Do NOT touch `lessons-source-mtime`, `feature`, `requirements-id`, or `id` —
main owns those. `lessons-source-mtime` reflects the source-file mtime at
spawn time and stays that way for the lifetime of this artifact.

Finally validate:

  scripts/frontmatter.sh validate <blueprint_lessons_path> blueprint-lessons

Return shape (sub-agent return contract, ≤ 1k tokens):
  Result: success | partial | blocked
  Artifacts changed:
  - <blueprint_lessons_path>: selected N of M lessons
  Findings / risks:
  - <optional bullet>
  Main should read:
  - <blueprint_lessons_path>: read ## Selected lessons before Step A
```

The sub-agent is **read-only on `lessons-learned.md`**: it never appends, edits,
or rotates source lessons. It only edits the body of the filtered artifact and
updates `selected-count` via `frontmatter.sh set`.

## 6. The `blueprint-lessons.md` artifact

**Location:** `<data_root>/workflow-stream/<feature>/implementation/blueprint-lessons.md`

Lives in `implementation/` (not `blueprints/current/`) for two reasons: it
matches `grounding-report.md`'s pattern (informational input to blueprint
generation that lives implementation-side), and it rotates into
`history/v[N+1]/implementation/` at stage 8 alongside the grounding report —
giving a permanent audit trail of which lessons each blueprint version was
informed by.

**Frontmatter schema** — new file `schemas/blueprint-lessons.schema.yaml`:

```yaml
$schema: "http://json-schema.org/draft-07/schema#"
$id: millwright-inspector-development-machine/blueprint-lessons.schema.yaml
title: blueprint-lessons.md frontmatter
description: >-
  Frontmatter for workflow-stream/<feature>/implementation/blueprint-lessons.md,
  written by the lessons-filter sub-agent at stage 2.
type: object
additionalProperties: false
required:
  - id
  - feature
  - requirements-id
  - lessons-source-mtime
  - selected-count
properties:
  id:
    type: string
    pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"
    description: UUID v4 for this filter run.
  feature:
    type: string
    pattern: "^[a-z0-9][a-z0-9-]*$"
    description: Kebab-case active feature name; matches progress.md active.feature.
  requirements-id:
    oneOf:
      - type: "null"
      - type: string
        pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"
    description: Back-reference to requirements.md; null at first write, backfilled by main after Step A.
  lessons-source-mtime:
    type: integer
    minimum: 0
    description: Epoch seconds of lessons-learned.md at read time. Lets a future cache check spot a stale artifact.
  selected-count:
    type: integer
    minimum: 0
    description: Number of L-IDs picked. 0 is valid (the artifact exists but injects no content).
```

**Frontmatter init template** — `templates/blueprint-lessons.md.tmpl`. No
`scripts/frontmatter.sh` change is required: the script loads
`templates/${tmpl_name}.md.tmpl` directly and auto-validates against
`schemas/${tmpl_name}.schema.yaml` if a matching schema exists
(`scripts/frontmatter.sh:20-35`). Creating the template file and the schema
file under matching names is sufficient. Mirrors the existing
`grounding-report` flow:

```markdown
---
id: {{UUID}}
feature: {{FEATURE}}
requirements-id: null
lessons-source-mtime: {{LESSONS_SOURCE_MTIME}}
selected-count: {{SELECTED_COUNT}}
---

# Blueprint-relevant lessons

Filtered from `lessons-learned.md` for the "{{FEATURE}}" feature at stage 2.
Read by main while composing `requirements.md`; injected into
`codebase-grounder`, `blueprint-consistency-reviewer`, and
`blueprint-item-reviewer` prompts.

## Selected lessons

<!-- filled by the lessons-filter sub-agent; empty when selected-count=0 -->
```

**Body format:**

```markdown
# Blueprint-relevant lessons

Filtered from `lessons-learned.md` for the "<feature>" feature at stage 2.

## Selected lessons

### L-007 — Goals items must name the existing seam
- source: <pr-url> · PR-014
- relevance: applies to PAY-001 (capture webhook) — the Goals item must name `services/` rather than describe behavior in the abstract.
- lesson: |
    Goals items that don't name an existing seam consistently lead to
    chain-time architecture rework. Always anchor each Goals item to a
    concrete folder/module identified by the codebase-grounding pass.
```

When `selected-count: 0`, the `## Selected lessons` heading is kept but the body
is empty. Consumers detect zero-selection by checking either the frontmatter
field or the empty section body.

## 7. Consumer wiring

### 7.1 Main composing requirements.md (`mi-apply-impact` Step A)

After `lessons-filter` returns and before invoking `codebase-grounder`, main
reads `<blueprint_lessons_path>`. If `selected-count > 0`, the
`## Selected lessons` body sits in main's context for the rest of Step A
(writing Goals / Planned / Non-goals).

After main writes `requirements.md`, it backfills the cross-reference:

```bash
requirements_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get \
  "$dest" id)"
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh set \
  "$blueprint_lessons_path" requirements-id "$requirements_id"
```

This satisfies Rule 2 (documents cross-link via UUIDs).

### 7.2 `codebase-grounder` spawn prompt

Add a new block to the spawn-prompt template in `docs/blueprint-regeneration.md`
Step A, immediately after the existing `**Required first reads:**` list:

```
**Lessons from prior PR reviews (filtered for blueprint relevance):**

The file <blueprint_lessons_path> contains lessons selected from
lessons-learned.md that may apply to this cycle's blueprint. Read its
`## Selected lessons` section before classifying seams or picking
pre-existing components. Each lesson's `relevance:` line ties it to a
specific concern in this cycle.

If <blueprint_lessons_path> does not exist or its `selected-count` is 0,
skip this read — there are no applicable lessons.
```

The grounder's existing per-item read cap (≤ 5 files) is unchanged.
`blueprint-lessons.md` is a small intake artifact and is not counted against
that budget — same treatment as `summary.md`.

### 7.3 Codex review templates (`/mi-blueprint-review`)

The two reviewer sub-agents (`blueprint-consistency-reviewer` and
`blueprint-item-reviewer`) render their own prompt templates from inside the
sub-agent (see `agents/blueprint-consistency-reviewer.md:30` and
`agents/blueprint-item-reviewer.md:35`). The orchestrator does not render the
final reviewer prompt itself — it only passes inputs through the spawn prompt.

Wiring must therefore split across three surfaces:

**(a) Orchestrator computes `lessons_block` once.** In `commands/mi-blueprint-review.md`,
before dispatching Phase 1 / Phase 3 / Phase 4, resolve a single
`lessons_block` string:

```
1. Resolve <file>'s directory. If it ends in `.../blueprints/current` AND a
   sibling `../../implementation/blueprint-lessons.md` exists, read its
   frontmatter `selected-count`.
2. If selected-count > 0, set lessons_block to:

     ## Lessons from prior PR reviews to honor

     Use these as additional review criteria — flag any item in this
     blueprint that contradicts one of these lessons.

     <verbatim ## Selected lessons body from blueprint-lessons.md>

3. Otherwise, set lessons_block to the empty string.
```

Compute once; reuse across all Phase 1 / 3 / 4 spawns in this command run.

**(b) Spawn prompts carry `lessons_block` to each reviewer sub-agent.** Add
`lessons_block` as a new input on both reviewer sub-agents'
`## Inputs (from the spawn prompt)` section:

- `agents/blueprint-consistency-reviewer.md` — add a new bullet:
  > `lessons_block` — opaque markdown string to substitute as
  > `{{LESSONS_BLOCK}}` in the reviewer prompt template. May be empty.

- `agents/blueprint-item-reviewer.md` — same new bullet under both Mode A and
  Mode B input lists.

**(c) Sub-agents substitute `{{LESSONS_BLOCK}}` when rendering.** Add
`{{LESSONS_BLOCK}}` to both reviewer prompt templates under `templates/`:

- `templates/blueprint-reviewer-prompt-consistency.md.tmpl`
- `templates/blueprint-reviewer-prompt-item.md.tmpl`

Update each sub-agent's "Render the reviewer prompt" step (step 3 in
`blueprint-consistency-reviewer.md`, step 2 in `blueprint-item-reviewer.md`)
to substitute `{{LESSONS_BLOCK}}` from the `lessons_block` spawn input,
alongside the existing `{{ITERATION}}` / `{{FILE_CONTENT}}` / `{{EXISTING_FINDINGS}}`
substitutions.

The sibling-detection rule (step (a)) keeps `/mi-blueprint-review`
workflow-neutral: when invoked manually on an arbitrary markdown file, no
sibling exists, `lessons_block` is empty, and the reviewer prompts render
exactly as they do today.

`/mi-blueprint-review-consistency` and `/mi-blueprint-review-item` (the
single-purpose variants invoked manually) get the same treatment: they
compute `lessons_block` via the same sibling-detection rule and pass it
into the sub-agent spawn prompt. When invoked on a file with no sibling
lessons artifact (the common case for manual invocation outside the
workflow), `lessons_block` is empty.

No new positional command parameters on the orchestrator.

## 8. Error handling

All failures are non-blocking — stage 2 must complete even with no lessons
injected, matching the codex-MCP-unavailable graceful-degradation pattern in
the existing Step B.5.

| Failure | Behavior |
| --- | --- |
| `lessons-learned.md` missing | Skip `lessons-filter` entirely. `blueprint-lessons.md` is not written. Consumers detect its absence and skip injection. Stage 2 continues unchanged. |
| `lessons-filter` returns `blocked` | Warn (`"warning: lessons-filter unavailable — skipping blueprint-lessons injection"`), continue without artifact. |
| `lessons-filter` returns `partial` with usable output | Accept the partial artifact; trust the schema-validated content. |
| `blueprint-lessons.md` fails schema validation | PostToolUse hook blocks the turn. Main must surface the error and either rerun the sub-agent or proceed without lessons. Standard mi-workflow invariant. |
| `requirements-id` backfill fails (e.g., file disappeared) | Warn, continue. The missing back-reference is recoverable; the lessons content is already on disk. |
| `mi-apply-impact` re-entered mid-stage-2 (check-current = 2, partial) WITH `blueprint-lessons.md` already present | See §8.1 below for the explicit `--force` cleanup. Without `--force`, the existing artifact is reused as-is and the sub-agent is not re-spawned. |
| `/mi-blueprint-review` invoked manually on a non-blueprint file | Sibling-detection finds no `../../implementation/blueprint-lessons.md`. `LESSONS_BLOCK` renders empty. Existing behavior preserved. |

### 8.1 Explicit `--force` cleanup for `implementation/`

`commands/mi-apply-impact.md:85-89` today clears only
`blueprints/current/*` when `--force` is passed against a partial state. The
`implementation/` directory is left untouched. With this spec, stage-2
artifacts now live in **both** directories:

- `blueprints/current/` — `requirements.md`, `config.md`, `diagrams/`
- `implementation/` — `grounding-report.md`, `blueprint-lessons.md`

If `--force` regenerates only the blueprint side, stale `grounding-report.md`
and/or `blueprint-lessons.md` survive and feed Step A against the freshly
regenerated requirements — a silent inconsistency.

The fix is scoped to **stage-2-generated implementation artifacts only**.
After clearing `blueprints/current/*` on the `--force` path,
`mi-apply-impact` also removes the stage-2 inputs that this command owns
under `implementation/`:

```bash
impl_dir="$data_root/workflow-stream/$active_feature/implementation"
# Stage-2 owns these two artifacts. Other implementation/ entries are owned
# by later stages (inspector-review.md by stage 5, review-context.md /
# change-summary.md / diagrams/ by stage 4/6) — do NOT touch them, even on
# --force: a partial stage-2 re-entry must not destroy mid-cycle stage-5+
# state if the inspector happens to be combining `--force` with a stale
# `implementation/` from a prior aborted run.
for stage2_artifact in grounding-report.md blueprint-lessons.md; do
  [[ -e "$impl_dir/$stage2_artifact" ]] && rm -f "$impl_dir/$stage2_artifact"
done
```

**Note on stage scoping.** Even though check-current=2 typically means the
inspector aborted partway through stage 2 (so stages 5+ artifacts would not
exist yet), the cleanup is intentionally allowlisted rather than wholesale.
A wholesale `rm -rf "$impl_dir"/*` could silently destroy work in pathological
re-entry scenarios (e.g., a workflow that survived a stage-7 failure into a
forced stage-2 redo). Allowlisting keeps the blast radius scoped to what
this command authored.

## 9. Lifecycle

- **Created:** by `lessons-filter` in `mi-apply-impact` Pre-Step A, when
  `lessons-learned.md` exists.
- **Read:** by main in Step A, by `codebase-grounder` in Step A, by
  `/mi-blueprint-review` reviewers in Step B.5.
- **Mutated mid-cycle:** out of scope. `/mi-update-blueprint` does **not**
  refresh `blueprint-lessons.md` in this spec. Adding parallel filter logic to
  `/mi-update-blueprint` is a flagged follow-up.
- **Archived:** rotated into `history/v[N+1]/implementation/blueprint-lessons.md`
  at stage 8 by `mi-complete-workflow`, alongside `grounding-report.md`.
  `mi-complete-workflow.md`'s archive loop is an **explicit allowlist** of
  filenames (`commands/mi-complete-workflow.md:234`); `blueprint-lessons.md`
  must be added to that list. The historical-snapshot prose immediately below
  the loop (`commands/mi-complete-workflow.md:242`) must also be updated to
  mention the new artifact.
- **Cleared:** by `/mi-abort-workflow`, alongside the rest of
  `implementation/`.

## 10. Testing

Integration-style smoke tests in `tests/`. Exact patterns to discover during
plan-writing.

1. **Lessons file absent.** Fresh data root, no `lessons-learned.md`. Run
   `mi-apply-impact`. Assert: no `blueprint-lessons.md` written; stage 2
   completes; codex review prompts contain no lessons block.

2. **Lessons present, zero selected.** Seed `lessons-learned.md` with 2–3
   stage-3-only lessons (code-level rules). Run `mi-apply-impact`. Assert:
   `blueprint-lessons.md` exists with `selected-count: 0` and empty
   `## Selected lessons`; codex review prompts contain no rendered lessons
   block (because selected-count = 0).

3. **Lessons present, ≥ 1 selected.** Seed `lessons-learned.md` with at least
   one blueprint-relevant lesson. Run `mi-apply-impact`. Assert:
   `blueprint-lessons.md` lists that L-ID with a `relevance:` line;
   `requirements-id` is backfilled after Step A; codex review prompts contain
   the rendered `## Lessons from prior PR reviews to honor` block with the
   lesson's verbatim body.

4. **Schema validation.** Hand-write a malformed `blueprint-lessons.md` (missing
   `selected-count`); confirm the PostToolUse hook blocks the write turn.

5. **Stage 8 rotation.** Complete a feature cycle; assert
   `history/v[N+1]/implementation/blueprint-lessons.md` exists and matches the
   pre-rotation file.

6. **Manual `/mi-blueprint-review` on arbitrary file.** Invoke the command on a
   markdown file outside any `blueprints/current/`. Assert: `LESSONS_BLOCK`
   renders empty; no errors.

## 11. Files touched

**New:**

- `agents/lessons-filter.md`
- `schemas/blueprint-lessons.schema.yaml`
- `templates/blueprint-lessons.md.tmpl` (frontmatter init template)
- `tests/...` — new test files per §10.

**Modified:**

- `commands/mi-apply-impact.md`:
  - Add Pre-Step A: guard on `lessons-learned.md` existence, `frontmatter.sh
    init blueprint-lessons`, spawn the `lessons-filter` sub-agent (§5.1).
  - Add the `requirements-id` backfill after Step A writes `requirements.md`
    (§7.1).
  - Extend the `--force` cleanup path to remove stage-2 implementation
    artifacts (§8.1).
- `docs/blueprint-regeneration.md` — Step A: add `blueprint-lessons.md` read
  for main; add the `## Lessons to honor` block to the `codebase-grounder`
  spawn-prompt template (§7.2).
- `commands/mi-blueprint-review.md` — compute `lessons_block` via
  sibling-detection (§7.3 step a) and pass it as a spawn input to every
  reviewer sub-agent in Phase 1 / 3 / 4.
- `commands/mi-blueprint-review-consistency.md`,
  `commands/mi-blueprint-review-item.md` — same sibling-detection +
  spawn-input wiring for the single-purpose variants (§7.3 final paragraph).
- `agents/blueprint-consistency-reviewer.md`,
  `agents/blueprint-item-reviewer.md` — add `lessons_block` to
  `## Inputs (from the spawn prompt)`; update the "Render the reviewer prompt"
  step to substitute `{{LESSONS_BLOCK}}` from that input (§7.3 step c).
- `templates/blueprint-reviewer-prompt-consistency.md.tmpl`,
  `templates/blueprint-reviewer-prompt-item.md.tmpl` — add the
  `{{LESSONS_BLOCK}}` placeholder at the appropriate position (§7.3 step c).
- `commands/mi-complete-workflow.md` — add `blueprint-lessons.md` to the
  archive allowlist at line 234, and update the historical-snapshot prose at
  line 242 to mention the new artifact (§9).
- `docs/millwright-inspector-project.md` — document the new artifact and the
  new sub-agent in the appropriate sections (workflow-stream layout, sub-agent
  list).

**Unchanged:**

- `scripts/frontmatter.sh` — no code change required. The script already
  loads `templates/${tmpl_name}.md.tmpl` by name and auto-validates against
  `schemas/${tmpl_name}.schema.yaml` if a matching schema exists
  (`scripts/frontmatter.sh:20-35`). Adding the new template + schema files
  under matching names is sufficient.
- `scripts/lessons.sh` — no new subcommand; the filter sub-agent reads the file
  via `lessons.sh path` and standard file IO.
- `pr-review-fixer` agent — no changes; `lessons-learned.md` schema unchanged.
- `blueprint-diagrammer` agent — no injection.

## 12. Open questions and follow-ups

- **Mid-cycle regen in `/mi-update-blueprint`** — should it re-filter? Probably
  yes, for the same reason stage 2 does. Tracked as a follow-up; not in this
  spec.
- **Cache reuse across cycles** — `lessons-source-mtime` lets a future
  optimization skip re-filtering when the source file hasn't changed since the
  last cycle on the same feature. Out of scope; the frontmatter field is added
  now so a later optimization doesn't require a schema migration.
