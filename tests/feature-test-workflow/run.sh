#!/usr/bin/env bash
# run.sh — integration tests for the abbreviated feature-test workflow
# (FTW-001..009).
#
# Each test prints PASS/FAIL; the suite exits 1 if any test failed.
# Tests are additive: later tasks append blocks under their own task headings.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="$TESTS_DIR/fixtures"

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

# make_quest — sandbox data root with one active quest cycle. Prints its path.
make_quest() {
  local sandbox slug
  sandbox="$(mktemp -d)"
  slug="2026-08-14-demo"
  mkdir -p "$sandbox/quest/$slug"
  cat > "$sandbox/quest/active.md" <<EOF
---
slug: $slug
started: "2026-08-14"
journal-folders: [demo]
status: active
---

# Active quest pointer
EOF
  SANDBOXES+=("$sandbox")
  printf '%s' "$sandbox"
}

quest_dir() { printf '%s/quest/2026-08-14-demo' "$1"; }

# seed_todo <sandbox> — two ordinary features plus a feature-test section.
seed_todo() {
  cat > "$(quest_dir "$1")/todo-list.md" <<'EOF'
---
id: 66666666-6666-4666-8666-666666666666
related-features: [payments, audit-log, payments-feature-test]
description: Seed cycle for feature-test workflow tests.
feature-test: payments-feature-test
---

# Todo list

## payments

- [x] (emin) IMPLEMENTED — PAY-001: first payment item

## audit-log

- [x] (emin) IMPLEMENTED — AUD-001: first audit item

## payments-feature-test

- [x] (emin) PENDING — FT-001: test the whole feature implementation
EOF
}

# seed_todo_no_ft <sandbox> — single-feature cycle, no feature-test field.
seed_todo_no_ft() {
  cat > "$(quest_dir "$1")/todo-list.md" <<'EOF'
---
id: 77777777-7777-4777-8777-777777777777
related-features: [payments]
description: Single-feature cycle.
---

# Todo list

## payments

- [x] (emin) IMPLEMENTED — PAY-001: first payment item
EOF
}

# ---- Task 1: is-feature-test ----------------------------------------------

is_ft() { MI_DATA_ROOT="$1" "$REPO_ROOT/scripts/todo.sh" is-feature-test "$2" >/dev/null 2>&1; }

t="is-feature-test: exit 0 for the declared feature-test name"
sandbox="$(make_quest)"; seed_todo "$sandbox"
if is_ft "$sandbox" payments-feature-test; then ok "$t"; else ng "$t" "declared name was rejected"; fi

t="is-feature-test: exit 1 for an ordinary feature name"
sandbox="$(make_quest)"; seed_todo "$sandbox"
if is_ft "$sandbox" payments; then ng "$t" "ordinary feature matched the predicate"; else ok "$t"; fi

t="is-feature-test: exit 1 when the cycle declares no feature-test"
sandbox="$(make_quest)"; seed_todo_no_ft "$sandbox"
if is_ft "$sandbox" payments-feature-test; then ng "$t" "matched despite no declaration"; else ok "$t"; fi

t="is-feature-test: exit 1 when todo-list.md is absent (never dies)"
sandbox="$(make_quest)"
if is_ft "$sandbox" payments-feature-test; then ng "$t" "matched with no todo-list.md"; else ok "$t"; fi

t="is-feature-test: silent on both streams"
sandbox="$(make_quest)"; seed_todo "$sandbox"
out="$(MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/todo.sh" is-feature-test payments 2>&1)"
if [[ -z "$out" ]]; then ok "$t"; else ng "$t" "expected no output, got '$out'"; fi

t="is-feature-test: writes no files"
sandbox="$(make_quest)"; seed_todo "$sandbox"
before="$(shasum -a 256 "$(quest_dir "$sandbox")/todo-list.md" | cut -d' ' -f1)"
is_ft "$sandbox" payments-feature-test
after="$(shasum -a 256 "$(quest_dir "$sandbox")/todo-list.md" | cut -d' ' -f1)"
if [[ "$before" == "$after" ]]; then ok "$t"; else ng "$t" "read-only predicate modified todo-list.md"; fi

# ---- Task 2: advance-to 2->5 ----------------------------------------------

# make_progress <sandbox> — init a queue and activate the first feature, so
# progress.md sits at current-stage=2 with a valid worktree fingerprint.
make_progress() {
  local sandbox="$1"
  MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/progress.sh" \
    init 66666666-6666-4666-8666-666666666666 payments audit-log >/dev/null 2>&1
  MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/progress.sh" activate >/dev/null 2>&1
}

t="advance-to: 2->5 is accepted"
sandbox="$(make_quest)"; seed_todo "$sandbox"; make_progress "$sandbox"
if MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/progress.sh" \
   advance-to 2 5 --set sub-flow=none >/dev/null 2>&1; then
  ok "$t"
else
  ng "$t" "2->5 was refused"
fi

t="advance-to: 2->5 lands the stage and the --set field atomically"
sandbox="$(make_quest)"; seed_todo "$sandbox"; make_progress "$sandbox"
MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/progress.sh" \
  advance-to 2 5 --set implementation-completed=true >/dev/null 2>&1
st="$(MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/progress.sh" get current-stage 2>/dev/null)"
ic="$(MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/progress.sh" get implementation-completed 2>/dev/null)"
if [[ "$st" == "5" && "$ic" == "true" ]]; then
  ok "$t"
else
  ng "$t" "expected stage 5 / impl true, got '$st' / '$ic'"
fi

t="advance-to: 2->4 is still refused"
sandbox="$(make_quest)"; seed_todo "$sandbox"; make_progress "$sandbox"
if MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/progress.sh" \
   advance-to 2 4 >/dev/null 2>&1; then
  ng "$t" "2->4 was accepted — whitelist is too wide"
else
  ok "$t"
fi

t="advance-to: 2->6 is still refused"
sandbox="$(make_quest)"; seed_todo "$sandbox"; make_progress "$sandbox"
if MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/progress.sh" \
   advance-to 2 6 >/dev/null 2>&1; then
  ng "$t" "2->6 was accepted — whitelist is too wide"
else
  ok "$t"
fi

t="advance-to: the refusal diagnostic lists 2->5 among the allowed pairs"
sandbox="$(make_quest)"; seed_todo "$sandbox"; make_progress "$sandbox"
err="$(MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/progress.sh" \
       advance-to 2 4 2>&1 >/dev/null || true)"
if [[ "$err" == *"2→5"* ]]; then
  ok "$t"
else
  ng "$t" "diagnostic does not advertise 2->5: '$err'"
fi

# ---- Task 3: schemas -------------------------------------------------------

fm_valid() { "$REPO_ROOT/scripts/frontmatter.sh" validate "$1" "$2" >/dev/null 2>&1; }

t="schema: an ordinary change-summary still validates (back-compat)"
if fm_valid "$FIXTURES/cs-ordinary/change-summary.md" change-summary; then
  ok "$t"
else
  ng "$t" "singular requirements-id was rejected — breaks every existing file"
fi

t="schema: a feature-test change-summary with requirements-ids validates"
if fm_valid "$FIXTURES/cs-feature-test/change-summary.md" change-summary; then
  ok "$t"
else
  ng "$t" "plural requirements-ids was rejected"
fi

t="schema: change-summary carrying BOTH fields is rejected"
if fm_valid "$FIXTURES/cs-both/change-summary.md" change-summary; then
  ng "$t" "both fields were accepted — the oneOf gate is not enforcing"
else
  ok "$t"
fi

t="schema: change-summary carrying NEITHER field is rejected"
if fm_valid "$FIXTURES/cs-neither/change-summary.md" change-summary; then
  ng "$t" "neither field was accepted — the requirement is unenforced"
else
  ok "$t"
fi

t="schema: an ordinary manual-test-plan still validates (back-compat)"
if fm_valid "$FIXTURES/mtp-ordinary/manual-test-plan.md" manual-test-plan; then
  ok "$t"
else
  ng "$t" "singular requirements-id was rejected on manual-test-plan"
fi

t="schema: a feature-test manual-test-plan with requirements-ids validates"
if fm_valid "$FIXTURES/mtp-feature-test/manual-test-plan.md" manual-test-plan; then
  ok "$t"
else
  ng "$t" "plural requirements-ids was rejected on manual-test-plan"
fi

# ---- Task 4: feature-test-range -------------------------------------------

# make_git_repo — a throwaway git repo with a linear history. Prints its path.
# Commit subjects are c1..c4; SHAs are read back by the caller.
make_git_repo() {
  local repo
  repo="$(mktemp -d)"
  SANDBOXES+=("$repo")
  (
    cd "$repo" || exit 1
    git init -q
    git config user.email t@example.com
    git config user.name Test
    for n in 1 2 3 4; do
      echo "$n" > "f$n.txt"
      git add "f$n.txt"
      git commit -q -m "c$n"
    done
  ) >/dev/null 2>&1
  printf '%s' "$repo"
}

# sha_of <repo> <subject> — resolve a commit sha by its subject line.
sha_of() { git -C "$1" log --format='%H %s' | awk -v s="$2" '$2==s {print $1; exit}'; }

# seed_history <sandbox> <feature> <base> <head> — write an archived
# change-summary for a finished feature at history/v1/.
seed_history() {
  local dir="$1/workflow-stream/$2/blueprints/history/v1/implementation"
  mkdir -p "$dir"
  cat > "$dir/change-summary.md" <<EOF
---
id: $(uuidgen | tr 'A-F' 'a-f')
requirements-id: 22222222-2222-4222-8222-222222222222
feature: $2
base-commit: $3
head: $4
---

# Change summary — $2
EOF
}

# seed_completed <sandbox> <feature...> — progress.md with a completed list and
# the feature-test entry active.
seed_completed() {
  local sandbox="$1"; shift
  local feats=("$@")
  local list=""
  local f
  for f in "${feats[@]}"; do list="$list- $f"$'\n'; done
  cat > "$(quest_dir "$sandbox")/progress.md" <<EOF
---
todo-list-id: 66666666-6666-4666-8666-666666666666
queue: []
completed:
$list
active:
  feature: payments-feature-test
  branch: null
  current-stage: 2
  sub-flow: none
  base-commit: null
  execution-mode: none
  planning-mode: none
  review-mode: none
  review-mode-suggestion: none
  diagram-prompt: prompt
  diagram-rendering: never
  implementation-diagrams-skipped: false
  implementation-completed: false
  inspector-review-completed: false
  manual-test-state: none
  manual-test-failure-policy: none
  worktree-path: null
  git-common-dir: null
  git-worktree-dir: null
  activation-id: 77777777-7777-4777-8777-777777777777
---

# Progress
EOF
}

ft_range() { ( cd "$2" && MI_DATA_ROOT="$1" "$REPO_ROOT/scripts/commits.sh" feature-test-range payments-feature-test ); }

t="feature-test-range: stacked features yield the earliest base and HEAD"
repo="$(make_git_repo)"; sandbox="$(make_quest)"; seed_todo "$sandbox"
c1="$(sha_of "$repo" c1)"; c2="$(sha_of "$repo" c2)"; c3="$(sha_of "$repo" c3)"; c4="$(sha_of "$repo" c4)"
seed_history "$sandbox" payments   "$c1" "$c2"
seed_history "$sandbox" audit-log  "$c2" "$c3"
seed_completed "$sandbox" payments audit-log
row="$(ft_range "$sandbox" "$repo" 2>/dev/null | head -1)"
if [[ "$row" == "$c1	$c4" ]]; then
  ok "$t"
else
  ng "$t" "expected '$c1<TAB>$c4', got '$row'"
fi

t="feature-test-range: lists each contributing feature"
repo="$(make_git_repo)"; sandbox="$(make_quest)"; seed_todo "$sandbox"
c1="$(sha_of "$repo" c1)"; c2="$(sha_of "$repo" c2)"; c3="$(sha_of "$repo" c3)"
seed_history "$sandbox" payments  "$c1" "$c2"
seed_history "$sandbox" audit-log "$c2" "$c3"
seed_completed "$sandbox" payments audit-log
n="$(ft_range "$sandbox" "$repo" 2>/dev/null | grep -c '^contributor')"
if [[ "$n" == "2" ]]; then ok "$t"; else ng "$t" "expected 2 contributor rows, got $n"; fi

t="feature-test-range: excludes the feature-test entry from its own inputs"
repo="$(make_git_repo)"; sandbox="$(make_quest)"; seed_todo "$sandbox"
c1="$(sha_of "$repo" c1)"; c2="$(sha_of "$repo" c2)"
seed_history "$sandbox" payments "$c1" "$c2"
seed_completed "$sandbox" payments payments-feature-test
out="$(ft_range "$sandbox" "$repo" 2>/dev/null)"
if [[ "$out" != *"payments-feature-test"* ]]; then
  ok "$t"
else
  ng "$t" "the entry appeared in its own input set"
fi

t="feature-test-range: exit 3 when a finished feature is unreachable from HEAD"
repo="$(make_git_repo)"; sandbox="$(make_quest)"; seed_todo "$sandbox"
c1="$(sha_of "$repo" c1)"
( cd "$repo" && git checkout -q -b side "$c1" && echo x > x.txt && git add x.txt && git commit -q -m orphan ) >/dev/null 2>&1
orphan="$(sha_of "$repo" orphan)"
( cd "$repo" && git checkout -q - ) >/dev/null 2>&1
seed_history "$sandbox" payments  "$c1" "$orphan"
seed_completed "$sandbox" payments
ft_range "$sandbox" "$repo" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 3 ]]; then ok "$t"; else ng "$t" "expected exit 3, got $rc"; fi

t="feature-test-range: the unreachable diagnostic names the offending feature"
err="$(ft_range "$sandbox" "$repo" 2>&1 >/dev/null || true)"
if [[ "$err" == *"payments"* ]]; then
  ok "$t"
else
  ng "$t" "diagnostic did not name the unreachable feature: '$err'"
fi

t="feature-test-range: exit 4 when no finished feature contributed commits"
repo="$(make_git_repo)"; sandbox="$(make_quest)"; seed_todo "$sandbox"
seed_completed "$sandbox" payments
ft_range "$sandbox" "$repo" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 4 ]]; then ok "$t"; else ng "$t" "expected exit 4, got $rc"; fi

t="feature-test-range: exit 5 when finished features' bases diverge"
repo="$(make_git_repo)"; sandbox="$(make_quest)"; seed_todo "$sandbox"
default_branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
c1="$(sha_of "$repo" c1)"; c2="$(sha_of "$repo" c2)"; c3="$(sha_of "$repo" c3)"
(
  cd "$repo" \
    && git checkout -q -b side "$c1" \
    && echo s1 > s1.txt && git add s1.txt && git commit -q -m s1 \
    && echo s2 > s2.txt && git add s2.txt && git commit -q -m s2 \
    && git checkout -q "$default_branch" \
    && git merge -q --no-ff side -m merge
) >/dev/null 2>&1
s1="$(sha_of "$repo" s1)"; s2="$(sha_of "$repo" s2)"
seed_history "$sandbox" payments  "$c2" "$c3"
seed_history "$sandbox" audit-log "$s1" "$s2"
seed_completed "$sandbox" payments audit-log
ft_range "$sandbox" "$repo" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 5 ]]; then ok "$t"; else ng "$t" "expected exit 5, got $rc"; fi

t="feature-test-range: a zero-commit feature is omitted, not fatal"
repo="$(make_git_repo)"; sandbox="$(make_quest)"; seed_todo "$sandbox"
c1="$(sha_of "$repo" c1)"; c2="$(sha_of "$repo" c2)"
seed_history "$sandbox" payments "$c1" "$c2"
seed_completed "$sandbox" payments audit-log     # audit-log has no history at all
out="$(ft_range "$sandbox" "$repo" 2>/dev/null)"
if [[ "$out" == *"omitted	audit-log"* ]]; then
  ok "$t"
else
  ng "$t" "zero-commit feature was not reported as omitted: '$out'"
fi

t="feature-test-range: writes no files"
repo="$(make_git_repo)"; sandbox="$(make_quest)"; seed_todo "$sandbox"
c1="$(sha_of "$repo" c1)"; c2="$(sha_of "$repo" c2)"
seed_history "$sandbox" payments "$c1" "$c2"
seed_completed "$sandbox" payments
before="$(shasum -a 256 "$(quest_dir "$sandbox")/progress.md" | cut -d' ' -f1)"
ft_range "$sandbox" "$repo" >/dev/null 2>&1
after="$(shasum -a 256 "$(quest_dir "$sandbox")/progress.md" | cut -d' ' -f1)"
if [[ "$before" == "$after" ]]; then ok "$t"; else ng "$t" "progress.md was modified"; fi

# ---- Task 5: populate-feature-test ----------------------------------------

# seed_ft_change_summary <sandbox> <base> <head> — the live change-summary the
# diagram pass writes for the entry.
seed_ft_change_summary() {
  local dir="$1/workflow-stream/payments-feature-test/implementation"
  mkdir -p "$dir"
  cat > "$dir/change-summary.md" <<EOF
---
id: 33333333-3333-4333-8333-333333333333
requirements-ids:
- 22222222-2222-4222-8222-222222222222
feature: payments-feature-test
base-commit: $2
head: $3
---

# Change summary — payments-feature-test
EOF
}

t="populate-feature-test: writes one commits entry per commit in the union range"
repo="$(make_git_repo)"; sandbox="$(make_quest)"; seed_todo "$sandbox"
c1="$(sha_of "$repo" c1)"; c2="$(sha_of "$repo" c2)"; c4="$(sha_of "$repo" c4)"
seed_history "$sandbox" payments "$c1" "$c2"
seed_completed "$sandbox" payments
seed_ft_change_summary "$sandbox" "$c1" "$c4"
( cd "$repo" && MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/commits.sh" \
    populate-feature-test payments-feature-test ) >/dev/null 2>&1
n="$(grep -c '^- sha: ' "$sandbox/workflow-stream/payments-feature-test/implementation/change-summary.md")"
if [[ "$n" == "3" ]]; then
  ok "$t"
else
  ng "$t" "expected 3 commits (c2..c4), got $n"
fi

t="populate-feature-test: the written file still validates"
if "$REPO_ROOT/scripts/frontmatter.sh" validate \
   "$sandbox/workflow-stream/payments-feature-test/implementation/change-summary.md" \
   change-summary >/dev/null 2>&1; then
  ok "$t"
else
  ng "$t" "populated change-summary failed schema validation"
fi

t="populate-feature-test: preserves requirements-ids"
if grep -q '^requirements-ids:' \
   "$sandbox/workflow-stream/payments-feature-test/implementation/change-summary.md"; then
  ok "$t"
else
  ng "$t" "requirements-ids was dropped by the populate write"
fi

t="populate-feature-test: refuses when the change-summary is absent"
repo="$(make_git_repo)"; sandbox="$(make_quest)"; seed_todo "$sandbox"
c1="$(sha_of "$repo" c1)"; c2="$(sha_of "$repo" c2)"
seed_history "$sandbox" payments "$c1" "$c2"
seed_completed "$sandbox" payments
if ( cd "$repo" && MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/commits.sh" \
     populate-feature-test payments-feature-test ) >/dev/null 2>&1; then
  ng "$t" "accepted a missing change-summary"
else
  ok "$t"
fi

# ---- Task 6: mi-continue dispatcher fork ----------------------------------

MI_CONT="$REPO_ROOT/commands/mi-continue.md"

t="mi-continue: Row A branches on the identity predicate"
if grep -q 'is-feature-test' "$MI_CONT"; then
  ok "$t"
else
  ng "$t" "mi-continue.md never calls todo.sh is-feature-test"
fi

t="mi-continue: the fork never calls blueprints.sh ensure-current"
if grep -qE 'never calls .*ensure-current' "$MI_CONT"; then
  ok "$t"
else
  ng "$t" "mi-continue.md does not state that the fork skips ensure-current"
fi

t="mi-continue: the fork resolves the union range"
if grep -q 'feature-test-range' "$MI_CONT"; then
  ok "$t"
else
  ng "$t" "mi-continue.md does not resolve the union range"
fi

t="mi-continue: the fork advances with advance-to 2 5"
if grep -qE 'advance-to 2 5' "$MI_CONT"; then
  ok "$t"
else
  ng "$t" "mi-continue.md does not use the atomic 2->5 transition"
fi

t="mi-continue: the 2->5 write sets implementation-completed"
# Tightened per review round 1: the original grep's second alternative
# (bare 'implementation-completed=true') already matched text elsewhere in
# the file (the Resume Handler's unrelated 3->5 transition), so it passed
# before the feature-test branch existed. Anchor on the actual advance-to 2 5
# invocation (line ends in a line-continuation backslash, distinguishing it
# from prose mentions of "advance-to 2 5") and require
# implementation-completed=true within that same call's continuation lines.
block="$(grep -A3 -E 'advance-to 2 5 \\$' "$MI_CONT")"
if printf '%s' "$block" | grep -q 'implementation-completed=true'; then
  ok "$t"
else
  ng "$t" "the advance-to 2 5 call does not set implementation-completed=true in the same call — resume-workflow would report state corruption"
fi

t="mi-continue: both the entry branch and the recovery branch exist"
n="$(grep -c 'is-feature-test' "$MI_CONT")"
if [[ "$n" -ge 2 ]]; then
  ok "$t"
else
  ng "$t" "expected >=2 is-feature-test call sites (Row A + recovery), found $n"
fi

t="mi-continue: states that ordinary features are unaffected"
if grep -qE 'falls through to today|unchanged for ordinary|ordinary features are unaffected|byte-identical' "$MI_CONT"; then
  ok "$t"
else
  ng "$t" "mi-continue.md does not record the ordinary-feature invariant at the fork"
fi

# ---- Task 6 review fix (finding 1): review.sh init for a feature-test entry -

# seed_history_requirements <sandbox> <feature> <id> — archived requirements.md
# at blueprints/history/v1/, alongside seed_history's change-summary. Real
# history rotation moves requirements.md straight into history/v<N>/ (not
# nested under implementation/) — see blueprints.sh rotate.
seed_history_requirements() {
  local dir="$1/workflow-stream/$2/blueprints/history/v1"
  mkdir -p "$dir"
  cat > "$dir/requirements.md" <<EOF
---
id: $3
---

# Requirements — $2
EOF
}

t="review.sh init: succeeds for a feature-test entry (no blueprints/current/)"
repo="$(make_git_repo)"; sandbox="$(make_quest)"; seed_todo "$sandbox"
c1="$(sha_of "$repo" c1)"; c2="$(sha_of "$repo" c2)"
req_id="44444444-4444-4444-8444-444444444444"
seed_history "$sandbox" payments "$c1" "$c2"
seed_history_requirements "$sandbox" payments "$req_id"
seed_completed "$sandbox" payments
if ( cd "$repo" && MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/review.sh" \
     init payments-feature-test ) >/dev/null 2>&1; then
  ok "$t"
else
  ng "$t" "review.sh init exited non-zero for a feature-test entry — this is the FTW-006 review Critical finding (init cannot run for a feature-test entry, stranding it in a non-progressing loop)"
fi

t="review.sh init: the feature-test result validates against review-file"
if fm_valid "$sandbox/workflow-stream/payments-feature-test/implementation/inspector-review.md" review-file; then
  ok "$t"
else
  ng "$t" "the initialized inspector-review.md failed review-file schema validation"
fi

t="review.sh init: the feature-test result carries requirements-ids (plural), not requirements-id"
ov="$sandbox/workflow-stream/payments-feature-test/implementation/inspector-review.md"
if grep -q "requirements-ids: \[$req_id\]" "$ov" && ! grep -q '^requirements-id:' "$ov"; then
  ok "$t"
else
  ng "$t" "expected requirements-ids: [$req_id] and no singular requirements-id"
fi

t="review.sh init: an ordinary feature still writes the singular requirements-id (unchanged)"
repo2="$(make_git_repo)"; sandbox2="$(make_quest)"; seed_todo_no_ft "$sandbox2"
mkdir -p "$sandbox2/workflow-stream/payments/blueprints/current"
cat > "$sandbox2/workflow-stream/payments/blueprints/current/requirements.md" <<EOF
---
id: 55555555-5555-4555-8555-555555555555
---

# Requirements — payments
EOF
( cd "$repo2" && MI_DATA_ROOT="$sandbox2" "$REPO_ROOT/scripts/review.sh" \
    init payments ) >/dev/null 2>&1
ov2="$sandbox2/workflow-stream/payments/implementation/inspector-review.md"
if grep -q '^requirements-id: 55555555-5555-4555-8555-555555555555$' "$ov2" && ! grep -q '^requirements-ids:' "$ov2"; then
  ok "$t"
else
  ng "$t" "ordinary review.sh init branch was disturbed by the feature-test fix"
fi

# ---- Task 7: mi-apply-impact refusal guard --------------------------------

MI_AI="$REPO_ROOT/commands/mi-apply-impact.md"

t="mi-apply-impact: guards on the identity predicate"
if grep -q 'is-feature-test' "$MI_AI"; then
  ok "$t"
else
  ng "$t" "mi-apply-impact.md has no feature-test guard"
fi

t="mi-apply-impact: the guard refuses before activating or ensuring current/"
if grep -qE 'before .*(activation|activate)|no activation, no ensure-current' "$MI_AI"; then
  ok "$t"
else
  ng "$t" "the guard does not state that it precedes activation"
fi

t="mi-apply-impact: the refusal points at /mi-continue"
if grep -q 'Type /mi-continue instead' "$MI_AI"; then
  ok "$t"
else
  ng "$t" "the refusal does not name the right command"
fi

# ---- Task 8: complete-feature diagrams ------------------------------------

MI_DIAG="$REPO_ROOT/commands/mi-generate-implementation-diagrams.md"

t="diagrams: detects the feature-test path"
if grep -q 'is-feature-test' "$MI_DIAG"; then
  ok "$t"
else
  ng "$t" "the command never detects a feature-test invocation"
fi

t="diagrams: uses the union range for a feature-test invocation"
if grep -q 'feature-test-range' "$MI_DIAG"; then
  ok "$t"
else
  ng "$t" "the command does not resolve the union range"
fi

t="diagrams: writes requirements-ids (plural) for a feature-test entry"
if grep -q 'requirements-ids' "$MI_DIAG"; then
  ok "$t"
else
  ng "$t" "the command does not write the plural requirements reference"
fi

t="diagrams: seeds from the ordinary features' archived blueprint diagrams"
if grep -qE 'history/v\[N\]/diagrams|archived .*blueprint diagram' "$MI_DIAG"; then
  ok "$t"
else
  ng "$t" "seeding source for a feature-test invocation is unstated"
fi

t="diagrams: states the larger cross-feature budget"
if grep -qE 'up to 5' "$MI_DIAG"; then
  ok "$t"
else
  ng "$t" "the enlarged sequence budget is not stated"
fi

t="diagrams: rejects sequences that redraw a single feature's own flow"
if grep -qE 'cross feature boundaries|must cross feature|re-draws one feature' "$MI_DIAG"; then
  ok "$t"
else
  ng "$t" "the cross-feature-only rule is not stated"
fi

t="diagrams: ordinary single-feature scoping is preserved"
if grep -qiE 'ordinary invocations are unchanged' "$MI_DIAG"; then
  ok "$t"
else
  ng "$t" "the ordinary-invocation invariant is not recorded"
fi

# ---- Summary --------------------------------------------------------------

printf "\n%d passed, %d failed\n" "$pass" "$fail"
if (( fail > 0 )); then
  printf "Failed: %s\n" "${fail_names[*]}" >&2
  exit 1
fi
exit 0
