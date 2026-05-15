# Implementation Plan — Context Optimization

This document is the consolidated, ordered work list for executing the context-optimization recommendations. It merges the per-stage items you marked with `(*ADD THIS)` in `workflow-simulation.md` with the cross-cutting operational items from `recommendations.md`.

**Scope:** 26 items across 8 phases. Each item is implementation-ready: source pointer, files to touch, change description, acceptance criteria, dependencies, effort estimate.

**How to read it:** Phases run in order. Items inside a phase can largely run in parallel except where `Depends on` is noted. Phase 0 establishes the return-contract standard before any delegation work begins. Phase 7 is deferred — only ship if observed pain warrants the refactor.

**Revision note (post-review):** A reviewer pass on the first draft caught several issues: stage-8 regeneration items described behavior that doesn't exist in the current workflow, `/mi-review` is currently a pure launcher (so Phase 1.3 needs to rewrite the loop into main, not just swap chain for sub-agent), `progress.md` field additions need `scripts/progress.sh` updates not just schema/template changes, and several mechanical errors (schema file extensions, invalid `advance-to` transition, item count mismatch). All addressed in this revision.

---

## Source documents

- **`docs/context optimization/recommendations.md`** — full specification, cost model, architectural principles, options 1A–1B / 2A–2F.
- **`docs/context optimization/workflow-simulation.md`** — stage-by-stage token simulation showing before/after impact. *Note: stage-8 entries in the simulation overstate completion-regeneration cost — current `/mi-complete-workflow` does not regenerate `current/`, only rotates and archives. The savings claimed there shift to stage 2 (next cycle's `/mi-apply-impact`).*
- **`docs/context optimization/optimization-assessment.md`** — peer review of the recommendations.

When this plan references "Option XX" or "Architectural Principle N", look up the detail in `recommendations.md`.

---

## Pre-implementation checklist

Before starting any phase:

1. **Create a feature branch.** `git checkout -b feat/context-optimization` (or split per phase if you want smaller PRs — recommended for review).
2. **Run `/mi-doctor`.** Confirm dependencies are healthy before touching the workflow.
3. **Snapshot a baseline workflow run.** Run a small representative cycle end-to-end on `main` and save the conversation export. After implementation, run the same cycle on the feature branch and compare main-context growth empirically.
4. **Familiarize with the affected files.** The optimizations touch `commands/*.md` (slash-command bodies), `scripts/*.sh` (helpers), `templates/*.tmpl` (artifact templates), and `schemas/*.schema.yaml` (frontmatter validation). Hook-based validation runs after every write — broken frontmatter blocks the workflow.
5. **Decide on phase split.** Each phase is internally cohesive. Phase 0 + Phase 1 together deliver the largest wins and are the recommended first PR.

### Validation tools available

- **`scripts/doctor.sh --preflight`** — fast dependency check.
- **`frontmatter.sh validate <file> <schema>`** — every artifact write should pass validation.
- **`progress.sh`, `quest.sh`, `review.sh`, `commits.sh`** — state-aware helpers that the optimizations build on. Avoid bypassing them.
- **The PostToolUse hook** — catches frontmatter drift after every Edit/Write. Treat hook errors as a forcing function: don't `--no-verify` your way around them.

### Risks summary (full list in `recommendations.md` § "Risks and Pitfalls")

1. **Don't accidentally use forks where fresh sub-agents are needed.** Every "delegate to sub-agent" item below means `subagent_type` set explicitly.
2. **Don't pre-read heavy content in main before delegating.** Pass paths and small slices, not file contents.
3. **Don't skip cache invalidation.** Every cache the plan introduces has a documented key in `recommendations.md` § "Cache Key Specifications".
4. **Don't extend `progress.sh advance-to` outside its whitelist.** The current whitelist is `3→5 | 5→7 | 6→7`. Adjacent transitions use `advance`. Stage-7 finalize uses `progress.sh finish`. Don't invent transitions like `7 -1` — they will be rejected.

---

## Phase 0 — Establish the Sub-Agent Return Contract Standard (PREREQUISITE)

**Why phase zero:** Every delegated item in Phases 1–5 returns a structured summary. If the contract isn't standardized BEFORE the first delegated stage ships, early implementations drift into free-form prose returns and the bloat the delegation was meant to avoid creeps back in. Defining the standard up front and enforcing it via prompt templates is the foundation everything else builds on.

**Estimated effort:** ~0.5 day.

### 0.1 — Sub-Agent Return Contract Standard

**Source:** `recommendations.md` § "Sub-Agent Return Contract Standard".
**Effort:** Small.
**Depends on:** none.

**Files to modify:**
- New: `templates/sub-agent-return.md.tmpl` — the canonical return shape, included by reference in every delegated-stage prompt.
- New: `docs/sub-agent-return-contract.md` — short reference documenting the standard for human readers.
- (No schema yet — return summaries are ephemeral message content, not persisted artifacts. If we later persist them, add the schema then.)

**Changes:**
- Define the canonical return shape:
  ```
  Return only this structure. Do not narrate intermediate steps.

  Result: success | partial | blocked
  Artifacts changed:
  - <path>: <one-line note>
  Commits:
  - <sha>: <subject>
  Findings / risks:
  - <bullet, optional>
  Main should read:
  - <path>: <reason>
  ```
- Total return must fit under ~1k tokens.
- All Phase 1–5 delegated-stage prompt templates will include this contract verbatim at the end of their prompt.

**Acceptance criteria:**
- `templates/sub-agent-return.md.tmpl` exists and contains the contract shape.
- `docs/sub-agent-return-contract.md` documents the standard with an example invocation.
- A minimal test sub-agent invocation following the template produces a return that fits under 1k tokens and parses cleanly.

---

## Phase 1 — Stage 6 Review Loop (P1)

**Why first:** Largest single-stage savings (~205k tokens of main-context relief per cycle in the worst case). Self-contained — does not require P2/P3 work to be in place.

**Estimated combined effort:** ~2.5 days. The bulk is in 1.3 because `/mi-review` is currently a pure launcher and needs to become a main-driven loop driver.

### 1.1 — Stage 5 auto-direct-mode hint persistence (prerequisite)

**Source:** `(*ADD THIS)` at workflow-simulation.md Stage 5 / `recommendations.md` Option 2A prerequisite.
**Effort:** Small.
**Depends on:** none.

**Files to modify:**
- `commands/mi-continue.md` — Inspector Step 1.5 (canonicalization).
- `schemas/progress.schema.yaml` — add `review-mode-suggestion` field to the `active` block (allowed values: `direct | brainstorming | none`; default `none`).
- `templates/progress.md.tmpl` — surface the new field with a default.
- **`scripts/progress.sh` — `activate` and `reset` blocks** (lines ~139 and ~227 currently). Both explicitly construct the `active` object; the new field must be initialized in both paths or it'll be absent when `active` is created.

**Changes:**
- After canonicalization completes and all findings are classified, compute the scope distribution of currently-open findings.
- If 100% are `scope: fix`, set `progress.md` `active.review-mode-suggestion=direct`. Otherwise set `=brainstorming`. Use `none` only when there are zero findings.
- Update `progress.sh activate` to initialize `review-mode-suggestion: none` in the new active block.
- Update `progress.sh reset` to set `review-mode-suggestion: none` (since reset clears runtime state).
- Use a single `progress.sh set` call for the post-canonicalization write so the update is atomic.

**Acceptance criteria:**
- `progress.sh get review-mode-suggestion` returns `direct` after stage 5 when all open findings are fix.
- Returns `brainstorming` when at least one finding has scope ≠ fix.
- Returns `none` immediately after `progress.sh activate` (i.e., before stage 5 has run).
- Field persists across session breaks.
- Schema validator accepts the new field (frontmatter still passes hook).

**Notes:** This is purely a metadata write — no behavior change at stage 5. Item 1.2 consumes the value.

---

### 1.2 — Option 2A: Auto-route to direct mode for fix-only findings

**Source:** `(*ADD THIS)` at workflow-simulation.md Stage 6 / `recommendations.md` Option 2A.
**Effort:** Small.
**Depends on:** 1.1.

**Files to modify:**
- `commands/mi-review.md` — Step 2.6 (review-mode prompt).

**Changes:**
- Read `progress.sh get review-mode-suggestion` at Step 2.6 entry.
- If `direct`, change the prompt's default and rationale: *"All N open findings are simple fixes. Defaulting to direct mode (skips brainstorming chain ceremony). Override by typing `brainstorming` if you want chain dispatch."*
- If `brainstorming` or `none`, keep the current default.
- Persist the actual choice to `active.review-mode` as today.

**Acceptance criteria:**
- Cycle with all-fix findings: pressing Enter at the prompt selects `direct`.
- Cycle with mixed scopes: prompt defaults to `brainstorming` as today.
- Override (typing `brainstorming` when default is direct) still works.

---

### 1.3 — Option 2B: Rewrite `/mi-review` Step 3a into a main-driven loop with fresh per-iteration sub-agents

**Source:** `(*ADD THIS)` at workflow-simulation.md Stage 6 / `recommendations.md` Option 2B.
**Effort:** Medium-Large. **This is the most invasive item in the plan** — it changes `/mi-review` from a pure launcher (which currently hands the entire `go again` loop to the brainstorming Skill) into a main-driven loop driver.
**Depends on:** 0.1 (return contract), 1.1.

**Current behavior to replace.** Per `commands/mi-review.md:7` and `commands/mi-review.md:97`, `/mi-review` is *invoke-and-hand-off*: it sets up the sub-flow, generates `review-context.md`, asks for `review-mode`, then invokes the brainstorming Skill once with a primer that contains the entire loop pattern (steps 1–6 of the loop). The Skill drives the loop; `/mi-review` returns immediately. The inspector types `/mi-continue` after the loop exits.

**New behavior to introduce (brainstorming mode only).** Move the loop into `/mi-review` itself:

1. Setup (unchanged): generate `review-context.md`, write `sub-flow=reviewing`, advance 5→6.
2. Read `review.sh list-open` to get the IR-IDs to address this iteration.
3. Spawn one fresh sub-agent (`subagent_type: general-purpose`, explicitly NOT a fork) with:
   - Path to `review-context.md`
   - Path to `inspector-review.md`
   - The list of open IR-NNN ids to address this iteration
   - The cascade pre-classification primer (item 1.6): for each `re-spec`/`re-plan` finding, pass IR-id + path to relevant plan/spec + 1-line excerpt only (NOT file content).
   - The Phase 0 return contract appended verbatim.
4. Sub-agent does its own reads, edits, commits, and calls `review.sh set-status` per finding.
5. Sub-agent returns the structured summary.
6. Main reads the summary, surfaces it to the inspector, asks `approve | go again | abort`.
7. On `go again`: re-canonicalize any new free-form additions (call `review.sh canonicalize` + `review.sh add` per Inspector Step 1.5), run the body refresh from item 1.4, then loop to step 2.
8. On `approve`: exit cleanly. Tell inspector to type `/mi-continue` to resume mi-workflow (unchanged hand-off contract).
9. On `abort`: invoke `/mi-abort-workflow`.

**Direct mode (Step 3b).** Already runs the loop in main today. Update it only to:
- Adopt the same iteration boundaries (read open IR-IDs once, address all, ask approve/go again/abort).
- Re-canonicalize on `go again` (already does).
- Optionally: when iteration count crosses a threshold or scope mix changes, prompt to switch to brainstorming mode mid-loop (existing item — preserve).

**Files to modify:**
- `commands/mi-review.md` — Step 3a (full rewrite), Step 3b (alignment), Step 4 (hand-off doc updated).
- New (or inline): the sub-agent prompt template that includes the Phase 0 return contract.

**Acceptance criteria:**
- `/mi-review` no longer hands the entire loop to the brainstorming Skill in `brainstorming` mode. Main owns the iteration boundaries.
- Per-iteration main-context growth caps at <1k tokens (the return summary).
- A 4-iteration loop ends with main-context delta under 5k tokens (vs ~200k under current behavior — verify against the simulation file's worst-case scenario).
- Sub-agent commits land in `base-commit..HEAD` as expected.
- `review.sh list-open` decreases as findings are resolved.
- Cascading scopes (`re-spec` / `re-plan`) still work — they happen inside the sub-agent.
- `direct` mode still works and is consistent in iteration boundaries.
- The hand-off contract is unchanged: inspector types `/mi-continue` after `approve` to resume mi-workflow.

**Notes:** This is the single biggest token saving in the entire plan. Test on a real cycle with at least 2 iterations and at least one cascade-scoped finding before merging. Treat regressions in cascade behavior as blockers — the cascade must produce correct outputs even when it runs inside the sub-agent.

---

### 1.4 — Option 2D: Refresh `review-context.md` body each iteration

**Source:** `(*ADD THIS)` at workflow-simulation.md Stage 6 / `recommendations.md` Option 2D.
**Effort:** Small.
**Depends on:** 1.3 (most useful when iterations spawn sub-agents).

**Files to modify:**
- `scripts/review.sh` — extend `sync-refs` with `--refresh-body` flag, OR add `refresh-context` subcommand.
- `commands/mi-review.md` — call the new mode at the start of each `go again` iteration (step 7 of 1.3's loop above).

**Changes:**
- New mode regenerates the `## Implemented surface` and `## Open findings (snapshot)` sections of `review-context.md` from current git state and `review.sh list-open` output.
- Cache key per `recommendations.md` § "Cache Key Specifications" → `review-context.md` body refresh: `(requirements-id, base-commit, HEAD-at-iteration-start)`. Skip the regen if no new commits since the last refresh.

**Acceptance criteria:**
- After an iteration commits new files, the next iteration's `review-context.md` `## Implemented surface` reflects the new files.
- `review-context.md` `## Open findings (snapshot)` matches `review.sh list-open` output exactly.
- Frontmatter `requirements-id` still synced as today.

---

### 1.5 — Approve-with-deferred-findings UX framing

**Source:** `(*ADD THIS)` at workflow-simulation.md Stage 6 / `recommendations.md` § "Approve-with-deferred-findings shortcut".
**Effort:** Small.
**Depends on:** none.

**Files to modify:**
- `commands/mi-continue.md` — Review-Resume Step 1 (open-findings completion check).

**Changes:**
- Reword the `completed | abandoned | abort` prompt to surface deferred-findings as an intentional choice for non-blocking issues.
- Frame `completed` as: *"keep them open and proceed; useful when you and the chain agreed to defer non-blocking follow-up work. The deferred findings remain queryable in the historical record at stage 8."*
- Do NOT auto-default to `completed` — that would mislead inspectors. Keep the prompt explicit.

**Acceptance criteria:**
- The prompt text clearly distinguishes "intentionally deferred" from "abandoned mid-loop".
- No behavior change beyond wording — same dispatch logic.

---

### 1.6 — Pre-classify cascades before invoking the sub-agent

**Source:** `(*ADD THIS)` at workflow-simulation.md Stage 6.
**Effort:** Small.
**Depends on:** 1.3 (cascades happen inside the sub-agent).

**Files to modify:**
- `commands/mi-review.md` — sub-agent prompt template (introduced in 1.3).

**Changes:**
- When the sub-agent prompt is being built and the open findings include any `re-spec` or `re-plan` scope, pre-pass:
  - The IR-NNN id and summary
  - Paths to relevant plan/spec files (from prior iterations or stage 3)
  - 1-line excerpts only (NOT full file content)
- Sub-agent reads the actual plan/spec files inside its own context.
- Critical rule: do NOT pre-fetch large source/spec content in main before invoking the sub-agent.

**Acceptance criteria:**
- Cascade-scoped findings produce correct outputs (chain regenerates plan/spec as expected).
- Main-context delta for a cascade iteration stays bounded (~1-2k tokens for the prompt + return summary).
- No file content is embedded in the sub-agent's prompt verbatim.

---

## Phase 2 — Stage 2 Delegation (P2)

**Why second:** Next-largest stage by main-context cost (~94k → ~25k). Mirrors Phase 1's sub-agent pattern.

**Estimated combined effort:** ~0.5 day.

> **Reviewer note (revision):** The original draft had three additional items here for stage 8 (delegate completion regeneration, skip when fresh, reuse implementation diagrams). Those items described behavior that does not exist in the current workflow — `/mi-complete-workflow` rotates and archives `current/` but does not regenerate it; the next feature's stage 2 (`/mi-apply-impact`) builds the next `current/`. So the savings claimed for stage 8 in the simulation file actually flow to the next cycle's stage 2, which is already addressed by item 2.1 below. The stage-8 items have been removed; if a future change introduces an explicit completion-kind regeneration at stage 8, re-add them as a separate phase with that introduction as a prerequisite.

### 2.1 — Stage 2: Delegate codebase-grounding pass to a fresh sub-agent

**Source:** `(*ADD THIS)` at workflow-simulation.md Stage 2 / `recommendations.md` Architectural Principle 3.
**Effort:** Medium.
**Depends on:** 0.1.

**Files to modify:**
- `commands/mi-apply-impact.md` — Step A (codebase-grounding pass).
- `docs/blueprint-regeneration.md` — update Step A description to reflect delegation.
- `commands/mi-complete-workflow.md` — Step 5 archival list (see lifecycle note below).
- New: `schemas/grounding-report.schema.yaml` (if frontmatter validation is required) and `templates/grounding-report.md.tmpl`.

**Changes:**
- Replace the inline grounding pass with a fresh sub-agent invocation.
- Sub-agent reads the active feature's seam (`src/<feature>/**` plus cross-references), identifies entrypoints / suspected flows / pre-existing classes, and writes a 2–4 KB structured grounding report to `implementation/grounding-report.md`.
- Main reads `grounding-report.md` to compose `requirements.md` / `config.md` / diagrams.
- Sub-agent return: standard contract shape (Phase 0).

**Lifecycle decision — `grounding-report.md`:**
- **Storage:** under `implementation/` (it's audit/debug state derived from the codebase at stage 2 entry; consumed by stage 2 to compose blueprints; useful in the historical record for understanding why the requirements were written the way they were).
- **Archival:** add `grounding-report.md` to the Step 5 archive list in `commands/mi-complete-workflow.md` alongside `inspector-review.md`, `review-context.md`, `change-summary.md`, and `diagrams/`. The archival loop already moves files conditional on existence (`[[ -e ... ]] && mv -n ...`), so adding one more entry is a one-line change.
- **Abort path:** `/mi-abort-workflow` already deletes the live `implementation/` folder; no change needed there.

**Acceptance criteria:**
- `requirements.md` quality matches current behavior (test on representative cycle).
- Main-context growth at stage 2 drops from ~94k to ~25k.
- `grounding-report.md` is generated and used by stage 2.
- After `/mi-complete-workflow` runs, `grounding-report.md` is present at `blueprints/history/v[N+1]/implementation/grounding-report.md`.

---

## Phase 3 — Stage 4 Diagram Delegation (P3)

**Why third:** Moderate cost, multi-touchpoint. The user has explicitly requested per-event inspector prompting before any diagram generation, and explicitly opted out of SVG/PNG rendering by default — both reflected below.

**Estimated combined effort:** ~1 day.

### 3.1 — Per-event inspector prompt + delegate diagram generation when approved (stage-aware)

**Source:** `(*ADD THIS)` at workflow-simulation.md Stages 2/4 + user's reaffirmed preference for per-event prompting.
**Effort:** Medium.
**Depends on:** 0.1.

**Files to modify:**
- `commands/mi-apply-impact.md` (stage 2 — blueprint diagrams).
- `commands/mi-generate-implementation-diagrams.md` (stage 4 — implementation diagrams).
- `commands/mi-draw-diagrams.md` (inspector-invokable wrapper for stage 4).
- `commands/mi-continue.md` — Resume Step 7 stage-5 handoff (~line 644) and Review-Resume Step 2.5 stage-7 refresh prompt (~line 782). Both currently assume implementation diagrams always exist; they need branching for the skipped case.
- `schemas/progress.schema.yaml` — add TWO fields to the `active` block (default values shown):
  - `diagram-prompt: prompt | auto` (default `prompt`) — controls whether to ask the inspector.
  - `implementation-diagrams-skipped: boolean` (default `false`) — records whether the inspector said `n` at stage 4 so downstream stages can distinguish "missing because skipped" from "missing because pending/stale".
  Both are required because the schema sets `additionalProperties: false` on `active`; without these additions, `progress.sh set` will fail validation.
- `templates/progress.md.tmpl` — surface both new fields with their defaults.
- **`scripts/progress.sh` — `activate` and `reset` blocks** (lines ~139 and ~227). Both explicitly construct the `active` object; initialize `diagram-prompt: prompt` and `implementation-diagrams-skipped: false` in both paths.

**Changes — stage-aware prompt behavior:**

The prompt is gated by a hard constraint: stage 2 cannot legally produce a diagramless blueprint. `scripts/blueprints.sh check-current` (line ~465) requires `diagrams/README.md` plus at least one `use-case-*.puml`, and `commands/mi-continue.md` Approve Step 1 (~line 173) blocks the stage-2 approval gate when check-current returns partial. So the prompt at stage 2 cannot offer `n`.

**Stage 2 (mi-apply-impact) — `y` and `auto` only:**

> "Stage 2 is about to generate blueprint diagrams for `<feature>`. Stage-2 approval requires diagrams (use-case + supporting set), so this step is mandatory. Reply:
>   - `y` — generate `.puml` source files now (delegated to a fresh sub-agent; ~30s).
>   - `auto` — generate, and don't ask again for diagrams during the rest of this feature's workflow (resets when the next feature activates)."

The `n` option is intentionally absent. If the inspector needs to defer the workflow, they should use `/mi-abort-workflow` rather than landing a partial blueprint.

**Stage 4 (mi-generate-implementation-diagrams) — `y` / `n` / `auto`:**

> "Stage 4 is about to generate implementation diagrams for `<feature>`. Reply:
>   - `y` — generate `.puml` source files now (delegated to a fresh sub-agent; ~30s).
>   - `n` — skip diagram generation for this stage. The blueprint's stage-2 diagrams remain authoritative; review at stage 5 will reference those.
>   - `auto` — generate, and don't ask again for diagrams during the rest of this feature's workflow (resets when the next feature activates)."

Stage 4's diagrams live under `implementation/diagrams/` and are not gated by `check-current`, so `n` is safe here.

**On `n` at stage 4 — clean any stale directory FIRST, then record the skip.** Order matters for crash safety. Two sequential actions:

1. **If `implementation/diagrams/` already exists** (e.g., from a prior partial run, an aborted previous stage-4 attempt, or re-entry after a session break), remove it.

   ```bash
   data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
   impl_diagrams="$data_root/workflow-stream/$active_feature/implementation/diagrams"
   [[ -d "$impl_diagrams" ]] && rm -rf "$impl_diagrams"
   ```

   The cleanup is intentionally destructive — there's no "are you sure?" prompt, because the inspector just chose `n`. If the directory contained valuable work-in-progress, the right recovery would have been to answer `y` (which preserves prior work via the `cp -n` seed step in 3.5), not `n`.

2. **Then** set `progress.sh set implementation-diagrams-skipped=true`.

**Why this order matters.** If the session breaks between step 1 and step 2, the next `/mi-continue` sees `implementation-diagrams-skipped=false` (default) AND no `implementation/diagrams/` directory — `diagrams-fresh` returns `missing`, which routes to the diagnostic / regeneration recovery path. That is the safe failure mode. The reverse order (marker first, then `rm`) would leave a window where `implementation-diagrams-skipped=true` was persisted but the stale directory still existed, causing stage 8's archival loop (`[[ -d "$impl_dir/diagrams" ]] && mv -n ...`) to silently archive stale `.puml` files into history under a "skipped" cycle — a quiet correctness bug that would only surface during audit reads.

The contract is: **when `implementation-diagrams-skipped=true`, the directory MUST NOT exist.** The ordering above preserves that invariant under crash conditions.

This persisted marker plus directory invariant drive downstream branching:

- **Stage 5 handoff** (`commands/mi-continue.md` Resume Step 7, ~line 644): the inspector prompt currently reads *"Look at: commits `$base_commit..HEAD` and diagrams under `implementation/diagrams`"*. When `implementation-diagrams-skipped=true`, change the wording to: *"Look at: commits `$base_commit..HEAD` and the stage-2 blueprint diagrams under `blueprints/current/diagrams` (implementation diagrams were skipped at stage 4)."* This makes the review target unambiguous.
- **Stage 7 refresh prompt** (`commands/mi-continue.md` Review-Resume Step 2.5, ~line 782): currently assumes implementation diagrams exist and asks whether to refresh them. When `implementation-diagrams-skipped=true`, replace the prompt with: *"Implementation diagrams were skipped at stage 4. The review session committed N additional commits since then. Reply: `y` — generate now (catches the full base-commit..HEAD range; ~30s); `n` — proceed without implementation diagrams (stage-2 diagrams remain the only diagram artifact archived at stage 8)."* If the inspector answers `y`, clear `implementation-diagrams-skipped=false` after generation succeeds.
- **Stage 8 archival** (already filesystem-only): the existing `[[ -d "$impl_dir/diagrams" ]] && mv -n ...` line in `commands/mi-complete-workflow.md` Step 5 handles the missing case correctly — no change required.

**Stage-aware worker inputs (the prompt template diverges between stages):**

- **Stage 2 sub-agent** reads the blueprint-regeneration inputs per `commands/mi-apply-impact.md` and `docs/blueprint-regeneration.md`:
  - `summary.md` (active feature section + cross-cutting)
  - `grounding-report.md` (from item 2.1)
  - The draft `requirements.md` being composed (passed by path)
  - **Does NOT read** `change-summary.md` or `base-commit..HEAD` — those don't exist yet at stage 2.
- **Stage 4 sub-agent** reads:
  - `change-summary.md` (cached via `commits.sh change-summary-fresh`)
  - `base-commit..HEAD` commit range
  - Needed source files for the existing-vs-new framing.
- Both produce `.puml` source files into the appropriate diagrams folder (`blueprints/current/diagrams/` for stage 2; `implementation/diagrams/` for stage 4).
- Both return the standard contract shape (Phase 0) — list of `.puml` files written + one-line purpose each.

**`auto` persistence — scope is per-feature, not per-quest-cycle.**

- The `diagram-prompt` field lives in `progress.md` `active.*`. The `active` block is per-feature: it is constructed by `progress.sh activate` when a feature is popped from the queue, mutated during that feature's stages 2–8, and torn down by `progress.sh finish` (or rebuilt by `progress.sh reset`) when the feature completes. So **`auto` applies to the currently-active feature's workflow only** — it does NOT carry across feature boundaries within the same quest cycle (where multiple features share a `quest/<slug>/` subfolder but each gets its own `active` block).
- If `auto`: persist `active.diagram-prompt: auto` to `progress.md` so subsequent stage 2 / stage 4 invocations within this feature's workflow skip the prompt and proceed directly to generation.
- The field resets to `prompt` automatically when the next feature activates: `progress.sh activate` constructs a fresh `active` block per item 1.1's initialization rule, so `diagram-prompt` defaults back to `prompt` for the next feature. This is intentional — different features in the queue may have different scopes, and the inspector's "auto for this feature" choice should not silently apply to subsequent unrelated work.
- If a future requirement emerges to make `auto` quest-cycle-scoped (e.g., a global "always auto-generate diagrams" preference), the right place is a new top-level `progress.md` field outside `active.*` (alongside `queue` and `completed`), not inside `active`. That's out of scope for this plan but worth flagging.

**Acceptance criteria:**
- Stage 2 prompt offers only `y` / `auto`; rejects `n` with the rationale above.
- Stage 4 prompt offers `y` / `n` / `auto`.
- `auto` persists for the rest of the current feature's workflow and is cleared at the next feature's activation (consistent with the per-feature scope of `active.*` defined above).
- Stage-2 worker prompt template references summary/grounding/draft-requirements; stage-4 worker prompt template references change-summary/base-commit..HEAD.
- `progress.sh get diagram-prompt` returns `prompt` immediately after `activate`.
- `progress.sh get implementation-diagrams-skipped` returns `false` immediately after `activate`.
- Schema validator accepts both new fields.
- Stage-2 approval still passes `check-current` after generation (blueprint diagrams produced as required).
- Stage-4 main-context growth drops from ~51k to ~5k when generation is approved.
- **On stage-4 `n`:** `implementation-diagrams-skipped` is set to `true` AND `implementation/diagrams/` does not exist on disk after the prompt is answered (any pre-existing directory from prior runs was removed).
- **On a subsequent stage-4 `y` or stage-7 generation:** `implementation-diagrams-skipped` is reset to `false` after the diagrams are written.

**Notes:** The `n`-disallowed-at-stage-2 constraint is load-bearing — silently allowing `n` at stage 2 would break the approve gate and strand the workflow. If a future change makes diagrams optional in `check-current`, revisit this constraint and update the prompt.

---

### 3.2 — `.puml`-only output by default; SVG/PNG never rendered without explicit request

**Source:** `(*ADD THIS)` at workflow-simulation.md Stages 2 and 4 + user's reaffirmed preference.
**Effort:** Small.
**Depends on:** 3.1.

**Files to modify:**
- `commands/mi-generate-implementation-diagrams.md` — gate any SVG/PNG rendering.
- `commands/mi-apply-impact.md` — same gating at stage 2.
- `schemas/progress.schema.yaml` — add `diagram-rendering: never|on-request` field to `active` (default `never`).
- `templates/progress.md.tmpl` — surface the new field with a default of `never`.
- **`scripts/progress.sh` — `activate` and `reset` blocks.** Both explicitly construct the `active` object; the new field must be initialized in both paths.

**Changes:**
- Hard-code `.puml`-only output. SVG/PNG rendering never runs implicitly.
- The `diagram-rendering` field defaults to `never`. Even when set to `on-request` (e.g., via inspector typing a follow-up command after the per-event prompt), rendering happens only on an explicit request, not automatically as part of generation.
- Update `progress.sh activate` and `reset` to initialize `diagram-rendering: never`.

**Acceptance criteria:**
- Default cycle generates only `.puml` files. No `.svg` or `.png` files are produced under any default flow.
- `progress.sh get diagram-rendering` returns `never` immediately after `activate`.
- A future explicit "render to SVG" command (out of scope for this plan but unblocked by this item) can flip the field to `on-request` and trigger rendering.

---

### 3.3 — Stage 4: Change-summary cache reuse verification

**Source:** `(*ADD THIS)` at workflow-simulation.md Stage 4 (added per reviewer dependency).
**Effort:** Small (mostly verification).
**Depends on:** 3.1.

**Files to modify:**
- `commands/mi-generate-implementation-diagrams.md` — verify `commits.sh change-summary-fresh` is called before generation.
- `commands/mi-update-blueprint.md` — same verification on its existing regeneration path (note: only `manual`, `spec-update`, `re-spec-cascade`, `re-plan-cascade` reasons exist today; completion is reserved for `/mi-complete-workflow` per `commands/mi-update-blueprint.md`).

**Changes:**
- Confirm both call sites use the cache key check; regenerate `change-summary.md` only on cache miss.
- Add a regression test (or manual checklist item) so future changes don't re-introduce double-walks.

**Acceptance criteria:**
- A second invocation of `/mi-draw-diagrams` within the same `(base-commit, HEAD)` range does not regenerate `change-summary.md`.

---

### 3.4 — Stage 4: Skip diagram regeneration when no commits since last diagrams

**Source:** `(*ADD THIS)` at workflow-simulation.md Stage 4 / `recommendations.md` § "Diagram set freshness" cache key.
**Effort:** Small.
**Depends on:** 3.1 (uses the `implementation-diagrams-skipped` marker introduced there).

**Files to modify:**
- `scripts/commits.sh` — add `diagrams-fresh <feature>` subcommand.
- `commands/mi-generate-implementation-diagrams.md` — call before regenerating.
- `commands/mi-continue.md` — update Review-Resume Step 2.5's `new_since_diagrams` calculation (~line 789) to handle the skipped case.

**Changes:**

**Multi-state freshness output.** The new `commits.sh diagrams-fresh <feature>` returns one of four states. Three are normal-flow outcomes; the fourth is a diagnostic exit reserved for invariant violations:

- `fresh` (normal) — `implementation/diagrams/` exists with `.puml` files AND no commits since the last diagram render commit.
- `stale` (normal) — `implementation/diagrams/` exists but new commits have landed since the last render commit.
- `skipped` (normal) — `progress.sh get implementation-diagrams-skipped` returns `true`. By contract, no `.puml` files exist (see the directory-invariant note in 3.1).
- `missing` (diagnostic) — neither `skipped=true` nor `.puml` files exist. This violates the directory invariant and should not occur in normal flow; the script surfaces a diagnostic message and exits non-zero. Callers route to a recovery prompt rather than silently regenerating.

The first three are the routing inputs that the call sites (auto-stage-4, inspector-invoked `/mi-draw-diagrams`, stage-7 refresh) switch on. `missing` is treated as an out-of-band error condition — implement it as a non-zero exit so a forgotten branch in a caller doesn't silently fall through.

Cache key for `stale` detection: `(base-commit, latest-commit-touching-implementation/diagrams/)`.

**Caller behavior:**

- **`/mi-draw-diagrams` (stage 4 entry — auto-invoked by stage 4):** if `fresh`, tell the inspector "diagrams already current" and skip the sub-agent. If `stale` or `missing`, proceed with generation (after the 3.1 prompt). If `skipped`, do nothing — the 3.1 prompt at stage 4 has already happened and persisted the marker (the auto-invoke flow does not re-prompt).
- **`/mi-draw-diagrams` (inspector-invoked manually):** the inspector might invoke `/mi-draw-diagrams` directly between stages 4 and 7 to recover from a stage-4 skip they regret. **Treat `skipped` as a recovery affordance**, not a no-op:
  - If `skipped`: prompt the inspector with *"Stage-4 diagrams were skipped earlier this cycle. Generate them now? Reply `y` (delegated to a fresh sub-agent; ~30s) or `n` (keep the skip)."* On `y`, run the seed-then-render flow from 3.5 against the current `base-commit..HEAD` range. After generation succeeds, clear the marker: `progress.sh set implementation-diagrams-skipped=false`. On `n`, exit without changes.
  - Optional: accept a `--force` (or `--generate`) flag that bypasses the prompt and proceeds directly to generation, with the same marker reset on success. Useful for scripted recovery.
  - If `fresh` / `stale` / `missing`: behave as today.
- **Stage 7 refresh** (`commands/mi-continue.md` Review-Resume Step 2.5): the current calculation `new_since_diagrams="$(git rev-list --count "${diagram_commits:-$base_commit}..HEAD")"` falls back to `base_commit` when no diagram commit exists, which would erroneously prompt for refresh after a skip. Replace the calculation with: first call `commits.sh diagrams-fresh`. If `skipped`, route to the modified prompt described in item 3.1 (offer `y`/`n` to generate; clear the marker on `y` after success). If `fresh`, skip the prompt entirely. If `stale`, run the existing refresh prompt. If `missing`, surface a diagnostic and prompt for generation.

**Acceptance criteria:**
- `commits.sh diagrams-fresh <feature>` returns the correct state for all four cases.
- `/mi-draw-diagrams` invoked twice in a row (no new commits in between) does not re-render.
- A cycle that skipped stage-4 diagrams reaches stage 7 with the appropriate "previously skipped" prompt, not the regular refresh prompt.
- After stage-7 generation succeeds, `implementation-diagrams-skipped` is reset to `false`.

---

### 3.5 — Stage 4: Render only changed-area diagrams (with seed-from-blueprints)

**Source:** `(*ADD THIS)` at workflow-simulation.md Stage 4.
**Effort:** Small.
**Depends on:** 3.1, 3.4.

**Files to modify:**
- `commands/mi-generate-implementation-diagrams.md` — owns the seed-then-render flow, the fresh implementation README generation, and the selective re-render logic.
- `commands/mi-continue.md` — Resume Step 7 (~line 644 stage-5 handoff). 3.5 owns the **"diagrams generated, some seeded-only"** wording case (i.e., when diagrams exist but some subjects are verbatim from stage 2). 3.1 owns the disjoint **"diagrams skipped entirely"** wording case (i.e., when `implementation-diagrams-skipped=true`). Both wording variants live in the same Resume Step 7 handoff prompt — implement them as branched messages keyed off the sub-agent return summary's seeded-only count and the skip marker respectively.
- `scripts/uuid.sh` — invoked from the sub-agent prompt to mint the new README's id; no code changes expected, just usage.

**Constraint to honour.** Stage 5 review and stage 8 archival both expect `implementation/diagrams/` to be a **complete diagram set** (one file per subject, matching the stage-2 set per `docs/workflow-spec.md:354`: *"Subjects/filenames should match the implementation diagrams rendered at stage 4 so the inspector can diff equivalent diagrams across the two folders."*). If item 3.5 only writes affected diagrams to `implementation/diagrams/`, the unchanged subjects would be missing entirely — making the stage-5 review and stage-8 archive incomplete.

**Three-step approach:**

1. **Seed `.puml` files only from `blueprints/current/diagrams/`.** On stage-4 entry (after the 3.1 prompt approves generation), the sub-agent copies every `.puml` file (and ONLY `.puml` files — not `README.md`) from `blueprints/current/diagrams/` to `implementation/diagrams/`. Use `cp -n` so a re-run idempotently preserves any already-generated implementation versions.
2. **Generate a fresh implementation `README.md` using the existing manual write path.** The blueprint and implementation README schemas are deliberately distinct: blueprint READMEs require `requirements-id` (and forbid other fields via `additionalProperties: false`), while implementation READMEs require `id` + `stage: implementation` (and intentionally do NOT carry `requirements-id` — see `schemas/diagrams-readme-implementation.schema.yaml:8-11` for the rationale). Copying the blueprint README would fail schema validation either way.

   Use the existing pattern documented in `commands/mi-generate-implementation-diagrams.md:121-132`: mint a new `id` via `scripts/uuid.sh`, then write the README directly with frontmatter:

   ```yaml
   ---
   id: <uuid-from-uuid.sh>
   stage: implementation
   ---
   ```

   Body: bullet list of diagrams with one-line purpose each, plus the seeded-only convention note when applicable (see Wording caveat below). Do NOT use `frontmatter.sh init diagrams-readme-implementation` — that path requires `templates/diagrams-readme-implementation.md.tmpl` which does not exist in the repo (`scripts/frontmatter.sh:20` will fail). If a future change introduces the template, this step can switch to `init`; for now the manual write path is what `mi-generate-implementation-diagrams.md` already uses.
3. **Selective re-render.** Sub-agent identifies which diagram subjects are affected by `base-commit..HEAD`. It re-renders only those subjects — overwriting the seeded copies for affected subjects. Unchanged subjects keep their stage-2 `.puml` content as-is (see "Wording caveat" below).

**Wording caveat for seeded-only diagrams (Finding #3 trade-off).** The stage-2 and stage-4 diagram conventions share the existing-vs-new colour scheme but differ in baseline semantics: stage-2 paints "blue = current HEAD codebase, green = planned new functionality"; stage-4 paints "blue = `base-commit`, green = `base-commit..HEAD`" — and the legend wording reflects each. **Seeded-only diagrams retain stage-2 wording** (e.g., legend may read "Planned" or "To be implemented"). For subjects that received no implementation commits in this cycle, this is correct in the strong sense — there literally was no implementation work to recolour, and the stage-2 design intent is the most accurate representation available. But it is a presentation deviation from the standard stage-4 convention.

Two ways to handle this; the plan picks the second by default:

- **Option A — Legend normalization (rejected as default):** Programmatically rewrite each seeded `.puml` to swap "Planned" → "Not implemented in this cycle" or similar. This requires fragile string surgery on PlantUML legend blocks and risks breaking customised legends. Only worth implementing if seeded-wording confusion becomes a real inspector pain point.
- **Option B — Document and message (default):** Keep seeded `.puml` content verbatim. Mention the convention in the freshly-generated implementation `README.md` body. Stage-5 handoff messaging (item 3.1's `commands/mi-continue.md` updates) calls it out explicitly: *"Subjects with no commits in `base-commit..HEAD` show the stage-2 design as-is — interpret these as 'design intent preserved without implementation changes in this cycle.'"*

**Changes:**
- Sub-agent prompt template (introduced in 3.1) is extended with the three-step instruction (seed `.puml` → fresh implementation README → selective re-render).
- Sub-agent reads the seed source (`blueprints/current/diagrams/*.puml`) plus the implementation context (`change-summary.md` + `base-commit..HEAD`) needed to re-render affected subjects.
- Sub-agent invokes `scripts/uuid.sh` to mint the new id, writes the README manually with the literal frontmatter (`id` + `stage: implementation`) per the pattern in `commands/mi-generate-implementation-diagrams.md:121-132`, then validates the written file against `schemas/diagrams-readme-implementation.schema.yaml` (e.g., via `scripts/frontmatter.sh validate <path> diagrams-readme-implementation`). Do NOT use `frontmatter.sh init` — see the rationale at the manual-write-path step above.
- Sub-agent return summary lists each diagram with its disposition: `seeded-only` (verbatim from stage-2) or `re-rendered` (affected) — and confirms the README was generated fresh.
- Update stage-5 handoff wording in `commands/mi-continue.md` Resume Step 7 to include the seeded-only convention note when the diagram set contains any seeded-only subjects.

**Acceptance criteria:**
- After stage 4 generation, `implementation/diagrams/` contains one `.puml` per stage-2 subject AND a fresh `README.md` that validates against `diagrams-readme-implementation.schema.yaml` (has `id`, has `stage: implementation`, has NO `requirements-id`).
- A change touching only `src/payments/` re-renders the payments diagram and leaves the audit-log diagram as the verbatim stage-2 `.puml`.
- Seeded-only `.puml` files have content equal to the corresponding `blueprints/current/diagrams/` files (verifiable with `diff`).
- The fresh implementation README mentions the seeded-only convention when applicable so the inspector reading at stage 5 understands the wording difference.
- Stage 5 review and stage 8 archival can read from `implementation/diagrams/` alone without needing to consult `blueprints/current/diagrams/` for missing subjects.

---

## Phase 4 — Stage 1.5 Cleanup (P4)

**Why fourth:** Architectural correctness fix. Smaller token impact than P1–P3 but closes the "intake stages don't read code" violation. Scope is narrow.

**Estimated combined effort:** ~0.5 day.

### 4.1 — Option 1A: Drop codebase scan from stage 1.5

**Source:** `recommendations.md` Option 1A.
**Effort:** Small.
**Depends on:** none.

**Files to modify:**
- `commands/mi-continue.md` — Pre-flight Step 2A item 4.
- `docs/workflow-spec.md:289, 591` — update text to reflect journal-only ordering.

**Changes:**
- Remove the codebase-grep step from Pre-flight Step 2A item 4.
- Replace with a journal-only ordering pass: scan `summary.md` `## Cross-cutting constraints` and feature sections for cross-references.
- The proposal to the inspector is based purely on journal signals.

**Acceptance criteria:**
- Stage 1.5 does not invoke any source-file Read or grep tools.
- Queue ordering proposal is generated from `summary.md` content.

---

### 4.2 — Option 1A.5: Heuristic short-circuit

**Source:** `(*ADD THIS)` at workflow-simulation.md Stage 1.5.
**Effort:** Small.
**Depends on:** 4.1.

**Files to modify:**
- `commands/mi-continue.md` — Pre-flight Step 2A.

**Changes:**
- Implement a heuristic check on `summary.md` body: regex for feature names appearing in another feature's section, or dependency keywords ("depends on", "blocks", "requires").
- If no signals → emit the journal-only proposal, done.
- If signals present → fall through to Option 1B (item 4.3).

**Acceptance criteria:**
- Cycle with no cross-feature mentions in `summary.md`: skips 1B entirely.
- Cycle with mentions: invokes 1B's sub-agent fallback.

---

### 4.3 — Option 1B: Fresh sub-agent fallback for code-aware ordering (with cache)

**Source:** `(*ADD THIS)` at workflow-simulation.md Stage 1.5 / `recommendations.md` Option 1B.
**Effort:** Small.
**Depends on:** 0.1, 4.2.

**Files to modify:**
- `commands/mi-continue.md` — Pre-flight Step 2A.
- `schemas/queue-rationale.schema.yaml` — add cache-key fields to frontmatter.
- `templates/queue-rationale.md.tmpl` — surface the cache fields.

**Changes:**
- Sub-agent (`subagent_type: general-purpose`) inspects cross-feature imports and writes the `queue-rationale.md` body directly.
- Sub-agent return: 2-3 sentence summary (Phase 0 contract shape).
- Cache key per `recommendations.md` § "queue-rationale.md cache": `(cycle-slug, ordered-feature-ids, summary-md-hash, HEAD-when-scanned)`.
- On subsequent `/mi-continue` invocations within the same cycle: read the cached `queue-rationale.md` instead of re-scanning.

**Acceptance criteria:**
- First `/mi-continue` after marking selections: spawns sub-agent (when 4.2 said "needed").
- Second `/mi-continue` within the same cycle: hits cache, no sub-agent.
- Cache invalidates if `summary.md` body changes or HEAD moves.

---

## Phase 5 — Smaller Wins (P5)

**Why fifth:** Long-tail optimizations. Each is small individually but cumulatively meaningful.

**Estimated combined effort:** ~1 day across all five.

### 5.1 — Option 2E: Tighten `change-summary.md` body

**Source:** `(*ADD THIS)` at workflow-simulation.md Stage 6 / `recommendations.md` Option 2E.
**Effort:** Small.
**Depends on:** none.

**Files to modify:**
- `scripts/commits.sh` — `change-summary` generation logic.
- `templates/change-summary.md.tmpl` — section guidance.

**Changes:**
- Bound diff excerpts: max 50 lines per file, max 500 lines total across all files.
- File index remains the dominant content.
- Add a `truncated: <count>` marker when bounds are hit so consumers know to look at git directly for full diff if needed.

**Acceptance criteria:**
- A change with one giant diff stays under 500 lines in `change-summary.md`.
- Consumers (stages 4, 6, 8) still derive correct file lists.

---

### 5.2 — Stage 1: Per-folder summarization for many small files

**Source:** `(*ADD THIS)` at workflow-simulation.md Stage 1.
**Effort:** Small.
**Depends on:** 0.1.

**Files to modify:**
- `commands/mi-run.md` — Step 2.5 (size manifest and threshold check).

**Changes:**
- Add a folder-level threshold: `>5 files AND >40 KB total per folder` triggers per-folder summarization.
- One sub-agent per folder produces a single digest covering all files in that folder, with source-file attribution.
- Existing per-file threshold (>100 KB single, >500 KB total) remains.
- Sub-agent return: standard contract shape (Phase 0).

**Acceptance criteria:**
- A folder with 20 small notes (50 KB total) triggers one sub-agent.
- A folder with 3 small notes does not trigger delegation.
- Source-file attribution is preserved in the digest.

---

### 5.3 — Stage 3: Primer hints

**Source:** `(*ADD THIS)` at workflow-simulation.md Stage 3 / `recommendations.md` § "Stage 3 launcher hints".
**Effort:** Small.
**Depends on:** none.

**Files to modify:**
- `templates/primer.md.tmpl`.
- `commands/mi-plan-implementation.md` — Step 3.5 (primer composition).

**Changes:**
- Add concrete threshold language to the primer:
  - *"Prefer subagent-driven-development for tasks touching >3 files OR >100 LOC."*
  - *"For features under 500 LOC, consider direct planning mode (skips chain ceremony)."*
- The chain reads these hints as guidance, not directives.

**Acceptance criteria:**
- Generated `primer.md` includes the threshold language.
- Chain still functions normally (these are hints, not enforced rules).

---

### 5.4 — Stage 3: Pre-pass tighter skill metadata

**Source:** `(*ADD THIS)` at workflow-simulation.md Stage 3.
**Effort:** Small.
**Depends on:** none for the basic implementation. **Soft dependency on 6.5** (artifact excerpt commands) — if 6.5 has already shipped, this item uses the excerpt commands for cleaner extraction; if not, it falls back to reading `config.md` directly via existing tools (`frontmatter.sh get` + section grep). Both paths produce equivalent results; only the implementation cleanliness differs.

**Files to modify:**
- `commands/mi-plan-implementation.md` — primer composition.
- `commands/mi-apply-impact.md` — `config.md` skill/rule filtering at stage 2.

**Changes:**
- Stage 2 already produces `config.md`'s `## Skills`, `## Rules`, `## Load on demand` tiers.
- At stage 3, primer reads only the filtered three-section list, not the raw `.claude/skills/` and `.claude/rules/` directories.
- If `config.md` skill list is small (≤10), pass inline. Otherwise reference the file path.
- Implementation note: prefer using 6.5's excerpt commands when available; otherwise extract sections directly. Either path satisfies the acceptance criteria.

**Acceptance criteria:**
- Stage 3 does not enumerate `.claude/skills/` directory contents.
- Chain still has access to relevant skills via the filtered list.

**PR note:** If 6.5 has not yet landed when 5.4 is implemented, ship the direct-extraction path and document a TODO to switch to excerpt commands once 6.5 is available. This keeps PR 5 implementable without waiting for PR 6.

---

### 5.5 — Stage 8: Atomic finalize and lazy archival validation

**Source:** `(*ADD THIS)` at workflow-simulation.md Stage 8.
**Effort:** Small.
**Depends on:** none.

**Files to modify:**
- `commands/mi-complete-workflow.md` — finalize sequence.
- `scripts/blueprints.sh` — archival logic.
- `scripts/progress.sh` — possibly extend `finish` to accept `--set field=value` pairs (mirror of the existing `advance-to ... --set` pattern) so the finalize write is atomic.

**Changes:**
- The current `progress.sh advance-to` whitelist is `3→5 | 5→7 | 6→7`; do NOT introduce a `7 → -1` transition. Stage finalization correctly uses `progress.sh finish` (per `commands/mi-complete-workflow.md` Step 6).
- Where multiple `progress.sh set` calls precede `progress.sh finish`, consolidate them: optionally extend `finish` to accept `--set field=value` pairs so the whole finalize write is atomic. This mirrors the `advance-to ... --set` pattern.
- Skip frontmatter re-validation on archived files (they're frozen post-rotation). The archive loop in Step 5 already uses `mv -n` for idempotency; ensure no validation hooks fire on the moved files in the archive directory.

**Acceptance criteria:**
- A session break mid-finalize does not strand state half-advanced.
- Archive operation does not invoke `frontmatter.sh validate` on `change-summary.md` or `review-context.md` after they're archived.
- `progress.sh finish` accepts the same atomic-write pattern as `advance-to` if extended (optional but recommended).

---

## Phase 6 — Operational Discipline (P6) — cross-cutting

**Why sixth:** Without these, the Phase 1–5 gains erode over time. Implement after the per-stage work so the targets exist. (The Sub-Agent Return Contract Standard, originally listed here, has been moved to Phase 0 because every Phase 1–5 delegated stage depends on it.)

**Estimated combined effort:** ~1 day.

### 6.2 — Cache Key Specifications enforcement

**Source:** `recommendations.md` § "Cache Key Specifications".
**Effort:** Small (mostly documentation + verification).
**Depends on:** 1.4, 2.1, 3.4, 4.3 (each introduces or tightens a cache).

**Files to modify:**
- `schemas/*.schema.yaml` for any artifact gaining new cache fields.
- `scripts/*.sh` — cache freshness checks.

**Changes:**
- For each cache (`change-summary.md`, `queue-rationale.md`, `review-context.md` body, diagram set), confirm the cache key is documented in `recommendations.md` and implemented in code.
- Add invariant assertions: every freshness-check function declares its output enum and the call site handles every value in that enum. The simple caches (e.g., `change-summary.md`) use a three-state output (`fresh | stale | missing`); `diagrams-fresh` uses a four-state output (`fresh | stale | skipped | missing`) per item 3.4 because of the explicit-skip case. The invariant is *per-cache enum exhaustiveness*, not a fixed state count across caches.

**Acceptance criteria:**
- Each cache has a corresponding `*-fresh` script function.
- A sentinel test (intentionally tampering with a cache key field) causes the next freshness check to return `stale`.

---

### 6.3 — Main-Read Budget Gates per stage

**Source:** `recommendations.md` § "Main-Read Budget Gates by Stage".
**Effort:** Medium.
**Depends on:** Phases 1–5 establish the budgets.

**Files to modify:**
- Each `commands/*.md` slash command body — add an entry-time budget self-check.

**Changes:**
- At command entry, document and enforce the stage's allowed reads per the budget table.
- If a command would exceed its budget, either delegate or surface an explicit override prompt to the inspector.
- Override prompts should be rare and intentional — they signal scope creep that needs review.

**Acceptance criteria:**
- A test where stage 1.5 is forced to read source code triggers the override prompt (not a silent budget violation).
- Each command's documentation lists its budget in a "Main-read budget" subsection.

---

### 6.4 — Context-Budget Instrumentation (`context-ledger.md`)

**Source:** `recommendations.md` § "Context-Budget Instrumentation".
**Effort:** Small.
**Depends on:** none, but most useful after Phases 1–5.

**Files to modify:**
- New: `scripts/ledger.sh` — `append <stage> <command> <files> <class> <location> <artifact>` helper.
- New: `templates/context-ledger.md.tmpl`.
- New: `schemas/context-ledger.schema.yaml`.
- Each command that performs a context-heavy read or delegation appends a row.

**Changes:**
- `quest/<active-slug>/context-ledger.md` records stage / command / files / class (small/medium/large) / location (main/sub-agent) / artifact.
- Ledger rotates with the cycle subfolder; archived under quest history.

**Acceptance criteria:**
- After a complete cycle, `context-ledger.md` has rows for every context-heavy event.
- A regression where a stage starts reading code in main shows up as a `large` class read with `location=main` in an unexpected stage.

---

### 6.5 — Artifact Excerpt Commands

**Source:** `recommendations.md` § "Artifact Excerpt Commands".
**Effort:** Small.
**Depends on:** none.

**Files to modify:**
- `scripts/quest.sh` (or new `summary.sh`) — `feature-section <feature>` subcommand.
- `scripts/review.sh` — `list-open-summaries` subcommand.
- `scripts/commits.sh` — `changed-files-only` subcommand.

**Changes:**
- Each subcommand emits a slice of a larger artifact (one feature section, open IR-IDs with summaries, file index without diff).
- Stages that currently read whole files are updated to use these where appropriate.

**Acceptance criteria:**
- `quest.sh feature-section payments` emits only the cross-cutting + payments sections from `summary.md`.
- `review.sh list-open-summaries` emits IR-IDs + severity + scope + summary, no details body.
- `commits.sh changed-files-only` emits the file index without diff hunks.

---

## Phase 7 — Deferred (P7)

**Why deferred:** Larger refactor that touches Skill-level prompts (brainstorming, writing-plans), not just mi-workflow. Only ship if observed pain warrants.

### 7.1 — Option 2F: Delta primers for cascades

**Source:** `recommendations.md` Option 2F.
**Effort:** Large.
**Depends on:** 1.3 (cascade behavior is now in sub-agents).

**Files to modify:**
- Brainstorming Skill prompt (out-of-tree — coordinate with the chain author).
- Writing-plans Skill prompt (same).
- `commands/mi-review.md` — pre-cascade primer composition (item 1.3's sub-agent prompt).

**Changes:**
- When a cascade fires, pass a delta primer: *"You already produced spec X and plan Y. Finding IR-NNN invalidated steps 3-5. Regenerate only those steps; keep 1-2 and 6+ verbatim."*
- Chain regenerates only the affected sections.

**Acceptance criteria:**
- A cascade for an isolated finding does not re-derive the full plan/spec.
- Decision: only ship if real cycles show repeated `re-spec`/`re-plan` cascades imposing meaningful cost.

---

## Tracking table

All items at a glance. Mark `Status` as you go: `todo | in-progress | done | skipped`.

| ID | Item | Phase | Effort | Depends on | Status |
| --- | --- | --- | --- | --- | --- |
| 0.1 | Sub-Agent Return Contract Standard | 0 | Small | — | done |
| 1.1 | Stage 5 auto-direct-mode hint persistence (incl. progress.sh activate/reset) | 1 | Small | — | done |
| 1.2 | Option 2A — auto-route to direct mode | 1 | Small | 1.1 | done |
| 1.3 | Option 2B — rewrite /mi-review Step 3a into main-driven loop with fresh per-iteration sub-agents | 1 | Medium-Large | 0.1, 1.1 | done |
| 1.4 | Option 2D — refresh review-context.md body | 1 | Small | 1.3 | done |
| 1.5 | Approve-with-deferred-findings UX framing | 1 | Small | — | done |
| 1.6 | Pre-classify cascades before sub-agent | 1 | Small | 1.3 | done |
| 2.1 | Stage 2 — delegate codebase-grounding pass; archive grounding-report | 2 | Medium | 0.1 | done |
| 3.1 | Per-event diagram prompt (stage 2: y/auto only; stage 4: y/n/auto) + delegate generation; adds `diagram-prompt` and `implementation-diagrams-skipped` to schema/progress.sh; updates `mi-continue.md` stage-5 handoff and stage-7 refresh wording | 3 | Medium | 0.1 | done |
| 3.2 | `.puml`-only default; SVG/PNG never auto-rendered; adds `diagram-rendering` to schema/progress.sh | 3 | Small | 3.1 | done |
| 3.3 | Stage 4 — change-summary cache reuse verification | 3 | Small | 3.1 | done |
| 3.4 | Stage 4 — skip diagram regen when fresh | 3 | Small | 3.1 | done |
| 3.5 | Stage 4 — render only changed-area diagrams | 3 | Small | 3.1, 3.4 | done |
| 4.1 | Option 1A — drop scan from stage 1.5 | 4 | Small | — | done |
| 4.2 | Option 1A.5 — heuristic short-circuit | 4 | Small | 4.1 | done |
| 4.3 | Option 1B — sub-agent fallback with cache | 4 | Small | 0.1, 4.2 | done |
| 5.1 | Option 2E — tighten change-summary body | 5 | Small | — | done |
| 5.2 | Stage 1 — per-folder summarization | 5 | Small | 0.1 | done |
| 5.3 | Stage 3 — primer hints | 5 | Small | — | done |
| 5.4 | Stage 3 — pre-pass tighter skill metadata | 5 | Small | — (soft dep on 6.5) | done |
| 5.5 | Stage 8 — atomic finalize via progress.sh finish; lazy archival | 5 | Small | — | done |
| 6.2 | Cache Key Specifications enforcement | 6 | Small | 1.4, 2.1, 3.4, 4.3 | done |
| 6.3 | Main-Read Budget Gates per stage | 6 | Medium | Phases 1–5 | done |
| 6.4 | Context-Budget Instrumentation | 6 | Small | — | done |
| 6.5 | Artifact Excerpt Commands | 6 | Small | — | done |
| 7.1 | Option 2F — delta primers for cascades | 7 | Large | 1.3 | done |

**Item count: 26.** (Was 29 before reviewer pass; removed three stage-8 regeneration items that described non-existent workflow behavior. Phase 6.1 was also moved to Phase 0.1, so it is no longer numbered under Phase 6.)

---

## Suggested PR strategy

**Single PR per phase** is recommended:

- PR 1: Phase 0 + Phase 1 (return contract + review loop) — biggest visible impact. Land first.
- PR 2: Phase 2 (stage 2 grounding-pass delegation).
- PR 3: Phase 3 (stage 4 diagrams with per-event prompt).
- PR 4: Phase 4 (stage 1.5 cleanup).
- PR 5: Phase 5 (smaller wins) — can be split further if any single item is contentious.
- PR 6: Phase 6 (operational discipline) — depends on Phases 1–5 for full effect.
- PR 7: Phase 7 — only if proceeding.

**Per-PR validation:**

1. Run a representative cycle end-to-end on the PR branch.
2. Compare main-context growth vs. baseline (from the pre-implementation snapshot).
3. Verify schema-validation hooks pass.
4. Confirm `/mi-doctor` reports clean.

**Backwards compatibility:** the workflow needs to keep working through partial implementation. Anchor that by:

- All new `active`-block fields have safe defaults and are initialized in both `progress.sh activate` and `reset`:
  - `review-mode-suggestion: none` (item 1.1)
  - `diagram-prompt: prompt` (item 3.1)
  - `implementation-diagrams-skipped: false` (item 3.1)
  - `diagram-rendering: never` (item 3.2)
  Without `additionalProperties: false`-compatible initialization in both lifecycle paths, `progress.sh set` will fail validation. **Verify each field appears in BOTH `activate` and `reset` blocks of `scripts/progress.sh` before merging the corresponding PR.**
- Most cache keys default to "missing → regenerate" behavior on first encounter (e.g., `change-summary.md`, `queue-rationale.md`, `review-context.md` body refresh — all return `missing` and the call site silently regenerates).
- **Exception: `diagrams-fresh`.** `missing` is treated as a diagnostic, not an automatic regenerate trigger. Per item 3.4, `missing` indicates an invariant violation (neither `implementation-diagrams-skipped=true` nor `.puml` files exist). The script exits non-zero; callers route to a recovery prompt that may regenerate after explicit inspector confirmation. The other three states (`fresh | stale | skipped`) are normal-flow outcomes the call sites handle inline.
- The `diagrams-fresh` four-state output (three normal: `fresh | stale | skipped`; one diagnostic: `missing`) handles the skipped case explicitly so downstream stages don't re-prompt for refresh.
- All sub-agent invocations have a fallback path (in-main execution) if the sub-agent fails — the workflow should not deadlock when delegation breaks.

---

## When you start implementation

1. Read `recommendations.md` end-to-end first. The cost model and architectural principles are load-bearing.
2. Read `workflow-simulation.md`'s tables for the stage you're about to change. The numbers are estimates — the structure of where work lives (main vs sub-agent) is what to preserve. **Caveat:** the simulation's stage-8 entries overstate cost (no completion regeneration in current workflow); the savings actually flow to next-cycle stage-2.
3. For each item, confirm the dependency graph above. Don't jump ahead. In particular, do not start any Phase 1–5 delegated item before Phase 0 lands.
4. Capture before/after token snapshots per item where feasible. Treat regressions as blockers.
5. Update this plan's tracking table as items land.
