# Rename "overseer" → "inspector" — Plan & Risk Report

**Status:** Pre-implementation. Decision in §3 must be confirmed before any rename work begins.

**Author motivation:** the word *overseer* carries historical connotations the project does not want to evoke. *Inspector* keeps the same semantic shape (a human who reviews a machine's work) without that baggage.

**Posture: clean break.** No compatibility shims, no tolerant readers, no aliases, no migration prompts. Users uninstall the old plugin, install the new one, and start a fresh `millwright-inspector/` data root. Existing in-flight workflows under `millwright-overseer/` are not carried forward — finish them on the old plugin or accept the loss. This posture is what shapes every choice below; if it changes, the plan changes substantially.

---

## 1. Scope at a glance

| Surface | Count | Notes |
| --- | ---: | --- |
| Files containing the string `overseer` (any case) | **112** | — |
| Total occurrences | **~1,648** | — |
| Files/dirs whose **name** contains `overseer` | 12 tracked + 1 untracked top-level dir | — |
| Plugin-manifest fields (`.claude-plugin/*.json`) | 6 | plugin/marketplace name, descriptions, default `data_root` |
| Schema `$id` URIs (`millwright-overseer-development-machine/...`) | 19 | renamed wholesale |
| Executable plugin-namespaced references — `subagent_type: millwright-overseer-development-machine:*`, `mcp__plugin_millwright-overseer-development-machine_plantuml__*` | ~20 sites across `commands/**`, `agents/**`, `docs/**` | not prose; these are dispatch tokens that resolve via the plugin name. Renamed in lockstep with `plugin.json.name` |
| YAML frontmatter field `overseer-review-completed` (runtime `progress.md`) | 1 field, every in-flight feature | renamed; old files become invalid by design |
| User-editable section header `## Overseer Additions` (runtime `config.md`) | 1 header per feature | renamed; old configs become unrecognized by design |
| User-editable YAML block field `overseer-notes` (runtime PR-review `report.md`) | 1 field per fix block | renamed → `inspector-notes`; free-text, not schema-validated |
| `mo-*` CLI commands + `MO_*` env vars + `mo_*` bash fn/var prefix | 19 commands + env vars + prefix | covered by D1 |
| Default data-folder name (`millwright-overseer/`) | 1 default + ~24 path refs | renamed; no fallback |

Casing distribution: lowercase `overseer` (~1197), Title `Overseer` (~333), hyphenated `overseer-review` (~383), title-hyphenated `Overseer-Review` (~3). Casing is preserved on replacement.

---

## 2. What the clean break means in practice

- **No fallback in `scripts/internal/common.sh` `mo_data_root()`.** The default becomes `millwright-inspector/`. If a user still has a `millwright-overseer/` directory, the new plugin does not see it. (`scripts/data-root.sh` is a thin wrapper over the helper; it inherits the new default automatically.)
- **No tolerant reader in `scripts/progress.sh`.** The field is `inspector-review-completed`. An old `progress.md` that uses `overseer-review-completed` fails schema validation and is rejected by `hooks/validate-on-write.sh`. That is the intended behavior.
- **No alias for `## Overseer Additions`.** `blueprints.sh preserve-inspector-sections` looks for `## Inspector Additions` only. Old user configs lose that block on the next regeneration.
- **No `preserve-overseer-sections` deprecation alias.** The sub-command is renamed in `blueprints.sh`; callers move with it.
- **No retained legacy fixtures.** Every test fixture is regenerated under the new names. A residual `overseer` match in `git grep` after the rename is a defect, not a feature.
- **Release notes are explicit:** this is a breaking rename. Existing users uninstall the old plugin, install the new one, and start fresh.

---

## 3. The one open decision

### D1. The `mo-` prefix — rename to `mi-` or retain as a brand token?

This is the only choice the rename plan still leaves open. Everything else is hard-cut.

- **Affects:** 19 command files (`commands/mo-*.md`), `MO_DATA_ROOT` and `MO_PLUGIN_ROOT` env vars, internal `mo_*` bash function/variable prefix in `scripts/internal/common.sh` and every shell script that sources it, the generated `.claude/mi-stage-info-bar.sh` wrapper (currently `mo-stage-info-bar.sh`), and ~300 documentation references.
- **Option A — Rename to `mi-` / `MI_*` / `mi_*` (default in this plan).** Consistent with the new role name. The `mo` prefix originated as an abbreviation of *millwright-overseer*; under a clean break, dragging it forward is incoherent.
- **Option B — Retain `mo` as a brand token.** Justified only if the project explicitly chooses to keep `mo` as an opaque product name disconnected from the now-retired *overseer* word. Not justified by compatibility; under this plan's posture there is nothing to be compatible with.

**Default in this plan: Option A.** §4 and §6 assume the rename; flip them all to "no change" if you pick Option B.

The other former decisions are settled by the clean-break posture:

| Former decision | Outcome under clean break |
| --- | --- |
| D2 (data-folder default) | Default `millwright-inspector/`; no fallback to `millwright-overseer/`. |
| D3 (env var name) | `MI_DATA_ROOT`, `MI_PLUGIN_ROOT` **if D1 = Option A**; `MO_DATA_ROOT`, `MO_PLUGIN_ROOT` retained **if D1 = Option B**. The env-var prefix follows the CLI prefix in lockstep — they are not independently controllable. |
| D4 (`overseer-review-completed` field) | Renamed to `inspector-review-completed`; no tolerant reader. Schema rejects old name. |
| D5 (`## Overseer Additions` header) | Renamed to `## Inspector Additions`; sub-command renamed to `preserve-inspector-sections`; no alias. |
| D6 (repo URL, top-level dir) | Out of scope of this rename. Tracked separately; see §8. |

---

## 4. Rename matrix (assumes D1 = Option A)

| Category | Action |
| --- | --- |
| Plugin display name (`plugin.json.name`, `marketplace.json.name`) | rename → `millwright-inspector-development-machine` |
| Plugin descriptions (both JSONs) | rewrite to use *inspector* in the millwright/inspector framing |
| Default `data_root` in `plugin.json` | change → `millwright-inspector` |
| `scripts/internal/common.sh` `mo_data_root()` | the actual resolver. Line ~44 hard-codes the default `${PWD}/millwright-overseer` — change to `${PWD}/millwright-inspector`. `scripts/data-root.sh` is a one-liner wrapper that calls this helper; no logic change there |
| `hooks/validate-on-write.sh` hardcoded fallback | line ~39 `data_root_segment="millwright-overseer"` (used when `common.sh` cannot be sourced) — change to `"millwright-inspector"`. Also update header comment and the block message in the rejection JSON (lines ~2 and ~88) that name the plugin |
| Plugin-namespaced dispatch tokens — `subagent_type: millwright-overseer-development-machine:<agent>` | rename → `millwright-inspector-development-machine:<agent>` across `commands/mo-run.md`, `commands/mo-review.md`, `commands/mo-apply-impact.md`, `commands/mo-generate-implementation-diagrams.md`, `commands/mo-continue.md`, `docs/blueprint-regeneration.md`, `docs/sub-agent-profiles/plan.md`, `docs/bundle/plan.md` |
| Plugin-namespaced MCP tool names — `mcp__plugin_millwright-overseer-development-machine_plantuml__*` | rename → `mcp__plugin_millwright-inspector-development-machine_plantuml__*` in `agents/implementation-analyst.md`, `agents/blueprint-diagrammer.md`, and `docs/sub-agent-profiles/plan.md`. These are tool allowlists in agent frontmatter — the names must match the Claude Code runtime's plugin-namespaced tool naming exactly |
| Role prose in `README.md`, `docs/**`, `commands/**`, `agents/**`, shell-script comments, schema descriptions | find-replace by casing class (lowercase, Title, hyphenated) |
| Filename `templates/overseer-review.md.tmpl` | rename → `templates/inspector-review.md.tmpl` |
| Runtime filename `implementation/overseer-review.md` | now `implementation/inspector-review.md`; `scripts/review.sh` writes the new name only |
| Schema `$id` URIs (`millwright-overseer-development-machine/...`) | rename → `millwright-inspector-development-machine/...` |
| Schema titles/descriptions mentioning *overseer* | rewrite |
| YAML field `overseer-review-completed` in `schemas/progress.schema.yaml` and `scripts/progress.sh` | rename → `inspector-review-completed`; schema rejects the old key |
| Section header `## Overseer Additions` in `templates/config.md.tmpl` and `docs/blueprint-regeneration.md` callers | rename → `## Inspector Additions` |
| User-editable YAML field `overseer-notes` in PR-review `report.md` | rename → `inspector-notes` in `templates/pr-review-report.md.tmpl`, `commands/mo-analyze-review.md`, `agents/pr-review-fixer.md`, `commands/mo-continue.md`, `docs/user-reviews/plan.md`. Free-text block field; not in `pr-review-report.schema.yaml` (which carries only the `$id`) |
| `blueprints.sh preserve-overseer-sections` sub-command | rename → `preserve-inspector-sections`; every caller updated |
| `mo-*` CLI command files, `MO_DATA_ROOT`, `MO_PLUGIN_ROOT`, internal `mo_*` bash names, generated `.claude/mo-stage-info-bar.sh` filename | rename to `mi-*`, `MI_*`, `mi_*`, `.claude/mi-stage-info-bar.sh`. **`CLAUDE_PLUGIN_ROOT` is provided by the Claude Code runtime and is NOT ours to rename** — only the internal alias (currently `MO_PLUGIN_ROOT`, set from `CLAUDE_PLUGIN_ROOT` in `common.sh`) changes to `MI_PLUGIN_ROOT` |
| Test fixtures under `tests/bundle/fixtures/*/input/millwright-overseer/` | rename folder to `millwright-inspector/`; regenerate every file inside so new names propagate consistently (field, header, filename, schema id) |
| Generated runtime artifact path `.claude/mo-stage-info-bar.sh` (in `/mo-init-status-bar`) | rename + update `statusLine.command` resolver |
| `LICENSE` | unchanged |
| `marketplace.json.homepage` (GitHub URL) | flagged in §8 — handled with the repo rename |
| Top-level working-copy directory `Millwright-Overseer-Development-Machine/` | flagged in §8 |

---

## 5. Risk register

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| Hyphenated identifiers like `overseer-authored`, `overseer-driven` get rewritten incorrectly when case-folded | Medium | broken links and malformed identifiers in docs | use case-sensitive replacements; lint pass (`git grep -i overseer` should return zero after Phase 6 once the documented exclusions are applied — see Phase 6 and the row below for the exclusion list) |
| A consumer of the schema `$id` (e.g. an external validator) references the old URI | Low | external tool breaks | the `$id` is not part of a documented public API; call out in release notes |
| Marketplace re-install treated as a new plugin (loses settings) when `plugin.json.name` changes | High by design | one-time re-onboarding per user | this is the intended posture; release notes are explicit |
| A user runs the new plugin in a project that still has a `millwright-overseer/` directory and expects continuity | Medium | confusion ("where did my data go?") | release notes spell out the manual procedure: `mv millwright-overseer millwright-inspector` if they want to keep their data, but they own that step; no automatic detection |
| Generated `.claude/mi-stage-info-bar.sh` wrapper conflicts with an existing `.claude/mo-stage-info-bar.sh` on disk | Low | stale status line until users re-run `/mi-init-status-bar` | release notes call out re-running the status-bar setup |
| `git grep -i overseer` after the rename still returns matches outside the documented exclusions (leakage) | Medium | residual references | Phase 6's lint pass is non-optional; CI grep guard added to `tests/`. "Zero matches" means zero **after** applying the exclusions enumerated in Phase 6 (`docs/rename-inspector/`, `CHANGELOG.md`, and the deferred `homepage` URL line in `.claude-plugin/marketplace.json` — that URL is tied to the repo rename in §8 and is intentionally not changed in this PR) |

---

## 6. Phased implementation order

**Phase 1 — Plugin manifest, schema `$id`s, dispatch tokens, defaults.**
- `.claude-plugin/plugin.json`: name, description, `userConfig.data_root.default`, `userConfig.data_root.description`.
- `.claude-plugin/marketplace.json`: org name, plugin name, description. (`homepage` URL is deferred — see §8 — and Phase 6 adds a targeted grep-guard exclusion for it.)
- **Version bump.** This is a hard breaking change, so bump the version in the same Phase-1 manifest edit — a major bump to `1.0.0` makes the break unambiguous. Also fix a pre-existing inconsistency: `plugin.json.version` is currently `0.10.0` while the `marketplace.json` plugin entry's `version` is `0.1.0`. Both must be set to the **same** new value. The release whose CHANGELOG entry (Phase 7) describes this rename is this version.
- `scripts/internal/common.sh`: update the hardcoded default in `mo_data_root()` (`${PWD}/millwright-overseer` → `${PWD}/millwright-inspector`). `scripts/data-root.sh` just calls the helper and needs no logic change; its header comment is rewritten in Phase 2 with the rest of the prose.
- `hooks/validate-on-write.sh`: update the hardcoded fallback `data_root_segment="millwright-overseer"` → `"millwright-inspector"`; update the plugin name in the file's header comment and the rejection-message JSON. Edit the path-to-schema dispatch (`case` block) to do **two** things, not one: (a) add `*/implementation/inspector-review.md) schema="review-file" ;;` so writes to the new filename are validated, and (b) add `*/implementation/overseer-review.md) emit a block JSON and exit 2 ;;` so writes to the old filename are hard-rejected with a "this filename was renamed to `inspector-review.md`" message. Both branches must exist after this phase — the old path must not fall through to the silent skip default, and the new path must be schema-validated.
- All `schemas/**.yaml`: rename `$id` from `millwright-overseer-development-machine/...` to `millwright-inspector-development-machine/...`; rewrite titles/descriptions.
- Plugin-namespaced dispatch tokens (executable, not prose): rename every occurrence of `subagent_type: millwright-overseer-development-machine:*` and `mcp__plugin_millwright-overseer-development-machine_plantuml__*` across `commands/**`, `agents/**`, and `docs/**`. These follow the plugin name change one-to-one.

**Phase 2 — Role prose pass.** Case-preserving find-replace of `overseer` → `inspector` across:
- `README.md`
- `docs/**` (excluding `docs/rename-inspector/`)
- `commands/**.md` (prose only — leave `subagent_type:` tokens for Phase 1, leave `/mo-*` for Phase 4)
- `agents/**.md` (prose only — leave `mcp__plugin_...` tool names for Phase 1)
- `templates/**.tmpl` (prose only — these are generated user-facing files and carry many `overseer` occurrences beyond the three handled in Phase 3: e.g. `progress.md.tmpl:11` "Managed by the millwright-overseer scripts", `decisions.md.tmpl:8` "overseer ↔ millwright Q&A", `primer.md.tmpl:69`, `review-context.md.tmpl:74`. Leave the identifier tokens for Phase 3 — the `## Overseer Additions` header, the `overseer-review.md` filename, the `overseer-notes` field — and leave any `/mo-*` / `mo:` token for Phase 4)
- Comments and help text in `scripts/**` and `hooks/**` (including the `Coverage policy` block inside `hooks/validate-on-write.sh` which currently names `overseer-review.md` as an example)

Honor casing: lowercase → lowercase, `Overseer` → `Inspector`, `OVERSEER` → `INSPECTOR`, hyphenated forms preserved. Possessives (`overseer's` → `inspector's`) included.

Phase 2 is strictly prose: it does **not** touch the YAML field name, the section header, the runtime filename, the `preserve-overseer-sections` sub-command, or any `/mo-*` / `MO_*` / `mo_*` token. Those are Phase 3 and Phase 4.

**Phase 3 — Identifiers.**
- YAML field rename across schema + scripts + every doc reference:
  - `schemas/progress.schema.yaml` — required-list entry and property block.
  - `scripts/progress.sh` — every read/write call site (~35).
  - `docs/workflow-spec.md`, `docs/project-report.md`, `docs/progress/**`, `docs/clear-points/**`, `docs/context optimization/**` — every occurrence of `overseer-review-completed`.
- Section header rename in `templates/config.md.tmpl` (`## Overseer Additions` → `## Inspector Additions`) and every doc that quotes it.
- PR-review block field rename: `overseer-notes` → `inspector-notes`. This is a user-editable free-text YAML key inside the PR-review `report.md` fix blocks — not schema-validated (`pr-review-report.schema.yaml` carries only the `$id`). Update every site together: `templates/pr-review-report.md.tmpl` (the `overseer-notes:` line and the `# overseer fills in` comment), `commands/mo-analyze-review.md` (the report template it emits, ~line 178, and the apply-flow prose, ~line 217), `agents/pr-review-fixer.md` (the prompt that reads the field, ~line 25, including the "`overseer-notes` overrides" rule), `commands/mo-continue.md` (the dispatch prose, ~line 1355), and `docs/user-reviews/plan.md`. **Note:** Phase 2's template prose pass deliberately leaves `overseer-notes` alone — it is an identifier, not prose — so the field is renamed only here in Phase 3, alongside the `## Overseer Additions` header and the `overseer-review.md` filename.
- Sub-command rename: `blueprints.sh preserve-overseer-sections` → `preserve-inspector-sections`; update the dispatcher and every caller (`commands/mo-update-blueprint.md`, `docs/blueprint-regeneration.md`, others).
- Filename rename: `templates/overseer-review.md.tmpl` → `templates/inspector-review.md.tmpl`. The path `implementation/overseer-review.md` is hard-coded in executable scripts and command bodies (this is **behavior**, not prose, and the grep guard will catch leaks but the implementation checklist names them so they are not missed):
  - `scripts/review.sh` — every site (~10) including the file-path helper, the `sync-refs` description, sub-command help text, and the marker-block comments.
  - `scripts/bundle.sh` — the explicit `overseer_review_md="…/overseer-review.md"` variable (line ~108), the file list passed to the bundler (~129), the Python regex patterns that match the filename (~247, ~259), and the section header comment (~847). Note: the regex patterns require careful editing because they appear inside Python `r"..."` literals.
  - `hooks/validate-on-write.sh` — the path mapping case branches (covered in Phase 1; called out here for completeness).
  - `commands/mo-abort-workflow.md` — the `rm -f "$impl_dir"/overseer-review.md` line (~73) and its echo above (~49).
  - `commands/mo-complete-workflow.md` — the archive bash loop that names the file in its iteration list (~234) and the prose block describing the archival (~208, ~311).
  - `commands/mo-continue.md` — many bash heredocs that read or write the file path (~605, ~607, ~868, ~996, ~998, ~999, ~1042, ~1058, ~1063, ~1101, ~1157) plus user-facing message text.
  - `commands/mo-init.md`, `commands/mo-manual-test-plan.md`, `commands/mo-manual-test-run.md`, `commands/mo-draw-diagrams.md` — onboarding text, user prompts, and the `mo-manual-test-run.md` frontmatter `description:` that names the file.
  - `docs/diagrams/workflow-sequence.puml`, `docs/diagrams/workflow-stages.puml` — PlantUML source files for the sequence/stage diagrams. These render into committed `.svg` files (`docs/diagrams/*.svg`), so after the source edits, re-render the diagrams (the project uses `plantuml-mcp-server`; the canonical command for any given diagram lives next to its source).
  - Test fixtures and expected outputs: the renamed fixture set under `tests/bundle/fixtures/*/input/millwright-inspector/` (covered in Phase 5) plus any golden-output files in `tests/bundle/` that name the path verbatim. Update both inputs and expected outputs together so the bundle test stays green.

**Phase 4 — D1: `mo-*` → `mi-*`** (only if D1 = Option A).
- Rename every `commands/mo-*.md` to `commands/mi-*.md`. The slash-command name follows the filename.
- Env vars **we own**: `MO_DATA_ROOT` → `MI_DATA_ROOT`, `MO_PLUGIN_ROOT` → `MI_PLUGIN_ROOT`. Update every shell script and doc that exports or reads them.
- Env var **we do not own**: `CLAUDE_PLUGIN_ROOT` is set by the Claude Code runtime and stays unchanged. `scripts/internal/common.sh` continues to seed its internal alias from `CLAUDE_PLUGIN_ROOT`; only the alias name changes (`MO_PLUGIN_ROOT` → `MI_PLUGIN_ROOT`). Verify no script reads `CLAUDE_PLUGIN_ROOT` under any altered name.
- Internal bash prefix: every `mo_*` function and variable in `scripts/internal/common.sh` and every script that calls them (`mo_die`, `mo_info`, `mo_fm_get`, `mo_fm_set`, `mo_quest_*`, `mo_active_quest_slug`, etc.) → `mi_*`.
- Generated wrapper filename: `.claude/mo-stage-info-bar.sh` → `.claude/mi-stage-info-bar.sh`; the `/mi-init-status-bar` command writes the new filename and points `statusLine.command` at it.
- Every doc reference to `/mo-*` commands and `MO_*` env vars updated.
- **Bare command-name tokens.** Command names appear without the leading slash in many places — agent frontmatter `description:` fields (`agents/codebase-grounder.md:3` names `mo-apply-impact`), command-file headings (`commands/mo-review.md:5` is `# mo-review`), and prose/lists in `docs/**` (e.g. `docs/workflow-spec.md:755` lists `mo-run`), plus schemas and templates. Rename every bare `mo-<name>` token to `mi-<name>` in lockstep with the slash forms — the rename target is the same; only the surrounding syntax differs.
- **Workflow self-name `mo-workflow`.** The system refers to itself in prose as the "mo-workflow" (`docs/workflow-spec.md`, `commands/mo-init.md` status-bar wiring text — `mo-workflow · <feature> · Stage <N>`, and ~10 other prose sites). Under Option A this becomes `mi-workflow`. The status-line wrapper at `.claude/mi-stage-info-bar.sh` must emit the new self-name.
- **Workspace self-name `mo-workspace`.** The system also refers to the user's working directory as an "mo-workspace" — present in `README.md` (the status-bar section), `commands/mo-init-status-bar.md`, `docs/project-report.md`, `docs/workflow-spec.md`, and `docs/stage-info-bar/plan.md` (3 sites). Under Option A this becomes `mi-workspace` throughout. Same rename target as `mo-workflow`, same logic.
- **User-facing `mo:` status prefix.** `mo_info()` in `scripts/internal/common.sh:394` emits `mo: <msg>` to stderr; several Python `print()` calls in `scripts/commits.sh`, `scripts/progress.sh`, `scripts/review.sh`, `scripts/todo.sh` do the same with hardcoded `"mo: ..."` literals. Rename every emitter to `mi:` so user-visible output is consistent with the renamed prefix.
- **Sync-marker HTML comment `<!-- mo:sync-marker -->`.** Emitted into `review-context.md` (and read by `scripts/review.sh:343`'s regex `r'(<!--\s*mo:sync-marker[^>]*-->)...'`); seeded by `templates/review-context.md.tmpl:18`. Under Option A, both the template and the regex change to `mi:sync-marker`. This is a piece of user data on disk: per the clean-break posture, old `review-context.md` files with the legacy marker are not migrated; users who carry forward a file must hand-edit the marker (or run a one-line `sed` they own). The `docs/bundle/plan.md` references to `mo:sync-marker` (3 sites at lines ~89, ~1084, ~1275) are also part of this Phase 4 token-level rewrite — not Phase 2, because Phase 2 is strictly `overseer` → `inspector` prose and these are `mo` → `mi` token edits.

Skip Phase 4 entirely if D1 = Option B.

**Phase 5 — Fixtures.**
- Rename every `tests/bundle/fixtures/*/input/millwright-overseer/` to `.../input/millwright-inspector/`.
- Inside each renamed fixture, regenerate every file so the new names propagate consistently: folder paths, `progress.md` field (`inspector-review-completed`), `config.md` header (`## Inspector Additions`), `implementation/inspector-review.md` filename, schema `$id` references in any embedded validator inputs.
- No legacy fixtures retained. The bundle tests assert against new-name expected outputs only.

**Phase 6 — Lint and CI guard.**
- Run `git grep -i overseer`. Expected output: matches only inside (a) `docs/rename-inspector/`, (b) the CHANGELOG entry for this rename, and (c) the deferred `homepage` URL in `.claude-plugin/marketplace.json` (see §8 — that line is tied to the repo rename and is not changed in this PR). Anything else is a leak.
- Add a `tests/` guard (a small shell test) that fails the suite on stray matches. The guard must not itself fail on a clean tree: `git grep` exits non-zero when there are no matches, so under `set -e`/`pipefail` a naive pipeline fails precisely when the rename is complete. Capture the output and branch on emptiness instead of relying on exit codes:
  ```sh
  matches=$(git grep -in overseer -- ':!docs/rename-inspector/' ':!CHANGELOG.md' \
    | grep -vE '^\.claude-plugin/marketplace\.json:[0-9]+:[[:space:]]*"homepage":' || true)
  [ -z "$matches" ] || { printf 'stray overseer references:\n%s\n' "$matches"; exit 1; }
  ```
  The `|| true` absorbs the no-match exit from both `git grep` and the filtering `grep`, so the clean tree yields an empty `matches` and the test passes. The exclusion is intentionally pinned to the `homepage` field only — every other line in `marketplace.json` (including the plugin `name`) is still subject to the guard, so a plugin-name leak in that file still fails the test. When the repo URL is eventually renamed in the follow-up PR (§8), the exclusion is removed in the same change.
- **D1-conditional `mo` guard (only if D1 = Option A).** The `overseer` grep does not cover the `mo` surface, because none of those tokens contain the word `overseer`. Add a second `tests/` guard that fails the suite on any of the following matches, all excluded the same way (`:!docs/rename-inspector/' ':!CHANGELOG.md'`).
  - **Portability note for `git grep`.** Word boundaries: `\b...\b` under `-E` does **not** work portably (macOS BSD `git grep -E` ignores it; the test then silently passes). Use either `-w` (which is the right tool when the entire pattern is a fixed word) or `-P` (Perl regex, available when Git is built with PCRE; the project's CI must guarantee this). The patterns below use `-w` where the whole token is fixed and `-P` where context needs to be expressed. Both behaviors must be verified once against the live tree as part of writing the guard, not assumed.
  - `git grep -nP '(^|[^A-Za-z])mo-[a-z]' …` — stale command-name references, both slash (`/mo-review`) and **bare** (`mo-review`, `mo-apply-impact`, `mo-run` in agent `description:` fields, command-file headings, doc prose, schemas, templates). The pattern intentionally omits the leading `/` so bare tokens are caught; `/` itself satisfies `[^A-Za-z]`, so slash forms still match. (This pattern also matches `mo-workflow`, `mo-workspace`, and `mo-stage-info-bar.sh` — harmless overlap with the dedicated guards below.)
  - `git ls-files 'commands/mo-*.md'` — any remaining `commands/mo-*.md` files (Phase 4 should have renamed them all to `commands/mi-*.md`).
  - `git grep -nwE 'MO_(DATA_ROOT|PLUGIN_ROOT)' …` — stale env-var references. `CLAUDE_PLUGIN_ROOT` is intentionally not in this list.
  - `git grep -nwP 'mo_[a-z_]+' …` — stale internal bash function/variable names (`mo_die`, `mo_info`, `mo_data_root`, `mo_fm_*`, `mo_quest_*`, etc.).
  - `git grep -nw 'mo-workflow' …` — stale workflow self-name in prose and status-line output.
  - `git grep -nw 'mo-workspace' …` — stale workspace self-name (present in `README.md`, `commands/mo-init-status-bar.md`, `docs/project-report.md`, `docs/workflow-spec.md`, `docs/stage-info-bar/plan.md`).
  - `git grep -nF 'mo-stage-info-bar.sh' …` — stale status-bar wrapper filename (`-F` because the dot is literal here).
  - `git grep -nP "(^|[[:space:]\"'\`])mo:[[:space:]]" …` — stale `mo: ` status prefix emitted by `mo_info()` and Python `print()` calls. The leading bracket class covers: line start, whitespace, double quote (e.g. `echo "mo: ..."`), single quote (`print(f'mo: ...')` — used in `scripts/review.sh`, `scripts/todo.sh`, `scripts/progress.sh`, `scripts/commits.sh`), and backtick (Markdown inline code in docs, e.g. `` `mo: ...` ``). The class is what avoids false positives on URL-like `something:mo:` substrings; it has to enumerate every realistic preceding delimiter or the guard misses the very emitters it exists to catch.
  - `git grep -nF 'mo:sync-marker' …` — stale HTML comment marker in `templates/review-context.md.tmpl`, `scripts/review.sh`'s regex, and `docs/bundle/plan.md`.
  Every guard below uses `git grep` (or `git ls-files`), which exits non-zero / returns empty on no matches — the same clean-tree hazard as the `overseer` guard above. Each must capture its output with `|| true` and fail only when the captured output is non-empty, never branching on the raw `git grep` exit code (for `git ls-files`, an empty result is likewise the success case). Each guard fails the test with a precise message ("stale `mo` reference found at `<file>:<line>`; rename to `mi`"). When D1 = Option B, this entire guard block is skipped (or asserted-false) because the `mo` tokens are retained intentionally.

**Phase 7 — Release notes.**
- CHANGELOG entry: this is a breaking rename. The plugin's marketplace name has changed; the default data folder has changed; the YAML field and section header used for in-flight workflows have changed.
- Procedure for existing users: because the **marketplace `name`** also changes (`millwright-overseer` → `millwright-inspector`), users must re-point the marketplace, not just the plugin. The full sequence: uninstall the old plugin (`/plugin uninstall millwright-overseer-development-machine`), remove the old marketplace (`/plugin marketplace remove millwright-overseer`), re-add the marketplace from the repo (`/plugin marketplace add <repo>` — the renamed `marketplace.json` now registers it as `millwright-inspector`), install the new plugin (`/plugin install millwright-inspector-development-machine@millwright-inspector`), and start with a fresh `millwright-inspector/` data root. Users who want to carry forward their existing data can `mv millwright-overseer millwright-inspector` manually, but they are responsible for editing any in-flight `progress.md` and `config.md` so the field and header names match the new schema; the new plugin will not migrate them automatically and will reject malformed files.
- Status-bar users re-run `/mi-init-status-bar` after upgrade.

---

## 7. Validation strategy

- **Bundle tests (`tests/bundle/run.sh`).** Must pass against the fully regenerated fixture set under the new names. There is no legacy-fixture lane.
- **Schema validation.** Deep JSON Schema validation is required for this release; the yq-based structural fallback in `scripts/internal/validate-frontmatter.sh` (last branch, lines ~82–100) only iterates the top-level `required` list and reads each field with `mo_fm_get`, so it cannot see nested fields like `active.inspector-review-completed` or catch a stray `active.overseer-review-completed`. The new field rename lives inside the `active` block, so the fallback would let both omissions and stale fields through silently. For this release, at least one of `ajv-cli` or the Python `jsonschema` module must be installed; promote them from optional to required in `README.md`'s Requirements section and in `/mi-doctor` (today both tiers are present in `validate-frontmatter.sh` but neither is mandatory). Tighten `validate-frontmatter.sh` so the third (yq) fallback fails with a clear "ajv-cli or python3-jsonschema required for this release" message instead of running an incomplete check. The schema `$id` rename is validated by loading each schema file itself; the workflow-file hook does not see `$id`.
- **Frontmatter hook (`hooks/validate-on-write.sh`).** The hook's reach is narrower than the rename surface. It can enforce exactly two of the five old surfaces:
  - **Old field name (`overseer-review-completed`)** — enforced indirectly. The hook runs the schema against `progress.md` frontmatter; the renamed `progress.schema.yaml` lists `inspector-review-completed` as required, so any `progress.md` missing that field fails. Strengthen the schema with `additionalProperties: false` on the relevant block so a write that re-introduces `overseer-review-completed` also fails on the unknown-key path.
  - **Old runtime filename (`*/implementation/overseer-review.md`)** — enforced **only** if we add an explicit case to the hook's path-to-schema dispatch that hard-rejects writes to the old path (rather than falling through to the silent skip default). Phase 1 splits this into two case branches: (a) the new path `*/implementation/inspector-review.md` is accepted and validated against the `review-file` schema, and (b) the old path `*/implementation/overseer-review.md` is mapped to a dedicated reject branch that emits a `decision: block` JSON with a clear "this filename was renamed to `inspector-review.md`" message. Both branches must exist; neither falls through.
  - **Old section header (`## Overseer Additions`)** — **not** enforceable by the hook. The hook validates frontmatter only, not body content. Enforcement comes from `blueprints.sh preserve-inspector-sections` (which looks for `## Inspector Additions` exclusively and emits nothing for the old header) plus Phase 6's grep guard.
  - **Old schema `$id`** — **not** enforceable by the hook. `$id` is a property of the schema files themselves, not of workflow-file frontmatter. Covered by the schema-self-validation step above and by the grep guard.
  - **Old PR-review field (`overseer-notes`)** — **not** enforceable by the hook. It is body content in the PR-review `report.md` fix blocks, not frontmatter, and it is free text (not in `pr-review-report.schema.yaml`), so neither the hook nor schema validation sees it. Enforcement comes solely from Phase 6's grep guard.
  Add focused unit tests for the two cases the hook owns: (a) a `progress.md` with the old field fails; (b) any write to `*/implementation/overseer-review.md` fails.
- **Lint guard.** A test in `tests/` runs `git grep -i overseer` with the documented exclusions and fails the suite on any match. This is what prevents the rename from regressing.
- **Manual smoke.** Run a fresh `/mi-init` → `/mi-run` → blueprint review → review loop in a sandbox project. Confirm:
  - Default data folder is `millwright-inspector/`.
  - `config.md` contains `## Inspector Additions`.
  - Review file is `implementation/inspector-review.md`.
  - `progress.md` carries `inspector-review-completed`.
  - All CLI commands resolve under `/mi-*`.
  - Status line wrapper is `.claude/mi-stage-info-bar.sh`.

---

## 8. Explicitly out of scope

- **The GitHub repo URL and the top-level working-copy directory name.** `marketplace.json.homepage` (`https://github.com/Eminakkoc/millwright-overseer-development-machine`) and the on-disk folder `Millwright-Overseer-Development-Machine/` are tracked as a separate concern. They can be renamed in a follow-up PR (with a GitHub repo rename + redirect, a local `git mv` or fresh clone, and a `marketplace.json` URL update), or kept indefinitely as historical artifacts. They are deliberately not mixed into this PR.
- **Migration tooling.** No script that translates an existing `millwright-overseer/` workflow tree to the new names. Users who want continuity do it by hand (see §6 Phase 7); the project does not own that path.
- **Historic blueprints and quest subfolders** (`blueprints/history/*/`, archived `quest/*/`). These are append-only by design; the old names inside them are correct as historical records and are not rewritten.

---

## 9. Open question

**D1 — confirm: rename `mo-*` to `mi-*` (Option A, this plan's default), or retain `mo` as an opaque brand token (Option B)?**

If Option A, the plan executes as written. If Option B, Phase 4 is dropped and the `mo-*`/`MO_*`/`mo_*` surface is left intact (with a short note in §1 and the CHANGELOG explaining that `mo` is retained as a product name, not as an abbreviation of *millwright-overseer*).

Implementation starts on confirmation of D1.
