# Feature-test workflow — design

**Feature:** `feature-test-workflow`
**Branch:** `feat/mi-run/feature-test-workflow`
**Date:** 2026-08-14
**Goals covered:** FTW-001 … FTW-009

## Problem

The sibling `feature-test-queue-entry` feature makes a multi-feature cycle emit a
terminal `## <first-feature>-feature-test` section, auto-select it, and pin it to the end
of the queue. Nothing runs it. When that entry reaches the front of the queue today it is
activated like any other feature: `/mi-apply-impact` builds it a blueprint, the inspector
is asked to approve requirements for work that was already built, and stage 3 launches a
planning chain with nothing to plan.

This feature gives the entry its own abbreviated pipeline — five steps that validate the
assembled feature without re-running the machinery that builds features.

## Scope

The abbreviated pipeline and the two artifacts it derives. The queue entry itself, its
derived name, and its selection state are inputs, owned by `feature-test-queue-entry`
(complete). The carried-forward scenarios that merge into the plan are owned by
`deferred-test-items` (`DTI-005`); this feature owns the merge *point*, not the merge.

## Constraints carried in from the journal

- **Additive, never a replacement.** Every ordinary feature keeps its full 8-stage
  workflow including its own manual-test phase. The whole-feature test sits after them.
- **Multi-feature cycles only.** A single-feature cycle behaves exactly as today.
- **Terminal.** Nothing runs after a successful feature-test entry; cycle completion is
  gated on it.
- **Artifact layout is prescribed.** `<feature-name>-feature-test/` with `implementation/`
  and `test/` children — honour those names rather than inventing a parallel convention.
- **Reuse the existing findings loop verbatim.** Route into the existing
  inspector-review / resolution machinery; do not fork it.

## Approach

The pipeline introduces **no new state values**. The diagram step is unpersisted (it runs
during the transition in, exactly as the ordinary stage-4 diagram pass runs unpersisted
inside the stage-3 Resume Handler); the plan, run, and review all sit at
`current-stage=5`, reusing `sub-flow=manual-testing` for the run; resolution is `6` /
`reviewing`, then `7` and `8` unchanged. `progress.schema.yaml` needs no edit.

The fork is a **branch taken before the ordinary rows**, never an edit to them. Every
existing dispatcher row keeps firing on exactly today's conditions.

Where the pipeline needs blueprint material it **borrows** from the completed ordinary
features rather than owning any. The resolved source is each completed feature's latest
`blueprints/history/v[N]/` — stage 8 rotates a finished feature's `current/` into history,
so `current/` is empty by the time this entry runs. That history version also carries the
archived `implementation/` (as-built diagrams, change-summary, inspector-review), which
both derived artifacts need.

### Three shipped-code changes the requirements did not anticipate

Surfaced during design against the shipped code; each is strictly widening.

1. **`progress.sh advance-to` gains `2→5`.** The whitelist is `3-5|5-7|6-7`
   (`scripts/progress.sh:667`). `decisions.md` calls for `advance-to 2 5`, mirroring the
   `advance-to 3 5` idiom so a session break cannot strand the entry mid-transition. One
   added case; the three existing transitions are untouched.
2. **`change-summary` and `manual-test-plan` schemas gain `requirements-ids`.** Both
   currently hard-require a single `requirements-id`, and `change-summary` sets
   `additionalProperties: false`. A feature-test entry has no requirements document — it
   is framed against *all* of the finished features' requirements. See Section 2.
3. **`/mi-apply-impact` gains a refusal guard.** Row A's fork means the command is never
   fired for a feature-test entry on the forward path, but a manual invocation would still
   run `blueprints.sh ensure-current` and create the folder `FTW-002` forbids.

## Section 1 — Identity, routing, and state (`FTW-001`, `FTW-006`)

### 1.1 The identity predicate

`todo.sh feature-test-status` already reads the cycle's `todo-list.md` frontmatter
`feature-test:` field and emits `<status>\t<ft-name>\t<item-id>\t<blocking>\t<assignee>`.
The queue entry name, the todo section heading, and the `workflow-stream/` folder name are
all the same derived string, so field 2 is the whole predicate.

Add **`todo.sh is-feature-test <name>`** — exit 0 when `<name>` matches the cycle's
declared feature-test name, exit 1 otherwise (including when the cycle declares none).
Eight call sites would otherwise each re-parse the same file with their own regex.

This adds a subcommand; it changes no existing `todo.sh` read path. `todo.sh list
IMPLEMENTED` keeps returning exactly the items in that state for its other callers,
notably stage 8's bulk transition.

### 1.2 Entry — a branch inside Row A (`commands/mi-continue.md`)

Row A today fires `/mi-apply-impact` for `queue[0]`. It gains one branch ahead of that:

```
Row A: active=null, queue non-empty, rationale confirmed, ordering invariant holds
  ├─ is-feature-test queue[0] →  progress.sh activate            (byte-identical)
  │                              folder-id.sh ensure             (id.md marker)
  │                              resolve + verify the union range   (§3.1)
  │                              progress.sh set base-commit=<earliest base>
  │                              /mi-generate-implementation-diagrams
  │                              review.sh init
  │                              progress.sh advance-to 2 5 --set sub-flow=none
  └─ otherwise                →  /mi-apply-impact                (unchanged)
```

`progress.sh activate` stays **byte-identical** — it keeps writing `current-stage=2` for
every feature without exception. The grounding report named `activate` the
highest-blast-radius seam in the cycle, since every feature activation calls it.

**No `blueprints.sh ensure-current` call.** That is the single line separating this branch
from an ordinary activation, and it is why the branch cannot simply delegate to
`/mi-apply-impact`.

### 1.3 Recovery — a branch inside the `2 | any` row

Two states leave a feature-test entry parked at `current-stage=2`:

- `/mi-abort-workflow` with no flag (`progress.sh reset` sets `current-stage=2`).
- A session break between activation and `advance-to 2 5`.

The `2 | any` row therefore gains the same branch, ahead of the Approve Handler: when the
active feature is the feature-test entry, run §1.2's diagram-pass-onward sequence instead
of the blueprint sanity-check and the `stage-2-to-3` clear gate.

Accepted consequence, carried from `decisions.md`: **the diagram pass is not resumable.**
An interruption re-runs it from scratch. Safe because it is idempotent and derives
entirely from committed state.

### 1.4 Row ordering

Both branches are **conditions evaluated ahead of an existing row's body**, not new rows
inserted into the table. For any feature that is not the cycle's feature-test entry,
`is-feature-test` exits 1 and control falls through to today's code path unchanged. The
regression check FTW-006 asks for: activate an ordinary feature after the change and
confirm both the persisted stage and the auto-fired command match pre-change behaviour.

### 1.5 Reporting (`FTW-006` acceptance criterion)

No persisted field marks the abbreviated pipeline, so `/mi-resume-workflow` and the status
bar (`scripts/info-bar.sh`) derive the identity from the feature name via
`todo.sh is-feature-test`. That derivation is **confined to those two reporting surfaces**;
the dispatcher needs it only for the two branches above.

Step naming for both surfaces:

| State | Reported as |
| --- | --- |
| `2` + feature-test | `combined test — drawing implementation diagrams` |
| `5` + `sub-flow=none` + `manual-test-state=none` | `combined test — test plan` |
| `5` + `sub-flow=manual-testing` | `combined test — manual run` |
| `5` + `sub-flow=none` + `manual-test-state ∈ {complete, skipped}` | `combined test — inspector review` |
| `6` + `reviewing` | `combined test — findings resolution` |
| `7` | `combined test — finalizing` |

The two `5` / `none` rows are separated by `manual-test-state`, **not** by whether a plan
file exists. An inspector who declines the plan reaches the review step with
`manual-test-state=skipped` and no plan file on disk; keying on file presence would report
them as still owing a test plan.

### 1.6 Stage mapping (the `FTW-001` written contract)

| Step | Persisted state | Handler |
| --- | --- | --- |
| 1. Complete-feature diagrams | *not persisted* — runs in the 2→5 transition | Row A / `2 \| any` branch |
| 2. Whole-feature test plan | `5` / `none` | `/mi-manual-test-plan` (feature-test path) |
| 3. Manual test run | `5` / `manual-testing` | `/mi-manual-test-run` (unchanged) |
| 4. Inspector review | `5` / `none` | Inspector Handler (unchanged) |
| 5. Findings resolution | `6` / `reviewing` → `7` | Review-Resume Handler (unchanged) |

Stages **2 and 3 are skipped**: no blueprint approval gate, no planning chain. Stage 4 was
already collapsed into the stage-3 Resume Handler for ordinary features and has no
persisted existence here either.

## Section 2 — Artifacts (`FTW-002`, `FTW-009`)

### 2.1 Folder layout

```
workflow-stream/<first-feature>-feature-test/
├── id.md                     # folder-identity marker, same as every feature folder
├── implementation/
│   ├── inspector-review.md   # findings file (IR-NNN blocks)
│   ├── change-summary.md     # cached analysis of the union range
│   └── diagrams/             # complete-feature render
└── test/
    ├── manual-test-plan.md
    ├── manual-test-results.md
    ├── manual-test-plan.history/
    └── manual-test-results.history/
```

**`blueprints/` is deliberately absent.** This is the first feature folder shape to omit
it, so the operations that assume it are forbidden against this folder:

| Operation | Status for a feature-test folder |
| --- | --- |
| `blueprints.sh ensure-current` | Never called — §1.2 omits it; `/mi-apply-impact` refuses |
| `blueprints.sh check-current [--require-primer]` | Never called — the stage-2 approve gate is skipped (§1.3); stage 8 skips its preflight (§4.2) |
| `blueprints.sh rotate` | Never called — stage 8 skips rotation (§4.2) |
| `/mi-update-blueprint` | Not reachable — it is a stage-3+ command and stage 3 does not exist here |

Ordinary feature folders keep their layout, and all `blueprints.sh` behaviour against them
is untouched.

### 2.2 Both children are permanent

`implementation/` and `test/` stay exactly where they are when the cycle closes.
`<feature-name>-feature-test/implementation/` **is** the permanent record of the whole-
feature review and diagrams, not a staging area. There is no live-versus-archived
distinction to draw: the folder was never rotated out of a `current/`, so there is nothing
to separate it from, and `test/` is already feature-permanent under the ordinary layout.
Stage 8 performs **no** archive move (§4.2).

Consequence accepted: re-running a feature-test entry overwrites the prior run's
`implementation/` contents rather than versioning them (§4.3).

### 2.3 `requirements-ids` — a list, not a reference

`change-summary.schema.yaml` and `manual-test-plan.schema.yaml` both list
`requirements-id` under `required`. A feature-test entry has no requirements document, and
picking one finished feature's id would point anyone following the reference at a document
that describes a fraction of what was tested.

Both schemas gain an optional **`requirements-ids`** array (UUID items, `minItems: 1`) and
move `requirements-id` out of `required`, with a `oneOf` asserting that **exactly one of
the two is present**:

```yaml
oneOf:
  - required: [requirements-id]
    not: { required: [requirements-ids] }
  - required: [requirements-ids]
    not: { required: [requirements-id] }
```

- **Ordinary features** keep writing `requirements-id: <uuid>`. Their files validate
  byte-identically to today; no generator, consumer, or existing file changes.
- **A feature-test entry** writes `requirements-ids: [<uuid>, …]` — the `id` of each
  finished ordinary feature's archived `history/v[N]/requirements.md`, in queue order.

`change-summary.schema.yaml` keeps `additionalProperties: false`; the new field is declared
under `properties`, so the constraint is satisfied without weakening it. The same schema
gains one further optional field, `commits` — the `{sha, msg}` array stage 8 writes for a
feature-test entry, which has no `requirements.md` to carry it (§4.2). Both additions are
optional, so every existing change-summary on disk stays valid.

Two consumers read the field and need a branch:

- `review.sh sync-refs` re-points `change-summary.requirements-id` after a mid-cycle
  blueprint rotation. Unreachable for a feature-test entry (no rotation), but it must
  tolerate the plural field rather than crash if invoked.
- `/mi-manual-test-plan`'s Step 1.5 freshness gate compares the plan's `requirements-id`
  against the live `requirements.md`. For a feature-test entry it compares the plan's
  `requirements-ids` **list** against the cycle's current finished set — a plan is stale
  when a feature finished after it was written.

### 2.4 Derivation scope (`FTW-009`)

Precise at the boundaries:

- **Only `IMPLEMENTED` items contribute.** Read via `todo.sh list IMPLEMENTED`.
- **Unselected `[ ] TODO` items are out of scope.** They were never built. A
  partially-selected cycle produces a combined plan covering only what shipped.
- **The feature-test item excludes itself.** Its own id comes from
  `todo.sh feature-test-status` field 3.

This constrains how §3.2 consumes existing state; it changes no state and no existing
`todo.sh` read path.

## Section 3 — Complete-feature diagrams (`FTW-003`)

`commands/mi-generate-implementation-diagrams.md` gains a feature-test path, auto-detected
via `todo.sh is-feature-test` on the active feature. An ordinary feature never matches, so
the single-feature path — including its freshness short-circuit and affected-subjects
derivation — is unreachable from the new code.

### 3.1 The union range, and the reachability gate

Each finished ordinary feature's archived
`blueprints/history/v[N]/implementation/change-summary.md` carries `base-commit` and `head`
in frontmatter. That is the durable per-feature range record; `progress.md` does not retain
`base-commit` after `progress.sh finish`.

```
contributors ← []
for each feature F in progress.completed, excluding the feature-test entry:
    if F has no archived change-summary:        # zero-commit cycle — see below
        record F as non-contributing; continue
    (base_F, head_F) ← F's latest history change-summary frontmatter
    require: git merge-base --is-ancestor head_F HEAD
    contributors ← contributors + [F]

require: contributors is non-empty
union_base ← the base_F that is an ancestor of every other base in contributors
union_range ← union_base..HEAD
```

**The reachability gate stops the pipeline.** If any `head_F` is not an ancestor of HEAD,
refuse before drawing anything and name every unreachable feature, with the remedy (merge
or rebase so the combined work is visible from one checkout). Features are on independent
branches by construction — one branch per feature, declared in each feature's own
`config.md` — and today they happen to be stacked, which is an emergent property of
sequential queue execution, not a guarantee. A partial picture that looks complete is
precisely the failure mode this cycle exists to close.

Two boundary cases, both with defined answers rather than inferred ones:

- **No single earliest base.** Every `base_F` is an ancestor of HEAD (it precedes a
  `head_F` that the gate already proved reachable), but that does not make the set totally
  ordered — two features merged in from diverged lines have no common earliest base among
  them. Refuse with the same diagnostic shape as the reachability gate: a contiguous
  `union_base..HEAD` is the contract every downstream consumer
  (`change-summary-fresh`, `diagrams-fresh`, `git diff`) is written against, and
  synthesising one from diverged history would silently include or exclude commits.
- **A finished feature that shipped nothing.** The zero-commit `direct-empty` path
  (`/mi-continue` Resume Step 1) completes a feature while explicitly skipping
  change-summary regeneration, so its history version carries no change-summary. That
  feature contributes no commits by definition — skip it, and list it under the
  change-summary's `## Omitted from analysis` so the absence is visible rather than
  invisible. If *every* finished feature is non-contributing the pipeline refuses: there is
  no assembled implementation to test.

`progress.sh set base-commit=<union_base>` on the entry makes
`commits.sh change-summary-fresh` and `commits.sh diagrams-fresh` work **unchanged** —
both key on `.active.base-commit` and HEAD.

### 3.2 Framing

- **Seeding.** A subject with no commits in the union range seeds from the originating
  ordinary feature's archived stage-2 blueprint diagram (`history/v[N]/diagrams/`) and is
  marked `seeded-only` against that feature. Never from a feature-test blueprint, which
  never exists.
- **Budget.** 1 combined use-case, ≤5 sequences, ≤2 structural — larger than an ordinary
  feature's 1 / 2–3 / ≤1 because the subject is larger.
- **Sequences must cross feature boundaries.** A sequence that re-draws one feature's own
  flow is rejected: that diagram already exists in that feature's history, and redrawing it
  adds pages without adding information. This mirrors the test plan's rule (§4 of
  `FTW-004`).
- **Attribution.** The change-summary body records which feature contributed each changed
  area, so the diagram framing can label the seams.

The existing-vs-new colour convention, the render gate, and the `seeded-only` README
wording caveat all apply unchanged.

## Section 4 — Plan, run, review, and endings

### 4.1 Whole-feature test plan (`FTW-004`) and the run (`FTW-005`)

`commands/mi-manual-test-plan.md` gains a feature-test derivation path. The single-feature
generator's behaviour is unchanged, and so is the schema its output validates against for
an ordinary feature (§2.3).

Input substitutions, all borrowing from the finished features:

| Ordinary input | Feature-test substitute |
| --- | --- |
| `blueprints/current/requirements.md` | each finished feature's `history/v[N]/requirements.md` |
| `blueprints/current/config.md` (services, env vars, topology) | the union of the finished features' `history/v[N]/config.md` |
| `implementation/change-summary.md` | the entry's own, over the union range (§3.1) |

The change-summary freshness gate, RUN_ROOT resolution, and the results auto-rotation guard
all work unchanged once `base-commit` is the union base.

**Derivation.** Scenarios come from the cycle's `IMPLEMENTED` items (§2.4) and the
implementation itself. Where the two disagree, the implementation is what gets tested.
Cross-feature scenarios dominate; a scenario that merely re-runs one feature's existing
case is the exception and carries a justification line, because those already ran during
the ordinary workflows — repeating them wholesale reproduces the exact gap this cycle
exists to close.

**Portability.** Every command the plan emits must be POSIX/BSD-portable and executable on
macOS. GNU-only flags are a defect in the plan even when the underlying code is correct
(the sibling `feature-test-queue-entry` cycle shipped a plan step calling `cat -A`, which
BSD `cat` rejects).

**Merge point for `DTI-005`.** The plan renders an explicit anchor at the end of
`## 3. Test scenarios`:

```markdown
<!-- deferred-merge-point -->
```

`DTI-005` inserts carried-forward scenario groups immediately above it. Stable target, no
schema change, and independent of scenario lettering.

**The run and the review are consumed, not extended.** `/mi-manual-test-run` is unchanged.
Failures land in the entry's `implementation/inspector-review.md` as ordinary findings via
the existing auto-seed path, and flow through the stage-5 Inspector Handler and the stage-6
Review-Resume Handler on their existing entry semantics — empty findings → confirm and
advance; findings present → auto-fire the review session. **No feature-test branch inside
either handler body.** `review.sh list-open`, the `inspector-review.md` block format, and
the empty-findings confirmation behave identically whichever caller reached them.

### 4.2 Stage 8 (`FTW-007`)

`commands/mi-complete-workflow.md` branches on identity across Branch III's four
blueprint-dependent steps:

| Step | Ordinary | Feature-test |
| --- | --- | --- |
| 2 — `IMPLEMENTING` → `IMPLEMENTED` | runs | runs (its own item) |
| 3 — commits list | `commits.sh populate-requirements` → `requirements.md` | union range → the entry's `change-summary.md` |
| 3.5 — lessons distillation | evidence keyed by requirements id | evidence = the entry's `inspector-review.md` + `manual-test-results.md` |
| 4 — `check-current --require-primer` preflight | required to return 0 | **skipped** — nothing to assert without a blueprint |
| 4 — `blueprints.sh rotate` | runs | **skipped** |
| 5 — `implementation/` archive move | runs | **skipped** — permanent in place (§2.2) |
| 6 — `progress.sh finish` | runs | runs |
| 7 — housekeeping | runs | runs |

Lessons distillation is deliberately **kept**: the whole-feature test is the only point in
the cycle that observes the features working *together*, making it the highest-value
lesson source in the run. Its `source_prefix` uses the entry's change-summary id in place
of a requirements id, preserving the re-append fence.

The commits list needs a home, since `requirements.md` does not exist. `change-summary`
gains an optional `commits` array — the same `{sha, msg}` shape `requirements.md` uses —
populated only for a feature-test entry, via a new `commits.sh populate-feature-test
<feature>`. `commits.sh populate-requirements` is left untouched: it is called by every
ordinary feature's stage 8 and branching it would put feature-test logic on the path every
completion takes.

Step 0's branch detection needs no change: `current/requirements.md` is always missing for
this folder and there is no history, so `latest_reason_kind` returns empty, Branch II does
not match, and control reaches Branch III correctly.

Then the **existing** queue-empty closure runs unmodified — `todo_count == 0` →
`quest.sh end`. No second completion path is introduced. Because the entry is pinned last,
its completion is what empties the queue, so the cycle closes in one pass.

### 4.3 Abort, retry, and reopen (`FTW-008`)

**Abort reuses `/mi-abort-workflow` unchanged.** Verified against the shipped command: the
no-flag path runs `progress.sh reset`, which sets `current-stage=2`, clears `base-commit`,
and mints a fresh `activation-id`. For a feature-test entry that reset lands on the
pipeline's genuine first step, because stage 2 plus feature-test identity *is* the diagram
pass (§1.3).

Three consequences:

1. **No new abort mechanism.** Only the post-abort guidance text branches — a feature-test
   entry is told to re-run the diagram pass and plan generation, never to re-approve a
   blueprint or re-plan a feature it never planned.
2. **`test/manual-test-plan.md` is preserved on retry.** It derives from the cycle's
   `IMPLEMENTED` items, the deferred entries, and committed code — none of which an abort
   changes — so regenerating would reproduce nearly the same file at real cost.
3. **`test/manual-test-results.md` does not carry forward.** This is already shipped
   behaviour, not new machinery: `reset` mints a fresh `activation-id`, and
   `/mi-manual-test-plan`'s §4.1 cross-activation guard then rotates the stale results into
   `manual-test-results.history/` on the next invocation. Carrying partial verdicts forward
   is how a scenario silently counts as passed without anyone re-running it — the same
   coverage-loss failure mode `DTI-007` guards against.

**Reopen: there is no reopen.** A whole-feature finding that traces back to an
already-complete ordinary feature is fixed in place through §4.1's ordinary
findings-resolution loop, and **nothing about the completed feature changes** — its todo
items stay `IMPLEMENTED`, its `blueprints/history/v[N]/` stays byte-identical, and it does
not re-enter the queue. No reverse edge is added to the todo state machine and no
un-archive mechanism is built.

Consequence accepted: code belonging to an ordinary feature can change after that feature
was marked complete, with the record of *why* living in the feature-test entry's own
`implementation/inspector-review.md` rather than in the ordinary feature's history. That is
the intended trade — the feature-test entry is the record of the combined phase, and the
alternative (rewriting a completed feature's archived history) is what the cycle's
append-only constraint forbids.

## Section 5 — Canonical project-doc updates

`docs/millwright-inspector-project.md`:

- **§3.4** — the feature-test folder shape (§2.1 above) alongside the ordinary per-feature
  layout, including the forbidden-operations table and the "both children permanent" note.
- **§6** — a new subsection defining the abbreviated pipeline and its stage mapping
  (§1.6). The ordinary 8-stage narrative and its dispatch table stay **intact and
  unedited** alongside it.
- **§7.4** — the two dispatcher branches, described as conditions evaluated ahead of
  existing rows. The statement at line 1092 ("the feature-test entry adds no new dispatcher
  rows") stays true and gains the qualification that Row A and `2 | any` each carry a
  branch.
- **§7.3** — the stage-8 substitution table (§4.2).
- **§8** — `todo.sh is-feature-test` and `commits.sh populate-feature-test` in the script
  reference table; the `advance-to` whitelist entry updated to `3→5, 5→7, 6→7, 2→5`.

## Testing

The plugin's artifacts are command prose plus shell helpers, so verification is a mix of
script-level tests and dispatcher walkthroughs.

- **`todo.sh is-feature-test`** — a cycle declaring a feature-test entry (match / no-match
  / hand-edited frontmatter naming a missing section); a cycle declaring none (always
  exit 1).
- **`progress.sh advance-to 2 5`** — accepted; `2→4`, `2→6`, `4→5` still refused with the
  whitelist diagnostic.
- **Schema round-trip** — an ordinary `change-summary.md` and `manual-test-plan.md`
  validate unchanged; a feature-test variant with `requirements-ids` validates; a file
  carrying **both** fields, and one carrying **neither**, are both rejected.
- **Union-range derivation** — the stacked case proceeds; a cycle where one finished
  feature's head is not an ancestor of HEAD refuses and names it; diverged bases with no
  single earliest refuse; a `direct-empty` feature with no archived change-summary is
  skipped and listed under `## Omitted from analysis`; a cycle where *every* finished
  feature is non-contributing refuses.
- **Ordinary-feature regression (the `FTW-006` explicit check)** — activate an ordinary
  feature after the change; confirm the persisted stage is `2` and the auto-fired command
  is `/mi-apply-impact`, matching pre-change behaviour byte for byte. Confirm an ordinary
  stage-4 diagram pass renders the same set and preserves its skip short-circuit.
- **End-to-end** — a two-feature cycle driven to the feature-test entry: diagrams cover
  both features, the plan is dominated by cross-feature scenarios, a seeded failure flows
  through the ordinary review loop, and completion closes the cycle in one pass.

## Non-goals

- Running the abbreviated pipeline on a single-feature cycle — no entry is emitted.
- Versioning re-runs of a feature-test entry (§2.2 accepts overwrite).
- Reopening a completed ordinary feature (§4.3).
- Any change to `progress.schema.yaml` — the pipeline introduces no new state values.
- The deferred-scenario merge itself (`DTI-005`); this feature owns only the anchor.
