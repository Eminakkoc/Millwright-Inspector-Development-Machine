---
description: Render diagrams of the implementation (commit range base-commit..HEAD) into implementation/diagrams/, with pre-existing system context framed alongside the new functionality. Called by /mo-continue at stage 4.
---

# mo-generate-implementation-diagrams

Generates the single set of diagrams the overseer reviews at stage 5. Each diagram shows the **implemented** behaviour of `base-commit..HEAD` with **pre-existing** participants, classes, and flows kept in view as framed/shaded context so the overseer can spot what changed at a glance.

**Main-read budget (stage 4).** Allowed in main: `progress.md`, drift-probe filesystem state, the sub-agent's return summary, and the `.puml` file listing for the README write. Forbidden in main: diff hunks, change-summary.md body composition, and PlantUML source generation — delegated to `subagent_type: millwright-overseer-development-machine:implementation-analyst` (Phase 3.1) under the per-event prompt gate. The change-summary cache check (`commits.sh change-summary-fresh`) runs in main only as a freshness probe to set the `summary_state` flag passed into the sub-agent prompt; main does not read the body. See `docs/workflow-spec.md` § "Main-read budget gates by stage" for the canonical table.

## Execution

### Step 1 — Resolve inputs

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
active_feature="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get-active)"
base_commit="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get base-commit)"
dest_dir="$data_root/workflow-stream/$active_feature/implementation/diagrams"
mkdir -p "$dest_dir"
```

### Step 1.5 — Diagram-set freshness check (skip regeneration when fresh)

Before doing any diagram work, check whether the existing set is already current. The `diagrams-fresh` subcommand returns one of `fresh | stale | skipped | missing` (see `scripts/commits.sh diagrams-fresh` for the contract):

```bash
freshness="$($CLAUDE_PLUGIN_ROOT/scripts/commits.sh diagrams-fresh "$active_feature")"
freshness_exit=$?
```

Branch on the output:

- **`fresh`** (exit 0) — `implementation/diagrams/` exists with `.puml` files AND no commits since the last diagram-render commit. Print *"diagrams already current — skipping regeneration"* and exit 0. Do NOT proceed to Step 2.
- **`stale`** (exit 0) — proceed to Step 2 to regenerate. (This is the typical case at stage-4 entry: diagrams either don't exist yet or new commits have landed.)
- **`skipped`** (exit 0) — `implementation-diagrams-skipped=true`. This command was invoked anyway (most likely from the manual recovery path or stage-7 refresh). Proceed to Step 2 to regenerate; after success, the caller (`/mo-draw-diagrams` or stage-7's Step 2.5) is responsible for clearing `implementation-diagrams-skipped=false`.
- **`missing`** (exit non-zero) — invariant violation diagnostic. Surface to the overseer:

  > "diagrams-fresh returned `missing` for `$active_feature` — the workflow expected either `implementation/diagrams/` with `.puml` files OR `implementation-diagrams-skipped=true`, but neither holds. This may be the result of a partial run. Run `/mo-draw-diagrams` to regenerate, or `/mo-resume-workflow` for a state diagnosis."

  Then exit non-zero. Do NOT silently regenerate — the routing layer in callers handles the recovery prompt.

### Step 2 — Resolve inputs and spawn the implementation-analyst sub-agent

Diagram generation reads from a cached analysis artifact instead of re-running the codebase scan from scratch. `/mo-update-blueprint` writes the same artifact when it runs in the same stage-4 turn (post-chain drift refresh), so the analysis happens once per `base-commit..HEAD` range.

**Cache contract (load-bearing — do NOT bypass).** The `change-summary-fresh` check is the gate that prevents this command and `/mo-update-blueprint` from independently re-walking the codebase for the same `(base-commit, HEAD)` range. Both consumers MUST call `commits.sh change-summary-fresh` before regenerating; a future change that reads `change-summary.md` directly without the freshness gate would re-introduce the double-walk this cache exists to prevent. See `docs/context optimization/recommendations.md` § "Cache Key Specifications" → `change-summary.md` for the canonical key.

#### Step 2.1 — Resolve sub-agent inputs (main)

```bash
requirements_file="$data_root/workflow-stream/$active_feature/blueprints/current/requirements.md"
requirements_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$requirements_file" id)"
base_commit_sha="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get base-commit)"
head_sha="$(git rev-parse HEAD)"
diagram_rendering="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get diagram-rendering 2>/dev/null || echo 'never')"
summary_file="$dest_dir/../change-summary.md"
blueprint_diagrams_dir="$data_root/workflow-stream/$active_feature/blueprints/current/diagrams"

if $CLAUDE_PLUGIN_ROOT/scripts/commits.sh change-summary-fresh "$active_feature"; then
  summary_state="fresh"
else
  summary_state="stale-or-missing"
fi
```

#### Step 2.2 — Initialize change-summary.md frontmatter when stale (main)

When `summary_state=stale-or-missing`, pre-create the file with valid frontmatter so the sub-agent only has to fill the body (mirrors Step A's "Initialize the report" pattern in `docs/blueprint-regeneration.md`):

```bash
if [[ "$summary_state" == "stale-or-missing" ]]; then
  $CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init change-summary \
    "$summary_file" \
    "REQUIREMENTS_ID=$requirements_id" \
    "FEATURE=$active_feature" \
    "BASE_COMMIT=$base_commit_sha" \
    "HEAD=$head_sha"
fi
```

When `summary_state=fresh`, leave the file alone — the sub-agent will read it as-is and skip the regeneration phase internally.

#### Step 2.3 — Spawn the sub-agent

**Delegate change-summary regeneration + diagram framing + selective re-render to a fresh sub-agent.** Bounded-context reading of the diff (often hundreds of lines across many files) and PlantUML rendering both belong off main — keeping them in a disposable sub-agent caps main's per-cycle bloat at the return summary. This was the workload labelled "delegation candidate" in prior versions; it is now mandatory, not optional.

Invoke `Agent` with `subagent_type: millwright-overseer-development-machine:implementation-analyst`. Compose the prompt from the template below. Substitute `<placeholder>` literals with concrete values resolved above.

Sub-agent prompt template:

```
You are a fresh sub-agent invoked from `mo-generate-implementation-diagrams` (Step 2.3) at stage 4. Your context is isolated from the main session — main does not see your tool calls, only your final return summary.

**Inputs (resolved by main, passed in this prompt):**

- active_feature: <active_feature>
- base_commit: <base_commit_sha>
- HEAD: <head_sha>
- summary_file: <summary_file>
- summary_state: <summary_state>          # "fresh" or "stale-or-missing"
- diagrams_dir: <dest_dir>                # implementation/diagrams/ destination
- blueprint_diagrams_dir: <blueprint_diagrams_dir>  # source for seeding
- diagram_rendering: <diagram_rendering>  # "never" (>99% path) or "on-request"
- requirements_path: <requirements_file>

**Your task — three phases:**

### Phase 1 — Ensure `change-summary.md` is current

- If `summary_state=fresh`, read <summary_file> as the analysis cache and skip to Phase 2 — do NOT re-walk the codebase.
- If `summary_state=stale-or-missing`, the file is pre-initialized with valid frontmatter by main. Fill the body via `Edit` per `templates/change-summary.md.tmpl`. Source the changed-file list from the helper:

  ```bash
  $CLAUDE_PLUGIN_ROOT/scripts/commits.sh changed-files "<active_feature>"
  # Emits TSV rows: <status>\t<adds>\t<dels>\t<path>
  ```

  Body sections to fill:
  - `## Range` — fill `commit count` from `git rev-list --count "<base_commit_sha>..HEAD"`.
  - `## Changed files` — group the TSV rows by area (top-level dir, layer, or feature concern). Format: `<status> <path> (+adds/-dels): <one-line purpose>`. Skip the per-file purpose for trivial files. Do NOT paste full diffs.
  - `## Detected entrypoints` — public surface introduced or modified: HTTP routes, RPC handlers, CLI commands, scheduled jobs, queue consumers, new exports. One bullet per entrypoint with `<path>:<symbol>`. Skip the section if no public surface changed.
  - `## Suspected flows` — end-to-end flows the change enables (validated against the diagram pass in Phase 3). Each entry: `<flow name>: <one-line trace>`.
  - `## Omitted from analysis` — every changed file you intentionally skipped per the bounded-context policy below, listed by path so reviewers can spot blind spots.

  Bounded context policy (apply throughout Phase 1):

  1. Diff hunks first. Always read `git diff "<base_commit_sha>..HEAD" -- <path>` for every changed file before opening unchanged-side context.
  2. Cap caller/callee expansion at 3 per changed file. Only open more when a flow would be unreadable without them — and note the expansion in the file's `## Changed files` bullet.
  3. Prefer symbol search over whole-file reads. If you only need the signature or one function, grep for it rather than `Read`-ing the whole file.
  4. Skip generated/vendor/lock files. Default omissions: `dist/`, `build/`, `node_modules/`, `vendor/`, `*.lock`, `package-lock.json`, `yarn.lock`, `Cargo.lock`, `Gemfile.lock`, `*.min.js`, `*.svg`.
  5. Skip large binary diffs. Files where `commits.sh changed-files` reports `-/-` for adds/dels are binary; record the path under `## Omitted from analysis`.

### Phase 2 — Seed `<diagrams_dir>` from `<blueprint_diagrams_dir>`

Stage 5 review and stage 8 archival both expect `<diagrams_dir>` to be a complete diagram set — one file per subject, matching the stage-2 set. Seed the `.puml` files from the blueprint folder before any selective re-rendering. `cp -n` ensures idempotent re-runs preserve already-generated implementation versions. Copy ONLY `.puml` files — do NOT copy `README.md` (the schemas are deliberately distinct).

```bash
if [[ -d "<blueprint_diagrams_dir>" ]]; then
  for puml in "<blueprint_diagrams_dir>"/*.puml; do
    [[ -f "$puml" ]] || continue
    cp -n "$puml" "<diagrams_dir>/$(basename "$puml")"
  done
fi
```

### Phase 3 — Selective re-render against `<base_commit>..HEAD`

Identify which diagram subjects are affected by the commit range. Sources for the "affected subjects" set:

- `change-summary.md` `## Detected entrypoints` — new public surface mapped back to which diagram subject covers it (e.g., new payment-webhook entrypoint → `sequence-payment-submit.puml`).
- `change-summary.md` `## Suspected flows` — flows the implementation enables, mapped to the matching `sequence-<flow>.puml`.
- `change-summary.md` `## Changed files` grouped by area — areas that map to a structural diagram subject.

Re-render the affected subjects only. Overwrite their seeded `.puml` files in `<diagrams_dir>` using the existing-vs-new convention against the `<base_commit>` baseline. Leave unchanged subjects (no entries in the affected set) as the seeded stage-2 versions — those subjects had no implementation work this cycle. A 30-file change touching only `src/payments/` should re-render only the payments-related diagrams.

**Diagram set caps** (per `docs/workflow-spec.md` § "Diagram conventions"):

- `use-case-<feature>.puml` — mandatory, exactly one. Implemented capabilities with framed actors that pre-existed.
- `sequence-<flow>.puml` — one per significant implemented flow, targeting 2–3 total per feature. Render 1 only when the implementation genuinely has a single significant flow; never render more than 3 (if more than 3 candidates exist, pick the most diff-worthy; surface a decomposition signal under `Findings / risks` if the count keeps creeping up).
- One optional structural diagram — `class-<domain>.puml` OR `component-<subject>.puml`, never both. Read the seam classification from `<requirements_path>` Goals items (carried forward from Step A's codebase-grounding pass). The optional slot fires only when seam is `backend`/`mixed` AND:
  - Class when the implementation introduced 3+ new domain classes/modules with non-trivial relationships (inheritance, composition with shared lifecycle, bidirectional association, or branching dependency graph).
  - Component when the implementation introduced 3+ new components/modules with non-trivial dependencies (fan-out, fan-in, cross-bucket dependency, or multiple inbound callers) but isn't class-heavy enough for a class diagram.
  - Linear chains do not qualify (e.g., `controller → service → repo`). Skip the slot.
  - One-sentence test. If you can't articulate the diagram's purpose in one sentence beyond its filename, skip.
  - Skip for `frontend` / `infra` seams.

  Pick whichever fits the *implemented* topology best — even if stage 2 picked the other type, the implementation reality wins here. The overseer can compare the matched filenames across both diagram folders; if stage 2 rendered `class-payment-domain.puml` and stage 4 renders `component-payment-pipeline.puml`, that mismatch is itself signal of chain restructure and surfaces in the post-chain drift check.

**Existing-vs-new convention** (use the canonical PlantUML snippets in this same file's "Existing-vs-new convention" subsection below):

- Existing — blue (`#D6EAF8` fill, `#3498DB` strokes) inside `box "Existing system" #D6EAF8 … end box` (sequence) or `package "Existing" #D6EAF8 { … }` (class / use-case / component); blue arrows `A -[#3498DB]-> B`; `#D6EAF8` activations.
- New — green (`#D4EDDA` fill, `#27AE60` strokes) inside `box "New" #D4EDDA … end box` or `package "New" #D4EDDA { … }`; green arrows `C -[#27AE60]-> D`; `#D4EDDA` activations.
- Standard legend block; stage-4 wording reads `"existing (pre-base-commit)"` / `"new in this implementation"`.

**Render gate.** When `<diagram_rendering>=never` (default >99% path), produce ONLY `.puml` source files via the PlantUML MCP — do NOT render `.svg`/`.png`. Render `.svg` only when `<diagram_rendering>=on-request`.

**Wording caveat for seeded-only diagrams.** Stage-2 and stage-4 conventions share the colour scheme but differ in baseline semantics: stage-2's legend reads "Planned" / "to be implemented"; stage-4's reads "new in this implementation". For subjects that received no implementation commits this cycle, the seeded `.puml` retains the stage-2 wording verbatim — that's correct (no implementation work to recolour) but is a presentation deviation from the standard stage-4 convention. Do NOT programmatically rewrite seeded legends — main's freshly-generated implementation `README.md` (next step) surfaces the convention to the overseer.

---

Required return shape — return ONLY this structure. Do not narrate intermediate steps:

Result: success | partial | blocked
Artifacts changed:
- <path>: <one-line note on what changed>     (include change-summary.md if regenerated, plus every re-rendered diagram path)
Commits:
- <sha>: <commit subject>     (likely empty — diagrams aren't committed by you)
Findings / risks:
- <short bullet, optional — surface notable deviations from requirements.md, decomposition signals, missing-context notes>
Main should read:
- <path>: <reason>     (likely empty — main reads the diagrams folder directly)

Total return must fit under ~1k tokens.
```

#### Step 2.4 — Receive the sub-agent return (main)

Validate that `<dest_dir>` contains the expected `.puml` files (at minimum the mandatory `use-case-<feature>.puml`) and that `<summary_file>` exists with valid frontmatter. If `Result: blocked` or files are missing, surface the failure to the overseer and stop — do not silently advance.

### Existing-vs-new convention (canonical PlantUML snippets — referenced by stage-2 and stage-4 diagram passes)

Use this fixed visual convention so the overseer can read every diagram the same way. The convention uses two colours: **blue for existing**, **green for new (to-be / implemented)**. Both the stage-2 `blueprint-diagrammer` sub-agent and the stage-4 `implementation-analyst` sub-agent embed this section in their working context — keep it in sync if you change either.

- **Existing — blue.** Pre-existing participants/classes/components are grouped in a blue-tinted block: `box "Existing system" #D6EAF8 … end box` (sequence) or `package "Existing" #D6EAF8 { … }` (class / use-case / component). Pre-existing message arrows, activations, and component dependencies use the matching blue stroke / fill: `A -[#3498DB]-> B` for arrows and `#D6EAF8` for activations.
- **New — green.** New participants/classes/components are grouped in a green-tinted block: `box "New" #D4EDDA … end box` (sequence) or `package "New" #D4EDDA { … }` (class / use-case / component). New arrows, activations, and dependencies use green: `C -[#27AE60]-> D` for arrows and `#D4EDDA` for activations. **Do not** use the default (uncoloured) skin for new elements — the colour is part of the convention so the diff is unambiguous.
- Each diagram includes a small legend so the convention is self-documenting:

  ```plantuml
  legend right
    |= |= Meaning |
    |<back:#D6EAF8>   </back>| existing (pre-`base-commit`) |
    |<back:#D4EDDA>   </back>| new in this implementation |
  endlegend
  ```

  At stage 2 the legend's right-column wording shifts to reflect the cycle flavor (see `docs/blueprint-regeneration.md` Step C): for a bugfix cycle the legend reads "current (wrong) behavior" / "corrected behavior"; for an improvement cycle it reads "current capability" / "improved capability"; for greenfield it reads "pre-existing context" / "to be implemented." The colours stay the same — only the legend wording adapts.

### Step 3 — Write diagrams/README.md (main)

**Generate a fresh implementation README** — do NOT copy the blueprint README. The blueprint and implementation README schemas are deliberately distinct: blueprint READMEs require `requirements-id` (and forbid other fields via `additionalProperties: false`), while implementation READMEs require `id` + `stage: implementation` and intentionally do NOT carry `requirements-id` (see `schemas/diagrams-readme-implementation.schema.yaml:8-11` for the rationale).

Use `scripts/uuid.sh` to mint the new id, then write the README manually with the literal frontmatter:

```yaml
---
id: <uuid-from-uuid.sh>
stage: implementation
---
```

Do NOT use `frontmatter.sh init diagrams-readme-implementation` — that path requires `templates/diagrams-readme-implementation.md.tmpl` which does not exist in the repo (`scripts/frontmatter.sh:20` will fail). Then validate the written file: `frontmatter.sh validate <path> diagrams-readme-implementation`.

Body: bullet list of diagrams with a one-line purpose each, with each entry tagged as either `re-rendered` (the sub-agent's Phase 3 freshly rendered this subject from `base-commit..HEAD`) or `seeded-only` (Phase 2 seeded from stage-2; no implementation commits touched this subject's area).

When at least one subject is `seeded-only`, prepend the body with a short convention note:

> *Some subjects below are tagged `seeded-only` — their `.puml` files are verbatim copies of the stage-2 blueprint diagrams. Those subjects had no implementation commits in `base-commit..HEAD`, so the stage-2 design intent is the most accurate available representation. Their legend wording (e.g., "Planned" or "to be implemented") follows stage-2 conventions; interpret them as "design preserved without implementation changes in this cycle." `re-rendered` subjects use the standard stage-4 wording against the `base-commit` baseline.*

If the implementation added a flow that wasn't in `requirements.md`, or omitted one that was, call it out under a `## Notable deviations from requirements` subsection — that's a heads-up for the overseer review at stage 5. The sub-agent will have surfaced these under `Findings / risks` in its return summary; promote the relevant ones into the README here.

### Step 4 — Report

> "Implementation diagrams generated at `$dest_dir` (N diagrams). Existing-system context is shaded; new functionality is highlighted."
