---
description: Safely cancel the active workflow — reverts IMPLEMENTING todos, clears implementation/, resets progress.md. Preserves blueprints/current/ and does NOT touch git.
argument-hint: "[--drop-feature=requeue]"
---

# mo-abort-workflow

Use when a workflow needs to be cancelled mid-flight — session crash, mind change, merge conflict, corrupted state.

> **Looking for `--drop-feature=completed`?** Removed. The flag was a partial shortcut — it set `progress.md.completed` but skipped the rest of stage 8 (no `commits:` field on `requirements.md`, no blueprint rotation, no archival of `implementation/` artifacts). The result was inconsistent state that violated the schema's contract that "completed" means stage 8 was reached. If a feature has actually shipped (commits exist in `base-commit..HEAD` and you're satisfied with them), run `/mo-complete-workflow` directly — that's the canonical, single-step finalizer. `/mo-abort-workflow` now only handles the genuinely-abort cases: requeue the feature, or retry it from stage 2.

## Execution

### Step 1 — Parse the drop-feature flag and validate

```bash
active_feature="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get-active)"
current_stage="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get current-stage)"
drop_mode=""
case "${1:-}" in
  --drop-feature=requeue)   drop_mode="requeue" ;;
  "")                       drop_mode="" ;;
  --drop-feature=completed)
    cat >&2 <<'EOF'
error: --drop-feature=completed has been removed.

It used to set progress.md.completed but skipped the rest of stage 8 (no
commits: field, no blueprint rotation, no archival of implementation/
artifacts). The result was inconsistent state.

If the feature has actually shipped, run /mo-complete-workflow directly
— that's the canonical finalizer. If you want to throw the feature
back on the queue or retry it, use --drop-feature=requeue (or no flag).
EOF
    exit 1
    ;;
  *) echo "error: unknown flag '$1' (expected --drop-feature=requeue or no flag)" >&2; exit 1 ;;
esac
```

### Step 2 — Confirm with the overseer

```bash
echo "Active feature: $active_feature"
echo "Current stage:  $current_stage"
echo "This will:"
echo "  - revert IMPLEMENTING todos for the active feature back to PENDING"
[[ "$drop_mode" == "requeue" ]] && echo "  - move '$active_feature' to the end of progress.md.queue"
echo "  - delete implementation/ (overseer-review.md, review-context.md, change-summary.md, grounding-report.md, diagrams/)"
[[ "$drop_mode" == "" ]]        && echo "  - reset progress.md to a fresh stage-2 state (active.feature + active.branch preserved for retry)"
echo "  - keep blueprints/current/ intact"
echo "  - keep the active quest cycle's subfolder under quest/<active-slug>/ intact (cycle stays open — abort only resets the active feature)"
echo "  - NOT touch git (branches and commits remain)"
read -p "Proceed? (y/n): " ans
[[ "$ans" == "y" ]] || exit 0
```

### Step 3 — Revert todos (active feature only)

Scope the revert to the active feature so other queued/in-flight features' todos aren't affected. (`bulk-transition` without `--feature` would touch every IMPLEMENTING line in the file — including any other feature mid-work, which is not what abort means.)

```bash
$CLAUDE_PLUGIN_ROOT/scripts/todo.sh bulk-transition IMPLEMENTING PENDING --feature "$active_feature"
```

### Step 4 — Clear implementation

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
impl_dir="$data_root/workflow-stream/$active_feature/implementation"
rm -rf "$impl_dir"/diagrams
rm -f "$impl_dir"/overseer-review.md
rm -f "$impl_dir"/review-context.md
rm -f "$impl_dir"/change-summary.md
rm -f "$impl_dir"/grounding-report.md
```

### Step 5 — Update progress.md based on `drop_mode`

```bash
case "$drop_mode" in
  requeue)
    # Feature did NOT ship — requeue appends to queue end and clears active.
    $CLAUDE_PLUGIN_ROOT/scripts/progress.sh requeue >/dev/null
    ;;
  "")
    # Retry: keep active.feature and active.branch; reset stage to 2.
    $CLAUDE_PLUGIN_ROOT/scripts/progress.sh reset
    ;;
esac
```

### Step 6 — Report

- **`requeue`**: `> "Workflow aborted. '$active_feature' moved to the end of progress.md.queue. Next /mo-apply-impact will activate whatever is now at queue[0]."`
- **(no flag)**: `> "Workflow aborted. '$active_feature' is back at stage 2 with blueprints preserved. Run /mo-plan-implementation to retry the chain, or /mo-apply-impact to regenerate the blueprint from scratch. (Auto-fire is suspended until you re-enter — both commands are safe to invoke manually here.)"`
