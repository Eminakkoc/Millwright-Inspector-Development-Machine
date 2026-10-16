#!/usr/bin/env bash
# guard-batch-reviewer.sh — PreToolUse(Bash) hook (v1.8.0; any-install wrapper paths v1.8.1;
# stdin + fast path 1.13.0).
#
# blueprint-batch-reviewer is structurally read-only. It needs Bash only to reach
# codex through scripts/codex-review.sh, and plugin agents cannot carry their own
# hooks or scoped Bash rules. So this plugin-level hook fires for every Bash call,
# ignores every caller except that agent, and admits exactly one command shape:
#
#   <plugin>/scripts/codex-review.sh open|reply [--backend B] [--effort X] [--thread Y] <<'DELIM'
#   ...prompt body (quoted heredoc — never expanded)...
#   DELIM
#
# <plugin> is this hook's own plugin root, or any other install of this plugin —
# e.g. a source checkout the orchestrator resolved via §8.14 step 2 (v1.8.1). The
# path may be quoted, and then may contain spaces.
#
# Anything else from that agent is blocked (exit 2; stderr goes back to the agent).
# The checks live in guard_batch_reviewer.py.

set -euo pipefail

input="$(cat)"

# Fast path: only the batch reviewer's own calls carry its agent name, and
# Claude Code writes the hook JSON itself without escaping plain hyphens, so
# every other Bash call exits here without starting Python.
[[ "$input" == *blueprint-batch-reviewer* ]] || exit 0

source "$(dirname "$0")/../scripts/internal/common.sh"

# The event goes in on stdin, never as one argument: Windows caps a command
# line at 32,767 characters, and past that the hook would fail open (WIN-12).
printf '%s' "$input" | mi_py "$(dirname "$0")/guard_batch_reviewer.py" "${CLAUDE_PLUGIN_ROOT:-}"
