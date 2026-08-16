---
description: Generate blueprints/current/ for the active feature — requirements.md, config.md, and diagrams/. Stage 2 of the mi-workflow.
---

# mi-apply-impact

**Runtime bootstrap.** Every `$CLAUDE_PLUGIN_ROOT` reference in this command's Bash blocks assumes a resolved plugin root; Claude Code does not inject the env var into Bash subshells. If it is empty in your shell, apply the canonical resolver (`docs/millwright-inspector-project.md` §8.14; reference implementation: `mi-continue.md` Step 1a) before the first Bash block: (1) inherited env var when it points at a working install, (2) `$PWD` when it is this plugin's source repo, (3) the `installPath` from `~/.claude/plugins/installed_plugins.json` — then export it, persist it to the per-cwd tempfile, and prepend the recovery one-liner to every subsequent Bash block. Refuse with an environmental diagnostic if none resolve.

**Delegation contract.** This command REQUIRES the sub-agents listed below; §8.13's main-read budget forbids main from doing their work itself. **Invoking `/mi-apply-impact` IS the user requesting them** — Claude Code's default "do not call the Agent tool unless the user requested it" (and any stricter house rule layered on it) does not reach a sub-agent this command names at the step that names it, so spawn them without asking for extra confirmation. The default still holds everywhere else: never spawn a sub-agent this command does not name, and never invent fan-out to parallelize a step main is supposed to run. If a named delegation genuinely cannot run (type unavailable, harness refusal), say so and stop — never silently do its work in main. Sub-agents: `lessons-filter` (Step 1.5 Pre-Step A), `codebase-grounder` (Phase 2.1 — writes `grounding-report.md`), `blueprint-diagrammer` (Step C — writes the `.puml` sources). Canonical rule: `docs/millwright-inspector-project.md` §8.15.

**Stage 2 launcher.** Pops the next feature off the queue, creates its `progress.md`, and generates the blueprint artifacts (requirements, config, diagrams).

**Main-read budget (stage 2).** Allowed in main: `summary.md` (active feature section + cross-cutting), generated artifacts. Forbidden in main: (a) codebase grounding pass — delegated to `subagent_type: millwright-inspector-development-machine:codebase-grounder` (Phase 2.1) which writes `implementation/grounding-report.md`; (b) diagram framing + render — delegated to `subagent_type: millwright-inspector-development-machine:blueprint-diagrammer` (Step C of `docs/blueprint-regeneration.md`) which writes `.puml` sources into `blueprints/current/diagrams/`. Main writes only the `diagrams/README.md` after the sub-agent returns. See `docs/millwright-inspector-project.md` § "Main-read budget gates by stage" for the canonical table.

## Invocation

The millwright auto-invokes this command on two triggers — the inspector does **not** type it in the happy path:

1. **End of stage 1.5.** Immediately after the inspector types `/mi-continue` to confirm the prioritized queue order (the Pre-flight Handler in `commands/mi-continue.md` writes `queue-rationale.md`, runs `progress.sh reorder`, then auto-fires this command).
2. **End of stage 8 (queue loop).** After `mi-complete-workflow` archives the finished feature and leaves `active: null` with more features in the queue, the millwright re-enters at stage 2 for the next feature (soft announce-and-continue). This command calls `progress.sh activate` internally to pop `queue[0]` into a fresh `active` block.

The command is still invokable manually for recovery — for example after `/mi-abort-workflow` (to regenerate blueprints from scratch) or when `/mi-resume-workflow` explicitly recommends it.

## Preconditions

- The active cycle's `todo-list.md`, `summary.md`, and `progress.md` exist (from stage 1; under `quest/<active-slug>/`).
- The inspector has marked at least one todo item as `PENDING`.
- The inspector has confirmed the workflow queue order (or the previous feature has just finished via `mi-complete-workflow`, leaving `active: null` in `progress.md`).

## Execution

### Step 1 — Activate (or re-enter) the active feature

Three entry conditions, evaluated in order (Item 2 of the v11 plan):

1. **`active` is null** — pop `queue[0]` into a fresh `active` block (current-stage=2, branch=null, all other runtime fields default). This is the original happy path.
2. **`active.current-stage == 2`** — re-entering the same feature mid-stage-2 (e.g., a session break interrupted blueprint generation; the inspector re-runs `/mi-apply-impact` for the same feature). Skip activation and proceed to Step 2 with the existing `active.feature`. Surface `check-current` status so the inspector knows whether `current/` is already complete (`0` → short-circuit), partial (`2` → surface what's missing; offer `--force`), or empty (`1` → regenerate from scratch).
3. **`active.current-stage > 2`** — a different feature is mid-flight. Refuse: the inspector must run `/mi-abort-workflow` to clear it before re-running `/mi-apply-impact`.

**Feature-test guard (runs first — before activation, before `ensure-current`).**
A feature-test entry has no blueprint stage and its folder deliberately carries no
`blueprints/` (`FTW-002`). On the forward path `/mi-continue`'s Row A never fires this
command for such an entry; this guard closes the manual-invocation hole, where
`blueprints.sh ensure-current` would otherwise create the folder the design forbids.

```bash
# Guard the queue-head on a fresh run, and the active feature on a re-entry.
guard_candidate="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get-active 2>/dev/null || echo 'null')"
if [[ "$guard_candidate" == "null" || -z "$guard_candidate" ]]; then
  guard_candidate="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh queue-remaining 2>/dev/null | sed '/^$/d' | head -1)"
fi
if [[ -n "$guard_candidate" ]] && $CLAUDE_PLUGIN_ROOT/scripts/todo.sh is-feature-test "$guard_candidate"; then
  echo "error: '$guard_candidate' is this cycle's feature-test entry. It has no blueprint stage, and this command would create the blueprints/ folder its design forbids." >&2
  echo "       Type /mi-continue instead — the dispatcher routes it into the abbreviated pipeline (diagrams → test plan → run → review → resolution)." >&2
  exit 1
fi
```

No activation, no `ensure-current`, no state mutation — the guard refuses with
`progress.md` byte-identical. For every ordinary feature `is-feature-test` exits 1 and the
command proceeds exactly as today.

```bash
active_feature_pre="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get-active 2>/dev/null || echo 'null')"

force_regen=0
for arg in $ARGUMENTS; do
  case "$arg" in
    --force) force_regen=1 ;;
  esac
done

if [[ "$active_feature_pre" == "null" || -z "$active_feature_pre" ]]; then
  active_feature="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh activate)"
  echo "Starting workflow for feature: $active_feature"

  # Feature-folder lineage backstop — late safety net behind /mi-run's Step-3
  # uniqueness gate (which prevents this at naming time for post-gate cycles).
  # Runs BEFORE ensure-current: ensure-current would create the folder and
  # link it to this cycle, flipping every later check to same-cycle. Fresh
  # activation only — the re-entry branch below re-enters a folder this cycle
  # already owns.
  if lineage_msg="$($CLAUDE_PLUGIN_ROOT/scripts/folder-id.sh feature-lineage-check "$active_feature")"; then
    echo "$lineage_msg"
  else
    echo "warning: $lineage_msg" >&2
    echo "warning: workflow-stream/$active_feature already exists and cannot be tied to this cycle's journal folders. Proceeding would mix this cycle's artifacts into the existing folder." >&2
    exit 78   # halt for inspector decision — see prose below
  fi

  $CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh ensure-current "$active_feature"
else
  current_stage="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get current-stage)"
  if [[ "$current_stage" != "2" ]]; then
    echo "error: feature '$active_feature_pre' is mid-flight at stage $current_stage. Run /mi-abort-workflow to clear before re-running /mi-apply-impact." >&2
    exit 1
  fi
  active_feature="$active_feature_pre"
  echo "Re-entering stage 2 for feature: $active_feature"
  $CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh ensure-current "$active_feature"

  # Inspect what's already there. check-current is in default mode (no
  # --require-primer): primer.md is not expected at stage 2.
  if "$CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh" check-current "$active_feature"; then
    cc_status=0
  else
    cc_status=$?
  fi
  case "$cc_status" in
    0)
      if [[ "$force_regen" != "1" ]]; then
        echo "blueprints/current is already complete for $active_feature. Skipping regeneration. Re-run with --force to regenerate from scratch, reply 'walkthrough' for an item-by-item guided review of requirements.md, or type /mi-continue to advance to /mi-plan-implementation."
        exit 0
      fi
      echo "--force passed; regenerating despite check-current=0."
      ;;
    1)
      echo "blueprints/current is empty; regenerating from stage-2 inputs."
      ;;
    2)
      if [[ "$force_regen" != "1" ]]; then
        echo "warning: blueprints/current is partial (check-current=2). Inspect the existing files; re-run /mi-apply-impact --force to regenerate from scratch, or repair the files manually and type /mi-continue." >&2
        exit 1
      fi
      echo "--force passed; clearing partial current/ and regenerating."
      data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
      curr="$data_root/workflow-stream/$active_feature/blueprints/current"
      shopt -s dotglob nullglob
      for entry in "$curr"/*; do rm -rf "$entry"; done
      shopt -u dotglob nullglob
      # Stage-2 also owns two artifacts under implementation/. Allowlisted
      # cleanup so later-stage artifacts (inspector-review.md, review-context.md,
      # change-summary.md, diagrams/) are preserved if the inspector happens to
      # be combining --force with a stale implementation/ from a prior aborted
      # run. See docs/superpowers/specs/2026-05-22-blueprint-lessons-injection-design.md §8.1.
      impl_dir="$data_root/workflow-stream/$active_feature/implementation"
      for stage2_artifact in grounding-report.md blueprint-lessons.md; do
        [[ -e "$impl_dir/$stage2_artifact" ]] && rm -f "$impl_dir/$stage2_artifact"
      done
      # v1.5: review-history.md sibling lives under blueprints/current/ and gets
      # cleared with the rest of current/ above, but be defensive in case the
      # loop above changes — explicit remove keeps cleanup intent visible.
      curr_review_history="$data_root/workflow-stream/$active_feature/blueprints/current/review-history.md"
      [[ -e "$curr_review_history" ]] && rm -f "$curr_review_history"
      $CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh ensure-current "$active_feature"
      ;;
  esac
fi
```

If the queue is empty AND `active` was null, `progress.sh activate` errors out — tell the inspector and stop. Branch is declared per-feature in `config.md`'s `## GIT BRANCH` section (written later in this command) and validated at stage 3; `/mi-plan-implementation` will persist it into `active.branch`.

**On the lineage-backstop halt (`exit 78`):** relay both warning lines to the inspector and ask how to proceed:

> "`workflow-stream/$active_feature/` already exists from a previous workflow (`<lineage diagnostic>`), and this cycle was built from different journal folders. Reusing the folder mixes the old artifacts (blueprints history, manual-test plans, decisions) with this cycle's.
>
>   - `proceed` — reuse the folder anyway. Only right when this genuinely continues the same feature (its test plans and decisions SHOULD carry over).
>   - anything else — I'll stop. Run `/mi-abort-workflow`, then fix the feature name at stage 1 (new cycles get this automatically from `/mi-run`'s Step-3 uniqueness gate — e.g. name the feature after its journal folder, `general-fixes-2`)."

On `proceed`, re-invoke `/mi-apply-impact`: the `active` block is already populated at `current-stage=2`, so the re-entry branch takes over and calls `ensure-current` without re-running the check. This backstop exists for cycles scaffolded before the `/mi-run` Step-3 gate and for hand-edited queues — post-gate cycles arrive here with collision-free names.

If the inspector replies `walkthrough` after the `check-current=0` short-circuit message above, run the Step 3.3 requirements walkthrough against the existing `blueprints/current/requirements.md` — the short-circuit path is the same review gate as Step 3.2, just re-entered.

### Step 1.5 — Lessons-filter Pre-Step A

Filter `lessons-learned.md` for blueprint-creation-relevant entries before
the runbook's main work begins, so main writing `requirements.md` and the
delegated `codebase-grounder` both have the filtered set in scope. The
filtered artifact also serves the stage-2 codex review at Step B.5.

The whole step is **guarded on `lessons-learned.md` existing**. `scripts/lessons.sh path`
returns a resolved path unconditionally — it does not check existence — so
the guard lives at this call site.

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
quest_dir="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh dir)"
impl_dir="$data_root/workflow-stream/$active_feature/implementation"
blueprint_lessons_path="$impl_dir/blueprint-lessons.md"
lessons_path="$($CLAUDE_PLUGIN_ROOT/scripts/lessons.sh path)"

if [[ ! -f "$lessons_path" ]]; then
  echo "info: lessons-learned.md not present; skipping blueprint-lessons injection"
else
  mkdir -p "$impl_dir"
  lessons_mtime="$(stat -f %m "$lessons_path" 2>/dev/null \
                   || stat -c %Y "$lessons_path" 2>/dev/null \
                   || echo 0)"
  # Integer-valued fields use the !RAW! sentinel from
  # scripts/internal/common.sh so the renderer interpolates them verbatim
  # rather than wrapping them as YAML strings — required because the
  # schema types lessons-source-mtime and selected-count as integer.
  "$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" init blueprint-lessons \
    "$blueprint_lessons_path" \
    "FEATURE=$active_feature" \
    "LESSONS_SOURCE_MTIME=!RAW!$lessons_mtime" \
    "SELECTED_COUNT=!RAW!0"

  # Spawn the lessons-filter sub-agent. The prompt below substitutes the
  # placeholders with the concrete values from this caller context.
  #
  # Sub-agent: agents/lessons-filter.md (subagent_type:
  # millwright-inspector-development-machine:lessons-filter).
  #
  # Spawn prompt template:
  #
  #   You are invoked from mi-apply-impact's Pre-Step A. Filter
  #   <lessons_path> to the blueprint-creation-relevant entries for the
  #   "<active_feature>" feature this cycle. Main has already created
  #   <blueprint_lessons_path> with valid frontmatter; you fill the body and
  #   update only `selected-count`. Follow agents/lessons-filter.md
  #   exactly.
  #
  #   Inputs:
  #   - active_feature: <active_feature>
  #   - lessons_path: <lessons_path>
  #   - quest_dir: <quest_dir>
  #   - blueprint_lessons_path: <blueprint_lessons_path>
  #
  #   Return per the sub-agent's return contract.
fi
```

After the sub-agent returns, recover from `blocked` or schema-validation
failures by clobbering the artifact back to the canonical zero-count
template. Both failure modes leave the artifact in an untrusted state
(partial body, mutated `selected-count`, or invalid frontmatter); the same
`frontmatter.sh init` re-run resets it:

```bash
# Run after the sub-agent return is parsed. Conditional on the artifact
# existing (skips cleanly on the no-lessons-file path above).
if [[ -f "$blueprint_lessons_path" ]]; then
  if [[ "${lessons_filter_result:-success}" == "blocked" ]]; then
    echo "warning: lessons-filter blocked — reset blueprint-lessons.md to zero-count; no injection this cycle" >&2
    "$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" init blueprint-lessons \
      "$blueprint_lessons_path" \
      "FEATURE=$active_feature" \
      "LESSONS_SOURCE_MTIME=!RAW!$lessons_mtime" \
      "SELECTED_COUNT=!RAW!0"
  elif ! "$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" validate \
            "$blueprint_lessons_path" blueprint-lessons >/dev/null 2>&1; then
    echo "warning: lessons-filter wrote an invalid artifact — reset blueprint-lessons.md to zero-count; no injection this cycle" >&2
    "$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" init blueprint-lessons \
      "$blueprint_lessons_path" \
      "FEATURE=$active_feature" \
      "LESSONS_SOURCE_MTIME=!RAW!$lessons_mtime" \
      "SELECTED_COUNT=!RAW!0"
  fi
fi
```

`$lessons_filter_result` is the `Result:` line from the sub-agent return.
Parse it before the recovery block runs.

Once the recovery (if any) completes, fall through to Step 2.

### Step 2 — Regenerate `blueprints/current/` content

The content flow — write `requirements.md`, write `config.md` (auto-block + GIT BRANCH pre-fill), and generate diagrams — lives in [`docs/blueprint-regeneration.md`](../docs/blueprint-regeneration.md). Follow its Steps A, B, C with this caller context:

```bash
# Scope: PENDING items (first-time generation at stage 2).
active_item_ids="$($CLAUDE_PLUGIN_ROOT/scripts/todo.sh list PENDING --feature "$active_feature")"
```

Pass `$active_feature` and `$active_item_ids` through to the shared steps. The shared runbook handles: computing `$planned_ids`, initializing frontmatter, writing the three requirements body sections, scanning skills/rules for the config auto-block, pre-filling the GIT BRANCH section from HEAD, and rendering use-case/sequence/class diagrams with the PlantUML MCP.

After completing Steps A and B of `docs/blueprint-regeneration.md` (requirements + config generation) and before Step C (diagrams), execute Steps B.4, B.5, and B.6:

#### Step B.4 — Initialize `review-history.md` (new in v1.5)

The orchestrator at Step B.5 expects a sibling `review-history.md` to exist when `requirements.md` lives under `blueprints/current/`. It will lazily init the file itself, but doing it here gives a deterministic init point in the workflow (and ties `requirements-id` to the freshly-written `requirements.md` exactly once, rather than relying on a re-init lookup later).

```bash
review_history="$data_root/workflow-stream/$active_feature/blueprints/current/review-history.md"
if [[ ! -f "$review_history" ]]; then
  req_id="$("$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" get "$requirements_path" id 2>/dev/null)"
  "$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" init review-history "$review_history" \
    ID="$(uuidgen | tr 'A-Z' 'a-z')" \
    FEATURE="$active_feature" \
    REQUIREMENTS_ID="${req_id:-null}" \
    LAST_FINDING_ID=F-000 \
    FINDING_COUNT_TOTAL='!RAW!0' \
    FINDING_COUNT_UNRESOLVED='!RAW!0' \
    LAST_REVIEW_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi
```

Guarded on existence — re-runs of `mi-apply-impact` don't clobber an existing history (which carries unresolved findings from prior cycles that the v1.5 orchestrator's prompt-header summary will surface). `--force` cleanup above DOES wipe this file (intentional: a forced regen resets the review history along with everything else under `current/`).

#### Step B.4.5 — Write the blueprint-review-context manifest (new in v1.6)

The orchestrator at Step B.5 passes this manifest via `--reference-file`. It's a persistable artifact: `references:` lists sibling files the reviewer should see, and the body carries auto-computed counts plus an inspector-editable `## Inspector additions to the review brief` section that codex weights as trusted guidance. See `docs/blueprint-rv-context/report.md` §3.6.

```bash
bp_dir="$data_root/workflow-stream/$active_feature/blueprints/current"
impl_dir="$data_root/workflow-stream/$active_feature/implementation"
bp_review_ctx="$bp_dir/blueprint-review-context.md"
config_path="$bp_dir/config.md"
grounding_path="$impl_dir/grounding-report.md"
active_slug="$("$CLAUDE_PLUGIN_ROOT/scripts/quest.sh" current 2>/dev/null || true)"
summary_path=""
[[ -n "$active_slug" ]] && summary_path="$data_root/quest/$active_slug/summary.md"

# Build references list (only artifacts that exist + are readable, in declared order).
refs_inner=""
refs_narrative=""
sep=""
if [[ -r "$config_path" ]]; then
  refs_inner+="${sep}./config.md"; sep=", "
  add_count="$(awk '/^## Inspector Additions/{f=1;next} /^## /{f=0} f && /^- /{c++} END{print c+0}' "$config_path")"
  refs_narrative+="- \`config.md\` — ${add_count} inspector addition(s) under \`## Inspector Additions\`"$'\n'
fi
if [[ -r "$grounding_path" ]]; then
  refs_inner+="${sep}../../implementation/grounding-report.md"; sep=", "
  seam_count="$(grep -c '^### ' "$grounding_path" 2>/dev/null || echo 0)"
  refs_narrative+="- \`grounding-report.md\` — ${seam_count} seams classified by the codebase grounder"$'\n'
fi
if [[ -n "$summary_path" && -r "$summary_path" ]]; then
  # 4 levels up from blueprints/current/ to the data root (current → blueprints
  # → <feature> → workflow-stream → data root); references resolve relative to
  # the manifest's own directory.
  refs_inner+="${sep}../../../../quest/$active_slug/summary.md"; sep=", "
  refs_narrative+="- \`summary.md\` — feature digest for active cycle \`$active_slug\`"$'\n'
fi
if [[ -z "$refs_inner" ]]; then
  refs_narrative="_(no readable reference artifacts at generation time)_"
fi

# Render the manifest. Failure is non-fatal — Step B.5 falls back to no --reference-file.
if ! "$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" init blueprint-review-context "$bp_review_ctx" \
  FEATURE="$active_feature" \
  REFS_INNER="!RAW!$refs_inner" \
  REFS_NARRATIVE="$refs_narrative" 2>/dev/null; then
  echo "warning: failed to render $bp_review_ctx — auto-fire will run without --reference-file" >&2
  rm -f "$bp_review_ctx"
fi
```

The manifest is **persisted** with the rest of `blueprints/current/` so manual re-runs of `/mi-blueprint-review` (with the same `--reference-file`) reproduce the same context. Inspectors can hand-edit the body — especially the `## Inspector additions to the review brief` section — between auto-fire and a manual re-run; the next invocation picks up the edits.

#### Step B.5 — Auto-invoke `/mi-blueprint-review` on the new `requirements.md`

This is a non-blocking quality gate: an external coding agent (Codex by default) reviews `requirements.md` for consistency and per-item completeness before the inspector sees the blueprint. Findings live inline in the file as `<!-- REVIEW-FINDING -->` comments; resolved ones are cleaned up automatically.

**Expect one inspector prompt from this auto-fire (v1.6.10).** The review's Phase E is a scope-expansion gate: any finding whose fix would add mechanism the blueprint does not contain today is NOT applied automatically — the review stops and asks. Answering `none` (the default) is a perfectly good answer at stage 2; those proposals stay inline as comments, get recorded as declined, and are not re-raised by later runs. This prompt is the reason `requirements.md` no longer grows on every review, so do not suppress or auto-answer it. If the session cannot prompt, the gate applies nothing and says so.

```bash
# Skip if codex MCP server is unavailable — graceful degradation per
# docs/blueprints-review/plan.md §10.2.
if "$CLAUDE_PLUGIN_ROOT/scripts/doctor.sh" --format=json | python3 -c '
import sys, json
status = json.load(sys.stdin)
checks = status.get("checks", [])
for r in checks:
    if r.get("name") == "codex" and r.get("present"):
        sys.exit(0)
sys.exit(1)
'; then
  requirements_path="$data_root/workflow-stream/$active_feature/blueprints/current/requirements.md"
  blueprint_review_context_path="$data_root/workflow-stream/$active_feature/blueprints/current/blueprint-review-context.md"
  # v1.5 CLI: --auto-iter replaces positional <max-c-iter> <max-i-iter>. Defaults
  # (--auto-iter 3, --batch-size 3, --concurrency 3, --reasoning-effort medium) are
  # the right starting point for stage-2 auto-fire (see docs/blueprint-review-token-reduction/plan.md §11.1).
  # --scope restricts per-item enumeration to Goals only — Planned and Non-goals
  # items don't need per-item review.
  # --reference-file (v1.6): only when Step B.4.5 successfully wrote the manifest.
  # If the manifest is missing, the auto-fire still runs — without the reference block —
  # preserving the non-blocking-gate property.
  ref_flag=()
  [[ -r "$blueprint_review_context_path" ]] && ref_flag=(--reference-file "$blueprint_review_context_path")
  /mi-blueprint-review codex "$requirements_path" --scope "Goals (this cycle)" --reasoning-effort medium "${ref_flag[@]}"
  review_status="auto-reviewed by codex; any remaining findings are inline as \`<!-- REVIEW-FINDING -->\` comments"
else
  echo "warning: codex MCP unavailable — skipping stage-2 blueprint review" >&2
  review_status="(blueprint review skipped — codex MCP unavailable)"
fi
```

#### Step B.6 — Surface drift in `summary.md` and `todo-list.md`

If the review rewrote `requirements.md`, surface any drift in the cycle's `summary.md` and `todo-list.md` as a heads-up to the inspector. The millwright does NOT auto-edit either file — `summary.md` is millwright-territory but auto-editing without consent feels surprising, and `todo-list.md` is strictly inspector-territory.

```bash
quest_dir="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh dir)"
summary_path="$quest_dir/summary.md"
todo_path="$quest_dir/todo-list.md"
requirements_path="$data_root/workflow-stream/$active_feature/blueprints/current/requirements.md"

drift_report="$($CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh diff-drift \
  "$requirements_path" "$summary_path" "$todo_path" "$active_feature" 2>/dev/null || true)"

if [[ -n "$drift_report" ]]; then
  echo
  echo "The blueprint review rewrote requirements.md. Possible drift in adjacent files:"
  echo "$drift_report"
  echo
  echo "Optional: edit summary.md and todo-list.md to match before typing /mi-continue. Or proceed — neither file blocks stage 3."
fi
```

Note: `scripts/blueprint-review.sh diff-drift` is a small helper — see `scripts/blueprint-review.sh` for the implementation. It surfaces possible drift, never blocks.

After Step B.6, proceed to Step C (diagram generation) from `docs/blueprint-regeneration.md`.

### Step 3 — Hand off (no stage advance)

Do NOT call `progress.sh advance` here — `progress.sh activate` (Step 1) already set `current-stage=2`, which represents "blueprints generated, awaiting inspector approval." Stage 2 → 3 is owned by `/mi-plan-implementation` (which calls `progress.sh advance 2` after branch validation, todo promotion, and base-commit capture). Calling `advance 2` here would cause `/mi-plan-implementation` to fail with a stage mismatch on the next step.

#### Step 3.1 — Compute the stage-3 effort suggestion (soft, conditional)

The brainstorming chain at stage 3 runs in this main session and makes design decisions the rest of the cycle depends on. When this cycle has design-heavy signals, surface a soft suggestion to bump effort to `xhigh` before the inspector types `/mi-continue`. See `docs/sub-agent-profiles/plan.md` § "Main session sizing — stage 3 effort suggestion" for the rationale.

The suggestion is one-way (the millwright cannot read the current effort level), non-blocking, and fires at most once per feature cycle.

**Compute three signals** from artifacts already on disk:

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
grounding_report="$data_root/workflow-stream/$active_feature/implementation/grounding-report.md"
requirements_path="$data_root/workflow-stream/$active_feature/blueprints/current/requirements.md"

# Signal 1: any in-scope item is greenfield. Per docs/millwright-inspector-project.md § 6.2,
# cycle flavor is per-item in the report body, not persisted as a single
# overall classification — grep the body lines.
signal_greenfield=0
if [[ -f "$grounding_report" ]] && \
   grep -qiE '^- \*\*Cycle flavor:\*\* greenfield' "$grounding_report"; then
  signal_greenfield=1
fi

# Signal 2: seam-classification = mixed (frontmatter, set by codebase-grounder).
signal_mixed=0
if [[ -f "$grounding_report" ]]; then
  seam="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$grounding_report" seam-classification 2>/dev/null || echo '')"
  if [[ "$seam" == "mixed" ]]; then
    signal_mixed=1
  fi
fi

# Signal 3: design-heavy keywords in requirements.md ## Goals (this cycle).
# Bound the grep to the Goals section by extracting between its heading and
# the next top-level heading.
signal_keywords=0
if [[ -f "$requirements_path" ]]; then
  goals_block="$(awk '/^## Goals \(this cycle\)/{flag=1;next} /^## /{flag=0} flag' "$requirements_path")"
  if printf '%s' "$goals_block" | grep -qiE '\b(refactor|redesign|architecture|migrate|introduce|decouple|abstraction|schema|restructure|rewrite)\b'; then
    signal_keywords=1
  fi
fi

signal_count=$(( signal_greenfield + signal_mixed + signal_keywords ))
```

**Build the suggestion line only when ≥ 2 signals fire.** Otherwise leave `effort_suggestion=""` and skip the appended block in Step 3.2.

```bash
effort_suggestion=""
if (( signal_count >= 2 )); then
  fired=()
  (( signal_greenfield )) && fired+=("any-item-greenfield")
  (( signal_mixed ))      && fired+=("seam-classification=mixed")
  (( signal_keywords ))   && fired+=("design-heavy keyword in Goals")
  fired_list="$(IFS=' + '; printf '%s' "${fired[*]}")"
  read -r -d '' effort_suggestion <<EOF || true

---
**Effort suggestion for stage 3.** This cycle has design-heavy signals: ${fired_list}. The brainstorming chain at stage 3 runs in this main session and makes design decisions the rest of the cycle depends on. Consider \`/effort xhigh\` before typing \`/mi-continue\` for this cycle. Drop back to \`/effort high\` after stage 3 — the lighter stages (4–8) don't benefit from xhigh.

This is a suggestion, not a gate. If you've read the blueprint and the design feels straightforward, \`high\` is fine and faster.
EOF
fi
```

#### Step 3.2 — Hand-off message

When Phase E of the auto-fired review declined or kept any scope-expanding proposals, set `scope_gate_note` to one line naming the count and where they live — e.g. `"2 scope-expanding proposals from the review were not applied (declined at the gate); they remain as \`<!-- REVIEW-FINDING -->\` comments in requirements.md if you want to revisit them."` Otherwise leave it empty and omit the line entirely.

Tell the inspector (append `$effort_suggestion` only when non-empty):

> "Blueprints generated for `$active_feature` at `workflow-stream/$active_feature/blueprints/current/`. The blueprint was ${review_status}. Review `requirements.md`, `config.md`, and `diagrams/`.
>
> ${scope_gate_note}
>
> Optional: reply **`walkthrough`** and I'll go over `requirements.md` with you item by item — each item gets a one-sentence summary in plain language, a short explanation, and a concrete example, waiting for your go-ahead before moving to the next one.
>
> When ready, type **`/mi-continue`**.${effort_suggestion}"

Then stop and wait. Two accepted signals:

- **`walkthrough`** (or a natural-language equivalent — "yes, walk me through it", "explain the requirements one by one") → run Step 3.3, then return to waiting for `/mi-continue`.
- **`/mi-continue`** → the Approve Handler in `commands/mi-continue.md` (current-stage = 2) takes over: blueprint sanity check, clear-point gate, then auto-fire of `/mi-plan-implementation`.

Do NOT auto-advance to stage 3 without `/mi-continue` — this is the mandatory review gate, and the walkthrough does not substitute for it (the inspector still approves explicitly).

#### Step 3.3 — Optional requirements walkthrough (on `walkthrough`)

Purely conversational — **no `progress.md` mutation, no stage change**; the feature stays at `current-stage=2` and the walkthrough is repeatable. Append one context-ledger row at the start:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/ledger.sh append \
  "2" "/mi-apply-impact" "requirements.md" "medium" "main" \
  "requirements walkthrough" || true
```

**Enumerate the items.** Read `blueprints/current/requirements.md` once. The items are the top-level `- ` bullets under `## Goals (this cycle)`, `## Planned (future cycles)`, and `## Non-goals (out of scope)`, in file order; each item's nested sub-bullets (including its `- _In plain terms:_ … _Example:_ …` line) belong to that item, not to the enumeration. Count them as `N`.

**Present one item at a time.** For each item `i` of `N`:

```
Item <i>/<N> — <section name>

> <the item's top-level bullet, verbatim>

In one sentence: <one-sentence summary in very simple language>

<plain-language explanation>

Example: <one concrete example>
```

- **One-sentence bar:** exactly one sentence, the simplest language you can manage — what this item makes the software do, as you'd say it to someone who has never opened the codebase. No item ids, no file paths, no symbol names, no acronyms; if a term can't be avoided, it isn't the right sentence. This is the "if you read nothing else" line, so lead with the outcome, not the mechanism ("Users will be able to add several items to the cart in one go" — not "Extends the cart service with a bulk entry point"). Present it before the fuller explanation, never as a replacement for it.
- **Explanation bar:** 2–4 sentences, very simple language — no workflow or domain jargon (define any term that can't be avoided), name the real files/behaviors the item touches. Go a step deeper than both the one-sentence bar above and the item's inline `_In plain terms:_` sub-bullet — expand on them, never just repeat them.
- **Example bar:** one concrete before/after or input → observable-outcome walk-through the inspector could actually try ("you click X / call Y → today you get A; after this feature you get B"). If the inline `_Example:_` sub-bullet already covers the same case, pick a different one so the inspector gets two angles on the item.

The three bars are a ladder — one sentence, then the paragraph, then the worked example — each one a level more concrete than the last. Never collapse them into one another, and never skip the one-sentence bar because the item "is already simple".

**Then wait for the inspector before advancing.** Accepted replies:

- `next` (also empty reply, `y`, `ok`) → advance to item `i+1`.
- A question or comment about the current item → answer it from the blueprint/grounding-report context, stay on the same item, and wait again.
- `stop` → end the walkthrough early (say which items remain unreviewed).

Never present two items in one turn — the one-item-then-wait rhythm is the entire point of the walkthrough.

**Decision capture during the walkthrough.** If an inspector reply amounts to a scope decision or a change request ("drop that", "this should also cover X", "treat that module as out of scope"), act on it immediately: edit `requirements.md` on request (stage 2 owns `blueprints/current/`), or persist it to `decisions.md` under `## Stage 2 — Blueprint approval`. Do NOT rely solely on the Approve Handler's end-of-stage decisions sweep — it reviews only the last several turns, and a long walkthrough can push early decisions out of that window.

**On completion** (last item, or `stop`):

> "Walkthrough done — <covered>/<N> items covered<, <remaining> skipped via stop>. Also review `config.md` and `diagrams/` if you haven't. When ready, type **`/mi-continue`**.${effort_suggestion}"

Then stop and wait for `/mi-continue` (or another `walkthrough`) exactly as in Step 3.2.
