#!/usr/bin/env bash
#
# review.sh — manage overseer-review.md and review-context.md.
#
# CACHE CONTRACTS (Phase 6.2 of the context-optimization plan).
# This script hosts one cache-aware operation:
#
#   sync-refs <feature> [--refresh-body]
#     Without --refresh-body: re-syncs `requirements-id` frontmatter only;
#       stamps a non-refresh marker. No cache key — runs unconditionally.
#     With --refresh-body: regenerates `## Implemented surface` and
#       `## Open findings (snapshot)` sections of review-context.md from
#       current git state and `list-open` output.
#       Cache key: (requirements-id, base-commit, HEAD-at-iteration-start).
#       The current implementation regenerates unconditionally when the flag
#       is set; a future optimization can add a no-op short-circuit when the
#       cache key matches the prior refresh stamp. See
#       `docs/context optimization/recommendations.md` § "Cache Key
#       Specifications" → `review-context.md` body refresh.
#     Output: exit code only (0 success / non-zero error). No enum.
#
# Discipline rule: no new cache may be added without an entry here AND in
# recommendations.md § "Cache Key Specifications".
#
# Finding id convention: IR-NNN, zero-padded to 3 digits, monotonically
# incrementing across the whole review file. IDs never reset per iteration.
#
# Usage:
#   review.sh init <feature>                              # writes skeleton
#   review.sh add <feature> <severity> <scope> <summary> [details-heredoc-via-stdin]
#                                                          # severity ∈ blocker|major|minor
#                                                          # scope    ∈ fix|re-implement|re-plan|re-spec
#                                                          #   fix           — apply patch directly; no chain re-entry.
#                                                          #   re-implement  — re-invoke executing-plans / subagent-driven-development.
#                                                          #   re-plan       — re-invoke writing-plans (cascades through executing-plans).
#                                                          #   re-spec       — re-invoke brainstorming (cascades through writing-plans + executing-plans).
#   review.sh set-status <feature> <finding-id> <status> [fix-note]
#                                                          # status ∈ open|fixed|wontfix
#   review.sh iterate <feature>                           # adds "## Iteration N" divider
#   review.sh list-open <feature>                         # prints open finding ids, one per line
#   review.sh list-open-summaries <feature>               # TSV: <id>\t<severity>\t<scope>\t<summary>
#                                                          # for every open finding (Phase 6.5).
#   review.sh sync-refs <feature> [--refresh-body]        # sync overseer-review.md's requirements-id
#                                                          # to the current blueprint after a rotation.
#                                                          # With --refresh-body, ALSO regenerates the
#                                                          # `## Implemented surface` and `## Open findings
#                                                          # (snapshot)` sections of review-context.md
#                                                          # from current git state and `list-open`. Used
#                                                          # by /mo-review's per-iteration loop (Phase 1.4).
#   review.sh canonicalize <feature>                      # detect freeform (non-IR-NNN) text under
#                                                          # ## Implementation Review and emit one TSV row
#                                                          # per detected span: <line-start>\t<line-end>\t<text>.
#                                                          # exit 0 — file already canonical (no action needed).
#                                                          # exit 3 — unstructured spans found (millwright must
#                                                          #          classify and convert via review.sh add,
#                                                          #          then strip-freeform the originals).
#   review.sh strip-freeform <feature> <line-start> <line-end>
#                                                          # delete the inclusive [start, end] line range from
#                                                          # the file. Used after canonicalize+add to remove
#                                                          # the original freeform text. Line numbers must match
#                                                          # what canonicalize emitted (call in reverse order
#                                                          # when stripping multiple spans).

set -euo pipefail
source "$(dirname "$0")/internal/common.sh"

review_file() {
  local feature="$1"
  echo "$(mo_impl_dir "$feature")/overseer-review.md"
}

cmd="${1:-}"; shift || true

case "$cmd" in
  init)
    feature="${1:?feature required}"
    dest="$(review_file "$feature")"
    [[ ! -f "$dest" ]] || mo_die "$dest already exists"

    # Pull the requirements-id from the active blueprint to stitch the frontmatter.
    requirements_file="$(mo_blueprints_current "$feature")/requirements.md"
    requirements_id="$(mo_fm_get "$requirements_file" id)"

    mkdir -p "$(dirname "$dest")"
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" init overseer-review "$dest" \
      "REQUIREMENTS_ID=$requirements_id" \
      "FEATURE=$feature"
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$dest" review-file >/dev/null
    mo_info "initialized $dest"
    ;;

  add)
    feature="${1:?feature required}"
    severity="${2:?severity required (blocker|major|minor)}"
    scope="${3:?scope required (fix|re-implement|re-plan|re-spec)}"
    summary="${4:?summary required}"
    dest="$(review_file "$feature")"
    [[ -f "$dest" ]] || mo_die "review file not found: $dest"

    [[ "$severity" =~ ^(blocker|major|minor)$ ]] || mo_die "severity must be blocker|major|minor"
    [[ "$scope" =~ ^(fix|re-implement|re-plan|re-spec)$ ]] || \
      mo_die "scope must be fix|re-implement|re-plan|re-spec"
    heading="## Implementation Review"

    # Determine next id within overseer-review.md.
    last=$( { grep -h -oE '^### IR-[0-9]{3}' "$dest" 2>/dev/null || true; } | \
           sed -E 's/^### IR-0*//' | sort -n | tail -1)
    last="${last:-0}"
    next=$(printf "%03d" $((last + 1)))
    finding_id="IR-${next}"

    details=""
    if [[ ! -t 0 ]]; then
      details="$(cat)"
    fi

    # Append the finding under the section heading.
    python3 - "$dest" "$heading" "$finding_id" "$summary" "$severity" "$scope" "$details" <<'PYEOF'
import sys, re
path, heading, fid, summary, severity, scope, details = sys.argv[1:8]
with open(path) as f:
    content = f.read()
block_lines = [f'### {fid} — {summary}']
block_lines.append(f'- severity: {severity}')
block_lines.append(f'- scope: {scope}')
block_lines.append(f'- status: open')
if details.strip():
    block_lines.append(f'- details: |')
    for line in details.splitlines():
        block_lines.append(f'    {line}')
else:
    block_lines.append(f'- details: ""')
block_lines.append(f'- fix-note: ""')
block = '\n'.join(block_lines) + '\n\n'

# Find the heading line and append just before the next heading (or EOF).
pattern = re.compile(rf'^{re.escape(heading)}\s*$', re.MULTILINE)
m = pattern.search(content)
if not m:
    print(f'error: heading "{heading}" not found in {path}', file=sys.stderr)
    sys.exit(1)
# Find next top-level heading after this one.
next_heading = re.search(r'^## ', content[m.end():], re.MULTILINE)
insert_at = m.end() + next_heading.start() if next_heading else len(content)
new_content = content[:insert_at].rstrip() + '\n\n' + block + content[insert_at:]
with open(path, 'w') as f:
    f.write(new_content)
print(fid)
PYEOF
    ;;

  set-status)
    feature="${1:?feature required}"
    finding_id="${2:?finding-id required}"
    new_status="${3:?status required}"
    fix_note="${4:-}"
    dest="$(review_file "$feature")"
    [[ -f "$dest" ]] || mo_die "review file not found: $dest"
    [[ "$new_status" =~ ^(open|fixed|wontfix)$ ]] || mo_die "status must be open|fixed|wontfix"
    python3 - "$dest" "$finding_id" "$new_status" "$fix_note" <<'PYEOF'
import sys, re
path, fid, new_status, fix_note = sys.argv[1:5]
with open(path) as f:
    content = f.read()
# Locate the finding block.
block_re = re.compile(rf'(### {re.escape(fid)} — .*?\n)(.*?)(?=\n### |\n## |\Z)', re.DOTALL)
m = block_re.search(content)
if not m:
    print(f'error: finding {fid} not found in {path}', file=sys.stderr)
    sys.exit(1)
block = m.group(2)
block = re.sub(r'- status:.*', f'- status: {new_status}', block)
if fix_note:
    block = re.sub(r'- fix-note:.*', f'- fix-note: |', block)
    block += ''.join(f'    {line}\n' for line in fix_note.splitlines())
new_content = content[:m.start(2)] + block + content[m.end(2):]
with open(path, 'w') as f:
    f.write(new_content)
print(f'mo: {fid} → {new_status}', file=sys.stderr)
PYEOF
    ;;

  iterate)
    feature="${1:?feature required}"
    dest="$(review_file "$feature")"
    [[ -f "$dest" ]] || mo_die "review file not found: $dest"
    # Count existing Iteration N headings; N+1 is the new one.
    last=$(grep -c "^## Iteration " "$dest" || true)
    next=$((last + 2))  # Iteration 1 is implicit; explicit numbering starts at 2.
    cat >> "$dest" <<EOF

## Iteration $next

EOF
    mo_info "added Iteration $next to $dest"
    ;;

  list-open)
    feature="${1:?feature required}"
    dest="$(review_file "$feature")"
    [[ -f "$dest" ]] || mo_die "review file not found: $dest"
    python3 - "$dest" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    content = f.read()
for m in re.finditer(r'### (IR-\d{3}) — .*?\n(.*?)(?=\n### |\n## |\Z)', content, re.DOTALL):
    fid, block = m.group(1), m.group(2)
    status_m = re.search(r'- status:\s*(\S+)', block)
    if status_m and status_m.group(1) == 'open':
        print(fid)
PYEOF
    ;;

  list-open-summaries)
    # Phase 6.5 of the context-optimization plan: emit IR-id + severity +
    # scope + summary for every open finding, WITHOUT the multi-line
    # `details:` body. Used by stages 5, 6 when only a cheat-sheet view is
    # needed (e.g., the per-iteration sub-agent prompt's open-findings
    # section). Reduces main-context reads when overseer-review.md has long
    # details bodies.
    #
    # Output format: one TSV row per open finding —
    #   <IR-id>\t<severity>\t<scope>\t<summary>
    feature="${1:?feature required}"
    dest="$(review_file "$feature")"
    [[ -f "$dest" ]] || mo_die "review file not found: $dest"
    python3 - "$dest" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    content = f.read()
for m in re.finditer(r'### (IR-\d{3}) — (.+?)\n(.*?)(?=\n### |\n## |\Z)', content, re.DOTALL):
    fid, summary, block = m.group(1), m.group(2).strip(), m.group(3)
    status_m = re.search(r'^- status:\s*(\S+)', block, re.MULTILINE)
    severity_m = re.search(r'^- severity:\s*(\S+)', block, re.MULTILINE)
    scope_m = re.search(r'^- scope:\s*(\S+)', block, re.MULTILINE)
    if status_m and status_m.group(1) == 'open':
        sev = severity_m.group(1) if severity_m else 'unknown'
        scope = scope_m.group(1) if scope_m else 'unknown'
        # TSV: tab-separated; summary may contain spaces but no tabs.
        # Strip any embedded tabs from summary to keep TSV well-formed.
        summary_clean = summary.replace('\t', ' ')
        print(f'{fid}\t{sev}\t{scope}\t{summary_clean}')
PYEOF
    ;;

  sync-refs)
    # Update overseer-review.md's and review-context.md's requirements-id
    # frontmatter to match the current blueprints/current/requirements.md id.
    # Called after blueprint rotation + regeneration so an in-flight review
    # loop keeps its frontmatter pointing at live scope. Silently skips files
    # that don't exist.
    #
    # By default the body of review-context.md is NOT regenerated — only the
    # frontmatter is synced and a staleness marker is stamped. Pass
    # --refresh-body to ALSO regenerate the `## Implemented surface` and
    # `## Open findings (snapshot)` sections from current git state and
    # `review.sh list-open` output. /mo-review's per-iteration loop calls
    # --refresh-body at iteration start so the snapshot reflects commits
    # made by the previous iteration's sub-agent (Phase 1.4 of the
    # context-optimization plan).
    feature=""
    refresh_body=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --refresh-body) refresh_body=1; shift ;;
        --) shift; break ;;
        -*) mo_die "sync-refs: unknown flag: $1" ;;
        *)
          if [[ -z "$feature" ]]; then
            feature="$1"
          else
            mo_die "sync-refs: unexpected positional arg: $1"
          fi
          shift
          ;;
      esac
    done
    [[ -n "$feature" ]] || mo_die "sync-refs: feature required"
    new_requirements_id="$(mo_fm_get "$(mo_blueprints_current "$feature")/requirements.md" id)"
    rf="$(review_file "$feature")"
    if [[ -f "$rf" ]]; then
      mo_fm_set "$rf" requirements-id "$new_requirements_id"
      mo_info "synced refs in $rf (requirements-id=$new_requirements_id)"
    fi
    ctx="$(mo_impl_dir "$feature")/review-context.md"
    if [[ -f "$ctx" ]]; then
      mo_fm_set "$ctx" requirements-id "$new_requirements_id"
      # Stamp a body marker so the staleness window is visible to readers.
      # The marker lives between `<!-- mo:sync-marker -->` and the next blank
      # line / `<!--` so it can be replaced idempotently across re-runs.
      ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      python3 - "$ctx" "$ts" "$refresh_body" <<'PYEOF'
import re, sys
path, ts, refresh = sys.argv[1], sys.argv[2], sys.argv[3] == '1'
with open(path) as f:
    body = f.read()
if refresh:
    marker_text = (
        f"\n> _Body sections (`## Implemented surface`, `## Open findings (snapshot)`) "
        f"refreshed at {ts}. `requirements-id` also synced. Read canonical files "
        f"(`overseer-review.md`, `requirements.md`) when current state matters beyond "
        f"this snapshot._\n"
    )
else:
    marker_text = (
        f"\n> _Frontmatter `requirements-id` last synced at {ts} (mid-cycle "
        f"blueprint refresh). Body content above and below was captured at "
        f"`/mo-review` invocation and is NOT regenerated; read canonical files "
        f"for current scope._\n"
    )
pat = re.compile(
    r'(<!--\s*mo:sync-marker[^>]*-->)(.*?)(?=\n\s*\n|\n<!--)',
    re.DOTALL,
)
m = pat.search(body)
if m:
    body = body[:m.end(1)] + marker_text + body[m.end():]
    with open(path, 'w') as f:
        f.write(body)
PYEOF

      if [[ "$refresh_body" == "1" ]]; then
        # Regenerate the body's `## Implemented surface` and
        # `## Open findings (snapshot)` sections.
        base_commit="$("${MO_PLUGIN_ROOT}/scripts/progress.sh" get base-commit 2>/dev/null || echo '')"
        ov_file="$(review_file "$feature")"
        impl_dir="$(mo_impl_dir "$feature")"
        diagrams_dir="$impl_dir/diagrams"
        python3 - "$ctx" "$ov_file" "$base_commit" "$diagrams_dir" <<'PYEOF'
import re, sys, subprocess
from pathlib import Path

ctx_path = sys.argv[1]
ov_path = sys.argv[2]
base_commit = sys.argv[3] or None
diagrams_dir = Path(sys.argv[4])

# --- Build new "Open findings (snapshot)" body ---
findings_lines = []
if Path(ov_path).is_file():
    with open(ov_path) as f:
        ov = f.read()
    for m in re.finditer(
        r'### (IR-\d{3}) — (.+?)\n(.*?)(?=\n### |\n## |\Z)',
        ov, re.DOTALL
    ):
        fid, summary, block = m.group(1), m.group(2).strip(), m.group(3)
        status_m = re.search(r'^- status:\s*(\S+)', block, re.MULTILINE)
        severity_m = re.search(r'^- severity:\s*(\S+)', block, re.MULTILINE)
        scope_m = re.search(r'^- scope:\s*(\S+)', block, re.MULTILINE)
        if status_m and status_m.group(1) == 'open':
            sev = severity_m.group(1) if severity_m else 'unknown'
            scope = scope_m.group(1) if scope_m else 'unknown'
            findings_lines.append(f'- `{fid}` ({sev}, {scope}): {summary}')
findings_body = '\n'.join(findings_lines) if findings_lines else '_No open findings._'

# --- Build new "Implemented surface" body ---
surface_lines = []
files = []
if base_commit:
    try:
        out = subprocess.check_output(
            ['git', 'diff', '--name-only', f'{base_commit}..HEAD'],
            text=True, stderr=subprocess.DEVNULL,
        )
        files = [f.strip() for f in out.split('\n') if f.strip()]
    except subprocess.CalledProcessError:
        files = []

if files:
    areas = {}
    for fp in files:
        parts = fp.split('/')
        area = '/'.join(parts[:2]) if len(parts) > 1 else parts[0]
        areas.setdefault(area, 0)
        areas[area] += 1
    surface_lines.append('Changed areas:')
    for area in sorted(areas):
        n = areas[area]
        surface_lines.append(f'- `{area}/` ({n} file{"s" if n != 1 else ""})')
else:
    surface_lines.append('Changed areas: _none in `base-commit..HEAD` yet_')

surface_lines.append('')
surface_lines.append('Diagrams:')
if diagrams_dir.is_dir():
    pumls = sorted(diagrams_dir.glob('*.puml'))
    if pumls:
        for p in pumls:
            surface_lines.append(f'- `{p.name}`')
    else:
        surface_lines.append('- _no `.puml` files in `implementation/diagrams/`_')
else:
    surface_lines.append('- _`implementation/diagrams/` missing (skipped at stage 4 or not yet generated)_')

surface_body = '\n'.join(surface_lines)

# --- Replace the two sections in the ctx file ---
with open(ctx_path) as f:
    ctx = f.read()

def replace_section(text, heading, new_body):
    pat = re.compile(
        rf'(^## {re.escape(heading)}\s*\n)(.*?)(?=^## |\Z)',
        re.MULTILINE | re.DOTALL,
    )
    if pat.search(text):
        return pat.sub(lambda _m: _m.group(1) + '\n' + new_body + '\n\n', text, count=1)
    sys.stderr.write(f"warning: heading '## {heading}' not found in {ctx_path}; skipped\n")
    return text

ctx = replace_section(ctx, 'Implemented surface', surface_body)
ctx = replace_section(ctx, 'Open findings (snapshot)', findings_body)

with open(ctx_path, 'w') as f:
    f.write(ctx)
PYEOF
        mo_info "synced refs in $ctx (requirements-id=$new_requirements_id; refreshed body)"
      else
        mo_info "synced refs in $ctx (requirements-id=$new_requirements_id; stamped sync marker)"
      fi
    fi
    cs="$(mo_impl_dir "$feature")/change-summary.md"
    if [[ -f "$cs" ]]; then
      mo_fm_set "$cs" requirements-id "$new_requirements_id"
      mo_info "synced refs in $cs (requirements-id=$new_requirements_id)"
    fi
    ;;

  canonicalize)
    feature="${1:?feature required}"
    dest="$(review_file "$feature")"
    [[ -f "$dest" ]] || mo_die "review file not found: $dest"
    # Walk lines under `## Implementation Review` (and any `## Iteration N`
    # sections), grouping consecutive non-blank, non-structured lines into
    # spans. Skip:
    #   - HTML comments (single-line and the opening line of multi-line ones)
    #   - lines belonging to a `### IR-NNN` block (heading itself or the
    #     `- field:` / continuation lines until the next blank line or heading)
    #   - blank lines
    # Anything else under the review heading is "freeform".
    python3 - "$dest" <<'PYEOF'
import re, sys

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

REVIEW_RE   = re.compile(r'^## Implementation Review\s*$')
ITER_RE     = re.compile(r'^## Iteration \d+\s*$')
OTHER_H2_RE = re.compile(r'^## ')
IR_HEAD_RE  = re.compile(r'^### IR-\d{3} —')
COMMENT_RE  = re.compile(r'^\s*<!--')
FIELD_RE    = re.compile(r'^- (severity|scope|status|details|fix-note):')
CONT_RE     = re.compile(r'^    ')   # block-scalar continuation under `details: |`

in_review = False
in_ir_block = False
spans = []          # list of (start_line_1based, end_line_1based, text)
cur_start = None
cur_text  = []

def flush(end_line):
    if cur_start is not None:
        spans.append((cur_start, end_line, '\n'.join(cur_text).strip()))

for i, raw in enumerate(lines, start=1):
    line = raw.rstrip('\n')
    stripped = line.strip()

    # Section boundaries: enter on review/iteration heading, leave on any other ##.
    if REVIEW_RE.match(line) or ITER_RE.match(line):
        flush(i - 1)
        cur_start = None
        cur_text  = []
        in_review = True
        in_ir_block = False
        continue
    if OTHER_H2_RE.match(line):
        flush(i - 1)
        cur_start = None
        cur_text  = []
        in_review = False
        in_ir_block = False
        continue
    if not in_review:
        continue

    # Inside the review section.
    if IR_HEAD_RE.match(line):
        flush(i - 1)
        cur_start = None
        cur_text  = []
        in_ir_block = True
        continue
    if in_ir_block:
        # Stay in the IR block while we see structured fields, continuations,
        # or blanks. Leave on the first non-structured non-blank line.
        if stripped == '' or FIELD_RE.match(line) or CONT_RE.match(line):
            continue
        in_ir_block = False
        # fall through — this line is freeform under the heading.

    if stripped == '' or COMMENT_RE.match(line):
        flush(i - 1)
        cur_start = None
        cur_text  = []
        continue

    # Freeform line — accumulate into the current span.
    if cur_start is None:
        cur_start = i
    cur_text.append(line)

flush(len(lines))

if not spans:
    sys.exit(0)

for start, end, text in spans:
    # TSV: tabs in text are dropped; newlines flattened to spaces so each span
    # is exactly one row.
    flat = re.sub(r'\s+', ' ', text).strip()
    print(f'{start}\t{end}\t{flat}')

sys.exit(3)
PYEOF
    ;;

  strip-freeform)
    feature="${1:?feature required}"
    line_start="${2:?line-start required}"
    line_end="${3:?line-end required}"
    dest="$(review_file "$feature")"
    [[ -f "$dest" ]] || mo_die "review file not found: $dest"
    python3 - "$dest" "$line_start" "$line_end" <<'PYEOF'
import sys
path, start, end = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(path) as f:
    lines = f.readlines()
if start < 1 or end > len(lines) or start > end:
    sys.stderr.write(f"error: invalid line range {start}-{end} (file has {len(lines)} lines)\n")
    sys.exit(1)
del lines[start - 1:end]
with open(path, 'w') as f:
    f.writelines(lines)
print(f"mo: stripped lines {start}-{end} from {path}", file=sys.stderr)
PYEOF
    ;;

  *)
    echo "usage: review.sh {init|add|set-status|iterate|list-open|list-open-summaries|sync-refs|canonicalize|strip-freeform} ..." >&2
    exit 2
    ;;
esac
