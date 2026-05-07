---
status: draft
audience: implementer
related:
  - docs/workflow-spec.md
  - docs/context optimization/recommendations.md
  - docs/context optimization/implementation-report.md
---

# Clear-points between mo-workflow stages

## 1. Problem

The existing context-optimization work (see `docs/context optimization/`) attacked the dominant cost driver — sticky source-code reads accumulating in main across stages and review iterations — by moving reads into fresh sub-agents that return ~1k-token summaries. That work is largely shipped.

What it does **not** address is the *conversational* residue that lives in the main agent's context across stages: clarifying Q&A while the overseer reviews `summary.md`, blueprint pushback at stage 2, ad-hoc "what about X?" exchanges during stage 5 findings canonicalization, and so on. None of this lives in any persisted artifact — it lives only in the main agent's running context, and it propagates from one stage to the next until the workflow finishes.

For an 8-stage feature this conversational tax compounds. The proposal here is to introduce a small number of **clear-points** — explicit handoff gates where the overseer is asked to `/clear` the main session, and the next stage rehydrates from the persisted `.md` files.

## 2. What's already in place (anchors for this plan)

These are the load-bearing facts the plan depends on. Verify these before implementing.

- `progress.md` is the single source of truth. The `active` block carries `current-stage`, `sub-flow`, `base-commit`, `planning-mode`, `review-mode`, `execution-mode`, `implementation-completed`, `overseer-review-completed`, `drift-check-completed`, `history-baseline-version`, and the worktree fingerprint (`worktree-path`, `git-common-dir`, `git-worktree-dir`). See `docs/workflow-spec.md` lines 549–559.
- `/mo-continue` is the universal advancement signal. Its dispatcher reads `progress.md.active` and routes to the right handler. Clear-points are integrated *here*, not in individual stage commands.
- `/mo-resume-workflow` is the read-only diagnostic dispatcher. It already prints the recommended next command from `progress.md` state — exactly the rehydration shape we need.
- Per-cycle quest files: `todo-list.md`, `summary.md`, `progress.md`, `queue-rationale.md` under `quest/<active-slug>/`.
- Per-feature workflow-stream files: `blueprints/current/{requirements.md, config.md, primer.md, diagrams/}` and `implementation/{overseer-review.md, review-context.md, change-summary.md, grounding-report.md, diagrams/}`.
- The sub-agent return contract (`docs/sub-agent-return-contract.md`) enforces a ~1k-token Result/Artifacts/Commits/Findings/Main-should-read shape. This is what makes rehydration cheap — every stage's outputs are already designed to be read back compactly.

## 3. Recommendation

Introduce **three** clear-points: two during a feature's run plus one at the feature→feature boundary when the cycle has more features queued. Don't go beyond these — additional per-stage clear-points have diminishing returns and compounding cache-bust costs (see Risks §6).

### 3.1 Primary (P0): between stage 2 and stage 3

**Where:** in `/mo-continue`'s **Approve Handler** (the stage-2 branch — see `commands/mo-continue.md` § "Approve Handler (current-stage = 2)"), after blueprint validation succeeds and *before* it auto-fires `/mo-plan-implementation`.

**Why this gate is the highest-value one:**
- Blueprint Q&A is typically the longest conversational stretch in a cycle. The overseer pushes back on requirements, asks the millwright to revise `requirements.md` or `config.md`, debates seam choices. All of that lives only in main context.
- Stage 3 (implementation) is the most expensive stage and the longest running. Starting it with a clean prefix matters most here — every subsequent turn pays the bloat cost otherwise.
- The handoff to stage 3 is already a hard boundary architecturally: `mo-plan-implementation` captures `base-commit`, writes `primer.md`, and (in `brainstorming` mode) hands off to an isolated chain. The chain doesn't share main context anyway, so clearing main right before is essentially free for the chain.

**Proposed flow:**

```
[Overseer]   Marks blueprint files reviewed, types: /mo-continue
[Millwright] Approve Handler: validates blueprint files.
             Writes any pending overseer decisions into decisions.md (see §4).
             Prints:

               Blueprint approved. Recommended: type /clear, then /mo-continue
               to enter stage 3 with a fresh context. State persisted in:
                 - workflow-stream/[feature]/blueprints/current/
                 - workflow-stream/[feature]/decisions.md
                 - progress.md (active block)
               Skip the clear if you have unsaved verbal context you want to
               carry forward.

[Overseer]   Types: /clear
[Overseer]   Types: /mo-continue
[Millwright] /mo-continue dispatcher reads progress.md.active. Sees
             current-stage=2 with `clear-recommendations` already
             containing `stage-2-to-3` (new field — see §5). Re-enters
             the Approve Handler, which reads the rehydration set
             (§5.3) and auto-fires /mo-plan-implementation as before.
             /mo-plan-implementation's Step 3.5 then writes primer.md,
             folding any decisions.md entries into the primer's context
             (see §9.3 — this is now a hard prerequisite, not an open
             question, because primer.md does NOT exist at clear time).
```

The clear is **overseer-triggered**, not automatic. Claude Code does not let the agent invoke `/clear` programmatically; the millwright's job is to *recommend* the clear at the right moment and make rehydration cheap on the other side.

### 3.2 Primary (P0): between feature A and feature B (feature boundary)

**Where:** in `commands/mo-complete-workflow.md`'s housekeeping step (currently auto-fires `mo-apply-impact` when the queue is non-empty). Halt before the auto-fire and recommend `/clear`.

**Why this is arguably the strongest of the three gates:**
- After stage 8, *nothing* in main is reusable for feature B. Feature A's blueprint, code reads, implementation Q&A, review findings, and manual-test discussion all become dead weight.
- The mechanical boundary is the cleanest possible: feature A's `blueprints/current/` and `implementation/` have already been rotated into `blueprints/history/v[N+1]/`, `progress.md.active` is `null`, and feature B's `workflow-stream/[feature-B]/` doesn't exist yet — `mo-apply-impact` will create it fresh after the clear.
- `decisions.md` is feature-scoped, so there's no cross-feature decision-loss risk: feature A's decisions sit at `workflow-stream/[feature-A]/decisions.md` (preserved at the feature root permanently — *not* rotated; see §9.2 resolution), and feature B starts with no decisions file at all.

**Proposed flow:**

```
[Millwright] /mo-complete-workflow steps 1–5 finish (todos updated, commits
             populated, current/ rotated, implementation/ archived,
             progress.sh finish run — active is now null).
             Step 6 housekeeping: queue non-empty.
             Final write to feature-A's decisions.md (last chance before
             main context is cleared — the file itself stays at
             workflow-stream/[A]/decisions.md permanently per §9.2).
             Then prints:

               Feature [A] complete. Queue continues with [B].
               Recommended: type /clear, then /mo-continue to start [B]
               with a fresh context. Nothing from [A] is needed for [B] —
               its blueprint history is at workflow-stream/[A]/blueprints/
               history/v[N+1]/ and its decisions log persists at
               workflow-stream/[A]/decisions.md (feature-scoped, never
               archived). Skip the clear if you want to carry verbal
               context across (rare).

             HALTS — does not auto-fire mo-apply-impact.

[Overseer]   Types: /clear
[Overseer]   Types: /mo-continue
[Millwright] /mo-continue dispatcher reads progress.md: active is null,
             queue non-empty → recognizes the standard "between features"
             state and auto-fires mo-apply-impact for queue[0].
             mo-apply-impact reads progress.md, summary.md (B's section),
             todo-list.md, config.md, runs delegated grounding, writes
             feature-B's blueprints/current/.
```

**No persistence flag needed for this gate.** Unlike `stage-2-to-3` and `stage-5-to-6`, the post-clear state (`active=null`, queue non-empty) only happens *once* per feature transition — `mo-apply-impact` immediately repopulates `active`. So the dispatcher cannot accidentally re-prompt the clear. Simpler to implement than `stage-2-to-3`.

**When this gate does NOT fire:** if the queue is empty after stage 8 (cycle drained), `/mo-complete-workflow` runs `quest.sh end` and recommends `/mo-run`. No clear is suggested — the overseer typically starts a fresh terminal/session anyway, and there's no immediate "next thing" that benefits from a clean prefix.

### 3.3 Secondary (P1): before stage 6 review loop

**Where:** at the very top of `/mo-review`, **before any state mutation** — specifically before Step 2 (which advances `current-stage` 5→6 and sets `sub-flow=reviewing`) and Step 2.5 (which generates `review-context.md`).

The mode prompt at Step 2.6 is *too late* to gate. Halting there leaves the workflow in `current-stage=6, sub-flow=reviewing, review-mode=none`, and a post-clear `/mo-continue` would route to the **Review-Resume Handler** (which expects a completed session), not back into `/mo-review`'s mode prompt.

**Re-entry on the post-clear side is via `/mo-review` again, not `/mo-continue`.** Because the gate halts before any state advance, the workflow is still at `current-stage=5, sub-flow=none` after the clear. The recommendation copy must say "type `/clear`, then `/mo-review`" — not "`/mo-continue`."

On re-entry, `/mo-review` checks `clear-recommendations` for `stage-5-to-6`; if present, it skips the gate and proceeds to Step 2 normally.

**Why:**
- Review loops are iterative, and even with the per-iteration sub-agents from the context-optimization work, the *outer* loop driver (canonicalization at stage 5, findings dispatch at stage 6 entry) accumulates Q&A in main.
- Stage 6 in `direct` mode keeps the review loop in main — exactly the case where prefix bloat hurts most.

**Lower priority than 3.1 / 3.2** because:
- Stage 6 already has the per-iteration sub-agent isolation that absorbs most of the read cost.
- A feature often runs stages 1–6 in one session; clearing three times in one session burns more cache budget than the savings justify.

Ship 3.1 and 3.2 first, measure, then decide on 3.3.

### 3.4 Where NOT to add clear-points

- **After stage 1 / stage 1.5:** the journal+queue conversation is small and useful context for stage 2 generation. Not worth clearing.
- **After every stage:** cache-bust cost dominates savings (see §6.1). The architectural principle should be "rare, well-chosen gates," not "blanket reset."
- **Mid-stage 3:** the brainstorming chain is already isolated. Don't fragment it.
- **At stage 4 / 7:** short auto-advance stages, nothing to clear.
- **At stage 8 when the queue is empty:** see §3.2 — the `stage-8-to-2` gate fires only when the queue has more features. A drained cycle ends with `/mo-run` recommendation; the overseer typically starts a fresh terminal anyway.

## 4. Prerequisite: decisions.md

This is the **load-bearing prerequisite**. Without it, clear-points silently drop overseer intent.

### 4.1 Why it's needed

Today, ad-hoc decisions made during Q&A live implicitly in main context and propagate "for free" into later stages. With clear-points, anything not persisted to a file is *lost*. We need a canonical place to capture conversational outcomes.

Examples of what currently lives only in main and would be lost without `decisions.md`:
- Overseer said "for this feature, treat X as out of scope even though `summary.md` mentions it."
- Overseer chose a specific seam for a goal because of an unstated migration constraint.
- Overseer accepted a reduced-scope `requirements.md` because the full version was too big — but the full version is what the document looks like today, and the *reason* for the trim is verbal.
- Overseer flagged a known-flaky test that the implementation should avoid touching.

### 4.2 Schema

One file per feature, at `workflow-stream/[feature]/decisions.md`. Append-only across stages.

```markdown
---
id: {{UUID}}
feature: {{feature-slug}}
---

# Decisions

Verbal decisions, scope adjustments, and constraints captured during
overseer ↔ millwright Q&A that aren't reflected in requirements.md,
config.md, or other canonical artifacts.

## Stage 2 — Blueprint approval

- **2026-05-07** — Treat `legacy-auth` module as out-of-scope for this
  cycle even though `summary.md` cross-references it. Reason: pending
  migration owned by another team.
- **2026-05-07** — Goal "G3 — refresh token rotation" lands in
  `services/auth/refresh.ts` not the auth-middleware as originally
  scoped. Reason: middleware is on the deprecation path.

## Stage 5 — Findings canonicalization

- ...
```

### 4.3 Write discipline

The millwright must *prompt itself* to write to `decisions.md` at the natural points:

- Before announcing the recommended `/clear` at the §3.1 gate.
- Before announcing the recommended `/clear` at the §3.2 gate.
- Inside `/mo-continue`'s Approve Handler at stage 2, when the overseer's last few turns added clarifications.

A simple rule of thumb to encode in command markdowns: **if the last N turns contain instructions, scope decisions, or constraints that are not captured verbatim in `requirements.md` / `config.md` / `overseer-review.md`, summarize them as bullets into `decisions.md` before suggesting `/clear`.**

### 4.4 Read consumers

`decisions.md` is a feature-scoped log read by every spec-synthesizing operation in the workflow. Single source of decisions, multiple consumers — important to keep this list current as the workflow evolves:

- **`/mo-plan-implementation` Step 3.5** — folds entries into the generated `primer.md`'s `## Decisions` section so the brainstorming chain (and `direct` mode) inherits them. See §9.3, §10 step 4.
- **`/mo-review` Step 2.5** — folds entries into the generated `review-context.md`'s `## Decisions` section so the per-iteration review sub-agents (which read `review-context.md` as their primary context source) inherit them. See §5.2 mo-review section, §10 step 4b. **Required prerequisite for the `stage-5-to-6` gate to deliver value** — without it, the gate cleans main's context but starves sub-agents of the same decisions.
- **`/mo-update-blueprint` (any regeneration trigger)** — folds scope/constraint entries into the regenerated `requirements.md` Non-goals and `config.md` Overseer Additions. Applies to drift (`spec-update`), `completion`-flavored regenerations, and manual invocations. See §9.5, §10 step 4a.
- **Future spec-synthesizing additions** must follow the same pattern: when regenerating spec-shaped artifacts, consult `decisions.md` and fold its constraints in before persisting the new artifact.

What does NOT read `decisions.md`:

- The dispatcher's post-clear rehydration set (decisions flow through downstream synthesizers, not directly into main — see §5.3 explicit note).
- Review sub-agents reading `review-context.md` directly (they get decisions through the Step 2.5 fold-in, not by reading `decisions.md` themselves).
- The clear-point gate handlers themselves (they only verify the file was *written* to before printing the recommendation; they don't synthesize anything from it).

`decisions.md` is **never modified** by any of these consumers — they read, fold derivative content into other artifacts, and leave the source log alone. The log persists at `workflow-stream/<feature>/decisions.md` for the feature's lifetime (per §9.2, no rotation).

This is a behavioral rule, not a tooling one. It should be tested in dry runs (§7).

## 5. Implementation approach

### 5.1 New schema field on `progress.md.active`

Add one optional field:

- **`clear-recommendations`** — YAML array of within-feature stage-transition identifiers the millwright has *already suggested* a clear for in this cycle's *active feature*. Identifiers are kebab-case strings: `stage-2-to-3`, `stage-5-to-6`. Example values: `[]`, `[stage-2-to-3]`, `[stage-2-to-3, stage-5-to-6]`. Missing/absent means "no clears recommended yet." Optional.

**Why an array (not a string):** strings like `"2->3"` are shell-pathological (`2->` parses as stderr-redirect-to-file in bash) and require careful quoting on every use. Kebab identifiers in a YAML array are safe in shells without quoting and round-trip cleanly through `progress.sh`'s `yaml.safe_load`.

**`progress.sh` interface:** `progress.sh set <field>=<value>` writes full values atomically — there is no append. Implementation needs a small new helper to do the read/append/dedupe:

```bash
# New subcommand:
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh add-clear-recommendation stage-2-to-3
# Internally: read current array, append if not already present, write full array back
# via the same set pipeline (validate → temp file → schema validate → atomic rename).
```

A reader-side helper for the gate check:

```bash
# Returns 0 if the identifier is present, 1 otherwise. No-op on missing/null field.
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh has-clear-recommendation stage-2-to-3
```

Both helpers go through the worktree-fingerprint guard, same as `progress.sh set`.

This prevents the millwright from re-prompting `/clear` if the overseer already cleared and re-entered the gate command mid-feature. The flag is the *only* signal — see §6.5 for why we cannot distinguish "skipped the clear" from "took the clear" via this field alone.

**`stage-8-to-2` (feature boundary) does NOT use this field** — see §3.2. The post-clear state (`active=null`, queue non-empty) only occurs once per feature transition by construction, so re-prompting is impossible. Telemetry for `stage-8-to-2` writes directly to `context-ledger.md` without a persistent flag.

This is one optional field; no migration concerns for in-flight workflows. Older cycles without the field are treated as having `clear-recommendations: []` — `has-clear-recommendation` returns "absent" and the gate commands MAY offer the clear once on the next gate-relevant invocation, exactly like a fresh feature. Missing means "no clear has been offered yet," not "skip the gate."

### 5.2 Changes to existing commands

**`commands/mo-continue.md` — Approve Handler (`current-stage = 2` branch):**
1. After blueprint validation passes (the existing `blueprints.sh check-current` step) and before auto-firing `/mo-plan-implementation`:
   1. Run the `decisions.md` write-check (§4.3).
   2. Check `progress.sh has-clear-recommendation stage-2-to-3`:
      - **Not yet recommended (exit 1):** Print the clear recommendation block. Run `progress.sh add-clear-recommendation stage-2-to-3`. Append `clear-offered  stage=stage-2-to-3  feature=<active>` to `context-ledger.md`. **Halt.** Do not auto-fire `/mo-plan-implementation`.
      - **Already recommended (exit 0):** This is either the post-clear re-entry path *or* the overseer typed `/mo-continue` again without clearing. Either way: read the rehydration set (§5.3), append `post-offer-resume stage=stage-2-to-3 feature=<active>` to `context-ledger.md`, then auto-fire `/mo-plan-implementation` as today. We **cannot** distinguish "took the clear" from "skipped the clear" here — see §6.5.

There is no separate "Resume Handler" branch for this gate. The Approve Handler's `has-clear-recommendation` check covers both first-entry (offer) and re-entry (proceed) within a single state-machine branch.

**`commands/mo-complete-workflow.md`:**
1. Step 6 housekeeping (queue non-empty branch): before the auto-invoke of `mo-apply-impact`:
   1. Run a final `decisions.md` write-check on feature A (last chance — main context is about to be cleared; the file itself stays at `workflow-stream/[A]/decisions.md` permanently per §9.2). If new verbal decisions exist in the last N turns, write them.
   2. Print the §3.2 clear recommendation block.
   3. Append `clear-offered  stage=stage-8-to-2  feature=<A>-to-<B>` row to `context-ledger.md`.
   4. **Halt.** Do not auto-fire `mo-apply-impact`.
2. Step 6 housekeeping (queue empty branch): unchanged — call `quest.sh end`, recommend `/mo-run`. No clear suggested.

**`commands/mo-continue.md` — dispatcher (post-`stage-8-to-2` re-entry):**
- When the dispatcher sees `active=null` and `queue` non-empty, this is the standard "between features" state — auto-fire `mo-apply-impact` as today. The path is the same whether or not the overseer cleared in between; no new branch needed. Append `post-offer-resume stage=stage-8-to-2 feature=<A>-to-<B>` to `context-ledger.md` so analytics can pair offer↔continue events. **Do not** label this "clear-taken" — see §6.5.

**`commands/mo-review.md` — gate placement (P1, ship after telemetry on §3.1/§3.2):**
1. **At the very top of the command, before Step 2 (state mutation):** check `progress.sh has-clear-recommendation stage-5-to-6`.
   - **Not yet recommended:** run the `decisions.md` write-check, run `progress.sh add-clear-recommendation stage-5-to-6`, append a `clear-offered` row to `context-ledger.md` (per §5.4), print the recommendation block (the copy must say "type `/clear`, then `/mo-review`" — re-entry is via `/mo-review`, NOT `/mo-continue`, because the workflow is still at `current-stage=5, sub-flow=none` — see §3.3), then **halt**. Do NOT advance the stage. Do NOT set `sub-flow=reviewing`. Do NOT generate `review-context.md`.
   - **Already recommended:** append a `post-offer-resume` row to `context-ledger.md` (per §5.4), then proceed to Step 2 (existing flow, unchanged) — *with the Step 2.5 update below*.
2. **Step 2.5 update** — `review-context.md` generation must include a `## Decisions` section folded from `decisions.md`. The per-iteration review sub-agents read `review-context.md` as their primary context source — not main's pre-clear conversation, which is exactly what the gate just discarded. Without this fold-in, decisions captured pre-gate would be invisible to the sub-agents, defeating the gate's purpose for the review loop.

   Concrete change: after the existing Step 2.5 sections (`## Active scope`, `## Goals (this cycle)`, `## Implemented surface`, `## Open findings (snapshot)`, `## Manual test results`), append a `## Decisions` section by reading `workflow-stream/<feature>/decisions.md` (if exists) and emitting its bullet entries verbatim. If the file is absent or empty, omit the section entirely. Add the `## Decisions` slot to `templates/review-context.md.tmpl`. **Hard prerequisite for `stage-5-to-6` to deliver value** (without it, the gate would clean main's context but starve sub-agents of the same decisions).

This Step 2.5 update is independently useful — even without `stage-5-to-6` shipping, a stage-5 overseer who jots a decision into `decisions.md` (without typing `/clear`) would benefit from it propagating to the review sub-agents. Consider shipping the Step 2.5 fold-in *before* the gate itself.

Gate placement is critical: steps 2 and 2.5 of the existing `/mo-review` mutate state (`current-stage` 5→6, `sub-flow=reviewing`, `review-context.md` written). Halting after them would route a post-clear `/mo-continue` to the **Review-Resume Handler**, which expects a completed session — wrong handler. The gate must precede all mutations.

### 5.3 Rehydration set (post-clear reads)

Goal: keep the rehydration cost predictable and bounded. After `/clear` and before any further work, the millwright reads the gate-appropriate subset of:

| File | Used for | Approx tokens |
|---|---|---|
| `progress.md` (active block only) | Stage state, fingerprint, base-commit, mode flags. **All gates.** | <500 |
| `quest/<active-slug>/queue-rationale.md` | Why this feature is current. **`stage-2-to-3` only** (irrelevant after stage 3). | ~500 |
| `quest/<active-slug>/summary.md` (active feature section only) | Cross-cutting + feature-scoped digest. **`stage-2-to-3` and `stage-5-to-6`** (`stage-8-to-2` reads its own variant — see below). | 1–3k |
| `workflow-stream/[feature]/blueprints/current/requirements.md` | Goals/Planned/Non-goals. **`stage-2-to-3` and `stage-5-to-6`.** | 2–6k |
| `workflow-stream/[feature]/blueprints/current/config.md` | Branch, skills, overseer additions. **`stage-2-to-3` and `stage-5-to-6`.** | 1–3k |
| `workflow-stream/[feature]/blueprints/current/primer.md` | Curated stage-3 entry context. **`stage-5-to-6` only** — primer.md does NOT exist at `stage-2-to-3` clear time (it is written by `mo-plan-implementation` Step 3.5 *after* the post-clear re-entry). | 1–4k |
| `review.sh list-open-summaries <feature>` excerpt | Open IR-IDs + one-line summaries — gives main enough finding context to chat with the overseer pre-`/mo-review`. **`stage-5-to-6` only.** Helper-derived excerpt, NOT the full `overseer-review.md` (which `/mo-review` itself reads canonically). Matches the existing main-read budget for stage 6 (per `commands/mo-review.md` line 9). | <500 |

**`decisions.md` is intentionally NOT in this rehydration set.** It is *never* read by main during rehydration — for every gate, it flows through a downstream synthesizer instead (see §9.3 + §9.5 + §4.4): `mo-plan-implementation` Step 3.5 reads it when generating `primer.md` for `stage-2-to-3`; `/mo-review` Step 2.5 reads it when generating `review-context.md` for `stage-5-to-6`; `/mo-update-blueprint` reads it on regeneration. The dispatcher's job is to fire the next command, not to pre-process its inputs.

Total rehydration: **~6–18k tokens** per `stage-2-to-3` or `stage-5-to-6` clear-point. This is the budget. If it grows past 25k, something has gone wrong (likely a bloated `requirements.md` — re-evaluate).

`primer.md` is the right rehydration anchor for stage 3; it was designed for exactly this purpose by the existing context-optimization work.

**For the `stage-8-to-2` clear-point, the rehydration set is lighter and different:**

| File | Why | Approx tokens |
|---|---|---|
| `progress.md` (queue + completed[]) | Active is null; need queue[0] = next feature | <500 |
| `quest/<active-slug>/summary.md` (next feature's section) | Cross-cutting + B's section | 1–3k |
| `quest/<active-slug>/todo-list.md` (PENDING items for next feature) | Drives requirements | <1k |

Total: **~2–5k tokens**. Feature B's `blueprints/current/` does not yet exist — `mo-apply-impact` creates it after the clear and reads what it needs *as part of its normal stage-2 work*. Don't pre-read those files during rehydration; that's `mo-apply-impact`'s job.

Feature A's archived files (`blueprints/history/v[N+1]/`) and feature A's `decisions.md` (which stays at `workflow-stream/[A]/decisions.md`, not rotated — see §9.2) are NOT part of the post-`stage-8-to-2` rehydration. They belong to feature A; feature B shouldn't see them unless it explicitly cross-references.

### 5.4 Telemetry

Append rows to `context-ledger.md` via the existing `scripts/ledger.sh append` interface. The ledger has a fixed six-column Markdown table — `Stage | Command | Files / inputs | Class | Location | Artifact produced` — and `ledger.sh append` only accepts those positional args. Clear-point events must encode into that schema; no new columns, no timestamp/elapsed fields (those would require extending the template + helper, which is out of scope for this plan).

Each gate writes up to three rows. Example for `stage-2-to-3` on feature `auth-jwt`:

| Stage | Command | Files / inputs | Class | Location | Artifact produced |
| --- | --- | --- | --- | --- | --- |
| 2 | `/mo-continue` | `clear-offer-recommendation` | small | main | `stage-2-to-3` clear offered |
| 2 | `/mo-continue` | `post-offer-resume` | small | main | Approve Handler resumed |
| 2 | `/mo-continue` | `progress.md, summary.md, requirements.md, config.md` | medium | main | `stage-2-to-3` rehydration |

For `stage-8-to-2` on transition `auth-jwt → refresh-token`:

| Stage | Command | Files / inputs | Class | Location | Artifact produced |
| --- | --- | --- | --- | --- | --- |
| 8 | `/mo-complete-workflow` | `clear-offer-recommendation` | small | main | `stage-8-to-2` clear offered |
| 2 | `/mo-continue` | `post-offer-resume` | small | main | `mo-apply-impact` auto-fired |
| 2 | `/mo-continue` | `progress.md, summary.md (B), todo-list.md` | small | main | `stage-8-to-2` rehydration |

For `stage-5-to-6` (when shipped):

| Stage | Command | Files / inputs | Class | Location | Artifact produced |
| --- | --- | --- | --- | --- | --- |
| 5 | `/mo-review` | `clear-offer-recommendation` | small | main | `stage-5-to-6` clear offered |
| 5 | `/mo-review` | `post-offer-resume` | small | main | `/mo-review` Step 2 entered |
| 6 | `/mo-review` | `progress.md, summary.md, requirements.md, config.md, primer.md, review.sh list-open-summaries excerpt` | medium | main | `stage-5-to-6` rehydration |

The rehydration row's `Files / inputs` matches the §5.3 table — the **excerpt** from `review.sh list-open-summaries` is what main reads, not `overseer-review.md` itself (`/mo-review` reads the canonical file as part of its own Step 1).

Field discipline:

- **`Files / inputs`** carries the event semantics. The literals `clear-offer-recommendation` and `post-offer-resume` are sentinel strings — they have no path on disk; they're the canonical labels for the offer event and the resume event respectively. Rehydration rows list the actual file set read from disk.
- **`Class`** for offer/resume rows is always `small` (no real read happened — main printed copy or routed to the next handler). For rehydration rows, use the standard buckets: `small` (<2k), `medium` (2k–20k), `large` (>20k).
- **`Location`** is `main` for all clear-point events. The rehydration is by definition into main's context, and the offer/resume events happen there too.
- **`Artifact produced`** carries the gate identifier (`stage-2-to-3` / `stage-5-to-6` / `stage-8-to-2`) plus a one-word event tag. This is the field analytics will group by.

**No `clear-taken` event.** We cannot reliably distinguish "overseer cleared and re-entered" from "overseer skipped the clear and re-entered" — both produce the same persisted state (the `clear-recommendations` array contains the identifier in both cases). Recording a fake `clear-taken` event would be misleading.

**No timestamp/elapsed columns.** The ledger doesn't have them today; row order is implicit chronology. If "wall time between offer and resume" turns out to be a useful metric, add it later via a small helper that diffs row positions or reads file mtimes — out of scope for this plan.

What we record, working within the existing schema:
- **clear-offered** — gate fired and the recommendation was printed (Files/inputs: `clear-offer-recommendation`).
- **post-offer-resume** — the next gate-relevant command ran after the offer (Files/inputs: `post-offer-resume`).
- **rehydration** — files main re-read after the clear (Files/inputs: actual file list; Class reflects total size).

What this lets us answer at 30 days: did the gate fire as expected, did each offer pair with a resume, and what was the rehydration cost class. Precise clear-taken rates require session-level signals (cache misses, prompt-token deltas) which are out of band for this plan and not directly observable from the ledger.

## 6. Risks and disadvantages

### 6.1 Cache-bust cost (the biggest hidden tax)

`/clear` discards the prompt-cache prefix. The next stage pays *uncached* input rate on the system prompt + rehydration reads. This is fine if stages run minutes apart (cache TTL is 5 minutes anyway), but punishing if the overseer is doing the whole cycle in one sitting and the cache would otherwise have stayed warm.

- **Mitigation:** keep clear-points sparse — three across an entire feature's run plus one at the feature boundary is still well within "rare gates," not a "blanket reset." Don't clear after every stage.
- **Mitigation:** the rehydration set is small (§5.3), so the uncached cost is bounded.
- **Residual risk:** for a fast cycle done in 20 minutes, the cache savings from *not clearing* may exceed the bloat savings from clearing. We won't know without §5.4 telemetry.

### 6.2 Lost decisions if `decisions.md` discipline slips

If the millwright forgets to write a verbal decision into `decisions.md` before recommending `/clear`, that decision is gone. Stage 3 then proceeds with an outdated `requirements.md` plus no awareness of the constraint. Worst case: incorrect implementation, blamed on the spec.

- **Mitigation:** `decisions.md` write-check is a *required* step in the Approve Handler at the gate (and in `/mo-review`'s gate-entry block for `stage-5-to-6`, and in `mo-complete-workflow`'s queue-non-empty branch for `stage-8-to-2`). Refuse to print the clear recommendation until the millwright has at least *opened* `decisions.md` and confirmed last-N turns are reflected (or explicitly marked "no new decisions").
- **Residual risk:** the check is behavioral, not enforced. Could skip silently. Overseer should be told in the recommendation message what was captured (so they can spot omissions before clearing).

### 6.3 Re-reading code on the other side of the clear

The user flagged this. Mostly addressed by the existing work — stage 3, stage 4, stage 6 already delegate code-reading to fresh sub-agents that produce ~1k summaries. Cases where this is still a concern:

- **Stage 3 `direct` mode:** millwright implements in main. After a `stage-2-to-3` clear, if the overseer asks "show me the existing X before you implement," that's a new code read. But it's a *targeted* read that would have happened anyway — pre-clear vs post-clear changes nothing about its cost.
- **Stage 5 canonicalization:** if the overseer triggers `stage-5-to-6` clear and then the millwright needs to verify a finding against source, that read happens fresh. Probably small (single-file lookups), not a regression vs. today.

Net: this is a smaller risk than it first appears. The architectural shift to delegated reads (already shipped) makes clear-points safer than they would have been a year ago.

### 6.4 UX friction

- Overseer has to type two commands (`/clear` then `/mo-continue`) instead of one.
- The millwright "reintroduces itself" briefly post-clear — a small jarring effect.
- Overseer may forget what was just discussed; relies on `decisions.md` to remember.

Acceptable, but should be measured. If overseers consistently skip the recommended clear, the value isn't there.

### 6.5 Workflow re-entry edge cases

The `clear-recommendations` field needs care:

- **`/mo-abort-workflow` must reset it** — same way it resets `drift-check-completed` and `history-baseline-version`. Otherwise an aborted-and-restarted feature won't be offered the clear again.
- **Worktree fingerprint guard** (`mo_assert_worktree_match`) interacts with `clear-recommendations` writes — the new `progress.sh add-clear-recommendation` helper must go through the same guard, otherwise a sibling worktree could write the field. Should be free since the helper goes through the same `set` pipeline.
- **Skip-clear vs after-clear are indistinguishable in persisted state.** When the gate fires, it sets `clear-recommendations += stage-2-to-3` and halts. Whether the overseer then types `/clear` followed by `/mo-continue` (took the clear) or just `/mo-continue` (skipped the clear), the persisted state is identical on re-entry: `clear-recommendations` already contains the identifier. The Approve Handler proceeds to auto-fire `mo-plan-implementation` either way. This is *fine functionally* — the workflow advances correctly in both cases — but it means telemetry cannot honestly record `clear-taken` (see §5.4). Don't try to fake the signal.
- **What if overseer clears mid-Q&A inside stage 2 (before approving)?** Today they *can* do that and the workflow recovers via `/mo-resume-workflow`. After this change, that pathway must still work — meaning rehydration logic must be robust to "no clear was suggested but one happened anyway." The Resume Handler already handles this; just verify.
- **`decisions.md` is excluded from history rotation by design** — see §9.2. It lives at `workflow-stream/[feature]/decisions.md` (root) and stays there permanently as a feature-scoped log. The earlier worry about "rotation leaving decisions.md behind / feature B overwriting it" was based on a flawed framing: feature B's `decisions.md` is at `workflow-stream/[feature-B]/decisions.md`, an entirely different path, so there is no overwrite risk. No rotation logic change is required.
- **`stage-8-to-2` race between halt and re-entry:** `mo-complete-workflow` halts after `progress.sh finish` (active=null). If the overseer types `/mo-continue` *without* clearing, the dispatcher proceeds normally to fire `mo-apply-impact`. There's no failure path here — clearing is purely opt-in. Confirm in dry-run #5.
- **`stage-5-to-6` re-entry path is `/mo-review` (preferred), but `/mo-continue` also works.** Because the gate halts before any state advance (workflow stays at `current-stage=5, sub-flow=none`), the overseer has two viable paths post-clear:
  - **`/mo-review` (recommended in the recommendation copy):** direct re-entry. The gate's `has-clear-recommendation stage-5-to-6` check returns "already recommended" (the flag was set just before the halt), so the gate skips and `/mo-review` proceeds straight to Step 2. No re-print.
  - **`/mo-continue`:** routes through the Overseer Handler, which canonicalizes any new findings and *then* auto-fires `/mo-review`. The flag is still set, so `/mo-review` skips the gate the same way — no re-print, but the canonicalization detour adds work the direct path skips. Equivalent end state, just a longer route.

  Recommendation copy says "type `/clear`, then `/mo-review`" because the direct path is faster and more deterministic; `/mo-continue` is a valid fallback if the overseer mistypes or has uncanonicalized findings to process anyway.

### 6.6 Diminishing returns vs. existing optimizations

The honest framing: the heavy lifting is already done by sub-agent isolation. Clear-points address a residual (conversational Q&A) that is real but smaller than the source-read problem the team already solved. Expect modest savings, not transformative ones. If telemetry after rollout shows <5% reduction in main-context token usage per cycle, consider this a useful hygiene feature rather than a major optimization, and don't pursue further clear-point gates beyond §3.1 and §3.2.

### 6.7 Schema migration

One new optional field (`clear-recommendations`, YAML array of identifier strings) on `active`. Backwards-compatible: missing/empty = no clears suggested yet. No migration script needed. In-flight workflows unaffected.

## 7. Acceptance criteria & validation plan

Before declaring this shipped:

1. **Unit:** `progress.sh add-clear-recommendation stage-2-to-3` round-trips correctly through the worktree-fingerprint guard; subsequent `has-clear-recommendation stage-2-to-3` returns 0; adding the same identifier twice is a no-op (deduped). `progress.sh advance` does not clobber the field.
2. **Unit:** `/mo-abort-workflow` resets `clear-recommendations` to `[]`.
3. **Dry-run #1 — primary gate:** run a real feature through stages 1 → 2, approve blueprint, verify the clear recommendation prints, verify `decisions.md` was written (or marked empty), `/clear`, `/mo-continue`, verify stage 3 starts cleanly *and* `/mo-plan-implementation`'s primer.md generation reads `decisions.md` (see §9.3). Compare main-context token usage in stage 3 first turn vs. a control cycle without the clear-point.
4. **Dry-run #2 — decisions discipline (`primer.md` fold-in):** during stage 2 Q&A, deliberately give a verbal scope decision ("treat X as out-of-scope"). Verify it lands in `decisions.md` before the clear recommendation. Verify post-clear `/mo-plan-implementation` folds the decision into `primer.md`'s context (e.g., the decision shows up in primer's "## Active scope" or a new "## Decisions" section).
4a. **Dry-run #2b — decisions discipline (`review-context.md` fold-in, P0, runs WITHOUT the `stage-5-to-6` gate):** at stage 5 (no clear gate involved), write a decision into `workflow-stream/<feature>/decisions.md` (e.g., "skip touching legacy module Y when addressing findings"). Run `/mo-review`. Verify Step 2.5's generated `review-context.md` contains a `## Decisions` section with the entry verbatim. Then trigger one brainstorming iteration and verify the per-iteration sub-agent's prompt (the inline-composed Step 3a.2.4 prompt) includes the decision through `review-context.md`. **This dry-run validates step 4b independently of the §3.3 gate** — required because step 4b is shipped P0 with the primary batch (per §10 step 11) regardless of whether `stage-5-to-6` ever ships.
5. **Dry-run #3 — overseer skips the clear:** overseer types `/mo-continue` *without* clearing. Workflow proceeds normally. `clear-recommendations` records the offer regardless. **Note:** this dry-run only verifies the workflow-progression path is correct; it cannot verify "skipped" vs "took" via state inspection (see §6.5 — they are indistinguishable). The telemetry rows (`clear-offered` then `post-offer-resume`) are written in both cases.
6. **Dry-run #4 — abort-restart:** abort an active cycle that had `clear-recommendations: [stage-2-to-3]`. Restart. Verify the field is reset to `[]` and the gate fires again.
7. **Dry-run #5 — feature boundary (`stage-8-to-2`):** run a cycle with two queued features. Complete feature A; verify the recommendation prints, feature A's `decisions.md` stays at `workflow-stream/[feature-A]/decisions.md` (verify presence at root and absence from `blueprints/history/v[N+1]/` — see §9.2), feature A's `blueprints/current/*` and `implementation/*` are correctly rotated into `blueprints/history/v[N+1]/`, and the workflow halts before auto-firing `mo-apply-impact`. Type `/clear`, `/mo-continue`; verify `mo-apply-impact` runs cleanly for feature B, feature B's stage-2 reads are not polluted by feature A's main context, and feature B's fresh `workflow-stream/[feature-B]/` does NOT contain a stray `decisions.md` (it should only appear when the first feature-B decision is written). Compare main-context token usage at feature B's stage-3 first turn vs. a control cycle without the `stage-8-to-2` gate.
8. **Dry-run #6 — review-loop gate placement (when shipping §3.3):** start `/mo-review` at stage 5 with open findings. Verify the gate fires *before* `current-stage` advances 5→6 and *before* `sub-flow=reviewing` is set (inspect `progress.md` mid-halt — both fields should still show stage-5 / no sub-flow). `/clear`, `/mo-review` (NOT `/mo-continue`), verify Step 2 advances and Step 2.6 prompts the mode question.
9. **Telemetry sanity check:** after 5 real cycles using the gates, inspect `context-ledger.md`:
    - **Pairing check (row order, not wall time):** every `clear-offered` row should be followed by a `post-offer-resume` row with the same `Artifact produced` gate identifier. Any unpaired `clear-offered` (followed by no resume) means the gate stranded the workflow — investigate. Wall-time between offer and resume is **not measurable** from the current ledger schema (no timestamp column — see §5.4); if that metric becomes important, add a `Timestamp` column to the ledger template + helper as a follow-up.
    - **Rehydration class targets:** `stage-2-to-3` rehydration rows should be `medium`; `stage-8-to-2` rows typically `small`. Outliers indicate a bloated `requirements.md` or other rehydration regression.
    - **Qualitative read** on whether overseers feel friction (informal — log subjective notes alongside the cycle). Without an in-band measurement of post-clear context, this is the only direct signal on whether overseers are actually taking the clear.

If pairing is healthy and rehydration class is on target but qualitative feedback reports overseers consistently skipping the clear, the recommendation copy or friction is the issue — iterate before adding §3.3 (or before shipping it if already in progress). The ledger alone can't prove the clear actually cleaned main-context occupancy; treat the gates' effectiveness as inferred from cycle-cost trends + overseer feedback rather than confirmed per-cycle.

## 8. Out of scope (for this plan)

- Automatic clearing without overseer typing `/clear`. Not possible in the current Claude Code surface — agents can't invoke `/clear` programmatically.
- Clear-points inside stages (e.g., mid-implementation). The chain's isolated session model already handles this for stage 3; nothing to add.
- Replacing existing sub-agent delegations with clear-points. These are complementary, not alternatives. The shipped sub-agent work attacks read-bloat; clear-points attack Q&A-bloat. Both should stay.
- Generalizing this to a "checkpoint" system with named restore points. Adds complexity for no clear gain over the simple §5.1 field.

## 9. Open questions

1. **Should the `stage-2-to-3` recommendation be silenceable per cycle?** If an overseer prefers to never clear, the prompt is friction. Possible: a `progress.md.active.skip-clear-recommendations: true` field, set via `/mo-continue --no-clear-prompts` or similar. Defer until friction is observed.
2. ~~Should `decisions.md` rotate into `blueprints/history/v[N+1]/` at completion?~~ **Resolved: NO, do not rotate.** `decisions.md` is a feature-scoped, version-independent log: facts like "treat X as out-of-scope" are properties of the feature, not of a specific blueprint version, and they should accumulate across blueprint regenerations. It lives at `workflow-stream/<feature>/decisions.md` (root) for the feature's lifetime and stays there permanently after stage 8 — `workflow-stream/<feature>/` itself is preserved as the parent of `blueprints/history/v[N]/...`, so decisions.md naturally persists alongside that history without being archived into any single version. **Today's rotation logic in `mo-complete-workflow` requires no change** — it only touches `blueprints/current/` and `implementation/`, both of which are inside the feature folder; `decisions.md` at the root is invisible to it. Cross-feature isolation is automatic (feature B's decisions.md lives at `workflow-stream/<feature-B>/decisions.md`, fully separate from feature A's). The earlier framing of "feature A's verbal decisions are lost when feature B starts" was wrong — they're not lost; they sit unread at feature A's root, where they belong as a permanent feature-scoped record.
3. ~~Does the brainstorming chain need to be told about `decisions.md`?~~ **Resolved: yes, mandatory. `mo-plan-implementation` Step 3.5 must read `decisions.md` and fold relevant entries into `primer.md` when generating it.** This is now a **hard prerequisite for `stage-2-to-3`**, not a nice-to-have, because `primer.md` does not yet exist at clear time (it is *written* by Step 3.5 *after* the post-clear re-entry). Therefore: (i) `decisions.md` cannot be in the rehydration set (the millwright cannot read it pre-primer because the dispatcher's job is to fire `/mo-plan-implementation`, not pre-process its inputs); (ii) `primer.md`'s template needs a `## Decisions` section that Step 3.5 populates from `decisions.md` if any entries exist. The brainstorming chain (and `direct` mode) reads `primer.md` as its required first read and inherits the decisions through that channel. Option (a) from the original framing is the chosen approach.
4. **Should the secondary `stage-5-to-6` gate be combined with a `/mo-review` flag (`--clear` / `--no-clear`) instead of always recommending?** Stage 6 has more variance in cycle length than stage 2→3. A flag-driven gate may be more honest than a default recommendation.
5. ~~Should `/mo-update-blueprint` read `decisions.md` when regenerating the blueprint?~~ **Resolved: yes, mandatory** — same architectural reason as §9.3 (`mo-plan-implementation` folding decisions into `primer.md`). Any synthesizing operation that regenerates spec/config from codebase + diff must consult the feature-scoped decisions log, otherwise verbal scope decisions and constraints made during stage 2 Q&A or stage 3 implementation get silently dropped at regeneration time. Applies to **all** `/mo-update-blueprint` triggers — `spec-update` (the drift path after stage 3), any future `completion`-flavored regeneration, and manual overseer invocations. Concretely: after reading the post-state codebase + diff + previous blueprint, also read `workflow-stream/<feature>/decisions.md` (if it exists) and fold scope/constraint entries into the regenerated `requirements.md`'s Non-goals section and `config.md`'s Overseer Additions section as appropriate. `decisions.md` itself is **untouched** by the regeneration — it persists at the feature root permanently per §9.2 and accumulates across blueprint versions. The blueprint inherits its content; the log itself is owned by the overseer's running history.

## 10. Implementation order

1. **Schema field** `clear-recommendations: []` on `progress.md.active`, plus `progress.sh add-clear-recommendation <id>` and `progress.sh has-clear-recommendation <id>` helpers (both go through the worktree-fingerprint guard via the existing `set` pipeline). (~1 hour — schema + two small helpers, more than the original "30 min" estimate because the helpers are net-new subcommands, not just a `set` of a string.)
2. `decisions.md` template at `templates/decisions.md.tmpl` + write-check helper (a behavioral rule encoded in command markdowns; not a new script). (~1 hour)
2a. **`decisions.md` schema + validate-on-write integration.** Add `schemas/decisions.schema.yaml` validating the frontmatter (`id`, `feature`) and at least one `## Stage <N> — <label>` section. Map `*/workflow-stream/*/decisions.md` in `hooks/validate-on-write.sh` so writes go through the same schema gate as `requirements.md`, `config.md`, etc. Update `docs/workflow-spec.md`'s schema/template inventory to list `decisions.md`. **Without this, the file is structurally unguarded** — any malformed write (e.g., a millwright that fumbles the frontmatter or section headings) lands silently, and downstream consumers (primer fold-in, review-context fold-in, blueprint regeneration) get garbage. (~1 hour)
3. ~~Rotation logic update~~ **Not needed.** `decisions.md` is excluded from history rotation by design (§9.2) — it stays at `workflow-stream/<feature>/decisions.md` permanently as a feature-scoped log. The existing rotation logic in `mo-complete-workflow` (which only moves `blueprints/current/*` and `implementation/*`) is correct as-is.
4. **`mo-plan-implementation` Step 3.5 update**: read `decisions.md` (if exists) and fold entries into `primer.md`'s `## Decisions` section. Add the `## Decisions` section to `templates/primer.md.tmpl`. **Hard prerequisite for `stage-2-to-3`** (see §9.3). (~1 hour)
4a. **`/mo-update-blueprint` regeneration update**: when regenerating `blueprints/current/`, also read `workflow-stream/<feature>/decisions.md` (if exists) and fold scope/constraint entries into the regenerated `requirements.md` (Non-goals) and `config.md` (Overseer Additions). **Critical ordering for `config.md`:** the existing command runs `blueprints.sh preserve-overseer-sections` *after* writing the new config to restore the prior `## Overseer Additions` from history. A naive decisions fold-in placed before `preserve-overseer-sections` would be overwritten. Two viable approaches: (a) place the decisions fold-in *after* `preserve-overseer-sections` runs, so it merges into whatever the preserve step restored; or (b) update `preserve-overseer-sections` to take an additional input source for decision-derived additions and merge them with the preserved content in one pass. Approach (a) is the simpler retrofit and the recommended path. `decisions.md` itself stays at the feature root, unmodified (per §9.2). Applies to all regeneration triggers — drift (`spec-update`), `completion`, manual. **Important for spec-decision durability across blueprint versions** (see §9.5). Not strictly load-bearing for clear-points themselves to function, but pairs naturally with the work; ship together if scheduling allows. (~1.5 hours including the preserve-step ordering work)
4b. **`/mo-review` Step 2.5 update — ship as P0 alongside steps 4 and 4a, NOT deferred to §3.3.** When generating `review-context.md`, append a `## Decisions` section folded from `workflow-stream/<feature>/decisions.md` (if exists). Add the slot to `templates/review-context.md.tmpl`. This is independently useful as a quality fix the moment `decisions.md` exists: a stage-5 overseer who jots a decision into `decisions.md` (without ever typing `/clear`) immediately benefits from it propagating to per-iteration review sub-agents that read `review-context.md`. The fold-in is also a **hard prerequisite for `stage-5-to-6` to ever deliver value** when that gate eventually ships — without it, the gate would clean main's context but starve sub-agents of the same decisions. Decoupling: shipping 4b in the P0 batch is unconditional; the §3.3 gate decision (ship/defer/skip) does not change whether 4b ships. (~1 hour)
5. `commands/mo-continue.md` **Approve Handler** — `stage-2-to-3` gate (offer+halt path, post-offer re-entry path; both branches in the same handler — see §5.2). (~2 hours, mostly prompt-engineering the recommendation copy.)
6. **`commands/mo-complete-workflow.md`** — `stage-8-to-2` halt + recommendation in queue-non-empty housekeeping. No persistence flag needed (re-entry is impossible by construction; see §3.2). (~1 hour)
7. `context-ledger.md` row writers for `clear-offered`, `post-offer-resume`, and `rehydration` events (per §5.4 — *not* a `clear-taken` event). (~30 min)
8. `mo-abort-workflow` reset of `clear-recommendations` to `[]`. (~15 min)
9. Dry-runs #1–#5 above. (~2.5 hours)
10. Ship `stage-2-to-3`, `stage-8-to-2`, **and step 4b's `review-context.md` decisions fold-in** together as P0. (Step 4a's `/mo-update-blueprint` integration ships in the same batch if scheduling allows; otherwise it can land as a fast follow.) Wait 1–2 weeks.
11. Inspect telemetry — `context-ledger.md` (offer↔resume row pairing, rehydration class) plus qualitative overseer feedback. Decide on §3.3 secondary gate (`stage-5-to-6`).
12. If shipping §3.3: add the gate at the **top of `commands/mo-review.md`, before Step 2 (state mutation)** (see §3.3, §5.2 mo-review section, §6.5 last bullet). Step 4b's review-context fold-in is already in place from the P0 batch — the gate just plugs into it. Run dry-run #6. (~2 hours, smaller than originally estimated because 4b is no longer part of this step's work.)

Total for primary + boundary gates plus 4b's fold-in: roughly a day-and-a-half of focused work plus dry-run time. Secondary gate is ~2 hours after telemetry confirms value (4b is already in place).
