---
description: Orchestrate a full blueprint review on a markdown file: initial consistency loop → item enumeration → per-item batched parallel reviews → final consistency loop. Uses an external coding agent (Codex by default) as the reviewer via MCP. Edits the file in place; surfaces y/n prompts per max-iter event. See docs/blueprints-review/plan.md §4.3.
---

# /mi-blueprint-review

## Usage

```
/mi-blueprint-review <agent> <max-consistency-iter> <max-item-iter> <file-path> [--batch-size N] [--scope <heading>]
```

| Param | Meaning |
| --- | --- |
| `<agent>` | Reviewer agent name (e.g. `codex`). |
| `<max-consistency-iter>` | Max iterations for EACH consistency loop (initial and final). |
| `<max-item-iter>` | Max iterations PER item review. |
| `<file-path>` | Markdown file. Edits in place. |
| `--batch-size N` | Optional; defaults to 5. Maximum items reviewed in parallel per batch. Hard cap on total items: `MAX_ITEMS_PER_REVIEW=20`. |
| `--scope <heading>` | Optional. Restrict Phase 2 enumeration to items under the named `## <heading>` section only. Without this flag, the reviewer enumerates every reviewable item in the file. The stage-2 auto-fire (see `commands/mi-apply-impact.md` Step B.5) passes `--scope "Goals (this cycle)"` so Planned and Non-goals items aren't reviewed per-item. |
| `--reasoning-effort <low\|medium\|high>` | Optional. Reasoning effort passed to the reviewer MCP tool for every call (Phase 1, Phase 2, Phase 3, Phase 4). Defaults to `medium`. Use `low` for fast/cheap iteration; `high` is rarely worth it for spec review — Scenario-1 testing at `low` already produced high-quality findings, and `high` roughly doubles wall-clock and token cost (see `docs/blueprints-review/plan.md` §O4 / REPORT-4). |

## Preconditions

- Reviewer agent's MCP server reachable (`/mi-doctor`).
- File exists and is writable.

## Phase progression contract (READ BEFORE EXECUTING)

This orchestrator runs FIVE phases in order: Phase 1 (Step 2) → Phase 2 (Step 3) → Phase 3 (Step 4) → Phase 4 (Step 5) → Phase 5 (Step 6). Every phase is **mandatory**. The only allowed early exits are the explicit branches listed below — nothing else.

| Phase | Step | Allowed skip / early exit | NOT allowed |
| --- | --- | --- | --- |
| 1 — initial consistency | Step 2 | `blocked` from sub-agent → stop the whole orchestrator. | Skipping because Phase 1 returned `success` (Phase 1 success is the common case, not a reason to skip later phases). |
| 2 — item enumeration | Step 3 | `enumerate` exits 2 → abort orchestrator. Descriptor count > `MAX_ITEMS_PER_REVIEW` → print refusal and stop. | Skipping Step 3 outright. |
| 3 — per-item batched review | Step 4 | Descriptor count == 0 → skip Step 4 and jump to Step 5 (this is the **only** way to skip Step 4). | Skipping for cost, time, token budget, "the items look fine", or any other unilateral reason. Stopping after Phase 2 enumeration without spawning the item sub-agents. Pruning descriptors that the enumerator returned. |
| 4 — final consistency | Step 5 | `blocked` from sub-agent → stop. | Skipping because Phase 3 found nothing actionable, because Phase 1 was clean, or because count was 0 (Phase 4 still runs in the count==0 case — it's the catch-all for cross-section contradictions). |
| 5 — final report | Step 6 | (none) | Skipping. Every run ends with the Phase 5 report, even on early `blocked` exits, so the inspector knows what state the file is in. |

If you find yourself about to deviate from this contract for a reason not in the "Allowed skip" column — STOP. The right action is to run the phase. Cost, token usage, wall-clock time, and "the previous phase was clean" are **never** valid skip conditions. If the inspector wants a cheaper run, they re-invoke with smaller `<max-consistency-iter>` / `<max-item-iter>` / `--reasoning-effort low` / `--scope` — not by you silently dropping phases.

Announce each phase as you enter it (one short line: "Phase N — <name> — starting") so the inspector can see the progression and immediately notice if a phase was skipped.

## Execution

### Step 1 — Validate inputs and resolve constants

```bash
set -euo pipefail
agent="${1:-}"
max_c="${2:-}"
max_i="${3:-}"
file="${4:-}"
batch_size=5
scope=""  # empty = review all items; otherwise the ## heading text (e.g. "Goals (this cycle)")
reasoning_effort="medium"  # G3: medium is the right default; high is wasteful for spec review.
i=5
while [[ $i -le $# ]]; do
  arg="${!i}"
  case "$arg" in
    --batch-size=*)      batch_size="${arg#--batch-size=}" ;;
    --batch-size)        ((i++)); batch_size="${!i}" ;;
    --scope=*)           scope="${arg#--scope=}" ;;
    --scope)             ((i++)); scope="${!i}" ;;
    --reasoning-effort=*) reasoning_effort="${arg#--reasoning-effort=}" ;;
    --reasoning-effort)   ((i++)); reasoning_effort="${!i}" ;;
  esac
  ((i++))
done

[[ -n "$agent" && -n "$max_c" && -n "$max_i" && -n "$file" ]] || {
  echo "usage: /mi-blueprint-review <agent> <max-consistency-iter> <max-item-iter> <file> [--batch-size N] [--scope <heading>] [--reasoning-effort <low|medium|high>]" >&2
  exit 64
}
[[ "$reasoning_effort" =~ ^(low|medium|high)$ ]] || { echo "error: --reasoning-effort must be low, medium, or high" >&2; exit 64; }
[[ -f "$file" && -w "$file" ]] || { echo "error: file not found or not writable: $file" >&2; exit 1; }

reviewer_tool="$($CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh resolve-tool "$agent")" || exit 1
MAX_ITEMS_PER_REVIEW=20
```

### Step 1.5 — Resolve lessons_block via sibling-detection

Compute the lessons block string once, before any phase spawns a sub-agent.
The block is non-empty only when `<file>` sits inside a `blueprints/current/`
directory AND a sibling `../../implementation/blueprint-lessons.md` exists
AND its `selected-count > 0`. Otherwise the block is empty and the reviewer
prompts render exactly as they did before this feature.

```bash
lessons_block=""
file_dir="$(cd "$(dirname "$file")" && pwd)"
if [[ "$file_dir" == */blueprints/current ]]; then
  feature_dir="$(cd "$file_dir/../.." && pwd)"
  artifact="$feature_dir/implementation/blueprint-lessons.md"
  if [[ -f "$artifact" ]]; then
    selected_count="$("$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" get \
      "$artifact" selected-count 2>/dev/null || echo 0)"
    if [[ "$selected_count" =~ ^[1-9][0-9]*$ ]]; then
      lessons_body="$(awk '/^## Selected lessons$/{flag=1; next} flag' "$artifact")"
      lessons_block="$(cat <<EOF
## Lessons from prior PR reviews to honor

Use these as additional review criteria — flag any item in this blueprint that contradicts one of these lessons.

$lessons_body
EOF
)"
    fi
  fi
fi
```

`$lessons_block` is then passed verbatim into every Phase 1, Phase 3, and
Phase 4 sub-agent spawn prompt under the input name `lessons_block`. Each
sub-agent substitutes it into `{{LESSONS_BLOCK}}` per its `## Inputs` block.
When the value is empty, the substitution rule drops the placeholder line
entirely so the rendered prompt has no stray blank line.

### Step 2 — Phase 1: initial consistency loop **(MANDATORY)**

Announce: `Phase 1 — initial consistency — starting`.

Spawn the `blueprint-consistency-reviewer` sub-agent exactly as `/mi-blueprint-review-consistency` does. Parameters: `file`, `max_c`, `agent`, `reviewer_tool`, `reasoning_effort` (G3).

Parameters passed to the sub-agent: `file`, `max_c`, `agent`, `reviewer_tool`, `reasoning_effort` (G3), and `lessons_block` (from Step 1.5 — empty unless the file under review has a sibling blueprint-lessons.md with selected-count > 0).

- On `success`: continue to Step 3.
- On `partial` (max-iter): prompt `y/n`. On `y`: re-spawn the same sub-agent with the same parameters and the file's current state. On `n`: continue to Step 3 with the remaining findings inline.
- On `blocked`: surface and stop the whole orchestrator.

### Step 3 — Phase 2: item enumeration **(MANDATORY)**

Announce: `Phase 2 — item enumeration — starting`.

Render the enumeration prompt by substituting placeholders in `templates/blueprint-reviewer-prompt-enumerate.md.tmpl`. The two scope-related placeholders depend on whether `--scope` was given:

| `--scope` value | `{{SCOPE_INSTRUCTION}}` | `{{SCOPE_EMPTY_HINT}}` |
| --- | --- | --- |
| unset (review all) | `Enumerate every reviewable item in the file, regardless of section.` | (empty string) |
| set (e.g. `"Goals (this cycle)"`) | `Enumerate ONLY items that appear under the heading "## <scope>" — skip every other section of the file, including any other top-level headings. If the named heading doesn't exist, return an empty array.` | ` (or if the heading "## <scope>" doesn't exist)` |

```bash
file_content="$(cat "$file")"
if [[ -z "$scope" ]]; then
  scope_instruction="Enumerate every reviewable item in the file, regardless of section."
  scope_empty_hint=""
else
  scope_instruction="Enumerate ONLY items that appear under the heading \"## $scope\" — skip every other section of the file, including any other top-level headings. If the named heading doesn't exist, return an empty array."
  scope_empty_hint=" (or if the heading \"## $scope\" doesn't exist)"
fi
# Substitute placeholders. (Use a python heredoc since file_content can be large.)
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

If the count is 0 (free-form spec with no items), skip Step 4 entirely and proceed to Step 5. **This is the only condition under which Step 4 may be skipped** — see the Phase progression contract above.

### Step 4 — Phase 3: per-item batched review **(MANDATORY when descriptor count ≥ 1)**

Announce: `Phase 3 — per-item review — starting (N descriptors, batch size B)`.

You **MUST** spawn a `blueprint-item-reviewer` sub-agent for every descriptor returned by Step 3 (do not prune, do not sample, do not stop after Phase 2's enumeration "looks reasonable"). Cost, token usage, and wall-clock time are not valid reasons to skip — the Phase 1 consistency review and the Phase 3 per-item review catch different classes of bugs (Phase 1 = cross-item contradictions; Phase 3 = single-item ambiguities, missing acceptance criteria, under-specified constraints), so skipping Phase 3 silently degrades review coverage in a way the inspector cannot see. If the descriptor count is genuinely too large, the only correct action is the `MAX_ITEMS_PER_REVIEW` refusal in Step 3, not unilateral pruning here.

Parameters passed to each `blueprint-item-reviewer` sub-agent spawn: `file`, `descriptor`, `instance_id`, `max_i`, `agent`, `reviewer_tool`, `reasoning_effort` (G3), and `lessons_block` (from Step 1.5 — empty unless the file under review has a sibling blueprint-lessons.md with selected-count > 0).

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

### Step 5 — Phase 4: final consistency loop **(MANDATORY — runs even if Phase 3 was skipped)**

Announce: `Phase 4 — final consistency — starting`.

Identical to Step 2. Catches contradictions introduced by item-level rewrites in Step 4 (and, when Phase 3 was skipped because count==0, still catches any cross-section drift that Phase 1's `partial` exit may have left behind). **Do not skip** because Phase 1 was clean, because Phase 3 made no changes, or because the file "looks fine after Phase 3" — every successful orchestrator run ends Phase 4 either with `success` or with the inspector explicitly answering the max-iter prompt.

Parameters passed to the sub-agent: `file`, `max_c`, `agent`, `reviewer_tool`, `reasoning_effort` (G3), and `lessons_block` (from Step 1.5 — empty unless the file under review has a sibling blueprint-lessons.md with selected-count > 0).

- On `success`: continue to Step 6.
- On `partial` (max-iter): prompt `y/n` per Step 2. Continue to Step 6 either way.
- On `blocked`: surface and stop.

### Step 6 — Phase 5: final report **(MANDATORY)**

Announce: `Phase 5 — final report — starting`.

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
