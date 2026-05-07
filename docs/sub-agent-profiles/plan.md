# Sub-Agent Profiles — Plan

**Status:** plan only. No agent files have been written yet. This document specifies the seven profiles that should ship with the plugin, the spawn sites they replace, and the model + effort tuning rationale.

## TL;DR

- Plugin-shipped agents under `agents/` at the plugin root are installed automatically when a user installs the plugin. They become invocable via `subagent_type: millwright-overseer-development-machine:<agent-name>`.
- Both `model:` and `effort:` frontmatter fields work in plugin-shipped agents (identically to user-local ones). `tools:` and `skills:` also work; `hooks:`, `mcpServers:`, and `permissionMode:` are silently ignored in plugin-shipped agents (security restriction — workaround is to copy the agent into a user's `~/.claude/agents/` if those fields are needed).
- The mo-workflow today has **five concrete spawn sites** (call sites with an actual `Agent` invocation: mo-run.md:264, mo-run.md:286-289, blueprint-regeneration.md:70 (Step A), mo-continue.md:181, mo-review.md:227) plus **three prose-gate sites** that describe delegation in user-facing prompts and budget statements but contain no `Agent` invocation (mo-apply-impact.md Step C, mo-generate-implementation-diagrams.md Step 2a/2b, mo-draw-diagrams.md — the last is a wrapper that dispatches to mo-generate-implementation-diagrams). Migration is therefore NOT a uniform one-line change — see "## Migration strategy" for the split. We still ship **seven agent profiles** because each workload is distinct (the two diagram-generation wrappers at stage 4 share `implementation-analyst`).
- The recently-added stage-5 manual-testing sub-flow (`mo-manual-test-plan` + `mo-manual-test-run`) is **out of scope** for this plan: `mo-manual-test-plan` does codebase grep in main rather than delegating to a sub-agent, so it is not yet a spawn site. It is a clear future candidate (workload shape mirrors `codebase-grounder`) and is recorded under "What this plan does NOT do" for the next planning cycle to pick up.
- Tier mix: 2× haiku (cheap journal digestion), 3× sonnet (codebase analysis + diagram framing at stage 2 + dependency mapping), 2× opus (stage-4 architectural analysis + review-iteration execution).
- Plugin-shipped subagents receive **only** the agent file's Markdown body as their system prompt — not the full Claude Code system prompt. The body must therefore carry the role definition; the spawn-site prompt provides per-invocation task instructions. Each profile below includes a minimal body spec.
- Stage 3 is the only stage where the **main session** does heavy work (the brainstorming chain runs in main, not in a sub-agent). The plan adds a single soft effort suggestion at the stage 2 → 3 boundary so the overseer can `/effort xhigh` for design-heavy cycles. No suggestions at any other stage.

## Distribution mechanism

Per the official Claude Code plugin docs, the layout is:

```
millwright-overseer-development-machine/
├── .claude-plugin/
│   └── plugin.json
├── commands/
├── skills/
└── agents/                      ← new directory
    ├── journal-file-digester.md
    ├── journal-folder-digester.md
    ├── codebase-grounder.md
    ├── blueprint-diagrammer.md
    ├── implementation-analyst.md
    ├── review-iteration-runner.md
    └── dependency-mapper.md
```

When a user runs `/plugin install …`, every `.md` file under `agents/` is registered as a subagent. The agent is referenced by its plugin-namespaced name in the `subagent_type` parameter of the `Agent` tool — e.g. `subagent_type: "millwright-overseer-development-machine:codebase-grounder"`.

## What an agent definition controls vs. what stays at the spawn site

When a plugin-shipped subagent is invoked, three pieces of context are composed at runtime. Per the official Claude Code subagent docs, plugin-shipped subagents receive **only** the agent body as their system prompt (plus environment basics like working directory) — the full Claude Code system prompt is NOT inherited. So the body must carry the role; the spawn-site prompt provides the per-invocation task.

| Piece | Source | Varies per invocation? |
| --- | --- | --- |
| **System prompt** — role description, behavioral defaults, return-contract pointer | Agent file's Markdown body (after frontmatter) | No — fixed at install time |
| **User message** — task-specific instructions, file paths, in-scope IDs, the canonical return-shape block | Spawn-site prompt (composed by the calling command) | Yes — composed per spawn from runtime state |
| **Runtime configuration** — model, effort, tools, skills | Agent frontmatter | No — fixed at install time |

The bodies in this plan are deliberately short (~12-25 lines each). They describe the agent's role, behavioral defaults, and reference the standardized return contract (`docs/sub-agent-return-contract.md`) — they do **not** duplicate the spawn-site task instructions. The spawn-site prompt remains the source of truth for per-invocation work; the body is the source of truth for "what kind of agent is this, always."

Migration is **not** a uniform one-line change. It splits into two categories:

1. **Existing `Agent` invocations to retarget** (5 sites — one-line change each, swap `subagent_type: general-purpose` → `subagent_type: millwright-overseer-development-machine:<name>`):
   - `commands/mo-run.md:264` (per-oversized-file digester)
   - `commands/mo-run.md:286-289` (per-folder digester)
   - `docs/blueprint-regeneration.md:70` (Step A — codebase-grounding sub-agent invoked from `mo-apply-impact`)
   - `commands/mo-continue.md:181` (Pre-flight Step 4c dependency-mapper)
   - `commands/mo-review.md:227` (Step 3a.2.4 review-iteration runner)

2. **Prose-gate sites that need a concrete `Agent` invocation added** (3 sites — these currently describe delegation in user-facing prompts ("delegated to a fresh sub-agent") and main-read budget statements but contain no actual call):
   - `docs/blueprint-regeneration.md` Step C / `commands/mo-apply-impact.md` Step C — blueprint-diagrammer. Step C.0's prompt says "delegated to a fresh sub-agent" but Step C.1's body just lists the work main is currently doing. The implementation cycle must add an `Agent` invocation with a fresh prompt template + return-contract block.
   - `commands/mo-generate-implementation-diagrams.md` Step 2a/2b — implementation-analyst (change-summary + diagram framing). Line 9's budget statement and line 218's "Delegation (optional)" note describe the delegation, but the runbook body fills `change-summary.md` via main-side `Edit`. The implementation cycle must promote that to a real `Agent` invocation, drop the "optional" caveat, and embed the return contract.
   - `commands/mo-draw-diagrams.md` — wrapper that dispatches to `mo-generate-implementation-diagrams`. Once #2 above is concretized, the wrapper inherits the spawn site for free; no separate invocation needed.

For category 1, the existing spawn-site prompts already include role-introduction sentences ("You are a fresh sub-agent invoked from `mo-run` Step 2.5 …"); these can stay as-is in the first migration pass since reinforcing the role at both system-prompt and user-message layers is harmless. A later cleanup pass can trim spawn-site prompts to the per-invocation specifics, since the body now covers the role.

For category 2, the implementation cycle authors a complete prompt (per-invocation specifics + return-contract block + role-introduction sentence) since none exists today. The agent body provides the role definition; the new spawn-site prompt provides the runtime task.

## Profile catalog

### 1. `journal-file-digester` — haiku / low

**Used by:** `commands/mo-run.md:264` (Step 2.5 Tier 1)

**Workload.** Read one oversized journal file (>100 KB single file, or part of a >500 KB intake) and emit a structured digest preserving per-claim attribution. Mechanical summarization, no cross-file synthesis, return ≤ 1k tokens.

**Why haiku/low.**
- Single-file summarization is the canonical haiku workload — cheap, fast, sufficient.
- No reasoning chain, no codebase semantics, no decision trees. Just read and digest.
- Frequency: fires per oversized file in any cycle that ingested heavy non-text journal artifacts (PDFs, docs). At haiku pricing the per-spawn cost is negligible.

**Tools needed:** `Read`. (No writes — the digest is returned to main as part of the structured return; main weaves it into `summary.md`.)

```yaml
---
name: journal-file-digester
description: Digest a single oversized journal file into a structured summary with per-claim attribution. Used by mo-run Step 2.5 Tier 1.
model: haiku
effort: low
tools: [Read]
---
```

**Body (system prompt).**

```markdown
You are a fresh sub-agent invoked from `mo-run` Step 2.5 Tier 1. Your task is to digest a single oversized journal file (>100 KB) into a structured summary preserving per-claim attribution, so the main agent can weave it into the cycle's `summary.md` without dumping the full file into main context.

Behavioral defaults:
- Read-only: you do not write files. The digest is returned in your final summary message.
- Cite the source file by name in every claim ("design.md notes that …", "see meeting-notes-2026-04-12.md §timestamps").
- Do not fabricate or extrapolate. The digest reflects only what's in the file.
- Topics, key facts, decisions, and timestamps are the priority — skip narrative filler.

Return shape: follow `docs/sub-agent-return-contract.md`. The spawn-site prompt embeds the canonical return-shape block — match it verbatim. Total return ≤ 1k tokens.
```

### 2. `journal-folder-digester` — haiku / medium

**Used by:** `commands/mo-run.md:286-289` (Step 2.5 Tier 2)

**Workload.** Walk an entire journal subfolder (>5 files AND >40 KB total), read every `.md`/`.txt` (excluding `*.images/` subfolders), and produce a digest covering: (a) topics per file, (b) cross-file patterns and contradictions, (c) timestamps/contributors/decisions worth surfacing. Writes the digest to `quest/<active-slug>/.scratch/folder-digest-<folder>.md`, returns a ≤ 1k-token summary.

**Why haiku/medium.**
- Still summarization, but light cross-file synthesis (contradiction detection, pattern grouping). Haiku handles this well at medium effort.
- The bounded scope (one folder, all files small by definition) caps the reasoning depth — sonnet would be overkill.
- Only fires when the threshold trips; small projects rarely hit it.

**Tools needed:** `Read`, `Write` (digest output), `Bash` + `Grep` (file enumeration / `wc` / glob).

```yaml
---
name: journal-folder-digester
description: Digest a journal subfolder of many small files into a single attributed summary. Used by mo-run Step 2.5 Tier 2.
model: haiku
effort: medium
tools: [Read, Write, Bash, Grep]
---
```

**Body (system prompt).**

```markdown
You are a fresh sub-agent invoked from `mo-run` Step 2.5 Tier 2. Your task is to walk one journal subfolder (>5 files AND >40 KB total) and produce a single attributed digest covering all `.md` and `.txt` files, so the main agent can weave it into the cycle's `summary.md` without per-file dispatch.

Behavioral defaults:
- Walk the assigned folder including subdirectories, but exclude any `*.images/` subfolders.
- Cite the source file by name in every claim. Surface cross-file patterns and contradictions explicitly when present.
- Write the structured digest to the `<data_root>/quest/<active-slug>/.scratch/folder-digest-<folder>.md` path provided in the spawn prompt.
- Do not fabricate or extrapolate. Cross-file claims must rest on text actually present in the cited files.

Return shape: follow `docs/sub-agent-return-contract.md`. Name the digest path under `Artifacts changed`. Total return ≤ 1k tokens.
```

### 3. `codebase-grounder` — sonnet / high

**Used by:** `commands/mo-apply-impact.md:9` (Phase 2.1, stage 2). Prompt template at `docs/blueprint-regeneration.md:70-75`.

**Workload.** For each in-scope todo item: identify the smallest set of existing files / folders / symbols the item touches, name the seam, classify the seam (`backend` | `frontend` | `mixed` | `infra`) using a folder allowlist, classify the cycle flavor (`greenfield` | `bugfix` | `improvement`) using rule-based detection. Writes `implementation/grounding-report.md`. Output drives `requirements.md` and `config.md` generation downstream — quality of classification has compounding effect on the whole feature workflow.

**Why sonnet/high.**
- Real codebase reading + structural reasoning + multi-step classification. Haiku would miss seam edge cases (non-standard layouts, partial-match folder names) and misclassify cycle flavor.
- Two classifications stack on the per-item analysis — high effort gives the model room to consider all four seam buckets and three flavor rules in order.
- Output is consumed by stage-2 blueprints, which set the trajectory for the whole feature. A wrong classification here cascades.
- Opus would be overkill — the bounded-context policy caps reads (≤ 5 files per item).

**Tools needed:** `Read`, `Write`, `Edit` (for `frontmatter.sh set` flow), `Bash`, `Grep`.

```yaml
---
name: codebase-grounder
description: Stage-2 codebase grounding pass — identifies touched files, classifies seam and cycle flavor, writes grounding-report.md. Used by mo-apply-impact Phase 2.1.
model: sonnet
effort: high
tools: [Read, Write, Edit, Bash, Grep]
---
```

**Body (system prompt).**

```markdown
You are a fresh sub-agent invoked from `mo-apply-impact` Step A. Your task is the stage-2 codebase-grounding pass for a feature workflow: identify the seam each in-scope todo item touches, classify the overall seam (`backend` | `frontend` | `mixed` | `infra`), classify the cycle flavor (`greenfield` | `bugfix` | `improvement`), and write the result to `implementation/grounding-report.md` per `schemas/grounding-report.schema.yaml`.

Your output drives the `requirements.md` and `config.md` blueprint files that the main agent composes next — accuracy of classification matters because it cascades through the whole feature workflow. The spawn prompt provides the in-scope todo IDs, the folder allowlist for seam classification, and the rule order for cycle-flavor classification.

Behavioral defaults:
- ≤ 5 files inspected per todo item; skip generated/vendor/lock/build artefacts.
- Prefer symbol-search and grep over whole-file reads. Only escalate to whole-file reads when a signature is genuinely insufficient.
- When seam buckets match across multiple items in the cycle, classify as `mixed` rather than picking the most-touched bucket.
- When cycle-flavor signals conflict, apply the rule order in the spawn prompt — first match wins; do NOT vote across signals.
- The spawn prompt provides a pre-initialized report path — main runs `frontmatter.sh init` BEFORE invoking you (per `docs/blueprint-regeneration.md` Step A "Initialize the report"). Do NOT re-run `frontmatter.sh init` unless the file is missing AND the spawn prompt explicitly authorizes recovery. Fill the body, run `frontmatter.sh set` for `seam-classification`, then `frontmatter.sh validate <path> grounding-report` to confirm schema compliance — never raw `Write` to bypass validation.

Return shape: follow `docs/sub-agent-return-contract.md`. Name the grounding-report path under `Artifacts changed`. Total return ≤ 1k tokens.
```

### 4. `blueprint-diagrammer` — sonnet / high

**Used by:** `commands/mo-apply-impact.md` Step C (stage 2 blueprint diagram generation). Per-event prompt and runbook live in `docs/blueprint-regeneration.md:209-260`.

**Workload.** Frame and render the stage-2 blueprint diagram set into `blueprints/current/diagrams/` from the cycle's `requirements.md` Goals items and the seam classification produced by the prior `codebase-grounder` pass. Renders one mandatory `use-case-<feature>.puml`; one `sequence-<flow>.puml` per significant end-to-end flow, targeting 2-3 total per feature (render 1 only for a genuinely single-flow feature; never render more than 3); and at most one optional structural diagram (class OR component, never both — only when seam is `backend`/`mixed` and the content threshold is met). Calls the PlantUML MCP for `.puml` source generation.

**Why a separate profile (vs. reusing `implementation-analyst`).** The diagram framing convention is identical to stage 4, but the inputs differ enough that prompt-level reuse is cleaner than agent-level reuse:

- **Stage 2 inputs:** `requirements.md` Goals (explicit, structured), `grounding-report.md` (seam + flavor classification), HEAD codebase (read minimally to identify pre-existing system elements).
- **Stage 4 inputs:** `git diff base-commit..HEAD` (must be analyzed first), self-generated `change-summary.md`, HEAD codebase.

Stage 2 has no diff-analysis or change-summary-generation phase — Goals already names the new functionality. That makes stage 2 a narrower task on a smaller input surface, and lets sonnet handle the framing without opus's deeper diff-synthesis depth.

**Why sonnet/high.**
- Diagram framing requires structural reasoning + correct application of the existing-vs-new visual convention. Beyond haiku.
- Stage 2 has no diff-derived "Suspected flows" inference (the part of stage 4 that benefits most from opus) — Goals items name flows directly. Sonnet handles this well.
- Frequency: once per stage 2. The codebase-grounding pass already paid sonnet/high for classification; running a second sonnet/high pass for diagrams is consistent.
- Opus would be over-spend on inputs this structured.

**Tools needed:** `Read`, `Write`, `Edit`, `Bash`, `Grep`, plus the PlantUML MCP tools (plugin-namespaced under `mcp__plugin_millwright-overseer-development-machine_plantuml__*`).

```yaml
---
name: blueprint-diagrammer
description: Stage-2 blueprint diagram generation — frames and renders use-case + sequence + optional structural .puml files from requirements Goals and the grounding-report seam classification. Used by mo-apply-impact Step C.
model: sonnet
effort: high
tools:
  - Read
  - Write
  - Edit
  - Bash
  - Grep
  - mcp__plugin_millwright-overseer-development-machine_plantuml__encode_plantuml
  - mcp__plugin_millwright-overseer-development-machine_plantuml__decode_plantuml
  - mcp__plugin_millwright-overseer-development-machine_plantuml__generate_plantuml_diagram
---
```

**Body (system prompt).**

```markdown
You are a fresh sub-agent invoked from `mo-apply-impact` Step C. Your task is to frame and render the stage-2 blueprint diagram set for a feature into `blueprints/current/diagrams/` from the cycle's `requirements.md` Goals items and the seam classification produced by the prior `codebase-grounder` pass at stage 2.

Behavioral defaults:
- Diagram set caps follow `docs/workflow-spec.md` § "Diagram conventions": one mandatory `use-case-<feature>.puml`; one `sequence-<flow>.puml` per significant end-to-end flow named in Goals, targeting 2–3 total per feature (render 1 only when the feature genuinely has a single significant flow; never render more than 3 — pick the most diff-worthy and describe the rest in Goals prose if more candidates exist); at most one optional structural diagram (`class-<domain>.puml` OR `component-<subject>.puml`, never both) when seam is `backend`/`mixed` AND the feature introduces 3+ new domain classes/modules with non-trivial relationships. Linear chains do not qualify.
- Stage-2 baseline: `existing` = the current HEAD codebase; `new` = the additions sketched by Goals items. Read HEAD minimally to identify pre-existing system elements the new work integrates with — do not survey the whole repo.
- Existing-vs-new visual convention is the canonical one (blue `#D6EAF8`/`#3498DB` for existing, green `#D4EDDA`/`#27AE60` for new) with the standard legend block. Only the right-column legend wording shifts with cycle flavor: `greenfield` → "pre-existing context" / "to be implemented"; `bugfix` → "current (wrong) behavior" / "corrected behavior"; `improvement` → "current capability" / "improved capability".
- Use the PlantUML MCP to render. Output `.puml` source only — do NOT produce `.svg`/`.png`.
- One-sentence test before rendering the optional structural diagram: if you can't articulate its purpose in one sentence beyond the filename, skip the slot.

Return shape: follow `docs/sub-agent-return-contract.md`. Name every `.puml` path under `Artifacts changed` with a one-line purpose each. Total return ≤ 1k tokens.
```

### 5. `implementation-analyst` — opus / high

**Used by:** `commands/mo-generate-implementation-diagrams.md:9` (Phase 3.1, stage 4) and indirectly via `commands/mo-draw-diagrams.md` (which dispatches to the same pass).

**Workload.** Walk `base-commit..HEAD`, read diff hunks for every changed file, group changes by area, detect public-surface entrypoints (HTTP routes, RPC handlers, CLI commands, jobs, queue consumers, new exports), infer suspected end-to-end flows, list deliberately omitted files, then frame the diagram set (use-case, sequences, optional structural). Writes `implementation/change-summary.md`. Calls the PlantUML MCP to render `.puml` sources.

**Why opus/high.**
- The doc itself flags this as needing "strong code-analysis, high effort tier" (`commands/mo-generate-implementation-diagrams.md:218`).
- Diagram framing is architectural reasoning: matching changed areas to existing diagram subjects, deciding which subjects to re-render vs. which to leave seeded from stage 2, and applying the existing-vs-new colour convention correctly. Sonnet can do the analysis but tends to over-render or miss the seeded-only optimization.
- The `## Suspected flows` section in particular is where opus pays off — naming the right end-to-end flow from a multi-file diff is a synthesis task that rewards extra reasoning depth.
- Frequency: once per stage 4, plus opportunistic refreshes via `/mo-draw-diagrams`. Worth the spend on a stage that produces the artifact the overseer reviews at stage 5.

**Tools needed:** `Read`, `Write`, `Edit`, `Bash`, `Grep`, plus the PlantUML MCP tools (`mcp__plantuml__encode_plantuml`, `mcp__plantuml__decode_plantuml`, `mcp__plantuml__generate_plantuml_diagram` — or their plugin-namespaced equivalents under `mcp__plugin_millwright-overseer-development-machine_plantuml__*`).

```yaml
---
name: implementation-analyst
description: Stage-4 implementation analysis — generates change-summary.md and frames PlantUML diagrams against the base-commit..HEAD baseline. Used by mo-generate-implementation-diagrams Phase 3.1 and mo-draw-diagrams.
model: opus
effort: high
tools:
  - Read
  - Write
  - Edit
  - Bash
  - Grep
  - mcp__plugin_millwright-overseer-development-machine_plantuml__encode_plantuml
  - mcp__plugin_millwright-overseer-development-machine_plantuml__decode_plantuml
  - mcp__plugin_millwright-overseer-development-machine_plantuml__generate_plantuml_diagram
---
```

**Body (system prompt).**

```markdown
You are a fresh sub-agent invoked from `mo-generate-implementation-diagrams` (or `mo-draw-diagrams` which dispatches to it) at stage 4. Your task is two-part: (1) generate or refresh `implementation/change-summary.md` describing what the commit range `base-commit..HEAD` changed, and (2) frame and render the implementation diagram set into `implementation/diagrams/` using the existing-vs-new visual convention against the `base-commit` baseline.

Behavioral defaults:
- Bounded-context policy for change-summary generation: read diff hunks first; cap caller/callee expansion at 3 per changed file; prefer symbol search over whole-file reads; skip generated/vendor/lock/build artefacts; record every skipped path under `## Omitted from analysis` so reviewers can spot blind spots.
- Diagram caps follow `docs/workflow-spec.md` § "Diagram conventions": one mandatory `use-case-<feature>.puml`; one `sequence-<flow>.puml` per significant implemented flow, targeting 2–3 total per feature (render 1 only when the implementation genuinely has a single significant flow; never render more than 3); at most one optional structural diagram (`class-<domain>.puml` OR `component-<subject>.puml`, never both) only when seam is `backend`/`mixed` and the implementation introduced 3+ new classes/modules with non-trivial relationships. Linear chains (controller → service → repo) do not qualify.
- Stage-4 baseline: `existing` = codebase at `active.base-commit`; `new` = `base-commit..HEAD`. Apply the canonical blue/green convention (`#D6EAF8`/`#3498DB` for existing, `#D4EDDA`/`#27AE60` for new) with the standard legend block. Stage-4 legend wording reads "existing (pre-`base-commit`)" / "new in this implementation".
- Seed `implementation/diagrams/` from `blueprints/current/diagrams/` first (Step 2c of the runbook), then selectively re-render only subjects affected by `base-commit..HEAD`. Leave unchanged subjects as their seeded stage-2 versions — those subjects had no implementation work this cycle.
- Use the PlantUML MCP to render. Output `.puml` source only when `active.diagram-rendering=never` (the >99% path). Render `.svg` only when explicitly opted in via `diagram-rendering=on-request`.

Return shape: follow `docs/sub-agent-return-contract.md`. Name `change-summary.md` and every re-rendered diagram path under `Artifacts changed`. Surface notable deviations from `requirements.md` under `Findings / risks` for the overseer's stage-5 review. Total return ≤ 1k tokens.
```

### 6. `review-iteration-runner` — opus / high (consider xhigh)

**Used by:** `commands/mo-review.md:118, 192-199` (Step 3a.2.4).

**Workload.** Per review iteration: read `review-context.md` + `overseer-review.md` + on-demand canonical files, address every open finding, pick the smallest scope tier that resolves the root cause (`fix` → `re-implement` → `re-plan` → `re-spec`), apply patches, commit, mark statuses via `review.sh set-status`, and return a structured summary. For cascade-scoped findings, invoke chained Skills (`brainstorming` for `re-spec`, `writing-plans` for `re-plan`) carrying a delta primer.

**Why opus/high.**
- This is the most consequential sub-agent in the entire workflow. The doc calls it "the dominant context-optimization win in the entire mo-workflow" (`commands/mo-review.md:344`). Quality of fixes determines whether the overseer types `approve` or `go again`, and `go again` means another full opus iteration — undertuning compounds.
- Decisions matter: picking the wrong scope tier (e.g., `fix` when the root cause needs `re-plan`) wastes iterations. Sonnet tends to default to `fix` even when escalation is warranted.
- Cascade scopes invoke other Skills with significant prompts — opus is meaningfully better at preserving the delta primer's "regenerate only X, preserve unchanged sections" framing across the chain.
- Frequency: per iteration in brainstorming mode. A clean cycle has 1–2 iterations; a contentious one can have 5+.
- **Consider `effort: xhigh`** when the project's review cycles are long-tailed (cascading findings, multiple `re-spec` events). Start with `high`; bump if iterations are coming back unresolved.

**Tools needed:** Effectively all — `Read`, `Write`, `Edit`, `Bash`, `Grep`. The `Skill` tool is also required so the sub-agent can invoke `brainstorming` and `writing-plans` for `re-spec` / `re-plan` cascades. Note that the sub-agent does NOT spawn further sub-agents (no `Agent` tool needed) — Claude Code subagents cannot spawn further subagents, so any skill whose core behavior is sub-agent dispatch (e.g., `subagent-driven-development`) is **not** a valid fallback inside `review-iteration-runner`. `re-implement` execution stays inline in the sub-agent's own context (the smaller refactors that scope is sized for don't need a sub-agent to run); deeper execution help that genuinely requires sub-agent dispatch belongs at session level (main / overseer flow), not here.

**Why no `skills:` frontmatter declaration.** The `skills:` frontmatter would inject those skills' full content into the sub-agent's system prompt at startup AND would make the listed skill names a hard install-time dependency. Both are wrong here:

- `README.md` § "Requirements" says the Superpowers plugin is "**Deliberately NOT declared as a Claude Code plugin dependency**" because Claude Code's plugin-dependency field is a hard load-time gate; users can satisfy these skills via Superpowers OR via local `.claude/skills/<name>/SKILL.md` files. Pinning `brainstorming` / `writing-plans` in the agent frontmatter would re-introduce that hard gate and break the local-skill-equivalents path.
- Cascade scopes (`re-spec` / `re-plan`) fire in maybe 10–20% of iterations. Preloading those skills' full content into every iteration's system prompt — even the iterations that only need `fix` scope — is wasted tokens.

The sub-agent invokes the cascade skills on demand via the `Skill` tool. If a skill name is registered (under either Superpowers or a local `SKILL.md`), the Skill tool finds and invokes it. If neither path is available, the cascade-scoped IR is structurally **unresolvable in this iteration** — `re-implement` does not address the cause that motivated the `re-plan` / `re-spec` scope, so silently demoting it would mark a structurally open problem as fixed. Instead, the sub-agent must return `Result: blocked`, leave every cascade-scoped IR in its current open state (do NOT call `review.sh set-status … fixed`), and name the missing skill under `Findings / risks` so main can prompt the overseer to run `/mo-doctor` (or install Superpowers / a local equivalent) and re-trigger the iteration. `/mo-init` and `/mo-doctor` already detect missing Superpowers skills and prompt the install — that diagnostic flow is the right place for the dependency, not the agent frontmatter.

```yaml
---
name: review-iteration-runner
description: Per-iteration review-finding addressor for mo-review brainstorming mode. Reads open findings, picks scope tiers, applies fixes, invokes cascade Skills (brainstorming / writing-plans) on demand for re-spec / re-plan scopes. Used by mo-review Step 3a.2.4.
model: opus
effort: high
tools: [Read, Write, Edit, Bash, Grep, Skill]
---
```

**Body (system prompt).**

```markdown
You are a fresh sub-agent invoked from `mo-review` Step 3a per iteration of the brainstorming-mode review loop. Your task is to address every currently-open finding for the active feature in a single iteration: read the canonical context, pick the smallest scope tier that resolves each finding's root cause, apply the fix (with chained Skill invocations for cascade scopes), commit, and mark statuses via `review.sh set-status` — then return a structured summary so the main agent can present it to the overseer.

Behavioral defaults:
- Required first reads: `review-context.md` then `overseer-review.md`. Other canonical files (`requirements.md`, `config.md`, `primer.md`, `summary.md`) are on-demand fallbacks; read only when the snapshot leaves a gap on a specific topic.
- The `scope` field on each finding is a hint, not a directive. Scope tiers in increasing weight: `fix` → `re-implement` → `re-plan` → `re-spec`. Pick the smallest tier that genuinely addresses the root cause; do NOT default to `fix` when the cause is structural.
- For `re-plan` cascades, invoke the `writing-plans` Skill via the `Skill` tool carrying the delta primer from the spawn prompt verbatim. For `re-spec` cascades, invoke `brainstorming` carrying the delta primer. The primer asks the cascading Skill to preserve unchanged sections — pass it through unchanged. These skills are not preloaded into your system prompt (see profile description); the `Skill` tool resolves them at call time against whichever provider is registered (Superpowers plugin or local `.claude/skills/<name>/SKILL.md`). If the Skill tool reports the name is unknown, do NOT silently demote the IR's scope: `re-implement` does not address the structural cause that motivated `re-plan` / `re-spec`. Stop the iteration, return `Result: blocked`, leave every cascade-scoped IR in its current open state (do NOT call `review.sh set-status … fixed`), and surface the missing-skill name under `Findings / risks` so main can prompt the overseer to run `/mo-doctor` and re-trigger the iteration once the skill is available. Non-cascade IRs (`fix` / `re-implement`) you handled in this iteration before the cascade attempt MAY be committed and marked resolved.
- Process findings in descending impact order: `re-spec` → `re-plan` → `re-implement` → `fix`. A higher-tier action supersedes lower-tier findings in the same pass; mark superseded findings `fixed` with `fix-note: "superseded by re-spec at iteration N"` (or re-plan, etc.).
- One-iteration discipline: address ALL listed open findings before returning. Do not partially address and return. Main spawns a new fresh sub-agent for the next iteration if the overseer types `go again`.
- Commit per fix; call `review.sh set-status` (or `wontfix` if the finding turns out invalid or already addressed) for each finding addressed. Do NOT mutate `progress.md` — that is mo-workflow's job, triggered later by the overseer's `/mo-continue`.

Return shape: follow `docs/sub-agent-return-contract.md`. List resolved IR-IDs under `Commits` with their commit subjects, name affected paths under `Artifacts changed`, surface unresolved cascades or scope-escalation signals under `Findings / risks`. If the scope is too broad to summarize in 1k tokens, return `Result: partial` with explanation. Total return ≤ 1k tokens.
```

### 7. `dependency-mapper` — sonnet / medium

**Used by:** `commands/mo-continue.md:151-181` (Pre-flight Step 4c, stage 1.5).

**Workload.** Given a list of features in the queue, inspect the codebase to detect cross-feature dependencies (import chains, shared modules, schema dependencies, runtime coupling), and propose a queue order that respects them. Hard caps: ≤ 5 files per feature; skip generated/vendor/lock/build artefacts. Returns a 2–3 sentence summary plus the structured return shape.

**Why sonnet/medium.**
- Code structural understanding is required (which feature would touch which file, where imports cross feature boundaries) — beyond haiku.
- The scope is tightly bounded (5 files × N features) and the output is short (2–3 sentences). Opus + high would be wasted effort budget on a narrow task.
- Frequency: only fires when stage-1.5's heuristic flags ambiguity (multi-feature queues with cross-references). Many cycles never invoke it.
- Cached: if the heuristic re-runs in the same cycle, the prior `queue-rationale.md` is reused — so even when it fires, it fires once.

**Tools needed:** `Read`, `Bash`, `Grep`. (No writes — main agent writes `queue-rationale.md` from the sub-agent's return.)

```yaml
---
name: dependency-mapper
description: Cross-feature dependency analysis for queue ordering. Reads ≤5 files per feature, detects import/schema/runtime coupling, proposes ordered queue. Used by mo-continue Pre-flight Step 4c.
model: sonnet
effort: medium
tools: [Read, Bash, Grep]
---
```

**Body (system prompt).**

```markdown
You are a fresh sub-agent invoked from `mo-continue` Pre-flight Step 4c at stage 1.5. Your task is to inspect cross-feature codebase dependencies for the queue of features (provided in the spawn prompt) and propose an ordering that respects the dependencies — features that block others run first.

Behavioral defaults:
- Required first read: the cycle's `summary.md` `## Cross-cutting constraints` and per-feature `## Feature: <name>` sections.
- Bounding rules: ≤ 5 files inspected per feature; skip generated/vendor/lock/build artefacts. The point is a queue-ordering signal, not an exhaustive dependency map.
- Detect: import chains, shared modules, schema dependencies, runtime coupling between features.
- Output is a 2–3 sentence summary naming the proposed order and the strongest dependency signal you found. Example: "Order: audit-log → payments. The payments feature's planned `services/payments/PaymentService.ts` will read from `services/audit/AuditLog.append()` which audit-log introduces. No reverse dependency surfaced."
- Do not write files. Main composes `queue-rationale.md` from your return summary.

Return shape: follow `docs/sub-agent-return-contract.md`. The `Artifacts changed` and `Commits` lines will typically be empty for this task. Place the proposed order and dependency signal in the body of the return, before the contract block. Total return ≤ 1k tokens.
```

## Per-site mapping

| Spawn site | File:line | Profile | Model / Effort |
| --- | --- | --- | --- |
| Per-oversized-file journal digester | `commands/mo-run.md:264` | `journal-file-digester` | haiku / low |
| Per-folder journal digester | `commands/mo-run.md:286-289` | `journal-folder-digester` | haiku / medium |
| Stage-2 codebase grounding (Step A) | `commands/mo-apply-impact.md:9` (template at `docs/blueprint-regeneration.md:70-75`) | `codebase-grounder` | sonnet / high |
| Stage-2 blueprint diagram generation (Step C) | `commands/mo-apply-impact.md` Step C (runbook at `docs/blueprint-regeneration.md:209-260`) | `blueprint-diagrammer` | sonnet / high |
| Stage-4 change-summary + diagram framing | `commands/mo-generate-implementation-diagrams.md:9` | `implementation-analyst` | opus / high |
| Per-iteration review-finding addressor | `commands/mo-review.md:118, 192-199` | `review-iteration-runner` | opus / high |
| Stage-1.5 cross-feature dependency analysis | `commands/mo-continue.md:151-181` | `dependency-mapper` | sonnet / medium |
| Diagram-generation wrapper (manual) | `commands/mo-draw-diagrams.md:57, 75` | `implementation-analyst` (delegates to mo-generate-implementation-diagrams) | opus / high |

## Budget considerations

The two opus profiles dominate the workflow's per-cycle token spend. Rough back-of-envelope per feature:

- `implementation-analyst` — fires once per stage 4 (and again per `/mo-draw-diagrams` invocation). One opus pass for the whole change set.
- `review-iteration-runner` — fires once per review iteration. A typical cycle has 1–2 iterations; a long-tailed cycle can have 5+.

If a project's overseer review cycles are consistently short (most findings are `fix` scope, often resolved in one iteration), the `review-iteration-runner` could be downgraded to `sonnet / high` without dramatic loss. The opus default is conservative — opus' decision quality on scope-tier selection (`fix` vs `re-implement` vs `re-plan` vs `re-spec`) is what justifies the spend.

The two haiku profiles are effectively free at the rates these workflows fire, even on the largest journal intakes.

The three sonnet profiles (`codebase-grounder`, `blueprint-diagrammer`, `dependency-mapper`) sit in the middle. The first two fire back-to-back at stage 2 (codebase grounding then diagram framing); `dependency-mapper` only fires when the queue heuristic flags ambiguity. Sonnet at `high` / `high` / `medium` is the right tier — haiku would misclassify and miss diagram conditionals; opus would over-spend on inputs that are already structured by the time the agent receives them.

## Main session sizing — stage 3 effort suggestion

The seven sub-agent profiles cover every spawn site, but they don't address the model + effort the **main session** itself runs at. That matters because **stage 3 is the only stage where main does heavy reasoning work** — the brainstorming → writing-plans → executing-plans / subagent-driven-development chain runs in the main agent's context, not in a sub-agent (see `commands/mo-plan-implementation.md:237-258` for the Skill invocation that takes over main, and Step 4b for direct mode which also runs in main). Every other stage in the workflow is either light orchestration around sub-agent calls, bash glue, or waiting for the overseer.

### Why only stage 3 gets a suggestion

| Stage | Where heavy work runs | Need main-effort suggestion? |
| --- | --- | --- |
| 1 (`mo-run`) | Mostly main, but it's summarization — no architectural decisions | No |
| 1.5 (`mo-continue` queue) | Main, or delegates to `dependency-mapper` if ambiguous | No |
| 2 (`mo-apply-impact`) | Delegates to `codebase-grounder` (Step A) + `blueprint-diagrammer` (Step C); both sonnet/high | No |
| **3 (`mo-plan-implementation`)** | **Brainstorming chain (Skill in main) or direct mode — both heavy, both in main** | **Yes** |
| 4 (`mo-generate-implementation-diagrams`) | Delegates to `implementation-analyst` (opus/high) | No |
| 5 (overseer review) | Mostly main waits for human. **Exception:** `mo-manual-test-plan` Step 3 does codebase grep in main during plan generation. Workload is structured grounding (not design-heavy), so default effort is fine — flagged below as a future delegation candidate. | No |
| 6 (`mo-review`) | Delegates to `review-iteration-runner` (opus/high) per iteration | No |
| 7–8 (complete/archive) | Bash orchestration | No |

A second suggestion at any other stage would be noise — those stages don't benefit from a higher main-session effort because the heavy work isn't in main.

### Where the suggestion fires

**Wiring location:** `commands/mo-apply-impact.md` Step 3 hand-off message (line 112-114, the "Blueprints generated for `$active_feature` … type `/mo-continue`" prompt).

**Why this spot, not `/mo-continue`'s Approve Handler.** At the `mo-apply-impact` hand-off the overseer is being told to review the blueprint and then type `/mo-continue` — that's the pause point where they have time to read `requirements.md` and adjust effort before committing to the chain. By the time they've typed `/mo-continue` the Approve Handler in `commands/mo-continue.md` is about to auto-fire `/mo-plan-implementation`; suggesting effort there would force the overseer to interrupt, `/effort xhigh`, and re-`/mo-continue`. Worse UX for the same outcome.

The suggestion is **soft** — it does not block the hand-off message and does not require an answer. The overseer reads it alongside the existing review prompt.

### Signal heuristic

The millwright computes three signals from artifacts already on disk after stage 2 completes. **Source correction:** `config.md`'s auto-block contains only Skills/Rules/Load-on-demand summaries (per `templates/config.md.tmpl`); seam and cycle flavor live in `implementation/grounding-report.md`. Per `docs/workflow-spec.md:597`, cycle flavor is *deliberately* not persisted as a single overall classification — it's a per-item field in the grounding report's body.

1. **Any item is `cycle flavor: greenfield`** — grep `implementation/grounding-report.md` body for `- **Cycle flavor:** greenfield` lines. One greenfield item suffices: greenfield work means building from scratch, more design decisions, fewer existing patterns to follow. (Optional refinement for a future cycle: add a `cycle-flavor-summary` frontmatter field to `schemas/grounding-report.schema.yaml` + `templates/grounding-report.md.tmpl` if a single overall flavor is needed elsewhere; the heuristic can then `frontmatter.sh get` it instead of grepping the body.)
2. **`seam-classification = mixed`** — read from `implementation/grounding-report.md` frontmatter via `$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get <path> seam-classification`. Mixed = changes ripple across architecture layers (backend + frontend, or backend + infra), so design choices have wider blast radius.
3. **Design-heavy keywords in `requirements.md` `## Goals (this cycle)`** — case-insensitive grep on the Goals section bullets for any of: `refactor`, `redesign`, `architecture`, `migrate`, `introduce`, `decouple`, `abstraction`, `schema`, `restructure`, `rewrite`. One match suffices.

**Combination rule:** if **≥ 2 of 3 signals fire**, surface the suggestion. If 0–1 signals fire, stay silent — default `high` is fine and an extra prompt would be friction.

The signals are deliberately conservative. Most cycles won't trigger the suggestion (a typical bugfix or improvement cycle is bugfix/backend with no design-heavy keywords). The cycles that DO trigger it are the ones where xhigh's extra reasoning depth materially improves the spec the chain produces.

### Suggestion message template

When ≥ 2 signals fire, append the following block to the existing Step 3 hand-off message in `mo-apply-impact.md`. Substitute `<…>` placeholders with the actual signals that fired (e.g., `"any-item-greenfield + seam-classification=mixed + 'refactor' in Goals"`).

```
---
**Effort suggestion for stage 3.** This cycle has design-heavy signals: <…>. The brainstorming chain at stage 3 runs in this main session and makes design decisions the rest of the cycle depends on. Consider `/effort xhigh` before typing `/mo-continue` for this cycle. Drop back to `/effort high` after stage 3 — the lighter stages (4–8) don't benefit from xhigh.

This is a suggestion, not a gate. If you've read the blueprint and the design feels straightforward, `high` is fine and faster.
```

When 0–1 signals fire, the block is omitted entirely. The overseer sees only the standard hand-off message.

### Why this is fine to add despite the "no introspection" caveat

The millwright cannot read the current effort level (no tool exposes it), so the suggestion is one-way: it recommends bumping but cannot verify the overseer did it, and cannot detect if the overseer is already at `xhigh` or `max`. That's acceptable here because:

- **Idempotent.** Suggesting `xhigh` to an overseer who's already at `xhigh` or `max` is a small UX wart, not a correctness issue. They ignore it.
- **Non-blocking.** The suggestion appears alongside the existing review prompt; if it's irrelevant the overseer skips past it.
- **Self-limiting frequency.** It fires at most once per feature cycle, only at the stage 2 → 3 boundary, and only when the heuristic threshold is met.

### Explicit non-goals

- **No suggestion at any other stage.** Stages 1, 1.5, 2, 4, 5, 6, 7, 8 stay silent on effort. Adding suggestions at every stage was explicitly considered and rejected as friction with little marginal benefit.
- **No downgrade suggestion.** The plan does not propose suggesting `xhigh → high` after stage 3 ends. The overseer can manually drop back if they care; the savings on stages 4–8 are small (those stages are mostly orchestration around sub-agents that have their own effort settings) and the prompt would be noise.
- **No tracking of whether the suggestion was followed.** The mo-workflow does not persist a "did the overseer bump effort?" flag. Cycles run identically whether the overseer bumped or not.
- **No model suggestion.** The plan only suggests adjusting effort, not switching model class (`sonnet → opus`). Model choice is a session-launch decision; switching mid-session is heavier (cache implications, behavior shift) and isn't covered here.

## Migration strategy (out of scope for this plan, recorded for the implementation cycle)

When the agent files are added in a subsequent feature cycle, the migration is mechanical:

1. **Author each agent file** under `agents/<profile-name>.md` with the frontmatter and Markdown body specified in this plan. The Markdown body is the agent's system prompt at runtime — it is NOT optional. Body length should match the spec here (~12-25 lines per agent); avoid expanding into a long playbook since per-invocation specifics belong in the spawn-site prompt.
2. **Wire up each spawn site** per the two-category split in "## What an agent definition controls vs. what stays at the spawn site":
   - **5 existing `Agent` invocations to retarget** (one-line `subagent_type: general-purpose` → `subagent_type: millwright-overseer-development-machine:<profile-name>` change each):
     - `commands/mo-run.md:264` → `journal-file-digester`
     - `commands/mo-run.md:286-289` → `journal-folder-digester`
     - `docs/blueprint-regeneration.md:70` (Step A invoked from `mo-apply-impact`) → `codebase-grounder`
     - `commands/mo-continue.md:181` → `dependency-mapper`
     - `commands/mo-review.md:227` → `review-iteration-runner`
   - **2 prose-gate sites that need a concrete `Agent` invocation added** (the runbook today describes delegation in user-facing prompts but contains no actual call):
     - `commands/mo-apply-impact.md` Step C (runbook at `docs/blueprint-regeneration.md` Step C) → `blueprint-diagrammer`. Author a fresh prompt template (per-invocation specifics + return-contract block + role-introduction sentence), insert the `Agent` invocation at Step C.1 where main currently does the work, and drop the "delegated to a fresh sub-agent" prose from Step C.0's user prompt now that the delegation is real.
     - `commands/mo-generate-implementation-diagrams.md` Step 2a/2b → `implementation-analyst`. Same pattern: author the prompt template, insert the `Agent` invocation, and remove the "Delegation (optional)" caveat at line 218 — the dispatch is now mandatory.
   - **1 wrapper that inherits its spawn site for free**: `commands/mo-draw-diagrams.md` dispatches to `mo-generate-implementation-diagrams`; once the prose-gate above is concretized, the wrapper picks up `implementation-analyst` automatically. No separate edit needed.
3. **Leave the spawn-site prompts unchanged in the first migration pass.** The standardized return contract in `docs/sub-agent-return-contract.md` is still embedded at the call site, and the existing role-introduction sentences ("You are a fresh sub-agent invoked from `mo-run` Step 2.5 …") harmlessly reinforce the body's role definition. A later cleanup pass can trim spawn-site prompts to per-invocation specifics once the bodies have been validated.
4. **No state-machine changes.** The mo-workflow's progress-tracking, freshness gates, and cache keys are agnostic to which agent ran the work.
5. **Add the stage-3 effort suggestion logic** to `commands/mo-apply-impact.md` Step 3: compute the three signals (any-item-greenfield, `seam-classification=mixed`, design-heavy-keyword grep on Goals), and conditionally append the suggestion block to the hand-off message when ≥ 2 signals fire. Read `seam-classification` from `implementation/grounding-report.md` frontmatter via `frontmatter.sh get`; grep the same file's body for `- **Cycle flavor:** greenfield` lines; grep `blueprints/current/requirements.md` `## Goals (this cycle)` for the keyword list. (NOT `config.md` — its auto-block is Skills/Rules/Load-on-demand only; seam and cycle flavor live in the grounding report.)

## What this plan does NOT do

- **No agent files are written.** This document specifies the seven profiles, including each agent's frontmatter AND minimal body. Implementation (writing the seven `agents/*.md` files) is a separate cycle.
- **No spawn-site edits.** The 5 existing `Agent` invocations stay at `subagent_type: general-purpose` until the implementation cycle retargets them. The 2 prose-gate sites stay as prose ("delegated to a fresh sub-agent" in user-facing prompts and budget statements, with no actual `Agent` call) until the implementation cycle adds concrete invocations there. The `mo-draw-diagrams` wrapper is untouched in either pass — it inherits its dispatch from `mo-generate-implementation-diagrams`. The stage-3 effort suggestion is also unimplemented today — `mo-apply-impact.md` Step 3's hand-off message is unchanged until the implementation cycle.
- **No per-spawn effort overrides for sub-agents.** Each sub-agent's `model` + `effort` are fixed in its frontmatter. Per-spawn `model:` overrides at the call site are technically possible (the `Agent` tool accepts `model:` per invocation) but `effort:` is not per-spawn — we'd only add per-spawn `model:` if a specific call site needs to deviate from the profile default.
- **No main-session model switching.** The stage-3 suggestion only addresses *effort*, not model class. Switching `sonnet → opus` mid-session has different cost/cache implications and is left to the overseer's session-launch decision.
- **No agent profile for the manual-test-plan generator.** `commands/mo-manual-test-plan.md` Step 3 reads `requirements.md` + `config.md` + `change-summary.md` + `summary.md` and runs a codebase grep (env-var references, docker-compose service names, GraphQL/REST routes, error-code constants, UI route paths) in main, then renders `manual-test-plan.md`. The workload shape mirrors `codebase-grounder`: read codebase, classify against a fixed schema, write a structured document. A future cycle should consider promoting it to a spawn site with a dedicated `manual-test-planner` profile (likely `sonnet / high`, tools `[Read, Write, Edit, Bash, Grep]`). The companion `mo-manual-test-run` command is NOT a delegation candidate — it is an interactive per-scenario driver that prompts the overseer between every step. Both stay in main for now.

## References

- `docs/sub-agent-return-contract.md` — return-shape contract every spawn site embeds (unchanged by this plan)
- `docs/workflow-spec.md` § "Main-read budget gates by stage" — table of which stages delegate
- `docs/workflow-spec.md` § "Delegation guidance" — the doc's own guidance on tier selection
- `commands/mo-manual-test-plan.md` + `commands/mo-manual-test-run.md` — stage-5 manual-testing sub-flow, recorded under "What this plan does NOT do" as a future delegation candidate
- `docs/manual-testing/plan.md` — design rationale for the stage-5 sub-flow
- Claude Code subagent docs — https://code.claude.com/docs/en/sub-agents.md (frontmatter schema, plugin-namespaced names)
- Claude Code plugin docs — https://code.claude.com/docs/en/plugins.md (`agents/` directory layout, install behavior)
