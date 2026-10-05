# Conventions review after implementation — design

- **Feature:** `conventions-review` (CVR-001 … CVR-009)
- **Target version:** 1.12.0 (builds on 1.11.0, skills across the workflow)
- **Blueprint:** `millwright-inspector/workflow-stream/conventions-review/blueprints/current/requirements.md` — the item-level acceptance criteria live there; this spec records the structure chosen at stage 3 and the deltas from the blueprint.

## Goal

When implementation finishes, the workflow checks whether the changed code follows
the skills and rules selected for the feature. One read-only reviewer sub-agent runs
per skill or rule. Validated findings land in `inspector-review.md` as ordinary
stage-5 findings with `source: conventions-review`, so the existing review loop fixes
them and the inspector sees them first.

## Decisions made at stage 3

1. **Logic lives in a helper script** (`scripts/conventions-review.sh`), not in command
   prose. The prose is a thin driver; the script is testable directly. `review.sh`,
   `skills.sh` and `commits.sh`'s `get_range` are called, never changed.
2. **Rule `paths:` follows the Claude Code docs** (code.claude.com/docs/en/claude-md,
   "Path-specific rules"): a YAML list **or a comma-separated string**; **brace
   expansion** (`*.{ts,tsx}`) is supported; rules are discovered recursively and
   through symlinks; a rule without `paths:` applies to every file. The docs do not say
   whether `*` crosses `/` or whether `**` matches zero folders — we keep the
   blueprint's picomatch-style choice (`*` never crosses `/`; `**` matches zero or more
   folders) and record it as an assumption.
3. **Two-phase run.** Every reviewer (all waves) finishes before anything is written.
   A spawn failure or an unparseable reply therefore writes no finding.

## Components

### 1. `scripts/commits.sh changed-lines <feature> <review-head>` (CVR-001)

New case arm next to `changed-files`; one usage-block entry. The base comes from
`get_range` (read, not changed); the end is `<review-head>`, never `HEAD`. An empty
feature or review-head fails with the usage error.

Parses the `@@ -a,b +c,d @@` headers of
`git diff -U0 --no-renames <base>..<review-head>` (`b`/`d` default to 1 when omitted):

| Hunk | Output row |
| --- | --- |
| `d > 0` (added/changed) | `path<TAB>c-(c+d-1)` |
| `d = 0` (deletion only) | `path<TAB>c-(c+1)`, clamped to the file's line count at `<review-head>`; `c = 0` gives `1-1` |
| file deleted, or left with zero lines | nothing |
| moved file (`--no-renames`) | fully added |

### 2. `scripts/conventions-review.sh` (new; CVR-003, CVR-004)

#### `prepare <feature>`

1. **Gate.** Empty feature → usage error. Allowed states: stage 3 with
   `sub-flow=resuming` (the Resume Handler), stage 5, stage 6. Otherwise exit 1 with
   a one-line reason.
2. **Feature-test entry** (`todo.sh is-feature-test` exits 0): print
   `conventions review: not run on the feature-test entry — it tests behaviour, not conventions`
   and exit 0 without writing anything.
3. **Clean.** Remove everything under `tmp/conventions-review/` except its `.gitignore`;
   (re)write that `.gitignore` as `*` + `!.gitignore` (the `bundle.sh` form).
   `tmp/bundles/` is never touched.
4. **Snapshot.** `review_head=$(git rev-parse HEAD)`. Covered files = the distinct
   paths in `commits.sh changed-lines <feature> <review_head>`, minus anything under
   the data root (`data-root.sh`) or `docs/superpowers/`. Copy each with `git cat-file blob "$review_head:$f"`
   into `tmp/conventions-review/<review_head>/<f>` (not `git archive` — it honours
   `export-ignore` / `export-subst`).
5. **Entries.**
   - *Skills:* rows of `skills.sh entries <feature> review` (`name<TAB>abs-path`). The
     source boundary is the folder containing `path` (`dirname` when `path` names a
     file such as `SKILL.md`; the path itself when it is a folder). Each skill covers
     every covered file.
   - *Rules:* `find -L .claude/rules -name '*.md'` (sorted). Only the frontmatter is
     read. No `paths:` → all covered files. With `paths:` → the covered files matching
     any pattern (after comma split and brace expansion); skipped when none match.
     The source boundary is the rule file itself. Entry name = the path relative to
     `.claude/rules/` without `.md`.
   - Main never parses `config.md` and never reads a rule body.
6. **State** in `tmp/conventions-review/<review_head>.state/`:
   - `entries.tsv` — `idx<TAB>name<TAB>kind<TAB>abs-path<TAB>boundary`
   - `entry-<idx>.ranges` — the entry's `path<TAB>start-end` rows (covered files only)
   - `meta` — `feature`, `review-head`, `snapshot` path
7. **Output.** No entries or no covered files → `conventions review: nothing to check`
   (exit 0). Otherwise `conventions review: N reviewers (<names>)` then
   `state: <state-dir>`.

#### `ingest <feature>`

Main has saved each reviewer's final reply verbatim to `<state>/reply-<idx>.md`.
`ingest` finds the run itself — `prepare` leaves exactly one `*.state` folder — so
no path has to cross between prose bash blocks.

- **Pass 1 — parse, write nothing.** Every entry needs a reply with `Entry:`,
  `Result: findings|clean|not-checkable` and `More: yes|no`; `findings` needs `### F-n`
  blocks with `file`, `severity`, `scope`, `quote`, `source`, `summary`, `details`
  (a block missing a field is a *drop*, not a parse failure). A missing or
  unparseable reply → exit 1 with `<entry>: <reason>`.
- **Pass 2 — validate and write.** Drop (and count) a finding when:
  `quote` is empty; `source` is outside the entry's boundary; the normalized quote
  (trim, collapse each whitespace run to one ASCII space) is not found in the
  normalized `source`; `file` has no line number or is not one of this entry's
  covered files; every cited line is outside that file's ranges (out-of-range lines
  are trimmed when at least one stays; a line past the snapshot file's end is never
  in range); severity ∉ {minor, major} or scope ∉ {fix, re-implement}.
- **Seed-id** `conventions:<entry>:<file>:<sha1(normalized quote, UTF-8, no newline)[:8]>`.
  `review.sh find-by-seed-id-family`: any member `open` or `wontfix` → skip; all
  members `fixed` → add as `<seed-id>:r<N>` (N = highest suffix + 1, base counts as 0);
  no members → add plain. Findings from different entries are never merged.
- **Write** `review.sh add <feature> <severity> <scope> "<entry>: <summary>" --source conventions-review --seed-id <id>`,
  details on its own stdin: the reviewer's details, then `quote`, `source` and the
  trimmed `file:line,…` citation.
- **Report** (last stdout line):
  `conventions review: N findings added (<entry>: n, …), M dropped, K entries not checkable`;
  when any reply said `More: yes`, append
  `— <entry> hit the 10-finding cap; run /mi-conventions-review again after fixing`
  (each such entry named). Then one `ledger.sh append` row (failure only warns), then
  delete the snapshot and the state folder.
- A crash mid-pass-2 is safe to re-run: written findings dedupe by seed-id. On any
  failure the run folder stays; the next `prepare` clears it.

### 3. `agents/conventions-reviewer.md` (new; CVR-002)

Frontmatter: `model: sonnet`, `effort: high`, `tools: [Read, Grep]`.
Spawn inputs: feature; snapshot path; ranges-file path; entry name, kind, absolute
path and source boundary; `decisions.md` path when it exists; the return contract.

Behaviour rules:
1. Read the entry file and the linked references that bear on the changed code. A
   requirement from a linked file outside the boundary is quoted through the entry's
   pointer sentence; the linked path and sentence go in `details`.
2. Read changed files from the snapshot only; cite snapshot-relative paths (equal to
   repo-relative). Other project files may be read for context.
3. Report only inside the ranges file's line ranges; a deletion-neighbour range stands
   for the removed code.
4. Do not report what a recorded decision in `decisions.md` explicitly allows.
5. One finding per quoted sentence per file, listing every offending line.
6. At most 10 findings, most important first; `More: yes` when there were more.

Return contract — the whole final reply (the body states this is deliberately not the
standard sub-agent return shape):

```
Entry: <name> (<skill|rule>)
Result: findings | clean | not-checkable
More: yes | no

### F-1
- file: <snapshot-relative path>:<line>[,<line>...]
- severity: minor | major
- scope: fix | re-implement
- quote: "<exact sentence from the entry file or a file inside its boundary>"
- source: <path of the file the quote is from>
- summary: <one line>
- details: |
    what the code does, what the skill or rule asks for, the suggested change
```

`not-checkable` carries one reason line and no findings; it is used only when the
entry has no requirement checkable from code.

### 4. `commands/mi-conventions-review.md` (new; CVR-003)

`**Delegation contract.**` note under the H1 (§8.15) naming `conventions-reviewer`.

1. **Prepare** — one bash block: bind `active_feature` via `progress.sh get-active`
   (stop on empty), run `prepare`, print `${MI_CONVENTIONS_REVIEW_MODEL:-sonnet}`.
   `nothing to check` or the feature-test line → relay and stop (success).
2. **Spawn** — read `entries.tsv`; spawn
   `millwright-inspector-development-machine:conventions-reviewer` with the printed
   `model`, at most 3 per wave, each wave in one message. Save each final reply
   verbatim with the Write tool to `<state>/reply-<idx>.md`. A spawn error or
   unavailable agent → print `conventions review: failed — <error>` and stop.
3. **Ingest** — bash block binding `active_feature` again; run `ingest`. Non-zero →
   `conventions review: failed — <stderr>` and stop. Otherwise relay the report line.

### 5. `/mi-continue` Resume Step 6.5 (CVR-005)

Between Resume Step 6 and Step 7: run `/mi-conventions-review` in every mode, no
prompt. On failure, print the failed line and stop before Step 7 — the feature stays
at stage 3 and the next `/mi-continue` re-runs the Resume Handler (Step 5 diagrams are
freshness-cached, Step 6 is idempotent, findings dedupe by seed-id). Diagrams are not
re-rendered here. Step 7 prints the report line before the hand-off, outside the
blockquotes beside the `skills:` line; the auto-answer lines stay put. The Delegation
contract's sub-agent list gains `conventions-reviewer` (via `/mi-conventions-review`,
Resume Step 6.5).

### 6. Fixer contradicting-findings rule (CVR-007)

Next to the one-iteration rule in `agents/review-iteration-runner.md`, the Step 3a.2.4
spawn prompt in `commands/mi-review.md`, and Step 3b (direct mode):

> If two open findings ask for opposite things, fix neither. Leave both `open` and name
> them as `Needs inspector: IR-x vs IR-y — <one line>`.

The runner puts the line under `Findings / risks`; direct mode in its end-of-iteration
summary. Both stay open, so the Review-Resume prompt and `auto.sh approve-guard` keep
the loop from approving.

### 7. Wiring (CVR-006)

- `templates/inspector-review.md.tmpl`: `conventions-review` as a `source:` value with
  seed-id `conventions:<entry>:<file>:<sha8>[:r<N>]`; reword the sentence naming
  `/mi-manual-test-run` as the only emitter. Frontmatter and skeleton unchanged.
- `tests/lint/run.sh`: `mi-conventions-review` in `DELEGATING_COMMANDS`.
- `docs/millwright-inspector-project.md`: agent table row (sonnet/high) and
  `changed-lines` on the `commits.sh` row.

## Testing (CVR-008)

`tests/conventions-review/run.sh` builds fixture git repos with a sandboxed
`MI_DATA_ROOT`, calls repo scripts explicitly, and runs under `env -u CLAUDE_PLUGIN_ROOT`.

- `changed-lines`: added, changed, deletion-only, emptied, deleted, moved.
- `prepare`: stage gate; feature-test no-op; nothing to check; `paths:` rule skipped
  with no match; nested + symlinked rule picked up; comma-string and brace `paths:`;
  `*` / `**` cases; uncommitted edit does not shift lines; `export-ignore` /
  `export-subst` byte match with `git cat-file blob`; root `.gitignore` copy does not
  collide; `tmp/bundles/` untouched.
- `ingest` with canned replies: the eight drop cases counted; partial trimming;
  linked-reference, pointer-sentence and wrapped quotes kept; deletion-neighbour and
  moved-file lines kept; two entries on one line → two findings; second run adds
  nothing, also after a line shift; `fixed` → `:r1`; `wontfix` skipped; unparseable
  reply writes nothing; report line and cap note.
- Static: reviewer `tools:` is exactly `[Read, Grep]`; every bash block of the new
  command and of Step 6.5 extracted and run with `active_feature` unset — recovers the
  feature when one is active, fails cleanly when none is.
- Live reviewer fixtures (run by hand in the implementing session): known violation →
  exact `file:line` + quote; clean skill → `clean`; `decisions.md` suppression;
  Context7-style rule → `not-checkable`.
- Manual: spawn-failure recovery; mi-sample end-to-end with the Sonnet-vs-Opus check.
  The live workflow runs from the installed plugin, so the end-to-end run needs 1.12.0
  installed — tracked as a deferred question, not done by installing mid-cycle.
- Existing suites stay green: `tests/lint/run.sh`, `tests/auto-mode/run.sh`,
  `tests/skills/run.sh`.

## Release (CVR-009)

`.claude-plugin/plugin.json` → `1.12.0`; `CHANGELOG.md` entry covering the agent and
its `$MI_CONVENTIONS_REVIEW_MODEL` override, the command, Resume Step 6.5,
`commits.sh changed-lines`, the `conventions-review` source and the fixer rule, noting
that in-flight features run Step 6.5 at their next stage 3 → 5 transition. No other
file embeds `1.11.0` as the current version.
