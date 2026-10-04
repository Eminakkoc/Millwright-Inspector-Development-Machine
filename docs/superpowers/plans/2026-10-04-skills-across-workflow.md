# Skills Across the Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Skills are selected once at stage 2, installed at the stage-2 approve gate, and handed through `scripts/skills.sh` to every step and sub-agent that writes or judges code (release 1.11.0).

**Architecture:** One helper script (`scripts/skills.sh` + `scripts/internal/skills.py`, already committed in Task 1) owns every read and the one deterministic rewrite of `config.md`'s auto block. Every other change is prose in `commands/`, `agents/`, `docs/` and `templates/` that calls `skills.sh` instead of parsing files, plus pinned-fixture updates and a release bump.

**Tech Stack:** bash 3.2 (macOS), python3 (stdlib only), markdown command/agent prose, the repo's standalone `tests/*/run.sh` suites.

**Spec:** `docs/superpowers/specs/2026-10-04-skills-across-workflow-design.md`. Full acceptance criteria per item: `millwright-inspector/workflow-stream/skills-across-workflow/blueprints/current/requirements.md` (SKL-001 … SKL-013).

## Global Constraints

- Target release **1.11.0**, breaking; no migration of in-flight workflows or old `config.md` files.
- **Skills only.** Rules, plugins, MCP servers and hooks are reported, never installed or listed in `config.md`.
- **One reader.** Every consumer reads the selection through `skills.sh` (`brief`, `entries`, `suggestions`) — never by parsing `config.md` or scanning `.claude/skills/` itself.
- **Project scope only.** `~/.claude/skills/` is never a source; only `scope: project` catalog skills; never `catalog add --user`.
- **Pre-1.11.0 shapes read as empty, never as an error** (no `## Requested skills`, no `## Catalog suggestions`, entries without `stages:`/`skill:`).
- **`catalog` CLI is optional everywhere** — absence → one stderr note (`catalog CLI not found — catalog suggestions skipped`), exit 0.
- New scripts run on **macOS bash 3.2** (no associative arrays, no `mapfile`).
- **Every new prose bash block is run once by hand** in a sandbox data root (`MI_DATA_ROOT=<tmp>`), never against the live `millwright-inspector/` cycle. Prose bash fails silently.
- Run repo test suites with **`env -u CLAUDE_PLUGIN_ROOT`** so they exercise this branch, not the installed plugin.
- `commands/mi-plan-implementation.md` **Step 2 text stays byte-identical.**
- New prose must not contain the never-auto audit phrases (`never auto`, `do not auto`, `Do NOT auto-fire`, `Wait for the`, case-insensitive) unless the task says to update `tests/auto-mode/fixtures/never-auto-expected.txt`.
- New files must not contain the retired `mo-` / `mo_` tokens (`tests/lint/run.sh`).
- Commit on `feat/skills-across-workflow` only. Do not push, merge, or create branches/worktrees.

## Review Focus

1. **A `config.md` from 1.10.0 reaching 1.11.0 code** (old three sections, `## Rules`, no `stages:`). Expect: every consumer renders nothing and carries on — no error, no empty headings. Pinned by `tests/skills` (`old-config.md`) and by Task 6/8/9 hand-runs against `tests/skills/fixtures/old-config.md`.
2. **Stage-2 gate re-entry after a partial run** (stop chosen, or a git failure after installs). Expect: the next `/mi-continue` re-asks only about remaining `requested: no` entries, re-commits still-changed files, and never double-moves an entry. Pinned by the `apply-installs` round trip and Task 5's re-entry hand-run.
3. **Unrelated staged files during the install commit.** Expect: they stay staged and are absent from the `chore(skills)` commit. Pinned by Task 5 Step 4.
4. **A `/mi-sidequest` or PR command with no active feature / no `config.md`.** Expect: spawn prompts identical to today's (no empty skills block). Pinned by Task 8 Step 5.
5. **Plan files whose tasks don't use `### Task <N>` headings, or no plan at all (direct mode).** Expect: the Resume report line is silent rather than printing `0 of 0`. Pinned by Task 7 Step 3.

---

### Task 1: `scripts/skills.sh` (DONE — commits `517d856`, `35c5c41`)

**Files:**
- Create: `scripts/skills.sh`, `scripts/internal/skills.py`
- Test: `tests/skills/run.sh`, `tests/skills/fixtures/{brief-config,old-config,gate-config,gate-after-stop,gate-after-retry}.md`

**Interfaces (Produces — every later task relies on these exact forms):**
- `skills.sh inventory [--installed]` → TSV `name kind origin description path needs`; kinds `skill|catalog-skill|broken`.
- `skills.sh lookup <name|bundle:name>…` → TSV `name kind scope bundle`; unknown → `<name>\tunknown\t-\t-`.
- `skills.sh brief <feature> implement|review` → block headed `## Skills for this work (from config.md)` / `## Skills for reviewing this work`, then a load-instruction line, then `- <skill> — <reason> — <abs path>` per entry. Nothing when no entry matches.
- `skills.sh entries <feature> implement|review` → TSV `skill\tabs-path`.
- `skills.sh suggestions <feature>` → TSV `name requested stages install reason` for `## Catalog suggestions`; nothing when empty or pre-1.11.0.
- `skills.sh catalog-files` → project-relative paths (changed lock-file skill files + `.claude/catalog.lock.json`).
- `skills.sh apply-installs <feature> [--installed a,b] [--declined c] [--failed d] [--stop]` → rewrites the auto block (rules in the spec, Component 1).
- Entry format in `config.md` (two lines):
  ```
  - <name> — <reason>
    stages: implement, review; skill: <name>; path: <path>[; origin: catalog-installed]
  ```
  Suggestions: `  stages: …; requested: journal|no; install: catalog add <name>`.

- [x] **Step 1:** Implemented, `bash tests/skills/run.sh` → `skills: 36 passed, 0 failed`. Committed.

---

### Task 2: Stage 1 — `## Requested skills` and `## Named resources` (SKL-002)

**Files:**
- Modify: `templates/summary.md.tmpl` (after the `## Out-of-scope` block, before `## Feature: <feature-name>`)
- Modify: `commands/mi-run.md` Step 4 body-section list (between item 2 `## Out-of-scope` and item 3 `## Feature:`), and the Step 2.5 spawn prompts for both digesters (Tier 1 near line 283, Tier 2 near line 305)
- Modify: `agents/journal-file-digester.md`, `agents/journal-folder-digester.md` (output-shape section)
- Test: hand-run only (no suite covers these files)

**Interfaces:**
- Produces: `summary.md` heading `## Requested skills` with line forms `- <name> — features: <list|all>; source: <file>`, `- (unresolved) "<quote>" — features: <list|all>; source: <file>`, `- (excluded) <name> — features: <list|all>; source: <file>`. Task 3's Step B reads exactly these forms.

- [ ] **Step 1: Add the template section.** In `templates/summary.md.tmpl`, insert after the `## Out-of-scope` section:

```markdown
## Requested skills

<!-- Skills (and other resources) the journal asks this work to use. One line each:
     - <name> — features: <feature-list|all>; source: <journal file>
     - (unresolved) "<quoted sentence>" — features: <feature-list|all>; source: <journal file>
     - (excluded) <name> — features: <feature-list|all>; source: <journal file>
     Exact names asked for in this work are plain lines; examples, past notes and
     one-of-several options are (unresolved); names the journal rules out are
     (excluded) and are never installed, selected or suggested. Rules, plugins,
     MCP servers and hooks the journal names are listed too, so stage 2 can report
     them. Keep the heading when the body is empty. Not covered by ## In plain terms. -->
```

- [ ] **Step 2: Add item 2.5 to `/mi-run` Step 4's list.** After the `## Out-of-scope` bullet, insert:

```markdown
2.5. **`## Requested skills`** — skills and other named resources the journal asks this work to use, built from the digesters' `## Named resources` sections plus the files you read directly. Line forms: `- <name> — features: <list|all>; source: <file>`; `- (unresolved) "<quote>" — features: …; source: …` for examples, past notes and one-of-several options; `- (excluded) <name> — features: …; source: …` for names the journal rules out. Include rules, plugins, MCP servers and hooks the journal names, so stage 2 can report them. A resource whose feature is still `unknown` is written with `features: all` — as `(excluded)` if the journal rules it out, otherwise as `(unresolved)`; it never becomes a plain requested line. Keep the heading even when the body is empty. `## In plain terms` does not cover this section.
```

Also extend item 5's (`## In plain terms`) parenthetical so it reads "each cross-cutting constraint, each out-of-scope entry, and each feature — not `## Requested skills`".

- [ ] **Step 3: Digester output.** In both `agents/journal-file-digester.md` and `agents/journal-folder-digester.md`, add to the required digest content (keep the ≤ 1k-token return cap and the return shape unchanged):

```markdown
**Mandatory `## Named resources` section.** List every skill, rule, plugin, MCP server, hook or CLI tool the material names by exact name, one line each:
`- <exact name> — "<the sentence that names it, quoted>" — <file>[§<location>] — feature: <feature name|unknown>`.
Write `(none)` when nothing is named. Do not judge whether a name is a request — quote it and let stage 1 decide.
```

In `commands/mi-run.md` Step 2.5, add one line to each spawn prompt's task list: `Include the mandatory \`## Named resources\` section (see your agent file) — main builds summary.md's \`## Requested skills\` from it.`

- [ ] **Step 4: Verify extraction is unchanged.** From the repo root:

```bash
repo="$PWD"; sb="$(mktemp -d)"; dr="$sb/millwright-inspector"; q="$dr/quest/2026-10-04-x"; mkdir -p "$q"
printf -- '---\nslug: 2026-10-04-x\nstatus: active\n---\n' > "$dr/quest/active.md"
printf '## Cross-cutting constraints\n\n- c1\n\n## Out-of-scope\n\n- o1\n\n## Feature: alpha\n\nalpha body\n\n## Sources\n\n- j/a.md: a\n' > "$sb/without.md"
awk '1; /^- o1$/{print "\n## Requested skills\n\n- web-images — features: alpha; source: j/a.md"}' "$sb/without.md" > "$sb/with.md"
for v in without with; do
  cp "$sb/$v.md" "$q/summary.md"
  (cd "$sb" && env -u CLAUDE_PLUGIN_ROOT MI_DATA_ROOT="$dr" "$repo/scripts/quest.sh" feature-section alpha) > "$sb/$v.out"
done
diff "$sb/without.out" "$sb/with.out" && echo "feature-section identical"
```

Expected: `feature-section identical` (and both outputs non-empty — `cat "$sb/with.out"`). If `quest.sh dir` resolution needs more pointer fields, copy them from `scripts/quest.sh init-pointer`'s output shape. Then `env -u CLAUDE_PLUGIN_ROOT bash tests/bundle/run.sh` → all pass.

- [ ] **Step 5: Commit.**

```bash
git add templates/summary.md.tmpl commands/mi-run.md agents/journal-file-digester.md agents/journal-folder-digester.md
git commit -m "feat(stage-1): record requested skills in summary.md via digesters' named resources (SKL-002)"
```

---

### Task 3: Stage 2 — skill selection into the new auto block (SKL-003)

**Files:**
- Modify: `templates/config.md.tmpl` (auto block only — lines between `<!-- auto:start` and `<!-- auto:end -->`)
- Modify: `docs/blueprint-regeneration.md` Step B (the paragraph at ~line 291 starting "Scan `.claude/skills/` and `.claude/rules/`")
- Modify: `docs/millwright-inspector-project.md` (every place describing the old `## Skills` / `## Rules` / `## Load on demand` block — `grep -n '## Rules\|Load on demand\|auto:start' docs/millwright-inspector-project.md`)

**Interfaces:**
- Consumes: `skills.sh inventory`, `skills.sh lookup`; `summary.md` `## Requested skills` (Task 2).
- Produces: the auto block format in Task 1's Interfaces. Task 1's `tests/skills/fixtures/gate-config.md` is a valid example.

- [ ] **Step 1: Replace the template's auto block** with exactly:

```markdown
<!-- auto:start — regenerated by mi-apply-impact; do not edit this section -->

<!-- Budget: ≤ 10 entries across ## Skills and ## Load on demand, ≤ 2 lines each.
     Journal-requested and inspector-confirmed skills always stay, even past 10;
     the millwright's own picks fill only the room left and are dropped first.
     ## Catalog suggestions does not count and is empty once the stage-2 gate ran.
     Every entry is read through scripts/skills.sh — keep the two-line format. -->

## Skills

<!-- Skills to load while implementing and/or reviewing this cycle's Goals:
     - <name> — <one-line reason>
       stages: implement, review; skill: <name to call>; path: <SKILL.md path>
     stages: implement (writes or changes code), review (judges without changing),
     or both. path: project-relative for project skills, absolute for plugin skills. -->

## Load on demand

<!-- Installed skills that may apply if a related concern surfaces. Same format. -->

## Catalog suggestions

<!-- Catalog skills not installed yet; the stage-2 approve gate installs them:
     - <name> — <one-line reason>
       stages: implement; requested: journal|no; install: catalog add <name> -->

<!-- auto:end -->
```

Leave `## Lessons learned`, `## GIT BRANCH` and `## Inspector Additions` byte-identical. Verify: `git diff templates/config.md.tmpl | grep '^[-+]' | grep -v 'auto\|^[-+]$\|Skills\|Rules\|Load on demand\|Catalog\|stages\|Budget\|<!--\|-->\|^[-+] '` prints nothing outside the block (eyeball the diff: only auto-block lines change).

- [ ] **Step 2: Rewrite Step B's skill paragraph** in `docs/blueprint-regeneration.md`. Replace the "Scan `.claude/skills/` and `.claude/rules/` …" paragraph (and any rules-related sentences right after it) with:

```markdown
**Skill selection (1.11.0).** Fill the auto block from three inputs — never by listing `.claude/skills/` or `.claude/rules/` yourself:

1. `"$CLAUDE_PLUGIN_ROOT/scripts/skills.sh" inventory` — every installed project skill, enabled-plugin skill and project-scope catalog skill (TSV `name kind origin description path needs`).
2. The `## Requested skills` lines of the cycle's `summary.md` whose `features:` names this feature or `all` (`quest.sh dir` gives the folder). A missing heading means no requests.
3. `"$CLAUDE_PLUGIN_ROOT/scripts/skills.sh" lookup <names…>` for every requested name and `bundle:<name>`, to classify it (`kind`, `scope`; bundles expand into their members).

Use `grounding-report.md` and the Goals as relevance input. Drop every `(excluded)` name everywhere — it must not appear in any section. Then place each candidate:

| Candidate | Goes to |
|---|---|
| requested, not a skill (rule, plugin, MCP server, hook — including such bundle members), or a `scope: user` catalog skill | left out; reported at hand-off |
| requested + installed (`kind=skill`) | `## Skills` |
| requested + `catalog-skill` with `needs` = `-` | `## Catalog suggestions`, `requested: journal` |
| any `catalog-skill` whose `needs` ≠ `-` | left out (reported only when requested) |
| `broken` | left out; reported with `catalog add <name> --force` |
| requested, `unknown` everywhere | left out; reported |
| `(unresolved)` request, or your own useful pick | installed → `## Skills` / `## Load on demand`; catalog → `## Catalog suggestions`, `requested: no` |

Every `## Skills` / `## Load on demand` entry carries `stages:`, `skill:` and `path:` (copy `path` from the inventory row: project-relative for project skills, absolute for plugin skills). Every suggestion carries `stages:`, `requested:` and `install: catalog add <name>`. Respect the budget written at the top of the block. Keep the lists you will need for the hand-off (Step 3.2 of `/mi-apply-impact`): requested not-skills, requested not-found, broken, held back for dependencies (`requested: journal` only), and selected skills shadowed by a personal `~/.claude/skills/<name>` copy (check with `[[ -d ~/.claude/skills/<name> ]]`).
```

Keep the existing instructions about writing only between the markers and preserving the other sections.

- [ ] **Step 3: Update the design reference.** In `docs/millwright-inspector-project.md`, change every description of the auto block to the three new sections and the entry format; remove `## Rules` from it; add one sentence: "All consumers read the selection through `scripts/skills.sh` (`brief`, `entries`, `suggestions`)."

- [ ] **Step 4: Check old readers.** Run `grep -rn '## Rules' commands docs scripts templates agents | grep -v superpowers` — the only remaining hits may be `scripts/bundle.sh` / `docs/bundle/plan.md` (removed in Task 11), `commands/mi-update-blueprint.md` (Task 9) and `commands/mi-plan-implementation.md` (Task 6). Note any other hit in your report.

- [ ] **Step 5: Run suites.** `env -u CLAUDE_PLUGIN_ROOT bash tests/skills/run.sh && env -u CLAUDE_PLUGIN_ROOT bash tests/blueprint-review/run.sh && env -u CLAUDE_PLUGIN_ROOT bash tests/lint/run.sh` → all pass.

- [ ] **Step 6: Commit.**

```bash
git add templates/config.md.tmpl docs/blueprint-regeneration.md docs/millwright-inspector-project.md
git commit -m "feat(stage-2): select skills from inventory + requested skills into the new auto block (SKL-003)"
```

---

### Task 4: Stage 2 hand-off skill report (SKL-004)

**Files:**
- Modify: `commands/mi-apply-impact.md` `#### Step 3.2 — Hand-off message` (line ~473)

**Interfaces:**
- Consumes: the hand-off lists kept by Task 3's Step B; `skills.sh suggestions <feature>`.

- [ ] **Step 1: Add the skill lines.** Before "Tell the inspector", add:

```markdown
**Skill report.** Build `skill_report` — one line per non-empty group, in this order, from the lists Step B kept and from `"$CLAUDE_PLUGIN_ROOT/scripts/skills.sh" suggestions "$active_feature"`:

- `Catalog skills to install at approval (requested in your journal): <names>`
- `Suggested, waiting for your confirmation at /mi-continue: <name> (<reason>), …` (`requested: no` rows)
- `Requested but not found anywhere: <names>`
- `<name>: not a skill — set it up yourself before /mi-continue` (one line per requested rule, plugin, MCP server or hook)
- `<name>: your personal ~/.claude/skills copy overrides the selected one on this machine`
- `<name>: broken catalog install — repair with catalog add <name> --force`
- `<name> needs <needs> (installs outside the project) — run catalog add <name> yourself before /mi-continue` (requested ones only; your own picks with missing dependencies are dropped silently)

Empty groups print nothing. On the `check-current=0` short-circuit re-entry Step B did not run, so `skill_report` is empty there — do not guess.
```

Then insert `> ${skill_report}` as its own paragraph in the blockquote directly after `> ${scope_gate_note}` and its blank `>` line, with the same "omit the line entirely when empty" rule as `scope_gate_note`. Do not change any other line of the blockquote (walkthrough and `/mi-continue` gate unchanged).

- [ ] **Step 2: Verify.** `env -u CLAUDE_PLUGIN_ROOT bash tests/auto-mode/run.sh` → all pass (the never-auto audit must not change — the new text has none of the audit phrases).

- [ ] **Step 3: Commit.**

```bash
git add commands/mi-apply-impact.md
git commit -m "feat(stage-2): report skill groups in the blueprint hand-off (SKL-004)"
```

---

### Task 5: Approve Step 1.5 — install catalog skills (SKL-005)

**Files:**
- Modify: `commands/mi-continue.md` — new `### Approve Step 1.5 — Install catalog skills` between `### Approve Step 1 — Sanity-check blueprint files` and `### Approve Step 2 — Clear-point gate (stage-2-to-3)`; also the Approve Handler intro sentence and the dispatch-table row text for stage 2 if they enumerate steps.

**Interfaces:**
- Consumes: `skills.sh suggestions`, `skills.sh apply-installs`, `skills.sh catalog-files`; `auto.sh is-on`, `auto.sh answer`; `/mi-plan-implementation` Step 2 (unchanged text, run by reference).

- [ ] **Step 1: Write the section** exactly:

````markdown
### Approve Step 1.5 — Install catalog skills

Runs on every entry to the Approve Handler, before the clear-point gate. Re-running it is a no-op once the branch is current and nothing is left to install or commit.

**Step 0 — Resolve the branch.** Run `/mi-plan-implementation`'s **Step 2 — Resolve and validate the primary branch from `config.md`** here, exactly as written there (in auto mode that is `auto.sh create-branch`). It runs even when there is nothing to install, and before any install so `create-branch`'s clean-tree check sees only your own changes. If it stops (prompt, refusal, non-zero exit), this handler stops with it; the next `/mi-continue` re-enters here.

**Step 1 — Read the suggestions.**

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
"$CLAUDE_PLUGIN_ROOT/scripts/skills.sh" suggestions "$active_feature"
```

Each row is `name<TAB>requested<TAB>stages<TAB>install<TAB>reason`. No rows (including a pre-1.11.0 `config.md`) → skip to Step 5.

**Step 2 — Confirm the millwright's own suggestions.** If any row has `requested=no`, ask once, in one sentence, with auto mode on or off:

> "Not in your journal but looks useful: <name> (<reason>), … — install all, none, or name the ones you want?"

The confirmed names join the install list; the rest are declined. Rows with `requested=journal` are installed without asking. In auto mode, log them first:

```bash
if "$CLAUDE_PLUGIN_ROOT/scripts/auto.sh" is-on; then
  "$CLAUDE_PLUGIN_ROOT/scripts/auto.sh" answer "catalog install" "<journal names, comma-joined>" --cmd /mi-continue
fi
```

**Step 3 — Install.** For each name in the install list, run its `install` column plus `--yes` (e.g. `catalog add web-images --yes`), one at a time, recording installed and failed names. When a `requested=journal` install fails, ask:

> "<name> (requested in your journal) failed to install: <error>. Retry, continue without it, or stop?"

`retry` → run it again. `continue` → it counts as failed. `stop` → it counts as failed, the names not yet attempted are left alone, and Step 4 gets `--stop`. A failed `requested=no` install is reported by name and counts as failed. If `catalog` is not on PATH, every install fails with that message.

**Step 4 — Rewrite `config.md`.**

```bash
"$CLAUDE_PLUGIN_ROOT/scripts/skills.sh" apply-installs "$active_feature" \
  --installed "<installed, comma-joined>" --declined "<declined>" --failed "<failed>" [--stop]
```

Omit an option whose list is empty. Installed entries move to `## Skills` (`origin: catalog-installed`); declined and failed entries are deleted, except failed journal entries and unattempted ones on `--stop`, which stay for the next `/mi-continue`.

**Step 5 — Commit the installs.**

```bash
paths="$("$CLAUDE_PLUGIN_ROOT/scripts/skills.sh" catalog-files)"
if [[ -n "$paths" ]]; then
  items="$(printf '%s\n' "$paths" | sed -n 's|^\.claude/skills/\([^/]*\)/.*|\1|p' | sort -u | paste -sd, - | sed 's/,/, /g')"
  printf '%s\n' "$paths" | tr '\n' '\0' | xargs -0 git add --
  printf '%s\n' "$paths" | tr '\n' '\0' | xargs -0 git commit -m "chore(skills): install ${items:-catalog skills} from catalog" --
fi
```

The trailing pathspec keeps any other staged file staged and out of this commit. If `git add` or `git commit` fails, stop and relay the error; the next `/mi-continue` re-runs this step and commits the still-changed paths. If the inspector chose `stop` in Step 3, stop here after the commit and say which entries are still waiting. Otherwise continue to Approve Step 2.
````

- [ ] **Step 2: Hand-run Step 5 in a sandbox** (from the repo root):

```bash
sb="$(mktemp -d)" && cd "$sb" && git init -q -b feat/x && git config user.email t@t && git config user.name t
echo seed > a && git add a && git commit -qm seed
mkdir -p .claude/skills/web-images && echo s > .claude/skills/web-images/SKILL.md
printf '{"version":1,"items":{"web-images":{"kind":"skill","files":[".claude/skills/web-images"]}}}\n' > .claude/catalog.lock.json
echo other > staged.txt && git add staged.txt
CLAUDE_PLUGIN_ROOT="$OLDPWD"
paths="$("$CLAUDE_PLUGIN_ROOT/scripts/skills.sh" catalog-files)"
items="$(printf '%s\n' "$paths" | sed -n 's|^\.claude/skills/\([^/]*\)/.*|\1|p' | sort -u | paste -sd, - | sed 's/,/, /g')"
printf '%s\n' "$paths" | tr '\n' '\0' | xargs -0 git add --
printf '%s\n' "$paths" | tr '\n' '\0' | xargs -0 git commit -qm "chore(skills): install ${items:-catalog skills} from catalog" --
git log -1 --format=%s; git show --stat --format= HEAD; git diff --cached --name-only
cd "$OLDPWD"
```

Expected: subject `chore(skills): install web-images from catalog`; the commit lists `.claude/catalog.lock.json` and `.claude/skills/web-images/SKILL.md` only; `git diff --cached` still lists `staged.txt`. Fix the block if any expectation fails, and copy the fixed form into the section.

- [ ] **Step 3: Hand-run re-entry.** In the same style, run Step 5 a second time with nothing changed → no commit, exit 0. Run Step 1's `suggestions` against `tests/skills/fixtures/gate-after-retry.md` and `old-config.md` (copied into a sandbox feature) → no rows.

- [ ] **Step 4: Point the handler at the new step.** Update the Approve Handler's opening paragraph to mention the install step, and wherever `commands/mi-continue.md` describes the stage-2 flow as "sanity check, clear-point gate, then /mi-plan-implementation", insert "skill install". Do not touch `commands/mi-plan-implementation.md` Step 2.

- [ ] **Step 5: Verify.** `env -u CLAUDE_PLUGIN_ROOT bash tests/auto-mode/run.sh` → all pass. If the never-auto audit fails, the new text contains an audit phrase — reword it (do not update the fixture).

- [ ] **Step 6: Commit.**

```bash
git add commands/mi-continue.md
git commit -m "feat(gate): install catalog skills and commit them at the stage-2 approve gate (SKL-005)"
```

---

### Task 6: Stage 3 — skills into the primer and the chain (SKL-006)

**Files:**
- Modify: `commands/mi-plan-implementation.md` Step 1, Step 3.5 (the `## Likely-relevant skills & rules` bullet), Step 4a (primer message block), Step 4b (direct mode list)
- Modify: `templates/primer.md.tmpl` (`## Likely-relevant skills & rules` section, line ~34)
- Modify: `tests/auto-mode/fixtures/prompts-off/primer-4a.txt`
- **Do not modify** Step 2.

**Interfaces:**
- Consumes: `skills.sh suggestions`, `skills.sh brief`.
- Produces: primer sections `## Skills for this work (from config.md)` and `## Skills for reviewing this work` (exact headings from `brief`). Tasks 8 and 9 rely on these headings.

- [ ] **Step 1: Step 1 check.** At the end of Step 1, add:

````markdown
**Pending catalog suggestions.** Skipped on stage-3 re-entry (`current-stage == 3`). Otherwise:

```bash
if [[ "$current_stage" != "3" && -n "$("$CLAUDE_PLUGIN_ROOT/scripts/skills.sh" suggestions "$active_feature")" ]]; then
  echo "Catalog skills are still waiting to be installed — run /mi-continue to finish the stage-2 gate first." >&2
  exit 1
fi
```

A missing `## Catalog suggestions` section (pre-1.11.0 `config.md`) counts as empty.
````

- [ ] **Step 2: Step 3.5.** Replace the whole `## Likely-relevant skills & rules` bullet (including the "Read from `config.md` only" paragraph and the ≤ 5 budget paragraph) with:

````markdown
- **Skills** — replace the template's skills placeholder (the line beginning `<!-- skills:brief`) with the two `brief` blocks, verbatim and in this order; each brings its own heading, and an empty one adds nothing:

  ```bash
  skills_block="$("$CLAUDE_PLUGIN_ROOT/scripts/skills.sh" brief "$active_feature" implement)"
  review_block="$("$CLAUDE_PLUGIN_ROOT/scripts/skills.sh" brief "$active_feature" review)"
  ```

  Write `$skills_block`, a blank line, then `$review_block` in place of the placeholder line; when both are empty, delete the placeholder line. Do not list skills any other way — `config.md`'s `## Load on demand` stays reachable through the on-demand files.
````

- [ ] **Step 3: Primer template.** In `templates/primer.md.tmpl` replace the `## Likely-relevant skills & rules` heading and its comment with the single line:

```markdown
<!-- skills:brief — replaced at stage 3 by `skills.sh brief <feature> implement` and `… review` (each brings its own heading); removed when both are empty. -->
```

Then confirm `blueprints.sh check-current --require-primer` does not require the old heading: `grep -n 'Likely-relevant' scripts/*.sh schemas/* 2>/dev/null` → no hits (if a hit exists, report it rather than editing the validator).

- [ ] **Step 4: Step 4a paragraph.** Inside the Step 4a message code block, after the final paragraph ("Proceed with your normal brainstorming flow: … after your chain finishes."), add a blank line and:

```
**Skills.** primer.md's `## Skills for this work (from config.md)` and `## Skills for reviewing this work` sections list the skills chosen for this feature at stage 2 (either may be absent). Load the relevant ones with the `Skill` tool before proposing the design, and list them in the spec. In the plan, every task an entry covers carries `**Skills:** <name> (load: Skill <name> or Read <path>)` for its implementer and `**Review skills:** <name> (load: Skill <name> or Read <path>)` for its reviewer — a task brief passes only the task's own section, so these lines are how skills reach those sub-agents. Paste the primer's `## Skills for reviewing this work` section into the final whole-branch reviewer and re-review dispatches, and its `## Skills for this work (from config.md)` section into the fix dispatch.
```

Append the same paragraph (preceded by one blank line) to `tests/auto-mode/fixtures/prompts-off/primer-4a.txt`. Also update the code-block line "Compact snapshot of active scope, goals, journal context, and likely-relevant skills/rules." to "… journal context, and the skills chosen for this feature." **in both the command and the fixture**.

- [ ] **Step 5: Step 4b load step.** After item 1 ("Read `primer.md`"), insert item 1.5: `**Load the skills** in \`## Skills for this work (from config.md)\` before editing the files they cover.`

- [ ] **Step 6: Hand-run Step 3.5 against fixtures.** In a sandbox data root with feature `feat`, put `tests/skills/fixtures/brief-config.md` as `config.md`, render a primer from `templates/primer.md.tmpl` (`frontmatter.sh init primer …` as in Step 3.5), apply the replacement, and check: both headings present once each; then repeat with `old-config.md` → neither heading, no placeholder line left. Run `blueprints.sh check-current --require-primer feat` (with requirements.md/config.md/diagrams present — copy them from `tests/` fixtures or create minimal ones per `scripts/blueprints.sh` usage) → exit 0. If building a full current/ tree is impractical, at least confirm the primer validates: `scripts/frontmatter.sh validate <primer> primer`.

- [ ] **Step 7: Verify.** `env -u CLAUDE_PLUGIN_ROOT bash tests/auto-mode/run.sh` → all pass (including `off: primer-4a prompt kept verbatim`).

- [ ] **Step 8: Commit.**

```bash
git add commands/mi-plan-implementation.md templates/primer.md.tmpl tests/auto-mode/fixtures/prompts-off/primer-4a.txt
git commit -m "feat(stage-3): hand stage-2 skills to the primer, chain and direct mode (SKL-006)"
```

---

### Task 7: Resume Handler skills report line (SKL-007)

**Files:**
- Modify: `commands/mi-continue.md` Resume Step 7 (after `advance-to 3 5`, before the two hand-off blockquotes)

**Interfaces:**
- Consumes: `plan_candidates` from Resume Step 2.5; `skills.sh entries`.

- [ ] **Step 1: Add the block** right after the `skipped=…` line in Resume Step 7, before "**When `skipped=false` …**":

````markdown
**Skills report (print before the hand-off; never a prompt).** Silent when no plan was found (direct mode) or config lists no skills of either tag:

```bash
base_commit="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get base-commit)"
plan_candidates="$(
  {
    git log --diff-filter=AM --name-only --format= "$base_commit..HEAD" -- 'docs/superpowers/plans/*.md' 2>/dev/null
    git status --porcelain -- docs/superpowers/plans/ 2>/dev/null | sed -E 's/^.. //; s/^.*-> //' | grep '\.md$' || true
  } | sort -u
)"
has_impl="$("$CLAUDE_PLUGIN_ROOT/scripts/skills.sh" entries "$active_feature" implement)"
has_rev="$("$CLAUDE_PLUGIN_ROOT/scripts/skills.sh" entries "$active_feature" review)"
if [[ -n "$plan_candidates" && ( -n "$has_impl" || -n "$has_rev" ) ]]; then
  printf '%s\n' "$plan_candidates" | python3 -c '
import re, sys
total = no_skill = no_review = 0
for path in filter(None, sys.stdin.read().split("\n")):
    try:
        text = open(path).read()
    except OSError:
        continue
    for task in re.split(r"(?m)^(?=### Task \d+)", text)[1:]:
        total += 1
        no_skill += "**Skills:**" not in task
        no_review += "**Review skills:**" not in task
if total:
    print("skills: %d of %d plan tasks name no skill, %d of %d name no review skill"
          % (no_skill, total, no_review, total))
'
fi
```

(The block recomputes `plan_candidates` because Resume Step 2.5 runs in an earlier Bash call.) The line prints outside the blockquotes below and does not move their auto-answer lines.
````

- [ ] **Step 2: Hand-run** in a sandbox repo: commit a plan file `docs/superpowers/plans/p.md` with three `### Task N:` sections (one with both lines, one with `**Skills:**` only, one with neither) after a recorded base commit, with a `brief-config.md` feature config and `MI_DATA_ROOT` set; set `base_commit` manually instead of `progress.sh get`. Expected: `skills: 1 of 3 plan tasks name no skill, 2 of 3 name no review skill`.

- [ ] **Step 3: Hand-run the silent cases:** (a) no plan file → nothing; (b) `old-config.md` → nothing; (c) a plan without `### Task` headings → nothing (no `0 of 0`).

- [ ] **Step 4: Verify** `env -u CLAUDE_PLUGIN_ROOT bash tests/auto-mode/run.sh` → all pass (the `manual-test-offer*` fixtures must still match byte for byte).

- [ ] **Step 5: Commit.**

```bash
git add commands/mi-continue.md
git commit -m "feat(resume): report plan tasks that name no skill in the stage-5 hand-off (SKL-007)"
```

---

### Task 8: Stage 6 and standalone consumers (SKL-008)

**Files:**
- Modify: `commands/mi-review.md` Step 3a.2.4 spawn prompt (above "**Open findings to address this iteration:**", line ~382) and Step 3b (direct mode)
- Modify: `commands/mi-sidequest.md` Step 5 spawn prompt (line ~113)
- Modify: `agents/sidequest-reader.md`, `agents/sidequest-writer.md`, `agents/pr-review-fixer.md`, `agents/review-comment-analyst.md` (frontmatter `tools:` + a short "Skills" paragraph)
- Modify: `commands/mi-continue.md` PR-Review Apply Step 5 spawn prompt; `commands/mi-analyze-review.md` Step 6 spawn prompt
- Modify: `docs/millwright-inspector-project.md` agent tool table

**Interfaces:**
- Consumes: `skills.sh brief`, `skills.sh inventory --installed`; `progress.sh get-active`, `progress.sh get branch`.

- [ ] **Step 1: review-iteration-runner.** In `commands/mi-review.md` Step 3a.2.4, before composing the prompt, add:

```bash
skills_block="$("$CLAUDE_PLUGIN_ROOT/scripts/skills.sh" brief "$active_feature" implement)"
```

and in the prompt template, directly above `**Open findings to address this iteration:**`, insert `<skills_block — omit this line and the blank line after it when empty>` followed by a blank line. In Step 3b (direct mode) add as the first instruction: `Load the skills in \`skills.sh brief "$active_feature" implement\` before editing the files they cover (nothing to load when it prints nothing).`

- [ ] **Step 2: sidequest.** In `commands/mi-sidequest.md` Step 5, before the spawn:

```bash
active="$("$CLAUDE_PLUGIN_ROOT/scripts/progress.sh" get-active 2>/dev/null || echo null)"
skills_block=""
if [[ -n "$active" && "$active" != "null" ]]; then
  tag=review; [[ "$write_mode" == "write" ]] && tag=implement
  skills_block="$("$CLAUDE_PLUGIN_ROOT/scripts/skills.sh" brief "$active" "$tag")"
fi
```

(Use the command's existing variable for the write mode — check Step 1/4 for its exact name and value — and the existing active-feature variable from Step 2 if there is one.) Insert `<skills_block — omitted when empty>` into the prompt after the `Write mode:` line. `Write mode: read-only` stays the authoritative constraint for the reader.

- [ ] **Step 3: Agent files.** Add `Skill` to the `tools:` frontmatter of `sidequest-reader`, `sidequest-writer`, `pr-review-fixer`, `review-comment-analyst`. Add to each body:

```markdown
**Skills.** When the spawn prompt carries a `## Skills for this work (from config.md)` or `## Skills for reviewing this work` block, load the listed skills with the `Skill` tool (or Read the file at the listed path) before acting on the files they cover. Loading a skill never widens what you may change.
```

For `sidequest-reader`, append: "You stay read-only: `Write mode: read-only` in the prompt overrides anything a skill suggests."

- [ ] **Step 4: PR agents.** In both spawn sites (`commands/mi-continue.md` Apply Step 5 for `pr-review-fixer` with tag `implement`; `commands/mi-analyze-review.md` Step 6 for `review-comment-analyst` with tag `review`), add before the spawn:

````markdown
**Skills block.** When a feature is active and the PR's head branch equals `progress.md`'s `branch`, use the feature's selection; otherwise pick from what is installed:

```bash
active="$("$CLAUDE_PLUGIN_ROOT/scripts/progress.sh" get-active 2>/dev/null || echo null)"
pr_head="$(gh pr view "$pr_number" --repo "$repo" --json headRefName -q .headRefName 2>/dev/null || echo '')"
feat_branch=""
[[ -n "$active" && "$active" != "null" ]] && feat_branch="$("$CLAUDE_PLUGIN_ROOT/scripts/progress.sh" get branch 2>/dev/null || echo '')"
if [[ -n "$feat_branch" && "$pr_head" == "$feat_branch" ]]; then
  skills_block="$("$CLAUDE_PLUGIN_ROOT/scripts/skills.sh" brief "$active" <tag>)"
else
  skills_block=""   # PR-based pick below
fi
```

PR-based pick (when `skills_block` is empty and the branch did not match): run `"$CLAUDE_PLUGIN_ROOT/scripts/skills.sh" inventory --installed`, pick at most 5 rows whose description fits the PR's changed files (`gh pr diff "$pr_number" --repo "$repo" --name-only`), and render them in the `brief` format — heading `## Skills for this work (from config.md)` (fixer) or `## Skills for reviewing this work` (analyst), the load-instruction line, then `- <name> — <why it fits> — <absolute path>` (make project-relative paths absolute with the repo root). Nothing relevant → leave the block out.
````

Use each site's existing variable names for the PR number and repo (read the step first). Insert `<skills_block — omitted when empty>` into each spawn prompt before its contract/return-shape lines.

- [ ] **Step 5: Hand-run the empty paths.** With no active feature (sandbox data root without `progress.md`), the `mi-sidequest` block yields `skills_block=""` and no error; `skills.sh brief nope review` prints nothing. Confirm no spawn template change adds text when the block is empty (read each edited template once).

- [ ] **Step 6: Docs table.** In `docs/millwright-inspector-project.md`'s agent tool table, add `Skill` for the four agents.

- [ ] **Step 7: Verify.** `env -u CLAUDE_PLUGIN_ROOT bash tests/auto-mode/run.sh && env -u CLAUDE_PLUGIN_ROOT bash tests/lint/run.sh` → pass.

- [ ] **Step 8: Commit.**

```bash
git add commands/mi-review.md commands/mi-sidequest.md commands/mi-continue.md commands/mi-analyze-review.md agents/sidequest-reader.md agents/sidequest-writer.md agents/pr-review-fixer.md agents/review-comment-analyst.md docs/millwright-inspector-project.md
git commit -m "feat(skills): pass skill briefs to stage-6, sidequest and PR sub-agents (SKL-008)"
```

---

### Task 9: `/mi-update-blueprint` keeps the selection (SKL-009)

**Files:**
- Modify: `commands/mi-update-blueprint.md` `#### Step 4c — Write the new config.md` (line ~382–407) and `#### Step 4f — Regenerate primer.md` (line ~483)

- [ ] **Step 1: Step 4c.** Replace the instruction to fill the auto section from `.claude/skills/` + `.claude/rules/` (line ~397, and the relevance rules copied with it) with:

````markdown
Copy the previous `config.md`'s auto block **verbatim** — from the line beginning `<!-- auto:start` through `<!-- auto:end -->` — over the template's empty block. No reselection, no catalog suggestions, no installs:

```bash
prev_cfg="$hist/v${new_v}/config.md"   # the just-rotated copy
new_cfg="$data_root/workflow-stream/$active_feature/blueprints/current/config.md"
python3 - "$prev_cfg" "$new_cfg" <<'PYEOF'
import sys
def span(lines):
    s = next((i for i, l in enumerate(lines) if l.lstrip().startswith("<!-- auto:start")), None)
    e = next((i for i, l in enumerate(lines) if s is not None and i > s and l.strip() == "<!-- auto:end -->"), None)
    return s, e
prev = open(sys.argv[1]).read().split("\n")
new = open(sys.argv[2]).read().split("\n")
ps, pe = span(prev)
ns, ne = span(new)
if ps is None or pe is None or ns is None or ne is None:
    sys.exit(0)  # hand-edited previous block: keep the template's empty block
open(sys.argv[2], "w").write("\n".join(new[:ns] + prev[ps:pe + 1] + new[ne + 1:]))
PYEOF
```
````

Use the step's existing variable names for the rotated history folder (read Steps 2–4a first; the variable may not be `$hist/v${new_v}`). The copy must run before Step 4d (`preserve-inspector-sections`).

- [ ] **Step 2: Step 4f.** Replace its skills instruction with the same two-block rendering as `/mi-plan-implementation` Step 3.5 (`skills.sh brief … implement`, blank line, `… review`, replacing the line beginning `<!-- skills:brief`; delete the placeholder when both are empty). Keep the `## Decisions` fold-in unchanged.

- [ ] **Step 3: Hand-run 4c** with `prev_cfg=tests/skills/fixtures/gate-after-stop.md` and `new_cfg=<sandbox copy of templates/config.md.tmpl rendered or copied raw>` → the auto block of `new_cfg` equals that of `prev_cfg` byte for byte (`diff <(sed -n '/auto:start/,/auto:end/p' A) <(sed -n '/auto:start/,/auto:end/p' B)` empty). Then with a `prev_cfg` whose markers were deleted → `new_cfg` unchanged.

- [ ] **Step 4: Commit.**

```bash
git add commands/mi-update-blueprint.md
git commit -m "feat(update-blueprint): copy the stage-2 skill selection verbatim on refresh (SKL-009)"
```

---

### Task 10: `catalog` as an optional dependency (SKL-010)

**Files:**
- Modify: `scripts/doctor.sh` (add `hints_catalog()` next to `hints_claude()` ~line 324; add a `check_cli catalog false …` in the OPTIONAL block near `check_cli gh false` ~line 355)
- Modify: `commands/mi-doctor.md`, `commands/mi-init.md` (where optional deps are listed)

- [ ] **Step 1: Find the setup command.** `curl -fsSL https://raw.githubusercontent.com/Eminakkoc/skills/main/README.md | grep -n -i -A3 'setup\|install'` — take the one-line setup command (expected shape: a `curl … | bash -s setup` or `bash <(curl …) setup` line). If unreachable, use `see https://github.com/Eminakkoc/skills#setup` as the hint.

- [ ] **Step 2: Add the hint and the check:**

```bash
hints_catalog() {
  cat <<'JSON'
{
  "any": "<the one-line setup command from Step 1>",
  "note": "optional — lets stage 2 suggest and install catalog skills (github.com/Eminakkoc/skills). Without it, catalog suggestions are skipped."
}
JSON
}
```

and in the optional section: `check_cli catalog false "$(hints_catalog)"`.

- [ ] **Step 3: Verify.** `PATH=/usr/bin:/bin:$(dirname "$(command -v python3)"):$(dirname "$(command -v yq)") bash scripts/doctor.sh --preflight; echo $?` → `0` with no `catalog` failure; the full `bash scripts/doctor.sh` output lists `catalog` as missing optional with the hint. Check `commands/mi-init.md` batches only required deps (no change needed beyond mentioning `catalog` as optional).

- [ ] **Step 4: Commit.**

```bash
git add scripts/doctor.sh commands/mi-doctor.md commands/mi-init.md
git commit -m "feat(doctor): report the catalog CLI as an optional dependency (SKL-010)"
```

---

### Task 11: Drop "Implementation rules to follow" from the export bundle (SKL-011)

**Files:**
- Modify: `scripts/bundle.sh` (delete `def emit_implementation_rules` at ~line 399–418 and its call at ~line 965)
- Modify: `docs/bundle/plan.md` (§5.5 at ~line 329–340; references at ~1253, ~1307, ~1467)
- Modify: the six `tests/bundle/fixtures/*/expected.md` (stage3-midcycle-scope, stage3-typical, stage4-stale-change, stage5-populated-review, stage6-freeform-only, stage6-structured-findings)

- [ ] **Step 1: Delete the function and its call** in `scripts/bundle.sh`. Leave neighbouring section-number comments as they are.

- [ ] **Step 2: Update fixtures.** In each of the six `expected.md`, delete the `## Implementation rules to follow` heading, its body, and the blank line that separated it from the next section, so the surrounding sections join exactly as the script now emits them. Run `env -u CLAUDE_PLUGIN_ROOT bash tests/bundle/run.sh` and fix whitespace until it passes. `git diff --stat tests/bundle` must list only those six files.

- [ ] **Step 3: Update `docs/bundle/plan.md`.** Delete §5.5; in the emptiness/acceptance references (lines ~1253, ~1307) remove the rules mentions; in the risk table row (~1467) add "(removed in 1.11.0: rules load through Claude Code itself)". Do not renumber sections.

- [ ] **Step 4: Commit.**

```bash
git add scripts/bundle.sh docs/bundle/plan.md tests/bundle/fixtures
git commit -m "feat(bundle): drop the implementation-rules section from exported bundles (SKL-011)"
```

---

### Task 12: Test gate and end-to-end checklist (SKL-012)

**Files:**
- Create: `tests/skills/e2e-checklist.md`
- Modify (only if needed): `tests/auto-mode/fixtures/never-auto-expected.txt`

- [ ] **Step 1: Write the checklist** `tests/skills/e2e-checklist.md`:

```markdown
# skills-across-workflow — manual end-to-end checklist (mi-sample)

Run one full cycle in the mi-sample project with the 1.11.0 plugin. Tick each line.

- [ ] Journal names `web-images` (catalog skill) and an MCP server for one feature.
- [ ] Stage 1: `summary.md` has `## Requested skills` with a `web-images` line and the MCP server line.
- [ ] Stage 2: `config.md` has `web-images` under `## Catalog suggestions` (`requested: journal`) and at least one `requested: no` suggestion; no `## Rules`.
- [ ] Stage-2 hand-off lists the MCP server as "not a skill — set it up yourself before /mi-continue".
- [ ] Approve gate with auto mode on and the feature branch missing: `auto.sh create-branch` creates it while `.claude/catalog.lock.json` is tracked.
- [ ] Decline one `requested: no` suggestion: it disappears from `config.md`.
- [ ] An unrelated file staged before `/mi-continue` is still staged afterwards and absent from the `chore(skills): install … from catalog` commit.
- [ ] The install commit is older than `progress.md`'s `base-commit` (`git merge-base --is-ancestor <install-sha> <base-commit>`).
- [ ] `primer.md` has `## Skills for this work (from config.md)` (and the review section when review skills exist).
- [ ] The plan's tasks carry `**Skills:**` / `**Review skills:**` lines; the stage-5 hand-off prints the `skills: N of M …` line.
- [ ] `/mi-update-blueprint "scope shifted"` leaves the auto block byte-identical.
- [ ] `/mi-analyze-review` on a PR from the feature branch uses the feature's review skills; on a PR from another branch it uses the inventory-based pick.
```

- [ ] **Step 2: Run every suite.**

```bash
for s in skills auto-mode bundle lint; do env -u CLAUDE_PLUGIN_ROOT bash "tests/$s/run.sh" >/tmp/mi-$s.log 2>&1; echo "$s: $?"; done
env -u CLAUDE_PLUGIN_ROOT bash tests/blueprint-review/run.sh >/tmp/mi-br.log 2>&1; echo "blueprint-review: $?"
```

Expected: every line ends in `0`. On a never-auto audit failure caused by intended new prose that must contain an audit phrase, regenerate the expected list with the audit's own command (see `tests/auto-mode/run.sh` Task 12 block) and commit the fixture with a message naming the phrase; otherwise reword the prose.

- [ ] **Step 3: Commit.**

```bash
git add tests/skills/e2e-checklist.md tests/auto-mode/fixtures 2>/dev/null
git commit -m "test(skills): end-to-end checklist for the skills cycle (SKL-012)"
```

---

### Task 13: Release 1.11.0 (SKL-013)

**Files:**
- Modify: `.claude-plugin/plugin.json` (`"version"`)
- Modify: `CHANGELOG.md` (new top entry)

- [ ] **Step 1: Bump** `"version": "1.10.0"` → `"1.11.0"` in `.claude-plugin/plugin.json`. Leave `.claude-plugin/marketplace.json` alone.

- [ ] **Step 2: CHANGELOG entry** above the 1.10.0 entry, matching the existing heading style (`## 1.10.0 — …`):

```markdown
## 1.11.0 — Skills across the workflow

**Breaking — finish or abort (`/mi-abort-workflow`) any active workflow before upgrading.** `config.md` entries written before 1.11.0 have no `stages:`/`skill:` fields, so `skills.sh brief` renders nothing for them, `/mi-update-blueprint` copies the old block as is, and ongoing workflows are not migrated.

- New `scripts/skills.sh` — the one reader of the skill selection: `inventory`, `lookup`, `brief`, `entries`, `suggestions`, `catalog-files`, `apply-installs`.
- Stage 1: `summary.md` gains `## Requested skills`; the journal digesters return a `## Named resources` section.
- Stage 2: `config.md`'s auto block is now `## Skills`, `## Load on demand`, `## Catalog suggestions`, with `stages:`/`skill:`/`path:` fields; `## Rules` is gone (rules load through Claude Code itself). The hand-off reports skills to install, suggestions to confirm, and things to set up yourself.
- Stage-2 approve gate: new Approve Step 1.5 resolves the feature branch (moved here from stage 3, which now only re-validates), installs the agreed catalog skills, and commits them as `chore(skills): install … from catalog` before `base-commit`.
- Stage 3+: the primer, the brainstorming chain (per-task `**Skills:**` / `**Review skills:**` lines), direct mode, the stage-6 runner, sidequests and the PR agents all receive the selected skills; `sidequest-reader`, `sidequest-writer`, `pr-review-fixer` and `review-comment-analyst` gain the `Skill` tool.
- `/mi-export-bundle` no longer emits "Implementation rules to follow".
- `/mi-doctor` reports the `catalog` CLI as optional. Bundle expansion needs a `catalog` with `list --json --bundles` (skills repo `b6b257c` or later).
```

- [ ] **Step 3: Verify.** `python3 -c "import json;print(json.load(open('.claude-plugin/plugin.json'))['version'])"` → `1.11.0`; `grep -n '^## 1\.9\.0 — Auto mode' CHANGELOG.md` still matches; `env -u CLAUDE_PLUGIN_ROOT bash tests/auto-mode/run.sh` passes.

- [ ] **Step 4: Commit.**

```bash
git add .claude-plugin/plugin.json CHANGELOG.md
git commit -m "chore(release): 1.11.0 — skills across the workflow (SKL-013)"
```
