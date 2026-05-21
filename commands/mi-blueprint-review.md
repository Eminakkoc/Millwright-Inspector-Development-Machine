---
description: Orchestrate a full blueprint review on a markdown file: initial consistency loop → item enumeration → per-item batched parallel reviews → final consistency loop. Uses an external coding agent (Codex by default) as the reviewer via MCP. Edits the file in place; surfaces y/n prompts per max-iter event. See docs/blueprints-review/plan.md §4.3.
---

# /mi-blueprint-review

## Usage

```
/mi-blueprint-review <agent> <max-consistency-iter> <max-item-iter> <file-path> [--batch-size N]
```

| Param | Meaning |
| --- | --- |
| `<agent>` | Reviewer agent name (e.g. `codex`). |
| `<max-consistency-iter>` | Max iterations for EACH consistency loop (initial and final). |
| `<max-item-iter>` | Max iterations PER item review. |
| `<file-path>` | Markdown file. Edits in place. |
| `--batch-size N` | Optional; defaults to 5. Maximum items reviewed in parallel per batch. Hard cap on total items: `MAX_ITEMS_PER_REVIEW=20`. |

## Preconditions

- Reviewer agent's MCP server reachable (`/mi-doctor`).
- File exists and is writable.

## Execution

### Step 1 — Validate inputs and resolve constants

```bash
set -euo pipefail
agent="${1:-}"
max_c="${2:-}"
max_i="${3:-}"
file="${4:-}"
batch_size=5
for arg in "${@:5}"; do
  case "$arg" in
    --batch-size=*) batch_size="${arg#--batch-size=}" ;;
    --batch-size) ;;  # next token, handled below
  esac
done
# Also handle the space-separated form
i=5
while [[ $i -le $# ]]; do
  [[ "${!i}" == "--batch-size" ]] && { ((i++)); batch_size="${!i}"; }
  ((i++))
done

[[ -n "$agent" && -n "$max_c" && -n "$max_i" && -n "$file" ]] || {
  echo "usage: /mi-blueprint-review <agent> <max-consistency-iter> <max-item-iter> <file> [--batch-size N]" >&2
  exit 64
}
[[ -f "$file" && -w "$file" ]] || { echo "error: file not found or not writable: $file" >&2; exit 1; }

reviewer_tool="$($CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh resolve-tool "$agent")" || exit 1
MAX_ITEMS_PER_REVIEW=20
```

### Step 2 — Phase 1: initial consistency loop

Spawn the `blueprint-consistency-reviewer` sub-agent exactly as `/mi-blueprint-review-consistency` does. Parameters: `file`, `max_c`, `agent`, `reviewer_tool`.

- On `success`: continue to Step 3.
- On `partial` (max-iter): prompt `y/n`. On `y`: re-spawn the same sub-agent with the same parameters and the file's current state. On `n`: continue to Step 3 with the remaining findings inline.
- On `blocked`: surface and stop the whole orchestrator.

### Step 3 — Phase 2: item enumeration

```bash
# Render the enumeration prompt.
enum_template="$CLAUDE_PLUGIN_ROOT/templates/blueprint-reviewer-prompt-enumerate.md.tmpl"
file_content="$(cat "$file")"
# Substitute placeholders. (Use a here-doc approach because file_content can be large.)
```

Send the rendered prompt to the reviewer MCP tool directly from main (no sub-agent — this is a small, one-shot call). Capture the response. Parse the fenced ` ```json ... ``` ` block into a JSON array of `[{id, anchor_line, occurrence_index}]`.

Save the array to a temp file `/tmp/mi-blueprint-review-items.<pid>.json` and run:

```bash
descriptors_json="$($CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh enumerate "$file" /tmp/mi-blueprint-review-items.<pid>.json)"
```

If `enumerate` exits 2, surface the `errors` array to the inspector and abort the orchestrator (the reviewer hallucinated items or miscounted occurrences).

If the resolved descriptor count exceeds `MAX_ITEMS_PER_REVIEW`, print:

> "File has N items, which exceeds the cap of 20. Split this file across multiple cycles, or run `/mi-blueprint-review-item` manually on a subset."

…and stop.

If the count is 0 (free-form spec with no items), skip Step 4 entirely and proceed to Step 5.

### Step 4 — Phase 3: per-item batched review

```python
# pseudocode for the orchestrator's batching loop
descriptors = sorted(descriptors, key=lambda d: d["start_offset"])
for batch_start in range(0, len(descriptors), batch_size):
    batch = descriptors[batch_start : batch_start + batch_size]

    # Spawn one blueprint-item-reviewer per item, in parallel, by emitting
    # multiple `Agent` tool calls in ONE message.
    returns = []
    for i, d in enumerate(batch):
        instance_id = f"T{i + 1}"  # T1..TN per batch (re-uses across batches; tmp-ids are file-scoped via instance namespace)
        spawn_prompt = render_spawn_prompt(d, instance_id, max_i, agent, reviewer_tool)
        returns.append(Agent(subagent_type="...:blueprint-item-reviewer", prompt=spawn_prompt))

    # Wait for all returns; then process in serialized order.
    payloads = [parse_payload_json(r) for r in returns]

    # Apply replacements sorted by ORIGINAL start_offset ascending.
    payloads_sorted = sorted(payloads, key=lambda p: original_offset_of(p["item_id"]))

    for p in payloads_sorted:
        # 1. Rewrite tmp-ids T<instance>-<n> to final F-NNN in p["new_region"].
        next_id = sh("scripts/blueprint-review.sh alloc-final-id", file).strip()
        rewritten = rewrite_tmp_ids(p["new_region"], starting_at=next_id)

        # 2. Apply via Edit with exact-match.
        try:
            Edit(file_path=file, old_string=p["original_region"], new_string=rewritten)
        except ExactMatchFailure:
            # Re-enumerate from current file state, re-spawn for this item only, retry.
            new_d = re_enumerate_single_item(file, p["item_id"])
            new_payload = spawn_item_sub_agent(new_d, ...)
            Edit(file_path=file, old_string=new_payload["original_region"], new_string=new_payload["new_region"])

        # 3. Re-validate frontmatter byte-equality. On mismatch, abort orchestrator.
        validate_frontmatter_unchanged(file)

    # Per-item max-iter prompts (one per Payload that returned Result: partial with max-iter).
    for p in payloads:
        if p["result"] == "partial" and has_max_iter(p):
            h, m = parse_max_iter_counts(p)
            answer = ask_inspector(f"Item `{p['item_id']}` review: {h} high / {m} medium findings remain after {max_i} iterations — run another loop? (y/n)")
            if answer == "y":
                # Re-enumerate this item (its offsets may have shifted from prior write-backs) and re-spawn.
                new_d = re_enumerate_single_item(file, p["item_id"])
                new_payload = spawn_item_sub_agent(new_d, ...)
                # Apply; if THIS one also returns partial+max-iter, prompt again (recurse).
```

When all batches complete, proceed to Step 5.

### Step 5 — Phase 4: final consistency loop

Identical to Step 2. Catches contradictions introduced by item-level rewrites in Step 4.

- On `success`: continue to Step 6.
- On `partial` (max-iter): prompt `y/n` per Step 2. Continue to Step 6 either way.
- On `blocked`: surface and stop.

### Step 6 — Phase 5: final report

Inspect the file's current `<!-- REVIEW-FINDING -->` blocks (via `scripts/blueprint-review.sh parse-findings`):

- If empty: `"No high/medium findings remain (Success)"`.
- Otherwise: print a summary — total count, per-severity breakdown, per-phase breakdown. The findings remain inline in the file for the inspector to review.

Clean up: `rm -f /tmp/mi-blueprint-review-items.<pid>.json`.

## Notes

- This command does NOT mutate `progress.md` or any quest file. It is workflow-neutral when invoked manually. Stage-2 auto-invocation is wired in `mi-apply-impact` (see Phase 5).
- The orchestrator never spawns more than `batch_size` item sub-agents at once.
- All file writes happen in this command (main), serialized — never in the item sub-agents.

## See also

- `docs/blueprints-review/plan.md` — design.
- `commands/mi-blueprint-review-consistency.md`, `commands/mi-blueprint-review-item.md` — the single-purpose variants.
