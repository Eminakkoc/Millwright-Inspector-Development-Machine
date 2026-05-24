---
description: Orchestrate a token-reduced blueprint review (v1.5) — Phase A (preflight + summary build) → B (enumerate) → C (per-batch parallel review) → D (single consistency pass) → F (persist to review-history.md) → G (report). Uses mcp__codex__codex for round 1 and mcp__codex__codex-reply for rounds 2+. See docs/blueprint-review-token-reduction/plan.md.
---

# /mi-blueprint-review

## Usage

```
/mi-blueprint-review <agent> <file-path>
                     [--auto-iter N] [--batch-size N] [--scope <heading>]
                     [--reasoning-effort <low|medium|high>] [--concurrency N]
```

| Param | Default | Meaning |
| --- | --- | --- |
| `<agent>` | (required) | Reviewer agent name. Currently `codex`. |
| `<file-path>` | (required) | Markdown file. Edits in place. |
| `--auto-iter N` | 3 | Per-batch / per-consistency-pass round budget. `1` = find-only (no fix step). |
| `--batch-size N` | 3 | Items per batch in Phase C. |
| `--scope <heading>` | (none) | Restrict Phase B enumeration to items under `## <heading>` only. |
| `--reasoning-effort R` | medium | Round-1 codex effort (via `config.model_reasoning_effort`). Locked per session; rounds 2+ inherit it. |
| `--concurrency N` | 3 | Maximum Phase C batches dispatched in parallel codex sessions per wave. |

## Preconditions

- Reviewer's MCP server reachable (`/mi-doctor`).
- `mcp__codex__codex-reply` available (verified at Phase 0; see `docs/blueprint-review-token-reduction/phase-0-findings.md`). If unavailable, sub-agents fall back to stateless mode automatically.
- File exists and is writable.

## Phase progression contract (READ BEFORE EXECUTING)

Phases run in order: **A → B → C → D → F → G**. Every phase is mandatory. Allowed early exits:

| Phase | Allowed skip | NOT allowed |
| --- | --- | --- |
| A — preflight | (none) | Skipping at all. |
| B — enumeration | `enumerate` exits 2 → abort orchestrator. | Skipping. |
| C — per-batch review | Descriptor count == 0 → skip C, proceed to D. | Skipping for cost / time / "items look fine." |
| D — consistency | (none) | Skipping because C found nothing / count was 0. |
| F — persist | (none) | Skipping; even if no findings, `last-review-at` updates. |
| G — final report | (none) | Skipping. |

Announce each phase as you enter it (one short line: `Phase X — <name> — starting`).

## Execution

### Step 1 — Validate inputs and resolve constants

```bash
set -euo pipefail
agent="${1:-}"
file="${2:-}"
auto_iter=3
batch_size=3
scope=""
reasoning_effort="medium"
concurrency=3
i=3
while [[ $i -le $# ]]; do
  arg="${!i}"
  case "$arg" in
    --auto-iter=*)        auto_iter="${arg#--auto-iter=}" ;;
    --auto-iter)          ((i++)); auto_iter="${!i}" ;;
    --batch-size=*)       batch_size="${arg#--batch-size=}" ;;
    --batch-size)         ((i++)); batch_size="${!i}" ;;
    --scope=*)            scope="${arg#--scope=}" ;;
    --scope)              ((i++)); scope="${!i}" ;;
    --reasoning-effort=*) reasoning_effort="${arg#--reasoning-effort=}" ;;
    --reasoning-effort)   ((i++)); reasoning_effort="${!i}" ;;
    --concurrency=*)      concurrency="${arg#--concurrency=}" ;;
    --concurrency)        ((i++)); concurrency="${!i}" ;;
  esac
  ((i++))
done

[[ -n "$agent" && -n "$file" ]] || {
  echo "usage: /mi-blueprint-review <agent> <file> [--auto-iter N] [--batch-size N] [--scope X] [--reasoning-effort R] [--concurrency N]" >&2
  exit 64
}
[[ "$auto_iter" =~ ^[1-9][0-9]*$ ]]   || { echo "error: --auto-iter must be positive integer" >&2; exit 64; }
[[ "$batch_size" =~ ^[1-9][0-9]*$ ]]  || { echo "error: --batch-size must be positive integer" >&2; exit 64; }
[[ "$concurrency" =~ ^[1-9][0-9]*$ ]] || { echo "error: --concurrency must be positive integer" >&2; exit 64; }
[[ "$reasoning_effort" =~ ^(low|medium|high)$ ]] || { echo "error: --reasoning-effort must be low|medium|high" >&2; exit 64; }
[[ -f "$file" && -w "$file" ]] || { echo "error: file not found or not writable: $file" >&2; exit 1; }

reviewer_tool="$($CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh resolve-tool "$agent")" || exit 1
reviewer_reply_tool="mcp__${agent}__${agent}-reply"   # v1.5 convention; matches Phase 0 finding
MAX_ITEMS_PER_REVIEW=20
```

### Step 2 — Phase A: preflight + summary build **(MANDATORY)**

Announce: `Phase A — preflight — starting`.

**A.1 — Resolve `review-history.md` sibling.** If the file sits inside `*/blueprints/current/`, lazily init the sibling artifact:

```bash
file_dir="$(cd "$(dirname "$file")" && pwd)"
review_history=""
if [[ "$file_dir" == */blueprints/current ]]; then
  review_history="$file_dir/review-history.md"
  if [[ ! -f "$review_history" ]]; then
    feature="$(basename "$(cd "$file_dir/../.." && pwd)")"
    req_id="$("$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" get "$file" id 2>/dev/null || echo null)"
    "$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" init review-history "$review_history" \
      ID="$(uuidgen | tr 'A-Z' 'a-z')" \
      FEATURE="$feature" \
      REQUIREMENTS_ID="${req_id:-null}" \
      LAST_FINDING_ID=F-000 \
      FINDING_COUNT_TOTAL='!RAW!0' \
      FINDING_COUNT_UNRESOLVED='!RAW!0' \
      LAST_REVIEW_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
fi
```

If the file is not under `blueprints/current/`, `review_history` stays empty and Phase F is silently skipped at Step 6.

**A.2 — Resolve `lessons_block`.** Identical to v1.2.x sibling-detection (only fires when the file's grandparent contains `implementation/blueprint-lessons.md` with `selected-count > 0`). See `commands/mi-apply-impact.md` Pre-Step A for the producer side.

**A.3 — Build `file_metadata_brief`** in main (a small markdown block sent into every codex session opener):

```
- Feature: <feature slug>
- File: <basename of $file>
- Items in scope: <comma-separated ids from Phase B enumeration>
- Sections: <comma-separated top-level ## headings>
- Glossary: <comma-separated bolded-term sample, up to 10 unique>
```

The items + sections + glossary list is built deterministically after Phase B completes (since enumeration drives the items list). For Phase D's spawn, this block is finalized before Step 5.

**A.4 — Build `history_summary` for consistency scope** if `review_history` is non-empty:

```bash
history_summary_consistency=""
if [[ -n "$review_history" && -f "$review_history" ]]; then
  history_summary_consistency="$("$CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh" \
    build-summary "$review_history" consistency 2>/dev/null || echo "")"
fi
```

Per-batch summaries are built in Step 4 once each batch's scope IDs are known.

### Step 3 — Phase B: item enumeration **(MANDATORY)**

Announce: `Phase B — enumeration — starting`.

Render `templates/blueprint-reviewer-prompt-enumerate.md.tmpl` (unchanged from v1.2.x) — substitute `{{SCOPE_INSTRUCTION}}` and `{{SCOPE_EMPTY_HINT}}` according to whether `--scope` was passed (same logic as v1.2.x orchestrator).

Call `mcp__codex__codex` directly from main (one-shot; no sub-agent) with `sandbox="read-only"`, `approval-policy="never"`, `config={"model_reasoning_effort": "$reasoning_effort"}`. Discard the returned `threadId` — enumeration is single-call.

Parse the fenced ```json ... ``` array; pass to `scripts/blueprint-review.sh enumerate <file> <items.json>` for deterministic descriptor computation.

- If `enumerate` exits 2 → surface its `errors` array + abort.
- If descriptor count > `MAX_ITEMS_PER_REVIEW` → print refusal: `"File has N items, exceeds cap of 20. Split across cycles or use /mi-blueprint-review-item on a subset."` + stop.
- If count == 0 → skip Step 4; jump to Step 5.

### Step 4 — Phase C: per-batch review **(MANDATORY when descriptor count ≥ 1)**

Announce: `Phase C — per-item review — starting (N descriptors, batch size B, concurrency C)`.

You **MUST** spawn a `blueprint-batch-reviewer` sub-agent for every batch of `batch_size` descriptors. Cost / time / "items look fine" are not valid reasons to skip — Phase C catches single-item ambiguities the whole-file Phase D pass under-weights.

```python
# pseudocode for the orchestrator's batched-wave dispatcher
descriptors = sorted(descriptors, key=lambda d: d["start_offset"])
batches = [descriptors[i:i+batch_size] for i in range(0, len(descriptors), batch_size)]

for wave_start in range(0, len(batches), concurrency):
    wave = batches[wave_start : wave_start + concurrency]
    
    # Build per-batch summaries before dispatching the wave.
    spawn_inputs = []
    for b_idx, batch in enumerate(wave):
        scope_ids = [d["id"] for d in batch]
        history_summary_batch = ""
        if review_history:
            args = " ".join(f"--scope-id {sid}" for sid in scope_ids)
            history_summary_batch = sh(
                f'{plugin_root}/scripts/blueprint-review.sh build-summary {review_history} batch {args}'
            )
        spawn_inputs.append({
            "batch_id": f"B{wave_start + b_idx + 1}",
            "items": batch,                       # [{item_id, original_region}, ...]
            "max_iterations": auto_iter,
            "agent": agent,
            "reviewer_tool_name": reviewer_tool,
            "reviewer_reply_tool_name": reviewer_reply_tool,
            "reasoning_effort": reasoning_effort,
            "sub_agent_instance_id": f"T{wave_start + b_idx + 1}",
            "history_summary": history_summary_batch,
            "file_metadata_brief": file_metadata_brief,
            "lessons_block": "",                  # always empty for batch reviewer (spec §8.1.3)
        })
    
    # Dispatch ALL spawn_inputs in this wave as parallel Agent calls in ONE message.
    payloads = parallel_dispatch(spawn_inputs, sub_agent_type="...:blueprint-batch-reviewer")
    
    # Flatten + serialize write-back in main.
    flat = []
    for p in payloads:
        flat.extend(p["items"])
    flat.sort(key=lambda it: original_offset_of(it["item_id"]))
    
    for it in flat:
        # Rewrite tmp-ids T<instance>-<n> to final F-NNN before applying.
        next_id = sh(f"scripts/blueprint-review.sh alloc-final-id {file}").strip()
        rewritten = rewrite_tmp_ids(it["new_region"], starting_at=next_id)
        try:
            Edit(file_path=file, old_string=it["original_region"], new_string=rewritten)
        except ExactMatchFailure:
            # Re-enumerate this item from current file state; re-spawn as single-item batch.
            new_d = re_enumerate_single_item(file, it["item_id"])
            new_payload = spawn_single_item_batch(new_d, ...)
            Edit(file_path=file,
                 old_string=new_payload["items"][0]["original_region"],
                 new_string=new_payload["items"][0]["new_region"])
        validate_frontmatter_unchanged(file)
```

When all waves complete, proceed to Step 5.

### Step 5 — Phase D: consistency loop **(MANDATORY — runs even when descriptor count was 0)**

Announce: `Phase D — consistency — starting`.

Spawn one `blueprint-consistency-reviewer` sub-agent. Parameters:

```
file_path = $file
max_iterations = $auto_iter
agent = $agent
reviewer_tool_name = $reviewer_tool
reviewer_reply_tool_name = $reviewer_reply_tool
reasoning_effort = $reasoning_effort
lessons_block = (from A.2)
history_summary = history_summary_consistency (from A.4)
file_metadata_brief = (from A.3, updated after Phase B with item-ids in scope)
```

On `success` / `partial` / `blocked`: continue to Step 6 (Phase F) regardless. Phase F persists whatever findings the file ended up with. On `partial` with `reason: max-iter`: surface a y/n prompt: `"<H>H/<M>M consistency findings remain after <K> rounds — run another loop? (y/n)"`. On `y`: re-spawn the sub-agent with the file's current state. On `n`: continue.

### Step 6 — Phase F: persist to review-history.md **(MANDATORY when `review_history` is set)**

Announce: `Phase F — persist — starting`.

Collect every `<!-- REVIEW-FINDING -->` block currently in the file via `scripts/blueprint-review.sh parse-findings`. Compare against existing `## F-NNN` sections in `review-history.md` (parse with grep / awk):

| In file? | In history? | Action |
| --- | --- | --- |
| yes | no | emit `status: new` entry with full body (`severity`, `phase`, `target`, `finding`, `suggested_fix` — all snake_case to match the v1.5 reviewer template contract; `persist-findings` reads `suggested_fix`) |
| yes | yes | emit `status: still-present` entry (just timestamp bump; persist-findings is a no-op for these since status doesn't change, but the script still updates `last-review-at`) |
| no | yes (with `last-status: still-present` or `refined`) | emit `status: dropped` entry — the finding's `REVIEW-FINDING` block was removed from the spec body (fixer resolved it, OR inspector manually deleted it without a `resolved_by_change` note) |
| no | yes (with `last-status: resolved` or `dropped`) | no entry (no state change needed) |

Pipe the JSON array to `scripts/blueprint-review.sh persist-findings`:

```bash
echo "$findings_json" > "/tmp/mi-persist-input.$$.json"
"$CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh" persist-findings "$review_history" "/tmp/mi-persist-input.$$.json"
rm -f "/tmp/mi-persist-input.$$.json"
```

If `review_history` is empty (file not under `blueprints/current/`), skip Phase F silently — inline findings stay in the file with no history record.

### Step 7 — Phase G: final report **(MANDATORY)**

Announce: `Phase G — final report — starting`.

Inspect the file's final `<!-- REVIEW-FINDING -->` block count + severity breakdown (via `scripts/blueprint-review.sh parse-findings`). Print:

- `"No high/medium findings remain (Success)"` — if 0 H + 0 M remain inline.
- Otherwise: `"<H>H/<M>M remain inline in <file>; <N> findings recorded in <review_history>"` (omit the second clause if `review_history` is empty).

Cleanup: `rm -f /tmp/mi-*.$$.*`.

## Notes

- This command does NOT mutate `progress.md` or any quest file. It is workflow-neutral when invoked manually. Stage-2 auto-invocation is wired in `commands/mi-apply-impact.md` (see Step B.5).
- All file writes happen in main (Step 4 write-back loop, Step 5 sub-agent direct writes, Step 6 persist). Sub-agents read but never write the spec file (batch reviewer is structurally read-only; consistency reviewer is serial-safe).
- Session-expiry behavior: if `codex-reply` errors with `Session not found for thread_id`, the affected sub-agent re-issues that round as a fresh `mcp__codex__codex` call (full prompt cost for one round; subsequent rounds continue on the new session).

## See also

- `docs/blueprint-review-token-reduction/plan.md` — v1.5 design.
- `docs/blueprints-review/plan.md` — v1.2.x prior art (item enumeration, canonical region descriptor, `alloc-final-id` semantics unchanged).
- `commands/mi-blueprint-review-consistency.md`, `commands/mi-blueprint-review-item.md` — standalone variants.
