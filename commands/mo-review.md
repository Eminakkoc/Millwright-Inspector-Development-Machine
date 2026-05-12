---
description: Launch a brainstorming review session for the active feature. Reads open findings from overseer-review.md and invokes brainstorming with those findings as work definition. The session runs ISOLATED from mo-workflow — same isolation model as stage 3. The overseer types /mo-continue after the session ends to resume the workflow.
---

# mo-review

**Review-loop driver.** Reads `overseer-review.md`, collects all open findings, and runs the review loop in main with one fresh sub-agent per iteration (brainstorming mode, Step 3a) or directly in main with no sub-agent dispatch (direct mode, Step 3b). Each iteration addresses the currently-open findings, asks the overseer for `approve` / `go again` / `abort`, and either exits or loops. Brainstorming mode's sub-agents handle cascade-scoped findings (`re-spec`, `re-plan`) inside their own context — those reads do not accumulate in main.

**Main-read budget (stage 6).** Allowed in main: `review-context.md`, `overseer-review.md` (open IR-IDs only via `review.sh list-open-summaries` excerpt — Phase 6.5). Forbidden in main: source reads for findings — delegated to per-iteration sub-agent in brainstorming mode (Phase 1.3) unless `direct` mode is selected AND all findings are scope=`fix` (Phase 1.2 auto-routing). See `docs/workflow-spec.md` § "Main-read budget gates by stage" for the canonical table.

**`mo-review` does NOT advance past stage 6, and does NOT auto-fire `/mo-complete-workflow`.** After the loop exits via `approve`, the overseer types `/mo-continue` to resume mo-workflow; the post-review-session Review-Resume Handler in `/mo-continue` finalizes (advances 6 → 7 and auto-fires `/mo-complete-workflow`).

There is no AI-driven review pass. Findings are authored by the overseer (during stage 5, and any time during the review loop). `mo-review` is a hand-off mechanism, not a reviewer.

## When invoked

- **Auto-fired** by `/mo-continue`'s Overseer Handler when the overseer types `/mo-continue` after writing findings into `overseer-review.md`.
- **Manually invokable** by the overseer at any point during stage 5 — useful if the overseer wants to start the brainstorming review session before the auto-fire path.

## Preconditions

- `progress.md`'s `active.current-stage` is 5 or 6.
- `overseer-review.md` exists.
- At least one finding in `overseer-review.md` has `status: open`. (If none are open, the workflow auto-completes — see `commands/mo-continue.md` Overseer Step 3a.)

## Execution

### Step 1 — Resolve inputs

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
active_feature="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get-active)"
ov_file="$data_root/workflow-stream/$active_feature/implementation/overseer-review.md"
[[ -f "$ov_file" ]] || { echo "error: overseer-review.md not found at $ov_file" >&2; exit 1; }

open_ids="$($CLAUDE_PLUGIN_ROOT/scripts/review.sh list-open "$active_feature")"
[[ -n "$open_ids" ]] || { echo "no open findings — nothing to review. Type /mo-continue to run the clean-review finalizer (advances to stage 7 and auto-fires /mo-complete-workflow)." >&2; exit 0; }
```

### Step 2 — Mark sub-flow

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "sub-flow=reviewing"
# Advance 5 → 6 if not already past.
current_stage="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get current-stage)"
if (( current_stage == 5 )); then
  $CLAUDE_PLUGIN_ROOT/scripts/progress.sh advance 5
fi
```

### Step 2.5 — Generate `implementation/review-context.md`

Compose a compact snapshot of the context the brainstorming review session needs at every loop trip — active scope, goals, implemented surface, and open-findings cheat sheet. The chain stays in this snapshot for the common case and drops into canonical files only when a finding requires deeper context.

```bash
ctx_dest="$data_root/workflow-stream/$active_feature/implementation/review-context.md"
requirements_file="$data_root/workflow-stream/$active_feature/blueprints/current/requirements.md"
requirements_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$requirements_file" id)"
# frontmatter.sh init overwrites — safe to re-run if /mo-review is invoked again.
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init review-context "$ctx_dest" \
  "REQUIREMENTS_ID=$requirements_id" \
  "FEATURE=$active_feature" \
  "DATA_ROOT=$data_root"
```

Then fill the body via `Edit`, following the template's section guide:

- **`## Active scope`** — write `branch` and `base-commit` from `progress.md` (`progress.sh get branch`, `progress.sh get base-commit`).
- **`## Goals (this cycle)`** — 5–20 line excerpt from `requirements.md` `## Goals (this cycle)`.
- **`## Implemented surface`** — two short lists. (a) Changed areas: prefer reading from `implementation/change-summary.md`'s `## Changed files` section when fresh — it already groups paths by area and notes adds/dels per file; check freshness with `commits.sh change-summary-fresh "$active_feature"`. If stale or missing, fall back to `commits.sh changed-files "$active_feature"` and group manually. Either way, do not paste diffs. (b) Diagrams: list every file under `implementation/diagrams/` with a one-line purpose pulled from its `diagrams/README.md`.
- **`## Open findings (snapshot)`** — one line per `IR-NNN` from `review.sh list-open "$active_feature"`, in the order they appear in `overseer-review.md`. Format: `IR-NNN (<severity>): <summary>`.
- **`## Manual test results`** (only when `workflow-stream/<feature>/test/manual-test-results.md` exists) — emit a header line `<passed>/<total> scenarios passed; <failed> failed.` followed by one line per failed scenario in results-file order, citing the most relevant family member per the priority rule below. Append the section to `review-context.md` after `## Open findings (snapshot)`. The `IR-NNN` citation MUST be resolved at generation time via `review.sh find-by-seed-id-family` — do NOT read from the results-file `Cited as IR-NNN:` cache (it can drift if the review session renumbered or merged blocks since auto-seeding). Algorithm:

  ```
  read manual-test-results.md frontmatter (passed, failed, total, plan-id, seed-family-id)
  emit "## Manual test results"
  emit "<passed>/<total> scenarios passed; <failed> failed."
  for each failed scenario S in results-file order:
    base_seed_id = "manual-test:" + seed_family_id + ":" + S.id
    family = review.sh find-by-seed-id-family "$active_feature" "$base_seed_id"
      # TSV: <IR-NNN>\t<seed-id>\t<status>, ordered by NUMERIC suffix ascending
      # (base = generation 0, then :r1, :r2, ..., :r10, :r11). NOT lexicographic.
    cited_row = pick from family in priority order:
      1. open regression IR with the highest numeric suffix (max-N where status=open and N≥1)
      2. else base IR if status=open
      3. else IR with the highest numeric suffix overall (regression or base) regardless of status
         — preserves traceability to the latest seeded artifact
      4. else empty (no IR exists for this scenario)
    if cited_row non-empty:
      cited_ir = cited_row.IR-NNN; cited_status = cited_row.status
      if cited_status == "open":
        emit "Scenario <S.id>: <S.observation_one_line>; cited in <cited_ir> (open)"
      else:
        emit "Scenario <S.id>: <S.observation_one_line>; cited in <cited_ir> (status: <cited_status>; no open seeded finding remains)"
      update results-file scenario S — set "Cited as IR-NNN: <cited_ir>" (refresh the cache)
    else:
      emit "Scenario <S.id>: <S.observation_one_line>; (auto-seed declined or all family IRs deleted — no IR)"
      update results-file scenario S — clear the cache by rendering exactly
        "- **Cited as IR-NNN:**" with no value after the colon (the literal string "null" is invalid)
  ```

  Two important invariants: (1) the `Cited as IR-NNN:` field in `manual-test-results.md` is a **cache** populated by review-context generation, NOT by `/mo-manual-test-run` — auto-seed writes blocks but does not write back the resulting `IR-NNN` to the results file (it would race with the review session's renumbering). Review-context regeneration is the unique writer. (2) `find-by-seed-id-family` returning empty is a *recoverable* state, not an error: emit the "no IR" form and clear the cache to a blank-after-colon shape.

  Brainstorming sub-agents reading `review-context.md` get the manual-test signal in their first read with up-to-date IR citations, without main needing to re-narrate.

- **`## Decisions`** — folded from `$data_root/workflow-stream/$active_feature/decisions.md` (per `docs/clear-points/plan.md` §5.2 mo-review section, §10 step 4b). Per-iteration review sub-agents read `review-context.md` as their primary context source — this fold-in is the **only path** by which feature-scoped decisions reach them. Without it, a `stage-5-to-6` clear (or any decision written between stages 5 and 6) would silently strand decisions outside the sub-agents' view.

  Same body extraction recipe as `mo-plan-implementation` Step 3.5:

  ```bash
  decisions_file="$data_root/workflow-stream/$active_feature/decisions.md"
  decisions_body="$(python3 - "$decisions_file" <<'PYEOF'
import sys, os, re
path = sys.argv[1]
if not os.path.isfile(path):
    sys.exit(0)
with open(path) as f:
    content = f.read()
m = re.match(r'^---\n.*?\n---\n(.*)$', content, re.DOTALL)
if not m:
    sys.exit(0)
body = m.group(1)
sections = re.split(r'(?m)^(?=## )', body)
out = []
for sec in sections:
    if not sec.strip().startswith('## '):
        continue
    cleaned = re.sub(r'<!--.*?-->', '', sec, flags=re.DOTALL)
    cleaned = re.sub(r'\n{3,}', '\n\n', cleaned).rstrip() + '\n'
    if re.search(r'(?m)^- ', cleaned):
        out.append(cleaned)
print('\n'.join(out).rstrip())
PYEOF
)"
  ```

  If `decisions_body` is non-empty, replace the `_(none recorded)_` line in the rendered review-context's `## Decisions` section with the extracted body via `Edit`. If `decisions.md` is absent OR every section is placeholder-only, leave `_(none recorded)_` untouched. **Do NOT delete the `## Decisions` heading itself** — the sub-agent prompt template references it positionally, and an absent heading is a different signal than "heading present, no decisions."

  This fold-in **always runs** at Step 2.5, regardless of whether the `stage-5-to-6` clear-point gate (§3.3 of the clear-points plan) is shipped — it is independently useful as soon as `decisions.md` exists, because any decision written between stages 5 and 6 (with or without a clear) needs to reach the sub-agents.

The `## On-demand canonical files` section is template-emitted and does not need editing. No `schemas/review-context.schema.yaml` change is required for the manual-test addition (the schema validates frontmatter only).

### Step 2.6 — Ask the overseer to pick a review mode

Read the suggestion that stage 5 (`/mo-continue` Overseer Step 1.6) persisted to `progress.md`:

```bash
suggestion="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get review-mode-suggestion 2>/dev/null || echo 'none')"
```

Branch the prompt's default and rationale on the suggestion:

**If `suggestion == "direct"`** (all open findings have `scope: fix` — stage 5 detected this when canonicalizing):

> "Review session — pick a mode for addressing the open findings on `$active_feature`:
>
>   - **`direct`** (default — recommended) — All N open findings are simple fixes (`scope: fix`). I'll address them myself in this session, applying patches directly. This skips the brainstorming chain ceremony and is the cheapest path when every finding is a fix.
>   - **`brainstorming`** — runs the loop in main with one fresh sub-agent per iteration. The sub-agent reads each finding's `scope:` as a hint and decides per-finding whether to `fix`, `re-implement`, `re-plan`, or `re-spec`. Use this if you want sub-agent dispatch even though findings are all fixes (e.g., to keep main context small).
>
> Reply `direct` (or just press Enter to accept the default), or `brainstorming` to override."

**Otherwise** (`suggestion == "brainstorming"` or `none` — keep the current default):

> "Review session — pick a mode for addressing the open findings on `$active_feature`:
>
>   - **`brainstorming`** (default) — runs the loop in main with one fresh sub-agent per iteration. The sub-agent reads each finding's `scope:` as a hint and decides per-finding whether to `fix` (patch), `re-implement`, `re-plan`, or `re-spec`. Best when findings span scope tiers, or when you want sub-agent dispatch to keep main context small (recommended for cycles with cascade-scoped findings).
>   - **`direct`** — I address the findings myself in this session, applying patches directly. Best when every finding is `fix` or simple `re-implement` (small refactors with clear acceptance criteria) and you want to skip the chain ceremony.
>
> Reply `brainstorming` or `direct`."

Wait for the reply. If the overseer presses Enter without typing (accept-default), use the suggestion-derived default (`direct` when suggestion was `direct`, `brainstorming` otherwise). Persist the actual choice:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "review-mode=<choice>"
```

Then dispatch on the value:

- `brainstorming` → continue to **Step 3a**.
- `direct` → continue to **Step 3b**.

The persisted `active.review-mode` records the overseer's actual choice; `active.review-mode-suggestion` stays as stage 5 set it (it is informational and re-readable for debugging/audit, not mutated by stage 6).

### Step 3a — Brainstorming mode: main-driven loop with fresh per-iteration sub-agents

**Architectural change from prior versions.** Step 3a no longer hands the entire `go again` loop to the brainstorming Skill. Main owns the iteration boundaries. Each iteration spawns one **fresh sub-agent** (`Agent` invocation with `subagent_type: millwright-overseer-development-machine:review-iteration-runner` — explicitly NOT a fork) that addresses the currently-open findings, returns a structured summary, and evaporates. Cascading scopes (`re-spec` / `re-plan`) still happen — but they happen *inside* the sub-agent's context, never accumulating in main.

This caps per-iteration main-context growth at the sub-agent's return summary (~500 tokens). A 10-iteration loop adds ~5k tokens to main instead of ~500k.

#### Step 3a.1 — Compute path constants

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
quest_slug="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh current)"
review_ctx="$data_root/workflow-stream/$active_feature/implementation/review-context.md"
overseer_review="$data_root/workflow-stream/$active_feature/implementation/overseer-review.md"
quest_summary="$data_root/quest/$quest_slug/summary.md"
blueprint_dir="$data_root/workflow-stream/$active_feature/blueprints/current"
```

These are the paths the per-iteration sub-agent will reference. They do NOT change between iterations.

#### Step 3a.2 — Iteration loop

The loop runs while open findings exist AND the overseer has not typed `approve` or `abort`. Each iteration is one full address-pass.

##### Step 3a.2.1 — Read open IR-IDs

```bash
open_ids="$($CLAUDE_PLUGIN_ROOT/scripts/review.sh list-open "$active_feature")"
```

If `open_ids` is empty: this should not happen at iteration entry — Step 2 already short-circuits the no-findings case. If it does happen mid-loop (e.g., the overseer manually closed all findings), exit cleanly per Step 3a.2.6 `approve` branch.

##### Step 3a.2.2 — Refresh `review-context.md` body (skip on first iteration)

On iteration 1, `review-context.md` is fresh from Step 2.5 — skip this step.

On iterations 2+, the prior iteration may have committed code; the snapshot of `## Implemented surface` and `## Open findings (snapshot)` is stale. Refresh:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/review.sh sync-refs "$active_feature" --refresh-body
```

`sync-refs --refresh-body` re-derives the two body sections from current git state and `review.sh list-open` output. The cache key `(requirements-id, base-commit, HEAD-at-iteration-start)` causes a no-op when nothing has moved — see `recommendations.md` § "Cache Key Specifications" → `review-context.md` body refresh.

##### Step 3a.2.3 — Pre-classify cascade context + compose delta primer (Phase 1.6 + 7.1)

For each open finding with scope ∈ {`re-spec`, `re-plan`}, read its block in `overseer-review.md` to extract IR-id, summary, and the file paths it references. Compose a small "cascade hints" section that the sub-agent prompt will include — paths and 1-line excerpts ONLY, never file content:

- For `re-plan` cascades: include the path to the most recent plan file under `docs/superpowers/plans/` (the plan the chain wrote at stage 3) and a 1-line note on which step the finding invalidates.
- For `re-spec` cascades: include both the plan path and the spec path under `docs/superpowers/specs/` plus a 1-line note on which design assumption the finding challenges.

The sub-agent reads the actual plan/spec files inside its own context. **Do NOT pre-fetch file contents in main** — embedding bytes in the sub-agent's prompt pays for them twice (once in main during prompt construction, once in the sub-agent during processing) and defeats the optimization.

**Delta primer (Phase 7.1).** For each cascade-scoped finding, also compose a delta primer the sub-agent will pass through when it invokes the cascading Skill (`brainstorming` for `re-spec`, `writing-plans` for `re-plan`). The delta primer tells the chain which sections to regenerate vs preserve, encouraging minimal-rework rather than full regeneration. Format:

```
DELTA PRIMER for <IR-NNN> (<scope>):

You already produced <plan path> in a prior iteration of this cycle.
<For re-spec: AND the spec at <spec path>.>

This finding invalidates: <one-line description of the invalidated section/step/assumption — extracted from the finding's details: body, NOT a re-read of the plan/spec content>.

Regenerate ONLY the affected sections. Preserve unchanged sections verbatim — they were correct in the prior iteration and the cycle's later work depends on their stability.

If during regeneration you discover the invalidation has a wider blast radius than initially identified, surface that in your return summary's `Findings / risks` so the overseer can decide whether to escalate (e.g., a re-plan finding that turns out to require a re-spec).
```

The delta primer is **best-effort guidance**, not a hard contract. The cascading Skill (`brainstorming`/`writing-plans`) is owned out-of-tree; whether it honors the "regenerate only X" framing depends on the Skill's training. In practice:

- A well-trained chain that recognizes the delta primer pattern will preserve unchanged sections and only re-derive the affected scope — saving substantial sub-agent context.
- A chain that doesn't recognize the pattern will regenerate fully — which is the same behavior as today (no regression). The sub-agent's context still evaporates after return, so the cost is bounded.

Either way, the delta primer doesn't introduce a failure mode. Worst case is no improvement; best case is meaningful cascade-cost reduction.

If no open finding has cascade scope, omit the cascade hints section AND the delta primer entirely.

##### Step 3a.2.4 — Spawn fresh sub-agent

Invoke `Agent` with `subagent_type: millwright-overseer-development-machine:review-iteration-runner`. The prompt is composed inline below. **Use `subagent_type` explicitly — a fork would inherit main's context and defeat the optimization.**

Sub-agent prompt template (substitute literals for `<...>` placeholders):

```
You are a fresh sub-agent invoked from `mo-review` Step 3a to address overseer review findings on the "<active_feature>" feature. Your context is isolated from the main session — main does not see your tool calls, only your final return summary.

**Required first reads (in order):**

1. <review_ctx> — compact snapshot of active scope, goals, implemented surface, and open findings. This plus overseer-review.md is enough for most cases.
2. <overseer_review> — canonical source of findings. Authoritative.

**On-demand fallbacks** (read only if a gap surfaces):
- <blueprint_dir>/requirements.md — full goals / planned / non-goals.
- <blueprint_dir>/config.md — skills, rules, GIT BRANCH, Overseer Additions.
- <blueprint_dir>/primer.md — original stage-3 launch primer.
- <quest_summary> — read `## Cross-cutting constraints` and `## Feature: <active_feature>`.

**Open findings to address this iteration:**

<bullet list of open IR-IDs with severity + scope + summary, derived from `review.sh list-open` and per-IR scope/summary lookups>

**Cascade hints** (only included when at least one open finding has scope ∈ {re-spec, re-plan}):

<for each cascade-scoped finding: IR-id + scope + plan path + spec path (re-spec only) + 1-line invalidation note>

**Delta primer** (Phase 7.1 — paired with each cascade hint):

<for each cascade-scoped finding: insert the DELTA PRIMER block constructed in Step 3a.2.3 — names the existing plan/spec paths, names the invalidated section, asks for minimal regeneration>

When you invoke the cascading Skill for a re-plan or re-spec finding, **include the delta primer verbatim in the Skill invocation prompt**. The primer asks the chain to preserve unchanged sections — that's the explicit intent of cascade pre-classification. If the chain regenerates fully despite the primer, that's expected for some Skill configurations and not a failure; surface it in `Findings / risks` only if the regeneration ignored an obvious preservation opportunity.

Read those plan/spec files yourself if you need their content. Main has NOT pre-fetched anything for you — passing file paths is intentional.

**How to address findings:**

The `scope` field on each finding is a hint, not a directive. Pick the smallest rework that genuinely addresses the root cause:
- `fix` — patch the existing code directly. Commit. Mark resolved.
- `re-implement` — re-do the affected sections (you may invoke `subagent-driven-development` for execution if it helps, but stay in this sub-agent's context). The existing plan stays.
- `re-plan` — regenerate the plan for the affected scope. The existing spec stays. **Pass the delta primer to `writing-plans`**: it asks the chain to preserve unchanged plan steps and only re-derive the affected ones.
- `re-spec` — full re-design. Regenerate spec + plan + commits. **Pass the delta primer to `brainstorming`**: when only one design assumption is invalidated, the chain may be able to preserve other spec sections rather than re-deriving the whole spec from scratch.

Process findings in descending order of impact: re-spec → re-plan → re-implement → fix. A higher-tier action supersedes lower-tier findings in the same pass — mark superseded findings `fixed` with `fix-note: "superseded by re-spec at iteration N"` (or re-plan, etc.).

**For each finding addressed**, commit your changes and call:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/review.sh set-status "<active_feature>" <IR-NNN> fixed "<one-line fix-note>"
```

Use `wontfix` instead of `fixed` if a finding turns out to be invalid or already addressed. Do NOT mutate `progress.md` — that is mo-workflow's job, triggered later by the overseer's `/mo-continue`.

**One-iteration discipline:** address ALL listed open findings before returning. Do not partially address and return. The main agent will spawn a new fresh sub-agent for the next iteration if the overseer types `go again`.

---

Required return shape — return ONLY this structure. Do not narrate intermediate steps:

Result: success | partial | blocked
Artifacts changed:
- <path>: <one-line note on what changed>
Commits:
- <sha>: <commit subject>
Findings / risks:
- <short bullet, optional>
Main should read:
- <path>: <reason why main needs this>

Total return must fit under ~1k tokens. If your scope was too broad to summarize in 1k, return `Result: partial` and explain in Findings / risks; the main agent will re-scope.
```

##### Step 3a.2.5 — Receive sub-agent return

The fresh sub-agent returns one structured summary message (per the contract above). Parse it:

- `Result: success` — proceed to Step 3a.2.6 (ask overseer).
- `Result: partial` — surface the Findings/risks section to the overseer and ask whether to spawn another sub-agent for the unfinished work or to continue with the current state.
- `Result: blocked` — surface the blockage, ask the overseer how to proceed (often this means dropping into direct mode, or aborting).

##### Step 3a.2.6 — Surface summary to overseer; ask approve / go again / abort

After the sub-agent returns, surface its summary to the overseer in chat. Then prompt:

> "Iteration <N> complete. Resolved IR-IDs: `<list-from-summary>`. <Optional: surface 'Findings / risks' or 'Main should read' lines if non-empty.>
>
> Reply:
>   - `approve` — exit the review loop. I'll tell you to type `/mo-continue` to resume mo-workflow and finalize.
>   - `go again` — open `overseer-review.md` (any text editor) to add new findings (plain sentences are fine — I'll canonicalize them; or use the `### IR-NNN` block format directly). Then reply `go again` to start another iteration.
>   - `abort` — invoke `/mo-abort-workflow` to cancel the workflow."

Wait for the reply.

##### Step 3a.2.7 — Branch on reply

- **On `approve`:** Tell the overseer *"Review session approved. Type `/mo-continue` to resume the mo-workflow and finalize."* Exit Step 3a (do NOT call `progress.sh` for stage advance — the Review-Resume Handler in `mo-continue.md` owns finalization).
- **On `go again`:** The overseer may have added free-form findings to `overseer-review.md`. Re-canonicalize:
  ```bash
  # Re-run canonicalization + classify any new free-form spans
  $CLAUDE_PLUGIN_ROOT/scripts/review.sh canonicalize "$active_feature" || true
  # If spans were found, classify and add them per the Step 1.5 recipe in commands/mo-continue.md.
  # Then re-compute review-mode-suggestion (Step 1.6 recipe) so subsequent iterations reflect the new scope mix.
  ```
  Then loop back to Step 3a.2.1 for the next iteration.
- **On `abort`:** Invoke `/mo-abort-workflow`. Stop.
- **On any other reply:** Treat as a verbal concern. Either (a) ask the overseer to write it into `overseer-review.md` first if it's a substantive review finding (then loop back to Step 3a.2.7's `go again` branch), or (b) address it inline if it's a clarifying question (then re-prompt at Step 3a.2.6).

#### Step 3a.3 — Why this design

- **Per-iteration sub-agents cap main-context growth.** Each iteration the sub-agent's source-file reads, edits, and tool outputs stay in its disposable context. Main sees only the ~500-token return summary.
- **Cascades stay contained.** A `re-spec` or `re-plan` finding triggers significant re-reads inside the sub-agent (plan/spec/code). Those reads do not enter main.
- **Hand-off contract is preserved.** The terminal state is identical to the prior implementation: overseer types `approve`, then `/mo-continue`, and the Review-Resume Handler finalizes. Mo-workflow's state machine doesn't notice the internal refactor.
- **Main runs the iteration boundaries.** The overseer's `approve` / `go again` / `abort` is consumed in main, not inside a Skill primer. This makes the loop reentrant after session breaks: a break between iterations leaves the workflow in a recoverable state (`sub-flow=reviewing` is already set; the next `/mo-continue` falls back into Step 3a's loop logic).

### Step 3b — Direct mode: address findings in this session

The millwright (this session) addresses each finding directly — no Skill is invoked. The overseer interacts with the millwright in chat as fixes happen.

1. **Read the required first reads:**
   - `implementation/review-context.md` — compact snapshot of active scope, goals, implemented surface, open-findings cheat sheet.
   - `implementation/overseer-review.md` — canonical findings (re-read on every `go again`).
2. **Process open findings in descending impact order:** `re-spec` → `re-plan` → `re-implement` → `fix`. A higher-tier action supersedes lower-tier findings in the same pass; mark superseded findings `fixed` with `fix-note: "superseded by re-spec at iteration N"` (or re-plan, etc.).
   - **Direct mode caveat:** if a finding's scope is `re-plan` or `re-spec`, it likely needs the chain's design / plan gates that direct mode skips. Surface that to the overseer and ask if they want to switch to `brainstorming` for the rest of the session — re-set `review-mode=brainstorming` and proceed to Step 3a. Only stay in direct mode for `fix` / simple `re-implement` findings.
3. **For each finding addressed**, commit the change and call:
   ```bash
   $CLAUDE_PLUGIN_ROOT/scripts/review.sh set-status "$active_feature" <IR-NNN> fixed "<one-line fix-note>"
   ```
   Use `wontfix` instead of `fixed` if the overseer agrees to skip it.
4. **One-iteration discipline:** address ALL open findings before asking for approval. Do not partially fix and ask.
5. **Loop pattern (same iteration boundaries as brainstorming mode, just no sub-agent dispatch):**
   1. Read `overseer-review.md`; list `open` findings.
   2. Address them per the rules above; commit; mark each resolved.
   3. Tell the overseer: *"All open findings addressed (resolved: \<ids\>). Either: (a) reply `approve` to end the review session — then type `/mo-continue` to resume mo-workflow and finalize; (b) add new findings to `overseer-review.md` (plain sentences are fine — I'll canonicalize them) and reply `go again` so I re-read; (c) reply `abort` to invoke `/mo-abort-workflow`."*
   4. On `approve`: tell the overseer *"Review session approved. Type `/mo-continue` to resume the mo-workflow and finalize."* Then stop. Do NOT call `progress.sh` for completion — that's mo-workflow's job, triggered by `/mo-continue`.
   5. On `go again`: re-canonicalize free-form additions (run `review.sh canonicalize` + classify any new spans + `review.sh add` per the recipe in `mo-continue.md` Overseer Step 1.5). Then re-run `mo-continue.md` Overseer Step 1.6 to update `review-mode-suggestion` based on the new scope mix. Then refresh `review-context.md` body via `review.sh sync-refs --refresh-body` (Phase 1.4). Then re-call `review.sh list-open` and go to step 1.
   6. On `abort`: invoke `/mo-abort-workflow`. Stop.
6. **Existing scope rules** apply unchanged: pick the smallest tier that genuinely resolves the root cause; escalate if narrower tier leaves the cause in place.

### Step 4 — Hand off

After Step 3a (brainstorming) or Step 3b (direct), stop driving the mo-workflow. Both modes converge on the same terminal: the overseer types `approve` to end the session, then types `/mo-continue` to resume mo-workflow.

- **Brainstorming mode (Step 3a):** runs in the main session, but each iteration delegates to a fresh sub-agent (`subagent_type: millwright-overseer-development-machine:review-iteration-runner`) whose context evaporates on return. Main owns the iteration boundaries (`approve` / `go again` / `abort`); the sub-agent owns the per-iteration finding work. The overseer drives the loop to its terminal state by typing `approve`, then `/mo-continue` to resume mo-workflow.
- **Direct mode (Step 3b):** runs entirely in the main session — no sub-agent dispatch. Best when every open finding is `fix` or simple `re-implement` and the chain ceremony would just be overhead. The overseer reviews fixes inline; when satisfied, types `approve` to end the loop, then `/mo-continue` to resume.

`mo-review` does **not** advance past stage 6. The Review-Resume Handler in `/mo-continue` (see `commands/mo-continue.md`) handles the post-session work when the overseer types `/mo-continue` after the session ends: sanity-checking no `open` findings remain, marking `overseer-review-completed=true`, setting `sub-flow=none`, advancing 6 → 7, and auto-firing `/mo-complete-workflow`.

**Do not type `/mo-continue` while a Step 3a sub-agent is mid-iteration** (i.e., while you're waiting on the sub-agent's return summary, or while main is asking for `approve` / `go again` / `abort`). Answer the prompt first; type `/mo-continue` only after Step 3a has fully exited via the `approve` branch and returned control with a "type /mo-continue to resume" message.

## Delegation (built-in)

Brainstorming mode (Step 3a) **delegates by default**: every iteration spawns one fresh sub-agent that addresses the currently-open findings and returns a structured summary. This is the dominant context-optimization win in the entire mo-workflow — it caps per-iteration main-context growth at the sub-agent's return summary regardless of how many findings or cascade scopes are involved.

The earlier "cluster sub-agents for >5 findings" pattern (still mentioned in `docs/workflow-spec.md` § "Delegation guidance") is now redundant in brainstorming mode — Step 3a's per-iteration sub-agent handles arbitrary finding counts inside its own context. Cluster delegation is only relevant in direct mode if a single iteration has >5 findings AND the overseer explicitly wants per-cluster sub-agents instead of one in-main pass; in practice, switching to brainstorming mode is simpler.

## Notes

- The Step 3a sub-agent prompt is a **layered load**: `review-context.md` + `overseer-review.md` are the required first reads; `requirements.md`, `config.md`, `summary.md`, and `primer.md` are on-demand fallbacks the sub-agent reads if a gap surfaces.
- `review-context.md` body is **refreshed each iteration** by Step 3a.2.2 via `review.sh sync-refs --refresh-body` (cache-keyed on `(requirements-id, base-commit, HEAD-at-iteration-start)` — no-op when nothing has moved). The frontmatter `requirements-id` is also synced if `/mo-update-blueprint` ran mid-loop. The sub-agent re-reads canonical files (`overseer-review.md`, `requirements.md`) when current state matters beyond the snapshot.
- `mo-review` does not generate findings. Authoring is the overseer's job (subjective concerns) and brainstorming's job (concerns surfaced during the session, written into `overseer-review.md` directly via the same `review.sh add` interface).
- Brainstorming exits in one of three ways:
  - **Approval (clean exit):** all findings resolved + overseer types `approve` → session ends. The overseer then types `/mo-continue`, which fires the Review-Resume Handler in `/mo-continue` to advance 6→7 and auto-fire `/mo-complete-workflow`.
  - **Abort:** overseer types `/mo-abort-workflow` mid-session → see `commands/mo-abort-workflow.md` for cleanup.
  - **Stuck / dead-end:** brainstorming may exit without addressing all findings. The Review-Resume Handler (triggered when the overseer types `/mo-continue`) detects open findings remaining and prompts the overseer to retry with `/mo-review` or to abort.
- The chain's spec/plan files (under `docs/superpowers/`) are not inputs and not tracked. Brainstorming regenerates its own artefacts internally as part of any cascade.
- There is no iteration cap. Brainstorming controls its own loop; the overseer ends it by typing `approve`.
