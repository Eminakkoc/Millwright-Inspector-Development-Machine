# Blueprint Review Token-Reduction Refit — Manual Tests

These scenarios require live `codex` calls. Run after Tasks 1–19 of the implementation plan are complete and the test harness (`tests/blueprint-review/run.sh`) is green.

For each scenario, capture in the writeup:
- Codex call count (round 1 + round 2 + round 3, per phase)
- Wall-clock time
- Approximate token cost (from codex billing or `codex usage` if available)
- Findings produced (high/medium/low counts)
- Whether the prompt-header summary appeared in the round-1 prompt as expected
- Whether the `threadId` from round 1 was reused by `mcp__codex__codex-reply` in rounds 2+ (vs degraded to a fresh `codex` call)

## Scenario A — 5-item blueprint, no prior history (cold start)

**Setup:** Pick a small feature; `cp` a 5-item synthetic `requirements.md` into `workflow-stream/<feat>/blueprints/current/`. Ensure no `review-history.md` exists.

**Run:** `/mi-blueprint-review codex workflow-stream/<feat>/blueprints/current/requirements.md`

**Verify:**
- Phase A creates `review-history.md` lazily; `frontmatter.sh validate` passes on the fresh file.
- Phase B returns 5 descriptors.
- Phase C runs 2 batches (3 + 2 items) in parallel; each batch ≤ 3 rounds.
- Phase D runs ≤ 3 rounds.
- Phase F appends N findings to `review-history.md`; `finding-count-total` and `finding-count-unresolved` reflect reality.
- Phase G reports `<H>H/<M>M remain inline; <N> recorded in review-history.md`.

**Expected cost:** ~6–10 codex calls, ~30k–50k tokens, ~5–10 min wall-clock.

## Scenario B — Same 5-item blueprint, with history present (warm cache)

**Setup:** Re-run Scenario A on the same file (`review-history.md` now exists with findings).

**Verify:**
- Phase A's `build-summary` output is non-empty and includes the prior findings (manually inspect: `scripts/blueprint-review.sh build-summary <history> consistency`).
- The reviewer's round-1 prompt (capturable from codex transcript if logged) contains the `## Prior review context` block.
- Round 1 finds fewer NEW findings than Scenario A (the reviewer recognizes prior-resolved issues and emits `status: still-present` or `resolved` in `existing[]`).
- Phase F updates existing `last-status-at` timestamps + appends any genuinely new findings.

**Expected cost:** ~4–7 calls, ~20k–35k tokens, ~3–7 min wall-clock.

## Scenario C — 20-item blueprint (stress test)

**Setup:** Re-create the synthetic 20-item audit-pipeline `requirements.md` used by REPORT-4 (`feature/test-plugin/reports/REPORT-4.md`). Drop any pre-existing `review-history.md`.

**Run:** `/mi-blueprint-review codex <path-to-20-item-file> --scope "Goals (this cycle)"`

**Verify:**
- Phase C dispatches 7 batches (20 items / batch_size 3, rounded up) in waves of 3 (concurrency default).
- Wall-clock should be dominated by the slowest batch in each wave (not by N × per-call latency).
- Phase D rounds 2+ use `mcp__codex__codex-reply` — the round-2 prompt should be ≪ round 1 (mostly the diff + "re-evaluate" instruction).
- Inspector workload at end: ~50–70 findings to triage (matches REPORT-4 projection).

**Expected cost:** ~15–25 calls, ~50k–80k tokens, ~10–15 min wall-clock — vs ~107 calls / ~1M tokens / ~60–80 min on v1.2.x.

## Scenario D — Standalone `/mi-blueprint-review-item` (Mode A)

**Setup:** Pick one item from the Scenario A blueprint (use an ID like `PAY-001`).

**Run:** `/mi-blueprint-review-item codex workflow-stream/<feat>/blueprints/current/requirements.md:PAY-001`

**Verify:**
- Phase B enumerates ALL items but the wrapper filters to the single PAY-001 descriptor.
- Phase C runs as a 1-item batch (`batch_id: B1`, `items: [PAY-001 only]`).
- Findings persist to `review-history.md` (only PAY-001's worth; other items in history are untouched).
- Phase G summary correct.

## Scenario E — Inspector mid-run abort (Ctrl-C)

**Setup:** Start Scenario C; Ctrl-C during Phase C wave 1.

**Verify:**
- Partial state: items in completed batches have their findings inline (Edits committed before abort); items mid-batch may or may not (depends on when the abort hit).
- `review-history.md` is NOT updated (Phase F never ran — the file's `last-review-at` matches the pre-run timestamp).
- Re-running `/mi-blueprint-review` on the same file proceeds (no lock / stale state); inline findings from completed batches feed into the next run's Phase A summary build.

## Scenario F — Codex MCP unavailable

**Setup:** Disable codex (e.g., temporarily rename `codex` binary or break `~/.codex/config.toml`).

**Run:** `/mi-blueprint-review codex <file>`

**Verify:**
- `mi-doctor` flags codex as unavailable (with the v1.4 codex-reply note absent).
- The orchestrator surfaces an actionable error early (before any file mutation) and exits cleanly.
- No file mutations (`requirements.md` unchanged; `review-history.md` untouched).

## Scenario G — Session-expiry fallback

**Setup:** Run Scenario A with a deliberately-stale `threadId` injected into the second-round prompt path. (This may require manual intervention in the sub-agent prompt — alternative: wait long enough between rounds for codex's idle-expiry to fire, which Phase 0 did not measure.)

**Verify:**
- The sub-agent detects the `Session not found for thread_id` error from `codex-reply`.
- Round N degrades to a fresh `mcp__codex__codex` call with full prompt context.
- A `round-N-degraded: session-expired` line appears in the sub-agent's `Findings / risks`.
- Subsequent rounds (if any) use the new threadId from the degraded round.

This scenario tests the resilience path documented in `docs/blueprint-review-token-reduction/plan.md` §12.2 R1 (session expiry).
