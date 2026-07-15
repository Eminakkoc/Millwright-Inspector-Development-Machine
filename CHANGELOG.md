# Changelog

## 1.6.1 — Ship the `stage-5-to-6` clear-point gate

Implements the third clear-point the docs already described: `/mi-review` now offers
the inspector a `/clear` between stage-5 findings authoring and the stage-6 review
session. Stage 6 was always designed to rehydrate from disk (`review-context.md` is
composed fresh from canonical files; brainstorming iterations run in fresh sub-agents),
so the gate flushes the bulkiest main-context stretch of the workflow — the
manual-test-run transcript and findings back-and-forth — at zero information cost.

### What changed

- **New Step 1.5 in `/mi-review`** — mirrors the `stage-2-to-3` gate in
  `/mi-continue`: a mandatory `decisions.md` write-check (Step 1.5a sweeps
  uncaptured stage-5 verbal decisions into `## Stage 5 — Findings canonicalization`),
  then a one-shot branch on `progress.sh has-clear-recommendation stage-5-to-6`
  (Step 1.5b): first entry records the flag, appends a `clear-offer-recommendation`
  ledger row, prints the recommendation, and halts before `sub-flow`/stage mutate;
  re-entry appends `post-offer-resume` + rehydration ledger rows and proceeds.
  Stage-6 re-launches (review-loop rotations) and pre-gate mid-flight features
  skip the gate silently (`gate_state=not-armed`).
- **Inspector Step 3b in `/mi-continue`** — no longer prints "review session is now
  live" when `/mi-review` halted at the gate; the gate's recommendation is the
  terminal message and the next `/mi-continue` re-enters the handler idempotently.
- **Docs aligned** — project doc §5 stage-6 launcher + §8 `/mi-review` entry now
  describe the shipped gate; the Step 2.5 fold-in note in `mi-review.md` no longer
  hedges on the gate being unshipped. No schema or script changes:
  `clear-recommendations` already enumerated `stage-5-to-6`, and
  `add-/has-clear-recommendation` were already id-agnostic.

## 1.6.0 — Workflow-completion lessons distillation (stage 8)

Closes the lessons loop: until now `lessons-learned.md` had exactly one writer — the
`pr-review-fixer` sub-agent on the standalone GitHub-PR-review path — so a workflow that
never went through an external PR review produced zero lessons, even though the
consumption side (stage-2 `lessons-filter` injection into blueprint creation) was fully
built.

### What changed

- **New `agents/lessons-distiller.md`** (sonnet / high; `Read`, `Bash`, `Grep`).
  Reads the finished cycle's evidence artifacts — `inspector-review.md` (resolved
  IR-NNN blocks, especially `re-spec` / `re-plan` tier), `review-history.md`,
  `manual-test-results.md`, `decisions.md`, `change-summary.md`,
  `grounding-report.md` — and appends at most **5 generalizable lessons** per cycle
  via `lessons.sh append`. Judgment bar: "would knowing this at stage 2/3 have
  changed an artifact or the approach?" Zero lessons is a valid outcome; existing
  `L-NNN` entries are read first to avoid duplicates (the stage-2 filter is
  haiku-class — noise degrades its selection).
- **New Step 3.5 in `/mi-complete-workflow`** — runs on Branch III only, *before*
  Step 4's rotation so evidence artifacts are still at their live paths. Stage 8 is
  the universal funnel (both the findings path 6→7→8 and the no-findings
  auto-finalize path 5→7→8 end there), so every completed workflow now distills.
- **Idempotency fence.** Every distilled lesson's `--source` begins with
  `workflow:<feature>/<requirements-id>`; Step 3.5 greps for that prefix before
  spawning, so crash-and-reenter (and the 0a/I/II recovery branches) never
  double-append. `lessons.sh append` continues to self-validate after each write.
- **Best-effort contract.** A `blocked` / failed distillation logs a warning and
  completion proceeds — Step 3.5 can never wedge stage 8.
- **Docs widened** (`lessons.sh` header, project doc §3.1/§5/§6.2/§7.3/§8.5/§8.6/
  §8.13/glossary, sub-agent return-contract binding table): `lessons-learned.md` is
  now "PR-review **+ workflow-completion** lessons" with two writers.

## 1.5.0 — Blueprint review token-reduction refit

**Breaking CLI change.** Replaces v1.2.x's positional `<max-c-iter> <max-i-iter>` args
with a single `--auto-iter N` flag (default `3`). Per-batch concurrency exposed via
`--concurrency N` (default `3`). Default `--batch-size` reduced from `5` to `3`.

Net effect on a 20-item stage-2 auto-fire (REPORT-4 baseline → v1.5 projection):
codex calls drop ~107 → ~25; token cost drops ~1M → ~50k; wall-clock drops ~60–80 min
→ ~10–15 min. Finding quality preserved (REPORT-4 evidence that iter-1 per-item review
self-regulates at ~4 findings regardless of iteration budget).

### What changed

- **`mcp__codex__codex-reply` session continuation** for all rounds ≥ 2 within a single
  review loop. Round 1 opens the session via `mcp__codex__codex`; rounds 2+ ship
  delta-only prompts (the file / batch content lives in session state). When
  `codex-reply` is unavailable (codex-cli < 0.130.0), sub-agents fall back to stateless
  mode (~60% reduction instead of ~95%).
- **Per-batch reviewer** (`agents/blueprint-batch-reviewer.md`) replaces the per-item
  reviewer. One sub-agent per batch of 1..N items; one codex session per batch.
  Standalone `/mi-blueprint-review-item` becomes a thin `batch_size=1` wrapper.
- **Consolidated phase structure.** v1.2.x's initial consistency fix-loop is gone;
  Phase D becomes the single fix-and-converge consistency pass that sees Phase C's
  per-item findings as inline context. Phases run: A (preflight + summary build) → B
  (enumerate) → C (per-batch parallel waves) → D (consistency) → F (persist) → G
  (report).
- **`review-history.md` sibling artifact** for cross-cycle memory. Co-located with
  `requirements.md` in `blueprints/current/`; rotates with the blueprint at
  `/mi-update-blueprint` and `/mi-complete-workflow` (via the wildcard
  `blueprints.sh rotate` move — no special-case wiring). Append-only within a
  blueprint version. Main builds a deterministic ≤ 1500-token summary
  (`scripts/blueprint-review.sh build-summary`) for every reviewer session opener so
  the reviewer avoids re-discovering resolved findings.
- **Envelope trim** (~30–50% per-call prompt-size reduction):
  - YAML frontmatter stripped from `{{FILE_CONTENT}}`.
  - `{{EXISTING_FINDINGS}}` bullet list collapsed to a one-line pointer (single
    source of truth: inline `<!-- REVIEW-FINDING -->` blocks).
  - `{{LESSONS_BLOCK}}` removed from per-item / batch review (cross-item by nature —
    Phase D's consistency pass catches lesson-violating findings).
  - Reconciliation contract prose compressed (~110 lines → ~50).
- **New `scripts/blueprint-review.sh` subcommands:** `build-summary` (deterministic
  history-summary renderer with truncation invariant that protects unresolved-high
  and current-item-tied resolved findings), `persist-findings` (append new + update
  existing-to-resolved/dropped + recompute frontmatter counters).
- **New schema + template + hook validation** for `review-history.md`.
- **`mi-apply-impact` Step B.4** lazily inits `review-history.md` before Step B.5's
  orchestrator auto-fire. Step B.5's CLI invocation collapses to the new shape;
  defaults cover the rest. `--force` cleanup explicitly removes `review-history.md`.
- **`mi-update-blueprint` and `mi-complete-workflow`** carry `review-history.md`
  through rotation / archive alongside `requirements.md` (no code change — the
  wildcard `blueprints.sh rotate` covers it; only descriptive prose updated).
- **`mi-doctor` annotates the codex check** with codex-reply availability based on
  installed codex-cli version (>= 0.130.0 gets the v1.5 cost-reduction path).

### Removed

- `agents/blueprint-item-reviewer.md` (replaced by `blueprint-batch-reviewer.md`)
- `templates/blueprint-reviewer-prompt-item.md.tmpl` (replaced by
  `blueprint-reviewer-prompt-batch.md.tmpl`)

### Testing

17-case integration harness at `tests/blueprint-review/run.sh` covers schema
validation, init template, hook validation (positive + outside-data-root no-op),
`build-summary` (filter / truncation / scope), and `persist-findings` (append / status
update / counter recomputation). Seven manual scenarios in
`docs/superpowers/plans/2026-05-23-blueprint-review-token-reduction-manual-tests.md`
cover the live-codex paths (cold start, warm history, 20-item stress, single-item,
mid-run abort, codex-unavailable, session-expiry fallback).

### Migration

- Breaking CLI change. No back-compat shim. Existing scripts invoking
  `/mi-blueprint-review` must drop the two positional iter args.
- Existing blueprints get a `review-history.md` lazily initialized on the first v1.5
  run. No backfill of historical findings — they were never preserved before.
- Reviewer prompt rendering changes shape; the multi-item `items[]` array in batch
  reviewer responses is the new contract for any external consumer.

See [`docs/blueprint-review-token-reduction/plan.md`](./docs/blueprint-review-token-reduction/plan.md) for
the full design and [`docs/blueprint-review-token-reduction/phase-0-findings.md`](./docs/blueprint-review-token-reduction/phase-0-findings.md)
for the verified `mcp__codex__codex-reply` MCP shape. The v1.2.x prior art
([`docs/blueprints-review/plan.md`](./docs/blueprints-review/plan.md)) carries forward
unchanged: item enumeration, canonical region descriptor, `alloc-final-id` semantics.

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
