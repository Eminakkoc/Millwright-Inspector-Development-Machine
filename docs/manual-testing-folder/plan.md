# Manual-test folder relocation — implementation plan

## 1. Goal

Move the manual-test artifacts out of the workflow-scoped `implementation/`
folder (which is wiped/archived at stage 8) into a new dedicated
**feature-permanent** folder `workflow-stream/<feature>/test/`. After this
change, the test/ folder behaves like `decisions.md` — it lives at the
feature root and is **never** rotated or deleted by the normal completion
flow. The intent is to keep manual-test plans and per-run verdict histories
available indefinitely for re-use across future cycles of the same feature.

### 1.1 Before / after

| Artifact                                  | Today's location                                                  | New location                                                |
| ----------------------------------------- | ----------------------------------------------------------------- | ----------------------------------------------------------- |
| `manual-test-plan.md`                     | `workflow-stream/<feature>/implementation/manual-test-plan.md`    | `workflow-stream/<feature>/test/manual-test-plan.md`        |
| `manual-test-results.md`                  | `workflow-stream/<feature>/implementation/manual-test-results.md` | `workflow-stream/<feature>/test/manual-test-results.md`     |
| `manual-test-plan.history/<timestamp>/`   | `workflow-stream/<feature>/implementation/manual-test-plan.history/` | `workflow-stream/<feature>/test/manual-test-plan.history/` |

The on-disk shape inside the folder is almost unchanged — filenames and
YAML frontmatter on each file are identical to today — with one
addition: a new sibling history directory
`test/manual-test-results.history/<UTC-timestamp>/manual-test-results.md`
holds results files auto-rotated out of the way at the start of a new
cycle (see §4.1). The existing `manual-test-plan.history/` continues to
hold plan rotations from `--force` / `--discard-existing`. The two
history directories are intentionally separate because plans and
results have independent lifecycles under cross-cycle reuse: a plan
may survive untouched across many cycles while the per-cycle results
rotate every time.

### 1.2 Lifecycle change

| Event                       | Today                                                                                                                                                              | After this change                                                                            |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------- |
| `/mo-complete-workflow` (stage 8) | `implementation/manual-test-plan.md`, `manual-test-results.md`, and `manual-test-plan.history/` are moved into `blueprints/history/v[N+1]/implementation/`. | `test/` folder is **left in place**. Nothing under it is moved, archived, or deleted.        |
| `/mo-abort-workflow`        | `implementation/manual-test-plan.md`, `manual-test-results.md`, `manual-test-plan.history/` are deleted alongside the other implementation artifacts.              | `test/` folder is **left in place** (open question — see §6.1).                              |
| `/mo-manual-test-plan --force` / `--discard-existing` | Rotates current plan + results into `implementation/manual-test-plan.history/<timestamp>/`.                                                          | Rotates into `test/manual-test-plan.history/<timestamp>/`. Same rotation mechanics, new root.|
| Next cycle for the same feature | Folder didn't survive — a fresh plan is generated against a clean directory.                                                                                  | The previous plan + results survive at `test/`. The next cycle's `/mo-manual-test-plan` either reuses the existing plan or rotates it into `manual-test-plan.history/` under the same `seed-family-id`. |

## 2. Files to change

### 2.1 Scripts

- **`scripts/internal/common.sh`** — add a sibling helper alongside `mo_impl_dir`:

  ```bash
  mo_test_dir() { echo "$(mo_feature_dir "$1")/test"; }
  ```

- **`scripts/blueprints.sh`** — three existing subcommands that resolve
  manual-test paths today via `mo_impl_dir` (lines 534–570), plus one
  new subcommand for results-only rotation (§4.1):

  - `manual-test-plan-path` — switch to `mo_test_dir`.
  - `manual-test-results-path` — switch to `mo_test_dir`.
  - `manual-test-plan-rotate` — `impl_dir` local variable becomes `test_dir`;
    `history_dir` resolves under the new root. Add a `mkdir -p` for
    `$test_dir` at the top of rotate so the move targets exist even when
    rotate is the first subcommand to touch the folder (today `manual-test-plan-rotate`
    relies on `implementation/` already existing because stage 4 created it).
  - `manual-test-results-rotate-only` (NEW) — moves ONLY
    `test/manual-test-results.md` into
    `test/manual-test-results.history/<UTC-timestamp>/manual-test-results.md`.
    Leaves `test/manual-test-plan.md` and `test/manual-test-plan.history/`
    untouched. Refuses with `^info: no manual-test-results.md to rotate`
    when the file is absent (non-fatal — exit 0). Used by §4.1's per-cycle
    results auto-rotation. The sibling history directory
    `manual-test-results.history/` is parallel to `manual-test-plan.history/`
    so the two lifecycles stay independent.
  - Update the usage string at the bottom of `blueprints.sh` accordingly.

  The renderers in `/mo-manual-test-plan` and `/mo-manual-test-run` use
  `frontmatter.sh init` and direct file writes — these will create the
  `test/` folder lazily, but the rotate path must also be safe when called
  before any plan-create has run.

- **`scripts/bundle.sh`** — three sets of references at lines 106–107
  and 244–256:

  - Local variables `manual_plan_md` and `manual_results_md` (lines 106–107)
    point at `workflow-stream/$feature/implementation/...` — change to
    `workflow-stream/$feature/test/...`.
  - `BODY_SCRUB_TABLE` regex at line 244 includes `\bimplementation/(?:...|manual-test-plan|manual-test-results|...)\.md\b`.
    Add a sibling pattern for the `test/` prefix:

    ```python
    (re.compile(r"\btest/(?:manual-test-plan|manual-test-results)\.md\b"),
     "<an internal record>"),
    ```

    Keep the implementation/ entry as-is for backwards-compatibility with
    legacy bundles that reference older shapes (still extractable from
    archived history).
  - The bare-filename regex at lines 252–256 already matches the bare
    filenames — no change needed there.
  - Refresh the comment block at line 6 mentioning "manual-test-*" path
    expectations.

- **`scripts/progress.sh`** — three additions for the §4.3 activation-id
  mechanism:

  - **`activate` subcommand** (line ~129–183): mint a fresh UUIDv4
    via `"${MO_PLUGIN_ROOT}/scripts/uuid.sh"` and add it to the
    `fm['active']` dict alongside the existing initialization fields
    (between `manual-test-failure-policy` and `worktree-path`). Use
    key `activation-id`.
  - **`reset` subcommand** (line ~281–323): same — mint a fresh
    UUIDv4 in the rebuilt `fm['active']` dict. This is the load-bearing
    change for §4.1's cross-cycle guard: re-minting on reset is what
    makes abort-retry register as a new activation even when git HEAD
    hasn't moved.
  - **Immutability list**: add `activation-id` to the immutable-after-activate
    field list checked by `set` (line ~495) and `advance-to` (line
    ~698). One narrow exception applies: a `set activation-id=<uuid>`
    is allowed when the field is currently missing (in-flight cycles
    activated before this change). The §4.3 "compatibility" backfill
    relies on this exception; encode it as `"field is immutable, but
    missing → set is allowed once"`.

- **`scripts/doctor.sh`** — verifies templates/schemas only; no data-path
  references to change. Add a check that `progress.schema.yaml`
  declares `activation-id` (similar to the existing
  `manual-test-state` / `manual-test-failure-policy` checks at line
  168) so a stale schema does not silently invalidate the new field.

- **`scripts/migrate-test-folder.sh`** (NEW, one-shot) — walks every
  `workflow-stream/*/implementation/` under the data root and moves
  `manual-test-plan.md`, `manual-test-results.md`, and
  `manual-test-plan.history/` to a sibling `test/` directory. Uses
  `mv -n` so re-runs are idempotent. Resolves the data root via
  `scripts/data-root.sh`. Prints a one-line summary per feature
  (`moved`, `nothing-to-move`, `already-migrated`). See §5.1 for the
  rationale; §7 step 4 schedules its invocation. Add a doctor check
  for its presence so it doesn't bit-rot.

### 2.2 Commands

For each, replace every occurrence of `workflow-stream/<feature>/implementation/manual-test-plan.md`,
`workflow-stream/<feature>/implementation/manual-test-results.md`, and
`workflow-stream/<feature>/implementation/manual-test-plan.history/` with the
`test/`-prefixed form. Replace inline shell snippets like
`"$impl_dir/manual-test-plan.md"` with `"$test_dir/manual-test-plan.md"`.

- **`commands/mo-manual-test-plan.md`** — three categories of edit:

  - Literal path updates in body prose (§1 invocation paragraph, §1
    "sub-flow" prose, Step 1, Step 5, Step 7 prompt). Also update the
    "Sub-flow `manual-testing`" prose if needed.
  - **Step 1 addition (§4.1 auto-rotation):** after the existing
    `plan_path` probe, add a parallel results-file probe and apply the
    §4.1 triple-AND prior-cycle guard
    (`results.plan-id == plan.id AND plan.generated-from-base-commit != active.base-commit`,
    state-agnostic). Only then call
    `blueprints.sh manual-test-results-rotate-only`. The base-commit
    clause is what distinguishes a prior-cycle leftover from a
    same-cycle `--seed-only` recovery case OR a same-cycle paused-run
    resume. The state-agnostic shape covers prior-cycle `complete`
    AND `in-progress` results — both can leak across cycles now that
    `/mo-abort-workflow` keeps `test/` intact (§6.1). Read-only
    against `progress.md` — safe to run before the existing read-only
    gates.
  - **New Step 1.5 (§4.2 freshness gate):** insert between the
    existing Step 1 and Step 2. Computes the
    `(requirements-id, generated-from-base-commit)` mismatch and
    dispatches per the table in §4.2. The gate MUST run before Step 2
    because the existing `--from-resume` + existing-plan branch in
    Step 2 (line 89 of `commands/mo-manual-test-plan.md`) jumps
    directly to Step 7, bypassing Step 3 entirely — a gate placed at
    Step 3 would never fire on the most important cross-cycle reuse
    path. Refusal/`c` answer leaves `progress.md` byte-identical
    (matches the "read-only gates" contract). On `y`, the gate sets
    an in-memory `freshness_forced_regen=true` flag that Step 2's
    branches consult: any branch that would have used the plan
    unchanged instead falls into the regeneration path (Steps 4–6),
    as if `--force` had been passed.

- **`commands/mo-manual-test-run.md`** — Branches A/B/C preconditions name
  the path literally; same change. The "Resolve RUN_ROOT" block doesn't
  reference the manual-test path. The worktree-drift guard reads
  `blueprints.sh manual-test-plan-path` (which is the right indirection);
  no change there except the prose around it.

  **Branch A pre-normalization addition (§4.1 fallback auto-rotation):**
  at the TOP of the pre-normalization step — before BOTH the existing
  "Valid `state: complete`: refuse" block AND the existing
  "Valid `state: in-progress`: continue to workflow-state normalization
  (paused-resume case)" branch — apply the §4.1 triple-AND prior-cycle
  guard
  (`results.plan-id == plan.id AND plan.generated-from-base-commit != active.base-commit`,
  state-agnostic). If both hold, call
  `blueprints.sh manual-test-results-rotate-only`, print a one-line
  `^info:` to stderr, and proceed as if the results file were absent
  (jumps to the "Results file absent: continue to workflow-state
  normalization" path). Same-cycle branches (where
  `plan.generated-from-base-commit == active.base-commit`) still fire
  as today: `state: complete` → `--seed-only` refusal,
  `state: in-progress` → paused-resume.

- **`commands/mo-complete-workflow.md`** — **structural change**, not a
  literal rename:

  - Step 5's `for artifact in overseer-review.md review-context.md change-summary.md grounding-report.md \ manual-test-plan.md manual-test-results.md; do`
    loop must **drop** `manual-test-plan.md` and `manual-test-results.md`.
  - The `[[ -d "$impl_dir/manual-test-plan.history" ]] && mv -n "$impl_dir/manual-test-plan.history" ...`
    line must be **deleted** (no longer applicable — the folder no longer
    lives under `impl_dir`).
  - The narrative paragraph after the code block ("The historical snapshot
    is then complete: …") must be updated to remove the manual-test items
    from the archive list and add a sentence noting that the test/ folder
    survives at the feature root, alongside `decisions.md`.

- **`commands/mo-abort-workflow.md`** — Step 4 currently `rm`s
  `$impl_dir/manual-test-plan.md`, `$impl_dir/manual-test-results.md`, and
  `$impl_dir/manual-test-plan.history`. Per the permanence intent, these
  `rm` lines should be **deleted** so abort leaves the test/ folder
  intact. Update the Step 2 user-facing confirmation message accordingly
  ("delete implementation/…") so the overseer knows the test/ folder
  survives. Treat as the default; revisit per §6.1.

- **`commands/mo-continue.md`** — multiple literal references requiring
  update:
  - Line 894 — user-facing prompt naming `workflow-stream/<active_feature>/implementation/manual-test-plan.md`.
  - Line 966 — surface-summary code-block prose naming `workflow-stream/<active_feature>/implementation/manual-test-results.md`.
  - Line 935 — indirect via `blueprints.sh manual-test-plan-path` (picks
    up the new path automatically once §2.1 lands; no edit needed here).
  - Line 988 — bare filename `manual-test-results.md` in prose; no path
    prefix, but re-read after the helper rename to confirm.

  **Audit gate.** Before declaring the command-update pass complete,
  run an `rg`-based sweep across `commands/`, `scripts/`, `schemas/`,
  `templates/`, and `docs/` for `implementation/manual-test-plan`,
  `implementation/manual-test-results`, and
  `implementation/manual-test-plan.history`. Every hit must either be
  rewritten to `test/...` or be a deliberate reference to archived
  history under `blueprints/history/v[N]/implementation/`. Do not rely
  on the per-file line-number lists in this plan — they are pre-edit
  pointers, not an exhaustive contract.

- **`commands/mo-review.md`** — one reference in the "## Manual test
  results" section description (line 72) — update the literal path.

- **`commands/mo-resume-workflow.md`** — no literal path changes; the row
  description for `5 | manual-testing` references the file by name only.
  Re-read after rename and confirm no stale prose remains.

- **`commands/mo-doctor.md`** — no data-path references.

### 2.3 Schemas

- **`schemas/manual-test-plan.schema.yaml`** —
  - `title` (line 3) reads `workflow-stream/<feature>/implementation/manual-test-plan.md frontmatter`.
    Update to `workflow-stream/<feature>/test/manual-test-plan.md frontmatter`.
  - Add `generated-in-activation` to the `required:` list (line 17
    area) and to the `properties:` block. UUIDv4 pattern, same as
    the existing `seed-family-id` declaration. Description: "UUIDv4
    of the `progress.md.active.activation-id` in effect when this
    plan was rendered. Read by `/mo-manual-test-plan` Step 1 and
    `/mo-manual-test-run` Branch A pre-normalization as the
    cross-cycle discriminator (see `docs/manual-testing-folder/plan.md`
    § 4.3)."
- **`schemas/manual-test-results.schema.yaml`** —
  - Same title-line update at line 3.
  - Same `generated-in-activation` addition (required + properties).
    Description: "UUIDv4 of the activation that started this run.
    Copied from the plan's `generated-in-activation` field at
    results-render time."
- **`schemas/progress.schema.yaml`** —
  - The description block on `manual-test-state` (line 202 area)
    references the implementation path in prose:
    `workflow-stream/<feature>/implementation/manual-test-plan.md`.
    Update to the `test/` path.
  - Add `activation-id` to `active`'s `properties:` block as an
    optional UUIDv4 string. **Do not add it to the `required:` list**
    — in-flight cycles activated before this change must still
    validate. Description: "UUIDv4 minted at activate time and
    re-minted at reset. Cross-cycle discriminator for the
    manual-test sub-flow's results-rotation guard. See
    `docs/manual-testing-folder/plan.md` § 4.3."

### 2.4 Templates

- **`templates/manual-test-plan.md.tmpl`** —
  - Review the body for any literal path references and update if
    present. (Spot-check at line 13 refers to "the runner reads ...
    the worktree path recorded in `generated-against-run-root`" — no
    folder path. Likely no change needed, confirm during
    implementation.)
  - Add `generated-in-activation: {{ACTIVATION_ID}}` to the
    frontmatter, immediately after the existing
    `generated-against-run-root` line. Resolved at render time via
    `progress.sh get activation-id` (after §4.3's backfill at Step 1
    has populated it for in-flight cycles).
- **`templates/manual-test-results.md.tmpl`** —
  - Same spot-check.
  - Add `generated-in-activation: {{ACTIVATION_ID}}` to the
    frontmatter. **Resolved at render time by copying the plan's
    `generated-in-activation` value**, NOT by re-reading
    `progress.md`. The plan is the authority on which activation
    started this run, and copying preserves the "this run belongs to
    the plan it was rendered against" invariant even if the
    activation has since been re-minted (e.g., abort-retry crashed
    after plan render but before run-render).

### 2.5 Documentation

- **`docs/workflow-spec.md`** — many references, including the feature-tree
  layout diagrams at lines 168–215 and the artifact list at line 237.
  The tree needs a new `test/` node at the feature root; the
  `implementation/` node loses its three manual-test entries; the prose
  about "stage 8 archives implementation/ into history" needs to
  explicitly note that the test/ folder is excluded from rotation, **the
  way `decisions.md` is excluded today**. Specific lines to edit:
  156–158, 168–215 (the two ASCII trees), 237, 542, 711–714, 742, 745,
  853, 1117. Add a new bullet under the "feature root contents" list
  documenting `test/`.

- **`docs/manual-testing/plan.md`** — design plan for the original feature.
  § 1.4 says "Files live under `workflow-stream/<feature>/implementation/`"
  with explicit paths. Either patch § 1.4 inline with the new path
  (preferred — preserves design history) or add a § 1.4.1 amendment
  pointing here. Same for any prose under §§ 2.2, 4.2.1 that names the
  literal path.

- **`docs/bundle/plan.md`** — references `manual-test-*.md` in the
  canonical-files list (lines 19–21). Update to mention the new `test/`
  parent location.

- **`docs/project-report.md`** — already in the `M` modified-files list;
  contains brief manual-test references; update any literal paths.

## 3. Schema invariants and validation

- The two `manual-test-*.schema.yaml` files validate **frontmatter only**.
  Their `$id` fields stay unchanged (they're identifiers, not paths). The
  `title` field is documentation. No validator code change.
- The `mo-doctor` checks at `commands/mo-doctor.md` lines 78–91 verify
  template + schema + `progress.schema.yaml` enum values. None of those
  reference data paths. No change.
- The `progress.schema.yaml` enum value `manual-testing` (sub-flow) and
  the fields `manual-test-state` / `manual-test-failure-policy` stay
  exactly as they are — they describe workflow state, not file location.

## 4. Permanence semantics

The test/ folder is the second feature-permanent artifact, joining
`workflow-stream/<feature>/decisions.md`. The full feature-root contents
become:

```
workflow-stream/<feature>/
├── blueprints/                          ← rotated per cycle
│   ├── current/
│   └── history/v[1..N]/
├── implementation/                      ← wiped at stage 8 (archived into history)
├── test/                                ← feature-permanent (NEW)
│   ├── manual-test-plan.md              ← survives across cycles
│   ├── manual-test-results.md           ← current-cycle results; rotated at start of next cycle (§4.1)
│   ├── manual-test-plan.history/        ← rotated plans (--force / --discard-existing)
│   └── manual-test-results.history/     ← rotated results (auto-rotated per cycle, §4.1) — NEW
└── decisions.md                         ← feature-permanent (already exists)
```

**Cross-cycle reuse.** Because the test/ folder survives, the next cycle
for the same feature inherits the prior plan automatically. The current
flow does NOT handle this safely as-is — two problems must be solved
before cross-cycle reuse works.

### 4.1 Terminal `manual-test-results.md` blocks the next cycle's run

`commands/mo-manual-test-run.md` Branch A's pre-normalization step
explicitly refuses any results file with `state: complete`:

> Valid `state: complete`: refuse: `"Manual test results already complete.
> Pass --seed-only to manage auto-seeding, or /mo-manual-test-plan --force
> to start over."` Do NOT normalize progress.md.

A finalized run from cycle N leaves `manual-test-results.md` with
`state: complete`. Under today's lifecycle that file gets archived at
stage 8 and the next cycle starts clean; under the new lifecycle that
file survives, so cycle N+1's `/mo-manual-test-run` is dead-on-arrival
with the refusal above. The plan must add a **per-cycle results rotation**:

- Introduce a new helper `blueprints.sh manual-test-results-rotate-only`
  that moves ONLY the results file (and not the plan) into
  `test/manual-test-results.history/<UTC-timestamp>/manual-test-results.md`.
  This is a sibling rotation directory parallel to the existing
  `manual-test-plan.history/` so the plan vs. results lifecycles stay
  independent.
- `commands/mo-manual-test-plan.md` Step 1 (existing-plan probe) gains
  a parallel check. Auto-rotate the results file whenever it
  unambiguously belongs to a prior cycle. The guard uses **activation-id**
  as the cross-cycle discriminator (see §4.3 for the activation-id
  mechanism):

  ```
  results_exists                                              AND
  results.plan-id == plan.id                                  AND
  results.generated-in-activation != active.activation-id
  ```

  Activation-id (defined in §4.3) is a per-activation UUIDv4 captured
  into plan and results frontmatter at render time. It is
  git-independent — minted fresh by `progress.sh activate` AND
  re-minted by `progress.sh reset` (the abort-retry path) — so it
  correctly distinguishes prior activations from the current one even
  when:

  - The prior cycle made zero commits (zero-commit-abort, direct-empty).
  - The overseer manually `git reset`s the worktree back to the prior
    baseline between cycles.
  - `active.base-commit` happens to match `plan.generated-from-base-commit`
    for any other reason.

  The guard is **deliberately agnostic to `results.state`** — both
  `complete` and `in-progress` are rotated, because both can leak
  across cycles under the new permanence model:

  - `state: complete` — finalized run from a prior cycle. Today's
    runner would refuse with the `--seed-only` recovery message.
  - `state: in-progress` — paused or aborted run from a prior cycle.
    With `/mo-abort-workflow` now keeping `test/` intact (§6.1),
    aborted runs leave `state: in-progress` results behind. Today's
    runner Branch A would treat these as a paused mid-run case
    (`current-scenario` cursor still set, verdict blocks in the body),
    silently resume from the stale cursor, and recompute counts from
    stale verdict blocks — wrong cycle, completely invalid.

  Without the activation-id clause, a same-activation completed run
  with stale `progress.md` markers (the `(none, none) + results=complete`
  recoverable state called out in `commands/mo-manual-test-run.md`
  Branch B preconditions, line ~103) would be wrongly rotated, which
  would destroy the `--seed-only` recovery path. With it, that
  same-activation case falls through to the existing Step 2 branches
  unmodified — the overseer reaches the existing `--seed-only` flow
  as designed. Same-activation paused runs (`state: in-progress` with
  matching activation-id) likewise fall through to Branch A's
  existing paused-resume handling. This is read-only against the
  plan, so it composes with all the existing Step 2 branches
  (regenerate/use-unchanged/force).

- `commands/mo-manual-test-run.md` Branch A pre-normalization gains a
  parallel pre-check using the SAME triple-AND guard above. If all
  three conditions hold, auto-rotate the results file and proceed as
  if results were absent. This is the fallback path when the runner
  is reached without `/mo-manual-test-plan` having fired first. The
  existing `state: complete` refusal and the existing
  `state: in-progress` paused-resume path both still fire for the
  same-activation case (where `results.generated-in-activation == active.activation-id`)
  — that's the genuine "use `--seed-only`" or "resume from cursor"
  path.
- The auto-rotation prints a one-line `^info:` to stderr naming the
  rotation target so the overseer sees what happened.

**Why not base-commit?** An earlier draft of this plan used
`plan.generated-from-base-commit != active.base-commit` as the
discriminator. That clause fails on the abort-retry-without-new-commits
path: `progress.sh reset` wipes `active.base-commit` to `null`, the
next stage-2 re-captures it from HEAD, and if HEAD has not moved
(zero-commit abort, direct-empty resume, manual `git reset` to the
prior baseline), the new base-commit matches the old plan's value
verbatim — the guard misses and prior-cycle results leak through.
Activation-id is git-independent, so it does not have this hole.

`state: skipped` is not a results-file value — the manual-test-state
enum value `skipped` is recorded in `progress.md` only. The
results-file `state` enum is `[in-progress, complete]`, both of which
the activation-id guard now covers.

### 4.2 Stale plan against current cycle's requirements / commits

Plan frontmatter today carries `generated-from-base-commit`,
`generated-from-head`, `requirements-id`, and `generated-against-run-root`
(see `schemas/manual-test-plan.schema.yaml` lines 17–60). Across cycles
all four can drift:

- `requirements-id` — bumps whenever `blueprints/current/requirements.md`
  is rotated (which `/mo-update-blueprint` and stage-8 completion both
  do). A plan from cycle N tests against cycle N's `Goals`/`Planned`
  lists, not cycle N+1's.
- `generated-from-base-commit` / `generated-from-head` — drift with
  every cycle's `base-commit..HEAD` range. The "What to run" and
  scenarios may reference symbols, env vars, or routes that no longer
  exist (or have been renamed) in cycle N+1's tree.
- `generated-against-run-root` — currently the only field the runner
  checks (the worktree-drift guard at `mo-manual-test-run.md` lines
  61–71). May still match if the overseer reuses the same worktree
  path for cycle N+1, masking the staleness.

Add a **plan-freshness gate** to `commands/mo-manual-test-plan.md` as
a new **Step 1.5**, between the existing Step 1 (existing-plan probe
+ §4.1 results auto-rotation) and Step 2 (overseer prompt dispatch).
This placement is load-bearing: the existing "Existing plan present,
`--from-resume` without `--force`" branch in Step 2 explicitly skips
Steps 3–6 and jumps straight to Step 7 (see
`commands/mo-manual-test-plan.md` line 89), so a gate placed at Step 3
would never fire on the `--from-resume` reuse path — the very path
most likely to encounter a stale plan from a prior cycle. The gate
must run BEFORE Step 2's dispatch so every "use unchanged" branch
inherits its result.

Step 1.5 logic:

```
# Skip entirely when no plan exists — nothing to be stale about.
[[ -f "$plan_path" ]] || skip gate

plan_req_id           = frontmatter(plan).requirements-id
plan_base_commit      = frontmatter(plan).generated-from-base-commit
current_req_id        = frontmatter(workflow-stream/<feature>/blueprints/current/requirements.md).id
current_base_commit   = progress.sh get base-commit

mismatch              = (plan_req_id != current_req_id) || (plan_base_commit != current_base_commit)
```

Branch on `(--from-resume, --force, mismatch)`:

| `--from-resume` | `--force` | Mismatch | Behavior                                                                                                                                                                                                                                                                                |
| --------------- | --------- | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| no              | no        | yes      | Prompt: `"Existing manual-test plan was generated against requirements <plan_req_id> / base-commit <plan_base_commit>; current cycle is <current_req_id> / <current_base_commit>. Regenerate? (y to rotate + regenerate, n to use the stale plan anyway, c to cancel.)"` Default to `c` on Ctrl-D. On `y`, treat the rest of Step 2 as if `--force` had been passed (skips Step 2's existing "regenerate?" prompt — the freshness prompt already answered it). On `n`, fall through to Step 2 unchanged (existing-plan branches will run; user-typed `n` to the Step 2 "regenerate?" prompt now uses the stale plan as the user explicitly chose). On `c`, exit 0 with `progress.md` byte-identical. |
| yes             | no        | yes      | Same prompt body. `--from-resume` suppresses ONLY the no-existing-plan duplicate prompt — staleness is a different decision and must surface. On `y`, treat as if `--force` had been passed (the existing `--from-resume` + existing-plan branch's "skip Steps 3–6, jump to Step 7" no longer fires; Steps 3.5–6 run). On `n`, fall through to the existing `--from-resume` branch (jumps to Step 7 using the stale plan, user-acknowledged). On `c`, exit 0. |
| any             | yes       | yes      | No prompt — `--force` already signals regeneration. Continue to Step 2 (which dispatches the `--force` regeneration path).                                                                                                                                                              |
| any             | any       | no       | No prompt — plan is fresh against the current cycle. Continue to Step 2 unchanged.                                                                                                                                                                                                      |
| any             | any       | (no plan) | Gate skipped entirely. Continue to Step 2.                                                                                                                                                                                                                                              |

The prompt is read-only against `progress.md` — answer `n` continues
without rotation, just like the existing "leave in place" branch. Answer
`c` exits with `progress.md` byte-identical, matching the read-only-gates
contract at the top of the execution section of
`commands/mo-manual-test-plan.md`. Answer `y` defers actual rotation
to Step 4 (existing); Step 1.5 only sets an in-memory flag that the
downstream branching consults.

`/mo-manual-test-run` does NOT duplicate this check — it trusts that
`/mo-manual-test-plan` (auto-fired by `/mo-continue`'s Resume Step 7, or
direct) ran first. The worktree-drift guard stays as a fast-fail backstop.

### 4.3 Activation-id mechanism

The activation-id is a UUIDv4 minted at feature activation time and
preserved for the entire activation's lifetime (until `finish` /
`requeue` clears the active block, or `reset` re-mints it as part of
the abort-retry path). It is the orthogonal cross-cycle discriminator
that §4.1's rotation guard depends on, and the only field-level change
this plan introduces to `progress.md.active`.

**Why activation-id, not base-commit.** See §4.1's "Why not
base-commit?" callout for the failure mode. In short: base-commit is
derived from git state, which can be reset between activations without
making any commits; activation-id is intrinsic workflow state and is
not coupled to git.

**Where activation-id lives:**

| Field                                                | Lifecycle                                                                          | Source of truth                                                                                                                                                                                                                                       |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `progress.md.active.activation-id`                   | Per-activation lifetime; minted at activate, re-minted at reset, cleared at finish/requeue. | The canonical identifier of the current activation.                                                                                                                                                                                                  |
| `manual-test-plan.md` frontmatter `generated-in-activation` | Per-plan-version lifetime; written once at plan render time.                  | Captures which activation generated this plan.                                                                                                                                                                                                       |
| `manual-test-results.md` frontmatter `generated-in-activation` | Per-results-file lifetime; written once at results render time.            | Captures which activation started this run. Copied from the plan's value at render time (so a run started under the same plan within the same activation always matches the plan, and a re-run under a re-minted activation does not). |

**Activation-id minting and preservation across `progress.sh`
subcommands:**

| Subcommand                  | Behavior                                                                                                                                                              |
| --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `progress.sh activate`      | Mints a fresh UUIDv4 via `scripts/uuid.sh`, writes to `active.activation-id`. (New behavior.)                                                                          |
| `progress.sh reset`         | Re-mints a fresh UUIDv4 alongside the existing field re-initialization (line 294 onward in `scripts/progress.sh`). This is what makes abort-retry register as a NEW activation, closing the §4.1 base-commit hole. |
| `progress.sh finish`        | Clears `active.activation-id` as part of setting `active=null` (today's behavior; no change needed — the whole `active` block is replaced).                            |
| `progress.sh requeue`       | Same as finish — `active` is cleared, so `activation-id` goes with it.                                                                                                |
| `progress.sh set`           | `activation-id` is **immutable after activate**. Add it to the existing immutability list in `progress.sh` (line ~495).                                              |
| `progress.sh advance-to`    | Same immutability — add to the immutable list at line ~698. Advancing stages within an activation does NOT mint a new activation-id.                                  |

**Compatibility with in-flight features.** The new field is **optional
on read**, **required on new writes**. Specifically:

- `schemas/progress.schema.yaml` declares `activation-id` as an
  optional UUIDv4 string (not in the `required:` list) — in-flight
  cycles activated before this change will have a missing field and
  the schema validator will accept them.
- The §4.1 rotation guard treats a missing `active.activation-id` or
  a missing `results.generated-in-activation` as **non-matching**
  (i.e., rotate). This is the safe default: an unidentifiable
  activation is treated as cross-cycle.
- The first `/mo-manual-test-plan` run after the change ships, on a
  feature whose `progress.md.active` lacks `activation-id`, must
  populate the field before rendering the plan. Add a one-shot
  backfill at the top of Step 1: if `active.activation-id` is missing,
  mint one via `uuid.sh` and `progress.sh set activation-id=<uuid>`
  (immutability rule above is relaxed for the missing → set
  transition only). This avoids requiring a global migration script
  for the active block.

**Schemas:**

- `manual-test-plan.schema.yaml` — add `generated-in-activation` to
  the required-fields list (line 17 area) and to the `properties:`
  block. UUIDv4 pattern, same as the existing `seed-family-id`.
- `manual-test-results.schema.yaml` — same addition.

**Templates:**

- `manual-test-plan.md.tmpl` — add `generated-in-activation: {{ACTIVATION_ID}}`
  to the frontmatter.
- `manual-test-results.md.tmpl` — same.

**Renderers:**

- `/mo-manual-test-plan` Step 5 (render) — `{{ACTIVATION_ID}}` is
  resolved via `progress.sh get activation-id`. Backfill (above)
  runs at Step 1 before this point.
- `/mo-manual-test-run` Step 1 (resolve results file) — when
  rendering from the template, `{{ACTIVATION_ID}}` is copied from the
  plan's `generated-in-activation` field, NOT re-read from
  `progress.md`. This is deliberate: it lets the runner detect when
  the plan was reused across activations (plan's value differs from
  current `active.activation-id`) before the results file even gets
  written.

### 4.4 Seed-family-id preservation

The `seed-family-id` preservation under `--force` (without
`--new-seed-family`) takes on new meaning: failures auto-seeded into the
new cycle's `overseer-review.md` carry the SAME seed-family-id as prior
cycles' seedings. This is desirable — re-failures of the same scenario
remain idempotent across cycles via seed-id. No change needed to the
seed-family-id mechanics; only the cross-cycle survival changes.

## 5. Migration

Two categories of existing data to consider:

### 5.1 In-flight features (rare)

If a feature currently has `implementation/manual-test-plan.md` and the
cycle has not reached stage 8, the new code will not find the file under
`test/`. Migration options:

- **One-shot script** (`scripts/migrate-test-folder.sh`) that walks every
  `workflow-stream/*/implementation/` directory and moves
  `manual-test-plan.md`, `manual-test-results.md`, and
  `manual-test-plan.history/` to a sibling `test/` directory. Idempotent
  (`mv -n` style). Run once after the code change ships.
- **Lazy migration in `blueprints.sh manual-test-plan-path`** — on every
  call, if the test/ file is missing AND the implementation/ counterpart
  exists, move it. Adds branching to a hot path; rejected unless the
  one-shot script proves insufficient.

Recommended: ship `scripts/migrate-test-folder.sh` (listed as a new
artifact in §2.1) and document running it as part of the change-set
landing. The author's own working tree (this repo) has no active
manual-test artifacts under `implementation/` today — check with a
`find $(scripts/data-root.sh) -type f \( -name manual-test-plan.md -o -name manual-test-results.md \) -path '*/implementation/*'`
before deciding whether the script needs to run. If the find returns
empty, the script is a no-op and can ship as a tested-but-unused
artifact for future operators.

### 5.2 Archived history (already in `blueprints/history/v[N]/implementation/`)

Already-rotated cycles have manual-test artifacts inside
`blueprints/history/v[N]/implementation/`. **Leave these untouched.**
They are part of the immutable audit record and the new code never reads
them as live state. The lookup helpers (`manual-test-plan-path`,
`manual-test-results-path`) point at the live `test/` folder only;
archived versions are inspected by the overseer manually when needed.

## 6. Open questions

### 6.1 Abort behavior

Should `/mo-abort-workflow` delete the test/ folder? Two readings:

- **Keep it (recommended).** Abort means "this cycle didn't ship, reset
  for retry" — but the manual-test work the overseer already did
  (scenarios written, runs executed) is valuable across retries. Same
  rationale as keeping `blueprints/current/` intact on abort.
- **Delete it.** Abort means "wipe everything this cycle produced." But
  if `blueprints/current/` and `decisions.md` survive, test/ surviving is
  consistent with that pattern.

Plan currently goes with "keep it" (§2.2). Confirm with overseer before
shipping.

### 6.2 `--discard-existing` semantics

Today `--discard-existing` rotates the existing plan into history and
marks the phase skipped. With test/ permanent, "discard existing" still
means "rotate this plan into history then skip" — the rotated copy lives
in `test/manual-test-plan.history/` and survives. The semantics are
unchanged; only the location shifts.

### 6.3 Naming

`test/` is short and matches the directory's purpose. Alternative names
considered:

- `manual-test/` — more explicit, but redundant given the file prefixes.
- `qa/` — broader-sounding, opens the door to non-manual-test artifacts.
- `tests/` (plural) — collision with the repo's own `tests/` convention.

Recommended: `test/`. Confirm before implementation.

## 7. Implementation order

1. **Add `mo_test_dir` helper** in `scripts/internal/common.sh`.
2. **Land the §4.3 activation-id mechanism** (must precede the
   manual-test command edits below — they read the field):
   - Add `activation-id` to `schemas/progress.schema.yaml` as an
     optional UUIDv4 string.
   - Update `scripts/progress.sh` `activate` (mint), `reset`
     (re-mint), `set` and `advance-to` (immutability + missing→set
     exception).
   - Add `generated-in-activation` to
     `schemas/manual-test-plan.schema.yaml` and
     `schemas/manual-test-results.schema.yaml` (both required).
   - Add `generated-in-activation: {{ACTIVATION_ID}}` to
     `templates/manual-test-plan.md.tmpl` and
     `templates/manual-test-results.md.tmpl`.
3. **Update `scripts/blueprints.sh`** path resolvers + plan rotate +
   the new `manual-test-results-rotate-only` subcommand (§4.1).
4. **Update `scripts/bundle.sh`** path constants + scrub regex.
5. **Create `scripts/migrate-test-folder.sh`** (§2.1, §5.1) and run it
   once against the live data root to move any in-flight
   `implementation/manual-test-*` to `test/`.
6. **Update commands** in this order — failures at any step before the
   doc updates fail safely because the helpers already point at the new
   path:
   - `mo-manual-test-plan.md` — literal paths + activation-id
     backfill at top of Step 1 + Step 1 §4.1 auto-rotation
     (state-agnostic, activation-id guard) + Step 1.5 §4.2 freshness
     gate (the gate MUST go at Step 1.5, not Step 3; see §4.2 for
     why — Step 3 would never fire on the `--from-resume` reuse
     path) + Step 5 render populates `{{ACTIVATION_ID}}` from
     `progress.sh get activation-id`.
   - `mo-manual-test-run.md` — literal paths + §4.1 Branch A
     pre-normalization fallback (state-agnostic, activation-id
     guard) + Step 1 results-render copies
     `generated-in-activation` from the plan's value, not from
     `progress.md`.
   - `mo-complete-workflow.md` (Step 5 archive loop — most important).
   - `mo-abort-workflow.md` (Step 4 rm list).
   - `mo-continue.md` — every literal path under §2.2's audit gate.
   - `mo-review.md`.
7. **Audit gate** — run `rg "implementation/manual-test-(plan|results)"`
   across `commands/`, `scripts/`, `schemas/`, `templates/`, `docs/`.
   Every remaining hit must be a deliberate archived-history reference
   (`blueprints/history/v[N]/implementation/...`). Block on any other
   hit before continuing.
8. **Update schema title strings** (`manual-test-plan.schema.yaml`,
   `manual-test-results.schema.yaml`, `progress.schema.yaml`
   `manual-test-state` description).
9. **Update docs** — `workflow-spec.md` (trees + prose; also document
   the new `active.activation-id` field in the active-block section),
   `manual-testing/plan.md`, `bundle/plan.md`, `project-report.md`.
10. **Doctor extension** — add a `progress.schema.yaml` check for
    `activation-id` to `scripts/doctor.sh` (mirrors the existing
    `manual-test-state` / `manual-test-failure-policy` checks).
11. **Run `/mo-doctor`** — confirm no checks regressed. Run a manual
    end-to-end pass: generate plan, run a scenario, complete workflow,
    verify `test/` survives; then start a second cycle on the same
    feature and confirm §4.1 auto-rotates the prior results and §4.2
    prompts on stale plan frontmatter. Then exercise the
    abort-retry-without-new-commits path explicitly (the case the
    base-commit guard missed): start a run, pause it, abort, retry
    without making any commits, and confirm the prior results still
    auto-rotate on the retry's `/mo-manual-test-plan`.

## 8. Verification

- After `/mo-complete-workflow` on a feature with a completed manual
  test, confirm:
  - `workflow-stream/<feature>/test/manual-test-plan.md` exists.
  - `workflow-stream/<feature>/test/manual-test-results.md` exists.
  - `workflow-stream/<feature>/blueprints/history/v[N+1]/implementation/`
    does **NOT** contain `manual-test-plan.md` or `manual-test-results.md`
    or `manual-test-plan.history/`.
  - `workflow-stream/<feature>/blueprints/history/v[N+1]/implementation/`
    DOES contain the other archived artifacts
    (`overseer-review.md`, `change-summary.md`, `grounding-report.md`,
    `review-context.md`, `diagrams/`).
- After `/mo-abort-workflow` on a feature with manual-test artifacts,
  confirm `test/` survives intact.
- After a fresh `/mo-manual-test-plan` against a feature whose `test/`
  folder carries a prior cycle's plan, confirm the "existing plan"
  prompt branches fire correctly and that `--force` rotates into
  `test/manual-test-plan.history/<timestamp>/`.
- `/mo-export-bundle` against a feature with a `test/` folder emits the
  `## Tests run / manual checks` section, and the body-scrub strips
  the new `test/` paths to `<an internal record>`.
- **Cross-cycle §4.1 verification (state: complete).** After cycle N
  completes (results file at `state: complete` survives in `test/`),
  start cycle N+1 on the same feature and reach stage 5:
  - `/mo-manual-test-plan` (any invocation) auto-rotates the prior
    `manual-test-results.md` into
    `test/manual-test-results.history/<timestamp>/manual-test-results.md`
    and prints the `^info:` line.
  - The fresh `/mo-manual-test-run` Branch A no longer hits the
    `state: complete` refusal.
- **Cross-cycle §4.1 verification (state: in-progress).** Pause cycle
  N mid-run (results file at `state: in-progress` with a non-null
  `current-scenario` cursor), then `/mo-abort-workflow` to end cycle
  N without finalizing. Start cycle N+1 on the same feature:
  - `active.base-commit` for cycle N+1 differs from
    `plan.generated-from-base-commit`.
  - `/mo-manual-test-plan` (any invocation) auto-rotates the prior
    in-progress results, NOT just complete ones.
  - The fresh `/mo-manual-test-run` Branch A does NOT silently resume
    from the stale cursor.
- **Same-activation protection verification.** Within a single
  activation (same `active.activation-id`):
  - Pause mid-run, then re-enter via `/mo-continue` →
    `/mo-manual-test-run` MUST resume from the cursor (no rotation).
  - Finalize a run (`state: complete`), then re-enter → `--seed-only`
    refusal MUST fire (no rotation).
  - Both cases verify the activation-id clause correctly protects
    same-activation state.
- **Abort-retry-without-new-commits verification (the case the
  base-commit guard missed — §4.1 "Why not base-commit?").** Without
  making any commits between cycles:
  - Start cycle N, generate a manual-test plan, run scenarios so
    `manual-test-results.md` exists (either `state: in-progress`
    after a pause or `state: complete` after finalization).
  - `/mo-abort-workflow` — retry mode (no `--drop-feature` flag) so
    `active.feature` is preserved and stage resets to 2.
  - **Do not make any new commits.** Re-enter the workflow via
    `/mo-continue` → `/mo-plan-implementation` etc. so cycle N+1
    activates at the same git HEAD.
  - Confirm `active.activation-id` was re-minted (compare to the
    previous value captured before abort).
  - Confirm `active.base-commit` is unchanged (this is the case the
    earlier base-commit guard would have missed).
  - Run `/mo-manual-test-plan` (any invocation form). The §4.1 Step
    1 rotation MUST fire because activation-id differs, even though
    base-commit matches. The prior `manual-test-results.md` is
    moved into `test/manual-test-results.history/<timestamp>/`.
  - Run `/mo-manual-test-run`. Branch A MUST treat the results file
    as absent (rendering a fresh one from template) rather than
    resuming the stale cursor or hitting the `state: complete`
    refusal.
- **In-flight cycle backward-compatibility verification.** For a
  feature whose `progress.md.active` was created before this change
  ships (no `activation-id` field):
  - First `/mo-manual-test-plan` invocation triggers the §4.3
    backfill at top of Step 1; `progress.sh get activation-id`
    returns a value afterward.
  - Subsequent invocations preserve that value (immutability).
  - The new plan rendered under the backfilled activation-id behaves
    identically to one rendered under a fresh activate-time
    activation-id.
- **Cross-cycle §4.2 verification.** With a surviving plan from cycle
  N whose `requirements-id` / `generated-from-base-commit` no longer
  match cycle N+1:
  - Direct `/mo-manual-test-plan` (no `--from-resume`, no `--force`)
    prompts on mismatch with `y/n/c` options.
  - `/mo-continue`'s Resume Step 7 auto-firing `/mo-manual-test-plan --from-resume`
    also surfaces the mismatch prompt (because §4.2 explicitly does
    NOT suppress it under `--from-resume`).
  - `--force` skips the prompt and regenerates as today.
  - When `requirements-id` and `base-commit` both match (e.g., the
    plan was regenerated mid-cycle), no prompt fires.
