# Changelog

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
