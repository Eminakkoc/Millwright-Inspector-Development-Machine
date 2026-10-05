#!/usr/bin/env bash
# conventions-review.sh — helper for /mi-conventions-review (1.12.0). Main runs
# `prepare`, spawns one conventions-reviewer per entry, saves each final reply to
# <state>/reply-<idx>.md, then runs `ingest`. Logic lives in
# internal/conventions_review.py; this wrapper checks state and resolves paths.
#
# Spec: docs/superpowers/specs/2026-10-05-conventions-review-design.md
#
# Usage:
#   conventions-review.sh prepare <feature>
#       Gate (stage 3 + sub-flow resuming, or stage 5/6), feature-test no-op,
#       snapshot of changed files at review-head, entry selection, run state.
#       Prints "conventions review: nothing to check", the feature-test line, or
#       "conventions review: N reviewers (<names>)" + "state: <dir>".
#   conventions-review.sh ingest <feature>
#       Parses every reply of the current run (writes nothing if one is missing
#       or unparseable), validates, dedupes and writes findings via review.sh
#       add, prints the report line, appends one ledger row, deletes the run.
set -euo pipefail
source "$(dirname "$0")/internal/common.sh"

PY="$(dirname "$0")/internal/conventions_review.py"
S="${MI_PLUGIN_ROOT}/scripts"
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

cmd="${1:-}"; shift || true

require_active() {
  local active
  active="$("$S/progress.sh" get-active 2>/dev/null || echo null)"
  [[ "$active" == "$1" ]] || mi_die "'$1' is not the active feature (active: $active)"
}

case "$cmd" in
  prepare)
    [[ $# -eq 1 && -n "$1" ]] || usage
    feature="$1"
    require_active "$feature"
    stage="$("$S/progress.sh" get current-stage)"
    sub="$("$S/progress.sh" get sub-flow)"
    case "$stage/$sub" in
      3/resuming|5/*|6/*) ;;
      *) mi_die "conventions review runs from the stage-3 Resume Handler or at stage 5/6 (now: stage $stage, sub-flow $sub)" ;;
    esac
    if "$S/todo.sh" is-feature-test "$feature"; then
      echo "conventions review: not run on the feature-test entry — it tests behaviour, not conventions"
      exit 0
    fi
    top="$(git rev-parse --show-toplevel)"
    review_head="$(git rev-parse HEAD)"
    CVR_LINES="$("$S/commits.sh" changed-lines "$feature" "$review_head")" \
    CVR_SKILLS="$("$S/skills.sh" entries "$feature" review)" \
      python3 "$PY" prepare "$top" "$review_head" "$(mi_data_root)" "$feature"
    ;;
  ingest)
    [[ $# -eq 1 && -n "$1" ]] || usage
    feature="$1"
    require_active "$feature"
    review_md="$(mi_impl_dir "$feature")/inspector-review.md"
    [[ -f "$review_md" ]] || mi_die "inspector-review.md not found: $review_md"
    top="$(git rev-parse --show-toplevel)"
    shopt -s nullglob
    states=("$top"/tmp/conventions-review/*.state)
    shopt -u nullglob
    [[ ${#states[@]} -eq 1 ]] || mi_die "expected one run under tmp/conventions-review/, found ${#states[@]} — run prepare first"
    state="${states[0]}"
    report="$(CVR_REVIEW_SH="$S/review.sh" python3 "$PY" ingest "$top" "$state" "$feature")"
    printf '%s\n' "$report"
    stage="$("$S/progress.sh" get current-stage 2>/dev/null || echo -)"
    "$S/ledger.sh" append "$stage" "/mi-conventions-review" "$(wc -l < "$state/entries.tsv" | tr -d ' ') reviewer replies" \
      small sub-agent "$report" >/dev/null 2>&1 || echo "warning: ledger append failed" >&2
    rm -rf "${state%.state}" "$state"
    ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
