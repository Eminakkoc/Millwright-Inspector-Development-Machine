---
description: Turn auto mode on or off for the active quest cycle, or show its state. While on, the millwright answers most stage 1.5–8 prompts itself and logs each answer; human gates still stop.
argument-hint: "[on | off]"
---

# mi-auto

**Runtime bootstrap.** Every `$CLAUDE_PLUGIN_ROOT` reference below assumes a resolved plugin root; apply the canonical resolver (`docs/millwright-inspector-project.md` §8.14; reference implementation: `mi-continue.md` Step 1a) before the first Bash block if it is empty.

Toggles the cycle-wide `auto-mode` flag stored at the top level of the active cycle's `progress.md`. Works between features (no active feature needed); refuses when there is no active quest cycle.

## Execution

1. Parse `$ARGUMENTS`: `on`, `off`, or empty (show state). Anything else → print `usage: /mi-auto [on|off]` and stop.
2. Run:

   ```bash
   mode="$ARGUMENTS"
   "$CLAUDE_PLUGIN_ROOT/scripts/auto.sh" switch "${mode:-status}"
   ```

   Relay its stdout verbatim. On a non-zero exit, relay the error and stop.
3. On `on` only: if a prompt from another command is currently waiting for the inspector's reply in this conversation, add: "The prompt already on screen still needs your answer — auto mode takes over from the next one."

## What auto mode answers — and what it never does

- Answers: queue order, diagram prompts, planning mode (`brainstorming`), drift check (`auto`), execution mode (`subagent-driven`), chain completion (when `chain-finished` is set), manual-test prompts, review mode (`direct`), and the stage-6 approve when every resolved finding was a clean `fix`/`re-implement`.
- Always stops for you: todo selection, blueprint approval, the blueprint-review scope gate, the brainstorming design Q&A (end it with `/mi-implement`), two-or-more branch candidates, the stage-5 review stop, DTI Gate 1, open design points, and the three clear gates (type `/clear`, then `/mi-continue`).
- Every automatic answer prints one `auto: <prompt> → <answer>` line and adds an `auto-answer` row to the cycle's context ledger. Anything you type always wins.

`/mi-auto on` affects the active feature immediately (`diagram-prompt=auto`); `/mi-auto off` restores `diagram-prompt=prompt`.
