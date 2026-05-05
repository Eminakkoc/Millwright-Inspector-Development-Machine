---
description: Launch brainstorming → writing-plans → executing-plans chain for the active feature. Stage 3 launcher — does NOT drive the chain.
---

# mo-plan-implementation

**Stage 3 launcher.** A pure launcher — primes the brainstorming skill with context, then returns control. The brainstorming → writing-plans → executing-plans / subagent-driven-development → finishing-a-development-branch chain runs as an isolated interactive session driven by the overseer. No mo-workflow commands are expected during the chain.

## Invocation

The millwright auto-invokes this command when the overseer types `/mo-continue` after the stage-2 hand-off message from `mo-apply-impact` (the Approve Handler in `commands/mo-continue.md` validates the blueprint files and chains into this command). The overseer does **not** type `/mo-plan-implementation` in the happy path.

The command remains manually invokable for recovery — for example after `/mo-abort-workflow` (to retry stage 3 without regenerating blueprints) or when `/mo-resume-workflow` recommends it explicitly.

Because stage 3 has several non-trivial side effects (todos → IMPLEMENTING, `base-commit` captured, planning-mode persisted, brainstorming chain launched OR direct implementation begun), the millwright must **never** auto-fire this command on a timer, heuristic, or inferred signal. The overseer's explicit `/mo-continue` at the stage-2 review gate (which the Approve Handler turns into this command's invocation) is mandatory.

## Preconditions

- Stage 2 is complete: `blueprints/current/requirements.md`, `config.md`, and `diagrams/` exist.
- `config.md`'s `## GIT BRANCH` section declares the primary feature branch (see Step 2 below — if empty, this command prompts before advancing).
- The overseer has reviewed the blueprint and typed `/mo-continue` (which auto-fires this command via the Approve Handler), or has typed the command manually for recovery.

## Execution

### Step 1 — Determine the active feature and check for re-entry

```bash
active_feature="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get-active)"
[[ -n "$active_feature" && "$active_feature" != "null" ]] || {
  echo "error: no active feature — run /mo-apply-impact first" >&2; exit 1; }

current_stage="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get current-stage)"
sub_flow="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get sub-flow)"
base_commit_persisted="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get base-commit 2>/dev/null || echo 'null')"
```

**Re-entry guard (Item 3 of the v11 plan).** If `current-stage == 3` and `sub-flow` is `chain-in-progress` or `resuming`, this is a re-entry into stage 3 (the chain was previously launched and the overseer is re-running this command for recovery). Validate `primer.md` and the planning-mode persistence; do NOT re-capture `base-commit` or `history-baseline-version`.

```bash
re_entry=0
if [[ "$current_stage" == "3" && ( "$sub_flow" == "chain-in-progress" || "$sub_flow" == "resuming" ) ]]; then
  re_entry=1
  echo "Re-entry into stage 3 detected (sub-flow=$sub_flow). Validating primer.md; preserving base-commit and history-baseline-version."
  # primer.md validation happens in Step 3.5; if missing/incomplete, regenerate.
  planning_mode_persisted="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get planning-mode 2>/dev/null || echo 'none')"
  base_commit_for_check="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get base-commit 2>/dev/null || echo '')"
  commit_count_since_base=0
  if [[ -n "$base_commit_for_check" && "$base_commit_for_check" != "null" ]]; then
    commit_count_since_base="$(git rev-list --count "$base_commit_for_check..HEAD" 2>/dev/null || echo 0)"
  fi
  # Skip the planning-mode prompt iff already persisted AND the chain produced commits.
  if [[ "$planning_mode_persisted" != "none" && "$commit_count_since_base" -gt 0 ]]; then
    skip_planning_prompt=1
    echo "planning-mode already persisted as '$planning_mode_persisted' and base-commit..HEAD has $commit_count_since_base commits — skipping planning-mode prompt on re-entry."
  fi
fi
```

**Legacy/partial stage-3 launch state.** If `active.current-stage == 2` but `base-commit != null`, the previous Step 3 wrote its state but did not advance. Do not recapture `base-commit` or `history-baseline-version`; finish the stage-3 launch by validating `primer.md` (regenerate via Step 3.5 if needed) and then advancing 2 → 3.

```bash
if [[ "$current_stage" == "2" && "$base_commit_persisted" != "null" && -n "$base_commit_persisted" ]]; then
  echo "Detected legacy/partial stage-3 launch state (current-stage=2 but base-commit=$base_commit_persisted). Skipping base-commit + baseline capture; will validate primer.md and advance 2 → 3."
  legacy_partial_launch=1
fi
```

### Step 2 — Resolve and validate the primary branch from `config.md`

The feature branch lives in `config.md`'s `## GIT BRANCH` section (written at stage 2). Parse it, validate it, and persist to `progress.md`.

```bash
config_file="$data_root/workflow-stream/$active_feature/blueprints/current/config.md"
```

Resolve the data root once so the command honors `userConfig.data_root` / `MO_DATA_ROOT` overrides:

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
```

**Extract the GIT BRANCH block.** Read lines from the `## GIT BRANCH` heading to the next `##` heading. Drop HTML comments (`<!-- ... -->`), drop blank lines, drop bullet points (`- ...`). Collect every remaining non-comment, non-empty line. Each such line is treated as a candidate branch name.

**Branch count gate:**

- **Zero candidates** — the section is empty. Prompt the overseer in chat with both paths:

  > "`config.md`'s `## GIT BRANCH` section is empty. I can't advance to brainstorming without the feature branch. Two options:
  >
  >   1. Tell me the branch here (e.g. `feat/pricing/webhook`) and I'll fill `config.md` for you.
  >   2. Edit `config.md` yourself — fill `## GIT BRANCH` with one bare line (no bullet, no quotes) — and re-run `/mo-plan-implementation`.
  >
  > Which one?"

  If the overseer provides a branch name inline, use `Edit` to write it into `config.md` between `## GIT BRANCH` and the next heading, then continue to validation below. If they choose option 2, halt and wait for them to re-invoke.

- **Exactly one candidate** — proceed to validation.

- **Two or more candidates** — warn and stop until the overseer narrows to one:

  > "`config.md`'s `## GIT BRANCH` section lists **N** branches:
  >
  >   - `<branch-1>`
  >   - `<branch-2>`
  >   - ...
  >
  > **One branch per feature.** The review pipeline (`/mo-review`, diff scope, base-commit, archival) assumes a single branch. If this feature genuinely needs coordinated work across multiple branches (e.g. a monorepo with separate frontend/backend branches), the plugin's model is to split it into two features — add one todo item per branch so each has its own review scope and audit trail. 
  >
  > Which single branch do you want me to use for this feature? Reply with the branch name, and I'll rewrite `## GIT BRANCH` in `config.md`. Or edit `config.md` yourself and re-run `/mo-plan-implementation`."

  Wait for the overseer's reply. If they name one branch, use `Edit` to rewrite the section to that single line (remove the others), then re-enter validation. If they edit and re-run, halt.

**Validation (once exactly one candidate is in hand).** Store it as `primary_branch`:

```bash
# Refuse main/master.
if [[ "$primary_branch" == "main" || "$primary_branch" == "master" ]]; then
  echo "error: '$primary_branch' is refused. Pick a feature branch, not the trunk." >&2
  exit 1
fi

# Assert HEAD matches.
current_branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$current_branch" != "$primary_branch" ]]; then
  echo "error: HEAD is on '$current_branch' but config.md declares '$primary_branch'. Check out the right branch (git checkout $primary_branch) and re-run." >&2
  exit 1
fi
```

Surface these errors to the overseer as readable messages (not raw stderr) before halting — same style as the empty/multi-branch prompts above.

**Persist to `progress.md`:**

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "branch=$primary_branch"
```

### Step 3 — Transition todos and record base commit + history baseline

(On re-entry, this whole step is skipped — the previously-captured `base-commit` and `history-baseline-version` are preserved. On legacy/partial-launch detection, the Step 3 capture is skipped but the advance 2 → 3 still runs.)

```bash
if [[ "${re_entry:-0}" == "0" && "${legacy_partial_launch:-0}" == "0" ]]; then
  $CLAUDE_PLUGIN_ROOT/scripts/todo.sh bulk-transition PENDING IMPLEMENTING --feature "$active_feature"
  base_commit="$(git rev-parse HEAD)"

  # Capture history-baseline-version: the highest finalized v[N] index for this
  # feature at stage-3 entry. The Stage-4 drift-completion probe (Item 1 of the
  # v11 plan) walks history versions K > baseline for kind=spec-update to detect
  # "this cycle's drift fired but the marker write was lost." Capturing 0 when
  # no history exists is correct (the probe treats null/missing as "unknown",
  # which is a different state — see Item 1's back-compat guard).
  data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
  history_dir="$data_root/workflow-stream/$active_feature/blueprints/history"
  baseline=0
  if compgen -G "$history_dir/v*" >/dev/null 2>&1; then
    baseline_str="$(ls -d "$history_dir"/v[0-9]* 2>/dev/null \
      | grep -vE '\.(partial|partial\.tmp)$' \
      | sed -n 's|.*/v\([0-9]\+\)$|\1|p' \
      | sort -n | tail -1)"
    [[ -n "$baseline_str" ]] && baseline="$baseline_str"
  fi

  # Atomic batched write: base-commit + sub-flow + history-baseline-version
  # land together (or none of them, if anything in the batch fails validation).
  $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set \
    "base-commit=$base_commit" \
    "sub-flow=chain-in-progress" \
    "history-baseline-version=$baseline"
fi

if [[ "${re_entry:-0}" == "0" ]]; then
  $CLAUDE_PLUGIN_ROOT/scripts/progress.sh advance 2
fi
```

### Step 3.5 — Generate `blueprints/current/primer.md`

Compose a compact context bundle for the brainstorming chain. The primer snapshots the parts of `requirements.md`, `config.md`, `summary.md`, and `progress.md` that the chain reads on every entry, so the chain can stay in the primer for the common case and drop into canonical files only when a gap surfaces.

```bash
primer_dest="$data_root/workflow-stream/$active_feature/blueprints/current/primer.md"
requirements_file="$data_root/workflow-stream/$active_feature/blueprints/current/requirements.md"
requirements_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$requirements_file" id)"
# frontmatter.sh init overwrites — safe to re-run on retry.
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init primer "$primer_dest" \
  "REQUIREMENTS_ID=$requirements_id" \
  "FEATURE=$active_feature" \
  "DATA_ROOT=$data_root"
```

Then fill the body via `Edit`. Resolve the values up front so they go into the file as literals (the template body has no token substitution beyond frontmatter):

```bash
primer_branch="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get branch)"
primer_base_commit="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get base-commit)"
implementing_ids="$($CLAUDE_PLUGIN_ROOT/scripts/todo.sh list IMPLEMENTING --feature "$active_feature")"
```

Then write each section per the template's guide:

- **`## Active scope`** — `branch: <primer_branch>`, `base-commit: <primer_base_commit>`, and one bullet per id in `implementing_ids` (pull each item's description from the active cycle's `todo-list.md`'s matching line; resolve the path via `$CLAUDE_PLUGIN_ROOT/scripts/quest.sh dir`).
- **`## Goals (this cycle)`** — 5–20 line excerpt extracted from `requirements.md`'s `## Goals (this cycle)` section. Tighten — the chain reads the full file only if the primer is insufficient.
- **`## Journal context (active feature)`** — 5–20 line digest from the active cycle's `summary.md`'s `## Feature: <active_feature>` section (resolve the path via `quest.sh dir`), plus any items from `## Cross-cutting constraints` that materially affect this feature.
- **`## Likely-relevant skills & rules`** — at most five entries from `config.md`'s **auto-block** (Phase 5.4 — pre-pass tighter skill metadata). Each entry: `<name>: <one-line reason>; path: <.claude/skills/...>`. Off-topic skills are reachable via `config.md`; do not list them here.

  **Read from `config.md` only — do NOT enumerate `.claude/skills/` or `.claude/rules/` directly.** Stage 2's `mo-apply-impact` already produced `config.md`'s three-section list (`## Skills`, `## Rules`, `## Load on demand`) by filtering the raw skill library to what's likely-relevant for this cycle. The primer's job is to surface the highest-priority subset; reading the raw directories at stage 3 would re-do work stage 2 already did and pull every skill name into main context. Use `frontmatter.sh get`-style section extraction or, when `commands/mo-run.md`'s artifact-excerpt commands ship (Phase 6.5), a dedicated slice command — both produce the same result.

  Quantitative budget: **≤ 5 entries inline**. If `config.md`'s `## Skills` and `## Rules` sections together carry ≤ 10 entries, pass them inline as bullets. If more than 10, pick the most-likely-relevant five for the primer and reference `config.md` itself by path for the rest.

The `## Execution-mode hints` section is template-emitted (Phase 5.3) and does not need editing — it carries the concrete thresholds for `subagent-driven-development` and `direct` mode that the chain reads when deciding execution.

The `## On-demand canonical files` section is template-emitted and does not need editing — it lists the files the chain should consult when the primer falls short.

### Step 4 — Ask the overseer to pick a planning mode

Prompt the overseer:

> "Stage 3 — pick a planning mode for `$active_feature`:
>
>   - **`brainstorming`** (default) — invokes the brainstorming → writing-plans → executing-plans / subagent-driven-development chain in an isolated session. Best for non-trivial features where the design isn't obvious from the requirements, or where you want the chain's design-question / spec-approval / plan-approval gates.
>   - **`direct`** — skips the brainstorming chain. I read `primer.md` (and any on-demand canonical files) and implement directly in this session. Best for straightforward features where the design is clear from the blueprint and you want to skip the chain ceremony. You'll still review the result at stage 5.
>
> Reply `brainstorming` or `direct`."

Wait for the reply. Persist the choice:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "planning-mode=<choice>"
```

Then dispatch on the value:

- `brainstorming` → continue to **Step 4a**.
- `direct` → continue to **Step 4b**.

### Step 4a — Brainstorming mode: invoke the Skill

Use the `Skill` tool to invoke the `brainstorming` skill with the following primer message. Substitute `<$data_root>` with the resolved data root (e.g. `millwright-overseer` by default; whatever `$data_root` evaluates to in this command's shell context) so the paths point at real files in the user's workspace.

```
I'm working on the "<$active_feature>" feature. Use these documents as primary context.

**Context loading order** (read in this order; only escalate when a gap appears):

1. **Required first read** — <$data_root>/workflow-stream/<$active_feature>/blueprints/current/primer.md
   Compact snapshot of active scope, goals, journal context, and likely-relevant skills/rules. For most cycles this is all you need.

2. **On demand** — only if the primer leaves a gap on a specific topic:
   - <$data_root>/workflow-stream/<$active_feature>/blueprints/current/requirements.md — full goals / planned / non-goals
   - <$data_root>/workflow-stream/<$active_feature>/blueprints/current/config.md — full skills/rules + GIT BRANCH + Overseer Additions
   - <$data_root>/quest/<active-slug>/summary.md — feature-indexed journal digest for this cycle (the slug is recorded in `<$data_root>/quest/active.md`). Read `## Cross-cutting constraints` and `## Feature: <$active_feature>` first; other feature sections are reference-only
   - <$data_root>/quest/<active-slug>/todo-list.md — full feature breakdown for this cycle if you need PENDING/TODO context

**Work definition** (the scope I'm taking on this run):
The IMPLEMENTING items listed in primer.md `## Active scope` are the committed scope for this run. Sibling features in PENDING/TODO are out of scope.

Proceed with your normal brainstorming flow: clarifying questions → design sections → spec doc → writing-plans → execution. Do NOT worry about the mo-workflow — I'll resume it automatically after your chain finishes.
```

Substitute `<$active_feature>` with the actual feature name read from the queue.

### Step 4b — Direct mode: implement in this session

The millwright (this session) owns the implementation directly — no Skill is invoked. Read the layered primer, implement, commit.

1. **Read `primer.md`.** Required first read.
2. **Escalate to canonical files only as needed:**
   - `blueprints/current/requirements.md` — full goals / planned / non-goals
   - `blueprints/current/config.md` — full skills/rules + GIT BRANCH + Overseer Additions
   - the active cycle's `summary.md` (under `quest/<active-slug>/`) — `## Cross-cutting constraints` + `## Feature: <$active_feature>` first
   - the active cycle's `todo-list.md` (under `quest/<active-slug>/`) — full feature breakdown if PENDING/TODO context is needed
3. **Implement on the current branch.** Follow the project's conventions (CLAUDE.md, `.claude/rules/`). The IMPLEMENTING items in `primer.md` `## Active scope` are the committed scope for this run; sibling features are out of scope.
4. **Commit per logical unit of work.** Stage 4 reads `git log base-commit..HEAD` to confirm the chain produced commits — direct mode satisfies the same check by committing here.
5. **When done, hand off.** Tell the overseer:

   > "Direct implementation complete on `$primary_branch`. Commits: `<count>`. Type `/mo-continue` to advance to stage 4 (implementation diagrams + overseer review)."

   The Resume Handler in `/mo-continue` (current-stage = 3) treats brainstorming and direct modes identically — it only verifies that `git log base-commit..HEAD` is non-empty before generating diagrams. The overseer reviews the result the same way.

**Direct mode caveats.** Direct mode trades the chain's design-questions / spec-approval / plan-approval gates for speed. If, while reading the primer, you realize the feature is bigger than expected (multiple non-trivial design decisions, ambiguous acceptance criteria, novel domain), surface that to the overseer and ask if they want to switch to `brainstorming` instead — re-set `planning-mode=brainstorming` and proceed to Step 4a.

### Step 5 — Hand off

After Step 4a or 4b, stop responding in the mo-workflow context.

- **Brainstorming mode:** the overseer drives the chain through to the end of executing-plans / subagent-driven-development / finishing-a-development-branch. When the chain ends and control returns to the main session, the overseer types `/mo-continue` to resume at stage 4.
- **Direct mode:** the overseer reviews the implementation in chat as it happens; when done, types `/mo-continue` (same resume signal).

## Notes

- The brainstorming primer is a **layered load**: `primer.md` is the only required first read; the canonical files (`requirements.md`, `config.md`, `summary.md`, `todo-list.md`) are on-demand fallbacks for when the primer leaves a gap. The chain reads the codebase and any other context on its own as needed.
- `primer.md` is generated **just before** the chain is invoked (Step 3.5), so branch and base-commit are already validated/captured. It rotates with the rest of `blueprints/current/` on stage 8 and on `/mo-update-blueprint`, leaving an audit trail.
- Do not intercept questions from the brainstorming skill. The overseer owns those.
- If the overseer cancels mid-chain, state is already partially updated (todos = IMPLEMENTING, base-commit set, sub-flow = chain-in-progress, primer.md written). Use `/mo-abort-workflow` to clean up.
