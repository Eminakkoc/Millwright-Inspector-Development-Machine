# Workflow Optimization Assessment

Source reports reviewed:

- `docs/context optimization/workflow-simulation.md`
- `docs/context optimization/recommendations.md`

## Overall Verdict

The proposed optimizations are directionally sound. The report correctly identifies the real cost driver: not raw total tokens, but sticky main-agent context that gets re-sent across many turns and pushes the workflow toward compaction. The strongest recommendations are the ones that move high-read, bounded work into fresh disposable sub-agents and return only compact summaries to the main agent.

The estimated impact is plausible: reducing final main context from ~881k to ~460k while only slightly reducing total work is exactly what should happen when work is relocated rather than eliminated. The session-budget argument is also reasonable because average cumulative main context matters across every turn.

The main implementation caveat is terminology. Several suggestions say "fork", but the optimization only works if these workers are fresh sub-agents that do not inherit the main conversation context. A true fork that inherits main context would not solve the main-context bloat problem.

## Highest-Value Optimizations

### P1: Stage 6 review loop isolation

**Marked suggestions reviewed:**

- Option 2B: per-iteration sub-agent on `go again`
- Option 2A: auto-direct-mode for fix-only findings
- Option 2D: refresh `review-context.md` body each iteration
- Option 2E: tighten `change-summary.md`
- approve-with-deferred-findings shortcut
- pre-classify cascades before invoking the chain

**Assessment: strongly reasonable, with one wording correction.**

Stage 6 is the biggest and clearest win. Each review iteration is naturally bounded by current open findings, and the intermediate source reads rarely need to remain in main context after the iteration commits. Moving each iteration into a fresh sub-agent is the right architecture.

Recommended adjustments:

- Rename "per-iteration sub-agent fork" to **"fresh per-iteration review sub-agent"**. This avoids implementing the wrong mode.
- Keep Option 2A. Fix-only reviews do not need brainstorming chain ceremony, and the stage-5 classification is already the right time to detect this.
- Keep Option 2D. Refreshing `review-context.md` gives each worker a compact current snapshot and reduces repeated diff discovery.
- Keep Option 2E. A bounded `change-summary.md` helps stages 4, 6, and 8.
- Keep the deferred-findings shortcut, but treat it as a workflow UX affordance, not a default behavior. It is useful when the inspector intentionally accepts non-blocking follow-up work.
- Be careful with "pre-classify cascades before invoking the chain": do not pre-fetch large source/spec context in main. If cascade context is needed, package only IDs, paths, and compact excerpts, then let the fresh worker read the heavier files.

### P1/P2: Stage 2 and Stage 8 blueprint work delegation

**Marked suggestions reviewed:**

- Stage 2: delegate codebase-grounding pass
- Stage 8: delegate completion regeneration
- Stage 8: skip regeneration when blueprint is already fresh
- Stage 8: reuse implementation diagrams

**Assessment: strongly reasonable.**

These stages are ideal sub-agent boundaries. The main agent needs the generated artifacts and a short summary, not the full exploration trail. Delegating the grounding and completion-regeneration passes preserves quality while keeping large code/diff reads out of sticky context.

The "skip if fresh" optimization is also sound and should be implemented before doing expensive regeneration. The freshness check needs a conservative cache key, at minimum:

- `base-commit`
- current `HEAD`
- active feature ID
- blueprint version or requirements ID
- reason kind, such as `impact` or `completion`

If any key differs, regenerate or delegate regeneration.

### P2: Stage 4 diagram generation delegation and reuse

**Marked suggestions reviewed:**

- delegate diagram generation to a sub-agent
- reuse `change-summary.md` cache
- skip diagram regeneration when no commits since last diagrams
- render only changed-area diagrams
- make diagram generation optional
- avoid SVG/PNG generation and keep `.puml` only unless requested

**Assessment: reasonable, but split "diagram source" from "diagram rendering".**

The workflow should generate or update `.puml` source when diagrams are part of the expected artifact set. Rendering SVG/PNG should be optional because binary/rendered output usually does not help the agent reason and can create extra filesystem churn.

Recommended policy:

- Generate `.puml` by default when diagram source is stale.
- Render SVG/PNG only when the inspector asks, when CI requires it, or when a visual QA step needs it.
- Do not ask the inspector every time. Use a persisted preference such as `diagram-rendering: never|prompt|auto`; otherwise the prompt itself adds turns and friction.
- Use commit-range detection to update only diagram subjects affected by changed files.

## Reasonable Smaller Optimizations

### Stage 1 per-folder summarization

**Marked suggestion reviewed:**

- per-folder summarization for many small files

**Assessment: reasonable.**

The existing per-file threshold misses the "many small files" case. A folder-level threshold such as `>5 files and >40 KB total` is a practical addition. It should produce a structured digest with source-file attribution so later stages can still trace claims back to original notes.

### Stage 1.5 queue-ordering controls

**Marked suggestions reviewed:**

- Option 1B: delegate codebase scan to a fresh sub-agent
- heuristic short-circuit
- cache the result for the cycle

**Assessment: reasonable, with Option 1A still preferred.**

The cleanest rule is still journal-only ordering at stage 1.5. If code-aware ordering is retained, it should be exceptional and delegated.

The heuristic short-circuit is a good compromise: only run a scan when feature sections mention one another or the journal summary contains dependency language. Caching is also safe because the queue-ordering result is stable within a cycle unless the feature queue or summary changes.

Recommended cache key:

- cycle slug
- ordered feature IDs
- summary file hash
- current `HEAD`, if a code-aware scan was used

### Stage 3 launcher hints

**Marked suggestions reviewed:**

- encourage `subagent-driven-development`
- make `direct` planning mode more attractive for small features
- pre-pass tighter skill metadata

**Assessment: reasonable, but do not oversteer the implementation chain.**

The mi-workflow has limited control over the brainstorming/writing/executing chain, so these should stay as launcher and primer hints. The best additions are:

- prefer subagent-driven-development for tasks touching more than 3 files or more than 100 LOC
- recommend direct mode for small features under roughly 500 LOC
- pass only the filtered skill/rule set from `config.md`

These hints reduce avoidable context, but they should not replace the chain's judgment for complex design work.

### Stage 5 direct-mode hint

**Marked suggestion reviewed:**

- persist `review-mode-suggestion: direct` after fix-only classification

**Assessment: reasonable.**

Stage 5 is the right place to compute this because findings are already canonicalized there. Persisting the suggestion prevents stage 6 from re-deriving the same fact and lets `/mi-review` default correctly.

### Stage 8 finalization mechanics

**Marked suggestions reviewed:**

- atomic finalize
- lazy archival

**Assessment: reasonable.**

These are smaller token wins but good engineering hygiene. Atomic finalization reduces hook churn and lowers the chance of partially advanced state. Lazy archival validation is reasonable as long as archived files are treated as immutable and the live/current artifacts were validated before rotation.

## Suggestions That Need Guardrails

1. **Do not turn every optimization into a user prompt.** Optional diagram generation is good, but repeated prompts increase turn count. Prefer persisted cycle preferences or config defaults.

2. **Do not pre-read heavy context in main before delegating.** The report correctly warns against this. Any implementation of cascade pre-classification must preserve that rule.

3. **Be precise about sub-agent mode.** The intended optimization requires fresh sub-agents with isolated context. Forked sub-agents are useful for other cases, but not for reducing main-context growth.

4. **Avoid stale-summary risk.** Cached `queue-rationale.md`, `change-summary.md`, `review-context.md`, and blueprint freshness checks need explicit invalidation keys. Bad cache invalidation can produce incorrect workflow decisions.

## My Additional Optimization Suggestions

### 1. Add lightweight context-budget instrumentation

Add a small workflow telemetry artifact, for example `quest/<slug>/context-ledger.md` or `progress.md` fields, that records estimated context-heavy events:

- stage
- command
- files read or delegated
- estimated token class, such as `small|medium|large`
- whether work happened in main or a fresh sub-agent
- artifact produced

This does not need exact token accounting. Even coarse counters would let you verify whether the optimized workflow behaves as expected and identify future regressions when a stage starts reading code in main again.

### 2. Add hard "main-read budget" gates by stage

Define soft budgets such as:

- stages 1 and 1.5: no source-code reads in main
- stage 2: main may read summaries and generated artifacts only; code grounding is delegated above threshold
- stage 6: main may read review metadata, but source-file reads for open findings happen in fresh workers unless direct fix-only mode is selected

When a command is about to exceed its budget, it should delegate or ask for explicit override. This turns the architectural principles into enforceable workflow behavior.

### 3. Standardize sub-agent return contracts

Each delegated stage should require a compact, structured return shape. For example:

```md
Result: success|partial|blocked
Artifacts changed:
- path
Commits:
- sha summary
Findings / risks:
- ...
Main should read:
- path, reason
```

This prevents sub-agents from returning long narrative summaries that slowly recreate the main-context bloat the delegation was meant to avoid.

### 4. Add artifact excerpt commands

Where possible, consume slices of large markdown artifacts through small scripts instead of reading whole files. Examples:

- extract one feature section from `summary.md`
- list only open IR IDs and summaries from `inspector-review.md`
- show only changed-file index from `change-summary.md`

This complements sub-agent delegation and keeps main reads bounded even when artifacts grow.

## Final Recommendation

Adopt the marked additions, but prioritize them in this order:

1. Stage 6 fresh per-iteration review sub-agents and fix-only direct mode.
2. Stage 2 and Stage 8 delegation for grounding/regeneration.
3. Stage 4 diagram delegation, `.puml`-first output, and freshness checks.
4. Stage 1.5 journal-only ordering with delegated code-aware fallback.
5. Smaller cache, archival, and validation reductions.

The proposed optimization set is coherent and should materially reduce compaction risk and Max-session pressure. The biggest implementation risk is accidentally using inherited-context forks or main-agent pre-reads where the design calls for fresh isolated workers.
