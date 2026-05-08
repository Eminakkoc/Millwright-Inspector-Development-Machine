---
description: Universal advancement signal for the mo-workflow. Dispatches to the right handler for the current state — pre-flight (after marking todos / approving blueprints), post-chain resume, overseer-review, or post-review-session resume.
---

# mo-continue

**The single advancement signal the overseer types throughout the workflow.** Reads `progress.md` (and a few sibling files) for the current state, decides where we are, and runs the appropriate handler.

The overseer types `/mo-continue` at every gate where they previously typed a free-form approval:

1. **After marking PENDING items** in the active cycle's `todo-list.md` (stage 1.5; lives under `quest/<active-slug>/todo-list.md`). Runs the Pre-flight Handler — promotes the marked items, analyzes feature dependencies, and proposes a workflow order.
2. **After accepting the proposed queue order** (stage 1.5, second invocation). Runs the Pre-flight Handler — writes the cycle's `queue-rationale.md`, reorders the queue, and auto-fires `/mo-apply-impact`.
3. **After reviewing the blueprint** (stage 2). Runs the Approve Handler — auto-fires `/mo-plan-implementation`.
4. **After the brainstorming chain has fully exited and returned control** (stage 3 → 4; the chain produced commits in `base-commit..HEAD`). Runs the Resume Handler — generates implementation diagrams and hands off to overseer review. **Do not type `/mo-continue` while the chain is mid-prompt** (e.g., while `finishing-a-development-branch` is asking for approval); answer the chain first.
5. **After writing findings into `overseer-review.md`** (stage 5; or leaving it empty to approve). Runs the Overseer Handler — auto-completes if there are no findings, or invokes `/mo-review` and returns control to the overseer.
6. **(only if findings were present)** **After the brainstorming review session has fully exited and returned control** (stage 6 → 7). Runs the Review-Resume Handler — offers a diagram refresh, sanity-checks findings, advances, and auto-fires `/mo-complete-workflow`. **Do not type `/mo-continue` while the review session is mid-prompt**; answer the chain first.

For any other workflow state, this command falls through to `/mo-resume-workflow` to give the overseer a state diagnosis instead of erroring out.

## Execution

### Step 1 — Read state

```bash
active_feature="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get-active 2>/dev/null || echo 'null')"
queue_count="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh queue-remaining 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
# todo-list.md lives inside the active quest cycle's subfolder; resolve via quest.sh.
quest_dir="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh dir 2>/dev/null || echo "")"
todo_file="$quest_dir/todo-list.md"
```

If `progress.md` (or `quest/active.md` / the active cycle subfolder) is missing, the calls fail — surface the error and stop (no recovery here; the overseer should run `/mo-run` first).

### Step 2 — Dispatch

The dispatcher picks a handler based on whether a feature is active and, when active, on `current-stage` + `sub-flow`. Pre-flight cases (no active feature) live above the table:

**Pre-flight cases (`active_feature == "null"`):**

Order matters — Rows A/B (auto-fire) must be evaluated **after** the manual-action rows (the overseer's `[x] TODO` and queue-rationale-missing signals take precedence over auto-fire) and **before** the catch-all (otherwise they'd never run). See Item 5 of the v11 progress-gap plan for the load-bearing rationale.

| Condition | Handler |
| --- | --- |
| `[x] TODO` lines exist in `todo-list.md` (selections not yet promoted) | **Pre-flight Step 2A** — promote + propose order |
| no `[x] TODO` lines, `queue_count > 0`, `queue-rationale.md` missing | **Pre-flight Step 2B** — confirm proposed order + auto-fire `/mo-apply-impact` |
| no `[x] TODO` lines, `queue_count > 0`, `queue-rationale.md` present, top-level `status: draft` (Item 7 multi-batch) | **Pre-flight Step 2B** (extended) — confirm/update the latest batch, refresh top-level `features:`/`batch:`, flip `status` to `confirmed`, auto-fire `/mo-apply-impact` |
| **Row A — between features:** active is null AND `queue_count > 0` AND `queue-rationale.md.status` (or absent → confirmed) is `confirmed` AND `(queue-rationale.md.features − progress.completed, preserving order)` equals `progress.queue` exactly | Auto-fire `/mo-apply-impact` |
| **Row B — post-finish housekeeping recovery:** active is null AND queue empty AND no `[x] TODO` AND no `[ ] TODO` AND `progress.completed` non-empty AND `blueprints/history/v[N]/reason.md.kind == "completion"` for `completed[-1]` AND `quest/active.md.status == "active"` | Auto-fire `/mo-complete-workflow` (short-circuits to its Branch I — Step 7 housekeeping only) |
| `queue_count == 0` and no `[x] TODO` lines (catch-all) | Delegate to `/mo-resume-workflow` |

**Active cases (`active_feature != "null"`):**

```bash
current_stage="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get current-stage)"
sub_flow="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get sub-flow)"
```

| Current stage | Sub-flow         | Handler                                                       |
| ------------- | ---------------- | ------------------------------------------------------------- |
| 2             | (any)            | **Approve Handler** — auto-fire `/mo-plan-implementation`     |
| 3             | (any)            | Post-chain resume (see Resume Handler below)                  |
| **5**         | **`manual-testing`** | **Manual-Test-Resume Handler** (manual-test paused or in progress — re-enters `/mo-manual-test-run`) |
| 5             | (any)            | Overseer-review received (see Overseer Handler below)         |
| 6             | reviewing        | Post-review-session resume (see Review-Resume Handler below)  |
| 7             | (any)            | Stage-7 finalize — auto-fire `/mo-complete-workflow` (Item 4 of v11 plan; idempotent via Branch II in mo-complete-workflow when re-entered after a partial finalize) |
| any other     | —                | Delegate to `/mo-resume-workflow` for state diagnosis         |

The `5 | manual-testing` row covers paused or in-progress manual-test runs — the Manual-Test-Resume Handler re-enters `/mo-manual-test-run` to continue from the persisted `current-scenario`. It must come **before** the `5 | (any)` row in the table; tables evaluate top-down and a misordered append would shadow the manual-testing row, misrouting paused manual tests to the Overseer Handler and treating them as normal findings review.

For the "any other" case (active or pre-flight), invoke `/mo-resume-workflow` and stop — let it report state and recommend the next command.

---

## Pre-flight Handler (active=null, queue or selections pending)

Runs at stage 1.5 — between `/mo-run` (which scaffolded the queue from journal content) and `/mo-apply-impact` (which will activate the first feature). Two sub-states, distinguished by what's still pending in the source files.

### Pre-flight Step 2A — Promote selections + propose order

Reached when the overseer has just finished marking items (`[x] TODO` lines exist).

1. **Promote the marked items.**
   ```bash
   $CLAUDE_PLUGIN_ROOT/scripts/progress.sh queue-remaining >/dev/null  # confirms progress.md exists
   $CLAUDE_PLUGIN_ROOT/scripts/todo.sh pend-selected
   ```
   `pend-selected` rejects any `[x] TODO` line missing an `(assignee)` tag — relay the offenders to the overseer, ask for assignee names, and stop. The overseer fixes the file and re-types `/mo-continue`.
2. **Group PENDING items by feature.** Read `todo-list.md` and collect the set of feature section headings (`## <feature>`) that contain `[x] PENDING` lines.
3. **Detect the queue source state.**
   ```bash
   queue_count="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh queue-remaining 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
   ```
   - **If `queue_count > 0`:** the queue was seeded by `/mo-run` (initial cycle). It already lists every feature found in the journal, in some default order. Skip to step 5.
   - **If `queue_count == 0`:** mid-cycle re-entry (Finding 6 — the cycle's first batch already completed and the overseer is marking more items now). The queue must be repopulated from the freshly-PENDING feature names:
     ```bash
     $CLAUDE_PLUGIN_ROOT/scripts/progress.sh enqueue <feat1> [<feat2> ...]
     ```
     where `<featN>` is the de-duplicated set of feature headings that hold PENDING items in `todo-list.md`. `enqueue` refuses duplicates against `queue ∪ completed`, so a feature already finished in this cycle would error out — surface that to the overseer (they probably wrote a TODO under the wrong heading).
4. **Derive cross-feature ordering signals — journal-first, code-aware as fallback.** Replaces the prior unconditional codebase scan (which violated the "intake stages don't read code" invariant — see `docs/context optimization/recommendations.md` § "Issue 1"). Skip the whole step when there's only one feature in the queue.

   For ≥ 2 features, follow this three-step flow:

   **Step 4a — Journal-only proposal (Phase 4.1).** Derive the ordering from `summary.md` content alone. Read the cycle's `summary.md` `## Cross-cutting constraints` and the `## Feature: <feature>` sections (these are already in main context from stage 1). Compose a proposed order based on:
   - Explicit cross-feature references in the body (e.g., `## Feature: payments` mentioning `audit-log` is a dependency signal).
   - Dependency keywords inside feature sections: `depends on`, `blocks`, `requires`, `precondition`.
   - The default ordering produced by `/mo-run` (already in `progress.md.queue`) when no signals surface.

   This step writes nothing on its own — the proposed order is held in chat to be presented in step 5 below.

   **Step 4b — Heuristic short-circuit (Phase 4.2).** Decide whether step 4a is enough or whether a code-aware scan is justified:

   ```bash
   data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
   summary_file="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh dir)/summary.md"
   features_in_queue="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh queue-remaining | sed '/^$/d')"

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

   If `cache_hit=0`, spawn a fresh sub-agent (`Agent` invocation with `subagent_type: millwright-overseer-development-machine:dependency-mapper` — explicitly NOT a fork; a fork would inherit main context and re-introduce the leak). Sub-agent prompt template:

   ```
   You are a fresh sub-agent invoked from `mo-continue` Pre-flight Step 2A item 4 to inspect cross-feature codebase dependencies for the queue: <comma-separated features_in_queue>. Your context is isolated from the main session — main does not see your tool calls, only your final return summary.

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

   Receive the sub-agent return summary. Use the proposed order in step 5. The cache key fields (`scan-mode: code-aware`, `summary-md-hash`, `head-when-scanned`) will be written into `queue-rationale.md` by Step 2B when the overseer confirms the order — main is responsible for passing these to Step 2B's frontmatter init/update.
5. **Propose the prioritized order.** Print the order as a numbered list and the dependency reasoning underneath. End the message with:
   > "Reply `/mo-continue` to accept this order, or paste a different order (one feature per line) and then `/mo-continue` to confirm."
6. **Mid-cycle re-entry only — append a draft batch to `queue-rationale.md` (Item 7 of the v11 plan).** When this Step 2A run is the mid-cycle re-entry path (queue was empty + we just re-populated via `enqueue`), `queue-rationale.md` already exists from the prior cycle's batches and its top-level `status` is `confirmed`. Append a new `## Batch <N+1> — <today>` body with the proposed order in `### Order` (and `### Dependencies`/`### Notes` if applicable). Refresh top-level frontmatter atomically with the body write: `batch: N+1`, `status: draft`, `features: <previous confirmed cumulative + proposed order for new batch>`. This makes the next `/mo-continue` route to the draft-confirmation row in the dispatcher (Item 5) → Step 2B (extended) for confirmation.

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
7. **Stop.** Do NOT auto-fire Step 2B from here — the draft batch needs the overseer's explicit confirmation. The dispatcher routes the next `/mo-continue` to Step 2B (extended) automatically because top-level `status` is now `draft`.

   For the **initial cycle** (queue was already seeded by `/mo-run`, no prior batches exist): skip the file write here and let Step 2B's case (a) write the file from scratch when the overseer confirms. (This preserves the current behavior for fresh cycles.)

### Pre-flight Step 2B — Confirm order + auto-fire `/mo-apply-impact`

Reached when `[x] TODO` lines have been promoted (none remain) AND either (a) `queue-rationale.md` is missing OR (b) `queue-rationale.md` is present with `status: draft`. Item 5 of the v11 plan extends Step 2B to handle both cases — they share the prompt logic, the order-validation, the `progress.sh reorder` call, and the auto-fire of `/mo-apply-impact`. They diverge only at the file-write step (init vs. targeted edit).

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

1. **Resolve the confirmed order.** If the overseer typed a custom order in the previous turn, parse it. Otherwise, use the proposal from Step 2A (which the millwright still has in conversation context — if the session was compacted, re-derive it by re-grouping PENDING items + re-running dependency analysis). For the draft case (b), the proposal lives in the latest batch's `### Order` body and in top-level `features:` (the suffix corresponding to the draft batch).
2. **Validate the order.** It must be a permutation of the current `progress.md` queue. If the overseer's custom order is malformed (extras, missing entries, duplicates), surface the error and ask them to retype.
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
   - Refresh top-level `features:` to the cumulative ordered list across all batches (previous confirmed batches' features in order, plus the just-confirmed latest batch's features). Use `mo_fm_set` (via `frontmatter.sh set`) to preserve the rest of the frontmatter.
   - Set top-level `batch:` to the latest batch number (`qr_batch`).
   - Flip top-level `status:` from `draft` to `confirmed`.
   - **Cache fields:** if Step 2A's item 4 ran the code-aware sub-agent for the latest batch, refresh `scan-mode`, `summary-md-hash`, `head-when-scanned` per case (a) above. If the sub-agent didn't run (cache hit during step 4c, or journal-only path), leave the fields as they were on the prior batch's confirmation.
   - **Load-bearing invariant:** after Step 2B returns, `queue-rationale.md.features - progress.completed` must equal `progress.queue` in order, or Row A will not fire between features. Verify this before the auto-fire below.

4. **Reorder the queue.**
   ```bash
   $CLAUDE_PLUGIN_ROOT/scripts/progress.sh reorder <feature1> <feature2> ...
   ```
5. **Auto-fire `/mo-apply-impact`.** Same as the prior end-of-stage-1.5 transition.

---

## Approve Handler (current-stage = 2)

Runs after the overseer has reviewed the blueprint files (`requirements.md`, `config.md`, `diagrams/`) and is ready to advance into the planning chain.

### Approve Step 1 — Sanity-check blueprint files

Use `blueprints.sh check-current` (default mode — `primer.md` is not expected until stage 3) so partial stage-2 generations cannot slip through to `/mo-plan-implementation` with an incomplete blueprint:

```bash
if "$CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh" check-current "$active_feature"; then
  current_status=0
else
  current_status=$?
fi
case "$current_status" in
  0) ;;  # stage-2 blueprint is complete; proceed to /mo-plan-implementation
  1)
    echo "error: blueprints/current is empty for $active_feature; run /mo-apply-impact first" >&2
    exit 1
    ;;
  2)
    echo "error: blueprints/current is partial or invalid for $active_feature; repair it or re-run /mo-apply-impact before approving" >&2
    exit 1
    ;;
  *)
    echo "error: check-current returned unexpected status $current_status" >&2
    exit 1
    ;;
esac
```

The default mode is correct here: `primer.md` is written at stage 3 by `/mo-plan-implementation` Step 3.5, so it does not exist yet at the stage-2 approve gate. Stage-3+ callers (`/mo-update-blueprint`, the Stage-4 drift probe, `/mo-complete-workflow` before completion rotation) use `--require-primer` to also validate the primer.

### Approve Step 2 — Clear-point gate (`stage-2-to-3`)

Per `docs/clear-points/plan.md` §3.1 / §5.2, this step offers the overseer a `/clear` between stage-2 blueprint approval and stage-3 implementation entry. The gate fires at most once per feature: on first entry it prints the recommendation and halts; on re-entry (whether the overseer cleared or skipped) it proceeds.

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"

if "$CLAUDE_PLUGIN_ROOT/scripts/progress.sh" has-clear-recommendation stage-2-to-3; then
  gate_already_fired=1
else
  gate_already_fired=0
fi
```

#### Step 2a — `decisions.md` write-check (always runs)

Before the gate decides, ensure any verbal scope decisions from the recent stage-2 Q&A have been persisted to `decisions.md`. This is mandatory: if the overseer cleared on the strength of the recommendation (Step 2b), anything not in `decisions.md` is **lost** — the file is the only thing that survives the clear (per `docs/clear-points/plan.md` §4 prerequisites).

Review the last several turns of the conversation. If they contain instructions, scope decisions, or constraints that are NOT captured verbatim in `requirements.md` / `config.md` / `overseer-review.md`, summarize them as bullets in `$data_root/workflow-stream/$active_feature/decisions.md` under the `## Stage 2 — Blueprint approval` section.

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
  "2" "/mo-continue" "clear-offer-recommendation" "small" "main" \
  "stage-2-to-3 clear offered" || true
```

Then print the recommendation block to the overseer and **halt** — do NOT auto-fire `/mo-plan-implementation` in this branch:

> "Blueprint for `$active_feature` approved. **Recommended:** type `/clear`, then `/mo-continue` to enter stage 3 with a fresh main context.
>
> What gets carried across the clear:
> - `progress.md` (workflow state)
> - `blueprints/current/{requirements,config}.md` (the blueprint you just approved)
> - `decisions.md` (any verbal decisions captured above — folded into `primer.md` when stage 3 starts)
>
> What gets discarded by the clear: the back-and-forth conversation that led to this point. The blueprint is the canonical record; the chat history is not.
>
> Skip the clear (just type `/mo-continue` without clearing) if you have unsaved verbal context you specifically want to carry forward."

Then exit. The overseer's next `/mo-continue` re-enters this handler with `gate_already_fired=1`.

**If `gate_already_fired=1` (re-entry — offer was already shown; proceed):**

```bash
$CLAUDE_PLUGIN_ROOT/scripts/ledger.sh append \
  "2" "/mo-continue" "post-offer-resume" "small" "main" \
  "stage-2-to-3 Approve Handler resumed" || true

# Rehydration row — record the file set the dispatcher reads to remember
# workflow state post-clear. The handler does NOT itself read these here
# (mo-plan-implementation reads what it needs), but the ledger row attributes
# the read class to the gate transition for analytics.
$CLAUDE_PLUGIN_ROOT/scripts/ledger.sh append \
  "2" "/mo-continue" "progress.md, summary.md, requirements.md, config.md" \
  "medium" "main" "stage-2-to-3 rehydration" || true
```

Fall through to Step 3.

We **cannot** distinguish "took the clear" from "skipped the clear" — both produce the same persisted state (the `clear-recommendations` array contains `stage-2-to-3` either way). Per `docs/clear-points/plan.md` §6.5 and §5.4, this is fine functionally; telemetry honestly records `clear-offered` and `post-offer-resume` only, never a fake `clear-taken`.

### Approve Step 3 — Auto-fire `/mo-plan-implementation`

`/mo-plan-implementation` handles its own preconditions: branch validation against `config.md`'s `## GIT BRANCH`, todo promotion (PENDING → IMPLEMENTING), `base-commit` capture, primer composition (which folds in `decisions.md` per Step 3.5 — see `docs/clear-points/plan.md` §9.3), planning-mode prompt, and chain launch.

```bash
/mo-plan-implementation
```

If `mo-plan-implementation` errors (branch missing, branch mismatch, etc.), relay the error to the overseer; they fix the underlying issue and type `/mo-continue` again.

---

## Resume Handler (current-stage = 3)

Runs after the brainstorming chain has fully exited and returned control. Generates implementation diagrams (with pre-existing system framed as shaded context), optionally rotates the blueprint if requirements changed during brainstorming, and hands off to the overseer for review.

The handler is structured so re-runs after a session break are safe (Item 1 of the v11 progress-gap plan). All state writes are atomic, and a Step 0 drift-completion probe detects "drift was successfully completed in this cycle but the marker write was lost" without re-prompting the overseer.

### Resume Step 0 — Drift-completion probe (closes F1)

Skipped when `active.drift-check-completed` is already true (probe is gated to one-shot per cycle). Detects the case where `/mo-update-blueprint` rotated and regenerated successfully but the subsequent marker-set was lost to a session break — without this probe, the next `/mo-continue` would re-prompt the overseer for a drift decision they already answered.

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
      # invoke /mo-update-blueprint with: prefer the partial's reason.kind,
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
          /mo-update-blueprint --reason-kind="$recovered_kind" "${recovered_summary:-recovery}"
          if [[ "$recovered_kind" == "spec-update" ]]; then
            $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "drift-check-completed=true"
            echo "Step 0: lazy-baseline recovery succeeded for spec-update; drift marker set. Re-run /mo-continue to advance."
            exit 0
          else
            # Manual recovery: capture fresh baseline, let the normal drift prompt run later in this invocation.
            baseline_after_recovery="$(latest_finalized_v)"; baseline_after_recovery="${baseline_after_recovery:-0}"
            $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "history-baseline-version=$baseline_after_recovery"
          fi
          ;;
        completion)
          echo "error: a 'completion' partial blocks drift recovery — this state is owned by /mo-complete-workflow's Branch 0a, not /mo-update-blueprint. Invoke /mo-complete-workflow to resume the in-flight stage-8 rotation, or /mo-resume-workflow for diagnosis." >&2
          exit 1
          ;;
        re-spec-cascade|re-plan-cascade)
          echo "error: a '$recovered_kind' partial blocks drift recovery — these are review-loop auto-trigger rotations; their resume path is via /mo-review (re-launch the brainstorming review session) which lets the chain's next rotation attempt resume the partial. /mo-update-blueprint cannot recover this kind. No state was modified." >&2
          exit 1
          ;;
        *)
          echo "error: cannot determine a safe recovery kind for current/ in this state. Run /mo-resume-workflow for diagnosis." >&2
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
        # Drift rotation started but regeneration is partial. Route to /mo-update-blueprint recovery.
        # The recovery loop note: when check-current==2, /mo-update-blueprint will refuse without
        # --force-regen and the workflow will keep landing on this same diagnostic until the
        # overseer intervenes. This is intentional (auto-firing --force-regen would discard
        # partial overseer-visible content without consent — which is what F2 closes).
        v_summary="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$hist/v${drift_done_v}/reason.md" summary 2>/dev/null || echo 'recovery')"
        echo "Step 0: detected this-cycle spec-update at v${drift_done_v} but current/ is incomplete (check-current=$cc_status). Routing to /mo-update-blueprint recovery."
        echo "Note: if /mo-update-blueprint refuses (partial state without --force-regen), the workflow will not progress until you repair current/ manually OR re-run /mo-update-blueprint --force-regen <reason>. This is intentional — see F2/Item 10 in the v11 plan."
        /mo-update-blueprint --reason-kind=spec-update "$v_summary"
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

**If `commit_count == 0`:** the chain produced no commits since `base-commit`. Three legitimate causes — prompt the overseer:

> "Stage 4 — no commits since `base-commit` (`$base_commit`). The brainstorming chain (or direct implementation) hasn't produced code yet. Reply:
>
>   - `retry-launch` — re-launch `/mo-plan-implementation` (the chain may have exited prematurely or the direct-implementation session was interrupted before any commits landed). Stage stays at 3.
>   - `direct-empty` — confirm that **no code changes were needed** (e.g., a config-only feature whose blueprint was already correct, or a feature that turned out to already be implemented). I'll skip diagram generation + change-summary regeneration, write a tagged HTML comment into `overseer-review.md` documenting why, mark the cycle as drift-check-complete (no drift to detect — there's nothing to compare), and advance directly to stage 5 (overseer review). You can still write findings if you disagree with the no-changes conclusion.
>   - `abort` — invoke `/mo-abort-workflow` to clean up state."

```bash
if (( commit_count == 0 )); then
  case "$zero_commit_reply" in
    retry-launch)
      echo "Zero-commit branch: re-launching /mo-plan-implementation."
      /mo-plan-implementation
      exit 0  # mo-plan-implementation handles the rest; overseer types /mo-continue when ready
      ;;
    direct-empty)
      # Direct-empty side-effect contract (Item 3 of v11 plan).
      # 1. Skip /mo-draw-diagrams entirely (no commits, nothing to diagram).
      # 2. Skip implementation/change-summary.md regeneration.
      # 3. Create/validate the overseer-review.md skeleton idempotently.
      data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
      ov_file="$data_root/workflow-stream/$active_feature/implementation/overseer-review.md"
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
    f"     The overseer reported during stage 4 that no code changes were needed.\n"
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
      echo "Direct-empty cycle for '$active_feature' — advanced to stage 5. Review overseer-review.md (the HTML comment documents the reason); type /mo-continue when ready."
      exit 0
      ;;
    abort)
      /mo-abort-workflow
      exit 0
      ;;
    *)
      echo "error: zero-commit branch requires reply of 'retry-launch', 'direct-empty', or 'abort'." >&2
      exit 1
      ;;
  esac
fi
```

In the happy path, the mo-workflow does **not** track or read the spec / plan files the chain produced under `docs/superpowers/` — those are the chain's own artefacts and `base-commit..HEAD` is the canonical implementation contract. Step 2.5 below is the single exception: when commits exist *and* a plan file from this chain run is detected, the handler reads the plan/spec **read-only** to compose a resume primer if the overseer reports the chain was interrupted mid-run.

### Resume Step 2 — Mark sub-flow + idempotent flag writes

Atomic batched write — these flags are idempotent on retry:

```bash
# Prompt for execution-mode only when not yet persisted (a prior partial run
# may have already chosen). Otherwise reuse the persisted value.
mode_persisted="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get execution-mode 2>/dev/null || echo 'none')"
if [[ "$mode_persisted" == "none" ]]; then
  # Prompt the overseer (subagent-driven|inline). The exact prompt text lives
  # in Resume Step 3 below for narrative continuity.
  mode="$mode_from_overseer"  # placeholder; the LLM following this recipe asks the overseer.
else
  mode="$mode_persisted"
fi

$CLAUDE_PLUGIN_ROOT/scripts/progress.sh set \
  "implementation-completed=true" \
  "execution-mode=$mode" \
  "sub-flow=resuming"
```

### Resume Step 2.5 — Confirm chain completion (abandoned-chain recovery)

A session that was closed mid-chain looks identical to a clean exit at this point: both have commits in `base-commit..HEAD` and `sub-flow=chain-in-progress`. To distinguish, look for plan files written by *this* chain run and ask the overseer.

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

4. **Prompt the overseer.** Render the candidates as a numbered list with their checkbox counts and ask:

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
   >   - `completed` — advance to overseer review (3 → 4). Use this when the chain ran through `finishing-a-development-branch` and exited normally; remaining `- [ ]` checkboxes are stale (the chain doesn't always tick the very last step).
   >   - `abandoned <N>` — re-launch the brainstorming chain with plan #N (the number from the list above) as the resume target. I'll point the chain at the existing plan + spec + commit history so it picks up from the next un-done step. Stage stays at 3 until the chain finishes; you'll type `/mo-continue` again afterward and this same handler will route to `completed`.
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

   Then invoke the `brainstorming` Skill with this **resume primer** (substitute literals for the `<...>` placeholders, paste the actual `git log` output where indicated). Substitute `<$data_root>` with the resolved data root (e.g. `millwright-overseer` by default; whatever `$data_root` evaluates to in this command's shell context).

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

   If the plan is fundamentally incompatible with what's been committed (e.g., the previous session diverged and the plan is now stale), surface that to the overseer; they can run `/mo-abort-workflow` to start over. Otherwise: resume execution.

   Do NOT worry about the mo-workflow — when you finish, the overseer types `/mo-continue` to resume mo-workflow at stage 4.
   ```

   After invoking the Skill, **stop here**. Do NOT advance the stage. Do NOT mark `implementation-completed`. The stage stays at 3, sub-flow at `chain-in-progress`. The overseer drives the chain to completion (same isolation model as the original stage-3 launch); when it finishes, they type `/mo-continue` and this handler runs again, this time routing to `completed` (or back through Step 2.5 if the second run was also interrupted).

### Resume Step 3 — Drift prompt (skipped when probe set the marker)

(Skipped when `active.drift-check-completed` was set true by Step 0's probe.)

```bash
drift_marker_now="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get drift-check-completed 2>/dev/null || echo 'false')"
if [[ "$drift_marker_now" != "true" ]]; then
  # Existing overseer prompt and dispatch lives below in "Resume Step 4 — Blueprint drift check".
  drift_prompt_required=1
else
  echo "Resume Step 3: drift marker already true (set by Step 0 probe); skipping drift prompt."
  drift_prompt_required=0
fi
```

### Resume Step 4 — Blueprint drift check (overseer-driven)

(Skipped when `drift_prompt_required==0`, i.e., the Step 0 probe already set the marker for this cycle.)

Brainstorming may have surfaced new requirements, dropped some, or shifted scope mid-session. Without inspecting the chain's spec/plan files (mo-workflow doesn't read those), the overseer is the authority on whether `blueprints/current/requirements.md` still matches what was actually built.

When `drift_prompt_required==1`, prompt the overseer:

> "Stage-4 drift check: did anything in the requirements change during brainstorming? Reply:
>
>   - `<short reason>` — I'll run `/mo-update-blueprint --reason-kind=spec-update <reason>` to rotate `blueprints/current/` into history and regenerate `requirements.md` / `config.md` / `diagrams/` from the **implementation** (codebase + `base-commit..HEAD` diff) plus the just-rotated history version. The previous blueprint's `todo-item-ids`, `## Planned`, `## Non-goals`, `## GIT BRANCH`, and `## Overseer Additions` are preserved verbatim. The active quest cycle's `todo-list.md` and `summary.md` (under `quest/<slug>/`) and `journal/` are NOT consulted.
>   - `auto` — I'll analyze `blueprints/current/requirements.md` against the implementation (`base-commit..HEAD` diff + current code) to detect drift myself. If I find meaningful divergence (added requirements, dropped scope, shifted boundaries), I'll generate a one-line reason summary and run `/mo-update-blueprint --reason-kind=spec-update <auto-detected reason>`. If I don't find drift, I'll skip the rotation and mark drift-check complete.
>   - `continue` — proceed without updating the blueprint. Any drift will surface as findings during overseer review.
>
> Skipping is fine — the review loop catches drift via `re-spec` / `re-plan` findings if needed."

#### Auto-detect analysis (only when `drift_reply == "auto"`)

The LLM performs the analysis before the dispatch block runs and assigns the result to `$auto_reason`:

- **Inputs:** `blueprints/current/requirements.md` (the spec narrative — intent, scope, what was promised), `git diff base-commit..HEAD` (what was actually built), and any code files needed to disambiguate the diff.
- **What counts as drift:** divergence between the spec's intent and the implementation that won't be self-corrected by regeneration. Specifically — requirements added during brainstorming that the spec doesn't mention, scope dropped from the spec that wasn't built, or a meaningful shape/seam change (e.g., spec says "REST endpoint", implementation landed a WebSocket). A pure re-derivation that would produce the same Goals does NOT count — `/mo-update-blueprint` already re-derives Goals from the implementation, so cosmetic-only deltas are wasted rotation.
- **Output contract:**
  - Drift found → set `$auto_reason` to a one-line summary describing the divergence (this becomes the `summary` field of `history/v[N+1]/reason.md`).
  - No drift → set `$auto_reason` to the empty string. The dispatch will skip the rotation and only persist the marker.

```bash
if [[ "${drift_prompt_required:-0}" == "1" ]]; then
  # Wait for the overseer's reply, captured into $drift_reply by the LLM.
  # When $drift_reply == "auto", the LLM also performs the auto-detect analysis
  # described above and assigns the result to $auto_reason (non-empty if drift,
  # empty if no drift).
  if [[ "$drift_reply" == "auto" ]]; then
    if [[ -n "${auto_reason:-}" ]]; then
      # Auto-detect found drift — same side effect as the reason path.
      /mo-update-blueprint --reason-kind=spec-update "$auto_reason"
    fi
    # No-drift branch: fall through to the marker write below, no rotation.
  elif [[ "$drift_reply" != "continue" && -n "$drift_reply" ]]; then
    # Drift side effect: invoke /mo-update-blueprint with --reason-kind=spec-update.
    # The --reason-kind=spec-update tag is what makes the Step 0 probe detect this
    # cycle's drift on retry (it walks history versions K > history-baseline-version
    # for kind=spec-update).
    /mo-update-blueprint --reason-kind=spec-update "$drift_reply"
  fi
  # Split marker write — runs whether the overseer continued, supplied a reason,
  # or chose auto (drift or no-drift). Splitting it from the side effect closes F1
  # (a session break between /mo-update-blueprint's return and this line is
  # recovered by the Step 0 probe on the next /mo-continue).
  $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "drift-check-completed=true"
fi
```

### Resume Step 5 — Generate implementation diagrams

Run `/mo-draw-diagrams` (the user-facing wrapper around `mo-generate-implementation-diagrams`). The command renders the diagram set of `base-commit..HEAD` into `implementation/diagrams/`, framing pre-existing participants/classes/flows as shaded context next to the new functionality.

### Resume Step 6 — Create overseer-review skeleton

Initialize the overseer-review skeleton (idempotent — `review.sh init` refuses to overwrite, so skip the call if the file already exists). The stage advance is deferred to Step 7 so the whole resume sequence finalizes atomically.

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
ov_file="$data_root/workflow-stream/$active_feature/implementation/overseer-review.md"
[[ -f "$ov_file" ]] || $CLAUDE_PLUGIN_ROOT/scripts/review.sh init "$active_feature"
```

### Resume Step 7 — Final atomic advance-to (3 → 5, sub-flow=none)

The Resume Handler eliminates stage 4 as a persisted state. The atomic `advance-to 3 5 --set sub-flow=none` collapses the old "advance 3 then advance 4" pair into a single transition, so a session break inside the handler can never strand the workflow at stage 4 with sub-flow=resuming.

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh advance-to 3 5 --set sub-flow=none
```

Tell the overseer. The wording branches on `implementation-diagrams-skipped` so the review target is unambiguous:

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
>   - `y` — I'll generate `workflow-stream/<active_feature>/implementation/manual-test-plan.md` based on the blueprint + implementation diff + a codebase scan. After generation I'll offer to run it interactively. Failures can auto-seed as findings.
>   - `n` — skip manual testing; go directly to findings authoring (write into `implementation/overseer-review.md`, or leave empty to approve).
>
> Reply `y` or `n`."

**When `skipped=true` (overseer answered `n` to stage-4 diagram prompt):**

> "Stage 5 — ready for your review. Look at: commits `$base_commit..HEAD` and the **stage-2 blueprint diagrams** under `blueprints/current/diagrams` (implementation diagrams were skipped at stage 4 — the blueprint diagrams remain authoritative for this cycle).
>
> Before reviewing the implementation, would you like a manual test plan generated for this feature? (`y`/`n`)
>
>   - `y` — generate `manual-test-plan.md` and offer to run it. Failures can auto-seed as findings.
>   - `n` — skip manual testing; go directly to findings authoring (write into `implementation/overseer-review.md`, or leave empty to approve). To generate implementation diagrams now, run `/mo-draw-diagrams` first.
>
> Reply `y` or `n`."

**On the manual-test prompt's reply:**

- `y` → auto-fire `/mo-manual-test-plan --from-resume`. The flag suppresses the duplicate no-existing-plan y/n prompt at `/mo-manual-test-plan` step 2; if a plan already exists, that skill uses it unchanged instead of rotating it silently. Stop driving — the new skill takes over and converges back into the existing flow.
- `n` → set the manual-test phase as declined and continue to findings authoring:

  ```bash
  $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set manual-test-state=skipped manual-test-failure-policy=none
  ```

  Then print the existing stage-5 review message tail (`"Write your findings into implementation/overseer-review.md (or leave it empty to approve). Type /mo-continue when done."`).

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
| `plan_exists=1`, `results_exists=0`                                                | Plan was generated and `/mo-manual-test-run` was auto-fired, but the run crashed before step 1 created the results file. Print `"Resuming manual test — results file missing, will recreate from template."` Auto-fire `/mo-manual-test-run` (Branch A); step 1 of the run renders the results template from scratch and step 2 runs the env-up phase as if from fresh. |
| `plan_exists=0`, `results_exists=0`                                                | Inconsistent state — markers say a run is in progress but neither input file exists. Print: `"Inconsistent manual-test state: sub-flow=manual-testing but no plan or results file. Reset with progress.sh set sub-flow=none manual-test-state=none and start over via /mo-continue (which will re-prompt for plan generation), OR run /mo-resume-workflow for full diagnosis."` **Stop. Do NOT auto-mutate.** |
| `plan_exists=1`, `results_exists=1`, `results_state=in-progress`, `results_cursor` non-null | Paused mid-run. Print `"Resuming manual test at scenario $results_cursor. Re-confirm your local environment is up."` Auto-fire `/mo-manual-test-run` (Branch A).                                                                                                                |
| `plan_exists=1`, `results_exists=1`, `results_state=in-progress`, `results_cursor` null     | Results file rendered but loop never reached scenario 1. Same as above — auto-fire `/mo-manual-test-run` (Branch A) to start from scenario 1.                                                                                  |
| `plan_exists=1`, `results_exists=1`, `results_state=complete`                      | **Reachable, not defensive.** `/mo-manual-test-run` writes `state=complete` BEFORE the auto-seed loop and BEFORE clearing `sub-flow` (deliberately, so a crash mid-seed leaves `sub-flow=manual-testing` for re-entry). The handler must NOT clear sub-flow and fall through to the Overseer Handler — that would bypass the seed-recovery path. **Auto-fire `/mo-manual-test-run --seed-only`** (Branch B). Branch B's entry-guard table dispatches on `manual-test-failure-policy` and either re-prompts, re-runs the upsert loop, or finalizes. Branch B clears `sub-flow=none` as its last mutation; the next `/mo-continue` lands in the Overseer Handler. |

After auto-fire, stop driving — the run skill drives the overseer; another `/mo-continue` post-run lands in the Overseer Handler.

---

## Overseer Handler (current-stage = 5)

Runs after the overseer has reviewed the implementation and either filled `overseer-review.md` with findings or left it empty.

### Overseer Step 0 — Manual-test summary line (read-only)

If `workflow-stream/<active_feature>/implementation/manual-test-results.md` exists, surface a one-line summary in the entry log:

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

**The Overseer Handler must NOT mutate `overseer-review.md` because of manual-test results.** By the time this handler runs, `/mo-manual-test-run` has already either run the auto-seed loop (possibly leaving some failed scenarios unseeded if the overseer picked `skip` on per-IR prompts) or recorded `failure-policy=manual` and written nothing. Seeded failures are already-canonical `### IR-NNN` blocks. The handler must not auto-seed, reopen, reclassify, or rewrite seeded IR blocks based on `manual-test-results.md`.

The existing canonicalization pass at Step 1.5 below remains allowed to mutate `overseer-review.md` for **overseer-authored free-form review text** — that is a separate legacy behavior and not a manual-test write path. Idempotency for seeded blocks is enforced durably by the `- seed-id:` field on each auto-seeded IR-NNN block (`/mo-manual-test-run`'s single-owner discipline; see `docs/manual-testing/plan.md` § 2.2 "Auto-seed ownership recap").

### Overseer Step 1 — Verify overseer-review.md exists

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
ov_file="$data_root/workflow-stream/$active_feature/implementation/overseer-review.md"
[[ -f "$ov_file" ]] || {
  echo "overseer-review.md not found — did you mean to approve with no findings?" >&2
  read -p "Create empty overseer-review.md and approve? (y/n): " ans
  [[ "$ans" == "y" ]] || exit 1
  $CLAUDE_PLUGIN_ROOT/scripts/review.sh init "$active_feature"
}
```

### Overseer Step 1.5 — Canonicalize free-form findings

The overseer is encouraged to write findings as plain sentences — one per line or paragraph — under `## Implementation Review`. Before checking for open findings, normalize the file so every finding is in `### IR-NNN — ...` block format. Without this step, a free-form finding would slip past `list-open` (which only matches structured `### IR-NNN` headings with a `- status: open` line) and the workflow would silently auto-finalize as "approved with no findings."

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
   The original text becomes the block's `details:` body so the overseer's wording is preserved verbatim.
6. **Strip the original freeform span.** After all spans have been added, call `strip-freeform` for each one **in reverse line order** (highest line first) so earlier line numbers stay valid:
   ```bash
   $CLAUDE_PLUGIN_ROOT/scripts/review.sh strip-freeform "$active_feature" <line-start> <line-end>
   ```

When all spans are converted, tell the overseer:

> "I converted **N** free-form finding(s) into `### IR-NNN` blocks. Severity and scope are my classifications — open `overseer-review.md` to override before the review session begins. Continuing to review..."

Then fall through to Step 1.6.

### Overseer Step 1.6 — Persist review-mode-suggestion

After canonicalization completes (whether spans were found or the file was already canonical), compute the scope-distribution suggestion that stage 6 will use to default its review-mode prompt. The hint is computed here, at canonicalization time, because findings are already classified and the scope is stable; computing it again at stage 6 would re-derive the same fact.

Logic:

- If `review.sh list-open` returns nothing (zero open findings): `suggestion=none`.
- If every open finding has `scope: fix`: `suggestion=direct`.
- If at least one open finding has scope ≠ fix: `suggestion=brainstorming`.

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
ov_file="$data_root/workflow-stream/$active_feature/implementation/overseer-review.md"
open_count="$($CLAUDE_PLUGIN_ROOT/scripts/review.sh list-open "$active_feature" | wc -l | tr -d ' ')"
if [[ "$open_count" == "0" ]]; then
  suggestion="none"
else
  # Walk overseer-review.md; flag if any open finding has scope != fix.
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

The persisted hint is read at stage 6 by `commands/mo-review.md` Step 2.6 to default the `review-mode` prompt — `direct` defaults to direct mode with an explicit rationale; `brainstorming` and `none` keep the current default. The field is `none` until stage 5 sets it, and resets to `none` at the next feature's `progress.sh activate`.

Then fall through to Step 2.

### Overseer Step 2 — Check for open findings

```bash
open_ids="$($CLAUDE_PLUGIN_ROOT/scripts/review.sh list-open "$active_feature")"
```

### Overseer Step 3a — No findings

If `open_ids` is empty:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh advance-to 5 7 \
  --set sub-flow=none \
  --set overseer-review-completed=true
```

The single `advance-to 5 7 --set ...` collapses the no-findings approve path's stage advances and the `overseer-review-completed=true` write into one atomic transition (Item 4 of the v11 plan). A session break inside this block can never strand the workflow at stage 6 with sub-flow=none — either everything lands or nothing does.

Tell the overseer: "Approved — no findings. Auto-finalizing via `/mo-complete-workflow`."

Then auto-invoke `/mo-complete-workflow` immediately. Do not wait for a further overseer signal — the loop's clean exit is itself the trigger.

### Overseer Step 3b — Findings present

Hand the review off to a **brainstorming review session** by invoking `/mo-review`. The session runs **isolated from mo-workflow — same isolation model as stage 3**. After invoking `/mo-review`, control returns to the overseer, who drives the session through to its terminal state (typing `approve`).

```bash
# /mo-review handles sub-flow=reviewing, the stage 5→6 advance, and the Skill invocation,
# then hands off. It does NOT block on the Skill.
/mo-review
```

After `/mo-review` returns, **stop**. Do not advance the stage. Do not auto-fire `/mo-complete-workflow`. The Review-Resume Handler will run when the overseer types `/mo-continue` again after the brainstorming review session exits.

Tell the overseer: "Brainstorming review session is now live (isolated from mo-workflow). Drive it to completion (typing `approve` when ready), then type `/mo-continue` to resume the mo-workflow."

**Why no scope-tier dispatch here.** Earlier versions of mo-workflow encoded a scope-tier cascade (re-spec → re-plan → re-implement → fix) inside this handler. That logic moved into the brainstorming session itself: the chain reads each finding's `scope:` as a hint and chooses the smallest cascade that resolves the root cause. Mo-workflow no longer needs to know about scopes during the loop — only that brainstorming exited cleanly.

**No iteration cap.** Brainstorming controls its own loop; the overseer ends it by typing `approve`. If the overseer accumulates many findings and the loop runs long, it's their judgment call to interrupt with `/mo-abort-workflow`.

---

## Review-Resume Handler (current-stage = 6, sub-flow = reviewing)

Runs after the brainstorming review session has fully exited and returned control. Sanity-checks the findings status, advances 6 → 7, and auto-fires `/mo-complete-workflow`.

This handler exists because stage 6's brainstorming review session runs **isolated from mo-workflow** — same as the stage-3 chain. There is no programmatic signal that the session ended; the overseer's `/mo-continue` is the explicit resumption signal.

### Review-Resume Step 1 — Open-findings completion check

```bash
remaining_open="$($CLAUDE_PLUGIN_ROOT/scripts/review.sh list-open "$active_feature")"
```

If `remaining_open` is empty, fall through to Step 2 (advance and finalize).

If `remaining_open` is non-empty, the review session ended without resolving every finding — the same ambiguity as the stage-3 abandoned-chain case. The session may have exited cleanly with intentionally-deferred findings, or it may have been interrupted mid-loop. The three replies below are NOT auto-defaulted; the overseer must pick deliberately, because the choice has different downstream consequences. Prompt the overseer:

> "Review session ended with **N** open finding(s): `<id-list>`. Pick one — there is no default:
>
>   - `completed` — **You and the chain intentionally deferred these findings as non-blocking follow-up work.** The workflow advances 6 → 7 with the finding(s) still `open`. `mo-complete-workflow` archives `overseer-review.md` into `blueprints/history/v[N]/implementation/` at stage 8, so the deferred findings remain queryable in the historical record. Use this when you've decided the open findings are worth tracking but not worth blocking this cycle on. (If you want them *addressed* in this cycle instead of just archived, choose `abandoned` instead — `completed` does not re-launch the review loop.)
>   - `abandoned` — **The session was interrupted mid-loop, or the findings still need to be addressed.** Re-launches the brainstorming review session via `/mo-review`. Stage stays at 6 until the session exits cleanly; you'll type `/mo-continue` again afterward.
>   - `abort` — **Something went wrong — cancel the workflow.** Invokes `/mo-abort-workflow`.
>
> Reply with one of the three keywords."

- **On `completed`** — fall through to Step 2.
- **On `abandoned`** — invoke `/mo-review` (which reads the open findings, prompts for a review-mode, and re-launches the loop) and **stop**. Do NOT advance past stage 6. The next `/mo-continue` after the new session exits will re-enter this handler.
- **On `abort`** — invoke `/mo-abort-workflow` and stop.

### Review-Resume Step 2 — (deferred to Step 2.6 finalize)

`sub-flow=reviewing` stays in place until after the diagram-refresh prompt at Step 2.5 (Item 4 of the v11 plan). This makes the refresh prompt re-fireable on retry — if a session break happens between "overseer answered the prompt" and "rotation finalized," the next `/mo-continue` re-enters this handler and re-prompts (the overseer can answer the same way; the prompt is idempotent because no state changed yet).

### Review-Resume Step 2.5 — Offer diagram refresh (or recovery)

The review session may have committed new code. Before finalizing, offer the overseer a chance to update implementation diagrams. The prompt branches on the multi-state output of `commits.sh diagrams-fresh`:

```bash
freshness="$($CLAUDE_PLUGIN_ROOT/scripts/commits.sh diagrams-fresh "$active_feature" 2>/dev/null)"
freshness_exit=$?
```

Branch on `freshness`:

- **`fresh`** (exit 0) — diagrams are already current. Skip the prompt entirely; fall through to Step 2.6.
- **`stale`** (exit 0) — refresh prompt:

  > "The review session committed additional commits since the implementation diagrams were generated. Regenerate them?
  >
  >   - `y` — re-run `/mo-draw-diagrams` before finalizing (~30 seconds; useful so the final snapshot reflects the review-loop fixes before stage 8 archives the diagrams into `blueprints/history/v[N+1]/implementation/diagrams/`).
  >   - `n` — proceed directly to `/mo-complete-workflow`. The diagrams stay at the post-chain snapshot; they'll be archived as-is (not deleted) at stage 8.
  >
  > (y/n)"

- **`skipped`** (exit 0) — recovery prompt (stage 4 was skipped):

  > "Implementation diagrams were skipped at stage 4. The review session committed commits in `base-commit..HEAD` since then. Reply:
  >   - `y` — generate implementation diagrams now via `/mo-draw-diagrams` (~30s; covers the full `base-commit..HEAD` range and clears the skip marker so stage 8 archives them).
  >   - `n` — proceed without implementation diagrams. Stage-2 blueprint diagrams remain the only diagram artifact archived at stage 8.
  >
  > (y/n)"

- **`missing`** (exit non-zero) — diagnostic. Surface to the overseer and ask how to proceed:

  > "diagrams-fresh returned `missing` for `$active_feature` — the workflow expected either implementation diagrams to exist OR the skip marker to be set, but neither holds. Reply:
  >   - `y` — generate implementation diagrams now via `/mo-draw-diagrams` (treats this as a fresh stage-4 entry).
  >   - `n` — proceed without implementation diagrams.
  >   - `abort` — invoke `/mo-abort-workflow` for a clean recovery."

On `y` (any branch), invoke `/mo-draw-diagrams`. The wrapper's Step 1.5 routes correctly: for `skipped=true` it offers the recovery prompt (then clears the marker after success); for `skipped=false` it offers the regular stage-4 prompt or proceeds directly when `diagram-prompt=auto`. Either way, after `/mo-draw-diagrams` returns successfully, `implementation-diagrams-skipped` will be `false`. Continue to Step 2.6.

On `n`, continue to Step 2.6 unchanged.

On `abort` (only valid for the `missing` branch), invoke `/mo-abort-workflow` and stop.

### Review-Resume Step 2.6 — Atomic finalize (advance-to 6 → 7)

After the refresh prompt has been answered (or skipped), finalize the review-resume sequence in one atomic write. This collapses the old "set sub-flow=none + set overseer-review-completed=true + advance 6" trio into a single transition (Item 4 of the v11 plan), so a session break here cannot strand the workflow at stage 6 with sub-flow=none and the marker only half-set.

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh advance-to 6 7 \
  --set sub-flow=none \
  --set overseer-review-completed=true
```

### Review-Resume Step 3 — Auto-fire /mo-complete-workflow

Tell the overseer: "Overseer-review session approved. Auto-finalizing via `/mo-complete-workflow`."

Then auto-invoke `/mo-complete-workflow` immediately. Do not wait for a further overseer signal — the third `/mo-continue` is itself the trigger.

## Notes

- `/mo-continue` is a dispatcher — it reads state and acts. It never asks the overseer which stage we're at.
- For state outside the known stages (3, 5, or 6+reviewing), the dispatcher falls through to `/mo-resume-workflow` for diagnosis rather than erroring out.
- The mo-workflow does not read or modify the chain's spec/plan files under `docs/superpowers/` in the happy path. Re-entry into `brainstorming` / `writing-plans` / `executing-plans` for `re-spec` / `re-plan` cascades is via concern-bundle primers; the chain regenerates its own artefacts internally and produces fresh commits in `base-commit..HEAD`. **The single exception** is the abandoned-chain recovery branch in Resume Step 2.5, which reads the chain's plan and spec **read-only** to compose a resume primer when the overseer reports an interrupted run. No mo-workflow command writes to `docs/superpowers/`.
- Both the stage-3 chain and the stage-6 brainstorming review session run **isolated from mo-workflow**. Neither auto-detects skill completion — the explicit `/mo-continue` from the overseer is the resumption signal in both cases.
- If invariants are violated (e.g., `current-stage=4` but `implementation-completed=false`), stop and recommend `/mo-resume-workflow` for diagnosis.
