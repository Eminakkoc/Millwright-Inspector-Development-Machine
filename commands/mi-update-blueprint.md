---
description: Rotate blueprints/current/ into history with a reason, then regenerate from the implementation (codebase + base-commit..HEAD diff) plus the previous blueprint (for non-derivable sections). Manual inspector trigger.
argument-hint: "[--reason-kind <manual|spec-update>] [--force-regen] <reason summary>"
---

# mi-update-blueprint

Manual inspector-triggered blueprint refresh. Rotates the current blueprint into history with a `reason.md`, then regenerates `requirements.md`, `config.md`, `diagrams/`, and `primer.md` from:

- **The implementation** — codebase + `git diff base-commit..HEAD` — for `## Goals (this cycle)` content and the diagrams.
- **The previous blueprint** (just rotated to `history/v[<version>]/`) — for sections the implementation alone can't reconstruct: `todo-item-ids` / `todo-list-id` (frontmatter), `## Planned (future cycles)`, `## Non-goals (out of scope)`, `## GIT BRANCH`, and `## Inspector Additions`.

The v1.5 `review-history.md` sibling (when present) rotates alongside `requirements.md` into `history/v[<version>]/review-history.md` via the `blueprints.sh rotate` wildcard move — no special-case wiring required. The fresh `current/` after regeneration starts with a new empty `review-history.md` (lazily initialized by `/mi-blueprint-review` Phase A or by `mi-apply-impact` Step B.4 on the next stage-2 auto-fire).

The journal and the active cycle's quest files (`quest/<active-slug>/todo-list.md`, `quest/<active-slug>/summary.md`, `journal/`) are **not** inputs. Mid-cycle refreshes consult only what's already in the workflow's own state — the implementation describes what was actually built; the previous blueprint carries everything else forward.

Use this command when changes discussed during brainstorming or reviews need to be reflected in the blueprint and you don't want to wait for an auto-trigger (the post-chain drift prompt at stage 4 also calls this command).

## Invocation

```
/mi-update-blueprint [--reason-kind <kind>] [--force-regen] <reason summary>
```

- `--reason-kind` accepts `manual` (default) or `spec-update`. The Stage-4 drift handler in `/mi-continue` invokes this command with `--reason-kind=spec-update` so the rotation history correctly records the trigger as a stage-4 drift fire instead of a manual refresh. Other rotation kinds (`completion`, `re-spec-cascade`, `re-plan-cascade`) are produced by their owning commands (`/mi-complete-workflow`, the brainstorming review session) and are not accepted here.
- `--force-regen` discards the current `blueprints/current/` content and regenerates from the latest history version, even when `current/` is complete or partially complete. It refuses when the latest history is `completion` or a cascade (no safe parent to restore from). Used when an in-flight regeneration is corrupted and the inspector wants to start over from a known-good history snapshot. See the recovery decision tree below for the safety gates.

The reason summary is a one-line free-form description of why the blueprint is being updated (e.g., `"webhook retry logic added during brainstorming"`). Required. Becomes the `summary` field of the new `history/v[N+1]/reason.md`.

## Preconditions

- `progress.md`'s `active` is non-null (a feature is in flight). Fails fast otherwise.
- `blueprints/current/` exists with content to rotate. Fails fast otherwise.
- `active.base-commit` is non-null (stage 3 has captured it). Fails fast otherwise — without `base-commit`, the diff that drives Goals regeneration can't be computed.

## Execution

### Step 1 — Resolve active feature and guard

```bash
active_feature="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get-active)"
[[ -n "$active_feature" && "$active_feature" != "null" ]] || {
  echo "error: no active feature — /mi-update-blueprint requires an in-flight workflow" >&2
  exit 1
}
base_commit="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get base-commit)"
[[ -n "$base_commit" && "$base_commit" != "null" ]] || {
  echo "error: active.base-commit is null — /mi-update-blueprint needs a stage-3+ workflow" >&2
  exit 1
}
```

Parse `$ARGUMENTS` for the optional flags and the required reason summary:

```bash
reason_kind="manual"
force_regen=0
positional=()
# shellcheck disable=SC2206
args=($ARGUMENTS)
i=0
while [[ $i -lt ${#args[@]} ]]; do
  case "${args[$i]}" in
    --reason-kind)
      i=$((i + 1))
      reason_kind="${args[$i]:?--reason-kind requires a value (manual|spec-update)}"
      ;;
    --reason-kind=*)
      reason_kind="${args[$i]#--reason-kind=}"
      ;;
    --force-regen)
      force_regen=1
      ;;
    *)
      positional[${#positional[@]}]="${args[$i]}"
      ;;
  esac
  i=$((i + 1))
done

case "$reason_kind" in
  manual|spec-update) ;;
  *)
    echo "error: --reason-kind must be 'manual' or 'spec-update' (got '$reason_kind'). Other kinds (completion, re-spec-cascade, re-plan-cascade) are produced by their owning commands and not accepted here." >&2
    exit 1
    ;;
esac

reason_summary="${positional[*]:-}"
[[ -n "$reason_summary" ]] || {
  echo "error: reason summary required. Usage: /mi-update-blueprint [--reason-kind <kind>] [--force-regen] <reason summary>" >&2
  exit 1
}
```

### Step 1.5 — Recovery decision tree (closes F2)

`/mi-update-blueprint` is a stage-3+ command, so all `check-current` calls in this command use `--require-primer`. A recovered/regenerated `current/` tree is not complete until `primer.md` has been regenerated alongside the rest.

This decision tree runs **before** Step 2's rotate so a partial state from a previously-interrupted run cannot get archived into history. The tree is unconditional on partial state: even with `--force-regen`, a partial `current/` is never silently rotated. In every sub-case, `blueprints.sh rotate` is NOT called on a partial `current/`.

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
hist="$data_root/workflow-stream/$active_feature/blueprints/history"
curr="$data_root/workflow-stream/$active_feature/blueprints/current"

# Helper: print the single .partial directory if exactly one exists; empty otherwise.
single_partial() {
  local matches
  matches=$(ls -d "$hist"/v[0-9]*.partial 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$matches" == "1" ]]; then
    ls -d "$hist"/v[0-9]*.partial 2>/dev/null
  fi
}

# Helper: count partial directories (both shapes).
total_partials_count() {
  local p t
  p=$(ls -d "$hist"/v[0-9]*.partial 2>/dev/null | wc -l | tr -d ' ')
  t=$(ls -d "$hist"/v[0-9]*.partial.tmp 2>/dev/null | wc -l | tr -d ' ')
  echo $((p + t))
}

# Helper: latest finalized version + reason kind.
latest_finalized() {
  ls -d "$hist"/v[0-9]* 2>/dev/null \
    | grep -vE '\.(partial|partial\.tmp)$' \
    | sed -n 's|.*/v\([0-9]\+\)$|\1|p' \
    | sort -n | tail -1
}
latest_kind() {
  local v
  v="$(latest_finalized)"
  [[ -n "$v" ]] || { echo ""; return; }
  $CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get \
    "$hist/v${v}/reason.md" kind 2>/dev/null || echo ""
}

# Helper: run check-current --require-primer; print exit code.
check_current_status() {
  if "$CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh" check-current --require-primer "$active_feature"; then
    echo 0
  else
    echo $?
  fi
}

# Initialize the routing flag. After this block, $skip_rotate==1 means Step 2 is skipped
# (the recovery has already given us a $version and a current/ tree to regenerate from).
skip_rotate=0

# 1. Multiple partials → STOP unconditionally.
if [[ "$(total_partials_count)" -gt 1 ]]; then
  echo "error: ambiguous partial rotations under $hist (count > 1). Manual reconciliation required; no state was modified." >&2
  exit 1
fi

# 2. Exactly one .partial: kind-matched recovery, or STOP.
partial_dir="$(single_partial)"
if [[ -n "$partial_dir" ]]; then
  if [[ ! -f "$partial_dir/reason.md" ]]; then
    echo "error: partial $partial_dir has no reason.md (old/unknown partial). No state was modified; manual cleanup required." >&2
    exit 1
  fi
  partial_kind="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$partial_dir/reason.md" kind 2>/dev/null || echo "")"
  if [[ "$partial_kind" != "$reason_kind" ]]; then
    echo "error: a $partial_kind blueprint rotation is already in progress at $partial_dir." >&2
    echo "Re-run the command that owns that reason kind, or inspect and repair the partial manually. No state was modified." >&2
    exit 1
  fi
  # Resume the partial, then proceed straight to Step 4 regeneration (skip Step 2 rotate).
  version="$($CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh resume-partial "$active_feature" --expected-kind "$reason_kind")"
  $CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh ensure-current "$active_feature"
  skip_rotate=1
  echo "Step 1.5: resumed partial → history/v${version}/; proceeding to Step 4 regeneration."
fi

# 3. No partial — examine check-current state and latest history reason kind.
if [[ "$skip_rotate" != "1" ]]; then
  cc_status="$(check_current_status)"
  last_kind="$(latest_kind)"
  latest_v="$(latest_finalized)"

  if [[ "$cc_status" == "1" && ( "$last_kind" == "manual" || "$last_kind" == "spec-update" ) ]]; then
    # Empty/scaffold-only current with a safe parent: resume regeneration without a fresh rotate.
    $CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh ensure-current "$active_feature"
    version="$latest_v"
    skip_rotate=1
    echo "Step 1.5: check-current=1 with safe parent (kind=$last_kind); resuming regeneration from history/v${version}/."

  elif [[ "$cc_status" == "2" ]]; then
    # UNCONDITIONAL stop on partial regeneration content (closes F2).
    if [[ "$force_regen" == "1" ]]; then
      if [[ "$last_kind" == "manual" || "$last_kind" == "spec-update" ]]; then
        echo "Step 1.5: --force-regen on partial state (check-current=2). Discarding current/ and regenerating from history/v${latest_v}/ (kind=$last_kind)."
        # Empty current/ then ensure-current scaffolding.
        if [[ -d "$curr" ]]; then
          shopt -s dotglob nullglob
          for entry in "$curr"/*; do rm -rf "$entry"; done
          shopt -u dotglob nullglob
        fi
        $CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh ensure-current "$active_feature"
        version="$latest_v"
        skip_rotate=1
      else
        echo "error: current/ has partial regenerated content (check-current=2) AND no manual/spec-update history version exists to restore from. Latest history is '$last_kind'." >&2
        echo "Manual cleanup required:" >&2
        echo "  - Inspect current/, edit it into a structurally valid state, and re-run /mi-update-blueprint <reason> normally." >&2
        echo "  - OR rm -rf current/* and re-run /mi-apply-impact (if you want to regenerate from scratch via stage 2)." >&2
        echo "No state was modified." >&2
        exit 1
      fi
    else
      echo "error: current/ has partial regenerated content from a prior interrupted run (check-current=2). Re-running rotate would archive this partial state." >&2
      echo "Options:" >&2
      echo "  /mi-update-blueprint --force-regen <reason>  — discards current/ and regenerates from history (only valid when latest history is manual or spec-update)." >&2
      echo "  Manually inspect/edit current/ until it's complete or empty, then re-run /mi-update-blueprint with the appropriate flag." >&2
      echo "No state was modified." >&2
      exit 1
    fi

  elif [[ "$cc_status" == "1" && ( "$last_kind" == "completion" || "$last_kind" == "re-spec-cascade" || "$last_kind" == "re-plan-cascade" ) ]]; then
    # Empty current with a non-safe parent — confused state, not auto-recovered here.
    echo "error: blueprints/current is empty/scaffold-only and the latest history version has reason.kind='$last_kind' (no safe manual/spec-update parent to resume from). This is a confused state; run /mi-resume-workflow for diagnosis." >&2
    exit 1

  elif [[ "$cc_status" == "1" ]]; then
    # Empty/scaffold-only current with no readable parent (e.g., no history at all).
    echo "error: blueprints/current/ is empty or scaffold-only, but there is no safe manual/spec-update history version to resume regeneration from. No rotation was performed." >&2
    echo "Inspect blueprints/history/ and repair any missing or malformed reason.md, or rerun /mi-apply-impact if this feature should be regenerated from stage 2." >&2
    exit 1

  elif [[ "$cc_status" == "0" && "$force_regen" == "1" ]]; then
    # Complete current/ + --force-regen: intentional override of "blueprints already complete".
    if [[ "$last_kind" == "manual" || "$last_kind" == "spec-update" ]]; then
      echo "Step 1.5: --force-regen on complete state. Discarding current/ and regenerating from history/v${latest_v}/ (kind=$last_kind)."
      shopt -s dotglob nullglob
      for entry in "$curr"/*; do rm -rf "$entry"; done
      shopt -u dotglob nullglob
      $CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh ensure-current "$active_feature"
      version="$latest_v"
      skip_rotate=1
    else
      echo "error: --force-regen requires a manual/spec-update history version to restore from. Latest history is '$last_kind'. Refused." >&2
      exit 1
    fi
  fi
  # cc_status == 0 without --force-regen: fall through to the normal forward path (Step 2 rotate).
fi
```

### Step 2 — Rotate blueprint to history

(Skipped when Step 1.5 set `skip_rotate=1` — the recovery already supplied a `$version` and a scaffolded `current/` tree.)

```bash
if [[ "$skip_rotate" != "1" ]]; then
  version="$($CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh rotate "$active_feature" \
    --reason-kind "$reason_kind" \
    --reason-summary "$reason_summary")"
  echo "Previous blueprint archived into history/v${version} (kind=$reason_kind)"
fi
```

After this step, `blueprints/current/` is empty and `blueprints/history/v[<version>]/` holds the previous `requirements.md`, `config.md`, `diagrams/`, and the new `reason.md`.

### Step 3 — Recreate the empty `current/` tree

(Skipped when Step 1.5 already ran `ensure-current` as part of the recovery branch.)

```bash
if [[ "$skip_rotate" != "1" ]]; then
  $CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh ensure-current "$active_feature"
fi
```

### Step 4 — Regenerate `blueprints/current/` content

The previous blueprint is now at `history/v[<version>]/` and the implementation is in `base-commit..HEAD`. Reconstruct `current/` by re-deriving Goals + diagrams from the code, and copying everything else forward from history.

#### Step 4a — Read context (AI work)

Resolve the data root and the path to the just-rotated previous `requirements.md` up front. Both are needed by the change-summary regen path below (which uses `$prev_req` to read the previous `id`) and by Step 4b (which carries `todo-list-id` and `todo-item-ids` forward).

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
prev_req="$data_root/workflow-stream/$active_feature/blueprints/history/v${version}/requirements.md"
```

Read into working memory:

- **Previous `requirements.md`:** `$prev_req` (default `data_root` is `millwright-inspector`). Capture the frontmatter (`id`, `todo-list-id`, `todo-item-ids`) and the bodies of `## Planned (future cycles)` and `## Non-goals (out of scope)` (verbatim — these are preserved as-is).
- **Previous `config.md`:** `$data_root/workflow-stream/$active_feature/blueprints/history/v${version}/config.md`. The `## GIT BRANCH` and `## Inspector Additions` sections are preserved at Step 4d via `blueprints.sh preserve-inspector-sections` — you don't need to copy them by hand.
- **Implementation reality (cached):**

  Use `implementation/change-summary.md` as the source of truth for what the implementation delivers. The same artifact backs `mi-generate-implementation-diagrams` so the analysis runs once per `base-commit..HEAD` range. **Cache contract (load-bearing — do NOT bypass):** the `change-summary-fresh` check is the gate that prevents this command and `mi-generate-implementation-diagrams` from independently re-walking the codebase for the same `(base-commit, HEAD)` range. A future change that reads `change-summary.md` directly without the freshness gate would re-introduce the double-walk this cache exists to prevent.

  ```bash
  if $CLAUDE_PLUGIN_ROOT/scripts/commits.sh change-summary-fresh "$active_feature"; then
    echo "change-summary.md is current — reading from cache"
  else
    echo "change-summary.md missing or stale — regenerating before reading"
    # See `commands/mi-generate-implementation-diagrams.md` Step 2.2 (main:
    # init) + the implementation-analyst sub-agent's Phase 1 (body fill) for
    # the canonical recipe. mi-update-blueprint.md inlines an equivalent
    # main-side recipe below rather than spawning the sub-agent — this command
    # runs alongside other main-context work that already references the
    # diff hunks, so a sub-agent dispatch here would not save context.
  fi
  ```

  When regeneration is needed, follow the same recipe documented in `mi-generate-implementation-diagrams.md` Step 2.2 (main-side init) plus the implementation-analyst sub-agent's Phase 1 (body fill); the inlined block below is the equivalent main-side path used here:

  ```bash
  base_commit_sha="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get base-commit)"
  head_sha="$(git rev-parse HEAD)"
  # Note: requirements.md hasn't been written yet at this step in mi-update-blueprint,
  # so use the previous requirements.md's id for now. Step 5 (review.sh sync-refs)
  # re-points the requirements-id after the new requirements.md is written in 4b.
  prev_req_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$prev_req" id)"
  $CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init change-summary \
    "$data_root/workflow-stream/$active_feature/implementation/change-summary.md" \
    "REQUIREMENTS_ID=$prev_req_id" \
    "FEATURE=$active_feature" \
    "BASE_COMMIT=$base_commit_sha" \
    "HEAD=$head_sha"
  $CLAUDE_PLUGIN_ROOT/scripts/commits.sh changed-files "$active_feature"
  ```

  Then fill the body of `change-summary.md` per its template guide (`## Range`, `## Changed files`, `## Detected entrypoints`, `## Suspected flows`, `## Omitted from analysis`), applying the bounded context policy embedded in the implementation-analyst sub-agent prompt at `mi-generate-implementation-diagrams.md` Step 2.3 / Phase 1 (diff hunks first; ≤ 3 callers/callees per file; skip generated/vendor/lock; record skips).

  Goals re-derivation in Step 4b reads from `change-summary.md` plus targeted diff hunks for the entrypoints it lists. Do NOT re-walk the whole codebase here.

- **Codebase context** for skills/rules summaries: re-scan `.claude/skills/` and `.claude/rules/` (used at Step 4d).

**Hard exclusion:** never read `blueprints/current/diagrams/*.svg` or `blueprints/history/*/diagrams/*.svg`. The `.puml` sources carry the same information at a fraction of the size.

#### Step 4b — Write the new `requirements.md`

```bash
new_req="$data_root/workflow-stream/$active_feature/blueprints/current/requirements.md"
# $prev_req is already set in Step 4a.

# Carry these from prev — they identify which todo items initiated the cycle and
# survive blueprint refreshes (todo state hasn't changed mid-cycle).
prev_todo_list_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$prev_req" todo-list-id)"
# `frontmatter.sh get todo-item-ids` returns a YAML array literal like
# `[PAY-001, AUD-002]`. The requirements template has `todo-item-ids:
# [{{TODO_ITEM_IDS}}]` (already wrapped in flow brackets), so strip the
# outer `[ ]` from the captured value before substituting — otherwise the
# template would produce `[[PAY-001, AUD-002]]`, a nested array that the
# requirements schema rejects (items must be strings, not arrays).
prev_todo_item_ids_csv="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$prev_req" todo-item-ids \
  | sed -E 's/^\[//; s/\]$//')"

$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init requirements "$new_req" \
  "TODO_LIST_ID=$prev_todo_list_id" \
  "TODO_ITEM_IDS=$prev_todo_item_ids_csv" \
  "FEATURE=$active_feature"
```

Then write the body using `Edit`. Three sections, in this order:

1. **`## Goals (this cycle)`** — **re-derive from the implementation.** Each goal item references the IMPLEMENTING todo IDs from the preserved `todo-item-ids` and describes what the code actually does. Use the diff + unchanged-side context to write accurate acceptance criteria, including any drift from the original spec (new fields, new endpoints, refactored boundaries — whatever the chain decided to do). **Same altitude rule as stage-2 (`docs/blueprint-regeneration.md` Step A):** name the seam the implementation landed on (the actual folder / module / layer that received the new code) and the integration shape, but do not paste in code-level specifics — function signatures, payload schemas, and table columns belong in `change-summary.md`, not in `requirements.md`. Goals are a high-level description of *what was built and where it lives*, mirroring the stage-2 sketch with the implementation reality substituted in.

2. **`## Planned (future cycles)`** — **copy verbatim** from the previous `requirements.md`. The implementation has no signal about future work; the inspector's planned roadmap survives unchanged. Skip the section entirely if the previous file didn't have one (no planned items).

3. **`## Non-goals (out of scope)`** — **copy verbatim** from the previous `requirements.md`. The implementation can't tell you what was deliberately excluded. Skip the section entirely if the previous file didn't have one.

   **Then fold in scope-exclusion decisions from `decisions.md`** (per `docs/clear-points/plan.md` §9.5). Read `$data_root/workflow-stream/$active_feature/decisions.md` (if exists), use the same body extraction as `mi-plan-implementation` Step 3.5 (Python helper that strips HTML-comment placeholder blocks and keeps only stage sections with real bullet entries), and append any bullets that read as scope exclusions — e.g., "treat `<module>` as out-of-scope", "don't touch `<area>`", "exclude `<concern>` from this cycle" — as additional Non-goal bullets. Preserve the source attribution: prefix each appended bullet with `(decisions.md, Stage <N>):`. Bullets that aren't scope-exclusion-shaped (instruction-shaped, seam-pick-shaped) belong in `config.md` `## Inspector Additions` instead — see Step 4d. The original entries remain untouched in `decisions.md` (it is excluded from history rotation per §9.2).

**Plain-language explanation after every item (reader aid).** As in stage-2 (`docs/blueprint-regeneration.md` Step A), directly beneath **each** item in all three sections add a **nested** sub-bullet — `- _In plain terms:_ <plain-language restatement>. _Example:_ <concrete example>.` — that restates the item in everyday language with one concrete example. It must be a nested (2-space-indent) sub-bullet so the blueprint reviewer treats it as part of the item, and it is non-normative (a reader aid only — introduce no new requirements or scope in it). For the `## Goals` items, describe what was actually built; for the verbatim-copied `## Planned` / `## Non-goals` items, carry over (or add, if the previous file predates this convention) a matching plain-terms line.

The frontmatter `commits` array stays empty — `mi-complete-workflow` populates it at stage 8.

#### Step 4c — Write the new `config.md`

```bash
new_cfg="$data_root/workflow-stream/$active_feature/blueprints/current/config.md"
new_req_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$new_req" id)"
# Resolve the cumulative lessons-learned file (see docs/blueprint-regeneration.md
# Step B). The config template's `## Lessons learned` section needs this token —
# omitting it would render a literal {{LESSONS_LEARNED_PATH}} placeholder.
lessons_path="$($CLAUDE_PLUGIN_ROOT/scripts/lessons.sh path)"
if [[ -f "$lessons_path" ]]; then lessons_token="$lessons_path"; else lessons_token="(none yet)"; fi
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init config "$new_cfg" \
  "REQUIREMENTS_ID=$new_req_id" \
  "LESSONS_LEARNED_PATH=$lessons_token"
```

Then, using `Edit`, fill the auto-section (between `<!-- auto:start -->` and `<!-- auto:end -->`) with summaries of the relevant skills and rules from `.claude/skills/` + `.claude/rules/`.

Same relevance filter, budget, and three-section structure as `docs/blueprint-regeneration.md` Step B:

- ≤ 10 entries combined across `## Skills`, `## Rules`, and `## Load on demand`; ≤ 2 lines each; always cite the canonical path.
- `## Skills` and `## Rules` carry only the entries likely to be consulted up front for the regenerated Goals.
- `## Load on demand` carries situational entries that may apply if a related concern surfaces; the chain opts in only when needed.
- Off-topic skills/rules are omitted entirely — they remain discoverable via `.claude/skills/` and `.claude/rules/`.

Leave `## GIT BRANCH` and `## Inspector Additions` empty / template-only here — Step 4d copies the previous content into them.

#### Step 4d — Restore inspector-authored sections

```bash
$CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh preserve-inspector-sections "$active_feature" "$version"
```

This reads `## GIT BRANCH` and `## Inspector Additions` bodies from `history/v[<version>]/config.md` and splices them into the matching headings in the new `current/config.md`. Headings stay; only the bodies are replaced. If those sections were empty in the previous file, the new file's matching sections are left as-is (template-empty).

**Then — and ONLY after `preserve-inspector-sections` runs — fold in instruction/constraint decisions from `decisions.md`.** Critical ordering point (per `docs/clear-points/plan.md` §10 step 4a): a fold-in placed *before* the preserve step would be silently overwritten when `preserve-inspector-sections` splices the historical body in. The correct sequence is: (1) `preserve-inspector-sections` restores the prior `## Inspector Additions` from history; (2) the fold-in then APPENDS decision-derived bullets after the preserved content.

```bash
decisions_file="$data_root/workflow-stream/$active_feature/decisions.md"
if [[ -f "$decisions_file" ]]; then
  # Same body extraction as mi-plan-implementation Step 3.5 — strips HTML-
  # comment placeholders, keeps only stage sections with real bullets.
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
fi
```

If `decisions_body` is non-empty, use `Edit` against `$new_cfg` to append the instruction/constraint-shaped bullets to `## Inspector Additions` (after whatever `preserve-inspector-sections` restored). Apply the same routing rule as Step 4b: bullets that read as instructions / constraints / seam picks (e.g., "use fixture Z", "land G3 in `refresh.ts`", "always call `helper()` before `commit()`") go here; bullets that are pure scope exclusions stay in requirements.md Non-goals (Step 4b). Prefix each appended bullet with `(decisions.md, Stage <N>):` for source attribution. The original entries remain in `decisions.md` unchanged.

If `decisions_body` is empty (no decisions or all-placeholder), skip the fold-in entirely. `## Inspector Additions` is left exactly as `preserve-inspector-sections` restored it.

#### Step 4e — Regenerate diagrams

Generate diagrams into `$data_root/workflow-stream/$active_feature/blueprints/current/diagrams/` (default `data_root` is `millwright-inspector`) per `docs/millwright-inspector-project.md` § "Diagram conventions":

- **Mandatory**: one `use-case-<feature>.puml`.
- **Conditional**: 2–3 `sequence-<flow>.puml`, one per significant end-to-end flow in the regenerated `requirements.md`. Render 1 only if the implementation genuinely has a single flow; never more than 3.
- **Optional, at most one**: either `class-<domain>.puml` OR `component-<subject>.puml`, never both. Use the seam classification carried forward from the previous `requirements.md` Goals items. The slot fires only when the seam is `backend` or `mixed` AND the content threshold is met (3+ classes with non-trivial relationships → class; 3+ components with non-trivial dependencies → component; linear chains don't qualify either way; pure UI / infra seams skip the slot). Apply the one-sentence test before rendering.

Use the `plantuml` MCP to render each diagram; save the `.puml` source. Also write a `diagrams/README.md` with the new `requirements-id` back-reference. Generate a fresh `id:` UUID for the README via `scripts/uuid.sh` and write it alongside `requirements-id`:

```bash
diagrams_readme="$data_root/workflow-stream/$active_feature/blueprints/current/diagrams/README.md"
new_drmd_id="$($CLAUDE_PLUGIN_ROOT/scripts/uuid.sh)"
cat > "$diagrams_readme" <<EOF
---
id: $new_drmd_id
requirements-id: $new_req_id
---

# Diagrams

(one-line description per .puml file in this folder)
EOF
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh validate "$diagrams_readme" diagrams-readme-blueprint >/dev/null
```

This satisfies `blueprints.sh check-current`'s `diagrams-readme-blueprint` validation requirement (the README's `requirements-id` must match `requirements.md.id`). The `id:` field follows Rule 2 of the workflow spec (every canonical artifact carries a UUID).

**Apply the existing-vs-new framing convention** (see `docs/millwright-inspector-project.md` § "Diagram conventions" and the canonical PlantUML snippets in `commands/mi-generate-implementation-diagrams.md` § "Existing-vs-new convention"). Mid-cycle blueprint regeneration is implementation-driven, so the baseline matches the stage-4 implementation diagrams: `existing` = the codebase at `active.base-commit`; `new` = `base-commit..HEAD`. The requirements-level diagrams under `blueprints/current/diagrams/` and the implementation-level diagrams under `implementation/diagrams/` should look very similar after this command runs — that's intentional, since both are now describing the same implemented reality through the same visual convention. They diverge again only when subsequent brainstorming/review work shifts requirements before the next rotation.

#### Step 4f — Regenerate `primer.md`

The just-rotated history version carried its own primer; the regenerated `current/` needs a fresh one pointing at the new `requirements.md` UUID. Branch and base-commit are already settled (this command runs mid-cycle — stage 3+ — so `progress.md` has both).

```bash
primer_dest="$data_root/workflow-stream/$active_feature/blueprints/current/primer.md"
new_req_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$new_req" id)"
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init primer "$primer_dest" \
  "REQUIREMENTS_ID=$new_req_id" \
  "FEATURE=$active_feature" \
  "DATA_ROOT=$data_root"
```

Then fill the body via `Edit`. Resolve values up front (the body has no token substitution beyond frontmatter):

```bash
primer_branch="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get branch)"
primer_base_commit="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get base-commit)"
implementing_ids="$($CLAUDE_PLUGIN_ROOT/scripts/todo.sh list IMPLEMENTING --feature "$active_feature")"
```

Then write each section per the same guide as `mi-plan-implementation` Step 3.5:

- `## Active scope` — `branch: <primer_branch>`, `base-commit: <primer_base_commit>`, one bullet per id in `implementing_ids` (description from the active cycle's `todo-list.md`; resolve via `quest.sh dir`).
- `## Goals (this cycle)` — 5–20 line excerpt from the new `requirements.md` `## Goals (this cycle)` (re-derived from the implementation in Step 4b).
- `## Journal context (active feature)` — 5–20 line digest from the active cycle's `summary.md` `## Feature: <active_feature>` plus relevant `## Cross-cutting constraints`.
- `## Likely-relevant skills & rules` — ≤ 5 entries from the new `config.md` auto-block (Step 4c).
- **`## Decisions`** — apply the same fold-in as `mi-plan-implementation` Step 3.5: read `decisions.md` (if exists), extract real-bullet stage sections via the Python helper, replace the `_(none recorded)_` placeholder line in the rendered primer's `## Decisions` section with the extracted body. If `decisions.md` is absent or every section is placeholder-only, leave `_(none recorded)_` untouched. **Do NOT delete the `## Decisions` heading itself.** Mandatory — same rationale as Step 3.5 (the chain inherits decisions only through primer.md).

The `## On-demand canonical files` section is template-emitted and does not need editing.

### Step 5 — Sync review files to new UUIDs

```bash
$CLAUDE_PLUGIN_ROOT/scripts/review.sh sync-refs "$active_feature"
```

This updates any existing `inspector-review.md` frontmatter to point at the newly-regenerated `requirements.md` id. Silently skips when the review file doesn't exist.

### Step 6 — Report

Tell the inspector:

> "Blueprint for `$active_feature` rotated to `history/v${version}/` (reason: `<summary>`) and regenerated from the implementation. Review the refreshed `requirements.md`, `config.md`, `diagrams/`, and `primer.md` under `blueprints/current/`. Inspector-authored sections (`## GIT BRANCH`, `## Inspector Additions`) and roadmap sections (`## Planned`, `## Non-goals`) are preserved from the previous version. Any in-flight review file has been re-pointed at the new requirements UUID."

## Notes

- Does **not** touch the active cycle's `todo-list.md`. Blueprint updates and todo edits are independent — use `/mi-update-todo-list` for todo changes.
- Does **not** read the active cycle's `todo-list.md` or `summary.md` (under `quest/<slug>/`), nor `journal/`. Mid-cycle refreshes are reverse-engineered from the implementation; the journal and quest are intake artifacts that don't drift after stage 1.5.
- Does **not** cascade into brainstorming / writing-plans / executing-plans. This is a pure refresh of the blueprint content; it does not re-run the chain.
- Does **not** change `progress.md`'s `active.current-stage` or any runtime flags. The workflow stays where it was.
- Cannot be invoked at stage 2 — there's no implementation to derive Goals from yet. Use `/mi-apply-impact` for stage-2 first-time blueprint generation.

## Delegation (optional)

When `change-summary.md` needs regeneration in Step 4a and the diff touches many areas, the body-fill is a good delegation candidate (see `docs/millwright-inspector-project.md` § "Delegation guidance"). One sub-agent at "strong code-analysis, high effort" tier; output artifact is `implementation/change-summary.md`; the chat reply stays under 20 lines per the contract. The millwright then proceeds with Step 4b reading from the just-written artifact. When the cache is fresh, no delegation is needed.
