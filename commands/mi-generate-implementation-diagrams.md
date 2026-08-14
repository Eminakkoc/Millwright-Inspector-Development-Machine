---
description: Render diagrams of the implementation (commit range base-commit..HEAD) into implementation/diagrams/, with pre-existing system context framed alongside the new functionality. Called by /mi-continue at stage 4.
---

# mi-generate-implementation-diagrams

**Runtime bootstrap.** Every `$CLAUDE_PLUGIN_ROOT` reference in this command's Bash blocks assumes a resolved plugin root; Claude Code does not inject the env var into Bash subshells. If it is empty in your shell, apply the canonical resolver (`docs/millwright-inspector-project.md` §8.14; reference implementation: `mi-continue.md` Step 1a) before the first Bash block: (1) inherited env var when it points at a working install, (2) `$PWD` when it is this plugin's source repo, (3) the `installPath` from `~/.claude/plugins/installed_plugins.json` — then export it, persist it to the per-cwd tempfile, and prepend the recovery one-liner to every subsequent Bash block. Refuse with an environmental diagnostic if none resolve.

**Delegation contract.** This command REQUIRES the sub-agents listed below; §8.13's main-read budget forbids main from doing their work itself. **Invoking `/mi-generate-implementation-diagrams` IS the user requesting them** — Claude Code's default "do not call the Agent tool unless the user requested it" (and any stricter house rule layered on it) does not reach a sub-agent this command names at the step that names it, so spawn them without asking for extra confirmation. The default still holds everywhere else: never spawn a sub-agent this command does not name, and never invent fan-out to parallelize a step main is supposed to run. If a named delegation genuinely cannot run (type unavailable, harness refusal), say so and stop — never silently do its work in main. Sub-agents: `implementation-analyst` (Phase 3.1 — writes `change-summary.md` and frames the diagrams). Canonical rule: `docs/millwright-inspector-project.md` §8.15.

Generates the single set of diagrams the inspector reviews at stage 5. Each diagram shows the **implemented** behaviour of `base-commit..HEAD` with **pre-existing** participants, classes, and flows kept in view as framed/shaded context so the inspector can spot what changed at a glance.

**Main-read budget (stage 4).** Allowed in main: `progress.md`, drift-probe filesystem state, the sub-agent's return summary, and the `.puml` file listing for the README write. Forbidden in main: diff hunks, change-summary.md body composition, and PlantUML source generation — delegated to `subagent_type: millwright-inspector-development-machine:implementation-analyst` (Phase 3.1) under the per-event prompt gate. The change-summary cache check (`commits.sh change-summary-fresh`) runs in main only as a freshness probe to set the `summary_state` flag passed into the sub-agent prompt; main does not read the body. See `docs/millwright-inspector-project.md` § "Main-read budget gates by stage" for the canonical table.

## Execution

### Step 1 — Resolve inputs

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
active_feature="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get-active)"
base_commit="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get base-commit)"
dest_dir="$data_root/workflow-stream/$active_feature/implementation/diagrams"
mkdir -p "$dest_dir"
```

### Step 1.4 — Invocation mode (ordinary vs. feature-test)

```bash
if $CLAUDE_PLUGIN_ROOT/scripts/todo.sh is-feature-test "$active_feature"; then
  ft_mode=1
  # feature-test-range refuses (exit 3/4/5) when a rebase leaves a finished
  # feature's head unreachable, no feature contributed commits, or bases
  # diverged. `| head -1` would otherwise swallow that exit status (head's
  # own exit code wins the pipe unless pipefail is set) — same shape
  # mi-continue.md's Feature-test entry sequence Step 1 already uses for
  # this exact call.
  set -o pipefail
  if ! range_line="$($CLAUDE_PLUGIN_ROOT/scripts/commits.sh feature-test-range "$active_feature" | head -1)"; then
    exit 1
  fi
  union_base="$(printf '%s' "$range_line" | cut -f1)"
else
  ft_mode=0
fi
```

Auto-detected rather than flag-driven so it cannot be forgotten by a caller. **An ordinary
feature never matches**, so the single-feature path below — including its freshness
short-circuit and its affected-subjects derivation — is unreachable from the feature-test
code and its behaviour is unchanged.

If the range refuses, `commits.sh`'s own diagnostic (exit 3/4/5's stderr message —
unreachable finished feature, no contributor, or diverged bases) is not redirected anywhere
in this block, so it reaches the inspector directly; stop here rather than continuing with an
empty `union_base`.

When `ft_mode=1`, `base-commit` was already pinned to `union_base` by the caller
(`/mi-continue`'s feature-test sequence), so Step 1.5's `diagrams-fresh` and Step 2.1's
`change-summary-fresh` both work **unchanged** — they key on `.active.base-commit` and HEAD.

### Step 1.5 — Diagram-set freshness check (skip regeneration when fresh)

**Ordinary invocations are unchanged.** When `ft_mode=0` every branch below behaves exactly
as it did before the feature-test path existed, including the `fresh` short-circuit.

Before doing any diagram work, check whether the existing set is already current. The `diagrams-fresh` subcommand returns one of `fresh | stale | skipped | missing` (see `scripts/commits.sh diagrams-fresh` for the contract):

```bash
# `missing` exits 1 by contract, and that is a normal path for this command
# (see the `missing` bullet) — the `|| true` keeps a `set -e` block from
# aborting on it. Branch on the stdout enum; the exit code carries no
# information the enum does not.
freshness="$($CLAUDE_PLUGIN_ROOT/scripts/commits.sh diagrams-fresh "$active_feature" 2>/dev/null || true)"
```

Branch on the output:

- **`fresh`** (exit 0) — `implementation/diagrams/` exists with `.puml` files AND no commits since the last diagram-render commit. Print *"diagrams already current — skipping regeneration"* and exit 0. Do NOT proceed to Step 2.
- **`stale`** (exit 0) — a `.puml` set exists but commits have landed since it was rendered. Proceed to Step 2 to regenerate. (Note that a *missing* set reports `missing`, not `stale` — the two "regenerate" reasons are distinct enum values, so do not read either bullet as covering the other.)
- **`skipped`** (exit 0) — `implementation-diagrams-skipped=true`. This command was invoked anyway (most likely from the manual recovery path or stage-7 refresh). Proceed to Step 2 to regenerate; after success, the caller (`/mi-draw-diagrams` or stage-7's Step 2.5) is responsible for clearing `implementation-diagrams-skipped=false`.
- **`missing`** (exit non-zero) — nothing to reuse: no `.puml` files and no skip marker. **Proceed to Step 2 and generate.** This is the state of every first-ever diagram generation for a feature (`implementation/diagrams/` is created by Step 2, not before it), and it is also what a partial run leaves behind — both want the same thing from *this* command, which exists to generate. Do not abort.

  Print a single line first so the distinction stays visible in the transcript: *"no existing diagram set — generating from scratch"*.

  **Why this branch does not abort here, but does elsewhere.** `missing` is a genuine invariant violation only when read *after* stage 4 was supposed to have run — that is the reading at `/mi-continue`'s Review-Resume Step 2.5, where it means "stage 4 reported success yet left nothing behind," and that handler correctly surfaces a diagnostic. It is not a violation at the entry point of the generator itself. An earlier version aborted here and told the inspector to run `/mi-draw-diagrams`, which dispatches straight back into this body (Step 2 of `mi-draw-diagrams`) and re-hits this branch — no feature could ever produce its first diagram set. Keep the asymmetry: the generator generates; the callers diagnose.

### Step 2 — Resolve inputs and spawn the implementation-analyst sub-agent

Diagram generation reads from a cached analysis artifact instead of re-running the codebase scan from scratch. `/mi-update-blueprint` writes the same artifact when it runs in the same stage-4 turn (post-chain drift refresh), so the analysis happens once per `base-commit..HEAD` range.

**Cache contract (load-bearing — do NOT bypass).** The `change-summary-fresh` check is the gate that prevents this command and `/mi-update-blueprint` from independently re-walking the codebase for the same `(base-commit, HEAD)` range. Both consumers MUST call `commits.sh change-summary-fresh` before regenerating; a future change that reads `change-summary.md` directly without the freshness gate would re-introduce the double-walk this cache exists to prevent. See `docs/context optimization/recommendations.md` § "Cache Key Specifications" → `change-summary.md` for the canonical key.

#### Step 2.1 — Resolve sub-agent inputs (main)

```bash
if [[ "$ft_mode" == "1" ]]; then
  # A feature-test entry has no requirements.md — it is framed against every
  # finished feature's. Resolve id + archived-path pairs in queue order.
  # requirements_paths (plural) feeds Phase 3's seam-classification gate
  # below — there is no single <requirements_path> for this folder.
  #
  # feature-test-range refuses (exit 3/4/5) on the same conditions Step 1.4
  # already covers. No pipe here (a plain command substitution), so its exit
  # status reaches `if !` directly — no pipefail needed for this call.
  # $ft_range_out is reused by Step 2.2 below rather than calling this a
  # third time.
  if ! ft_range_out="$($CLAUDE_PLUGIN_ROOT/scripts/commits.sh feature-test-range "$active_feature")"; then
    exit 1
  fi
  req_pairs=()
  while IFS=$'\t' read -r row_kind row_feat _row_base _row_head; do
    [[ "$row_kind" == "contributor" ]] || continue
    hist="$data_root/workflow-stream/$row_feat/blueprints/history"
    # Portable newest-version resolution (macOS/BSD sed has no `\+` in BRE
    # mode, so this loops instead of a one-line sed capture — same pattern
    # scripts/review.sh's `init` branch already uses for a feature-test
    # entry).
    latest_v=0
    for d in "$hist"/v[0-9]*; do
      [[ -d "$d" ]] || continue
      v="${d##*/v}"
      [[ "$v" =~ ^[0-9]+$ ]] || continue
      (( v > latest_v )) && latest_v="$v"
    done
    if [[ "$latest_v" -eq 0 ]]; then
      echo "error: no archived requirements.md found for contributor $row_feat" >&2
      exit 1
    fi
    req_file="$hist/v$latest_v/requirements.md"
    if [[ ! -f "$req_file" ]]; then
      echo "error: $req_file not found for contributor $row_feat" >&2
      exit 1
    fi
    req_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$req_file" id)"
    req_pairs+=("$req_id"$'\t'"$req_file")
  done <<< "$ft_range_out"
  if [[ ${#req_pairs[@]} -eq 0 ]]; then
    echo "error: feature-test-range reported no contributors for $active_feature" >&2
    exit 1
  fi
  requirements_ids="$(printf '%s\n' "${req_pairs[@]}" | cut -f1)"
  requirements_paths="$(printf '%s\n' "${req_pairs[@]}" | cut -f2)"
  requirements_file=""   # no single requirements.md for a feature-test entry; see requirements_paths
else
  requirements_file="$data_root/workflow-stream/$active_feature/blueprints/current/requirements.md"
  requirements_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$requirements_file" id)"
  requirements_paths=""
fi
base_commit_sha="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get base-commit)"
head_sha="$(git rev-parse HEAD)"
diagram_rendering="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get diagram-rendering 2>/dev/null || echo 'never')"
summary_file="$dest_dir/../change-summary.md"
blueprint_diagrams_dir="$data_root/workflow-stream/$active_feature/blueprints/current/diagrams"

if $CLAUDE_PLUGIN_ROOT/scripts/commits.sh change-summary-fresh "$active_feature"; then
  summary_state="fresh"
else
  summary_state="stale-or-missing"
fi
```

#### Step 2.2 — Initialize change-summary.md frontmatter when stale (main)

When `summary_state=stale-or-missing`, pre-create the file with valid frontmatter so the sub-agent only has to fill the body (mirrors Step A's "Initialize the report" pattern in `docs/blueprint-regeneration.md`):

```bash
if [[ "$summary_state" == "stale-or-missing" ]]; then
  if [[ "$ft_mode" == "1" ]]; then
    # Feature-test entry: plural requirements-ids (a YAML list), one per
    # finished contributor, in the order collected in Step 2.1. Same
    # REQUIREMENTS_FIELD + `!RAW!` shape review.sh init already established
    # for inspector-review.md's oneOf field.
    req_ids=()
    while IFS= read -r rid; do
      if [[ -n "$rid" ]]; then
        req_ids+=("$rid")
      fi
    done <<< "$requirements_ids"
    # Empty-array expansion of "${req_ids[*]}" aborts with unbound variable
    # under `set -u` (confirmed on bash 3.2.57) — guard before the join,
    # same defense-in-depth review.sh's own final-list check uses.
    if [[ ${#req_ids[@]} -eq 0 ]]; then
      echo "error: no requirements-ids resolved for $active_feature" >&2
      exit 1
    fi
    ids_csv="$(IFS=,; echo "${req_ids[*]}")"
    requirements_field="!RAW!requirements-ids: [$ids_csv]"
  else
    requirements_field="!RAW!requirements-id: $requirements_id"
  fi
  $CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init change-summary \
    "$summary_file" \
    "REQUIREMENTS_FIELD=$requirements_field" \
    "FEATURE=$active_feature" \
    "BASE_COMMIT=$base_commit_sha" \
    "HEAD=$head_sha"
  if [[ "$ft_mode" == "1" ]]; then
    # A zero-commit finished feature contributes nothing to the union range
    # and would otherwise vanish silently. Record it under the freshly
    # initialized body's `## Omitted from analysis` (the template's final
    # section, so a plain append lands there). Reuses $ft_range_out captured
    # by Step 2.1 above — no third feature-test-range call, so nothing here
    # needs its own refusal guard.
    omitted_features="$(printf '%s\n' "$ft_range_out" | awk -F'\t' '$1=="omitted" {print $2}')"
    if [[ -n "$omitted_features" ]]; then
      while IFS= read -r feat; do
        if [[ -n "$feat" ]]; then
          printf -- '- %s — zero-commit finished feature; omitted from the union range.\n' "$feat" >> "$summary_file"
        fi
      done <<< "$omitted_features"
    fi
  fi
fi
```

When `summary_state=fresh`, leave the file alone — the sub-agent will read it as-is and skip the regeneration phase internally.

#### Step 2.3 — Spawn the sub-agent

**Delegate change-summary regeneration + diagram framing + selective re-render to a fresh sub-agent.** Bounded-context reading of the diff (often hundreds of lines across many files) and PlantUML rendering both belong off main — keeping them in a disposable sub-agent caps main's per-cycle bloat at the return summary. This was the workload labelled "delegation candidate" in prior versions; it is now mandatory, not optional.

Invoke `Agent` with `subagent_type: millwright-inspector-development-machine:implementation-analyst`. Compose the prompt from the template below. Substitute `<placeholder>` literals with concrete values resolved above.

Sub-agent prompt template:

```
You are a fresh sub-agent invoked from `mi-generate-implementation-diagrams` (Step 2.3) at stage 4. Your context is isolated from the main session — main does not see your tool calls, only your final return summary.

**Inputs (resolved by main, passed in this prompt):**

- active_feature: <active_feature>
- base_commit: <base_commit_sha>
- HEAD: <head_sha>
- summary_file: <summary_file>
- summary_state: <summary_state>          # "fresh" or "stale-or-missing"
- diagrams_dir: <dest_dir>                # implementation/diagrams/ destination
- blueprint_diagrams_dir: <blueprint_diagrams_dir>  # source for seeding
- diagram_rendering: <diagram_rendering>  # "never" (>99% path) or "on-request"
- requirements_path: <requirements_file>  # ordinary feature only — empty for a feature-test entry
- requirements_paths: <requirements_paths>  # feature-test entry only (newline list) — empty for an ordinary feature
- feature_test: <feature_test_flag>       # "true" when ft_mode=1 (derived from $ft_mode), else "false"

**When this is a feature-test invocation** (`ft_mode=1`, passed as `feature_test: true`):

- **Range.** `<union_base>..HEAD` spans every finished ordinary feature, not one feature's
  own work.
- **Seeding (Phase 2).** There is no `blueprints/current/diagrams` for this folder — it has
  no blueprint by design. Skip the `<blueprint_diagrams_dir>` recipe in Phase 2 below
  entirely; do not stat or create that path for this folder. Seed instead from each
  **ordinary** feature's archived stage-2 set at
  `workflow-stream/<feat>/blueprints/history/v[N]/diagrams/*.puml` (newest finalized
  `v[N]`). A subject with no commits in the union range stays seeded and is tagged
  `seeded-only` against the feature it came from.
- **Budget (Phase 3).** 1 combined `use-case-<ft-feature>.puml`, **up to 5**
  `sequence-<flow>.puml`, **up to 2** structural. Larger than an ordinary feature's
  1 / 2–3 / ≤1 because the subject is larger.
- **Seam classification (Phase 3).** `<requirements_path>` is empty for this invocation —
  there is no single requirements.md to read Goals items from. Read every path listed in
  `<requirements_paths>` instead (one per contributing feature) and treat the optional
  structural-diagram gate as satisfied if **any** of them declares seam `backend` or
  `mixed`. This is the substitute Phase 3's own instruction below points back to.
- **Sequences must cross feature boundaries.** A sequence that re-draws one feature's own
  internal flow is rejected — that diagram already exists in that feature's history, and
  redrawing it adds pages without adding information. Draw the seams: where one feature's
  output becomes another's input, shared state, and handoffs.
- **Attribution.** In `## Changed files`, label each area with the feature that contributed
  it, so the framing can name the seams.

**Your task — three phases:**

### Phase 1 — Ensure `change-summary.md` is current

- If `summary_state=fresh`, read <summary_file> as the analysis cache and skip to Phase 2 — do NOT re-walk the codebase.
- If `summary_state=stale-or-missing`, the file is pre-initialized with valid frontmatter by main. Fill the body via `Edit` per `templates/change-summary.md.tmpl`. Source the changed-file list from the helper:

  ```bash
  $CLAUDE_PLUGIN_ROOT/scripts/commits.sh changed-files "<active_feature>"
  # Emits TSV rows: <status>\t<adds>\t<dels>\t<path>
  ```

  Body sections to fill:
  - `## Range` — fill `commit count` from `git rev-list --count "<base_commit_sha>..HEAD"`.
  - `## Changed files` — group the TSV rows by area (top-level dir, layer, or feature concern). Format: `<status> <path> (+adds/-dels): <one-line purpose>`. Skip the per-file purpose for trivial files. Do NOT paste full diffs.
  - `## Detected entrypoints` — public surface introduced or modified: HTTP routes, RPC handlers, CLI commands, scheduled jobs, queue consumers, new exports. One bullet per entrypoint with `<path>:<symbol>`. Skip the section if no public surface changed.
  - `## Suspected flows` — end-to-end flows the change enables (validated against the diagram pass in Phase 3). Each entry: `<flow name>: <one-line trace>`.
  - `## Omitted from analysis` — every changed file you intentionally skipped per the bounded-context policy below, listed by path so reviewers can spot blind spots. **Feature-test invocation:** when `summary_state=stale-or-missing`, main has already appended one bullet per zero-commit contributor to this section before you were spawned — APPEND your own file-level omissions after them; do not delete or overwrite what is already there.

  Bounded context policy (apply throughout Phase 1):

  1. Diff hunks first. Always read `git diff "<base_commit_sha>..HEAD" -- <path>` for every changed file before opening unchanged-side context.
  2. Cap caller/callee expansion at 3 per changed file. Only open more when a flow would be unreadable without them — and note the expansion in the file's `## Changed files` bullet.
  3. Prefer symbol search over whole-file reads. If you only need the signature or one function, grep for it rather than `Read`-ing the whole file.
  4. Skip generated/vendor/lock files. Default omissions: `dist/`, `build/`, `node_modules/`, `vendor/`, `*.lock`, `package-lock.json`, `yarn.lock`, `Cargo.lock`, `Gemfile.lock`, `*.min.js`, `*.svg`.
  5. Skip large binary diffs. Files where `commits.sh changed-files` reports `-/-` for adds/dels are binary; record the path under `## Omitted from analysis`.

### Phase 2 — Seed `<diagrams_dir>` from `<blueprint_diagrams_dir>`

Stage 5 review and stage 8 archival both expect `<diagrams_dir>` to be a complete diagram set — one file per subject, matching the stage-2 set. Seed the `.puml` files from the blueprint folder before any selective re-rendering. `cp -n` ensures idempotent re-runs preserve already-generated implementation versions. Copy ONLY `.puml` files — do NOT copy `README.md` (the schemas are deliberately distinct).

```bash
if [[ -d "<blueprint_diagrams_dir>" ]]; then
  for puml in "<blueprint_diagrams_dir>"/*.puml; do
    [[ -f "$puml" ]] || continue
    cp -n "$puml" "<diagrams_dir>/$(basename "$puml")"
  done
fi
```

### Phase 3 — Selective re-render against `<base_commit>..HEAD`

Identify which diagram subjects are affected by the commit range. Sources for the "affected subjects" set:

- `change-summary.md` `## Detected entrypoints` — new public surface mapped back to which diagram subject covers it (e.g., new payment-webhook entrypoint → `sequence-payment-submit.puml`).
- `change-summary.md` `## Suspected flows` — flows the implementation enables, mapped to the matching `sequence-<flow>.puml`.
- `change-summary.md` `## Changed files` grouped by area — areas that map to a structural diagram subject.

Re-render the affected subjects only. Overwrite their seeded `.puml` files in `<diagrams_dir>` using the existing-vs-new convention against the `<base_commit>` baseline. Leave unchanged subjects (no entries in the affected set) as the seeded stage-2 versions — those subjects had no implementation work this cycle. A 30-file change touching only `src/payments/` should re-render only the payments-related diagrams.

**Diagram set caps** (per `docs/millwright-inspector-project.md` § "Diagram conventions"):

- `use-case-<feature>.puml` — mandatory, exactly one. Implemented capabilities with framed actors that pre-existed.
- `sequence-<flow>.puml` — one per significant implemented flow, targeting 2–3 total per feature. Render 1 only when the implementation genuinely has a single significant flow; never render more than 3 (if more than 3 candidates exist, pick the most diff-worthy; surface a decomposition signal under `Findings / risks` if the count keeps creeping up).
- One optional structural diagram — `class-<domain>.puml` OR `component-<subject>.puml`, never both. Read the seam classification from `<requirements_path>` Goals items (carried forward from Step A's codebase-grounding pass) — for a feature-test invocation (`feature_test: true`), `<requirements_path>` is empty; use `<requirements_paths>` and the "any contributor" rule from the feature-test block above instead. The optional slot fires only when seam is `backend`/`mixed` AND:
  - Class when the implementation introduced 3+ new domain classes/modules with non-trivial relationships (inheritance, composition with shared lifecycle, bidirectional association, or branching dependency graph).
  - Component when the implementation introduced 3+ new components/modules with non-trivial dependencies (fan-out, fan-in, cross-bucket dependency, or multiple inbound callers) but isn't class-heavy enough for a class diagram.
  - Linear chains do not qualify (e.g., `controller → service → repo`). Skip the slot.
  - One-sentence test. If you can't articulate the diagram's purpose in one sentence beyond its filename, skip.
  - Skip for `frontend` / `infra` seams.

  Pick whichever fits the *implemented* topology best — even if stage 2 picked the other type, the implementation reality wins here. The inspector can compare the matched filenames across both diagram folders; if stage 2 rendered `class-payment-domain.puml` and stage 4 renders `component-payment-pipeline.puml`, that mismatch is itself signal of chain restructure and surfaces in the post-chain drift check.

**Existing-vs-new convention** (use the canonical PlantUML snippets in this same file's "Existing-vs-new convention" subsection below):

- Existing — blue (`#D6EAF8` fill, `#3498DB` strokes) inside `box "Existing system" #D6EAF8 … end box` (sequence) or `package "Existing" #D6EAF8 { … }` (class / use-case / component); blue arrows `A -[#3498DB]-> B`; `#D6EAF8` activations.
- New — green (`#D4EDDA` fill, `#27AE60` strokes) inside `box "New" #D4EDDA … end box` or `package "New" #D4EDDA { … }`; green arrows `C -[#27AE60]-> D`; `#D4EDDA` activations.
- Standard legend block; stage-4 wording reads `"existing (pre-base-commit)"` / `"new in this implementation"`.

**Render gate.** When `<diagram_rendering>=never` (default >99% path), produce ONLY `.puml` source files via the PlantUML MCP — do NOT render `.svg`/`.png`. Render `.svg` only when `<diagram_rendering>=on-request`.

**Wording caveat for seeded-only diagrams.** Stage-2 and stage-4 conventions share the colour scheme but differ in baseline semantics: stage-2's legend reads "Planned" / "to be implemented"; stage-4's reads "new in this implementation". For subjects that received no implementation commits this cycle, the seeded `.puml` retains the stage-2 wording verbatim — that's correct (no implementation work to recolour) but is a presentation deviation from the standard stage-4 convention. Do NOT programmatically rewrite seeded legends — main's freshly-generated implementation `README.md` (next step) surfaces the convention to the inspector.

---

Required return shape — return ONLY this structure. Do not narrate intermediate steps:

Result: success | partial | blocked
Artifacts changed:
- <path>: <one-line note on what changed>     (include change-summary.md if regenerated, plus every re-rendered diagram path)
Commits:
- <sha>: <commit subject>     (likely empty — diagrams aren't committed by you)
Findings / risks:
- <short bullet, optional — surface notable deviations from requirements.md, decomposition signals, missing-context notes>
Main should read:
- <path>: <reason>     (likely empty — main reads the diagrams folder directly)

Total return must fit under ~1k tokens.
```

#### Step 2.4 — Receive the sub-agent return (main)

Validate that `<dest_dir>` contains the expected `.puml` files (at minimum the mandatory `use-case-<feature>.puml`) and that `<summary_file>` exists with valid frontmatter. If `Result: blocked` or files are missing, surface the failure to the inspector and stop — do not silently advance.

### Existing-vs-new convention (canonical PlantUML snippets — referenced by stage-2 and stage-4 diagram passes)

Use this fixed visual convention so the inspector can read every diagram the same way. The convention uses two colours: **blue for existing**, **green for new (to-be / implemented)**. Both the stage-2 `blueprint-diagrammer` sub-agent and the stage-4 `implementation-analyst` sub-agent embed this section in their working context — keep it in sync if you change either.

- **Existing — blue.** Pre-existing participants/classes/components are grouped in a blue-tinted block: `box "Existing system" #D6EAF8 … end box` (sequence) or `package "Existing" #D6EAF8 { … }` (class / use-case / component). Pre-existing message arrows, activations, and component dependencies use the matching blue stroke / fill: `A -[#3498DB]-> B` for arrows and `#D6EAF8` for activations.
- **New — green.** New participants/classes/components are grouped in a green-tinted block: `box "New" #D4EDDA … end box` (sequence) or `package "New" #D4EDDA { … }` (class / use-case / component). New arrows, activations, and dependencies use green: `C -[#27AE60]-> D` for arrows and `#D4EDDA` for activations. **Do not** use the default (uncoloured) skin for new elements — the colour is part of the convention so the diff is unambiguous.
- Each diagram includes a small legend so the convention is self-documenting:

  ```plantuml
  legend right
    |= |= Meaning |
    |<back:#D6EAF8>   </back>| existing (pre-`base-commit`) |
    |<back:#D4EDDA>   </back>| new in this implementation |
  endlegend
  ```

  At stage 2 the legend's right-column wording shifts to reflect the cycle flavor (see `docs/blueprint-regeneration.md` Step C): for a bugfix cycle the legend reads "current (wrong) behavior" / "corrected behavior"; for an improvement cycle it reads "current capability" / "improved capability"; for greenfield it reads "pre-existing context" / "to be implemented." The colours stay the same — only the legend wording adapts.

### Step 3 — Write diagrams/README.md (main)

**Generate a fresh implementation README** — do NOT copy the blueprint README. The blueprint and implementation README schemas are deliberately distinct: blueprint READMEs require `requirements-id` (and forbid other fields via `additionalProperties: false`), while implementation READMEs require `id` + `stage: implementation` and intentionally do NOT carry `requirements-id` (see `schemas/diagrams-readme-implementation.schema.yaml:8-11` for the rationale).

Use `scripts/uuid.sh` to mint the new id, then write the README manually with the literal frontmatter:

```yaml
---
id: <uuid-from-uuid.sh>
stage: implementation
---
```

Do NOT use `frontmatter.sh init diagrams-readme-implementation` — that path requires `templates/diagrams-readme-implementation.md.tmpl` which does not exist in the repo (`scripts/frontmatter.sh:20` will fail). Then validate the written file: `frontmatter.sh validate <path> diagrams-readme-implementation`.

Body: bullet list of diagrams with a one-line purpose each, with each entry tagged as either `re-rendered` (the sub-agent's Phase 3 freshly rendered this subject from `base-commit..HEAD`) or `seeded-only` (Phase 2 seeded from stage-2; no implementation commits touched this subject's area).

When at least one subject is `seeded-only`, prepend the body with a short convention note:

> *Some subjects below are tagged `seeded-only` — their `.puml` files are verbatim copies of the stage-2 blueprint diagrams. Those subjects had no implementation commits in `base-commit..HEAD`, so the stage-2 design intent is the most accurate available representation. Their legend wording (e.g., "Planned" or "to be implemented") follows stage-2 conventions; interpret them as "design preserved without implementation changes in this cycle." `re-rendered` subjects use the standard stage-4 wording against the `base-commit` baseline.*

If the implementation added a flow that wasn't in the framed requirements — `requirements.md` for an ordinary feature, or any contributor's archived `requirements.md` for a feature-test entry — or omitted one that was, call it out under a `## Notable deviations from requirements` subsection — that's a heads-up for the inspector review at stage 5. The sub-agent will have surfaced these under `Findings / risks` in its return summary; promote the relevant ones into the README here.

### Step 4 — Report

> "Implementation diagrams generated at `$dest_dir` (N diagrams). Existing-system context is shaded; new functionality is highlighted."
