---
description: Run a single whole-file consistency review (v1.5) — thin wrapper around Phase A + D + F + G of /mi-blueprint-review. One codex session per loop; rounds 2+ via codex-reply. See docs/blueprint-review-token-reduction/plan.md.
---

# /mi-blueprint-review-consistency

**Runtime bootstrap.** Every `$CLAUDE_PLUGIN_ROOT` reference in this command's Bash blocks assumes a resolved plugin root; Claude Code does not inject the env var into Bash subshells. If it is empty in your shell, apply the canonical resolver (`docs/millwright-inspector-project.md` §8.14; reference implementation: `mi-continue.md` Step 1a) before the first Bash block: (1) inherited env var when it points at a working install, (2) `$PWD` when it is this plugin's source repo, (3) the `installPath` from `~/.claude/plugins/installed_plugins.json` — then export it, persist it to the per-cwd tempfile, and prepend the recovery one-liner to every subsequent Bash block. Refuse with an environmental diagnostic if none resolve.

## Usage

```
/mi-blueprint-review-consistency <agent> <file-path> [--auto-iter N] [--reasoning-effort R]
```

Defaults: `--auto-iter 5`, `--reasoning-effort medium`. No `--batch-size`, no `--scope`, no `--concurrency` — they don't apply to a consistency-only run.

## Preconditions

- Reviewer's MCP server reachable (`/mi-doctor`).
- File exists and is writable.

## Execution

### Step 1 — Validate inputs

```bash
set -euo pipefail
agent="${1:-}"
file="${2:-}"
auto_iter=5
reasoning_effort="medium"
i=3
while [[ $i -le $# ]]; do
  arg="${!i}"
  case "$arg" in
    --auto-iter=*)        auto_iter="${arg#--auto-iter=}" ;;
    --auto-iter)          ((i++)); auto_iter="${!i}" ;;
    --reasoning-effort=*) reasoning_effort="${arg#--reasoning-effort=}" ;;
    --reasoning-effort)   ((i++)); reasoning_effort="${!i}" ;;
  esac
  ((i++))
done
[[ -n "$agent" && -n "$file" ]] || { echo "usage: /mi-blueprint-review-consistency <agent> <file> [--auto-iter N] [--reasoning-effort R]" >&2; exit 64; }
[[ "$auto_iter" =~ ^[1-9][0-9]*$ ]] || { echo "error: --auto-iter must be positive integer" >&2; exit 64; }
[[ "$reasoning_effort" =~ ^(low|medium|high)$ ]] || { echo "error: --reasoning-effort must be low|medium|high" >&2; exit 64; }
[[ -f "$file" && -w "$file" ]] || { echo "error: file not found or not writable: $file" >&2; exit 1; }

reviewer_tool="$($CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh resolve-tool "$agent")" || exit 1
reviewer_reply_tool="mcp__${agent}__${agent}-reply"
# resolve-tool prints the unprefixed candidate. Apply /mi-blueprint-review
# Step 1's tool-name resolution: if the unprefixed pair is absent from the
# session's tool inventory but the plugin-prefixed pair exists
# (mcp__plugin_millwright-inspector-development-machine_codex__codex[-reply]),
# reassign both variables to the prefixed spellings; if neither exists, refuse.
```

### Step 2 — Run Phase A (preflight + summary build)

Same logic as `/mi-blueprint-review` Step 2 (A.1, A.2, A.3, A.4). Build `history_summary_consistency` and `file_metadata_brief`. Lazily init `review-history.md` if the file sits under `blueprints/current/`.

### Step 3 — Run Phase D (consistency loop)

Spawn `blueprint-consistency-reviewer` with the spawn-input bundle:

```
file_path = $file
max_iterations = $auto_iter
agent = $agent
reviewer_tool_name = $reviewer_tool
reviewer_reply_tool_name = $reviewer_reply_tool
reasoning_effort = $reasoning_effort
lessons_block = (from A.2)
history_summary = history_summary_consistency (from A.4)
file_metadata_brief = (from A.3)
```

On `success` / `partial` / `blocked`: continue to Step 4 regardless. On `partial` with `reason: max-iter`: surface `"<B>B/<C>C/<H>H/<M>M findings remain after <K> rounds — run another loop? (y/n)"` (drop the zero-count severities from the string). On `y`: re-spawn with the file's current state. On `n`: continue.

### Step 3.5 — Run Phase E (scope-expansion gate)

Same contract as `/mi-blueprint-review` Step 5.5, scoped to this file's consistency findings: collect the inline blocks with `scope-impact: expanding`, present them as one compact list, ask once (`none` / `all` / an id list / `keep <ids>`), apply only what the inspector approves, and mark the declined ones `deferred` for Step 4's persist. Skip only when there are none.

The gate belongs here as much as in the orchestrator — this wrapper drives the same consistency reviewer, whose fixer is under the same rule (apply `clarifying` only), so without Phase E its expanding findings would sit inline forever and be re-proposed on every later run.

### Step 4 — Run Phase F (persist)

Same logic as `/mi-blueprint-review` Step 6 (collect inline findings, classify against history sections, pipe to `persist-findings`). Skip silently if `review_history` is empty.

### Step 5 — Final report

- `"No findings remain (Success)"` — if inline count is 0.
- `"<B>B/<C>C/<H>H/<M>M findings remain inline in <file>; <N> recorded in <review_history>"` otherwise — drop the zero-count severities, and omit the second clause if `review_history` is empty.
- Any remaining `blocker` / `critical` gets its own line plus the escalation sentence from `/mi-blueprint-review` G.2.

## Notes

- Severity vocabulary is `blocker | critical | high | medium` (v1.6.8 — no `low`); see `/mi-blueprint-review` Notes.
- Findings also carry `scope-impact: clarifying | expanding` (v1.6.10). The fixer auto-applies only `clarifying`; `expanding` proposals go through the Step 3.5 inspector gate and are recorded `deferred` when declined, so later runs do not re-raise them.
- Thin wrapper. All shared logic lives in `commands/mi-blueprint-review.md` and the `blueprint-consistency-reviewer` sub-agent — this wrapper just skips Phases B and C.
- File frontmatter is preserved byte-for-byte (the sub-agent revalidates after each disk write).

## See also

- `commands/mi-blueprint-review.md` — full orchestrator (runs this + Phases B/C).
- `docs/blueprint-review-token-reduction/plan.md` — design.
