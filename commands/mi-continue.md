---
description: Universal advancement signal for the mi-workflow. Dispatches to the right handler for the current state — pre-flight (after marking todos / approving blueprints), post-chain resume, inspector-review, or post-review-session resume.
---

# mi-continue

**The single advancement signal the inspector types throughout the workflow.** Reads `progress.md` (and a few sibling files) for the current state, decides where we are, and runs the appropriate handler.

**Delegation contract.** This command REQUIRES the sub-agents listed below; §8.13's main-read budget forbids main from doing their work itself. **Invoking `/mi-continue` IS the user requesting them** — Claude Code's default "do not call the Agent tool unless the user requested it" (and any stricter house rule layered on it) does not reach a sub-agent this command names at the step that names it, so spawn them without asking for extra confirmation. The default still holds everywhere else: never spawn a sub-agent this command does not name, and never invent fan-out to parallelize a step main is supposed to run. If a named delegation genuinely cannot run (type unavailable, harness refusal), say so and stop — never silently do its work in main. Sub-agents: `dependency-mapper` (Pre-flight Step 4c — only when feature ordering is ambiguous), `pr-review-fixer` (PR-Review Apply Handler). Handlers that auto-fire another `mi-*` command inherit that command's own delegation contract. Canonical rule: `docs/millwright-inspector-project.md` §8.15.

The inspector types `/mi-continue` at every gate where they previously typed a free-form approval:

1. **After marking PENDING items** in the active cycle's `todo-list.md` (stage 1.5; lives under `quest/<active-slug>/todo-list.md`). Runs the Pre-flight Handler — promotes the marked items, analyzes feature dependencies, and proposes a workflow order.
2. **After accepting the proposed queue order** (stage 1.5, second invocation). Runs the Pre-flight Handler — writes the cycle's `queue-rationale.md`, reorders the queue, and auto-fires `/mi-apply-impact`.
3. **After reviewing the blueprint** (stage 2). Runs the Approve Handler — auto-fires `/mi-plan-implementation`.
4. **After the brainstorming chain has fully exited and returned control** (stage 3 → 4; the chain produced commits in `base-commit..HEAD`). Runs the Resume Handler — generates implementation diagrams and hands off to inspector review. **Do not type `/mi-continue` while the chain is mid-prompt** (e.g., while `finishing-a-development-branch` is asking for approval); answer the chain first.
5. **After writing findings into `inspector-review.md`** (stage 5; or leaving it empty to approve). Runs the Inspector Handler — auto-completes if there are no findings, or invokes `/mi-review` and returns control to the inspector.
6. **(only if findings were present)** **After the brainstorming review session has fully exited and returned control** (stage 6 → 7). Runs the Review-Resume Handler — offers a diagram refresh, sanity-checks findings, advances, and auto-fires `/mi-complete-workflow`. **Do not type `/mi-continue` while the review session is mid-prompt**; answer the chain first.

For any other workflow state, this command falls through to `/mi-resume-workflow` to give the inspector a state diagnosis instead of erroring out.

## Execution

### Step 1 — Read state

#### Step 1a — Resolve the plugin runtime (load-bearing)

Resolve `$CLAUDE_PLUGIN_ROOT` and verify the dispatcher's scripts are on disk. This must run **first**: the state-read fallbacks in Step 1b (`2>/dev/null || echo 'null'`) cannot distinguish "no active workflow" from "scripts unreachable" — without this check, an empty `$CLAUDE_PLUGIN_ROOT` would expand `$CLAUDE_PLUGIN_ROOT/scripts/progress.sh` to `/scripts/progress.sh`, silently fail with "command not found", and route the dispatcher to the pre-flight catch-all → `/mi-resume-workflow`, making it look like there's no active workflow when in fact the runtime is broken.

**Why the resolver exists** (canonically documented in `docs/millwright-inspector-project.md` §8.14 — this Step 1a is the reference implementation every other command's Runtime-bootstrap note points at). Claude Code does not currently inject `$CLAUDE_PLUGIN_ROOT` as a shell env var into Bash tool subshells (open feature request: anthropics/claude-code#48230); the variable is only template-expanded inside config files like `hooks.json`/`plugin.json`. The inherited env var is therefore best-effort — sometimes leaked by a prior hook invocation, often empty (especially right after `/clear`). The resolver below is the canonical source of `$CLAUDE_PLUGIN_ROOT` for this command and falls back through three sources in order: (1) the inherited env var when it points at a working `scripts/progress.sh`, (2) the cwd when it's this plugin's source repo (local dev mode), (3) the marketplace install path from `~/.claude/plugins/installed_plugins.json`. On success the resolved path is exported AND persisted to a per-cwd tempfile so the rest of this invocation's Bash blocks can recover it (each Bash tool call is a fresh subshell that does NOT inherit exports from prior calls — see anthropics/claude-code#2508).

```bash
resolved=""
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -x "$CLAUDE_PLUGIN_ROOT/scripts/progress.sh" ]]; then
  resolved="$CLAUDE_PLUGIN_ROOT"
elif [[ -f "$PWD/.claude-plugin/plugin.json" ]] \
  && grep -q '"name": *"millwright-inspector-development-machine"' "$PWD/.claude-plugin/plugin.json" \
  && [[ -x "$PWD/scripts/progress.sh" ]]; then
  resolved="$PWD"
elif [[ -f "$HOME/.claude/plugins/installed_plugins.json" ]]; then
  candidate="$(python3 - <<'PYEOF' 2>/dev/null
import json, os
try:
    with open(os.path.expanduser('~/.claude/plugins/installed_plugins.json')) as f:
        d = json.load(f)
    for k, v in (d.get('plugins') or {}).items():
        if k.startswith('millwright-inspector-development-machine@') and v:
            print(v[0].get('installPath', ''))
            break
except Exception:
    pass
PYEOF
)"
  if [[ -n "$candidate" && -x "$candidate/scripts/progress.sh" ]]; then
    resolved="$candidate"
  fi
fi

if [[ -z "$resolved" ]]; then
  echo "error: cannot resolve plugin root for millwright-inspector-development-machine." >&2
  echo "       Tried in order: \$CLAUDE_PLUGIN_ROOT env var, \$PWD/.claude-plugin/plugin.json, ~/.claude/plugins/installed_plugins.json." >&2
  echo "       None of these point to a usable install (scripts/progress.sh must exist and be executable)." >&2
  exit 1
fi

export CLAUDE_PLUGIN_ROOT="$resolved"
mi_root_tag="$(printf '%s' "$PWD" | shasum -a 256 | cut -c1-16)"
printf 'export CLAUDE_PLUGIN_ROOT=%q\n' "$resolved" \
  > "${TMPDIR:-/tmp}/mi-plugin-root.${mi_root_tag}.sh"

echo "Step 1a: CLAUDE_PLUGIN_ROOT resolved to $resolved"
```

If the resolver fails, **stop**. Do not fall through to Step 1b, do not delegate to `/mi-resume-workflow`, do not print a state snapshot — the failure is environmental, not stateful, and any state-shaped output would mislead the inspector into debugging their workflow when the runtime is the problem.

**Per-block recovery (applies to every subsequent Bash invocation in this command).** Each Bash tool call is a fresh subshell that does NOT inherit the export from Step 1a. Prepend this one-liner to every subsequent Bash block in this command so the env var is restored from the tempfile written above:

```bash
[[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]] && source "${TMPDIR:-/tmp}/mi-plugin-root.$(printf '%s' "$PWD" | shasum -a 256 | cut -c1-16).sh" 2>/dev/null || true
```

If the tempfile is missing (e.g. someone jumped to a later step without running Step 1a first), the source is a no-op and the original symptom — `$CLAUDE_PLUGIN_ROOT/...` expanding to `/...` — reappears. That's intentional: Step 1a is the only entry point that's expected to produce the tempfile, and a missing tempfile means Step 1a was skipped.

#### Step 1b — Read workflow state

```bash
active_feature="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get-active 2>/dev/null || echo 'null')"
queue_count="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh queue-remaining 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
# todo-list.md lives inside the active quest cycle's subfolder; resolve via quest.sh.
quest_dir="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh dir 2>/dev/null || echo "")"
todo_file="$quest_dir/todo-list.md"
```

With Step 1a's guard in place, the `2>/dev/null || echo 'null'` fallbacks here only ever fire for legitimate state-missing conditions (no `progress.md` yet, no active cycle), never for runtime faults.

If `progress.md` (or `quest/active.md` / the active cycle subfolder) is missing, the calls fail — surface the error and stop (no recovery here; the inspector should run `/mi-run` first).

### Step 2 — Dispatch

#### Step 2.0 — PR-review pre-dispatch check (runs before the workflow router)

`/mi-analyze-review` produces PR-review reports that have no active quest, so they are routed here, **before** the workflow dispatch table below. Scan for any report awaiting the inspector:

```bash
pr_awaiting="$($CLAUDE_PLUGIN_ROOT/scripts/pr-review.sh find-awaiting 2>/dev/null || true)"
pr_report_count="$(printf '%s' "$pr_awaiting" | sed '/^$/d' | wc -l | tr -d ' ')"
```

`find-awaiting` is a no-op when `pr-reviews/` does not exist (it exits 0 with no output), and emits one TSV row — `<status>\t<pr-number>\t<report-path>` — per report whose frontmatter `status` is `awaiting-marks` or `partial`. An empty result must fall through cleanly to the workflow dispatch; it never aborts the command.

Branch on the count and on whether a workflow is active (`active_feature` from Step 1b). The four cases are **mutually exclusive** — evaluate them in this order so the active-workflow case is never shadowed by the multi-report case:

1. **`pr_report_count == 0`** → fall through to the workflow dispatch unchanged.
2. **`active_feature != "null"` and `pr_report_count >= 1`** (active workflow *and* one-or-more PR-review reports) → ambiguous intent. `/mi-continue` never guesses. Print all candidates as a numbered list — the active feature/stage on one line, each PR-review report (status + PR number + path) on its own line — and ask the inspector to reply **in chat** (`workflow`, or a report's number). The command pauses for the reply, then routes: `workflow` → fall through to the dispatch table; a report → PR-Review Apply Handler with that report.
3. **`active_feature == "null"` and `pr_report_count == 1`** → route to the **PR-Review Apply Handler** with that report path.
4. **`active_feature == "null"` and `pr_report_count > 1`** → list the reports (status + PR number + path) as a numbered menu and ask the inspector to reply with a choice **in chat**; the command pauses for the reply, then routes the chosen report to the PR-Review Apply Handler.

The chat-reply pause is the same mid-command pause the Resume Handler's drift prompt uses — no new argument parsing on `/mi-continue` is needed.

#### Step 2 dispatch table

The dispatcher picks a handler based on whether a feature is active and, when active, on `current-stage` + `sub-flow`. Pre-flight cases (no active feature) live above the table:

**Pre-flight cases (`active_feature == "null"`):**

Order matters — Rows A/B (auto-fire) must be evaluated **after** the manual-action rows (the inspector's `[x] TODO` and queue-rationale-missing signals take precedence over auto-fire) and **before** the catch-all (otherwise they'd never run). See Item 5 of the v11 progress-gap plan for the load-bearing rationale.

| Condition | Handler |
| --- | --- |
| `[x] TODO` lines exist in `todo-list.md` (selections not yet promoted) | **Pre-flight Step 2A** — promote + propose order |
| no `[x] TODO` lines, `queue_count > 0`, `queue-rationale.md` missing | **Pre-flight Step 2B** — confirm proposed order + auto-fire `/mi-apply-impact` |
| no `[x] TODO` lines, `queue_count > 0`, `queue-rationale.md` present, top-level `status: draft` (Item 7 multi-batch) | **Pre-flight Step 2B** (extended) — confirm/update the latest batch, refresh top-level `features:`/`batch:`, flip `status` to `confirmed`, auto-fire `/mi-apply-impact` |
| **Row A — between features:** active is null AND `queue_count > 0` AND `queue-rationale.md.status` (or absent → confirmed) is `confirmed` AND `(queue-rationale.md.features − progress.completed, preserving order)` equals `progress.queue` exactly | Resolve `queue[0]`. If `todo.sh is-feature-test "$next"` exits 0, run `progress.sh activate` and then the **Feature-test entry sequence** above. Otherwise auto-fire `/mi-apply-impact` (unchanged). |
| **Row B — post-finish housekeeping recovery:** active is null AND queue empty AND no `[x] TODO` AND no `[ ] TODO` AND `progress.completed` non-empty AND `blueprints/history/v[N]/reason.md.kind == "completion"` for `completed[-1]` AND `quest/active.md.status == "active"` | Auto-fire `/mi-complete-workflow` (short-circuits to its Branch I — Step 7 housekeeping only) |
| `queue_count == 0` and no `[x] TODO` lines (catch-all) | Delegate to `/mi-resume-workflow` |

### Feature-test entry sequence (shared by Row A and the `2 | any` recovery branch)

Runs when the active — or about-to-be-active — feature is the cycle's feature-test entry.
It replaces stages 2 and 3 entirely: no blueprint is generated, approved, or planned.

**This sequence never calls `blueprints.sh ensure-current`.** That single omission is what
separates it from an ordinary activation, and it is why the branch cannot delegate to
`/mi-apply-impact` — see `docs/superpowers/specs/2026-08-14-feature-test-workflow-design.md`
§1.2.

```bash
# 1. Resolve and verify the union range BEFORE any mutation. Exit 3/4/5 are
#    refusals with their own diagnostics — relay and stop; nothing was written.
if ! range_line="$($CLAUDE_PLUGIN_ROOT/scripts/commits.sh feature-test-range "$ft_feature" 2>&1 | head -1)"; then
  echo "$range_line" >&2
  exit 1
fi
union_base="$(printf '%s' "$range_line" | cut -f1)"

# 2. Folder marker. NO ensure-current — this folder has no blueprints/.
$CLAUDE_PLUGIN_ROOT/scripts/folder-id.sh ensure "$ft_feature"

# 3. Pin the union base so the shipped freshness caches
#    (commits.sh change-summary-fresh / diagrams-fresh) work unchanged —
#    both key on .active.base-commit and HEAD.
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "base-commit=$union_base"
```

4. **Run the complete-feature diagram pass** — invoke `/mi-generate-implementation-diagrams`,
   which auto-detects the feature-test path (see that command's Step 1.5).

5. **Initialize the findings skeleton** (idempotent — `review.sh init` refuses to overwrite):

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
ov_file="$data_root/workflow-stream/$ft_feature/implementation/inspector-review.md"
[[ -f "$ov_file" ]] || $CLAUDE_PLUGIN_ROOT/scripts/review.sh init "$ft_feature"
```

6. **Atomic advance into the review step:**

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh advance-to 2 5 \
  --set sub-flow=none \
  --set implementation-completed=true
```

`implementation-completed=true` is **load-bearing, not cosmetic**. `/mi-resume-workflow`'s
Step 4 invariant asserts that any feature at stage ≥ 5 has it set; without it, every
`/mi-resume-workflow` on a feature-test entry would report "State corruption detected" and
recommend `/mi-abort-workflow`. It is also true on its face: the implementation is
complete — that is the premise of running a combined test at all.

7. **Hand off at stage 5** with the manual-test prompt, exactly as the stage-3 Resume
   Handler's Step 7 does. Answering `y` auto-fires `/mi-manual-test-plan --from-resume`,
   which takes its own feature-test derivation path.

**Not resumable.** An interruption before step 6 leaves the entry at stage 2 and the pass
re-runs from scratch on the next `/mi-continue`. Acceptable: the pass is idempotent and
derives entirely from committed state.

**Row A's feature-test branch.** `progress.sh activate` is called directly and stays
**byte-identical** — it keeps writing `current-stage=2` for every feature without
exception. Only the step *after* activation differs:

```bash
next="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh queue-remaining | sed '/^$/d' | head -1)"
if $CLAUDE_PLUGIN_ROOT/scripts/todo.sh is-feature-test "$next"; then
  ft_feature="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh activate)"
  # → run the Feature-test entry sequence above, then stop.
else
  # Ordinary feature: falls through to today's path, byte-identical.
  /mi-apply-impact
fi
```

For any feature that is not the cycle's feature-test entry, `is-feature-test` exits 1 and
control falls through to today's auto-fire unchanged. Ordinary features are unaffected.

**Active cases (`active_feature != "null"`):**

```bash
current_stage="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get current-stage)"
sub_flow="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get sub-flow)"
```

| Current stage | Sub-flow         | Handler                                                       |
| ------------- | ---------------- | ------------------------------------------------------------- |
| 2             | (any)            | `todo.sh is-feature-test "$active_feature"` → **Feature-test entry sequence** (recovery re-entry). Otherwise → **Approve Handler** |
| 3             | (any)            | Post-chain resume (see Resume Handler below)                  |
| **5**         | **`manual-testing`** | **Manual-Test-Resume Handler** (manual-test paused or in progress — re-enters `/mi-manual-test-run`) |
| 5             | (any)            | Inspector-review received (see Inspector Handler below)         |
| 6             | reviewing        | Post-review-session resume (see Review-Resume Handler below)  |
| 7             | (any)            | Stage-7 finalize — auto-fire `/mi-complete-workflow` (Item 4 of v11 plan; idempotent via Branch II in mi-complete-workflow when re-entered after a partial finalize) |
| any other     | —                | Delegate to `/mi-resume-workflow` for state diagnosis         |

**Why the stage-2 row needs the branch too.** Two states park a feature-test entry at
`current-stage=2`: `/mi-abort-workflow` with no flag (`progress.sh reset` sets stage 2),
and a session break between activation and `advance-to 2 5`. Both re-enter here, and both
want the same idempotent sequence. Ordinary features still reach the Approve Handler on
exactly today's condition.

The `5 | manual-testing` row covers paused or in-progress manual-test runs — the Manual-Test-Resume Handler re-enters `/mi-manual-test-run` to continue from the persisted `current-scenario`. It must come **before** the `5 | (any)` row in the table; tables evaluate top-down and a misordered append would shadow the manual-testing row, misrouting paused manual tests to the Inspector Handler and treating them as normal findings review.

For the "any other" case (active or pre-flight), invoke `/mi-resume-workflow` and stop — let it report state and recommend the next command.

---

## Pre-flight Handler (active=null, queue or selections pending)

Runs at stage 1.5 — between `/mi-run` (which scaffolded the queue from journal content) and `/mi-apply-impact` (which will activate the first feature). Two sub-states, distinguished by what's still pending in the source files.

### Pre-flight Step 2A — Promote selections + propose order

Reached when the inspector has just finished marking items (`[x] TODO` lines exist).

1. **Promote the marked items.**
   ```bash
   $CLAUDE_PLUGIN_ROOT/scripts/progress.sh queue-remaining >/dev/null  # confirms progress.md exists
   promoted="$($CLAUDE_PLUGIN_ROOT/scripts/todo.sh pend-selected)"
   ```
   `pend-selected` rejects any `[x] TODO` line missing an `(assignee)` tag — relay the offenders to the inspector, ask for assignee names, and stop. The inspector fixes the file and re-types `/mi-continue`.

   Its **stdout** carries one `<item-id>\t<assignee>` row per promoted item, in document order; `$promoted` holds them for item 1.5 below.

1.5. **Evaluate the feature-test entry (multi-feature cycles only).**

   ```bash
   ft_row="$($CLAUDE_PLUGIN_ROOT/scripts/todo.sh feature-test-status)"
   ft_status="$(printf '%s' "$ft_row" | cut -f1)"
   ft_name="$(printf '%s' "$ft_row" | cut -f2)"
   ft_item_id="$(printf '%s' "$ft_row" | cut -f3)"
   ft_blocking="$(printf '%s' "$ft_row" | cut -f4)"
   ft_fallback_assignee="$(printf '%s' "$ft_row" | cut -f5)"
   printf 'feature-test: status=%s name=%s item=%s blocking=%s fallback=%s\n' \
     "$ft_status" "$ft_name" "$ft_item_id" "$ft_blocking" "$ft_fallback_assignee"
   ```

   This block **prints** what it read — the values themselves do not survive into later Bash blocks (each Bash tool call is a fresh subshell; see Step 1a), so the printed line is what the agent branches on here, and later items (3.5, 4, 5) re-derive their own copies rather than trusting an export from this fence.

   Branch on `$ft_status`:

   - **`none`** — no feature-test entry in this cycle (single-feature, or a cycle predating the field). Do nothing.
   - **`blocked`** — ordinary `[ ]` items remain. Do nothing, and say nothing about the entry; the hand-off text already explained it.
   - **`ready`** — every ordinary item is now selected or cancelled. Inherit the assignee from the **last** row of `$promoted` (that is, the last one in document order on the pass that completed the selection); when `$promoted` is empty — a re-run after an interrupted session — fall back to `$ft_fallback_assignee`. If both are empty (only reachable by hand-editing, since `pend-selected` and `todo.sh add` both enforce the tag), **ask the inspector for a name** rather than promoting untagged: an untagged `[x]` line would fail the assignee invariant every later `pend-selected` re-checks.

     ```bash
     $CLAUDE_PLUGIN_ROOT/scripts/todo.sh set-state "$ft_item_id" PENDING --assignee "$inherited_assignee"
     ```

   - **`premature`** — the inspector marked the entry by hand while ordinary items remain, and `pend-selected` promoted it early. Revert it (their `(assignee)` tag is preserved, leaving `- [ ] (emin) TODO — …`) and explain:

     ```bash
     $CLAUDE_PLUGIN_ROOT/scripts/todo.sh set-state "$ft_item_id" TODO
     ```

     > "`<ft_name>` is auto-managed — I've unmarked it. It selects itself once every ordinary item is selected or cancelled, and it's pinned last in the queue."

   - **`selected`** — already promoted on an earlier pass. Do nothing here; item 3.5 still checks whether it needs queueing.

2. **Group PENDING items by feature.** Read `todo-list.md` and collect the set of feature section headings (`## <feature>`) that contain `[x] PENDING` lines.
3. **Detect the queue source state.**
   ```bash
   queue_count="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh queue-remaining 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
   ```
   - **If `queue_count > 0`:** the queue was seeded by `/mi-run` (initial cycle). It already lists every feature found in the journal, in some default order — no repopulation needed. Proceed to item 3.5, then item 4 and step 5.
   - **If `queue_count == 0`:** mid-cycle re-entry (Finding 6 — the cycle's first batch already completed and the inspector is marking more items now). The queue must be repopulated from the freshly-PENDING feature names:
     ```bash
     $CLAUDE_PLUGIN_ROOT/scripts/progress.sh enqueue <feat1> [<feat2> ...]
     ```
     where `<featN>` is the de-duplicated set of feature headings that hold PENDING items in `todo-list.md`. `enqueue` refuses duplicates against `queue ∪ completed`, so a feature already finished in this cycle would error out — surface that to the inspector (they probably wrote a TODO under the wrong heading).

     Pass **only ordinary feature names** here, **excluding `$ft_name`** — the feature-test entry is appended separately by item 3.5 so it lands last in both the initial and the mid-cycle branch.

3.5. **Append the feature-test entry to the queue.** Runs after item 3 regardless of which branch fired — both the initial-cycle branch (`queue_count > 0`) and the mid-cycle branch (`queue_count == 0`) fall through to this item. Within that, it actually enqueues when `$ft_status` is `ready` or `selected` and the name is not already present in either the queue or `completed`. This is its own fence, so it re-derives `$ft_status`/`$ft_name` itself rather than trusting item 1.5's — each Bash tool call is a fresh subshell (Step 1a); relying on the earlier fence's export is exactly what makes this step fail silently:

   ```bash
   quest_dir="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh dir)"
   ft_row="$($CLAUDE_PLUGIN_ROOT/scripts/todo.sh feature-test-status)"
   ft_status="$(printf '%s' "$ft_row" | cut -f1)"
   ft_name="$(printf '%s' "$ft_row" | cut -f2)"

   if [[ -n "$ft_name" && "$ft_status" != "none" && "$ft_status" != "blocked" && "$ft_status" != "premature" ]]; then
     queued_now="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh queue-remaining 2>/dev/null || true)"
     completed_now="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$quest_dir/progress.md" 'completed[]' 2>/dev/null || true)"
     ft_already=0
     if printf '%s\n' "$queued_now" | grep -qx "$ft_name"; then
       ft_already=1
     fi
     if printf '%s\n' "$completed_now" | grep -qx "$ft_name"; then
       ft_already=1
     fi
     if [[ "$ft_already" -eq 0 ]]; then
       $CLAUDE_PLUGIN_ROOT/scripts/progress.sh enqueue "$ft_name"
     fi
   fi
   ```

   The guard matters: `enqueue` **errors** on a duplicate rather than no-opping, so a `/mi-continue` re-run after a session break would abort here without it. Checking `completed` alongside `queue-remaining` matters too — `enqueue` itself refuses against `queue ∪ completed`, not just `queue`. On a mid-cycle re-entry *after* the feature-test entry itself already finished its whole workflow, `$ft_status` reads `selected` (the checkbox is still `[x]` in `todo-list.md`) but the name now sits in `progress.completed`, not in `queue` — a queue-only guard would pass and then `enqueue` would abort stage 1.5 with no recovery short of hand-editing `progress.md`. A feature-test entry already in `completed` is deliberately not re-queued. Splitting this from the promotion in item 1.5 is what guarantees last position in both branches — the initial cycle skips item 3's `enqueue` entirely, while the mid-cycle branch enqueues ordinary features first.

4. **Derive cross-feature ordering signals — journal-first, code-aware as fallback.** Replaces the prior unconditional codebase scan (which violated the "intake stages don't read code" invariant — see `docs/context optimization/recommendations.md` § "Issue 1"). Skip the whole step when there's only one feature in the queue.

   **Exclude `$ft_name` from every part of this step** — from the journal-only proposal, from the ambiguity heuristic, and from the feature list passed to the `dependency-mapper` sub-agent. The feature-test entry has no code to scan and its position is fixed by the pin, so including it would spend sub-agent reads searching for a feature that does not exist yet.

   For ≥ 2 features, follow this three-step flow:

   **Step 4a — Journal-only proposal (Phase 4.1).** Derive the ordering from `summary.md` content alone. Read the cycle's `summary.md` `## Cross-cutting constraints` and the `## Feature: <feature>` sections (these are already in main context from stage 1). Compose a proposed order based on:
   - Explicit cross-feature references in the body (e.g., `## Feature: payments` mentioning `audit-log` is a dependency signal).
   - Dependency keywords inside feature sections: `depends on`, `blocks`, `requires`, `precondition`.
   - The default ordering produced by `/mi-run` (already in `progress.md.queue`) when no signals surface.

   This step writes nothing on its own — the proposed order is held in chat to be presented in step 5 below.

   **Step 4b — Heuristic short-circuit (Phase 4.2).** Decide whether step 4a is enough or whether a code-aware scan is justified. This fence re-derives `ft_name` from frontmatter rather than trusting item 1.5's export (fresh subshell — see Step 1a):

   ```bash
   data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
   quest_dir="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh dir)"
   summary_file="$quest_dir/summary.md"
   ft_name="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$quest_dir/todo-list.md" feature-test 2>/dev/null || echo '')"
   [[ "$ft_name" == "null" ]] && ft_name=""
   features_in_queue="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh queue-remaining | sed '/^$/d')"
   if [[ -n "$ft_name" ]]; then
     features_in_queue="$(printf '%s\n' "$features_in_queue" | grep -vx "$ft_name" || true)"
   fi

   ambiguous=0
   # Signal 1: any feature name appears inside another feature's section body
   while IFS= read -r feat; do
     [[ -z "$feat" ]] && continue
     # Use python for robust section walking
     hits="$(python3 - "$summary_file" "$feat" "$features_in_queue" <<'PYEOF'
import re, sys
path, target_feat, all_feats = sys.argv[1], sys.argv[2], sys.argv[3].split('\n')
with open(path) as f:
    content = f.read()
# Find each ## Feature: <name> section
for m in re.finditer(r'^## Feature:\s+(\S+)\s*\n(.*?)(?=^## |\Z)', content, re.MULTILINE | re.DOTALL):
    section_feat, body = m.group(1).strip(), m.group(2)
    if section_feat == target_feat:
        continue
    # Does target_feat appear anywhere in this other feature's body?
    if re.search(rf'\b{re.escape(target_feat)}\b', body):
        print('1')
        sys.exit(0)
print('0')
PYEOF
)"
     if [[ "$hits" == "1" ]]; then
       ambiguous=1
       break
     fi
   done <<< "$features_in_queue"

   # Signal 2: dependency keywords inside any feature section
   if [[ "$ambiguous" == "0" ]] && grep -qiE '\b(depends on|blocks|requires|precondition)\b' "$summary_file"; then
     ambiguous=1
   fi
   ```

   - **`ambiguous=0`** — journal-only ordering is sufficient. Skip Step 4c. Use the proposal from Step 4a in step 5.
   - **`ambiguous=1`** — fall through to Step 4c.

   **Step 4c — Sub-agent fallback for code-aware ordering (Phase 4.3 — Option 1B).** When the heuristic flags ambiguity, delegate the dependency analysis to a fresh sub-agent. Do NOT do the codebase scan in main — that's the leak Phase 4.1 closes.

   First check the cache. If a `queue-rationale.md` from a prior batch in this cycle exists with `scan-mode: code-aware` AND its cache key still matches, reuse the existing rationale instead of spawning a new sub-agent:

   ```bash
   qr_file="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh dir)/queue-rationale.md"
   if [[ -f "$qr_file" ]]; then
     cached_scan_mode="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$qr_file" scan-mode 2>/dev/null || echo 'journal-only')"
     cached_summary_hash="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$qr_file" summary-md-hash 2>/dev/null || echo '')"
     cached_head="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$qr_file" head-when-scanned 2>/dev/null || echo '')"
     current_summary_hash="$(shasum -a 256 "$summary_file" | awk '{print $1}' | cut -c1-16)"
     current_head="$(git rev-parse HEAD 2>/dev/null || echo '')"
     if [[ "$cached_scan_mode" == "code-aware" \
        && "$cached_summary_hash" == "$current_summary_hash" \
        && "$cached_head" == "$current_head" ]]; then
       echo "queue-rationale.md cache hit (scan-mode=code-aware) — reusing prior code-aware ordering"
       cache_hit=1
     else
       cache_hit=0
     fi
   else
     cache_hit=0
   fi
   ```

   If `cache_hit=1`, use the cached order from `qr_file`'s `features` frontmatter and skip the sub-agent. The cached body's `### Order` and `### Dependencies` carry the existing reasoning — surface those in step 5's proposal.

   If `cache_hit=0`, spawn a fresh sub-agent (`Agent` invocation with `subagent_type: millwright-inspector-development-machine:dependency-mapper` — explicitly NOT a fork; a fork would inherit main context and re-introduce the leak). Sub-agent prompt template:

   ```
   You are a fresh sub-agent invoked from `mi-continue` Pre-flight Step 2A item 4 to inspect cross-feature codebase dependencies for the queue: <comma-separated features_in_queue>. Your context is isolated from the main session — main does not see your tool calls, only your final return summary.

   **Required first reads:**

   1. <summary_file> — the cycle's summary.md. Read `## Cross-cutting constraints` and each `## Feature: <name>` section in scope.

   **Your task:**

   1. For each feature in scope, identify the smallest set of existing files / folders / symbols the feature's TODO items would naturally touch (heuristics: keyword grep on the feature name + journal cues, neighboring features in the same module).
   2. Detect cross-feature dependencies: import chains, shared modules, schema dependencies, runtime-coupling between features.
   3. Propose a queue order that respects the dependencies — features that block others run first.
   4. Bounding rules: ≤ 5 files inspected per feature; skip generated/vendor/lock/build artefacts.

   **Return only a 2–3 sentence summary** of the proposed order and the strongest dependency signal you found. Example: "Order: audit-log → payments. The payments feature's planned `services/payments/PaymentService.ts` will read from `services/audit/AuditLog.append()`, which the audit-log feature introduces. No reverse dependency surfaced."

   ---

   Required return shape — return ONLY this structure. Do not narrate intermediate steps:

   Result: success | partial | blocked
   Artifacts changed:
   - <path>: <one-line note>  (likely empty for this task — the sub-agent does not write files)
   Commits:
   - <sha>: <commit subject>  (likely empty)
   Findings / risks:
   - <short bullet, optional>
   Main should read:
   - <path>: <reason>  (likely empty)

   Total return must fit under ~1k tokens.
   ```

   Receive the sub-agent return summary. Use the proposed order in step 5. The cache key fields (`scan-mode: code-aware`, `summary-md-hash`, `head-when-scanned`) will be written into `queue-rationale.md` by Step 2B when the inspector confirms the order — main is responsible for passing these to Step 2B's frontmatter init/update.
5. **Propose the prioritized order.** Print the order as a numbered list and the dependency reasoning underneath. End the message with:
   > "Reply `/mi-continue` to accept this order, or paste a different order (one feature per line) and then `/mi-continue` to confirm."

   When the feature-test entry is **in the queue** — not merely present in frontmatter — append `$ft_name` **last** to the proposal, then assert the pin before printing. Gate on queue membership, not frontmatter presence: item 3.5 only enqueues on `ready`/`selected`, so on a `blocked` partial selection (a common case — the inspector marks some but not all items) `ft_name` is populated in frontmatter but absent from the queue. Appending it to the proposal anyway would poison it with a name `check-feature-test-pin` happily accepts (it IS last in the *proposed* list) but that `progress.sh reorder` later rejects as "not in existing queue" — *after* Step 2B has already written `queue-rationale.md` with it in `features:`, breaking the Row A invariant (`queue-rationale.features − completed == queue`). This fence re-derives `ft_name` itself rather than trusting item 1.5's or item 3.5's export (fresh subshell — see Step 1a):

   ```bash
   quest_dir="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh dir)"
   ft_name="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$quest_dir/todo-list.md" feature-test 2>/dev/null || echo '')"
   [[ "$ft_name" == "null" ]] && ft_name=""
   ft_queued=0
   if [[ -n "$ft_name" ]]; then
     q="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh queue-remaining 2>/dev/null || true)"
     if printf '%s\n' "$q" | grep -qx "$ft_name"; then
       ft_queued=1
     fi
   fi
   if [[ "$ft_queued" -eq 1 ]]; then
     $CLAUDE_PLUGIN_ROOT/scripts/progress.sh check-feature-test-pin "$ft_name" "${proposed_order[@]}"
   fi
   ```

   Show it in the numbered list with a one-line note that it is pinned and cannot be moved — only when `ft_queued=1`. When it's `0` (still `blocked`), the entry isn't part of this proposal at all; say nothing about it here, same as item 1.5's `blocked` branch.

6. **Mid-cycle re-entry only — append a draft batch to `queue-rationale.md` (Item 7 of the v11 plan).** When this Step 2A run is the mid-cycle re-entry path (queue was empty + we just re-populated via `enqueue`), `queue-rationale.md` already exists from the prior cycle's batches and its top-level `status` is `confirmed`. Append a new `## Batch <N+1> — <today>` body with the proposed order in `### Order` (and `### Dependencies`/`### Notes` if applicable). Refresh top-level frontmatter atomically with the body write: `batch: N+1`, `status: draft`, `features: <previous confirmed cumulative + proposed order for new batch>`. This makes the next `/mi-continue` route to the draft-confirmation row in the dispatcher (Item 5) → Step 2B (extended) for confirmation.

   ```bash
   if [[ -f "$qr_file" && "$(frontmatter.sh get "$qr_file" status 2>/dev/null || echo confirmed)" == "confirmed" ]]; then
     # Determine N from the highest matched ## Batch <N> heading via the pinned regex
     # ^## Batch (\d+)\b. Files without batch headers are treated as implicit Batch 1.
     # Append ## Batch <N+1> — <today> + ### Order/Dependencies/Notes via Edit.
     # Then update top-level frontmatter:
     #   $CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh set "$qr_file" batch <N+1>
     #   $CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh set "$qr_file" status draft
     #   $CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh set "$qr_file" features '[<cumulative>]'
   fi
   ```

   When the batch introduced the feature-test entry, record the pin under `### Notes`:

   > `<ft_name>` is pinned last — it exercises the assembled result of every ordinary feature in this cycle, so it cannot run before them. This is a structural constraint, not a priority judgement; an order placing it earlier is refused at stage 1.5.

7. **Stop.** Do NOT auto-fire Step 2B from here — the draft batch needs the inspector's explicit confirmation. The dispatcher routes the next `/mi-continue` to Step 2B (extended) automatically because top-level `status` is now `draft`.

   For the **initial cycle** (queue was already seeded by `/mi-run`, no prior batches exist): skip the file write here and let Step 2B's case (a) write the file from scratch when the inspector confirms. (This preserves the current behavior for fresh cycles.)

### Pre-flight Step 2B — Confirm order + auto-fire `/mi-apply-impact`

Reached when `[x] TODO` lines have been promoted (none remain) AND either (a) `queue-rationale.md` is missing OR (b) `queue-rationale.md` is present with `status: draft`. Item 5 of the v11 plan extends Step 2B to handle both cases — they share the prompt logic, the order-validation, the `progress.sh reorder` call, and the auto-fire of `/mi-apply-impact`. They diverge only at the file-write step (init vs. targeted edit).

**Detect entry condition:**

```bash
quest_dir="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh dir)"
qr_file="$quest_dir/queue-rationale.md"
if [[ -f "$qr_file" ]]; then
  qr_status="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$qr_file" status 2>/dev/null || echo 'confirmed')"
  qr_batch="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$qr_file" batch 2>/dev/null || echo '1')"
else
  qr_status="missing"
  qr_batch="0"
fi
```

1. **Resolve the confirmed order.** If the inspector typed a custom order in the previous turn, parse it. Otherwise, use the proposal from Step 2A (which the millwright still has in conversation context — if the session was compacted, re-derive it by re-grouping PENDING items + re-running dependency analysis). For the draft case (b), the proposal lives in the latest batch's `### Order` body and in top-level `features:` (the suffix corresponding to the draft batch).
2. **Validate the order.** It must be a permutation of the current `progress.md` queue. If the inspector's custom order is malformed (extras, missing entries, duplicates), surface the error and ask them to retype.

   **Pin validation.** When the feature-test entry is **in the queue** — not merely present in frontmatter — the confirmed order must keep it last. Gate on queue membership, not frontmatter presence: the same partial-selection gap as item 5 above applies here — `ft_name` can be populated in frontmatter while the entry is still `blocked` and was never enqueued:

   ```bash
   ft_name="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$quest_dir/todo-list.md" feature-test 2>/dev/null || echo '')"
   if [[ -n "$ft_name" && "$ft_name" != "null" ]]; then
     q="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh queue-remaining 2>/dev/null || true)"
     if printf '%s\n' "$q" | grep -qx "$ft_name"; then
       $CLAUDE_PLUGIN_ROOT/scripts/progress.sh check-feature-test-pin "$ft_name" "${confirmed_order[@]}"
     fi
   fi
   ```

   On exit 3, relay the message and ask the inspector to retype the order — the same shape as the malformed-order path above. The check reads no files, so it is equally valid against a proposed order and a persisted one.

   Read `ft_name` from frontmatter as shown — **never re-derive it here.** The name was frozen at stage 1 from the stage-1 feature order; a confirmed order that puts a different feature first does not change it, and re-deriving would rename a feature folder mid-cycle and strand its artifacts.

3. **Write the cycle's `queue-rationale.md`.** Two sub-paths:

   **(a) Missing — write a fresh file** (current behavior):

   ```bash
   todo_list_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get \
     "$quest_dir/todo-list.md" id)"
   $CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init queue-rationale \
     "$qr_file" \
     "TODO_LIST_ID=$todo_list_id" \
     "FEATURES=<comma-joined confirmed order>"
   ```

   Then fill the body via `Edit` per the template's section guide (one `## Batch 1 — <date>` section with `### Order`, `### Dependencies`, `### Notes`). Top-level `status` and `batch` may be omitted (schema defaults handle them as `confirmed`/`1`).

   **Cache fields (Phase 4.3 of the context-optimization plan).** If Step 2A's item 4 ran the code-aware sub-agent fallback (Step 4c), record the cache key fields so a subsequent mid-cycle re-entry can short-circuit the scan. Set these via `frontmatter.sh set` after the init:

   ```bash
   if [[ "$step_2a_scan_mode" == "code-aware" ]]; then
     summary_md_hash="$(shasum -a 256 "$summary_file" | awk '{print $1}' | cut -c1-16)"
     head_when_scanned="$(git rev-parse HEAD 2>/dev/null || echo '')"
     $CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh set "$qr_file" scan-mode code-aware
     $CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh set "$qr_file" summary-md-hash "$summary_md_hash"
     [[ -n "$head_when_scanned" ]] && $CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh set "$qr_file" head-when-scanned "$head_when_scanned"
   fi
   # When step_2a_scan_mode is unset or `journal-only`, omit these fields — schema default is journal-only.
   ```

   **(b) Draft — targeted edit of the existing file** (Item 7 + Item 5 extension):

   - Update only the **latest batch's** `### Order / ### Dependencies / ### Notes` body to reflect the confirmed order and reasoning. Do NOT add a new batch (Item 7 reserves the append step for Step 2A); do NOT rewrite earlier batch bodies (audit history).
   - Refresh top-level `features:` to the cumulative ordered list across all batches (previous confirmed batches' features in order, plus the just-confirmed latest batch's features). Use `mi_fm_set` (via `frontmatter.sh set`) to preserve the rest of the frontmatter.
   - Set top-level `batch:` to the latest batch number (`qr_batch`).
   - Flip top-level `status:` from `draft` to `confirmed`.
   - **Cache fields:** if Step 2A's item 4 ran the code-aware sub-agent for the latest batch, refresh `scan-mode`, `summary-md-hash`, `head-when-scanned` per case (a) above. If the sub-agent didn't run (cache hit during step 4c, or journal-only path), leave the fields as they were on the prior batch's confirmation.
   - **Load-bearing invariant:** after Step 2B returns, `queue-rationale.md.features - progress.completed` must equal `progress.queue` in order, or Row A will not fire between features. Verify this before the auto-fire below.

     When the cycle carries a feature-test entry, `queue-rationale.features` ends with it — which is exactly what keeps **Row A** satisfied, since the confirmed order (and therefore `progress.queue`) ends with it too. This is the invariant that breaks first if anyone moves the item-3.5 `enqueue` out of Step 2A into Step 2B: the name would be missing from the queue when `features:` is written, Row A would mismatch, and the workflow would stall between features.

4. **Reorder the queue.**
   ```bash
   $CLAUDE_PLUGIN_ROOT/scripts/progress.sh reorder <feature1> <feature2> ...
   ```
5. **Auto-fire `/mi-apply-impact`.** Same as the prior end-of-stage-1.5 transition.

---

## Approve Handler (current-stage = 2)

Runs after the inspector has reviewed the blueprint files (`requirements.md`, `config.md`, `diagrams/`) and is ready to advance into the planning chain.

### Approve Step 1 — Sanity-check blueprint files

Use `blueprints.sh check-current` (default mode — `primer.md` is not expected until stage 3) so partial stage-2 generations cannot slip through to `/mi-plan-implementation` with an incomplete blueprint:

```bash
if "$CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh" check-current "$active_feature"; then
  current_status=0
else
  current_status=$?
fi
case "$current_status" in
  0) ;;  # stage-2 blueprint is complete; proceed to /mi-plan-implementation
  1)
    echo "error: blueprints/current is empty for $active_feature; run /mi-apply-impact first" >&2
    exit 1
    ;;
  2)
    echo "error: blueprints/current is partial or invalid for $active_feature; repair it or re-run /mi-apply-impact before approving" >&2
    exit 1
    ;;
  *)
    echo "error: check-current returned unexpected status $current_status" >&2
    exit 1
    ;;
esac
```

The default mode is correct here: `primer.md` is written at stage 3 by `/mi-plan-implementation` Step 3.5, so it does not exist yet at the stage-2 approve gate. Stage-3+ callers (`/mi-update-blueprint`, the Stage-4 drift probe, `/mi-complete-workflow` before completion rotation) use `--require-primer` to also validate the primer.

### Approve Step 2 — Clear-point gate (`stage-2-to-3`)

Per `docs/clear-points/plan.md` §3.1 / §5.2, this step offers the inspector a `/clear` between stage-2 blueprint approval and stage-3 implementation entry. The gate fires at most once per feature: on first entry it prints the recommendation and halts; on re-entry (whether the inspector cleared or skipped) it proceeds.

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"

if "$CLAUDE_PLUGIN_ROOT/scripts/progress.sh" has-clear-recommendation stage-2-to-3; then
  gate_already_fired=1
else
  gate_already_fired=0
fi
```

#### Step 2a — `decisions.md` write-check (always runs)

Before the gate decides, ensure any verbal scope decisions from the recent stage-2 Q&A have been persisted to `decisions.md`. This is mandatory: if the inspector cleared on the strength of the recommendation (Step 2b), anything not in `decisions.md` is **lost** — the file is the only thing that survives the clear (per `docs/clear-points/plan.md` §4 prerequisites).

Review the last several turns of the conversation. If they contain instructions, scope decisions, or constraints that are NOT captured verbatim in `requirements.md` / `config.md` / `inspector-review.md`, summarize them as bullets in `$data_root/workflow-stream/$active_feature/decisions.md` under the `## Stage 2 — Blueprint approval` section.

```bash
decisions_file="$data_root/workflow-stream/$active_feature/decisions.md"
if [[ ! -f "$decisions_file" ]]; then
  # File doesn't exist yet — initialize it on first use.
  $CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init decisions "$decisions_file" \
    "FEATURE=$active_feature"
fi
# Then use Edit to append bullets to the `## Stage 2 — Blueprint approval`
# section if any new decisions surfaced. Format per templates/decisions.md.tmpl:
#   - **YYYY-MM-DD** — <decision>. Reason: <why>.
# Skip the write entirely if the recent turns contain no spec-relevant
# decisions — the placeholder comment can stay.
```

If the gate has already fired (`gate_already_fired=1`), the write-check still runs — late-stage decisions caught between offer and resume should still land. Only the ledger appends and the recommendation print differ between branches.

#### Step 2b — Branch on `gate_already_fired`

**If `gate_already_fired=0` (first entry — print recommendation + halt):**

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh add-clear-recommendation stage-2-to-3
$CLAUDE_PLUGIN_ROOT/scripts/ledger.sh append \
  "2" "/mi-continue" "clear-offer-recommendation" "small" "main" \
  "stage-2-to-3 clear offered" || true
```

Then print the recommendation block to the inspector and **halt** — do NOT auto-fire `/mi-plan-implementation` in this branch:

> "Blueprint for `$active_feature` approved. **Recommended:** type `/clear`, then `/mi-continue` to enter stage 3 with a fresh main context.
>
> What gets carried across the clear:
> - `progress.md` (workflow state)
> - `blueprints/current/{requirements,config}.md` (the blueprint you just approved)
> - `decisions.md` (any verbal decisions captured above — folded into `primer.md` when stage 3 starts)
>
> What gets discarded by the clear: the back-and-forth conversation that led to this point. The blueprint is the canonical record; the chat history is not.
>
> Skip the clear (just type `/mi-continue` without clearing) if you have unsaved verbal context you specifically want to carry forward."

Then exit. The inspector's next `/mi-continue` re-enters this handler with `gate_already_fired=1`.

**If `gate_already_fired=1` (re-entry — offer was already shown; proceed):**

```bash
$CLAUDE_PLUGIN_ROOT/scripts/ledger.sh append \
  "2" "/mi-continue" "post-offer-resume" "small" "main" \
  "stage-2-to-3 Approve Handler resumed" || true

# Rehydration row — record the file set the dispatcher reads to remember
# workflow state post-clear. The handler does NOT itself read these here
# (mi-plan-implementation reads what it needs), but the ledger row attributes
# the read class to the gate transition for analytics.
$CLAUDE_PLUGIN_ROOT/scripts/ledger.sh append \
  "2" "/mi-continue" "progress.md, summary.md, requirements.md, config.md" \
  "medium" "main" "stage-2-to-3 rehydration" || true
```

Fall through to Step 3.

We **cannot** distinguish "took the clear" from "skipped the clear" — both produce the same persisted state (the `clear-recommendations` array contains `stage-2-to-3` either way). Per `docs/clear-points/plan.md` §6.5 and §5.4, this is fine functionally; telemetry honestly records `clear-offered` and `post-offer-resume` only, never a fake `clear-taken`.

### Approve Step 3 — Auto-fire `/mi-plan-implementation`

`/mi-plan-implementation` handles its own preconditions: branch validation against `config.md`'s `## GIT BRANCH`, todo promotion (PENDING → IMPLEMENTING), `base-commit` capture, primer composition (which folds in `decisions.md` per Step 3.5 — see `docs/clear-points/plan.md` §9.3), planning-mode prompt, and chain launch.

```bash
/mi-plan-implementation
```

If `mi-plan-implementation` errors (branch missing, branch mismatch, etc.), relay the error to the inspector; they fix the underlying issue and type `/mi-continue` again.

---

## Resume Handler (current-stage = 3)

Runs after the brainstorming chain has fully exited and returned control. Generates implementation diagrams (with pre-existing system framed as shaded context), optionally rotates the blueprint if requirements changed during brainstorming, and hands off to the inspector for review.

The handler is structured so re-runs after a session break are safe (Item 1 of the v11 progress-gap plan). All state writes are atomic, and a Step 0 drift-completion probe detects "drift was successfully completed in this cycle but the marker write was lost" without re-prompting the inspector.

### Resume Step 0 — Drift-completion probe (closes F1)

Skipped when `active.drift-check-completed` is already true (probe is gated to one-shot per cycle). Detects the case where `/mi-update-blueprint` rotated and regenerated successfully but the subsequent marker-set was lost to a session break — without this probe, the next `/mi-continue` would re-prompt the inspector for a drift decision they already answered.

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
hist="$data_root/workflow-stream/$active_feature/blueprints/history"

drift_marker="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get drift-check-completed 2>/dev/null || echo 'false')"

# Helper: highest finalized v[N] for active.feature.
latest_finalized_v() {
  ls -d "$hist"/v[0-9]* 2>/dev/null \
    | grep -vE '\.(partial|partial\.tmp)$' \
    | sed -n 's|.*/v\([0-9]\+\)$|\1|p' \
    | sort -n | tail -1
}

# Helper: highest finalized v[K]>baseline whose reason.kind == "spec-update". Empty if none.
spec_update_after() {
  local baseline="$1"
  local v
  for d in "$hist"/v[0-9]*; do
    [[ -d "$d" ]] || continue
    [[ "$d" == *.partial || "$d" == *.partial.tmp ]] && continue
    v="${d##*/v}"
    [[ "$v" =~ ^[0-9]+$ ]] || continue
    [[ "$v" -le "$baseline" ]] && continue
    local kind
    kind="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$d/reason.md" kind 2>/dev/null || echo "")"
    if [[ "$kind" == "spec-update" ]]; then
      echo "$v"
      return 0
    fi
  done
  echo ""
}

# Helper: most recent partial directory's reason kind, or empty.
single_partial() {
  local matches
  matches=$(ls -d "$hist"/v[0-9]*.partial 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$matches" == "1" ]]; then
    ls -d "$hist"/v[0-9]*.partial 2>/dev/null
  fi
}

if [[ "$drift_marker" != "true" ]]; then
  baseline_str="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get history-baseline-version 2>/dev/null || echo 'null')"

  if [[ "$baseline_str" == "null" || -z "$baseline_str" ]]; then
    # Unknown baseline (older in-flight cycle, or Step 3 was partial). Do NOT
    # infer drift from old history; first ensure current/ is structurally
    # complete, then capture a fresh baseline and skip the probe for this
    # invocation.
    if "$CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh" check-current --require-primer "$active_feature"; then
      cc_status=0
    else
      cc_status=$?
    fi
    if [[ "$cc_status" != "0" ]]; then
      # current/ is empty or partial — recovery required. Determine the kind to
      # invoke /mi-update-blueprint with: prefer the partial's reason.kind,
      # otherwise the latest finalized v[N]/reason.md.kind. GUARD the value to
      # {manual, spec-update}; other kinds are owned by other commands.
      partial_dir="$(single_partial)"
      recovered_kind=""
      recovered_summary=""
      if [[ -n "$partial_dir" && -f "$partial_dir/reason.md" ]]; then
        recovered_kind="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$partial_dir/reason.md" kind 2>/dev/null || echo "")"
        recovered_summary="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$partial_dir/reason.md" summary 2>/dev/null || echo "")"
      else
        latest_v_for_kind="$(latest_finalized_v)"
        if [[ -n "$latest_v_for_kind" ]]; then
          recovered_kind="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$hist/v${latest_v_for_kind}/reason.md" kind 2>/dev/null || echo "")"
          recovered_summary="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$hist/v${latest_v_for_kind}/reason.md" summary 2>/dev/null || echo "")"
        fi
      fi

      case "$recovered_kind" in
        manual|spec-update)
          /mi-update-blueprint --reason-kind="$recovered_kind" "${recovered_summary:-recovery}"
          if [[ "$recovered_kind" == "spec-update" ]]; then
            $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "drift-check-completed=true"
            echo "Step 0: lazy-baseline recovery succeeded for spec-update; drift marker set. Re-run /mi-continue to advance."
            exit 0
          else
            # Manual recovery: capture fresh baseline, let the normal drift prompt run later in this invocation.
            baseline_after_recovery="$(latest_finalized_v)"; baseline_after_recovery="${baseline_after_recovery:-0}"
            $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "history-baseline-version=$baseline_after_recovery"
          fi
          ;;
        completion)
          echo "error: a 'completion' partial blocks drift recovery — this state is owned by /mi-complete-workflow's Branch 0a, not /mi-update-blueprint. Invoke /mi-complete-workflow to resume the in-flight stage-8 rotation, or /mi-resume-workflow for diagnosis." >&2
          exit 1
          ;;
        re-spec-cascade|re-plan-cascade)
          echo "error: a '$recovered_kind' partial blocks drift recovery — these are review-loop auto-trigger rotations; their resume path is via /mi-review (re-launch the brainstorming review session) which lets the chain's next rotation attempt resume the partial. /mi-update-blueprint cannot recover this kind. No state was modified." >&2
          exit 1
          ;;
        *)
          echo "error: cannot determine a safe recovery kind for current/ in this state. Run /mi-resume-workflow for diagnosis." >&2
          exit 1
          ;;
      esac
    else
      # current/ is complete: just capture a fresh baseline and skip the probe for this invocation.
      baseline_capture="$(latest_finalized_v)"; baseline_capture="${baseline_capture:-0}"
      $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "history-baseline-version=$baseline_capture"
      echo "Step 0: lazy baseline capture (=$baseline_capture). Probe disabled for this invocation; the normal drift prompt may run."
    fi
  else
    # Known baseline — walk K > baseline for kind=spec-update.
    drift_done_v="$(spec_update_after "$baseline_str")"
    if [[ -n "$drift_done_v" ]]; then
      if "$CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh" check-current --require-primer "$active_feature"; then
        cc_status=0
      else
        cc_status=$?
      fi
      if [[ "$cc_status" == "0" ]]; then
        # Drift rotated + regenerated successfully — only the marker write was lost. Persist it.
        $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "drift-check-completed=true"
        echo "Step 0: detected this-cycle spec-update at v${drift_done_v} with complete current/; persisted drift marker. Drift prompt will be skipped."
      else
        # Drift rotation started but regeneration is partial. Route to /mi-update-blueprint recovery.
        # The recovery loop note: when check-current==2, /mi-update-blueprint will refuse without
        # --force-regen and the workflow will keep landing on this same diagnostic until the
        # inspector intervenes. This is intentional (auto-firing --force-regen would discard
        # partial inspector-visible content without consent — which is what F2 closes).
        v_summary="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$hist/v${drift_done_v}/reason.md" summary 2>/dev/null || echo 'recovery')"
        echo "Step 0: detected this-cycle spec-update at v${drift_done_v} but current/ is incomplete (check-current=$cc_status). Routing to /mi-update-blueprint recovery."
        echo "Note: if /mi-update-blueprint refuses (partial state without --force-regen), the workflow will not progress until you repair current/ manually OR re-run /mi-update-blueprint --force-regen <reason>. This is intentional — see F2/Item 10 in the v11 plan."
        /mi-update-blueprint --reason-kind=spec-update "$v_summary"
        $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "drift-check-completed=true"
      fi
    fi
    # If no spec-update v > baseline, drift hasn't run yet in this cycle — let the normal Step 3 prompt fire.
  fi
fi
```

### Resume Step 1 — Verify the chain produced commits (zero-commit branch)

```bash
base_commit="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get base-commit)"
commit_count="$(git rev-list --count "$base_commit..HEAD")"
```

**If `commit_count > 0`:** proceed to Step 2 (the normal flow).

**If `commit_count == 0`:** the chain produced no commits since `base-commit`. Three legitimate causes — prompt the inspector:

> "Stage 4 — no commits since `base-commit` (`$base_commit`). The brainstorming chain (or direct implementation) hasn't produced code yet. Reply:
>
>   - `retry-launch` — re-launch `/mi-plan-implementation` (the chain may have exited prematurely or the direct-implementation session was interrupted before any commits landed). Stage stays at 3.
>   - `direct-empty` — confirm that **no code changes were needed** (e.g., a config-only feature whose blueprint was already correct, or a feature that turned out to already be implemented). I'll skip diagram generation + change-summary regeneration, write a tagged HTML comment into `inspector-review.md` documenting why, mark the cycle as drift-check-complete (no drift to detect — there's nothing to compare), and advance directly to stage 5 (inspector review). You can still write findings if you disagree with the no-changes conclusion.
>   - `abort` — invoke `/mi-abort-workflow` to clean up state."

```bash
if (( commit_count == 0 )); then
  case "$zero_commit_reply" in
    retry-launch)
      echo "Zero-commit branch: re-launching /mi-plan-implementation."
      /mi-plan-implementation
      exit 0  # mi-plan-implementation handles the rest; inspector types /mi-continue when ready
      ;;
    direct-empty)
      # Direct-empty side-effect contract (Item 3 of v11 plan).
      # 1. Skip /mi-draw-diagrams entirely (no commits, nothing to diagram).
      # 2. Skip implementation/change-summary.md regeneration.
      # 3. Create/validate the inspector-review.md skeleton idempotently.
      data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
      ov_file="$data_root/workflow-stream/$active_feature/implementation/inspector-review.md"
      [[ -f "$ov_file" ]] || $CLAUDE_PLUGIN_ROOT/scripts/review.sh init "$active_feature"
      $CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh validate "$ov_file" review-file >/dev/null

      # Insert the direct-empty HTML comment ONCE, immediately after the frontmatter
      # block and before any markdown heading. review.sh canonicalize explicitly
      # skips HTML comments (scripts/review.sh:246-253), so this comment will not
      # be misclassified as a free-form finding. Do NOT use plain "## No code
      # changes" prose here — that would trip canonicalize.
      python3 - "$ov_file" "$direct_empty_reason" <<'PYEOF'
import re, sys
path, reason = sys.argv[1], sys.argv[2] or "not provided"
with open(path) as f:
    content = f.read()
marker = "<!-- direct-empty cycle"
if marker in content:
    sys.exit(0)  # already added; idempotent
m = re.match(r'^(---\n.*?\n---\n)(.*)$', content, re.DOTALL)
fm_block = m.group(1) if m else ""
body = m.group(2) if m else content
note = (
    f"\n<!-- direct-empty cycle (planning-mode=direct, zero commits in "
    f"base-commit..HEAD).\n"
    f"     The inspector reported during stage 4 that no code changes were needed.\n"
    f"     Reason: {reason}.\n"
    f"     Approve with no findings to advance, or write findings under\n"
    f"     \"## Implementation Review\" if you disagree. -->\n"
)
with open(path, 'w') as f:
    f.write(fm_block + note + body)
PYEOF

      # 4. Standalone flag writes — drift-check-completed=true skips the drift
      # prompt entirely (no drift to detect when there are zero commits).
      $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set \
        "implementation-completed=true" \
        "drift-check-completed=true" \
        "execution-mode=inline" \
        "sub-flow=resuming"

      # 5. Final atomic advance-to 3 → 5.
      $CLAUDE_PLUGIN_ROOT/scripts/progress.sh advance-to 3 5 --set sub-flow=none

      # 6. Hand off at stage 5.
      echo "Direct-empty cycle for '$active_feature' — advanced to stage 5. Review inspector-review.md (the HTML comment documents the reason); type /mi-continue when ready."
      exit 0
      ;;
    abort)
      /mi-abort-workflow
      exit 0
      ;;
    *)
      echo "error: zero-commit branch requires reply of 'retry-launch', 'direct-empty', or 'abort'." >&2
      exit 1
      ;;
  esac
fi
```

In the happy path, the mi-workflow does **not** track or read the spec / plan files the chain produced under `docs/superpowers/` — those are the chain's own artefacts and `base-commit..HEAD` is the canonical implementation contract. Step 2.5 below is the single exception: when commits exist *and* a plan file from this chain run is detected, the handler reads the plan/spec **read-only** to compose a resume primer if the inspector reports the chain was interrupted mid-run.

### Resume Step 2 — Mark sub-flow + idempotent flag writes

Atomic batched write — these flags are idempotent on retry:

```bash
# Prompt for execution-mode only when not yet persisted (a prior partial run
# may have already chosen). Otherwise reuse the persisted value.
mode_persisted="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get execution-mode 2>/dev/null || echo 'none')"
if [[ "$mode_persisted" == "none" ]]; then
  # Prompt the inspector (subagent-driven|inline). The exact prompt text lives
  # in Resume Step 3 below for narrative continuity.
  mode="$mode_from_inspector"  # placeholder; the LLM following this recipe asks the inspector.
else
  mode="$mode_persisted"
fi

$CLAUDE_PLUGIN_ROOT/scripts/progress.sh set \
  "implementation-completed=true" \
  "execution-mode=$mode" \
  "sub-flow=resuming"
```

### Resume Step 2.5 — Confirm chain completion (abandoned-chain recovery)

A session that was closed mid-chain looks identical to a clean exit at this point: both have commits in `base-commit..HEAD` and `sub-flow=chain-in-progress`. To distinguish, look for plan files written by *this* chain run and ask the inspector.

1. **Locate this run's plan candidates.** Combine plans added/modified in `base-commit..HEAD` (committed by the chain) with any plan files currently in the working tree under `docs/superpowers/plans/` (the chain may have written but not yet committed). Filtering by `base-commit..HEAD` excludes plans from earlier features.

   ```bash
   plan_candidates="$(
     {
       git log --diff-filter=AM --name-only --format= "$base_commit..HEAD" -- 'docs/superpowers/plans/*.md' 2>/dev/null
       git status --porcelain -- docs/superpowers/plans/ 2>/dev/null \
         | sed -E 's/^.. //; s/^.*-> //' \
         | grep '\.md$' || true
     } | sort -u
   )"
   ```

2. **If `plan_candidates` is empty** — no plan from this chain run was found (e.g., `planning-mode=direct` skips writing-plans, or the chain committed without dropping a plan file). Skip the recovery branch entirely and fall through to Step 3. No prompt; no behavior change versus the pre-recovery happy path.

3. **If `plan_candidates` has entries** — for each, count `- [x]` (done) and `- [ ]` (remaining) checkboxes:

   ```bash
   commit_count_total="$(git rev-list --count "$base_commit..HEAD")"
   last_commit="$(git log -1 --format='%h %s' HEAD)"
   while IFS= read -r plan; do
     [[ -z "$plan" ]] && continue
     done_count="$(grep -cE '^[[:space:]]*-[[:space:]]*\[[xX]\]' "$plan" 2>/dev/null || echo 0)"
     remaining_count="$(grep -cE '^[[:space:]]*-[[:space:]]*\[[[:space:]]\]' "$plan" 2>/dev/null || echo 0)"
     echo "$plan|$done_count|$remaining_count"
   done <<< "$plan_candidates"
   ```

4. **Prompt the inspector.** Render the candidates as a numbered list with their checkbox counts and ask:

   > "Stage 4 — chain-completion check.
   >
   > Plan file(s) written during this chain run:
   >
   >   1. `<path>` — done: N, remaining: M
   >   2. `<path>` — done: P, remaining: Q  *(only if multiple candidates)*
   >
   > Commits since base-commit: K (latest: `<sha> <subject>`)
   >
   > Did the brainstorming chain finish cleanly, or was the session interrupted mid-chain?
   >
   >   - `completed` — advance to inspector review (3 → 4). Use this when the chain ran through `finishing-a-development-branch` and exited normally; remaining `- [ ]` checkboxes are stale (the chain doesn't always tick the very last step).
   >   - `abandoned <N>` — re-launch the brainstorming chain with plan #N (the number from the list above) as the resume target. I'll point the chain at the existing plan + spec + commit history so it picks up from the next un-done step. Stage stays at 3 until the chain finishes; you'll type `/mi-continue` again afterward and this same handler will route to `completed`.
   >   - `abandoned` — same as above; valid only when there's exactly one plan candidate (the `<N>` is implied)."

5. **On `completed`** — fall through to Step 3.

6. **On `abandoned [<N>]`** — resolve `<N>` to the picked plan file (default to the only candidate when omitted; if multiple candidates and `<N>` is missing or out of range, surface the error and re-prompt). Then find the matching spec by the same git-log-filter pattern applied to `docs/superpowers/specs/*.md`:

   ```bash
   spec_candidates="$(
     {
       git log --diff-filter=AM --name-only --format= "$base_commit..HEAD" -- 'docs/superpowers/specs/*.md' 2>/dev/null
       git status --porcelain -- docs/superpowers/specs/ 2>/dev/null \
         | sed -E 's/^.. //; s/^.*-> //' \
         | grep '\.md$' || true
     } | sort -u
   )"
   ```

   - 0 spec candidates → omit the spec line from the resume primer (the chain works from the plan alone).
   - 1 spec candidate → reference it as `<picked_spec_path>` in the primer.
   - >1 spec candidates → list all of them in the primer; the chain decides which is canonical.

   Reset sub-flow back to `chain-in-progress` (the chain is about to be live again):

   ```bash
   $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "sub-flow=chain-in-progress"
   ```

   Then invoke the `brainstorming` Skill with this **resume primer** (substitute literals for the `<...>` placeholders, paste the actual `git log` output where indicated). Substitute `<$data_root>` with the resolved data root (e.g. `millwright-inspector` by default; whatever `$data_root` evaluates to in this command's shell context).

   ```
   I'm RESUMING an interrupted implementation session for the "<active_feature>" feature. The previous session ended mid-chain — some commits were made but the plan isn't fully executed.

   **Required first reads (in order):**

   1. <$data_root>/workflow-stream/<active_feature>/blueprints/current/primer.md — the original stage-3 launch primer (active scope, goals, journal context, likely-relevant skills/rules).
   2. <picked_plan_path> — the plan you wrote in the previous session. Checkbox state (`- [x]` vs `- [ ]`) reflects what's been executed; the next `- [ ]` is where you pick up.
   3. <picked_spec_path> — the spec the plan implements. *(omit this line if no spec candidates were found)*

   **Already shipped** (commits in <base_commit>..HEAD):

   <paste output of `git log --oneline <base_commit>..HEAD` here>

   **Resume strategy:**

   Read the primer, plan, and spec. The plan's checkbox state tells you what was executed; the commit log tells you what physically landed. If they disagree (plan checkboxes can lag if the previous session was killed before the check was written), reconcile based on the commits — they're authoritative. Then continue executing-plans / subagent-driven-development from the next un-done Task or Step.

   If the plan is fundamentally incompatible with what's been committed (e.g., the previous session diverged and the plan is now stale), surface that to the inspector; they can run `/mi-abort-workflow` to start over. Otherwise: resume execution.

   Do NOT worry about the mi-workflow — when you finish, the inspector types `/mi-continue` to resume mi-workflow at stage 4.
   ```

   After invoking the Skill, **stop here**. Do NOT advance the stage. Do NOT mark `implementation-completed`. The stage stays at 3, sub-flow at `chain-in-progress`. The inspector drives the chain to completion (same isolation model as the original stage-3 launch); when it finishes, they type `/mi-continue` and this handler runs again, this time routing to `completed` (or back through Step 2.5 if the second run was also interrupted).

### Resume Step 3 — Drift prompt (skipped when probe set the marker)

(Skipped when `active.drift-check-completed` was set true by Step 0's probe.)

```bash
drift_marker_now="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get drift-check-completed 2>/dev/null || echo 'false')"
if [[ "$drift_marker_now" != "true" ]]; then
  # Existing inspector prompt and dispatch lives below in "Resume Step 4 — Blueprint drift check".
  drift_prompt_required=1
else
  echo "Resume Step 3: drift marker already true (set by Step 0 probe); skipping drift prompt."
  drift_prompt_required=0
fi
```

### Resume Step 4 — Blueprint drift check (inspector-driven)

(Skipped when `drift_prompt_required==0`, i.e., the Step 0 probe already set the marker for this cycle.)

Brainstorming may have surfaced new requirements, dropped some, or shifted scope mid-session. Without inspecting the chain's spec/plan files (mi-workflow doesn't read those), the inspector is the authority on whether `blueprints/current/requirements.md` still matches what was actually built.

When `drift_prompt_required==1`, prompt the inspector:

> "Stage-4 drift check: did anything in the requirements change during brainstorming? Reply:
>
>   - `<short reason>` — I'll run `/mi-update-blueprint --reason-kind=spec-update <reason>` to rotate `blueprints/current/` into history and regenerate `requirements.md` / `config.md` / `diagrams/` from the **implementation** (codebase + `base-commit..HEAD` diff) plus the just-rotated history version. The previous blueprint's `todo-item-ids`, `## Planned`, `## Non-goals`, `## GIT BRANCH`, and `## Inspector Additions` are preserved verbatim. The active quest cycle's `todo-list.md` and `summary.md` (under `quest/<slug>/`) and `journal/` are NOT consulted.
>   - `auto` — I'll analyze `blueprints/current/requirements.md` against the implementation (`base-commit..HEAD` diff + current code) to detect drift myself. If I find meaningful divergence (added requirements, dropped scope, shifted boundaries), I'll generate a one-line reason summary and run `/mi-update-blueprint --reason-kind=spec-update <auto-detected reason>`. If I don't find drift, I'll skip the rotation and mark drift-check complete.
>   - `continue` — proceed without updating the blueprint. Any drift will surface as findings during inspector review.
>
> Skipping is fine — the review loop catches drift via `re-spec` / `re-plan` findings if needed."

#### Auto-detect analysis (only when `drift_reply == "auto"`)

The LLM performs the analysis before the dispatch block runs and assigns the result to `$auto_reason`:

- **Inputs:** `blueprints/current/requirements.md` (the spec narrative — intent, scope, what was promised), `git diff base-commit..HEAD` (what was actually built), and any code files needed to disambiguate the diff.
- **What counts as drift:** divergence between the spec's intent and the implementation that won't be self-corrected by regeneration. Specifically — requirements added during brainstorming that the spec doesn't mention, scope dropped from the spec that wasn't built, or a meaningful shape/seam change (e.g., spec says "REST endpoint", implementation landed a WebSocket). A pure re-derivation that would produce the same Goals does NOT count — `/mi-update-blueprint` already re-derives Goals from the implementation, so cosmetic-only deltas are wasted rotation.
- **Output contract:**
  - Drift found → set `$auto_reason` to a one-line summary describing the divergence (this becomes the `summary` field of `history/v[N+1]/reason.md`).
  - No drift → set `$auto_reason` to the empty string. The dispatch will skip the rotation and only persist the marker.

```bash
if [[ "${drift_prompt_required:-0}" == "1" ]]; then
  # Wait for the inspector's reply, captured into $drift_reply by the LLM.
  # When $drift_reply == "auto", the LLM also performs the auto-detect analysis
  # described above and assigns the result to $auto_reason (non-empty if drift,
  # empty if no drift).
  if [[ "$drift_reply" == "auto" ]]; then
    if [[ -n "${auto_reason:-}" ]]; then
      # Auto-detect found drift — same side effect as the reason path.
      /mi-update-blueprint --reason-kind=spec-update "$auto_reason"
    fi
    # No-drift branch: fall through to the marker write below, no rotation.
  elif [[ "$drift_reply" != "continue" && -n "$drift_reply" ]]; then
    # Drift side effect: invoke /mi-update-blueprint with --reason-kind=spec-update.
    # The --reason-kind=spec-update tag is what makes the Step 0 probe detect this
    # cycle's drift on retry (it walks history versions K > history-baseline-version
    # for kind=spec-update).
    /mi-update-blueprint --reason-kind=spec-update "$drift_reply"
  fi
  # Split marker write — runs whether the inspector continued, supplied a reason,
  # or chose auto (drift or no-drift). Splitting it from the side effect closes F1
  # (a session break between /mi-update-blueprint's return and this line is
  # recovered by the Step 0 probe on the next /mi-continue).
  $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "drift-check-completed=true"
fi
```

### Resume Step 5 — Generate implementation diagrams

Run `/mi-draw-diagrams` (the user-facing wrapper around `mi-generate-implementation-diagrams`). The command renders the diagram set of `base-commit..HEAD` into `implementation/diagrams/`, framing pre-existing participants/classes/flows as shaded context next to the new functionality.

### Resume Step 6 — Create inspector-review skeleton

Initialize the inspector-review skeleton (idempotent — `review.sh init` refuses to overwrite, so skip the call if the file already exists). The stage advance is deferred to Step 7 so the whole resume sequence finalizes atomically.

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
ov_file="$data_root/workflow-stream/$active_feature/implementation/inspector-review.md"
[[ -f "$ov_file" ]] || $CLAUDE_PLUGIN_ROOT/scripts/review.sh init "$active_feature"
```

### Resume Step 7 — Final atomic advance-to (3 → 5, sub-flow=none)

The Resume Handler eliminates stage 4 as a persisted state. The atomic `advance-to 3 5 --set sub-flow=none` collapses the old "advance 3 then advance 4" pair into a single transition, so a session break inside the handler can never strand the workflow at stage 4 with sub-flow=resuming.

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh advance-to 3 5 --set sub-flow=none
```

Tell the inspector. The wording branches on `implementation-diagrams-skipped` so the review target is unambiguous:

```bash
skipped="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get implementation-diagrams-skipped 2>/dev/null || echo 'false')"
```

**When `skipped=false` (the normal case):**

> "Stage 5 — ready for your review. Look at: commits `$base_commit..HEAD` and diagrams under `implementation/diagrams` (existing-system context is shaded grey; new functionality is highlighted).
>
> *Note on seeded-only diagrams:* if `implementation/diagrams/README.md` flags any subject as `seeded-only`, that `.puml` is a verbatim copy of the stage-2 blueprint diagram — those subjects had no implementation commits in `base-commit..HEAD`. Treat them as 'design intent preserved' rather than implementation drift; the legend wording (e.g., 'Planned') reflects the stage-2 baseline.
>
> Before reviewing the implementation, would you like a manual test plan generated for this feature? (`y`/`n`)
>
>   - `y` — I'll generate `workflow-stream/<active_feature>/test/manual-test-plan.md` based on the blueprint + implementation diff + a codebase scan. After generation I'll offer to run it — either as a guided walkthrough (I bring the environment up and walk you through each case) or fully hands-off. Failures can auto-seed as findings.
>   - `n` — skip manual testing; go directly to findings authoring (write into `implementation/inspector-review.md`, or leave empty to approve).
>
> Reply `y` or `n`."

**When `skipped=true` (inspector answered `n` to stage-4 diagram prompt):**

> "Stage 5 — ready for your review. Look at: commits `$base_commit..HEAD` and the **stage-2 blueprint diagrams** under `blueprints/current/diagrams` (implementation diagrams were skipped at stage 4 — the blueprint diagrams remain authoritative for this cycle).
>
> Before reviewing the implementation, would you like a manual test plan generated for this feature? (`y`/`n`)
>
>   - `y` — generate `manual-test-plan.md` and offer to run it (guided walkthrough or fully hands-off). Failures can auto-seed as findings.
>   - `n` — skip manual testing; go directly to findings authoring (write into `implementation/inspector-review.md`, or leave empty to approve). To generate implementation diagrams now, run `/mi-draw-diagrams` first.
>
> Reply `y` or `n`."

**On the manual-test prompt's reply:**

- `y` → auto-fire `/mi-manual-test-plan --from-resume`. The flag suppresses the duplicate no-existing-plan y/n prompt at `/mi-manual-test-plan` step 2; if a plan already exists, that skill uses it unchanged instead of rotating it silently. Stop driving — the new skill takes over and converges back into the existing flow.
- `n` → set the manual-test phase as declined and continue to findings authoring:

  ```bash
  $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set manual-test-state=skipped manual-test-failure-policy=none
  ```

  Then print the existing stage-5 review message tail (`"Write your findings into implementation/inspector-review.md (or leave it empty to approve). Type /mi-continue when done."`).

Stop here.

---

## Manual-Test-Resume Handler (current-stage = 5, sub-flow = manual-testing)

Reached when the dispatcher matches the `5 | manual-testing` row (a manual-test run is paused mid-scenario, in progress, or finished writing results but hasn't cleared `sub-flow` yet — the auto-seed loop crashed or the workflow was interrupted between `state=complete` and the final `sub-flow=none manual-test-state=complete` mutation).

### Manual-Test-Resume Step 1 — Read state

```bash
mt_state="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get manual-test-state)"
mt_policy="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get manual-test-failure-policy)"
plan_path="$($CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh manual-test-plan-path "$active_feature")"
results_path="$($CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh manual-test-results-path "$active_feature")"
plan_exists=$([[ -f "$plan_path" ]] && echo 1 || echo 0)
results_exists=$([[ -f "$results_path" ]] && echo 1 || echo 0)
results_state=""
results_cursor=""
if [[ "$results_exists" == 1 ]]; then
  results_state="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$results_path" state 2>/dev/null || echo '')"
  results_cursor="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$results_path" current-scenario 2>/dev/null || echo '')"
fi
```

### Manual-Test-Resume Step 2 — Dispatch

| Condition                                                                          | Behavior                                                                                                                                                                                                                                |
| ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `plan_exists=1`, `results_exists=0`                                                | Plan was generated and `/mi-manual-test-run` was auto-fired, but the run crashed before step 1 created the results file. Print `"Resuming manual test — results file missing, will recreate from template."` Auto-fire `/mi-manual-test-run` (Branch A); step 1 of the run renders the results template from scratch and step 2 runs the env-up phase as if from fresh. |
| `plan_exists=0`, `results_exists=0`                                                | Inconsistent state — markers say a run is in progress but neither input file exists. Print: `"Inconsistent manual-test state: sub-flow=manual-testing but no plan or results file. Reset with progress.sh set sub-flow=none manual-test-state=none and start over via /mi-continue (which will re-prompt for plan generation), OR run /mi-resume-workflow for full diagnosis."` **Stop. Do NOT auto-mutate.** |
| `plan_exists=1`, `results_exists=1`, `results_state=in-progress`, `results_cursor` non-null | Paused mid-run. Print `"Resuming manual test at scenario $results_cursor."` — then, per the persisted `manual-test-env-mode` (`progress.sh get manual-test-env-mode`; missing/null = `interactive`): interactive → append `"Re-confirm your local environment is up."`; guided → append `"The millwright will re-probe and relaunch any stopped services, then walk you through the remaining scenarios."`; autonomous → append `"The millwright will re-probe and relaunch any stopped services, then continue performing the remaining scenarios itself."` Auto-fire `/mi-manual-test-run` (Branch A). |
| `plan_exists=1`, `results_exists=1`, `results_state=in-progress`, `results_cursor` null     | Results file rendered but loop never reached scenario 1. Same as above — auto-fire `/mi-manual-test-run` (Branch A) to start from scenario 1.                                                                                  |
| `plan_exists=1`, `results_exists=1`, `results_state=complete`                      | **Reachable, not defensive.** `/mi-manual-test-run` writes `state=complete` BEFORE the auto-seed loop and BEFORE clearing `sub-flow` (deliberately, so a crash mid-seed leaves `sub-flow=manual-testing` for re-entry). The handler must NOT clear sub-flow and fall through to the Inspector Handler — that would bypass the seed-recovery path. **Auto-fire `/mi-manual-test-run --seed-only`** (Branch B). Branch B's entry-guard table dispatches on `manual-test-failure-policy` and either re-prompts, re-runs the upsert loop, or finalizes. Branch B clears `sub-flow=none` as its last mutation; the next `/mi-continue` lands in the Inspector Handler. |

After auto-fire, stop driving — the run skill drives the inspector; another `/mi-continue` post-run lands in the Inspector Handler.

---

## Inspector Handler (current-stage = 5)

Runs after the inspector has reviewed the implementation and either filled `inspector-review.md` with findings or left it empty.

### Inspector Step 0 — Manual-test summary line (read-only)

If `workflow-stream/<active_feature>/test/manual-test-results.md` exists, surface a one-line summary in the entry log:

```bash
results_path="$($CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh manual-test-results-path "$active_feature")"
if [[ -f "$results_path" ]]; then
  passed="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$results_path" passed)"
  failed="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$results_path" failed)"
  total="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$results_path" total)"
  policy="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get manual-test-failure-policy)"
  # seeded_failed = count of failed verdict blocks whose `Seeded:` field is `true`.
  # Computed from the verdict blocks; do NOT infer from manual-test-failure-policy.
  seeded_failed="$(awk '
    /^### / && /— /              { in_block=1; verdict=""; seeded=""; next }
    /^- \*\*Verdict:\*\* /        { verdict=$3; next }
    /^- \*\*Seeded:\*\* /         { seeded=$3 }
    in_block && (/^### / || /^## /) { if (verdict=="fail" && seeded=="true") c++; in_block=0 }
    END                           { if (verdict=="fail" && seeded=="true") c++; print (c+0) }
  ' "$results_path")"
  echo "Manual test: $passed/$total passed, $failed failed (failure-policy: $policy; seeded $seeded_failed/$failed failures)."
fi
```

**The Inspector Handler must NOT mutate `inspector-review.md` because of manual-test results.** By the time this handler runs, `/mi-manual-test-run` has already either run the auto-seed loop (possibly leaving some failed scenarios unseeded if the inspector picked `skip` on per-IR prompts) or recorded `failure-policy=manual` and written nothing. Seeded failures are already-canonical `### IR-NNN` blocks. The handler must not auto-seed, reopen, reclassify, or rewrite seeded IR blocks based on `manual-test-results.md`.

The existing canonicalization pass at Step 1.5 below remains allowed to mutate `inspector-review.md` for **inspector-authored free-form review text** — that is a separate legacy behavior and not a manual-test write path. Idempotency for seeded blocks is enforced durably by the `- seed-id:` field on each auto-seeded IR-NNN block (`/mi-manual-test-run`'s single-owner discipline; see `docs/manual-testing/plan.md` § 2.2 "Auto-seed ownership recap").

### Inspector Step 1 — Verify inspector-review.md exists

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
ov_file="$data_root/workflow-stream/$active_feature/implementation/inspector-review.md"
[[ -f "$ov_file" ]] || {
  echo "inspector-review.md not found — did you mean to approve with no findings?" >&2
  read -p "Create empty inspector-review.md and approve? (y/n): " ans
  [[ "$ans" == "y" ]] || exit 1
  $CLAUDE_PLUGIN_ROOT/scripts/review.sh init "$active_feature"
}
```

### Inspector Step 1.5 — Canonicalize free-form findings

The inspector is encouraged to write findings as plain sentences — one per line or paragraph — under `## Implementation Review`. Before checking for open findings, normalize the file so every finding is in `### IR-NNN — ...` block format. Without this step, a free-form finding would slip past `list-open` (which only matches structured `### IR-NNN` headings with a `- status: open` line) and the workflow would silently auto-finalize as "approved with no findings."

```bash
unstructured="$($CLAUDE_PLUGIN_ROOT/scripts/review.sh canonicalize "$active_feature" || true)"
canon_exit=$?
```

`canonicalize` exits `0` (already canonical — skip to Step 1.6), `3` (unstructured spans found — proceed below, then continue to Step 1.6), or non-zero (error — surface and abort). When spans are found, `stdout` carries one TSV row per span: `<line-start>\t<line-end>\t<flattened-text>`.

For each TSV row, the millwright (the LLM, not the script) classifies and converts:

1. **Read the text snippet.** Use it as the basis for the structured block's summary and details.
2. **Classify severity** (default `major`):
   - `blocker` if the text contains absolute language (`must`, `critical`, `breaks`, `required`, `cannot ship`).
   - `minor` if the text is hedged (`nit`, `prefer`, `could`, `maybe`, `optional`).
   - `major` otherwise.
3. **Classify scope** (default `re-implement` for refactoring suggestions, `fix` for small patches):
   - `fix` — small patch (typo, edge case, single-line behavior change, missing test).
   - `re-implement` — refactoring an existing module without changing the spec ("move to common folder", "rename", "extract", "should be generic").
   - `re-plan` — adds tasks not in the original plan ("also add X", "wire up Y", "missing handler for Z").
   - `re-spec` — challenges the design ("wrong abstraction", "should use a different pattern", "this approach won't scale").
4. **Generate a one-line summary** (≤ 80 chars) capturing the finding's intent.
5. **Add the structured block:**
   ```bash
   echo "<full original text>" | $CLAUDE_PLUGIN_ROOT/scripts/review.sh add \
     "$active_feature" "<severity>" "<scope>" "<summary>"
   ```
   The original text becomes the block's `details:` body so the inspector's wording is preserved verbatim.
6. **Strip the original freeform span.** After all spans have been added, call `strip-freeform` for each one **in reverse line order** (highest line first) so earlier line numbers stay valid:
   ```bash
   $CLAUDE_PLUGIN_ROOT/scripts/review.sh strip-freeform "$active_feature" <line-start> <line-end>
   ```

When all spans are converted, tell the inspector:

> "I converted **N** free-form finding(s) into `### IR-NNN` blocks. Severity and scope are my classifications — open `inspector-review.md` to override before the review session begins. Continuing to review..."

Then fall through to Step 1.6.

### Inspector Step 1.6 — Persist review-mode-suggestion

After canonicalization completes (whether spans were found or the file was already canonical), compute the scope-distribution suggestion that stage 6 will use to default its review-mode prompt. The hint is computed here, at canonicalization time, because findings are already classified and the scope is stable; computing it again at stage 6 would re-derive the same fact.

Logic:

- If `review.sh list-open` returns nothing (zero open findings): `suggestion=none`.
- If every open finding has `scope: fix`: `suggestion=direct`.
- If at least one open finding has scope ≠ fix: `suggestion=brainstorming`.

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
ov_file="$data_root/workflow-stream/$active_feature/implementation/inspector-review.md"
open_count="$($CLAUDE_PLUGIN_ROOT/scripts/review.sh list-open "$active_feature" | wc -l | tr -d ' ')"
if [[ "$open_count" == "0" ]]; then
  suggestion="none"
else
  # Walk inspector-review.md; flag if any open finding has scope != fix.
  has_non_fix="$(python3 - "$ov_file" <<'PYEOF'
import re, sys
with open(sys.argv[1]) as f:
    content = f.read()
for m in re.finditer(r'### (IR-\d{3}) —.*?\n(.*?)(?=\n### |\n## |\Z)', content, re.DOTALL):
    block = m.group(2)
    status = re.search(r'^- status:\s*(\S+)', block, re.MULTILINE)
    scope = re.search(r'^- scope:\s*(\S+)', block, re.MULTILINE)
    if status and status.group(1) == 'open' and scope and scope.group(1) != 'fix':
        print('1')
        sys.exit(0)
print('0')
PYEOF
)"
  if [[ "$has_non_fix" == "1" ]]; then
    suggestion="brainstorming"
  else
    suggestion="direct"
  fi
fi
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "review-mode-suggestion=$suggestion"
```

The persisted hint is read at stage 6 by `commands/mi-review.md` Step 2.6 to default the `review-mode` prompt — `direct` defaults to direct mode with an explicit rationale; `brainstorming` and `none` keep the current default. The field is `none` until stage 5 sets it, and resets to `none` at the next feature's `progress.sh activate`.

Then fall through to Step 2.

### Inspector Step 2 — Check for open findings

```bash
open_ids="$($CLAUDE_PLUGIN_ROOT/scripts/review.sh list-open "$active_feature")"
```

### Inspector Step 3a — No findings

If `open_ids` is empty, **prompt the inspector to confirm before completing the stage**. This guard exists because the no-findings path auto-fires `/mi-complete-workflow` immediately — once it runs, the workflow archives blueprints and advances the queue, which is non-trivial to undo. The confirmation gives the inspector one explicit beat to add findings instead.

> "`inspector-review.md` has no open findings. Confirming will complete the inspector-review stage and auto-fire `/mi-complete-workflow`. Continue?
>
>   - `y` — finalize the inspector-review stage and proceed.
>   - `n` — stop here. Add findings to `inspector-review.md`, then re-run `/mi-continue` when ready.
>
> (y/n)"

- **On `n`** — stop. Do **not** advance the stage. State stays at `current-stage=5`, so the next `/mi-continue` re-enters this handler (idempotent: if findings were added, it routes to Step 3b instead; if still empty, it re-prompts).
- **On `y`** — proceed with the atomic advance below.

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh advance-to 5 7 \
  --set sub-flow=none \
  --set inspector-review-completed=true
```

The single `advance-to 5 7 --set ...` collapses the no-findings approve path's stage advances and the `inspector-review-completed=true` write into one atomic transition (Item 4 of the v11 plan). A session break inside this block can never strand the workflow at stage 6 with sub-flow=none — either everything lands or nothing does.

Tell the inspector: "Approved — no findings. Auto-finalizing via `/mi-complete-workflow`."

Then auto-invoke `/mi-complete-workflow` immediately. Do not wait for a further inspector signal — the loop's clean exit is itself the trigger.

### Inspector Step 3b — Findings present

Hand the review off to a **brainstorming review session** by invoking `/mi-review`. The session runs **isolated from mi-workflow — same isolation model as stage 3**. After invoking `/mi-review`, control returns to the inspector, who drives the session through to its terminal state (typing `approve`).

```bash
# /mi-review handles the stage-5-to-6 clear-point gate (Step 1.5), sub-flow=reviewing,
# the stage 5→6 advance, and the Skill invocation, then hands off. It does NOT block
# on the Skill.
/mi-review
```

After `/mi-review` returns, **stop**. Do not advance the stage. Do not auto-fire `/mi-complete-workflow`. The Review-Resume Handler will run when the inspector types `/mi-continue` again after the brainstorming review session exits.

**If `/mi-review` halted at its `stage-5-to-6` clear-point gate** (first entry — it printed a `/clear` recommendation and did NOT launch the session), say nothing further: the gate's recommendation is the terminal message for this turn. State stays at `current-stage=5`, so the inspector's next `/mi-continue` re-enters this handler and auto-fires `/mi-review` again, which then proceeds past the gate.

Otherwise tell the inspector: "Brainstorming review session is now live (isolated from mi-workflow). Drive it to completion (typing `approve` when ready), then type `/mi-continue` to resume the mi-workflow."

**Why no scope-tier dispatch here.** Earlier versions of mi-workflow encoded a scope-tier cascade (re-spec → re-plan → re-implement → fix) inside this handler. That logic moved into the brainstorming session itself: the chain reads each finding's `scope:` as a hint and chooses the smallest cascade that resolves the root cause. Mi-workflow no longer needs to know about scopes during the loop — only that brainstorming exited cleanly.

**No iteration cap.** Brainstorming controls its own loop; the inspector ends it by typing `approve`. If the inspector accumulates many findings and the loop runs long, it's their judgment call to interrupt with `/mi-abort-workflow`.

---

## Review-Resume Handler (current-stage = 6, sub-flow = reviewing)

Runs after the brainstorming review session has fully exited and returned control. Sanity-checks the findings status, advances 6 → 7, and auto-fires `/mi-complete-workflow`.

This handler exists because stage 6's brainstorming review session runs **isolated from mi-workflow** — same as the stage-3 chain. There is no programmatic signal that the session ended; the inspector's `/mi-continue` is the explicit resumption signal.

### Review-Resume Step 1 — Open-findings completion check

```bash
remaining_open="$($CLAUDE_PLUGIN_ROOT/scripts/review.sh list-open "$active_feature")"
```

If `remaining_open` is empty, **prompt the inspector to confirm before completing the stage**. This guard mirrors Inspector Step 3a: once finalize fires, `/mi-complete-workflow` archives blueprints and advances the queue, so the inspector gets one explicit beat to re-launch the review session or add new findings instead.

> "All findings have been resolved (no open findings remain in `inspector-review.md`). Confirming will complete the inspector-review stage and auto-fire `/mi-complete-workflow`. Continue?
>
>   - `y` — finalize the inspector-review stage and proceed (continues to the diagram-refresh prompt and atomic finalize).
>   - `n` — stop here. Re-launch `/mi-review` if more findings need to be addressed, or re-run `/mi-continue` when ready.
>
> (y/n)"

- **On `n`** — stop. Do **not** advance past stage 6. State stays at `current-stage=6, sub-flow=reviewing`, so the next `/mi-continue` re-enters this handler (idempotent: re-runs `review.sh list-open` and re-prompts if still empty, or routes to the non-empty branch below if findings were reopened).
- **On `y`** — fall through to Step 2 (advance and finalize).

If `remaining_open` is non-empty, the review session ended without resolving every finding — the same ambiguity as the stage-3 abandoned-chain case. The session may have exited cleanly with intentionally-deferred findings, or it may have been interrupted mid-loop. The three replies below are NOT auto-defaulted; the inspector must pick deliberately, because the choice has different downstream consequences. Prompt the inspector:

> "Review session ended with **N** open finding(s): `<id-list>`. Pick one — there is no default:
>
>   - `completed` — **You and the chain intentionally deferred these findings as non-blocking follow-up work.** The workflow advances 6 → 7 with the finding(s) still `open`. `mi-complete-workflow` archives `inspector-review.md` into `blueprints/history/v[N]/implementation/` at stage 8, so the deferred findings remain queryable in the historical record. Use this when you've decided the open findings are worth tracking but not worth blocking this cycle on. (If you want them *addressed* in this cycle instead of just archived, choose `abandoned` instead — `completed` does not re-launch the review loop.)
>   - `abandoned` — **The session was interrupted mid-loop, or the findings still need to be addressed.** Re-launches the brainstorming review session via `/mi-review`. Stage stays at 6 until the session exits cleanly; you'll type `/mi-continue` again afterward.
>   - `abort` — **Something went wrong — cancel the workflow.** Invokes `/mi-abort-workflow`.
>
> Reply with one of the three keywords."

- **On `completed`** — fall through to Step 2.
- **On `abandoned`** — invoke `/mi-review` (which reads the open findings, prompts for a review-mode, and re-launches the loop) and **stop**. Do NOT advance past stage 6. The next `/mi-continue` after the new session exits will re-enter this handler.
- **On `abort`** — invoke `/mi-abort-workflow` and stop.

### Review-Resume Step 2 — (deferred to Step 2.6 finalize)

`sub-flow=reviewing` stays in place until after the diagram-refresh prompt at Step 2.5 (Item 4 of the v11 plan). This makes the refresh prompt re-fireable on retry — if a session break happens between "inspector answered the prompt" and "rotation finalized," the next `/mi-continue` re-enters this handler and re-prompts (the inspector can answer the same way; the prompt is idempotent because no state changed yet).

### Review-Resume Step 2.5 — Offer diagram refresh (or recovery)

The review session may have committed new code. Before finalizing, offer the inspector a chance to update implementation diagrams. The prompt branches on the multi-state output of `commits.sh diagrams-fresh`:

```bash
freshness="$($CLAUDE_PLUGIN_ROOT/scripts/commits.sh diagrams-fresh "$active_feature" 2>/dev/null)"
freshness_exit=$?
```

Branch on `freshness`:

- **`fresh`** (exit 0) — diagrams are already current. Skip the prompt entirely; fall through to Step 2.6.
- **`stale`** (exit 0) — refresh prompt:

  > "The review session committed additional commits since the implementation diagrams were generated. Regenerate them?
  >
  >   - `y` — re-run `/mi-draw-diagrams` before finalizing (~30 seconds; useful so the final snapshot reflects the review-loop fixes before stage 8 archives the diagrams into `blueprints/history/v[N+1]/implementation/diagrams/`).
  >   - `n` — proceed directly to `/mi-complete-workflow`. The diagrams stay at the post-chain snapshot; they'll be archived as-is (not deleted) at stage 8.
  >
  > (y/n)"

- **`skipped`** (exit 0) — recovery prompt (stage 4 was skipped):

  > "Implementation diagrams were skipped at stage 4. The review session committed commits in `base-commit..HEAD` since then. Reply:
  >   - `y` — generate implementation diagrams now via `/mi-draw-diagrams` (~30s; covers the full `base-commit..HEAD` range and clears the skip marker so stage 8 archives them).
  >   - `n` — proceed without implementation diagrams. Stage-2 blueprint diagrams remain the only diagram artifact archived at stage 8.
  >
  > (y/n)"

- **`missing`** (exit non-zero) — diagnostic. Surface to the inspector and ask how to proceed:

  > "diagrams-fresh returned `missing` for `$active_feature` — the workflow expected either implementation diagrams to exist OR the skip marker to be set, but neither holds. Reply:
  >   - `y` — generate implementation diagrams now via `/mi-draw-diagrams` (treats this as a fresh stage-4 entry).
  >   - `n` — proceed without implementation diagrams.
  >   - `abort` — invoke `/mi-abort-workflow` for a clean recovery."

On `y` (any branch), invoke `/mi-draw-diagrams`. The wrapper's Step 1.5 routes correctly: for `skipped=true` it offers the recovery prompt (then clears the marker after success); for `skipped=false` it offers the regular stage-4 prompt or proceeds directly when `diagram-prompt=auto`. Either way, after `/mi-draw-diagrams` returns successfully, `implementation-diagrams-skipped` will be `false`. Continue to Step 2.6.

On `n`, continue to Step 2.6 unchanged.

On `abort` (only valid for the `missing` branch), invoke `/mi-abort-workflow` and stop.

### Review-Resume Step 2.6 — Atomic finalize (advance-to 6 → 7)

After the refresh prompt has been answered (or skipped), finalize the review-resume sequence in one atomic write. This collapses the old "set sub-flow=none + set inspector-review-completed=true + advance 6" trio into a single transition (Item 4 of the v11 plan), so a session break here cannot strand the workflow at stage 6 with sub-flow=none and the marker only half-set.

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh advance-to 6 7 \
  --set sub-flow=none \
  --set inspector-review-completed=true
```

### Review-Resume Step 3 — Auto-fire /mi-complete-workflow

Tell the inspector: "Inspector-review session approved. Auto-finalizing via `/mi-complete-workflow`."

Then auto-invoke `/mi-complete-workflow` immediately. Do not wait for a further inspector signal — the third `/mi-continue` is itself the trigger.

---

## PR-Review Apply Handler (routed from Step 2.0)

Runs when Step 2.0 routed a PR-review `report.md` here — the inspector ran `/mi-analyze-review`, marked blocks, and typed `/mi-continue`. `$report` is the report path Step 2.0 selected. See `docs/user-reviews/plan.md` § 6.2 for the design.

### Apply Step 1 — Canonicalize

```bash
$CLAUDE_PLUGIN_ROOT/scripts/pr-review.sh canonicalize "$report"
```

`canonicalize` renumbers the `PR-NNN` ids and validates every block has an `action` and `status` line (exit 3 on a structural error — if it fails, read the offending block, fix it with Edit, and re-run).

### Apply Step 2 — Guard, normalize, collect actionable blocks

1. **Guard a fresh report.** Count marked blocks **before** normalizing:
   ```bash
   report_status="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$report" status)"
   marked_count="$($CLAUDE_PLUGIN_ROOT/scripts/pr-review.sh count-marked "$report")"
   ```
   If `report_status == "awaiting-marks"` and `marked_count == 0`, print and stop — leaving the report **unchanged**:

   > "No blocks marked. Open `<report>`, flip `[ ]` → `[x]` on the blocks you want acted on, then re-run `/mi-continue`."

   The guard is scoped to `awaiting-marks`; a `partial` report continues into normalization (un-marking a stuck block is the intended way to retire it).
2. **Normalize.** `pr-review.sh normalize "$report"` — every unmarked (`[ ]`) block in a non-terminal status (`open`, `reply-failed`, `reply-declined`, `fix-failed`, `fix-blocked`) becomes `skipped`.
3. **Collect.** `pr-review.sh list-actionable "$report"` — TSV rows `<PR-NNN>\t<action>\t<comment-kind>\t<status>` for every **marked, non-terminal** block. Terminal blocks (`applied`/`replied`/`skipped`) are excluded even if still `[x]`, so a `partial` re-run never re-applies a fix, re-posts a reply, or re-appends a lesson.
4. If the actionable set is empty, skip Steps 3–7 and go straight to **Apply Step 8** (finalize) — normalization above may have cleared the last stuck block, so the report can still legitimately transition `partial → applied`. Print "No blocks to apply" first.

### Apply Step 3 — Split by action

Partition the actionable rows into **fix blocks** (`action: fix`) and **reply blocks** (`action: reply`). Steps 4–5 (fixes) and Step 6 (replies) run independently — a reply-only run must never be blocked by fix-only worktree concerns.

### Apply Step 4 — gh preflight, repo guard (always), checkout (fix blocks only)

```bash
repo="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$report" repo)"
pr_number="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$report" pr-number)"
```

- **gh preflight (always, first).** Before the repo guard, verify `gh` is usable: `command -v gh` and `gh auth status`. If `gh` is missing, stop with the install hint; if it is installed but not authenticated, stop with `gh auth login`. This must run **first** — without it a missing/unauthenticated `gh` makes `gh repo view` print nothing, and the empty result would surface as a misleading "wrong checkout" error instead of the real auth problem.
- **Repo guard (always).** With `gh` confirmed usable:
  ```bash
  cwd_repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo '')"
  ```
  If `cwd_repo` is empty or `!= repo`, refuse — `/mi-continue` is running in the wrong checkout. Relay the mismatch and stop.
- **Only when fix blocks exist:**
  - Refuse if the working tree is dirty (`git status --porcelain` non-empty) — ask the inspector to stash or commit first.
  - `gh pr checkout "$pr_number"` to land fixes on the PR's head branch. If `gh pr checkout` produces a detached HEAD or a fork-tracking branch, surface that to the inspector rather than committing blindly. If the PR is merged or closed, warn and ask the inspector to confirm a target branch before proceeding.
- **Reply-only run:** skip this checkout bullet entirely — posting replies needs only GitHub API access, not a clean tree or a checkout.

### Apply Step 5 — Apply fixes (skipped when there are no fix blocks)

Spawn the fixer with `subagent_type: millwright-inspector-development-machine:pr-review-fixer`. Spawn prompt:

```
You are a fresh sub-agent invoked from /mi-continue's PR-Review Apply Handler.
Apply the inspector-marked fix blocks from a PR-review report.

Report:          <report>
Fix block ids:   <space-separated PR-NNN list of action:fix actionable blocks>
PR URL:          <pr-url from report frontmatter>
Plugin scripts:  <absolute path to $CLAUDE_PLUGIN_ROOT/scripts>

The working directory is already on the PR's head branch. For each fix block:
read its proposed-fix + inspector-notes (inspector-notes overrides on conflict),
apply the change, commit (do NOT push), and set the block status via
`<plugin-scripts>/pr-review.sh set-status <report> PR-NNN applied`.

Clean-worktree invariant: a fix-failed / fix-blocked block must leave NO
uncommitted changes — revert that block's partial edits before returning the
failure, and set the block status to fix-failed or fix-blocked accordingly. If a
clean working tree cannot be restored, STOP, return Result: blocked, and list
the dirty files — do not process further blocks.

For each block you set to `applied` whose verdict is `valid`, distill one
concrete lesson and append it:
  echo "<lesson>" | <plugin-scripts>/lessons.sh append --source "<pr-url> · PR-NNN" --title "<title>"

Follow agents/pr-review-fixer.md for the full contract and return shape. Return
a per-block outcome line, commit shas, and an explicit `Worktree: clean|dirty`
line. Total return ≤ 1k tokens. Return only the contract structure.
```

If the fixer returns `Result: blocked` with a dirty worktree, **stop the handler** — relay the dirty files to the inspector and do not run Steps 6–8. The inspector resolves the worktree, then re-runs `/mi-continue`.

### Apply Step 6 — Post replies (skipped when there are no reply blocks)

For each **actionable reply block** (marked `[x]` and non-terminal — never a terminal `replied` block), read its `proposed-reply`, `comment-url`, and `comment-kind`, and show the inspector exactly what will be posted and where:

```
PR-NNN → <comment-kind> reply to <comment-url>:
<proposed-reply text>
```

Posting to GitHub is an external, visible write — ask for one explicit confirmation covering all reply blocks (`yes` / `no` / `select`). Then, per block:

- **Confirmed** → `pr-review.sh post-reply "$report" PR-NNN`. The script posts via the endpoint for the `comment-kind` (`review-comment` → threaded reply; `review-summary` / `issue-comment` → a new PR conversation comment quoting the original) and sets the block status to `replied` on success. If `post-reply` exits non-zero, set the block status to `reply-failed` with `pr-review.sh set-status` and report the failure.
- **Declined** → `pr-review.sh set-status "$report" PR-NNN reply-declined`. The block stays marked for a future retry.

### Apply Step 7 — Lessons

Lessons are appended by the fixer sub-agent in Step 5 (one per applied `valid` fix), not here. If the fixer's return named `lessons-learned.md` under `Artifacts changed`, mention in the summary that lessons were recorded — do not re-read the file.

### Apply Step 8 — Finalize from all blocks

```bash
new_status="$($CLAUDE_PLUGIN_ROOT/scripts/pr-review.sh report-status "$report")"
```

`report-status` scans **every** block, sets the report frontmatter `status` to `applied` (all blocks terminal) or `partial` (any block still non-terminal), and prints the result. Then summarize for the inspector:

- Counts: fixes applied / failed / blocked, replies posted / declined / failed.
- If `partial`: name the non-terminal blocks and tell the inspector they can re-run `/mi-continue` to retry, or un-mark a block to drop it.
- If `applied`: confirm the report is complete. Remind the inspector that fix commits are **on the PR branch but not pushed** — pushing is their call.

The PR-Review Apply Handler does not auto-fire any other command.

## Notes

- `/mi-continue` is a dispatcher — it reads state and acts. It never asks the inspector which stage we're at.
- For state outside the known stages (3, 5, or 6+reviewing), the dispatcher falls through to `/mi-resume-workflow` for diagnosis rather than erroring out.
- The mi-workflow does not read or modify the chain's spec/plan files under `docs/superpowers/` in the happy path. Re-entry into `brainstorming` / `writing-plans` / `executing-plans` for `re-spec` / `re-plan` cascades is via concern-bundle primers; the chain regenerates its own artefacts internally and produces fresh commits in `base-commit..HEAD`. **The single exception** is the abandoned-chain recovery branch in Resume Step 2.5, which reads the chain's plan and spec **read-only** to compose a resume primer when the inspector reports an interrupted run. No mi-workflow command writes to `docs/superpowers/`.
- Both the stage-3 chain and the stage-6 brainstorming review session run **isolated from mi-workflow**. Neither auto-detects skill completion — the explicit `/mi-continue` from the inspector is the resumption signal in both cases.
- If invariants are violated (e.g., `current-stage=4` but `implementation-completed=false`), stop and recommend `/mi-resume-workflow` for diagnosis.
