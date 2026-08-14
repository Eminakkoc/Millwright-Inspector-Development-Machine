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

# ---- Summary --------------------------------------------------------------

printf "\n%d passed, %d failed\n" "$pass" "$fail"
if (( fail > 0 )); then
  printf "Failed: %s\n" "${fail_names[*]}" >&2
  exit 1
fi
exit 0
