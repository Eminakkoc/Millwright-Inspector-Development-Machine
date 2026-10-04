# Skills across the workflow — design (1.11.0)

**Feature:** `skills-across-workflow` · **Branch:** `feat/skills-across-workflow` · **Items:** SKL-001 … SKL-013
**Source of truth for detailed acceptance criteria:** `millwright-inspector/workflow-stream/skills-across-workflow/blueprints/current/requirements.md` (stage-2 blueprint). This spec records the design choices made on top of it; where the two differ, this spec wins only on the points listed under "Design decisions".

## Goal

Skills are selected once at stage 2, stored in `config.md`'s auto block, installed (catalog skills) at the stage-2 approve gate, and handed to every step and sub-agent that writes or judges code. Every reader treats pre-1.11.0 shapes (no `## Requested skills`, no `## Catalog suggestions`, entries without `stages:`/`skill:`) as empty, never as an error.

## Design decisions

1. **Six `skills.sh` subcommands, not five.** `apply-installs` is added so the Approve Step 1.5 `config.md` rewrite is deterministic and covered by a round-trip fixture (SKL-012). The prose decides retry/continue/stop; the script only applies the outcome.
2. **Parsing in embedded python.** JSON and markdown parsing runs in `python3 - <<'PYEOF'` blocks, like `auto.sh` and `blueprints.sh`. No `jq`, no associative arrays, no `mapfile` — bash 3.2 safe. No new dependency.
3. **One auto-block reader.** `brief`, `entries` and `apply-installs` share one python function that reads from the opening comment beginning `<!-- auto:start` (bare or annotated) through `<!-- auto:end -->`.
4. **Step 2 of `/mi-plan-implementation` stays word for word.** Approve Step 1.5 runs it by reference; stage 3 only re-validates.

## Component 1 — `scripts/skills.sh` (SKL-001)

Bash dispatcher; sources `scripts/internal/common.sh` (read-only use of `mi_blueprints_current`, `mi_die`). Every subcommand exits 0 with empty stdout when nothing matches.

| Subcommand | Reads | Output |
|---|---|---|
| `inventory [--installed]` | project `.claude/skills/*/SKILL.md`; enabled-plugin skills; `catalog list --json`; both lock files | TSV `name kind origin description path needs` |
| `lookup <name\|bundle:x>…` | `catalog list --json`, `catalog list --json --bundles` | TSV `name kind scope bundle` |
| `brief <feature> implement\|review` | `## Skills` inside the auto block | markdown block (below) |
| `entries <feature> implement\|review` | same parse as `brief` | TSV `name abs-path` |
| `catalog-files` | `.claude/catalog.lock.json`, `git status --porcelain` | project-relative paths, one per line |
| `apply-installs <feature> [--installed a,b] [--declined c] [--failed d] [--stop]` | auto block of `config.md` | rewrites `config.md` in place |

### `inventory`

- **Project skills:** `.claude/skills/<name>/SKILL.md` → `kind=skill`, `origin=project`, `path` project-relative.
- **Plugin skills:** `enabledPlugins` merged from `~/.claude/settings.json` → `.claude/settings.json` → `.claude/settings.local.json` (later wins). For each enabled plugin, take the install path from `~/.claude/plugins/installed_plugins.json` — the record whose `projectPath` is this project, else the user-scope record — and list `<installPath>/skills/<skill>/SKILL.md` as `<plugin>:<skill>`, `origin=plugin:<plugin>`, absolute `path`.
- **Catalog skills** (skipped with `--installed`): `catalog list --json`, accepting both the flat `{name: {...}}` map and an `.items`-wrapped form; keep `kind: skill` and `scope: project`; drop names already found → `kind=catalog-skill`, `origin=catalog`, `path=-`.
- **Broken:** a lock-file skill entry (`./.claude/catalog.lock.json`) whose `files` are missing on disk → `kind=broken`.
- **Personal `~/.claude/skills/` is never a source.**
- **Description** from `SKILL.md` frontmatter `description` (or the catalog row), cut at 200 characters, tabs/newlines flattened to spaces.
- **`needs`** (catalog rows only): the row's non-skill `requires` that are missing here — a `tool` item whose `bin` (from the catalog row; the name when absent) is not on PATH, or any other kind present in neither lock file — comma-joined; `-` when none. Always `-` for installed rows.
- No `catalog` on PATH → print `catalog CLI not found — catalog suggestions skipped` once on stderr, emit the installed rows, exit 0.

### `lookup`

- Each argument: `bundle:<name>` expands through `catalog list --json --bundles` (`{<bundle>: {description, items}}`) into its items, with the bundle name in the `bundle` column; plain names have `bundle=-`.
- Known names print `name kind scope bundle` from the catalog row. Names the catalog doesn't list print `<name> unknown - -` (`-` replaced by the bundle name for expanded members).
- `--bundles` unsupported (non-zero exit) → each `bundle:<name>` argument prints `bundle:<name> unknown - -`.
- No `catalog` → the same stderr note as `inventory`, every argument prints as `unknown`, exit 0.

### `brief` / `entries`

- Reads `blueprints/current/config.md` for the feature; missing file → nothing, exit 0.
- Considers only `## Skills` entries (not `## Load on demand`, not `## Catalog suggestions`) whose `stages:` list contains the tag and which carry both `skill:` and `path:`. Others are skipped silently.
- Relative paths resolve against the repo root (`git rev-parse --show-toplevel`, else `$PWD`).
- `brief` output:

  ```
  ## Skills for this work (from config.md)

  Load each skill with the `Skill` tool (`Skill <name>`); if that fails, Read the file at its path.

  - <name> — <reason> — <abs path>
  ```

  For `review` the heading is `## Skills for reviewing this work`.
- `entries` prints the same entries as `<name>\t<abs path>`.

### `catalog-files`

Paths under each lock-file skill's `files` that `git status --porcelain` shows as new or changed (untracked directories expanded), plus `.claude/catalog.lock.json` itself when it changed. Project-relative, sorted, unique.

### `apply-installs`

Rewrites only the text between the auto markers:

- `--installed` names: the `## Catalog suggestions` entry is removed and a `## Skills` entry is appended with the same reason line and `stages:`, plus `skill: <name>; path: .claude/skills/<name>/SKILL.md; origin: catalog-installed`.
- `--declined` names: entry deleted.
- `--failed` names: deleted when `requested: no`; when `requested: journal`, deleted unless `--stop`.
- `--stop`: the failed journal entries and every suggestion not named in any list stay in `## Catalog suggestions`.
- Without `--stop`, any suggestion not named in any list is left in place (the caller always names every entry it handled).
- Idempotent: a name already in `## Skills` and absent from suggestions is a no-op. Missing markers → `mi_die`.

### Entry format (data contract)

Every entry is at most two lines:

```
## Skills
- vercel:nextjs — App Router pages in this feature
  stages: implement, review; skill: vercel:nextjs; path: /abs/…/nextjs/SKILL.md
## Load on demand
- web-images — only if the feature adds images
  stages: implement; skill: web-images; path: .claude/skills/web-images/SKILL.md
## Catalog suggestions
- agent-browser — e2e checks of the checkout flow
  stages: review; requested: no; install: catalog add agent-browser
```

Fields on the second line are `key: value` pairs separated by `; `. `stages:` values are comma-separated from `{implement, review}`. Gate-installed entries add `origin: catalog-installed` (informational).

## Component 2 — stage 1 (SKL-002)

- `templates/summary.md.tmpl` and `/mi-run` Step 4's body-section list gain `## Requested skills` after `## Out-of-scope`. Heading kept when empty; not covered by `## In plain terms`. Line forms: `- <name> — features: <list|all>; source: <file>`, `- (unresolved) "<quote>" — features: …; source: …`, `- (excluded) <name> — features: …; source: …`. Rules, plugins, MCP servers and hooks named by the journal are listed too.
- `agents/journal-file-digester.md`, `agents/journal-folder-digester.md` and their Step 2.5 spawn prompts gain a mandatory `## Named resources` section: `- <exact name> — "<quoted sentence>" — <file>[§loc] — feature: <name|unknown>`, or `(none)`. Return cap and shape unchanged.
- Step 4 builds `## Requested skills` from those sections plus files main read directly; an `unknown` feature becomes `features: all` as `(excluded)` or `(unresolved)`, never a plain requested line.
- Verified by running `quest.sh feature-section` and `bundle.sh` against a summary with and without the heading.

## Component 3 — stage 2 (SKL-003, SKL-004)

- `docs/blueprint-regeneration.md` Step B is rewritten: run `skills.sh inventory`; read `## Requested skills` lines naming this feature or `all`; classify with `skills.sh lookup`; drop every `(excluded)` name everywhere; use `grounding-report.md` and Goals as relevance input; place candidates by the blueprint's placement rules; write the auto block with stage tags. Budget: ≤ 10 entries across `## Skills` + `## Load on demand`; journal-requested and inspector-confirmed skills always kept; the millwright's own picks fill only the room left and are dropped first; `## Catalog suggestions` doesn't count.
- `templates/config.md.tmpl`: auto block becomes `## Skills`, `## Load on demand`, `## Catalog suggestions`; `## Rules` removed. `## GIT BRANCH`, `## Inspector Additions`, `## Lessons learned` byte-identical.
- `docs/millwright-inspector-project.md` updated where it describes the old block.
- `/mi-apply-impact` Step 3.2 hand-off: one line per non-empty group (to install, awaiting confirmation, requested-not-found, not a skill, personal-copy override, broken with `catalog add <name> --force`, held back for dependencies — `requested: journal` only). No groups → message unchanged. The `check-current=0` short-circuit omits the lines.

## Component 4 — approve gate (SKL-005)

New `/mi-continue` Approve Step 1.5 "Install catalog skills", after Approve Step 1, before the clear-point gate:

0. Resolve the branch: run `/mi-plan-implementation` Step 2 unchanged (auto mode → `auto.sh create-branch`). Always runs; non-zero stops.
1. Read `## Catalog suggestions`. Missing section or empty → skip to step 5.
2. If any entry has `requested: no`, ask once, auto mode on or off: `Not in your journal but looks useful: <name> (<reason>), … — install all, none, or name the ones you want?`
3. Install `requested: journal` entries plus confirmed ones with their `install:` command plus `--yes`. Auto mode logs journal installs with `auto.sh answer "catalog install" "<items>" --cmd /mi-continue`. A failed journal install asks `<item> (requested in your journal) failed to install: <error>. Retry, continue without it, or stop?`
4. `skills.sh apply-installs` with the outcome (`--stop` when the inspector chose stop).
5. Commit: when `skills.sh catalog-files` prints paths, `git add -- <paths>` and `git commit -m "chore(skills): install <items> from catalog" -- <paths>`. Nothing → skip. A git failure stops the step. On `--stop`, halt after committing.

Re-running is a no-op. The install commit precedes stage 3's `base-commit`.

## Component 5 — stage 3 and resume (SKL-006, SKL-007)

- `/mi-plan-implementation` Step 1: refuse with `Catalog skills are still waiting to be installed — run /mi-continue to finish the stage-2 gate first.` when `## Catalog suggestions` has an entry; skipped when `current-stage == 3`; missing section = empty.
- Step 3.5 and `templates/primer.md.tmpl`: replace `## Likely-relevant skills & rules` (heading included) with `skills.sh brief <feature> implement` then `skills.sh brief <feature> review`, verbatim; drop the ≤ 5 rule. `check-current --require-primer` must still pass.
- Step 4a: append the **Skills** paragraph — load relevant skills before proposing the design, list them in the spec, require `**Skills:** <name> (load: Skill <name> or Read <path>)` and `**Review skills:** …` lines in every plan task an entry covers, paste the primer's review block into the final reviewer and re-review dispatches and the implement block into the fix dispatch.
- Step 4b: "Load the skills in `## Skills for this work (from config.md)` before editing the files they cover."
- Resume Handler: when Resume Step 2.5 found plan candidates, count `### Task <N>` sections without `**Skills:**` (when `entries … implement` is non-empty) and without `**Review skills:**` (when `entries … review` is non-empty), aggregated across candidates; print `skills: N of M plan tasks name no skill, K of M name no review skill` in the stage-5 hand-off, outside the pinned blockquotes and without moving the auto-answer line.

## Component 6 — stage 6 and standalone consumers (SKL-008)

| Consumer | Change |
|---|---|
| `review-iteration-runner` (`commands/mi-review.md` Step 3a.2.4) | `brief <feature> implement` above "Open findings" |
| `mi-review` direct mode | the stage-3 direct-mode load step |
| `sidequest-reader` | `Skill` tool + `brief <feature> review`; `Write mode: read-only` stays authoritative |
| `sidequest-writer` (`commands/mi-sidequest.md` Step 5) | `Skill` tool + `brief <feature> implement` |
| `pr-review-fixer` | `Skill` tool; `brief implement` when a feature is active and the PR head equals `progress.md`'s `branch`, else main picks ≤ 5 from `inventory --installed` relevant to the changed files, same block format |
| `review-comment-analyst` | `Skill` tool; `brief review` under the same condition, else the same PR-based pick |

Empty brief → the block is omitted. Return contracts unchanged. The agent tool table in `docs/millwright-inspector-project.md` is updated.

## Component 7 — refresh (SKL-009)

`/mi-update-blueprint` Step 4c copies the previous `config.md` auto block byte for byte (replacing its own scan); without a marker pair it uses the template's empty block. Step 4f renders the primer's two brief blocks like stage 3.

## Component 8 — doctor, init, bundle (SKL-010, SKL-011)

- `scripts/doctor.sh`: `catalog` as an optional dependency with the skills repo README's setup command as hint. `--preflight` exit unchanged; `/mi-init` doesn't batch it; `commands/mi-doctor.md` and `commands/mi-init.md` mention it.
- `scripts/bundle.sh`: delete `emit_implementation_rules` and its call; `docs/bundle/plan.md` §5.5 and matching references; the section in six `tests/bundle/fixtures/*/expected.md`. Input fixture configs may keep `## Rules`.

## Testing (SKL-012)

- **`tests/skills/run.sh`** in the `tests/auto-mode/run.sh` style (`ok`/`ng`, sandbox git repos, trap cleanup, fake `HOME`). A stub `catalog` on PATH serves canned flat or `.items` JSON, a canned `--bundles` map, or exits 1 for "unsupported". Covers: `inventory` sources (project, personal excluded, plugin via fake settings + `installed_plugins.json`), `broken`, non-skill and user-scope rows excluded, `needs`, no `catalog`; `lookup` (mixed bundle, user-scope skill, unknown, no `catalog`, `--bundles` unsupported); `brief`/`entries` (tag filter, absolute paths, old-format → empty, `entries` ≡ `brief`); `catalog-files`; **`apply-installs` round trip** — install, decline, failed optional, failed journal + `--stop`, retry — each against a golden `config.md`, plus a repeat-run no-op.
- **Deliberate fixture updates:** `tests/auto-mode/fixtures/prompts-off/primer-4a.txt`; `never-auto-expected.txt` if new prose matches the audit; six bundle `expected.md`.
- **Manual checklist:** `tests/skills/e2e-checklist.md` for the mi-sample end-to-end.
- **Gate:** `tests/skills`, `tests/auto-mode`, `tests/bundle`, `tests/lint`, `tests/blueprint-review` pass under `env -u CLAUDE_PLUGIN_ROOT`. Every new prose bash block is run once by hand in a sandbox data root (`MI_DATA_ROOT`), never against the live cycle. New files avoid the retired `mo-`/`mo_` tokens.

## Release (SKL-013)

`.claude-plugin/plugin.json` → `1.11.0`. `CHANGELOG.md` `## 1.11.0 — …` opens with: finish or abort (`/mi-abort-workflow`) any active workflow before upgrading — pre-1.11.0 `config.md` entries have no `stages:`/`skill:`, so `skills.sh brief` renders nothing for them, `/mi-update-blueprint` copies the old block as is, and ongoing workflows are not migrated. Then: new summary section, new config sections and fields, the stage-2 install gate, branch resolution and install commit moving to the gate, `Skill` added to four agents, the export bundle losing "Implementation rules to follow", and the `catalog list --json --bundles` requirement (skills repo `b6b257c` or later). `marketplace.json` unchanged; older CHANGELOG headings unchanged.

## Out of scope

Migration of old configs; changes to codex reviewers, `dependency-mapper`, `codebase-grounder`, `lessons-*`, `blueprint-diagrammer`, `implementation-analyst`; installing anything that isn't a project-scope catalog skill.
