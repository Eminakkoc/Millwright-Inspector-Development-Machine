# Sub-Agent Return Contract

A short reference for human readers (overseers, plugin maintainers) on the standardized return shape for fresh sub-agents invoked from mo-workflow commands.

## Why this contract exists

The mo-workflow's context-optimization design pushes large reads (codebase walks, diff analyses, per-iteration review work) into **fresh sub-agents** — `Agent` invocations with `subagent_type` set, which start with zero context and return a single summary message to the main agent. The whole point of this pattern is that the sub-agent's intermediate reads (often tens to hundreds of thousands of tokens) live in a disposable context and never accumulate in the main agent's session.

That benefit only holds if the return summary stays small and structured. Without a contract, sub-agent returns drift toward long prose narratives — and prose narratives slowly reintroduce the bloat the delegation was supposed to avoid. The contract caps each return at roughly 1k tokens of structured data.

## The shape

Every fresh sub-agent invoked from a mo-workflow command returns exactly this structure:

```
Result: success | partial | blocked
Artifacts changed:
- <path>: <one-line note on what changed>
Commits:
- <sha>: <commit subject>
Findings / risks:
- <short bullet, optional>
Main should read:
- <path>: <reason why main needs this>
```

The canonical version with full field semantics, rules, and an example lives in `templates/sub-agent-return.md.tmpl`. That file is the source of truth; this document is the human-friendly summary.

## What "main should read" actually means

`Main should read` is the routing primitive that connects the sub-agent's work to the next step in main. The sub-agent did the heavy reads in its own context; if the main agent now needs to act on a specific artifact (an updated `requirements.md`, a fresh `grounding-report.md`, a list of resolved IR-IDs), the sub-agent names that artifact here. Main consumes those paths and proceeds; everything else stays out of main's context.

Empty `Main should read` is fine when the sub-agent's work was self-contained (e.g., it committed code and updated `review.sh set-status` for each finding — no further main reads needed).

## What `Findings / risks` is NOT for

It is not a place for the sub-agent to narrate what it did. Narration belongs in the sub-agent's own context, which is discarded. Findings/risks is reserved for items that **require main-side action or awareness**:

- Ambiguity the sub-agent couldn't resolve and needs the overseer to clarify
- Edge cases discovered during the work that warrant overseer review
- Risks the main agent should know about before continuing (e.g., "the implementation diverged from the plan in ways that may affect later stages")

Bullets that don't fit those categories are noise and should be dropped.

## Where the contract is bound

Each mo-workflow command that delegates work via a fresh sub-agent embeds the contract in its prompt template. The list:

| Command | Stage | Sub-agent purpose |
| --- | --- | --- |
| `commands/mo-run.md` | 1 | Per-file or per-folder summarization for oversized journal intake |
| `commands/mo-continue.md` (Pre-flight Step 2A) | 1.5 | Queue-rationale dependency scan (Option 1B fallback) |
| `commands/mo-apply-impact.md` | 2 | Codebase-grounding pass for blueprint generation |
| `commands/mo-review.md` Step 3a | 6 | Per-iteration review work in brainstorming mode |
| `commands/mo-generate-implementation-diagrams.md` | 4 | Implementation diagram generation |
| `commands/mo-apply-impact.md` | 2 | Blueprint diagram generation (same per-event prompt as stage 4) |
| `commands/mo-draw-diagrams.md` | manual | Overseer-invokable wrapper for stage-4 diagram generation |
| `commands/mo-sidequest.md` | any | Mid-workflow Q&A or small-fix sub-agent (read-only `sidequest-reader`, or writable `sidequest-writer` under `--write`). Uses the side-quest variant of the contract — see below. |

When adding a new delegated stage, copy the "Required return shape" block from `templates/sub-agent-return.md.tmpl` verbatim into the new prompt. Do not paraphrase — the literal shape is what trains consistent sub-agent behavior across the workflow.

## Side-quest variant

The `/mo-sidequest` slash command spawns one of two side-quest sub-agents (`agents/sidequest-reader.md`, `agents/sidequest-writer.md`) and uses a slight extension of the contract: two extra blocks (`Answer:` and `Continuity summary:`) at the top of the return, plus two distinct first-line sentinels (`NEEDS_ESCALATION:` for tier escalation, `WRITE_REQUIRED:` reader-only). The standard fields below the extras are unchanged — `Artifacts changed:` and `Commits:` still appear with empty bullet lists where applicable. The canonical definition lives in the "Side-quest additions" section of `templates/sub-agent-return.md.tmpl`; the side-quest design plan is `docs/side-quest/plan.md`.

## Quick checklist for prompt authors

When writing a sub-agent prompt for any of the call sites above:

1. ✅ The prompt ends with the "Required return shape" block from the template, copied verbatim.
2. ✅ The prompt ends with the literal instruction: *"Return only this structure. Do not narrate intermediate steps."*
3. ✅ The prompt scopes the sub-agent's work narrowly enough that the return fits under ~1k tokens.
4. ✅ The prompt names every artifact the sub-agent should write, so the sub-agent can list them under "Artifacts changed" without ambiguity.
5. ✅ The prompt explains what main will do next, so the sub-agent knows what to put under "Main should read".

If any item fails, tighten the prompt before invoking. A loose prompt is the fastest way to recreate the bloat.

## Related

- `templates/sub-agent-return.md.tmpl` — canonical template (source of truth)
- `docs/context optimization/recommendations.md` — full optimization specification
- `docs/context optimization/implementation-plan.md` — Phase 0.1 introduces this contract; subsequent phases bind it at each call site
