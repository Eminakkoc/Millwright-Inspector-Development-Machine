---
description: Run a single-item review (v1.4) — thin wrapper around Phase A + B(single-item) + C(batch=1) + F + G of /mi-blueprint-review. Mode A edits the file; Mode B is stateless (prints to terminal). See docs/blueprint-review-token-reduction/plan.md.
---

# /mi-blueprint-review-item

## Usage

```
/mi-blueprint-review-item <agent> <file-path>:<item-id> [--auto-iter N] [--reasoning-effort R]   # Mode A: file-anchored
/mi-blueprint-review-item <agent> <content>             [--auto-iter N] [--reasoning-effort R]   # Mode B: stateless
```

Also accepts the explicit form `--file <path> --item <id>` for paths containing colons.

Defaults: `--auto-iter 3`, `--reasoning-effort medium`.

## Preconditions

- Reviewer's MCP server reachable (`/mi-doctor`).
- (Mode A only) File exists and is writable.

## Execution

### Step 1 — Parse args + detect mode

```bash
set -euo pipefail
agent="${1:-}"
arg2="${2:-}"
auto_iter=3
reasoning_effort="medium"

[[ -n "$agent" && -n "$arg2" ]] || {
  echo "usage: /mi-blueprint-review-item <agent> <file>:<item-id> | <content> [--auto-iter N] [--reasoning-effort R]" >&2
  exit 64
}

reviewer_tool="$($CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh resolve-tool "$agent")" || exit 1
reviewer_reply_tool="mcp__${agent}__${agent}-reply"

# Mode detection (identical to v1.2.x):
mode=""
file=""
item_id=""
content=""

if [[ "$arg2" == "--file" ]]; then
  file="${3:-}"
  [[ "${4:-}" == "--item" ]] || { echo "usage: --file <path> --item <id>" >&2; exit 64; }
  item_id="${5:-}"
  mode="file"
elif [[ "$arg2" == *":"* ]]; then
  file_candidate="${arg2%:*}"
  if [[ -f "$file_candidate" ]]; then
    file="$file_candidate"
    item_id="${arg2##*:}"
    mode="file"
  fi
fi

if [[ -z "$mode" ]]; then
  # Mode B: everything from $2 onward is raw content (until flags).
  content="${*:2}"
  # Strip trailing flag chunks.
  mode="content"
fi

# Parse --auto-iter / --reasoning-effort flags (anywhere in argv).
for ((i=1; i<=$#; i++)); do
  arg="${!i}"
  case "$arg" in
    --auto-iter=*)        auto_iter="${arg#--auto-iter=}" ;;
    --auto-iter)          j=$((i+1)); auto_iter="${!j}" ;;
    --reasoning-effort=*) reasoning_effort="${arg#--reasoning-effort=}" ;;
    --reasoning-effort)   j=$((i+1)); reasoning_effort="${!j}" ;;
  esac
done

[[ "$auto_iter" =~ ^[1-9][0-9]*$ ]] || { echo "error: --auto-iter must be positive integer" >&2; exit 64; }
[[ "$reasoning_effort" =~ ^(low|medium|high)$ ]] || { echo "error: --reasoning-effort must be low|medium|high" >&2; exit 64; }
```

### Step 2 — Mode A: Phase A + Phase B(single) + Phase C(batch=1) + Phase F + Phase G

**Phase A:** same logic as `/mi-blueprint-review` Step 2 (lazily init `review-history.md` if under `blueprints/current/`; build `history_summary` filtered to `[item_id]` plus file; build `file_metadata_brief`).

**Phase B (single-item enumerate):** render `templates/blueprint-reviewer-prompt-enumerate.md.tmpl` with no scope (return all items). Call `mcp__codex__codex` (single-shot, discard threadId). Filter the returned JSON array to the entry matching `item_id`; abort with `"item <id> not found in file"` if absent. Run `scripts/blueprint-review.sh enumerate <file> <items.json>` to compute the canonical descriptor.

**Phase C (batch=1):** spawn `blueprint-batch-reviewer` with:

```
mode = file
batch_id = B1
items = [<single canonical descriptor>]
max_iterations = $auto_iter
agent = $agent
reviewer_tool_name = $reviewer_tool
reviewer_reply_tool_name = $reviewer_reply_tool
reasoning_effort = $reasoning_effort
sub_agent_instance_id = T1
history_summary = (from A — scoped to [item_id])
file_metadata_brief = (from A)
lessons_block = ""    (always empty per spec §8.1.3)
```

Apply the returned `new_region` to disk via `Edit(old_string=original_region, new_string=new_region)` — rewrite tmp-ids T1-<n> to final F-NNN via `scripts/blueprint-review.sh alloc-final-id` before applying. On exact-match failure: re-enumerate this item; re-spawn (same shape as orchestrator's Phase C exact-match-failure path).

**Phase F:** persist findings (only this one item's worth) per `/mi-blueprint-review` Step 6.

**Phase G:** print summary. On `partial; reason: max-iter`: surface y/n re-loop prompt.

### Step 3 — Mode B: synthesized Phase A + Phase C(batch=1, mode=content) + Phase G

No disk file → no `review-history.md` → no Phase F. `history_summary = ""`; `file_metadata_brief = ""`; `lessons_block = ""`.

Spawn `blueprint-batch-reviewer` with:

```
mode = content
batch_id = B1
items = [{item_id: "(unnamed)", original_region: <content>}]
max_iterations = $auto_iter
agent = $agent
reviewer_tool_name = $reviewer_tool
reviewer_reply_tool_name = $reviewer_reply_tool
reasoning_effort = $reasoning_effort
sub_agent_instance_id = T1
history_summary = ""
file_metadata_brief = ""
lessons_block = ""
```

Print the returned `new_region` to stdout (with any remaining `T1-<n>` REVIEW-FINDING blocks inline). No file write; no F-NNN rewrite (tmp-ids in Mode B output have no continuity with anything else).

## Notes

- All shared logic lives in the orchestrator (`commands/mi-blueprint-review.md`) and the batch reviewer sub-agent (`agents/blueprint-batch-reviewer.md`). This wrapper just builds a single-item batch and routes through Phases A / B / C / F / G.
- The `:item-id` separator is colon. Use `--file <path> --item <id>` for paths containing colons (rare on macOS, common on Windows).

## See also

- `commands/mi-blueprint-review.md` — full orchestrator (spawns batches in parallel waves).
- `docs/blueprint-review-token-reduction/plan.md` — design.
