# Worst-Case Workflow Simulation — Stage-by-Stage Token Cost

This document walks through one full mi-workflow cycle for a deliberately large feature, tracking main-agent context, sub-agent token cost, and cumulative total work at every stage. Two passes are presented side-by-side: the **current** behavior (spec as-is) and the **optimized** behavior (with the recommendations from `recommendations.md` applied).

The numbers are estimates with stated assumptions. They are intentionally on the high side so you see the worst case clearly; smaller features scale down proportionally.

---

## Reference scenario

**Cycle**: "Payments overhaul + audit-log compliance"

- **Features in queue**: `payments`, `audit-log` (2 features → triggers stage-1.5 dependency analysis under current spec)
- **Journal folders supplied to `/mi-run`**: `pricing-meeting`, `compliance-rfc`, `audit-design-doc`
- **Journal sizes**:
  - `pricing-meeting/transcript.txt` — 150 KB
  - `compliance-rfc/audit-rfc.md` — 80 KB
  - `audit-design-doc/design.md` — 60 KB
  - **Total intake**: 290 KB (`transcript.txt` exceeds the 100 KB single-file threshold from `/mi-run` Step 2.5)
- **Codebase**: ~80,000 LOC TypeScript + Python backend monorepo
- **Implementation scope**:
  - 30 source files touched across both features
  - 4,000 LOC added/modified
  - 12 commits in `base-commit..HEAD`
- **Review session**: 4 iterations driven by 5 findings — 2 `fix`, 2 `re-implement`, 1 `re-plan`

This is on the larger end. A typical cycle is one feature, smaller journal intake, a few commits, and 1–2 review iterations. The worst case is shown so the optimization impact is visible at full scale.

---

## Token estimation conventions

These are the conversion rules used throughout. They are rough but defensible:

| Source | Approximate tokens |
| --- | --- |
| 1 KB of natural-language text (transcript, RFC) | ~330 tokens |
| 1 KB of markdown spec | ~330 tokens |
| 1 LOC of TypeScript/Python source | ~8–12 tokens (typed code; imports + signatures + bodies) |
| 1 LOC of dense markdown | ~10–15 tokens |
| 500-LOC source file | ~5,000 tokens |
| 2,000-LOC source file | ~16,000 tokens |
| Bounded grep result (50–200 hits) | ~1,000–5,000 tokens |
| `frontmatter.sh` / `progress.sh` / shell command output | ~100–500 tokens per call |

Other assumptions:

1. **Same-conversation context.** Skill invocations (brainstorming, writing-plans, executing-plans) run in the same Claude Code session — their reads accumulate in main context. The "isolated from mi-workflow" phrase in the spec means mi-workflow commands don't read the chain's spec/plan files, NOT that the chain runs in a separate process. Tokens spent inside the chain are tokens spent in main context.
2. **Forks vs fresh sub-agents.** The "Sub-agents" column in each table counts tokens spent in disposable sub-agent contexts that do NOT add to main context. A fork (no `subagent_type`) inherits main context — its reads would land in main, so it is treated as "main" in this simulation. The optimized scenarios use **fresh sub-agents** (`subagent_type: general-purpose` or similar) so their reads stay isolated.
3. **Prompt cache.** Cached re-reads cost ~10% of normal at runtime, but they still occupy context-window space. The numbers below count **bytes-in-context** rather than per-turn-cost. Per-turn cost with caching is meaningfully lower; context-window pressure is what's tracked here.
4. **"Cumulative main" tracks bytes in main context.** Sub-agent contexts evaporate after they return; their tokens are reported per-stage but not summed into the running main total.
5. **"Cumulative total" tracks total tokens of work done.** Main delta + all sub-agent deltas through this stage. Approximates total compute cost paid (regardless of where the tokens lived). Use this column when reasoning about session-window budget.

---

## Claude Max 5x session budget reference

Anthropic does **not** publish exact token limits for Claude Code plans — usage is measured by a weighted-message system that doesn't translate cleanly to a fixed token count. The numbers below are approximations based on community-reported observations and rough scaling between tiers. Use them as order-of-magnitude estimates, not precise budgets.

| Plan | Approximate budget per 5-hour rolling window |
| --- | --- |
| Claude Pro (~$20/mo) | ~1–2 million token-equivalents |
| Claude Max 5x (~$100/mo) | ~5–10 million token-equivalents |
| Claude Max 20x (~$200/mo) | ~20–40 million token-equivalents |

Effective budget depends on:

- **Model**: Opus is heavier per token than Sonnet (rough rule: ~3–4× the weight). The mi-workflow runs on Opus 4.7, so lean toward the **lower end** of the range.
- **Tool use**: every tool invocation has bookkeeping overhead beyond the tokens it processes.
- **Cache hit rate**: cached prefixes cost ~10% of normal. High hit rates stretch the budget significantly; low hit rates compress it.
- **Output volume**: output tokens cost ~5× input tokens (from the API price ratio for Opus). Long generation passes (writing specs, plans, blueprints) skew effective cost upward.

For the mi-workflow's Opus + heavy tool use + frequent generation profile, **assume ~5 million token-equivalents per Max 5x session window** as the working budget. This is conservative; some sessions may stretch further.

### Two ways to compare a workflow against this budget

The "Cumulative total" column in the per-stage tables tracks **work performed** — the sum of every token processed across main and all sub-agents. This is the figure to compare against the session budget.

There is a second figure that matters in practice: **effective billing per cycle**, which is approximately:

```
effective_billing ≈ total_work + (turns × average_cumulative_main × cache_factor)
```

where `cache_factor` ≈ 0.1 for warm-cache turns. For a cycle with ~120 turns and a high average context size, effective billing can be ~3–6× the total-work figure. This is where the optimization payoff is biggest: keeping cumulative main small means every turn re-sends a smaller cached prefix, multiplying the savings across the entire cycle.

Both metrics — total work and effective billing — are reported in the session-budget analysis at the end of this document.

---

## Stage 1 — `/mi-run pricing-meeting compliance-rfc audit-design-doc`

Activity: dependency preflight, parse arguments, validate journal folders, size manifest, slug + cycle subfolder, generate `todo-list.md` + `summary.md` + `progress.md`.

### Current behavior

Step 2.5's per-file summarization fires automatically for the 150 KB transcript (over the 100 KB single-file threshold), so even "current" already delegates one read.

| Activity | Main delta | Sub-agent delta |
| --- | --- | --- |
| `/mi-run` command body loaded into context | 6,000 | — |
| `doctor.sh --preflight` output | 200 | — |
| Journal folder validation + size manifest | 500 | — |
| Per-file summarization sub-agent for `transcript.txt` (Step 2.5 delegation) | — | 50,000 |
| Sub-agent return digest folded into main | 1,500 | — |
| Read `audit-rfc.md` (under threshold) | 26,000 | — |
| Read `design.md` (under threshold) | 20,000 | — |
| Generate `todo-list.md` + `summary.md` + `progress.md` (output tokens + frontmatter calls) | 6,000 | — |
| Hook validation outputs | 800 | — |
| **Stage 1 main delta** | **~61,000** | — |
| **Sub-agents this stage** | — | **1 sub-agent, ~50,000 tokens (disposable)** |
| **Cumulative main** | **~61,000** | — |
| **Cumulative total work** | **~111,000** | — |

### Optimized behavior

No additional optimization beyond what Step 2.5 already provides — current behavior is already correct here. Stage 1 is the spec's reference example for "delegate when file exceeds threshold."

| Activity | Main delta | Sub-agent delta |
| --- | --- | --- |
| (same as current) | ~61,000 | 50,000 |
| **Cumulative main** | **~61,000** | — |
| **Cumulative total work** | **~111,000** | — |

**Delta vs current: 0**. Stage 1 is already optimized.

### Stage 1 optimization suggestions

- **Size thresholds (already in spec).** `/mi-run` Step 2.5 triggers per-file summarization at >100 KB single-file or >500 KB total. Defaults are reasonable but can be tuned downward (e.g., 60 KB / 300 KB) if your typical journal files are smaller and you still see context pressure here.
- **Pre-trim irrelevant sections.** For very large transcripts (multi-hour meeting recordings), pre-process them with a script that strips boilerplate (timestamps, speaker tags repeated each turn, off-topic sections marked by speakers) before they enter the journal folder. The summarizer reads less.
- (*ADD THIS) **Per-folder summarization (not currently in spec).** When a single journal folder has many small files (e.g., 20 short notes in one folder), a per-folder sub-agent can produce a single digest covering all files instead of reading them individually in main. Add a threshold: if a journal folder contains >5 files totaling >40 KB, dispatch one sub-agent for the folder.
- **Skip frontmatter validation re-reads.** `frontmatter.sh init` validation reads the file it just wrote. The hook re-validates on the next tool call. These compound — consider a `--skip-validate` flag on the init path when the hook will catch errors anyway.

---

## Stage 1.5 — `/mi-continue` ×2 (Pre-flight Steps 2A + 2B)

Activity: promote `[x] TODO → PENDING`, analyze cross-feature dependencies (current spec), propose order, write `queue-rationale.md`, reorder queue, auto-fire `/mi-apply-impact`.

### Current behavior

The Pre-flight Step 2A item 4 explicitly reads the codebase: *"For ≥ 2 features in the queue, do a bounded inspection (grep for cross-feature imports, references in shared modules)."*

| Activity | Main delta | Sub-agent delta |
| --- | --- | --- |
| `/mi-continue` command body loaded | 5,000 | — |
| `todo.sh pend-selected` output | 200 | — |
| Re-read `todo-list.md` to group features (already partly cached) | 2,000 | — |
| **Cross-feature codebase scan**: grep results + reading 8–15 candidate files for context | **40,000** | — |
| Propose order in chat (output tokens) | 1,500 | — |
| Second `/mi-continue` — write `queue-rationale.md`, run `progress.sh reorder` | 2,000 | — |
| Auto-fire `/mi-apply-impact` (handed off — its cost counted in stage 2) | 0 | — |
| **Stage 1.5 main delta** | **~50,700** | — |
| **Sub-agents this stage** | — | **0** |
| **Cumulative main** | **~111,700** | — |
| **Cumulative total work** | **~161,700** | — |

### Optimized behavior

Apply **Option 1A** (drop the codebase scan; use journal-only ordering signals from `summary.md` feature sections — already in cache from stage 1).

| Activity | Main delta | Sub-agent delta |
| --- | --- | --- |
| `/mi-continue` command body loaded (cached) | 500 | — |
| `todo.sh pend-selected` output | 200 | — |
| Re-read `todo-list.md` (cached) | 200 | — |
| **Order proposal from journal signals only**: scan `summary.md` cross-cutting + feature sections (already in main from stage 1) | 500 | — |
| Propose order in chat (output tokens) | 1,500 | — |
| Second `/mi-continue` — write `queue-rationale.md`, run `progress.sh reorder` | 2,000 | — |
| **Stage 1.5 main delta** | **~4,900** | — |
| **Sub-agents this stage** | — | **0** |
| **Cumulative main** | **~65,900** | — |
| **Cumulative total work** | **~115,900** | — |

**Delta vs current: −45,800 tokens permanently saved from main context.**

If Option 1B is preferred over 1A (delegate the scan to a sub-agent instead of cutting it):

| Activity | Main delta | Sub-agent delta |
| --- | --- | --- |
| ... | ~6,400 | — |
| **Codebase dependency scan via sub-agent** | — | **40,000** |
| Sub-agent return summary | 500 | — |
| **Stage 1.5 main delta** | **~6,900** | — |
| **Sub-agents this stage** | — | **1, ~40,000 tokens** |
| **Cumulative main** | **~67,900** | — |
| **Cumulative total work** | **~157,900** | — |

Option 1A and 1B yield comparable main-context savings; 1B preserves the dependency analysis for cases where the journal alone is ambiguous. Option 1A also reduces total work; Option 1B keeps total work similar to current but relocates it.

### Stage 1.5 optimization suggestions

- **Option 1A — Drop the codebase scan entirely (recommended P2).** Cross-feature ordering is derived from journal signals only (`summary.md` cross-cutting + feature sections, both already in main context from stage 1). If stage 2's grounding pass later reveals an ordering inversion, the inspector reorders manually — the cost of being occasionally wrong is small.
- (*ADD THIS if this option prevents main agent context bloating) **Option 1B — Delegate the scan to a fresh sub-agent.** Lower the existing >3-feature threshold to ≥2 to match the actual code path. Sub-agent inspects imports/references and writes the `queue-rationale.md` body directly. Main only sees a one-paragraph summary.
- (*ADD THIS) **Heuristic short-circuit.** Run the scan only when feature names cross-reference each other in `summary.md`'s body (regex check on feature-name appearances inside another feature's section). Most cycles will skip the scan; only ambiguous ones trigger it.
- (*ADD THIS) **Cache the result for the cycle.** If the scan does run, the result is stable for the entire cycle. Don't re-derive it on subsequent `/mi-continue` invocations within the same cycle.

---

## Stage 2 — `/mi-apply-impact` (auto-fired)

Activity: codebase-grounding pass per `docs/blueprint-regeneration.md`, generate `requirements.md` + `config.md` + `diagrams/` for the active feature (`payments`).

### Current behavior

The grounding pass reads 10–20 files across the payments seam (`src/payments/**`, `src/webhooks/**`, plus a few cross-references): ~12 files at average 600 LOC each = ~60,000 tokens. Plus skill/rule scanning for `config.md`'s auto-block.

| Activity | Main delta | Sub-agent delta |
| --- | --- | --- |
| `/mi-apply-impact` command body loaded | 4,500 | — |
| Read `summary.md` `## Cross-cutting` + `## Feature: payments` (cached partial from stage 1) | 3,000 | — |
| **Codebase-grounding pass**: walk payments seam, read ~12 files | **65,000** | — |
| Skill/rule scanning under `.claude/skills/` and `.claude/rules/` | 8,000 | — |
| Generate `requirements.md` body (output tokens) | 6,000 | — |
| Generate `config.md` body (output tokens) | 3,000 | — |
| Generate diagrams (PlantUML rendering metadata, not the rendered SVGs) | 4,000 | — |
| Hook validation | 800 | — |
| **Stage 2 main delta** | **~94,300** | — |
| **Sub-agents this stage** | — | **0** |
| **Cumulative main** | **~206,000** | — |
| **Cumulative total work** | **~256,000** | — |

### Optimized behavior

Apply Architectural Principle 3: **push large reads into sub-agents**. The codebase-grounding pass is delegated to a fresh sub-agent that produces a structured grounding report; main reads only the report and uses it to compose `requirements.md` / `config.md` / diagrams.

| Activity | Main delta | Sub-agent delta |
| --- | --- | --- |
| `/mi-apply-impact` command body loaded | 4,500 | — |
| Read `summary.md` `## Feature: payments` (cached) | 1,500 | — |
| **Codebase-grounding sub-agent**: reads payments seam, returns structured report | — | **65,000** |
| Sub-agent return: grounding report (~3 KB markdown) | 3,500 | — |
| **Skill/rule filter sub-agent** (>30 entries threshold met) | — | **8,000** |
| Sub-agent return: filtered three-section list | 1,500 | — |
| Generate `requirements.md` body | 6,000 | — |
| Generate `config.md` body | 3,000 | — |
| Generate diagrams metadata | 4,000 | — |
| Hook validation | 800 | — |
| **Stage 2 main delta** | **~24,800** | — |
| **Sub-agents this stage** | — | **2, ~73,000 tokens (disposable)** |
| **Cumulative main** | **~90,700** | — |
| **Cumulative total work** | **~213,700** | — |

**Delta vs current: −69,500 tokens.** Stage 2 is the first stage where sub-agent dispatch makes a large difference, because it is the first stage with legitimate large codebase reads.

### Stage 2 optimization suggestions

- (*ADD THIS) **Delegate the codebase-grounding pass.** This is the single biggest stage-2 win. Sub-agent walks the seam, identifies entrypoints / suspected flows / pre-existing classes, writes a 2–4 KB structured grounding report. Main reads the report (small) instead of the seam (large).
- **Skill/rule filter sub-agent (>30 entries threshold).** Already in `docs/workflow-spec.md:290` as optional. Make it default behavior when `.claude/skills/` + `.claude/rules/` exceed 30 entries combined.
- **Read only the active feature section of `summary.md`.** `## Cross-cutting constraints` is needed; other features' sections are not. Use `awk` or a small script to extract just the relevant sections, not the whole file.
- **Avoid re-generating `change-summary.md` if fresh.** The cache key is `(base-commit, head)`. At stage 2 there are no commits yet on the feature branch, so `change-summary.md` doesn't apply — this is more relevant to stages 4 and 8.
- (*ADD THIS and we can completely avoid generating .svg and .png files. We can also ask the inspector if they want the diagrams to be generated so we can make the diagram generation optional.) **Diagram rendering — defer SVG generation.** PlantUML rendering produces large output but the renderer's binary output isn't relevant to context. Confirm the rendered SVGs/PNGs are not being read into context (only the `.puml` source matters).

---

## Stage 3 — `/mi-plan-implementation` + brainstorming chain

Activity: launch the brainstorming chain (in same session). Chain executes brainstorming → writing-plans → executing-plans, producing 12 commits across 30 files (4,000 LOC). The Skill's reads accumulate in main session context.

### Current behavior

This is the largest single-stage cost in the entire workflow. The chain reads code to design, writes a spec, reads more code to plan, writes a plan, then executes the plan with Read+Edit+Bash cycles for each task.

For a 4,000 LOC / 30-file scope:

| Activity | Main delta | Sub-agent delta |
| --- | --- | --- |
| `/mi-plan-implementation` command + branch validation | 5,000 | — |
| Read `primer.md` | 2,500 | — |
| **Brainstorming phase**: read 15–25 candidate files for design context, draft + iterate spec | **80,000** | — |
| **Writing-plans phase**: re-read relevant files, draft plan with checkboxes | **40,000** | — |
| **Executing-plans phase**: per-task Read + Edit + Bash + commit cycles for ~12 tasks | **180,000** | — |
| Skill metadata (subagent-driven-development, finishing-a-development-branch, etc.) | 8,000 | — |
| `git diff` / `git status` outputs accumulated across tasks | 12,000 | — |
| **Stage 3 main delta** | **~327,500** | — |
| **Sub-agents this stage** | — | **Variable** — `subagent-driven-development` may spawn its own; counted within the chain's accumulated total above |
| **Cumulative main** | **~533,500** | — |
| **Cumulative total work** | **~583,500** | — |

The 327k figure crosses the 200k context window — implying compaction will fire (or the user will be on the 1M-context tier). This is realistic for a 4,000 LOC feature.

### Optimized behavior

The brainstorming chain itself is governed by Skill prompts that aren't directly under the mi-workflow's control. The recommendations doc does not propose changes to the chain's internal token use; it focuses on stages 1.5 and 6 where the mi-workflow IS in control.

That said, the chain's own design — particularly `subagent-driven-development` — already delegates per-task work to sub-agents when invoked. Whether that delegation happens depends on the chain's own decisions per task; mi-workflow can't force it.

| Activity | Main delta | Sub-agent delta |
| --- | --- | --- |
| (same as current; chain internals not modified) | ~327,500 | (variable, internal to chain) |
| **Stage 3 main delta** | **~327,500** | — |
| **Cumulative main** | **~418,200** | — |
| **Cumulative total work** | **~541,200** | — |

**Delta vs current: 0 from mi-workflow's perspective.** The cumulative difference (533,500 vs 418,200 main) comes entirely from the savings in stages 1.5 and 2 — main entered stage 3 with 90k of context instead of 206k, and exits with 418k instead of 533k.

### Stage 3 optimization suggestions

Mi-workflow has limited control here, but several levers exist:

- **Tighten `primer.md`.** Currently the primer can include broad scope and goals. Reduce it to the bare minimum — active scope, goals (compressed), 5–10 most likely-relevant skills/rules. The chain reads canonical files on demand anyway; over-bundling here just inflates main early.
- (*ADD THIS) **Strongly encourage `subagent-driven-development` mode.** When the chain decides between inline execution and sub-agent dispatch per task, the primer can nudge it toward delegation: *"Prefer subagent-driven-development for tasks touching >3 files or >100 LOC."* Mi-workflow can't enforce this but the primer text influences the chain's choices.
- **Smaller commit boundaries.** Chains that batch many file edits per commit accumulate more open-file context per commit cycle. If the chain's plan tasks are kept granular (one task = one file or one function), per-task context stays bounded.
- (*ADD THIS) **Make `direct` planning mode more attractive for small features.** The stage-3 launcher asks for `brainstorming` vs `direct`. `direct` skips the chain entirely and runs implementation in main — for features under 500 LOC this is often cheaper than chain ceremony. The default-mode prompt could note this trade-off explicitly.
- (*ADD THIS) **Pre-pass tighter skill metadata.** The chain reads skill descriptions to decide which to invoke. If `config.md` already filtered to ~10 skills/rules at stage 2, the chain has less to scan.

---

## Stage 4 — `/mi-continue` (Resume Handler) + diagrams

Activity: drift-check probe, optional drift prompt, generate implementation diagrams (`/mi-draw-diagrams` → `mi-generate-implementation-diagrams`), create `inspector-review.md` skeleton, atomic advance 3 → 5.

### Current behavior

Diagram generation re-reads the commit range (`base-commit..HEAD`) plus context files to render the existing-vs-new framing. For a 12-commit / 30-file scope, this is non-trivial.

| Activity | Main delta | Sub-agent delta |
| --- | --- | --- |
| `/mi-continue` body (mostly cached) | 1,000 | — |
| Drift-completion probe (file-system reads) | 800 | — |
| Drift prompt + inspector reply | 500 | — |
| **`/mi-draw-diagrams` invocation**: read `change-summary.md` (or generate it), walk `base-commit..HEAD`, read 8–12 files for diagram context, render 4–6 diagram files | **48,000** | — |
| `review.sh init` skeleton write | 500 | — |
| Atomic `progress.sh advance-to 3 5` | 200 | — |
| **Stage 4 main delta** | **~51,000** | — |
| **Sub-agents this stage** | — | **0** |
| **Cumulative main** | **~584,500** | — |
| **Cumulative total work** | **~634,500** | — |

### Optimized behavior

Delegate diagram generation to a sub-agent. The sub-agent reads the commit range and writes the diagram files directly; main only sees a return summary.

| Activity | Main delta | Sub-agent delta |
| --- | --- | --- |
| `/mi-continue` body (cached) | 1,000 | — |
| Drift probe | 800 | — |
| Drift prompt | 500 | — |
| **Diagram-generation sub-agent**: reads commit range, renders diagrams, writes files | — | **48,000** |
| Sub-agent return summary (diagram filenames + one-line purposes) | 1,500 | — |
| `review.sh init` | 500 | — |
| `progress.sh advance-to` | 200 | — |
| **Stage 4 main delta** | **~4,500** | — |
| **Sub-agents this stage** | — | **1, ~48,000 tokens** |
| **Cumulative main** | **~422,700** | — |
| **Cumulative total work** | **~593,700** | — |

**Delta vs current: −46,500 tokens this stage. Cumulative main delta: −161,800.**

### Stage 4 optimization suggestions

- (*ADD THIS) **Delegate diagram generation to a sub-agent.** Same pattern as stage 2's grounding pass. Sub-agent reads commit range, runs `commits.sh changed-files`, reads context files, renders diagram source files, returns one-line summary per diagram.
- (*ADD THIS) **Reuse `change-summary.md` cache.** The (base-commit, head) cache key is shared with `/mi-update-blueprint`. If the sub-agent (or chain) already produced `change-summary.md` mid-stage-3, stage 4 should NOT regenerate it — just read.
- **Skip drift prompt when probe set marker.** `commands/mi-continue.md` Resume Step 0 already handles this. Verify it's firing correctly — a session break that loses the marker but completes the rotation results in a redundant drift prompt that the user dismisses.
- (*ADD THIS) **Skip diagram regeneration when no commits since last diagrams.** Stage 7's diagram-refresh prompt already has this logic. Apply the same idempotency to stage 4: if `implementation/diagrams/` has commits newer than `base-commit`, don't re-render.
- (*ADD THIS and we can make the diagram generation optional by asking the inspector if they want diagram generation at this stage and also avoid generating .svg or .png files, just create .puml files) **Render only changed-area diagrams.** A 30-file change might touch only 2 of 5 diagram subjects. Sub-agent identifies which diagrams need update from the commit range; unchanged diagrams stay as stage-2 versions.

---

## Stage 5 — `/mi-continue` (Inspector Handler)

Activity: canonicalize free-form findings, list open findings, dispatch.

### Current behavior

| Activity | Main delta | Sub-agent delta |
| --- | --- | --- |
| `/mi-continue` body (cached) | 500 | — |
| Read `inspector-review.md` | 3,000 | — |
| `review.sh canonicalize` output (TSV rows for unstructured spans) | 1,000 | — |
| Per-finding classification + `review.sh add` calls | 4,000 | — |
| `review.sh list-open` | 200 | — |
| **Stage 5 main delta** | **~8,700** | — |
| **Sub-agents this stage** | — | **0** |
| **Cumulative main** | **~593,200** | — |
| **Cumulative total work** | **~643,200** | — |

### Optimized behavior

If all findings have `scope: fix` after classification, **Option 2A** auto-routes to direct mode and the savings show up in stage 6. For this scenario the 5 findings span fix / re-implement / re-plan, so 2A does NOT trigger — review-mode prompt defaults to `brainstorming` as today.

| Activity | Main delta | Sub-agent delta |
| --- | --- | --- |
| (same as current) | ~8,700 | — |
| **Stage 5 main delta** | **~8,700** | — |
| **Cumulative main** | **~431,400** | — |
| **Cumulative total work** | **~602,400** | — |

**Delta vs current: 0 at this stage.** The savings cumulative continue from stages 2 and 4.

### Stage 5 optimization suggestions

- **Already small** — stage 5 is one of the cheapest stages. Don't over-optimize.
- **Batch finding classification when >5 unstructured spans.** A single sub-agent classifies all spans at once and returns a TSV of `(line-start, line-end, severity, scope, summary)` rows. Main applies them via `review.sh add` in a loop.
- **Canonical metadata cache.** If the inspector revises findings mid-stage-5 (rare but possible), avoid re-classifying spans that are already structured `### IR-NNN` blocks. `review.sh canonicalize` already does this; verify it's not re-reading structured blocks.
- (*ADD THIS) **Auto-direct-mode hint here, not at stage 6.** Run the scope-distribution check during stage 5 (after classification). If 100% of findings are `fix`, persist `review-mode-suggestion: direct` to `progress.md` so stage 6 can default to direct mode without re-classifying.

---

## Stage 6 — `/mi-review` brainstorming review session — 4 iterations

Activity: generate `review-context.md`, ask review-mode, invoke brainstorming Skill, run loop until inspector types `approve`.

The 5 findings: `IR-001` (fix), `IR-002` (fix), `IR-003` (re-implement), `IR-004` (re-implement), `IR-005` (re-plan). Loop runs 4 iterations because the inspector adds 2 new findings mid-session in iteration 3.

### Current behavior

Each iteration the chain reads source files to address findings, edits, commits. Re-implement findings cascade into `executing-plans` (more reads). Re-plan finding cascades into `writing-plans` + `executing-plans` (substantially more).

Iteration breakdown:

| Iteration | Findings addressed | Reads | Edits/commits | Main delta this iter |
| --- | --- | --- | --- | --- |
| 1 | IR-001, IR-002 (both fix) | 4 files for context | 2 commits | ~22,000 |
| 2 | IR-003, IR-004 (re-implement) — `executing-plans` re-entry | 8 files re-read | 4 commits | ~58,000 |
| 3 | IR-005 (re-plan) — `writing-plans` + `executing-plans` cascade | 12 files re-read, plan rewritten | 5 commits | **~110,000** |
| 4 | (inspector added IR-006, IR-007 as fix scope mid-session) | 3 files | 2 commits | ~18,000 |

| Activity | Main delta | Sub-agent delta |
| --- | --- | --- |
| `/mi-review` command body | 4,000 | — |
| Generate `review-context.md` (read requirements + run `commits.sh changed-files`) | 8,000 | — |
| Brainstorming Skill primer + initial setup | 6,000 | — |
| Iteration 1 (2× fix) | 22,000 | — |
| Iteration 2 (2× re-implement, executing-plans re-entry) | 58,000 | — |
| Iteration 3 (1× re-plan cascade) | 110,000 | — |
| Iteration 4 (2× fix from mid-session additions) | 18,000 | — |
| **Stage 6 main delta** | **~226,000** | — |
| **Sub-agents this stage** | — | **0** (chain inline) |
| **Cumulative main** | **~819,200** | — |
| **Cumulative total work** | **~869,200** | — |

Stage 6 alone adds 226k tokens. The cumulative crosses 819k — well past the 200k context window, deep into the 1M tier.

### Optimized behavior

Apply **Option 2B** (fresh per-iteration sub-agent on `go again`) and **Option 2D** (refresh `review-context.md` body per iteration). Option 2A (auto-direct-mode) does NOT apply because not all findings are `fix`.

The loop now spawns one fresh sub-agent per iteration. Each sub-agent reads `review-context.md` + the current `inspector-review.md`, addresses its assigned findings, commits, calls `review.sh set-status`, and returns a short summary. Cascading scopes (re-plan in iteration 3) still happen — but they happen *inside* the sub-agent and never enter main.

| Activity | Main delta | Sub-agent delta |
| --- | --- | --- |
| `/mi-review` command body | 4,000 | — |
| Generate `review-context.md` | 8,000 | — |
| Iteration 1 sub-agent (2× fix) | — | 22,000 |
| Iteration 1 return summary | 600 | — |
| Refresh `review-context.md` body (Option 2D) | 1,500 | — |
| Iteration 2 sub-agent (2× re-implement) | — | 58,000 |
| Iteration 2 return summary | 800 | — |
| Refresh `review-context.md` | 1,500 | — |
| Iteration 3 sub-agent (1× re-plan, full cascade INSIDE sub-agent) | — | 110,000 |
| Iteration 3 return summary | 1,200 | — |
| Refresh `review-context.md` | 1,500 | — |
| Iteration 4 sub-agent (2× fix) | — | 18,000 |
| Iteration 4 return summary | 600 | — |
| Final `approve` ceremony | 500 | — |
| **Stage 6 main delta** | **~20,200** | — |
| **Sub-agents this stage** | — | **4 sub-agents, ~208,000 tokens (disposable)** |
| **Cumulative main** | **~451,600** | — |
| **Cumulative total work** | **~830,600** | — |

**Delta vs current: −205,800 tokens this stage. Cumulative main delta: −367,600.**

This is by far the largest individual saving. Stage 6 went from adding 226k to main to adding 20k.

### Stage 6 optimization suggestions

- (*ADD THIS) **Option 2B — Fresh per-iteration sub-agent on `go again` (recommended P1).** The single biggest win. Each iteration spawns a fresh sub-agent with `review-context.md` + the new IR-NNN ids; the sub-agent addresses, commits, marks resolved, and returns a one-paragraph summary.
- (*ADD THIS) **Option 2A — auto-direct-mode for fix-only findings (recommended P1).** When stage 5 has classified all findings as `fix`, default review-mode to `direct` (skip brainstorming chain ceremony entirely).
- (*ADD THIS) **Option 2D — refresh `review-context.md` body each iteration (recommended P3).** Currently `review.sh sync-refs` re-points only the frontmatter. Add a `refresh-body` mode that regenerates the `## Implemented surface` and `## Open findings (snapshot)` sections from current git state.
- (*ADD THIS) **Option 2E — tighten `change-summary.md` body.** Bound diff excerpts (max 50 lines per file, 500 lines total). Affects stages 4, 6, and 8.
- **Option 2C — lower cluster-delegation threshold from >5 to ≥2.** Made redundant by Option 2B if Option 2B is implemented.
- **Cap re-spec / re-plan cascades to a separate session.** When a finding's scope is `re-spec`, the cascade runs `brainstorming` + `writing-plans` + `executing-plans` — that's effectively a second stage 3. Consider making this an explicit sub-agent boundary: the cascade runs in its own sub-agent, and main only sees that the cascade completed and what it changed.
- (*ADD THIS) **Approve-with-deferred-findings shortcut.** When the inspector types `approve` with open findings remaining, the spec already supports `completed` (deferred). Surface this prominently — for cases where 1-2 findings are non-blocking, deferring is cheaper than a 5th iteration.
- (*ADD THIS) **Pre-classify cascades before invoking the chain.** If the chain is about to do a `re-plan`, the millwright can pre-fetch the relevant plan/spec context once and pass it; the chain doesn't re-walk to find context that's already known.

---

## Stage 7 — auto-advance

Activity: post-review-resume handler advances 6 → 7 atomically. Set `inspector-review-completed=true`, clear `sub-flow`. Optional diagram refresh prompt (skipped here — no new commits since iteration 4 diagrams are fresh).

### Current and Optimized

| Activity | Main delta | Sub-agent delta |
| --- | --- | --- |
| Open-findings completion check | 200 | — |
| Diagram-refresh prompt (asked, replied `n`) | 500 | — |
| Atomic `progress.sh advance-to 6 7` | 200 | — |
| **Stage 7 main delta** | **~900** | — |
| **Cumulative main (current)** | **~820,100** | — |
| **Cumulative main (optimized)** | **~452,500** | — |
| **Cumulative total work (current)** | **~870,100** | — |
| **Cumulative total work (optimized)** | **~831,500** | — |

### Stage 7 optimization suggestions

- **Already minimal.** Don't over-optimize.
- **Skip the diagram-refresh prompt when no review-loop commits.** The prompt already self-suppresses when `new_since_diagrams == 0` (per `commands/mi-continue.md` Review-Resume Step 2.5). Verify the suppression is firing correctly — the count check is git-log based; a session break mid-iteration could miscount.
- **Make diagram-refresh decision automatic for `n`-only cycles.** If the inspector reflexively answers `n` to this prompt every time, persist a per-cycle preference (`refresh-diagrams: never|prompt|auto`) and skip the prompt accordingly.

---

## Stage 8 — `/mi-complete-workflow`

Activity: rotate `blueprints/current/` into `history/v[N+1]/`, archive live `implementation/` folder alongside, regenerate fresh `current/` from the codebase + diff (`completion`-kind blueprint regeneration), advance todos IMPLEMENTING → IMPLEMENTED, pop the queue, finalize.

### Current behavior

Completion blueprint regeneration runs an implementation-driven pass (reads `change-summary.md` + targeted `git diff base-commit..HEAD` hunks) — bounded but not free.

| Activity | Main delta | Sub-agent delta |
| --- | --- | --- |
| `/mi-complete-workflow` command body | 5,000 | — |
| `blueprints.sh rotate` (filesystem moves; minimal) | 500 | — |
| Archive `implementation/` to `history/v[N+1]/implementation/` | 300 | — |
| **`/mi-update-blueprint --reason-kind=completion`**: read `change-summary.md` (cached partly) + targeted `git diff` hunks + regenerate `requirements.md` / `config.md` / diagrams | **55,000** | — |
| Update todos to IMPLEMENTED | 500 | — |
| `progress.sh finish` | 200 | — |
| Open next feature in queue (`audit-log`) — but queue advance is the next cycle's stage 2 trigger via Row A | 0 | — |
| **Stage 8 main delta** | **~61,500** | — |
| **Sub-agents this stage** | — | **0** |
| **Cumulative main** | **~881,600** | — |
| **Cumulative total work** | **~931,600** | — |

### Optimized behavior

Apply Architectural Principle 3: delegate the completion-blueprint regeneration to a sub-agent. Same pattern as stage 2.

| Activity | Main delta | Sub-agent delta |
| --- | --- | --- |
| `/mi-complete-workflow` command body | 5,000 | — |
| Rotate + archive | 800 | — |
| **Completion-regeneration sub-agent**: reads `change-summary.md` + diffs, writes new `current/` files | — | **55,000** |
| Sub-agent return summary | 1,500 | — |
| Todos IMPLEMENTED + finish | 700 | — |
| **Stage 8 main delta** | **~8,000** | — |
| **Sub-agents this stage** | — | **1, ~55,000 tokens** |
| **Cumulative main** | **~460,500** | — |
| **Cumulative total work** | **~894,500** | — |

**Delta vs current: −53,500 tokens this stage. Cumulative main delta: −421,100.**

### Stage 8 optimization suggestions

- (*ADD THIS) **Delegate completion regeneration to a sub-agent.** Same pattern as stage 2 grounding. Largest single stage-8 saving.
- (*ADD THIS) **Skip regeneration when blueprint is already fresh.** If `/mi-update-blueprint` ran during stage 4's drift check and `current/` already reflects the implementation, completion-rotation can move the existing `current/` directly into history without regenerating. Check via `commits.sh change-summary-fresh` — if fresh AND drift-check happened this cycle, skip regeneration.
- (*ADD THIS) **Reuse the implementation diagrams.** `current/diagrams/` and `implementation/diagrams/` should already be aligned by stage 7's refresh prompt. Stage 8 doesn't need to re-render — just copy `implementation/diagrams/` into the rotated `current/` of the new history version.
- (*ADD THIS) **Atomic finalize.** Multiple `progress.sh set` calls and todo updates can race with hooks. Use a single `progress.sh advance-to 7 -1 --set ...` style transition where possible to reduce hook re-validation cost.
- (*ADD THIS) **Lazy archival.** `implementation/` archival into `history/v[N+1]/implementation/` is filesystem-only (zero token cost). But the `change-summary.md` and `review-context.md` inside it have frontmatter that gets re-validated by the hook on archival. Skip validation for archived files (they're frozen and won't be edited).

---

## Side-by-side cumulative summary

Cumulative main-context size and cumulative total work after each stage. Lower is better for both.

| Stage | Activity | Main (current) | Main (optimized) | Total work (current) | Total work (optimized) | Per-stage main Δ | Running main Δ |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `/mi-run` (intake) | 61,000 | 61,000 | 111,000 | 111,000 | 0 | 0 |
| 1.5 | `/mi-continue` ×2 (queue ordering) | 111,700 | 65,900 | 161,700 | 115,900 | −45,800 | −45,800 |
| 2 | `/mi-apply-impact` (blueprints) | 206,000 | 90,700 | 256,000 | 213,700 | −69,500 | −115,300 |
| 3 | `/mi-plan-implementation` (chain) | 533,500 | 418,200 | 583,500 | 541,200 | 0 | −115,300 |
| 4 | `/mi-continue` (diagrams) | 584,500 | 422,700 | 634,500 | 593,700 | −46,500 | −161,800 |
| 5 | `/mi-continue` (inspector handler) | 593,200 | 431,400 | 643,200 | 602,400 | 0 | −161,800 |
| 6 | `/mi-review` ×4 iterations | 819,200 | 451,600 | 869,200 | 830,600 | −205,800 | −367,600 |
| 7 | auto-advance | 820,100 | 452,500 | 870,100 | 831,500 | 0 | −367,600 |
| 8 | `/mi-complete-workflow` | 881,600 | 460,500 | 931,600 | 894,500 | −53,500 | −421,100 |

**Reading the table:**

- "Main" columns = bytes occupying main agent context after this stage (sticky; affects per-turn cost and compaction risk).
- "Total work" columns = sum of all tokens processed across main + every sub-agent through this stage (the figure to compare against a session budget).
- The optimization reduces **main** by 47.7% (881k → 460k) but reduces **total work** by only 4% (931k → 894k). The optimization relocates work into disposable contexts; it doesn't dramatically reduce total compute.
- The main-context savings compound across turns via prompt caching: smaller cumulative main = smaller cached prefix per turn = lower per-turn billing across hundreds of turns. This is where the real session-budget win shows up.

### Sub-agent activity summary (optimized)

| Stage | Sub-agents | Total sub-agent tokens (disposable) | Returns to main |
| --- | --- | --- | --- |
| 1 | 1 (per-file summarization) | 50,000 | ~1,500 |
| 1.5 | 0 (or 1 if Option 1B) | 0–40,000 | 0–500 |
| 2 | 2 (codebase grounding + skill filter) | 73,000 | ~5,000 |
| 3 | (chain internal — variable) | — | — |
| 4 | 1 (diagram generation) | 48,000 | ~1,500 |
| 5 | 0 | 0 | 0 |
| 6 | 4 (one per review iteration) | 208,000 | ~3,200 |
| 7 | 0 | 0 | 0 |
| 8 | 1 (completion regeneration) | 55,000 | ~1,500 |
| **Totals** | **9** | **~434,000** | **~12,700** |

The "Returns to main" column is the total token cost added to main from sub-agent dispatch. Across the entire cycle, sub-agents that processed ~434k tokens of work contributed only ~13k tokens to main context — a roughly 33× reduction in context-window pressure for the work they performed.

---

## Session-budget analysis

Comparing the cycle against a Claude Max 5x ~5M token-equivalent session window.

### Total work per cycle (raw)

| Metric | Current | Optimized |
| --- | --- | --- |
| Cumulative total work | 932,000 | 895,000 |
| % of 5M Max 5x window | ~19% | ~18% |

By raw total-work alone, both versions fit comfortably in a single Max 5x session. **But this measure ignores per-turn re-sends with caching**, which is the dominant cost in practice.

### Effective billing per cycle (with prompt-cache re-sends)

The mi-workflow runs ~120 turns end-to-end (rough estimate: ~5 turns per stage × 9 stages, plus ~50–80 turns within stages 3 and 6 for the chain and review loop). Each turn re-sends the current prompt prefix; cached prefixes cost ~10% of normal.

Approximate effective billing:

```
effective_billing ≈ total_work + (turns × average_cumulative_main × 0.1)
```

| Metric | Current | Optimized |
| --- | --- | --- |
| Average cumulative main across the cycle | ~440,000 | ~230,000 |
| Cache-amortized re-send cost per turn | ~44,000 | ~23,000 |
| Total re-send cost (120 turns) | ~5,280,000 | ~2,760,000 |
| Plus total work | 932,000 | 895,000 |
| **Effective billing per cycle** | **~6,200,000** | **~3,650,000** |
| **% of 5M Max 5x window** | **~124%** | **~73%** |

**Reading the result:**

- Under **current** behavior, one big-feature cycle is estimated to consume ~1.24 Max 5x sessions worth of tokens. In practice, the user runs out of session quota mid-cycle.
- Under **optimized** behavior, one big-feature cycle consumes ~73% of a Max 5x session. The cycle fits in a single window, with ~27% headroom for retries, exploration, and overhead.

The optimization roughly halves effective billing per cycle. **This is the answer to whether one big-feature workflow fits in a Max 5x session: under current behavior likely no, under optimized behavior yes with margin.**

### Smaller-feature scaling

For a typical (smaller) feature — single feature, ~500 LOC scope, 1–2 review iterations — the absolute numbers shrink to roughly 1/4 of the worst case:

| Metric | Current (typical) | Optimized (typical) |
| --- | --- | --- |
| Cumulative total work | ~230,000 | ~225,000 |
| Cumulative main | ~220,000 | ~120,000 |
| Effective billing per cycle | ~1,500,000 | ~900,000 |
| % of 5M Max 5x window | ~30% | ~18% |

A typical cycle fits comfortably in a Max 5x session under both versions. The optimization payoff is bigger on big features (where current behavior breaches the budget) and smaller on typical features (where headroom already exists).

### Caveats on these numbers

- **The 5M Max 5x figure is approximate.** Anthropic's actual limits are weighted-message-based and not publicly documented as token counts. Some sessions stretch to 10M+; some compress to 3–4M depending on cache hit rate, output volume, and tool-use overhead. Use 5M as a conservative working number.
- **Turn count varies.** A workflow with many inspector interactions (lots of `go again` cycles, drift prompts, multi-batch queue ordering) can hit 200+ turns. Conversely, a streamlined cycle might run in 60 turns. Effective billing scales linearly with turn count.
- **Cache hit rate is assumed high (~90% on prefix re-sends).** A cold start, frequent compaction events, or context modifications between turns reduce the hit rate and increase effective cost.
- **Output token cost is folded into the work estimate but not separately tracked.** Output tokens cost ~5× input tokens at API rates; if a stage produces unusually large generated output (e.g., a long spec or plan), its effective cost is higher than the raw token count suggests.

---

## Key takeaways

1. **The cycle's three biggest single-stage costs are stage 3 (chain), stage 6 (review loop), and stage 2 (blueprint generation), in that order.** Stage 3 the mi-workflow has limited leverage over (chain internals); stages 2 and 6 are fully addressable.

2. **The recommendations cut roughly half of the cycle's main-context cost** (881k → 460k for this scenario, a 47.7% reduction). The biggest single win is stage 6 (Option 2B fresh per-iteration sub-agent), worth 205k by itself.

3. **Total work per cycle changes much less than main-context size** (932k → 895k, a 4% reduction). The optimization relocates work from main into disposable sub-agent contexts; it doesn't eliminate work. **The session-budget benefit comes from cache amortization of the smaller prefix across many turns**, not from doing less total work.

4. **Under current behavior, one big-feature cycle estimates at ~124% of a Max 5x session window** (effective billing ~6.2M vs ~5M budget). Under optimized behavior, it estimates at ~73%. This is the difference between "exhausts the session quota mid-cycle" and "fits with headroom."

5. **The 200k context window crosses early under current behavior** — at stage 2 the cumulative main is already 206k. The optimized version stays under 200k all the way through stage 5, only crossing it at stage 3 (where the chain itself is the unavoidable cost). For workflows on the 200k-tier (non-1M), this is the difference between "compaction never fires" and "compaction fires multiple times mid-cycle."

6. **Stage 1.5 is small in absolute terms (~46k saved) but architecturally important.** It establishes the principle that intake stages do not read code. Without that fix, the workflow has an early invariant violation that's easy to extend in worse directions.

7. **For typical (smaller) features, the absolute numbers shrink but the proportions stay similar.** A single-feature cycle with 5-file scope and 1 review iteration scales every row by roughly 1/4. The relative impact of optimizations stays in the same range. The optimization payoff is biggest on big features (where context pressure matters most) and meaningful on small features (where it just keeps things tidy).

---

## Caveats

- **Numbers are estimates with stated assumptions.** Real workflow runs will vary based on file sizes, codebase shape, model behavior, and prompt-cache hit rates. The intent is to show *relative* impact, not predict exact runtime cost.
- **Per-turn cost is not the same as context-window occupancy.** With prompt caching, repeat reads of the same content cost ~10% of normal at runtime. The "cumulative main" numbers track context-window bytes, which is what determines whether compaction fires and what the per-turn cache prefix size is. The session-budget analysis above estimates per-turn cost separately.
- **Stage 3 cost is highly variable.** A 4,000-LOC feature is on the larger end. A 500-LOC feature might run stage 3 in under 50k tokens. Stage 3's internal token use is dominated by the chain's design and execution choices, which mi-workflow does not control directly.
- **Sub-agent dispatch has overhead** beyond the work tokens themselves: prompt construction, summary parsing, hook re-validation. The numbers above include rough overhead estimates but real overhead may be 10–20% higher per sub-agent.
- **The "isolated from mi-workflow" wording in the spec refers to logical isolation** (mi-workflow doesn't read the chain's spec/plan files), not session isolation. Skill invocations run in the same Claude Code session and their reads do accumulate in main context, contrary to what an unfamiliar reader might assume from the term.
- **Anthropic does not publish exact token limits for plan tiers.** The 5M Max 5x figure used here is a community-derived approximation. Treat it as an order-of-magnitude reference, not a precise budget.
