#!/usr/bin/env bash
# run.sh — rename-leakage lint guard.
#
# Fails the suite if any stale pre-rename token survives in the tree. This is
# the regression guard for the overseer->inspector / mo->mi rename: once the
# rename landed, any reappearance of an old token is a defect.
#
# Excluded by design:
#   docs/rename-inspector/  — the rename plan itself quotes the old names
#   CHANGELOG.md            — the breaking-change entry names the old plugin
#   tests/lint/             — this guard necessarily contains the old tokens
#   hooks/validate-on-write.sh legacy-path branch — the hook deliberately
#                             pattern-matches the old review-file name in
#                             order to hard-reject writes to it
#   docs/millwright-inspector-project.md "Hard-rejected" prose — the project
#                             doc names the legacy `overseer-review.md` path
#                             once when documenting which writes the hook
#                             rejects
#
# Each check captures output with `|| true` so a clean tree (git grep exits
# non-zero on no matches) does not itself fail the guard.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

EXCLUDES=(':!docs/rename-inspector/' ':!CHANGELOG.md' ':!tests/lint/')
fail=0

report() {
  # $1 = human label, $2 = captured matches
  if [[ -n "$2" ]]; then
    printf '\xe2\x9c\x97 %s\n%s\n\n' "$1" "$2" >&2
    fail=1
  else
    printf '\xe2\x9c\x93 %s\n' "$1"
  fi
}

# --- overseer -> inspector -------------------------------------------------
old="over""seer"
m=$(git grep -in "$old" -- "${EXCLUDES[@]}" \
  | grep -vE "^hooks/validate-on-write\.sh:[0-9]+:.*${old}-review\.md" \
  | grep -vE "^docs/millwright-inspector-project\.md:[0-9]+:.*legacy path.*${old}-review\.md" || true)
report "no stale '$old' references" "$m"

# --- mo-* command tokens (slash and bare) ----------------------------------
m=$(git grep -nE '(^|[^A-Za-z])mo-[a-z]' -- "${EXCLUDES[@]}" || true)
report "no stale 'mo-' command tokens" "$m"

m=$(git ls-files 'commands/mo-*.md' || true)
report "no remaining commands/mo-*.md files" "$m"

# --- MO_ env vars (CLAUDE_PLUGIN_ROOT intentionally not listed) ------------
m=$(git grep -nwE 'MO_(DATA_ROOT|PLUGIN_ROOT)' -- "${EXCLUDES[@]}" || true)
report "no stale MO_ env-var references" "$m"

# --- internal mo_ bash function/variable prefix ----------------------------
m=$(git grep -nE '(^|[^A-Za-z])mo_[a-z]' -- "${EXCLUDES[@]}" || true)
report "no stale 'mo_' bash identifiers" "$m"

# --- mo: status prefix and sync-marker -------------------------------------
m=$(git grep -nE '(^|[^A-Za-z])mo:' -- "${EXCLUDES[@]}" || true)
report "no stale 'mo:' prefix / sync-marker" "$m"

# --- capitalized self-name in prose ----------------------------------------
m=$(git grep -nE '(^|[^A-Za-z])Mo-[a-z]' -- "${EXCLUDES[@]}" || true)
report "no stale 'Mo-' prose tokens" "$m"

# --- blueprint-batch-reviewer read-only invariant (v1.4) ---------------------
# The agent must list ONLY codex MCP tools (mcp__codex__codex, mcp__codex__codex-reply)
# in its tools: frontmatter. Adding Read/Write/Edit/Bash/Grep would break the
# read-only isolation guarantee.
bbr="agents/blueprint-batch-reviewer.md"
bbr_tools=$(git show "HEAD:$bbr" | awk '/^tools:/{print; exit}')
bad=""
for tok in Read Write Edit Bash Grep; do
  echo "$bbr_tools" | grep -qF "$tok" && bad="${bad}${tok} "
done
report "blueprint-batch-reviewer tools: contains no filesystem tools (Read/Write/Edit/Bash/Grep)" "$bad"

# --- delegation contract note (v1.6.12) -------------------------------------
# Every command that spawns a sub-agent must carry the "Delegation contract"
# note under its H1 and cite §8.15. Without it an agent running the command
# hits Claude Code's "do not call the Agent tool unless the user requested it"
# default, and either stops to ask or silently does the delegated work in main
# — breaking the §8.13 main-read budget. See docs/millwright-inspector-project.md §8.15.
DELEGATING_COMMANDS=(
  mi-run mi-continue mi-apply-impact mi-generate-implementation-diagrams
  mi-review mi-complete-workflow mi-analyze-review mi-sidequest
  mi-blueprint-review mi-blueprint-review-item mi-blueprint-review-consistency
)
missing=""
for c in "${DELEGATING_COMMANDS[@]}"; do
  f="commands/$c.md"
  [[ -f "$f" ]] || { missing="${missing}${f} (file absent) "; continue; }
  grep -qF '**Delegation contract.**' "$f" || missing="${missing}${f} (no note) "
  grep -qF '§8.15' "$f" || missing="${missing}${f} (no §8.15 citation) "
done
report "every delegating command carries the Delegation contract note" "$missing"

# Reverse drift net: a command that names a subagent_type but is not on the
# list above is a new delegation site that never got the note.
untracked=""
while IFS= read -r f; do
  base="$(basename "$f" .md)"
  for c in "${DELEGATING_COMMANDS[@]}"; do
    [[ "$base" == "$c" ]] && { base=""; break; }
  done
  [[ -n "$base" ]] && untracked="${untracked}${f} "
done < <(git grep -l 'subagent_type' -- 'commands/*.md' || true)
report "no delegating command missing from the DELEGATING_COMMANDS list" "$untracked"

# The note points at §8.15 — it must exist.
m=""
grep -qF '### 8.15 Delegation is part of the command contract' \
  docs/millwright-inspector-project.md || m="§8.15 missing from the project doc"
report "project doc defines §8.15 (delegation contract)" "$m"

echo
if [[ "$fail" -ne 0 ]]; then
  echo "rename lint guard FAILED — rename the tokens above to the inspector/mi names" >&2
  exit 1
fi
echo "rename lint guard passed"
