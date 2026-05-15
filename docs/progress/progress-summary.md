# Progress Continuity Summary

## 1. Introduction

This work makes the workflow safer when a session ends in the middle of a command.

The main idea is simple: `progress.md` should only move forward after the important side effect has already happened, or after there is enough durable disk state to safely retry. If the inspector closes the session, the next `/mi-continue` should know exactly where to resume.

The work to be done is:

- Add safer progress writes so multi-field updates happen as one validated write.
- Add a small `advance-to` helper for the few places where the workflow must skip over internal stages.
- Make blueprint rotation resumable with `vN.partial/` folders.
- Make stage launchers and finalizers safe to re-run.
- Persist interactive choices, like queue ordering and drift decisions, before relying on chat memory.
- Add dispatcher rows for states where an auto-fired command was lost because the session ended.
- Add blueprint completeness checks so the workflow does not continue with half-written files.

## 2. Stages

The workflow is easiest to understand as a set of stages. Some stages are visible gates where the inspector reviews or confirms something; other stages are internal handoff points.

```text
Stage 1      Stage 1.5          Stage 2             Stage 3
mi-run   ->  pick queue order -> blueprint ready -> implementation launched
              progress queue      active feature      base-commit captured

Stage 4                  Stage 5             Stage 6
implementation returns -> inspector review -> review session running
diagrams/review setup     findings or ok      only if findings exist

Stage 7              Stage 8
ready to finalize -> complete workflow
auto-fire finalizer   archive, finish, next feature
```

Detailed transition view:

```text
active=null
  |
  | /mi-continue after marked TODOs
  v
Stage 1.5: queue proposal and confirmation
  |
  | /mi-apply-impact
  v
Stage 2: blueprint review
  |
  | /mi-continue auto-fires /mi-plan-implementation
  v
Stage 3: implementation chain or direct implementation
  |
  | /mi-continue after implementation returns
  v
Stage 4 work inside Resume Handler
  |
  | atomic advance-to 3 -> 5
  v
Stage 5: inspector review
  |
  | no findings: atomic advance-to 5 -> 7
  | findings: /mi-review advances to stage 6
  v
Stage 6: review session, if needed
  |
  | atomic advance-to 6 -> 7
  v
Stage 7: finalizer should run
  |
  | /mi-complete-workflow
  v
active=null, feature completed
  |
  | queue has more features: /mi-apply-impact
  | queue empty: quest housekeeping
  v
next feature or cycle end
```

## 3. Progress Update Points

These are the places where `progress.md` changes. The fixes make these writes either atomic, idempotent, or safely recoverable.

```text
Stage 1
  progress.sh init
  Writes the queue and sets active=null.

Stage 1.5
  progress.sh enqueue or reorder
  Updates the queue after the inspector chooses feature order.

Stage 2
  progress.sh activate
  Pops the next feature from the queue and creates active.feature.

Stage 3 launch
  progress.sh set base-commit, sub-flow, history-baseline-version
  progress.sh advance 2
  Captures the implementation starting point.

Stage 4 resume
  progress.sh set implementation-completed, execution-mode, sub-flow
  progress.sh set drift-check-completed, when drift is handled
  progress.sh advance-to 3 5 --set sub-flow=none
  Moves to inspector review only after drift, diagrams, and review setup are done.

Stage 5 no-findings path
  progress.sh advance-to 5 7 --set sub-flow=none --set inspector-review-completed=true
  Skips the review-session stage when there are no findings.

Stage 6 review-resume path
  progress.sh advance-to 6 7 --set sub-flow=none --set inspector-review-completed=true
  Moves to finalization only after optional diagram refresh is decided.

Stage 8 finalizer
  progress.sh finish
  Appends active.feature to completed and sets active=null.
```

Important implementation rule:

```text
progress.sh set and progress.sh advance-to must write to a temp file,
validate that temp file, and then atomically rename it over progress.md.
```

That rule prevents bad or partial progress writes from becoming the saved state.

## 4. Issues From The Report

### Cross-cutting: `progress.sh set` and `advance-to`

This fixes the gap where `progress.md` could be half-updated if the session ended during a multi-field write.

Before, `progress.sh set a=1 b=2 c=3` wrote each field one at a time. If the session ended after `a=1`, the workflow could resume with only part of the intended state. The plan changes this so all fields are written together, validated, and then swapped into place.

`advance-to` fixes the places where the workflow needs to jump over an internal stage, like `3 -> 5` or `6 -> 7`, without doing two separate writes.

### Item 1: Stage-4 Resume Handler

This fixes the gap when the inspector closes the session while the workflow is resuming after implementation.

Stage 4 does several things: confirms commits exist, asks about blueprint drift, maybe updates the blueprint, draws diagrams, and creates the review file. The old plan advanced too early. If the session ended afterward, the dispatcher could think the workflow was somewhere else and not know how to continue.

The fix keeps the stage at 3 until all Stage-4 side effects are done. Then it uses one atomic `advance-to 3 5`.

It also adds `drift-check-completed` and `history-baseline-version` so the workflow can tell whether a blueprint drift update already happened before the session ended.

### Item 2: `/mi-apply-impact` Re-entry

This fixes the gap when the session ends while generating the first blueprint for a feature.

If the active feature is already at stage 2, `/mi-apply-impact` can safely re-enter that same feature instead of failing because `active` is not null.

It also checks whether the blueprint is already complete. If it is complete, the command does not overwrite it. If it is partial, the command stops and asks for an explicit force path.

### Item 3: `/mi-plan-implementation` And Resume Partial Launch

This fixes the gap when the session ends while launching implementation.

Stage 3 captures `base-commit`, writes `primer.md`, asks for planning mode, and launches the implementation work. If the session ends after only some of that happened, the retry must not recapture `base-commit` or lose the original implementation range.

The fix makes `/mi-plan-implementation` detect that it is re-entering the same stage. It preserves `base-commit`, regenerates `primer.md` only if needed, and only re-prompts for planning mode when no implementation commits exist yet.

The zero-commit branch also gives a safe path for direct mode when there really was nothing to change.

### Item 4: Stage-7 Dispatcher Row And Review Refresh Placement

This fixes the gap when the inspector closes the session after review is approved but before finalization starts.

Stage 7 means review is done and `/mi-complete-workflow` should run. If the auto-fire is lost, `/mi-continue` now knows to run the finalizer.

The plan also keeps `sub-flow=reviewing` until after the optional diagram refresh prompt. That prevents the workflow from landing in a state where it has already cleared the review sub-flow but has not asked about refreshing diagrams yet.

### Item 5: Inter-feature And Post-finish Pre-flight Rows

This fixes two gaps when the session ends between features or after the final feature finishes.

Row A handles this case:

```text
Feature A finished.
Queue still has Feature B.
Session ended before /mi-apply-impact started Feature B.
```

The next `/mi-continue` auto-fires `/mi-apply-impact`.

Row B handles this case:

```text
progress.sh finish already set active=null.
quest.sh end did not run yet.
Session ended before cycle housekeeping finished.
```

The next `/mi-continue` auto-fires `/mi-complete-workflow`, which skips straight to the remaining housekeeping.

### Item 6: Stage-8 Finalizer Hardening

This fixes the gap when the session ends while archiving a completed feature.

The old blueprint rotation could leave `history/vN/` and `current/` in confusing partial states. The new plan rotates through a `vN.partial/` folder:

```text
current/ -> vN.partial/ -> vN/
```

If the session ends, the next run can inspect the partial folder and either resume it or stop with a clear diagnostic.

The finalizer also handles cases where rotation already happened, implementation artifacts were already archived, or `progress.sh finish` already ran.

### Item 7: Multi-batch Queue Rationale

This fixes the gap where queue-order decisions could live only in chat.

The queue rationale file now has draft and confirmed states. A proposal is written to disk before the inspector confirms it. If the session ends, the next `/mi-continue` can replay the saved draft instead of recreating a possibly different order.

For later batches in the same quest cycle, the file appends a new batch section instead of overwriting the old one.

### Item 8: Stage-1 Partial Generation Detection

This fixes the gap where `/mi-run` could leave quest files half-filled.

The plan adds checks for required bodies and placeholder text. If files exist but look incomplete, the workflow can offer to complete them in place instead of assuming the cycle is valid.

### Item 9: `blueprints.sh check-current`

This fixes the gap where commands could not tell the difference between complete, empty, and partial blueprints.

The helper returns:

```text
0 = complete
1 = empty or scaffold-only
2 = partial
```

That lets `/mi-apply-impact`, `/mi-update-blueprint`, Stage-4 recovery, and Stage-1 checks make safer decisions.

The check does not require rendered images or sequence diagrams, because some valid features may only need source `.puml` files and a use-case diagram.

### Item 10: `/mi-update-blueprint` Recovery

This fixes the gap when the session ends during blueprint refresh.

`/mi-update-blueprint` can rotate the current blueprint and then regenerate a new one. If the session ends after rotation but before regeneration, `current/` may be empty. If the session ends during regeneration, `current/` may be partial.

The fix makes partial state explicit:

- Matching `vN.partial/` is resumed.
- Partial `current/` is never rotated.
- Empty `current/` only resumes if there is a safe manual or spec-update history version.
- Otherwise the command stops with a diagnostic and does not modify state.

### Item 11: `/mi-update-blueprint` Reason-kind Alignment

This fixes the gap where every manual or drift-triggered blueprint update looked the same.

The command now accepts a reason kind:

```text
manual
spec-update
```

Stage 4 uses `spec-update`. That lets the drift-completion probe detect whether a blueprint update happened during this specific stage-4 cycle.

### Dropped Earlier Approach: Chained Advances

This fixes the gap where `advance 3 && advance 4` could still break if the session ended between the two commands.

The plan drops chained advances and uses `advance-to` for the few required skip transitions.

### Dropped Earlier Approach: `reason.md` As The Only Rotation Signal

This fixes the gap where `history/vN/` could exist but not be fully valid.

The new plan uses `vN.partial/` as the in-progress signal and treats finalized `vN/` without `reason.md` as a stop-and-repair state.

### Dropped Earlier Approach: `implementation-completed` As Proof

This fixes the gap where a flag could be true even though later side effects had not happened.

The plan now uses specific completion markers:

- `drift-check-completed` for the Stage-4 drift decision.
- commit count for implementation launch recovery.
- `reason.md` in finalized history for rotation completion.
- `completed[-1]` for post-finish recovery.
