#!/usr/bin/env bash
# pr-review.sh — drive the /mo-analyze-review PR-review feature.
#
# Owns the mechanical half of the feature: GitHub URL parsing, kind-aware
# comment fetching (GraphQL review threads + REST review bodies + REST issue
# comments), session-directory management, and the report.md block-state
# machine (canonicalize / normalize / list-actionable / set-status /
# report-status / post-reply). The AI half — judging each comment and
# proposing fixes/replies — lives in the review-comment-analyst sub-agent.
#
# Sessions live under <data_root>/pr-reviews/<owner>-<repo>-pr<N>/<ts>/ and
# each holds report.md plus a raw/ folder of the fetched GitHub payloads.
#
# Self-validation: every subcommand that writes or mutates report.md runs
# frontmatter.sh validate afterwards — the PostToolUse write-hook only fires
# on Edit/Write tool calls, so script-written artifacts must validate inline.
#
# Report status lifecycle:   awaiting-marks → partial → applied
# Block status — terminal:     applied | replied | skipped
#              — non-terminal:  open | reply-failed | reply-declined
#                               | fix-failed | fix-blocked
#
# The report.md body opens with an HTML-comment block holding a worked block
# example; every parser below skips lines inside `<!-- ... -->` so the example
# is never mistaken for a real PR-NNN block.
#
# Usage:
#   pr-review.sh parse-url <github-pr-or-comment-url>
#                                 # prints one TAB-separated line: owner\trepo\tpr\tkind\tref-id
#                                 # (kind ∈ pr|comment|review). owner/repo are slug-restricted so
#                                 # callers can `read` the fields without an eval.
#   pr-review.sh find-awaiting    # TSV of in-progress reports: <status>\t<pr-number>\t<report-path>
#   pr-review.sh new-session <owner> <repo> <pr-number>
#                                 # creates a timestamped session dir, prints its path;
#                                 # refuses if an awaiting-marks/partial session exists for this PR.
#   pr-review.sh fetch <owner> <repo> <pr-number> <kind> <ref-id> <session-dir>
#                                 # gh GraphQL+REST fetch; writes raw/ payloads and comments.json
#   pr-review.sh canonicalize <report.md>
#                                 # renumber PR-NNN sequentially, validate block shape (exit 3 on error)
#   pr-review.sh count-marked <report.md>
#                                 # prints the number of [x]-marked blocks (any status)
#   pr-review.sh normalize <report.md>
#                                 # unmarked [ ] non-terminal blocks → status: skipped
#   pr-review.sh list-actionable <report.md>
#                                 # TSV of marked non-terminal blocks: <PR-NNN>\t<action>\t<comment-kind>\t<status>
#   pr-review.sh set-status <report.md> <PR-NNN> <status>
#   pr-review.sh post-reply <report.md> <PR-NNN>
#                                 # posts the block's proposed-reply to GitHub (endpoint per comment-kind),
#                                 # sets block status to replied on success; exits non-zero on failure.
#   pr-review.sh report-status <report.md>
#                                 # recompute frontmatter status from ALL blocks (applied|partial), print it.

set -euo pipefail
source "$(dirname "$0")/internal/common.sh"

pr_reviews_dir() { echo "$(mo_data_root)/pr-reviews"; }

# Slug for a PR session group: lowercased owner/repo, non-alnum collapsed to '-'.
pr_slug() {
  local owner="$1" repo="$2" pr="$3"
  python3 - "$owner" "$repo" "$pr" <<'PYEOF'
import re, sys
owner, repo, pr = sys.argv[1:4]
def k(s): return re.sub(r'-+', '-', re.sub(r'[^a-z0-9]+', '-', s.lower())).strip('-')
print(f"{k(owner)}-{k(repo)}-pr{pr}")
PYEOF
}

# Validate report.md frontmatter against the pr-review-report schema. Loud on failure.
validate_report() {
  "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$1" pr-review-report >/dev/null
}

require_gh() {
  command -v gh >/dev/null 2>&1 || mo_die "gh (GitHub CLI) is required — install it and run 'gh auth login'"
}

cmd="${1:-}"; shift || true

case "$cmd" in
  parse-url)
    url="${1:?github url required}"
    # owner/repo are restricted to GitHub slug-safe characters so the fields
    # are safe to consume with `read` (no eval). A crafted URL with shell
    # metacharacters fails the pattern outright.
    python3 - "$url" <<'PYEOF'
import re, sys
url = sys.argv[1].strip()
m = re.match(
    r'https?://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/(\d+)(?:\#(.*))?$',
    url,
)
if not m:
    sys.stderr.write(f"error: not a recognized GitHub PR/comment URL: {url}\n")
    sys.exit(1)
owner, repo, pr, frag = m.group(1), m.group(2), m.group(3), m.group(4) or ''
kind, ref_id = 'pr', ''
fm = re.match(r'discussion_r(\d+)$', frag)
fr = re.match(r'pullrequestreview-(\d+)$', frag)
if fm:
    kind, ref_id = 'comment', fm.group(1)
elif fr:
    kind, ref_id = 'review', fr.group(1)
# TAB-separated single line — caller reads it with `IFS=$'\t' read`.
print('\t'.join([owner, repo, pr, kind, ref_id]))
PYEOF
    ;;

  find-awaiting)
    dir="$(pr_reviews_dir)"
    [[ -d "$dir" ]] || exit 0   # absent dir → no reports; caller falls through
    while IFS= read -r report; do
      [[ -f "$report" ]] || continue
      status="$(mo_fm_get "$report" status 2>/dev/null || echo '')"
      case "$status" in
        awaiting-marks|partial)
          pr_number="$(mo_fm_get "$report" pr-number 2>/dev/null || echo '?')"
          printf '%s\t%s\t%s\n' "$status" "$pr_number" "$report"
          ;;
      esac
    done < <(find "$dir" -path '*/report.md' 2>/dev/null | sort)
    ;;

  new-session)
    owner="${1:?owner required}"; repo="${2:?repo required}"; pr="${3:?pr-number required}"
    slug="$(pr_slug "$owner" "$repo" "$pr")"
    group_dir="$(pr_reviews_dir)/$slug"
    # Refuse if an in-progress session already exists for this PR.
    if [[ -d "$group_dir" ]]; then
      while IFS= read -r report; do
        [[ -f "$report" ]] || continue
        st="$(mo_fm_get "$report" status 2>/dev/null || echo '')"
        if [[ "$st" == "awaiting-marks" || "$st" == "partial" ]]; then
          mo_die "an in-progress PR-review report already exists for this PR (status=$st):
       $report
  Finish it (mark blocks + /mo-continue) or delete the session, then retry."
        fi
      done < <(find "$group_dir" -path '*/report.md' 2>/dev/null)
    fi
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    session="$group_dir/$ts"
    mkdir -p "$session/raw"
    echo "$session"
    ;;

  fetch)
    owner="${1:?owner required}"; repo="${2:?repo required}"; pr="${3:?pr-number required}"
    kind="${4:?kind required}"; ref_id="${5:-}"; session="${6:?session-dir required}"
    require_gh
    raw="$session/raw"
    mkdir -p "$raw"

    # Line-level review comments + thread-resolution state — GraphQL.
    # `--paginate` follows the `reviewThreads` cursor (the `$endCursor` variable
    # + `pageInfo` selection are what gh's auto-pagination keys on); `--slurp`
    # collects every page into one JSON array so a >100-thread PR is complete.
    gh api graphql --paginate --slurp \
      -F owner="$owner" -F repo="$repo" -F pr="$pr" \
      -f query='
        query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String){
          repository(owner:$owner,name:$repo){
            pullRequest(number:$pr){
              headRefName
              reviewThreads(first:100, after:$endCursor){
                pageInfo{ hasNextPage endCursor }
                nodes{
                  isResolved isOutdated
                  comments(first:100){
                    pageInfo{ hasNextPage }
                    nodes{
                      databaseId url path line originalLine body
                      author{login}
                      pullRequestReview{databaseId}
                    }
                  }
                }
              }
            }
          }
        }' > "$raw/review-threads.json"

    # Review summary bodies + general issue comments — REST.
    # `--paginate --slurp` returns an array of per-page arrays; the normalizer
    # flattens it. A genuine gh failure aborts here rather than being silently
    # treated as "no comments".
    gh api "repos/$owner/$repo/pulls/$pr/reviews" --paginate --slurp > "$raw/reviews.json"
    gh api "repos/$owner/$repo/issues/$pr/comments" --paginate --slurp > "$raw/issue-comments.json"

    # Normalize into one comments.json array the analyst consumes.
    python3 - "$raw/review-threads.json" "$raw/reviews.json" "$raw/issue-comments.json" \
              "$kind" "$ref_id" "$session/comments.json" <<'PYEOF'
import json, sys
threads_f, reviews_f, issues_f, kind, ref_id, dest = sys.argv[1:7]

def load_required(path, label):
    """Parse a fetched payload — a parse failure is a hard error, never an
    empty result, so the workflow can never claim to have processed every
    comment off a payload it could not read."""
    try:
        with open(path) as f:
            return json.load(f)
    except Exception as e:
        sys.stderr.write(f"error: failed to parse {label} ({path}): {e}\n")
        sys.exit(1)

threads_pages = load_required(threads_f, 'GraphQL review-threads')
reviews_pages = load_required(reviews_f, 'REST reviews')
issues_pages  = load_required(issues_f, 'REST issue-comments')

# `--paginate --slurp` always yields a top-level array of pages.
if not isinstance(threads_pages, list):
    threads_pages = [threads_pages]
if not isinstance(reviews_pages, list):
    reviews_pages = [reviews_pages]
if not isinstance(issues_pages, list):
    issues_pages = [issues_pages]

head_ref = ''
thread_nodes = []
for pg in threads_pages:
    pg = pg or {}
    if pg.get('errors'):
        sys.stderr.write(f"error: GraphQL returned errors: {pg['errors']}\n")
        sys.exit(1)
    prn = (((pg.get('data') or {}).get('repository') or {}).get('pullRequest') or {})
    if not head_ref:
        head_ref = prn.get('headRefName', '') or ''
    thread_nodes += ((prn.get('reviewThreads') or {}).get('nodes') or [])

# A thread with >100 comments is not paginated (the nested `comments`
# connection has no cursor loop). Fail loudly rather than silently drop the
# tail — which could include a direct #discussion_r<ID> target.
truncated = [
    th for th in thread_nodes
    if ((th.get('comments') or {}).get('pageInfo') or {}).get('hasNextPage')
]
if truncated:
    sys.stderr.write(
        f"error: {len(truncated)} review thread(s) have more than 100 comments; "
        "nested comment pagination is not supported. Resolve or trim the thread, "
        "or analyze the specific comment via its #discussion_r<ID> URL.\n"
    )
    sys.exit(1)

# REST slurp pages are arrays of objects — flatten.
reviews_raw = [it for page in reviews_pages for it in (page or [])]
issues_raw  = [it for page in issues_pages for it in (page or [])]

ref = ref_id.strip()
out = []

# --- review-comment: one entry per review thread ---
for th in thread_nodes:
    comments = ((th.get('comments') or {}).get('nodes') or [])
    if not comments:
        continue
    root = comments[0]
    root_db = root.get('databaseId')
    review_db = ((root.get('pullRequestReview') or {}).get('databaseId'))
    # Kind-scoped filtering + source-comment selection.
    if kind == 'comment':
        # The URL points at one specific comment — analyze THAT comment, not
        # the thread root, even when the linked comment is a reply.
        src = next((c for c in comments if str(c.get('databaseId')) == ref), None)
        if src is None:
            continue
        body = f"@{(src.get('author') or {}).get('login','?')}: {src.get('body','')}"
    elif kind == 'review':
        if str(review_db) != ref:
            continue
        src = root
        body = '\n\n'.join(
            f"@{(c.get('author') or {}).get('login','?')}: {c.get('body','')}"
            for c in comments
        )
    else:  # whole PR — skip resolved threads
        if th.get('isResolved'):
            continue
        src = root
        body = '\n\n'.join(
            f"@{(c.get('author') or {}).get('login','?')}: {c.get('body','')}"
            for c in comments
        )
    out.append({
        'kind': 'review-comment',
        # source_comment_id identifies the exact comment under analysis;
        # reply_target_id is always the thread's top-level comment, since
        # GitHub only accepts replies addressed to the thread root.
        'source_comment_id': src.get('databaseId'),
        'reply_target_id': root_db,
        'author': (src.get('author') or {}).get('login', '?'),
        'url': src.get('url', ''),
        'path': src.get('path', '') or '',
        'line': src.get('line') or src.get('originalLine') or '',
        'thread_state': 'resolved' if th.get('isResolved') else 'unresolved',
        'body': body,
    })

# --- review-summary: one entry per review with a non-empty body ---
for rv in reviews_raw:
    rb = (rv.get('body') or '').strip()
    if not rb:
        continue
    rid = rv.get('id')
    if kind == 'review' and str(rid) != ref:
        continue
    if kind == 'comment':
        continue
    out.append({
        'kind': 'review-summary',
        'source_comment_id': rid,
        'reply_target_id': '',
        'author': (rv.get('user') or {}).get('login', '?'),
        'url': rv.get('html_url', ''),
        'path': '',
        'line': '',
        'thread_state': 'n/a',
        'body': rb,
    })

# --- issue-comment: general PR conversation comments ---
for ic in issues_raw:
    ib = (ic.get('body') or '').strip()
    if not ib:
        continue
    if kind in ('comment', 'review'):
        continue
    out.append({
        'kind': 'issue-comment',
        'source_comment_id': ic.get('id'),
        'reply_target_id': '',
        'author': (ic.get('user') or {}).get('login', '?'),
        'url': ic.get('html_url', ''),
        'path': '',
        'line': '',
        'thread_state': 'n/a',
        'body': ib,
    })

with open(dest, 'w') as f:
    json.dump({'head_ref': head_ref, 'comments': out}, f, indent=2)

kinds = {}
for c in out:
    kinds[c['kind']] = kinds.get(c['kind'], 0) + 1
summary = ', '.join(f"{v} {k}" for k, v in sorted(kinds.items())) or 'none'
print(f"fetched {len(out)} comment(s): {summary}")
print(f"head-ref={head_ref}")
PYEOF
    ;;

  canonicalize)
    report="${1:?report.md required}"
    [[ -f "$report" ]] || mo_die "report not found: $report"
    python3 - "$report" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

HEAD_RE = re.compile(r'^### PR-\d{3} — \[[ xX]\] .+$')
ANY_H3  = re.compile(r'^### ')
ANY_H2  = re.compile(r'^## ')
ACTION_RE = re.compile(r'^- action:\s*(fix|reply)\s*$')
STATUS_RE = re.compile(r'^- status:\s*(\S+)\s*$')

# Mark each line as inside an HTML comment (`<!-- ... -->`) or not; comment
# lines hold the worked example and must never be parsed as real blocks.
comment_flag = [False] * len(lines)
in_comment = False
for idx, raw in enumerate(lines):
    line = raw.rstrip('\n')
    if in_comment:
        comment_flag[idx] = True
        if '-->' in line:
            in_comment = False
    else:
        if '<!--' in line:
            comment_flag[idx] = True
            if '-->' not in line:
                in_comment = True

errors = []
count = 0
i, n = 0, len(lines)
while i < n:
    if comment_flag[i]:
        i += 1
        continue
    line = lines[i].rstrip('\n')
    if HEAD_RE.match(line):
        count += 1
        new_id = f"PR-{count:03d}"
        lines[i] = re.sub(r'^### PR-\d{3}', f'### {new_id}', lines[i])
        j = i + 1
        has_action = has_status = False
        while j < n:
            if comment_flag[j]:
                j += 1
                continue
            bl = lines[j].rstrip('\n')
            if ANY_H3.match(bl) or ANY_H2.match(bl):
                break
            if ACTION_RE.match(bl):
                has_action = True
            if STATUS_RE.match(bl):
                has_status = True
            j += 1
        if not has_action:
            errors.append(f"{new_id}: missing or invalid `- action:` line (expected fix|reply)")
        if not has_status:
            errors.append(f"{new_id}: missing `- status:` line")
        i = j
        continue
    if line.startswith('### PR-') or line.startswith('### PR '):
        errors.append(f"malformed PR block heading: {line!r} "
                      f"(expected `### PR-NNN — [ ] <summary>`)")
    i += 1

with open(path, 'w') as f:
    f.writelines(lines)

if errors:
    sys.stderr.write("error: pr-review report failed canonicalization:\n")
    for e in errors:
        sys.stderr.write(f"  - {e}\n")
    sys.exit(3)
print(f"mo: canonicalized {count} PR block(s) in {path}", file=sys.stderr)
PYEOF
    validate_report "$report"
    ;;

  count-marked)
    report="${1:?report.md required}"
    [[ -f "$report" ]] || mo_die "report not found: $report"
    python3 - "$report" <<'PYEOF'
import re, sys
with open(sys.argv[1]) as f:
    lines = f.readlines()
HEAD_RE = re.compile(r'^### PR-\d{3} — \[[xX]\] ')
in_comment = False
count = 0
for raw in lines:
    line = raw.rstrip('\n')
    if in_comment:
        if '-->' in line:
            in_comment = False
        continue
    if '<!--' in line:
        if '-->' not in line:
            in_comment = True
        continue
    if HEAD_RE.match(line):
        count += 1
print(count)
PYEOF
    ;;

  normalize)
    report="${1:?report.md required}"
    [[ -f "$report" ]] || mo_die "report not found: $report"
    python3 - "$report" <<'PYEOF'
import re, sys
path = sys.argv[1]
NON_TERMINAL = {'open', 'reply-failed', 'reply-declined', 'fix-failed', 'fix-blocked'}
with open(path) as f:
    lines = f.readlines()
HEAD_RE = re.compile(r'^### PR-\d{3} — \[([ xX])\] ')
ANY_H3  = re.compile(r'^### ')
ANY_H2  = re.compile(r'^## ')
STATUS_RE = re.compile(r'^(- status:\s*)(\S+)(\s*)$')

comment_flag = [False] * len(lines)
in_comment = False
for idx, raw in enumerate(lines):
    line = raw.rstrip('\n')
    if in_comment:
        comment_flag[idx] = True
        if '-->' in line:
            in_comment = False
    elif '<!--' in line:
        comment_flag[idx] = True
        if '-->' not in line:
            in_comment = True

changed = 0
i, n = 0, len(lines)
while i < n:
    if comment_flag[i]:
        i += 1
        continue
    m = HEAD_RE.match(lines[i].rstrip('\n'))
    if m:
        unmarked = (m.group(1) == ' ')
        j = i + 1
        while j < n:
            if comment_flag[j]:
                j += 1
                continue
            bl = lines[j].rstrip('\n')
            if ANY_H3.match(bl) or ANY_H2.match(bl):
                break
            sm = STATUS_RE.match(bl)
            if sm and unmarked and sm.group(2) in NON_TERMINAL:
                lines[j] = "- status: skipped\n"
                changed += 1
            j += 1
        i = j
        continue
    i += 1
with open(path, 'w') as f:
    f.writelines(lines)
print(f"mo: normalized {changed} unmarked non-terminal block(s) to skipped", file=sys.stderr)
PYEOF
    validate_report "$report"
    ;;

  list-actionable)
    report="${1:?report.md required}"
    [[ -f "$report" ]] || mo_die "report not found: $report"
    python3 - "$report" <<'PYEOF'
import re, sys
path = sys.argv[1]
NON_TERMINAL = {'open', 'reply-failed', 'reply-declined', 'fix-failed', 'fix-blocked'}
with open(path) as f:
    lines = f.readlines()
HEAD_RE = re.compile(r'^### (PR-\d{3}) — \[([ xX])\] ')
ANY_H3  = re.compile(r'^### ')
ANY_H2  = re.compile(r'^## ')
FIELD_RE = re.compile(r'^- (action|status|comment-kind):\s*(\S+)')

comment_flag = [False] * len(lines)
in_comment = False
for idx, raw in enumerate(lines):
    line = raw.rstrip('\n')
    if in_comment:
        comment_flag[idx] = True
        if '-->' in line:
            in_comment = False
    elif '<!--' in line:
        comment_flag[idx] = True
        if '-->' not in line:
            in_comment = True

i, n = 0, len(lines)
while i < n:
    if comment_flag[i]:
        i += 1
        continue
    m = HEAD_RE.match(lines[i].rstrip('\n'))
    if m:
        pid, marked = m.group(1), (m.group(2) in 'xX')
        fields = {}
        j = i + 1
        while j < n:
            if comment_flag[j]:
                j += 1
                continue
            bl = lines[j].rstrip('\n')
            if ANY_H3.match(bl) or ANY_H2.match(bl):
                break
            fm = FIELD_RE.match(bl)
            if fm:
                fields[fm.group(1)] = fm.group(2)
            j += 1
        status = fields.get('status', 'open')
        if marked and status in NON_TERMINAL:
            print(f"{pid}\t{fields.get('action','?')}\t{fields.get('comment-kind','?')}\t{status}")
        i = j
        continue
    i += 1
PYEOF
    ;;

  set-status)
    report="${1:?report.md required}"
    block_id="${2:?PR-NNN required}"
    new_status="${3:?status required}"
    [[ -f "$report" ]] || mo_die "report not found: $report"
    case "$new_status" in
      open|applied|replied|skipped|reply-failed|reply-declined|fix-failed|fix-blocked) ;;
      *) mo_die "invalid block status: $new_status" ;;
    esac
    python3 - "$report" "$block_id" "$new_status" <<'PYEOF'
import re, sys
path, bid, new_status = sys.argv[1:4]
with open(path) as f:
    lines = f.readlines()
HEAD_RE = re.compile(rf'^### {re.escape(bid)} — \[[ xX]\] ')
ANY_H3  = re.compile(r'^### ')
ANY_H2  = re.compile(r'^## ')
STATUS_RE = re.compile(r'^- status:\s*\S+\s*$')

comment_flag = [False] * len(lines)
in_comment = False
for idx, raw in enumerate(lines):
    line = raw.rstrip('\n')
    if in_comment:
        comment_flag[idx] = True
        if '-->' in line:
            in_comment = False
    elif '<!--' in line:
        comment_flag[idx] = True
        if '-->' not in line:
            in_comment = True

i, n, done = 0, len(lines), False
while i < n and not done:
    if not comment_flag[i] and HEAD_RE.match(lines[i].rstrip('\n')):
        j = i + 1
        while j < n:
            if comment_flag[j]:
                j += 1
                continue
            bl = lines[j].rstrip('\n')
            if ANY_H3.match(bl) or ANY_H2.match(bl):
                break
            if STATUS_RE.match(bl):
                lines[j] = f"- status: {new_status}\n"
                done = True
                break
            j += 1
    i += 1
if not done:
    sys.stderr.write(f"error: block {bid} (or its status line) not found in {path}\n")
    sys.exit(1)
with open(path, 'w') as f:
    f.writelines(lines)
print(f"mo: {bid} → {new_status}", file=sys.stderr)
PYEOF
    validate_report "$report"
    ;;

  post-reply)
    report="${1:?report.md required}"
    block_id="${2:?PR-NNN required}"
    [[ -f "$report" ]] || mo_die "report not found: $report"
    require_gh
    repo="$(mo_fm_get "$report" repo)"
    pr_number="$(mo_fm_get "$report" pr-number)"
    [[ "$repo" == */* ]] || mo_die "report frontmatter 'repo' is malformed: $repo"

    # Extract the block's comment-kind, reply-target-id, comment-url and the
    # proposed-reply block scalar. Output: line1=kind, line2=target, line3=url,
    # rest=reply body.
    block_meta="$(python3 - "$report" "$block_id" <<'PYEOF'
import re, sys
path, bid = sys.argv[1], sys.argv[2]
with open(path) as f:
    lines = f.readlines()
HEAD_RE = re.compile(rf'^### {re.escape(bid)} — \[[ xX]\] ')
ANY_H3  = re.compile(r'^### ')
ANY_H2  = re.compile(r'^## ')
FIELD_RE = re.compile(r'^- ([a-z-]+):\s*(.*)$')

comment_flag = [False] * len(lines)
in_comment = False
for idx, raw in enumerate(lines):
    line = raw.rstrip('\n')
    if in_comment:
        comment_flag[idx] = True
        if '-->' in line:
            in_comment = False
    elif '<!--' in line:
        comment_flag[idx] = True
        if '-->' not in line:
            in_comment = True

i, n = 0, len(lines)
fields, reply = {}, []
while i < n:
    if not comment_flag[i] and HEAD_RE.match(lines[i].rstrip('\n')):
        j = i + 1
        while j < n:
            if comment_flag[j]:
                j += 1
                continue
            raw = lines[j].rstrip('\n')
            if ANY_H3.match(raw) or ANY_H2.match(raw):
                break
            fm = FIELD_RE.match(raw)
            if fm:
                key, val = fm.group(1), fm.group(2)
                if key == 'proposed-reply' and val.strip() == '|':
                    j += 1
                    while j < n and (lines[j].startswith('    ') or lines[j].strip() == ''):
                        nxt = lines[j].rstrip('\n')
                        if not nxt.strip() and j + 1 < n and not lines[j+1].startswith('    '):
                            break
                        reply.append(nxt[4:] if nxt.startswith('    ') else '')
                        j += 1
                    continue
                fields[key] = val.strip()
            j += 1
        break
    i += 1
if not fields:
    sys.stderr.write(f"error: block {bid} not found in {path}\n")
    sys.exit(1)
while reply and reply[-1] == '':
    reply.pop()
print(fields.get('comment-kind', ''))
print(fields.get('reply-target-id', ''))
print(fields.get('comment-url', ''))
print('\n'.join(reply))
PYEOF
)"
    comment_kind="$(printf '%s\n' "$block_meta" | sed -n '1p')"
    reply_target="$(printf '%s\n' "$block_meta" | sed -n '2p')"
    comment_url="$(printf '%s\n' "$block_meta" | sed -n '3p')"
    reply_body="$(printf '%s\n' "$block_meta" | tail -n +4)"
    [[ -n "${reply_body//[[:space:]]/}" ]] || mo_die "block $block_id has an empty proposed-reply"

    case "$comment_kind" in
      review-comment)
        [[ "$reply_target" =~ ^[0-9]+$ ]] || mo_die "block $block_id: review-comment needs a numeric reply-target-id"
        if gh api "repos/$repo/pulls/$pr_number/comments/$reply_target/replies" \
             -X POST -f body="$reply_body" >/dev/null; then
          "$0" set-status "$report" "$block_id" replied
          mo_info "posted threaded reply for $block_id"
        else
          mo_die "failed to post threaded reply for $block_id"
        fi
        ;;
      review-summary|issue-comment)
        quoted="$(printf 'Re: %s\n\n%s\n' "$comment_url" "$reply_body")"
        if gh api "repos/$repo/issues/$pr_number/comments" \
             -X POST -f body="$quoted" >/dev/null; then
          "$0" set-status "$report" "$block_id" replied
          mo_info "posted PR conversation comment for $block_id"
        else
          mo_die "failed to post conversation comment for $block_id"
        fi
        ;;
      *)
        mo_die "block $block_id has an unknown comment-kind: '$comment_kind'"
        ;;
    esac
    ;;

  report-status)
    report="${1:?report.md required}"
    [[ -f "$report" ]] || mo_die "report not found: $report"
    new_status="$(python3 - "$report" <<'PYEOF'
import re, sys
path = sys.argv[1]
TERMINAL = {'applied', 'replied', 'skipped'}
with open(path) as f:
    lines = f.readlines()
HEAD_RE = re.compile(r'^### PR-\d{3} — \[[ xX]\] ')
ANY_H3  = re.compile(r'^### ')
ANY_H2  = re.compile(r'^## ')
STATUS_RE = re.compile(r'^- status:\s*(\S+)')

comment_flag = [False] * len(lines)
in_comment = False
for idx, raw in enumerate(lines):
    line = raw.rstrip('\n')
    if in_comment:
        comment_flag[idx] = True
        if '-->' in line:
            in_comment = False
    elif '<!--' in line:
        comment_flag[idx] = True
        if '-->' not in line:
            in_comment = True

all_terminal = True
i, n = 0, len(lines)
while i < n:
    if not comment_flag[i] and HEAD_RE.match(lines[i].rstrip('\n')):
        j = i + 1
        st = 'open'
        while j < n:
            if comment_flag[j]:
                j += 1
                continue
            bl = lines[j].rstrip('\n')
            if ANY_H3.match(bl) or ANY_H2.match(bl):
                break
            sm = STATUS_RE.match(bl)
            if sm:
                st = sm.group(1)
            j += 1
        if st not in TERMINAL:
            all_terminal = False
        i = j
        continue
    i += 1
print('applied' if all_terminal else 'partial')
PYEOF
)"
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" set "$report" status "$new_status" >/dev/null
    validate_report "$report"
    echo "$new_status"
    ;;

  *)
    echo "usage: pr-review.sh {parse-url|find-awaiting|new-session|fetch|canonicalize|count-marked|normalize|list-actionable|set-status|post-reply|report-status} ..." >&2
    exit 2
    ;;
esac
