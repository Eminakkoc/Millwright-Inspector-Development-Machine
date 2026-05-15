# Millwright-Inspector Agentic Workflow System

## Naming and the analogy

This approach mainly focuses on the software development with 2 actors which are:

1. The Millwright
2. The Inspector

The Millwright is the one who writes the code and the Inspector is the one who provides documents, notes and other resources for the millwright to implement. The Inspector also has another important task which is to check/review the outputs of each step that the Millwright perform.

Millwright-Inspector name came from the analogy where in a factory/plant a millwright is responsible from building, maintaining and fixing the heavy machines.

During the old times they were restricted by the available materials for building the appropriate machine for performing a specific task. In todays software development environment, we can consider project as the factory/plant, the modules or features in that project can be considered as machines that perform a task, and the developer can be considered as the millwright who builds those features with the given specs and requirements. The tools are restricted by the dependencies or libraries used in that project.

Before AI coding agents, the inspector was the developer themselves, they read the requirements, they create diagrams from those requirements and get ready for the implementation, then they first review the code they had written. But now with the AI coding agents being introduced, all those steps can now be done by the AI coding agent. Then what will todays developers do? This workflow system introduces a new role for the developers (as previously called) which is now called "The Inspector". The role of the inspector is to review and check each output of the millwright.

In this approach, there are defined stages which each of those stages produces an output to be reivewed and corrected by the inspector.

## Main Motivation

The main motivation behind creating such an approach is the current confusion among many developers, that they see themselves as useless by experiencing of hearing the capabilities and outputs of the ai coding agents. Things have been changed since those agent begin to get in our codebases. The kind of work the developers were doing before ai is now completely different from todays world. That was the reason the new role "Inspector" is introduced in this approach. To leave the traditional role which used to be called "developer", since the work done by those developers are also completely changed. And also the role "Millwright" was introduced since the development done by the ai coding agent is also its own type and also prevent the perception that "ai has taken the jobs of developers".

We believe that in todays software development environment, the coding part should be delegated to the ai coding agents completely. In this approach, the inspector should not interfere with the code that ai agents had been generating. Instead they should give the specs, rules, tools and review the output. The codebase is now just another item in the context alongside with the .md files inside the millwright-inspector folder.

## The Reform in Software Development Tools/Artifacts

There used to be 1 main component in a software project where the developer is responsible from, which was: the codebase. All other components, the requirement documents, task management tools, design handoff apps etc. were all other tools or artifacts which were connected to the codebase, since codebase is the main component which produces the output: the product. In todays world we no longer need that much external tools, resources or artifatcs which we used to use to help us developing code.

- Handoff tools are no longer needed since we use MCP's or directly code generated from design tools.
  With millwright-inspector agentic workflow system:
- Requirement documents will not be prepared and given by another actor Project manager or business analyst. They used to be a bridge between the customer and the developer, but now can be directly received from customers via voice recording and transforming them into prompts, or other specs documents provided which can be saved to RAG systmes or directly saved as text documents to be given to coding agents as inputs. Even a vibe-coded project can now be used as a prompt.
- Task management tools like JIRA or Linear are no longer needed with this approach since the input documents and specs are transformed and saved in "Journal" folders which are transformed into todo.md documents where you can add additional data such as: who is responsible from this task, related requirements.md documents, diagrams, commits etc. since all those info are in the same space with the codebase. Project managers can now get whatever data they desire from the documents which we will be talking about later. They will be able to get the relevant data by giving prompt to their own agents such as: "Can you please give me a detailed report on ongoing tasks?", "Please tell me if the development of the loyalty related topic we discussed in yesterdays meeting has been completed? And provide me summary how that feature interacts with the current authentication module?", "Summarize the work done by mobile team today" etc. They will get the information directly from .md files and codebase itself.

## Connections to broader AI-engineering practice

Several recurring concepts in the wider agentic-AI discourse map directly onto the load-bearing decisions in this spec — useful as a lens for understanding why the plugin is shaped this way:

- **Software 3.0 (programming = prompting; the context window is the lever).** Rule 1 ("inputs live in files, not in conversation context") and Rule 3 ("layered context loading") below operationalize this directly: every workflow-stream artifact is a deliberately-sized piece of context window for a specific stage's LLM consumer, and the `commands/*.md` runbooks are themselves prompts the agent reads and follows.
- **Agent-native infrastructure.** Every runbook, schema, and template is written for the agent first. The PostToolUse frontmatter validation hook gates every Write/Edit to a workflow `.md`, so an artifact only exists if it's parsable by the next consumer. There is no separate "human view" of state — the same `.md` files serve the agent and the inspector.
- **Agentic engineering, not vibe coding — in both planning modes.** Every cycle goes through the stage-2 spec review, stage-4 diagrams, stage-5 structured findings, stage-6 review session (when findings exist), and stage-8 archival. None of those is optional. `planning-mode: brainstorming` and `planning-mode: direct` differ only in *how the implementation work itself is run* (isolated chain vs main-session, with the chain providing its own spec/plan/execution gates). Direct mode trades the chain's internal ceremony for speed; it does not trade away the spec, the diagrams, the findings file, or the rotation history. Vibe coding — letting the agent land an implementation against an unwritten spec with no structured review — is explicitly not what this plugin does.
- **Verifiability as a design constraint.** Every cycle produces verifiable artifacts — `requirements.md.commits` populated at stage 8, the blue/green existing-vs-new diagrams that diff intent against reality visually, the structured `IR-NNN` findings file, the `base-commit..HEAD` diff as the canonical implementation contract. An LLM judge — human or otherwise — can close the loop without reading a chain transcript.
- **Jaggedness drives the recovery machinery.** The Resume Handler's drift-completion probe, atomic `progress.sh advance-to` skip-transitions, resumable rotations, the worktree-fingerprint guard, and `mi-complete-workflow`'s five-branch dispatch (0a / 0b / I / II / III) all exist because LLM output can be partial, contradictory, or session-broken at any point. The plugin never trusts a single transition.
- **Inspector owns understanding; millwright owns execution.** The two-role split keeps the human in the loop for every spec, change, and approval. Mandatory gates at stages 2, 5, and 6 mean the millwright never self-approves — `direct` mode does not lower this bar, it just removes the brainstorming-chain ceremony.
- **Layered, projected information as agent context.** `summary.md` (feature-indexed), `primer.md` (stage-3 launcher), `review-context.md` (stage-6 launcher), and `change-summary.md` (cache-keyed by `(base-commit, head)`) are derived projections of canonical data sized for a specific LLM consumer at a specific stage — never canonical themselves, regenerated only when the source moves.

See `docs/project-report.md` §1.4 for the longer mapping with worked examples.

## The Main Components

The 2 main compoents in this system are:

1. Codebase
2. Millwright-Inspector folder (The control room)

### Millwright-Inspector folder (The control room)

This folder holds three components at the data root:

1. **Journal**: essential resources which will be used for developing code — meeting transcripts, notes, specifications etc.
2. **Quest**: each `/mi-run` creates a fresh **per-cycle subfolder** under `quest/` (named after a date-prefixed slug derived from the journal folders — `YYYY-MM-DD-<journal-folder-slugs-joined-with-+>` plus an optional 3-character hex collision suffix when the same slug already exists for the day; e.g. `quest/2026-04-27-pricing-meeting/` for a single journal folder, `quest/2026-04-27-pricing-meeting+auth-rfc/` for two) and writes three of the cycle's files inside it at stage 1: `todo-list.md`, `summary.md`, and `progress.md` (single workflow state file — feature queue, completed features, currently active feature's runtime state). The fourth, `queue-rationale.md` (audit of the stage-1.5 dependency-ordering decision), is written by `/mi-continue`'s Pre-flight Step 2B at stage 1.5 once the inspector confirms the queue order — the dispatcher keys on its absence to distinguish "selections still pending" from "queue-order proposal awaiting confirmation". All four files share a quest cycle's lifecycle once they exist. `/mi-run` also writes a fifth stage-1 file, `reference.md` — a folder-link table connecting the cycle to its source `journal/` folders, and (as stage 2 materializes feature folders) to the `workflow-stream/` feature folders it produces; see "Folder linking" below. Subfolders from previous cycles are **never** modified or deleted — they form a permanent task archive that PMs and future inspectors can query (past task lists, summaries, queue rationales, the historical state of `progress.md`, and the folder links in `reference.md`). The top-level `quest/active.md` pointer file records which subfolder is currently active; path-resolution helpers in `scripts/internal/common.sh` (and the `scripts/quest.sh` wrapper) read it to map references like "the active todo-list.md" to the right subfolder.

**Folder linking.** `journal/<topic>/`, `quest/<slug>/`, and `workflow-stream/<feature>/` are tied together by ID, not by name:

- Each `journal/` topic folder and each `workflow-stream/` feature folder holds an `id.md` whose frontmatter `id` is a UUID identifying that *folder*. Because the ID lives in a marker file, the link survives the folder being renamed or moved.
- Each quest cycle subfolder holds a `reference.md` (its own `id` identifies the cycle): the `journal-refs` frontmatter array lists the `id.md` IDs of the journal folders the cycle was built from; the `feature-refs` array lists the feature folders it produced. Body bullets pair each ID with the folder's current name as a human-readable hint.
- `journal-refs` is written by `/mi-run` at stage 1; `feature-refs` is extended by `blueprints.sh ensure-current` (which calls `folder-id.sh link-feature`) as each feature's blueprint folder is created at stage 2.
- Reading a cycle's `reference.md`, you can reach every journal folder that seeded it and every feature folder it produced; resolve any ID back to its current path with `scripts/folder-id.sh resolve <id>`. `scripts/folder-id.sh` is the sole manager of `id.md` and `reference.md`.
3. **Workflow stream**: per-feature generated requirements, diagrams, and review artifacts.

#### Quest

When the inspector asks for a task to be completed (e.g. "Implement the payment module"), `/mi-run` creates a new per-cycle subfolder under `quest/` and the millwright generates these files inside it:

- **todo-list.md**: The todos should be categorized for each existing module and newcoming module and each item should have an id to be referenced by other documents.
  todo items may have 5 states: TODO(initial), PENDING(selected to be involved in workflow), IMPLEMENTING(currently in workflow), IMPLEMENTED(complete), CANCELED(removed from scope mid-cycle; preserved for audit). Each item also carries an optional **assignee** — the name of the inspector responsible for it — written in parentheses between the checkbox and the state word, e.g. `- [ ] (emin) TODO — PAY-001: capture webhook`. Assignees are optional on `[ ] TODO` lines (the inspector may pre-assign without selecting) but **mandatory** on every `[x]` line: `todo.sh pend-selected` rejects any `[x] TODO` that lacks an `(assignee)` tag and lists the offending items so the inspector can fix them before retrying.

  **State machine paths.** The normal cycle is `[ ] TODO → [x] PENDING → [x] IMPLEMENTING → [x] IMPLEMENTED`, where the inspector drives selection (TODO→PENDING via `pend-selected`) and the automated stages drive the rest (stage 3 promotes PENDING→IMPLEMENTING; stage 8 promotes IMPLEMENTING→IMPLEMENTED). Two additional paths support mid-cycle edits: `/mi-update-todo-list add <feature> IMPLEMENTING ...` creates a new item directly in the IMPLEMENTING state for a scope expansion discovered during brainstorming or review, and `/mi-update-todo-list cancel <item-id>` flips an item to CANCELED. CANCELED items are left alone by stage 8's bulk IMPLEMENTING→IMPLEMENTED sweep. The assignee tag is preserved verbatim through every state transition.

  Checkbox convention: `[ ]` = TODO (unselected); `[x]` = any selected state (PENDING/IMPLEMENTING/IMPLEMENTED/CANCELED) — the state word is the canonical source of truth for downstream progress.

  **Manual writes to `PENDING` and `IMPLEMENTED` are refused.** `PENDING` is only written by stage-1.5's `pend-selected` (the transition is an audit event tied to the inspector's bulk selection, not a state anyone writes ad-hoc). `IMPLEMENTED` is only written by stage-8 `mi-complete-workflow` (the commits-linkage invariant depends on it being promoted in one atomic pass with the active feature's scope).
- **summary.md**: generated structured digest of every journal sub-folder named to `/mi-run`. **Feature-indexed**: a `## Cross-cutting constraints` section, an `## Out-of-scope` section, and one `## Feature: <name>` section per feature so downstream stages can read only the active feature's section instead of the whole digest. Used by stage 2 (`mi-apply-impact`) as the requirements-generation source — it is the canonical bridge between raw journal content and the active cycle's blueprints.

#### progress.md (central workflow state)

A single file inside the active cycle's quest subfolder: `millwright-inspector/quest/<active-slug>/progress.md`. The `<active-slug>` segment is recorded in the top-level `quest/active.md` pointer; helpers (`scripts/quest.sh dir`, `mi_progress_file` in `common.sh`) resolve the path automatically. Co-generated at stage 1 with the cycle's `todo-list.md` and `summary.md` by `/mi-run`; the fourth cycle file, `queue-rationale.md`, lands at stage 1.5 via `/mi-continue` Step 2B. Once all four exist, they share the quest cycle's lifecycle. Earlier cycles' `progress.md` files (and the rest of their subfolder) are preserved permanently under their own slug subfolder. Populated by `mi-run` at stage 1; mutated by `mi-apply-impact` (stage 2, via `progress.sh activate`), `/mi-continue` / `/mi-plan-implementation` / review commands (runtime field writes), and `mi-complete-workflow` (stage 8, via `progress.sh finish`).

YAML frontmatter shape:

```yaml
---
id: <uuid>
todo-list-id: <uuid of the related todo-list.md>
queue: [notifications, audit-log]  # features still to run, in priority order
completed: [onboarding]             # features finalized via mi-complete-workflow
active:                             # null between workflows; populated while a feature is running
  feature: payments
  branch: feat/payments/webhook     # null until stage 3
  current-stage: 5                  # 2..8; stage 4 is conceptual and never persisted (3→5 atomic via advance-to)
  sub-flow: none                    # none | chain-in-progress | resuming | reviewing | manual-testing
  base-commit: a1b2c3d               # null until stage 3
  execution-mode: subagent-driven
  planning-mode: brainstorming      # 'brainstorming' | 'direct' | 'none' — set at stage 3 by mi-plan-implementation
  review-mode: none                 # 'brainstorming' | 'direct' | 'none' — stays 'none' until stage 6 fires; mi-review records the inspector's pick
  implementation-completed: true
  inspector-review-completed: false
  drift-check-completed: true                                    # optional — true once stage-4 drift prompt has been answered (Resume Handler Step 0 probe + Step 4 drift-gate split markers)
  history-baseline-version: 0                                    # optional — highest finalized blueprints/history/v[N] for active.feature at stage-3 entry; null/missing means "unknown" (probe disables itself)
  manual-test-state: none                                        # optional — none | running | complete | skipped (stage-5 manual-testing sub-flow)
  manual-test-failure-policy: none                               # optional — none | auto-seed | manual (how /mi-manual-test-run handles failures)
  clear-recommendations: []                                      # optional array — clear-point identifiers already crossed (e.g. stage-2-to-3, stage-5-to-6) so gates don't re-prompt
  worktree-path: /Users/me/repo                                  # captured at stage 2
  git-common-dir: /Users/me/repo/.git                            # shared across worktrees of one repo
  git-worktree-dir: /Users/me/repo/.git                          # per-worktree (== common-dir for the main worktree)
---
```

**Two-step activation lifecycle:**

- **Stage 1** — `mi-run` scaffolds progress.md with the ordered queue; `active` starts as `null`.
- **Stage 2** — `mi-apply-impact` calls `progress.sh activate`, which pops `queue[0]` into a fresh `active` block (current-stage=2, branch=null, all other runtime fields at defaults). Fails if `active` is already non-null.
- **Stages 2–8** — the runtime fields inside `active` are mutated in place as the workflow progresses. Only the `active` block is touched; `queue` and `completed` are unchanged during a feature's lifecycle.
- **Stage 8** — `mi-complete-workflow` calls `progress.sh finish`, which appends `active.feature` to `completed` and sets `active` back to `null`. The next `/mi-apply-impact` will activate `queue[0]` into a new `active` block.

On resume, the millwright reads this file to determine the current position: `active` null + non-empty queue means "next feature is waiting to be activated"; `active` populated means "feature X is at stage N with sub-flow Y"; `active` null + empty queue means "cycle complete".

#### Journal

General knowledge base, source of information.

Journal folder structure:

**journal**

- pricing-requirements-meeting (example)
  - meeting-transcript.txt (example)
  - notes.md (example)
  - devops-team-concerns.md (example)
- authentication-related-slack-conversation (example)
  - conversation.txt (example)

#### Workflow stream

This folder has 2 sub folders which are:

1. **blueprints**: folder with permanent content and a history mechanism. Has `current/` and `history/` subfolders. `current/` holds the live blueprint for the active feature:
   - `requirements.md` — Goals (this cycle), Planned (future cycles), Non-goals.
   - `config.md` — auto-block summarizing relevant skills under `.claude/skills/` and rules under `.claude/rules/` (≤ 10 entries / ≤ 2 lines each), plus `## Skills` / `## Rules` / `## Load on demand` tiers and a manual `## Inspector Additions` section the inspector fills with custom prompts. Stage 3 / stage 6 chains pull in skills/rules from here on demand.
   - `diagrams/` — use-case + sequence + optional class `.puml` files.
   - `primer.md` — compact stage-3 launch primer (active scope, Goals excerpt, journal context for the active feature, likely-relevant skills/rules). Written by `mi-plan-implementation` immediately before invoking the brainstorming chain and refreshed by `/mi-update-blueprint`. Rotates with the rest of `current/` so historical primers remain auditable.

   Inspector reviews these files at the stage-2 gate to confirm the requirements before brainstorming launches.

   `history/` keeps prior `current/` snapshots in subfolders named `v[number]`. Each rotation increments the number and writes a sibling `reason.md` recording why the rotation fired (`completion`, `manual`, `spec-update`, `re-spec-cascade`, `re-plan-cascade`). Rotations move every child of `current/` (`requirements.md`, `config.md`, `diagrams/`, `primer.md`) so the audit trail is complete; they fire on stage 8 (`mi-complete-workflow`) and on `/mi-update-blueprint`. **On `completion` rotations only, the entire live `implementation/` folder is also archived alongside as `history/v[N+1]/implementation/`** (see the `implementation` bullet below) — so a stage-8 history version is the single feature-version folder where every artifact (blueprint + findings + diagrams + change-summary + review-context + grounding-report) lives together.

2. **implementation**: a temporary folder used during implementation and review. Holds:
   - `diagrams/` — diagrams of the implemented behaviour of `base-commit..HEAD`, with pre-existing participants/classes/flows framed as shaded context next to the new functionality so the inspector sees the change inside one diagram set.
   - `inspector-review.md` — findings authored by the inspector at stage 5 and addressed by the chain in the stage-6 review session.
   - `review-context.md` — compact stage-6 review primer (active scope, goals, implemented surface, open-findings cheat sheet). Written by `/mi-review` and consumed by the brainstorming review session as the required first read alongside `inspector-review.md`.
   - `change-summary.md` — cached analysis of `base-commit..HEAD` (changed-files index, suspected flows, omitted paths). Shared by `/mi-update-blueprint` and `/mi-generate-implementation-diagrams` via `commits.sh change-summary-fresh` so the bounded codebase reads only happen once per commit range.
   - `grounding-report.md` — stage-2 codebase-grounding snapshot. Written by the `codebase-grounder` sub-agent during `/mi-apply-impact`'s Step A (Codebase-grounding pass) before the requirements body is composed. Carries per-item seam findings, pre-existing components, cycle-flavor classification, and an overall `seam-classification` (backend/frontend/mixed/infra) that drives Step C's optional-structural-diagram decision. Audit/debug state — not blueprint state. Lifecycle matches the rest of `implementation/`: archived alongside at stage 8, deleted on `/mi-abort-workflow`.

   At stage 8 (`mi-complete-workflow`) the whole `implementation/` folder is **archived** into `blueprints/history/v[N+1]/implementation/` (move, not delete) so findings, the review-context snapshot, change-summary, grounding-report, and implementation diagrams are preserved as part of the audit record. `/mi-abort-workflow` deletes the same files (an aborted cycle has no shipped work to archive).

3. **test**: a feature-permanent folder for the optional stage-5 manual-testing sub-flow. Holds:
   - `manual-test-plan.md` — optional stage-5 manual-testing plan (schema `manual-test-plan`). Generated by `/mi-manual-test-plan` when the inspector answers `y` to the Resume Step 7 manual-test offer; refused outside `current-stage=5`. On `--force` / `--discard-existing`, the prior plan is rotated into `manual-test-plan.history/<timestamp>/`.
   - `manual-test-results.md` — optional stage-5 manual-testing run record (schema `manual-test-results`, with `state ∈ {in-progress, complete}`, `current-scenario` cursor, `plan-id`, `seed-family-id`, `generated-in-activation`, counts). Written and updated by `/mi-manual-test-run` as the inspector walks the plan. Failed scenarios under `failure-policy=auto-seed` are converted into `### IR-NNN` findings via `review.sh upsert-manual-test-failure` (deterministic `seed-id: manual-test:<seed-family-id>:<scenario-id>` so re-runs are idempotent).
   - `manual-test-plan.history/<timestamp>/` — rotated prior plans on `--force` / `--discard-existing`.
   - `manual-test-results.history/<timestamp>/` — rotated prior-activation results (auto-rotated by `/mi-manual-test-plan` Step 1 and `/mi-manual-test-run` Branch A pre-normalization when the surviving results file belongs to a prior `activation-id`; see `docs/manual-testing-folder/plan.md` § 4.1).

   The `test/` folder is feature-permanent — it is NOT rotated into history at stage 8 and NOT deleted on `/mi-abort-workflow`. Cross-cycle reuse of the manual-test plan is intentional; the §4.1 cross-activation guard rotates only the per-run results into the sibling history directory. Note: `decisions.md` likewise lives at the **feature root** (`workflow-stream/<feature>/decisions.md`) and is similarly excluded from rotation.

Workflow stream folder structure:

**workflow-stream**

- [feature]
  - decisions.md                       # feature-scoped append-only decision log; NOT rotated
  - blueprints
    - history
      - v1 (example — completion rotation; carries the archived implementation/ alongside)
        - requirements.md
        - config.md
        - primer.md
        - reason.md
        - diagrams
          - use-case-auth.puml (example)
          - sequence-auth-login.puml (example)
        - implementation                   # archived from the live folder at stage 8 (manual-test artifacts NOT archived; they live in the sibling test/ folder)
          - inspector-review.md
          - review-context.md
          - change-summary.md
          - grounding-report.md
          - diagrams
            - use-case-auth.puml (example)
            - sequence-auth-login.puml (example)
      - v2 (example — manual / spec-update / cascade rotation; no implementation/ since the cycle wasn't completed)
        - requirements.md
        - config.md
        - primer.md
        - reason.md
        - diagrams
          - use-case-auth.puml (example)
          - sequence-auth-login.puml (example)
    - current
      - requirements.md
      - config.md
      - primer.md
      - diagrams
        - README.md
        - use-case-payments.puml (example)
        - sequence-payment-submit.puml (example)
        - sequence-payment-refund.puml (example)
        - class-payment-domain.puml (example — at most one optional structural diagram)
  - implementation
    - inspector-review.md
    - review-context.md
    - change-summary.md
    - grounding-report.md
    - diagrams
      - README.md
      - use-case-payments.puml (example)
      - sequence-payment-submit.puml (example)
  - test                                  # feature-permanent — survives stage 8 and abort
    - manual-test-plan.md                 # only if the manual-testing sub-flow ran
    - manual-test-results.md              # current-activation results (auto-rotated at next cycle's start)
    - manual-test-plan.history/           # rotated prior plans (--force / --discard-existing)
    - manual-test-results.history/        # rotated prior-activation results (§4.1)

## Persistence Model

Two rules govern how information flows through the workflow. They apply to every stage and every command.

### Rule 1 — Inputs live in files, not in conversation context

Every mi-command resolves its inputs from known file paths at runtime. Conversation context is treated as ephemeral — sessions break, context gets compacted, and a single workflow may span multiple days across multiple Claude Code sessions. Any inspector-provided value (branch name, approvals, `/mi-continue` signals) is captured the moment it arrives and persisted to disk.

Each command's `inputs:` list under "The Workflow Commands" is therefore a **file-path contract**, not a runtime parameter list. The inspector never passes values into commands; the millwright always reads them from canonical file locations:

- **`quest/active.md`** — top-level pointer file with frontmatter `slug:` (the active subfolder) and `status:` (active | archived | none). All quest helpers resolve through it.
- **`quest/<active-slug>/todo-list.md`** — todo items and their PENDING / IMPLEMENTING / IMPLEMENTED status.
- **`quest/<active-slug>/summary.md`** — structured summary of journal resources.
- **`quest/<active-slug>/progress.md`** — single workflow state file: `queue`, `completed`, and the nested `active` block carrying the currently-running feature's runtime state (branch, current-stage, sub-flow, base-commit, execution-mode, and `*-completed` flags). Co-located with `todo-list.md`, `summary.md`, and `queue-rationale.md` inside the same per-cycle subfolder; all four share the quest cycle's lifecycle. Schema documented in "The Workflow and the stages" below. The chain's spec/plan files (under `docs/superpowers/`) are intentionally NOT tracked here — those are the chain's own artefacts.
- **`quest/<active-slug>/queue-rationale.md`** — audit of the stage-1.5 dependency-ordering decision. Body captures `<dependent> → <dependency>` edges with short reasons under one or more `## Batch <N>` (level-2) headings — each batch records one ordering decision (the initial cycle-start ordering is Batch 1; mid-cycle additions land as Batch 2, 3, …). Top-level frontmatter `features:` is the **cumulative** ordered feature list across all confirmed batches (and the proposed order for the latest batch when `status: draft`); the dispatcher's between-features Row A relies on `features − progress.completed == progress.queue` exactly. Optional fields `status: draft | confirmed` and `batch: integer ≥ 1` describe the LATEST batch only and route the Pre-flight Handler — `draft` flips to the multi-batch confirmation row, `confirmed` (or absent ⇒ confirmed) routes Row A. Files without `## Batch` headings are treated as implicit Batch 1 for back-compat (Item 7 of the v11 progress-gap plan). Survives session breaks so the analysis isn't re-derived on resume; persists permanently under its slug subfolder once the cycle ends.
- **`workflow-stream/[feature]/decisions.md`** — feature-scoped append-only decision log under stage-named H2s. Excluded from blueprint history rotation; persists for the feature's lifetime (see `docs/clear-points/plan.md` §9.2).
- **`workflow-stream/[feature]/blueprints/current/`** — `requirements.md`, `config.md`, `diagrams/`, and (after stage 3 starts) `primer.md` for the active feature.
- **`workflow-stream/[feature]/implementation/`** — `inspector-review.md`, `review-context.md`, `change-summary.md`, `grounding-report.md`, and a `diagrams/` folder rendered from `base-commit..HEAD`. (Manual-test artifacts moved to a sibling feature-permanent `test/` folder — see below.)
- **`workflow-stream/[feature]/test/`** — feature-permanent home for the optional stage-5 manual-testing sub-flow. `manual-test-plan.md`, `manual-test-results.md`, `manual-test-plan.history/`, and `manual-test-results.history/`. Survives stage 8 and `/mi-abort-workflow`. See `docs/manual-testing-folder/plan.md`.
- **`quest/<active-slug>/context-ledger.md`** — per-cycle telemetry artifact (Phase 6.4); rows record stage / command / files / class / location / artifact for every context-heavy read. Append-only via `scripts/ledger.sh append`.

The only inspector inputs expected at runtime are:

1. The **journal folder list**, given to `mi-run` at stage 1 — one or more sub-folders of `journal/` whose contents seed the new cycle's `todo-list.md` and `summary.md` (inside `quest/<new-slug>/`). Stage 1 no longer takes a branch argument; the feature branch is declared **per feature** in `blueprints/current/config.md`'s `## GIT BRANCH` section at stage 2, and validated at stage 3 (`/mi-plan-implementation`). `main`/`master` are refused at stage 3. Optional: pass `--archive-active` when an old cycle's pointer is still active and you want to retire it (without finishing) so the new one can open.
2. **Marking PENDING items** in the active cycle's `todo-list.md` (under `quest/<active-slug>/`) followed by `/mi-continue` (twice — first to trigger promotion + dependency analysis + order proposal, second to confirm the proposed order). The Pre-flight Handler in `commands/mi-continue.md` carries out stage 1.5; the inspector no longer replies with free-form text here.
3. **`/mi-continue` after blueprints** at the end of stage 2 — types it after reviewing `blueprints/current/`. The Approve Handler in `commands/mi-continue.md` validates the blueprint files and auto-fires `/mi-plan-implementation`. The millwright must never infer this signal from anything else.
4. **`/mi-continue`** during stages 3–7 (in addition to its stage-1.5 and stage-2 uses), typed two or three times per feature: once after stage 3 (to trigger the post-chain resume handler), once after stage 5 (to trigger the inspector-review handler — which auto-completes if there are no findings, otherwise hands off to a review session), and one more time after stage 6 if findings were written (to trigger the post-review-session resume handler after the review session exits).
5. **Planning-mode / review-mode picks** during stages 3 and 6 — the inspector answers `brainstorming` or `direct` when `mi-plan-implementation` and `mi-review` prompt for the launch mode. The choice is persisted to `progress.md` (`active.planning-mode`, `active.review-mode`).
6. _(optional)_ **Edits to `inspector-review.md`** during stage 5 — findings (plain sentences or `### IR-NNN` blocks) if the inspector has concerns, empty file if they approve. The Inspector Handler in `commands/mi-continue.md` canonicalizes any plain-sentence findings into structured blocks before checking open-finding count.

Every other value comes from disk.

**Launcher commands (`mi-apply-impact`, `mi-plan-implementation`, `mi-complete-workflow`) are auto-invoked by the millwright on the gates above — the inspector does not type them during the happy path.** They remain invokable manually for recovery (after `/mi-abort-workflow`, or when `/mi-resume-workflow` explicitly recommends one).

### Rule 2 — Documents cross-link via UUIDs, with paths as navigation hints

Every .md file created or consumed by the workflow carries a YAML frontmatter info section. The canonical shape:

```yaml
---
id: 8f3a7b2c-1234-4a5b-9c6d-0e1f2a3b4c5d # UUID v4, generated once at document creation
contributors: [emin, ai-agent] # manual for journal docs, auto for generated docs
date: 2026-04-19 # YYYY-MM-DD

# Typed reference fields point at other documents' `id` values.
# The field name indicates the kind of document being referenced.
todo-list-id: 4c911d5e-1234-...
requirements-id: a2b3c4d5-6789-...
---
```

**Rules for IDs:**

- **Never reuse an ID.** When a document is rewritten (e.g., `requirements.md` regenerated for a new iteration), generate a fresh UUID. The old ID remains discoverable under `blueprints/history/v[N]/`.
- **Generate once, reference many times.** The `id` field is written once, on creation, by whichever command produces the document.
- **Don't leave dangling references.** When populating a reference field, the millwright verifies the target document exists and its `id` matches the written value.

This gives three properties for free: grep-based cross-reference discovery, rename-safe document identity, and an audit trail when combined with `blueprints/history/`.

### Rule 3 — Layered context loading

Stages that hand off to the brainstorming chain (stage 3 via `mi-plan-implementation`, stage 6 via `mi-review`) follow a **layered load** rather than passing every canonical file at full size on every entry. Each launcher writes a compact derived primer alongside the canonical files; the chain reads the primer first and only escalates to canonical files when a gap surfaces. Direct-mode runs of those same stages use the **same layered load** — the millwright reads the primer first and escalates as needed.

| Stage | Required first read | Canonical fallbacks (on demand) |
| --- | --- | --- |
| 3 — implementation (brainstorming or direct) | `blueprints/current/primer.md` | `requirements.md`, `config.md`, `summary.md` (active feature section), `todo-list.md` |
| 6 — review session (brainstorming or direct) | `implementation/review-context.md` + `implementation/inspector-review.md` | `requirements.md`, `config.md`, `summary.md` (active feature section), `blueprints/current/primer.md` |

Properties of derived primers:

- **Derived, not canonical.** They are snapshots; the canonical files remain the source of truth. If a primer falls behind, the canonical files win.
- **Overwritten on regeneration.** Each writer (`mi-plan-implementation`, `mi-update-blueprint` for `primer.md`; `mi-review` for `review-context.md`) overwrites in place.
- **Rotated or cleared with their parent folder.** `primer.md` rotates with `blueprints/current/` on stage 8 and `/mi-update-blueprint`. On completion, `review-context.md` and `change-summary.md` are archived with the live `implementation/` folder under the rotated blueprint history version; on abort, the live implementation artifacts are deleted.
- **Cross-refs stay live.** `review.sh sync-refs` re-points the `requirements-id` frontmatter on `inspector-review.md`, `review-context.md`, and `change-summary.md` after any mid-cycle blueprint rotation.

**Cache-keyed reuse.** Stage-4 analysis is shared across `mi-generate-implementation-diagrams` and `/mi-update-blueprint` via `implementation/change-summary.md`. The frontmatter pair `(base-commit, head)` is the cache key; `commits.sh change-summary-fresh <feature>` exits 0 (fresh — reuse), 1 (stale — regenerate), or 2 (missing — generate). The artifact carries the changed-files list and the bounded analysis (entrypoints, suspected flows, omitted paths) so neither consumer re-walks the codebase from scratch when the range hasn't moved.

`summary.md` itself is layered too: it is **feature-indexed** so a stage can read only `## Cross-cutting constraints` and `## Feature: <active>` instead of the whole digest. Other features' sections are reference-only for the active cycle.

When adding a new launcher command that hands off to a long-running chain, follow the same pattern: write a compact primer immediately before invoking the chain, and document the layered-load order in the primer text.

### Delegation guidance (sub-agent profiles)

As of v0.6.0, delegation is implemented through **first-class sub-agent profiles** under `agents/` (one Markdown file per profile, with YAML frontmatter `name`, `description`, `model`, `effort`, `tools`). Commands invoke profiles by name through the `Task` tool. The seven profiles below cover every approved delegation point in the workflow:

| Profile | Model / effort | Spawned by | Inputs | Output |
| --- | --- | --- | --- | --- |
| `journal-file-digester` | haiku / low | `mi-run` Step 2.5 Tier 1 | one oversized journal file (>100 KB) | digest in return body — read-only, no file writes |
| `journal-folder-digester` | haiku / medium | `mi-run` Step 2.5 Tier 2 | one journal subfolder (>5 files AND >40 KB total) | writes `<data_root>/quest/<active-slug>/.scratch/folder-digest-<folder>.md` |
| `dependency-mapper` | sonnet / medium | `mi-continue` Pre-flight Step 4c (stage 1.5) | queue of features (≥ 2) | 2–3 sentence ordering proposal in the return body — does NOT write files; main composes `queue-rationale.md` |
| `codebase-grounder` | sonnet / high | `mi-apply-impact` Step A / Phase 2.1 (stage 2) | in-scope todo IDs, folder allowlist, cycle-flavor rule order | writes `implementation/grounding-report.md` and sets `seam-classification` via `frontmatter.sh set`. ≤ 5 files inspected per todo |
| `blueprint-diagrammer` | sonnet / high | `mi-apply-impact` Step C (stage 2) | `requirements.md` Goals + the just-written grounding-report | writes `.puml` sources into `blueprints/current/diagrams/` (has the PlantUML MCP tools) |
| `implementation-analyst` | opus / high | `mi-generate-implementation-diagrams` Phase 3.1 (Resume Handler / `/mi-draw-diagrams`) | `base-commit..HEAD` diff, `blueprints/current/diagrams/` as seed | writes `implementation/change-summary.md` and re-renders `implementation/diagrams/`; only re-renders changed subjects |
| `review-iteration-runner` | opus / high | `mi-review` Step 3a, per iteration (stage 6 brainstorming mode) | open findings, scope-cascade rules | calls `review.sh set-status`. Has the `Skill` tool and chains into `brainstorming` / `writing-plans` for `re-spec` / `re-plan` cascades. Does NOT mutate `progress.md` |

Every profile returns per `docs/sub-agent-return-contract.md` with a ≤ 1k-token return body. Detailed evidence belongs in the artifact files named in `## Artifacts Written`, not in the chat reply.

**Do NOT delegate:**

- Workflow state mutations (`progress.sh`, `todo.sh`, `blueprints.sh`, `review.sh set-status`).
- Stage transitions, command dispatch, or final approvals.
- Anything that fits cleanly in the millwright's working context.

**Output contract.** Sub-agents must keep their reply ≤ 20 lines and follow this shape:

```
## Scope
<one short paragraph: what was inspected>

## Findings
- <short, source-linked bullet>

## Decisions / Assumptions
- <assumption with confidence>

## Artifacts Written
- <path>

## Main-Agent Action Needed
- <one concrete next step, or "none">
```

Detailed evidence belongs in the artifact files (the `## Artifacts Written` paths), not in the chat. The millwright reads the artifacts; the chat reply is just the routing slip.

**Capability and effort tiers.** Pick the smallest tier that can produce the artifact safely.

| Work type | Recommended tier |
| --- | --- |
| Mechanical extraction (file manifests, source maps, changed-file groupings) | Small/fast model, low effort |
| Bounded interpretation (feature summaries, queue dependencies, config relevance) | General reasoning model, medium effort |
| Cross-file analysis (`change-summary.md` body, finding clusters) | Strong code-analysis model, high effort |
| Architecture / security / re-spec assessments | Most capable model, high or extra-high effort |

**Anti-patterns:**

- Multiple sub-agents reading the same broad input. If two need the same context, run one and share its artifact.
- Returning full diffs, raw source excerpts, or whole-file contents in the chat reply.
- Mutating central workflow state from a sub-agent unless its assignment explicitly says so.
- Using the most capable tier for work a lightweight tier can do safely.

When delegation makes sense for a specific command, that command's documentation has a brief "Delegation (optional)" subsection naming the sub-agent task and the artifact it should produce.

### Diagram conventions

All PlantUML diagrams generated by the workflow follow the same rules, regardless of which command produces them (`mi-apply-impact` for requirements-level, `mi-generate-implementation-diagrams` for implementation-level):

- **Use-case diagram — mandatory, exactly one per feature.** Shows actors (users, external systems, cron jobs) and the feature's public capabilities. Filename: `use-case-<feature>.puml` (e.g., `use-case-payments.puml`).
- **Sequence diagrams — conditional, 2–3 per feature.** Generate one per significant end-to-end flow described in `requirements.md` (e.g., "user submits payment", "user cancels subscription"). The target is **2–3 sequence diagrams per feature**; rendering 1 is acceptable only when the feature genuinely has a single significant flow (e.g., a webhook handler with one entry point), and **never more than 3** — needing more than 3 is a signal the feature should be decomposed into sub-features, and the millwright should flag this to the inspector rather than rendering a fourth. Pick the most diff-worthy flows when more candidates exist than the cap allows; the rest are described in prose in `requirements.md`'s Goals. Filename: `sequence-<flow>.puml` (e.g., `sequence-payment-submit.puml`, `sequence-payment-refund.puml`).
- **One optional structural diagram — class OR component, never both.** A feature gets at most one structural diagram per cycle. The codebase-grounding pass at stage 2 (Step A in `docs/blueprint-regeneration.md`) classifies the seam as `backend | frontend | mixed | infra`; the optional slot fires only when the seam is `backend` or `mixed` AND the feature meets the content threshold below. Pick **whichever of class or component fits the work better** — not both:
  - **Class diagram (`class-<domain>.puml`)** — pick this when the feature introduces **3+ new domain classes/modules with non-trivial relationships**. "Non-trivial" means at least one of: inheritance, composition with shared lifecycle, bidirectional association, or a dependency graph with branching. Skip for simple CRUD on a single entity. Example: `class-payment-domain.puml` when the feature introduces `Payment`, `Refund`, `PaymentMethod`, `PaymentEvent` with associations between them.
  - **Component diagram (`component-<subject>.puml`)** — pick this when the feature introduces **3+ new components/modules with non-trivial dependencies** but isn't class-heavy enough for a class diagram. "Non-trivial dependencies" means at least one of: a fan-out, a fan-in, a cross-bucket dependency (e.g., backend service depending on a queue worker or external integration), or more than one inbound caller for the new component. A linear chain (`controller → service → repo`) is **not** non-trivial and does **not** warrant a component diagram regardless of how many modules it touches. Example: `component-payment-pipeline.puml` when the feature introduces a payment service that fans out to a retry-queue worker and an audit-log writer.
  - **One-sentence test (applies to both).** Before rendering, the millwright must be able to write a one-sentence purpose for the diagram beyond the filename. "Shows the new payment-webhook flow fan-out into the retry queue and the audit-log writer" passes; "shows the dependencies between the new service files" fails. If the millwright can't articulate the value, skip the optional slot entirely.
  - **Skip for pure UI / pure infra.** Frontend-only features (`seam = frontend`) and infra-only features (`seam = infra`) skip the optional slot — UI topology lives in the component file tree, infra topology lives in the manifest/config files; a diagram adds little.
- **File naming rules.**
  - Lowercase kebab-case.
  - `<type>-<subject>.puml` where type ∈ `{use-case, sequence, class, component}`.
  - One diagram per file. Do not combine multiple diagram types in a single `.puml`.
- **Scope alignment.** The two diagram locations show the same feature at two stages: requirements (`blueprints/current/diagrams/`) and implementation (`implementation/diagrams/`). The diagram set should share subject names across both locations — e.g., if `sequence-payment-submit.puml` exists in `blueprints/current/diagrams/`, it should also exist in `implementation/diagrams/` so the inspector can diff requirements-vs-implementation. Both stages express intent-vs-reality *inside* each diagram via the existing-vs-new framing convention (next bullet), so the inspector can read both folders with the same visual vocabulary; the comparison is then "did the new bits planned at stage 2 match the new bits implemented at stage 4?"
- **Existing-vs-new framing (applies to stage-2 blueprint diagrams AND stage-4 implementation diagrams).** Diagrams under `blueprints/current/diagrams/` and `implementation/diagrams/` distinguish pre-existing system elements from new functionality with one fixed two-colour convention — **blue (`#D6EAF8` fill, `#3498DB` strokes) for existing**, **green (`#D4EDDA` fill, `#27AE60` strokes) for new** — so the inspector reads every diagram the same way: pre-existing participants/classes sit inside a `box "Existing system" #D6EAF8 … end box` (sequence) or a tinted `package "Existing" #D6EAF8 { … }` (class/use-case); pre-existing arrows are `A -[#3498DB]-> B` with `#D6EAF8` activations. New elements use the matching green block (`box "New" #D4EDDA … end box` or `package "New" #D4EDDA { … }`), green arrows `C -[#27AE60]-> D`, and `#D4EDDA` activations — the default (uncoloured) skin is not used; both sides have explicit colour. Each diagram includes a small `legend right … endlegend` block documenting the convention. See `commands/mi-generate-implementation-diagrams.md` § "Existing-vs-new convention" for the canonical PlantUML snippets — both stages share these snippets verbatim. **The baseline differs by stage:** stage-2 (`mi-apply-impact`) uses the current HEAD codebase as the `existing` (blue) baseline and the seams sketched by Goals as `new` (green); stage-4 (`mi-generate-implementation-diagrams`) uses `active.base-commit` as `existing` (blue) and `base-commit..HEAD` as `new` (green). When stage-2's codebase-grounding pass found no relevant pre-existing seams (greenfield bootstrap), the blue `Existing` block is empty or omitted and the legend notes "no pre-existing context."
- **Semantic interpretation of the colours adapts to cycle flavor at stage 2.** The visual rules above are universal, but what blue / green *mean* shifts with the cycle flavor identified by the codebase-grounding pass (see `docs/blueprint-regeneration.md` Step A). For a `greenfield` Goals item: blue = pre-existing system context, green = the new code being added. For a `bugfix` item: blue = current (buggy) behaviour shown for diff legibility, green = corrected behaviour the cycle delivers. For an `improvement` item: blue = current capability, green = the upgraded / extended capability. The legend's right-column wording is rephrased per flavor; the colours and visual rules stay identical so cross-stage diffs work regardless of flavor.
- **Info section.** Each `.puml` file has no YAML (PlantUML's comment syntax differs), but the enclosing `diagrams/` folder has a sibling `README.md` with a YAML info section that carries the `requirements-id` back-reference and lists all diagrams in the folder.

### Branch contract

The git branch is owned by the inspector end-to-end. The mi-workflow never creates, deletes, or force-updates branches.

- **Creation.** The inspector creates and checks out the feature branch whenever it fits their rhythm — before `mi-run`, between stages 1 and 2, or just before approving blueprints. The branch is declared **per feature** in `blueprints/current/config.md`'s `## GIT BRANCH` section.
- **Pre-fill at stage 2.** When `mi-apply-impact` writes `config.md`, it populates the `## GIT BRANCH` section with the current HEAD if HEAD is on a non-trunk branch. Otherwise the section is left blank for the inspector to fill in manually.
- **Validation at stage 3.** `mi-plan-implementation` reads the `## GIT BRANCH` section and verifies:
  - exactly **one** branch line is present (multiple lines → the millwright prompts the inspector to pick one, since each feature has its own review scope);
  - the branch is not `main` or `master`;
  - the branch is the currently checked-out branch (`git rev-parse --abbrev-ref HEAD` matches).
  - If the section is empty, the millwright prompts the inspector in chat OR asks them to edit `config.md` and re-invoke — either path is valid.
- **One branch per feature.** Each feature in `progress.md`'s `queue` has its own `config.md` with its own `## GIT BRANCH`. Features can share a branch or use different branches freely — the plugin doesn't enforce sameness across the queue. If a feature genuinely needs coordinated work across multiple branches, the inspector should split it into two features in the todo list rather than listing multiple branches in one `## GIT BRANCH` section.
- **Persistence.** Once validated at stage 3, the primary branch is written to `progress.md`'s `active.branch` (which is `null` until then) and the `base-commit` is captured from HEAD into `active.base-commit`. Review scope (`/mi-review`) and diffs rely on both.

### Blueprint lifecycle: rotation and reason.md

`blueprints/current/` is a **living** snapshot of the active feature's design. It can be refreshed whenever the inspector's requirements shift — during brainstorming, during a review loop, or on manual demand. Every refresh is a rotation: the previous `current/` content moves into `blueprints/history/v[N+1]/` and a new `current/` is regenerated. **The regeneration source depends on the trigger:** stage 2's first-time generation (`mi-apply-impact`) is **quest-driven** and reads from the active cycle's `summary.md` (under `quest/<active-slug>/`) plus the codebase per `docs/blueprint-regeneration.md`. Mid-cycle refreshes (`/mi-update-blueprint`, also auto-fired by the stage-4 drift check) are **implementation-driven** — they read from `implementation/change-summary.md` plus targeted `git diff base-commit..HEAD` hunks; the journal and the cycle's quest files are intake artifacts that don't drift after stage 1.5 and are deliberately not consulted. Each history version carries a sibling `reason.md` that records why the rotation fired.

**Rotation triggers.**

| Trigger | Reason kind (`reason.md`) | Prompt / condition |
| --- | --- | --- |
| Stage 8 (`mi-complete-workflow`) — happy-path close-out of the feature. | `completion` | Always, no prompt. |
| `/mi-continue` post-chain (stage-4 resume) — brainstorming may have shifted scope. | `spec-update` (via `/mi-update-blueprint --reason-kind=spec-update`) | The resume handler prompts the inspector for a one-line reason; if supplied, it invokes `/mi-update-blueprint --reason-kind=spec-update <reason>`. The drift check itself does not read the chain's spec/plan files — the inspector is the authority on whether requirements drifted. (The separate abandoned-chain check in Resume Step 2.5 *does* read them read-only, but only to compose a resume primer, not to detect drift.) |
| Review-loop `re-spec` cascade (stage 6 inspector-review session). | `re-spec-cascade` | Unconditional — re-spec by definition means design-level change. |
| Review-loop `re-plan` cascade. | `re-plan-cascade` | Millwright prompts the inspector to confirm whether the regenerated plan also shifted requirements; rotates only on `yes`. No auto-detection (mi-workflow doesn't track plan paths). |
| `/mi-update-blueprint <reason>` — inspector-invoked manual refresh. | `manual` | The inspector-supplied reason becomes the `summary`. |

All rotations route through `scripts/blueprints.sh rotate <feature> --reason-kind <kind> --reason-summary <text>`, which moves `current/*` into `history/v[N+1]/` and writes `reason.md` using `templates/reason.md.tmpl` + `schemas/reason.schema.yaml`. **The rotation is resumable** — it follows a `.partial.tmp → .partial → vN` flow (Step 1 creates `vN.partial.tmp/`, Step 2 writes + validates `reason.md` inside it, Step 3 atomically renames `.tmp → .partial` to publish recoverable intent, Step 4 moves `current/*` into `.partial/`, Step 5 atomically renames `.partial → vN` to finalize), so a session break between any two file-system steps leaves a recoverable state. On re-entry, `rotate` recovers a single `.partial` only when its `reason.md.kind` matches the requested `--reason-kind`; the cross-product STOP refuses when more than one partial exists. `blueprints.sh resume-partial --expected-kind <kind>` is the kind-asserting helper used by `mi-complete-workflow`'s Branch 0a. Content regeneration after rotation differs by caller: `mi-apply-impact` (stage 2, no implementation yet) follows `docs/blueprint-regeneration.md` — the **quest-driven runbook** (journal is consulted only at stage 1; stage 2 reads the active cycle's `summary.md` under `quest/<active-slug>/` as the digest, not `journal/` directly); `/mi-update-blueprint` (mid-cycle, implementation exists) uses its own inline logic that reads from the codebase + the just-rotated history version (see `commands/mi-update-blueprint.md` Step 4). Stage-3+ callers (`/mi-update-blueprint`, the Resume Handler probe, the `/mi-complete-workflow` rotate preflight) gate on `blueprints.sh check-current --require-primer "$feature"` returning 0 (complete-core + valid `primer.md` matching `requirements.md`'s id) so a partial regeneration cannot slip into the next stage. Mid-cycle callers must invoke `blueprints.sh preserve-inspector-sections` after regeneration to splice `## GIT BRANCH` and `## Inspector Additions` forward from history; the regeneration logic does not preserve them by itself.

**Review-file sync on mid-loop rotation.** When a rotation fires while `inspector-review.md` already exists (i.e. during a review session), the file's `requirements-id` frontmatter is updated to point at the newly-regenerated `requirements.md`. This keeps the in-flight brainstorming review session pointing at live scope rather than the rotated-away version. `scripts/review.sh sync-refs <feature>` is the helper; it's a no-op when the review file is absent.

**Scope of `requirements.md.todo-item-ids`.** The array captures the todo items that **initiated** the current cycle — the PENDING set at stage 2 (or the IMPLEMENTING set at the time of any mid-cycle regeneration). It does **not** grow to include every concern surfaced during brainstorming or review; scope expansions land in the requirements body and are tracked via `/mi-update-todo-list add <feature> IMPLEMENTING ...` if they warrant a new todo id. Similarly, the active cycle's `todo-list.md` (under `quest/<active-slug>/`) is independent of blueprint rotation — rotation never touches todos, and `/mi-update-todo-list` never rotates the blueprint. The two are deliberately decoupled: `todo-list.md` is "what the inspector asked for"; `blueprints/current/` is "what the chain figured out we need to build to deliver those asks."

### Review File Schema

The single review file `inspector-review.md` follows the schema below. The inspector fills it in during stage 5; the brainstorming review session iterates against it during the stage-6 loop (which runs isolated from mi-workflow).

Review is implementation-only: findings compare the commits in `base-commit..HEAD` against `requirements.md` (the millwright-owned contract). The chain's plan / spec files under `docs/superpowers/` are not part of the review surface — they're the chain's internal artefacts and are regenerated by the chain itself when a `re-plan` / `re-spec` cascade fires.

**File shape:**

```markdown
---
id: <uuid>
requirements-id: <uuid of related requirements.md>
---

## Implementation Review

### IR-001 — <one-line summary>

- **severity**: blocker | major | minor
- **scope**: fix | re-implement | re-plan | re-spec
- **status**: open | fixed | wontfix
- **details**: |
  Multi-line context. What was reviewed, what went wrong, which file or commit
  is implicated. Reference other findings by id (e.g., "related to IR-003").
- **fix-note**: populated when status transitions to `fixed` or `wontfix`, otherwise empty.

### IR-002 — ...

## Iteration 2

(new findings discovered after the first fix pass, nested under `## Iteration N`. Added only on the second pass onward.)
```

**ID rules:**

- Finding ids are `IR-NNN`, zero-padded to three digits, monotonically incrementing.
- IDs are **never reused** within a workflow.
- IDs are stable across iterations: a fix that lands in iteration 2 is still tagged with the original IR-005 id; its `status` flips from `open` to `fixed`, and `fix-note` explains what changed.

**Severity rules:**

- **blocker**: highest-impact finding; should normally be fixed before approval or explicitly deferred by the inspector.
- **major**: material issue that should be fixed or explicitly deferred by the inspector.
- **minor**: low-impact issue; may be fixed, deferred, or marked `wontfix`.

Severity is advisory metadata, not a hard workflow gate. If any findings remain `open` after the review session exits, the Review-Resume handler prompts the inspector to either proceed with them deferred, relaunch/continue the review work, or abort. Deferred open findings are archived with the implementation record on completion.

**Scope rules:**

`scope` classifies the smallest rework that genuinely addresses the finding. It controls which step of the brainstorming → writing-plans → executing-plans chain the millwright re-enters when applying fixes. The millwright picks the value at review time; for inspector-written findings left blank, the millwright classifies before acting.

- **fix** — the finding is addressed by a patch to existing code (typo, missing edge case, minor logic, small refactor, test gap). No chain re-entry.
- **re-implement** — the plan is sound but the code diverged; the millwright re-invokes `executing-plans` (or `subagent-driven-development`) to rewrite the affected sections against the existing plan.
- **re-plan** — the chain's plan was wrong or incomplete (missed task, wrong ordering, misconceived task); the millwright re-invokes `writing-plans` with a concern bundle, which cascades through `executing-plans`. The chain regenerates the plan internally; mi-workflow does not track plan paths.
- **re-spec** — the underlying design is wrong (wrong abstraction, wrong approach, wrong API shape); the millwright re-invokes `brainstorming`, which cascades through `writing-plans` and `executing-plans`. The chain regenerates its own spec/plan internally and produces fresh commits. Use sparingly: this invalidates the current implementation. Before triggering, the millwright surfaces a short "scope of impact" summary to the inspector so the decision is visible.

**Priority for acting on open findings (tier-0 wins):**

The brainstorming review session (launched during stage 6 by `/mi-review`, which advances 5→6 before invoking the Skill) addresses findings in **descending order of chain impact**, because each higher tier supersedes the lower ones in the same pass:

1. **re-spec** findings first — one re-entry produces a fresh spec, plan, and implementation; all previously-open lower-scope findings are marked `fixed` with `fix-note: "superseded by re-spec at iteration N"` since the code that drew them no longer exists.
2. **re-plan** findings next, against the current spec. Cascades through executing-plans; existing re-implement/fix findings are similarly superseded.
3. **re-implement** findings, against the current plan. Existing fix findings may still apply or be superseded depending on what sections were rewritten — the next review iteration resolves the ambiguity.
4. **fix** findings are patched individually last.

The brainstorming session controls this dispatch internally; mi-workflow does not encode the cascade. Finding ids keep incrementing monotonically across loop iterations within `inspector-review.md`.

**Status transitions:**

- `open` → `fixed`: the millwright (or inspector) addressed the finding; `fix-note` describes how.
- `open` → `wontfix`: the finding is declined with justification in `fix-note`. Conventionally the inspector signs off on `wontfix` for blocker/major findings, but this is advisory — `review.sh set-status` does not gate on severity.
- `fixed` / `wontfix` → `open`: only re-opens if a later iteration surfaces regression.

**Empty / skeleton state:**

When the millwright first creates `inspector-review.md` at the end of stage 4, it writes only the frontmatter + an empty `## Implementation Review` section (no finding blocks). The stage-5 `/mi-continue` handler treats the presence of at least one `### IR-NNN` block as "has findings"; absence means "approved with no findings."

### Skill references

Skill names in this document (e.g., `brainstorming`, `writing-plans`, `executing-plans`, `subagent-driven-development`, `finishing-a-development-branch`) must be available to the session. Two equivalent sources are accepted:

- the `superpowers` plugin installed in the host Claude Code session (resolves names like `superpowers:brainstorming`), or
- local `SKILL.md` files under `.claude/skills/<name>/`.

The mi-workflow treats these sources as interchangeable and uses whichever naming the host session surfaces. `/mi-doctor` verifies each of the five skill names is resolvable via at least one source on first run and prints the exact `/plugin marketplace add` + `/plugin install` slash commands (or the `.claude/skills/` drop-in path) when one is missing. These skills are **not** declared as a Claude Code plugin dependency in `plugin.json` — that would block millwright-inspector-development-machine from loading before `/mi-doctor` could guide the install.

### Schemas, scripts, templates (overview)

The plugin ships fourteen JSON-Schema-as-YAML files under `schemas/`, twelve scripts under `scripts/` (plus `scripts/internal/` helpers), and twelve frontmatter templates under `templates/`. Frontmatter on every workflow `.md` file is validated by the PostToolUse hook (`hooks/validate-on-write.sh`) against the matching schema; a write that produces invalid frontmatter blocks the turn until the inspector fixes it.

- **Schemas** (one per artifact type): `active-quest`, `change-summary`, `config`, `context-ledger`, `decisions`, `diagrams-readme-blueprint`, `diagrams-readme-implementation`, `folder-id`, `grounding-report`, `manual-test-plan`, `manual-test-results`, `primer`, `progress`, `queue-rationale`, `reason`, `reference`, `requirements`, `review-context`, `review-file`, `summary`, `todo-list`. The `folder-id` schema validates the `id.md` folder-identity markers in `journal/` topic folders and `workflow-stream/` feature folders; the `reference` schema validates `quest/<active-slug>/reference.md` (the `journal-refs` / `feature-refs` folder-link table). The `progress` schema's `active` block carries the optional drift markers (`drift-check-completed`, `history-baseline-version`), the optional manual-testing fields (`manual-test-state ∈ {none, running, complete, skipped}`, `manual-test-failure-policy ∈ {none, auto-seed, manual}`), the optional `clear-recommendations` array (within-feature clear-point gates that have already fired — `stage-2-to-3` / `stage-5-to-6`), and the immutable worktree-fingerprint trio (`worktree-path`, `git-common-dir`, `git-worktree-dir`); `sub-flow` admits a fifth value `manual-testing` while a stage-5 manual-test run is in progress. The `queue-rationale` schema supports the multi-batch shape (`status: draft|confirmed`, `batch: integer`, cumulative `features:`). The two `diagrams-readme-*` schemas validate the sibling READMEs under `blueprints/current/diagrams/` and `implementation/diagrams/` respectively. The `grounding-report` schema validates the stage-2 codebase-grounding snapshot under `implementation/grounding-report.md`. The `manual-test-plan` schema validates the optional stage-5 plan; the `manual-test-results` schema validates the run record (with `state ∈ {in-progress, complete}`, `current-scenario` cursor, `plan-id`, `seed-family-id`, counts). The `context-ledger` schema validates the per-cycle telemetry artifact at `quest/<active-slug>/context-ledger.md` (Phase 6.4). The `decisions` schema (UUIDv4-only `id` pattern — stricter than other schemas) validates the feature-scoped verbal-decision log at `workflow-stream/<feature>/decisions.md` (excluded from history rotation; persists for the feature's lifetime — see `docs/clear-points/plan.md` §9.2).
- **Scripts** (deeper detail in `commands/*.md`): `uuid.sh` (UUID v4 minting — sole authority), `frontmatter.sh` (read/write/init/validate YAML frontmatter), `progress.sh` (mutates the active cycle's `progress.md`; key subcommands beyond the obvious are `advance-to <expected> <target> [--set k=v]...` for atomic skip-transitions and `check-worktree` for the worktree-fingerprint pre-flight), `todo.sh` (state-machine-aware todo edits), `quest.sh` (active-pointer manager — `start <slug> [<journal-folder>...]`, `end`, `dir`, `current`, `list`), `folder-id.sh` (folder-link manager — `ensure`/`get`/`resolve`/`list` for `id.md` markers, `init-reference` writes the cycle's `reference.md` at stage 1, `link-feature` appends a feature folder to it at stage 2), `data-root.sh` (resolves `MI_DATA_ROOT` → `CLAUDE_PLUGIN_USER_CONFIG_data_root` → `${PWD}/millwright-inspector`), `blueprints.sh` (`ensure-current`, `rotate`, `resume-partial`, `preserve-inspector-sections`, `check-current [--require-primer]`, `branch-status`), `review.sh` (`inspector-review.md` operations including `canonicalize`, `strip-freeform`, `find-by-seed-id`, `find-by-seed-id-family`, and `upsert-manual-test-failure` — the single owner of manual-test → review-file mutations), `commits.sh` (`base-commit..HEAD` queries + cache-keyed `change-summary-fresh`), `bundle.sh` (engine for `/mi-export-bundle`; `export` is the only subcommand in v1 — extracts the active feature's current state into `tmp/bundles/<feature>-stage<N>-<timestamp>.md`), `info-bar.sh` (pull-only Claude Code `statusLine` renderer — NOT a hook; reads stdin JSON, parses `quest/active.md` + `progress.md` once, prints one line, exits 0; ≤100 ms hot-path target), `ledger.sh` (manages `quest/<active-slug>/context-ledger.md`; two subcommands: `init` and `append <stage> <command> <files> <class> <location> <artifact>` — append failures warn but do NOT block parent commands), `ingest.sh` (non-text journal conversion), `doctor.sh` (dependency detection + `--preflight` mode), `migrate-diagrams-readme.sh` (one-shot back-fill of `requirements-id` / `id` into legacy diagram READMEs).
- **Templates** (mustache-style, rendered by `frontmatter.sh init`): `active-quest`, `change-summary`, `config`, `context-ledger`, `decisions`, `grounding-report`, `manual-test-plan`, `manual-test-results`, `inspector-review`, `primer`, `progress`, `queue-rationale`, `reason`, `requirements`, `review-context`, `sub-agent-return`, `summary`, `todo-list` — each schema-bound template pairs with its same-named schema.

For per-field detail and design rationale, see `docs/project-report.md` §7 ("Technical underpinnings").

## Roles × Plugin Interaction

A condensed map of who interacts with which plugin surface, why, and at which stage. Detailed semantics for each command live in "The Workflow Commands" below; this section is for orientation.

**Actors:**

- **Inspector** — the human. Authors journal content, marks selections, approves blueprints, picks planning-mode and review-mode, writes findings, types every `/mi-continue`. Owns the git branch end-to-end.
- **Millwright** — the AI agent (Claude Code main session). Generates every artifact under `quest/`, `blueprints/current/`, and `implementation/`. Dispatches inside `/mi-continue`. Auto-fires launcher commands at each gate.
- **Plugin internals** — the PostToolUse frontmatter validator, the auto-fired launcher commands (`mi-apply-impact`, `mi-plan-implementation`, `mi-review`, `mi-draw-diagrams`, `mi-complete-workflow`), and the `plantuml-mcp-server` MCP integration.

**Touchpoint map** (chronological by stage):

| Stage | Actor | Surface | Action |
| ---: | --- | --- | --- |
| 0 | Inspector | `journal/<topic>/*.md` `.txt` (and `/mi-ingest` for non-text) | Authors raw inputs; sets `contributors:` + `date:` frontmatter on `.md`. |
| setup | Inspector | `/mi-init`, `/mi-doctor`, `/mi-ingest` | One-prompt setup wizard, detailed dep check, non-text ingestion. |
| 1 | Inspector | `/mi-run <folder1> [<folder2> ...]` | Triggers quest generation. Creates a fresh per-cycle subfolder under `quest/`. No branch arg. |
| 1 | Millwright | `quest/<active-slug>/{todo-list, summary, progress}.md` + `quest/active.md` (pointer) | Writes three of the four quest files into the new per-cycle subfolder (todo-list, summary, progress); updates the top-level pointer; sets `active=null`. The fourth file, `queue-rationale.md`, is written at stage 1.5 by `/mi-continue` Step 2B. |
| 1.5 | Inspector | active cycle's `todo-list.md` (under `quest/<active-slug>/`) | Marks `[x]` and adds `(assignee)` tag for items in scope. |
| 1.5 | Inspector | `/mi-continue` ×2 | First call: Pre-flight Step 2A (`pend-selected`, propose order). Second call: Step 2B (write the cycle's `queue-rationale.md` — implicit Batch 1 with cumulative `features:`; top-level `status` may be omitted because missing means confirmed — reorder, auto-fire `/mi-apply-impact`). For mid-cycle re-entry, Step 2A appends a `## Batch <N+1>` body and publishes top-level `batch=N+1`/`status=draft`/cumulative `features` in one write; the next `/mi-continue` routes through the draft-confirmation row. |
| between features | Pre-flight Handler (auto) | `/mi-continue` Row A | Detects `(queue-rationale.md.features − progress.completed) == progress.queue` and auto-fires `/mi-apply-impact` for `queue[0]` without prompting. |
| post-finish housekeeping | Pre-flight Handler (auto) | `/mi-continue` Row B | Detects an interrupted Stage-8 housekeeping (rotation done, `progress.sh finish` ran, but Step 7 didn't complete) and auto-fires `/mi-complete-workflow` Branch I. |
| stage-7 finalize | Active-row Handler (auto) | `/mi-continue` | When `active.current-stage == 7` (no-findings or post-review path landed), auto-fires `/mi-complete-workflow` (idempotent via Branch II if re-entered after a partial finalize). |
| 2 | Millwright (auto) | `/mi-apply-impact` | `progress.sh activate`, generate `blueprints/current/`. Pre-fills `## GIT BRANCH` from HEAD only when HEAD is non-trunk; otherwise leaves the section blank for the inspector to fill in. |
| 2 | Inspector | `blueprints/current/{requirements.md, config.md, diagrams/}` | Reviews. May edit `## Inspector Additions` and `## GIT BRANCH`. |
| 2 → 3 | Inspector | `/mi-continue` | Approve Handler: Step 1 sanity-check; **Step 2 `stage-2-to-3` clear-point gate** (recommends `/clear`; identifier recorded in `progress.md.active.clear-recommendations`); Step 3 auto-fires `/mi-plan-implementation`. |
| 3 | Millwright (auto) | `/mi-plan-implementation` | PENDING→IMPLEMENTING; captures `base-commit`; validates branch; writes `primer.md`; asks for `planning-mode`. |
| 3 | Inspector | Chat reply (`brainstorming` \| `direct`) | Picks planning-mode; persisted to `progress.md`. |
| 3 | Inspector + chain (brainstorming) OR Millwright (direct) | Codebase, `primer.md`, optional canonical fallbacks | Implements the feature. Commits land on the active branch. |
| 3 → 5 (atomic) | Inspector | `/mi-continue` | Resume Handler: Step 0 drift-completion probe; verifies commits (zero-commit branch offers `retry-launch` / `direct-empty` / `abort`); idempotent flag writes; optional `/mi-update-blueprint --reason-kind=spec-update` drift fire (drift prompt accepts `<reason>` / `auto` / `continue`); auto-fires `/mi-draw-diagrams`; creates review skeleton; **Step 7 manual-test offer** (`y/n`; on `y` auto-fires `/mi-manual-test-plan --from-resume` then `/mi-manual-test-run` under `sub-flow=manual-testing`). Final write is atomic `advance-to 3 5` — `current-stage` skips 4 entirely. |
| (Resume Handler) | Millwright (auto) | `/mi-draw-diagrams` (= `mi-generate-implementation-diagrams`) | Renders implementation diagrams with blue/green existing-vs-new framing into `implementation/diagrams/`. Uses `change-summary.md` cache. |
| 5 (sub-flow=manual-testing, optional) | Millwright (auto) → Inspector | `/mi-manual-test-plan`, `/mi-manual-test-run` | Generates `test/manual-test-plan.md`; walks scenarios capturing pass/fail into `test/manual-test-results.md`; under `failure-policy=auto-seed`, seeds `### IR-NNN` findings via `review.sh upsert-manual-test-failure` with deterministic `seed-id: manual-test:<seed-family-id>:<scenario-id>`. Re-entry while `current-stage=5, sub-flow=manual-testing` routes to the **Manual-Test-Resume Handler** (above the catch-all `5 | (any)` row), which re-fires `/mi-manual-test-run` (Branch A) or `--seed-only` (Branch B) for crash recovery. The `test/` folder is feature-permanent and survives stage 8 + abort. |
| 5 | Inspector | `implementation/inspector-review.md` | Writes findings as plain sentences or `### IR-NNN` blocks. Empty file = approval. |
| 5 → 7 (no findings) | Inspector | `/mi-continue` | Inspector Handler canonicalizes free-form findings; if none open, **prompts y/n confirmation** before auto-firing `/mi-complete-workflow`. On `n`, stops without advancing — `current-stage` stays at 5. |
| 5 → 6 (with findings) | Inspector | `/mi-continue` | Inspector Handler auto-fires `/mi-review`; control returns to inspector. |
| 6 | Millwright (auto) | `/mi-review` | **Step 0 — `stage-5-to-6` clear-point gate** (recommends `/clear`; identifier recorded in `progress.md.active.clear-recommendations`); composes `review-context.md`; asks for `review-mode`; dispatches to brainstorming session (via the `review-iteration-runner` sub-agent) or direct loop. |
| 6 | Inspector | Chat reply (`brainstorming` \| `direct`), then drives the session | Addresses findings via chain or directly; ends with `approve`. |
| 6 → 7 → 8 | Inspector | `/mi-continue` | Review-Resume Handler: check/defer open findings (with the same y/n completion confirmation as the no-findings stage-5 path), offer a diagram refresh when review-loop commits exist, then atomically advance 6→7 and auto-fire `/mi-complete-workflow`. |
| 8 | Millwright (auto) | `/mi-complete-workflow` | IMPLEMENTING → IMPLEMENTED, populate `commits:`, rotate blueprint, **archive `implementation/` artifacts into the newly rotated `blueprints/history/v[N+1]/implementation/`** (preserving findings, review-context, change-summary, grounding-report, and diagrams; `decisions.md` lives at the feature root and is not rotated; the `test/` folder is feature-permanent and is likewise not rotated), `progress.sh finish`. Step 7 housekeeping: when the queue is non-empty, fires the **feature-A→feature-B clear-point gate** (recommends `/clear` and halts before auto-firing `/mi-apply-impact` for the next feature; one-shot, no tracking flag); else loops to TODO marks or recommends `/mi-run`. |
| recovery | Inspector | `/mi-abort-workflow [--drop-feature=requeue]`, `/mi-resume-workflow`, `/mi-update-blueprint <reason>`, `/mi-update-todo-list <subcmd>` | Safe-cancel, state diagnosis, manual blueprint refresh, manual todo edits. (`--drop-feature=completed` was removed; use `/mi-complete-workflow` for shipped-feature finalization.) |
| any active | Inspector | `/mi-export-bundle` | Extracts a single self-contained markdown bundle of the active feature's current state (requirements, scope, decisions, codebase-context audit, implementation summary, changed-files, manual-test results, open findings) into `tmp/bundles/<feature>-stage<N>-<timestamp>.md` for pasting into a fresh agent. Refuses on no active cycle / no active feature / worktree fingerprint mismatch. |
| once | Inspector | `/mi-init-status-bar [--user\|--project-shared] [--plugin-root <abs>]` | Wires the pull-only `statusLine` renderer (`scripts/info-bar.sh`): writes `.claude/mi-stage-info-bar.sh` (with the plugin's absolute path baked in — Claude Code does NOT expand `$CLAUDE_PLUGIN_ROOT` inside `statusLine.command`) plus a `statusLine.command` block in settings.json. Default target: project-local `.claude/settings.local.json`. Idempotent. |
| always | Plugin internals | `hooks/validate-on-write.sh` (PostToolUse) | Validates frontmatter on every Write/Edit to a workflow `.md`; blocks the turn on schema failure. No-op outside data root. |
| 2, Resume Handler | Plugin internals | `plantuml-mcp-server` (MCP) | Renders `.puml` diagram sources to images. |
| optional | Plugin internals | `rtk` (companion), `docling` (companion) | Token-saving shell-output filter; document → markdown converter. Detected by `/mi-doctor`; never required. |

**Key isolation points:**

- The stage-3 brainstorming chain and the stage-6 brainstorming review session both run **isolated from mi-workflow**. Mi-workflow only re-engages when the inspector types `/mi-continue` after the session exits.
- Mi-workflow **never writes** to the chain's spec/plan files under `docs/superpowers/`, and in the happy path **never reads** them either — the commit range `base-commit..HEAD` is the canonical implementation contract. The single read exception is `/mi-continue`'s abandoned-chain recovery branch (Resume Step 2.5): when the inspector reports an interrupted stage-3 run, the handler reads the plan + spec **read-only** to compose a resume primer for re-launching the chain. All writes to `docs/superpowers/` remain the chain's domain.
- The git branch is owned by the inspector end-to-end. Mi-workflow never creates, deletes, or force-updates branches.

## The Workflow and the stages

Below is the description of the workflow. The central `progress.md` file (schema shown above under "progress.md (central workflow state)") tracks workflow progression so execution can resume after a session break, and records hand-off metadata whenever the millwright yields control to an external skill chain (brainstorming → writing-plans → executing-plans / subagent-driven-development).

The `active` block inside `progress.md` holds per-cycle runtime state — null between workflows, populated between stages 2 and 8. Its fields:

- **feature**: name of the feature/module this cycle targets (mirrors the `[feature]` segment of the `workflow-stream/` folder path). Written by `progress.sh activate` when stage 2 fires.
- **branch**: git branch name that carries the implementation commits. Initialized to `null` by activate (branch isn't known yet at stage 2). Written by `mi-plan-implementation` at stage 3 after it parses and validates `blueprints/current/config.md`'s `## GIT BRANCH` section.
- **current-stage**: integer 2–8 (active block only exists within this range). Advances through `progress.sh advance`.
- **sub-flow**: one of `none | chain-in-progress | resuming | reviewing | manual-testing`. Set to `chain-in-progress` by `mi-plan-implementation` immediately before invoking the brainstorming skill at stage 3, and reset to `none` after the inspector types `/mi-continue` and the millwright has successfully consumed the chain's outputs. Set to `reviewing` by `/mi-review` when it launches the stage-6 brainstorming review session, and reset to `none` by the post-review-session resume handler in `/mi-continue` after the inspector signals the session ended. Value `resuming` is set during the stage-4 `/mi-continue` handler. Value `manual-testing` is set by `/mi-manual-test-plan` and held while a stage-5 manual-test run is in progress (cleared by `/mi-manual-test-run` when the run reaches `complete`/`skipped`). The millwright never inspects sub-flow _during_ the chain — both the stage-3 chain and the stage-6 review session run in fully isolated Claude Code session flows.
- **base-commit**: git SHA captured at the start of stage 3 (before brainstorming is invoked). Used later by `/mi-review`, `mi-generate-implementation-diagrams`, and `mi-complete-workflow` to scope the implementation diff to `base-commit..HEAD`. The chain's spec/plan files are intentionally NOT tracked in `progress.md` — those are the chain's own artefacts; mi-workflow reads only the commit range.
- **execution-mode**: one of `subagent-driven | inline | none`. Recorded when the inspector picks an execution option inside writing-plans (only meaningful for `planning-mode: brainstorming`; `direct` mode does not enter writing-plans).
- **planning-mode**: one of `brainstorming | direct | none`. Set by `mi-plan-implementation` at stage 3 when it asks the inspector to pick a launch mode. `brainstorming` invokes the brainstorming → writing-plans → executing-plans chain in an isolated session (the legacy default). `direct` skips the Skill — the millwright reads `primer.md` and implements in the main session. `none` until the choice is made.
- **review-mode**: one of `brainstorming | direct | none`. Set by `mi-review` at stage 6 when it asks the inspector to pick a review-loop mode. `brainstorming` invokes a brainstorming review session (isolated). `direct` keeps the review loop in the main session: the millwright addresses each finding directly. `none` until the choice is made.
- **implementation-completed**: boolean. True once the execution sub-flow exits and implementation commits are on the branch.
- **inspector-review-completed**: boolean. True once the stage-6 review session exits with inspector approval and no new findings added (set by the post-review-session resume handler in `/mi-continue`), or set directly at stage 5 when the inspector approved with no findings.
- **drift-check-completed**: optional boolean. True once the Resume Handler's stage-4 drift prompt has been answered — either "continue" (skip drift) or a reason that fed `/mi-update-blueprint --reason-kind=spec-update`. Persisted as a split marker write: the Resume Handler's Step 0 probe writes it when it detects a successful `spec-update` rotation whose marker was lost to a session break, AND the drift gate at Step 4 writes it after a fresh decision. Optional — missing means false. `/mi-abort-workflow`'s reset intentionally drops this field so the next stage-3 entry starts with a fresh state. Eliminates the failure mode where a session break between rotation and marker-write would re-fire the drift prompt.
- **history-baseline-version**: optional integer. Highest finalized `blueprints/history/v[N]` index for `active.feature` at stage-3 entry. Captured by `/mi-plan-implementation` Step 3 alongside `base-commit` and preserved across re-entries (the re-entry guard skips Step 3 entirely). The Resume Handler's drift-completion probe walks `v[K] > baseline` to distinguish this-cycle `spec-update` rotations from prior-cycle ones. Optional — missing/null means "unknown": the probe captures a fresh baseline and disables itself for that invocation rather than defaulting to 0 (which would mistake old `spec-update` history for this-cycle drift). `/mi-abort-workflow`'s reset intentionally drops this field.
- **manual-test-state**: optional `none | running | complete | skipped`. Tracks the stage-5 manual-testing sub-flow. `running` while `/mi-manual-test-run` is mid-walk; `complete` once results land in `complete`; `skipped` if the inspector answered `n` to the Resume Step 7 offer. Cleared by `progress.sh activate` and `progress.sh reset` to `none`. Optional — missing means `none`.
- **manual-test-failure-policy**: optional `none | auto-seed | manual`. Recorded when the inspector picks the failure policy at the start of `/mi-manual-test-run`. `auto-seed` causes failed scenarios to seed `### IR-NNN` findings via `review.sh upsert-manual-test-failure` (deterministic `seed-id: manual-test:<seed-family-id>:<scenario-id>`); `manual` prints the failure and lets the inspector hand-author the finding. Cleared on activate/reset.
- **clear-recommendations**: optional array of clear-point identifiers already crossed (`stage-2-to-3`, `stage-5-to-6`). The Approve Handler and `/mi-review` consult this so the gate doesn't re-prompt on re-entry. The feature-A→feature-B gate at `/mi-complete-workflow` Step 7 is one-shot and uses no flag (state shape is already self-recovering). Cleared on activate/reset.
- **worktree-path / git-common-dir / git-worktree-dir**: working-tree fingerprint captured at activation time (stage 2, by `progress.sh activate`). Records the absolute `pwd`, `git rev-parse --git-common-dir`, and `git rev-parse --git-dir` of the working tree that owns this cycle. State-mutating subcommands (`set`, `advance`, `advance-to`, `finish`, `requeue`, `reset`) call `mi_assert_worktree_match` before writing and refuse on mismatch — this prevents two `git worktree add` checkouts that share the same `data_root` from clobbering each other's active block. The fields are immutable after activate (`progress.sh set worktree-path=...` is rejected) so the guard's anchor can't be erased mid-cycle. A pre-flight subcommand `progress.sh check-worktree` exposes the same check for command markdowns that want to fail fast before any state writes. The guard is a no-op for cycles activated before the fingerprint shipped (all three fields absent), so old in-flight cycles finish without disruption.
- **activation-id**: optional UUIDv4. Minted by `progress.sh activate` and re-minted by `progress.sh reset` (so the abort-retry path counts as a new activation). Cleared on `finish`/`requeue` along with the rest of `active`. Cross-activation discriminator for the stage-5 manual-test sub-flow's results-rotation guard — `/mi-manual-test-plan` Step 1 and `/mi-manual-test-run` Branch A pre-normalization rotate any surviving `test/manual-test-results.md` whose frontmatter `generated-in-activation` does not match this value. Git-independent (does not depend on `base-commit`), so the abort-retry-without-new-commits path is correctly detected. Immutable after activate (`progress.sh set` / `advance-to` reject rewrites) with one narrow exception: a missing → set transition is allowed, used by `/mi-manual-test-plan` Step 1's one-shot backfill for cycles activated before the field existed. See `docs/manual-testing-folder/plan.md` § 4.3.

Stages 0 (journal intake) and 1 (mi-run) are workflow-wide and implied by the absence of progress.md (stage 0) or its presence with `active: null` (stage 1 done). On resume, the millwright reads `active` to decide which command to run next. Stages are defined below.

#### Running parallel cycles with git worktree

`mi_data_root` resolves per working directory (`$MI_DATA_ROOT` → `$CLAUDE_PLUGIN_USER_CONFIG_data_root` → `${PWD}/millwright-inspector`). The default puts each working tree on its own data root automatically, so two `git worktree add` checkouts can run independent cycles with no extra setup. Two pitfalls are worth calling out:

- **Don't set `userConfig.data_root` to an absolute path.** That value is global to the Claude Code instance, so every worktree resolving against it lands on the same folder and shares one `quest/active.md`, one `progress.md`, one `workflow-stream/`. Either leave it unset or use a relative path (e.g. `.mi`).
- **If you need an absolute root, set it per-worktree via `MI_DATA_ROOT`.** `MI_DATA_ROOT` overrides the user-config value, so a per-worktree `.envrc` (`export MI_DATA_ROOT="$PWD/millwright-inspector"`) neutralizes a bad global setting.

If both worktrees do end up sharing a data root, the worktree fingerprint guard catches the most damaging case (a sibling worktree mutating an active block it doesn't own) and refuses with a guidance message before any state is written. `quest.sh start` and `progress.sh activate` already refuse to repoint `quest/active.md` or activate a second feature while one is in flight, so the remaining gap — stage-3+ mutations from the wrong worktree — is what `mi_assert_worktree_match` closes.

### The Workflow

1. Everything starts by populating the **journal** folder with documents. Both `.md` and `.txt` files are accepted — pick whichever format fits the source (meeting transcripts are typically `.txt`; notes and specs are typically `.md`). One thing important here is that every `.md` file which is generated or used by the workflow has an info section at the beginning of the document which holds information and references to other `.md` documents. When users add a `.md` document into the journal folder, they should manually add the **contributors** and **date** fields at the top. `.txt` files have no frontmatter requirement and are read as plain content.
2. When the inspector asks the millwright to perform a task, they invoke `mi-run` passing one or more `journal/` sub-folder names (the topics this workflow cycle will cover). No branch arg — that's deferred to stage 2's `config.md` and validated at stage 3. `/mi-run` first creates a fresh per-cycle subfolder under `quest/` (named after a date-prefixed slug derived from the journal folders) and updates `quest/active.md` to point at it. Older cycle subfolders are kept untouched as a permanent record. If a previous cycle is still active and the inspector wants to start fresh anyway, they pass `--archive-active` to retire it.
   `mi-run` command then generates these files inside `quest/<active-slug>/`:
   - **todo-list.md**: explained in the ####Journal section above. Has data in info section which are:
     1. **id**: random generated UUID
     2. **related-features**: feature/module name list. those names may be existing features in the project or the name of the to-be-implemented.
     3. **description**: description of the work to be done.
   - **summary.md**: generated structured summary of all resources. Used for understanding the context of the resources or work to be done. The body is **feature-indexed** so downstream stages can read only the active feature's section instead of the whole digest:
     - `## Cross-cutting constraints` — concerns that apply to every feature this cycle.
     - `## Out-of-scope` — items explicitly excluded from this cycle's roadmap.
     - One `## Feature: <name>` section per feature in `features:`, each self-contained.

     Frontmatter:
     1. **todo-list-id**: reference to the todo-list.md file id.
     2. **features**: kebab-case feature names matching the body's `## Feature: <name>` headings — same set as todo-list.md's `related-features`.
     3. **keywords**: keywords in the file.
     4. **description**: a brief description of the summary of related journal items.

3. After the **todo-list.md** had been generated:
   - ask the inspector to mark the todo items they want this cycle to cover by putting an `x` in their checkbox AND adding an `(assignee)` tag (`- [ ] TODO — ...` → `- [x] (emin) TODO — ...`). Unselected items stay as `[ ] TODO`; pre-assigned-but-not-selected items (`- [ ] (emin) TODO — ...`) are also fine.
   - when done marking, the inspector types `/mi-continue`. The Pre-flight Handler in `commands/mi-continue.md` runs `todo.sh pend-selected` — which converts every `[x] (<assignee>) TODO` line into `[x] (<assignee>) PENDING` in one pass. If any `[x] TODO` line lacks an assignee tag, the script exits `2` without modifying the file and prints the offending item ids on stderr; the millwright relays those to the inspector, who adds names and re-types `/mi-continue`. Once promotion succeeds, the handler groups the PENDING items by feature/module. If they span multiple features, the handler proposes an ordering using a journal-first / heuristic / sub-agent-fallback flow (Phase 4 of the context-optimization plan): try `summary.md` cross-references first; only if a heuristic flags ambiguity does it delegate to a fresh sub-agent that inspects the codebase. Main never reads code at stage 1.5. The result is presented to the inspector for confirmation.
   - the inspector accepts by typing `/mi-continue` again (or pastes a custom order in chat first, then `/mi-continue`). The Pre-flight Handler then writes the active cycle's `queue-rationale.md` (under `quest/<active-slug>/`), runs `scripts/progress.sh reorder <feature1> <feature2> ...` (which validates the new order is a permutation of the existing queue and refuses to run while a feature is active), and auto-fires `/mi-apply-impact` for `queue[0]`. `progress.md` is the single source of truth for which features remain to be worked on; the millwright reads it on every resume and between workflows.
4. When the inspector types `/mi-continue` after seeing the proposed queue order, the millwright (via the Pre-flight Handler's Step 2B) **auto-invokes** `mi-apply-impact` (the inspector does not type the command). `mi-apply-impact` calls `progress.sh activate` to pop `queue[0]` into a fresh `active` block (feature set from the popped value, branch=null, current-stage=2, all other runtime fields at defaults), and generates the `[feature]/blueprints/current` folder content which is:
   - **requirements.md**: generate the requirements for the selected todo list items by reading the active cycle's `summary.md`, `todo-list.md`, and `config.md`, and by running a **bounded codebase-grounding pass** to identify, for each PENDING item, the existing seam (folder / module / layer / hook point) where the change naturally lands AND the **cycle flavor** (`greenfield | bugfix | improvement`) — the flavor is detected per Goals item from the todo description plus whether the seam already contains the targeted functionality, and it shapes how the Goals body is phrased and how the diagram legend reads at Step C. The pass is scoped, not exhaustive — see `docs/blueprint-regeneration.md` Step A "Codebase-grounding pass" for the recipe, bounds, and flavor-detection rules. Cycle flavor is **not** persisted (no frontmatter field, no schema change); it's a framing decision implicit in the Goals prose. Frontmatter fields:
     - add **id** field to info section to this file by generating an uuid.
     - add **todo-list-id** which is a reference to the related **todo-list.md** (**todo-list-id** should be the same value with the **id** field of the related **todo-list.md** file)
     - add **todo-item-ids** which is the id array of the todo list items which had status as PENDING in the related **todo-list.md** file.
     - add **commits** which is a list of commits (currently empty)

     The requirements.md **body** must contain three clearly-labeled scope sections so the brainstorming chain at stage 3 can distinguish "deliver now" from "design for later" from "not in the roadmap":
     1. **`## Goals (this cycle)`** — what the PENDING items (scoped to the active feature's section in `todo-list.md`) deliver. Each Goals item **names the existing seam** identified by the codebase-grounding pass and sketches the high-level solution shape; the **phrasing follows the cycle flavor** detected in the same pass: greenfield items read as additive ("add a service under `services/` to handle add-to-cart"), bugfix items read as behaviour changes against the existing seam ("change `CartService.addItem` so quantity 0 is rejected with 400 instead of creating an empty cart row"), improvement items read as extensions of an existing capability ("extend `CartService.addItem` to also accept bulk-add requests; keep the single-item path unchanged"). This is a high-level solution sketch — not implementation detail. Code-level specifics (function signatures, payload shapes, table columns) belong in the brainstorming spec at stage 3, not here. The seam is a hint for the chain, not a contract; if brainstorming picks a better seam, the stage-4 drift check + `/mi-update-blueprint` rotates the blueprint to match. The primary deliverable.
     2. **`## Planned (future cycles)`** — the TODO items still in the **same feature's** section of `todo-list.md` that were NOT selected this cycle. These WILL be implemented in a later cycle, so the current design must leave appropriate architectural seams (interfaces, extension points, abstractions) for each one to land without a rewrite. `mi-apply-impact` fetches this list via `todo.sh list TODO --feature "$active_feature"`. Omit the section entirely if no such items exist.
     3. **`## Non-goals (out of scope)`** — items explicitly excluded from the feature's roadmap. Sourced from the active cycle's `summary.md` (any journal-sourced exclusions are captured there at stage 1; under `quest/<active-slug>/`), `config.md`'s `## Inspector Additions`, or inspector statements in chat. These are NOT on the TODO list. May be omitted if empty.

     **Critical distinction:** a "Planned" item is future work that the current implementation must accommodate. A "Non-goal" item is something the implementation can safely assume away. Lumping unselected TODO items into Non-goals — as earlier versions of this command did — is a regression that can force painful rewrites when those items are later implemented.

   - **config.md**: split into two ownership zones so `mi-apply-impact` can regenerate the auto-summary without clobbering the inspector's custom prompts. The canonical shape:

     ```markdown
     ---
     id: <uuid>
     requirements-id: <uuid of the related requirements.md>
     ---

     <!-- auto:start — regenerated by mi-apply-impact; do not edit this section -->

     ## Skills

     (auto-generated summaries of each skill under `.claude/skills/`)

     ## Rules

     (auto-generated summaries of each rule under `.claude/rules/`)

     <!-- auto:end -->

     ## Inspector Additions

     (anything below this marker is preserved verbatim across regenerations — put custom prompts, MCP invocations like "get figma files from <url>", project-specific instructions, etc. here)
     ```

     `mi-apply-impact` replaces only the content between `<!-- auto:start -->` and `<!-- auto:end -->` markers. Everything below `## Inspector Additions` is preserved verbatim on every regeneration. The **requirements-id** field in the info section cross-references the related `requirements.md`'s `id`.

   - diagrams: render via the PlantUML MCP, with caps per § "Diagram conventions" — **1 use-case (mandatory), 2–3 sequence, and at most one optional structural diagram (either class OR component, never both)**. The optional slot fires only when the seam classification from Step A's codebase-grounding pass is `backend` or `mixed` AND the content threshold is met (3+ classes with non-trivial relationships → class; 3+ components with non-trivial dependencies → component; skip otherwise). **Apply the existing-vs-new framing convention** with the stage-2 baseline: `existing` = the current HEAD codebase identified by the codebase-grounding pass; `new` = the additions sketched by the Goals items. Subjects/filenames should match the implementation diagrams rendered at stage 4 so the inspector can diff equivalent diagrams across the two folders.
     - add **requirements-id** field to info section which is a reference to the generated **requirements.md** id field avaialble at its info section.

5. Inform the inspector that the `workflow-stream/[feature]/blueprints/current/requirements.md`, `workflow-stream/[feature]/blueprints/current/config.md` and `workflow-stream/[feature]/blueprints/current/diagrams` have been generated and ask them to review. Instruct the inspector that when ready they should type `/mi-continue`; the Approve Handler in `commands/mi-continue.md` will validate the blueprint files and auto-launch `mi-plan-implementation`. Also inform the inspector about the next stage which is:
   - planning phase by using the `brainstorming` skill (already registered under `.claude/skills/` in this project — see the "Skill references" note at the end of this section), OR direct implementation in the main session — the inspector picks at the start of stage 3 (see item 6).
6. When the inspector types `/mi-continue` (the stage-2 review gate), the millwright (via the Approve Handler) **auto-invokes** `mi-plan-implementation`. This command is a **pure launcher** and does the following atomically:
   1. updates the selected todo items PENDING → IMPLEMENTING in the active cycle's `todo-list.md`.
   2. captures `git rev-parse HEAD` into `progress.md` as **base-commit**.
   3. sets **sub-flow** to `chain-in-progress` in `progress.md`.
   4. composes `workflow-stream/[feature]/blueprints/current/primer.md` — a compact snapshot of active scope, goals (from `requirements.md`), journal context (from `summary.md`'s `## Feature: <active>` section), and likely-relevant skills/rules (from `config.md`). See "Rule 3 — Layered context loading" above.
   5. **asks the inspector to pick a planning-mode** (`brainstorming` or `direct`) and persists the choice to `progress.md` (`active.planning-mode`). See "Planning-mode and review-mode" below for what each mode means.
   6. **brainstorming mode:** invokes the brainstorming skill with `primer.md` as the required first read; `config.md`, `requirements.md`, the active cycle's `summary.md` (active feature section), and the active cycle's `todo-list.md` are listed as on-demand fallbacks. **direct mode:** the millwright reads `primer.md` itself, escalates to canonical files only as needed, and implements directly in the main session.

   After step 6 the millwright does NOT interfere with the chain (in brainstorming mode). The brainstorming → writing-plans → executing-plans / subagent-driven-development → finishing-a-development-branch chain runs as a completely isolated interactive session. The inspector answers design questions, approves the spec, approves the plan, picks an execution mode, and interacts with the execution skill exactly as they would in any normal Claude Code session. No mi-workflow commands are expected during this phase — the inspector should not be thinking about the mi-workflow at all while brainstorming is live.

   In direct mode, the inspector reviews the millwright's work inline as it happens; commits land on the active branch as the millwright produces them.

   When the chain (or direct implementation) finishes and control returns to the main thread, the inspector types `/mi-continue` once. This is the single resumption signal and the only mi-workflow touchpoint required between launch and reviews. The `/mi-continue` handler resumes the workflow as described in item 7 below.

7. When the inspector types `/mi-continue` after the chain has returned, the millwright's Resume Handler runs an atomic seven-step sequence ending in `progress.sh advance-to 3 5` — **stage 4 is conceptual and never persisted**. Eliminating stage 4 as a persisted state closes a class of "session break re-fires the drift prompt" failures (F1 in the v11 progress-gap plan):
   0. **Drift-completion probe.** Skipped when `active.drift-check-completed=true`. Otherwise walks `blueprints/history/v[K] > active.history-baseline-version` looking for a finalized version with `reason.kind == "spec-update"`. If found AND `blueprints.sh check-current --require-primer` returns 0 (complete), the prior `/mi-update-blueprint --reason-kind=spec-update` rotated + regenerated successfully but the marker write was lost — persist `drift-check-completed=true` and skip Step 3. If no baseline is recorded (older in-flight cycle, or stage-3 was partial), the probe captures a fresh baseline and disables itself for this invocation. The recovered-kind switch GUARDs to `{manual, spec-update}`; `completion` routes to `/mi-complete-workflow`'s Branch 0a, and `re-spec-cascade`/`re-plan-cascade` route back to `/mi-review`.
   1. **Verify commits.** Runs `git rev-list --count base-commit..HEAD`. If `> 0`, proceed. If `== 0`, prompts the inspector with three options: `retry-launch` (re-launch `/mi-plan-implementation`; stage stays at 3), `direct-empty` (confirm no code changes were needed — writes a tagged HTML comment into `inspector-review.md` documenting why, pre-sets `drift-check-completed=true`, and atomically advances 3→5), or `abort` (run `/mi-abort-workflow`). Direct-mode implementations satisfy the non-empty check by committing during stage 3.
   2. **Idempotent flag writes.** Sets `sub-flow=resuming`, `implementation-completed=true`. Idempotent so a session-break re-entry doesn't trip a "field already set" guard.
   2.5. **Abandoned-chain check.** Locates plan files added/modified in `base-commit..HEAD` under `docs/superpowers/plans/` plus any uncommitted plans newer than `base-commit`, counts `- [x]` / `- [ ]` checkboxes; on `abandoned`, re-invokes the `brainstorming` Skill with a resume primer pointing at the existing plan + spec + commit log so the chain picks up from the next un-done step, sets `sub-flow` back to `chain-in-progress`, and stops without advancing.
   3. **Drift prompt — skipped when Step 0 set the marker.** Otherwise prompts the inspector with three valid replies: a short `<reason>` (invokes `/mi-update-blueprint --reason-kind=spec-update "<reason>"`, which rotates `blueprints/current/` into history and regenerates Goals + diagrams + primer.md from the codebase, preserving inspector-authored sections + roadmap from the rotated version); `auto` (the millwright analyzes `requirements.md` against `git diff base-commit..HEAD` + current code — if meaningful divergence is found, derives an `$auto_reason` and invokes `/mi-update-blueprint --reason-kind=spec-update "$auto_reason"`; if no divergence, skips rotation and only writes the `drift-check-completed=true` marker — cosmetic-only deltas don't trigger rotation because `/mi-update-blueprint` already re-derives Goals from implementation reality); or `continue` (proceed without updating; drift surfaces as findings later). The chain's spec/plan files are NOT read; the inspector (or the `auto` analyzer) is the authority on whether requirements drifted.
   4. **Drift side effect** — persists `drift-check-completed=true` (split marker write so Step 0's probe can detect a successful rotation even if the gate's marker write is the one lost to a session break).
   5. **Auto-fire `/mi-draw-diagrams`** (the user-facing wrapper around `mi-generate-implementation-diagrams`). Renders use-case, sequence, and (if relevant) one optional structural diagram of `base-commit..HEAD` into `workflow-stream/[feature]/implementation/diagrams/`, with pre-existing system elements framed as shaded blue context next to new green functionality.
   6. **Initialize** `workflow-stream/[feature]/implementation/inspector-review.md` skeleton via `review.sh init` (idempotent).
   7. **Atomic finalize.** `progress.sh advance-to 3 5 --set sub-flow=none` — the drift marker was already persisted by Step 0 or Step 4 as a split marker write; this final write only collapses stage 3 directly to stage 5.

8. The millwright then announces stage completion: implementation commits (`base-commit..HEAD`) and diagrams at `workflow-stream/[feature]/implementation/diagrams`. The inspector reviews the generated code and the diagrams (existing-system context is shaded inside each diagram so the new functionality reads as a delta), then edits the skeleton at `workflow-stream/[feature]/implementation/inspector-review.md` — either appending finding entries or leaving the file untouched to signal approval. When done, the inspector types `/mi-continue` a second time.

9. This second `/mi-continue` triggers the inspector-review handler. The handler:
   0. **(read-only) prints a one-line manual-test summary** if `manual-test-state ∈ {complete, skipped}`.
   1. verifies `inspector-review.md` exists; if missing (inspector deleted it), prompts the inspector to either recreate it or confirm approval, and aborts if neither.
   2. **canonicalizes any free-form findings** the inspector wrote as plain sentences. The handler runs `review.sh canonicalize` to detect unstructured text under `## Implementation Review`; for each detected span, the millwright classifies severity + scope, generates a one-line summary, calls `review.sh add` to insert the structured `### IR-NNN` block (preserving the original wording in `details:`), then calls `review.sh strip-freeform` to remove the original line range. This keeps the file canonical so `list-open` sees every inspector-authored finding. See `commands/mi-continue.md` Inspector Step 1.5.
   3. parses the file: if there are no `open` findings under `## Implementation Review`, **prompts the inspector with a y/n confirmation** (`inspector-review.md has no open findings. Confirming will complete the inspector-review stage and auto-fire /mi-complete-workflow. Continue? (y/n)`); on `y`, sets **inspector-review-completed** = true, advances directly to stage 7, and auto-fires `mi-complete-workflow`; on `n`, stops without advancing — `current-stage` stays at 5 so the next `/mi-continue` re-prompts (or routes to step 4 if findings were added in the meantime). The confirmation gate exists because once `/mi-complete-workflow` fires it archives blueprints and advances the queue, which is non-trivial to undo.
   4. otherwise, invokes `/mi-review`, which fires its **Step 0 `stage-5-to-6` clear-point gate** (recommends `/clear` and records the identifier in `progress.md.active.clear-recommendations`), then sets **sub-flow** to `reviewing`, advances stage 5 → 6, composes `workflow-stream/[feature]/implementation/review-context.md` (compact snapshot — active scope, goals, implemented surface, open-findings cheat sheet; folds in `decisions.md` content + the persisted `review-mode-suggestion` if present), **asks the inspector to pick a review-mode** (`brainstorming` or `direct`; persisted to `progress.md` as `active.review-mode`), and either launches a brainstorming review session via the `review-iteration-runner` sub-agent (isolated from mi-workflow — same model as stage 3) with `review-context.md` + `inspector-review.md` as required first reads and `requirements.md` / `config.md` / `summary.md` (active feature section) / `primer.md` as on-demand fallbacks, OR runs the review loop directly in the main session for `direct` mode. After invoking `/mi-review`, the second `/mi-continue` returns control to the inspector; it does NOT advance past stage 6 and does NOT auto-fire `/mi-complete-workflow`.

      Inside the brainstorming review session, the chain controls the loop end-to-end:
      - reads each open finding (id, severity, scope hint, details);
      - decides per-finding how to address it — `fix` (direct patch), `re-implement` (cascade into executing-plans), `re-plan` (cascade into writing-plans → executing-plans), or `re-spec` (full re-design through writing-plans + executing-plans); the chain regenerates its own spec/plan internally and writes commits;
      - marks each finding resolved via `review.sh set-status <id> fixed <note>`;
      - asks the inspector for approval. The inspector either replies `approve` (chain exits cleanly), or writes new findings into `inspector-review.md` and replies `go again` (chain re-reads and processes the new findings). The session loops until approval.

      Mi-workflow does not encode the cascade dispatch — that's the brainstorming skill's job. There is no iteration cap; the inspector ends the session with `approve`.

      When the brainstorming review session exits, the inspector types `/mi-continue` (the third per-feature touchpoint). The post-review-session resume handler checks for open findings (if any remain, it prompts the inspector to proceed with deferred findings, retry `/mi-review`, or abort; if all are resolved, it prompts the **same y/n completion confirmation** as the no-findings stage-5 path — on `n`, stops without advancing, `current-stage=6, sub-flow=reviewing` stays in place so the next `/mi-continue` re-prompts), then **offers the inspector a diagram refresh before advancing** (a y/n prompt — if the review session committed new code, regenerating implementation diagrams via `/mi-draw-diagrams` lets the inspector see the final state before stage 8 archives the diagrams into `blueprints/history/v[N+1]/implementation/diagrams/`). Only after both prompts are settled does it atomically set **sub-flow** to `none`, set **inspector-review-completed** = true, advance stage 6 → 7, and auto-fire `mi-complete-workflow`.
10. When the workflow reaches stage 7 — either via the no-findings path (stage-5 `/mi-continue` advances directly because `inspector-review.md` was empty) or via the with-findings path (the stage-6 `/mi-continue` confirms all findings resolved after the review session) — the millwright **auto-invokes** `mi-complete-workflow` (the inspector does not type the command; reaching stage 7 itself is the signal). `mi-complete-workflow` handles:
    - Millwright updates the todo items IMPLEMENTING to IMPLEMENTED in **todo-list.md** file.
    - Millwright populates the **commits** field in the info section of the related **requirements.md** file with the commit ids and commit messages of the branch (the canonical link between requirements and implementation; the chain's plan/spec files under `docs/superpowers/` are NOT touched — they're the chain's own artefacts).
    - Millwright rotates the entire contents of `workflow-stream/[feature]/blueprints/current` (namely `requirements.md`, `config.md`, `primer.md`, and `diagrams/`) into `workflow-stream/[feature]/blueprints/history/v[N+1]/` via `blueprints.sh rotate --reason-kind completion`, which also writes a `reason.md` into the new history folder. For example: if the last `v[number]` under `workflow-stream/[feature]/blueprints/history` is `v3`, then all four artifact groups plus `reason.md` land in `workflow-stream/[feature]/blueprints/history/v4/` and `workflow-stream/[feature]/blueprints/current/` is left empty.
    - **archive** the content of `workflow-stream/[feature]/implementation/` into the just-rotated `blueprints/history/v[N+1]/implementation/` (move `inspector-review.md`, `review-context.md`, `change-summary.md`, `grounding-report.md`, and `diagrams/` into a sibling `implementation/` subfolder under the new history version). The live `implementation/` folder is left empty; the next feature's stage-2 launcher re-creates children there. This keeps every finding (including any deferred `status: open` ones), the review-context snapshot, the change-summary, the grounding-report, and the implementation diagrams as a permanent audit record alongside the rotated blueprint version. Note: `decisions.md` lives at the feature root and is **not** rotated — it persists across blueprint versions. The `test/` folder (manual-test plan + results + history) is similarly feature-permanent and is NOT rotated at stage 8 — see `docs/manual-testing-folder/plan.md` for the cross-cycle reuse design.
    - call `progress.sh finish`: append the just-completed feature to `completed`, and set `active` to `null`. (Under the two-step activation model, the next feature is not auto-popped — `mi-apply-impact` will activate it.)
11. Lastly, the millwright reads `progress.md`'s `queue`. If any features remain, **the feature-A→feature-B clear-point gate fires here**: the millwright recommends `/clear` to the inspector (Claude Code does not let agents invoke `/clear` programmatically) and HALTS before auto-firing `/mi-apply-impact` for `queue[0]` — this gate is one-shot and uses no tracking flag (a fresh session re-enters via `/mi-continue` Pre-flight Row A, which auto-fires `/mi-apply-impact` based on the `features − completed == queue` invariant). The inspector can pause indefinitely by simply replying with a non-affirmative message or by running `/mi-abort-workflow`. If `queue` is empty (and `active` is null), the millwright checks the active cycle's `todo-list.md` for unmarked `[ ] TODO` items: if any exist, it tells the inspector to mark the items they want next and type `/mi-continue` (the Pre-flight Handler will use `progress.sh enqueue` to repopulate the queue without scrubbing the existing `progress.md` / quest files); if none remain, the cycle is fully drained and `quest.sh end` archives the pointer; the millwright reports completion with a recommendation to run `/mi-run` for a new cycle.

### The Stages:

The `progress.md` file's `active.current-stage` should be advanced when a stage is considered completed.

**At-a-glance** (detailed prose follows the table):

| Stage | Name | Driver | Entry signal | Exit |
| ---: | --- | --- | --- | --- |
| 0 | Journal populated | Inspector (manual) | New cycle | Inspector types `/mi-run` |
| 1 | Quest generated | Millwright via `/mi-run` | `/mi-run <folder...>` | `quest/<active-slug>/{todo-list, summary, progress}.md` exist; `quest/active.md` updated; `queue-rationale.md` is deferred to stage 1.5 |
| 1.5 | Selection + ordering | Pre-flight Handler in `/mi-continue` | Inspector marks `[x]` then `/mi-continue` ×2 | `queue-rationale.md` written; queue reordered; `/mi-apply-impact` auto-fires |
| 2 | Blueprints generated | Millwright via `/mi-apply-impact` (auto) | Pre-flight Step 2B | `blueprints/current/{requirements.md, config.md, diagrams/}` |
| 3 | Implementation launched | Millwright via `/mi-plan-implementation` (auto) → chain or direct | Approve Handler at end of stage 2 | `base-commit` + `planning-mode` recorded; chain or direct implementation in progress |
| 4 | Implementation resumed (conceptual; **never persisted**) | Resume Handler in `/mi-continue` | `/mi-continue` after chain/direct returns | `implementation-completed=true`; diagrams rendered; review skeleton created. Handler ends with atomic `progress.sh advance-to 3 5` — `current-stage` skips 4 entirely (closes F1 in the v11 progress-gap plan) |
| 5 | Presented for inspector review | Inspector | Stage-4 handoff message | `/mi-continue` after editing `inspector-review.md` |
| 6 | Inspector review session | `/mi-review` (auto) → chain or direct | Inspector Handler with open findings | Inspector types `approve`, then `/mi-continue` |
| 7 | Review completed (transitional) | Review-Resume Handler | No-findings path or post-review-session path | No-findings path auto-completes; with-findings path may refresh diagrams before completion |
| 8 | Completion | Millwright via `/mi-complete-workflow` (auto) | Stage 7 reached | Blueprint rotated to history; `implementation/` archived into that history version and cleared; queue advances |

- **Stage 0 — Journal populated**: Covers populating the `journal/` folder with resources (meeting transcripts, notes, etc.). Completed when the inspector signals that intake is done.
- **Stage 1 — Quest generated**: Covers `mi-run`. Completed when the active cycle's `todo-list.md` and `summary.md` exist (under `quest/<active-slug>/`) and `quest/active.md` points at the new slug.
- **Stage 2 — Blueprints generated**: Covers `mi-apply-impact`. Completed when `workflow-stream/[feature]/blueprints/current/requirements.md`, `.../config.md`, and `.../diagrams/` all exist.
- **Stage 3 — Implementation launched**: Covers `mi-plan-implementation` (the launcher). Completed when `progress.md` has `base-commit` recorded, `planning-mode` set (`brainstorming` or `direct`), and `sub-flow: chain-in-progress` for both planning modes. After this point the mi-workflow does not touch the session in brainstorming mode (the inspector drives the chain to completion); in direct mode, the millwright is the implementer in the main session. Direct mode is distinguished by `planning-mode: direct`, not by clearing `sub-flow`.
- **Stage 4 — Implementation resumed**: Covers the `/mi-continue` Resume Handler post-implementation (chain-driven or direct). Conceptual stage — `current-stage=4` is **never persisted**. The handler runs Step 0 (drift-completion probe — closes F1 in the v11 progress-gap plan), Step 1 (verify commits in `base-commit..HEAD`; the zero-commit branch offers `retry-launch` / `direct-empty` / `abort`), Step 2 (idempotent flag writes — `sub-flow=resuming`, `implementation-completed=true`), Step 2.5 (abandoned-chain recovery — read-only inspection of `docs/superpowers/plans/`), Step 3 (drift prompt — skipped when Step 0 set the marker), Step 4 (drift side effect: auto-fires `/mi-update-blueprint --reason-kind=spec-update <reason>` if a reason was supplied, and persists `drift-check-completed=true`), Step 5 (auto-fire `/mi-draw-diagrams`), Step 6 (init `inspector-review.md` skeleton), and Step 7 (atomic `progress.sh advance-to 3 5 --set sub-flow=none`; the drift marker was already split-written by Step 0 or Step 4). Completed when implementation-completed=true, the drift probe + (optional) drift fire are settled, implementation diagrams exist under `workflow-stream/[feature]/implementation/diagrams`, and the empty `inspector-review.md` skeleton has been created. The chain's spec/plan files are not tracked.
- **Stage 5 — Presented for inspector review**: Covers the millwright announcing stage completion (code + implementation diagrams with existing-vs-new framing) and waiting for the inspector to write findings into `inspector-review.md`. Stage 5 is broader than just findings authoring — it widens to "inspector evaluation," with an optional **manual-test sub-flow** that can run before findings authoring. The Resume Step 7 hand-off prompt asks the inspector whether to generate a manual test plan first; on `y` it auto-fires `/mi-manual-test-plan` (which renders `workflow-stream/[feature]/test/manual-test-plan.md` and offers to execute it via `/mi-manual-test-run`). Manual-test artifacts are feature-scoped under `workflow-stream/[feature]/test/` — `manual-test-plan.md`, `manual-test-results.md`, `manual-test-plan.history/`, and `manual-test-results.history/`. The `test/` folder is **feature-permanent**: it survives `/mi-complete-workflow` and `/mi-abort-workflow` so the next cycle on the same feature can reuse the prior plan and inherit its `seed-family-id`. Cross-activation results auto-rotation (`/mi-manual-test-plan` Step 1 and `/mi-manual-test-run` Branch A pre-normalization) prevents a prior-activation results file from interfering with a fresh run — see `docs/manual-testing-folder/plan.md` § 4.1 + § 4.3. While a run is in progress, `progress.md` carries `sub-flow=manual-testing` and `manual-test-state=running`; the `/mi-continue` dispatcher routes the `5 | manual-testing` row to a dedicated Manual-Test-Resume Handler that re-enters `/mi-manual-test-run` from the persisted `current-scenario`. After the run finalizes (or when the inspector answers `n` to the manual-test prompt), `sub-flow` returns to `none` and stage 5 continues with findings authoring as before. Completed when the inspector types `/mi-continue` and the millwright confirms `inspector-review.md` exists (empty or populated). See `docs/manual-testing/plan.md` for the original sub-flow design and `docs/manual-testing-folder/plan.md` for the test-folder relocation + cross-cycle reuse design.
- **Stage 6 — Inspector review session**: Covers the review session launched by `/mi-review`. After the second `/mi-continue` invokes `/mi-review`, the millwright sets `sub-flow=reviewing`, advances 5→6, asks the inspector to pick a `review-mode` (`brainstorming` or `direct`), and hands off accordingly. **In `brainstorming` mode**, the session runs isolated from mi-workflow — same isolation model as stage 3. The chain runs the entire fix-and-approval loop internally — addressing findings, asking the inspector for approval, re-reading `inspector-review.md` if the inspector adds new findings, and exiting on `approve`. **In `direct` mode**, the millwright addresses each finding directly in the main session, committing per fix, marking each `fixed` via `review.sh set-status`, and looping on `go again` reads. Either way: there is no iteration cap. Completed when the session exits AND the inspector types `/mi-continue` (the third per-feature touchpoint), at which point the post-review-session resume handler in `/mi-continue` handles open/deferred findings, offers the diagram-refresh prompt when review-loop commits exist, then advances 6 → 7. Skipped entirely when there are no findings — the stage-5 `/mi-continue` advances directly to stage 7.
- **Stage 7 — Review completed**: Brief transitional stage. Reached either by (a) the no-findings path — stage-5 `/mi-continue` advances directly because there were no open findings — or (b) the with-findings path — the post-review-session resume handler advances after the review session exits and the inspector types `/mi-continue`. Either way, **inspector-review-completed** is true, **sub-flow** is `none`. The no-findings path immediately auto-fires `/mi-complete-workflow`; the with-findings path first offers the inspector a diagram-refresh prompt when review-loop commits exist, then advances 6 → 7 and auto-fires completion.
- **Stage 8 — Completion**: Covers `mi-complete-workflow`. Completed when `blueprints/current` has been rotated (with `reason.md`, `kind: completion`) into `blueprints/history/v[N+1]`, the live `implementation/` folder has been archived into that history version and cleared, `progress.sh finish` has moved the active feature to `completed` and cleared `active`, and the todo items are marked IMPLEMENTED (CANCELED items are left as-is).

### The Workflow Commands

- `mi-run`:
  - behavior: reads the specified `journal/` sub-folders and produces `quest/<active-slug>/todo-list.md`, `quest/<active-slug>/summary.md`, and the central `progress.md` (with the feature queue populated, `active: null`, `completed: []`) inside a fresh per-cycle subfolder; calls `quest.sh start` to update `quest/active.md`. Refuses (unless `--archive-active` is passed) when a cycle is already active.
  - inputs:
    1. one or more journal sub-folder names (from inspector, positional)
  - post-conditions: quest files + `progress.md` populated. Branch selection is deferred to stage 2 (pre-filled in `config.md`) and validated at stage 3 (`/mi-plan-implementation`).

- `mi-apply-impact`:
  - invocation: **auto-fired** by the Pre-flight Handler — Sub-state B (initial / extended) and Row A between features at stage 1.5, or by `mi-complete-workflow` Step 7 (when the queue still has features). Manually invokable for recovery.
  - behavior: three-branch re-entry per Step 1 (Item 2 of v11 plan):
    1. **`active` is null** — calls `progress.sh activate` (pops `queue[0]` into a fresh `active` block, current-stage=2). Original happy path.
    2. **`active.current-stage == 2`** — re-entering the same feature mid-stage-2 (e.g., a session break interrupted blueprint generation; the inspector or the Row A dispatcher re-runs `/mi-apply-impact`). Skips activation and surfaces `blueprints.sh check-current` (default mode — primer.md is not expected at stage 2): `0` complete → short-circuit unless `--force`; `1` empty → regenerate from stage-2 inputs; `2` partial → refuse without `--force` (and warn what's missing).
    3. **`active.current-stage > 2`** — refuses; the inspector must run `/mi-abort-workflow` to clear before re-running.
    Then generates the `workflow-stream/[feature]/blueprints/current/` artifacts (requirements.md, config.md, diagrams/, diagrams/README.md).
  - inputs:
    1. feature (popped from `progress.md`'s `queue[0]`, or carried forward in re-entry)
    2. `quest/<active-slug>/todo-list.md` PENDING items for that feature
  - post-conditions: blueprints/current/ populated; `active.current-stage` = 2.

- `mi-plan-implementation` (**launcher — no driver logic**):
  - invocation: **auto-fired** by `/mi-continue`'s Approve Handler when the inspector types `/mi-continue` at the end of stage 2 (the blueprint review gate). Must not fire without that signal. Manually invokable for recovery.
  - behavior: (1) updates selected todo items PENDING → IMPLEMENTING in the active cycle's `todo-list.md`; (2) records `git rev-parse HEAD` as `active.base-commit` and sets `active.sub-flow` = `chain-in-progress` in `progress.md`; (3) composes `blueprints/current/primer.md` (compact stage-3 launch primer); (4) **asks the inspector to pick a planning-mode** (`brainstorming` or `direct`) and persists it to `active.planning-mode`; (5a) `brainstorming` mode — invokes the brainstorming skill with the primer paths listed below; (5b) `direct` mode — does NOT invoke a Skill; the millwright reads `primer.md` itself and implements in the main session, committing on the active branch. Either way, the command does not re-enter the workflow until the inspector types `/mi-continue` after implementation finishes.
  - reads / writes (the launcher's own I/O):
    1. `progress.md` — reads `active.feature`; writes `base-commit`, `sub-flow`, `branch`, `current-stage`, `planning-mode`
    2. `quest/<active-slug>/todo-list.md` — writes: PENDING → IMPLEMENTING for the active feature (via `todo.sh bulk-transition`)
    3. `blueprints/current/config.md` — reads: `## GIT BRANCH` section only, for branch validation
    4. `blueprints/current/primer.md` — writes: compact stage-3 launch primer (overwritten on retry)
  - layered primer paths (used in both modes per "Rule 3 — Layered context loading"; passed to the Skill in `brainstorming` mode, read directly by the millwright in `direct` mode):
    - **Required first read:**
      1. `blueprints/current/primer.md` — active scope, goals excerpt, journal context, likely-relevant skills/rules
    - **On-demand canonical files:**
      2. `blueprints/current/requirements.md` — full goals / planned / non-goals
      3. `blueprints/current/config.md` — full file (skills, rules, inspector additions)
      4. `quest/<active-slug>/summary.md` — feature-indexed digest; read `## Cross-cutting constraints` and `## Feature: <active>` first
      5. `quest/<active-slug>/todo-list.md` — full feature breakdown if PENDING/TODO context is needed
  - post-conditions: implementation-mode is live (Skill invoked or millwright editing); `active.current-stage` = 3; `active.planning-mode` recorded; `primer.md` written.

- `mi-continue` (**universal advancement signal — multi-purpose**):
  - behavior: the single touchpoint between the inspector and the mi-workflow at every gate. Reads `progress.md` (and a few sibling files) and dispatches. Pre-flight rows (active=null) are evaluated first, in order; active rows (active!=null) are evaluated by `current-stage` + `sub-flow`.

    **Pre-flight rows (active=null):**
    - Sub-state A — `[x] TODO` lines exist in active cycle's `todo-list.md`: runs Pre-flight Step 2A — `todo.sh pend-selected` promotes selections, dependencies are analyzed, the prioritized order is proposed in chat.
    - Sub-state B (initial) — promotion done, queue non-empty, `queue-rationale.md` missing: runs Pre-flight Step 2B — writes `queue-rationale.md` (implicit Batch 1 with cumulative `features:`; top-level `status` may be omitted because missing means confirmed), runs `progress.sh reorder` (or `progress.sh enqueue` for mid-cycle re-entry per Finding 6), auto-fires `/mi-apply-impact`.
    - Sub-state B (extended — multi-batch) — promotion done, queue non-empty, `queue-rationale.md` present, top-level `status: draft` (Item 7 of v11 plan): runs Pre-flight Step 2B — confirms or updates the latest `## Batch <N>` body, refreshes top-level `features:`/`batch:`, flips `status` to `confirmed`, then auto-fires `/mi-apply-impact`.
    - **Row A — between features:** queue non-empty, `queue-rationale.md.status` is `confirmed` (or absent ⇒ confirmed), AND `(queue-rationale.md.features − progress.completed, preserving order) == progress.queue` exactly. Auto-fires `/mi-apply-impact` for `queue[0]` without an inspector prompt — the cumulative invariant is already satisfied.
    - **Row B — post-finish housekeeping recovery:** queue empty, no `[x]/[ ] TODO`, `progress.completed` non-empty, `blueprints/history/v[N]/reason.md.kind == "completion"` for `completed[-1]`, `quest/active.md.status == "active"`. Auto-fires `/mi-complete-workflow` — short-circuits to its Branch I (Step 7 housekeeping only).
    - Catch-all (queue empty, no `[x] TODO` lines): delegates to `/mi-resume-workflow` for diagnosis rather than erroring out.

    **Active rows (active != null):**
    - **At stage 2 (Approve Handler):** Step 1 sanity-check (requires `blueprints.sh check-current "$active_feature"` to return 0 in default mode); **Step 2 `stage-2-to-3` clear-point gate** (recommends `/clear` to the inspector; records the identifier in `progress.md.active.clear-recommendations` so re-entry doesn't re-prompt); Step 3 auto-fires `/mi-plan-implementation`. The launcher itself prompts for `planning-mode`.
    - **At stage 5 (Manual-Test-Resume Handler) — `current-stage=5, sub-flow=manual-testing`:** placed ABOVE the catch-all `5 | (any)` row. Dispatches on (plan exists, results exists, results state); Branch A re-fires `/mi-manual-test-run`; Branch B re-fires `/mi-manual-test-run --seed-only` (results exist but seeding never completed); diagnostic + refuse on genuinely-inconsistent shapes.
    - **After stage 3 (Resume Handler):** runs an atomic seven-step sequence ending in `progress.sh advance-to 3 5` — stage 4 is **never persisted**. Step 0 drift-completion probe (skipped when `drift-check-completed=true`; walks `blueprints/history/v[K] > history-baseline-version` for `reason.kind == "spec-update"` and persists the marker if the rotation is complete; the recovered-kind switch GUARDs to `{manual, spec-update}` and routes other kinds to their owning commands; lazy-baseline path captures a fresh baseline and disables the probe for the current invocation when no baseline is recorded). Step 1 verifies commits in `base-commit..HEAD`; the **zero-commit branch** prompts the inspector with `retry-launch` (re-launch `/mi-plan-implementation`), `direct-empty` (confirm no code changes were needed — writes a tagged HTML comment into `inspector-review.md`, pre-sets `drift-check-completed=true`, and atomically advances 3→5), or `abort`. Step 2 sets `sub-flow=resuming`, `implementation-completed=true` idempotently. Step 2.5 runs the abandoned-chain check — locates plan files added/modified in `base-commit..HEAD` under `docs/superpowers/plans/` plus any uncommitted plans newer than `base-commit`, counts `- [x]` / `- [ ]` checkboxes, prompts the inspector with `completed` / `abandoned <N>` options; on `abandoned`, re-invokes the `brainstorming` Skill with a resume primer pointing at the existing plan + spec + commit log so the chain picks up from the next un-done step, sets `sub-flow` back to `chain-in-progress`, stops without advancing. Read-only access to `docs/superpowers/plans/` and `docs/superpowers/specs/` is the single exception to the "mi-workflow does not read the chain's artefacts" rule and applies only on the abandoned-chain branch. Step 3 drift prompt — skipped when Step 0 set the marker; otherwise accepts `<reason>` / `auto` / `continue` and auto-invokes `/mi-update-blueprint --reason-kind=spec-update <reason>` if the inspector supplies one (or `auto` derives one). Step 4 drift side effect — persists `drift-check-completed=true` (split marker write so the probe can detect a successful rotation even if the gate's marker write is the one lost). Step 5 invokes `/mi-draw-diagrams`. Step 6 creates the empty `inspector-review.md` skeleton via `review.sh init`. **Step 7 manual-test offer** (`y/n`): on `y`, auto-fires `/mi-manual-test-plan --from-resume` then `/mi-manual-test-run` and HOLDS at `current-stage=5, sub-flow=manual-testing` until the manual-test sub-flow exits; on `n`, atomic finalize `progress.sh advance-to 3 5 --set sub-flow=none`. Whichever branch returns to stage 5, the same atomic 3→5 advance applies.
    - **After stage 5** (inspector has written findings): runs the Inspector Handler — Step 0 prints a one-line manual-test summary if `manual-test-state ∈ {complete, skipped}`; Step 1.5 **canonicalizes free-form findings** (runs `review.sh canonicalize`, has the millwright classify severity/scope, calls `review.sh add` per span, then `review.sh strip-freeform` to remove originals); Step 1.6 persists `review-mode-suggestion`; reads `inspector-review.md`; if empty (post-canonicalization), **prompts a y/n completion confirmation** (`inspector-review.md has no open findings. Confirming will complete the inspector-review stage and auto-fire /mi-complete-workflow. Continue? (y/n)`); on `y`, atomically `progress.sh advance-to 5 7 --set sub-flow=none --set inspector-review-completed=true` and auto-fires `/mi-complete-workflow`; on `n`, stops without advancing — `current-stage` stays at 5 so the next `/mi-continue` re-prompts (or routes to `/mi-review` if findings were added in the meantime). If findings exist, auto-fires `/mi-review` (which advances 5→6 and prompts for `review-mode`) and stops.
    - **After stage 6 with sub-flow=reviewing** (review session has returned, in either mode): runs the post-review-session resume handler — checks for `open` findings in `inspector-review.md`; if any remain, prompts the inspector with `completed` (proceed with deferred findings; they will be archived in `history/v[N+1]/implementation/inspector-review.md` at stage 8), `abandoned` (re-invoke `/mi-review` to re-launch the loop and stop without advancing), or `abort` (run `/mi-abort-workflow`); if none remain (or `completed` was picked), prompts the **same y/n completion confirmation** as the no-findings stage-5 path — on `n`, stops without advancing (`current-stage=6, sub-flow=reviewing` stays in place). On `y`, **offers a diagram-refresh prompt** (skip when no review-loop commits since the original diagram run; otherwise re-run `/mi-draw-diagrams` if the inspector answers `y`), then atomic finalize: `progress.sh advance-to 6 7 --set sub-flow=none --set inspector-review-completed=true`, and auto-fires `/mi-complete-workflow`. `sub-flow` stays `reviewing` until after the refresh prompt so the prompt is re-fireable on retry.
    - **Stage 7 active row:** auto-fires `/mi-complete-workflow` (idempotent via Branch II in mi-complete-workflow when re-entered after a partial finalize — Item 4 of the v11 plan).
    - **Any other state**: delegates to `/mi-resume-workflow` for state diagnosis rather than erroring out.
  - inputs:
    1. progress.md (`millwright-inspector/quest/<active-slug>/progress.md`, resolved via `quest/active.md`)
    2. `quest/<active-slug>/todo-list.md` (for pre-flight `[x] TODO` detection)
    3. `quest/<active-slug>/queue-rationale.md` (for pre-flight sub-state disambiguation)
    4. inspector-review.md (for canonicalization + open-finding count)
  - post-conditions: depends on dispatch — pre-flight ends with `/mi-apply-impact` chained; stage-2 dispatch chains `/mi-plan-implementation`; stage-5/6 chain ends with `/mi-complete-workflow`.

- `mi-draw-diagrams` (**user-facing diagram launcher**):
  - invocation: manually by the inspector, OR auto-fired by `/mi-continue`'s Resume Handler (Step 5) and Review-Resume Handler (Step 2.5 prompt).
  - behavior: thin wrapper that dispatches on `--target=<name>` (default `implementation`). For `--target=implementation`, runs the body of `mi-generate-implementation-diagrams` unchanged. Other targets are reserved for future use and currently error out with a hint pointing at `/mi-update-blueprint` for requirements-level regeneration.
  - inputs:
    1. config.md, codebase, commit range, `change-summary.md` — same as `mi-generate-implementation-diagrams`.
  - post-conditions: same as `mi-generate-implementation-diagrams`.

- `mi-generate-implementation-diagrams`:
  - behavior: ensures `implementation/change-summary.md` is current (via `commits.sh change-summary-fresh`; regenerates the cached analysis if stale or missing), then reads the commit range `active.base-commit..HEAD` and renders use-case, sequence, and (if relevant) one optional class-OR-component diagram of the **implemented** code via the PlantUML MCP into `workflow-stream/[feature]/implementation/diagrams`. Each diagram applies the blue/green existing-vs-new convention (blue `#D6EAF8` blocks + `#3498DB` arrows for pre-existing; green `#D4EDDA` blocks + `#27AE60` arrows for new), so the inspector reads the change inside one diagram instead of diffing two folders. Codebase reads are bounded (diff hunks first; ≤ 3 callers/callees per changed file; skip generated/vendor/lock; record skipped paths under `## Omitted from analysis`).
  - inputs:
    1. config.md (`workflow-stream/[feature]/blueprints/current/config.md`)
    2. codebase (for both the diff and the unchanged-side context that defines "existing", subject to the bounded-context policy)
    3. commit range `active.base-commit..HEAD` (from `progress.md`)
    4. `implementation/change-summary.md` — reused if cache-fresh, regenerated otherwise
  - post-conditions: `implementation/diagrams/` populated; `implementation/change-summary.md` is current for the active range.

- `mi-review` (**review-loop launcher — pure launcher, no driver logic**):
  - invocation: **auto-fired** by `/mi-continue`'s Inspector Handler when the inspector types `/mi-continue` after writing findings into `inspector-review.md`. Manually invokable by the inspector anytime during stage 5/6 to start the review session early. Re-entry after a clear-point also lands here (not on `/mi-continue`).
  - behavior: **Step 0 — `stage-5-to-6` clear-point gate** at the very top before any state mutation; recommends `/clear` to the inspector and records the identifier in `progress.md.active.clear-recommendations` so re-entry doesn't re-prompt. Then reads open findings from `inspector-review.md`, composes `implementation/review-context.md` (compact stage-6 review primer; folds in `decisions.md` content + the persisted `review-mode-suggestion` if present), **asks the inspector to pick a `review-mode`** (`brainstorming` or `direct`; persisted to `active.review-mode`), and dispatches: `brainstorming` mode invokes the `review-iteration-runner` sub-agent (which has the `Skill` tool and chains into `brainstorming` / `writing-plans` for `re-spec` / `re-plan` cascades) with the primer paths listed below (the session runs isolated from mi-workflow — same isolation model as stage 3); `direct` mode keeps the review loop in the main session — the millwright reads the same primer, addresses each finding directly, commits per fix, marks each `fixed` via `review.sh set-status`, and loops on `go again` reads. Mi-review does NOT advance past stage 6 in either mode and does NOT auto-fire `/mi-complete-workflow`. The inspector ends the session by typing `approve`, then `/mi-continue` to resume mi-workflow; the post-review-session resume handler in `/mi-continue` offers the diagram refresh when review-loop commits exist, then atomically advances 6 → 7 and auto-fires `/mi-complete-workflow`. Mi-review does **not** generate findings (inspectors and the chain are the only authors) and does **not** drive scope-tier dispatch (the chain or millwright decides per-finding).
  - reads / writes:
    1. `progress.md` — reads `active.feature`, `active.base-commit`; writes `sub-flow=reviewing`, `review-mode`, advances stage 5 → 6
    2. `inspector-review.md` — reads via `review.sh list-open` to compose the concern bundle for the primer
    3. `implementation/review-context.md` — writes: compact stage-6 review primer (overwritten on retry; archived by `mi-complete-workflow`, deleted by `mi-abort-workflow`)
  - layered primer paths (used in both modes per "Rule 3 — Layered context loading"; passed to the Skill in `brainstorming` mode, read directly by the millwright in `direct` mode):
    - **Required first reads:**
      1. `implementation/review-context.md` — compact snapshot of active scope, goals, implemented surface, open-findings cheat sheet
      2. `implementation/inspector-review.md` — canonical findings (re-read on `go again`)
    - **On-demand canonical files:**
      3. `blueprints/current/requirements.md` — full goals / planned / non-goals
      4. `blueprints/current/config.md` — full file (skills, rules, inspector additions)
      5. `blueprints/current/primer.md` — original stage-3 launch primer
      6. `quest/<active-slug>/summary.md` — feature-indexed digest; read `## Cross-cutting constraints` and `## Feature: <active>` first
  - post-conditions: review session is live (Skill in `brainstorming` mode, or main session in `direct` mode). `active.sub-flow=reviewing`, `active.current-stage=6`, `active.review-mode` recorded, `review-context.md` written. The inspector types `/mi-continue` to resume mi-workflow; the post-review-session resume handler in `/mi-continue` offers the diagram-refresh prompt when review-loop commits exist before atomically advancing 6 → 7 and auto-firing `/mi-complete-workflow`.

- `mi-complete-workflow`:
  - invocation: **auto-fired** by the millwright on stage-7 clean exit (`active.inspector-review-completed=true`), and by Pre-flight Row B for post-finish housekeeping recovery, and by the active-row stage-7 dispatch. Manually invokable for recovery.
  - behavior: Step 0 dispatches into one of five branches (per Item 6 of the v11 plan) so a partially-completed prior invocation can resume cleanly:
    - **Branch 0a — in-flight rotation matching completion.** `active != null` AND exactly one `v[K].partial/` exists for `active.feature` AND its `reason.md.kind == "completion"`. Resumes the partial via `blueprints.sh resume-partial --expected-kind completion`, skips Steps 1–4, proceeds Step 5 onward (Step 5 archival uses `mv -n` and is already idempotent — re-entry picks up cleanly even when Step 5 landed some artifacts before the prior crash).
    - **Branch 0b — different-kind partial blocks completion rotation.** `active != null` AND a `v[K].partial/` exists with a different `reason.md.kind`. Refuses with "finish or abandon that rotation first" guidance; no state mutation.
    - **Branch I — post-finish recovery (active=null).** `progress.completed[-1]` exists AND its latest finalized `v[N]/reason.md.kind == "completion"`. Reconstructs `active_feature` from `completed[-1]`, skips Steps 1–6, runs Step 7 housekeeping only. Does NOT call `progress.sh get` for active fields in this branch (active is null).
    - **Branch II — rotation already done (active!=null, finalized vN/).** `active != null` AND `blueprints/current/requirements.md` is missing AND latest finalized `v[N]/reason.md.kind == "completion"`. Sets `version=N` and resumes from Step 5.
    - **Branch III — normal forward path.** Falls through to Step 1 below. Before Step 4's completion rotate, runs `blueprints.sh check-current --require-primer "$active_feature"` and requires `0` (the completion rotation must never archive a `current/` tree missing the stage-3 primer; Item 9 of the v11 plan).
    Steps (when reached): (1) resolve inputs; (2) updates todo items IMPLEMENTING → IMPLEMENTED in the active cycle's `todo-list.md` via `todo.sh bulk-transition --feature` (CANCELED items left untouched; skipped on Branch I — the prior invocation already ran this); (3) populates **commits** field in `requirements.md` info section with commit ids/messages from `active.base-commit..HEAD` via `commits.sh populate-requirements`; (4) rotates `workflow-stream/[feature]/blueprints/current/` into `workflow-stream/[feature]/blueprints/history/v[N+1]/` via `blueprints.sh rotate --reason-kind completion` (moves every child of `current/` — requirements.md, config.md, diagrams/, primer.md — and writes reason.md); (5) **archives** `workflow-stream/[feature]/implementation/` into the just-rotated `blueprints/history/v[N+1]/implementation/` (moves inspector-review.md, review-context.md, change-summary.md, grounding-report.md, and diagrams/ into a sibling `implementation/` subfolder under the new history version — every finding, the review-context snapshot, change-summary, grounding-report, and implementation diagrams are preserved as part of the permanent audit record; `decisions.md` and the `test/` folder live at the feature root and are **not** rotated); (6) calls `progress.sh finish` — appends the active feature to `progress.md`'s `completed` and sets `active: null`; (7) housekeeping: **if `queue` is non-empty**, fires the **feature-A→feature-B clear-point gate** — recommends `/clear` to the inspector and HALTS before auto-firing `/mi-apply-impact` for `queue[0]` (one-shot gate, uses no tracking flag — a fresh session re-enters via `/mi-continue` Pre-flight Row A, which auto-fires `/mi-apply-impact` based on the `features − completed == queue` invariant). **If `queue` is empty AND the active cycle's `todo-list.md` still has unmarked `[ ] TODO` items**, the command tells the inspector to mark the next batch and type `/mi-continue` (the Pre-flight Handler will use `progress.sh enqueue` to repopulate the queue and resume from stage 1.5 without scrubbing the existing `progress.md`). If `queue` is empty AND no `[ ] TODO` items remain, the cycle is fully drained: the command calls `quest.sh end` to flip `quest/active.md` to `status=archived` (the per-cycle subfolder remains in place as a permanent archive) and recommends `/mi-run <folders>` for a new cycle. The chain's plan/spec files under `docs/superpowers/` are NOT touched — those are the chain's own artefacts.
  - inputs:
    1. config.md (`workflow-stream/[feature]/blueprints/current/config.md`)
    2. codebase
    3. commit range `active.base-commit..HEAD` (from `progress.md`)
    4. requirements.md (`workflow-stream/[feature]/blueprints/current/requirements.md`)
    5. progress.md (`millwright-inspector/quest/<active-slug>/progress.md`, resolved via `quest/active.md`)
  - post-conditions: workflow closed; ready for the next feature in the queue (or a new `mi-run` cycle). When the cycle drains, `quest/active.md` is archived and the per-cycle subfolder is preserved.

- `mi-abort-workflow` (**safe cancel**):
  - behavior: explicitly aborts the currently active workflow so state does not go stale. Preserves approved work (the blueprint) while rolling back in-flight work (implementation artifacts + todo state). Does **not** touch git — branches and commits are the inspector's to manage. The optional flag `--drop-feature=requeue` decides whether the active feature stays where it is (default; ready to retry from stage 2) or is appended to the end of the queue.
    1. parses `--drop-feature=` (if any) into `drop_mode`. Only `requeue` is accepted; `--drop-feature=completed` was removed (it bypassed canonical stage-8 work — no `commits:` populated, no blueprint rotation, no archival of `implementation/` artifacts — and produced state inconsistent with the schema's contract that "completed" means stage 8 was reached). To finalize a feature whose work has shipped, run `/mi-complete-workflow` directly.
    2. reverts IMPLEMENTING → PENDING for `$active_feature` only (scoped via `--feature`) so other in-flight features' todos are unaffected.
    3. **deletes** the contents of `workflow-stream/[feature]/implementation/` (inspector-review.md, review-context.md, change-summary.md, diagrams/). Abort represents abandoned in-flight work, not a shipped feature; the implementation artifacts are scratch by definition. (Contrast stage 8, which archives them into the newly rotated `blueprints/history/v[N+1]/implementation/` because the feature shipped.)
    4. updates progress.md based on `drop_mode`: `requeue` → `progress.sh requeue` (appends to `queue`, clears `active`); no flag → `progress.sh reset` (clears base-commit, execution-mode, *-completed flags; sets sub-flow=none; keeps `active.feature` and `active.branch`; sets `active.current-stage` = 2 so the inspector can retry).
    5. preserves `workflow-stream/[feature]/blueprints/current/` (the approved requirements + diagrams) — re-running the workflow does not re-do stages 0–2.
  - inputs:
    1. progress.md (`millwright-inspector/quest/<active-slug>/progress.md`, resolved via `quest/active.md`)
    2. optional flag `--drop-feature=requeue`
  - post-conditions: `active.current-stage` = 2 (default); next valid command is `mi-plan-implementation` (to retry stage 3 onward) or `mi-apply-impact` (to regenerate the blueprint from scratch if requirements changed). With `--drop-feature=requeue`, `active` is null and the next `mi-apply-impact` activates the next queued feature.

- `mi-resume-workflow` (**safe resume**):
  - behavior: diagnostic / dispatch command the inspector runs when unsure where a workflow left off. Reads `progress.md`, validates invariants, and prints a one-line summary plus the recommended next command. Does not mutate state by itself.
    1. if `active` is `null` and `queue` is non-empty: recommends `mi-apply-impact` for `queue[0]`.
    2. if `active` is set but `active.current-stage` < 3: recommends `mi-plan-implementation`.
    3. if `active.current-stage` = 3 and `active.sub-flow` = `chain-in-progress`: reminds the inspector that brainstorming is live; recommends continuing the chain in the current session or typing `/mi-continue` if the chain already ended.
    4. if `active.current-stage` = 4: recommends `/mi-continue` (the resume handler was interrupted; re-running it is idempotent). **Legacy state — should not appear in v11+:** the Resume Handler now finalizes via an atomic `progress.sh advance-to 3 5`, so `current-stage=4` only ever appears in old in-flight cycles that were activated before the v11 progress-gap plan shipped.
    5. if `active.current-stage` = 5: recommends writing findings to `inspector-review.md` and typing `/mi-continue`.
    6. if `active.current-stage` ∈ {6, 7}: recommends `/mi-continue`.
    7. if `active` is `null` and `queue` is empty: checks the active cycle's `todo-list.md` for unmarked `[ ] TODO` items. If any exist, recommends marking the next batch + `/mi-continue` (the Pre-flight Handler picks them up via `progress.sh enqueue`). If none remain, recommends a new `/mi-run`.
    8. on invariant violations (e.g., `active.sub-flow` = `chain-in-progress` but commits exist in `base-commit..HEAD`): surfaces the mismatch and recommends `/mi-continue` (which will resume) or `mi-abort-workflow` if state looks corrupt.
  - inputs:
    1. progress.md (`millwright-inspector/quest/<active-slug>/progress.md`, resolved via `quest/active.md`)
  - post-conditions: no state changes; a recommendation is printed.

- `mi-update-blueprint` (**manual blueprint refresh — implementation-driven**):
  - invocation: inspector types `/mi-update-blueprint [--reason-kind <manual|spec-update>] [--force-regen] <reason summary>` when they want to bring `blueprints/current/` back in sync with how the implementation has actually evolved (post-chain drift, mid-review changes, etc.) — without waiting for an auto-trigger. Also auto-fired by the Resume Handler's Step 4 drift gate with `--reason-kind=spec-update` so the rotation history correctly tags the trigger.
  - flags:
    - `--reason-kind` accepts `manual` (default) or `spec-update`. Other rotation kinds (`completion`, `re-spec-cascade`, `re-plan-cascade`) are owned by their owning commands (`/mi-complete-workflow`, the brainstorming review session) and refused here.
    - `--force-regen` discards `current/` content and regenerates from the latest history version even when `current/` is partially complete. Refuses when the latest history version is `completion` or a cascade kind (no safe parent to restore from). Used to recover from a corrupted in-flight regeneration when the inspector wants to start over from a known-good history snapshot.
  - behavior: (1) fails fast if `active` is null OR `active.base-commit` is null (this command is mid-cycle only — stage 3+); (1.5) **Step 1.5 recovery decision tree** runs **before** Step 2's rotate so a partial state from a previously-interrupted run cannot get archived into history (closes F2 in the v11 plan). All `check-current` calls in this command use `--require-primer`. The tree is unconditional on partial state: even with `--force-regen`, a partial `current/` is never silently rotated. Decision points: partial `.partial.tmp` / `.partial` directories handled first (resume or STOP); `check-current==1` (empty) + manual/spec-update parent → resume regen without rotate; `check-current==2` (partial) → STOP unconditionally (or `--force-regen` with safe parent); `check-current==1` with cascade / completion parent → recommend `/mi-resume-workflow`; `check-current==1` with no readable parent → STOP. (2) calls `blueprints.sh rotate --reason-kind "$reason_kind" --reason-summary "<inspector's text>"`, moving the previous blueprint into `history/v[N+1]/` and writing `reason.md`; (3) calls `blueprints.sh ensure-current`; (4) ensures `implementation/change-summary.md` is current via `commits.sh change-summary-fresh` (regenerates if stale or missing) and reads from it for implementation-reality context; (5) regenerates `requirements.md` / `config.md` / `diagrams/` / `primer.md` inline (see `commands/mi-update-blueprint.md` Step 4) — Goals + diagrams are re-derived from `change-summary.md` plus targeted diff hunks for the entrypoints it lists, while `## Planned`, `## Non-goals`, and frontmatter `todo-item-ids` / `todo-list-id` are copied verbatim from the previous `requirements.md` in history; (6) calls `blueprints.sh preserve-inspector-sections "$active_feature" "$version"` to splice `## GIT BRANCH` and `## Inspector Additions` from the previous `config.md` into the new one; (7) calls `review.sh sync-refs` to re-point any in-flight `inspector-review.md` / `review-context.md` / `change-summary.md` `requirements-id` frontmatter at the new UUID.
  - inputs:
    1. `<reason summary>` (required) — one-line explanation; lands in `reason.md`.
    2. `progress.md` — active feature + `base-commit` lookups.
    3. `implementation/change-summary.md` — cached analysis (reused if cache-fresh, regenerated otherwise).
    4. codebase + targeted `git diff base-commit..HEAD` hunks — source for re-derived Goals + diagrams (bounded by the policy in `mi-generate-implementation-diagrams.md` Step 2a).
    5. previous `blueprints/history/v[N+1]/requirements.md` and `config.md` — source for sections the implementation alone can't reconstruct (Planned / Non-goals / `todo-item-ids` / GIT BRANCH / Inspector Additions).
  - **NOT inputs (deliberately):** the active cycle's `todo-list.md` / `summary.md`, and `journal/`, are not consulted. Mid-cycle refreshes are reverse-engineered from the implementation; the journal and quest are intake artifacts that don't drift after stage 1.5.
  - post-conditions: `blueprints/history/v[N+1]/` has the prior content + `reason.md`; `blueprints/current/` holds fresh artifacts (including a regenerated `primer.md`); `change-summary.md` is current for the active range; inspector-authored sections survive verbatim; `inspector-review.md` / `review-context.md` / `change-summary.md` (if present) re-point at new ids. Does not change `current-stage` or any `*-completed` flags.

- `mi-update-todo-list` (**manual todo edits**):
  - invocation: inspector types `/mi-update-todo-list <subcommand> <args>` to manage items without waiting for stage-driven writes.
  - subcommands:
    1. `add <feature> <state> <assignee> <item-id> <description>` — append a new item under the feature's section (auto-creating the section if absent). `state ∈ {TODO, IMPLEMENTING, CANCELED}` only — `PENDING` and `IMPLEMENTED` are refused.
    2. `cancel <item-id>` — flips the item to CANCELED. Convenience alias for `set-state <id> CANCELED`.
    3. `set-state <item-id> <state>` — flips the item to `<state>`. Refuses `PENDING` (only `pend-selected` writes it) and `IMPLEMENTED` (only `mi-complete-workflow` writes it).
  - behavior: thin dispatcher over `scripts/todo.sh`; validates state transitions against the refused-states list and relays script stderr to the inspector. Never rotates blueprints, never alters `progress.md`.
  - inputs:
    1. `quest/<active-slug>/todo-list.md` (the file being edited).
  - post-conditions: `todo-list.md` updated; no other files touched. If the edit affects active-cycle scope (e.g., a mid-cycle `add ... IMPLEMENTING`), the inspector is reminded to follow up with `/mi-update-blueprint <reason>` if they want `requirements.md` / `config.md` / diagrams to reflect the change.

- `mi-manual-test-plan` (**stage-5 manual-testing — generator**):
  - invocation: **auto-fired** by `/mi-continue` Resume Step 7 with `--from-resume` when the inspector answers `y` to the manual-test offer; manually invokable while `current-stage=5`. Refuses outside stage 5.
  - behavior: generates `workflow-stream/[feature]/test/manual-test-plan.md` (schema `manual-test-plan`), enumerating inspector-runnable scenarios derived from `requirements.md` Goals + `change-summary.md` + open todos. On `--force` / `--discard-existing`, rotates the existing plan into `test/manual-test-plan.history/<timestamp>/` so prior plans survive as audit artifacts. Auto-rotates a prior-activation `manual-test-results.md` into `test/manual-test-results.history/<timestamp>/` before any prompt (Step 1, cross-activation guard). Sets `sub-flow=manual-testing`. Does NOT execute the plan — that is `/mi-manual-test-run`'s job.
  - inputs:
    1. `progress.md` — reads `active.feature`, `active.current-stage`; writes `sub-flow=manual-testing`.
    2. `blueprints/current/requirements.md` — Goals as scenario seeds.
    3. `implementation/change-summary.md` — implemented surface; ensures freshness via `commits.sh change-summary-fresh`.
    4. `quest/<active-slug>/todo-list.md` — IMPLEMENTING/IMPLEMENTED items for the active feature.
  - post-conditions: `manual-test-plan.md` written; `sub-flow=manual-testing`. `manual-test-state` left at default (transitions on `/mi-manual-test-run`).

- `mi-manual-test-run` (**stage-5 manual-testing — executor + auto-seeder**):
  - invocation: **auto-fired** by Resume Step 7 immediately after `/mi-manual-test-plan` succeeds; auto-fired by the Manual-Test-Resume Handler on re-entry; manually invokable. The single owner of mutations to `inspector-review.md` from manual-test results.
  - behavior: walks the plan's scenarios, captures per-scenario outcomes into `manual-test-results.md` (schema `manual-test-results`, with `state ∈ {in-progress, complete}`, `current-scenario` cursor, `plan-id`, `seed-family-id`, counts). On a failure under `failure-policy=auto-seed`, calls `review.sh upsert-manual-test-failure` to seed an `### IR-NNN` finding with deterministic `seed-id: manual-test:<seed-family-id>:<scenario-id>` (idempotent across re-runs); under `manual` policy, prints the failure and lets the inspector hand-author the finding. `--seed-only` is the recovery shape used when results exist but seeding never completed (Manual-Test-Resume Handler Branch B). When the run reaches `complete` (or the inspector skips), restores `sub-flow=none`.
  - inputs:
    1. `manual-test-plan.md` — the plan.
    2. `manual-test-results.md` — read for `current-scenario` cursor on re-entry.
    3. `progress.md` — reads `active.feature`, `manual-test-failure-policy`; writes `manual-test-state`, clears `sub-flow` on completion.
  - post-conditions: `manual-test-results.md` populated; on `auto-seed` failures, `### IR-NNN` blocks seeded into `inspector-review.md` with stable `seed-id`s.

- `mi-export-bundle` (**bundle export for fresh-agent paste**):
  - invocation: inspector types `/mi-export-bundle` any time an active cycle + active feature exists.
  - behavior: extracts (does NOT synthesize) the active feature's current state into a single self-contained markdown file at `tmp/bundles/<feature>-stage<N>-<timestamp>.md`. Sections: requirements, scope, custom project instructions, project constraints, feature background, decisions, codebase-context audit, implementation summary, changed-files index, manual-test results, open review findings. Strips frontmatter / HTML scaffolding / template placeholders / workflow file paths. Excludes diagrams, diffs, prose synthesis. Pre-flight refusals (in order): no active cycle / no active feature / worktree fingerprint mismatch — must precede any `mkdir -p tmp/bundles`. Auto-writes `tmp/bundles/.gitignore` so bundles stay out of source control. Engine: `scripts/bundle.sh export` (the only subcommand in v1).
  - inputs: every readable workflow artifact for the active feature (no positional args).
  - post-conditions: bundle file written under `tmp/bundles/`; nothing else touched.

- `mi-init-status-bar` (**status-line wiring**):
  - invocation: inspector types `/mi-init-status-bar [--user|--project-shared] [--plugin-root <abs>]`, once per workspace (or whenever the wiring is lost). Idempotent.
  - behavior: writes a generated wrapper at `.claude/mi-stage-info-bar.sh` with the plugin's absolute path baked in (necessary because Claude Code does NOT expand `$CLAUDE_PLUGIN_ROOT` inside `statusLine.command`), then writes the matching `statusLine.command` block to settings.json. Default target: project-local `.claude/settings.local.json`. `--user` writes to `~/.claude/settings.json`; `--project-shared` writes to `.claude/settings.json` (warns and requires confirmation because the file is committed to source). The renderer itself (`scripts/info-bar.sh`) is **pull-only** — Claude Code calls it on its status-line cadence; it reads stdin JSON, anchors to `workspace.project_dir`, parses `quest/active.md` + `progress.md` once via a single `python3 -S -I` invocation, prints one line, exits 0. Hot-path target ≤100 ms. Always exits 0 (Claude Code surfaces stderr from a failing `statusLine`, which would visually break the prompt).

    Display:
    - Active feature, stages 2–7: `mi-workflow · <feature> · Stage <N> · <stage-name>`.
    - No active feature (`active=null`), cycle present: `mi-workflow · cycle <slug> · Stage 1 · quest generated`.
    - No active cycle: `mi-workflow · idle`.
    - Outside an mi-workspace: empty output.

    An earlier "status-bar" feature (PostToolUse hook + JSON sidecar + NDJSON usage log for token tracking) was removed in v0.7.4 and replaced by this pull-only renderer in v0.7.5.

## Worked example: a single feature, end-to-end

The walkthrough below traces one feature (`auth`) through every stage with one finding addressed in a brainstorming review session. Every line is either an inspector action or a millwright action; nothing is omitted.

```
[Inspector]   Drops journal/auth-meeting/{transcript.txt, notes.md}.
[Inspector]   Types: /mi-init                                       # one-time setup
[Millwright] Installs deps via single y/n; scaffolds journal/, quest/, workflow-stream/.

[Inspector]   Types: /mi-run auth-meeting
[Millwright] Runs doctor preflight; computes slug 2026-04-27-auth-meeting via quest.sh slug;
             calls quest.sh start to update quest/active.md; generates
             quest/2026-04-27-auth-meeting/{todo-list.md, summary.md, progress.md}
             (active=null, queue=[auth]).

[Inspector]   Edits quest/2026-04-27-auth-meeting/todo-list.md: marks AUTH-001 and AUTH-002
             with [x] (emin).
[Inspector]   Types: /mi-continue                                   # stage 1.5 step A
[Millwright] todo.sh pend-selected; groups PENDING by feature; proposes order: [auth].

[Inspector]   Types: /mi-continue                                   # stage 1.5 step B (accept)
[Millwright] Writes quest/2026-04-27-auth-meeting/queue-rationale.md; progress.sh reorder;
             auto-fires /mi-apply-impact.

[Millwright] /mi-apply-impact: progress.sh activate (auth → active block).
             Generates blueprints/current/requirements.md (Goals/Planned/Non-goals),
             config.md (auto skills+rules block, ## GIT BRANCH pre-filled with HEAD
             feat/auth/jwt, ## Inspector Additions placeholder), and use-case +
             sequence diagrams under diagrams/.
[Inspector]   Reviews blueprint files; adds custom prompts under ## Inspector Additions.

[Inspector]   Types: /mi-continue                                   # stage 2 approve
[Millwright] Approve Handler validates blueprint files; auto-fires /mi-plan-implementation.
[Millwright] /mi-plan-implementation: PENDING → IMPLEMENTING; captures base-commit;
             validates ## GIT BRANCH (matches HEAD, not main/master); writes primer.md;
             asks: "planning-mode? brainstorming or direct?"
[Inspector]   Types: brainstorming
[Millwright] Persists planning-mode=brainstorming; sets sub-flow=chain-in-progress;
             invokes brainstorming Skill (isolated session) with primer.md as required first read.

[Inspector + chain]
             brainstorming → writing-plans → executing-plans → subagent-driven-development
             → finishing-a-development-branch. Commits land on feat/auth/jwt.

[Inspector]   Types: /mi-continue                                   # stage 3 → 5 (atomic; 4 not persisted)
[Millwright] Resume Handler: Step 0 drift-completion probe (no spec-update history,
             baseline captured, probe disables itself); Step 1 verifies commits in
             base-commit..HEAD; Step 2 sets sub-flow=resuming and
             implementation-completed=true (idempotent); Step 2.5 no abandoned-chain
             plan candidates; Step 3 asks for blueprint-drift reason.
[Inspector]   Types: continue                                       # no drift (alternatives: <reason> or auto)
[Millwright] Step 4 sets drift-check-completed=true (split marker write).
             Step 5 auto-fires /mi-draw-diagrams (renders implementation diagrams with
             blue/green existing-vs-new framing). Step 6 initializes inspector-review.md
             skeleton via review.sh init. Step 7 manual-test offer: "Run manual testing now? (y/n)".
[Inspector]   Types: n                                              # skip manual-test sub-flow
[Millwright] Atomic finalize: progress.sh advance-to 3 5 --set sub-flow=none.
             Prints stage-5 handoff message.

[Inspector]   Reviews implementation/diagrams/ + the diff; edits inspector-review.md
             with a free-form sentence:
                "The JWT signing function in auth/jwt.ts hard-codes HS256;
                 it should be configurable via config."

[Inspector]   Types: /mi-continue                                   # stage 5
[Millwright] Inspector Handler: review.sh canonicalize finds the freeform span;
             classifies severity=major, scope=re-implement; review.sh add creates IR-001
             with the original sentence preserved as `details`; review.sh strip-freeform
             removes the source line. review.sh list-open returns ["IR-001"].
             Auto-fires /mi-review.
[Millwright] /mi-review writes review-context.md; sets sub-flow=reviewing;
             advances 5 → 6; asks: "review-mode? brainstorming or direct?"
[Inspector]   Types: brainstorming
[Millwright] Invokes brainstorming Skill (isolated review session) with
             review-context.md + inspector-review.md as required first reads.

[Inspector + chain]
             Chain reads IR-001, classifies as re-implement, edits auth/jwt.ts to
             accept a config-driven algorithm, commits. review.sh set-status IR-001
             fixed. Asks inspector for approval.
[Inspector]   Types: approve

[Inspector]   Types: /mi-continue                                   # stage 6 → 7 → 8
[Millwright] Review-Resume Handler: list-open is empty;
             prompts y/n to confirm completing the inspector-review stage.
[Inspector]   Types: y                                              # confirm completion
[Millwright] Offers diagram refresh (review-loop commits exist).
[Inspector]   Types: y                                              # diagram refresh
[Millwright] Re-runs /mi-draw-diagrams. Atomic finalize:
             progress.sh advance-to 6 7 --set sub-flow=none --set inspector-review-completed=true.
             Auto-fires /mi-complete-workflow.

[Millwright] /mi-complete-workflow:
               todo.sh bulk-transition IMPLEMENTING IMPLEMENTED --feature auth;
               commits.sh populate-requirements auth (writes commits: field);
               blueprints.sh rotate auth --reason-kind completion
                 (current/* → history/v1/, with reason.md);
               archives implementation/{inspector-review.md, review-context.md,
                                         change-summary.md, grounding-report.md, diagrams/}
                 into history/v1/implementation/ (preserved as audit record;
                 manual-test artifacts skipped here because the manual-test sub-flow
                 was declined; decisions.md stays at the feature root);
               progress.sh finish (auth → completed; active = null).
             Queue is empty; checks todo-list.md for unmarked [ ] TODO. None remain.
             Cycle drained — calls quest.sh end (status=archived; subfolder
             quest/2026-04-27-auth-meeting/ is preserved as a permanent archive).
             Recommends /mi-run for the next cycle.
```

**Inspector touchpoints in this run:** `/mi-init`, `/mi-run auth-meeting`, edit todo-list, `/mi-continue`, `/mi-continue`, edit `## Inspector Additions`, `/mi-continue`, `brainstorming`, drove the chain, `/mi-continue`, `continue` (drift skip), `n` (manual-test skip), edit `inspector-review.md`, `/mi-continue`, `brainstorming`, drove the review session, `approve`, `/mi-continue`, `y` (completion confirmation), `y` (diagram refresh).

**Clear-point recommendations** also fire at stage-2→3, stage-5→6, and feature-A→feature-B in any multi-feature run — the millwright recommends `/clear` to the inspector at each gate (Claude Code does not let agents invoke `/clear` programmatically).

**Millwright auto-actions:** `/mi-apply-impact`, `/mi-plan-implementation`, `/mi-draw-diagrams`, `/mi-review`, `/mi-draw-diagrams` (refresh), `/mi-complete-workflow`, plus every `progress.sh` / `todo.sh` / `blueprints.sh` / `review.sh` / `commits.sh` invocation.

## Main-read budget gates by stage

Phase 6.3 of the context-optimization plan. Each stage's command body has an explicit budget for what the **main agent** is allowed to read directly. Reads outside the budget must be delegated to a fresh sub-agent (see `docs/sub-agent-return-contract.md`) or surface an explicit override prompt to the inspector. Override prompts should be rare and intentional — they signal scope creep that needs review.

| Stage | Command(s) | Allowed main reads | Forbidden in main (delegated) |
| --- | --- | --- | --- |
| 1 | `/mi-run` | Journal files (per Step 2.5 size policy — large files / many-small-folders delegated) | Source code |
| 1.5 | `/mi-continue` Pre-flight | `summary.md` (cached from stage 1), `todo-list.md`, `progress.md` | Source code (delegated under Option 1B if heuristic flags ambiguity) |
| 2 | `/mi-apply-impact` | `summary.md` (active feature section + cross-cutting only), generated artifacts | Codebase grounding pass — delegated to fresh sub-agent (Phase 2.1) |
| 3 | `/mi-plan-implementation` | `primer.md`, brainstorming Skill outputs | Bulk source reads — handled by chain, with `subagent-driven-development` encouraged for tasks >3 files or >100 LOC (Phase 5.3 hints) |
| 4 | `/mi-continue` Resume, `/mi-draw-diagrams`, `/mi-generate-implementation-diagrams` | `change-summary.md` (cached), `progress.md`, drift-probe filesystem state | Diagram-source generation reads — delegated (Phase 3.1) |
| 5 | `/mi-continue` Inspector | `inspector-review.md`, `progress.md` | (none significant — stage is small) |
| 6 | `/mi-review` | `review-context.md`, `inspector-review.md` (open IR-IDs only via excerpt command — Phase 6.5) | Source reads for findings — delegated to per-iteration sub-agent unless `direct` mode + all findings are `fix` (Phase 1.3, 1.2) |
| 7 | `/mi-continue` Review-Resume | `progress.md` | (none significant — auto-advance only) |
| 8 | `/mi-complete-workflow` | `change-summary.md`, archived blueprint files | Codebase regeneration walk — currently absent from `/mi-complete-workflow` (only rotates + archives); a future stage-8 regen would delegate |

**Enforcement model.** The current implementation documents the budget as a contract; runtime self-checks (programmatic detection of "am I about to read source code?") are out of scope for the initial Phase 6.3 work. Each stage-related command file references this table and identifies its specific row. A future iteration can add hook-style enforcement; for now, the table serves as the contract for code review and as the regression-detection oracle for the `context-ledger.md` telemetry artifact (Phase 6.4) — a `large` class read with `location: main` in a stage that forbids it surfaces in the ledger as a budget violation.

**Migration note.** Existing commands that violate their budget (most prominently the pre-Phase-4 `commands/mi-continue.md` Pre-flight Step 2A item 4 codebase grep, the pre-Phase-2.1 `commands/mi-apply-impact.md` Step A grounding pass, and the pre-Phase-1.3 `commands/mi-review.md` Step 3a chain primer) have been updated. New commands should consult this table at design time and document their row.

## Glossary

Quick reference for terms used throughout this spec.

- **Active block** — the populated `active:` section of `progress.md` while a feature is mid-cycle. Null between features.
- **Base-commit** — git SHA captured at stage 3 just before chain launch / direct implementation. The lower bound of the implementation diff. Recorded in `progress.md`'s `active.base-commit`.
- **Blueprint** — the `requirements.md` + `config.md` + `primer.md` + `diagrams/` set under `blueprints/current/` for the active feature. Rotates into `blueprints/history/v[N]/` on each refresh.
- **Brainstorming chain** — the isolated session running `brainstorming` → `writing-plans` → `executing-plans` (or `subagent-driven-development`) → `finishing-a-development-branch` at stage 3. Mi-workflow does not interfere with it.
- **Brainstorming review session** — the isolated session running the `brainstorming` Skill at stage 6 to address findings. Same isolation model as the stage-3 chain.
- **Canonicalize** — convert a free-form finding sentence in `inspector-review.md` into a structured `### IR-NNN` block, via `review.sh canonicalize` + the millwright's classification + `review.sh add` + `review.sh strip-freeform`.
- **Cycle** — the lifespan of a single per-cycle subfolder under `quest/<slug>/`, from `/mi-run` (which creates the subfolder and points `quest/active.md` at it) to all features in the queue completed and all `[ ] TODO` items addressed (or the cycle aborted). At cycle end, `quest.sh end` flips `quest/active.md` to `status=archived`; the subfolder is preserved permanently as a task archive that PMs can query.
- **Direct mode** — planning-mode or review-mode that keeps work in the main session instead of invoking a Skill. The millwright reads the primer and implements / addresses findings inline.
- **Drift check** — the post-chain prompt at stage 4 asking the inspector whether the requirements changed during brainstorming. Three valid replies: a `<reason>` (invokes `/mi-update-blueprint --reason-kind=spec-update <reason>`); `auto` (the millwright analyzes drift itself against `requirements.md` + the diff and either invokes `/mi-update-blueprint` with a derived reason or skips when nothing meaningful changed); or `continue` (skip drift; surface as findings later).
- **Existing-vs-new framing** — two-colour visual convention in stage-2 blueprint and stage-4 implementation diagrams: blue (`#D6EAF8` fill, `#3498DB` strokes) for pre-existing system elements, green (`#D4EDDA` fill, `#27AE60` strokes) for new / to-be-implemented elements. Legend wording adapts to cycle flavor; colours stay constant.
- **Findings file** — `implementation/inspector-review.md`. Holds `### IR-NNN` finding blocks.
- **History version (vN)** — a snapshot of `blueprints/current/` rotated into `blueprints/history/vN/` with a sibling `reason.md` recording why.
- **IR-NNN** — finding identifier in `inspector-review.md`. Zero-padded to three digits, monotonically increasing across the whole review file, never reused.
- **Layered load** — the primer-first context discipline (Rule 3). Long-running stages read a compact primer first and escalate to canonical files only on demand.
- **Millwright** — the AI agent role (Claude Code's main session).
- **Inspector** — the human role.
- **Planning-mode / review-mode** — the inspector's choice between `brainstorming` (isolated Skill session) and `direct` (main-session work) at stages 3 and 6 respectively.
- **Primer** — a compact derived snapshot file (`primer.md`, `review-context.md`) that bootstraps a long-running stage. Derived from canonical files; canonical files win on conflict.
- **Quest** — the cycle-wide working state under `quest/<slug>/`: `todo-list.md`, `summary.md`, `progress.md`, `queue-rationale.md`. Each `/mi-run` creates a fresh per-cycle subfolder; the top-level `quest/active.md` pointer (slug + status) names the active one. Historical subfolders are kept indefinitely as a permanent task archive.
- **re-spec / re-plan / re-implement / fix** — the four scope tiers for a finding, in descending order of chain impact. Higher tiers supersede lower tiers in the same review pass.
- **Stage** — one of 0–8 in the canonical workflow. Stage 1.5 is implicit (Pre-flight Handler) but referenced throughout. Stage 4 is conceptual — the Resume Handler runs "stage 4" work but `current-stage` never persists 4 (the handler ends with an atomic `progress.sh advance-to 3 5`).
- **`progress.sh advance-to`** — atomic skip-transition with a stage-pair whitelist (`3→5`, `5→7`, `6→7`). Accepts zero or more `--set field=value` arguments applied in the same atomic write so `current-stage` skips and runtime-flag updates either all land or none do. Adjacent transitions still use `progress.sh advance` (which catches typo'd targets via the off-by-one check).
- **Drift-completion probe** — Resume Handler Step 0. Detects the case where a prior `/mi-update-blueprint --reason-kind=spec-update` rotated + regenerated successfully but the marker write was lost to a session break. Walks `blueprints/history/v[K] > history-baseline-version` looking for `reason.kind == "spec-update"`; if found AND `check-current --require-primer == 0`, persists `drift-check-completed=true` and skips Step 3.
- **Worktree-fingerprint guard** — `mi_assert_worktree_match` (in `scripts/internal/common.sh`) compares the current `pwd` / `git rev-parse --git-common-dir` / `git rev-parse --git-dir` against the immutable `worktree-path` / `git-common-dir` / `git-worktree-dir` recorded in `progress.md.active` at stage-2 activation. Every state-mutating subcommand of `progress.sh` calls it before writing; `progress.sh check-worktree` exposes the same gate for command markdowns to fail fast.
- **Multi-batch queue-rationale** — `queue-rationale.md` body holds one or more `## Batch <N>` (level-2) headings, one per ordering decision in the cycle; top-level frontmatter `status: draft | confirmed` and `batch: integer` describe the latest batch only, while `features:` is the cumulative ordered list across all confirmed batches. Drives the dispatcher's draft-confirmation row, between-features Row A, and Pre-flight Step 2A's mid-cycle re-entry.
- **Resumable rotation** — `blueprints.sh rotate` follows a `.partial.tmp → .partial → vN` flow so a session break between any two file-system steps leaves a recoverable state. On re-entry, a single `.partial` is resumed only when its `reason.md.kind` matches the requested `--reason-kind`; the cross-product STOP refuses when more than one partial exists. `blueprints.sh resume-partial --expected-kind <kind>` is the kind-asserting helper used by `mi-complete-workflow`'s Branch 0a.
- **Sub-flow** — `none | chain-in-progress | resuming | reviewing | manual-testing` — secondary state dimension on top of `active.current-stage` for tracking isolated-session handoffs and the optional stage-5 manual-test sub-flow.
- **Manual-testing sub-flow** — optional stage-5 sub-flow exercising the implemented surface against an inspector-runnable test plan before findings authoring. Two commands (`/mi-manual-test-plan` generator, `/mi-manual-test-run` executor + auto-seeder), two `progress.md.active` fields (`manual-test-state`, `manual-test-failure-policy`), and feature-permanent artifacts under `test/` (`manual-test-plan.md`, `manual-test-results.md`, `manual-test-plan.history/`, `manual-test-results.history/`). The `test/` folder survives stage 8 and abort so cross-cycle reuse is supported; the `generated-in-activation` field on plan and results frontmatter (paired with `progress.md.active.activation-id`) is the cross-activation discriminator that drives the §4.1 auto-rotation guard. Failed scenarios under `auto-seed` policy become `### IR-NNN` findings via deterministic `seed-id: manual-test:<seed-family-id>:<scenario-id>`. Implemented as a sub-flow rather than a new stage 4.5. See `docs/manual-testing-folder/plan.md` for the test-folder relocation + cross-cycle reuse design.
- **Clear-point** — a recommendation by the millwright to type `/clear` (start a fresh Claude Code session) at a high-context-payoff transition. Three points fire: `stage-2-to-3` (Approve Handler Step 2), `stage-5-to-6` (top of `/mi-review`), and feature-A→feature-B (`/mi-complete-workflow` Step 7 housekeeping when the queue is non-empty). The first two record the identifier in `progress.md.active.clear-recommendations` so re-entry doesn't re-prompt; the third is one-shot. Claude Code does NOT let agents invoke `/clear` programmatically — these are recommendations to the inspector.
- **Decisions log (`decisions.md`)** — feature-scoped, append-only markdown file at `workflow-stream/<feature>/decisions.md`. Lives at the feature root, NOT inside `blueprints/current/`; excluded from blueprint history rotation by design so it persists across blueprint regenerations and across the feature's whole lifetime. Body is organized under stage-named H2 headings.
- **Context ledger (`context-ledger.md`)** — per-cycle telemetry artifact at `quest/<active-slug>/context-ledger.md`. Body has an `## Events` table whose rows record the size class (`small | medium | large`) and location (`main | sub-agent | fork`) of every context-heavy read so a `large + main` row visibly signals a budget regression. Written via `scripts/ledger.sh append`; append failures warn but don't block.
- **Grounding report (`grounding-report.md`)** — stage-2 codebase-grounding snapshot at `implementation/grounding-report.md`. Written by the `codebase-grounder` sub-agent during `mi-apply-impact` Step A / Phase 2.1 before the `requirements.md` body is composed. Carries per-item seam findings and an overall `seam-classification` (`backend | frontend | mixed | infra`) that drives the optional structural-diagram decision in Step C. Archived alongside the rest of `implementation/` at stage 8.
- **Stage info-bar** — pull-only Claude Code `statusLine` renderer at `scripts/info-bar.sh`. Wired by `/mi-init-status-bar` (which writes `.claude/mi-stage-info-bar.sh` and a `statusLine.command` block in settings.json). NOT a hook; reads stdin JSON, prints one line, exits 0. The earlier "status-bar" feature (PostToolUse hook + JSON sidecar + NDJSON usage log) was removed in v0.7.4 and replaced by this pull-only renderer in v0.7.5.
- **Export bundle** — single self-contained markdown file produced by `/mi-export-bundle` at `tmp/bundles/<feature>-stage<N>-<timestamp>.md` for pasting into a fresh agent that lacks plugin/data access. Extraction-only, no synthesis. Engine: `scripts/bundle.sh export`.
- **Sub-agent profiles** — first-class agent definitions under `agents/` (introduced v0.6.0). Seven profiles: `journal-file-digester`, `journal-folder-digester`, `dependency-mapper`, `codebase-grounder`, `blueprint-diagrammer`, `implementation-analyst`, `review-iteration-runner`. See "Delegation guidance (sub-agent profiles)" earlier in this spec for the full table.
- **Workflow stream** — the per-feature folder tree under `workflow-stream/<feature>/` containing `blueprints/` (with `current/` + `history/`) and `implementation/`.
- **Software 3.0** — Programming-as-prompting. The view that with capable LLMs, the context window is the new lever; curated text files replace explicit code as the primary programmable surface. Operationalized here through Rule 1 (file-based inputs) and Rule 3 (layered context loading).
- **Vibe coding** — Letting an AI agent land an implementation against an unwritten or informal spec with no structured review. **The mi-workflow is explicitly not vibe coding** — even `planning-mode: direct` keeps the stage-2 spec, the primer, the stage-4 diagrams, the structured findings file, and the rotation history.
- **Agentic engineering** — Coordinating agents to ship production-quality software faster without lowering the quality bar. **This plugin operates entirely in the agentic-engineering paradigm**, in both planning modes; the brainstorming chain, gated review, structured findings file, and rotation history are agentic-engineering primitives.
- **Jagged intelligence** — The unevenness in LLM capability across tasks (fluent on RL-trained domains, brittle on out-of-distribution ones). Drives the plugin's defensive recovery branches: the drift-completion probe, atomic `advance-to`, resumable rotations, the five-branch `mi-complete-workflow` dispatch, the worktree-fingerprint guard.
- **Verifiable artifact** — A workflow output checkable against a finite contract — `requirements.md.commits`, the blue/green diagrams, `IR-NNN` findings, the `base-commit..HEAD` diff. The plugin is built so every cycle ends with a set of these, not just code.
