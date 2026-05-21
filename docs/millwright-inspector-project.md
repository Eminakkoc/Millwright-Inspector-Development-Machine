# Millwright-Inspector Development Machine — Project & Workflow Reference

> **Purpose of this document.** A self-contained, in-depth briefing for AI agents (or
> new human collaborators) who need a complete mental model of this project without
> crawling the codebase. It explains the philosophy, the actors, the data flow, every
> command, every stage, and every supporting script, schema, and sub-agent. Optimized
> for context-pasting into another agent's working memory.
>
> **Provenance.** This file is the single source of truth for the project. It supersedes
> and replaces the former `docs/project-report.md` (detailed report) and
> `docs/workflow-spec.md` (workflow specification), which have been merged here. It
> describes plugin **v1.1.0**. For the end-to-end sequence diagram see
> [`docs/diagrams/workflow-sequence.svg`](./diagrams/workflow-sequence.svg); for
> per-stage diagrams see [`docs/agents-and-contexts/`](./agents-and-contexts/).

---

## 1. Introduction — the philosophy

### 1.1 Why this project exists

Software development has historically revolved around a single primary artifact: **the
codebase**. Everything else — requirement documents from project managers, ticket queues
in JIRA / Linear, design hand-off in Figma, sprint planning, code-review comments — was
*connective tissue* whose only job was to feed the human developer enough context to
write code. The developer was the bottleneck and the only authoritative author of the
product.

Capable AI coding agents collapse that center of gravity. The agent can read requirement
documents and meeting transcripts directly, design APIs, draw diagrams, write specs,
implement features end-to-end, and even self-review its own code. This forces a question
many developers find disorienting: **if the AI can do all of that, what is left for the
developer to do?** The Millwright-Inspector plugin proposes a clean answer — the
developer's role is *renamed and reframed*, not eliminated. Two new roles replace the
legacy "developer + project manager + reviewer" stack:

1. **The Millwright** — an AI coding agent (Claude Code) that does the building. The name
   is borrowed from factory life: a millwright builds, maintains, and repairs the heavy
   machines that produce a factory's output. In software, the codebase is the factory and
   each module/feature is a machine. The AI agent is the modern millwright.
2. **The Inspector** — a human who supplies raw materials (specs, notes, transcripts),
   defines the work, and reviews every artifact the millwright produces at every stage.
   The inspector never writes production code; their authority is exercised through
   documents, prompts, and approvals.

The naming is intentional. "Developer" carried so much accumulated meaning (architect,
coder, tester, debugger, reviewer) that calling the human a developer in this new world
would be misleading. Calling the AI a "developer" would also feed the toxic narrative
that "AI took the developer's job." Renaming both sides separates the *activity* from the
*historical identity*. In this approach the coding part is delegated to the AI completely;
the inspector does not interfere with generated code — they give specs, rules, and tools,
and review the output. The codebase is now just another item in the context alongside the
`.md` files in the control-room folder.

### 1.2 The reform of tooling and artifacts

If the AI agent can read, design, and write directly from raw inputs, many tools that
used to live around the codebase become unnecessary or transform:

- **Design hand-off tools** are replaced by direct MCP integrations or design-to-code
  generation (e.g. a Figma MCP).
- **Requirement documents** no longer need a project manager / business analyst to
  mediate between customer and developer. Customer voice memos become prompts; meeting
  transcripts go straight into the journal; even a vibe-coded prototype can serve as an
  input.
- **Task-management tools** (JIRA, Linear) are no longer the single source of truth.
  Tasks live in the active cycle's `todo-list.md` next to the codebase, and every past
  cycle's `todo-list.md` is preserved permanently in its dated subfolder under `quest/`
  as a queryable archive. PMs query the artifacts via natural-language prompts to their
  own agents ("summarize what mobile shipped today", "is the loyalty feature done?",
  "how does it interact with auth?"). The `.md` files alongside the code are the answer
  surface.
- **Pull-request review tools** are augmented by structured review files
  (`inspector-review.md`) the millwright re-reads on every iteration, and by
  `/mi-analyze-review`, which turns a GitHub PR review into a triaged work list.

The result: only **two** primary components matter — the **codebase** and the
**control-room folder** (default `millwright-inspector/`). Everything the workflow needs
to remember lives on disk in plain Markdown so it survives session breaks, model swaps,
and even days-long pauses.

### 1.3 Core operating principles

Three rules are stamped into every command and stage (detailed in §4):

1. **Inputs live in files, not in conversation context.** Context is ephemeral; sessions
   break and get compacted. Every inspector-supplied value (branch name, approval,
   finding) is captured to disk the moment it arrives. Each command's inputs list is a
   *file-path contract*, not a parameter list.
2. **Documents cross-link via UUIDs; paths are just navigation hints.** Every generated
   `.md` carries a UUID v4 in its frontmatter; cross-references point at IDs, not paths.
   That gives grep-based discovery, rename-safety, and a clean audit trail. UUIDs are
   minted by `scripts/uuid.sh`, never by the AI directly, to eliminate hallucinated IDs.
3. **Layered context loading.** Long-running stages (planning, review) are entered through
   a small *primer* file rather than by re-reading every canonical file. The chain reads
   the primer first and escalates to canonical files only when a gap surfaces. This keeps
   token consumption bounded across multi-day workflows.

A fourth implicit rule: **every artifact is auditable**. Blueprints are rotated into
`blueprints/history/v[N]/` on each refresh with a sibling `reason.md` explaining *why*;
the live `implementation/` folder is archived alongside on stage-8 completion. Quest
cycles live in dated `quest/<slug>/` subfolders that are never overwritten and never
deleted. Findings keep monotonically increasing `IR-NNN` ids that never reset. **Nothing
is ever silently overwritten** — PMs can read the complete history of any past cycle from
a single feature-version folder.

### 1.4 Alignment with Software 3.0 / agentic engineering

The mi-workflow's design predates much of the current vocabulary around agentic AI
engineering, but several recurring concepts map directly onto its load-bearing decisions.
The mapping is descriptive, not prescriptive — the plugin works the same whether or not
the operator buys into any framing — but it explains *why* the choices were made.

- **Programming is prompting; the context window is the lever.** Rule 1 and Rule 3
  operationalize the Software 3.0 view that prompts and curated context are the new
  programming surface. Every artifact under `workflow-stream/<feature>/`
  (`requirements.md`, `config.md`, `primer.md`, `review-context.md`, `change-summary.md`)
  is a deliberately-sized context window for a specific stage's LLM consumer. The
  `commands/mi-*.md` files are themselves prompts — text the agent reads and follows.
- **Agent-native infrastructure.** Every runbook lives in `commands/*.md`; every workflow
  `.md` carries YAML frontmatter validated by schema; the central state lives in a single
  LLM-legible `progress.md` rather than a database. The PostToolUse validation hook fails
  the turn the moment an LLM writes invalid YAML — an artifact only exists if it is
  parsable by the next consumer.
- **Agentic engineering, not vibe coding — in both planning modes.** Every feature cycle
  goes through stage-2 spec review, stage-3 primer composition, stage-4 implementation
  diagrams, stage-5 structured findings, an optional stage-6 review session, and stage-8
  blueprint rotation + archival. None of those gates is optional. The two planning modes
  differ only in *how the implementation work is run*: `planning-mode: brainstorming`
  invokes the brainstorming → writing-plans → executing-plans → finishing-a-development-branch
  chain in an isolated session; `planning-mode: direct` keeps implementation in the main
  session with the millwright reading `primer.md` first. Direct mode trades the chain's
  internal ceremony for speed; it does **not** trade away the spec, diagrams, findings
  file, or rotation history. Vibe coding — landing an implementation against an unwritten
  spec with no structured review — is explicitly not what this plugin does.
- **Verifiability as a design principle.** Every cycle produces verifiable artifacts:
  `requirements.md`'s `commits:` field (populated at stage 8) closes the loop between spec
  and diff; stage-2 and stage-4 diagrams share the blue/green existing-vs-new convention
  so intent-vs-reality diffs are visual; `inspector-review.md` is structured by a finite
  scope-tier ladder (`fix | re-implement | re-plan | re-spec`); the commit range
  `base-commit..HEAD` is the single canonical implementation contract.
- **Jaggedness as a safety constraint.** Modern LLMs are jagged — peaking on trained tasks,
  breaking on superficially-similar edge cases. Almost every recovery branch exists because
  of this: the Resume Handler's drift-completion probe, atomic `progress.sh advance-to`
  skip-transitions, resumable rotations (`.partial.tmp → .partial → vN`),
  `mi-complete-workflow`'s five-branch dispatch, the worktree-fingerprint guard, the
  frontmatter-validation hook, and the mandatory inspector gates. The plugin never trusts
  a single transition.
- **Outsource thinking, not understanding.** The two-role split keeps the human in the
  loop for every spec, change, and approval. The plugin never lets the millwright
  self-approve; `direct` mode does not lower this bar — it just removes the
  brainstorming-chain ceremony.
- **Layered, projected information as agent context.** `summary.md` (feature-indexed),
  `primer.md` (stage-3 launcher), `review-context.md` (stage-6 launcher), and
  `change-summary.md` (cache-keyed by `(base-commit, head)`) are derived projections of
  canonical data sized for a specific LLM consumer at a specific stage — never canonical
  themselves, regenerated only when the source moves.

### 1.5 Context artifacts and the Context Artifact Relay

Two terms name a mechanism that is otherwise left implicit across this document.

**Context artifact.** Every `.md` file — and every `.puml` diagram — the millwright
generates under `quest/<active-slug>/` and `workflow-stream/<feature>/` is a *context
artifact*: an artifact that does double duty. It is at once (1) an **inspection surface** —
a human-legible record that lets the inspector see the workflow's state and judge the
work — and (2) a **context carrier** — the on-disk material the millwright (or a sub-agent,
or the brainstorming chain) reads back to rebuild its working context for the next stage.
The `requirements.md` the inspector reviews at stage 2 is, once approved, the same
substrate the stage-3 implementer plans against. Nothing the workflow "remembers" lives in
conversation context (Rule 1, §4) — it lives in context artifacts on disk.

The two roles are not evenly weighted across every file. The canonical blueprint and
review artifacts (`requirements.md`, `config.md`, `diagrams/`, `inspector-review.md`) lean
toward inspection; the derived primers (`primer.md`, `review-context.md`,
`change-summary.md`, `grounding-report.md`) lean toward context-carrying and are seldom
inspected directly (§1.4; Rule 3). But each is *both*, which is what makes "context
artifact" the right umbrella name for the whole generated set.

**The Context Artifact Relay.** An electrical relay is a switch that stays open — passing
nothing — until a control signal energizes its coil; only then does it close the circuit
and let the main current flow. The mi-workflow advances the same way. At every stage
boundary the millwright has produced a fresh set of context artifacts, but they do **not**
flow into the next stage on their own. They wait. The circuit closes only when the
inspector supplies the control signal — `/mi-continue`, the *universal advancement signal*
(§7.4), or its stage-6 spelling `approve`. That signal energizes the relay: the workflow
dispatches and the just-finished stage's context artifacts become the read-inputs of the
next stage.

This is the **Context Artifact Relay**. It fires once per inspector gate — i.e. at
essentially every stage transition (1→1.5, 1.5→2, 2→3, 3→5, 5→6, 6→7→8). Because the gate
is mandatory, the millwright can never advance itself: a stage's output is inert until the
inspector closes the circuit. The relay is the operational form of the two-role split
(§2) — the millwright fills the payload, the inspector throws the switch.

Three properties follow, each tying the relay back to a rule already stated:

- **Durable.** The relayed payload is context artifacts on disk, not conversation context,
  so the open circuit survives session breaks, compaction, model swaps, and multi-day
  pauses between gates (Rule 1). An inspector can leave the relay open indefinitely; the
  artifacts are still there on return.
- **Layered, not raw.** What flows forward is not every byte of every artifact but a
  primer-first projection — `primer.md` into stage 3, `review-context.md` into stage 6 —
  with the canonical artifacts as on-demand fallback (Rule 3). The relay meters its own
  bandwidth.
- **Cascading.** One advancement signal often energizes a run of auto-fired commands (a
  stage-2 approval cascades `/mi-plan-implementation`; a stage-7 exit cascades
  `/mi-complete-workflow`). The relay is keyed to the *gate*, not the command — one throw
  of the switch can carry the artifacts through several auto-fired steps.

One honest caveat on the analogy. A pure relay only switches; it never adds to the current
it gates. The inspector does a little more: at some gates they also *author* part of the
relayed payload — findings in `inspector-review.md`, prompts under `## Inspector
Additions`, a drift reason — so the inspector is both the control signal and, occasionally,
a contributor to what the relay carries. And the signal's *meaning* shifts by stage — a
selection acknowledgment at 1.5, a literal approval at 2 (the Approve Handler), a resume
acknowledgment at 3→5. The relay analogy holds regardless, since a relay needs only *a*
control signal, not a particular one; "approval" is the representative case, not the
universal one.

---

## 2. The two roles

### 2.1 The Inspector (human)

- **Owns**: the journal content, the todo selection and assignee tags, blueprint
  approvals, `## Inspector Additions` in `config.md`, the git branch, the findings file,
  every `/mi-continue` signal.
- **Never writes**: production code, generated specs, generated diagrams, generated
  requirements, generated quest files. (The inspector *may* hand-edit these in
  emergencies, but that is a recovery path, not the primary mode.)
- **Touchpoints per feature** (happy path):
  - `/mi-run <folder...>` once at the start of a quest cycle.
  - `/mi-continue` ×2 at stage 1.5 (after marking, after the queue-order proposal).
  - `/mi-continue` ×1 after blueprint review at stage 2.
  - Picks `planning-mode` (`brainstorming` | `direct`) when prompted.
  - `/mi-continue` ×1 after implementation returns.
  - Edits `inspector-review.md` if needed, then `/mi-continue` at stage 5.
  - Picks `review-mode` if findings exist; types `approve` to end the review session;
    `/mi-continue` ×1 after the session.
  - A handful of short chat replies: the stage-4 drift answer (`continue` / `auto` / a
    reason), the manual-test offer (`y`/`n`), the optional diagram-refresh (`y`/`n`).

### 2.2 The Millwright (AI agent — Claude Code)

- **Owns**: every generated artifact under `quest/<active-slug>/` (and the `quest/active.md`
  pointer), `workflow-stream/<feature>/blueprints/current/`, and
  `workflow-stream/<feature>/implementation/`. Owns dispatch — picks the right handler
  inside `/mi-continue`. Owns auto-fired commands (`mi-apply-impact`,
  `mi-plan-implementation`, `mi-review`, `mi-complete-workflow`, `mi-draw-diagrams`).
- **Never owns**: git operations beyond reads (no branch creation, no commits to trunk,
  no force-push), the `## Inspector Additions` block, the journal content, todo selection
  or assignee tags.
- **Delegates**: may spawn first-class sub-agents (§8.6) for bounded heavy lifting —
  per-file journal summarization, queue dependency analysis, codebase grounding, diagram
  rendering, change-summary writing, review-iteration work, side-quests, PR-review
  analysis and fixing. Sub-agents return ≤ 1k-token routing slips; detailed output goes
  into artifact files.

---

## 3. System architecture

### 3.1 The two top-level components

1. **Codebase** — whatever the project is building. The mi-workflow does not enforce any
   language or framework.
2. **The control-room folder** (default `millwright-inspector/`) — the workflow's data
   root. The path is configurable via `userConfig.data_root` in `plugin.json` (commonly
   `.millwright-inspector` for hidden mode). The plugin reads the runtime value from the
   `CLAUDE_PLUGIN_USER_CONFIG_data_root` environment variable Claude Code injects; the
   `MI_DATA_ROOT` env var is an explicit per-shell override. Every command resolves the
   data root via `scripts/data-root.sh` rather than hardcoding `millwright-inspector/`,
   so the same scripts work in either mode.

The control-room folder contains exactly three sub-folders:

```
millwright-inspector/
├── journal/          # raw inputs (inspector-authored)
├── quest/            # cycle-wide working state (millwright-generated; inspector marks selections)
└── workflow-stream/  # per-feature blueprints + implementation artifacts
```

A few feature-scoped or workspace-scoped files also live under the data root:
`lessons-learned.md` (cumulative PR-review lessons) at the root, and `pr-reviews/`
session directories created by `/mi-analyze-review`.

### 3.2 The journal

The journal holds **raw resources**: meeting transcripts, notes, specs, design hand-offs,
Slack exports — anything that defines or constrains the work. Sub-folders are topic
groupings; the inspector drops files in, and the workflow reads them.

Accepted formats:

- `.md` — must carry YAML frontmatter with `contributors:` and `date:` (YYYY-MM-DD),
  authored manually by the inspector.
- `.txt` — no frontmatter required; read as plain content.
- `.pdf`, `.docx`, `.pptx`, `.xlsx`, `.html`, images (`.png`/`.jpg`/etc.) — supported via
  `/mi-ingest` (docling for document conversion, a stub-md for images / short PDFs).
  `/mi-run` detects un-ingested files at stage 1 and asks the inspector per file which
  path to take. Originals stay in place for audit.

Each `journal/<topic>/` folder also gets an `id.md` folder-identity marker (see §3.6).
Example layout:

```
journal/
├── pricing-requirements-meeting/
│   ├── id.md
│   ├── meeting-transcript.txt
│   ├── notes.md
│   └── devops-team-concerns.md
└── authentication-related-slack-conversation/
    ├── id.md
    └── conversation.txt
```

### 3.3 The quest folder

Generated by `/mi-run` at the start of each cycle and **scoped per-cycle**, so older
cycles are preserved permanently as a task archive. Each `/mi-run` creates a per-cycle
subfolder under `quest/` named after a date-prefixed slug —
`YYYY-MM-DD-<journal-folder-slugs-joined-with-+>` plus an optional 3-character hex
collision suffix when the same slug already exists for the day (e.g.
`quest/2026-04-27-pricing-meeting+auth-rfc/`). A top-level `quest/active.md` pointer file
records which slug is currently active and is the single source of truth scripts and
commands read to resolve the active cycle's directory.

```
quest/
├── active.md                              # pointer file: slug + status
├── 2026-04-27-auth-meeting/               # an active cycle (or an older preserved one)
│   ├── todo-list.md
│   ├── summary.md
│   ├── progress.md
│   ├── queue-rationale.md                 # written at stage 1.5, not stage 1
│   ├── reference.md                       # folder-link table (see §3.6)
│   └── context-ledger.md                  # optional per-cycle telemetry
├── 2026-04-12-pricing-meeting+auth-rfc/    # a previous cycle, preserved permanently
│   └── ...
└── ...
```

The per-cycle files under `quest/<active-slug>/`:

| File | Role |
| ---- | ---- |
| `todo-list.md` | Per-feature checklist of TODO items with assignee tags. The inspector marks items `[x]` to select for the cycle. |
| `summary.md` | Feature-indexed digest of journal content: `## Cross-cutting constraints`, `## Out-of-scope`, and one `## Feature: <name>` section per feature. Downstream stages read only the active feature's section. |
| `progress.md` | The central workflow state file — queue, completed list, and the active feature's runtime block (see §3.5). |
| `queue-rationale.md` | Audit of stage 1.5's dependency-ordering decision. Survives session breaks. Body uses `## Batch <N>` headings (one per ordering decision); top-level frontmatter `status: draft \| confirmed`, `batch: integer ≥ 1`, and a cumulative `features:` list drive the dispatcher. |
| `reference.md` | Folder-link table tying the cycle to its source `journal/` folders and the `workflow-stream/` feature folders it produces (see §3.6). |
| `context-ledger.md` | Optional per-cycle telemetry artifact — rows record the size class (`small \| medium \| large`) and location (`main \| sub-agent \| fork`) of every context-heavy read, so a `large + main` row signals a budget regression. Written via `scripts/ledger.sh append`; append failures warn but never block. |

`todo-list.md`, `summary.md`, `progress.md`, and `reference.md` are written at stage 1 by
`/mi-run`. `queue-rationale.md` is deliberately deferred to stage 1.5 — its absence under
`quest/<active-slug>/` is what the dispatcher keys on to route the second `/mi-continue`
to Pre-flight Step 2B. Older cycle subfolders are never deleted, moved, or overwritten;
the dated slug doubles as a chronological index.

#### Todo-item state machine

Items pass through five canonical states:

```
TODO → PENDING → IMPLEMENTING → IMPLEMENTED
                  ↘ CANCELED (mid-cycle exit; preserved for audit)
```

Checkbox convention:

- `[ ]` = TODO only.
- `[x]` = any selected state (PENDING, IMPLEMENTING, IMPLEMENTED, CANCELED) — the
  **state word** is the canonical truth.

Assignee tag (the name in parentheses between the checkbox and the state word):

- *Optional* on `[ ] TODO` lines (the inspector may pre-assign without selecting).
- **Mandatory** on every `[x]` line. `todo.sh pend-selected` rejects unassigned
  selections with a list of offending IDs so the inspector can fix and retry.

Example progression:

```
- [ ] TODO — PAY-001: capture webhook              (default: unselected, unassigned)
- [ ] (emin) TODO — PAY-001: capture webhook       (pre-assigned, not selected)
- [x] (emin) PENDING — PAY-001: capture webhook    (selected for this cycle)
- [x] (emin) IMPLEMENTING — PAY-001: capture webhook  (in workflow)
- [x] (emin) IMPLEMENTED — PAY-001: capture webhook   (done)
- [x] (emin) CANCELED — PAY-001: capture webhook      (dropped mid-cycle, kept for audit)
```

**Refused manual writes.** The plugin refuses manual writes to `PENDING` and
`IMPLEMENTED`: `PENDING` is only written by stage-1.5's `pend-selected` (an audit event
tied to bulk selection); `IMPLEMENTED` is only written by stage-8's `mi-complete-workflow`
(the commits-linkage invariant depends on atomic promotion).

### 3.4 The workflow stream

Per-feature folders that hold the actual design + implementation artifacts. One folder
per feature in `workflow-stream/<feature>/`:

```
workflow-stream/<feature>/
├── id.md                  # folder-identity marker (UUID; see §3.6)
├── decisions.md           # feature-scoped append-only decision log — NOT rotated
├── blueprints/
│   ├── current/
│   │   ├── requirements.md   # Goals / Planned / Non-goals
│   │   ├── config.md         # auto-summary of skills+rules; ## GIT BRANCH; ## Inspector Additions
│   │   ├── primer.md         # compact stage-3 launch primer (layered-load entry point)
│   │   └── diagrams/
│   │       ├── README.md
│   │       ├── use-case-<feature>.puml
│   │       ├── sequence-<flow>.puml
│   │       └── (optional, at most one) class-<domain>.puml OR component-<subject>.puml
│   └── history/
│       ├── v1/{requirements.md, config.md, primer.md, diagrams/, reason.md, implementation/}
│       ├── v2/...
│       └── ...
├── implementation/        # archived into history/v[N+1]/implementation/ at stage 8
│   ├── inspector-review.md   # findings file (IR-NNN blocks)
│   ├── review-context.md     # compact stage-6 review primer
│   ├── change-summary.md     # cached analysis of base-commit..HEAD (cache-keyed reuse)
│   ├── grounding-report.md   # stage-2 codebase-grounding snapshot (seam classification)
│   └── diagrams/             # implementation render, with existing-vs-new framing
└── test/                  # feature-permanent — survives stage 8 and abort
    ├── manual-test-plan.md
    ├── manual-test-results.md
    ├── manual-test-plan.history/
    └── manual-test-results.history/
```

Four regions:

1. **`blueprints/`** — *permanent with history*. `current/` holds the live blueprint for
   the active feature. Every refresh rotates `current/*` into `history/v[N+1]/` with a
   `reason.md` recording why (`completion`, `manual`, `spec-update`, `re-spec-cascade`,
   `re-plan-cascade`). On `completion` rotations (stage 8) the entire live
   `implementation/` folder is archived alongside as `history/v[N+1]/implementation/`.
2. **`implementation/`** — *temporary in `current/`, permanent in `history/`*. Holds
   findings and implementation-side artifacts during the cycle. At stage 8 the live
   folder is **moved** (not deleted) into `history/v[N+1]/implementation/`, so every
   finding (including deferred `status: open` ones), the review-context snapshot, the
   change-summary, the grounding-report, and the implementation diagrams survive as a
   permanent audit record. `/mi-abort-workflow` clears the live `implementation/` (an
   aborted cycle has no committed work to archive).
3. **`test/`** — *feature-permanent*. Home for the optional stage-5 manual-testing
   sub-flow. The folder is **not** rotated at stage 8 and **not** deleted on abort, so a
   later cycle on the same feature can reuse the prior plan and inherit its
   `seed-family-id`. A cross-activation guard auto-rotates only the per-run results.
4. **`decisions.md`** at the **feature root** (not inside `blueprints/current/`) —
   *permanent across rotations*. A feature-scoped, append-only decision log written under
   stage-named H2s (`## Stage 2 — Blueprint approval`, etc.). Excluded from blueprint
   rotation by design; it persists across regenerations and across the feature's whole
   lifetime. Writers: `mi-continue`'s Approve Handler and Inspector Handler, plus
   `mi-complete-workflow` housekeeping. Read-only consumers fold it into `primer.md`,
   `review-context.md`, and mid-cycle blueprint regen.

### 3.5 `progress.md` — the central state file

A single YAML-frontmatter Markdown file at `quest/<active-slug>/progress.md`. Its
frontmatter is the source of truth for "where are we right now":

```yaml
---
id: <uuid>
todo-list-id: <uuid of the related todo-list.md>
queue: [notifications, audit-log]   # features still to run, in priority order
completed: [onboarding]             # features finalized via mi-complete-workflow
active:                             # null between workflows; populated while a feature runs
  feature: payments
  branch: feat/payments/webhook     # null until stage 3
  current-stage: 5                  # 2..8; stage 4 is conceptual and never persisted (3→5 atomic)
  sub-flow: none                    # none | chain-in-progress | resuming | reviewing | manual-testing
  base-commit: a1b2c3d              # null until stage 3
  execution-mode: subagent-driven   # subagent-driven | inline | none
  planning-mode: brainstorming      # brainstorming | direct | none — set at stage 3
  review-mode: none                 # brainstorming | direct | none — set at stage 6
  review-mode-suggestion: none      # brainstorming | direct | none — computed at stage 5 from finding scopes
  diagram-prompt: prompt            # prompt | auto — ask before each diagram event, or skip the prompt
  diagram-rendering: never          # never (.puml only) | on-request (.svg/.png on explicit ask)
  implementation-diagrams-skipped: false  # true if the inspector answered 'n' to the stage-4 diagram prompt
  implementation-completed: true
  inspector-review-completed: false
  drift-check-completed: true       # optional — true once the stage-4 drift prompt has been answered
  history-baseline-version: 0       # optional — highest finalized history/v[N] index at stage-3 entry
  manual-test-state: none           # optional — none | running | complete | skipped
  manual-test-failure-policy: none  # optional — none | auto-seed | manual
  clear-recommendations: []         # optional — clear-point ids already crossed (stage-2-to-3, stage-5-to-6)
  worktree-path: /Users/me/repo     # immutable after activate; state-mutating subcommands refuse on mismatch
  git-common-dir: /Users/me/repo/.git    # shared across worktrees of one repository
  git-worktree-dir: /Users/me/repo/.git  # per-worktree; equals common-dir for the main worktree
  activation-id: <uuid>             # optional — minted at activate, re-minted at reset; manual-test rotation discriminator
---
```

**Two-step activation lifecycle:**

| Trigger | Effect on `active` |
| --- | --- |
| `/mi-run` (stage 1) | `active = null`; `queue` populated. |
| `/mi-apply-impact` → `progress.sh activate` (stage 2) | Pops `queue[0]` into a fresh `active` block (current-stage=2). Fails fast if `active` is already non-null. |
| Stages 2–8 | Mutates `active.*` fields in place via `progress.sh set`, `advance`, and `advance-to`. |
| `mi-complete-workflow` → `progress.sh finish` (stage 8) | Appends `active.feature` to `completed`; sets `active = null`. |

On resume the millwright reads `active`:

- `active` null + non-empty queue → "next feature is waiting; activate it."
- `active` populated → "feature X at stage N with sub-flow Y."
- `active` null + empty queue → "cycle complete (or the todo list still has unmarked
  items — start stage 1.5 again)."

`progress.sh set` is atomic-batched (validate-all → same-dir temp file → schema-validate →
atomic rename) so a partial multi-field write can't corrupt the file. `advance-to <expected>
<target> [--set k=v]...` performs whitelisted skip-transitions in a single atomic write —
the whitelist is `3→5`, `5→7`, and `6→7`. Adjacent transitions use `advance`. Every
state-mutating subcommand calls the worktree-fingerprint guard (`mi_assert_worktree_match`)
before writing.

### 3.6 Folder linking — journal ↔ quest ↔ workflow-stream

The three folder trees are tied together by **ID, not by name**, so a quest cycle can be
traced back to the journal folders it grew from and forward to the feature folders it
produced — even after a folder is renamed or moved.

- **`id.md` folder markers.** Each `journal/<topic>/` and each `workflow-stream/<feature>/`
  folder holds an `id.md` whose frontmatter `id` is a UUID identifying *that folder*.
  Because the ID lives in a marker file, the link survives the folder being renamed or
  moved. IDs are minted lazily on first use.
- **`reference.md` link table.** Each quest cycle subfolder holds a `reference.md` (its
  own `id` identifies the cycle). Its `journal-refs` frontmatter array lists the `id.md`
  UUIDs of the journal folders the cycle was built from; its `feature-refs` array lists
  the feature folders it produces. Body bullets pair each ID with the folder's current
  name as a human-readable hint.
- **Who writes what.** `/mi-run` writes `journal-refs` at stage 1; `blueprints.sh
  ensure-current` (calling `folder-id.sh link-feature`) appends `feature-refs` as each
  feature's blueprint folder is created at stage 2.
- **`scripts/folder-id.sh`** is the sole manager of `id.md` and `reference.md`. Its
  subcommands: `ensure`, `get`, `resolve <id>` (resolve any ID back to its current path),
  `list`, `init-reference`, `link-feature`.

Reading a cycle's `reference.md`, you can reach every journal folder that seeded it and
every feature folder it produced. Existing workspaces are not migrated: journal folders
get an `id.md` the next time `/mi-run` reads them, and already-finished quest cycles get
no `reference.md`; new cycles get the full treatment.

---

## 4. The operating model — three rules

These rules apply to every stage and every command.

### Rule 1 — Inputs live in files, not in conversation context

Every mi-command resolves its inputs from known file paths at runtime. Conversation
context is ephemeral — sessions break, context gets compacted, and a single workflow may
span multiple days across multiple Claude Code sessions. Any inspector-provided value
(branch name, approvals, `/mi-continue` signals, findings) is captured the moment it
arrives and persisted to disk. Each command's inputs list is a **file-path contract**, not
a runtime parameter list. The canonical file locations:

- **`quest/active.md`** — top-level pointer (`slug`, `status`). All quest helpers resolve
  through it.
- **`quest/<active-slug>/todo-list.md`** — todo items and their state.
- **`quest/<active-slug>/summary.md`** — structured journal digest, feature-indexed.
- **`quest/<active-slug>/progress.md`** — single workflow state file (§3.5).
- **`quest/<active-slug>/queue-rationale.md`** — audit of the stage-1.5 ordering decision.
- **`quest/<active-slug>/reference.md`** — folder-link table (§3.6).
- **`workflow-stream/<feature>/decisions.md`** — feature-scoped append-only decision log.
- **`workflow-stream/<feature>/blueprints/current/`** — `requirements.md`, `config.md`,
  `diagrams/`, and (after stage 3) `primer.md`.
- **`workflow-stream/<feature>/implementation/`** — `inspector-review.md`,
  `review-context.md`, `change-summary.md`, `grounding-report.md`, `diagrams/`.
- **`workflow-stream/<feature>/test/`** — feature-permanent manual-testing artifacts.

The only inspector inputs expected at runtime: the **journal folder list** given to
`/mi-run`; **marking PENDING items** in `todo-list.md` followed by `/mi-continue`; the
post-blueprint `/mi-continue`; the stage-3/5/6 `/mi-continue` signals;
**planning-mode / review-mode picks**; and optional **edits to `inspector-review.md`**.
Every other value comes from disk. Launcher commands (`mi-apply-impact`,
`mi-plan-implementation`, `mi-review`, `mi-complete-workflow`, `mi-draw-diagrams`) are
auto-invoked by the millwright on the gates above — the inspector does not type them in
the happy path, though they remain invokable manually for recovery.

The chain's spec/plan files (under `docs/superpowers/`) are intentionally **not** tracked
in `progress.md` — those are the chain's own artefacts. The commit range
`base-commit..HEAD` is the canonical implementation contract. The single read exception is
`/mi-continue`'s abandoned-chain recovery branch (Resume Step 2.5), which reads the plan +
spec read-only to compose a resume primer.

### Rule 2 — Documents cross-link via UUIDs, with paths as navigation hints

Every `.md` file created or consumed by the workflow carries a YAML frontmatter info
section:

```yaml
---
id: 8f3a7b2c-1234-4a5b-9c6d-0e1f2a3b4c5d   # UUID v4, generated once at creation
contributors: [emin, ai-agent]            # manual for journal docs, auto for generated docs
date: 2026-04-19                          # YYYY-MM-DD

# Typed reference fields point at other documents' `id` values.
todo-list-id: 4c911d5e-1234-...
requirements-id: a2b3c4d5-6789-...
---
```

Rules for IDs:

- **Never reuse an ID.** When a document is rewritten (e.g. `requirements.md` regenerated
  for a new iteration), generate a fresh UUID; the old ID remains discoverable under
  `blueprints/history/v[N]/`.
- **Generate once, reference many times.** The `id` field is written once, on creation,
  by whichever command produces the document. IDs are minted by `scripts/uuid.sh`.
- **Don't leave dangling references.** When populating a reference field, the millwright
  verifies the target document exists and its `id` matches.

This gives three properties for free: grep-based cross-reference discovery, rename-safe
document identity, and an audit trail when combined with `blueprints/history/`.

### Rule 3 — Layered context loading

Stages that hand off to a long-running session (stage 3 via `mi-plan-implementation`,
stage 6 via `mi-review`) follow a **layered load** rather than passing every canonical
file at full size. Each launcher writes a compact derived *primer* alongside the canonical
files; the consumer reads the primer first and escalates to canonical files only when a
gap surfaces. Direct-mode runs of those stages use the same layered load.

| Stage | Required first read | Canonical fallbacks (on demand) |
| --- | --- | --- |
| 3 — implementation | `blueprints/current/primer.md` | `requirements.md`, `config.md`, `summary.md` (active feature section), `todo-list.md` |
| 6 — review | `implementation/review-context.md` + `implementation/inspector-review.md` | `requirements.md`, `config.md`, `summary.md` (active feature section), `blueprints/current/primer.md` |

Properties of derived primers:

- **Derived, not canonical** — snapshots; the canonical files win on conflict.
- **Overwritten on regeneration** by their writer (`mi-plan-implementation` /
  `mi-update-blueprint` for `primer.md`; `mi-review` for `review-context.md`).
- **Rotated or cleared with their parent folder.** `primer.md` rotates with
  `blueprints/current/`; `review-context.md` is archived into
  `history/v[N+1]/implementation/` at stage 8, cleared only on abort.
- `review.sh sync-refs` keeps `requirements-id` references live across mid-cycle rotations.
- `change-summary.md` is **cache-keyed** by `(base-commit, head)` and shared across
  `mi-generate-implementation-diagrams` and `/mi-update-blueprint`:
  `commits.sh change-summary-fresh` exits 0 (fresh — reuse), 1 (stale — regenerate), or
  2 (missing — generate).
- `summary.md` is **feature-indexed**, so a stage reads only its active feature's section
  plus cross-cutting constraints.

---

## 5. Roles × plugin interaction

A condensed map of who interacts with which plugin surface, for which purpose, at which
stage — the single most useful view of the workflow's blast radius.

| Actor | Surface | Action / Touchpoint | Stage |
| --- | --- | --- | --- |
| **Inspector** | `journal/<topic>/*` (and ingested non-text) | Authors raw inputs and `.md` frontmatter (`contributors`, `date`); groups by topic. | 0 |
| Inspector | `/mi-init`, `/mi-doctor`, `/mi-ingest`, `/mi-init-status-bar` | Setup wizard, dependency check, non-text ingestion, status-line wiring. | setup |
| Inspector | `/mi-run <folder...>` | Generate quest files from selected journal sub-folders; create a per-cycle subfolder. | 1 |
| Millwright | `quest/<active-slug>/{todo-list,summary,progress,reference}.md` + `quest/active.md` | Writes four stage-1 files into the new subfolder; updates the pointer; `active=null`. | 1 |
| Inspector | `quest/<active-slug>/todo-list.md` | Marks items `[x]` and adds `(assignee)` tags. | 1.5 |
| Inspector | `/mi-continue` ×2 | Pre-flight Step 2A (`pend-selected`, propose order); Step 2B (write `queue-rationale.md`, reorder, auto-fire `/mi-apply-impact`). | 1.5 → 2 |
| Millwright (auto) | `/mi-apply-impact` | `progress.sh activate`; generate `blueprints/current/`; pre-fill `## GIT BRANCH`. | 2 |
| Millwright (auto) | `/mi-blueprint-review` (auto-fired in stage 2 by `mi-apply-impact`) | Reviewer-fixer loop on `requirements.md` via Codex MCP; findings inline as `<!-- REVIEW-FINDING -->`. | 2 |
| Inspector | `blueprints/current/` | Reviews requirements / config / diagrams; may edit `## GIT BRANCH` and `## Inspector Additions`. | 2 |
| Inspector | `/mi-continue` | Approve Handler validates blueprints, fires the `stage-2-to-3` clear-point gate, auto-fires `/mi-plan-implementation`. | 2 → 3 |
| Millwright (auto) | `/mi-plan-implementation` | PENDING→IMPLEMENTING; capture `base-commit`; write `primer.md`; ask for `planning-mode`. | 3 |
| Inspector | Chat reply (`brainstorming` / `direct`) | Picks `planning-mode`; persisted to `progress.md`. | 3 |
| Inspector + chain / Millwright | Codebase, `primer.md` | Implements the feature (isolated chain, or direct in main session). Commits land on the active branch. | 3 |
| Inspector | `/mi-continue` | Resume Handler — drift probe, commit verification, drift prompt, diagram render, review skeleton, manual-test offer; atomic `advance-to 3 5`. | 3 → 5 |
| Millwright (auto) | `/mi-draw-diagrams` | Renders implementation diagrams with the blue/green existing-vs-new framing. | (Resume) |
| Inspector | `implementation/inspector-review.md` | Authors findings as plain sentences or `### IR-NNN` blocks. Empty file = approval. | 5 |
| Inspector | `/mi-continue` | Inspector Handler — canonicalize free-form findings; auto-finalize if no findings (after y/n confirm) or auto-fire `/mi-review`. | 5 → (7 \| 6) |
| Millwright (auto) | `/mi-review` | Fires the `stage-5-to-6` clear-point gate; writes `review-context.md`; asks for `review-mode`; dispatches. | 6 |
| Inspector + chain / Millwright | Review session | Addresses findings; ends with `approve`. | 6 |
| Inspector | `/mi-continue` | Review-Resume Handler — check/defer open findings, optional diagram refresh, atomic `advance-to 6 7`, auto-fire `/mi-complete-workflow`. | 6 → 7 → 8 |
| Millwright (auto) | `/mi-complete-workflow` | IMPLEMENTING→IMPLEMENTED, populate `commits:`, rotate blueprint, archive `implementation/`, `progress.sh finish`. | 8 |
| Inspector | recovery commands | `/mi-abort-workflow`, `/mi-resume-workflow`, `/mi-update-blueprint`, `/mi-update-todo-list`, `/mi-export-bundle`, `/mi-sidequest`. | any |
| Inspector | `/mi-analyze-review <pr-url>` | Standalone — turns a GitHub PR review into a triaged `report.md`. | n/a |
| **PostToolUse hook** | `hooks/validate-on-write.sh` | Validates YAML frontmatter against schemas on every Write/Edit to a workflow `.md`; blocks the turn on failure. | always |
| **MCP server** | `plantuml-mcp-server` | Renders `.puml` sources to images for use-case / sequence / class / component diagrams. | 2, Resume |
| Optional companions | `rtk`, `docling` | Token-saving shell-output filter; document → markdown converter. Detected by `/mi-doctor`; never required. | optional |

**Key isolation points.** The stage-3 brainstorming chain and the stage-6 brainstorming
review session both run **isolated from mi-workflow** — the millwright re-engages only when
the inspector types `/mi-continue` after the session exits. Mi-workflow never writes to the
chain's spec/plan files under `docs/superpowers/` and, in the happy path, never reads them.
The git branch is owned by the inspector end-to-end.

---

## 6. The stages (canonical 0 → 8)

### 6.1 At-a-glance

Each stage has a precise entry condition, work list, and exit condition.
`progress.md`'s `active.current-stage` is advanced at the *end* of each stage. Each
transition between stages is one firing of the **Context Artifact Relay** (§1.5): a
stage's exit condition leaves a set of context artifacts that stay inert until the
inspector's advancement signal relays them into the next stage's entry condition.

| Stage | Name | Driver | Entry | Exit |
| ---: | --- | --- | --- | --- |
| 0 | Journal populated | Inspector | `journal/` empty or stale | Inspector types `/mi-run` |
| 1 | Quest generated | Millwright via `/mi-run` | `/mi-run <folder...>` | `quest/<active-slug>/{todo-list, summary, progress, reference}.md` exist; `quest/active.md` updated (`queue-rationale.md` deferred to 1.5) |
| 1.5 | Selection + ordering | Pre-flight Handler in `/mi-continue` | Inspector marks `[x]` then `/mi-continue` ×2 | `queue-rationale.md` written; queue reordered; `/mi-apply-impact` auto-fires |
| 2 | Blueprints generated | Millwright via `/mi-apply-impact` (auto) | Pre-flight Step 2B | `blueprints/current/{requirements.md, config.md, diagrams/}` exist |
| 3 | Implementation launched | Millwright via `/mi-plan-implementation` (auto) → chain or direct | Approve Handler | `base-commit` + `planning-mode` recorded; chain or direct implementation runs |
| 4 | Implementation resumed (**conceptual; never persisted**) | Resume Handler in `/mi-continue` | `/mi-continue` after chain/direct returns | `implementation-completed=true`; diagrams rendered; review skeleton created. Handler ends with atomic `advance-to 3 5` — `current-stage` skips 4 entirely |
| 5 | Presented for inspector evaluation (optional manual test, then findings) | Inspector | Stage-4 handoff message | `/mi-continue`; `inspector-review.md` exists (empty or populated) |
| 6 | Inspector review session | `/mi-review` (auto) → chain or direct | Inspector Handler with open findings | Inspector types `approve`, then `/mi-continue` |
| 7 | Review completed (transitional) | Review-Resume Handler / active-row dispatch | No-findings path (5→7) or with-findings path (6→7) | With-findings path may refresh diagrams; no-findings path skips straight to `mi-complete-workflow` |
| 8 | Completion | Millwright via `/mi-complete-workflow` (auto) | Stage 7 reached | Blueprint rotated to history; `implementation/` archived; IMPLEMENTING→IMPLEMENTED; queue advances |

### 6.2 Detailed flow per stage

**Stage 0 — Journal populated.** The inspector drops `.md` / `.txt` (and optionally
non-text via `/mi-ingest`) into topic sub-folders under `journal/`. Frontmatter for `.md`
files: `contributors:` + `date:`. No automation here — pure intake.

**Stage 1 — `/mi-run`.** The millwright computes the cycle slug, creates `quest/<slug>/`,
and points `quest/active.md` at it via `quest.sh start`. It reads the named sub-folders,
summarizes their content into the active cycle's feature-indexed `summary.md`, generates
`todo-list.md` (kebab-case feature headings + per-item IDs and assignee placeholders),
scaffolds `progress.md` with the queue populated and `active: null`, and writes
`reference.md` with `journal-refs` linking the cycle to its source journal folders. Each
journal folder gets an `id.md` minted on first use. Only `todo-list.md`, `summary.md`,
`progress.md`, and `reference.md` are produced — `queue-rationale.md` is deferred to stage
1.5. Per-file ingest decisions are made interactively for any non-text file detected.
`--archive-active` retires an in-flight cycle without finishing it: the current
`quest/<active-slug>/` is preserved frozen, `quest/active.md` is cleared via `quest.sh
end`, and a fresh subfolder is created.

**Stage 1.5 — Selection + ordering (Pre-flight Handler).**
- *Sub-state A* (`[x] TODO` lines exist): runs `todo.sh pend-selected`, groups PENDING
  items by feature, repopulates the queue via `progress.sh enqueue` if mid-cycle, derives
  cross-feature ordering signals (journal-first → heuristic short-circuit → optional
  `dependency-mapper` sub-agent for code-aware ordering), and proposes a prioritized order
  in chat.
- *Sub-state B* (promotion done, `queue-rationale.md` missing or `status: draft`): writes
  `queue-rationale.md`, runs `progress.sh reorder`, and auto-fires `/mi-apply-impact`.

**Stage 2 — Blueprint generation (`mi-apply-impact`).** Calls `progress.sh activate`
(pops `queue[0]` into `active`), then follows the quest-driven runbook in
`docs/blueprint-regeneration.md`:
- *Step A* — read `summary.md` (active feature section + cross-cutting + out-of-scope),
  delegate a **bounded codebase-grounding pass** to the `codebase-grounder` sub-agent
  (≤ 5 files per todo item) which writes `implementation/grounding-report.md` and sets
  the `seam-classification` (`backend | frontend | mixed | infra`). Write
  `requirements.md` with `## Goals (this cycle)`, `## Planned (future cycles)`, and
  `## Non-goals (out of scope)`. Goals items name the existing seam and follow the cycle
  flavor (`greenfield` → "add …"; `bugfix` → "change X from doing A to doing B";
  `improvement` → "extend X to also …"). Planned items WILL ship later — the current
  implementation must leave architectural seams. Non-goals are truly out of scope.
- *Step B* — scan `.claude/skills/` and `.claude/rules/`; write `config.md`'s auto-block
  (≤ 10 entries / ≤ 2 lines each; `## Skills`, `## Rules`, `## Load on demand`); pre-fill
  `## GIT BRANCH` from HEAD when non-trunk; preserve `## Inspector Additions` verbatim.

After Steps A and B, `mi-apply-impact` auto-invokes `/mi-blueprint-review` (Codex by default) to review `requirements.md` for consistency and per-item completeness, then surfaces any drift in `summary.md` / `todo-list.md`. Diagrams (Step C) are generated last, after the review. See `docs/blueprints-review/plan.md`.

- *Step C* — delegate diagram rendering to the `blueprint-diagrammer` sub-agent: a
  mandatory `use-case-<feature>.puml`, 2–3 `sequence-<flow>.puml`, and at most one optional
  structural diagram (`class-` OR `component-`, never both — fires only on `backend`/`mixed`
  seams meeting a content threshold). Plus `diagrams/README.md` with a `requirements-id`
  back-reference.

`mi-apply-impact` has a **three-branch re-entry**: `active` null → activate; `current-stage
== 2` → re-enter the same feature (surfaces `blueprints.sh check-current` status; `--force`
overrides a complete or partial `current/`); `current-stage > 2` → refuses (run
`/mi-abort-workflow` first).

**Stage 3 — Implementation launch (`mi-plan-implementation`).** Pure launcher with no
driver logic: (1) `todo.sh bulk-transition PENDING IMPLEMENTING --feature <active>`; (2)
`git rev-parse HEAD` → `active.base-commit`, and capture `history-baseline-version`; (3)
validate `## GIT BRANCH` (refuse trunk, multi-line, mismatch with HEAD); (4) compose
`primer.md`; (5) ask the inspector for `planning-mode`. **Brainstorming mode** invokes the
`brainstorming` skill with `primer.md` as the required first read; the skill chains
brainstorming → writing-plans → executing-plans / subagent-driven-development →
finishing-a-development-branch in an isolated session, and mi-workflow does not interfere.
**Direct mode** has the millwright read `primer.md` and implement in the main session,
committing as it goes.

**Stage 4 — Implementation resumed (Resume Handler).** Stage 4 is conceptual — the handler
runs the work attributed to it but **never persists `current-stage=4`**; it ends with an
atomic `progress.sh advance-to 3 5 --set sub-flow=none`. Steps:
- *Step 0 — drift-completion probe.* Skipped when `drift-check-completed=true`. Otherwise
  walks `blueprints/history/v[K] > history-baseline-version` for a finalized
  `reason.kind == "spec-update"`; if found AND `blueprints.sh check-current --require-primer`
  returns 0, the prior `/mi-update-blueprint` succeeded but its marker write was lost —
  persist the marker and skip Step 3. With no baseline recorded, capture a fresh one and
  disable the probe for this invocation.
- *Step 1 — verify commits in `base-commit..HEAD`.* If zero commits, prompt the inspector:
  `retry-launch` (re-launch `/mi-plan-implementation`), `direct-empty` (confirm no code
  changes were needed — writes a tagged HTML comment into `inspector-review.md`, pre-sets
  the drift marker, advances 3→5), or `abort`.
- *Step 2 — idempotent flag writes* (`sub-flow=resuming`, `implementation-completed=true`,
  `execution-mode`).
- *Step 2.5 — abandoned-chain check.* Locates plan files in `base-commit..HEAD` under
  `docs/superpowers/plans/`; if a candidate has open checkboxes, prompts `completed |
  abandoned <N>`. On `abandoned`, re-invokes the `brainstorming` skill with a resume primer
  (read-only access to `docs/superpowers/` is the single exception to the "don't read chain
  artefacts" rule).
- *Step 3 — drift prompt* (skipped when Step 0 set the marker). Replies: a `<reason>`
  (invokes `/mi-update-blueprint --reason-kind=spec-update "<reason>"`), `auto` (the
  millwright analyzes `requirements.md` against `git diff base-commit..HEAD` and rotates
  only on meaningful divergence), or `continue` (proceed; drift surfaces as findings later).
- *Step 4 — drift side effect* — persists `drift-check-completed=true` (split marker write).
- *Step 5 — auto-fire `/mi-draw-diagrams`* (renders implementation diagrams).
- *Step 6 — initialize the `inspector-review.md` skeleton* via `review.sh init` (idempotent).
- *Step 7 — manual-test offer* (`y`/`n`). On `y`, auto-fires `/mi-manual-test-plan
  --from-resume` then `/mi-manual-test-run` under `sub-flow=manual-testing`. On `n`, atomic
  finalize `advance-to 3 5`.

**Stage 5 — Presented for inspector evaluation (Inspector Handler).** Stage 5 widens from
"findings only" to "optional manual test, then findings." If the manual-testing sub-flow
ran (`sub-flow=manual-testing`), the `5 | manual-testing` dispatch row routes to the
**Manual-Test-Resume Handler** for crash recovery. The plain Inspector Handler runs after
the sub-flow exits (or if it was skipped): (0) prints a one-line manual-test summary if
applicable; (1) verifies `inspector-review.md` exists; (1.5) **canonicalizes free-form
findings** — `review.sh canonicalize` returns TSV spans, the millwright classifies severity
(`blocker`/`major`/`minor`) and scope (`fix`/`re-implement`/`re-plan`/`re-spec`), calls
`review.sh add`, and `review.sh strip-freeform`; (1.6) persists `review-mode-suggestion`;
(2) `review.sh list-open`. If empty → prompt a y/n confirmation, then atomic `advance-to
5 7` (skip stage 6) and auto-fire `/mi-complete-workflow`. If non-empty → auto-fire
`/mi-review` and stop.

**Stage 6 — Inspector review session (`mi-review`).** Pure launcher: fires the
`stage-5-to-6` clear-point gate, composes `review-context.md`, sets `sub-flow=reviewing`,
advances 5→6, asks for `review-mode`. **Brainstorming mode** invokes the
`review-iteration-runner` sub-agent (which holds the `Skill` tool and chains into
`brainstorming`/`writing-plans` for `re-spec`/`re-plan` cascades) — the session loops
internally: read findings → cascade-dispatch by scope → mark each `fixed` → ask for
approval. **Direct mode** keeps the loop in the main session. The inspector ends with
`approve`. There is no iteration cap.

**Stage 7 — Review completed (Review-Resume Handler).** Checks for open findings; if any
remain, prompts `completed` (proceed with deferred findings — archived in the stage-8
snapshot), `abandoned` (re-launch `/mi-review`), or `abort`. If none remain, prompts the
same y/n completion confirmation as stage 5. Offers a **diagram refresh** when review-loop
commits exist (the refreshed render is what stage 8 archives). Then atomic `advance-to 6 7
--set sub-flow=none --set inspector-review-completed=true` and auto-fire
`/mi-complete-workflow`.

**Stage 8 — Completion (`mi-complete-workflow`).** (1) `todo.sh bulk-transition
IMPLEMENTING IMPLEMENTED --feature <active>` (CANCELED items left alone); (2)
`commits.sh populate-requirements` writes the `commits:` field in `requirements.md`; (3)
`blueprints.sh rotate --reason-kind completion` moves `current/*` into `history/v[N+1]/`
and writes `reason.md`; (4) archives the live `implementation/` folder into
`history/v[N+1]/implementation/` (a move, not a delete — `decisions.md` and `test/` stay at
the feature root); (5) `progress.sh finish`. Then housekeeping: if `queue` is non-empty,
the **feature-A→feature-B clear-point gate** fires (recommend `/clear`, halt before
auto-firing the next `/mi-apply-impact`); if `queue` is empty but `[ ] TODO` items remain,
ask the inspector to mark the next batch and `/mi-continue` (re-enters stage 1.5 via
`progress.sh enqueue`); if `queue` is empty and no `[ ] TODO` remain, `quest.sh end`
archives the pointer and `/mi-run` can start a new cycle.

### 6.3 Running parallel cycles with git worktree

`mi_data_root` resolves per working directory (`$MI_DATA_ROOT` →
`$CLAUDE_PLUGIN_USER_CONFIG_data_root` → `${PWD}/millwright-inspector`). The default puts
each working tree on its own data root automatically, so two `git worktree add` checkouts
can run independent cycles with no extra setup. Two pitfalls:

- **Don't set `userConfig.data_root` to an absolute path** — that value is global to the
  Claude Code instance, so every worktree resolving against it lands on the same folder
  and shares one `quest/active.md`, one `progress.md`, one `workflow-stream/`. Leave it
  unset or use a relative path.
- **If you need an absolute root, set it per-worktree via `MI_DATA_ROOT`** (e.g. a
  per-worktree `.envrc` exporting `MI_DATA_ROOT="$PWD/millwright-inspector"`).

If both worktrees do share a data root, the **worktree-fingerprint guard** catches the
most damaging case — a sibling worktree mutating an active block it doesn't own — and
refuses with a guidance message before any state is written.

---

## 7. The workflow commands (full reference)

All commands live under `commands/` as Markdown files with YAML frontmatter
(`description:` and optional `argument-hint:`). The slash-command name matches the file
name. There are **21 commands**. Commands marked **auto** are fired by the millwright on
the preceding inspector gate; they remain invokable manually for recovery.

In the happy path the inspector types only **three** commands across the whole workflow:
`/mi-init` (once per workspace), `/mi-run` (once per cycle), and `/mi-continue` (at every
gate). Everything else is auto-fired or used only for non-happy-path situations.

### 7.1 Setup and dependency commands

**`/mi-init`** — first-run wizard, once per workspace, idempotent. Runs
`doctor.sh --format=json`, buckets every required-and-missing dependency into
Bash-runnable (CLI tools / Python modules) and plugin-kind (slash-command-only) sets,
offers a **single y/n** to install all Bash-runnable deps in batch, prints the
`/plugin marketplace add` + `/plugin install` commands for plugin-kind deps, scaffolds
`journal/`, `quest/`, `workflow-stream/` under the data root, seeds the `quest/active.md`
pointer with `status: none`, and offers to wire the status line. Prints the canonical
next-steps walkthrough.

**`/mi-doctor`** — detailed dependency check; manual, or auto-invoked by `/mi-run`'s
preflight. Per-dep prompts and sudo handling; returns JSON or a human-readable summary.
Verifies CLI tools (`git`, `python3`, `yq`), Python modules, `plantuml-mcp-server`,
optional companions (`ajv-cli`, `rtk`, `docling`), and the five chain skills.

**`/mi-ingest [<journal-subfolder>] [--dry-run] [--force]`** — converts non-text journal
files to sibling `.md`. Also `--file <path>` (one file via auto-dispatch) and
`--stub <path>` (force a native-read stub). Documents (`.pdf`, `.docx`, `.pptx`, `.xlsx`,
`.html`) → docling with `--image-export-mode referenced` (figures land in
`<stem>.images/`). Standalone images → a stub `.md` referencing the original (Claude is
already a VLM; docling's image pipeline is net-negative for standalones). Short PDFs
(≤ 20 pages) default to a stub. `/mi-run` auto-runs the same per-file decision flow for
any un-ingested file detected at stage 1.

**`/mi-init-status-bar [--user | --project-shared] [--plugin-root <abs>]`** — one-shot
wiring of the pull-only `statusLine` renderer. Writes `.claude/mi-stage-info-bar.sh` (a
generated wrapper with the plugin's absolute path baked in — Claude Code does **not**
expand `$CLAUDE_PLUGIN_ROOT` inside `statusLine.command`) and a `statusLine.command` block
in settings.json. Default target: project-local `.claude/settings.local.json`; `--user`
writes to `~/.claude/`; `--project-shared` writes to the committed `.claude/settings.json`
(warned — the wrapper's baked-in path is machine-specific). The renderer (`scripts/info-bar.sh`)
is pull-only — not a hook, not a writer; it reads stdin JSON, parses `quest/active.md` +
`progress.md` once, prints one line (`mi-workflow · <feature> · Stage <N> · <stage-name>`),
and exits 0. Outside an mi-workspace it prints nothing.

### 7.2 Cycle-level command

**`/mi-run <journal-folder> [<journal-folder>...] [--archive-active]`** — inspector, once
per cycle. Step 0: dependency preflight via `doctor.sh --preflight` (which runs `git
rev-parse --verify HEAD`, so a fresh repo with zero commits fails preflight). Step 1: parse
arguments. Step 2: detect non-text files and run the per-file ingest decision flow. Step 3:
compute the cycle slug, create `quest/<slug>/`, `quest.sh start`. Step 4: generate
`todo-list.md`, `summary.md`, `progress.md` (queue populated, `active: null`), and
`reference.md` (with `journal-refs`). Refuses if a cycle is already active unless
`--archive-active` is passed. Branch selection is deferred to stage 2.

### 7.3 Per-feature launcher commands

**`/mi-apply-impact [--force]`** *(auto)* — stage 2. Auto-fired by Pre-flight Step 2B and
Row A, and by `mi-complete-workflow` Step 7 when the queue still has features. Three-branch
re-entry (§6.2). Generates `blueprints/current/{requirements.md, config.md, diagrams/,
diagrams/README.md}` via the `docs/blueprint-regeneration.md` runbook, delegating to the
`codebase-grounder` and `blueprint-diagrammer` sub-agents. `--force` regenerates even when
`check-current` reports a complete `current/`. Does **not** auto-advance to stage 3.

**`/mi-plan-implementation`** *(auto)* — stage 3 launcher. Auto-fired by the Approve
Handler. Pure launcher (§6.2): PENDING→IMPLEMENTING, capture `base-commit` +
`history-baseline-version`, validate `## GIT BRANCH`, compose `primer.md`, ask for
`planning-mode`, launch the chosen path. Sets `sub-flow=chain-in-progress` and advances
2→3.

**`/mi-draw-diagrams [--target=implementation] [--force]`** *(auto or manual)* — auto-fired
by the Resume Handler (Step 5) and the Review-Resume Handler (Step 2.5, on a `y` refresh).
Thin wrapper that dispatches on `--target` (default `implementation`) and branches on the
`(diagram-prompt, implementation-diagrams-skipped)` state; `--force`/`--generate` bypasses
the skip-recovery prompt. For `--target=implementation` it runs the body of
`mi-generate-implementation-diagrams`.

**`/mi-generate-implementation-diagrams`** *(internal)* — the engine behind
`/mi-draw-diagrams`. Ensures `change-summary.md` is fresh via
`commits.sh change-summary-fresh`, seeds `implementation/diagrams/` from
`blueprints/current/diagrams/`, and selectively re-renders the affected subjects of
`base-commit..HEAD` (use-case + 2–3 sequence + optional one structural diagram) with the
blue/green existing-vs-new convention. Delegates to the `implementation-analyst` sub-agent.
Writes `implementation/diagrams/README.md` with `stage: implementation` (intentionally not
`requirements-id`).

**`/mi-review`** *(auto)* — stage 6 launcher. Auto-fired by the Inspector Handler when
findings exist. Step 0: `stage-5-to-6` clear-point gate. Then composes `review-context.md`
(folding in `decisions.md` content + the `review-mode-suggestion`), sets `sub-flow=reviewing`,
advances 5→6, asks for `review-mode`, and dispatches to the `review-iteration-runner`
sub-agent (brainstorming) or the main-session loop (direct). Does **not** advance past 6 or
auto-fire `/mi-complete-workflow` — that is the Review-Resume Handler's job.

**`/mi-complete-workflow`** *(auto)* — stage 8. Auto-fired on stage-7 clean exit (and by
Pre-flight Row B and the active-row stage-7 dispatch). Step 0 dispatches into one of five
branches so a partially-completed prior invocation resumes cleanly:
- **0a** — an in-flight `v[K].partial/` exists matching `completion`: resume via
  `blueprints.sh resume-partial --expected-kind completion`, skip Steps 1–4.
- **0b** — a different-kind partial blocks the completion rotation: refuse with guidance.
- **I** — post-finish recovery (`active=null`, `completed[-1]`'s latest `v[N]` is
  `completion`): reconstruct the feature, run Step 7 housekeeping only.
- **II** — rotation already done (`current/requirements.md` missing, latest `v[N]` is
  `completion`): resume from Step 5.
- **III** — normal forward path; before Step 4's rotate, requires
  `blueprints.sh check-current --require-primer` to return 0.

Steps when reached: resolve inputs; IMPLEMENTING→IMPLEMENTED; populate `commits:`; rotate
the blueprint; archive `implementation/`; `progress.sh finish`; housekeeping (§6.2 stage 8).

### 7.4 The universal advancement signal — `/mi-continue`

The single touchpoint at every inspector gate. Reads `progress.md` (and sibling files) and
dispatches. **Step 1** sanity-checks `$CLAUDE_PLUGIN_ROOT` and reads workflow state.
**Step 2.0** is a **PR-review pre-dispatch check** that runs *before* the workflow router
(see §7.8). **Step 2** is the dispatch table.

**Pre-flight rows (`active = null`)** — evaluated in order:

| Pre-condition | Handler |
| --- | --- |
| `[x] TODO` lines exist in `todo-list.md` (selections not promoted) | **Pre-flight Step 2A** — `pend-selected`, group by feature, propose order |
| no `[x] TODO`, queue non-empty, `queue-rationale.md` missing | **Pre-flight Step 2B (initial)** — write `queue-rationale.md` (implicit Batch 1), `progress.sh reorder`, auto-fire `/mi-apply-impact` |
| no `[x] TODO`, queue non-empty, `queue-rationale.md` present, `status: draft` | **Pre-flight Step 2B (extended — multi-batch)** — confirm/update the latest `## Batch <N>`, flip `status` to `confirmed`, auto-fire `/mi-apply-impact` |
| **Row A — between features:** queue non-empty, `queue-rationale.md.status` confirmed (or absent), `(features − completed) == queue` exactly | Auto-fire `/mi-apply-impact` for `queue[0]` (no prompt) |
| **Row B — post-finish housekeeping recovery:** queue empty, no TODO marks, `completed` non-empty, `completed[-1]`'s latest `reason.kind == "completion"`, `quest/active.md.status == "active"` | Auto-fire `/mi-complete-workflow` (Branch I — Step 7 only) |
| catch-all (queue empty, no `[x] TODO`) | Delegate to `/mi-resume-workflow` |

**Active rows (`active != null`)** — keyed by `current-stage` + `sub-flow`:

| `current-stage` | `sub-flow` | Handler |
| --- | --- | --- |
| 2 | any | **Approve Handler** — Step 1 sanity-check `blueprints.sh check-current`; Step 2 `stage-2-to-3` clear-point gate (records the id in `clear-recommendations`; writes pending decisions to `decisions.md`); Step 3 auto-fire `/mi-plan-implementation` |
| 3 | any | **Resume Handler** — the seven-step sequence of §6.2 (drift probe → verify commits → idempotent flags → abandoned-chain check → drift prompt → drift side effect → diagrams → review skeleton → manual-test offer), ending in atomic `advance-to 3 5` |
| 5 | `manual-testing` | **Manual-Test-Resume Handler** — placed ABOVE the catch-all `5 | (any)` row; dispatches on (plan exists, results exists, results state) and re-fires `/mi-manual-test-run` (Branch A) or `--seed-only` (Branch B) for crash recovery |
| 5 | any | **Inspector Handler** — manual-test summary line; canonicalize free-form findings; persist `review-mode-suggestion`; `list-open`. Empty → y/n confirm → atomic `advance-to 5 7` → auto-fire `/mi-complete-workflow`. Non-empty → auto-fire `/mi-review` |
| 6 | `reviewing` | **Review-Resume Handler** — check/defer open findings (with the same y/n completion confirmation), offer a diagram refresh when review-loop commits exist, atomic `advance-to 6 7`, auto-fire `/mi-complete-workflow` |
| 7 | any | Stage-7 finalize — auto-fire `/mi-complete-workflow` (idempotent via Branch II) |
| any other | — | Delegate to `/mi-resume-workflow` for diagnosis |

### 7.5 The stage-5 manual-testing sub-flow

An optional sub-flow that exercises the implemented surface against an inspector-runnable
test plan before findings authoring. Two commands and two `progress.md.active` fields
(`manual-test-state`, `manual-test-failure-policy`). All artifacts are feature-permanent
under `workflow-stream/<feature>/test/`.

**`/mi-manual-test-plan [--from-resume] [--force [--new-seed-family]] [--discard-existing]`**
*(auto or manual)* — auto-fired by Resume Step 7 (with `--from-resume`) when the inspector
answers `y`; manually invokable while `current-stage=5`; refuses outside stage 5. Generates
`test/manual-test-plan.md` (schema `manual-test-plan`), enumerating scenarios derived from
`requirements.md` Goals + `change-summary.md` + open todos, and offers to run it. On
`--force` / `--discard-existing` it rotates the existing plan into
`test/manual-test-plan.history/<timestamp>/`. Step 1 auto-rotates any prior-activation
results into `test/manual-test-results.history/<timestamp>/` (cross-activation guard, keyed
on `generated-in-activation` vs `progress.md.active.activation-id`). Sets
`sub-flow=manual-testing`.

**`/mi-manual-test-run [--seed-only [...]] | [--finalize-skipped]`** *(auto or manual)* —
auto-fired by Resume Step 7 right after the plan is generated; also auto-fired by the
Manual-Test-Resume Handler on re-entry. Walks the plan's scenarios, asking the inspector
for `pass` / `fail <observation>` / `skip <reason>` / `pause`, and captures outcomes into
`test/manual-test-results.md` (`state ∈ {in-progress, complete}`, `current-scenario`
cursor, counts). It is the **single owner** of manual-test → `inspector-review.md`
mutations: under `failure-policy=auto-seed` it calls `review.sh upsert-manual-test-failure`
to seed a `### IR-NNN` finding with a deterministic `seed-id:
manual-test:<seed-family-id>:<scenario-id>` (idempotent across re-runs); under `manual`
policy it prints the failure and lets the inspector hand-author the finding. `--seed-only`
is the recovery shape (results exist but seeding never completed; companion flags
`--reclassify`, `--reopen-all`, `--as-new-findings`, `--force-new-regressions` tune how
re-failures are reseeded); `--finalize-skipped` bulk-skips remaining scenarios and
finalizes.

### 7.6 Recovery and utility commands

**`/mi-abort-workflow [--drop-feature=requeue]`** — safe-cancel. Reverts IMPLEMENTING →
PENDING for the active feature only; **deletes** the contents of `implementation/` (an
aborted cycle has no shipped work to archive); preserves `blueprints/current/` and the
feature-permanent `test/` folder; never touches git. Without a flag, `progress.sh reset`
keeps `feature` + `branch`, clears `base-commit` / `execution-mode` / completion flags /
drift markers, sets `sub-flow=none` and `current-stage=2` (ready to retry). With
`--drop-feature=requeue`, `progress.sh requeue` appends the feature to the end of the
queue. (`--drop-feature=completed` was **removed** — it bypassed canonical stage-8 work;
to finalize a shipped feature, run `/mi-complete-workflow` directly.)

**`/mi-resume-workflow`** — diagnostic. Reads `progress.md`, validates invariants, prints a
one-line summary plus the recommended next command. Does **not** mutate state. It is the
fall-through target for `/mi-continue`'s catch-all and unknown-state rows.

**`/mi-update-blueprint [--reason-kind <manual|spec-update>] [--force-regen] <reason summary>`**
— manual implementation-driven blueprint refresh (mid-cycle, stage 3+); also auto-fired by
the Resume Handler's drift gate with `--reason-kind=spec-update`. A **Step 1.5 recovery
decision tree** runs *before* the rotate so a partial state can never be archived. Rotates
`current/` into `history/v[N+1]/`, regenerates `requirements.md` Goals + `config.md` +
`diagrams/` + `primer.md` from `change-summary.md` + targeted `git diff base-commit..HEAD`
hunks, copies `## Planned` / `## Non-goals` / `todo-item-ids` / `todo-list-id` verbatim from
the previous history version, preserves `## GIT BRANCH` + `## Inspector Additions` via
`blueprints.sh preserve-inspector-sections`, and calls `review.sh sync-refs`.
`--reason-kind` accepts `manual` (default) or `spec-update`; the cascade kinds
(`completion`, `re-spec-cascade`, `re-plan-cascade`) belong to their owning commands and
are refused. `--force-regen` discards a partial `current/` and regenerates from the latest
safe history version. **Deliberately NOT inputs:** `todo-list.md`, `summary.md`,
`journal/` — mid-cycle refreshes are reverse-engineered from the implementation.

**`/mi-update-todo-list <subcmd> <args>`** — manual todo edits, a thin dispatcher over
`todo.sh`: `add <feature> <state> <assignee> <item-id> <description>` (state ∈ {TODO,
IMPLEMENTING, CANCELED} only), `cancel <item-id>`, `set-state <item-id> <state>`. Refuses
`PENDING` and `IMPLEMENTED` writes. Reminds the inspector to follow up with
`/mi-update-blueprint` if a mid-cycle edit shifts scope.

**`/mi-export-bundle`** — extracts (does **not** synthesize) the active feature's current
state into a single self-contained markdown file at
`tmp/bundles/<feature>-stage<N>-<timestamp>.md` for pasting into a fresh agent that lacks
plugin/data access. Sections: requirements, scope, custom project instructions, project
constraints, feature background, decisions, codebase-context audit, implementation
summary, changed-files index, manual-test results, open review findings. Strips
frontmatter / HTML scaffolding / template placeholders / workflow file paths; excludes
diagrams, diffs, and prose synthesis. Pre-flight refusals (in order): no active cycle / no
active feature / worktree fingerprint mismatch. Auto-writes `tmp/bundles/.gitignore`.
Engine: `scripts/bundle.sh export`.

### 7.7 Side-quests — `/mi-sidequest`

**`/mi-sidequest [--quick | --standard | --deep] [--write] "<question>"`** — runs a
mid-workflow question or small ask in an **isolated sub-agent context** so the exploration
footprint does not accumulate in the main orchestrator's context for the rest of the
cycle. It complements the clear-point gates (which flush context at stage boundaries) by
handling the *between-gate* exploration cost. Refuses outside an active workflow.

- The sub-agent reads workflow state from a `progress.md` snapshot passed in the spawn
  prompt, answers the question, and returns a focused `Answer:` block plus a one-line
  `Continuity summary:` that main retains.
- Three effort tiers — `quick`, `standard`, `deep` — control the sub-agent's read/grep
  budget and answer length, not the model. The tier is auto-classified from three cheap
  signals (scope, action verb, concreteness): all-narrow → `quick`; mixed/one-broad →
  `standard`; two-or-more-broad, or any `design`/`audit`/`refactor` verb → `deep`. Under
  uncertainty the higher tier is chosen. The `--quick` / `--standard` / `--deep` flags
  override the classification.
- Default spawns the read-only `sidequest-reader` sub-agent. `--write` spawns the
  writable `sidequest-writer`, which may edit **project source files only** — workflow
  artifacts under the data root stay read-only regardless, and the sub-agent cannot
  commit, branch, or mutate workflow state.
- Escalation: a `NEEDS_ESCALATION:` sentinel re-spawns one tier up (one-shot); a
  `WRITE_REQUIRED:` sentinel from the reader tells the inspector to re-run with `--write`
  (it never auto-spawns the writer — write mode is an explicit inspector decision).

### 7.8 PR-review analysis — `/mi-analyze-review`

**`/mi-analyze-review <github-pr-or-comment-url>`** — **standalone; requires no active
workflow.** Turns a GitHub PR review into a structured, inspector-triaged work list.
Accepted URL forms: `…/pull/<N>` (the whole PR), `…/pull/<N>#discussion_r<ID>` (one
line-comment thread), `…/pull/<N>#pullrequestreview-<ID>` (one review). Flow:

1. **Parse the URL** via `pr-review.sh parse-url`.
2. **Preflight** — `gh` installed + authenticated; the working directory is a checkout of
   the PR's repository; HEAD is the PR's head commit (the analyst judges comments against
   real code); a dirty tree is a warning, not a hard refusal.
3. **Create the session** — `pr-review.sh new-session` creates a fresh timestamped
   directory under `pr-reviews/`; it refuses if an `awaiting-marks` or `partial` report
   already exists for the PR.
4. **Fetch the comments** — `pr-review.sh fetch` retrieves line-level review comments via
   **GraphQL review threads** and review-summary bodies + general PR comments via **REST
   issue comments**, writing raw payloads under `<session>/raw/` and a normalized
   `<session>/comments.json`.
5. **Scaffold `report.md`** — `frontmatter.sh init pr-review-report` writes the report
   with frontmatter (`status: awaiting-marks`, `pr-url`, `repo`, `pr-number`,
   `pr-branch`), inspector instructions, and an empty `## Comments` section.
6. **Analyze (sub-agent)** — the `review-comment-analyst` sub-agent reads `comments.json`,
   judges each comment against the real code, and appends one `### PR-NNN` block per
   comment. Each block carries `verdict:` (`valid` / `invalid` / `needs-discussion`),
   `action:` (`fix` when valid, `reply` otherwise), the verbatim `comment:`, an `analysis:`
   citing the inspected `file:line`, and either a `proposed-fix:` or a `proposed-reply:`.
   Blocks stay `[ ]` — marking is the inspector's job.
7. **Canonicalize** — `pr-review.sh canonicalize` renumbers `PR-NNN` ids and validates
   structure.
8. **Hand back** — the inspector opens `report.md`, flips `[ ] → [x]` on blocks to act on
   (and may edit `verdict`/`action` or add `inspector-notes`), then types `/mi-continue`.

**The PR-Review Apply Handler in `/mi-continue`.** `/mi-continue`'s Step 2.0 scans for
reports with `status: awaiting-marks` or `partial` via `pr-review.sh find-awaiting`.
With no active workflow and exactly one report it routes straight to the **PR-Review Apply
Handler**; with an active feature *and* a report it asks the inspector to disambiguate in
chat. The handler: canonicalizes; guards a fresh report with zero marks; normalizes
(unmarked non-terminal blocks → `skipped`); collects actionable blocks via
`pr-review.sh list-actionable`; splits by `action`. For **fix** blocks it runs a `gh`
preflight + repo guard, checks out the PR branch (`gh pr checkout`), and spawns the
`pr-review-fixer` sub-agent, which applies each marked fix, commits it (does **not** push),
sets the block status, enforces a clean-worktree invariant on failure, and — for each
applied `valid` fix — distills one lesson and appends it to `lessons-learned.md` via
`lessons.sh append`. For **reply** blocks it shows the inspector exactly what will be
posted, asks one confirmation, then `pr-review.sh post-reply` posts a threaded reply
(`review-comment`) or a new PR conversation comment (`review-summary` / `issue-comment`).
Finally `pr-review.sh report-status` sets the report frontmatter to `applied` (all blocks
terminal) or `partial` (some non-terminal). The handler auto-fires nothing else.

---

## 8. Technical underpinnings

### 8.1 Plugin descriptor (`.claude-plugin/plugin.json`)

```json
{
  "name": "millwright-inspector-development-machine",
  "version": "1.1.0",
  "description": "Millwright-Inspector agentic workflow system …",
  "author": { "name": "Emin Akkoc", "email": "emin.akkoc@gmail.com" },
  "license": "MIT",
  "keywords": ["agentic-workflow", "ai-coding", "code-review", "spec-driven", "plantuml", "brainstorming"],
  "commands": "./commands/",
  "mcpServers": {
    "plantuml": { "command": "plantuml-mcp-server", "args": [] }
  },
  "userConfig": {
    "data_root": {
      "type": "string",
      "title": "Workflow data root",
      "default": "millwright-inspector",
      "sensitive": false
    }
  }
}
```

The marketplace manifest (`.claude-plugin/marketplace.json`) names the marketplace
`millwright-inspector`, lists this one plugin, and points `homepage` at the GitHub
repository.

**Notable design choice:** `superpowers` is **not** declared as a plugin dependency.
Claude Code's `dependencies:` field is a hard load-time gate; declaring superpowers there
would prevent `mi-init` from loading in the first place — the very command that guides the
inspector through the install. Instead, `mi-init` / `mi-doctor` detect missing skills and
print the slash commands to run.

### 8.2 The validation hook (`hooks/hooks.json` + `hooks/validate-on-write.sh`)

A single `PostToolUse` hook matched on `Write|Edit`. It reads the tool-call JSON on stdin,
extracts the file path, and — if the file lives under the data root, ends in `.md`, and
matches a known schema — runs `scripts/internal/validate-frontmatter.sh <file> <schema>`.
On failure it emits `{"decision": "block", "reason": "…"}` and exits 2 to halt the turn.
It is a no-op outside the data root and for unknown filenames, so general project edits
proceed normally.

Coverage policy:

- **Validated (live artifacts):** `quest/active.md` (schema `active-quest`),
  `quest/*/{progress, todo-list, summary, queue-rationale, context-ledger}.md`,
  `quest/*/reference.md` (schema `reference`), `journal/*/id.md` and
  `workflow-stream/*/id.md` (schema `folder-id`), `workflow-stream/*/decisions.md`,
  `blueprints/current/{requirements, config, primer}.md`,
  `blueprints/current/diagrams/README.md`,
  `implementation/{inspector-review, review-context, change-summary, grounding-report}.md`,
  `implementation/diagrams/README.md`, `blueprints/history/v*/reason.md`,
  `pr-reviews/*/report.md` (schema `pr-review-report`), and `lessons-learned.md`.
- **Hard-rejected:** writes to the legacy path `implementation/overseer-review.md` (the
  file was renamed to `inspector-review.md` at v1.0.0).
- **Skipped (audit archive):** other files under `blueprints/history/v*/` (including
  `history/v*/implementation/*` archived at stage 8) and older `quest/<old-slug>/*`
  subfolders — they were validated when live and are immutable post-rotation.

### 8.3 Schemas (`schemas/`)

**23 JSON-Schema-as-YAML files**, one per artifact type, validated by `ajv-cli` (preferred)
or a `yq`-based structural fallback:

| Schema | Validates |
| --- | --- |
| `active-quest` | `quest/active.md` — `slug`, `started`, `journal-folders`, `status` (`active \| archived \| none`) |
| `progress` | `quest/*/progress.md` — the full state file of §3.5 |
| `todo-list` | `quest/*/todo-list.md` — `id`, `related-features`, `description` |
| `summary` | `quest/*/summary.md` — `id`, `todo-list-id`, `features`, `keywords`, `description` |
| `queue-rationale` | `quest/*/queue-rationale.md` — multi-batch shape (`status`, `batch`, cumulative `features`) |
| `reference` | `quest/*/reference.md` — `id`, `journal-refs[]`, `feature-refs[]` (arrays of folder UUIDs) |
| `context-ledger` | `quest/*/context-ledger.md` — per-cycle telemetry table |
| `folder-id` | `journal/*/id.md` and `workflow-stream/*/id.md` — a single `id` UUID identifying the folder |
| `requirements` | `blueprints/current/requirements.md` — `id`, `todo-list-id`, `todo-item-ids`, `commits` |
| `config` | `blueprints/current/config.md` — `id`, `requirements-id` |
| `primer` | `blueprints/current/primer.md` — `id`, `requirements-id`, `feature` |
| `diagrams-readme-blueprint` | `blueprints/current/diagrams/README.md` — `requirements-id` back-reference |
| `decisions` | `workflow-stream/*/decisions.md` — `id` (UUIDv4-only, stricter than others), `feature` |
| `reason` | `blueprints/history/v*/reason.md` — `kind`, `triggered-at`, `summary` |
| `review-file` | `implementation/inspector-review.md` — `id`, `requirements-id` |
| `review-context` | `implementation/review-context.md` — `id`, `requirements-id`, `feature` |
| `change-summary` | `implementation/change-summary.md` — `id`, `requirements-id`, `feature`, `base-commit`, `head` |
| `grounding-report` | `implementation/grounding-report.md` — `id`, `feature`, `seam-classification` |
| `diagrams-readme-implementation` | `implementation/diagrams/README.md` — `id`, `stage: implementation` |
| `manual-test-plan` | `test/manual-test-plan.md` — `id`, `seed-family-id`, `feature`, `generated-in-activation`, `requirements-id`, … |
| `manual-test-results` | `test/manual-test-results.md` — `id`, `plan-id`, `seed-family-id`, `state`, `current-scenario`, counts |
| `pr-review-report` | `pr-reviews/*/report.md` — `id`, `pr-url`, `repo`, `pr-number`, `status` (`awaiting-marks \| partial \| applied`) |
| `lessons-learned` | `lessons-learned.md` — `id` (the `L-NNN` lesson blocks in the body are appended by `lessons.sh`, not schema-validated) |

### 8.4 Templates (`templates/`)

**22 mustache-style templates** rendered by `frontmatter.sh init`, which auto-injects a
fresh UUID via `uuid.sh` if `UUID=` isn't passed, then substitutes the remaining `{{KEY}}`
placeholders: `active-quest`, `change-summary`, `config`, `context-ledger`, `decisions`,
`folder-id`, `grounding-report`, `inspector-review`, `lessons-learned`, `manual-test-plan`,
`manual-test-results`, `pr-review-report`, `primer`, `progress`, `queue-rationale`,
`reason`, `reference`, `requirements`, `review-context`, `sub-agent-return`, `summary`,
`todo-list`. (`inspector-review.md.tmpl` is the template for the `review-file` schema; the
two `diagrams-readme-*` artifacts have no template — their READMEs are composed directly.)

### 8.5 Scripts (`scripts/`)

**19 scripts** plus `scripts/internal/` helpers:

| Script | Role |
| --- | --- |
| `uuid.sh` | Generate a single UUID v4 (prefers `uuidgen`, falls back to Python). The sole authority for ID minting. |
| `frontmatter.sh` | Read / write / init / validate YAML frontmatter. Subcommands: `init`, `get`, `set`, `validate`. |
| `data-root.sh` | Resolve the data root: `MI_DATA_ROOT` → `CLAUDE_PLUGIN_USER_CONFIG_data_root` → `${PWD}/millwright-inspector`. Every other script sources this. |
| `quest.sh` | Manage the `quest/active.md` pointer and resolve the active cycle's directory. Subcommands: `slug`, `start`, `end`, `init-pointer`, `current`, `dir`, `has-active`, `status`, `list`, `feature-section`. |
| `progress.sh` | Manage the active cycle's `progress.md`. Subcommands: `init`, `activate`, `finish`, `requeue`, `reset`, `reorder`, `enqueue`, `get-active`, `queue-remaining`, `get`, `set`, `advance`, `advance-to`, `add-clear-recommendation`, `has-clear-recommendation`, `check-worktree`. |
| `todo.sh` | Manage `todo-list.md`. Subcommands: `set-state`, `bulk-transition` (optional `--feature`), `pend-selected`, `list <state>`, `add`. Enforces the state machine and assignee invariants. |
| `folder-id.sh` | Manage `id.md` markers and `reference.md`. Subcommands: `ensure`, `get`, `resolve <id>`, `list`, `init-reference`, `link-feature`. |
| `blueprints.sh` | Manage `blueprints/`. Subcommands: `ensure-current`, `rotate`, `resume-partial`, `preserve-inspector-sections`, `check-current [--require-primer]`, `branch-status`. Rotation is resumable (`.partial.tmp → .partial → vN`). |
| `review.sh` | Manage `inspector-review.md` / `review-context.md`. Subcommands: `init`, `add`, `set-status`, `iterate`, `list-open`, `list-open-summaries`, `sync-refs`, `canonicalize`, `strip-freeform`, plus the manual-test seeding helpers (`find-by-seed-id`, `find-by-seed-id-family`, `upsert-manual-test-failure`). IDs are `IR-NNN`, monotonically incremented. |
| `commits.sh` | Query `base-commit..HEAD`. Subcommands: `list`, `yaml`, `populate-requirements`, `changed-files`, `changed-files-only`, `change-summary-fresh`, `diagrams-fresh`. |
| `ingest.sh` | Convert non-text journal files to sibling `.md` (docling for documents, stub for images / short PDFs). |
| `doctor.sh` | Dependency detection. JSON or human output; `--preflight` mode runs `git rev-parse --verify HEAD`. |
| `bundle.sh` | Engine for `/mi-export-bundle`. Subcommand: `export`. |
| `info-bar.sh` | Pull-only Claude Code `statusLine` renderer (not a hook). Reads stdin JSON, prints one line, exits 0; ≤ 100 ms hot-path target. |
| `ledger.sh` | Manage `context-ledger.md`. Subcommands: `init`, `append`. Append failures warn but never block. |
| `pr-review.sh` | Drive `/mi-analyze-review`. Subcommands: `parse-url`, `new-session`, `fetch`, `canonicalize`, `count-marked`, `find-awaiting`, `list-actionable`, `normalize`, `set-status`, `post-reply`, `report-status`. |
| `lessons.sh` | Manage `lessons-learned.md` (cumulative PR-review lessons). Subcommands: `path`, `append` (auto-increments `L-NNN` ids). |
| `migrate-diagrams-readme.sh` | One-shot back-fill of `requirements-id` / `id` into legacy diagram READMEs. |
| `migrate-test-folder.sh` | One-shot migration of legacy manual-test artifacts into the feature-permanent `test/` folder. |
| `internal/common.sh` | Shared helpers sourced by every script: `mi_data_root`, path resolvers, `mi_quest_compute_slug`, frontmatter helpers, `mi_render_template` (YAML-encodes substituted values), the worktree guard `mi_assert_worktree_match`. |
| `internal/validate-frontmatter.sh` | Run by the PostToolUse hook — loads a schema, validates `.md` frontmatter, exits non-zero on failure. |

### 8.6 Sub-agent profiles (`agents/`)

Delegation is implemented through **first-class agent profiles** under `agents/` — one
Markdown file per profile with YAML frontmatter (`name`, `description`, `model`, optional
`effort`, `tools`). Commands invoke them by name through the `Agent`/`Task` tool. Every
profile returns per `docs/sub-agent-return-contract.md` with a ≤ 1k-token return body
(`Result`, `Artifacts changed`, `Commits`, `Findings / risks`, `Main should read`);
detailed evidence belongs in artifact files, not the return. There are **11 profiles**:

| Profile | Model / effort | Spawned by | Output |
| --- | --- | --- | --- |
| `journal-file-digester` | haiku / low | `mi-run` Step 2.5 Tier 1 — one oversized journal file (> 100 KB) | digest in the return body — read-only, no file writes |
| `journal-folder-digester` | haiku / medium | `mi-run` Step 2.5 Tier 2 — one journal subfolder (> 5 files AND > 40 KB) | writes `quest/<active-slug>/.scratch/folder-digest-<folder>.md` |
| `dependency-mapper` | sonnet / medium | `mi-continue` Pre-flight Step 4c (stage 1.5) | a 2–3 sentence ordering proposal — no file writes; main composes `queue-rationale.md` |
| `codebase-grounder` | sonnet / high | `mi-apply-impact` Step A (stage 2) | writes `implementation/grounding-report.md`; sets `seam-classification`. ≤ 5 files per todo |
| `blueprint-diagrammer` | sonnet / high | `mi-apply-impact` Step C (stage 2) | writes `.puml` sources into `blueprints/current/diagrams/` (has the PlantUML MCP tools) |
| `implementation-analyst` | opus / high | `mi-generate-implementation-diagrams` / `mi-draw-diagrams` (stage 4) | writes `implementation/change-summary.md`; re-renders `implementation/diagrams/` |
| `review-iteration-runner` | opus / high | `mi-review` (stage 6 brainstorming mode) | calls `review.sh set-status`; has the `Skill` tool and chains into `brainstorming`/`writing-plans` for `re-spec`/`re-plan` cascades |
| `sidequest-reader` | sonnet | `/mi-sidequest` (no `--write`) | read-only — answers a mid-workflow question; no Edit/Write |
| `sidequest-writer` | sonnet | `/mi-sidequest --write` | answers + performs a small fix; edits project source only — workflow artifacts stay read-only |
| `review-comment-analyst` | sonnet / high | `/mi-analyze-review` | appends one `### PR-NNN` block per comment to `report.md`; read-only on source |
| `pr-review-fixer` | sonnet / high | `/mi-continue` PR-Review Apply Handler | applies marked fix blocks, commits them, appends lessons to `lessons-learned.md`; enforces a clean-worktree invariant |

**Do NOT delegate** (these stay with main): workflow state mutations (`progress.sh`,
`todo.sh`, `blueprints.sh`, `review.sh set-status` outside `review-iteration-runner`),
stage transitions, command dispatch, final approvals, the y/n confirmation gates, and any
context-budget gating decisions.

### 8.7 The PlantUML MCP integration and diagram conventions

`plugin.json` registers `plantuml-mcp-server` as an MCP server; the millwright (and the
diagram sub-agents, which carry the PlantUML MCP tools) invoke it to render `.puml` sources
to images during stage 2 and the Resume Handler. The inspector installs the binary
themselves (e.g. `npm install -g plantuml-mcp-server`).

Diagram conventions (enforced by the millwright, not by tooling):

- **File naming** — lowercase kebab-case, `<type>-<subject>.puml` where `<type> ∈
  {use-case, sequence, class, component}`; one diagram per file.
- **Mandatory** — exactly one `use-case-<feature>.puml` per feature.
- **Conditional** — 2–3 `sequence-<flow>.puml` per feature. One is acceptable only for a
  genuinely single-flow feature; needing more than 3 is a signal to decompose the feature
  and the millwright surfaces this rather than rendering a fourth.
- **Optional, at most one** — `class-<domain>.puml` OR `component-<subject>.puml`, never
  both. Fires only on `backend`/`mixed` seams (per the stage-2 codebase-grounding pass)
  meeting a content threshold (3+ classes with non-trivial relationships → class; 3+
  components with non-trivial dependencies → component; linear chains and pure UI/infra
  seams skip the slot).
- **Existing-vs-new framing** — both stage-2 blueprint diagrams and stage-4 implementation
  diagrams use one fixed two-colour convention: **blue (`#D6EAF8` fill, `#3498DB` strokes)
  for pre-existing system elements**, **green (`#D4EDDA` fill, `#27AE60` strokes) for new /
  to-be-implemented elements**, plus a `legend right … endlegend` block whose wording
  reflects the cycle flavor (`greenfield` / `bugfix` / `improvement`). The baseline differs
  by stage: stage 2 uses current HEAD as `existing` and the seams sketched by Goals as
  `new`; stage 4 uses `base-commit` as `existing` and `base-commit..HEAD` as `new`.
- **Sibling `README.md`** — `.puml` files have no YAML; the enclosing `diagrams/` folder
  carries a `README.md` with the `requirements-id` back-reference (blueprint side) or
  `stage: implementation` (implementation side).
- **Render gate** — `diagram-rendering` (`never` by default, `on-request`) governs whether
  `.svg`/`.png` are produced; `diagram-prompt` (`prompt` by default, `auto`) governs
  whether the inspector is asked before each diagram event.

### 8.8 The branch contract

The git branch is owned by the inspector end-to-end. Mi-workflow never creates, deletes,
or force-updates branches.

- **Creation** — the inspector's responsibility, whenever it fits their rhythm.
- **Declaration** — in `blueprints/current/config.md`'s `## GIT BRANCH` section. Pre-filled
  at stage 2 from HEAD when HEAD is non-trunk; otherwise left blank.
- **Validation at stage 3** — exactly one branch line; branch ≠ `main`/`master`; branch ==
  current HEAD. An empty section → the millwright prompts the inspector.
- **Persistence** — `progress.md.active.branch` is null until stage 3, then set;
  `active.base-commit` is captured from HEAD at the same time.
- **One branch per feature** — features may share or differ; the plugin doesn't enforce
  sameness across the queue.

### 8.9 The blueprint lifecycle

`blueprints/current/` is a *living* snapshot. Every refresh is a rotation: the previous
`current/` content moves into `blueprints/history/v[N+1]/` and a new `current/` is
regenerated. Each history version carries a sibling `reason.md` recording why:

| Trigger | `reason.md` kind | Regeneration source |
| --- | --- | --- |
| Stage 8 (`mi-complete-workflow`) | `completion` | n/a — `current/` becomes empty; the live `implementation/` is archived alongside |
| Stage-4 drift check, inspector-supplied reason | `spec-update` (via `/mi-update-blueprint`) | implementation-driven |
| Review-loop `re-spec` cascade | `re-spec-cascade` | implementation-driven |
| Review-loop `re-plan` cascade (inspector confirms) | `re-plan-cascade` | implementation-driven |
| `/mi-update-blueprint <reason>` (manual) | `manual` | implementation-driven |

Stage 2's first-time generation is **quest-driven** — it reads the active cycle's
`summary.md` plus the codebase per `docs/blueprint-regeneration.md`. Mid-cycle refreshes
are **implementation-driven** — they read `change-summary.md` + targeted `git diff
base-commit..HEAD` hunks + the previous history version; the journal and quest files are
intake artifacts that don't drift after stage 1.5 and are deliberately not consulted.
**The rotation is resumable** (`.partial.tmp → .partial → vN`), so a session break between
any two file-system steps leaves a recoverable state.

### 8.10 The review file schema

`inspector-review.md` is the single review artifact. Findings are `### IR-NNN` blocks with
monotonically increasing, zero-padded, never-reused IDs. Per finding:

- **severity**: `blocker` | `major` | `minor` (advisory metadata, not a hard gate).
- **scope**: `fix` | `re-implement` | `re-plan` | `re-spec`.
- **status**: `open` | `fixed` | `wontfix`.
- **details**: multi-line markdown body.
- **fix-note**: populated on `fixed` / `wontfix`.

Scope classifies the smallest rework that genuinely addresses the finding and controls
which chain step is re-entered. Cascade priority (descending impact, tier-0 wins):

1. **re-spec** — re-invokes `brainstorming`; cascades through writing-plans + executing-plans.
2. **re-plan** — re-invokes `writing-plans`; cascades through executing-plans.
3. **re-implement** — re-invokes `executing-plans` / `subagent-driven-development` against
   the existing plan.
4. **fix** — direct patch.

When a higher-tier scope fires, all open lower-scope findings get `fixed` with a
`fix-note: "superseded by re-spec at iteration N"` because the code that drew them no
longer exists. Iterations are nested under `## Iteration N` headers; IDs stay stable
across iterations. Review is implementation-only — findings compare `base-commit..HEAD`
against `requirements.md`; the chain's plan/spec files are not part of the review surface.
The inspector may write plain sentences; `/mi-continue`'s Inspector Handler canonicalizes
them into `### IR-NNN` blocks before the review session starts.

### 8.11 Optional companions

Detected by `/mi-doctor` but never required — the workflow runs identically without them:

- **`rtk`** (rtk-ai/rtk) — a pre-tool-use hook that filters verbose shell output (git
  diffs, test runs, logs) before it reaches Claude. No plugin-level integration; once
  installed it applies session-wide. Install: `brew install rtk && rtk init -g`.
- **`docling`** (docling-project/docling) — IBM's document → markdown converter that
  powers `/mi-ingest`. Required only for `.docx`/`.pptx`/`.xlsx`/`.html` and PDFs over 20
  pages. Pulls ML dependencies (torch, transformers); first conversion downloads a few
  hundred MB of model weights. Skip it if the journal will only ever contain `.md`,
  `.txt`, short PDFs, and images — `Read` covers all of those natively.
- **`ajv-cli`** — used for deep JSON Schema validation of workflow files; the hook falls
  back to `yq`-based structural checks if it is absent.

### 8.12 Skill references

The stage-3 brainstorming chain and the stage-6 brainstorming review session depend on
five named skills: `brainstorming`, `writing-plans`, `executing-plans`,
`subagent-driven-development`, `finishing-a-development-branch`. They can come from either
the **superpowers plugin** (resolves names like `superpowers:brainstorming`) or local
`SKILL.md` files under `.claude/skills/<name>/`. `mi-doctor` accepts both sources
interchangeably and prints the exact install commands when one is missing.

### 8.13 Main-read budget gates by stage

Each stage's command body has an explicit budget for what the **main agent** may read
directly; reads outside the budget must be delegated to a fresh sub-agent or surface an
explicit override prompt.

| Stage | Command(s) | Allowed main reads | Delegated / forbidden in main |
| --- | --- | --- | --- |
| 1 | `/mi-run` | Journal files (per the Step 2.5 size policy) | Source code |
| 1.5 | `/mi-continue` Pre-flight | `summary.md`, `todo-list.md`, `progress.md` | Source code (delegated to `dependency-mapper` if ambiguous) |
| 2 | `/mi-apply-impact` | `summary.md` (active section + cross-cutting), generated artifacts | Codebase grounding pass — delegated to `codebase-grounder` |
| 3 | `/mi-plan-implementation` | `primer.md`, chain outputs | Bulk source reads — handled by the chain |
| 4 | Resume / `/mi-draw-diagrams` | `change-summary.md`, `progress.md`, drift-probe filesystem state | Diagram-source generation — delegated to `implementation-analyst` |
| 5 | `/mi-continue` Inspector | `inspector-review.md`, `progress.md` | (none significant) |
| 6 | `/mi-review` | `review-context.md`, `inspector-review.md` (open IRs) | Source reads — delegated to `review-iteration-runner` unless direct mode + all `fix` findings |
| 8 | `/mi-complete-workflow` | `change-summary.md`, archived blueprint files | (rotates + archives only) |

Enforcement is currently a documented contract; the `context-ledger.md` telemetry artifact
is the regression-detection oracle — a `large`-class read with `location: main` in a stage
that forbids it surfaces in the ledger as a budget violation.

---

## 9. End-to-end happy-path walkthrough

A single feature (`auth`), brainstorming planning, brainstorming review, one finding.

```
[Inspector]  Drops journal/auth-meeting/{transcript.txt, notes.md}.
[Inspector]  Types: /mi-init                                  # one-time setup
[Millwright] Installs deps via single y/n; scaffolds journal/, quest/, workflow-stream/.

[Inspector]  Types: /mi-run auth-meeting
[Millwright] Runs doctor preflight (incl. git rev-parse --verify HEAD); computes slug
             2026-04-27-auth-meeting; creates quest/2026-04-27-auth-meeting/;
             quest.sh start writes quest/active.md; generates todo-list.md, summary.md,
             progress.md (active=null, queue=[auth]), and reference.md (journal-refs).

[Inspector]  Edits todo-list.md: marks AUTH-001 and AUTH-002 with [x] (emin).
[Inspector]  Types: /mi-continue                              # stage 1.5 step A
[Millwright] todo.sh pend-selected; groups PENDING by feature; proposes order: [auth].
[Inspector]  Types: /mi-continue                              # stage 1.5 step B (accept)
[Millwright] Writes queue-rationale.md; progress.sh reorder; auto-fires /mi-apply-impact.

[Millwright] /mi-apply-impact: progress.sh activate (auth → active block).
             codebase-grounder writes grounding-report.md; generates requirements.md
             (Goals/Planned/Non-goals), config.md (## GIT BRANCH pre-filled feat/auth/jwt),
             and use-case + sequence diagrams via blueprint-diagrammer.
[Inspector]  Reviews blueprint files; adds prompts under ## Inspector Additions.

[Inspector]  Types: /mi-continue                              # stage 2 approve
[Millwright] Approve Handler validates blueprints, fires stage-2-to-3 clear-point gate,
             auto-fires /mi-plan-implementation.
[Millwright] PENDING → IMPLEMENTING; captures base-commit; writes primer.md;
             asks: "planning-mode? brainstorming or direct?"
[Inspector]  Types: brainstorming
[Millwright] Persists planning-mode; sub-flow=chain-in-progress; invokes brainstorming skill.
[Inspector + chain]  brainstorming → writing-plans → executing-plans →
             subagent-driven-development → finishing-a-development-branch.
             Commits land on feat/auth/jwt.

[Inspector]  Types: /mi-continue                              # stage 3 → 5 (4 never persisted)
[Millwright] Resume Handler: drift probe; verifies commits; sets implementation-completed;
             asks for the drift reason. Inspector types: continue.
             Auto-fires /mi-draw-diagrams (implementation-analyst renders diagrams).
             Initializes inspector-review.md skeleton. Asks: "Run manual testing? (y/n)".
[Inspector]  Types: n
[Millwright] Atomic advance-to 3 5; prints the stage-5 handoff message.

[Inspector]  Reviews implementation/diagrams/ + the diff; edits inspector-review.md:
             "The JWT signing function in auth/jwt.ts hard-codes HS256; make it configurable."
[Inspector]  Types: /mi-continue                              # stage 5
[Millwright] Inspector Handler: review.sh canonicalize finds the free-form span;
             classifies severity=major, scope=re-implement; review.sh add → IR-001;
             review.sh strip-freeform. list-open returns ["IR-001"]. Auto-fires /mi-review.
[Millwright] /mi-review: stage-5-to-6 clear-point gate; writes review-context.md;
             sub-flow=reviewing; advances 5→6; asks: "review-mode? brainstorming or direct?"
[Inspector]  Types: brainstorming
[Millwright] review-iteration-runner addresses IR-001, edits auth/jwt.ts, commits,
             review.sh set-status IR-001 fixed. Asks the inspector for approval.
[Inspector]  Types: approve
[Inspector]  Types: /mi-continue                              # stage 6 → 7 → 8
[Millwright] Review-Resume Handler: list-open empty; y/n completion confirmation.
[Inspector]  Types: y
[Millwright] Offers a diagram refresh (review-loop commits exist).
[Inspector]  Types: y
[Millwright] Re-runs /mi-draw-diagrams; atomic advance-to 6 7; auto-fires /mi-complete-workflow.
[Millwright] /mi-complete-workflow: todo.sh bulk-transition IMPLEMENTING IMPLEMENTED;
             commits.sh populate-requirements; blueprints.sh rotate --reason-kind completion
             (current/* → history/v1/, AND archives implementation/ as
             history/v1/implementation/); progress.sh finish.
             Queue empty; no [ ] TODO remain — quest.sh end archives the pointer;
             recommends /mi-run for the next cycle.
```

**Inspector touchpoints:** `/mi-init`, `/mi-run auth-meeting`, edit todo-list,
`/mi-continue`, `/mi-continue`, edit `## Inspector Additions`, `/mi-continue`,
`brainstorming`, drove the chain, `/mi-continue`, `continue` (drift skip), `n` (manual-test
skip), edit `inspector-review.md`, `/mi-continue`, `brainstorming`, drove the review
session, `approve`, `/mi-continue`, `y` (completion confirmation), `y` (diagram refresh).

**Millwright auto-actions:** `/mi-apply-impact`, `/mi-plan-implementation`,
`/mi-draw-diagrams`, `/mi-review`, `/mi-draw-diagrams` (refresh), `/mi-complete-workflow`,
plus every `progress.sh` / `todo.sh` / `blueprints.sh` / `review.sh` / `commits.sh`
invocation. Clear-point recommendations fire at stage-2→3, stage-5→6, and feature-A→feature-B
(the inspector is asked to type `/clear` themselves — Claude Code does not let agents
invoke `/clear` programmatically).

---

## 10. Glossary

- **Active block** — the populated `active:` section of `progress.md` while a feature is
  mid-cycle. Null between features.
- **Active cycle / active slug** — the cycle named by `quest/active.md`. All cycle-scoped
  scripts resolve their working files under `quest/<active-slug>/` via `quest.sh dir`.
- **Activation id** — `progress.md.active.activation-id`, a UUID minted at `activate` and
  re-minted at `reset`. A git-independent cross-activation discriminator for the
  manual-test results-rotation guard.
- **Agentic engineering** — coordinating AI agents and runbooks to ship production-quality
  software faster without sacrificing the pre-AI quality bar. The plugin operates entirely
  in this paradigm, in both planning modes.
- **Base-commit** — the git SHA captured at stage 3 just before chain launch / direct
  implementation. The lower bound of the implementation diff.
- **Blueprint** — the `requirements.md` + `config.md` + `primer.md` + `diagrams/` set under
  `blueprints/current/`.
- **Brainstorming chain** — the isolated session running `brainstorming` → `writing-plans`
  → `executing-plans` (or `subagent-driven-development`) → `finishing-a-development-branch`.
- **Canonicalize** — convert a free-form finding sentence into a structured `### IR-NNN`
  block (`review.sh canonicalize` + classification + `review.sh add` + `strip-freeform`).
- **Clear-point** — a recommendation by the millwright to type `/clear` at a
  high-context-payoff transition. Three points fire: `stage-2-to-3`, `stage-5-to-6`, and
  feature-A→feature-B. The first two record their id in `clear-recommendations`; the third
  is one-shot.
- **Context artifact** — any `.md` or `.puml` file the millwright generates under `quest/`
  or `workflow-stream/`, named for its dual role: an inspection surface for the inspector
  and a context carrier the millwright reads back to rebuild its working context for the
  next stage (§1.5).
- **Context Artifact Relay** — the mechanism by which a stage's context artifacts stay
  inert until the inspector's advancement signal (`/mi-continue` / `approve`) energizes the
  relay and dispatches them into the next stage. One firing per inspector gate; durable (on
  disk), layered (primer-first), and able to cascade auto-fired commands (§1.5).
- **Context ledger** — the per-cycle telemetry artifact `quest/<active-slug>/context-ledger.md`.
- **Cycle** — the lifespan of a single `quest/<slug>/` cohort, from `/mi-run` to all
  features completed (or the cycle aborted/archived). Older cycle subfolders are preserved
  permanently as a task archive.
- **Decisions log** — the feature-scoped, append-only `workflow-stream/<feature>/decisions.md`,
  excluded from blueprint rotation.
- **Direct mode** — a planning-mode or review-mode that keeps work in the main session
  instead of spawning a Skill.
- **Drift check** — the post-chain (stage-4) prompt asking whether requirements changed
  during brainstorming. Replies: a `<reason>`, `auto`, or `continue`.
- **Drift-completion probe** — Resume Handler Step 0; detects a successful prior
  `spec-update` rotation whose marker write was lost to a session break.
- **Existing-vs-new framing** — the blue/green two-colour diagram convention (§8.7).
- **Export bundle** — the self-contained markdown file produced by `/mi-export-bundle`.
- **Folder linking** — the `id.md` + `reference.md` ID-based links tying journal, quest,
  and workflow-stream folders (§3.6).
- **Grounding report** — the stage-2 codebase-grounding snapshot
  `implementation/grounding-report.md`, written by the `codebase-grounder` sub-agent.
- **History version (vN)** — a snapshot of `blueprints/current/` rotated into
  `blueprints/history/vN/` with a sibling `reason.md`.
- **Inspector** — the human role. **Millwright** — the AI agent role.
- **IR-NNN** — a finding ID in `inspector-review.md`; zero-padded, monotonically
  increasing, never reused.
- **Jagged intelligence** — the unevenness of LLM capability across tasks; it drives the
  plugin's defensive recovery branches.
- **Layered load** — the primer-first context discipline (Rule 3); canonical files are
  fallbacks.
- **Lessons-learned** — `lessons-learned.md` at the data root: a cumulative, append-only
  record of PR-review lessons (`L-NNN` blocks), written by the `pr-review-fixer` sub-agent.
- **Manual-testing sub-flow** — the optional stage-5 sub-flow (§7.5).
- **Multi-batch queue-rationale** — `queue-rationale.md`'s `## Batch <N>` body shape; the
  dispatcher's Row A relies on `features − completed == queue` exactly.
- **PR-review report** — `pr-reviews/<session>/report.md`, the inspector-triaged work list
  produced by `/mi-analyze-review`; its `status` (`awaiting-marks` / `partial` / `applied`)
  is the contract with `/mi-continue`'s PR-Review Apply Handler.
- **Primer** — a compact derived snapshot (`primer.md`, `review-context.md`) that bootstraps
  a long-running stage.
- **`progress.sh advance-to`** — atomic skip-transition with a stage-pair whitelist
  (`3→5`, `5→7`, `6→7`); `--set field=value` arguments land in the same atomic write.
- **Quest** — the cycle-wide working state under `quest/<active-slug>/`, plus the permanent
  archive of past cycles, plus the `quest/active.md` pointer.
- **re-spec / re-plan / re-implement / fix** — the four scope tiers for a finding, in
  descending order of chain impact.
- **Resumable rotation** — `blueprints.sh rotate`'s `.partial.tmp → .partial → vN` flow.
- **Resume / Approve / Pre-flight / Inspector / Review-Resume / Manual-Test-Resume Handler;
  PR-Review Apply Handler** — the dispatch targets inside `/mi-continue` (§7.4, §7.8).
- **Side-quest** — a mid-workflow question or small ask run in an isolated sub-agent via
  `/mi-sidequest` (§7.7).
- **Software 3.0** — the view that with capable LLMs, programming shifts to curating
  prompts and context windows; operationalized here through Rule 1 and Rule 3.
- **Stage** — one of 0–8 in the canonical workflow. Stage 4 is conceptual — the Resume
  Handler runs "stage 4" work but `current-stage` never persists 4.
- **Stage info-bar** — the pull-only `statusLine` renderer `scripts/info-bar.sh`, wired by
  `/mi-init-status-bar`.
- **Sub-flow** — `none | chain-in-progress | resuming | reviewing | manual-testing` — a
  secondary state dimension on top of `current-stage`.
- **Vibe coding** — landing an implementation against an unwritten or informal spec with no
  structured review. **The mi-workflow is explicitly not vibe coding** — even
  `planning-mode: direct` keeps the stage-2 spec, the primer, the stage-4 diagrams, the
  findings file, and the rotation history.
- **Verifiable artifact** — a workflow output checkable against a finite contract
  (`requirements.md.commits`, the blue/green diagrams, `IR-NNN` findings, the
  `base-commit..HEAD` diff). Every cycle ends with a set of these, not just code.
- **Worktree-fingerprint guard** — `mi_assert_worktree_match`, which compares the current
  working tree against the immutable `worktree-path` / `git-common-dir` / `git-worktree-dir`
  recorded at activation and refuses cross-worktree state mutations.
- **Workflow stream** — the per-feature folder tree under `workflow-stream/<feature>/`.
