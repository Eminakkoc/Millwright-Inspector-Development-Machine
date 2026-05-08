---
description: Export a self-contained agent-handoff brief for the active feature. Extracts (does not synthesize) requirements, scope, custom project instructions, project-wide constraints, feature background, decisions, codebase-context audit, implementation summary, changed-files index, manual-test results, and open review findings into a single markdown file under tmp/bundles/, with workflow scaffolding stripped and task-neutral section headers. Run when the overseer asks to "export the context", "export the bundle", "build a context bundle", or "create a prompt for another session". The slash form is the supported invocation; natural-language matching is best-effort and harness-dependent.
---

# mo-export-bundle

Produces a single self-contained markdown file under `tmp/bundles/` that the overseer can paste into a fresh agent session that may not have access to this plugin's data tree or this codebase. The bundle extracts (it never synthesizes) every workflow artifact relevant to the active feature, strips frontmatter / HTML scaffolding / template placeholders, mechanically scrubs workflow file paths and `.md` filenames out of body text, and structures the result under task-neutral section headers.

Workflow role / tool / domain words (`mo-workflow`, `millwright`, `overseer`, `seam`, `cycle flavor`, finding ids) may still appear in body text where they were authored by humans or sub-agents. The bundle's top prompt block tells the receiving agent to treat such phrasing as opaque labels.

Design reference: `docs/bundle/plan.md`. Section structure: §5.1–§5.18 of that plan.

## Invocation

```
/mo-export-bundle
```

No arguments in v1. Future flags (`--with-diffs`, `--compose`, `--as-of-stage`, etc.) are listed as v2 follow-ups in `docs/bundle/plan.md` §11.

## Refusals

The script refuses (exits non-zero) in three pre-flight cases. See `docs/bundle/plan.md` §6 for the full check ordering.

- **No active cycle.** `quest.sh current` exits non-zero. Message: `Refused: no active cycle. Run /mo-init and /mo-run first.`
- **No active feature.** `progress.sh get-active` returns `null`. Message: `Refused: no active feature. Advance to stage 2 first (run /mo-continue or /mo-apply-impact).`
- **Worktree fingerprint mismatch.** `progress.sh check-worktree` exits non-zero (the current working tree differs from the `worktree-path` recorded in `progress.md.active`). Message: `Refused: invoked from a different worktree than the one that owns the active feature. Switch to the recorded worktree-path and re-run.`

The worktree refusal must precede any `mkdir -p tmp/bundles` so a wrong-worktree invocation never leaves a bundle behind in the wrong repo.

## Execution

Delegate to `scripts/bundle.sh export`; the command markdown does not re-implement extraction logic.

```bash
"$CLAUDE_PLUGIN_ROOT/scripts/bundle.sh" export
```

Relay the script's stderr and exit code to the overseer verbatim.

## Report

On success, the script prints a single line of the form:

```
Wrote tmp/bundles/<feature>-stage<N>-<timestamp>.md (<size> KB, ~<token-estimate> tokens)
Tip: open it in your editor, or `cat` it to copy into another session.
```

The file lives under `tmp/bundles/` (gitignored locally via `tmp/bundles/.gitignore` written by the script the first time the directory is created — see `docs/bundle/plan.md` §4.1). Bundles can be regenerated at any time from canonical files; deleting them is safe (`rm -rf tmp/bundles/`).

## Notes

- The bundle is **derived and disposable**. The canonical files under `workflow-stream/<feature>/` and `quest/<active-slug>/` remain the source of truth.
- The bundle **excludes** diagrams, inline diffs, and any prose synthesis — see `docs/bundle/plan.md` §3 for the full non-goals list and §11 for v2 candidates.
- Natural-language triggering ("export the context", "build a context bundle", etc.) is **best-effort** — see `docs/bundle/plan.md` §7.2. The slash form `/mo-export-bundle` is the supported invocation. If the millwright cannot match a natural-language request, ask the overseer to type the slash form directly.
