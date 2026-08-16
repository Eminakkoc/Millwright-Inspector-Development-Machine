---
description: Safely cancel the active workflow — reverts IMPLEMENTING todos, clears implementation/, resets progress.md. Preserves blueprints/current/ and does NOT touch git.
argument-hint: "[--drop-feature=requeue]"
---

# mi-abort-workflow

**Runtime bootstrap.** Every `$CLAUDE_PLUGIN_ROOT` reference in this command's Bash blocks assumes a resolved plugin root; Claude Code does not inject the env var into Bash subshells. If it is empty in your shell, apply the canonical resolver (`docs/millwright-inspector-project.md` §8.14; reference implementation: `mi-continue.md` Step 1a) before the first Bash block: (1) inherited env var when it points at a working install, (2) `$PWD` when it is this plugin's source repo, (3) the `installPath` from `~/.claude/plugins/installed_plugins.json` — then export it, persist it to the per-cwd tempfile, and prepend the recovery one-liner to every subsequent Bash block. Refuse with an environmental diagnostic if none resolve.

Use when a workflow needs to be cancelled mid-flight — session crash, mind change, merge conflict, corrupted state.

> **Looking for `--drop-feature=completed`?** Removed. The flag was a partial shortcut — it set `progress.md.completed` but skipped the rest of stage 8 (no `commits:` field on `requirements.md`, no blueprint rotation, no archival of `implementation/` artifacts). The result was inconsistent state that violated the schema's contract that "completed" means stage 8 was reached. If a feature has actually shipped (commits exist in `base-commit..HEAD` and you're satisfied with them), run `/mi-complete-workflow` directly — that's the canonical, single-step finalizer. `/mi-abort-workflow` now only handles the genuinely-abort cases: requeue the feature, or retry it from stage 2.

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

If the feature has actually shipped, run /mi-complete-workflow directly
— that's the canonical finalizer. If you want to throw the feature
back on the queue or retry it, use --drop-feature=requeue (or no flag).
EOF
    exit 1
    ;;
  *) echo "error: unknown flag '$1' (expected --drop-feature=requeue or no flag)" >&2; exit 1 ;;
esac
```

```bash
if $CLAUDE_PLUGIN_ROOT/scripts/todo.sh is-feature-test "$active_feature"; then
  ft_mode=1
else
  ft_mode=0
fi
```

### Step 2 — Confirm with the inspector

```bash
echo "Active feature: $active_feature"
echo "Current stage:  $current_stage"
echo "This will:"
echo "  - revert IMPLEMENTING todos for the active feature back to PENDING"
[[ "$drop_mode" == "requeue" ]] && echo "  - move '$active_feature' to the end of progress.md.queue"
echo "  - delete implementation/ (inspector-review.md, review-context.md, change-summary.md, grounding-report.md, diagrams/)"
echo "  - preserve test/ (manual-test-plan.md, manual-test-results.md, manual-test-plan.history/, deferred-tests.md) — feature-permanent across cycles"
if [[ "$drop_mode" == "" ]]; then
  if [[ "${ft_mode:-0}" == "1" ]]; then
    echo "  - reset progress.md to the combined test's first step (the complete-feature diagram pass)"
  else
    echo "  - reset progress.md to a fresh stage-2 state (active.feature + active.branch preserved for retry)"
  fi
fi
echo "  - keep blueprints/current/ intact"
echo "  - keep the active quest cycle's subfolder under quest/<active-slug>/ intact (cycle stays open — abort only resets the active feature)"
echo "  - NOT touch git (branches and commits remain)"
read -p "Proceed? (y/n): " ans
[[ "$ans" == "y" ]] || exit 0
```

**Feature-test entries need no new abort mechanism.** The no-flag path runs
`progress.sh reset`, which sets `current-stage=2` — and for a feature-test entry stage 2
*is* the diagram pass (`/mi-continue`'s recovery branch). The reset lands on the pipeline's
genuine first step, so only the guidance text branches.

Retry semantics for `test/`:

- **`manual-test-plan.md` is preserved.** It derives from the cycle's `IMPLEMENTED` items
  and the committed code over the union range — neither of which an abort changes — so
  regenerating it would reproduce nearly the same file at real cost.
- **`manual-test-results.md` does not carry forward.** This needs no new code:
  `progress.sh reset` mints a fresh `activation-id`, and `/mi-manual-test-plan`'s §4.1
  cross-activation guard then rotates the stale results into
  `manual-test-results.history/` on the next invocation. Carrying partial verdicts forward
  is how a scenario silently counts as passed without anyone re-running it.
- **`deferred-tests.md` survives both abort shapes.** Aborting an *ordinary* feature targets
  `workflow-stream/$active_feature/implementation` and never touches the feature-test
  folder, so entries parked from that feature stay put. Aborting the *feature-test entry*
  deletes only its `implementation/` and preserves `test/` with the rest of the
  feature-permanent artifacts.

  Entries parked by a feature that was later aborted are **preserved, not auto-pruned**: on
  retry, re-deferring the same scenario upserts the same composite key and produces no
  duplicate, and an entry that is never re-deferred still merges as a runnable scenario.
  Over-inclusive rather than lossy is the correct direction here. Use
  `deferred-tests.sh remove <ft> <feature> <scenario>` when an entry is known to be obsolete.

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
rm -f "$impl_dir"/inspector-review.md
rm -f "$impl_dir"/review-context.md
rm -f "$impl_dir"/change-summary.md
rm -f "$impl_dir"/grounding-report.md
```

**`test/` is intentionally NOT deleted.** `workflow-stream/$active_feature/test/` (manual-test-plan.md, manual-test-results.md, manual-test-plan.history/, manual-test-results.history/, deferred-tests.md) is feature-permanent per `docs/manual-testing-folder/plan.md`. The next cycle on the same feature inherits the prior plan and runs the §4.1 cross-activation results auto-rotation on the next `/mi-manual-test-plan` invocation — that's the abort-retry-without-new-commits safety path, and it depends on the `test/` folder surviving abort.

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

- **`requeue`**: `> "Workflow aborted. '$active_feature' moved to the end of progress.md.queue. Next /mi-apply-impact will activate whatever is now at queue[0]."`
- **(no flag), feature-test entry**: `> "Combined test aborted. '$active_feature' is back at its first step. Type /mi-continue to re-run the complete-feature diagram pass. The existing manual-test plan is reused unchanged; the previous run's results will be rotated into history on the next plan invocation."`
- **(no flag), ordinary feature**: `> "Workflow aborted. '$active_feature' is back at stage 2 with blueprints preserved. Run /mi-plan-implementation to retry the chain, or /mi-apply-impact to regenerate the blueprint from scratch. (Auto-fire is suspended until you re-enter — both commands are safe to invoke manually here.)"`
