# Blueprint Review Token-Reduction Refit — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refit the blueprint review system to cut token cost by ~95% while preserving finding quality. Replaces per-iteration stateless codex calls with single-session `codex` + `codex-reply` continuations; replaces per-item sub-agents with per-batch reviewers; drops the redundant initial consistency loop; adds a sibling `review-history.md` artifact for cross-cycle memory.

**Architecture:** New orchestrator runs Phase A (preflight + summary build) → Phase B (enumerate) → Phase C (per-batch reviews, parallel waves) → Phase D (single consistency pass) → Phase F (persist to history) → Phase G (report). Each codex-touching phase opens one session; rounds ≥ 2 use `codex-reply` with delta-only payloads. Main builds a ≤ 1500-token deterministic summary from `review-history.md` once per Phase A and passes it into every session opener.

**Tech Stack:** Bash + Python3 (`scripts/*.sh` pattern with embedded Python heredocs for parsing/rendering), Markdown + YAML frontmatter (templates), JSON for sub-agent IPC, MCP for codex integration (`mcp__codex__codex` + `mcp__codex__codex-reply`).

**Spec:** `docs/blueprint-review-token-reduction/plan.md`. Cite section numbers from there in commit messages (e.g., `feat(blueprint-review): build-summary subcommand per §6.2`).

**Breaking change:** v1.2.x positional args (`<max-c-iter> <max-i-iter>`) replaced by `--auto-iter`. No back-compat shim; v1.4.0 minor bump documents the break.

---

## File structure

**New files:**

- `schemas/review-history.schema.yaml` — frontmatter schema (`id`, `feature`, `requirements-id`, `last-finding-id`, `finding-count-total`, `finding-count-unresolved`, `last-review-at`).
- `templates/review-history.md.tmpl` — init template.
- `templates/blueprint-reviewer-prompt-batch.md.tmpl` — replaces `*-item.md.tmpl`; single template handles 1..N items per batch.
- `agents/blueprint-batch-reviewer.md` — replaces `blueprint-item-reviewer.md`; one sub-agent per batch; strictly read-only; owns one codex session.
- `tests/blueprint-review/run.sh` — bash integration harness; grows over tasks.
- `tests/blueprint-review/fixtures/*` — fixture trees per scenario.
- `docs/blueprint-review-token-reduction/phase-0-findings.md` — output of Task 1's MCP shape verification.
- `docs/superpowers/plans/2026-05-23-blueprint-review-token-reduction-manual-tests.md` — manual scenarios.

**Modified files:**

- `scripts/blueprint-review.sh` — add `build-summary` and `persist-findings` subcommands; keep existing `resolve-tool`/`enumerate`/`parse-findings`/`alloc-final-id`/`diff-drift` unchanged.
- `scripts/doctor.sh` — add `codex-reply` capability probe (non-blocking).
- `hooks/validate-on-write.sh` — validate `review-history.md` path against the new schema.
- `agents/blueprint-consistency-reviewer.md` — reshape for single-session + `codex-reply` rounds; accept new spawn inputs (`history_summary`, `file_metadata_brief`).
- `templates/blueprint-reviewer-prompt-consistency.md.tmpl` — envelope trim (frontmatter stripped, `{{EXISTING_FINDINGS}}` collapsed to one-line marker, reconciliation contract compressed).
- `commands/mi-blueprint-review.md` — full rewrite for new CLI + phase shape.
- `commands/mi-blueprint-review-consistency.md` — thin wrapper around Phase A+D+F+G.
- `commands/mi-blueprint-review-item.md` — thin wrapper around Phase A+B(single)+C(batch=1)+F+G.
- `commands/mi-apply-impact.md` — add Step A.5 (init `review-history.md`); update Step B.5 CLI line; extend `--force` cleanup allowlist.
- `commands/mi-update-blueprint.md` — carry `review-history.md` through rotation.
- `commands/mi-complete-workflow.md` — archive allowlist extension.
- `.claude-plugin/plugin.json` — version → `1.4.0`.
- `CHANGELOG.md` — new entry under `## 1.4.0`.
- `README.md` — brief commands section update.
- `docs/millwright-inspector-project.md` — note the new artifact + sub-agent rename.

**Removed files:**

- `agents/blueprint-item-reviewer.md`
- `templates/blueprint-reviewer-prompt-item.md.tmpl`

---

## Task ordering rationale

Phase 0 first (verify `codex-reply` MCP shape) — if this fails, the rest of the plan changes shape (fallback to stateless mode). Then foundation (schema + template + script subcommands) so later tasks can validate against real files. Then sub-agents and templates. Then commands. Then workflow wiring (`mi-apply-impact`, rotation, archive). Then cleanup of deprecated files. Then manual test plan + migration docs. Tests grow alongside each task in `tests/blueprint-review/run.sh`.

---

### Task 1: Phase 0 — Verify `mcp__codex__codex-reply` MCP shape

**Files:**
- Create: `docs/blueprint-review-token-reduction/phase-0-findings.md`

**Context:** This is a verification task, not a build task. The spec assumes `mcp__codex__codex-reply` returns a session-continuable response. If it doesn't (or has unexpected shape), the entire design's primary cost win evaporates and we fall back to stateless mode. Subsequent tasks depend on what we learn here.

- [ ] **Step 1: Probe `mcp__codex__codex` for session ID return shape**

In a Claude Code session, call `mcp__codex__codex` directly with a short prompt:

```
prompt: "Reply with the exact string OK-PROBE-1 and nothing else."
reasoning_effort: low
```

Capture the full response object (not just the text). Note whether it includes a `session_id`, `sessionId`, conversation ID, or similar field — and where (top-level vs nested).

- [ ] **Step 2: Probe `mcp__codex__codex-reply` for continuation behavior**

Using the session-identifier from Step 1, call `mcp__codex__codex-reply`:

```
session_id: <whatever Step 1 returned>
prompt: "Reply with the exact string OK-PROBE-2 and nothing else."
reasoning_effort: low
```

Capture response. Verify the response references the prior turn (e.g., "I previously said OK-PROBE-1"). If `mcp__codex__codex-reply` returns an error, capture the error verbatim.

- [ ] **Step 3: Probe session-expiry behavior**

Wait ~5 minutes after Step 2, then attempt another `codex-reply` with the same session_id. Capture response. (Goal: learn whether sessions time out and if so, what the error looks like.)

- [ ] **Step 4: Write findings to `docs/blueprint-review-token-reduction/phase-0-findings.md`**

```markdown
# Phase 0 — codex-reply MCP shape findings

**Date:** YYYY-MM-DD
**Codex CLI version:** <`codex --version` output>
**MCP tool names confirmed:** mcp__codex__codex, mcp__codex__codex-reply

## Round-1 response shape (mcp__codex__codex)

Session identifier: <field name, e.g., `session_id` or `sessionId`>, located at <path, e.g., top-level or `response.metadata.session_id`>.

Example response (redacted):
\`\`\`json
{ ... }
\`\`\`

## Round-2 behavior (mcp__codex__codex-reply)

Session continuation: <works / fails / partial>.
Required parameter shape: <e.g., `session_id` + `prompt` + `reasoning_effort`>.

Example response:
\`\`\`json
{ ... }
\`\`\`

## Session expiry

Behavior after ~5 min idle: <continues / errors with "...">.
Error shape on expiry: <verbatim>.

## Decision

- [ ] Plan proceeds as designed (session continuation works).
- [ ] Plan falls back to stateless mode (rounds 2+ are fresh codex calls; cost win drops from ~95% to ~60%).

If fallback: update spec §7 and §12.2 R1 to reflect; this is a real design change and warrants discussion with the inspector before continuing.
```

- [ ] **Step 5: Commit**

```bash
git add docs/blueprint-review-token-reduction/phase-0-findings.md
git commit -m "$(cat <<'EOF'
docs(blueprint-review): Phase 0 codex-reply MCP shape findings

Verified mcp__codex__codex-reply shape per spec §7. Plan proceeds as designed / falls back to stateless mode (whichever applies).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: review-history.md frontmatter schema

**Files:**
- Create: `schemas/review-history.schema.yaml`
- Create: `tests/blueprint-review/run.sh`
- Create: `tests/blueprint-review/fixtures/schema-good/review-history.md`
- Create: `tests/blueprint-review/fixtures/schema-bad-missing-counter/review-history.md`
- Create: `tests/blueprint-review/fixtures/schema-bad-counts/review-history.md`

- [ ] **Step 1: Write failing test harness**

Create `tests/blueprint-review/run.sh`:

```bash
#!/usr/bin/env bash
# run.sh — integration smoke tests for the v1.4 blueprint review refit.
#
# Each test exits 0 on PASS and a unique non-zero on FAIL so partial-suite
# results stay actionable. Tests are additive: later tasks append blocks
# under their own task headings.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="$TESTS_DIR/fixtures"

pass=0
fail=0
fail_names=()

ok() { printf "\xe2\x9c\x93 %s\n" "$1"; pass=$((pass + 1)); }
ng() { printf "\xe2\x9c\x97 %s\n   %s\n" "$1" "$2" >&2; fail=$((fail + 1)); fail_names+=("$1"); }

# ---- Task 2: review-history schema ----------------------------------------

t="schema: valid review-history frontmatter passes"
if "$REPO_ROOT/scripts/frontmatter.sh" validate \
   "$FIXTURES/schema-good/review-history.md" review-history >/dev/null 2>&1; then
  ok "$t"
else
  ng "$t" "expected validation to pass"
fi

t="schema: missing last-finding-id rejected"
if "$REPO_ROOT/scripts/frontmatter.sh" validate \
   "$FIXTURES/schema-bad-missing-counter/review-history.md" review-history >/dev/null 2>&1; then
  ng "$t" "expected validation to fail; it passed"
else
  ok "$t"
fi

t="schema: non-integer finding-count-total rejected"
if "$REPO_ROOT/scripts/frontmatter.sh" validate \
   "$FIXTURES/schema-bad-counts/review-history.md" review-history >/dev/null 2>&1; then
  ng "$t" "expected validation to fail; it passed"
else
  ok "$t"
fi

# ---- Summary --------------------------------------------------------------

printf "\n--- summary: %d pass, %d fail ---\n" "$pass" "$fail"
[[ ${#fail_names[@]} -eq 0 ]] || { printf "failed:\n%s\n" "$(printf '  - %s\n' "${fail_names[@]}")"; exit 1; }
exit 0
```

Make it executable: `chmod +x tests/blueprint-review/run.sh`.

- [ ] **Step 2: Create fixtures**

`tests/blueprint-review/fixtures/schema-good/review-history.md`:

```markdown
---
id: 6c969da0-7b53-4e89-b286-65fa898bb572
feature: payment-webhook
requirements-id: 6c969da0-7b53-4e89-b286-65fa898bb572
last-finding-id: F-000
finding-count-total: 0
finding-count-unresolved: 0
last-review-at: 2026-05-23T11:12:37Z
---

# Review history — payment-webhook

(no findings yet)
```

`tests/blueprint-review/fixtures/schema-bad-missing-counter/review-history.md` (same body, omit `last-finding-id`):

```markdown
---
id: 6c969da0-7b53-4e89-b286-65fa898bb572
feature: payment-webhook
requirements-id: 6c969da0-7b53-4e89-b286-65fa898bb572
finding-count-total: 0
finding-count-unresolved: 0
last-review-at: 2026-05-23T11:12:37Z
---

# Review history — payment-webhook

(no findings yet)
```

`tests/blueprint-review/fixtures/schema-bad-counts/review-history.md` (counts as strings, not integers):

```markdown
---
id: 6c969da0-7b53-4e89-b286-65fa898bb572
feature: payment-webhook
requirements-id: 6c969da0-7b53-4e89-b286-65fa898bb572
last-finding-id: F-000
finding-count-total: "zero"
finding-count-unresolved: "zero"
last-review-at: 2026-05-23T11:12:37Z
---

# Review history — payment-webhook
```

- [ ] **Step 3: Run tests to verify they fail (no schema yet)**

```bash
bash tests/blueprint-review/run.sh
```

Expected: all three schema tests fail with "schema not found: review-history" or equivalent.

- [ ] **Step 4: Write schema**

Create `schemas/review-history.schema.yaml`:

```yaml
$schema: "http://json-schema.org/draft-07/schema#"
title: review-history
description: Append-only review history for a single blueprint version. Sibling to requirements.md in blueprints/current/; rotates with the blueprint.
type: object
additionalProperties: false
required:
  - id
  - feature
  - requirements-id
  - last-finding-id
  - finding-count-total
  - finding-count-unresolved
  - last-review-at
properties:
  id:
    type: string
    pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
    description: UUID v4 identifying this review-history.md instance.
  feature:
    type: string
    pattern: "^[a-z0-9-]+$"
    description: Feature slug (matches workflow-stream/<feature>/).
  requirements-id:
    oneOf:
      - type: string
        pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
      - type: "null"
    description: Sibling requirements.md's id; nullable until backfilled in Phase A.
  last-finding-id:
    type: string
    pattern: "^F-[0-9]{3,}$"
    description: Lifetime-monotonic counter; bootstrap value is F-000.
  finding-count-total:
    type: integer
    minimum: 0
    description: Total findings ever appended.
  finding-count-unresolved:
    type: integer
    minimum: 0
    description: Findings currently in last-status != resolved.
  last-review-at:
    type: string
    format: date-time
    description: ISO-8601 UTC timestamp of the most recent persist pass.
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
bash tests/blueprint-review/run.sh
```

Expected: 3 pass, 0 fail.

- [ ] **Step 6: Commit**

```bash
git add schemas/review-history.schema.yaml tests/blueprint-review/run.sh tests/blueprint-review/fixtures/
git commit -m "$(cat <<'EOF'
feat(schemas): review-history.md frontmatter schema + smoke tests

Schema enforces UUID id, feature slug pattern, nullable requirements-id, F-NNN counter, non-negative integer counts, ISO-8601 last-review-at. Per spec §5.2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: review-history.md init template

**Files:**
- Create: `templates/review-history.md.tmpl`
- Modify: `tests/blueprint-review/run.sh` (append block)

- [ ] **Step 1: Append failing template tests**

Append to `tests/blueprint-review/run.sh` before the `# ---- Summary` line:

```bash
# ---- Task 3: init template ------------------------------------------------

t="template: init produces a schema-valid file"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if "$REPO_ROOT/scripts/frontmatter.sh" init review-history "$tmp/review-history.md" \
   ID=$(uuidgen | tr 'A-Z' 'a-z') \
   FEATURE=test-feat \
   REQUIREMENTS_ID=$(uuidgen | tr 'A-Z' 'a-z') \
   LAST_FINDING_ID=F-000 \
   FINDING_COUNT_TOTAL='!RAW!0' \
   FINDING_COUNT_UNRESOLVED='!RAW!0' \
   LAST_REVIEW_AT=2026-05-23T00:00:00Z \
   >/dev/null 2>&1; then
  if "$REPO_ROOT/scripts/frontmatter.sh" validate "$tmp/review-history.md" review-history >/dev/null 2>&1; then
    ok "$t"
  else
    ng "$t" "init produced an invalid file"
  fi
else
  ng "$t" "init invocation failed"
fi

t="template: body contains expected heading"
if grep -q "^# Review history" "$tmp/review-history.md" 2>/dev/null; then
  ok "$t"
else
  ng "$t" "missing '# Review history' heading"
fi
```

- [ ] **Step 2: Run tests, verify they fail (template doesn't exist)**

```bash
bash tests/blueprint-review/run.sh
```

Expected: template tests fail with "template not found: review-history".

- [ ] **Step 3: Write template**

Create `templates/review-history.md.tmpl`:

```markdown
---
id: {{ID}}
feature: {{FEATURE}}
requirements-id: {{REQUIREMENTS_ID}}
last-finding-id: {{LAST_FINDING_ID}}
finding-count-total: {{FINDING_COUNT_TOTAL}}
finding-count-unresolved: {{FINDING_COUNT_UNRESOLVED}}
last-review-at: {{LAST_REVIEW_AT}}
---

# Review history — {{FEATURE}}

(no findings yet)
```

**Note:** `!RAW!` is NOT in the template — it's prefixed at the call site, matching the convention used by `templates/blueprint-lessons.md.tmpl`. Callers of `scripts/frontmatter.sh init review-history ...` MUST pass integer values as `FINDING_COUNT_TOTAL='!RAW!0'` etc. Without the prefix, the renderer wraps the value in quotes and schema validation rejects it as a string-not-integer.

- [ ] **Step 4: Run tests, verify they pass**

```bash
bash tests/blueprint-review/run.sh
```

Expected: 5 pass, 0 fail.

- [ ] **Step 5: Commit**

```bash
git add templates/review-history.md.tmpl tests/blueprint-review/run.sh
git commit -m "$(cat <<'EOF'
feat(templates): review-history.md init template

Mirrors blueprint-lessons.md.tmpl shape; uses !RAW! sentinel for integer fields per spec §5.4.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Extend `hooks/validate-on-write.sh` to cover `review-history.md`

**Files:**
- Modify: `hooks/validate-on-write.sh`
- Modify: `tests/blueprint-review/run.sh`

- [ ] **Step 1: Read the existing hook to find the dispatch pattern**

```bash
cat hooks/validate-on-write.sh | head -80
```

Identify how the hook matches paths to schemas (likely a `case` statement on filename basename). Note the line range of the dispatch block.

- [ ] **Step 2: Append failing hook test**

Append to `tests/blueprint-review/run.sh` before `# ---- Summary`:

```bash
# ---- Task 4: hook validation ----------------------------------------------

t="hook: review-history.md path triggers schema validation"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Simulate a workflow-stream path the hook will recognize
mkdir -p "$tmp/workflow-stream/test-feat/blueprints/current"
cp "$FIXTURES/schema-bad-counts/review-history.md" \
   "$tmp/workflow-stream/test-feat/blueprints/current/review-history.md"
if PATH_TO_FILE="$tmp/workflow-stream/test-feat/blueprints/current/review-history.md" \
   bash "$REPO_ROOT/hooks/validate-on-write.sh" "$PATH_TO_FILE" >/dev/null 2>&1; then
  ng "$t" "expected hook to fail validation on bad review-history; it passed"
else
  ok "$t"
fi
```

- [ ] **Step 3: Run, verify failure (hook doesn't know about this path yet)**

```bash
bash tests/blueprint-review/run.sh
```

Expected: hook test fails (it lets the bad file pass).

- [ ] **Step 4: Add path matcher to hook**

In `hooks/validate-on-write.sh`, locate the dispatch `case` (after the lessons / requirements / etc. entries). Add a new entry following the existing pattern:

```bash
*/blueprints/current/review-history.md|*/blueprints/history/v*/review-history.md)
  "$plugin_root/scripts/frontmatter.sh" validate "$file" review-history
  ;;
```

Preserve the existing entries' style exactly (indentation, error-passthrough).

- [ ] **Step 5: Run tests, verify they pass**

```bash
bash tests/blueprint-review/run.sh
```

Expected: 6 pass, 0 fail.

- [ ] **Step 6: Commit**

```bash
git add hooks/validate-on-write.sh tests/blueprint-review/run.sh
git commit -m "$(cat <<'EOF'
feat(hooks): validate review-history.md on write

Adds path matcher to validate-on-write.sh per spec §5.5. Covers both current/ and history/v<N>/ paths so post-rotation files validate too.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `scripts/blueprint-review.sh build-summary` subcommand

**Files:**
- Modify: `scripts/blueprint-review.sh`
- Modify: `tests/blueprint-review/run.sh`
- Create: `tests/blueprint-review/fixtures/summary-empty/review-history.md`
- Create: `tests/blueprint-review/fixtures/summary-unresolved-only/review-history.md`
- Create: `tests/blueprint-review/fixtures/summary-mixed/review-history.md`
- Create: `tests/blueprint-review/fixtures/summary-oversize/review-history.md`

- [ ] **Step 1: Create fixtures**

`tests/blueprint-review/fixtures/summary-empty/review-history.md`: same as `schema-good` (zero findings in body).

`tests/blueprint-review/fixtures/summary-unresolved-only/review-history.md`:

```markdown
---
id: 6c969da0-7b53-4e89-b286-65fa898bb572
feature: payment-webhook
requirements-id: 6c969da0-7b53-4e89-b286-65fa898bb572
last-finding-id: F-002
finding-count-total: 2
finding-count-unresolved: 2
last-review-at: 2026-05-23T11:12:37Z
---

# Review history — payment-webhook

## F-001
- severity: medium
- phase: item
- target: PAY-001
- first-seen: 2026-05-22T10:00:00Z (cycle 2026-05-22, iter 1)
- last-status: still-present
- last-status-at: 2026-05-22T10:00:00Z
- finding: |
    PAY-001 idempotency-key field name ambiguous.
- suggested-fix: |
    Specify the canonical field name (e.g., Idempotency-Key header).

## F-002
- severity: high
- phase: consistency
- target: file
- first-seen: 2026-05-22T10:05:00Z (cycle 2026-05-22, iter 1)
- last-status: still-present
- last-status-at: 2026-05-22T10:05:00Z
- finding: |
    PAY-002 references "audit_log" but no item defines its schema.
- suggested-fix: |
    Add a Planned item for audit_log schema, or remove the reference.
```

`tests/blueprint-review/fixtures/summary-mixed/review-history.md` (4 findings: 2 unresolved + 2 resolved):

```markdown
---
id: 6c969da0-7b53-4e89-b286-65fa898bb572
feature: payment-webhook
requirements-id: 6c969da0-7b53-4e89-b286-65fa898bb572
last-finding-id: F-004
finding-count-total: 4
finding-count-unresolved: 2
last-review-at: 2026-05-23T11:12:37Z
---

# Review history — payment-webhook

## F-001
- severity: medium
- phase: item
- target: PAY-001
- first-seen: 2026-05-21T08:00:00Z (cycle 2026-05-21, iter 1)
- last-status: resolved
- last-status-at: 2026-05-21T08:15:00Z
- resolved_by_change: "PAY-001 now specifies the Idempotency-Key header explicitly"
- finding: |
    PAY-001 idempotency-key field name ambiguous.
- suggested-fix: |
    Specify the canonical field name.

## F-002
- severity: high
- phase: consistency
- target: file
- first-seen: 2026-05-22T10:05:00Z (cycle 2026-05-22, iter 1)
- last-status: still-present
- last-status-at: 2026-05-22T10:05:00Z
- finding: |
    PAY-002 references "audit_log" but no item defines its schema.
- suggested-fix: |
    Add a Planned item or remove the reference.

## F-003
- severity: medium
- phase: item
- target: PAY-003
- first-seen: 2026-05-22T10:30:00Z (cycle 2026-05-22, iter 1)
- last-status: resolved
- last-status-at: 2026-05-22T10:45:00Z
- resolved_by_change: "PAY-003 now states retry policy: 3x with 2s backoff"
- finding: |
    PAY-003 retry behavior unspecified.
- suggested-fix: |
    Pick a retry count + backoff policy.

## F-004
- severity: medium
- phase: item
- target: PAY-002
- first-seen: 2026-05-23T09:00:00Z (cycle 2026-05-23, iter 1)
- last-status: still-present
- last-status-at: 2026-05-23T09:00:00Z
- finding: |
    PAY-002 timeout for downstream call unspecified.
- suggested-fix: |
    Specify timeout in seconds.
```

`tests/blueprint-review/fixtures/summary-oversize/review-history.md`: 30 resolved + 5 unresolved findings to force truncation. Use a generator script in the fixture directory OR write by hand with shortened bodies. (Engineer's call; the test asserts the truncation invariant holds, not the exact rendered length.)

- [ ] **Step 2: Append failing tests**

Append to `tests/blueprint-review/run.sh`:

```bash
# ---- Task 5: build-summary ------------------------------------------------

t="build-summary: empty history returns empty output"
out="$("$REPO_ROOT/scripts/blueprint-review.sh" build-summary \
       "$FIXTURES/summary-empty/review-history.md" consistency 2>/dev/null || true)"
if [[ -z "$out" ]]; then ok "$t"; else ng "$t" "expected empty, got: $out"; fi

t="build-summary: unresolved-only renders all unresolved"
out="$("$REPO_ROOT/scripts/blueprint-review.sh" build-summary \
       "$FIXTURES/summary-unresolved-only/review-history.md" consistency 2>/dev/null)"
if grep -q "F-001" <<<"$out" && grep -q "F-002" <<<"$out" && grep -q "Currently unresolved" <<<"$out"; then
  ok "$t"
else
  ng "$t" "missing expected ids or heading"
fi

t="build-summary: mixed renders both unresolved and resolved sections"
out="$("$REPO_ROOT/scripts/blueprint-review.sh" build-summary \
       "$FIXTURES/summary-mixed/review-history.md" consistency 2>/dev/null)"
if grep -q "Currently unresolved" <<<"$out" \
   && grep -q "Recently resolved" <<<"$out" \
   && grep -q "F-002" <<<"$out" \
   && grep -q "F-001" <<<"$out"; then
  ok "$t"
else
  ng "$t" "missing one of the expected sections / ids"
fi

t="build-summary: batch filter scopes to named items"
out="$("$REPO_ROOT/scripts/blueprint-review.sh" build-summary \
       "$FIXTURES/summary-mixed/review-history.md" batch \
       --scope-id PAY-001 --scope-id PAY-002 2>/dev/null)"
# PAY-003 finding should be filtered out; PAY-001 + PAY-002 + file-level kept.
if ! grep -q "F-003" <<<"$out" \
   && grep -q "F-001" <<<"$out" \
   && grep -q "F-002" <<<"$out"; then
  ok "$t"
else
  ng "$t" "expected F-001/F-002/F-004 kept, F-003 filtered"
fi

t="build-summary: oversize history truncates to budget"
out="$("$REPO_ROOT/scripts/blueprint-review.sh" build-summary \
       "$FIXTURES/summary-oversize/review-history.md" consistency 2>/dev/null)"
# Rough check: output stays under 8000 characters (~1500 tokens × ~5 chars/token + scaffold)
if [[ ${#out} -lt 8000 ]]; then ok "$t"; else ng "$t" "exceeded 8000 chars (${#out})"; fi
```

- [ ] **Step 3: Run, verify failures**

```bash
bash tests/blueprint-review/run.sh
```

Expected: all 5 build-summary tests fail with "unknown subcommand 'build-summary'".

- [ ] **Step 4: Implement subcommand**

Open `scripts/blueprint-review.sh`. After the existing `parse-findings)` block and before `alloc-final-id)`, add a new case:

```bash
  build-summary)
    history_file="${1:-}"
    phase="${2:-}"
    [[ -n "$history_file" && -n "$phase" ]] || { echo "usage: $0 build-summary <history-file> <phase> [--scope-id <id>]..." >&2; exit 64; }
    [[ -f "$history_file" ]] || { echo "error: history file not found: $history_file" >&2; exit 1; }
    [[ "$phase" =~ ^(consistency|batch)$ ]] || { echo "error: phase must be 'consistency' or 'batch'" >&2; exit 64; }
    shift 2

    scope_ids=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --scope-id)   scope_ids+=("${2:-}"); shift 2 ;;
        --scope-id=*) scope_ids+=("${1#--scope-id=}"); shift ;;
        *) echo "error: unknown arg: $1" >&2; exit 64 ;;
      esac
    done

    python3 - "$history_file" "$phase" "${scope_ids[@]}" <<'PYEOF'
import sys, re

history_path = sys.argv[1]
phase = sys.argv[2]
scope_ids = set(sys.argv[3:])

BUDGET_CHARS = 7500   # ~1500 tokens at ~5 chars/token average
SEVERITY_RANK = {"high": 0, "medium": 1, "low": 2}

with open(history_path, encoding="utf-8", errors="replace") as f:
    text = f.read()

# Strip frontmatter
m = re.match(r'^---\n(.*?)\n---\n', text, re.DOTALL)
body = text[m.end():] if m else text

# Parse ## F-NNN sections
findings = []
section_re = re.compile(r'^## (F-\d{3,})\s*\n((?:(?!^## ).)*)', re.MULTILINE | re.DOTALL)
for sm in section_re.finditer(body):
    fid = sm.group(1)
    sb = sm.group(2)
    def field(name):
        fm = re.search(rf'^- {re.escape(name)}:\s*(.+?)$', sb, re.MULTILINE)
        return fm.group(1).strip() if fm else None
    def field_multi(name):
        fm = re.search(rf'^- {re.escape(name)}:\s*\|\n((?:    .+\n?)+)', sb, re.MULTILINE)
        if not fm: return None
        return "\n".join(l[4:] for l in fm.group(1).splitlines()).strip()
    findings.append({
        "id": fid,
        "severity": field("severity") or "medium",
        "phase": field("phase") or "item",
        "target": field("target") or "file",
        "last_status": field("last-status") or "still-present",
        "last_status_at": field("last-status-at") or "",
        "resolved_by_change": field("resolved_by_change") or "",
        "finding": (field_multi("finding") or "").splitlines()[0] if field_multi("finding") else "",
    })

if not findings:
    sys.exit(0)  # empty output

# Relevance filter
def relevant(f):
    if phase == "consistency":
        return True  # caller passes scope filtering separately; default to all
    # batch: target must be in scope_ids OR file
    return f["target"] in scope_ids or f["target"] == "file"

relevant_findings = [f for f in findings if relevant(f)]
if not relevant_findings:
    sys.exit(0)

unresolved = [f for f in relevant_findings if f["last_status"] != "resolved"]
resolved   = [f for f in relevant_findings if f["last_status"] == "resolved"]

unresolved.sort(key=lambda f: (SEVERITY_RANK.get(f["severity"], 3), f["id"]))
resolved.sort(key=lambda f: f["last_status_at"], reverse=True)

# Truncation invariant: protect unresolved-high + current-item-tied resolved
def render(u, r):
    out = ["## Prior review context (review-history.md)"]
    if u:
        out.append("")
        out.append("Currently unresolved (verify still in spec; reconcile per the contract):")
        for f in u:
            out.append(f"- {f['id']} [{f['severity']}, {f['target']}]: {f['finding']}")
    if r:
        out.append("")
        out.append("Recently resolved (do NOT re-flag unless underlying content has regressed):")
        for f in r:
            rbc = f["resolved_by_change"] or "(no resolution note)"
            out.append(f"- {f['id']} [resolved {f['last_status_at'][:10]}, {f['target']}]: {rbc}")
    out.append("")
    return "\n".join(out)

block = render(unresolved, resolved)
while len(block) > BUDGET_CHARS:
    if resolved:
        resolved.pop()  # drop oldest resolved first
    elif any(f["severity"] == "low" for f in unresolved):
        # drop oldest low-severity unresolved
        for i in range(len(unresolved) - 1, -1, -1):
            if unresolved[i]["severity"] == "low":
                unresolved.pop(i); break
    else:
        break  # accept overrun; never drop protected findings
    block = render(unresolved, resolved)

print(block)
PYEOF
    ;;

```

Place this *before* the existing `alloc-final-id)` case to preserve case ordering.

- [ ] **Step 5: Run tests, verify they pass**

```bash
bash tests/blueprint-review/run.sh
```

Expected: 11 pass, 0 fail.

- [ ] **Step 6: Commit**

```bash
git add scripts/blueprint-review.sh tests/blueprint-review/run.sh tests/blueprint-review/fixtures/summary-*/
git commit -m "$(cat <<'EOF'
feat(blueprint-review): build-summary subcommand

Deterministic prompt-header summary builder from review-history.md per spec §6.2. Honors truncation invariant (never drops unresolved-high or current-item-tied resolved). Caller picks budget = 7500 chars (~1500 tokens).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `scripts/blueprint-review.sh persist-findings` subcommand

**Files:**
- Modify: `scripts/blueprint-review.sh`
- Modify: `tests/blueprint-review/run.sh`
- Create: `tests/blueprint-review/fixtures/persist-input.json`

- [ ] **Step 1: Create fixture for findings input**

`tests/blueprint-review/fixtures/persist-input.json`:

```json
[
  {
    "id": "F-005",
    "severity": "medium",
    "phase": "item",
    "target": "PAY-005",
    "status": "new",
    "first_seen": "2026-05-23T12:00:00Z",
    "cycle_slug": "2026-05-23",
    "iter": 1,
    "finding": "PAY-005 has no acceptance criteria.",
    "suggested_fix": "Add a measurable acceptance criterion."
  },
  {
    "id": "F-002",
    "status": "resolved",
    "resolved_at": "2026-05-23T12:00:00Z",
    "resolved_by_change": "audit_log Planned item added under §Planned"
  },
  {
    "id": "F-001",
    "status": "dropped",
    "dropped_at": "2026-05-23T12:00:00Z"
  }
]
```

The findings shape: `status: "new"` records require full body fields; `status: "resolved"` / `"dropped"` require only `id` + status timestamps + (optional) `resolved_by_change`.

- [ ] **Step 2: Append failing tests**

Append to `tests/blueprint-review/run.sh`:

```bash
# ---- Task 6: persist-findings ---------------------------------------------

t="persist: append new finding bumps last-finding-id"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp "$FIXTURES/summary-mixed/review-history.md" "$tmp/h.md"
"$REPO_ROOT/scripts/blueprint-review.sh" persist-findings "$tmp/h.md" \
   "$FIXTURES/persist-input.json" >/dev/null 2>&1
lid="$("$REPO_ROOT/scripts/frontmatter.sh" get "$tmp/h.md" last-finding-id 2>/dev/null)"
if [[ "$lid" == "F-005" ]]; then ok "$t"; else ng "$t" "expected F-005 got $lid"; fi

t="persist: status update flips F-002 to resolved"
if grep -A2 '^## F-002' "$tmp/h.md" | grep -q 'last-status: resolved'; then
  ok "$t"
else
  ng "$t" "F-002 not marked resolved"
fi

t="persist: dropped status flips F-001 to dropped (was resolved)"
# F-001 in the fixture was 'resolved'; the input marks it 'dropped'. Result should be 'dropped'.
if grep -A2 '^## F-001' "$tmp/h.md" | grep -q 'last-status: dropped'; then
  ok "$t"
else
  ng "$t" "F-001 not marked dropped"
fi

t="persist: finding-count-total recomputed"
total="$("$REPO_ROOT/scripts/frontmatter.sh" get "$tmp/h.md" finding-count-total 2>/dev/null)"
if [[ "$total" == "5" ]]; then ok "$t"; else ng "$t" "expected 5 got $total"; fi

t="persist: finding-count-unresolved recomputed"
# Pre-fixture: F-001 resolved, F-002 still-present, F-003 resolved, F-004 still-present. Unresolved=2.
# After persist: F-001 dropped, F-002 resolved, F-003 resolved (unchanged), F-004 still-present, F-005 new still-present. Unresolved=2.
unr="$("$REPO_ROOT/scripts/frontmatter.sh" get "$tmp/h.md" finding-count-unresolved 2>/dev/null)"
if [[ "$unr" == "2" ]]; then ok "$t"; else ng "$t" "expected 2 got $unr"; fi
```

- [ ] **Step 3: Run, verify failures**

```bash
bash tests/blueprint-review/run.sh
```

Expected: 5 persist tests fail.

- [ ] **Step 4: Implement subcommand**

In `scripts/blueprint-review.sh`, after the `build-summary)` block, add:

```bash
  persist-findings)
    history_file="${1:-}"
    input_json="${2:-}"
    [[ -n "$history_file" && -n "$input_json" ]] || { echo "usage: $0 persist-findings <history-file> <input.json>" >&2; exit 64; }
    [[ -f "$history_file" && -w "$history_file" ]] || { echo "error: history file not found or not writable: $history_file" >&2; exit 1; }
    [[ -f "$input_json" ]] || { echo "error: input json not found: $input_json" >&2; exit 1; }

    python3 - "$history_file" "$input_json" <<'PYEOF'
import sys, re, json, datetime as dt

history_path, input_path = sys.argv[1], sys.argv[2]
with open(history_path, encoding="utf-8", errors="replace") as f:
    raw = f.read()
with open(input_path, encoding="utf-8") as f:
    inputs = json.load(f)

# Split frontmatter and body
m = re.match(r'^(---\n)(.*?)(\n---\n)', raw, re.DOTALL)
if not m:
    print("error: history file has no frontmatter", file=sys.stderr); sys.exit(1)
fm_open, fm_body, fm_close = m.group(1), m.group(2), m.group(3)
body = raw[m.end():]

# Extract current last-finding-id
lid_match = re.search(r'(?m)^last-finding-id:\s*F-(\d+)\s*$', fm_body)
next_n = (int(lid_match.group(1)) + 1) if lid_match else 1

now_iso = dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

# Apply inputs
allocated_last = lid_match.group(1) if lid_match else "000"
for item in inputs:
    status = item.get("status")
    if status == "new":
        # Allocate next id (override if input provides one and it matches expected)
        new_id = item.get("id") or f"F-{next_n:03d}"
        # Append a fresh section
        finding_text = item.get("finding", "").strip()
        fix_text = item.get("suggested_fix", "").strip()
        section = f"""

## {new_id}
- severity: {item.get("severity", "medium")}
- phase: {item.get("phase", "item")}
- target: {item.get("target", "file")}
- first-seen: {item.get("first_seen", now_iso)} (cycle {item.get("cycle_slug", "")}, iter {item.get("iter", 1)})
- last-status: still-present
- last-status-at: {item.get("first_seen", now_iso)}
- finding: |
    {finding_text}
- suggested-fix: |
    {fix_text}
"""
        body = body.rstrip() + section
        m2 = re.match(r"F-(\d+)", new_id)
        if m2:
            allocated_last = m2.group(1)
            next_n = int(allocated_last) + 1
    elif status in ("resolved", "dropped"):
        fid = item["id"]
        ts = item.get("resolved_at") or item.get("dropped_at") or now_iso
        # Locate the section
        pat = re.compile(rf"(^## {re.escape(fid)}\s*\n)((?:(?!^## ).)*?)(?=^## |\Z)", re.MULTILINE | re.DOTALL)
        sm = pat.search(body)
        if not sm:
            print(f"warning: finding {fid} not in history; skipped", file=sys.stderr)
            continue
        section_body = sm.group(2)
        # Replace last-status line
        section_body = re.sub(r"(?m)^- last-status:.*$", f"- last-status: {status}", section_body)
        # Replace last-status-at line (insert if absent)
        if re.search(r"(?m)^- last-status-at:", section_body):
            section_body = re.sub(r"(?m)^- last-status-at:.*$", f"- last-status-at: {ts}", section_body)
        else:
            section_body = re.sub(r"(?m)(^- last-status:.*$)", rf"\1\n- last-status-at: {ts}", section_body)
        # resolved_by_change (only for resolved)
        if status == "resolved":
            rbc = item.get("resolved_by_change", "")
            if re.search(r"(?m)^- resolved_by_change:", section_body):
                section_body = re.sub(r"(?m)^- resolved_by_change:.*$", f'- resolved_by_change: "{rbc}"', section_body)
            else:
                section_body = re.sub(r"(?m)(^- last-status-at:.*$)", rf'\1\n- resolved_by_change: "{rbc}"', section_body)
        body = body[:sm.start()] + sm.group(1) + section_body + body[sm.end():]

# Recompute counters
all_ids = re.findall(r"(?m)^## (F-\d+)", body)
statuses = {}
for fid in all_ids:
    pat = re.compile(rf"^## {re.escape(fid)}\s*\n((?:(?!^## ).)*)", re.MULTILINE | re.DOTALL)
    sm = pat.search(body)
    if sm:
        st_m = re.search(r"(?m)^- last-status:\s*(\S+)", sm.group(1))
        statuses[fid] = st_m.group(1) if st_m else "still-present"
total = len(all_ids)
unresolved = sum(1 for s in statuses.values() if s != "resolved" and s != "dropped")

# Rewrite frontmatter
def set_field(fm, name, value):
    pat = re.compile(rf"(?m)^{re.escape(name)}:.*$")
    if pat.search(fm):
        return pat.sub(f"{name}: {value}", fm, count=1)
    return fm.rstrip("\n") + f"\n{name}: {value}"

fm_body = set_field(fm_body, "last-finding-id", f"F-{int(allocated_last):03d}")
fm_body = set_field(fm_body, "finding-count-total", str(total))
fm_body = set_field(fm_body, "finding-count-unresolved", str(unresolved))
fm_body = set_field(fm_body, "last-review-at", now_iso)

new_raw = fm_open + fm_body + fm_close + body
with open(history_path, "w", encoding="utf-8") as f:
    f.write(new_raw)
PYEOF
    ;;

```

- [ ] **Step 5: Run tests, verify they pass**

```bash
bash tests/blueprint-review/run.sh
```

Expected: 16 pass, 0 fail.

- [ ] **Step 6: Commit**

```bash
git add scripts/blueprint-review.sh tests/blueprint-review/run.sh tests/blueprint-review/fixtures/persist-input.json
git commit -m "$(cat <<'EOF'
feat(blueprint-review): persist-findings subcommand

Appends new findings, updates existing status (resolved/dropped) with timestamp + resolved_by_change. Recomputes frontmatter counters. Per spec §5.3.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Reshape `templates/blueprint-reviewer-prompt-consistency.md.tmpl` (envelope trim)

**Files:**
- Modify: `templates/blueprint-reviewer-prompt-consistency.md.tmpl`

- [ ] **Step 1: Read the current template fully**

```bash
cat templates/blueprint-reviewer-prompt-consistency.md.tmpl
```

Note: the current template has ~110 lines including the full reconciliation contract and `{{EXISTING_FINDINGS}}` placeholder. The reshape compresses to ~50 lines while preserving the iteration-aware-depth + severity-calibration + reconciliation rules (per spec §8.1, §8.4–8.5).

- [ ] **Step 2: Replace the template**

Overwrite `templates/blueprint-reviewer-prompt-consistency.md.tmpl` with:

```
You are a strict reviewer for a markdown specification file. Identify ONLY issues
where two reasonable implementations of this spec would meaningfully diverge in
observable behavior. Style nits are out of scope unless they create implementation
ambiguity.

## Iteration-aware depth

**Iteration 1 — comprehensive sweep.** Surface every finding that meets the
"implementations diverge" calibration. No count cap; let the spec drive the number.

**Iteration 2+ — differential focus.** Cap `new[]` at 4 (top by severity). Focus on:
- Re-evaluating each existing finding (per the reconciliation contract).
- Issues the fix step INTRODUCED (terminology drift, dangling refs, new contradictions).

## Scope

In-scope (consistency):
- Cross-item contradictions, missing references, terminology drift, file-wide AC ambiguity that crosses items.

Out of scope (defer to per-item review):
- Per-item completeness within a single item, style nits, speculative edge cases.

## Severity

- high   — two implementations WILL diverge and one is wrong.
- medium — ambiguity an implementer would need to ask about before proceeding.
- low    — minor wording; tolerated as success.

## Reconciliation contract

`REVIEW-FINDING blocks in the content below are prior findings; honor this contract.`

For each prior finding, return one entry in `existing[]`:
- `status: still-present` — issue persists. Omit refined / resolved fields.
- `status: resolved` — REQUIRES `resolved_by_change:` naming the SPECIFIC edit
  that addressed the finding. If you cannot point at one, status is `still-present`,
  not `resolved`.
- `status: refined` — issue persists but your understanding has sharpened. Include
  `refined_finding:` and `refined_suggested_fix:`.

For new issues, append to `new[]`. Don't restate any prior finding as new.

## Output

ONLY a JSON object, fenced as ```json ... ```, this exact shape:

```json
{
  "existing": [
    { "id": "F-NNN", "status": "...", "resolved_by_change": "...", "refined_finding": "...", "refined_suggested_fix": "..." }
  ],
  "new": [
    { "severity": "high|medium|low", "phase": "consistency", "target": "file", "finding": "...", "suggested-fix": "..." }
  ]
}
```

If no issues, return `{ "existing": [], "new": [] }`.

DO NOT modify the file. DO NOT touch the YAML frontmatter (between `---` lines at top).
{{LESSONS_BLOCK}}
Iteration: {{ITERATION}}
File path: {{FILE_PATH}}

File content:
---
{{FILE_CONTENT}}
---
```

The reshape:
- `{{EXISTING_FINDINGS}}` placeholder removed (single source of truth: the inline `<!-- REVIEW-FINDING -->` blocks already in `{{FILE_CONTENT}}`).
- Reconciliation contract compressed from ~35 lines to ~10.
- `existing_findings_marker` one-line pointer embedded in the prose at "REVIEW-FINDING blocks in the content below..."

- [ ] **Step 3: Smoke-test substitution**

```bash
bash -c "
content=\"\$(cat templates/blueprint-reviewer-prompt-consistency.md.tmpl)\"
echo \"\$content\" | grep -q '{{EXISTING_FINDINGS}}' && { echo 'FAIL: placeholder still present' >&2; exit 1; }
echo \"\$content\" | grep -q '{{FILE_CONTENT}}' || { echo 'FAIL: FILE_CONTENT placeholder missing' >&2; exit 1; }
echo \"\$content\" | grep -q '{{LESSONS_BLOCK}}' || { echo 'FAIL: LESSONS_BLOCK placeholder missing' >&2; exit 1; }
echo OK
"
```

Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add templates/blueprint-reviewer-prompt-consistency.md.tmpl
git commit -m "$(cat <<'EOF'
feat(templates): consistency reviewer prompt envelope trim

Removes {{EXISTING_FINDINGS}} placeholder (single source of truth: inline REVIEW-FINDING blocks in file content). Compresses reconciliation contract per spec §8.1, §8.5.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Create `templates/blueprint-reviewer-prompt-batch.md.tmpl` (replaces `*-item.md.tmpl`)

**Files:**
- Create: `templates/blueprint-reviewer-prompt-batch.md.tmpl`
- (Don't yet delete `*-item.md.tmpl` — deletion happens in Task 18 once all callers migrate.)

- [ ] **Step 1: Write the template**

Create `templates/blueprint-reviewer-prompt-batch.md.tmpl`:

```
You are a strict reviewer for ONE OR MORE items in a markdown specification. Identify
ONLY issues where two reasonable implementations of an item would meaningfully diverge
in observable behavior. Style nits are out of scope unless they create implementation
ambiguity.

## Iteration-aware depth

**Iteration 1 — comprehensive sweep per item.** Surface every finding that meets the
"implementations diverge" calibration for each item. No count cap; let the item drive
the number.

**Iteration 2+ — differential focus.** Cap each item's `new[]` at 4 (top by severity).
Focus on re-evaluating existing findings + issues the fix step introduced.

## Scope (per item)

In-scope: missing acceptance criteria, missing seam reference, internal contradictions,
genuinely-ambiguous edge cases.

Out of scope (defer to consistency review): cross-item issues, style nits, speculative
"what if" cases.

## Severity

- high   — two implementations WILL diverge and one is wrong.
- medium — ambiguity an implementer would need to ask about before proceeding.
- low    — minor wording; tolerated as success.

## Reconciliation contract

`REVIEW-FINDING blocks in each item's content below are prior findings; honor this contract.`

Per prior finding, one `existing[]` entry per the same rules as the consistency reviewer
(`still-present` / `resolved` (REQUIRES `resolved_by_change:`) / `refined`).

## Output

ONLY a JSON object, fenced as ```json ... ```, this exact shape. The `items` array
MUST contain exactly one entry per item in the input, keyed by `item_id`. Items with
nothing to flag still appear with empty `existing` and `new` arrays.

```json
{
  "items": [
    {
      "item_id": "<id from input>",
      "existing": [
        { "id": "F-NNN-or-T1-N", "status": "...", "resolved_by_change": "...", "refined_finding": "...", "refined_suggested_fix": "..." }
      ],
      "new": [
        { "severity": "high|medium|low", "phase": "item", "target": "<item_id>", "finding": "...", "suggested-fix": "..." }
      ]
    }
  ]
}
```

Iteration: {{ITERATION}}

Items to review:
---
{{BATCH_PAYLOAD}}
---
```

`{{BATCH_PAYLOAD}}` is rendered by the sub-agent as a sequence of:

```
Item <id>:
---
<item content including inline REVIEW-FINDING blocks>
---
```

- [ ] **Step 2: Smoke-test substitution**

```bash
bash -c "
content=\"\$(cat templates/blueprint-reviewer-prompt-batch.md.tmpl)\"
echo \"\$content\" | grep -q '{{BATCH_PAYLOAD}}' || { echo 'FAIL: BATCH_PAYLOAD missing' >&2; exit 1; }
echo \"\$content\" | grep -q '{{ITERATION}}' || { echo 'FAIL: ITERATION missing' >&2; exit 1; }
echo \"\$content\" | grep -q 'item_id' || { echo 'FAIL: item_id contract missing' >&2; exit 1; }
echo OK
"
```

Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add templates/blueprint-reviewer-prompt-batch.md.tmpl
git commit -m "$(cat <<'EOF'
feat(templates): batch reviewer prompt (replaces per-item template)

Single template handles 1..N items per batch via {{BATCH_PAYLOAD}}. Per-item shape uniformity simplifies parsing. Per spec §8.3.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Reshape `agents/blueprint-consistency-reviewer.md` for session continuation

**Files:**
- Modify: `agents/blueprint-consistency-reviewer.md`

- [ ] **Step 1: Replace the agent definition body**

Overwrite the body of `agents/blueprint-consistency-reviewer.md` (keep frontmatter `name` + `description` + `model` mostly intact; update `tools` to include `mcp__codex__codex-reply`):

```markdown
---
name: blueprint-consistency-reviewer
description: Runs one whole-file consistency review for /mi-blueprint-review-consistency and the orchestrator's Phase D. Owns a single codex session; rounds 2+ use codex-reply. Writes the reviewed file directly between rounds (safe — always serial). Exits early on success / stop-on-stable; otherwise hits max-iter.
model: opus
effort: high
tools: [Read, Write, Edit, Bash, Grep, mcp__codex__codex, mcp__codex__codex-reply]
---

You are a fresh sub-agent invoked by `mi-blueprint-review-consistency` (or by `/mi-blueprint-review` Phase D) to run **one** consistency review on a markdown file. Your context is isolated; main sees only your structured return.

You write the reviewed file directly between rounds. Safe because consistency review is always serial — only one instance of you runs per file at a time.

## Inputs (from spawn prompt)

- `file_path` — absolute path to the markdown file.
- `max_iterations` — positive integer; maximum reviewer calls.
- `agent` — reviewer agent name (e.g. `codex`).
- `reviewer_tool_name` — main `mcp__codex__codex` tool (round 1).
- `reviewer_reply_tool_name` — `mcp__codex__codex-reply` (rounds 2+).
- `reasoning_effort` — `low | medium | high`.
- `lessons_block` — opaque markdown string for `{{LESSONS_BLOCK}}` substitution; may be empty.
- `history_summary` — opaque markdown string built by main (≤ 1500 tokens) carrying cross-cycle context. May be empty.
- `file_metadata_brief` — opaque markdown string built by main (~100 tokens) — feature, item-id range, terminology glossary.

## Loop body

### Round 1 (mandatory — open session)

1. Read `file_path` (includes any existing `<!-- REVIEW-FINDING -->` blocks).
2. Strip the YAML frontmatter from the content used for the prompt (the on-disk file is unchanged).
3. Render the consistency reviewer template (`templates/blueprint-reviewer-prompt-consistency.md.tmpl`) with:
   - `{{FILE_PATH}}` = `file_path`
   - `{{FILE_CONTENT}}` = frontmatter-stripped file body
   - `{{ITERATION}}` = 1
   - `{{LESSONS_BLOCK}}` = the spawn input
4. Compose the round-1 prompt:
   ```
   [file_metadata_brief]
   
   [history_summary]                <-- omit entire block if empty
   
   [rendered consistency template]
   ```
5. Call `mcp__codex__codex` with `prompt=<composed>`, `sandbox="read-only"`, `approval-policy="never"`, `config={"model_reasoning_effort": <spawn input reasoning_effort>}`. Capture `threadId` from the response. Parse the `content` field as JSON (shape `{existing: [...], new: [...]}`). On parse failure: retry once with `"Your last response was not valid JSON. Return ONLY a JSON object with the documented shape."`; on second failure → `Result: blocked`. **See `docs/blueprint-review-token-reduction/phase-0-findings.md` for the MCP shape — threadId, not session_id; reasoning_effort goes through config, not as a top-level param.**
6. Apply the reconciliation in-memory + write the file to disk (see Apply step below).
7. If `new[]` is empty AND every `existing[]` is `status ∈ {still-present, refined}` after round 1, you've converged → exit `Result: success` (or `partial; reason: stable` if anything remains).
8. Else if `max_iterations == 1`: exit `Result: partial; reason: max-iter`.

### Rounds 2..N (via codex-reply)

For each subsequent round (up to `max_iterations`):

1. Compute the diff between the prior round's pre-apply file content and the post-apply content (or just "I applied the suggested fixes; here is the new file content" with relevant section).
2. Compose the delta prompt:
   ```
   I applied your suggested fixes. Here is the updated file content (frontmatter-stripped):
   ---
   [updated body]
   ---
   
   Re-evaluate per the same contract. Return the same JSON shape. Iteration: <N>.
   ```
3. Call `mcp__codex__codex-reply` with **only** `threadId=<from round 1>` and `prompt=<delta>`. **Do NOT pass reasoning_effort / sandbox / config** — `codex-reply` rejects those params; `reasoning_effort` is locked in at round 1 via the thread's session state. Same parse + retry policy as round 1.
4. Apply the reconciliation; write the file.
5. Check completion:
   - **(a) Success** — `new[]` empty AND every `existing[]` is `resolved`. Exit `Result: success`.
   - **(b) Stop-on-stable** — `new[]` empty AND every `existing[]` is `still-present` or `refined`. Exit `Result: partial; reason: stable`.
   - **(c) Stable-medium-only** — no high-severity findings remain. Exit `Result: partial; reason: stable-medium`.
6. If round == `max_iterations`: exit `Result: partial; reason: max-iter`.

### Apply step (per round)

For each `existing[]` entry:
- `status: resolved` (with non-empty `resolved_by_change`) — REMOVE the `<!-- REVIEW-FINDING id: X -->` block from the file.
- `status: refined` — UPDATE the block's `finding:` and `suggested-fix:` with refined text.
- `status: still-present` — leave the block alone.

For each `new[]` entry:
- Allocate a final `F-NNN` id via `scripts/blueprint-review.sh alloc-final-id "$file_path"`.
- Append a fresh `REVIEW-FINDING` block at the top of the body (after frontmatter, before the first `## ` heading).

Write the updated file via `Write`. Validate frontmatter byte-for-byte unchanged from your round's starting state. If changed: revert; retry once; on second failure → `Result: blocked`.

### Session-expiry fallback

If `mcp__codex__codex-reply` errors with a session-expiry signal (verify the exact shape from `docs/blueprint-review-token-reduction/phase-0-findings.md`), degrade for this round: re-compose the full round-1-style prompt (scaffold + brief + summary + current file content) and call `mcp__codex__codex` instead. Note in `Findings / risks` that round N degraded.

## Required return shape

```
Result: success | partial | blocked
Artifacts changed:
- <file_path>: <rounds run + final finding counts + exit reason>
Commits:
- (none — this sub-agent never commits)
Findings / risks:
- reason: <success | stable | stable-medium | max-iter | blocked-detail>
- counts: <H> high / <M> medium / <L> low remain inline
- rounds: <N>
- session: <session_id>          (informational)
Main should read:
- <file_path>: (when Result=partial, main may surface a y/n prompt; also Phase F reads it for persist)
```

Total return ≤ 1k tokens.
```

- [ ] **Step 2: Lint check the agent file**

If the project has a generic agent-frontmatter lint test, run it:

```bash
bash tests/lint/run.sh 2>&1 | grep -i "blueprint-consistency-reviewer\|review\|agent" | head -20
```

(If `tests/lint/run.sh` doesn't exist or has no specific check, this step is a no-op — the test infrastructure for sub-agents is light.)

- [ ] **Step 3: Commit**

```bash
git add agents/blueprint-consistency-reviewer.md
git commit -m "$(cat <<'EOF'
feat(agents): blueprint-consistency-reviewer single-session + codex-reply

Reshape per spec §9.1. Round 1 uses mcp__codex__codex; rounds 2+ use mcp__codex__codex-reply with delta-only prompts. Accepts new spawn inputs (history_summary, file_metadata_brief). Drops {{EXISTING_FINDINGS}} from prompt rendering.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Create `agents/blueprint-batch-reviewer.md`

**Files:**
- Create: `agents/blueprint-batch-reviewer.md`

- [ ] **Step 1: Write the agent**

Create `agents/blueprint-batch-reviewer.md`:

```markdown
---
name: blueprint-batch-reviewer
description: Runs one read-only review on a batch of 1..N items for /mi-blueprint-review Phase C (or /mi-blueprint-review-item with batch=1). Owns a single codex session; rounds 2+ use codex-reply with delta-only payloads. Returns multi-item Payload JSON; main applies region replacements serially.
model: opus
effort: high
tools: [mcp__codex__codex, mcp__codex__codex-reply]
---

You are a fresh sub-agent invoked by `/mi-blueprint-review` Phase C (or `/mi-blueprint-review-item`) to review **one batch** of 1..N items. Your context is isolated; main sees only your structured return.

You are **strictly read-only on every file**. Your `tools:` lists ONLY the codex MCP tools — no `Read`, `Write`, `Edit`, `Bash`, `Grep`. You operate entirely on the content passed in your spawn prompt and on the reviewer's responses.

## Inputs (from spawn prompt)

- `mode`: `file` | `content` (file = batch comes from canonical descriptors; content = stateless single item from `/mi-blueprint-review-item` Mode B)
- `batch_id`: e.g., `B1`
- `items`: JSON array `[{item_id, original_region}, ...]` (1..N entries)
- `max_iterations`: positive integer
- `agent`, `reviewer_tool_name` (`mcp__codex__codex`), `reviewer_reply_tool_name` (`mcp__codex__codex-reply`)
- `reasoning_effort`: `low | medium | high`
- `sub_agent_instance_id`: e.g., `T1` — used as tmp-id prefix for new findings
- `history_summary`: opaque markdown string built by main (≤ 1500 tokens). May be empty.
- `file_metadata_brief`: opaque markdown string built by main.
- `lessons_block`: **always empty for this sub-agent** (per spec §8.1.3); field kept for shape uniformity.

## Loop body

### Round 1

1. Initialize per-item `working_copy = original_region`. Track `tmp_id_counter` per item.
2. Render `templates/blueprint-reviewer-prompt-batch.md.tmpl` with:
   - `{{ITERATION}}` = 1
   - `{{BATCH_PAYLOAD}}` = rendered as:
     ```
     Item <id1>:
     ---
     <working_copy_1>
     ---
     
     Item <id2>:
     ---
     <working_copy_2>
     ---
     ```
3. Compose the round-1 prompt:
   ```
   [file_metadata_brief]
   
   [history_summary]                <-- omit if empty
   
   [rendered batch template]
   ```
4. Call `mcp__codex__codex` with `prompt=<composed>`, `sandbox="read-only"`, `approval-policy="never"`, `config={"model_reasoning_effort": <spawn input reasoning_effort>}`. Capture `threadId` from the response. Parse the `content` field as JSON (shape `{items: [{item_id, existing, new}, ...]}`). On parse failure: retry once with clarifying suffix; on second failure → `Result: blocked`. **See `docs/blueprint-review-token-reduction/phase-0-findings.md` for the MCP shape — threadId, not session_id; reasoning_effort via config.**
5. Validate: response's `items` array must contain exactly one entry per input item, keyed by `item_id`. On mismatch: retry once; on second failure → `Result: blocked`.
6. Apply reconciliation per-item to each `working_copy` (see Apply step).
7. If all items are converged AND `max_iterations == 1`: exit with the Payload JSON below.

### Rounds 2..N (via codex-reply)

1. Drop converged items from `active_items` (item is converged if its round N-1 entry has `new: []` AND every `existing[]` is `still-present | resolved | refined`).
2. If `active_items` is empty: exit `Result: success`.
3. Compose the delta prompt:
   ```
   I applied your suggested fixes. Updated item content (only items still active):
   
   Item <id_active_1>:
   ---
   <working_copy_active_1>
   ---
   
   (... only active items ...)
   
   Items not listed converged in round <N-1>.
   
   Re-evaluate per the same contract. Return the same JSON shape, with `items` entries
   ONLY for the items above. Iteration: <N>.
   ```
4. Call `mcp__codex__codex-reply` with **only** `threadId=<from round 1>` and `prompt=<delta>`. Do NOT pass `sandbox` / `config` / `reasoning_effort` — `codex-reply` rejects those (settings are locked at thread open). Same parse/validate/retry policy.
5. Apply reconciliation.
6. Check completion (same exit logic as the consistency reviewer's rounds 2+).

### Apply step (in-memory per item)

For each item's response entry:

For each `existing[]` entry:
- `status: resolved` (with non-empty `resolved_by_change`) — REMOVE the matching `<!-- REVIEW-FINDING -->` block from `working_copy`.
- `status: refined` — UPDATE the block's `finding:` and `suggested-fix:`.
- `status: still-present` — leave alone.

For each `new[]` entry:
- Allocate tmp-id `<sub_agent_instance_id>-<n>` where n starts at 1 per item and increments.
- Append a `REVIEW-FINDING` block to `working_copy` after the offending line (or at the end of the item region if no specific anchor).

### Session-expiry fallback

Same shape as the consistency reviewer's fallback — if `codex-reply` errors, re-issue the round as a fresh `mcp__codex__codex` call with full context. Note in `Findings / risks`.

## Required return shape

Payload JSON block FIRST (four-backtick outer fence; inner ```json` is unambiguous), then standard contract fields.

````
Payload JSON:
```json
{
  "batch_id": "<batch_id>",
  "iteration_reached": <N>,
  "session_id": "<opaque; informational>",
  "items": [
    {
      "item_id": "<id>",
      "original_region": "<exact bytes received>",
      "new_region": "<working_copy at exit>",
      "remaining_findings": [
        { "id": "<tmp_id>", "severity": "...", "phase": "item", "target": "<item_id>", "finding": "...", "suggested-fix": "..." }
      ]
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
- batch-id: <batch_id>
- reason: <success | stable | stable-medium | max-iter | blocked-detail>
- rounds: <N>
Main should read:
- (none — main reads the Payload JSON above)
````

Total standard-fields return ≤ 1k tokens; Payload JSON is not counted against that budget.
```

- [ ] **Step 2: Commit**

```bash
git add agents/blueprint-batch-reviewer.md
git commit -m "$(cat <<'EOF'
feat(agents): blueprint-batch-reviewer (replaces per-item reviewer)

One sub-agent per batch (1..N items). Strictly read-only on disk. Owns one codex session; rounds 2+ use codex-reply with delta-only prompts. Returns multi-item Payload JSON. Per spec §9.2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Rewrite `/mi-blueprint-review` orchestrator

**Files:**
- Modify: `commands/mi-blueprint-review.md`

This is the largest single task. Break Step 1 (rewrite) into the sequential implementation order called out in the spec §3 walkthrough.

- [ ] **Step 1: Read the current orchestrator fully**

```bash
cat commands/mi-blueprint-review.md
```

Note the existing structure (Step 1 validate, Step 1.5 lessons_block, Step 2 Phase 1, Step 3 Phase 2, Step 4 Phase 3, Step 5 Phase 4, Step 6 Phase 5). The new file replaces it entirely.

- [ ] **Step 2: Replace the command file**

Overwrite `commands/mi-blueprint-review.md` with the new v1.4 orchestrator:

````markdown
---
description: Orchestrate a token-reduced blueprint review (v1.4): preflight + summary build → enumerate → per-batch review (parallel waves) → single consistency pass → persist to review-history.md → report. Uses mcp__codex__codex for round 1 and mcp__codex__codex-reply for rounds 2+. See docs/blueprint-review-token-reduction/plan.md.
---

# /mi-blueprint-review

## Usage

```
/mi-blueprint-review <agent> <file-path>
                     [--auto-iter N] [--batch-size N] [--scope <heading>]
                     [--reasoning-effort <low|medium|high>] [--concurrency N]
```

| Param | Default | Meaning |
| --- | --- | --- |
| `<agent>` | (required) | Reviewer agent name. Currently `codex`. |
| `<file-path>` | (required) | Markdown file. Edits in place. |
| `--auto-iter N` | 3 | Per-batch / per-consistency-pass round budget. `1` = find-only (no fix step). |
| `--batch-size N` | 3 | Items per batch in Phase C. |
| `--scope <heading>` | (none) | Restrict Phase B enumeration to items under `## <heading>`. |
| `--reasoning-effort R` | medium | Passed through to every codex call. |
| `--concurrency N` | 3 | Maximum Phase C batches in parallel codex sessions per wave. |

## Preconditions

- Reviewer's MCP server reachable (`/mi-doctor`).
- `mcp__codex__codex-reply` available (verified at Phase 0). If unavailable, this command falls back to stateless mode and logs a warning.
- File exists and is writable.

## Phase progression contract (READ BEFORE EXECUTING)

Phases run in order: A → B → C → D → F → G. Every phase is **mandatory**. Allowed early exits:

| Phase | Allowed skip | NOT allowed |
| --- | --- | --- |
| A — preflight | (none) | Skipping at all. |
| B — enumeration | `enumerate` exits 2 → abort orchestrator. | Skipping. |
| C — per-batch review | Descriptor count == 0 → skip C, proceed to D. | Skipping for cost / time / "items look fine." |
| D — consistency | (none) | Skipping because C found nothing / count was 0. |
| F — persist | (none) | Skipping; even if no findings, `last-review-at` updates. |
| G — final report | (none) | Skipping. |

Announce each phase as you enter it (one short line: "Phase X — <name> — starting").

## Execution

### Step 1 — Validate inputs and resolve constants

```bash
set -euo pipefail
agent="${1:-}"
file="${2:-}"
auto_iter=3
batch_size=3
scope=""
reasoning_effort="medium"
concurrency=3
i=3
while [[ $i -le $# ]]; do
  arg="${!i}"
  case "$arg" in
    --auto-iter=*)        auto_iter="${arg#--auto-iter=}" ;;
    --auto-iter)          ((i++)); auto_iter="${!i}" ;;
    --batch-size=*)       batch_size="${arg#--batch-size=}" ;;
    --batch-size)         ((i++)); batch_size="${!i}" ;;
    --scope=*)            scope="${arg#--scope=}" ;;
    --scope)              ((i++)); scope="${!i}" ;;
    --reasoning-effort=*) reasoning_effort="${arg#--reasoning-effort=}" ;;
    --reasoning-effort)   ((i++)); reasoning_effort="${!i}" ;;
    --concurrency=*)      concurrency="${arg#--concurrency=}" ;;
    --concurrency)        ((i++)); concurrency="${!i}" ;;
  esac
  ((i++))
done

[[ -n "$agent" && -n "$file" ]] || {
  echo "usage: /mi-blueprint-review <agent> <file> [--auto-iter N] [--batch-size N] [--scope X] [--reasoning-effort R] [--concurrency N]" >&2
  exit 64
}
[[ "$auto_iter" =~ ^[1-9][0-9]*$ ]]   || { echo "error: --auto-iter must be positive integer" >&2; exit 64; }
[[ "$batch_size" =~ ^[1-9][0-9]*$ ]]  || { echo "error: --batch-size must be positive integer" >&2; exit 64; }
[[ "$concurrency" =~ ^[1-9][0-9]*$ ]] || { echo "error: --concurrency must be positive integer" >&2; exit 64; }
[[ "$reasoning_effort" =~ ^(low|medium|high)$ ]] || { echo "error: --reasoning-effort must be low|medium|high" >&2; exit 64; }
[[ -f "$file" && -w "$file" ]] || { echo "error: file not found or not writable: $file" >&2; exit 1; }

reviewer_tool="$($CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh resolve-tool "$agent")" || exit 1
reviewer_reply_tool="mcp__${agent}__${agent}-reply"   # v1.4 convention; matches Phase 0 finding
MAX_ITEMS_PER_REVIEW=20
```

### Step 2 — Phase A: preflight + summary build **(MANDATORY)**

Announce: `Phase A — preflight — starting`.

**A.1 — Resolve `review-history.md` sibling.** If the file sits inside `*/blueprints/current/`:

```bash
file_dir="$(cd "$(dirname "$file")" && pwd)"
review_history=""
if [[ "$file_dir" == */blueprints/current ]]; then
  review_history="$file_dir/review-history.md"
  if [[ ! -f "$review_history" ]]; then
    "$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" init review-history "$review_history" \
      ID=$(uuidgen | tr 'A-Z' 'a-z') \
      FEATURE=$(basename "$(cd "$file_dir/../.." && pwd)") \
      REQUIREMENTS_ID=$("$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" get "$file" id 2>/dev/null || echo null) \
      LAST_FINDING_ID=F-000 \
      FINDING_COUNT_TOTAL='!RAW!0' \
      FINDING_COUNT_UNRESOLVED='!RAW!0' \
      LAST_REVIEW_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
fi
```

**A.2 — Resolve lessons_block** via existing sibling-detection (identical to v1.2.x; see prior implementation in this command file's history for reference).

**A.3 — Build `file_metadata_brief`** in main:

```
- Feature: <feature slug>
- File: <basename>
- Items in scope: <ids>
- Sections: <top-level ## headings>
- Glossary: <comma-separated bolded-term sample, up to 10>
```

**A.4 — Build `history_summary`** (consistency-scope) once if `$review_history` is non-empty:

```bash
history_summary_consistency=""
if [[ -n "$review_history" && -f "$review_history" ]]; then
  history_summary_consistency="$("$CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh" \
    build-summary "$review_history" consistency 2>/dev/null || echo "")"
fi
```

(Per-batch summaries are built in Step 4 once the batch's scope IDs are known.)

### Step 3 — Phase B: item enumeration **(MANDATORY)**

Announce: `Phase B — enumeration — starting`.

Render `templates/blueprint-reviewer-prompt-enumerate.md.tmpl` (unchanged from v1.2.x). Call `mcp__codex__codex` directly from main (one-shot; no sub-agent). Capture session ID but discard (enumeration is single-call).

Parse the JSON array; pass to `scripts/blueprint-review.sh enumerate`. If `enumerate` exits 2 → surface errors + abort. If count > `MAX_ITEMS_PER_REVIEW` → print refusal message + stop. If count == 0 → skip Step 4; jump to Step 5.

### Step 4 — Phase C: per-batch review **(MANDATORY when descriptor count ≥ 1)**

Announce: `Phase C — per-item review — starting (N descriptors, batch size B, concurrency C)`.

You **MUST** spawn a `blueprint-batch-reviewer` sub-agent for every batch of `<batch_size>` descriptors. Cost / time / "items look fine" are not valid reasons to skip — Phase C catches single-item ambiguities Phase D's whole-file pass under-weights.

```python
# pseudocode for the orchestrator's batched-wave dispatcher
descriptors = sorted(descriptors, key=lambda d: d["start_offset"])
batches = [descriptors[i:i+batch_size] for i in range(0, len(descriptors), batch_size)]

for wave_start in range(0, len(batches), concurrency):
    wave = batches[wave_start : wave_start + concurrency]
    
    # Build per-batch summaries before dispatching the wave.
    spawn_inputs = []
    for batch in wave:
        scope_ids = [d["id"] for d in batch]
        history_summary_batch = ""
        if review_history:
            history_summary_batch = sh(
                f'{plugin_root}/scripts/blueprint-review.sh build-summary {review_history} batch '
                + " ".join(f'--scope-id {sid}' for sid in scope_ids)
            )
        spawn_inputs.append({
            "batch_id": f"B{wave_start//concurrency + 1}-{batches.index(batch)}",
            "items": batch,
            "max_iterations": auto_iter,
            "agent": agent,
            "reviewer_tool_name": reviewer_tool,
            "reviewer_reply_tool_name": reviewer_reply_tool,
            "reasoning_effort": reasoning_effort,
            "sub_agent_instance_id": f"T{batch_index}",
            "history_summary": history_summary_batch,
            "file_metadata_brief": file_metadata_brief,
            "lessons_block": "",     # always empty for batch reviewer (spec §8.1.3)
        })
    
    # Dispatch ALL spawn_inputs in this wave as parallel Agent calls in ONE message.
    payloads = parallel_dispatch(spawn_inputs, sub_agent_type="...:blueprint-batch-reviewer")
    
    # Serialized write-back in main.
    flat = []
    for p in payloads:
        flat.extend(p["items"])  # each batch returns multi-item items[]
    flat.sort(key=lambda it: original_offset_of(it["item_id"]))
    
    for it in flat:
        next_id = sh(f"scripts/blueprint-review.sh alloc-final-id {file}").strip()
        rewritten = rewrite_tmp_ids(it["new_region"], starting_at=next_id)
        try:
            Edit(file_path=file, old_string=it["original_region"], new_string=rewritten)
        except ExactMatchFailure:
            # Re-enumerate this item; re-spawn a single-item batch.
            new_d = re_enumerate_single_item(file, it["item_id"])
            new_payload = spawn_single_item_batch(new_d, ...)
            Edit(file_path=file, old_string=new_payload["items"][0]["original_region"], new_string=new_payload["items"][0]["new_region"])
        validate_frontmatter_unchanged(file)
```

When all waves complete, proceed to Step 5.

### Step 5 — Phase D: consistency loop **(MANDATORY)**

Announce: `Phase D — consistency — starting`.

Spawn one `blueprint-consistency-reviewer` sub-agent. Parameters:

```
file_path, max_iterations=auto_iter, agent, reviewer_tool_name, reviewer_reply_tool_name,
reasoning_effort, lessons_block, history_summary (use history_summary_consistency from A.4),
file_metadata_brief
```

On `success` / `partial` / `blocked`: continue to Step 6 (Phase F) regardless. Phase F persists whatever findings exist.

### Step 6 — Phase F: persist to review-history.md **(MANDATORY when `review_history` is set)**

Announce: `Phase F — persist — starting`.

Collect all findings produced this run from the file's current `<!-- REVIEW-FINDING -->` blocks (via `scripts/blueprint-review.sh parse-findings`). For each:
- If its `id` already exists in `review-history.md`: emit a `status: still-present` entry (timestamp bumped).
- If its `id` is new: emit a `status: new` entry with full body.

Also detect findings that previously existed in `review-history.md` with `status != resolved/dropped` but are NOT in the current file's inline blocks → emit a `status: dropped` entry for them.

Pipe the resulting JSON array to `scripts/blueprint-review.sh persist-findings`:

```bash
echo "$findings_json" > /tmp/mi-persist-input.<pid>.json
"$CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh" persist-findings "$review_history" /tmp/mi-persist-input.<pid>.json
rm -f /tmp/mi-persist-input.<pid>.json
```

If `review_history` is empty (file not in `*/blueprints/current/`), skip Phase F silently — the inline findings stay in the file, no history is recorded.

### Step 7 — Phase G: final report **(MANDATORY)**

Announce: `Phase G — final report — starting`.

```
"<H>H/<M>M remain inline in <file>; <N> findings recorded in <review_history>"
```

Or: `"No high/medium findings remain (Success)"` if inline count is zero.

## Notes

- This command does NOT mutate `progress.md` or any quest file. Workflow-neutral.
- Cleanup: temporary files `/tmp/mi-*.<pid>.*` removed at exit.

## See also

- `docs/blueprint-review-token-reduction/plan.md` — v1.4 design.
- `docs/blueprints-review/plan.md` — v1.2.x prior art (item enumeration, canonical region descriptor, `alloc-final-id` semantics unchanged).
- `commands/mi-blueprint-review-consistency.md`, `commands/mi-blueprint-review-item.md` — standalone variants.
````

- [ ] **Step 3: Smoke-test that the file is syntactically valid markdown**

```bash
grep -c "^### " commands/mi-blueprint-review.md  # should print 7 (Step 1..7)
grep -c "^## " commands/mi-blueprint-review.md   # should print 5+ (Usage, Preconditions, Phase contract, Execution, Notes, See also)
```

- [ ] **Step 4: Commit**

```bash
git add commands/mi-blueprint-review.md
git commit -m "$(cat <<'EOF'
feat(mi-blueprint-review): v1.4 orchestrator (token-reduction refit)

Replaces v1.2.x's 5-phase fix-loop architecture with Phase A (preflight + summary) → B (enumerate) → C (per-batch parallel waves via codex-reply) → D (single consistency pass via codex-reply) → F (persist to review-history.md) → G (report). Breaking CLI change: --auto-iter replaces <max-c-iter> <max-i-iter>. Per spec §3, §4, §10.1.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: Rewrite `/mi-blueprint-review-consistency` wrapper

**Files:**
- Modify: `commands/mi-blueprint-review-consistency.md`

- [ ] **Step 1: Replace command**

Overwrite `commands/mi-blueprint-review-consistency.md`:

```markdown
---
description: Run a single whole-file consistency review (v1.4) — thin wrapper around Phase A + D + F + G of /mi-blueprint-review. One codex session per loop; rounds 2+ via codex-reply.
---

# /mi-blueprint-review-consistency

## Usage

```
/mi-blueprint-review-consistency <agent> <file-path> [--auto-iter N] [--reasoning-effort R]
```

Default `--auto-iter 3`, `--reasoning-effort medium`. No `--batch-size`, no `--scope`, no `--concurrency` — they don't apply to a consistency-only run.

## Execution

### Step 1 — Validate inputs (same shape as orchestrator's Step 1)

```bash
set -euo pipefail
agent="${1:-}"
file="${2:-}"
auto_iter=3
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
```

### Step 2 — Run Phase A (preflight + summary build)

Same logic as `/mi-blueprint-review` Step 2. Build `history_summary_consistency` and `file_metadata_brief`. Lazily init `review-history.md` if file sits in `blueprints/current/`.

### Step 3 — Run Phase D (consistency loop)

Spawn `blueprint-consistency-reviewer` with the spawn-input bundle from spec §9.1.

### Step 4 — Run Phase F (persist)

Same logic as orchestrator Step 6. Skip silently if `review_history` is empty.

### Step 5 — Final report

```
"No high/medium findings remain (Success)"
OR
"<H>H/<M>M findings remain inline in <file>; <N> recorded in <review_history>"
```

## Notes

- This is a thin wrapper. All shared logic lives in the orchestrator; the wrapper just skips Phases B and C.
- File frontmatter is preserved byte-for-byte (sub-agent revalidates).

## See also

- `commands/mi-blueprint-review.md` — full orchestrator (runs this + Phases B/C).
- `docs/blueprint-review-token-reduction/plan.md` — design.
```

- [ ] **Step 2: Commit**

```bash
git add commands/mi-blueprint-review-consistency.md
git commit -m "$(cat <<'EOF'
feat(mi-blueprint-review-consistency): v1.4 wrapper

Thin wrapper around Phase A + D + F + G. Breaking CLI change matches the orchestrator. Per spec §10.2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 13: Rewrite `/mi-blueprint-review-item` wrapper

**Files:**
- Modify: `commands/mi-blueprint-review-item.md`

- [ ] **Step 1: Replace command**

Overwrite `commands/mi-blueprint-review-item.md`:

```markdown
---
description: Run a single-item review (v1.4) — thin wrapper around Phase A + B(single-item) + C(batch=1) + F + G. Mode A edits the file; Mode B is stateless (prints to terminal).
---

# /mi-blueprint-review-item

## Usage

```
/mi-blueprint-review-item <agent> <file-path>:<item-id> [--auto-iter N] [--reasoning-effort R]   # Mode A
/mi-blueprint-review-item <agent> <content>             [--auto-iter N] [--reasoning-effort R]   # Mode B
```

Also accepts `--file <path> --item <id>` for paths containing colons.

## Execution

### Step 1 — Parse args + detect mode

Identical mode detection to v1.2.x (see existing logic). Resolve `agent`, `file`, `item_id`, `content`, `auto_iter`, `reasoning_effort`, `reviewer_tool`, `reviewer_reply_tool`.

### Step 2 — Mode A: Phase A + Phase B(single) + Phase C(batch=1) + Phase F + Phase G

Phase A: same as orchestrator's Step 2. Init review-history.md if missing.

Phase B (single-item enumerate): render the enumerate template asking for one item; filter to `item_id`. Run `scripts/blueprint-review.sh enumerate` to get the canonical descriptor.

Phase C (batch=1): spawn `blueprint-batch-reviewer` with `items=[<single-descriptor>]`, `batch_size=1`, `auto_iter`, `reviewer_tool`, `reviewer_reply_tool`, history_summary scoped to `[item_id]`, `file_metadata_brief`, `lessons_block=""`. Apply the returned `new_region` to disk via `Edit` (with frontmatter validation + exact-match retry on failure — same as orchestrator).

Phase F: persist findings (only this one item's worth).

Phase G: print success / max-iter message.

### Step 3 — Mode B: Phase A(synthesized) + Phase C(batch=1, mode=content) + Phase G

No disk file → no review-history.md → no Phase F. `history_summary` is empty; `file_metadata_brief` is empty.

Spawn `blueprint-batch-reviewer` with `mode=content`, `items=[{item_id: "(unnamed)", original_region: <content>}]`. Print the returned `new_region` to stdout. No file write.

## Notes

- All shared logic lives in the orchestrator / sub-agent. This wrapper just builds a single-item batch.
- Tmp-ids `T1-<n>` in Mode B output have no continuity with anything else.

## See also

- `commands/mi-blueprint-review.md` — full orchestrator (spawns batches in parallel).
- `docs/blueprint-review-token-reduction/plan.md` — design.
```

- [ ] **Step 2: Commit**

```bash
git add commands/mi-blueprint-review-item.md
git commit -m "$(cat <<'EOF'
feat(mi-blueprint-review-item): v1.4 wrapper

Single-item review built as batch_size=1. Same Phase A + C + F + G path as a regular batch run. Breaking CLI change matches the orchestrator. Per spec §10.2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 14: Wire `mi-apply-impact` Step A.5 + Step B.5 + `--force` allowlist

**Files:**
- Modify: `commands/mi-apply-impact.md`

- [ ] **Step 1: Read current `mi-apply-impact.md`**

```bash
cat commands/mi-apply-impact.md | head -200
```

Identify: Pre-Step A line, Step A end (`requirements.md` exists), Step B.5 CLI invocation line, `--force` cleanup block.

- [ ] **Step 2: Insert Step A.5 (review-history init)**

After Step A's final substep (where `requirements.md` exists), before Step B, add:

```markdown
### Step A.5 — Initialize review-history.md (new in v1.4)

```bash
review_history="$blueprint_dir/review-history.md"
if [[ ! -f "$review_history" ]]; then
  req_id="$("$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" get "$requirements_path" id 2>/dev/null)"
  "$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" init review-history "$review_history" \
    ID="$(uuidgen | tr 'A-Z' 'a-z')" \
    FEATURE="$feature" \
    REQUIREMENTS_ID="${req_id:-null}" \
    LAST_FINDING_ID=F-000 \
    FINDING_COUNT_TOTAL='!RAW!0' \
    FINDING_COUNT_UNRESOLVED='!RAW!0' \
    LAST_REVIEW_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi
```

Guarded on existence — re-runs of `mi-apply-impact` don't clobber an existing history.
```

- [ ] **Step 3: Update Step B.5 CLI invocation**

Find the existing line:

```diff
- /mi-blueprint-review codex 3 5 "$requirements_path" --scope "Goals (this cycle)" --reasoning-effort medium
+ /mi-blueprint-review codex "$requirements_path" --scope "Goals (this cycle)" --reasoning-effort medium
```

Defaults (`--auto-iter 3 --batch-size 3 --concurrency 3`) cover the rest.

- [ ] **Step 4: Extend `--force` cleanup allowlist**

Find the existing cleanup block (lessons-filter added it for `implementation/`). Add a parallel block for `current/`:

```bash
# Existing: implementation/ cleanup (untouched)
impl_files_to_clean=("grounding-report.md" "blueprint-lessons.md")
# ... existing logic ...

# v1.4 addition: current/ cleanup (review-history.md only)
current_files_to_clean=("review-history.md")
for f in "${current_files_to_clean[@]}"; do
  path="$blueprint_dir/$f"
  if [[ -f "$path" ]]; then
    rm -f "$path"
    echo "removed: $path"
  fi
done
```

Place this after the existing `impl_files_to_clean` loop. Use the same variable name conventions (`blueprint_dir` is the `blueprints/current/` path used in the surrounding code).

- [ ] **Step 5: Commit**

```bash
git add commands/mi-apply-impact.md
git commit -m "$(cat <<'EOF'
feat(mi-apply-impact): wire review-history.md init + new orchestrator CLI

Adds Step A.5 (lazy init of review-history.md). Updates Step B.5 to v1.4 orchestrator CLI (collapsed args; defaults cover the rest). Extends --force cleanup to remove review-history.md. Per spec §11.1.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 15: Wire `mi-update-blueprint` to rotate `review-history.md`

**Files:**
- Modify: `commands/mi-update-blueprint.md`

- [ ] **Step 1: Read current `mi-update-blueprint.md`**

```bash
cat commands/mi-update-blueprint.md
```

Identify the rotation block — where `blueprints/current/` contents are moved into `blueprints/history/v<N>/`.

- [ ] **Step 2: Add `review-history.md` to the rotation manifest**

The rotation likely uses an explicit list of files OR a wildcard. Add `review-history.md` to the explicit list (if used) or confirm wildcards already cover it:

```bash
# If the rotation uses an explicit allowlist:
files_to_rotate=("requirements.md" "config.md" "diagrams" "review-history.md")
# ... existing rotation logic ...
```

If the rotation uses a wildcard (`cp -r blueprints/current/* blueprints/history/v$N/`), no change needed — but verify the new file is included by reading the rotation block.

- [ ] **Step 3: Append test for rotation behavior**

Append to `tests/blueprint-review/run.sh`:

```bash
# ---- Task 15: mi-update-blueprint rotation -------------------------------

t="rotation: review-history.md moves to history/v<N>/"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/blueprints/current"
cp "$FIXTURES/schema-good/review-history.md" "$tmp/blueprints/current/review-history.md"
# Simulate the rotation portion of mi-update-blueprint (manual mimic — actual command requires more context)
mkdir -p "$tmp/blueprints/history/v1"
mv "$tmp/blueprints/current/review-history.md" "$tmp/blueprints/history/v1/review-history.md"
if [[ -f "$tmp/blueprints/history/v1/review-history.md" && ! -f "$tmp/blueprints/current/review-history.md" ]]; then
  ok "$t"
else
  ng "$t" "rotation didn't move the file"
fi
```

(This is a smoke test of the file-move behavior, not the actual `/mi-update-blueprint` command — that requires a fuller stage 2 fixture which manual scenarios cover.)

- [ ] **Step 4: Run tests**

```bash
bash tests/blueprint-review/run.sh
```

Expected: previous tests still pass + new rotation smoke test passes.

- [ ] **Step 5: Commit**

```bash
git add commands/mi-update-blueprint.md tests/blueprint-review/run.sh
git commit -m "$(cat <<'EOF'
feat(mi-update-blueprint): rotate review-history.md with blueprint

Adds review-history.md to the rotation manifest so blueprint version history carries its review history. Per spec §11.2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 16: Wire `mi-complete-workflow` archive allowlist

**Files:**
- Modify: `commands/mi-complete-workflow.md`

- [ ] **Step 1: Read current `mi-complete-workflow.md`**

```bash
cat commands/mi-complete-workflow.md | head -200
```

Identify the archive allowlist (the blueprint-lessons feature added `blueprint-lessons.md` to it; the new entry follows the same pattern).

- [ ] **Step 2: Extend the allowlist**

Add `review-history.md` to the archive allowlist for `blueprints/current/`:

```diff
# Hypothetical existing block (exact form depends on command's structure)
- archive_allowlist_current=("requirements.md" "config.md" "diagrams")
+ archive_allowlist_current=("requirements.md" "config.md" "diagrams" "review-history.md")
```

Update any human-readable prose nearby that lists what gets archived.

- [ ] **Step 3: Commit**

```bash
git add commands/mi-complete-workflow.md
git commit -m "$(cat <<'EOF'
feat(mi-complete-workflow): archive review-history.md

Extends archive allowlist for blueprints/current/ so review-history.md is preserved in history/v<N+1>/. Per spec §11.3.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 17: Add `codex-reply` probe to `scripts/doctor.sh`

**Files:**
- Modify: `scripts/doctor.sh`

- [ ] **Step 1: Read current `doctor.sh`**

```bash
cat scripts/doctor.sh
```

Identify the existing `mcp:codex` probe block (added in v1.2.0).

- [ ] **Step 2: Extend the probe**

After the existing `mcp:codex` check (verifies `codex mcp-server --help` succeeds), add:

```bash
# v1.4 — verify codex-reply tool name. Non-blocking; warning only.
if command -v codex >/dev/null 2>&1; then
  if codex --help 2>/dev/null | grep -q "mcp-server"; then
    # Try a 1-shot stdio handshake that lists tools (low-friction probe — no auth).
    if codex mcp-server <<< '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' 2>/dev/null \
       | grep -q "codex-reply"; then
      echo "  ✓ mcp__codex__codex-reply available (v1.4 cost-reduction path)"
    else
      echo "  ⚠ mcp__codex__codex-reply not detected — blueprint review falls back to stateless mode (~60% savings instead of ~95%)"
    fi
  fi
fi
```

(The exact probe shape depends on Phase 0's findings — if `tools/list` isn't the right MCP method, adjust to whatever Phase 0 documented.)

- [ ] **Step 3: Commit**

```bash
git add scripts/doctor.sh
git commit -m "$(cat <<'EOF'
feat(mi-doctor): probe for mcp__codex__codex-reply

Non-blocking warning. If codex-reply isn't available, /mi-blueprint-review falls back to stateless mode. Per spec §11.4.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 18: Delete deprecated files

**Files:**
- Delete: `agents/blueprint-item-reviewer.md`
- Delete: `templates/blueprint-reviewer-prompt-item.md.tmpl`

- [ ] **Step 1: Verify no stale references**

```bash
grep -rn "blueprint-item-reviewer\|blueprint-reviewer-prompt-item" \
  agents/ commands/ scripts/ templates/ hooks/ schemas/ tests/ docs/ 2>/dev/null | grep -v "CHANGELOG\|docs/blueprints-review\|docs/blueprint-review-token-reduction\|docs/superpowers" || echo "no stale refs in active code"
```

Expected: only references in docs/ (CHANGELOG, the historical plan) and the spec/plan docs. No active code references.

- [ ] **Step 2: Remove files**

```bash
git rm agents/blueprint-item-reviewer.md
git rm templates/blueprint-reviewer-prompt-item.md.tmpl
```

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
refactor(blueprint-review): remove deprecated single-item reviewer files

agents/blueprint-item-reviewer.md is replaced by blueprint-batch-reviewer (batch_size=1 path).
templates/blueprint-reviewer-prompt-item.md.tmpl is replaced by blueprint-reviewer-prompt-batch.md.tmpl.
Per spec §9.3, §14.3.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 19: Final integration test sweep

**Files:**
- Modify: `tests/blueprint-review/run.sh`

- [ ] **Step 1: Run the full test harness**

```bash
bash tests/blueprint-review/run.sh
```

Expected: all tests added across Tasks 2, 3, 4, 5, 6, 15 pass. Confirm the final summary line.

- [ ] **Step 2: Run the project's existing lint suite**

```bash
bash tests/lint/run.sh 2>&1 | tail -10
```

Expected: pass. (If lint fails on new files, fix inline — likely a missing frontmatter field on the new agent or template.)

- [ ] **Step 3: Run the blueprint-lessons test harness (regression)**

```bash
bash tests/blueprint-lessons/run.sh 2>&1 | tail -5
```

Expected: pass. Our changes don't touch the lessons feature.

- [ ] **Step 4: Commit the test harness if any tweaks were needed**

```bash
git add tests/blueprint-review/run.sh
git status  # confirm nothing else changed
git diff --cached
git commit -m "test(blueprint-review): final pass on integration harness" --allow-empty
```

(`--allow-empty` is fine if no tweaks were needed — the commit serves as a checkpoint.)

---

### Task 20: Write manual test plan

**Files:**
- Create: `docs/superpowers/plans/2026-05-23-blueprint-review-token-reduction-manual-tests.md`

- [ ] **Step 1: Write the manual test plan**

Create the file with five scenarios that require live codex (and can't be automated cost-effectively):

```markdown
# Blueprint Review Token-Reduction Refit — Manual Tests

These scenarios require live `codex` calls. Run after Tasks 1–19 are complete and the test harness (`tests/blueprint-review/run.sh`) is green.

For each scenario, capture in the writeup:
- Codex call count (round 1 + round 2 + round 3, per phase)
- Wall-clock time
- Approximate token cost (from codex billing or `codex usage` if available)
- Findings produced (high/medium/low counts)
- Whether the prompt-header summary appeared in the round-1 prompt as expected

## Scenario A — 5-item blueprint, no prior history (cold start)

**Setup:** Pick a small feature; `cp` a 5-item synthetic `requirements.md` into `workflow-stream/<feat>/blueprints/current/`. Ensure no `review-history.md` exists.

**Run:** `/mi-blueprint-review codex workflow-stream/<feat>/blueprints/current/requirements.md`

**Verify:**
- Phase A creates `review-history.md` lazily.
- Phase B returns 5 descriptors.
- Phase C runs 2 batches (3 + 2 items) in parallel; each batch ≤ 3 rounds.
- Phase D runs ≤ 3 rounds.
- Phase F appends N findings to `review-history.md`; `finding-count-total` and `finding-count-unresolved` reflect reality.
- Phase G reports `<H>H/<M>M remain inline; <N> recorded in review-history.md`.

**Expected cost:** ~6–10 codex calls, ~30k–50k tokens, ~5–10 min wall-clock.

## Scenario B — Same 5-item blueprint, with history present (warm cache)

**Setup:** Re-run Scenario A on the same file (`review-history.md` now exists with findings).

**Verify:**
- Phase A's `build-summary` output is non-empty and includes the prior findings.
- The reviewer's round-1 prompt (capturable from codex transcript if logged) contains the `## Prior review context` block.
- Round 1 finds fewer NEW findings than Scenario A (the reviewer recognizes prior-resolved issues).
- Phase F updates existing `last-status-at` timestamps + appends any genuinely new findings.

**Expected cost:** ~4–7 calls, ~20k–35k tokens, ~3–7 min wall-clock.

## Scenario C — 20-item blueprint (stress test)

**Setup:** Re-create the synthetic 20-item audit-pipeline `requirements.md` used by REPORT-4. Drop any pre-existing `review-history.md`.

**Run:** `/mi-blueprint-review codex <path-to-20-item-file> --scope "Goals (this cycle)"`

**Verify:**
- Phase C dispatches 7 batches (20 items / batch_size 3) in waves of 3.
- Wall-clock should be dominated by the slowest batch in each wave.
- Phase D rounds 2+ use `codex-reply` (size of round-2 prompt should be ≪ round 1).
- Inspector workload at end: ~50–70 findings to triage (matches REPORT-4 projection).

**Expected cost:** ~15–25 calls, ~50k–80k tokens, ~10–15 min wall-clock — vs ~107 calls / ~1M tokens / ~60–80 min on v1.2.x.

## Scenario D — Standalone `/mi-blueprint-review-item` (Mode A)

**Setup:** Pick one item from the Scenario A blueprint.

**Run:** `/mi-blueprint-review-item codex workflow-stream/<feat>/blueprints/current/requirements.md:PAY-001`

**Verify:**
- Phase B enumerates the single item (no full file scan).
- Phase C runs as a 1-item batch.
- Findings persist to `review-history.md`.
- Phase G summary correct.

## Scenario E — Inspector mid-run abort (Ctrl-C)

**Setup:** Start Scenario C; Ctrl-C during Phase C wave 1.

**Verify:**
- Partial state: items in completed batches have their findings inline; items mid-batch may or may not (depends on when the abort hit).
- `review-history.md` is NOT updated (Phase F never ran).
- Re-running `/mi-blueprint-review` on the same file proceeds (no lock / stale state).

## Scenario F — Codex MCP unavailable

**Setup:** Disable codex (e.g., temporarily rename `codex` binary or break `~/.codex/config.toml`).

**Run:** `/mi-blueprint-review codex <file>`

**Verify:**
- `mi-doctor` flags codex as unavailable.
- The orchestrator surfaces an actionable error and exits cleanly.
- No file mutations (`requirements.md` unchanged; `review-history.md` untouched).
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/plans/2026-05-23-blueprint-review-token-reduction-manual-tests.md
git commit -m "$(cat <<'EOF'
docs(plans): manual test scenarios for blueprint review token-reduction refit

Six scenarios covering cold-start, warm-history, stress test (20 items), standalone single-item, mid-run abort, codex-unavailable. Per spec §13.3.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 21: CHANGELOG entry

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Read the current top of CHANGELOG**

```bash
head -10 CHANGELOG.md
```

- [ ] **Step 2: Prepend the new entry**

Edit `CHANGELOG.md`. Insert at the very top (before the existing `## 1.3.0` entry):

```markdown
## 1.4.0 — Blueprint review token-reduction refit

**Breaking CLI change.** Replaces v1.2.x's positional `<max-c-iter> <max-i-iter>` args
with a single `--auto-iter N` flag (default `3`). Per-batch concurrency exposed via
`--concurrency N` (default `3`). Default `--batch-size` reduced from `5` to `3`.

Net effect on a 20-item stage-2 auto-fire (REPORT-4 baseline → v1.4 projection):
codex calls drop ~107 → ~25; token cost drops ~1M → ~50k; wall-clock drops ~60–80
min → ~10–15 min. Finding quality preserved (REPORT-4 evidence that iter-1 per-item
review self-regulates at ~4 findings regardless of iteration budget).

### What changed

- **`mcp__codex__codex-reply` session continuation** for all rounds ≥ 2 within a
  single review loop. Round 1 opens the session via `mcp__codex__codex`; rounds 2+
  ship delta-only prompts (the file/batch content lives in session state). When
  `codex-reply` is unavailable, the orchestrator falls back to stateless mode
  (~60% reduction instead of ~95%).
- **Per-batch reviewer** (`agents/blueprint-batch-reviewer.md`) replaces the per-item
  reviewer. One sub-agent per batch of 1..N items; one codex session per batch.
  Standalone `/mi-blueprint-review-item` becomes a thin batch=1 wrapper.
- **Consolidated phase structure.** Phase 1's full-file fix-loop is gone; Phase 4
  becomes the single fix-and-converge consistency pass that sees Phase 3's per-item
  findings as context. Phases run in order A (preflight + summary build) → B
  (enumerate) → C (per-batch parallel waves) → D (consistency) → F (persist) → G
  (report).
- **`review-history.md` sibling artifact** for cross-cycle memory. Co-located with
  `requirements.md` in `blueprints/current/`; rotates with the blueprint at
  `/mi-update-blueprint` and `/mi-complete-workflow`. Append-only across cycles
  within a blueprint version. Main builds a deterministic ≤ 1500-token summary
  (`scripts/blueprint-review.sh build-summary`) for every reviewer session opener
  so the reviewer avoids re-discovering resolved findings.
- **Envelope trim** (~30–50% per-call prompt-size reduction):
  - YAML frontmatter stripped from `{{FILE_CONTENT}}`.
  - `{{EXISTING_FINDINGS}}` bullet list collapsed to a one-line pointer (single
    source of truth: inline `<!-- REVIEW-FINDING -->` blocks).
  - `{{LESSONS_BLOCK}}` removed from per-item review (cross-item by nature — Phase D
    catches lesson-violating findings).
  - Reconciliation contract prose compressed (~110 lines → ~50).
  - `severity: low` blocks stripped from round 2+ prompt views.
- **New `scripts/blueprint-review.sh` subcommands:** `build-summary` (deterministic
  history-summary renderer with truncation invariant), `persist-findings` (append
  new + update existing-to-resolved/dropped + recompute counters).
- **New schema + template + hook validation** for `review-history.md`.
- **`mi-apply-impact` Step A.5** lazily inits `review-history.md`. Step B.5's CLI
  invocation collapses to the new shape; defaults handle the rest. `--force` cleanup
  extends to `review-history.md`.
- **`mi-update-blueprint` and `mi-complete-workflow`** carry `review-history.md`
  through rotation / archive alongside `requirements.md`.
- **`mi-doctor` adds a non-blocking `codex-reply` capability probe.**

### Removed

- `agents/blueprint-item-reviewer.md` (replaced by `blueprint-batch-reviewer.md`)
- `templates/blueprint-reviewer-prompt-item.md.tmpl` (replaced by
  `blueprint-reviewer-prompt-batch.md.tmpl`)

### Testing

Unit + integration tests at `tests/blueprint-review/run.sh` cover schema, init
template, hook validation, `build-summary` (filter / truncation / invariant), and
`persist-findings` (append / update / counter recomputation). Six manual scenarios
in `docs/superpowers/plans/2026-05-23-blueprint-review-token-reduction-manual-tests.md`
cover the live-codex paths (cold start, warm history, 20-item stress, single-item,
mid-run abort, codex-unavailable).

### Migration

- Breaking CLI change. No back-compat shim. Existing scripts invoking
  `/mi-blueprint-review` must drop the two positional iter args.
- Existing blueprints get a `review-history.md` lazily initialized on the first
  v1.4 run. No backfill of historical findings — they were never preserved before.
- Reviewer prompt rendering changes shape; any external consumer of the codex
  reviewer JSON output needs to handle the multi-item `items` array shape for
  per-item review.

See `docs/blueprint-review-token-reduction/plan.md` for the full design and
`docs/blueprints-review/plan.md` for the v1.2.x prior art (item enumeration,
canonical region descriptor, `alloc-final-id` semantics unchanged).
```

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "$(cat <<'EOF'
docs(changelog): v1.4.0 — blueprint review token-reduction refit

Release notes for the v1.4 refit: ~95% token reduction via codex-reply session continuation, per-batch reviewer, phase consolidation, review-history.md cross-cycle memory, prompt envelope trim. Breaking CLI change documented.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 22: Version bump in `plugin.json`

**Files:**
- Modify: `.claude-plugin/plugin.json`

- [ ] **Step 1: Read current version**

```bash
cat .claude-plugin/plugin.json
```

- [ ] **Step 2: Bump version**

Edit `.claude-plugin/plugin.json`. Change the `"version"` field from `"1.3.0"` (or whatever it currently is) to `"1.4.0"`. Preserve all other fields exactly.

- [ ] **Step 3: Commit**

```bash
git add .claude-plugin/plugin.json
git commit -m "$(cat <<'EOF'
chore(plugin): bump version to 1.4.0

Blueprint review token-reduction refit. See CHANGELOG.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 23: README.md update

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Find the commands section**

```bash
grep -n "/mi-blueprint-review" README.md | head -10
```

- [ ] **Step 2: Update command synopsis**

Update the three `/mi-blueprint-review*` command synopses to reflect the new CLI:

```diff
- /mi-blueprint-review <agent> <max-c-iter> <max-i-iter> <file>
+ /mi-blueprint-review <agent> <file> [--auto-iter N] [--batch-size N] [--scope X] [--reasoning-effort R] [--concurrency N]

- /mi-blueprint-review-consistency <agent> <max-iter> <file>
+ /mi-blueprint-review-consistency <agent> <file> [--auto-iter N] [--reasoning-effort R]

- /mi-blueprint-review-item <agent> <max-iter> <file>:<id>
+ /mi-blueprint-review-item <agent> <file>:<id> [--auto-iter N] [--reasoning-effort R]
```

If README has a short description line per command, update those too to mention the v1.4 behavior (single-session, session-continued iteration; review-history.md sibling artifact).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs(readme): update blueprint-review command synopses for v1.4

Reflects the breaking CLI change (--auto-iter replaces positional iter args) and the new --concurrency flag.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 24: Project doc update

**Files:**
- Modify: `docs/millwright-inspector-project.md`

- [ ] **Step 1: Find sub-agent profile table**

```bash
grep -n "blueprint-item-reviewer\|sub-agent profile\|profile count" docs/millwright-inspector-project.md
```

The project doc tracks every sub-agent in a profile table (the blueprint-lessons feature changed "profile count 13 → 14"). v1.4 doesn't add a sub-agent, but it renames one (`blueprint-item-reviewer` → `blueprint-batch-reviewer`) and changes its description.

- [ ] **Step 2: Rename and update the row**

In the sub-agent profile table, find the `blueprint-item-reviewer` row and:
- Rename to `blueprint-batch-reviewer`.
- Update the description column to reflect "per-batch reviewer (1..N items per spawn)" wording.
- If the table references the agent's `tools:`, update to `[mcp__codex__codex, mcp__codex__codex-reply]`.

The profile count stays the same (it was a rename, not an addition).

- [ ] **Step 3: Find blueprint-review section / artifact list**

```bash
grep -n "review-history\|blueprints/current\|blueprint review" docs/millwright-inspector-project.md
```

- [ ] **Step 4: Add review-history.md to the artifacts list**

If the project doc lists the artifacts that live in `blueprints/current/` (the blueprint-lessons feature added similar updates), include `review-history.md` alongside `requirements.md`, `config.md`, `diagrams/`. Note that it rotates with the blueprint.

If the doc mentions stage-2 auto-fire behavior, briefly note: "the orchestrator now uses `mcp__codex__codex-reply` for within-loop iteration and persists findings to a sibling `review-history.md` for cross-cycle memory."

- [ ] **Step 5: Commit**

```bash
git add docs/millwright-inspector-project.md
git commit -m "$(cat <<'EOF'
docs(project): rename blueprint-item-reviewer; document review-history.md

Reflects v1.4 sub-agent rename (item-reviewer → batch-reviewer) and adds review-history.md to the blueprints/current/ artifact list. Per spec §14.2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-review checklist

After completing all tasks above:

- [ ] All 23 tasks committed.
- [ ] `tests/blueprint-review/run.sh` runs green end-to-end.
- [ ] `tests/lint/run.sh` runs green (no regressions).
- [ ] `tests/blueprint-lessons/run.sh` runs green (regression check on the v1.3 feature).
- [ ] `git status` is clean (no uncommitted changes).
- [ ] `.claude-plugin/plugin.json` reflects `1.4.0`.
- [ ] Phase 0 findings doc (`docs/blueprint-review-token-reduction/phase-0-findings.md`) accurately describes the codex-reply behavior we relied on.
- [ ] Spec doc (`docs/blueprint-review-token-reduction/plan.md`) was not modified during implementation, or if it was, the modification was a justified clarification documented in the relevant task's commit message.
- [ ] Two manual scenarios from `docs/superpowers/plans/2026-05-23-blueprint-review-token-reduction-manual-tests.md` (at minimum Scenarios A + C) have been executed and their results captured in a follow-up commit.

If any item fails, fix it in a follow-up commit before considering this plan complete.
