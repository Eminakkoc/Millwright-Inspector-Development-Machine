#!/usr/bin/env bash
# uuid.sh — generate a single UUID v4 and print it to stdout.
# Usage: uuid.sh

set -euo pipefail

# Prefer system uuidgen (BSD/macOS/Linux); fall back to Python — Git Bash on
# Windows ships no uuidgen. common.sh is sourced only on that path, so the
# uuidgen path starts no extra process. Lowercase either way.
if command -v uuidgen >/dev/null 2>&1; then
  uuidgen | tr '[:upper:]' '[:lower:]'
else
  source "$(dirname "$0")/internal/common.sh"
  mi_py -c "import uuid; print(uuid.uuid4())"
fi
