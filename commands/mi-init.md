---
description: First-run wizard — checks dependencies, offers a single y/n to install everything missing, and scaffolds the workflow data folders. Simpler than /mi-doctor.
---

# mi-init

Run this once per workspace when setting up the plugin for the first time. Reuses the same detection backend as `/mi-doctor`, but exposes a one-prompt interaction instead of per-dep prompts.

What it does:

1. Checks every dependency (CLI tools, Python modules, MCP server, skills).
2. If anything is missing, asks **one** y/n to install all Bash-runnable deps in a single batch.
3. For plugin-kind deps that can't be auto-installed (e.g. superpowers), prints the slash commands and asks the inspector to run them, then re-run `/mi-init`.
4. Scaffolds the workflow data folders (`journal/`, `quest/`, `workflow-stream/`) under the data root if absent, and seeds an empty `quest/active.md` pointer with `status: none` so future cycles can attach without scaffolding races.
5. Prints the exact next command to run.

For per-dep prompts, `select` mode, detailed JSON output, and sudo handling — use `/mi-doctor` instead.

## Execution

### Step 1 — Run the detection script

```bash
$CLAUDE_PLUGIN_ROOT/scripts/doctor.sh --format=json
```

Parse the JSON. Collect all checks where `required == true` and `present == false` into two buckets:

- **Bash-runnable** — `kind ∈ {cli, pymod}`.
- **Plugin-kind** — `kind == "plugin"` (slash-command install only).

Also note any checks where `kind == "env"` (e.g. `git-repo` not initialized) — these need a one-line instruction, not an automated install.

### Step 2 — One-line status summary

Print a short, condensed status (not the full per-dep table):

```
Checking dependencies (os=darwin)...

  ✓ present:  git, python3, plantuml-mcp-server, git-repo, + 5 skills
  ✗ missing:  yq, pyyaml  (Bash-installable)
              superpowers plugin (5 skills — slash command install)
```

If `status == "ok"`, skip to Step 5.

### Step 3 — Single-prompt install for Bash-runnable deps

If any Bash-runnable deps are missing, show the batch and ask once:

```
Install these now?

  brew install yq
  python3 -m pip install --user pyyaml

Proceed? (y/n)
```

- **`y`** — run every command in the batch via `Bash`, in order. Print `✓` or `✗` per command inline; continue on failure (don't abort the batch).
- **`n`** — skip; print "Install manually, then re-run /mi-init." and exit.

If a command needs `sudo`, call it out with a single extra confirmation before running:

> "`sudo apt install yq` needs your password. Proceed? (y/n)"

When the batch finishes, re-run `doctor.sh --format=json` to refresh state before Step 4.

### Step 4 — Plugin-kind deps (can't auto-install)

If any plugin-kind deps are still missing, print the slash commands for the inspector to run themselves, then stop:

```
Remaining setup — please run these in this Claude Code session:

  /plugin marketplace add obra/superpowers
  /plugin install superpowers@obra-superpowers
  /reload-plugins

Then re-run /mi-init to finish scaffolding.
```

Do not proceed to Step 5 with plugin deps still missing — the workflow's stage 3 needs those skills.

### Step 5 — Scaffold the data folders

Resolve the data root via the canonical helper (`scripts/data-root.sh`), which honors `$MI_DATA_ROOT`, then `$CLAUDE_PLUGIN_USER_CONFIG_data_root`, then defaults to `$PWD/millwright-inspector`:

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
mkdir -p "$data_root/journal" "$data_root/quest" "$data_root/workflow-stream"

# Seed the empty active-quest pointer (idempotent — won't overwrite an
# existing pointer or any per-cycle subfolder).
$CLAUDE_PLUGIN_ROOT/scripts/quest.sh init-pointer
```

If the folder already exists with content, do **not** touch anything inside it — just report "already initialized". `quest.sh init-pointer` is idempotent: it only writes `quest/active.md` when that file is absent, so existing per-cycle subfolders and an in-flight active pointer are preserved untouched.

### Step 5.5 — Offer to wire the status line

Ask the inspector once whether to wire the bottom-bar status line:

```
Wire the mi-workflow status line now? (y/n)
  Shows: mi-workflow · <feature> · Stage <N> · <stage-name>
  Refreshes automatically — no hook, no token tracking.
  Writes a wrapper to .claude/mi-stage-info-bar.sh and a statusLine entry
  to .claude/settings.local.json (machine-local; not committed).
  Skipped if you say n; you can run /mi-init-status-bar anytime later.
```

- **`y`** — invoke `/mi-init-status-bar` (no flags — uses the machine-local default). All wrapper-resolution and overwrite-on-conflict prompting lives inside that command; do not duplicate it here. After it returns, continue to Step 6.
- **`n`** — skip silently. The Step 6 footer mentions `/mi-init-status-bar` so re-running is discoverable.

This prompt is intentionally separate from the Step 3 dependency batch — `statusLine` wiring is per-machine config, not a dependency, and mixing it into the same y/n would conflate "install software" with "edit my settings".

### Step 6 — Report and hand off

Print the ready-state followed by a full walkthrough of what the inspector does next — including **when `/mi-continue` is typed** (twice per feature). Keep the output as-is; this is the canonical handoff text for first-time users:

```
✓ Ready at <data_root>/
    journal/          (drop notes, meeting transcripts, spec docs here as .md or .txt — .md files need `contributors:` and `date:` frontmatter; .txt files have no metadata requirement. For PDFs, Word/PowerPoint/Excel docs, or images, run /mi-ingest first to produce sibling .md files — requires docling.)
    quest/            (per-cycle subfolders created by /mi-run; the top-level active.md tracks which one is currently active. Historical subfolders are preserved across cycles as a permanent task archive.)
    workflow-stream/  (populated during workflow execution)

Next steps — what you do to start and drive the workflow:

  1. Populate <data_root>/journal/ with the resources you want the workflow
     to use (meeting transcripts, notes, specs). Both .md and .txt files
     are accepted — pick whichever format fits the source material
     (transcripts are usually .txt, notes/specs usually .md). Group them
     into sub-folders per topic, e.g.
       <data_root>/journal/pricing-requirements-meeting/
     .md files need YAML frontmatter with `contributors:` and `date:`.
     .txt files have no metadata requirement.

  2. Start the workflow. Pass the journal sub-folder names you want this
     cycle to cover (one or more):
       /mi-run <folder1> [<folder2> ...]

     This creates a per-cycle subfolder under quest/ (named after the
     journal folders + today's date — e.g. quest/2026-04-27-pricing/) and
     generates todo-list.md, summary.md, and progress.md inside it. The
     top-level quest/active.md pointer file is updated to reference the
     new cycle. Older cycle subfolders are kept as-is (permanent record).
     Branch selection is NOT required at this stage — you'll declare the
     feature branch per-feature inside `blueprints/current/config.md`'s
     `## GIT BRANCH` section at stage 2.

  3. Open the new cycle's todo-list.md (the path is printed by /mi-run; you can
     also resolve it with `bash $CLAUDE_PLUGIN_ROOT/scripts/quest.sh dir`).
     For each item you want implemented this cycle:
       a. Put an `x` inside its checkbox: `- [ ] TODO — ...` → `- [x] TODO — ...`.
       b. Add the assignee — your inspector name in parentheses between the
          checkbox and the state word:
            `- [x] (emin) TODO — PAY-001: capture webhook`
     Leave items you don't want as `[ ] TODO`. You can pre-assign without
     selecting — `[ ] (emin) TODO — ...` is fine too.
     You do NOT need to rewrite the state word — I'll promote your selections
     to PENDING automatically (via `todo.sh pend-selected`) when you type
     `/mi-continue`. **Required:** every `[x]` line must have an `(assignee)`
     tag; I'll refuse to promote and ask you to add names if any are missing.
     Save, then type:
       /mi-continue
     I'll promote your selections, analyze cross-feature dependencies, and
     propose a priority order. Type `/mi-continue` again to accept (or paste
     a custom order first, then `/mi-continue`).

  4. I'll then auto-generate the blueprint (requirements + config + diagrams)
     for the first feature. Review those files — including `config.md`'s
     `## GIT BRANCH` section, which I'll pre-fill with your current HEAD
     if you're on a non-trunk branch (otherwise leave it blank and I'll
     ask you at stage 3). One branch per feature — if you list multiple
     I'll warn you and ask you to pick one. When ready, type:
       /mi-continue
     The Approve Handler validates the blueprint files and auto-launches
     `/mi-plan-implementation`, which asks you to pick a planning-mode:
       - `brainstorming` — launches the brainstorming chain in an isolated
         session; drive it normally.
       - `direct` — I implement in the main session using `primer.md` as the
         required first read; you review the work inline.

  5. When the chain finishes (or I finish direct implementation) and
     commits are on the branch, type:
       /mi-continue

     I'll detect the commits, generate implementation diagrams
     (with pre-existing system shaded as context), and hand the
     implementation off to you for review.

  6. I'll then hand you implementation/inspector-review.md. Add findings
     if you have any (plain sentences are fine — I canonicalize them
     into structured `### IR-NNN` blocks before the review session
     starts), or leave it empty to approve. When done, type:
       /mi-continue       (second time for this feature)

     If the file is empty, I auto-finalize via /mi-complete-workflow and
     auto-advance to the next queued feature (loop back to step 4). If
     you added findings, I'll ask you to pick a review-mode (`brainstorming`
     or `direct`) and run the fix-and-approval loop. End the session by
     typing `approve`, then `/mi-continue` (third time) to finalize. I'll
     offer a diagram refresh first if review-loop commits were created.

Summary of what YOU type per feature:
  /mi-run <folder1> [<folder2> ...]       (once, at the start of a cycle)
  /mi-continue                            (×2 at stage 1.5: after marking, after order proposal)
  /mi-continue                            (×1 at stage 2 after blueprint review)
  /mi-continue                            (×2 at stages 4–5 after implementation;
                                           ×3 if you added review findings)
  + short text replies: planning-mode (`brainstorming`/`direct`),
                        review-mode if findings (`brainstorming`/`direct`),
                        `approve` to end review session, optional diagram-refresh y/n
  + fill `## GIT BRANCH` in config.md per feature (or I'll prompt you)
  + optional findings in implementation/inspector-review.md
    (plain sentences are fine — I canonicalize them)

Everything else — mi-apply-impact, mi-plan-implementation, mi-review,
mi-draw-diagrams, mi-complete-workflow — fires automatically.

Optional companions (detected but never required):
  - rtk               (filters verbose shell output to save tokens in reviews + chain)
  - docling           (enables /mi-ingest — convert PDF/DOCX/PPTX/XLSX/images
                       into sibling .md so /mi-run can consume them. Skip if
                       your journal will only ever contain .md and .txt.)
If any are missing, see /mi-doctor for install hints. The workflow
runs identically without them.

Status line (opt-in, per-machine):
  /mi-init-status-bar     wire a one-line workflow indicator into Claude Code's
                          bottom bar. Run any time on any machine — the
                          /mi-init wizard offers to do this automatically.
```

## Notes

- Idempotent — safe to run any time.
- Does not replace `/mi-doctor`. Doctor remains the detailed diagnostic command and is auto-invoked by `/mi-run`'s preflight.
- `/mi-init` only creates folders; it never writes files inside the data root. Journal content is always inspector-authored.
