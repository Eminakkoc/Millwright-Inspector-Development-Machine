#!/usr/bin/env bash
# lessons.sh — manage <data_root>/lessons-learned.md, the cumulative record of
# mistakes surfaced by PR reviews so future implementations don't repeat them.
#
# The file is append-only and lives at the top level of the data root, a
# sibling of journal/, quest/, workflow-stream/, and pr-reviews/. It is created
# on demand the first time a lesson is appended. config.md references it by
# path (written by mo-apply-impact) so the planning/implementation chains read
# it before writing code.
#
# Self-validation: append runs frontmatter.sh validate after each write — the
# PostToolUse write-hook only fires on Edit/Write tool calls, so a
# script-written artifact must validate inline.
#
# Usage:
#   lessons.sh path                                  # print the resolved lessons-learned.md path
#   lessons.sh append --source <ref> --title <text>  # lesson body read from stdin
#                                                    # appends a new ## L-NNN entry (auto-incremented)

set -euo pipefail
source "$(dirname "$0")/internal/common.sh"

lessons_file() { echo "$(mo_data_root)/lessons-learned.md"; }

cmd="${1:-}"; shift || true

case "$cmd" in
  path)
    lessons_file
    ;;

  append)
    source_ref=""
    title=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --source) [[ $# -ge 2 ]] || mo_die "append: --source requires a value"; source_ref="$2"; shift 2 ;;
        --source=*) source_ref="${1#--source=}"; shift ;;
        --title)  [[ $# -ge 2 ]] || mo_die "append: --title requires a value"; title="$2"; shift 2 ;;
        --title=*) title="${1#--title=}"; shift ;;
        *) mo_die "append: unknown argument: $1" ;;
      esac
    done
    [[ -n "$title" ]]      || mo_die "append: --title is required"
    [[ -n "$source_ref" ]] || mo_die "append: --source is required"

    dest="$(lessons_file)"
    if [[ ! -f "$dest" ]]; then
      "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" init lessons-learned "$dest" >/dev/null
    fi

    lesson_body=""
    if [[ ! -t 0 ]]; then
      lesson_body="$(cat)"
    fi
    [[ -n "${lesson_body//[[:space:]]/}" ]] || mo_die "append: lesson body (stdin) is empty"

    today="$(date -u +%Y-%m-%d)"
    python3 - "$dest" "$title" "$today" "$source_ref" "$lesson_body" <<'PYEOF'
import re, sys
path, title, today, source_ref, body = sys.argv[1:6]
with open(path) as f:
    content = f.read()
# Scan for the last L-NNN, ignoring the worked example inside the template's
# HTML comment block (which would otherwise be counted as L-001).
scan = re.sub(r'<!--.*?-->', '', content, flags=re.DOTALL)
last = 0
for m in re.finditer(r'^## L-(\d{3}) ', scan, re.MULTILINE):
    last = max(last, int(m.group(1)))
lid = f"L-{last + 1:03d}"
block_lines = [
    f"## {lid} — {title}",
    f"- date:   {today}",
    f"- source: {source_ref}",
    "- lesson: |",
]
for ln in body.splitlines():
    block_lines.append(f"    {ln}")
block = "\n".join(block_lines) + "\n"
content = content.rstrip() + "\n\n" + block
with open(path, 'w') as f:
    f.write(content)
print(lid)
PYEOF
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$dest" lessons-learned >/dev/null
    mo_info "appended lesson to $dest"
    ;;

  *)
    echo "usage: lessons.sh {path|append} ..." >&2
    exit 2
    ;;
esac
