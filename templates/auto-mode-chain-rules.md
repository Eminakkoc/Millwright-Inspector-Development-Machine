# Auto-mode end-of-chain rules

Read and follow these rules for the rest of this implementation chain. They apply
until the chain hands back to the mi-workflow. `$CLAUDE_PLUGIN_ROOT` is the plugin
root; `<feature>` is the active feature.

1. **Defer instead of blocking.** When a question would block you, do not stop to
   ask. Record it and the assumption you are taking, then continue on that assumption:

   ```bash
   "$CLAUDE_PLUGIN_ROOT/scripts/deferred-questions.sh" add <feature> "<question>" "<assumption>"
   ```

2. **One branch.** Stay on the current feature branch. Do not create a git worktree
   and do not switch branches — the workflow reviews the `base-commit..HEAD` range of
   this branch only.

3. **Issue check at the end.** When implementation is done, collect:
   - open points in your end-of-session report that need the inspector's decision, and
   - every row of `"$CLAUDE_PLUGIN_ROOT/scripts/deferred-questions.sh" list-open <feature>`.

   Problems already handled during implementation (a task's BLOCKED or
   DONE_WITH_CONCERNS report you resolved) do not count.

4. **Walk through issues one item per reply.** Present one issue, wait for the
   inspector's answer, then the next. For a deferred question record the answer:

   ```bash
   "$CLAUDE_PLUGIN_ROOT/scripts/deferred-questions.sh" answer <feature> <DQ-NNN> "<answer>" [--needs-finding]
   ```

   If an answer needs a code change, either make and commit the fix now, or pass
   `--needs-finding` so it becomes a review finding at stage 5. If the inspector says
   stop, or a point stays unresolved, print exactly
   `auto: open point <X> unresolved — answer, then /mi-continue` (with `<X>` naming
   the point), choose no finishing option, set no marker, and stop.

5. **Finishing.** When `finishing-a-development-branch` offers its options, choose
   option 3 — keep the branch as-is. Do not merge, push, or open a PR.

6. **Hand back.** Run the following, then invoke `/mi-continue`:

   ```bash
   "$CLAUDE_PLUGIN_ROOT/scripts/progress.sh" set chain-finished=true
   ```
