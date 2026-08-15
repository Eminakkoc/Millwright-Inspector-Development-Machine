#!/usr/bin/env bash
# deferred-tests.sh — manage <ft>/test/deferred-tests.md, the carried-forward
# manual-test scenarios a cycle's whole-feature test must still run.
#
# Writers: /mi-manual-test-run (upsert, on a `defer` verdict) and
# /mi-manual-test-plan (set-merged-as, during the feature-test render).
# Readers: /mi-manual-test-plan (merge) and /mi-continue (the completion gate).
#
# Entry identity is the composite key <originating-feature>/<originating-scenario>,
# carried in the block heading. There is no separate numbering.
#
# Self-validation: every mutating subcommand runs frontmatter.sh validate after
# the write — the PostToolUse write-hook only fires on Edit/Write tool calls, so
# a script-written artifact must validate inline.
#
# Usage:
#   deferred-tests.sh path <ft>
#   deferred-tests.sh count <ft>
#   deferred-tests.sh list <ft>
#   deferred-tests.sh upsert <ft> --feature <f> --scenario <s> --title <t>
#                               --reason <r> --action <a> --expected <e>
#                               [--deferred-at <iso8601>]
#   deferred-tests.sh set-merged-as <ft> <f> <s> <scenario-id>
#   deferred-tests.sh remove <ft> <f> <s>
#   deferred-tests.sh offer-defer <active-feature>

set -euo pipefail
source "$(dirname "$0")/internal/common.sh"

dt_file() {
  "${MI_PLUGIN_ROOT}/scripts/blueprints.sh" deferred-tests-path "${1:?feature-test name required}"
}

dt_validate() {
  "${MI_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$1" deferred-tests >/dev/null
}

# PARSING CONTRACT — every Python block below repeats these three lines:
#
#   sec  = re.search(r'(?m)^## Deferred scenarios[ \t]*$', content)
#   rest = content[sec.end():] ; nxt = re.search(r'(?m)^## ', rest)
#   sec_start, sec_end = sec.end(), sec.end() + (nxt.start() if nxt else len(rest))
#
# Scoping to that section is load-bearing, not tidiness: the template's
# entry-shape comment sits ABOVE the heading and contains a worked example with
# a `###` line. An unscoped whole-file scan counts it as a real entry, so a
# freshly rendered file reports one phantom deferral — which would block the
# feature-test entry's completion forever. The idiom is repeated inline rather
# than factored out because each block is a quoted heredoc: a shell variable
# would not expand inside it.

# Render the artifact when it does not exist yet. Idempotent.
dt_ensure() {
  local ft dest slug
  ft="$1"
  dest="$(dt_file "$ft")"
  if [[ -f "$dest" ]]; then
    printf '%s' "$dest"
    return 0
  fi
  slug="$(mi_active_quest_slug 2>/dev/null || true)"
  if [[ -z "$slug" || "$slug" == "null" ]]; then
    mi_die "deferred-tests: no active quest cycle; cannot create $dest"
  fi
  "${MI_PLUGIN_ROOT}/scripts/frontmatter.sh" init deferred-tests "$dest" \
    "FEATURE_TEST=$ft" \
    "QUEST_SLUG=$slug" \
    "CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null
  printf '%s' "$dest"
}

cmd="${1:-}"; shift || true

case "$cmd" in
  path)
    dt_file "${1:?feature-test name required}"
    ;;

  ensure)
    dt_ensure "${1:?feature-test name required}"
    ;;

  count)
    ft="${1:?feature-test name required}"
    dest="$(dt_file "$ft")"
    if [[ ! -f "$dest" ]]; then
      echo 0
      exit 0
    fi
    python3 - "$dest" <<'PYEOF'
import re, sys
with open(sys.argv[1]) as f:
    content = f.read()
sec = re.search(r'(?m)^## Deferred scenarios[ \t]*$', content)
if not sec:
    print(0)
    sys.exit(0)
rest = content[sec.end():]
nxt = re.search(r'(?m)^## ', rest)
window = rest[:nxt.start()] if nxt else rest
print(len(re.findall(r'(?m)^### [^/\s]+/[^\s]+ — ', window)))
PYEOF
    ;;

  list)
    ft="${1:?feature-test name required}"
    dest="$(dt_file "$ft")"
    if [[ ! -f "$dest" ]]; then
      exit 0
    fi
    python3 - "$dest" <<'PYEOF'
import re, sys
with open(sys.argv[1]) as f:
    content = f.read()
sec = re.search(r'(?m)^## Deferred scenarios[ \t]*$', content)
if not sec:
    sys.exit(0)
rest = content[sec.end():]
nxt = re.search(r'(?m)^## ', rest)
window = rest[:nxt.start()] if nxt else rest
HEAD = re.compile(r'(?m)^### ([^/\s]+)/([^\s]+) — (.*)$')
for m in HEAD.finditer(window):
    feature, scenario, title = m.group(1), m.group(2), m.group(3).strip()
    # Block runs to the next ### / ## heading or the end of the section.
    tail = window[m.end():]
    nb = re.search(r'(?m)^(###|##) ', tail)
    block = tail[:nb.start()] if nb else tail
    mm = re.search(r'(?m)^- \*\*Merged as:\*\*[ \t]*(.*)$', block)
    merged = mm.group(1).strip() if mm else ''
    print('\t'.join([feature, scenario, merged, title]))
PYEOF
    ;;

  upsert)
    ft="${1:?feature-test name required}"; shift
    feature=""; scenario=""; title=""; reason=""; action=""; expected=""; deferred_at=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --feature)     [[ $# -ge 2 ]] || mi_die "upsert: --feature requires a value";     feature="$2"; shift 2 ;;
        --feature=*)   feature="${1#--feature=}"; shift ;;
        --scenario)    [[ $# -ge 2 ]] || mi_die "upsert: --scenario requires a value";    scenario="$2"; shift 2 ;;
        --scenario=*)  scenario="${1#--scenario=}"; shift ;;
        --title)       [[ $# -ge 2 ]] || mi_die "upsert: --title requires a value";       title="$2"; shift 2 ;;
        --title=*)     title="${1#--title=}"; shift ;;
        --reason)      [[ $# -ge 2 ]] || mi_die "upsert: --reason requires a value";      reason="$2"; shift 2 ;;
        --reason=*)    reason="${1#--reason=}"; shift ;;
        --action)      [[ $# -ge 2 ]] || mi_die "upsert: --action requires a value";      action="$2"; shift 2 ;;
        --action=*)    action="${1#--action=}"; shift ;;
        --expected)    [[ $# -ge 2 ]] || mi_die "upsert: --expected requires a value";    expected="$2"; shift 2 ;;
        --expected=*)  expected="${1#--expected=}"; shift ;;
        --deferred-at) [[ $# -ge 2 ]] || mi_die "upsert: --deferred-at requires a value"; deferred_at="$2"; shift 2 ;;
        --deferred-at=*) deferred_at="${1#--deferred-at=}"; shift ;;
        *) mi_die "upsert: unknown argument: $1" ;;
      esac
    done
    [[ -n "$feature" ]]  || mi_die "upsert: --feature is required"
    [[ -n "$scenario" ]] || mi_die "upsert: --scenario is required"
    [[ -n "$title" ]]    || mi_die "upsert: --title is required"
    [[ -n "$reason" ]]   || mi_die "upsert: --reason is required (an entry without one is not runnable later)"
    if [[ -z "$deferred_at" ]]; then
      deferred_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fi
    dest="$(dt_ensure "$ft")"
    python3 - "$dest" "$feature" "$scenario" "$title" "$reason" "$action" "$expected" "$deferred_at" <<'PYEOF'
import re, sys
path, feature, scenario, title, reason, action, expected, deferred_at = sys.argv[1:9]

with open(path) as f:
    content = f.read()

key_head = f"### {feature}/{scenario} — "
HEAD = re.compile(r'(?m)^### [^/\s]+/[^\s]+ — .*$')

# Scope to the `## Deferred scenarios` section — see the PARSING CONTRACT note
# above the case statement. Offsets below are absolute so the splice is direct.
sec = re.search(r'(?m)^## Deferred scenarios[ \t]*$', content)
if not sec:
    sys.stderr.write(f"error: '## Deferred scenarios' heading not found in {path}\n")
    sys.exit(1)
_rest = content[sec.end():]
_nxt = re.search(r'(?m)^## ', _rest)
sec_start = sec.end()
sec_end = sec_start + (_nxt.start() if _nxt else len(_rest))
window = content[sec_start:sec_end]

# Find an existing block with this key and keep its Merged as value.
existing = None
merged_as = ''
for m in HEAD.finditer(window):
    if window[m.start():m.start() + len(key_head)] == key_head:
        abs_start = sec_start + m.start()
        tail = window[m.end():]
        nb = re.search(r'(?m)^(###|##) ', tail)
        abs_end = sec_start + m.end() + (nb.start() if nb else len(tail))
        existing = (abs_start, abs_end)
        old = content[abs_start:abs_end]
        mm = re.search(r'(?m)^- \*\*Merged as:\*\*[ \t]*(.*)$', old)
        if mm:
            merged_as = mm.group(1).strip()
        break

def scalar(text):
    """Four-space-indent a multi-line value for a YAML-ish block scalar."""
    lines = text.rstrip('\n').split('\n')
    return '\n'.join(('    ' + ln) if ln.strip() else '' for ln in lines)

block = (
    f"{key_head}{title}\n"
    f"\n"
    f"- **Originating feature:** {feature}\n"
    f"- **Originating scenario:** {scenario}\n"
    f"- **Action:** |\n{scalar(action)}\n"
    f"- **Expected:** |\n{scalar(expected)}\n"
    f"- **Reason:** {reason}\n"
    f'- **Deferred at:** "{deferred_at}"\n'
    f"- **Merged as:** {merged_as}\n"
    f"\n"
)

if existing:
    content = content[:existing[0]] + block + content[existing[1]:]
else:
    # Append at the end of the `## Deferred scenarios` section.
    content = content[:sec_end].rstrip('\n') + '\n\n' + block + content[sec_end:]

with open(path, 'w') as f:
    f.write(content)
PYEOF
    dt_validate "$dest"
    mi_info "deferred: $feature/$scenario → $(basename "$dest")"
    ;;

  set-merged-as)
    ft="${1:?feature-test name required}"
    feature="${2:?originating feature required}"
    scenario="${3:?originating scenario required}"
    merged="${4:?merged scenario id required}"
    dest="$(dt_file "$ft")"
    [[ -f "$dest" ]] || mi_die "set-merged-as: $dest not found"
    python3 - "$dest" "$feature" "$scenario" "$merged" <<'PYEOF'
import re, sys
path, feature, scenario, merged = sys.argv[1:5]
with open(path) as f:
    content = f.read()
# Scope to the `## Deferred scenarios` section — see the PARSING CONTRACT note.
sec = re.search(r'(?m)^## Deferred scenarios[ \t]*$', content)
if not sec:
    sys.stderr.write(f"error: '## Deferred scenarios' heading not found in {path}\n")
    sys.exit(3)
_rest = content[sec.end():]
_nxt = re.search(r'(?m)^## ', _rest)
sec_start = sec.end()
sec_end = sec_start + (_nxt.start() if _nxt else len(_rest))
window = content[sec_start:sec_end]
key_head = f"### {feature}/{scenario} — "
m = re.search(r'(?m)^' + re.escape(key_head) + r'.*$', window)
if not m:
    sys.stderr.write(f"error: no entry {feature}/{scenario} in {path}\n")
    sys.exit(3)
start = sec_start + m.start()
tail = window[m.end():]
nb = re.search(r'(?m)^(###|##) ', tail)
end = sec_start + m.end() + (nb.start() if nb else len(tail))
block = content[start:end]
new_block, n = re.subn(r'(?m)^- \*\*Merged as:\*\*[ \t]*.*$',
                       f'- **Merged as:** {merged}', block)
if n == 0:
    sys.stderr.write(f"error: entry {feature}/{scenario} has no 'Merged as:' line\n")
    sys.exit(3)
with open(path, 'w') as f:
    f.write(content[:start] + new_block + content[end:])
PYEOF
    dt_validate "$dest"
    ;;

  remove)
    ft="${1:?feature-test name required}"
    feature="${2:?originating feature required}"
    scenario="${3:?originating scenario required}"
    dest="$(dt_file "$ft")"
    [[ -f "$dest" ]] || mi_die "remove: $dest not found"
    python3 - "$dest" "$feature" "$scenario" <<'PYEOF'
import re, sys
path, feature, scenario = sys.argv[1:4]
with open(path) as f:
    content = f.read()
# Scope to the `## Deferred scenarios` section — see the PARSING CONTRACT note.
sec = re.search(r'(?m)^## Deferred scenarios[ \t]*$', content)
if not sec:
    sys.stderr.write(f"error: '## Deferred scenarios' heading not found in {path}\n")
    sys.exit(3)
_rest = content[sec.end():]
_nxt = re.search(r'(?m)^## ', _rest)
sec_start = sec.end()
sec_end = sec_start + (_nxt.start() if _nxt else len(_rest))
window = content[sec_start:sec_end]
key_head = f"### {feature}/{scenario} — "
m = re.search(r'(?m)^' + re.escape(key_head) + r'.*$', window)
if not m:
    sys.stderr.write(f"error: no entry {feature}/{scenario} in {path}\n")
    sys.exit(3)
start = sec_start + m.start()
tail = window[m.end():]
nb = re.search(r'(?m)^(###|##) ', tail)
end = sec_start + m.end() + (nb.start() if nb else len(tail))
with open(path, 'w') as f:
    f.write(content[:start] + content[end:])
PYEOF
    dt_validate "$dest"
    ;;

  offer-defer)
    # Exit 0 when `defer` should be offered for <active-feature>, else exit 1.
    #
    # This is a script predicate rather than a shell variable on purpose: each
    # fenced bash block in a command file is a separate invocation with no
    # shared state, and a flag defaulted to "off" at a consumption site would
    # silently disable the disposition. Any block can call this in one line.
    active="${1:?active feature name required}"
    # `| head -1 | cut -f1` resolves a value, not a guard — safe without pipefail.
    ft_status="$("${MI_PLUGIN_ROOT}/scripts/todo.sh" feature-test-status 2>/dev/null | head -1 | cut -f1 || true)"
    if [[ "$ft_status" != "ready" && "$ft_status" != "selected" ]]; then
      # `none` (no entry this cycle, e.g. a single-feature cycle) or `blocked`
      # (entry exists in frontmatter but was never enqueued, so no folder was
      # created at stage 1.5). Either way there is no destination.
      exit 1
    fi
    if "${MI_PLUGIN_ROOT}/scripts/todo.sh" is-feature-test "$active" >/dev/null 2>&1; then
      # The feature-test entry's own run. It is terminal — nothing to defer into.
      exit 1
    fi
    exit 0
    ;;

  *)
    echo "usage: deferred-tests.sh {path|ensure|count|list|upsert|set-merged-as|remove|offer-defer} ..." >&2
    exit 2
    ;;
esac
