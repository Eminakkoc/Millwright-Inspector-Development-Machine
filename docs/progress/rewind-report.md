# `mi-rewind` — design report (first implementation)

A new inspector command, `/mi-rewind`, that lists the stages the active feature can be rolled back to and, after the inspector picks one, deterministically resets the artifacts, `progress.md` state, todos, and (optionally) git so the workflow can be re-driven from that point. This report enumerates the rewind targets for the **first implementation** and lists the consequences of each.

## Scope of the first implementation

- **Active workflow only.** `/mi-rewind` operates on the currently-active feature (`progress.md.active != null`). It does NOT touch already-completed features (entries in `progress.md.completed` or any `blueprints/history/v[N]/` snapshots they own), and it does NOT touch the cycle's quest files (`todo-list.md`, `summary.md`, `progress.md.queue`, `progress.md.completed`, `queue-rationale.md`, `quest/active.md`).
- **No cross-cycle rewind.** A workflow that has already drained (`active=null`, queue empty, cycle archived via `quest.sh end`) is out of scope. Likewise, rewinding past stage 1 (i.e. throwing the whole cycle away) is out of scope — that's `/mi-run --archive-active` territory.
- **Refuses while an isolated Skill session is live.** If `active.sub-flow` is `chain-in-progress` (stage 3) or `reviewing` (stage 6), the brainstorming Skill is running in a separate Claude Code session that mi-workflow has no control over. Rewinding mid-session would leave that session writing into folders this command just wiped. The first implementation refuses with a guidance message; the inspector must exit the Skill session first (or run `/mi-abort-workflow` if they want to scrap state without redoing).
- **Worktree fingerprint guard applies.** Rewind goes through `mi_assert_worktree_match` like every other state-mutating progress command. If the cycle was activated in a sibling worktree, the command refuses.

## Rewind targets, by current stage

The set of valid rewind targets is determined by `active.current-stage`. A target stage `T` is valid only when `T < current-stage` (you can't rewind to where you already are or forward).

| current-stage | Valid rewind targets |
| ---: | --- |
| 2 | 1.5 |
| 3 | 2, 1.5 |
| 4 | 3, 2, 1.5 |
| 5 | 3, 2, 1.5 |
| 6 | 5, 3, 2, 1.5 |
| 7 | 5, 3, 2, 1.5 |

Stage 4 itself is not offered as a rewind *target*. It's a thin transitional stage that runs entirely inside the post-stage-3 `/mi-continue` Resume Handler (drift check + diagram render + review-skeleton creation). Re-doing stage 4 is achievable by rewinding to stage 3 and re-typing `/mi-continue`, OR by running `/mi-draw-diagrams` directly for a diagram-only refresh — both already exist. Adding stage-4 as a rewind destination would duplicate those paths without giving the inspector anything new.

Stage 7 is transitional too (the review-completed brief stage that auto-fires `/mi-complete-workflow`); it only exists between the moment `inspector-review-completed` flips to true and the moment `mi-complete-workflow` runs. It is not a rewind target, only a current-stage from which earlier targets are reachable.

Stage 6 is offered as a rewind target only when current-stage is past 6 with caveats (see below). For the first implementation, **stage 6 rewind is out of scope** — see "Out-of-scope for v1" below.

## Per-target consequences

Each section below lists, for one rewind target:
- **Use case** — when an inspector would pick this target.
- **Files / folders touched** — what gets deleted, recreated, or rotated.
- **`progress.md` mutations** — which `active.*` fields revert, plus any cycle-level state changes.
- **Todo state** — what `todo-list.md` transitions look like for the active feature only.
- **Git** — whether `HEAD` moves, and which commits get dropped.
- **Preserved** — what the rewind does NOT touch.
- **Confirmation prompts** — which actions need an explicit `y/n` because they are destructive or irreversible.

### Rewind to **Stage 1.5** (queue selection / ordering)

**Use case.** The inspector realizes the wrong items were marked, the queue ordering was wrong, or that this feature shouldn't have been the next one to run. They want to re-mark `[x] (assignee) TODO` selections and let the dispatcher re-propose an order before any feature is activated.

**Files / folders touched.**
- `workflow-stream/[active-feature]/blueprints/current/` — **rotated** into `blueprints/history/v[N+1]/` via `blueprints.sh rotate --reason-kind manual --reason-summary "rewind to stage 1.5"` (we do NOT delete; we keep the audit trail). After rotation, `current/` is left empty.
- `workflow-stream/[active-feature]/implementation/` — **deleted** (`inspector-review.md`, `review-context.md`, `change-summary.md`, `diagrams/`). This is in-flight scratch state, not a shipped artifact, so deletion matches `/mi-abort-workflow` semantics.
- `quest/<active-slug>/queue-rationale.md` — **deleted**. The `/mi-continue` dispatcher keys on its absence to route to stage-1.5 step A, so removing it puts the dispatcher back into "selections still pending" mode.

**`progress.md` mutations.**
- `active.feature` is appended to the **front** of `progress.md.queue` (NOT the end — the inspector's intent is "let me reconsider this feature's selection / position", and dropping it to the back of the queue would bury it behind other already-ordered features). Then `active` is set to `null`.
- The other queue features stay in their current order; the rewind does not synthesize a new ordering — that's the dispatcher's job at stage 1.5 step B.

**Todo state.** For the active feature only: `IMPLEMENTING → PENDING` (if past stage 3) and then `PENDING → TODO` (so the inspector can re-mark). Other features' todos are untouched. The `(assignee)` tag is preserved verbatim; `[x] (emin) IMPLEMENTING — AUTH-001` becomes `[ ] (emin) TODO — AUTH-001`. **CANCELED items are NOT reverted** (they were explicitly removed from scope; the inspector would have to re-`/mi-update-todo-list add` them if they want them back).

**Git.** If `active.base-commit` is non-null, the inspector is prompted: *"Reset HEAD back to `<sha>`? This drops N implementation commits. (y/n)"* — answering `n` leaves the commits in place but warns that re-entering the same feature later will see a non-empty `base-commit..HEAD` from a stale base. Answering `y` runs `git reset --hard <base-commit>`. Either way the choice is visible.

**Preserved.** `journal/`, the cycle's quest files (`todo-list.md` minus the active-feature transitions, `summary.md`, `progress.md.queue`, `progress.md.completed`, `quest/active.md`), other features' `workflow-stream/<other-feature>/` folders, all `blueprints/history/v[N]/` versions of all features (including the freshly-rotated one for the active feature), the `.git` directory itself.

**Confirmation prompts.** (1) Final "proceed?" listing every action. (2) Git-reset y/n if commits exist.

---

### Rewind to **Stage 2** (re-do blueprint generation)

**Use case.** The inspector reviewed `blueprints/current/{requirements.md, config.md, diagrams/}`, accepted them, then realized during stage 3 or later that the requirements themselves were wrong (wrong scope, wrong seam, missing constraint). They want to regenerate the blueprint from the same `summary.md` + codebase, possibly after editing `## Inspector Additions`.

**Files / folders touched.**
- `workflow-stream/[active-feature]/blueprints/current/` — **rotated** into `blueprints/history/v[N+1]/` (`blueprints.sh rotate --reason-kind manual --reason-summary "rewind to stage 2"`). The just-rotated history version is the snapshot of the requirements that produced the now-discarded implementation.
- `workflow-stream/[active-feature]/implementation/` — **deleted** entirely (`inspector-review.md`, `review-context.md`, `change-summary.md`, `diagrams/`).

**`progress.md` mutations.**
- `active.current-stage = 2`
- `active.sub-flow = none`
- `active.base-commit = null`
- `active.planning-mode = none`
- `active.review-mode = none`
- `active.execution-mode = none`
- `active.implementation-completed = false`
- `active.inspector-review-completed = false`
- `active.drift-check-completed` — dropped (consistent with `progress.sh reset`)
- `active.history-baseline-version` — dropped (so the next stage-3 entry recaptures it from the new history version count)
- `active.feature` and `active.branch` are **preserved** (the inspector is keeping the same feature, just regenerating its blueprint).
- Worktree fingerprint fields (`worktree-path`, `git-common-dir`, `git-worktree-dir`) are immutable and stay.

**Todo state.** For the active feature only: `IMPLEMENTING → PENDING`. The inspector's selection set is preserved; they don't re-mark, and `mi-apply-impact` will pick up the same PENDING set when it re-fires. CANCELED items left as-is.

**Git.** If `active.base-commit` is non-null, prompts to reset HEAD to `base-commit`. After reset, the branch is back to where it was at stage 3 entry (so `mi-plan-implementation` will recapture the same SHA when stage 3 is re-launched, unless the inspector commits something else first).

**Preserved.** `## GIT BRANCH` and `## Inspector Additions` from the rotated `config.md` are NOT auto-spliced into the next regeneration — the inspector is rewinding because they want a fresh blueprint. They re-edit `## Inspector Additions` after `mi-apply-impact` re-runs. (Open question: should we splice them automatically? See "Open design questions".)

**Confirmation prompts.** (1) Final "proceed?" listing every action. (2) Git-reset y/n if commits exist.

**Resumption path.** After the rewind, `progress.md.active` is at stage 2 with feature/branch preserved. The next valid command is `/mi-apply-impact` (manually invokable; `/mi-rewind` calls it as the last step so the blueprint is regenerated immediately, matching the user's intent). The inspector then reviews the regenerated `blueprints/current/`, types `/mi-continue`, and the standard stage-2 → stage-3 path resumes.

---

### Rewind to **Stage 3** (re-do implementation)

**Use case (the example in the user's request).** The inspector is at stage 5 (inspector-review) or already past it, and realizes the implementation went in the wrong direction relative to the (still-correct) requirements. They want to drop all implementation commits, keep `blueprints/current/` exactly as approved, and re-launch `/mi-plan-implementation` from a clean base.

**Files / folders touched.**
- `workflow-stream/[active-feature]/blueprints/current/` — **untouched**. The blueprint is still the contract; only the implementation diverged.
- `workflow-stream/[active-feature]/implementation/` — **deleted** entirely (`inspector-review.md`, `review-context.md`, `change-summary.md`, `diagrams/`).

**`progress.md` mutations.**
- `active.current-stage = 3`
- `active.sub-flow = none`
- `active.planning-mode = none` — the inspector re-picks (they may go from `brainstorming` to `direct`, or vice versa)
- `active.review-mode = none`
- `active.execution-mode = none`
- `active.implementation-completed = false`
- `active.inspector-review-completed = false`
- `active.drift-check-completed` — dropped
- `active.base-commit` — **preserved** (the inspector wants to redo from the same baseline; recapturing would risk picking up unrelated commits the inspector made on the branch in the meantime). If the inspector wants a fresh base, they should rewind to stage 2 instead.
- `active.history-baseline-version` — preserved (same reason: same baseline cycle).
- `active.branch` and `active.feature` preserved.

**Todo state.** Active feature's todos stay in IMPLEMENTING. They're still the in-scope items; only the code changed.

**Git.** **Always** prompts: *"Reset HEAD back to `<base-commit>` (`<sha>`)? This drops N implementation commits. (y/n)"*. This is the canonical destructive operation of this rewind target — answering `n` makes the rewind a no-op for git, which leaves the branch carrying the bad commits while progress.md says stage 3. The first implementation **refuses to proceed** if the inspector answers `n` here, because the resulting state (stage 3, `implementation-completed=false`, but commits present in `base-commit..HEAD`) violates the resume-handler's expectations. (The inspector can `/mi-abort-workflow` if they want to abandon git changes manually.)

**Preserved.** `blueprints/current/` (including `primer.md` if present), `quest/<active-slug>/` files, `journal/`, all history versions, the `.git` directory's branches and remotes.

**Confirmation prompts.** (1) Final "proceed?". (2) Git-reset y/n (mandatory `y` to continue).

**Resumption path.** After the rewind, `progress.md.active` is at stage 3 with base-commit / branch / feature preserved and todos in IMPLEMENTING. The next valid command is `/mi-plan-implementation` (re-launched by `/mi-rewind` automatically). The launcher prompts again for `planning-mode` and proceeds as usual; `primer.md` is regenerated by the launcher.

---

### Rewind to **Stage 5** (re-do inspector review writing)

**Use case.** The inspector wrote findings in `inspector-review.md`, then changed their mind — maybe they realized a free-form sentence was misclassified during canonicalization, maybe they want to regroup findings differently, or maybe they wrote findings during stage 5 but want to start over before triggering the review session. They want a fresh skeleton without re-running the implementation or the diagrams.

**Files / folders touched.**
- `workflow-stream/[active-feature]/implementation/inspector-review.md` — **deleted and re-created** as the empty skeleton (frontmatter + empty `## Implementation Review`).
- `workflow-stream/[active-feature]/implementation/review-context.md` — **deleted** if present (it's only written when `/mi-review` fires for stage 6; if rewinding from past-stage-6, this file exists and must go).
- `workflow-stream/[active-feature]/implementation/change-summary.md` — **preserved** (it's a cache of `base-commit..HEAD` and remains valid).
- `workflow-stream/[active-feature]/implementation/diagrams/` — **preserved** (still reflects current `base-commit..HEAD`).
- `workflow-stream/[active-feature]/blueprints/current/` — untouched.

**`progress.md` mutations.**
- `active.current-stage = 5`
- `active.sub-flow = none`
- `active.review-mode = none`
- `active.inspector-review-completed = false`
- `active.implementation-completed` — preserved (still true, the implementation hasn't changed).
- `active.base-commit`, `active.branch`, `active.feature`, `active.planning-mode`, `active.execution-mode` — all preserved.

**Todo state.** Active feature's todos stay in IMPLEMENTING.

**Git.** **No git changes.** Stage 5/6 fixes that landed during a previous review session — if any — stay on the branch. (See "Open design questions" for why a stage-6 rewind that drops review-loop commits is out of scope for v1.)

**Preserved.** Everything except the two review files listed above.

**Confirmation prompts.** (1) Final "proceed?". This rewind has no irreversible git operations, so a single confirmation is enough.

**Resumption path.** After the rewind, `progress.md.active` is at stage 5 with implementation-completed already true. The inspector edits the fresh `inspector-review.md` skeleton and types `/mi-continue` as usual; the Inspector Handler in `/mi-continue` runs canonicalization → either auto-completes (no findings) or auto-fires `/mi-review`. No mi-rewind logic re-fires anything here — control returns directly to the inspector.

## Out-of-scope for v1

These rewind targets are **deliberately not** offered in the first implementation. They are listed here for posterity — each one is plausible but has a tracking gap that needs to be closed before implementation is safe.

- **Rewind to Stage 6 from past-stage-6.** A previously-completed review session produced commits that landed between `base-commit..HEAD` *after* the original implementation commits. Those review-loop commits are not separately tracked anywhere — `progress.md` records only `base-commit`, not a "post-implementation pre-review" SHA. To rewind to stage 6 we would need to drop the review-loop commits without dropping the implementation commits, and there's no way to do that without another captured SHA. Adding `active.post-implementation-commit` (captured by the post-chain Resume Handler at stage 4) would close the gap, but that's a separate piece of work. For v1, the workaround is "rewind to stage 5" (fresh review file, keep all commits) or "rewind to stage 3" (drop all commits and re-do everything).
- **Rewind to Stage 4.** As discussed above, stage 4 is a transitional handler step rather than an interactive surface; rewinding to it duplicates `/mi-draw-diagrams` (for diagram-only) or "rewind to stage 3 + re-`/mi-continue`" (for the full handler). Not worth the extra option in the menu.
- **Rewind across cycles.** Throwing away the entire cycle is what `/mi-run --archive-active` does already. Reframing it as a rewind target is unnecessary.
- **Rewind to a previous feature in `progress.md.completed`.** The user explicitly excluded shipped features from v1. Implementing this would require un-archiving the rotated `blueprints/history/v[N]/implementation/` artifacts and re-claiming the slot; the schema and folder layout don't natively support that, and the user's request is for the *current* workflow only.

## Open design questions

These are decisions the implementation should make explicitly; the report has not committed to one answer.

1. **Should the rewind-to-stage-2 target auto-splice `## GIT BRANCH` and `## Inspector Additions` from the rotated config?** `mi-update-blueprint` does this via `blueprints.sh preserve-inspector-sections` for mid-cycle rotations. For rewind, the inspector's intent is "give me a fresh blueprint" — but losing their carefully-crafted custom prompts is annoying. **Tentative recommendation:** preserve them by default (matches `mi-update-blueprint`'s contract); the inspector can edit the regenerated `config.md` before `/mi-continue` if they want to start clean.
2. **Should the rotation `reason-kind` be `manual` or a new `rewind` enum value?** The `reason.schema.yaml` enum is `completion | spec-update | re-spec-cascade | re-plan-cascade | manual`. Using `manual` keeps the schema unchanged but loses the audit signal. Adding `rewind` requires a schema migration but makes the audit trail richer. **Tentative recommendation:** add `rewind` to the enum — the rotation's `summary` field can record the from-stage / to-stage transition, and `reason.kind` should distinguish "inspector rolled back the workflow" from "inspector manually refreshed the blueprint". One-line schema change; worth it.
3. **Single `/mi-rewind` command vs. per-target subcommands?** Two options: (a) `/mi-rewind` with no args lists targets, then takes a follow-up reply (`stage-3`, `1.5`, etc.); (b) `/mi-rewind <target>` direct, with `/mi-rewind` (no args) listing options. **Tentative recommendation:** option (b) — matches the flag-style of `/mi-abort-workflow --drop-feature=...` and is easier to test. The no-args form prints the menu and exits without mutating.
4. **What happens if the inspector rewinds while uncommitted changes exist in the working tree?** A `git reset --hard` would clobber them. The first implementation should refuse with a guidance message ("commit, stash, or discard your working-tree changes first") rather than nuking unsaved work. Already aligns with the `/mi-abort-workflow` precedent (which doesn't touch git at all).
5. **Where does the rewind announcement land?** Existing recovery commands print a one-paragraph summary at the end. `/mi-rewind` should do the same: state the rewind target, list every action taken, and name the next valid command (`/mi-apply-impact`, `/mi-plan-implementation`, etc.).
6. **Relationship to `/mi-abort-workflow`.** Today, abort-with-no-flag is structurally identical to "rewind to stage 2 minus rotation, minus git reset, plus blueprint preservation". Once `/mi-rewind --target=2` exists, the no-flag abort is arguably redundant. **Tentative recommendation:** keep both — abort signals "I'm putting this aside / canceling intent" and rewind signals "I'm iterating, redo". Document the difference in both command pages.
7. **Refusal vs. soft-handle when sub-flow is non-`none`.** `chain-in-progress` (Skill is live) is a hard refusal. `resuming` only exists during the brief window inside `/mi-continue`'s Resume Handler — if the inspector types `/mi-rewind` while a Resume Handler invocation is mid-flight, that's a session crash recovery scenario and `/mi-resume-workflow` should run first. The first implementation should refuse on `chain-in-progress` and `reviewing`, treat `resuming` as "tell the inspector to re-type `/mi-continue` first then try again", and proceed normally on `none`.

## Comparison table — rewind vs. existing recovery commands

| Command | Active feature lifecycle | Blueprint | Implementation/ | Git | Todos | progress.md |
| --- | --- | --- | --- | --- | --- | --- |
| `/mi-abort-workflow` (no flag) | Reset to stage 2, feature preserved | **Preserved** | Deleted | Untouched | IMPLEMENTING → PENDING (active feature) | `progress.sh reset` |
| `/mi-abort-workflow --drop-feature=requeue` | Active block cleared, feature appended to queue end | Preserved | Deleted | Untouched | IMPLEMENTING → PENDING (active feature) | `progress.sh requeue` |
| `/mi-rewind --target=1.5` | Active block cleared, feature **prepended** to queue front | **Rotated to history** | Deleted | Optional reset to base-commit | IMPLEMENTING → PENDING → TODO (active feature) | Active=null, queue mutated |
| `/mi-rewind --target=2` | Reset to stage 2 | **Rotated to history** (re-generated by auto-fired `/mi-apply-impact`) | Deleted | Optional reset to base-commit | IMPLEMENTING → PENDING (active feature) | Like `progress.sh reset` |
| `/mi-rewind --target=3` | Reset to stage 3 | Preserved | Deleted | **Mandatory** reset to base-commit | Stay IMPLEMENTING | Clear *-completed flags, planning/review/execution mode = none, base-commit preserved |
| `/mi-rewind --target=5` | Reset to stage 5 | Preserved | Mostly preserved (review files reset; diagrams + change-summary kept) | Untouched | Stay IMPLEMENTING | inspector-review-completed=false, review-mode=none, sub-flow=none |

The clearest design contrast: **abort is non-destructive to git and blueprints; rewind is destructive in proportion to how far back you go.** That distinction is the first implementation's main user-facing message.
