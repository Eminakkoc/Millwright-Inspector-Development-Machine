# Agents & Contexts — diagram set

PlantUML diagrams showing, for each workflow stage, **what data lives in the
main agent's context** versus **what is injected into each fresh sub-agent's
context**.

Each sub-agent is spawned empty, is pointed at a specific subset of artifacts,
does its heavy reads in disposable context, and returns a ~1k-token summary
(the [sub-agent return contract](../sub-agent-return-contract.md)). The
diagrams make explicit which artifacts cross into which context.

| File | Stage | Sub-agent(s) |
|------|-------|--------------|
| `overview.puml` | all stages at a glance | — |
| `stage-1-quest-generation.puml` | 1 — `/mi-run` | `journal-file-digester`, `journal-folder-digester` (oversized input only) |
| `stage-1.5-preflight.puml` | 1.5 — `/mi-continue` pre-flight | `dependency-mapper` |
| `stage-2-blueprints.puml` | 2 — `/mi-apply-impact` | `codebase-grounder`, `blueprint-diagrammer` |
| `stage-3-implementation.puml` | 3 — `/mi-plan-implementation` | isolated implementation chain (brainstorming mode) |
| `stage-4-implementation-diagrams.puml` | 4 — post-implementation resume | `implementation-analyst` |
| `stage-6-review.puml` | 6 — `/mi-review` | `review-iteration-runner` (one per iteration) |

Stages 5, 7 and 8 spawn no sub-agents (inspector-authored review / metadata-only
archival) and are summarised in `overview.puml`.

## Colour key

- **Yellow** — main-agent context (persists across the stage)
- **Blue** — fresh sub-agent / isolated-chain context (dies on return)
- **Purple** — persisted artifact store on disk
- **Green** — artifact written during the stage
- **Pink** — sub-agent return summary read back by main

## Rendering

```sh
plantuml docs/agents-and-contexts/*.puml        # -> .png
plantuml -tsvg docs/agents-and-contexts/*.puml  # -> .svg
```
