#!/usr/bin/env bash
#
# ledger.sh — append rows to the active cycle's context-ledger.md.
#
# Phase 6.4 of the context-optimization plan. Records context-heavy events
# (large reads, delegations, sub-agent invocations) so regressions are
# detectable. The ledger is intentionally coarse — exact token accounting
# is not the goal.
#
# Usage:
#   ledger.sh init                                            # writes skeleton (idempotent)
#   ledger.sh append <stage> <command> <files> <class> <location> <artifact>
#                                                              # class    ∈ small | medium | large
#                                                              # location ∈ main | sub-agent | fork
#                                                              # files    — short description (paths or count)
#                                                              # artifact — what the event produced
#
# The append subcommand opens the cycle's context-ledger.md (creating it if
# absent) and writes one row to the `## Events` table. No validation gating
# beyond schema-on-write; rows are an append-only audit trail.
#
# Token class buckets (coarse — buckets are wide on purpose):
#   small  — under ~2k tokens
#   medium — 2k–20k tokens
#   large  — over 20k tokens
#
# Discipline rule: ledger writes are not in the critical path. A failed
# append surfaces a warning but does not block the parent command.

set -euo pipefail
source "$(dirname "$0")/internal/common.sh"

ledger_file() {
  local quest_dir
  quest_dir="$(mo_quest_active_dir 2>/dev/null)" || mo_die "ledger: no active quest"
  echo "$quest_dir/context-ledger.md"
}

cmd="${1:-}"; shift || true

case "$cmd" in
  init)
    dest="$(ledger_file)"
    if [[ -f "$dest" ]]; then
      mo_info "ledger already initialized at $dest (idempotent)"
      exit 0
    fi
    quest_dir="$(mo_quest_active_dir)"
    cycle_slug="$(basename "$quest_dir")"
    mkdir -p "$quest_dir"
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" init context-ledger "$dest" \
      "CYCLE_SLUG=$cycle_slug"
    mo_info "initialized $dest"
    ;;

  append)
    stage="${1:?stage required}"
    command="${2:?command required}"
    files="${3:?files required}"
    class="${4:?class required (small|medium|large)}"
    location="${5:?location required (main|sub-agent|fork)}"
    artifact="${6:?artifact required}"

    [[ "$class" =~ ^(small|medium|large)$ ]] || mo_die "ledger: class must be small|medium|large"
    [[ "$location" =~ ^(main|sub-agent|fork)$ ]] || mo_die "ledger: location must be main|sub-agent|fork"

    dest="$(ledger_file)"
    # Auto-init on first append so callers don't need to remember.
    if [[ ! -f "$dest" ]]; then
      "${MO_PLUGIN_ROOT}/scripts/ledger.sh" init >/dev/null 2>&1 || true
    fi
    [[ -f "$dest" ]] || { echo "ledger: $dest still missing after init — skipping append" >&2; exit 0; }

    # Sanitize pipe characters in user-provided fields so the markdown table
    # row stays well-formed. Replace `|` with `/`; rows that need a literal
    # pipe can document it in the artifact column.
    sanitize() { printf '%s' "$1" | tr '|' '/'; }
    files_clean="$(sanitize "$files")"
    artifact_clean="$(sanitize "$artifact")"
    command_clean="$(sanitize "$command")"

    row="| $stage | $command_clean | $files_clean | $class | $location | $artifact_clean |"

    # Append BEFORE the `## Cycle summary` heading if it exists, otherwise at
    # the end of the file. The `## Events` table grows; the `## Cycle summary`
    # block is filled at stage 8 finalize.
    python3 - "$dest" "$row" <<'PYEOF'
import re, sys
path, row = sys.argv[1], sys.argv[2]
with open(path) as f:
    body = f.read()
marker = '## Cycle summary'
if marker in body:
    new_body = body.replace(marker, row + '\n\n' + marker, 1)
else:
    new_body = body.rstrip() + '\n' + row + '\n'
with open(path, 'w') as f:
    f.write(new_body)
PYEOF
    ;;

  *)
    echo "usage: ledger.sh {init|append} ..." >&2
    exit 2
    ;;
esac
