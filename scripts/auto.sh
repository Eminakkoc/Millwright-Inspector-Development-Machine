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
#   auto.sh create-branch <slug> <config.md>      # dirty tracked tree (data root excluded) →
#                                                 # exit 3; else creates feat/<slug> (or -2, -3,
#                                                 # ...), switches to it, rewrites config.md's
#                                                 # ## GIT BRANCH section to one bare branch
#                                                 # line, prints the created-branch line, and
#                                                 # logs an auto-answer ledger row.
#   auto.sh approve-guard <feature>               # exit 0 when every ### IR-NNN block is
#                                                 # scope fix/re-implement + status fixed and
#                                                 # no deferred question is still open;
#                                                 # else exit 1 and list the offenders needing
#                                                 # your look (or "inspector-review.md missing").

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

  create-branch)
    slug="${1:?slug required}"; config="${2:?config.md path required}"
    [[ -f "$config" ]] || mi_die "create-branch: config not found: $config"
    grep -qE '^## GIT BRANCH[[:space:]]*$' "$config" \
      || mi_die "create-branch: no '## GIT BRANCH' heading in config.md"
    top="$(git rev-parse --show-toplevel)"
    # Exclude the data root when it lives inside the work tree: stage 2 has
    # just written blueprints/current/* there, and those must not count.
    rel="$(python3 -c 'import os,sys; r=os.path.relpath(os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])); print("" if r.startswith("..") else r)' "$(mi_data_root)" "$top")"
    if [[ -n "$rel" && "$rel" != "." ]]; then
      dirty="$(git -C "$top" status --porcelain --untracked-files=no -- . ":(exclude)$rel")"
    else
      dirty="$(git -C "$top" status --porcelain --untracked-files=no)"
    fi
    if [[ -n "$dirty" ]]; then
      echo "auto: uncommitted changes — commit or stash, then /mi-continue"
      exit 3
    fi
    base="$(git rev-parse --abbrev-ref HEAD)"
    [[ "$base" == "HEAD" ]] && base="$(git rev-parse --short HEAD)"
    name="feat/$slug"; n=2
    while git show-ref --verify --quiet "refs/heads/$name"; do
      name="feat/$slug-$n"; n=$((n + 1))
    done
    git switch -q -c "$name"
    python3 - "$config" "$name" <<'PYEOF'
import sys, re
path, name = sys.argv[1], sys.argv[2]
s = open(path).read()
m = re.search(r'(?m)^## GIT BRANCH[ \t]*\n', s)
if not m:
    sys.stderr.write("error: create-branch: no '## GIT BRANCH' heading in config.md\n"); sys.exit(1)
start = m.end()
nxt = re.search(r'(?m)^## ', s[start:])
end = start + (nxt.start() if nxt else len(s) - start)
body = s[start:end]
# Keep HTML comments only; drop every other non-blank line (old candidates).
comments = re.findall(r'<!--.*?-->', body, re.DOTALL)
new_body = '\n' + ''.join(c + '\n\n' for c in comments) + name + '\n\n'
open(path, 'w').write(s[:start] + new_body + s[end:])
PYEOF
    echo "auto: created branch $name from $base"
    ledger_row "/mi-plan-implementation" "auto-answer" "feature branch → $name (from $base)"
    ;;

  approve-guard)
    feature="${1:?feature required}"
    rf="$(mi_impl_dir "$feature")/inspector-review.md"
    if [[ ! -f "$rf" ]]; then
      echo "auto: review needs your look — inspector-review.md missing"
      exit 1
    fi
    # Open deferred questions also need the inspector: the stage-6 approve
    # must never close a feature while one is still unanswered.
    open_dq="$("${MI_PLUGIN_ROOT}/scripts/deferred-questions.sh" list-open "$feature" | cut -f1)"
    python3 - "$rf" "$open_dq" <<'PYEOF'
import re, sys
content = open(sys.argv[1]).read()
open_dq = [d for d in sys.argv[2].split('\n') if d]
bad = []
for m in re.finditer(r'(?ms)^### (IR-\d{3}) —.*?(?=^### |^## |\Z)', content):
    block = m.group(0)
    scope = re.search(r'(?m)^- scope:\s*(\S+)', block)
    status = re.search(r'(?m)^- status:\s*(\S+)', block)
    if not scope or not status:
        bad.append(f"{m.group(1)} (unreadable)"); continue
    sc, st = scope.group(1), status.group(1)
    if st == 'open':
        bad.append(f"{m.group(1)} (open)")
    elif st == 'wontfix':
        bad.append(f"{m.group(1)} (wontfix)")
    elif sc not in ('fix', 're-implement'):
        bad.append(f"{m.group(1)} ({sc})")
    elif st != 'fixed':
        bad.append(f"{m.group(1)} (unreadable)")
bad += [f"{d} (open question)" for d in open_dq]
if bad:
    print("auto: review needs your look — " + ", ".join(bad))
    sys.exit(1)
PYEOF
    ;;

  *)
    echo "usage: auto.sh {is-on|answer|switch|create-branch|approve-guard} ..." >&2
    exit 2
    ;;
esac
