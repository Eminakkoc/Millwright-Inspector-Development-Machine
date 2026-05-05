#!/usr/bin/env bash
# quest.sh — manage the active-quest pointer at quest/active.md.
#
# The quest folder is per-cycle: each /mo-run creates a fresh subfolder
# (named after a date-prefixed slug derived from the journal folders)
# and writes todo-list.md, summary.md, progress.md, and queue-rationale.md
# inside it. Historical cycle folders are preserved as a permanent task
# archive. The top-level quest/active.md file is the single piece of
# mutable state and tells path-resolution helpers which subfolder is
# the currently-active cycle.
#
# Usage:
#   quest.sh slug <folder1> [<folder2> ...]
#       Compute the canonical slug for the given journal folders and
#       print to stdout. Does not create any files. Used by /mo-run
#       to show the user which slug is about to be created.
#
#   quest.sh start <slug> <folder1> [<folder2> ...]
#       Begin a new cycle: create quest/<slug>/ if missing and write
#       quest/active.md with status=active. Refuses if there is already
#       an active cycle (slug != null AND status=active) — the caller
#       must run `quest.sh end` (or pass /mo-run --archive-active) first.
#
#   quest.sh end
#       End the current cycle: set quest/active.md to slug=null,
#       status=archived. Leaves the per-cycle subfolder intact under
#       quest/<slug>/ for historical querying. Idempotent — safe to call
#       even if no cycle is active.
#
#   quest.sh init-pointer
#       Create quest/active.md with status=none if it doesn't exist.
#       Used by /mo-init to scaffold a fresh workspace.
#
#   quest.sh current
#       Print the active slug to stdout, or empty if none.
#       Exit 0 if a cycle is active, 1 if not.
#
#   quest.sh dir
#       Print the path of the active quest's subfolder, e.g.
#       /path/to/millwright-overseer/quest/2026-04-27-pricing-meeting.
#       Errors if no cycle is active.
#
#   quest.sh has-active
#       Exit 0 if a cycle is active, 1 if not. Silent.
#
#   quest.sh status
#       Print the status field (active|archived|none) or empty if the
#       pointer file is missing.
#
#   quest.sh list
#       List historical quest subfolders, one per line (excluding
#       active.md). Sorted lexicographically (which is also chronological
#       since the slug is date-prefixed).

set -euo pipefail
source "$(dirname "$0")/internal/common.sh"

cmd="${1:-}"; shift || true

case "$cmd" in
  slug)
    [[ $# -gt 0 ]] || mo_die "slug: at least one journal folder required"
    mo_quest_compute_slug "$@"
    ;;

  start)
    new_slug="${1:?slug required}"; shift
    [[ $# -gt 0 ]] || mo_die "start: at least one journal folder required"
    pointer="$(mo_quest_active_pointer)"
    quest_root="$(mo_quest_dir)"

    # Refuse if a cycle is already active.
    if [[ -f "$pointer" ]]; then
      existing_slug="$(mo_active_quest_slug 2>/dev/null || true)"
      if [[ -n "$existing_slug" ]]; then
        existing_status="$(mo_fm_get "$pointer" status 2>/dev/null || echo "active")"
        if [[ "$existing_status" == "active" ]]; then
          mo_die "active cycle already in flight (slug=${existing_slug}). End it with 'quest.sh end' or run /mo-run --archive-active to archive it before starting a new one."
        fi
      fi
    fi

    # Create the per-cycle subfolder.
    target_dir="${quest_root}/${new_slug}"
    [[ ! -d "$target_dir" ]] || mo_die "quest subfolder already exists: $target_dir (slug collision)"
    mkdir -p "$target_dir"

    # Render quest/active.md from the template. The pointer file has no UUID
    # — it's a singleton not cross-referenced from anywhere — so we render
    # the template directly without invoking frontmatter.sh init (which
    # auto-injects UUIDs).
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    folders_csv="$(printf '%s,' "$@" | sed 's/,$//')"
    python3 - "${MO_PLUGIN_ROOT}/templates/active-quest.md.tmpl" "$pointer" \
      "${new_slug}" "${started}" "${folders_csv}" "active" <<'PYEOF'
import sys
tmpl, dest, slug, started, folders, status = sys.argv[1:]
with open(tmpl) as f:
    content = f.read()
# Render journal-folders as YAML flow array tokens (kebab-strings, no quotes).
folder_tokens = ', '.join(f for f in folders.split(',') if f)
content = (content
    .replace('{{SLUG}}', slug)
    .replace('{{STARTED}}', started)
    .replace('{{JOURNAL_FOLDERS}}', folder_tokens)
    .replace('{{STATUS}}', status))
with open(dest, 'w') as f:
    f.write(content)
PYEOF

    # Validate the freshly-written pointer.
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$pointer" active-quest >/dev/null
    mo_info "started quest cycle slug=${new_slug} (folder=${target_dir})"
    ;;

  end)
    pointer="$(mo_quest_active_pointer)"
    if [[ ! -f "$pointer" ]]; then
      mo_info "no active-quest pointer exists; nothing to end"
      exit 0
    fi
    # Set slug=null, status=archived. Use mo_fm_set to preserve other fields.
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" set "$pointer" slug "null" >/dev/null
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" set "$pointer" status "archived" >/dev/null
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$pointer" active-quest >/dev/null
    mo_info "ended active quest cycle (status=archived)"
    ;;

  init-pointer)
    pointer="$(mo_quest_active_pointer)"
    if [[ -f "$pointer" ]]; then
      mo_info "quest/active.md already exists; leaving it untouched"
      exit 0
    fi
    mkdir -p "$(mo_quest_dir)"
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    python3 - "${MO_PLUGIN_ROOT}/templates/active-quest.md.tmpl" "$pointer" \
      "null" "${started}" "" "none" <<'PYEOF'
import sys
tmpl, dest, slug, started, folders, status = sys.argv[1:]
with open(tmpl) as f:
    content = f.read()
folder_tokens = ', '.join(f for f in folders.split(',') if f)
content = (content
    .replace('{{SLUG}}', slug)
    .replace('{{STARTED}}', started)
    .replace('{{JOURNAL_FOLDERS}}', folder_tokens)
    .replace('{{STATUS}}', status))
with open(dest, 'w') as f:
    f.write(content)
PYEOF
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$pointer" active-quest >/dev/null
    mo_info "scaffolded empty quest/active.md (status=none)"
    ;;

  current)
    if slug="$(mo_active_quest_slug 2>/dev/null)"; then
      printf '%s\n' "$slug"
    else
      exit 1
    fi
    ;;

  dir)
    mo_quest_active_dir
    ;;

  has-active)
    if mo_active_quest_slug >/dev/null 2>&1; then
      exit 0
    else
      exit 1
    fi
    ;;

  status)
    pointer="$(mo_quest_active_pointer)"
    [[ -f "$pointer" ]] || exit 0
    mo_fm_get "$pointer" status
    ;;

  list)
    quest_root="$(mo_quest_dir)"
    [[ -d "$quest_root" ]] || exit 0
    # List subdirectories under quest/, excluding the active.md file.
    find "$quest_root" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null \
      | xargs -I{} basename {} \
      | sort
    ;;

  feature-section)
    # Phase 6.5 of the context-optimization plan: extract just one feature's
    # section from the active cycle's summary.md, plus the cross-cutting
    # constraints, instead of reading the whole file. Used by stages 2, 3, 6
    # when only the active feature's content is needed; the on-disk file
    # stays canonical, but the slice keeps main-context reads bounded.
    #
    # Output: stdout carries the `## Cross-cutting constraints` section
    # followed by the matching `## Feature: <feature>` section. Other
    # features' sections are intentionally omitted. Exit 0 on success;
    # exit 1 if the feature is not found in the file.
    feature="${1:?feature required}"
    quest_dir="$(mo_quest_active_dir)" || mo_die "feature-section: no active quest"
    summary_file="$quest_dir/summary.md"
    [[ -f "$summary_file" ]] || mo_die "feature-section: $summary_file not found"
    python3 - "$summary_file" "$feature" <<'PYEOF'
import re, sys
path, target = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()
# Extract `## Cross-cutting constraints` (always emit if present).
cc = re.search(r'(^## Cross-cutting constraints\s*\n.*?)(?=^## |\Z)', content, re.MULTILINE | re.DOTALL)
if cc:
    print(cc.group(1).rstrip())
    print()
# Extract the matching feature section.
fs = re.search(rf'(^## Feature:\s+{re.escape(target)}\s*\n.*?)(?=^## |\Z)', content, re.MULTILINE | re.DOTALL)
if not fs:
    sys.stderr.write(f"feature-section: no `## Feature: {target}` heading in {path}\n")
    sys.exit(1)
print(fs.group(1).rstrip())
PYEOF
    ;;

  *)
    echo "usage: quest.sh {slug|start|end|init-pointer|current|dir|has-active|status|list|feature-section} ..." >&2
    exit 2
    ;;
esac
