# Implementation Report — Context Optimization

A non-technical summary of what shipped in the context-optimization pass. For the detailed step-by-step record, see `implementation-plan.md`. For the rationale behind each change, see `recommendations.md`. For predicted impact numbers, see `workflow-simulation.md`.

## What this work is about

The mo-workflow was using more main-agent context than it needed to. Two stages were the worst offenders:

- **Stage 6 (the review loop)** — every iteration accumulated source-file reads on top of all prior iterations, so a 5-iteration loop carried ~150–500k tokens of cumulative reads in the main session.
- **Stage 1.5 (queue ordering)** — was reading the codebase even though intake stages aren't supposed to look at code yet.

The fix is one consistent pattern, applied across every stage where it helps: **push large reads into fresh sub-agents whose context evaporates when they finish, instead of doing those reads in the main session.** Main keeps a small, structured summary; the sub-agent does the heavy work and disappears.

The goal isn't to do less work — it's to keep main's context small. Smaller main context means smaller per-turn re-sends, less compaction risk, and more cycles fitting in a Claude Max session window.

## What changed, by stage

### Stage 1 — Reading the journal

Mostly unchanged. Per-file summarization for very large files was already in place; we added **per-folder summarization** for the "many small files" case (a folder with more than 5 files totaling more than 40 KB now gets one sub-agent per folder rather than reading every file in main).

### Stage 1.5 — Picking the order to work features in

The codebase scan that used to run here is gone. The handler now tries journal-only ordering first, runs a quick heuristic to detect ambiguity, and only delegates to a sub-agent for the codebase-aware analysis when the heuristic flags real cross-feature dependencies. The sub-agent's findings are cached so a mid-cycle re-entry doesn't re-derive them. **Net effect: most cycles never read code at this stage; the rare ones that need it spend a few hundred tokens in main, not tens of thousands.**

### Stage 2 — Generating the blueprint

The codebase-grounding pass — which used to walk source files in main to identify the seam each todo touches — is now delegated. A fresh sub-agent does the seam walk and writes a structured `grounding-report.md` (a new audit artifact). Main reads the small report instead of the seam.

### Stage 3 — Brainstorming and implementation

The mo-workflow has limited control here (the brainstorming Skill drives the work). We added **guidance hints** to the primer the chain reads at launch — explicit thresholds for when to use sub-agent delegation per task and when direct mode is the better choice.

### Stage 4 — Drawing the implementation diagrams

Three changes worth noting:

1. **Per-event prompt.** Before generating diagrams, the workflow now asks the overseer (`y` / `n` / `auto`). Stage 2 is mandatory (blueprints require diagrams), so its prompt offers only `y` and `auto`. Stage 4 is optional; saying `n` records the skip and downstream stages know to reference the stage-2 diagrams instead.
2. **`.puml`-only output.** No SVG/PNG renders are produced by default — only the PlantUML source. A new `diagram-rendering` setting reserves the option to enable rendering on request, but it's never automatic.
3. **Seed-then-render.** When the overseer says yes, the sub-agent first copies the unchanged stage-2 diagrams into the implementation folder, then re-renders only the diagrams whose subjects actually changed in this cycle. Unchanged subjects keep their stage-2 versions verbatim.

### Stage 5 — Overseer review

The overseer-review file is now scanned at canonicalization time so the workflow knows whether all findings are simple fixes. This sets up the Stage 6 default-mode choice. The deferred-findings prompt at the end of a review session has been reworded to make it clear that `completed` is for "intentionally deferred non-blocking work" and isn't a default — the overseer must pick deliberately.

### Stage 6 — The review loop

The biggest change in the entire pass. The review loop used to hand control to the brainstorming Skill, which ran the whole iteration loop internally — accumulating reads across iterations. Now **main owns the iteration boundaries**: each iteration spawns a fresh sub-agent, gives it the open findings to address, receives a short summary back, and asks the overseer for `approve` / `go again` / `abort`. The sub-agent's own reads (potentially tens of thousands of tokens per iteration) live in disposable context and never enter main.

When stage 5 detected that all open findings are simple fixes, the prompt now defaults to direct mode (which skips the chain ceremony entirely). Cascade-scoped findings (`re-spec`, `re-plan`) get a "delta primer" telling the cascading chain which sections of the existing plan or spec are invalidated, so it can preserve the unchanged sections rather than regenerating from scratch.

### Stage 7 — Auto-advance

Largely unchanged. The diagram-refresh prompt now branches on whether stage 4 was skipped, and routes to a recovery generation prompt instead of the regular refresh prompt when needed.

### Stage 8 — Completing the workflow

The archival step now also moves the new `grounding-report.md` and the per-cycle telemetry artifact (when present) into the historical record alongside the existing files. The `progress.sh finish` helper gained an optional `--set` capability that future stage-8 logic can use to bundle a top-level write with finalization atomically.

## What overseers will notice

- **A new prompt at stage 4** asking whether to generate implementation diagrams (`y` / `n` / `auto`). Saying `auto` once skips the prompt for the rest of that feature workflow.
- **Stage 6 reviews feel snappier** — each iteration completes faster because main doesn't accumulate context across iterations.
- **Direct mode now defaults on** when all open findings are simple fixes. The overseer can override by typing `brainstorming`.
- **The deferred-findings prompt** at end-of-review is more deliberate. There's no default; the overseer picks `completed` / `abandoned` / `abort` explicitly.
- **The stage-5 review handoff message** explicitly mentions which folder to look at for diagrams (the implementation folder normally; the blueprint folder if stage 4 was skipped).

Most of the optimization work happens behind the scenes — the overseer's experience is the same shape as before, just with smaller context costs and a few new explicit choice points.

## New artifacts

The workflow now produces or maintains a few new files inside the per-feature working area:

- **`grounding-report.md`** — the stage-2 sub-agent's structured findings (seam, pre-existing components, cycle flavor per item). Lives in the implementation folder; archived with the rest at stage 8.
- **`context-ledger.md`** — per-cycle telemetry recording context-heavy events (which stage, which command, what was read, where). Coarse, not exact — the goal is regression detection, not exact accounting.
- **A canonical sub-agent return contract** — every sub-agent the workflow spawns now uses a fixed return shape (Result / Artifacts / Commits / Findings / Main-should-read), capping return summaries at roughly 1k tokens. This is what prevents the optimization from eroding over time.

## Risks

These are the things to watch when deploying or extending this work.

### High — Schema migration

The active block of `progress.md` gained five new required fields. Any in-flight workflow that started on the old schema will fail validation under the new one. **Recommend completing in-progress cycles on `main` before deploying this branch, or running a one-time migration helper that adds the fields with their default values.**

### High — Limited real-cycle exercise

The recipes in this PR are documented and pass syntax checks, but most of the new flows (per-iteration review sub-agent, stage-2 grounding delegation, diagram delegation, seed-then-render, journal-first ordering with sub-agent fallback, per-folder summarization) have not been run end-to-end on a representative cycle. A real-cycle test on this branch — and a comparison of context growth against a baseline run on `main` — is the recommended next step before merging.

### Medium — Sub-agent behavior depends on the runtime

Several optimizations depend on Claude correctly following the sub-agent prompts (return contract, delta primers, scope discipline). Where prompts are explicit, the success rate is high. The cascade delta primer in particular is **best-effort**: it asks the cascading chain to preserve unchanged sections, but the chain is owned out-of-tree. If it ignores the primer, the workflow regenerates fully — same behavior as before, no regression — but the savings won't materialize.

### Medium — More overseer prompts at stages 4 and 5

The per-event diagram prompt and the explicit deferred-findings prompt add a small number of overseer turns per cycle. The trade-off (control over diagram generation, deliberate deferral) was an explicit overseer preference, but it does mean a typical cycle now has 1–2 more touch points. The `auto` answer at the diagram prompt cuts that to one per feature workflow.

### Low — New required fields are easy to forget

Adding a future feature that touches the active block needs to remember that five new fields are required (`review-mode-suggestion`, `diagram-prompt`, `diagram-rendering`, `implementation-diagrams-skipped`, plus the existing ones). The `progress.sh activate` and `reset` constructors initialize them, so the contract is upheld for the happy path; ad-hoc test fixtures that build active-block dictionaries by hand may need updating.

### Low — Telemetry artifact is opt-in

The `context-ledger.md` infrastructure is in place but no command currently appends to it. Wiring the appends at the major stages would give a regression-detection signal; without that wiring, the ledger stays empty and the regression-detection benefit doesn't activate. This is a small follow-up commit when ready.

## What's next

1. **Test on a real cycle.** The one missing piece. Run a representative feature end-to-end on this branch and compare main-context growth against the same cycle on `main`. The simulation predicted ~50% reduction in main-context growth for the worst-case scenario; reality may differ.
2. **Decide on schema migration.** If any in-flight workflow needs to survive the upgrade, write the migration helper before merging.
3. **Wire the telemetry ledger.** Optional but high-value. Adds 5–10 lines per command and turns regression detection from "needs review" to "shows up in the ledger."
4. **Measure cascade frequency.** The Phase 7 delta-primer work was conditional on real cascade pain. If cascades are rare, the work is low-impact; if they show up often in the ledger telemetry, it pays off.

## Closing note

The optimization is structural, not about doing less work. The same number of files get read across the workflow — the question is just *where* those reads live. By moving them out of the sticky main-agent context and into disposable sub-agent contexts, the workflow stays well within Claude Code session budgets even on large features, and the per-turn cache prefix stays manageable across long review loops.

The architectural principles encoded in this pass — return contracts for sub-agents, cache invalidation discipline, main-read budget gates per stage, the per-cycle telemetry artifact — exist so that the gains are durable. Future workflow changes that follow the same principles will preserve the savings; changes that don't will surface in the ledger.
