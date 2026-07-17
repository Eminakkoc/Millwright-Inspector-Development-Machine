---
description: Generate three quest cycle files (todo-list.md, summary.md, progress.md) inside a fresh per-cycle subfolder under quest/, from a selected list of journal folders. Stage 1 of the mi-workflow. The fourth cycle file, queue-rationale.md, is written later by /mi-continue at stage 1.5.
argument-hint: "<journal-folder> [<journal-folder>...] [--archive-active]"
---

# mi-run

**Runtime bootstrap.** Every `$CLAUDE_PLUGIN_ROOT` reference in this command's Bash blocks assumes a resolved plugin root; Claude Code does not inject the env var into Bash subshells. If it is empty in your shell, apply the canonical resolver (`docs/millwright-inspector-project.md` §8.14; reference implementation: `mi-continue.md` Step 1a) before the first Bash block: (1) inherited env var when it points at a working install, (2) `$PWD` when it is this plugin's source repo, (3) the `installPath` from `~/.claude/plugins/installed_plugins.json` — then export it, persist it to the per-cwd tempfile, and prepend the recovery one-liner to every subsequent Bash block. Refuse with an environmental diagnostic if none resolve.

**Stage 1 launcher.** Reads a caller-specified list of `journal/` sub-folders (topics to base this workflow on), creates a per-cycle subfolder under `quest/`, generates **three** of the cycle's files inside it (`todo-list.md`, `summary.md`, `progress.md`), and points `quest/active.md` at the new subfolder. Then prompts the inspector to mark PENDING items.

**Main-read budget (stage 1).** Allowed in main: journal files (per Step 2.5 size policy — large files and many-small-folders delegated to fresh sub-agents). Forbidden in main: source code. See `docs/millwright-inspector-project.md` § "Main-read budget gates by stage" for the canonical table.

The fourth cycle file, `queue-rationale.md`, is written later by `/mi-continue`'s Pre-flight Step 2B at stage 1.5 — its absence is what the dispatcher in `commands/mi-continue.md` keys on to distinguish "selections still pending promotion" (Step 2A) from "queue-order proposal is awaiting inspector confirmation" (Step 2B). Creating it during `/mi-run` would skip Step 2A entirely.

## Inputs (positional, parsed from `$ARGUMENTS`)

- **Journal folder list** (required, one or more) — each token is the name of a direct child under `millwright-inspector/journal/`. Example: `pricing-requirements-meeting`, `auth-slack-conversation`. Only files inside these folders are read.
- **`--archive-active`** (optional flag) — if a previous quest cycle is still active (queue or in-flight feature, OR queue empty but unmarked `[ ] TODO` items remain), `/mi-run` refuses by default. Pass `--archive-active` to flip the previous cycle's status to `archived` (preserving its subfolder under `quest/<old-slug>/` for historical querying) before opening the new one.

Branch selection is **not** part of stage 1 — the feature branch is declared per-feature in `blueprints/current/config.md`'s `## GIT BRANCH` section at stage 2 and validated at stage 3. Stage 1 is pure journal-to-quest.

## Quest folder layout

The cycle's files live inside a per-cycle subfolder named after a date-prefixed slug derived from the journal folders, e.g. `millwright-inspector/quest/2026-04-27-pricing-meeting+auth-rfc/`. `/mi-run` creates three of them at stage 1 — `todo-list.md`, `summary.md`, and `progress.md`. The fourth, `queue-rationale.md`, is written by `/mi-continue` at stage 1.5 once the inspector confirms the queue order. Subfolders from previous cycles are **never** modified or deleted — they are a permanent task archive that PMs and future inspectors can query. The top-level `quest/active.md` pointer file records which slug is currently active; path-resolution helpers in `scripts/internal/common.sh` read it to map references like "the active todo-list.md" to the right subfolder.

Example invocations:

```
/mi-run pricing-requirements-meeting
/mi-run pricing-requirements-meeting auth-slack-conversation
/mi-run pricing-requirements-meeting --archive-active     # archive previous cycle, start fresh
```

## Execution

Use the workflow data root at `millwright-inspector/` (relative to project root) unless the plugin's `data_root` userConfig overrides it.

### Step 0 — Preflight dependency check

Before anything else, verify required dependencies are present:

```bash
if ! $CLAUDE_PLUGIN_ROOT/scripts/doctor.sh --preflight; then
  echo "Required dependencies missing. Running /mi-doctor to diagnose and install..."
  # Millwright: invoke /mi-doctor inline here, not a separate turn — the inspector
  # just typed /mi-run and expects a seamless flow. Run doctor,
  # negotiate installs, then retry preflight before proceeding.
  exit 1
fi
```

If preflight fails, **invoke `/mi-doctor` immediately** (do not stop and ask the inspector to run it themselves). Follow the `/mi-doctor` command's flow to present missing deps, propose install commands, and run them after approval. Once doctor reports `status: ok`, re-run preflight and continue to Step 1.

### Step 1 — Parse arguments

Tokenize `$ARGUMENTS`. Pull `--archive-active` out as a flag if present; every other token is a journal folder name. Error out if zero folder names were provided:

```
error: no journal folders specified. Usage:
  /mi-run <folder1> [<folder2> ...] [--archive-active]
```

### Step 1.5 — Active-quest pre-check

Before doing any journal scanning or generation, verify there is no quest cycle in flight (or honor `--archive-active` to retire the existing one).

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
if existing_slug="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh current 2>/dev/null)"; then
  if [[ -n "${archive_active:-}" ]]; then
    $CLAUDE_PLUGIN_ROOT/scripts/quest.sh end
    echo "Archived previous cycle: $existing_slug (subfolder preserved under quest/$existing_slug/)"
  else
    cat >&2 <<EOF
error: a quest cycle is already active (slug=$existing_slug). The cycle's subfolder
is at $data_root/quest/$existing_slug/ and contains the in-flight
todo-list.md, summary.md, progress.md (plus queue-rationale.md if stage 1.5 has
already confirmed the queue order).

To finish the current cycle: complete its remaining queued features (or run
/mi-abort-workflow + /mi-complete-workflow as appropriate).

To start a new cycle anyway and preserve the current one as a historical
record, re-run with the --archive-active flag:
  /mi-run <folder1> [<folder2> ...] --archive-active
EOF
    exit 1
  fi
fi
```

### Step 2 — Validate journal folders and read their content

For each folder name in the parsed list, verify `millwright-inspector/journal/<folder>/` exists. If any are missing, error with the list of missing folders and available folders (listing direct children of `journal/`) so the inspector can retype.

Then enumerate `.md` and `.txt` files **only inside the specified folders** (e.g. `millwright-inspector/journal/<folder>/**/*.md` and `.../*.txt`) — not the whole `journal/` tree. Both formats are first-class inputs; use whichever is natural for the resource (meeting transcripts are typically `.txt`, notes and specs typically `.md`).

**Non-text files — per-file ingest decision flow.** Before reading, scan the specified folders for unsupported extensions — `.pdf`, `.docx`, `.pptx`, `.xlsx`, `.html`, `.png`, `.jpg`, `.jpeg`, `.webp`, `.tiff`, `.tif`. **Exclude any `*.images/` subfolder** from this scan — those hold figures that `/mi-ingest` extracted from PDFs on a previous run, and they are already accounted for via their parent document's `.md`. Of the remaining hits, collect any that have **no sibling `.md`** (files where `<stem>.md` exists have already been ingested and are fine). Do not silently skip un-ingested files — the inspector may believe that PDF/DOCX content is feeding the quest when it isn't.

If the un-ingested set is empty, proceed to the next paragraph. Otherwise run the per-file decision flow:

1. **Classify each detected file** to produce a recommendation:

   | Extension | Recommendation | Rationale |
   | --- | --- | --- |
   | `.docx`, `.pptx`, `.xlsx`, `.html` | **docling (required)** | Claude Code's `Read` tool does NOT open these formats. Docling is the only way in. |
   | `.pdf` > 20 pages | **docling (recommended)** | `Read` caps PDFs at 20 pages per call — larger files require chunking. Docling handles any length in one pass. |
   | `.pdf` ≤ 20 pages | **native read (optional)** | `Read` parses short PDFs natively with full fidelity. Docling is optional — pick it if the PDF has complex tables or a multi-column layout. |
   | `.pdf` (page count unknown) | **ask the inspector** | If `pdfinfo` isn't available to check page count, present both options. |
   | `.png`, `.jpg`, `.jpeg`, `.webp`, `.tiff`, `.tif` | **native stub (always)** | Claude is a VLM — it reads images directly. Docling's default image pipeline base64-wraps standalone images and is net-negative here. No choice offered. |

   **Determining PDF page count.** Use `pdfinfo` (from poppler-utils, typically present on any machine that has PDF tooling):

   ```bash
   pages=$(pdfinfo "$file" 2>/dev/null | awk '/^Pages:/ {print $2}')
   ```

   If `pdfinfo` is missing or returns empty, fall back to "page count unknown" and let the inspector decide.

2. **Show the full plan to the inspector.** Group by recommendation so the landscape is visible before any prompts:

   > "Found 4 non-text file(s) in the specified journal folders. Here's what I'd do with each:
   >
   > **Recommended: docling ingestion** (Claude's `Read` tool can't handle these, or size exceeds its limits)
   >   - `contracts/legal-terms.docx` — Word doc; `Read` doesn't open DOCX
   >   - `specs/mega-report.pdf` — 73-page PDF; exceeds `Read`'s 20-page cap
   >
   > **Recommended: native read via stub** (`Read` handles these cleanly; docling optional)
   >   - `specs/plant-spec.pdf` — 8 pages
   >
   > **Always stub** (images; docling is net-negative for standalone captures)
   >   - `diagrams/dashboard.png`
   >
   > I'll ask per file below. You can shortcut with `all` to accept every recommendation, or `cancel` to halt the whole run."

3. **Ask per file, following the table.** Iterate through the detected set. For each file, show the recommendation and ask. Possible responses: `y` (accept recommendation), `n` (take the other option — see below), `all` (accept recommendations for this and all remaining files; stop asking), `cancel` (halt the whole run).

   For **docling-required** files (DOCX/PPTX/XLSX/HTML, or PDF > 20 pages), the prompt should make the trade-off explicit:

   > "File 1/4: `contracts/legal-terms.docx`
   >   → Recommended: **docling** — `Read` can't open DOCX, so docling is the only way to extract content.
   >   Options:
   >     y       — ingest via docling (if docling isn't installed, I'll offer to install it)
   >     n       — force a native-read stub. WARNING: the stub will be a dead end because `Read` does not support DOCX. Use only if you plan to remove this file before the next ingest, or re-run later.
   >     all     — accept recommendations for this and every remaining file
   >     cancel  — halt the whole /mi-run
   >   Your choice? (y/n/all/cancel)"

   For **native-recommended PDFs** (≤ 20 pages), the prompt should emphasize that native works fine:

   > "File 3/4: `specs/plant-spec.pdf` (8 pages)
   >   → Recommended: **native stub** — I'll generate a small `.md` that points at the PDF; during stage 1/2 I read the PDF directly via the `Read` tool. No preprocessing, no docling dependency needed.
   >   Options:
   >     y       — stub only (native read)
   >     n       — force docling ingestion (canonical `.md` extraction + figures in `<stem>.images/`; useful if the PDF has complex tables or you want an auditable extraction artifact)
   >     all     — accept recommendations for this and every remaining file
   >     cancel  — halt the whole /mi-run
   >   Your choice? (y/n/all/cancel)"

   For **images**, do NOT prompt — auto-apply the stub:

   > "File 4/4: `diagrams/dashboard.png`
   >   → Always stub (images use native stub — docling is skipped deliberately). No confirmation needed."

   Track each file's resolved mode as `docling` or `stub`.

4. **If any file resolved to `docling` — preflight and offer install with disclosure.**

   ```bash
   if command -v docling >/dev/null 2>&1; then
     docling_present=1
   else
     docling_present=0
   fi
   ```

   If `docling_present=0` and at least one file needs docling, surface the install-with-disclosure prompt once:

   > "Docling isn't installed. N file(s) in your plan require it.
   >
   > **Install cost disclosure** — docling pulls ML dependencies (torch, transformers, pillow, OCR engine). Expect **~1–2 GB of disk** and a few minutes of download. The first conversion may additionally pull **~200–400 MB of model weights** from Hugging Face (cached under `~/.cache/huggingface/`).
   >
   > **What I'd run** (picking the first available):
   >
   > ```bash
   > pipx install docling          # preferred
   > # OR:
   > python3 -m pip install --user docling
   > ```
   >
   > The command runs in this session via my `Bash` tool — you'll see progress streamed. Nothing outside pipx's managed venv (or `~/.local/lib/python*/site-packages/`) is modified.
   >
   > **How I use it afterwards** — I invoke docling only via `$CLAUDE_PLUGIN_ROOT/scripts/ingest.sh` (`--file <path>` mode). After install completes, I'll ingest the files you picked for docling and stub the rest.
   >
   > Options:
   >   y       — install docling and proceed
   >   n       — cancel this run (or go back and re-decide — you can tell me to demote docling-required files to stubs, but see the DOCX warning: stubs for DOCX/PPTX/XLSX are dead ends)
   >
   > Proceed with install? (y/n)"

   **On `y`** — install:

   ```bash
   if command -v pipx >/dev/null 2>&1; then
     pipx install docling
   else
     python3 -m pip install --user docling
   fi
   ```

   Stream output. Re-check `command -v docling` afterwards. If still not on PATH (e.g., `~/.local/bin` not in PATH), halt with the PATH-fix instruction:

   > "Install ran but `docling` isn't on PATH. Add `export PATH=\"$HOME/.local/bin:$PATH\"` to your shell profile, open a fresh session, and re-run `/mi-run <folders>`."

   **On `n`** — halt. Do not silently drop docling-required files.

5. **Dispatch each file to the right mode.** Call `ingest.sh` with the correct per-file flag — it handles frontmatter, stub body tailoring, and idempotency itself:

   ```bash
   ingest_failed=0
   for path in "${files[@]}"; do
     mode="${resolved_mode[$path]}"   # "docling" or "stub"
     case "$mode" in
       docling) $CLAUDE_PLUGIN_ROOT/scripts/ingest.sh --file "$path" || ingest_failed=1 ;;
       stub)    $CLAUDE_PLUGIN_ROOT/scripts/ingest.sh --stub "$path" || ingest_failed=1 ;;
     esac
   done
   ```

   Echo each invocation's summary line to the inspector. On `ingest_failed=1`, halt — don't proceed to stage 1 with a partial ingest. Surface the specific failed paths and suggest the inspector open the originals to check format support, or remove them and re-run.

6. **On success — continue.** When every file resolved and `ingest_failed=0`, tell the inspector:

   > "Ingest plan complete: N via docling, M via stub. Continuing with quest generation..."

   Then fall through to the `.md` / `.txt` enumeration in the next paragraph — the newly-produced sibling `.md` files will be picked up by the same glob.

For `.md` files, verify the YAML frontmatter has `contributors:` and `date:` — if missing, tell the inspector which files need those fields before proceeding. `.txt` files don't support frontmatter, so no metadata is required on them; read them as plain content. Other text-based formats (e.g., `.markdown`) in the specified folders are also read as context if present.

Record the selected folder list for use in the summary frontmatter (Step 4).

### Step 2.5 — Size manifest and threshold check

Before reading the bodies of the enumerated files, build a per-file size manifest so the inspector (and the millwright) know up front whether a single transcript or extracted PDF is going to dominate context. Print the manifest to the chat:

```bash
for f in "${files[@]}"; do
  bytes="$(wc -c <"$f" | tr -d ' ')"
  printf '  %8s B  %s\n' "$bytes" "$f"
done
total_bytes="$(du -cb "${files[@]}" 2>/dev/null | tail -1 | awk '{print $1}')"
echo "  total: $total_bytes B across ${#files[@]} file(s)"
```

**Two threshold tiers** — covering both "single huge file" and "many small files":

**Tier 1 — Per-file summarization (existing).** If any single file exceeds **100 KB** OR the total exceeds **500 KB**, surface a warning to the inspector before reading bodies:

> "Heads up — the journal intake is large. <N> file(s) exceed 100 KB and the total is <X> KB. I'll summarize per-file first, then build the cycle's `todo-list.md` and `summary.md` (inside the per-cycle quest subfolder) from the per-file summaries plus selected excerpts, rather than dumping every file into context. Reply `proceed` to continue, or `cancel` to halt and trim the inputs."
>
> (Files over threshold:
> - <path>: <bytes> B
> - …)

On `proceed`, follow the per-file summarization plan: spawn one fresh sub-agent per oversized file (`Agent` with `subagent_type: millwright-inspector-development-machine:journal-file-digester` — explicitly NOT a fork). Each sub-agent reads its assigned file once and returns a digest using the standard return contract (Phase 0 of the implementation plan; see `docs/sub-agent-return-contract.md`). The millwright weaves the digests into `summary.md`'s feature sections and `## Sources`. Do not paste raw file content into the body of the quest files.

**Tier 2 — Per-folder summarization (Phase 5.2 of the context-optimization plan).** Even when no single file exceeds the per-file threshold, a journal folder containing **>5 files AND >40 KB total** is worth delegating: reading 20 small notes individually accumulates the same context as one large file, but is invisible to the per-file check. Compute per-folder counts:

```bash
declare -A folder_count folder_bytes
for f in "${files[@]}"; do
  rel="${f#$data_root/journal/}"
  folder="${rel%%/*}"
  folder_count[$folder]=$(( ${folder_count[$folder]:-0} + 1 ))
  bytes="$(wc -c <"$f" | tr -d ' ')"
  folder_bytes[$folder]=$(( ${folder_bytes[$folder]:-0} + bytes ))
done

oversize_folders=()
for folder in "${!folder_count[@]}"; do
  if (( folder_count[$folder] > 5 && folder_bytes[$folder] > 40000 )); then
    oversize_folders+=("$folder")
  fi
done
```

For each `oversize_folder`, spawn one fresh sub-agent for the folder (NOT one per file). Invoke `Agent` with `subagent_type: millwright-inspector-development-machine:journal-folder-digester`. Sub-agent prompt:

```
You are a fresh sub-agent invoked from `mi-run` Step 2.5 to digest a journal folder containing many small files. Your context is isolated from the main session — main does not see your tool calls, only your final return summary.

**Task:**
- Read every `.md` and `.txt` file under `<data_root>/journal/<folder>/` (including subdirectories, but excluding any `*.images/` subfolders).
- Produce a structured digest covering: (a) the topics each file contributes, (b) cross-file patterns or contradictions, (c) any timestamps / contributors / decisions worth surfacing.
- **Preserve source-file attribution.** Every claim in the digest cites the file it came from (e.g., "design.md notes that ..." or "see meeting-notes-2026-04-12.md §timestamps").

**Output destination:** write the digest to `<data_root>/quest/<active-slug>/.scratch/folder-digest-<folder>.md`. The millwright reads the digest and weaves it into `summary.md`'s feature sections + `## Sources` in Step 4.

---

Required return shape — return ONLY this structure:

Result: success | partial | blocked
Artifacts changed:
- <data_root>/quest/<active-slug>/.scratch/folder-digest-<folder>.md: digest of <count> files (<total bytes>) from journal/<folder>/
Commits:
Findings / risks:
- <bullet, optional — surface any contradictions or missing context>
Main should read:
- <path to digest>: input for summary.md feature sections + Sources

Total return must fit under ~1k tokens.
```

Surface the per-folder delegation plan to the inspector alongside the per-file plan when both fire; the inspector can opt out of either tier with `cancel`.

When no folder hits the per-folder threshold AND no file hits the per-file threshold, proceed without prompting. The thresholds are conservative — small projects routinely come in well under them.

### Step 2.6 — Open the cycle subfolder

Compute the slug for this cycle, create its subfolder under `quest/`, and point `quest/active.md` at it. After this step, every per-cycle file written in Steps 3–5 lands inside `quest/<slug>/` automatically (the helper scripts resolve paths through the active pointer).

```bash
slug="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh slug "${journal_folders[@]}")"
$CLAUDE_PLUGIN_ROOT/scripts/quest.sh start "$slug" "${journal_folders[@]}"
quest_dir="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh dir)"
echo "Opened cycle subfolder: $quest_dir"
```

The slug format is `YYYY-MM-DD-<journal-slugs-joined-with-+>`, with a 3-char hash suffix appended automatically if a same-day collision exists. This is purely identifying — never edit the slug or rename the subfolder by hand.

### Step 2.7 — Record folder links in `reference.md`

Write the cycle's `reference.md`, which links this quest folder back to the `journal/` folders it was built from (and, later, forward to the `workflow-stream/` feature folders it produces). One call does everything — it mints an `id.md` in each journal folder if one doesn't exist yet, then writes `reference.md` with those IDs:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/folder-id.sh init-reference "${journal_folders[@]}"
```

This creates `$quest_dir/reference.md` with the `journal-refs` frontmatter array populated and `feature-refs` left empty — the feature links are appended automatically at stage 2, when each feature's blueprint folder is created (`blueprints.sh ensure-current` calls `folder-id.sh link-feature`). The `id.md` files identify the *folders*, so the links survive a folder being renamed or moved; resolve any ID back to its folder with `folder-id.sh resolve <id>`.

### Step 3 — Generate the cycle's `todo-list.md` (AI work)

Create `$quest_dir/todo-list.md` using the template. Analyze **only the content from the specified journal folders** and write todo items grouped by feature/module. Each item must have a stable `item-id` (e.g., `PAY-001`, `AUD-002`) and start in `TODO` state.

**Feature-name uniqueness gate (mandatory — run BEFORE writing `todo-list.md`).** Candidate feature names are derived from journal *content*, so two different journal folders about the same topic (`general-fixes-1` last cycle, `general-fixes-2` today) naturally distill to the same feature name (`general-fixes`) — and since `workflow-stream/<feature>/` is keyed by feature name, reusing it would mix this cycle's artifacts into the completed workflow's folder. Check every candidate name:

```bash
# For each candidate kebab-case feature name:
if msg="$($CLAUDE_PLUGIN_ROOT/scripts/folder-id.sh feature-lineage-check "$candidate")"; then
  echo "$msg"   # free / same-cycle / same-lineage — safe to use
else
  echo "$msg"   # exit 3 = collision, exit 4 = unknown lineage — MUST rename (below)
fi
```

- **Exit 0** — keep the name. `same-lineage` means this cycle re-selected a journal folder that produced the existing feature folder: that is genuine continuation of the same feature, and folder reuse is intentional (`test/` plans and `decisions.md` carry over by design).
- **Exit 3 or 4** — the name belongs to an unrelated (or unprovable) prior effort. Rename the candidate — never reuse silently:
  1. **Preferred:** the source journal folder's name verbatim — journal `general-fixes-2` → feature `general-fixes-2`. Journal folder names are unique within `journal/`, so this almost always resolves the collision in one step.
  2. If the feature draws on multiple journal folders, or the journal-folder name is itself taken, append the source journal folder's distinguishing suffix (or an ordinal `-2`, `-3`) to the semantic name.
  3. Re-run `feature-lineage-check` on the replacement — it must exit 0 before the name is used anywhere.

The final (possibly renamed) names are the ones written everywhere downstream — `todo-list.md` `related-features`, `summary.md` `features:` + `## Feature:` headings, and the `progress.md` queue — so a rename can never desync the cycle files. If the inspector actually wants to CONTINUE a completed feature in its old folder (reusing its manual-test plan and decisions), the supported path is re-selecting that feature's original journal folder for this cycle, which makes the check pass by lineage. Record any renames — Step 6's hand-off message must surface them.

The block below is a **template** — substitute concrete values before running. `FEATURES` must be comma-separated kebab-case feature names matching what you found in the journal; `DESCRIPTION` is a one-line overall scope. Sample invocation:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init todo-list \
  "$quest_dir/todo-list.md" \
  "FEATURES=payments,audit-log" \
  "DESCRIPTION=Add Stripe webhooks and a tamper-evident audit trail."
```

Replace `payments,audit-log` with the kebab-case feature names you derived from the journal, and replace the description with a single line summarizing the cycle's overall scope. The schema requires `related-features` to be kebab-case — angle-bracket placeholders will fail validation if pasted literally.

Then append the item blocks to the body of the file (replace the placeholder comment).

### Step 4 — Generate the cycle's `summary.md` (AI work)

The block below is a **template** — substitute concrete values before running. `FEATURES` must match the `related-features` array you wrote into `todo-list.md` in Step 3 (exact same kebab-case names, in any order — the body's `## Feature: <name>` headings will be cross-checked against this list). Sample invocation:

```bash
todo_list_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get \
  "$quest_dir/todo-list.md" id)"
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init summary \
  "$quest_dir/summary.md" \
  "TODO_LIST_ID=$todo_list_id" \
  "FEATURES=payments,audit-log" \
  "KEYWORDS=stripe,webhook,refund,append-only" \
  "DESCRIPTION=Digest of pricing-meeting.txt and audit-rfc.md."
```

Replace `payments,audit-log` with the same kebab-case feature names you used in Step 3, `KEYWORDS` with a few comma-separated terms (any case), and `DESCRIPTION` with a one-line summary of the journal content.

Then append the summary body. **The body is feature-indexed** — downstream stages read only the active feature's section plus the cross-cutting block instead of the entire digest:

1. **`## Cross-cutting constraints`** — concerns that apply to every feature in this cycle (compliance, perf budgets, security boundaries, deploy windows). Keep the heading even when there are none, with an empty body — downstream stages look up the heading by name.
2. **`## Out-of-scope`** — items explicitly excluded from this cycle's roadmap, sourced from journal exclusions or inspector statements. Keep the heading even when empty.
3. **`## Feature: <feature-name>`** — one section per feature in the `features:` frontmatter, in the same order. Multi-paragraph digest of journal content relevant to that feature: goals, context, dependencies, acceptance hints. Reference contributing source documents inline (e.g., `see meeting-transcript.txt §12:43`). Each feature section must be self-contained so a stage that loads only this section has everything it needs.
4. **`## Sources`** — one bullet per source file from the selected journal folders, with a short note on what it contributed. Required even for small intakes — keep it terse, but never empty. Format: `- <journal-folder>/<file>: <one-line note>`. This is the back-reference downstream stages use to surface "see pricing-meeting.txt" in their reasoning without re-loading raw journal content.
5. **`## In plain terms`** — a NON-NORMATIVE reader aid at the very bottom of the file. One short bullet per item that appears in the sections above (each cross-cutting constraint, each out-of-scope entry, and each feature), restating it in everyday language and giving ONE concrete example. Keep each to 1–2 sentences. This section is purely for a human skimming the gist; downstream stages ignore it and read the structured sections above, so nothing here is load-bearing. Keep the heading even when the body would be empty. Format each bullet as `- **<item it explains>** — <plain-language restatement>. Example: <concrete example>.`

The `features:` frontmatter array and the body's `## Feature: <name>` headings must agree. The schema validator enforces the frontmatter; downstream stages cross-check by heading name.

### Step 5 — Scaffold the cycle's `progress.md`

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh init "$todo_list_id" <feature1> [<feature2> ...]
```

`progress.sh init` resolves the destination path through the active-quest pointer, so the file lands at `$quest_dir/progress.md` automatically. The new file has the queue populated, `completed: []`, and `active: null`. The feature list here is the distinct feature names surfaced in the todo list — the inspector confirms the priority order in the next step (that's stage 1.5 / item 3 of the workflow). For now, pass them in an order that seems sensible from the journal context; dependencies are resolved later.

### Step 6 — Hand off to the inspector

Tell the inspector (substitute `$quest_dir` and `$slug` literals into the message):

> "Quest scaffolded at `$quest_dir/` (`todo-list.md`, `summary.md`, and `progress.md` with the feature queue; slug=`$slug`; journal folders=<comma-separated list>). The top-level `quest/active.md` now points at this subfolder. Please open `$quest_dir/todo-list.md` and mark the items you want this cycle to cover by putting an `x` in their checkbox AND adding your name in parentheses between the checkbox and the state word, e.g. `- [x] (emin) TODO — PAY-001: ...`. Leave items you don't want as `[ ] TODO`. Items you want to pre-assign but not start this cycle can be `[ ] (emin) TODO`. When you're done marking, type **`/mi-continue`** — I'll promote your selections to PENDING, analyze cross-feature dependencies, and propose a workflow order. Reply `/mi-continue` again to accept the order, or paste a different one first and then `/mi-continue`. (Branch selection is deferred to per-feature config — you'll declare it in `blueprints/current/config.md`'s `## GIT BRANCH` section at stage 2.)"

When the Step-3 uniqueness gate renamed any feature, append one line per rename to the hand-off message:

> "Note: feature `<semantic-name>` was named **`<final-name>`** — `workflow-stream/<semantic-name>/` already belongs to a previously completed workflow built from different journal folder(s) (`<lineage from feature-lineage-check>`), so reusing the name would mix artifacts."

Then **stop and wait** for the inspector to type `/mi-continue`. The Pre-flight Handler in `commands/mi-continue.md` carries out the rest of stage 1.5:

- **First `/mi-continue`** (Pre-flight Step 2A): runs `todo.sh pend-selected` — which **rejects** any `[x] TODO` line missing an `(assignee)` tag and prints the offending item ids on stderr; the millwright relays the list and asks the inspector to fix names before re-trying. Once promotion succeeds, the handler groups PENDING items by feature, analyzes cross-feature dependencies (codebase scan for ≥ 2 features), and proposes a priority order in chat.
- **Second `/mi-continue`** (Pre-flight Step 2B): writes the cycle's `queue-rationale.md` (inside `$quest_dir/`), runs `progress.sh reorder`, and auto-fires `/mi-apply-impact`. If the inspector pasted a custom order between the two `/mi-continue`s, the handler validates it as a permutation of the existing queue.

The handler's two-step flow uses the existence of `queue-rationale.md` and the count of `[x] TODO` lines to disambiguate which sub-state we're in — `mi-run` does NOT need to track this state. Just leave the queue scaffolded and let `/mi-continue` drive the rest.

Do not advance past this point inside `mi-run` itself. `/mi-continue`'s Pre-flight Handler owns the promotion, the proposal, the rationale write-out, and the auto-fire of `/mi-apply-impact`.

## Notes

- Never generate UUIDs inline. Always use `$CLAUDE_PLUGIN_ROOT/scripts/uuid.sh`, or rely on `frontmatter.sh init` which auto-generates one.
- Every write to a workflow file is validated by the PostToolUse hook. If the hook blocks, fix the frontmatter and retry.

## Delegation (optional)

When Step 2.5 flags large files (any file > 100 KB or total > 500 KB), per-file summarization is a good delegation candidate (see `docs/millwright-inspector-project.md` § "Delegation guidance"). One sub-agent per oversized file, capability tier "general reasoning, medium effort". Each sub-agent reads its assigned file once and writes a digest into a scratch path the millwright then weaves into `summary.md`'s feature sections and `## Sources`. Files below threshold stay in-context — delegation overhead is not worth it.
