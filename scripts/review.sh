#!/usr/bin/env bash
#
# review.sh — manage inspector-review.md and review-context.md.
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
#   review.sh sync-refs <feature> [--refresh-body]        # sync inspector-review.md's requirements-id
#                                                          # to the current blueprint after a rotation.
#                                                          # With --refresh-body, ALSO regenerates the
#                                                          # `## Implemented surface` and `## Open findings
#                                                          # (snapshot)` sections of review-context.md
#                                                          # from current git state and `list-open`. Used
#                                                          # by /mi-review's per-iteration loop (Phase 1.4).
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
  echo "$(mi_impl_dir "$feature")/inspector-review.md"
}

cmd="${1:-}"; shift || true

case "$cmd" in
  init)
    feature="${1:?feature required}"
    dest="$(review_file "$feature")"
    [[ ! -f "$dest" ]] || mi_die "$dest already exists"

    # Pull the requirements-id from the active blueprint to stitch the frontmatter.
    requirements_file="$(mi_blueprints_current "$feature")/requirements.md"
    requirements_id="$(mi_fm_get "$requirements_file" id)"

    mkdir -p "$(dirname "$dest")"
    "${MI_PLUGIN_ROOT}/scripts/frontmatter.sh" init inspector-review "$dest" \
      "REQUIREMENTS_ID=$requirements_id" \
      "FEATURE=$feature"
    "${MI_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$dest" review-file >/dev/null
    mi_info "initialized $dest"
    ;;

  add)
    feature="${1:?feature required}"; shift
    severity="${1:?severity required (blocker|major|minor)}"; shift
    scope="${1:?scope required (fix|re-implement|re-plan|re-spec)}"; shift
    summary="${1:?summary required}"; shift
    source_field=""
    seed_id_field=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --source)
          [[ $# -ge 2 ]] || mi_die "add: --source requires a value"
          source_field="$2"; shift 2
          ;;
        --source=*)
          source_field="${1#--source=}"; shift
          ;;
        --seed-id)
          [[ $# -ge 2 ]] || mi_die "add: --seed-id requires a value"
          seed_id_field="$2"; shift 2
          ;;
        --seed-id=*)
          seed_id_field="${1#--seed-id=}"; shift
          ;;
        *)
          mi_die "add: unknown argument: $1 (expected --source|--seed-id)"
          ;;
      esac
    done
    dest="$(review_file "$feature")"
    [[ -f "$dest" ]] || mi_die "review file not found: $dest"

    [[ "$severity" =~ ^(blocker|major|minor)$ ]] || mi_die "severity must be blocker|major|minor"
    [[ "$scope" =~ ^(fix|re-implement|re-plan|re-spec)$ ]] || \
      mi_die "scope must be fix|re-implement|re-plan|re-spec"
    heading="## Implementation Review"

    # Determine next id within inspector-review.md.
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
    python3 - "$dest" "$heading" "$finding_id" "$summary" "$severity" "$scope" "$source_field" "$seed_id_field" "$details" <<'PYEOF'
import sys, re
path, heading, fid, summary, severity, scope, source, seed_id, details = sys.argv[1:10]
with open(path) as f:
    content = f.read()
block_lines = [f'### {fid} — {summary}']
block_lines.append(f'- severity: {severity}')
block_lines.append(f'- scope: {scope}')
block_lines.append(f'- status: open')
# Optional source/seed-id come BEFORE details so the `details: |` block scalar
# (matched by CONT_RE four-space indentation) stays at the end of the field list.
if source:
    block_lines.append(f'- source: {source}')
if seed_id:
    block_lines.append(f'- seed-id: {seed_id}')
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
    [[ -f "$dest" ]] || mi_die "review file not found: $dest"
    [[ "$new_status" =~ ^(open|fixed|wontfix)$ ]] || mi_die "status must be open|fixed|wontfix"
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
print(f'mi: {fid} → {new_status}', file=sys.stderr)
PYEOF
    ;;

  iterate)
    feature="${1:?feature required}"
    dest="$(review_file "$feature")"
    [[ -f "$dest" ]] || mi_die "review file not found: $dest"
    # Count existing Iteration N headings; N+1 is the new one.
    last=$(grep -c "^## Iteration " "$dest" || true)
    next=$((last + 2))  # Iteration 1 is implicit; explicit numbering starts at 2.
    cat >> "$dest" <<EOF

## Iteration $next

EOF
    mi_info "added Iteration $next to $dest"
    ;;

  list-open)
    feature="${1:?feature required}"
    dest="$(review_file "$feature")"
    [[ -f "$dest" ]] || mi_die "review file not found: $dest"
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
    # section). Reduces main-context reads when inspector-review.md has long
    # details bodies.
    #
    # Output format: one TSV row per open finding —
    #   <IR-id>\t<severity>\t<scope>\t<summary>
    feature="${1:?feature required}"
    dest="$(review_file "$feature")"
    [[ -f "$dest" ]] || mi_die "review file not found: $dest"
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
    # Update inspector-review.md's and review-context.md's requirements-id
    # frontmatter to match the current blueprints/current/requirements.md id.
    # Called after blueprint rotation + regeneration so an in-flight review
    # loop keeps its frontmatter pointing at live scope. Silently skips files
    # that don't exist.
    #
    # By default the body of review-context.md is NOT regenerated — only the
    # frontmatter is synced and a staleness marker is stamped. Pass
    # --refresh-body to ALSO regenerate the `## Implemented surface` and
    # `## Open findings (snapshot)` sections from current git state and
    # `review.sh list-open` output. /mi-review's per-iteration loop calls
    # --refresh-body at iteration start so the snapshot reflects commits
    # made by the previous iteration's sub-agent (Phase 1.4 of the
    # context-optimization plan).
    feature=""
    refresh_body=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --refresh-body) refresh_body=1; shift ;;
        --) shift; break ;;
        -*) mi_die "sync-refs: unknown flag: $1" ;;
        *)
          if [[ -z "$feature" ]]; then
            feature="$1"
          else
            mi_die "sync-refs: unexpected positional arg: $1"
          fi
          shift
          ;;
      esac
    done
    [[ -n "$feature" ]] || mi_die "sync-refs: feature required"
    new_requirements_id="$(mi_fm_get "$(mi_blueprints_current "$feature")/requirements.md" id)"
    rf="$(review_file "$feature")"
    if [[ -f "$rf" ]]; then
      mi_fm_set "$rf" requirements-id "$new_requirements_id"
      mi_info "synced refs in $rf (requirements-id=$new_requirements_id)"
    fi
    ctx="$(mi_impl_dir "$feature")/review-context.md"
    if [[ -f "$ctx" ]]; then
      mi_fm_set "$ctx" requirements-id "$new_requirements_id"
      # Stamp a body marker so the staleness window is visible to readers.
      # The marker lives between `<!-- mi:sync-marker -->` and the next blank
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
        f"(`inspector-review.md`, `requirements.md`) when current state matters beyond "
        f"this snapshot._\n"
    )
else:
    marker_text = (
        f"\n> _Frontmatter `requirements-id` last synced at {ts} (mid-cycle "
        f"blueprint refresh). Body content above and below was captured at "
        f"`/mi-review` invocation and is NOT regenerated; read canonical files "
        f"for current scope._\n"
    )
pat = re.compile(
    r'(<!--\s*mi:sync-marker[^>]*-->)(.*?)(?=\n\s*\n|\n<!--)',
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
        base_commit="$("${MI_PLUGIN_ROOT}/scripts/progress.sh" get base-commit 2>/dev/null || echo '')"
        ov_file="$(review_file "$feature")"
        impl_dir="$(mi_impl_dir "$feature")"
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
        mi_info "synced refs in $ctx (requirements-id=$new_requirements_id; refreshed body)"
      else
        mi_info "synced refs in $ctx (requirements-id=$new_requirements_id; stamped sync marker)"
      fi
    fi
    cs="$(mi_impl_dir "$feature")/change-summary.md"
    if [[ -f "$cs" ]]; then
      mi_fm_set "$cs" requirements-id "$new_requirements_id"
      mi_info "synced refs in $cs (requirements-id=$new_requirements_id)"
    fi
    ;;

  canonicalize)
    feature="${1:?feature required}"
    dest="$(review_file "$feature")"
    [[ -f "$dest" ]] || mi_die "review file not found: $dest"
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
FIELD_RE    = re.compile(r'^- (severity|scope|status|source|seed-id|details|fix-note):')
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
    [[ -f "$dest" ]] || mi_die "review file not found: $dest"
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
print(f"mi: stripped lines {start}-{end} from {path}", file=sys.stderr)
PYEOF
    ;;

  find-by-seed-id)
    feature="${1:?feature required}"
    seed_id="${2:?seed-id required}"
    dest="$(review_file "$feature")"
    [[ -f "$dest" ]] || mi_die "review file not found: $dest"
    python3 - "$dest" "$seed_id" <<'PYEOF'
import sys, re
path, target = sys.argv[1], sys.argv[2]
with open(path) as f:
    lines = f.readlines()
IR_HEAD_RE = re.compile(r'^### (IR-\d{3}) —')
SEED_RE    = re.compile(r'^- seed-id:\s*(.*?)\s*$')
H2_RE      = re.compile(r'^## ')
cur_id = None
for line in lines:
    if H2_RE.match(line):
        cur_id = None
        continue
    m = IR_HEAD_RE.match(line)
    if m:
        cur_id = m.group(1)
        continue
    if cur_id is None:
        continue
    s = SEED_RE.match(line)
    if s and s.group(1) == target:
        print(cur_id)
        sys.exit(0)
sys.exit(0)
PYEOF
    ;;

  find-by-seed-id-family)
    feature="${1:?feature required}"
    base_seed_id="${2:?base-seed-id required}"
    dest="$(review_file "$feature")"
    [[ -f "$dest" ]] || mi_die "review file not found: $dest"
    python3 - "$dest" "$base_seed_id" <<'PYEOF'
import sys, re
path, base = sys.argv[1], sys.argv[2]
with open(path) as f:
    lines = f.readlines()

IR_HEAD_RE = re.compile(r'^### (IR-\d{3}) —')
FIELD_RE   = re.compile(r'^- (severity|scope|status|source|seed-id|details|fix-note):\s*(.*?)\s*$')
H2_RE      = re.compile(r'^## ')

# Walk top-down, capturing current IR's seed-id and status. An IR block
# ends at the next ### heading or a top-level (## ) heading.
rows = []  # (sort_key, ir_id, seed_id, status)
cur_id = None
cur_seed = None
cur_status = None

def emit():
    global cur_id, cur_seed, cur_status
    if cur_id is None or cur_seed is None:
        cur_id = cur_seed = cur_status = None
        return
    sort_key = None
    # Match base exactly OR <base>:r<N> where N is canonical positive decimal
    # (no :r0, no leading zeros). Literal-string matching, not regex on base.
    if cur_seed == base:
        sort_key = 0
    else:
        prefix = base + ":r"
        if cur_seed.startswith(prefix):
            suf = cur_seed[len(prefix):]
            if suf and suf[0] != '0' and suf.isdigit():
                sort_key = int(suf)
    if sort_key is not None:
        rows.append((sort_key, cur_id, cur_seed, cur_status or 'open'))
    cur_id = cur_seed = cur_status = None

for line in lines:
    if H2_RE.match(line):
        emit()
        continue
    m = IR_HEAD_RE.match(line)
    if m:
        emit()
        cur_id = m.group(1)
        cur_seed = None
        cur_status = None
        continue
    if cur_id is None:
        continue
    f = FIELD_RE.match(line)
    if f:
        key, val = f.group(1), f.group(2)
        if key == 'seed-id':
            cur_seed = val
        elif key == 'status':
            cur_status = val
emit()

rows.sort(key=lambda r: r[0])  # numeric ascending; base (0) first.
for _, ir_id, seed, status in rows:
    print(f"{ir_id}\t{seed}\t{status}")
PYEOF
    ;;

  upsert-manual-test-failure)
    feature="${1:?feature required}"; shift
    seed_family_id="${1:?seed-family-id required}"; shift
    scenario_id="${1:?scenario-id required}"; shift
    severity="${1:?severity required (blocker|major|minor)}"; shift
    scope="${1:?scope required (fix|re-implement|re-plan|re-spec)}"; shift
    [[ "$severity" =~ ^(blocker|major|minor)$ ]] || mi_die "severity must be blocker|major|minor"
    [[ "$scope" =~ ^(fix|re-implement|re-plan|re-spec)$ ]] || \
      mi_die "scope must be fix|re-implement|re-plan|re-spec"
    flag_reopen=""
    flag_new_finding=""
    flag_force_new_regression=""
    flag_reclassify=""
    file_citation=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --reopen) flag_reopen=1; shift ;;
        --new-finding) flag_new_finding=1; shift ;;
        --force-new-regression) flag_force_new_regression=1; shift ;;
        --reclassify) flag_reclassify=1; shift ;;
        --file-citation)
          [[ $# -ge 2 ]] || mi_die "upsert-manual-test-failure: --file-citation requires a value"
          file_citation="$2"; shift 2
          ;;
        --file-citation=*) file_citation="${1#--file-citation=}"; shift ;;
        *) mi_die "upsert-manual-test-failure: unknown argument: $1" ;;
      esac
    done
    dest="$(review_file "$feature")"
    [[ -f "$dest" ]] || mi_die "review file not found: $dest"

    # Read multi-line observation body from stdin (mirrors `review.sh add`).
    observation=""
    if [[ ! -t 0 ]]; then
      observation="$(cat)"
    fi

    python3 - \
      "$dest" "$seed_family_id" "$scenario_id" "$severity" "$scope" \
      "$flag_reopen" "$flag_new_finding" "$flag_force_new_regression" "$flag_reclassify" \
      "$file_citation" "$observation" <<'PYEOF'
import sys, re

path = sys.argv[1]
seed_family_id = sys.argv[2]
scenario_id    = sys.argv[3]
severity_arg   = sys.argv[4]
scope_arg      = sys.argv[5]
opt_reopen     = bool(sys.argv[6])
opt_new        = bool(sys.argv[7])
opt_force_new  = bool(sys.argv[8])
opt_reclass    = bool(sys.argv[9])
file_citation  = sys.argv[10]
observation    = sys.argv[11]

# 0. Mutual-exclusion check.
if opt_reopen and opt_new:
    sys.stderr.write("error: --reopen and --new-finding are mutually exclusive\n")
    sys.exit(1)
# --force-new-regression is meaningful only with --new-finding (defensive guard;
# the runner-level dispatch already gates on this, but the helper double-checks).
if opt_force_new and not opt_new:
    sys.stderr.write("error: --force-new-regression requires --new-finding\n")
    sys.exit(1)

base_seed_id = f"manual-test:{seed_family_id}:{scenario_id}"
HEADING = "## Implementation Review"

with open(path) as f:
    content = f.read()

# Locate the Implementation Review section (insertion point for new blocks).
heading_re = re.compile(r'^## Implementation Review\s*$', re.MULTILINE)
hm = heading_re.search(content)
if not hm:
    sys.stderr.write(f'error: heading "{HEADING}" not found in {path}\n')
    sys.exit(1)

# Parse all IR blocks under all sections so we can find by seed-id and
# allocate the next IR-NNN globally. The block boundary uses the same shape as
# canonicalize: ends at the next `### IR-` or top-level `## ` heading or EOF.
lines = content.split('\n')
IR_HEAD_RE = re.compile(r'^### (IR-(\d{3})) — (.*)$')
H2_RE      = re.compile(r'^## ')
FIELD_RE   = re.compile(r'^- (severity|scope|status|source|seed-id|fix-note):\s*(.*?)\s*$')
DETAILS_HEAD_RE = re.compile(r'^- details:\s*(\|)?\s*(.*?)\s*$')
CONT_RE    = re.compile(r'^    ')

class IRBlock:
    __slots__ = ("ir_id","ir_num","summary","start","end","fields","details","details_block","raw")
    def __init__(self):
        self.ir_id = None
        self.ir_num = 0
        self.summary = ""
        self.start = 0   # inclusive line index of `### IR-NNN — ...`
        self.end = 0     # exclusive
        self.fields = {} # severity/scope/status/source/seed-id/fix-note
        self.details = ""    # for inline `details: ""` shape
        self.details_block = None  # list[str] body lines (without indent) when |
        self.raw = []

def parse_blocks():
    blocks = []
    i = 0
    in_review = False
    while i < len(lines):
        line = lines[i]
        if H2_RE.match(line):
            # any ## heading ends the previous block; only Implementation Review
            # and Iteration N sections are scope for IR blocks but we accept all.
            in_review = (re.match(r'^## Implementation Review\s*$', line) is not None
                         or re.match(r'^## Iteration \d+\s*$', line) is not None)
            i += 1
            continue
        m = IR_HEAD_RE.match(line)
        if m and in_review:
            b = IRBlock()
            b.ir_id = m.group(1)
            b.ir_num = int(m.group(2))
            b.summary = m.group(3)
            b.start = i
            b.raw.append(line)
            j = i + 1
            while j < len(lines):
                ln = lines[j]
                if H2_RE.match(ln) or IR_HEAD_RE.match(ln):
                    break
                b.raw.append(ln)
                fm = FIELD_RE.match(ln)
                if fm:
                    b.fields[fm.group(1)] = fm.group(2)
                    j += 1
                    continue
                dh = DETAILS_HEAD_RE.match(ln)
                if dh and dh.group(1):  # `- details: |`
                    j += 1
                    body = []
                    while j < len(lines) and (CONT_RE.match(lines[j]) or lines[j].strip() == ''):
                        if CONT_RE.match(lines[j]):
                            body.append(lines[j][4:])
                        else:
                            # blank line inside body — preserve unless this is the trailing blank
                            body.append('')
                        j += 1
                    # Trim trailing blank lines collected as part of the spacer.
                    while body and body[-1] == '':
                        body.pop()
                    b.details_block = body
                    continue
                if dh:
                    # `- details: "..."` or `- details: <text>`
                    b.details = dh.group(2)
                    j += 1
                    continue
                j += 1
            b.end = j
            blocks.append(b)
            i = j
            continue
        i += 1
    return blocks

blocks = parse_blocks()

def find_by_seed(seed):
    for b in blocks:
        if b.fields.get('seed-id') == seed:
            return b
    return None

def find_family(base):
    rows = []  # (sort_key, block)
    for b in blocks:
        s = b.fields.get('seed-id')
        if s is None:
            continue
        if s == base:
            rows.append((0, b))
            continue
        prefix = base + ":r"
        if s.startswith(prefix):
            suf = s[len(prefix):]
            if suf and suf[0] != '0' and suf.isdigit():
                rows.append((int(suf), b))
    rows.sort(key=lambda r: r[0])
    return rows

def next_ir_id():
    last = max((b.ir_num for b in blocks), default=0)
    return f"IR-{last + 1:03d}"

def render_block(ir_id, summary, severity, scope, status, source, seed_id, observation,
                 file_citation, fix_note):
    out = [f"### {ir_id} — {summary}"]
    out.append(f"- severity: {severity}")
    out.append(f"- scope: {scope}")
    out.append(f"- status: {status}")
    if source:
        out.append(f"- source: {source}")
    if seed_id:
        out.append(f"- seed-id: {seed_id}")
    body = []
    body.append(f"Scenario {scenario_id} failed during manual test.")
    body.append(f"Observation: {observation}" if observation.count('\n') == 0 else "Observation:")
    if observation.count('\n') > 0:
        for ln in observation.split('\n'):
            body.append(ln)
    if file_citation:
        body.append(f"File citation: {file_citation}")
    out.append("- details: |")
    for ln in body:
        out.append(f"    {ln}")
    if fix_note:
        out.append(f"- fix-note: {fix_note}")
    else:
        out.append('- fix-note: ""')
    return "\n".join(out)

def write_file(new_lines):
    new_content = '\n'.join(new_lines)
    if not new_content.endswith('\n'):
        new_content += '\n'
    with open(path, 'w') as f:
        f.write(new_content)

def replace_block(b, new_text):
    new_lines = lines[:b.start] + new_text.split('\n') + lines[b.end:]
    write_file(new_lines)

def append_block(new_text):
    # Insert just before the next top-level heading after `## Implementation Review`,
    # or at EOF if there is none.
    review_idx = None
    next_h2_idx = None
    in_review = False
    for idx, ln in enumerate(lines):
        if re.match(r'^## Implementation Review\s*$', ln):
            review_idx = idx
            in_review = True
            continue
        if in_review and H2_RE.match(ln):
            next_h2_idx = idx
            break
    if review_idx is None:
        sys.stderr.write(f'error: heading "{HEADING}" not found in {path}\n')
        sys.exit(1)
    insert_idx = next_h2_idx if next_h2_idx is not None else len(lines)
    # Trim trailing blank lines before insert.
    head = lines[:insert_idx]
    while head and head[-1].strip() == '':
        head.pop()
    new_lines = head + ['', new_text, ''] + lines[insert_idx:]
    write_file(new_lines)

def upsert_open(b):
    """Open-update path: preserve IR-NNN/status/fix-note; preserve severity/scope
    unless --reclassify; replace details; refresh source/seed-id."""
    sev = severity_arg if opt_reclass else b.fields.get('severity', severity_arg)
    scp = scope_arg    if opt_reclass else b.fields.get('scope', scope_arg)
    new_text = render_block(
        b.ir_id, b.summary, sev, scp,
        b.fields.get('status', 'open'),
        'manual-test',
        b.fields.get('seed-id', None),  # refreshed implicitly by always-write
        observation,
        file_citation,
        b.fields.get('fix-note', '').strip('"') if b.fields.get('fix-note') else '',
    )
    # Always rewrite seed-id to the canonical form computed below.
    new_text = re.sub(r'^- seed-id:.*$', f'- seed-id: {b.fields.get("seed-id")}',
                      new_text, count=1, flags=re.MULTILINE)
    replace_block(b, new_text)
    print(b.ir_id)

def insert_new(seed_id):
    ir_id = next_ir_id()
    summary = f"Scenario {scenario_id} failed: {observation.splitlines()[0] if observation else 'manual-test failure'}"
    summary = summary[:160]  # keep summary line bounded
    new_text = render_block(
        ir_id, summary, severity_arg, scope_arg, 'open',
        'manual-test', seed_id, observation, file_citation, ''
    )
    append_block(new_text)
    print(ir_id)

# ---- dispatch ---------------------------------------------------------------

if opt_new:
    # Family-aware path: --new-finding short-circuit.
    family = find_family(base_seed_id)
    if not family and opt_force_new:
        sys.stderr.write(
            f"error: --force-new-regression requires an existing seed-id family; "
            f"no base or regression IR exists for {base_seed_id}\n"
        )
        sys.exit(1)
    if family and opt_force_new:
        max_n = max((k for k, _ in family if k >= 1), default=0)
        next_n = max_n + 1
        insert_new(f"{base_seed_id}:r{next_n}")
        sys.exit(0)
    # Idempotent reuse of latest open regression.
    open_regs = [(k, b) for k, b in family if k >= 1 and b.fields.get('status', 'open') == 'open']
    if open_regs:
        _, b = max(open_regs, key=lambda r: r[0])
        upsert_open(b)
        sys.exit(0)
    # Allocate next regression when family non-empty but no open regression.
    if family:
        max_n = max((k for k, _ in family if k >= 1), default=0)
        next_n = max_n + 1
        insert_new(f"{base_seed_id}:r{next_n}")
        sys.exit(0)
    # Empty family: fall through to base insert.
    insert_new(base_seed_id)
    sys.exit(0)

# Default / --reopen path: exact-seed-id lookup.
match = find_by_seed(base_seed_id)
if match is None:
    insert_new(base_seed_id)
    sys.exit(0)

status = match.fields.get('status', 'open')
if status == 'open':
    # `--reopen` is a silent no-op against an open IR — fall through to upsert.
    upsert_open(match)
    sys.exit(0)

# status in {fixed, wontfix}
if opt_reopen:
    # Flip to open, clear fix-note, replace details. Preserve severity/scope unless --reclassify.
    sev = severity_arg if opt_reclass else match.fields.get('severity', severity_arg)
    scp = scope_arg    if opt_reclass else match.fields.get('scope', scope_arg)
    new_text = render_block(
        match.ir_id, match.summary, sev, scp,
        'open',
        'manual-test',
        match.fields.get('seed-id', base_seed_id),
        observation,
        file_citation,
        '',  # cleared
    )
    replace_block(match, new_text)
    print(match.ir_id)
    sys.exit(0)

# Closed-default: warn on stderr, do not mutate. Stdout is exactly <IR-NNN>.
sys.stderr.write(
    f"warning: {sys.argv[1].rsplit('/',1)[-1]} {base_seed_id} matched {match.ir_id} with "
    f"status={status}; details not updated; pass --reopen to overwrite or "
    f"--new-finding to record as a regression\n"
)
print(match.ir_id)
sys.exit(0)
PYEOF
    ;;

  *)
    echo "usage: review.sh {init|add|set-status|iterate|list-open|list-open-summaries|sync-refs|canonicalize|strip-freeform|find-by-seed-id|find-by-seed-id-family|upsert-manual-test-failure} ..." >&2
    exit 2
    ;;
esac
