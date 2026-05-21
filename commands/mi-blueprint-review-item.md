---
description: Run a per-item review loop using an external coding agent (Codex by default) as the reviewer. Mode A (file-anchored) edits the file in place; mode B (stateless) prints results to terminal. The item sub-agent is strictly read-only — the command applies any region replacement in main. See docs/blueprints-review/plan.md §4.2.
---

# /mi-blueprint-review-item

## Usage

```
/mi-blueprint-review-item <agent> <max-iterations> <file-path>:<item-id>      # mode A: file-anchored
/mi-blueprint-review-item <agent> <max-iterations> <content>                  # mode B: stateless
```

To support file paths containing colons (rare on macOS, common on Windows), this command also accepts the alternative form:

```
/mi-blueprint-review-item <agent> <max-iterations> --file <path> --item <id>
```

## Execution

### Step 1 — Parse arguments and detect mode

```bash
set -euo pipefail
agent="${1:-}"
max_iter="${2:-}"
arg3="${3:-}"
[[ -n "$agent" && -n "$max_iter" && -n "$arg3" ]] || {
  echo "usage: /mi-blueprint-review-item <agent> <max-iterations> <file-path>:<item-id> | <content>" >&2
  exit 64
}
reviewer_tool="$($CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh resolve-tool "$agent")" || exit 1

# Detect mode A: arg3 contains ':' AND the prefix is a readable file.
mode=""
file=""
item_id=""
content=""

if [[ "$arg3" == "--file" ]]; then
  file="${4:-}"
  [[ "${5:-}" == "--item" ]] || { echo "usage: --file <path> --item <id>" >&2; exit 64; }
  item_id="${6:-}"
  mode="file"
elif [[ "$arg3" == *":"* ]]; then
  file_candidate="${arg3%:*}"
  if [[ -f "$file_candidate" ]]; then
    file="$file_candidate"
    item_id="${arg3##*:}"
    mode="file"
  fi
fi

if [[ -z "$mode" ]]; then
  # Treat the entire remainder of the command line as raw content (mode B).
  content="${*:3}"
  mode="content"
fi
```

### Step 2 — Mode A: enumerate the single item

If `mode=file`:

1. Read the file and render the enumeration prompt (`templates/blueprint-reviewer-prompt-enumerate.md.tmpl`).
2. Call the reviewer MCP tool — ask it to return `[{id, anchor_line, occurrence_index}]` for ALL items, since the parser is uniform.
3. Filter the returned list to the single item matching `item_id`. Refuse if not present.
4. Run `scripts/blueprint-review.sh enumerate <file> <items.json>` to compute the canonical descriptor for that one item. Capture `start_offset`, `end_offset`, `original_region`.

### Step 3 — Spawn the item sub-agent

Invoke the `Agent` tool with `subagent_type: millwright-inspector-development-machine:blueprint-item-reviewer`. Spawn prompt:

**Mode A:**

```
You are invoked by /mi-blueprint-review-item (mode A). Run ONE item review loop. Follow agents/blueprint-item-reviewer.md exactly.

Inputs:
- mode: file
- id: <ITEM_ID>
- original_region: |
    <THE ORIGINAL_REGION BYTES, INDENTED>
- max_iterations: <MAX_ITER>
- agent: <AGENT>
- reviewer_tool_name: <REVIEWER_TOOL>
- sub_agent_instance_id: T1

Return the Payload JSON block first, then the standard contract fields.
```

**Mode B:**

```
You are invoked by /mi-blueprint-review-item (mode B). Run ONE item review loop. Follow agents/blueprint-item-reviewer.md exactly.

Inputs:
- mode: content
- content: |
    <THE CONTENT, INDENTED>
- max_iterations: <MAX_ITER>
- agent: <AGENT>
- reviewer_tool_name: <REVIEWER_TOOL>
- sub_agent_instance_id: T1

Return the Payload JSON block first, then the standard contract fields.
```

### Step 4 — Receive the return; apply (mode A) or print (mode B)

Parse the sub-agent's return:
1. Extract the Payload JSON block (four-backtick outer fence; inside, ` ```json ... ``` `). Parse its JSON into `{item_id, original_region, new_region, remaining_findings}`.
2. Read the `Result:` field.

**Mode A:**

- On `success` or `partial`: rewrite each `tmp_id` inside `new_region` to a final `F-NNN` using `scripts/blueprint-review.sh alloc-final-id <file>` (incrementing for each tmp_id). Then apply the replacement to `<file>` via `Edit` with `old_string=original_region`, `new_string=<rewritten new_region>`.
- On exact-match failure: re-enumerate this item from the file's current state (Step 2) and re-spawn the sub-agent.
- On `blocked`: surface the `Findings / risks` and stop.
- After applying: verify frontmatter byte-equality between pre-write and post-write file states.

**Mode B:**

- Print `new_region` to stdout (plus any remaining tmp-id `REVIEW-FINDING` comments inline). No file write.

### Step 5 — Surface success / max-iter message

- `success` → print `"No high/medium findings remain (Success)"`.
- `partial` with `max-iter:` risk line → print `"<H> high / <M> medium findings remain after <K> iterations — run another loop? (y/n)"`. On `y`, restart the loop with the file's current state (mode A) or `new_region` as the new content (mode B). On `n`, stop.

## Notes

- The item sub-agent has no filesystem tools — all file mutation happens in this command (main), serialized by construction.
- Mode B is stateless: the command prints, nothing persists. Tmp-ids `T1-<n>` appear in the printed output as-is (no `F-NNN` rewrite in mode B — they have no continuity with anything else).

## See also

- `docs/blueprints-review/plan.md` — design.
- `commands/mi-blueprint-review.md` — orchestrator that spawns this in parallel batches.
