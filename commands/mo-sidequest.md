---
description: Run a mid-workflow question or small ask in an isolated sub-agent context so it does not pollute the main orchestrator. Reads the active quest's progress.md to learn workflow state. Three effort budgets (quick/standard/deep) auto-selected by rubric; override with --quick / --standard / --deep. --write selects the writable side-quest sub-agent so source-code edits are allowed (workflow artifacts remain read-only). Refuses outside an active workflow.
---

# mo-sidequest

A user-triggered escape hatch for handling mid-workflow questions and small fixes without polluting the main orchestrator's context. The overseer types `/mo-sidequest "<question or ask>"`, you read the active quest's `progress.md` to learn workflow state, classify the question into one of three effort budgets, and spawn a fresh side-quest sub-agent that does the exploration in its isolated context and returns a focused answer.

The trigger is **always** explicit. This command exists because ad-hoc questions and small fixes typed in chat land directly in main and propagate to later stages; clear-points (`docs/clear-points/plan.md`) flush context at fixed gates but do nothing for the *exploration cost* of a single mid-stage question — that is what this command addresses. See `docs/side-quest/plan.md` for the full design.

## Usage

```
/mo-sidequest "<question or ask>"
/mo-sidequest --quick    "<...>"
/mo-sidequest --standard "<...>"
/mo-sidequest --deep     "<...>"
/mo-sidequest --write    "<...>"
```

Flags:

- `--quick` / `--standard` / `--deep` — override the auto-classified tier (§ Step 3). At most one. They control the sub-agent's *budget* (read caps, answer length), not the model.
- `--write` — select the writable side-quest sub-agent (`sidequest-writer`) instead of the read-only one (`sidequest-reader`). Required for any ask that needs to edit source files. Workflow artifacts under the resolved `data_root` remain immutable regardless.

## Execution

### Step 1 — Parse arguments

Split `$ARGUMENTS` into:

- An optional tier flag (`--quick` | `--standard` | `--deep`). At most one.
- An optional `--write` flag.
- The remaining tokens, joined with single spaces → `question`.

If `question` is empty after parsing, print:

```
Usage: /mo-sidequest [--quick | --standard | --deep] [--write] "<question>"
```

…and exit. Multiple tier flags is the same usage error.

### Step 2 — Resolve workflow state

Run the reads below in order. The slash command does not catch errors from these calls — if any of them prints an error and exits non-zero (worktree mismatch, missing active quest), the overseer sees that error and the side-quest does not spawn.

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
quest_slug="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh current)"      # exits non-zero if no active quest
progress="$data_root/quest/$quest_slug/progress.md"

# Worktree-fingerprint guard. Mandatory before any spawn, especially before --write.
# Helper at scripts/internal/common.sh:308 (mo_verify_worktree). Exits 0 when active=null,
# so safe to call unconditionally at cycle scope.
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh check-worktree

active_feature="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get-active)"
current_stage="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$progress" .active.current-stage 2>/dev/null || echo null)"
sub_flow="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$progress" .active.sub-flow 2>/dev/null || echo none)"
```

If `quest.sh current` exits non-zero (no active cycle), print and exit:

```
No active mo-workflow. /mo-sidequest is for mid-workflow questions.
Ask the question directly in chat, or run /mo-run to start a cycle first.
```

If `active_feature == "null"` and `current_stage == "null"`, set `scope=cycle`; otherwise `scope=feature`. Cycle scope is rare but legitimate — `active=null` is the pre-stage-2 and post-stage-8 state and the overseer may want to ask something about the queue between features.

### Step 3 — Classify (skipped on explicit tier override)

If the overseer passed `--quick` / `--standard` / `--deep`, use that tier verbatim and print:

```
sidequest: tier=<tier> (overridden)
```

Otherwise apply the rubric below to score the question on three cheap signals, then map to a tier:

**Rubric signals**

1. **Scope** — does the question name one symbol / file (narrow) or a whole module / "the codebase" / "the workflow" (broad)?
2. **Action verb** — `explain` / `show` / `list` / `where` → narrow; `refactor` / `audit` / `design` / `propose` / `why is X slow` → broad.
3. **Concreteness** — named file + line, or a specific IR-ID (narrow) vs. open-ended "what's going on with X" (broad).

**Tier assignment**

- All three signals narrow → `quick`.
- Mixed, or one broad signal → `standard`.
- Two or more broad signals, **or** any `design` / `audit` / `refactor` verb regardless of other signals → `deep`.

**Bias up under uncertainty.** When two adjacent tiers are plausible, pick the higher one. Under-budget costs a re-spawn round trip (escalation in Step 6); over-budget costs only tokens.

Print one line so the overseer sees the classification and can `Ctrl-C` if it is obviously wrong:

```
sidequest: tier=<tier> (rubric: scope=<narrow|broad>, verb=<narrow|broad>, concreteness=<narrow|broad>)
```

### Step 4 — Pick the sub-agent

- `--write` absent → `subagent_type: millwright-overseer-development-machine:sidequest-reader`.
- `--write` present → `subagent_type: millwright-overseer-development-machine:sidequest-writer`.

Both agents pin `model: sonnet` in their frontmatter — do **not** pass a per-call `model:` override to `Agent` (the plugin's other call sites do not, and the override precedence vs frontmatter is not documented anywhere we control).

### Step 5 — Spawn the sub-agent

Invoke `Agent` with the selected `subagent_type` and the spawn prompt below. Substitute the values resolved above into the placeholders:

- `<tier>` — `quick` | `standard` | `deep`
- `<write_mode>` — `read-only` | `write-allowed`
- `<scope>` — `cycle` | `feature`
- `<quest_slug>`, `<active_feature>`, `<current_stage>`, `<sub_flow>`, `<data_root>`
- `<question>` — verbatim from Step 1
- `<escalation_reason>` — empty on first spawn; populated on re-spawn (Step 6 branch 2)

```
You are a fresh sub-agent invoked from /mo-sidequest. Your context is isolated from the main session — main does not see your tool calls, only your final return summary.

Tier: <tier>          (budget table is in your behavioral defaults)
Write mode: <write_mode>
Scope: <scope>

Workflow state (read at spawn from progress.md, may have advanced since):
- Active cycle: <quest_slug>
- Active feature: <active_feature>
- Current stage: <current_stage>
- Sub-flow: <sub_flow>
- Data root (absolute): <data_root>

Workflow artifacts live under <data_root>. Use the documented directory shape (workflow-stream/<feature>/blueprints/current/, .../implementation/, .../test/, quest/<slug>/) to find what the question needs. Read narrowly; do not bulk-read directories.

Overseer question:
<<<
<question>
>>>

<if escalation_reason is non-empty>
This is a re-spawn after a tier=<previous-tier> sub-agent returned NEEDS_ESCALATION with reason:
<<<
<escalation_reason>
>>>
Treat that reason as a hint about where the previous tier ran out of budget; do not start over from scratch if the hint suggests a focused direction.
</if>

Return shape: follow docs/sub-agent-return-contract.md with the two side-quest additions described in templates/sub-agent-return.md.tmpl (`Answer:` block and `Continuity summary:` line). Include every standard field — `Artifacts changed:` and `Commits:` are present with empty bullet lists where applicable.

Two first-line sentinels can replace the entire return shape; emit one of them only as the first non-blank line, with nothing else:
- `NEEDS_ESCALATION: <reason>` — your tier's budget was too tight. The orchestrator will re-spawn at the next tier.
- `WRITE_REQUIRED: <reason>` — reader-only. The question cannot be answered without source edits. The orchestrator will surface this to the overseer.

Total return ≤ 1.5k tokens. Return only this structure. Do not narrate intermediate steps.
```

### Step 6 — Render the return

On return, parse the sub-agent's output. Sentinel handling runs **in order**; the first match wins.

#### Branch 1 — `WRITE_REQUIRED: <reason>` as the first non-blank line

The read-only sub-agent has determined the ask cannot be answered without source edits. Do **not** re-spawn — write-mode is an explicit overseer decision, never automatic. Print:

```
sidequest: reader returned WRITE_REQUIRED → re-run with --write
  reason: <reason>
```

…and exit. (This branch is reader-only by construction; the writer cannot emit `WRITE_REQUIRED`.)

#### Branch 2 — `NEEDS_ESCALATION: <reason>` as the first non-blank line, tier ≠ `deep`

Re-invoke with `tier := <tier>+1` (i.e. `quick → standard`, `standard → deep`) and `escalation_reason := <reason>`. The agent selection from Step 4 does **not** change — reader stays reader, writer stays writer; tier and reader/writer are orthogonal axes. Print:

```
sidequest: tier=<previous> returned NEEDS_ESCALATION → re-spawning at <next>
  reason: <reason>
```

Escalation is **one-shot**. The orchestrator does not loop on escalation — a `deep`-tier `NEEDS_ESCALATION` falls through to Branch 3, not back to Branch 2.

#### Branch 3 — `NEEDS_ESCALATION: <reason>` at tier `deep`

Cannot escalate further. Treat as `Result: partial` and surface the reason as a `Findings / risks` bullet for the overseer. Print the Answer block (if any) followed by the trailer; ask the overseer to narrow or split the question across multiple `/mo-sidequest` calls.

#### Branch 4 — Normal return

Extract the `Answer:` block from the sub-agent's return and print it verbatim to the overseer (markdown is preserved). The other fields (`Result`, `Continuity summary`, `Artifacts changed`, `Commits`, `Findings / risks`, `Main should read`) are naturally retained as the tool result in main's context — that is the compact record of what just happened.

If the sub-agent populated `Artifacts changed`, do **not** read those files in main — the next `/mo-continue` drift check picks edits up via the existing mechanism.

#### Branch 5 — Malformed return

If the return does not start with one of the sentinels above and also lacks a parseable `Answer:` block, treat as `Result: blocked`. Print the raw output under a `Findings / risks:` bullet so the overseer can re-run. Do not attempt to repair the output.

### Step 7 — Trailer

After Branches 3 / 4 / 5, print one line:

```
sidequest: complete · tier=<tier> · result=<success|partial|blocked>
```

After Branch 1 / Branch 2 the corresponding branch already printed its own status line; no extra trailer.

## Behavior outside an active workflow

If `quest.sh current` exits non-zero in Step 2, the command refuses with the message in Step 2 and exits. `/mo-sidequest` is mid-workflow only — for questions outside a workflow, ask in chat directly.

## What this command does NOT do

- **No auto-routing of arbitrary messages.** Only the explicit `/mo-sidequest` slash command triggers a side-quest spawn. Steering messages typed in chat without the slash command go to main as usual.
- **No persisted answer log.** Answers are ephemeral. If the overseer wants the answer recorded, the regular `/mo-*` commands are the right path (e.g. add an IR finding via `/mo-review`, update a goal via `/mo-update-blueprint`).
- **No workflow-state mutations.** Neither side-quest sub-agent can advance stages, activate features, edit `progress.md`, or commit. Those are the standard workflow commands' jobs.
- **No write access to workflow artifacts even under `--write`.** The writer's behavioral defaults forbid edits under the resolved absolute `data_root`. This protects `progress.md`, blueprints, plans, reviews, and test artifacts from accidental mutation regardless of where the overseer pointed `data_root`.

## See also

- `docs/side-quest/plan.md` — full design plan including rationale, edge cases, and review fold-ins.
- `agents/sidequest-reader.md` — read-only side-quest sub-agent.
- `agents/sidequest-writer.md` — writable side-quest sub-agent.
- `templates/sub-agent-return.md.tmpl` § "Side-quest additions" — canonical return-shape extension.
- `docs/clear-points/plan.md` — the complementary feature that flushes context at fixed gates; side-quest covers the residual mid-stage exploration cost.
