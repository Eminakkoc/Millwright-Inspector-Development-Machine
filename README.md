# millwright-overseer-development-machine

An agentic workflow system for Claude Code where an AI "millwright" writes all the code and a human "overseer" reviews each stage's output. The workflow produces an auditable trail of requirements, specs, plans, diagrams, and reviews for every feature.

See [`docs/workflow-spec.md`](./docs/workflow-spec.md) for the full specification and [`docs/diagrams/workflow-sequence.svg`](./docs/diagrams/workflow-sequence.svg) for the end-to-end sequence diagram.

## Installation

The plugin does not declare `superpowers` as a hard Claude Code dependency — if it did, Claude Code would refuse to load the plugin before `/mo-init` had a chance to prompt you. Instead, `/mo-init` detects everything missing (including the superpowers plugin) on first run and asks to install.

Two ways to load the plugin:

### Local dev (iterating on plugin source)

```bash
claude --plugin-dir /absolute/path/to/millwright-overseer-development-machine
```

Edits to the source are picked up by `/reload-plugins` — no reinstall.

### Marketplace install (end-user)

```
/plugin marketplace add <source-containing-this-plugin>
/plugin install millwright-overseer-development-machine@<alias>
/reload-plugins
```

Either way, after the plugin loads run `/mo-init` once — it installs any missing CLI deps (yq, pyyaml, etc.) after a single y/n, shows you the `/plugin marketplace add` + `/plugin install` commands for superpowers (can't auto-run those from Bash), and scaffolds the `millwright-overseer/` workspace folders.

On first run, the plugin creates a `millwright-overseer/` folder at your project root for workflow data (journal, quest, workflow-stream). This location is configurable via `userConfig.data_root` when you enable the plugin.

## Requirements

- **Claude Code** ≥ 2.1.110 (required for plugin dependency resolution).
- **`yq`** on your PATH — used by scripts to read/write YAML frontmatter. Install via `brew install yq` or equivalent.
- **`plantuml-mcp-server`** on your PATH — used to render diagrams. The plugin auto-configures it as an MCP server on enable, but you must install the binary yourself (e.g., `npm install -g plantuml-mcp-server`).
- **`ajv-cli`** (optional) — used for deep JSON Schema validation of workflow files. Falls back to `yq`-based structural checks if absent. Install via `npm install -g ajv-cli`.
- **Superpowers plugin** (or local skill equivalents) — provides the `brainstorming`, `writing-plans`, `executing-plans`, `subagent-driven-development`, and `finishing-a-development-branch` skills that stage 3 hands control to. **Deliberately NOT declared as a Claude Code plugin dependency** — Claude Code's `dependencies` field is a hard load-time gate, and declaring it would prevent `millwright-overseer-development-machine` from loading before `/mo-init` could guide the install. `/mo-init` detects missing superpowers skills and prints the `/plugin marketplace add` + `/plugin install` commands for you to run (these cannot be auto-run from Bash). You can also satisfy the skills by dropping local `SKILL.md` files under `.claude/skills/<name>/` for each of the five skills.

### Optional companions (token-reduction)

These are detected by `/mo-doctor` but never required. The workflow runs identically without them; when present, specific commands auto-detect and take advantage.

- **`rtk`** (rtk-ai/rtk) — a pre-tool-use hook that filters verbose shell output (git diffs, test runs, logs) before it reaches Claude. Targets the exact kinds of commands the brainstorming review session and `/mo-generate-implementation-diagrams` run (`git diff <base>..HEAD`), plus everything the stage-3 brainstorming chain runs during execution. Real session-level savings. Install via `brew install rtk && rtk init -g`. No plugin-level integration — once installed, it applies session-wide.
- **`docling`** ([docling-project/docling](https://github.com/docling-project/docling)) — IBM's document converter. Powers `/mo-ingest`. Required only for formats that Claude Code's `Read` tool can't handle natively (`.docx`, `.pptx`, `.xlsx`, `.html`) or for PDFs over 20 pages (where `Read`'s per-call page cap would require cumbersome chunking). Ingest routes each journal file based on a recommendation the overseer confirms per-file in `/mo-run`: (a) docling-required files run through docling with `--image-export-mode referenced`; figures land in a `<stem>.images/` subfolder and the generated `.md` points at them, so the millwright reads the extracted text AND can open each figure natively when needed. (b) Short PDFs default to a native-read stub — a small `.md` that references the original PDF so the millwright opens it via `Read` during stage 1/2 (no preprocessing, no docling dependency needed for this case). (c) Standalone images (`.png`, `.jpg`, etc.) always go through a stub — docling's default image pipeline base64-wraps pixels and handles UI captures / diagrams poorly. Docling's picture-description (VLM) enrichment is intentionally disabled across the board — the millwright is already a VLM, so a second one describing figures for it would be redundant and lossy. **Skip this companion if your journal will only ever contain `.md`, `.txt`, short PDFs, and images** — `Read` covers all of those natively. Install via `pipx install docling` or `python3 -m pip install --user docling`. Pulls ML dependencies (torch, transformers) — first conversion may download a few hundred MB of models.

### Status line (opt-in, per-machine)

Run `/mo-init-status-bar` once per machine and Claude Code will show the current mo-workflow stage at the bottom of the window — `mo-workflow · <feature> · Stage <N> · <stage-name>` — refreshing on every Claude Code event. No hook, no token tracking, no sidecar. Outside an mo-workspace it prints nothing (the bar collapses cleanly).

The command writes a small wrapper at `.claude/mo-stage-info-bar.sh` (with the plugin's absolute path baked in — `$CLAUDE_PLUGIN_ROOT` is not expanded inside `statusLine.command`) and points your machine-local `.claude/settings.local.json` at it. The change takes effect on your next interaction with Claude Code (no restart needed).

`/mo-init` offers to wire this automatically at the end of the wizard. Re-run the standalone command on other machines, after resetting your settings, or after a marketplace plugin upgrade if the wrapper's fallback scan can't find the new install. Flags: `--user` writes to `~/.claude/`; `--project-shared` writes to the committed `.claude/settings.json` (warned — the wrapper's baked-in path is machine-specific).

## How to use

In the happy path, the overseer types just **three** slash commands across the entire workflow:

| Slash command | When | Purpose |
| --- | --- | --- |
| `/mo-init` | Once per workspace | First-run wizard — installs deps and scaffolds the data folders. |
| `/mo-run <folder1> [<folder2> ...]` | Once per cycle | Creates a per-cycle subfolder under `quest/` (named after a date-prefixed slug derived from the journal folders) and generates the cycle's four files inside it (`todo-list.md`, `summary.md`, `progress.md`, `queue-rationale.md`). The top-level `quest/active.md` pointer tracks which subfolder is currently active; older subfolders are preserved across cycles as a permanent task archive. Pass `--archive-active` if a previous cycle is still in flight and you want to retire it without finishing. |
| `/mo-continue` | At every gate during the cycle | Universal advancement signal. Reads `progress.md`, dispatches to the right handler (Pre-flight, Approve, Resume, Overseer, Review-Resume), and auto-fires the next launcher when appropriate. |

Everything else — `/mo-apply-impact`, `/mo-plan-implementation`, `/mo-review`, `/mo-draw-diagrams`, `/mo-complete-workflow` — is **auto-fired by the millwright on the right `/mo-continue`**. You never type those.

You also reply to a handful of short prompts in chat (no slash commands):

- `brainstorming` or `direct` — planning-mode at stage 3 and review-mode at stage 6.
- A short reason or `continue` — at the post-implementation drift check (stage 4).
- `approve` — to end a brainstorming review session (stage 6).
- `y` or `n` — at the optional diagram refresh after the review session.

Plus you edit a few files directly:

- `journal/<topic>/*.md` `.txt` — author the raw inputs.
- the active cycle's `todo-list.md` (under `quest/<active-slug>/`; resolve via `bash $CLAUDE_PLUGIN_ROOT/scripts/quest.sh dir`) — mark items with `[x]` and add `(assignee)` tags.
- `blueprints/current/config.md` — fill `## GIT BRANCH`, optionally add prompts under `## Overseer Additions`.
- `implementation/overseer-review.md` — write findings (plain sentences are fine; the millwright canonicalizes them into `### IR-NNN` blocks).

### Optional commands (special cases)

These exist for non-happy-path situations; you don't need them in the normal flow:

| Command | When you'd use it |
| --- | --- |
| `/mo-ingest <folder>` / `--file <path>` | Convert non-text journal files (PDF, DOCX, PPTX, XLSX, HTML, images) into sibling `.md`. Skip if your journal only ever contains `.md` and `.txt`. |
| `/mo-doctor` | Detailed dependency check with per-dep prompts. (Auto-invoked by `/mo-run` preflight.) |
| `/mo-draw-diagrams` | Manually re-render implementation diagrams. (Auto-fired during stage 4; manual is for recovery.) |
| `/mo-abort-workflow [--drop-feature=requeue]` | Safe-cancel an in-flight workflow. Preserves the blueprint; never touches git. (Use `/mo-complete-workflow` directly when the feature actually shipped — `--drop-feature=completed` was removed because it bypassed canonical stage-8 work.) |
| `/mo-resume-workflow` | Diagnostic — reads `progress.md` and recommends the next command. |
| `/mo-update-blueprint <reason>` | Mid-cycle blueprint refresh from implementation reality. |
| `/mo-update-todo-list <subcmd>` | Manual edits to `todo-list.md` (add / cancel / set-state). |

### Stages at a glance

| Stage | What happens | Driver | Your action |
| ---: | --- | --- | --- |
| 0 | Journal populated | Overseer | Drop notes / transcripts / specs into `journal/<topic>/`. |
| 1 | Quest generated | `/mo-run` (overseer) | `/mo-run <folder...>` |
| 1.5 | Selection + ordering | Pre-flight Handler | Mark `[x] (assignee)` items in the cycle's `todo-list.md`; `/mo-continue` ×2. |
| 2 | Blueprint generated | `/mo-apply-impact` (auto) | Review `blueprints/current/`; edit `## GIT BRANCH` and `## Overseer Additions`; `/mo-continue`. |
| 3 | Implementation | brainstorming chain or direct | Pick `brainstorming` or `direct`; drive the chain (or watch direct work). |
| 4 | Implementation resumed | Resume Handler | `/mo-continue`; reply to drift check (`continue` or a reason). |
| 5 | Overseer review | Overseer | Edit `overseer-review.md` (or leave empty); `/mo-continue`. |
| 6 | Review session | `/mo-review` (auto) | Pick `brainstorming` or `direct`; drive the loop; `approve`. |
| 7 | Review completed | Review-Resume Handler | `/mo-continue`; optional diagram refresh (`y`/`n`). |
| 8 | Completion | `/mo-complete-workflow` (auto) | None — millwright closes out and loops to the next queued feature. |

After stage 8, if more features are queued, the millwright auto-fires `/mo-apply-impact` for the next one (back to stage 2). If the queue empties but `[ ] TODO` items remain, you're prompted to mark the next batch and `/mo-continue` (re-entering stage 1.5; the same per-cycle quest subfolder stays active). When everything is done — queue empty AND no `[ ] TODO` items left — `/mo-complete-workflow` archives the active-quest pointer (the cycle's subfolder under `quest/<slug>/` is preserved as a historical record), then run `/mo-run` again to start a new cycle.

For the full prose walkthrough with every nuance (preflight checks, ingest decision flow, stage-by-stage details), see [Quickstart](#quickstart) below or [`docs/workflow-spec.md`](./docs/workflow-spec.md).

## Quickstart

0. **First run: `/mo-init`.** One-prompt wizard — checks every dependency (CLI tools, Python modules, MCP server, skills), offers a single y/n to install everything missing at once, and scaffolds the `millwright-overseer/` data folders (`journal/`, `quest/`, `workflow-stream/`). If you prefer per-dep prompts and a detailed JSON report, use `/mo-doctor` instead. `/mo-run` also runs the same dependency preflight automatically, so you can skip straight to step 2 if you're confident everything is already in place.
1. Populate `millwright-overseer/journal/` with any relevant resources (meeting transcripts, notes, spec documents) as `.md` or `.txt` files. `.md` files get `contributors:` and `date:` YAML frontmatter manually; `.txt` files have no metadata requirement and are read as plain content. PDFs, Word/PowerPoint/Excel docs, and images are also supported — drop them in the same folder and `/mo-run` will detect each one, recommend whether to route it through docling (required for DOCX/PPTX/XLSX and PDFs over 20 pages) or through a native-read stub (Claude's `Read` tool handles short PDFs directly; images go through a stub regardless because Claude is already a VLM), and ask per file. You can also convert ahead of time via `/mo-ingest <folder>` or per-file via `/mo-ingest --file <path>` / `/mo-ingest --stub <path>`. Originals stay in place for audit.
2. Run `/mo-run <folder1> [<folder2> ...]` — pass the journal sub-folder names you want this cycle to cover. Creates a per-cycle subfolder under `quest/` (named e.g. `2026-04-27-pricing-meeting+auth-rfc/`) and generates `todo-list.md`, `summary.md`, and `progress.md` inside it from the content of the named folders only. `progress.md` holds the feature queue, completed list, and the active feature's runtime state (null until stage 2 activates one). The top-level `quest/active.md` pointer is updated to reference the new subfolder; older subfolders from previous cycles are kept untouched as a permanent record. Branch selection happens per-feature at stage 2 via `blueprints/current/config.md`'s `## GIT BRANCH` section (pre-filled from HEAD if you're on a non-trunk branch; otherwise `/mo-plan-implementation` prompts you at stage 3). If a previous cycle is still active, pass `--archive-active` to retire it without finishing.
3. Open the cycle's `todo-list.md` (the `/mo-run` handoff message prints the path; you can also resolve it any time with `bash $CLAUDE_PLUGIN_ROOT/scripts/quest.sh dir`) and **mark the items you want implemented by putting an `x` in their checkbox AND adding your assignee name** between the checkbox and state word: `- [ ] TODO — ...` → `- [x] (emin) TODO — ...`. The `(assignee)` tag is optional on `[ ] TODO` lines (pre-assignment) but **required** on any `[x]` line — `todo.sh pend-selected` rejects unassigned selections and asks you to add names. No need to rewrite the `TODO`/`PENDING` state word. When you're done marking, type **`/mo-continue`** — the Pre-flight Handler promotes selections to PENDING, analyzes cross-feature dependencies, and proposes a queue order. Type `/mo-continue` once more to accept the proposal (or paste a custom order first); the millwright then **auto-launches `/mo-apply-impact`** for the first feature.
4. For each feature, the workflow runs stages 2–8. Launcher commands are **auto-fired by the millwright** after the preceding overseer gate:
   - `/mo-apply-impact` (auto) — generates requirements + config + diagrams for review.
   - Type `/mo-continue` after reviewing the blueprints — this is the only gate before stage 3.
   - `/mo-plan-implementation` (auto, on approval) — asks you to pick a **planning-mode** (`brainstorming` or `direct`); `brainstorming` launches the chain in an isolated session, `direct` keeps implementation in the main session with `primer.md` as the required first read.
   - `/mo-continue` (manual) — resumes the workflow, generates implementation diagrams (with existing-vs-new framing) via `/mo-draw-diagrams`, hands off to the overseer for review.
   - (review loop) — overseer writes findings to `overseer-review.md` (**plain sentences are fine — the millwright canonicalizes them into `### IR-NNN` blocks before the review session starts**); the second `/mo-continue` invokes `/mo-review`, which asks you to pick a **review-mode** (`brainstorming` for an isolated session, `direct` to address findings in the main session). The overseer ends the session with `approve`, then types `/mo-continue` a third time to advance.
   - `/mo-complete-workflow` (auto, on review clean exit) — offers a diagram refresh first if review-loop commits exist, archives artifacts into `blueprints/history/`, advances the queue. **If the queue is empty but unmarked `[ ] TODO` items remain in the cycle's `todo-list.md`**, the workflow stops and asks you to mark the next batch (a third `/mo-continue` re-enters stage 1.5 via `progress.sh enqueue` without scrubbing the existing per-cycle quest subfolder). When the queue empties AND no `[ ] TODO` items remain, the cycle ends — `/mo-complete-workflow` archives `quest/active.md` (the per-cycle subfolder under `quest/<slug>/` is preserved as a historical record) and a fresh `/mo-run` can start a new cycle.

Overseer touchpoints per feature shrink to: `/mo-continue` ×2 at stage 1.5, `/mo-continue` after blueprint review, planning-mode pick, `/mo-continue` ×2 (or ×3 with findings), review-mode pick, optional diagram-refresh y/n, and optional edits to `overseer-review.md`. Launcher commands remain invokable manually for recovery (e.g. after `/mo-abort-workflow`).

See `docs/workflow-spec.md` for the full stage-by-stage reference.

## Command list

| Command                      | Invocation | Purpose                                                                    |
| ---------------------------- | ---------- | -------------------------------------------------------------------------- |
| `/mo-init`                   | overseer   | First-run wizard: one-prompt dependency install + data-folder scaffolding. |
| `/mo-doctor`                 | overseer   | Detailed dependency check; per-dep install prompts and sudo handling.      |
| `/mo-ingest`                 | overseer   | Convert non-text journal files (PDF/DOCX/PPTX/XLSX/images) to sibling .md. |
| `/mo-run`                    | overseer   | Generate quest files from `journal/`.                                      |
| `/mo-apply-impact`           | **auto**   | Generate `blueprints/current/` for the active feature.                     |
| `/mo-plan-implementation`    | **auto**   | Asks for `planning-mode` (brainstorming or direct), then launches the chosen path with `primer.md` as the required first read. |
| `/mo-continue`               | overseer   | Universal advancement signal — dispatches to pre-flight, approve, resume, overseer-review, or post-review handlers based on state. |
| `/mo-review`                 | internal   | Asks for `review-mode` (brainstorming or direct), then launches the chosen path against open findings; runs the fix-and-approval loop until the overseer types `approve`. |
| `/mo-draw-diagrams`          | overseer / **auto** | Render implementation diagrams from `base-commit..HEAD` into `implementation/diagrams/`. Auto-fired by the Resume Handler at stage 4 and (optionally) by the Review-Resume Handler at stage 6→7. |
| `/mo-generate-implementation-diagrams` | internal | Internal name — the body of `/mo-draw-diagrams --target=implementation`. Existing wiring keeps both names valid. |
| `/mo-complete-workflow`      | **auto**   | Archive and advance to next queued feature; or stop and ask for more TODO marks if the queue is empty but todos remain. |
| `/mo-abort-workflow`         | overseer   | Safely cancel an in-flight workflow; preserves blueprints.                 |
| `/mo-resume-workflow`        | overseer   | Diagnostic dispatcher: reads state and recommends next command.            |
| `/mo-update-blueprint`       | overseer   | Manually rotate + regenerate `blueprints/current/` with a reason.           |
| `/mo-update-todo-list`       | overseer   | Add / cancel / change state on todo items (state-machine safe).            |

Commands marked **auto** are fired by the millwright on the preceding overseer gate (see the Quickstart). They remain invokable manually for recovery.

## Configuration

`userConfig` exposes a single setting:

- **`data_root`** (default: `millwright-overseer`) — where workflow data lives relative to project root. If you want workflow data hidden, set to `.millwright-overseer`. The Claude Code plugin runtime surfaces this value to the workflow scripts via the `CLAUDE_PLUGIN_USER_CONFIG_data_root` env var; you can also override it ad-hoc by exporting `MO_DATA_ROOT` in your shell (takes precedence over `userConfig.data_root`). All commands resolve the data root via `scripts/data-root.sh`, so paths shown in this README and the docs as `millwright-overseer/...` will be `<your-data-root>/...` if you've changed the setting.

## Safety

- `mo-abort-workflow` never touches git. Branches and commits remain the overseer's to manage.
- A PostToolUse hook validates YAML frontmatter on every write to workflow files and blocks malformed writes.
- Every generated file has a stable UUID in frontmatter plus typed reference fields for cross-linking; IDs are generated by `scripts/uuid.sh` (never by the AI directly) to eliminate hallucination.

## License

MIT — see [`LICENSE`](./LICENSE).
