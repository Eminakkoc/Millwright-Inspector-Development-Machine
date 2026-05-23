# Blueprint Review — Token-Reduction Refit — Plan & Design

**Status:** Pre-implementation. Phase 0 (`mcp__codex__codex-reply` shape verification) must precede any other work.

**Target version:** `v1.4.0` (minor — breaking CLI change documented; replaces one sub-agent, reshapes another, consolidates two prompt templates into one, adds one artifact + schema + script subcommands).

**Supersedes parts of:** `docs/blueprints-review/plan.md` (v1.2.x design). The original orchestration, sub-agent split, and per-iteration loop semantics are replaced by the design below. Item enumeration (§5.4 of v1.2.x), the canonical region descriptor, `alloc-final-id`, the YAML `<!-- REVIEW-FINDING -->` inline format, and the file-mutation contract (§9 of v1.2.x) carry forward unchanged.

---

## 1. Motivation & summary

The v1.2.x blueprint review system works but is expensive: a full stage-2 auto-fire on a 20-item `requirements.md` at `reasoning_effort=medium` projects to ~47 codex calls / ~400–500k tokens / ~30–40 min wall-clock (REPORT-4). The dominant cost is structural, not prompt-quality:

- Every codex call is stateless — the full file content + scaffold + lessons block is re-sent every iteration.
- Per-item review fires one codex call per item per iteration (up to 100 calls for 20 items × 5 iter).
- Phase 1 (initial consistency loop) and Phase 4 (final consistency loop) overlap heavily (REPORT-1 §P2) — two full-file loops per run.
- `<!-- REVIEW-FINDING -->` blocks live in the file body AND are bullet-listed in `{{EXISTING_FINDINGS}}` — same info, sent twice.
- The reviewer has no cross-cycle memory; findings resolved in a prior cycle can be re-discovered in the next.

This refit cuts the structural cost while preserving the existing finding quality (REPORT-4 evidence that iter-1 self-regulates at ~4 findings per item).

**Headline numbers (20-item file, new defaults `--auto-iter 3 --batch-size 3`):**

| Metric | v1.2.x worst case | v1.4 worst case | v1.4 best case |
| --- | ---: | ---: | ---: |
| Codex calls | 107 | 25 | 9 |
| Token cost (rough) | ~1M | ~50k | ~40k |
| Wall-clock | ~60–80 min | ~10–15 min | ~5–8 min |

The 95%+ token reduction comes from four levers:

1. **`mcp__codex__codex-reply` session continuation** for all within-loop iterations after round 1.
2. **Batched per-item review** — one codex call per batch of N items, not one per item.
3. **Phase consolidation** — drop the redundant initial consistency loop; the final consistency pass uses session continuation.
4. **Find-and-fix-by-default with optional auto-iter** — `--auto-iter` budget collapses from two separate flags to one.

A new sibling artifact `review-history.md` (co-located with `requirements.md` in `blueprints/current/`) provides cross-cycle memory: every finding ever seen is appended with its resolution. A deterministic ≤ 1500-token summary is injected into the reviewer's session opener so the reviewer avoids re-discovering resolved findings.

---

## 2. Scope decisions (confirmed)

| Decision | Outcome |
| --- | --- |
| How iteration works within a loop | **Per-batch (Phase C) and single-session (Phase D).** A single codex session per batch / per consistency pass. Round 1 is `mcp__codex__codex`; rounds 2+ are `mcp__codex__codex-reply` with delta-only payloads. |
| Default iteration budget | **`--auto-iter 3` everywhere.** The two old flags (`max-consistency-iter`, `max-item-iter`) collapse into one. |
| Default batch size | **`--batch-size 3`.** Five items in one batch is also valid; 3 chosen for tighter per-call signal. |
| Default parallelism | **`--concurrency 3` batches in parallel** in Phase C. Each batch owns its own codex session. |
| Phase ordering | **Per-item first, then file-wide consistency.** Inverts v1.2.x's order. Consistency sees per-item findings as inline context. |
| Number of phases | **Three codex phases (B, C, D) + three non-codex phases (A, F, G).** Phase A = preflight + summary build; Phase B = enumeration; Phase C = per-item batched; Phase D = consistency; Phase F = persist to history; Phase G = report. The apply step is interleaved — it runs in main between Phase C sub-agent returns and within each sub-agent between `codex-reply` rounds — and is **not** a standalone phase. (Letter `E` is intentionally unused so the historical "Phase 5" → Phase G mapping stays unambiguous.) |
| Cross-cycle memory | **`review-history.md` sibling artifact**, co-located with `requirements.md`. Append-only across cycles within a blueprint version; rotates with the blueprint. |
| Prompt-header summary budget | **1500 tokens, single budget across all session openers**, with a truncation invariant that protects unresolved-high-severity and current-item-tied findings. |
| Where the summary is built | **Main**, deterministically from `review-history.md`. History is loaded in Phase A but the summary itself is rendered **just-in-time per session opener** (Phase A has no item IDs yet — those come from Phase B). The orchestrator builds one summary per Phase C batch (scope = batch items) and one for the Phase D session (scope = all items in file). `file_item_ids` from Phase B is reused across all openers as the truncation-invariant protection set. |
| Auto-fix posture | **On by default (`--auto-iter 3`).** Rounds 2+ apply fixes (in-memory in the sub-agent) and re-evaluate via `codex-reply`. To turn auto-fix off, invoke with `--auto-iter 1`. |
| Per-item sub-agent contract | **One sub-agent per batch** (replaces today's one-per-item). Strictly read-only on the disk file. Reshapes to a multi-item Payload JSON return. |
| Consistency sub-agent contract | **One sub-agent per orchestrator run**, drives a single codex session with up to `--auto-iter` rounds via `codex-reply`. Continues to write the disk file directly between rounds (serial; no race). |
| CLI compatibility | **Breaking change.** v1.2.x positional args (`<max-c-iter> <max-i-iter>`) replaced by `--auto-iter`. No back-compat shim; documented in CHANGELOG. |
| Lessons block in per-item review | **Kept** (same as v1.2.x). v1.3.0 just shipped blueprint-lessons injection at stage 2 specifically so per-item review honors prior PR lessons — removing it here would silently regress that feature. The token cost (~500–2k per batch session opener) is paid once per session thanks to session continuation, so the lever is no longer attractive even on cost grounds. |
| Frontmatter in file content sent to reviewer | **Stripped** before being inserted into the prompt. The reviewer is told it cannot touch frontmatter; sending it is pure cost. File-metadata briefing carries the only frontmatter fields that mattered. |
| Single source of truth for existing findings | **The inline `<!-- REVIEW-FINDING -->` blocks** in file/batch content. The `{{EXISTING_FINDINGS}}` bullet list is replaced with a one-line pointer. |
| Item enumeration, region descriptor, `alloc-final-id`, frontmatter byte-equality | **Unchanged from v1.2.x.** All carry forward. |

---

## 3. End-to-end flow

```
inspector: /mi-blueprint-review codex path/to/requirements.md
            [--auto-iter 3] [--batch-size 3] [--scope X] [--reasoning-effort medium] [--concurrency 3]
   │
   ├─ Phase A — preflight (no codex)
   │     ├─ Codex availability gate — probe codex MCP via `doctor.sh --format=json`;
   │     │     on missing, prompt inspector (install | skip) and continue only on
   │     │     install-then-rerun OR exit cleanly on skip. Runs BEFORE any other
   │     │     Phase A step so a skip leaves zero state on disk. See §11.5.
   │     ├─ Validate inputs; resolve reviewer tool; resolve lessons_block (sibling-detection)
   │     ├─ Init review-history.md if absent (template + frontmatter backfill)
   │     └─ Load review-history.md into memory; parse findings (no summary rendered yet —
   │           summary requires file_item_ids, which only exists after Phase B)
   │
   ├─ Phase B — item enumeration (1 codex call)
   │     ├─ mcp__codex__codex with enumerate prompt → [{id, anchor_line, occurrence_index}]
   │     ├─ scripts/blueprint-review.sh enumerate → canonical descriptors
   │     └─ Main caches file_item_ids = [d.id for d in descriptors]; reused as the
   │           protection set by every summary built in Phase C / Phase D (see §6.2, §6.5)
   │
   ├─ Phase C — per-item batched (waves of --concurrency batches; each batch up to --auto-iter rounds)
   │     ├─ For each batch about to spawn, main builds a batch-specific summary
   │     │     via `scripts/blueprint-review.sh build-summary` with scope=batch_item_ids
   │     │     and file_item_ids=<all items from Phase B>; passed verbatim to the sub-agent.
   │     ├─ Wave 1: dispatch up to 3 blueprint-batch-reviewer sub-agents in parallel
   │     │     each batch owns its own codex session:
   │     │       round 1: mcp__codex__codex (full opener: scaffold + brief + summary + payload)
   │     │       in-memory apply by sub-agent
   │     │       round 2: mcp__codex__codex-reply (delta only)
   │     │       in-memory apply by sub-agent
   │     │       round 3: mcp__codex__codex-reply final pass; stop-on-stable may fire earlier
   │     ├─ collect Payloads; main serializes write-back to disk (Edit + frontmatter validation)
   │     ├─ Wave 2..N: continue until all batches done
   │     └─ Max-iter inspector prompt (see §7.8) — if ANY batch exited via
   │           `partial; reason: max-iter` with unresolved high/medium findings,
   │           aggregate and prompt once: "K batches hit max-iter (N unresolved
   │           H/M). Run another --auto-iter cycle on those batches? (y/n)"
   │           On 'y': re-spawn only the unconverged batches with the same
   │           --auto-iter budget against the file's current state, then re-evaluate
   │           the prompt. On 'n' (or env-var suppressed / no TTY): continue.
   │
   ├─ Phase D — final consistency (1 sub-agent, 1 session, up to --auto-iter rounds)
   │     ├─ Main builds the Phase D summary just before spawn via build-summary with
   │     │     scope=file_item_ids and file_item_ids=<same set> (consistency reviews
   │     │     the whole file, so scope == file). Passed verbatim to the sub-agent.
   │     ├─ same iteration shape as a Phase C batch (round 1 = codex; rounds 2+ = codex-reply
   │     │     with delta-only) but operates on the whole file AND the sub-agent itself
   │     │     writes the file to disk at the end of each round (serial; matches v1.2.x).
   │     │     Main does NOT write the file in Phase D — only validates frontmatter.
   │     └─ Max-iter inspector prompt (see §7.8) — if Phase D exited via
   │           `partial; reason: max-iter` with unresolved high/medium findings,
   │           prompt: "Consistency loop hit max-iter (N unresolved H/M). Run
   │           another? (y/n)". On 'y': re-spawn Phase D against current file
   │           state, then re-evaluate the prompt. On 'n' (or suppressed): continue.
   │
   ├─ Phase F — persist to review-history.md (no codex; main writes)
   │     ├─ Aggregate per-Payload existing_transitions across all Phase C batches and
   │     │     Phase D. For each transition: update that history entry's last-status /
   │     │     last-status-at / resolved_by_change. See §8.4 status-enum table.
   │     ├─ Compute the "dropped" set: prior history IDs in scope this run that did NOT
   │     │     appear in any Payload's existing_transitions. Mark these last-status: dropped.
   │     ├─ Aggregate remaining_findings; for each ID not already in review-history.md,
   │     │     append a new ## F-NNN section with last-status: still-present.
   │     └─ Recompute frontmatter counters (finding-count-total, finding-count-unresolved,
   │           last-review-at, last-finding-id).
   │
   └─ Phase G — final report
         "<H>H/<M>M remain inline; <N> findings recorded in review-history.md"
```

**Apply step (not a phase).** Letter `E` is unused on purpose; "apply" is an interleaved step, not a phase. There are **three** distinct apply sites — Phase C and Phase D differ in who owns the disk write:

1. **Sub-agent in-memory apply (both phases)** — between *its own* `codex-reply` rounds, the sub-agent mutates its working copy so it can compute the next round's delta prompt. No disk I/O.
2. **Phase C — main on-disk apply (between waves)** — Phase C sub-agents are strictly read-only on disk (§9.2). After each wave returns, main writes the final working copies to disk, serialized by `start_offset`, with frontmatter validation between writes. Sub-agents NEVER touch the disk in Phase C.
3. **Phase D — consistency sub-agent on-disk apply (between rounds)** — Phase D's consistency sub-agent writes the file to disk at the end of each round (carried forward verbatim from v1.2.x; safe because the consistency loop is single-threaded — no race). Main does NOT write the file in Phase D.

The asymmetry is intentional: Phase C parallelism requires main as the single writer to avoid races; Phase D is serial, so the existing v1.2.x serial-write contract is preserved unchanged.

Standalone commands (`/mi-blueprint-review-consistency`, `/mi-blueprint-review-item`) become thin wrappers around Phase D and Phase C with batch=1 respectively.

---

## 4. Phase mapping: v1.2.x → v1.4

| v1.2.x | v1.4 | What changes |
| --- | --- | --- |
| Phase 1 — initial consistency fix-loop | **gone** | Its work folds into Phase A preflight (history read) + Phase D (the single consistency loop after per-item). |
| Phase 2 — item enumeration | **Phase B** | Effectively unchanged. |
| Phase 3 — per-item batched fix-loops (one sub-agent per item) | **Phase C** | Sub-agent shape: one-per-batch, not one-per-item. Iteration per-batch via `codex-reply`. Batches run in parallel waves. Per-loop y/n max-iter prompt aggregates across batches (one prompt, not per-item) — see §7.8. |
| Phase 4 — final consistency fix-loop | **Phase D** | Single sub-agent, single codex session, up to `--auto-iter` rounds via `codex-reply`. Sees Phase C's findings already inline. Per-loop y/n max-iter prompt preserved verbatim from v1.2.x — see §7.8. |
| Phase 5 — final report | **Phase G** | Adds a `review-history.md` updated/appended count line. |
| (none) | **Phase A** | New. Preflight + summary build + history init. |
| (none) | **Phase F** | New. Persist all run findings to `review-history.md`. |
| (none) | _no phase_ | The apply step is interleaved (main between Phase C waves; sub-agent between rounds), not a standalone phase. See §3. |

---

## 5. `review-history.md` schema and lifecycle

### 5.1 Location

Sibling to `requirements.md` in `blueprints/current/`. Rotates with the blueprint:

- `/mi-update-blueprint` rotates `blueprints/current/` into `blueprints/history/v<N>/`; `review-history.md` goes along.
- `/mi-complete-workflow` archives `current/` into `blueprints/history/v<N+1>/`; same.
- Mid-cycle regen via `/mi-update-blueprint` resets history (new `current/` initialized empty). Intentional — the regen is a meaningful reset.

### 5.2 Schema

`schemas/review-history.schema.yaml` (new). Frontmatter:

```yaml
id: <uuid>
feature: <slug>
requirements-id: <requirements.md's frontmatter id>
last-finding-id: F-NNN              # lifetime-monotonic; mirrors requirements.md's
finding-count-total: <int>
finding-count-unresolved: <int>
last-review-at: <ISO-8601 UTC>
```

Body shape:

```markdown
# Review history — <feature>

## F-NNN
- severity: high | medium | low
- phase: consistency | item
- target: <item-id> | file
- first-seen: <ISO-8601> (cycle <slug>, iter <N>)
- last-status: still-present | resolved | dropped
- last-status-at: <ISO-8601>
- resolved_by_change: "<one-line description of edit>"     # required iff last-status=resolved
- finding: |
    <verbatim from review>
- suggested-fix: |
    <verbatim from review>

## F-NNN+1
...
```

Sections appear in lifetime-monotonic ID order (append-only). `last-status: dropped` distinguishes "finding disappeared without a recorded resolution" from "finding was concretely resolved" — useful for inspector audit.

### 5.3 Frontmatter ownership

- **Main owns** every frontmatter field: `id`, `feature`, `requirements-id`, `last-finding-id`, `finding-count-total`, `finding-count-unresolved`, `last-review-at`.
- **Main owns the body** — appends `## F-NNN` sections in Phase F; updates `last-status` + `last-status-at` + `resolved_by_change` lines of existing sections.
- **Sub-agents never touch this file.** Sub-agents return findings via Payload JSON; main does all `review-history.md` mutation in Phase F.

### 5.4 Init template

`templates/review-history.md.tmpl` (new), mirrors `blueprint-lessons.md.tmpl` shape:

```markdown
---
id: {{UUID}}
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

`{{KEY}}` placeholder convention matches `templates/blueprint-lessons.md.tmpl` (and every other template under `templates/`). The `!RAW!` sentinel is **not** part of the template body — it belongs on the VALUE side of the KEY=VAL pairs passed to `frontmatter.sh init` for integer-typed fields (see §11.1 for the canonical call). `{{UUID}}` is auto-generated by `frontmatter.sh init`; callers do not pass `ID=`/`UUID=` themselves.

### 5.5 Lifecycle hooks

- `mi-apply-impact` Step A.5 (new, after `requirements.md` exists): init `review-history.md` if absent; backfill `requirements-id` to match.
- `mi-apply-impact --force` cleanup: **no allowlist change required.** `review-history.md` lives in `blueprints/current/` next to `requirements.md`, and the existing `--force` path already wipes every entry inside `current/` (see `commands/mi-apply-impact.md` lines 86–88). The separate stage-2 cleanup loop for `implementation/` artifacts (grounding-report.md, blueprint-lessons.md) is not extended either, since review-history.md does not live under `implementation/`.
- `mi-update-blueprint`: rotation copies `review-history.md` alongside `requirements.md`.
- `mi-complete-workflow`: archive allowlist extended to carry `review-history.md` into `history/v<N+1>/`.
- `hooks/validate-on-write.sh`: extends to validate `review-history.md` against the new schema.

### 5.6 Migration

- Existing blueprints without a `review-history.md` get one initialized lazily at next `/mi-blueprint-review` invocation (init-if-missing in Phase A).
- **No backfill** of resolved history is possible — those findings were never preserved before.
- **Inline `<!-- REVIEW-FINDING -->` blocks ARE migrated.** When Phase A's lazy init creates a fresh `review-history.md` AND the file under review already contains one or more inline `<!-- REVIEW-FINDING -->` blocks, the orchestrator runs `scripts/blueprint-review.sh migrate-inline-findings <file> <history-file>` immediately after init. The subcommand:
  1. Parses every inline block via `scripts/blueprint-review.sh parse-findings` (existing).
  2. For each block, appends a `## F-NNN` section to the new history file with `last-status: still-present`, `first-seen: <now>` (UTC, marked as `(synthetic; pre-history finding)`), and the verbatim `finding` / `suggested-fix` text.
  3. Recomputes the history file's `last-finding-id`, `finding-count-total`, and `finding-count-unresolved` frontmatter counters.
  4. **Leaves the inline blocks in place** — they remain authoritative in the file body; history is for cross-cycle anchoring only.
- If the inline IDs are tmp-form (`T1-1` etc., from a prior partial run), they are normalized to `F-NNN` via `alloc-final-id` before being recorded in history, and the file is rewritten in place to match.

**Frontmatter contract during migration (relaxed):** The `alloc-final-id` subcommand mutates `last-finding-id` in the file's YAML frontmatter as part of normal operation (see `scripts/blueprint-review.sh` lines 195–217). During the one-shot migration step, the standard byte-equality check is relaxed for `last-finding-id` ONLY — every other frontmatter field must remain byte-for-byte identical. The migration subcommand validates this explicitly (diff frontmatter except for `last-finding-id` line; abort if any other field changed). Once migration completes, the normal byte-equality contract resumes for all subsequent reviewer-driven writes.

---

## 6. Prompt-header summary derivation

### 6.1 Purpose

Carries cross-cycle memory: "we already considered X, here's how it was resolved." Sent once per codex session in the opening prompt; rounds 2+ inherit it from session state (zero re-send cost).

### 6.2 Algorithm (deterministic, no LLM)

```python
def build_summary(history_findings, phase, scope_ids, file_item_ids, budget=1500):
    """
    Args:
        history_findings: every finding currently in review-history.md
        phase: "consistency" (Phase D) or "batch" (Phase C)
        scope_ids: item IDs in scope for THIS session opener
                   - Phase C batch: the item IDs in this batch only
                   - Phase D consistency: every item ID currently present in the file
                     (NOT empty — the consistency loop reviews the whole file, so
                      every present item is "in scope" for relevance filtering)
        file_item_ids: every item ID currently present in the file under review
                       (used by the truncation invariant for both phases — see below).
                       For Phase D, scope_ids and file_item_ids are typically identical.
        budget: soft token budget (1500); see §6.4 for overrun semantics
    """
    # Relevance filter — same shape for both phases now that scope_ids is
    # phase-appropriate. File-level findings always pass; item-level findings
    # pass when their target is in scope for this session.
    relevant = [f for f in history_findings
                if f.target == "file" or f.target in scope_ids]

    # Two buckets
    unresolved = [f for f in relevant if f.last_status != "resolved"]
    resolved   = [f for f in relevant if f.last_status == "resolved"]

    unresolved.sort(key=lambda f: (severity_rank(f.severity), -f.first_seen_ts))
    resolved.sort(key=lambda f: -f.last_status_at_ts)

    # Truncation invariant: never drop unresolved-high; protect resolutions
    # whose target is an item currently in the file (so the reviewer keeps
    # seeing "we already considered X for AUD-013" even when AUD-013 isn't
    # in the immediate Phase C batch).
    protected_resolved = [f for f in resolved if f.target in file_item_ids]
    other_resolved     = [f for f in resolved if f not in protected_resolved]

    block = render(unresolved, protected_resolved + other_resolved)
    while token_count(block) > budget:
        if other_resolved:
            other_resolved.pop()  # drop oldest unprotected resolved first
        elif unresolved_lows := [f for f in unresolved if f.severity == "low"]:
            unresolved.remove(unresolved_lows[-1])  # drop oldest low
        else:
            break  # accept slight overrun before dropping critical context
        block = render(unresolved, protected_resolved + other_resolved)

    return block
```

**Caller responsibilities (orchestrator, Phase A).** Main computes `file_item_ids` once per run by enumerating the file under review (cached for all session openers). For each session opener it then passes:

- Phase C batch session: `scope_ids = <this batch's item IDs>`, `file_item_ids = <all items in file>`.
- Phase D consistency session: `scope_ids = file_item_ids = <all items in file>` (so the file-wide loop sees every prior finding whose target is still in the spec, not just file-level ones).

### 6.3 Rendered shape

```markdown
## Prior review context (review-history.md)

Currently unresolved (verify still in spec; reconcile per the contract):
- F-007 [medium, file]: Backlog metric source ambiguous (AUD-018 vs AUD-017).
- F-012 [medium, AUD-013]: Write authz unspecified for POST /audit/events.

Recently resolved (do NOT re-flag unless underlying content has regressed):
- F-001 [resolved 2026-05-21, AUD-002]: Kafka publish-failure → retry-with-backoff + dead-letter.
- F-005 [resolved 2026-05-22, AUD-006]: ClickHouse contract → linked to schemas/audit_events.yaml.
- (8 more older resolutions omitted)
```

For Phase C batches, the section heading reads `## Prior review context — relevant to this batch` and the filter scopes to that batch's item IDs + `target: file`.

### 6.4 Empty cases

If `review-history.md` is empty OR no findings pass the relevance filter, the entire block is **omitted** from the prompt (no stray heading). The session opener proceeds with scaffold + file-metadata-brief + work payload only.

### 6.5 Helper

New subcommand:

```
scripts/blueprint-review.sh build-summary <history-file> <phase> \
    [--scope-id <id>]... \
    [--file-item-id <id>]...
```

Does parsing, filtering, rendering, and budget enforcement per §6.2. The caller passes:
- `--scope-id` (repeatable) — item IDs in scope for this session opener (this Phase C batch, or every item in the file for Phase D).
- `--file-item-id` (repeatable) — every item ID currently present in the file under review. Drives the truncation-invariant protection bucket.

For Phase D the orchestrator passes the same set of IDs to both flags. The orchestrator calls the helper once per session opener; the `--file-item-id` list is computed once (after Phase B's enumeration, since item IDs come from there) and reused for every Phase C and Phase D opener.

---

## 7. Session continuation mechanics

### 7.1 Session lifecycle per sub-agent

Each sub-agent owns exactly one codex session from open to close. Sub-agents hold the session ID in memory across rounds; main never sees it.

```python
# pseudocode for blueprint-batch-reviewer / blueprint-consistency-reviewer.
# call_mcp(name, **kwargs) is shorthand for invoking the named MCP tool.
# Hyphenated MCP tool names ("mcp__codex__codex-reply") aren't valid Python
# identifiers, so we invoke them via call_mcp.
def run(spawn_inputs):
    # Round 1 — open session, full prompt. reasoning_effort is set ONLY on
    # round 1 via the codex tool's top-level `reasoning_effort` parameter
    # (the convention v1.2.x agents already use in production — see
    # agents/blueprint-item-reviewer.md and agents/blueprint-consistency-reviewer.md).
    # Rounds 2+ inherit it because codex-reply has no reasoning_effort parameter
    # (see §7.7).
    response_1 = call_mcp(
        "mcp__codex__codex",
        prompt=compose_round_1(
            scaffold,
            file_metadata_brief,
            lessons_block,         # sibling-detected; non-empty when applicable
            history_summary,       # prebuilt by main, passed in spawn
            existing_findings_marker,  # one-line pointer (see §8.2)
            work_payload,
        ),
        reasoning_effort=reasoning_effort,
    )
    # Phase 0 must confirm where the thread id lives in the response. The
    # current Codex MCP server returns it as response.threadId (preferred) or
    # response.conversationId (deprecated alias). See §15 step 1.
    # If both are absent, fall back to stateless mode for the rest of the run
    # (do NOT hard-fail) — see §7.6 for the contract and required banner.
    thread_id = extract_thread_id(response_1)  # None → caller switches to stateless mode
    findings_1 = parse_json(response_1)
    if thread_id is None:
        emit_degraded_mode_banner()  # Phase G surfaces this
        return run_stateless(spawn_inputs, findings_1)  # carries delta inline each round

    if all_converged(findings_1) or max_iter == 1:
        return Payload(items=findings_1, iteration=1)

    working_copy = apply_in_memory(work_payload, findings_1)
    findings_prev = findings_1

    # Rounds 2..N — codex-reply with delta only. No reasoning_effort param;
    # the tool schema only accepts threadId + prompt.
    for round_n in range(2, max_iter + 1):
        # H3: batch shrinking is removed. We DO NOT drop converged items
        # from the diff — they stay in scope so cascade findings introduced
        # by sibling items' fixes can re-surface against them.
        if whole_batch_converged(working_copy, findings_prev):
            break

        diff = compute_diff(work_payload, working_copy, scope=all_batch_items)
        response_n = call_mcp(
            "mcp__codex__codex-reply",
            threadId=thread_id,
            prompt=compose_delta(diff, all_batch_items, round_n),
        )
        findings_n = parse_json(response_n)

        if whole_batch_converged_now(findings_n) or stable_match(findings_n, findings_prev):
            break

        working_copy = apply_in_memory(working_copy, findings_n)
        findings_prev = findings_n

    return Payload(items=findings_n, iteration=round_n)
```

### 7.2 Round 1 payload (Phase C batch of 3 items)

```
[scaffold ~600 tokens — compressed reviewer template per §8.1]
[file_metadata_brief ~100 tokens — feature, scope, terminology glossary]
[lessons_block 0–2k tokens — optional; sibling-detected cross-cycle PR lessons.
                Same value passed to every Phase C batch + Phase D session opener.]
[history_summary ≤ 1500 tokens — filtered to batch items + file scope]
[existing_findings_marker — one line, see §8.2]
[work_payload — JSON: {items: [{item_id, original_region}, ...]}]
```

### 7.3 Round 2+ payload (same batch, via codex-reply)

```
[threadId from round 1's response]
[delta prompt ~200–500 tokens]:
  "I applied your suggested fixes. Diffs per item:
   - PAY-001: <diff>
   - PAY-002: (no findings; unchanged)
   - PAY-003: <diff>
   
   Re-evaluate ALL items in this batch — including any that converged
   in the previous round — because a fix to one item may have introduced
   a new issue in another (cross-item cascade). Return the same JSON shape.
   Iteration: 2."
```

The scaffold, summary, and original item content live in session state — not re-sent. Note: `mcp__codex__codex-reply` accepts only `threadId` and `prompt` per its schema; reasoning effort cannot be changed mid-session.

### 7.4 Batch convergence (no per-item shrinking)

**Per-item shrinking is intentionally NOT done.** Earlier drafts of this design proposed dropping converged items between rounds. That optimization is rejected because of the cross-item cascade risk: if item A converges in round 1 and item B's round-2 fix introduces a terminology drift or cross-reference that breaks A, A's regression would be invisible (A wouldn't be in the round-3 prompt).

Concrete rules:

- The round 2+ delta prompt always includes the full set of items in the batch — converged or not. Diffs for items that didn't change between rounds are emitted as `- <id>: (no findings; unchanged)`.
- The token savings from this design come from session continuation (scaffold/content not re-sent) rather than per-item shrinking. Empirical token cost should be measured in Phase 0 (§15 step 1).

**Exit conditions (carried forward verbatim from v1.2.x; applied across the whole batch):**

| Exit | Condition |
| --- | --- |
| `Result: success` | Across every item in the batch: `new == []` AND every `existing` entry has `status: resolved`. No unresolved findings remain anywhere in the batch. |
| `Result: partial; reason: stable` | At iteration ≥ 2, across every item in the batch: `new == []` AND every `existing` entry has `status ∈ {still-present, refined}`. The loop has converged at "these findings exist and cannot be auto-fixed" — `still-present` and `refined` both count as stable because they represent the same underlying issue, not new work. |
| `Result: partial; reason: stable-medium` | At iteration ≥ 2: no high-severity findings remain anywhere in the batch (neither in `new` nor in any item's kept existing entries) AND `new` contains no medium-severity findings introduced this iteration AND every kept medium is `still-present | refined`. Remaining mediums are stable ambiguities for inspector resolution. The "no new mediums this iteration" clause is mandatory — a fresh medium means progress was just made, so the loop has NOT stabilized. |
| `Result: partial; reason: max-iter` | `iteration_reached == max_iterations` without any earlier exit firing. |
| `Result: partial; reason: stable` (variant) | Round N's findings are byte-identical to round N−1's across all items — historical `stop-on-stable` guard, unchanged from v1.2.x. |

`still-present` findings are **unresolved** problems and do NOT count toward `success`. The orchestrator MUST preserve this distinction when reporting in Phase G.

### 7.5 Concurrency

Main dispatches Phase C batches in waves of `--concurrency` (default 3). Each batch's sub-agent owns its codex session — sessions are isolated. File writes happen in main between waves, serialized by `start_offset`.

```python
batches = chunk(item_descriptors, batch_size=3)
for wave in chunks(batches, size=concurrency):
    payloads = await_all(spawn_batch_sub_agent(b) for b in wave)
    for p in sort_by_first_offset(payloads):
        apply_to_disk(p)         # Edit with exact-match
        validate_frontmatter()   # byte-equality
```

### 7.6 Error handling

| Failure | Behavior |
| --- | --- |
| Invalid JSON in round 1 | Retry once with clarifying suffix. Second failure → `Result: blocked` (raw response captured in `Findings / risks`). |
| Invalid JSON in round ≥ 2 | Same retry. Second failure → accept round N−1's findings as final; `Result: partial; reason: round-n-parse-failure`. |
| Session expired / codex MCP unavailable between rounds | Fall back to fresh `mcp__codex__codex` call carrying delta context inline (degraded mode — pays round-1-size cost). Log warning. |
| Exact-match `Edit` failure during final apply (main) | Re-enumerate that one item from file's current state; re-spawn as fresh single-item batch. |
| Frontmatter byte-mismatch after `Edit` | Revert; retry once; second failure → `Result: blocked`. |
| `stop-on-stable` fires (round N findings ≡ round N−1) | Exit `Result: partial; reason: stable`. Existing behavior preserved. |
| Codex `threadId` not returned in round-1 response | Fall back to **stateless mode for the rest of this run** (each remaining round = fresh `mcp__codex__codex` call carrying full delta inline). Emit one ERROR-level log line at the moment of fallback (`"codex-reply unavailable: threadId missing from round-1 response — degrading to stateless mode"`) AND prepend a single-line "⚠ Degraded mode (stateless) — token savings ~60% vs ~95% target" banner to the Phase G report so the inspector sees it without grep. Does NOT abort the run. If this triggers in production, it signals Phase 0 verification regressed (see §15 step 1) — file a follow-up to re-run Phase 0 tests against the current codex CLI. |

### 7.7 Reasoning-effort handling

`mcp__codex__codex-reply`'s tool schema accepts only `threadId` (or deprecated `conversationId`) and `prompt` — there is no `reasoning_effort` parameter. This forces a one-shot model:

- **Round 1** sets reasoning effort by passing `reasoning_effort: "low" | "medium" | "high"` as a top-level parameter to the `mcp__codex__codex` tool — the same convention the v1.2.x agents already use in production (see `agents/blueprint-item-reviewer.md` step 3 and `agents/blueprint-consistency-reviewer.md` step 4). No nested `config` wrapper, no `model_reasoning_effort` rename — pass it through verbatim.
- **Rounds 2+** inherit the round-1 effort by virtue of running inside the same codex thread. Mid-session effort changes are **not supported**.
- The orchestrator MUST NOT attempt to pass `reasoning_effort` to `codex-reply` — doing so will either error or be silently ignored, depending on the MCP server's tolerance.

### 7.8 Max-iter inspector prompt (carried forward from v1.2.x)

v1.2.x prompts the inspector `y/n` for "another loop?" whenever a loop exits via max-iter with unresolved high/medium findings. v1.4 preserves that escape hatch, adapted to the batched/aggregated shape.

**Firing sites:**

1. **End of Phase C** — after all waves complete, aggregate every batch that exited via `Result: partial; reason: max-iter` AND still has unresolved high or medium findings. If the aggregated set is non-empty, fire ONE prompt:
   `K batches hit max-iter (N unresolved H/M across <batch-ids>). Run another --auto-iter cycle on those batches? (y/n)`
   On `y`: re-spawn ONLY the listed batches with the same `--auto-iter` budget against the file's current state (with prior round findings now inline), then re-aggregate and re-evaluate the prompt. On `n`: continue to Phase D with findings inline.
2. **End of Phase D** — if Phase D exited via `Result: partial; reason: max-iter` with unresolved high/medium, fire:
   `Consistency loop hit max-iter (N unresolved H/M). Run another? (y/n)`
   On `y`: re-spawn Phase D against current file state; re-evaluate. On `n`: continue to Phase F.

Both sites loop on `y` — there is no inner cap on re-runs; the inspector is the cap. (This matches v1.2.x semantics; the only difference is aggregation in Phase C instead of one prompt per item.)

**Exit reasons that do NOT trigger the prompt:**
- `Result: success` (nothing unresolved).
- `Result: partial; reason: stable` or `stable-medium` (the loop converged at the best it can; another pass would re-emit the same findings — the inspector decision is "edit the spec manually," not "loop again").
- `Result: blocked` (the run already surfaced a hard error; the prompt is not the right resolution mechanism).
- `Result: partial; reason: round-n-parse-failure` (degenerate; surfaced as a Phase G warning).

**Suppression contract — when the prompt is silently treated as `n`:**

| Condition | Why |
| --- | --- |
| `MI_BLUEPRINT_REVIEW_AUTO_FIRE=1` is set | The auto-fire path from `mi-apply-impact` Step B.5 is non-interactive by design (matches the §11.5 codex-availability gate's silent-skip semantics on the same env var). |
| No TTY on stdin/stdout | CI runs, scripted batches, background processes — prompting would hang. Log one warning line per suppressed prompt: `max-iter prompt suppressed (no TTY); <K> batches / <N> findings carried forward as-is`. |
| `Ctrl-C` during prompt | Treated as `n`. Loop exits cleanly; findings remain inline. |

**Phase G report integration.** Whether the prompt fired or was suppressed, Phase G's final report includes per-firing-site counters:
- `Phase C: K batches hit max-iter; M re-run cycles requested by inspector; N unresolved H/M at exit.`
- `Phase D: hit max-iter (yes/no); R re-runs; N unresolved H/M at exit.`

If suppression was the reason (env var or no TTY), Phase G appends a one-line note so the inspector reading the report later can see that the escape hatch was not offered.

---

## 8. Prompt envelope and batched per-item shape

### 8.1 Envelope trimmings (each independently valuable)

| # | Change | Saves per call | Notes |
| ---: | --- | ---: | --- |
| 8.1.1 | **Strip YAML frontmatter from `{{FILE_CONTENT}}`** in Phase D + Phase B. Sub-agent splits on `---\n...\n---\n`; passes body only. | 50–300 tokens | `file_metadata_brief` carries the only frontmatter fields that mattered. |
| 8.1.2 | **Replace `{{EXISTING_FINDINGS}}` bullet list with a one-line pointer.** Inline `<!-- REVIEW-FINDING -->` blocks in content become the single source of truth. | 200–2000 tokens (scales with finding count) | Reviewer parses blocks directly; format is structured enough that codex reliably extracts them. |
| 8.1.3 | **Compress reconciliation contract** from ~110 lines to ~50 lines. Dedupe prose shared across `still-present` / `resolved` / `refined` status rules. `resolved_by_change` constraint stays explicit. | 200–400 tokens | Instructions live in session state across rounds; only round 1 pays for them. |
| 8.1.4 | **Strip `severity: low` `REVIEW-FINDING` blocks from the prompt-view of file** in round ≥ 2. In-prompt only; blocks stay on disk. | 50–100 tokens × low-finding-count | Low is already success-tolerated; re-evaluating per round is waste. |

Combined: ~20–35% reduction in per-call round-1 prompt size; rounds 2+ stay tiny via session continuation regardless. (v1.2.x's lessons-block lever is retained per §2 — see "Lessons block in per-item review" — so it does not appear here.)

### 8.2 `existing_findings_marker`

Replaces the multi-line `{{EXISTING_FINDINGS}}` bullet list. Single line, placed immediately before the work payload in every session opener:

```
REVIEW-FINDING blocks in the content below are prior findings; honor the reconciliation contract.
```

### 8.3 Batched per-item reviewer template

`templates/blueprint-reviewer-prompt-batch.md.tmpl` (new — replaces `*-item.md.tmpl`):

```
You are a strict reviewer for ONE OR MORE items in a markdown specification. Identify
ONLY issues where two reasonable implementations would meaningfully diverge in
observable behavior.

[... compressed iteration-aware-depth + severity-calibration + reconciliation-contract
 prose, ~50 lines total ...]

Output ONLY a JSON object, fenced as ```json ... ```, with exactly this shape:

```json
{
  "items": [
    {
      "item_id": "<id from input>",
      "existing": [ { "id": "F-NNN", "status": "...", ... } ],
      "new":      [ { "severity": "...", "phase": "item", "target": "<item_id>", ... } ]
    }
  ]
}
```

The `items` array MUST contain exactly one entry per item in the input, keyed by
`item_id`. Items with nothing to flag still appear with empty `existing` and `new` arrays.

Iteration: {{ITERATION}}

Items to review:
---
{{BATCH_PAYLOAD}}
---
```

`{{BATCH_PAYLOAD}}` rendered as a sequence of `Item <id>:\n---\n<content>\n---` blocks, one per item.

Single-item review (`/mi-blueprint-review-item` or batch_size=1) uses the same template with one entry. The `items` array always exists — uniformity simplifies parsing.

### 8.4 Multi-item Payload JSON (sub-agent → main)

```json
{
  "batch_id": "B1",
  "iteration_reached": 3,
  "threadId": "<opaque codex thread id; informational, not used by main>",
  "items": [
    {
      "item_id": "PAY-001",
      "original_region": "<exact bytes received>",
      "new_region":      "<final bytes after sub-agent's in-memory applies>",
      "remaining_findings": [
        { "id": "T1-2", "severity": "medium", "finding": "...", "suggested-fix": "..." }
      ],
      "existing_transitions": [
        { "id": "F-007", "status": "resolved",      "resolved_by_change": "Added retry-with-backoff + dead-letter to publish-failure paragraph" },
        { "id": "F-012", "status": "still-present" },
        { "id": "F-015", "status": "refined" }
      ]
    },
    {
      "item_id": "PAY-002",
      "original_region": "...",
      "new_region":      "...",
      "remaining_findings": [],
      "existing_transitions": []
    }
  ]
}
```

**`remaining_findings` vs `existing_transitions` — they answer different questions.** Together they give Phase F everything it needs to update `review-history.md` correctly; alone, each is incomplete.

| Field | Source | Purpose for Phase F |
| --- | --- | --- |
| `remaining_findings` | The reviewer's FINAL-round `items[].new` array combined with any `existing[].status == "still-present"` entries that weren't resolved this loop | Snapshot of what's still inline in the file at end of run. Drives the "append new finding" path in Phase F when an ID is absent from `review-history.md`. |
| `existing_transitions` | The reviewer's FINAL-round `items[].existing[]` array, ID-normalized to `F-NNN` form (tmp-ids resolved before return) | Per-ID status update for findings that were already in `review-history.md` at the start of the run. Drives Phase F's `last-status` / `last-status-at` / `resolved_by_change` updates on existing sections. `status: resolved` requires `resolved_by_change` to be non-empty (mirrors the §5.2 schema constraint). |

**`status` enum (per `existing_transitions[].status`):**
- `resolved` — finding addressed this loop; `resolved_by_change` REQUIRED.
- `still-present` — finding acknowledged but not yet fixed; carries forward inline.
- `refined` — finding re-articulated; treated as still-unresolved for Phase F (`last-status: still-present`) but text in `finding` / `suggested-fix` is updated to the latest wording.
- `dropped` — finding was in history at run start but absent from the final round's `existing[]` array entirely. Sub-agents do NOT emit `dropped` themselves; main infers it by diffing the union of all Payloads' `existing_transitions[].id` against the set of prior history IDs that were in scope this run.

**Sub-agent contract for filling `existing_transitions`.** For each item in its batch the sub-agent emits one entry per ID it saw in any round's `existing[]` array, using the LAST round's status verdict (since exit conditions in §7.4 are evaluated against the last round). IDs in tmp-form (`T<instance>-<n>`) are normalized to their final `F-NNN` via `alloc-final-id` BEFORE Payload return — main never sees tmp-ids in `existing_transitions`. The same normalization step rewrites tmp-ids inside `new_region` so the file-on-disk and history-on-disk agree byte-for-byte on every ID.

Main parses, sorts by `original_region`'s `start_offset` (from the canonical descriptor it retained), and applies each item's `Edit(old=original_region, new=new_region)` serially with frontmatter validation between writes. The disk write happens BEFORE Phase F so `review-history.md` updates and the file-on-disk findings can never disagree on which IDs exist.

### 8.5 Consistency reviewer template

`templates/blueprint-reviewer-prompt-consistency.md.tmpl` — same compression treatment as the batch template. `{{EXISTING_FINDINGS}}` placeholder replaced by `existing_findings_marker`; frontmatter stripped from `{{FILE_CONTENT}}`.

---

## 9. Sub-agent restructure

### 9.1 `blueprint-consistency-reviewer` (reshaped)

**File:** `agents/blueprint-consistency-reviewer.md`

**Changes from v1.2.x:**
- Receives `history_summary` and `file_metadata_brief` as new spawn inputs.
- Owns a single codex session for the whole loop; uses `mcp__codex__codex` for round 1 and `mcp__codex__codex-reply` for rounds 2+. (Holds the `threadId` returned in round 1 in memory across rounds.)
- Applies fixes to its in-memory working copy between rounds (so it can compute the delta prompt for the next round). Writes the file to disk at the end of each round (existing serial-write behavior preserved).
- Frontmatter validation after each disk write (unchanged).
- Returns `Payload JSON` with the same shape as the batched reviewer (`items` array with one entry whose `item_id = "file"`). Uniformity simplifies main's parsing.

### 9.2 `blueprint-batch-reviewer` (new — replaces `blueprint-item-reviewer`)

**File:** `agents/blueprint-batch-reviewer.md`

**Inputs (from spawn prompt):**
- `mode`: `file` | `content`
- `batch_id`: e.g., `B1`
- `items`: array of `{item_id, original_region}` (1..N entries)
- `max_iterations`: positive integer
- `agent`, `reviewer_tool_name`
- `reasoning_effort`: low | medium | high
- `sub_agent_instance_id`: T1, T2, … (used as tmp-id prefix per existing pattern)
- `history_summary`: opaque markdown string (built by main; passed verbatim)
- `file_metadata_brief`: opaque markdown string (built by main)
- `lessons_block`: opaque markdown string built by main via sibling-detection against the file under review (same algorithm as `/mi-blueprint-review` Step 1.5 today). May be empty. Substituted into `{{LESSONS_BLOCK}}` in the round-1 prompt; lives in session state for rounds 2+. Identical value passed to every Phase C batch + the Phase D session.

**Tools:** Only `mcp__codex__codex` and `mcp__codex__codex-reply`. Strictly read-only on disk (no `Read`, no `Bash`, no `Edit`).

**Returns:** Multi-item Payload JSON per §8.4.

### 9.3 `blueprint-item-reviewer` (deprecated)

Removed. The single-item path is `blueprint-batch-reviewer` with `items: [single]`. `/mi-blueprint-review-item` builds the single-item batch.

---

## 10. CLI changes

### 10.1 Orchestrator

```
# v1.2.x
/mi-blueprint-review <agent> <max-consistency-iter> <max-item-iter> <file> [--batch-size N] [--scope X] [--reasoning-effort R]

# v1.4
/mi-blueprint-review <agent> <file> [--auto-iter N] [--batch-size N] [--scope X] [--reasoning-effort R] [--concurrency N]
```

Defaults: `--auto-iter 3 --batch-size 3 --concurrency 3 --reasoning-effort medium`.

**Max-iter inspector prompt.** When a loop hits its `--auto-iter` budget with unresolved high/medium findings, the orchestrator fires a `y/n` prompt — once per Phase C aggregation and once for Phase D — to ask the inspector whether to spend another `--auto-iter` cycle. Suppressed when `MI_BLUEPRINT_REVIEW_AUTO_FIRE=1` is set or stdin/stdout is not a TTY. Full contract in §7.8.

### 10.2 Standalone commands

```
# v1.2.x
/mi-blueprint-review-consistency <agent> <max-iterations> <file> [--reasoning-effort R]
/mi-blueprint-review-item <agent> <max-iterations> <file>:<id> [--reasoning-effort R]

# v1.4
/mi-blueprint-review-consistency <agent> <file> [--auto-iter N] [--reasoning-effort R]
/mi-blueprint-review-item <agent> <file>:<id> [--auto-iter N] [--reasoning-effort R]
```

Both become thin wrappers — `-consistency` runs Phase A + B + D + F + G; `-item` runs Phase A + B (single-item) + C (batch=1) + F + G.

Phase B is required even for `-consistency` (one cheap codex enumeration call): it produces the `file_item_ids` list that drives the summary builder's truncation-invariant protection (§6.2). Without it, the protection set is empty and the summary cannot tell "AUD-013 still in the spec, keep its resolution context" apart from "AUD-013 was removed, drop it." For `-item`, Phase B already runs in v1.2.x to compute the anchor for the single item; v1.4 additionally extracts `file_item_ids = [<that one id>]` for the summary scope.

### 10.3 `mi-apply-impact` Step B.5 auto-fire

```diff
- /mi-blueprint-review codex 3 5 "$requirements_path" --scope "Goals (this cycle)" --reasoning-effort medium
+ MI_BLUEPRINT_REVIEW_AUTO_FIRE=1 /mi-blueprint-review codex "$requirements_path" --scope "Goals (this cycle)" --reasoning-effort medium
```

Defaults cover the rest. The `MI_BLUEPRINT_REVIEW_AUTO_FIRE=1` prefix tells the orchestrator's Phase A codex-availability gate (§11.5) to silently no-op on missing codex instead of prompting — B.5's outer probe already handled it. Step B.5's existing codex-presence check (`commands/mi-apply-impact.md` lines 213–240) is unchanged; the new env var is purely a hint to the inner gate.

---

## 11. Stage-2 integration

### 11.1 `mi-apply-impact` changes

New Step A.5 (after Step A's `requirements.md` is generated, before Step B):

```bash
# Step A.5 — Initialize review-history.md if absent.
#
# frontmatter.sh init takes positional args: <template-name> <dest-file> [KEY=VAL ...].
# KEYs are uppercase and map to {{KEY}} placeholders in the template. The script
# auto-generates the `id` UUID — do NOT pass ID=. Integer-typed fields use the
# !RAW! sentinel so they render as bare integers rather than YAML strings (same
# pattern blueprint-lessons uses for selected-count). See mi-apply-impact.md
# Step 1.5 for the canonical example.
review_history="$blueprint_dir/review-history.md"
if [[ ! -f "$review_history" ]]; then
  requirements_id="$("$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" get \
                     "$requirements_path" id)"
  "$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" init review-history \
    "$review_history" \
    "FEATURE=$feature" \
    "REQUIREMENTS_ID=$requirements_id" \
    "LAST_FINDING_ID=F-000" \
    "FINDING_COUNT_TOTAL=!RAW!0" \
    "FINDING_COUNT_UNRESOLVED=!RAW!0" \
    "LAST_REVIEW_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi
```

`mi-apply-impact --force` cleanup: **no code change required.** The existing `--force` block (`commands/mi-apply-impact.md` lines 86–88) already removes every entry under `blueprints/current/` via `for entry in "$curr"/*; do rm -rf "$entry"; done`, which transparently covers `review-history.md`. The neighboring stage-2 cleanup loop over `implementation/` artifacts (grounding-report.md, blueprint-lessons.md) is untouched. Tests in §13.2 should pin this behavior so a future refactor doesn't replace the wildcard sweep with a narrower allowlist that misses review-history.md.

### 11.2 `mi-update-blueprint`

Rotation logic extended to carry `review-history.md` alongside `requirements.md` into `blueprints/history/v<N>/`. New `current/` initialized empty.

### 11.3 `mi-complete-workflow`

Archive allowlist extended to include `review-history.md` in `blueprints/history/v<N+1>/` snapshot.

### 11.4 `mi-doctor`

New `codex-reply` capability probe — verifies `mcp__codex__codex-reply` is callable. Non-blocking; surfaces a warning if missing, and the orchestrator falls back to stateless mode (degraded; logs a notice).

### 11.5 Codex availability gate (orchestrator Phase A — new)

`/mi-blueprint-review` checks codex MCP presence as the **first** Phase A step — before reviewer-tool resolution, lessons-block sibling-detection, `review-history.md` lazy-init, and summary build. The check reuses the existing `scripts/doctor.sh --format=json` codex probe (see `scripts/doctor.sh` `record "codex" cli ...` block, lines 354–366), so it stays consistent with `mi-apply-impact` Step B.5's gate.

**Probe semantics.** The doctor probe is a config + binary presence check (`command -v codex` plus `codex mcp-server --help`). It does NOT verify the server is responsive to a real call — that liveness gap is intentionally accepted here; a mid-run codex failure falls back per §7.6.

**Gate behavior — direct inspector invocation** (`/mi-blueprint-review codex path/to/file.md`, `/mi-blueprint-review-consistency …`, `/mi-blueprint-review-item …`):

1. Probe codex via doctor.sh JSON output.
2. If `present: true` → no-op; continue Phase A.
3. If `present: false` → prompt the inspector with two options:
   - **"Install codex MCP"** — print the install hints carried in the doctor JSON record (`hints_codex()` already provides platform-aware lines: `brew install codex` on darwin, `see https://github.com/openai/codex` on linux). Exit with status 0 and the message: `codex MCP not installed — install and re-run /mi-blueprint-review`. No state mutation.
   - **"Skip review for this run"** — exit with status 0 and a one-line banner: `codex MCP unavailable — review skipped at inspector's request.` No state mutation.

Defaulting to "Skip" is acceptable if the inspector aborts the prompt (Ctrl-C). Either branch returns before any `review-history.md` mutation or sub-agent spawn, so partial state is impossible.

**Gate behavior — auto-fire from `mi-apply-impact` Step B.5** (the existing pre-invocation gate in `commands/mi-apply-impact.md` lines 213–240 stays intact; see §10.3 for the unchanged CLI-line edit):

- B.5's outer probe already silently skips with a warning when codex is missing, so the inner Phase A gate is a no-op fast path on the auto-fire trajectory.
- Keeping the inner gate hardens any **direct or scripted** invocation that bypasses B.5 (e.g., the inspector running the orchestrator manually after `--force`, or future callers).
- No prompt is presented from the auto-fire path because B.5's silent-skip filters the case upstream. The inner gate only prompts when B.5 wasn't the caller.

**Detecting caller**: the orchestrator checks the `MI_BLUEPRINT_REVIEW_AUTO_FIRE` env var (set by `mi-apply-impact` Step B.5 before invoking `/mi-blueprint-review`). When set, the gate falls through silently on missing codex (B.5 already gated; this is defense in depth and should not happen). When unset, the gate prompts.

**No CLI flag for non-interactive mode.** A `--no-prompt` flag is deliberately omitted in v1.4 — the only known non-interactive caller is `mi-apply-impact` Step B.5, and that path uses the env-var signal above. If future callers need a non-interactive skip, add it then.

**Test coverage.** §13.2 adds a test for the gate (mocked doctor.sh `present: false` → skip path; `present: true` → no-op fast path; `MI_BLUEPRINT_REVIEW_AUTO_FIRE=1` → silent-skip without prompt).

---

## 12. Edge cases & risks

### 12.1 Edge cases (net-new from this design)

Existing cases from `docs/blueprints-review/plan.md` §12 carry forward. Net-new:

| Case | Behavior |
| --- | --- |
| `review-history.md` missing post-upgrade | Phase A lazily inits; empty summary block; persists normally at Phase F. |
| `review-history.md` schema-invalid | Hard error in Phase A; orchestrator refuses to start. Inspector moves file aside; re-init occurs lazily. |
| `review-history.md` grows large (10MB+) | Summary cap bounds runtime cost; disk size bounded by archive rotation per blueprint version. |
| Phase C batch returns an `item_id` not in input batch | Retry once with clarifying suffix; second failure → `Result: blocked`. |
| Phase C batch returns fewer `items` entries than input | Same retry-then-blocked policy. |
| Codex `threadId` not returned in round-1 response | Indicates Phase 0 verification gap. Fall back to stateless mode for this run; surface to inspector. |
| Codex MCP unavailable at Phase A entry | Phase A gate prompts inspector (install \| skip); abort cleanly on either branch with no `review-history.md` mutation. When invoked via `mi-apply-impact` Step B.5 (env-var-signaled), gate silently no-ops because B.5 already filtered the case. See §11.5. |
| Concurrent invocations on same file | Out-of-scope (matches v1.2.x). `alloc-final-id` is atomic; `review-history.md` appends would race. Documented as "don't do this." |
| `/mi-update-blueprint` mid-cycle | `review-history.md` rotates with the blueprint; fresh `current/` starts empty. Intentional. |
| Max-iter prompt fires in non-TTY environment | Treated as `n`; one warning line logged; Phase G report annotates suppression. No hang. See §7.8. |
| Inspector answers `y` repeatedly without convergence | No inner cap on re-runs; inspector is the cap. Each `y` re-spends a full `--auto-iter` cycle on the unconverged batches / Phase D. Intentional — matches v1.2.x's per-loop semantics. |
| Inspector aborts (Ctrl-C) at max-iter prompt | Treated as `n`. Loop exits cleanly; findings remain inline; Phase F still runs. |
| Phase C `y` re-run converges some but not all of the previously unconverged batches | Aggregated prompt re-fires with the now-smaller set. Loop continues until either everything converges, the inspector says `n`, or suppression triggers. |

### 12.2 Risks

- **R1 — `mcp__codex__codex-reply` behavior unverified until Phase 0.** Single largest unknown. The MCP tool schema documents only `threadId` + `prompt` as inputs; it does **not** document the round-1 response shape. The design assumes round 1 (`mcp__codex__codex`) returns a `threadId` (or `conversationId` alias) in its response. If that field is absent OR if delta-only prompts in round 2+ don't behave as expected, the design's primary cost win evaporates. Mitigation: Phase 0 is mandatory before any other implementation work and **must produce a written GO / NO-GO report** (§15 step 1). NO-GO → the plan is rewritten around stateless mode as the primary path (each round = fresh `codex` call carrying full delta inline; ~60% savings vs today's projected 95%).
- **R2 — Cascade findings in `--auto-iter 3` mode.** REPORT-1 §P0 Failure mode A persists: the fixer's edits introduce new content the reviewer flags in round 2/3 as "new" findings. Cheap on tokens thanks to `codex-reply`, but inspectors will see auto-fixed text with new issues. Mitigated by stop-on-stable + the new `review-history.md` cross-cycle anchoring.
- **R3 — Summary truncation losing critical context.** Pathological case (20-item blueprint, cycle 6+) can exceed the 1500-token budget after the truncation invariant protects unresolved-high and current-item-tied findings. The design accepts a ≤ 20% overrun in this case rather than dropping load-bearing context. If the overrun proves unacceptable in practice, tune the budget upward.
- **R4 — Migration of currently-inline findings (mitigated).** Existing blueprints with inline `<!-- REVIEW-FINDING -->` blocks need those tracked in `review-history.md` so the cross-cycle "do not re-flag resolved" rule applies to them. Phase A's lazy init runs `scripts/blueprint-review.sh migrate-inline-findings` whenever it creates a fresh `review-history.md` for a file that already contains inline blocks (§5.6). The migrate subcommand walks the file, appends each inline block to history as `last-status: still-present` with a synthetic `first-seen` timestamp, and leaves the inline blocks untouched. Residual risk: the synthetic timestamp doesn't reflect when the finding was actually first surfaced; this is acceptable for inspector-facing audit.
- **R5 — Single-template-for-1..N-items risk.** `blueprint-reviewer-prompt-batch.md.tmpl` always emits `items` array shape, even for batch=1. Slightly more wrapping per single-item review. Trade for one less template to maintain.

---

## 13. Testing plan

### 13.1 Unit

`scripts/blueprint-review.sh` subcommands:
- `build-summary` — table-driven: filter logic per phase, severity sort, truncation invariants (protected vs unprotected), empty history, oversize history
- `persist-findings` (new) — consume the Payload-aggregated existing_transitions and remaining_findings (§8.4): append truly-new findings, apply per-ID status updates (resolved + resolved_by_change, still-present, refined→still-present-with-updated-text), infer the "dropped" set from missing IDs, recompute frontmatter counters. Cover the four statuses individually plus the cross-payload aggregation case (same F-NNN reported by Phase C and Phase D — last-write-wins on Phase D since consistency runs after per-item)
- `migrate-inline-findings` (new) — file with zero inline blocks (no-op), file with N final-id blocks (appends N history entries), file with tmp-id blocks (renames to F-NNN in place, then appends), idempotency check (second run on same file = no-op)
- `schemas/review-history.schema.yaml` validation cases (valid + every invalid permutation)
- Init template smoke tests (mirrors `blueprint-lessons.md.tmpl` pattern, `!RAW!` sentinel)

### 13.2 Integration (`tests/blueprint-review/run.sh` — new harness, mocked codex MCP)

- Round-1-only completes and persists findings
- Multi-round with `codex-reply`: round 2 receives delta-only payload (assert prompt size)
- Stop-on-stable detection at round 2 (same findings as round 1)
- Session-expiry fallback to fresh `codex` call mid-batch
- No batch shrinking: round-2 prompt includes ALL batch items, with converged items rendered as `- <id>: (no findings; unchanged)` (regression test for §7.4 — cross-item cascade protection requires converged items stay in scope)
- Cross-cycle: run 1 generates history; run 2 verifies summary delivered in opener
- existing_transitions end-to-end: pre-seed review-history.md with three findings (one will be resolved, one will stay still-present, one will not appear in the reviewer's final response); run a Phase C batch; assert the Payload carries the right three transitions and that Phase F updates review-history.md to `resolved` (with resolved_by_change populated), `still-present`, and `dropped` respectively
- Codex availability gate (§11.5): (a) doctor probe `present: true` → no-op fast path; (b) `present: false` + direct invocation → prompt path with both install and skip branches exiting cleanly with zero state on disk; (c) `present: false` + `MI_BLUEPRINT_REVIEW_AUTO_FIRE=1` → silent-skip without prompt
- Max-iter inspector prompt (§7.8): (a) Phase C batch hits max-iter with unresolved H/M → aggregated prompt fires; on `y` only the unconverged batches re-run; on `n` flow continues to Phase D with findings inline. (b) Phase D hits max-iter with unresolved H/M → prompt fires; on `y` Phase D re-runs against current file state. (c) Stable / stable-medium / success exits → prompt does NOT fire. (d) `MI_BLUEPRINT_REVIEW_AUTO_FIRE=1` → both prompts silently treated as `n`; warning logged. (e) No-TTY environment → both prompts silently treated as `n`; warning logged. (f) Loop-on-`y` semantics: two consecutive `y` answers trigger two re-runs.
- `--force` cleanup removes `review-history.md` via the existing current/ wildcard sweep (regression test pinning the no-allowlist behavior described in §11.1)
- `/mi-update-blueprint` rotates `review-history.md` into `history/v<N>/`
- `/mi-complete-workflow` archives `review-history.md` alongside other artifacts
- Frontmatter byte-equality preserved across all writes (existing contract)

### 13.3 Manual scenarios (`docs/superpowers/plans/2026-05-23-blueprint-review-token-reduction-manual-tests.md`)

- Real stage-2 on a 5-item blueprint, no prior history
- Re-run on same 5-item blueprint with history (verify summary in prompt)
- Real stage-2 on a 20-item blueprint (batching, parallelism, concurrency cap)
- Standalone `/mi-blueprint-review-item` (single-item-as-batch=1)
- Inspector mid-run abort (Ctrl-C) → partial state inspection
- Max-iter prompt: 20-item blueprint with deliberately-ambiguous content so multiple batches hit max-iter; verify aggregated Phase C prompt, then `y` re-run, then Phase D prompt, then `n` — confirm Phase G report shows the prompt counters correctly
- Max-iter prompt under auto-fire: invoke via `mi-apply-impact` Step B.5; confirm prompt is silently treated as `n` and Phase G logs the suppression

---

## 14. Files to add / modify

### 14.1 New files

| Path | Purpose |
| --- | --- |
| `docs/blueprint-review-token-reduction/plan.md` | This file. |
| `agents/blueprint-batch-reviewer.md` | §9.2 |
| `templates/blueprint-reviewer-prompt-batch.md.tmpl` | §8.3 (replaces `*-item.md.tmpl`) |
| `templates/review-history.md.tmpl` | §5.4 |
| `schemas/review-history.schema.yaml` | §5.2 |
| `tests/blueprint-review/run.sh` | §13.2 |
| `tests/blueprint-review/fixtures/` | mocked codex MCP responses |
| `docs/superpowers/plans/2026-05-23-blueprint-review-token-reduction-manual-tests.md` | §13.3 |

### 14.2 Modified files

| Path | Change |
| --- | --- |
| `commands/mi-blueprint-review.md` | Rewrite orchestrator for new CLI + phase shape (§3, §4, §7, §10). |
| `commands/mi-blueprint-review-consistency.md` | Thin wrapper around Phase A+D+F+G (§10.2). |
| `commands/mi-blueprint-review-item.md` | Thin wrapper around Phase A+B(single)+C(batch=1)+F+G (§10.2). |
| `agents/blueprint-consistency-reviewer.md` | Reshape for session continuation (§9.1). |
| `templates/blueprint-reviewer-prompt-consistency.md.tmpl` | Envelope trim (§8.1, §8.5). |
| `templates/blueprint-reviewer-prompt-enumerate.md.tmpl` | Unchanged. |
| `scripts/blueprint-review.sh` | Add `build-summary`, `persist-findings`, and `migrate-inline-findings` subcommands. Keep `resolve-tool`, `enumerate`, `parse-findings`, `alloc-final-id`, `diff-drift` unchanged. |
| `commands/mi-apply-impact.md` | Add Step A.5 (§11.1). Update Step B.5 CLI line (§10.3). No `--force` cleanup change (existing current/ wipe already covers review-history.md — see §11.1). |
| `commands/mi-update-blueprint.md` | Carry `review-history.md` through rotation (§11.2). |
| `commands/mi-complete-workflow.md` | Archive allowlist extension (§11.3). |
| `scripts/doctor.sh` | `codex-reply` probe (§11.4). |
| `hooks/validate-on-write.sh` | Validate `review-history.md` path against schema. |
| `.claude-plugin/plugin.json` | Bump version to `1.4.0`. |
| `CHANGELOG.md` | New entry under `## 1.4.0`. |
| `README.md` | Brief update to the commands section. |

### 14.3 Removed files

| Path | Reason |
| --- | --- |
| `agents/blueprint-item-reviewer.md` | Replaced by `blueprint-batch-reviewer.md` (§9.3). |
| `templates/blueprint-reviewer-prompt-item.md.tmpl` | Replaced by `blueprint-reviewer-prompt-batch.md.tmpl` (§8.3). |

---

## 15. Implementation order (suggested — writing-plans will refine)

1. **Phase 0 — verify `mcp__codex__codex-reply` shape AND produce a written GO / NO-GO report.** Single largest unknown. Output: `docs/blueprint-review-token-reduction/phase-0-report.md` checked into the repo, listing each test below with `PASS | FAIL | UNKNOWN` and the raw evidence (response excerpts, prompt sizes). The report MUST be reviewed and the GO/NO-GO decision recorded before any other implementation step begins.

   **Required tests (each must pass for GO):**
   - **T0.1** — Call `mcp__codex__codex` with a trivial prompt and `reasoning_effort: "medium"` (the parameter shape v1.2.x already uses in production — see `agents/blueprint-item-reviewer.md` step 3). Inspect the response. Record the exact field name carrying the thread/conversation id (expect `threadId` per the tool schema; tolerate `conversationId` as deprecated alias). FAIL if neither is present. **Phase 0's job is to verify the response shape, not the parameter name — the parameter name is already known.**
   - **T0.2** — Call `mcp__codex__codex-reply` with the `threadId` from T0.1 and a follow-up prompt referencing context from T0.1 ("what was the prompt I just sent?"). Confirm the response demonstrates the model has retained T0.1's context — i.e., session continuation works.
   - **T0.3** — Measure prompt size delta: round-1 prompt size (full scaffold + summary + content) vs round-2 prompt size (delta-only). Log token counts. Target: round-2 ≤ 25% of round-1.
   - **T0.4** — Force session expiry / timeout: how does `codex-reply` behave when `threadId` is invalid or expired? Document the error shape so the fallback path (§7.6) can detect it.
   - **T0.5** — Confirm `codex-reply` rejects or ignores any attempt to pass `reasoning_effort` (it's not in the schema). Document the actual behavior.
   - **T0.6** — Open three concurrent `codex` sessions and verify they don't rate-limit each other. (Pre-validates the `--concurrency 3` default.)

   **GO criteria:** T0.1, T0.2, T0.3, T0.6 all PASS. T0.4, T0.5 PASS or have a documented workaround.

   **NO-GO consequence (design-time, before implementation begins):** This plan is rewritten around stateless mode as the primary path (each round = fresh `codex` call carrying full delta inline). Token savings drop to ~60%; wall-clock savings drop to ~50%. Re-run the writing-plans skill on the revised design before resuming.

   **Runtime regression (after implementation ships):** If `codex-reply` later breaks in production (Phase 0 passed but the CLI was downgraded, the MCP server changed, etc.), the orchestrator does NOT hard-fail. It falls back to stateless mode for the affected run per §7.6 and surfaces a degraded-mode banner in Phase G. NO-GO is a design-time decision; mid-run threadId loss is a graceful degradation.
2. **`schemas/review-history.schema.yaml` + init template + hook validation entry.**
3. **`scripts/blueprint-review.sh build-summary` + `persist-findings` + `migrate-inline-findings` + unit tests.**
4. **Reshape `agents/blueprint-consistency-reviewer.md`** to single-session + `codex-reply` rounds.
5. **Build `agents/blueprint-batch-reviewer.md`** + new prompt template; deprecate `blueprint-item-reviewer`.
6. **Reshape orchestrator and standalone commands** for new CLI + session lifecycle.
7. **Wire `mi-apply-impact` Step A.5 + Step B.5 CLI update.** (No `--force` cleanup change — existing current/ wipe already covers review-history.md per §11.1.)
8. **Wire `mi-update-blueprint` + `mi-complete-workflow`** for `review-history.md` rotation.
9. **Phase F persist logic in main.**
10. **Integration test harness + mocked-codex fixtures.**
11. **Manual test plan + run on real codex** with both 5-item and 20-item blueprints.
12. **`CHANGELOG.md` entry, version bump, doc updates** (`README.md`, project doc if needed).

Each numbered step is a candidate plan step for writing-plans.

---

## 16. Open decisions

| ID | Decision | Notes |
| --- | --- | --- |
| D1 | Whether `--auto-iter` should be plumbed as a plugin `userConfig` field | Currently CLI-only. Promote if multiple teams have different cost tolerances. |
| D2 | Whether to allow `--auto-iter 0` (find-only, no fix step) | Useful for "give me the review but don't touch the file." Recommended: yes; trivial to add. |
| D3 | Whether to add a `--re-loop-marked` flag for inspector-mediated iteration | Inspector marks specific `<!-- REVIEW-FINDING -->` blocks with `<!-- REVIEW-ACK: refix -->`; a second pass re-runs only marked items. Defer to v1.5 if `--auto-iter 3` proves enough. |
| D4 | Whether the summary should include `phase: consistency` findings in per-item batch summaries | Currently yes (file-level findings included). Trade ~50–100 tokens per batch for cross-item anchoring. Could scope strictly to per-item. |
| D5 | Whether to emit a structured `blueprint-review-result.json` next to the file at orchestrator exit | Useful for CI / downstream tooling. Out of scope for v1.4; revisit. |
| D6 | Whether to keep `agents/blueprint-item-reviewer.md` as a deprecated alias | Probably no — clean break; the file is removed in v1.4. |
| D7 | Whether `mi-doctor`'s `codex-reply` probe should be blocking (fail mi-doctor) or just warning | Recommended: warning. Stateless fallback still works. |
