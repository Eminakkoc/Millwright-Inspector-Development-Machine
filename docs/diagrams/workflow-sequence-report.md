---
review-date: 2026-04-26
scope:
  - docs/diagrams/workflow-sequence.puml
  - docs/diagrams/workflow-sequence.svg
  - commands/
  - scripts/
  - hooks/
  - templates/
---

# Workflow Sequence Review Report

## Summary

No blocker or major sequence/code inconsistency was found in the current workflow. The PlantUML source now reflects the important high-level happy-path behavior: staged `/mi-continue` gates, isolated stage-3 and stage-6 sessions, layered context files, `change-summary.md` cache reuse, bounded codebase reads, and capability-based sub-agent delegation.

The SVG appears to be current relative to the PUML (`workflow-sequence.svg` is newer than `workflow-sequence.puml`) and contains the same rendered stage structure.

One medium issue remains in the project docs/logic around post-review diagram refresh detection. It can cause unnecessary diagram regeneration and context reloading because the workflow tries to infer freshness from Git history for transient diagram files.

## Findings

### 1. Medium — Review-resume diagram refresh uses Git history for transient diagrams

**Where**

- `commands/mi-continue.md`, Review-Resume Step 2.5
- `commands/mi-draw-diagrams.md`, notes on transient implementation diagrams
- `commands/mi-generate-implementation-diagrams.md`, `diagrams/README.md` frontmatter recipe

**What I found**

The Review-Resume Handler computes:

```bash
diagram_commits="$(git log --format=%H -- "millwright-inspector/workflow-stream/$active_feature/implementation/diagrams/" | head -1)"
new_since_diagrams="$(git rev-list --count "${diagram_commits:-$base_commit}..HEAD" 2>/dev/null || echo 0)"
```

But `implementation/diagrams/` is a transient workflow artifact that is archived at stage 8 (moved into `blueprints/history/v[N+1]/implementation/diagrams/`) and is not the source of truth while live. If those files are not committed, `git log -- implementation/diagrams/` returns nothing, so the fallback becomes `base_commit`. That makes `new_since_diagrams` count the entire implementation range, not only review-loop commits.

**Impact**

The workflow can prompt to regenerate implementation diagrams even when no review-loop code changes happened. If the inspector accepts, the diagram pass may re-open `change-summary.md`, diff hunks, and targeted code context unnecessarily. That is exactly the kind of avoidable context expansion the optimization work is trying to prevent.

**Suggested fix**

Track diagram freshness in workflow data, not Git history. The lowest-friction option is to add `base-commit` and `head` to `implementation/diagrams/README.md` frontmatter when diagrams are generated:

```yaml
---
id: <uuid>
stage: implementation
base-commit: "<base_commit>"
head: "<git rev-parse HEAD>"
---
```

Then Review-Resume Step 2.5 should read that `head` and compare it with `git rev-parse HEAD`. If equal, skip the refresh prompt. If different, prompt. This avoids reading Git history for transient files and makes the freshness check deterministic.

An alternative is storing `implementation-diagrams-head=<sha>` in `progress.md`, but the README frontmatter keeps the freshness key next to the generated artifact.

### 2. Low — The PUML omits the optional post-review diagram refresh branch

**Where**

- `docs/diagrams/workflow-sequence.puml`, `Stage 6 → 7 — Post-review-session resume`
- `commands/mi-continue.md`, Review-Resume Step 2.5

**What I found**

The sequence diagram shows the post-review resume as:

- sanity-check no open findings remain
- mark review complete and advance 6 → 7
- auto-finalize

The command docs include an optional diagram refresh prompt between the stage advance and finalization. Because the diagram is explicitly high-level and happy-path focused, this omission is acceptable. It becomes worth adding only if the diagram is intended to document all context-heavy operations.

**Suggested fix**

If desired, add a compact `alt review-loop commits since diagrams` block after `advance 6 → 7`:

```plantuml
alt final HEAD differs from implementation/diagrams/README head
  Millwright --> Inspector : "Refresh diagrams before finalizing?"
  Inspector -> Millwright : y / n
  opt y
    Millwright -> Millwright : /mi-draw-diagrams
  end
end
```

This should be paired with Finding 1's deterministic freshness key. Without that fix, the diagram would document a check that is currently unreliable.

## Confirmed Consistencies

- Stage 2 blueprint generation matches `mi-apply-impact.md`: active feature is activated, `summary.md` is read, current requirements/config/diagrams are generated, and the workflow waits for inspector approval.
- Stage 3 now matches `mi-plan-implementation.md`: branch validation happens before work starts, PENDING todos are promoted to IMPLEMENTING before `base-commit` is captured, and `primer.md` is generated after branch/base state exists.
- Stage 4 matches `mi-continue.md`, `mi-update-blueprint.md`, and `mi-generate-implementation-diagrams.md`: post-chain resume verifies commits, optional drift refresh uses `change-summary.md`, implementation diagrams are generated from `base-commit..HEAD`, and review skeleton creation advances the workflow to stage 5.
- Stage 6 review handling matches `mi-review.md`: the review session is isolated, uses `review-context.md` plus `inspector-review.md` as first reads, and delegates finding clusters only for larger review sets.
- Stage 8 completion matches `mi-complete-workflow.md`: IMPLEMENTING todos become IMPLEMENTED, commits are written into requirements, blueprints are archived, transient implementation artifacts are removed, and the next queued feature loops back to stage 2.
- Sub-agent wording in the diagram and command docs uses capability tiers rather than explicit model names.
- The high-level diagram does not show every fallback or recovery path, but the omitted details are either out-of-band commands or non-happy-path branches.

## Context Optimization Review

The main context-bloat controls are present and consistent:

- Stage 3 uses `primer.md` as the required first read and keeps requirements/config/summary/todo-list as on-demand fallbacks.
- Stage 4 uses `implementation/change-summary.md` as a cache keyed by `base-commit` + `head`, so `/mi-update-blueprint` and diagram generation do not independently re-scan the same range.
- Stage 4's bounded context policy prioritizes diff hunks, caps caller/callee expansion, skips generated/vendor/lock/binary artifacts, and records omissions.
- Stage 6 uses `review-context.md` as a compact review-loop snapshot and escalates to canonical files only when needed.
- Sub-agents write small artifacts and keep chat replies short, which prevents the main context from absorbing every detailed inspection.

The remaining context-risk area is the post-review diagram refresh freshness check described in Finding 1.

## Verification Performed

- Reviewed `docs/diagrams/workflow-sequence.puml`.
- Checked `docs/diagrams/workflow-sequence.svg` presence and timestamp relative to the PUML.
- Reviewed command docs for stage 2 through stage 8 and diagram-related flows.
- Reviewed `scripts/commits.sh`, `scripts/review.sh`, `scripts/frontmatter.sh`, `hooks/validate-on-write.sh`, and `templates/change-summary.md.tmpl`.
- Ran shell syntax checks for scripts and hooks.
- Parsed all schema YAML files.
- Validated the change-summary frontmatter path with an all-numeric `HEAD` value.

