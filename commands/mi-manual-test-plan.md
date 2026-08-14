---
description: Generate a manual test plan for the active feature and offer to execute it. Stage-5 sub-flow — runs before findings authoring.
argument-hint: "[--from-resume] [--force [--new-seed-family]] [--discard-existing]"
---

# mi-manual-test-plan

**Runtime bootstrap.** Every `$CLAUDE_PLUGIN_ROOT` reference in this command's Bash blocks assumes a resolved plugin root; Claude Code does not inject the env var into Bash subshells. If it is empty in your shell, apply the canonical resolver (`docs/millwright-inspector-project.md` §8.14; reference implementation: `mi-continue.md` Step 1a) before the first Bash block: (1) inherited env var when it points at a working install, (2) `$PWD` when it is this plugin's source repo, (3) the `installPath` from `~/.claude/plugins/installed_plugins.json` — then export it, persist it to the per-cwd tempfile, and prepend the recovery one-liner to every subsequent Bash block. Refuse with an environmental diagnostic if none resolve.

Stage-5 manual-test plan generator. Reads the active feature's blueprint + change-summary + a codebase scan, renders `workflow-stream/<feature>/test/manual-test-plan.md`, then offers to start the per-scenario run via `/mi-manual-test-run`. The plan is one of the most important artifacts in the workflow — Step 5's depth & coverage bar is mandatory: enumerate every scenario the implementation surface supports (happy paths, edge cases, error paths, idempotency, regression seams, non-goal boundaries), not a happy-path sketch. Auto-fired by `/mi-continue`'s Resume Step 7 when the inspector answers `y` to the stage-5 hand-off prompt; also invocable directly during stage 5 if the inspector wants to (re)generate.

The plan + results files live under a feature-permanent `test/` folder — they survive `/mi-complete-workflow` and `/mi-abort-workflow` so the next cycle on the same feature can reuse them. See `docs/manual-testing-folder/plan.md` for the lifecycle.

The manual-test phase is a **sub-flow on stage 5** (sub-flow value `manual-testing`), not a new stage number — see `docs/manual-testing/plan.md` § 1 for the rationale.

## Invocation

```
/mi-manual-test-plan [--from-resume] [--force [--new-seed-family]] [--discard-existing]
```

- `--from-resume` — passed by `/mi-continue`'s Resume Step 7 on auto-fire. Suppresses the duplicate no-existing-plan generation prompt (the inspector already answered `y` to the stage-5 hand-off prompt). If a plan already exists and `--force` was not also passed, the flag uses that plan unchanged and jumps to the "perform now?" prompt — never silently rotates.
- `--force` — explicit override for re-running from a terminal `manual-test-state` (`complete` or `skipped`). Bypasses the existing-plan regeneration prompt and rotates plan/results. The `manual-test-state` reset to `none` happens AFTER all read-only gates pass (existing-plan probe, RUN_ROOT resolution, change-summary freshness) so a refusal from any of those leaves `progress.md` byte-identical even when `--force` was passed.
- `--new-seed-family` — only meaningful with `--force`. By default `--force` preserves the prior plan's `seed-family-id` so re-run failures upsert into the same seeded IR family. Pass `--new-seed-family` to abandon prior seed history and start a fresh family (prior IRs become invisible to the new run's seed lookup).
- `--discard-existing` — explicit destructive-intent path. When the file exists, rotates the existing plan/results into history and marks the phase `skipped` without re-rendering. With no existing plan, behaves like a normal direct `n`.

## Preconditions

Flags are parsed first; `manual-test-state` requirements then dispatch on flag.

| Invocation                                                    | Requirements                                                                                                                                                                          |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Common (every invocation)                                     | `progress.sh get-active` non-null. `progress.sh get current-stage == 5`. `progress.sh get sub-flow == none`.                                                                          |
| Normal (no `--force`, no `--discard-existing`)                | `manual-test-state == none`. Refuse on `complete` or `skipped` with: "Manual test already terminal (state=`<X>`). Re-run with `/mi-manual-test-plan --force` to start over."          |
| `--force` (with or without `--from-resume` / `--new-seed-family`) | `manual-test-state ∈ {none, complete, skipped}` is acceptable at entry. The skill resets `manual-test-state=none manual-test-failure-policy=none` later (step 3.5) — only AFTER all read-only gates pass. |
| `--discard-existing`                                          | `manual-test-state == none`. Same precondition envelope as normal invocation; the flag changes step 1's behavior, not the precondition envelope.                                       |

Implementation note: parse flags before evaluating `manual-test-state`. An implementation that hard-rejects on `manual-test-state != none` *before* checking for `--force` will never reach the override path.

## Execution

The flow is ordered so that **every read-only gate fires before the first `progress.md` mutation**. Steps 1–3 are read-only (existing-plan probe, §4.1 results auto-rotation, §4.2 freshness gate, prompt branching, RUN_ROOT resolution, change-summary freshness gate). The first step that mutates `progress.md` is step 3.5, gated on `--force`; everything earlier either writes to `progress.md` only on a clean stop (`--discard-existing` and direct `n` paths in step 2) or doesn't write at all. This is what makes "stale change-summary refuses with `progress.md` unchanged" hold even when `--force` was passed.

The §4.1 auto-rotation is a **filesystem mutation** but not a `progress.md` mutation — it moves a stale `manual-test-results.md` into `test/manual-test-results.history/<timestamp>/` so the gate-ordering contract is preserved: every gate that aborts ends with `progress.md` byte-identical.

### Step 1 — Resolve any existing plan + cross-cycle results auto-rotation

**Mode detection (ordinary vs. feature-test), runs first.** Auto-detected rather than flag-driven so it cannot be forgotten by a caller:

```bash
if $CLAUDE_PLUGIN_ROOT/scripts/todo.sh is-feature-test "$active_feature"; then
  ft_mode=1
else
  ft_mode=0
fi
```

**An ordinary feature never matches**, so every branch below that is not explicitly gated on `ft_mode=1` runs exactly as it did before the feature-test path existed — this generator's single-feature behaviour, and the schema its output validates against, are unchanged.

**Step 1.0 — Activation-id backfill (one-shot for in-flight cycles).**
Cycles activated before `progress.md.active.activation-id` was introduced
have a missing field. Read it; if missing, mint and store one. The
`set` helper allows the missing → set transition exactly once (see
`docs/manual-testing-folder/plan.md` § 4.3 "compatibility").

```bash
activation_id="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get activation-id 2>/dev/null || echo "")"
if [[ -z "$activation_id" || "$activation_id" == "null" ]]; then
  activation_id="$($CLAUDE_PLUGIN_ROOT/scripts/uuid.sh)"
  $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set activation-id="$activation_id"
fi
```

**Step 1.1 — Existing-plan probe.**
Check `workflow-stream/<feature>/test/manual-test-plan.md`:

```bash
plan_path="$($CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh manual-test-plan-path "$active_feature")"
preserved_seed_family_id=""
if [[ -f "$plan_path" ]]; then
  if [[ -z "${flag_new_seed_family:-}" ]]; then
    preserved_seed_family_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$plan_path" seed-family-id)"
  fi
fi
```

This read happens before any y/n prompt so the skill never marks the phase `skipped` while silently leaving an old plan file behind.

**Step 1.2 — Cross-cycle results auto-rotation (§4.1).**
The `test/` folder is feature-permanent now — completion no longer
archives it. If a prior activation's `manual-test-results.md` survived
into this activation, the runner's `state: complete` refusal (or
`state: in-progress` paused-resume path) would silently misroute. Auto-rotate
on the triple-AND prior-activation guard:

```bash
results_path="$($CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh manual-test-results-path "$active_feature")"
if [[ -f "$plan_path" && -f "$results_path" ]]; then
  plan_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$plan_path" id)"
  results_plan_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$results_path" plan-id)"
  results_activation="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$results_path" generated-in-activation 2>/dev/null || echo "")"
  # Triple-AND guard: results match the plan AND belong to a prior activation.
  # Missing generated-in-activation on the results file counts as non-matching
  # (in-flight cycles without the field cannot be proven to belong to this
  # activation — rotate is the safe default).
  if [[ "$results_plan_id" == "$plan_id" \
        && ( -z "$results_activation" || "$results_activation" != "$activation_id" ) ]]; then
    $CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh manual-test-results-rotate-only "$active_feature" >&2
  fi
fi
```

The guard is **state-agnostic** — both `state: complete` and
`state: in-progress` are rotated when activation differs, because both
can leak across activations under the new permanence model
(`/mi-abort-workflow` no longer deletes the test/ folder; see §4.1
of the plan).

**Step 1.3 — `--discard-existing` shortcut.**
If `--discard-existing` was passed AND the plan file exists:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh manual-test-plan-rotate "$active_feature"
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh set manual-test-state=skipped manual-test-failure-policy=none
echo "Existing manual-test plan discarded; manual-test phase marked skipped. Write findings into inspector-review.md and type /mi-continue when done."
exit 0
```

If `--discard-existing` was passed with no existing plan, treat it like a normal direct `n` below (mark phase skipped without rotating anything).

### Step 1.5 — Plan-freshness gate (cross-activation, read-only)

If `plan_path` does NOT exist, skip this step entirely (nothing to be stale about). Otherwise compute the freshness mismatch on `generated-from-base-commit` AND the requirements reference. For an ordinary feature (`ft_mode=0`) that reference is the singular `requirements-id`, unchanged from before. **When `ft_mode=1` the entry has no `requirements.md` of its own; the plan instead carries `requirements-ids`** (plural) — one id per finished ordinary feature. Staleness for a feature-test entry means **the cycle's finished set changed** since the plan was written, so the gate compares the id LIST, not a single id — a feature finishing (or being rebased out) after the plan was rendered has to flip `mismatch`.

**Normalize before comparing.** `frontmatter.sh get` is a thin `yq eval` wrapper, and `yq` preserves whichever YAML style the array was written in: flow style (`[aaa, bbb]`) collapses onto one line, block style (`- aaa` / `- bbb`) spans one line per element with a `- ` bullet. `plan_req_ids` is read straight off `plan_path`'s frontmatter (whichever style it happens to be in) while `current_req_ids` is assembled bare-id-per-line from separate `frontmatter.sh get ... id` calls — comparing the two raw strings can never match even when the sets are identical. Pipe **both** sides through the same normalizer — strip `[`, `]`, and `"`, split on commas, strip a leading `- ` block-bullet and surrounding whitespace, drop blank lines, then sort — so flow style, block style, and a single-element list all reduce to the same shape:

```bash
if [[ "${ft_mode:-0}" == "1" ]]; then
  norm() { tr -d '[]"' | tr ',' '\n' | sed -e 's/^- //' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' | sort; }

  plan_req_ids="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$plan_path" requirements-ids | norm)"
  plan_base_commit="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$plan_path" generated-from-base-commit)"
  current_base_commit="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get base-commit)"

  # feature-test-range refuses (exit 3/4/5) when a finished feature's head is
  # unreachable, nothing contributed commits, or bases diverged. This is a
  # plain command substitution (no pipe to `head`), so its exit status
  # reaches `if !` directly — same shape as Step 1.4 of
  # mi-generate-implementation-diagrams.md and review.sh's own feature-test
  # `init` branch. commits.sh's own stderr diagnostic is not redirected, so
  # it reaches the inspector directly; stop here rather than continuing with
  # an empty id list.
  if ! ft_range_out="$($CLAUDE_PLUGIN_ROOT/scripts/commits.sh feature-test-range "$active_feature")"; then
    exit 1
  fi

  # Build the id list via a PLAIN (unpiped) while loop, not `while ... | sort`.
  # A pipe forks the while loop into its own subshell, and without `pipefail`
  # (not set here) the pipeline's reported exit status is the LAST stage's
  # (`sort`'s, always 0) — an `exit 1` fired inside a piped loop would be
  # silently swallowed, exactly the class of bug the `head -1` guard above
  # exists to avoid. Using `<<<` with no trailing pipe keeps the loop in the
  # current shell, so `exit 1` genuinely terminates the whole command.
  current_ids=()
  while IFS=$'\t' read -r row_kind row_feat _row_base _row_head; do
    [[ "$row_kind" == "contributor" ]] || continue
    hist="$data_root/workflow-stream/$row_feat/blueprints/history"
    # Portable newest-version resolution — macOS/BSD sed has no `\+` in BRE
    # mode, so this loops instead of a one-line sed capture. Same pattern
    # Task 8 uses at mi-generate-implementation-diagrams.md Step 2.1 and
    # review.sh's own feature-test `init` branch — reused, not a third
    # variant.
    latest_v=0
    for d in "$hist"/v[0-9]*; do
      [[ -d "$d" ]] || continue
      v="${d##*/v}"
      [[ "$v" =~ ^[0-9]+$ ]] || continue
      (( v > latest_v )) && latest_v="$v"
    done
    # Hard-fail on an invariant violation — same shape as review.sh:107-109
    # and Task 8's Step 2.1. A corrupted or missing archived blueprint must
    # refuse loudly, never quietly shrink the comparison set: silently
    # dropping a contributor here would make this gate blind to exactly the
    # drift it exists to catch.
    if [[ "$latest_v" -eq 0 ]]; then
      echo "error: no archived requirements.md found for contributor $row_feat" >&2
      exit 1
    fi
    req_file="$hist/v$latest_v/requirements.md"
    if [[ ! -f "$req_file" ]]; then
      echo "error: $req_file not found for contributor $row_feat" >&2
      exit 1
    fi
    current_ids+=("$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$req_file" id)")
  done <<< "$ft_range_out"
  if [[ ${#current_ids[@]} -eq 0 ]]; then
    echo "error: feature-test-range reported no contributors for $active_feature" >&2
    exit 1
  fi
  current_req_ids="$(printf '%s\n' "${current_ids[@]}" | norm)"

  mismatch=0
  if [[ "$plan_req_ids" != "$current_req_ids" || "$plan_base_commit" != "$current_base_commit" ]]; then
    mismatch=1
  fi
else
  plan_req_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$plan_path" requirements-id)"
  plan_base_commit="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$plan_path" generated-from-base-commit)"
  req_path="$data_root/workflow-stream/$active_feature/blueprints/current/requirements.md"
  current_req_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$req_path" id)"
  current_base_commit="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get base-commit)"

  mismatch=0
  if [[ "$plan_req_id" != "$current_req_id" || "$plan_base_commit" != "$current_base_commit" ]]; then
    mismatch=1
  fi
fi
```

The `else` branch above is the pre-existing ordinary-feature computation, unedited — the `ft_mode=1` branch is new and is checked first, per the global constraint that a feature-test entry must never read `blueprints/current/` for its own folder (it has none).

Branch on `(--from-resume, --force, mismatch)`:

- **`--force` set:** no prompt — `--force` already signals regeneration. Set `freshness_forced_regen=false` (the regen is driven by `--force`, not by this gate). Continue to Step 2.
- **No `--force`, no mismatch:** no prompt. Set `freshness_forced_regen=false`. Continue to Step 2.
- **No `--force`, mismatch detected (with OR without `--from-resume`):**

  Prompt (`ft_mode=0`): `"Existing manual-test plan was generated against requirements <plan_req_id> / base-commit <plan_base_commit>; current cycle is <current_req_id> / <current_base_commit>. Regenerate? (y to rotate + regenerate, n to use the stale plan anyway, c to cancel.)"`

  Prompt (`ft_mode=1`): `"Existing manual-test plan was generated against requirements <plan_req_ids, comma-joined> / base-commit <plan_base_commit>; the cycle's finished set is now <current_req_ids, comma-joined> / <current_base_commit>. Regenerate? (y to rotate + regenerate, n to use the stale plan anyway, c to cancel.)"` `plan_req_ids` and `current_req_ids` are newline-separated after `norm`; join with `, ` for display so the inspector sees which ids actually changed instead of a blank interpolation.

  Default to `c` on Ctrl-D (both prompts).

  - On `y`: set `freshness_forced_regen=true` (downstream branches treat as if `--force` had been passed — Steps 3.5, 4, 5, 6 run; no extra Step 2 prompt for the same regenerate decision).
  - On `n`: set `freshness_forced_regen=false`. Fall through to Step 2 unchanged; the user-typed `n` here is them explicitly opting into the stale plan.
  - On `c`: exit 0 with `progress.md` byte-identical. (No filesystem rotation either — the gate is read-only against the plan.)

This gate is placed at Step 1.5 (not Step 3) because Step 2's "Existing plan present, `--from-resume` without `--force`" branch (below) jumps directly to Step 7, bypassing Steps 3–6. A gate placed at Step 3 would never fire on that branch — the very path most likely to encounter a stale plan from a prior activation. See `docs/manual-testing-folder/plan.md` § 4.2 for the full rationale.

### Step 2 — Prompt the inspector (y/n)

The prompt fires only when invoked directly by the inspector and only for a decision that has not already been made. `--from-resume` (auto-fired by `/mi-continue`'s Resume Step 7) suppresses the duplicate **no-existing-plan** generation prompt because the inspector already answered `y` to that same question.

Branch on `(plan_exists, --from-resume, --force)`:

- **No existing plan, no `--from-resume`:**

  Prompt: `"Generate manual-test-plan.md for <feature> before findings review? (Recommended for UI / integration changes; skippable for backend-only changes you're confident about.) y/n"`

  - On `n`: `progress.sh set manual-test-state=skipped manual-test-failure-policy=none`. Print `"Skipped. Write findings into inspector-review.md and type /mi-continue when done."` Stop.
  - On `y`: continue to step 3.

- **No existing plan, `--from-resume`:** treat as if `y` was answered. Continue to step 3.

- **Existing plan present, no `--force`, direct invocation:**

  Prompt: `"Existing manual-test-plan.md found for <feature>. Regenerate it? (y to rotate and regenerate, n to leave it in place.)"`

  - On `n`: do **not** set `manual-test-state=skipped`; print `"Existing plan left in place. Run /mi-manual-test-run when ready, or write findings into inspector-review.md and type /mi-continue to proceed without running it."` Stop with state unchanged.
  - On `y`: continue to step 3 (regeneration).

- **Existing plan present, `--from-resume` without `--force`, no `freshness_forced_regen`:** do **not** prompt and do **not** rotate/regenerate silently. Print `"Existing manual-test plan found; using it unchanged."` Skip steps 3–6 and jump to step 7's "perform now?" prompt. The stage-5 hand-off answer means "make a plan available," not "destroy and replace an existing plan without asking."

- **Existing plan present, `--from-resume` without `--force`, `freshness_forced_regen=true`:** the Step 1.5 gate already asked the regenerate decision and the inspector answered `y`. Do not re-prompt; continue to Step 3 (regeneration path).

- **Existing plan present, `--force` (with or without `--from-resume`), or `freshness_forced_regen=true`:** explicit regeneration signal — either an inspector-typed `--force` or a Step 1.5 `y` answer. Continue to Step 3 without prompting.

### Step 3 — Resolve RUN_ROOT and read inputs (read-only gates)

**Resolve RUN_ROOT** from the active block. `progress.sh get <field>` already reads from `.active.<field>` internally — do not write `active.worktree-path`:

```bash
RUN_ROOT="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get worktree-path)"
if [[ -z "$RUN_ROOT" || "$RUN_ROOT" == "null" ]]; then
  RUN_ROOT="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get git-worktree-dir)"
fi
[[ -n "$RUN_ROOT" && "$RUN_ROOT" != "null" ]] || {
  echo "error: cannot resolve worktree path from progress.md active block" >&2
  exit 1
}
```

All codebase search performed during plan generation runs from `RUN_ROOT`.

**Change-summary freshness gate.** `commits.sh change-summary-fresh` is a check, NOT a regenerator — exit 0 = fresh cache hit, exit 1 = stale, exit 2 = missing. Refuse with a recovery diagnostic if the summary isn't fresh:

```bash
if ! $CLAUDE_PLUGIN_ROOT/scripts/commits.sh change-summary-fresh "$active_feature"; then
  rc=$?
  case "$rc" in
    1) echo "error: change-summary.md is stale for $active_feature; run /mi-draw-diagrams (or /mi-generate-implementation-diagrams) to regenerate, then re-run /mi-manual-test-plan." >&2 ;;
    2) echo "error: change-summary.md is missing for $active_feature; run /mi-draw-diagrams (or /mi-generate-implementation-diagrams) to regenerate, then re-run /mi-manual-test-plan." >&2 ;;
    *) echo "error: commits.sh change-summary-fresh exited $rc" >&2 ;;
  esac
  exit 1
fi
```

No mutation on refusal — `manual-test-state` is unchanged, no plan rotation.

**Feature-test input substitutions (`ft_mode=1`).** The entry owns no blueprint; it borrows from the finished features' archived `blueprints/history/v[N]/` instead of `blueprints/current/`:

| Ordinary input | Feature-test substitute |
| --- | --- |
| `blueprints/current/requirements.md` | each finished feature's `history/v[N]/requirements.md` (newest archived version) |
| `blueprints/current/config.md` | the **union** of the finished features' `history/v[N]/config.md` — merge Prerequisites, services, and env vars, de-duplicated |
| `implementation/change-summary.md` | the entry's own, over the union range |

The change-summary freshness gate, RUN_ROOT resolution, and the §4.1 results auto-rotation all work unchanged for `ft_mode=1`, because `base-commit` is already the union base (pinned by `/mi-continue`'s feature-test sequence at the `advance-to 2 5` transition).

**Read inputs (`ft_mode=0`; see the substitution table above for `ft_mode=1`):**

- `workflow-stream/<feature>/blueprints/current/requirements.md` — goals, planned, non-goals.
- `workflow-stream/<feature>/blueprints/current/config.md` — services, env vars, runtime topology.
- `workflow-stream/<feature>/implementation/change-summary.md` — files touched, areas affected (gated fresh by the check above). (Lives under `implementation/`, not `test/` — `change-summary.md` is a stage-4 artifact that gets archived at stage 8.)
- `quest/<active-slug>/summary.md` — feature scope (cycle-scoped — read for cross-cutting context only).

**Codebase search (run from RUN_ROOT):** grep the changed paths from `change-summary.md` for env-var references, docker-compose service names, GraphQL operations / REST routes, error-code constants, UI route paths. These ground the Prerequisites and Test scenarios sections in real symbols, not invented ones.

This is the last read-only step. Any refusal up to this point — invalid existing-plan frontmatter, declined regeneration, RUN_ROOT unresolvable, stale/missing change-summary — leaves `progress.md` byte-identical.

### Step 3.5 — Force-state reset (only when `--force` or `freshness_forced_regen` is set)

Only when `--force` was passed OR Step 1.5 set `freshness_forced_regen=true`, AND we're proceeding to render:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh set manual-test-state=none manual-test-failure-policy=none manual-test-env-mode=guided
```

Resetting `manual-test-env-mode` alongside `manual-test-state`/`manual-test-failure-policy` keeps a forced regeneration starting from a clean slate — without it, a prior run's `autonomous` would silently govern the next one. Step 7 re-sets the mode explicitly whenever the inspector answers `y` or `y-autonomous`, so this reset only governs the deferred (`n`) path, where it is the mode a later bare `/mi-manual-test-run` will use.

**The reset baseline is `guided`, not `interactive` (v1.6.8).** It has to match what `y` selects: an inspector who regenerates a plan and defers, then types `/mi-manual-test-run` later, gets the same experience they would have gotten by answering `y` on the spot. `interactive` remains the reading of a *missing* `manual-test-env-mode` — that is a compatibility rule for cycles that predate the field, not a default anyone chose.

This is the FIRST `progress.md` mutation in the regeneration branch. It runs AFTER all read-only gates above so any earlier refusal aborts cleanly without changing state. Skip this step entirely on non-`--force` invocations that didn't trigger the freshness regen. The prior `manual-test-results.md` is rotated alongside the plan in step 4; this step only touches `progress.md`.

### Step 4 — Rotate any existing plan into history

If an existing plan was found and we're regenerating (direct `y`, `--force`, `freshness_forced_regen=true`, or `--discard-existing`):

```bash
$CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh manual-test-plan-rotate "$active_feature"
```

The `seed-family-id` to preserve was already captured in step 1. Preserving `seed-family-id` is required so forced re-runs can still find prior auto-seeded IR families even though the per-render plan `id` changes.

### Step 5 — Render the plan

Render `workflow-stream/<feature>/test/manual-test-plan.md` from `templates/manual-test-plan.md.tmpl`. Generate a fresh plan `id` (UUIDv4) every time, but reuse `preserved_seed_family_id` from step 1 when present; otherwise create a new UUIDv4 `seed-family-id`. Populate `{{ACTIVATION_ID}}` with the value from `progress.sh get activation-id` (already backfilled in Step 1.0 for in-flight cycles).

**Resolve the requirements reference.** The template's frontmatter carries `{{REQUIREMENTS_FIELD}}` — a bare placeholder, not `requirements-id: {{REQUIREMENTS_ID}}` — the same `REQUIREMENTS_FIELD` + `!RAW!` sentinel shape `change-summary.md.tmpl` and `inspector-review.md.tmpl` already use (converted by Tasks 6 and 8). Resolve the value before rendering:

```bash
if [[ "${ft_mode:-0}" == "1" ]]; then
  # Resolve req_ids exactly as review.sh's feature-test `init` branch does
  # (scripts/review.sh:94-114) — reused, not a fourth variant. Same
  # plain-(unpiped)-while-loop shape as Step 1.5 above, for the same reason:
  # a hard `exit 1` inside a piped loop is swallowed by the pipeline's own
  # (always-0) exit status unless pipefail is set, which it isn't here.
  if ! ft_range_out="$($CLAUDE_PLUGIN_ROOT/scripts/commits.sh feature-test-range "$active_feature")"; then
    exit 1
  fi
  req_ids=()
  while IFS=$'\t' read -r row_kind row_feat _row_base _row_head; do
    [[ "$row_kind" == "contributor" ]] || continue
    hist="$data_root/workflow-stream/$row_feat/blueprints/history"
    latest_v=0
    for d in "$hist"/v[0-9]*; do
      [[ -d "$d" ]] || continue
      v="${d##*/v}"
      [[ "$v" =~ ^[0-9]+$ ]] || continue
      (( v > latest_v )) && latest_v="$v"
    done
    # Hard-fail on an invariant violation — same shape as review.sh:107-109.
    # A corrupted or missing archived blueprint refuses loudly rather than
    # rendering a plan silently framed against fewer requirements than the
    # cycle actually finished.
    if [[ "$latest_v" -eq 0 ]]; then
      echo "error: no archived requirements.md found for contributor $row_feat" >&2
      exit 1
    fi
    req_file="$hist/v$latest_v/requirements.md"
    if [[ ! -f "$req_file" ]]; then
      echo "error: $req_file not found for contributor $row_feat" >&2
      exit 1
    fi
    req_ids+=("$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$req_file" id)")
  done <<< "$ft_range_out"
  if [[ ${#req_ids[@]} -eq 0 ]]; then
    echo "error: feature-test-range reported no contributors for $active_feature" >&2
    exit 1
  fi
  ids_csv="$(IFS=,; echo "${req_ids[*]}")"
  requirements_field="!RAW!requirements-ids: [$ids_csv]"
else
  requirements_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$data_root/workflow-stream/$active_feature/blueprints/current/requirements.md" id)"
  requirements_field="!RAW!requirements-id: $requirements_id"
fi
```

Pass `REQUIREMENTS_FIELD=$requirements_field` to `frontmatter.sh init manual-test-plan` alongside the other substitutions. The `ft_mode=0` branch renders the exact `requirements-id: <uuid>` line it always has — confirmed by rendering the template before and after this conversion with the same inputs and diffing (see the task report); the ordinary output is byte-identical. When Step 1.5 already ran this same resolution for the `ft_mode=1` regeneration path (an existing plan was present), its `current_ids`/`ids_csv` may be reused here instead of recomputing; on the first-ever render for an entry, Step 1.5 was skipped (no `plan_path` yet) so this is the only place the resolution happens.

The body has four top-level sections:

- `## 1. Prerequisites` — services to run, env vars, install/bootstrap, seed data. Filled from blueprint config.md + change-summary grep results.
- `## 2. What to run` — per-terminal command set. **Every command line MUST be self-contained** — copy-pasteable into the inspector's terminal without preceding setup. Acceptable shapes (pick one per section, do not mix):
  1. **Absolute-path inline (preferred):** the resolved `RUN_ROOT` is interpolated into every command, shell-quoted. Example: `cd "/abs/path/to/.worktree" && pnpm dev`.
  2. **Preamble export:** the section starts with a single `export RUN_ROOT="/abs/path/to/.worktree"` line; subsequent commands use `cd "$RUN_ROOT" && <cmd>`.

  Bare `cd "$RUN_ROOT" && ...` without the export preamble in the same section is invalid (the variable would be undefined in the inspector's shell). When a specific command must instead run from the main checkout (e.g., a docker-compose stack pinned there), emit `cd "/abs/main/checkout"  # reason: <why>` for that one command. Generic "run from repo root" without an explicit `cd` is not allowed — every command line states its working directory.

  Set the `generated-against-run-root` frontmatter field to the resolved absolute `RUN_ROOT` so the runner can detect worktree drift at run time.

- `## 3. Test scenarios` — grouped by Scenario letter (A, B, C, …), numbered within (`A.1, A.2, B.1, …`). This is the most consequential section of the plan — generate it against the depth & coverage bar below, not as a happy-path sketch.
- `## 4. Coverage notes` — waived coverage-matrix cells, one line each with the reason (see the bar below). An empty section asserts full matrix coverage. Kept OUTSIDE § 3 so scenario-block parsers never mistake it for a scenario.

**Feature-test derivation (`ft_mode=1`).** This governs the whole Step 5 render — § 2's command portability and § 3's merge anchor included, not only the coverage bar below. Scenarios are derived, never transcribed — the entry's todo item says only "test the whole feature implementation".

Inputs, in priority order:

1. `todo.sh list IMPLEMENTED` — everything that actually shipped this cycle, **excluding the feature-test item itself** (its id is field 3 of `todo.sh feature-test-status`).
2. The implementation itself, over the union range. **Where the implementation and the stated intent disagree, the implementation is what gets tested.**

Items the inspector left as `[ ] TODO` were **never built** and are out of scope — a partially-selected cycle produces a plan covering only what shipped.

**Cross-feature scenarios dominate.** Prioritise the seams: one feature's output becoming another's input, shared state, ordering, and interactions no single-feature plan could have covered — cross-feature scenarios dominate this entry's plan by design, because that is the exact coverage gap it exists to close. A scenario that merely re-runs one feature's existing case is the exception and carries a one-line justification, because that case already ran during that feature's own workflow — repeating it wholesale would just reproduce the gap this entry exists to close.

**Portability.** Every command in § 2 must be POSIX/BSD-portable and run on macOS. GNU-only flags (`cat -A`, `grep -P`, `sed -i` with no argument) are defects in the plan even when the underlying code is correct.

**Merge anchor for `DTI-005`.** End `## 3. Test scenarios` with exactly this line:

```markdown
<!-- deferred-merge-point -->
```

The sibling `deferred-test-items` feature inserts carried-forward scenario groups immediately above it. A stable anchor, independent of scenario lettering, needing no schema change. This feature owns the anchor only — never the merge.

#### Scenario depth & coverage bar (mandatory)

The manual test plan is one of the most important artifacts in the entire workflow: it is the last quality gate before findings authoring, and whatever it fails to cover is simply never exercised — by the inspector or by an autonomous run. Generate § 3 **as detailed and exhaustive as the implementation surface allows**; err on the side of too many scenarios, never too few. A short plan is not a virtue here.

**Coverage matrix — every cell gets ≥1 scenario or an explicit § 4 waiver:**

- **Every Goal** in `requirements.md` `## Goals (this cycle)` — at least one happy-path scenario per goal, plus that goal's failure/error path.
- **Every changed area** in `change-summary.md` `## Changed files` — at least one scenario exercising that area's observable behavior. A changed file with no scenario and no waiver is a coverage hole.
- **Edge + boundary cases** — empty inputs, oversized inputs, invalid formats, boundary values (0, 1, N, N+1), unicode/whitespace where strings are handled.
- **Error and failure paths** — invalid requests, missing/expired auth where applicable, dependency-down behavior (a `config.md` service stopped), malformed payloads, constraint violations. Expected outcomes name the *specific* error surface (status code, error-code constant found by the Step 3 codebase scan, exact UI error state) — never just "an error is shown".
- **State transitions & idempotency** — re-run/refresh/double-submit the same action, resume after interruption, run a scenario twice where the second run's expectation differs (or must not differ).
- **Regression seams** — pre-existing behavior adjacent to the changed code (call sites of changed functions per the codebase scan). At least one scenario per seam verifying old behavior still holds. **Start from the requirements' `**Shipped-code impact:**` bullets** (one per Goals item) and, when it exists, `implementation/grounding-report.md`'s `## Shipped-code regression risks` section — each named consumer/contract that "must keep holding" is a required scenario here, phrased as *the old behavior still works*, with the cheapest observable check the bullet named. An item whose shipped-code impact reads `none — additive only` needs no scenario in this cell; one that reads `unassessed` gets a scenario against its seam's obvious existing consumer plus a `## 4. Coverage notes` line saying the assessment was missing.
- **Non-goals boundaries** — for each `requirements.md` Non-goal bordering the change, one scenario verifying the excluded behavior did NOT change.

**Waivers instead of silent omission:** when a matrix cell genuinely has nothing testable (e.g. a pure-refactor file with no observable behavior), record it in `## 4. Coverage notes` — one line per waived cell with the reason. An unmentioned empty cell is a defect in the plan, not a judgment call.

**Per-scenario depth bar:** every scenario must be executable without reading the source. `Action` steps are numbered and copy-paste concrete (exact commands, URLs, request bodies, UI paths, input values — grounded in the real symbols the Step 3 codebase scan found). `Expected` bullets are concrete observable outcomes (exact response fields/status codes, exact UI text or state, log lines, DB rows) — one bullet per observable, never a vague "it works". Where a trick is needed to trigger the path from the UI, spell it out.

**Autonomous-runnability:** write every scenario so a hands-off run (`/mi-manual-test-run`, autonomous env-mode) can execute it — each `Expected` bullet names WHERE the outcome is observable (HTTP response, log line, DB row, file, DOM state). When a scenario's headline verification is subjective visual judgment, additionally list the objective side-effects that CAN be machine-checked, so an autonomous run verifies those instead of skipping the scenario outright.

**Self-check before writing the file:** after drafting § 3, walk the coverage matrix once more against Goals + changed areas and count scenarios per cell; add scenarios (or § 4 waivers) for every empty cell. Only then render the file. For `ft_mode=1`, this coverage bar is grounded against the feature-test derivation inputs stated above (before "The body has four top-level sections:"), not against a single feature's `requirements.md`.

### Step 6 — Do NOT change `manual-test-state`

`manual-test-state` stays at `none`. The file's existence is the "plan generated" signal; the enum tracks the *run* lifecycle, not the *plan* lifecycle.

### Step 7 — "Perform manual test now?" prompt

Always asked (regardless of `--from-resume`):

Prompt: `"Plan available at workflow-stream/<feature>/test/manual-test-plan.md. Perform the manual test now? Reply y, y-autonomous, or n.

  y             — guided run. I bring the whole local environment up for you (the plan's
                  What-to-run commands from the worktree — services in the background, one-shot
                  bootstrap in the foreground, verified up), then walk you through the plan one
                  test case at a time: what it checks in one or two plain sentences, a concrete
                  example, and exactly what to do. I wait for your `pass` / `fail <what you saw>` /
                  `skip <why>` before moving to the next one, and I'll add anything you ask me to
                  into test/manual-test-results.md as we go.

  y-autonomous  — full hands-off run. The millwright brings the environment up itself, then
                  performs every scenario itself and records each `pass`/`fail`/`skip` verdict
                  WITHOUT asking you to run anything. A scenario it can't verify autonomously
                  (visual-only judgment, a physical device, or no available tool) is recorded
                  `skip` with a reason — never a fabricated pass. If env bring-up fails it stops
                  and hands control back to you. When it finishes I'll offer you a guided re-run.

  n             — defer — you can resume later by typing /mi-manual-test-run, or proceed directly
                  to findings authoring."`

Both `y` and `y-autonomous` bring the environment up for you; they differ in **who judges each scenario**. `y` (guided) keeps every verdict yours — the millwright explains and sets up, you look and decide, and there is a `pause` whenever you want to stop. `y-autonomous` self-determines the verdicts and runs straight through (no `pause`). In BOTH modes the end-of-run auto-seed prompt still asks you before writing any failures into `inspector-review.md`.

If you'd rather start the services yourself, that is still available — type `/mi-manual-test-run --interactive-env` instead of answering `y`.

- On `n`: print `"Deferred. Run /mi-manual-test-run when ready, or write findings into inspector-review.md and type /mi-continue to proceed without manual testing. The plan file stays available."` Stop. State stays `none`.
- On `y`:

  ```bash
  $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set sub-flow=manual-testing manual-test-state=running manual-test-env-mode=guided
  ```

  Then auto-fire `/mi-manual-test-run`.

- On `y-autonomous`:

  ```bash
  $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set sub-flow=manual-testing manual-test-state=running manual-test-env-mode=autonomous
  ```

  Then auto-fire `/mi-manual-test-run`.

`manual-test-env-mode` is set **explicitly on both start paths** (not left to default) so a re-run in a feature cycle whose prior run chose the other mode always reflects the answer just given, never a stale value.

**Why `y` is `guided` and not `interactive`.** The value `interactive` still exists and still means "the inspector brings the services up themselves"; it is simply no longer what `y` selects, because the common case — "run the app for me and then walk me through the tests" — is better served by `guided`. `interactive` stays reachable through `/mi-manual-test-run --interactive-env` and remains the backward-compatible meaning of a missing/null `manual-test-env-mode` on in-flight cycles.

## Notes

- **Manual invocability:** the inspector can type `/mi-manual-test-plan` directly during stage 5. Direct invocation does NOT pass `--from-resume`, so the step 2 y/n prompt fires normally. If no plan exists, answering `n` marks the phase skipped. If a plan already exists, answering `n` is intentionally a no-op that leaves the plan file and state unchanged; use `--discard-existing` for the explicit "delete/rotate this plan and mark the phase skipped" path.
- **`--from-resume` flag.** The flag is mutually compatible with `--force` and `--new-seed-family`; passing all three is well-defined (force a re-run from a terminal state without re-prompting and reset the seed family). Has no effect on step 7's "perform now?" prompt — that's a separate decision (generate/available vs. run).
- **Change-summary regeneration is owned by `/mi-draw-diagrams`** (or `/mi-generate-implementation-diagrams`). This skill only gates on freshness; it never regenerates change-summary itself.
- **Single-owner discipline for auto-seeding:** this skill does NOT touch `inspector-review.md`. Auto-seeding belongs to `/mi-manual-test-run`. See `docs/manual-testing/plan.md` § 2.2 "Auto-seed ownership recap".

See `docs/manual-testing/plan.md` § 2.1 for the full design rationale.
