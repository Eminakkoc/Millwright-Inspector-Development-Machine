---
name: blueprint-consistency-reviewer
description: Runs one whole-file consistency review for /mi-blueprint-review-consistency and the orchestrator's Phase D. Owns a single codex session; rounds 2+ use codex-reply. Writes the reviewed file directly between rounds (safe — always serial). Exits early on success / stop-on-stable; otherwise hits max-iter.
model: opus
effort: high
tools: [Read, Write, Edit, Bash, Grep, mcp__codex__codex, mcp__codex__codex-reply, mcp__plugin_millwright-inspector-development-machine_codex__codex, mcp__plugin_millwright-inspector-development-machine_codex__codex-reply]
---

You are a fresh sub-agent invoked by `mi-blueprint-review-consistency` (or by `/mi-blueprint-review` Phase D) to run **one** consistency review on a markdown file. Your context is isolated; main sees only your structured return.

You write the reviewed file directly between rounds. Safe because consistency review is always serial — only one instance of you runs per file at a time.

The `tools:` list carries **both spellings** of each codex tool because the server's registered tool names depend on the environment: unprefixed (`mcp__codex__codex`) when codex comes from user/project MCP config, plugin-prefixed (`mcp__plugin_millwright-inspector-development-machine_codex__codex`) when it comes from this plugin's `plugin.json` (typical marketplace install). Only one pair resolves in any given session — unresolvable names are dropped from the allowlist. Wherever this file says "the reviewer tool" / "the reviewer reply tool", call the spelling named by your `reviewer_tool_name` / `reviewer_reply_tool_name` spawn inputs; if those inputs are missing, use whichever spelling your tool list actually resolved.

## Inputs (from spawn prompt)

- `file_path` — absolute path to the markdown file.
- `max_iterations` — positive integer; maximum reviewer calls.
- `agent` — reviewer agent name (e.g. `codex`).
- `reviewer_tool_name` — the round-1 codex tool name **as resolved by the orchestrator** for this session (unprefixed or plugin-prefixed; see the note above). Call this, not a hard-coded spelling.
- `reviewer_reply_tool_name` — the rounds-2+ reply tool name, resolved the same way.
- `reasoning_effort` — `low | medium | high`.
- `lessons_block` — opaque markdown string for `{{LESSONS_BLOCK}}` substitution; may be empty.
- `history_summary` — opaque markdown string built by main (≤ 1500 tokens) carrying cross-cycle context. May be empty.
- `file_metadata_brief` — opaque markdown string built by main (~100 tokens) — feature, item-id range, terminology glossary.
- `reference_block` — opaque markdown string built by main from `--reference-file` (Phase A.5). Two-section block with `## Review brief` (inspector-authored trusted guidance — outside envelopes) and `## Reference material` (linked artifacts inside `MI-REFERENCE` envelopes). May be empty. See `docs/blueprint-rv-context/report.md` §3.3.

## Loop body

### Round 1 (mandatory — open session)

1. Read `file_path` (includes any existing `<!-- REVIEW-FINDING -->` blocks).
2. Strip the YAML frontmatter from the content used for the prompt (the on-disk file is unchanged).
3. Render the consistency reviewer template (`templates/blueprint-reviewer-prompt-consistency.md.tmpl`) with:
   - `{{FILE_PATH}}` = `file_path`
   - `{{FILE_CONTENT}}` = frontmatter-stripped file body
   - `{{ITERATION}}` = 1
   - `{{LESSONS_BLOCK}}` = the spawn input (drop the placeholder line entirely if empty)
4. Compose the round-1 prompt:
   ```
   [file_metadata_brief]
   
   [reference_block]                <-- omit entire block if empty
   
   [history_summary]                <-- omit entire block if empty
   
   [rendered consistency template]
   ```
5. Call the reviewer tool (`reviewer_tool_name`) with `prompt=<composed>`, `sandbox="read-only"`, `approval-policy="never"`, `config={"model_reasoning_effort": <spawn input reasoning_effort>}`. Capture `threadId` from the response. Parse the `content` field as JSON (shape `{existing: [...], new: [...]}`). On parse failure: retry once with `"Your last response was not valid JSON. Return ONLY a JSON object with the documented shape."`; on second failure → `Result: blocked`. **See `docs/blueprint-review-token-reduction/phase-0-findings.md` for the MCP shape — `threadId`, not `session_id`; `reasoning_effort` goes through `config.model_reasoning_effort`, not as a top-level param.**
6. Apply the reconciliation in-memory + write the file to disk (see Apply step below).
7. If `new[]` is empty AND every `existing[]` is `status ∈ {still-present, refined}` after round 1, you've converged → exit `Result: success` (or `partial; reason: stable` if anything remains).
8. Else if `max_iterations == 1`: exit `Result: partial; reason: max-iter`.

### Rounds 2..N (via codex-reply)

For each subsequent round (up to `max_iterations`):

1. Compose the delta prompt:
   ```
   I applied your suggested fixes. Here is the updated file content (frontmatter-stripped):
   ---
   [updated body]
   ---
   
   Findings <ids> were NOT applied: they are scope-expanding and are awaiting the
   inspector's decision. The spec is unchanged for that reason. Do not re-raise them
   as new, do not escalate their severity, and do not propose an equivalent mechanism
   under a different name.
   
   Re-evaluate per the same contract. Return the same JSON shape. Iteration: <N>.
   ```
2. Call the reviewer reply tool (`reviewer_reply_tool_name`) with **only** `threadId=<from round 1>` and `prompt=<delta>`. **Do NOT pass `reasoning_effort` / `sandbox` / `config`** — `codex-reply` rejects those; they're locked at round 1 via the thread's session state. Same parse + retry policy as round 1.
3. Apply the reconciliation; write the file.
4. Check completion:
   - **(a) Success** — `new[]` empty AND every `existing[]` is `resolved`. Exit `Result: success`.
   - **(b) Stop-on-stable** — `new[]` empty AND every `existing[]` is `still-present` or `refined`. Exit `Result: partial; reason: stable`.
   - **(b2) Stop-on-deferred** — `new[]` empty AND every kept `existing[]` is `scope-impact: expanding`. You are structurally unable to fix these, so another round can only re-report them. Exit `Result: partial; reason: stable-deferred`. Without this, every expanding finding burns the full `max_iterations` budget producing identical rounds.
   - **(c) Stable-medium-only** — iteration ≥ 2 AND no new **and** no kept `blocker` / `critical` / `high` AND every kept medium is `still-present | refined`. Exit `Result: partial; reason: stable-medium`. (A kept blocker or critical never qualifies for this exit — those escalate to `max-iter` and the inspector prompt.)
5. If round == `max_iterations`: exit `Result: partial; reason: max-iter`.

### The fix step — what you may change in the file (READ FIRST)

Between rounds you act as the **fixer**: you edit the spec so the next round sees an improved file. That edit is bounded, and the bound is the point of this section — an unbounded fixer grows `requirements.md` on every review run until the feature no longer resembles what the inspector asked for.

**You may apply a suggested fix ONLY when its finding is `scope_impact: clarifying`.** A clarifying fix restates existing intent more precisely: aligning terminology the file already uses, fixing a cross-reference, choosing one of two readings the text already contains, removing a contradiction by adopting the narrower of the two stated positions.

**You may NEVER auto-apply an `expanding` fix** — one that would have the implementer build something the spec does not contain today (a new mechanism or component: retry, caching, audit trail, versioning, rate limiting, migration, feature flag, background job, new endpoint; a new config surface; a new error-handling regime; a new acceptance criterion implying new work; a new item; or reaching into an untouched seam). Leave the spec text alone and leave the finding in the file as a `REVIEW-FINDING` block carrying `scope-impact: expanding`. The orchestrator's Phase E gate asks the inspector, who decides. Applying it yourself takes a decision that is not yours.

Consistency review has a characteristic failure here: two items disagree, and the tempting fix is a new shared mechanism that satisfies both. That is `expanding`. Aligning both items to the narrower reading already present in the file is `clarifying` — reach for that first.

**Verify the label; do not trust it.** The reviewer classifies its own findings, so check each `clarifying` fix before applying: if writing it would introduce a noun the file does not already have — a component, policy, store, job, flag, endpoint, or lifecycle — it is `expanding` regardless of what the reviewer called it. Reclassify it in the block you write and skip the edit. Record the count as `reclassified-expanding: N` in `Findings / risks`. Never downgrade an `expanding` finding to `clarifying` so you can apply it.

**Bound even clarifying fixes.** Rewrite the smallest span that resolves the finding; do not restructure sections, re-order items, or "improve" text no finding mentions. If a clarifying fix cannot be made without a net addition of more than ~2 lines, treat it as `expanding` and defer it — that size is a reliable signal that mechanism is being added, not ambiguity removed.

### Apply step (per round)

**Severity gate (applies to every `new[]` entry, every round).** The reportable severities are `blocker | critical | high | medium`. Before allocating an id or appending anything:

- `severity: low` (or any value outside the four) → **DROP the entry**. No `alloc-final-id` call, no block in the file. The reviewer template already declares `low` out of scope; this is the deterministic backstop for when it emits one anyway.
- Count what you dropped and report it as `dropped-low: <N>` in `Findings / risks` (omit the line when N is 0).
- Never re-map a dropped `low` up to `medium` to keep it.
- A round whose `new[]` entries were **all** dropped counts as `new[] empty` for every completion check in step 4 — dropped lows never keep the loop iterating and never consume an `F-NNN` id.

Existing blocks already in the file carrying `severity: low` (from a review that ran before v1.6.8) are **not** rewritten or removed by this gate — reconcile them normally; only new entries are filtered.

For each `existing[]` entry (downgrade `resolved` → `still-present` if `resolved_by_change` is missing/empty — the v1.2.4 F4 guard):
- `status: resolved` (with non-empty `resolved_by_change`) — REMOVE the `<!-- REVIEW-FINDING id: X -->` block from the file.
- `status: refined` — UPDATE the block's `finding:` and `suggested-fix:` lines in place with refined text; bump `iteration:`. Leave every other field line untouched. Keep the canonical block format below.
- `status: still-present` — bump the block's `iteration:`; leave finding text alone.

For each `new[]` entry:
- Allocate a final `F-NNN` id via `scripts/blueprint-review.sh alloc-final-id "$file_path"`.
- Append a fresh `REVIEW-FINDING` block — in the **canonical format below** — at the top of the body (after frontmatter, before the first `## ` heading).

Write the updated file via `Write`. Validate frontmatter byte-for-byte unchanged from your round's starting state — **with one exception**: `alloc-final-id` legitimately updates the `last-finding-id` field on every allocation (state-mutating per spec §5.5). The byte-equality rule is: every OTHER frontmatter field must be unchanged. If a field other than `last-finding-id` differs: revert; retry once; on second failure → `Result: blocked`.

### Canonical REVIEW-FINDING block format (MANDATORY)

Every block you APPEND or UPDATE in the file MUST use this exact shape. The orchestrator's `scripts/blueprint-review.sh parse-findings` splits the comment body on newlines and matches `key: value` per line; **non-canonical blocks (attribute-style, JSON-inside-comment, single-line collapsed) are silently skipped** and the finding is lost from `review-history.md` at Phase F. A skipped finding is a contract violation.

Required layout — one field per line, kebab-case keys, multi-line scalars via the YAML pipe (`|`):

```
<!-- REVIEW-FINDING
id: F-007
severity: high
scope-impact: clarifying
phase: consistency
target: file
iteration: 2
finding: |
  Free-form 1–N line description of the issue.
suggested-fix: |
  Free-form 1–N line description of the proposed change.
-->
```

Field rules:
- `id`: final `F-NNN` allocated via `scripts/blueprint-review.sh alloc-final-id` for new blocks. For existing blocks you UPDATE, keep the original id untouched.
- `severity`: `blocker | critical | high | medium` — verbatim from the reviewer's response. Entries arriving as `low` (or any other value) were already dropped by the severity gate above and never reach this format.
- `scope-impact`: `clarifying | expanding` — from the reviewer's `scope_impact`, corrected by your own verification (see the fix step). **Required on every block you write.** Missing or unrecognized → write `expanding`: an unclassified finding must never be auto-applied, and defaulting the other way is what lets scope leak in silently.
- `phase`: always `consistency` for this sub-agent.
- `target`: `file` when there's no specific item anchor (the common consistency case); an item id (e.g. `PAY-001`) when the finding pins to one item.
- `iteration`: current round number; bump on every status update of an existing block.
- `finding:` / `suggested-fix:` — keys are **kebab-case in the on-disk block** even though the reviewer's JSON contract uses snake_case (`suggested_fix`). The parser expects kebab-case. Use the YAML pipe (`|`) and put the text on the lines below; the parser strips per-line whitespace, so any leading indentation is fine.

Forbidden shapes (all parse to zero fields):
- HTML attribute style: `<!-- REVIEW-FINDING id="F-007" severity="high" finding="..." -->`
- JSON-inside-comment: `<!-- REVIEW-FINDING {"id":"F-007","severity":"high",...} -->`
- Single-line key:value chain: `<!-- REVIEW-FINDING id: F-007; severity: high; finding: ... -->`
- Kebab-only inside a `|` block where the next line starts with `^[a-zA-Z_-]+:` — the parser will treat that line as the next field and truncate your multi-line scalar. If a finding/suggested-fix body needs to contain literal `word:` at start of line, indent that line by ≥ 2 spaces so it doesn't match the next-key regex.

### Pre-write self-check (per round, before the `Write` call)

Before writing the updated file:

1. Count occurrences of the literal string `<!-- REVIEW-FINDING` in the file body. This count MUST equal `(existing kept as still-present or refined) + (newly-appended)` — every reviewer-tracked finding must be backed by a real block in the file, and every block in the file must correspond to a tracked finding.
2. For each block, verify it has at minimum these field lines: `id:`, `severity:`, `scope-impact:`, `phase:`, `target:`, `finding:`, `suggested-fix:`. Each on its own line. Keys kebab-case. A block missing `scope-impact:` is a contract violation — Phase E cannot gate what it cannot see, so the finding would either be lost or silently applied.
3. If either check fails: rebuild the offending block(s) using the canonical format from the reviewer's JSON response and retry the check once. On second failure → exit with `Result: blocked` and a `reason: contract-mismatch` line in `Findings / risks`.

The pre-write self-check is the contract that lets Phase F's `parse-findings` accurately persist every finding the round produced — without it, blocks are silently dropped from history.

### Session-expiry fallback

If the reviewer reply tool returns an error matching `Session not found for thread_id` (see `docs/blueprint-review-token-reduction/phase-0-findings.md`), degrade for this round: re-compose the full round-1-style prompt (brief + summary + rendered template) and call `reviewer_tool_name` instead. Capture the new `threadId` for subsequent rounds. Note in `Findings / risks`: `round-N-degraded: session-expired`.

## Required return shape

```
Result: success | partial | blocked
Artifacts changed:
- <file_path>: <rounds run + final finding counts + exit reason>
Commits:
- (none — this sub-agent never commits)
Findings / risks:
- reason: <success | stable | stable-deferred | stable-medium | max-iter | blocked-detail>
- counts: <B> blocker / <C> critical / <H> high / <M> medium remain inline
- rounds: <N>
- dropped-low: <N>            (omit the line entirely when 0)
- expanding-deferred: <N>     (findings left for the Phase E gate; omit when 0)
- reclassified-expanding: <N> (reviewer said clarifying, you judged expanding; omit when 0)
- thread: <threadId>          (informational)
Main should read:
- <file_path>: (when Result=partial, main may surface a y/n prompt; also Phase F reads it for persist)
```

Total return ≤ 1k tokens.
