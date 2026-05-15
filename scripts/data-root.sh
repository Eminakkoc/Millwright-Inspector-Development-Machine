#!/usr/bin/env bash
# data-root.sh — print the resolved workflow data root to stdout.
#
# This is a thin wrapper over the `mi_data_root` helper in
# scripts/internal/common.sh. It exists so command markdown files can
# resolve the data root once at the top of a shell snippet without
# sourcing the helper:
#
#   data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
#   config="$data_root/workflow-stream/$active_feature/blueprints/current/config.md"
#
# Precedence (see common.sh):
#   1. $MI_DATA_ROOT
#   2. $CLAUDE_PLUGIN_USER_CONFIG_data_root  (Claude Code plugin runtime
#                                             surfacing of userConfig.data_root)
#   3. ./millwright-inspector (default)

set -euo pipefail
source "$(dirname "$0")/internal/common.sh"
mi_data_root
