# Auto mode — design

- **Feature:** `auto-mode` (todo items AUTO-001 … AUTO-010)
- **Branch:** `feat/auto-mode`, base `6ce0cba` (plugin v1.8.1)
- **Release:** 1.9.0
- **Source of requirements:** `millwright-inspector/workflow-stream/auto-mode/blueprints/current/requirements.md`
  (decisions D1–D8, issues I1–I11, requirements R1–R12 are defined there and in the
  cycle's `summary.md`; this spec does not restate their rationale).

## 1. Intent

One cycle-wide switch that lets the millwright answer most stage 1.5–8 prompts itself,
while the gates that need a human keep stopping. Success means:

- With auto mode **off**, every prompt and hand-off is byte-for-byte what 1.8.1 prints.
- With auto mode **on**, each auto-answered prompt prints one `auto: <prompt> → <answer>`
  line and appends one `auto-answer` ledger row.
- These stay manual in every mode: todo-item selection, D1 blueprint approval, the
  blueprint-review scope gate (`mi-apply-impact` Step B.5), the stage-3 launcher's
  never-auto-fire rule, the stage-2 review gate, the brainstorming design Q&A (ended by
  `/mi-implement`), the two-or-more branch candidates path, the stage-5 review stop, DTI
  Gate 1, and the three clear gates (which pause and hand over).
- Inspector input always wins: anything the inspector types answers that prompt.

## 2. Architecture

Auto mode is implemented as **short prose branches in `commands/*.md` / `docs/*.md`,
backed by one shared helper script** (`scripts/auto.sh`). The prompt text itself is never
edited: each branch is a paragraph inserted immediately *before* the prompt it answers, in
this fixed shape:

> **Auto mode.** If `auto.sh is-on` → run `auto.sh answer "<prompt>" "<answer>" --cmd <cmd>`
> and continue as if the inspector had replied `<answer>`. Otherwise show the prompt below
> unchanged.

Stop-type branches (where auto mode prints a line and halts) use the same shape with
"print `<line>` and stop" in place of "continue".

### 2.1 State (`schemas/progress.schema.yaml`)

| Field | Level | Type | Default / missing | Writers |
|---|---|---|---|---|
| `auto-mode` | top | boolean | off | `init --auto`, `set-top` (via `auto.sh switch`) |
| `completed-branches` | top | array of string | `[]` | `progress.sh finish` |
| `chain-finished` | `active` | boolean | false | chain rules (`progress.sh set`); cleared by `activate` / `reset` |
| `review-stop-shown` | `active` | boolean | false | stage-5 review stop; cleared by `activate` / `reset` |

All four are optional (no `required` growth), so a pre-1.9.0 `progress.md` validates and
reads as auto mode off. Non-boolean `auto-mode` is rejected by the schema.

### 2.2 `scripts/progress.sh` additions

Existing `get` / `set` stay byte-identical.

- `get-top <field>` — prints `.<field>` from the top level (`null` when absent). Works when
  `active` is null.
- `set-top <field>=<value> …` — same temp file → schema validate → atomic rename pipeline
  as `set`; runs `mi_assert_worktree_match` (no-op when `active` is null); refuses
  `active`, `queue`, `completed`, `id`, `todo-list-id`. Shares its top-level write logic
  with `finish --set`.
- `init --auto` — creates `progress.md` with `auto-mode: true`.
- `activate`, `reset` — drop `chain-finished` and `review-stop-shown`.
- `finish` — appends `active.branch` to `completed-branches` (deduplicated; skipped when
  `branch` is null) in the same atomic write.

### 2.3 `scripts/auto.sh` (new)

| Subcommand | Behaviour | Exit |
|---|---|---|
| `is-on` | Reads `get-top auto-mode`. No cycle / missing / false → off. | 0 on, 1 off |
| `answer "<prompt>" "<answer>" [--cmd <cmd>]` | Prints `auto: <prompt> → <answer>`; appends `ledger.sh append "<stage\|->" "<cmd\|->" "auto-answer" small main "<prompt> → <answer>"`. Stage is `active.current-stage`, `-` when `active` is null. A ledger failure only warns. | 0 |
| `switch on\|off` | `set-top auto-mode=true\|false`; ledger row `"<stage\|->" "/mi-auto" "auto-mode-switch" small main "auto-mode → on\|off"`; if a feature is active, `progress.sh set diagram-prompt=auto\|prompt`. Refuses without an active quest cycle. | 0 / 1 |
| `create-branch <slug> <config.md>` | `git status --porcelain --untracked-files=no -- . ":(exclude)<data-root>"` must be empty, else prints `auto: uncommitted changes — commit or stash, then /mi-continue` and exits 3. Picks `feat/<slug>`, then `feat/<slug>-2`, `-3`, … while the local branch exists. `git switch -c <name>` from current HEAD. Rewrites `## GIT BRANCH` in `config.md` to the single bare line (HTML comment kept). Prints `auto: created branch <name> from <base>` and a ledger row. | 0 / 3 / 1 |
| `approve-guard <feature>` | Walks `inspector-review.md`. Passes only when every non-open finding has scope `fix` or `re-implement` **and** status `fixed`, no finding is still `open`, and `deferred-questions.sh list-open` is empty. Otherwise prints `auto: review needs your look — IR-003 (re-spec), IR-004 (wontfix), DQ-001 (open question), …` naming each offending finding with its scope or status, then each open deferred question. | 0 pass / 1 stop |

### 2.4 Commands

- **`/mi-run`** — Step 1 accepts `--auto`, and a bare `auto` token only when no journal
  folder named `auto` exists (otherwise it stays a folder name). Passes `--auto` to
  `progress.sh init`.
- **`/mi-auto on|off`** (new, `commands/mi-auto.md`) — thin wrapper over `auto.sh switch`.
  `on` prints `auto mode ON — remaining questions this cycle will be answered
  automatically`; `off` prints that prompts are restored; no argument prints the current
  state. When a prompt is already waiting, `on` says the inspector answers that one and auto
  mode takes over from the next.
- **`/mi-implement`** (new, `commands/mi-implement.md`) — hand-typed; ends the brainstorming
  design Q&A. Typing it counts as design approval. It tells the chain to: write the spec;
  write the plan without an inspector review; run implementation with sub-agents; follow
  `templates/auto-mode-chain-rules.md` (read the file — never inlined). Works whether auto
  mode is on or off. The step list is numbered correctly (fixes the "3 steps" wording).
- **Optional:** an `AUTO` badge in the status-line script when `auto.sh is-on` succeeds.

### 2.5 Shared end-of-chain rules (`templates/auto-mode-chain-rules.md`, new)

Plain text, no tokens. Both `/mi-implement` and the `mi-plan-implementation` Step 4a primer
(the primer only when auto mode is on) reference this one file, so the two cannot drift.
Rules:

1. Record blocking questions in `implementation/deferred-questions.md` (via
   `deferred-questions.sh add`) with the assumption taken, instead of stopping.
2. Stay on the current feature branch; never create a git worktree.
3. At chain end, check for issues: open points in the end-of-session report needing the
   inspector's decision, or `deferred-questions.sh list-open` non-empty. Individual
   BLOCKED / DONE_WITH_CONCERNS task reports handled during implementation do not count.
4. If there are issues, walk through them **one item per reply** and wait. An answer that
   needs code is either fixed now or recorded with `needs-finding: true`. If the inspector
   says stop, or a point stays unresolved: print
   `auto: open point <X> unresolved — answer, then /mi-continue`, choose no finishing
   option, set no marker, and stop.
5. When `finishing-a-development-branch` asks, choose option 3 (keep the branch as-is).
6. Run `progress.sh set chain-finished=true`, then invoke `/mi-continue`.

### 2.6 Deferred questions

- `templates/deferred-questions.md.tmpl` (+ schema `deferred-questions`): frontmatter
  `feature`; body entries `## DQ-NNN` with lines `- question:`, `- assumed:`,
  `- status: open|answered`, `- answer:`, `- needs-finding: true|false`,
  `- follow-up:` (IR id, optional).
- `scripts/deferred-questions.sh`: `init <feature>`, `add <feature> <question> <assumed>`,
  `answer <feature> <DQ> <answer> [--needs-finding]`, `list-open <feature>`,
  `list-needs-finding <feature>` (needs-finding true and no follow-up),
  `set-follow-up <feature> <DQ> <IR>`.
- **Resume Step 6 (all modes):** after `review.sh init`, each entry from
  `list-needs-finding` becomes a finding via `review.sh add <feature> major <scope>
  "<question>"` (scope `fix`, or `re-implement` when the answer describes restructuring),
  and the IR id is written back with `set-follow-up`. Idempotent via `follow-up`.
- **Stage 5–6:** still-open entries are listed at the review stop, count as open issues, and make `approve-guard` stop
  (they block the R9 path-1 auto-complete).

## 3. Auto-answer sites

"Answer" = auto branch continues with that reply. "Stop" = prints the line and halts.

| # | File / step | Prompt | Auto behaviour |
|---|---|---|---|
| 1 | `mi-continue` Pre-flight 2A.7 | queue order | Answer: accept; continue into Step 2B (the "Do NOT auto-fire Step 2B" line gains "unless auto mode is on") |
| 2 | `mi-apply-impact` after `progress.sh activate` | — | `progress.sh set diagram-prompt=auto` + `auto.sh answer "blueprint diagrams" "auto"` |
| 3 | `mi-draw-diagrams` Step 1.5 "skipped earlier" | generate now? | Answer `y` |
| 4 | `mi-continue` Review-Resume 2.5, `stale` / `skipped` | refresh diagrams? | Answer `y`; `missing` stays manual; `fresh` unchanged |
| 5 | `mi-plan-implementation` Step 2, zero candidates | branch | `auto.sh create-branch`; exit 3 → stop; two-or-more candidates still asks |
| 6 | `mi-plan-implementation` Step 4 | planning mode | Answer `brainstorming`; Step 4a primer appends the chain-rules reference |
| 7 | `mi-continue` Resume Step 2 | execution mode | Answer `subagent-driven` |
| 8 | `mi-continue` Resume Step 2.5 | chain completed? | `chain-finished=true` → answer `completed`; otherwise the prompt shows (auto mode does not guess) |
| 9 | `mi-continue` Resume Step 4 | drift check | Answer `auto` |
| 10 | stage-3 `/effort` suggestion | — | print only |
| 11 | `mi-continue` Resume Step 7 | manual test plan? | Answer `y` |
| 12 | `mi-manual-test-plan` run offer | execution mode | Answer `y-autonomous` |
| 13 | `mi-manual-test-run` auto-seed | seed failures? | Answer `y` (failed scenarios only) |
| 14 | `mi-manual-test-run` guided re-run offer | re-run guided? | Answer `n` |
| 15 | `mi-manual-test-run` per-IR actions | action | Answer `a` (reopen the closed IR / seed into the regression family — keeps the failure open) |
| 16 | `mi-manual-test-run` 4.8 hand-off | — | Stop with the review-stop line (§4.1) |
| 17 | `mi-continue` Inspector Step 3a | no findings, confirm? | Answer `y` when no open findings and no open DQ entries; DTI Gate 1 still runs |
| 18 | `mi-review` Step 2.6 | review mode | Answer `direct`; the switch-to-brainstorming question becomes a warning line |
| 19 | `mi-review` Step 3a.2.7 / Step 3b approve / Step 4 | approve? | `approve-guard` pass → answer `approve`, run `/mi-continue`; fail → print the guard line, then the unchanged prompt |
| 20 | `mi-continue` Review-Resume Step 1 | all resolved, confirm? | Answer `y` only when `approve-guard` passes; otherwise print its line and show the prompt |
| 21 | `mi-continue` Inspector Step 3b | "Do not auto-fire `/mi-complete-workflow`" | gains "unless auto mode is on and the approve guard passes" |

Before editing, re-grep `commands/` and `docs/` for `never auto`, `do not auto`,
`Do NOT auto-fire`, `Wait for the`; any hit not in this table is left untouched and listed
in the plan (I8).

## 4. Stops and gates

### 4.1 Stage-5 review stop (R12, D4)

In auto mode the review stop prints exactly once per feature:

`auto: review stop for <feature> — check commits <base>..HEAD, diagrams and test results; add findings to inspector-review.md or leave it empty, then /mi-continue (No findings → it approves and completes.)`

It fires at `mi-manual-test-run` 4.8 (replacing the hand-off), or — when no test run reached
4.8 — at the Inspector Handler's entry when `review-stop-shown` is false. Either site sets
`review-stop-shown=true`. It never auto-continues. Still-open deferred questions are listed
under it.

After the inspector's `/mi-continue`: canonicalization → no open findings and no open DQ
entries → site 17 (R9 path 1); otherwise `/mi-review` fires, whose `stage-5-to-6` clear gate
pauses separately.

### 4.2 Clear gates (R10, D5)

Gates: `stage-2-to-3` (`mi-continue` Approve Step 2), `stage-5-to-6` (`mi-review` Step 1.5),
`stage-8-to-2` (`mi-complete-workflow` Step 7.2). In auto mode each gate:

1. runs its `decisions.md` write-check exactly as today;
2. for the two in-feature gates only, records the gate via `add-clear-recommendation`;
3. prints `auto: clear gate <gate> — type /clear, then /mi-continue` in place of the long
   recommendation block, and stops.

Re-entry proceeds via the existing `has-clear-recommendation` check (in-feature gates) or by
construction (`stage-8-to-2`). The D1 blueprint review stop stays separate: review →
`/mi-continue` → Approve Step 2's write-check → the pause line.

### 4.3 Stacked-branch reminder (D8)

At stage 8, after `finish`, in every mode: when the previous entry of `completed-branches`
has a tip that is an ancestor of this feature's `base-commit`, and that previous branch is
not merged into `main`/`master`, print
`stacked: <branch> is based on <previous> (unmerged)`.

### 4.4 Stage-2 pre-fill fix (all modes)

`docs/blueprint-regeneration.md` Step B skips the `## GIT BRANCH` pre-fill from HEAD when
`head_branch` is in `completed-branches`. With nothing pre-filled, site 5 creates the next
feature's own stacked branch.

## 5. Error handling

- `auto.sh is-on` treats every read failure as off — an unreadable state never auto-answers.
- `auto.sh answer` never blocks the workflow on a ledger failure (warning only).
- `create-branch` never reuses an existing branch; exit 3 on a dirty tracked tree is a
  normal stop, not an error.
- `approve-guard` is conservative: any unparsable finding block counts as a stop.
- `set-top` refuses protected fields and leaves the file untouched on schema failure.

## 6. Testing (`tests/auto-mode/run.sh`, new)

Same harness style as `tests/deferred-test-items/run.sh`. Layers:

1. **Behaviour:** `get-top`/`set-top` with `active: null`; protected-field refusal;
   non-boolean rejection; legacy `progress.md` reads off; `init --auto`; `activate`/`reset`
   clear the per-feature markers; `finish` appends `completed-branches` (deduped);
   every `auto.sh` subcommand incl. `create-branch` dirty/collision/data-root-exclusion and
   `approve-guard` pass + each failure kind; `deferred-questions.sh` round-trip; Resume
   Step 6 conversion is idempotent.
2. **Off byte-for-byte:** every prompt block in §3 captured verbatim from base `6ce0cba`
   into `tests/auto-mode/fixtures/prompts-off/`; the test extracts the same blocks from the
   current files and compares exactly.
3. **On:** each site has its auto paragraph immediately before the prompt naming the
   expected answer; every `auto:` stop line matches its exact text.
4. **Chain rules single source:** `/mi-implement` and the Step 4a primer reference
   `templates/auto-mode-chain-rules.md` and neither inlines its text.
5. **Never-auto audit:** the grep in §3 matches an expected list of changed and unchanged
   lines.

Existing suites and fixtures are untouched and must still pass. There is no top-level
runner or CI list, so nothing else changes.

## 7. Docs and release

- README "Auto mode" section: enabling it (`/mi-run --auto`, `/mi-auto`), what stays
  manual, clear-gate pauses, `/mi-implement`, deferred questions, branch stacking and merge
  order (merge in queue order, or merge the last branch to take the whole stack).
- `docs/millwright-inspector-project.md`: list `/mi-auto`, `/mi-implement`, `auto.sh`,
  `deferred-questions.sh`.
- `CHANGELOG.md`: new top heading `## 1.9.0 — Auto mode`.
- `.claude-plugin/plugin.json`: `1.9.0`.

## 8. Out of scope

Running `/clear` from the model; a sub-agent substitute for clear gates; auto-answering
superpowers prompts beyond what plugin text instructs; seeding non-failed manual-test
scenarios; an unattended mode without the stage-5 stop; auto-selecting todo items.
