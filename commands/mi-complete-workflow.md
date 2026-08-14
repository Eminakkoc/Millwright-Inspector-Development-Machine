---
description: Finalize the active feature's workflow — archive blueprints, clear implementation, advance the queue. Stage 8.
---

# mi-complete-workflow

**Runtime bootstrap.** Every `$CLAUDE_PLUGIN_ROOT` reference in this command's Bash blocks assumes a resolved plugin root; Claude Code does not inject the env var into Bash subshells. If it is empty in your shell, apply the canonical resolver (`docs/millwright-inspector-project.md` §8.14; reference implementation: `mi-continue.md` Step 1a) before the first Bash block: (1) inherited env var when it points at a working install, (2) `$PWD` when it is this plugin's source repo, (3) the `installPath` from `~/.claude/plugins/installed_plugins.json` — then export it, persist it to the per-cwd tempfile, and prepend the recovery one-liner to every subsequent Bash block. Refuse with an environmental diagnostic if none resolve.

**Delegation contract.** This command REQUIRES the sub-agents listed below; §8.13's main-read budget forbids main from doing their work itself. **Invoking `/mi-complete-workflow` IS the user requesting them** — Claude Code's default "do not call the Agent tool unless the user requested it" (and any stricter house rule layered on it) does not reach a sub-agent this command names at the step that names it, so spawn them without asking for extra confirmation. The default still holds everywhere else: never spawn a sub-agent this command does not name, and never invent fan-out to parallelize a step main is supposed to run. If a named delegation genuinely cannot run (type unavailable, harness refusal), say so and stop — never silently do its work in main. Sub-agents: `lessons-distiller` (Step 3.5 — reads the cycle's evidence artifacts and appends to `lessons-learned.md`). Canonical rule: `docs/millwright-inspector-project.md` §8.15.

**Stage 8 finalizer.** Archives the blueprint into `history/`, clears the implementation folder, resets `progress.md`, and advances the workflow queue to the next feature.

**Main-read budget (stage 8).** Allowed in main: `change-summary.md` (cached), archived blueprint files. The current implementation only rotates and archives — there is no codebase regeneration walk at stage 8 (the next feature's stage 2 builds the next `current/`). The one delegated read set is Step 3.5's lessons distillation: the `lessons-distiller` sub-agent reads the cycle's evidence artifacts (inspector-review, review-history, manual-test results, decisions) and appends to `lessons-learned.md`; main never reads those files here. If a future change introduces stage-8 regeneration, it should likewise be delegated to a fresh sub-agent per Phase 2.1's pattern. See `docs/millwright-inspector-project.md` § "Main-read budget gates by stage" for the canonical table.

## Invocation

The millwright auto-invokes this command on **stage-7 clean exit** — that is, immediately after the `/mi-continue` handler sets `inspector-review-completed=true` and advances `active.current-stage` to 7. (Stage 8 is conceptual — it names the finalizer phase but is not a persisted `active.current-stage` value; this command's `progress.sh finish` call sets `active=null` rather than incrementing the stage counter to 8.) The inspector does **not** type `/mi-complete-workflow` in the happy path; reaching stage 7 is itself the signal.

The command remains manually invokable for recovery — e.g. when `/mi-resume-workflow` recommends it because an auto-fire was interrupted.

## Preconditions

- `inspector-review-completed` is `true` in `progress.md` (stage 7 has exited clean).

## Execution

### Step 0 — Top-of-command branch dispatch

Before running the normal forward path, check for in-flight rotation states (a prior `/mi-complete-workflow` invocation may have been interrupted) and post-finish recovery states (the rotation completed but Step 7 housekeeping was interrupted). Four branches (one of which is the normal path):

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
active_feature="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get-active 2>/dev/null || echo 'null')"

# Helper: read latest finalized v[N] under a feature's history.
latest_finalized_version() {
  local feat="$1"
  local hist="$data_root/workflow-stream/$feat/blueprints/history"
  [[ -d "$hist" ]] || { echo ""; return; }
  ls -d "$hist"/v[0-9]* 2>/dev/null \
    | grep -vE '\.(partial|partial\.tmp)$' \
    | sed -n 's|.*/v\([0-9]\+\)$|\1|p' \
    | sort -n | tail -1
}

# Helper: read latest finalized v[N]/reason.md.kind.
latest_reason_kind() {
  local feat="$1"
  local v
  v="$(latest_finalized_version "$feat")"
  [[ -n "$v" ]] || { echo ""; return; }
  $CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get \
    "$data_root/workflow-stream/$feat/blueprints/history/v${v}/reason.md" kind \
    2>/dev/null || echo ""
}

# Helper: count partial directories for a feature; print the single one if exactly one exists.
single_partial() {
  local feat="$1"
  local hist="$data_root/workflow-stream/$feat/blueprints/history"
  [[ -d "$hist" ]] || { echo ""; return; }
  local matches
  matches=$(ls -d "$hist"/v[0-9]*.partial 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$matches" == "1" ]]; then
    ls -d "$hist"/v[0-9]*.partial 2>/dev/null
  fi
}
```

**Branch 0a — in-flight rotation matching completion.** If `active != null` AND there is exactly one `v[K].partial/` for `active.feature` AND its `reason.md.kind == "completion"`, the prior invocation crashed mid-rotation. Resume the rotation, skip Steps 1–4, and proceed to Step 5 onward. (Step 5 archival uses `mv -n` and is already idempotent — re-entry picks up cleanly even when Step 5 landed some artifacts before the prior crash.)

```bash
if [[ "$active_feature" != "null" && -n "$active_feature" ]]; then
  partial_dir="$(single_partial "$active_feature")"
  if [[ -n "$partial_dir" ]]; then
    partial_kind="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$partial_dir/reason.md" kind 2>/dev/null || echo "")"
    if [[ "$partial_kind" == "completion" ]]; then
      version="$($CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh resume-partial "$active_feature" --expected-kind completion)"
      echo "Resumed in-flight completion rotation: history/v${version}/"
      branch_route="0a"  # remembered so we know to skip Steps 1-4
    elif [[ -n "$partial_kind" ]]; then
      # Branch 0b — different-kind partial blocks completion rotation.
      echo "error: completion rotation refused — a $partial_kind rotation is already partial at $partial_dir." >&2
      echo "Finish or abandon that rotation first (run the command that owns its kind, or repair manually)." >&2
      exit 1
    fi
  fi
fi
```

**Branch I — post-finish recovery (active=null).** If `active == null` AND `progress.completed` is non-empty AND the latest finalized history version for `completed[-1]` has `reason.kind == "completion"`, then rotation + `progress.sh finish` ran but the housekeeping (Step 7) was interrupted. Reconstruct `active_feature` from `completed[-1]` and `remaining` from the queue, skip Steps 1–6, and run Step 7 only. Do NOT call `progress.sh get` for active fields in this branch (active is null).

```bash
if [[ "$active_feature" == "null" || -z "$active_feature" ]]; then
  completed_last="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh queue-remaining 2>/dev/null >/dev/null; \
    python3 -c "
import sys, re, yaml
with open('$data_root/quest/active.md') as f:
    slug = yaml.safe_load(f.read().split('---')[1]).get('slug')
import os
prog = '$data_root/quest/' + slug + '/progress.md'
with open(prog) as f:
    fm = yaml.safe_load(f.read().split('---')[1])
completed = fm.get('completed') or []
print(completed[-1] if completed else '')
")"
  if [[ -n "$completed_last" ]]; then
    last_kind="$(latest_reason_kind "$completed_last")"
    if [[ "$last_kind" == "completion" ]]; then
      active_feature="$completed_last"
      branch_route="I"
      echo "Branch I: post-finish recovery for $active_feature; running Step 7 housekeeping only."
    fi
  fi
  if [[ "${branch_route:-}" != "I" ]]; then
    echo "error: /mi-complete-workflow requires an active feature, but progress.md.active is null and no Branch I recovery condition was met. Run /mi-continue or /mi-resume-workflow for diagnosis." >&2
    exit 1
  fi
fi

# Verify inspector-review-completed only on the normal path (Branches 0a, II, III need it;
# Branch I has active=null so the guard is skipped).
if [[ "${branch_route:-III}" != "I" ]]; then
  oc="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get inspector-review-completed 2>/dev/null || echo 'false')"
  [[ "$oc" == "true" ]] || { echo "error: inspector-review not complete; run /mi-continue first" >&2; exit 1; }
fi
```

**Branch II — in-flight rotation already done (active!=null, finalized vN/).** If `active != null` AND `blueprints/current/requirements.md` is missing AND the latest finalized history version for `active.feature` has `reason.kind == "completion"`, the rotation completed but Step 5 (or later) was interrupted. Set `$version=N` and proceed Step 5 → 6 → 7.

```bash
if [[ "${branch_route:-}" == "" && "$active_feature" != "null" ]]; then
  if [[ ! -f "$data_root/workflow-stream/$active_feature/blueprints/current/requirements.md" ]]; then
    last_kind="$(latest_reason_kind "$active_feature")"
    if [[ "$last_kind" == "completion" ]]; then
      version="$(latest_finalized_version "$active_feature")"
      branch_route="II"
      echo "Branch II: rotation already done at history/v${version}/; resuming from Step 5."
    fi
  fi
fi
```

**Branch III — normal forward path.** Falls through to Step 1 below. Before Step 4's completion rotate, the normal path runs `blueprints.sh check-current --require-primer "$active_feature"` and requires `0` (completion rotation must never archive a current/ tree that is missing the stage-3 primer; see Item 9 of the v11 progress-gap plan).

**Mode detection.** Every downstream step needs to know whether `$active_feature` is this cycle's declared feature-test entry, so resolve it once here:

```bash
if $CLAUDE_PLUGIN_ROOT/scripts/todo.sh is-feature-test "$active_feature"; then
  ft_mode=1
else
  ft_mode=0
fi
```

**Feature-test entries take a substituted Branch III.** Of the four blueprint-dependent steps, two are kept from a different source and two are skipped:

| Step | Ordinary | Feature-test (`ft_mode=1`) |
| --- | --- | --- |
| 2 — IMPLEMENTING → IMPLEMENTED | runs | runs (its own item) |
| 3 — commits list | `commits.sh populate-requirements` → `requirements.md` | `commits.sh populate-feature-test` → the entry's `change-summary.md` |
| 3.5 — lessons distillation | evidence keyed by requirements id | evidence = the entry's `inspector-review.md` + `test/manual-test-results.md` |
| 4 — `check-current --require-primer` preflight | must return 0 | **skipped** — nothing to assert without a blueprint, and it would only block closure |
| 4 — `blueprints.sh rotate` | runs | **skipped** |
| 5 — `implementation/` archive move | runs | **skipped** — permanent in place (`FTW-002`) |
| 6 — `progress.sh finish` | runs | runs |
| 7 — housekeeping | runs | runs |

Lessons distillation is deliberately **kept**: the whole-feature test is the only point in the cycle that observes the features working together, which makes it the highest-value lesson source in the run. Its `source_prefix` uses the entry's `change-summary.md` `id` in place of a requirements id, preserving the re-append fence.

**Step 0 needs no change.** `current/requirements.md` is always absent for this folder and there is no history, so `latest_reason_kind` returns empty, Branch II does not match, and control reaches Branch III correctly.

### Step 1 — Resolve inputs

(Skipped when `branch_route` is `0a`, `I`, or `II`.)

```bash
if [[ "${branch_route:-III}" == "III" ]]; then
  : "${active_feature:?already resolved above}"

  # Verify inspector-review-completed (re-checked here for the normal path).
  oc="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get inspector-review-completed)"
  [[ "$oc" == "true" ]] || { echo "error: inspector-review not complete; run /mi-continue first" >&2; exit 1; }
fi
```

The chain's plan / spec files under `docs/superpowers/` are not touched by this command — those artefacts belong to the brainstorming chain, not the mi-workflow. Cross-referencing between requirements and commits lives in `requirements.md`'s `commits:` field (populated below).

### Step 2 — Transition todos IMPLEMENTING → IMPLEMENTED

(Skipped on Branch I — the prior invocation already ran this before the housekeeping interruption.)

```bash
if [[ "${branch_route:-III}" == "III" || "${branch_route:-}" == "0a" || "${branch_route:-}" == "II" ]]; then
  $CLAUDE_PLUGIN_ROOT/scripts/todo.sh bulk-transition IMPLEMENTING IMPLEMENTED --feature "$active_feature"
fi
```

The `--feature` filter scopes the transition to items under the active feature's section header only, so sibling features still mid-flight in a multi-feature queue are not touched.

### Step 3 — Populate commits in requirements.md

(Skipped on Branch I.)

```bash
if [[ "${branch_route:-III}" == "III" || "${branch_route:-}" == "0a" || "${branch_route:-}" == "II" ]]; then
  if [[ "$ft_mode" == "1" ]]; then
    # Feature-test entries have no requirements.md; the union commit range
    # lands in the entry's own change-summary.md instead (Task 5).
    $CLAUDE_PLUGIN_ROOT/scripts/commits.sh populate-feature-test "$active_feature"
  else
    $CLAUDE_PLUGIN_ROOT/scripts/commits.sh populate-requirements "$active_feature"
  fi
fi
```

### Step 3.5 — Distill workflow lessons into `lessons-learned.md`

(Only runs on Branch III. Branches 0a, I, and II re-enter *after* a prior invocation already passed through this step — the idempotency guard below would skip it anyway, but the branch gate keeps recovery paths cheap.)

Every completed workflow funnels through this command — both the findings path (6→7→8) and the no-findings auto-finalize path (5→7→8) — so this is the single point where the finished cycle's evidence gets distilled into cumulative lessons for future cycles. It must run **before Step 4's rotation** so the evidence artifacts are still at their live paths (`blueprints/current/`, `implementation/`).

Main does NOT read the evidence artifacts (stage-8 main-read budget) — the reads are delegated to the `lessons-distiller` sub-agent, symmetric to stage 2's `lessons-filter` (filter reads lessons at cycle start; distiller writes them at cycle end).

```bash
if [[ "${branch_route:-III}" == "III" ]]; then
  lessons_path="$($CLAUDE_PLUGIN_ROOT/scripts/lessons.sh path)"

  if [[ "$ft_mode" == "1" ]]; then
    # Feature-test entries have no requirements.md to key evidence off; the
    # entry's own change-summary.md id substitutes (Step 3 above already
    # populated it), preserving the same re-append-fence shape.
    req_path="$data_root/workflow-stream/$active_feature/implementation/change-summary.md"
    req_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$req_path" id 2>/dev/null || echo "")"
    # frontmatter.sh get exits 0 and prints the literal "null" for an absent
    # field — never test presence by exit code, test the value.
    [[ "$req_id" == "null" ]] && req_id=""
  else
    req_path="$data_root/workflow-stream/$active_feature/blueprints/current/requirements.md"
    req_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$req_path" id 2>/dev/null || echo "")"
  fi
  source_prefix="workflow:$active_feature/$req_id"

  if [[ -z "$req_id" ]]; then
    echo "warning: could not resolve requirements-id from $req_path; skipping lessons distillation" >&2
  elif grep -qsF "$source_prefix" "$lessons_path"; then
    # Idempotency guard: a crash between Step 3.5 and Step 4 re-enters Branch III;
    # lessons.sh append has no dedup, so the source-prefix grep is the re-append fence.
    echo "info: lessons already distilled for $source_prefix; skipping (idempotent re-entry)"
  else
    impl_dir="$data_root/workflow-stream/$active_feature/implementation"

    if [[ "$ft_mode" == "1" ]]; then
      # Feature-test entries substitute a narrower evidence set (contract
      # table above): the entry's own inspector-review.md and
      # test/manual-test-results.md — no review-history.md, decisions.md,
      # change-summary.md (its id was already read above), or
      # grounding-report.md, since the entry has no blueprint and no
      # grounding pass. The whole-feature test is the only point in the cycle
      # that observes the previously separate features working together,
      # which makes these two files the highest-value lesson source in the run.
      #
      # Sub-agent: agents/lessons-distiller.md (subagent_type:
      # millwright-inspector-development-machine:lessons-distiller).
      #
      # Spawn prompt template (ft_mode=1 — same sub-agent, substituted inputs):
      #
      #   You are invoked from /mi-complete-workflow's Step 3.5. The
      #   feature-test entry "<active_feature>" just completed. Distill at
      #   most 5 generalizable lessons from its own evidence artifacts and
      #   append them to <lessons_path> via <plugin>/scripts/lessons.sh
      #   append. Every --source you write MUST begin with "<source_prefix>"
      #   verbatim. Zero lessons is a valid outcome. Follow
      #   agents/lessons-distiller.md exactly.
      #
      #   Inputs:
      #   - active_feature: <active_feature>
      #   - source_prefix: <source_prefix>
      #   - lessons_path: <lessons_path>
      #   - plugin scripts dir: $CLAUDE_PLUGIN_ROOT/scripts
      #   - inspector_review_path: <impl_dir>/inspector-review.md
      #   - manual_test_results_path: <data_root>/workflow-stream/<active_feature>/test/manual-test-results.md
      #   (Missing evidence files are normal — tolerate silently.)
      #
      #   Return per the sub-agent's return contract.
      :
    else
      # Spawn the lessons-distiller sub-agent. The prompt below substitutes the
      # placeholders with the concrete values from this caller context.
      #
      # Sub-agent: agents/lessons-distiller.md (subagent_type:
      # millwright-inspector-development-machine:lessons-distiller).
      #
      # Spawn prompt template:
      #
      #   You are invoked from /mi-complete-workflow's Step 3.5. The workflow for
      #   feature "<active_feature>" just completed. Distill at most 5
      #   generalizable lessons from the cycle's evidence artifacts and append
      #   them to <lessons_path> via <plugin>/scripts/lessons.sh append. Every
      #   --source you write MUST begin with "<source_prefix>" verbatim. Zero
      #   lessons is a valid outcome. Follow agents/lessons-distiller.md exactly.
      #
      #   Inputs:
      #   - active_feature: <active_feature>
      #   - source_prefix: <source_prefix>
      #   - lessons_path: <lessons_path>
      #   - plugin scripts dir: $CLAUDE_PLUGIN_ROOT/scripts
      #   - inspector_review_path: <impl_dir>/inspector-review.md
      #   - review_history_path: <data_root>/workflow-stream/<active_feature>/blueprints/current/review-history.md
      #   - manual_test_results_path: <data_root>/workflow-stream/<active_feature>/test/manual-test-results.md
      #   - decisions_path: <data_root>/workflow-stream/<active_feature>/decisions.md
      #   - change_summary_path: <impl_dir>/change-summary.md
      #   - grounding_report_path: <impl_dir>/grounding-report.md
      #   (Missing evidence files are normal — tolerate silently.)
      #
      #   Return per the sub-agent's return contract.
      :
    fi
  fi
fi
```

**Distillation is best-effort — it never blocks completion.** On a `blocked` / `partial` return (or a sub-agent failure), log one warning line, mention it in the Step 7 completion report, and proceed to Step 4. `lessons.sh append` self-validates after every write, so a bad append fails inside the sub-agent's turn, not downstream. On `success`, relay the appended count (from the return's `Artifacts changed` line) in the completion report — do not re-read `lessons-learned.md` in main.

### Step 4 — Rotate blueprints/current → history/v[N+1]

(Only runs on Branch III. Branch 0a's `version` was set by `blueprints.sh resume-partial`; Branch II's `version` was set by the Branch II detection.)

```bash
if [[ "${branch_route:-III}" == "III" ]]; then
  if [[ "$ft_mode" == "1" ]]; then
    # Feature-test entries skip the check-current --require-primer preflight
    # and blueprints.sh rotate entirely: there is no blueprints/current/ for
    # this folder to check or rotate (FTW-002 — no rotation is possible or
    # needed), and running the preflight would only block closure with
    # nothing to assert.
    echo "Feature-test entry: rotation skipped (no blueprint to rotate)."
  else
    # Preflight (Item 9 + Item 6): completion rotate must NEVER archive a current/
    # tree that is missing the stage-3 primer. Refuse with a diagnostic if so.
    if "$CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh" check-current --require-primer "$active_feature"; then
      cc_status=0
    else
      cc_status=$?
    fi
    if [[ "$cc_status" != "0" ]]; then
      echo "error: blueprints/current is incomplete (check-current --require-primer returned $cc_status). Completion rotation refused — repair current/ (regenerate primer.md, ensure all artifacts validate) before re-running /mi-complete-workflow." >&2
      exit 1
    fi
    version="$($CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh rotate "$active_feature" \
      --reason-kind completion \
      --reason-summary "completed at stage 8 for $active_feature")"
    echo "Blueprints archived into history/v${version}"
  fi
fi
```

### Step 5 — Archive implementation/ into the rotated history version

(Skipped on Branch I. Idempotent for Branch 0a re-entry — `mv -n` refuses to overwrite, so artifacts already moved on a prior partial run stay put.)

Stage 4 rotated `blueprints/current/` into `blueprints/history/v${version}/`. The just-finished implementation artifacts (`inspector-review.md`, `review-context.md`, `change-summary.md`, `grounding-report.md`, and `diagrams/`) are part of the same audit record, so move them into a sibling `implementation/` subfolder under the new history version. This preserves every finding (including any `status: open` ones the inspector chose to defer), the stage-2 grounding report, and the diagrams of `base-commit..HEAD` for posterity. The live `implementation/` folder is then empty and the next feature's stage-2 launcher re-creates children there.

**Manual-test artifacts are NOT archived here.** Per `docs/manual-testing-folder/plan.md`, `workflow-stream/<feature>/test/` is **feature-permanent** — it survives stage 8 alongside `decisions.md` so the next cycle on the same feature can reuse the prior plan and inherit its `seed-family-id` for cross-cycle seed idempotency. The `test/` folder is intentionally absent from the archive loop below.

```bash
if [[ "${branch_route:-III}" == "III" || "${branch_route:-}" == "0a" || "${branch_route:-}" == "II" ]]; then
  if [[ "$ft_mode" == "1" ]]; then
    # Feature-test entries skip the archive move entirely: there is no
    # rotated history/v${version}/ to move into (Step 4 skipped rotation),
    # and both children (implementation/, test/) are permanent in place for
    # this folder (FTW-002) — nothing to archive, nothing to leave behind.
    echo "Feature-test entry: implementation/ archive skipped (permanent in place)."
  else
    impl_dir="$data_root/workflow-stream/$active_feature/implementation"
    archive_dir="$data_root/workflow-stream/$active_feature/blueprints/history/v${version}/implementation"
    mkdir -p "$archive_dir"

    # Move each artifact if it exists. Using `mv -n` keeps it idempotent if the
    # command is re-invoked after a partial run; mv would otherwise refuse to
    # overwrite an existing target.
    #
    # Lazy archival validation (Phase 5.5 of the context-optimization plan):
    # `mv` is a filesystem operation, not an Edit/Write — the PostToolUse hook
    # does NOT fire frontmatter validation on moved files. Archived files are
    # treated as immutable and frozen post-rotation, so re-validation would be
    # noise. The live counterparts were validated when written; if a post-write
    # tampering happened before rotation, that's a different problem from
    # archival. Do not add explicit `frontmatter.sh validate` calls here.
    #
    # Manual-test artifacts (manual-test-plan.md, manual-test-results.md,
    # manual-test-plan.history/, manual-test-results.history/) live under
    # the sibling `test/` folder, which is feature-permanent and NOT
    # archived here. See docs/manual-testing-folder/plan.md.
    for artifact in inspector-review.md review-context.md change-summary.md grounding-report.md blueprint-lessons.md; do
      [[ -e "$impl_dir/$artifact" ]] && mv -n "$impl_dir/$artifact" "$archive_dir/$artifact"
    done
    [[ -d "$impl_dir/diagrams" ]] && mv -n "$impl_dir/diagrams" "$archive_dir/diagrams"
    # Leave the implementation/ folder itself in place (empty) — next workflow re-creates children.
  fi
fi
```

The historical snapshot is then complete: `blueprints/history/v${version}/` carries the rotated `requirements.md`, `config.md`, `diagrams/`, `primer.md`, `reason.md`, the v1.5 `review-history.md` (rotated along with the blueprint by the wildcard `blueprints.sh rotate` move at Step 4), AND `implementation/` (review file, review-context, change-summary, grounding-report, blueprint-lessons, implementation diagrams). PMs querying past cycles can read the full audit trail from this single folder per feature-version — including every codex finding ever raised on that blueprint version via `review-history.md`. The feature's manual-test history lives separately under `workflow-stream/<feature>/test/` and persists across cycles.

### Step 6 — Finish the active feature

(Skipped on Branch I — `progress.sh finish` already ran in the prior invocation that left active=null. Re-running it would error: require_active rejects null active.)

Archive the active feature into `completed` and set `active` to null. Under the two-step activation model, `/mi-apply-impact` will activate the next feature from the queue when it's invoked next.

```bash
if [[ "${branch_route:-III}" == "III" || "${branch_route:-}" == "0a" || "${branch_route:-}" == "II" ]]; then
  $CLAUDE_PLUGIN_ROOT/scripts/progress.sh finish >/dev/null
fi
remaining="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh queue-remaining 2>/dev/null || echo '')"
```

**Atomic finalize affordance (Phase 5.5).** `progress.sh finish` accepts optional `--set field=value` pairs (mirroring `advance-to`) so future stage-8 logic that needs to write a top-level `progress.md` field at finalize time can bundle the write atomically:

```bash
# Example (no current call site uses this — affordance is reserved for future):
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh finish --set last-completion=$(date -u +%Y-%m-%dT%H:%M:%SZ)
```

The `--set` writes target top-level fields only; setting `active.*` is rejected because `active` is being cleared. Do NOT introduce `advance-to 7 -1` as a finalize mechanism — `advance-to` only permits the whitelisted `3→5 | 5→7 | 6→7` transitions; stage-7 finalization stays on `progress.sh finish`.

### Step 7 — Report and auto-continue

(Runs on every branch including Branch I — this is the housekeeping that Branch I exists to recover.)

If `remaining` is empty, check whether unmarked TODO items still exist in the cycle's `todo-list.md`. If so, the inspector can extend this cycle by marking more items rather than running `/mi-run` from scratch:

```bash
todo_count="$($CLAUDE_PLUGIN_ROOT/scripts/todo.sh list TODO 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
```

- **If `todo_count > 0`:**

  Resolve the active quest's todo-list path for the user-facing message:

  ```bash
  active_quest_dir="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh dir)"
  ```

  > "Workflow for `$active_feature` complete. Queue is now empty, but **$todo_count items still in `[ ] TODO`** state in `$active_quest_dir/todo-list.md`. To continue this cycle, mark the items you want next (`[x] (assignee) TODO — ...`) and type `/mi-continue` — I'll promote them to PENDING, enqueue their features, and resume from stage 1.5. Or run `/mi-run <folders> --archive-active` to retire this cycle (preserved as a historical subfolder under `quest/`) and start a brand-new one."

  Stop here; the Pre-flight Handler in `mi-continue.md` (active=null, queue_count=0, `[x] TODO` lines present) takes over once the inspector marks items and types `/mi-continue`. It uses `progress.sh enqueue` to repopulate the queue without calling `progress.sh init` (which would refuse because `progress.md` already exists). The active-quest pointer stays `active`; this is still the same cycle.

- **If `todo_count == 0`:**

  The cycle is fully complete — every item the inspector marked has shipped, and nothing else is queued. Archive the active-quest pointer so a fresh `/mi-run` can open a new cycle without `--archive-active`. The cycle's subfolder under `quest/<slug>/` stays intact as a historical record.

  ```bash
  finished_slug="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh current 2>/dev/null || echo "")"
  $CLAUDE_PLUGIN_ROOT/scripts/quest.sh end
  ```

  > "Workflow for `$active_feature` complete. Queue empty and no TODO items remain. Cycle `$finished_slug` is now archived (subfolder preserved under `quest/$finished_slug/` for future reference). Run `/mi-run <folders>` for a new cycle."

  Stop here; nothing else to do.

  **The closure itself is the shipped one, unmodified.** No second completion path is
  introduced: the feature-test entry reaches the same `todo_count == 0` → `quest.sh end`
  branch every final feature reaches. Because the entry is pinned last, its completion is
  what empties the queue, so the cycle closes in one pass.

If `remaining` is non-empty, the first line is the next feature:

```bash
next="$(printf '%s\n' "$remaining" | head -1)"
```

#### Step 7.1 — Final `decisions.md` write-check on the just-finished feature

Per `docs/clear-points/plan.md` §3.2 and §5.2 (mi-complete-workflow section), this is the **last chance** to capture verbal decisions about feature `$active_feature` before main context gets cleared at the gate (Step 7.2 below). The file itself stays at `workflow-stream/$active_feature/decisions.md` permanently per §9.2 — it's NOT rotated into history — but anything not yet WRITTEN to it before the clear is gone.

Review the last several turns of conversation for instructions, scope decisions, or constraints about feature `$active_feature` that aren't captured verbatim in its blueprint or `inspector-review.md`. Append them as bullets to the relevant `## Stage <N>` section of `$data_root/workflow-stream/$active_feature/decisions.md`. If the file doesn't exist (no decisions ever recorded for this feature), skip — there's nothing to capture and creating an empty file adds noise.

#### Step 7.2 — Clear-point gate (`stage-8-to-2`)

Per `docs/clear-points/plan.md` §3.2, recommend a `/clear` between feature A's completion and feature B's activation. Unlike the `stage-2-to-3` and `stage-5-to-6` gates, this one needs **no persistence flag** — the post-clear state (`active=null`, queue non-empty) only happens once per feature transition by construction (`mi-apply-impact` immediately repopulates `active`), so the dispatcher cannot accidentally re-prompt.

```bash
$CLAUDE_PLUGIN_ROOT/scripts/ledger.sh append \
  "8" "/mi-complete-workflow" "clear-offer-recommendation" "small" "main" \
  "stage-8-to-2 clear offered (${active_feature} -> ${next})" || true
```

Then print the recommendation block to the inspector and **halt** — do NOT auto-fire `/mi-apply-impact`:

> "Workflow for `$active_feature` complete. Queue continues with `$next`.
>
> **Recommended:** type `/clear`, then `/mi-continue` to start `$next` with a fresh main context. Nothing from `$active_feature` is needed for `$next`:
> - `$active_feature`'s blueprint history is preserved at `workflow-stream/$active_feature/blueprints/history/v[N+1]/`.
> - `$active_feature`'s decisions log persists at `workflow-stream/$active_feature/decisions.md` (feature-scoped, never archived).
> - `$next`'s `workflow-stream/$next/` will be created fresh by `mi-apply-impact` after the clear.
>
> Skip the clear (just type `/mi-continue` without clearing) if you want to carry verbal context across — rare; the feature boundary is usually the cleanest moment to clear in the entire cycle."

Then exit. The inspector's next `/mi-continue` re-enters the dispatcher with `active=null` and `queue` non-empty, which Row A in the dispatch table matches and auto-fires `/mi-apply-impact` for `queue[0]`. Row A's path is unchanged by this gate — it doesn't know about clear-recommendations and doesn't need to (the gate fired exactly once, before halt; re-entry just continues the existing Row A path).

**Why no `post-offer-resume` ledger row for this gate:** the dispatcher's Row A path is a generic "between features" handler that fires on every queue advance, including initial-cycle entry after `/mi-run` where there was no prior offer. Writing an unconditional `post-offer-resume` here would produce noise; writing a conditional one (only when the previous ledger row was a `clear-offered stage-8-to-2`) couples mi-apply-impact to ledger introspection. For analytics, pair `clear-offered stage-8-to-2` with the next feature's stage-2 rows — row order alone is enough.

If the inspector interrupts with a non-affirmative message before or during the next feature's stage 2 execution, defer to their instruction. Manual `/mi-apply-impact` invocation remains available.
