---
description: Generate blueprints/current/ for the active feature — requirements.md, config.md, and diagrams/. Stage 2 of the mo-workflow.
---

# mo-apply-impact

**Stage 2 launcher.** Pops the next feature off the queue, creates its `progress.md`, and generates the blueprint artifacts (requirements, config, diagrams).

**Main-read budget (stage 2).** Allowed in main: `summary.md` (active feature section + cross-cutting), generated artifacts. Forbidden in main: codebase grounding pass — delegated to a fresh sub-agent (Phase 2.1) which writes `implementation/grounding-report.md`. See `docs/workflow-spec.md` § "Main-read budget gates by stage" for the canonical table.

## Invocation

The millwright auto-invokes this command on two triggers — the overseer does **not** type it in the happy path:

1. **End of stage 1.5.** Immediately after the overseer types `/mo-continue` to confirm the prioritized queue order (the Pre-flight Handler in `commands/mo-continue.md` writes `queue-rationale.md`, runs `progress.sh reorder`, then auto-fires this command).
2. **End of stage 8 (queue loop).** After `mo-complete-workflow` archives the finished feature and leaves `active: null` with more features in the queue, the millwright re-enters at stage 2 for the next feature (soft announce-and-continue). This command calls `progress.sh activate` internally to pop `queue[0]` into a fresh `active` block.

The command is still invokable manually for recovery — for example after `/mo-abort-workflow` (to regenerate blueprints from scratch) or when `/mo-resume-workflow` explicitly recommends it.

## Preconditions

- The active cycle's `todo-list.md`, `summary.md`, and `progress.md` exist (from stage 1; under `quest/<active-slug>/`).
- The overseer has marked at least one todo item as `PENDING`.
- The overseer has confirmed the workflow queue order (or the previous feature has just finished via `mo-complete-workflow`, leaving `active: null` in `progress.md`).

## Execution

### Step 1 — Activate (or re-enter) the active feature

Three entry conditions, evaluated in order (Item 2 of the v11 plan):

1. **`active` is null** — pop `queue[0]` into a fresh `active` block (current-stage=2, branch=null, all other runtime fields default). This is the original happy path.
2. **`active.current-stage == 2`** — re-entering the same feature mid-stage-2 (e.g., a session break interrupted blueprint generation; the overseer re-runs `/mo-apply-impact` for the same feature). Skip activation and proceed to Step 2 with the existing `active.feature`. Surface `check-current` status so the overseer knows whether `current/` is already complete (`0` → short-circuit), partial (`2` → surface what's missing; offer `--force`), or empty (`1` → regenerate from scratch).
3. **`active.current-stage > 2`** — a different feature is mid-flight. Refuse: the overseer must run `/mo-abort-workflow` to clear it before re-running `/mo-apply-impact`.

```bash
active_feature_pre="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get-active 2>/dev/null || echo 'null')"

force_regen=0
for arg in $ARGUMENTS; do
  case "$arg" in
    --force) force_regen=1 ;;
  esac
done

if [[ "$active_feature_pre" == "null" || -z "$active_feature_pre" ]]; then
  active_feature="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh activate)"
  echo "Starting workflow for feature: $active_feature"
  $CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh ensure-current "$active_feature"
else
  current_stage="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get current-stage)"
  if [[ "$current_stage" != "2" ]]; then
    echo "error: feature '$active_feature_pre' is mid-flight at stage $current_stage. Run /mo-abort-workflow to clear before re-running /mo-apply-impact." >&2
    exit 1
  fi
  active_feature="$active_feature_pre"
  echo "Re-entering stage 2 for feature: $active_feature"
  $CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh ensure-current "$active_feature"

  # Inspect what's already there. check-current is in default mode (no
  # --require-primer): primer.md is not expected at stage 2.
  if "$CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh" check-current "$active_feature"; then
    cc_status=0
  else
    cc_status=$?
  fi
  case "$cc_status" in
    0)
      if [[ "$force_regen" != "1" ]]; then
        echo "blueprints/current is already complete for $active_feature. Skipping regeneration. Re-run with --force to regenerate from scratch, or type /mo-continue to advance to /mo-plan-implementation."
        exit 0
      fi
      echo "--force passed; regenerating despite check-current=0."
      ;;
    1)
      echo "blueprints/current is empty; regenerating from stage-2 inputs."
      ;;
    2)
      if [[ "$force_regen" != "1" ]]; then
        echo "warning: blueprints/current is partial (check-current=2). Inspect the existing files; re-run /mo-apply-impact --force to regenerate from scratch, or repair the files manually and type /mo-continue." >&2
        exit 1
      fi
      echo "--force passed; clearing partial current/ and regenerating."
      data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
      curr="$data_root/workflow-stream/$active_feature/blueprints/current"
      shopt -s dotglob nullglob
      for entry in "$curr"/*; do rm -rf "$entry"; done
      shopt -u dotglob nullglob
      $CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh ensure-current "$active_feature"
      ;;
  esac
fi
```

If the queue is empty AND `active` was null, `progress.sh activate` errors out — tell the overseer and stop. Branch is declared per-feature in `config.md`'s `## GIT BRANCH` section (written later in this command) and validated at stage 3; `/mo-plan-implementation` will persist it into `active.branch`.

### Step 2 — Regenerate `blueprints/current/` content

The content flow — write `requirements.md`, write `config.md` (auto-block + GIT BRANCH pre-fill), and generate diagrams — lives in [`docs/blueprint-regeneration.md`](../docs/blueprint-regeneration.md). Follow its Steps A, B, C with this caller context:

```bash
# Scope: PENDING items (first-time generation at stage 2).
active_item_ids="$($CLAUDE_PLUGIN_ROOT/scripts/todo.sh list PENDING --feature "$active_feature")"
```

Pass `$active_feature` and `$active_item_ids` through to the shared steps. The shared runbook handles: computing `$planned_ids`, initializing frontmatter, writing the three requirements body sections, scanning skills/rules for the config auto-block, pre-filling the GIT BRANCH section from HEAD, and rendering use-case/sequence/class diagrams with the PlantUML MCP.

### Step 3 — Hand off (no stage advance)

Do NOT call `progress.sh advance` here — `progress.sh activate` (Step 1) already set `current-stage=2`, which represents "blueprints generated, awaiting overseer approval." Stage 2 → 3 is owned by `/mo-plan-implementation` (which calls `progress.sh advance 2` after branch validation, todo promotion, and base-commit capture). Calling `advance 2` here would cause `/mo-plan-implementation` to fail with a stage mismatch on the next step.

Tell the overseer:

> "Blueprints generated for `$active_feature` at `workflow-stream/$active_feature/blueprints/current/`. Review `requirements.md`, `config.md`, and `diagrams/`. If adjustments are needed, edit the files directly — pay attention to `config.md`'s `## GIT BRANCH` section (declare the feature branch there if it isn't pre-filled). When ready, type **`/mo-continue`** — the Approve Handler in `mo-continue.md` will validate the blueprint files and auto-launch `mo-plan-implementation`."

Then stop and wait for the overseer to type `/mo-continue`. Do NOT auto-advance to stage 3 without that signal — this is the mandatory review gate. The Approve Handler in `commands/mo-continue.md` (current-stage = 2) handles the rest: blueprint sanity check, then auto-fire of `/mo-plan-implementation`.
