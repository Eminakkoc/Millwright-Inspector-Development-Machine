---
description: Analyze a GitHub PR review. Fetches every review comment (line comments via GraphQL review threads, review summary bodies, and issue comments via REST), spawns the review-comment-analyst sub-agent to judge each one against the codebase, and writes a marked-up report.md the overseer triages before running /mo-continue. Standalone — no active workflow required.
---

# mo-analyze-review

Turns a GitHub PR review into a structured, overseer-triaged work list. The
overseer runs `/mo-analyze-review <pr-url>`; the millwright fetches every review
comment, analyzes each against the real codebase, and writes a **report** — one
block per comment, each a proposed **fix** (the comment is valid) or a proposed
**reply** (the comment is not valid). The overseer then marks the blocks they
want acted on — the same checkbox gesture used for todo-list items — and runs
`/mo-continue` to apply them.

This command is **standalone**: it does not need an active mo-workflow. See
`docs/user-reviews/plan.md` for the full design.

## Usage

```
/mo-analyze-review <github-pr-or-comment-url>
```

Accepted URL forms:

| URL form | Meaning |
| --- | --- |
| `…/pull/<N>` | The whole PR — every unresolved review comment, review summary body, and issue comment. |
| `…/pull/<N>#discussion_r<ID>` | A single line-level review comment (its thread). |
| `…/pull/<N>#pullrequestreview-<ID>` | One review — its summary body and the line comments in it. |

## Execution

### Step 1 — Parse the URL

```bash
url="$ARGUMENTS"
[[ -n "$url" ]] || { echo 'Usage: /mo-analyze-review <github-pr-or-comment-url>' >&2; exit 1; }
# parse-url exits non-zero on an unrecognized URL and prints one TAB-separated
# line. owner/repo are slug-restricted, so the fields are read directly — no
# eval — and a URL carrying shell metacharacters fails the pattern outright.
parsed="$($CLAUDE_PLUGIN_ROOT/scripts/pr-review.sh parse-url "$url")" || exit 1
IFS=$'\t' read -r owner repo pr kind ref_id <<< "$parsed"
```

If `parse-url` exits non-zero, surface its error and stop — the URL is not a
recognized GitHub PR/comment URL.

### Step 2 — Preflight

1. **`gh` installed + authenticated.** Run `gh auth status`. If `gh` is missing
   or not authenticated, print the install/auth hint (`gh auth login`) and stop.
2. **Repository guard.** The current working directory must be the checkout of
   the PR's repository:
   ```bash
   cwd_repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo '')"
   ```
   If `cwd_repo` is empty (cwd is not a GitHub-backed git repo) or does not equal
   `$owner/$repo`, refuse:

   > "This command is running in `<cwd_repo>`, but the PR belongs to
   > `<owner>/<repo>`. Re-run from a checkout of `<owner>/<repo>`."

   The guard is required even for analysis — the `review-comment-analyst` reads
   the working directory to judge each comment, so it must be the right repo.
3. **PR head guard.** The repo alone is not enough — the analyst judges each
   comment against the code in the working directory, so the working tree must
   be on the PR's head commit, not `main` or a stale branch:
   ```bash
   pr_head="$(gh pr view "$pr" --json headRefOid -q .headRefOid 2>/dev/null || echo '')"
   local_head="$(git rev-parse HEAD 2>/dev/null || echo '')"
   ```
   - If `pr_head` is empty, the PR is inaccessible — surface the error and stop.
   - If `local_head != pr_head`, refuse:

     > "Your HEAD (`<local_head>`) is not the PR head (`<pr_head>`). Run
     > `gh pr checkout <pr>` and re-run `/mo-analyze-review` so the analysis
     > judges the PR's actual code."

   - If `git status --porcelain` is non-empty, **warn** that uncommitted local
     changes may skew the analysis and ask the overseer to confirm before
     continuing (a dirty tree is a warning, not a hard refusal — the overseer
     may knowingly be mid-edit).

### Step 3 — Create the session

```bash
session="$($CLAUDE_PLUGIN_ROOT/scripts/pr-review.sh new-session "$owner" "$repo" "$pr")"
```

`new-session` refuses (non-zero exit) if an `awaiting-marks` or `partial` report
already exists for this PR — relay its message and stop; the overseer should
finish or delete that session first. Otherwise it prints a fresh timestamped
session directory.

### Step 4 — Fetch the comments

```bash
fetch_out="$($CLAUDE_PLUGIN_ROOT/scripts/pr-review.sh fetch "$owner" "$repo" "$pr" "$kind" "$ref_id" "$session")"
head_ref="$(echo "$fetch_out" | sed -n 's/^head-ref=//p')"
```

`fetch` writes raw GitHub payloads under `<session>/raw/` and a normalized
`<session>/comments.json` the analyst consumes. If `comments.json` has an empty
`comments` array, print "No review comments found on this PR — nothing to
analyze." and stop.

### Step 5 — Scaffold the report

```bash
report="$session/report.md"
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init pr-review-report "$report" \
  "PR_URL=$url" \
  "REPO=$owner/$repo" \
  "PR_NUMBER=!RAW!$pr" \
  "PR_BRANCH=$head_ref"
```

This writes `report.md` with frontmatter (`status: awaiting-marks`), the
overseer instructions, and an empty `## Comments` section. The analyst appends
the per-comment blocks under that heading.

### Step 6 — Analyze (sub-agent)

Spawn the analyst with `subagent_type: millwright-overseer-development-machine:review-comment-analyst`.
Substitute the resolved values into the spawn prompt:

```
You are a fresh sub-agent invoked from /mo-analyze-review. Your context is
isolated from the main session — main sees only your final return summary.

Repository (current working directory): <cwd_repo>
PR: <owner>/<repo> #<pr>
Normalized comments: <session>/comments.json
Report to append to: <session>/report.md

Read <session>/comments.json — an object `{ "head_ref": ..., "comments": [...] }`.
Each comment carries: kind (review-comment | review-summary | issue-comment),
source_comment_id, reply_target_id, author, url, path, line, thread_state, body.

For EACH comment, in array order, append one block under the `## Comments`
heading of report.md (use Edit). Number the blocks PR-001, PR-002, … in order —
`pr-review.sh canonicalize` will renumber, but write sequential ids anyway.

Judge each comment against the actual code in the working directory:
- Read the file/line the comment references (and enough surrounding code to
  judge it). review-summary / issue-comment blocks may reference no specific
  file — judge them on their merits.
- verdict: `valid` (the comment identifies a real problem worth fixing),
  `invalid` (the comment is mistaken — the code is already correct, or the
  suggestion would be wrong), or `needs-discussion` (legitimate but needs an
  overseer decision).
- action: `fix` when verdict is valid; `reply` when verdict is invalid. For
  needs-discussion, choose `reply` and draft a reply that states the question.

Block shape (copy field names exactly; the commented template in report.md is
the reference):

### PR-001 — [ ] <one-line summary of the comment>
- comment-url:        <url from comments.json>
- comment-kind:       <kind>
- source-comment-id:  <source_comment_id>
- reply-target-id:    <reply_target_id, or blank for non-review-comment kinds>
- comment-author:     @<author>
- location:           <path>:<line>   (blank when path is empty)
- thread-state:       <thread_state>
- verdict:            <valid | invalid | needs-discussion>
- action:             <fix | reply>
- comment: |
    <the comment body, verbatim from comments.json>
- analysis: |
    <your reasoning — cite the file:line you inspected>
- proposed-fix: |        (include ONLY when action is fix)
    <what you would change and in which files — concrete, not vague>
- proposed-reply: |      (include ONLY when action is reply)
    <a courteous, specific reply explaining why no change is needed,
     or stating the question for needs-discussion>
- overseer-notes: |
- status:             open

Rules:
- The `comment:` body must be verbatim — do not paraphrase the reviewer.
- Keep every value on its own `- field:` line; multi-line values use `|`.
- Do NOT mark checkboxes — every block stays `[ ]`; marking is the overseer's job.
- Do NOT edit frontmatter or commit anything. You only append blocks.

Return shape: follow docs/sub-agent-return-contract.md. Name report.md under
`Artifacts changed`. Put a one-line tally (N comments: X fix, Y reply) in the
Result line context. Total return ≤ 1k tokens. Return only this structure.
Do not narrate intermediate steps.
```

### Step 7 — Canonicalize and validate

After the analyst returns:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/pr-review.sh canonicalize "$report"
```

`canonicalize` renumbers the `PR-NNN` ids in document order and validates every
block has an `action` and a `status` line (exit 3 on a structural error — if it
fails, read the offending block, fix it with Edit, and re-run).

### Step 8 — Hand back to the overseer

Print a summary and the next-step instructions:

```
PR-review report ready:
  <session>/report.md

  <N> comment(s) analyzed — <X> proposed fixes, <Y> proposed replies.

Next:
  • Open report.md and flip [ ] → [x] on each block you want acted on.
    You may edit verdict/action and add overseer-notes.
  • Then run /mo-continue — the millwright applies the marked fixes and
    (after you confirm) posts the marked replies to GitHub.

Tip: if the marked work is large, copy this report into a journal/ entry and
run /mo-run to handle it as a full mo-workflow instead.
```

## What this command does NOT do

- **No code changes.** The analyst is read-only; it only proposes. Fixes are
  applied later by `/mo-continue`'s PR-Review Apply Handler.
- **No GitHub writes.** Nothing is posted until the overseer marks reply blocks
  and confirms during `/mo-continue`.
- **No workflow-state mutation.** It does not touch `progress.md`, the queue, or
  any active feature. The report lives in its own `pr-reviews/` session dir.

## See also

- `docs/user-reviews/plan.md` — full design.
- `commands/mo-continue.md` § "PR-Review Apply Handler" — the apply half.
- `agents/review-comment-analyst.md` — the analysis sub-agent.
