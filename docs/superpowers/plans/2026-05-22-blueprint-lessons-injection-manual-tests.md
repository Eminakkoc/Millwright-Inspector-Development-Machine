# Blueprint-lessons injection — manual test scenarios

The automated harness at `tests/blueprint-lessons/run.sh` covers what can be
checked by shell alone: schema validation, template init, sibling-detection
contract, `--force` cleanup, archive allowlist. The scenarios below require
a live sub-agent invocation and are exercised by hand against a real
workflow.

For each scenario, you'll need a project with the plugin installed, a
populated `journal/`, and an inspector ready to drive `/mi-run` and
`/mi-continue`.

## Scenario 1 — Lessons file absent (graceful skip)

Setup:
- Fresh data root with no `lessons-learned.md`.

Steps:
- Run a normal `/mi-run` → `/mi-continue` flow through stage 2.

Assertions:
- No `workflow-stream/<feature>/implementation/blueprint-lessons.md` is
  written.
- Stage 2 completes; `/mi-blueprint-review` runs and its reviewer prompts
  contain no `## Lessons from prior PR reviews to honor` heading (check
  the codex MCP request body if it's logged, or trust that
  `lessons_block` was empty per the sibling-detection rule).
- The Step A backfill block prints no warning (it's guarded on the
  artifact existing).

## Scenario 2 — Lessons present, zero blueprint-relevant

Setup:
- `lessons-learned.md` with 2–3 lessons whose body is clearly code-level
  (e.g. "always use prepared statements", "lock files before fsync") and
  not blueprint-creation-related.

Steps:
- Run through stage 2.

Assertions:
- `blueprint-lessons.md` exists; `selected-count: 0`.
- The `## Selected lessons` body is literally empty.
- The codex review prompt for both phases contains no
  `## Lessons from prior PR reviews to honor` heading (lessons_block
  resolved to empty because `selected-count == 0`).

## Scenario 3 — Lessons present, ≥ 1 selected

Setup:
- `lessons-learned.md` with at least one entry whose body is plausibly
  about blueprint creation (e.g. "Goals items must name the existing seam
  rather than describing intent abstractly").

Steps:
- Run through stage 2.

Assertions:
- `blueprint-lessons.md` exists; `selected-count >= 1`.
- The `## Selected lessons` body has one `### L-NNN` block per picked
  entry, each with a `relevance:` line tying it to a concrete todo item
  id or constraint.
- After Step A writes `requirements.md`, `blueprint-lessons.md`'s
  `requirements-id` frontmatter field is no longer `null` — it matches
  the freshly-written requirements file's `id`.
- The codex review prompt for both phases contains the
  `## Lessons from prior PR reviews to honor` heading with the lesson's
  verbatim body.

## Scenario 4 — lessons-filter blocked (manual injection)

This is the trickiest scenario to exercise. The sub-agent itself decides
when to return `Result: blocked`. The cleanest hand-driven approximation:

Setup:
- Make `lessons-learned.md` syntactically broken (e.g., dangling `## L-`
  block with no body, or invalid YAML frontmatter).
- Run through stage 2.

Expected behavior:
- The `lessons-filter` sub-agent will either return `Result: blocked` or
  attempt to write an invalid artifact.
- Main's recovery logic re-runs `frontmatter.sh init blueprint-lessons`,
  resetting the file to zero-count + empty body.
- A warning is printed: either `lessons-filter blocked — …` or
  `lessons-filter wrote an invalid artifact — …`.
- `blueprint-lessons.md` ends up with `selected-count: 0` and an empty
  `## Selected lessons` body.
- The rest of stage 2 (Step A, B, B.5, C) completes normally.

## Scenario 5 — Manual /mi-blueprint-review on arbitrary file

Setup:
- Pick any markdown file in the workspace that is NOT under
  `workflow-stream/<feature>/blueprints/current/`.

Steps:
- Run `/mi-blueprint-review codex 3 5 <that file path>`.

Assertions:
- Sibling-detection finds no artifact; `lessons_block` resolves to empty.
- The reviewer prompts render exactly as they did before this feature —
  no `## Lessons from prior PR reviews to honor` heading anywhere.
- The command completes without error.

## Scenario 6 — Stage 8 archive

Setup:
- Drive a feature cycle to completion (`/mi-continue` through stage 8).

Assertions:
- After `/mi-complete-workflow` finishes,
  `workflow-stream/<feature>/blueprints/history/v[N+1]/implementation/blueprint-lessons.md`
  exists and is byte-equal to the pre-rotation
  `implementation/blueprint-lessons.md`.
- The live `implementation/` folder no longer contains
  `blueprint-lessons.md` (it was moved, not copied).
