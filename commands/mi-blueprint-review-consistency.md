---
description: Run a whole-file consistency review loop using an external coding agent (Codex by default) as the reviewer. Findings are embedded inline in the reviewed file as `<!-- REVIEW-FINDING -->` HTML comments; resolved findings are cleaned up automatically. Works on any markdown file — no active mi-workflow required. See docs/blueprints-review/plan.md §4.1.
---

# /mi-blueprint-review-consistency

## Usage

```
/mi-blueprint-review-consistency <agent> <max-iterations> <file-path>
```

| Param | Meaning |
| --- | --- |
| `<agent>` | Reviewer agent name. Currently supported: `codex`. |
| `<max-iterations>` | Positive integer. Maximum reviewer calls in this loop. |
| `<file-path>` | Path to a markdown file. Edits in place. |

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
[[ -n "$agent" && -n "$max_iter" && -n "$file" ]] || {
  echo "usage: /mi-blueprint-review-consistency <agent> <max-iterations> <file-path>" >&2
  exit 64
}
[[ -f "$file" && -w "$file" ]] || { echo "error: file not found or not writable: $file" >&2; exit 1; }
[[ "$max_iter" =~ ^[0-9]+$ && "$max_iter" -ge 1 ]] || { echo "error: max-iterations must be a positive integer" >&2; exit 64; }

reviewer_tool="$($CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh resolve-tool "$agent")" || exit 1
```

### Step 2 — Spawn the consistency reviewer

Invoke the `Agent` tool with `subagent_type: millwright-inspector-development-machine:blueprint-consistency-reviewer`. Compose the spawn prompt from the template below (substitute literal values):

```
You are invoked by /mi-blueprint-review-consistency. Run ONE consistency review loop on the file below.

Inputs:
- file_path: <FILE>
- max_iterations: <MAX_ITER>
- agent: <AGENT>
- reviewer_tool_name: <REVIEWER_TOOL>

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
