---
description: Turn auto mode on or off for the active quest cycle, or show its state. Turning it on asks which planning mode stage 3 uses. While on, the millwright answers most stage 1.5–8 prompts itself and logs each answer; human gates still stop.
argument-hint: "[on [brainstorming | direct] | off]"
---

# mi-auto

**Runtime bootstrap.** Every `$CLAUDE_PLUGIN_ROOT` reference below assumes a resolved plugin root; apply the canonical resolver (`docs/millwright-inspector-project.md` §8.14; reference implementation: `mi-continue.md` Step 1a) before the first Bash block if it is empty.

**Running blocks.** Run each fenced `bash` block with the Bash tool (never the PowerShell tool), as written, in one call. Don't wrap a block in `bash -c`, `sh -c`, `zsh -c` or `eval`: Claude Code can't check a wrapped script, so it may stop for permission, and an unattended session denies it. The blocks run the same in bash and zsh; if one fails on shell syntax, stop and report it as a plugin bug instead of working around it.

Toggles the cycle-wide `auto-mode` flag stored at the top level of the active cycle's `progress.md`, together with the planning mode auto mode picks at stage 3 (`auto-planning-mode`). Works between features (no active feature needed); refuses when there is no active quest cycle.

## Execution

1. Parse `$ARGUMENTS`: `on`, `on brainstorming`, `on direct`, `off`, or empty (show state). Anything else → print `usage: /mi-auto [on [brainstorming|direct] | off]` and stop.
2. **`on`** — every time auto mode is turned on, it records a planning mode. If `$ARGUMENTS` did not name one, ask in one line and wait: "Which planning mode should auto mode use — `brainstorming` (design questions first, then spec → plan → sub-agents) or `direct` (I implement straight from the blueprint)? You can still change it per feature at each blueprint stop." Accept only those two words. Then run, with `<planning-mode>` set to the argument or the reply:

   ```bash
   "$CLAUDE_PLUGIN_ROOT/scripts/auto.sh" switch on <planning-mode>
   ```

   **`off` or no argument** — run:

   ```bash
   mode="$ARGUMENTS"
   "$CLAUDE_PLUGIN_ROOT/scripts/auto.sh" switch "${mode:-status}"
   ```

   Relay its stdout verbatim. On a non-zero exit, relay the error and stop.
3. On `on` only: if a prompt from another command is currently waiting for the inspector's reply in this conversation, add: "The prompt already on screen still needs your answer — auto mode takes over from the next one."

## What auto mode answers — and what it never does

- Answers: queue order, diagram prompts, planning mode (the one chosen at `/mi-auto on` or `/mi-run --auto`, unless you picked another for the feature at its blueprint stop), drift check (`auto`), execution mode (`subagent-driven`), chain completion (when `chain-finished` is set), manual-test prompts, review mode (`direct`), and the stage-6 approve when every resolved finding was a clean `fix`/`re-implement`.
- Always stops for you: todo selection, blueprint approval, the blueprint-review scope gate, the brainstorming design Q&A (end it with `/mi-implement`), two-or-more branch candidates, the stage-5 review stop, DTI Gate 1, and open design points.
- Clear gates: the turn ends at each of the three, and the clear-gate hook runs `/clear`, then `/mi-continue`, for you. With the plugin's `auto_clear` setting off, you type them.
- Every automatic answer prints one `auto: <prompt> → <answer>` line and adds an `auto-answer` row to the cycle's context ledger. Anything you type always wins.

`/mi-auto on` affects the active feature immediately (`diagram-prompt=auto`); `/mi-auto off` restores `diagram-prompt=prompt`.

**Planning mode per feature.** In auto mode, the stage-2 blueprint stop names the planning mode stage 3 will use. Reply `brainstorming` or `direct` there to change it for that feature only; the next feature goes back to the auto-mode choice. Running `/mi-auto on <mode>` again changes it for every feature that has no pick of its own.
