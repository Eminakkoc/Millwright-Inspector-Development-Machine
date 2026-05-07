# Stage info-bar implementation plan

A Claude Code bottom-bar widget that shows the current mo-workflow stage at a
glance. The line is regenerated on every status-line refresh by reading
`progress.md` directly — there is no hook, no sidecar, no per-cycle log,
and no token math.

This is deliberately **smaller** than the v0.5.0–v0.7.4 info-bar (which
tracked per-stage token usage via a `PostToolUse` hook + JSON sidecar +
NDJSON usage log + `/mo-info-bar` wrapper). That feature was removed in
commit `2b14410` because the moving parts outweighed the signal. This plan
keeps only the part the overseer actually wanted: knowing *which stage we
are in right now*.

## 1. Goal

Render a single line at the bottom of Claude Code that always reads:

```
mo-workflow · <feature> · Stage <N> · <stage-name>
```

The line refreshes on every Claude Code status-line tick. Because Claude Code
re-runs the status-line command on every tick, the script does not need
event hooks to "react" to stage transitions — the next tick after
`progress.sh advance` picks the new value up automatically.

## 2. Non-goals

- **No token tracking.** No tokens-per-stage display, no cumulative counters,
  no main/sub context occupancy. That was the v0.5.0 feature; it is
  intentionally dropped.
- **No hooks.** No `PostToolUse` matcher, no `track-stage-tokens.sh`. The
  status line is pull-only.
- **No sidecar / log files.** No `quest/<slug>/.stage-tokens.json`, no
  `usage.log`. Source of truth is `progress.md`; nothing else is written.
- **No automatic plugin-manifest install.** Claude Code's plugin manifest
  does not distribute `statusLine` settings; the wiring has to be written
  to the user's `.claude/settings.json`. We do this via a dedicated
  slash command (§5.3) — not via the plugin manifest.

## 3. Display format

The widget is a single line with `·` separators. Length is bounded so it fits
in a typical terminal width.

### 3.1 Active feature (stages 2–7)

```
mo-workflow · <feature> · Stage <N> · <stage-name>
```

`<feature>` is `progress.md → active.feature` (kebab-case, e.g.
`payment-webhook`). `<N>` is `active.current-stage` (integer 2–8).
`<stage-name>` is the table in §4.

If the feature slug is longer than 24 chars it is truncated to 22 chars
plus `…`.

### 3.2 Cycle-level states (no active feature)

When `active` is `null` the schema says we are either:

- pre-stage-2 (`/mo-run` happened but no feature has been activated yet), or
- post-stage-8 (the previous feature finished; the next one has not been
  activated).

Both cases render as:

```
mo-workflow · cycle <slug> · Stage 1 · quest generated
```

…until `progress.sh activate` populates `active`. There is no separate
"stage 1.5" rendering — `active=null` plus a non-empty queue is the only
signal we have, and the schema does not store the 1.5 sub-state. Accept the
small ambiguity rather than parse `queue-rationale.md` presence on every
tick.

`<slug>` is the active quest slug (basename of `quest.sh dir`). Truncated
the same way as the feature slug.

### 3.3 No active cycle

When `quest.sh has-active` exits non-zero (no `quest/active.md`, or
`status != active`):

```
mo-workflow · idle
```

### 3.4 Outside an mo-workspace

When the current project has no `millwright-overseer/` data root, the
script must print **nothing** (empty output). Claude Code is also used in
repos that don't have this plugin configured; we don't want a
"mo-workflow · idle" string leaking into those windows.

**Detection.** Anchor to Claude Code's status-line stdin JSON, NOT to
`$PWD`. Per the docs, every status-line invocation receives a JSON
payload on stdin with these always-present fields:

- `workspace.project_dir` — directory where Claude Code was launched.
- `workspace.current_dir` — current directory (may differ from
  `project_dir` if the overseer `cd`'d during the session).
- `cwd` — same value as `workspace.current_dir`, preserved for
  back-compat.

Use `workspace.project_dir` to resolve a relative `MO_DATA_ROOT` /
`CLAUDE_PLUGIN_USER_CONFIG_data_root` / default `millwright-overseer`
(see §5.1 for the precedence chain). Then probe:

```bash
[[ -f "$data_root/quest/active.md" ]] || { echo ""; exit 0; }
```

This replaces an earlier draft of this plan that referred to a fictitious
`quest.sh init-pointer-path` helper. The pointer file is the canonical
"is this an mo-workspace" marker — `quest.sh init-pointer` writes it
during `/mo-init`, so its presence is exactly equivalent to "this project
ran mo-init at least once."

### 3.5 Error / unreadable state

If `progress.md` exists but is unparseable (corrupt frontmatter, schema
mismatch), render:

```
mo-workflow · <slug> · progress.md unreadable
```

Never `exit 1` — Claude Code prints the script's stderr on failure, which
disrupts the prompt. Always `exit 0`.

## 4. Stage-name mapping

The names come from `docs/workflow-spec.md` "Stages at a glance" and the
slash-command descriptions. Kept short for the status bar.

| `current-stage` | Name shown                    | Source of truth                                        |
| --------------: | ----------------------------- | ------------------------------------------------------ |
| `null` (active=null, queue non-empty)         | `quest generated`             | `/mo-run` produced the cycle; no feature activated yet |
| 2               | `blueprint`                   | `/mo-apply-impact` activated the feature              |
| 3               | `implementation`              | `/mo-plan-implementation` advanced 2→3                 |
| 4               | `impl-resumed`                | Resume Handler advanced 3→4 (drift check)              |
| 5               | `overseer-review`             | `/mo-continue` advanced 4→5 (or 3→5 skip)              |
| 6               | `review-session`              | `/mo-review` advanced 5→6                              |
| 7               | `review-completed`            | Review-Resume Handler advanced 6→7 (or 5→7 skip)       |
| 8 (transient)   | `finalizing`                  | `/mo-complete-workflow` is mid-finalize                |

**Stage 8 caveat.** Per `commands/mo-complete-workflow.md:13`, stage 8 is
"conceptual — it is not a persisted `current-stage` value; `progress.sh
finish` sets `active=null` rather than incrementing the counter to 8."
The `current-stage` enum in the schema does include `8` for forward-compat,
but we will rarely observe it on disk. The mapping line exists so a tick
that races with `progress.sh finish` doesn't show "Stage ?".

The mapping lives in the script as a `case` — not in a separate config
file, since it changes only when the workflow spec changes.

## 5. Files

```
scripts/info-bar.sh                new — pull-only renderer; reads stdin JSON; sub-50ms
commands/mo-init-status-bar.md     new — slash command; writes wrapper + statusLine block
commands/mo-init.md                edit — add Step 5.5 that calls /mo-init-status-bar
docs/stage-info-bar/plan.md        this file
README.md                          +1 section: "Status line (opt-in)"
```

Generated at install time (NOT shipped in the plugin):

```
<project>/.claude/mo-stage-info-bar.sh        wrapper with absolute plugin root baked in
<project>/.claude/settings.local.json         statusLine → wrapper (machine-local)
   (or ~/.claude/{mo-stage-info-bar.sh,settings.json} with --user)
   (or <project>/.claude/settings.json         with --project-shared, warned)
```

That is the entire surface area. No hook script, no schema, no template.

### 5.1 `scripts/info-bar.sh`

Pure pull-only renderer. No state, no writes, no logs. Always exits 0.

**Hot path is one Python call.** Do NOT call `mo_fm_get` from this
script. `mo_fm_get` (in `scripts/internal/common.sh:162`) shells to `yq`
per field via an awk + yq pipeline; reading `active`, `active.feature`,
and `active.current-stage` would mean three separate `yq` processes per
status-line tick.

**Runtime budget.** Aim for ≤100ms typical, ≤150ms max. macOS python3
cold-start alone is ~45–75ms, so a sub-50ms target (inherited from the
deleted v0.5.0 plan) is unreachable on Mac without dropping python
entirely. The status line is event-driven (next assistant message, vim
toggle, /compact, permission change — not a tight refresh loop), so
≤150ms is imperceptible to the user. Mitigations applied: invoke
`python3 -S -I` (skip site init, isolate user-site) to shave ~35ms off
cold-start; one python invocation, not two; no pyyaml import.

Likewise, do NOT call `quest.sh has-active` or `quest.sh dir` —
each invocation forks a Bash subshell that re-sources `common.sh` and
re-resolves data root. Resolve once, in this script, then read files
directly.

**Responsibilities (in order)**:

1. Read the entire stdin payload (Claude Code's status-line JSON). It is
   small; a single `cat` is fine.
2. In Bash, resolve `data_root` using this precedence chain (mirrors
   `mo_data_root` in `common.sh` but anchors relative paths to
   `workspace.project_dir` from the stdin payload, NOT `$PWD`):
   - If `$MO_DATA_ROOT` is absolute → use it.
   - Else if `$MO_DATA_ROOT` is relative → resolve against
     `workspace.project_dir`.
   - Else if `$CLAUDE_PLUGIN_USER_CONFIG_data_root` is absolute → use it.
   - Else if relative → resolve against `workspace.project_dir`.
   - Else → `<project_dir>/millwright-overseer`.
3. Probe for the workspace marker:
   `[[ -f "$data_root/quest/active.md" ]] || { echo ""; exit 0; }`
4. Hand off to a single `python3 -` invocation that:
   - Reads `$data_root/quest/active.md` frontmatter.
   - Branches on `status`: missing/`archived`/`none` → print
     `mo-workflow · idle`.
   - Otherwise reads `$data_root/quest/<slug>/progress.md` frontmatter.
   - Branches on `active`:
     - `null` (or missing) → print `mo-workflow · cycle <slug-short> ·
       Stage 1 · quest generated`.
     - object → look up `feature` and `current-stage`, look up the
       `<stage-name>` from §4's mapping, print the active-feature line.
   - On any parse error or missing file, prints the §3.5 fallback
     (`mo-workflow · <slug-short> · progress.md unreadable`) for the
     progress.md branch, or `mo-workflow · idle` for the active.md
     branch.
   - Returns exit 0 unconditionally.
5. Bash-side trap: any unexpected failure (e.g. python3 missing) falls
   through to `echo ""` + exit 0. Never propagate a non-zero exit —
   Claude Code surfaces stderr on a failing statusLine command and that
   would visually break the prompt.

**Why one Python process, not yq.** Python cold-start (~45–75ms on
macOS) replaces three yq cold-starts (~30ms each, plus an awk in front
of each — ~120ms total). One python is faster, even after factoring in
its startup. The script also skips pyyaml entirely: a hand-rolled
regex/line parser handles the few specific keys we read (`slug`,
`status`, `active.feature`, `active.current-stage`) and saves the
~30ms pyyaml import. The schema for those keys is simple enough that
hand-rolling is bug-free in <40 lines.

**File layout.** Bash prologue is small (~25 lines: stdin read,
data-root resolution, marker probe, python heredoc invocation). The
Python heredoc carries the rendering logic and the §4 stage-name table
as a literal `dict`. Total target: ~120 LOC including comments.

**Permissions.** `chmod +x`, shebang `#!/usr/bin/env bash`,
`set -euo pipefail` inside a guarded `main()` so any unexpected failure
still falls through to `exit 0`.

### 5.2 `README.md` addition

A short section under "Optional companions":

> **Status line (opt-in).** Run `/mo-init-status-bar` once per machine
> and Claude Code will show the current mo-workflow stage at the bottom
> of the window. The command writes a small wrapper script
> (`.claude/mo-stage-info-bar.sh`) and points your machine-local
> `.claude/settings.local.json` at it. The line refreshes on every
> Claude Code event — no hook, no sidecar. Outside an mo-workspace it
> prints nothing (the bar collapses cleanly).
>
> `/mo-init` offers to do this automatically at the end of the wizard;
> the standalone command exists for re-running on other machines, after
> resetting settings, or after a marketplace plugin upgrade if the
> wrapper's fast-path resolution can't find the new install.
>
> Flags: `--user` writes to `~/.claude/`; `--project-shared` writes to
> the committed `.claude/settings.json` (warned — the wrapper path is
> machine-specific).

### 5.3 `commands/mo-init-status-bar.md` (new slash command)

Stand-alone, idempotent slash command. Either invoked by the overseer
directly (`/mo-init-status-bar`) or auto-invoked by `/mo-init` Step 5.5.

**Critical fact this design depends on.** Per the official statusLine
docs, **`$CLAUDE_PLUGIN_ROOT` is NOT expanded** in the
`statusLine.command` string. The command runs in a plain shell where any
plugin-provided variables are unset. So we cannot wire
`"$CLAUDE_PLUGIN_ROOT/scripts/info-bar.sh"` directly. Two consequences:

1. We need a small **wrapper script** with an absolute path captured at
   install time. The wrapper exec's `info-bar.sh`.
2. Because the wrapper path is machine-specific, the default settings
   target must be **machine-local** — not a file the user might commit.

**What the command does**

1. **Resolve the absolute plugin root** at install time, in this order:
   - `$CLAUDE_PLUGIN_ROOT` (set by Claude Code while a slash command is
     running — this is the high-confidence path; the limitation only
     applies to the statusLine command, not slash commands).
   - Fallback: scan `$HOME/.claude/plugins/` for any
     `**/.claude-plugin/plugin.json` whose `name` field equals
     `millwright-overseer-development-machine`, pick the most recent
     mtime.
   - If both fail, error out with a clear message: "Cannot resolve
     plugin root. Re-run from a Claude Code session with the plugin
     loaded, or pass `--plugin-root <abs-path>`."
2. **Pick the wrapper destination**, defaulting to a path next to the
   settings file we're going to wire (so the two move together):
   - default → `<project_dir>/.claude/mo-stage-info-bar.sh`
   - `--user` → `$HOME/.claude/mo-stage-info-bar.sh`
   - `--project-shared` → `<project_dir>/.claude/mo-stage-info-bar.sh`
     (same path as default, but pairs with the shared settings file —
     see step 4)
3. **Write the wrapper** with the resolved absolute plugin root baked
   in:
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail

   plugin_root="<absolute path captured at install time>"

   # Fast path: captured root still valid.
   if [[ -x "$plugin_root/scripts/info-bar.sh" ]]; then
     exec "$plugin_root/scripts/info-bar.sh"
   fi

   # Fallback: marketplace upgrades may have moved the plugin. Scan for
   # the most-recently-modified install whose plugin.json names this
   # plugin. Silent on miss — Claude Code prints the script's output
   # verbatim, so leaking a diagnostic into the status line is worse than
   # printing nothing.
   resolved="$(python3 - "$HOME/.claude/plugins" <<'PY' 2>/dev/null || true
   import glob, json, os, sys
   root = sys.argv[1]
   best = None  # (mtime, plugin_root)
   for p in glob.iglob(os.path.join(root, '**', '.claude-plugin', 'plugin.json'), recursive=True):
       try:
           if json.load(open(p)).get('name') != 'millwright-overseer-development-machine':
               continue
           pr = os.path.dirname(os.path.dirname(p))
           if not os.access(os.path.join(pr, 'scripts', 'info-bar.sh'), os.X_OK):
               continue
           m = os.path.getmtime(p)
           if best is None or m > best[0]:
               best = (m, pr)
       except Exception:
           continue
   if best:
       print(best[1])
   PY
   )"
   if [[ -n "$resolved" && -x "$resolved/scripts/info-bar.sh" ]]; then
     exec "$resolved/scripts/info-bar.sh"
   fi

   # Plugin missing — silently render empty.
   echo ""
   exit 0
   ```
   Permissions: `chmod 0755`. Atomic write via temp file + `os.replace`.
4. **Pick the settings target** — the key change from the previous
   draft. Default to **machine-local**, not committed shared config:
   - default → `<project_dir>/.claude/settings.local.json`
   - `--user` → `$HOME/.claude/settings.json`
   - `--project-shared` → `<project_dir>/.claude/settings.json` —
     **emits a warning** ("the wrapper at `<abs-path>` is
     machine-specific; collaborators on this repo will get a broken
     status line unless they run /mo-init-status-bar themselves") and
     requires confirmation before writing.
5. **Read the chosen settings file** (create as `{}` if absent), inspect
   `statusLine`:
   - Already points at our wrapper path → `✓ status line already
     wired`, exit 0.
   - Points elsewhere → print the existing value and ask `(o)verwrite /
     (k)eep / (p)rint snippet to wire manually`, default `k`. On `o`,
     replace; on `k`, exit without writing; on `p`, print the JSON
     snippet for manual merging.
   - Absent → write the block.
6. **Write** the `statusLine` block, with the **absolute wrapper path**
   (not `$CLAUDE_PLUGIN_ROOT`):
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "/abs/path/to/.claude/mo-stage-info-bar.sh"
     }
   }
   ```
   Uses `python3 -c` with the `json` module: read → mutate → write to
   sibling tempfile → `os.replace` (atomic). Other settings keys are
   preserved untouched.
7. **Print the reload-behavior note** (§11): the bar shows up on the
   next Claude Code event — no session restart required.

**Marketplace-upgrade policy.** The wrapper's fallback scan handles
moves in `~/.claude/plugins/` automatically. For installs outside that
tree (local-dev `claude --plugin-dir <path>` invocations, custom
locations), the policy is documented: "rerun `/mo-init-status-bar` after
plugin upgrades." The fallback scan is a best-effort convenience, not a
guarantee.

**Why a slash command instead of a Bash one-liner.** Editing the user's
`settings.json`, writing an executable wrapper, and resolving the plugin
root require enough decision-making that one-liner instructions in the
README would be error-prone. The command also handles overwrite
prompts, the absolute-path warning for `--project-shared`, and the
reload hint — all in one place the overseer can re-run.

**Failure modes**

- `.claude/` doesn't exist → `mkdir -p` first (project or user, as
  appropriate).
- `settings.json` is malformed JSON → refuse to write; print the parse
  error and ask the overseer to fix it manually. Never try to repair.
- Plugin root unresolvable → error per step 1.
- Wrapper destination not writable → error with the resolved path.

**Frontmatter**

```yaml
---
description: Wire the mo-workflow status line. Writes a wrapper script with the plugin's absolute path and points statusLine at it. Default target is .claude/settings.local.json (machine-local, not committed). Idempotent.
---
```

**Flags**

- `--user` — write to `~/.claude/mo-stage-info-bar.sh` and
  `~/.claude/settings.json`.
- `--project-shared` — write to `.claude/mo-stage-info-bar.sh` and
  `.claude/settings.json`. Warned because the wrapper's baked-in
  absolute path is machine-specific.
- `--plugin-root <abs>` — manual override for the resolution in step 1
  (escape hatch for unusual installs).

### 5.4 `commands/mo-init.md` edit — Step 5.5

After Step 5 (scaffold data folders) and before Step 6 (report and
hand off), insert:

> **Step 5.5 — Offer to wire the status line.**
>
> Ask once:
>
> ```
> Wire the mo-workflow status line now? (y/n)
>   Shows: mo-workflow · <feature> · Stage <N> · <stage-name>
>   Refreshes automatically — no hook, no token tracking.
>   Writes a wrapper to .claude/mo-stage-info-bar.sh and a statusLine
>   entry to .claude/settings.local.json (machine-local; not committed).
>   Skipped if you say n; you can run /mo-init-status-bar anytime later.
> ```
>
> - **`y`** → invoke `/mo-init-status-bar` (no flags — uses the
>   machine-local default) and let it run its own prompts (wrapper
>   resolution and overwrite-on-conflict logic lives there, not here).
> - **`n`** → skip silently. Mention `/mo-init-status-bar` once in
>   Step 6's "Optional companions" footer so re-running is discoverable.

The Step 5.5 prompt is intentionally separate from the Step 3 dependency
batch — `statusLine` wiring is per-machine config, not a dependency, and
mixing it into the same y/n would conflate "install software" with "edit
my settings".

## 6. Wiring (recap)

There is no plugin-manifest `statusLine` field — Claude Code does not
accept it from plugin packages, and the docs confirm `$CLAUDE_PLUGIN_ROOT`
is not expanded inside `statusLine.command` even if it were. The wiring is:

1. `/mo-init-status-bar` writes (a) a wrapper script with the absolute
   plugin path baked in, then (b) a `statusLine` block pointing at the
   wrapper's absolute path. Default targets are
   `.claude/mo-stage-info-bar.sh` + `.claude/settings.local.json`
   (machine-local). `--user` retargets `~/.claude/`. `--project-shared`
   retargets the committed `.claude/settings.json` after a confirmation
   prompt.
2. `/mo-init` Step 5.5 offers to invoke that command at the end of the
   first-run wizard.
3. The overseer can re-run `/mo-init-status-bar` at any time — on a new
   machine, after settings are reset, or after a marketplace plugin
   upgrade if the wrapper's fallback scan can't find the new install.

`/mo-doctor` is unchanged in this plan. (A future ticket may have it
detect missing wiring and suggest `/mo-init-status-bar`, but that is
out of scope here.)

## 7. Edge cases

- **Multiple worktrees.** Each Claude Code window receives its own
  `workspace.project_dir` in the stdin payload, so two parallel
  checkouts each render their own current stage. No locking required
  (read-only).
- **`progress.md` mid-write.** `progress.sh` writes via temp file +
  `os.replace`, so we either see the old or the new copy — never a torn
  read. The Python parser does not need a retry loop.
- **`quest/active.md` exists with `status=archived`.** The Python parser
  in §5.1 step 4 branches on `status`; `archived` (and `none`) collapse
  to `mo-workflow · idle`.
- **Schema migration.** If `current-stage` ever grows past 8, the
  Python `dict` default prints `Stage <N> · unknown`. Status line never
  breaks.
- **Workflow runs in a subdirectory.** The script anchors to
  `workspace.project_dir` from the stdin payload, NOT `$PWD`. This is
  what saves it from the failure mode the deleted v0.5.0 hook ran into
  (commit `38dd1a4`), where Claude Code's hook subprocess inherited a
  stale CWD. As long as the data root is at the project root (the only
  location `/mo-init` scaffolds), the bar renders correctly even if the
  overseer `cd`'d into a subdirectory mid-session.
- **Plugin moved by marketplace upgrade.** The wrapper's fast path uses
  the absolute plugin root captured at install time; if that path no
  longer exists, the wrapper scans `~/.claude/plugins/` for a current
  install. If the scan also fails (local-dev installs outside the
  user-cache tree), the wrapper prints empty and the overseer reruns
  `/mo-init-status-bar` per the documented policy.

## 8. Implementation steps

1. Add `scripts/info-bar.sh` per §5.1.
2. Add `commands/mo-init-status-bar.md` per §5.3.
3. Edit `commands/mo-init.md` per §5.4 (insert Step 5.5).
4. Add the README section per §5.2.
5. Smoke-test `info-bar.sh` directly. Feed it a synthetic stdin payload
   so we exercise the project_dir anchor:
   ```bash
   echo '{"workspace":{"project_dir":"/abs/path/to/repo","current_dir":"/abs/path/to/repo/sub"},"cwd":"/abs/path/to/repo/sub"}' \
     | scripts/info-bar.sh
   ```
   Cases:
   - `project_dir` has no `millwright-overseer/` → empty output.
   - `project_dir` has data root, no active quest → `mo-workflow · idle`.
   - Active cycle, `active=null` → `mo-workflow · cycle <slug> · Stage 1
     · quest generated`.
   - Active cycle, `current-stage=3` → `mo-workflow · <feat> · Stage 3
     · implementation`.
   - **From a subdirectory** — set `current_dir` to a child path of
     `project_dir`; the bar must still find the project-root data root
     and render correctly.
   - Corrupt `progress.md` frontmatter → §3.5 fallback line.
   - Time the round-trip; expect ≤100ms typical, ≤150ms max on macOS
     (python3 cold-start dominates).
6. Smoke-test `/mo-init-status-bar`:
   - No prior settings → wrapper written, `settings.local.json` written,
     both valid.
   - `statusLine` already points at our wrapper path → "already wired",
     no rewrite.
   - `statusLine` points elsewhere → prompt fires; `k` does nothing,
     `o` overwrites, `p` prints snippet.
   - `--user` writes to `~/.claude/{mo-stage-info-bar.sh,settings.json}`;
     project files untouched.
   - `--project-shared` warns about the machine-specific wrapper path
     and requires confirmation; on confirm, writes `.claude/settings.json`
     (not `.local.json`).
   - Wrapper resolution:
     - Fast path with `$CLAUDE_PLUGIN_ROOT` set works.
     - Force the plugin to a non-default location and verify the
       fallback scan in `~/.claude/plugins/` finds it.
     - Both unresolvable → clear error message.
   - Malformed JSON in target settings file → refuses to write;
     prints parse error.
7. Smoke-test `/mo-init` end-to-end: ensure Step 5.5 fires, declining
   skips cleanly, accepting wires the bar, and the bottom bar shows the
   correct line on the next Claude Code interaction.
8. Bump plugin version to `0.7.5` and ship.

No new schema, no new template, no new hook.

## 9. Why this is safe to land where v0.5.0 wasn't

| v0.5.0–v0.7.4 (removed)                        | This plan                                |
| ---------------------------------------------- | ---------------------------------------- |
| `PostToolUse(Bash)` hook on every shell call   | No hook                                  |
| Per-cycle `.stage-tokens.json` sidecar         | No sidecar                               |
| Per-cycle NDJSON `usage.log`                   | No log                                   |
| `/mo-info-bar` (token-math display wrapper)    | `/mo-init-status-bar` (one-time wiring   |
|                                                | only; no display logic, no token math)   |
| Token math (parsed Claude Code transcript)     | No math; reads `current-stage` integer   |
| Hook anchored to a stale `$PWD` (silent fail   | Script reads `workspace.project_dir`     |
| in `38dd1a4`)                                  | from the status-line stdin payload       |
| 1382 LOC removed when ripped out               | ~120 LOC `info-bar.sh` + ~80 LOC         |
|                                                | wrapper + slash command + 1 README block |

Remaining failure modes:

- Status line shows the wrong stage if the overseer mutates
  `progress.md` outside `progress.sh` — already a documented "do not do
  that" in `templates/progress.md.tmpl`.
- Status line goes blank after a marketplace plugin upgrade if the
  wrapper's fallback scan can't find the new install — recovered by
  rerunning `/mo-init-status-bar`.

## 10. Decisions taken (resolutions to questions raised during planning)

These were open during drafting. Recording the resolutions here so the
implementation has no ambiguity to re-litigate.

1. **Stage 1.5 rendering — fold into "Stage 1 · quest generated".**
   Distinguishing the queue-ordering-confirmation sub-state would require
   probing `queue-rationale.md` existence on every status-line tick.
   Cost outweighs the signal; the overseer is staring at the queue
   proposal in the chat anyway. The status line is for "where am I"
   awareness, not protocol-level disambiguation.
2. **Slug / feature truncation: 24 chars, with `…` suffix at 22.**
   Bounded by terminal width. Revisit only if a real feature name in the
   active workspace exceeds 24 characters during the smoke tests in §8;
   no point raising the limit for hypothetical names that don't exist
   yet.
3. **Stage 8 renders as `finalizing`.** Even though `current-stage=8` is
   rarely observed on disk (per `commands/mo-complete-workflow.md:13`,
   stage 8 is conceptual; `progress.sh finish` jumps straight to
   `active=null`), a status-line tick that races with the finalize
   write would otherwise show "Stage 8 · unknown". The `finalizing`
   label costs nothing and explains the brief flash.
4. **`--project-shared` keeps the warning + confirmation, does not
   refuse.** Tightly-controlled fleets where every machine has the
   plugin at the same path (think team-wide dotfiles, controlled-image
   dev environments) are a legitimate use case. Closing off
   `--project-shared` entirely would be paternalistic. The warning
   makes the trade-off explicit; the confirmation forces the overseer
   to acknowledge it.
5. **Most-recent-mtime wins when multiple plugin installs exist in the
   user-cache.** Both the wrapper's fallback scan and the slash
   command's install-time capture sort by `plugin.json` mtime and pick
   the newest. Reasoning: a marketplace upgrade or a manual reinstall
   is exactly the case the fallback exists for, and "newest install"
   matches user intent in those scenarios. An explicit version pin
   would defeat the fallback's purpose (the captured fast-path root
   already pins the install at the time `/mo-init-status-bar` ran).

## 11. Reload behavior — does the bar appear instantly?

**Short answer: no session restart needed; one user interaction is enough.**

Per the official Claude Code documentation
(<https://code.claude.com/docs/en/statusline.md>):

> Settings reload automatically, but changes won't appear until your next
> interaction with Claude Code.

So the sequence after the overseer runs `/mo-init-status-bar` is:

1. The command writes the wrapper script and the `statusLine` block to
   the chosen settings file (default `.claude/settings.local.json`,
   `~/.claude/settings.json` with `--user`, `.claude/settings.json` with
   `--project-shared`) and exits.
2. Claude Code re-reads the settings file automatically — no
   `/reload-plugins`, no `/config` action, no restart.
3. The bottom bar **does not appear yet** — the statusLine command is
   only invoked when Claude Code has something to render against (next
   assistant message, next tool call, next slash-command return, even
   toggling vim mode is enough).
4. As soon as any one of those happens, the bar is rendered. From there
   on, every status-line tick re-runs the wrapper, which `exec`s
   `info-bar.sh`, which reads `progress.md` and prints one line.

The reload behavior is identical for `.claude/settings.local.json`,
`.claude/settings.json`, and `~/.claude/settings.json` — Claude Code
treats all three sources the same way for this purpose.

### What `/mo-init-status-bar` should print at the end

To set expectations, the command finishes with something like:

```
✓ wrote wrapper       → /abs/path/to/.claude/mo-stage-info-bar.sh
✓ wrote statusLine    → .claude/settings.local.json
The bar will appear on your next interaction with Claude Code (no restart needed).
If it doesn't show up after the next message, check that the wrapper is
executable and that the absolute plugin path baked into it still exists.
```

That covers the 99% case (instant on next message) and the 1% case
(plugin moved without a rerun, missing executable bit, etc.).
