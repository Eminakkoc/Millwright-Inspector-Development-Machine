---
description: Optional pre-/mi-run step. Organizes the raw inputs dropped into scriptorium/<topic>/ into one task.md, runs review iterations on it (each archived into v<N>/), and publishes the result to journal/<topic>/ for /mi-run. Not part of any quest cycle.
argument-hint: "<topic> [--continue]"
---

# mi-scriptorium

**Runtime bootstrap.** Every `$CLAUDE_PLUGIN_ROOT` reference in this command's Bash blocks assumes a resolved plugin root; Claude Code does not inject the env var into Bash subshells. If it is empty in your shell, apply the canonical resolver (`docs/millwright-inspector-project.md` §8.14; reference implementation: `mi-continue.md` Step 1a) before the first Bash block: (1) inherited env var when it points at a working install, (2) `$PWD` when it is this plugin's source repo, (3) the `installPath` from `~/.claude/plugins/installed_plugins.json` — then export it, persist it to the per-cwd tempfile, and prepend the recovery one-liner to every subsequent Bash block. Refuse with an environmental diagnostic if none resolve.

**Running blocks.** Run each fenced `bash` block with the Bash tool (never the PowerShell tool), as written, in one call. Don't wrap a block in `bash -c`, `sh -c`, `zsh -c` or `eval`: Claude Code can't check a wrapped script, so it may stop for permission, and an unattended session denies it. The blocks run the same in bash and zsh; if one fails on shell syntax, stop and report it as a plugin bug instead of working around it.

**Delegation contract.** This command REQUIRES the sub-agents listed below; §8.13's main-read budget forbids main from doing their work itself. **Invoking `/mi-scriptorium` IS the user requesting them** — Claude Code's default "do not call the Agent tool unless the user requested it" (and any stricter house rule layered on it) does not reach a sub-agent this command names at the step that names it, so spawn them without asking for extra confirmation. The default still holds everywhere else: never spawn a sub-agent that this command does not name, and never invent fan-out to parallelize a step main is supposed to run. If a named delegation genuinely cannot run (type unavailable, harness refusal), say so and stop — never silently do its work in main. Sub-agents: `journal-file-digester` (size policy Tier 1 — one oversized input file each, at Step 1 or the Step 2 merge), `journal-folder-digester` (size policy Tier 2 — one per topic folder with many small input files, at Step 1 or the Step 2 merge). Canonical rule: `docs/millwright-inspector-project.md` §8.15.

**What it does.** An optional step before `/mi-run`. The inspector drops a topic's scattered raw inputs (notes, transcripts, converted documents) into `<data_root>/scriptorium/<topic>/`. This command organizes them into one `task.md`, refines it over one or more review iterations, and publishes it to `<data_root>/journal/<topic>/task.md`. `/mi-run` then starts the quest cycle from that refined file and takes its `## Feature:` headings as the cycle's features. An inspector can always skip scriptorium and put files straight into `journal/`.

**Terms.** A *topic folder* is `scriptorium/<topic>/`: one topic's inputs, published as one journal folder. A topic can hold several features. *Feature* always means a `## Feature:` section in `task.md`, never the folder.

**Generated-file marker.** Every `task.md` this command writes carries the frontmatter `source: scriptorium`. That marker, read with `frontmatter.sh get <file> source` (the same test `/mi-run` uses), is what separates a generated `task.md` from a user file. It decides the entry guards (Step 0) and the publish target rule (Step 7).

**No quest cycle.** Scriptorium works outside the mi-workflow:

- It never writes under `quest/`, including the active quest's `.scratch/`. Its own scratch space is `scriptorium/<topic>/.scratch/`.
- It is never advanced with `/mi-continue`. Re-entry is always `/mi-scriptorium <topic> --continue`. Never point the inspector at `/mi-continue` from this command.
- Auto mode does not apply. Every question in this command is asked, even while the active quest cycle has auto mode on.
- It never runs `/clear` or `/mi-run` itself. Step 7 ends by telling the inspector what to type.

## Inputs (positional, parsed from `$ARGUMENTS`)

- **`<topic>`** (one token) — the name of a direct child of `<data_root>/scriptorium/`. A leading `scriptorium/` and a trailing `/` are dropped, so `scriptorium/payments` means `payments`.
- **`--continue`** (optional flag) — start at Step 2 (the next review iteration) instead of Step 1 (organize).

Invocations:

- `/mi-scriptorium payments` — organize the inputs in `scriptorium/payments/` into `task.md`, then stop.
- `/mi-scriptorium payments --continue` — run the next iteration: archive into `v<N>/`, review, summarize, then iterate, publish or pause.

## Topic folder layout

```
scriptorium/payments/
  task.md                 # the working copy, frontmatter source: scriptorium
  findings.md             # this iteration's review findings (written by the review steps)
  .scratch/               # digests from the size policy; never input
  v1/                     # iteration 1: the user files, moved here unchanged
    meeting-notes.md
    spec.pdf
    spec.md
    spec.images/
  v2/                     # iteration 2: task.md as it stood + the previous findings.md,
    task.md               #   plus any user input added before iteration 2
    findings.md
    extra-notes.md
```

**Folder rules used throughout:**

- A *version folder* `v<N>/` is `v` followed by digits only (`v1/`, `v12/`). `v2-notes/` is an ordinary user folder. This is the definition `scripts/ingest.sh` uses.
- *Hidden* entries (any name starting with `.`, such as `.scratch/` or a Finder `.DS_Store`) are never input.
- *Non-text* files are the ones `/mi-ingest` converts: `.pdf`, `.docx`, `.pptx`, `.xlsx`, `.html`, `.png`, `.jpg`, `.jpeg`, `.webp`, `.tiff`, `.tif` (any case). A non-text file with a sibling `<stem>.md` is already converted: the `.md` is the input and the original stays where it is.

## Execution

Run Step 0 first. It decides where the run starts: a plain run starts at Step 1 and stops after it. A `--continue` run starts at Step 2 and runs Steps 2–6, then Step 7 or a pause.

### Step 0 — Entry guards

**No topic argument.** List the topic folders and ask which one:

```bash
data_root="$("$CLAUDE_PLUGIN_ROOT/scripts/data-root.sh")"
if [[ -d "$data_root/scriptorium" ]]; then
  find "$data_root/scriptorium" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | sed 's|.*/||' | LC_ALL=C sort
else
  echo "no scriptorium/ folder under $data_root"
fi
```

- One or more names: ask "Which topic — `<name>`, `<name>`, …?" and continue with the answer. Keep `--continue` if it was given.
- No names (or no `scriptorium/` folder): stop with "No topic folders yet. Create `scriptorium/<topic>/` under the data root, put the topic's input files there, then run `/mi-scriptorium <topic>`." (`/mi-init` creates `scriptorium/` itself.)

**Check the topic folder.** Substitute the topic name:

```bash
data_root="$("$CLAUDE_PLUGIN_ROOT/scripts/data-root.sh")"
topic="<topic>"
topic="${topic#scriptorium/}"
topic="${topic%/}"
topic_dir="$data_root/scriptorium/$topic"
if [[ -z "$topic" || "$topic" == */* || "$topic" == .* ]]; then
  echo "guard: bad-name"
elif [[ ! -d "$topic_dir" ]]; then
  echo "guard: missing $topic_dir"
elif [[ -z "$(find "$topic_dir" -mindepth 1 -maxdepth 1 ! -name '.*' | head -1)" ]]; then
  echo "guard: empty $topic_dir"
else
  generated=0
  if [[ -f "$topic_dir/task.md" ]] \
    && [[ "$("$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" get "$topic_dir/task.md" source 2>/dev/null)" == "scriptorium" ]]; then
    generated=1
  fi
  echo "guard: ok $topic_dir"
  echo "generated: $generated"
  for f in task.md findings.md; do
    if [[ -e "$topic_dir/$f" ]]; then
      echo "present: $f"
    fi
  done
fi
```

Branch on the `guard:` line:

- **`bad-name`** — stop with "`<topic>` is not a topic folder name. Use the name of a folder directly under `scriptorium/`."
- **`missing`** or **`empty`** — stop with "`scriptorium/<topic>/` is missing or has no input files. Put the topic's input files there first, then run `/mi-scriptorium <topic>`."
- **`ok`** — check the mode against `generated:`:

| Mode | `generated: 1` | `generated: 0` |
| --- | --- | --- |
| plain run | **Refuse:** "`scriptorium/<topic>/task.md` was generated by an earlier run, and a plain run would overwrite it. Run `/mi-scriptorium <topic> --continue` to start the next iteration." | Go to **User-file rename** below, then Step 1. |
| `--continue` | Go to Step 2. | **Refuse:** "`scriptorium/<topic>/` has no generated `task.md` yet. Run `/mi-scriptorium <topic>` (without `--continue`) first to organize the inputs." |

**User-file rename (plain run only).** On a plain run no generated file exists yet, so a `task.md` or `findings.md` listed under `present:` is the inspector's own input. It needs another name so the generated `task.md` (and later the review's `findings.md`) can take its place. For each one, ask:

> "`scriptorium/<topic>/<file>` isn't a generated file, so I'll organize it as one of your inputs. It needs a different name first — what should I call it? (for example `<file stem>-notes.md`)"

The new name must be a plain file name (no `/`, not starting with `.`), and neither `task.md` nor `findings.md`. Rename it, never overwrite:

```bash
data_root="$("$CLAUDE_PLUGIN_ROOT/scripts/data-root.sh")"
topic_dir="$data_root/scriptorium/<topic>"
old="$topic_dir/<task.md or findings.md>"
new="$topic_dir/<new name>"
if [[ -e "$new" ]]; then
  echo "rename: taken"
else
  mv "$old" "$new" && echo "rename: done"
fi
```

On `rename: taken`, say the name is already used in the folder and ask again. When every listed file is renamed, go to Step 1.

### Input scan (used by Step 1 and the Step 2 merge)

Lists the topic folder's input files, finds non-text files that still need converting, and measures sizes for the size policy. The input is every file under the topic folder except: hidden entries, `*.images/` folders, version folders `v<N>/` (at any depth, the prune `scripts/ingest.sh` applies), the top-level `task.md` and `findings.md`, and non-text originals that already have a sibling `.md`.

At Step 1 this is everything the inspector dropped in. At the Step 2 merge it is exactly the user input added since the last iteration, because everything older has already moved into a `v<N>/` folder.

```bash
data_root="$("$CLAUDE_PLUGIN_ROOT/scripts/data-root.sh")"
topic_dir="$data_root/scriptorium/<topic>"
non_text=" pdf docx pptx xlsx html png jpg jpeg webp tiff tif "
total=0
count=0
big=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  rel="${f#"$topic_dir"/}"
  ext="$(printf '%s' "${f##*/}" | sed -n 's/^.*\.\([^.]*\)$/\1/p' | tr '[:upper:]' '[:lower:]')"
  if [[ -n "$ext" && "$non_text" == *" $ext "* ]]; then
    if [[ ! -f "${f%.*}.md" ]]; then
      printf 'needs-ingest\t%s\n' "$rel"
    fi
    continue
  fi
  bytes="$(wc -c <"$f" | tr -d ' ')"
  printf 'input\t%s\t%s\n' "$bytes" "$rel"
  total=$((total + bytes))
  count=$((count + 1))
  if [[ "$bytes" -gt 100000 ]]; then
    big=$((big + 1))
  fi
done < <(find "$topic_dir" -mindepth 1 \
           \( -type d \( -name '.*' -o -name '*.images' -o \( -name 'v[0-9]*' ! -name 'v*[!0-9]*' \) \) -prune \) \
           -o \( -type f ! -name '.*' ! -path "$topic_dir/task.md" ! -path "$topic_dir/findings.md" -print \) \
         | LC_ALL=C sort)
tier1=0
tier2=0
if [[ "$big" -gt 0 || "$total" -gt 500000 ]]; then
  tier1=1
fi
if [[ "$count" -gt 5 && "$total" -gt 40000 ]]; then
  tier2=1
fi
echo "total: $total B across $count input file(s); over 100 KB: $big"
echo "tier1: $tier1"
echo "tier2: $tier2"
```

Rows are `input\t<bytes>\t<path>` and `needs-ingest\t<path>`, with paths relative to the topic folder. Show the `input` rows to the inspector as the size manifest.

**Non-text check.** Any `needs-ingest` row stops the step **before anything is written, copied or moved**:

> "These files need converting to text first: `<path>`, …. Run `/mi-ingest scriptorium/<topic>`, then run `/mi-scriptorium <topic>` again."

At Step 2, say `/mi-scriptorium <topic> --continue` instead.

**Size policy.** These are the thresholds of `/mi-run` Step 2.5, applied to the topic folder (KB means 1000 bytes; byte counts come from `wc -c`):

- **Tier 1 — per-file digests** (`tier1: 1`): any input file over 100 KB, or all inputs together over 500 KB.
- **Tier 2 — folder digest** (`tier2: 1`): more than 5 input files AND more than 40000 bytes in total.

When neither tier fires, read the input files directly and go on. When one or both fire, warn before reading any input body:

> "Heads up — the input for `<topic>` is large: <count> file(s), <total> KB in total. Instead of reading every file into context, I'll <plan>. Reply `proceed` to continue, or `cancel` to stop and trim the inputs."
>
> (Files over 100 KB:
> - <path>: <bytes> B
> - …)

`<plan>` names what fired: "summarize each file over 100 KB with its own digester" (Tier 1) and/or "summarize the folder's files with one folder digester" (Tier 2). On `cancel`, stop. Nothing has been written, copied or moved. On `proceed`, run the plan:

**Tier 1.** For each input file over 100 KB, spawn one fresh sub-agent: `Agent` with `subagent_type: millwright-inspector-development-machine:journal-file-digester` (explicitly NOT a fork). It is read-only and returns its digest in its reply, so nothing is saved for it. Spawn prompt:

```
You are a fresh sub-agent invoked from `mi-scriptorium` (<Step 1 organize | Step 2 merge>) to digest one oversized input file of the scriptorium topic `<topic>`. Your context is isolated from the main session — main does not see your tool calls, only your final reply.

**Task:**
- Read `<absolute path of the file>` once.
- Digest it: the topics it covers, key facts and requirements, decisions, constraints, exclusions, timestamps and contributors. Cite the file by name in every claim. Do not fabricate or extrapolate.
- Include the mandatory `## Named resources` section (see your agent file).
- You write no file. Main organizes your digest into the topic's task.md.

Put the digest first, under a `## Digest` heading, then the return block below.

---

Required return shape — return ONLY this structure after the digest:

Result: success | partial | blocked
Artifacts changed:
Commits:
Findings / risks:
- <bullet, optional — contradictions or missing context>
Main should read:

Return only this structure. Do not narrate intermediate steps. Total return must fit under ~1k tokens.
```

**Tier 2.** Spawn one fresh sub-agent for the topic folder (not one per file): `Agent` with `subagent_type: millwright-inspector-development-machine:journal-folder-digester`. When Tier 1 also fired, leave the files over 100 KB out of its list; their digests come back from Tier 1. Create its output folder first:

```bash
data_root="$("$CLAUDE_PLUGIN_ROOT/scripts/data-root.sh")"
mkdir -p "$data_root/scriptorium/<topic>/.scratch"
```

Spawn prompt:

```
You are a fresh sub-agent invoked from `mi-scriptorium` (<Step 1 organize | Step 2 merge>) to digest the input files of the scriptorium topic `<topic>`. Your context is isolated from the main session — main does not see your tool calls, only your final return summary.

**Task:**
- Read exactly these files, and no others:
  <absolute path of each input file, one per line>
- Never read anything in a `v<N>/` archive folder, the `.scratch/` folder or a `*.images/` folder, and never `task.md` or `findings.md` — none of them is input to this digest.
- Produce a structured digest covering: (a) the topics each file contributes, (b) cross-file patterns or contradictions, (c) any timestamps / contributors / decisions worth surfacing.
- **Preserve source-file attribution.** Every claim in the digest cites the file it came from (e.g., "design.md notes that ...").
- Include the mandatory `## Named resources` section (see your agent file).

**Output destination:** write the digest to `<data_root>/scriptorium/<topic>/.scratch/folder-digest-<topic>.md` — this exact path, never a `quest/` folder's `.scratch/`. Main reads the digest and organizes it into the topic's task.md.

---

Required return shape — return ONLY this structure:

Result: success | partial | blocked
Artifacts changed:
- <data_root>/scriptorium/<topic>/.scratch/folder-digest-<topic>.md: digest of <count> files (<total bytes>) from scriptorium/<topic>/
Commits:
Findings / risks:
- <bullet, optional — surface any contradictions or missing context>
Main should read:
- <path to digest>: input for the topic's task.md

Return only this structure. Do not narrate intermediate steps. Total return must fit under ~1k tokens.
```

Then read the digest file and any input file no digester covered.

### Step 1 — Organize

Reached on a plain run after Step 0. Combines every input into one working `scriptorium/<topic>/task.md`.

1. **Scan the inputs** with the Input scan above. If it lists no `input` rows, stop with the Step 0 `empty` message. Apply the non-text check and the size policy, then read the inputs (or their digests).

2. **Write `scriptorium/<topic>/task.md`** with the Write tool. The frontmatter is exactly:

   ```
   ---
   source: scriptorium
   ---
   ```

   `contributors:` and `date:` are added only to the published copy (Step 7). The body has one section per `## ` heading, in this order:

   - **`## Goal`** — what the topic as a whole is for, in a short paragraph. `/mi-run` condenses it into the cycle description and the opening paragraph of each feature.
   - **`## Cross-cutting constraints`** — rules that hold for more than one feature (one bullet each).
   - **`## Out-of-scope`** — what the inputs explicitly exclude (one bullet each).
   - **`## Feature: <kebab-name>`** — one per feature found in the inputs. Each holds everything the inputs say about that feature, as one bullet per distinct requirement, so `/mi-run` can turn the section into todo items.

   Rules for the body:

   - Each feature heading is a single line at column 0, written exactly `## Feature: <name>`. The name is kebab-case (lowercase letters, digits and single hyphens) and unique within the file. No `## Feature:` line ever appears inside a code fence.
   - Keep a section heading even when its section is empty. `/mi-run` maps Cross-cutting constraints and Out-of-scope one to one.
   - Use only what the inputs say. When two inputs disagree, keep both statements, each with the file it came from, and leave the decision to the review steps.
   - Keep any skill, tool, rule, plugin, hook or MCP server an input names (the digests list them under `## Named resources`) verbatim in the section it applies to, so `/mi-run` can report it.

3. **Check the file.**

   ```bash
   data_root="$("$CLAUDE_PLUGIN_ROOT/scripts/data-root.sh")"
   task="$data_root/scriptorium/<topic>/task.md"
   if [[ "$(sed -n '1,3p' "$task")" == "$(printf -- '---\nsource: scriptorium\n---')" ]]; then
     echo "frontmatter: ok"
   else
     echo "frontmatter: wrong"
   fi
   grep -n '^## ' "$task"
   names="$(sed -n 's/^## Feature:[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' "$task")"
   printf '%s\n' "$names" | grep -vE '^[a-z0-9]+(-[a-z0-9]+)*$' | sed '/^$/d; s/^/not-kebab: /'
   printf '%s\n' "$names" | sed '/^$/d' | LC_ALL=C sort | uniq -d | sed 's/^/duplicate: /'
   awk '/^[[:space:]]*```/ { inside = !inside; next } inside && /^## Feature:/ { print "in-fence: line " NR }' "$task"
   ```

   The names come from the same `sed` that `/mi-run` Step 2 uses to list scriptorium features, so this list is what `/mi-run` will see. Fix the file and re-run the check until `frontmatter: ok` is printed, the `## ` headings run Goal, Cross-cutting constraints, Out-of-scope, then the features, and no `not-kebab:`, `duplicate:` or `in-fence:` line remains.

4. **Stop.** Step 1 never moves or deletes the inspector's files — Step 2 archives them. Tell the inspector:

   > "Organized `scriptorium/<topic>/task.md` — <N> feature(s): `<name>`, …. Read it, then run `/mi-scriptorium <topic> --continue` to start the first review iteration. If you have more input, add it after that first iteration: a file dropped in before it is archived into `v1/` without being merged."

### Step 2 — Version folders

Reached on a `--continue` run after Step 0, and again from Step 6 on `yes`. Each iteration archives its inputs into `scriptorium/<topic>/v<N>/`. Files keep their original names inside `v<N>/` (no version suffix), and `task.md` stays in the topic folder as the working copy the review steps work on.

**Iteration number.** `N` is the count of version folders plus one. Version folders are never deleted or renamed by hand (an assumption, not a check), so `v<N>/` is always a new folder.

```bash
data_root="$("$CLAUDE_PLUGIN_ROOT/scripts/data-root.sh")"
topic_dir="$data_root/scriptorium/<topic>"
count="$(find "$topic_dir" -mindepth 1 -maxdepth 1 -type d -name 'v[0-9]*' ! -name 'v*[!0-9]*' | wc -l | tr -d ' ')"
echo "iteration: $((count + 1))"
```

**User input** is every entry directly in the topic folder except `task.md`, `findings.md`, hidden entries and the version folders. That covers files and the inspector's own subfolders alike, including `/mi-ingest`'s sibling `.md` files and `*.images/` folders. This block moves it into `v<N>/` (substitute the iteration number):

```bash
data_root="$("$CLAUDE_PLUGIN_ROOT/scripts/data-root.sh")"
topic_dir="$data_root/scriptorium/<topic>"
vdir="$topic_dir/v<N>"
mkdir -p "$vdir"
find "$topic_dir" -mindepth 1 -maxdepth 1 ! -name '.*' ! -name task.md ! -name findings.md \
    ! \( -type d -name 'v[0-9]*' ! -name 'v*[!0-9]*' \) -print \
  | LC_ALL=C sort \
  | while IFS= read -r entry; do
      [[ -n "$entry" ]] || continue
      mv "$entry" "$vdir/" && printf 'archived: %s\n' "${vdir##*/}/${entry##*/}"
    done
```

**Iteration 1** (`iteration: 1`). Move the user input into `v1/` with the block above. Nothing else: there is no `findings.md` yet, and `v1/` holds only the inspector's files. Go to Step 3.

**Iteration 2 and later.** Before touching anything, run the Input scan. Its `input` rows are the user input added since the last iteration.

1. **Non-text check and size policy.** A `needs-ingest` row stops the step, and so does `cancel` at the size prompt: nothing is copied, moved or merged. Only this new input is measured. When there is none, skip to step 2 below.
2. **Copy `task.md` and move `findings.md` into `v<N>/`:**

   ```bash
   data_root="$("$CLAUDE_PLUGIN_ROOT/scripts/data-root.sh")"
   topic_dir="$data_root/scriptorium/<topic>"
   vdir="$topic_dir/v<N>"
   mkdir -p "$vdir"
   cp "$topic_dir/task.md" "$vdir/task.md" || exit 1
   if [[ -f "$topic_dir/findings.md" ]]; then
     mv "$topic_dir/findings.md" "$vdir/findings.md"
   fi
   ls -1 "$vdir"
   ```

3. **Merge the new input into the working `task.md`.** Read it (or its digests) and organize it into the outline with the Edit tool, following the body rules of Step 1: new requirements go into the feature they belong to, a new feature gets its own `## Feature:` section, and the frontmatter stays exactly `source: scriptorium`. Then run Step 1's check block (item 3) until it passes.
4. **Move that user input into `v<N>/`** with the block above.

Go to Step 3.

### Step 3 — Section review

_Not built yet — the `scriptorium-review` feature fills this step in._ Go straight to Step 4.

### Step 4 — Consistency review

_Not built yet — the `scriptorium-review` feature fills this step in._ Go straight to Step 5.

### Step 5 — Refinement summary

Show the inspector how the reviewed working `task.md` differs from everything they wrote. This step asks for no decision and writes no file: `task.md`, `findings.md` and every `v<N>/` folder stay byte-identical.

The comparison set is every user input archived in a version folder: `v1/`, plus the user input archived in later `v<N>/` folders. It leaves out each `v<N>/task.md` and `v<N>/findings.md` (generated files), hidden entries, `*.images/` folders and non-text originals that have a sibling `.md`. Read the listed files directly, whatever their size: no size policy, no digesters and no `.scratch/` writes at this step.

```bash
data_root="$("$CLAUDE_PLUGIN_ROOT/scripts/data-root.sh")"
topic_dir="$data_root/scriptorium/<topic>"
non_text=" pdf docx pptx xlsx html png jpg jpeg webp tiff tif "
find "$topic_dir" -mindepth 1 -maxdepth 1 -type d -name 'v[0-9]*' ! -name 'v*[!0-9]*' | LC_ALL=C sort \
  | while IFS= read -r vd; do
      find "$vd" -mindepth 1 \( -type d \( -name '.*' -o -name '*.images' \) -prune \) \
        -o \( -type f ! -name '.*' ! -path "$vd/task.md" ! -path "$vd/findings.md" -print \) | LC_ALL=C sort
    done \
  | while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      ext="$(printf '%s' "${f##*/}" | sed -n 's/^.*\.\([^.]*\)$/\1/p' | tr '[:upper:]' '[:lower:]')"
      if [[ -n "$ext" && "$non_text" == *" $ext "* ]]; then
        if [[ ! -f "${f%.*}.md" ]]; then
          printf 'unread\t%s\n' "${f#"$topic_dir"/}"
        fi
        continue
      fi
      printf 'compare\t%s\n' "${f#"$topic_dir"/}"
    done
if [[ -f "$topic_dir/findings.md" ]]; then
  printf 'findings\tfindings.md\n'
fi
find "$topic_dir" -mindepth 1 -maxdepth 1 -type d -name 'v[0-9]*' ! -name 'v*[!0-9]*' | LC_ALL=C sort \
  | while IFS= read -r vd; do
      if [[ -f "$vd/findings.md" ]]; then
        printf 'findings\t%s\n' "${vd##*/}/findings.md"
      fi
    done
```

Read every `compare` file, the working `task.md` and every `findings` file. Then show the inspector a summarized list, one bullet per difference between the inputs and `task.md`:

- **Added** — in `task.md` but in no input.
- **Changed** — reworded so the meaning moved, or made more specific.
- **Dropped** — in an input but not in `task.md`.
- **Moved** — placed under a different section than its input suggested (for example into another `## Feature:` section).

Mark each bullet that came from a review finding the inspector approved in a walkthrough — a finding recorded in `findings.md` or an archived `v<N>/findings.md` with the outcome `applied` or `edited` — with that finding. For example: "Added: refunds over €500 need approval (from finding 3, which you applied)". A pure regrouping of the same content is one bullet, not one per line. List any `unread` file at the end as not compared (a non-text file archived without a converted `.md`).

### Step 6 — Iterate?

Always ask, in every mode (a quest cycle's auto mode never answers it):

> "Run another review iteration on `<topic>`? Reply `yes` to start iteration <N+1> now, `no` to publish `task.md` to the journal, or `later` to stop here without publishing."

- **`yes`** — go to Step 2 in this session. It starts the next `v<N>/`.
- **`no`** — go to Step 7.
- **`later`** — stop. Nothing is published and nothing is written under `journal/`. Tell the inspector:

  > "Paused — `<topic>` is not published. Add any new input files to `scriptorium/<topic>/`, then run `/mi-scriptorium <topic> --continue` when you're ready for the next iteration."

### Step 7 — Publish to journal

Copies the working `task.md` to `<data_root>/journal/<name>/task.md`, the input `/mi-run` reads. `<name>` is `<topic>` unless the inspector picks another name. The file is copied, not moved: `scriptorium/<topic>/` stays in place, so the topic can be refined and published again later.

1. **Contributors.** Collect the `contributors:` values from the frontmatter of the archived user files: the `.md` files in the version folders, leaving out each `v<N>/task.md` and `v<N>/findings.md`.

   ```bash
   data_root="$("$CLAUDE_PLUGIN_ROOT/scripts/data-root.sh")"
   topic_dir="$data_root/scriptorium/<topic>"
   find "$topic_dir" -mindepth 1 -maxdepth 1 -type d -name 'v[0-9]*' ! -name 'v*[!0-9]*' | LC_ALL=C sort \
     | while IFS= read -r vd; do
         find "$vd" -mindepth 1 \( -type d \( -name '.*' -o -name '*.images' \) -prune \) \
           -o \( -type f -name '*.md' ! -name '.*' ! -path "$vd/task.md" ! -path "$vd/findings.md" -print \)
       done \
     | while IFS= read -r f; do
         [[ -n "$f" ]] || continue
         names="$("$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" get "$f" 'contributors[]' 2>/dev/null)"
         if [[ -z "$names" || "$names" == "null" ]]; then
           names="$("$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" get "$f" contributors 2>/dev/null)"
         fi
         if [[ -n "$names" && "$names" != "null" ]]; then
           printf '%s\n' "$names"
         fi
       done \
     | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d' | LC_ALL=C sort -u
   ```

   The printed names, one per line, are the union. When nothing is printed, ask the inspector once: "None of the archived input files lists its contributors. Who contributed to `<topic>`? (names, comma-separated)". Use their answer, one name per line.

2. **Publish.** Substitute the journal folder name and the contributor names (one per line). The block refuses to write into a folder that is not an earlier publish of a scriptorium topic:

   ```bash
   data_root="$("$CLAUDE_PLUGIN_ROOT/scripts/data-root.sh")"
   topic_dir="$data_root/scriptorium/<topic>"
   name="<journal folder name>"
   jdir="$data_root/journal/$name"
   if [[ -z "$name" || "$name" == */* || "$name" == .* ]]; then
     echo "target: bad-name"
     exit 0
   fi
   if [[ -e "$jdir" ]]; then
     earlier=0
     if [[ -d "$jdir" && -f "$jdir/task.md" ]] \
       && [[ -z "$(find "$jdir" -mindepth 1 -maxdepth 1 ! -name '.*' ! -name task.md ! -name id.md | head -1)" ]] \
       && [[ "$("$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" get "$jdir/task.md" source 2>/dev/null)" == "scriptorium" ]]; then
       earlier=1
     fi
     if [[ "$earlier" != "1" ]]; then
       echo "target: taken"
       exit 0
     fi
     echo "target: replace"
   else
     echo "target: new"
   fi
   mkdir -p "$topic_dir/.scratch"
   cat > "$topic_dir/.scratch/contributors.txt" <<'EOF'
   <contributor names, one per line>
   EOF
   contributors="$("$CLAUDE_PLUGIN_ROOT/scripts/py.sh" -c 'import json, sys; print(json.dumps([s.strip() for s in open(sys.argv[1], encoding="utf-8") if s.strip()], ensure_ascii=False))' "$topic_dir/.scratch/contributors.txt")" || exit 1
   mkdir -p "$jdir"
   cp "$topic_dir/task.md" "$jdir/task.md" || exit 1
   "$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" set "$jdir/task.md" contributors "$contributors" || exit 1
   "$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" set "$jdir/task.md" date "$(date +%Y-%m-%d)" || exit 1
   echo "published: $jdir/task.md"
   echo "source: $("$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" get "$jdir/task.md" source)"
   sed -n 's/^## Feature:[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' "$jdir/task.md" | sed 's/^/feature: /'
   ```

   Branch on the `target:` line:

   - **`new`** — `journal/<name>/` did not exist and now holds the published `task.md`.
   - **`replace`** — `journal/<name>/` held only an earlier publish (a `task.md` with `source: scriptorium`, plus an optional `id.md`). Only `task.md` was replaced; `id.md` is untouched, so the folder keeps its identity (its UUID, its lineage and the quest `reference.md` links to it).
   - **`taken`** — the folder holds something else, such as a journal folder the inspector made by hand. Nothing was written. Ask: "`journal/<name>/` already holds files that aren't an earlier publish of a scriptorium topic, so I won't write there. Which journal folder name should I publish `<topic>` to instead?" Re-run the block with the new name; the same rules apply.
   - **`bad-name`** — nothing was written. Ask for a plain folder name (no `/`, not starting with `.`).

   The published copy keeps `source: scriptorium` and gains `contributors:` and `date:` (today, YYYY-MM-DD), which `/mi-run` requires on every journal `.md` file.

3. **Hand off.** Tell the inspector, in prose:

   > "Published `scriptorium/<topic>/task.md` to `journal/<name>/task.md` — <N> feature(s): `<name>`, …. To start a quest cycle from it, type `/clear`, then `/mi-run <name>` (add `--auto` to run the cycle in auto mode). `scriptorium/<topic>/` stays in place; to refine it further later, run `/mi-scriptorium <topic> --continue` and publish again."

   Stop. Do not run `/clear` or `/mi-run`.

## Notes

- **Resuming an interrupted review is not supported.** `--continue` always starts at Step 2. If a session stops partway through Steps 3–4, the next `--continue` archives the half-reviewed `task.md` and the partial `findings.md` as a new `v<N>/` and reviews every section again.
- **Late input before the first iteration.** Iteration 1 archives without merging, so a file dropped in between Step 1 and the first `--continue` lands in `v1/` without being merged. Step 1's stop message tells the inspector to add late input after the first iteration.
- **Nothing under `quest/`.** No step of this command writes there. Digests go to `scriptorium/<topic>/.scratch/`.
- **Contract with `/mi-run`.** `/mi-run` Step 2 detects a published `task.md` by `source: scriptorium`, lists its features with a `^## Feature:` line match, and stops when two selected folders declare the same feature. Its Steps 3–4 condense `## Goal` and map `## Cross-cutting constraints` and `## Out-of-scope` one to one. Step 1's outline and check exist to satisfy that parser.
