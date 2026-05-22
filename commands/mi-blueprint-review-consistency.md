---
description: Run a whole-file consistency review loop using an external coding agent (Codex by default) as the reviewer. Findings are embedded inline in the reviewed file as `<!-- REVIEW-FINDING -->` HTML comments; resolved findings are cleaned up automatically. Works on any markdown file — no active mi-workflow required. See docs/blueprints-review/plan.md §4.1.
---

# /mi-blueprint-review-consistency

## Usage

```
/mi-blueprint-review-consistency <agent> <max-iterations> <file-path> [--reasoning-effort <low|medium|high>]
```

| Param | Meaning |
| --- | --- |
| `<agent>` | Reviewer agent name. Currently supported: `codex`. |
| `<max-iterations>` | Positive integer. Maximum reviewer calls in this loop. |
| `<file-path>` | Path to a markdown file. Edits in place. |
| `--reasoning-effort` | Optional. Defaults to `medium`. Reviewer reasoning effort. `low` is fast/cheap; `high` is rarely worth it for spec review. |

## Preconditions

- The file exists and is writable.
- `<agent>`'s MCP server is reachable (see `/mi-doctor`).

## Execution

### Step 1 — Validate inputs

```bash
set -euo pipefail
agent="${1:-}"
max_iter="${2:-}"
file="${3:-}"
reasoning_effort="medium"
i=4
while [[ $i -le $# ]]; do
  case "${!i}" in
    --reasoning-effort=*) reasoning_effort="${!i#--reasoning-effort=}" ;;
    --reasoning-effort)   ((i++)); reasoning_effort="${!i}" ;;
  esac
  ((i++))
done
[[ -n "$agent" && -n "$max_iter" && -n "$file" ]] || {
  echo "usage: /mi-blueprint-review-consistency <agent> <max-iterations> <file-path> [--reasoning-effort <low|medium|high>]" >&2
  exit 64
}
[[ -f "$file" && -w "$file" ]] || { echo "error: file not found or not writable: $file" >&2; exit 1; }
[[ "$max_iter" =~ ^[0-9]+$ && "$max_iter" -ge 1 ]] || { echo "error: max-iterations must be a positive integer" >&2; exit 64; }
[[ "$reasoning_effort" =~ ^(low|medium|high)$ ]] || { echo "error: --reasoning-effort must be low, medium, or high" >&2; exit 64; }

reviewer_tool="$($CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh resolve-tool "$agent")" || exit 1
```

### Step 1.5 — Resolve lessons_block via sibling-detection

Compute the lessons block string once before spawning the sub-agent. The
block is non-empty only when `<file>` sits inside a `blueprints/current/`
directory AND a sibling `../../implementation/blueprint-lessons.md` exists
AND its `selected-count > 0`. Otherwise the block is empty and the reviewer
prompt renders exactly as it did before this feature.

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

`$lessons_block` is then passed verbatim into the sub-agent spawn prompt
under the input name `lessons_block`. The sub-agent substitutes it into
`{{LESSONS_BLOCK}}` per its `## Inputs` block. When empty, the substitution
rule drops the placeholder line entirely so the rendered prompt has no
stray blank line.

### Step 2 — Spawn the consistency reviewer

Invoke the `Agent` tool with `subagent_type: millwright-inspector-development-machine:blueprint-consistency-reviewer`. Compose the spawn prompt from the template below (substitute literal values):

```
You are invoked by /mi-blueprint-review-consistency. Run ONE consistency review loop on the file below.

Inputs:
- file_path: <FILE>
- max_iterations: <MAX_ITER>
- agent: <AGENT>
- reviewer_tool_name: <REVIEWER_TOOL>
- reasoning_effort: <REASONING_EFFORT>     (one of low|medium|high; pass through to the reviewer MCP tool on every call)
- lessons_block: <LESSONS_BLOCK>     (from sibling-detection above; pass empty when no sibling artifact or selected-count=0)

Follow agents/blueprint-consistency-reviewer.md exactly. Return only the structured contract output.
```

### Step 3 — Receive return and surface to inspector

Parse the return's `Result:` field:

- `success` — print: `"No high/medium findings remain (Success)"`. Stop.
- `partial` with `max-iter:` risk line — extract the H / M counts from the risk line and prompt:
  > "<N> high / <M> medium findings remain after <max_iter> iterations — run another loop? (y/n)"

  On `y`: re-invoke the sub-agent with the same inputs (the file's current state will carry the unresolved findings forward; the next loop's iteration 1 reads them as prior findings per the prompt template). On `n`: stop, leaving findings inline.
- `blocked` — surface the raw `Findings / risks` to the inspector and stop.

## Notes

- This command does NOT mutate `progress.md` or any quest file. It is workflow-neutral.
- The file's YAML frontmatter is preserved byte-for-byte (the sub-agent revalidates after every iteration).
- The reviewer agent (Codex via MCP) has no file write access — findings are emitted as JSON and translated to inline HTML comments by the sub-agent.

## See also

- `docs/blueprints-review/plan.md` — design.
- `commands/mi-blueprint-review.md` — orchestrator that runs this + per-item review back-to-back.
