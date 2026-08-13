# Feature-test queue entry — design

**Feature:** `feature-test-queue-entry`
**Branch:** `feat/mi-run/feature-test-queue-entry`
**Date:** 2026-08-14
**Goals covered:** FTQ-001 … FTQ-008

## Problem

`/mi-run` distills a journal folder into a `todo-list.md` whose sections each become a
separate 8-stage workflow. Every one of those workflows carries its own manual-test
phase, so at the end of a multi-feature cycle every *part* has been tested and the
*assembled whole* has been tested by nobody. Nothing in the pipeline queues that work,
so it happens only when the inspector remembers to do it by hand.

This feature makes the whole-feature test a first-class queued unit: a multi-feature
cycle emits one extra `todo-list.md` section carrying a single item, which is
auto-selected once the ordinary selection is settled and pinned to the end of the queue.

## Scope

This feature owns the **quest side** only — stage-1 emission and stage-1.5 queueing.
The abbreviated pipeline that *runs* the test belongs to the sibling
`feature-test-workflow` feature; the carried-forward scenarios belong to
`deferred-test-items`. Both are out of scope here.

## Constraints carried in from the journal

- **Additive, never a replacement.** Every ordinary feature keeps its full 8-stage
  workflow including its own manual-test phase. The whole-feature test sits after them.
- **Multi-feature cycles only.** A single-feature cycle must behave exactly as today.
- **Terminal.** Nothing in the cycle runs after the feature-test entry.
- **Reuse the existing findings loop verbatim.** No forked review machinery.

## Approach

Three deterministic predicates live in scripts; content-shaped work stays in command
prose. This matches the repo's existing grain — `folder-id.sh feature-lineage-check` is
the precedent: a naming gate implemented as a script subcommand and *called* from prose.

| Concern | Location |
| --- | --- |
| Name derivation + uniqueness retry | `folder-id.sh derive-feature-test-name` (new) |
| Trigger predicate | `todo.sh feature-test-status` (new) |
| Pin validation | `progress.sh check-feature-test-pin` (new) |
| Assignee-setting promotion | `todo.sh set-state --assignee` (new flag) |
| Promoted-item reporting | `todo.sh pend-selected` stdout (additive) |
| Section/item emission, `summary.md` content, hand-off wording, rationale prose | `commands/mi-run.md`, `commands/mi-continue.md` |

Rejected alternatives: a prose-only implementation (the three predicates are evaluated
on every `/mi-continue` of every multi-feature cycle — drift there is silent and lands in
persisted files); and a fully script-backed `feature-test.sh` (stage-1 emission needs
journal-derived content a script cannot produce, and it would add a second writer to
`todo-list.md`).

## Section 1 — Identification and name derivation

### Schema

One optional property added to `schemas/todo-list.schema.yaml` and
`schemas/summary.schema.yaml`:

```yaml
feature-test:
  type: string
  pattern: "^[a-z0-9][a-z0-9-]*$"
  description: >
    The derived feature-test entry's name, when this cycle has one. Absent on
    single-feature cycles and on cycles generated before this field existed.
    When present it MUST also appear in related-features / features.
```

Optional, so absence is meaningful and every existing cycle file stays valid untouched.

**Not** added to `queue-rationale.schema.yaml`. The pin check reads the name from
`todo-list.md` in the same quest directory; a second copy is only a thing to desync.

### Writing the field

`mi-run` calls `frontmatter.sh set "$quest_dir/todo-list.md" feature-test "$ft_name"`
*after* `frontmatter.sh init`, only on the `>= 2` branch. Templates are unchanged, so
FTQ-007's byte-identical guarantee is structural rather than something prose must
remember. (Templating it as `{{FEATURE_TEST}}` would leave either a literal token or an
empty value on single-feature cycles, failing the pattern.)

### Derivation — `folder-id.sh derive-feature-test-name <feature1> <feature2> [...]`

Arguments are the cycle's final ordered ordinary feature names.

1. Candidate = `<first-arg>-feature-test`.
2. Reject if it equals any ordinary name in the argument list.
3. Reject if `feature-lineage-check <candidate>` exits non-zero.
4. On either rejection, append `-2`, `-3`, … and re-run both checks until they pass.
5. Print the final name on stdout. When an ordinal was required, print a rename note on
   stderr so Step 6 can surface it alongside the existing per-feature rename notes.
6. Refuse with a clear error when given fewer than two arguments — this makes an
   FTQ-007 violation loud instead of silent.

### Freezing

The name derives from the **stage-1** ordered feature list and is then frozen in
`todo-list.md`, `summary.md`, and the feature folder name. A stage-1.5 reorder that
changes which feature is first does **not** re-derive it; re-deriving would rename a
folder mid-cycle and strand artifacts.

### Item id

The feature-test item's id is `FT-001`. When the `FT` prefix is already taken by an
ordinary feature in the same cycle, the **prefix** falls back — `FT2-001`, `FT3-001`, …
— preserving the `-001` numbering convention ordinary ids use.

## Section 2 — Stage-1 emission (`commands/mi-run.md`)

Everything below is gated on `count(ordinary features) >= 2`, evaluated **after** the
existing feature-name uniqueness gate settles renames so the derived name is built from
final names. Below the threshold none of these paths execute (FTQ-007).

### Step 3 — `todo-list.md`

```bash
ft_name="$($CLAUDE_PLUGIN_ROOT/scripts/folder-id.sh derive-feature-test-name "${final_features[@]}")"
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init todo-list "$quest_dir/todo-list.md" \
  "FEATURES=payments,audit-log,payments-feature-test" \
  "DESCRIPTION=..."
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh set "$quest_dir/todo-list.md" feature-test "$ft_name"
```

`FEATURES` lists the ordinary names in order, then `ft_name` last. The body emits the
ordinary sections first and `## <ft_name>` last:

```markdown
## payments-feature-test

Covers the assembled result of every feature above. Auto-selected by the millwright once
every ordinary item is either selected or cancelled — leave this item unmarked. To drop
an ordinary item you do not want this cycle, cancel it
(`todo.sh set-state <id> CANCELED`) rather than leaving it unmarked.

- [ ] TODO — FT-001: test the whole feature implementation
```

The item carries **no assignee** — it is inherited at stage 1.5 from whoever completed
the selection. Section headings kebab-normalize, so `## payments-feature-test` already
matches `--feature payments-feature-test` in `todo.sh bulk-transition` / `list` with no
script change.

### Step 4 — `summary.md`

The same `FEATURES` list and the same `feature-test` field. The body gains
`## Feature: <ft_name>` as the last `## Feature:` section (before `## Sources`),
describing **what** the whole-feature test must cover — synthesized from
`## Cross-cutting constraints` plus the union of the ordinary features' acceptance
hints. It does **not** enumerate scenarios: stage 1 has journal content rather than an
implementation, and scenarios written here would be guesses that the feature-test
workflow later contradicts when it derives a real plan from shipped code, leaving two
disagreeing definitions with the stale one in the file the inspector reads first. One
matching `## In plain terms` bullet is added.

### Step 5 — `progress.sh init`

Receives **only** the ordinary features. `ft_name` is deliberately withheld: selection is
unknown at stage 1, and FTQ-005 routes the entry through `enqueue` at stage 1.5.

### Step 6 — hand-off

Two additions to the message: a line naming the feature-test section, stating it is
auto-selected and must not be marked, and naming the cancel escape hatch; plus, when
`derive-feature-test-name` needed an ordinal, a rename note in the same shape as the
existing per-feature rename notes.

### Known affordance trade-off

This places a visible section in `todo-list.md` that the inspector is told to leave
alone, against a file whose whole convention is "mark what you want." Mitigated by the
section lead-in text and by the stage-1.5 revert of a hand-marked entry (Section 3).
Accepted deliberately: the alternative — hiding the entry until stage 1.5 — would make
the whole-feature test invisible at the moment the inspector is deciding cycle scope.

## Section 3 — Stage-1.5 trigger, promotion, and queueing (`commands/mi-continue.md`)

### Trigger predicate — `todo.sh feature-test-status`

Read-only over `todo-list.md`; writes nothing. Prints one TSV row:

```
<status>\t<ft-name>\t<ft-item-id>\t<blocking-count>\t<fallback-assignee>
```

| Status | Meaning |
| --- | --- |
| `none` | No `feature-test:` field — single-feature cycle, or a cycle predating the field. Callers no-op. |
| `blocked` | Feature-test item is `[ ]`, and at least one ordinary `[ ]` line remains. |
| `ready` | Feature-test item is `[ ]`, no ordinary `[ ]` line remains. Promote. |
| `premature` | Feature-test item is `[x]`, but ordinary `[ ]` lines remain — the inspector marked it by hand. |
| `selected` | Feature-test item is `[x]`, no ordinary `[ ]` remains — already promoted. |

**"Ordinary"** means any section whose kebab-normalized heading differs from the
`feature-test` frontmatter value. This is why Section 1's explicit field is worth its
schema property: suffix-matching was ruled out, and positional identification is an
unenforced invariant.

**"Unselected"** means the checkbox is `[ ]`. Every `[x]` state resolves an item,
including `CANCELED` — so cancelling an item the inspector does not want this cycle is
the documented escape hatch that lets the trigger fire. Without it, one permanently
unmarked low-priority item would silently cost the cycle its whole-feature test.

`blocking-count` is the number of ordinary `[ ]` **item lines** (not sections) remaining;
it is `0` for every status other than `blocked` and `premature`.

`fallback-assignee` is the assignee of the last `[x]` ordinary line in document order, or
the empty string when no `[x]` ordinary line exists or the last one carries no tag (only
reachable via hand-editing — `pend-selected` and `todo.sh add` both enforce the tag).
On empty, Step 2A must prompt the inspector for a name rather than promoting untagged:
an untagged `[x]` line would fail the assignee invariant that every later
`pend-selected` run re-checks.

### Assignee inheritance — `todo.sh pend-selected` stdout

`pend-selected` gains **stdout** output it does not currently produce: one
`<item-id>\t<assignee>` row per promoted item, in document order. Its existing stderr
summary is unchanged, so no current caller breaks.

Step 2A takes the **last** row's assignee. When that pass promoted nothing — a re-run
after an interrupted session — it falls back to `feature-test-status`'s
`fallback-assignee` field.

### Promotion — `todo.sh set-state <item-id> <state> [--assignee <name>]`

New optional flag on the existing subcommand, which already performs the state rewrite
and already parses the assignee capture group. When the flag is omitted, behaviour and
output are byte-identical to today.

### Sequence inside Step 2A

Two insertion points, deliberately not adjacent:

1. `pend-selected` runs; its stdout is captured.
2. **New — evaluate and promote.**
   - `ready` → `todo.sh set-state <ft-item-id> PENDING --assignee <inherited>`
   - `premature` → `todo.sh set-state <ft-item-id> TODO` (preserving their assignee tag,
     leaving `- [ ] (emin) TODO — FT-001: …`), then tell the inspector the entry is
     auto-managed and will select itself once the ordinary items are resolved.
   - `blocked` / `selected` / `none` → nothing.
3. Existing items 2–3 run unchanged — group PENDING by feature, detect
   initial-vs-mid-cycle, and on the mid-cycle branch `enqueue` the newly-PENDING ordinary
   features, **excluding `ft_name`**.
4. **New — append the feature-test to the queue.** When step 2 promoted, or when the
   status is `selected` and `ft_name` is not yet in `queue ∪ completed`:
   `progress.sh enqueue "$ft_name"`.
5. Existing items 4–7 (dependency analysis, order proposal, draft-batch append) run
   unchanged, with `ft_name` now queued and pinned last by Section 4.

Splitting promotion (2) from queueing (4) is what guarantees last position in **both**
branches: the initial cycle skips item 3's `enqueue` entirely, while the mid-cycle branch
enqueues ordinary features first. One append path, always last, no ordering
special-case.

### Idempotency

Every mutation is guarded by a state read. `set-state` is a no-op on re-run because the
status flips to `selected`; the `enqueue` is skipped when the name is already in
`queue ∪ completed` (`enqueue` errors rather than no-ops on duplicates, so the caller
checks rather than swallowing the error). A session break anywhere in items 1–4 recovers
on the next `/mi-continue`.

### Quiet on `blocked`

A `blocked` pass prints nothing about the feature-test entry. The escape hatch is
documented in the Step 6 hand-off text and in the section lead-in, so it is discoverable
at the point of confusion rather than repeated at every gate.

## Section 4 — Pin enforcement and rationale

### `progress.sh check-feature-test-pin <ft-name> <order...>`

Pure validation, no writes. Exit 0 when `ft-name` is absent from the order (nothing to
pin) or is its last element; exit 3 otherwise, with a message naming what displaced it.

Deliberately **not** inside `reorder`: that subcommand's permutation-only contract is the
single choke point every multi-feature cycle already depends on, and a guard there would
change behaviour for cycles carrying no feature-test entry at all.

### Call sites

- **Step 2A item 5**, before the order is proposed. `ft_name` is excluded from the
  dependency analysis entirely — including from the `dependency-mapper` sub-agent's
  feature list, which would otherwise spend reads scanning for a feature that has no code
  — then appended last to the proposal. The check runs as an assertion on the result.
- **Step 2B item 2**, immediately after the existing permutation check, against the
  inspector's custom order. On exit 3, surface the message and ask them to retype — the
  same shape as the existing malformed-order path.

### `queue-rationale.md`

The batch that introduces the entry records the pin under `### Notes`:

> `payments-feature-test` is pinned last — it exercises the assembled result of every
> ordinary feature in this cycle, so it cannot run before them. This is a structural
> constraint, not a priority judgement; an order placing it earlier is refused at
> stage 1.5.

### Row A invariant

The dispatcher's Row A (between-features auto-fire) requires
`queue-rationale.features − progress.completed` to equal `progress.queue` in order.
Step 2B already writes `features:` as the confirmed order, and that order now ends with
`ft_name`, so the invariant continues to hold with no extra work.

This is the invariant that breaks first if anyone later moves the `enqueue` from Step 2A
into Step 2B: the name would be missing from the queue when `queue-rationale.features` is
written, Row A would mismatch, and the workflow would stall between features.

## Section 5 — Canonical project-doc updates

`docs/millwright-inspector-project.md` is the canonical workflow spec, and it enumerates
every surface this feature changes. Leaving it stale would make the doc disagree with
shipped behaviour at six separate points, so these edits are part of the feature, not
follow-up work:

| Location | Edit |
| --- | --- |
| §3.3 (the quest folder) | Document the feature-test section in `todo-list.md`'s structure: when it appears, that it holds exactly one item, and that it is auto-selected rather than inspector-marked. |
| §3.5 / assignee invariant (~line 382) | Note the one line whose assignee is inherited rather than inspector-supplied. |
| Stage-1.5 sub-state A (~lines 754–760) | Add the promote-and-enqueue steps to sub-state A's described behaviour, and the pin check to sub-state B's. |
| Dispatcher table (~line 1069) | No new rows — record that the feature-test entry rides the existing Step 2A/2B rows, and that Row A's ordering invariant is preserved by `queue-rationale.features` ending with the pinned name. |
| `todo.sh` subcommand table (~line 1688) | Add `feature-test-status`; note `set-state`'s new `--assignee` flag and `pend-selected`'s new stdout. |
| `folder-id.sh` subcommand table (~line 1689) | Add `derive-feature-test-name`. |
| `progress.sh` subcommand reference | Add `check-feature-test-pin`, stating explicitly that it is a separate validator and that `reorder`'s contract is unchanged. |
| §8.3 (schemas) | Record the optional `feature-test` property on `todo-list` and `summary`. |

## Testing

`tests/feature-test-entry/run.sh`, following the existing `ok()` / `ng()`-with-fixtures
convention used by `tests/blueprint-lessons/` and `tests/bundle/`.

| Target | Cases |
| --- | --- |
| schema | valid `feature-test` field passes; bad pattern fails; field absent passes (back-compat) |
| `derive-feature-test-name` | base derivation; ordinal retry on collision with an ordinary name; ordinal retry on lineage collision; refusal below two arguments |
| `feature-test-status` | all five statuses; correct `blocking-count`; correct fallback assignee |
| `check-feature-test-pin` | last → 0; absent → 0; not-last → 3 |
| `set-state --assignee` | sets the tag; omitted flag leaves output byte-identical to today |
| `pend-selected` | new stdout TSV correct; stderr summary unchanged |

**Coverage limit.** This covers the script layer — the three predicates and two contract
changes, which is where determinism matters and where the chosen approach put the logic.
The `mi-run` / `mi-continue` changes are command prose and are not unit-testable; they
are verified by the workflow's own stage-5 manual test, which is what the sibling
`feature-test-workflow` feature exists to run.

## Non-goals

- Enforcing the pin inside `progress.sh reorder`.
- Adding `feature-test` to `queue-rationale.schema.yaml`.
- Generating whole-feature test scenarios at stage 1.
- Any change to the abbreviated feature-test pipeline or to deferred test items.
