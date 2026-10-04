#!/usr/bin/env bash
# skills.sh — skill lookup helper (1.11.0). The one reader of the stage-2 skill
# selection in config.md's auto block, and the one place that asks the project,
# enabled plugins and the catalog which skills exist. Parsing lives in
# internal/skills.py; this wrapper checks arguments and resolves paths.
#
# Spec: docs/superpowers/specs/2026-10-04-skills-across-workflow-design.md
#
# Usage:
#   skills.sh inventory [--installed]          # TSV: name kind origin description path needs
#                                              # (kind: skill | catalog-skill | broken).
#                                              # --installed skips the catalog source.
#   skills.sh lookup <name|bundle:name> ...    # TSV: name kind scope bundle
#                                              # (names the catalog doesn't list: `<name> unknown - -`)
#   skills.sh brief <feature> implement|review # the "## Skills for this work (from config.md)" /
#                                              # "## Skills for reviewing this work" block
#   skills.sh entries <feature> implement|review
#                                              # TSV: name abs-path (same entries as brief)
#   skills.sh suggestions <feature>            # TSV: name requested stages install reason
#                                              # (## Catalog suggestions; empty when none)
#   skills.sh catalog-files                    # project-relative paths to commit after an install
#   skills.sh apply-installs <feature> [--installed a,b] [--declined c] [--failed d] [--stop]
#                                              # rewrites config.md's auto block after the
#                                              # stage-2 gate's installs
#
# Every subcommand prints nothing and exits 0 when nothing matches. Without the
# catalog CLI on PATH, inventory and lookup print one stderr note and exit 0.

set -euo pipefail
source "$(dirname "$0")/internal/common.sh"

SKILLS_PY="$(cd "$(dirname "$0")" && pwd)/internal/skills.py"

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

feature_config() {
  [[ -n "${1:-}" ]] || usage
  printf '%s/config.md' "$(mi_blueprints_current "$1")"
}

check_tag() {
  case "${1:-}" in
    implement|review) ;;
    *) mi_die "tag must be implement or review (got '${1:-}')" ;;
  esac
}

cmd="${1:-}"
[[ -n "$cmd" ]] || usage
shift

case "$cmd" in
  inventory)
    [[ $# -eq 0 || ( $# -eq 1 && "$1" == "--installed" ) ]] || usage
    python3 "$SKILLS_PY" inventory "$@"
    ;;
  lookup)
    [[ $# -ge 1 ]] || usage
    python3 "$SKILLS_PY" lookup "$@"
    ;;
  brief|entries)
    [[ $# -eq 2 ]] || usage
    check_tag "$2"
    config="$(feature_config "$1")"
    python3 "$SKILLS_PY" "$cmd" "$config" "$2"
    ;;
  suggestions)
    [[ $# -eq 1 ]] || usage
    config="$(feature_config "$1")"
    python3 "$SKILLS_PY" suggestions "$config"
    ;;
  catalog-files)
    [[ $# -eq 0 ]] || usage
    python3 "$SKILLS_PY" catalog-files
    ;;
  apply-installs)
    [[ $# -ge 1 ]] || usage
    config="$(feature_config "$1")"
    shift
    [[ -f "$config" ]] || mi_die "config.md not found: $config"
    for arg in "$@"; do
      case "$arg" in
        --installed|--declined|--failed|--stop) ;;
        --*) mi_die "unknown option: $arg" ;;
      esac
    done
    python3 "$SKILLS_PY" apply-installs "$config" "$@"
    ;;
  -h|--help|help) usage ;;
  *) mi_die "unknown subcommand: $cmd" ;;
esac
