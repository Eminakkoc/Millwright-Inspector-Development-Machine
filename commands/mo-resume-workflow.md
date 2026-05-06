---
description: Diagnostic dispatcher — reads workflow state and prints the recommended next command. Does NOT mutate state.
---

# mo-resume-workflow

Use this when you're not sure where the workflow left off (e.g., after a session break).

The recommendations below include launcher commands (`/mo-apply-impact`, `/mo-plan-implementation`, `/mo-complete-workflow`) that **normally auto-fire** during the happy path. They only appear here as recommendations because `mo-resume-workflow` is a recovery tool — the auto-fire was interrupted or bypassed (e.g., by `/mo-abort-workflow`, or a session break that dropped the pending text-approval turn). Typing the recommended command manually is safe and re-joins the workflow.

## Execution

### Step 1 — Read progress.md

Resolve the active cycle's todo-list path through the active-quest pointer (errors if no cycle has been started — handled below).

```bash
active_quest_dir="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh dir 2>/dev/null || echo '')"
todo_file="${active_quest_dir:+$active_quest_dir/todo-list.md}"

# If there's no active cycle pointer at all, recommend /mo-run and stop.
if [[ -z "$active_quest_dir" ]]; then
  echo "No active quest cycle. Run /mo-run <folder1> [<folder2> ...] to start one."
  exit 0
fi

active_feature="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get-active)"
if [[ -z "$active_feature" || "$active_feature" == "null" ]]; then
  remaining="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh queue-remaining 2>/dev/null || echo '')"
  marked_count=0
  todo_count=0
  if [[ -f "$todo_file" ]]; then
    marked_count="$(grep -cE '^\s*-\s+\[[xX]\]\s+(\([^)]+\)\s+)?TODO' "$todo_file" || true)"
    todo_count="$($CLAUDE_PLUGIN_ROOT/scripts/todo.sh list TODO 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
  fi
  if [[ -z "$remaining" ]]; then
    if (( marked_count > 0 )); then
      echo "Active=null, queue empty, but $marked_count [x] TODO line(s) marked."
      echo "Recommended: /mo-continue (Pre-flight Handler will promote them and enqueue features)"
    elif (( todo_count > 0 )); then
      echo "Queue empty, but $todo_count item(s) still in [ ] TODO state in todo-list.md."
      echo "Mark the items you want next and type /mo-continue (or run /mo-run for a fresh cycle)."
    else
      echo "Queue is empty and no TODO items remain. Run /mo-run <folder1> [<folder2> ...] for a new cycle."
    fi
    exit 0
  else
    if (( marked_count > 0 )); then
      echo "Active=null, queue has $((1 + $(echo "$remaining" | wc -l))) entries, $marked_count selection(s) pending promotion."
      echo "Recommended: /mo-continue (Pre-flight Handler — Step 2A: promote, propose order)"
    else
      echo "Active=null, queue has pending entries."
      echo "Next: $remaining"
      echo "Recommended: /mo-continue (Pre-flight Handler — Step 2B: confirm and auto-fire /mo-apply-impact). /mo-apply-impact also remains directly invokable for recovery."
    fi
    exit 0
  fi
fi
```

### Step 2 — Read runtime state for the active feature

```bash
stage="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get current-stage)"
sub_flow="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get sub-flow)"
impl_done="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get implementation-completed)"
ov_done="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get overseer-review-completed)"
```

### Step 3 — Recommend based on state

| Stage | Sub-flow                                     | Recommendation                                                                                                   |
| ----- | -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| 0     | —                                            | Populate `journal/` first.                                                                                       |
| 1     | —                                            | `/mo-run <folder1> [<folder2> ...]`.                                                                             |
| 2     | none                                         | `/mo-continue` to advance (the Approve Handler validates blueprints and auto-fires `/mo-plan-implementation`). `/mo-plan-implementation` also remains directly invokable for recovery. |
| 3     | chain-in-progress                            | The brainstorming chain is live (planning-mode=brainstorming) — continue it in the current session; type `/mo-continue` when the chain returns. For planning-mode=direct, the millwright is implementing in the main session — type `/mo-continue` once commits exist. |
| 3     | chain-in-progress (but commits exist in `base-commit..HEAD`) | Type `/mo-continue` — the Resume Handler will run the abandoned-chain check (locates plan files written during this run, counts done/remaining checkboxes, and asks whether the chain finished cleanly or was interrupted; on `abandoned` it re-launches the chain with the existing plan/spec + commit log so it picks up where it left off). Alternatively `/mo-abort-workflow` to reset. |
| 4     | resuming                                     | `/mo-continue` (resume handler was interrupted; re-running it is idempotent).                                    |
| 5     | manual-testing                               | A manual-test run is paused or in progress (the dispatcher routes this through `/mo-continue`'s Manual-Test-Resume Handler). Type `/mo-continue` — the handler reads `manual-test-results.md` frontmatter and either auto-fires `/mo-manual-test-run` (Branch A) to resume the per-scenario loop, or auto-fires `/mo-manual-test-run --seed-only` (Branch B) when `state=complete && sub-flow=manual-testing` (mid-seed-crash recovery). |
| 5     | —                                            | Write findings to `overseer-review.md` (plain sentences are fine — the millwright canonicalizes them) and type `/mo-continue`. |
| 6     | reviewing                                    | The review session is live. Continue it in the current session; type `/mo-continue` when the session returns.    |
| 6     | reviewing (no `open` findings remain)        | Review session likely exited cleanly; type `/mo-continue` to advance.                                            |
| 6     | reviewing (with `open` findings remaining)   | Review session likely exited mid-loop; type `/mo-continue` — the Review-Resume Handler will prompt with `completed` (proceed with deferred findings), `abandoned` (re-launch via `/mo-review`), or `abort`. |
| 7     | — (overseer-review-completed = true)         | `/mo-complete-workflow` to finalize.                                                                             |
| 8     | —                                            | Workflow already completed. Check the queue for next feature via `/mo-apply-impact`.                             |

Print the recommendation as a single-line message, plus the state snapshot underneath for context. Do NOT modify any files.

### Step 4 — Invariant checks

Before printing the recommendation, verify:

- If `stage ≥ 3`, then `base-commit` must be non-null.
- If `stage ≥ 5`, then `implementation-completed` must be `true`.
- If `stage ≥ 7`, then `overseer-review-completed` must be `true`.

If any invariant is violated, print "State corruption detected" and recommend `/mo-abort-workflow` instead.

## Output format

```
Active feature: <name>
Current stage:  <N>
Sub-flow:       <value>
Flags:          impl=<bool> ovr=<bool>

Recommended next command: <command>
<optional one-line reason>
```
