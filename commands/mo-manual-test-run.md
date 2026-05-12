---
description: Execute the active feature's manual-test-plan.md scenario by scenario, asking the overseer for verdicts. Single owner of manual-test auto-seeding into overseer-review.md.
argument-hint: "[--seed-only [--reclassify | --reopen-all | --as-new-findings [--force-new-regressions]]] | [--finalize-skipped]"
---

# mo-manual-test-run

Stage-5 sub-flow runner. Walks the active feature's `manual-test-plan.md` scenario by scenario, asking the overseer for `pass`, `fail <observation>`, `skip <reason>`, or `pause` per scenario. On loop completion, prompts the overseer to auto-seed failures as canonical `### IR-NNN` blocks in `overseer-review.md` via `review.sh upsert-manual-test-failure`. **This skill is the single owner of manual-test auto-seeding** — `/mo-continue`'s Overseer Handler is read-only against `overseer-review.md` for manual-test results.

## Invocation

```
/mo-manual-test-run                                     # Branch A — normal first-run / paused-resume
/mo-manual-test-run --seed-only [<companion-flags>]     # Branch B — seed-only re-trigger / recovery
/mo-manual-test-run --finalize-skipped                  # Branch C — bulk-skip remaining scenarios + finalize
```

Mode flags are mutually exclusive: `--seed-only` and `--finalize-skipped` together refuse with `"--seed-only and --finalize-skipped are mutually exclusive"` and no mutation.

**Branch B companion flags** (only meaningful with `--seed-only`):

| Flag                                                    | Effect                                                                                                                                                  |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--reclassify`                                          | Re-prompts severity/scope per failed scenario (like `y --classify` in first-time auto-seed) and passes `--reclassify` to each helper call.              |
| `--reopen-all`                                          | Per-scenario family inspection. Closed base → `--reopen`; open base / family-empty → default helper; orphan-family (base missing, regressions exist) → refuse-and-skip per-scenario. |
| `--as-new-findings`                                     | Mirror of `--reopen-all` but with `--new-finding` for closed bases. Open base / family-empty go through default mode. Orphan family extends the existing regression family. |
| `--as-new-findings --force-new-regressions`             | Composes with `--as-new-findings`. For every closed-base re-failure, allocates a fresh `:r<N>` regardless of whether an open regression exists. **Not idempotent.** |

`--reopen-all` and `--as-new-findings` (and the `--force-new-regressions` companion) cannot be combined; runner refuses with diagnostic.

## Dispatch order

Parse flags first, then dispatch to one of three branches. The runner picks exactly one branch and never mixes their flows:

1. Parse flags from `$ARGUMENTS`.
2. If `--seed-only` is present → run **Branch B** (seed-only re-trigger / recovery).
3. Else if `--finalize-skipped` is present → run **Branch C** (bulk-skip + finalize).
4. Else → run **Branch A** (normal first-run / paused-resume).

## Common preconditions (all branches)

- `progress.sh get-active` is non-null.
- `progress.sh get current-stage == 5`. Refuse outside stage 5: `"Manual test belongs to stage 5 (overseer review). Current stage is <N>. Type /mo-resume-workflow to see the next-step recommendation, or wait until the workflow reaches stage 5."`

## Resolve RUN_ROOT (Branches A and B only)

Before any user-facing prompt or scenario render in Branches A and B:

```bash
RUN_ROOT="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get worktree-path)"
[[ -n "$RUN_ROOT" && "$RUN_ROOT" != "null" ]] || \
  RUN_ROOT="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get git-worktree-dir)"
[[ -n "$RUN_ROOT" && "$RUN_ROOT" != "null" ]] || {
  echo "error: cannot resolve worktree path from progress.md active block" >&2
  exit 1
}
```

`progress.sh get` already reads from the active block — do not write `active.worktree-path`. Branch C never executes scenarios or runs commands, so it doesn't need `RUN_ROOT`.

**Worktree-drift guard.** Compare the resolved `RUN_ROOT` to the plan's frontmatter `generated-against-run-root`:

```bash
plan_path="$($CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh manual-test-plan-path "$active_feature")"
[[ -f "$plan_path" ]] || { echo "error: $plan_path not found" >&2; exit 1; }
plan_run_root="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$plan_path" generated-against-run-root)"
if [[ "$plan_run_root" != "$RUN_ROOT" ]]; then
  echo "error: worktree drift — plan generated against $plan_run_root but progress.md active worktree is $RUN_ROOT. Run /mo-manual-test-plan --force to regenerate against the current worktree." >&2
  exit 1
fi
```

## Branch A — normal first-run / paused-resume

### Branch A — preconditions

- Common preconditions above.
- `workflow-stream/<feature>/test/manual-test-plan.md` exists.
- `manual-test-state` ∈ {`none`, `running`} (never run, OR paused mid-run). On `complete` or `skipped`, refuse: `"Manual test already terminal (state=<X>). Re-run with /mo-manual-test-plan --force to start over, or pass --seed-only to re-trigger only the auto-seed loop."`

### Branch A — pre-normalization results-file read

**Step 0 — Cross-activation auto-rotation (§4.1 fallback).** Before any other check, apply the triple-AND prior-activation guard from `docs/manual-testing-folder/plan.md` § 4.1 in case the runner was reached without `/mo-manual-test-plan` having fired first:

```bash
plan_path="$($CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh manual-test-plan-path "$active_feature")"
results_path="$($CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh manual-test-results-path "$active_feature")"
if [[ -f "$plan_path" && -f "$results_path" ]]; then
  plan_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$plan_path" id)"
  results_plan_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$results_path" plan-id)"
  current_activation="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get activation-id 2>/dev/null || echo "")"
  results_activation="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$results_path" generated-in-activation 2>/dev/null || echo "")"
  # State-agnostic guard — both state: complete (prior cycle's
  # finalized run) and state: in-progress (prior cycle's paused or
  # aborted run) are rotated when activation differs.
  if [[ "$results_plan_id" == "$plan_id" \
        && -n "$current_activation" \
        && ( -z "$results_activation" || "$results_activation" != "$current_activation" ) ]]; then
    $CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh manual-test-results-rotate-only "$active_feature" >&2
  fi
fi
```

Same-activation branches (where `results_activation == current_activation`) still fire as today: `state: complete` → `--seed-only` refusal, `state: in-progress` → paused-resume.

**Step 1 — dispatch on results state.** Read and validate `manual-test-results.md` if it (still) exists, then dispatch on its `state`:

- **Results file absent:** continue to workflow-state normalization. Genuine deferred-plan / first-run case (or just-rotated by Step 0 above).
- **Results file present but frontmatter unreadable, invalid, or not owned by the active plan.** Refusal triggers:
  - YAML parse error
  - Missing required keys (`feature`, `state`, `current-scenario`, `plan-id`, `seed-family-id`, counts)
  - `state` value not in `[in-progress, complete]`
  - Ownership mismatch: `results.feature != <active-feature>`, OR `results.plan-id != <current plan id>`, OR `results.seed-family-id != <current plan seed-family-id>`
  - State-specific inconsistency: for `state=in-progress`, `current-scenario` must be `null` or a scenario id present in the plan; for `state=complete`, `current-scenario` must be `null` AND `finished-at` must be non-null.

  Refuse with diagnostic naming the offending field/parse error/mismatch:

  ```
  manual-test-results.md frontmatter is invalid (<reason>); cannot determine resume state.
  Inspect the file and fix the YAML, or run /mo-manual-test-plan --force to rotate the broken file and start over.
  ```

  **Do NOT mutate `progress.md`. Do NOT re-render the results file from the template** (that would lose any per-scenario verdicts in the body).

- **Valid `state: in-progress`:** continue to workflow-state normalization. Paused-resume case.
- **Valid `state: complete`:** refuse: `"Manual test results already complete. Pass --seed-only to manage auto-seeding, or /mo-manual-test-plan --force to start over."` Do NOT normalize progress.md. (A clean finalization sets `manual-test-state=complete`, NOT `none`, so `(none, none) + results=complete` is a recoverable stale-progress state — recovery path is `--seed-only`, which Branch B accepts.)

### Branch A — workflow-state normalization

With the results-file pre-check passing, normalize `progress.md` so a pause routes correctly:

```
case (sub-flow, manual-test-state):
  ("none",            "none")    → progress.sh set sub-flow=manual-testing manual-test-state=running
                                    # deferred-plan path
  ("manual-testing",  "running") → no-op
  any other combo               → refuse: "Inconsistent state — sub-flow=<X>, manual-test-state=<Y>.
                                    Expected (none/none) or (manual-testing/running). Run /mo-resume-workflow."
```

### Branch A — flow

#### Step 1 — Resolve the results file

Render from `templates/manual-test-results.md.tmpl` if absent. The template includes `feature`, `plan-id` (copied from the current plan's `id`), `seed-family-id` (copied from the current plan's stable `seed-family-id`), `generated-in-activation` (copied from the current plan's `generated-in-activation`, NOT re-read from `progress.md` — preserves the "this run belongs to the plan it was rendered against" invariant; see `docs/manual-testing-folder/plan.md` § 4.3), `state: in-progress`, `current-scenario: null`, counts, `started-at: <timestamp>`, `finished-at: null`. If present, read its frontmatter — it tells us where to resume.

#### Step 2 — Local-environment-up phase

Always first, even on resume — env may have decayed since the pause.

- Read `## 1. Prerequisites` and `## 2. What to run` from the plan.
- Render the prerequisite checklist + run-commands as a single message to the overseer in chat. Per the plan template, each command is already in self-contained shape (absolute path inlined OR an `export RUN_ROOT="..."` preamble at the top of the section followed by `cd "$RUN_ROOT" && ...` commands). The runner echoes the section verbatim — it does NOT post-process or re-substitute `$RUN_ROOT`.
- Wait for the overseer to confirm `ready` (or `skip-env` if they're already running).

#### Step 3 — Per-scenario loop

For each scenario in the plan in order, starting from `current-scenario` (or scenario 1 if null):

##### 3.1 Set the cursor

Set `current-scenario: <THIS_ID>` in the results-file frontmatter BEFORE rendering. This is the resume key — pause persists this value, so resume re-shows the same scenario rather than skipping to the next one.

**Verdict-already-committed crash recovery:** before rendering, check whether a verdict block for `<THIS_ID>` already exists. If it does, treat the verdict as already committed (likely crash window after writing the body but before advancing the cursor): recompute counts from all verdict blocks, advance `current-scenario` to the next uncommitted scenario (or `null` if none), persist the frontmatter, and continue without prompting the overseer again. Keeps resume idempotent when a prior invocation crashed mid-commit.

##### 3.2 Render the scenario

Render in the report format the overseer specified:

```
⏺ <SCENARIO_ID> — <one-line title> (<linked-IR-IDs if any>)

What it tests: <expanded from the plan's scenario body>

Trick to trigger from the UI: <if the plan called this out>

Action:
<numbered steps from the plan>

Expected:
<bulleted expectations from the plan>
```

##### 3.3 Wait for overseer reply

Reply is one of: `pass`, `fail <observation>`, `skip <reason>`, `pause`.

##### 3.4 On `pass` / `fail` / `skip`

- Upsert the verdict block for `<THIS_ID>` in `manual-test-results.md` body (one canonical block per scenario id). Do not append a second block if one already exists; replace that scenario's block.
- Recompute `passed`/`failed`/`skipped` counts from the full set of verdict blocks. Then set `current-scenario` to the **next** uncommitted scenario id (or `null` if this was the last) — only AFTER the verdict block is committed, so the just-finished scenario is durable before the cursor advances.
- Write body + frontmatter via temp file + atomic rename where the platform supports it. Scenario verdict commit unit: parse existing verdict blocks into `map[scenario_id]`, replace `map[<THIS_ID>]`, render blocks in plan order, recompute counts, update cursor, write temp, rename.
- **Duplicate-verdict-block recovery.** When parsing existing verdict blocks into `map[scenario_id]`, if two or more blocks share the same scenario id (corruption from a prior crash window or hand-edit), keep the latest block (the one that appears later in the file) as canonical, drop the earlier duplicate(s), emit a one-line `^warning:` to stderr naming the scenario id and the count of duplicates dropped. Then proceed with the upsert as normal. Refusal-and-prompt is NOT acceptable — silent self-healing matches the rest of the file's idempotency story.
- Echo to chat as a single line: `<ID> ✅ <one-line outcome>` or `<ID> ❌ <one-line observation>` or `<ID> ⊘ skipped: <reason>`. Do NOT re-render the full scenario block in the echo.
- Continue to the next scenario.

##### 3.5 On `pause`

- Frontmatter is already set to `current-scenario: <THIS_ID>` from step 3.1. Do not advance it. Leave **results-file** `state: in-progress`. (The two state fields are deliberately separate: `progress.md` `manual-test-state: running` is the workflow-level marker for dispatcher routing; `manual-test-results.md` `state: in-progress` is the file-level marker for the resume guard.)
- Print: `"Paused at scenario <THIS_ID>. Type /mo-continue (will resume the run by re-showing this scenario) or /mo-manual-test-run directly. To bulk-skip remaining scenarios and end the run, type /mo-manual-test-run --finalize-skipped."`
- Stop.

#### Step 4 — Loop completion (auto-seed + finalize)

##### 4.1 Mark results complete

```
state: complete
finished-at: <timestamp>
current-scenario: null
```

Recompute pass/fail/skip counts from the verdict blocks.

##### 4.2 Auto-seed prompt

If `failed > 0`, ask the overseer:

```
Manual test complete: <passed>/<total> passed, <failed> failed, <skipped> skipped.
Auto-seed <failed> failures as findings in overseer-review.md?
Reply `y`, `n`, or `y --classify` to set scope per scenario (default if you reply `y`: scope=fix, severity=major).

  y          — runs the per-scenario family-inspection loop and seeds each failed scenario via
               review.sh upsert-manual-test-failure per the inspection's branch decision.
               Most scenarios end up as canonical ### IR-NNN blocks with Seeded: true; some may
               end up Seeded: false if you pick `skip` at a closed-IR or orphan-family per-scenario prompt.

  y --classify — same as y but prompts for severity/scope per failed scenario; reclassify_existing=true
               propagates --reclassify to every helper call that may update an existing IR.

  n          — leaves overseer-review.md untouched and you'll author findings yourself.
```

##### 4.3 Auto-seed family inspection (per scenario)

For each failed scenario, before any helper call:

```
base_seed_id = "manual-test:<seed-family-id>:<scenario-id>"
family       = $(review.sh find-by-seed-id-family "$active_feature" "$base_seed_id")
base_row     = the row in family whose seed-id == base_seed_id  (may be empty)
```

Dispatch on three shapes:

- **Family empty** (no base, no regressions): default helper call — `review.sh upsert-manual-test-failure ... <severity> <scope>`. Inserts a new base IR with chosen severity/scope.
- **Base missing but family non-empty** (orphan regressions from a prior cycle whose review session deleted the base): run the orphan-regression default-interactive prompt:

  ```
  scenario <id>: base IR missing but regression family exists; latest family IR is <IR-NNN> (status=<status>)
  Pick:
    a) seed into the existing regression family
    b) skip this scenario
    c) explicitly restore the missing base IR
  ```

  - `a`: `review.sh upsert-manual-test-failure ... --new-finding`
  - `b`: mark `Seeded: false`; continue.
  - `c`: `review.sh upsert-manual-test-failure ...` (default mode, inserts a new base IR).

  Pass the overseer's chosen severity/scope to whichever helper path they pick.

- **Base present, status=open:** default helper call. Helper's open-update path replaces details and preserves prior severity/scope unless `y --classify` reclassified them (in which case the runner passes `--reclassify`).
- **Base present, status ∈ {fixed, wontfix}:** default helper call. Helper emits the closed-IR warning; runner surfaces the per-IR prompt:

  ```
  IR-<NNN> is fixed/wontfix; the manual test failed it again. Pick:
    a) reopen the IR with the new observation       → re-call helper with --reopen
    b) record this as a new finding (separate IR)   → re-call helper with --new-finding
    c) skip (ignore — the IR stays as-is)            → no second call; Seeded: false
  ```

##### 4.4 Closed-IR caller pattern

Use this exact pattern for every helper call that may emit a warning. Three constraints simultaneously: (a) preserve stderr so warnings can be inspected; (b) check exit code before using `IR_ID` (non-zero exit means refusal — `IR_ID` is empty/stale); (c) feed the multi-line observation through `printf`, not `echo`:

```bash
stderr_tmp="$(mktemp)"

if ! IR_ID="$(printf '%s\n' "$observation" | $CLAUDE_PLUGIN_ROOT/scripts/review.sh upsert-manual-test-failure \
    "$active_feature" "$seed_family_id" "$scenario_id" "$severity" "$scope" \
    2> "$stderr_tmp")"; then
    err="$(cat "$stderr_tmp")"; rm -f "$stderr_tmp"
    printf 'upsert-manual-test-failure failed: %s\n' "$err" >&2
    # Helper non-zero exit is FATAL to the auto-seed loop. Do not finalize.
    return 1
fi

if grep -q '^warning:' "$stderr_tmp"; then
    warning_text="$(cat "$stderr_tmp")"
    # Closed-IR default path: surface to overseer; offer reopen / new-finding / skip.
    # On overseer choice, re-call helper with the chosen flag.
fi
rm -f "$stderr_tmp"
```

Do NOT use `trap 'rm -f "$stderr_tmp"' EXIT` inside the per-scenario loop. Re-registering an `EXIT` trap on every scenario overwrites earlier cleanup and can clobber an outer trap.

##### 4.5 `Seeded:` flip rule

The runner classifies the helper's outcome from exit code + presence of `^warning:` on stderr:

- Helper exit 0, stderr empty → **successful seed action** → `Seeded: true`.
- Helper exit 0, stderr starts with `^warning:` (closed-default) → **no seed action** → `Seeded` unchanged. If the overseer subsequently picks `reopen` or `new-finding` and the runner re-calls the helper, the second call's success flips `Seeded: true`. If the overseer picks `skip`, leave `Seeded: false`.
- Helper non-zero exit → no seed action → `Seeded` unchanged. The runner aborts the auto-seed loop as a hard error (per the closed-IR caller pattern). Branch B does not finalize or promote policy on this invocation.

The byte-diff doesn't matter — the helper's classification of the outcome does. This makes the cache safe under arbitrary crash/retry topologies.

##### 4.6 Policy promotion

After the loop completes successfully:

- `y` answer → `progress.sh set manual-test-failure-policy=auto-seed`.
- `y --classify` answer → same; `reclassify_existing=true` was already propagated.
- `n` answer → `progress.sh set manual-test-failure-policy=manual`.

**Policy-after-loop ordering is deliberate.** A mid-loop crash or helper non-zero exit leaves `policy=none`, `sub-flow=manual-testing`, `manual-test-state=running`; Branch B re-entry re-prompts the overseer from scratch and does not finalize until a complete valid exit occurs. Re-prompting is safe because per-scenario seeding is idempotent via seed-id, so the overseer can re-confirm without double-seeding any IRs.

##### 4.7 Finalize

The LAST mutation:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh set sub-flow=none manual-test-state=complete
```

A session break before this leaves `sub-flow=manual-testing` (re-enters cleanly via `/mo-continue`'s Manual-Test-Resume Handler).

##### 4.8 Hand-off message

```
Manual test done. Review overseer-review.md (auto-seeded failures appear at the bottom as canonical
### IR-NNN blocks — no canonicalization needed for those), add any subjective findings as free-form
text, and type /mo-continue when done. The free-form findings will be canonicalized by the existing
canonicalize pass on the next /mo-continue.
```

## Branch B — `--seed-only` invocation

### Branch B — preconditions

- Common preconditions (including `current-stage == 5`).
- `workflow-stream/<feature>/test/manual-test-plan.md` exists.
- `workflow-stream/<feature>/test/manual-test-results.md` exists.
- **Same corruption + active-plan ownership validation as Branch A.** YAML must parse; required keys present; `state` value in `[in-progress, complete]`; `results.feature` / `results.plan-id` / `results.seed-family-id` must match the active feature and current plan; state-specific invariants enforced.
- Results frontmatter `state: complete`.
- `manual-test-state` ∈ {`complete` (post-run), `running` (post-run-with-mid-seed-crash), OR `none` AND `sub-flow=none` AND results-file `state=complete` (recoverable stale-progress)}. Refuse on `skipped` (phase declined). Refuse on `none` AND `sub-flow=manual-testing` (genuinely inconsistent — `"Inconsistent: manual-test-state=none but sub-flow=manual-testing. Run /mo-resume-workflow."`).

### Branch B — entry guard (dispatch on `manual-test-failure-policy`)

| Policy value | Behavior                                                                                                                                                                                                                                       |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `none`       | First-time seeding (or recovery from a crash before step 4's auto-seed prompt). If `failed > 0`: prompt the overseer (auto-seed prompt as in Branch A step 4.2). If `failed == 0`: no-op; finalize by clearing sub-flow and confirm `policy=none`. |
| `auto-seed`  | Re-run the upsert loop for every failed scenario. The loop is idempotent via seed-id, so unchanged scenarios produce no diff; observation edits since last seed are picked up. Print `"Re-seed complete: <seeded>/<failed> failures seeded."` |
| `manual`     | Prompt: `"Auto-seed was declined for this run; switch to auto-seed and seed <failed> failures now? y/n"`. `y` flips policy to `auto-seed` and seeds; `n` keeps `policy=manual` and finalizes per the rule below.                              |

### Branch B — mandatory base-status inspection

Companion flags (`--reopen-all`, `--as-new-findings`, `--as-new-findings --force-new-regressions`) suppress the per-IR closed-base prompt but still run the same base-status inspection so override flags are passed only against the right cases. The inspection algorithm matches Branch A step 4.3 (family empty / base missing but family non-empty / open base / closed base) but dispatches on companion flag where applicable.

For closed-base + `--as-new-findings`: pass `--new-finding`. For closed-base + `--as-new-findings --force-new-regressions`: pass `--new-finding --force-new-regression`. For closed-base + `--reopen-all`: pass `--reopen`. For orphan-family + `--reopen-all`: refuse-and-skip per-scenario (`"scenario <id>: base IR missing but regression family exists; cannot reopen base; skipping"`; `Seeded: false`). For orphan-family + `--as-new-findings`: extend the existing regression family with `--new-finding`.

### Branch B — classification override propagation

The runner computes `reclassify_existing=true` when either (a) first-time auto-seed used `y --classify` (Branch A step 4.2), or (b) `--seed-only --reclassify` was passed. When true, append `--reclassify` to every helper call that may update an existing IR: open-base default update, closed-base `--reopen`, closed-base `--new-finding`, orphan-family seed-into-family, and default helper calls that hit an existing closed/open base.

### Branch B — finalization rule

Finalize on every **valid exit**:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh set sub-flow=none manual-test-state=complete
```

**Valid exits** (regardless of which `policy` shape Branch B was entered with):

- Overseer answered `y` or `y --classify`: the auto-seed loop ran to its end without any helper non-zero exit. Per-scenario outcomes may include `Seeded: true` (successful seed action) or `Seeded: false` (overseer picked `skip` at a closed-IR or orphan-family prompt). **Helper non-zero exit is never a per-scenario continue path** — it's a hard error that aborts the loop and falls under "Invalid exit" below.
- Overseer answered `n`: no overseer-review.md writes happen, but the workflow is genuinely done. Set `policy=manual` if entering with `policy=none`; leave as-is if already `manual`.
- No-failures no-op: `failed == 0`; no prompt fires. Confirm `policy=none` and finalize.
- `auto-seed` re-seed completed: idempotent zero-diff is fine; per-scenario seed-action outcomes flip `Seeded:` per the rules above.

**Invalid exits** (do NOT finalize, leave markers untouched):

- Precondition refusal (e.g., `current-stage != 5`, plan file missing, results state still `in-progress`).
- Hard error mid-loop (helper non-zero exit, schema failure, mutual-exclusion refusal, overseer aborted via Ctrl-C). Next invocation can pick up where the prior left off; do NOT promote `manual-test-failure-policy`, do NOT clear `sub-flow`, and do NOT set `manual-test-state=complete`.

After finalization, the next `/mo-continue` lands in the Overseer Handler.

## Branch C — `--finalize-skipped` invocation

Rare-path bulk-skip-and-finalize escape hatch. Branch C is **not** part of Branch A's flow: it does not run the local-environment-up phase, does not render the current scenario, and does not prompt the overseer for a verdict on any scenario. It writes skip verdicts for every uncommitted scenario, then converges directly into the auto-seed/finalization logic in Branch A step 4.

### Branch C — preconditions

In addition to the common preconditions:

- `workflow-stream/<feature>/test/manual-test-plan.md` exists.
- `workflow-stream/<feature>/test/manual-test-results.md` exists.
- **Results frontmatter passes the same corruption + active-plan ownership validation as Branches A and B.** YAML must parse; required keys present; `state` value in `[in-progress, complete]`; `current-scenario` (if non-null) is a scenario id present in the active plan; AND `results.feature == <active-feature>`, `results.plan-id == <current plan id>`, `results.seed-family-id == <current plan seed-family-id>`. Refuse on any failure with the same diagnostic shape as Branches A/B. **No mutation on refusal.**
- `sub-flow == manual-testing`
- `manual-test-state == running`
- Results frontmatter `state: in-progress`.
- Results-file `current-scenario != null`.

On any of the run-state preconditions failing:

- `"Manual test isn't running — nothing to finalize-skip. (sub-flow=<X>, manual-test-state=<Y>.) If the plan was generated but the run never started, just don't run it."`
- `"Manual test isn't paused — current-scenario is null. The run hasn't reached scenario 1 yet."`

### Branch C — pre-bulk-skip cursor-integrity check

Before writing any skip verdicts, parse verdict blocks per `docs/manual-testing/plan.md` § 4.2.1 (block boundary `^### <SCENARIO_ID> — ` to next `^### `/`^## `/EOF; bullet keys exact-match), apply duplicate self-healing (keep latest, warn on stderr), and validate that every scenario id ordered before `current-scenario` in the plan has exactly one **valid parsed verdict block**. Heading-only is not enough — missing `Verdict:`, invalid verdict value, or any other parser-refusal counts as missing/corrupt.

If any scenario before the cursor lacks a valid verdict, refuse:

```
--finalize-skipped: scenario <X> is ordered before current-scenario <CURSOR> in the plan but has no
valid verdict block (<reason>). Inspect manual-test-results.md and either restore the verdict, rewind
current-scenario by hand, or run /mo-manual-test-plan --force to start over.
```

No mutation. This makes `--finalize-skipped` an honest finalization escape hatch rather than a tool that silently papers over genuine corruption.

### Branch C — flow

1. **Parse and self-heal verdict blocks** (§ 4.2.1), then run the cursor-integrity check above. Refuse on any failure.
2. **Write bulk-skip verdicts.** For every scenario id from `current-scenario` onward (in plan order), upsert a verdict block with `Verdict: skip`, `Observation: bulk-skipped`, a `Recorded at` timestamp, and `Seeded: false`. **Pre-existing verdicts at or after `current-scenario` are left as-is** (Branch C never overwrites a real verdict; it only writes for scenarios that lack one). Recompute counts from the body. Set frontmatter `current-scenario: null`.
3. **Converge into Branch A step 4 (loop completion).** From here, the auto-seed prompt fires for any failed scenarios (bulk-skipped scenarios are NOT failures and do not enter the auto-seed loop), the helper writes seeded IRs per the family-inspection rules, and the LAST mutation is `progress.sh set sub-flow=none manual-test-state=complete`. **Terminal state is `manual-test-state=complete`, NOT `skipped`** — the run reached its terminal state, just with a higher skipped count.

Branch C does NOT run the local-environment-up phase, the per-scenario render/wait loop, or the pre-render verdict-already-committed check from Branch A step 3.1.

## Auto-seed ownership recap

`mo-manual-test-run` is the single owner for mutations that originate from manual-test results. The Overseer Handler in `/mo-continue` may still run its existing review-file canonicalization for overseer-authored review text, but it must not auto-seed, reopen, reclassify, or rewrite manual-test seeded IR blocks based on `manual-test-results.md`; it only surfaces the manual-test summary line.

The deterministic **seed-id** (`manual-test:<seed-family-id>:<scenario-id>`) written as a structured `- seed-id:` field on each auto-seeded IR-NNN block is the correctness mechanism that makes the seeding loop idempotent. The `Seeded:` boolean in the results file is a display/diagnostic cache — not load-bearing for correctness — and `--seed-only` mode bypasses it entirely (always greps overseer-review.md for the seed-id, so observation edits propagate).

## Context discipline

- Each scenario's full prompt is **rendered fresh from the plan file** every iteration, not held in conversation as a growing block.
- The chat echo per scenario is one line.
- Detailed verdicts (multi-line observations from the overseer) go to `manual-test-results.md` body, not to chat history. If the overseer types a long observation, the skill writes it to the file and echoes back only `<ID> ❌ failed (observation written to results file)`.

See `docs/manual-testing/plan.md` § 2.2 for the full design rationale, § 3.7.1 for the helper contract, § 4.2.1 for the verdict-block parsing contract.
