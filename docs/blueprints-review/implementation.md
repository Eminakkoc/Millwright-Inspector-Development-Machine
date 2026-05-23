# Blueprints Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build three new slash commands (`mi-blueprint-review-consistency`, `mi-blueprint-review-item`, `mi-blueprint-review`) plus two read-only reviewer sub-agents and one helper script, then wire the orchestrator into stage 2 of the mi-workflow.

**Architecture:** Reviewer-fixer loop where the millwright (Claude) is the fixer and an external coding agent (Codex via MCP) is the reviewer. Findings live inline in the reviewed file as `<!-- REVIEW-FINDING -->` HTML comments. Consistency review is serial (sub-agent writes the file directly); per-item review is read-only (sub-agent returns region replacements; orchestrator serializes write-back in main). Full design at [`docs/blueprints-review/plan.md`](./plan.md).

**Tech Stack:** Bash 5+, Python 3 (existing helpers), Claude Code Plugin API, Codex CLI (`codex mcp-server`), PostToolUse YAML schema hook.

**Testing note:** This codebase is structured around Markdown commands/agents with YAML frontmatter validated by `hooks/validate-on-write.sh` against `schemas/*.yaml`. There is no traditional unit-test runner. Verification commands at each step rely on the existing bundle/lint test scripts (`tests/bundle/run.sh`, `tests/lint/run.sh`) plus targeted smoke tests in a real workspace.

---

## Pre-implementation prerequisites

Before starting Phase 0, confirm:

- The current branch is suitable for the work (create a feature branch if not already on one).
- `codex` CLI is installed and on `$PATH`: `command -v codex` → exits 0.
- `plantuml-mcp-server` is reachable (existing dependency, sanity check): `command -v plantuml-mcp-server` → exits 0.

---

## Phase 0 — Settle Open Decision D2 (Codex MCP tool name)

The plan's §13 D2 leaves the exact Codex MCP tool name unresolved (`mcp__codex__codex` is the assumed default). Resolve this first because every sub-agent's `tools:` frontmatter must declare the exact tool name, and every command's prompt must reference it correctly.

### Task 0.1: Verify Codex CLI's MCP entrypoint

**Files:**
- (read-only verification — no files touched)

- [ ] **Step 1:** Run `codex mcp-server --help` and confirm the command exits 0 (this is the stdio MCP entrypoint per §7.1). Capture the help text for reference. If the subcommand is unknown, stop and report — the plan needs revision before any code is written.

- [ ] **Step 2:** Run `codex --version` and capture the version string.

- [ ] **Step 3:** Record both outputs in a scratch note (e.g., as a comment in `docs/blueprints-review/plan.md` §13 D2). No commit yet — Task 0.3 commits the resolved decision once we also know the tool name.

### Task 0.2: Declare the Codex MCP server and resolve the tool name

**Files:**
- Modify: `.claude-plugin/plugin.json`

- [ ] **Step 1:** Read `.claude-plugin/plugin.json` to confirm current contents (existing `plantuml` entry).

- [ ] **Step 2:** Add the `codex` server to `mcpServers` (do NOT bump version yet — version bump comes in Phase 6):

```json
"mcpServers": {
  "plantuml": {
    "command": "plantuml-mcp-server",
    "args": []
  },
  "codex": {
    "command": "codex",
    "args": ["mcp-server"]
  }
}
```

- [ ] **Step 3:** Reload the plugin in Claude Code (close + reopen the session, or run the project's reload command if one exists).

- [ ] **Step 4:** In the reloaded session, inspect the available MCP tools — look for any tool named `mcp__codex__*`. Record the exact tool name (likely `mcp__codex__codex`, but **verify**; if it's something else like `mcp__codex__exec` or `mcp__codex__run`, that's the canonical name to use everywhere downstream).

- [ ] **Step 5:** Validate the JSON syntactically:

```bash
python3 -m json.tool .claude-plugin/plugin.json > /dev/null && echo "json ok"
```

Expected: `json ok`.

### Task 0.3: Update D2 in the design plan with the resolved tool name

**Files:**
- Modify: `docs/blueprints-review/plan.md` (§13 D2 only)

- [ ] **Step 1:** Replace the "Resolved partially" wording in D2 with the resolved tool name and the `codex --version` captured in Task 0.1:

```markdown
| D2 | Exact Codex MCP tool name | Resolved: stdio entrypoint is `codex mcp-server` (Codex CLI `<version>`); the MCP server publishes the tool `mcp__codex__<NAME_FROM_TASK_0.2>`. This is the tool name listed in every sub-agent's `tools:` frontmatter (§6.1, §6.2). |
```

- [ ] **Step 2:** Commit the MCP server declaration and the D2 resolution together:

```bash
git add .claude-plugin/plugin.json docs/blueprints-review/plan.md
git commit -m "$(cat <<'EOF'
Declare codex MCP server and resolve D2

Adds codex (`codex mcp-server` stdio entrypoint) alongside the existing
plantuml MCP server so the upcoming blueprint-review sub-agents can call
the reviewer agent. Updates docs/blueprints-review/plan.md §13 D2 with
the resolved tool name observed after plugin reload.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 1 — Foundation (return-contract extension, helper script, doctor check)

### Task 1.1: Extend `docs/sub-agent-return-contract.md` with the Payload JSON pattern

**Files:**
- Modify: `docs/sub-agent-return-contract.md`

- [ ] **Step 1:** Read the current contract file to find the right insertion point (after the "Quick checklist for prompt authors" section, before "Related").

- [ ] **Step 2:** Append a new section. Use the Edit tool to insert before the existing `## Related` line:

```markdown
## Payload JSON extension

Some sub-agents need to hand back **structured machine-readable data** to the calling
command, not just file paths. The canonical contract above does not include a
"structured payload" channel — `Main should read` is a list of paths, not bytes —
so this extension defines a named, fenced block placed **BEFORE** the standard
fields. Calling commands that opt in know to parse it; calling commands that don't
opt in can safely ignore it (the standard fields still parse correctly).

Shape (outer fence uses four backticks so the inner `\`\`\`json` block is unambiguous):

````
Payload JSON:
```json
{ "key": "value", ... }
```

Result: success | partial | blocked
Artifacts changed:
...
````

Rules:

- The block starts with the literal line `Payload JSON:` followed by a
  triple-backtick `json`-tagged fenced code block carrying exactly one JSON
  object. Parsers MUST tolerate optional whitespace inside the fence; the
  fences and the `json` tag are mandatory.
- The block is **mandatory** on `Result: success` and `Result: partial`. It is
  allowed-but-not-required on `Result: blocked` (a blocked sub-agent may
  legitimately have no payload to return).
- The block appears exactly once per return; if a sub-agent emits multiple
  blocks, parsers use the first.
- All standard contract fields below the payload remain unchanged.

First adopter: `agents/blueprint-item-reviewer.md` (see
`docs/blueprints-review/plan.md` §6.2). Other sub-agents needing a structured
payload should follow this same shape.
```

- [ ] **Step 3:** Verify the markdown rendering: open the file and confirm the 4-backtick outer fence around the example works (the inner triple-backtick block should display as a code block inside the example, not break out).

### Task 1.2: Add an optional Payload JSON slot to `templates/sub-agent-return.md.tmpl`

**Files:**
- Modify: `templates/sub-agent-return.md.tmpl`

- [ ] **Step 1:** Read the template file to find the right insertion point (at the very top, before `Result:`).

- [ ] **Step 2:** Insert a commented stub above the existing template content:

```markdown
<!-- Optional: Payload JSON extension. Use only when the calling command needs a
     structured JSON payload from this sub-agent. See
     docs/sub-agent-return-contract.md § "Payload JSON extension".

Payload JSON:
```json
{ "...": "..." }
```

-->
```

- [ ] **Step 3:** Verify the existing template body below still renders correctly (the HTML comment must not bleed into the actual return shape that consumers read).

- [ ] **Step 4:** Commit Tasks 1.1 + 1.2 together (both touch the sub-agent return contract surface):

```bash
git add docs/sub-agent-return-contract.md templates/sub-agent-return.md.tmpl
git commit -m "$(cat <<'EOF'
Define Payload JSON extension for sub-agent returns

Adds an optional, named, fenced payload block (placed before the standard
contract fields) so sub-agents that need to hand back structured
machine-readable data have a documented channel. Adopted first by
agents/blueprint-item-reviewer.md (see docs/blueprints-review/plan.md §6.2).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 1.3: Create `scripts/blueprint-review.sh` with the `resolve-tool` subcommand

**Files:**
- Create: `scripts/blueprint-review.sh`

- [ ] **Step 1:** Write the initial skeleton with `resolve-tool` (the simplest, smallest unit — verifies the script bootstraps correctly):

```bash
#!/usr/bin/env bash
# blueprint-review.sh — helpers for /mi-blueprint-review and friends.
# See docs/blueprints-review/plan.md.
#
# Subcommands:
#   resolve-tool <agent>          # → MCP tool name for the agent argument
#   enumerate <file>              # (added in Task 1.4)
#   parse-findings <file>         # (added in Task 1.5)
#   reconcile <...>               # (added in Task 1.5)
#   alloc-final-id <file>         # (added in Task 1.5)

set -euo pipefail

usage() {
  sed -n '2,11p' "$0"
}

cmd="${1:-}"
[[ -n "$cmd" ]] || { usage >&2; exit 64; }
shift

case "$cmd" in
  resolve-tool)
    agent="${1:-}"
    [[ -n "$agent" ]] || { echo "usage: $0 resolve-tool <agent>" >&2; exit 64; }
    case "$agent" in
      codex)
        # MCP tool name verified in Phase 0 Task 0.2. Replace if Phase 0 found a
        # different name.
        echo "mcp__codex__codex"
        ;;
      *)
        echo "error: agent '$agent' is not supported. Supported: codex" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "error: unknown subcommand '$cmd'" >&2
    usage >&2
    exit 64
    ;;
esac
```

- [ ] **Step 2:** Make the script executable:

```bash
chmod +x scripts/blueprint-review.sh
```

- [ ] **Step 3:** Smoke test:

```bash
scripts/blueprint-review.sh resolve-tool codex
# expected: mcp__codex__codex   (or whatever Phase 0 resolved)

scripts/blueprint-review.sh resolve-tool gemini
# expected stderr: error: agent 'gemini' is not supported. Supported: codex
# expected exit: 1
```

If the tool name from Phase 0 was different from `mcp__codex__codex`, edit the `case codex)` arm in the script to emit the verified name before continuing.

- [ ] **Step 4:** Run the lint test to ensure the script passes shellcheck (if available) and the project's lint rules:

```bash
tests/lint/run.sh
```

Expected: exit 0.

### Task 1.4: Add the `enumerate` subcommand

**Files:**
- Modify: `scripts/blueprint-review.sh`

The `enumerate` subcommand takes a file and a JSON array of `[{id, anchor_line, occurrence_index}]` (on stdin or via `--items <path>`) and emits canonical region descriptors `[{id, start_offset, end_offset, original_region}]` deterministically. Per design plan §5.4.

- [ ] **Step 1:** Add the `enumerate` case to the `case` block. The implementation uses Python for the byte arithmetic (consistent with other plugin scripts):

```bash
  enumerate)
    file="${1:-}"
    items_path="${2:-}"
    [[ -n "$file" && -n "$items_path" ]] || { echo "usage: $0 enumerate <file> <items.json>" >&2; exit 64; }
    [[ -f "$file" ]] || { echo "error: file not found: $file" >&2; exit 1; }
    [[ -f "$items_path" ]] || { echo "error: items file not found: $items_path" >&2; exit 1; }

    python3 - "$file" "$items_path" <<'PYEOF'
import sys, json, re

file_path, items_path = sys.argv[1], sys.argv[2]
with open(file_path, "rb") as f:
    raw = f.read()

# Strip leading YAML frontmatter (--- ... ---) from the body so offsets are
# 0-indexed into the body, not the file.
m = re.match(rb'^---\n.*?\n---\n', raw, re.DOTALL)
body_start = m.end() if m else 0
body = raw[body_start:]

with open(items_path) as f:
    items = json.load(f)

# Pre-scan: for each unique anchor_line, list every byte offset where it occurs
# in the body (exact substring match).
occurrences = {}  # anchor_line -> [offset, offset, ...]
for it in items:
    anchor = it["anchor_line"].encode("utf-8")
    if anchor in occurrences:
        continue
    offs = []
    start = 0
    while True:
        idx = body.find(anchor, start)
        if idx < 0:
            break
        offs.append(idx)
        start = idx + 1
    occurrences[anchor] = offs

# Resolve each item to a byte offset by indexing into its anchor's occurrence list.
resolved = []
errors = []
for it in items:
    anchor = it["anchor_line"].encode("utf-8")
    idx = int(it.get("occurrence_index", 1)) - 1
    offs = occurrences.get(anchor, [])
    if idx < 0 or idx >= len(offs):
        errors.append(f"item {it['id']}: anchor_line not found at occurrence_index {it.get('occurrence_index', 1)} "
                      f"(only {len(offs)} occurrence(s) in file)")
        continue
    start_offset = offs[idx]
    resolved.append({"id": it["id"], "start_offset": start_offset, "anchor": anchor})

# Compute end offsets by walking forward to the next anchor / `^## ` heading / EOF.
resolved.sort(key=lambda r: r["start_offset"])
heading_re = re.compile(rb'(?m)^## ')

descriptors = []
for i, r in enumerate(resolved):
    start = r["start_offset"]
    # The next boundary: next anchor's start_offset, or next `^## ` after start, or EOF.
    next_anchor_offset = resolved[i + 1]["start_offset"] if i + 1 < len(resolved) else len(body)
    h = heading_re.search(body, start + len(r["anchor"]))
    next_heading_offset = h.start() if h else len(body)
    end_offset = min(next_anchor_offset, next_heading_offset)
    region = body[start:end_offset]
    # Sanity check: region must start with anchor.
    if not region.startswith(r["anchor"]):
        errors.append(f"item {r['id']}: computed region does not start with anchor_line — script bug or stale offset")
        continue
    descriptors.append({
        "id": r["id"],
        "start_offset": start_offset,
        "end_offset": end_offset,
        "original_region": region.decode("utf-8"),
    })

result = {"descriptors": descriptors, "errors": errors}
print(json.dumps(result, ensure_ascii=False, indent=2))
sys.exit(0 if not errors else 2)
PYEOF
    ;;
```

- [ ] **Step 2:** Smoke test with a fixture file. Create a temporary file `/tmp/blueprint-review-test.md` with frontmatter + a few items:

```bash
cat > /tmp/blueprint-review-test.md <<'EOF'
---
id: 00000000-0000-4000-8000-000000000000
---
# Requirements — test

## Goals (this cycle)

- **PAY-001** — add webhook capture under `services/`.
  Acceptance criteria: returns 400 on missing payload.
- **PAY-002** — extend CartService for bulk add.

## Non-goals

- Real-time analytics.
EOF
```

Then build the items array:

```bash
cat > /tmp/items.json <<'EOF'
[
  { "id": "PAY-001", "anchor_line": "- **PAY-001** — add webhook capture under `services/`.", "occurrence_index": 1 },
  { "id": "PAY-002", "anchor_line": "- **PAY-002** — extend CartService for bulk add.", "occurrence_index": 1 }
]
EOF

scripts/blueprint-review.sh enumerate /tmp/blueprint-review-test.md /tmp/items.json
```

Expected: a JSON object with two `descriptors` (PAY-001 spans the bullet + the indented Acceptance criteria line; PAY-002 spans just the single bullet up to the next `^## `). `errors` is empty.

- [ ] **Step 3:** Smoke test with a duplicate anchor (negative case):

```bash
cat > /tmp/items-dup.json <<'EOF'
[
  { "id": "PAY-002", "anchor_line": "- **PAY-002** — extend CartService for bulk add.", "occurrence_index": 2 }
]
EOF

scripts/blueprint-review.sh enumerate /tmp/blueprint-review-test.md /tmp/items-dup.json
```

Expected: exit code 2, errors array names the missing occurrence.

### Task 1.5: Add helper subcommands (`parse-findings`, `alloc-final-id`)

**Files:**
- Modify: `scripts/blueprint-review.sh`

These helpers are used by the consistency sub-agent (assigns final F-NNN ids itself) and by the orchestrator (rewrites tmp ids during write-back). They are small.

- [ ] **Step 1:** Add `parse-findings`: emit a JSON array of every `<!-- REVIEW-FINDING ... -->` block currently in a file:

```bash
  parse-findings)
    file="${1:-}"
    [[ -n "$file" && -f "$file" ]] || { echo "usage: $0 parse-findings <file>" >&2; exit 64; }
    python3 - "$file" <<'PYEOF'
import sys, re, json
with open(sys.argv[1]) as f:
    text = f.read()
# Each block: <!-- REVIEW-FINDING\n     id: F-001\n     severity: high\n     ... \n-->
pattern = re.compile(r'<!--\s*REVIEW-FINDING\s*(.*?)\s*-->', re.DOTALL)
out = []
for m in pattern.finditer(text):
    body = m.group(1)
    # Field-per-line; "key: value" or "key: |\n  multi-line".
    fields = {}
    for line in body.splitlines():
        if ':' in line:
            k, _, v = line.partition(':')
            fields[k.strip()] = v.strip()
    out.append(fields)
print(json.dumps(out, indent=2))
PYEOF
    ;;
```

- [ ] **Step 2:** Add `alloc-final-id`: emit the next F-NNN id given a file (scans for current max + 1):

```bash
  alloc-final-id)
    file="${1:-}"
    [[ -n "$file" && -f "$file" ]] || { echo "usage: $0 alloc-final-id <file>" >&2; exit 64; }
    python3 - "$file" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f:
    text = f.read()
ns = [int(m.group(1)) for m in re.finditer(r'\bid:\s*F-(\d+)\b', text)]
print(f"F-{(max(ns) + 1) if ns else 1:03d}")
PYEOF
    ;;
```

- [ ] **Step 3:** Smoke test both helpers against the file from Task 1.4. With no findings yet, `parse-findings` should output `[]`, and `alloc-final-id` should output `F-001`.

```bash
scripts/blueprint-review.sh parse-findings /tmp/blueprint-review-test.md
# expected: []

scripts/blueprint-review.sh alloc-final-id /tmp/blueprint-review-test.md
# expected: F-001
```

Add a synthetic finding and re-test:

```bash
printf '\n<!-- REVIEW-FINDING\n     id: F-007\n     severity: medium\n     finding: test\n-->\n' >> /tmp/blueprint-review-test.md

scripts/blueprint-review.sh parse-findings /tmp/blueprint-review-test.md
# expected: a JSON array with one entry, id "F-007"

scripts/blueprint-review.sh alloc-final-id /tmp/blueprint-review-test.md
# expected: F-008
```

- [ ] **Step 4:** Clean up the fixture: `rm /tmp/blueprint-review-test.md /tmp/items.json /tmp/items-dup.json`.

- [ ] **Step 5:** Commit Tasks 1.3–1.5 together (one new script, atomic addition):

```bash
git add scripts/blueprint-review.sh
git commit -m "$(cat <<'EOF'
Add scripts/blueprint-review.sh with resolve-tool, enumerate, parse-findings, alloc-final-id

Helpers consumed by the blueprint-review sub-agents and orchestrator:
- resolve-tool: maps agent argument to MCP tool name.
- enumerate: deterministic item-region computation from
  reviewer-supplied {id, anchor_line, occurrence_index} (no LLM byte
  arithmetic — see docs/blueprints-review/plan.md §5.4).
- parse-findings: extract <!-- REVIEW-FINDING ... --> blocks as JSON.
- alloc-final-id: emit the next monotonic F-NNN for a file.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 1.6: Add the `mcp:codex` check to `scripts/doctor.sh`

**Files:**
- Modify: `scripts/doctor.sh`

- [ ] **Step 1:** Read `scripts/doctor.sh` to find an existing similar `record` invocation (look for the `plantuml-mcp-server` block) to pattern off.

- [ ] **Step 2:** Add a `codex` block alongside `plantuml-mcp-server`. The check is two-step (CLI present + mcp-server entrypoint present):

```bash
# codex CLI + mcp-server subcommand (used by blueprint-review commands).
if command -v codex >/dev/null 2>&1; then
  codex_version="$(codex --version 2>/dev/null | head -1 || echo 'unknown')"
  if codex mcp-server --help >/dev/null 2>&1; then
    record "codex" cli false true "$codex_version" '{}'
  else
    # Binary exists but the mcp-server subcommand is missing — this CLI is too
    # old / wrong build.
    record "codex" cli false false "$codex_version (no mcp-server)" '{"darwin":"brew install codex","linux":"see https://github.com/openai/codex"}'
  fi
else
  record "codex" cli false false "" '{"darwin":"brew install codex","linux":"see https://github.com/openai/codex"}'
fi
```

`required: false` because the rest of the workflow still works without codex; missing codex just disables stage-2 auto-review (per design plan §10.2).

- [ ] **Step 3:** Smoke test:

```bash
scripts/doctor.sh --format=human | grep -i codex
# expected: a line showing codex with present/version, severity=ok if installed
```

- [ ] **Step 4:** Commit:

```bash
git add scripts/doctor.sh
git commit -m "$(cat <<'EOF'
doctor: add mcp:codex check

Reports codex CLI presence and version, and verifies the
`codex mcp-server` subcommand exists. Non-blocking — stage-2 blueprint
review degrades gracefully when codex is missing (see
docs/blueprints-review/plan.md §10.2).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2 — Consistency review path

This phase builds the simpler of the two paths (whole-file consistency, serial, writes file directly). Once it works, Phase 3 reuses the same scaffolding for per-item review.

### Task 2.1: Write the consistency reviewer prompt template

**Files:**
- Create: `templates/blueprint-reviewer-prompt-consistency.md.tmpl`

- [ ] **Step 1:** Create the file with the exact prompt body from design plan §11.1:

```markdown
You are a strict reviewer for a markdown specification file. Your job is to identify
issues that affect the file *as a whole*: contradictions between items, missing
references, inconsistent terminology, vague acceptance criteria, and items that
implicitly contradict each other.

You are NOT responsible for:
- Style / grammar nitpicks (unless they cause ambiguity).
- Per-item completeness — that is reviewed separately.
- Modifying the file. You only emit findings.

The file may already contain `<!-- REVIEW-FINDING ... -->` comments from prior
iterations. For each such comment:
- If the underlying issue is still present, INCLUDE an equivalent finding in your
  JSON output (you may refine the wording).
- If the issue has been resolved or no longer applies, OMIT a corresponding
  finding. The reconciler will drop the stale comment.

Severity:
- high   — file contradicts itself in a way that will cause implementation errors.
- medium — file is ambiguous or contains weak acceptance criteria.
- low    — file has minor issues that do not affect correctness (style, formatting).

Output ONLY a JSON array, fenced as ```json ... ```, with the following shape:

[
  {
    "severity": "high" | "medium" | "low",
    "phase": "consistency",
    "target": "file",
    "finding": "Description (multi-line ok).",
    "suggested-fix": "How to fix (multi-line ok)."
  }
]

If you find no issues, return an empty array: []

DO NOT modify the file. DO NOT touch the YAML frontmatter (between `---` lines at top).

Iteration: {{ITERATION}}
File path: {{FILE_PATH}}
File content:
---
{{FILE_CONTENT}}
---
```

- [ ] **Step 2:** Verify there are no smart-quote / non-ASCII issues that would confuse the reviewer (template should be plain text):

```bash
file templates/blueprint-reviewer-prompt-consistency.md.tmpl
# expected: ASCII text or UTF-8 text
```

### Task 2.2: Write the `blueprint-consistency-reviewer` sub-agent file

**Files:**
- Create: `agents/blueprint-consistency-reviewer.md`

- [ ] **Step 1:** Create the agent with the frontmatter declaring all tools it needs (per design plan §6.1). Replace `mcp__codex__codex` with whatever Phase 0 resolved:

```markdown
---
name: blueprint-consistency-reviewer
description: Runs one whole-file consistency review loop for /mi-blueprint-review-consistency and the orchestrator. Writes the reviewed file directly each iteration (safe because consistency review is always serial). Returns success on zero high/medium findings; returns partial with a max-iter risk line when the iteration cap is reached.
model: opus
effort: high
tools: [Read, Write, Edit, Bash, Grep, mcp__codex__codex]
---

You are a fresh sub-agent invoked by `mi-blueprint-review-consistency` (or by the orchestrator `/mi-blueprint-review` phase 1 / phase 4) to run **one** consistency review loop on a markdown file. Your context is isolated; main sees only your structured return.

You write the reviewed file directly each iteration. This is safe because consistency review is always serial — only one instance of you runs per file at a time. The parallel write-ownership concerns in `docs/blueprints-review/plan.md` §9 apply only to per-item review, not to you.

## Inputs (from the spawn prompt)

- `file_path` — absolute path to the markdown file to review.
- `max_iterations` — positive integer; maximum reviewer calls in this loop.
- `agent` — reviewer agent name (e.g. `codex`).
- `reviewer_tool_name` — the exact MCP tool you must call (e.g. `mcp__codex__codex`). It is listed in your `tools:` frontmatter; the spawn prompt tells you which one to use this run.

## Loop body (per iteration)

1. Read `file_path` (current state, including any prior `REVIEW-FINDING` comments).
2. Render the reviewer prompt by substituting placeholders in `templates/blueprint-reviewer-prompt-consistency.md.tmpl`:
   - `{{ITERATION}}` = the current iteration number (1-indexed).
   - `{{FILE_PATH}}` = `file_path`.
   - `{{FILE_CONTENT}}` = the file's contents.
3. Call the reviewer MCP tool (`reviewer_tool_name`) with the rendered prompt as input. Parse the JSON array in the response. On parse failure: log the raw response, retry once with a clarifying suffix asking for a valid JSON array; on second failure, return `Result: blocked` with the raw response captured in `Findings / risks`.
4. Reconcile new findings against the existing `REVIEW-FINDING` comments in the file:
   - For each existing comment: if the new findings include an equivalent one (same `target` + similar `finding` text), refresh the comment's `iteration` field. If the new findings do not, the issue is resolved or dropped — remove the stale comment.
   - For each new finding without a matching existing comment: scan the file for the current highest `F-NNN` (you can shell out to `scripts/blueprint-review.sh alloc-final-id <file_path>`) and append a fresh `REVIEW-FINDING` block with the **final** id `F-<next>`. Place the block at the top of the file body (after frontmatter, before the first `## ` heading). No tmp-id step is needed — consistency review is serial.
5. Write the updated file via `Write`. Validate that the YAML frontmatter (the `---`...`---` block at top) is byte-for-byte unchanged from your iteration's starting state. If frontmatter changed, revert and retry this iteration once; on second failure, return `Result: blocked`.
6. Check completion: if the reviewer's new findings contain zero `high` and zero `medium`, return `Result: success`.
7. Check max-iter: if `iteration >= max_iterations`, return `Result: partial` with a `max-iter:` risk line. Findings remain in the file.
8. Otherwise, **fix step**: apply edits to the file that address the new findings (and remove their `REVIEW-FINDING` comments). Re-validate frontmatter unchanged.
9. Increment iteration; loop.

## Required first reads

- `file_path` (canonical input).

## Required return shape — return ONLY this structure. Do not narrate intermediate steps.

```
Result: success | partial | blocked
Artifacts changed:
- <file_path>: <one-line note on iterations run + final finding counts>
Commits:
- (none — this sub-agent never commits)
Findings / risks:
- max-iter: <H> high / <M> medium remain inline    (only when Result=partial)
Main should read:
- <file_path>: (when Result=partial — main needs to surface the y/n prompt)
```

Total return ≤ 1k tokens. If your scope was too broad to summarize, return `Result: partial` and explain in `Findings / risks`; main will re-scope.
```

- [ ] **Step 2:** If Phase 0 resolved a Codex tool name different from `mcp__codex__codex`, update both the `tools:` array and the inline example accordingly. Use Grep to find any other occurrences in the file:

```bash
grep -n "mcp__codex__codex" agents/blueprint-consistency-reviewer.md
```

Update each match.

### Task 2.3: Write the `/mi-blueprint-review-consistency` command

**Files:**
- Create: `commands/mi-blueprint-review-consistency.md`

- [ ] **Step 1:** Create the command (per design plan §4.1):

```markdown
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
```

- [ ] **Step 2:** Smoke test the command on a real-ish file. Pick a small, low-risk markdown file (e.g., `README.md` or a copy of `requirements.md` from a finished cycle). **Do not** run this on `docs/blueprints-review/plan.md` itself — the file is mid-review and adding inline `REVIEW-FINDING` comments would be disruptive.

In the Claude Code session, type:

```
/mi-blueprint-review-consistency codex 2 /tmp/sample-spec.md
```

Where `/tmp/sample-spec.md` is a small spec-shaped fixture. Expected outcomes:
- Iteration 1 runs.
- Either zero findings → success on iter 2's verifying call, or some findings → fixer step → iter 2 verifies → success or max-iter prompt.
- The file's frontmatter (if any) is byte-identical before/after.

- [ ] **Step 3:** Commit Tasks 2.1–2.3 together (consistency path is a coherent unit):

```bash
git add templates/blueprint-reviewer-prompt-consistency.md.tmpl \
        agents/blueprint-consistency-reviewer.md \
        commands/mi-blueprint-review-consistency.md
git commit -m "$(cat <<'EOF'
Add /mi-blueprint-review-consistency command + sub-agent + prompt template

Whole-file consistency review loop using an external coding agent
(Codex via MCP) as the reviewer. Findings are embedded inline as
<!-- REVIEW-FINDING --> HTML comments; resolved findings are cleaned
up automatically. Sub-agent writes the file directly each iteration
(safe — consistency review is always serial; the parallel
write-ownership concerns in docs/blueprints-review/plan.md §9 apply
only to per-item review).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 2.4: End-to-end smoke test for the consistency path

**Files:**
- (none — verification only)

- [ ] **Step 1:** Construct a deliberately-inconsistent fixture file at `/tmp/sample-inconsistent.md`:

```markdown
---
id: 11111111-1111-4000-8000-111111111111
---
# Sample spec

## Goals

- **PAY-001** — return 400 on missing payload.
  Acceptance criteria: raise ValidationError on missing payload.
- **PAY-002** — accept bulk add requests.
```

Note the contradiction: PAY-001's bullet says "return 400" but its acceptance criteria says "raise ValidationError".

- [ ] **Step 2:** Run `/mi-blueprint-review-consistency codex 3 /tmp/sample-inconsistent.md`. Expected:
  - Iteration 1 emits a high-severity finding flagging the PAY-001 contradiction (as an inline `<!-- REVIEW-FINDING -->` comment).
  - Fixer step rewrites the bullet to be self-consistent.
  - Iteration 2 verifies: zero findings.
  - Command prints `"No high/medium findings remain (Success)"`.

- [ ] **Step 3:** Inspect the file after the run:
  - Frontmatter must be unchanged byte-for-byte.
  - PAY-001's bullet and acceptance criteria must now agree.
  - Zero `<!-- REVIEW-FINDING -->` comments remain.

- [ ] **Step 4:** Clean up: `rm /tmp/sample-inconsistent.md`. No commit needed for this verification task.

---

## Phase 3 — Per-item review path

Builds on Phase 2's scaffolding: same reviewer-fixer loop shape, but the sub-agent is **strictly read-only** on the reviewed file (no `Read`/`Write`/`Edit`/`Bash`/`Grep` tools — see design plan §6.2 H1 enforcement) and the calling command/orchestrator applies the region replacement in main.

### Task 3.1: Write the per-item reviewer prompt template

**Files:**
- Create: `templates/blueprint-reviewer-prompt-item.md.tmpl`

- [ ] **Step 1:** Create the file with the exact body from design plan §11.2:

```markdown
You are a strict reviewer for a single item in a markdown specification. Review the
item for: unclear language, missing acceptance criteria, missing seam reference,
internal contradictions, gaps in scope.

You are NOT responsible for:
- Style / grammar nitpicks.
- Cross-item consistency — that is reviewed separately.
- Modifying the item content. You only emit findings.

The item content may already contain `<!-- REVIEW-FINDING ... -->` comments from
prior iterations. Same reconciliation rule as the consistency prompt: re-flag if
still present, omit if resolved.

Severity: same scale as the consistency prompt.

Output ONLY a JSON array, fenced as ```json ... ```, with the following shape:

[
  {
    "severity": "high" | "medium" | "low",
    "phase": "item",
    "target": "{{ITEM_ID}}",
    "finding": "Description.",
    "suggested-fix": "How to fix."
  }
]

If no issues, return [].

Iteration: {{ITERATION}}
Item id: {{ITEM_ID}}
Item content:
---
{{ITEM_CONTENT}}
---
```

### Task 3.2: Write the item-enumeration prompt template

**Files:**
- Create: `templates/blueprint-reviewer-prompt-enumerate.md.tmpl`

- [ ] **Step 1:** Create the file with the body from design plan §11.3:

```markdown
You are a parser. Read the attached markdown file and identify every reviewable
item. An "item" is a distinct unit of specification — typically a bullet under a
top-level section like `## Goals`, `## Items`, `## Tasks`, etc. Items usually have
an id prefix in bold (e.g. **PAY-001**) but may not.

For each item, return:
- `id` — the item's explicit id (e.g. "PAY-001"); if none, assign `item-1`, `item-2`, … in document order.
- `anchor_line` — the **exact, verbatim, byte-for-byte** first line of the item as
  it appears in the file. Copy it; do not paraphrase, summarize, or normalize
  whitespace. A downstream script locates this line via exact substring match
  to compute byte offsets — any deviation will cause the item to be dropped.
- `occurrence_index` — a **1-based** integer indicating which occurrence of
  `anchor_line` this item is, counting from the start of the file body. The
  vast majority of items have a unique `anchor_line` and `occurrence_index = 1`.
  Only set it higher when the same anchor_line repeats in the file — e.g., two
  items that both start with `- Description:`. In that case the earlier one has
  `occurrence_index = 1`, the next `2`, and so on. **You must return items in
  document order** so the script can cross-validate the occurrence indices.

DO NOT return byte offsets, line numbers, or item content. The script computes
those deterministically from `anchor_line` + `occurrence_index`.

Return ONLY a JSON array, fenced as ```json ... ```:

[
  { "id": "PAY-001", "anchor_line": "- **PAY-001** — add a service under `services/` for webhook capture.", "occurrence_index": 1 },
  { "id": "PAY-002", "anchor_line": "- **PAY-002** — extend the existing CartService to accept bulk-add requests.", "occurrence_index": 1 },
  { "id": "GEN-001", "anchor_line": "- Description:", "occurrence_index": 1 },
  { "id": "GEN-002", "anchor_line": "- Description:", "occurrence_index": 2 }
]

Return an empty array if the file has no reviewable items.

File path: {{FILE_PATH}}
File content:
---
{{FILE_CONTENT}}
---
```

### Task 3.3: Write the `blueprint-item-reviewer` sub-agent

**Files:**
- Create: `agents/blueprint-item-reviewer.md`

- [ ] **Step 1:** Create the agent with the minimal-tools frontmatter (design plan §6.2 — only the MCP tool, no filesystem tools at all). Replace `mcp__codex__codex` with the Phase 0 resolved name:

```markdown
---
name: blueprint-item-reviewer
description: Runs one read-only per-item review loop for /mi-blueprint-review-item and the orchestrator's phase-3 batches. Operates entirely on the content passed via the spawn prompt — no filesystem access. Returns the final region replacement (or final content, in mode B) as a Payload JSON block before the standard sub-agent contract fields.
model: opus
effort: high
tools: [mcp__codex__codex]
---

You are a fresh sub-agent invoked by `/mi-blueprint-review-item` (or by `/mi-blueprint-review` phase 3) to run **one** review loop on a single item. Your context is isolated; main sees only your structured return.

You are **strictly read-only** on every file. Your `tools:` frontmatter lists only the reviewer MCP tool — no `Read`, `Write`, `Edit`, `Bash`, or `Grep`. You receive the item's content in the spawn prompt and operate on an in-memory working copy. The calling command applies the resulting region replacement in main, with exact-match validation against the original content you echo back in the payload.

## Inputs (from the spawn prompt)

Mode A (file-anchored, invoked by `/mi-blueprint-review-item` mode A or by the orchestrator):
- `mode`: `file`
- `id`: the item's id (e.g. `PAY-001`).
- `original_region`: the verbatim bytes of the item as the orchestrator/script enumerated it.
- `max_iterations`: positive integer.
- `agent`, `reviewer_tool_name`.
- `sub_agent_instance_id`: a small token like `T1`, `T2`, …, used as a temporary-id prefix.

Mode B (stateless, invoked by `/mi-blueprint-review-item` mode B):
- `mode`: `content`
- `content`: raw string passed by the inspector.
- `max_iterations`, `agent`, `reviewer_tool_name`, `sub_agent_instance_id` (same as mode A).

## Loop body (per iteration; operates on `working_copy`, initialized from `original_region` or `content`)

1. Render the per-item reviewer prompt by substituting placeholders in `templates/blueprint-reviewer-prompt-item.md.tmpl`:
   - `{{ITERATION}}` = current iteration (1-indexed).
   - `{{ITEM_ID}}` = `id` (mode A) or `(unnamed)` (mode B).
   - `{{ITEM_CONTENT}}` = `working_copy`.
2. Call the reviewer MCP tool (`reviewer_tool_name`) with the rendered prompt. Parse the JSON array. On parse failure: retry once with a clarifying suffix; on second failure, return `Result: blocked` with the raw response in `Findings / risks`.
3. Reconcile new findings against existing `<!-- REVIEW-FINDING -->` comments in `working_copy` (scan with simple in-prompt regex over the in-memory text):
   - Existing comment still matches a new finding → refresh `iteration`.
   - Existing comment NOT in new findings → drop it.
   - New finding without a match → append a new `REVIEW-FINDING` block with `id: <sub_agent_instance_id>-<n>` where `<n>` is the next per-instance counter starting at 1.
4. Completion check: if new findings have zero `high` and zero `medium`, return `Result: success`.
5. Max-iter check: if `iteration >= max_iterations`, return `Result: partial` with a `max-iter:` risk line.
6. Fix step: apply edits to `working_copy` that address the new findings, removing each resolved finding's `REVIEW-FINDING` comment.
7. Increment iteration; loop.

## What you do in-prompt (no helpers)

- **Existing-finding extraction:** match `<!-- REVIEW-FINDING ... -->` blocks in `working_copy` by pattern.
- **Tmp-id allocation:** monotonically increment within your own `sub_agent_instance_id` namespace; collisions are impossible across parallel sub-agents because each has a unique instance id.
- **Severity counting:** count severities in the reviewer's JSON response directly.
- **No frontmatter checks:** items don't carry frontmatter. The orchestrator validates frontmatter byte-equality after each `Edit` write-back in main.

## Required return shape

The Payload JSON block (see `docs/sub-agent-return-contract.md` § "Payload JSON extension") goes FIRST, then the standard contract fields. Outer fence uses four backticks; inner ``` ```json ``` ``` block is unambiguous.

````
Payload JSON:
```json
{
  "item_id": "<id, or null in mode B>",
  "original_region": "<the exact bytes you received, or null in mode B>",
  "new_region": "<the working_copy at loop exit>",
  "remaining_findings": [
    {
      "tmp_id": "<sub_agent_instance_id>-<n>",
      "severity": "high|medium|low",
      "phase": "item",
      "target": "<id-or-unnamed>",
      "finding": "...",
      "suggested-fix": "..."
    }
  ]
}
```

Result: success | partial | blocked
Artifacts changed:
- (none — read-only)
Commits:
- (none)
Findings / risks:
- item-id: <id-or-unnamed>
- original-region-bytes: <N>
- max-iter: <H> high / <M> medium remain inline    (only when Result=partial)
Main should read:
- (none — main reads the Payload JSON block above)
````

The Payload JSON block is **mandatory** on `Result: success` and `Result: partial`. On `Result: blocked` it is allowed but not required (if you couldn't produce a meaningful `new_region`, omit it and explain in `Findings / risks`).

Total return ≤ 1k tokens for the standard fields; the Payload JSON block itself is not counted against that budget (it can be the size of the item content).
```

- [ ] **Step 2:** Verify the `tools:` frontmatter contains **only** the MCP tool — no `Read`/`Write`/`Edit`/`Bash`/`Grep`:

```bash
grep -E "^tools:" agents/blueprint-item-reviewer.md
# expected: tools: [mcp__codex__codex]   (or whatever Phase 0 resolved)
```

If you see any other tool in the list, remove it. This is the structural read-only guarantee from design plan §12.

### Task 3.4: Write the `/mi-blueprint-review-item` command (both modes)

**Files:**
- Create: `commands/mi-blueprint-review-item.md`

- [ ] **Step 1:** Create the command (per design plan §4.2):

```markdown
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
1. Extract the Payload JSON block (four-backtick outer fence; inside, ``` ```json ... ``` ```). Parse its JSON into `{item_id, original_region, new_region, remaining_findings}`.
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
```

### Task 3.5: Smoke test the item-review path (both modes)

**Files:**
- (none — verification only)

- [ ] **Step 1:** Mode B smoke test — paste raw content to the command:

```
/mi-blueprint-review-item codex 3 "- **TEST-001** — vague item with no acceptance criteria."
```

Expected: at least one medium-severity finding from the reviewer (e.g., "missing acceptance criteria"). The fixer adds an Acceptance criteria line. Final output prints to terminal.

- [ ] **Step 2:** Mode A smoke test — use the same fixture from Task 2.4, scoped to one item:

```bash
cat > /tmp/sample-item.md <<'EOF'
---
id: 22222222-2222-4000-8000-222222222222
---
# Sample spec

## Goals

- **PAY-001** — return 400 on missing payload.
- **PAY-002** — accept bulk add requests.
EOF
```

Then:

```
/mi-blueprint-review-item codex 3 /tmp/sample-item.md:PAY-002
```

Expected: a finding flagging PAY-002's vagueness (no seam reference, no acceptance criteria); fixer rewrites the bullet; the file's frontmatter and PAY-001 are unchanged byte-for-byte.

- [ ] **Step 3:** Verify the file post-run:

```bash
diff <(head -3 /tmp/sample-item.md) <(head -3 /tmp/sample-item.md.before)  # frontmatter unchanged
```

Set up the `.before` snapshot before Step 2.

- [ ] **Step 4:** Clean up: `rm /tmp/sample-item.md /tmp/sample-item.md.before`.

- [ ] **Step 5:** Commit Tasks 3.1–3.4 together:

```bash
git add templates/blueprint-reviewer-prompt-item.md.tmpl \
        templates/blueprint-reviewer-prompt-enumerate.md.tmpl \
        agents/blueprint-item-reviewer.md \
        commands/mi-blueprint-review-item.md
git commit -m "$(cat <<'EOF'
Add /mi-blueprint-review-item command + sub-agent + prompt templates

Per-item review loop with two modes:
- Mode A (file-anchored): file:item-id argument; command extracts the
  region, runs a read-only sub-agent loop, applies the result in main
  via Edit exact-match.
- Mode B (stateless): raw content argument; sub-agent loops on the
  content and the command prints the result.

The blueprint-item-reviewer sub-agent has no filesystem tools at all
(tools: [mcp__codex__codex]) — read-only is structurally enforced, not
just by convention.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 4 — Orchestrator

### Task 4.1: Write the `/mi-blueprint-review` orchestrator command

**Files:**
- Create: `commands/mi-blueprint-review.md`

- [ ] **Step 1:** Create the command (per design plan §4.3). This is the largest command file in the feature:

```markdown
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

Spawn the `blueprint-consistency-reviewer` sub-agent exactly as `/mi-blueprint-review-consistency` does (Phase 2 Task 2.3 Step 2). Parameters: `file`, `max_c`, `agent`, `reviewer_tool`.

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

Send the rendered prompt to the reviewer MCP tool directly from main (no sub-agent — this is a small, one-shot call). Capture the response. Parse the fenced ```` ```json ... ``` ```` block into a JSON array of `[{id, anchor_line, occurrence_index}]`.

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
```

### Task 4.2: Smoke test the orchestrator

**Files:**
- (none — verification only)

- [ ] **Step 1:** Construct a multi-item fixture at `/tmp/sample-multi.md`:

```bash
cat > /tmp/sample-multi.md <<'EOF'
---
id: 33333333-3333-4000-8000-333333333333
---
# Multi-item spec

## Goals

- **PAY-001** — return 400 on missing payload.
  Acceptance criteria: raise ValidationError on missing payload.
- **PAY-002** — extend CartService.
- **PAY-003** — add audit logging.
  Acceptance criteria: writes one row per request.
- **PAY-004** — restrict admin endpoints.
- **PAY-005** — webhook retry.
- **PAY-006** — refund flow.
- **PAY-007** — accept bulk add.

## Non-goals

- Real-time analytics.
EOF
```

7 items → batches of (5, 2) at batch-size 5.

- [ ] **Step 2:** Run:

```
/mi-blueprint-review codex 3 2 /tmp/sample-multi.md
```

Expected:
- Phase 1: initial consistency review flags PAY-001's bullet-vs-acceptance contradiction → fixer rewrites → iter 2 verifies success.
- Phase 2: enumeration returns 7 items.
- Phase 3 batch 1: spawns 5 item sub-agents in parallel; collects returns; applies region replacements in serialized order; per-item y/n prompts only for items that hit max-iter.
- Phase 3 batch 2: spawns 2 item sub-agents; same flow.
- Phase 4: final consistency loop runs.
- Phase 5: prints final report.

Verify:
- The file's YAML frontmatter is byte-identical before/after the run.
- No two `REVIEW-FINDING` comments share an `F-NNN` id.
- Sections that didn't need changes (e.g., `## Non-goals`) are byte-identical.

- [ ] **Step 3:** Clean up the fixture: `rm /tmp/sample-multi.md`.

- [ ] **Step 4:** Commit Task 4.1 (the orchestrator command):

```bash
git add commands/mi-blueprint-review.md
git commit -m "$(cat <<'EOF'
Add /mi-blueprint-review orchestrator command

Runs a full blueprint review over a markdown file:
- Phase 1: initial whole-file consistency loop
- Phase 2: item enumeration (reviewer returns {id, anchor_line,
  occurrence_index}; script computes canonical descriptors)
- Phase 3: per-item batched parallel review (batch-size 5,
  MAX_ITEMS_PER_REVIEW=20)
- Phase 4: final consistency loop
- Phase 5: final report

Read-only sub-agent contract for item review + serialized write-back
in main (see docs/blueprints-review/plan.md §9). Per-max-iter y/n
prompts per design plan §4.3.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 5 — Stage-2 integration

### Task 5.1: Insert Steps B.5 and B.6 into `commands/mi-apply-impact.md`

**Files:**
- Modify: `commands/mi-apply-impact.md`

- [ ] **Step 1:** Read `commands/mi-apply-impact.md` to find Step B's end and Step C's beginning (the boundary where Steps B.5 + B.6 will be inserted).

- [ ] **Step 2:** Insert two new steps between Step B and the existing Step C. Use the Edit tool to add this content immediately before the line that begins Step C (typically `Pass $active_feature and $active_item_ids through to the shared steps` or wherever `Step C — diagrams` starts):

```markdown
### Step B.5 — Auto-invoke `/mi-blueprint-review` on the new `requirements.md`

This is a non-blocking quality gate: an external coding agent (Codex by default) reviews `requirements.md` for consistency and per-item completeness before the inspector sees the blueprint. Findings live inline in the file as `<!-- REVIEW-FINDING -->` comments; resolved ones are cleaned up automatically.

```bash
# Skip if codex MCP server is unavailable — graceful degradation per
# docs/blueprints-review/plan.md §10.2.
if "$CLAUDE_PLUGIN_ROOT/scripts/doctor.sh" --format=json | python3 -c '
import sys, json
status = json.load(sys.stdin)
checks = status.get("checks", [])
for r in checks:
    if r.get("name") == "codex" and r.get("present"):
        sys.exit(0)
sys.exit(1)
'; then
  requirements_path="$data_root/workflow-stream/$active_feature/blueprints/current/requirements.md"
  # Invoke the orchestrator (defaults: codex, 3 consistency iters, 5 item iters).
  /mi-blueprint-review codex 3 5 "$requirements_path"
else
  echo "warning: codex MCP unavailable — skipping stage-2 blueprint review" >&2
fi
```

### Step B.6 — Surface drift in `summary.md` and `todo-list.md`

If the review rewrote `requirements.md`, surface any drift in the cycle's `summary.md` and `todo-list.md` as a heads-up to the inspector. The millwright does NOT auto-edit either file — `summary.md` is millwright-territory but auto-editing without consent feels surprising, and `todo-list.md` is strictly inspector-territory.

```bash
quest_dir="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh dir)"
summary_path="$quest_dir/summary.md"
todo_path="$quest_dir/todo-list.md"
requirements_path="$data_root/workflow-stream/$active_feature/blueprints/current/requirements.md"

# Compare semantic Goals/Planned/Non-goals content in requirements.md against the
# active feature's section in summary.md and the PENDING items in todo-list.md.
# Heuristic: extract item IDs and one-line summaries from each; emit a heads-up if
# wording diverges by more than minor whitespace.
drift_report="$($CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh diff-drift \
  "$requirements_path" "$summary_path" "$todo_path" "$active_feature" 2>/dev/null || true)"

if [[ -n "$drift_report" ]]; then
  echo
  echo "The blueprint review rewrote requirements.md. Possible drift in adjacent files:"
  echo "$drift_report"
  echo
  echo "Optional: edit summary.md and todo-list.md to match before typing /mi-continue. Or proceed — neither file blocks stage 3."
fi
```

Note: `scripts/blueprint-review.sh diff-drift` is a small helper added for this step — see Task 5.1 Step 3 below.
```

- [ ] **Step 3:** Add the `diff-drift` subcommand to `scripts/blueprint-review.sh`:

```bash
  diff-drift)
    requirements="${1:-}"
    summary="${2:-}"
    todo="${3:-}"
    feature="${4:-}"
    [[ -n "$requirements" && -n "$summary" && -n "$todo" && -n "$feature" ]] || {
      echo "usage: $0 diff-drift <requirements.md> <summary.md> <todo-list.md> <feature>" >&2
      exit 64
    }
    python3 - "$requirements" "$summary" "$todo" "$feature" <<'PYEOF'
import sys, re
req, summary, todo, feature = sys.argv[1:]

def read(p):
    try:
        with open(p) as f: return f.read()
    except FileNotFoundError:
        return ""

req_text = read(req)
sum_text = read(summary)
todo_text = read(todo)

# Extract item ids from requirements.md's Goals section.
req_goals = re.search(r'^## Goals \(this cycle\).*?(?=^## |\Z)', req_text, re.DOTALL | re.MULTILINE)
goal_items = []
if req_goals:
    for m in re.finditer(r'\*\*([A-Z]+-\d+)\*\*\s*[—\-:]\s*(.+?)(?=\n\s*-|\n##|\Z)', req_goals.group(0), re.DOTALL):
        goal_items.append((m.group(1), m.group(2).strip().splitlines()[0]))

# For each goal item id, check if its one-line description is present in
# summary.md (active feature section) and todo-list.md.
drift = []
sum_section = re.search(rf'^## Feature: {re.escape(feature)}.*?(?=^## |\Z)', sum_text, re.DOTALL | re.MULTILINE)
for id_, desc in goal_items:
    short = desc[:60]
    if sum_section and short.split()[0] not in sum_section.group(0):
        drift.append(f"  - {id_}: requirements.md mentions \"{short}…\" — not found in summary.md’s feature section")
    if id_ in todo_text and short.split()[0] not in todo_text:
        drift.append(f"  - {id_}: requirements.md description differs from todo-list.md description")

print("\n".join(drift))
PYEOF
    ;;
```

The `diff-drift` helper is intentionally simple — it surfaces possible drift, never blocks. Refinements can come later if the inspector says it's too noisy.

- [ ] **Step 4:** Verify `mi-apply-impact.md` still passes the bundle test:

```bash
tests/bundle/run.sh
```

Expected: exit 0.

- [ ] **Step 5:** Update the stage-2 handoff message at the very end of `mi-apply-impact.md` to mention the review:

```markdown
"Blueprints generated for `<feature>` at `workflow-stream/<feature>/blueprints/current/`. The blueprint was auto-reviewed by `codex` and any remaining findings are inline as `<!-- REVIEW-FINDING -->` comments. Review `requirements.md`, `config.md`, and `diagrams/`. When ready, type **`/mi-continue`**."
```

(Replace the existing handoff message; the precise current wording is in `mi-apply-impact.md` Step 3.2.)

### Task 5.2: Update `docs/blueprint-regeneration.md`

**Files:**
- Modify: `docs/blueprint-regeneration.md`

- [ ] **Step 1:** Add a short section between Step B and Step C noting that the blueprint review runs after `config.md` is generated and before diagrams. Insert text like:

```markdown
## Step B.5 — Auto-review

After writing `config.md` and before generating diagrams, `mi-apply-impact` auto-invokes `/mi-blueprint-review codex 3 5` against the newly-written `requirements.md`. This is a quality gate using an external coding agent (Codex by default) as the reviewer; the millwright (Claude) is the fixer. Findings live inline in `requirements.md` as `<!-- REVIEW-FINDING -->` comments; resolved ones are cleaned up automatically. See `docs/blueprints-review/plan.md` for the full design.

If the codex MCP server is unavailable, the review is skipped and a warning is printed. The rest of stage 2 continues normally.

## Step B.6 — Drift surfacing

If the review rewrote `requirements.md`, `mi-apply-impact` diffs it against the active cycle's `summary.md` and `todo-list.md` and surfaces a heads-up message. The millwright does not auto-edit either file. The inspector reads the heads-up, optionally edits, and proceeds.
```

### Task 5.3: End-to-end smoke test of stage 2 with auto-review

**Files:**
- (none — verification only)

- [ ] **Step 1:** In a workspace with an active mi-workflow, deliberately mark a TODO item that would produce an inconsistent `requirements.md` (e.g., one whose journal entry contradicts itself). Run through stages 0 → 1 → 1.5 normally.

- [ ] **Step 2:** When stage 1.5 auto-fires `/mi-apply-impact`, observe:
  - Step A generates `requirements.md`.
  - Step B generates `config.md`.
  - **NEW** Step B.5 auto-invokes `/mi-blueprint-review`, which produces inline findings and fixes for `requirements.md`.
  - **NEW** Step B.6 surfaces drift (if any) in `summary.md` / `todo-list.md`.
  - Step C generates diagrams.
  - Handoff message mentions the auto-review.

- [ ] **Step 3:** Manually inspect the final `requirements.md`. Frontmatter intact; any leftover `<!-- REVIEW-FINDING -->` comments visible at the top of the body.

- [ ] **Step 4:** Type `/mi-continue` to verify the rest of the workflow proceeds unchanged (stage 3, etc.).

- [ ] **Step 5:** Commit Tasks 5.1–5.3 together:

```bash
git add commands/mi-apply-impact.md \
        scripts/blueprint-review.sh \
        docs/blueprint-regeneration.md
git commit -m "$(cat <<'EOF'
mi-apply-impact: auto-invoke /mi-blueprint-review at stage 2

Inserts Steps B.5 (auto-review) and B.6 (drift surfacing) between
config.md generation and diagram generation. Non-blocking — degrades
to a warning when codex MCP is unavailable. summary.md and
todo-list.md are NOT auto-edited; drift is surfaced as a heads-up.

Defers diagram generation to after the review completes (existing
Step C runs last), so the inspector sees diagrams that reflect the
post-review requirements.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 6 — Version bump and docs

### Task 6.1: Bump plugin version to v1.2.0

**Files:**
- Modify: `.claude-plugin/plugin.json`

- [ ] **Step 1:** Change `"version": "1.1.0"` to `"version": "1.2.0"` in `plugin.json`.

- [ ] **Step 2:** Validate JSON:

```bash
python3 -m json.tool .claude-plugin/plugin.json > /dev/null && echo ok
```

### Task 6.2: Add a CHANGELOG entry

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1:** Insert a new section at the top of `CHANGELOG.md`:

```markdown
## 1.2.0 — Blueprints review: AI-driven consistency + per-item review

Adds three slash commands and two read-only reviewer sub-agents that use an external coding agent (Codex first) via MCP to review markdown spec files (especially `requirements.md` at stage 2) for cross-item consistency and per-item completeness. Findings live inline in the reviewed file as `<!-- REVIEW-FINDING -->` HTML comments; resolved findings are cleaned up automatically.

### What changed

- **New commands** under `commands/`:
  - `/mi-blueprint-review-consistency <agent> <max-iter> <file>` — whole-file consistency loop.
  - `/mi-blueprint-review-item <agent> <max-iter> <file:item-id | content>` — per-item loop, two modes (file-anchored / stateless).
  - `/mi-blueprint-review <agent> <max-c-iter> <max-i-iter> <file>` — orchestrator: consistency → per-item batched → final consistency.
- **New sub-agents** under `agents/`:
  - `blueprint-consistency-reviewer` — serial; writes the file directly.
  - `blueprint-item-reviewer` — strictly read-only (tools list contains only the reviewer MCP tool); returns region replacements via a Payload JSON extension to the sub-agent return contract.
- **New script** `scripts/blueprint-review.sh` with subcommands: `resolve-tool`, `enumerate` (deterministic offset computation from reviewer-supplied `{id, anchor_line, occurrence_index}`), `parse-findings`, `alloc-final-id`, `diff-drift`.
- **Three new templates** under `templates/` for the consistency, per-item, and enumeration reviewer prompts.
- **Stage-2 integration:** `mi-apply-impact` now auto-invokes the orchestrator on `requirements.md` between `config.md` generation and diagram generation. Skipped gracefully when codex MCP is unavailable.
- **`docs/sub-agent-return-contract.md`** gains a "Payload JSON extension" section documenting the fenced-block pattern for sub-agents that need to hand back structured data.
- **`scripts/doctor.sh`** gains a `mcp:codex` check (non-blocking).
- **`plugin.json`** declares the `codex` MCP server (`codex mcp-server`).

See [`docs/blueprints-review/plan.md`](./docs/blueprints-review/plan.md) and [`docs/blueprints-review/implementation.md`](./docs/blueprints-review/implementation.md) for full design and implementation history.
```

### Task 6.3: Update README.md

**Files:**
- Modify: `README.md`

- [ ] **Step 1:** Find the existing commands section in `README.md` and add a subsection covering the three new commands. The exact placement depends on the existing structure; aim for a short three-bullet addition near the other `/mi-*` listings:

```markdown
**Blueprint review (v1.2.0+):**

- `/mi-blueprint-review-consistency <agent> <max-iter> <file>` — run a whole-file consistency review loop using an external coding agent (Codex by default).
- `/mi-blueprint-review-item <agent> <max-iter> <file:item-id | content>` — review a single item, in place or stateless.
- `/mi-blueprint-review <agent> <max-c-iter> <max-i-iter> <file>` — orchestrator: consistency → per-item batched → final consistency. Auto-fires at stage 2 against `requirements.md` (codex, 3, 5 defaults).

See [`docs/blueprints-review/plan.md`](docs/blueprints-review/plan.md) for the design.
```

### Task 6.4: Update `docs/millwright-inspector-project.md`

**Files:**
- Modify: `docs/millwright-inspector-project.md`

- [ ] **Step 1:** In §6.2 (Stage 2 description), add a sentence after the existing Step B description noting that `mi-blueprint-review` auto-fires next, before diagrams.

- [ ] **Step 2:** In §5 (Roles × plugin interaction table), add a row for the auto-fired blueprint review (Stage 2). Sample row:

```markdown
| Millwright (auto) | `/mi-blueprint-review` (auto-fired in stage 2 by `mi-apply-impact`) | Reviewer-fixer loop on `requirements.md` via Codex MCP; findings inline as `<!-- REVIEW-FINDING -->`. | 2 |
```

- [ ] **Step 3:** Commit Tasks 6.1–6.4 together:

```bash
git add .claude-plugin/plugin.json CHANGELOG.md README.md docs/millwright-inspector-project.md
git commit -m "$(cat <<'EOF'
v1.2.0 — Blueprints review: docs + version bump

Bumps plugin version to 1.2.0 and adds the v1.2.0 CHANGELOG entry,
README listing for the three new /mi-blueprint-review* commands, and
project-reference notes (stage-2 description + roles table).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 7 — Tests

### Task 7.1: Extend bundle / lint tests for the new files

**Files:**
- Modify: `tests/bundle/run.sh` (if needed; new files may already be picked up by glob patterns)
- Modify: `tests/lint/run.sh` (if needed)

- [ ] **Step 1:** Run the existing tests as-is to see whether they auto-discover the new files:

```bash
tests/bundle/run.sh
tests/lint/run.sh
```

If both pass, no test changes are needed — the new commands and agents are discovered by the existing glob patterns. Skip to Step 3.

- [ ] **Step 2:** If either test fails or doesn't cover the new files, add explicit assertions:
  - `tests/bundle/run.sh`: ensure new commands have valid frontmatter (no schema exists for command files — just check the YAML parses).
  - `tests/lint/run.sh`: ensure `scripts/blueprint-review.sh` passes shellcheck (or whatever lint command this repo uses).
  - Smoke test for `scripts/blueprint-review.sh`: run `resolve-tool codex` and expect `mcp__codex__codex` (or the resolved name).

- [ ] **Step 3:** Commit any test updates:

```bash
git add tests/
git commit -m "$(cat <<'EOF'
tests: cover blueprint-review commands, agents, and helper script

Adds (or verifies) that the bundle and lint tests pick up the new
commands/agents/scripts introduced in v1.2.0.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

Before declaring the implementation complete:

- [ ] All commits land on the feature branch; the working tree is clean (`git status`).
- [ ] All four smoke tests in Phases 2.4, 3.5, 4.2, 5.3 pass on a real workspace.
- [ ] `tests/bundle/run.sh` and `tests/lint/run.sh` both exit 0.
- [ ] `/mi-doctor` reports `codex` as present (or warns gracefully if absent).
- [ ] `docs/blueprints-review/plan.md` and `docs/blueprints-review/implementation.md` are both in the repo and cross-referenced correctly.
- [ ] `plugin.json` version is `1.2.0`.

When all checks pass, open a PR against `main` referencing both the design (`plan.md`) and the implementation history (`implementation.md`).
