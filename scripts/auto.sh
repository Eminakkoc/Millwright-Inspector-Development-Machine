#!/usr/bin/env bash
# auto.sh — auto-mode helper (1.9.0). One tested home for the on/off check,
# the audit trail every auto-answered prompt emits, the /mi-auto switch,
# automatic feature-branch creation and the stage-6 approve guard.
#
# Spec: docs/superpowers/specs/2026-09-25-auto-mode-design.md
#
# Usage:
#   auto.sh is-on                                   # exit 0 when auto-mode is on; 1 otherwise
#                                                 # (no cycle / missing field / unreadable = off)
#   auto.sh answer "<prompt>" "<answer>" [--cmd <cmd>]
#                                                 # prints `auto: <prompt> → <answer>` and appends
#                                                 # an `auto-answer` ledger row (stage = active
#                                                 # current-stage, or `-` between features).
#                                                 # A ledger failure only warns.
#   auto.sh switch on|off|status                  # /mi-auto backend
#   auto.sh create-branch <slug> <config.md>      # see case below
#   auto.sh approve-guard <feature>               # see case below

set -euo pipefail
source "$(dirname "$0")/internal/common.sh"

PROG="${MI_PLUGIN_ROOT}/scripts/progress.sh"
LEDGER="${MI_PLUGIN_ROOT}/scripts/ledger.sh"

auto_is_on() {
  local v
  v="$("$PROG" get-top auto-mode 2>/dev/null)" || return 1
  [[ "$v" == "true" ]]
}

active_feature() {
  "$PROG" get-active 2>/dev/null || echo null
}

current_stage() {
  local a
  a="$(active_feature)"
  if [[ -z "$a" || "$a" == "null" ]]; then
    echo "-"
  else
    "$PROG" get current-stage 2>/dev/null || echo "-"
  fi
}

ledger_row() {
  # ledger_row <command> <files> <artifact>
  "$LEDGER" append "$(current_stage)" "$1" "$2" small main "$3" >/dev/null 2>&1 \
    || mi_info "warning: could not append ledger row ($2: $3)"
}

cmd="${1:-}"; shift || true

case "$cmd" in
  is-on)
    auto_is_on
    ;;

  answer)
    prompt="${1:?prompt required}"; answer="${2:?answer required}"; shift 2
    caller="-"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --cmd)   [[ $# -ge 2 ]] || mi_die "answer: --cmd requires a value"; caller="$2"; shift 2 ;;
        --cmd=*) caller="${1#--cmd=}"; shift ;;
        *) mi_die "answer: unknown argument: $1" ;;
      esac
    done
    printf 'auto: %s → %s\n' "$prompt" "$answer"
    ledger_row "$caller" "auto-answer" "$prompt → $answer"
    ;;

  switch)
    mode="${1:-status}"
    [[ -f "$(mi_progress_file 2>/dev/null)" ]] \
      || mi_die "no active quest cycle — run /mi-run first (auto mode is stored per cycle)"
    case "$mode" in
      on|off)
        val=true; [[ "$mode" == "off" ]] && val=false
        "$PROG" set-top "auto-mode=$val" >/dev/null 2>&1 || mi_die "could not write auto-mode"
        a="$(active_feature)"
        if [[ -n "$a" && "$a" != "null" ]]; then
          dp=auto; [[ "$mode" == "off" ]] && dp=prompt
          "$PROG" set "diagram-prompt=$dp" >/dev/null 2>&1 || mi_info "warning: could not set diagram-prompt=$dp"
        fi
        ledger_row "/mi-auto" "auto-mode-switch" "auto-mode → $mode"
        if [[ "$mode" == "on" ]]; then
          echo "auto mode ON — remaining questions this cycle will be answered automatically"
        else
          echo "auto mode OFF — prompts restored"
        fi
        ;;
      status)
        if auto_is_on; then echo "auto mode: on"; else echo "auto mode: off"; fi
        ;;
      *) mi_die "switch: expected on|off|status, got '$mode'" ;;
    esac
    ;;

  *)
    echo "usage: auto.sh {is-on|answer|switch|create-branch|approve-guard} ..." >&2
    exit 2
    ;;
esac
