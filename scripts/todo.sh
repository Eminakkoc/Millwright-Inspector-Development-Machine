#!/usr/bin/env bash
# todo.sh — update todo item states in the active quest cycle's todo-list.md
# (resolved via the active-quest pointer at quest/active.md → quest/<slug>/todo-list.md).
#
# Todo items are written as markdown checkboxes with an optional assignee tag
# and the state as a prefix word:
#   - [ ] TODO — ITEM-001: description                      (default, unselected, unassigned)
#   - [ ] (emin) TODO — ITEM-001: description               (assigned but not yet selected)
#   - [x] (emin) PENDING — ITEM-001: description            (selected for this cycle)
#   - [x] (emin) IMPLEMENTING — ITEM-001: description       (currently being worked on)
#   - [x] (emin) IMPLEMENTED — ITEM-001: description        (complete)
#   - [x] (emin) CANCELED — ITEM-001: description           (removed mid-cycle; preserved for audit)
#
# Convention: [ ] = TODO only; [x] = any selected state (PENDING/IMPLEMENTING/IMPLEMENTED/CANCELED).
# Assignee rules:
#   - Optional on `[ ] TODO` lines (inspector may pre-assign or leave unassigned).
#   - REQUIRED on any `[x]` line. pend-selected rejects `[x] TODO` lines that
#     have no `(assignee)` tag and lists the offending item ids.
#   - Preserved automatically by set-state / bulk-transition across all state changes.
#
# Usage:
#   todo.sh set-state <item-id> <TODO|PENDING|IMPLEMENTING|IMPLEMENTED|CANCELED>
#                                 [--assignee <name>]
#                                 # --assignee sets the (assignee) tag; omitted, the
#                                 # existing tag is preserved verbatim (unchanged behaviour).
#   todo.sh bulk-transition <from-state> <to-state> [--feature <kebab-name>]
#                                 # with --feature: only items under `## <matching-header>` transition.
#                                 # without it: operates on every item in the file (backward-compatible).
#                                 # header matching is case-insensitive and kebab-normalized,
#                                 # so `## Marketing site` matches `--feature marketing-site`.
#   todo.sh pend-selected         # transform inspector-marked [xX] TODO items to [x] PENDING
#                                 # (fails if any selected item lacks an assignee).
#                                 # stdout: one `<item-id>\t<assignee>` row per promoted
#                                 # item, in document order.
#   todo.sh list <state> [--feature <kebab-name>]
#                                 # list item ids currently in <state>; with --feature,
#                                 # only items under the matching ## <header> section.
#   todo.sh add <feature> <state> <assignee> <item-id> <description>
#                                 # append a new item under the feature's section (creating
#                                 # the section if absent). state ∈ {TODO, IMPLEMENTING, CANCELED}.
#                                 # PENDING is refused (only stage-1.5 pend-selected writes PENDING);
#                                 # IMPLEMENTED is refused (only mi-complete-workflow writes IMPLEMENTED).
#                                 # Fails if item-id already exists in the file.
#   todo.sh feature-test-status   # read-only predicate. Prints one TSV row:
#                                 #   <status>\t<ft-name>\t<ft-item-id>\t<blocking-count>\t<fallback-assignee>
#                                 # status ∈ none|blocked|ready|premature|selected.
#                                 # "unselected" means checkbox `[ ]`; every [x] state
#                                 # (including CANCELED) resolves an item.
#   todo.sh is-feature-test <name>  # read-only predicate. Exit 0 when <name> is
#                                   # this cycle's declared feature-test entry,
#                                   # exit 1 otherwise. Silent on both streams.

set -euo pipefail
source "$(dirname "$0")/internal/common.sh"

# todo-list.md lives inside the active quest cycle's subfolder; resolve it
# every call so the path tracks the active-quest pointer.
todo_file() { mi_quest_active_file todo-list; }

cmd="${1:-}"; shift || true

case "$cmd" in
  set-state)
    item_id="${1:?item-id required}"
    new_state="${2:?new-state required}"
    shift 2
    assignee_override=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --assignee)   assignee_override="${2:?--assignee requires a value}"; shift 2 ;;
        --assignee=*) assignee_override="${1#*=}"; shift ;;
        *)            mi_die "set-state: unknown argument: $1" ;;
      esac
    done
    file="$(todo_file)"
    [[ -f "$file" ]] || mi_die "todo-list.md not found"
    python3 - "$file" "$item_id" "$new_state" "$assignee_override" <<'PYEOF'
import sys, re
path, item_id, new_state, assignee_override = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
)
checkbox = '[ ]' if new_state == 'TODO' else '[x]'
with open(path) as f:
    lines = f.readlines()
# Capture optional (assignee) between checkbox and state word.
pattern = re.compile(
    rf'^(\s*-\s+)\[[ xX]\]\s+(?:\(([^)]+)\)\s+)?(TODO|PENDING|IMPLEMENTING|IMPLEMENTED|CANCELED)\s+—\s+{re.escape(item_id)}(:.*)$'
)
updated = 0
for i, line in enumerate(lines):
    m = pattern.match(line.rstrip('\n'))
    if m:
        assignee = assignee_override or m.group(2)
        assignee_tag = f'({assignee}) ' if assignee else ''
        lines[i] = f'{m.group(1)}{checkbox} {assignee_tag}{new_state} — {item_id}{m.group(4)}\n'
        updated += 1
if updated == 0:
    print(f'error: item {item_id} not found in {path}', file=sys.stderr)
    sys.exit(1)
with open(path, 'w') as f:
    f.writelines(lines)
print(f'mi: set {item_id} to {new_state}', file=sys.stderr)
PYEOF
    ;;

  bulk-transition)
    from_state="${1:?from-state required}"
    to_state="${2:?to-state required}"
    shift 2
    feature_filter=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --feature)   feature_filter="${2:?--feature requires a value}"; shift 2 ;;
        --feature=*) feature_filter="${1#*=}"; shift ;;
        *)           mi_die "bulk-transition: unknown argument: $1" ;;
      esac
    done
    file="$(todo_file)"
    [[ -f "$file" ]] || mi_die "todo-list.md not found"
    python3 - "$file" "$from_state" "$to_state" "$feature_filter" <<'PYEOF'
import sys, re
path, from_state, to_state, feature_filter = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
to_checkbox = '[ ]' if to_state == 'TODO' else '[x]'

def kebab(s):
    # "Marketing site" → "marketing-site"; "Payments" → "payments"; tolerant of
    # underscores, multi-spaces, stray punctuation.
    s = s.strip().lower()
    s = re.sub(r'[\s_]+', '-', s)
    s = re.sub(r'[^a-z0-9-]', '', s)
    s = re.sub(r'-+', '-', s).strip('-')
    return s

target = kebab(feature_filter) if feature_filter else None

item_pat = re.compile(
    rf'^(\s*-\s+)\[[ xX]\]\s+(?:\(([^)]+)\)\s+)?{re.escape(from_state)}\s+—'
)

with open(path) as f:
    lines = f.readlines()

current_section = None
count = 0
for i, line in enumerate(lines):
    stripped = line.rstrip('\n')
    if stripped.startswith('## '):
        current_section = kebab(stripped[3:])
        continue
    # If a filter was given, skip lines outside the matching section.
    if target is not None and current_section != target:
        continue
    m = item_pat.match(stripped)
    if m:
        prefix, assignee = m.group(1), m.group(2)
        tag = f'({assignee}) ' if assignee else ''
        lines[i] = item_pat.sub(f'{prefix}{to_checkbox} {tag}{to_state} —', stripped, count=1) + '\n'
        count += 1

with open(path, 'w') as f:
    f.writelines(lines)

scope = f' under ## {feature_filter}' if feature_filter else ''
print(f'mi: transitioned {count} items from {from_state} to {to_state}{scope}', file=sys.stderr)
PYEOF
    ;;

  pend-selected)
    # Inspector marks items with [x]/[X] on TODO lines to select them for this cycle.
    # Convert those marks to canonical [x] (<assignee>) PENDING. Idempotent: an item
    # already in [x] PENDING is left untouched because this only matches state word == TODO.
    #
    # Validation: every [x] TODO line MUST carry an (assignee) tag. If any are missing,
    # the script exits 2 and lists the offending items without touching the file.
    file="$(todo_file)"
    [[ -f "$file" ]] || mi_die "todo-list.md not found"
    python3 - "$file" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    content = f.read()
# Match any [xX] TODO line; capture optional assignee for validation.
pattern = re.compile(
    r'^(\s*-\s+)\[[xX]\]\s+(?:\(([^)]+)\)\s+)?TODO\s+—\s+(.+)$',
    re.MULTILINE,
)
# First pass: collect items missing an assignee.
missing = [m.group(3) for m in pattern.finditer(content) if not m.group(2)]
if missing:
    print(
        'error: the following items are marked [x] but have no (assignee) tag.',
        file=sys.stderr,
    )
    print(
        '       add a name tag between the checkbox and the state word, e.g. `[x] (emin) TODO — ...`.',
        file=sys.stderr,
    )
    for item in missing:
        print(f'  - {item}', file=sys.stderr)
    sys.exit(2)
# Second pass: rewrite with (assignee) preserved, recording promoted items.
promoted = []
def _sub(m):
    prefix, assignee, rest = m.group(1), m.group(2), m.group(3)
    promoted.append((rest.split(':', 1)[0].strip(), assignee))
    return f'{prefix}[x] ({assignee}) PENDING — {rest}'
new_content, count = pattern.subn(_sub, content)
with open(path, 'w') as f:
    f.write(new_content)
for item_id, assignee in promoted:
    print(f'{item_id}\t{assignee}')
print(f'mi: transitioned {count} inspector-selected items from TODO to PENDING', file=sys.stderr)
PYEOF
    ;;

  list)
    state="${1:?state required}"
    shift 1
    feature_filter=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --feature)   feature_filter="${2:?--feature requires a value}"; shift 2 ;;
        --feature=*) feature_filter="${1#*=}"; shift ;;
        *)           mi_die "list: unknown argument: $1" ;;
      esac
    done
    file="$(todo_file)"
    [[ -f "$file" ]] || mi_die "todo-list.md not found"
    # Python implementation — portable across BSD/GNU sed, accepts the optional
    # (assignee) tag, and honors --feature with the same kebab-normalization as
    # bulk-transition so `--feature marketing-site` matches `## Marketing site`.
    python3 - "$file" "$state" "$feature_filter" <<'PYEOF'
import sys, re
path, state, feature_filter = sys.argv[1], sys.argv[2], sys.argv[3]

def kebab(s):
    s = s.strip().lower()
    s = re.sub(r'[\s_]+', '-', s)
    s = re.sub(r'[^a-z0-9-]', '', s)
    s = re.sub(r'-+', '-', s).strip('-')
    return s

target = kebab(feature_filter) if feature_filter else None

item_pat = re.compile(
    rf'^\s*-\s+\[[ xX]\]\s+(?:\([^)]+\)\s+)?{re.escape(state)}\s+—\s+([A-Z0-9-]+)'
)

current_section = None
with open(path) as f:
    for line in f:
        stripped = line.rstrip('\n')
        if stripped.startswith('## '):
            current_section = kebab(stripped[3:])
            continue
        if target is not None and current_section != target:
            continue
        m = item_pat.match(stripped)
        if m:
            print(m.group(1))
PYEOF
    ;;

  add)
    feature="${1:?feature required}"
    state="${2:?state required}"
    assignee="${3:?assignee required}"
    item_id="${4:?item-id required}"
    description="${5:?description required}"
    case "$state" in
      TODO|IMPLEMENTING|CANCELED) ;;
      PENDING)     mi_die "state=PENDING is not allowed for manual add (only stage-1.5 pend-selected writes PENDING)" ;;
      IMPLEMENTED) mi_die "state=IMPLEMENTED is not allowed for manual add (only mi-complete-workflow writes IMPLEMENTED)" ;;
      *)           mi_die "invalid state: $state (valid: TODO|IMPLEMENTING|CANCELED)" ;;
    esac
    file="$(todo_file)"
    [[ -f "$file" ]] || mi_die "todo-list.md not found"
    python3 - "$file" "$feature" "$state" "$assignee" "$item_id" "$description" <<'PYEOF'
import sys, re
path, feature, state, assignee, item_id, description = sys.argv[1:]

def kebab(s):
    s = s.strip().lower()
    s = re.sub(r'[\s_]+', '-', s)
    s = re.sub(r'[^a-z0-9-]', '', s)
    s = re.sub(r'-+', '-', s).strip('-')
    return s

target_section = kebab(feature)
checkbox = '[ ]' if state == 'TODO' else '[x]'
new_line = f'- {checkbox} ({assignee}) {state} — {item_id}: {description}\n'

with open(path) as f:
    lines = f.readlines()

# Uniqueness check: item-id must not already exist in any item line.
id_check_pat = re.compile(
    rf'^\s*-\s+\[[ xX]\]\s+(?:\([^)]+\)\s+)?'
    rf'(?:TODO|PENDING|IMPLEMENTING|IMPLEMENTED|CANCELED)\s+—\s+{re.escape(item_id)}\b'
)
for i, line in enumerate(lines):
    if id_check_pat.match(line.rstrip('\n')):
        print(f'error: item-id {item_id} already exists at line {i+1}', file=sys.stderr)
        sys.exit(1)

# Find target section; collect its start index if present.
section_start = None
for i, line in enumerate(lines):
    stripped = line.rstrip('\n')
    if stripped.startswith('## ') and kebab(stripped[3:]) == target_section:
        section_start = i
        break

if section_start is None:
    # Create new section at end of file.
    if lines and not lines[-1].endswith('\n'):
        lines[-1] += '\n'
    if lines and lines[-1].strip() != '':
        lines.append('\n')
    lines.append(f'## {target_section}\n')
    lines.append('\n')
    lines.append(new_line)
else:
    # Insert at end of the target section (just before the next ## or EOF).
    insert_at = len(lines)
    for j in range(section_start + 1, len(lines)):
        if lines[j].startswith('## '):
            insert_at = j
            break
    # Trim trailing blank lines before the next section / EOF.
    while insert_at > section_start + 1 and lines[insert_at - 1].strip() == '':
        insert_at -= 1
    lines.insert(insert_at, new_line)

with open(path, 'w') as f:
    f.writelines(lines)

print(f'mi: added {item_id} as [{state}] under ## {target_section}', file=sys.stderr)
PYEOF
    ;;

  feature-test-status)
    file="$(todo_file)"
    [[ -f "$file" ]] || mi_die "todo-list.md not found"
    python3 - "$file" <<'PYEOF'
import sys, re, yaml

path = sys.argv[1]
with open(path) as f:
    content = f.read()

m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
fm = (yaml.safe_load(m.group(1)) or {}) if m else {}
body = m.group(2) if m else content
ft_name = fm.get('feature-test')

def kebab(s):
    s = s.strip().lower()
    s = re.sub(r'[\s_]+', '-', s)
    s = re.sub(r'[^a-z0-9-]', '', s)
    s = re.sub(r'-+', '-', s).strip('-')
    return s

def emit_none():
    print('none\t\t\t0\t')
    sys.exit(0)

if not ft_name:
    emit_none()

target = kebab(ft_name)
item_pat = re.compile(
    r'^\s*-\s+\[([ xX])\]\s+(?:\(([^)]+)\)\s+)?'
    r'(?:TODO|PENDING|IMPLEMENTING|IMPLEMENTED|CANCELED)\s+—\s+([A-Z0-9-]+)'
)

section = None
ft_item_id = ''
ft_checked = False
blocking = 0
fallback_assignee = ''

for line in body.split('\n'):
    if line.startswith('## '):
        section = kebab(line[3:])
        continue
    mm = item_pat.match(line)
    if not mm:
        continue
    checked = mm.group(1) in ('x', 'X')
    assignee = mm.group(2) or ''
    item_id = mm.group(3)
    if section == target:
        ft_item_id = item_id
        ft_checked = checked
    elif not checked:
        blocking += 1
    elif assignee:
        # Only overwrite the fallback with a non-empty value — a checked
        # ordinary item can have an empty tag (e.g. `set-state <id> CANCELED`
        # with no --assignee preserves an unassigned line), and letting that
        # clobber a good fallback from an earlier line forces the inspector
        # to re-supply a name that was already available.
        fallback_assignee = assignee

if not ft_item_id:
    # Field present but no matching section/item — a hand-edited file. Warn and
    # report `none` so callers no-op rather than stalling the cycle.
    sys.stderr.write(
        f"warning: feature-test '{ft_name}' is declared in frontmatter but no "
        f"matching section with an item was found; reporting status=none\n"
    )
    emit_none()

if ft_checked:
    status = 'premature' if blocking else 'selected'
else:
    status = 'blocked' if blocking else 'ready'

print(f'{status}\t{ft_name}\t{ft_item_id}\t{blocking}\t{fallback_assignee}')
PYEOF
    ;;

  is-feature-test)
    # Read-only identity predicate: does <name> match this cycle's declared
    # feature-test entry? Exit 0 = yes, 1 = no. Never dies — callers use it
    # directly in `if`, so a missing cycle or file is "no", not an error.
    name="${1:?feature name required}"
    file="$(todo_file 2>/dev/null || true)"
    [[ -n "$file" && -f "$file" ]] || exit 1
    python3 - "$file" "$name" <<'PYEOF'
import sys, re, yaml
path, name = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        content = f.read()
except OSError:
    sys.exit(1)
m = re.match(r'^---\n(.*?)\n---\n', content, re.DOTALL)
fm = (yaml.safe_load(m.group(1)) or {}) if m else {}
ft = fm.get('feature-test')
sys.exit(0 if ft and ft == name else 1)
PYEOF
    ;;

  *)
    echo "usage: todo.sh {set-state|bulk-transition|pend-selected|list|add|feature-test-status|is-feature-test} ..." >&2
    exit 2
    ;;
esac
