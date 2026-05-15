# Context Optimization — Findings and Recommendations

## Summary

Two stages in the mi-workflow consume significantly more token context than necessary:

1. **Stage 1.5** (queue ordering, `commands/mi-continue.md` Pre-flight Step 2A) reads the codebase to analyse cross-feature dependencies — violating the design principle that intake stages should be journal-only. Codebase analysis is supposed to begin at stage 2 (`mi-apply-impact`).
2. **Stage 6** (inspector review loop, brainstorming session launched by `commands/mi-review.md`) accumulates large amounts of code/spec/plan reads inside the main chain context across iterations. With 5 iterations and 3–5 source-file reads per iteration, the main context can balloon by several hundred thousand tokens — most of which never needed to be in main context in the first place.

The recommended direction is **not** to read large files in the main agent and pass them down to sub-agents. The opposite: keep main context small, and push large reads **into** sub-agents whose context is discarded after they return a summary. The existing layered-artifact pattern (`review-context.md`, `change-summary.md`, feature-indexed `summary.md`) is correct — the issue is that the work that consumes those artifacts is currently happening in the main chain instead of in delegated sub-agents.

The dominant cost is the review loop. The stage-1.5 leak is comparatively small (~5k tokens per workflow run) but architecturally wrong — it breaks the "intake stages don't read code" invariant.

Beyond the two issues called out above, a third class of problem is operational: **without a return-contract standard, cache invalidation discipline, and clear main-read budgets per stage, the optimization gains erode over time.** Sub-agent summaries grow long, caches go stale, prompts multiply. The later sections of this document codify those operational disciplines.

---

## Cost Model Primer

Three costs matter, and they are routinely conflated:

### 1. Bytes-on-the-wire cost (per model invocation)

What you pay each time the model runs. Prompt caching (5-minute TTL) cuts this to roughly 10% of the normal rate for cached prefixes. So a 50k-token file read at turn 3 costs full price once, then ~10% on every subsequent turn that the cache prefix still applies.

### 2. Context-window occupation (sticky)

Once content enters main agent context, it stays for the rest of the conversation (until compaction kicks in). Even if every subsequent turn is cache-cheap, the bytes still consume the 200k or 1M context window. Cross the compaction threshold and earlier content is dropped or summarized lossily — losing fidelity that may be needed later.

### 3. Accumulation across iterations

Loops compound #2. Each iteration of the stage-6 review loop adds *new* reads on top of *all prior* iterations' reads. The chain doesn't reset between `go again` cycles, so iteration 5 carries the cost of iterations 1–4 plus its own work.

### Reference token sizes

Rough conversions (vary by language and density):

| Source | Approximate tokens |
| --- | --- |
| 2k-line TypeScript / Python file | 12k–20k |
| 2k-line markdown spec | 20k–40k |
| Bounded grep results (50–200 hits) | 1k–5k |
| Full codebase walk (50 files × 500 LOC) | 100k–200k |
| `review-context.md` (current template) | 1k–2k |
| `inspector-review.md` with 3–5 findings | 1k–3k |

### Sub-agent variants — fork vs fresh

The `Agent` tool has two distinct modes. They behave very differently:

- **Fork** — `Agent` invoked **without** `subagent_type`. Inherits the full conversation context of the parent and shares the prompt cache. A read the parent did is visible to the fork at near-zero marginal cost. Good for "I need help with something specific to what I just did" — code review, second opinion, audit of work-in-progress.

- **Fresh sub-agent** — `Agent` invoked **with** `subagent_type` (e.g., `general-purpose`, `Explore`). Starts with zero context. Does NOT see anything the parent has read. Its own reads stay in *its* context and never enter the parent's context. The fresh sub-agent returns a single summary message (typically <1k tokens) to the parent. Good for "go investigate / do work I don't need to see the intermediate steps of."

**Critical implementation note:** Every recommendation in this document that says "delegate to a sub-agent" or "spawn a sub-agent" means a **fresh sub-agent** (`subagent_type` set), not a fork. Forks inherit main context and don't reduce main-context bloat. This is the single most common implementation mistake — re-read the decision rule above before implementing any delegation.

### Why "read in main, pass to sub-agents" is usually wrong

A common assumption is: *read the big file once in main, then pass it to each sub-agent so they don't re-read it.*

This pattern breaks down for fresh sub-agents. They don't share the parent's cache, so to "see" the file content you'd have to embed it verbatim in their prompt. That means the bytes are paid for **twice** — once when main composed the prompt (the file content sits in main's context at prompt-construction time), and once when the sub-agent processed the prompt (the file content sits in the sub-agent's context). Net result: more total tokens, not fewer.

The correct patterns are:

- **For files needed in many turns of main session work**: Read in main, then **fork** (no `subagent_type`) for sub-tasks that need the same context. Forks inherit the read for free.
- **For isolated investigations**: Use a **fresh sub-agent** (`subagent_type: general-purpose` etc.) and let it Read the file directly inside its own context. The bytes are paid for exactly once, in a context that evaporates after the sub-agent returns.
- **For files needed in many sub-agent runs across the same workflow**: Derive a **smaller artifact** once (the existing `review-context.md` / `change-summary.md` pattern) and have the sub-agents read the small artifact. Escalate to the canonical file only when the small artifact has a gap.

Pasting large file contents into a sub-agent's prompt is rarely optimal. The exception is when the sub-agent only needs a *small slice* of a large file (e.g., 20 lines from a 2k-line spec) — in that case, embedding the slice is cheaper than letting the sub-agent Read and skim the whole thing.

---

## Issue 1 — Stage 1.5 Reads Codebase Before Stage 2

### Evidence

The mi-run command (stage 1) is correctly journal-only:

- `commands/mi-run.md:279` — Step 3 (`todo-list.md` generation): *"Analyze **only the content from the specified journal folders**"*
- `commands/mi-run.md:294-318` — Step 4 (`summary.md` generation): all sources are the named journal folders; no codebase touch
- `templates/summary.md.tmpl:11-13` — *"Structured digest of the resources in `journal/`"*

The codebase access happens at **stage 1.5** inside the Pre-flight Handler:

- `commands/mi-continue.md:96` (Pre-flight Step 2A item 4): *"**Analyze codebase for cross-feature dependencies.** For ≥ 2 features in the queue, do a bounded inspection (grep for cross-feature imports, references in shared modules) to surface ordering hints."*
- `docs/workflow-spec.md:289` (Delegation guidance): *"Stage 1.5 (queue ordering): codebase dependency inspection when ≥ 3 features need ordering."*
- `docs/workflow-spec.md:591`: *"If they span multiple features, the handler inspects the codebase to resolve dependencies."*

The output of this scan is written into `quest/<slug>/queue-rationale.md`, which is one of the four canonical quest cycle files. Functionally, a "quest file" is being seeded with codebase context even though the literal stage-1 generator (`/mi-run`) is clean.

### Token impact

A bounded grep across the codebase typically returns 50–200 lines of results — roughly 1k–5k tokens. Once read, those tokens stay in main context for the remainder of the workflow (stages 2 through 8), benefiting from prompt caching but still occupying context window space.

The per-occurrence impact is small (5k tokens). The compounding factor is that this happens on every `/mi-run` cycle, the dependency analysis can grow with feature count, and it sets a pattern of "main session reads code at intake stages" that is easy to extend in ways that scale worse.

### Recommendation

Three compatible options. The cleanest rule is **journal-only ordering at stage 1.5 (Option 1A)**; if code-aware ordering is retained, it should be **exceptional** (heuristic-gated) and **delegated** (Option 1B). Apply in the order presented:

**Option 1A — Cut the scan from main; defer ordering signals to stage 2.**

Remove the codebase inspection from `commands/mi-continue.md` Pre-flight Step 2A. Have stage 1.5 propose the queue order from journal-only signals (`summary.md`'s `## Cross-cutting constraints`, cross-references inside feature sections, journal source documents). Let stage 2's existing codebase-grounding pass (per `docs/blueprint-regeneration.md` Step A) surface dependency mismatches via its diagram and requirements output. If stage 2 reveals that the wrong feature was activated first, the inspector can `/mi-update-blueprint` and reorder the queue.

This is the cheapest option — main context never reads code at 1.5.

**Option 1A.5 — Heuristic short-circuit (gate Option 1B).**

Even when 1B is in play as a fallback, only run a code-aware scan when journal signals genuinely don't decide the order. The trigger:

- Feature names mentioned across `summary.md`'s sections (e.g., `## Feature: payments` body references `audit-log`)
- Cross-cutting constraints referencing inter-feature dependencies (e.g., "audit log must be online before payments can write to it")
- Explicit dependency language in journal sources

Most cycles will skip the scan entirely. Only ambiguous cycles trigger 1B.

**Option 1B — When code-aware ordering is genuinely needed, delegate to a fresh sub-agent.**

The mi-workflow spec already endorses this (`docs/workflow-spec.md:289`) but only for ≥3 features. Lower the threshold to ≥2 (matching the actual code path), and make sub-agent dispatch the **default** rather than an optional bullet:

- Spawn a `general-purpose` **fresh sub-agent** (`subagent_type` set) with disjoint scope: `"Inspect the codebase for cross-feature import/reference relationships among features <A>, <B>, <C>. Read summary.md feature sections for context. Write the queue-rationale.md body section by section. Return only a 2-3 sentence summary of the proposed order and the strongest dependency signal you found."`
- The sub-agent writes the file directly. Main only sees the summary.
- Net main impact: ~200 tokens (the summary), versus the 1k–5k tokens of accumulated grep output today.

The resulting `queue-rationale.md` should be cached for the cycle (see "Cache Key Specifications" below) so subsequent `/mi-continue` invocations within the same cycle don't re-derive it.

Recommendation order: **1A as the primary fix, 1A.5 as the gate, 1B as the fallback path** for the rare cycle where journal alone is genuinely ambiguous.

---

## Issue 2 — Review Loop Accumulates in Main Context

### Evidence

The review loop (stage 6) currently runs the brainstorming session in the main chain context across iterations. Per `commands/mi-review.md:135-145`, each loop trip:

1. Re-reads `inspector-review.md` (small — 1k–3k tokens)
2. Reads `review-context.md` once at session start (compact — 1k–2k tokens)
3. Addresses each open finding — which involves reading the source files affected, possibly cascading into `writing-plans` and `executing-plans` for `re-spec`/`re-plan`-scoped findings
4. On `go again`, repeats step 1–3 with new findings — but the chain context is **not reset**; prior iterations' reads remain

The codebase reads happen inline in the chain (`commands/mi-review.md:104-115`), not via delegation. The existing delegation guidance (`commands/mi-review.md:184-186`, `docs/workflow-spec.md:292`) only triggers for >5 findings — a threshold rarely met in practice (most loops have 1–3 findings per iteration but run across multiple iterations).

### Token impact

Per iteration with the chain reading 3–5 source files to address a finding: ~30k–100k tokens added to main per iteration. Across 5 iterations without sub-agent dispatch: ~150k–500k tokens of accumulated reads in main context.

For `re-spec` / `re-plan` findings the cascade re-launches `writing-plans` + `executing-plans`, which each load their own primers and re-walk relevant code. A single `re-spec` finding can dwarf the cost of five `fix` findings combined.

This is the dominant token cost in the entire workflow. It is also the point where context-window exhaustion is most likely to bite — long review loops can push the conversation past compaction thresholds, losing fidelity for downstream stages.

### Recommendation

Apply in priority order. Options 2A and 2B together address the common case; 2C–2F are progressively bigger refactors.

**Option 2A — Auto-route to direct mode when all open findings are scope=`fix`.**

During canonicalization (`commands/mi-continue.md` Inspector Step 1.5, lines ~683–708) the millwright already classifies severity and scope for each finding. Stage 5 should run the scope-distribution check **at canonicalization time** and persist the result to `progress.md` as `review-mode-suggestion: direct | brainstorming`. Stage 6 then reads the persisted suggestion and defaults the `review-mode` prompt accordingly:

> "All N open findings are simple fixes. Defaulting to direct mode (skips brainstorming chain ceremony). Override by typing `brainstorming` if you want chain dispatch."

Direct mode keeps the review loop in main, but it skips the chain's plan/spec gates that drive the bulk of the cascading reads. For pure-fix iterations this is a large saving with no quality impact.

**Note:** Option 2A's stage-5 hint persistence is a hard prerequisite. Without it, stage 6 has nothing to key off of and the auto-routing doesn't fire.

**Option 2B — Fresh per-iteration sub-agent on `go again`.**

This is the biggest single win. On each `go again` reply, instead of re-entering the existing chain context, spawn a **fresh sub-agent** (`subagent_type` set — explicitly NOT a fork) with:

- Path to `review-context.md`
- Path to `inspector-review.md`
- The list of newly-added IR-NNN ids to address this iteration
- Instructions: address each, commit per fix, call `review.sh set-status` to mark resolved, return a summary in the standard contract shape (see "Sub-Agent Return Contract Standard" below)

The sub-agent does its own reads, edits, and commits in its own context. Main only sees the return summary (~500 tokens).

This caps per-iteration main-context cost at the sub-agent's summary message, instead of the cumulative chain history. A 10-iteration loop adds ~5k tokens to main instead of ~500k.

The trade-off: the sub-agent does not have the prior iterations' context, so re-spec/re-plan cascades that need to *know what was tried before* would need to be passed that history explicitly via small excerpts (paths + IR-IDs + 1-line per prior fix), NOT by pre-reading large source/spec content in main.

**Option 2C — Lower the existing cluster-delegation threshold from >5 to ≥2.**

The spec already endorses cluster-based delegation for >5 findings (`workflow-spec.md:292`). Lower the trigger to ≥2 findings whose scope is `fix` or `re-implement`. Keep `re-spec`/`re-plan` findings in the main chain since they need design-gate context that's expensive to re-establish in a sub-agent.

This is a smaller refinement of 2B. If 2B is implemented, 2C becomes redundant. If 2B is not implemented, 2C is a meaningful partial fix.

**Option 2D — Refresh `review-context.md` body on each `go again`.**

`review.sh sync-refs` (`scripts/review.sh:187-240`) re-points the `requirements-id` frontmatter and stamps a marker, but does NOT regenerate the body. So if iteration 2 commits new files, the chain re-derives "what changed" via `git diff` instead of reading from a refreshed snapshot — a per-iteration cost.

Add a `review.sh refresh-context` subcommand (or extend `sync-refs` with a `--refresh-body` flag) that regenerates the `## Implemented surface` and `## Open findings (snapshot)` sections from current git state and `list-open` output. Call it at the start of each `go again` iteration, before the chain (or sub-agent under 2B) re-reads.

Costs one extra script invocation per iteration; saves the chain ~5k–15k tokens of `git diff` output it would otherwise re-derive.

**Option 2E — Compact `change-summary.md` more aggressively.**

`change-summary.md` is read by `/mi-update-blueprint`, `mi-generate-implementation-diagrams`, and (under Option 2B) the per-iteration review sub-agents. Its body sometimes includes multi-KB diff excerpts that exceed what most consumers need. Tighten the body so the file index is the dominant content and diff excerpts are bounded (e.g., max 50 lines per file, max 500 lines total across all files).

This benefits stages 4, 6, and 8.

**Option 2F — Delta primers for re-spec / re-plan cascades.**

When the chain re-enters `writing-plans` or `brainstorming` for a cascade, it currently reloads everything from scratch. Pass a "delta primer" that says: *"You already produced spec X and plan Y. The finding `IR-NNN` invalidated steps 3–5 of the plan. Regenerate only those steps; keep steps 1–2 and 6+ verbatim."*

This requires changes to the brainstorming and writing-plans skill prompts, not just the mi-workflow commands. Bigger refactor; only worth it if re-spec/re-plan loops are common in practice.

**Approve-with-deferred-findings shortcut (UX affordance, not a default).**

When the inspector types `approve` with open findings remaining, the spec already supports `completed` (deferred). Surface this option clearly in the review-resume prompt — for cases where 1-2 findings are non-blocking, deferring is cheaper than a 5th iteration. Frame it as *"useful when the inspector intentionally accepts non-blocking follow-up work,"* NOT as a default behavior the workflow auto-applies. Auto-applying would mislead inspectors into skipping legitimate findings.

### Ranked recommendation for Issue 2

Highest impact, smallest plumbing — apply both:

1. **Option 2A** — auto-direct-mode when all findings are scope=`fix` (depends on stage-5 hint persistence)
2. **Option 2B** — fresh per-iteration sub-agent on `go again`

Medium-effort follow-ons:

3. **Option 2D** — refresh `review-context.md` body on each `go again`
4. **Option 2E** — tighten `change-summary.md` body

Bigger refactor (only if observed pain warrants it):

5. **Option 2F** — delta primers for cascades

Option 2C becomes redundant once 2B is in place; skip it if implementing 2B.

---

## Sub-Agent Return Contract Standard

Without this standard, sub-agent summaries grow long over time and slowly recreate the main-context bloat that delegation was meant to avoid.

**Required return shape.** Every fresh sub-agent invoked from the mi-workflow must return its result in this markdown shape:

```md
Result: success | partial | blocked
Artifacts changed:
- <path>: <one-line note on what changed>
Commits:
- <sha>: <commit subject>
Findings / risks:
- <short bullet, optional>
Main should read:
- <path>: <reason why main needs this>
```

**Rules:**

- Total return must fit under ~1k tokens. If a sub-agent produces more, scope was too broad or the agent is narrating instead of summarizing.
- "Main should read" lists artifacts the main agent must consume next; everything else stays in the sub-agent's context.
- "Findings / risks" is for issues the sub-agent encountered but couldn't resolve (e.g., ambiguity needing inspector input). Empty bullet list is OK.
- Sub-agent prompts MUST instruct the agent to return only this shape. Free-form prose returns are forbidden — they're how delegation regresses into bloat.

**How to enforce:** the prompt template for each delegated stage should end with the exact shape above as a literal example, plus the instruction *"Return only this structure. Do not narrate intermediate steps."*

**Where this matters most:**

- Stage 2 codebase-grounding sub-agent
- Stage 4 diagram-generation sub-agent
- Stage 6 per-iteration review sub-agent
- Stage 8 completion-regeneration sub-agent
- Stage 1.5 dependency-scan sub-agent (when 1B fires)

---

## Main-Read Budget Gates by Stage

These turn the architectural principles into runtime-checkable workflow rules. Each stage has an explicit budget for what the main agent may read directly. Reads outside the budget must be delegated to a fresh sub-agent or surface an explicit override prompt.

| Stage | Allowed main reads | Forbidden in main |
| --- | --- | --- |
| 1 | Journal files (per `/mi-run` Step 2.5 size policy — large files delegated) | Source code |
| 1.5 | `summary.md` (cached from stage 1), `todo-list.md`, `progress.md` | Source code (delegated under Option 1B if scan needed) |
| 2 | `summary.md` (active feature section + cross-cutting only), generated artifacts | Codebase grounding pass — delegated to fresh sub-agent |
| 3 | `primer.md`, brainstorming Skill outputs | Bulk source reads — handled by chain, with `subagent-driven-development` encouraged for tasks >3 files or >100 LOC |
| 4 | `change-summary.md` (cached), `progress.md`, drift-probe filesystem state | Diagram-source generation reads — delegated |
| 5 | `inspector-review.md`, `progress.md` | (none significant — stage is small) |
| 6 | `review-context.md`, `inspector-review.md` (open IR-IDs only via excerpt command) | Source reads for findings — delegated unless `direct` mode + all findings are `fix` |
| 7 | `progress.md` | (none significant — auto-advance only) |
| 8 | `change-summary.md`, archived blueprint files | Codebase regeneration walk — delegated |

**Enforcement.** Each command should self-check at entry: *"Am I about to read a forbidden category?"* If yes, either spawn a fresh sub-agent for the read, or prompt the inspector for an explicit override. The override prompt is rare and intentional — most reads should already conform.

**Migration note.** Existing commands that violate their budget (most prominently: `mi-continue.md` Pre-flight Step 2A, `mi-apply-impact.md` Step A's grounding pass, `mi-review.md` Step 3a's chain primer) need to be updated to follow these rules. The Implementation Priority table below sequences this work.

---

## Cache Key Specifications

Bad cache invalidation produces incorrect workflow decisions, which is worse than re-doing the work. Every cached artifact MUST document its invalidation key. The keys below are the conservative minimum — add fields if the artifact's freshness depends on additional state.

### `change-summary.md` (already implemented)

```
key:        (base-commit, HEAD, feature-id)
location:   implementation/change-summary.md frontmatter
invalidate: any HEAD movement on the feature branch
read by:    /mi-update-blueprint, mi-generate-implementation-diagrams,
            stage-6 review sub-agents (under Option 2B), stage-8 completion regeneration
status:     ✅ implemented via commits.sh change-summary-fresh
```

### `queue-rationale.md` cache (NEW — required by Option 1B)

```
key:        (cycle-slug, ordered-feature-ids, summary-md-hash,
             HEAD-if-code-aware-scan-was-used)
location:   queue-rationale.md frontmatter
invalidate: any change to selected features OR summary.md body OR
            (when code-aware) any HEAD movement
read by:    /mi-continue Pre-flight handlers
status:     ❌ not implemented — required if Option 1B ships
```

### Stage-8 blueprint freshness check (NEW — required by "skip if fresh" suggestion)

```
key:        (base-commit, HEAD, feature-id, blueprint-version-or-requirements-id,
             reason-kind)
location:   blueprints/current/ + last reason.md in history
invalidate: any of the keys differ from the prior rotation's reason.md
read by:    /mi-complete-workflow before invoking /mi-update-blueprint
status:     ❌ not implemented — required by stage-8 "skip if fresh" item
behavior:   when fresh, skip regeneration and rotate current/ as-is into history
```

### `review-context.md` body refresh (NEW — required by Option 2D)

```
key:        (requirements-id, base-commit, HEAD-at-iteration-start)
location:   review-context.md frontmatter + body sync marker
invalidate: any new commits in base-commit..HEAD between iterations
read by:    stage-6 review chain or sub-agents (under Option 2B)
status:     ⚠️ partial — sync-refs handles requirements-id only;
            body refresh is Option 2D (not yet implemented)
```

### Diagram set freshness (NEW — required by stage-4 "skip when no commits since last diagrams")

```
key:        (base-commit, latest-commit-touching-implementation/diagrams/)
location:   git log of the diagrams/ directory
invalidate: any new commits in base-commit..HEAD since the last diagram render commit
read by:    /mi-draw-diagrams (stage 4), Review-Resume Step 2.5 (stage 7)
status:     ⚠️ partial — Step 2.5 implements this; stage 4 doesn't yet
```

**Discipline rule.** No new cache may be added without a documented entry here. Update this section whenever a new cache mechanism is introduced.

---

## Artifact Excerpt Commands

These small scripts let main agent code consume slices of large markdown artifacts instead of reading whole files. They complement sub-agent delegation by keeping main reads bounded even when canonical artifacts grow.

Suggested additions:

- **`summary.sh feature-section <feature>`** — emits `## Cross-cutting constraints` + `## Feature: <feature>` from `summary.md`. Stages 2, 3, 6 currently read the whole file when they need only one feature's section.
- **`review.sh list-open-summaries`** — emits open IR-IDs and their summary lines (severity, scope, summary), without the `details` body. Stages 5, 6 use this for dispatch decisions; full bodies are needed only inside the per-finding sub-agents.
- **`commits.sh changed-files-only`** — emits the file index from `change-summary.md` without diff hunks. Stages 4, 6, 8 use this when only the file list matters (e.g., deciding which diagrams to refresh).
- **`inspector-review.sh open-ids`** — emits only IR-IDs that are still `status: open` (one per line). Equivalent to `review.sh list-open` but explicitly contract-stable for scripting.

These are not strictly required by the optimization design — but they reduce the chance that a future stage adds inline file reads that could have been excerpts. They also pair naturally with the main-read budget gates above: when a stage's budget allows "review-context.md" but not the full inspector-review.md, an excerpt command makes that distinction enforceable.

---

## Context-Budget Instrumentation

Add a per-cycle telemetry artifact recording context-heavy events, so optimization regressions are detectable. The artifact is intentionally coarse — exact token accounting is not the goal.

**Suggested file: `quest/<active-slug>/context-ledger.md`**

```md
---
id: <uuid>
cycle-slug: <slug>
---

# Context ledger — <slug>

| Stage | Command | Files / inputs | Token class | Location | Artifact produced |
| --- | --- | --- | --- | --- | --- |
| 1   | /mi-run             | journal/pricing/transcript.txt    | large  | sub-agent | summary.md (transcript section) |
| 1   | /mi-run             | journal/compliance/audit-rfc.md   | medium | main      | summary.md |
| 1.5 | /mi-continue        | summary.md (cached)               | small  | main      | queue-rationale.md |
| 2   | /mi-apply-impact    | src/payments seam (12 files)      | large  | sub-agent | requirements.md, config.md |
| 4   | /mi-draw-diagrams   | base-commit..HEAD (8 files)       | large  | sub-agent | implementation/diagrams/ |
| 6   | /mi-review iter-1   | 4 source files for IR-001/002     | medium | sub-agent | 2 commits |
```

**Token class buckets** (rough; no exact counting):

- `small` — under ~2k tokens (single small file, command body, summary)
- `medium` — 2k–20k tokens (single moderate file, small directory walk)
- `large` — over 20k tokens (codebase walk, large transcript, multiple files)

**Implementation:**

- A `ledger.sh append <stage> <command> <files> <class> <location> <artifact>` helper standardizes the format.
- Each delegated/main-reading command appends one row at the moment of the read.
- The ledger lives inside the cycle subfolder so it rotates with everything else at stage 8.

**What this catches:**

- A stage that started reading code in main when its budget says it shouldn't — the row's `Location` column says `main` for a `large` class read.
- A sub-agent invocation that grew bigger over time — repeat large reads under the same stage signal scope creep.
- A future regression where a new optimization is bypassed — the ledger row stops appearing or its class jumps.

The ledger is metadata only; it does not enter context as a sticky read. Main writes one row per relevant event and never re-reads the whole file.

---

## Risks and Pitfalls

The four most important implementation traps to avoid:

1. **Don't accidentally use forks where fresh sub-agents are needed.** A fork inherits main context and reads land in main — defeating the optimization. Use `subagent_type: general-purpose` (or a dedicated subagent type) for any work intended to stay isolated. The "Sub-agent variants — fork vs fresh" subsection of the Cost Model Primer is the decision rule; reread it before implementing any delegation.

2. **Don't pre-read heavy context in main before delegating.** If a sub-agent needs a file, let it Read directly. Pasting file contents into the sub-agent's prompt pays the bytes twice (once in main during prompt construction, once in the sub-agent during processing). The exception is small slices (~20 lines), where embedding is cheaper than letting the sub-agent skim a large file. This applies especially to "pre-classify cascades before invoking the chain" — pass IDs, paths, and 1-line excerpts only.

3. **Don't multiply user prompts.** Optional behaviors (diagram rendering, review mode selection, drift confirmation) should default to a persisted cycle preference (e.g., `diagram-rendering: never|prompt|auto` in `progress.md`), not a per-cycle prompt. Each prompt adds at minimum 1 turn — for a workflow at ~120 turns, 5 extra prompts inflate billing meaningfully and add inspector friction.

4. **Don't skip cache invalidation discipline.** Caches without explicit invalidation keys produce stale data, leading to incorrect workflow decisions. Every new cache (queue-rationale, blueprint freshness, review-context body, diagram set, etc.) MUST document its key fields and invalidation triggers in the "Cache Key Specifications" section above. Bad cache hits are worse than re-doing the work.

---

## Implementation Priority

Reordered per the optimization-assessment review. Stages 2, 4, and 8 delegation (previously implicit in the architectural principles) are now first-class priority entries.

| Priority | Item | Stage(s) affected | Rough effort |
| --- | --- | --- | --- |
| **P1** | Option 2B — fresh per-iteration sub-agent on `go again` | 6 | Medium — touches `mi-review.md` Step 3a/3b |
| **P1** | Option 2A — auto-direct-mode for fix-only findings | 5/6 | Small — touches `mi-continue.md` Inspector Step 1.5 + `mi-review.md` Step 2.6 |
| **P1** | Stage 5 — auto-direct-mode hint persistence (prerequisite for 2A) | 5 | Small — adds `review-mode-suggestion` field to `progress.md` |
| **P2** | Stage 2 — delegate codebase-grounding pass to fresh sub-agent | 2 | Medium — touches `mi-apply-impact.md` Step A |
| **P2** | Stage 8 — delegate completion regeneration to fresh sub-agent | 8 | Medium — touches `mi-update-blueprint.md` completion path |
| **P2** | Stage 8 — skip regeneration when blueprint is already fresh | 8 | Small — implement the cache key check |
| **P2** | Stage 8 — reuse implementation diagrams (no re-render at completion) | 8 | Small — copy instead of regenerate |
| **P3** | Stage 4 — delegate diagram generation to fresh sub-agent | 4 | Medium — touches `mi-generate-implementation-diagrams.md` |
| **P3** | Stage 4 — `.puml`-first; SVG/PNG only on persisted preference (not per-cycle prompt) | 4 | Small — add `diagram-rendering` preference; render flag |
| **P3** | Stage 4 — change-summary cache reuse | 4 | Small — verify call site uses `commits.sh change-summary-fresh` |
| **P3** | Stage 4 — skip diagram regeneration when no commits since last diagrams | 4 | Small — git-log check; cache key documented above |
| **P3** | Stage 4 — render only changed-area diagrams | 4 | Small — sub-agent identifies affected diagrams from commit range |
| **P4** | Option 1A — drop codebase scan from stage 1.5 | 1.5 | Small — touches `mi-continue.md` Pre-flight Step 2A item 4 |
| **P4** | Option 1A.5 — heuristic short-circuit for code-aware scan | 1.5 | Small — regex on `summary.md` body |
| **P4** | Option 1B — fresh sub-agent for residual stage-1.5 dependency analysis (with cache) | 1.5 | Small — only fires when 1A.5 says scan is needed |
| **P5** | Option 2D — refresh `review-context.md` body on `go again` | 6 | Small — extend `review.sh sync-refs` |
| **P5** | Option 2E — tighten `change-summary.md` body | 4/6/8 | Small — adjust generation in `commits.sh` |
| **P5** | Stage 1 — per-folder summarization for many small files | 1 | Small — extend `/mi-run` Step 2.5 thresholds |
| **P5** | Stage 3 — primer hints (subagent-driven-development for >3 files / >100 LOC; direct for <500 LOC) | 3 | Small — `primer.md` template tweak |
| **P5** | Stage 3 — pre-pass tighter skill metadata via `config.md` filtering | 3 | Small — depends on stage-2 skill filter sub-agent |
| **P5** | Stage 8 — atomic finalize; lazy archival validation | 8 | Small — script consolidation |
| **P6** | Sub-agent return contract enforcement (all delegated stages) | All P1–P5 delegated stages | Small — primer-level instruction in each call site |
| **P6** | Cache key specifications — document each cache; enforce in code | 1.5, 4, 6, 8 | Small — frontmatter additions, freshness checks |
| **P6** | Main-read budget gates per stage | All stages | Medium — self-check at command entry |
| **P6** | Context-budget instrumentation (`context-ledger.md`) | All stages | Small — telemetry artifact + helper script |
| **P6** | Approve-with-deferred-findings UX framing (clarify in prompt text) | 6 | Small — wording in review-resume prompt |
| **P7** | Option 2F — delta primers for cascades | 6 | Large — touches brainstorming/writing-plans Skill prompts |

**Reading the priority groups:**

- **P1** delivers the largest single-stage savings (review loop). Apply first.
- **P2** addresses the next two largest stage costs (blueprint generation at 2 and 8).
- **P3** addresses stage 4 (diagram generation) — moderate cost but touches multiple subsystems.
- **P4** closes the architectural gap at stage 1.5 (intake stages must not read code).
- **P5** is the long tail of smaller wins.
- **P6** is operational discipline — without it, the P1–P5 gains erode over time.
- **P7** is the cascade refactor — only worth doing if observed pain warrants it.

---

## Architectural Principles to Carry Forward

These are the load-bearing rules behind the recommendations above. They generalise to future stage additions or modifications:

1. **Intake stages (1, 1.5) are journal-only.** Codebase analysis begins at stage 2 (`mi-apply-impact`) and never earlier. If an intake-stage decision needs codebase signal, derive it lazily at stage 2 or delegate to a fresh sub-agent that returns a summary — do not read code in main.

2. **Layered artifacts before canonical files.** `review-context.md`, `change-summary.md`, and feature-indexed `summary.md` exist precisely to spare downstream stages from re-reading large canonical files. When adding a new stage, derive a small artifact for it; let consumers escalate to canonical only on cache miss.

3. **Push large reads into sub-agents, not out of them.** Main-agent context is precious because it is sticky and accumulates. Sub-agent context is disposable. Default to: large reads happen in sub-agents whose context evaporates on return.

4. **Fork for "needs my context"; fresh sub-agent for "doesn't need my context".** Forks inherit cache and prior reads at near-zero cost. Fresh sub-agents start from zero but keep their reads out of main. Pick based on whether the sub-task actually needs to know what main has done. **Default to fresh when in doubt** — using a fork where a fresh sub-agent was needed silently defeats the optimization.

5. **Avoid passing large file contents in sub-agent prompts.** Embedded bytes are paid for twice (once in main during prompt construction, once in the sub-agent). Always cheaper to let the sub-agent Read directly, unless you only need a small slice (~20 lines).

6. **Loops compound costs.** Any iterating stage (review loop, drift checks, mid-cycle re-entry) needs explicit per-iteration context discipline. Sub-agent dispatch per iteration caps cumulative main-context growth at the sum of summary messages, not the sum of all reads.

7. **Sub-agent return discipline.** Every delegated stage produces a structured ~1k-token return summary in the contract shape (Result / Artifacts / Commits / Findings / Main-should-read). Free-form prose returns slowly recreate the bloat the delegation was meant to avoid.

8. **Cache invalidation discipline.** Every cached artifact has an explicit, documented invalidation key in the "Cache Key Specifications" section. Bad cache hits are worse than re-doing the work.

9. **Don't multiply prompts.** Optional behaviors default to persisted cycle preferences, not per-cycle user prompts. Each prompt adds turns; turns multiply per-turn cache cost.
