# Manual testing stage — design plan

Owner: inspector (Emin).
Slot: between today's stage 5 entry and the existing inspector-review findings-authoring step. Implemented as a stage-5 sub-flow, not a new stage number — see § 1.

## 1. Stage / state model

### 1.1 Why no renumber

Today's stage map: `2 activate → 3 plan → 4 resume → 5 inspector-review → 6 review-loop → 7 finalize → 8 complete`. Renumbering to insert manual-test as a new stage 5 would require:

- Editing `schemas/progress.schema.yaml` `current-stage` bounds and every cross-reference.
- Updating `progress.sh advance-to`'s whitelist (currently `3→5, 5→7, 6→7`).
- Touching every doc that names a stage by number (lots of cross-refs in `commands/*.md`, `docs/workflow-spec.md`, the v11 progress-gap docs).
- Migrating any in-flight `progress.md` files.

The semantically clean version is not worth that churn. Instead, the manual-test phase becomes a **sub-flow on stage 5**: stage 5's role widens from "inspector review (findings only)" to "inspector evaluation (optional manual test, then findings)."

### 1.2 New `sub-flow` value

Add `manual-testing` to the enum at `schemas/progress.schema.yaml`:

```yaml
sub-flow:
  type: string
  enum: [none, chain-in-progress, resuming, reviewing, manual-testing]
```

Lifecycle on stage 5:

| Sub-flow            | Meaning                                                                 |
| ------------------- | ----------------------------------------------------------------------- |
| `none` (default)    | Stage 5 entry — no manual test in progress. Findings authoring is open. |
| `manual-testing`    | A manual-test plan exists and is being executed (or paused).            |
| `none` (post-test)  | Manual test finished or was declined. Back to findings authoring.       |

Sub-flow returns to `none` after the manual-test run completes (or is skipped/declined). It does **not** transition into `reviewing` — that transition happens later when the inspector types `/mi-continue` after writing findings (existing path).

### 1.3 New active-block fields

Add to the activate-time init in `scripts/progress.sh` and to `schemas/progress.schema.yaml`:

```yaml
manual-test-state:
  type: string
  enum: [none, running, complete, skipped]
  description: >
    Coarse lifecycle marker for the stage-5 manual-test phase. Four values:
      - `none` — initial value at activate. Also the state when a plan has been
        generated but the inspector has deferred running it (file exists at
        workflow-stream/<feature>/implementation/manual-test-plan.md, but the
        per-scenario loop has not started). The "plan exists" signal lives in
        the existence of workflow-stream/<feature>/implementation/manual-test-plan.md,
        not in this enum, to avoid a redundant transient state. Skill
        preconditions distinguish these two `none` cases by checking file
        presence.
      - `running` — per-scenario loop is active OR paused mid-run. Paired with
        sub-flow=manual-testing for dispatcher routing. Pause persists state as
        `running` (not a new value) and writes the current scenario id to
        manual-test-results.md frontmatter.
      - `complete` — loop finished (pass/fail counts live in
        manual-test-results.md frontmatter).
      - `skipped` — inspector declined the manual-test phase entirely at the
        stage-5 plan prompt (no plan generated, no scenarios run). Reserved
        for "decline the phase" only. Resets to `none` at next feature's
        activate.

      Note: `/mi-manual-test-run --finalize-skipped` does NOT set this state.
      Bulk-skipping remaining scenarios from a paused state is treated as a
      *completed run with skipped count* — terminal state is `complete`, with
      the skipped count tracked in `manual-test-results.md` frontmatter. This
      is a deliberate semantic split: `skipped` means "phase declined,"
      `complete` means "run reached its terminal state" (regardless of how
      many scenarios were actually executed vs bulk-skipped).

manual-test-failure-policy:
  type: string
  enum: [auto-seed, manual, none]
  description: >
    Records the inspector's answer to the auto-seed prompt at the end of a
    manual-test run. Set by `mi-manual-test-run` (the single owner of seeding —
    see § 2.2 "Auto-seed ownership recap"). Values:
      - `none` — initial value; also the value when the run is `skipped` or
        when no failures occurred.
      - `auto-seed` — inspector chose to run the auto-seed loop. This is a
        cycle-level intent/outcome marker, not a guarantee that every failed
        scenario ended with a seeded IR. Individual failures may remain
        unseeded when the inspector picks `skip` on a closed-IR or orphan-family
        prompt, or when a helper hard error aborts the auto-seed loop before
        remaining scenarios are visited. The per-scenario `Seeded:` cache in
        the results file is the source of truth for how many failures
        currently have a successful seed action. Seeded failures are written
        as canonical `### IR-NNN` blocks (with `- source: manual-test` and
        `- seed-id: ...` fields — see § 2.2) into inspector-review.md under
        `## Implementation Review`.
      - `manual` — inspector answered `n`; inspector-review.md was not modified
        by the run; the inspector authors any findings themselves.
    The Inspector Handler at `commands/mi-continue.md` (stage 5) reads this
    field for its summary line ONLY — it must not auto-seed, reopen,
    reclassify, or rewrite manual-test seeded IR blocks based on this value.
    Single-owner discipline (§ 2.2) is enforced by convention; tests should
    assert the Inspector Handler does not mutate inspector-review.md because of
    manual-test results when this field is `auto-seed`. Existing canonicalization
    of inspector-authored free-form review text remains outside this invariant.
```

Authoritative scenario-level state (current-scenario id, per-scenario verdicts, pass/fail counts) lives in `manual-test-results.md` frontmatter, not in `progress.md`. `progress.md` only carries the coarse markers above so the dispatcher can route.

**Idempotency lives in `inspector-review.md` via seed-id, not in `progress.md` and not in the results file.** Each auto-seeded IR-NNN block carries a `- seed-id:` field, so re-running the auto-seed loop upserts by seed-id (§ 2.2, § 3.7.1) and never duplicates. The results-file `Seeded:` field is display/cache only and does not enforce idempotency.

Rationale for not duplicating scenario-level state into `progress.md`: scenario-level state mutates per scenario (~20+ writes per cycle); making each one go through `progress.sh set` adds friction for no gain. The results file is the single source of truth for run progress, `progress.md` is the single source of truth for workflow progress.

### 1.4 Artifact location — feature-scoped, not cycle-scoped

> **AMENDMENT (post-v1):** The artifact location moved from
> `workflow-stream/<feature>/implementation/` to a sibling
> feature-permanent `workflow-stream/<feature>/test/` folder so the
> manual-test plan and per-run history survive stage 8 and abort,
> enabling cross-cycle reuse. The historical content of this section is
> kept below for design-history continuity; all live paths should be
> read as `test/...` instead of `implementation/...`. See
> `docs/manual-testing-folder/plan.md` for the relocation design (new
> §4.1 cross-activation results auto-rotation, §4.2 freshness gate,
> §4.3 activation-id mechanism). Section §3.4 below describing the
> abort-time rm list is similarly superseded — `/mi-abort-workflow` no
> longer deletes the test/ artifacts.

**Files live under `workflow-stream/<feature>/implementation/`**, alongside `inspector-review.md`, `review-context.md`, and `change-summary.md`:

- `workflow-stream/<feature>/implementation/manual-test-plan.md`.
- `workflow-stream/<feature>/implementation/manual-test-results.md`.
- `workflow-stream/<feature>/implementation/manual-test-plan.history/` (rotated prior plans, if `/mi-manual-test-plan` is re-run).

**Why feature-scoped, not cycle-scoped:**

- A quest cycle can contain multiple queued features (per `docs/workflow-spec.md`). Cycle-scoped artifacts (`todo-list.md`, `summary.md`, `progress.md`, `queue-rationale.md`) are workflow-wide; feature-scoped artifacts live under `workflow-stream/<feature>/`. Manual-test plans and results describe a specific feature's behavior — they're feature-scoped.
- The archive (`mi-complete-workflow.md`) and abort (`mi-abort-workflow.md`) flows both target `workflow-stream/<feature>/implementation/` already, so the new files live in the right folder for those flows. Both flows enumerate fixed file lists, not recursive copy/delete, so the new files still need explicit list-extension diffs in § 3.3 and § 3.4. Feature-scoping avoids parallel plumbing for a separate folder; it does not eliminate the list-extension work.
- The retry-mode abort path (`progress.sh reset`) preserves the active feature; the next stage-5 entry will see no `manual-test-plan.md` (cleared by abort with the extended rm list per § 3.4) and re-prompt for plan generation.

### 1.5 `progress.sh` schema impact

- `activate` block: add the two new fields with default `none`.
- `reset` block: add the same two new fields with default `none`. Without this, abort-with-retry (`progress.sh reset`, called from the retry path in `mi-abort-workflow.md`) would rebuild an active block missing the required fields and fail schema validation. § 3.6 details the diff.
- `set` validation (existing logic): accepts the two new fields by name.
- `advance-to` whitelist: **no change**. Manual-test does not advance `current-stage`; only sub-flow toggles within stage 5.
- `finish` (stage 8): no change — the new fields go to the archived `progress.md` snapshot like everything else.

---

## 2. New skills

### 2.1 `mi-manual-test-plan`

**File:** `commands/mi-manual-test-plan.md`.
**Description:** "Generate a manual test plan for the active feature and offer to execute it."

**Preconditions.** Flags are parsed first; `manual-test-state` requirements then dispatch on flag:

| Invocation                          | Requirements                                                                                                                                                                          |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Common (every invocation)           | `progress.sh get-active` is non-null. `progress.sh get current-stage == 5`. `progress.sh get sub-flow == none`.                                                                       |
| Normal (no `--force`, no `--discard-existing`) | `manual-test-state == none`. Refuse on `complete` or `skipped` with: "Manual test already terminal (state=`<X>`). Re-run with `/mi-manual-test-plan --force` to start over." |
| `--force` (with or without `--from-resume` / `--new-seed-family`) | `manual-test-state ∈ {none, complete, skipped}` is acceptable at entry. The skill itself resets `manual-test-state=none manual-test-failure-policy=none` later in the flow (see step 3.5 below) — only AFTER all read-only gates have passed (existing-plan read, RUN_ROOT resolution, change-summary freshness). This ordering guarantees that a refusal from any of those gates leaves `progress.md` byte-identical even when `--force` was passed. |
| `--discard-existing`                | `manual-test-state == none`. Same shape as normal invocation; the flag changes step 1's behavior, not the precondition envelope. |

Implementation note: parse flags before evaluating `manual-test-state`. An implementation that hard-rejects on `manual-test-state != none` *before* checking for `--force` will never reach the override path.

**Flow:**

The flow is ordered so that **every read-only gate fires before the first `progress.md` mutation**. Steps 1–3 are read-only (existing-plan probe, prompt branching, RUN_ROOT resolution, change-summary freshness gate). The first step that mutates `progress.md` is step 3.5, gated on `--force`; everything earlier either writes to `progress.md` only on a clean stop (`--discard-existing` and direct `n` paths in step 2) or doesn't write at all. This is what makes "stale change-summary refuses with `progress.md` unchanged" hold even when `--force` was passed.

1. **Resolve any existing plan before prompting.** Check `workflow-stream/<feature>/implementation/manual-test-plan.md` first.
   - If the file exists, read its frontmatter and store its `seed-family-id` as `preserved_seed_family_id` unless `--new-seed-family` was passed. This read happens before any y/n prompt so the skill never marks the phase `skipped` while silently leaving an old plan file behind.
   - If `--discard-existing` was passed and the file exists, rotate the existing plan/results into `manual-test-plan.history/<timestamp>/`, set `progress.sh set manual-test-state=skipped manual-test-failure-policy=none`, print "Existing manual-test plan discarded; manual-test phase marked skipped. Write findings into `inspector-review.md` and type `/mi-continue` when done.", and stop. This is the explicit destructive-intent path for "I do not want this existing plan anymore." If `--discard-existing` is passed with no existing plan, treat it like a normal direct `n` below.
2. **Prompt the inspector** (y/n) — but only when invoked directly by the inspector and only for a decision that has not already been made. `--from-resume` (auto-fired by `mi-continue`'s Resume Step 7) suppresses the duplicate **no-existing-plan** generation prompt because the inspector already answered `y` to that same question.
   - **No existing plan:** prompt "Generate `manual-test-plan.md` for `<feature>` before findings review? (Recommended for UI / integration changes; skippable for backend-only changes you're confident about.)" On `n`: `progress.sh set manual-test-state=skipped manual-test-failure-policy=none`. Print "Skipped. Write findings into `inspector-review.md` and type `/mi-continue` when done." Stop. On `y` (or when `--from-resume` was passed): continue.
   - **Existing plan present, no `--force`, direct invocation:** prompt "Existing `manual-test-plan.md` found for `<feature>`. Regenerate it? (`y` to rotate and regenerate, `n` to leave it in place.)" On `n`: do **not** set `manual-test-state=skipped`; print "Existing plan left in place. Run `/mi-manual-test-run` when ready, or write findings into `inspector-review.md` and type `/mi-continue` to proceed without running it." Stop with state unchanged. On `y`: continue to regeneration.
   - **Existing plan present, `--from-resume` without `--force`:** do **not** prompt and do **not** rotate/regenerate silently. Print "Existing manual-test plan found; using it unchanged." Skip the render path and jump to step 7's "perform now?" prompt. The stage-5 hand-off answer means "make a plan available," not "destroy and replace an existing plan without asking."
   - **Existing plan present, `--force` with or without `--from-resume`:** `--force` is the explicit regeneration signal. Continue to step 4 without prompting; rotate the existing plan/results and render a fresh plan.
3. **Resolve `RUN_ROOT` and read inputs.**

   **Resolve `RUN_ROOT`** from the active block: `RUN_ROOT = progress.sh get worktree-path` (with `progress.sh get git-worktree-dir` as the fallback if the field name differs in the current schema). `progress.sh get <field>` already reads from `.active.<field>` internally, so do not write `active.worktree-path`. All codebase search in this step runs from `RUN_ROOT`.

   **Render commands so they work in the inspector's terminal.** Generated commands MUST be self-contained — the inspector copy-pastes from chat into a shell where `$RUN_ROOT` is not defined. Two acceptable shapes; pick one and use it consistently for the whole `## 2. What to run` section:
   - **Preferred — absolute-path inline:** the plan generator interpolates the resolved absolute worktree path into every command, shell-quoted. Example: `cd "/Users/eminakkoc/.../workflow-stream/<feature>/.worktree" && pnpm dev`. This is unambiguous and self-contained; the inspector can copy-paste a single command without preamble.
   - **Acceptable — preamble export:** the section starts with a single `export RUN_ROOT="/abs/worktree/path"` line and subsequent commands use `cd "$RUN_ROOT" && ...`. Inspectors must copy the preamble first, but later commands stay short. Use only when the section has many commands and the absolute-path shape would be visually noisy.

   Exact rule: the plan generator does NOT emit bare `cd "$RUN_ROOT"` lines. Either the path is resolved inline at render time, or a preamble export defines `RUN_ROOT` in the same code block. If a specific service or repo legitimately must run from the original checkout (e.g., a docker-compose file pinned to the main checkout), the plan generator emits an absolute `cd "/abs/path/to/main/checkout"  # reason: <why>` for that one command; the default for everything else is the worktree.

   **Change-summary freshness gate.** Call `commits.sh change-summary-fresh <feature>` and dispatch on the exit code (`commits.sh change-summary-fresh` is a check, NOT a regenerator — exit 0 = fresh cache hit, exit 1 = stale, exit 2 = missing). Refuse with a recovery diagnostic if the summary isn't fresh:
   - exit 0 (fresh): proceed; read `workflow-stream/<feature>/implementation/change-summary.md`.
   - exit 1 (stale) or exit 2 (missing): refuse with diagnostic `change-summary.md is <stale|missing> for <feature>; run /mi-draw-diagrams (or /mi-generate-implementation-diagrams) to regenerate, then re-run /mi-manual-test-plan.` Stop. Do not mutate `manual-test-state` or rotate any existing plan. The inspector regenerates via the diagram skill (which owns change-summary regeneration today) and retries.

   **Read inputs** (input mix per § 7.1):
   - `workflow-stream/<feature>/blueprints/current/requirements.md` — goals, planned, non-goals.
   - `workflow-stream/<feature>/blueprints/current/config.md` — services, env vars, runtime topology.
   - `workflow-stream/<feature>/implementation/change-summary.md` — files touched, areas affected (gated fresh by the check above).
   - `quest/<active-slug>/summary.md` — feature scope (this IS cycle-scoped — read for cross-cutting context only).
   - **Codebase search (run from `RUN_ROOT`):** grep the changed paths from `change-summary.md` for env-var references, docker-compose service names, GraphQL operations / REST routes, error-code constants, UI route paths. These ground the Prerequisites and Test scenarios sections in real symbols, not invented ones.

   This is the last read-only step. Any refusal up to this point — invalid existing-plan frontmatter, declined regeneration, RUN_ROOT unresolvable, stale/missing change-summary — leaves `progress.md` byte-identical.

   **Step 3.5 — Force-state reset (only when `--force` is present, and only if we're proceeding to render).** Call `progress.sh set manual-test-state=none manual-test-failure-policy=none`. This is the FIRST `progress.md` mutation in the `--force` branch. It runs AFTER all read-only gates above so any earlier refusal aborts cleanly without changing state. Skip this step entirely on non-`--force` invocations and on the `--from-resume` "use existing plan unchanged" path that jumps to step 7. The prior `manual-test-results.md` is rotated alongside the plan in step 4; this step only touches `progress.md`. (Numbered "3.5" because it is logically a sub-step of the read-only-gates → state-mutation transition; the rest of the flow keeps its 1–7 numbering intact.)

4. **If an existing plan was found and regeneration is proceeding:** rotate the old plan into `manual-test-plan.history/<timestamp>/` via `scripts/blueprints.sh manual-test-plan-rotate` (see § 3.6). The `seed-family-id` to preserve was already captured in step 1. Preserving `seed-family-id` is required so forced re-runs can still find prior auto-seeded IR families even though the per-render plan `id` changes.
5. **Render** `workflow-stream/<feature>/implementation/manual-test-plan.md` from `templates/manual-test-plan.md.tmpl`. Generate a fresh plan `id` every time, but reuse `preserved_seed_family_id` from step 1 when present; otherwise create a new one. Three top-level sections (mirroring `tmp/manual-test-plan.md`):
   - `## 1. Prerequisites` — services to run, env vars, install/bootstrap, seed data.
   - `## 2. What to run` — per-terminal command set.
   - `## 3. Test scenarios` — grouped by Scenario letter (A, B, C, …), numbered within (`A.1, A.2, B.1, …` per § 7.3).
6. **Do NOT change `manual-test-state`.** It stays at `none`. The file's existence is the "plan generated" signal; the enum tracks the *run* lifecycle, not the *plan* lifecycle.
7. **Prompt the inspector** (y/n): "Plan available at `workflow-stream/<feature>/implementation/manual-test-plan.md`. Perform the manual test now? (`y` to start with the local-environment-up phase; `n` to defer — you can resume later by typing `/mi-manual-test-run`, or proceed directly to findings authoring.)"
   - On `n`: print "Deferred. Run `/mi-manual-test-run` when ready, or write findings into `inspector-review.md` and type `/mi-continue` to proceed without manual testing. The plan file stays available." Stop. State stays `none`.
   - On `y`: `progress.sh set sub-flow=manual-testing manual-test-state=running`. Auto-fire `/mi-manual-test-run`.

**Manual invocability:** The inspector can type `/mi-manual-test-plan` directly during stage 5 (not auto-fired) if they want to (re)generate. Direct invocation does NOT pass `--from-resume`, so the step 2 y/n prompt fires normally. If no plan exists, answering `n` marks the phase skipped. If a plan already exists, answering `n` is intentionally a no-op that leaves the plan file and state unchanged; use `--discard-existing` for the explicit "delete/rotate this plan and mark the phase skipped" path. The "if file exists, rotate" branch in step 4 handles regeneration cleanly.

**`--from-resume` flag.** Used by `commands/mi-continue.md`'s Resume Step 7 (§ 3.1.1) to suppress the redundant no-existing-plan generation prompt at step 2 when the inspector already answered `y` to the stage-5 hand-off prompt. If a plan already exists and `--force` was not passed, the flag uses that plan unchanged and jumps to step 7; it must not silently rotate/regenerate the file because "regenerate existing plan?" is a distinct destructive decision. The flag is mutually compatible with `--force` and `--new-seed-family`; passing all three is well-defined (force a re-run from a terminal state without re-prompting and reset the seed family). The flag has no effect on step 7's "perform now?" prompt — that prompt is always asked because it's a separate decision (generate/available vs run).

**Forced re-invocation from a terminal state:** `--force` is the explicit override path for re-running when `manual-test-state` is already `complete` or `skipped` (per the precondition table above). The state reset happens in **step 3.5**, AFTER the read-only gates pass, so a refusal from any earlier gate (invalid existing-plan frontmatter, declined regeneration prompt, unresolvable RUN_ROOT, stale/missing change-summary) leaves `progress.md` byte-identical even when `--force` was passed. `--force` is also the explicit "regenerate the existing plan" signal, so it bypasses the existing-plan regeneration prompt at step 2 and rotates plan/results at step 4. By default, `--force` preserves the previous plan's `seed-family-id` so re-run failures upsert into the same seeded IR family. If the inspector intentionally wants to abandon all prior manual-test seed history, they may pass `--force --new-seed-family`; that creates a fresh `seed-family-id` and makes prior IRs invisible to the new run's seed lookup.

### 2.2 `mi-manual-test-run`

**File:** `commands/mi-manual-test-run.md`.
**Description:** "Execute the active feature's manual-test-plan.md scenario by scenario, asking the inspector for verdicts."

**Invocation modes and dispatch order.** `/mi-manual-test-run` accepts three mutually exclusive mode flags. Parse flags first, then dispatch to one of three branches. After flag parsing the runner picks exactly one branch and never mixes their flows:

1. Parse flags from argv.
2. If `--seed-only` is present → run **Branch B** (seed-only re-trigger / recovery).
3. Else if `--finalize-skipped` is present → run **Branch C** (bulk-skip the remaining scenarios).
4. Else → run **Branch A** (normal first-run / paused-resume).

`--seed-only` and `--finalize-skipped` are mutually exclusive; passing both refuses with diagnostic `"--seed-only and --finalize-skipped are mutually exclusive"` and no mutation.

**All branches — common preconditions:**

- `progress.sh get-active` is non-null.
- `progress.sh get current-stage == 5`. Refuse outside stage 5 with diagnostic: "Manual test belongs to stage 5 (inspector review). Current stage is `<N>`. Type /mi-resume-workflow to see the next-step recommendation, or wait until the workflow reaches stage 5." This guards the deferred-plan path: if the inspector answered `n` to "perform now" at stage 5, then proceeded through review and finalize, the workflow leaves stage 5; invoking `/mi-manual-test-run` later would otherwise paint `sub-flow=manual-testing` outside stage 5 and corrupt the state machine.

**Resolve `RUN_ROOT` (Branches A and B; not Branch C).** Before any user-facing prompt or scenario render in Branches A and B, resolve `RUN_ROOT = progress.sh get worktree-path` (or the active block's worktree field name — note `progress.sh get` already reads from the active block, do not prefix with `active.`). This is the working directory the env-up phase, scenario execution, and any in-line codebase reads should assume. Branch C never executes scenarios or runs commands, so it doesn't need `RUN_ROOT`.

**Branch A — normal invocation (no flags):**

- Common preconditions above.
- `workflow-stream/<feature>/implementation/manual-test-plan.md` exists.
- `manual-test-state` ∈ {`none`, `running`} (i.e., never run, OR paused mid-run). On `complete` or `skipped`, refuse and print "Manual test already terminal (state=`<X>`). Re-run with `/mi-manual-test-plan --force` to start over, or pass `--seed-only` to re-trigger only the auto-seed loop."

**Branch A — pre-normalization results-file read.** Before any progress.md mutation, **read and validate `manual-test-results.md` if it exists**, then dispatch on its `state`:

- Results file absent: continue to the workflow-state normalization step below. This is the genuine deferred-plan / first-run case.
- **Results file present but frontmatter unreadable, invalid, or not owned by the active plan.** Refusal triggers: YAML parse error, missing required keys (`feature`, `state`, `current-scenario`, `plan-id`, `seed-family-id`, counts), `state` value not in the `[in-progress, complete]` enum, ownership mismatch (`results.feature != <active-feature>`, `results.plan-id != current manual-test-plan.md id`, or `results.seed-family-id != current manual-test-plan.md seed-family-id`), or state-specific inconsistency. For `state=in-progress`, `current-scenario` must be `null` or a scenario id present in the plan. For `state=complete`, `current-scenario` must be `null` and `finished-at` must be non-null. Refuse with diagnostic `"manual-test-results.md frontmatter is invalid (<reason>); cannot determine resume state. Inspect the file and fix the YAML, or run /mi-manual-test-plan --force to rotate the broken file and start over."` Do NOT normalize progress.md. Do NOT re-render the results file from the template (that would lose any per-scenario verdicts in the body). The diagnostic must name the offending field/parse error/mismatch so the inspector can fix the file by hand without guessing. This guard is symmetric across Branch A and Branch B — corrupt or stale frontmatter is a refuse-and-surface case in both modes; without it, a naive implementation could resume a stale results file against the wrong plan or fall through to normalization and wrongly paint `(manual-testing, running)`.
- Valid `state: in-progress`: continue to workflow-state normalization. This is the paused-resume case.
- Valid `state: complete`: refuse with "Manual test results already complete. Pass `--seed-only` to manage auto-seeding, or `/mi-manual-test-plan --force` to start over." **Do NOT normalize progress.md.** A clean finalization via § 2.2 step 4 sets `manual-test-state=complete`, NOT `none`, so `(none, none) + results=complete` is a *recoverable stale-progress state* (legacy run from before the finalization rule landed, or a manual `progress.sh set` edit), not an "accurate" post-finalization shape. Branch A still refuses without mutating progress.md; the recovery path is `--seed-only` (Branch B accepts `(none, none) + results=complete` as input and finalizes to `(none, complete)` per § 2.2 Branch B finalization).

**Branch A — workflow-state normalization.** With the results-file pre-check passing, normalize `progress.md` so a pause routes correctly:

```
case (sub-flow, manual-test-state):
  ("none",            "none")    → progress.sh set sub-flow=manual-testing manual-test-state=running
                                    # deferred-plan path: /mi-manual-test-plan ran, inspector answered `n` to "perform now",
                                    # then later typed /mi-manual-test-run directly. Paint the workflow markers so the
                                    # dispatcher routes a future pause through the Manual-Test-Resume Handler.
  ("manual-testing",  "running") → no-op (paused-resume path; markers already correct)
  any other combo               → refuse with diagnostic: "Inconsistent state — sub-flow=<X>, manual-test-state=<Y>.
                                    Expected (none/none) or (manual-testing/running). Run /mi-resume-workflow."
```

The deferred-plan crash window is partially closed by this normalization: as soon as `/mi-manual-test-run` enters Branch A, the markers are correct even if the run crashes before creating the results file. The Manual-Test-Resume Handler also handles the "plan exists, results missing" recovery — see § 3.1.3.

**Branch B — `--seed-only` invocation:**

- Common preconditions above (including `current-stage == 5`).
- `workflow-stream/<feature>/implementation/manual-test-plan.md` exists.
- `workflow-stream/<feature>/implementation/manual-test-results.md` exists.
- **Before checking `state=complete`, read and validate results frontmatter with the same corruption/ownership rules as Branch A.** If YAML parsing fails, a required key is missing, an enum value is invalid, `results.feature` / `results.plan-id` / `results.seed-family-id` does not match the active feature and current plan frontmatter, `current-scenario` points to a scenario id not present in the plan, or `state=complete` has non-null `current-scenario` / null `finished-at`, refuse with the explicit corruption/stale-results diagnostic and do not mutate `progress.md` or re-render the results file. Only after this validation passes does Branch B enforce `state: complete`.
- Results frontmatter `state: complete`.
- `manual-test-state` may be `complete` (post-run, normal seed-recovery case) OR `running` (post-run-with-mid-seed-crash, dispatcher-routed case) OR `none` AND `sub-flow=none` AND results-file `state=complete` (recoverable stale-progress state — accepted here so the inspector can re-seed observations after-the-fact even when the markers don't match clean finalization). Refuse on `skipped` (phase declined — no plan exists). Refuse on `none` AND `sub-flow=manual-testing` (genuinely inconsistent state — print: "Inconsistent: manual-test-state=none but sub-flow=manual-testing. Run /mi-resume-workflow.").

The Branch-B precondition deliberately **allows `manual-test-state=complete`**, which Branch A rejects. This is the recovery path for the Manual-Test-Resume Handler's `state=complete && sub-flow=manual-testing` case (§ 3.1.3) AND for the manual re-trigger case after the inspector edits observations in the results file. The `(none, none) + results=complete` allowance closes the contradiction with Branch A's diagnostic, which recommends `--seed-only` for that recoverable state.

**Note on `state=none` semantics (Branch A):** `state=none` covers two cases: (a) plan was generated but the inspector deferred running it, file exists; (b) the run was never started. Both resume identically via this skill in Branch A — the results file is created on first invocation, and `current-scenario: null` means "start from scenario 1."

**Flow:**

1. **Resolve the results file** at `workflow-stream/<feature>/implementation/manual-test-results.md`. If absent, render from `templates/manual-test-results.md.tmpl` (the template is the single source of truth for frontmatter shape — see § 4.2). The template includes `feature`, `plan-id`, `seed-family-id`, `state`, `current-scenario`, `total`, `passed`, `failed`, `skipped`, `started-at`, `finished-at`, plus the `id` UUID. `plan-id` is copied from the current plan's per-render `id`; `seed-family-id` is copied from the current plan's stable `seed-family-id`. Substitute placeholder values at render time. If the file is present, read its frontmatter — it tells us where to resume.
2. **Local-environment-up phase** (always first, even on resume — env may have decayed since the pause):
   - Read `## 1. Prerequisites` and `## 2. What to run` from the plan.
   - Render the prerequisite checklist + run-commands as a single message to the inspector in chat. Per § 4.1, the plan generator already wrote each command in a self-contained, copy-paste-ready shape — either with the absolute worktree path inlined (e.g., `cd "/abs/.../<feature>/.worktree" && pnpm dev`) or with an `export RUN_ROOT="/abs/path"` preamble at the top of the section followed by `cd "$RUN_ROOT" && ...` commands. The runner echoes the section verbatim; it does NOT post-process or substitute `$RUN_ROOT` itself, because the plan file is the authoritative copy and the inspector may also read it directly. If the plan was generated against a different worktree path than the current `progress.sh get worktree-path` (e.g., the worktree was moved between plan generation and run), the runner refuses with a diagnostic naming both paths and recommends `/mi-manual-test-plan --force` to regenerate.
   - Wait for the inspector to confirm `ready` (or `skip-env` if they're already running).
3. **Per-scenario loop.** For each scenario in the plan in order, starting from `current-scenario` (or scenario 1 if null):
   1. **Set `current-scenario: <THIS_ID>` in the results-file frontmatter** before rendering. This is the resume key — pause persists this value, so resume re-shows the same scenario rather than skipping to the next one.
      - Before rendering, check whether a verdict block for `<THIS_ID>` already exists. If it does, treat the verdict as already committed (likely crash window after writing the body but before advancing the cursor): recompute counts from all verdict blocks, advance `current-scenario` to the next uncommitted scenario (or `null` if none), persist the frontmatter, and continue without prompting the inspector again. This keeps resume idempotent when a prior invocation crashed mid-commit.
   2. Render the scenario block in the report format the inspector specified:
      ```
      ⏺ <SCENARIO_ID> — <one-line title> (<linked-IR-IDs if any>)

      What it tests: <expanded from the plan's scenario body>

      Trick to trigger from the UI: <if the plan called this out>

      Action:
      <numbered steps from the plan>

      Expected:
      <bulleted expectations from the plan>
      ```
   3. Wait for inspector reply: `pass`, `fail <observation>`, `skip <reason>`, or `pause`.
   4. **On `pass` / `fail` / `skip`:**
      - Upsert the verdict block for this scenario id in `manual-test-results.md` body (one canonical block per scenario: id, verdict, observation, timestamp). Do not append a second block if one already exists; replace that scenario's block.
      - Recompute `passed`, `failed`, and `skipped` counts from the full set of verdict blocks. Then set `current-scenario` to the **next** uncommitted scenario id (or `null` if this was the last) — only AFTER the verdict block is committed, so the just-finished scenario is durable before the cursor advances.
      - Write body + frontmatter via temp file + atomic rename where the platform supports it. This is the scenario verdict commit unit: parse existing verdict blocks into `map[scenario_id]`, replace `map[THIS_ID]`, render blocks in plan order, recompute counts, update cursor, write temp, rename.
      - **Duplicate-verdict-block recovery.** When parsing existing verdict blocks into `map[scenario_id]`, if two or more blocks share the same scenario id (corruption from a prior crash window or hand-edit), the parser must NOT silently fold both into the count. The pinned recovery shape is: **keep the latest block (the one that appears later in the file) as canonical, drop the earlier duplicate(s), emit a one-line `^warning:` to stderr naming the scenario id and the count of duplicates dropped**, then proceed with the upsert as normal. The runner already owns canonical-block parsing, so silent self-healing matches the rest of the file's idempotency story; refusal would force the inspector to hand-edit a markdown file mid-run. The stderr warning surfaces the heal in case it's masking something the inspector wants to see.
      - Echo to chat as a single line: `<ID> ✅ <one-line outcome>` or `<ID> ❌ <one-line observation>` or `<ID> ⊘ skipped: <reason>`. **Do not re-render the full scenario block in the echo** — that's the bloat-control point.
      - Continue to the next scenario.
   5. **On `pause`:**
      - Frontmatter is **already** set to `current-scenario: <THIS_ID>` from step 3.1 (the scenario being shown). Do not advance it. Leave **results-file** `state: in-progress`. (The two state fields are deliberately separate: `progress.md` `manual-test-state: running` is the workflow-level marker that drives dispatcher routing; `manual-test-results.md` `state: in-progress` is the file-level marker that drives the resume guard within the skill. Don't conflate them — pause sets neither to `running`.)
      - Print: "Paused at scenario `<THIS_ID>`. Type `/mi-continue` (will resume the run by re-showing this scenario) or `/mi-manual-test-run` directly. To bulk-skip remaining scenarios and end the run, type `/mi-manual-test-run --finalize-skipped`."
      - Stop.
4. **Loop completion:** (`mi-manual-test-run` is the **single owner** of auto-seeding for manual-test results)
   - Set frontmatter `state: complete`, `finished-at: <timestamp>`, `current-scenario: null`.
   - Recompute pass/fail/skip counts from the verdict blocks and write them to frontmatter.
   - **Observation extraction for the auto-seed helper call.** The storage shape is pinned in § 4.2.1's parsing contract. For each failed scenario, the runner extracts the raw observation text from the verdict block's `- **Observation:** ...` bullet. Single-line form (`- **Observation:** <text>`) yields `<text>` directly. Block-scalar form (`- **Observation:** |` followed by indented lines) yields the body with its four-space indent stripped, preserving internal blank lines. The extracted text is piped to `review.sh upsert-manual-test-failure` via stdin using `printf '%s\n'` (per § 3.7.1's caller pattern). Round-trip is lossless: a write/read/write cycle of the same observation yields a byte-identical block scalar.
   - **Auto-seed prompt** (per § 7.2): if `failed > 0`, ask the inspector: "Manual test complete: `<passed>/<total>` passed, `<failed>` failed, `<skipped>` skipped. Auto-seed `<failed>` failures as findings in `inspector-review.md`? Reply `y`, `n`, or `y --classify` to set scope per scenario (default if you reply `y`: scope=`fix`, severity=`major`).
     - `y` runs the per-scenario family-inspection loop (see "Family inspection in first-time auto-seed" below) and seeds each failed scenario via `review.sh upsert-manual-test-failure` (§ 3.7.1) per the inspection's branch decision. Most scenarios end up as canonical `### IR-NNN` blocks with `Seeded: true`; some may end up `Seeded: false` if the inspector picks `skip` at a closed-IR or orphan-family per-scenario prompt.
     - `n` leaves inspector-review.md untouched and you'll author findings yourself."
     - On `y`: enter the auto-seed loop with `scope=fix, severity=major` for every failure. After it completes, set `progress.sh set manual-test-failure-policy=auto-seed` and report seeded/failed counts. Note: on a subsequent `--seed-only` re-run, existing IRs' severity/scope are preserved (§ 3.7.1 — preservation behavior); the (fix, major) defaults only apply to first-time inserts.

       **Policy-after-loop ordering is deliberate.** `manual-test-failure-policy=auto-seed` is set AFTER the loop, not before. A mid-loop crash or helper non-zero exit leaves `policy=none`, `sub-flow=manual-testing`, and `manual-test-state=running`; Branch B re-entry re-prompts the inspector from scratch and does not finalize until a complete valid exit occurs. The alternative — setting policy *before* the loop — would silently commit the inspector to `auto-seed` before they confirmed the prompt actually completed; that loses information and risks finalizing on a half-baked outcome. Re-prompting is safe because per-scenario seeding is idempotent via seed-id (§ 2.2 "Crash-safe auto-seed via deterministic seed-id"), so the inspector can re-confirm without double-seeding any IRs. The same logic applies to `y --classify` below.
     - On `y --classify`: for each failed scenario, prompt "`<SCENARIO_ID>` failed: `<one-line observation>`. Pick scope (`fix`/`re-implement`/`re-plan`/`re-spec`, default `fix`) and severity (`blocker`/`major`/`minor`, default `major`):" Pass the chosen values to `upsert-manual-test-failure` and set `reclassify_existing=true` so those choices also apply when the helper reopens or reuses an existing IR. Set `policy=auto-seed` and report seeded/failed counts. The classification persists on the IR block; subsequent `--seed-only` re-runs preserve it unless the inspector explicitly re-classifies (helper's `--reclassify` flag).
     - On `n`: set `progress.sh set manual-test-failure-policy=manual`.

     **Family inspection in first-time auto-seed.** Both `y` and `y --classify` paths perform the same per-scenario family inspection as Branch B's "Mandatory base-status inspection" (below) before each helper call. For each failed scenario:
     - **Family empty** (truly first-time, no leftovers from prior cycles) → default helper call (insert a new base IR with the chosen severity/scope).
     - **Base missing but family non-empty** (orphan regressions from a prior `--force` cycle whose review session deleted the base while leaving `:r1`/`:r2`) → run the orphan-regression default-interactive prompt (seed-into-family / skip / restore-base). Pass the inspector's chosen severity/scope to whichever helper path they pick. Calling the helper in default mode here would otherwise insert a NEW base IR alongside the orphan regressions.
     - **Open base** → default helper call. Helper's open-update path replaces details and preserves prior severity/scope unless `y --classify` reclassified them (in which case the runner passes `--reclassify`).
     - **Closed base** → default helper call. Helper emits the closed-IR warning; the runner surfaces the per-IR reopen / new-finding / skip prompt; the second call's outcome drives the cited IR-NNN and the `Seeded:` flip per the successful-seed-action rule.

     The inspection is necessary in the first-time loop because previous-cycle IRs may still exist in `inspector-review.md` even before any `--seed-only` re-run — the orphan-regression case is not exclusive to `--seed-only` mode.
     When the inspector chose `y --classify`, set `reclassify_existing=true` for this auto-seed loop and pass `--reclassify` on any helper call that updates/reopens/reuses an existing IR, including the second call after a closed-IR prompt and the orphan-family seed-into-family path. Without this flag, the helper deliberately preserves existing severity/scope and the inspector's classification choice would be ignored on reused IRs.
   - **Set `progress.sh set sub-flow=none manual-test-state=complete`** as the LAST mutation. A session break before this leaves `sub-flow=manual-testing` (re-enters cleanly via the Manual-Test-Resume Handler).
   - Print the stage-5 hand-off message: "Manual test done. Review `inspector-review.md` (auto-seeded failures appear at the bottom as canonical `### IR-NNN` blocks — no canonicalization needed for those), add any subjective findings as free-form text, and type `/mi-continue` when done. The free-form findings will be canonicalized by the existing canonicalize pass on the next `/mi-continue`." The helper writes auto-seeded blocks canonically; § 3.1.4's Inspector Handler must not mutate review content because of manual-test results. Canonicalize only handles inspector-authored free-form review text.

**Crash-safe auto-seed via deterministic seed-id.** `mi-manual-test-run` writes canonical `### IR-NNN` blocks under `## Implementation Review` (per `templates/inspector-review.md.tmpl`) by calling `review.sh upsert-manual-test-failure` (§ 3.7.1) once per failed scenario. The helper does seed-id lookup, upserts the block, and returns the resulting `IR-NNN`. The seed-id (`manual-test:<seed-family-id>:<scenario-id>`) is unique per stable manual-test seed family and scenario. `seed-family-id` comes from `manual-test-plan.md` frontmatter and is preserved across `/mi-manual-test-plan --force` re-renders unless `--new-seed-family` is explicitly passed; scenario-id is e.g. `A.1`.

The full helper contract — including arg list, stdin observation body, preservation rules for `severity`/`scope`/`status`/`fix-note`, and the `--reclassify` flag — lives in **§ 3.7.1**. Read it once before implementing the auto-seed loop. The `mi-manual-test-run` loop is `for-each-failed-scenario → family-inspect → dispatch (default helper / orphan prompt / closed-base prompt) → pipe observation to upsert → collect IR-NNN`. The inspection adds one `find-by-seed-id-family` call per failure, well below inspector-prompt latency. Most complexity stays in the helper; the runner's job is the inspection-and-dispatch wrapper.

**`Seeded:` marker is display/cache only.** It's flipped to `true` after a successful upsert as a diagnostic aid (lets a human or query glance at the results file and see what's been seeded), but it is NOT a correctness path. `--seed-only` mode always greps `inspector-review.md` by seed-id via the helper; the cache is ignored. The cache stays in the schema (§ 4.2) for diagnostic value only.

**`Seeded:` flips on a successful seed action — NOT "mutation occurred."** Idempotent crash recovery is the motivating case: a crash between "IR inserted" and "Seeded flipped" leaves an open seeded IR with `Seeded: false`. On retry the helper finds the IR, upserts byte-identically, and produces no file diff — but the seeding *did happen*, just on the prior call. The `Seeded:` rule must therefore key on whether the helper performed a successful seed action (regardless of whether bytes changed on this specific call), not on whether a mutation hit disk.

The runner MUST distinguish:

- Helper exit 0, stderr empty (open-match upsert — including idempotent zero-diff reuse — OR insert / `--reopen` / regression allocate / regression upsert) → **successful seed action** → `Seeded: true`.
- Helper exit 0, stderr starts with `^warning:` (closed-default — the helper *declined* to seed because the matched IR is closed) → **no seed action** → `Seeded` unchanged. If the inspector subsequently picks `reopen` or `new-finding` and the runner re-calls the helper, the second call's success flips `Seeded: true`. If the inspector picks `skip`, leave `Seeded: false`.
- Helper non-zero exit (refusal — mutual exclusion, empty-family `--force-new-regression`, schema problem) → no seed action → `Seeded` unchanged. The runner aborts the auto-seed loop as a hard error per the closed-IR caller pattern (§ 3.7.1); Branch B does not finalize or promote policy on this invocation.

Net rule: distinguish "the helper agreed this was a valid seeding outcome" (exit 0, no warning) from "the helper warned" or "the helper refused." The byte-diff doesn't matter; the helper's classification of the outcome does. This makes the cache safe under arbitrary crash/retry topologies.

**`--seed-only` flag on `/mi-manual-test-run`** runs only the auto-seed loop, useful for: (a) crash recovery routed by the Manual-Test-Resume Handler when `state=complete && sub-flow=manual-testing`; (b) manual re-trigger if the inspector wants to re-seed after editing observations in `manual-test-results.md` — the replace-by-seed-id path picks up the edits because `--seed-only` mode always greps (does not trust the `Seeded:` cache). See the precondition branches above.

**Resume-aware entry guard (step 0).** At the top of the skill, before the env-up phase, branch on invocation mode and state.

**Branch A entry (normal invocation):** check results-file `state`:

- `state: in-progress`: normal resume from `current-scenario`.
- `state: complete`: defense-in-depth refusal (the pre-normalization read at the top of Branch A already refuses on `state: complete` before this guard is reached). Refuse with "Manual test already complete; use `/mi-manual-test-plan --force` to re-run, or pass `--seed-only` to manage auto-seeding."
- (results file absent): the workflow-state normalization at Branch A entry sets `state=running`; if the results file is absent, fall through to step 1 which renders it from the template.

**Branch B entry (`--seed-only` invocation):** dispatch on `manual-test-failure-policy`:

| `policy` value | Behavior                                                                                                                                                                                                                                       |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `none`         | First-time seeding (or recovery from a crash before step 4's auto-seed prompt). If `failed > 0`: prompt the inspector (auto-seed prompt as in step 4). If `failed == 0`: no-op; finalize by clearing sub-flow and confirm `policy=none`.        |
| `auto-seed`    | Re-run the upsert loop for every failed scenario. The loop is idempotent via seed-id, so unchanged scenarios produce no diff; observation edits since last seed are picked up. Print seeded/failed counts, e.g. "Re-seed complete: 2/3 failures seeded." |
| `manual`       | The inspector previously declined auto-seed. Prompt: "Auto-seed was declined for this run; switch to auto-seed and seed `<failed>` failures now? (`y`/`n` — `y` flips policy and seeds; `n` keeps `policy=manual` and finalizes per § 2.2 Branch B finalization.)" |

**Branch B runner-level flags.** `--seed-only` accepts companion flags that map to the helper's classification/closed-IR overrides:

| Runner flag                       | Effect                                                                                                                                                  |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/mi-manual-test-run --seed-only` | Default. For each failed scenario, performs the family inspection below, then usually calls `upsert-manual-test-failure` without override flags. Exact closed-base detection prompts the inspector per IR (§ 3.7.1); orphan-regression families prompt before any helper call. |
| `--seed-only --reclassify`        | Re-prompts the inspector for severity/scope per failed scenario (like `y --classify` in step 4) and passes `--reclassify` to each helper call. Useful when classification from the original run was wrong. |
| `--seed-only --reopen-all`        | For each failed scenario, performs the same family inspection as `--as-new-findings`. Dispatch: **closed base** → pass `--reopen`; **open base** → default helper call (`--reopen` would be a silent no-op); **family empty** → default helper call (insert a new base IR — `--reopen` against no match is also a no-op); **base missing but family non-empty** → refuse-and-skip per-scenario per the orphan-regression diagnostic ("base IR missing but regression family exists; cannot reopen base"). Suppresses the per-IR closed-base prompt but does NOT bypass the inspection. Use sparingly — the default per-IR prompt is usually safer because the inspector can pick `new-finding` for surfaces that legitimately need a regression record. |
| `--seed-only --as-new-findings`   | Mirror of `--reopen-all` but with `--new-finding`. Treats every **closed-base** re-failure as a regression. Open-base and family-empty first-time scenarios go through the helper's default mode so the open base is updated or a new base IR is inserted. Base-missing-but-family-non-empty scenarios extend the existing regression family. See "Mandatory base-status inspection" below — this flag is NOT a license to pass `--new-finding` blindly. Idempotent — re-running picks up the latest open regression in the family per § 3.7.1's Family-aware logic. |
| `--seed-only --as-new-findings --force-new-regressions` | Composes with `--as-new-findings`. For every **closed-base** re-failure, passes `--new-finding --force-new-regression` to the helper, allocating a fresh `:r<N>` regardless of whether an open regression already exists in the family. Open-base and family-empty first-time scenarios still go through default mode; base-missing-but-family-non-empty scenarios extend or force-extend the existing regression family — `--force-new-regressions` does NOT bypass the base-status check. **Not idempotent against closed bases or orphan families** — every invocation produces a new IR per scenario where the force flag is actually passed. Reserved for the rare "this is a parallel regression that happens to share the scenario id" case. Mutually exclusive with `--reopen-all`. Refused if `--as-new-findings` is omitted (the flag is meaningless without it). |

**Classification override propagation.** The runner computes `reclassify_existing=true` when either (a) first-time auto-seed used `y --classify`, or (b) `--seed-only --reclassify` was passed. When true, append `--reclassify` to every helper call that may update an existing IR: open-base default update, closed-base `--reopen`, closed-base `--new-finding`, orphan-family seed-into-family (`--new-finding`), and default helper calls that hit an existing closed/open base. This is required because the helper preserves severity/scope on updates unless `--reclassify` is present. For a true insert path (family empty or explicit restore-base after deletion), `--reclassify` is harmless but not required because the inserted block uses the passed severity/scope.

**Mandatory base-status inspection.** Helper `--new-finding` operates on the family regardless of base status — passing it against an open base IR allocates a `:r1` regression instead of updating the open base, which is virtually never what the inspector means when they pick "treat closed-IR re-failures as regressions." `--reopen-all` doesn't have this problem (it's a no-op against open IRs by design), but `--as-new-findings` and `--as-new-findings --force-new-regressions` do. The default interactive path also needs the family check for one edge case: if the exact base IR was deleted but `:r<N>` regressions remain, the helper's default exact lookup would see "no base match" and insert a new base IR unless the runner catches the orphan family first. Therefore Branch B performs an explicit per-scenario family lookup before deciding which helper mode, prompt, or refusal applies.

The inspection must distinguish three shapes:

```
for each failed scenario in the results file:
  base_seed_id = "manual-test:<seed-family-id>:<scenario-id>"
  family = $(review.sh find-by-seed-id-family "$feature" "$base_seed_id")
  base_row = the row in family whose seed-id == base_seed_id  (may be empty)
  family_is_empty = (family has zero rows)

  if family_is_empty:
    # Truly first-time seed for this scenario — no base IR, no regressions.
    upsert-manual-test-failure ... <severity> <scope>

  elif base_row is empty (but family is non-empty — base was deleted, regressions remain):
    # Orphan regression family: base IR was manually removed by the review session,
    # but :r1, :r2, … still live. Default-inserting would create a NEW base IR alongside
    # the orphan regressions, which is confusing. Handle per runner flag:
    if --as-new-findings was passed:
      # Extend the existing regression family.
      if --force-new-regressions was passed:
        upsert-manual-test-failure ... <severity> <scope> --new-finding --force-new-regression
      else:
        upsert-manual-test-failure ... <severity> <scope> --new-finding
    elif --reopen-all was passed:
      # No base to reopen; refuse with a per-scenario diagnostic and skip.
      print "scenario <id>: base IR missing but regression family exists; cannot reopen base; skipping"
      mark Seeded: false; continue
    else:
      # Default interactive (no batch override). Do NOT call the helper yet:
      # default mode would exact-lookup the missing base seed-id, find no match, and
      # insert a new base IR alongside the orphan regressions.
      latest_family_row = newest open regression if present, otherwise newest family row overall
      print "scenario <id>: base IR missing but regression family exists; latest family IR is <IR-NNN> (status=<status>)"
      prompt:
        a) seed into the existing regression family
        b) skip this scenario
        c) explicitly restore the missing base IR
      if inspector picks a:
        upsert-manual-test-failure ... <severity> <scope> --new-finding
      elif inspector picks b:
        mark Seeded: false; continue
      else:  # inspector explicitly chose to restore the base
        upsert-manual-test-failure ... <severity> <scope>

  elif base_row.status == "open":
    # Open base — the right place to record this failure.
    # NEVER pass --new-finding here; that would create a redundant :r1 next to an open base IR.
    upsert-manual-test-failure ... <severity> <scope>

  else:  # base_row.status in {"fixed", "wontfix"}
    # Closed base — dispatch by runner mode.
    if --as-new-findings was passed AND --force-new-regressions was passed:
      upsert-manual-test-failure ... <severity> <scope> --new-finding --force-new-regression
    elif --as-new-findings was passed:
      upsert-manual-test-failure ... <severity> <scope> --new-finding
    elif --reopen-all was passed:
      upsert-manual-test-failure ... <severity> <scope> --reopen
    else:
      # Default interactive: helper emits the closed-IR warning; runner surfaces
      # the reopen / new-finding / skip prompt, then re-calls with the chosen flag.
      upsert-manual-test-failure ... <severity> <scope>
```

`--reopen-all` follows the same shape but passes `--reopen` only when the base is closed; against open or no-base/no-family it falls through to default-mode helper calls (and against the orphan-regressions case it refuses per-scenario as shown above). `--reclassify` is orthogonal — it composes with whichever path the inspection picks. The runner does one `find-by-seed-id-family` call per failed scenario before helper invocation; the cost is well below the latency of the inspector's classification prompts in non-batch mode.

The default behavior (no companion flags) is still per-IR interactive for exact base matches: the helper's closed-IR warning surfaces a prompt asking the inspector to pick reopen/new-finding/skip; the runner re-calls the helper with the chosen flag. The orphan-family case is the exception because the helper's default exact lookup cannot detect the family after the base is gone. For that shape, the runner owns the prompt shown above and calls the helper only after the inspector chooses seed-into-family or restore-base. `--reopen-all`, `--as-new-findings`, and `--as-new-findings --force-new-regressions` are batch overrides for cycles where the inspector has already decided which side they want; they suppress the per-IR prompt but they still run the same base-status inspection so the override flags are passed only against the right cases.

**Branch B finalization.** Branch B preconditions allow entry when results-file `state=complete` regardless of whether `manual-test-state` is `running` (mid-seed-crash) or `complete` (normal post-run re-seed).

**Finalization rule:** if Branch B was entered with `sub-flow=manual-testing` AND results-file `state=complete`, OR with any other entry state where finalization is needed to reach `(none, complete)`, then **finalize on every valid exit** with:

```
progress.sh set sub-flow=none manual-test-state=complete
```

"Valid exit" — finalize whenever the inspector's interactive answer for this Branch B invocation is committed (regardless of which `policy` shape Branch B was entered with). The list below enumerates the outcome shapes; the test for "valid" is "did the inspector answer the prompt for this invocation, or was the prompt genuinely a no-op (no failures)?"

- **Inspector answered `y` or `y --classify`** (from any policy entry state): the auto-seed loop ran to its end. "Ran to its end" means every failed scenario was visited without any helper non-zero exit. Per-scenario outcomes may include `Seeded: true` (successful seed action) or `Seeded: false` (inspector picked `skip` at a closed-IR or orphan-family prompt). **Helper non-zero exit is never a per-scenario continue path**; it is a hard error that aborts the whole loop and falls under the "Invalid exit" list below.
- **Inspector answered `n`** (from any policy entry state — including the `policy=none → answered n` first-time decline AND the `policy=manual → declined flip` case): no inspector-review.md writes happen, but the workflow is genuinely done — the inspector chose manual finding authoring. Set `policy=manual` if entering with `policy=none`; leave `policy` as-is if it was already `manual`.
- **No-failures no-op:** `failed == 0` at Branch B entry; no prompt fires. Confirm `policy=none` and finalize.
- **`auto-seed` re-seed completed:** entered with `policy=auto-seed`, the loop ran. Idempotent zero-diff is fine; per-scenario seed-action outcomes flip `Seeded:` per the rules in § 2.2.

"Invalid exit" (do NOT finalize, leave markers untouched):

- Precondition refusal (e.g., `current-stage != 5`, plan file missing, results state still in-progress).
- Hard error mid-loop (helper non-zero exit, schema failure, mutual-exclusion refusal, inspector aborted via Ctrl-C). The next invocation can pick up where the prior left off; do not promote `manual-test-failure-policy`, do not clear `sub-flow`, and do not set `manual-test-state=complete`.

Finalization tracks "is the workflow genuinely done with the manual-test phase" — not "did this invocation write anything." All four valid Branch-B outcomes converge on done-ness once the inspector answers the prompt; refusal/error paths defer.

The write is idempotent — running it from `(manual-testing, running)` lands `(none, complete)`; from `(manual-testing, complete)` lands `(none, complete)`; from `(none, complete)` (clean post-finalization — re-entering `--seed-only` to re-seed observations) is a no-op; from `(none, none)` with results=complete (the recoverable stale-progress state described at Branch A's pre-normalization read) lands `(none, complete)`. Only the `(none, complete)` case is genuine post-finalization; `(none, none) + results=complete` is a stale-progress recovery, not a clean finalization residue.

After finalization, the next `/mi-continue` lands in the Inspector Handler.

**Branch B never resumes the per-scenario loop.** Branch B's `state: complete` precondition refuses any in-progress invocation before the runner reaches this point. This is an explanatory note for readers landing here from § 3.1.3's `state=complete && sub-flow=manual-testing` case, which auto-fires Branch B and might otherwise look like it could resume the loop — it cannot, because by the time `state=complete` was written, the per-scenario loop had finished (§ 2.2 step 4 ordering). If the run is somehow genuinely paused mid-loop (`results-file state=in-progress`) and Branch B is invoked anyway, the precondition refuses with "Manual test still in progress at scenario `<X>`. Resume normally with `/mi-manual-test-run` (no flag), then use `--seed-only` if you need to re-seed after completion."

**Branch C — `--finalize-skipped` invocation.**

Branch C is the rare-path bulk-skip-and-finalize escape hatch. It is **not** part of Branch A's flow: it does not run the local-environment-up phase, does not render the current scenario, and does not prompt the inspector for a verdict on any scenario. It writes skip verdicts for every uncommitted scenario, then converges directly into the auto-seed/finalization logic in step 4.

**Branch C — preconditions (in addition to the common preconditions above):**

- `workflow-stream/<feature>/implementation/manual-test-plan.md` exists.
- `workflow-stream/<feature>/implementation/manual-test-results.md` exists.
- **Results frontmatter passes the same corruption + active-plan ownership validation as Branches A and B.** YAML must parse; required keys present (`feature`, `state`, `current-scenario`, `plan-id`, `seed-family-id`, counts); `state` value in `[in-progress, complete]`; `current-scenario` if non-null must be a scenario id present in the active plan; AND `results.feature == <active-feature>`, `results.plan-id == current manual-test-plan.md id`, `results.seed-family-id == current manual-test-plan.md seed-family-id`. Refuse on any failure with the same corruption/stale-results diagnostic shape as Branches A and B (naming the offending field/value and recommending the by-hand fix or `/mi-manual-test-plan --force`). No mutation. This guard is what stops `--finalize-skipped` from writing bulk-skip verdicts into a results file that belongs to a different feature, a stale plan, or a different seed-family — producing canonical-looking-but-wrong artifacts that the rest of the pipeline would happily ingest.
- `sub-flow == manual-testing`
- `manual-test-state == running`
- Results frontmatter `state: in-progress`.
- results-file `current-scenario != null`

On any of these failing, refuse with a specific diagnostic:

- "Manual test isn't running — nothing to finalize-skip. (`sub-flow=<X>`, `manual-test-state=<Y>`.) If the plan was generated but the run never started, just don't run it."
- "Manual test isn't paused — `current-scenario` is null. The run hasn't reached scenario 1 yet."

Without these guards, the common preconditions (which permit `manual-test-state=none`) would let the inspector bulk-skip an unstarted deferred plan, producing a results file full of `bulk-skipped` verdicts for a phase that never ran — confusing and useless.

**Branch C — pre-bulk-skip cursor-integrity check.** Before writing any skip verdicts, parse verdict blocks using § 4.2.1, apply duplicate self-healing, and validate that every scenario id ordered before `current-scenario` in the plan has exactly one **valid parsed verdict block**. A heading alone is not enough: missing `Verdict:`, invalid verdict value, or any other parser-refusal condition counts as missing/corrupt. The runner's normal flow guarantees this (cursor advances only after the verdict commits, per § 2.2 step 3.4), but reachability through manual frontmatter edits, legacy results files, or a deleted/malformed-verdict-block-with-advanced-cursor corruption shape isn't ruled out. If any scenario before the cursor lacks a valid verdict, refuse with diagnostic: `--finalize-skipped: scenario <X> is ordered before current-scenario <CURSOR> in the plan but has no valid verdict block (<reason>). Inspect manual-test-results.md and either restore the verdict, rewind current-scenario by hand, or run /mi-manual-test-plan --force to start over.` No mutation. This makes `--finalize-skipped` an honest finalization escape hatch rather than a tool that silently papers over genuine corruption.

**Branch C — flow:**

1. **Parse and self-heal verdict blocks** (§ 4.2.1), then run the cursor-integrity check above. Refuse on any failure.
2. **Write bulk-skip verdicts.** For every scenario id from `current-scenario` onward (in plan order), upsert a verdict block with `Verdict: skip`, `Observation: bulk-skipped`, a `Recorded at` timestamp, and `Seeded: false`. Pre-existing verdicts at or after `current-scenario` are left as-is (Branch C never overwrites a real verdict; it only writes for scenarios that lack one — i.e., `current-scenario` and everything after it that the runner hadn't reached yet). Recompute `passed`/`failed`/`skipped` counts from the body. Set frontmatter `current-scenario: null`.
3. **Converge into Branch A's step 4 (loop completion).** From here, the auto-seed prompt fires for any failed scenarios (bulk-skipped scenarios are NOT failures and do not enter the auto-seed loop), the helper writes seeded IRs per the family-inspection rules, and the LAST mutation is `progress.sh set sub-flow=none manual-test-state=complete`. **Terminal state is `manual-test-state=complete`, NOT `skipped`** — the run reached its terminal state, just with a higher skipped count. § 1.3 schema enforces this split: `skipped` is reserved for "phase declined entirely at stage-5 prompt," not "bulk-skip remaining."

Branch C explicitly does NOT run any of: the local-environment-up phase (the run is being abandoned, not resumed), the per-scenario render/wait loop (no scenarios to ask about), or the pre-render verdict-already-committed check from Branch A step 3.1 (no rendering happens). The convergence into step 4 is the only flow shared with Branch A.

**Auto-seed ownership recap.** `mi-manual-test-run` is the single owner for mutations that originate from manual-test results. The Inspector Handler may still run its existing review-file canonicalization for inspector-authored review text, but it must not auto-seed, reopen, reclassify, or rewrite manual-test seeded IR blocks based on `manual-test-results.md`; it only surfaces the manual-test summary line. The deterministic **seed-id** (`manual-test:<seed-family-id>:<scenario-id>`) written as a structured `- seed-id:` field on each auto-seeded IR-NNN block is the correctness mechanism that makes the seeding loop idempotent. The `Seeded:` boolean in the results file is a display/diagnostic cache — not load-bearing for correctness — and `--seed-only` mode bypasses it entirely (always greps inspector-review.md for the seed-id, so observation edits propagate).

**Critical design point — context discipline:**

- Each scenario's full prompt is **rendered fresh from the plan file** every iteration, not held in conversation as a growing block.
- The chat echo per scenario is one line.
- Detailed verdicts (multi-line observations from the inspector) go to `manual-test-results.md` body, not to chat history. If the inspector types a long observation, the skill writes it to the file and echoes back only `<ID> ❌ failed (observation written to results file)`.

### 2.3 `mi-manual-test-abort` — not creating

Considered, rejected. Aborting a manual test partway should just be `pause` followed by ignoring the resume prompt; the run is non-destructive (no commits, no progress-stage advance). If the inspector wants to end the run early but keep the partial results, use `--finalize-skipped` (terminal state `complete`). If the inspector wants to fully cancel the manual-test phase from outside the run, set `manual-test-state=skipped` via `progress.sh set` directly. Adding a dedicated abort skill is overkill.

---

## 3. Existing skills touched

### 3.1 `commands/mi-continue.md`

#### 3.1.1 Resume Step 7 (stage-5 hand-off prompt)

Currently this step (in the Resume Handler) prints "Stage 5 — ready for your review. Look at: commits …" and tells the inspector to write findings and type `/mi-continue`.

Change: prepend the manual-test offer.

```
"Stage 5 — ready for your review.

Before reviewing the implementation, would you like a manual test plan generated for this feature? (`y`/`n`)
  - `y` — I'll generate `workflow-stream/<feature>/implementation/manual-test-plan.md` based on the blueprint + implementation diff + a codebase scan. After generation I'll offer to run it interactively. Failures can auto-seed as findings.
  - `n` — skip manual testing; go directly to findings authoring (existing flow).

Reply `y` or `n`."
```

- On `y`: auto-fire `/mi-manual-test-plan --from-resume`. The flag suppresses the duplicate no-existing-plan y/n prompt at § 2.1 step 2; if a plan already exists, § 2.1 uses it unchanged instead of rotating it silently. Stop driving (the new skill takes over and converges back into the existing flow).
- On `n`: set `manual-test-state=skipped`, `manual-test-failure-policy=none`. Print the existing stage-5 review message (commits + diagrams + write findings + `/mi-continue`). Done.

#### 3.1.2 Dispatcher table (Step 2)

The existing dispatch table in `commands/mi-continue.md` has a `5 | (any)` row routing to the Inspector Handler. A new `5 | manual-testing` row would be **shadowed** by the `(any)` row if appended after it — table evaluation is top-down and the first match wins. Insert the new row **immediately before** the existing `5 | (any)` row:

| Current stage | Sub-flow         | Handler                                                       |
| ------------- | ---------------- | ------------------------------------------------------------- |
| 2             | (any)            | Approve Handler — auto-fire `/mi-plan-implementation`         |
| 3             | (any)            | Post-chain resume (Resume Handler)                            |
| **5**         | **`manual-testing`** | **Manual-Test-Resume Handler** (NEW — must come BEFORE the `5 | (any)` row) |
| 5             | (any)            | Inspector-review received (Inspector Handler)                   |
| 6             | reviewing        | Post-review-session resume (Review-Resume Handler)            |
| 7             | (any)            | Stage-7 finalize                                              |
| any other     | —                | Delegate to `/mi-resume-workflow`                             |

When implementing, also update the prose right after the table to note: "The `5 | manual-testing` row covers paused or in-progress manual-test runs — the Manual-Test-Resume Handler re-enters `/mi-manual-test-run` to continue from the persisted `current-scenario`. Without this row, paused manual tests would be misrouted to the Inspector Handler and treated as normal findings review."

#### 3.1.3 New: Manual-Test-Resume Handler

Section between the Resume Handler and the Inspector Handler. Behavior:

1. Read `progress.md` `manual-test-state`, `manual-test-failure-policy`, `sub-flow`.
2. Check whether `manual-test-results.md` exists. If yes, read frontmatter `state` and `current-scenario`. If no, mark `results_missing=true`.
3. **Cases:**
   - **Plan exists, results missing.** Reachable when `/mi-manual-test-plan` set `sub-flow=manual-testing manual-test-state=running` and auto-fired `/mi-manual-test-run`, but the run crashed before step 1 created the results file. Print "Resuming manual test — results file missing, will recreate from template." Auto-fire `/mi-manual-test-run` (Branch A); step 1 of the run renders the results template from scratch and step 2 runs the env-up phase as if from fresh.
   - **Plan missing, results missing, `sub-flow=manual-testing`.** Inconsistent state — markers say a run is in progress but neither input file exists. Print diagnostic: "Inconsistent manual-test state: sub-flow=manual-testing but no plan or results file. Reset with `progress.sh set sub-flow=none manual-test-state=none` and start over via /mi-continue (which will re-prompt for plan generation), OR run /mi-resume-workflow for full diagnosis." Stop. Do NOT auto-mutate.
   - `state=in-progress, current-scenario=<X>` (paused mid-run): print "Resuming manual test at scenario `<X>`. Re-confirm your local environment is up." Auto-fire `/mi-manual-test-run` (Branch A).
   - `state=in-progress, current-scenario=null` (results file rendered but loop never reached scenario 1): same as above; auto-fire `/mi-manual-test-run` (Branch A) to start from scenario 1.
   - `state=complete` AND `sub-flow=manual-testing`: REACHABLE, not defensive. `/mi-manual-test-run` writes `state=complete` BEFORE the auto-seed loop and BEFORE clearing `sub-flow` (§ 2.2 step 4 ordering — deliberately, so a crash mid-seed leaves `sub-flow=manual-testing` for re-entry). The handler must NOT clear sub-flow and fall through to the Inspector Handler — that would bypass the seed recovery path. Instead: **auto-fire `/mi-manual-test-run --seed-only`** (Branch B), whose entry-guard table (§ 2.2 Branch B entry) dispatches on `manual-test-failure-policy` and either re-prompts, re-runs the upsert loop, or finalizes. Branch B clears `sub-flow=none` as its last mutation; the next `/mi-continue` lands in the Inspector Handler.
4. After auto-fire, stop driving (the run skill drives the inspector; another `/mi-continue` post-run lands in the Inspector Handler).

#### 3.1.4 Inspector Handler (stage 5 main path)

`mi-manual-test-run` owns seeding per § 2.2; the Inspector Handler's only manual-test responsibility is a read-only summary line.

- **Read `workflow-stream/<feature>/implementation/manual-test-results.md` if present.** Surface a one-line summary in the entry log: `Manual test: <passed>/<total> passed, <failed> failed (failure-policy: <auto-seed|manual|none>; seeded <seeded_failed>/<failed> failures).` `seeded_failed` is computed from failed verdict blocks whose `Seeded:` field is `true`; do not infer it from `manual-test-failure-policy`.
- The Inspector Handler does NOT mutate `inspector-review.md` **because of manual-test results**. By the time the handler runs (inspector typed `/mi-continue` after manual-test exit), `mi-manual-test-run` has already either run the auto-seed loop (possibly leaving some failed scenarios unseeded if the inspector picked `skip` on per-IR prompts) or recorded `failure-policy=manual` and written nothing. Seeded failures are already-canonical `### IR-NNN` blocks via `review.sh upsert-manual-test-failure`. The handler must not auto-seed, reopen, reclassify, or rewrite seeded IR blocks from `manual-test-results.md`. The existing stage-5 canonicalization step remains allowed to mutate `inspector-review.md` for **inspector-authored free-form review text**; that is a separate legacy behavior and not a manual-test write path.

No new boolean fields, no active-block idempotency markers, no double-write risk. Idempotency is enforced durably by the `- seed-id:` field on each auto-seeded IR-NNN block (§ 3.7.1's `upsert-manual-test-failure`). The single-owner model in § 2.2 means the Inspector Handler's manual-test job is summary-only; canonicalization of unrelated free-form review text still belongs to the existing Inspector Handler path.

### 3.2 `commands/mi-review.md`

#### 3.2.1 Step 2.5 `## Implemented surface` (review-context.md generation)

If `manual-test-results.md` exists, append a `## Manual test results` section to `review-context.md`. **The `IR-NNN` citation must be resolved at generation time** — not read from the results-file `Cited as IR-NNN:` cache, which can drift if the review session renumbered or merged blocks since auto-seeding.

Generation algorithm:

```
read manual-test-results.md frontmatter (passed, failed, total, plan-id, seed-family-id)
emit "## Manual test results"
emit "<passed>/<total> scenarios passed; <failed> failed."
for each failed scenario S in results-file order:
  base_seed_id = "manual-test:" + seed_family_id + ":" + S.id
  family = $(review.sh find-by-seed-id-family "$feature" "$base_seed_id")
    # returns IR-NNN list for base + every base:rN, ordered by NUMERIC suffix ascending:
    #   base (generation 0), :r1, :r2, ..., :r10, :r11.
    # NOT lexicographic — :r10 must sort AFTER :r2, not before.
  cited_row = pick from family in priority order:
    1. open regression IR with the highest numeric suffix (max-N where status=open and N≥1)
    2. else base IR if status=open
    3. else IR with the highest numeric suffix overall (regression or base) regardless of status — preserves traceability to the latest seeded artifact
    4. else empty (no IR exists for this scenario)
  if cited_row non-empty:
    cited_ir = cited_row.IR-NNN
    cited_status = cited_row.status
    if cited_status == "open":
      emit "Scenario {S.id}: {S.observation_one_line}; cited in {cited_ir} (open)"
    else:
      emit "Scenario {S.id}: {S.observation_one_line}; cited in {cited_ir} (status: {cited_status}; no open seeded finding remains)"
    update results-file scenario S — set "Cited as IR-NNN: {cited_ir}" (refresh the cache; status stays in review-context output, not in this cache field)
  else:
    emit "Scenario {S.id}: {S.observation_one_line}; (auto-seed declined or all family IRs deleted — no IR)"
    update results-file scenario S — clear the cache by rendering the exact blank markdown bullet "- **Cited as IR-NNN:**" with nothing after the colon. This reflects the missing-IR state; without it, a previously-cached IR-NNN survives in the results file even after the review session deletes the entire family, and downstream consumers that read the cache directly would cite a nonexistent IR. The literal string "null" is invalid.
```

This requires a new helper `review.sh find-by-seed-id-family <feature> <base-seed-id>` that returns IR-NNNs for the base and every `<base>:r<N>` match. See § 3.7.

Two important invariants:

- The `Cited as IR-NNN:` field in `manual-test-results.md` is a **cache** populated by review-context generation, NOT by `mi-manual-test-run`. Auto-seed writes blocks but does not write back the resulting `IR-NNN` to the results file (it would race with the review session's renumbering). Review-context regeneration is the unique writer.
- `find-by-seed-id-family` returning empty is a *recoverable* state, not an error: the inspector may have manually deleted every auto-seeded IR for the scenario (base + every regression). Emit the "no IR" form and **clear the `Cited as IR-NNN:` cache field** in the results-file scenario block by rendering exactly `- **Cited as IR-NNN:**` with no value after the colon. Consumers treat a blank value as "no current citation" rather than "never cited"; the literal string `null` is invalid.

Brainstorming sub-agents reading `review-context.md` get the manual-test signal in their first read, with up-to-date IR citations, without main needing to re-narrate. ~1 line per failure; bounded.

No `schemas/review-context.schema.yaml` change is required unless review-context frontmatter changes. The current schema validates frontmatter only; the new `## Manual test results` body section belongs in `commands/mi-review.md` / template-generation docs, not in the JSON schema.

#### 3.2.2 Step 3a sub-agent prompt

The "Required first reads" block lists `review-context.md` and `inspector-review.md`. No change required; the manual-test info travels in via `review-context.md`. If the sub-agent needs the verbose plan/results detail, it can be added to "On-demand fallbacks" pointing to `workflow-stream/<feature>/implementation/manual-test-plan.md` and `workflow-stream/<feature>/implementation/manual-test-results.md`.

### 3.3 `commands/mi-complete-workflow.md` — archive list extension required

The archive step in `commands/mi-complete-workflow.md` does **not** recursively move the entirety of `implementation/`. It enumerates a fixed list:

```bash
for artifact in inspector-review.md review-context.md change-summary.md grounding-report.md; do
  [[ -e "$impl_dir/$artifact" ]] && mv -n "$impl_dir/$artifact" "$archive_dir/$artifact"
done
[[ -d "$impl_dir/diagrams" ]] && mv -n "$impl_dir/diagrams" "$archive_dir/diagrams"
```

Manual-test files would be silently left behind in `implementation/` (and then either zombied across the next cycle or — worse — picked up as stale state). Two viable fixes; pick one during implementation:

**Option A (minimal — recommended):** add manual-test files to the enumerated list:

```bash
for artifact in inspector-review.md review-context.md change-summary.md grounding-report.md \
                manual-test-plan.md manual-test-results.md; do
  [[ -e "$impl_dir/$artifact" ]] && mv -n "$impl_dir/$artifact" "$archive_dir/$artifact"
done
[[ -d "$impl_dir/diagrams" ]] && mv -n "$impl_dir/diagrams" "$archive_dir/diagrams"
[[ -d "$impl_dir/manual-test-plan.history" ]] && mv -n "$impl_dir/manual-test-plan.history" "$archive_dir/manual-test-plan.history"
```

**Option B (broader, riskier):** convert the archive step to "move everything in `implementation/` not in a known-skip set." Cleaner long-term — every future addition gets archived for free — but riskier (could pick up debris files). Defer to a separate refactor unless there's a reason to bundle.

Update the trailing prose ("The historical snapshot is then complete: …") to mention the manual-test files when option A lands.

### 3.4 `commands/mi-abort-workflow.md` — clear list extension required

Same enumeration pattern in `commands/mi-abort-workflow.md`:

```bash
rm -rf "$impl_dir"/diagrams
rm -f "$impl_dir"/inspector-review.md
rm -f "$impl_dir"/review-context.md
rm -f "$impl_dir"/change-summary.md
rm -f "$impl_dir"/grounding-report.md
```

Add manual-test files (matching whichever option is chosen for § 3.3):

```bash
rm -f "$impl_dir"/manual-test-plan.md
rm -f "$impl_dir"/manual-test-results.md
rm -rf "$impl_dir"/manual-test-plan.history
```

**Field-reset addition.** `mi-abort-workflow.md` calls one of two paths — `progress.sh requeue` (nulls the active block; new fields default-init on next `activate`) OR `progress.sh reset` (rebuilds the active block preserving feature/branch/worktree). The reset path enumerates active fields explicitly; adding new required fields without updating the reset block fails schema validation on retry-mode abort. § 3.6 covers the reset diff.

### 3.5 `commands/mi-resume-workflow.md`

The diagnostic dispatcher needs to recognize `sub-flow=manual-testing` and recommend `/mi-continue` as the next step (which will then route to the Manual-Test-Resume Handler).

### 3.6 `scripts/blueprints.sh` and `scripts/progress.sh`

**`blueprints.sh` (not `quest.sh`)** — manual-test artifacts are feature-scoped and live next to other `implementation/` files; rotation belongs alongside the existing blueprint-rotation pattern in `blueprints.sh`, not in the cycle-scoped `quest.sh`.

- `blueprints.sh manual-test-plan-path <feature>` — prints `workflow-stream/<feature>/implementation/manual-test-plan.md`.
- `blueprints.sh manual-test-results-path <feature>` — prints `workflow-stream/<feature>/implementation/manual-test-results.md`.
- `blueprints.sh manual-test-plan-rotate <feature>` — moves the current plan file (and results, if present) into `workflow-stream/<feature>/implementation/manual-test-plan.history/<UTC-timestamp>/`. Called by `/mi-manual-test-plan` step 4 on re-invocation/regeneration, by the `--force` path in `/mi-manual-test-plan`, and by the explicit `--discard-existing` path when the inspector wants to discard an existing plan and mark the phase skipped. The caller must read and preserve the old plan's `seed-family-id` before invoking this helper unless `--new-seed-family` was explicitly passed.

**`progress.sh` reset block** — add the two new fields with default `none` so the reset rebuild produces a schema-valid active block. Diff:

```python
fm['active'] = {
    'feature': old['feature'],
    'branch': old.get('branch'),
    'current-stage': 2,
    'sub-flow': 'none',
    # ... existing fields ...
    'inspector-review-completed': False,
+   'manual-test-state': 'none',
+   'manual-test-failure-policy': 'none',
    'worktree-path': old.get('worktree-path'),
    'git-common-dir': old.get('git-common-dir'),
    'git-worktree-dir': old.get('git-worktree-dir'),
}
```

Same fields, same defaults, same place as in the activate block (§ 1.5). Without this, retry-mode abort (`progress.sh reset`) would produce an active block missing two required schema fields and the validation step at the bottom of `reset()` would fail.

### 3.7 `scripts/review.sh` — required helpers

Auto-seeding writes canonical IR blocks with `- source:` and `- seed-id:` fields. The supporting `review.sh` helpers below are **required, not optional**, with precise contracts. All auto-seeding goes through these helpers — `mi-manual-test-run` does NOT edit `inspector-review.md` directly.

#### 3.7.1 `review.sh upsert-manual-test-failure` (REQUIRED)

```
review.sh upsert-manual-test-failure <feature> <seed-family-id> <scenario-id> <severity> <scope> \
    [--reclassify] [--reopen | --new-finding [--force-new-regression]] [--file-citation <path:line>]
```

**Argument convention:** the `<observation>` body is read from **stdin**, mirroring `review.sh add` (`details="$(cat)"`). Only structured/short values are positional. Observations are explicitly allowed to be multi-line, and positional args don't survive shell quoting reliably for multi-line content.

Caller pattern (use `printf '%s\n'`, not `echo`, for the observation — `echo`'s handling of `-n`-prefixed strings and backslashes is shell-specific and would silently mangle some observations):

```bash
IR_ID="$(printf '%s\n' "$observation_text" | review.sh upsert-manual-test-failure "$feature" "$seed_family_id" "$scenario_id" "$severity" "$scope")"
```

For the closed-IR-aware caller pattern (with stderr inspection and exit-code guard), see "Closed-IR caller pattern" further down this section.

**Arguments:**

- `<seed-family-id>` — stable manual-test seed namespace copied from `manual-test-plan.md` / `manual-test-results.md` frontmatter. It is preserved across `/mi-manual-test-plan --force` re-renders unless `--new-seed-family` is explicitly requested. The helper uses it to compute `manual-test:<seed-family-id>:<scenario-id>`; it does not use the per-render plan `id`.
- `<severity>` ∈ `blocker | major | minor` — passed by `mi-manual-test-run` based on the auto-seed prompt's classification (default `major` for failed scenarios; the run skill may downgrade based on the observation text).
- `<scope>` ∈ `fix | re-implement | re-plan | re-spec`. Passed explicitly by the caller. **Hardcoding `fix` is wrong** — review-mode routing in `commands/mi-continue.md` derives review-mode-suggestion from the scope distribution; if every manual-test failure forces `fix`, all-fail cycles default to `direct` review mode even when failures reveal planning/spec gaps. The auto-seed prompt in `mi-manual-test-run` step 4 should ask the inspector for the scope per failed scenario (or batch-default with override), and the run skill passes the chosen scope through to this helper.
- `--reclassify` — optional flag. On update, replace `- severity:` and `- scope:` from arguments instead of preserving existing values. `status` and `fix-note` remain preserved regardless. Composes with `--reopen` and `--new-finding` (independent axis).
- `--reopen` — optional flag. When the matched IR has `status` ∈ {`fixed`, `wontfix`}, flip status back to `open`, clear `fix-note`, and update `details` from the new observation. Has no effect when the matched IR is already open or no match exists. **Mutually exclusive with `--new-finding`** (refuse with diagnostic if both passed).
- `--new-finding` — optional flag. Triggers the "Family-aware logic" block in "Behavior" below (the step 2 short-circuit). Always operates on the seed-id family, regardless of whether the base seed-id matches an open, closed, or no IR. Allocates or reuses a regression IR per the family-aware idempotent rules. **Mutually exclusive with `--reopen`** (refuse with diagnostic if both passed).
- `--force-new-regression` — optional flag, only meaningful with `--new-finding`. Skips the family-reuse step and allocates the next `:r<N>` when the family is non-empty; **refuses non-zero with stderr diagnostic and no mutation when the family is empty**. Default-off because it breaks idempotency; require explicit inspector opt-in via runner flag (§ 2.2 Branch B `--seed-only --as-new-findings --force-new-regressions`), which itself gates on closed-base status per the inspection algorithm.
- `--file-citation <path:line>` — optional; appended to the IR body if the plan tied this scenario to specific code paths.
- **stdin** — the observation body. Free-form, multi-line allowed. Goes into the `- details: |` block.

**Behavior — upsert by seed-id:**

The dispatch order is fixed: mutual-exclusion check first, then the `--new-finding` short-circuit, then exact-seed-id lookup, then status-aware branching.

0. **Mutual-exclusion check.** If both `--reopen` and `--new-finding` are passed, refuse with stderr diagnostic and non-zero exit. No file mutation, no stdout output.
1. **Compute seed_id** = `"manual-test:<seed-family-id>:<scenario-id>"`.
2. **`--new-finding` short-circuit.** If `--new-finding` was passed, jump to the **Family-aware logic** block below, regardless of whether the base seed-id matches an existing block or what status the matched block has. The base IR is never the target for `--new-finding`; the family is.
3. **Exact-seed-id lookup.** Search `inspector-review.md` (under the `## Implementation Review` section per `templates/inspector-review.md.tmpl`) for an `### IR-NNN` block whose `- seed-id:` field equals `seed_id`. Steps 4–6 below execute only when `--new-finding` was NOT passed (i.e., default mode or `--reopen`).
4. **If found AND existing block has `status: open`:** preserve the existing `IR-NNN` id, `- status:` value, `- fix-note:` value, `- severity:`, and `- scope:`. Replace `- details:` only; refresh `- source:` and `- seed-id:` to canonical values; write back. Output: the preserved `IR-NNN`. (`--reopen` is silently a no-op against an open IR — see invariants.)
5. **If found AND existing block has `status` ∈ {`fixed`, `wontfix`}:** the prior failure was resolved or accepted-as-known by the review session. Re-seeding's effect depends on the override flag (or absence thereof):
   - **No `--reopen` flag (default):** do NOT update `- details:`, `- source:`, `- seed-id:`, `- severity:`, `- scope:`, or `- fix-note:` — the closed IR is left exactly as-is. **Stdout is exactly `<IR-NNN>\n`** (same contract as every other path so command substitution stays clean). The warning text goes to **stderr only**, formatted as: `warning: <feature> <seed-id> matched IR-NNN with status=<fixed|wontfix>; details not updated; pass --reopen to overwrite or --new-finding to record as a regression`. Callers detect the closed-IR case by checking stderr (or by re-reading the IR's status post-call) — they do NOT parse stdout for warnings. Exit 0. This is the safe default: fresh failure observations on a closed IR mean either the fix didn't take or the test scenario covers something subtly different; auto-overwriting the resolved IR's details would silently mask that.
   - **`--reopen` flag:** flip `- status:` back to `open`, clear `- fix-note:`, and update `- details:` from the new observation. The inspector is explicitly saying "this is the same failure surface; reopen the IR." Severity and scope are preserved unless `--reclassify` is also passed. Output: the IR-NNN.
6. **If not found:** allocate the next free `IR-NNN` id (max-existing+1, default `IR-001`); append a new canonical block at the bottom of `## Implementation Review` with the helper's `<severity>` and `<scope>` arguments and `- status: open`. Output: the new `IR-NNN`. (`--reopen` is silently a no-op when no match exists; the insert path writes `status: open` regardless.)

**Family-aware logic (`--new-finding` path, entered via the step 2 short-circuit).**

This path runs regardless of whether a base IR exists for `seed_id` and regardless of its status. Treat the failure as a *separate* IR with a regression seed-id, idempotent across re-seeds. **Step order matters:** `--force-new-regression`'s empty-family refusal must be checked BEFORE the empty-family fall-through to base insert; otherwise a naive implementation reaches the fall-through first and silently allocates a base IR for `--force-new-regression` even though the flag's contract says it must refuse. The numbered order below is the canonical implementation order:

1. **Family lookup.** Look up the seed-id family for `manual-test:<seed-family-id>:<scenario-id>` — i.e., every IR whose seed-id is the exact base or `<base>:r<N>` for any canonical positive integer `<N>` (via `review.sh find-by-seed-id-family`, § 3.7.2). Suffix `<N>` is parsed as an integer; ordering is numeric, NOT lexicographic. (`:r10` sorts AFTER `:r2`.)
2. **`--force-new-regression` empty-family refusal.** If `--force-new-regression` is passed AND the family is empty (no base IR, no regressions): refuse with non-zero exit and stderr diagnostic: `--force-new-regression requires an existing seed-id family; no base or regression IR exists for <seed-id>`. No file mutation, no stdout. Stop. Rationale: "regression of nothing" is semantically incoherent — refuse explicitly rather than silently fall through to base insert. The runner-level `--force-new-regressions` (§ 2.2 Branch B runner-level flags) gates on closed-base status before passing this helper flag, so this refusal is a defensive backstop.
3. **`--force-new-regression` non-empty-family allocate.** If `--force-new-regression` is passed AND the family is non-empty: allocate `<N> = max-existing-regression-N + 1` (numerically), or `<N> = 1` if no regressions exist yet. Append a new IR with seed-id `<base>:r<N>` and `status: open`, using the helper's `<severity>` and `<scope>` arguments. Output: the new IR-NNN. Stop. (The base IR's status is irrelevant; never touched.)
4. **Idempotent reuse of latest open regression.** Find the latest **open** regression IR in the family — the IR with the highest numeric `<N>` whose `status: open` (regressions only — the base IR's status is irrelevant for `--new-finding`, even when the base is open). If found: upsert into it (preserve IR-NNN/severity/scope/status/fix-note per the open-update rules; replace details). Output: that IR-NNN. Stop. This is the idempotent path — a crash or repeated `--new-finding` against the same scenario reuses the existing open regression rather than allocating yet another `:rN`.
5. **Allocate next regression** (no `--force-new-regression`, no open regression to reuse, family non-empty). Allocate `<N> = max-existing-regression-N + 1` (numerically), or `<N> = 1` if no regressions exist yet. Append a new IR with seed-id `<base>:r<N>` and `status: open`. Output: the new IR-NNN. Stop. (The base IR is never touched.)
6. **Empty-family fall-through to base insert** (no `--force-new-regression`, no family members at all). Fall through to the default insert path: create a new IR with seed-id `<base>` (no regression suffix) and `status: open`. Output: the new base IR-NNN. `--new-finding` has no effect when there's nothing to regress from.

Net effect: re-seeding a scenario as a new finding twice in a row produces ONE regression IR (the second call upserts into the first regression's open block via step 4). Re-seeding after the regression is `fixed` produces a new `:r<N+1>` via step 5. `--force-new-regression` always allocates a parallel `:r<N>` (step 3) — except against an empty family, where it refuses (step 2). The original base IR (whether open or closed) is never touched by `--new-finding`.

**Closed-IR caller pattern.** The pattern must satisfy three constraints simultaneously: (a) preserve stderr so warnings can be inspected; (b) check the helper's exit code before using `IR_ID`, since non-zero exit means refusal — mutual-exclusion violation, schema failure, etc. — and `IR_ID` is empty or stale in that case; (c) feed the multi-line observation through `printf`, not `echo`, because `echo`'s `-n` / backslash handling is shell-specific and silently mangles observations starting with `-` or containing `\`:

```bash
stderr_tmp="$(mktemp)"

if ! IR_ID="$(printf '%s\n' "$observation" | review.sh upsert-manual-test-failure \
    "$feature" "$seed_family_id" "$scenario_id" "$severity" "$scope" \
    2> "$stderr_tmp")"; then
    # Non-zero exit: helper refused. IR_ID is empty / stale — do NOT cite it.
    # Surface stderr to the inspector and abort the per-scenario seed step.
    err="$(cat "$stderr_tmp")"
    rm -f "$stderr_tmp"
    printf 'upsert-manual-test-failure failed: %s\n' "$err" >&2
    return 1
fi

if grep -q '^warning:' "$stderr_tmp"; then
    warning_text="$(cat "$stderr_tmp")"
    # Closed-IR default path: surface warning to inspector; offer reopen / new-finding / skip.
    # On inspector choice, re-call helper with the chosen flag.
fi
rm -f "$stderr_tmp"
# Past the exit-code guard, $IR_ID holds the IR-NNN to cite.
```

Do not use `trap 'rm -f "$stderr_tmp"' EXIT` inside the per-scenario loop. Re-registering an `EXIT` trap on every scenario overwrites earlier cleanup and can clobber an outer trap. If this pattern is wrapped in a Bash function, a local temp variable plus a `RETURN` trap is also acceptable; otherwise remove the temp file immediately as shown above.

Key invariants:

- Stdout always contains exactly `<IR-NNN>\n` regardless of which path the helper took (open update / insert / closed-default / `--reopen` / `--new-finding`). Command substitution always yields a clean IR-NNN.
- Stderr is empty for normal paths (open update / insert / `--reopen` / `--new-finding`). Stderr is non-empty only on the closed-default path (the warning) or on errors (refusals, mutual-exclusion violations, schema problems).
- The caller distinguishes warnings from errors by checking exit code: closed-default warning is exit 0 with stderr; errors are non-zero exit with stderr.

**Inspector prompt on warning:** "IR-`<NNN>` is `fixed`/`wontfix`; the manual test failed it again. Pick: (a) `reopen` the IR with the new observation, (b) record this as a `new` finding (separate IR — will be `:r<N>` in the seed-id family per the Family-aware logic block above), (c) `skip` (ignore — the IR stays as-is and the failure isn't seeded)." Map to `--reopen`, `--new-finding`, or no-op respectively, and re-call the helper with the chosen flag. The first call's stdout-IR-NNN is the citation if the inspector picks `skip`.

**`Seeded:` interaction with the prompt.** The first (warning-emitting) helper call is NOT a successful seed action — the helper declined to seed because the matched IR is closed — so `Seeded:` MUST stay `false` after it. The runner flips `Seeded: true` only if the second (override-flag) call returns exit 0 with no warning on stderr — `reopen` and `new-finding` are both successful seed actions in that shape. If the inspector picks `skip`, no second call happens and `Seeded:` stays `false`; the IR-NNN from the first call may still be cited in the chat echo for traceability, but the scenario is not considered seeded.

**The `--reclassify` flag.** To override the preserve-on-update behavior for severity/scope — e.g., the inspector wants a re-seed to update classification from new arguments — pass `--reclassify`. Composes independently with **both** `--reopen` (reopen and reclassify simultaneously) **and** `--new-finding` (write the new severity/scope to the regression IR, whether reused or freshly allocated). Without `--reclassify`, severity/scope are preserved on every update path. The flag is the ONLY path to update severity/scope on an existing IR; otherwise the inspector's earlier classification persists.

**Output format:** stdout is exactly `<IR-NNN>\n`, nothing else (so callers can capture it: `IR_ID="$(review.sh upsert-manual-test-failure …)"`).

**Block format written:**

```markdown
### IR-NNN — Scenario <scenario-id> failed: <one-line summary derived from observation>
- severity: <severity>
- scope: <scope>
- status: <preserved on update; `open` on insert>
- source: manual-test
- seed-id: <seed-id>
- details: |
    Scenario <scenario-id> failed during manual test.
    Observation: <observation>
    <file-citation if provided>
- fix-note: <preserved if existed; else empty>
```

The `<seed-id>` placeholder takes one of two shapes:

- **Base insert** — first time a scenario gets seeded, default mode, or a `--new-finding` short-circuit that falls through to base insert because the family is empty:
  ```
  - seed-id: manual-test:<seed-family-id>:<scenario-id>
  ```
- **Regression insert** — `--new-finding` allocates a new `:r<N>` (or `--force-new-regression` allocates a parallel one), where `<N>` is the next integer suffix per the Family-aware logic:
  ```
  - seed-id: manual-test:<seed-family-id>:<scenario-id>:r<N>
  ```

`find-by-seed-id-family` (§ 3.7.2) treats both shapes as members of the same family and returns them with numeric-suffix ordering.

**Invariants (split by mode):**

**Universal invariants (every mode):**

- Never appends free-form text. The block is canonical from the moment it lands.
- Never deletes an existing block — `IR-NNN` ids are stable across the review session's edits.
- Stdout is exactly `<IR-NNN>\n` on success, regardless of mode. Warnings and errors go to stderr only.
- The mutual-exclusion check fires before any other work: passing both `--reopen` and `--new-finding` produces a non-zero exit with a stderr diagnostic and no file mutation.

**Default mode (no override flags):**

- Open match → upsert into the existing block: preserve IR-NNN/status/fix-note/severity/scope; replace details; refresh source/seed-id.
- Closed match → emit warning on stderr; do NOT update details; stdout is the matched IR-NNN.
- No match → insert with `status: open` and the helper's `<severity>`/`<scope>` arguments.
- Idempotent: calling twice with identical args yields byte-identical mutable fields. Two calls in a row produce zero diff after the first.

**`--reopen` mode:**

- Closed match → flip `status` to `open`, clear `fix-note`, replace details. Severity/scope preserved (override with `--reclassify`).
- Open match → behaves identically to default (the open-update path doesn't need reopening). The flag is silently a no-op against open IRs; this is intentional so callers can pass `--reopen` proactively without checking status first.
- No match → behaves identically to default (insert with `status: open`).
- NOT idempotent across status transitions (the first call flips status; the second is a no-op against the now-open IR). Idempotent across the inspector's repeated explicit reopens (calling `--reopen` twice in a row is byte-identical).

**`--new-finding` mode:**

- Closed match on base seed-id → look up family by `find-by-seed-id-family`. If a latest open regression exists (highest numeric `<N>` with `status: open`), upsert into it (open-update rules). Else allocate next `:r<N+1>`, insert with `status: open`. Original closed base IR is never touched.
- Open match (rare — the inspector explicitly passed `--new-finding` against an open IR) → behave like the closed-match path: family lookup, reuse-or-allocate. Treats open base as "already addressed" for regression purposes.
- No match → falls through to default insert path (no regression suffix; the seed-id is new).
- **Idempotent across re-seeds against the same scenario**: two `--new-finding` calls in a row produce ONE regression IR (the second upserts into the first's open block).
- NOT idempotent across the regression's own status transitions: closing `:r1` then re-running `--new-finding` allocates `:r2`.

**`--force-new-regression` mode** (only meaningful with `--new-finding`):

Evaluation order matches the family-aware logic above — the force checks happen at the top, before any insert path:

- **Family empty + `--force-new-regression`** → refuse with non-zero exit and stderr diagnostic `--force-new-regression requires an existing seed-id family; no base or regression IR exists for <seed-id>`. No mutation, no stdout. "Force a regression of nothing" is rejected explicitly.
- **Family non-empty + `--force-new-regression`** → always allocate a new `:r<N>` regardless of whether an open regression exists. Stops here — never reaches the reuse step or the next-regression-allocate step.
- NOT idempotent: every successful call produces a new IR. Reserved for the explicit "this is a different regression that happens to share a scenario id" case. The runner does NOT pass this by default; the runner-level `--force-new-regressions` (§ 2.2 Branch B runner-level flags) additionally gates on closed-base status, so the empty-family refusal is a defensive backstop rather than a routine path.

**`--reclassify` mode** (composes with any of the above):

- Replaces `severity` and `scope` from arguments instead of preserving existing values.
- Does NOT affect status or fix-note preservation rules — those are still preserved (or transitioned by `--reopen`).
- Composes with `--reopen` (reopen + reclassify in one call) and with `--new-finding` (allocate-or-reuse, then write the new severity/scope to the resulting IR).

#### 3.7.2 `review.sh find-by-seed-id` and `find-by-seed-id-family` (REQUIRED)

```
review.sh find-by-seed-id        <feature> <seed-id>
review.sh find-by-seed-id-family <feature> <base-seed-id>
```

**`find-by-seed-id`** — exact-match lookup. Output: stdout is exactly `<IR-NNN>\n` if a matching block exists in `inspector-review.md`, empty (exit 0) if not.

**`find-by-seed-id-family`** — family-match lookup. Returns every IR whose seed-id is exactly `<base-seed-id>` OR whose seed-id starts with the literal string `<base-seed-id>:r` followed by a canonical positive decimal integer suffix (`:r1`, `:r2`, …; no `:r0`, no leading zeroes like `:r02`, no non-digit suffix). Output format: one row per matching IR on stdout, tab-separated as `<IR-NNN>\t<seed-id>\t<status>`, **ordered by numeric suffix ascending**: base first (generation 0), then `:r1`, `:r2`, `:r3`, …, `:r10`, `:r11`, … . **NOT lexicographic** — a lexicographic sort would place `:r10` between `:r1` and `:r2`, breaking the "newest" semantics every consumer relies on. The implementation must parse the integer suffix and sort numerically. Empty stdout if no family member exists.

Family matching is literal, not regex-semantic. Scenario ids can contain dots (`A.1`) and other characters that have meaning in regular expressions. Prefer exact string comparisons:

```
seed_id == base_seed_id
OR
seed_id starts with base_seed_id + ":r" AND the remaining suffix matches [1-9][0-9]*
```

If the implementation uses `grep`, `sed`, `awk`, or another regex engine, it must escape `<base-seed-id>` before building the pattern. A base seed-id of `manual-test:P:A.1` must not match `manual-test:P:A-1`, `manual-test:P:A11`, or `manual-test:P:A.10`.

Used by:

- `upsert-manual-test-failure --new-finding` (§ 3.7.1) to find the latest open regression IR for the idempotent reuse path.
- Review-context generation (§ 3.2.1) to resolve a scenario's citation to the most relevant family member (newest open regression preferred over base).

#### 3.7.3 `FIELD_RE` and canonical output ordering (REQUIRED)

`scripts/review.sh`'s `FIELD_RE` currently recognizes only `severity|scope|status|details|fix-note`. This change is a **hard prerequisite** for any auto-seed work landing — without it, seeded blocks will be corrupted by the next `canonicalize` pass (the `source` and `seed-id` lines won't match `FIELD_RE` and the block-detection state machine will treat them as freeform paragraphs, breaking `IR_HEAD_RE` boundaries).

Required diff:

```python
FIELD_RE = re.compile(r'^- (severity|scope|status|source|seed-id|details|fix-note):')
```

Note the field ordering: `source` and `seed-id` come BEFORE `details` so the `details: |` block scalar (which uses `CONT_RE` four-space indentation matching) stays at the end of the field list. Order matters for `review.sh add` and any structured-block writer — keep all writers consistent.

#### 3.7.4 `review.sh add` extension (REQUIRED)

Whatever existing path `review.sh add` uses for emitting structured blocks must accept `source` and `seed-id` as known optional fields and emit them in the order specified above. If `review.sh add` is currently fixed-field, generalize it.

#### 3.7.5 Tests (REQUIRED before auto-seed work merges)

In seed-id examples below, `P`, `F1`, and `F2` are `seed-family-id` values, not per-render plan ids.

- `upsert-manual-test-failure` is idempotent (call twice with identical args, file content identical for mutable fields).
- `upsert-manual-test-failure` preserves `IR-NNN` id on second call with edited observation.
- `upsert-manual-test-failure` preserves `fix-note` value across upserts.
- `upsert-manual-test-failure` preserves both `status` AND `details` on a closed IR by default. Set up an IR with `status: fixed`, a known `fix-note`, and a known `details` body. Call upsert again with a different observation. Assert ALL of: status is still `fixed`, fix-note is unchanged, details are unchanged, severity and scope are unchanged, source and seed-id are unchanged. Stderr carries the closed-IR warning. Stdout is exactly `<IR-NNN>\n`. The separate `--reopen` test below owns the details-overwrite path; this test owns the no-mutation default.
- `upsert-manual-test-failure` preserves `severity` and `scope` across upserts by default. Set up an IR with `severity=blocker scope=re-plan`; call upsert with `severity=major scope=fix` arguments; assert the IR still has `severity=blocker scope=re-plan`.
- `upsert-manual-test-failure --reclassify` overrides the preserve-on-update for severity and scope. Same setup as above; pass `--reclassify`; assert the IR now has `severity=major scope=fix`. `status` and `fix-note` remain preserved even with `--reclassify`.
- `upsert-manual-test-failure` accepts `<scope>` argument and writes it to the block on insert. Test all four scope values; assert the written block matches.
- `upsert-manual-test-failure` clean-stdout-via-command-substitution on a closed IR. Set up an IR with `status: fixed` and a fix-note; capture: `IR_ID="$(printf '%s\n' "$obs" | review.sh upsert-manual-test-failure ... 2>/dev/null)"`. Assert `IR_ID` is exactly `IR-NNN` with no warning text or tab-separated fields. (`2>/dev/null` is intentional in this test — it's the worst-case shape the helper must still handle gracefully — but it's NOT the recommended caller pattern; production callers split stderr to a temp file per § 3.7.1 closed-IR caller pattern, which also lets them check the helper's exit code.)
- `upsert-manual-test-failure --reopen` reopens a `fixed` IR and overwrites details. Same setup; pass `--reopen`; assert status flipped to `open`, fix-note cleared, details updated.
- `upsert-manual-test-failure --new-finding` is family-aware and idempotent. Three sub-tests:
  - **First call against a `fixed` base IR:** set up a `fixed` IR with seed-id `manual-test:P:A.1`. Call with `--new-finding`. Assert original IR untouched AND a new IR exists with seed-id `manual-test:P:A.1:r1` and `status: open`. Stdout is the new IR-NNN.
  - **Second call (idempotent reuse):** call `--new-finding` again with a different observation. Assert NO new IR is created — the existing `:r1` is upserted (details replaced; severity/scope/status preserved per the open-IR rules). Stdout is the same IR-NNN as the first call. **No `:r2` exists.**
  - **Third call after closing `:r1`:** mark `:r1` as `fixed`. Call `--new-finding` again. Now no open regression exists in the family, so `:r2` is allocated. Base IR status is irrelevant. Assert new IR with seed-id `manual-test:P:A.1:r2`, `status: open`.
- `upsert-manual-test-failure --new-finding --force-new-regression` always allocates a new `:r<N>` against a non-empty family. Set up a base IR + open `:r1`; call `--new-finding --force-new-regression`; assert `:r2` is created and `:r1` is untouched. The flag is the explicit override path for parallel regressions.
- `upsert-manual-test-failure --new-finding --force-new-regression` REFUSES on an empty family. Start with no IR for the seed-id (no base, no regressions). Call with `--new-finding --force-new-regression`. Assert: helper exits non-zero, stderr matches the diagnostic `--force-new-regression requires an existing seed-id family; ...`, stdout is empty, and `inspector-review.md` is byte-identical pre/post-call.
- `/mi-manual-test-run --seed-only --as-new-findings` does NOT create a regression for an open base IR. Set up: feature with one failed scenario whose base IR exists in `inspector-review.md` with `status: open`. Run `/mi-manual-test-run --seed-only --as-new-findings`. Assert: the runner did NOT pass `--new-finding` to the helper for that scenario; the open base IR was updated in place per default-mode rules (details refreshed); NO `:r1` regression was created. This gates the runner's mandatory base-status inspection. Add a sibling test for the `--force-new-regressions` companion: open base + `--seed-only --as-new-findings --force-new-regressions` must also leave the base IR updated and NOT allocate `:r1` — `--force-new-regressions` only matters when the base is closed.
- `/mi-manual-test-run --seed-only --as-new-findings` DOES create a regression for a closed base IR. Same setup but the base IR is `status: fixed`. Run `--as-new-findings`. Assert: `:r1` is allocated with `status: open`; original base IR untouched; `Seeded: true` flips for the scenario.
- `/mi-manual-test-run --seed-only --as-new-findings` orphan-regression branch. Set up: feature with one failed scenario whose **base IR is missing** but `:r1` exists in `inspector-review.md` (the review session manually deleted the base block while leaving regressions). Run `--seed-only --as-new-findings`. Assert: the runner detected the orphan-regression case (base_row empty AND family non-empty) and called the helper with `--new-finding`; `:r1` was upserted (latest open regression reuse) — NO new base IR was inserted next to the orphan regressions. Add a sibling test where the only family member is a closed `:r1`: runner calls helper with `--new-finding`, helper allocates `:r2`, no base IR is created.
- `/mi-manual-test-run --seed-only --reopen-all` orphan-regression refusal. Same orphan setup (missing base + open `:r1`). Run `--reopen-all`. Assert: the runner refused this scenario per the orphan-regression diagnostic ("base IR missing but regression family exists; cannot reopen base"), `Seeded: false` for the scenario, no helper call was made for it, and `inspector-review.md` is byte-identical pre/post-call. Other scenarios in the run are still processed normally.
- `/mi-manual-test-run --seed-only` default interactive orphan-regression branch. Same orphan setup (missing base + open `:r1`). Run default `--seed-only` with no companion flags. Assert: the runner performs the family lookup before any helper call, detects `base_row` empty AND family non-empty, and prompts before calling the helper. Three prompt-choice sub-tests:
  - **Seed into existing regression family:** runner calls helper with `--new-finding`; helper reuses/upserts the open `:r1`; no base IR is created; `Seeded: true`.
  - **Skip:** runner makes no helper call; `Seeded: false`; `inspector-review.md` byte-identical pre/post-call.
  - **Restore missing base:** runner calls helper without override flags only after the inspector explicitly chooses restore-base; helper inserts the base IR; `Seeded: true`.
- `/mi-manual-test-run --seed-only --as-new-findings` family-empty (truly first-time). Set up: feature with a failed scenario that has NO IR yet — no base, no regressions. Run `--seed-only --as-new-findings`. Assert: the runner detected the family-empty case and called the helper in default mode (no override flags); a new base IR was inserted with `status: open`; `Seeded: true`. Confirms `--as-new-findings` does NOT pass `--new-finding` against an empty family.
- `Seeded:` idempotent crash recovery. Set up: an open seeded base IR exists in `inspector-review.md` for scenario `A.1` with seed-id `manual-test:P:A.1`, but `manual-test-results.md` shows `Seeded: false` for that scenario (simulating a crash between insert and flag-flip on a prior run). Run `/mi-manual-test-run --seed-only` with no companion flags. Assert: the runner called the helper with the same observation; the helper performed an open-match upsert (potentially byte-identical to the existing IR — zero file diff is acceptable); helper exited 0 with empty stderr; the runner classified this as a successful seed action and flipped `Seeded: true` for scenario `A.1`. `inspector-review.md` may or may not be byte-identical pre/post depending on observation edits, but `Seeded:` MUST flip regardless. Companion variant: identical observation between seed and retry → byte-identical inspector-review.md, `Seeded: true`.
- Stable `seed-family-id` across `/mi-manual-test-plan --force`. Generate a plan with `id=P1` and `seed-family-id=F1`; seed scenario `A.1`, producing `seed-id: manual-test:F1:A.1`. Mark the run complete. Re-run `/mi-manual-test-plan --force`; assert the new plan has a fresh `id=P2` but the same `seed-family-id=F1`, and the new results file copies `seed-family-id=F1`. Run a failed A.1 seed; assert `find-by-seed-id-family` sees the original family and the helper upserts/reuses according to family rules. Sibling test: `/mi-manual-test-plan --force --new-seed-family` creates `seed-family-id=F2`; the old `manual-test:F1:A.1` family is not matched by the new run.
- Existing-plan direct decline / `--from-resume` / `--force` handling is state/file consistent. Set up `manual-test-state=none`, `sub-flow=none`, and an existing `workflow-stream/<feature>/implementation/manual-test-plan.md`. Invoke `/mi-manual-test-plan` directly and answer `n` to the existing-plan prompt. Assert: `manual-test-state` remains `none`, `manual-test-failure-policy` remains unchanged, the plan file is byte-identical, and no history rotation occurs. Sibling test: invoke `/mi-manual-test-plan --from-resume` with the same existing plan and no `--force`; assert it does not rotate/regenerate, jumps to the "perform now?" prompt, and the plan file is byte-identical. Sibling tests: invoke `/mi-manual-test-plan --force` and `/mi-manual-test-plan --from-resume --force` from terminal states; assert both rotate plan/results and render a fresh plan without asking the regeneration prompt. Sibling test: no existing plan + direct `n` sets `manual-test-state=skipped`. Sibling test: existing plan + `--discard-existing` rotates plan/results into history and sets `manual-test-state=skipped`.
- Verdict commit is scenario-keyed and crash-idempotent. Simulate a crash after writing the `### A.1 — fail` verdict block but before frontmatter counts/cursor were advanced. Resume `/mi-manual-test-run`; assert it detects the existing A.1 verdict, recomputes counts, advances to A.2, and does NOT prompt for or append a second A.1 block.
- Duplicate-verdict-block self-healing. Set up: `manual-test-results.md` body contains TWO `### A.1 — fail` blocks, the later one having a different observation. Resume `/mi-manual-test-run` (or any normal verdict-commit operation that reads the body). Assert: the parser kept the latest A.1 block as canonical and dropped the earlier one (write back produces exactly one A.1 block whose observation matches the later input); a `^warning:` line was emitted to stderr naming `A.1` and the count of duplicates dropped (`1`); counts were computed from the canonical (latest) block, not from both. Sibling sub-test: three duplicates of A.1; assert latest kept, two earlier dropped, warning reports `2`. Refusal mode is NOT acceptable — the test asserts self-healing.
- `--finalize-skipped` upserts skip verdicts. Run `--finalize-skipped` twice after a paused run. Assert B.1/B.2/B.3 each have exactly one skip block, counts remain stable, and no duplicate skip verdicts are appended on the second invocation.
- Partial auto-seed summary. Set up one failed scenario whose base IR is closed. Run first-time auto-seed, answer `y`, then pick `skip` at the closed-IR prompt. Assert `manual-test-failure-policy=auto-seed`, the scenario's `Seeded: false`, no details mutation on the closed IR, and the Inspector Handler summary reports `seeded 0/1 failures` rather than implying all failures were seeded.
- Helper non-zero aborts Branch B without finalization. Set up a completed results file with one failed scenario and `sub-flow=manual-testing manual-test-state=running manual-test-failure-policy=none` (mid-seed-crash re-entry shape). Stub `review.sh upsert-manual-test-failure` to exit non-zero with stderr on that scenario. Run `/mi-manual-test-run --seed-only` and answer `y`. Assert: the diagnostic is surfaced; `manual-test-failure-policy` remains `none`; `sub-flow` remains `manual-testing`; `manual-test-state` remains `running`; the scenario's `Seeded:` remains `false`; no final "Manual test done" hand-off is printed. This gates the rule that helper refusals are hard errors, not per-scenario continue paths.
- `y --classify` / `--reclassify` propagates to secondary helper calls. Four sub-tests:
  - First-time `y --classify` + closed base + inspector chooses `reopen`: assert second helper call includes `--reopen --reclassify` and severity/scope are updated on the reopened IR.
  - First-time `y --classify` + closed base + inspector chooses `new-finding` where open `:r1` already exists: assert helper call includes `--new-finding --reclassify`, `:r1` is reused, and severity/scope update on `:r1`.
  - `--seed-only --reclassify` + orphan family + inspector chooses seed-into-family: assert helper call includes `--new-finding --reclassify` and the reused regression IR gets the new severity/scope.
  - **Open base + `--seed-only --reclassify`.** Set up an open base IR with `severity=major scope=fix` and a known details body. Run `/mi-manual-test-run --seed-only --reclassify`; the inspector (or test driver) picks `severity=blocker scope=re-plan` for the affected scenario. Assert: the (single) helper call for that scenario includes `--reclassify` (no `--reopen` and no `--new-finding`, since the base is open and the inspection routes to default-mode); the open base IR's `severity` and `scope` are updated to `blocker`/`re-plan`; `status` remains `open`; `fix-note` is unchanged; `details` are refreshed.
- `upsert-manual-test-failure --new-finding` numeric-suffix sorting. Set up a closed `:r2`, then a closed `:r10`. Call `--new-finding`; assert the next regression is `:r11`, NOT `:r3` (which would be the lexicographic-sort answer). Confirms numeric parsing of the regression suffix.
- `--reopen` and `--new-finding` are mutually exclusive. Pass both flags; assert helper refuses with diagnostic on stderr and exits non-zero. Assert no file mutation occurred (inspector-review.md byte-identical pre/post-call) and stdout is empty.
- `upsert-manual-test-failure --new-finding` against an OPEN base IR. Two sub-tests:
  - **No regressions exist:** set up an open base IR with seed-id `manual-test:P:A.1` and a known details body. Call `--new-finding`. Assert the base IR is byte-identical post-call (NOT upserted into; the `--new-finding` short-circuit must skip the open-update path) AND a new IR exists with seed-id `manual-test:P:A.1:r1` and `status: open`. Stdout is the new `:r1` IR-NNN.
  - **Open `:r1` already exists:** set up open base + open `:r1`. Call `--new-finding`. Assert the base IR is untouched, `:r1` is upserted (details replaced; severity/scope/status preserved per the open-update rules — same as the family-aware reuse path), and stdout is the existing `:r1` IR-NNN. **No `:r2` is allocated.** Confirms `--new-finding` enters the family-aware path uniformly, regardless of base status.
- `canonicalize` does not corrupt blocks containing `source` and `seed-id` fields.
- `find-by-seed-id` returns the `IR-NNN` of an upserted block; returns empty for a non-existent seed-id.
- `find-by-seed-id-family` TSV output format. Set up base + `:r1` + `:r2` IRs. Call `review.sh find-by-seed-id-family <feature> <base-seed-id>`. Assert stdout has exactly 3 rows, each tab-separated as `<IR-NNN>\t<seed-id>\t<status>`. Verify the seed-id column matches the canonical seed-id (base or `:r<N>`) for each row.
- `find-by-seed-id-family` empty output. Call against a non-existent base seed-id. Assert stdout is empty AND exit code is 0 (empty family is a recoverable state, not an error).
- `find-by-seed-id-family` numeric-suffix ordering. Set up base + `:r1` + `:r2` + `:r10`. Call the family helper. Assert row order is base → `:r1` → `:r2` → `:r10`. NOT base → `:r1` → `:r10` → `:r2` (lexicographic). This is the gating test for the helper's integer suffix parsing; review-context citation logic and `--new-finding` allocation both depend on it.
- `find-by-seed-id-family` literal matching. Set `base_seed_id=manual-test:P:A.1`. Assert the helper matches `manual-test:P:A.1`, `manual-test:P:A.1:r1`, and `manual-test:P:A.1:r12`. Assert it does NOT match `manual-test:P:A-1`, `manual-test:P:A11`, `manual-test:P:A.10`, `manual-test:P:A.1:rX`, `manual-test:P:A.1:r1-extra`, `manual-test:P:A.1:r0`, or `manual-test:P:A.1:r02`. This gates escaping / exact-string matching for scenario ids that contain regex metacharacters.
- `find-by-seed-id-family` status column reflects current state. Set up `fixed` base + open `:r1` + `fixed` `:r2` + open `:r3`. Call the family helper. Assert the status column reads `fixed`, `open`, `fixed`, `open` in numeric order. Confirms the helper reads live status from each block, not seed-time status.
- Review-context citation priority. For each of the family states below, run the review-context citation-resolution path (per § 3.2.1 algorithm) and assert the cited IR matches the priority rule (newest open regression > open base > newest closed family member > none):
  - **Open base, closed `:r1`, open `:r2`:** cite `:r2` (newest open regression beats open base).
  - **Closed base, open `:r1`, no `:r2`:** cite `:r1` (newest open regression).
  - **Open base, no regressions:** cite the base IR.
  - **Closed base, no regressions:** cite the closed base IR, with the emitted review-context line using the closed form (`cited in IR-NNN (status: <fixed|wontfix>; no open seeded finding remains)`). Item 3 of the priority rule fires here — the base is the highest-suffix-overall family member (suffix 0), and items 1 and 2 don't apply.
  - **Closed base, closed `:r1`, closed `:r2`:** cite `:r2` (newest overall — preserves traceability when nothing is open) and include its closed status in the emitted review-context line.
  - **No family at all (auto-seed declined or all family deleted):** emit the "no IR" form per § 3.2.1; do not error.
- Review-context closed-citation status text. Set up a closed base and closed latest regression. Assert the generated line uses the closed form, e.g. `cited in IR-123 (status: fixed; no open seeded finding remains)`, not just `cited in IR-123`.
- `list-open` output includes blocks regardless of whether they carry `source`/`seed-id`.
- First-time auto-seed loop runs family inspection. Set up: a previous cycle left an orphan family in `inspector-review.md` (deleted base + extant open `:r1`) for seed-id `manual-test:F1:A.1`. Run a fresh manual-test cycle with one failed scenario for A.1 via `/mi-manual-test-plan --force`; assert the new plan has a fresh plan `id` but preserves `seed-family-id=F1`. Answer `y` to the auto-seed prompt; the test driver simulates the inspector choosing "seed into existing family" at the orphan prompt. Assert: the helper was called with `--new-finding`; the existing `:r1` was upserted (open-update — details replaced, severity/scope/status preserved unless `--reclassify` was used); NO new base IR was inserted alongside the orphan regression. Sibling sub-test: same setup but the test driver picks "skip" at the orphan prompt; assert no helper call, `Seeded: false`, `inspector-review.md` byte-identical pre/post-call.
- `/mi-manual-test-run --seed-only --reopen-all` is a no-op against an open base IR. Set up: feature with one failed scenario whose base IR exists with `status: open`. Run `--seed-only --reopen-all`. Assert: the open base IR was updated in place per default-mode rules (details refreshed; status still `open`; fix-note unchanged); NO new IR was created; `Seeded: true`. (Implementations may either pass `--reopen` to the helper — silent no-op against open IRs — or skip the flag; either is acceptable.)
- `/mi-manual-test-run --seed-only --reopen-all` family-empty truly-first-time. Set up: failed scenario with no IR yet (no base, no regressions). Run `--seed-only --reopen-all`. Assert: the runner detected the family-empty case and called the helper in default mode (no `--reopen` — the flag would be a no-op against no match); a new base IR was inserted with `status: open`; `Seeded: true`. Confirms `--reopen-all` does NOT pass `--reopen` against an empty family.
- `/mi-manual-test-run --seed-only --reopen-all` reopens a closed base IR. Set up: closed base IR (`status: fixed`, with a fix-note). Run `--seed-only --reopen-all`. Assert: helper was called with `--reopen`; status flipped to `open`; fix-note cleared; details refreshed; `Seeded: true`.
- Branch A and Branch B pre-normalization refuses on corrupt results-file frontmatter. Six sub-tests covering the corruption shapes:
  - **YAML parse error** (e.g., unbalanced quotes in `state:`): set up `manual-test-results.md` with broken YAML; run `/mi-manual-test-run` (Branch A) and separately `/mi-manual-test-run --seed-only` (Branch B). For each, assert: skill refuses with diagnostic naming the parse error; `progress.md` is byte-identical pre/post-call; results file is byte-identical (NOT re-rendered from template).
  - **Missing `state` key**: results file has frontmatter but no `state:` field. Same assertions as above.
  - **`state: bogus`** (value not in the `[in-progress, complete]` enum): same assertions, with the diagnostic naming the offending value.
  - **Missing `current-scenario` key**: same assertions; diagnostic names `current-scenario`.
  - **Unknown current scenario**: `state: in-progress`, `current-scenario: Z.9`, but Z.9 does not exist in the plan. Same assertions; diagnostic names the invalid scenario id.
  - **Complete-state mismatch**: `state: complete` with non-null `current-scenario`, or `state: complete` with `finished-at: null`. Same assertions; Branch B must emit the corruption diagnostic, not a generic "results not complete" refusal.
  In all cases, the diagnostic must name the offending field/error so the inspector can fix the file by hand without guessing. The guard must fire BEFORE any progress.md mutation in either branch.
- Branch A and Branch B refuse stale results that do not match the active plan. Three sub-tests, each run against Branch A and Branch B: (1) `results.feature` differs from the active feature; (2) `results.plan-id` differs from current `manual-test-plan.md` frontmatter `id`; (3) `results.seed-family-id` differs from current plan `seed-family-id`. Assert: diagnostic names the mismatched field and both expected/actual values; `progress.md` is byte-identical; results file is not re-rendered; no auto-seed helper call occurs.
- Branch C (`--finalize-skipped`) refuses stale results that do not match the active plan. Three sub-tests covering the same three mismatch shapes as the Branch A/B test above: (1) `results.feature` differs; (2) `results.plan-id` differs; (3) `results.seed-family-id` differs. Set up so all the run-state preconditions (`sub-flow=manual-testing`, `manual-test-state=running`, results `state: in-progress`, `current-scenario != null`) WOULD otherwise pass. Run `/mi-manual-test-run --finalize-skipped`. Assert: refusal with diagnostic naming the mismatched field; `progress.md` byte-identical pre/post-call; `manual-test-results.md` byte-identical pre/post-call (NO bulk-skip verdicts written, NO frontmatter mutation); the auto-seed step in the converged step 4 does not fire. Sibling sub-test: corrupt-frontmatter shapes (missing `state` key, unparseable YAML) are also refused under Branch C with no mutation.
- Review-context citation cache cleared on family deletion. Set up: a previous review-context generation wrote `Cited as IR-NNN: IR-123` to scenario A.1's results block. Then the review session manually deleted IR-123 and every other family member (no base, no regressions remain in `inspector-review.md`). Re-run review-context generation. Assert: the emitted review-context line uses the "no IR" form (`(auto-seed declined or all family IRs deleted — no IR)`) AND the results-file cache line is exactly `- **Cited as IR-NNN:**` with no value after the colon, NOT the stale `IR-123` and NOT the literal string `null`.
- `--finalize-skipped` finalizes a paused run as `complete` with bulk-skipped remainder. Set up: paused mid-run with one passed scenario (A.1), one failed scenario (A.2), and `current-scenario=B.1` with B.1, B.2, B.3 unstarted. Run `/mi-manual-test-run --finalize-skipped`. Assert:
  - results body has verdicts for A.1 (pass), A.2 (fail), and now B.1, B.2, B.3 each with `skip` verdict, reason `bulk-skipped`, and `Seeded: false`;
  - results frontmatter `state: complete`, `finished-at` set to a non-null timestamp, `current-scenario: null`;
  - counts: `passed=1, failed=1, skipped=3, total=5`;
  - the auto-seed prompt fires for the one failure (A.2) — bulk-skipped scenarios do NOT count as failures and do NOT enter the auto-seed loop;
  - if the inspector answers `y`, A.2's IR is seeded normally (with the family inspection); `Seeded: true` for A.2 only; `Seeded: false` for B.1/B.2/B.3;
  - if the inspector answers `n`, `policy=manual` and finalization still lands;
  - progress.md is finalized to `(sub-flow=none, manual-test-state=complete)`, NOT `manual-test-state=skipped` (the schema reserves `skipped` for the declined-at-stage-5 case per § 1.3).
- `--finalize-skipped` precondition refusals. Three sub-tests:
  - `sub-flow=none`: refuse with the "Manual test isn't running" diagnostic; assert no mutation.
  - `manual-test-state=complete`: refuse; assert no mutation.
  - `current-scenario=null` (run hasn't reached scenario 1 yet): refuse with "Manual test isn't paused — `current-scenario` is null"; assert no mutation.
- `--finalize-skipped` refuses when a prior scenario lacks a valid verdict. Set up `current-scenario=B.1` with scenarios A.1, A.2 ordered before it. Sub-test 1: delete A.2's verdict block. Sub-test 2: keep A.2's heading but remove its `- **Verdict:**` bullet. Run `/mi-manual-test-run --finalize-skipped`. Assert: diagnostic names A.2 and the missing/invalid verdict reason; results file and progress.md are byte-identical; no B.* skip verdicts are written.
- `/mi-manual-test-run` mode-flag dispatch is mutually exclusive. Pass `--seed-only --finalize-skipped` together. Assert: refusal with diagnostic naming both flags; `progress.md` and `manual-test-results.md` byte-identical pre/post-call.
- Branch C (`--finalize-skipped`) does not run env-up or render scenarios. Set up: paused mid-run, `current-scenario=B.1`, env-up has not yet been confirmed for the resumed run. Run `/mi-manual-test-run --finalize-skipped`. Assert: no env-up prompt is rendered; no scenario block (B.1 or otherwise) is rendered; B.1/B.2/... receive `skip` verdicts with `Observation: bulk-skipped`; the run finalizes via step 4. Sibling assertion: scenarios at or after `current-scenario` that already have a real verdict (defensive corner — should not occur in normal flow but the test asserts the runner does not overwrite them) are left untouched.
- `/mi-manual-test-plan` `--force` flag-dispatch reaches the override branch. Set up `manual-test-state=complete` and an existing plan file. Run `/mi-manual-test-plan --force` with a FRESH change-summary. Assert: skill does NOT refuse on the precondition; step 3.5 resets `manual-test-state=none manual-test-failure-policy=none` AFTER read-only gates pass; step 4 rotates the existing plan and results into history; a fresh plan is rendered; `seed-family-id` is preserved (unless `--new-seed-family` was also passed). Sibling: `--force` from `manual-test-state=skipped` reaches the same override branch with the same outcomes. Sibling: bare `/mi-manual-test-plan` (no `--force`) from `manual-test-state=complete` IS refused per the normal precondition.
- `--force` does NOT mutate `progress.md` when a read-only gate refuses. Three sub-tests, each set up with `manual-test-state=complete` (so the precondition table requires `--force` to enter):
  - **Stale change-summary under `--force`:** stub `commits.sh change-summary-fresh` to return 1; run `/mi-manual-test-plan --force`. Assert: skill refuses with the stale-change-summary diagnostic; `manual-test-state` is still `complete` (NOT reset to `none`); `manual-test-failure-policy` is unchanged; no plan rotation; no new plan rendered. The reset that would normally happen in step 3.5 was correctly deferred until after the gate passed.
  - **Missing change-summary under `--force`:** same shape with `commits.sh change-summary-fresh` returning 2.
  - **Invalid existing-plan frontmatter under `--force`:** existing plan file has unparseable YAML; `--force` should still refuse on the read of the existing plan with `progress.md` byte-identical pre/post-call. (Confirms step 1's read-only check fires before step 3.5's mutation.)
- `/mi-manual-test-plan` change-summary freshness gate (non-`--force` shape). Three sub-tests:
  - `commits.sh change-summary-fresh` returns 0 (fresh): the skill reads the summary and proceeds normally.
  - `commits.sh change-summary-fresh` returns 1 (stale): the skill refuses with diagnostic naming `/mi-draw-diagrams` (or `/mi-generate-implementation-diagrams`); `manual-test-state` is unchanged; no plan is rendered; no rotation occurs.
  - `commits.sh change-summary-fresh` returns 2 (missing): same refusal shape as stale, with the diagnostic naming the missing file.
- `/mi-manual-test-plan` renders self-contained `## 2. What to run` commands. Set up an active feature whose `worktree-path` is a per-feature worktree distinct from the main checkout. Generate a plan; assert every command line in the rendered `## 2. What to run` section is in one of the two acceptable shapes per § 4.1: either (a) starts with `cd "<absolute-worktree-path>"` with the path inlined and shell-quoted, or (b) the section opens with a single `export RUN_ROOT="<absolute-worktree-path>"` line and subsequent commands use `cd "$RUN_ROOT"` (the export line counts as part of the section). Bare `cd "$RUN_ROOT"` lines without a preceding `export` in the same section MUST NOT appear. Sibling assertion: the rendered plan frontmatter contains `generated-against-run-root: <absolute-worktree-path>`. Sibling assertion: codebase search performed during plan generation also runs from the worktree path (instrument `change-summary.md` for files that exist only on the worktree branch and assert they're picked up).
- `/mi-manual-test-run` worktree-drift guard. Set up: a generated plan whose frontmatter `generated-against-run-root` is `/old/path` (recorded at plan time), but the active feature's `progress.sh get worktree-path` now returns `/new/path` (worktree was moved). Run `/mi-manual-test-run`. Assert: refusal with diagnostic naming both `/old/path` and `/new/path` and recommending `/mi-manual-test-plan --force`; `progress.md` byte-identical pre/post-call; `manual-test-results.md` not created or modified. Sibling: when the two paths match, the env-up phase proceeds normally.
- Inspector Handler does not auto-seed or rewrite from manual-test results. Set up: a completed manual-test run with `manual-test-failure-policy=auto-seed`, two failed scenarios both successfully auto-seeded as canonical IR blocks in `inspector-review.md`, and no free-form review text. Capture sha256 of `inspector-review.md`. Type `/mi-continue` (the dispatcher routes to the Inspector Handler at stage 5 with `sub-flow=none`). Assert: the handler's entry log contains the expected Manual-test summary line (`Manual test: 2/4 passed, 2 failed (failure-policy: auto-seed; seeded 2/2 failures)`); the post-handler sha256 of `inspector-review.md` matches the pre-handler sha256 byte-for-byte. Sibling sub-test with `policy=manual` and `policy=none`: same no-manual-test-mutation assertion on an already-canonical review file. Separate sibling: add inspector-authored free-form review text before `/mi-continue`; assert existing canonicalization may mutate `inspector-review.md`, but no new manual-test seeded IR is created and no existing `source: manual-test` block is changed because of `manual-test-results.md`.

These tests gate the auto-seed work in `mi-manual-test-run` — without them, the seed-id idempotency design is unverified.

### 3.8 `scripts/doctor.sh` / `commands/mi-doctor.md`

Add the following checks in `scripts/doctor.sh`, not only in `commands/mi-doctor.md`. `commands/mi-doctor.md` already runs `scripts/doctor.sh --format=json` and renders the returned check objects; it should not duplicate detection logic. Use the existing `record <name> <kind> <required> <present> <version> <install_hints_json>` JSON shape from `scripts/doctor.sh` for each check, with `kind=env` and `required=true` for missing repo artifacts.

- **Templates exist.** `templates/manual-test-plan.md.tmpl` and `templates/manual-test-results.md.tmpl`. Add a helper such as `check_file_exists manual-test-plan-template templates/manual-test-plan.md.tmpl true` that records `present=false` with a hint pointing at the manual-testing implementation step.
- **Schemas exist.** `schemas/manual-test-plan.schema.yaml` and `schemas/manual-test-results.schema.yaml`. Without these, the `mi-manual-test-plan` / `mi-manual-test-run` skills will fail validation on first invocation.
- **`progress.schema.yaml` includes the new sub-flow value AND the new active-block fields.** Grep `schemas/progress.schema.yaml` for `manual-testing` (in the sub-flow enum) AND for `manual-test-state:` and `manual-test-failure-policy:` (as field declarations). Record each separately so the operator knows which piece is missing if the schema was partially updated.
- **`review.sh` accepts the new subcommands.** First, implement `--help` / usage handling for `review.sh upsert-manual-test-failure`, `review.sh find-by-seed-id`, and `review.sh find-by-seed-id-family` so doctor can probe them without mutating files. Then have `scripts/doctor.sh` run those help probes and assert exit 0. These helpers are runtime-load-bearing for `mi-manual-test-run` and `mi-review`; the doctor should surface a clear "review.sh too old" check instead of a cryptic runtime helper-call failure.
- **`FIELD_RE` extension landed.** Grep `scripts/review.sh` for the extended regex line containing `source` and `seed-id` per § 3.7.3. Without the extension, `canonicalize` corrupts auto-seeded blocks. This is the highest-risk silent-failure the doctor can catch.

`commands/mi-doctor.md` only needs a prose/schema update if the rendered grouping should label these as "manual-test feature checks"; otherwise the existing JSON report rendering can display them like the other env checks.

---

## 4. New templates

### 4.1 `templates/manual-test-plan.md.tmpl`

Mirrors `tmp/manual-test-plan.md`'s top-level structure. Frontmatter:

```yaml
---
id: {{PLAN_REVISION_ID}}
seed-family-id: {{SEED_FAMILY_ID}}
feature: {{FEATURE}}
generated-from-base-commit: {{BASE_COMMIT}}
generated-from-head: {{HEAD_AT_GENERATION}}
generated-against-run-root: {{RUN_ROOT}}
requirements-id: {{REQUIREMENTS_ID}}
---
```

`generated-against-run-root` records the absolute worktree path that was inlined into the `## 2. What to run` commands. The runner (§ 2.2) compares this to the live `progress.sh get worktree-path` at run time; a mismatch refuses with a worktree-drift diagnostic so the inspector can `--force` regenerate against the new path.

Body skeleton (placeholders the generator fills):

```markdown
# Manual test plan — {{FEATURE}}

## 1. Prerequisites

### 1.1. Services to run via docker-compose
{{SERVICES_BLOCK}}

### 1.2. Required env vars (...)
{{ENV_VARS_BLOCK}}

### 1.3. Install + bootstrap
{{INSTALL_BLOCK}}

### 1.4. Seed data
{{SEED_BLOCK}}

## 2. What to run

{{TERMINAL_COMMANDS}}

## 3. Test scenarios

{{SCENARIOS}}
```

The plan generator MUST emit every command in `## 2. What to run` in a shape that works when copy-pasted into the inspector's terminal — i.e., `RUN_ROOT` cannot be a runner-only variable. Two acceptable shapes (pick one per section, do not mix):

- **Absolute-path inline (preferred):** the resolved absolute worktree path is interpolated into every command, shell-quoted. Example: `cd "/abs/path/to/.worktree" && pnpm dev`.
- **Preamble export:** the section begins with `export RUN_ROOT="/abs/path/to/.worktree"` on its own line; subsequent commands use `cd "$RUN_ROOT" && <cmd>`. The export line is part of what the inspector copy-pastes.

Bare `cd "$RUN_ROOT" && ...` without a preceding `export RUN_ROOT="..."` in the same `## 2. What to run` section is invalid — the variable would be undefined in the inspector's shell. If a specific command must run from the main checkout (e.g., a docker-compose stack pinned there), the generator emits an absolute `cd "/abs/path/to/main/checkout"  # reason: <why>` for that one command. Generic "run from repo root" without an explicit `cd` is not allowed — every command line states its working directory.

Scenarios section follows the `Scenario A — <title>` / `### A.1. <title>` convention from the reference (per § 7.3).

Need a corresponding schema: `schemas/manual-test-plan.schema.yaml` validating frontmatter shape only (body is free-form markdown, no enforced section order beyond the three top-level headings). Required frontmatter fields include `id` (per-render plan revision id) and `seed-family-id` (stable across forced re-renders unless `--new-seed-family` is explicitly requested).

### 4.2 `templates/manual-test-results.md.tmpl`

```yaml
---
id: {{UUID}}
feature: {{FEATURE}}
plan-id: {{PLAN_ID}}
seed-family-id: {{SEED_FAMILY_ID}}
state: in-progress
current-scenario: null
total: {{TOTAL}}
passed: 0
failed: 0
skipped: 0
started-at: {{TIMESTAMP}}
finished-at: null
---
```

```markdown
# Manual test results — {{FEATURE}}

## Per-scenario verdicts

(populated by `/mi-manual-test-run` as scenarios are evaluated)
```

Each verdict block is upserted by scenario id as:

```markdown
### {{SCENARIO_ID}} — {{VERDICT}}

- **Verdict:** pass | fail | skip
- **Observation:** {{INSPECTOR_REPLY}}
- **Recorded at:** {{TIMESTAMP}}
- **Seeded:** false
- **Cited as IR-NNN:** {{IR_ID_IF_PRESENT_ELSE_BLANK}}
```

`Seeded:` is only meaningful for `fail` verdicts; flipped to `true` after a *successful seed action* — i.e., the helper exited 0 with no `^warning:` on stderr (insert, open-match upsert including idempotent zero-diff reuse, `--reopen`, regression allocate, or regression upsert/reuse). The closed-default warning path (helper returned IR-NNN with `^warning:` on stderr) leaves `Seeded: false`; if the inspector subsequently picks `reopen`/`new-finding`, the helper's second call's success flips the flag, and if they pick `skip` the flag stays `false`. **Display/cache only — NOT a correctness mechanism.** The seed-id grep-and-replace in § 2.2 is what makes seeding idempotent. `--seed-only` mode ignores this field entirely.

Schema: `schemas/manual-test-results.schema.yaml`, required frontmatter fields (`id`, `feature`, `plan-id`, `seed-family-id`, `state`, `current-scenario`, counts, `started-at`, `finished-at`), `state` enum `[in-progress, complete]`, and `seed-family-id` copied from the plan. The static schema validates frontmatter shape only; the runner performs active-plan ownership validation by comparing `feature`, `plan-id`, and `seed-family-id` to the active feature and current `manual-test-plan.md` frontmatter (§ 2.2). Per-scenario verdict block fields are loosely structured (markdown bullets); the runner parses verdict blocks per § 4.2.1.

### 4.2.1 Verdict-block parsing contract

The verdict-block format below is the contract both writers and readers agree on. Pinning block boundaries, field ordering, missing-field defaults, and key case-sensitivity prevents the verdict-commit unit and the auto-seed loop from drifting in their tolerance for malformed input.

**Block boundary.** A verdict block starts at the first line matching `^### <SCENARIO_ID> — ` (literal three-hash heading, scenario id, em-dash with surrounding spaces). It ends at the first of: the next `^### ` heading (any scenario id), the next `^## ` heading (next top-level section), or end-of-file. Anything inside that range is part of the block.

**Bullet keys are case-sensitive and exact-match.** Recognized bullets are exactly:

```
- **Verdict:** <pass|fail|skip>
- **Observation:** <body, possibly multi-line block scalar — see "Multi-line Observation: storage" below>
- **Recorded at:** <ISO-8601 timestamp>
- **Seeded:** <true|false>
- **Cited as IR-NNN:** <IR-NNN, possibly empty>
```

The runner emits all five bullets in the order shown, every time, on every commit. Missing-field defaults on read (defensive — should not occur in runner-written blocks but may occur after hand-edits or on legacy files):

- `Verdict:` missing → refuse with `^warning:` on stderr; do NOT count this scenario; do NOT advance cursor past it. (A verdict block with no verdict is unrecoverable.)
- `Observation:` missing → empty string (treat as "no observation recorded"). Acceptable for `pass` and `skip` verdicts; auto-seed loop refuses to seed a `fail` scenario whose observation is empty (with a stderr warning), continuing to the next failure.
- `Recorded at:` missing → empty string. Display only; not load-bearing.
- `Seeded:` missing → `false`. This default is deliberately permissive so hand-edits and legacy files don't get spuriously skipped on `--seed-only` (which always greps `inspector-review.md` for the seed-id anyway, so the cache state is double-checked).
- `Cited as IR-NNN:` missing → empty (treat as "no current citation"). The blank-after-colon shape is the canonical empty form; missing-field is treated identically.

**Multi-line `Observation:` storage.** When the inspector's reply is multi-line, store as a YAML-style block scalar:

```markdown
- **Observation:** |
    Line 1.
    Line 2.

    Blank line preserved.
```

Indent body four spaces. The block scalar runs until the next bullet (`^- ` outdent), the next heading (`^### ` or `^## `), or end-of-block (per the boundary rule). Blank lines inside the block scalar are preserved. Single-line observations omit the `|` introducer and inline directly: `- **Observation:** got 500 from /api/foo`. The runner inverse-extracts by stripping the leading four-space indent and rejoining; this is the input piped to `review.sh upsert-manual-test-failure` via stdin in § 2.2 step 4.

**Bullet ordering on read.** The parser tolerates any order of the five recognized bullets on read (the runner always writes them in canonical order, but hand-edits may reorder). Unknown bullets within a verdict block are preserved in place on rewrite — they're foreign content and the runner has no opinion about them. (Rare; would only happen if the inspector hand-annotated a block.)

**Why pin this contract.** Two consumers read these blocks: the verdict-commit unit (re-parses and rewrites the block on every scenario advance) and the auto-seed loop (extracts observation text and `Seeded:` value to drive seeding). Without an explicit contract, those two consumers can drift in their tolerance for malformed input — one might silently fold a missing `Verdict:` field into `pass`, the other might refuse on the same input. Pinning the contract here means both implementations agree on what's well-formed and what's not.

---

## 5. Per-scenario output format (what the inspector asked for)

Lifted directly from the example provided. The skill's prompt template:

```
⏺ {{SCENARIO_ID}} — {{ONE_LINE_TITLE}} ({{LINKED_IR_IDS_OR_BLANK}})

What it tests: {{WHAT_IT_TESTS_PARAGRAPH}}

{{TRICK_BLOCK_IF_APPLICABLE}}

Action:
{{NUMBERED_STEPS}}

Expected:
{{BULLETED_EXPECTATIONS}}
```

Where `{{TRICK_BLOCK_IF_APPLICABLE}}` is rendered as a "Trick to trigger from the UI:" paragraph only when the plan's scenario calls one out (the reference's D.7 has one; D.1 doesn't).

The plan generator (`/mi-manual-test-plan`) is responsible for filling the corresponding fields when it writes scenarios into `manual-test-plan.md`. The runner just reads them back.

---

## 6. Context discipline (the bloat answer, made concrete)

Sources of potential bloat in main:

| Source                                         | Mitigation                                                                                                                                  |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Re-rendering the full scenario block per loop  | Render once per scenario (necessary — the inspector needs to see it). Don't re-include past scenarios in subsequent prompts.                 |
| Inspector's verbose observations                | Write to `manual-test-results.md`, echo to chat as `<ID> ❌ failed (observation written to results file)`. Don't keep multi-line observations in chat. |
| Auto-seed step writing many findings           | One family-inspection dispatch per failed scenario (§ 2.2, § 3.7.1), with helper calls only on seed/reopen/regression choices. Echo seeded/failed counts plus any IR-NNNs actually seeded; do not imply skipped or warning-only failures were seeded. |
| Stage-6 review session reading manual-test     | It reads `review-context.md` (one paragraph). Detail files are on-demand via the sub-agent's optional reads.                                |
| Carrying everything into the next workflow     | Hard terminator stays at `/mi-complete-workflow` (stage 8). Suggest `/clear` there, before queue-advance — same as today.                   |

No new `/clear` checkpoint is suggested between manual-test and findings-authoring. Auto-seeded manual-test failures are written as canonical `### IR-NNN` blocks immediately by `review.sh upsert-manual-test-failure` (§ 3.7.1) — the stage-5 Inspector Handler's `canonicalize` pass only handles ordinary inspector-authored free-form review text, not auto-seeded blocks. Even so, the auto-seed step needs the failed-scenario observations in main to call the helper with the right arguments; forcing a clear before that would just mean re-reading the results file.

---

## 7. Decisions captured

### 7.1 Plan generator inputs — answer: blueprint + change-summary + codebase scan

Per the inspector's reply, codebase search is added on top of the blueprint/change-summary inputs to ground prerequisites and scenarios in real symbols. The generator greps the changed paths from `change-summary.md` for: env-var refs, docker-compose service names, GraphQL/REST operations, error-code constants, UI route paths.

### 7.2 Auto-seed failed scenarios — answer: prompt the inspector per cycle

Default behavior is to ask `y/n` after the run completes (only if there are failures). The choice is recorded in `manual-test-failure-policy`. Some cycles legitimately want manual-test failures *not* to gate review (flaky external services, exploratory smoke tests).

### 7.3 Scenario ID convention — answer: `<LETTER>.<NUMBER>` is the standard

`A.1, A.2, B.1, …` matches the reference. Codified in the plan template's "Test scenarios" section preamble.

### 7.4 Resume on `/mi-continue` — answer: yes, with progress.md updates

Implemented via the new `manual-testing` sub-flow + Manual-Test-Resume Handler. Progress.md updates are minimal (sub-flow toggle + coarse `manual-test-state` marker); per-scenario state lives in the results file frontmatter so it doesn't churn `progress.md` 20 times per run.

### 7.5 Artifact location — answer: feature-scoped under `workflow-stream/<feature>/implementation/`

Manual-test plan/results are added to the per-feature `implementation/` folder lifecycle. Reasons in § 1.4. Both archive (`mi-complete-workflow.md`) and abort (`mi-abort-workflow.md`) enumerate fixed file lists, so manual-test files still need explicit list-extension diffs in § 3.3 and § 3.4. The location decision avoids parallel plumbing (different folder) but does not eliminate the list extensions themselves.

The cycle-scoped alternative (under `quest/<active-slug>/`) was wrong on two counts: (a) cycles can have multiple features, so artifacts would collide; (b) it would require *separate* archive/abort plumbing for the cycle folder, on top of the list extensions in `implementation/`-targeting commands.

### 7.6 Run-root for manual-test execution — answer: the active feature's worktree

Manual-test commands and codebase scans run from the active feature's worktree (`progress.sh get worktree-path`), not the main checkout. The active feature's implementation lives in that worktree, so testing against it avoids the trap of testing stale code from main while a feature's changes sit uncommitted (or committed only on the worktree branch). The plan generator (§ 2.1 step 3) resolves `RUN_ROOT` from this field at render time. Generated commands in `## 2. What to run` are written so they work when copy-pasted into the inspector's terminal — either with the absolute worktree path inlined (`cd "/abs/path" && <cmd>`, preferred) or with an `export RUN_ROOT="/abs/path"` preamble at the top of the section followed by `cd "$RUN_ROOT" && <cmd>` commands (§ 4.1). Bare `cd "$RUN_ROOT" && ...` without the export preamble is invalid because `$RUN_ROOT` is not a runner-shared variable. When a specific service legitimately must run from the main checkout, the plan generator emits an absolute `cd "/abs/main/checkout"  # reason: <why>` for that command. The default — every other command — is the worktree.

---

## 8. Implementation order (suggested)

1. **Schema + script changes first** (smallest blast radius, easy to verify):
   - `schemas/progress.schema.yaml`: add `manual-testing` to sub-flow enum, add `manual-test-state` and `manual-test-failure-policy` fields. **No** active-block idempotency-marker boolean — seed-id-based idempotency per § 2.2.
   - `scripts/progress.sh`: extend BOTH the activate block AND the reset block.
   - `scripts/review.sh` (REQUIRED, gating). The full checklist:
     - **Parser:** extend `FIELD_RE` per § 3.7.3 ordering (`severity|scope|status|source|seed-id|details|fix-note`).
     - **Parser:** numeric regression-suffix parsing — given a seed-id, identify whether it's a base (no `:r<N>`) or a regression (`<base>:r<N>` where `<N>` is parsed as an integer, NOT as a string). Required by `find-by-seed-id-family` ordering and `--new-finding` family-reuse logic.
     - **`upsert-manual-test-failure`** (§ 3.7.1): full helper including:
       - Stdin observation reading (mirrors `review.sh add`).
       - Open-IR upsert path: preserve severity/scope/status/fix-note; replace details/source/seed-id.
       - Closed-IR default path: warning on stderr, clean `<IR-NNN>\n` on stdout, no details mutation.
       - `--reopen`: flip status to open, clear fix-note, update details.
       - `--new-finding`: family-aware path entered before the exact-seed-id open/closed dispatch (the step 2 short-circuit). Reuse the latest open regression IR (highest numeric `<N>` with `status: open`); if no open regression exists and the family is non-empty, allocate the next regression suffix `:r<N+1>` (numerically); if the family is empty, fall through to the default base-insert path. Base IR's status is irrelevant — never touched, even when open.
       - `--new-finding --force-new-regression`: same family-aware path, but when the family is non-empty, always allocate a new `:r<N>` regardless of open-regression presence; **refuses non-zero with stderr diagnostic and no mutation when the family is empty**. The runner-level `--force-new-regressions` flag gates on closed-base status before passing this combination, so the refusal is a defensive backstop.
       - `--reclassify`: replace severity/scope on update (composes with `--reopen` and `--new-finding` independently).
       - Mutual-exclusion check: refuse if both `--reopen` and `--new-finding` are passed.
     - **`find-by-seed-id`** (§ 3.7.2): exact-match lookup, clean stdout.
     - **`find-by-seed-id-family`** (§ 3.7.2): family-match lookup with literal base seed-id matching and **numeric** suffix ordering (NOT lexicographic — `:r10` sorts AFTER `:r2`, not before). Output is TSV `<IR-NNN>\t<seed-id>\t<status>` with rows ordered by parsed-integer suffix ascending (base, then regression generations 1, 2, …, 10, 11). Reject lookalike suffixes such as `:r0`, `:r02`, `:rX`, or `:r1-extra`.
     - **`review.sh add`** (§ 3.7.4): accept `source` and `seed-id` as known fields when emitting canonical blocks.
     - **Tests:** ship the full set in § 3.7.5 — including the family-reuse idempotency tests, numeric-suffix sort test, mutual-exclusion test, and clean-stdout-via-command-substitution test.

     **Gating note:** no auto-seed work in `mi-manual-test-run` may merge before these tests pass. Specifically: without `FIELD_RE` extended, canonicalize silently corrupts seeded blocks; without `upsert-manual-test-failure` family-reuse, `--new-finding` re-runs duplicate IRs; without `find-by-seed-id-family`, review-context misroutes regressions to closed base IRs; without numeric suffix parsing, sort order breaks at the 10th regression generation.
   - `templates/inspector-review.md.tmpl`: extend the "Structured blocks (precise)" example to include the optional `- source:` and `- seed-id:` fields.
   - `schemas/review-file.schema.yaml`: if it enforces field set, add the two optional fields.
   - `scripts/blueprints.sh`: add path resolvers + rotate function (§ 3.6). **Not** `scripts/quest.sh` — manual-test artifacts are feature-scoped.
   - `schemas/manual-test-plan.schema.yaml`, `schemas/manual-test-results.schema.yaml`: new files. Both schemas include `seed-family-id`. The runner's frontmatter validation (not necessarily the static schema alone, because it needs the plan's scenario list) enforces state-specific invariants: `state=complete` requires `current-scenario=null` and non-null `finished-at`; `state=in-progress` requires `current-scenario` null or a valid scenario id.
   - `templates/manual-test-plan.md.tmpl`, `templates/manual-test-results.md.tmpl`: new files. Results template's per-scenario verdict block carries `Seeded:` as display/cache only (§ 4.2).

2. **New skills:**
   - `commands/mi-manual-test-plan.md`. The implementer must additionally build:
     - **Flag-dispatch preconditions** (§ 2.1 preconditions table): parse `--force`, `--from-resume`, `--new-seed-family`, `--discard-existing` BEFORE evaluating `manual-test-state`. Normal invocation requires `manual-test-state=none`; `--force` accepts `none|complete|skipped`; `--discard-existing` accepts `none`.
     - **`--force` state-reset ordering** (§ 2.1 step 3.5): the `progress.sh set manual-test-state=none manual-test-failure-policy=none` reset must run AFTER all read-only gates (existing-plan probe, RUN_ROOT resolution, change-summary freshness). A refusal from any earlier gate must leave `progress.md` byte-identical even when `--force` was passed. Tests in § 3.7.5 gate this with stale/missing change-summary cases under `--force`.
     - **`--from-resume`** (§ 2.1, § 3.1.1): suppress only the duplicate no-existing-plan generation prompt when auto-fired by `mi-continue`; if a plan already exists and `--force` was not passed, use it unchanged and jump to the separate "perform now?" prompt instead of silently rotating it.
     - **Existing-plan direct-decline handling** (§ 2.1): resolve any existing plan before prompting. Direct `n` with no existing plan marks skipped; direct `n` with an existing plan leaves the plan and state unchanged; `--discard-existing` is the only path that rotates an existing plan/results and marks skipped.
     - **`--force` precedence** (§ 2.1): from terminal states, `--force` bypasses the existing-plan regeneration prompt and rotates plan/results immediately; preserve `seed-family-id` unless `--new-seed-family` was passed.
     - **Stable seed-family id across regeneration** (§ 2.1): read the old plan frontmatter before rotation and preserve `seed-family-id` unless `--new-seed-family` was explicitly passed.
     - **Change-summary freshness gate** (§ 2.1 step 3): call `commits.sh change-summary-fresh <feature>` BEFORE reading the summary. Exit 0 = proceed; exit 1 (stale) or exit 2 (missing) = refuse with the "/mi-draw-diagrams to regenerate" diagnostic. `commits.sh change-summary-fresh` is a check, not a regenerator; the plan skill never regenerates change-summary itself.
     - **Self-contained `## 2. What to run` commands** (§ 2.1 step 3, § 4.1): resolve `RUN_ROOT` from `progress.sh get worktree-path` at render time. Then emit each command in one of two shapes — absolute path inlined (`cd "/abs/path" && <cmd>`, preferred) or a single `export RUN_ROOT="/abs/path"` preamble at the top followed by `cd "$RUN_ROOT" && <cmd>` commands. Bare `cd "$RUN_ROOT" && ...` without the export preamble is rejected by the generator. Codebase search performed during plan generation runs from the resolved path. If a specific command must run from the main checkout, write `cd "/abs/main/checkout"  # reason: <why>` for that command — never an unprefixed bare command.
   - `commands/mi-manual-test-run.md` (note: it owns auto-seeding — the Inspector Handler does NOT). The implementer must additionally build:
     - **Branch B companion flags** from § 2.2 Branch B runner-level flags: `--reclassify`, `--reopen-all`, `--as-new-findings`, `--as-new-findings --force-new-regressions`. Mutual-exclusion: `--reopen-all` and `--as-new-findings` (and the `--force-new-regressions` companion) cannot be combined; runner refuses with diagnostic.
     - **Results/plan ownership validation** (§ 2.2 Branch A/B): before accepting any existing results file, verify `results.feature`, `results.plan-id`, and `results.seed-family-id` match the active feature and current plan frontmatter.
     - **Verdict-block parser contract** (§ 4.2.1): implement the block boundary, exact bullet keys, block-scalar observation extraction, missing-field defaults/refusals, unknown-bullet preservation, and canonical write order in one shared parser used by the verdict commit unit, `--finalize-skipped`, and the auto-seed loop.
     - **Three-branch dispatch (A / B / C) by mode flag** (§ 2.2): parse flags first, then dispatch — `--seed-only` → Branch B, `--finalize-skipped` → Branch C, otherwise Branch A. Refuse with diagnostic if both `--seed-only` and `--finalize-skipped` are passed.
     - **`RUN_ROOT` resolution and worktree-drift guard** (§ 2.2 precondition section, § 2.1 step 3): resolve `RUN_ROOT = progress.sh get worktree-path` in Branches A and B (Branch C does not run commands). `progress.sh get` already reads from the active block, so do not write `active.worktree-path`. The runner's env-up phase echoes the plan's `## 2. What to run` section verbatim — it does NOT post-process or re-substitute `$RUN_ROOT`, because the plan file is the authoritative copy. If the worktree path resolved at run time differs from the path the plan was generated against (worktree was moved between plan and run), refuse with a diagnostic and recommend `/mi-manual-test-plan --force` to regenerate the plan.
     - **Branch C (`--finalize-skipped`) flow** (§ 2.2 Branch C): preconditions including the Branch A/B-style corruption + active-plan ownership validation on results frontmatter (`results.feature`, `results.plan-id`, `results.seed-family-id` must match the active feature and current plan), cursor-integrity check using § 4.2.1 self-healing, write skip verdicts for `current-scenario` onward, then converge directly into Branch A's step 4. Do NOT run env-up, do NOT render any scenario, do NOT touch verdict blocks for scenarios at or after `current-scenario` that already have a real verdict, and do NOT mutate any file if any precondition refuses.
     - **Per-scenario base-status inspection** (§ 2.2 Branch B "Mandatory base-status inspection"). For **both first-time auto-seed (§ 2.2 step 4) AND all `--seed-only` paths**, call `review.sh find-by-seed-id-family` per failed scenario before helper invocation and dispatch on three shapes: family empty (default helper), base missing but family non-empty (orphan-regression branch — extend with `--new-finding` under `--as-new-findings`, refuse-and-skip under `--reopen-all`, prompt under default interactive before any helper call), base present (open → default helper, closed → flag-specific override or helper warning prompt). Under the default interactive orphan branch, call the default helper only if the inspector explicitly chooses to restore the missing base IR.
     - **Verdict block upsert and self-healing** (§ 2.2 per-scenario loop): write verdicts by scenario-id replacement, recompute counts from canonical verdict blocks, advance cursor after commit, handle the crash window where a verdict exists but the cursor still points at that scenario, and self-heal duplicate scenario blocks by keeping latest + warning to stderr.
     - **Observation extraction for auto-seed** (§ 2.2 step 4, § 4.2.1): single-line observations pass through directly; block-scalar observations strip four-space indentation and preserve internal blank lines before piping via `printf '%s\n'`.
     - **Classification override propagation** (§ 2.2 Branch B runner-level flags): compute `reclassify_existing` for first-time `y --classify` and `--seed-only --reclassify`; append `--reclassify` to secondary `--reopen` / `--new-finding` calls and existing-IR default updates.
     - **`Seeded:` flip rule** based on successful seed action, NOT byte-diff (§ 2.2 "`Seeded:` flips on a successful seed action"). The runner classifies the helper's outcome from exit code + presence of `^warning:` on stderr, then flips `Seeded: true` for exit-0-no-warning paths (including idempotent zero-diff reuse), leaves `Seeded: false` for closed-default + skip and for non-zero exits. Crash-recovery test in § 3.7.5 gates this.
     - **Branch B finalization/error semantics** (§ 2.2 Branch B finalization): finalize only on valid exits. Helper non-zero exits are hard errors: do not promote policy, clear sub-flow, or set `manual-test-state=complete`.
     - **`--finalize-skipped` cursor integrity** (§ 2.2 step 5): before writing bulk skips, verify every scenario before `current-scenario` has a valid parsed verdict block after duplicate self-healing.
     - **Gating with the runner tests in § 3.7.5**: open-base-no-`:r1`, closed-base-creates-`:r1`, orphan-regression branches under default / `--as-new-findings` / `--reopen-all`, crash-recovery `Seeded:`, stable `seed-family-id` across `--force`, existing-plan direct decline, results/plan mismatch refusals, verdict-upsert crash recovery, duplicate-verdict self-healing, helper-nonzero no-finalize, partial auto-seed summary, reclassify propagation, corrupt-frontmatter refusals, review-context cache clearing, and `--finalize-skipped` happy/refusal/cursor-integrity paths.

3. **Existing skill edits:**
   - `commands/mi-continue.md` — Resume Step 7 prompt, dispatcher table (with the row inserted **before** `5 | (any)` per § 3.1.2), Manual-Test-Resume Handler section, Inspector Handler addition (summary line only for manual-test results — NO auto-seed/reopen/reclassify/rewrite behavior).
   - `commands/mi-review.md` — Step 2.5 review-context.md addition.
   - `commands/mi-complete-workflow.md` — **archive list extension required**: add `manual-test-plan.md`, `manual-test-results.md`, `manual-test-plan.history/` to the enumerated list. § 3.3 covers the diff.
   - `commands/mi-abort-workflow.md` — **clear list extension required**: add `manual-test-plan.md`, `manual-test-results.md`, `manual-test-plan.history/` to the enumerated rm list. § 3.4 covers the diff.
   - `commands/mi-resume-workflow.md` — diagnostic recognition for the new sub-flow.
   - `scripts/doctor.sh` — add the full § 3.8 manual-test checks using the existing JSON `record` shape.
   - `commands/mi-doctor.md` — no detection duplication; render the new `scripts/doctor.sh` checks like other env checks, with optional label/prose updates only.

4. **Docs:** update `docs/workflow-spec.md`'s stage-5 description to mention the manual-test sub-flow and the feature-scoped `implementation/` artifact location; update `commands/mi-continue.md`'s "When invoked" preamble to list the new auto-fire path.

---

## 9. Open questions / decisions still needed

1. **Schema enforcement of plan structure.** Hard-enforcing `## 1. Prerequisites / ## 2. What to run / ## 3. Test scenarios` makes parsing easier but may be too rigid for cycles that need a different shape (e.g., backend-only with no `## 2. What to run`). Consider making sections 1 and 3 required, section 2 optional.
