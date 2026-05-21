# Blueprints Review — multi-agent file & item review — Plan & Design

**Status:** Pre-implementation. Open decisions in §13 should be confirmed before work begins.

**Target version:** `v1.2.0` (new minor — adds three commands, two sub-agents, one helper script, one MCP server declaration; modifies `commands/mi-apply-impact.md` and `docs/blueprint-regeneration.md`).

---

## 1. Motivation & summary

The mi-workflow generates `requirements.md` at stage 2 from the cycle's `summary.md` plus a bounded codebase-grounding pass. Today there is no automated second opinion on that artifact before the inspector reads it: inconsistencies between items, weakly-stated acceptance criteria, missing seam references, and contradictions between Goals and Planned typically survive to the inspector's review and either bounce back through `/mi-update-blueprint` or leak into the implementation.

This feature adds a self-contained reviewer-fixer loop that uses an **external coding agent** (Codex first, others via MCP) as the reviewer and Claude (this plugin) as the fixer. It ships as three slash commands:

1. **`/mi-blueprint-review-consistency`** — whole-file consistency loop. Finds cross-item contradictions, missing references, and other file-wide issues. One review-loop on the file as a single unit.
2. **`/mi-blueprint-review-item`** — single-item loop. Reviews one item (a Goals bullet, or arbitrary content passed inline) for unclear language, missing acceptance criteria, internal inconsistencies, and gaps.
3. **`/mi-blueprint-review`** — orchestrator. Runs a consistency loop, then **per-item loops batched in parallel**, then a **final consistency loop** to catch any new contradictions introduced by item-level rewrites.

The commands are **standalone** — they can review any markdown file, with or without an active mi-workflow. The orchestrator is **also auto-fired at stage 2** for the active feature's `requirements.md` (see §10).

Findings live **inline in the reviewed file** as HTML comments. Resolved findings are cleaned up by the fixer when it actually addresses them; unresolved findings stay in the file when a loop exits via max-iters.

The role split is preserved: the **millwright (Claude)** drives orchestration and applies fixes; the **reviewer agent (Codex)** emits findings; the **inspector** sees the cleaned artifact and only intervenes on max-iter `y/n` prompts.

---

## 2. Scope decisions (confirmed)

| Decision | Outcome |
| --- | --- |
| How the reviewer agent is invoked | **MCP tool, agent-specific.** Each supported reviewer (Codex first) ships an MCP server declared in `plugin.json`. The sub-agent maps the `<agent>` argument to a known MCP tool name and prompts the tool with file/item content + a strict reviewer prompt. Adding a new reviewer = editing `plugin.json` + adding one mapping entry. |
| Whether commands require an active mi-workflow | **No.** All three commands run standalone on any file (or item content). The orchestrator is *additionally* auto-fired by `mi-apply-impact` during stage 2. |
| Where findings are stored | **Inline HTML comments inside the reviewed file**, one comment per finding, placed at the relevant location. Invisible in rendered markdown; visible to both agents in raw text. Content-only mode (no file path) prints findings to terminal instead — no persistence. |
| Cleanup behavior | **Clean up resolved findings only.** When the fixer addresses a finding, the corresponding `<!-- REVIEW-FINDING -->` comment is removed. Unresolved findings stay in the file when the loop exits via max-iters. No end-of-loop pass that removes everything. |
| Completion conditions of a single loop | (a) The reviewer returns zero High and zero Medium findings → **success**; (b) the iteration counter reaches the max → **max-iter exit**. Low-only findings are tolerated as success. |
| Behavior on max-iter exit | The loop prompts the inspector `y/n` for "perform another review loop?" — **per loop**, not once at the end of the orchestrator. On `y`, a fresh loop with the same max-iter budget starts from the file's current state. On `n`, remaining findings stay inline and orchestration continues. |
| Item identification | **Split between the reviewer agent and the script.** The reviewer is asked only to return `[{id, anchor_line, occurrence_index}]` — IDs and verbatim first-lines in document order, plus a 1-based disambiguator when an `anchor_line` repeats in the file (§5.4 / §11.3). `scripts/blueprint-review.sh enumerate` then computes the canonical `{id, start_offset, end_offset, original_region}` descriptor deterministically from those anchors. LLMs are kept off the byte-arithmetic path. No item-format convention is enforced. |
| Severity field | **High / Medium / Low**, emitted by the reviewer per finding. No `scope:` tier (that field stays on `inspector-review.md` for stage 5/6). |
| Per-item I/O modes | **Two modes.** `/mi-blueprint-review-item <agent> <max-iter> <file>:<item-id>` edits the file in place. `/mi-blueprint-review-item <agent> <max-iter> <content>` is stateless and prints results to terminal. When called from the orchestrator, the per-item sub-agent uses the file-path mode. |
| Batching policy | **Default batch size 5, configurable via `--batch-size N`, hard cap `MAX_ITEMS_PER_REVIEW=20`.** If the reviewer enumerates more than 20 items, the orchestrator refuses to start and tells the inspector to split the file across cycles. |
| Drift in adjacent quest files after `requirements.md` is rewritten | **Surface to inspector, do not auto-edit.** After review completes, diff the rewritten `requirements.md` against the active cycle's `summary.md` and `todo-list.md`; surface proposed edits as a heads-up message. The inspector decides whether to apply. |
| Diagram generation at stage 2 | **Deferred to *after* the review completes.** Existing `mi-apply-impact` Step C runs last, after review and drift surfacing. |

---

## 3. End-to-end flow (standalone, orchestrator)

```
inspector: /mi-blueprint-review codex 3 5 path/to/requirements.md
   │
   ├─ preflight: file exists; codex MCP available; reviewer-tool mapping resolved
   ├─ phase 1 — consistency loop (max=3)
   │     ├─ iter 1: call reviewer; findings → inline HTML comments; fixer applies fixes; remove resolved comments
   │     ├─ iter 2: call reviewer; ...; if no H/M → success exit
   │     └─ … or max-iter exit → prompt y/n → on y, restart loop with same max=3
   ├─ phase 2 — item enumeration
   │     ├─ one-shot reviewer call: "return [{id, anchor_line, occurrence_index}]"
   │     │   in document order — IDs + verbatim first-lines + per-anchor ordinal
   │     │   only (NO byte offsets — LLMs are unreliable at byte arithmetic)
   │     └─ scripts/blueprint-review.sh enumerate: deterministically compute
   │        {start_offset, end_offset, original_region} from each anchor — see §5.4
   │        result: [PAY-001, PAY-002, …]  (refused if count > MAX_ITEMS_PER_REVIEW)
   ├─ phase 3 — per-item batched review (batch-size 5, max-iter=5 per item)
   │     ├─ batch 1: spawn 5 parallel sub-agents, one per item; each runs its own loop
   │     ├─ collect returns: items that exit max-iter trigger per-item y/n prompts
   │     ├─ on y for a given item: re-spawn that item's sub-agent with same max-iter
   │     ├─ batch 1 done → batch 2 → …
   │     └─ all batches done
   ├─ phase 4 — final consistency loop (max=3)
   │     ├─ same shape as phase 1; catches contradictions introduced by item rewrites
   │     └─ success or max-iter (with y/n)
   └─ phase 5 — print final report
         "No high/medium findings remain (Success)"
         OR  "Review complete; N high / M medium findings remain inline in <file>"
```

The standalone single-purpose commands (`-consistency`, `-item`) execute one of phases 1, 3, or a single-item slice of phase 3.

---

## 4. The three commands

### 4.1 `/mi-blueprint-review-consistency`

**File:** `commands/mi-blueprint-review-consistency.md`

**Usage:**

```
/mi-blueprint-review-consistency <agent> <max-iterations> <file-path>
```

| Param | Meaning |
| --- | --- |
| `<agent>` | Reviewer agent name. First supported: `codex`. Resolved against the agent → MCP-tool map in §7. |
| `<max-iterations>` | Positive integer. Maximum reviewer calls in this loop. |
| `<file-path>` | Path to a markdown file. Edits in place. |

**Execution outline:**

1. Resolve the reviewer's MCP tool name from `<agent>`. Refuse with a usage hint if `<agent>` is unknown.
2. Verify the file exists and is writable.
3. Spawn the `blueprint-consistency-reviewer` sub-agent with the file path, max-iter, and reviewer tool name. The sub-agent owns the loop (see §6.1) and writes the reviewed file directly each iteration — safe because consistency review is always serial. No `sub_agent_instance_id` is passed: the consistency sub-agent assigns final `F-NNN` ids inline (§5.5) and has no need for the tmp-id namespace.
4. Receive the sub-agent's return. Surface the final summary line:
   - `"No high/medium findings remain (Success)"` on `Result: success`, or
   - `"<N> high / <M> medium findings remain after <K> iterations — run another loop? (y/n)"` on `Result: partial` with a `max-iter` risk line.
5. On `y`: re-invoke the sub-agent with the same max-iter and the current file state. On `n`: stop.

**Notes.**
- No state in `progress.md` is mutated by this command.
- Findings are written *into the file*. No companion file is created.
- The reviewer is allowed to overwrite or update findings it previously left in the file — the prompt explicitly tells it to acknowledge prior comments and either re-flag or drop them.

### 4.2 `/mi-blueprint-review-item`

**File:** `commands/mi-blueprint-review-item.md`

**Usage (two modes):**

```
/mi-blueprint-review-item <agent> <max-iterations> <file-path>:<item-id>      # mode A: file-anchored
/mi-blueprint-review-item <agent> <max-iterations> <content>                  # mode B: stateless
```

**Mode A — file-anchored.** Argument has the shape `path/to/file.md:ITEM-ID`. The command:
1. Reads the file and asks the reviewer (one-shot) to locate the item with id `ITEM-ID` and return `[{id, anchor_line, occurrence_index}]` for that single item (see §5.4 / §11.3). Refuses if the reviewer can't find it.
2. Invokes `scripts/blueprint-review.sh enumerate` to deterministically compute the canonical region descriptor `{id, start_offset, end_offset, original_region}` from the reviewer's anchor.
3. Spawns the **read-only** `blueprint-item-reviewer` sub-agent with the item's `id` and `original_region` (no file path, no offsets — §6.2). The sub-agent loops on an in-memory working copy and returns `{item_id, original_region, new_region, remaining_findings}`. **The sub-agent never writes the reviewed file.**
4. The command (running in main) applies the region replacement to the file via `Edit` with exact-match validation against `original_region`. Final F-NNN ids are assigned at this point (see §5.5).
5. Surfaces the same success / max-iter message as §4.1.

**Mode B — stateless.** Argument is raw content (typically pasted by the inspector). The command:
1. Spawns `blueprint-item-reviewer` with the content directly (no region descriptor). The sub-agent loops on an in-memory copy and returns the final content + remaining findings.
2. Prints the final item content (with any unresolved `<!-- REVIEW-FINDING -->` comments inline) and a summary to the terminal. No file is written.

**Notes.**
- The `:item-id` separator is colon. To support file paths containing colons (rare on macOS, common on Windows), the command also accepts `--file <path> --item <id>` as an explicit alternative form.
- Item discovery (finding the item by id) is delegated to the reviewer agent — the command does not encode any item-format convention.

### 4.3 `/mi-blueprint-review` (orchestrator)

**File:** `commands/mi-blueprint-review.md`

**Usage:**

```
/mi-blueprint-review <agent> <max-consistency-iter> <max-item-iter> <file-path>
                     [--batch-size N]
```

| Param | Meaning |
| --- | --- |
| `<agent>` | Reviewer agent. Same resolution as §4.1. |
| `<max-consistency-iter>` | Max iterations for **each** consistency loop (initial and final). |
| `<max-item-iter>` | Max iterations **per item**. Applies to every item review in every batch. |
| `<file-path>` | Markdown file. Edits in place. |
| `--batch-size N` | Optional. Defaults to 5. Maximum items reviewed in parallel per batch. |

**Execution outline** (phases match §3):

1. **Preflight** — resolve agent, verify file exists, verify reviewer MCP tool is callable.
2. **Phase 1 — initial consistency loop.** Same logic as `/mi-blueprint-review-consistency`. On max-iter, the orchestrator prompts the inspector `y/n`; on `y` the loop restarts; on `n` the orchestrator proceeds to phase 2 with the remaining findings inline.
3. **Phase 2 — item enumeration.** Two-step (see §5.4 for the canonical descriptor):
   1. One-shot reviewer call asking only for an array of item identifiers + anchor strings + occurrence indices — the reviewer never produces byte offsets. Shape: `[{id, anchor_line, occurrence_index}]` in **document order**, where `anchor_line` is the exact first line of each item as it appears in the file (the reviewer is told to copy it verbatim) and `occurrence_index` is a 1-based ordinal that disambiguates when the same anchor repeats (§11.3).
   2. `scripts/blueprint-review.sh enumerate` consumes that list and computes each item's deterministic `{start_offset, end_offset, original_region}` by indexing each `anchor_line` to its `occurrence_index`-th match in the file body and walking forward to the next anchor / heading. The script is the single source of truth for byte offsets; the reviewer's responsibility is restricted to *identification* and *disambiguation*, not measurement.

   If the resolved count exceeds `MAX_ITEMS_PER_REVIEW`, refuse and print:
   > "File has N items, which exceeds the cap of 20. Split this file across multiple cycles, or run `/mi-blueprint-review-item` manually on a subset."
4. **Phase 3 — per-item batched review.** For each batch of up to `batch-size` items:
   - Spawn one `blueprint-item-reviewer` sub-agent per item, in parallel. Each sub-agent receives **only `id`, `original_region`, `max_iterations`, `agent`, `reviewer_tool_name`, and `sub_agent_instance_id`** (no offsets, no file path — see §6.2). The orchestrator (running in main) retains the offsets so it can sort returns for serialized write-back. Each sub-agent runs an independent loop with its own counter (max = `<max-item-iter>`) and returns a `Payload JSON:` block with `{item_id, original_region, new_region, remaining_findings}`. **Sub-agents do not write the file.**
   - Apply returns in main per §9: sort by `start_offset` ascending, apply each via `Edit` with exact-match against `original_region`, recompute offsets for remaining returns. Rewrite all `tmp_id` values inside each `new_region` to final `F-NNN` ids during this pass (see §5.5).
   - On an exact-match failure during write-back: re-enumerate that item from the file's current state and re-spawn its sub-agent. Continue with the remaining returns.
   - For each return whose `Result: partial` carried a `max-iter` risk line, prompt the inspector individually:
     > "Item `<ITEM-ID>` review: N high / M medium findings remain after K iterations — run another loop? (y/n)"
   - On `y`: re-spawn that item's sub-agent (same max budget, **re-enumerated region** from current file state). On `n`: leave the item's findings inline and continue.
   - When all sub-agents (including any re-runs) have terminated, move to the next batch.
5. **Phase 4 — final consistency loop.** Identical to phase 1; catches contradictions introduced by item-level rewrites in phase 3.
6. **Phase 5 — final report.** Print:
   - `"No high/medium findings remain (Success)"` if all loops succeeded; or
   - A summary of remaining findings: total counts, locations.

**Notes.**
- The orchestrator does *not* itself prompt for diagram regeneration or drift surfacing — those are stage-2 concerns handled by the caller (`mi-apply-impact`, see §10).
- The orchestrator never modifies `progress.md` or any quest file.

---

## 5. Findings format

### 5.1 Inline HTML comment

Every finding is encoded as exactly one HTML comment placed adjacent to the offending content. The reviewer emits a finding's *semantic* fields; the sub-agent renders the comment.

```markdown
<!-- REVIEW-FINDING
     id: F-007
     severity: high
     agent: codex
     iteration: 2
     phase: consistency | item
     target: PAY-001                  (item-id when phase=item; "file" when phase=consistency and no specific anchor)
     finding: |
       Free-form 1–N line description of the issue.
     suggested-fix: |
       Free-form 1–N line description of the proposed change.
-->
```

**Placement.**
- `phase: item` findings are placed immediately after the offending line within the item's content (e.g., after the bullet under `## Goals (this cycle)`).
- `phase: consistency` findings are placed at the top of the file, above the first top-level heading, in a single contiguous block. They are not interleaved with content, because by definition they are cross-item.

**Id uniqueness.** `id: F-NNN` is unique per file *and* monotonically increasing. Assignment is split by sub-agent type — see §5.5 for the full rule:
- **Consistency sub-agent (always serial)** assigns final `F-NNN` ids directly when it writes findings into the file. No temporary-id step.
- **Item sub-agent (parallel-capable)** emits temporary ids of the form `T<instance>-<n>`; the orchestrator/command rewrites them to final `F-NNN` during serialized write-back in main.

**No frontmatter changes.** The reviewed file's YAML frontmatter (e.g., `requirements.md`'s `id`, `todo-list-id`, `commits`) is **never touched** by the reviewer or fixer. The reviewer is told this explicitly; the sub-agent validates it after each iteration.

### 5.2 Reviewer wire protocol

The reviewer agent receives a strict prompt asking for **a JSON array of findings**, fenced in a code block. The sub-agent parses the JSON and renders the HTML comments itself — the reviewer does not write to the file directly.

```json
[
  {
    "severity": "high",
    "phase": "consistency",
    "target": "file",
    "finding": "Goal PAY-001 says \"return 400\" but its acceptance criteria say \"raise ValidationError\". Pick one.",
    "suggested-fix": "If HTTP, write \"reject with 400\". If domain, write \"raise ValidationError\"."
  },
  {
    "severity": "medium",
    "phase": "item",
    "target": "PAY-002",
    "finding": "Item names the seam `services/` but never says which service.",
    "suggested-fix": "Specify the concrete service file or sub-folder."
  }
]
```

**Why JSON in, HTML out.**
- JSON in: robust to parse, reviewer-agnostic. Different reviewer agents will produce different freeform markdown, but most agree on JSON when asked explicitly.
- HTML out (inline comments): invisible in rendered markdown, visible in raw text, positioned at the relevant location, and convertible back to JSON if needed.

### 5.3 Cleanup semantics

- When the fixer applies a fix in iteration N, it removes the corresponding `<!-- REVIEW-FINDING -->` comment as part of the same edit. The comment is **only** removed when the underlying content has changed in a way that addresses the finding.
- A finding the fixer cannot resolve in iteration N stays in place; the reviewer at iteration N+1 reads the file *including* that unresolved comment and is instructed to:
  - **Re-flag** the same issue (with a new `iteration` value) if it still applies, possibly with refined wording, OR
  - **Drop** the stale comment (omit it from the JSON return) if the issue is no longer present. The sub-agent reconciles by replacing the file's `REVIEW-FINDING` block list with the new iteration's output — stale comments naturally disappear.
- At max-iter exit, the sub-agent does **not** strip any comments. Whatever the final iteration produced stays in the file.

### 5.4 Canonical item region descriptor

Phase 2's enumeration produces a single canonical descriptor used everywhere downstream — the orchestrator, per-item sub-agents, and the serialized write-back step. **No other shape is allowed**; do not introduce `content_excerpt`, line ranges, or LLM-produced offsets elsewhere in the implementation.

```json
{
  "id":              "PAY-001",
  "start_offset":    1284,                              // byte offset, 0-indexed, into the file body (after frontmatter)
  "end_offset":      1452,                              // exclusive
  "original_region": "- **PAY-001** — ...\n  Acceptance criteria: ...\n"
}
```

**Who produces what:**

- **The reviewer agent (Codex via MCP)** identifies items only by id, an `anchor_line` (verbatim copy of the item's first line), and an `occurrence_index` — a 1-based count that disambiguates when the same `anchor_line` appears multiple times in the file (e.g., two bullets that begin with the generic text `- Description:`). The reviewer **never** produces byte offsets — LLMs are unreliable at byte arithmetic, especially with non-ASCII text and JSON escaping. Items are returned in document order.
- **`scripts/blueprint-review.sh enumerate`** consumes the reviewer's `[{id, anchor_line, occurrence_index}]` list and computes each item's `{start_offset, end_offset, original_region}` deterministically:
  1. Pre-scan: for each unique `anchor_line` the reviewer named, enumerate every byte position where it appears in the file body (skipping the YAML frontmatter) via exact substring match.
  2. For each item, resolve its `anchor_line` to a byte position by indexing into the pre-scanned occurrence list with `occurrence_index - 1`. If the index is out of range (the reviewer claimed e.g. `occurrence_index=3` but the line appears only twice), drop the item with a warning to the inspector. If `anchor_line` does not appear in the file at all, drop with a stronger warning (reviewer hallucination).
  3. Walk forward from the resolved byte position to find the item's end: the line immediately *before* the next item's start_offset (in document order), or to the next top-level heading (`^## `), or to EOF — whichever comes first.
  4. Emit `start_offset = anchor_byte_position`, `end_offset = computed_end_byte_position`, `original_region = file[start_offset:end_offset]`. All three fields are derived; none are LLM-trusted.
  5. Sanity check: every item's `original_region` must start with `anchor_line` (otherwise the script's walk has a bug). Items failing this check are dropped with a warning.

**Properties of the descriptor:**

- **`start_offset` / `end_offset` are byte offsets into the file as it currently exists on disk.** They are *not* line numbers (line numbers shift unpredictably when inline `REVIEW-FINDING` comments are inserted).
- **`original_region` is the exact, byte-for-byte content of the range `[start_offset, end_offset)`** at enumeration time. It is the authoritative substring; offsets exist so the orchestrator can sort returns for serialized write-back and avoid re-scanning the file for each `Edit`.
- The exact-match `Edit` in the serialized write-back step keys on `original_region`, not the offsets. If `original_region` doesn't match, the orchestrator re-enumerates and re-spawns (see §9).

### 5.5 Finding id assignment

Final `F-NNN` ids are unique per file and monotonically increasing. Assignment is split by sub-agent type to match the dual write-ownership model (§9):

- **Consistency sub-agent (always serial; writes the file directly).** Assigns final `F-NNN` ids itself, with **no temporary-id intermediate step**. Each iteration: scan the file for the current highest `F-NNN`, increment for each new finding, embed the final id directly in the `REVIEW-FINDING` block, write the file. Safe because no parallel sub-agent can race the scan-and-write for the same file.
- **Item sub-agent (parallel-capable; read-only on the file).** Receives a `sub_agent_instance_id` (e.g., `T1`, `T2`, …) in its spawn prompt and emits new findings with **temporary ids** of the form `T<instance>-<n>` (e.g., `T3-2` = instance 3's second new finding). It returns these `tmp_id` values inside `new_region`. During serialized write-back in main, the orchestrator/command scans the file's *current* highest `F-NNN` and rewrites each `tmp_id` inside the next `new_region` to a monotonic `F-NNN` before the `Edit` is applied — so each region replacement's findings are consecutively numbered against the file's running max.
- **Standalone `/mi-blueprint-review-item` mode A**: identical to the parallel case — the command performs the same `tmp_id → F-NNN` rewrite in main before writing. Uniform code path.
- **Standalone `/mi-blueprint-review-item` mode B**: `tmp_id` values appear in the printed terminal output. Because no file persists, terminal output keeps the `T<instance>-<n>` ids — they are scoped to this single invocation and have no continuity with anything else. (If we later want `F-NNN` in the terminal output for readability, the command can do a final rewrite pass before printing; defer to D8 in §13.)

---

## 6. Sub-agent architecture

Two new sub-agents, both following the existing pattern (`agents/*.md` with `name`, `description`, `model`, `effort`, `tools` frontmatter, then prompt body).

### 6.1 `blueprint-consistency-reviewer`

**File:** `agents/blueprint-consistency-reviewer.md`

**Purpose:** Run one consistency loop on a whole file. **Writes the reviewed file directly** at each iteration (whole-file replacement via `Write`). This is safe because consistency review is **always serial** — exactly one consistency sub-agent runs per file at a time (no parallelism, no race). The parallel write-ownership concerns in §9 apply only to per-item review.

**Tools:** `Read, Write, Edit, Bash, Grep` plus every supported reviewer's MCP tool listed explicitly in the agent file's `tools:` frontmatter (e.g., `mcp__codex__codex`). Sub-agents cannot invoke tools that are not in their declared list, so the list grows by one entry every time a new reviewer agent is added in §7.

**Inputs (from spawn prompt):**
- `file_path`
- `max_iterations`
- `agent` (e.g., `codex`)
- `reviewer_tool_name` (e.g., `mcp__codex__codex`) — resolved by the caller from the agent → MCP-tool map. Must already be present in the sub-agent's `tools:` frontmatter; the spawn prompt tells the sub-agent *which* of its declared tools to call for this invocation.

**Loop body (per iteration):**
1. Read `file_path` (current state, including any prior `REVIEW-FINDING` comments).
2. Build the reviewer prompt: file content + instructions (see §5.2 + §11).
3. Call the reviewer MCP tool. Parse JSON. On parse failure: log and retry once; on second failure: return `Result: blocked`.
4. Reconcile new findings against existing `REVIEW-FINDING` comments in the file:
   - For each existing comment, if the new findings include an equivalent one, refresh the comment's `iteration` field. If the new findings do not, the issue is resolved (or dropped) — remove the stale comment.
   - For each new finding without a matching existing comment, scan the file for the current highest `F-NNN` and append a fresh `REVIEW-FINDING` block with the **final** id `F-<next>`. No tmp-id step is needed — consistency review is always serial, so the scan-and-write is race-free.
5. Write the updated file to disk via `Write`. Validate frontmatter unchanged (§9 rule 1); revert and retry the iteration on mismatch.
6. Check completion: if `count(high) + count(medium) == 0` → return `Result: success`.
7. Check max-iter: if `iteration >= max_iterations` → return `Result: partial` with a `max-iter` risk line. Findings remain in the file.
8. Otherwise, **fix step**: apply edits to the file that address the findings (and remove their `REVIEW-FINDING` comments). Re-validate frontmatter unchanged.
9. Increment iteration; loop.

**Returns** (per `docs/sub-agent-return-contract.md` — the `Result` field uses only `success | partial | blocked` per the existing contract; max-iter exits are encoded as `partial` with a structured risk line):

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

### 6.2 `blueprint-item-reviewer`

**File:** `agents/blueprint-item-reviewer.md`

**Purpose:** Run one item review loop, either on a region descriptor from a file (mode A) or on raw content (mode B). **Strictly read-only with respect to any file** — the sub-agent has no filesystem-write tool in its `tools:` list, so a runtime write attempt would fail at the tool layer, not just by convention. The orchestrator (running in main) applies returned region replacements serially.

**Tools (minimal, deliberately):** ONLY the reviewer MCP tool, listed explicitly by name (e.g., `mcp__codex__codex`). **No `Read`, no `Write`, no `Edit`, no `Bash`, no `Grep`** — `Bash` alone is enough to read or write arbitrary workspace files, which would defeat the structural read-only guarantee even if `Write`/`Edit` were absent. The sub-agent operates entirely on the content it receives in the spawn prompt and the reviewer's responses; it never needs to touch the filesystem.

**What the sub-agent does in-prompt, with no helpers:**
- **Existing-finding extraction.** The sub-agent scans the in-memory `original_region` text for `<!-- REVIEW-FINDING ... -->` blocks by pattern, parses them from the comment body, and tracks them across iterations. No external parser needed — the content is finite and structured.
- **Tmp-id allocation.** Allocates `T<instance>-<n>` ids starting at `n = 1`, incrementing on each new finding it emits this iteration. `instance` is passed in as `sub_agent_instance_id`. No "ceiling" computation is needed — every new id within this sub-agent's namespace is fresh; collisions are impossible because `<instance>` is unique per spawn.
- **Severity counting.** Counts high/medium/low directly from the reviewer's JSON response. The reviewer returns severity per finding (§5.2), so counting is a pass over its output array.
- **Frontmatter checks** are **not the item sub-agent's concern.** The item sub-agent operates on a region of body text — no frontmatter is present in its working copy. The orchestrator validates frontmatter byte-equality after each `Edit` write-back in main (§9 rule 1).

If a future feature needs heavier parsing (e.g., cross-region structural validation), the helper belongs in `scripts/blueprint-review.sh` and is called from main *before* spawning the sub-agent; the precomputed result is passed in via the spawn prompt. The sub-agent's scope stays: "given a content snapshot, call the reviewer, reconcile findings into the snapshot via in-prompt reasoning, emit fixes in-language."

**Inputs (from spawn prompt):**
- `mode: file | content`
- Mode A: only `id` and `original_region` from the descriptor (no `file_path`, no `start_offset` / `end_offset`, no `occurrence_index` — main retains those for write-back ordering and re-enumeration on exact-match failure; passing them here would leak mutation metadata into a read-only sub-agent's context for no purpose).
- Mode B: `content` (raw string).
- `max_iterations`
- `agent`, `reviewer_tool_name`
- `sub_agent_instance_id` — small integer assigned by the orchestrator (`T1`, `T2`, …) used as a temporary-id prefix to avoid collisions across parallel sub-agents (see §5.5).

**Loop body:** Same shape as §6.1 (call reviewer → reconcile findings → check completion → check max-iter → fix step), but operating on an in-memory working copy initialized from `original_region` (mode A) or `content` (mode B). No file I/O at any iteration. When the loop exits the sub-agent emits a `Payload JSON:` block (see Returns below).

- **Mode A:** payload's `item_id` and `original_region` are populated from the spawn inputs; `new_region` is the final working copy. The calling command applies the replacement in main via `Edit` with exact-match validation against `original_region`. If the exact match fails (the region has shifted), the orchestrator re-spawns the sub-agent against the freshly-enumerated region (see §9).
- **Mode B:** payload's `item_id` is `null` and `original_region` is `null`; `new_region` holds the final working copy. The calling command prints it to terminal — no file write happens. The shape is uniform with mode A so the orchestrator can reuse the parser.

**Why a region, not the whole file.** Per-item review is meant to focus the reviewer on a single item's coherence (clarity, acceptance criteria, seam reference, internal consistency). Feeding it the whole file would (a) re-trigger consistency findings already covered by phase 1, and (b) increase reviewer cost N-fold across the batch.

**Returns (extension of `docs/sub-agent-return-contract.md`):** This sub-agent must hand back a machine-readable payload, not just file paths. The canonical contract doesn't include a "structured payload" channel, so this design introduces a **named, fenced payload block placed BEFORE the standard fields** — an explicit extension that the calling command knows to parse. The shape (outer fence uses four backticks so the inner triple-backtick JSON block is unambiguous):

````
Payload JSON:
```json
{
  "item_id": "PAY-001",
  "original_region": "<exact bytes the sub-agent received>",
  "new_region":      "<exact bytes to write back>",
  "remaining_findings": [
    {
      "tmp_id":        "T3-2",
      "severity":      "medium",
      "phase":         "item",
      "target":        "PAY-001",
      "finding":       "...",
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
- item-id: <ITEM-ID>
- original-region-bytes: <N>
- max-iter: <H> high / <M> medium remain inline    (only when Result=partial)
Main should read:
- (none — main reads the Payload JSON block above)
````

Properties of the extension:

- The block starts with the literal line `Payload JSON:`, immediately followed by a triple-backtick `json`-tagged fenced code block carrying a single JSON object. Parsers MUST tolerate optional whitespace inside the fence but the fences and the `json` tag are mandatory.
- The block is **mandatory** on `Result: success` and `Result: partial`. It is allowed-but-not-required on `Result: blocked` (the sub-agent may legitimately have no payload to return if blocked before producing `new_region`).
- The block appears exactly once per return; if a sub-agent emits multiple, parsers use the first.
- All standard fields below the payload remain unchanged from `docs/sub-agent-return-contract.md`.

`tmp_id` values inside `remaining_findings` are scoped to this sub-agent's `sub_agent_instance_id`. The orchestrator rewrites them to final `F-NNN` ids during serialized write-back (§5.5).

`docs/sub-agent-return-contract.md` and `templates/sub-agent-return.md.tmpl` get a new section documenting this `Payload JSON:` extension so future sub-agents that need a structured payload can use the same shape (see §14 modified files).

### 6.3 Why two sub-agents instead of one

Whole-file consistency and per-item review have different reviewer prompts, different output anchors (file-top block vs adjacent to item), different inputs (whole file vs region/content), and different reviewer cost shapes. Sharing logic via a single sub-agent would force a mode flag through every step. Two narrow sub-agents are clearer.

### 6.4 Parallel item reviews

The orchestrator (`mi-blueprint-review` phase 3) spawns up to `batch-size` `blueprint-item-reviewer` sub-agents in parallel by issuing multiple `Agent` calls in one message — the standard Claude Code pattern for parallel sub-agents. Sub-agents are **read-only on the reviewed file** (§6.2, §9), so parallel safety is guaranteed by construction: no two sub-agents can touch the file at all, regardless of region overlap. The orchestrator then serializes the *write-back* of each sub-agent's returned `new_region` — see §9.

---

## 7. MCP integration

### 7.1 Declaration in `plugin.json`

Each supported reviewer agent's MCP server is declared in `plugin.json`'s `mcpServers` block, alongside the existing `plantuml` entry:

```json
"mcpServers": {
  "plantuml": { "command": "plantuml-mcp-server", "args": [] },
  "codex":    { "command": "codex",                "args": ["mcp-server"] }
}
```

The `codex mcp-server` subcommand is Codex CLI's stdio MCP server entrypoint (verified locally — `codex mcp` is a server-management command, **not** the stdio entrypoint). When the plugin is loaded, the tool `mcp__codex__codex` (or whatever Codex's MCP tool is named — see §13 D2) becomes available.

### 7.2 Agent → tool map

A small adapter file `scripts/blueprint-review.sh` exposes a single subcommand `resolve-tool <agent>` that returns the MCP tool name for a given agent argument:

```bash
$ scripts/blueprint-review.sh resolve-tool codex
mcp__codex__codex
$ scripts/blueprint-review.sh resolve-tool gemini
error: agent 'gemini' is not supported. Supported: codex
```

This indirection means:
- The mapping is in **one place** (the script), not duplicated across three command files and two sub-agents.
- Adding a new reviewer requires: edit `plugin.json` (add the MCP server) + edit `scripts/blueprint-review.sh` (add one case in `resolve-tool`).
- The sub-agents receive the resolved tool name in their spawn prompt and call it without knowing the agent's specifics.

### 7.3 Reviewer prompt templates

Three prompt templates live under `templates/`:

- `templates/blueprint-reviewer-prompt-consistency.md.tmpl` (§11.1)
- `templates/blueprint-reviewer-prompt-item.md.tmpl` (§11.2)
- `templates/blueprint-reviewer-prompt-enumerate.md.tmpl` (§11.3)

The sub-agent (or, for enumeration, the orchestrator) fills placeholders (`{{FILE_CONTENT}}`, `{{ITEM_CONTENT}}`, `{{ITERATION}}`, `{{ITEM_ID}}`, `{{FILE_PATH}}`) and submits the rendered prompt as the MCP tool's primary input.

### 7.4 Codex-specific assumptions (to verify before implementation)

- The plugin assumes Codex CLI is installed and its MCP subcommand is available on `$PATH`.
- The Codex MCP tool accepts a single text prompt argument and returns the model's text response.
- `/mi-doctor` is extended to verify these — see §10.5.

---

## 8. Loop algorithm — formal semantics

Single-loop pseudocode (shared by §6.1 and §6.2). `target` is either the file content (consistency sub-agent — written back to disk each iteration) or the item region (item sub-agent — held in memory and returned at exit):

```
function review_loop(target, max_iter):
    iteration = 0
    while True:
        iteration += 1
        # 8.1 — reviewer call
        prior_findings = parse_existing_review_findings(target)
        new_findings   = call_reviewer(target, iteration, prior_findings)

        # 8.2 — reconcile findings into target
        target = reconcile_findings(target, prior_findings, new_findings)
        # reconcile = drop comments whose finding is no longer reported,
        #             refresh comments whose finding persists (update iteration),
        #             append comments for new findings (tmp_id for item sub-agent;
        #             final F-NNN for consistency sub-agent, see §5.5)

        # 8.3 — completion check
        if count_severity(new_findings, "high") == 0 and \
           count_severity(new_findings, "medium") == 0:
            return ("success", target)        # encoded as Result: success

        # 8.4 — max-iter check (BEFORE fix step)
        if iteration >= max_iter:
            return ("max-iter", target)        # encoded as Result: partial + max-iter risk

        # 8.5 — fix step
        target = fixer_apply(target, new_findings)
        # fixer removes REVIEW-FINDING comments for findings it resolves
        # frontmatter must be unchanged after this step
```

### Iteration semantics

`max_iter = N` means **at most N reviewer calls**, with up to N−1 fix passes between them. The Nth call is the verifying review — if it has zero High/Medium, the loop exits success; otherwise max-iter.

### Re-run on `y`

If the loop returned `max-iter` and the inspector answers `y`, the caller re-invokes the loop with the **same `max_iter` budget** and the **current target state**. Findings from the prior loop that remain inline are read by the next loop's iteration 1 as `prior_findings` and either re-flagged or dropped per §5.3.

### Idempotence claim

Calling the reviewer with the same target content + same iteration + same prior_findings should produce the same JSON. The reviewer is a language model, so this is best-effort, not deterministic. The reconcile step is robust to minor wording changes in `finding` / `suggested-fix` between iterations.

---

## 9. File-mutation contract

The reviewed file is the **only** artifact written by this feature. Two write-ownership models coexist, scoped by what sub-agent is running:

| Sub-agent | Write ownership | Reason |
| --- | --- | --- |
| `blueprint-consistency-reviewer` (§6.1) | **Writes the file directly** at each iteration via `Write` (whole-file replacement). | Always serial — exactly one instance per file at a time. No race. |
| `blueprint-item-reviewer` (§6.2) | **Read-only on the reviewed file**; returns `{original_region, new_region}`; the calling command (orchestrator phase 3 or standalone) applies the replacement in main with `Edit` exact-match. | Phase 3 spawns up to `batch-size` instances in parallel against the same file. Direct writes would race. Read-only sub-agents + serialized writes in main eliminate the race by construction. |

Three rules implement the contract:

1. **No frontmatter mutations.** Both sub-agents are told (in their spawn prompt) that the file's YAML frontmatter (between the leading `---` fences) is off-limits. The consistency sub-agent revalidates frontmatter byte-for-byte after each iteration's write; the command revalidates after each region replacement applied in main. On mismatch: revert and retry the iteration / re-spawn the sub-agent.
2. **Disjoint regions enforced by exact-match `original_region`.** Phase 2 enumeration returns each item's `{start_offset, end_offset, original_region}` (see §5.4). The item sub-agent echoes `original_region` back in its return so the orchestrator's `Edit` succeeds only against the same bytes the sub-agent saw. If the exact match fails (a prior write has shifted offsets or rewritten neighbouring text), the orchestrator re-enumerates that item from the file's current state and re-spawns the affected sub-agent.
3. **Serialized write-back in main for parallel item review.** Even though item sub-agents run in parallel for the *review* part of phase 3, the orchestrator (running in main) processes their returns one at a time. Order: sort returns by `start_offset` ascending; apply each replacement; recompute offsets for remaining returns (each `start_offset` shifts by `len(new_region) − len(original_region)` of every prior applied return); apply the next one. Any return whose `original_region` no longer matches after recomputation triggers a re-enumeration + re-spawn for that item only.

---

## 10. Stage-2 integration

### 10.1 New flow in `mi-apply-impact`

Replace the current Step A → Step B → Step C flow with:

| Step | Owner | What |
| --- | --- | --- |
| A | unchanged | Generate `requirements.md` (with codebase-grounding sub-agent). |
| B | unchanged | Generate `config.md` (auto + manual sections, GIT BRANCH). |
| **B.5 (new)** | new | Auto-invoke `/mi-blueprint-review codex 3 5 <requirements.md path>`. |
| **B.6 (new)** | new | Drift surfacing — see §10.3. |
| C | unchanged in shape | Delegate diagram rendering to `blueprint-diagrammer` (now **after** review). |
| 3.1 | unchanged | Compute stage-3 effort suggestion. |
| 3.2 | unchanged | Hand off to inspector. |

### 10.2 Auto-invocation

`mi-apply-impact` calls the orchestrator with hardcoded defaults: `codex`, `max-consistency-iter=3`, `max-item-iter=5`. These can become user-config in a later iteration (see §13 D5).

If `/mi-doctor` reports the codex MCP server is not available, Step B.5 prints a warning and *skips* the review — the inspector sees the raw blueprint, same as today. Stage 2 is not blocked.

### 10.3 Drift surfacing (Step B.6)

After the review completes, compare the rewritten `requirements.md` (semantic content, ignoring `REVIEW-FINDING` comments) to:
- `quest/<active-slug>/summary.md` — specifically the `## Feature: <active-feature>` section and cross-cutting constraints.
- `quest/<active-slug>/todo-list.md` — the items still marked `PENDING` for the active feature.

For each diff hunk that meaningfully changes Goals/Planned/Non-goals, surface a heads-up:

> "The blueprint review rewrote `requirements.md`. Two changes may have drifted from `summary.md` and `todo-list.md`:
>
> 1. Goal **PAY-001** description changed from `<old>` to `<new>` — `summary.md` still has the old wording.
> 2. Goal **PAY-003** acceptance criteria were tightened — `todo-list.md` description is now slightly stale.
>
> Optional: edit `summary.md` and `todo-list.md` to match before typing `/mi-continue`. Or proceed — neither file blocks stage 3."

The millwright does **not** auto-edit either file. `summary.md` is millwright-territory but auto-editing without inspector consent feels surprising; `todo-list.md` is inspector-territory and never auto-editable.

### 10.4 Updated handoff message

The stage-2 handoff message in `mi-apply-impact` is updated to mention the review:

> "Blueprints generated for `<feature>` at `workflow-stream/<feature>/blueprints/current/`. The blueprint was auto-reviewed by `codex` and any remaining findings are inline as `<!-- REVIEW-FINDING -->` comments. Review `requirements.md`, `config.md`, and `diagrams/`. When ready, type **`/mi-continue`**."

### 10.5 `/mi-doctor` additions

Add a `mcp:codex` check to `scripts/doctor.sh`:
- Verify the `codex` CLI is installed and on `$PATH` (`command -v codex`).
- Verify `codex mcp-server --help` exits 0 — this confirms the stdio MCP entrypoint exists at the version installed locally without actually starting the long-running server.
- (Optional stretch) a 2-second stdio handshake probe that spawns `codex mcp-server`, sends an MCP `initialize` request, and kills the process — useful for catching auth/config breakage that `--help` would miss. Defer this to a follow-up if `--help` proves sufficient in practice.
- If the basic check fails, print a non-blocking warning: "codex MCP unavailable — stage-2 blueprint review will be skipped".

The check is **non-blocking** because the rest of the workflow is unaffected.

---

## 11. Reviewer prompt templates

Three templates, stored under `templates/` (one per reviewer call site — consistency review, per-item review, and the one-shot item-enumeration call from orchestrator phase 2).

### 11.1 Consistency prompt — `templates/blueprint-reviewer-prompt-consistency.md.tmpl`

```
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

### 11.2 Per-item prompt — `templates/blueprint-reviewer-prompt-item.md.tmpl`

```
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

### 11.3 Item enumeration prompt (one-shot, used by orchestrator phase 2)

```
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

After receiving the response, `scripts/blueprint-review.sh enumerate` produces the canonical descriptors (§5.4) by indexing each item's `anchor_line` + `occurrence_index` into a pre-scanned occurrence list and walking forward to the next item / heading boundary. Items whose `anchor_line` cannot be located at the named occurrence are dropped with a warning to the inspector — this is the script's signal that the reviewer hallucinated an item that isn't in the file (or miscounted occurrences).

---

## 12. Edge cases & risks

| Edge case | Behavior |
| --- | --- |
| Reviewer returns invalid JSON | Retry once with a clarifying suffix; on second failure, return `Result: blocked` with the raw reviewer output captured in the sub-agent's `Findings / risks`. The orchestrator surfaces this to the inspector instead of running the next phase. |
| Reviewer returns findings whose `target` is unknown | Treat as a `phase: consistency` finding (top-of-file). Log a warning. |
| Reviewer (Codex via MCP) returns content that looks like file edits | The reviewer has no file write access — it only returns JSON. The sub-agent parses the JSON and ignores any extra prose. If the JSON parse fails, treat as "invalid JSON" above. |
| Item sub-agent attempts to write the reviewed file | The sub-agent's `tools:` frontmatter declares **only** the reviewer MCP tool — no `Read`, `Write`, `Edit`, `Bash`, or `Grep` (§6.2). Any attempt to call a filesystem tool fails at the tool-availability check — the sub-agent has no shell, no editor, no read primitive of any kind. As an additional layer, the orchestrator validates each return's `original_region` echoes back the bytes the sub-agent received (§9), and the post-`Edit` frontmatter check verifies bytes match the pre-write value. Together: structural enforcement (no filesystem tools at all) + protocol enforcement (echo `original_region`) + post-condition enforcement (frontmatter byte-equality). |
| File has no items (e.g., a free-form spec) | Phase 2 returns an empty array. The orchestrator skips phase 3 entirely and runs only phase 1 + phase 4. The final report notes that no items were found. |
| File has > MAX_ITEMS_PER_REVIEW items | Orchestrator refuses; prints the message in §4.3 step 3. |
| Reviewer MCP server is unavailable | All three commands print an actionable error referencing `/mi-doctor`. In stage 2, the auto-invocation skips review with a warning (see §10.2). |
| Inspector answers something other than `y` / `n` at the max-iter prompt | Treat any non-`y` as `n` (conservative). |
| Sub-agent runs out of tool budget mid-iteration | Sub-agent returns `Result: partial` with `Findings / risks: - tool-budget-exhausted: ...` (distinguishable from a max-iter `partial` by the risk-line key). The orchestrator surfaces this and stops the phase. |
| Concurrent invocations on the same file | Out of scope — the inspector should not run two reviews on the same file at once. No locking. |
| `requirements.md` is regenerated by `/mi-update-blueprint` mid-cycle | Out of scope — `/mi-update-blueprint` does not auto-invoke the review. The inspector can run `/mi-blueprint-review` manually if they want a fresh review on a mid-cycle regenerated blueprint. |

### Risks

- **R1 — Reviewer cost.** A 20-item file with `max_consistency_iter=3`, `max_item_iter=5`, plus enumeration call, can run up to `3 + 1 + (20 × 5) + 3 = 107` reviewer calls in the worst case. The hard cap on items keeps this bounded; the y/n prompts give the inspector a kill switch.
- **R2 — Reviewer drift between iterations.** If the reviewer re-flags issues with substantially different wording each iteration, the reconciler may treat them as new findings and stack comments. Mitigation: the prompt explicitly tells the reviewer to keep finding wording stable across iterations when the underlying issue persists.
- **R3 — Fixer over-edits.** The fixer (Claude in the sub-agent) might rewrite parts of the file that aren't covered by any finding. Mitigation: the sub-agent's fix-step prompt is restricted to "edit only the spans referenced by findings"; the iteration is rejected if non-finding spans changed beyond whitespace.
- **R4 — Codex-specific MCP shape.** The exact MCP tool name and argument shape of Codex's MCP server is not yet verified — this is the largest unknown going into implementation. See §13 D2.
- **R5 — Inspector fatigue from prompts.** In a worst-case scenario (every item hits max-iter), the inspector sees 20+ y/n prompts in one stage. Mitigation: a future enhancement could add a `--yes-to-all` / `--no-to-all` flag once the feature is validated, but the v1 design exposes prompts per spec.

---

## 13. Open decisions

| ID | Decision | Notes |
| --- | --- | --- |
| D1 | Whether to support `--batch-size 0` (sequential, non-parallel) | Useful for debugging. Recommended: yes, easy to add. |
| D2 | Exact Codex MCP **tool name** (the entry that appears as `mcp__codex__<tool>`) | Resolved partially: the stdio entrypoint is `codex mcp-server` (not `codex mcp`). What's still open is the exact tool name Codex publishes inside the MCP server — verify after wiring `plugin.json` and reloading the plugin (`mcp__codex__codex` is the assumed name in this plan but should be confirmed before §6 sub-agents are written, since each agent's `tools:` frontmatter must list the tool by its real name). |
| D3 | Whether `MAX_ITEMS_PER_REVIEW` should be a plugin `userConfig` field | Currently a constant in `scripts/blueprint-review.sh`. If multiple teams use the plugin and have different spec sizes, promote to userConfig. |
| D4 | Whether stage-2 auto-invocation defaults (codex, 3, 5) should be plugin `userConfig` | Same reasoning as D3. Lean toward yes once the feature is validated. |
| D5 | Whether to also auto-run the review at `/mi-update-blueprint` regenerations | The mid-cycle blueprint refresh is a smaller, codebase-aware regen; running a second AI review may not add value. Recommended: opt-in flag (`/mi-update-blueprint --review`), not default. |
| D6 | Whether commands should validate that the reviewed file is well-formed markdown | The current design feeds the file to the reviewer verbatim. A pre-flight `markdownlint` check could catch obvious syntax issues before paying for reviewer calls. Low priority. |
| D7 | Whether to emit a structured `blueprint-review-result.json` next to the file at orchestrator exit | Useful for downstream tooling / CI. Out of scope for v1. |
| D8 | Whether `/mi-blueprint-review-item` mode B should rewrite `T<instance>-<n>` to `F-NNN` before printing terminal output | Cosmetic; tmp-ids in mode B have no continuity with anything else. Defer until inspector feedback suggests it matters. |

---

## 14. Files to add / modify

### New files

| Path | Purpose |
| --- | --- |
| `commands/mi-blueprint-review-consistency.md` | §4.1 |
| `commands/mi-blueprint-review-item.md` | §4.2 |
| `commands/mi-blueprint-review.md` | §4.3 |
| `agents/blueprint-consistency-reviewer.md` | §6.1 |
| `agents/blueprint-item-reviewer.md` | §6.2 |
| `scripts/blueprint-review.sh` | §7.2 + §5.4 — `resolve-tool`, `enumerate` (deterministic offsets from anchor lines), plus shared helpers (parse-existing-findings, reconcile, validate-frontmatter-unchanged, tmp-id-to-final-id rewrite) |
| `templates/blueprint-reviewer-prompt-consistency.md.tmpl` | §11.1 |
| `templates/blueprint-reviewer-prompt-item.md.tmpl` | §11.2 |
| `templates/blueprint-reviewer-prompt-enumerate.md.tmpl` | §11.3 |
| `docs/blueprints-review/plan.md` | This file. |

### Modified files

| Path | Change |
| --- | --- |
| `.claude-plugin/plugin.json` | Add `codex` to `mcpServers`. Bump version to `1.2.0`. |
| `commands/mi-apply-impact.md` | Insert Steps B.5 and B.6 (§10.1, §10.3); update handoff message (§10.4). |
| `docs/blueprint-regeneration.md` | Add a short section between Step B and Step C describing the new review stage. |
| `scripts/doctor.sh` | Add `mcp:codex` check (§10.5). |
| `CHANGELOG.md` | New entry under `## v1.2.0`. |
| `README.md` | Add a short section under "Commands" for the three new commands. |
| `docs/millwright-inspector-project.md` | Brief mention in §6.2 (Stage 2) and the roles-table (§5). |
| `docs/sub-agent-return-contract.md` | Add a "Payload JSON extension" section documenting the fenced-block extension introduced for `blueprint-item-reviewer` (see §6.2). General-purpose for any future sub-agent that needs a structured machine-readable payload. |
| `templates/sub-agent-return.md.tmpl` | Add an optional `Payload JSON:` block at the top of the template (commented out, with a one-line note: "use when the calling command needs a structured JSON payload — see contract doc"). |

### Schema considerations

No new schemas are required:
- The reviewed file's YAML frontmatter is not touched.
- `REVIEW-FINDING` comments are not validated by `hooks/validate-on-write.sh` because they live inside the body, not the frontmatter. If we later want validation, we'd add a body-pattern check to the hook — not in scope for v1.

---

## 15. Implementation order (suggested)

1. **Settle D2** — verify Codex MCP tool name + argument shape on a real installation.
2. **Add `codex` to `plugin.json`** — confirm `mcp__codex__*` tool appears after plugin reload.
3. **Write `scripts/blueprint-review.sh`** with `resolve-tool` first; then `enumerate` (the deterministic offset-computation from reviewer-supplied `anchor_line` values — §5.4); then per-finding helpers (parse-existing-findings, reconcile, validate-frontmatter-unchanged, tmp-id-to-final-id rewrite) as the sub-agents and orchestrator need them.
4. **Write `agents/blueprint-consistency-reviewer.md`** + **`templates/blueprint-reviewer-prompt-consistency.md.tmpl`**. Test standalone via a hand-invoked spawn on a sample file.
5. **Write `commands/mi-blueprint-review-consistency.md`**. Smoke-test on a real `requirements.md`.
6. **Write `agents/blueprint-item-reviewer.md`** + **`templates/blueprint-reviewer-prompt-item.md.tmpl`** + **enumeration template**. Test standalone.
7. **Write `commands/mi-blueprint-review-item.md`** (both modes). Smoke-test mode A and mode B.
8. **Write `commands/mi-blueprint-review.md`** (orchestrator). Smoke-test with a 12-item file (multiple batches).
9. **Modify `mi-apply-impact.md`** to auto-invoke the orchestrator. Test a real stage-2 run end-to-end.
10. **Modify `scripts/doctor.sh`** to add the `mcp:codex` check.
11. **Update docs** — `blueprint-regeneration.md`, `millwright-inspector-project.md`, `README.md`, `CHANGELOG.md`.
12. **Tests** — add a lint/bundle test that exercises the new commands' frontmatter and the new sub-agents' prompts.

Each numbered step is a candidate plan-step for the writing-plans skill when this design is approved.
