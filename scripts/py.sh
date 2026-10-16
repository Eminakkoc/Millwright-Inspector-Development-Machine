#!/usr/bin/env bash
# py.sh — run Python through the plugin's resolver from command blocks.
#
# Usage: py.sh <python arguments...>
#   e.g. "$CLAUDE_PLUGIN_ROOT/scripts/py.sh" - "$path" <<'PY'
#
# Command blocks cannot call mi_py directly (each block is a fresh shell that
# has not sourced common.sh), so they call this wrapper instead. It resolves
# the interpreter (python3, python or py -3; see common.sh), adds -X utf8, and
# strips \r from stdout on Windows.

source "$(dirname "$0")/internal/common.sh"

mi_py "$@"
