---
description: Render diagrams of the implementation (commit range base-commit..HEAD) into implementation/diagrams/. Inspector-invokable wrapper around mi-generate-implementation-diagrams; auto-fired by mi-continue's Review-Resume Handler when the inspector wants a diagram refresh after the review session committed new code.
argument-hint: "[--target=implementation]"
---

# mi-draw-diagrams

**User-facing diagram generator.** Generic launcher for diagram rendering against the active feature's commit range. Currently supports `--target=implementation` (the default and only mode); future targets may extend this command without churn at the call sites.

## When invoked

- **Manually** by the inspector at any point during stages 4–7 to refresh the implementation diagrams (e.g., the brainstorming review session just shipped fixes and the inspector wants to look at the updated picture before stage 8 archives it).
- **Auto-fired** by the Review-Resume Handler in `/mi-continue` (see `commands/mi-continue.md`) when the inspector answers `y` to the Step 2.5 diagram-refresh prompt.

## Preconditions

- A feature is active in `progress.md` (`active != null`).
- `active.base-commit` is set (stage 3+).
- The PlantUML MCP server is available (verified by `/mi-doctor`).

## Execution

### Step 1 — Parse `$ARGUMENTS`

```bash
target="implementation"
for arg in $ARGUMENTS; do
  case "$arg" in
    --target=*)        target="${arg#--target=}" ;;
    --target)          shift; target="$1" ;;
    *)                 echo "warn: ignoring unrecognized argument: $arg" >&2 ;;
  esac
done
```

If `target` is not `implementation`, error out:

> "Only `--target=implementation` is supported today. To regenerate requirements-level diagrams, use `/mi-update-blueprint <reason>` (which rotates the blueprint and regenerates `requirements.md` / `config.md` / `diagrams/` from the implementation)."

### Step 1.5 — Per-event diagram prompt (stage 4)

Read the diagram-prompt setting and the skip marker:

```bash
diagram_prompt="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get diagram-prompt 2>/dev/null || echo 'prompt')"
skipped="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get implementation-diagrams-skipped 2>/dev/null || echo 'false')"
```

**Branch on `(diagram_prompt, skipped)`:**

- **`diagram_prompt=auto`** — skip the prompt entirely. The inspector opted into auto-generation earlier in this feature's workflow. Proceed to Step 2 (dispatch). After dispatch succeeds, clear `implementation-diagrams-skipped=false` (in case it was set from an earlier skip).
- **`diagram_prompt=prompt` AND `skipped=true`** — recovery path: the inspector answered `n` at stage 4 earlier and is now manually invoking `/mi-draw-diagrams` to generate. Use the recovery prompt below instead of the stage-4 prompt.

  **Recovery prompt** (Phase 3.4):

  > "Stage-4 diagrams were skipped earlier this cycle. Generate them now? Reply:
  >   - `y` — delegate to a fresh sub-agent now (~30s); covers the full `base-commit..HEAD` range and clears the skip marker so stage 8 archives the diagrams.
  >   - `n` — keep the skip; stage-2 blueprint diagrams remain authoritative for this cycle."

  Optional convenience: accept a `--force` (or `--generate`) flag in `$ARGUMENTS` that bypasses the recovery prompt and proceeds to dispatch directly. Useful for scripted recovery.

  Branch on the answer:

  - **`y` (or `--force`)** — proceed to Step 2 (dispatch). After dispatch succeeds, clear the marker:
    ```bash
    $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "implementation-diagrams-skipped=false"
    ```
  - **`n`** — exit 0 with no changes. The skip remains in place.

- **`diagram_prompt=prompt` AND `skipped=false`** — fall through to the stage-4 prompt below.

**Stage-4 prompt** (offered when `diagram_prompt=prompt`):

> "Stage 4 is about to generate implementation diagrams for `<active_feature>`. Reply:
>   - `y` — generate `.puml` source files now (delegated to a fresh sub-agent; ~30s).
>   - `n` — skip diagram generation for this stage. The blueprint's stage-2 diagrams remain authoritative; review at stage 5 will reference those.
>   - `auto` — generate, and don't ask again for diagrams during the rest of this feature's workflow (resets when the next feature activates)."

Wait for the reply. Branch on the answer:

- **`y`** — proceed to Step 2 (dispatch). After the dispatch succeeds, clear the skip marker (in case it was set from an earlier skip): `progress.sh set implementation-diagrams-skipped=false`.
- **`auto`** — persist the preference, then proceed to Step 2:
  ```bash
  $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "diagram-prompt=auto"
  ```
  After the dispatch succeeds, also clear `implementation-diagrams-skipped=false`.
- **`n`** — record the skip and clean any stale directory. **Order matters for crash safety**: remove the directory FIRST, then set the marker. If a session breaks between step 1 and step 2, the next `/mi-continue` sees `implementation-diagrams-skipped=false` (default) AND no `implementation/diagrams/` directory — `diagrams-fresh` (Phase 3.4) returns `missing`, which routes to the safe diagnostic recovery path. The reverse order would leave a window where the marker says skipped but stale `.puml` files still exist, and stage 8's archival loop (`[[ -d ... ]] && mv -n ...`) would silently archive them.

  ```bash
  data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
  active_feature="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get-active)"
  impl_diagrams="$data_root/workflow-stream/$active_feature/implementation/diagrams"
  [[ -d "$impl_diagrams" ]] && rm -rf "$impl_diagrams"
  $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "implementation-diagrams-skipped=true"
  ```

  Then exit cleanly:

  > "Skipped stage-4 diagram generation. Stage-5 review will reference the stage-2 blueprint diagrams under `blueprints/current/diagrams/`. To generate later, run `/mi-draw-diagrams` again."

  Stop. Do NOT proceed to Step 2.

### Step 2 — Dispatch to the implementation generator

For `--target=implementation`, run the body of `mi-generate-implementation-diagrams.md`. This is a thin wrapper — no behavior change. The implementation generator handles:

- ensuring `implementation/change-summary.md` is current via `commits.sh change-summary-fresh` (regenerates if stale);
- reading the commit range `active.base-commit..HEAD`;
- rendering use-case, sequence, and (if relevant) class diagrams via the PlantUML MCP into `workflow-stream/$active_feature/implementation/diagrams/`;
- framing pre-existing system elements as shaded context next to the new functionality;
- writing `implementation/diagrams/README.md` with frontmatter `id: <new uuid>` + `stage: implementation` (validated against the `diagrams-readme-implementation` schema). This README intentionally does **not** carry a `requirements-id` — the requirements back-reference for the implementation lives in `implementation/change-summary.md` and the review artifacts (`inspector-review.md`, `review-context.md`).

See `commands/mi-generate-implementation-diagrams.md` for the full step-by-step recipe.

### Step 3 — Report

The implementation generator already prints its own report (`Implementation diagrams generated at $dest_dir (N diagrams). Existing-system context is shaded; new functionality is highlighted.`). Pass that through unchanged.

## Notes

- This command is the **public** name inspectors should use; `mi-generate-implementation-diagrams` remains as the **internal** implementation that the workflow's auto-firing paths invoke (the Resume Handler at stage 4, the Review-Resume Handler at stage 6 → 7, and `/mi-update-blueprint`'s diagram regeneration). Keeping both names valid means existing wiring isn't broken; new manual invocations use the simpler name.
- Diagrams under `implementation/diagrams/` are **archived at stage 8** by `mi-complete-workflow` into `blueprints/history/v[N+1]/implementation/diagrams/` alongside the rotated blueprint version (move, not delete). They live there permanently as part of the audit record so the inspector can revisit any past cycle's implementation view next to its requirements-level diagrams under `blueprints/history/v[N]/diagrams/`. (Earlier versions of this plugin deleted them at stage 8; the change to archival landed alongside the per-cycle quest folder refactor. `/mi-abort-workflow` still deletes them — an aborted cycle has no shipped work to archive.)
- The PlantUML `.svg` renders are intentionally not produced — the `.puml` source is what the inspector diffs.
