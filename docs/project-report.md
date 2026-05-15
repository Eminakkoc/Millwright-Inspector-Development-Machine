# Millwright-Inspector Development Machine — Detailed Project Report



> **Purpose of this document.** A self-contained, in-depth briefing for AI agents (or new human collaborators) who need a complete mental model of this project without having to crawl the codebase. It explains the philosophy, the actors, the data flow, every command, every stage, and every supporting script. Optimized for context-pasting into another agent's working memory.



---



## 1. Introduction — The Philosophy



### 1.1 Why this project exists

  

Software development has historically revolved around a single primary artifact: **the codebase**. Everything else — requirement documents from project managers, ticket queues in JIRA / Linear, design hand-off in Figma, sprint planning, code-review comments — was *connective tissue* whose only job was to feed the human developer enough context to write code. The developer was the bottleneck and also the only authoritative author of the product.

  

The arrival of capable AI coding agents collapses that center of gravity. The agent can:

  

- read requirement documents and meeting transcripts directly,

- design APIs, draw diagrams, write specs,

- implement features end-to-end,

- and even self-review its own code.

  

This forces a question many developers find disorienting: **if the AI can do all of that, what is left for the developer to do?** The Millwright-Inspector plugin proposes a clean answer: the developer's role is renamed and reframed, not eliminated. Two new roles take the place of the legacy "developer + project manager + reviewer" stack:

  

1. **The Millwright** — an AI coding agent (Claude Code) that does the building. The name is borrowed from factory life: a millwright builds, maintains, and repairs the heavy machines that produce a factory's output. In software, the codebase is the factory and each module/feature is a machine. The AI agent is the modern millwright.

2. **The Inspector** — a human who supplies raw materials (specs, notes, transcripts), defines the work, and reviews every artifact the millwright produces at every stage. The inspector never writes production code; their authority is exercised through documents, prompts, and approvals.

  

The naming is intentional. "Developer" carried so much accumulated meaning (architect, coder, tester, debugger, reviewer) that calling the human a developer in this new world would be misleading. Calling the AI a "developer" would also feed the toxic narrative that "AI took the developer's job." Renaming both sides separates the activity from the historical identity.

  

### 1.2 The reform of tooling and artifacts

  

If the AI agent can read, design, and write directly from raw inputs, many tools that used to live around the codebase become unnecessary or transform:

  

- **Design hand-off tools** are replaced by direct MCP integrations or design-to-code generation (e.g., Figma MCP + plugin).

- **Requirement documents** no longer need a project manager / business analyst to mediate between customer and developer. Customer voice memos become prompts; meeting transcripts go straight into the journal; vibe-coded prototypes can themselves serve as inputs.

- **Task management tools** (JIRA, Linear) are no longer the single source of truth. Tasks live in the active cycle's `todo-list.md` next to the codebase, and every past cycle's `todo-list.md` is preserved permanently in its dated subfolder under `quest/` as a queryable archive. PMs query the artifacts via natural-language prompts to their own agents ("summarize what mobile shipped today", "is the loyalty feature done?", "how does it interact with auth?"). The *.md files alongside the code are the answer surface.

- **Pull-request review tools** are augmented by structured review files (`inspector-review.md`) that the millwright can re-read on every iteration.

  

The result: only **two** primary components matter — the **codebase** and the **millwright-inspector/** "control room" folder. Everything the workflow needs to remember is on disk in plain Markdown so it survives session breaks, model swaps, and even days-long pauses.

  

### 1.3 Core operating principles

  

Three rules are stamped into every command and stage:

  

1. **Inputs live in files, not in conversation context.** Context is ephemeral; sessions break and get compacted. Every inspector-supplied value (branch name, approval, finding) is captured to disk the moment it arrives. Each command's inputs list is a *file-path contract*, not a parameter list.

2. **Documents cross-link via UUIDs, paths are just navigation hints.** Every generated `.md` carries a UUID v4 in its frontmatter. Cross-references point at IDs, not paths, which gives grep-based discovery, rename-safety, and a clean audit trail when combined with `blueprints/history/`. UUIDs are minted by `scripts/uuid.sh` (never by the AI directly) to eliminate hallucinated IDs.

3. **Layered context loading.** Long-running stages (planning, review) are entered through a small *primer* file rather than by re-reading every canonical file. The chain reads the primer first and only escalates to the canonical files when a gap surfaces. This keeps token consumption bounded across multi-day workflows.

  

A fourth implicit rule: **every artifact is auditable**. Blueprints are rotated into `blueprints/history/v[N]/` on each refresh with a sibling `reason.md` explaining *why*; the live `implementation/` folder is archived alongside on stage-8 completion (as `history/v[N+1]/implementation/`), so every finding (including any deferred `status: open` ones), the review-context snapshot, the change-summary, and the implementation diagrams are preserved permanently — not deleted. Quest cycles live in dated `quest/<slug>/` subfolders that are likewise never overwritten and never deleted; the `quest/active.md` pointer simply moves to a new sibling on each `/mi-run`. Findings keep monotonically increasing IR-NNN ids that never reset. Quest cycles and feature cycles have crisp lifecycles with clearly defined entry / exit points. **Nothing is ever silently overwritten — every artifact is auditable**, and PMs can read the complete history of any past cycle from a single feature-version folder.

  

### 1.4 Alignment with the wider Software 3.0 / agentic-engineering view

  

The mi-workflow's design predates much of the current vocabulary around agentic AI engineering, but several recurring concepts in that discourse map directly onto its load-bearing decisions. The mapping below is descriptive, not prescriptive — the plugin works the same whether or not the operator buys into any particular framing — but it offers a useful lens for explaining *why* the choices were made.

  

- **Programming is prompting; the context window is the lever.** Rule 1 ("inputs live in files, not in conversation context") and Rule 3 ("layered context loading") operationalize the Software 3.0 view that prompts and curated context are the new programming surface. Every artifact under `workflow-stream/<feature>/` (`requirements.md`, `config.md`, `primer.md`, `review-context.md`, `change-summary.md`) is a deliberately-sized context window for a specific stage's LLM consumer. The `commands/mi-*.md` files are themselves prompts — text the agent reads and follows, not human tutorials.

  

- **Agent-native infrastructure.** Every runbook lives in `commands/*.md` so the agent reads it directly; every workflow `.md` carries YAML frontmatter validated by schema (`hooks/validate-on-write.sh`); the workflow's central state lives in a single LLM-legible `progress.md` rather than a database. An artifact only exists if it's parsable by whichever agent has to read it next — the validate-on-write hook closes that loop by failing the turn the moment an LLM writes invalid YAML.

  

- **Agentic engineering, not vibe coding — in both planning modes.** The mi-workflow lives entirely on the agentic-engineering side of the line. Every feature cycle goes through stage-2 spec review (`requirements.md`, `config.md`, `diagrams/`), stage-3 primer composition, stage-4 implementation diagrams, stage-5 structured findings (`inspector-review.md`), stage-6 review session when findings exist, and stage-8 blueprint rotation + `implementation/` archival. None of those gates is optional — they are the quality bar. The two planning modes differ only in *how the implementation work itself is run*: `planning-mode: brainstorming` invokes the brainstorming → writing-plans → executing-plans → finishing-a-development-branch chain in an isolated session with the chain's own spec/plan/execution approval gates, while `planning-mode: direct` keeps implementation in the main session with the millwright reading `primer.md` first. Direct mode trades the chain's internal ceremony for speed; it does **not** trade away the spec, the diagrams, the findings file, or the rotation history. Vibe coding — letting the agent land an implementation against an unwritten spec with no structured review — is explicitly not what this plugin does.

  

- **Verifiability as a design principle.** LLMs automate well in domains where output can be verified, so every feature cycle produces verifiable artifacts. `requirements.md`'s `commits:` field populated at stage 8 closes the loop between spec and diff; stage-2 blueprint diagrams and stage-4 implementation diagrams share the blue/green existing-vs-new convention so intent-vs-reality diffs are visual; `inspector-review.md` is structured by a finite scope-tier ladder (`fix | re-implement | re-plan | re-spec`) where each tier maps to a specific re-entry point in the chain; the commit range `base-commit..HEAD` is the single canonical implementation contract — the chain's spec/plan files are deliberately NOT tracked because they're internal chain state, not the verifiable surface.

  

- **Jaggedness as a safety design constraint.** Modern LLMs are jagged — peaking on tasks the labs trained for, breaking on edge cases that look superficially similar. Almost every recovery branch in the plugin exists because of this: the Resume Handler's drift-completion probe (Step 0), atomic `progress.sh advance-to` skip-transitions, resumable rotations (`.partial.tmp → .partial → vN`), `mi-complete-workflow`'s five-branch dispatch (0a / 0b / I / II / III), the worktree-fingerprint guard, the frontmatter-validation hook, and the mandatory inspector gates at stages 2, 5, and 6 are all designed around the assumption that the model can hand back broken or partial state at any point. The plugin never trusts a single transition.

  

- **Outsource thinking, not understanding.** The two-role split — inspector as design-and-direction authority, millwright as execution — operationalizes this exactly. The inspector reviews `requirements.md` (the spec) before any code is written, picks `planning-mode` and `review-mode`, reviews the implementation diagrams + diff before approval, writes findings, and ends every review session with an explicit `approve`. The plugin never lets the millwright self-approve; understanding stays with the human, and `direct` mode does not lower this bar — it just removes the brainstorming-chain ceremony, not the gates.

  

- **Layered, projected information as agent context.** The plugin's primer / review-context / change-summary / summary files are derived projections of canonical data, sized for a specific LLM consumer at a specific stage rather than dumped at full size. `summary.md` is feature-indexed so a stage reads only its active feature's section; `primer.md` is the stage-3 launch projection; `review-context.md` is the stage-6 review projection; `change-summary.md` is cache-keyed by `(base-commit, head)` so a projection only regenerates when its source actually changes. This is the same pattern that makes production-grade LLM knowledge-base / wiki systems token-efficient — derived projections of canonical data, not duplicated state.

  

---

  

## 2. The Two Roles

  

### 2.1 The Inspector (human)

  

- **Owns**: the journal content, the todo selection, the assignee tags, blueprint approvals, `## Inspector Additions` in `config.md`, the git branch, the findings file, every `/mi-continue` signal.

- **Never writes**: production code, generated specs, generated diagrams, generated requirements, generated quest files. (The inspector *may* hand-edit these in emergencies, but that's a recovery path, not the primary mode.)

- **Touchpoints per feature** (happy path, see §6 for details):

- `/mi-run <folder...>` once at the start of a quest cycle.

- `/mi-continue` ×2 at stage 1.5 (after marking, after queue order proposal).

- `/mi-continue` ×1 after blueprint review at stage 2.

- Picks `planning-mode` (`brainstorming` | `direct`) when prompted.

- `/mi-continue` ×1 after implementation returns; the Resume Handler performs the conceptual stage-4 work and atomically advances 3→5.

- Edits `inspector-review.md` if needed, then `/mi-continue` at stage 5.

- Picks `review-mode` if findings exist; types `approve` to end the review session.

- `/mi-continue` ×1 after the review session at stage 6 (only when there were findings).

- Diagram-refresh y/n (only when review-loop commits exist), blueprint-drift reason (inspector-supplied or `continue`).

  

### 2.2 The Millwright (AI agent — Claude Code)

  

- **Owns**: every generated artifact under `quest/<active-slug>/` (and the `quest/active.md` pointer), `workflow-stream/<feature>/blueprints/current/`, and `workflow-stream/<feature>/implementation/`. Owns dispatch — picks the right handler inside `/mi-continue`. Owns auto-fired commands (`mi-apply-impact`, `mi-plan-implementation`, `mi-review`, `mi-complete-workflow`, `mi-draw-diagrams`).

- **Never owns**: git operations beyond reads (no branch creation, no commits to main, no force-push), the `## Inspector Additions` block in `config.md`, the journal content, todo selection or assignee tags.

- **Delegates** (optional, see §3.2): may spawn sub-agents for bounded heavy lifting (per-file journal summarization, queue dependency analysis, change-summary writing, finding-cluster grouping). Sub-agents return ≤ 20-line routing slips; their detailed output goes into artifact files.

  

---

  

## 3. System Architecture

  

### 3.1 The two top-level components

  

1. **Codebase** — whatever the project is building. The mi-workflow does not enforce any particular language or framework on it.

2. **`millwright-inspector/` folder** ("the control room") — the workflow's data root. Path is configurable via `userConfig.data_root` in `plugin.json` (default: `millwright-inspector`; commonly set to `.millwright-inspector` for hidden mode). The plugin reads the runtime value from the `CLAUDE_PLUGIN_USER_CONFIG_data_root` environment variable that Claude Code injects from `userConfig`; the `MI_DATA_ROOT` env var is the explicit shell override for one-off runs. Every command resolves the data root via `scripts/data-root.sh` rather than hardcoding `millwright-inspector/...`, so the same scripts work in either mode without edits.

  

The control-room folder contains exactly three sub-folders:

  

```

millwright-inspector/

├── journal/ # raw inputs (inspector-authored)

├── quest/ # cycle-wide working state (millwright-generated; inspector marks selections)

└── workflow-stream/ # per-feature blueprints + implementation artifacts

```

  

### 3.2 The journal

  

The journal holds **raw resources**: meeting transcripts, notes, specs, design hand-offs, slack conversation exports — anything that defines or constrains the work. Sub-folders are topic groupings. The inspector drops files in; the workflow reads them.

  

Accepted formats:

- `.md` — must carry YAML frontmatter with `contributors:` and `date:` (YYYY-MM-DD). The inspector authors the frontmatter manually.

- `.txt` — no frontmatter required; read as plain content.

- `.pdf`, `.docx`, `.pptx`, `.xlsx`, `.html`, images (`.png`/`.jpg`/etc.) — supported via `/mi-ingest` (which uses **docling** for document conversion and a stub-md for images / short PDFs). `/mi-run` detects un-ingested files at stage 1 and asks the inspector per file which path to take. Originals stay in place for audit.

  

Example layout:

  

```

journal/

├── pricing-requirements-meeting/

│ ├── meeting-transcript.txt

│ ├── notes.md

│ └── devops-team-concerns.md

└── authentication-related-slack-conversation/

└── conversation.txt

```

  

### 3.3 The quest folder

  

Generated by `/mi-run` at the start of each cycle and **scoped per-cycle** so older cycles are preserved permanently as a task archive. Each `/mi-run` creates a per-cycle subfolder under `quest/` named after a date-prefixed slug — `YYYY-MM-DD-<journal-folder-slugs-joined-with-+>` plus an optional 3-character hex collision suffix when the same slug already exists for the day (e.g. `quest/2026-04-27-pricing-meeting+auth-rfc/`). The cycle's working files live inside that subfolder; the older subfolders are never overwritten. A top-level `quest/active.md` pointer file records which slug is currently active and is the single source of truth that scripts/commands read to resolve the active cycle's directory.

  

```

quest/

├── active.md                                # pointer file: which slug is current

├── 2026-04-27-auth-meeting/                 # an active cycle (or an older preserved one)

│   ├── todo-list.md

│   ├── summary.md

│   ├── progress.md

│   └── queue-rationale.md                   # written at stage 1.5, not stage 1

├── 2026-04-12-pricing-meeting+auth-rfc/     # a previous cycle, preserved permanently

│   └── ...

└── ...

```

  

Four files share the per-cycle lifecycle and live under `quest/<active-slug>/`:

  

| File | Role |

| ---- | ---- |

| `todo-list.md` | Per-feature checklist of TODO items with assignee tags. The inspector marks items with `[x]` to select for the cycle. |

| `summary.md` | Feature-indexed digest of journal content. `## Cross-cutting constraints`, `## Out-of-scope`, and one `## Feature: <name>` section per feature. Downstream stages read only the active feature's section. |

| `progress.md` | The central workflow state file. Holds the queue, completed list, and the active feature's runtime block. (See §3.5.) |

| `queue-rationale.md` | Audit of stage 1.5's dependency-ordering decision; survives session breaks so the analysis isn't re-derived on resume. **Multi-batch shape:** body uses `## Batch <N>` headings (level-2; `^## Batch (\d+)\b`); top-level frontmatter `status: draft \| confirmed`, `batch: integer ≥ 1`, and a cumulative `features:` list across all confirmed batches drive the dispatcher's draft-confirmation row, between-features Row A, and Pre-flight Step 2A's mid-cycle re-entry (which appends a `## Batch <N+1>` body and publishes top-level `batch=N+1`/`status=draft`/cumulative `features` in one write). Files without batch headings are treated as implicit Batch 1 for back-compat. |

  

Three of these (`todo-list.md`, `summary.md`, `progress.md`) are written at stage 1 by `/mi-run`. The fourth, `queue-rationale.md`, is deliberately deferred to stage 1.5 — it is written by `/mi-continue` after the dependency-order analysis runs. The dispatcher keys on its absence under `quest/<active-slug>/` to route to Pre-flight Step 2B.

  

Older cycle subfolders are never deleted, never moved, and never overwritten. PMs and recovery flows can grep across `quest/*/` for any past task, finding, or feature decision; the dated slug doubles as a chronological index.

  

#### Todo-item state machine

  

Items pass through five canonical states:

  

```

TODO → PENDING → IMPLEMENTING → IMPLEMENTED

↘ CANCELED (mid-cycle exit; preserved for audit)

```

  

Checkbox convention:

- `[ ]` = TODO only.

- `[x]` = any selected state (PENDING, IMPLEMENTING, IMPLEMENTED, CANCELED) — the **state word** is the canonical truth.

  

Assignee tag (the name in parentheses between the checkbox and the state word):

- *Optional* on `[ ] TODO` lines (inspector may pre-assign without selecting).

- **Mandatory** on every `[x]` line. `todo.sh pend-selected` rejects unassigned selections with a list of offending IDs so the inspector can fix and retry.

  

Example progression:

  

```

- [ ] TODO — PAY-001: capture webhook (default unselected, unassigned)

- [ ] (emin) TODO — PAY-001: capture webhook (pre-assigned, not selected)

- [x] (emin) PENDING — PAY-001: capture webhook (selected for this cycle)

- [x] (emin) IMPLEMENTING — PAY-001: capture webhook (in workflow)

- [x] (emin) IMPLEMENTED — PAY-001: capture webhook (done)

- [x] (emin) CANCELED — PAY-001: capture webhook (dropped mid-cycle, kept for audit)

```

  

**Refused manual writes.** The plugin refuses manual writes to `PENDING` and `IMPLEMENTED`:

- `PENDING` is only written by stage-1.5's `pend-selected` (it's an audit event tied to bulk selection).

- `IMPLEMENTED` is only written by stage-8's `mi-complete-workflow` (the commits-linkage invariant depends on atomic promotion).

  

### 3.4 The workflow stream

  

Per-feature folders that hold the actual design + implementation artifacts. One folder per feature in `workflow-stream/<feature>/`:

  

```

workflow-stream/<feature>/

├── decisions.md # feature-scoped append-only decision log (NOT rotated)

├── blueprints/

│ ├── current/

│ │ ├── requirements.md # Goals / Planned / Non-goals

│ │ ├── config.md # auto-summary of skills+rules; ## GIT BRANCH; ## Inspector Additions

│ │ ├── primer.md # compact stage-3 launch primer (layered-load entry point)

│ │ └── diagrams/

│ │ ├── use-case-<feature>.puml

│ │ ├── sequence-<flow>.puml

│ │ └── (optional, at most one) class-<domain>.puml OR component-<subject>.puml

│ └── history/

│ ├── v1/{requirements.md, config.md, primer.md, diagrams/, reason.md, implementation/}

│ ├── v2/...

│ └── ...

└── implementation/ # archived into history/v[N+1]/implementation/ at stage 8

├── inspector-review.md # findings file (IR-NNN blocks)

├── review-context.md # compact stage-6 review primer

├── change-summary.md # cached analysis of base-commit..HEAD (cache-keyed reuse)

├── grounding-report.md # stage-2 codebase-grounding snapshot (seam-classification etc.)

├── manual-test-plan.md # stage-5 manual-testing plan (optional sub-flow)

├── manual-test-results.md # stage-5 manual-testing run results (optional sub-flow)

├── manual-test-plan.history/ # rotated prior plans (--force / --discard-existing)

└── diagrams/ # render of the implementation, with shaded "existing system" framing

```

  

Two regions:

  

1. **`blueprints/`** — *permanent with history*. `current/` holds the live blueprint for the active feature. Every refresh rotates `current/*` into `history/v[N+1]/` with a `reason.md` recording why (`completion`, `manual`, `re-spec-cascade`, `re-plan-cascade`, `spec-update`). On `completion` rotations (stage 8), the entire live `implementation/` folder is also archived alongside as `history/v[N+1]/implementation/` so the rotated version contains: `requirements.md`, `config.md`, `diagrams/`, `primer.md`, `reason.md`, AND `implementation/` (`inspector-review.md`, `review-context.md`, `change-summary.md`, `diagrams/`).

2. **`implementation/`** — *temporary in `current/`, permanent in `history/`*. Holds findings and implementation-side artifacts during the cycle: `inspector-review.md`, `review-context.md`, `change-summary.md`, `grounding-report.md` (stage-2 codebase-grounding snapshot written by the `codebase-grounder` sub-agent), `diagrams/`, and — when the manual-testing sub-flow runs at stage 5 — `manual-test-plan.md`, `manual-test-results.md`, and `manual-test-plan.history/<timestamp>/` for rotated prior plans. At stage 8 the live folder is archived (moved) into `history/v[N+1]/implementation/`, not deleted — so every finding (including any deferred `status: open` ones), the review-context snapshot, the change-summary, the grounding-report, the manual-test artifacts, and the implementation diagrams survive as a permanent audit record. PMs querying past cycles can read the full audit trail from a single folder per feature-version. `mi-abort-workflow` still clears the live `implementation/` (an aborted cycle has no committed work to archive).

3. **`decisions.md`** at the **feature root** (not inside `blueprints/current/`) — *permanent across rotations*. A feature-scoped, append-only decision log written under stage-named H2s (`## Stage 2 — Blueprint approval`, `## Stage 5 — Findings canonicalization`, etc.). Excluded from blueprint history rotation by design: it persists across blueprint regenerations and across the feature's whole lifetime. Writers: `mi-continue` Approve Handler (stage-2→3 clear gate), Inspector Handler, and `mi-complete-workflow` housekeeping. Read-only consumers fold it into stage primers (`primer.md`, `review-context.md`) and into mid-cycle blueprint regen.

  

### 3.5 `progress.md` — the central state file

  

A single YAML-frontmatter Markdown file at `quest/<active-slug>/progress.md` (the active cycle's `progress.md`). Its frontmatter is the source of truth for "where are we right now":

  

```yaml

---

id: <uuid>

todo-list-id: <uuid of the related todo-list.md>

queue: [notifications, audit-log] # features still to run, in priority order

completed: [onboarding] # features finalized via mi-complete-workflow

active: # null between workflows; populated while a feature is running

feature: payments

branch: feat/payments/webhook # null until stage 3

current-stage: 5 # 2..8; stage 4 is conceptual and never persisted (3→5 atomic via advance-to)

sub-flow: none # none | chain-in-progress | resuming | reviewing | manual-testing

base-commit: a1b2c3d # null until stage 3

execution-mode: subagent-driven

planning-mode: brainstorming # brainstorming | direct | none

review-mode: none # brainstorming | direct | none

implementation-completed: true

inspector-review-completed: false

drift-check-completed: true # optional — true once stage-4 drift prompt has been answered (probe + drift-gate split markers)

history-baseline-version: 0 # optional — highest finalized blueprints/history/v[N] index for active.feature at stage-3 entry; null/missing means "unknown" (probe disables itself for that invocation)

manual-test-state: none # none | running | complete | skipped — stage-5 manual-testing sub-flow

manual-test-failure-policy: none # none | auto-seed | manual — how /mi-manual-test-run handles a failed scenario

clear-recommendations: [] # array of clear-point identifiers already crossed (e.g. stage-2-to-3, stage-5-to-6) so gates don't re-prompt

worktree-path: /Users/me/repo # immutable after activate; state-mutating subcommands refuse on mismatch

git-common-dir: /Users/me/repo/.git # shared across worktrees of one repository

git-worktree-dir: /Users/me/repo/.git # per-worktree; equals common-dir for the main worktree

---

```

  

Two-step activation lifecycle:

  

| Trigger | Effect on `active` |

| --- | --- |

| `/mi-run` (stage 1) | `active = null`; queue populated. |

| `/mi-apply-impact` → `progress.sh activate` (stage 2) | Pops `queue[0]` into a fresh `active` block (current-stage=2). Fails fast if `active` is already non-null. |

| Stages 2–8 | Mutates `active.*` fields in place via `progress.sh set` and `progress.sh advance`. |

| `mi-complete-workflow` → `progress.sh finish` (stage 8) | Appends `active.feature` to `completed`; sets `active = null`. |

  

On resume, the millwright reads `active`:

- `active` null + non-empty queue → "next feature is waiting; activate it."

- `active` populated → "feature X at stage N with sub-flow Y."

- `active` null + empty queue → "cycle complete (or todo list still has unmarked items — start stage 1.5 again)."

  

---

  

## 4. Roles × Plugin Interaction Table

  

This table summarizes who interacts with which plugin surface, for which purpose, at which stage. It is the single most useful map for understanding the workflow's blast radius.

  

| Actor | Interacts with | Action / Touchpoint | Stage | Notes |

| --- | --- | --- | --- | --- |

| **Inspector** | `journal/<topic>/*.md` `.txt` (and ingested non-text) | Authors raw inputs, frontmatter (`contributors`, `date`), groups them by topic. | 0 | Manual; inspector is the only writer. |

| Inspector | `/mi-init` | First-run wizard; one-prompt dependency install + folder scaffold. | once | Idempotent. |

| Inspector | `/mi-doctor` | Detailed dependency check; per-dep prompts; sudo handling. | recovery / setup | Auto-invoked by `/mi-run`'s preflight. |

| Inspector | `/mi-ingest <folder>` / `--file <path>` / `--stub <path>` | Convert PDF/DOCX/PPTX/XLSX/HTML/images to sibling `.md` (docling or stub). | optional 0.5 | Required for non-text journal files Claude can't `Read` natively. |

| Inspector | `/mi-run <folder1> [<folder2> ...]` | Generate quest files from selected journal sub-folders. | 1 | Pure journal → quest. No branch arg. |

| Inspector | `quest/<active-slug>/todo-list.md` | Marks items `[x]` and adds `(assignee)` tag. | 1.5 | Item selection. |

| Inspector | `/mi-continue` (1st in stage 1.5) | Triggers Pre-flight Step 2A: promote `[x] TODO` → `[x] PENDING`, propose queue order. | 1.5 | `pend-selected` rejects unassigned `[x]`. |

| Inspector | `/mi-continue` (2nd in stage 1.5) | Triggers Pre-flight Step 2B: write `queue-rationale.md`, reorder queue, auto-fire `/mi-apply-impact`. | 1.5 → 2 | Inspector may paste a custom order before this. |

| **Millwright (auto)** | `/mi-apply-impact` | Calls `progress.sh activate`; generates `requirements.md`, `config.md`, `diagrams/`, pre-fills `## GIT BRANCH`. | 2 | Quest-driven blueprint via `docs/blueprint-regeneration.md`. |

| Inspector | `blueprints/current/config.md` `## GIT BRANCH` | Edits / confirms feature branch. Refused: `main`, `master`. | 2 | Pre-filled from HEAD if non-trunk; otherwise blank. |

| Inspector | `blueprints/current/` (review) | Visually reviews requirements / config / diagrams. May hand-edit `## Inspector Additions`. | 2 | Pre-implementation gate. |

| Inspector | `/mi-continue` (after blueprint review) | Approve Handler validates blueprint files and auto-fires `/mi-plan-implementation`. | 2 → 3 | One per feature. |

| Millwright (auto) | `/mi-plan-implementation` | Pure launcher: PENDING→IMPLEMENTING, captures base-commit, sets sub-flow, writes `primer.md`, asks for `planning-mode`. | 3 | Hands off to brainstorming chain or direct mode. |

| Inspector | Chat reply (`brainstorming` / `direct`) | Picks `planning-mode`; persisted to `progress.md`. | 3 | `brainstorming` → isolated chain session. `direct` → main-session implementation. |

| Inspector | brainstorming chain (when in `brainstorming` mode) | Drives the brainstorming → writing-plans → executing-plans / subagent-driven-development → finishing-a-development-branch chain. | 3 | Isolated from mi-workflow; inspector interacts as in any normal Claude Code session. |

| Millwright (direct mode) | Codebase, `primer.md` | Implements directly, committing on the active branch. | 3 | Layered-load: primer first, escalate as needed. |

| Inspector | `/mi-continue` (post-implementation) | Resume Handler: drift-completion probe; verifies commits (zero-commit branch offers `retry-launch` / `direct-empty` / `abort`); idempotent flag writes; optional `/mi-update-blueprint --reason-kind=spec-update` drift fire; auto-fires `/mi-draw-diagrams`; creates `inspector-review.md` skeleton; finalizes with atomic `advance-to 3 5`. | 3 → 5 (atomic; stage 4 never persists) | Single resumption signal. |

| Millwright (auto) | `/mi-draw-diagrams` (= `mi-generate-implementation-diagrams`) | Renders use-case + sequence + (optional) one structural diagram of `base-commit..HEAD` with the blue/green existing-vs-new framing. | (Resume Handler) | Auto-fired here; manually invokable. |

| Inspector | `implementation/inspector-review.md` | Authors findings as plain sentences or `### IR-NNN` blocks. Empty file = approval. | 5 | Skeleton already created. |

| Inspector | `/mi-continue` (after review) | Inspector Handler: canonicalizes free-form findings (`review.sh canonicalize` + millwright classifies + `review.sh add` + `strip-freeform`); if no open findings, auto-finalize via `mi-complete-workflow`; else auto-fire `/mi-review`. | 5 → (7 \| 6) | Auto-finalizes only when truly empty. |

| Millwright (auto) | `/mi-review` | Pure launcher: writes `review-context.md`, asks for `review-mode`, dispatches to brainstorming review session or direct review loop. | 6 | Sets sub-flow=reviewing, advances 5→6. |

| Inspector | Chat reply (`brainstorming` / `direct`) | Picks `review-mode`. | 6 | Persisted to `progress.md`. |

| Inspector | brainstorming review session OR direct review loop | Addresses findings; chain or millwright marks each `fixed`. Inspector types `approve` to end. | 6 | No iteration cap. |

| Inspector | `/mi-continue` (after review session) | Review-Resume Handler: check/defer open findings, offer a diagram refresh when review-loop commits exist, then atomically advance 6→7 and auto-fire `/mi-complete-workflow`. | 6 → 7 → 8 | Only when there were findings. |

| Millwright (auto) | `/mi-complete-workflow` | Updates IMPLEMENTING → IMPLEMENTED, populates `commits:` in `requirements.md`, rotates `blueprints/current/` into `history/v[N+1]/`, archives the live `implementation/` into `history/v[N+1]/implementation/` (not deleted — preserves findings, review-context, change-summary, and diagrams as a permanent audit record), calls `progress.sh finish`. Auto-invokes next feature's `/mi-apply-impact` if queue non-empty; else asks for more TODO marks or recommends `/mi-run`. | 8 | Atomic close-out. |

| Inspector | `/mi-abort-workflow [--drop-feature=requeue]` | Safe cancel: IMPLEMENTING → PENDING revert (scoped to the active feature), clear `implementation/`, reset `active` block, preserve `blueprints/current/`. Never touches git. (`--drop-feature=completed` was removed because it bypassed canonical stage-8; use `/mi-complete-workflow` instead.) | recovery | Optional `--drop-feature=requeue`. |

| Inspector | `/mi-resume-workflow` | Diagnostic dispatcher: reads state, prints recommended next command. No mutations. | recovery | Auto-suggestion target for unknown states inside `/mi-continue`. |

| Inspector | `/mi-update-blueprint [--reason-kind <manual\|spec-update>] [--force-regen] <reason>` | Manual or stage-4 spec-update implementation-driven blueprint refresh: rotate, regenerate from `change-summary.md` + diff hunks + previous history, preserve `## GIT BRANCH` and `## Inspector Additions`, sync `requirements-id` refs. | mid-cycle (3+) | Stage-4 drift check auto-invokes this with `--reason-kind=spec-update` if inspector supplies a reason. |

| Inspector | `/mi-update-todo-list <subcmd> <args>` | Manual todo edits — `add` (TODO/IMPLEMENTING/CANCELED only), `cancel`, `set-state`. Refuses PENDING / IMPLEMENTED writes. | any | Reminds inspector to follow up with `/mi-update-blueprint` if scope shifts. |

| Inspector | `/mi-manual-test-plan` | Generates `test/manual-test-plan.md` (manual-testing sub-flow at stage 5). Auto-fired by Resume Step 7 when inspector answers `y`; manually invokable while `current-stage=5`. | 5 | Refuses outside stage 5. Rotates an existing plan into `test/manual-test-plan.history/<timestamp>/` on `--force`/`--discard-existing`. Auto-rotates prior-activation results into `test/manual-test-results.history/<timestamp>/` (cross-activation guard, see `docs/manual-testing-folder/plan.md` § 4.1). |

| Inspector | `/mi-manual-test-run` | Walks the plan, captures pass/fail per scenario into `manual-test-results.md`, and (on failure-policy=`auto-seed`) seeds `### IR-NNN` findings into `inspector-review.md` via `review.sh upsert-manual-test-failure` with deterministic `seed-id: manual-test:<seed-family-id>:<scenario-id>`. | 5 | Single owner of manual-test → review-file mutations. `--seed-only` is the recovery shape used by the Manual-Test-Resume Handler when results exist but seeding never completed. |

| Inspector | `/mi-export-bundle` | Extracts a single self-contained markdown bundle of the active feature's current state (requirements, scope, decisions, codebase-context audit, implementation summary, changed-files, manual-test results, open findings) into `tmp/bundles/<feature>-stage<N>-<timestamp>.md`. Refuses if no active cycle / no active feature / worktree fingerprint mismatch. | any active | For pasting into a fresh agent that lacks plugin/data access. Excludes diagrams, diffs, prose synthesis. `tmp/bundles/.gitignore` is auto-written. |

| Inspector | `/mi-init-status-bar [--user|--project-shared] [--plugin-root <abs>]` | One-shot wiring: writes `.claude/mi-stage-info-bar.sh` (a generated wrapper with the plugin's absolute path baked in, because Claude Code does NOT expand `$CLAUDE_PLUGIN_ROOT` inside `statusLine.command`) and a `statusLine.command` block in settings.json (default: project-local). | once | The renderer (`scripts/info-bar.sh`) is **pull-only** — not a hook; not a writer. Reads stdin JSON, parses `quest/active.md` + `progress.md` once, prints one line, exits 0. |

| **PostToolUse hook** | `hooks/validate-on-write.sh` | Auto-validates YAML frontmatter against schemas on every Write/Edit to a workflow `.md` file. Blocks the turn on failure. | always | No-op outside the data root. |

| **MCP server** | `plantuml-mcp-server` | Renders `.puml` sources to images for use-case / sequence / class diagrams. | 2, Resume Handler | Configured automatically via `plugin.json`. |

| Optional companion | `rtk` | Pre-tool-use hook that filters verbose shell output (git diffs, test runs, logs) before Claude sees them. | always (when installed) | Detected by `/mi-doctor`; never required. |

| Optional companion | `docling` | Document → markdown converter. Powers `/mi-ingest`. | optional (stage 0.5) | Only needed for DOCX/PPTX/XLSX/HTML or PDFs >20 pages. |

  

---

  

## 5. The Stages (canonical 0 → 8)

  

Each stage has a precise entry condition, work list, and exit condition. `progress.md`'s `active.current-stage` is advanced at the *end* of each stage by `progress.sh advance`.

  

| Stage | Name | Driver | Entry | Exit |

| ---: | --- | --- | --- | --- |

| 0 | Journal populated | Inspector | `journal/` empty or stale. | Inspector signals intake done by typing `/mi-run`. |

| 1 | Quest generated | Millwright via `/mi-run` | Inspector ran `/mi-run <folder...>`. | New per-cycle subfolder created under `quest/`; `quest/active.md` updated to point at it; `quest/<active-slug>/{todo-list.md, summary.md, progress.md}` exist (`queue-rationale.md` is deferred to stage 1.5). |

| 1.5 | Selection + ordering | Inspector + Millwright via `/mi-continue` Pre-flight Handler | Inspector marks `[x]` in the active cycle's `todo-list.md`. | `quest/<active-slug>/queue-rationale.md` written; queue reordered; `/mi-apply-impact` auto-fires. |

| 2 | Blueprints generated | Millwright via `/mi-apply-impact` | Pre-flight handler auto-fired. | `blueprints/current/requirements.md`, `config.md`, `diagrams/` exist. |

| 3 | Implementation launched | Millwright via `/mi-plan-implementation` (auto) → chain or direct | Inspector typed `/mi-continue` (Approve Handler). | `base-commit` recorded, `planning-mode` set, sub-flow set; chain or direct implementation runs. |

| 4 | Implementation resumed (conceptual; **never persisted**) | Millwright via `/mi-continue` Resume Handler | Inspector typed `/mi-continue` after chain/direct returned. | `implementation-completed=true`, drift probe + (optional) drift fire complete, diagrams rendered, `inspector-review.md` skeleton created. The handler's final write is an atomic `advance-to 3 5` — `current-stage` skips 4 entirely. |

| 5 | Presented for inspector evaluation (optional manual test, then findings) | Inspector | Stage-4 handoff message printed. Resume Step 7 asks `y/n` to launch the manual-testing sub-flow; on `y`, auto-fires `/mi-manual-test-plan` then `/mi-manual-test-run` under `sub-flow=manual-testing`. | Inspector types `/mi-continue`; `inspector-review.md` exists (empty or populated). Failed manual-test scenarios may have already seeded findings via `auto-seed` policy. |

| 6 | Inspector review session | Inspector + chain/millwright via `/mi-review` | Stage-5 `/mi-continue` found open findings. | Review session exits (inspector types `approve`); inspector types `/mi-continue` again. |

| 7 | Review completed (transitional) | Millwright | Either no-findings path (5 → 7 directly) or with-findings path (6 → 7). | With-findings path offers a diagram refresh when review-loop commits exist; no-findings path skips straight to `mi-complete-workflow`. |

| 8 | Completion | Millwright via `/mi-complete-workflow` | Stage 7 reached. | Blueprint rotated, live `implementation/` archived into `history/v[N+1]/implementation/`, IMPLEMENTING → IMPLEMENTED, `progress.sh finish` called. Loop back to next queue feature or wait for more TODO marks. |

  

### 5.1 Detailed flow per stage

  

**Stage 0 — Journal populated.**

The inspector drops `.md` / `.txt` (and optionally non-text via `/mi-ingest`) into topic sub-folders under `journal/`. Frontmatter for `.md` files: `contributors:` + `date:`. No frontmatter for `.txt`. No automation here — pure intake.

  

**Stage 1 — `/mi-run`.**

The millwright computes the new cycle's slug — `YYYY-MM-DD-<journal-folder-slugs-joined-with-+>` plus an optional 3-character hex collision suffix when the same slug already exists for the day — creates `quest/<slug>/`, and updates `quest/active.md` to point at it via `quest.sh start`. It then reads the named sub-folders, summarizes their content into the active cycle's `summary.md` (feature-indexed), generates the active cycle's `todo-list.md` (kebab-case feature headings + per-item IDs and assignee placeholders), and scaffolds the active cycle's `progress.md` with the queue populated and `active: null`. Only THREE files are produced at stage 1: `todo-list.md`, `summary.md`, `progress.md`. The fourth quest file (`queue-rationale.md`) is intentionally deferred to stage 1.5 — its absence under `quest/<active-slug>/` is what the dispatcher keys on to route the second `/mi-continue` to Pre-flight Step 2B. Per-file ingest decisions are made interactively for any non-text file detected. Sub-agent delegation is allowed for per-file summarization when files exceed thresholds. Older quest subfolders are left alone — they are the permanent task archive.

  

`/mi-run` also accepts `--archive-active`, which tells the inspector's currently in-flight cycle to be retired without finishing it. The current `quest/<active-slug>/` is preserved as-is (frozen, audit-readable), `quest/active.md` is cleared via `quest.sh end`, and a fresh cycle subfolder is created on top. Use this when the cycle has gone in a wrong direction and you want a clean restart without losing the audit trail.

  

**Stage 1.5 — Selection + Ordering (Pre-flight Handler in `/mi-continue`).**

- Sub-state A (`[x] TODO` lines exist in the active cycle's `todo-list.md`): runs `todo.sh pend-selected`, groups PENDING items by feature, runs `progress.sh enqueue` if mid-cycle, analyzes cross-feature dependencies for ≥ 2 features, proposes a prioritized order in chat.

- Sub-state B (promotion done, `quest/<active-slug>/queue-rationale.md` missing): writes `quest/<active-slug>/queue-rationale.md`, runs `progress.sh reorder`, auto-fires `/mi-apply-impact`. The dispatcher specifically keys on the absence of `queue-rationale.md` under the active cycle's subfolder to route here.

  

**Stage 2 — Blueprint generation (`mi-apply-impact`).**

Calls `progress.sh activate` (pops `queue[0]` into `active`). Then follows `docs/blueprint-regeneration.md` (the *quest-driven runbook*):

- Step A: read `quest/<active-slug>/summary.md` (active feature section + cross-cutting + out-of-scope), then run a **bounded codebase-grounding pass** (≤ 5 files per todo item, scoped to the active feature) to identify (a) the existing seam each PENDING item lands on, (b) the seam classification (`backend | frontend | mixed | infra`), and (c) the **cycle flavor** per item (`greenfield | bugfix | improvement` — detected from todo keywords + whether the seam already contains the targeted functionality; not persisted). Write `requirements.md` with `## Goals (this cycle)`, `## Planned (future cycles)`, `## Non-goals (out of scope)`. Goals items name the seam and sketch a high-level solution shape, with phrasing that follows the cycle flavor (greenfield: "add …"; bugfix: "change X from doing A to doing B"; improvement: "extend X to also …") — not code-level details (function signatures, payload schemas belong to the brainstorming spec at stage 3). Distinction matters: Planned items WILL ship later — current implementation must leave architectural seams. Non-goals are truly out of scope and can be assumed away.

- Step B: scan `.claude/skills/` and `.claude/rules/`, write `config.md`'s auto-block (≤ 10 entries / ≤ 2 lines each, three sections: `## Skills`, `## Rules`, `## Load on demand`), pre-fill `## GIT BRANCH` from HEAD if non-trunk, preserve `## Inspector Additions` verbatim.

- Step C: render diagrams via PlantUML MCP — mandatory `use-case-<feature>.puml`, 2–3 `sequence-<flow>.puml`, and at most one optional structural diagram (`class-<domain>.puml` OR `component-<subject>.puml`, never both — fires only on `backend`/`mixed` seams when 3+ items with non-trivial relationships/dependencies are present; linear chains and pure UI/infra seams skip the slot). Apply the **existing-vs-new framing convention** (shared with stage-4 implementation diagrams): stage-2 baseline is current HEAD as `existing` and the seams sketched by Goals as `new`. Plus `diagrams/README.md` with `requirements-id` back-reference.

  

**Stage 3 — Implementation launch (`mi-plan-implementation`).**

Pure launcher with no driver logic:

1. `todo.sh bulk-transition PENDING IMPLEMENTING --feature <active>` (selected items → IMPLEMENTING).

2. `git rev-parse HEAD` → `progress.md.active.base-commit`.

3. Validate `## GIT BRANCH` from `config.md` (refuse main/master, refuse multi-line, refuse mismatch with HEAD).

4. Compose `primer.md` (compact stage-3 launch primer: active scope, goals excerpt, journal context, likely-relevant skills/rules). Layered-load entry point.

5. Ask inspector for `planning-mode` (`brainstorming` | `direct`).

6. **Brainstorming mode**: invoke the `brainstorming` skill with `primer.md` as the required first read; canonical files (`requirements.md`, `config.md`, `summary.md` active section, `todo-list.md`) are fallbacks. The skill chains brainstorming → writing-plans → executing-plans / subagent-driven-development → finishing-a-development-branch in an isolated session. Mi-workflow does NOT interfere.

**Direct mode**: millwright reads `primer.md` itself, escalates to canonicals on demand, implements in the main session, commits as it goes.

  

**Stage 4 — Implementation resumed (Resume Handler in `/mi-continue`).**

Stage 4 is conceptual — the Resume Handler runs the work attributed to it but **never persists `current-stage=4`**. The drift marker is persisted earlier as a split marker write, and the handler ends with an atomic `progress.sh advance-to 3 5 --set sub-flow=none`, so the file's `current-stage` jumps from 3 to 5 in one write. Eliminating stage 4 as a persisted state closes a class of "session break re-fires the drift prompt" failures (F1 in the v11 progress-gap plan).

0. **Drift-completion probe.** Skipped when `active.drift-check-completed=true`. Otherwise, walks `blueprints/history/v[K] > active.history-baseline-version` looking for a finalized version with `reason.kind == "spec-update"`. If found AND `blueprints.sh check-current --require-primer` returns 0 (complete), the prior `/mi-update-blueprint --reason-kind=spec-update` rotated + regenerated successfully but the marker write was lost — persist `drift-check-completed=true` and skip Step 3. If no baseline is recorded (older in-flight cycle, or stage-3 was partial), the probe captures a fresh baseline and disables itself for this invocation. The probe's `recovered-kind` switch GUARDs to `{manual, spec-update}`; `completion` routes to `/mi-complete-workflow`'s Branch 0a, and `re-spec-cascade`/`re-plan-cascade` route back to `/mi-review`.

1. **Verify commits in `base-commit..HEAD`.** If `commit_count > 0`, proceed. If `commit_count == 0`, prompt the inspector with three options: `retry-launch` (re-launch `/mi-plan-implementation`), `direct-empty` (confirm no code changes were needed — writes a tagged HTML comment into `inspector-review.md` documenting why, pre-sets `drift-check-completed=true`, and atomically advances 3→5), or `abort` (run `/mi-abort-workflow`).

2. **Idempotent flag writes.** Set `sub-flow=resuming`, `implementation-completed=true`. Idempotent so a session-break re-entry doesn't trip a "field already set" guard.

2.5. **Abandoned-chain check.** Locates plan files added/modified in `base-commit..HEAD` under `docs/superpowers/plans/` plus any uncommitted plans newer than `base-commit`. Counts `- [x]` / `- [ ]` checkboxes; if a candidate has open items, prompts the inspector with `completed | abandoned <N>` choices. On `abandoned`, re-invokes the `brainstorming` Skill with a resume primer pointing at the existing plan + spec + commit log (read-only access to `docs/superpowers/` is the single exception to the "mi-workflow does not read chain artefacts" rule).

3. **Drift prompt — skipped when Step 0 set the marker.** Otherwise prompts the inspector for a blueprint-drift reason. Three valid replies: a `<short reason>` (invokes `/mi-update-blueprint --reason-kind=spec-update "<reason>"`); `auto` (millwright analyzes `requirements.md` against `git diff base-commit..HEAD` and current code — if meaningful divergence is found, derives an `$auto_reason` and invokes `/mi-update-blueprint --reason-kind=spec-update "$auto_reason"`; if no divergence, skips rotation and only writes the `drift-check-completed=true` marker — cosmetic-only deltas don't trigger rotation because `/mi-update-blueprint` already re-derives Goals); or `continue` (proceed without updating; drift surfaces as findings later).

4. **Drift side effect.** Persists `drift-check-completed=true` (split marker write so the probe can detect a successful rotation even if the drift gate's own marker write is the one lost to a session break).

5. **Auto-fire `/mi-draw-diagrams`** (= `mi-generate-implementation-diagrams`). Renders use-case + sequence + (optional) one structural diagram of `base-commit..HEAD` with the blue/green existing-vs-new convention: blue `#D6EAF8` boxes + `#3498DB` arrows for pre-existing, green `#D4EDDA` boxes + `#27AE60` arrows for new, plus a `legend right` block whose wording reflects the cycle flavor.

6. **Initialize `inspector-review.md`** skeleton via `review.sh init` (idempotent).

7. **Atomic finalize.** `progress.sh advance-to 3 5 --set sub-flow=none`. The drift marker was already persisted by Step 0 or Step 4; this final write only collapses stage 3 directly to stage 5. Print stage-5 handoff message.

  

**Stage 5 — Presented for inspector evaluation (Inspector Handler in `/mi-continue`).**

Stage 5's role widens from "findings only" to "optional manual test, then findings." The Resume Handler offers a manual-testing sub-flow via Step 7 before stage 5 ever takes its inspector-typed `/mi-continue`:

- **Resume Step 7 (manual-testing offer).** Asks `y/n`. On `y`, auto-fires `/mi-manual-test-plan --from-resume`, then `/mi-manual-test-run`, all under `sub-flow=manual-testing`. New active-block fields `manual-test-state ∈ {none, running, complete, skipped}` and `manual-test-failure-policy ∈ {none, auto-seed, manual}` carry the run state. Failed scenarios under `auto-seed` policy are converted into `### IR-NNN` findings via `review.sh upsert-manual-test-failure` (deterministic `seed-id: manual-test:<seed-family-id>:<scenario-id>`).

- **Manual-Test-Resume Handler** (`current-stage=5, sub-flow=manual-testing`). Routed inside `/mi-continue` ABOVE the catch-all `5 | (any)` row. Dispatches on (plan exists, results exists, results state) and re-fires `/mi-manual-test-run` (Branch A) or `--seed-only` (Branch B) for crash recovery; refuses with diagnostic on genuinely-inconsistent shapes.

The plain Inspector Handler runs after the manual-testing sub-flow exits (or if the inspector skipped the offer):

0. **Manual-test summary line** (read-only). Prints a one-line summary if `manual-test-state ∈ {complete, skipped}`.

1. Verify `inspector-review.md` exists (offer to recreate if missing).

2. **Canonicalize free-form findings**: `review.sh canonicalize` returns TSV rows `<line-start>\t<line-end>\t<text>`. For each row, the millwright classifies severity (blocker/major/minor) and scope (fix/re-implement/re-plan/re-spec) heuristically based on the wording, calls `review.sh add` with the original text as `details:`, and then `review.sh strip-freeform` in reverse line order. Without this step a free-form finding would slip past `list-open` and the workflow would silently auto-finalize.

3. `review.sh list-open <feature>`:

- If empty: prompt the inspector with a y/n confirmation (`inspector-review.md has no open findings. Confirming will complete the inspector-review stage and auto-fire /mi-complete-workflow. Continue? (y/n)`). On `y`, atomic `progress.sh advance-to 5 7 --set sub-flow=none --set inspector-review-completed=true` (skip stage 6 — no review session needed), auto-fire `/mi-complete-workflow`. On `n`, stop without advancing — `current-stage` stays at 5 so the next `/mi-continue` re-prompts (or routes to Step 3b if findings were added in the meantime). The confirmation gate exists because once `/mi-complete-workflow` fires it archives blueprints and advances the queue.

- If non-empty: auto-fire `/mi-review`. Stop after that — the second `/mi-continue` does NOT auto-fire `/mi-complete-workflow`.

  

**Stage 6 — Inspector review session (`mi-review`).**

Pure launcher:

1. Compose `review-context.md` (compact stage-6 review primer: active scope, goals, implemented surface, open-findings cheat sheet).

2. Set `sub-flow=reviewing`; advance 5 → 6.

3. Ask inspector for `review-mode` (`brainstorming` | `direct`).

4. **Brainstorming mode**: invoke the `brainstorming` skill with `review-context.md` + `inspector-review.md` as required first reads. The session loops internally: read findings → cascade-dispatch by scope (re-spec > re-plan > re-implement > fix) → mark each `fixed` via `review.sh set-status` → ask for approval. Inspector ends with `approve`.

**Direct mode**: millwright addresses each finding in the main session, commits per fix, marks each `fixed`, loops on `go again`.

5. Stop. Wait for inspector's `/mi-continue`.

  

**Stage 7 — Review completed (Review-Resume Handler).**

1. Check for open findings. If any remain, prompt the inspector to either proceed with deferred findings (they are archived in the stage-8 implementation snapshot), re-launch `/mi-review`, or abort. If none remain, prompt with the same y/n confirmation as the no-findings stage-5 path (`inspector-review.md has no open findings. Confirming will complete the inspector-review stage and auto-fire /mi-complete-workflow. Continue? (y/n)`). On `n`, stop without advancing — `current-stage=6, sub-flow=reviewing` stays in place so the next `/mi-continue` re-prompts.

2. Keep `sub-flow=reviewing` in place while the refresh decision is pending so the prompt is re-fireable on retry.

3. Diagram refresh: when review-loop commits exist, prompt y/n to re-run `/mi-draw-diagrams` before stage 8 archives the live `implementation/diagrams/` (the refreshed render is what gets preserved into history). Skipped silently when no review-loop commits exist; the y/n choice is the only optional bit.

4. Atomically finalize with `progress.sh advance-to 6 7 --set sub-flow=none --set inspector-review-completed=true`, then auto-fire `/mi-complete-workflow`.

  

**Stage 8 — Completion (`mi-complete-workflow`).**

1. `todo.sh bulk-transition IMPLEMENTING IMPLEMENTED --feature <active>`. CANCELED items are left alone.

2. `commits.sh populate-requirements <feature>` writes `commits:` field in `requirements.md` frontmatter (the canonical link between requirements and implementation).

3. `blueprints.sh rotate <feature> --reason-kind completion --reason-summary "..."` moves `blueprints/current/*` into `blueprints/history/v[N+1]/` and writes `reason.md`. This step rotates the blueprint artifacts only.

4. `/mi-complete-workflow` then archives the live `implementation/` folder alongside the rotated blueprints as `blueprints/history/v[N+1]/implementation/` (inspector-review.md, review-context.md, change-summary.md, diagrams/ all preserved). This is an archive, not a delete: every finding (including any deferred `status: open` ones), the review-context snapshot, the change-summary, and the implementation diagrams survive as part of the rotated version. The rotated history version therefore contains: `requirements.md`, `config.md`, `diagrams/`, `primer.md`, `reason.md`, AND `implementation/`.

5. `progress.sh finish` (active.feature → completed; active = null).

6. If `queue` non-empty: announce next feature and auto-invoke `/mi-apply-impact` (loop back to stage 2).

If `queue` empty AND `[ ] TODO` items remain in the active cycle's `todo-list.md`: ask inspector to mark next batch and type `/mi-continue` (re-enters stage 1.5 via `progress.sh enqueue`).

If `queue` empty AND no `[ ] TODO`: cycle complete; recommend `/mi-run` for a new cycle (which will create a new dated subfolder under `quest/`, leaving the just-completed one preserved as a permanent task archive).

  

---

  

## 6. The Workflow Commands (full reference)

  

All commands live under `commands/` as Markdown files with YAML frontmatter (`description:` and optional `argument-hint:`). The slash-command name matches the file name.

  

### 6.1 Setup / dependency commands

  

#### `/mi-init`

- **Invocation**: inspector, once per workspace.

- **Behavior**: runs `doctor.sh --format=json`; collects all required-and-missing checks into Bash-runnable (cli/pymod) and plugin-kind (slash-command-only) buckets; prints a one-line status; offers a single y/n to install all Bash-runnable deps in batch; prints slash-command instructions for plugin-kind deps; scaffolds `journal/`, `quest/`, `workflow-stream/` under the data root if absent; prints the canonical handoff text describing what to do next.

- **Idempotent**: yes.

  

#### `/mi-doctor`

- **Invocation**: inspector (manual) or auto-invoked by `/mi-run` preflight.

- **Behavior**: detailed dependency check. Per-dep prompts and sudo handling. Returns JSON or human-readable summary.

  

#### `/mi-ingest`

- **Invocation**: inspector.

- **Modes**: `<folder>`, `--file <path>`, `--stub <path>`, `--dry-run`, `--force`.

- **Behavior**: dispatches by extension. Documents (`.pdf`, `.docx`, `.pptx`, `.xlsx`, `.html`) → docling with `--image-export-mode referenced` (figures land in `<stem>.images/` next to the produced `.md`). Standalone images → stub `.md` referencing the original (Claude is a VLM; docling's image pipeline is net-negative for standalones). Short PDFs (≤ 20 pages) default to a stub.

  

### 6.2 Cycle-level commands

  

#### `/mi-run <folder1> [<folder2> ...] [--archive-active]`

- **Invocation**: inspector; once per cycle.

- **Behavior**: Step 0 preflight via `doctor.sh --preflight` (now includes a `git rev-parse --verify HEAD` check, so a fresh repo with zero commits fails the preflight); Step 1 parse arguments; Step 2 detect non-text files and run per-file ingest decision flow; Step 3 compute the new cycle's slug — `YYYY-MM-DD-<journal-folder-slugs-joined-with-+>` plus an optional 3-character hex collision suffix when the same slug already exists under `quest/` for the day — create `quest/<slug>/`, and call `quest.sh start <slug>` to point `quest/active.md` at it; Step 4 generate `quest/<active-slug>/todo-list.md` (per-feature checklist with `<feature>-NNN` IDs), `quest/<active-slug>/summary.md` (feature-indexed digest), and `quest/<active-slug>/progress.md` with queue populated. `queue-rationale.md` is **not** written here — it is deferred to stage 1.5 by design.

- **`--archive-active` flag**: if a cycle is already in flight, retire it without finishing. The current `quest/<active-slug>/` is preserved untouched (frozen as a permanent record), `quest/active.md` is cleared via `quest.sh end`, and a fresh cycle subfolder is created on top. Use this when the cycle has gone in a wrong direction and you want a clean restart without losing the audit trail. Without this flag, attempting `/mi-run` while a cycle is active is refused.

- **Post-conditions**: `quest/active.md` points at the new slug; `quest/<active-slug>/{todo-list.md, summary.md, progress.md}` exist; `progress.md.active=null`. Branch deferred to stage 2. Older `quest/*/` subfolders remain untouched.

  

### 6.3 Per-feature workflow commands

  

#### `/mi-apply-impact` (auto-fired)

- **Invocation**: auto-fired by `/mi-continue` Pre-flight Step 2B (and by Pre-flight Row A between features), and by `/mi-complete-workflow` Step 7 (when queue still has features). Manually invokable for recovery.

- **Behavior**: three-branch re-entry per Step 1 (Item 2 of v11 plan):

  1. **`active` is null** — calls `progress.sh activate` to pop `queue[0]` into a fresh `active` block (current-stage=2). Original happy path.

  2. **`active.current-stage == 2`** — re-entering the same feature mid-stage-2. Skips activation; surfaces `blueprints.sh check-current` status (`0` complete → short-circuit unless `--force`; `1` empty → regenerate; `2` partial → refuse without `--force`).

  3. **`active.current-stage > 2`** — refuses; the inspector must run `/mi-abort-workflow` to clear before re-running.

  Then runs `docs/blueprint-regeneration.md` (Step A requirements, Step B config + branch pre-fill, Step C diagrams).

- **Post-conditions**: `blueprints/current/{requirements.md, config.md, diagrams/, diagrams/README.md}`; `active.current-stage=2`.

  

#### `/mi-plan-implementation` (auto-fired)

- **Invocation**: auto-fired by `/mi-continue` Approve Handler.

- **Behavior**: PENDING→IMPLEMENTING via `todo.sh bulk-transition`; `git rev-parse HEAD` captured into `active.base-commit`; validates `## GIT BRANCH` (refuses main/master, refuses multi-line, refuses mismatch with HEAD); writes `primer.md` (compact stage-3 launch primer); asks inspector for `planning-mode` (`brainstorming` | `direct`); persists choice; brainstorming mode invokes the `brainstorming` skill, direct mode reads primer in main session.

- **Post-conditions**: `active.current-stage=3`, `active.planning-mode` recorded, `active.sub-flow=chain-in-progress` for both planning modes. Direct mode is distinguished by `active.planning-mode=direct`; the Resume Handler later changes `sub-flow` through `resuming` and finally back to `none`.

  

#### `/mi-draw-diagrams [--target=implementation]` (auto-fired or manual)

- **Invocation**: auto-fired by `/mi-continue`'s Resume Handler (Step 5, unconditionally) and by the Review-Resume Handler (Step 2.5 — only when the inspector answers `y` to the diagram-refresh prompt, which itself only fires when review-loop commits exist). Manually invokable.

- **Behavior**: thin wrapper dispatching on `--target`. Default target `implementation` runs the body of `mi-generate-implementation-diagrams`.

  

#### `/mi-generate-implementation-diagrams` (internal)

- **Behavior**: ensures `implementation/change-summary.md` is current via `commits.sh change-summary-fresh` (cache-keyed by `(base-commit, head)`; exit 0 = fresh, 1 = stale, 2 = missing). Reads commit range `active.base-commit..HEAD`. Renders use-case + sequence + (if relevant) one optional class-OR-component diagram via PlantUML MCP into `implementation/diagrams/` with the blue/green existing-vs-new convention (blue `#D6EAF8` boxes + `#3498DB` arrows for pre-existing; green `#D4EDDA` boxes + `#27AE60` arrows for new; flavor-aware `legend right` block). Codebase reads are bounded (diff hunks first; ≤ 3 callers/callees per changed file; skip generated/vendor/lock; record skipped paths under `## Omitted from analysis` in `change-summary.md`).

  

#### `/mi-review` (auto-fired)

- **Invocation**: auto-fired by `/mi-continue` Inspector Step 3b. Manually invokable. Re-entry after a clear-point also lands here, not on `/mi-continue`.

- **Behavior**: pure launcher. **Step 0 — clear-point gate (`stage-5-to-6`)**, fired at the very top before any state mutation; recommends `/clear` and records the identifier in `progress.md.active.clear-recommendations`. Then composes `review-context.md` (compact stage-6 review primer; folds `decisions.md` content + the `review-mode-suggestion` if present); sets `sub-flow=reviewing`; advances 5 → 6; asks inspector for `review-mode`. Brainstorming mode invokes the `review-iteration-runner` sub-agent (which has the `Skill` tool and chains into `brainstorming` / `writing-plans` for `re-spec` / `re-plan` cascades). Direct mode keeps the loop in the main session. Mi-review does NOT advance past 6 and does NOT auto-fire `mi-complete-workflow` — that's the Review-Resume Handler's job.

  

#### `/mi-complete-workflow` (auto-fired)

- **Invocation**: auto-fired on stage-7 clean exit (and by Pre-flight Row B for post-finish housekeeping recovery, and by the active-row stage-7 dispatch). Manually invokable for recovery.

- **Behavior**: Step 0 dispatches into one of five branches (per the v11 progress-gap plan, Item 6) so a partially-completed prior invocation can resume cleanly:

  - **Branch 0a — in-flight rotation matching completion.** Exactly one `v[K].partial/` exists for `active.feature` with `reason.md.kind == "completion"`. Resumes the partial via `blueprints.sh resume-partial --expected-kind completion`, skips Steps 1–4, proceeds Step 5 onward.

  - **Branch 0b — different-kind partial blocks completion rotation.** Refuses with a guidance message ("finish or abandon that rotation first"); no state mutation.

  - **Branch I — post-finish recovery (active=null).** `progress.completed[-1]` exists and its latest finalized `v[N]/reason.md.kind == "completion"`. Reconstructs `active_feature` from `completed[-1]`, skips Steps 1–6, runs Step 7 housekeeping only.

  - **Branch II — rotation already done (active!=null, finalized vN/).** `blueprints/current/requirements.md` is missing AND latest finalized `v[N]/reason.md.kind == "completion"`. Resumes from Step 5.

  - **Branch III — normal forward path.** Falls through to Step 1; before Step 4's rotate, runs `blueprints.sh check-current --require-primer "$active_feature"` and requires `0` (the completion rotation must never archive a `current/` tree missing the stage-3 primer; Item 9 of the v11 plan).

  Steps (when reached): Step 1 resolves inputs (active feature, base-commit, etc.); Step 2 IMPLEMENTING → IMPLEMENTED via `todo.sh bulk-transition --feature` (CANCELED items left alone; skipped on Branch I — the prior invocation already ran this); Step 3 populates `commits:` in `requirements.md` via `commits.sh populate-requirements`; Step 4 rotates `blueprints/current/` into `history/v[N+1]/` via `blueprints.sh rotate --reason-kind completion`; Step 5 **archives the live `implementation/` folder** into `history/v[N+1]/implementation/` (inspector-review.md, review-context.md, change-summary.md, grounding-report.md, manual-test-plan.md, manual-test-results.md, manual-test-plan.history/, diagrams/ all preserved as a permanent audit record — not deleted; `decisions.md` lives at the feature root and is not rotated); Step 6 `progress.sh finish` (active.feature → completed; active = null); Step 7 housekeeping — when the queue is non-empty, the **feature-A→feature-B clear-point gate** fires here: recommends `/clear` to the inspector and halts before auto-firing `/mi-apply-impact` for the next feature (this gate is one-shot and uses no tracking flag); else if active cycle's `todo-list.md` still has `[ ] TODO` items, asks the inspector to mark the next batch and type `/mi-continue`; else `quest.sh end` archives the pointer and recommends `/mi-run`.

  

#### `/mi-manual-test-plan [--from-resume] [--force | --discard-existing]`

- **Invocation**: auto-fired by `/mi-continue` Resume Step 7 when the inspector answers `y` to the manual-testing offer; manually invokable while `current-stage=5`. Refuses outside stage 5.

- **Behavior**: generates `workflow-stream/<feature>/test/manual-test-plan.md` (schema `manual-test-plan`), enumerating inspector-runnable scenarios derived from `requirements.md` Goals + `change-summary.md` + open todos. On `--force` or `--discard-existing`, rotates the existing plan into `test/manual-test-plan.history/<timestamp>/` so prior plans survive as audit artifacts. Auto-rotates prior-activation results into `test/manual-test-results.history/<timestamp>/` at Step 1 (cross-activation guard — see `docs/manual-testing-folder/plan.md` § 4.1). Sets `sub-flow=manual-testing`. Does not run the plan — that is `/mi-manual-test-run`'s job.

  

#### `/mi-manual-test-run [--seed-only]`

- **Invocation**: auto-fired by Resume Step 7 immediately after `/mi-manual-test-plan` succeeds; auto-fired by the Manual-Test-Resume Handler on re-entry; manually invokable. The single owner of mutations to `inspector-review.md` from manual-test results.

- **Behavior**: walks the plan's scenarios, captures per-scenario outcomes into `manual-test-results.md` (schema `manual-test-results`, with `state ∈ {in-progress, complete}`, `current-scenario` cursor, `plan-id`, `seed-family-id`, counts). On a failure under `failure-policy=auto-seed`, calls `review.sh upsert-manual-test-failure` to seed an `### IR-NNN` finding with deterministic `seed-id: manual-test:<seed-family-id>:<scenario-id>` (idempotent across re-runs); under `manual` policy, prints the failure and lets the inspector hand-author the finding. `--seed-only` is the recovery shape used when results exist but seeding never completed (Manual-Test-Resume Handler Branch B). Helpers: `review.sh find-by-seed-id`, `find-by-seed-id-family`, `add` extension, plus `FIELD_RE` canonical ordering.

  

#### `/mi-export-bundle`

- **Invocation**: inspector, any time an active cycle + active feature exists.

- **Behavior**: extracts (does NOT synthesize) the active feature's current state into a single self-contained markdown file at `tmp/bundles/<feature>-stage<N>-<timestamp>.md`. Sections: requirements, scope, custom project instructions, project constraints, feature background, decisions, codebase-context audit, implementation summary, changed-files index, manual-test results, open review findings. Strips frontmatter / HTML scaffolding / template placeholders / workflow file paths. Excludes diagrams, diffs, prose synthesis. Pre-flight refusals (in order): no active cycle / no active feature / worktree fingerprint mismatch — must precede any `mkdir -p tmp/bundles`. Auto-writes `tmp/bundles/.gitignore` so bundles stay out of source control. Engine: `scripts/bundle.sh export` (the only subcommand in v1).

  

#### `/mi-init-status-bar [--user|--project-shared] [--plugin-root <abs>]`

- **Invocation**: inspector, once per workspace (or whenever the wiring is lost). Idempotent.

- **Behavior**: writes a generated wrapper at `.claude/mi-stage-info-bar.sh` with the plugin's absolute path baked in (necessary because Claude Code does NOT expand `$CLAUDE_PLUGIN_ROOT` inside `statusLine.command`), then writes the matching `statusLine.command` block to settings.json. Default target: `.claude/settings.local.json` (project-local). `--user` writes to `~/.claude/settings.json`; `--project-shared` writes to `.claude/settings.json` (warns and requires confirmation because it's committed to source). The renderer itself (`scripts/info-bar.sh`) is **pull-only** — Claude Code calls it on its own status-line cadence; it reads stdin JSON, anchors to `workspace.project_dir`, parses `quest/active.md` + `progress.md` once via a single `python3 -S -I` invocation, prints one line, and exits 0. No state, no writes, no logs, no hooks. Hot-path target ≤100 ms. Always exits 0 (Claude Code surfaces stderr from a failing statusLine, which would visually break the prompt).

  

  Display:

  - Active feature, stages 2–7: `mi-workflow · <feature> · Stage <N> · <stage-name>`.

  - No active feature (`active=null`), cycle present: `mi-workflow · cycle <slug> · Stage 1 · quest generated`.

  - No active cycle: `mi-workflow · idle`.

  - Outside an mi-workspace: empty output.

  

  Note: an earlier "status-bar" feature (PostToolUse hook + JSON sidecar + NDJSON usage log for token tracking) was removed in v0.7.4 and replaced by the pull-only renderer in v0.7.5.

  

### 6.4 The universal advancement signal

  

#### `/mi-continue` (inspector)

The single touchpoint at every inspector gate. Reads `progress.md` and dispatches to the right handler.

**Pre-flight rows (`active = null`)** — evaluated first, in order:

| Pre-condition (in addition to `active = null`) | Handler |

| --- | --- |

| `[x] TODO` lines exist in active cycle's `todo-list.md` (selections not yet promoted) | **Pre-flight Step 2A** — `pend-selected`, group by feature, propose prioritized order |

| no `[x] TODO` lines, queue non-empty, `queue-rationale.md` missing | **Pre-flight Step 2B (initial)** — write `queue-rationale.md` (implicit Batch 1 with cumulative `features:`; top-level `status` may be omitted because missing means confirmed), `progress.sh reorder`, auto-fire `/mi-apply-impact` |

| no `[x] TODO` lines, queue non-empty, `queue-rationale.md` present, top-level `status: draft` | **Pre-flight Step 2B (extended — multi-batch)** — confirm or update the latest `## Batch <N>` body, refresh top-level `features:`/`batch:`, flip `status` to `confirmed`, then auto-fire `/mi-apply-impact` |

| **Row A — between features:** queue non-empty, `queue-rationale.md.status` is `confirmed` (or absent ⇒ confirmed), `(queue-rationale.md.features − progress.completed, preserving order) == progress.queue` | Auto-fire `/mi-apply-impact` for `queue[0]` (no inspector prompt — the cumulative invariant is already satisfied) |

| **Row B — post-finish housekeeping recovery:** queue empty, no `[x]/[ ] TODO`, `progress.completed` non-empty, `blueprints/history/v[N]/reason.md.kind == "completion"` for `completed[-1]`, `quest/active.md.status == "active"` | Auto-fire `/mi-complete-workflow` (short-circuits to its Branch I — Step 7 housekeeping only) |

| catch-all (queue empty, no `[x] TODO` lines) | Delegate to `/mi-resume-workflow` for diagnosis |

**Active rows (`active != null`)** — evaluated by `current-stage` + `sub-flow`:

| `current-stage` | `sub-flow` | Handler |

| --- | --- | --- |

| 2 | any | **Approve Handler** — Step 1 sanity-check (require default-mode `blueprints.sh check-current "$active_feature" == 0`); Step 2 **clear-point gate (`stage-2-to-3`)** — recommends `/clear` to the inspector (Claude Code does not let agents invoke `/clear` programmatically); records the identifier in `progress.md.active.clear-recommendations` so re-entry doesn't re-prompt; Step 3 auto-fire `/mi-plan-implementation` |

| 3 | any | **Resume Handler** — Step 0 drift-completion probe (skipped when `drift-check-completed=true`); Step 1 verify commits in `base-commit..HEAD` (zero-commit branch offers `retry-launch` / `direct-empty` / `abort`); Step 2 idempotent flag writes (`sub-flow=resuming`, `implementation-completed=true`); Step 2.5 abandoned-chain recovery (read-only inspection of `docs/superpowers/plans/`); Step 3 drift prompt (skipped when probe set the marker; accepts `<reason>` / `auto` / `continue`); Step 4 drift side effect (auto-fires `/mi-update-blueprint --reason-kind=spec-update <reason>`); Step 5 auto-fire `/mi-draw-diagrams`; Step 6 init `inspector-review.md` skeleton; Step 7 manual-testing offer (y/n — `y` auto-fires `/mi-manual-test-plan --from-resume` then `/mi-manual-test-run` under `sub-flow=manual-testing`); finally atomic `progress.sh advance-to 3 5 --set sub-flow=none`. Stage 4 is **not** persisted — the transition is atomic 3→5 |

| 5 | manual-testing | **Manual-Test-Resume Handler** — placed ABOVE the catch-all `5 | (any)` row. Dispatches on (plan exists, results exists, results state); Branch A re-fires `/mi-manual-test-run`; Branch B re-fires `/mi-manual-test-run --seed-only` (results exist but seeding never completed); diagnostic + refuse on genuinely-inconsistent shapes |

| 5 | any | **Inspector Handler** — Step 0 manual-test summary line (read-only); Step 1.5 canonicalize free-form findings; Step 1.6 persist `review-mode-suggestion`; list-open. If empty, **prompt y/n confirmation** before auto-firing `/mi-complete-workflow`; on `y`, atomic `advance-to 5 7 --set sub-flow=none --set inspector-review-completed=true` and auto-fire. If non-empty, auto-fire `/mi-review` and stop |

| 6 | reviewing | **Review-Resume Handler** — check/defer open findings (with the same y/n completion confirmation as the no-findings stage-5 path), offer a diagram refresh when review-loop commits exist before advancing, then atomic `advance-to 6 7 --set sub-flow=none --set inspector-review-completed=true` and auto-fire `/mi-complete-workflow` |

| 7 | any | Stage-7 finalize — auto-fire `/mi-complete-workflow` (idempotent via Branch II when re-entered after a partial finalize) |

| any other | — | Delegate to `/mi-resume-workflow` for diagnosis |

  

### 6.5 Recovery / utility commands

  

#### `/mi-abort-workflow [--drop-feature=requeue]`

- Reverts IMPLEMENTING → PENDING in the active cycle's `todo-list.md` (scoped to the active feature; other features' todos are unaffected). Deletes `implementation/*` (an aborted cycle has no committed work to archive). `progress.sh reset` (keeps feature + branch, clears base-commit + execution-mode + completion flags, sub-flow=none, current-stage=2). Preserves `blueprints/current/`. Never touches git.

- `--drop-feature=requeue` → appends `$active_feature` to end of queue (IMPLEMENTING todos still revert to PENDING).

- `--drop-feature=completed` was **removed**. It bypassed canonical stage-8 work (no `commits:` populated, no blueprint rotation, no archival of `implementation/` artifacts) and produced state inconsistent with the schema's contract that "completed" means stage 8 was reached. To finalize a feature whose work has shipped, run `/mi-complete-workflow` directly — it's the single canonical finalizer.

  

#### `/mi-resume-workflow`

- Diagnostic. Reads `progress.md`, validates invariants, prints next-recommended-command. Does not mutate state.

  

#### `/mi-update-blueprint [--reason-kind <manual|spec-update>] [--force-regen] <reason>`

- Manual implementation-driven blueprint refresh (mid-cycle, stage 3+). Rotates `current/` into history; regenerates `requirements.md` Goals + diagrams from `change-summary.md` + diff hunks; copies Planned / Non-goals / `todo-item-ids` / `todo-list-id` verbatim from previous history version; regenerates `primer.md`; preserves `## GIT BRANCH` and `## Inspector Additions` via `blueprints.sh preserve-inspector-sections`; calls `review.sh sync-refs` to re-point in-flight `requirements-id` references.

- **`--reason-kind`** accepts `manual` (default) or `spec-update`. Stage-4's drift handler invokes the command with `--reason-kind=spec-update` so the rotation history correctly tags the trigger as a stage-4 drift fire. Other rotation kinds (`completion`, `re-spec-cascade`, `re-plan-cascade`) belong to their owning commands and are refused here.

- **`--force-regen`** discards the current `blueprints/current/` content and regenerates from the latest history version even when `current/` is partially complete. Refuses when the latest history version is `completion` or a cascade kind (no safe parent to restore from). For corrupted in-flight regenerations only.

- **Step 1.5 — Recovery decision tree** (closes F2): runs **before** Step 2's rotate so a partial state can never be archived. All `check-current` calls use `--require-primer` (stage-3+ command). Decision points: partial `.partial.tmp` / `.partial` directories handled first (resume or STOP); `check-current==1` (empty) + manual/spec-update parent → resume regen without rotate; `check-current==2` (partial) → STOP unconditionally (or `--force-regen` with safe parent); `check-current==1` with cascade / completion parent → recommend `/mi-resume-workflow`; `check-current==1` with no readable parent → STOP. The unconditional STOP on partial `current/` (without `--force-regen`) is intentional — auto-firing `--force-regen` would discard partial inspector-visible content without consent.

- **Deliberately NOT inputs**: `quest/<active-slug>/todo-list.md`, `quest/<active-slug>/summary.md`, `journal/`. Mid-cycle refreshes are reverse-engineered from the implementation; intake artifacts don't drift after stage 1.5.

  

#### `/mi-update-todo-list <subcmd> <args>`

- `add <feature> <state> <assignee> <item-id> <description>` — append item. State ∈ {TODO, IMPLEMENTING, CANCELED} only.

- `cancel <item-id>` — flip to CANCELED.

- `set-state <item-id> <state>` — flip to state. Refuses PENDING and IMPLEMENTED.

  

---

  

## 7. Technical underpinnings

  

### 7.1 Plugin descriptor (`.claude-plugin/plugin.json`)

  

```json

{

"name": "millwright-inspector-development-machine",

"version": "0.8.2",

"commands": "./commands/",

"mcpServers": {

"plantuml": { "command": "plantuml-mcp-server", "args": [] }

},

"userConfig": {

"data_root": {

"type": "string", "default": "millwright-inspector", "sensitive": false

}

}

}

```

  

Notable design choice: **`superpowers` is NOT declared as a plugin dependency.** Claude Code's `dependencies:` field is a hard load-time gate; declaring superpowers there would prevent `mi-init` from loading in the first place — which is precisely the command that guides the inspector through the install. Instead, `mi-init` / `mi-doctor` detect missing skills and print the slash commands for the inspector to run.

  

### 7.2 Hook (`hooks/hooks.json` + `hooks/validate-on-write.sh`)

  

A single `PostToolUse` hook matched on `Write|Edit`. Reads the tool-call JSON on stdin, extracts `tool_input.file_path`, and — if the file lives under the data root and matches a known schema — runs `scripts/internal/validate-frontmatter.sh <file> <schema>`. On failure, emits a JSON `{"decision": "block", "reason": "..."}` response to halt the turn until the inspector fixes the frontmatter. The hook is a no-op outside the data root and for unknown filenames, so general project edits proceed normally.

  

Coverage policy:

- **Validated**: `quest/active.md` (active-quest schema), `quest/<active-slug>/{progress, todo-list, summary, queue-rationale, context-ledger}.md`, `workflow-stream/<feature>/decisions.md`, `blueprints/current/{requirements, config, primer}.md`, `blueprints/current/diagrams/README.md` (diagrams-readme-blueprint schema), `implementation/{inspector-review, review-context, change-summary, grounding-report, manual-test-plan, manual-test-results}.md`, `implementation/diagrams/README.md` (diagrams-readme-implementation schema), `blueprints/history/v*/reason.md`.

- **Skipped (audit archive)**: other files under `blueprints/history/v*/` (including `history/v*/implementation/*` archived at stage 8) and older `quest/<old-slug>/*` subfolders — they were already validated when live and are immutable post-rotation/archival.

  

### 7.3 Schemas (`schemas/`)

  

JSON-Schema-as-YAML files validated by `ajv-cli` (preferred) or a `yq`-based structural fallback. One schema per artifact type:

  

```

active-quest.schema.yaml

change-summary.schema.yaml

config.schema.yaml

context-ledger.schema.yaml

decisions.schema.yaml

diagrams-readme-blueprint.schema.yaml

diagrams-readme-implementation.schema.yaml

grounding-report.schema.yaml

manual-test-plan.schema.yaml

manual-test-results.schema.yaml

primer.schema.yaml

progress.schema.yaml

queue-rationale.schema.yaml

reason.schema.yaml

requirements.schema.yaml

review-context.schema.yaml

review-file.schema.yaml

summary.schema.yaml

todo-list.schema.yaml

```

  

Notes on the per-schema surface:

- **`progress.schema.yaml`** — the `active` block carries optional fields used by the Resume Handler's drift-completion probe and the manual-testing sub-flow: `drift-check-completed` (boolean — true once the stage-4 drift prompt has been answered, persisted so a session break can't re-fire the prompt); `history-baseline-version` (integer — highest finalized `blueprints/history/v[N]` index for `active.feature` at stage-3 entry; used to distinguish this-cycle drift rotations from prior-cycle ones); `manual-test-state` (`none | running | complete | skipped`); `manual-test-failure-policy` (`none | auto-seed | manual`); `clear-recommendations` (array of clear-point identifiers already crossed, e.g. `stage-2-to-3`, `stage-5-to-6`, so gates don't re-prompt on re-entry — the feature-A→feature-B gate is one-shot and uses no flag). `active.sub-flow` admits a fifth value, `manual-testing`, while a stage-5 manual-test run is in progress. `active` also carries the immutable worktree-fingerprint trio `worktree-path` / `git-common-dir` / `git-worktree-dir` captured at activation; state-mutating subcommands of `progress.sh` refuse on mismatch.

- **`grounding-report.schema.yaml`** — frontmatter contract for `workflow-stream/<feature>/implementation/grounding-report.md`. Required: `id` (UUID v1–v8), `feature` (kebab-case), `seam-classification` (`backend | frontend | mixed | infra`). Optional: `contributors[]`, `date`. Written by the `codebase-grounder` sub-agent during `mi-apply-impact` Step A / Phase 2.1 before the `requirements.md` body is composed. `seam-classification` drives Step C's optional structural-diagram decision. Lifecycle matches the rest of `implementation/`: archived alongside at stage 8, deleted on `/mi-abort-workflow`.

- **`decisions.schema.yaml`** — frontmatter contract for `workflow-stream/<feature>/decisions.md`. Required: `id` (UUIDv4 only — pattern is stricter than the other schemas), `feature`. Lives at the **feature root** (not inside `blueprints/current/`); excluded from blueprint history rotation by design so it persists across blueprint regenerations and across the feature's whole lifetime. Body is a markdown log under stage-named H2s (`## Stage 2 — Blueprint approval`, `## Stage 5 — Findings canonicalization`, etc.). Writers: `mi-continue` Approve Handler (stage-2→3 clear gate) and Inspector Handler; `mi-complete-workflow` housekeeping. Read-only consumers fold it into `primer.md` (stage 3), `review-context.md` (stage 6), and `requirements.md` Non-goals + `config.md` Inspector Additions during mid-cycle blueprint regen.

- **`context-ledger.schema.yaml`** — frontmatter contract for `quest/<active-slug>/context-ledger.md`. Required: `id` (UUID v1–v8), `cycle-slug`. Per-cycle telemetry artifact (Phase 6.4 of context-optimization). Body has an `## Events` table with rows `stage | command | files | class | location | artifact` where `class ∈ {small, medium, large}` (under 2k / 2k–20k / over 20k tokens) and `location ∈ {main, sub-agent, fork}` so a `large + main` row signals a budget regression. Written by any command/script that does a context-heavy read via `scripts/ledger.sh append`. Append failures warn but do NOT block parent commands. Persists permanently with the cycle archive.

- **`manual-test-plan.schema.yaml`** — frontmatter contract for `test/manual-test-plan.md`. Enumerates inspector-runnable scenarios derived from `requirements.md` Goals + `change-summary.md` + open todos. Carries `generated-in-activation` (UUIDv4 of the activation that rendered the plan — cross-activation discriminator).

- **`manual-test-results.schema.yaml`** — frontmatter contract for `test/manual-test-results.md`. Carries `state ∈ {in-progress, complete}`, `current-scenario` cursor, `plan-id` (back-reference to the plan), `seed-family-id` (used in the deterministic finding `seed-id`), `generated-in-activation` (copied from the plan; cross-activation discriminator), and counts.

- **`queue-rationale.schema.yaml`** — supports a multi-batch shape: optional top-level `status: draft | confirmed` and `batch: integer` (≥ 1) describe the LATEST batch only; older batches' statuses live in the body audit trail. `features:` is the cumulative ordered list across all confirmed batches (and the proposed order for the latest batch when status: draft). The dispatcher's between-features Row A relies on `features − progress.completed` equalling `progress.queue` exactly. Both fields are optional for back-compat with single-batch v10-and-earlier files.

- **`diagrams-readme-blueprint.schema.yaml`** — frontmatter contract for `blueprints/current/diagrams/README.md`. Carries `requirements-id` (mandatory back-reference to the sibling `requirements.md.id`) plus optional `id` (UUID) for new-style READMEs. UUID pattern is permissive (any RFC 4122 v1–v8 with valid variant nibble).

- **`diagrams-readme-implementation.schema.yaml`** — frontmatter contract for `implementation/diagrams/README.md`. Requires `id` and `stage: implementation`. Intentionally does NOT carry `requirements-id` — the implementation-side review artifacts (`inspector-review.md`, `review-context.md`, `change-summary.md`) carry the requirements back-reference instead.

- **`active-quest.schema.yaml`** — frontmatter contract for the top-level `quest/active.md` pointer. Required fields: `slug` (active subfolder name, or null when no cycle is active), `started` (ISO-8601 timestamp the cycle was opened by `/mi-run`), `journal-folders` (the `journal/<folder>` names `/mi-run` was invoked with — preserved so historical quests carry their input provenance), `status` (`active | archived | none` — `active` means a cycle is in flight, `archived` means the previous cycle ended cleanly with `slug=null`, `none` means the workspace has never run a cycle).

### 7.4 Templates (`templates/`)

  

Mustache-style templates rendered by `frontmatter.sh init`. The script auto-injects a fresh UUID via `uuid.sh` if `UUID=` isn't passed, then substitutes the remaining `{{KEY}}` placeholders. Templates exist for every workflow artifact:

  

```

active-quest.md.tmpl

change-summary.md.tmpl

config.md.tmpl

context-ledger.md.tmpl

decisions.md.tmpl

grounding-report.md.tmpl

manual-test-plan.md.tmpl

manual-test-results.md.tmpl

inspector-review.md.tmpl

primer.md.tmpl

progress.md.tmpl

queue-rationale.md.tmpl

reason.md.tmpl

requirements.md.tmpl

review-context.md.tmpl

sub-agent-return.md.tmpl

summary.md.tmpl

todo-list.md.tmpl

```

  

### 7.5 Scripts (`scripts/`)

  

| Script | Role |

| --- | --- |

| `uuid.sh` | Generate a single UUID v4. Prefers `uuidgen`; falls back to Python's `uuid` module. The only authority for ID minting. |

| `frontmatter.sh` | Read / write / init / validate YAML frontmatter. Subcommands: `init`, `get`, `set`, `validate`. |

| `progress.sh` | Manage the active cycle's `progress.md` (resolved via `quest.sh dir`). Subcommands: `init`, `activate`, `finish`, `requeue`, `reset`, `reorder`, `enqueue`, `get-active`, `queue-remaining`, `get`, `set`, `advance`, `advance-to`, `check-worktree`. `set` is atomic-batched (validate-all → same-dir temp file → schema-validate → atomic rename) so a partial multi-field write can't corrupt the file. `advance-to <expected> <target> [--set k=v]...` performs whitelisted skip-transitions in a single atomic write — the whitelist is `3→5` (Resume Handler eliminates stage 4 as a persisted state), `5→7` (no-findings approve path), and `6→7` (review-resume finalize). Adjacent transitions still use `advance`. `check-worktree` exposes the worktree-fingerprint guard for command markdowns to fail fast before any state writes. Uses Python heredocs for safe YAML mutation. |

| `todo.sh` | Manage the active cycle's `todo-list.md` (resolved via `quest.sh dir`). Subcommands: `set-state`, `bulk-transition` (with optional `--feature`), `pend-selected`, `list <state>` (with optional `--feature`). Enforces state-machine paths and assignee invariants. |

| `quest.sh` | Manage the active-quest pointer at `quest/active.md` and resolve the active cycle's directory for every other script. Subcommands: `slug` (print active slug or empty), `start <slug> [<journal-folder>...]` (write `quest/active.md` with `slug`, `started=<ISO-8601>`, `journal-folders=[…]`, `status=active`; create the subfolder if needed), `end` (flip `status=archived` and clear `slug`, leaving the subfolder in place), `init-pointer` (idempotent: create `quest/active.md` with `status=none` if missing), `current` (print active slug or fail), `dir` (print absolute path of `quest/<active-slug>/` or fail), `has-active` (exit 0 if pointer set, 1 otherwise), `status` (human-readable diagnostic), `list` (enumerate every `quest/<slug>/` subfolder as the task archive index). |

| `data-root.sh` | Resolve the data root path. Reads `MI_DATA_ROOT` (explicit shell override) first, then `CLAUDE_PLUGIN_USER_CONFIG_data_root` (Claude Code's injected `userConfig` value), defaulting to `millwright-inspector`. Every other script sources this rather than hardcoding the path so the same code works in default and `.millwright-inspector` (hidden) modes interchangeably. |

| `blueprints.sh` | Manage `workflow-stream/<feature>/blueprints/`. Subcommands: `ensure-current`, `rotate --reason-kind --reason-summary`, `resume-partial --expected-kind <kind>`, `preserve-inspector-sections`, `check-current [--require-primer] <feature>`, `branch-status <feature>`. Rotation kinds: `completion`, `spec-update`, `re-spec-cascade`, `re-plan-cascade`, `manual`. **Resumable rotation:** `rotate` follows a `.partial.tmp → .partial → vN` flow — Step 1 creates `vN.partial.tmp/`, Step 2 writes + validates `reason.md` inside it, Step 3 atomically renames `.tmp → .partial` (publishes recoverable intent), Step 4 moves `current/*` into `.partial/`, Step 5 atomically renames `.partial → vN` (finalizes). On re-entry, `rotate` recovers a single `.partial` only when its `reason.md.kind` matches the requested `--reason-kind`; the cross-product STOP refuses when more than one partial exists. `resume-partial` is a kind-asserting helper used by `mi-complete-workflow`'s Branch 0a. `check-current` returns 0 (complete-core), 1 (empty), or 2 (partial); with `--require-primer` it also asserts a valid `primer.md` (used by stage-3+ callers — `/mi-update-blueprint`, the Resume Handler probe, and the `/mi-complete-workflow` rotate preflight). `branch-status` reads `## GIT BRANCH` from `config.md` and prints one of `unset` (file missing or section empty), `set` (one non-trunk branch line), `trunk` (one branch line equal to `main` or `master`), or `multi` (two or more branch lines). |

| `migrate-diagrams-readme.sh` | One-shot helper that back-fills `requirements-id` (and an `id` UUID, when missing) into legacy `blueprints/current/diagrams/README.md` files. Idempotent; `--dry-run` mode supported; refuses to rewrite hand-supplied identifiers. |

| `review.sh` | Manage `inspector-review.md`. Subcommands: `init`, `add`, `set-status`, `iterate`, `list-open`, `sync-refs`, `canonicalize` (returns TSV of free-form spans), `strip-freeform`, `find-by-seed-id`, `find-by-seed-id-family`, `upsert-manual-test-failure` (the single owner of manual-test → review-file mutations; uses deterministic `seed-id: manual-test:<seed-family-id>:<scenario-id>` so re-runs are idempotent). IDs are `IR-NNN`, monotonically incremented. |

| `commits.sh` | Query and format `base-commit..HEAD`. Subcommands: `list`, `yaml`, `populate-requirements`, `changed-files`, `change-summary-fresh` (cache-keyed by `(base-commit, head)` — exit 0 fresh / 1 stale / 2 missing). |

| `bundle.sh` | Engine for `/mi-export-bundle`. Subcommands: `export` (the only subcommand in v1) — extracts the active feature's current state into `tmp/bundles/<feature>-stage<N>-<timestamp>.md`. Anything else: `usage: bundle.sh export` and exit 2. |

| `info-bar.sh` | Pull-only Claude Code `statusLine` renderer (NOT a hook). Reads stdin JSON from Claude Code, anchors to `workspace.project_dir`, parses `quest/active.md` + `progress.md` once via a single `python3 -S -I` invocation, prints one line, exits 0. No state, no writes, no logs. Hot-path target ≤100 ms. Always exits 0 so Claude Code's status line never visually breaks. |

| `ledger.sh` | Manage `quest/<active-slug>/context-ledger.md`. Two subcommands: `init` (idempotent skeleton write via `frontmatter.sh init context-ledger ... CYCLE_SLUG=<slug>`; refuses with info, exit 0, if the file already exists) and `append <stage> <command> <files> <class> <location> <artifact>` (appends one row to the `## Events` table; auto-runs `init` if missing; sanitizes `\|` characters; inserts before a `## Cycle summary` heading if present, otherwise at EOF; validates `class` and `location` enums). Anything else: `usage: ledger.sh {init\|append} ...` exit 2. |

| `ingest.sh` | Convert non-text journal files to sibling `.md`. Routes by extension (docling for documents, stub for images / short PDFs). |

| `doctor.sh` | Dependency detection and reporting. Outputs JSON or human-readable. `--preflight` mode for fast checks; the preflight now runs `git rev-parse --verify HEAD` (not just `--is-inside-work-tree`), so a fresh repo with zero commits fails the preflight rather than crashing later when stage 3 tries to capture `base-commit`. |

| `internal/common.sh` | Shared helpers: `mi_die`, `mi_info`, `mi_progress_file` (resolves through `quest.sh dir`), `mi_fm_get`, `mi_render_template`. `mi_render_template` YAML-encodes any value substituted into a YAML-frontmatter slot (e.g. `summary:` in `reason.md.tmpl`) so a value containing `:` or `#` no longer breaks parsing — single-line strings get quoted as needed; multi-line strings are emitted as a literal block scalar. |

| `internal/validate-frontmatter.sh` | Run by the PostToolUse hook. Loads schema, validates `.md` frontmatter, exits non-zero on failure. |

  

### 7.6 The PlantUML MCP integration

  

`plugin.json` registers `plantuml-mcp-server` as an MCP server. The millwright invokes the server's tools directly to render `.puml` sources to images during stage 2 (`mi-apply-impact`) and during the post-implementation Resume Handler (`mi-generate-implementation-diagrams`). The inspector must install the binary themselves (e.g. `npm install -g plantuml-mcp-server`); the plugin configures it but does not bundle it.

  

Diagram conventions (enforced by the millwright, not by tooling):

- File naming: `<type>-<subject>.puml` where `<type> ∈ {use-case, sequence, class, component}`. One diagram per file. Lowercase kebab-case.

- Mandatory: exactly one `use-case-<feature>.puml` per feature.

- Conditional: 2–3 `sequence-<flow>.puml` per feature. 1 is acceptable only when the feature has a single significant flow; >3 is a signal to decompose the feature, and the millwright surfaces this to the inspector rather than rendering a fourth.

- Optional, at most one: either `class-<domain>.puml` OR `component-<subject>.puml`, never both. Fires only on `backend`/`mixed` seams (per the codebase-grounding pass classification at stage 2) AND when the content threshold is met (3+ classes with non-trivial relationships → class; 3+ components with non-trivial dependencies → component; linear chains and pure UI/infra seams skip the slot).

- Both stage-2 blueprint diagrams and stage-4 implementation diagrams use the **blue/green existing-vs-new convention**: blue `#D6EAF8` boxes/packages + `#3498DB` arrows + `#D6EAF8` activations for pre-existing participants/classes/components; green `#D4EDDA` boxes/packages + `#27AE60` arrows + `#D4EDDA` activations for new / to-be-implemented elements; plus a `legend right … endlegend` block whose right-column wording reflects the cycle flavor (greenfield / bugfix / improvement).

- A sibling `diagrams/README.md` carries the `requirements-id` back-reference (since `.puml` files have no YAML frontmatter).

  

### 7.7 Optional companions

  

Detected by `/mi-doctor` but never required:

  

- **`rtk`** (rtk-ai/rtk) — pre-tool-use hook that filters verbose shell output (git diffs, test runs, logs). Targets exactly the kinds of commands the brainstorming review session and `/mi-generate-implementation-diagrams` run. Install: `brew install rtk && rtk init -g`. No plugin-level integration; once installed, applies session-wide.

- **`docling`** — IBM's document → markdown converter. Powers `/mi-ingest`. Required for DOCX/PPTX/XLSX/HTML, recommended for PDFs >20 pages, optional for short PDFs, deliberately skipped for standalone images. Pulls ~1–2 GB of ML deps (torch, transformers, OCR engine); first conversion downloads ~200–400 MB of model weights to `~/.cache/huggingface/`.

  

### 7.8 Skill references

  

The brainstorming chain at stage 3 and the brainstorming review session at stage 6 depend on five named skills:

  

- `brainstorming`

- `writing-plans`

- `executing-plans`

- `subagent-driven-development`

- `finishing-a-development-branch`

  

These can come from either:

1. The **superpowers plugin** (resolves names like `superpowers:brainstorming`).

2. Local `SKILL.md` files under `.claude/skills/<name>/`.

  

`mi-doctor` accepts both sources interchangeably and prints the exact `/plugin marketplace add` + `/plugin install` slash commands when missing.

  

### 7.9 Branch contract

  

The git branch is owned by the inspector end-to-end. Mi-workflow never creates, deletes, or force-updates branches.

  

- **Creation**: inspector's responsibility, before `mi-run`, between stages 1–2, or just before approving blueprints.

- **Declaration**: in `blueprints/current/config.md`'s `## GIT BRANCH` section. Pre-filled at stage 2 if HEAD is non-trunk.

- **Validation at stage 3**: exactly one branch line; branch ≠ main/master; branch == current HEAD. Empty section → millwright prompts the inspector (chat or edit-and-retry; either is valid).

- **Persistence**: `progress.md.active.branch` is null until stage 3, then set; `active.base-commit` captured from HEAD at the same time.

- **One branch per feature**: features may share or differ; the plugin doesn't enforce sameness across the queue.

  

### 7.10 The blueprint lifecycle

  

`blueprints/current/` is a *living* snapshot. Refresh triggers:

  

| Trigger | reason.md kind | Source of regeneration |

| --- | --- | --- |

| Stage 8 (`mi-complete-workflow`) | `completion` | n/a — `current/` becomes empty; the live `implementation/` is archived alongside as `history/v[N+1]/implementation/` |

| `/mi-continue` post-chain (stage 4) drift check (inspector-supplied reason) | `spec-update` (via `/mi-update-blueprint --reason-kind=spec-update`) | implementation-driven |

| Review-loop `re-spec` cascade | `re-spec-cascade` | implementation-driven (chain just regenerated spec) |

| Review-loop `re-plan` cascade (inspector confirms) | `re-plan-cascade` | implementation-driven |

| `/mi-update-blueprint <reason>` (manual) | `manual` | implementation-driven |

  

Implementation-driven means: read from `implementation/change-summary.md` + targeted `git diff base-commit..HEAD` hunks + previous history version. Quest data and journal are *not* consulted post-stage-1.5.

  

### 7.11 The review file schema

  

`inspector-review.md` is the single review artifact. Findings are `### IR-NNN` blocks with monotonically incrementing IDs (never reused). Per finding:

  

- **severity**: `blocker` | `major` | `minor`

- **scope**: `fix` | `re-implement` | `re-plan` | `re-spec`

- **status**: `open` | `fixed` | `wontfix`

- **details**: multi-line markdown body

- **fix-note**: populated on `fixed` / `wontfix`

  

Scope cascade priority (descending impact, tier-0 wins):

1. **re-spec** — re-invokes `brainstorming`; cascades through writing-plans + executing-plans. Invalidates current implementation.

2. **re-plan** — re-invokes `writing-plans`; cascades through executing-plans.

3. **re-implement** — re-invokes `executing-plans` / `subagent-driven-development` against the existing plan.

4. **fix** — direct patch.

  

When a higher-tier scope fires, all open lower-scope findings get `fixed` with `fix-note: "superseded by re-spec at iteration N"` because the code that drew them no longer exists.

  

Iterations are nested under `## Iteration N` headers. IDs stay stable across iterations — a fix landing in iteration 2 is still IR-005, just with `status: fixed`.

  

### 7.12 Layered context loading (Rule 3 in detail)

  

| Stage | Required first read | Canonical fallbacks (on demand) |

| --- | --- | --- |

| 3 (planning) | `blueprints/current/primer.md` | `requirements.md`, `config.md`, `quest/<active-slug>/summary.md` (active feature section), `quest/<active-slug>/todo-list.md` |

| 6 (review) | `implementation/review-context.md` + `implementation/inspector-review.md` | `requirements.md`, `config.md`, `quest/<active-slug>/summary.md` (active feature section), `blueprints/current/primer.md` |

  

Properties:

- Primers are **derived, not canonical**. Canonical files win on conflict.

- Primers are **overwritten on regeneration** by their writer.

- Primers are **rotated with their parent folder** (`primer.md` rotates with `blueprints/current/`; `review-context.md` is archived into `history/v[N+1]/implementation/` at stage 8, cleaned only on abort).

- `review.sh sync-refs` keeps `requirements-id` references live across rotations.

- `change-summary.md` is **cache-keyed** by `(base-commit, head)` and shared across `mi-generate-implementation-diagrams` and `/mi-update-blueprint`.

- `summary.md` is **feature-indexed**, so a stage reads only its active feature's section + cross-cutting constraints.

  

### 7.13 Sub-agent profiles (`agents/`)

  

As of v0.6.0 the previous "ad-hoc Task spawn" delegation policy is replaced by **first-class agent profiles** under `agents/`. Each profile is a Markdown file with YAML frontmatter (`name`, `description`, `model`, `effort`, `tools`); commands invoke them by name through the `Task` tool. Every profile returns per `docs/sub-agent-return-contract.md` with a ≤ 1k-token return body. Detailed evidence belongs in artifact files, not the return.

  

| Profile | Model / effort | Spawned by | Inputs | Output |

| --- | --- | --- | --- | --- |

| `journal-file-digester` | haiku / low | `mi-run` Step 2.5 Tier 1 | one oversized journal file (>100 KB) | digest in return body — read-only, no file writes |

| `journal-folder-digester` | haiku / medium | `mi-run` Step 2.5 Tier 2 | one journal subfolder (>5 files AND >40 KB total) | writes `<data_root>/quest/<active-slug>/.scratch/folder-digest-<folder>.md` |

| `dependency-mapper` | sonnet / medium | `mi-continue` Pre-flight Step 4c (stage 1.5) | queue of features (≥ 2) | 2–3 sentence ordering proposal in the return body — does NOT write files; main composes `queue-rationale.md` from the return |

| `codebase-grounder` | sonnet / high | `mi-apply-impact` Step A / Phase 2.1 (stage 2) | in-scope todo IDs, folder allowlist, cycle-flavor rule order | writes `implementation/grounding-report.md` and sets `seam-classification` via `frontmatter.sh set`. ≤ 5 files inspected per todo |

| `blueprint-diagrammer` | sonnet / high | `mi-apply-impact` Step C (stage 2) | `requirements.md` Goals + the just-written grounding-report | writes `.puml` sources into `blueprints/current/diagrams/` (never `.svg`/`.png` — has the PlantUML MCP tools) |

| `implementation-analyst` | opus / high | `mi-generate-implementation-diagrams` Phase 3.1 (Resume Handler / `/mi-draw-diagrams`) | `base-commit..HEAD` diff, `blueprints/current/diagrams/` as seed | writes `implementation/change-summary.md` and re-renders `implementation/diagrams/`; only re-renders changed subjects |

| `review-iteration-runner` | opus / high | `mi-review` Step 3a, per iteration (stage 6 brainstorming mode) | open findings, scope-cascade rules | calls `review.sh set-status`. Has the `Skill` tool and chains into the `brainstorming` / `writing-plans` Skills for `re-spec` / `re-plan` cascades. Does NOT mutate `progress.md` |

  

**Do NOT delegate** (these stay with main): workflow state mutations (`progress.sh`, `todo.sh`, `blueprints.sh`, `review.sh set-status` outside `review-iteration-runner`), stage transitions, command dispatch, final approvals, the y/n confirmation gates, any context-budget gating decisions.

  

---

  

## 8. End-to-end happy-path walkthrough

  

A single feature, brainstorming planning, brainstorming review, with one finding.

  

```

[Inspector] Drops journal/auth-meeting/{transcript.txt, notes.md}

[Inspector] Types: /mi-init # one-time setup

[Millwright] Installs deps via single y/n; scaffolds folders.

[Inspector] Types: /mi-run auth-meeting

[Millwright] Runs doctor preflight (including git rev-parse --verify HEAD);

computes slug 2026-04-27-auth-meeting; creates quest/2026-04-27-auth-meeting/;

quest.sh start writes quest/active.md → 2026-04-27-auth-meeting;

generates quest/2026-04-27-auth-meeting/{todo-list.md, summary.md, progress.md}.

(queue-rationale.md is intentionally NOT written here; it's deferred to stage 1.5.)

[Inspector] Edits quest/2026-04-27-auth-meeting/todo-list.md:

marks AUTH-001 and AUTH-002 with [x] (emin).

[Inspector] Types: /mi-continue # 1.5 step A

[Millwright] todo.sh pend-selected; groups by feature; proposes order: [auth].

[Inspector] Types: /mi-continue # 1.5 step B (accept)

[Millwright] Writes quest/2026-04-27-auth-meeting/queue-rationale.md;

progress.sh reorder; auto-fires /mi-apply-impact.

[Millwright] progress.sh activate (auth → active block).

Generates blueprints/current/{requirements.md, config.md, diagrams/}.

Pre-fills config.md ## GIT BRANCH from HEAD (feat/auth/jwt).

[Inspector] Reviews requirements + diagrams. Adds custom prompt under ## Inspector Additions.

[Inspector] Types: /mi-continue # stage 2 approve

[Millwright] Approve Handler validates files; auto-fires /mi-plan-implementation.

[Millwright] PENDING → IMPLEMENTING; captures base-commit; writes primer.md;

asks: "planning-mode? brainstorming or direct?"

[Inspector] Types: brainstorming

[Millwright] Persists planning-mode; sets sub-flow=chain-in-progress;

invokes brainstorming skill (isolated session).

[Inspector + chain] brainstorming → writing-plans → executing-plans →

subagent-driven-development → finishing-a-development-branch.

Commits land on feat/auth/jwt.

[Inspector] Types: /mi-continue # post-chain

[Millwright] Resume Handler: verifies commits exist; sets implementation-completed=true;

asks for blueprint-drift reason (reply: <reason> | auto | continue). Inspector types: continue.

Auto-fires /mi-draw-diagrams (renders implementation diagrams).

Initializes inspector-review.md skeleton. Asks: "Run manual testing now? (y/n)". Inspector types: n.

Advances to stage 5.

[Inspector] Reviews implementation/diagrams/ + the diff. Edits inspector-review.md:

"The JWT signing function in auth/jwt.ts hard-codes HS256; should be configurable."

[Inspector] Types: /mi-continue # stage 5

[Millwright] Inspector Handler: review.sh canonicalize finds the free-form span;

classifies severity=major, scope=re-implement; review.sh add creates IR-001

with the original sentence as `details`; review.sh strip-freeform removes the line.

review.sh list-open returns ["IR-001"].

Auto-fires /mi-review.

[Millwright] /mi-review writes review-context.md; sets sub-flow=reviewing;

advances 5 → 6; asks: "review-mode? brainstorming or direct?"

[Inspector] Types: brainstorming

[Millwright] Invokes brainstorming skill (isolated review session).

[Inspector + chain] Chain reads IR-001, classifies as re-implement, edits auth/jwt.ts,

commits. review.sh set-status IR-001 fixed. Asks inspector for approval.

[Inspector] Types: approve

[Inspector] Types: /mi-continue # post-review-session

[Millwright] Review-Resume Handler: list-open is empty;

prompts y/n to confirm completing the inspector-review stage.

[Inspector] Types: y

[Millwright] Offers diagram refresh before advancing.

[Inspector] Types: y

[Millwright] Re-runs /mi-draw-diagrams; atomically advances 6 → 7
with `progress.sh advance-to 6 7 --set sub-flow=none --set inspector-review-completed=true`;
auto-fires /mi-complete-workflow.

[Millwright] mi-complete-workflow:

todo.sh bulk-transition IMPLEMENTING IMPLEMENTED --feature auth;

commits.sh populate-requirements auth (writes commits: field);

blueprints.sh rotate auth --reason-kind completion

(current/* → history/v1/, AND archives live implementation/ as

history/v1/implementation/ — inspector-review.md, review-context.md,

change-summary.md, diagrams/ all preserved as a permanent audit record);

progress.sh finish (auth → completed, active = null).

Queue is empty; checks the active cycle's todo-list.md for unmarked [ ] TODO.

None found; recommends /mi-run for the next cycle (which will create a

NEW dated subfolder under quest/, leaving quest/2026-04-27-auth-meeting/

preserved permanently as part of the task archive).

```

  

What the inspector typed end-to-end: `/mi-init`, `/mi-run auth-meeting`, edit todo-list, `/mi-continue`, `/mi-continue`, edit config, `/mi-continue`, `brainstorming`, drove the chain, `/mi-continue`, `continue` (drift skip), `n` (manual-test skip), edit inspector-review.md, `/mi-continue`, `brainstorming`, drove the review session, `approve`, `/mi-continue`, `y` (completion confirmation), `y` (diagram refresh).

  

What the millwright did automatically: `mi-apply-impact`, `mi-plan-implementation`, `mi-draw-diagrams`, `mi-review`, `mi-draw-diagrams` (refresh), `mi-complete-workflow`, plus all script invocations. Clear-point recommendations fire at stage-2→3, stage-5→6, and feature-A→feature-B (the inspector is asked to type `/clear` themselves — Claude Code does not let agents invoke `/clear` programmatically).

  

---

  

## 9. Glossary

  

- **Active block** — the populated `active:` section of `progress.md` while a feature is mid-cycle.

- **Base-commit** — the git SHA captured at stage 3 just before chain launch / direct implementation. The lower bound of the implementation diff.

- **Blueprint** — the `requirements.md` + `config.md` + `primer.md` + `diagrams/` set under `blueprints/current/`.

- **Brainstorming chain** — the isolated session running `brainstorming` → `writing-plans` → `executing-plans` (or `subagent-driven-development`) → `finishing-a-development-branch`.

- **Canonicalize** — convert a free-form finding sentence into a structured `### IR-NNN` block.

- **Cycle** — the lifespan of a single `quest/<slug>/` cohort, from `/mi-run` to all features completed. The slug is `YYYY-MM-DD-<journal-folder-slugs-joined-with-+>` plus an optional 3-character hex collision suffix; older cycle subfolders are preserved permanently as a task archive.

- **Active cycle / active slug** — the cycle named by `quest/active.md`. All cycle-scoped scripts and commands resolve their working files (`todo-list.md`, `summary.md`, `progress.md`, `queue-rationale.md`) under `quest/<active-slug>/` via `quest.sh dir`.

- **Direct mode** — planning-mode or review-mode that keeps work in the main session instead of spawning a Skill.

- **Drift check** — the post-chain prompt asking the inspector whether requirements changed during brainstorming.

- **Existing-vs-new framing** — two-colour convention in stage-2 blueprint and stage-4 implementation diagrams: blue (`#D6EAF8` fill, `#3498DB` strokes) for pre-existing system elements, green (`#D4EDDA` fill, `#27AE60` strokes) for new / to-be-implemented elements. Legend wording adapts to cycle flavor (greenfield / bugfix / improvement).

- **Findings file** — `implementation/inspector-review.md`. Contains `### IR-NNN` blocks.

- **History version (vN)** — a snapshot of `blueprints/current/` rotated into `blueprints/history/vN/` with a sibling `reason.md`.

- **IR-NNN** — finding ID in `inspector-review.md`. Zero-padded, monotonically increasing, never reused.

- **Layered load** — the primer-first context discipline; canonical files are fallbacks.

- **Millwright** — the AI agent role.

- **Inspector** — the human role.

- **Primer** — a compact derived snapshot file (`primer.md`, `review-context.md`) that bootstraps a long-running stage.

- **Quest** — the cycle-wide working state under `quest/<active-slug>/`, plus the permanent archive of past cycles under `quest/<old-slug>/` siblings, plus the `quest/active.md` pointer file at the top level of `quest/`.

- **Re-spec / re-plan / re-implement / fix** — the four scope tiers for a finding.

- **Resume Handler / Approve Handler / Pre-flight Handler / Inspector Handler / Review-Resume Handler** — the five dispatch targets inside `/mi-continue`.

- **`progress.sh advance-to`** — atomic skip-transition with a stage-pair whitelist (`3→5`, `5→7`, `6→7`). `--set field=value` arguments are applied in the same atomic write, so `current-stage` skips and runtime-flag updates either all land or none do. Adjacent transitions still use `progress.sh advance` (which catches typo'd targets via the off-by-one check).

- **Drift-completion probe** — Resume Handler Step 0. Detects the case where a prior `/mi-update-blueprint --reason-kind=spec-update` rotated + regenerated successfully but the marker write was lost to a session break. Walks `blueprints/history/v[K] > history-baseline-version` looking for `reason.kind == "spec-update"`; if found AND `check-current --require-primer == 0`, persists `drift-check-completed=true` and skips Step 3.

- **Worktree-fingerprint guard** — `mi_assert_worktree_match` (in `scripts/internal/common.sh`) compares the current `pwd` / `git rev-parse --git-common-dir` / `git rev-parse --git-dir` against the immutable `worktree-path` / `git-common-dir` / `git-worktree-dir` recorded in `progress.md.active` at stage-2 activation. Every state-mutating subcommand of `progress.sh` calls it before writing; `progress.sh check-worktree` exposes the same gate for command markdowns to fail fast. Closes the gap where two `git worktree add` checkouts sharing the same `data_root` could clobber each other's active block.

- **Multi-batch queue-rationale** — `queue-rationale.md` body holds `## Batch <N>` (level-2) headings, one per ordering decision in the cycle; top-level frontmatter `status` / `batch` / cumulative `features:` describe the latest batch. The dispatcher's between-features Row A relies on `features − completed == queue` exactly; the draft-confirmation row routes a `status: draft` file through Step 2B's extended path before flipping it to `confirmed`.

- **Stage** — one of 0–8 in the canonical workflow. Stage 4 is conceptual — the Resume Handler runs "stage 4" work but `current-stage` never persists 4 (the handler ends with an atomic `advance-to 3 5`).

- **Sub-flow** — `none | chain-in-progress | resuming | reviewing | manual-testing` — secondary state dimension on top of `current-stage`. `manual-testing` is set by `/mi-manual-test-plan` while a stage-5 manual-test run is in progress.

- **Manual-testing sub-flow** — optional stage-5 sub-flow that lets the inspector run a generated test plan against the implemented surface before authoring findings. Two commands: `/mi-manual-test-plan` (generator) and `/mi-manual-test-run` (executor + auto-seeder). Two `progress.md.active` fields: `manual-test-state ∈ {none, running, complete, skipped}` and `manual-test-failure-policy ∈ {none, auto-seed, manual}`. Failed scenarios under `auto-seed` policy become `### IR-NNN` findings via deterministic `seed-id: manual-test:<seed-family-id>:<scenario-id>`. Implemented as a sub-flow rather than a new stage 4.5.

- **Clear-point** — a recommendation by the millwright to type `/clear` (start a fresh Claude Code session) at a high-context-payoff transition. Three points fire: `stage-2-to-3` (Approve Handler Step 2), `stage-5-to-6` (top of `/mi-review`), and feature-A→feature-B (`/mi-complete-workflow` Step 7 housekeeping when the queue is non-empty). The first two record the identifier in `progress.md.active.clear-recommendations` so re-entry doesn't re-prompt; the third is one-shot. Claude Code does NOT let agents invoke `/clear` programmatically — these are recommendations only.

- **Decisions log (`decisions.md`)** — feature-scoped, append-only markdown file at `workflow-stream/<feature>/decisions.md`. Lives at the feature root, NOT inside `blueprints/current/`; excluded from blueprint history rotation by design so it persists across blueprint regenerations and across the feature's whole lifetime. Body is organized under stage-named H2 headings.

- **Context ledger (`context-ledger.md`)** — per-cycle telemetry artifact at `quest/<active-slug>/context-ledger.md`. Body has an `## Events` table whose rows record the size class (`small | medium | large`) and location (`main | sub-agent | fork`) of every context-heavy read so a `large + main` row visibly signals a budget regression. Written via `scripts/ledger.sh append`; append failures warn but don't block.

- **Grounding report (`grounding-report.md`)** — stage-2 codebase-grounding snapshot at `implementation/grounding-report.md`. Written by the `codebase-grounder` sub-agent during `mi-apply-impact` Step A / Phase 2.1 before the `requirements.md` body is composed. Carries per-item seam findings and an overall `seam-classification` (`backend | frontend | mixed | infra`) that drives the optional structural-diagram decision in Step C. Archived alongside the rest of `implementation/` at stage 8.

- **Stage info-bar** — pull-only Claude Code `statusLine` renderer at `scripts/info-bar.sh`. Wired by `/mi-init-status-bar` (which writes `.claude/mi-stage-info-bar.sh` and a `statusLine.command` block in settings.json). NOT a hook; reads stdin JSON, prints one line, exits 0. The earlier "status-bar" feature (PostToolUse hook + JSON sidecar + NDJSON usage log) was removed in v0.7.4 and replaced by this pull-only renderer in v0.7.5.

- **Export bundle** — single self-contained markdown file produced by `/mi-export-bundle` at `tmp/bundles/<feature>-stage<N>-<timestamp>.md` for pasting into a fresh agent that lacks plugin/data access. Extraction-only, no synthesis. Engine: `scripts/bundle.sh export`.

- **Sub-agent profiles** — first-class agent definitions under `agents/` (introduced v0.6.0). Seven profiles: `journal-file-digester`, `journal-folder-digester`, `dependency-mapper`, `codebase-grounder`, `blueprint-diagrammer`, `implementation-analyst`, `review-iteration-runner`. See §7.13 for the full table.

- **Workflow stream** — the per-feature folder tree under `workflow-stream/<feature>/`.

- **Software 3.0** — The view that with capable LLMs, programming shifts from writing code (Software 1.0) or curating training data (Software 2.0) to curating prompts and context windows. The plugin's file-based context discipline (Rule 1) and layered loading (Rule 3) operate in this paradigm — every artifact is context-window content for a specific stage's agent.

- **Vibe coding** — Letting an AI agent land an implementation against an unwritten or informal spec with no structured review surface — the operator trusts the model, accepts the diff, and ships. **The mi-workflow is explicitly not vibe coding.** Even `planning-mode: direct` keeps the stage-2 spec review, the stage-3 primer, the stage-4 implementation diagrams, the stage-5 `inspector-review.md` findings, the optional stage-6 review session, and the stage-8 rotation + archival — the chain's internal ceremony is the only thing direct mode skips.

- **Agentic engineering** — Coordinating AI agents and runbooks to ship production-quality software faster without sacrificing the pre-AI quality bar (security, correctness, maintainability). **This plugin operates entirely in the agentic-engineering paradigm.** The blueprint files, primer composition, implementation diagrams with existing-vs-new framing, the `IR-NNN`-structured findings file, the rotation history with `reason.md`, and the mandatory inspector gates at stages 2, 5, and 6 are all agentic-engineering primitives — and they apply to both planning modes equally.

- **Jagged intelligence** — The tendency of LLMs to peak on tasks their training data and RL environments emphasized while breaking on superficially-similar but out-of-distribution tasks. The plugin treats jaggedness as a hard design constraint: every state transition is atomic or recoverable, every artifact is schema-validated on write, and the inspector's gates act as the final correctness check.

- **Verifiable artifact** — A workflow output whose correctness can be checked against a finite contract — `requirements.md.commits` populated at stage 8, the blue/green existing-vs-new diagrams, the `IR-NNN`-structured findings file, the `base-commit..HEAD` diff. The plugin is built so that every cycle ends with a set of these, not just code.
