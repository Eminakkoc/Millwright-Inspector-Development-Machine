# Info-bar implementation plan

Two related features built on a shared hook:

1. **Status-line widget** (the info-bar proper) — a Claude Code bottom-bar display showing the mo-workflow's per-stage token usage, always visible, updated on every stage transition.
2. **Per-cycle usage log** — an append-only NDJSON audit trail at `quest/<active-slug>/usage.log`, capturing tokens + main/sub-context occupancy at every stage advance, for retrospective analysis ("which stage actually used the most context?", "where did the budget go?").

Both are written by the same `PostToolUse` hook on stage transitions. The status line consumes the sidecar (small, fast); the overseer consumes the log via direct `jq` queries (or a future reporter).

## Display format

Two numbers, displayed separately:

- **Up to that point** — cumulative tokens spent in this cycle through and including the just-completed stage.
- **Current stage** — tokens spent in the just-completed stage alone.

Both numbers update whenever a stage advances. Between stages the displayed values are frozen (the last completed stage's snapshot stays visible).

Suggested rendering (single line, fits in a typical terminal width):

```
mo · cycle <slug-short> · stage <N> ✓ │ up to that point: 247k │ current stage: 52k
```

Compact fallback when terminal width is tight:

```
mo · s<N> │ up to: 247k │ this stage: 52k
```

When no workflow is active (between cycles):

```
mo · no active cycle
```

When a cycle is active but no stage has completed yet (post-`/mo-run`, pre-stage-2 advance):

```
mo · cycle <slug-short> · stage 1 ✓ │ up to that point: 109k │ current stage: 109k
```

When a feature is active (stage 2 onward), the rendering includes the feature name. With a single-feature cycle this is mostly redundant with the slug; with multi-feature cycles it disambiguates which feature's stage is being reported:

```
mo · cycle <slug-short> · feature <X> · stage 3+4 ✓ │ up to that point: 247k │ current stage: 157k
```

Cycle-level stages 1 and 1.5 have no active feature — the rendering omits the `· feature <X>` segment (the sidecar's `current_feature` is `null`). The collapsed stage-3+4 row is rendered as `stage 3+4 ✓` (matching the sidecar's `current_stage` string).

## Architecture — four pieces

The split exists because Claude Code's status line refreshes constantly (every few seconds), so heavy work must happen elsewhere. The hook does all expensive work once per stage advance; the sidecar holds the current snapshot for the status line; the usage log preserves the full per-stage history (tokens + main/sub context) for retrospective analysis; the status line is a dumb display layer.

### 1. Hook — the **producer**

A `PostToolUse` hook with `Bash` matcher. Fires after every Bash invocation, but acts only when the command was a stage transition.

**Hook input contract.** Claude Code passes the tool-call payload as JSON on stdin (NOT as `$TOOL_INPUT`). The bash command lives at `tool_input.command`. This matches the existing `hooks/validate-on-write.sh` pattern in this repo (which reads stdin and parses `tool_input.file_path`). Step 1 verifies the exact field name, but stdin-JSON is the working assumption — not env vars.

**Trigger detection.** The hook parses `tool_input.command` and distinguishes two trigger classes — **row-writing triggers** (each one writes a sidecar row + log record), and **anchor-only triggers** (update sidecar metadata for status-line display, no row written).

**Row-writing triggers:**

| Command | Stage label written | Feature attribution |
|---|---|---|
| `progress.sh init <todo-list-id> <features...>` | `"1"` | `null` (cycle-level) |
| `progress.sh reorder <features...>` | `"1.5"` | `null` (cycle-level) |
| `progress.sh advance 2` | `"2"` | `active.feature` (set by the prior `activate`) |
| `progress.sh advance-to 3 5` | `"3+4"` (collapsed — see below) | `active.feature` |
| `progress.sh set sub-flow=none manual-test-state=complete` | `"5-mt"` (manual-test sub-flow finalized — see "Manual-test sub-flow" below) | `active.feature` |
| `progress.sh advance 5` | `"5"` (with-findings path; review session begins next) | `active.feature` |
| `progress.sh advance-to 5 7` | `"5"` (no-findings path; review skipped entirely) | `active.feature` |
| `progress.sh advance-to 6 7` | `"6"` (review session completed) | `active.feature` |
| `progress.sh finish` | `"8"` | `completed[-1]` (read post-state — `finish` cleared `active`) |

**Anchor-only triggers** (update sidecar's `current_feature` and/or `current_stage` for status-line display, but DO NOT write a row):

| Command | Side effect |
|---|---|
| `quest.sh start` | No-op for token attribution. Cycle folder is created here, but the next trigger (`progress.sh init`) is what writes the stage-1 row. |
| `progress.sh activate <feature>` | Update sidecar `current_feature` to the activated feature. **No row written.** Stage 2's actual completion row is written later by `progress.sh advance 2`. |
| `progress.sh set sub-flow=manual-testing manual-test-state=running` | Update sidecar `current_stage` to `"5-mt"` so the status line shows the manual-test sub-flow has begun. **No row written.** The work is captured later when `progress.sh set sub-flow=none manual-test-state=complete` fires. |
| `progress.sh set manual-test-state=skipped manual-test-failure-policy=none` | Phase declined at the stage-5 prompt OR via `--discard-existing`. **No row written and no anchor change** — no manual-test work happened, so the eventual stage-5 row absorbs the planning-prompt tokens normally. |

For any other Bash invocation, the hook exits silently and instantly.

**Trigger pattern matching for `progress.sh set`.** `progress.sh set` accepts multiple `field=value` pairs in a single invocation. The hook matches on the EXACT field-value combinations listed in the tables (any order, with possible additional pairs that are ignored — though the workflow does not currently mix manual-test sets with unrelated sets in a single call). Use a regex that anchors on the field-value pair: `progress\.sh\s+set\b.*\bsub-flow=none\b.*\bmanual-test-state=complete\b` (and the symmetric `manual-testing/running` pattern). Pure `progress.sh set` invocations that don't match any manual-test pattern (e.g., `progress.sh set base-commit=...`) are silently ignored — they're intra-stage state writes, not stage transitions.

**Why `activate` is anchor-only, not a row-writing trigger.** `progress.sh activate` runs at the START of `/mo-apply-impact` (`commands/mo-apply-impact.md:46-47`) — before blueprint generation work happens. Stage 2 actually COMPLETES later, when `/mo-plan-implementation` calls `progress.sh advance 2` (`commands/mo-plan-implementation.md:172-174`). Treating `activate` as a row-writing trigger would either double-write stage 2 or attribute only the activation/setup tokens to stage 2 (missing the blueprint-generation work). Treating it as anchor-only is correct: stage-2 row writes once, when `advance 2` fires, covering all tokens since the prior trigger.

**Stage 4 — conceptual, never persisted.** Per `docs/workflow-spec.md` §"Stage 4", `current-stage=4` is never persisted in `progress.md` — the Resume Handler ends with `progress.sh advance-to 3 5`, collapsing stages 3 and 4 into a single transition. The hook records the combined work as one row with `stage: "3+4"`. Splitting them would require explicit logical markers in the Resume Handler, which the workflow intentionally avoids.

**Manual-test sub-flow (`"5-mt"`).** Stage 5 is widened by `docs/manual-testing/plan.md` to "overseer evaluation" — an optional manual-test sub-flow runs BEFORE findings authoring. While the sub-flow is active, `progress.md` carries `sub-flow=manual-testing` and `manual-test-state=running`; the LAST mutation of `/mo-manual-test-run`'s auto-seed loop (and Branch B finalization, and Branch C `--finalize-skipped` finalization) is `progress.sh set sub-flow=none manual-test-state=complete`. The hook treats the entry mutation as anchor-only (sets the sidecar's `current_stage` to `"5-mt"` so the status line reflects the active sub-flow) and the exit mutation as row-writing (writes a `"5-mt"` row capturing all tokens consumed during the sub-flow). The subsequent stage-5 row (`advance 5` or `advance-to 5 7`) then captures only the *post-manual-test* findings-authoring + Overseer Handler tokens — meaningfully cleaner attribution than rolling everything into a single `"5"` row.

**Multiple `"5-mt"` rows per feature are valid.** A single feature may legitimately fire the manual-test finalization more than once: `/mo-manual-test-run --seed-only` re-trigger after observation edits writes its own finalize, as does `--finalize-skipped`. Each finalize emits a row; consumers analyzing per-feature totals must sum across all `"5-mt"` rows in the feature's window. The status line shows the most recent. The skipped-phase path (overseer answered `n` to "generate plan?" or used `--discard-existing`) writes NO `"5-mt"` row — the eventual stage-5 row absorbs the planning-prompt tokens.

**Stage 7 — transitional, never a row label.** Stage 7 is reached only via `advance-to 5 7` (no findings) or `advance-to 6 7` (review completed), both of which immediately auto-fire `/mo-complete-workflow`. No work is attributed to stage 7 itself. The hook writes the from-stage label (`"5"` or `"6"`); the stage-7 reach is implicit. The next row is `"8"` (written by `finish`).

**Pre-state read for `finish`.** `progress.sh finish` clears `active` and appends the just-finished feature to `completed`. By the time PostToolUse fires, `active` is gone — so the hook reads `completed[-1]` from `progress.md` to identify the feature attribution for the stage-8 row.

**`init` and `reorder` are cycle-level (no active feature).** Stages 1 and 1.5 happen before any feature is activated. The hook records these rows with `feature: null`. Per-feature attribution begins at the next `progress.sh activate` (which is anchor-only) and is realized in the first per-feature row at `advance 2`.

**Work performed when triggered:**

1. Determine logical stage boundary from the parsed command (which row to write).
2. Resolve the feature attribution: `active.feature` for stages 2–7, `completed[-1]` for stage 8 (`finish`), `null` for stages 1 and 1.5.
3. Read the current Claude Code session transcript (JSONL at `~/.claude/projects/<project-hash>/<session-id>.jsonl`).
4. Sum `input_tokens` + `output_tokens` (and cached variants) across all assistant turns since the last recorded stage marker timestamp.
5. Capture the main-session's most-recent-turn input total as the **main-context occupancy snapshot**.
6. Discover any sub-agent transcripts in the stage's time window and aggregate their tokens + context sizes.
7. Update the sidecar (see below) with the new stage row.
8. Append one full-detail record (tokens + main/sub context + feature) to the **usage log** (see below).
9. Print a brief one-line confirmation to stdout (which surfaces as a small in-chat note — optional; can be suppressed).

The hook is the slow path. It does the transcript parse + math + sub-context discovery; it runs at most once or twice per stage.

### 2. Sidecar — the **state file**

A small JSON file the hook writes and the status line reads.

**Location.** `quest/<active-slug>/.stage-tokens.json` — co-located with the active cycle's quest files. Reasons for this location:

- Rotates with the cycle automatically; archived alongside the rest at stage 8.
- No stale state from old cycles bleeds into a new cycle (the slug changes).
- Survives session breaks within a cycle (state persists to disk).
- **Preserved across `/mo-abort-workflow`** — abort is a feature-level reset (reverts IMPLEMENTING todos, clears `implementation/`, resets `progress.md`), not a cycle-level reset. The quest subfolder stays intact (per `commands/mo-abort-workflow.md:52`), and the sidecar is part of that subfolder. The cycle-wide token tally therefore continues uninterrupted across an abort/retry of an active feature.

**Format.**

```json
{
  "cycle_slug": "2026-05-12-payments-meeting+audit-log",
  "session_id": "<claude-code-session-uuid>",
  "current_stage": "3+4",
  "current_feature": "payments",
  "current_stage_tokens": 157191,
  "up_to_that_point_tokens": 247891,
  "last_advance_at": "2026-05-12T14:23:01Z",
  "stages": [
    { "stage": "1",    "feature": null,        "tokens": 61000,  "completed_at": "2026-05-12T13:15:02Z" },
    { "stage": "1.5",  "feature": null,        "tokens": 4900,   "completed_at": "2026-05-12T13:18:14Z" },
    { "stage": "2",    "feature": "payments",  "tokens": 24800,  "completed_at": "2026-05-12T13:35:48Z" },
    { "stage": "3+4",  "feature": "payments",  "tokens": 157191, "completed_at": "2026-05-12T14:23:01Z" },
    { "stage": "5-mt", "feature": "payments",  "tokens": 89240,  "completed_at": "2026-05-12T15:01:33Z" }
  ]
}
```

Field notes:

- `stage` is a string — most rows are integer-as-string (`"1"`, `"2"`, …), the half-stage `"1.5"`, the collapsed Resume-Handler transition `"3+4"`, or the manual-test sub-flow row `"5-mt"`. Using a string consistently avoids JSON-number-vs-string surprises in jq queries.
- `feature` is the kebab-case feature name for stages 2–8 (including `"5-mt"`), or `null` for cycle-level stages 1 / 1.5. Stage numbers REPEAT across features in a multi-feature cycle (e.g., feature A's stage 2 and feature B's stage 2 are different rows, disambiguated by `feature`). The manual-test row label `"5-mt"` may also appear MORE than once per feature when `--seed-only` re-triggers fire — each finalize writes a row.
- `current_feature` mirrors the just-completed row's `feature` (so the status line can render `cycle <slug> · feature <X> · stage <N>`).
- `up_to_that_point_tokens` is `sum(stages[].tokens)` cycle-wide, across all features. `current_stage_tokens` mirrors `stages[-1].tokens`.

**Atomicity.** The hook writes via temp file + rename so a crash mid-write doesn't leave a half-written sidecar.

### 3. Usage log — the **append-only audit trail**

A second state file the hook writes alongside the sidecar. Where the sidecar holds the current snapshot for status-line consumption, the usage log preserves the full per-stage history for retrospective analysis — "which stage actually used the most context?", "how did the main context evolve from stage 3 to 7?", "did sub-agents during stage 3 inflate effective consumption?".

**Location.** `quest/<active-slug>/usage.log` — same lifecycle as the sidecar: rotates with the cycle, archives at stage 8, isolated per-cycle so no bleed-through, and **preserved across `/mo-abort-workflow`** (the quest subfolder stays intact during a feature-level abort; cycle-wide history continues uninterrupted).

**Why a separate file from the sidecar.** The sidecar is overwritten on every update — it shows current state but loses history. The log is append-only — every stage's full detail is preserved permanently. Different jobs, different formats:

- Sidecar = "what should the status line show right now?" (small, structured, frequently re-read).
- Log = "what happened across this entire cycle?" (grows with the cycle, written once per stage, read rarely but in full when read).

**Format.** Newline-delimited JSON (NDJSON), one record per stage advance:

```jsonl
{"ts":"2026-05-12T13:15:02Z","stage":"1","feature":null,"tokens":{"input":...,"output":...,"cache_creation":...,"cache_read":...,"total":...},"context":{"main":...,"sub":[...]}}
{"ts":"2026-05-12T13:35:48Z","stage":"2","feature":"payments","tokens":{...},"context":{...}}
{"ts":"2026-05-12T14:23:01Z","stage":"3+4","feature":"payments","tokens":{...},"context":{...}}
```

Per-record fields:

- `ts` — ISO timestamp of the stage-advance event.
- `stage` — stage label, always a string. Valid values: `"1"`, `"1.5"`, `"2"`, `"3+4"` (the collapsed Resume Handler transition), `"5-mt"` (manual-test sub-flow finalized — only present when the overseer ran `/mo-manual-test-run`), `"5"`, `"6"`, `"8"`. **Stage `"4"` and `"7"` never appear** as row labels — stage 4 is folded into `"3+4"`; stage 7 is transitional and folded into the from-stage row (`"5"` or `"6"`). When a manual-test phase ran, the subsequent `"5"` row captures only the post-manual-test findings-authoring + Overseer Handler tokens (NOT the manual-test work, which lives in the preceding `"5-mt"` row).
- `feature` — kebab-case feature name for stages 2–8, or `null` for cycle-level stages 1 / 1.5. **Required for disambiguation in multi-feature cycles** — without it, the same stage number appearing twice (once per feature) would be ambiguous. Stage 8 records read `feature` from `completed[-1]` of `progress.md` (because `finish` clears `active` before the hook fires).
- `tokens` — breakdown for the just-completed stage:
  - `input` — uncached input tokens.
  - `output` — output tokens.
  - `cache_creation` — cache write tokens.
  - `cache_read` — cache hit tokens.
  - `total` — sum of the four above (matches the sidecar's stage `tokens` value).
- `context` — context-window occupancy snapshots at the stage-advance moment:
  - `main` — main session's active context size: sum of `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` for the most recent assistant turn. Represents how full the main context window was when the stage advanced.
  - `sub` — array of sub-context summaries, one entry per sub-agent / fork active during this stage:
    - `session_id` — sub-agent's session UUID.
    - `kind` — `"subagent"` (Task with `subagent_type`), `"fork"` (Task without `subagent_type`), or `"unknown"`.
    - `started_at` — sub-agent launch timestamp (ISO).
    - `tokens_total` — total tokens consumed by the sub-agent during this stage's window.
    - `context_size` — sub-agent's most-recent-turn input size (its context-window occupancy at hand-off time).

**Multi-feature cycles.** A cycle that processes N features writes between (2 + 4N) and (2 + 6N) records: 2 cycle-level (stages 1, 1.5) plus 4 to 6 per feature, depending on whether the manual-test sub-flow ran and whether findings were authored.

- **No-findings, no manual-test (4 rows per feature):** `"2"`, `"3+4"`, `"5"` (`advance-to 5 7`), `"8"`.
- **No-findings + manual-test (5 rows per feature):** `"2"`, `"3+4"`, `"5-mt"`, `"5"` (`advance-to 5 7`), `"8"`.
- **With-findings, no manual-test (5 rows per feature):** `"2"`, `"3+4"`, `"5"` (`advance 5`), `"6"` (`advance-to 6 7`), `"8"`.
- **With-findings + manual-test (6 rows per feature):** `"2"`, `"3+4"`, `"5-mt"`, `"5"` (`advance 5`), `"6"` (`advance-to 6 7`), `"8"`.

Multiple `"5-mt"` rows for the same feature are valid (e.g., a `--seed-only` re-trigger after observation edits, or a `--finalize-skipped` after pause). Records are appended in chronological order; consumers can group by `feature` to slice per-feature totals, or stay at cycle granularity by ignoring `feature` and summing across all rows.

**Tokens vs. context — the distinction.** `tokens` measures throughput (cumulative bytes through the model — proxy for cost). `context.main` and `context.sub[].context_size` measure occupancy (how full the context window was at the moment of stage advance — proxy for "session budget remaining"). Both matter; they answer different questions. A stage that re-uses heavily cached context can have very high `tokens.cache_read` (throughput) but a stable `context.main` (occupancy).

**Sub-context discovery.** Sub-agents launched via the `Task` tool create their own session JSONL transcripts under `~/.claude/projects/<project-hash>/`. The hook discovers them by:

1. Listing JSONL files in the project's session directory whose mtime falls between `last_advance_at` and now.
2. Filtering to those whose first record contains a `parentUuid` referencing the main session (sub-agent transcripts carry this back-reference).
3. Aggregating per-transcript token totals and reading the last turn's input size for `context_size`.
4. Resolving `kind` by inspecting the parent's `Task` tool-use record (`subagent_type` field present → `"subagent"`, absent → `"fork"`, ambiguous → `"unknown"`).

If sub-agent discovery fails (e.g., field renames across Claude Code versions), the hook degrades gracefully: write the record with `sub: []` and `sub_discovery_failed: true`.

**Atomicity.** Append uses a single `>>` write. On POSIX filesystems, writes under `PIPE_BUF` (4096 bytes) are atomic — one record fits comfortably under that even with full sub-context detail. A crash mid-write leaves the file with whole records only.

**Read path.** The status line does NOT read the log — it reads only the sidecar (small, fast, structured for sub-50ms parsing). The log is consumed by the overseer via direct `jq` queries during retrospective analysis, or by a future `mo-stage-stats` reporter command if real demand emerges.

### 4. Status line — the **consumer**

A bash script registered in `.claude/settings.json` under `statusLine`. Claude Code re-invokes it constantly; the script must complete in milliseconds.

**Work performed:**

1. Read `quest/active.md` to find the active cycle slug. If no active cycle, print `mo · no active cycle` and exit.
2. Read `quest/<slug>/.stage-tokens.json`. If absent, print `mo · cycle <slug-short> · pre-stage-1` and exit.
3. Pull `current_stage`, `current_feature`, `current_stage_tokens`, `up_to_that_point_tokens` from the sidecar. Render: `mo · cycle <slug-short>` then optionally `· feature <X>` (skip when `current_feature` is null), then `· stage <S> ✓ │ up to that point: <Nk> │ current stage: <Mk>`.
4. Format the two numbers and print one line.

The status line never parses transcripts, never does math beyond pretty-printing. It's a dumb display layer.

## Implementation steps

In dependency order:

### Step 1 — Verify hook + transcript contracts

Spawn the `claude-code-guide` agent to confirm:

- **Hook input shape.** Working assumption is **stdin JSON** (`tool_input.command` for Bash matchers) — same pattern as the existing `hooks/validate-on-write.sh`. Confirm the field name and structure. Do NOT plan around `$TOOL_INPUT` env vars unless verification proves them current.
- **Sub-agent transcript shape.** Confirm sub-agent JSONL files land under the same `~/.claude/projects/<project-hash>/` directory as the main session, and that the back-reference field is `parentUuid` (working assumption).
- **JSONL transcript field names** for input/output token counts (per-turn `usage.input_tokens` / `output_tokens` / `cache_creation_input_tokens` / `cache_read_input_tokens` is the working assumption).
- **Status line config keys** in `settings.json` (`statusLine.type: "command"` + `statusLine.command: "<path>"` is the working assumption).

Also re-verify (no agent needed — read this repo's source):

- The full set of stage-transition commands listed in the Hook section's trigger table — `quest.sh start`, `progress.sh init / reorder / activate / advance / advance-to / finish / set`. Cross-check against `scripts/progress.sh` and `scripts/quest.sh` to confirm command names and arg shapes haven't drifted.
- That `progress.sh advance-to 3 5` is the only path that collapses two stages into one transition (so `"3+4"` is the only multi-stage label the hook needs to handle).
- The manual-test `progress.sh set` command shapes used by `/mo-manual-test-plan` and `/mo-manual-test-run`:
  - `progress.sh set sub-flow=manual-testing manual-test-state=running` — entry to manual-test sub-flow (anchor-only).
  - `progress.sh set sub-flow=none manual-test-state=complete` — exit (row-writing, label `"5-mt"`).
  - `progress.sh set manual-test-state=skipped manual-test-failure-policy=none` — phase declined (silent no-op).
  - `progress.sh set manual-test-failure-policy=auto-seed` / `manual` — intra-flow policy promotion (silent no-op; not a stage transition).

This step is fast and makes the rest of the implementation accurate.

### Step 2 — Implement the hook script

`scripts/track-stage-tokens.sh`. Responsibilities:

1. **Read stdin JSON** (Claude Code's PostToolUse contract — same pattern as `hooks/validate-on-write.sh`). Extract `tool_input.command`. Exit silently if parsing fails or the command isn't a stage-transition trigger from the table in the Hook section.
2. **Classify the trigger** as either anchor-only or row-writing (per the Hook section's tables):
   - `quest.sh start` → anchor; no row written.
   - `progress.sh activate <feature>` → anchor; update sidecar `current_feature`; no row written.
   - `progress.sh set sub-flow=manual-testing manual-test-state=running` → anchor; update sidecar `current_stage` to `"5-mt"`; no row written. (Pattern: regex-match the command for both `sub-flow=manual-testing` and `manual-test-state=running` field-value pairs in any order.)
   - `progress.sh set manual-test-state=skipped manual-test-failure-policy=none` → silent no-op; no row written and no anchor change. The phase was declined; no manual-test work happened.
   - `progress.sh init` → row, stage `"1"`, feature `null`.
   - `progress.sh reorder` → row, stage `"1.5"`, feature `null`.
   - `progress.sh advance 2` → row, stage `"2"`, feature = `active.feature`.
   - `progress.sh advance-to 3 5` → row, stage `"3+4"` (collapsed), feature = `active.feature`.
   - `progress.sh set sub-flow=none manual-test-state=complete` → row, stage `"5-mt"` (manual-test sub-flow finalized), feature = `active.feature`. (Pattern: regex-match the command for both `sub-flow=none` and `manual-test-state=complete` field-value pairs in any order.) Multiple `"5-mt"` rows per feature are valid (re-runs via `--seed-only` or `--finalize-skipped`); each finalize emits a row.
   - `progress.sh advance 5` → row, stage `"5"` (with-findings path), feature = `active.feature`. **When a `"5-mt"` row preceded this in the same feature's window**, the `"5"` row captures only post-manual-test tokens (findings authoring + Overseer Handler).
   - `progress.sh advance-to 5 7` → row, stage `"5"` (no-findings path; stage 7 reached but never labeled), feature = `active.feature`. Same post-manual-test-tokens semantics as above when `"5-mt"` preceded.
   - `progress.sh advance-to 6 7` → row, stage `"6"` (review-completed path), feature = `active.feature`.
   - `progress.sh finish` → row, stage `"8"`, feature = `completed[-1]` (post-state read, since `finish` cleared `active`).
   - Other `progress.sh set ...` invocations (e.g., `progress.sh set base-commit=...`, `progress.sh set manual-test-failure-policy=auto-seed`) → silent no-op; intra-stage state writes don't move the stage cursor.
3. Resolve the active cycle's quest dir via `quest.sh dir`. (This works during stages 1/1.5/2-onward as long as the cycle folder exists.)
4. Read or initialize `quest/<slug>/.stage-tokens.json`.
5. Locate the current Claude Code session transcript. Parse from the last recorded `last_advance_at` timestamp forward (or from session start if first stage).
6. Sum tokens across all assistant turns in that range, broken down by `input` / `output` / `cache_creation` / `cache_read` / `total`.
7. Capture the **main-context occupancy snapshot**: input-side total of the most recent assistant turn (`input_tokens + cache_creation_input_tokens + cache_read_input_tokens`).
8. **Discover sub-agent transcripts** whose mtime falls in the stage window (`last_advance_at` … now). For each: aggregate per-stage tokens; read its last-turn context size; classify `kind` from the parent's `Task` tool-use record.
9. Append a new `stages[]` row to the sidecar (with `stage`, `feature`, `tokens`, `completed_at`); update `current_stage`, `current_feature`, `current_stage_tokens`, `up_to_that_point_tokens`, `last_advance_at`. Atomic-write (temp + rename).
10. **Append one NDJSON record to `quest/<slug>/usage.log`** with `ts`, `stage`, `feature`, full token breakdown, plus `context.main` and `context.sub[]` snapshots. Single `>>` write (atomic under `PIPE_BUF`).
11. Print an optional one-line confirmation to stdout.

**Failure modes:**

- No active cycle / `quest.sh dir` returns nothing (e.g., running this hook in another repo, or before `quest.sh start` ran) → exit 0 silently; do not touch sidecar or log.
- Sidecar missing AND not a stage-1 trigger → exit 0 silently (don't try to recover mid-cycle from a missing sidecar).
- `progress.sh activate` / `advance` fired but `active.feature` cannot be read (corrupted progress.md) → write the row with `feature: null` and a `feature_lookup_failed: true` flag.
- `progress.sh finish` fired but `completed` is empty (shouldn't happen — finish errors out earlier — but defensively) → write the row with `feature: null` and a `feature_lookup_failed: true` flag.
- Transcript parse error → write a minimal `stages[]` sidecar row with `tokens: 0` and a `parse_error: true` flag (status line shows `?` for that stage); append a corresponding log record carrying `parse_error: true`.
- Sub-context discovery error → log record carries `sub: []` and `sub_discovery_failed: true`; sidecar is unaffected.
- Log append fails after sidecar write succeeded → don't roll back the sidecar; log a warning to stdout. The sidecar remains the source of truth for the status line; the log is best-effort.

### Step 3 — Implement the status line script

`scripts/info-bar.sh`. Responsibilities:

1. Resolve `data_root` via `data-root.sh`.
2. Read `quest/active.md` for the active slug. Empty → print `mo · no active cycle`, exit 0.
3. Read `<data_root>/quest/<slug>/.stage-tokens.json`. Missing → print `mo · cycle <slug-short> · pre-stage-1`, exit 0.
4. Format and print one line. Truncate slug to first 18 chars + `…` for compactness.
5. Total runtime budget: under 50ms. Avoid spawning python; use jq or a small bash parser.

### Step 4 — Wire the hook (and document the status-line opt-in)

The hook and the status line have **different distribution channels** because Claude Code treats them differently:

**4a. Hook — ship via `hooks/hooks.json`.** This plugin already distributes its existing hook (`hooks/validate-on-write.sh`) through `hooks/hooks.json`. Add the new entry there so plugin users get it automatically:

```json
{
  "hooks": {
    "PostToolUse": [
      { "matcher": "Write|Edit", "hooks": [{ "type": "command", "command": "$CLAUDE_PLUGIN_ROOT/hooks/validate-on-write.sh" }] },
      { "matcher": "Bash",       "hooks": [{ "type": "command", "command": "$CLAUDE_PLUGIN_ROOT/scripts/track-stage-tokens.sh" }] }
    ]
  }
}
```

Plugin hooks **merge** with user-level `.claude/settings.json` hooks (they don't override) — both fire. So users who already have their own `.claude/settings.json` PostToolUse hooks keep them.

**4b. Status line — user-level only; cannot ship in the plugin.** Per Claude Code's plugin reference, `statusLine` is a per-user `.claude/settings.json` setting and is NOT distributable through plugin manifests (only `agents` and `subagentStatusLine` are). The plugin therefore cannot wire `info-bar.sh` automatically — the user must opt in.

Document the opt-in clearly in `commands/mo-init.md` (Step 6 of this plan). The `update-config` skill can be invoked from `/mo-init` with the user's consent to write:

```json
{
  "statusLine": {
    "type": "command",
    "command": "$CLAUDE_PLUGIN_ROOT/scripts/info-bar.sh"
  }
}
```

If the user declines, the hook still runs (the sidecar/log are still produced); they just don't get the bottom-bar display until they opt in later.

**Path resolution.** Both files resolve through `$CLAUDE_PLUGIN_ROOT`, which the runtime sets to the plugin's installed root — so the wiring works from any worktree.

### Step 5 — Test on a real cycle

1. Run `/mo-run` → confirm sidecar gets initialized.
2. Watch the status line update after each `/mo-continue` / stage-advance call.
3. Verify the `up to that point` and `current stage` numbers match expectations.

### Step 6 — Document in `commands/mo-init.md`

The hook ships automatically via `hooks/hooks.json` — no user action needed for token tracking to start. The status line, however, is opt-in (Claude Code does not let plugins ship `statusLine` config). `/mo-init` should:

1. Confirm the hook is wired (verify `hooks/hooks.json` includes the `track-stage-tokens.sh` entry — if the plugin was installed before this feature shipped, prompt to update).
2. Offer the status-line opt-in: ask the user whether to wire `info-bar.sh` into their `.claude/settings.json`. If yes, invoke the `update-config` skill to write the `statusLine` block (path under `$CLAUDE_PLUGIN_ROOT/scripts/info-bar.sh`). If no, mention they can opt in later by re-running `/mo-init`.

Mention in the user-facing doc that the sidecar + usage log are produced regardless of the status-line opt-in — declining only affects the bottom-bar display, not the data collection.

## Token-counting strategy

**Source.** Claude Code session transcript (JSONL).

**What to count per assistant turn:**

- `usage.input_tokens` — uncached input.
- `usage.output_tokens` — output.
- `usage.cache_creation_input_tokens` — cache writes (charged at premium).
- `usage.cache_read_input_tokens` — cache hits (charged at ~10%).

The simplest accurate metric is `(input_tokens + cache_creation_input_tokens + cache_read_input_tokens + output_tokens)` — total bytes through the model. This is what counts against Claude Code's session budget regardless of cache hit rate.

**Per-stage attribution.**

The hook records `last_advance_at` (timestamp of the previous stage advance). On the next advance, sum tokens across all assistant turns whose timestamps are between `last_advance_at` and now. Update `last_advance_at` to the current advance time.

For the very first stage in a cycle, the start anchor is the cycle's `quest/<slug>/active.md` write timestamp (or the session start, whichever is later).

## Context-counting strategy

**Source.** Same Claude Code session transcripts (main + sub-agent JSONLs).

**Main-context occupancy at stage advance.** For the main session's most recent assistant turn at the moment of the stage advance, the input-side total approximates the active context-window size:

```
context.main = input_tokens + cache_creation_input_tokens + cache_read_input_tokens
```

This is what the model received as input on its last turn — i.e., everything currently "in context". It excludes `output_tokens` (the model's response, which becomes part of context for the *next* turn but isn't counted as occupancy at the moment of the just-completed turn).

**Sub-context occupancy.** Same formula applied to each sub-agent's most-recent turn in its own transcript. A sub-agent that has finished (its transcript ends with a final assistant turn followed by no further activity) still has a meaningful "last context size" — the moment just before it returned its result.

**Why occupancy and throughput differ — and why both are logged.**

- A stage that re-uses heavily cached context can have very high `tokens.cache_read` (throughput) but a stable `context.main` (occupancy).
- A stage that grows the conversation rapidly with mostly fresh content can show modest token throughput but a steeply rising `context.main`.
- A stage that delegates to many sub-agents may have moderate `context.main` (the main session stays small) but a large aggregate `sum(sub[].context_size)` — meaning the work happened in sub-contexts and didn't pollute the main one.

The two numbers together let the overseer answer "where did the budget go?" — directly visible in the log without re-running the cycle.

## Edge cases

### Multiple Claude Code sessions per cycle

A workflow cycle can span multiple sessions (overseer takes a break, restarts Claude Code). Each session has its own transcript file.

**Handling.** The sidecar persists `session_id`. On hook entry, check whether the current session matches the recorded one:

- Match → continue with `last_advance_at` as the lower bound.
- Mismatch → the prior session's tail tokens are unattributable. Record a `session_break` marker in `stages[]` and start the current stage's count from the new session's start. The displayed cumulative may slightly understate (tokens between the prior session's last advance and its session end aren't counted). This is acceptable — accurate to ~5%.

### Stage transitions outside the workflow

A stray `progress.sh advance` invocation while no cycle is active (shouldn't happen, but defensively): hook exits silently.

### Hook fires AFTER the bash but BEFORE the assistant turn that contained it lands in the transcript

In practice, the assistant turn including the bash tool call IS in the transcript by the time `PostToolUse` fires. But if there's a race, the hook should accept "the latest turn boundary at-or-before now" as the upper bound rather than failing.

### Very large transcripts

A long-running cycle's transcript can grow to hundreds of MB. The hook only needs to scan from `last_advance_at` forward — not the whole file. Use a `tail -c <n>` sample and walk back to a JSONL boundary if needed; or use `jq --stream` for memory-efficient parsing.

### Sidecar corruption

If the sidecar is unreadable JSON, the hook writes a fresh sidecar with just the current stage's row and a `recovered: true` marker. The status line script handles missing/invalid JSON by printing `mo · sidecar error · check stage-tokens.json` and exit 0.

### Slug-name length in the status line

Slugs like `2026-05-12-pricing-meeting+audit-rfc` are long. The status line truncates: first 18 chars + `…`. Or replaces the slug with just the date prefix.

### Sub-agent transcripts not fully flushed when the hook runs

Like the main-transcript race condition, sub-agent JSONL files may not be fully flushed by the time the hook discovers them. The hook reads "best available" — count tokens up to the last whole JSONL record; `context_size` may be a turn or two behind reality. Acceptable; the log is for retrospective analysis, not real-time billing.

### Sub-agent kind detection ambiguous

Distinguishing a Task-with-`subagent_type` (`"subagent"`) from a Task-without (`"fork"`) requires inspecting the parent session's `Task` tool-use record (the `subagent_type` field lives in the tool input args). If detection is ambiguous (e.g., older transcripts that didn't capture this field cleanly), record `kind: "unknown"` rather than guessing. The distinction is informational, not load-bearing.

### Long cycles producing large logs

A cycle with all 8 stages (plus 1.5) produces ~9 NDJSON records. Even with verbose sub-context detail per record, the log stays well under 100 KB across an entire cycle. No rotation needed within a cycle. Across cycles, the log archives with the cycle and a fresh empty file is created when the next cycle starts.

### Concurrent sub-agents during a single stage

A stage may launch multiple sub-agents in parallel (especially during stage 3 brainstorming → planning → executing). All of them appear as separate entries in `context.sub[]`. The hook does NOT try to deduplicate or merge — each sub-agent's session UUID is the key. Sub-agents that started in an earlier stage but finished in the current one are recorded against the stage in which they finished (their transcript's last-modified time is the attribution anchor).

### Cycle-level stages 1 and 1.5 have no active feature

Stages 1 and 1.5 fire BEFORE any feature is activated — `progress.sh activate` is what flips `active` from null to a feature name (entering stage 2). The hook records these rows with `feature: null` in both the sidecar and the log. Status-line rendering treats `feature: null` as cycle-level (no feature segment shown). Note that during these stages the cycle's quest folder exists (created by `quest.sh start`) but `progress.md` may have `active: null` and an unreordered queue.

### Stage 4 never appears as its own row

The hook never emits a `"stage": "4"` row — stages 3 and 4 are merged into a single `"3+4"` row, written when `progress.sh advance-to 3 5` fires. Consumers (`jq` queries, future report generators) must accept `"3+4"` as a valid stage label. This matches `progress.md`'s own behavior: `current-stage` is never `4` either. If finer-grained attribution becomes necessary later, it requires explicit logical markers in the Resume Handler — out of scope for this plan.

### Manual-test sub-flow rows (`"5-mt"`)

Per `docs/manual-testing/plan.md`, stage 5 is widened to "overseer evaluation": an optional manual-test sub-flow runs before findings authoring. The hook records the sub-flow as a `"5-mt"` row, written when `progress.sh set sub-flow=none manual-test-state=complete` fires (the LAST mutation of `/mo-manual-test-run`'s auto-seed loop / Branch B finalization / Branch C `--finalize-skipped` finalization). The entry mutation `progress.sh set sub-flow=manual-testing manual-test-state=running` is anchor-only — it updates the sidecar's `current_stage` to `"5-mt"` so the status line reflects the active sub-flow, but does not write a row. Tokens between the entry anchor and the exit row are attributed to `"5-mt"`.

A single feature may legitimately fire `"5-mt"` multiple times — `/mo-manual-test-run --seed-only` re-trigger after observation edits, `--finalize-skipped` after pause, or post-crash recovery (`state=complete && sub-flow=manual-testing`) re-firing the finalization mutation. Each finalization emits its own row. Per-feature totals must sum across all `"5-mt"` rows in the feature's window. The status line shows the most recent.

The skipped-phase path (overseer answered `n` to "generate plan?" or used `--discard-existing`) writes NO `"5-mt"` row — `progress.sh set manual-test-state=skipped manual-test-failure-policy=none` is treated as a silent no-op by the hook because no manual-test work happened. The eventual stage-5 row absorbs the small planning-prompt tokens normally.

When a manual-test phase ran, the subsequent `"5"` row captures only the *post-manual-test* findings-authoring + Overseer Handler tokens. This is meaningful: a stage-5 row that says `200k tokens` means very different things depending on whether a `"5-mt"` row precedes it. Consumers should treat `"5-mt" + "5"` as a coupled pair when reporting "stage 5 cost".

### `finish` clears active before the post-hook reads it

`progress.sh finish` atomically clears `active` to null and appends the just-finished feature to `completed`. By the time PostToolUse fires, `active` is gone — so the hook reads `completed[-1]` from `progress.md` for the stage-8 row's `feature` field. (If `completed` is unexpectedly empty, the row is written with `feature: null` and `feature_lookup_failed: true`.) Pre-hook capture (PreToolUse companion) is NOT needed — `completed[-1]` is the post-state authority.

### Multi-feature cycles — stage numbers repeat

A cycle that processes 3 features writes the per-feature stages (2, 3+4, 5, 6, 7, 8) three times — once for each feature, in queue order. The `feature` field disambiguates. Total cycle tokens = `up_to_that_point_tokens` after the last row. Per-feature totals are derivable: `jq -s '[.[] | select(.feature == "payments") | .tokens.total] | add' usage.log`. Without the `feature` field, identical stage numbers would be ambiguous after the second feature begins.

## Verification

After implementation, exercise:

1. **Happy path.** Run a small cycle end-to-end. Verify the bottom bar updates after each `/mo-continue`. Check that `up to that point` increases monotonically and `current stage` reflects the last delta.
2. **Session break.** Mid-cycle, exit Claude Code, restart, continue. Verify `session_break` marker appears and the cumulative number reasonably continues.
3. **Abort path.** Run `/mo-abort-workflow` mid-cycle. Verify the sidecar AND `usage.log` are **preserved** (not removed) — abort is a feature-level reset that keeps the quest subfolder intact. Confirm the cycle-wide token tally continues uninterrupted when the same or a different feature is retried after the abort.
4. **Completion path.** Run `/mo-complete-workflow`. Verify the sidecar is archived alongside the rest of the cycle (ends up under `blueprints/history/v[N+1]/...` or stays in the now-archived `quest/<slug>/` — both are acceptable per the design choice).
5. **No-cycle state.** Open Claude Code in a fresh project with no active cycle. Verify the bottom bar shows the no-active-cycle message and doesn't error.
6. **Usage log content.** After running a cycle end-to-end, `cat quest/<slug>/usage.log` should show one valid NDJSON record per stage advance with full token breakdown and `context.main` populated. Validate with `jq -c . quest/<slug>/usage.log` (parse-clean).
7. **Sub-context capture.** Run a cycle in which stage 3 invokes brainstorming/planning/executing sub-agents. Verify the corresponding log record's `context.sub[]` array is non-empty, contains one entry per sub-agent, with `session_id`, `kind`, `tokens_total`, and `context_size` fields populated.
8. **Log archival on completion.** After `/mo-complete-workflow`, verify `usage.log` is preserved alongside the cycle's other artifacts (same destination as `.stage-tokens.json`).
9. **Log preservation on abort.** After `/mo-abort-workflow`, verify `usage.log` is **preserved** (same as the sidecar — abort is a feature-level reset, not a cycle-level cleanup). Append-only history of pre-abort stages should still be present in the log when the cycle resumes.
10. **Multi-feature cycle attribution.** Run a cycle with at least 2 queued features. Verify the log contains repeated stage numbers (e.g., two `"stage":"2"` rows) disambiguated by `feature`. Verify `jq -s '[.[] | select(.feature == "<feature-A>") | .tokens.total] | add' usage.log` produces a sensible per-feature total.
11. **Stage 1 / 1.5 cycle-level rows.** After `/mo-run` + the two `/mo-continue` taps in stage 1.5, verify the log has exactly two records with `"feature": null` (one for stage 1, one for stage 1.5). The first feature-level row (`"stage":"2"`) should appear after `progress.sh activate` fires.
12. **Stage 3+4 collapse.** Run a cycle through the Resume Handler. Verify exactly one record with `"stage":"3+4"` is appended (no separate `"3"` and `"4"` records). Confirm `progress.md`'s `current-stage` jumps from 3 to 5 (never 4) at the same moment.
13. **Finish post-state read.** Run a cycle through `/mo-complete-workflow`. Verify the stage-8 record's `feature` matches the cycle's `completed[-1]` entry (read directly from the archived `progress.md`).
14. **Manual-test sub-flow `"5-mt"` row.** Run a cycle in which the overseer answers `y` to the stage-5 hand-off "generate manual-test plan?" prompt and runs the test through to completion. Verify exactly one `"5-mt"` record is appended when `progress.sh set sub-flow=none manual-test-state=complete` fires (`/mo-manual-test-run` step 4 — the LAST mutation of the auto-seed loop). Verify the subsequent `"5"` record's tokens reflect ONLY post-manual-test work (findings authoring + Overseer Handler — substantially less than a manual-test-included row would be). Confirm the status line shows `stage 5-mt ✓` while the sub-flow is active and switches to `stage 5 ✓` after the eventual stage-5 finalization. Sibling: declined-phase path — the overseer answers `n` at the stage-5 prompt; verify NO `"5-mt"` record exists; the `"5"` record absorbs the planning-prompt tokens; status line shows `stage 5` directly. Sibling: re-trigger via `/mo-manual-test-run --seed-only` after observation edits — verify a SECOND `"5-mt"` record appends.
15. **Manual-test entry anchor.** Set up a cycle just past `progress.sh set sub-flow=manual-testing manual-test-state=running`. Verify the sidecar's `current_stage` is `"5-mt"` even though no row has been appended yet (`stages[]` does not contain a `"5-mt"` entry). The status line should show `stage 5-mt` (in progress) rather than the prior stage's label.

## Risks

- **Transcript field names aren't a stable public contract.** Claude Code may rename `usage.input_tokens` etc. across versions. The hook should fail gracefully (log a warning, write a `parse_error: true` row) rather than crash.
- **Cumulative number is a token-equivalents estimate, not exact billing.** Claude Code's session budget is weighted by model + caching + tool-use overhead in ways the transcript doesn't fully expose. Use the displayed number as a directional signal, not a budget compliance check.
- **Status line refresh frequency.** If Claude Code refreshes the status line too aggressively (e.g., every 2 seconds), even a 20ms script becomes noticeable. Profile during testing; if it lags, add a 500ms cache (read sidecar mtime, only re-format if newer).
- **The two-number format may want a third.** If "up to that point" + "current stage" feels insufficient (e.g., wanting "% of session budget remaining"), add a third number behind a config flag. Don't widen the default display.
- **Sub-context discovery is the most fragile part of the new feature.** It depends on (a) sub-agent JSONLs landing in the same project directory as the main session, (b) the `parentUuid` back-reference being present and stable, and (c) `mtime` correlating with sub-agent activity windows. Any of these can break across Claude Code versions. The hook MUST degrade gracefully (`sub: []` + `sub_discovery_failed: true`) rather than corrupt the log or block the sidecar. Log the failure mode for diagnosis; never let it cascade.
- **Log content is not stable across plugin versions.** If we add a field to the NDJSON record schema later, downstream tooling that grew up around the v1 schema may break. Treat the format as additive-only: new optional fields fine, never rename or remove existing ones without bumping a `schema_version` field on each record.

## Out of scope

- Per-turn token tracking (too granular; the log stays at stage granularity, matching the hook's natural firing cadence).
- Cross-session cycle persistence beyond the sidecar + usage log (these two files are enough — no separate database needed).
- Real-time billing integration with Anthropic's API (transcripts are sufficient and don't require API auth).
- A `/mo-stage-stats` command or other report generator (the sidecar and `usage.log` are queryable directly with `jq`; build a reporter if real demand emerges).
- Sub-context tracking in the **status line** itself (the log captures it; the status line stays minimal — main-context two-number format only).

## Estimated effort

Roughly a day of focused work:

- Step 1 (verify hook + transcript contracts, sub-agent transcript shape, full trigger list): 1 hour.
- Step 2 (hook — stdin parsing, full trigger detection incl. `init`/`reorder`/`activate`/`finish` + manual-test `set` patterns for `"5-mt"` row and entry anchor, feature attribution, stage 3+4 collapse, sidecar + usage log + sub-context discovery): 5 hours.
- Step 3 (status line): 1 hour.
- Step 4 (settings.json wiring): 15 minutes.
- Step 5 (test on a real cycle — multi-feature, including log + sub-context + feature-attribution verification): 2 hours.
- Step 6 (docs): 15 minutes.

Total: ~9 hours of focused work.
