---
description: Render diagrams of the implementation (commit range base-commit..HEAD) into implementation/diagrams/, with pre-existing system context framed alongside the new functionality. Called by /mo-continue at stage 4.
---

# mo-generate-implementation-diagrams

Generates the single set of diagrams the overseer reviews at stage 5. Each diagram shows the **implemented** behaviour of `base-commit..HEAD` with **pre-existing** participants, classes, and flows kept in view as framed/shaded context so the overseer can spot what changed at a glance.

**Main-read budget (stage 4).** Allowed in main: `change-summary.md` (cached via `commits.sh change-summary-fresh`), `progress.md`, drift-probe filesystem state. Forbidden in main: diagram-source generation reads — delegated to a fresh sub-agent (Phase 3.1) under the per-event prompt gate. See `docs/workflow-spec.md` § "Main-read budget gates by stage" for the canonical table.

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

### Step 2 — Ensure `implementation/change-summary.md` is current (AI work)

Diagram generation reads from a cached analysis artifact instead of re-running the codebase scan from scratch. `/mo-update-blueprint` writes the same artifact when it runs in the same stage-4 turn (post-chain drift refresh), so the analysis happens once per `base-commit..HEAD` range.

**Cache contract (load-bearing — do NOT bypass).** The `change-summary-fresh` check is the gate that prevents this command and `/mo-update-blueprint` from independently re-walking the codebase for the same `(base-commit, HEAD)` range. Both consumers MUST call `commits.sh change-summary-fresh` before regenerating; a future change that reads `change-summary.md` directly without the freshness gate would re-introduce the double-walk this cache exists to prevent. See `docs/context optimization/recommendations.md` § "Cache Key Specifications" → `change-summary.md` for the canonical key.

```bash
summary_file="$dest_dir/../change-summary.md"
if $CLAUDE_PLUGIN_ROOT/scripts/commits.sh change-summary-fresh "$active_feature"; then
  echo "change-summary.md is current (cache hit) — reusing"
else
  echo "change-summary.md is missing or stale — regenerating"
  # Fall through to Step 2a.
fi
```

#### Step 2a — Generate or refresh `change-summary.md`

When the freshness check fails (exit 1 = stale, exit 2 = missing), regenerate the artifact:

```bash
requirements_file="$data_root/workflow-stream/$active_feature/blueprints/current/requirements.md"
requirements_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$requirements_file" id)"
base_commit_sha="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get base-commit)"
head_sha="$(git rev-parse HEAD)"
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init change-summary \
  "$data_root/workflow-stream/$active_feature/implementation/change-summary.md" \
  "REQUIREMENTS_ID=$requirements_id" \
  "FEATURE=$active_feature" \
  "BASE_COMMIT=$base_commit_sha" \
  "HEAD=$head_sha"
```

Then fill the body via `Edit`. Source the changed-file list from the script — do **not** re-scan the working tree:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/commits.sh changed-files "$active_feature"
# Emits TSV rows: <status>\t<adds>\t<dels>\t<path>
```

For each file in the changed-files output, decide what depth to inspect using the **bounded context policy** below. Then write each section per the template's guide:

- **`## Range`** — fill `commit count` from `git rev-list --count "$base_commit_sha..HEAD"`.
- **`## Changed files`** — group the TSV rows by area (top-level dir, layer, or feature concern). Format: `<status> <path> (+adds/-dels): <one-line purpose>`. Skip the per-file purpose for trivial files (e.g., simple imports). Do **not** paste full diffs.
- **`## Detected entrypoints`** — public surface introduced or modified: HTTP routes, RPC handlers, CLI commands, scheduled jobs, queue consumers, new exports. One bullet per entrypoint with `<path>:<symbol>`. Skip the section if no public surface changed.
- **`## Suspected flows`** — end-to-end flows the change enables (validated against the actual diagram pass in Step 3). Each entry: `<flow name>: <one-line trace>`.
- **`## Omitted from analysis`** — every changed file you intentionally skipped per the bounded-context policy, listed by path so reviewers can spot blind spots.

#### Bounded context policy

The naive expansion — read every changed file plus all callers/callees — pulls hundreds of lines of unchanged code into the analysis context for moderate-sized diffs. Apply these defaults:

1. **Diff hunks first.** Always read `git diff "$base_commit_sha..HEAD" -- <path>` for every changed file before opening unchanged-side context.
2. **Cap caller/callee expansion at 3 per changed file.** Only open more when a flow would be unreadable without them — and note the expansion in the file's `## Changed files` bullet.
3. **Prefer symbol search over whole-file reads.** If you only need the signature or one function from a caller/callee, grep for it rather than `Read`-ing the whole file.
4. **Skip generated/vendor/lock files.** Default omissions: `dist/`, `build/`, `node_modules/`, `vendor/`, `*.lock`, `package-lock.json`, `yarn.lock`, `Cargo.lock`, `Gemfile.lock`, `*.min.js`, `*.svg`. List anything skipped under `## Omitted from analysis`.
5. **Skip large binary diffs.** Files where `commits.sh changed-files` reports `-/-` for adds/dels are binary; record the path under `## Omitted from analysis` and move on.

When the cache is fresh (Step 2 freshness check exited 0), skip Step 2a entirely — the summary is already correct for the current range.

### Step 2b — Frame diagrams from the cached summary (AI work)

Now build each diagram subject from `change-summary.md` + targeted re-reads:

1. **New** — actors, participants, messages, classes, and flows introduced by `base-commit..HEAD`. Derive from `## Detected entrypoints` and `## Suspected flows`, with diff hunks for the underlying code where needed.
2. **Existing** — the pre-existing participants, classes, and flows the new code touches or sits next to. Derive from the unchanged side of touched files (read only what the bounded context policy allows). Only include enough context to make the new bits legible — do not redraw the whole system.

### Step 2c — Seed `implementation/diagrams/` from `blueprints/current/diagrams/` (Phase 3.5)

Stage 5 review and stage 8 archival both expect `implementation/diagrams/` to be a **complete diagram set** — one file per subject, matching the stage-2 set per `docs/workflow-spec.md` § "Diagram conventions" (subjects/filenames must match across both folders so the overseer can diff equivalent diagrams). If only changed-area diagrams are written to `implementation/diagrams/`, the unchanged subjects would be missing entirely and stage-5 review would be incomplete.

To preserve the complete-set invariant, **seed the `.puml` files** from `blueprints/current/diagrams/` before any selective re-rendering. Copy ONLY `.puml` files — do NOT copy `README.md` (the blueprint and implementation README schemas are deliberately distinct: blueprint READMEs require `requirements-id`; implementation READMEs require `id` + `stage: implementation` and intentionally don't carry `requirements-id`. Copying would fail schema validation either way).

```bash
blueprint_diagrams="$data_root/workflow-stream/$active_feature/blueprints/current/diagrams"
if [[ -d "$blueprint_diagrams" ]]; then
  # Use cp -n so a re-run idempotently preserves any already-generated
  # implementation versions. .puml only — README is generated fresh in Step 4.
  for puml in "$blueprint_diagrams"/*.puml; do
    [[ -f "$puml" ]] || continue
    cp -n "$puml" "$dest_dir/$(basename "$puml")"
  done
fi
```

After this step, `implementation/diagrams/` contains one `.puml` per stage-2 subject. Step 3 then identifies which subjects are affected by `base-commit..HEAD` and re-renders only those — overwriting the seeded copies for affected subjects, leaving unchanged subjects with their stage-2 content.

**Wording caveat for seeded-only diagrams.** Stage-2 and stage-4 conventions share the colour scheme but differ in baseline semantics: stage-2's legend reads "Planned" / "to be implemented" (per the cycle flavor); stage-4's reads "new in this implementation" (against the `base-commit` baseline). For subjects that received no implementation commits this cycle, the seeded `.puml` retains the stage-2 wording verbatim — which is correct (there was no implementation work to recolour, and the stage-2 design intent is the most accurate available representation), but is a presentation deviation from the standard stage-4 convention.

The plan does NOT programmatically rewrite seeded legends (fragile string surgery on PlantUML). Instead, the freshly-generated implementation `README.md` (Step 4) and the stage-5 handoff message in `commands/mo-continue.md` Resume Step 7 surface the convention so the overseer interprets seeded-only diagrams as "design intent preserved without implementation changes in this cycle."

### Step 3 — Generate diagrams (AI + PlantUML MCP)

**Selective re-render (Phase 3.5).** After Step 2c seeded `.puml` files from `blueprints/current/diagrams/`, identify which diagram subjects are actually affected by `base-commit..HEAD`. Sources for the "affected subjects" set:

- `change-summary.md` `## Detected entrypoints` — the new public surface this cycle delivers, mapped back to which diagram subject covers it (e.g., new payment-webhook entrypoint → `sequence-payment-submit.puml`).
- `change-summary.md` `## Suspected flows` — flows the implementation enables, mapped to the matching `sequence-<flow>.puml`.
- `change-summary.md` `## Changed files` grouped by area — areas that map to a structural diagram subject (e.g., `services/payments/` → `class-payment-domain.puml` or `component-payment-pipeline.puml`).

**Re-render the affected subjects only.** Overwrite their seeded `.puml` files in `implementation/diagrams/` with the freshly-rendered content using the existing-vs-new convention against the `base-commit` baseline. **Leave unchanged subjects** (those with no entries in the affected set) as the seeded stage-2 versions — those subjects had no implementation work this cycle, so the stage-2 design intent is the most accurate available representation.

A 30-file change touching only `src/payments/` should re-render only the payments-related diagrams; the audit-log diagrams stay as their stage-2 versions.

**Diagram set caps still apply.** Follow `docs/workflow-spec.md` § "Diagram conventions":

- **`use-case-<feature>.puml`** — mandatory, exactly one. Implemented capabilities with framed actors that pre-existed.
- **`sequence-<flow>.puml`** — 2–3 per feature, one per significant implemented flow. Render 1 only when the implementation genuinely has a single significant flow; **never render more than 3** (if more than 3 candidates exist, pick the most diff-worthy; surface a decomposition signal to the overseer if the count keeps creeping up).
- **One optional structural diagram — `class-<domain>.puml` OR `component-<subject>.puml`, never both.** Read the seam classification from the feature's `blueprints/current/requirements.md` Goals items (carried forward from Step A's codebase-grounding pass). The optional slot fires only when the seam is `backend` or `mixed` AND the implementation meets the content threshold:
  - **Class** when the implementation introduced 3+ new domain classes/modules with non-trivial relationships (inheritance, composition with shared lifecycle, bidirectional association, or branching dependency graph).
  - **Component** when the implementation introduced 3+ new components/modules with non-trivial dependencies (fan-out, fan-in, cross-bucket dependency, or multiple inbound callers) but isn't class-heavy enough for a class diagram.
  - **Linear chains do not qualify** (e.g., `controller → service → repo`). Skip the slot.
  - **One-sentence test.** If you can't articulate the diagram's purpose in one sentence beyond its filename, skip.
  - **Skip for `frontend` / `infra` seams.**

  Pick whichever fits the *implemented* topology best — even if stage-2 picked the other type, the implementation reality wins here. The overseer can compare the matched filenames across both diagram folders; if stage 2 rendered a `class-payment-domain.puml` and stage 4 rendered `component-payment-pipeline.puml`, that mismatch is itself signal that the chain restructured the work, and shows up in the post-chain drift check.

#### Existing-vs-new convention (consistent across all diagrams)

Use this fixed visual convention so the overseer can read every diagram the same way. The convention uses two colours: **blue for existing**, **green for new (to-be / implemented)**.

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

Use the PlantUML MCP (`plantuml` server) to render each diagram. Save the `.puml` source.

**`.puml`-only output by default — gated by `active.diagram-rendering`.** Read the field:

```bash
diagram_rendering="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get diagram-rendering 2>/dev/null || echo 'never')"
```

When `diagram_rendering=never` (default for every feature workflow), produce ONLY the `.puml` source files — do NOT render `.svg` or `.png`. The millwright never reads `.svg` files (they're banned by the review commands' hard exclusion), and PlantUML sources are what the overseer diffs. This is the path for >99% of cycles.

When `diagram_rendering=on-request` (explicitly opted in by the overseer for this feature), render `.svg` alongside `.puml` only on an explicit request — never automatically as part of the generation flow. The "explicit request" trigger is intentionally not wired here yet; the field reserves the lever. If a CI / visual-QA scenario emerges, the trigger can be added without re-plumbing the gate.

### Step 4 — Write diagrams/README.md

**Generate a fresh implementation README** — do NOT copy the blueprint README. The blueprint and implementation README schemas are deliberately distinct: blueprint READMEs require `requirements-id` (and forbid other fields via `additionalProperties: false`), while implementation READMEs require `id` + `stage: implementation` and intentionally do NOT carry `requirements-id` (see `schemas/diagrams-readme-implementation.schema.yaml:8-11` for the rationale).

Use `scripts/uuid.sh` to mint the new id, then write the README manually with the literal frontmatter:

```yaml
---
id: <uuid-from-uuid.sh>
stage: implementation
---
```

Do NOT use `frontmatter.sh init diagrams-readme-implementation` — that path requires `templates/diagrams-readme-implementation.md.tmpl` which does not exist in the repo (`scripts/frontmatter.sh:20` will fail). Then validate the written file: `frontmatter.sh validate <path> diagrams-readme-implementation`.

Body: bullet list of diagrams with a one-line purpose each, with each entry tagged as either `re-rendered` (Step 3 freshly rendered this subject from `base-commit..HEAD`) or `seeded-only` (seeded from stage-2 in Step 2c; no implementation commits touched this subject's area).

When at least one subject is `seeded-only`, prepend the body with a short convention note:

> *Some subjects below are tagged `seeded-only` — their `.puml` files are verbatim copies of the stage-2 blueprint diagrams. Those subjects had no implementation commits in `base-commit..HEAD`, so the stage-2 design intent is the most accurate available representation. Their legend wording (e.g., "Planned" or "to be implemented") follows stage-2 conventions; interpret them as "design preserved without implementation changes in this cycle." `re-rendered` subjects use the standard stage-4 wording against the `base-commit` baseline.*

If the implementation added a flow that wasn't in `requirements.md`, or omitted one that was, call it out under a `## Notable deviations from requirements` subsection — that's a heads-up for the overseer review at stage 5.

### Step 5 — Report

> "Implementation diagrams generated at `$dest_dir` (N diagrams). Existing-system context is shaded; new functionality is highlighted."

## Delegation (optional)

When Step 2a fires (cache miss/stale) and the diff touches many areas, writing the `change-summary.md` body is a good delegation candidate (see `docs/workflow-spec.md` § "Delegation guidance"). One sub-agent at "strong code-analysis, high effort" tier; output artifact is `implementation/change-summary.md`; chat reply stays ≤ 20 lines. The millwright reads the artifact for Step 2b's diagram framing. When the cache is fresh (Step 2 exited 0), no delegation is needed.
