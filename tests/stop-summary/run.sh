#!/usr/bin/env bash
# run.sh — tests for scripts/stop-summary.sh (1.15.0), the one-sentence summary
# that ends the stage-2 blueprint stop and the stage-5 review stop, and for the
# persist-findings --items/--fixed flags that feed its stage-2 numbers.
#
# Every fixture is a small fake MI project (a git repo, so the commit count
# works) generated into a temp folder at test time — nothing is committed.
# Each check prints ✓/✗; the suite exits 1 if any failed.
set -uo pipefail

# Every script finds its siblings through MI_PLUGIN_ROOT, which prefers
# $CLAUDE_PLUGIN_ROOT — unset it so every call runs this checkout. The data
# root is each fixture's ./millwright-inspector.
unset CLAUDE_PLUGIN_ROOT MI_DATA_ROOT CLAUDE_PLUGIN_USER_CONFIG_data_root
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUMMARY="$REPO_ROOT/scripts/stop-summary.sh"
REVIEW="$REPO_ROOT/scripts/blueprint-review.sh"
SLUG=2026-10-20-demo
FT=demo-feature-test
ACT=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa

pass=0
fail=0
fail_names=()

ok() { printf "\xe2\x9c\x93 %s\n" "$1"; pass=$((pass + 1)); }
ng() { printf "\xe2\x9c\x97 %s\n   %s\n" "$1" "$2" >&2; fail=$((fail + 1)); fail_names+=("$1"); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- Fixture builders --------------------------------------------------------

# project <name> <commits> — a git repo with <commits> commits after a base
# commit; prints its path. BASE_<name> is not exported: use base_of.
project() {
  local p="$TMP/$1" i
  mkdir -p "$p"
  git -C "$p" init -q
  git -C "$p" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  for ((i = 0; i < $2; i++)); do
    git -C "$p" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "c$i"
  done
  printf '%s' "$p"
}
base_of() { git -C "$1" rev-list --max-parents=0 HEAD; }

# cycle <project> <feature> <stage> <completed-csv> <queue-csv> [active line …]
# — quest/active.md, progress.md (block-style lists, as progress.sh writes them)
# and a todo-list.md naming $FT as the feature-test entry.
cycle() {
  local p="$1" feature="$2" stage="$3" completed="$4" queue="$5" q="$1/millwright-inspector/quest" item
  shift 5
  mkdir -p "$q/$SLUG"
  printf -- '---\nslug: %s\nstatus: active\n---\n' "$SLUG" > "$q/active.md"
  {
    printf -- '---\nid: 11111111-1111-4111-8111-111111111111\n'
    if [[ -n "$queue" ]]; then
      printf 'queue:\n'
      for item in ${queue//,/ }; do printf -- '- %s\n' "$item"; done
    else
      printf 'queue: []\n'
    fi
    if [[ -n "$completed" ]]; then
      printf 'completed:\n'
      for item in ${completed//,/ }; do printf -- '- %s\n' "$item"; done
    else
      printf 'completed: []\n'
    fi
    printf 'active:\n  feature: %s\n  current-stage: %s\n  base-commit: %s\n  activation-id: %s\n' \
      "$feature" "$stage" "$(base_of "$p")" "$ACT"
    for item in "$@"; do printf '  %s\n' "$item"; done
    printf 'auto-mode: false\n---\n'
  } > "$q/$SLUG/progress.md"
  printf -- '---\nid: 22222222-2222-4222-8222-222222222222\nfeature-test: %s\n---\n' "$FT" > "$q/$SLUG/todo-list.md"
}

ws() { printf '%s/millwright-inspector/workflow-stream/%s' "$1" "$2"; }

# finding <id> <severity> — one canonical inline REVIEW-FINDING block.
finding() {
  printf '<!-- REVIEW-FINDING\nid: %s\nseverity: %s\nscope-impact: clarifying\nphase: item\ntarget: X-001\nfinding: |\n  something\nsuggested-fix: |\n  something else\n-->\n' "$1" "$2"
}

# history <file> [frontmatter line …] — a review-history.md; F-NNN sections
# come from $HISTORY_BODY.
history() {
  local f="$1"
  shift
  mkdir -p "$(dirname "$f")"
  {
    printf -- '---\nid: 33333333-3333-4333-8333-333333333333\nfeature: demo\nrequirements-id: null\n'
    printf 'last-finding-id: F-009\nfinding-count-total: %s\nfinding-count-unresolved: 0\n' "${TOTAL:-0}"
    printf 'last-review-at: "2026-10-20T00:00:00Z"\n'
    for line in "$@"; do printf '%s\n' "$line"; done
    printf -- '---\n\n# Review history\n%s' "${HISTORY_BODY:-}"
  } > "$f"
}

# ir <id> <status> [source] — one inspector-review.md finding block.
ir() {
  printf '\n### %s — a finding\n- severity: major\n- scope: fix\n- status: %s\n' "$1" "$2"
  [[ -n "${3:-}" ]] && printf -- '- source: %s\n' "$3"
  printf -- '- details: ""\n- fix-note: ""\n'
}

# dq <id> <status> — one deferred-questions.md entry.
dq() { printf '\n## %s\n- question: q\n- assumed: a\n- status: %s\n- answer:\n- needs-finding: false\n- follow-up:\n' "$1" "$2"; }

# results <file> <activation> <state> <total> <passed> <failed> <skipped> <deferred>
results() {
  mkdir -p "$(dirname "$1")"
  printf -- '---\nfeature: demo\nstate: %s\ntotal: %s\npassed: %s\nfailed: %s\nskipped: %s\ndeferred: %s\ngenerated-in-activation: %s\n---\n' \
    "$3" "$4" "$5" "$6" "$7" "$8" "$2" > "$1"
}

# expect <name> <project> <kind> <expected stdout>
expect() {
  local out rc
  out="$(cd "$2" && "$SUMMARY" "$3" 2>&1)"
  rc=$?
  if [[ $rc -eq 0 && "$out" == "$4" ]]; then ok "$1"; else ng "$1" "rc=$rc out=[$out] want=[$4]"; fi
}

# ---- Stage 2: blueprint -------------------------------------------------------

p="$(project b-clean 0)"
cycle "$p" pricing 2 "" "export,invoice,$FT"
mkdir -p "$(ws "$p" pricing)/blueprints/current"
printf -- '---\nid: x\n---\n\n## Goals (this cycle)\n\n- PAY-001 a goal\n' > "$(ws "$p" pricing)/blueprints/current/requirements.md"
history "$(ws "$p" pricing)/blueprints/current/review-history.md" "last-review-items: 6" "last-review-fixed: 9"
expect "blueprint, nothing open: fixed and open counts, nothing to decide" "$p" blueprint \
  '**Summary:** Stage 2 of 8 (blueprint) for `pricing`, feature 1 of 3: the review checked 6 requirements and fixed 9 findings, 0 findings are open, and nothing needs your decision.'

p="$(project b-open 0)"
cycle "$p" invoice 2 "pricing" "export,$FT"
cur="$(ws "$p" invoice)/blueprints/current"
mkdir -p "$cur"
{
  printf -- '---\nid: x\n---\n\n## Goals (this cycle)\n\n'
  finding F-001 critical; printf -- '- INV-001 a goal\n'
  finding F-002 medium; finding F-003 medium
  finding F-004 high   # declined at the scope gate — decided, so not open
} > "$cur/requirements.md"
HISTORY_BODY=$'\n## F-004\n- severity: high\n- last-status: deferred\n\n## F-005\n- severity: medium\n- last-status: deferred\n\n## F-006\n- severity: medium\n- last-status: dropped\n' \
  TOTAL=6 history "$cur/review-history.md" "last-review-items: 8" "last-review-fixed: 9"
printf -- '---\nid: y\n---\n\n<!-- auto:start -->\n\n## Skills\n\n## Load on demand\n\n## Catalog suggestions\n\n- agent-browser - e2e checks\n  stages:review;requested:no;install:catalog add agent-browser\n- web-images - images\n  stages:implement;requested:yes;install:catalog add web-images\n\n<!-- auto:end -->\n' > "$cur/config.md"
expect "blueprint, open findings by severity, declined proposals, a skill waiting" "$p" blueprint \
  '**Summary:** Stage 2 of 8 (blueprint) for `invoice`, feature 2 of 3: the review checked 8 requirements and fixed 9 findings, 3 findings are still open (1 critical, 2 medium), 2 scope proposals were declined, and 1 suggested skill is waiting for your OK.'

p="$(project b-singular 0)"
cycle "$p" export 2 "pricing,invoice" "$FT"
cur="$(ws "$p" export)/blueprints/current"
mkdir -p "$cur"
{ printf -- '---\nid: x\n---\n\n'; finding F-001 high; } > "$cur/requirements.md"
history "$cur/review-history.md" "last-review-items: 1" "last-review-fixed: 1"
expect "blueprint, singular wording, last feature" "$p" blueprint \
  '**Summary:** Stage 2 of 8 (blueprint) for `export`, feature 3 of 3: the review checked 1 requirement and fixed 1 finding, and 1 finding is still open (1 high).'

p="$(project b-none 0)"
cycle "$p" pricing 2 "" ""
mkdir -p "$(ws "$p" pricing)/blueprints/current"
printf -- '---\nid: x\n---\n\n- PAY-001\n' > "$(ws "$p" pricing)/blueprints/current/requirements.md"
expect "blueprint, no review recorded (skipped review, no history)" "$p" blueprint \
  '**Summary:** Stage 2 of 8 (blueprint) for `pricing`, feature 1 of 1: no blueprint review is recorded, 0 findings are open, and nothing needs your decision.'

p="$(project b-old 0)"
cycle "$p" pricing 2 "" ""
cur="$(ws "$p" pricing)/blueprints/current"
mkdir -p "$cur"
{ printf -- '---\nid: x\n---\n\n'; finding F-001 medium; } > "$cur/requirements.md"
TOTAL=3 history "$cur/review-history.md"
expect "blueprint, a pre-1.15.0 history: no run numbers, open count still shown" "$p" blueprint \
  '**Summary:** Stage 2 of 8 (blueprint) for `pricing`, feature 1 of 1: 1 finding is still open (1 medium).'

p="$(project b-ft 0)"
cycle "$p" "$FT" 2 "pricing" ""
expect "blueprint on the feature-test entry prints nothing" "$p" blueprint ''

# ---- Stage 5: review ----------------------------------------------------------

p="$(project r-clean 3)"
cycle "$p" pricing 5 "" "export,$FT" "manual-test-state: complete"
results "$(ws "$p" pricing)/test/manual-test-results.md" "$ACT" complete 14 14 0 0 0
mkdir -p "$(ws "$p" pricing)/implementation"
{ dq DQ-001 answered; dq DQ-002 answered; } > "$(ws "$p" pricing)/implementation/deferred-questions.md"
printf -- '---\nid: z\n---\n\n## Implementation Review\n\n<!-- Findings (IR-NNN). -->\n' > "$(ws "$p" pricing)/implementation/inspector-review.md"
expect "review, nothing waiting: an empty review completes the feature" "$p" review \
  '**Summary:** Stage 5 of 8 (inspector review) for `pricing`, feature 1 of 2: 3 commits, 14 of 14 test scenarios passed, 2 of 2 deferred questions answered, and 0 findings are open, so an empty review completes the feature.'

p="$(project r-open 11)"
cycle "$p" invoice 5 "pricing" "export,$FT" "manual-test-state: complete"
results "$(ws "$p" invoice)/test/manual-test-results.md" "$ACT" complete 18 15 2 1 0
impl="$(ws "$p" invoice)/implementation"
mkdir -p "$impl"
{
  printf -- '---\nid: z\n---\n\n## Implementation Review\n'
  ir IR-001 open manual-test; ir IR-002 open manual-test; ir IR-003 open conventions-review
} > "$impl/inspector-review.md"
{ dq DQ-001 answered; dq DQ-002 open; dq DQ-003 answered; } > "$impl/deferred-questions.md"
expect "review, failures seeded as findings, an open deferred question" "$p" review \
  '**Summary:** Stage 5 of 8 (inspector review) for `invoice`, feature 2 of 3: 11 commits, 18 test scenarios run (15 passed, 2 failed, 1 skipped), 3 findings waiting (2 from the failed tests, 1 from the conventions review), 0 fixed so far, and 1 of 3 deferred questions still open.'

p="$(project r-skipped 1)"
cycle "$p" pricing 5 "" "" "manual-test-state: skipped"
# A finished run from an earlier activation must not count for this one.
results "$(ws "$p" pricing)/test/manual-test-results.md" "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" complete 5 5 0 0 0
impl="$(ws "$p" pricing)/implementation"
mkdir -p "$impl"
{
  printf -- '---\nid: z\n---\n\n## Implementation Review\n'
  ir IR-001 open; ir IR-002 fixed manual-test; ir IR-003 wontfix
} > "$impl/inspector-review.md"
expect "review, testing skipped (old results ignored), your finding, fixed and won't-fix counts" "$p" review \
  '**Summary:** Stage 5 of 8 (inspector review) for `pricing`, feature 1 of 1: 1 commit, manual testing skipped, 1 finding waiting (1 written by you), 1 fixed so far, and 1 marked won'"'"'t fix.'

p="$(project r-notrun 2)"
cycle "$p" pricing 5 "" "" "manual-test-state: none"
expect "review, no manual test yet and no review file" "$p" review \
  '**Summary:** Stage 5 of 8 (inspector review) for `pricing`, feature 1 of 1: 2 commits, no manual test run yet, and 0 findings are open, so an empty review completes the feature.'

p="$(project r-unseeded 1)"
cycle "$p" pricing 5 "" "" "manual-test-state: complete"
results "$(ws "$p" pricing)/test/manual-test-results.md" "$ACT" complete 3 2 1 0 0
expect "review, a failed test not seeded is never called complete" "$p" review \
  '**Summary:** Stage 5 of 8 (inspector review) for `pricing`, feature 1 of 1: 1 commit, 3 test scenarios run (2 passed, 1 failed), and 0 findings open.'

p="$(project r-deferred 1)"
cycle "$p" pricing 5 "" "$FT" "manual-test-state: complete"
results "$(ws "$p" pricing)/test/manual-test-results.md" "$ACT" complete 5 4 0 0 1
expect "review, a scenario deferred to the whole-cycle test" "$p" review \
  '**Summary:** Stage 5 of 8 (inspector review) for `pricing`, feature 1 of 1: 1 commit, 5 test scenarios run (4 passed, 1 deferred to the whole-cycle test), and 0 findings are open, so an empty review completes the feature.'

p="$(project r-ft 4)"
cycle "$p" "$FT" 5 "pricing,invoice" "" "manual-test-state: complete"
results "$(ws "$p" "$FT")/test/manual-test-results.md" "$ACT" complete 17 16 1 0 0
mkdir -p "$(ws "$p" "$FT")/implementation"
{ printf -- '---\nid: z\n---\n\n## Implementation Review\n'; ir IR-001 open manual-test; } > "$(ws "$p" "$FT")/implementation/inspector-review.md"
printf -- '---\nid: d\n---\n\n## Deferred scenarios\n\n### pricing/B.2 — refund shows\n\n- **Originating feature:** pricing\n- **Merged as:**\n' \
  > "$(ws "$p" "$FT")/test/deferred-tests.md"
expect "review, feature-test entry: position, deferred tests without a verdict" "$p" review \
  '**Summary:** Stage 5 of 8 (inspector review) for `demo-feature-test`, the whole-cycle test after 2 finished features: 4 commits, 17 test scenarios run (16 passed, 1 failed), 1 finding waiting (1 from a failed test), 0 fixed so far, and 1 deferred test scenario from earlier features still needs a verdict.'

# ---- Silence and usage ---------------------------------------------------------

p="$(project n-between 0)"
mkdir -p "$p/millwright-inspector/quest/$SLUG"
printf -- '---\nslug: %s\nstatus: active\n---\n' "$SLUG" > "$p/millwright-inspector/quest/active.md"
printf -- '---\nid: 1\nqueue: []\ncompleted: []\nactive: null\n---\n' > "$p/millwright-inspector/quest/$SLUG/progress.md"
expect "no active feature prints nothing" "$p" review ''
expect "no cycle at all prints nothing" "$(project n-nocycle 0)" blueprint ''

t="a bad kind is a usage error (exit 2)"
"$SUMMARY" stage-7 >/dev/null 2>&1
if [[ $? -eq 2 ]]; then ok "$t"; else ng "$t" "expected exit 2"; fi

# ---- persist-findings --items / --fixed -----------------------------------------

h="$TMP/persist/review-history.md"
history "$h"
t="persist-findings --items/--fixed records last-review-items/-fixed"
printf '[]\n' | "$REVIEW" persist-findings "$h" - --items 6 --fixed 9 >/dev/null 2>&1
if grep -qx 'last-review-items: 6' "$h" && grep -qx 'last-review-fixed: 9' "$h"; then ok "$t"; else ng "$t" "$(head -12 "$h")"; fi

t="the recorded fields pass the review-history schema"
if "$REPO_ROOT/scripts/frontmatter.sh" validate "$h" review-history >/dev/null 2>&1; then ok "$t"; else ng "$t" "schema rejected the file"; fi

t="persist-findings without the flags keeps the recorded numbers"
printf '[]\n' | "$REVIEW" persist-findings "$h" - >/dev/null 2>&1
if grep -qx 'last-review-items: 6' "$h" && grep -qx 'last-review-fixed: 9' "$h"; then ok "$t"; else ng "$t" "$(head -12 "$h")"; fi

t="--items without --fixed is refused (exit 64), file untouched"
before="$(cat "$h")"
printf '[]\n' | "$REVIEW" persist-findings "$h" - --items 3 >/dev/null 2>&1
rc=$?
if [[ $rc -eq 64 && "$(cat "$h")" == "$before" ]]; then ok "$t"; else ng "$t" "rc=$rc"; fi

# ---- Wiring: every stop ends with the summary ------------------------------------

t="each stop's prose runs stop-summary.sh (1 blueprint site, 8 review sites)"
c="$REPO_ROOT/commands"
nb="$(grep -oE 'stop-summary\.sh"? blueprint' "$c/mi-apply-impact.md" | wc -l | tr -d ' ')"
nr="$(cat "$c/mi-continue.md" "$c/mi-manual-test-run.md" "$c/mi-manual-test-plan.md" \
  | grep -oE 'stop-summary\.sh"? review' | wc -l | tr -d ' ')"
if [[ "$nb" == 1 && "$nr" == 8 ]]; then ok "$t"; else ng "$t" "blueprint=$nb review=$nr"; fi

echo
echo "stop-summary: $pass passed, $fail failed"
if (( fail )); then
  printf '  - %s\n' "${fail_names[@]}" >&2
  exit 1
fi
