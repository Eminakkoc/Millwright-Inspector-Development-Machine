---
description: End the brainstorming design Q&A and hand the chain straight to implementation — spec, plan without review, sub-agent execution, then the auto-mode end-of-chain rules. Typed by the inspector during stage 3; works with auto mode on or off.
---

# mi-implement

**Runtime bootstrap.** Resolve `$CLAUDE_PLUGIN_ROOT` per `docs/millwright-inspector-project.md` §8.14 (reference implementation: `mi-continue.md` Step 1a) before running any Bash block.

Typed by the inspector while the stage-3 brainstorming chain is asking design questions. **Typing it counts as design approval** for the design discussed so far — do not ask for approval again.

## Instructions to the chain

Do these four things, in order:

1. **Write the spec** for the approved design to `docs/superpowers/specs/` and commit it. Record any remaining design question in the spec's open-questions list rather than asking it.
2. **Write the implementation plan** with the writing-plans skill and commit it, without waiting for an inspector review of the spec or the plan.
3. **Implement with sub-agents** — choose subagent-driven development as the execution method and begin immediately.
4. **Follow the end-of-chain rules.** Read `$CLAUDE_PLUGIN_ROOT/templates/auto-mode-chain-rules.md` now and follow it until the chain hands back with `/mi-continue`.

These instructions apply whether or not auto mode is on: `/mi-implement` always carries the end-of-chain rules, so turning auto mode on mid-chain still works.
