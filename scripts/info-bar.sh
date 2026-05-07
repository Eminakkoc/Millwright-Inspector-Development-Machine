#!/usr/bin/env bash
# info-bar.sh — Claude Code statusLine command for millwright-overseer-development-machine.
#
# Reads the per-cycle sidecar produced by hooks/track-stage-tokens.sh
# (`quest/<active-slug>/.stage-tokens.json`) and prints one line for
# Claude Code's bottom-bar display. Refreshes constantly — runtime budget
# is sub-50ms.
#
# This script is the dumb display layer per docs/info-bar/plan.md § 4:
# it never parses Claude Code transcripts, never does math, never writes
# anything. The hook does all the expensive work and persists the result
# to the sidecar; this script just formats one line.
#
# Wiring (per Claude Code's plugin reference, statusLine is NOT
# distributable through plugin manifests). The user opts in by adding to
# their .claude/settings.json:
#
#   { "statusLine": { "type": "command",
#                     "command": "$CLAUDE_PLUGIN_ROOT/scripts/info-bar.sh" } }
#
# /mo-init offers this opt-in interactively (see commands/mo-init.md).

set -euo pipefail

# Output formats:
#
#   mo · no active cycle                                                                          (no active cycle)
#   mo · cycle <slug-short> · pre-stage-1                                                         (cycle exists, sidecar missing)
#   mo · cycle <slug-short> · stage <S> ✓ │ up to that point: <Nk> │ current stage: <Mk>          (cycle-level stage 1/1.5)
#   mo · cycle <slug-short> · feature <X> · stage <S> ✓ │ up to that point: <Nk> │ current stage: <Mk>  (feature-level stage)
#
# The slug is truncated to first 18 chars + `…` when longer.

# Find the plugin root from this script's location (so we can call sibling scripts
# without depending on $CLAUDE_PLUGIN_ROOT being exported into the statusLine env).
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the active cycle slug. quest.sh has-active exits 0 when active, non-zero otherwise.
if ! "${script_dir}/quest.sh" has-active 2>/dev/null; then
  echo "mo · no active cycle"
  exit 0
fi

# Get the active slug (basename of the quest dir).
quest_dir="$("${script_dir}/quest.sh" dir 2>/dev/null || true)"
[[ -n "$quest_dir" ]] || { echo "mo · no active cycle"; exit 0; }
slug="$(basename "$quest_dir")"

# Truncate slug for compactness.
if (( ${#slug} > 18 )); then
  slug_short="${slug:0:18}…"
else
  slug_short="$slug"
fi

sidecar="${quest_dir}/.stage-tokens.json"
if [[ ! -f "$sidecar" ]]; then
  echo "mo · cycle ${slug_short} · pre-stage-1"
  exit 0
fi

# Parse the sidecar. We use python3 for speed + reliability — yq's JSON path is
# slower than a single python3 invocation for small files. python3 is already
# a required dep (per scripts/doctor.sh).
set +e
python3 - "$sidecar" "$slug_short" <<'PYEOF'
import json, sys

path = sys.argv[1]
slug_short = sys.argv[2]

def fmt_tokens(n):
    if n is None:
        return "?"
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.0f}k"
    return str(n)

try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    sys.exit(2)

stage = data.get("current_stage")
feature = data.get("current_feature")
up_to = data.get("up_to_that_point_tokens")
this = data.get("current_stage_tokens")

# Build the line piece by piece.
parts = [f"mo · cycle {slug_short}"]
if feature:
    parts.append(f"feature {feature}")
if stage:
    parts.append(f"stage {stage} ✓")
prefix = " · ".join(parts)

if up_to is not None or this is not None:
    print(f"{prefix} │ up to that point: {fmt_tokens(up_to)} │ current stage: {fmt_tokens(this)}")
else:
    # Sidecar exists but no stages recorded yet (rare — between hook init and first row write).
    print(f"{prefix}")
PYEOF
rc=$?
set -e
if (( rc != 0 )); then
  # Sidecar unreadable — surface a diagnostic but don't error the prompt.
  echo "mo · cycle ${slug_short} · sidecar error · check stage-tokens.json"
fi
