# Deferred test items — design

**Feature:** `deferred-test-items`
**Branch:** `feat/mi-run/feature-test-workflow`
**Date:** 2026-08-15
**Goals covered:** DTI-001 … DTI-008

## Problem

Testing each feature in isolation misses more than the seams between features. It also
produces scenarios that are simply *not runnable yet*, because the behaviour under test
depends on a feature later in the queue. Today those scenarios have nowhere to go: the
inspector either fails them (wrong — nothing is broken), skips them (wrong — the coverage
is silently dropped), or remembers them informally (worst — they are lost).

This feature gives them a destination with an owner and a due date: a `deferred-tests`
file that ordinary manual-test runs write into, and the whole-feature test plan reads
from.

## Scope

Both ends of the pipe plus the artifact between them:

- **Producer** — a `defer` disposition in an ordinary feature's manual-test run.
- **Artifact** — `deferred-tests.md`, carrying enough per-entry context to be run later by
  someone who is not re-reading the source workflow.
- **Consumer** — the merge into the whole-feature manual test plan at generation time.

Plus the integrity machinery that stops `defer` from degrading into `skip`.

The `<feature-name>-feature-test` name, its queue entry, and its selection state are
inputs, owned by `feature-test-queue-entry` (complete). The whole-feature plan's render
path and its `<!-- deferred-merge-point -->` anchor are owned by `feature-test-workflow`
(complete) — this feature owns the merge, not the anchor.

## Constraints carried in from the journal

- **Additive, never a replacement.** Every ordinary feature keeps its full 8-stage
  workflow including its own manual-test phase.
- **Multi-feature cycles only.** A single-feature cycle behaves exactly as today.
- **Terminal.** Nothing runs after a successful feature-test entry.
- **Artifact layout is prescribed.** `<feature-name>-feature-test/` with exactly two
  children, `implementation/` and `test/`.
- **Reuse the existing findings loop verbatim.**

And one invariant this feature adds to every seam it touches:

- **Zero-deferral cycles behave byte-identically to today.** Every prompt string, every
  render, every gate. This is the single most-tested property in the plan.

## Approach

Three decisions shape everything below. Each was open in the requirements and settled
during brainstorming.

1. **The feature-test folder is created early, at stage 1.5** (DTI-002), when
   `/mi-continue` Pre-flight Step 2A enqueues the feature-test entry — not at `/mi-run`
   name derivation, and not lazily on first deferral. This keeps the journal's stated
   folder layout literally true from cycle start.

2. **`defer` is offered only when a future destination exists** — one predicate that
   subsumes both DTI-008's single-feature rule and the terminal entry's own run.

3. **`skip` resolves a deferred item.** The completion gate catches *absent* verdicts, not
   abandoned ones. The existing autonomous skip audit (`mi-manual-test-run.md` § 4.1)
   already polices skip quality, and adding a second waiver mechanism beside it would be
   redundant machinery for a case that path already covers.

### Two shipped defects this feature must repair

DTI-002 requires the decision to name every currently-shipped behavior it changes. Two
of those behaviors are broken today, and early creation makes both load-bearing:

**`folder-id.sh ensure` is called with the wrong argument type.**
`commands/mi-continue.md`'s Feature-test entry sequence step 3 calls:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/folder-id.sh ensure "$ft_feature"
```

`ensure` takes a **folder path** — `_fid_ensure` opens with
`[[ -d "$folder" ]] || mi_die "folder not found: $folder"`, and the folder is
`$(mi_stream_dir)/<feature>`. Passing a bare feature name dies. The call must become
`folder-id.sh ensure "$data_root/workflow-stream/$ft_feature"`. We cannot claim Row A stays
idempotent under early creation while one of its two setup calls aborts.

**The feature-test folder is never linked into the cycle's `reference.md`.**
`folder-id.sh link-feature` has exactly one caller: `blueprints.sh ensure-current` — which
§3.4.1 forbids against a feature-test folder. So the folder is never linked, and on a
*later* cycle `feature-lineage-check` reaches its final branch:

```
unknown: workflow-stream/<name> exists (id=…) but no quest cycle references it
exit 4
```

`derive-feature-test-name` treats any non-zero as "candidate taken" and bumps the ordinal —
so the entry silently renames itself to `payments-feature-test-2`. Today this needs the
folder to exist, which is rare. Under early creation it becomes certain. The fix is to call
`link-feature` at creation time, which closes the hazard rather than opening it.

Both are small, both sit directly on this feature's path, and both are pinned by
regression tests below.

---

## Section 1 — The artifact (`DTI-001`)

### 1.1 Location and resolver

`workflow-stream/<ft-name>/test/deferred-tests.md` — nested under the feature-test
folder's existing `test/` child. **Never a third top-level child**: §3.4.1's two-child
shape must keep holding.

`scripts/blueprints.sh` gains one subcommand beside its two existing helpers, built on the
same `mi_test_dir`:

```bash
deferred-tests-path)
  feature="${1:?feature required}"
  echo "$(mi_test_dir "$feature")/deferred-tests.md"
  ;;
```

Add it to the `usage:` string in the same edit.

### 1.2 Registration

`frontmatter.sh init <kind> <dest>` resolves kind → artifact purely by filename
convention: `templates/<kind>.md.tmpl` for the body, `schemas/<kind>.schema.yaml` for
validation when one exists by the same name. Adding the pair is therefore drop-in, with no
registry edit anywhere:

- `schemas/deferred-tests.schema.yaml`
- `templates/deferred-tests.md.tmpl`

**Acceptance criterion (DTI-001):** `frontmatter.sh init deferred-tests <path>` renders the
file and `frontmatter.sh validate <path> deferred-tests` accepts it, through the same
render/validate path every other workflow artifact uses. No bespoke parsing.

### 1.3 Frontmatter

```yaml
---
id: <uuidv4>
feature-test: payments-feature-test
quest-slug: 2026-08-13-whole-feature-test-workflow
created-at: "2026-08-15T09:04:00Z"
---
```

`additionalProperties: false`, all four required. `feature-test` uses the same
`^[a-z0-9][a-z0-9-]*$` pattern every other feature field uses; `id` uses the shared UUIDv4
pattern.

**No counters.** Resolution state is derived from the feature-test's
`manual-test-results.md` at gate time (§ 4.3). A `resolved:` counter here would be a
denormalization with no writer at the moment resolution actually changes, and would go
stale on the first hand-edit.

### 1.4 Body shape

```markdown
## Deferred scenarios

### payments/B.2 — refund shows in the audit trail

- **Originating feature:** payments
- **Originating scenario:** B.2
- **Action:** |
    1. Sign in as an admin and open order #1001
    2. Issue a full refund
- **Expected:** |
    - The refund appears in the audit trail within 5s
    - The entry names the acting admin
- **Reason:** the audit-log feature ships later in this cycle
- **Deferred at:** "2026-08-15T10:22:11Z"
- **Merged as:**
```

Block boundary is `^### ` to the next `^### ` / `^## ` / EOF — the same shape
`manual-test-results.md` uses, so the parsing idiom is already familiar in this codebase.
Multi-line `Action:` / `Expected:` use the four-space-indented block-scalar convention the
results file already uses.

**Identity is the heading.** `<originating-feature>/<originating-scenario>` is the
composite key: what DTI-003's upsert matches on and what DTI-005's merge matches on. This
is the requirement's stated identity, expressed literally rather than mirrored into a
separate numbering scheme — there is no `DEF-NNN` to renumber when an entry is removed, and
no way for the heading and the body fields to disagree.

**Self-containment is the point.** `Action`, `Expected`, and `Reason` are copied out of the
plan at defer time, not referenced. An entry must be runnable weeks later by someone who
never opens the originating workflow. This is also what makes § 2.6's stale-key edge case
harmless.

**`Merged as:`** is blank at defer time and written back by DTI-005 with the feature-test
scenario id the entry became (`A.7`). It is the machine-checkable link DTI-007's gate
needs. It does **not** conflict with DTI-006: DTI-006 forbids new ids and new frontmatter
fields on the *plan* and the *results*; this field lives on `deferred-tests.md`, an
artifact this feature owns outright.

### 1.5 The helper

New `scripts/deferred-tests.sh`, following the one-script-per-artifact-family pattern
already set by `review.sh`, `todo.sh`, `lessons.sh`, `pr-review.sh`, and `folder-id.sh`.

| Subcommand | Contract |
| --- | --- |
| `upsert <ft> --feature <f> --scenario <s> --title <t> --reason <r> --action <a> --expected <e> [--deferred-at <iso8601>]` | All of `--feature`/`--scenario`/`--title`/`--reason`/`--action`/`--expected` are named flags, not read from stdin — stdin into a command-recipe fence is fragile, and every call site already agrees on flags. All six are mandatory; `--deferred-at` defaults to now when omitted. Idempotent by composite key — replaces the existing block, never appends a second. Mirrors `review.sh upsert-manual-test-failure`'s shape. |
| `list <ft>` | TSV rows `<feature>\t<scenario>\t<merged-as>\t<title>`, one per entry. |
| `set-merged-as <ft> <feature> <scenario> <id>` | Writes the `Merged as:` back-reference. |
| `remove <ft> <feature> <scenario>` | Drops one entry. The escape hatch for § 3.4's aborted-feature case. |
| `count <ft>` | Entry count; `0` when the file is absent. |

`count` returning `0` on an absent file — rather than failing — is what lets every
consumer gate on "are there any deferrals" without first testing for the file.

The helper lives in a script rather than inline in the command file so that
`mi-manual-test-run.md` keeps its "single owner of manual-test auto-seeding" contract
shape: commands orchestrate, scripts mutate artifacts.

---

## Section 2 — The producer (`DTI-003`, `DTI-004`, `DTI-008`)

### 2.1 The offer predicate

Evaluated once at run start, reused at every site that renders the vocabulary:

```
offer_defer  ⇐  the cycle has a feature-test entry
                     (todo.sh feature-test-status reports a name)
            AND  the active feature is not that entry
                     (todo.sh is-feature-test "$active_feature" exits 1)
```

| Situation | Vocabulary |
| --- | --- |
| Ordinary feature, multi-feature cycle | `pass` / `fail` / `skip` / `defer` / `pause` |
| Ordinary feature, single-feature cycle (DTI-008) | `pass` / `fail` / `skip` / `pause` — unchanged |
| The feature-test entry's own run | `pass` / `fail` / `skip` / `pause` — unchanged |

Single-feature cycles fail the first clause; the terminal entry fails the second. One
condition to implement, test, and document instead of two special cases — and it settles a
case the journal never covered, since the terminal entry has no later phase to defer into.

DTI-008's acceptance criterion follows directly: in a single-feature cycle the defer path
is **unreachable**, not reachable-and-failing, and the run is indistinguishable from
today's.

### 2.2 The disposition

`defer <reason>` sits alongside `pass` / `fail` / `skip` as a further disposition, and
alongside `pause` as a further reply. **The reason is mandatory** — an entry without one is
not runnable later, which is DTI-001's whole point. A bare `defer` re-prompts rather than
recording an empty reason.

Seven sites carry the vocabulary. Each gets an explicit disposition so a generated plan can
never advertise a vocabulary the runner will not accept:

| Site | Disposition |
| --- | --- |
| `mi-manual-test-run.md` 3.2a / 3.3a — interactive | Offer when `offer_defer` |
| `mi-manual-test-run.md` 3.2c / 3.3c — guided | Offer when `offer_defer` |
| `mi-manual-test-run.md` 3.3b — autonomous self-judgment | **Never offered** — stated explicitly, not by silence |
| `mi-manual-test-run.md` overview section | Conditional mention |
| `mi-manual-test-run.md` guided env-up announcement | Conditional mention |
| `templates/manual-test-plan.md.tmpl` | Static mention with an explicit cycle-shape caveat |
| `commands/mi-manual-test-plan.md` generated-plan prose | Conditional mention |

**`templates/manual-test-plan.md.tmpl`'s mention is static, not conditionally rendered.**
The template names `defer <reason>` in every generated plan, with a caveat that it applies to
multi-feature cycles only and never during the feature-test entry's own run — a
generation-time snapshot of `offer_defer` would go stale the moment the cycle's shape changed
after the plan was rendered, so static-with-caveat is the correct mechanism, not a shortcut.
The live gate stays in `/mi-manual-test-run`, which calls
`deferred-tests.sh offer-defer "$active_feature"` at each vocabulary-rendering site and only
offers `defer` when it exits 0 — so a generated plan never advertises a vocabulary the runner
will not accept, even though the plan's own mention of `defer` never varies.

**Autonomous mode does not self-defer.** The journal frames deferral as inspector-driven —
"I can tell the agent to defer a manual test item". An autonomous run that genuinely cannot
exercise a scenario already has the attempt-backed `skip` path (3.3b), whose bar is
stricter than a defer reason would be. Stating this explicitly matters because the
autonomous branch *matches on the same verdict strings* the prompts render; leaving it
implicit would make `defer` reachable there by accident.

### 2.3 The commit path (3.4)

`defer` joins the shared verdict commit unit unchanged in structure:

- Upsert one canonical verdict block for the scenario id, `Verdict: defer`, with the
  inspector's reason as `Observation:`. Bullets keep their existing five-key contract and
  order.
- **A `defer` reply never falls into the `fail` or `skip` parsing branch.** This is the
  single most important behavioural guard in the producer.
- In the *same* commit unit, call `deferred-tests.sh upsert` with the feature, scenario id,
  title, `Action`, `Expected`, and reason read out of the plan. One write per disposition,
  not two — a crash between a results write and a deferred-tests write would otherwise
  leave the two files disagreeing.
- Re-deferring the same scenario updates the one entry. The composite key makes this
  idempotent, so the existing verdict-already-committed crash recovery (3.1) stays correct.
- Echo shape follows the existing one-line convention: `<ID> ⏸ deferred: <reason>`.

`Seeded:` stays `false` and is never flipped for a defer.

### 2.4 Auto-seed is untouched (`4.2`, `review.sh upsert-manual-test-failure`)

**A deferred scenario never spawns an `IR-NNN`.** It does not enter the failed set, so the
auto-seed prompt's `<failed>` count excludes it and the per-scenario family-inspection loop
never sees it. `review.sh upsert-manual-test-failure` needs no change at all.

### 2.5 The counter (`DTI-004`)

`schemas/manual-test-results.schema.yaml` enumerates exactly `total` / `passed` / `failed` /
`skipped` under `additionalProperties: false`, so a deferred verdict has nowhere to be
tallied today. Add:

```yaml
  deferred:
    type: integer
    minimum: 0
    default: 0
    description: >
      Count of scenarios the inspector deferred to the cycle's whole-feature
      test. Optional with a default so results files rendered before this key
      existed stay valid — a reader that sees no key reads 0. Deferred
      scenarios remain inside `total`.
```

**Optional, not required.** Adding it to `required:` would invalidate every
already-rendered results file on disk. A reader seeing no key reads 0.

`templates/manual-test-results.md.tmpl` gains `deferred: 0` beside the other three, so
freshly-rendered files carry it explicitly.

Recompute sites in `mi-manual-test-run.md` — all three tally it:

1. Step 4.1 — mark results complete.
2. Step 3.4 — the per-scenario commit unit.
3. Branch C — bulk-skip convergence.

Roll-up strings in `mi-manual-test-run.md` — all three gain the fourth term:

1. Step 4.1 autonomous roll-up.
2. Step 4.2 auto-seed prompt.
3. Branch B messages.

(Bare `§ N` in this document always refers to a section of this document; sections of
`mi-manual-test-run.md` are written as `Step N` or named with the file.)

**Invariant:** `passed + failed + skipped + deferred == total` at every recompute site.
Deferred scenarios stay **inside** `total` — they are plan scenarios that were reached and
dispositioned, unlike `INS-<n>` inspector-added checks, which stay outside all counters.

### 2.6 Edge case — a stale key after `--force` regeneration

If an ordinary feature's plan is regenerated with `/mi-manual-test-plan --force` after a
deferral, scenario lettering can shift and an entry's `<feature>/<scenario>` key no longer
matches a live scenario in that plan.

This is harmless by construction. § 1.4 requires each entry to carry its own `Action` and
`Expected`, so an orphaned entry still merges into the whole-feature plan as a fully
runnable scenario. What it loses is the ability to trace back to a live scenario id in its
originating plan — a display detail, not lost coverage. No reconciliation pass is needed,
and none is specified.

---

## Section 3 — Creation timing (`DTI-002`)

### 3.1 The decision

The `<feature-name>-feature-test/` folder and its `deferred-tests.md` are created at
**stage 1.5**, at the point in `/mi-continue` Pre-flight Step 2A **item 3.5** where the
feature-test entry is confirmed and enqueued — immediately after the successful
`progress.sh enqueue "$ft_name"`.

Written into `docs/millwright-inspector-project.md` § 3.4.1 as the folder's stated
lifecycle.

### 3.2 What creation does

```bash
ft_dir="$data_root/workflow-stream/$ft_name"
mkdir -p "$ft_dir/implementation" "$ft_dir/test"
$CLAUDE_PLUGIN_ROOT/scripts/folder-id.sh ensure "$ft_dir"
$CLAUDE_PLUGIN_ROOT/scripts/folder-id.sh link-feature "$ft_name"
dt="$($CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh deferred-tests-path "$ft_name")"
[[ -f "$dt" ]] || $CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init deferred-tests "$dt" \
  "FEATURE_TEST=$ft_name" "QUEST_SLUG=$slug"
```

Every step is idempotent: `mkdir -p` no-ops, `ensure` returns the existing id, and the
`deferred-tests.md` render is `[[ -f ]]`-guarded so a re-entrant Step 2A can never truncate
parked entries.

**No `blueprints/`.** That omission is the whole point of the abbreviated shape and it is
preserved exactly.

**`link-feature` is load-bearing, not housekeeping** — see § 3.3 row 2.

### 3.3 The five named consumers

| Consumer | Behavior under early creation |
| --- | --- |
| § 3.4.1's four forbidden operations — `ensure-current`, `check-current`, `rotate`, `/mi-update-blueprint` | **Unchanged: still never called.** The folder gains `implementation/` and `test/` and still never gains `blueprints/`, so none of the four becomes reachable. The § 3.4.1 table is updated to state the new creation timing and to say explicitly that it does not change any row. |
| `folder-id.sh derive-feature-test-name` / `feature-lineage-check` | **Resolves identically across cycles — because creation mints `id.md` *and* links it.** Without `link-feature`, `feature-lineage-check` returns exit 4 on the next cycle and the entry silently renames to `<name>-2`. This is the defect described in the Approach section; early creation is what makes fixing it mandatory. |
| Stage-8 Branch III substitution (§ 7.3, four blueprint-dependent steps) | **No fifth step, and no assumption of a freshly-created folder.** The entry does no blueprint rotation and no archive move; nothing it reads depends on when the folder appeared. Stated explicitly rather than left implicit. |
| `/mi-abort-workflow` | **Parked entries survive both abort shapes, with no new code.** Aborting an *ordinary* feature targets `workflow-stream/$active_feature/implementation` and never touches the feature-test folder. Aborting the *feature-test entry* deletes only its `implementation/` and already preserves `test/` as feature-permanent. Documented in the command's retry-semantics section. |
| Row A setup — `folder-id.sh ensure` → `review.sh init` | **Idempotent, once the `ensure` argument is corrected** (Approach, defect 1). `ensure` no-ops on an existing `id.md`; `review.sh init` is `[[ -f ]]`-guarded. Neither touches `test/`, so `deferred-tests.md` is never overwritten or truncated. This is the consumer most able to clobber parked entries, which is why its behavior is stated rather than assumed. |

### 3.4 Aborted originating features

An ordinary feature that deferred a scenario and was then aborted leaves its entries in
`deferred-tests.md`. They are **preserved, not auto-pruned**: on retry, re-deferring the
same scenario upserts the same key and produces no duplicate, and an entry that is not
re-deferred still merges as a runnable scenario. Over-inclusive rather than lossy, which is
the correct direction for a feature whose purpose is to stop coverage disappearing.

`deferred-tests.sh remove` is the deliberate escape hatch when the inspector knows an entry
is obsolete.

---

## Section 4 — The consumer and the gates (`DTI-005`, `DTI-006`, `DTI-007`)

### 4.1 The merge (`DTI-005`)

`commands/mi-manual-test-plan.md` Step 5's feature-test render path (`ft_mode=1`) gains
`deferred-tests.md` as a derivation input alongside `todo.sh list IMPLEMENTED` and the
union range.

Carried-forward entries render as their own lettered group(s), continuing the plan's
existing lettering, inserted **immediately above** the anchor:

```markdown
### C.1 — [deferred from payments] refund shows in the audit trail

…

<!-- deferred-merge-point -->
```

**The anchor keeps its exact text and its exact position** — the last line of
`## 3. Test scenarios`, immediately before `## 4. Coverage notes` — on *every* feature-test
render, including renders with zero deferred entries. It is matched as a literal string,
and a later deferral plus regeneration must still find it.

As each entry renders, the merge calls
`deferred-tests.sh set-merged-as <ft> <feature> <scenario> <new-id>`.

**Empty `deferred-tests.md` → the render is unchanged from today.** Pinned by test.

### 4.2 Attribution (`DTI-006`)

**Plan side.** The scenario title carries the marker:
`[deferred from payments] refund shows in the audit trail`. Nothing else changes — no new
id prefix, no reserved letter range, no new frontmatter field. The id grammar stays
byte-identical, so neither the runner's one-to-one id↔verdict-block keying nor
`review.sh`'s `seed-id` construction (`manual-test:<seed-family-id>:<scenario-id>`) sees
anything new.

**Results side.** `mi-manual-test-run.md` Step 3.4's block gains exactly one line, directly
under the heading and above the existing bullets, which keep their contract verbatim:

```markdown
### C.1 — pass

[deferred from payments]

- **Verdict:** pass
- **Observation:** …
- **Recorded at:** …
- **Seeded:** false
- **Cited as IR-NNN:**
```

One consequence to pin deliberately: the verdict-block parser must tolerate a non-bullet
line between the heading and the first bullet. It reads by bullet key within the block
window, so it already does — but that tolerance is currently incidental, and a test makes
it a contract.

### 4.3 Gate 1 — the feature-test entry, blocking (`DTI-007`)

An additive `AND`-condition on the **two shipped entries into finalization** in
`commands/mi-continue.md`:

- the Inspector Handler's no-open-findings path — `advance-to 5 7`
- the Review-Resume Handler's path — `advance-to 6 7`

**Not inside generic `progress.sh advance-to`.** Putting it there would alter behaviour for
cycles that carry no feature-test entry at all; placing it on both handler paths is what
guarantees neither branch bypasses it while leaving `advance-to`'s contract untouched.

The existing open-findings block is **not replaced** — this sits beside it as a second,
independent condition.

**Resolution rule.** For each entry in `deferred-tests.md`:

| State | Verdict |
| --- | --- |
| `Merged as:` id has a verdict block in the entry's `manual-test-results.md` with `pass`, `fail`, or `skip` | **resolved** |
| `Merged as:` id has no verdict block | **unresolved** — gate holds |
| `Merged as:` is blank | **unresolved** — gate holds |

`skip` resolves. The gate catches *absent* verdicts, not abandoned ones: a skip is already
recorded with a mandatory reason, and the autonomous run's pre-finalize skip audit
(`mi-manual-test-run.md` Step 4.1) already refuses convenience skips. A blank `Merged as:`
is unreachable in practice —
every deferral predates plan generation, since all ordinary features finish before the
entry activates — but it fails closed, which is the right direction.

On a block, name the offending entries:

```
Cannot finalize payments-feature-test — 2 deferred scenarios have no verdict:
  payments/B.2 → C.1  (refund shows in the audit trail)
  checkout/A.4 → C.3  (cart survives a session expiry)
Run /mi-manual-test-run to complete them, or remove an obsolete entry with
deferred-tests.sh remove.
```

**Zero deferred entries → both paths behave byte-identically to today.**

### 4.4 Gate 2 — the ordinary feature, report-only (`DTI-007`)

A different path, and deliberately weaker. It reads the `deferred` counter from § 2.5 and
fires at two places:

- `mi-manual-test-run.md` § 4.8's hand-off message
- the ordinary-feature stage-8 preflight

It changes **wording only**: "8/10 passed, 1 deferred to the whole-feature test" replaces
any fully-tested claim. **It never blocks** the ordinary feature's stage-8 completion or its
promotion to `IMPLEMENTED` — those scenarios are resolved later, at the feature-test entry.
Blocking here would deadlock the cycle, since the entry that resolves them runs last.

### 4.5 Deliberately out of scope

A direct or recovery invocation of `/mi-complete-workflow` that reaches finalization
without passing through either handler is **not** gated. It is a manual repair path the
inspector drives knowingly, and this cycle does not add a third enforcement point there.

---

## Section 5 — Canonical project-doc updates

`docs/millwright-inspector-project.md`:

- **§ 3.4.1** — add `deferred-tests.md` to the folder tree under `test/`; state the stage-1.5
  creation timing; state that the timing change makes none of the four forbidden operations
  reachable.
- **§ 6.4** — note `deferred-tests.md` as a derivation input to step 2 (whole-feature test
  plan).
- **§ 7.3** — state that Branch III gains no fifth step under early creation.
- **§ 7.4 / Row A** — the corrected `folder-id.sh ensure` argument and the added
  `link-feature`.
- **Script table** — `blueprints.sh` gains `deferred-tests-path`; add the
  `scripts/deferred-tests.sh` row.

---

## Testing

New `tests/deferred-test-items/run.sh`, matching the shape of `tests/feature-test-entry/`
and `tests/feature-test-workflow/`.

**Artifact (DTI-001)**
- `frontmatter.sh init deferred-tests` renders; `validate` accepts.
- `upsert` twice on the same composite key produces one block, updated.
- `upsert` on two different keys produces two blocks.
- `count` returns 0 for an absent file.
- `remove` drops exactly one entry.

**Creation (DTI-002)**
- Stage-1.5 creation produces `implementation/`, `test/`, `id.md`, and **no** `blueprints/`.
- Re-running creation does not truncate a populated `deferred-tests.md`.
- **Regression:** `derive-feature-test-name` returns the same name on a second cycle after
  early creation — the pin for the `link-feature` fix.
- **Regression:** `folder-id.sh ensure` is invoked with a folder path, not a feature name.
- Aborting an ordinary feature leaves `deferred-tests.md` intact.

**Producer (DTI-003, DTI-004, DTI-008)**
- `offer_defer` is false in a single-feature cycle and false for the feature-test entry's
  own run; the rendered prompt strings are byte-identical to today in both.
- All three per-mode prompt sites offer `defer` when `offer_defer`; the autonomous site
  never does.
- A `defer` reply does not fall into the `fail` or `skip` branch.
- A deferred scenario seeds no `IR-NNN`.
- Counter identity `passed + failed + skipped + deferred == total` at all three recompute
  sites.
- A results file with no `deferred` key still validates.

**Consumer and gates (DTI-005, DTI-006, DTI-007)**
- A feature-test plan rendered with empty `deferred-tests.md` is byte-identical to today's.
- The anchor's exact text and position survive a zero-deferral render.
- A merged entry carries `[deferred from <feature>]` in its title and its `Merged as:` is
  written back.
- The scenario-id grammar is unchanged by a merge.
- The verdict-block parser tolerates the attribution line between heading and bullets.
- Gate 1 blocks on an absent verdict; `pass`, `fail`, and `skip` each clear it.
- Gate 1 is a no-op for a cycle with zero deferred entries.
- Gate 2 changes wording only and never blocks stage 8.

---

## Non-goals

- **No reconciliation pass** for entries orphaned by a `--force` plan regeneration (§ 2.6).
- **No waiver mechanism** — `skip` resolves, so none is needed (Approach, decision 3).
- **No deferral from the feature-test entry itself**, and none in single-feature cycles.
- **No gate on direct `/mi-complete-workflow`** (§ 4.5).
- **No versioning of `deferred-tests.md`.** It lives in `test/`, which is feature-permanent
  and already survives abort; it is not rotated into history.
- **No change to `review.sh`.** A deferral is not a finding.
