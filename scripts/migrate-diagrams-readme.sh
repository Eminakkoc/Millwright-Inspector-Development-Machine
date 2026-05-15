#!/usr/bin/env bash
# migrate-diagrams-readme.sh — back-fill `requirements-id` (and `id`) in
# legacy blueprints/current/diagrams/README.md files so they validate against
# the diagrams-readme-blueprint schema introduced by Item 9 of the v11
# progress-gap plan.
#
# Behavior (per plan Item 9):
#
# 1. Walk every data_root/workflow-stream/<feature>/blueprints/current/diagrams/README.md.
# 2. For each file with frontmatter missing, missing `id`, missing `requirements-id`,
#    or `requirements-id` that differs from sibling requirements.md.id, validate the
#    sibling first. If sibling is missing/invalid or has no readable `id`, print the
#    README path and skip (the helper cannot infer the back-reference).
# 3. Back-fill/update `requirements-id` to exactly match the sibling `requirements.md.id`;
#    add `id:` only if absent (generated via scripts/uuid.sh). Do NOT rewrite an existing
#    valid `id` just because it is non-v4. If the existing `id` is present but does NOT
#    match the permissive UUID pattern, surface the path and skip — auto-rewriting could
#    clobber a deliberately-chosen external reference key.
# 4. Validate the resulting file against `diagrams-readme-blueprint`. Refuse to write if
#    validation still fails; print the path and skip.
# 5. Idempotent — re-runs are no-ops on already-valid files whose requirements-id matches.
# 6. Does NOT touch blueprints/history/v*/diagrams/README.md (archived; immutable per
#    the existing coverage policy in hooks/validate-on-write.sh).
#
# Usage:
#   migrate-diagrams-readme.sh           # walk all features under data_root
#   migrate-diagrams-readme.sh --dry-run # print actions; do not write
#
# Exit code: 0 on success (even when some files are skipped); non-zero on
# infrastructure error (e.g., data_root missing).

set -euo pipefail
source "$(dirname "$0")/internal/common.sh"

dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" >&2
      exit 0
      ;;
    *) mi_die "unknown argument: $1" ;;
  esac
done

stream_dir="$(mi_stream_dir)"
[[ -d "$stream_dir" ]] || mi_die "workflow-stream directory not found: $stream_dir"

# Permissive UUID pattern (RFC 4122 v1-v8, valid variant nibble).
uuid_re='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'

migrated=0
already_valid=0
skipped_reasons=()
skipped_paths=()

while IFS= read -r -d '' readme; do
  feature_dir="${readme%/blueprints/current/diagrams/README.md}"
  feature="$(basename "$feature_dir")"
  req="$feature_dir/blueprints/current/requirements.md"

  # Run the migration logic in Python for one file. Exit codes:
  #   0 — wrote a change (or would have, in dry-run)
  #   1 — already valid; no-op
  #   2 — skipped (reason printed to stderr)
  #   3 — infrastructure error (printed to stderr)
  # Note: bash 3.2 chokes on heredocs inside $(...) so we run the command
  # directly and capture only the exit code via $?.
  set +e
  python3 - "$readme" "$req" "$uuid_re" "$dry_run" "$MI_PLUGIN_ROOT" <<'PYEOF'
import os, re, subprocess, sys, yaml, uuid

readme, req, uuid_re, dry_run_str, plugin_root = sys.argv[1:6]
dry_run = dry_run_str == "1"
uuid_pat = re.compile(uuid_re)

def fail(msg, code=2):
    sys.stderr.write(f"{msg}\n")
    sys.exit(code)

def fm_field(path, field):
    if not os.path.isfile(path):
        return None
    with open(path) as f:
        content = f.read()
    m = re.match(r'^---\n(.*?)\n---\n', content, re.DOTALL)
    if not m:
        return None
    try:
        fm = yaml.safe_load(m.group(1)) or {}
    except yaml.YAMLError:
        return None
    return fm.get(field) if isinstance(fm, dict) else None

# Read sibling requirements.md.
if not os.path.isfile(req):
    fail(f"skip {readme}: sibling requirements.md missing ({req})")
req_id = fm_field(req, "id")
if not req_id or not uuid_pat.match(str(req_id)):
    fail(f"skip {readme}: sibling requirements.md has missing or unreadable `id`")

# Read README current state.
with open(readme) as f:
    content = f.read()
m = re.match(r'^(---\n)(.*?)(\n---\n)(.*)$', content, re.DOTALL)
if m:
    fm_text, body = m.group(2), m.group(4)
    try:
        fm = yaml.safe_load(fm_text) or {}
    except yaml.YAMLError:
        fail(f"skip {readme}: existing frontmatter is not valid YAML")
    if not isinstance(fm, dict):
        fail(f"skip {readme}: existing frontmatter is not a YAML object")
else:
    fm = {}
    body = content

# Decide on changes.
existing_id = fm.get("id")
existing_req_id = fm.get("requirements-id")

# id: present-but-invalid → skip; absent → add new uuid; valid → keep as-is.
if existing_id is not None:
    if not uuid_pat.match(str(existing_id)):
        fail(f"skip {readme}: existing `id` is present but invalid (does not match permissive UUID pattern); refusing to auto-rewrite a hand-supplied identifier")
    new_id = existing_id
    id_changed = False
else:
    # Generate new v4 uuid via the project's uuid.sh helper for consistency.
    try:
        new_id = subprocess.run(
            [f"{plugin_root}/scripts/uuid.sh"],
            check=True, capture_output=True, text=True
        ).stdout.strip()
    except subprocess.CalledProcessError:
        new_id = str(uuid.uuid4())
    id_changed = True

# requirements-id: ensure it matches sibling.
req_id_str = str(req_id)
req_id_changed = (existing_req_id != req_id_str)

if not id_changed and not req_id_changed:
    sys.exit(1)  # already valid

# Build new frontmatter (preserve other fields like contributors, date).
new_fm = dict(fm)
new_fm["id"] = new_id
new_fm["requirements-id"] = req_id_str

new_content = "---\n" + yaml.safe_dump(new_fm, default_flow_style=False, sort_keys=False) + "---\n" + body

# Write to a same-directory temp, validate, atomic rename.
tmp = readme + ".migrate.tmp"
with open(tmp, "w") as f:
    f.write(new_content)

result = subprocess.run(
    [f"{plugin_root}/scripts/internal/validate-frontmatter.sh", tmp, "diagrams-readme-blueprint"],
    capture_output=True
)
if result.returncode != 0:
    os.unlink(tmp)
    fail(f"skip {readme}: even after migration, file fails validation against diagrams-readme-blueprint (manual repair required)")

if dry_run:
    os.unlink(tmp)
    print(f"would migrate {readme}: id={'add' if id_changed else 'keep'}, requirements-id={'update' if req_id_changed else 'keep'}", file=sys.stderr)
else:
    os.rename(tmp, readme)
    print(f"migrated {readme}: id={'added' if id_changed else 'kept'}, requirements-id={'updated' if req_id_changed else 'kept'}", file=sys.stderr)
sys.exit(0)
PYEOF
  rc=$?
  set -e
  case "$rc" in
    0) migrated=$((migrated + 1)) ;;
    1) already_valid=$((already_valid + 1)) ;;
    2) skipped_paths[${#skipped_paths[@]}]="$readme" ;;
    *) mi_die "infrastructure error processing $readme (exit $rc)" ;;
  esac
done < <(find "$stream_dir" -type f -path '*/blueprints/current/diagrams/README.md' -print0 2>/dev/null)

mi_info "migration summary: ${migrated} migrated, ${already_valid} already valid, ${#skipped_paths[@]} skipped"
if [[ ${#skipped_paths[@]} -gt 0 ]]; then
  echo "Skipped (manual repair required):" >&2
  for p in "${skipped_paths[@]}"; do
    echo "  - $p" >&2
  done
fi
