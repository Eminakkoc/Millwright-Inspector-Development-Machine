# Workflow continuity gap fixes — v11

Consolidated plan after ten rounds of review feedback. v10 is preserved as `tmp/progress-gap-v10.md` (round-9 snapshot).

## Themes (unchanged)

- **A — Move state advances to *after* side effects.**
- **B — Make stage launchers idempotent for the same active feature.**
- **C — Persist interactive proposals to disk before yielding control.**
- **D — Dispatcher coverage for between-stage / auto-fire states.**

## Cross-cutting helper: `progress.sh advance-to`

Single atomic helper for stage skip-transitions.

**Signature:** `progress.sh advance-to <expected-current> <target> [--set field=value]...`

**Required safeguards:** `require_active`, `mi_assert_worktree_match`, immutable-field rejection (`worktree-path` / `git-common-dir` / `git-worktree-dir`), `current-stage` rejection in `--set` (the helper owns that field), duplicate `--set` field rejection, `yaml.safe_load` value parsing, all semantic validation before any write, candidate write to a same-directory temp file, single `frontmatter.sh validate "$tmp" progress`, then atomic rename over `progress.md`.

**Stage-pair whitelist:** `3 → 5`, `5 → 7`, `6 → 7`. Adjacent transitions stay with `advance`.

**Related hardening:** update `progress.sh set` itself before relying on multi-field writes in this plan. Today it loops over `field=value` args and writes once per field; v10 needs a batched implementation: validate all fields first (same immutable-field list, duplicate-field rejection, `yaml.safe_load` parsing), write the candidate result to a same-directory temp file in one Python pass, validate the temp file against the `progress` schema, then atomically rename it over `progress.md`. Single-field behavior stays identical. This avoids both half-written states (`base-commit` captured but `history-baseline-version` missing) and invalid-destination states from unknown fields rejected by `additionalProperties: false`.

## 1. Stage-4 Resume Handler — split marker write + drift-completion probe (closes F1)

**File:** `commands/mi-continue.md`

### The race v9 left open

v9 wrote `drift-check-completed=true` standalone right after `/mi-update-blueprint` returned, then `advance-to` next. There's still a session-break window between `/mi-update-blueprint` returning successfully and the marker write landing. On retry, marker is false, the prompt re-asks, and if the inspector answers "yes" again, a second `/mi-update-blueprint` would run — rotating again on top of the just-completed rotation. Even if `/mi-update-blueprint`'s own recovery (item 10) catches `current/`-already-complete, the user-visible behavior is "I just answered this; why am I being asked again?"

### Fix: a Step 0 drift-completion probe with a per-cycle baseline

When entering the Resume Handler, we can detect "drift was successfully completed in this cycle" without re-prompting if:

1. The drift marker is false (still default).
2. The cycle's baseline of "history versions that existed before stage 3" is below the highest-numbered `vN` carrying `reason.kind == "spec-update"` for this feature.
3. `blueprints.sh check-current --require-primer "$active_feature"` returns `0` (stage-3+ regeneration completed, including `primer.md`).

This requires a per-cycle baseline so we don't mistake an aborted prior cycle's leftover spec-update for this cycle's drift. We add a small field to the active block.

### Schema additions to `progress.schema.yaml` (both optional, missing → defaults)

```yaml
properties:
  drift-check-completed:
    type: boolean             # missing → false
  history-baseline-version:
    type: [integer, "null"]   # missing/null → unknown; probe disabled until captured
    description: >
      Highest blueprints/history/v[N] index for active.feature at stage-3 entry.
      Used by the Resume Handler's drift-completion probe to distinguish
      this-cycle rotations from prior-cycle rotations. Captured by
      /mi-plan-implementation alongside base-commit on first stage-3 entry;
      preserved across re-entries (the re-entry guard skips Step 3 entirely).
```

`progress.sh activate` and `progress.sh reset` do NOT need to write these — both new fields are optional. `drift-check-completed` absence is false; `history-baseline-version` absence is **unknown**, not `0`.

**`reset` intentionally drops both fields.** Abort recovery rebuilds the active block to a fresh-cycle shape (feature + branch + worktree fingerprint preserved; everything else reset). Both `drift-check-completed` and `history-baseline-version` fall away with the rest. This is correct: after an abort, the next stage-3 entry re-captures the baseline against current history (which now includes any partial cycle's rotations), so the probe sees the post-abort world as ground truth instead of the pre-abort baseline. If a future change extends the reset preserved-field list, do **not** add these — preserving them would let a stale baseline incorrectly mark the next cycle's drift as "already done."

### `/mi-plan-implementation` Step 3 captures the baseline

Same atomic set as `base-commit` and `sub-flow=chain-in-progress` (after `progress.sh set` is made batched as described above):

```bash
# At stage-3 entry (gated on base-commit == null, same as the existing capture).
history_dir="$data_root/workflow-stream/$active_feature/blueprints/history"
baseline=0
if compgen -G "$history_dir/v*" >/dev/null; then
  baseline="$(ls -d "$history_dir"/v[0-9]* 2>/dev/null \
              | sed -n 's|.*/v\([0-9]\+\)$|\1|p' | sort -n | tail -1)"
fi
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh set \
  "base-commit=$base_commit" \
  "sub-flow=chain-in-progress" \
  "history-baseline-version=$baseline"
```

The re-entry guard ("if active.current-stage == 3 and active.sub-flow in {chain-in-progress, resuming}, skip Step 3 entirely") preserves the originally-captured baseline across retries.

Also handle the possible legacy/partial stage-3 launch state: if `active.current-stage == 2` but `base-commit != null`, treat this as Step 3 having written its state but not advanced. Do not recapture `base-commit` or `history-baseline-version`; regenerate/validate `primer.md` if needed, then finish the stage-3 launch with `progress.sh advance 2`. This prevents the new batched baseline write from moving the old "break between set and advance" hole into the Approve Handler.

### Resume Handler flow (revised)

```
Step 0 — Drift-completion probe (NEW; closes F1):
   if active.drift-check-completed != true:
     baseline = active.history-baseline-version
     if baseline is null/missing:
       # Unknown baseline means this cycle predates the capture or Step 3 was partial.
       # Do NOT infer drift from old history. First ensure current/ is structurally
       # complete; an incomplete current/ must recover before any prompt can mark
       # drift-check-completed.
       current_status = blueprints.sh check-current --require-primer "$active_feature"
       if current_status != 0:
         route to /mi-update-blueprint recovery (item 10), or stop with its diagnostic.
         The recovery route must preserve the reason kind of the recoverable
         rotation it is resuming:
           - partial v[K].partial/reason.md.kind, if a partial exists
           - otherwise latest finalized v[N]/reason.md.kind, for empty-current
             manual/spec-update recovery
         GUARD — recoverable-kind allowlist:
           recovered_kind MUST be in {"manual", "spec-update"} before /mi-update-blueprint
           is invoked. /mi-update-blueprint per Item 11 accepts only those two kinds;
           passing any other (`completion`, `re-spec-cascade`, `re-plan-cascade`) would
           fail at argument parsing.
           - completion partial → STOP with diagnostic: this state is owned by
             /mi-complete-workflow's Branch 0a (Item 6), not by /mi-update-blueprint.
             Tell the inspector to invoke /mi-complete-workflow (or /mi-resume-workflow
             for diagnosis) to resume the in-flight stage-8 rotation.
           - re-spec-cascade / re-plan-cascade partial → STOP with diagnostic: these
             are review-loop auto-trigger rotations; their resume path is the brainstorming
             review session via /mi-review, not /mi-update-blueprint. No state modified;
             surface to the inspector.
         Invoke `/mi-update-blueprint --reason-kind=<recovered_kind> <latest reason.summary>`.
         After recovery returns successfully:
           if recovered_kind == "spec-update":
             # A spec-update rotation has now completed even though the baseline
             # was unknown, so the drift decision is complete.
             progress.sh set "drift-check-completed=true"
             stop; next /mi-continue re-enters with marker true
           else:
             # A manual/non-drift recovery only made current/ whole again. Do not
             # mark drift complete; capture a fresh baseline and let the normal
             # drift prompt run in this invocation.
             progress.sh set "history-baseline-version=<current-highest-finalized-vN-or-0>"
             continue with Step 1 (normal drift prompt may run later)
       progress.sh set "history-baseline-version=<current-highest-finalized-vN-or-0>"
       continue with Step 1 (skip the probe for this invocation)
     # Find the highest finalized v[K] with K > baseline whose reason.md.kind == "spec-update"
     # for this feature.
     drift_done = false
     for each blueprints/history/v[K]/ where K > baseline:
       if reason.md.kind == "spec-update":
         drift_done = true; break
     current_status = blueprints.sh check-current --require-primer "$active_feature"
     if drift_done AND current_status == 0:
         # /mi-update-blueprint successfully rotated + regenerated in this cycle;
         # we lost only the marker write. Persist the marker; skip the prompt.
         progress.sh set "drift-check-completed=true"
     elif drift_done:
         # A spec-update rotation started in this cycle but current/ is not complete.
         # Do not offer the normal continue/reason prompt. Route to /mi-update-blueprint
         # recovery (item 10), or stop with its diagnostic if no safe recovery exists.
         /mi-update-blueprint --reason-kind=spec-update <latest spec-update reason.summary>
         # After recovery returns successfully:
         progress.sh set "drift-check-completed=true"

Step 1.  Commit-count check.
         If commit_count == 0 → route to zero-commit branch (item 3).

Step 2.  Standalone, non-blocking flag writes (idempotent):
         Prompt for `execution-mode` only when active.execution-mode == "none";
         otherwise reuse the persisted value (a prior partial run already chose).
            progress.sh set \
              "implementation-completed=true" \
              "execution-mode=$mode" \
              "sub-flow=resuming"

Step 3.  Drift prompt (skipped if active.drift-check-completed is now true):
           - Inspector answered "continue" → no side effect.
           - Inspector supplied a reason → invoke
             /mi-update-blueprint --reason-kind=spec-update <reason>
             and wait for it to return successfully.

Step 4.  Drift side effect succeeded — persist the marker:
            progress.sh set "drift-check-completed=true"

Step 5.  /mi-draw-diagrams (idempotent: change-summary cache).

Step 6.  review.sh init (idempotent existence check).

Step 7.  Final atomic advance-to:
            progress.sh advance-to 3 5 --set sub-flow=none
```

### Verification — does the probe genuinely close the race?

**Race window** (v9): between `/mi-update-blueprint`'s successful return (rotation written, regeneration written) and the standalone `progress.sh set "drift-check-completed=true"` write.

**Disk state during the window:**

- progress.md: `drift-check-completed=false`, `current-stage=3`, `sub-flow=resuming`, `base-commit=<X>`, `history-baseline-version=<B>`.
- blueprints/history/v[B+i] (for some i ≥ 1): `reason.kind == "spec-update"` for `active.feature`.
- blueprints/current/: regenerated by `/mi-update-blueprint`'s Step 4 → `check-current` returns `0`.

**On retry, Step 0 probe:**

- `drift-check-completed != true` → enter probe body.
- Walk `blueprints/history/v[K]/` directories where `K > B`. The drift's rotation is among them (kind=spec-update). Probe sets `drift_done=true`.
- `check-current == 0` → confirmed.
- Set `drift-check-completed=true`. Continue handler with the prompt skipped.

**False-positive resistance — aborted prior cycle on same feature:**

- Cycle 1 drift fires → v[K1] with kind=spec-update.
- Cycle 1 aborted via `/mi-abort-workflow` (history is preserved).
- Cycle 2 starts on same feature: `/mi-apply-impact` regenerates current/ (overwrite, no rotation). `/mi-plan-implementation` Step 3 captures `history-baseline-version = K1` (the highest finalized index at stage-3 entry, which is K1 from cycle 1).
- In cycle 2, no drift has run yet. Probe walks `K > K1` — finds nothing. Drift treated as not-yet-done. Prompt fires correctly.
- Once cycle 2's drift fires → v[K1+1] with kind=spec-update. K1+1 > baseline=K1 → probe trigger condition met. Correct.

**Idempotence — probe re-run after marker is set:**

- Marker is true → Step 0's outer guard skips. Probe doesn't re-fire. No spurious state writes.

**Edge case — multiple spec-update rotations in same cycle (re-fired drift):**

- Probe finds at least one v[K]>baseline with spec-update. Sets marker. Correct (drift was handled at some point).

**Edge case — drift partially completed (rotation done, regeneration not done):**

- Probe finds v[K]>baseline with spec-update.
   - `check-current` is 1 or 2, not 0.
- Outer AND fails. Probe does not fire.
- Because `drift_done == true`, do **not** offer the normal `continue`/reason drift prompt. The disk already proves a drift rotation started in this cycle, and `current/` is not complete. Route directly to `/mi-update-blueprint`'s recovery path (item 10) or stop with its diagnostic. This prevents the inspector from accidentally marking `drift-check-completed=true` over partial blueprints.

**Recovery loop note (intentional, not a bug).** When `current/` is `check-current==2` (partial regeneration) AND `drift_done==true`, the routed `/mi-update-blueprint --reason-kind=spec-update` call (without `--force-regen`) hits Item 10's "current/ has partial regenerated content" branch and refuses with a diagnostic — no rotate, no destruction. The probe's marker stays unset, and on every subsequent `/mi-continue` this same path repeats with the same diagnostic. The workflow does **not** progress until the inspector intervenes. This is intentional: auto-firing `--force-regen` would discard partial inspector-visible content without consent, which is what F2 closes. The inspector must either (a) repair `current/` manually until `check-current` returns `0`, or (b) re-run `/mi-update-blueprint --force-regen <reason>` (which only succeeds when latest history is `manual` or `spec-update`, per Item 10's safety gate). Surface this diagnostic explicitly in the Resume Handler's stop message so the inspector knows the loop will not self-resolve.

The probe closes F1 cleanly.

**Back-compat guard — missing baseline:** Never treat a missing/null `history-baseline-version` as `0`. Older in-flight cycles can already have `spec-update` history from an aborted prior attempt; using `0` would make the probe skip the drift prompt incorrectly. The first entry with an unknown baseline first requires `check-current --require-primer == 0`, then captures the current highest finalized history version and disables the probe for that invocation. If `current/` is empty or partial, it routes to `/mi-update-blueprint` recovery (or stops with its diagnostic) before any drift prompt can mark the check complete. If that recovery was `manual`, it only captures a fresh baseline and lets the normal drift prompt run; if it was `spec-update`, it marks `drift-check-completed=true`. Any subsequent successful `/mi-update-blueprint --reason-kind=spec-update` in the same cycle creates a newer version and becomes detectable on retry.

## 2. `/mi-apply-impact` re-entry for the same feature

**File:** `commands/mi-apply-impact.md`

```
if active is null:
    progress.sh activate
elif active.current-stage == 2:
    proceed against active.feature
else:
    error: feature mid-flight at stage N — abort first
```

`check-current == 0` short-circuit ("already complete"); `check-current == 2` surfaces what's missing and offers `--force`.

## 3. `/mi-plan-implementation` + Resume Handler partial-launch recovery

**Files:** `commands/mi-plan-implementation.md`, `commands/mi-continue.md`

**`mi-plan-implementation.md` re-entry guard:**

```
if active.current-stage == 3 and active.sub-flow in {"chain-in-progress", "resuming"}:
    Validate primer.md; regenerate via Step 3.5 if missing/incomplete.
    Skip planning-mode prompt iff active.planning-mode != "none"
      AND base-commit..HEAD has commits; otherwise re-prompt.
```

`base-commit` capture and `history-baseline-version` capture (item 1) both gated on `base-commit == null`. Re-entry preserves both.

**Resume Handler:**

- `sub-flow=resuming` written at Step 2 (after commit-count check).
- Zero-commit branch: prompt `retry-launch | direct-empty | abort`.

### direct-empty side-effect contract

The "no code changes" note must not trip `review.sh canonicalize`, which only walks free-form text under `## Implementation Review` and explicitly skips HTML comments (`scripts/review.sh:246-253`).

````
1. Skip /mi-draw-diagrams entirely.
2. Skip implementation/change-summary.md regeneration.
3. Create/validate the inspector-review.md skeleton idempotently:

   ```
   data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
   ov_file="$data_root/workflow-stream/$active_feature/implementation/inspector-review.md"
   [[ -f "$ov_file" ]] || $CLAUDE_PLUGIN_ROOT/scripts/review.sh init "$active_feature"
   $CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh validate "$ov_file" review-file >/dev/null
   ```

   Then insert this HTML comment once, immediately after the frontmatter block and before any markdown heading. Do not synthesize a fresh `requirements-id`; `review.sh init` reads the current `requirements.md.id` and preserves the back-reference.

   ```
   <!-- direct-empty cycle (planning-mode=direct, zero commits in base-commit..HEAD).
        The inspector reported during stage 4 that no code changes were needed.
        Reason: <inspector's reason or "not provided">.
        Approve with no findings to advance, or write findings under
        "## Implementation Review" if you disagree. -->
   ```

   If `ov_file` already exists, preserve any existing findings. Only add the comment if it is not already present.

4. Standalone flag writes:
     progress.sh set \
       "implementation-completed=true" \
       "drift-check-completed=true" \
       "execution-mode=inline" \
       "sub-flow=resuming"

5. progress.sh advance-to 3 5 --set sub-flow=none
6. Hand off at stage 5.
````

## 4. Stage-7 dispatcher row + diagram-refresh placement + sub-flow clear

**File:** `commands/mi-continue.md`

- `sub-flow=reviewing` stays until after refresh prompt.
- Step 2.6 finalize: `progress.sh advance-to 6 7 --set sub-flow=none --set inspector-review-completed=true`.
- No-findings path (Inspector Step 3a): `progress.sh advance-to 5 7 --set sub-flow=none --set inspector-review-completed=true`.
- Add `stage 7 → auto-fire /mi-complete-workflow` dispatcher row. **Position (load-bearing):** in the active-cases dispatcher table, place the new row **between the existing `6 + reviewing` row and the `any other → /mi-resume-workflow` catch-all**. Final ordering inside the active-cases block: `2 → Approve Handler` → `3 → Resume Handler` → `5 → Inspector Handler` → `6 + reviewing → Review-Resume Handler` → **`7 → auto-fire /mi-complete-workflow`** → `any other → /mi-resume-workflow`. Putting the new row before the catch-all is what makes it fire when the advance-to landed but the auto-invoke was interrupted; putting it after the existing handlers preserves their priority on lower stages. Re-firing `/mi-complete-workflow` is safe because Branch II in Item 6 makes it idempotent for this case (active!=null, `blueprints/current/requirements.md` missing, latest history kind=completion → skip Steps 1-4 and proceed Step 5 → 6 → 7).

## 5. Inter-feature pre-flight rows

**File:** `commands/mi-continue.md`

### Dispatcher table position (load-bearing)

Rows A/B live in the existing pre-flight (`active_feature == "null"`) section of the dispatch table, alongside the queue-rationale confirmation rows. Order matters — the existing fallback at the bottom (`queue_count == 0 and no [x] TODO lines → /mi-resume-workflow`) catches everything that doesn't match earlier rows, so Rows A and B must be evaluated **before** it or they will never fire. Final ordering inside the active=null block:

1. Existing — `[x] TODO` lines exist → Pre-flight Step 2A (inspector-driven selection takes precedence over auto-fire).
2. Existing — `queue_count > 0`, `queue-rationale.md` missing → Pre-flight Step 2B.
3. **NEW — draft queue-rationale confirmation** — `queue_count > 0`, latest `queue-rationale.md` batch status normalized to `draft` → Pre-flight Step 2B (confirm/update the latest batch, then flip it to `confirmed`).
4. **NEW — Row A (between features)** — auto-fire `/mi-apply-impact`.
5. **NEW — Row B (post-finish housekeeping)** — auto-fire `/mi-complete-workflow` Step 7.
6. Existing — `queue_count == 0` and no `[x] TODO` lines → `/mi-resume-workflow`.

Putting Rows A/B *after* the existing `[x] TODO` and queue-rationale confirmation rows preserves the inspector's manual selection signal (those rows reflect a deliberate inspector action; auto-fire should not pre-empt them). Putting them *before* the catch-all is what makes them fire at all. Row A requires confirmed rationale, so a draft rationale must route to Step 2B before any auto-apply path can run.

**Step 2B is extended (not reused as-is) for the draft case.** Today (v10 and earlier) Step 2B's only entry condition is `queue-rationale.md` missing — it always writes a fresh file via `frontmatter.sh init queue-rationale`. After Item 7 + the new draft-confirmation row above, Step 2B accepts two entry conditions and dispatches on file presence:

- (a) `queue-rationale.md` missing → write a fresh file with one `## Batch 1 — <date>` section, status implicit-confirmed (current behavior). Body filled per the existing template guide.
- (b) `queue-rationale.md` present with the latest batch's `status: draft` → `Edit` the existing file: update only the latest batch's `### Order / ### Dependencies / ### Notes` body in place, update top-level `features:` so it reflects the confirmed order that will be written to `progress.md.queue` (cumulative order across all batches, with the latest draft batch replaced by the confirmed order), set top-level `batch:` to the latest batch number, then flip top-level `status:` from `draft` to `confirmed`. Do **not** add a new batch (Item 7 reserves the append step for Step 2A); do **not** rewrite earlier batch bodies (they are audit history).

Both entry conditions share the same prompt logic, the same inspector-typed-order parsing, the same `progress.sh reorder` call, and the same auto-fire of `/mi-apply-impact`. The divergence is exclusively in the file-write step (init vs. targeted edit). Document this branch inside `commands/mi-continue.md` Step 2B so the file-write path is explicit, not implicit. Load-bearing invariant: after Step 2B returns, `queue-rationale.md.features - progress.completed` must equal `progress.queue` in order, or Row A will not fire between features.

### Row A — between features

```
condition:
  active is null
  AND queue_count > 0
  AND queue-rationale.md.status normalized to "confirmed"
  AND (queue-rationale.md.features  −  progress.md.completed, preserving order)
       equals progress.md.queue exactly, in the same order
action:
  auto-fire /mi-apply-impact
```

The "minus completed, preserving order" expression is `[f for f in features if f not in completed]`. Worked for both within-batch (after f1 completes, fires for f2) and across-batches (after Batch N completes and Batch N+1 starts, fires for the new batch's first feature).

### Row B — post-finish housekeeping recovery

```
condition:
  active is null
  AND queue empty
  AND no [x] TODO lines, no [ ] TODO lines
  AND progress.completed is non-empty
  AND blueprints/history/v[N]/reason.md exists for completed[-1] with reason.kind == "completion"
  AND quest/active.md.status == "active"
action:
  auto-fire /mi-complete-workflow (short-circuits to Step 7 housekeeping)
```

## 6. Stage-8 finalizer hardening

**Files:** `scripts/blueprints.sh`, `commands/mi-complete-workflow.md`

### `blueprints.sh rotate` — kind-matched recovery

```
- before any partial recovery or version selection:
    scan finalized v[0-9]*/ directories.
    if any finalized vK/ is missing reason.md → STOP.
    This is an old-format interrupted rotation shape; do not guess its kind
    or count it as a safe parent until an inspector repairs it.
- 0 partials → forward path
- exactly 1 partial v[K].partial:
    if K.partial/reason.md missing AND partial is empty → remove it and restart forward path
    if K.partial/reason.md missing AND partial has artifacts → STOP (old/unknown partial)
    if K.partial/reason.md.kind != requested --reason-kind → STOP (different commands cannot share a partial)
    else: resume — move any current/* still present into vK.partial/, rename vK.partial → vK
- exactly 1 unpublished temp v[K].partial.tmp:
    if tmp contains only reason.md or is empty → remove it and restart forward path
    else → STOP (unreachable under new flow; protects against accidental artifact moves into tmp)
- multiple partials → STOP
```

**Cross-product clarification.** "Multiple partials" is a single combined count, not per-K and not per-suffix. The rule: **STOP if `(count of v*.partial directories) + (count of v*.partial.tmp directories) > 1`, regardless of which K each carries.** The forward path only ever creates `.partial.tmp` for the current `next_n`, so the only way two partials of any kind can co-exist is a previously interrupted recovery — refuse loudly instead of guessing which to resume. This rule is checked before the per-shape branches above; if total partial count > 1, no per-shape branch fires.

**Forward path:** mkdir `v[next_n].partial.tmp` → write and validate `reason.md` there → atomic rename `v[next_n].partial.tmp → v[next_n].partial` (publishes recoverable intent) → `mv current/* into v[next_n].partial/` → atomic rename `→ v[next_n]` → `mkdir current/`.

Version selection scans finalized `v[0-9]*` directories only after the missing-`reason.md` preflight passes. Partial directories are handled by the recovery branch before picking `next_n`; they must never be counted as finalized versions or skipped over silently.

### `blueprints.sh resume-partial <feature> --expected-kind <kind>`

`--expected-kind` is required. Errors on missing partial, multiple partials, non-empty missing-reason partials, unpublished temp partials with unexpected contents, or kind mismatch. Empty missing-reason partials and empty/reason-only `.partial.tmp` directories are safe to remove because no blueprint artifacts have moved yet.

### `mi-complete-workflow.md` — top-of-command branches

```
Branch 0a — in-flight rotation matching completion:
    active!=null AND exactly one v[K].partial/ for active.feature
    AND v[K].partial/reason.md.kind == "completion"
    → blueprints.sh resume-partial; skip Steps 1-4; proceed Step 5 → 6 → 7.
    Note: Step 5 (implementation/ archival) uses `mv -n` and is already idempotent
    on the artifacts (inspector-review.md, review-context.md, change-summary.md,
    diagrams/) — re-entry from Branch 0a picks up cleanly even when Step 5
    landed some artifacts before the prior crash. No additional guard needed
    in Step 5 itself; the existence checks (`[[ -e ... ]]`) gate each move.

Branch 0b — partial blocking us (different kind):
    active!=null AND a v[K].partial/ for active.feature with kind != "completion"
    → STOP with diagnostic (inspector must finish or abandon the other command's partial).

Branch I — post-finish recovery (active=null):
    active is null AND progress.completed non-empty
    AND latest blueprints/history/v[N]/reason.kind == "completion" for completed[-1]
    → Set active_feature=progress.completed[-1].
      Recompute remaining from progress.queue.
      Skip Steps 1-6. Run Step 7 housekeeping only.
      Do not call progress.sh get for active fields in this branch.

Branch II — in-flight rotation already done (active!=null, finalized vN/):
    active!=null AND blueprints/current/requirements.md missing
    AND latest blueprints/history/v[N]/reason.kind == "completion" for active.feature
    → Set $version=N. Skip Steps 1-4. Proceed Step 5 → 6 → 7.

Branch III — normal forward path:
    else: Run Steps 1–7.
    Before Step 4's completion rotate, run
    `blueprints.sh check-current --require-primer "$active_feature"` and require `0`.
    If it returns `1` or `2`, STOP with a diagnostic; completion rotation must never
    archive a current/ tree that is missing the stage-3 primer.
```

## 7. Multi-batch queue-rationale

**Files:** `schemas/queue-rationale.schema.yaml`, `templates/queue-rationale.md.tmpl`, `commands/mi-continue.md`.

Schema gains optional `status: draft | confirmed` and `batch: integer` (missing → batch=1, status=confirmed).

Top-level frontmatter remains the machine-readable latest queue contract:

- `features:` is the cumulative ordered feature list for all batches recorded so far. When a later batch is draft, `features:` includes that draft batch's proposed order; Step 2B replaces the draft suffix with the confirmed order before calling `progress.sh reorder`.
- `batch:` and `status:` describe the latest batch only. Older batch statuses live only in the body audit trail; dispatcher rows read top-level `status` as "latest batch status."

**Schema description update (load-bearing).** The current `schemas/queue-rationale.schema.yaml` describes `features:` as "MUST exactly match `progress.md.queue` after the matching `progress.sh reorder` call." That single-batch invariant is no longer literally true after Item 7 lands. Replace the field's `description:` text with the multi-batch contract so the schema matches the dispatcher's actual reads:

> "Cumulative ordered feature list across all confirmed batches (and the proposed order for the latest batch when `status: draft`). The dispatcher's Row A (Item 5) requires `features - progress.completed` to equal `progress.queue` in order; Step 2B keeps these aligned by refreshing `features` whenever the latest batch flips from `draft` to `confirmed`. Step 2A appending a new batch must publish the cumulative `features` and `batch: N+1`/`status: draft` in the same write so the next `/mi-continue` routes to the draft-confirmation row."

Without this update, future readers of the schema will assume the v10 single-batch invariant still holds and may write code (e.g., a doctor check) that fails on legitimate multi-batch states.

Body uses `## Batch <N> — <date>` sections; each batch has its own `### Order`, `### Dependencies`, `### Notes`. Files without batch headers are treated as a single implicit `## Batch 1`.

**Heading detection regex (pinned).** Use `^## Batch (\d+)\b` to extract batch numbers from the body. Matches: `## Batch 1`, `## Batch 12 — 2026-04-30`, `## Batch 7    -- notes`. Does **not** match `## Batches`, `## Batch one`, or `### Batch 1` (only level-2 headings count). When the file has zero matching headings, treat the entire body as `## Batch 1` (back-compat with v10-and-earlier files). When N+1 is appended in Step 2A, derive `N` from the highest matched number, not from the count of headings (so a file containing only `## Batch 5` appends `## Batch 6`, not `## Batch 2`).

Step 2A on mid-cycle re-entry (confirmed status detected) appends a new `## Batch <N+1>` section; prior sections are preserved as audit. The same write must also publish the proposal in top-level frontmatter: set `batch: N+1`, set `status: draft`, and set `features:` to the cumulative ordered list (`previous confirmed features` + `proposed order for Batch N+1`). This makes the next `/mi-continue` route to the draft-confirmation row instead of Row A or the catch-all. Step 2B updates the LATEST batch body only, refreshes top-level `features:` / `batch:`, and flips top-level `status` to `confirmed`.

## 8. Stage-1 partial-generation detection

**Deferred to v12+; out of scope for the v11 implementation.**

Stage-1 (`/mi-run`) generates `quest/<slug>/todo-list.md`, `summary.md`, `queue-rationale.md`, and `progress.md` from the journal. A session break mid-generation can leave any of those files structurally incomplete — frontmatter present but body sections missing, or one file written and a sibling not yet started. v11 does not address this surface because:

- Detection requires a per-file body-completeness heuristic (frontmatter + section presence + non-placeholder content). Today's `frontmatter.sh validate` only checks the frontmatter; the body shape is implicit in the templates.
- The blueprint-side analogue (`blueprints.sh check-current`) exists and is materially extended in this round (Item 9), so the pattern is established for v12.
- The stage-1 surface (`mi-run` Step 1 / 1.5) is not otherwise touched by v11; bundling stage-1 work in would expand the round's blast radius without an F-failure to anchor it.

Scope to be defined when the stage-1 generator is next hardened — likely a `quest.sh check` helper analogous to `blueprints.sh check-current`, plus body-completeness regexes per template. No schema changes anticipated; the existing schemas already require the frontmatter shape.

## 9. Helper: `blueprints.sh check-current <feature>` + diagrams README schemas

**Files:** `scripts/blueprints.sh`, two schemas, `hooks/validate-on-write.sh`, `docs/blueprint-regeneration.md`, `commands/mi-update-blueprint.md`, `commands/mi-draw-diagrams.md`, `commands/mi-continue.md`.

### Return values (closes F4)

**Signature:** `blueprints.sh check-current [--require-primer] <feature>`

Default mode is for stage-2 blueprint approval and first-time generation recovery: `primer.md` is not expected yet, because `/mi-plan-implementation` writes it at stage 3. `--require-primer` is mandatory for stage-3+ callers (`/mi-update-blueprint` recovery, the Stage-4 drift probe, and `/mi-complete-workflow` before completion rotation), because mid-cycle regeneration and completion history must include `primer.md` with the rest of `blueprints/current/`.

- **`0` — complete:**
  - `requirements.md` valid frontmatter + non-placeholder body.
  - `config.md` valid frontmatter + non-placeholder body. **`## GIT BRANCH` may be empty** (per `docs/blueprint-regeneration.md:155`).
  - `diagrams/README.md` valid frontmatter against `diagrams-readme-blueprint` with `requirements-id` matching `requirements.md.id`.
  - `diagrams/` contains at least one `use-case-*.puml` (mandatory per `docs/workflow-spec.md` § "Diagram conventions").
  - If `--require-primer` is set: `primer.md` valid frontmatter against `primer` with `requirements-id` matching `requirements.md.id` and non-placeholder body.
  - **Sequence and structural diagrams are NOT required by check-current** (closes F4). The spec prefers 2–3 sequence diagrams, but zero-flow features (pure config / docs / refactor with no observable flow) are valid; check-current does not block them. The inspector is responsible for verifying flow coverage during the stage-2 blueprint review. Rendered images are also not required.

- **`1` — empty:** `requirements.md` AND `config.md` both missing AND `diagrams/` missing or scaffold-only (no README, no .puml). In `--require-primer` mode, the empty-vs-partial classification for requirements/config/diagrams is unchanged. A missing or invalid `primer.md` promotes a would-be `0` to `2` (partial); it does not promote a `1` (empty) to `2`.

- **`2` — partial:** anything in between.

### Stage-2 Approve Handler consumes `check-current`

Update `commands/mi-continue.md` Approve Step 1 to replace the existing existence-only checks for `requirements.md`, `config.md`, and `diagrams/` with `blueprints.sh check-current "$active_feature"` in default mode (no `--require-primer`; `primer.md` is not expected until `/mi-plan-implementation` writes it at stage 3):

```
if "$CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh" check-current "$active_feature"; then
  current_status=0
else
  current_status=$?
fi
case "$current_status" in
  0) ;;  # stage-2 blueprint is complete; proceed to /mi-plan-implementation
  1)
    echo "error: blueprints/current is empty; run /mi-apply-impact first" >&2
    exit 1
    ;;
  2)
    echo "error: blueprints/current is partial or invalid; repair it or re-run /mi-apply-impact before approving" >&2
    exit 1
    ;;
  *)
    echo "error: check-current returned unexpected status $current_status" >&2
    exit 1
    ;;
esac
```

This is load-bearing for stage-2 interruption safety. Without this consumer, a session interrupted midway through `/mi-apply-impact` can leave one or two blueprint files present, pass the old Approve Handler's path checks, and advance to `/mi-plan-implementation` with an incomplete reviewed blueprint. The stricter `--require-primer` mode remains limited to stage-3+ callers.

### Separate `branch-status` helper

```
blueprints.sh branch-status <feature>
  → "set" / "unset" / "trunk" / "multi"
```

`/mi-plan-implementation` consumes this for branch validation; `check-current` does not gate on it.

### Schemas (closes F3)

**`schemas/diagrams-readme-blueprint.schema.yaml`:**

```yaml
required: [requirements-id]
properties:
  id: { type: string, pattern: <uuid-any-version> }           # OPTIONAL — back-compat with old generated READMEs.
                                                              # Pattern accepts any UUID version (v1–v8) so
                                                              # hand-edited values aren't rejected; new READMEs
                                                              # from scripts/uuid.sh are v4 by default.
  requirements-id: { type: string, pattern: <uuid-any-version> }
  contributors: { type: array, items: { type: string } }     # optional
  date: { type: string, format: date }                         # optional
```

**UUID pattern note.** Use a permissive-but-valid UUID pattern such as `^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$` rather than the v4-specific pattern used elsewhere in the schemas (e.g., `progress.schema.yaml`). Diagrams READMEs are the most likely surface to be hand-edited or migrated from external systems; locking to v4 only would surface as a confusing validation failure for what's semantically a valid identifier. Still reject UUID-shaped strings with invalid version/variant nibbles so the schema matches the stated "v1–v8" rule.

**Two-part fix for F3:**

1. **`id` becomes optional in the schema.** Existing diagrams READMEs in `blueprints/history/v[N]/` written by older generators don't have `id` and would otherwise fail validation.
2. **Generator runbooks updated to write `id` going forward.** v10 ships matching edits to:
   - `docs/blueprint-regeneration.md:185` — Step C's "Also write a `diagrams/README.md` with the `requirements-id`..." gains a directive to call `scripts/uuid.sh` and write the resulting UUID into the `id:` frontmatter alongside `requirements-id`.
   - `commands/mi-update-blueprint.md:204` — Step 4's diagram regeneration block gains the same directive.

   New READMEs carry `id`; old ones keep validating; the canonical-shape rule (Rule 2 of the workflow spec) is honored going forward.

**`schemas/diagrams-readme-implementation.schema.yaml`:**

```yaml
required: [id]
properties:
  id: { type: string, pattern: <uuid-any-version> }
  stage: { type: string, enum: [implementation] }
```

Matches `commands/mi-generate-implementation-diagrams.md:123` output. `id` keeps the same permissive UUID pattern as the blueprint schema (per the UUID pattern note above). Implementation diagram READMEs intentionally do **not** carry `requirements-id`; they describe the implementation commit range, while `implementation/change-summary.md` and review artifacts carry the requirements back-reference. As part of this item, update the stale wrapper text in `commands/mi-draw-diagrams.md` Step 2 so it says the implementation generator writes `id` + `stage: implementation`, not a `requirements-id` back-reference. Do not add `requirements-id` to `diagrams-readme-implementation` unless the generator output is changed at the same time.

### Migration helper for legacy `diagrams/README.md` files

Projects that pre-date the `diagrams-readme-blueprint` schema may have hand-written `current/diagrams/README.md` files without a `requirements-id` back-reference, or with a stale one that no longer matches the sibling `requirements.md.id`. Once Item 9 ships, those files fail validation, and `check-current` returns `2` (partial) — silently blocking workflows on otherwise-healthy features. Without a migration story, v11 breaks every such project on first invocation.

Ship `scripts/migrate-diagrams-readme.sh` as part of Item 9. Behavior:

1. Walk every `data_root/workflow-stream/<feature>/blueprints/current/diagrams/README.md`.
2. For each file with frontmatter missing, missing `id`, missing `requirements-id`, or `requirements-id` that differs from sibling `blueprints/current/requirements.md.id`, read and validate the sibling `requirements.md` first. If the sibling is missing/invalid or has no readable `id`, print the README path and skip it; the helper cannot safely infer the back-reference.
3. Back-fill/update `requirements-id` to exactly match the sibling `requirements.md.id`; add `id:` only if absent (generated via `scripts/uuid.sh`). Do not rewrite an existing valid `id` just because it is non-v4. **If the existing `id` value is present but does not match the permissive UUID pattern (e.g., `id: foo`, malformed, or empty string), do NOT auto-rewrite it** — print the path under the failed-validation list at the end and skip the file. Auto-rewriting a hand-supplied `id` could clobber a deliberately-chosen identifier the inspector is using as an external reference key (e.g., a Linear / Notion / Jira ticket ID); the inspector must decide whether to delete-and-regenerate or fix in place.
4. Validate the resulting file against `diagrams-readme-blueprint`. Refuse to write if validation still fails (the README is structurally broken in a way the helper can't fix automatically — print the path and skip; surface the list at the end).
5. Idempotent — re-runs are no-ops on already-valid files whose `requirements-id` matches the sibling `requirements.md.id`.
6. Does **not** touch `blueprints/history/v*/diagrams/README.md` (archived; immutable per the existing coverage policy in `hooks/validate-on-write.sh:50-63`). Archived READMEs are not validated by the hook (no case branch for them) and not gated by `check-current` (which only walks `current/`), so they pose no migration risk.

Document a one-line invocation in the v11 release notes:

```
$CLAUDE_PLUGIN_ROOT/scripts/migrate-diagrams-readme.sh
```

Optionally, `/mi-doctor` can call the helper in dry-run mode to flag features whose READMEs would block check-current after upgrade — gives the inspector a heads-up before the first `/mi-continue` of the v11 era.

### Hook update

`hooks/validate-on-write.sh` does not currently have an explicit `diagrams/README.md` skip. The case statement (lines 65-78) routes by file path; `diagrams/README.md` matches none of the existing cases and falls through to the catch-all `*) exit 0 ;;` at line 78. The change is to **add** matching case branches so the hook routes diagrams READMEs to the right schema:

```sh
*/blueprints/current/diagrams/README.md)        schema="diagrams-readme-blueprint" ;;
*/implementation/diagrams/README.md)            schema="diagrams-readme-implementation" ;;
```

Archived READMEs under `blueprints/history/v*/diagrams/README.md` and `blueprints/history/v*/implementation/diagrams/README.md` follow the existing coverage policy (validated when live, immutable once archived — see the comment block at lines 50-63). No case branch is added for them, so the hook continues to skip them silently. If you ever need to validate an archived README by hand, run `scripts/internal/validate-frontmatter.sh` directly.

## 10. `/mi-update-blueprint` recovery — strict partial guard (closes F2)

**File:** `commands/mi-update-blueprint.md`.

### v9's gap

v9 only blocked the `check-current == 2` partial-state path when latest history reason was `manual`/`spec-update`. If latest reason was `completion`, `re-spec-cascade`, `re-plan-cascade`, or no history at all, v9 fell to the normal forward path → `blueprints.sh rotate` → archived the partial regenerated content. This violates the invariant "rotation must capture the most recent inspector-approved blueprint, not partial regeneration in progress."

### v10 rule: `check-current == 2` always stops

```
Top-of-command, in order:

  All `check-current` calls in this command use
  `blueprints.sh check-current --require-primer "$active_feature"`.
  `/mi-update-blueprint` is stage-3+ only, and a recovered/regenerated
  current/ is not complete until `primer.md` has been regenerated too.

  if exactly one blueprints/history/v[K].partial/ exists:
     if v[K].partial/reason.md missing:
       STOP with diagnostic (old/unknown partial; no state modified)
     elif v[K].partial/reason.md.kind != requested --reason-kind:
       STOP with diagnostic:
         "A <kind> blueprint rotation is already in progress at v[K].partial/.
          Re-run the command that owns that reason kind, or inspect and repair
          the partial manually. No state was modified."
     else:
       # Rotate was interrupted after intent publish and before final rename.
       blueprints.sh resume-partial "$active_feature" --expected-kind "$reason_kind"
       Set $version=K
       ensure-current
       proceed to Step 4 regeneration (skip the remaining top-of-command checks)

  elif multiple partials exist:
     STOP with diagnostic (ambiguous partial rotations; no state modified)

  if check-current == 1 (empty/scaffold-only)
     AND latest blueprints/history/v[N]/reason.md.kind in {"manual", "spec-update"}:
       # Post-rotate-pre-regenerate. Resume regeneration without a fresh rotate.
       Skip Step 2; ensure-current; Set $version=N; proceed to Step 4.

  elif check-current == 2 (partial):                   ← UNCONDITIONAL on partial state
       # Partial regeneration content in current/. ROTATING WOULD ARCHIVE PARTIAL CONTENT.
       # The kind of the latest history version determines whether --force-regen has
       # a safe parent to restore from, but the stop is unconditional.
       if --force-regen flag was passed:
           if latest blueprints/history/v[N]/reason.md.kind in {"manual", "spec-update"}:
               # Safe parent exists — discard partial, regenerate from history vN.
               Empty current/; ensure-current; Set $version=N; proceed to Step 4.
           else:
               # No safe parent. Refuse:
               STOP with diagnostic:
                 "current/ has partial regenerated content (check-current=2) AND no
                  manual/spec-update history version exists to restore from. Latest
                  history is <kind>. Manual cleanup required:
                    - Inspect current/, edit it into a structurally valid state,
                      and re-run /mi-update-blueprint <reason> normally.
                    - OR rm -rf current/* and re-run /mi-apply-impact (if you want
                      to regenerate from scratch via stage 2).
                  No state was modified."
       else:
           # Default — diagnostic, no state change:
           STOP with diagnostic:
             "current/ has partial regenerated content from a prior interrupted run
              (check-current=2). Re-running rotate would archive this partial state.
              Options:
                /mi-update-blueprint --force-regen <reason>  — discards current/
                  and regenerates from history (only valid when latest history
                  is manual or spec-update).
                Manually inspect/edit current/ until it's complete or empty,
                  then re-run /mi-update-blueprint with the appropriate flag.
              No state was modified."

  elif check-current == 1 AND latest reason.kind in {"completion", "re-spec-cascade", "re-plan-cascade"}:
       # check-current==1 (empty) without a manual/spec-update parent — confused state
       # not auto-recovered here.
       Surface to inspector; recommend /mi-resume-workflow.

  elif check-current == 1:
       # Empty/scaffold-only current with no readable manual/spec-update parent.
       # This includes "no history", missing/unreadable reason.md, and any other
       # unclassified latest-history state.
       STOP with diagnostic:
         "blueprints/current/ is empty or scaffold-only, but there is no safe
          manual/spec-update history version to resume regeneration from. No
          rotation was performed. Inspect blueprints/history/ and repair the
          missing or malformed reason.md, or rerun /mi-apply-impact if this
          feature should be regenerated from stage 2."

  else:
       # check-current == 0 (complete) AND we're not in any partial-recovery state.
       # Normal forward path: rotate complete current/ into history, then regenerate.
       Proceed to Step 2.
```

### `--force-regen` safety gate (preserved from v9)

```
--force-regen preconditions:
  - latest blueprints/history/v[N]/ exists
  - vN/reason.md.kind in {"manual", "spec-update"}

If neither: refuse (this is the same diagnostic as the "partial + --force-regen + no safe
parent" branch above).

When preconditions hold:
  - check-current == 0 → discard current/, ensure-current, regenerate from vN
                          (intentional override of "blueprints already complete")
  - check-current == 1 → ensure-current, regenerate from vN
                          (same as the no-flag empty-recovery branch above)
  - check-current == 2 → empty current/, ensure-current, regenerate from vN
                          (the new branch covered above)
```

### Verification — does the rule genuinely close F2?

**Failure case v9 left open:** `check-current == 2` + latest reason ∈ {completion, re-spec-cascade, re-plan-cascade, no history}.

- v9: `else → forward path → blueprints.sh rotate(current/)` archives partial regenerated content. Audit trail corrupted.
- v10: `check-current == 2` branch fires unconditionally. Without `--force-regen`, the command stops with a diagnostic (no rotate). With `--force-regen` AND no safe parent, the command refuses (no rotate, no destruction). With `--force-regen` AND safe parent, the partial is discarded and regeneration restarts from the safe parent (no rotate).

In every sub-case, `blueprints.sh rotate` is NOT called on a partial `current/`. F2 closed.

## 11. `/mi-update-blueprint` reason-kind alignment

**Files:** `commands/mi-update-blueprint.md`, `commands/mi-continue.md`.

`/mi-update-blueprint [--reason-kind <kind>] [--force-regen] <reason>`. Accepts `manual` (default) or `spec-update`. Stage-4 drift handler invokes with `--reason-kind=spec-update`.

## Adopted ordering

1. `progress.sh set` batched multi-field writes + `progress.sh advance-to` helper.
2. Item 9 — `check-current` (looser sequence rule, default-mode Approve Handler gate, `--require-primer` mode for stage-3+ callers, optional id in blueprint README schema, generator runbook updates) + `branch-status` helper + hook update + `migrate-diagrams-readme.sh` migration helper.
3. Item 11 — `/mi-update-blueprint` reason-kind alignment (`manual` default, `spec-update` accepted).
4. Item 6 — `blueprints.sh rotate` resumability + `resume-partial --expected-kind` + `mi-complete-workflow` four branches.
5. Item 10 — `/mi-update-blueprint` recovery (depends on 6, 9, 11) with strict partial/empty guards.
6. Item 1 — Stage-4 Resume Handler (depends on 9, 10, 11; Step 0 probe + split marker write + history-baseline-version capture in `/mi-plan-implementation`).
7. Item 2 — `/mi-apply-impact` re-entry.
8. Item 3 — `/mi-plan-implementation` re-entry + Resume zero-commit branch + direct-empty (HTML-comment note).
9. Item 4 — Review-Resume + Inspector Step 3a refresh placement.
10. Item 5 — Pre-flight rows.
11. Item 7 — multi-batch queue-rationale.
12. Item 8 — Stage-1 partial detection.

## Dropped from earlier drafts

- Stage-4 dispatcher row.
- Chained `advance N && advance N+1`.
- `reason.md`-presence-only signal in `vN/`.
- Single unified diagrams README schema.
- `implementation-completed=true` / `planning-mode != "none"` as completion proofs.
- Generic "set stage to anything" API.
- Marker field for `/mi-update-blueprint` mid-run state.
- Eager write of `drift-check-completed=true`.
- Erroring on confirmed `queue-rationale.md` in Step 2A.
- Hardcoding `/mi-update-blueprint` to `--reason-kind=manual`.
- Git history as the queue-rationale audit mechanism.
- Non-empty `## GIT BRANCH` as a check-current completeness requirement.
- Resuming any partial regardless of caller.
- Letting `/mi-update-blueprint` rotate over a partial-regenerated `current/`.
- Bundling `drift-check-completed=true` into the final `advance-to`.
- Strict equality between `queue-rationale.features` and `progress.queue` in Row A.
- Plain `## No code changes` text in `inspector-review.md` for direct-empty.
- `--force-regen` on any history state.
- **Standalone marker write as the sole F1 fix.** The two-step write (drift returns → marker write) still has a window. v10 adds a Step 0 probe in the Resume Handler that detects "drift completed but marker lost" by walking history versions newer than `history-baseline-version` for `kind=spec-update` — closes F1 without depending on the marker-write being atomic with `/mi-update-blueprint`'s return.
- **`check-current == 2` partial state limited to manual/spec-update history.** v9 still rotated partial content when latest history was completion / cascade / missing. v10 makes the partial guard unconditional — closes F2 in every sub-case.
- **Requiring `id` in blueprint diagrams README schema without runbook alignment.** v9 mismatched what generators wrote. v10 makes `id` optional in the schema (back-compat with existing READMEs) AND ships matching runbook edits so new READMEs always carry `id` — closes F3 from both directions.
- **Requiring at least one `sequence-*.puml` in `check-current`.** Spec calls sequence diagrams "conditional"; zero-flow features should not be blocked. v10 drops the requirement (inspector verifies flow coverage at the stage-2 review gate) — closes F4.
- **Treating missing `history-baseline-version` as `0`.** That confused old `spec-update` history with this-cycle drift. Missing/null is now "unknown": capture the current finalized version and run the normal drift prompt once.
- **Publishing `vN.partial/` before writing `reason.md`.** That left a recoverable-looking partial with no caller identity. The forward path now writes intent inside `.partial.tmp`, then atomically publishes `.partial/` only after `reason.md` validates.
- **Plain explanatory text inside the direct-empty review section.** Only an HTML comment is written; `## Implementation Review` stays otherwise empty so `review.sh canonicalize` has nothing to convert.
- **Running Step 7 post-finish recovery without reconstructed variables.** Branch I now derives `active_feature` from `progress.completed[-1]` and recomputes `remaining` before entering housekeeping.
- **Deploying Stage-4 recovery before the helpers it invokes.** `check-current`, `/mi-update-blueprint --reason-kind=spec-update`, rotate resumability, and `/mi-update-blueprint` recovery now ship before Item 1.
- **Letting `check-current == 1` fall through to rotate.** Empty/scaffold-only `current/` without a safe manual/spec-update parent now stops before any rotation.
- **Ignoring old finalized `vN/` folders without `reason.md`.** `blueprints.sh rotate` now stops on that old-format interrupted shape before version selection.
- **Misleading "remove `diagrams/README.md` skip" wording.** v10 implied an explicit skip exists at `hooks/validate-on-write.sh:64`. The actual code has no such skip — `diagrams/README.md` falls through the case statement to the `*) exit 0` catch-all. v11 re-frames the change as ADDING two case branches (one for `blueprints/current/diagrams/README.md`, one for `implementation/diagrams/README.md`), which is what the implementation actually does.
- **Assuming all existing `diagrams/README.md` files have a current `requirements-id`.** v10 made `id` optional in the blueprint schema but kept `requirements-id` required. Projects with hand-written or legacy READMEs would silently fail `check-current` (returning `2` = partial), blocking workflows; READMEs with stale back-references would fail the new `requirements.md.id` match check. v11 ships `scripts/migrate-diagrams-readme.sh` and documents the upgrade path so existing projects don't break on first invocation.
- **v4-only UUID pattern for diagrams READMEs.** v10 reused the v4 pattern from `progress.schema.yaml` for the diagrams README schemas. Diagrams READMEs are the most likely surface to be hand-edited or imported, and rejecting valid non-v4 UUIDs would surface as a confusing validation failure. v11 relaxes the pattern to accept valid UUID versions v1–v8 for diagrams READMEs only — while still checking the UUID variant nibble. The strict v4 pattern stays in place for state schemas where the values are always machine-generated.
- **Implicit "multiple partials" count.** v10 enumerated `.partial` and `.partial.tmp` recovery cases separately and said "multiple partials → STOP" without pinning what "multiple" means across the two suffixes. v11 makes it explicit: STOP if `(count of v*.partial) + (count of v*.partial.tmp) > 1`, regardless of K — checked before the per-shape branches.
- **Unspecified `## Batch <N>` heading regex.** v10 said "files without batch headers are treated as `## Batch 1`" without pinning the parser. v11 pins `^## Batch (\d+)\b`, locks heading level to `##` (level-2), and clarifies "highest match wins" for N+1 derivation.
- **Implicit `execution-mode` re-prompt.** v10's Item 1 Step 2 wrote `execution-mode=$mode` without specifying when `$mode` is prompted vs reused. v11 makes the rule explicit: prompt only when `active.execution-mode == "none"`, otherwise reuse the persisted value (a prior partial run already chose).
- **Treating the post-probe `check-current==2` recovery loop as a bug.** v10's Item 1 routed partial-state cases to `/mi-update-blueprint` and noted the recovery would stop with a diagnostic, but didn't acknowledge that on retry the *same* path repeats with the *same* diagnostic until the inspector intervenes. v11 calls this out as intentional behavior (the alternative — auto-`--force-regen` — is what F2 closes) and requires the Resume Handler to surface the diagnostic so the loop's non-self-resolving nature is visible to the inspector.
- **Ambiguity about `progress.sh reset` behavior on the new fields.** v10 said `reset` doesn't *need* to write `drift-check-completed` / `history-baseline-version`. v11 strengthens this: `reset` *must not* preserve them across abort recovery, because doing so would let a stale baseline incorrectly mark the next cycle's drift as already done.
- **Dispatcher row ordering left implicit in Item 5.** v10 specified Rows A/B without pinning where they sit relative to existing rows. v11 documents the full active=null block ordering: existing `[x] TODO` row → existing queue-rationale-missing row → draft queue-rationale confirmation row → Row A → Row B → existing `/mi-resume-workflow` fallback. Putting Rows A/B before the catch-all is what makes them fire; putting them after the manual-action rows preserves inspector intent.
- **Item 4 stage-7 dispatcher row position left implicit.** v11 (initial draft) added the row but didn't pin it inside `mi-continue.md`'s active-cases table. The row now sits between `6 + reviewing` and the `any other → /mi-resume-workflow` catch-all so a stage-7 active state (advance-to landed but auto-invoke interrupted) re-runs the finalizer; Branch II in Item 6 makes the re-invocation idempotent.
- **Item 5 row 3 implicitly assumed Step 2B already handled the draft case.** Today's Step 2B is gated on "queue-rationale.md missing" only. v11 now says explicitly that Step 2B is *extended*, not reused: condition (a) writes a fresh file (current behavior); condition (b) targeted-edits the existing file's latest batch and updates top-level `features:`/`batch:`/`status`. Both share prompt / reorder / auto-apply-impact logic; they diverge only at the file-write step.
- **Item 9 migration helper silent on invalid `id` values.** v11 (initial draft) covered missing/stale `requirements-id` and missing `id`, plus the "don't rewrite valid non-v4 `id`" guard. The "id present but invalid" case was implicit (Step 4 would refuse to write). v11 now states it explicitly: if the existing `id` is present but doesn't match the permissive UUID pattern, surface the path and skip. Auto-rewriting could clobber a deliberately-chosen external reference key.
- **Treating requirements/config/diagrams as complete in every context.** That is correct at stage 2, before `primer.md` exists, but wrong for stage-3+ recovery and completion. v11 now gives `check-current` a `--require-primer` mode and requires it for `/mi-update-blueprint`, the Stage-4 drift probe, and `/mi-complete-workflow` before completion rotation.
- **Draft queue-rationale confirmation leaving top-level `features:` stale.** Row A depends on `features - completed == queue`; if a draft confirmation accepts a custom order but only edits the body/status, Row A can miss between-feature auto-fire. v11 now requires draft Step 2B to update top-level `features:`, `batch:`, and `status:` consistently before `progress.sh reorder`.
- **Unknown-baseline recovery marking every recovered rotation as drift complete.** The old pseudo-flow's comment intended spec-update only, but the write was unconditional. v11 now preserves the recovered rotation kind; only recovered `spec-update` sets `drift-check-completed=true`. Manual/non-drift recovery captures a fresh baseline and continues to the normal drift prompt.
- **Step 2A appending a batch without publishing draft frontmatter.** The dispatcher row for draft confirmation reads top-level `status`, so appending only the body would either fall through or auto-fire Row A with an unconfirmed proposal. v11 now requires Step 2A to set `batch: N+1`, `status: draft`, and cumulative `features:` in the same write as the new batch section.
- **Lazy-baseline recovery passing arbitrary `recovered_kind` to `/mi-update-blueprint`.** Item 1's unknown-baseline path sourced `recovered_kind` from the partial's `reason.md.kind`, which can be any of the five values in `reason.schema.yaml`. `/mi-update-blueprint` per Item 11 only accepts `manual` and `spec-update`; passing `completion` / `re-spec-cascade` / `re-plan-cascade` would fail at argument parsing. v11 adds an explicit allowlist guard: completion partials route to `/mi-complete-workflow`'s Branch 0a (Item 6); cascade partials route to `/mi-review`; only manual/spec-update partials proceed via `/mi-update-blueprint`.
- **Approve Handler only checked path existence before stage 3.** The new `blueprints.sh check-current` helper closed partial-regeneration detection everywhere except the stage-2 approve gate that advances into `/mi-plan-implementation`. v11 now updates `commands/mi-continue.md` Approve Step 1 to require default-mode `check-current == 0`; `1` routes back to `/mi-apply-impact`, and `2` stops for repair or an explicit re-run before stage 3 can launch.
- **Adopted-ordering entry for Item 9 didn't reflect v11's expanded scope.** v11's Item 9 now ships the default-mode Approve Handler gate, `--require-primer` mode, the migration helper, and the runbook updates in addition to the `check-current` exit codes / hook update. The ordering entry's parenthetical now lists the full Item 9 scope so a reader scanning the ordering section sees the complete contract.
- **`queue-rationale.schema.yaml`'s single-batch `features` description.** Today's schema description says `features` "MUST exactly match `progress.md.queue` after the matching `progress.sh reorder` call." That invariant is wrong post-Item-7 (multi-batch makes `features` cumulative; the dispatcher's invariant is `features - completed == queue`). v11 now requires the schema description to be rewritten to the multi-batch contract so future readers (and any doctor check that consumes the description) match the dispatcher's actual reads.
- **Item 8 left as a one-line placeholder.** v10 and v11 (initial) both said "Lower priority. Body-completeness heuristic for quest files; `blueprints.sh check-current` for blueprint files" without committing to scope. v11 now explicitly defers Item 8 to v12+ with a written rationale (no F-failure to anchor it; stage-1 surface untouched in this round; pattern established by Item 9 for v12 to follow). This prevents the placeholder from sitting unresolved when implementation reaches that item.
- **Stale "v10 entry" wording in the back-compat guard.** Item 1's back-compat-guard paragraph referred to "the first v10 entry with an unknown baseline" — confusing in a v11 file where v10 is the prior-round snapshot, not the active version. v11 now uses "the first entry with an unknown baseline" (drops the version qualifier).
- **Dense single-sentence `--require-primer` empty-vs-partial wording.** v11 (initial) collapsed two distinct rules into one comma-separated sentence. v11 now splits them: classification for requirements/config/diagrams is unchanged in `--require-primer` mode; primer being missing/invalid promotes `0` → `2` only, not `1` → `2`.

## Round-by-round trail

- **Round 1** → `tmp/progress-gap.md`.
- **Round 2** → `tmp/progress-gap-v3.md`.
- **Round 3 snapshot** → `tmp/progress-gap-v4.md` (identical to v3).
- **Round 4** → `tmp/progress-gap-v5.md`.
- **Round 5** → `tmp/progress-gap-v6.md`.
- **Round 6** → `tmp/progress-gap-v7.md`.
- **Round 7** → `tmp/progress-gap-v8.md`.
- **Round 8** → `tmp/progress-gap-v9.md`.
- **Round 9** → `tmp/progress-gap-v10.md`. Step 0 drift-completion probe + `history-baseline-version` (closes F1 race), unconditional partial-state guard in `/mi-update-blueprint` (closes F2), optional `id` in blueprint README schema + matching runbook updates (closes F3), looser sequence-diagrams rule in `check-current` (closes F4).
- **Round 10 (this file)** → `tmp/progress-gap-v11.md`. Six adopted-with-fixes points from the v10 review: (1) hook-update wording corrected — there is no explicit `diagrams/README.md` skip in `validate-on-write.sh`, so v11 ADDS case branches rather than removing a skip; (2) `scripts/migrate-diagrams-readme.sh` migration helper added to Item 9 so existing projects don't break on legacy READMEs without a current `requirements-id`; (3) `.partial`/`.partial.tmp` cross-product rule made explicit in Item 6 — STOP if combined count > 1, regardless of K; (4) Item 5 dispatcher row ordering pinned (confirmation rows before Rows A/B, Rows A/B before the catch-all); (5) Item 1 partial-state soft-loop diagnostic explicitly called out as intentional behavior with required inspector intervention; (6) Item 1 Step 2 `execution-mode` prompt explicitly idempotent (only prompt when `active.execution-mode == "none"`). Smaller fixes: Item 7's batch-heading regex pinned to `^## Batch (\d+)\b` with explicit "highest match wins" rule, Item 9's UUID pattern relaxed to valid versions v1–v8 for diagrams READMEs only, implementation README schema/runbook wording aligned, Branch 0a's reliance on Step 5's `mv -n` idempotence noted, `progress.sh reset`'s intentional drop of `drift-check-completed`/`history-baseline-version` documented as load-bearing for next-cycle baseline freshness. **In-round refinements** (folded into v11 after self-review passes): Item 4's stage-7 dispatcher row position pinned inside the active-cases table (between `6 + reviewing` and the catch-all), Item 5's Step 2A/2B draft contract made explicit (Step 2A publishes `status: draft`; Step 2B confirms and refreshes features; shared prompt/reorder/auto-apply logic), Item 9's migration helper now explicitly handles the "id present but invalid" case (surface and skip; do not auto-rewrite hand-supplied identifiers), default-mode `check-current == 0` now gates the stage-2 Approve Handler, `check-current --require-primer` added for stage-3+ completeness checks, unknown-baseline recovery now only marks drift complete for recovered `spec-update` rotations, lazy-baseline recovery now restricts `recovered_kind` to `{manual, spec-update}` and routes other kinds to their owning commands, the `Adopted ordering` entry for Item 9 now reflects v11's expanded scope, `queue-rationale.schema.yaml`'s `features` description is required to be rewritten to the multi-batch contract, Item 8 explicitly deferred to v12+ with a written rationale (rather than leaving the one-line placeholder unresolved), and two small wording polishes in Item 1's back-compat guard and Item 9's `--require-primer` empty-vs-partial classification.
