# PR-Review Analysis — `/mo-analyze-review` — Plan & Design

**Status:** Pre-implementation. The open decisions in §11 should be confirmed before
work begins.

**Target version:** `v0.10.0` (new minor — adds a command, two agents, two scripts, two
templates, two schemas; modifies `/mo-continue`, `/mo-apply-impact`, and the write-hook).

---

## 1. Motivation & summary

When a feature ships, human reviewers leave comments on its GitHub PR. Today those
comments are handled ad-hoc in chat, outside the millwright-overseer workflow — no
audit trail, no structured triage, and nothing feeds back into how the millwright
implements the *next* feature.

This feature adds a self-contained loop:

1. The overseer points the millwright at a PR (or a single review comment).
2. The millwright fetches every review comment, analyzes each against the real
   codebase, and writes a **report** — one block per comment, each either a
   **proposed fix** (comment is valid) or a **proposed reply** (comment is not valid).
3. The overseer reads the report and **marks** the blocks they want acted on —
   exactly the checkbox-marking gesture used for todo-list items — and may add notes.
4. `/mo-continue` drives the apply step: the millwright applies the marked fixes,
   and (after explicit confirmation) posts the marked replies to GitHub.
5. After fixing, the millwright distills **lessons learned** from the *valid*
   comments into `millwright-overseer/lessons-learned.md`.
6. `lessons-learned.md` is referenced from every future `config.md`, so the
   planning and implementation chains consult it and stop repeating past mistakes.

The role split is unchanged: the **millwright** analyzes, proposes, fixes, and
distills lessons; the **overseer** decides which proposals are acted on. The
millwright never self-approves — the marking gate is mandatory, mirroring the
stage-2 / stage-5 / stage-6 gates.

---

## 2. Scope decisions (confirmed)

| Decision | Outcome |
| --- | --- |
| What happens to a proposed reply | **Post on overseer mark.** A marked `action: reply` block is posted to GitHub by the apply step — gated behind an explicit confirmation prompt, since it is an external, visible write. Unmarked reply blocks are drafts only. |
| How `lessons-learned.md` reaches future workflows | **Reference by path.** `config.md` gets a `## Lessons learned` section containing the resolved path; the chains are instructed to read the file. The content is *not* inlined, so `config.md` stays small. |
| Whether `/mo-analyze-review` needs an active workflow | **No.** It runs standalone on any PR URL. After writing the report it prints a reminder that the overseer may turn the report into a journal entry and start a normal workflow from it if the changes are large. |
| Which comment kinds are in scope (formerly open decision D4) | **All three kinds**, each with its own fetch source, resolution model, and reply mechanics — see §4a. The kinds are: line-level **review comments**, review **summary bodies**, and general PR **issue comments**. They do *not* share one reply endpoint, so the report carries an explicit `comment-kind` field. |

---

## 3. End-to-end flow

```
overseer: /mo-analyze-review https://github.com/acme/web/pull/812
   │
   ├─ parse URL → owner, repo, PR #, optional comment/review id
   ├─ preflight: gh installed + authenticated; cwd repo remote matches owner/repo
   ├─ fetch comments  (GraphQL reviewThreads for line comments + isResolved;
   │                   REST for review summary bodies and issue comments)
   ├─ create timestamped session  millwright-overseer/pr-reviews/acme-web-pr812/<ts>/
   ├─ spawn review-comment-analyst sub-agent (reads the codebase)
   └─ write report.md  (status: awaiting-marks)
         │
         ▼
overseer: opens report.md, flips  [ ] → [x]  on the blocks to act on,
          optionally edits verdict/action, adds overseer-notes
         │
         ▼
overseer: /mo-continue
   │
   ├─ pre-dispatch check finds a pr-reviews/**/report.md with
   │  status: awaiting-marks  OR  status: partial
   ├─ → PR-Review Apply Handler
   │     ├─ normalize + collect actionable blocks (marked [x] AND non-terminal)
   │     ├─ split into fix blocks / reply blocks
   │     ├─ repo guard (always); dirty-tree check + gh pr checkout (only if fixes)
   │     ├─ spawn pr-review-fixer sub-agent → applies fix blocks, commits
   │     ├─ confirm + post reply blocks to GitHub (endpoint per comment-kind)
   │     ├─ append lessons (from applied valid fixes) → lessons-learned.md
   │     └─ report.md status → applied (all terminal)  |  partial (retries remain)
   └─ done
         │
         ▼
next feature's /mo-apply-impact regenerates config.md
   └─ writes  ## Lessons learned  →  path: millwright-overseer/lessons-learned.md
         the planning + implementation chains read it before writing code
```

---

## 4. New command — `/mo-analyze-review`

**File:** `commands/mo-analyze-review.md`

**Usage:**

```
/mo-analyze-review <github-pr-or-comment-url>
```

### Step 1 — Parse the URL

Accept three forms:

| URL form | Meaning |
| --- | --- |
| `…/pull/<N>` | The whole PR — all unresolved review comments + summary bodies + issue comments. |
| `…/pull/<N>#discussion_r<ID>` | A single line-level review comment. |
| `…/pull/<N>#pullrequestreview-<ID>` | One review — its summary body and the line comments in it. |

Extract `owner`, `repo`, `pr_number`, and the optional `comment_id` / `review_id`.
Reject non-GitHub URLs and non-PR URLs with a usage message.

### Step 2 — Preflight

1. `gh` must be installed and authenticated (`gh auth status`). If not, print the
   install/auth hint and exit. (`gh` is added to `mo-doctor` — see §10.)
2. **Repository guard.** The current working directory must be inside a git repo
   whose default remote (`origin`, or the `gh`-resolved default) points at the same
   `owner/repo` as the URL. On mismatch, refuse — the overseer is in the wrong
   checkout. This guard matters because the command is *standalone*: unlike the
   workflow commands it cannot lean on the active-quest worktree fingerprint in
   `scripts/internal/common.sh` (`mo_assert_worktree_match`, common.sh:325), which
   is keyed to workflow state. The repo guard is the standalone equivalent.
3. **PR head guard.** The repo match is not sufficient — the `review-comment-analyst`
   judges each comment against the code in the working directory, so the working
   tree must be on the PR's head commit. Compare `git rev-parse HEAD` to the PR's
   `headRefOid` (`gh pr view <pr> --json headRefOid`); on mismatch, refuse and tell
   the overseer to `gh pr checkout <pr>` first. A dirty worktree
   (`git status --porcelain` non-empty) is a **warning** — local edits can skew the
   review — but not a hard refusal.

The repo and head guards are required for analysis (not just the later apply-step
checkout) so the `review-comment-analyst` reads the PR's actual code.

### Step 3 — Fetch comments

Delegate to `scripts/pr-review.sh fetch`. The fetch is **kind-aware** — see §4a for
the per-kind sources and why a single REST endpoint is insufficient. In summary:

- **Line-level review comments** → GraphQL `repository.pullRequest.reviewThreads`,
  which exposes `isResolved` / `isOutdated` per thread plus each comment's
  `databaseId`, `body`, `author`, `path`, `line`/`originalLine`, `url`. On a
  whole-PR fetch, threads with `isResolved: true` are skipped by default.
- **Review summary bodies** → REST `gh api repos/{o}/{r}/pulls/{N}/reviews`
  (non-empty `body` only).
- **Issue (PR conversation) comments** → REST `gh api repos/{o}/{r}/issues/{N}/comments`.

For a single-comment / single-review URL, fetch only the targeted id(s). Raw
JSON/GraphQL responses are saved under the session's `raw/` for traceability.

### Step 4 — Create the session

Sessions are **timestamped** to keep re-runs from colliding:

```
<data_root>/pr-reviews/<owner>-<repo>-pr<N>/<UTC-timestamp>/
  ├─ report.md
  └─ raw/
```

Before creating a new session, `pr-review.sh` scans this PR's existing sessions for
a report whose `status` is `awaiting-marks` or `partial` (i.e. still in progress).
If one exists, refuse and point the overseer at it — there must be at most one live
report per PR. Completed (`applied`) sessions are retained as history.

### Step 5 — Analyze (sub-agent)

Spawn the `review-comment-analyst` sub-agent (§7.1) with the fetched comments and
the repo path. It reads the referenced files/lines, judges each comment, and
returns one structured block per comment.

### Step 6 — Write the report

Render `<session>/report.md` from `templates/pr-review-report.md.tmpl` (§5),
frontmatter `status: awaiting-marks`.

### Step 7 — Hand back to the overseer

Print a summary (N comments by kind, X proposed fixes, Y proposed replies) and:

```
Report ready: millwright-overseer/pr-reviews/acme-web-pr812/<ts>/report.md
  • Mark  [ ] → [x]  on each block you want acted on, then run /mo-continue.
  • Tip: if the marked work is large, you can copy this report into a
    journal/ entry and run /mo-run to handle it as a full workflow instead.
```

---

## 4a. Comment kinds — fetch, resolution, and reply mechanics

GitHub does not treat all PR comments uniformly, and the original plan wrongly
assumed one fetch shape and one reply endpoint. The three kinds:

| `comment-kind` | Fetched from | Resolution state | Reply mechanism |
| --- | --- | --- | --- |
| `review-comment` | GraphQL `reviewThreads` (REST `…/pulls/{N}/comments` lacks thread-resolution state) | `isResolved` / `isOutdated` from the review thread | Threaded reply: `POST repos/{o}/{r}/pulls/{N}/comments/{reply-target-id}/replies` — **must target the thread's top-level comment**, not a reply |
| `review-summary` | REST `…/pulls/{N}/reviews` (`body`) | none — a review body is not a resolvable thread | New PR conversation comment: `POST repos/{o}/{r}/issues/{N}/comments`, body prefixed with a quote + link to the original review |
| `issue-comment` | REST `…/issues/{N}/comments` | none | New PR conversation comment: `POST repos/{o}/{r}/issues/{N}/comments`, body prefixed with a quote + link to the original comment |

Consequences baked into the rest of the plan:

- The report stores `comment-kind` on every block. The apply step's reply-posting
  branches on it; there is no single "comment thread" to post to.
- Only `review-comment` blocks have a meaningful resolved/unresolved state. The
  "skip resolved comments" promise applies to that kind only; summary bodies and
  issue comments are always included on a whole-PR fetch.
- A `review-comment` block stores **two** ids, both REST `databaseId`s read from the
  GraphQL nodes: `source-comment-id` (the exact comment the URL/fetch points at) and
  `reply-target-id` (the thread's top-level/root review comment). GitHub's
  *Create a reply for a review comment* endpoint only accepts a top-level comment as
  the target — replies to replies are rejected. The thread's root is the first node
  in the GraphQL `reviewThread.comments` connection; `reply-target-id` is set to
  that root's `databaseId`. When the source comment *is* the root, the two ids are
  equal. `post-reply` always posts against `reply-target-id`.

Sources: GitHub REST — *Pull request reviews*, *Pull request review comments*, and
*Create a reply for a review comment*; GitHub GraphQL — `PullRequest.reviewThreads`
(`isResolved`, `isOutdated`).

---

## 5. The report document — `report.md`

**Template:** `templates/pr-review-report.md.tmpl` · **Schema:** `schemas/pr-review-report.schema.yaml`

```markdown
---
id: {{UUID}}
pr-url:    https://github.com/acme/web/pull/812
repo:      acme/web
pr-number: 812
pr-branch: feat/checkout/coupon-codes
status:    awaiting-marks      # awaiting-marks → partial → applied
---

# PR review analysis — acme/web #812

One block per review comment. For each block:
  • Flip  `[ ]` → `[x]`  in the heading to act on it.
      - action: fix   → the marked fix is applied to the PR branch.
      - action: reply → the drafted reply is posted to GitHub (after you confirm).
  • Leave `[ ]` to skip the comment entirely (no fix, no reply).
  • You may edit `verdict`/`action` if you disagree with the millwright, and
    add free text under `overseer-notes`. Then run /mo-continue.

## Comments

### PR-001 — [ ] <one-line summary of the comment>
- comment-url:        https://github.com/acme/web/pull/812#discussion_r456
- comment-kind:       review-comment   # review-comment | review-summary | issue-comment
- source-comment-id:  457              # databaseId of the exact comment the URL/fetch points at
- reply-target-id:    456              # databaseId of the thread's top-level review comment
                                       #   (review-comment only; reply endpoint target). Equals
                                       #   source-comment-id when the source IS the root comment.
- comment-author:     @reviewer
- location:           src/checkout/coupon.ts:42  # blank for review-summary/issue-comment
- thread-state:       unresolved       # review-comment only; else: n/a
- verdict:            valid            # valid | invalid | needs-discussion
- action:             fix              # fix | reply
- comment: |
    <original review comment, verbatim>
- analysis: |
    <millwright's reasoning for the verdict>
- proposed-fix: |                      # present when action: fix
    <what the millwright will change, and which files>
- proposed-reply: |                    # present when action: reply
    <drafted reply text to post on GitHub>
- overseer-notes: |                    # overseer fills in; optional
- status:             open             # open → applied | replied | skipped
                                       #      | reply-failed | reply-declined
                                       #      | fix-failed | fix-blocked
```

**Marking semantics** — identical gesture to todo-list marking, so the overseer
learns it once:

- `### PR-NNN — [x]` → the block is acted on (`fix` applied, or `reply` posted).
- `### PR-NNN — [ ]` → skipped; `status` becomes `skipped` after the apply step.
- The overseer may rewrite `verdict`/`action`; **`action` is authoritative** for
  what the apply step does (the millwright's verdict is only advisory once edited).
- `overseer-notes` is passed verbatim into the fixer sub-agent's prompt.

**Report status lifecycle:**

- `awaiting-marks` — fresh; the apply step has never run.
- `partial` — the apply step ran, but ≥1 marked block did not reach a terminal
  state. Non-terminal block states: `reply-failed` (post failed), `reply-declined`
  (overseer declined to post), `fix-failed` (the fixer could not apply the patch or
  hit a test failure), `fix-blocked` (the fixer returned `blocked` — e.g. ambiguous
  instruction). `/mo-continue` keeps picking the report up so retries remain
  reachable.
- `applied` — every marked block reached a **terminal** state: `applied`, `replied`,
  or `skipped`. Unmarked blocks are `skipped`.

A `partial` report leaves its non-terminal blocks still marked `[x]`; on the next
`/mo-continue` those — and only those — are retried (terminal blocks are skipped by
the collector, §6.2 step 2). To drop a stuck block without acting on it, the
overseer un-marks it (`[x]` → `[ ]`); the next `/mo-continue`'s normalization step
(§6.2 step 2) retires it to `skipped`, which lets the report finalize.

A `pr-review.sh canonicalize` sub-command (mirroring `review.sh canonicalize`)
auto-assigns `PR-NNN` ids and validates the block shape on `/mo-continue`.

---

## 6. `/mo-continue` integration — PR-Review Apply Handler

`/mo-continue` is the universal dispatcher; the user wants it to drive the apply
step. PR-review work has no active quest, so it is added as a **pre-dispatch check**
that runs *before* the existing 7-way Step-2 router.

### 6.1 Pre-dispatch check

At the top of `mo-continue` Step 2, scan for any report with frontmatter
`status: awaiting-marks` **or** `status: partial`. The `pr-reviews/` directory may
not exist yet, so guard first: `[[ -d "$data_root/pr-reviews" ]]` — if absent,
treat it as "no reports" and fall straight through to the existing dispatcher.
When it does exist, enumerate report files with
`find "$data_root/pr-reviews" -path '*/report.md'` rather than a `**` glob —
recursive `**` needs `shopt -s globstar`, which is not reliably set in this repo's
Bash snippets. A scan that finds nothing must also fall through cleanly, never
aborting the command before the normal dispatch.

- **None found** → fall through to the existing dispatch unchanged.
- **Exactly one found, no active workflow** → route to the PR-Review Apply Handler (§6.2).
- **More than one PR-review report found** → list them (PR number + timestamp +
  status) and ask the overseer to pick.
- **One PR-review report *and* an active workflow** → ambiguous intent. `/mo-continue`
  never guesses between a workflow stage and a PR-review apply. It prints both
  candidates as a numbered list and asks the overseer to reply with a choice **in
  chat** — the slash command is mid-execution and pauses for the reply, the same way
  the stage-3 drift prompt and other handlers already pause for overseer input.
  The reply (`1`/`2`, or `workflow`/`pr-review`) selects the route; no re-invocation
  or argument flag is needed. *(See open decision D1.)*

### 6.2 PR-Review Apply Handler

1. **Parse & canonicalize.** Run `pr-review.sh canonicalize` on `report.md`.
2. **Guard, normalize, then collect actionable blocks.**
   - *Guard a fresh report.* Count marked (`[x]`) blocks **before** normalizing. If
     the report's frontmatter `status` is `awaiting-marks` and zero blocks are
     marked, print "No blocks marked — mark the blocks you want acted on, then
     re-run /mo-continue" and exit with the report **unchanged**. This stops a
     no-op `/mo-continue` on a fresh report from normalizing every `[ ] + open`
     block to `skipped` and finalizing the whole report as `applied`. The guard is
     scoped to `awaiting-marks` only — a `partial` report must still flow into
     normalization below, since un-marking a stuck block is the intended way to
     retire it.
   - *Normalize.* Any **unmarked** (`[ ]`) block in a non-terminal `status`
     (`open`, `reply-failed`, `reply-declined`, `fix-failed`, `fix-blocked`) is set
     to `skipped`. This is how the overseer drops a stuck block — un-mark it and the
     next `/mo-continue` retires it.
   - *Collect.* Gather every **marked** (`[x]`) block whose `status` is non-terminal
     — those are the actionable set. Blocks already terminal (`applied`, `replied`,
     `skipped`) are excluded even if still marked `[x]`, so a `partial` re-run never
     re-applies a fix, re-posts a reply, or re-appends a lesson.
   - If the actionable set is empty, skip steps 3–7, go straight to step 8
     (finalize) — normalization above may have cleared the last stuck block, so the
     report can still legitimately transition `partial → applied` here. Print
     "No blocks to apply" before finalizing.
3. **Split by action.** Partition the actionable set into **fix blocks**
   (`action: fix`) and **reply blocks** (`action: reply`). The next two steps run
   independently — a report with only reply blocks must never be blocked by
   fix-only worktree concerns.
4. **Repo guard (always), checkout (fix blocks only).**
   - *Always:* confirm cwd is inside the git repo whose default remote matches the
     report's `repo` field (the §4 Step-2 guard, re-checked here because the apply
     step may run in a different session than the analysis). This guard applies to
     reply-only runs too — `pr-review.sh post-reply` must target the right repo.
   - *Only when fix blocks exist:* refuse if the working tree is dirty (ask the
     overseer to stash or commit), then `gh pr checkout <N>` to land fixes on the
     PR's head branch. `gh pr checkout` resolves cross-fork PRs; if it produces a
     detached or fork-tracking branch, surface that rather than committing blindly.
     If the PR is merged or closed, warn and ask the overseer to confirm a target
     branch. **A reply-only run skips this bullet entirely** — replies need only
     GitHub API access, not a clean tree or a checkout.
5. **Apply fixes** *(skipped when there are no fix blocks)*. Spawn the
   `pr-review-fixer` sub-agent (§7.2) with all fix blocks + their `overseer-notes`.
   It edits source, commits per the repo's convention, and returns a per-block
   outcome. Fixes are **committed, not pushed** — pushing stays the overseer's call.
   Per-block outcome → block `status`:
   - applied cleanly → `applied` (the fix's own changes are committed).
   - patch could not be applied / introduced a test failure → `fix-failed`, block
     stays marked `[x]` for retry.
   - fixer returned `blocked` (ambiguous instruction, missing context) → `fix-blocked`,
     block stays marked `[x]`; the fixer's reason is surfaced to the overseer so they
     can clarify `overseer-notes` before retrying.

   **Clean-worktree invariant.** A `fix-failed` / `fix-blocked` return must leave
   **no uncommitted changes** for that block — the fixer reverts its partial edits
   before returning the failure (only cleanly-applied fixes are committed). If the
   fixer cannot restore a clean tree, it must **halt the whole handler**, report the
   dirty files, and not proceed to other blocks — a stranded dirty checkout makes
   the next `/mo-continue` retry unsafe. The fixer's return states the worktree
   condition explicitly (`Worktree: clean` or `Worktree: dirty — <files>`).
6. **Post replies** *(skipped when there are no reply blocks)*. For each
   **actionable reply block** (marked `[x]` *and* non-terminal — never a
   terminal-but-still-marked `replied` block), show the overseer the exact reply
   text and target, and ask for explicit confirmation. On `yes`, post via
   `pr-review.sh post-reply`, which **branches on `comment-kind`** (§4a):
   `review-comment` → threaded reply endpoint; `review-summary` / `issue-comment` →
   new PR conversation comment quoting the original. Outcomes per block:
   - posted OK → block `status: replied`.
   - overseer declined → block `status: reply-declined`, stays marked `[x]`.
   - post failed (network/permission) → block `status: reply-failed`, stays marked,
     the failure is reported per block.
7. **Distill lessons.** Append lessons to `lessons-learned.md` (§8) **only for
   blocks that reached `status: applied` in this run** and are `verdict: valid` +
   `action: fix`. Because the collector skips already-terminal blocks (step 2), a
   `partial` re-run cannot append a duplicate lesson for a previously applied fix.
   Invalid comments yield no lesson — the millwright was right.
8. **Finalize from *all* blocks.** Report status is recomputed by scanning every
   block in the report, not just this run's actionable set:
   - If **every** block is terminal (`applied` / `replied` / `skipped`) → report
     `status: applied`.
   - If **any** block is still non-terminal (`open`, `reply-failed`,
     `reply-declined`, `fix-failed`, `fix-blocked`) → report `status: partial`, so
     `/mo-continue` keeps the report reachable for retry.
   Because step 2's normalization already retired every unmarked non-terminal block
   to `skipped`, a leftover `open` block here can only be a marked one — there is no
   path that marks the report `applied` while an unmarked block still says `open`.
   Print a summary.

---

## 7. New sub-agents

### 7.1 `agents/review-comment-analyst.md`

- **Model / effort:** `sonnet` / high (parity with `codebase-grounder`).
- **Job:** Given fetched PR comments + repo path, read the referenced code and, for
  each comment, return a block: `verdict` (valid / invalid / needs-discussion),
  `action` (fix / reply), `analysis`, and either `proposed-fix` or `proposed-reply`.
  Carries `comment-kind`, `source-comment-id`, `reply-target-id`, and `thread-state`
  straight through from the fetch (§5) — the analyst classifies, it does not derive
  these ids.
- **Constraints:** Read-only — it analyzes, it does not edit source. The original
  comment body is preserved verbatim. Returns per `docs/sub-agent-return-contract.md`.

### 7.2 `agents/pr-review-fixer.md`

- **Model / effort:** `sonnet` / high.
- **Job:** Apply the marked `action: fix` blocks to the checked-out PR branch,
  honoring `overseer-notes`, and commit. Then, for each *valid* fix it applied,
  distill a one-paragraph lesson (what went wrong + the rule to follow next time).
- **Constraints:** Edits source freely; commits only cleanly-applied fixes; must
  not push; must not touch workflow artifacts. **Clean-worktree invariant** — a
  `fix-failed` / `fix-blocked` block must leave no uncommitted changes (the fixer
  reverts its partial edits); if a clean tree cannot be restored, the agent halts
  and reports the dirty files instead of continuing (§6.2 step 5).
- **Returns:** a **per-block outcome** (`applied` / `fix-failed` / `fix-blocked`
  with a reason), commit shas, an explicit worktree-condition line (`Worktree:
  clean` or `Worktree: dirty — <files>`), and the lesson set — the handler maps
  these onto block `status` (§6.2 step 5).

*(Alternative considered: reuse `review-iteration-runner`. Rejected — that agent is
bound to stage-6 `overseer-review.md` IR findings and the brainstorming chain;
PR-review fixes are a different scope and a different artifact. See open decision D2.)*

---

## 8. `lessons-learned.md`

**Location:** `<data_root>/lessons-learned.md` — top level of the `millwright-overseer/`
data root, sibling to `journal/`, `quest/`, `workflow-stream/`, `pr-reviews/`.

**Template:** `templates/lessons-learned.md.tmpl` · **Schema:** `schemas/lessons-learned.schema.yaml`

```markdown
---
id: {{UUID}}
---

# Lessons learned

Cumulative record of mistakes surfaced by PR reviews. The planning and
implementation chains read this before writing code so the same mistakes are
not repeated. Append-only — managed by scripts/lessons.sh.

## L-001 — <short lesson title>
- date:   2026-05-15
- source: https://github.com/acme/web/pull/812 · PR-003
- lesson: |
    <what went wrong, and the concrete rule to follow next time>
```

- Created on demand the first time the apply step distills a lesson; absent until then.
- `scripts/lessons.sh append` auto-increments `L-NNN` and writes one entry per
  applied valid fix. The fixer sub-agent supplies the title + lesson body.
- Append-only for v1. De-duplication / consolidation of similar lessons is a
  future enhancement (noted in §11, D3).

---

## 9. `config.md` integration

Per the confirmed decision, `config.md` references `lessons-learned.md` by path.

### 9.1 Template change — `templates/config.md.tmpl`

Add a new section immediately after `<!-- auto:end -->` (i.e. before `## GIT BRANCH`):

```markdown
## Lessons learned

<!-- Regenerated by mo-apply-impact. Cumulative lessons from past PR reviews.
     The planning and implementation chains MUST read this file before writing
     code, to avoid repeating mistakes flagged in earlier reviews. -->
- path: {{LESSONS_LEARNED_PATH}}
```

This section sits **outside** the `auto:start/auto:end` entry-budget block — it is
a single fixed pointer, not a discovered skill/rule, so it does not consume the
≤10-entry budget that is paid on every primer load.

### 9.2 Generation change — `mo-apply-impact` / `docs/blueprint-regeneration.md`

The config.md generation step gains: resolve `<data_root>/lessons-learned.md`.

- **File exists** → write the `## Lessons learned` section with the resolved path.
- **File absent** → write the section with `- path: (none yet)` so the structure is
  stable.

### 9.3 Chain consumption

`config.md` is already loaded into every chain primer, so the new section
propagates automatically. To make the chains actually *act* on it, add one
instruction line to `templates/primer.md.tmpl` (and/or the planning prompt in
`mo-plan-implementation`): "If `config.md` lists a Lessons learned path, read that
file before writing plans or code."

### 9.4 Schema — no change

`schemas/config.schema.yaml` validates `config.md`'s **frontmatter only**; it does
not validate body sections. The `## Lessons learned` section is body content, so
the schema is *not* the right enforcement point and is left unchanged. The section's
presence and shape are guaranteed by the `mo-apply-impact` generation step (§9.2),
which is deterministic. (If body-level validation is wanted later, it belongs in a
body-aware check in the write-hook, not in the frontmatter schema — out of scope
for v1.)

---

## 10. Full file inventory

**New files**

| Path | Purpose |
| --- | --- |
| `commands/mo-analyze-review.md` | The new command (§4). |
| `agents/review-comment-analyst.md` | Analyzes PR comments (§7.1). |
| `agents/pr-review-fixer.md` | Applies marked fixes, distills lessons (§7.2). |
| `templates/pr-review-report.md.tmpl` | Report scaffold (§5). |
| `templates/lessons-learned.md.tmpl` | Lessons-learned scaffold (§8). |
| `schemas/pr-review-report.schema.yaml` | Validates `report.md` frontmatter. |
| `schemas/lessons-learned.schema.yaml` | Validates `lessons-learned.md` frontmatter. |
| `scripts/pr-review.sh` | URL parse, kind-aware `gh` fetch, session mgmt, `canonicalize`, `post-reply`. Self-validates — see note below §10. |
| `scripts/lessons.sh` | `append` — auto-incremented `L-NNN` entries. Self-validates — see note below §10. |

**Modified files**

| Path | Change |
| --- | --- |
| `commands/mo-continue.md` | Pre-dispatch PR-review check + PR-Review Apply Handler (§6). |
| `commands/mo-apply-impact.md` | config.md generation writes the `## Lessons learned` section (§9.2). |
| `docs/blueprint-regeneration.md` | Document the config.md `## Lessons learned` step. |
| `templates/config.md.tmpl` | New `## Lessons learned` section (§9.1). |
| `templates/primer.md.tmpl` | One line: read the lessons-learned file if config.md lists it (§9.3). |
| `hooks/validate-on-write.sh` | **Add cases** to the hard-coded path→schema dispatch for `*/pr-reviews/*/report.md` → `pr-review-report.schema.yaml` and `*/lessons-learned.md` → `lessons-learned.schema.yaml`. Unknown files currently exit unvalidated, so the new schemas are *not* picked up automatically. |
| `commands/mo-doctor.md` + `scripts/doctor.sh` | Add a `gh` (GitHub CLI) dependency + auth check. |
| `commands/mo-init.md` | Optionally scaffold `pr-reviews/` (or leave it created on demand). |
| `.claude-plugin/plugin.json` | Version bump to `0.10.0`. |
| `docs/sub-agent-profiles/plan.md` | Register the two new agents. |

`schemas/config.schema.yaml` is intentionally **not** modified — see §9.4.

**Script-written artifacts validate themselves.** The `hooks/validate-on-write.sh`
PostToolUse hook only fires on `Edit`/`Write` *tool* calls; files created or mutated
by a shell script bypass it entirely. So the new scripts must validate inline rather
than rely on the hook:

- `pr-review.sh` runs `frontmatter.sh validate` against `report.md` after the
  initial write (§4 Step 6) and after every status mutation, and runs
  `pr-review.sh canonicalize` after any block-level mutation, failing loudly on a
  schema error.
- `lessons.sh append` runs `frontmatter.sh validate` against `lessons-learned.md`
  after each appended entry.

The hook cases added to `validate-on-write.sh` still matter — they cover the
overseer's *manual* edits to `report.md` (marking, `verdict`/`action`/`overseer-notes`
changes), which do go through the `Edit` tool.

---

## 11. Open decisions

### D1 — `/mo-continue` behavior when a workflow *and* a PR-review report are both live

§6.1 has `/mo-continue` **pause and ask** the overseer (numbered list, chat reply)
when an active workflow and an in-progress PR-review report coexist. The capture
mechanism is the same mid-command pause the stage-3 drift prompt already uses — no
new argument parsing on `/mo-continue`. Alternatives if that is unwanted:
(a) always prefer the workflow stage; (b) always prefer the PR-review apply;
(c) keep the apply step in a dedicated `/mo-apply-review` command and leave
`/mo-continue` untouched. The author asked for `/mo-continue`, so (c) is not the
default — confirm the ask-the-overseer behavior vs. a fixed precedence.

### D2 — Reuse `review-iteration-runner` vs. a new `pr-review-fixer` agent

This plan proposes a new agent (§7.2) because the existing runner is bound to the
stage-6 `overseer-review.md` IR loop. If the two are judged close enough, the
runner could be generalized instead, at the cost of coupling two workflows.

### D3 — `lessons-learned.md` growth

v1 is append-only. Over many PRs the file grows unbounded and the chains pay to
read all of it. Options for later: per-lesson `status: active|retired`, periodic
consolidation, or scoping lessons by area so only relevant ones load. Out of scope
for v1 but should be acknowledged before the file gets large.

*(Former D4 — comment kinds in scope — is resolved; see §2 and §4a.)*

---

## 12. Edge cases

- **No comments / all resolved** — `mo-analyze-review` writes an empty report and
  says so; nothing to mark.
- **`gh` not installed or not authenticated** — preflight refuses with an install hint.
- **Invalid / non-PR / inaccessible URL** — refuse with a usage message.
- **cwd repo does not match the URL's `owner/repo`** — refuse (wrong checkout), at
  both analysis time and apply time.
- **Single-comment URL whose comment is stale or deleted** — skip with a note in the report.
- **Overseer marks nothing on a fresh report** — the §6.2 step-2 guard prints
  "No blocks marked" and exits with the `awaiting-marks` report unchanged (it does
  *not* normalize-then-finalize, which would wrongly close the report as `applied`).
- **`verdict`/`action` edited into contradiction** (e.g. `verdict: valid` + `action: reply`)
  — `action` wins; the apply step does what `action` says.
- **Dirty working tree with actionable fix blocks** — refuse before `gh pr checkout`;
  ask the overseer to stash or commit first. Reply-only runs do not require a clean
  tree and are not blocked by this.
- **Cross-fork PR** — `gh pr checkout` may produce a fork-tracking or detached
  branch; surface it before committing rather than assuming a local branch.
- **PR already merged/closed** — warn; ask the overseer to confirm a target branch
  before fixes are applied. Do not auto-create a branch.
- **Reply post fails or is declined** — block goes `reply-failed` / `reply-declined`,
  report goes `partial`, and `/mo-continue` keeps the report reachable so the
  overseer can retry (or un-mark to drop it).
- **Re-running `mo-analyze-review` on the same PR** — refused while an
  `awaiting-marks`/`partial` report exists; otherwise a new timestamped session dir
  is created and prior `applied` sessions are kept as history.
- **`review-summary` / `issue-comment` marked `action: reply`** — posted as a new
  PR conversation comment quoting the original, since these have no threaded-reply
  endpoint (§4a).

---

## 13. Implementation order

1. `scripts/pr-review.sh` (URL parse + kind-aware `gh`/GraphQL fetch + session dir)
   and `scripts/lessons.sh`.
2. Templates + schemas for `report.md` and `lessons-learned.md`; wire the two new
   cases into `hooks/validate-on-write.sh`.
3. `commands/mo-analyze-review.md` + `agents/review-comment-analyst.md` — end-to-end
   up to a written report (includes the repo guard).
4. `agents/pr-review-fixer.md` + the `/mo-continue` pre-dispatch check and
   PR-Review Apply Handler (repo/worktree guards + checkout).
5. Reply-posting (`pr-review.sh post-reply`, kind-branched) with the confirmation
   prompt and the `partial`/retry state machine.
6. Lessons distillation + `lessons-learned.md` append.
7. `config.md` template + generation changes + primer instruction.
8. `mo-doctor` `gh` check, `docs/sub-agent-profiles/plan.md` registration, version bump.

Each numbered step is independently testable; steps 1–3 deliver the report-writing
half of the feature before any apply logic exists.
