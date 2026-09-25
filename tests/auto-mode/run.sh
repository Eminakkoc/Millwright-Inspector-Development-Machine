#!/usr/bin/env bash
# run.sh — tests for the auto-mode feature (AUTO-001..010).
#
# Each test prints PASS/FAIL; the suite exits 1 if any test failed.
# Tests are additive: later tasks append blocks under their own task headings.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$REPO_ROOT/tests/auto-mode/fixtures"

pass=0
fail=0
fail_names=()

ok()   { printf "\xe2\x9c\x93 %s\n" "$1"; pass=$((pass + 1)); }
ng()   { printf "\xe2\x9c\x97 %s\n   %s\n" "$1" "$2" >&2; fail=$((fail + 1)); fail_names+=("$1"); }

SANDBOXES=()
cleanup() {
  local s
  for s in ${SANDBOXES[@]+"${SANDBOXES[@]}"}; do
    [[ -n "$s" && -d "$s" ]] && rm -rf "$s"
  done
}
trap cleanup EXIT

P="$REPO_ROOT/scripts/progress.sh"
FM="$REPO_ROOT/scripts/frontmatter.sh"
UUID1="11111111-1111-4111-8111-111111111111"

# make_sandbox [--auto] — a git repo whose data root holds one quest cycle with
# progress.md (queue: alpha beta, active null). cd's nowhere; callers run
# commands with (cd "$sb" && MI_DATA_ROOT="$sb/millwright-inspector" ...).
make_sandbox() {
  local sb dr slug
  sb="$(mktemp -d)"
  SANDBOXES+=("$sb")
  dr="$sb/millwright-inspector"
  slug="2026-09-25-demo"
  mkdir -p "$dr/quest/$slug"
  cat > "$dr/quest/active.md" <<EOF
---
slug: $slug
started: "2026-09-25"
journal-folders: [demo]
status: active
---

# Active quest pointer
EOF
  (cd "$sb" && git init -q -b main && git config user.email t@t && git config user.name t \
     && echo seed > README.md && git add README.md && git commit -qm seed)
  (cd "$sb" && MI_DATA_ROOT="$dr" "$P" init ${1:-} "$UUID1" alpha beta >/dev/null 2>&1)
  printf '%s' "$sb"
}

# run_in <sandbox> <cmd...> — run with cwd + data root set.
run_in() { local sb="$1"; shift; (cd "$sb" && MI_DATA_ROOT="$sb/millwright-inspector" "$@"); }

# assert_prompt_kept <site> <file>: fixture prompts-off/<site>.txt appears verbatim in <file>.
assert_prompt_kept() {
  local site="$1" file="$2"
  if python3 - "$FIX/prompts-off/$site.txt" "$REPO_ROOT/$file" <<'PYEOF'; then
import sys
fx = open(sys.argv[1]).read().rstrip('\n')
body = open(sys.argv[2]).read()
sys.exit(0 if fx and fx in body else 1)
PYEOF
    ok "off: $site prompt kept verbatim in $file"
  else
    ng "off: $site prompt kept verbatim in $file" "fixture text not found (or fixture empty)"
  fi
}

# assert_auto_before <site> <file> <needle>...: the 1500 chars before the fixture
# block contain '**Auto mode.**', 'auto.sh is-on' and every needle.
assert_auto_before() {
  local site="$1" file="$2"; shift 2
  if python3 - "$FIX/prompts-off/$site.txt" "$REPO_ROOT/$file" "$@" <<'PYEOF'; then
import sys
fx = open(sys.argv[1]).read().rstrip('\n')
body = open(sys.argv[2]).read()
i = body.find(fx)
if i < 0: sys.exit(1)
before = body[max(0, i - 1500):i]
needles = ['**Auto mode.**', 'auto.sh is-on'] + sys.argv[3:]
sys.exit(0 if all(n in before for n in needles) else 1)
PYEOF
    ok "on: $site auto paragraph precedes prompt in $file"
  else
    ng "on: $site auto paragraph precedes prompt in $file" "missing auto paragraph or needle: $*"
  fi
}

# assert_contains <name> <file> <literal>
assert_contains() {
  if grep -qF -- "$3" "$REPO_ROOT/$2"; then ok "$1"; else ng "$1" "'$3' not in $2"; fi
}

# ---- Task 1: state -----------------------------------------------------------

t="get-top works with active null and reads missing auto-mode as null"
sb="$(make_sandbox)"
got="$(run_in "$sb" "$P" get-top auto-mode 2>&1)"
[[ "$got" == "null" ]] && ok "$t" || ng "$t" "got: $got"

t="init --auto sets auto-mode true"
sb="$(make_sandbox --auto)"
got="$(run_in "$sb" "$P" get-top auto-mode 2>&1)"
[[ "$got" == "true" ]] && ok "$t" || ng "$t" "got: $got"

t="set-top writes auto-mode with active null"
sb="$(make_sandbox)"
run_in "$sb" "$P" set-top auto-mode=true >/dev/null 2>&1
got="$(run_in "$sb" "$P" get-top auto-mode 2>&1)"
[[ "$got" == "true" ]] && ok "$t" || ng "$t" "got: $got"

for f in active queue completed id todo-list-id; do
  t="set-top refuses protected field $f"
  sb="$(make_sandbox)"
  pf="$sb/millwright-inspector/quest/2026-09-25-demo/progress.md"
  before="$(cat "$pf")"
  if run_in "$sb" "$P" set-top "$f=x" >/dev/null 2>&1; then
    ng "$t" "exit 0"
  elif [[ "$(cat "$pf")" != "$before" ]]; then
    ng "$t" "file changed"
  else
    ok "$t"
  fi
done

t="schema rejects non-boolean auto-mode (set-top leaves file untouched)"
sb="$(make_sandbox)"
pf="$sb/millwright-inspector/quest/2026-09-25-demo/progress.md"
before="$(cat "$pf")"
if run_in "$sb" "$P" set-top auto-mode=maybe >/dev/null 2>&1; then
  ng "$t" "exit 0"
else
  [[ "$(cat "$pf")" == "$before" ]] && ok "$t" || ng "$t" "file changed"
fi

t="legacy progress.md without new fields validates"
sb="$(make_sandbox)"
pf="$sb/millwright-inspector/quest/2026-09-25-demo/progress.md"
if run_in "$sb" "$FM" validate "$pf" progress >/dev/null 2>&1; then ok "$t"; else ng "$t" "validate failed"; fi

t="activate seeds diagram-prompt=auto when auto-mode is true"
sb="$(make_sandbox --auto)"
run_in "$sb" "$P" activate >/dev/null 2>&1
got="$(run_in "$sb" "$P" get diagram-prompt 2>&1)"
[[ "$got" == "auto" ]] && ok "$t" || ng "$t" "got: $got"

t="activate keeps diagram-prompt=prompt when auto-mode is off"
sb="$(make_sandbox)"
run_in "$sb" "$P" activate >/dev/null 2>&1
got="$(run_in "$sb" "$P" get diagram-prompt 2>&1)"
[[ "$got" == "prompt" ]] && ok "$t" || ng "$t" "got: $got"

t="set accepts chain-finished and review-stop-shown booleans"
sb="$(make_sandbox)"
run_in "$sb" "$P" activate >/dev/null 2>&1
if run_in "$sb" "$P" set chain-finished=true review-stop-shown=true >/dev/null 2>&1; then ok "$t"; else ng "$t" "set failed"; fi

t="reset clears chain-finished and review-stop-shown"
run_in "$sb" "$P" reset >/dev/null 2>&1
got="$(run_in "$sb" "$P" get chain-finished 2>&1)|$(run_in "$sb" "$P" get review-stop-shown 2>&1)"
[[ "$got" == "null|null" ]] && ok "$t" || ng "$t" "got: $got"

t="finish appends branch to completed-branches (deduped, null skipped)"
sb="$(make_sandbox)"
run_in "$sb" "$P" activate >/dev/null 2>&1
run_in "$sb" "$P" set branch=feat/alpha >/dev/null 2>&1
run_in "$sb" "$P" finish >/dev/null 2>&1
run_in "$sb" "$P" activate >/dev/null 2>&1
run_in "$sb" "$P" finish >/dev/null 2>&1          # beta: branch null → skipped
got="$(run_in "$sb" "$P" get-top 'completed-branches[]' 2>&1 | tr '\n' ',')"
[[ "$got" == "feat/alpha," ]] && ok "$t" || ng "$t" "got: $got"

# ---- Task 2: auto.sh is-on/answer/switch -----------------------------------------

A="$REPO_ROOT/scripts/auto.sh"

t="auto.sh is-on exits 1 with no quest cycle"
empty="$(mktemp -d)"; SANDBOXES+=("$empty")
if (cd "$empty" && MI_DATA_ROOT="$empty/none" "$A" is-on >/dev/null 2>&1); then ng "$t" "exit 0"; else ok "$t"; fi

t="auto.sh is-on exits 1 when field missing, 0 when true"
sb="$(make_sandbox)"
if run_in "$sb" "$A" is-on >/dev/null 2>&1; then ng "$t" "missing → on"; else
  run_in "$sb" "$P" set-top auto-mode=true >/dev/null 2>&1
  if run_in "$sb" "$A" is-on >/dev/null 2>&1; then ok "$t"; else ng "$t" "true → off"; fi
fi

t="auto.sh answer prints the audit line and a ledger row with stage '-' between features"
sb="$(make_sandbox --auto)"
out="$(run_in "$sb" "$A" answer "queue order" "accept" --cmd /mi-continue 2>/dev/null)"
ledger="$sb/millwright-inspector/quest/2026-09-25-demo/context-ledger.md"
if [[ "$out" == "auto: queue order → accept" ]] \
   && grep -qF '| - | /mi-continue | auto-answer | small | main | queue order → accept |' "$ledger"; then
  ok "$t"
else
  ng "$t" "out=$out; ledger row missing"
fi

t="auto.sh answer uses active current-stage"
run_in "$sb" "$P" activate >/dev/null 2>&1
run_in "$sb" "$A" answer "planning mode" "brainstorming" --cmd /mi-plan-implementation >/dev/null 2>&1
grep -qF '| 2 | /mi-plan-implementation | auto-answer | small | main | planning mode → brainstorming |' "$ledger" \
  && ok "$t" || ng "$t" "row missing"

t="auto.sh switch refuses without a quest cycle"
if (cd "$empty" && MI_DATA_ROOT="$empty/none" "$A" switch on >/dev/null 2>&1); then ng "$t" "exit 0"; else ok "$t"; fi

t="auto.sh switch on between features sets flag, prints ON line, logs switch row"
sb="$(make_sandbox)"
out="$(run_in "$sb" "$A" switch on 2>/dev/null)"
ledger="$sb/millwright-inspector/quest/2026-09-25-demo/context-ledger.md"
if [[ "$out" == "auto mode ON — remaining questions this cycle will be answered automatically" ]] \
   && [[ "$(run_in "$sb" "$P" get-top auto-mode 2>/dev/null)" == "true" ]] \
   && grep -qF '| - | /mi-auto | auto-mode-switch | small | main | auto-mode → on |' "$ledger"; then
  ok "$t"
else
  ng "$t" "out=$out"
fi

t="auto.sh switch on/off toggles diagram-prompt on the active feature"
sb="$(make_sandbox)"
run_in "$sb" "$P" activate >/dev/null 2>&1
run_in "$sb" "$A" switch on >/dev/null 2>&1
a="$(run_in "$sb" "$P" get diagram-prompt 2>/dev/null)"
run_in "$sb" "$A" switch off >/dev/null 2>&1
b="$(run_in "$sb" "$P" get diagram-prompt 2>/dev/null)"
[[ "$a|$b" == "auto|prompt" ]] && ok "$t" || ng "$t" "got $a|$b"

t="auto.sh switch status prints current state"
out="$(run_in "$sb" "$A" switch status 2>/dev/null)"
[[ "$out" == "auto mode: off" ]] && ok "$t" || ng "$t" "got $out"

t="/mi-auto command exists and wraps auto.sh switch"
assert_contains "$t" commands/mi-auto.md 'auto.sh" switch'

# ---- end of tests --------------------------------------------------------------
echo
echo "auto-mode: $pass passed, $fail failed"
if (( fail > 0 )); then printf '  - %s\n' "${fail_names[@]}" >&2; exit 1; fi
