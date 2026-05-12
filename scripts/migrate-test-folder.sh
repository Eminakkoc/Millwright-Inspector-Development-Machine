#!/usr/bin/env bash
# migrate-test-folder.sh — one-shot migration that moves manual-test artifacts
# from each feature's implementation/ folder into a sibling test/ folder.
#
# Background: docs/manual-testing-folder/plan.md relocates the manual-test
# plan, results, and rotated-plan-history into a new feature-permanent
# `test/` folder. After the code change ships, helpers and commands look
# for the artifacts under test/, not implementation/ — so any in-flight
# feature that already has files under implementation/ needs them moved
# once.
#
# Migrated paths:
#   workflow-stream/<feature>/implementation/manual-test-plan.md
#     → workflow-stream/<feature>/test/manual-test-plan.md
#   workflow-stream/<feature>/implementation/manual-test-results.md
#     → workflow-stream/<feature>/test/manual-test-results.md
#   workflow-stream/<feature>/implementation/manual-test-plan.history/
#     → workflow-stream/<feature>/test/manual-test-plan.history/
#
# Idempotent: uses `mv -n` so re-runs of a partially-migrated tree never
# clobber existing test/ files. Per-feature summary line tells the
# operator exactly what happened.
#
# Archived history under blueprints/history/v[N]/implementation/ is left
# alone — those copies are immutable audit records, not live state.
#
# Usage:
#   scripts/migrate-test-folder.sh [--data-root /path/to/data]
#
# Without --data-root, resolves via scripts/data-root.sh (MO_DATA_ROOT
# env / CLAUDE_PLUGIN_USER_CONFIG_data_root / ./millwright-overseer).

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

data_root=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-root)
      [[ $# -ge 2 ]] || { echo "error: --data-root requires a path" >&2; exit 2; }
      data_root="$2"
      shift 2
      ;;
    --data-root=*)
      data_root="${1#--data-root=}"
      shift
      ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1 (expected --data-root <path>)" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$data_root" ]]; then
  data_root="$("$here/data-root.sh")"
fi

stream_dir="$data_root/workflow-stream"
if [[ ! -d "$stream_dir" ]]; then
  echo "no workflow-stream/ under $data_root — nothing to migrate"
  exit 0
fi

moved_count=0
nothing_count=0
already_count=0
total_features=0

for feature_dir in "$stream_dir"/*/; do
  [[ -d "$feature_dir" ]] || continue
  feature="$(basename "$feature_dir")"
  total_features=$((total_features + 1))

  impl_dir="$feature_dir/implementation"
  test_dir="$feature_dir/test"

  src_plan="$impl_dir/manual-test-plan.md"
  src_results="$impl_dir/manual-test-results.md"
  src_history="$impl_dir/manual-test-plan.history"

  has_src=0
  [[ -f "$src_plan" || -f "$src_results" || -d "$src_history" ]] && has_src=1

  has_dst=0
  [[ -f "$test_dir/manual-test-plan.md" \
     || -f "$test_dir/manual-test-results.md" \
     || -d "$test_dir/manual-test-plan.history" ]] && has_dst=1

  if [[ "$has_src" == "0" ]]; then
    if [[ "$has_dst" == "1" ]]; then
      echo "$feature: already-migrated"
      already_count=$((already_count + 1))
    else
      echo "$feature: nothing-to-move"
      nothing_count=$((nothing_count + 1))
    fi
    continue
  fi

  mkdir -p "$test_dir"

  if [[ -f "$src_plan" ]]; then
    mv -n "$src_plan" "$test_dir/manual-test-plan.md"
  fi
  if [[ -f "$src_results" ]]; then
    mv -n "$src_results" "$test_dir/manual-test-results.md"
  fi
  if [[ -d "$src_history" ]]; then
    # mv -n on a directory only refuses if the destination already exists.
    if [[ -d "$test_dir/manual-test-plan.history" ]]; then
      # Merge content rather than fail. Use mv -n on each child so any
      # pre-existing rotation snapshots in test/ are preserved.
      for snap in "$src_history"/*/; do
        [[ -d "$snap" ]] || continue
        mv -n "$snap" "$test_dir/manual-test-plan.history/"
      done
      # Remove the now-empty source dir; leave behind if anything remains.
      rmdir "$src_history" 2>/dev/null || \
        echo "  warning: $src_history not fully emptied (some snapshots collided with existing test/ snapshots)"
    else
      mv -n "$src_history" "$test_dir/manual-test-plan.history"
    fi
  fi

  echo "$feature: moved"
  moved_count=$((moved_count + 1))
done

echo ""
echo "Summary: moved=$moved_count nothing-to-move=$nothing_count already-migrated=$already_count total-features=$total_features"
