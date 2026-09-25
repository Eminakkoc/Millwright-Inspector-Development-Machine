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

# ---- Task 3: create-branch / approve-guard -------------------------------------

# cfg_file <sb> — write a config.md with an empty GIT BRANCH section; print path.
cfg_file() {
  local c="$1/millwright-inspector/workflow-stream/alpha/blueprints/current/config.md"
  mkdir -p "$(dirname "$c")"
  cat > "$c" <<'EOF'
# Config

## GIT BRANCH

<!-- one bare line -->

## Lessons learned
- path: (none yet)
EOF
  printf '%s' "$c"
}

t="create-branch ignores untracked + data-root changes, creates feat/<slug>, writes config"
sb="$(make_sandbox --auto)"
cfg="$(cfg_file "$sb")"
echo junk > "$sb/untracked.txt"
out="$(run_in "$sb" "$A" create-branch alpha "$cfg" 2>/dev/null)"; rc=$?
head_now="$(cd "$sb" && git rev-parse --abbrev-ref HEAD)"
section="$(awk '/^## GIT BRANCH/{f=1;next} /^## /{f=0} f' "$cfg" | grep -v '^[[:space:]]*$' | grep -v '^<!--')"
if [[ $rc -eq 0 && "$head_now" == "feat/alpha" && "$section" == "feat/alpha" \
      && "$out" == "auto: created branch feat/alpha from main" ]]; then
  ok "$t"
else
  ng "$t" "rc=$rc head=$head_now section=[$section] out=$out"
fi

t="create-branch appends -2 when feat/<slug> exists"
sb="$(make_sandbox --auto)"
cfg="$(cfg_file "$sb")"
(cd "$sb" && git branch feat/alpha)
run_in "$sb" "$A" create-branch alpha "$cfg" >/dev/null 2>&1
[[ "$(cd "$sb" && git rev-parse --abbrev-ref HEAD)" == "feat/alpha-2" ]] && ok "$t" || ng "$t" "not on feat/alpha-2"

t="create-branch replaces an existing candidate line in config"
sb="$(make_sandbox --auto)"
cfg="$(cfg_file "$sb")"
python3 - "$cfg" <<'PYEOF'
import sys; p=sys.argv[1]; s=open(p).read()
open(p,'w').write(s.replace('<!-- one bare line -->\n', '<!-- one bare line -->\nfeat/old\n'))
PYEOF
run_in "$sb" "$A" create-branch alpha "$cfg" >/dev/null 2>&1
section="$(awk '/^## GIT BRANCH/{f=1;next} /^## /{f=0} f' "$cfg" | grep -v '^[[:space:]]*$' | grep -v '^<!--')"
[[ "$section" == "feat/alpha" ]] && ok "$t" || ng "$t" "section=[$section]"

t="create-branch exits 3 on a dirty tracked file and does not switch"
sb="$(make_sandbox --auto)"
cfg="$(cfg_file "$sb")"
echo changed >> "$sb/README.md"
out="$(run_in "$sb" "$A" create-branch alpha "$cfg" 2>/dev/null)"; rc=$?
if [[ $rc -eq 3 && "$out" == "auto: uncommitted changes — commit or stash, then /mi-continue" \
      && "$(cd "$sb" && git rev-parse --abbrev-ref HEAD)" == "main" ]]; then
  ok "$t"
else
  ng "$t" "rc=$rc out=$out"
fi

t="create-branch succeeds when a tracked data-root file is dirty (data root excluded)"
sb="$(make_sandbox --auto)"
cfg="$(cfg_file "$sb")"
(cd "$sb" && git add -f millwright-inspector/workflow-stream/alpha/blueprints/current/config.md \
   && git commit -qm "track config")
echo more >> "$cfg"
out="$(run_in "$sb" "$A" create-branch alpha "$cfg" 2>/dev/null)"; rc=$?
if [[ $rc -eq 0 && "$(cd "$sb" && git rev-parse --abbrev-ref HEAD)" == "feat/alpha" \
      && "$out" == "auto: created branch feat/alpha from main" ]]; then
  ok "$t"
else
  ng "$t" "rc=$rc out=$out"
fi

# review_file <sb> <blocks...>: each block "IR-001|fix|fixed"; "IR-009|-|-" = no scope/status lines.
review_file() {
  local sb="$1"; shift
  local f="$sb/millwright-inspector/workflow-stream/alpha/implementation/inspector-review.md"
  mkdir -p "$(dirname "$f")"
  { printf -- '---\nfeature: alpha\n---\n\n## Implementation Review\n\n'
    local b id sc st
    for b in "$@"; do
      IFS='|' read -r id sc st <<< "$b"
      printf '### %s — thing\n- severity: major\n' "$id"
      [[ "$sc" != "-" ]] && printf -- '- scope: %s\n' "$sc"
      [[ "$st" != "-" ]] && printf -- '- status: %s\n' "$st"
      printf -- '- details: |\n    x\n\n'
    done
  } > "$f"
}

t="approve-guard passes when every finding is fix/re-implement and fixed"
sb="$(make_sandbox)"
review_file "$sb" "IR-001|fix|fixed" "IR-002|re-implement|fixed"
out="$(run_in "$sb" "$A" approve-guard alpha 2>/dev/null)"; rc=$?
[[ $rc -eq 0 && -z "$out" ]] && ok "$t" || ng "$t" "rc=$rc out=$out"

t="approve-guard stops and names re-spec, re-plan, wontfix, open, unreadable"
review_file "$sb" "IR-001|fix|fixed" "IR-002|re-spec|fixed" "IR-003|re-plan|fixed" \
  "IR-004|fix|wontfix" "IR-005|fix|open" "IR-006|-|-"
out="$(run_in "$sb" "$A" approve-guard alpha 2>/dev/null)"; rc=$?
want="auto: review needs your look — IR-002 (re-spec), IR-003 (re-plan), IR-004 (wontfix), IR-005 (open), IR-006 (unreadable)"
[[ $rc -eq 1 && "$out" == "$want" ]] && ok "$t" || ng "$t" "rc=$rc out=$out"

t="approve-guard stops when inspector-review.md is missing"
sb="$(make_sandbox)"
out="$(run_in "$sb" "$A" approve-guard alpha 2>/dev/null)"; rc=$?
[[ $rc -eq 1 && "$out" == "auto: review needs your look — inspector-review.md missing" ]] && ok "$t" || ng "$t" "rc=$rc out=$out"

# ---- Task 4: deferred questions -----------------------------------------------

DQ="$REPO_ROOT/scripts/deferred-questions.sh"

t="deferred-questions init renders a valid file with no phantom entries"
sb="$(make_sandbox)"
f="$(run_in "$sb" "$DQ" init alpha 2>/dev/null)"
if [[ -f "$f" ]] && run_in "$sb" "$FM" validate "$f" deferred-questions >/dev/null 2>&1 \
   && [[ -z "$(run_in "$sb" "$DQ" list-open alpha 2>/dev/null)" ]]; then
  ok "$t"
else
  ng "$t" "file=$f"
fi

t="deferred-questions add/list-open/answer/list-needs-finding/set-follow-up round-trip"
id1="$(run_in "$sb" "$DQ" add alpha "Which cache TTL?" "assumed 60s" 2>/dev/null)"
id2="$(run_in "$sb" "$DQ" add alpha $'Multi\nline?' "assumed no" 2>/dev/null)"
open1="$(run_in "$sb" "$DQ" list-open alpha 2>/dev/null)"
run_in "$sb" "$DQ" answer alpha "$id1" "use 300s" --needs-finding >/dev/null 2>&1
open2="$(run_in "$sb" "$DQ" list-open alpha 2>/dev/null)"
nf1="$(run_in "$sb" "$DQ" list-needs-finding alpha 2>/dev/null)"
run_in "$sb" "$DQ" set-follow-up alpha "$id1" IR-007 >/dev/null 2>&1
nf2="$(run_in "$sb" "$DQ" list-needs-finding alpha 2>/dev/null)"
if [[ "$id1" == "DQ-001" && "$id2" == "DQ-002" \
      && "$open1" == $'DQ-001\tWhich cache TTL?\nDQ-002\tMulti line?' \
      && "$open2" == $'DQ-002\tMulti line?' \
      && "$nf1" == $'DQ-001\tWhich cache TTL?\tuse 300s' \
      && -z "$nf2" ]]; then
  ok "$t"
else
  ng "$t" "id1=$id1 id2=$id2 open1=[$open1] open2=[$open2] nf1=[$nf1] nf2=[$nf2]"
fi

t="deferred-questions list-open with no file prints nothing and exits 0"
sb="$(make_sandbox)"
out="$(run_in "$sb" "$DQ" list-open alpha 2>/dev/null)"; rc=$?
[[ $rc -eq 0 && -z "$out" ]] && ok "$t" || ng "$t" "rc=$rc out=$out"

t="deferred-questions path prints exactly one line with no trailing blank line"
sb="$(make_sandbox)"
outfile="$(mktemp)"; expectfile="$(mktemp)"
run_in "$sb" "$DQ" path alpha >"$outfile" 2>/dev/null
printf '%s\n' "$sb/millwright-inspector/workflow-stream/alpha/implementation/deferred-questions.md" >"$expectfile"
lines="$(wc -l < "$outfile" | tr -d ' ')"
if [[ "$lines" == "1" ]] && diff -q "$outfile" "$expectfile" >/dev/null 2>&1; then
  ok "$t"
else
  ng "$t" "lines=$lines content=[$(cat "$outfile")]"
fi
rm -f "$outfile" "$expectfile"

# ---- Task 6: stage 1.5–2 sites -------------------------------------------------
assert_prompt_kept queue-order commands/mi-continue.md
assert_auto_before queue-order commands/mi-continue.md '"queue order" "accept"'
assert_prompt_kept draw-skipped commands/mi-draw-diagrams.md
assert_auto_before draw-skipped commands/mi-draw-diagrams.md '"generate skipped diagrams" "y"'
assert_contains "item 7 Stop gains the auto-mode exception" commands/mi-continue.md \
  'Do NOT auto-fire Step 2B from here — unless auto mode is on (`auto.sh is-on`), in which case continue straight into Step 2B without re-prompting (item 5 above already recorded'
assert_contains "mi-run parses --auto" commands/mi-run.md '--auto'
assert_contains "mi-run passes --auto to progress.sh init" commands/mi-run.md 'progress.sh" init --auto'
assert_contains "mi-apply-impact logs the blueprint-diagrams auto answer" commands/mi-apply-impact.md \
  'auto.sh" answer "blueprint diagrams" "auto" --cmd /mi-apply-impact'
assert_contains "Step B skips pre-fill for completed branches" docs/blueprint-regeneration.md \
  "completed-branches[]"

# ---- Task 7: stage 3 -----------------------------------------------------------
assert_prompt_kept branch-empty commands/mi-plan-implementation.md
assert_auto_before branch-empty commands/mi-plan-implementation.md 'auto.sh" create-branch' 'exit 3'
assert_prompt_kept planning-mode commands/mi-plan-implementation.md
assert_auto_before planning-mode commands/mi-plan-implementation.md '"planning mode" "brainstorming"'
assert_prompt_kept primer-4a commands/mi-plan-implementation.md

RULES=templates/auto-mode-chain-rules.md
for needle in 'deferred-questions.sh" add' 'Do not create a git worktree' \
  'one item per reply' 'auto: open point <X> unresolved — answer, then /mi-continue' \
  'option 3' 'progress.sh" set chain-finished=true' '/mi-continue'; do
  assert_contains "chain rules mention: $needle" "$RULES" "$needle"
done

t="chain rules are referenced, never inlined, by /mi-implement and the 4a primer"
ref='$CLAUDE_PLUGIN_ROOT/templates/auto-mode-chain-rules.md'
marker='one item per reply'
if grep -qF "$ref" "$REPO_ROOT/commands/mi-implement.md" \
   && grep -qF "$ref" "$REPO_ROOT/commands/mi-plan-implementation.md" \
   && ! grep -qF "$marker" "$REPO_ROOT/commands/mi-implement.md" \
   && ! grep -qF "$marker" "$REPO_ROOT/commands/mi-plan-implementation.md"; then
  ok "$t"
else
  ng "$t" "reference missing or rules text inlined"
fi

assert_contains "/mi-implement counts as design approval" commands/mi-implement.md 'counts as design approval'
assert_contains "/mi-implement: plan without inspector review" commands/mi-implement.md 'without waiting for an inspector review'

# ---- Task 8: Resume Handler ------------------------------------------------------
MC=commands/mi-continue.md
assert_prompt_kept chain-complete $MC
assert_auto_before chain-complete $MC 'chain-finished' '"chain completion" "completed"'
assert_prompt_kept drift $MC
assert_auto_before drift $MC '"drift check" "auto"'
assert_prompt_kept manual-test-offer $MC
assert_auto_before manual-test-offer $MC '"manual test plan" "y"'
assert_prompt_kept manual-test-offer-skipped $MC
assert_auto_before manual-test-offer-skipped $MC '"manual test plan" "y"'
assert_contains "Resume Step 2 records subagent-driven in auto mode" $MC \
  'auto.sh" answer "execution mode" "subagent-driven" --cmd /mi-continue'
assert_contains "Resume Step 6 converts needs-finding deferred questions" $MC \
  'deferred-questions.sh" list-needs-finding'

t="Resume Step 6 DQ conversion snippet is idempotent (behaviour)"
sb="$(make_sandbox)"
run_in "$sb" "$DQ" add alpha "TTL?" "60s" >/dev/null 2>&1
run_in "$sb" "$DQ" answer alpha DQ-001 "300s" --needs-finding >/dev/null 2>&1
rf="$sb/millwright-inspector/workflow-stream/alpha/implementation/inspector-review.md"
printf -- '---\nfeature: alpha\n---\n\n## Implementation Review\n\n' > "$rf"
snippet="$(python3 - "$REPO_ROOT/$MC" <<'PYEOF'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'```bash\n(# Deferred questions → findings.*?)```', s, re.S)
print(m.group(1) if m else '')
PYEOF
)"
if [[ -z "$snippet" ]]; then
  ng "$t" "snippet starting '# Deferred questions → findings' not found"
else
  for _ in 1 2; do
    run_in "$sb" env CLAUDE_PLUGIN_ROOT="$REPO_ROOT" active_feature=alpha bash -c "$snippet" >/dev/null 2>&1
  done
  n="$(grep -c '^### IR-' "$rf")"
  fu="$(grep -E '^- follow-up:' "$sb/millwright-inspector/workflow-stream/alpha/implementation/deferred-questions.md")"
  [[ "$n" == "1" && "$fu" == "- follow-up: IR-001" ]] && ok "$t" || ng "$t" "n=$n fu=$fu"
fi

# ---- Task 9: manual tests + review stop -------------------------------------------
assert_prompt_kept mt-run-offer commands/mi-manual-test-plan.md
assert_auto_before mt-run-offer commands/mi-manual-test-plan.md '"run manual test" "y-autonomous"'
assert_prompt_kept mt-seed commands/mi-manual-test-run.md
assert_auto_before mt-seed commands/mi-manual-test-run.md '"auto-seed failures" "y"'
assert_prompt_kept mt-closed-ir commands/mi-manual-test-run.md
assert_auto_before mt-closed-ir commands/mi-manual-test-run.md '"seed <IR-NNN>" "a"' 'reopen the IR'
assert_prompt_kept mt-orphan commands/mi-manual-test-run.md
assert_auto_before mt-orphan commands/mi-manual-test-run.md '"seed <scenario id>" "a"' 'seed into the existing regression family'
assert_prompt_kept mt-guided-rerun commands/mi-manual-test-run.md
assert_auto_before mt-guided-rerun commands/mi-manual-test-run.md '"guided re-run" "n"'
assert_prompt_kept mt-handoff commands/mi-manual-test-run.md
assert_auto_before mt-handoff commands/mi-manual-test-run.md \
  'auto: review stop — check commits <base>..HEAD, diagrams and test results; add findings to inspector-review.md or leave it empty, then /mi-continue' \
  'review-stop-shown=true'
assert_contains "Inspector Handler fires the review stop once" $MC 'progress.sh" get review-stop-shown'
assert_contains "Inspector Handler review stop line" $MC \
  'auto: review stop — check commits <base>..HEAD, diagrams and test results; add findings to inspector-review.md or leave it empty, then /mi-continue'
assert_prompt_kept inspector-3a $MC
assert_auto_before inspector-3a $MC 'deferred-questions.sh" list-open' '"no findings, complete" "y"'

# ---- Task 10: review + approval ----------------------------------------------------
MR=commands/mi-review.md
assert_prompt_kept review-mode $MR
assert_auto_before review-mode $MR '"review mode" "direct"'
assert_prompt_kept review-3a-approve $MR
assert_auto_before review-3a-approve $MR 'auto.sh" approve-guard' '"review approve" "approve"'
assert_prompt_kept review-3b-approve $MR
assert_auto_before review-3b-approve $MR 'auto.sh" approve-guard' '"review approve" "approve"'
assert_contains "direct-mode caveat becomes a warning in auto mode" $MR \
  'auto: warning — <IR-NNN> is <scope>; direct mode may skip the design/plan gates it needs'
assert_contains "mi-review header allows the guarded auto hand-off" $MR \
  'unless auto mode is on and `auto.sh approve-guard` passes'
assert_prompt_kept rr-confirm $MC
assert_auto_before rr-confirm $MC '"all findings resolved, complete" "y"'
assert_prompt_kept rr-stale $MC
assert_auto_before rr-stale $MC '"refresh diagrams" "y"'
assert_prompt_kept rr-skipped $MC
assert_auto_before rr-skipped $MC '"generate skipped diagrams" "y"'
assert_contains "Inspector Step 3b rule loosened" $MC \
  'Do not auto-fire `/mi-complete-workflow` — unless auto mode is on and `auto.sh approve-guard` passes'

# ---- Task 11: clear gates + stacked note ----------------------------------------------
assert_prompt_kept gate-2-3 $MC
assert_auto_before gate-2-3 $MC 'auto: clear gate stage-2-to-3 — type /clear, then /mi-continue'
assert_prompt_kept gate-5-6 $MR
assert_auto_before gate-5-6 $MR 'auto: clear gate stage-5-to-6 — type /clear, then /mi-continue'
assert_prompt_kept gate-8-2 commands/mi-complete-workflow.md
assert_auto_before gate-8-2 commands/mi-complete-workflow.md 'auto: clear gate stage-8-to-2 — type /clear, then /mi-continue'

t="stacked-branch note prints only for an unmerged previous branch under this base"
snippet="$(python3 - "$REPO_ROOT/commands/mi-complete-workflow.md" <<'PYEOF'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'```bash\n(?:(?!```).)*?(# Stacked-branch note.*?)```', s, re.S)
print(m.group(1) if m else '')
PYEOF
)"
if [[ -z "$snippet" ]]; then
  ng "$t" "snippet '# Stacked-branch note' not found"
else
  sb="$(make_sandbox)"
  (cd "$sb" && git switch -qc feat/alpha && echo a > a && git add a && git commit -qm a \
     && git switch -qc feat/beta && echo b > b && git add b && git commit -qm b)
  base_b="$(cd "$sb" && git rev-parse feat/alpha)"
  run_in "$sb" "$P" set-top 'completed-branches=["feat/alpha","feat/beta"]' >/dev/null 2>&1
  out1="$(run_in "$sb" env CLAUDE_PLUGIN_ROOT="$REPO_ROOT" finished_branch=feat/beta finished_base="$base_b" bash -c "$snippet" 2>/dev/null)"
  (cd "$sb" && git switch -q main && git merge -q --ff-only feat/alpha)
  out2="$(run_in "$sb" env CLAUDE_PLUGIN_ROOT="$REPO_ROOT" finished_branch=feat/beta finished_base="$base_b" bash -c "$snippet" 2>/dev/null)"
  if [[ "$out1" == "stacked: feat/beta is based on feat/alpha (unmerged)" && -z "$out2" ]]; then
    ok "$t"
  else
    ng "$t" "out1=[$out1] out2=[$out2]"
  fi
fi

t="stacked note shares one continuous bash fence with the finished_branch/finished_base capture and the finish call (no re-query after finish)"
check="$(python3 - "$REPO_ROOT/commands/mi-complete-workflow.md" <<'PYEOF'
import re, sys
s = open(sys.argv[1]).read()
result = "missing"
for fence in re.findall(r'```bash\n(.*?)```', s, re.S):
    if '# Stacked-branch note' in fence:
        before = fence[:fence.index('# Stacked-branch note')]
        needles = ['finished_branch=', 'finished_base=', 'progress.sh finish']
        result = "yes" if all(n in before for n in needles) else "no"
        break
print(result)
PYEOF
)"
[[ "$check" == "yes" ]] && ok "$t" || ng "$t" "check=$check"

# ---- Task 12: never-auto audit --------------------------------------------------------
t="never-auto rules match the audited list"
cur="$(cd "$REPO_ROOT" && grep -rniE 'never auto|do not auto|Do NOT auto-fire|Wait for the' commands docs \
       | grep -v '^docs/superpowers/' | sed -E 's/:[0-9]+:/:/' | sort)"
if [[ "$cur" == "$(cat "$FIX/never-auto-expected.txt")" ]]; then ok "$t"; else
  ng "$t" "diff: $(diff <(printf '%s\n' "$cur") "$FIX/never-auto-expected.txt" | head -5)"
fi

assert_contains "plugin.json is 1.9.0" .claude-plugin/plugin.json '"version": "1.9.0"'
t="CHANGELOG top heading is 1.9.0"
top="$(grep -m1 '^## ' "$REPO_ROOT/CHANGELOG.md")"
[[ "$top" == "## 1.9.0 — Auto mode" ]] && ok "$t" || ng "$t" "top=$top"
assert_contains "README has an Auto mode section" README.md '## Auto mode'
assert_contains "project doc lists /mi-auto" docs/millwright-inspector-project.md '/mi-auto'
assert_contains "project doc lists /mi-implement" docs/millwright-inspector-project.md '/mi-implement'

# ---- Final fixes ---------------------------------------------------------------

# Item 1: Review-Resume Step 1 only auto-answers "y" after a passing approve-guard.
assert_auto_before rr-confirm $MC 'auto.sh" approve-guard'

# Item 2: create-branch verifies the '## GIT BRANCH' heading BEFORE switching branches.
t="create-branch exits 1 (not 3) when config.md has no GIT BRANCH heading; HEAD and branches unchanged"
sb="$(make_sandbox --auto)"
cfg="$sb/millwright-inspector/workflow-stream/alpha/blueprints/current/config.md"
mkdir -p "$(dirname "$cfg")"
cat > "$cfg" <<'EOF'
# Config

## Lessons learned
- path: (none yet)
EOF
before_branches="$(cd "$sb" && git branch --format='%(refname:short)' | sort)"
out="$(run_in "$sb" "$A" create-branch alpha "$cfg" 2>&1)"; rc=$?
head_now="$(cd "$sb" && git rev-parse --abbrev-ref HEAD)"
after_branches="$(cd "$sb" && git branch --format='%(refname:short)' | sort)"
if [[ $rc -eq 1 && "$head_now" == "main" && "$before_branches" == "$after_branches" \
      && "$out" == *"GIT BRANCH"* ]]; then
  ok "$t"
else
  ng "$t" "rc=$rc head=$head_now before=[$before_branches] after=[$after_branches] out=$out"
fi

assert_contains "mi-plan-implementation relays non-3 create-branch exits and stops" commands/mi-plan-implementation.md \
  'On any other non-zero exit, relay the error and stop.'

# Item 3: /mi-auto's fence no longer reads an unassigned $mode.
assert_contains "mi-auto.md assigns mode inside the fence" commands/mi-auto.md 'mode="$ARGUMENTS"'

# Item 4: orphan-family / closed-IR auto answers name the concrete reopen/seed option
# (needles updated above at the mt-closed-ir / mt-orphan assert_auto_before calls).

# Item 6: CHANGELOG/README no longer claim every unresolved deferred question becomes a finding.
assert_contains "CHANGELOG deferred-questions wording: needs-finding conversion" CHANGELOG.md \
  'answered entries marked `needs-finding` become'
assert_contains "README deferred-questions wording: needs-finding conversion" README.md \
  'Answered entries marked `needs-finding` become findings automatically'

# Item 7: Inspector Step 0.5 prints an 'Open deferred questions:' header only when rows exist.
t="Step 0.5 prints 'Open deferred questions:' header only when open DQ rows exist"
snippet="$(python3 - "$REPO_ROOT/$MC" <<'PYEOF'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'```bash\n(if "\$CLAUDE_PLUGIN_ROOT/scripts/auto\.sh" is-on.*?)```', s, re.S)
print(m.group(1) if m else '')
PYEOF
)"
if [[ -z "$snippet" ]]; then
  ng "$t" "Inspector Step 0.5 snippet not found"
else
  sb1="$(make_sandbox --auto)"; run_in "$sb1" "$P" activate >/dev/null 2>&1
  out_no_dq="$(run_in "$sb1" env CLAUDE_PLUGIN_ROOT="$REPO_ROOT" active_feature=alpha bash -c "$snippet" 2>&1)"

  sb2="$(make_sandbox --auto)"; run_in "$sb2" "$P" activate >/dev/null 2>&1
  run_in "$sb2" "$DQ" add alpha "TTL?" "60s" >/dev/null 2>&1
  out_with_dq="$(run_in "$sb2" env CLAUDE_PLUGIN_ROOT="$REPO_ROOT" active_feature=alpha bash -c "$snippet" 2>&1)"

  if [[ "$out_no_dq" != *"Open deferred questions:"* \
        && "$out_with_dq" == *"Open deferred questions:"* \
        && "$out_with_dq" == *"TTL?"* ]]; then
    ok "$t"
  else
    ng "$t" "no_dq=[$out_no_dq] with_dq=[$out_with_dq]"
  fi
fi

# Item 8: mi-run's usage/error string mentions --auto.
assert_contains "mi-run usage/error string lists --auto" commands/mi-run.md \
  '/mi-run <folder1> [<folder2> ...] [--archive-active] [--auto]'

# Item 9: spec §3 rows 15 and 20 carry the concrete auto behaviour, not a placeholder.
SPEC=docs/superpowers/specs/2026-09-25-auto-mode-design.md
assert_contains "spec row 15 names the concrete reopen/seed answer" $SPEC \
  'Answer `a` (reopen the closed IR / seed into the regression family — keeps the failure open)'
assert_contains "spec row 20 requires a passing approve-guard" $SPEC \
  'Answer `y` only when `approve-guard` passes; otherwise print its line and show the prompt'

# ---- Follow-up: approve-guard stops on open deferred questions -----------------

t="approve-guard stops and names open deferred questions even when every finding is fixed"
sb="$(make_sandbox)"
review_file "$sb" "IR-001|fix|fixed"
run_in "$sb" "$DQ" add alpha "Which TTL?" "60s" >/dev/null 2>&1
run_in "$sb" "$DQ" add alpha "Retry count?" "3" >/dev/null 2>&1
run_in "$sb" "$DQ" answer alpha DQ-002 "3 is fine" >/dev/null 2>&1
out="$(run_in "$sb" "$A" approve-guard alpha 2>/dev/null)"; rc=$?
want="auto: review needs your look — DQ-001 (open question)"
[[ $rc -eq 1 && "$out" == "$want" ]] && ok "$t" || ng "$t" "rc=$rc out=$out"

t="approve-guard lists findings before open deferred questions in one line"
review_file "$sb" "IR-001|fix|fixed" "IR-002|re-spec|fixed"
out="$(run_in "$sb" "$A" approve-guard alpha 2>/dev/null)"; rc=$?
want="auto: review needs your look — IR-002 (re-spec), DQ-001 (open question)"
[[ $rc -eq 1 && "$out" == "$want" ]] && ok "$t" || ng "$t" "rc=$rc out=$out"

t="approve-guard passes once every deferred question is answered"
run_in "$sb" "$DQ" answer alpha DQ-001 "60s" >/dev/null 2>&1
review_file "$sb" "IR-001|fix|fixed"
out="$(run_in "$sb" "$A" approve-guard alpha 2>/dev/null)"; rc=$?
[[ $rc -eq 0 && -z "$out" ]] && ok "$t" || ng "$t" "rc=$rc out=$out"

# ---- end of tests --------------------------------------------------------------
echo
echo "auto-mode: $pass passed, $fail failed"
if (( fail > 0 )); then printf '  - %s\n' "${fail_names[@]}" >&2; exit 1; fi
