#!/usr/bin/env bash
# progress.sh — manage progress.md (central workflow state) inside the
# active quest cycle's subfolder, resolved via quest/active.md →
# millwright-overseer/quest/<slug>/progress.md.
#
# The file tracks the feature queue, completed features, and the currently
# active feature's runtime state. Activation is two-step: finish sets the
# active block to null; activate pops queue[0] into a fresh active block.
#
# Usage:
#   progress.sh init <todo-list-id> <feature1> [<feature2> ...]  # stage 1: scaffold
#   progress.sh activate                     # stage 2: pop queue[0] into active
#   progress.sh finish                       # stage 8: active -> completed, active=null
#   progress.sh requeue                      # abort --drop-feature=requeue: active -> end of queue, active=null
#   progress.sh reset                        # abort recovery: keep feature+branch, reset other active fields
#   progress.sh reorder <feature1> [<feature2> ...]  # stage 1.5: rewrite queue order;
#                                                    # new order MUST be a permutation of the
#                                                    # existing queue (same set of features —
#                                                    # no extras, no missing, no duplicates).
#                                                    # Errors if active is non-null.
#   progress.sh enqueue <feature1> [<feature2> ...]  # mid-cycle re-entry (Finding 6):
#                                                    # append features to the queue while
#                                                    # active is null. Refuses duplicates against
#                                                    # the union of queue + completed + active.feature.
#                                                    # Errors if active is non-null.
#
#   progress.sh get-active                   # prints active.feature or "null"
#   progress.sh queue-remaining              # prints queue entries, one per line
#
#   progress.sh get <field>                  # reads active.<field>; errors if active is null
#   progress.sh set <field>=<value> ...      # writes active.<field>(s) atomically; errors if
#                                            # active is null. All fields are validated first
#                                            # (immutable-field rejection, duplicate-field rejection,
#                                            # yaml.safe_load value parsing); the candidate state is
#                                            # written to a same-directory temp file, validated
#                                            # against the progress schema, and atomically renamed
#                                            # over progress.md. Single-field behavior is identical
#                                            # to the legacy per-field loop.
#   progress.sh advance <expected-stage>     # increments active.current-stage if it matches
#   progress.sh advance-to <expected-current> <target> [--set field=value]...
#                                            # atomic stage skip-transition. expected-current must
#                                            # equal active.current-stage; target must be one of the
#                                            # whitelisted skip pairs (3→5, 5→7, 6→7). Adjacent
#                                            # transitions stay with `advance`. --set field=value pairs
#                                            # are applied in the same atomic write as the stage update;
#                                            # current-stage is rejected from --set (the helper owns it),
#                                            # immutable fields are rejected, duplicate --set fields are
#                                            # rejected, all values parse via yaml.safe_load. Same write
#                                            # pipeline as `set`: validate → temp file → schema validate
#                                            # → atomic rename.
#
#   progress.sh check-worktree               # pre-flight: errors if the current working tree is
#                                            # not the one that activated the cycle. No-op when
#                                            # active is null or the fingerprint isn't recorded
#                                            # (cycles activated before the worktree-fingerprint
#                                            # change shipped). Mutating commands above call the
#                                            # same guard internally; this entry-point exists so
#                                            # command markdowns can fail fast pre-implementation.
#
# Worktree fingerprint:
#   The active block records `worktree-path`, `git-common-dir`, and
#   `git-worktree-dir` at activation time (stage 2). Every state-mutating
#   command compares the current working tree to those values and refuses
#   on mismatch. This protects two `git worktree add` checkouts that
#   share the same data_root from clobbering each other's active state.

set -euo pipefail
source "$(dirname "$0")/internal/common.sh"

# progress.md lives inside the active quest cycle's subfolder; resolve it
# every call so the path tracks the active-quest pointer.
progress_file() { mo_progress_file; }

require_file() {
  local file="$1"
  [[ -f "$file" ]] || mo_die "progress.md not found at $file (run /mo-run first)"
}

require_active() {
  local file="$1"
  local a; a="$(mo_fm_get "$file" active)"
  [[ "$a" != "null" && -n "$a" ]] || mo_die "no active feature (active is null — run 'progress.sh activate' first)"
}

cmd="${1:-}"; shift || true

case "$cmd" in
  init)
    todo_list_id="${1:?todo-list-id required}"; shift
    [[ $# -gt 0 ]] || mo_die "at least one feature required"
    dest="$(progress_file)"
    [[ ! -f "$dest" ]] || mo_die "progress.md already exists: $dest"
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" init progress "$dest" \
      "TODO_LIST_ID=$todo_list_id"
    # Populate queue from args.
    python3 - "$dest" "$@" <<'PYEOF'
import sys, re, yaml
path, *features = sys.argv[1:]
with open(path) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
fm = yaml.safe_load(m.group(1)) or {}
fm['queue'] = list(features)
with open(path, 'w') as f:
    f.write('---\n')
    f.write(yaml.safe_dump(fm, default_flow_style=False, sort_keys=False))
    f.write('---\n')
    f.write(m.group(2))
PYEOF
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$dest" progress >/dev/null
    mo_info "progress initialized with $# features in queue"
    ;;

  activate)
    dest="$(progress_file)"
    require_file "$dest"
    # Capture the worktree fingerprint up front so the active block records
    # which working tree owns the cycle. Subsequent state mutations are gated
    # on a match via mo_assert_worktree_match (common.sh).
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      || mo_die "progress.sh activate must run inside a git working tree (current dir: $PWD)"
    wt_path="$PWD"
    git_common_dir="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
    git_worktree_dir="$(cd "$(git rev-parse --git-dir)" && pwd)"
    python3 - "$dest" "$wt_path" "$git_common_dir" "$git_worktree_dir" <<'PYEOF'
import sys, re, yaml
path, wt_path, git_common_dir, git_worktree_dir = sys.argv[1:]
with open(path) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
fm = yaml.safe_load(m.group(1)) or {}
if fm.get('active') is not None:
    sys.stderr.write(f"error: active already set to feature={fm['active'].get('feature')}\n")
    sys.exit(1)
if not fm.get('queue'):
    sys.stderr.write("error: queue is empty — nothing to activate\n")
    sys.exit(1)
feat = fm['queue'].pop(0)
fm['active'] = {
    'feature': feat,
    'branch': None,
    'current-stage': 2,
    'sub-flow': 'none',
    'base-commit': None,
    'execution-mode': 'none',
    'planning-mode': 'none',
    'review-mode': 'none',
    'review-mode-suggestion': 'none',
    'diagram-prompt': 'prompt',
    'diagram-rendering': 'never',
    'implementation-diagrams-skipped': False,
    'implementation-completed': False,
    'overseer-review-completed': False,
    'manual-test-state': 'none',
    'manual-test-failure-policy': 'none',
    'worktree-path': wt_path,
    'git-common-dir': git_common_dir,
    'git-worktree-dir': git_worktree_dir,
}
with open(path, 'w') as f:
    f.write('---\n')
    f.write(yaml.safe_dump(fm, default_flow_style=False, sort_keys=False))
    f.write('---\n')
    f.write(m.group(2))
print(feat)
PYEOF
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$dest" progress >/dev/null
    ;;

  finish)
    # Finalize the active feature: move active.feature to completed[] and set
    # active=null. Phase 5.5 of the context-optimization plan adds an optional
    # `--set field=value` pair pattern (mirroring `advance-to`) so callers can
    # bundle a top-level field write with the finalize transition in one
    # atomic file update. Useful when stage-8 wants to set a top-level flag
    # alongside finalization without a separate `progress.sh set` call.
    #
    # Note: --set targets TOP-LEVEL fields only. The active block is being
    # torn down here, so writes inside `active.*` are meaningless.
    set_args=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --set)
          [[ $# -ge 2 ]] || mo_die "finish: --set requires field=value"
          set_args[${#set_args[@]}]="$2"
          shift 2
          ;;
        --set=*)
          set_args[${#set_args[@]}]="${1#--set=}"
          shift
          ;;
        *)
          mo_die "finish: unknown argument: $1 (expected --set field=value)"
          ;;
      esac
    done

    dest="$(progress_file)"
    require_file "$dest"
    require_active "$dest"
    mo_assert_worktree_match
    python3 - "$dest" "${set_args[@]:-}" <<'PYEOF'
import sys, re, yaml
path = sys.argv[1]
extra_sets = sys.argv[2:]
with open(path) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
fm = yaml.safe_load(m.group(1)) or {}
active = fm['active']
fm.setdefault('completed', []).append(active['feature'])
fm['active'] = None
# Apply any --set field=value pairs to top-level fields. active.* writes are
# meaningless here (active is being set to None).
for kv in extra_sets:
    if not kv:
        continue
    if '=' not in kv:
        sys.stderr.write(f"finish: --set value missing '=': {kv}\n")
        sys.exit(2)
    field, value = kv.split('=', 1)
    if field.startswith('active.') or field == 'active':
        sys.stderr.write(f"finish: cannot set active.* fields during finalize (active is being cleared): {field}\n")
        sys.exit(2)
    # Try YAML-parsing the value so booleans/numbers/lists land as the right type.
    try:
        parsed = yaml.safe_load(value)
    except yaml.YAMLError:
        parsed = value
    fm[field] = parsed
with open(path, 'w') as f:
    f.write('---\n')
    f.write(yaml.safe_dump(fm, default_flow_style=False, sort_keys=False))
    f.write('---\n')
    f.write(m.group(2))
print(active['feature'])
PYEOF
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$dest" progress >/dev/null
    ;;

  requeue)
    dest="$(progress_file)"
    require_file "$dest"
    require_active "$dest"
    mo_assert_worktree_match
    python3 - "$dest" <<'PYEOF'
import sys, re, yaml
path = sys.argv[1]
with open(path) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
fm = yaml.safe_load(m.group(1)) or {}
active = fm['active']
fm.setdefault('queue', []).append(active['feature'])
fm['active'] = None
with open(path, 'w') as f:
    f.write('---\n')
    f.write(yaml.safe_dump(fm, default_flow_style=False, sort_keys=False))
    f.write('---\n')
    f.write(m.group(2))
print(active['feature'])
PYEOF
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$dest" progress >/dev/null
    ;;

  reset)
    dest="$(progress_file)"
    require_file "$dest"
    require_active "$dest"
    mo_assert_worktree_match
    python3 - "$dest" <<'PYEOF'
import sys, re, yaml
path = sys.argv[1]
with open(path) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
fm = yaml.safe_load(m.group(1)) or {}
old = fm['active']
fm['active'] = {
    'feature': old['feature'],
    'branch': old.get('branch'),
    'current-stage': 2,
    'sub-flow': 'none',
    'base-commit': None,
    'execution-mode': 'none',
    'planning-mode': 'none',
    'review-mode': 'none',
    'review-mode-suggestion': 'none',
    'diagram-prompt': 'prompt',
    'diagram-rendering': 'never',
    'implementation-diagrams-skipped': False,
    'implementation-completed': False,
    'overseer-review-completed': False,
    'manual-test-state': 'none',
    'manual-test-failure-policy': 'none',
    'worktree-path': old.get('worktree-path'),
    'git-common-dir': old.get('git-common-dir'),
    'git-worktree-dir': old.get('git-worktree-dir'),
}
with open(path, 'w') as f:
    f.write('---\n')
    f.write(yaml.safe_dump(fm, default_flow_style=False, sort_keys=False))
    f.write('---\n')
    f.write(m.group(2))
PYEOF
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$dest" progress >/dev/null
    mo_info "reset active feature (feature + branch preserved)"
    ;;

  enqueue)
    [[ $# -gt 0 ]] || mo_die "at least one feature required"
    dest="$(progress_file)"
    require_file "$dest"
    python3 - "$dest" "$@" <<'PYEOF'
import sys, re, yaml
path, *new_features = sys.argv[1:]
with open(path) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
fm = yaml.safe_load(m.group(1)) or {}
# enqueue is a mid-cycle re-entry / pre-flight operation; reject if a feature is active.
if fm.get('active') is not None:
    sys.stderr.write(
        f"error: cannot enqueue while a feature is active "
        f"(feature={fm['active'].get('feature')}). "
        f"Wait for the active feature to finish (or run /mo-abort-workflow) first.\n"
    )
    sys.exit(1)
existing_queue = list(fm.get('queue', []))
completed = list(fm.get('completed', []))
known = set(existing_queue) | set(completed)
new_list = list(new_features)
# Refuse duplicates within the new args.
if len(new_list) != len(set(new_list)):
    seen = set()
    dups = []
    for feat in new_list:
        if feat in seen and feat not in dups:
            dups.append(feat)
        seen.add(feat)
    sys.stderr.write(f"error: duplicate features in enqueue args: {', '.join(dups)}\n")
    sys.exit(1)
# Refuse features already in queue or completed.
collisions = sorted(set(new_list) & known)
if collisions:
    in_queue = [f for f in collisions if f in existing_queue]
    in_done  = [f for f in collisions if f in completed]
    parts = []
    if in_queue:
        parts.append(f"already in queue: {', '.join(in_queue)}")
    if in_done:
        parts.append(f"already completed: {', '.join(in_done)}")
    sys.stderr.write(
        "error: enqueue refuses duplicates.\n"
        f"  problems: {'; '.join(parts)}\n"
    )
    sys.exit(1)
fm['queue'] = existing_queue + new_list
with open(path, 'w') as f:
    f.write('---\n')
    f.write(yaml.safe_dump(fm, default_flow_style=False, sort_keys=False))
    f.write('---\n')
    f.write(m.group(2))
print(f"mo: enqueued {len(new_list)} feature(s); queue is now: {', '.join(fm['queue'])}", file=sys.stderr)
PYEOF
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$dest" progress >/dev/null
    ;;

  reorder)
    [[ $# -gt 0 ]] || mo_die "at least one feature required"
    dest="$(progress_file)"
    require_file "$dest"
    python3 - "$dest" "$@" <<'PYEOF'
import sys, re, yaml
path, *new_order = sys.argv[1:]
with open(path) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
fm = yaml.safe_load(m.group(1)) or {}
# reorder is a stage-1.5 operation; reject if a feature is already active.
if fm.get('active') is not None:
    sys.stderr.write(
        f"error: cannot reorder while a feature is active "
        f"(feature={fm['active'].get('feature')}). "
        f"Reorder is a stage-1.5 operation; use /mo-abort-workflow first if needed.\n"
    )
    sys.exit(1)
existing = list(fm.get('queue', []))
existing_set = set(existing)
new_list = list(new_order)
new_set = set(new_list)
# Check for duplicates in the new order.
if len(new_list) != len(new_set):
    seen = set()
    dups = []
    for f in new_list:
        if f in seen and f not in dups:
            dups.append(f)
        seen.add(f)
    sys.stderr.write(f"error: duplicate features in new order: {', '.join(dups)}\n")
    sys.exit(1)
# Check the new order is a permutation of the existing queue.
if existing_set != new_set:
    missing = sorted(existing_set - new_set)
    extra = sorted(new_set - existing_set)
    msg_parts = []
    if missing:
        msg_parts.append(f"missing from new order: {', '.join(missing)}")
    if extra:
        msg_parts.append(f"not in existing queue: {', '.join(extra)}")
    sys.stderr.write(
        "error: new order must be a permutation of the existing queue.\n"
        f"  existing: {', '.join(existing) if existing else '(empty)'}\n"
        f"  problems: {'; '.join(msg_parts)}\n"
    )
    sys.exit(1)
# No-op short-circuit: leave file untouched if order is unchanged.
if existing == new_list:
    sys.stderr.write("mo: reorder is a no-op (queue order unchanged)\n")
    sys.exit(0)
fm['queue'] = new_list
with open(path, 'w') as f:
    f.write('---\n')
    f.write(yaml.safe_dump(fm, default_flow_style=False, sort_keys=False))
    f.write('---\n')
    f.write(m.group(2))
print(f"mo: queue reordered to: {', '.join(new_list)}", file=sys.stderr)
PYEOF
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$dest" progress >/dev/null
    ;;

  get-active)
    dest="$(progress_file)"
    require_file "$dest"
    mo_fm_get "$dest" '.active.feature'
    ;;

  queue-remaining)
    dest="$(progress_file)"
    require_file "$dest"
    mo_fm_get "$dest" '.queue[]'
    ;;

  get)
    field="${1:?field required}"
    dest="$(progress_file)"
    require_file "$dest"
    require_active "$dest"
    mo_fm_get "$dest" ".active.${field}"
    ;;

  set)
    [[ $# -gt 0 ]] || mo_die "at least one field=value required"
    dest="$(progress_file)"
    require_file "$dest"
    require_active "$dest"
    mo_assert_worktree_match
    # Batched implementation: validate every field first (immutable rejection,
    # duplicate rejection, value parsing), build the candidate state in one
    # Python pass, write to a same-directory temp file, schema-validate the
    # temp, then atomically rename it over progress.md. Avoids half-written
    # states (e.g., base-commit captured but history-baseline-version missing)
    # and invalid-destination states from typo'd field names.
    tmp="$(mktemp "$(dirname "$dest")/progress.md.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    if ! python3 - "$dest" "$tmp" "$@" <<'PYEOF'; then
import sys, re, yaml
path, tmp = sys.argv[1], sys.argv[2]
kvs = sys.argv[3:]

IMMUTABLE = {'worktree-path', 'git-common-dir', 'git-worktree-dir'}
seen = set()
parsed_kvs = []
for kv in kvs:
    if '=' not in kv:
        sys.stderr.write(f"error: progress.sh set: invalid field=value: {kv!r}\n")
        sys.exit(1)
    field, value = kv.split('=', 1)
    if field in IMMUTABLE:
        sys.stderr.write(f"error: progress.sh set: {field} is immutable after activate (captured at stage 2)\n")
        sys.exit(1)
    if field in seen:
        sys.stderr.write(f"error: progress.sh set: duplicate field {field!r} in args\n")
        sys.exit(1)
    seen.add(field)
    try:
        parsed_value = yaml.safe_load(value)
    except yaml.YAMLError:
        parsed_value = value
    parsed_kvs.append((field, parsed_value))

with open(path) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
if not m:
    sys.stderr.write(f"error: progress.sh set: {path} has no frontmatter block\n")
    sys.exit(1)
fm = yaml.safe_load(m.group(1)) or {}
if fm.get('active') is None:
    sys.stderr.write("error: progress.sh set: active is null (require_active should have caught this)\n")
    sys.exit(1)
for field, parsed_value in parsed_kvs:
    fm['active'][field] = parsed_value
with open(tmp, 'w') as f:
    f.write('---\n')
    f.write(yaml.safe_dump(fm, default_flow_style=False, sort_keys=False))
    f.write('---\n')
    f.write(m.group(2))
PYEOF
      exit 1
    fi
    if ! "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$tmp" progress >/dev/null; then
      mo_die "progress.sh set: candidate state failed schema validation; original file unchanged"
    fi
    mv "$tmp" "$dest"
    trap - EXIT
    ;;

  advance)
    expected="${1:?expected current-stage required}"
    dest="$(progress_file)"
    require_file "$dest"
    require_active "$dest"
    mo_assert_worktree_match
    current="$(mo_fm_get "$dest" '.active.current-stage')"
    if [[ "$current" != "$expected" ]]; then
      mo_die "stage mismatch: active.current-stage=$current, advance expected $expected"
    fi
    next=$((expected + 1))
    python3 - "$dest" "$next" <<'PYEOF'
import sys, re, yaml
path, next_stage = sys.argv[1], int(sys.argv[2])
with open(path) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
fm = yaml.safe_load(m.group(1)) or {}
fm['active']['current-stage'] = next_stage
with open(path, 'w') as f:
    f.write('---\n')
    f.write(yaml.safe_dump(fm, default_flow_style=False, sort_keys=False))
    f.write('---\n')
    f.write(m.group(2))
PYEOF
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$dest" progress >/dev/null
    mo_info "advanced to stage $next"
    ;;

  advance-to)
    expected="${1:?expected current-stage required}"; shift
    target="${1:?target stage required}"; shift
    # Stage-pair whitelist: only these skip-transitions are legal. Adjacent
    # transitions must use `advance` (which catches typo'd targets via the
    # off-by-one check). The whitelist exists so the dispatcher's intentional
    # skips (3→5 after stage-4 collapses into the Resume Handler; 5→7 on the
    # no-findings approve path; 6→7 on the review-resume finalize path) can't
    # be confused with arbitrary stage jumps.
    case "${expected}-${target}" in
      3-5|5-7|6-7) ;;
      *)
        mo_die "advance-to: stage transition ${expected} → ${target} not in whitelist (allowed: 3→5, 5→7, 6→7). Adjacent transitions use 'advance'."
        ;;
    esac
    # Parse --set field=value args (zero or more).
    set_args=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --set)
          [[ $# -ge 2 ]] || mo_die "advance-to: --set requires field=value"
          set_args[${#set_args[@]}]="$2"
          shift 2
          ;;
        --set=*)
          set_args[${#set_args[@]}]="${1#--set=}"
          shift
          ;;
        *)
          mo_die "advance-to: unknown argument: $1 (expected --set field=value)"
          ;;
      esac
    done
    dest="$(progress_file)"
    require_file "$dest"
    require_active "$dest"
    mo_assert_worktree_match
    tmp="$(mktemp "$(dirname "$dest")/progress.md.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    # Build the python args list explicitly so empty set_args expansion works
    # under bash 3.2 (which trips on "${set_args[@]+...}" idioms).
    py_args=("$dest" "$tmp" "$expected" "$target")
    if [[ ${#set_args[@]} -gt 0 ]]; then
      for kv in "${set_args[@]}"; do py_args[${#py_args[@]}]="$kv"; done
    fi
    if ! python3 - "${py_args[@]}" <<'PYEOF'; then
import sys, re, yaml
path, tmp, expected_str, target_str = sys.argv[1:5]
kvs = sys.argv[5:]
expected = int(expected_str)
target = int(target_str)

IMMUTABLE = {'worktree-path', 'git-common-dir', 'git-worktree-dir'}
seen = set()
parsed_kvs = []
for kv in kvs:
    if '=' not in kv:
        sys.stderr.write(f"error: advance-to: invalid --set field=value: {kv!r}\n")
        sys.exit(1)
    field, value = kv.split('=', 1)
    if field == 'current-stage':
        sys.stderr.write("error: advance-to: --set may not target current-stage (the helper owns that field)\n")
        sys.exit(1)
    if field in IMMUTABLE:
        sys.stderr.write(f"error: advance-to: {field} is immutable after activate (captured at stage 2)\n")
        sys.exit(1)
    if field in seen:
        sys.stderr.write(f"error: advance-to: duplicate --set field {field!r}\n")
        sys.exit(1)
    seen.add(field)
    try:
        parsed_value = yaml.safe_load(value)
    except yaml.YAMLError:
        parsed_value = value
    parsed_kvs.append((field, parsed_value))

with open(path) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
if not m:
    sys.stderr.write(f"error: advance-to: {path} has no frontmatter block\n")
    sys.exit(1)
fm = yaml.safe_load(m.group(1)) or {}
if fm.get('active') is None:
    sys.stderr.write("error: advance-to: active is null (require_active should have caught this)\n")
    sys.exit(1)
current = fm['active'].get('current-stage')
if current != expected:
    sys.stderr.write(f"error: advance-to: stage mismatch — active.current-stage={current}, expected {expected}\n")
    sys.exit(1)

fm['active']['current-stage'] = target
for field, parsed_value in parsed_kvs:
    fm['active'][field] = parsed_value
with open(tmp, 'w') as f:
    f.write('---\n')
    f.write(yaml.safe_dump(fm, default_flow_style=False, sort_keys=False))
    f.write('---\n')
    f.write(m.group(2))
PYEOF
      exit 1
    fi
    if ! "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$tmp" progress >/dev/null; then
      mo_die "advance-to: candidate state failed schema validation; original file unchanged"
    fi
    mv "$tmp" "$dest"
    trap - EXIT
    mo_info "advanced from stage $expected to stage $target"
    ;;

  check-worktree)
    # Public pre-flight gate. Fails with a guidance message when the
    # current working tree is not the one that activated the active
    # feature. No-op when active is null or fingerprint absent.
    mo_assert_worktree_match
    ;;

  *)
    echo "usage: progress.sh {init|activate|finish|requeue|reset|reorder|enqueue|get-active|queue-remaining|get|set|advance|advance-to|check-worktree} ..." >&2
    exit 2
    ;;
esac
