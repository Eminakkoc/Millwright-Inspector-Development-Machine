#!/usr/bin/env bash
# validate-on-write.sh — PostToolUse(Write|Edit) hook for millwright-overseer-development-machine.
#
# Reads the tool-call JSON on stdin, extracts the touched file path, and —
# if it's a workflow data file — validates its frontmatter against the matching
# schema. Any validation failure blocks Claude's next turn with an error.
#
# The hook is a no-op for any file outside the workflow data root, so it
# doesn't interfere with normal editing elsewhere in the project.

set -euo pipefail

# Parse tool input JSON from stdin; extract the file path field.
# Claude Code passes either `tool_input.file_path` (Write/Edit) — we accept both.
input="$(cat)"
file_path="$(printf '%s' "$input" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = data.get("tool_input", {}) or {}
path = ti.get("file_path") or ti.get("path") or ""
print(path)
' 2>/dev/null || echo "")"

# No file path or not under workflow data root → skip silently.
[[ -n "$file_path" ]] || exit 0

# Resolve the configured data-root segment (default `millwright-overseer`,
# but the user can override via $MO_DATA_ROOT or userConfig.data_root). The
# hook only validates files that live under that segment so workflows in a
# custom-named data folder still get validated, and files outside any data
# folder are silently skipped.
if [[ -f "${CLAUDE_PLUGIN_ROOT:-}/scripts/internal/common.sh" ]]; then
  # Source common.sh in a subshell so its `set -euo pipefail` doesn't leak.
  data_root_segment="$(bash -c "source '${CLAUDE_PLUGIN_ROOT}/scripts/internal/common.sh' && mo_data_root_segment")"
else
  data_root_segment="millwright-overseer"
fi
[[ "$file_path" == *"/${data_root_segment}/"* ]] || exit 0

# Only check .md files.
[[ "$file_path" == *.md ]] || exit 0

# Map file basename + path context → schema name.
#
# Coverage policy: this hook validates LIVE workflow artifacts only — files
# under `quest/`, `blueprints/current/`, and `implementation/`. Files under
# `blueprints/history/v*/` are an audit archive: they are produced by
# `blueprints.sh rotate` and `mo-complete-workflow`'s implementation-archival
# step via shell `mv` (no Edit/Write tool call, so the hook would not fire
# even if a case matched), and once rotated they are expected to be
# immutable. Their content was validated when they lived in `current/` or
# `implementation/`. The single exception is `blueprints/history/v*/reason.md`,
# which IS written by the rotation step via `frontmatter.sh init` and
# therefore must be schema-checked. The archived `implementation/` artifacts
# (`overseer-review.md`, `review-context.md`, `change-summary.md`,
# `diagrams/`) under `blueprints/history/v*/implementation/` follow the same
# "validated when live, immutable once archived" rule as the rotated
# blueprint files. If you ever need to edit a historical artifact by hand,
# run the validator manually — the hook intentionally does not gate that
# path.
schema=""
case "$file_path" in
  */quest/active.md)                     schema="active-quest" ;;
  */quest/*/progress.md)                 schema="progress" ;;
  */quest/*/todo-list.md)                schema="todo-list" ;;
  */quest/*/summary.md)                  schema="summary" ;;
  */quest/*/queue-rationale.md)          schema="queue-rationale" ;;
  */blueprints/current/requirements.md)  schema="requirements" ;;
  */blueprints/current/config.md)        schema="config" ;;
  */blueprints/current/primer.md)        schema="primer" ;;
  */blueprints/current/diagrams/README.md) schema="diagrams-readme-blueprint" ;;
  */workflow-stream/*/decisions.md)      schema="decisions" ;;
  */implementation/overseer-review.md)   schema="review-file" ;;
  */implementation/review-context.md)    schema="review-context" ;;
  */implementation/change-summary.md)    schema="change-summary" ;;
  */implementation/diagrams/README.md)   schema="diagrams-readme-implementation" ;;
  */blueprints/history/v*/reason.md)     schema="reason" ;;
  *) exit 0 ;;  # unknown / archived mo file → skip per coverage policy
esac

# Run the validator. If it fails, its stderr bubbles up and blocks the turn.
if ! "${CLAUDE_PLUGIN_ROOT}/scripts/internal/validate-frontmatter.sh" "$file_path" "$schema" >&2; then
  # Emit a JSON response that blocks the stop and explains why.
  cat <<EOF
{"decision": "block", "reason": "millwright-overseer-development-machine: frontmatter validation failed for $file_path (schema=$schema). Fix the frontmatter before continuing."}
EOF
  exit 2
fi

exit 0
