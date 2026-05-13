# Side-quest sub-agent implementation plan

A user-triggered escape hatch for handling mid-workflow questions and small
fixes without polluting the main orchestrator's context. The overseer types
`/mo-sidequest "<question or ask>"`, the main agent reads the active quest's
`progress.md` to learn what workflow it is inside, classifies the question
into one of three effort tiers, and spawns a fresh sub-agent that does the
exploration in its isolated context and returns a focused answer.

The motivation: the mo-workflow already pushes large reads (codebase walks,
diff analyses, per-iteration review) into fresh sub-agents so that main's
context stays slim across stages (`docs/sub-agent-return-contract.md`). But
*ad-hoc* overseer questions and "can you fix this small thing" requests
typed mid-workflow currently land directly in main and propagate to later
stages. This feature closes that gap with an **explicitly invoked**
side-quest path — never an auto-router.

## 1. Goals

1. Give the overseer a single slash command (`/mo-sidequest`) that runs a
   mid-workflow question or small ask in an isolated sub-agent context.
2. Make the sub-agent **workflow-aware** by reading `progress.md` once at
   spawn time — no extra state file, no sidecar, no in-memory pointer the
   orchestrator must clear at workflow end.
3. Assign a soft effort budget (`quick` / `standard` / `deep`) using a
   small rubric the orchestrator applies before spawning — biased toward
   *over*-effort under uncertainty. The budget controls read/grep caps
   and answer length in the spawn prompt; it does **not** swap models
   per call (see §5 rationale).
4. Surface a clean answer to the overseer and a compact continuity line
   in main, so that two turns later "do what we just discussed" still
   works.
5. Give the sub-agent a one-shot escalation lever
   (`NEEDS_ESCALATION: <reason>`) so misclassified questions are
   re-spawned at a higher budget rather than answered badly.

## 2. Non-goals

- **No auto-classification of arbitrary overseer messages.** Steering
  ("skip step 3", "actually let's stop") and side-quests look identical
  from the outside; auto-routing would silently drop steering into a
  throwaway context. The trigger is **always** the slash command.
- **No persistent state file.** No `.sidequest.json`, no
  `quest/<slug>/sidequest-log.md`. Workflow awareness comes from
  `progress.md`, which already exists and is already maintained by
  `progress.sh`. (This is the same anti-pattern that the v0.5.0 info-bar
  feature tripped over; see `docs/stage-info-bar/plan.md` §9.)
- **No per-call model override.** The plugin's existing call sites do
  not pass `model:` to `Agent` and the override precedence between
  frontmatter and call-site is not documented anywhere we control. The
  side-quest agents therefore pin a single model in frontmatter (§5).
- **No tool-list extension at call time.** Sub-agent `tools:` is static
  frontmatter (`agents/codebase-grounder.md:6`,
  `agents/review-iteration-runner.md:6`). Read-only vs writable is
  achieved with **two agent files**, not one (§7.3).
- **No artifact catalog passed in the spawn prompt.** The sub-agent
  infers which artifacts to read from the workflow-state header plus
  the question. Hard-coding a per-stage list would drift every time the
  workflow spec changes — exactly the bug the review caught in the v1
  draft.
- **No background scheduling, no retries, no daemons.** The side-quest
  is synchronous: spawn → return → done.
- **No write access to workflow artifacts in any tier.** A side-quest
  must not silently mutate anything under the resolved data root —
  `progress.md`, `quest/`, `workflow-stream/`, blueprints, plans,
  reviews are immutable from the side-quest path regardless of `--write`.
  See §6.
- **No re-implementation of the orchestrator's job.** A side-quest may
  not advance stages, activate features, or finalize the workflow.
  Those are the existing `/mo-*` commands' responsibilities.
- **No new schema.** The slash command and the sub-agents both work off
  existing files (`progress.md`, `quest/active.md`, blueprint dir,
  implementation dir, test dir).

## 3. Trigger and surface

The overseer invokes:

```
/mo-sidequest "<question or ask, free-form>"
/mo-sidequest --quick    "<...>"
/mo-sidequest --standard "<...>"
/mo-sidequest --deep     "<...>"
/mo-sidequest --write    "<...>"      # see §6
```

The question is a single quoted string (multi-word arguments are joined by
the slash-command runtime). Flags are optional; when none of `--quick` /
`--standard` / `--deep` is present the orchestrator classifies per §5.

`--write` is a separate axis from the budget flags. It is the only way to
let the sub-agent edit files, and it selects the writable sub-agent (§7.3)
with its own gating (§6).

### 3.1 Behavior with no active workflow

If `quest.sh has-active` exits non-zero (no `quest/active.md`, or its
`status != active`), `/mo-sidequest` refuses and prints:

```
No active mo-workflow. /mo-sidequest is for mid-workflow questions.
Ask the question directly in chat, or run /mo-run to start a cycle first.
```

If a cycle is active but `progress.md → active` is `null` (pre-stage-2 or
post-stage-8), the command proceeds **at cycle scope** — the spawn prompt
omits feature-specific paths and tells the sub-agent the cycle is between
features. This is rare but legitimate (e.g., the overseer wants to ask
something about the queue between two features).

### 3.2 Where the answer is rendered

The sub-agent's return follows the existing sub-agent return contract
(`docs/sub-agent-return-contract.md`), with **two additions** — an
`Answer:` block holding the overseer-facing response, and a
`Continuity summary:` line for retention in main. The orchestrator:

1. Prints the `Answer:` block verbatim to the overseer.
2. Retains the rest of the return shape (`Result`, `Findings / risks`,
   `Main should read`, `Continuity summary`) in its own context as the
   compact record of what just happened.

No file is written for the answer by default. The overseer can pipe the
answer into the workflow if it warrants — e.g., copy a finding into
`/mo-review`, or update a goal via the next `/mo-*` command. This keeps
the side-quest from accidentally rewriting workflow artifacts.

## 4. Workflow awareness — how main learns the context

Source of truth: `progress.md` in the active cycle. The orchestrator runs
exactly these reads before classifying the question (each is cheap; no
new helper script is needed):

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
quest_slug="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh current)"        # → slug or exit≠0
progress="$data_root/quest/$quest_slug/progress.md"

# Worktree-fingerprint guard — refuses if the current working tree does not
# match the one that activated the feature. Mandatory before spawning,
# especially before --write. Exits 0 when active=null (cycle scope), so
# safe to call unconditionally. See scripts/progress.sh:767 and the
# helper `mo_verify_worktree` at scripts/internal/common.sh:308.
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh check-worktree

active_feature="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get-active)"   # → "null" or feature name
current_stage="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$progress" .active.current-stage 2>/dev/null || echo null)"
sub_flow="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$progress" .active.sub-flow 2>/dev/null || echo none)"
```

(Helper names confirmed by `scripts/progress.sh:27,:451,:767` and
`scripts/internal/common.sh:97`. `get-active` is a file read only — the
worktree guard is the separate `check-worktree` subcommand and must be
invoked explicitly. The `data-root.sh` resolution honors `MO_DATA_ROOT`
→ `CLAUDE_PLUGIN_USER_CONFIG_data_root` → default per
`scripts/internal/common.sh:16-46` — the rest of the plan must use
`$data_root` whenever it needs an absolute path, never the literal
`millwright-overseer/`.)

From those five values the orchestrator derives the spawn-prompt header:

```
Active cycle: <quest_slug>
Active feature: <active_feature | none>
Current stage: <N | null>      (stage names mirror docs/workflow-spec.md)
Sub-flow: <sub-flow value>
Data root (absolute): <data_root>
```

The sub-agent uses `Data root (absolute)` as both (a) the anchor for
"where workflow artifacts live" (so it can find them without hard-coding
`millwright-overseer/`) and (b) the forbidden prefix in the writable
variant (§6).

No artifact catalog is passed. The sub-agent reads `progress.md` itself
when it needs to confirm state, and infers the relevant artifacts from
`current_stage` plus the question — the workflow's directory shape
(`workflow-stream/<feature>/blueprints/current/`,
`…/implementation/`, `…/test/`, `quest/<slug>/`) is documented in
`docs/workflow-spec.md` and is stable enough that the sub-agent finds
the right files on its own.

## 5. Effort budgets

Three soft tiers, picked by the orchestrator using a short rubric. The
tier sets the budget the sub-agent works under; it does **not** change
the model. Both side-quest agents pin `model: sonnet` in frontmatter
(§7.3 rationale).

| Tier       | Read budget                     | Answer length    | Typical questions                                          |
| ---------- | ------------------------------- | ---------------- | ---------------------------------------------------------- |
| `quick`    | ≤ 3 file reads, ≤ 1 grep        | ≤ 200 words      | "what does this symbol do", "where is X defined"           |
| `standard` | ≤ 10 file reads, ≤ 5 greps      | ≤ 500 words      | "how does X interact with Y", "is the plan covering Z"     |
| `deep`     | unconstrained                   | full reasoning   | "audit this module", "design an alternative", "why is X slow" |

### 5.1 Rubric (applied by orchestrator before spawn)

The orchestrator scores the user's question on three cheap signals:

1. **Scope** — does the question name one symbol/file (narrow) or a whole
   module / "the codebase" / "the workflow" (broad)?
2. **Action verb** — `explain` / `show` / `list` / `where` → narrow;
   `refactor` / `audit` / `design` / `propose` / `why is X slow` → broad.
3. **Concreteness** — named file + line, or a specific IR-ID, vs.
   open-ended "what's going on with X".

Tier assignment:

- All three signals narrow → `quick`.
- Mixed, or one broad signal → `standard`.
- Two or more broad signals, or any `design` / `audit` / `refactor` verb
  → `deep`.

**Bias up under uncertainty.** When two adjacent tiers are plausible the
orchestrator picks the higher one. Under-budget costs a re-spawn round
trip via escalation (§5.3); over-budget costs only tokens.

### 5.2 Overrides

The flags `--quick` / `--standard` / `--deep` override the rubric. They
are the right answer when the overseer already knows the question's
shape better than any heuristic will. The orchestrator's rendered echo
notes the override so the overseer can confirm:

```
sidequest: tier=deep (overridden)
sidequest: tier=standard (rubric: scope=narrow, verb=audit→broad, concreteness=narrow)
```

The echo is one line, printed before the sub-agent is spawned. It exists
so the overseer can `Ctrl-C` and retry with a different tier if the
classification is obviously wrong.

### 5.3 Escalation protocol

If the sub-agent realizes mid-task that the question is bigger than its
budget assumed, it returns a single line as the **first line** of its
output:

```
NEEDS_ESCALATION: <one-sentence reason>
```

…and nothing else. The orchestrator detects that token, re-spawns the
side-quest one tier higher (`quick → standard`, `standard → deep`), and
forwards the original question plus the reason. `deep` cannot escalate
further; a `deep` sub-agent that hits its ceiling returns a normal
`Result: partial` with the limitation in `Findings / risks` instead.

Escalation is **one-shot**. The orchestrator does not loop on escalation
— a sub-agent that escalates twice in a row would suggest the rubric is
wrong, not that the budget is too tight.

### 5.4 Two distinct first-line sentinels

Two different signals can be emitted by a side-quest sub-agent. They
share the "first non-blank line, nothing else" shape but have different
semantics, so they use distinct tokens — Step 6 handlers them in two
separate branches (§7.1.6):

- `NEEDS_ESCALATION: <reason>` — the sub-agent's *budget* (read caps,
  answer length) was too tight for the question. The orchestrator
  re-spawns at the next tier.
- `WRITE_REQUIRED: <reason>` — the read-only sub-agent has determined
  the ask cannot be satisfied without source edits. The orchestrator
  does **not** auto-promote to the writer; instead it surfaces the
  reason and asks the overseer to re-run with `--write`. Write-mode is
  an explicit overseer decision by design (§6.1).

Keeping the two sentinels distinct avoids a real bug in an earlier
revision of this plan: that revision told the reader to emit
`NEEDS_ESCALATION: question requires --write`, which would have
triggered the tier-escalation handler and re-run the question at
`standard` instead of asking the overseer for `--write`. The token
distinction is what fixes that (recorded in §12 fold-in #5).

### 5.5 Why one model, not three

The plan originally suggested per-tier model selection (haiku / sonnet
/ opus). The review surfaced two problems with that approach:

1. Sub-agent `model:` is set in frontmatter, and no command in this
   plugin invokes `Agent` with a per-call `model:` override
   (`commands/mo-review.md:262`,
   `commands/mo-generate-implementation-diagrams.md:88`). The override
   may or may not be honored — the precedence vs frontmatter is not
   documented anywhere we control.
2. Three agent files (one per tier) crossed with two access modes
   (read-only / writable) is six files, all with nearly-identical
   bodies. Drift between the six would be inevitable.

So the design pins `sonnet` for both side-quest agents. Sonnet is
capable enough for the `deep` budget in practice; if the `deep` case
turns out to need opus, the right answer is to *swap* the writer's (or
reader's) frontmatter, not to introduce a tier→model matrix the rest
of the plugin doesn't use.

## 6. Write access — `--write` flag

Default behavior: read-only. The slash command spawns
`sidequest-reader` whose frontmatter declares
`tools: [Read, Grep, Bash]` — Bash is included only to call
`frontmatter.sh get` / `quest.sh dir` / similar read helpers through
the standard project entry points.

`--write` selects the `sidequest-writer` agent instead, whose
frontmatter declares `tools: [Read, Grep, Bash, Edit, Write]`. The
writable agent's spawn prompt adds these rules:

1. **Allowed paths** — the project source tree under
   `workspace.project_dir`, excluding the resolved data root.
2. **Forbidden paths** — everything under the absolute `$data_root`
   passed in the spawn-prompt header (so `progress.md`, `quest/`,
   `workflow-stream/`, blueprints, plans, reviews, test artifacts are
   immutable from the side-quest path regardless of where the user
   pointed their data root via `MO_DATA_ROOT` /
   `CLAUDE_PLUGIN_USER_CONFIG_data_root`).
3. **No git operations beyond `git status` / `git diff`.** Commits,
   branch creation, worktree manipulation are forbidden — those are
   the workflow commands' jobs.
4. **No `progress.sh` / `quest.sh` / `frontmatter.sh set` invocations.**

If the user invokes `--write` alone without a tier flag, the
orchestrator classifies normally. A `--write` side-quest typically
lands in `standard` or `deep` because "fix this" verbs are broad —
the rubric handles it.

### 6.1 Why `--write` is opt-in and a separate agent

Two reasons:

- **Most mid-workflow asks are questions.** Defaulting to read-only
  keeps the lightweight case lightweight, and the read-only agent
  literally lacks `Edit` / `Write` in its tool list — so a Q&A
  side-quest cannot accidentally mutate anything even if the spawn
  prompt has a bug.
- **A silent write during a workflow can invalidate the in-flight
  stage's contract.** If stage 4 is mid-execution and a side-quest
  rewrites `src/foo.ts`, the resume-handler's drift check at stage 4
  may fire on the next `/mo-continue`. Forcing the overseer to type
  `--write` keeps that decision explicit.

A side-quest that **does** rewrite source code returns the list of
touched files under `Artifacts changed`, exactly like any other
sub-agent. The next `/mo-continue` drift check picks the change up
normally.

## 7. Files

```
agents/sidequest-reader.md                 new — read-only sub-agent (Q&A)
agents/sidequest-writer.md                 new — writable sub-agent (--write only)
commands/mo-sidequest.md                   new — slash-command spec
docs/side-quest/plan.md                    this file
README.md                                  +1 paragraph under "Optional companions"
templates/sub-agent-return.md.tmpl         edit — add the `Answer:` and `Continuity summary:` lines
docs/sub-agent-return-contract.md          edit — document the two new fields and that they are side-quest-specific
```

No new script. No new schema. No new template beyond the return-shape edit.

### 7.1 `commands/mo-sidequest.md`

Frontmatter:

```yaml
---
description: Run a mid-workflow question or small ask in an isolated sub-agent context so it does not pollute the main orchestrator. Reads the active quest's progress.md to learn workflow state. Three effort budgets (quick/standard/deep) auto-selected by rubric; override with --quick / --standard / --deep. --write selects the writable side-quest sub-agent so source-code edits are allowed (workflow artifacts remain read-only). Refuses outside an active workflow.
---
```

The command body has six steps.

#### 7.1.1 Step 1 — Parse arguments

Split `$ARGUMENTS` into:

- An optional tier flag (`--quick` | `--standard` | `--deep`). At most one.
- An optional `--write` flag.
- The remaining tokens, joined with single spaces → `question`.

If `question` is empty after parsing, print:

```
Usage: /mo-sidequest [--quick | --standard | --deep] [--write] "<question>"
```

…and exit. Multiple tier flags is an error with the same usage line.

#### 7.1.2 Step 2 — Resolve workflow state

Run the reads from §4 in order:

1. `data-root.sh` → `$data_root`.
2. `quest.sh current` → `$quest_slug`. If this exits non-zero, print
   the §3.1 refusal and exit.
3. `progress.sh check-worktree`. **Mandatory before any spawn**,
   especially under `--write` — the worktree-fingerprint mismatch
   message surfaces to the overseer with the canonical text from
   `mo_verify_worktree` (`scripts/internal/common.sh:308-365`). The
   slash command does not catch this error; the user sees it and the
   side-quest does not spawn.
4. `progress.sh get-active`, `frontmatter.sh get` for `current-stage`
   and `sub-flow`.

If `active_feature == "null"` and `current_stage == null`, set scope to
**cycle**; otherwise **feature**.

#### 7.1.3 Step 3 — Classify (skipped on explicit tier override)

Apply the §5.1 rubric. Print the one-line echo from §5.2 so the overseer
sees the chosen tier.

#### 7.1.4 Step 4 — Pick the sub-agent

- `--write` absent → `subagent_type:
  millwright-overseer-development-machine:sidequest-reader`.
- `--write` present → `subagent_type:
  millwright-overseer-development-machine:sidequest-writer`.

No further pre-spawn computation is needed — the sub-agent infers which
artifacts to read from the workflow-state header in the spawn prompt
plus the question, per §4.

#### 7.1.5 Step 5 — Spawn the sub-agent

Invoke `Agent` with the selected `subagent_type`. Do **not** pass a
per-call `model:` — both side-quest agents pin sonnet in frontmatter
(§5.4). The orchestrator passes only the prompt.

The spawn prompt is the §7.2 template with these substitutions:

- `<tier>` — `quick` | `standard` | `deep`
- `<write_mode>` — `read-only` | `write-allowed`
- `<scope>` — `cycle` | `feature`
- `<quest_slug>`, `<active_feature>`, `<current_stage>`, `<sub_flow>`,
  `<data_root>` (all from §4)
- `<question>` — verbatim from §7.1.1
- `<escalation_reason>` — empty on first spawn; populated on re-spawn

#### 7.1.6 Step 6 — Render the return

On return, parse the sub-agent's output. Sentinel handling runs **in
order**; the first match wins:

1. **`WRITE_REQUIRED: <reason>` as the first non-blank line.** The
   read-only sub-agent has determined the ask cannot be answered without
   edits. Do NOT re-spawn — write-mode is an explicit overseer decision,
   never automatic. Print:

   ```
   sidequest: reader returned WRITE_REQUIRED → re-run with --write
     reason: <reason>
   ```

   …and exit. (Distinct sentinel because it shares a return shape with
   `NEEDS_ESCALATION` but means a different thing — see §5.4.)

2. **`NEEDS_ESCALATION: <reason>` as the first non-blank line, tier ≠
   `deep`.** Re-invoke with `tier := <tier>+1` and
   `<escalation_reason> := <reason>` (same sub-agent file — the
   reader/writer split is set by `--write`, not by tier). Print:

   ```
   sidequest: tier=<previous> returned NEEDS_ESCALATION → re-spawning at <next>
     reason: <reason>
   ```

3. **`NEEDS_ESCALATION: <reason>` at tier `deep`.** Cannot escalate
   further. Surface as a `Result: partial` and print the reason as a
   `Findings / risks` bullet. Ask the overseer to narrow or split the
   question.

4. **Otherwise** — extract the `Answer:` block (§7.4) and print it
   verbatim to the overseer.

5. Print a one-line trailer:

   ```
   sidequest: complete · tier=<tier> · result=<success|partial|blocked>
   ```

The structured part of the return (Result / Findings / Continuity
summary / Main should read / Artifacts changed) is naturally retained in
main's context as the tool result. No further main-side action is taken
unless the sub-agent populated `Artifacts changed` (in which case a
follow-up `/mo-continue` will pick the edits up via the existing drift
check — main does not need to read the edited files itself).

### 7.2 Spawn-prompt template

```
You are a fresh sub-agent invoked from /mo-sidequest. Your context is
isolated from the main session — main does not see your tool calls,
only your final return summary.

Tier: <tier>          (budget table in your behavioral defaults)
Write mode: <write_mode>
Scope: <scope>

Workflow state (read at spawn from progress.md, may have advanced since):
- Active cycle: <quest_slug>
- Active feature: <active_feature>
- Current stage: <current_stage>
- Sub-flow: <sub_flow>
- Data root (absolute): <data_root>

Workflow artifacts live under <data_root>. Use the documented directory
shape (workflow-stream/<feature>/blueprints/current/, .../implementation/,
.../test/, quest/<slug>/) to find what the question needs. Read narrowly;
do not bulk-read directories.

Overseer question:
<<<
<question>
>>>

<if escalation_reason is non-empty>
This is a re-spawn after a tier=<previous> sub-agent returned
NEEDS_ESCALATION with reason:
<<<
<escalation_reason>
>>>
Treat that reason as a hint about where the previous tier ran out of
budget; do not start over from scratch if the hint suggests a focused
direction.
</if>

Return shape: follow docs/sub-agent-return-contract.md with the two
side-quest additions described in templates/sub-agent-return.md.tmpl
(`Answer:` block and `Continuity summary:` line). Total return ≤ 1.5k
tokens. If the question is bigger than your tier budget, return exactly
one line: `NEEDS_ESCALATION: <one-sentence reason>` and stop.
```

### 7.3 Two sub-agent files

The plugin's sub-agent tool list is static frontmatter
(`agents/codebase-grounder.md:6`,
`agents/review-iteration-runner.md:6`). To support both read-only Q&A
and `--write` small-fix mode, the plan ships two near-identical agent
files. Their bodies are intentionally near-identical — the only
differences are the `tools:` line and the write-mode rules in the
behavioral defaults.

`agents/sidequest-reader.md`:

```yaml
---
name: sidequest-reader
description: Mid-workflow Q&A sub-agent. Spawned by /mo-sidequest without --write. Reads workflow state from progress.md (passed in spawn prompt), answers the overseer's question, and returns a structured response with an Answer block for the overseer plus a Continuity summary line for main. Read-only — no Edit / Write.
model: sonnet
tools: [Read, Grep, Bash]
---

You are a fresh sub-agent invoked from /mo-sidequest. The spawn prompt
gives you (1) the overseer's question, (2) the active quest / feature /
stage context, (3) the absolute data root, (4) your tier, and (5)
`Write mode: read-only`.

Behavioral defaults — budget per tier:
- quick: at most 3 file reads, at most 1 grep, ≤ 200-word answer.
- standard: at most 10 file reads, at most 5 greps, ≤ 500-word answer.
- deep: unconstrained reads; favor a thorough answer over a short one.

Behavioral defaults — discipline:
- Read narrowly. Use Grep + symbol search first; escalate to whole-file
  reads only when a signature / line range is genuinely insufficient.
- Workflow artifacts live under the absolute data root from your spawn
  prompt. Use that path; never hard-code `millwright-overseer/`.
- You do not have Edit or Write in your tool list. If the question
  cannot be answered without edits, return exactly
  `WRITE_REQUIRED: <one-sentence reason>` as the first line and stop —
  the slash command will surface that to the overseer, who can re-run
  with --write. Do NOT use `NEEDS_ESCALATION` for this case; that
  sentinel is reserved for budget-tier escalation and would be handled
  differently.
- If you find that the question is bigger than your tier budget, return
  exactly `NEEDS_ESCALATION: <reason>` as the first line and nothing
  else. Do not partially answer first.

Return shape: docs/sub-agent-return-contract.md plus the two side-quest
additions. Include every standard field — `Artifacts changed:` and
`Commits:` are present even on a read-only Q&A (empty bullet lists are
allowed per the contract). The full block:

  Answer:
  <free-form response shown verbatim to the overseer; markdown is fine>

  Continuity summary:
  <one line, ≤ 20 words, suitable for retention in main's context — what
   was asked and the gist of the answer>

  Result: success | partial | blocked
  Artifacts changed:
  (empty for the reader — you cannot write)
  Commits:
  (empty for the reader — you cannot commit)
  Findings / risks:
  - <main-actionable bullets, optional>
  Main should read:
  - <paths, optional — usually empty for a side-quest>
```

`agents/sidequest-writer.md`:

```yaml
---
name: sidequest-writer
description: Mid-workflow small-fix sub-agent. Spawned by /mo-sidequest --write. Reads workflow state from progress.md (passed in spawn prompt), answers and / or performs a small constrained fix, and returns a structured response with an Answer block, Continuity summary, and any touched files under Artifacts changed. Edits allowed in the project source tree only — workflow artifacts under the data root are read-only.
model: sonnet
tools: [Read, Grep, Bash, Edit, Write]
---

You are a fresh sub-agent invoked from /mo-sidequest --write. The spawn
prompt gives you (1) the overseer's question / ask, (2) the active
quest / feature / stage context, (3) the absolute data root, (4) your
tier, and (5) `Write mode: write-allowed`.

Behavioral defaults — budget per tier:
- quick: at most 3 file reads, at most 1 grep, ≤ 200-word answer.
- standard: at most 10 file reads, at most 5 greps, ≤ 500-word answer.
- deep: unconstrained reads; favor a thorough answer over a short one.

Behavioral defaults — discipline:
- Workflow artifacts live under the absolute data root from your spawn
  prompt. **Edits anywhere under that absolute path are forbidden** —
  progress.md, quest/, workflow-stream/, blueprints, plans, reviews,
  test artifacts. Edits in the surrounding project source tree are fine.
- No `git commit`, no branch creation, no worktree manipulation. Only
  `git status` and `git diff` are allowed. The next `/mo-continue` will
  pick up your edits via the existing drift check.
- Do not call `progress.sh` / `quest.sh` set helpers, or
  `frontmatter.sh set` on any workflow artifact.
- Read narrowly. Use Grep + symbol search first; escalate to whole-file
  reads only when a signature / line range is genuinely insufficient.
- If you find that the ask is bigger than your tier budget, return
  exactly `NEEDS_ESCALATION: <reason>` as the first line and nothing
  else. Do not partially apply edits first.

Return shape: docs/sub-agent-return-contract.md plus the two side-quest
additions. Include every standard field — `Commits:` is present even
though you cannot commit (empty bullet list per the contract). The full
block:

  Answer:
  <free-form response shown verbatim to the overseer; markdown is fine>

  Continuity summary:
  <one line, ≤ 20 words, suitable for retention in main's context — what
   was asked / done and the gist>

  Result: success | partial | blocked
  Artifacts changed:
  - <path>: <one-line note on what changed>
  Commits:
  (empty — you cannot commit; the next /mo-continue will pick up your edits)
  Findings / risks:
  - <main-actionable bullets, optional>
  Main should read:
  - <paths, optional — usually empty for a side-quest>
```

Drift discipline: when one agent's behavioral defaults change, the other
must be updated in the same commit. The two files share enough body
that a stray edit in one is a real risk; PR reviewers should flag any
change that touches only one of them.

### 7.4 Return-template additions

Append to `templates/sub-agent-return.md.tmpl`:

```
## Side-quest additions (only for sidequest-reader / sidequest-writer)

In addition to the standard fields, side-quest returns include two extra
blocks. They are emitted at the top of the return, before `Result:`.

Answer:
  Free-form response intended for the overseer. The /mo-sidequest
  slash command prints this block verbatim. Markdown is allowed.

Continuity summary:
  Single line, ≤ 20 words. Retained in main's context. Should make sense
  to a reader who did not see the Answer block — e.g. "Overseer asked
  whether the rate-limiter fix touches both the API and CLI paths;
  confirmed it only touches the API path."

Two first-line sentinels are mutually exclusive with the rest of the
return shape. When emitted, the sentinel MUST be the first non-blank
line and the sub-agent emits nothing else:

- `NEEDS_ESCALATION: <reason>` — the budget was too tight for the
  question. The orchestrator re-spawns at the next tier. Reader and
  writer both use this.
- `WRITE_REQUIRED: <reason>` — reader-only. The question cannot be
  answered without edits; the orchestrator surfaces this to the
  overseer rather than auto-promoting to the writer (write-mode is
  always an explicit decision).
```

`docs/sub-agent-return-contract.md` gets a corresponding one-paragraph
section pointing at the template's side-quest block.

### 7.5 `README.md` addition

Under "Optional companions":

> **Side-quest sub-agent.** `/mo-sidequest "<question>"` runs a
> mid-workflow question or small ask in an isolated sub-agent context so
> the question does not leak into the main orchestrator's context. The
> sub-agent reads workflow state from `progress.md` at spawn, classifies
> the question into one of three effort budgets (`quick` / `standard` /
> `deep`), and returns a focused answer plus a one-line continuity
> summary that main retains. Add `--write` to invoke the writable
> variant if the side-quest needs to edit source files (workflow
> artifacts remain read-only). Refuses outside an active workflow.

## 8. Edge cases

- **Question references a stale stage.** The sub-agent reads
  `progress.md` once (via the snapshot in its spawn prompt); the workflow
  may advance during the side-quest. This is acceptable — the side-quest
  is for the state at spawn time. If the answer depends on a value that
  changed (e.g., the overseer asked "is stage 5 done" mid-`/mo-continue`),
  the answer is correct *as of spawn* and the overseer can re-ask.
- **Side-quest takes longer than the next stage's drift threshold.**
  Under `--write`, if the sub-agent edits source while `/mo-continue` is
  later run, the resume handler's drift check fires normally — this is
  the right behavior; we want drift to be visible.
- **Custom data-root location.** A user with
  `userConfig.data_root: .mo-data` (or any other value) is protected by
  the same write-forbidden rule — the slash command resolves
  `data-root.sh` and passes the absolute path into the spawn prompt, so
  the writable agent's forbidden-path check is "anywhere under
  `<resolved abs path>`," not "anywhere under `millwright-overseer/`."
- **NEEDS_ESCALATION echoed by a deep-tier sub-agent.** A `deep`
  side-quest cannot escalate further. The orchestrator treats it as a
  `Result: partial` and prints the reason as a finding, asking the
  overseer to narrow the question or split it across multiple
  `/mo-sidequest` calls.
- **Read-only sub-agent asked to edit.** The reader's tool list omits
  Edit / Write. The reader's instructions tell it to return
  `WRITE_REQUIRED: <reason>` in that case (a separate sentinel from
  `NEEDS_ESCALATION` — see §5.4). Step 6's first branch surfaces this
  to the overseer rather than auto-escalating to the writer; write-mode
  is an explicit decision, never automatic.
- **Sub-agent crashes / returns malformed output.** The slash command's
  fallback is `Result: blocked` with the raw output preserved under
  `Findings / risks`. The overseer can re-run.
- **Overseer runs two `/mo-sidequest`s in quick succession.** Each
  spawns its own sub-agent — there is no shared state between
  side-quests by design. If the overseer wants continuity across
  side-quests, the second question should reference the first explicitly.
- **`progress.md` mid-write at spawn time.** `progress.sh` writes via
  temp file + `os.replace`, so the orchestrator either sees the old or
  new state — never torn. No retry loop needed.
- **`/mo-sidequest` is called from inside a worktree the workflow does
  not own.** Step 2 explicitly invokes `progress.sh check-worktree`
  (`scripts/progress.sh:767`), which delegates to `mo_verify_worktree`
  (`scripts/internal/common.sh:308-365`). On mismatch the helper prints
  the canonical worktree-mismatch message and exits non-zero; the
  slash command does not catch this, so the user sees the error and the
  side-quest does not spawn. The guard is a no-op when `active=null`
  (cycle scope), so it is safe to call unconditionally before
  classification.
- **Side-quest invoked at stage 1.5 (queue-rationale review).** Treated
  as cycle scope per §3.1 — feature paths are absent; questions about
  the queue order use the directory shape under `<data_root>/quest/`.

## 9. Implementation steps

1. Edit `templates/sub-agent-return.md.tmpl` per §7.4 (additive).
2. Edit `docs/sub-agent-return-contract.md` per §7.4 (one paragraph
   pointing at the template's new block).
3. Add `agents/sidequest-reader.md` per §7.3.
4. Add `agents/sidequest-writer.md` per §7.3, keeping body intentionally
   near-identical to the reader (only `tools:` line and the
   write-discipline bullets differ).
5. Add `commands/mo-sidequest.md` per §7.1 — six numbered steps,
   spawn-prompt template at the end of the file.
6. Edit `README.md` per §7.5.
7. Smoke tests:
   - **No active workflow.** `/mo-sidequest "anything"` → refusal per
     §3.1.
   - **Quick tier auto.** Active stage-3 feature, question "where is
     `parseToken` defined" → tier=quick, answer references one file,
     no escalation.
   - **Standard tier auto.** Stage-3, "is the implementation primer
     covering the refresh-token path" → tier=standard, sub-agent reads
     `primer.md` and `requirements.md`, answer cites both.
   - **Deep tier auto.** Stage-4, "audit the rate-limiter implementation
     end to end" → tier=deep, multi-file walk; budget unconstrained.
   - **Override.** `--quick` on a deep-feeling question → respected;
     echo shows `(overridden)`; if the question is truly too big, the
     sub-agent escalates to standard.
   - **Escalation chain.** Construct a question where quick escalates
     to standard. Verify the orchestrator's re-spawn message and that
     `escalation_reason` reaches the sub-agent's spawn prompt.
   - **Cycle scope.** Run between features (`active=null`, queue
     non-empty). Sub-agent answers a queue question without erroring
     on missing feature paths.
   - **Read-only sub-agent asked to edit.** Question phrased as a fix
     ("rename X to Y in src/foo.ts") without `--write` → reader returns
     `WRITE_REQUIRED: <reason>`; orchestrator's Step 6 first branch
     fires, prints "re-run with --write" and exits. Critically: the
     orchestrator does NOT re-spawn at a higher tier — that would
     happen if the reader incorrectly emitted `NEEDS_ESCALATION`
     instead. Verify by inspecting the trailer (no "re-spawning at"
     message).
   - **Worktree-mismatch guard.** From a checkout that is not the
     activator worktree, run `/mo-sidequest "anything"`. Expect:
     `progress.sh check-worktree` prints the canonical mismatch
     message and exits non-zero; the side-quest does not spawn.
     Repeat with `--write` to confirm the guard fires before any
     sub-agent invocation.
   - **`--write` allowed path.** Sub-agent edits a file under
     `src/` → return lists it under `Artifacts changed`; next
     `/mo-continue` drift check picks it up.
   - **`--write` forbidden path under default data root.** Sub-agent
     attempts to edit `<project>/millwright-overseer/quest/<slug>/progress.md`
     → refuses; `Result: blocked` with a clear finding.
   - **`--write` forbidden path under custom data root.** Set
     `MO_DATA_ROOT=.mo-data`; spawn a writable side-quest; sub-agent
     attempts to edit a file under `.mo-data/`; refuses identically.
     This validates the resolved-abs-path rule (§6 / §7.2).
   - **Manual-test artifact path.** Question at stage 7 referencing
     "the manual-test plan" — sub-agent finds
     `<data_root>/workflow-stream/<feature>/test/manual-test-plan.md`
     via the documented directory shape, NOT `implementation/`.
   - **Malformed return.** Force a sub-agent to return garbage →
     orchestrator prints `Result: blocked` and shows raw output under
     `Findings / risks`. No crash.
8. Bump plugin version per the project's standard cadence (next minor
   after current `0.8.2` → `0.9.0`, given this adds a new top-level
   slash command + sub-agents).

## 10. Why this is safe to land

| Risk                                                  | Mitigation in this plan                                                |
| ----------------------------------------------------- | ---------------------------------------------------------------------- |
| Auto-routing eats legitimate steering messages        | No auto-routing; the trigger is always the explicit slash command.    |
| State file persists past workflow end                 | No state file; spawn-time read of `progress.md` is the only source.   |
| Mid-workflow writes invalidate stage contracts        | Read-only sub-agent by default; writer's forbidden-path rule excludes the resolved absolute `$data_root`. |
| Misclassified tier wastes a round trip                | One-shot `NEEDS_ESCALATION` escape hatch; bias-up rubric reduces miss rate. |
| Side-quest answer reintroduces bloat into main        | Full Answer is shown to overseer; main only retains the structured fields, including the ≤20-word Continuity summary. |
| Hard-coded `millwright-overseer/` in write-scope rule | Slash command resolves `data-root.sh` and passes the absolute path; agent's forbidden-prefix check uses it. Works under `MO_DATA_ROOT` / `CLAUDE_PLUGIN_USER_CONFIG_data_root` overrides. |
| Tool-list extension at call time (unsupported)        | Two static agent files (reader / writer). Slash command picks one based on `--write`. |
| Per-call model override (unverified)                  | Both agents pin `sonnet` in frontmatter. Tier is budget-only, not model. |
| Two near-identical agent files drift apart            | Documented drift discipline (§7.3); PR reviewers flag any change that edits only one file. |
| "Needs --write" signal collides with tier escalation  | Distinct sentinel `WRITE_REQUIRED: <reason>` (§5.4) handled by a separate first branch in Step 6 (§7.1.6). The orchestrator never auto-promotes reader → writer. |
| Sidequest returns drop canonical contract fields      | Both agent return shapes (§7.3) include `Artifacts changed:` and `Commits:` with empty bullets where applicable, per `templates/sub-agent-return.md.tmpl`. |
| Worktree-fingerprint guard assumed but not invoked    | Step 2 (§7.1.2) calls `progress.sh check-worktree` explicitly before classification, especially before `--write`. The helper is a no-op when `active=null`. |
| Stale `progress.md` snapshot if workflow advances     | Documented as accepted; answer is "as of spawn time"; overseer can re-ask. |

Remaining limitations — explicitly accepted:

- The orchestrator's full Answer is technically present in main's tool
  result, but the practical win is that the *exploration* (file reads,
  greps, multi-file reasoning) lived in the sub-agent's context, not
  main's. The Continuity summary is what main *keeps as record* after
  the Answer scrolls out of working attention.
- A `deep` side-quest that exhausts sonnet's working budget cannot
  escalate further; the overseer must split the question. If practice
  shows sonnet is undersized for the `deep` case, the right answer is
  to swap the deep agent's `model:` frontmatter, not to reintroduce
  a tier→model matrix.
- `--write` side-quests do not interact with the resume-handler beyond
  what the existing drift check provides. We rely on that mechanism;
  this feature adds no new drift logic.

## 11. Open decisions (for review)

These are pinned for the reviewer to confirm or override before
implementation begins. Decisions 1–3 from the v1 draft were closed by
the v2 review pass; what remains:

1. **Continuity-summary length cap.** Plan picks ≤ 20 words. Reviewer:
   confirm or pick a different cap. (The point is "one line"; the word
   count is a soft enforcement.)
2. **Cycle-scope behavior.** Plan proceeds at cycle scope when
   `active=null`. Reviewer: confirm, or change to "refuse unless a
   feature is active" if the cycle case feels too rare to support.
3. **Version bump.** Plan picks `0.9.0` (new top-level slash command).
   Reviewer: confirm, or pick `0.8.3` if treated as additive.
4. **Should the answer ever be persisted?** Plan says no — answers are
   ephemeral; if the overseer wants the answer in the workflow, the
   regular `/mo-*` commands are the right path. Reviewer: confirm, or
   add an optional `--save <name>` flag that writes to
   `quest/<slug>/sidequests/<timestamp>-<name>.md`. (Recommendation:
   defer to a future ticket if requested; not needed for v1.)
5. **Sonnet for the `deep` budget.** Plan pins both side-quest agents
   to sonnet (§5.4). Reviewer: confirm, or override to opus for the
   writer only (small-fix correctness matters more than a Q&A answer).

## 12. Review fold-ins (v2)

These are the resolutions to the four findings from the first review
pass, folded into the body above. Recorded here so a future re-review
can see what changed and why.

1. **Tool-list extension at call time was unsupported.** Original draft
   said `--write` would "extend the tool list" of a single agent. Sub-
   agent `tools:` is static frontmatter. Resolution: two agent files
   (`sidequest-reader.md`, `sidequest-writer.md`). See §7.3.
2. **Per-tier model override was unverified.** Original draft said the
   orchestrator would pass `model: <haiku|sonnet|opus>` per call. No
   command in this plugin invokes `Agent` with a `model:` override;
   the override's precedence vs frontmatter is not documented anywhere
   we control. Resolution: pin `sonnet` in both agents' frontmatter;
   tier becomes budget-only (read caps + answer length), not a model
   selector. See §5.4 and §7.3.
3. **Artifact catalog had stale paths.** Original §4 catalog listed
   `implementation/plan.md` (no such artifact — the chain's plan files
   live under `docs/superpowers/` and are intentionally untracked per
   `docs/workflow-spec.md:237,:747`) and put manual-test artifacts
   under `implementation/` (actual location is
   `workflow-stream/<feature>/test/` per `docs/workflow-spec.md:242`
   and `scripts/blueprints.sh:534-541`). Resolution: drop the catalog
   entirely. The sub-agent infers from the workflow-state header plus
   the documented directory shape, which avoids drift on every
   workflow-spec change. See §4 (no catalog) and §2 (non-goal).
4. **Write-scope hard-coded `millwright-overseer/`.** Data root is
   configurable via `MO_DATA_ROOT` / `CLAUDE_PLUGIN_USER_CONFIG_data_root`
   / default (`scripts/internal/common.sh:16-46`). A user with a custom
   path got no protection. Resolution: slash command resolves
   `data-root.sh` once (§4) and passes the absolute path into the
   spawn prompt as `Data root (absolute)`; writer's forbidden-prefix
   rule (§6) checks that absolute path. Smoke test covers the custom
   data root case (§9 step 7).
5. **Token collision: `NEEDS_ESCALATION: question requires --write`.**
   The earlier revision had the reader emit `NEEDS_ESCALATION` for the
   "needs --write" case, which the generic Step 6 handler would have
   treated as a tier escalation and re-run the question at `standard`
   instead of surfacing the request for `--write`. Resolution: distinct
   sentinel `WRITE_REQUIRED: <reason>` for the write-mode signal; Step
   6 grows a first branch that handles it without re-spawning (§5.4
   introduces the distinction; §7.1.6 handles it; reader's behavioral
   defaults emit the new token).
6. **Sidequest return shapes dropped canonical-contract fields.** The
   reader example omitted both `Artifacts changed:` and `Commits:`;
   the writer example omitted `Commits:`. The contract
   (`templates/sub-agent-return.md.tmpl:11`) requires both fields with
   empty bullet lists allowed (`docs/sub-agent-return-contract.md:15`).
   Resolution: both agents' return shapes now show the full standard
   block; the reader's `Artifacts changed` and `Commits` are documented
   as always-empty, the writer's `Commits` as always-empty (with a
   note that the next `/mo-continue` handles commit creation).
7. **Worktree guard was assumed, not invoked.** §8 said the §4 reads
   "already error" via `mo_verify_worktree`, but the listed reads
   (`quest.sh current`, `progress.sh get-active`, `frontmatter.sh get`)
   do not call the guard — `mo_verify_worktree` is exposed as the
   separate subcommand `progress.sh check-worktree`
   (`scripts/progress.sh:767`). Resolution: §4 reads now include an
   explicit `progress.sh check-worktree` call; Step 2 (§7.1.2) lists
   it as mandatory before any spawn, especially under `--write`.
