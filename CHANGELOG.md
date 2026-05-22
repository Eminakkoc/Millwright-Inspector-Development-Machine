# Changelog

## 1.3.0 — Blueprint-lessons injection at stage 2

Stage 2 now consumes prior PR-review lessons. A new `lessons-filter` sub-agent
spawned from `mi-apply-impact`'s Pre-Step A reads `lessons-learned.md`,
picks blueprint-creation-relevant entries for the active feature, and writes
`workflow-stream/<feature>/implementation/blueprint-lessons.md`. That artifact
is then read by main (composing `requirements.md`), the `codebase-grounder`
sub-agent, and the codex blueprint review (consistency + per-item phases via
sibling-detection in the orchestrator and its two single-purpose variants).
At stage 8 the artifact rotates into `history/v[N+1]/implementation/`
alongside `grounding-report.md`.

Before this release, `lessons-learned.md` was only consumed at stage 3 (via
`config.md`'s `## Lessons learned` pointer). Blueprint-level mistakes the
inspector had already caught in prior cycles could recur in fresh blueprints,
and the codex blueprint review couldn't flag them either.

### What changed

- **New `lessons-filter` sub-agent** (`agents/lessons-filter.md`,
  `haiku/medium`): reads `lessons-learned.md`, `todo-list.md`, and the
  active feature's `summary.md` section. Each selected lesson must tie back
  to one of four anchors: active todo id, planned todo id, cross-cutting
  constraint, or feature-level concern. Lessons that can't be tied back are
  dropped. Read-only on the source lessons file.

- **New artifact** `workflow-stream/<feature>/implementation/blueprint-lessons.md`,
  with schema (`schemas/blueprint-lessons.schema.yaml`) and init template
  (`templates/blueprint-lessons.md.tmpl`). Main owns artifact init and every
  frontmatter field (`id`, `feature`, `requirements-id`, `lessons-source-mtime`);
  the sub-agent owns only `selected-count` and the body.

- **`mi-apply-impact` Step 1.5**: guards on `lessons-learned.md` existence
  (skip cleanly when absent), runs the filter sub-agent, and clobbers the
  artifact via `frontmatter.sh init` re-run on `Result: blocked` or
  schema-validation failure. The `--force` cleanup path now also removes
  `grounding-report.md` and `blueprint-lessons.md` from `implementation/`
  (allowlisted, not wholesale, to protect any stage-5+ state).

- **`docs/blueprint-regeneration.md` Step A**: main reads
  `blueprint-lessons.md` (when present, `selected-count > 0`) before
  composing requirements. The `codebase-grounder` spawn-prompt template
  gets a new "Lessons from prior PR reviews" reads block pointing at the
  artifact. A new sub-step at the end of Step A backfills
  `requirements-id` into `blueprint-lessons.md` via guarded `frontmatter.sh
  get` + `set`.

- **Codex review wiring** (`/mi-blueprint-review`,
  `/mi-blueprint-review-consistency`, `/mi-blueprint-review-item`): each
  command resolves a `lessons_block` string once via sibling-detection
  against `<file>`'s blueprints/current parent → `../../implementation/blueprint-lessons.md`
  → `selected-count > 0`. The block is passed as a new spawn input to the
  consistency and per-item reviewer sub-agents, which substitute it into
  the new `{{LESSONS_BLOCK}}` placeholder in their prompt templates. Empty
  substitution drops the placeholder line entirely so pre-feature
  rendering is preserved. `/mi-blueprint-review-item` Mode B (stateless
  content, no file anchor) always passes empty.

- **`mi-complete-workflow` archive allowlist**: extended to include
  `blueprint-lessons.md` between `grounding-report.md` and `diagrams/`.
  Historical-snapshot prose updated to match.

### Testing

11-case integration harness at `tests/blueprint-lessons/run.sh` covers
schema validation, template init (including the `!RAW!` sentinel for
integer fields), `--force` cleanup contract, sibling-detection across four
branches, and the archive allowlist. Six manual-test scenarios documented
in `docs/superpowers/plans/2026-05-22-blueprint-lessons-injection-manual-tests.md`
cover the parts requiring a live model invocation (filter relevance
judgment, blocked recovery). All six manual scenarios verified end-to-end
against `feature/test-plugin/` before the release.

### Project doc

`docs/millwright-inspector-project.md` updated: §3.4 tree diagram and
archive prose now list `blueprint-lessons.md`; §8.6 sub-agent profile table
gains a `lessons-filter` row (profile count 13 → 14); §5 Roles × surface
table's `/mi-apply-impact` row mentions `lessons-filter Pre-Step A`.

## 1.2.4 — Blueprints review: tighten `resolved` criterion + reasoning_effort plumbing

Two fixes from the v1.2.3 Scenario-2 (20-item) stress test (REPORT-4).

### F4 — Tightened `resolved` criterion in the reconciliation contract

In REPORT-4's Phase 1 iter 2, codex marked finding F-006 as `resolved` despite
no edit actually addressing it. Likely cause: with whole-file context + an
existing-findings list, the reviewer could rationalize "the broader spec is
now clearer" as resolution even when the finding's `suggested-fix` was never
applied.

Fix: both reviewer prompt templates now require `status: "resolved"` to
include a `resolved_by_change:` field naming the exact edit that addressed
the finding. The instruction is explicit: "if you cannot point at a specific
edit that addresses the finding's `suggested-fix`, the status is
`still-present`, not `resolved`".

Both sub-agents now downgrade `resolved → still-present` if `resolved_by_change`
is missing or empty, as a defensive guard against legacy reviewers that
don't follow the new contract.

### G3 — `--reasoning-effort` plumbing; default `medium`

REPORT-4's full-run cost projection at the agent file's `effort: high` is
~60-80 min wall-clock and ~800k-1M tokens for a 20-item spec. That's wrong
for an auto-fire from stage 2.

Fix: added `--reasoning-effort <low|medium|high>` flag to:
- `/mi-blueprint-review` (orchestrator)
- `/mi-blueprint-review-consistency` (singleton)
- `/mi-blueprint-review-item` (singleton, both modes)

Default is `medium` everywhere. The flag is plumbed through spawn prompts to
both sub-agents (`reasoning_effort` input field) and from there to every
reviewer MCP call. `mi-apply-impact` Step B.5's auto-fire of the orchestrator
inherits the default; no caller change needed.

Note: `effort:` in the agent files' frontmatter (Claude's own reasoning effort)
is unchanged — that controls the sub-agent's orchestration work, not the
reviewer agent's depth.

## 1.2.3 — Blueprints review: iteration-aware depth (comprehensive iter 1, differential iter 2+)

Cuts "discovery" findings — pre-existing ambiguities the reviewer didn't
surface in iter 1 because of v1.2.1's terseness cap, which then appeared as
confusing "new" findings in iter 2 and pushed the loop toward max-iter.

### What changed

- **Both reviewer prompt templates** (`templates/blueprint-reviewer-prompt-{consistency,item}.md.tmpl`):
  Replaced the unconditional "prefer 1-3 findings, cap at 3" instruction with
  iteration-aware depth:
  - **Iter 1 — comprehensive sweep.** Surface EVERY finding that meets the
    "implementations diverge" calibration. No count cap. Missing something here
    means it shows up in iter 2 as a fake-new finding.
  - **Iter 2 or later — differential focus, cap 4 new findings.** Focus on
    re-evaluating existing findings (via the reconciliation contract) and on
    issues the fix step introduced. Pre-existing ambiguities should not appear
    as "new" — they should have been caught in iter 1.

### Why

v1.2.1's terseness cap was a blunt fix for v1.2.0's noisy iter 1. After v1.2.1's
calibration ("two implementations would meaningfully diverge") landed, the noise
was already gone but the cap remained. The cap was now suppressing real findings
in iter 1, which surfaced as "new" findings in iter 2 — looking like cascades
but actually being discoveries.

REPORT-2 (v1.2.1) Phase 1 iter 2 found PAY-001/PAY-004 unknown-event scope
ambiguity. That issue existed in iter-1's file; codex simply didn't flag it
because the cap pushed it below the visible threshold. v1.2.3's comprehensive
iter 1 should catch it up front.

### What this can't fix

True cascades — findings caused by the fixer rewriting content that did not
exist in iter 1 — are unaffected. Those need I4 (inspector-mediated marking)
or structural changes. v1.2.3 only tackles Discovery findings.

## 1.2.2 — Blueprints review: relax stop-on-stable to accept `refined`

Bug-fix release surfaced by the v1.2.1 Scenario-1 re-test (REPORT-2).

### What changed

- **Both reviewer sub-agents** (`agents/blueprint-{consistency,item}-reviewer.md`): the stop-on-stable predicate now reads `every existing has status ∈ {still-present, refined}` instead of the stricter `every existing has status == still-present`. Same change applied to stable-medium-only (clause c).

### Why

In the v1.2.1 re-test, codex sometimes returned `refined` for an existing finding — same underlying issue, sharpened wording. The strict predicate treated `refined` as "not stable", forcing the loop to `max-iter` even though no new findings appeared. `refined` is operationally equivalent to `still-present` for loop-convergence purposes (the reviewer is just polishing, not finding new content).

Verified against the captured iter-2 reviewer responses from REPORT-2: all 4 per-item loops now exit `stable` instead of 2 of 4 hitting `max-iter`. Exit signal is now correctly "loop converged, can't auto-fix" rather than the ambiguous "out of budget".

## 1.2.1 — Blueprints review: convergence + audit-trail fixes from Scenario-1 testing

Polish pass on the v1.2.0 reviewer loop after a manual end-to-end test surfaced
that every loop hit max-iter (the reviewer kept finding new things; the fixer
kept introducing new issues). Tightens reviewer scope, adds early-exit on
convergence, switches to id-based reconciliation, and makes finding ids
lifetime-monotonic.

### What changed

- **Reviewer prompt templates** (`templates/blueprint-reviewer-prompt-{consistency,item}.md.tmpl`):
  - **Tighter scope (I3).** Reviewers now flag ONLY issues where two reasonable
    implementations would meaningfully diverge in observable behavior. Style
    nits and "could be tighter" feedback are out of scope unless they cause
    ambiguity. Per-iteration cap of 3 findings (top-by-severity) keeps loops
    tractable.
  - **Id-based reconciliation (O7).** Reviewer now returns
    `{existing: [...], new: [...]}` instead of a flat findings array. For each
    existing finding (passed in via a new `{{EXISTING_FINDINGS}}` placeholder),
    the reviewer returns `status: still-present | resolved | refined`. The
    sub-agent processes deterministically by id instead of doing fuzzy
    content-similarity match.

- **Reviewer sub-agents** (`agents/blueprint-{consistency,item}-reviewer.md`):
  - **Stop-on-stable (I1).** After iter 2, if the reviewer's `new` array is
    empty AND every existing finding is `still-present`, exit early with
    `Result: partial; reason: stable`. The loop has converged at "these
    findings exist and the fixer can't resolve them" — further iterations
    cost without progress.
  - **Severity-stratified completion (I2).** After iter 2, if no high
    findings (kept or new) AND no new mediums (only stable ones remain),
    exit with `Result: partial; reason: stable-medium`. Inspector tolerance
    for stable mediums is high — surface and continue.
  - Findings/risks now carries a `reason:` line on every partial exit so the
    orchestrator can choose the right user-facing message.

- **Orchestrator `--scope <heading>` flag (O1).** `/mi-blueprint-review` now
  accepts `--scope "Goals (this cycle)"` to restrict per-item enumeration to
  one section. Stage-2 auto-fire (`mi-apply-impact` Step B.5) passes
  `--scope "Goals (this cycle)"` so Planned + Non-goals items aren't reviewed
  per-item. Standalone invocation without `--scope` enumerates everything
  (preserves general-file utility).

- **Lifetime-monotonic F-NNN ids (O2).** New optional `last-finding-id: F-NNN`
  field in `schemas/requirements.schema.yaml`. `scripts/blueprint-review.sh
  alloc-final-id` reads, increments, writes back, and emits the new id
  atomically — id space is now lifetime-monotonic so resolved findings don't
  free up their ids. Bootstraps from existing body F-NNN max when the field
  is absent.

### Migration notes

- v1.2.0 files without `last-finding-id` in frontmatter are auto-handled —
  `alloc-final-id` bootstraps the field on first call after upgrade.
- The reviewer prompt's output shape changed from a JSON array to a JSON
  object. Any external consumer of the reviewer-tool output needs to handle
  both shapes during the transition (the design's only consumers are the
  reviewer sub-agents themselves, which have been updated atomically).

See `feature/test-plugin/reports/findings-and-improvements.md` (gitignored)
for the detailed analysis that motivated this release.

## 1.2.0 — Blueprints review: AI-driven consistency + per-item review

Adds three slash commands and two reviewer sub-agents that use an external coding agent (Codex first) via MCP to review markdown spec files (especially `requirements.md` at stage 2) for cross-item consistency and per-item completeness. Findings live inline in the reviewed file as `<!-- REVIEW-FINDING -->` HTML comments; resolved findings are cleaned up automatically.

### What changed

- **New commands** under `commands/`:
  - `/mi-blueprint-review-consistency <agent> <max-iter> <file>` — whole-file consistency loop.
  - `/mi-blueprint-review-item <agent> <max-iter> <file:item-id | content>` — per-item loop, two modes (file-anchored / stateless).
  - `/mi-blueprint-review <agent> <max-c-iter> <max-i-iter> <file>` — orchestrator: consistency → per-item batched → final consistency.
- **New sub-agents** under `agents/`:
  - `blueprint-consistency-reviewer` — serial; writes the file directly.
  - `blueprint-item-reviewer` — strictly read-only (`tools:` contains only the reviewer MCP tool); returns region replacements via a Payload JSON extension to the sub-agent return contract.
- **New script** `scripts/blueprint-review.sh` with subcommands: `resolve-tool`, `enumerate` (deterministic offset computation from reviewer-supplied `{id, anchor_line, occurrence_index}`), `parse-findings`, `alloc-final-id`, `diff-drift`.
- **Three new templates** under `templates/` for the consistency, per-item, and enumeration reviewer prompts.
- **Stage-2 integration:** `mi-apply-impact` now auto-invokes the orchestrator on `requirements.md` between `config.md` generation and diagram generation. Skipped gracefully when codex MCP is unavailable; handoff message reflects the actual run/skip state.
- **`docs/sub-agent-return-contract.md`** gains a "Payload JSON extension" section documenting the fenced-block pattern for sub-agents that need to hand back structured data.
- **`scripts/doctor.sh`** gains a `mcp:codex` check (non-blocking).
- **`plugin.json`** declares the `codex` MCP server (`codex mcp-server`).

See [`docs/blueprints-review/plan.md`](./docs/blueprints-review/plan.md) and [`docs/blueprints-review/implementation.md`](./docs/blueprints-review/implementation.md) for full design and implementation history.

## 1.1.0 — Folder linking: journal ↔ quest ↔ workflow-stream

ID-based links now tie the three workflow folder trees together, so a quest
cycle can always be traced back to the journal folders it grew from and
forward to the feature folders it produced — even after a folder is renamed
or moved.

### What changed

- **`id.md` folder markers.** Each `journal/<topic>/` and
  `workflow-stream/<feature>/` folder gets an `id.md` carrying a stable UUID
  (frontmatter `id`) that identifies the *folder*. Minted lazily on first use.
- **`reference.md` link table.** Each quest cycle subfolder gets a
  `reference.md` (validated by the new `reference` schema). Its `journal-refs`
  frontmatter array links the cycle to its source journal folders; its
  `feature-refs` array links it to the feature folders it produces.
  `/mi-run` writes `journal-refs` at stage 1; `blueprints.sh ensure-current`
  appends `feature-refs` at stage 2.
- **`scripts/folder-id.sh`.** New script managing `id.md` and `reference.md`:
  `ensure`, `get`, `resolve <id>`, `list`, `init-reference`, `link-feature`.
- **Schemas + validation.** New `folder-id` and `reference` schemas; the
  PostToolUse hook validates `journal/*/id.md`, `workflow-stream/*/id.md`,
  and `quest/*/reference.md`.

Existing workspaces are not migrated: journal folders get an `id.md` the next
time `/mi-run` reads them, and already-finished quest cycles get no
`reference.md`. New cycles get the full treatment.

## 1.0.0 — Rename: "overseer" → "inspector"

**Breaking.** The plugin has been renamed throughout. The reviewer role is now
the *inspector* (previously *overseer*), and the `mo-` command prefix is now
`mi-`. This is a clean break: there are no compatibility shims, aliases, or
migration prompts.

### What changed

- **Plugin identity.** Marketplace name `millwright-overseer` →
  `millwright-inspector`; plugin name `millwright-overseer-development-machine`
  → `millwright-inspector-development-machine`.
- **Commands.** Every `/mo-*` command is now `/mi-*` (e.g. `/mo-run` →
  `/mi-run`, `/mo-init` → `/mi-init`).
- **Data root.** The default workflow data folder is now `millwright-inspector/`
  (was `millwright-overseer/`). There is no fallback to the old folder.
- **Runtime files.** The `progress.md` field `overseer-review-completed` is now
  `inspector-review-completed`; the `config.md` section header
  `## Overseer Additions` is now `## Inspector Additions`; the review file
  `implementation/overseer-review.md` is now `implementation/inspector-review.md`;
  the PR-review report field `overseer-notes` is now `inspector-notes`.
- **Environment / internals.** `MO_DATA_ROOT`/`MO_PLUGIN_ROOT` →
  `MI_DATA_ROOT`/`MI_PLUGIN_ROOT`; internal `mo_*` bash helpers → `mi_*`; the
  `mo:` status prefix and `mo:sync-marker` comment → `mi:`; the status-bar
  wrapper `.claude/mo-stage-info-bar.sh` → `.claude/mi-stage-info-bar.sh`.
  (`CLAUDE_PLUGIN_ROOT` is provided by the Claude Code runtime and is
  unchanged.)

The new plugin does not read or migrate old `millwright-overseer/` data, and
the frontmatter hook rejects writes to the legacy `overseer-review.md` path.

### Migration for existing users

1. Uninstall the old plugin: `/plugin uninstall millwright-overseer-development-machine`
2. Remove the old marketplace: `/plugin marketplace remove millwright-overseer`
3. Re-add the marketplace: `/plugin marketplace add <repo>`
4. Install the new plugin: `/plugin install millwright-inspector-development-machine@millwright-inspector`
5. Start fresh with a `millwright-inspector/` data root.

To carry forward in-flight data, `mv millwright-overseer millwright-inspector`
manually and hand-edit any `progress.md` and `config.md` so the field and
section-header names match the new schema — the plugin will not migrate them
and will reject malformed files.

Status-bar users re-run `/mi-init-status-bar` after upgrading.

### New home

The plugin now lives at a new repository:
https://github.com/Eminakkoc/Millwright-Inspector-Development-Machine
The `marketplace.json` `homepage` field points there.
