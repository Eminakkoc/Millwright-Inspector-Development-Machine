# Review of `docs/manual-testing/plan.md`

This file holds two independent reviews of the design plan:

- **Pass 1 (against revision 17, below)** — the original review that produced 5 major + 7 moderate + 8 minor findings.
- **Pass 2 (against revision 18, after all pass-1 fixes were applied)** — second deep read looking for issues introduced by the rev-18 edits, plus anything the first pass missed. Pass-2 findings are at the bottom.

Reading order: skim pass 1 to understand what changed in revision 18, then read pass 2 for what's still open.

---

# Pass 1 — Review of revision 17

**Reviewer:** Claude (Opus 4.7).
**Scope:** end-to-end read of the 1,424-line design plan plus cross-reference verification against the live codebase (`scripts/progress.sh`, `scripts/review.sh`, `commands/*`, `templates/*`, `schemas/*`).
**Verdict at a glance:** the plan is internally coherent and well-grounded — most cross-references verify against the current code, the seed-id idempotency design is sound, and the dispatch order through the helper is self-consistent. The findings below are *fix-suggestions* rather than *don't-merge-as-is* blockers; one UX duplication and one stage-5 hand-off contradiction are worth correcting before implementation begins, the rest are spec-tightening.

Findings are grouped by severity. Each finding cites a line range from `plan.md` and proposes a concrete fix.

---

## Blockers (fix before implementation starts)

None of the findings rise to a strict blocker — the design is implementable as written. The two highest-severity items below are tagged **major** because each will produce a noticeably worse end-product (UX duplication or doc contradiction) if left unfixed, but they don't gate the design itself.

---

## Major

### M1. Duplicate "generate manual test plan?" prompt between `mo-continue` step 7 and `mo-manual-test-plan` step 1

**Where:** § 3.1.1 (lines 644–662) defines the stage-5 hand-off prompt, which on `y` auto-fires `/mo-manual-test-plan`. § 2.1 step 1 (lines 335–337) re-prompts the overseer with the *same* y/n question.

**Impact:** the overseer who answers `y` to the first prompt is immediately asked again. They might answer `n` the second time by accident (or out of fatigue) and skip the manual-test phase they just opted into. UX bug.

**Why both prompts exist today:** § 2.1 also supports manual invocation (overseer types `/mo-manual-test-plan` mid-cycle without being routed via `mo-continue`); for that case the prompt is needed.

**Suggested fix:** add a `--from-resume` (or `--no-prompt`) flag to `/mo-manual-test-plan`. `mo-continue` step 7 passes the flag on auto-fire, suppressing the redundant prompt. Direct invocation by the overseer (no flag) keeps the prompt. Document the flag in § 2.1's "Manual invocability" paragraph (line 354) and reference it from § 3.1.1's "On `y`" branch.

---

### M2. Stage-5 hand-off message contradicts § 3.1.4 on canonicalization

**Where:** § 2.2 step 4 final message (line 466):

> "Manual test done. Review `overseer-review.md` (auto-seeded failures appear at the bottom; **canonicalization runs on `/mo-continue`**), add any subjective findings, and type `/mo-continue` when done."

But § 3.1.4 (lines 698–700) explicitly states:

> "Seeded failures are already-canonical `### IR-NNN` blocks via `review.sh upsert-manual-test-failure`. The handler's existing canonicalization step has nothing to do with seeded blocks — they're canonical from the moment `upsert-manual-test-failure` writes them. Canonicalization only handles overseer-authored free-form review text."

**Impact:** the message implies the auto-seeded blocks are not yet canonical and might be reformatted on `/mo-continue` — readers/implementers will write tests that exercise that reformatting, only to find the spec elsewhere says it does nothing. Minor at runtime (the canonicalize pass is a no-op on already-canonical blocks), but the contradicting prose is a maintenance trap.

**Suggested fix:** rewrite the hand-off line to:

> "Manual test done. Review `overseer-review.md` (auto-seeded failures appear at the bottom as canonical `### IR-NNN` blocks; any free-form findings you author will be canonicalized on `/mo-continue` per the existing pass), add any subjective findings, and type `/mo-continue` when done."

---

### M3. Branch B finalization "valid exit" list is incomplete for `policy=none` first-time outcomes

**Where:** § 2.2 Branch B finalization, lines 591–596 enumerate "valid exit" cases:

- Auto-seed loop ran to completion.
- No-failures no-op.
- `manual→auto-seed` flip-and-seed (overseer answered `y`).
- `manual` decline (`n`) to flip-prompt.
- `auto-seed` re-seed completed, no diff produced.

**Missing case:** Branch B entered with `policy=none` AND `failed > 0`. The policy table at line 498 says: "If `failed > 0`: prompt the overseer (auto-seed prompt as in step 4)." That prompt has three answers (`y` / `y --classify` / `n`), each producing a valid done-state. None of those answers are explicitly listed as a "valid exit" — the closest is "Auto-seed loop ran to completion," which arguably covers the `y` and `y --classify` cases but not `n` (where no loop runs and policy is set to `manual`).

**Impact:** an implementer reading the list literally might leave Branch B without finalizing in the `policy=none → answered n → no loop ran` shape, leaving `(sub-flow=manual-testing, manual-test-state=running)` on disk and looping the next `/mo-continue` back into the same handler — exactly the bug rev-9 finding #1 fixed for `policy=manual`.

**Suggested fix:** rewrite the "valid exit" list to be answer-driven rather than entry-state-driven:

```
"Valid exit" — finalize whenever the overseer answered the auto-seed/flip prompt
(or the no-failures no-op fired):
  - From any policy entry state, the overseer answered `y` or `y --classify` and the
    auto-seed loop ran to its end (regardless of how many scenarios actually got seeded;
    skipped/refused per-scenario outcomes still finalize the run).
  - From any policy entry state, the overseer answered `n` to the prompt (no writes happen,
    but the workflow is genuinely done).
  - No-failures no-op (nothing to seed).
  - `auto-seed` re-seed completed (idempotent, may produce zero diff).
```

This also removes a separate problem: the current list reads as if the per-policy entry shape matters for "valid exit" classification, when really only the overseer's answer matters.

---

### M4. Multiple-verdict-block recovery: implementation choice left to the implementer

**Where:** § 3.7.5 test (line 1070):

> "Add a malformed-history sibling where duplicate A.1 verdict blocks exist: implementation must either keep the latest block and rewrite a single canonical A.1 block, or refuse with a diagnostic naming the duplicate; it must not silently count both."

**Impact:** the two options produce *very* different UX. "Keep latest + rewrite" is silent self-healing; "refuse with diagnostic" forces overseer intervention. The test allows either, but downstream consumers (Overseer Handler summary, review-context citation) read the result body and need to know which shape they'll see. A spec that allows both invites silent divergence between implementations.

**Suggested fix:** pick one and pin it in § 2.2 step 3.4 (verdict commit unit). Recommendation: **"keep the latest block; emit a one-line stderr warning naming the duplicate; do not refuse"** — the runner already owns parsing-by-scenario-id, so silent self-healing matches the rest of the file's idempotency story. Adding a refuse path here means the overseer has to hand-edit a markdown file mid-run, which is hostile.

---

### M5. `--reclassify` propagation against open base IR has no gating test

**Where:** § 2.2 "Classification override propagation" (lines 512–513) requires the runner to pass `--reclassify` for open-base default updates when `reclassify_existing=true`. The runner test at lines 1073–1076 covers reclassify propagation for closed-base secondary calls and orphan-family seed-into-family, but **not** for open-base default updates.

**Impact:** without a gating test, an implementer could miss the open-base path. The user-visible failure: overseer runs `/mo-manual-test-run --seed-only --reclassify`, expecting to reclassify scenarios with open-base IRs; the helper preserves the old severity/scope and the overseer's choice is silently discarded.

**Suggested fix:** add a fourth sub-test under the rev-17 propagation block:

> **Open base + `--seed-only --reclassify`:** set up an open base IR with `severity=major scope=fix`. Run `/mo-manual-test-run --seed-only --reclassify`, overseer picks `severity=blocker scope=re-plan`. Assert: helper call includes `--reclassify`; the open base IR's severity/scope are updated to `blocker`/`re-plan`; status remains `open`; details are refreshed.

---

## Moderate

### m1. Verdict-block parsing rules are under-specified

**Where:** § 4.2 (lines 1207–1219) and § 2.2 step 3.4 (lines 437–442) describe verdict-block storage but not parsing.

Open questions the spec doesn't answer:

- Block boundary: is it `### <ID> — ...` until the next `### ` heading? Or until EOF / next `## ` heading? What if the block lacks a leading `### `?
- Field parsing: are bullets case-sensitive (`- **Verdict:**` vs `- **verdict:**`)? Whitespace-tolerant?
- What if a verdict block exists but lacks the `Seeded:` field (legacy / hand-edited)? Treat as `false`? Refuse?
- What is the canonical ordering of bullets within a block? The template shows Verdict / Observation / Recorded at / Seeded / Cited as IR-NNN — is that order enforced?

**Suggested fix:** add a § 4.2.1 "Verdict-block parsing contract" that pins:
- Block boundary: `^### <SCENARIO_ID> — ` to next `^### ` heading or `^## ` heading or EOF (whichever comes first).
- Required bullets in order: Verdict, Observation, Recorded at, Seeded, Cited as IR-NNN. The runner emits them in that order; the parser tolerates any order on read.
- Missing `Seeded:` field on a `fail` verdict reads as `false` (matches default behavior; useful for hand-edits).
- Bullet keys are case-sensitive and whitespace-stripped (`- **Verdict:**` exactly).

---

### m2. Auto-seed loop's observation extraction from results body is not specified

**Where:** § 2.2 step 4 (lines 450–464) describes the auto-seed loop calling `upsert-manual-test-failure` per failed scenario, but doesn't specify how the runner extracts the raw observation text from the per-scenario verdict block to pipe via stdin.

The verdict block stores observation as a markdown bullet:
```
- **Observation:** {{OVERSEER_REPLY}}
```

If the overseer's reply is multi-line, the rendered storage shape isn't specified — block scalar (`|` indent), bullet sub-lines, or escaped single line? The auto-seed loop needs a deterministic shape so the inverse extraction is unambiguous.

**Suggested fix:** specify in § 4.2 that multi-line observations are stored as a YAML-style block scalar under the bullet:

```
- **Observation:** |
    Line 1.
    Line 2.
```

And specify in § 2.2 step 4 that the runner reads the block-scalar body, strips the four-space indent, and pipes to the helper via `printf '%s\n' "$observation"`. This mirrors the helper's own `- details: |` rendering (§ 3.7.1 block format) and keeps the round-trip lossless.

---

### m3. `mo-doctor` check is too narrow

**Where:** § 3.8 (line 1127):

> "Add a check: `templates/manual-test-plan.md.tmpl` and `templates/manual-test-results.md.tmpl` exist. Trivial."

**Impact:** the design also adds two new schemas (`schemas/manual-test-plan.schema.yaml`, `schemas/manual-test-results.schema.yaml`) and depends on `scripts/review.sh` having `find-by-seed-id-family` and `upsert-manual-test-failure` subcommands. None of these are checked by the proposed `mo-doctor` extension.

**Suggested fix:** rewrite § 3.8 to check:
- Templates exist (current scope).
- Schemas exist (`manual-test-plan.schema.yaml`, `manual-test-results.schema.yaml`).
- `review.sh` accepts the new subcommands (`review.sh upsert-manual-test-failure --help` and `review.sh find-by-seed-id-family --help` exit 0).
- `progress.schema.yaml` includes `manual-testing` in the sub-flow enum and has the two new active-block fields.

---

### m4. Closed-base-only-family priority rule has no test

**Where:** § 3.2.1 priority rule (lines 720–724) item 3:

> "else IR with the highest numeric suffix overall (regression or base) regardless of status — preserves traceability to the latest seeded artifact"

The test set at lines 1090–1094 covers:
- Open base, closed `:r1`, open `:r2` → cite `:r2`.
- Closed base, open `:r1`, no `:r2` → cite `:r1`.
- Open base, no regressions → cite the base.
- Closed base, closed `:r1`, closed `:r2` → cite `:r2`.
- No family at all → "no IR" form.

**Missing case:** "Closed base, no regressions." Item 3 says this should cite the closed base (the base is the highest-suffix-overall member, suffix 0). Without a test, an implementer might emit "no IR" instead.

**Suggested fix:** add a sub-test:

> **Closed base, no regressions:** cite the closed base IR with `(status: fixed; no open seeded finding remains)`.

---

### m5. "Overseer Handler does not Edit overseer-review.md when policy=auto-seed" — gating test missing

**Where:** § 1.3 schema description (lines 282–285) says:

> "tests should assert the Overseer Handler does not Edit overseer-review.md when this field is `auto-seed`"

But this assertion is not in the § 3.7.5 test list, nor in § 8 step 3 implementation order.

**Impact:** the single-owner discipline is a load-bearing invariant of the design (revisions 2/3 emphasized it). Without a test, an over-eager implementer who reads § 3.1.4's "summary line" prose and assumes "summary line implies updates" could add a re-canonicalize-and-rewrite step to the Overseer Handler.

**Suggested fix:** add a test under § 3.7.5:

> **Overseer Handler is read-only against `overseer-review.md` when `policy=auto-seed`.** Set up: completed manual-test run with `policy=auto-seed`, two seeded failures in `overseer-review.md`. Capture sha256 of `overseer-review.md`. Type `/mo-continue` (lands in Overseer Handler). Assert: the handler emits the expected summary line; the post-handler sha256 matches the pre-handler sha256 (file was not edited).

---

### m6. `--finalize-skipped` doesn't address "scenarios before current-scenario without verdict blocks"

**Where:** § 2.2 step 5 (line 624):

> "mark every scenario from `current-scenario` onward as `skip` with reason `bulk-skipped`, write each as a verdict in the results body (with `Seeded: false`), then run step 4."

**Edge case:** what if scenarios *before* `current-scenario` lack verdict blocks? This shouldn't happen in normal flow (the runner only advances cursor after committing the verdict — see § 2.2 step 3.4), but it's reachable through:
- A manual edit to `current-scenario` in the frontmatter.
- A legacy results file from before the cursor-after-commit rule landed (rev-17 finding #2).
- A corrupted state where a verdict block was deleted but the cursor advanced past it.

**Suggested fix:** add a defensive clause after the bulk-skip body:

> "Before bulk-skipping, validate that every scenario id ordered before `current-scenario` in the plan has a verdict block. If any are missing, refuse with diagnostic: `--finalize-skipped: scenario <X> has no verdict but cursor is past it. Inspect the results file and fix by hand, or run /mo-manual-test-plan --force to start over.`"

This makes `--finalize-skipped` truly a finalization escape hatch and not a tool that can paper over genuine corruption.

---

### m7. `manual-test-failure-policy=auto-seed` is set AFTER the loop — make the deliberate choice explicit

**Where:** § 2.2 step 4 (lines 453–454):

> "On `y`: enter the auto-seed loop with `scope=fix, severity=major` for every failure. After it completes, set `progress.sh set manual-test-failure-policy=auto-seed` and report seeded/failed counts."

**Why this matters:** if the auto-seed loop crashes mid-iteration (helper non-zero exit aborts the per-scenario seed step per the closed-IR caller pattern), `manual-test-failure-policy` stays `none`. Re-entry via Manual-Test-Resume Handler → `--seed-only` → Branch B with `policy=none` → re-prompt the overseer from scratch.

This is *probably* the right behavior (the overseer can re-confirm), but it's not explicitly justified in the spec. A reader could reasonably argue the policy should be set BEFORE the loop so resume picks up without re-prompting.

**Suggested fix:** add a sentence after the policy-set line explaining the choice:

> "Setting policy *after* the loop is deliberate: a mid-loop crash leaves `policy=none`, and Branch B re-enters the auto-seed prompt on resume — this is preferable to silently committing the overseer to `auto-seed` before they confirmed the prompt actually completed. Idempotency of the per-scenario seeding (via seed-id) means re-running doesn't double-write any IRs."

---

## Minor

### mn1. Reset-block line-number inconsistency

The doc cites `scripts/progress.sh:277-296` in some places (lines 313, 814) and `277-295` in others (line 184). The actual reset block runs lines 277–295 with line 296 being post-block code; the verification confirms 277–295 is the accurate range.

**Fix:** replace all occurrences of `277-296` with `277-295` for consistency. (Functionally harmless either way.)

---

### mn2. § 9 resolved-questions sub-section ordering is scrambled

Sub-sections appear in this order in the doc (lines 1347–1424):

> 9.1 (rev 2) → 9.2 (rev 3) → 9.10 (rev 11) → 9.9 (rev 10) → 9.8 (rev 9) → 9.7 (rev 8) → 9.6 (rev 7) → 9.5 (rev 6) → 9.4 (rev 5) → 9.3 (rev 4)

That's neither ascending-by-section-number nor consistently descending-by-revision. It looks like an unsorted accumulation as new revisions added entries.

**Fix:** pick one ordering and sort. Recommended: ascending by revision (so newest is at the bottom, matching how revisions are ordered chronologically when read top-to-bottom in the rev-history block at the top of the file). Or consistently descending by revision throughout. Either way, the current mixed ordering is just a maintenance quirk to clean up.

---

### mn3. Resolved-questions trail stops at revision 11

Revisions 12–17 don't have their own subsections under § 9. The rev-12 changelog at the top notes "Annotated [resolved entries] inline" rather than adding new resolved-question sections, but this practice was inconsistently applied: rev-13 finding #6 explicitly updates rev-10's resolved entry inline (line 1374 — "Original rev-10 answer ... was superseded by revisions 12/13"), but revs 14, 15, 16, 17 didn't propagate their own resolved questions anywhere.

**Impact:** a reader scanning § 9 for "what's been settled in revisions 12–17" finds nothing.

**Fix (low effort):** either (a) add 9.11 / 9.12 / ... 9.16 sub-sections summarizing the resolved items per revision, or (b) explicitly state in § 9's preamble that "resolved entries from revision 12+ are recorded inline in the rev-history changelog at the top of this file rather than duplicated here." Option (b) is fewer words and matches the actual practice.

---

### mn4. Corrupt-frontmatter test header miscounts sub-tests

§ 3.7.5 test at lines 1101–1108 begins with:

> "Branch A and Branch B pre-normalization refuses on corrupt results-file frontmatter (revision-16 — addressing finding #3). **Three sub-tests** covering the three corruption shapes:"

But the bullets list **six** sub-tests: YAML parse error, missing `state` key, `state: bogus`, missing `current-scenario`, unknown current scenario, complete-state mismatch.

**Fix:** change "Three sub-tests" to "Six sub-tests" (or rewrite as "covering the corruption shapes").

---

### mn5. `y` description on auto-seed prompt is too absolute

Line 451:

> "`y` writes each failed scenario as a canonical `### IR-NNN` block via `review.sh upsert-manual-test-failure` (§ 3.7.1)."

But the family-inspection rules in lines 457–464 (rev-16 finding #1 fix) introduce per-scenario branches where:
- Family empty → write a base IR (matches the prose).
- Orphan family with `skip` choice → no helper call, scenario unseeded.
- Closed base → may end up with `Seeded: false` if overseer picks `skip`.

So "writes each failed scenario" is wrong in two of three branches.

**Fix:** rewrite the line to:

> "`y` runs the per-scenario family-inspection loop (see "Family inspection in first-time auto-seed" below) and seeds each failed scenario via `review.sh upsert-manual-test-failure` per the inspection's branch decision; some scenarios may end up with `Seeded: false` if the overseer picks `skip` at a per-IR prompt."

---

### mn6. `templates/overseer-review.md.tmpl` doesn't yet have `source` / `seed-id` example fields

Verification confirmed the template currently has only `severity / scope / status / details / fix-note` in its structured-block example (lines 24–29). § 8 step 1 (line 1314) lists this as work to do, but it's worth flagging that this *prerequisite* needs to land before any auto-seed work merges, alongside the `FIELD_RE` extension.

**Fix:** none needed in the plan — § 8 already lists this work. But the implementer should verify both changes go in the same change-set as `FIELD_RE`, since canonicalize-corruption is the failure mode if either lands without the other.

---

### mn7. `printf '%s\n'` adds a trailing newline regardless of input

The closed-IR caller pattern (§ 3.7.1, line 896):

```bash
IR_ID="$(printf '%s\n' "$observation" | review.sh upsert-manual-test-failure ...)"
```

This appends `\n` even when `$observation` already ends with one — producing a trailing blank line in the helper's stdin. Not a correctness bug (the helper's `details="$(cat)"` collapses trailing whitespace differently per shell, but the canonical-block writer should normalize). Just noting the asymmetry.

**Fix:** if precise round-trip is needed, the helper should explicitly strip a single trailing newline on read. Otherwise this is fine to leave as-is.

---

### mn8. `mo-abort-workflow.md:81` cited; actual line is 88

Verification turned up that the cited line for `progress.sh reset` invocation is line 88, not line 81 (line 81 in the current file is part of an earlier branch). Inside § 3.4 / § 1.4 the citation is `mo-abort-workflow.md line 81` (line 800 of the plan).

**Fix:** update the citation to line 88. Or, since these citations age fast, replace with a stable description: "the retry-mode `progress.sh reset` invocation in `mo-abort-workflow.md`."

---

## Pass-1 summary table

| # | Severity | One-line fix |
|---|----------|--------------|
| M1 | Major | Add `--from-resume` flag to `/mo-manual-test-plan` so `mo-continue` step-7 doesn't double-prompt. |
| M2 | Major | Rewrite stage-5 hand-off message — auto-seeded blocks are canonical from write; canonicalize only touches free-form text. |
| M3 | Major | Reword Branch B "valid exit" list as answer-driven (overseer picked y/n), not entry-state-driven. |
| M4 | Major | Pin "duplicate verdict block" recovery to `keep-latest + warn`, not implementer's choice. |
| M5 | Major | Add gating test for `--seed-only --reclassify` against an open base IR. |
| m1 | Moderate | Add a § 4.2.1 verdict-block parsing contract (boundary, field order, missing-field defaults). |
| m2 | Moderate | Specify multi-line observation storage shape (YAML block scalar) and the inverse extraction. |
| m3 | Moderate | Expand `mo-doctor` to also check schemas, `review.sh` subcommands, and progress.schema.yaml additions. |
| m4 | Moderate | Add a "Closed base, no regressions" sub-test to the citation-priority test set. |
| m5 | Moderate | Add a gating test asserting Overseer Handler is read-only on `overseer-review.md` when `policy=auto-seed`. |
| m6 | Moderate | Add defensive validation in `--finalize-skipped` for missing-verdict scenarios before the cursor. |
| m7 | Moderate | Add an explicit rationale paragraph for setting `policy=auto-seed` AFTER the loop. |
| mn1 | Minor | Replace `progress.sh:277-296` with `277-295` consistently. |
| mn2 | Minor | Sort § 9 resolved-questions sub-sections by ascending revision. |
| mn3 | Minor | Add a § 9 preamble noting that revs 12+ resolved-questions are recorded inline in the changelog. |
| mn4 | Minor | Fix "Three sub-tests" → "Six sub-tests" in corrupt-frontmatter test. |
| mn5 | Minor | Soften the "`y` writes each failed scenario" line — some scenarios may end up `Seeded: false`. |
| mn6 | Minor | (No change needed; flag for implementer that `FIELD_RE` + template + schema must land together.) |
| mn7 | Minor | (No change needed; note `printf '%s\n'` trailing-newline asymmetry.) |
| mn8 | Minor | Update `mo-abort-workflow.md:81` citation → line 88, or replace with stable description. |

**Bottom line:** the design is implementable as written; M1–M5 are worth fixing before code lands because they will cause user-visible bugs or test gaps. m1–m7 are spec-tightening that will save an implementer time. mn1–mn8 are housekeeping.

---

# Pass 2 — Review of revision 18

**Reviewer:** Claude (Opus 4.7).
**Scope:** end-to-end re-read of the patched plan.md (now 1,512 lines) after all 20 pass-1 fixes were applied as revision 18. Additionally re-checked the previously-flagged sections plus surrounding cross-references for new inconsistencies introduced by the fixes.
**Verdict at a glance:** the rev-18 fixes landed cleanly. All five Major findings are now closed by spec changes plus gating tests. The seven Moderate findings are addressed (one with a small follow-on gap noted below). The eight Minor findings are housekeeping-only and check out.
The pass-2 findings are smaller in scope than pass 1 — most are clarifications around language introduced by the fixes themselves (R5–R7 below), one missing test for a new spec clause (R1), and a couple of long-standing under-specifications that pass 1 didn't catch (R8, R10, R12).

Findings are numbered R1, R2, … to keep them distinct from pass-1's M/m/mn series.

---

## R1. The new `--finalize-skipped` cursor-integrity check (m6) has no gating test

**Where:** § 2.2 step 5 (line 656 in rev 18) added a "Pre-bulk-skip cursor-integrity check" that refuses if any scenario before `current-scenario` lacks a verdict block. The pass-1 m6 finding called for the spec change but didn't ask for a corresponding test, and revision 18 didn't add one.

**Impact:** the check is a defensive refusal path; without a gating test, an implementer can build the rest of `--finalize-skipped` correctly and skip this check entirely without anyone noticing. The other `--finalize-skipped` tests (line 1147 — happy-path, line 1155 — three precondition refusals) don't exercise this case.

**Fix:** add a `--finalize-skipped` cursor-integrity refusal test under § 3.7.5, paralleling the precondition-refusals test:

> **`--finalize-skipped` refuses when scenarios before the cursor lack verdicts (revision 18 — gates m6).** Set up: paused mid-run with `current-scenario=B.1` but **no verdict block for A.2** (manually deleted after the cursor advanced — simulates corruption). Run `/mo-manual-test-run --finalize-skipped`. Assert: refusal with diagnostic naming `A.2`; `progress.md` byte-identical pre/post-call; `manual-test-results.md` byte-identical pre/post-call. Sibling sub-test: A.1 verdict missing (multiple scenarios before cursor without verdicts) — diagnostic names the first such scenario in plan order.

This belongs immediately after the existing `--finalize-skipped` precondition-refusals test.

---

## R2. M3's "valid exit" reword introduces an underspecified term: "fatal" helper refusal

**Where:** § 2.2 Branch B finalization, line 625 (revision 18 — addressing M3):

> "per-scenario refusal (helper non-zero exit on that one scenario, surfaced and continued past). A scenario-level helper refusal that the runner classified as fatal aborts the whole loop and finalizes via the 'Invalid exit' list — that's distinct from per-scenario `skip`."

**Problem:** "the runner classified as fatal" is doing a lot of work, but the runner's classification rule isn't pinned anywhere. The closed-IR caller pattern (§ 3.7.1, lines 925–948) shows a `return 1` on non-zero exit, but its containing function is per-scenario; the loop's behavior on that return value isn't specified. The text introduces a "fatal vs continued" axis without specifying which refusals fall on which side.

**Concrete examples that aren't pinned:**
- Mutual-exclusion refusal (`--reopen` + `--new-finding` both passed) — should never happen if the runner builds args correctly. Probably fatal-class.
- Empty-family `--force-new-regression` refusal — should never happen if the runner gates per the inspection algorithm. Probably fatal-class (runner bug).
- Schema validation failure inside the helper — load-bearing-class. Probably fatal.
- `find-by-seed-id-family` returning an unexpected error — environmental. Could be either.

**Impact:** an implementer builds the loop and gets `return 1` from a per-scenario helper call. Do they `break` out of the loop or `continue` to the next scenario? Without a spec, two implementations diverge.

**Fix:** add a sentence after the M3 text (or in § 3.7.1's caller pattern) specifying:

> "Helper non-zero exit is treated as fatal by default (the runner aborts the loop, leaves markers untouched, and exits non-zero with the helper's stderr surfaced to the overseer). The reasoning: every documented non-zero refusal (mutual exclusion, empty-family `--force-new-regression`, schema problems) indicates a runner bug or environmental failure that re-running won't fix without intervention. The runner does NOT silently `continue` past these — the overseer should see the failure, fix the cause, and re-run. Idempotency via seed-id means partial progress isn't lost."

This pin closes the ambiguity in both directions: the loop aborts; the prior partial seeding survives via seed-id.

---

## R3. M3 reword still uses the awkward phrase "from any policy entry state"

**Where:** § 2.2 Branch B finalization, lines 625–626 (revision 18 — addressing M3):

> "Overseer answered `y` or `y --classify` (**from any policy entry state**): ..."
> "Overseer answered `n` (**from any policy entry state** — including the `policy=none → answered n` first-time decline AND the `policy=manual → declined flip` case): ..."

**Problem:** "from any policy entry state" reads as "regardless of what `policy` was when Branch B started." But "entry state" is also a term that might be confused with the dispatcher's entry guard at the top of § 2.2. Mild ambiguity. Pass 1 wrote this phrase; rev 18 retained it.

**Fix:** swap "from any policy entry state" → "regardless of `manual-test-failure-policy` at Branch B entry." Two-sentence wording change. Improves readability for a future reader without rewriting the structure.

---

## R4. § 4.2.1 cross-reference to "m2 / § 4.2 below" is awkward

**Where:** § 4.2.1 (line 1277, revision 18 — added in m1):

> "- **Observation:** <body, possibly multi-line block scalar — see m2 / § 4.2 below>"

**Problem:** "m2" is a finding number from a review report (`review-of-plan.md`); referencing it inside the design doc requires the reader to have the review file in hand. § 4.2 is the parent section (the multi-line storage description is actually in § 4.2.1 itself, below the bullet list). The "below" pointer is also slightly misleading — it points to a part of § 4.2.1, not § 4.2.

**Fix:** simplify to "see 'Multi-line `Observation:` storage' below." That's a sub-header within § 4.2.1, unambiguous and self-contained.

---

## R5. § 4.2.1 missing-field-default for `Verdict:` says "refuse" but doesn't specify scope

**Where:** § 4.2.1 (line 1285, revision 18 — added in m1):

> "- `Verdict:` missing → refuse with `^warning:` on stderr; do NOT count this scenario; do NOT advance cursor past it. (A verdict block with no verdict is unrecoverable.)"

**Problem:** "refuse" without further detail is ambiguous: does the runner stop the whole loop, skip just this scenario and continue, or abort the entire skill invocation with non-zero exit?

The text says "do NOT count this scenario; do NOT advance cursor past it" — that suggests *skip and continue without advancing*. But that creates a livelock: on resume, the runner re-reads the same malformed block, refuses again, and loops forever.

Compare to the corrupt-frontmatter handling (§ 2.2 Branch A pre-normalization, line 405): "Refuse with diagnostic `... cannot determine resume state. Inspect the file...` Do NOT normalize progress.md." That's a *whole-skill* refusal — exit non-zero, print diagnostic, stop.

**Fix:** rewrite the bullet to:

> "- `Verdict:` missing → refuse the whole runner invocation with non-zero exit; emit diagnostic `verdict block for scenario <X> has no Verdict: field; cannot determine outcome. Inspect manual-test-results.md and either restore the field or rewind current-scenario by hand.` Do NOT count this scenario; do NOT advance cursor; do NOT re-render the verdict block. Resume re-encounters the same malformed block and refuses identically until the overseer fixes it. (Same shape as corrupt-frontmatter handling at § 2.2 Branch A pre-normalization.)"

---

## R6. § 4.2.1 multi-line observation block scalar doesn't pin chomping behavior

**Where:** § 4.2.1 (lines 1291–1301, revision 18 — added in m1):

> "When the overseer's reply is multi-line, store as a YAML-style block scalar:
> ...
> Indent body four spaces. The block scalar runs until the next bullet (`^- ` outdent), the next heading (`^### ` or `^## `), or end-of-block (per the boundary rule). Blank lines inside the block scalar are preserved."

**Problem:** "Blank lines inside the block scalar are preserved" — but what about *trailing* blank lines? In YAML, the chomping indicator (`|`, `|+`, `|-`) decides whether a single, all, or no trailing blank lines are kept. The runner's reader is custom (not a YAML parser), but it still has to make this decision deterministically — otherwise round-trip isn't byte-stable, and the M4 self-healing test (which compares observations across writes) will be flaky.

**Fix:** add one sentence:

> "Trailing blank lines in the body are stripped on read; the runner emits the body without trailing blank lines on write. Leading blank lines (between `|` and the first non-blank line of the body) are stripped on both read and write. Internal blank lines are preserved exactly. Round-trip equivalence: read → write produces a body byte-identical to the input modulo leading/trailing blank-line normalization."

---

## R7. M1 `--from-resume` over-claims compatibility with `--force` / `--new-seed-family`

**Where:** § 2.1 "`--from-resume` flag" paragraph (revision 18):

> "The flag is mutually compatible with `--force` and `--new-seed-family`; passing all three is well-defined (force a re-run from a terminal state without re-prompting and reset the seed family)."

**Problem:** the only auto-fire site for `--from-resume` is § 3.1.1 step 7 (Resume Handler), which never passes `--force`. The Resume Handler reaches step 7 only when entering stage 5 with `manual-test-state=none` (not `complete` or `skipped`). So `--from-resume --force` is never auto-fired; it'd only happen if the overseer types both flags by hand, which is an odd manual recovery path.

**Impact:** the compatibility claim isn't wrong, but it implies a use case the spec doesn't actually support. A future reader might write a "force-from-resume" routine that the rest of the spec doesn't cover.

**Fix:** simplify the paragraph:

> "The flag is mutually compatible with `--force` and `--new-seed-family` if passed together (well-defined: force a re-run from a terminal state without re-prompting). However, `mo-continue`'s Resume Step 7 only auto-fires with `--from-resume` alone — it never passes `--force` because step 7 only fires when `manual-test-state=none`. The combined-flag form is reserved for manual invocation in atypical recovery scenarios."

---

## R8. § 4.2 prose still describes verdict-block parsing inline, now redundant with § 4.2.1

**Where:** § 4.2 (line 1265, last paragraph, predates revision 18):

> "The runner parses verdict blocks by `### <SCENARIO_ID> — ...`, keeps exactly one canonical block per scenario id, renders blocks in plan order, and recomputes counts from those blocks. The `Seeded:` field is parsed by `mo-manual-test-run`'s auto-seed loop via a regex over the scenario's bullet list — keep the format stable."

**Problem:** § 4.2.1 (added in revision 18) is the authoritative parsing contract. The quoted prose in § 4.2 partially duplicates it (block boundary, "one canonical block per scenario id," counts recomputation) and partially handwaves what § 4.2.1 now pins precisely. If a future revision changes one without the other, the spec drifts.

**Fix:** rewrite the § 4.2 paragraph to a one-liner pointing at § 4.2.1:

> "The runner's parsing rules — block boundary, required bullet keys, missing-field defaults, and multi-line `Observation:` storage — are pinned in § 4.2.1 below. Both the verdict-commit unit and the auto-seed loop use that contract."

---

## R9. § 4.2.1 lists "two consumers" of verdict blocks; there are actually three

**Where:** § 4.2.1 (line 1305, revision 18):

> "Two consumers (verdict-commit unit, auto-seed loop) read these blocks; an explicit contract prevents tolerance drift between them."

**Problem:** the Overseer Handler (§ 3.1.4, line 731) also reads verdict blocks — specifically the `Seeded:` field — to compute its summary line: "`seeded_failed` is computed from failed verdict blocks whose `Seeded:` field is `true`."

**Fix:** "Three consumers (verdict-commit unit, auto-seed loop, Overseer Handler summary line) read these blocks; an explicit contract prevents tolerance drift between them."

---

## R10. M5 test asserts "helper call includes `--reclassify`" — which requires instrumentation the spec doesn't define

**Where:** § 3.7.5 added test (revision 18, addressing M5):

> "Assert: the (single) helper call for that scenario includes `--reclassify` (no `--reopen` and no `--new-finding`, since the base is open and the inspection routes to default-mode); the open base IR's `severity` and `scope` are updated to `blocker`/`re-plan`; ..."

**Problem:** "the helper call includes `--reclassify`" is a flag-passing assertion; verifying it requires either (a) instrumenting `review.sh` to log its invocations, or (b) inspecting test-driver shims. The spec doesn't establish which mechanism is used; other tests in § 3.7.5 mostly assert via outcome (severity changed, IR allocated, etc.).

**Impact:** the outcome assertions in this test are sufficient — if `--reclassify` weren't passed, the open base's `severity`/`scope` would be preserved per § 3.7.1's default-update rules. So the explicit "includes `--reclassify`" assertion is redundant and harder to test.

**Fix:** drop the flag-passing assertion; rely on outcomes:

> "Assert: the open base IR's `severity` and `scope` are updated to `blocker`/`re-plan`; `status` remains `open`; `fix-note` is unchanged; `details` are refreshed. The severity/scope update is only possible via `--reclassify`, so a passing test confirms the runner's `reclassify_existing=true` propagation hits the open-base default path."

(Same pattern other tests in § 3.7.5 already use — see e.g. the "preserves `severity` and `scope` across upserts by default" test at line 1052.)

---

## R11. M4 self-healing warning's "duplicate count" is the count of *dropped* blocks, but the test wording is briefly ambiguous

**Where:** § 3.7.5 added test (revision 18, addressing M4):

> "**Sibling sub-test: three duplicates of A.1; assert latest kept, two earlier dropped, warning reports `2`.**"

**Problem:** "three duplicates of A.1" is ambiguous: is that "three blocks total, two of which are duplicates of one canonical" (drop count = 2), or "three duplicates plus one canonical = four blocks" (drop count = 3)? The expected `2` argues for the first reading. Compare to the test's first sub-test: "TWO `### A.1 — fail` blocks, the later one having a different observation" — clear (drop count = 1, warning says `1`). The sibling could be clearer.

**Fix:** rewrite as:

> "**Sibling sub-test: three `### A.1 — fail` blocks (e.g., from two crash-then-retry cycles plus a hand-edit); assert the latest is kept, the two earlier are dropped, the warning reports `2 duplicates dropped for scenario A.1`.**"

---

## R12. § 4.2.1 doesn't say what to do with foreign sub-headings inside a verdict block

**Where:** § 4.2.1 (lines 1303–1305, revision 18):

> "Unknown bullets within a verdict block are preserved in place on rewrite — they're foreign content and the runner has no opinion about them. (Rare; would only happen if the overseer hand-annotated a block.)"

**Problem:** the contract says how to handle unknown *bullets*, but not unknown *sub-headings*. If the overseer adds `#### Notes` inside an A.1 block, what does the runner do on rewrite? Drop it? Preserve it in place? The block-boundary rule (line 1271) ends the block at the next `^### ` or `^## ` heading — `^#### ` (four-hash) doesn't end the block, so it's *inside*. Behavior unspecified.

**Fix:** add to the "Unknown bullets" paragraph:

> "Sub-headings (`#### `, `##### `, etc.) inside a verdict block are also preserved in place — the block boundary rule only stops at three-hash or two-hash headings. Foreign content of any shape (unknown bullets, sub-headings, paragraphs) round-trips unchanged on rewrite."

---

## R13. Test list is now near 50 bullets; consider grouping by concern

**Where:** § 3.7.5 (lines 1043–1161 in revision 18) is now a flat list of ~50 test bullets covering helper-level tests, runner-level tests, helper-output-format tests, end-to-end tests, and review-context tests. This was already long in revision 17; revision 18 added two more (M5 reclassify open-base, m4 closed-base-only-family priority, m5 Overseer Handler read-only — three actually). The flat shape is starting to make the file hard to navigate.

**Impact:** not a correctness issue; an organization issue. An implementer working through the test list has to scan the whole flat list to figure out what they've covered.

**Fix (optional, lower priority than the others above):** add sub-headings grouping by concern. Suggested split:

```
### 3.7.5.1 Helper-level tests (`upsert-manual-test-failure`, `find-by-seed-id*`)
### 3.7.5.2 Runner-level tests (`mo-manual-test-run` Branch B, family inspection)
### 3.7.5.3 End-to-end tests (`--finalize-skipped`, verdict-commit recovery, plan rotation)
### 3.7.5.4 Review-context tests (`mo-review` step 2.5)
### 3.7.5.5 Cross-skill tests (Overseer Handler read-only, corrupt-frontmatter)
```

This is presentation-only; the test bullets themselves don't change.

---

## Pass-2 summary table

| # | Scope | One-line fix |
|---|-------|--------------|
| R1 | Test gap (rev-18 m6) | Add a `--finalize-skipped` cursor-integrity refusal test in § 3.7.5. |
| R2 | Spec gap (rev-18 M3) | Pin "fatal vs. continued" rule for non-zero helper exits — recommend default-fatal. |
| R3 | Wording (rev-18 M3) | "from any policy entry state" → "regardless of `manual-test-failure-policy` at Branch B entry." |
| R4 | Reference (rev-18 m1) | "see m2 / § 4.2 below" → "see 'Multi-line `Observation:` storage' below." |
| R5 | Spec gap (rev-18 m1) | Pin scope of `Verdict:` missing → refuse — whole-skill non-zero, mirroring corrupt-frontmatter. |
| R6 | Spec gap (rev-18 m1) | Pin chomping for the multi-line block scalar (strip leading/trailing, preserve internal). |
| R7 | Wording (rev-18 M1) | Soften the `--from-resume` + `--force` compatibility claim — only manual invocation uses the combined form. |
| R8 | Redundancy (pre-rev-18) | Replace § 4.2's parsing prose with a one-liner pointer to § 4.2.1. |
| R9 | Wording (rev-18 m1) | "Two consumers" → "Three consumers" (Overseer Handler also reads `Seeded:`). |
| R10 | Test wording (rev-18 M5) | Drop "helper call includes `--reclassify`" assertion; rely on outcome assertions. |
| R11 | Test wording (rev-18 M4) | Disambiguate "three duplicates" — three blocks total, two dropped, warning reports `2`. |
| R12 | Spec gap (rev-18 m1) | Specify behavior for foreign sub-headings inside a verdict block — preserve in place. |
| R13 | Organization | Optionally group § 3.7.5's ~50 test bullets under sub-headings (helper / runner / e2e / review-context / cross-skill). |

**Bottom line for pass 2:** the rev-18 fixes were applied cleanly and addressed everything the pass-1 review raised. The pass-2 findings are all in two narrow categories: (a) wording/reference cleanups around the new prose (R3, R4, R7, R9, R10, R11), and (b) follow-on spec gaps that the new prose surfaced but didn't fully close (R1, R2, R5, R6, R12). R8 is a pre-existing redundancy that pass 1 didn't catch but became more visible after § 4.2.1 was added. R13 is organizational and optional.

R1 and R2 are the most worth acting on:
- **R1** because m6 added a refuse path with no gating test, and silent omission of the check is exactly the failure mode m6 was meant to prevent.
- **R2** because the new M3 prose introduced a "fatal vs. continued" axis without specifying which refusals fall on which side; two implementations could diverge.

Everything else is polish.
