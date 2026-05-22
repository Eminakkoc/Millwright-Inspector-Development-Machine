# Blueprint-lessons injection at stage 2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Filter `lessons-learned.md` for blueprint-creation-relevant lessons at stage 2 and inject them into the producer side (main + `codebase-grounder`) and the codex review side (consistency + per-item reviewers).

**Architecture:** A new `lessons-filter` sub-agent runs once at `mi-apply-impact` Pre-Step A. Main pre-initializes a `workflow-stream/<feature>/implementation/blueprint-lessons.md` artifact (guarded on `lessons-learned.md` existing). Sub-agent fills the body and sets `selected-count`. Main, `codebase-grounder`, and `/mi-blueprint-review` reviewers read the artifact via a sibling-detection rule. The artifact rotates into `history/v[N+1]/implementation/` at stage 8.

**Tech Stack:** Bash, YAML/JSON Schema (draft-07), Markdown templates with `{{PLACEHOLDER}}` substitution, the project's `scripts/frontmatter.sh` / `scripts/uuid.sh` / `scripts/lessons.sh` helpers, the existing PostToolUse frontmatter-validation hook, integration-style smoke tests under `tests/` (bash `run.sh` runners with fixture folders).

**Spec:** `docs/superpowers/specs/2026-05-22-blueprint-lessons-injection-design.md`

---

## File structure

**New files:**

- `schemas/blueprint-lessons.schema.yaml` — frontmatter schema; required `id`, `feature`, `requirements-id` (nullable), `lessons-source-mtime`, `selected-count`.
- `templates/blueprint-lessons.md.tmpl` — init template; `## Selected lessons` body is literally empty.
- `agents/lessons-filter.md` — new sub-agent definition; reads `lessons-learned.md`, `todo-list.md`, `summary.md` (active feature); fills `blueprint-lessons.md`.
- `tests/blueprint-lessons/run.sh` — harness covering schema, template, sibling detection, `--force` cleanup, archive integration.
- `tests/blueprint-lessons/fixtures/*` — fixture trees per scenario.
- `docs/superpowers/plans/2026-05-22-blueprint-lessons-injection-manual-tests.md` — manual scenarios for things requiring a live sub-agent (filter relevance, blocked recovery).

**Modified files:**

- `commands/mi-apply-impact.md` — add Pre-Step A (guard + init + spawn + recovery); add Step A backfill block; extend `--force` cleanup.
- `docs/blueprint-regeneration.md` — Step A: main read of `blueprint-lessons.md` before composing; codebase-grounder spawn prompt block.
- `agents/blueprint-consistency-reviewer.md` — add `lessons_block` to `## Inputs`; substitute `{{LESSONS_BLOCK}}` in step 3.
- `agents/blueprint-item-reviewer.md` — same for both Mode A and Mode B input lists; substitute in step 2.
- `templates/blueprint-reviewer-prompt-consistency.md.tmpl` — add `{{LESSONS_BLOCK}}` placeholder.
- `templates/blueprint-reviewer-prompt-item.md.tmpl` — add `{{LESSONS_BLOCK}}` placeholder.
- `commands/mi-blueprint-review.md` — compute `lessons_block` once via sibling-detection; pass into Phase 1/3/4 spawns.
- `commands/mi-blueprint-review-consistency.md` — same sibling-detection + spawn-input wiring.
- `commands/mi-blueprint-review-item.md` — Mode A sibling-detection; Mode B forces `lessons_block=""`.
- `commands/mi-complete-workflow.md` — add `blueprint-lessons.md` to archive allowlist; update prose.
- `docs/millwright-inspector-project.md` — document the new artifact + sub-agent.

---

## Task ordering rationale

Foundation first (schema + template) so later tasks can validate against real files. Then the sub-agent definition. Then producer wiring. Then codex review wiring. Then archive. Then docs. Tests are written alongside each foundation task and the wiring tasks where they're automatable.

---

### Task 1: Frontmatter schema for blueprint-lessons.md

**Files:**
- Create: `schemas/blueprint-lessons.schema.yaml`
- Create: `tests/blueprint-lessons/run.sh`
- Create: `tests/blueprint-lessons/fixtures/schema-good/blueprint-lessons.md`
- Create: `tests/blueprint-lessons/fixtures/schema-bad-missing-count/blueprint-lessons.md`
- Create: `tests/blueprint-lessons/fixtures/schema-bad-feature/blueprint-lessons.md`

- [ ] **Step 1: Write failing tests**

Create `tests/blueprint-lessons/run.sh`:

```bash
#!/usr/bin/env bash
# run.sh — integration smoke tests for the blueprint-lessons stage-2 injection.
#
# Each test exits 0 on PASS and a unique non-zero on FAIL so partial-suite
# results stay actionable. Tests are additive: later tasks append blocks to
# this file under their own task headings.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="$TESTS_DIR/fixtures"

pass=0
fail=0
fail_names=()

ok()   { printf "\xe2\x9c\x93 %s\n" "$1"; pass=$((pass + 1)); }
ng()   { printf "\xe2\x9c\x97 %s\n   %s\n" "$1" "$2" >&2; fail=$((fail + 1)); fail_names+=("$1"); }

# ---- Task 1: schema -------------------------------------------------------

t="schema: valid frontmatter passes validation"
if "$REPO_ROOT/scripts/frontmatter.sh" validate \
   "$FIXTURES/schema-good/blueprint-lessons.md" blueprint-lessons >/dev/null 2>&1; then
  ok "$t"
else
  ng "$t" "expected validation to pass"
fi

t="schema: missing selected-count rejected"
if "$REPO_ROOT/scripts/frontmatter.sh" validate \
   "$FIXTURES/schema-bad-missing-count/blueprint-lessons.md" blueprint-lessons >/dev/null 2>&1; then
  ng "$t" "expected validation to fail; it passed"
else
  ok "$t"
fi

t="schema: invalid feature pattern rejected"
if "$REPO_ROOT/scripts/frontmatter.sh" validate \
   "$FIXTURES/schema-bad-feature/blueprint-lessons.md" blueprint-lessons >/dev/null 2>&1; then
  ng "$t" "expected validation to fail; it passed"
else
  ok "$t"
fi

# ---- Summary --------------------------------------------------------------

printf "\n%d passed, %d failed\n" "$pass" "$fail"
if (( fail > 0 )); then
  printf "Failed: %s\n" "${fail_names[*]}" >&2
  exit 1
fi
exit 0
```

Make it executable:

```bash
chmod +x tests/blueprint-lessons/run.sh
```

Create the three fixtures:

`tests/blueprint-lessons/fixtures/schema-good/blueprint-lessons.md`:

```markdown
---
id: 12345678-1234-4234-8234-123456789012
feature: payments
requirements-id: null
lessons-source-mtime: 1716336000
selected-count: 0
---

# Blueprint-relevant lessons

## Selected lessons
```

`tests/blueprint-lessons/fixtures/schema-bad-missing-count/blueprint-lessons.md`:

```markdown
---
id: 12345678-1234-4234-8234-123456789012
feature: payments
requirements-id: null
lessons-source-mtime: 1716336000
---

# Blueprint-relevant lessons

## Selected lessons
```

`tests/blueprint-lessons/fixtures/schema-bad-feature/blueprint-lessons.md`:

```markdown
---
id: 12345678-1234-4234-8234-123456789012
feature: Payments
requirements-id: null
lessons-source-mtime: 1716336000
selected-count: 0
---

# Blueprint-relevant lessons

## Selected lessons
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
tests/blueprint-lessons/run.sh
```

Expected: all three tests fail — the schema doesn't exist yet, so `frontmatter.sh validate ... blueprint-lessons` will error out on every fixture. The "missing-count" and "bad-feature" tests *want* a failure, so they will pass for the wrong reason. To make Step 4 a meaningful PASS, expect: `schema: valid frontmatter passes validation` to FAIL right now.

- [ ] **Step 3: Write the schema**

Create `schemas/blueprint-lessons.schema.yaml`:

```yaml
$schema: "http://json-schema.org/draft-07/schema#"
$id: millwright-inspector-development-machine/blueprint-lessons.schema.yaml
title: workflow-stream/<feature>/implementation/blueprint-lessons.md frontmatter
description: >
  Stage-2 filtered-lessons artifact. Written by the `lessons-filter` sub-agent
  spawned from /mi-apply-impact's Pre-Step A. The artifact lists the
  lessons-learned.md entries deemed blueprint-relevant for the active
  feature; consumers (main composing requirements.md, codebase-grounder,
  the codex blueprint reviewers) read it before working.

  Lifecycle matches the rest of `implementation/`: archived at stage 8 to
  blueprints/history/v[N+1]/implementation/blueprint-lessons.md; cleared by
  /mi-abort-workflow with the rest of the live implementation folder.

  UUID pattern accepts any RFC 4122 version (v1-v8) with a valid variant
  nibble, matching the project's permissive policy for workflow schemas.

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
    pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"
    description: UUID for cross-references; minted via scripts/uuid.sh.

  feature:
    type: string
    minLength: 1
    pattern: "^[a-z0-9][a-z0-9-]*$"
    description: >
      Kebab-case feature name; mirrors the workflow-stream/<feature>/ folder
      that contains this artifact's parent implementation/ directory.

  requirements-id:
    oneOf:
      - type: "null"
      - type: string
        pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"
    description: >
      Back-reference to requirements.md's id. Null at first write (the
      artifact is created before requirements.md exists); backfilled by
      main after Step A writes requirements.md.

  lessons-source-mtime:
    type: integer
    minimum: 0
    description: >
      Epoch seconds of lessons-learned.md at filter time. Lets a future
      cache check spot a stale artifact. Owned by main; never updated by
      the lessons-filter sub-agent.

  selected-count:
    type: integer
    minimum: 0
    description: >
      Number of ## L-NNN entries the sub-agent picked. 0 is valid — it
      means a filter attempt happened and yielded no blueprint-relevant
      lessons (or was reset by a blocked/schema-fail recovery). Consumers
      short-circuit on selected-count == 0.

  contributors:
    type: array
    items:
      type: string
    description: Optional list of contributors (sub-agent + main typically).

  date:
    type: string
    format: date
    description: Optional ISO-8601 date the artifact was generated.
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
tests/blueprint-lessons/run.sh
```

Expected: `3 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add schemas/blueprint-lessons.schema.yaml \
        tests/blueprint-lessons/run.sh \
        tests/blueprint-lessons/fixtures/
git commit -m "feat(schemas): add blueprint-lessons frontmatter schema + smoke tests"
```

---

### Task 2: Init template for blueprint-lessons.md

**Files:**
- Create: `templates/blueprint-lessons.md.tmpl`
- Modify: `tests/blueprint-lessons/run.sh` (append a Task-2 block)

- [ ] **Step 1: Write failing test**

Append to `tests/blueprint-lessons/run.sh` (immediately before the `# ---- Summary ----` section):

```bash
# ---- Task 2: template init -----------------------------------------------

t="template: init renders valid frontmatter with required tokens"
init_tmpdir="$(mktemp -d)"
init_dest="$init_tmpdir/blueprint-lessons.md"
if MI_PLUGIN_ROOT="$REPO_ROOT" "$REPO_ROOT/scripts/frontmatter.sh" init blueprint-lessons \
     "$init_dest" \
     "FEATURE=payments" \
     "LESSONS_SOURCE_MTIME=1716336000" \
     "SELECTED_COUNT=0" >/dev/null 2>&1; then
  if MI_PLUGIN_ROOT="$REPO_ROOT" "$REPO_ROOT/scripts/frontmatter.sh" validate \
       "$init_dest" blueprint-lessons >/dev/null 2>&1; then
    ok "$t"
  else
    ng "$t" "init wrote a file that fails schema validation"
  fi
else
  ng "$t" "init command itself failed"
fi
rm -rf "$init_tmpdir"

t="template: ## Selected lessons body is literally empty after init"
init_tmpdir="$(mktemp -d)"
init_dest="$init_tmpdir/blueprint-lessons.md"
MI_PLUGIN_ROOT="$REPO_ROOT" "$REPO_ROOT/scripts/frontmatter.sh" init blueprint-lessons \
  "$init_dest" \
  "FEATURE=payments" \
  "LESSONS_SOURCE_MTIME=1716336000" \
  "SELECTED_COUNT=0" >/dev/null 2>&1
# Extract everything after the `## Selected lessons` heading. Body must be
# whitespace-only.
body="$(awk '/^## Selected lessons$/{flag=1; next} flag' "$init_dest")"
if [[ -z "${body//[[:space:]]/}" ]]; then
  ok "$t"
else
  ng "$t" "expected empty body, found: $body"
fi
rm -rf "$init_tmpdir"
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
tests/blueprint-lessons/run.sh
```

Expected: both new tests fail with `template not found: …/templates/blueprint-lessons.md.tmpl`.

- [ ] **Step 3: Create the template**

Create `templates/blueprint-lessons.md.tmpl`:

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
```

Important: there must be NO blank line, comment, or other content after the
`## Selected lessons` heading. A trailing newline after the heading is fine
(POSIX-style), but no body content. The "empty body" predicate (used by Test
7 of the spec and the codex sibling-detection step) requires this.

- [ ] **Step 4: Run tests to verify they pass**

```bash
tests/blueprint-lessons/run.sh
```

Expected: `5 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add templates/blueprint-lessons.md.tmpl tests/blueprint-lessons/run.sh
git commit -m "feat(templates): add blueprint-lessons init template"
```

---

### Task 3: The lessons-filter sub-agent definition

**Files:**
- Create: `agents/lessons-filter.md`

This file is a markdown agent definition. There is no automated test for the agent's behavior (that requires a live model); the manual-tests doc will cover that.

- [ ] **Step 1: Create the agent file**

Create `agents/lessons-filter.md`:

````markdown
---
name: lessons-filter
description: Blueprint-lessons filter sub-agent. Spawned by mi-apply-impact at stage 2 Pre-Step A. Reads lessons-learned.md, picks entries relevant to blueprint creation for the active feature, and fills implementation/blueprint-lessons.md. Read-only on lessons-learned.md; main owns artifact init and all frontmatter fields except selected-count.
model: haiku
effort: medium
tools: [Read, Edit, Bash]
---

You are a fresh sub-agent invoked from `mi-apply-impact`'s Pre-Step A. Your
job is to filter the cumulative PR-review lessons in
`<data_root>/lessons-learned.md` to the entries that should influence the
blueprint for the active feature in this cycle.

Your context is isolated from the main session — main does not see your
tool calls, only your structured return.

## What main has already done

Before invoking you, main has created `<blueprint_lessons_path>` from
`templates/blueprint-lessons.md.tmpl` via
`scripts/frontmatter.sh init blueprint-lessons …`. The file's frontmatter is
fully populated with valid values (`id`, `feature`, `requirements-id: null`,
`lessons-source-mtime`, `selected-count: 0`). The body has a `# Blueprint-relevant
lessons` heading, an introductory paragraph, and a literally-empty
`## Selected lessons` section.

You fill the body of `## Selected lessons` and update exactly ONE frontmatter
field — `selected-count`. You do NOT create the file from scratch and you do
NOT touch `id`, `feature`, `requirements-id`, or `lessons-source-mtime`.

## Required first reads

1. **`<lessons_path>`** — every `## L-NNN` block in `lessons-learned.md`.
2. **`<quest_dir>/todo-list.md`** — the active todo items: read the section
   for the `<active_feature>` feature; capture every item id (e.g.
   `PAY-001`, `AUD-002`) and its one-line description, for both
   `PENDING`-tagged items (in scope this cycle) and `TODO`-tagged items (the
   feature's backlog). These ids are what every relevance tie-back binds to.
   `requirements.md` does not exist yet — `todo-list.md` is the
   authoritative source of item ids at this point in stage 2.
3. **`<quest_dir>/summary.md`** — read `## Cross-cutting constraints` and
   the `## Feature: <active_feature>` section ONLY. Do not read other
   features' sections. `summary.md` gives the feature-level context; it
   does not generally list item ids.

## Judgment task

For each `## L-NNN` block, decide whether the lesson is **blueprint-relevant**:

- **Blueprint-relevant** means the lesson should influence WHAT goes into
  `requirements.md` (Goals / Planned / Non-goals wording, scope discipline,
  acceptance-criteria altitude, seam-naming, scope-tier picks, items added
  or dropped) OR how `codebase-grounder` classifies seams or picks
  pre-existing components.
- **NOT blueprint-relevant**: code-level rules, framework quirks, runtime
  behavior, library-specific traps. Those apply at stage 3 (planning /
  implementation chain) and are already covered via `config.md`'s
  `## Lessons learned` pointer.

For every lesson you select, write a one-line `relevance:` reason that ties
it to a concrete concern in this cycle. Valid tie-back anchors:

- an **active todo item id** (PENDING-tagged for this cycle), OR
- a **planned todo item id** (TODO-tagged for this feature), OR
- a **cross-cutting constraint** from `summary.md`'s
  `## Cross-cutting constraints`, OR
- a **feature-level concern** from `summary.md`'s `## Feature: <active_feature>`.

If you cannot articulate a tie-back to one of those four anchors in one
line, **drop the lesson** — non-tied lessons add noise.

## Write the body

Use `Edit` to replace the post-heading content of `<blueprint_lessons_path>`.
The new body under `## Selected lessons` (one `### L-NNN` block per selected
lesson; the heading itself is not rewritten):

```
### L-NNN — <title copied verbatim from the source block>
- source: <copied verbatim from the source block's `source:` line>
- relevance: <one line tying this lesson to this cycle's blueprint>
- lesson: |
    <verbatim copy of the source `lesson:` body, preserving blank lines>
```

When zero lessons are selected, do not write any `### L-NNN` blocks — leave
the body of `## Selected lessons` literally empty. Do NOT introduce a
placeholder or a "no lessons selected" stub; downstream consumers detect
the empty section by checking `selected-count == 0` (cheap) and/or scanning
the body for non-whitespace content (fallback).

## Update the frontmatter field you own

Update `selected-count` to the number of `### L-NNN` blocks you wrote:

```bash
scripts/frontmatter.sh set <blueprint_lessons_path> selected-count <N>
```

Do NOT touch `id`, `feature`, `requirements-id`, or `lessons-source-mtime`.
Those belong to main.

## Validate before returning

Run a final frontmatter validation so a bad write fails inside your turn
rather than in a downstream consumer:

```bash
scripts/frontmatter.sh validate <blueprint_lessons_path> blueprint-lessons
```

If validation fails, attempt one corrective edit; on second failure, return
`Result: blocked` with the validation error message under `Findings / risks`
and DO NOT continue — main will re-run `frontmatter.sh init` to clobber any
partial state.

## Required return shape

Return ONLY this structure. Do not narrate intermediate steps.

```
Result: success | partial | blocked
Artifacts changed:
- <blueprint_lessons_path>: selected N of M lessons
Commits:
- (none — this sub-agent never commits)
Findings / risks:
- <one short bullet, optional; required on partial/blocked with the reason>
Main should read:
- <blueprint_lessons_path>: read ## Selected lessons before Step A
```

Total return must fit under ~1k tokens.
````

- [ ] **Step 2: Verify the file lints**

```bash
ls agents/lessons-filter.md
head -8 agents/lessons-filter.md  # verify frontmatter is intact
```

Expected: file exists; the first 8 lines show the YAML frontmatter cleanly.

- [ ] **Step 3: Commit**

```bash
git add agents/lessons-filter.md
git commit -m "feat(agents): add lessons-filter sub-agent for stage-2 blueprint injection"
```

---

### Task 4: Add Pre-Step A to mi-apply-impact (guard + init + spawn + recovery)

**Files:**
- Modify: `commands/mi-apply-impact.md` (insert a new Pre-Step A section between Step 1 and Step 2)

- [ ] **Step 1: Read the current command file to locate insertion point**

```bash
grep -n "^### Step " commands/mi-apply-impact.md | head -5
```

Identify the line immediately before `### Step 2 — Regenerate \`blueprints/current/\` content`. The new section is inserted there.

- [ ] **Step 2: Insert the Pre-Step A section**

Find the line `### Step 2 — Regenerate \`blueprints/current/\` content` in `commands/mi-apply-impact.md`. Immediately *before* that heading, insert the following section:

````markdown
### Step 1.5 — Lessons-filter Pre-Step A

Filter `lessons-learned.md` for blueprint-creation-relevant entries before
the runbook's main work begins, so main writing `requirements.md` and the
delegated `codebase-grounder` both have the filtered set in scope. The
filtered artifact also serves the stage-2 codex review at Step B.5.

The whole step is **guarded on `lessons-learned.md` existing**. `scripts/lessons.sh path`
returns a resolved path unconditionally — it does not check existence — so
the guard lives at this call site.

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
impl_dir="$data_root/workflow-stream/$active_feature/implementation"
blueprint_lessons_path="$impl_dir/blueprint-lessons.md"
lessons_path="$($CLAUDE_PLUGIN_ROOT/scripts/lessons.sh path)"

if [[ ! -f "$lessons_path" ]]; then
  echo "info: lessons-learned.md not present; skipping blueprint-lessons injection"
else
  mkdir -p "$impl_dir"
  lessons_mtime="$(stat -f %m "$lessons_path" 2>/dev/null \
                   || stat -c %Y "$lessons_path" 2>/dev/null \
                   || echo 0)"
  "$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" init blueprint-lessons \
    "$blueprint_lessons_path" \
    "FEATURE=$active_feature" \
    "LESSONS_SOURCE_MTIME=$lessons_mtime" \
    "SELECTED_COUNT=0"

  # Spawn the lessons-filter sub-agent. The prompt below substitutes the
  # placeholders with the concrete values from this caller context.
  #
  # Sub-agent: agents/lessons-filter.md (subagent_type:
  # millwright-inspector-development-machine:lessons-filter).
  #
  # Spawn prompt template:
  #
  #   You are invoked from mi-apply-impact's Pre-Step A. Filter
  #   <lessons_path> to the blueprint-creation-relevant entries for the
  #   "<active_feature>" feature this cycle. Main has already created
  #   <blueprint_lessons_path> with valid frontmatter; you fill the body and
  #   update only `selected-count`. Follow agents/lessons-filter.md
  #   exactly.
  #
  #   Inputs:
  #   - active_feature: <active_feature>
  #   - lessons_path: <lessons_path>
  #   - quest_dir: <quest_dir>
  #   - blueprint_lessons_path: <blueprint_lessons_path>
  #
  #   Return per the sub-agent's return contract.
fi
```

After the sub-agent returns, recover from `blocked` or schema-validation
failures by clobbering the artifact back to the canonical zero-count
template. Both failure modes leave the artifact in an untrusted state
(partial body, mutated `selected-count`, or invalid frontmatter); the same
`frontmatter.sh init` re-run resets it:

```bash
# Run after the sub-agent return is parsed. Conditional on the artifact
# existing (skips cleanly on the no-lessons-file path above).
if [[ -f "$blueprint_lessons_path" ]]; then
  if [[ "${lessons_filter_result:-success}" == "blocked" ]]; then
    echo "warning: lessons-filter blocked — reset blueprint-lessons.md to zero-count; no injection this cycle" >&2
    "$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" init blueprint-lessons \
      "$blueprint_lessons_path" \
      "FEATURE=$active_feature" \
      "LESSONS_SOURCE_MTIME=$lessons_mtime" \
      "SELECTED_COUNT=0"
  elif ! "$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" validate \
            "$blueprint_lessons_path" blueprint-lessons >/dev/null 2>&1; then
    echo "warning: lessons-filter wrote an invalid artifact — reset blueprint-lessons.md to zero-count; no injection this cycle" >&2
    "$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" init blueprint-lessons \
      "$blueprint_lessons_path" \
      "FEATURE=$active_feature" \
      "LESSONS_SOURCE_MTIME=$lessons_mtime" \
      "SELECTED_COUNT=0"
  fi
fi
```

`$lessons_filter_result` is the `Result:` line from the sub-agent return.
Parse it before the recovery block runs.

Once the recovery (if any) completes, fall through to Step 2.

````

- [ ] **Step 3: Verify the new section reads correctly**

```bash
awk '/^### Step 1\.5 — Lessons-filter Pre-Step A$/,/^### Step 2 — /' commands/mi-apply-impact.md | head -80
```

Expected: the new section appears in full, ending just before the `### Step 2 — Regenerate` heading.

- [ ] **Step 4: Commit**

```bash
git add commands/mi-apply-impact.md
git commit -m "feat(mi-apply-impact): add Pre-Step A — lessons-filter sub-agent invocation"
```

---

### Task 5: Add requirements-id backfill at end of Step A in mi-apply-impact

**Files:**
- Modify: `docs/blueprint-regeneration.md` (the actual Step A body lives here; `mi-apply-impact.md` delegates to it)

The Step-A runbook lives in `docs/blueprint-regeneration.md`, not in `mi-apply-impact.md` directly. The backfill belongs at the end of Step A, after main writes `requirements.md` and captures its `id`.

- [ ] **Step 1: Locate the end of Step A**

```bash
grep -n "^## Step " docs/blueprint-regeneration.md
```

Identify the boundary between Step A and Step B. The backfill block belongs immediately before `## Step B — Generate \`config.md\``.

- [ ] **Step 2: Add the backfill block at end of Step A**

Find the line `## Step B — Generate \`config.md\` (auto + manual sections)` in `docs/blueprint-regeneration.md`. Immediately *before* that line, insert:

````markdown
### Step A — backfill the blueprint-lessons cross-reference (when present)

If the Pre-Step A lessons-filter ran (i.e. `lessons-learned.md` existed at
stage entry), backfill the freshly-written `requirements.md`'s id into
`blueprint-lessons.md`'s `requirements-id` field so the two artifacts
cross-link per Rule 2 of the workflow spec. Skip when the artifact was
never created (no-lessons-file path).

Both calls are guarded: `frontmatter.sh get` runs under `set -e`, so an
unguarded failure would abort `mi-apply-impact` before the warn-on-failure
on the `set` call could fire.

```bash
if [[ -f "$blueprint_lessons_path" ]]; then
  requirements_id="$("$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" get \
    "$dest" id 2>/dev/null || true)"
  if [[ -n "$requirements_id" ]]; then
    "$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" set \
      "$blueprint_lessons_path" requirements-id "$requirements_id" \
      || echo "warning: requirements-id backfill failed for blueprint-lessons.md" >&2
  else
    echo "warning: could not read requirements-id from $dest; skipping blueprint-lessons backfill" >&2
  fi
fi
```

`$dest` is the `requirements.md` path from earlier in this step;
`$blueprint_lessons_path` is the path computed in `mi-apply-impact.md` Step 1.5.
````

- [ ] **Step 3: Verify the block reads correctly**

```bash
awk '/^### Step A — backfill the blueprint-lessons cross-reference/,/^## Step B — /' docs/blueprint-regeneration.md | head -40
```

Expected: the backfill section appears in full, ending just before `## Step B — Generate config.md`.

- [ ] **Step 4: Add a main read of blueprint-lessons.md at the start of Step A's requirements composition**

Find the line that starts Step A's requirements composition in `docs/blueprint-regeneration.md`. Look for the existing text that begins with "Read `$quest_dir/todo-list.md` and `$quest_dir/summary.md`". Immediately *after* that paragraph (before the `summary.md` "feature-indexed" paragraph), insert:

```markdown
**Optional: read `blueprint-lessons.md` when present.** If Pre-Step A wrote a
`blueprint-lessons.md` for this feature (i.e. `lessons-learned.md` existed at
stage entry), read its `## Selected lessons` body before composing the
requirements body. The frontmatter `selected-count` indicates whether the
section is worth reading — when `selected-count > 0`, the lessons should
inform Goals / Planned / Non-goals wording. The artifact lives at
`workflow-stream/<active_feature>/implementation/blueprint-lessons.md`.

When the artifact does not exist (no-lessons-file path) or `selected-count == 0`,
skip this read — there are no applicable lessons.
```

- [ ] **Step 5: Commit**

```bash
git add docs/blueprint-regeneration.md
git commit -m "feat(blueprint-regeneration): backfill requirements-id + main read of blueprint-lessons.md"
```

---

### Task 6: Extend --force cleanup in mi-apply-impact

**Files:**
- Modify: `commands/mi-apply-impact.md`
- Modify: `tests/blueprint-lessons/run.sh` (append a Task-6 block)

- [ ] **Step 1: Write failing test**

Append to `tests/blueprint-lessons/run.sh` immediately before `# ---- Summary ----`:

```bash
# ---- Task 6: --force cleanup of stage-2 implementation artifacts ---------

t="--force cleanup: removes grounding-report.md and blueprint-lessons.md"
force_tmpdir="$(mktemp -d)"
mkdir -p "$force_tmpdir/impl"
echo "stage-2 owned" > "$force_tmpdir/impl/grounding-report.md"
echo "stage-2 owned" > "$force_tmpdir/impl/blueprint-lessons.md"
echo "later-stage sentinel — must be preserved" > "$force_tmpdir/impl/inspector-review.md"

# Mirror the cleanup loop the spec defines. Tests the contract, not the
# command invocation (which requires an active workflow).
for stage2_artifact in grounding-report.md blueprint-lessons.md; do
  [[ -e "$force_tmpdir/impl/$stage2_artifact" ]] && rm -f "$force_tmpdir/impl/$stage2_artifact"
done

if [[ -e "$force_tmpdir/impl/grounding-report.md" ]] \
   || [[ -e "$force_tmpdir/impl/blueprint-lessons.md" ]]; then
  ng "$t" "stage-2 artifact was not removed"
elif [[ ! -e "$force_tmpdir/impl/inspector-review.md" ]]; then
  ng "$t" "later-stage sentinel was removed; allowlist failed"
else
  ok "$t"
fi
rm -rf "$force_tmpdir"
```

- [ ] **Step 2: Run tests; verify the new one passes (it tests the contract directly, not the command edit)**

```bash
tests/blueprint-lessons/run.sh
```

Expected: `6 passed, 0 failed`. (The test verifies the cleanup contract; the command-file edit in Step 3 only documents/embeds it.)

- [ ] **Step 3: Embed the cleanup in mi-apply-impact's --force branch**

Open `commands/mi-apply-impact.md`. Find the bash block under Step 1 that handles the `cc_status=2` `--force` branch — it's the one that currently does:

```bash
echo "--force passed; clearing partial current/ and regenerating."
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
curr="$data_root/workflow-stream/$active_feature/blueprints/current"
shopt -s dotglob nullglob
for entry in "$curr"/*; do rm -rf "$entry"; done
shopt -u dotglob nullglob
$CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh ensure-current "$active_feature"
```

Immediately *after* the `shopt -u dotglob nullglob` line and *before* the
`$CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh ensure-current` line, insert:

```bash
# Stage-2 also owns two artifacts under implementation/. Allowlisted
# cleanup so later-stage artifacts (inspector-review.md, review-context.md,
# change-summary.md, diagrams/) are preserved if the inspector happens to
# be combining --force with a stale implementation/ from a prior aborted
# run. See docs/superpowers/specs/2026-05-22-blueprint-lessons-injection-design.md §8.1.
impl="$data_root/workflow-stream/$active_feature/implementation"
for stage2_artifact in grounding-report.md blueprint-lessons.md; do
  [[ -e "$impl/$stage2_artifact" ]] && rm -f "$impl/$stage2_artifact"
done
```

- [ ] **Step 4: Re-run tests to confirm nothing regressed**

```bash
tests/blueprint-lessons/run.sh
```

Expected: `6 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add commands/mi-apply-impact.md tests/blueprint-lessons/run.sh
git commit -m "feat(mi-apply-impact): extend --force cleanup to stage-2 implementation artifacts"
```

---

### Task 7: Codebase-grounder spawn prompt — add lessons-to-honor block

**Files:**
- Modify: `docs/blueprint-regeneration.md`

The codebase-grounder spawn prompt template lives inside `docs/blueprint-regeneration.md` Step A (look for `Sub-agent prompt template:` followed by a fenced block).

- [ ] **Step 1: Locate the existing spawn-prompt template**

```bash
grep -n "Required first reads" docs/blueprint-regeneration.md | head -5
```

Identify the first occurrence inside the codebase-grounder spawn-prompt template.

- [ ] **Step 2: Insert the lessons-to-honor block**

In `docs/blueprint-regeneration.md`, find the codebase-grounder spawn-prompt template's block that begins with:

```
**Required first reads:**

1. <quest_dir>/todo-list.md — find the items in scope this cycle: <comma-separated active_item_ids>. Read each item's description.
2. <quest_dir>/summary.md — read `## Cross-cutting constraints` and `## Feature: <active_feature>` sections.
```

Immediately after the closing of the `**Required first reads:**` enumeration (after the line for read #2), and before the line that begins `**Your task — for each item id in scope:**`, insert:

```
**Lessons from prior PR reviews (filtered for blueprint relevance):**

The file <blueprint_lessons_path> contains lessons selected from
lessons-learned.md that may apply to this cycle's blueprint. Read its
`## Selected lessons` section before classifying seams or picking
pre-existing components. Each lesson's `relevance:` line ties it to a
specific concern in this cycle.

If <blueprint_lessons_path> does not exist or its `selected-count` is 0,
skip this read — there are no applicable lessons. Do not count this read
against the per-item file budget; the artifact is a small intake file
(~1–4 KB), not a seam read.
```

- [ ] **Step 3: Verify the spawn prompt template now contains the lessons block**

```bash
awk '/Sub-agent prompt template:/,/Total return must fit/' docs/blueprint-regeneration.md \
  | grep -A 8 "Lessons from prior PR reviews"
```

Expected: the new block appears inside the spawn-prompt template.

- [ ] **Step 4: Also update the caller-side substitution list**

Find the paragraph in `docs/blueprint-regeneration.md` that says "Substitute `<placeholder>` literals with concrete values" near the codebase-grounder invocation. Add `<blueprint_lessons_path>` to the substitution list, with a one-line note:

```
- <blueprint_lessons_path>: the path computed in `commands/mi-apply-impact.md` Step 1.5. Pass the empty string if Pre-Step A was skipped (no lessons-learned.md).
```

- [ ] **Step 5: Commit**

```bash
git add docs/blueprint-regeneration.md
git commit -m "feat(blueprint-regeneration): codebase-grounder receives blueprint-lessons.md path"
```

---

### Task 8: Add {{LESSONS_BLOCK}} placeholder to both reviewer prompt templates

**Files:**
- Modify: `templates/blueprint-reviewer-prompt-consistency.md.tmpl`
- Modify: `templates/blueprint-reviewer-prompt-item.md.tmpl`

- [ ] **Step 1: Inspect the current templates**

```bash
cat templates/blueprint-reviewer-prompt-consistency.md.tmpl | head -40
cat templates/blueprint-reviewer-prompt-item.md.tmpl | head -40
```

Identify a stable insertion point in each — somewhere near the top of the prompt body, after any framing/preamble and before the file-content/item-content block. The placeholder should be conditional-readable: a renderer that substitutes the empty string for `{{LESSONS_BLOCK}}` must leave a clean prompt with no orphan headings or stray blank lines.

- [ ] **Step 2: Insert the placeholder in the consistency template**

In `templates/blueprint-reviewer-prompt-consistency.md.tmpl`, immediately after the prompt's framing/role section and before the `## Existing findings` (or the equivalent — adjust to whatever heading currently exists before the file-content block), insert exactly:

```
{{LESSONS_BLOCK}}
```

(no surrounding heading, no surrounding blank lines — the lessons block, when non-empty, supplies its own heading and a leading blank line. When the substituted value is empty, the placeholder line is removed entirely so no stray blank line remains.)

To make the empty-substitution behavior clean, the rendering rule will trim the placeholder's whole line when the value is empty — this is handled in the sub-agent's substitution code (Task 9, 10), not here.

- [ ] **Step 3: Insert the placeholder in the item template**

Identical insertion in `templates/blueprint-reviewer-prompt-item.md.tmpl`: pick a position immediately after the role/framing section and before the item-content block, and write `{{LESSONS_BLOCK}}` on its own line.

- [ ] **Step 4: Verify both files were edited**

```bash
grep -n LESSONS_BLOCK templates/blueprint-reviewer-prompt-consistency.md.tmpl \
                     templates/blueprint-reviewer-prompt-item.md.tmpl
```

Expected: one match in each file.

- [ ] **Step 5: Commit**

```bash
git add templates/blueprint-reviewer-prompt-consistency.md.tmpl \
        templates/blueprint-reviewer-prompt-item.md.tmpl
git commit -m "feat(templates): add LESSONS_BLOCK placeholder to reviewer prompt templates"
```

---

### Task 9: Wire lessons_block into the consistency reviewer sub-agent

**Files:**
- Modify: `agents/blueprint-consistency-reviewer.md`

- [ ] **Step 1: Add the new input under ## Inputs**

In `agents/blueprint-consistency-reviewer.md`, find the `## Inputs (from the spawn prompt)` section. After the existing bullet for `reasoning_effort`, append a new bullet:

```
- `lessons_block` — opaque markdown string to substitute as `{{LESSONS_BLOCK}}` in the reviewer prompt template. May be empty. Computed by the orchestrator (`/mi-blueprint-review`, `/mi-blueprint-review-consistency`) via sibling-detection against the file under review.
```

- [ ] **Step 2: Update the "Render the reviewer prompt" step**

Find Step 3 of the loop body (`### 3. Render the reviewer prompt`). Its existing substitution list reads roughly:

```
- `{{ITERATION}}` = current iteration (1-indexed).
- `{{FILE_PATH}}` = `file_path`.
- `{{FILE_CONTENT}}` = full file content.
- `{{EXISTING_FINDINGS}}` = a bullet list of every existing consistency finding's `id`, `severity`, `finding`. …
```

Append a new bullet to that list:

```
- `{{LESSONS_BLOCK}}` = substitute from the `lessons_block` spawn input. When `lessons_block` is the empty string, **remove the entire line** the placeholder sits on (do not leave a stray blank line) so the rendered prompt looks identical to a pre-feature run. When non-empty, the value is inserted verbatim — it already carries its own `## Lessons from prior PR reviews to honor` heading and surrounding context from the orchestrator.
```

- [ ] **Step 3: Verify the file**

```bash
grep -n LESSONS_BLOCK agents/blueprint-consistency-reviewer.md
grep -n "lessons_block" agents/blueprint-consistency-reviewer.md
```

Expected: at least one match for each.

- [ ] **Step 4: Commit**

```bash
git add agents/blueprint-consistency-reviewer.md
git commit -m "feat(agents): blueprint-consistency-reviewer accepts lessons_block input"
```

---

### Task 10: Wire lessons_block into the item reviewer sub-agent (both modes)

**Files:**
- Modify: `agents/blueprint-item-reviewer.md`

- [ ] **Step 1: Add the new input under both Mode A and Mode B input lists**

In `agents/blueprint-item-reviewer.md`, find the `## Inputs (from the spawn prompt)` section. It has two sub-blocks: `Mode A (file-anchored)` and `Mode B (stateless)`. Append to **both** sub-blocks the same new bullet:

```
- `lessons_block` — opaque markdown string to substitute as `{{LESSONS_BLOCK}}` in the reviewer prompt template. May be empty. In Mode A the orchestrator computes it via sibling-detection; in Mode B it is **always empty** (Mode B has no file anchor for sibling-detection).
```

- [ ] **Step 2: Update the "Render the reviewer prompt" step**

Find Step 2 of the loop body (`### 2. Render the reviewer prompt`). Its existing substitution list reads roughly:

```
- `{{ITERATION}}` = current iteration.
- `{{ITEM_ID}}` = `id` (mode A) or `(unnamed)` (mode B).
- `{{ITEM_CONTENT}}` = `working_copy`.
- `{{EXISTING_FINDINGS}}` = …
```

Append a new bullet:

```
- `{{LESSONS_BLOCK}}` = substitute from the `lessons_block` spawn input. When `lessons_block` is the empty string, **remove the entire line** the placeholder sits on (no stray blank line) so the rendered prompt looks identical to a pre-feature run. When non-empty (Mode A only — Mode B always passes empty), the value is inserted verbatim with its own `## Lessons from prior PR reviews to honor` heading.
```

- [ ] **Step 3: Verify the file**

```bash
grep -n LESSONS_BLOCK agents/blueprint-item-reviewer.md
grep -c "lessons_block" agents/blueprint-item-reviewer.md
```

Expected: the substitution bullet appears in the render step; `lessons_block` appears at least three times (Mode A input, Mode B input, render step).

- [ ] **Step 4: Commit**

```bash
git add agents/blueprint-item-reviewer.md
git commit -m "feat(agents): blueprint-item-reviewer accepts lessons_block input (Mode A populated, Mode B empty)"
```

---

### Task 11: Sibling-detection + spawn wiring in /mi-blueprint-review

**Files:**
- Modify: `commands/mi-blueprint-review.md`
- Modify: `tests/blueprint-lessons/run.sh` (append a sibling-detection test)

- [ ] **Step 1: Write the failing test for sibling-detection**

Append to `tests/blueprint-lessons/run.sh` immediately before `# ---- Summary ----`:

```bash
# ---- Task 11: sibling-detection contract ---------------------------------

# The contract: given a file path under .../blueprints/current/, the
# sibling lessons artifact lives at ../../implementation/blueprint-lessons.md.
# When selected-count > 0, lessons_block is non-empty; otherwise empty.

sibling_lessons_block() {
  # Mirrors the resolution rule that lives inside commands/mi-blueprint-review.md.
  local file="$1"
  local dir
  dir="$(cd "$(dirname "$file")" && pwd)"
  [[ "$dir" == */blueprints/current ]] || { echo ""; return 0; }
  local feature_dir
  feature_dir="$(cd "$dir/../.." && pwd)"
  local artifact="$feature_dir/implementation/blueprint-lessons.md"
  [[ -f "$artifact" ]] || { echo ""; return 0; }
  local count
  count="$("$REPO_ROOT/scripts/frontmatter.sh" get "$artifact" selected-count 2>/dev/null || echo 0)"
  if [[ "$count" =~ ^[1-9][0-9]*$ ]]; then
    # Extract the body under `## Selected lessons`.
    local body
    body="$(awk '/^## Selected lessons$/{flag=1; next} flag' "$artifact")"
    printf "## Lessons from prior PR reviews to honor\n\nUse these as additional review criteria — flag any item in this blueprint that contradicts one of these lessons.\n\n%s" "$body"
  else
    echo ""
  fi
}

t="sibling-detection: arbitrary file outside blueprints/current → empty"
sibling_tmpdir="$(mktemp -d)"
echo "# arbitrary" > "$sibling_tmpdir/random.md"
out="$(sibling_lessons_block "$sibling_tmpdir/random.md")"
if [[ -z "$out" ]]; then ok "$t"; else ng "$t" "expected empty, got: $out"; fi
rm -rf "$sibling_tmpdir"

t="sibling-detection: blueprints/current with no sibling artifact → empty"
sibling_tmpdir="$(mktemp -d)"
mkdir -p "$sibling_tmpdir/feature/blueprints/current"
echo "# requirements" > "$sibling_tmpdir/feature/blueprints/current/requirements.md"
out="$(sibling_lessons_block "$sibling_tmpdir/feature/blueprints/current/requirements.md")"
if [[ -z "$out" ]]; then ok "$t"; else ng "$t" "expected empty, got: $out"; fi
rm -rf "$sibling_tmpdir"

t="sibling-detection: blueprints/current with selected-count=0 sibling → empty"
sibling_tmpdir="$(mktemp -d)"
mkdir -p "$sibling_tmpdir/feature/blueprints/current" "$sibling_tmpdir/feature/implementation"
echo "# requirements" > "$sibling_tmpdir/feature/blueprints/current/requirements.md"
MI_PLUGIN_ROOT="$REPO_ROOT" "$REPO_ROOT/scripts/frontmatter.sh" init blueprint-lessons \
  "$sibling_tmpdir/feature/implementation/blueprint-lessons.md" \
  "FEATURE=feature" "LESSONS_SOURCE_MTIME=1000" "SELECTED_COUNT=0" >/dev/null 2>&1
out="$(sibling_lessons_block "$sibling_tmpdir/feature/blueprints/current/requirements.md")"
if [[ -z "$out" ]]; then ok "$t"; else ng "$t" "expected empty, got: $out"; fi
rm -rf "$sibling_tmpdir"

t="sibling-detection: selected-count=2 sibling → non-empty with honor heading"
sibling_tmpdir="$(mktemp -d)"
mkdir -p "$sibling_tmpdir/feature/blueprints/current" "$sibling_tmpdir/feature/implementation"
echo "# requirements" > "$sibling_tmpdir/feature/blueprints/current/requirements.md"
cat > "$sibling_tmpdir/feature/implementation/blueprint-lessons.md" <<'EOF'
---
id: 12345678-1234-4234-8234-123456789012
feature: feature
requirements-id: null
lessons-source-mtime: 1000
selected-count: 2
---

# Blueprint-relevant lessons

## Selected lessons

### L-001 — Goals must name the seam
- relevance: applies to PAY-001
- lesson: name the seam, don't describe behavior abstractly
EOF
out="$(sibling_lessons_block "$sibling_tmpdir/feature/blueprints/current/requirements.md")"
if [[ "$out" == *"Lessons from prior PR reviews to honor"* ]] \
   && [[ "$out" == *"L-001 — Goals must name the seam"* ]]; then
  ok "$t"
else
  ng "$t" "did not find honor heading or lesson body in output"
fi
rm -rf "$sibling_tmpdir"
```

- [ ] **Step 2: Run the tests; verify they pass (the helper inlines the contract directly)**

```bash
tests/blueprint-lessons/run.sh
```

Expected: `10 passed, 0 failed`.

- [ ] **Step 3: Embed the same resolution rule in `commands/mi-blueprint-review.md`**

Open `commands/mi-blueprint-review.md`. Find the line at the start of `### Step 1 — Validate inputs and resolve constants` (the existing argument-parsing bash block). Immediately after that block ends (after `MAX_ITEMS_PER_REVIEW=20`), insert a new sub-section that computes `lessons_block`:

````markdown
### Step 1.5 — Resolve lessons_block via sibling-detection

Compute the lessons block string once, before any phase spawns a sub-agent.
The block is non-empty only when `<file>` sits inside a `blueprints/current/`
directory AND a sibling `../../implementation/blueprint-lessons.md` exists
AND its `selected-count > 0`. Otherwise the block is empty and the reviewer
prompts render exactly as they did before this feature.

```bash
lessons_block=""
file_dir="$(cd "$(dirname "$file")" && pwd)"
if [[ "$file_dir" == */blueprints/current ]]; then
  feature_dir="$(cd "$file_dir/../.." && pwd)"
  artifact="$feature_dir/implementation/blueprint-lessons.md"
  if [[ -f "$artifact" ]]; then
    selected_count="$("$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" get \
      "$artifact" selected-count 2>/dev/null || echo 0)"
    if [[ "$selected_count" =~ ^[1-9][0-9]*$ ]]; then
      lessons_body="$(awk '/^## Selected lessons$/{flag=1; next} flag' "$artifact")"
      lessons_block="$(cat <<EOF
## Lessons from prior PR reviews to honor

Use these as additional review criteria — flag any item in this blueprint that contradicts one of these lessons.

$lessons_body
EOF
)"
    fi
  fi
fi
```

`$lessons_block` is then passed verbatim into every Phase 1, Phase 3, and
Phase 4 sub-agent spawn prompt under the input name `lessons_block`. Each
sub-agent substitutes it into `{{LESSONS_BLOCK}}` per its `## Inputs` block.
When the value is empty, the substitution rule drops the placeholder line
entirely so the rendered prompt has no stray blank line.
````

- [ ] **Step 4: Update Step 2, Step 4, and Step 5 spawn-prompt notes**

Find the three places in the file where sub-agent spawn prompts are described:

- Step 2 — Phase 1 (consistency)
- Step 4 — Phase 3 (per-item batched)
- Step 5 — Phase 4 (final consistency)

In each, add a one-line note that `lessons_block` is passed as a spawn input. For example, in the Phase 1 description, append a line at the end of the existing paragraph:

```
Parameters passed to the sub-agent: `file`, `max_c`, `agent`, `reviewer_tool`, `reasoning_effort` (G3), and `lessons_block` (from Step 1.5 — empty unless the file under review has a sibling blueprint-lessons.md with selected-count > 0).
```

Use the same shape for Phase 3 and Phase 4.

- [ ] **Step 5: Commit**

```bash
git add commands/mi-blueprint-review.md tests/blueprint-lessons/run.sh
git commit -m "feat(mi-blueprint-review): resolve lessons_block via sibling-detection and pass to all phases"
```

---

### Task 12: Sibling-detection wiring in /mi-blueprint-review-consistency

**Files:**
- Modify: `commands/mi-blueprint-review-consistency.md`

- [ ] **Step 1: Add the resolution rule**

Open `commands/mi-blueprint-review-consistency.md`. Find the first bash block that parses `agent`, `max_iter`, `file`, and `reasoning_effort`. Immediately after that block (and before the sub-agent is spawned), insert a new sub-section that computes `lessons_block`:

````markdown
### Step 1.5 — Resolve lessons_block via sibling-detection

Compute the lessons block string once before spawning the sub-agent. The
block is non-empty only when `<file>` sits inside a `blueprints/current/`
directory AND a sibling `../../implementation/blueprint-lessons.md` exists
AND its `selected-count > 0`. Otherwise the block is empty and the reviewer
prompt renders exactly as it did before this feature.

```bash
lessons_block=""
file_dir="$(cd "$(dirname "$file")" && pwd)"
if [[ "$file_dir" == */blueprints/current ]]; then
  feature_dir="$(cd "$file_dir/../.." && pwd)"
  artifact="$feature_dir/implementation/blueprint-lessons.md"
  if [[ -f "$artifact" ]]; then
    selected_count="$("$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" get \
      "$artifact" selected-count 2>/dev/null || echo 0)"
    if [[ "$selected_count" =~ ^[1-9][0-9]*$ ]]; then
      lessons_body="$(awk '/^## Selected lessons$/{flag=1; next} flag' "$artifact")"
      lessons_block="$(cat <<EOF
## Lessons from prior PR reviews to honor

Use these as additional review criteria — flag any item in this blueprint that contradicts one of these lessons.

$lessons_body
EOF
)"
    fi
  fi
fi
```

`$lessons_block` is then passed verbatim into the sub-agent spawn prompt
under the input name `lessons_block`. The sub-agent substitutes it into
`{{LESSONS_BLOCK}}` per its `## Inputs` block. When empty, the substitution
rule drops the placeholder line entirely so the rendered prompt has no
stray blank line.
````

- [ ] **Step 2: Update the spawn-prompt description**

Find the section where the sub-agent spawn prompt is composed. Add one bullet to the inputs list passed in the spawn prompt:

```
- lessons_block: <LESSONS_BLOCK>     (from sibling-detection above; pass empty when no sibling artifact or selected-count=0)
```

- [ ] **Step 3: Verify**

```bash
grep -n lessons_block commands/mi-blueprint-review-consistency.md
```

Expected: at least two matches (the resolution block + the spawn-prompt input).

- [ ] **Step 4: Commit**

```bash
git add commands/mi-blueprint-review-consistency.md
git commit -m "feat(mi-blueprint-review-consistency): resolve and pass lessons_block to the sub-agent"
```

---

### Task 13: /mi-blueprint-review-item — Mode A sibling-detection, Mode B forced-empty

**Files:**
- Modify: `commands/mi-blueprint-review-item.md`

- [ ] **Step 1: Add resolution + forced-empty logic**

Open `commands/mi-blueprint-review-item.md`. Find the section after argument parsing where `mode` is set to either `file` or `content`. Immediately after that detection block, insert:

````markdown
### Step 1.5 — Resolve lessons_block (Mode A only)

Mode B is stateless — it operates on raw content with no file anchor — so
sibling-detection cannot apply. Mode B **always** passes an empty
`lessons_block` to the item reviewer sub-agent. Mode A computes the same
sibling-detection block as `commands/mi-blueprint-review.md` Step 1.5.

```bash
lessons_block=""
if [[ "$mode" == "file" ]]; then
  file_dir="$(cd "$(dirname "$file")" && pwd)"
  if [[ "$file_dir" == */blueprints/current ]]; then
    feature_dir="$(cd "$file_dir/../.." && pwd)"
    artifact="$feature_dir/implementation/blueprint-lessons.md"
    if [[ -f "$artifact" ]]; then
      selected_count="$("$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" get \
        "$artifact" selected-count 2>/dev/null || echo 0)"
      if [[ "$selected_count" =~ ^[1-9][0-9]*$ ]]; then
        lessons_body="$(awk '/^## Selected lessons$/{flag=1; next} flag' "$artifact")"
        lessons_block="$(cat <<EOF
## Lessons from prior PR reviews to honor

Use these as additional review criteria — flag any item in this blueprint that contradicts one of these lessons.

$lessons_body
EOF
)"
      fi
    fi
  fi
fi
```
````

- [ ] **Step 2: Update both spawn prompts (Mode A and Mode B) to include lessons_block**

In the same file, find the Mode A spawn-prompt block (the fenced block beginning `**Mode A:**`). Add a new bullet to its `Inputs:` list:

```
- lessons_block: <LESSONS_BLOCK>     (from Step 1.5 — empty unless sibling-detection found a populated artifact)
```

Find the Mode B spawn-prompt block. Add the same input bullet, but with explicit forced-empty wording:

```
- lessons_block:      (Mode B is stateless — always empty; the item reviewer ignores this for Mode B and renders the template with the placeholder removed)
```

- [ ] **Step 3: Verify**

```bash
grep -n lessons_block commands/mi-blueprint-review-item.md
```

Expected: at least three matches (Step 1.5 block + Mode A spawn input + Mode B spawn input).

- [ ] **Step 4: Commit**

```bash
git add commands/mi-blueprint-review-item.md
git commit -m "feat(mi-blueprint-review-item): Mode A sibling-detection; Mode B forces empty lessons_block"
```

---

### Task 14: Add blueprint-lessons.md to mi-complete-workflow's archive allowlist

**Files:**
- Modify: `commands/mi-complete-workflow.md`
- Modify: `tests/blueprint-lessons/run.sh` (append archive-loop test)

- [ ] **Step 1: Write the failing test**

Append to `tests/blueprint-lessons/run.sh` immediately before `# ---- Summary ----`:

```bash
# ---- Task 14: archive allowlist ------------------------------------------

t="archive: blueprint-lessons.md is in the mi-complete-workflow allowlist"
if grep -E '^\s+for artifact in .*\bblueprint-lessons\.md\b' \
   "$REPO_ROOT/commands/mi-complete-workflow.md" >/dev/null 2>&1; then
  ok "$t"
else
  ng "$t" "blueprint-lessons.md not found in mi-complete-workflow.md's archive loop"
fi
```

- [ ] **Step 2: Run tests; verify the new one fails**

```bash
tests/blueprint-lessons/run.sh
```

Expected: the new test fails — `blueprint-lessons.md` is not yet in the archive loop.

- [ ] **Step 3: Add to the archive allowlist**

In `commands/mi-complete-workflow.md`, find the bash line:

```bash
  for artifact in inspector-review.md review-context.md change-summary.md grounding-report.md; do
```

Change it to:

```bash
  for artifact in inspector-review.md review-context.md change-summary.md grounding-report.md blueprint-lessons.md; do
```

- [ ] **Step 4: Update the historical-snapshot prose**

A few lines below the loop, find the prose paragraph that begins with `The historical snapshot is then complete: ...`. Update the parenthetical that lists archived artifacts:

Before:

```
…AND `implementation/` (review file, review-context, change-summary, grounding-report, implementation diagrams).
```

After:

```
…AND `implementation/` (review file, review-context, change-summary, grounding-report, blueprint-lessons, implementation diagrams).
```

- [ ] **Step 5: Run tests to verify the allowlist test now passes**

```bash
tests/blueprint-lessons/run.sh
```

Expected: `11 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add commands/mi-complete-workflow.md tests/blueprint-lessons/run.sh
git commit -m "feat(mi-complete-workflow): archive blueprint-lessons.md alongside other implementation artifacts"
```

---

### Task 15: Document the new artifact + sub-agent in the project doc

**Files:**
- Modify: `docs/millwright-inspector-project.md`

- [ ] **Step 1: Find the workflow-stream layout section**

```bash
grep -n "^### 3.4 The workflow stream" docs/millwright-inspector-project.md
```

- [ ] **Step 2: Update the implementation/ layout listing**

In `docs/millwright-inspector-project.md` § 3.4 (The workflow stream), find the existing tree diagram that shows `implementation/` contents:

```
├── implementation/        # archived into history/v[N+1]/implementation/ at stage 8
│   ├── inspector-review.md   # findings file (IR-NNN blocks)
│   ├── review-context.md     # compact stage-6 review primer
│   ├── change-summary.md     # cached analysis of base-commit..HEAD (cache-keyed reuse)
│   ├── grounding-report.md   # stage-2 codebase-grounding snapshot (seam classification)
│   └── diagrams/             # implementation render, with existing-vs-new framing
```

Add a new line for `blueprint-lessons.md` in the appropriate position (after `grounding-report.md`, before `diagrams/`):

```
│   ├── grounding-report.md   # stage-2 codebase-grounding snapshot (seam classification)
│   ├── blueprint-lessons.md  # stage-2 filtered lessons from lessons-learned.md (selected-count gating injection)
│   └── diagrams/             # implementation render, with existing-vs-new framing
```

- [ ] **Step 3: Update the surrounding prose**

Find the paragraph below the tree that lists `implementation/`'s archive contract (look for "implementation-side artifacts during the cycle. At stage 8 the live folder is **moved**..."). Update the list of preserved artifacts to include `blueprint-lessons.md`:

Before:

```
…so every finding (including deferred `status: open` ones), the review-context snapshot, the change-summary, the grounding-report, and the implementation diagrams survive as a permanent audit record.
```

After:

```
…so every finding (including deferred `status: open` ones), the review-context snapshot, the change-summary, the grounding-report, the filtered blueprint-lessons artifact, and the implementation diagrams survive as a permanent audit record.
```

- [ ] **Step 4: Document the new sub-agent**

Find the section on sub-agents (search for "first-class sub-agents" or "§8.6"). Add a bullet for `lessons-filter` to the existing sub-agent list (location-appropriate — wherever the existing sub-agents like `codebase-grounder`, `blueprint-diagrammer`, `pr-review-fixer` are listed):

```
- `lessons-filter` — stage-2 Pre-Step A: reads `lessons-learned.md`, picks blueprint-relevant entries for the active feature, and fills `implementation/blueprint-lessons.md`. Read-only on the source lessons file; main owns artifact init and all frontmatter fields except `selected-count`.
```

- [ ] **Step 5: Update the table in § 5 (Roles × plugin interaction) if it includes mi-apply-impact stage-2 row**

Search for the row that describes `/mi-apply-impact` (look for "auto-invokes `/mi-blueprint-review`"). If the row mentions specific stage-2 substeps, add a note that Pre-Step A also auto-fires the `lessons-filter` sub-agent.

If the row is sparse and just says "generate `blueprints/current/`", a one-line addition is appropriate:

```
| Millwright (auto) | `/mi-apply-impact` | `progress.sh activate`; lessons-filter Pre-Step A; generate `blueprints/current/`; pre-fill `## GIT BRANCH`. | 2 |
```

- [ ] **Step 6: Commit**

```bash
git add docs/millwright-inspector-project.md
git commit -m "docs(project): document blueprint-lessons.md artifact and lessons-filter sub-agent"
```

---

### Task 16: Document the manual test scenarios

**Files:**
- Create: `docs/superpowers/plans/2026-05-22-blueprint-lessons-injection-manual-tests.md`

Some scenarios in the spec's §10 cannot be exercised by the automated harness because they require a live model invocation. Document them so the inspector can drive them by hand.

- [ ] **Step 1: Create the manual-tests doc**

Create `docs/superpowers/plans/2026-05-22-blueprint-lessons-injection-manual-tests.md`:

````markdown
# Blueprint-lessons injection — manual test scenarios

The automated harness at `tests/blueprint-lessons/run.sh` covers what can be
checked by shell alone: schema validation, template init, sibling-detection
contract, `--force` cleanup, archive allowlist. The scenarios below require
a live sub-agent invocation and are exercised by hand against a real
workflow.

For each scenario, you'll need a project with the plugin installed, a
populated `journal/`, and an inspector ready to drive `/mi-run` and
`/mi-continue`.

## Scenario 1 — Lessons file absent (graceful skip)

Setup:
- Fresh data root with no `lessons-learned.md`.

Steps:
- Run a normal `/mi-run` → `/mi-continue` flow through stage 2.

Assertions:
- No `workflow-stream/<feature>/implementation/blueprint-lessons.md` is
  written.
- Stage 2 completes; `/mi-blueprint-review` runs and its reviewer prompts
  contain no `## Lessons from prior PR reviews to honor` heading (check
  the codex MCP request body if it's logged, or trust that
  `lessons_block` was empty per the sibling-detection rule).
- The Step A backfill block prints no warning (it's guarded on the
  artifact existing).

## Scenario 2 — Lessons present, zero blueprint-relevant

Setup:
- `lessons-learned.md` with 2–3 lessons whose body is clearly code-level
  (e.g. "always use prepared statements", "lock files before fsync") and
  not blueprint-creation-related.

Steps:
- Run through stage 2.

Assertions:
- `blueprint-lessons.md` exists; `selected-count: 0`.
- The `## Selected lessons` body is literally empty.
- The codex review prompt for both phases contains no
  `## Lessons from prior PR reviews to honor` heading (lessons_block
  resolved to empty because `selected-count == 0`).

## Scenario 3 — Lessons present, ≥ 1 selected

Setup:
- `lessons-learned.md` with at least one entry whose body is plausibly
  about blueprint creation (e.g. "Goals items must name the existing seam
  rather than describing intent abstractly").

Steps:
- Run through stage 2.

Assertions:
- `blueprint-lessons.md` exists; `selected-count >= 1`.
- The `## Selected lessons` body has one `### L-NNN` block per picked
  entry, each with a `relevance:` line tying it to a concrete todo item
  id or constraint.
- After Step A writes `requirements.md`, `blueprint-lessons.md`'s
  `requirements-id` frontmatter field is no longer `null` — it matches
  the freshly-written requirements file's `id`.
- The codex review prompt for both phases contains the
  `## Lessons from prior PR reviews to honor` heading with the lesson's
  verbatim body.

## Scenario 4 — lessons-filter blocked (manual injection)

This is the trickiest scenario to exercise. The sub-agent itself decides
when to return `Result: blocked`. The cleanest hand-driven approximation:

Setup:
- Make `lessons-learned.md` syntactically broken (e.g., dangling `## L-`
  block with no body, or invalid YAML frontmatter).
- Run through stage 2.

Expected behavior:
- The `lessons-filter` sub-agent will either return `Result: blocked` or
  attempt to write an invalid artifact.
- Main's recovery logic re-runs `frontmatter.sh init blueprint-lessons`,
  resetting the file to zero-count + empty body.
- A warning is printed: either `lessons-filter blocked — …` or
  `lessons-filter wrote an invalid artifact — …`.
- `blueprint-lessons.md` ends up with `selected-count: 0` and an empty
  `## Selected lessons` body.
- The rest of stage 2 (Step A, B, B.5, C) completes normally.

## Scenario 5 — Manual /mi-blueprint-review on arbitrary file

Setup:
- Pick any markdown file in the workspace that is NOT under
  `workflow-stream/<feature>/blueprints/current/`.

Steps:
- Run `/mi-blueprint-review codex 3 5 <that file path>`.

Assertions:
- Sibling-detection finds no artifact; `lessons_block` resolves to empty.
- The reviewer prompts render exactly as they did before this feature —
  no `## Lessons from prior PR reviews to honor` heading anywhere.
- The command completes without error.

## Scenario 6 — Stage 8 archive

Setup:
- Drive a feature cycle to completion (`/mi-continue` through stage 8).

Assertions:
- After `/mi-complete-workflow` finishes,
  `workflow-stream/<feature>/blueprints/history/v[N+1]/implementation/blueprint-lessons.md`
  exists and is byte-equal to the pre-rotation
  `implementation/blueprint-lessons.md`.
- The live `implementation/` folder no longer contains
  `blueprint-lessons.md` (it was moved, not copied).
````

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/plans/2026-05-22-blueprint-lessons-injection-manual-tests.md
git commit -m "docs(plans): add manual test scenarios for blueprint-lessons injection"
```

---

### Task 17: Run the full suite and lint-check

**Files:** (read-only verification)

- [ ] **Step 1: Run the new test harness**

```bash
tests/blueprint-lessons/run.sh
```

Expected: all tests pass. Specifically:
- 3 schema tests (Task 1)
- 2 template tests (Task 2)
- 1 --force cleanup test (Task 6)
- 4 sibling-detection tests (Task 11)
- 1 archive allowlist test (Task 14)

Total: `11 passed, 0 failed`.

- [ ] **Step 2: Run the rename-leakage lint**

```bash
tests/lint/run.sh
```

Expected: all checks pass — we haven't introduced any pre-rename tokens.

- [ ] **Step 3: Verify the PostToolUse hook would accept the new template + schema**

Sanity check the new schema syntactically:

```bash
python3 -c "import yaml; yaml.safe_load(open('schemas/blueprint-lessons.schema.yaml'))"
```

Expected: no output (parse succeeded).

- [ ] **Step 4: Verify the agent definition lints**

```bash
head -8 agents/lessons-filter.md
```

Expected: a clean YAML frontmatter block with `name: lessons-filter`,
`model: haiku`, `effort: medium`, `tools: [Read, Edit, Bash]`.

- [ ] **Step 5: Final commit (only if any small fixes were needed above)**

If any of the above checks surfaced an issue, fix it inline, then:

```bash
git add -p
git commit -m "fix(blueprint-lessons): post-implementation cleanup"
```

If nothing needed fixing, no commit. The feature is ready for manual
testing per `docs/superpowers/plans/2026-05-22-blueprint-lessons-injection-manual-tests.md`.

---

## Spec → task coverage map

| Spec section | Task(s) |
|---|---|
| §4 Architecture diagram (whole flow) | 1–14 collectively |
| §5 lessons-filter sub-agent | 3 (definition); 4 (spawn from mi-apply-impact) |
| §5.1 Main pre-init with presence guard | 4 |
| §5.2 Spawn prompt + reads | 3 (sub-agent file); 4 (concrete prompt substitution) |
| §6 Artifact + schema + template | 1, 2 |
| §7.1 Main reads + backfill | 5 |
| §7.2 codebase-grounder spawn prompt block | 7 |
| §7.3 Codex review wiring (orchestrator + sub-agents + templates) | 8, 9, 10, 11, 12, 13 |
| §8 Error handling table | 4 (blocked + schema-fail recovery); 5 (guarded backfill); 8.1 (--force) → 6 |
| §8.1 --force cleanup | 6 |
| §9 Lifecycle (archive at stage 8) | 14 |
| §10 Tests | 1, 2, 6, 11, 14 (automated); 16 (manual) |
| §11 Files touched | covered by 1–15 |

## Self-review

- **Spec coverage:** every numbered section is mapped to at least one task above.
- **Placeholder scan:** every code/diff block in the plan is complete; no TBD/TODO/"implement later"; every command has expected output.
- **Type consistency:** field names (`selected-count`, `lessons-source-mtime`, `requirements-id`, `feature`, `id`) are identical across schema, template, sub-agent prompt, and consumer reads. Path variables (`$blueprint_lessons_path`, `$lessons_path`, `$impl_dir`, `$active_feature`) are introduced in Task 4 and reused with the same names in Tasks 5, 6, 7. The orchestrator-side variables (`lessons_block`, `selected_count`, `artifact`, `feature_dir`, `file_dir`) are introduced in Task 11 and reused identically in Tasks 12 and 13.
