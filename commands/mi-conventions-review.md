---
description: Check the active feature's changed code against its review-tagged skills and path-matched rules — one read-only conventions-reviewer per entry — and add validated findings to inspector-review.md (source conventions-review). Auto-run by /mi-continue Resume Step 6.5; run it by hand at stage 5 or 6.
---

# mi-conventions-review

**Delegation contract.** This command REQUIRES the sub-agents listed below; §8.13's main-read budget forbids main from doing their work itself. **Invoking `/mi-conventions-review` (directly, or through `/mi-continue` Resume Step 6.5) IS the user requesting them** — Claude Code's default "do not call the Agent tool unless the user requested it" (and any stricter house rule layered on it) does not reach a sub-agent this command names at the step that names it, so spawn them without asking for extra confirmation. The default still holds everywhere else: never spawn a sub-agent this command does not name, and never invent fan-out beyond the waves below. If a named delegation genuinely cannot run (type unavailable, harness refusal), say so and stop — never silently do its work in main. Sub-agents: `conventions-reviewer` (Step 2 — one per skill or rule entry, at most 3 per wave). Canonical rule: `docs/millwright-inspector-project.md` §8.15.

**Runtime bootstrap.** Resolve `$CLAUDE_PLUGIN_ROOT` per `docs/millwright-inspector-project.md` §8.14 (reference implementation: `mi-continue.md` Step 1a) before running any Bash block.

No arguments. Runs at stage 3 inside `/mi-continue`'s Resume Handler (`sub-flow=resuming`), or at stage 5 or 6. Main never reads the diff, `config.md`, or a rule body — `scripts/conventions-review.sh` selects entries and validates findings.

## Step 1 — Prepare

```bash
active_feature="$("$CLAUDE_PLUGIN_ROOT/scripts/progress.sh" get-active 2>/dev/null || true)"
if [[ -z "$active_feature" || "$active_feature" == "null" ]]; then
  echo "conventions review: failed — no active feature" >&2
  exit 1
fi
"$CLAUDE_PLUGIN_ROOT/scripts/conventions-review.sh" prepare "$active_feature"
echo "model: ${MI_CONVENTIONS_REVIEW_MODEL:-sonnet}"
```

- Exit non-zero → print `conventions review: failed — <its stderr line>` and stop.
- `conventions review: nothing to check` or the feature-test line → relay it and stop. Both are success.
- Otherwise relay the `conventions review: N reviewers (…)` line and keep the printed `state:` directory and `model:` value for Step 2.

## Step 2 — Spawn reviewers

Read `<state>/entries.tsv` (`idx`, `name`, `kind`, `abs-path`, `boundary`). For each row spawn `subagent_type: millwright-inspector-development-machine:conventions-reviewer` with the Agent `model` parameter set to the printed `model:` value. Send **at most 3 spawns per message** (one wave); start the next wave when the previous one has returned. Spawn prompt:

```
Review the "<active_feature>" feature's changed code against one <kind>.

Entry:           <name> (<kind>)
Entry file:      <abs-path>
Source boundary: <boundary>
Snapshot folder: <snapshot — the state path without the trailing ".state">
Ranges file:     <state>/entry-<idx>.ranges
Decisions:       <data root>/workflow-stream/<active_feature>/decisions.md   (omit this line when the file does not exist)

Follow agents/conventions-reviewer.md: report only inside the ranges, quote the
exact sentence broken, at most 10 findings. Your whole final reply is the return
contract — Entry / Result / More, then ### F-n blocks.
```

As each reviewer returns, save its final reply **verbatim** with the Write tool to `<state>/reply-<idx>.md`. Do not summarize, reformat or judge it — `ingest` validates.

If a spawn errors, or the agent type is unavailable, print `conventions review: failed — <error>` and stop. Nothing has been written; the next run starts over.

## Step 3 — Ingest

```bash
active_feature="$("$CLAUDE_PLUGIN_ROOT/scripts/progress.sh" get-active 2>/dev/null || true)"
if [[ -z "$active_feature" || "$active_feature" == "null" ]]; then
  echo "conventions review: failed — no active feature" >&2
  exit 1
fi
"$CLAUDE_PLUGIN_ROOT/scripts/conventions-review.sh" ingest "$active_feature"
```

- Exit non-zero → print `conventions review: failed — <its stderr line>` and stop. No finding was written; the run folder is kept for inspection and the next run clears it.
- Exit 0 → relay the last stdout line (the report line) as this command's final line.
