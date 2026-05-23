# Phase 0 — codex-reply MCP shape findings

**Date:** 2026-05-23
**Codex CLI version:** `codex-cli 0.133.0`
**MCP tool names confirmed:** `mcp__codex__codex`, `mcp__codex__codex-reply`

## Decision

✅ **Plan proceeds as designed.** Session continuation works as expected; the v1.4 cost-reduction strategy is viable.

## Round-1 response shape (`mcp__codex__codex`)

Session identifier field: **`threadId`** (camelCase), at the **top level** of the response object.

Response shape:

```json
{
  "threadId": "<uuid>",
  "content": "<model's reply text>"
}
```

Example (from the actual probe):

```json
{"threadId":"019e5699-19e7-7002-828b-444f261646b6","content":"OK-PROBE-1"}
```

### Tool parameters (`mcp__codex__codex`)

Required: `prompt: string`.

Notable optional parameters used by v1.4:
- `sandbox: "read-only" | "workspace-write" | "danger-full-access"` — review calls should use `"read-only"` (codex must not write files).
- `approval-policy: "untrusted" | "on-failure" | "on-request" | "never"` — review calls should use `"never"` (no inline approval prompts).
- `config: object` — free-form. `reasoning_effort` is passed here as **`model_reasoning_effort`** (see below).
- `model: string` — override (e.g., `"gpt-5.2-codex"`). Defaults to the configured codex model.

**Important:** `reasoning_effort` is **NOT** a top-level parameter. It must be passed via `config.model_reasoning_effort`. Example:

```jsonc
{
  "prompt": "...",
  "sandbox": "read-only",
  "approval-policy": "never",
  "config": { "model_reasoning_effort": "low" }
}
```

## Round-2+ behavior (`mcp__codex__codex-reply`)

✅ **Continuation works.** Codex retains full prior-turn context within the same `threadId`.

Test sequence:
1. Round 1 prompt: `"Reply with the exact string OK-PROBE-1 and nothing else."` → response: `OK-PROBE-1` + `threadId: 019e5699-...`
2. Round 2 prompt (via codex-reply): `"What did you say in your previous response? Reply with only that exact string, then add the suffix -REPLIED."` → response: `OK-PROBE-1-REPLIED`

Codex correctly recalled `OK-PROBE-1` and appended `-REPLIED`, confirming session memory.

### Tool parameters (`mcp__codex__codex-reply`)

Required: `threadId: string`, `prompt: string`.

**No other parameters accepted.** Specifically:
- ❌ No `reasoning_effort` / `config` parameter — session-wide settings are locked from the round-1 call.
- ❌ No `sandbox` / `approval-policy` override.
- ❌ No `model` override.
- The deprecated `conversationId` field is still accepted (back-compat alias for `threadId`); v1.4 uses `threadId`.

**Implication for the plan:** The v1.4 spec text saying "pass `reasoning_effort` on every call" is **incorrect for rounds 2+**. The right interpretation is: `reasoning_effort` is set once at session open (round 1's `config.model_reasoning_effort`) and persists for the life of the thread. Sub-agents must pass `reasoning_effort` only to round 1; rounds 2+ inherit it from session state.

## Session-expiry / invalid-thread behavior

Invalid `threadId` returns a hard error:

```
Session not found for thread_id: 00000000-0000-0000-0000-000000000000
```

The sub-agents' session-expiry fallback (defined in `agents/blueprint-{consistency,batch}-reviewer.md`) MUST match on the string `"Session not found for thread_id"` (or substring `"Session not found"`) to detect this case and degrade to a fresh stateless `mcp__codex__codex` call.

### Session timeout / idle expiry

⚠ **Not tested in this run.** Verifying idle-expiry behavior requires waiting ~5+ minutes between rounds, which exceeds the Phase 0 budget for a single probe pass. Defer to manual Scenario E (mid-run abort) variant or a dedicated probe later.

Conservative assumption for v1.4: treat any error containing `"Session not found"` as expiry and fall back to stateless mode for that round. If empirical use shows sessions expire faster than expected (e.g., < 1 min), revisit the codex configuration (`session_ttl` or similar) before increasing `--auto-iter`.

## Adjustments to the v1.4 plan

Two text edits are needed in the spec / plan but not implementation:

1. **`docs/blueprint-review-token-reduction/plan.md` §7.1** — wherever it says "pass `reasoning_effort` to `codex-reply`", clarify that `reasoning_effort` is round-1-only via `config.model_reasoning_effort` and is session-wide.
2. **`docs/superpowers/plans/2026-05-23-blueprint-review-token-reduction.md` Task 9 + Task 10** — same correction in the sub-agent input lists. Drop `reasoning_effort` from the codex-reply call signatures; keep it on round-1 `codex` calls.

These adjustments do not change the architecture or cost win — they're just MCP-shape corrections.

## Cost / safety notes

- Round-1 call cost: trivial (3-token prompt + 11-token response at `model_reasoning_effort: low`).
- Probe ran with `sandbox: read-only` + `approval-policy: never` — no file mutations, no shell commands.
- Total Phase 0 cost: 3 codex calls (round 1 + valid continuation + invalid-threadId error probe).
