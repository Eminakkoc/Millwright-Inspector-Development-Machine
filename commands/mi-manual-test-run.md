---
description: Execute the active feature's manual-test-plan.md scenario by scenario — millwright-guided walkthrough with inspector verdicts (guided), inspector-driven verdicts (interactive), or millwright-driven verdicts (autonomous). Single owner of manual-test auto-seeding into inspector-review.md.
argument-hint: "[--guided-env | --autonomous-env | --interactive-env] | [--rerun-guided] | [--seed-only [--reclassify | --reopen-all | --as-new-findings [--force-new-regressions]]] | [--finalize-skipped]"
---

# mi-manual-test-run

**Runtime bootstrap.** Every `$CLAUDE_PLUGIN_ROOT` reference in this command's Bash blocks assumes a resolved plugin root; Claude Code does not inject the env var into Bash subshells. If it is empty in your shell, apply the canonical resolver (`docs/millwright-inspector-project.md` §8.14; reference implementation: `mi-continue.md` Step 1a) before the first Bash block: (1) inherited env var when it points at a working install, (2) `$PWD` when it is this plugin's source repo, (3) the `installPath` from `~/.claude/plugins/installed_plugins.json` — then export it, persist it to the per-cwd tempfile, and prepend the recovery one-liner to every subsequent Bash block. Refuse with an environmental diagnostic if none resolve.

Stage-5 sub-flow runner. Walks the active feature's `manual-test-plan.md` scenario by scenario in one of three env-modes:

| Env-mode | Who brings the environment up | Who judges each scenario |
| --- | --- | --- |
| `guided` (the `y` answer at the plan prompt) | the millwright | the **inspector**, walked through each scenario in plain language by the millwright |
| `interactive` (`--interactive-env`) | the inspector | the inspector |
| `autonomous` (`y-autonomous`) | the millwright | the millwright |

In **guided** env-mode the millwright brings the whole local environment up itself, then presents each scenario as a short plain-language explanation (≤ 2 sentences) plus a concrete example and exactly what to do, and waits for the inspector's `pass`, `fail <observation>`, `skip <reason>`, `defer <reason>` (offered only when the cycle has a feature-test entry and the active feature is not it), or `pause`; the inspector can also ask for notes or extra checks to be recorded into `manual-test-results.md` mid-walk. In **interactive** env-mode the inspector runs the services and each scenario and replies with the same verdict vocabulary. In **autonomous** env-mode the millwright performs each scenario itself and self-determines the `pass` / `fail <observation>` / `skip <reason>` verdict without asking the inspector to run anything (no `pause`; `skip` is a last-resort verdict reserved for a proven capability gap — see 3.3b — never a convenience exit); when it finishes, it offers a **guided re-run** (Step 4.7.1) so the inspector can walk the same plan themselves.

On loop completion, prompts the inspector to auto-seed failures as canonical `### IR-NNN` blocks in `inspector-review.md` via `review.sh upsert-manual-test-failure`. **This skill is the single owner of manual-test auto-seeding** — `/mi-continue`'s Inspector Handler is read-only against `inspector-review.md` for manual-test results.

## Invocation

```
/mi-manual-test-run                                     # Branch A — normal first-run / paused-resume
/mi-manual-test-run --guided-env                        # Branch A, forcing guided (millwright env-up, inspector verdicts)
/mi-manual-test-run --autonomous-env                    # Branch A, forcing autonomous local-environment-up
/mi-manual-test-run --interactive-env                   # Branch A, forcing interactive local-environment-up
/mi-manual-test-run --rerun-guided                      # Branch D — re-run a finished run as a guided walkthrough
/mi-manual-test-run --seed-only [<companion-flags>]     # Branch B — seed-only re-trigger / recovery
/mi-manual-test-run --finalize-skipped                  # Branch C — bulk-skip remaining scenarios + finalize
```

Mode flags are mutually exclusive: any two of `--seed-only`, `--finalize-skipped`, `--rerun-guided` together refuse with `"--seed-only, --finalize-skipped, and --rerun-guided are mutually exclusive"` and no mutation.

**Branch A env-mode flags** (`--guided-env` / `--autonomous-env` / `--interactive-env`): direct control over the local-environment-up phase (Step 2) and the per-scenario loop mode (Step 3). They are only meaningful for Branch A — the sole branch that runs the env-up phase. Behavior:

- They persist the choice by writing `progress.sh set manual-test-env-mode=<guided|autonomous|interactive>` **before** Step 2, so the mode is durable across a later pause/resume (which re-fires the runner without flags).
- Any two of them together refuse with `"--guided-env, --autonomous-env, and --interactive-env are mutually exclusive"` and no mutation.
- Any of them combined with `--seed-only`, `--finalize-skipped`, or `--rerun-guided` refuses with `"env-mode flags apply only to a normal run (Branch A); they cannot combine with --seed-only/--finalize-skipped/--rerun-guided"` and no mutation. (`--rerun-guided` already implies `guided`.)
- When no env-mode flag is passed, Branch A reads the persisted `manual-test-env-mode` (set earlier by `/mi-manual-test-plan` Step 7). A missing/null value means `interactive` — the backward-compatible reading for cycles that predate the field — **except** on a fresh run (no results file), where the runner asks once rather than assuming; see Step 2's "Unset-mode disambiguation".

**Branch B companion flags** (only meaningful with `--seed-only`):

| Flag                                                    | Effect                                                                                                                                                  |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--reclassify`                                          | Re-prompts severity/scope per failed scenario (like `y --classify` in first-time auto-seed) and passes `--reclassify` to each helper call.              |
| `--reopen-all`                                          | Per-scenario family inspection. Closed base → `--reopen`; open base / family-empty → default helper; orphan-family (base missing, regressions exist) → refuse-and-skip per-scenario. |
| `--as-new-findings`                                     | Mirror of `--reopen-all` but with `--new-finding` for closed bases. Open base / family-empty go through default mode. Orphan family extends the existing regression family. |
| `--as-new-findings --force-new-regressions`             | Composes with `--as-new-findings`. For every closed-base re-failure, allocates a fresh `:r<N>` regardless of whether an open regression exists. **Not idempotent.** |

`--reopen-all` and `--as-new-findings` (and the `--force-new-regressions` companion) cannot be combined; runner refuses with diagnostic.

## Dispatch order

Parse flags first, then dispatch to one of four branches. The runner picks exactly one branch and never mixes their flows:

1. Parse flags from `$ARGUMENTS`.
2. Validate env-mode flags: `--guided-env`, `--autonomous-env`, and `--interactive-env` are mutually exclusive with each other, and none may combine with `--seed-only`, `--finalize-skipped`, or `--rerun-guided` (refuse with the diagnostics in the Invocation section; no mutation).
3. If `--seed-only` is present → run **Branch B** (seed-only re-trigger / recovery).
4. Else if `--finalize-skipped` is present → run **Branch C** (bulk-skip + finalize).
5. Else if `--rerun-guided` is present → run **Branch D** (guided re-run of an already-finished run).
6. Else → run **Branch A** (normal first-run / paused-resume). If an env-mode flag was passed, Branch A applies it (see Branch A — env-mode resolution).

## Common preconditions (all branches)

- `progress.sh get-active` is non-null.
- `progress.sh get current-stage == 5`. Refuse outside stage 5: `"Manual test belongs to stage 5 (inspector review). Current stage is <N>. Type /mi-resume-workflow to see the next-step recommendation, or wait until the workflow reaches stage 5."`

## Resolve RUN_ROOT (Branches A, B, and D)

Before any user-facing prompt or scenario render in Branches A, B, and D (Branch D resolves it as a read-only precondition, before its rotation):

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
  echo "error: worktree drift — plan generated against $plan_run_root but progress.md active worktree is $RUN_ROOT. Run /mi-manual-test-plan --force to regenerate against the current worktree." >&2
  exit 1
fi
```

## Branch A — normal first-run / paused-resume

### Branch A — preconditions

- Common preconditions above.
- `workflow-stream/<feature>/test/manual-test-plan.md` exists.
- `manual-test-state` ∈ {`none`, `running`} (never run, OR paused mid-run). On `complete` or `skipped`, refuse: `"Manual test already terminal (state=<X>). Re-run with /mi-manual-test-plan --force to start over, or pass --seed-only to re-trigger only the auto-seed loop."`

### Branch A — pre-normalization results-file read

**Step 0 — Cross-activation auto-rotation (§4.1 fallback).** Before any other check, apply the triple-AND prior-activation guard from `docs/manual-testing-folder/plan.md` § 4.1 in case the runner was reached without `/mi-manual-test-plan` having fired first:

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
  Inspect the file and fix the YAML, or run /mi-manual-test-plan --force to rotate the broken file and start over.
  ```

  **Do NOT mutate `progress.md`. Do NOT re-render the results file from the template** (that would lose any per-scenario verdicts in the body).

- **Valid `state: in-progress`:** continue to workflow-state normalization. Paused-resume case.
- **Valid `state: complete`:** refuse: `"Manual test results already complete. Pass --seed-only to manage auto-seeding, or /mi-manual-test-plan --force to start over."` Do NOT normalize progress.md. (A clean finalization sets `manual-test-state=complete`, NOT `none`, so `(none, none) + results=complete` is a recoverable stale-progress state — recovery path is `--seed-only`, which Branch B accepts.)

### Branch A — workflow-state normalization

With the results-file pre-check passing, normalize `progress.md` so a pause routes correctly:

```
case (sub-flow, manual-test-state):
  ("none",            "none")    → progress.sh set sub-flow=manual-testing manual-test-state=running
                                    # deferred-plan path
  ("manual-testing",  "running") → no-op
  any other combo               → refuse: "Inconsistent state — sub-flow=<X>, manual-test-state=<Y>.
                                    Expected (none/none) or (manual-testing/running). Run /mi-resume-workflow."
```

### Branch A — flow

#### Step 1 — Resolve the results file

Render from `templates/manual-test-results.md.tmpl` if absent. The template includes `feature`, `plan-id` (copied from the current plan's `id`), `seed-family-id` (copied from the current plan's stable `seed-family-id`), `generated-in-activation` (copied from the current plan's `generated-in-activation`, NOT re-read from `progress.md` — preserves the "this run belongs to the plan it was rendered against" invariant; see `docs/manual-testing-folder/plan.md` § 4.3), `state: in-progress`, `current-scenario: null`, counts, `started-at: <timestamp>`, `finished-at: null`. If present, read its frontmatter — it tells us where to resume.

**Render through the helper — do not hand-write the frontmatter.** `frontmatter.sh init` runs the file through `mi_render_template`, which YAML-encodes every frontmatter substitution: the timestamp comes out quoted (unquoted, YAML would auto-type it as a datetime rather than the `type: string` the schema declares) and the file is schema-validated at write time. `TOTAL` takes the `!RAW!` sentinel because `total` is an integer and the default encoding would quote it into a string.

```bash
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init manual-test-results \
  "$results_file" \
  "FEATURE=$active_feature" \
  "PLAN_ID=$plan_id" \
  "SEED_FAMILY_ID=$seed_family_id" \
  "ACTIVATION_ID=$generated_in_activation" \
  "TOTAL=!RAW!$scenario_count" \
  "TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

#### Step 2 — Local-environment-up phase

Always first, even on resume — env may have decayed since the pause.

**Env-mode resolution.** Determine how the environment comes up:

```bash
# Direct-invocation override: if --guided-env / --autonomous-env /
# --interactive-env was passed, persist it FIRST so the choice survives a later
# pause/resume (mi-continue re-fires this runner without flags).
if [[ -n "$flag_env_mode" ]]; then           # "guided" | "autonomous" | "interactive" | ""
  $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set manual-test-env-mode="$flag_env_mode"
fi

env_mode="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get manual-test-env-mode 2>/dev/null || echo interactive)"
[[ -n "$env_mode" && "$env_mode" != "null" ]] || env_mode="interactive"
```

**Unset-mode disambiguation (fresh runs only).** With three modes, a bare `/mi-manual-test-run` on a run that never recorded a choice is ambiguous — silently picking `interactive` would hand the inspector a list of commands when they may have wanted the guided walkthrough. So when **all** of these hold — no env-mode flag was passed, AND the persisted `manual-test-env-mode` is missing/null, AND this is a **fresh** run (no `manual-test-results.md`, i.e. not a resume) — ask once instead of assuming:

```
How should I run this? Reply guided, autonomous, or interactive.

  guided       — I bring the environment up and walk you through each test case; your verdicts.
  autonomous   — I bring the environment up, run every case myself, and record my own verdicts.
  interactive  — you bring the services up and run every case yourself.
```

Persist the answer (`progress.sh set manual-test-env-mode=<answer>`) before continuing, so a later pause/resume recovers it. **Do NOT ask** when any of the three conditions fails: an env-mode flag is an explicit answer; a persisted value is an earlier explicit answer; and a resume (results file present) must not re-prompt — a pre-v1.6.8 cycle mid-run has no persisted value by construction, and its `interactive` default is the correct back-compatible reading. Auto-fire paths never reach this prompt: `/mi-manual-test-plan` Step 7 always persists the mode before firing the runner.

Then branch on `env_mode`. All three modes read the SAME plan sections (`## 1. Prerequisites`, `## 2. What to run`); they differ only in WHO runs the commands. `guided` and `autonomous` share one bring-up procedure (2b) and diverge only afterwards, at the per-scenario loop.

##### 2a. Interactive mode (`env_mode == interactive`, the default)

- Read `## 1. Prerequisites` and `## 2. What to run` from the plan.
- Render the prerequisite checklist + run-commands as a single message to the inspector in chat. Per the plan template, each command is already in self-contained shape (absolute path inlined OR an `export RUN_ROOT="..."` preamble at the top of the section followed by `cd "$RUN_ROOT" && ...` commands). The runner echoes the section verbatim — it does NOT post-process or re-substitute `$RUN_ROOT`.
- Wait for the inspector to confirm `ready` (or `skip-env` if they're already running).

##### 2b. Millwright-driven bring-up (`env_mode == autonomous` OR `env_mode == guided`)

The millwright brings the environment up **itself** — the inspector is NOT asked to run any command. This bring-up procedure is identical for both modes; only what happens afterwards differs:

- `autonomous` — the per-scenario loop (Step 3) is **also** run by the millwright: it performs each scenario itself and self-determines the `pass`/`fail`/`skip` verdict.
- `guided` — the per-scenario loop is a **walkthrough**: the millwright explains each scenario in plain language and tells the inspector what to do, and the **inspector** gives every verdict (Step 3.2c / 3.3c).

(Interactive mode automates neither — the inspector runs the services AND gives every verdict.)

1. Read `## 1. Prerequisites` and `## 2. What to run` from the plan. All commands run from the resolved `RUN_ROOT` (the plan already inlines it; do NOT re-substitute).
2. Announce in chat: `"Bringing the test environment up autonomously from <RUN_ROOT>."` followed by the list of commands about to run, so the inspector can see (and interrupt) what the millwright is doing.
3. **Idempotent readiness pre-check.** For each service the plan describes, first probe whether it is already up (the health URL / port / ready log line the plan names). Skip launching any service that is already healthy — this makes autonomous **resume** safe (background services started before a pause are usually still running; re-launching a dev server would fail on port-in-use).
4. **Execute the `## 2. What to run` commands in order**, classifying each by whether it returns:
   - **Long-running service** — a process that does not exit until killed (dev server, watcher, `docker compose up` without `-d`; e.g. `pnpm dev`, `npm start`, `next dev`, `vite`, `serve`, `… --watch`). Launch it with the Bash tool's `run_in_background: true` so it keeps running across the whole per-scenario loop. Record the returned background task id.
   - **One-shot bootstrap** — a command that runs to completion (installs, builds, DB migrations, seed-data loaders, `docker compose up -d`, `docker compose … --wait`). Run it in the **foreground** and check the exit code; a non-zero exit is a hard failure (step 6).
   - **Ambiguous** — if the millwright cannot confidently classify a command, treat it as a failure (step 6) rather than guessing; the inspector runs it.
5. **Wait for readiness** before proceeding: after launching background services, poll the health/URL/port the plan names (or watch the captured log for the service's ready line) with a bounded retry (roughly up to ~60s per service). Never advance to Step 3 against a service that is not yet up.
6. **On any bring-up failure** — a one-shot non-zero exit, a service that never becomes ready within the bound, or an unclassifiable command — STOP the bring-up. Do NOT fall through to the scenario loop. Report exactly what failed (the command, and the tail of its captured stdout/stderr or background-task output), then hand control back to the inspector: `"Environment bring-up failed at <cmd>: <reason>. Fix it and re-run /mi-manual-test-run (add --interactive-env to bring the environment up yourself), or reply here to continue manually."` Leave `manual-test-state=running` so the run is resumable.
7. **On success**, echo a concise one-line-per-service summary (service → background task id / URL, one-shots → `done`), then proceed directly to Step 3 — no `ready`/`skip-env` wait. Then:
   - `autonomous` — the millwright drives the per-scenario loop itself (Step 3, autonomous branch).
   - `guided` — announce that the environment is up and the walkthrough is starting, naming the entry point the inspector will be using (the app URL / CLI command the plan's scenarios exercise): `"Environment is up — <URL or entry point>. I'll walk you through <N> test cases one at a time. Reply `pass`, `fail <what you saw>`, `skip <why>`, `defer <reason>` (only when offer_defer=1), or `pause` after each one."` Then start the walkthrough (Step 3, guided branch).

Background services the millwright starts here are its responsibility for the life of the run; their background task ids are surfaced (step 7 summary, and again in the pause/finalize messages) so the inspector can stop them when the run ends. The millwright does NOT tear them down automatically — the inspector may keep exercising the environment while authoring findings.

##### Step 2.9 — Resolve the defer offer (DTI-003 / DTI-008)

```bash
if $CLAUDE_PLUGIN_ROOT/scripts/deferred-tests.sh offer-defer "$active_feature" >/dev/null 2>&1; then
  offer_defer=1
  ft_name="$($CLAUDE_PLUGIN_ROOT/scripts/todo.sh feature-test-status | head -1 | cut -f2)"
else
  offer_defer=0
  ft_name=""
fi
```

**Re-run this snippet in every block that renders the verdict vocabulary.** Each fenced
bash block is a separate invocation with no shared shell state, so `offer_defer` does not
survive from one block to the next — and defaulting it to `0` at a consumption site would
silently disable the disposition rather than fail loudly. The predicate is cheap: two
read-only `todo.sh` calls, no file writes.

`offer-defer` exits 0 only when the cycle has a feature-test entry in `ready`/`selected`
state **and** the active feature is not that entry. A single-feature cycle fails the first
clause (DTI-008); the feature-test entry's own terminal run fails the second. When it exits
1, every prompt string below is byte-identical to what shipped before this feature.

#### Step 3 — Per-scenario loop

For each scenario in the plan in order, starting from `current-scenario` (or scenario 1 if null):

##### 3.1 Set the cursor

Set `current-scenario: <THIS_ID>` in the results-file frontmatter BEFORE presenting or performing the scenario. This is the resume key — a `pause` (interactive) or an interruption of the autonomous run persists this value, so resume re-presents / re-runs the same scenario rather than skipping to the next one.

**Verdict-already-committed crash recovery:** before presenting or performing the scenario, check whether a verdict block for `<THIS_ID>` already exists. If it does, treat the verdict as already committed (likely crash window after writing the body but before advancing the cursor): recompute counts from all verdict blocks, advance `current-scenario` to the next uncommitted scenario (or `null` if none), persist the frontmatter, and continue without prompting the inspector or re-running the scenario. Keeps resume idempotent when a prior invocation crashed mid-commit.

##### 3.2 Present or perform the scenario (mode-branched)

All modes read the scenario fresh from the plan each iteration (per Context discipline). They differ in WHO exercises it and how it is presented.

###### 3.2a Interactive (`env_mode == interactive`, the default)

Render the scenario for the inspector in the report format they specified:

```
⏺ <SCENARIO_ID> — <one-line title> (<linked-IR-IDs if any>)

What it tests: <expanded from the plan's scenario body>

Trick to trigger from the UI: <if the plan called this out>

Action:
<numbered steps from the plan>

Expected:
<bulleted expectations from the plan>
```

###### 3.2b Autonomous (`env_mode == autonomous`)

The millwright performs the scenario **itself** against the environment it brought up in Step 2 — it does NOT render the scenario for the inspector to run. This is the whole point of `y-autonomous`: after env-up the run proceeds through every scenario without asking the inspector to run anything.

1. Read the scenario's `Action` steps and `Expected` outcomes from the plan.
2. **Announce a one-line intent before acting** — `running <SCENARIO_ID>: <what it's about to exercise>` — so the inspector can watch and interrupt.
3. **Execute the `Action` steps** using the tools available, driving from `RUN_ROOT`: shell commands, HTTP requests against the services started in Step 2 (the health/URL/route the plan names), log/DB/file inspection, project scripts, and any browser-automation tool the millwright actually has. Never simulate a step it did not run.
4. **Execute every scenario — attempt before judging.** The plan's scenario list is a contract: an autonomous run's default is a verdict grounded in actual execution for **100% of scenarios**. Do NOT pre-judge a scenario as un-runnable from its text, its similarity to a previous scenario, or its expected effort — attempt its `Action` steps with real tools first. A `skip` verdict is only reachable AFTER an attempt has demonstrated a genuine capability gap (3.3b defines the bar).

###### 3.2c Guided (`env_mode == guided`)

The environment is already up (the millwright started it in Step 2b). The **inspector** performs the scenario; the millwright's job is to make that as easy as possible. Present exactly one scenario, in this shape:

```
⏺ <SCENARIO_ID> — <one-line title>   (<i> of <N>)

What this checks: <≤ 2 sentences, plain language — no jargon, no internal symbol
names unless the inspector has to type them. Say what behavior is being verified and
why it matters, not how the code works.>

For example: <one concrete instance — a specific input and the specific thing that
should happen. Use real values the inspector can actually type/click, taken from the
plan's Action steps.>

What to do:
1. <numbered, copy-paste concrete steps from the plan's Action — with the resolved
   URL / command / input values filled in, not placeholders>
2. …

What you should see: <the plan's Expected bullets, restated as observable outcomes
in plain language — one line each.>

Reply `pass`, `fail <what you saw>`, `skip <why>`, `defer <reason>` (only when
offer_defer=1), or `pause`.
```

Bars for this presentation:

- **Brevity is the point.** "What this checks" is at most 2 sentences. If a scenario genuinely needs more, that is a signal to say less, not more — the detail belongs in the plan file, which the inspector can open.
- **Plain language.** Explain it the way you'd explain it to someone who has not read the code. Define any term you can't avoid.
- **Always give the example.** One concrete instance beats a general description; it is what makes an abstract expectation checkable.
- **Resolve every placeholder.** URLs, ports, paths, and sample payloads are filled in from the running environment and `RUN_ROOT` — the inspector should never have to substitute a variable.
- **One scenario per turn, then stop and wait.** Never present two scenarios in one message, and never guess a verdict — the whole point of guided mode is that the inspector looks and decides.
- **Answer questions in place.** If the inspector asks something about the current scenario ("where do I click?", "what's the difference from the last one?"), answer it, stay on the same scenario, and wait again. A question is not a verdict.

##### 3.3 Obtain the verdict (mode-branched)

Same verdict vocabulary in all three modes; only the source differs. The commit path (3.4) is shared.

###### 3.3a Interactive

Wait for the inspector's reply, one of: `pass`, `fail <observation>`, `skip <reason>`,
`defer <reason>` (offered only when `offer_defer=1`), `pause`.

###### 3.3b Autonomous

The millwright determines the verdict itself by comparing what it observed in 3.2b against every `Expected` bullet:

- **`pass`** — every expectation was actually observed to hold.
- **`fail <observation>`** — at least one expectation was observed NOT to hold. The `<observation>` is the millwright's own account: what it ran, what it saw, and the delta from expected. Autonomous failures are as load-bearing as inspector ones — they enter the auto-seed loop in Step 4 identically.
- **`skip <reason>`** — **last resort, allowed only for a proven capability gap, never for convenience.** Before a skip verdict the millwright MUST have: (1) actually attempted the `Action` steps (3.2b item 4); (2) tried every observation channel available for each `Expected` bullet — HTTP response, logs, DB/file state, project scripts, DOM/browser automation where present; (3) looked for an objective proxy when the expectation is subjective (the plan generator's autonomous-runnability rule lists machine-checkable side-effects for visual scenarios precisely so this run can verify those instead of skipping). Only if every expectation remains genuinely unobservable after all three may it skip, and the `<reason>` must name the specific unobservable expectation AND the channels attempted — e.g. `skip gradient rendering is visual-only; DOM classes + computed styles verified via browser tool, pixel output unobservable`. The following are NOT valid skip reasons and force an actual attempt instead: "similar to a previous scenario", "low value", "would take too long", "environment already exercised this path", "likely passes". **Never fabricate a `pass` for a step that was not actually exercised** — an honest `skip` beats a fabricated `pass`, but an executed verdict beats both: skipped scenarios do not seed findings, so every unjustified skip silently shrinks the quality gate.

There is **no `defer` verdict in autonomous mode** — autonomous mode never defers, in any
cycle shape. Deferral is inspector-driven by design: the journal frames it as "I can tell
the agent to defer a manual test item". An autonomous run that genuinely cannot exercise a
scenario already has the attempt-backed `skip` path above, whose bar is stricter than a
defer reason would be. This is stated rather than left implicit because the autonomous
branch matches on the same verdict strings the inspector-facing prompts render.

There is **no `pause` verdict** in autonomous mode — the millwright runs the loop straight through to Step 4. (The inspector can still interrupt the session at any point; the `current-scenario` cursor persisted in 3.1 makes an interruption resumable exactly as a `pause` would be, and Step 2's idempotent readiness pre-check relaunches only the services that stopped.)

###### 3.3c Guided

**The verdict is the inspector's, always.** Wait for their reply, one of `pass`,
`fail <observation>`, `skip <reason>`, `defer <reason>` (offered only when
`offer_defer=1`), `pause` — exactly the interactive vocabulary. The millwright brought the environment up and explained the scenario; it does NOT self-determine the outcome, and it does not "help" by pre-filling a verdict it expects. If the reply is a question or a comment rather than a verdict, answer it and wait again (3.2c).

Two guided-only behaviors on top of the interactive contract:

1. **Confirmation before advancing is mandatory.** Never move to the next scenario without a verdict for the current one. A bare `next`/`ok` with no verdict word is ambiguous — ask which verdict they mean rather than assuming `pass`.
2. **Inspector-requested additions to the results file.** During the walkthrough the inspector may ask for something to be recorded — an extra observation, a note, a check they ran that the plan didn't list, or a whole extra case they want captured. Honor it immediately and write it into `manual-test-results.md`:
   - **A note or observation about the current scenario** → fold it into that scenario's `Observation:` bullet at commit time (3.4). This is the common case, and it keeps one canonical block per scenario id.
   - **An extra check the inspector wants recorded as its own item** → append a block under `## Inspector-added checks` (create the section at the end of the body if absent) in the same shape as a verdict block, with the id `INS-<n>` (`n` starting at 1, per results file) and the same `Verdict` / `Observation` / `Recorded at` bullets. These are **not** plan scenarios: they never enter `total`, never enter the `passed`/`failed`/`skipped` counts, never advance the cursor, and never seed IRs — the frontmatter counters describe the plan, and a plan-shaped counter that counted ad-hoc checks would break every ownership comparison in Branches A/B/C.
   - **A gap in the plan itself** ("this case should have been in here") → record it as an `INS-<n>` block and say plainly that the plan file is not edited mid-run; the durable fix is `/mi-manual-test-plan --force` after this run, or a finding in `inspector-review.md`.

   Echo one line per addition (`recorded: <one-line summary>`), then return to the scenario you were on. An addition is never a verdict — after recording it, still wait for the verdict.

##### 3.4 On `pass` / `fail` / `skip` / `defer`

- Upsert the verdict block for `<THIS_ID>` in `manual-test-results.md` body (one canonical block per scenario id). Do not append a second block if one already exists; replace that scenario's block.
- **Carried-forward scenarios (`DTI-006`).** When the scenario's plan title begins with a
  `[deferred from <feature>]` marker, emit that marker as its own line directly under the
  `### <SCENARIO_ID> — <VERDICT>` heading and above the bullets, which keep their contract
  verbatim:

  ```markdown
  ### C.1 — pass

  [deferred from payments]

  - **Verdict:** pass
  - **Observation:** …
  ```

  **The verdict-block parser must tolerate a non-bullet line between the heading and the
  first bullet.** It reads by bullet key within the block window, so it already does — this
  makes that tolerance a contract rather than an accident. The block boundary
  (`^### <id> — ` to the next `^### `/`^## `/EOF) and the five bullet keys are unchanged.
- Recompute `passed`/`failed`/`skipped`/`deferred` counts from the full set of verdict
  blocks; `passed + failed + skipped + deferred == total` must hold. Then set `current-scenario` to the **next** uncommitted scenario id (or `null` if this was the last) — only AFTER the verdict block is committed, so the just-finished scenario is durable before the cursor advances.
- **On `defer <reason>` (requires `offer_defer=1`).** The reason is mandatory — an entry
  without one is not runnable later. A bare `defer` re-prompts rather than recording an
  empty reason.

  Write the verdict block with `Verdict: defer` and the reason as `Observation:`, keeping
  the existing five-bullet contract and order; `Seeded:` stays `false` and is never
  flipped. In the **same** commit unit, park the scenario:

  ```bash
  # Resolve ft_name in THIS fence — per trap 5, a fenced bash block carries no
  # state from any other block, and this is the one non-vocabulary site where
  # ft_name is used for real effect (the upsert target), so it cannot rely on
  # Step 2.9 having run earlier in the same invocation.
  ft_name="$($CLAUDE_PLUGIN_ROOT/scripts/todo.sh feature-test-status | head -1 | cut -f2)"
  $CLAUDE_PLUGIN_ROOT/scripts/deferred-tests.sh upsert "$ft_name" \
    --feature "$active_feature" \
    --scenario "$THIS_ID" \
    --title "$scenario_title" \
    --reason "$defer_reason" \
    --action "$scenario_action" \
    --expected "$scenario_expected"
  ```

  One disposition, one commit unit — a crash between a results write and a deferred-tests
  write would otherwise leave the two files disagreeing. `upsert` is idempotent on the
  `<feature>/<scenario>` composite key, so re-deferring the same scenario updates the one
  entry and the existing verdict-already-committed crash recovery (3.1) stays correct. It
  also preserves any `Merged as:` already written by a prior plan generation.

- **A `defer` reply never falls into the `fail` or `skip` parsing branch.** This is the
  single most important behavioural guard in the disposition: a defer is neither a failure
  nor an abandonment.

- Echo shape: `<ID> ⏸ deferred: <reason>`.
- Write body + frontmatter via temp file + atomic rename where the platform supports it. Scenario verdict commit unit: parse existing verdict blocks into `map[scenario_id]`, replace `map[<THIS_ID>]`, render blocks in plan order, recompute all four counts, update cursor, write temp, rename.
- **Parsing scope (load-bearing).** Verdict-block parsing — here, in Branch C's cursor-integrity check, and anywhere else the body is read — is scoped to the `## Per-scenario verdicts` section: start at that heading, stop at the next `## ` heading or EOF, and treat `### <id> — ` blocks inside that window as verdicts. Blocks outside it (notably `## Inspector-added checks`'s `### INS-<n>` blocks from guided mode) are NOT verdicts: they never enter `map[scenario_id]`, the counters, the cursor, or the auto-seed loop. An unscoped whole-body scan would swallow them and corrupt the counts.
- **Duplicate-verdict-block recovery.** When parsing existing verdict blocks into `map[scenario_id]`, if two or more blocks share the same scenario id (corruption from a prior crash window or hand-edit), keep the latest block (the one that appears later in the file) as canonical, drop the earlier duplicate(s), emit a one-line `^warning:` to stderr naming the scenario id and the count of duplicates dropped. Then proceed with the upsert as normal. Refusal-and-prompt is NOT acceptable — silent self-healing matches the rest of the file's idempotency story.
- Echo to chat as a single line: `<ID> ✅ <one-line outcome>` or `<ID> ❌ <one-line observation>` or `<ID> ⊘ skipped: <reason>`. Do NOT re-render the full scenario block in the echo.
- **Guided mode only:** anything the inspector asked to record for this scenario (3.3c item 2) is folded into the `Observation:` bullet in the same commit — one write, not two. `INS-<n>` blocks under `## Inspector-added checks` are written the same way (parse → upsert by id → render → atomic rename) but do NOT touch `total` / `passed` / `failed` / `skipped` or the cursor.
- Continue to the next scenario.

##### 3.5 On `pause` (interactive and guided modes)

Reached in interactive and guided mode — `pause` is not a verdict the autonomous loop produces. An autonomous run instead runs straight through; if the inspector interrupts it, the persisted `current-scenario` cursor (3.1) makes it resumable, and `/mi-continue`'s Manual-Test-Resume Handler re-probes and relaunches any stopped millwright-started services (see 3.3b).

- Frontmatter is already set to `current-scenario: <THIS_ID>` from step 3.1. Do not advance it. Leave **results-file** `state: in-progress`. (The two state fields are deliberately separate: `progress.md` `manual-test-state: running` is the workflow-level marker for dispatcher routing; `manual-test-results.md` `state: in-progress` is the file-level marker for the resume guard.)
- Print: `"Paused at scenario <THIS_ID>. Type /mi-continue (will resume the run by re-showing this scenario) or /mi-manual-test-run directly. To bulk-skip remaining scenarios and end the run, type /mi-manual-test-run --finalize-skipped."`
- **Guided mode only:** append the list of millwright-started background services (with their task ids) and note that they are left running so the environment survives the pause — resume re-probes and relaunches only what stopped.
- Stop.

#### Step 4 — Loop completion (auto-seed + finalize)

##### 4.1 Mark results complete

```
state: complete
finished-at: "<timestamp>"
current-scenario: null
```

**Quote the timestamp.** `finished-at` and `started-at` are `type: string` in `schemas/manual-test-results.schema.yaml`; an unquoted ISO-8601 scalar is auto-typed by YAML as a datetime, not text. `frontmatter.sh validate` tolerates the drift but warns; every other reader of this file expects a string. The same applies anywhere this command writes frontmatter by hand.

Recompute `passed` / `failed` / `skipped` / `deferred` counts from the verdict blocks.
The identity `passed + failed + skipped + deferred == total` must hold — deferred
scenarios stay **inside** `total`.

**Autonomous env-mode only — pre-finalize skip audit (runs BEFORE writing `state: complete`):** if `skipped > 0`, re-read every `skip` verdict block and check its recorded reason against the 3.3b bar — it must name a specific unobservable expectation and the channels attempted. Any skip whose reason reads as convenience ("similar to", "low value", time/effort, "likely passes", an empty or generic reason) is NOT terminal: re-enter Step 3 for that scenario and execute it properly — the 3.4 upsert replaces the skip verdict with the earned one. Only when every remaining skip is a genuine, attempt-backed capability gap may the run finalize. This audit is the enforcement backstop for the 100%-execution contract in 3.2b item 4.

**Autonomous env-mode only:** the inspector was hands-off for the whole loop, so echo a one-line roll-up before the auto-seed decision: `"Autonomous manual test complete: <passed>/<total> passed, <failed> failed, <skipped> skipped, <deferred> deferred."` When `skipped > 0`, follow it with one line per skipped scenario — `<ID> ⊘ <unobservable expectation> — attempted: <channels>` — so the inspector immediately sees that nothing was silently dropped. (Interactive mode already surfaced each verdict as the inspector gave it.)

##### 4.2 Auto-seed prompt

If `failed > 0`, ask the inspector:

```
Manual test complete: <passed>/<total> passed, <failed> failed, <skipped> skipped, <deferred> deferred.
Auto-seed <failed> failures as findings in inspector-review.md?
Reply `y`, `n`, or `y --classify` to set scope per scenario (default if you reply `y`: scope=fix, severity=major).

  y          — runs the per-scenario family-inspection loop and seeds each failed scenario via
               review.sh upsert-manual-test-failure per the inspection's branch decision.
               Most scenarios end up as canonical ### IR-NNN blocks with Seeded: true; some may
               end up Seeded: false if you pick `skip` at a closed-IR or orphan-family per-scenario prompt.

  y --classify — same as y but prompts for severity/scope per failed scenario; reclassify_existing=true
               propagates --reclassify to every helper call that may update an existing IR.

  n          — leaves inspector-review.md untouched and you'll author findings yourself.
```

**A deferred scenario never spawns an `IR-NNN`.** It does not enter the failed set, so the
`<failed>` count above excludes it and the per-scenario family-inspection loop never sees
it. `review.sh upsert-manual-test-failure` is unchanged by this feature.

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

  Pass the inspector's chosen severity/scope to whichever helper path they pick.

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
    # Closed-IR default path: surface to inspector; offer reopen / new-finding / skip.
    # On inspector choice, re-call helper with the chosen flag.
fi
rm -f "$stderr_tmp"
```

Do NOT use `trap 'rm -f "$stderr_tmp"' EXIT` inside the per-scenario loop. Re-registering an `EXIT` trap on every scenario overwrites earlier cleanup and can clobber an outer trap.

##### 4.5 `Seeded:` flip rule

The runner classifies the helper's outcome from exit code + presence of `^warning:` on stderr:

- Helper exit 0, stderr empty → **successful seed action** → `Seeded: true`.
- Helper exit 0, stderr starts with `^warning:` (closed-default) → **no seed action** → `Seeded` unchanged. If the inspector subsequently picks `reopen` or `new-finding` and the runner re-calls the helper, the second call's success flips `Seeded: true`. If the inspector picks `skip`, leave `Seeded: false`.
- Helper non-zero exit → no seed action → `Seeded` unchanged. The runner aborts the auto-seed loop as a hard error (per the closed-IR caller pattern). Branch B does not finalize or promote policy on this invocation.

The byte-diff doesn't matter — the helper's classification of the outcome does. This makes the cache safe under arbitrary crash/retry topologies.

##### 4.6 Policy promotion

After the loop completes successfully:

- `y` answer → `progress.sh set manual-test-failure-policy=auto-seed`.
- `y --classify` answer → same; `reclassify_existing=true` was already propagated.
- `n` answer → `progress.sh set manual-test-failure-policy=manual`.

**Policy-after-loop ordering is deliberate.** A mid-loop crash or helper non-zero exit leaves `policy=none`, `sub-flow=manual-testing`, `manual-test-state=running`; Branch B re-entry re-prompts the inspector from scratch and does not finalize until a complete valid exit occurs. Re-prompting is safe because per-scenario seeding is idempotent via seed-id, so the inspector can re-confirm without double-seeding any IRs.

##### 4.7 Finalize

The LAST mutation:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh set sub-flow=none manual-test-state=complete
```

A session break before this leaves `sub-flow=manual-testing` (re-enters cleanly via `/mi-continue`'s Manual-Test-Resume Handler).

"LAST mutation" scopes to **this run**. The guided re-run offer below fires after finalization and, if accepted, starts a new run through Branch D — which re-opens the markers deliberately and with its own preconditions. It is a fresh run, not a continuation of this one.

##### 4.7.1 Guided re-run offer (autonomous env-mode only)

A hands-off run is a machine's opinion of the feature. The inspector may still want to see it with their own eyes — so after an autonomous run finalizes, **always offer the guided walkthrough**:

```
Autonomous run finished: <passed>/<total> passed, <failed> failed, <skipped> skipped, <deferred> deferred.
Want to walk through the same plan yourself now? I'll bring the environment back up
(or reuse what's already running), explain each test case in plain language, and
record YOUR verdicts. Reply y or n.

  y  — guided re-run. The autonomous verdicts are rotated into
       test/manual-test-results.history/<timestamp>/ and kept; this run starts a
       fresh results file against the same plan. Failures you record upsert into the
       same seeded IR family, so nothing is double-seeded.
  n  — done. Review inspector-review.md and type /mi-continue.
```

- Fires **only** when `env_mode == autonomous`, and only on a clean finalization (Step 4.7 actually ran). Never fires for guided or interactive runs — those verdicts are already the inspector's.
- Fires regardless of the auto-seed answer, and regardless of pass/fail counts: a clean autonomous pass is exactly the case an inspector most often wants to double-check.
- On `y` → invoke `/mi-manual-test-run --rerun-guided` (Branch D) and stop driving; Branch D owns the rest, including its own Step 4 and hand-off message. Do NOT print 4.8 as well.
- On `n` → continue to 4.8 unchanged.
- Ask **once** per autonomous run. If the inspector declines and later changes their mind, `/mi-manual-test-run --rerun-guided` is directly invocable — say so in the 4.8 hand-off for autonomous runs.

##### 4.8 Hand-off message

```
Manual test done. Review inspector-review.md (auto-seeded failures appear at the bottom as canonical
### IR-NNN blocks — no canonicalization needed for those), add any subjective findings as free-form
text, and type /mi-continue when done. The free-form findings will be canonicalized by the existing
canonicalize pass on the next /mi-continue.
```

**Guided and autonomous env-modes:** append a line listing the millwright-started background services (with their task ids) and note they are still running so the inspector can stop them once done exercising the environment (the runner does not tear them down automatically).

**Autonomous env-mode only:** when the inspector declined the 4.7.1 guided re-run offer, append: `"Changed your mind? /mi-manual-test-run --rerun-guided walks you through the same plan with your own verdicts."`

## Branch B — `--seed-only` invocation

### Branch B — preconditions

- Common preconditions (including `current-stage == 5`).
- `workflow-stream/<feature>/test/manual-test-plan.md` exists.
- `workflow-stream/<feature>/test/manual-test-results.md` exists.
- **Same corruption + active-plan ownership validation as Branch A.** YAML must parse; required keys present; `state` value in `[in-progress, complete]`; `results.feature` / `results.plan-id` / `results.seed-family-id` must match the active feature and current plan; state-specific invariants enforced.
- Results frontmatter `state: complete`.
- `manual-test-state` ∈ {`complete` (post-run), `running` (post-run-with-mid-seed-crash), OR `none` AND `sub-flow=none` AND results-file `state=complete` (recoverable stale-progress)}. Refuse on `skipped` (phase declined). Refuse on `none` AND `sub-flow=manual-testing` (genuinely inconsistent — `"Inconsistent: manual-test-state=none but sub-flow=manual-testing. Run /mi-resume-workflow."`).

### Branch B — entry guard (dispatch on `manual-test-failure-policy`)

| Policy value | Behavior                                                                                                                                                                                                                                       |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `none`       | First-time seeding (or recovery from a crash before step 4's auto-seed prompt). If `failed > 0`: prompt the inspector (auto-seed prompt as in Branch A step 4.2). If `failed == 0`: no-op; finalize by clearing sub-flow and confirm `policy=none`. |
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

- Inspector answered `y` or `y --classify`: the auto-seed loop ran to its end without any helper non-zero exit. Per-scenario outcomes may include `Seeded: true` (successful seed action) or `Seeded: false` (inspector picked `skip` at a closed-IR or orphan-family prompt). **Helper non-zero exit is never a per-scenario continue path** — it's a hard error that aborts the loop and falls under "Invalid exit" below.
- Inspector answered `n`: no inspector-review.md writes happen, but the workflow is genuinely done. Set `policy=manual` if entering with `policy=none`; leave as-is if already `manual`.
- No-failures no-op: `failed == 0`; no prompt fires. Confirm `policy=none` and finalize.
- `auto-seed` re-seed completed: idempotent zero-diff is fine; per-scenario seed-action outcomes flip `Seeded:` per the rules above.

**Invalid exits** (do NOT finalize, leave markers untouched):

- Precondition refusal (e.g., `current-stage != 5`, plan file missing, results state still `in-progress`).
- Hard error mid-loop (helper non-zero exit, schema failure, mutual-exclusion refusal, inspector aborted via Ctrl-C). Next invocation can pick up where the prior left off; do NOT promote `manual-test-failure-policy`, do NOT clear `sub-flow`, and do NOT set `manual-test-state=complete`.

After finalization, the next `/mi-continue` lands in the Inspector Handler.

Branch B does **not** fire the Step 4.7.1 guided re-run offer, even when the run it is recovering was autonomous — it is a seeding-recovery path, not the end of a run, and re-prompting there would compete with its own auto-seed prompt. Mention `/mi-manual-test-run --rerun-guided` in Branch B's closing message when `manual-test-env-mode == autonomous`, so the option is still visible.

## Branch C — `--finalize-skipped` invocation

Rare-path bulk-skip-and-finalize escape hatch. Branch C is **not** part of Branch A's flow: it does not run the local-environment-up phase, does not render the current scenario, and does not prompt the inspector for a verdict on any scenario. It writes skip verdicts for every uncommitted scenario, then converges directly into the auto-seed/finalization logic in Branch A step 4.

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

Before writing any skip verdicts, parse verdict blocks (scoped to `## Per-scenario verdicts` per step 3.4's parsing-scope rule; block boundary `^### <SCENARIO_ID> — ` to next `^### `/`^## `/EOF; bullet keys exact-match), apply duplicate self-healing (keep latest, warn on stderr), and validate that every scenario id ordered before `current-scenario` in the plan has exactly one **valid parsed verdict block**. Heading-only is not enough — missing `Verdict:`, invalid verdict value, or any other parser-refusal counts as missing/corrupt.

If any scenario before the cursor lacks a valid verdict, refuse:

```
--finalize-skipped: scenario <X> is ordered before current-scenario <CURSOR> in the plan but has no
valid verdict block (<reason>). Inspect manual-test-results.md and either restore the verdict, rewind
current-scenario by hand, or run /mi-manual-test-plan --force to start over.
```

No mutation. This makes `--finalize-skipped` an honest finalization escape hatch rather than a tool that silently papers over genuine corruption.

### Branch C — flow

1. **Parse and self-heal verdict blocks** (scoped per step 3.4's parsing-scope rule), then run the cursor-integrity check above. Refuse on any failure.
2. **Write bulk-skip verdicts.** For every scenario id from `current-scenario` onward (in plan order), upsert a verdict block with `Verdict: skip`, `Observation: bulk-skipped`, a `Recorded at` timestamp, and `Seeded: false`. **Pre-existing verdicts at or after `current-scenario` are left as-is** (Branch C never overwrites a real verdict; it only writes for scenarios that lack one). Recompute `passed`/`failed`/`skipped`/`deferred` counts from the body; `passed + failed + skipped + deferred == total` must hold. Set frontmatter `current-scenario: null`.
3. **Converge into Branch A step 4 (loop completion).** From here, the auto-seed prompt fires for any failed scenarios (bulk-skipped scenarios are NOT failures and do not enter the auto-seed loop), the helper writes seeded IRs per the family-inspection rules, and the LAST mutation is `progress.sh set sub-flow=none manual-test-state=complete`. **Terminal state is `manual-test-state=complete`, NOT `skipped`** — the run reached its terminal state, just with a higher skipped count.

Branch C does NOT run the local-environment-up phase, the per-scenario present/perform loop (interactive render-and-wait, guided walkthrough, or autonomous execute-and-judge), or the pre-render verdict-already-committed check from Branch A step 3.1.

## Branch D — `--rerun-guided` invocation

Re-runs an **already-finished** manual test as a guided walkthrough, against the same plan. Its reason to exist: a `y-autonomous` run produces the millwright's verdicts, and the inspector may still want to see the feature with their own eyes. Fired from the Step 4.7.1 offer at the end of an autonomous run, or typed directly at any point afterwards while the cycle is still at stage 5.

Branch D is a **thin front-end onto Branch A**: it validates, rotates the finished results file into history, flips the markers back to a running guided run, and then converges into Branch A's flow. Everything after the reset — results-file render, env-up, the per-scenario loop, auto-seed, finalization — is Branch A's, unmodified.

### Branch D — preconditions

All read-only. Any failure refuses with the diagnostic and leaves `progress.md` byte-identical and the filesystem untouched.

- Common preconditions (including `current-stage == 5`).
- `workflow-stream/<feature>/test/manual-test-plan.md` exists. Refuse: `"No manual-test plan for <feature>; nothing to re-run. Generate one with /mi-manual-test-plan."`
- `workflow-stream/<feature>/test/manual-test-results.md` exists. Refuse: `"No finished manual-test run for <feature> to re-run. Start one with /mi-manual-test-run."`
- **Same corruption + active-plan ownership validation as Branch A** — YAML parses, required keys present, `state` in `[in-progress, complete]`, and `results.feature` / `results.plan-id` / `results.seed-family-id` all match the active feature and current plan. Same diagnostic shape.
- Results frontmatter `state: complete`. On `in-progress`, refuse: `"That run isn't finished — resume it with /mi-manual-test-run, or end it with /mi-manual-test-run --finalize-skipped. --rerun-guided re-runs a completed run."`
- `sub-flow == none`. On `manual-testing`, refuse: `"A manual-test run is still open (sub-flow=manual-testing). Type /mi-continue to finish it, then re-run with --rerun-guided."`
- `manual-test-state == complete`, OR the recoverable stale-progress shape Branch B also accepts (`none` AND `sub-flow == none` AND results `state: complete`). Refuse on `running` (`"a run is in flight — /mi-continue resumes it"`) and on `skipped` (`"the manual-test phase was declined for this cycle; /mi-manual-test-plan --force starts one"`).
- `RUN_ROOT` resolves, and the plan's `generated-against-run-root` matches it — the **same worktree-drift guard as Branches A and B** (Branch D executes scenarios, so a drifted plan is as wrong here as on a first run).

Env-mode flags do not combine with `--rerun-guided` (it already implies `guided`); `--seed-only` and `--finalize-skipped` do not either. See the Dispatch order.

### Branch D — flow

1. **Run every precondition above.** Nothing is mutated until all of them pass.
2. **Rotate the finished results file into history** — filesystem mutation, before any `progress.md` write:

   ```bash
   $CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh manual-test-results-rotate-only "$active_feature"
   ```

   The prior run's verdicts are preserved at `test/manual-test-results.history/<UTC-timestamp>/manual-test-results.md` — a guided re-run never destroys the autonomous record it is second-guessing. `manual-test-plan.md` is **not** rotated: the whole point is to re-run the *same* plan, so its `id`, `seed-family-id`, and `generated-in-activation` all survive.

   If the rotation fails, stop with its diagnostic and do NOT touch `progress.md`.
3. **Reset the markers for a fresh guided run:**

   ```bash
   $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set sub-flow=manual-testing manual-test-state=running \
     manual-test-env-mode=guided manual-test-failure-policy=none
   ```

   `manual-test-failure-policy=none` is deliberate: the re-run gets its own auto-seed prompt rather than silently inheriting the previous run's answer.
4. **Converge into Branch A's flow, starting at Branch A Step 1.** The state Branch A now sees is exactly a fresh run: results file absent (just rotated), `(sub-flow, manual-test-state) == (manual-testing, running)` so its normalization is a no-op, and `env_mode == guided` so Step 2 uses the millwright-driven bring-up and Step 3 the guided walkthrough. Branch A Step 0's cross-activation auto-rotation is a no-op (no results file to rotate).

   Step 2's idempotent readiness pre-check matters here: the services the autonomous run started are usually still up, so the re-run reuses them instead of failing on port-in-use.
5. **Auto-seeding is idempotent across the two runs**, because the plan's `seed-family-id` is unchanged: a scenario that failed in both runs upserts the same base IR (its observation updated to the inspector's own words) rather than creating a duplicate.

### Branch D — what a re-run does NOT do

- **It does not close or reopen IRs on its own.** A scenario the autonomous run failed and the inspector now passes leaves the seeded IR exactly as it was — the runner only ever seeds failures. Closing it is the inspector's call in `inspector-review.md`, which is the right place for that judgment. Say this plainly in the hand-off when the re-run's pass set differs from the rotated run's.
- **It does not edit the plan.** Gaps the inspector notices during the walkthrough are recorded as `INS-<n>` blocks (3.3c) and/or findings; regenerating the plan is `/mi-manual-test-plan --force`.
- **It does not stack.** Each `--rerun-guided` rotates the current results and starts one new run; there is no accumulation of parallel result sets, only the history folder.

Branch D can be invoked repeatedly (each invocation rotates the then-current results file), and it is not restricted to following an autonomous run — a guided re-run of an interactive or guided run is legal, just rarely useful.

## Auto-seed ownership recap

`mi-manual-test-run` is the single owner for mutations that originate from manual-test results. The Inspector Handler in `/mi-continue` may still run its existing review-file canonicalization for inspector-authored review text, but it must not auto-seed, reopen, reclassify, or rewrite manual-test seeded IR blocks based on `manual-test-results.md`; it only surfaces the manual-test summary line.

The deterministic **seed-id** (`manual-test:<seed-family-id>:<scenario-id>`) written as a structured `- seed-id:` field on each auto-seeded IR-NNN block is the correctness mechanism that makes the seeding loop idempotent. The `Seeded:` boolean in the results file is a display/diagnostic cache — not load-bearing for correctness — and `--seed-only` mode bypasses it entirely (always greps inspector-review.md for the seed-id, so observation edits propagate).

## Context discipline

- Each scenario's full prompt is **rendered fresh from the plan file** every iteration, not held in conversation as a growing block.
- The chat echo per scenario is one line.
- Detailed verdicts (multi-line observations — inspector-typed in interactive and guided modes, millwright-generated in autonomous mode) go to `manual-test-results.md` body, not to chat history. When an observation is long, the skill writes it to the file and echoes back only `<ID> ❌ failed (observation written to results file)`.
- Guided mode's per-scenario presentation is the one deliberate exception to the one-line-per-scenario echo rule: the explanation, example, and steps ARE the interface. It stays bounded by the 3.2c bars (≤ 2 sentences of explanation, one example, the plan's steps with placeholders resolved) and is rendered fresh from the plan each iteration, never accumulated in conversation.

See `docs/millwright-inspector-project.md` § 6.2 (stage 5) for how this runner sits in the workflow. The verdict-block parsing contract is stated inline at step 3.4 ("Parsing scope" + "Duplicate-verdict-block recovery"); the helper contract is `scripts/review.sh upsert-manual-test-failure`.
