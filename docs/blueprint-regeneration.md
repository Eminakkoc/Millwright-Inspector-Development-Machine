# Blueprint regeneration

Runbook for first-time blueprint generation by **`mo-apply-impact`** at stage 2. Generates the content of `workflow-stream/<feature>/blueprints/current/` — specifically `requirements.md`, `config.md`, and `diagrams/` — from the **active cycle's quest data** (the journal digest captured at stage 1, living under `quest/<active-slug>/`) plus the codebase, scoped to PENDING items for the active feature.

**Journal is NOT a stage-2 input.** The active cycle's `summary.md` (under `quest/<active-slug>/`; the slug is recorded in `quest/active.md`) is the authoritative digest of the journal, written by `/mo-run` at stage 1; stage 2 relies on it instead of re-reading `journal/`. This keeps the data flow one-way (`journal → quest cycle → blueprint → implementation`) and aligns with the design principle restated in `commands/mo-update-blueprint.md` ("journal and quest are intake artifacts that don't drift after stage 1.5"). If the cycle's `summary.md` is missing context this cycle needs, that is a stage-1 quality issue — surface it to the overseer rather than backfilling by re-reading the journal at stage 2.

This runbook is **not** used for mid-cycle blueprint refreshes. After stage 3, the implementation exists and is the source of truth for what the blueprint should reflect; mid-cycle refreshes are handled by `/mo-update-blueprint`, which has its own inline regeneration logic (see `commands/mo-update-blueprint.md` Step 4) that reads from the codebase + previous blueprint instead of quest data.

## Caller contract

Before following these steps, the caller must have:

- `$active_feature` — the kebab-case feature name (from `progress.md`'s `active.feature`).
- `$active_item_ids` — the newline-separated list of PENDING item ids in scope for this cycle. Compute via `todo.sh list PENDING --feature "$active_feature"`.
- An **empty** `blueprints/current/` directory. The caller runs `blueprints.sh ensure-current "$active_feature"` to guarantee the `current/` and `current/diagrams/` subpaths exist.

## Step A — Generate `requirements.md` (AI work)

Resolve the active cycle's quest folder and the workflow data root once and reuse them in the rest of this runbook:

```bash
quest_dir="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh dir)"
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
```

Read `$quest_dir/todo-list.md` and `$quest_dir/summary.md` (the journal digest from stage 1). Do NOT read `journal/` directly — the cycle's `summary.md` is the authoritative digest; stage 2 is purely quest-driven.

`summary.md` is feature-indexed. Read **only** `## Cross-cutting constraints`, `## Out-of-scope`, and `## Feature: <$active_feature>` — other features' sections belong to other cycles. The `features:` frontmatter lists what's available; if `$active_feature` isn't in there, that's a stage-1 quality issue and should be surfaced rather than backfilled.

Also gather the backlog set:

```bash
planned_ids="$($CLAUDE_PLUGIN_ROOT/scripts/todo.sh list TODO --feature "$active_feature")"
```

Create the file. `TODO_ITEM_IDS` must be a comma-separated list — `$active_item_ids` arrives from `todo.sh list` as newline-separated, so reshape it before substituting:

```bash
dest="$data_root/workflow-stream/$active_feature/blueprints/current/requirements.md"
todo_list_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get \
  "$quest_dir/todo-list.md" id)"
todo_item_ids_csv="$(printf '%s\n' "$active_item_ids" | paste -sd, -)"
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init requirements "$dest" \
  "TODO_LIST_ID=$todo_list_id" \
  "TODO_ITEM_IDS=$todo_item_ids_csv" \
  "FEATURE=$active_feature"
```

The schema requires `todo-item-ids` to be a non-empty array of strings. Each item-id (e.g. `PAY-001`, `AUD-002`) is alphanumeric, so the comma-separated list lands cleanly inside the template's `[{{TODO_ITEM_IDS}}]` brackets.

### Codebase-grounding pass (delegated to a fresh sub-agent)

Before writing the requirements body, do a **bounded codebase pass** scoped to the active feature's PENDING todo items. The goal is to anchor each requirement item to the **existing seam** where the change lands (a service folder, a module, a layer, a hook point), so Goals describe a high-level solution sketch rather than a pure restatement of intent. This pass also gives Step C the inputs it needs to render existing-vs-new diagrams.

**Delegate this pass to a fresh sub-agent.** The grounding pass involves reading 5+ candidate files per todo item — those reads, if done in main, accumulate in main context for the rest of the workflow (stages 2 through 8). Instead, spawn a fresh sub-agent (`Agent` invocation with `subagent_type: millwright-overseer-development-machine:codebase-grounder` — explicitly NOT a fork) whose context is disposable. The sub-agent walks the seam, classifies, and writes a structured `grounding-report.md`; main reads that report (small, ~2–4 KB) instead of the seam (large, ~60k tokens).

**Initialize the report.** Before invoking the sub-agent, create the destination file with valid frontmatter so it's writable when the sub-agent fills the body. The sub-agent will overwrite frontmatter fields (notably `seam-classification`) at write time; we just need the skeleton in place:

```bash
impl_dir="$data_root/workflow-stream/$active_feature/implementation"
mkdir -p "$impl_dir"
report_dest="$impl_dir/grounding-report.md"
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init grounding-report "$report_dest" \
  "FEATURE=$active_feature" \
  "SEAM_CLASSIFICATION=mixed"
```

`SEAM_CLASSIFICATION=mixed` is a placeholder; the sub-agent recomputes and overwrites it via `frontmatter.sh set` after analyzing the seam.

**Spawn the sub-agent.** Invoke `Agent` with `subagent_type: millwright-overseer-development-machine:codebase-grounder`. Compose the prompt from the template below. Substitute `<placeholder>` literals with concrete values from the caller context.

Sub-agent prompt template:

```
You are a fresh sub-agent invoked from `mo-apply-impact` Step A to do the stage-2 codebase-grounding pass for the "<active_feature>" feature. Your context is isolated from the main session — main does not see your tool calls, only your final return summary.

**Required first reads:**

1. <quest_dir>/todo-list.md — find the items in scope this cycle: <comma-separated active_item_ids>. Read each item's description.
2. <quest_dir>/summary.md — read `## Cross-cutting constraints` and `## Feature: <active_feature>` sections.

**Your task — for each item id in scope:**

1. Identify the smallest set of existing files / folders / symbols the item naturally touches. Heuristics: keyword grep, neighboring features in the same feature folder, sibling files in the obvious module (e.g., for "add to cart" → `services/`, `routes/`, the existing cart entity if any).
2. Note the seam name (`services/`, `events/`, `domain/cart/`, etc.) and any pre-existing component the new functionality must integrate with (e.g., a base service class, an existing repository, an event bus).
3. **Classify the seam** as one of `backend | frontend | mixed | infra`. Use this allowlist of folder patterns — if multiple buckets match across this item's reads, classify as `mixed`:
   - `backend`: `services/`, `controllers/`, `routes/`, `domain/`, `models/`, `repositories/`, `events/`, `workers/`, `jobs/`, `handlers/`, `api/`.
   - `frontend`: `components/`, `pages/`, `views/`, `screens/`, `hooks/`, `containers/`.
   - `infra`: `migrations/`, `terraform/`, `k8s/`, `ci/`, `scripts/`.

   Projects with non-standard layouts: pick the closest match by intent (a folder of HTTP request handlers is `backend` even if it's named `endpoints/`). When the closest match is genuinely ambiguous, prefer `mixed` over guessing.

4. **Classify the cycle flavor** as one of `greenfield | bugfix | improvement`. Detection rules (apply in order; first match wins):

   - **Bugfix** if the todo description contains an explicit defect signal: keywords like "fix", "bug", "broken", "regression", "crash", "incorrect", "resolve issue", or links to a defect ticket; AND the seam already contains the targeted functionality (the buggy code is what's being fixed).
   - **Improvement** if the seam already contains a working version of the feature the todo names AND the todo description signals enhancement: keywords like "improve", "extend", "optimize", "enhance", "expand", "upgrade", "speed up", "make … faster / more accurate / more reliable".
   - **Greenfield** otherwise — the seam either is empty for this todo or doesn't yet contain the targeted functionality. This is the default; ambiguous items fall here.

**Bounding rules** (this is a stage-2 pass, not a full read of the project):

- Diff hunks aren't available yet — let the todo description and feature folder structure drive your reads.
- ≤ 5 files per todo item; skip generated/vendor/lock/build artefacts. If you needed to read more than that to identify the seam, surface that as a finding/risk in your return summary — main will flag it to the overseer.

**Greenfield case.** If the project is empty or has no relevant existing seams (first-cycle bootstrap), the per-item finding has empty `Pre-existing components` and flavor `greenfield` — that's correct, there's nothing to anchor to. Do not fabricate seams that don't exist yet.

**Write the report.** Fill `<report_dest>` (already initialized with frontmatter by main):

1. **Update the `seam-classification` frontmatter** to the overall classification across all items in this cycle (`backend` if every item is backend; `frontend` if every item is frontend; `mixed` if items span buckets; `infra` if every item is infra). Use `scripts/frontmatter.sh set <report_dest> seam-classification <value>`.
2. **Fill `## Per-item findings`** with one subsection per item id (`### <ITEM-ID> — <description>`) covering: seam, pre-existing components, cycle flavor, notes. Follow the template's example.
3. **Fill `## Overall seam summary`** with 2–4 bullets summarizing the cross-item picture and the classification rationale.
4. Validate the file: `scripts/frontmatter.sh validate <report_dest> grounding-report`.

---

Required return shape — return ONLY this structure. Do not narrate intermediate steps:

Result: success | partial | blocked
Artifacts changed:
- <path>: <one-line note on what changed>
Commits:
- <sha>: <commit subject>
Findings / risks:
- <short bullet, optional>
Main should read:
- <path>: <reason why main needs this>

Total return must fit under ~1k tokens.
```

**Receive the sub-agent return** and proceed. Main now reads `$report_dest` to extract:
- The `seam-classification` frontmatter value (drives Step C's optional-structural-diagram decision).
- The per-item findings (drive the Goals body — phrasing follows the cycle flavor noted in each subsection).
- The overall seam summary (provides the cross-item context for Goals composition).

The grounding pass writes nothing else on its own — the report is the only artifact. The findings feed Goals (below) and the diagrams in Step C.

Then write the requirements body with **three clearly-labeled scope sections**:

1. **`## Goals (this cycle)`** — describe what the active items (`$active_item_ids`) deliver: goals, constraints, acceptance criteria. Each Goals item should **name the existing seam** identified by the codebase-grounding pass above and sketch the high-level solution shape. The phrasing follows the cycle flavor classified in step 5 of the grounding pass:

   - **Greenfield** — phrase as additive: "add a new service under `services/` to handle add-to-cart, plugging into the same request/response contract as the other REST services in that folder."
   - **Bugfix** — phrase as a behaviour change against the existing seam: "change the existing `services/CartService.addItem` path so quantity 0 no longer creates an empty cart row; the corrected behaviour rejects the request with 400 and leaves the cart untouched." Include reproduction conditions and the corrected behaviour inline so the acceptance criteria are explicit.
   - **Improvement** — phrase as an extension or upgrade of the existing capability: "extend the existing `services/CartService.addItem` to also accept bulk-add requests; keep the single-item path unchanged." Be specific about what changes versus what's preserved — the chain at stage 3 needs to know which existing behaviour is load-bearing.

   This is the primary deliverable.

   **Altitude rule (applies to all three flavors).** Name the seam, sketch the integration, describe behaviour at the input/output level; do **not** prescribe code-level details. "Add a service in `services/`" / "change `CartService.addItem` to reject quantity 0" / "extend `CartService.addItem` to accept bulk arrays" are the right altitude. "Add `CartService.addItem(itemId, quantity)` returning `{ ok, cartId }`" is too low — that belongs in the brainstorming spec at stage 3. The seam-naming is a hint, not a contract; the chain may pick a different approach during brainstorming, in which case the stage-4 drift check + `/mo-update-blueprint` flow rotates the blueprint to match.

2. **`## Planned (future cycles)`** — list each unselected TODO item (`$planned_ids`) from the same feature with a short line that names the item id, what it delivers, and **what architectural seam the current implementation needs to leave open for it**. Example:

   ```markdown
   ## Planned (future cycles)

   These items belong to the `authentication` feature and will land in a later cycle. The implementation in this cycle must not lock in choices that would require a rewrite when they arrive.

   - **AUTH-003** — JWT with role claim (Employee | Admin).
     Design guidance: the current session primitive should be wrapped behind a
     narrow interface (`getCurrentUser()` / `requireRole()`) so the underlying
     mechanism can swap to JWT without touching call sites. Do not leak session
     shape (cookies, session table) into domain code.
   ```

   Skip this section entirely if `$planned_ids` is empty.

3. **`## Non-goals (out of scope)`** — reserved for things **explicitly excluded from the feature's roadmap** — captured at stage 1 in the cycle's `summary.md` (any journal-sourced exclusions are already digested there; under `quest/<active-slug>/`), or in `config.md`'s `## Overseer Additions`, or via overseer statements in chat. These are NOT on the TODO list. If there are none, omit the section.

**Critical distinction:** "Planned (future cycles)" items WILL be implemented — just later. The design of this cycle must accommodate them. "Non-goals" items are truly out of scope and can be assumed away.

**Note on scope of `todo-item-ids`.** The array captures the items that *initiated* the current cycle — not every concern discovered during brainstorming. Scope expansions that surface mid-cycle land in the requirements body but do not retroactively invent new todo ids; manage those via `/mo-update-todo-list add ... IMPLEMENTING`.

## Step B — Generate `config.md` (auto + manual sections)

Scan `.claude/skills/` and `.claude/rules/` in the current project. Summarize each skill and rule in one or two lines. Write these summaries **only between the `<!-- auto:start -->` and `<!-- auto:end -->` markers** in the template.

**Relevance filter (critical for token cost).** `config.md` is loaded into the brainstorming primer at stage 3 and re-loaded on every chain re-entry during the review loop. Every line in the auto block costs tokens repeatedly.

**Quantitative budget.** Across the three auto-block sections combined: **≤ 10 entries total, ≤ 2 lines each**. Cite the canonical path on every entry — that lets the chain pull more detail on demand without bloating the primer. If you find yourself wanting more than 10 entries, demote the borderline cases to `## Load on demand` rather than expanding the always-loaded sections.

**Three-tier structure.** The auto block has three sections, in this order:

1. **`## Skills`** — skills that are likely to be consulted while implementing the active Goals. Cycle-specific. Each entry: `- <name>: <one-line reason>; path: .claude/skills/<name>/SKILL.md`.
2. **`## Rules`** — rules that constrain the implementation. Same format with `path: .claude/rules/<name>.md`.
3. **`## Load on demand`** — skills/rules that exist in the project and may apply if a related concern surfaces during brainstorming or review, but aren't required up front for the active Goals. Examples: `mobile-react-native` listed here when the feature is web-only but might cross over later; `ci-templates` when CI changes are possible but not planned. Each entry: `- <name>: <when to load>; path: ...`.

For skills/rules that are clearly off-topic (e.g., `github-actions-templates` when no CI change is in scope and there's no realistic future need this cycle), **omit them entirely** — they remain discoverable via `.claude/skills/` if a need surfaces.

When uncertain whether something is relevant: prefer `## Load on demand` over `## Skills` / `## Rules`. The chain pays nothing for `## Load on demand` entries unless it explicitly opts in.

```bash
requirements_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get \
  "$dest" id)"
config_dest="$data_root/workflow-stream/$active_feature/blueprints/current/config.md"
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init config "$config_dest" \
  "REQUIREMENTS_ID=$requirements_id"
```

Then, using Edit, replace the auto-section placeholder with the real skill/rule summaries. If `config.md` already exists from a prior run (e.g., the overseer aborted and restarted `mo-apply-impact` for the same feature without rotating), preserve content below the `## GIT BRANCH` heading AND below the `## Overseer Additions` heading — only the auto block is overwritten. (This is a same-cycle re-run case. For mid-cycle preservation across rotations, see `commands/mo-update-blueprint.md` Step 4d, which calls `blueprints.sh preserve-overseer-sections`.)

**Pre-fill `## GIT BRANCH` if possible.** Immediately after writing the auto block, check the current HEAD:

```bash
head_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
```

If `head_branch` is non-empty and is NOT `main`, `master`, or `HEAD` (detached) — AND the overseer hasn't already filled the `## GIT BRANCH` section (e.g., from a prior run) — write `head_branch` as the bare line under the heading, above the commented placeholder. This is a convenience default; the overseer can edit it before advancing to stage 3.

If HEAD is `main`/`master`/detached, leave the section unfilled — `/mo-plan-implementation` will prompt the overseer at stage 3.

## Step C — Generate requirement-level diagrams (AI work)

### Step C.0 — Per-event diagram prompt (stage 2)

Read the diagram-prompt setting:

```bash
diagram_prompt="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get diagram-prompt 2>/dev/null || echo 'prompt')"
```

If `diagram_prompt=auto`, skip the prompt and proceed directly to Step C.1 (diagram generation). The overseer opted into auto-generation earlier in this feature's workflow.

If `diagram_prompt=prompt`, ask the overseer:

> "Stage 2 is about to generate blueprint diagrams for `<active_feature>`. Stage-2 approval requires diagrams (use-case + supporting set), so this step is mandatory. Reply:
>   - `y` — generate `.puml` source files now (delegated to a fresh sub-agent; ~30s).
>   - `auto` — generate, and don't ask again for diagrams during the rest of this feature's workflow (resets when the next feature activates)."

The `n` option is intentionally absent. Stage-2 approval requires the blueprint diagram set (`scripts/blueprints.sh check-current` enforces this), so silently allowing `n` would strand the workflow. If the overseer wants to defer, they should run `/mo-abort-workflow` rather than land a partial blueprint.

Wait for the reply. Branch:

- **`y`** — proceed to Step C.1.
- **`auto`** — persist the preference, then proceed to Step C.1:
  ```bash
  $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "diagram-prompt=auto"
  ```

### Step C.1 — Render diagrams (delegated to a fresh sub-agent)

**Delegate the diagram framing + render pass to a fresh sub-agent.** Same context-isolation rationale as Step A: framing the stage-2 diagram set requires reading the cycle's `requirements.md` Goals, the per-item findings in `grounding-report.md`, and a minimal HEAD codebase scan to identify pre-existing system elements. Doing those reads in main accumulates them across the rest of the workflow; doing them inside a fresh sub-agent keeps the reads disposable and main only sees the return summary.

**Spawn the sub-agent.** Invoke `Agent` with `subagent_type: millwright-overseer-development-machine:blueprint-diagrammer`. Compose the prompt from the template below. Substitute `<placeholder>` literals with concrete values from the caller context (`<active_feature>`, `<requirements_path>`, `<grounding_report_path>`, `<diagrams_dir>`, `<diagram_rendering>`).

Sub-agent prompt template:

```
You are a fresh sub-agent invoked from `mo-apply-impact` Step C to frame and render the stage-2 blueprint diagram set for the "<active_feature>" feature. Your context is isolated from the main session — main does not see your tool calls, only your final return summary.

**Required first reads:**

1. <requirements_path> — read `## Goals (this cycle)` to identify the significant end-to-end flows and the new functionality this cycle delivers.
2. <grounding_report_path> — read frontmatter `seam-classification` (drives the optional structural-diagram decision) AND `## Per-item findings` (per-item seam, pre-existing components, cycle flavor — drives the legend wording for each diagram).

**Output destination:** write `.puml` source files into <diagrams_dir>. Do NOT write README.md (main writes that after you return).

**Diagram set caps** (per `docs/workflow-spec.md` § "Diagram conventions"):

- **Mandatory**: one `use-case-<feature>.puml` use-case diagram.
- **Conditional**: one `sequence-<flow>.puml` per significant end-to-end flow from the Goals items, targeting 2–3 total per feature. Render 1 only when the feature genuinely has a single significant flow; **never render more than 3** (if more than 3 candidates exist, pick the most diff-worthy and describe the rest in the Goals prose; if you find yourself wanting 4+, surface a decomposition request under `Findings / risks`).
- **Optional, at most one**: either a `class-<domain>.puml` OR a `component-<subject>.puml`, never both. Fires only when seam-classification is `backend` or `mixed` AND the content threshold is met:
  - **Class** when the feature introduces 3+ new domain classes/modules with non-trivial relationships (inheritance, composition with shared lifecycle, bidirectional association, or branching dependency graph).
  - **Component** when the feature introduces 3+ new components/modules with non-trivial dependencies (fan-out, fan-in, cross-bucket dependency, or multiple inbound callers) but isn't class-heavy enough for a class diagram.
  - **Linear chains do not qualify.** A `controller → service → repo` topology is not "non-trivial" regardless of how many modules it touches; skip the optional slot.
  - **One-sentence test.** Before rendering, write a one-sentence purpose for the diagram beyond the filename. If you can't articulate the value, skip.
  - **Skip for `frontend` or `infra` seams.**

**Existing-vs-new framing.** Stage-2 baseline: `existing` = the current HEAD codebase (read minimally to identify pre-existing system elements the new work integrates with — do not survey the whole repo); `new` = the additions sketched by the Goals items. Apply the canonical blue/green convention:

- pre-existing inside `box "Existing system" #D6EAF8 … end box` (sequence) or `package "Existing" #D6EAF8 { … }` (class / use-case / component); blue arrows `A -[#3498DB]-> B`; `#D6EAF8` activations.
- new inside `box "New" #D4EDDA … end box` or `package "New" #D4EDDA { … }`; green arrows `C -[#27AE60]-> D`; `#D4EDDA` activations.
- Every diagram carries the standard legend block. Right-column wording shifts with the per-item cycle flavor read from `grounding-report.md`:
  - `greenfield` → "pre-existing context" / "to be implemented".
  - `bugfix` → "current (wrong) behavior" / "corrected behavior".
  - `improvement` → "current capability" / "improved capability".
- If the grounding pass found no existing seams for a given diagram (greenfield bootstrap with empty seam), the blue `Existing` block is empty or omitted — render only the green elements and note "no pre-existing context" in the legend.

**Render gate.** Read `<diagram_rendering>` (passed in from main; the `.active.diagram-rendering` field). When `diagram-rendering=never` (the default for >99% of cycles), output ONLY the `.puml` source files via the PlantUML MCP — do NOT produce `.svg` or `.png`. Render `.svg` only when `diagram-rendering=on-request`.

**Bounding rules:** the HEAD codebase read is for grounding the existing-side of each diagram, NOT for re-doing Step A's work. Cap reads at ≤ 3 files per diagram subject; prefer symbol-search over whole-file reads; skip generated/vendor/lock/build artefacts.

---

Required return shape — return ONLY this structure. Do not narrate intermediate steps:

Result: success | partial | blocked
Artifacts changed:
- <path>: <one-line purpose>
Commits:
- <sha>: <commit subject>  (likely empty — diagrams aren't committed by you)
Findings / risks:
- <short bullet, optional — surface decomposition signals or missing-context notes>
Main should read:
- <path>: <reason>  (likely empty — main reads the diagrams folder directly)

Total return must fit under ~1k tokens.
```

**Receive the sub-agent return.** Main now resumes Step C.1's downstream work: validate that `<diagrams_dir>` contains the expected `.puml` files (at minimum the mandatory `use-case-<feature>.puml`) and proceed to write the README below. If the sub-agent returned `Result: blocked` or the expected files are missing, surface the failure to the overseer and stop — do not silently advance.

**Cross-stage convention reference.** The blue/green visual rules are identical to stage 4's; the canonical PlantUML snippets live in `commands/mo-generate-implementation-diagrams.md` § "Existing-vs-new convention". Stage-2 and stage-4 share the convention so the overseer diffs equivalent diagrams with one visual vocabulary — the green set in the stage-2 diagram is what was planned, the green set in the matching stage-4 diagram is what was actually built; matching subjects (same `<type>-<subject>.puml` filename) make the comparison direct.

**Step C.2 — Write `diagrams/README.md` (main).** With the `.puml` files in place, write a `diagrams/README.md` with the `requirements-id` back-reference and a listing of all diagrams. Generate a fresh `id:` UUID for the README via `scripts/uuid.sh` and write it alongside `requirements-id`:

```bash
diagrams_readme="$data_root/workflow-stream/$active_feature/blueprints/current/diagrams/README.md"
drmd_id="$($CLAUDE_PLUGIN_ROOT/scripts/uuid.sh)"
cat > "$diagrams_readme" <<EOF
---
id: $drmd_id
requirements-id: $requirements_id
---

# Diagrams

(one-line description per .puml file in this folder)
EOF
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh validate "$diagrams_readme" diagrams-readme-blueprint >/dev/null
```

This satisfies `blueprints.sh check-current`'s requirement that the README validate against `diagrams-readme-blueprint` with a matching `requirements-id`. The `id:` field follows Rule 2 of the workflow spec.
