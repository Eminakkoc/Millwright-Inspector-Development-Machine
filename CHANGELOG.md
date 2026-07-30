# Changelog

## 1.6.12 — Delegation is part of the command contract

Field report: a stage-2 run stopped mid-flight and asked the inspector to adjudicate a
rule collision. `/mi-apply-impact` structurally requires three sub-agents
(`codebase-grounder`, `blueprint-diagrammer`, `lessons-filter`), and §8.13's main-read
budget *forbids* main from doing that work itself — while Claude Code ships a default
instruction not to call the Agent tool unless the user requested it. Refusing to delegate
left only two outs: blow the budget, or ship an ungrounded blueprint.

**Root cause — the plugin never granted its own permission.** Eleven commands (16 call
sites) name sub-agents they cannot run without, but no command said that invoking it
*constitutes* requesting them. The collision was structural and would recur at nearly
every stage, since 11 of the 24 commands delegate.

### What changed

- **New project-doc §8.15 — "Delegation is part of the command contract".** Invoking an
  `mi-*` command *is* the user requesting the delegations that command declares: the
  sub-agents are named in the command body, their contracts live in `agents/`, and the
  command cannot satisfy its own spec without them. A default aimed at *unrequested*
  fan-out does not reach a delegation the user requested by name when they typed the
  command. The boundary is stated exactly so the default keeps its teeth — sanctioned
  means a sub-agent this command names, at the step that names it, for the work described
  there; everything else (unnamed sub-agents, invented parallelism) stays forbidden.
- **Self-sufficient "Delegation contract" note in all 11 delegating commands**, under the
  H1 next to the Runtime-bootstrap note, each naming its own sub-agents and the step that
  spawns them — so an agent can act on it without reading §8.15. `mi-continue` additionally
  records that handlers auto-firing another `mi-*` command inherit that command's contract.
- **No silent downgrade.** Every note states that a delegation which genuinely cannot run
  (type unavailable, harness refusal) must be reported and stop the command — never
  quietly performed in main. §8.13 now cross-references §8.15 for the same reason: the
  budget forbidding main from the work is what makes the delegation mandatory.
- **Lint guard (3 new checks).** Every command on the delegating list carries the note and
  cites §8.15; a reverse drift net fails when a command names a `subagent_type` but is
  absent from that list (a new delegation site that never got the note); and §8.15 must
  exist in the project doc. Negative-tested: removing one note fails the suite.

## 1.6.11 — Readable requirements: inline reference glosses + one-sentence walkthrough summaries

Both changes target the same reader: the inspector approving `requirements.md` at the
stage-2 gate. The file was written at the right altitude but still assumed the reader
already knew what `AUTH-003`, `services/payments/`, or `JWT` meant, and the optional
walkthrough opened each item with a paragraph rather than a takeaway.

### What changed

- **Inline glosses on every reference (non-normative, ≤ 3 words).** New rule in
  `docs/blueprint-regeneration.md` Step A: whenever an item names another item id, a
  file/folder/module path, a symbol, a link, or an abbreviation, a parenthetical gloss of
  at most 3 words follows it on first mention **inside that item** — `AUTH-003 (JWT role
  claims)`, `services/payments/ (payment handlers)`, `JWT (signed login token)`. It
  applies to the top-level bullet and every nested sub-bullet (`**Shipped-code impact:**`
  included). Repeat across items (each is read on its own), never within one. Skipped when
  the sentence already explains the reference and for universally-known terms (HTTP, URL,
  JSON, ID, API, CLI, UI, DB). The reference itself always stays verbatim — the gloss goes
  beside it, never instead of it, so ids and paths remain greppable. Mirrored in
  `templates/requirements.md.tmpl` and in `/mi-update-blueprint` Step 4b, where the
  rewritten Goals items gloss the real post-implementation symbols read out of the diff.
- **Both reviewer prompts treat glosses as invisible.** `blueprint-reviewer-prompt-batch`
  and `-consistency` now put glosses out of scope alongside the `_In plain terms:_`
  sub-bullet: never flagged as vague or as introducing a component, never a source of a
  requirement, and — for the consistency pass — two differently-worded glosses on the same
  reference are not terminology drift. Without this the ≤ 3-word aid would have read as an
  under-specified requirement and the review would have grown the file fixing it.
- **A one-sentence summary opens every walkthrough item.** `/mi-apply-impact` Step 3.3 now
  presents three bars per item instead of two — a single plain sentence, then the 2–4
  sentence explanation, then the worked example — each a level more concrete than the last.
  The new bar carries no item ids, paths, symbols, or acronyms and leads with the outcome
  rather than the mechanism; it is never skipped for "simple" items and never collapsed
  into the paragraph below it. The stage-2 hand-off message advertises it.

## 1.6.10 — Scope-expansion gate: blueprint review stops growing `requirements.md`

Field report: blueprint reviews kept adding new mechanisms to the requirements without
asking, so the file got bigger on every run.

**Root cause — the fix step had no scope contract.** Both reviewer sub-agents documented
exactly how to manipulate `<!-- REVIEW-FINDING -->` comment blocks, and both round-2+
prompts opened with "I applied your suggested fixes", but nothing defined what *applying a
fix* was allowed to change. Three things compounded it: `--auto-iter 5` gives up to five
fix rounds per batch and per consistency pass; the reviewer's in-scope list ("missing
acceptance criteria", "ambiguous edge cases") makes *adding* the cheapest way to resolve
anything; and `review-history.md` had no "the human decided against this" state, so a
mechanism the inspector implicitly rejected was rediscovered and re-applied on the next
run.

### What changed

- **`scope_impact` on every finding** — `clarifying` (restates existing intent: wording, an
  already-implied AC, the seam the item already points at, picking one of two readings the
  text contains) or `expanding` (requires building something the spec lacks today: retry,
  caching, audit trail, versioning, rate limiting, migration, feature flag, background job,
  new endpoint, new config surface, new error regime, a new AC implying new work, a new
  item, an untouched seam). Independent of severity. Both prompt templates now instruct:
  prefer the smallest fix, prefer deleting ambiguity over adding mechanism — and an
  `expanding` finding is *legitimate*, it just isn't the reviewer's decision to apply.
- **The fixer applies `clarifying` fixes only.** `expanding` fixes are never auto-applied.
  Both sub-agents verify the reviewer's self-label (a "clarifying" fix introducing a noun
  the spec lacks — component, policy, store, job, flag, endpoint, lifecycle — is
  reclassified and skipped), treat missing/unknown values as `expanding`, and bound even
  clarifying fixes to the smallest span (a net addition beyond ~2 lines is itself the
  signal that mechanism is being added).
- **New Phase E — scope-expansion gate.** All expanding findings are shown once, as one
  compact list, each a single line naming the mechanism it would add, alongside the run's
  growth stat. The inspector answers `none` (default), `all`, an id list, or `keep <ids>`.
  Only approved fixes are applied. Non-interactive runs apply nothing and record
  `still-present` — silence is neither consent nor refusal. Ledger-enforced exactly like
  Phase C: `skipped` is sanctioned only when marked `--findings 0`, so the gate cannot be
  quietly bypassed. Both wrapper commands run it too (Mode B of `-item` excepted: stateless,
  applies nothing).
- **Declined proposals are remembered.** Phase F persists them as `last-status: deferred`
  with a `deferred-reason`, and `build-summary` renders them into every future reviewer
  session under "DECLINED BY THE INSPECTOR — do NOT re-raise". Without this the gate would
  hold for exactly one run. `deferred` is terminal (doesn't inflate
  `finding-count-unresolved`); the summary protects declined entries ahead of legacy lows,
  keeps at least the 5 most recent, and says when older ones were dropped for budget.
- **Deferred findings no longer burn iterations.** An item or file whose only remaining
  findings are `expanding` is converged — the fixer cannot act on them by contract. The
  consistency reviewer gains a `stable-deferred` exit; delta prompts name the deferred ids
  and forbid re-raising them, escalating them, or proposing the same mechanism under
  another name.
- **Growth is now reported.** New `blueprint-review.sh size-stat` (body lines / items /
  bytes, with frontmatter and finding blocks excluded) is captured as a Phase A baseline
  via a new `ledger … meta` key/value store and reported in Phase G, so creeping expansion
  is visible run over run even when each individual fix looked reasonable.

### Tests

Seven new cases in `tests/blueprint-review/run.sh`: declined findings render as
do-NOT-re-raise and not as unresolved; `deferred` is terminal in the counters; `scope-impact`
is persisted on new findings; `size-stat` strips frontmatter and finding blocks; Phase E
cannot be skipped while expanding findings exist; `ledger meta` round-trips across
invocations; and a wiring guard across templates, agents, and the orchestrator. 59 pass,
0 fail.

## 1.6.8 — Blueprint-review severities, shipped-code regression checks, guided manual tests

Three changes, one theme: make the quality gates say what actually matters and let the
inspector see it for themselves.

### Blueprint-review severities: `blocker | critical | high | medium` (no `low`)

- **Two new severities.** `blocker` — the item cannot be implemented as written, or
  implementing it breaks already-shipped behavior with no stated migration; work stops
  until a human resolves it. `critical` — implementations will diverge AND the wrong
  branch costs data, security, or a silent regression. `high` and `medium` keep their
  existing meanings.
- **`low` is out of scope, not just deprioritized.** Both reviewer prompt templates
  declare the class unreportable, and both reviewer sub-agents apply a deterministic
  severity gate that **drops** any `low` the reviewer emits anyway — no block appended,
  no `F-NNN` allocated, never re-mapped up to `medium`, reported as `dropped-low: N`. A
  round whose `new[]` was entirely dropped counts as empty for every convergence check,
  so nits can no longer keep a loop iterating.
- **Backward compatible.** `severity: low` blocks written by earlier versions stay in
  place, still parse, and still reconcile. `build-summary`'s rank table keeps `low` last
  (`blocker < critical < high < medium < low`) so legacy histories truncate
  deterministically, and legacy `low` is now the *only* severity the truncation loop may
  drop — an over-budget summary of reportable findings accepts the overrun instead.
- Reporting updated end to end: the consistency reviewer's `stable-medium` exit no longer
  fires while a blocker or critical is kept, count lines read `<B>B/<C>C/<H>H/<M>M`, and
  Phase G escalates each remaining blocker/critical on its own line.

### Requirements are written and reviewed against already-shipped code

- **Grounding pass (stage 2).** `codebase-grounder` now assesses regression risk as a
  first-class deliverable: a per-item `**Shipped-code impact:**` line (which call sites,
  consumers, routes, events, tables, or UI flows depend on the seam today; what changes
  for them; what must keep holding and how to observe it) plus a cross-item
  `## Shipped-code regression risks` section in `grounding-report.md`. Symbol and
  call-site searches are explicitly free against the ≤ 5-file-per-item budget.
- **Requirements body.** Every `## Goals` item carries a **normative** nested
  `- **Shipped-code impact:** …` bullet. `none — additive only` is a valid answer;
  omission is not, and an item the grounding pass never assessed is written `unassessed`
  and surfaced in the hand-off rather than guessed at. `/mi-update-blueprint` re-derives
  the same bullet from the `base-commit..HEAD` diff.
- **Review.** Shipped-code regression is an in-scope finding class for both passes — per
  item in the batch template, file-wide (two items that jointly break a contract, a
  Non-goal contradicted by a Goal) in the consistency template. Reviewers ground findings
  in the item's own bullet, the grounding report, and bounded read-only repo access
  (~5 files, only when a concrete path or symbol is named).
- **Manual testing.** The plan's regression-seam coverage cell now starts from those
  bullets: every named consumer that "must keep holding" is a required scenario.

### Manual testing: guided mode + post-autonomous re-run

- **New `guided` env-mode — what `y` now selects.** The millwright brings the whole local
  environment up itself (the same bring-up machinery as autonomous), then walks the
  inspector through the plan one scenario at a time: what it checks in ≤ 2 plain
  sentences, one concrete example, exactly what to do — then waits for the inspector's
  `pass` / `fail` / `skip` / `pause`. Verdicts stay the inspector's; the millwright never
  self-determines one, and never presents two scenarios in a turn.
- **Mid-walk additions.** The inspector can ask for anything to be recorded as they go:
  notes fold into that scenario's `Observation:`; ad-hoc extra checks land as
  `### INS-<n>` blocks under a new `## Inspector-added checks` section that is excluded
  from the plan-shaped counters, the cursor, and seeding. Verdict-block parsing is now
  explicitly scoped to `## Per-scenario verdicts` so the two never mix.
- **`interactive` is unchanged and still reachable** via `/mi-manual-test-run
  --interactive-env` (and remains the compatibility reading of a *missing*
  `manual-test-env-mode`); `y` simply no longer selects it, because "run the app for me,
  then walk me through it" is the common case. Two follow-ons so nothing defaults
  silently: a forced plan regeneration resets the mode to `guided` (matching what `y`
  selects) rather than `interactive`, and a bare `/mi-manual-test-run` on a fresh run
  with no persisted mode and no flag **asks** which mode to use instead of assuming —
  never on a resume, and never on an auto-fire path, both of which always have an
  explicit value.
- **Guided re-run after a hands-off run.** An autonomous run now always offers a guided
  walkthrough when it finishes — a machine's verdicts are not the same as the inspector's
  eyes. `/mi-manual-test-run --rerun-guided` (Branch D) is the same path, directly
  invocable later: it rotates the finished results into history, keeps the plan (so the
  `seed-family-id` and therefore idempotent re-seeding survive), resets the markers to a
  running guided run, and converges into the normal Branch A flow. It never closes or
  reopens IRs — a scenario the millwright failed and the inspector passes stays seeded
  until the inspector resolves it.

### Tests

`tests/blueprint-review/run.sh` gains three cases: blocker > critical > high > medium
ordering in `build-summary`, no reportable severity dropped from an over-budget summary,
and a wiring guard that the templates/agents declare the new vocabulary and carry no stale
`high|medium|low` enum. 52 pass, 0 fail.

## 1.6.6 — Canonical `$CLAUDE_PLUGIN_ROOT` resolver documentation (§8.14)

Claude Code does not inject `$CLAUDE_PLUGIN_ROOT` into Bash tool subshells
(anthropics/claude-code#48230), so on marketplace installs every command's
`$CLAUDE_PLUGIN_ROOT/scripts/…` reference silently depended on the executing agent
improvising a resolution. Only `mi-continue.md` documented the resolver; the other 23
commands assumed the variable worked.

### What changed

- **New project-doc §8.14 — "Resolving `$CLAUDE_PLUGIN_ROOT` in Bash blocks".** The
  canonical writeup: why the env var is best-effort, why the resolver must be an
  inline pattern (finding a script requires the very root being resolved), the
  three-source fallback (validated env var → source-repo `$PWD` → `installPath` from
  `~/.claude/plugins/installed_plugins.json`), refuse-with-environmental-diagnostic,
  and the export + per-cwd-tempfile persistence with the per-block recovery one-liner
  (each Bash call is a fresh subshell — anthropics/claude-code#2508).
- **`mi-continue.md` Step 1a** named as the reference implementation; its inline
  resolver is unchanged and its rationale now cites §8.14.
- **Standard "Runtime bootstrap" note added to the other 23 commands** that use
  `$CLAUDE_PLUGIN_ROOT`, directly under each H1. The note is self-sufficient (inlines
  the three-source order and persist/recover steps) so an agent can act on it before
  it can read the doc.

## 1.6.5 — Blueprint-review fixes: reference manifest bugs + codex tool-name portability

Two field-reported defects, both verified against the repo before fixing.

### What changed

- **`/mi-apply-impact` Step B.4.5 — two bugs, the second masked by the first.**
  (1) The manifest builder called `quest.sh slug` with no args — which
  unconditionally errors (it computes slugs from journal-folder args; the active-slug
  accessor is `quest.sh current`) — and the `|| true` swallow left `active_slug`
  empty, silently dropping `summary.md` from every review manifest's reference list.
  (2) The summary reference path was one directory level too shallow
  (`../../../quest/…` resolves to `workflow-stream/quest/…`; references resolve
  relative to the manifest's directory, so four levels are needed). Both fixed;
  codex reviews now receive the full reference set.
- **Codex MCP tool-name portability.** The reviewer agents' `tools:` frontmatter
  pinned unprefixed `mcp__codex__codex[-reply]`, which only resolves when the codex
  server is registered at user/project level; marketplace installs register it via
  `plugin.json` and expose plugin-prefixed names
  (`mcp__plugin_millwright-inspector-development-machine_codex__codex[-reply]`),
  leaving the agents with no resolvable tools. Fixes: both spellings listed in the
  agents' `tools:` (unresolvable names drop out of the allowlist); agent bodies now
  call the `reviewer_tool_name` / `reviewer_reply_tool_name` spawn inputs instead of
  hard-coded names; `/mi-blueprint-review` Step 1 gains an explicit tool-name
  resolution step (verify inventory → reassign to prefixed spellings → refuse with a
  `/mi-doctor` pointer if neither exists) whose resolved values feed every direct
  call and spawn input; the two wrapper commands reference the same rule.

## 1.6.4 — Feature-name uniqueness gate (workflow-stream collision prevention)

Fixes artifact mixing when two different journal folders distill to the same feature
name: journal `general-fixes-1` (completed workflow) and `general-fixes-2` (new cycle)
both produced feature `general-fixes`, so the new cycle's artifacts landed in the
completed workflow's `workflow-stream/general-fixes/` folder.

### What changed

- **New `folder-id.sh feature-lineage-check <feature>`** — answers "may the active
  cycle safely use this feature name?" from the existing folder-linking metadata
  (quest `reference.md` journal-refs/feature-refs). Exit 0 = safe (folder absent,
  already linked to the active cycle, or shares a source journal folder — genuine
  continuation); exit 3 = collision (lineage disjoint); exit 4 = unknown lineage
  (pre-linking folder / orphan — treated as collision).
- **`/mi-run` Step 3 — mandatory uniqueness gate** before `todo-list.md` is written.
  Colliding candidates are renamed automatically, preferring the source journal
  folder's own name (journal `general-fixes-2` → feature `general-fixes-2`); the
  final names flow into `related-features`, `summary.md`, and the queue together, and
  renames are surfaced in the Step 6 hand-off. Intentional cross-cycle reuse (test
  plans, `decisions.md`) still works: re-selecting the feature's original journal
  folder passes the check as same-lineage.
- **`/mi-apply-impact` activation backstop** — the same check runs at fresh
  activation (before `ensure-current` creates/links the folder) for cycles
  scaffolded before the gate and hand-edited queues; on collision it halts with the
  lineage diagnostic and asks the inspector to `proceed` (knowing reuse) or abort
  and fix the name at stage 1.

## 1.6.3 — Optional requirements walkthrough at the stage-2 review gate

The stage-2 hand-off (blueprints + diagrams generated, inspector asked to review)
now offers a guided, one-item-at-a-time walkthrough of `requirements.md` — replacing
the custom prompt inspectors used to paste by hand.

### What changed

- **`/mi-apply-impact` Step 3.2** — the hand-off message offers `walkthrough`
  (natural-language equivalents accepted) alongside `/mi-continue`. The same offer
  appears on the `check-current=0` re-entry short-circuit, which is the same review
  gate re-entered.
- **New Step 3.3 — the walkthrough loop.** Enumerates the top-level items under
  `## Goals (this cycle)` / `## Planned (future cycles)` / `## Non-goals (out of
  scope)` in file order and presents exactly one per turn: item quoted verbatim, a
  2–4 sentence jargon-free explanation, and one concrete input → observable-outcome
  example — required to go deeper than the item's inline `_In plain terms:_` /
  `_Example:_` sub-bullets, never repeat them. Waits for `next` between items;
  questions keep the cursor on the current item; `stop` exits early with a
  remaining-items note.
- **Decision capture** — mid-walkthrough scope decisions are persisted immediately
  (a `requirements.md` edit or a `decisions.md` entry) instead of relying on the
  Approve Handler's end-of-stage sweep, whose recent-turns window a long walkthrough
  can outrun.
- **No state mutation** — purely conversational (one context-ledger row), repeatable,
  and not a substitute for the explicit `/mi-continue` approval gate. Project doc
  stage-2 section updated to match.

## 1.6.2 — Manual-test depth: exhaustive plans + no-skip autonomous runs

Two quality tightenings on the stage-5 manual-test sub-flow.

### What changed

- **`/mi-manual-test-plan` Step 5 — mandatory scenario depth & coverage bar.** The
  plan is now generated against an explicit coverage matrix: every Goal (happy +
  failure path), every changed area, edge/boundary cases, error paths with the
  specific error surface, state transitions & idempotency, regression seams, and
  non-goal boundaries — each cell needs ≥1 scenario or an explicit waiver in the
  new `## 4. Coverage notes` section (template gains the section + `{{COVERAGE_NOTES}}`,
  kept outside § 3 so scenario parsers never mistake a waiver for a scenario).
  Per-scenario depth bar: executable without reading the source, copy-paste-concrete
  Actions, one observable per Expected bullet. Scenarios must also be written
  autonomous-runnable — each Expected names WHERE it is observable, and visual-only
  checks list machine-checkable side-effects.
- **`/mi-manual-test-run` autonomous mode — 100%-execution contract.** New 3.2b
  item 4: attempt every scenario with real tools before judging; pre-judging from
  scenario text, similarity, or effort is banned. The `skip` verdict (3.3b) is now
  a last resort gated on a three-step attempt protocol (run the Actions, try every
  observation channel per Expected, seek an objective proxy for subjective checks),
  with an explicit list of invalid reasons ("similar to previous", "low value",
  time/effort, "likely passes"). New pre-finalize skip audit in Step 4.1: before
  `state: complete`, every skip verdict is re-checked against the bar — convenience
  skips re-enter the Step 3 loop and get executed; the autonomous roll-up now lists
  each surviving skip with the unobservable expectation and channels attempted.

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
