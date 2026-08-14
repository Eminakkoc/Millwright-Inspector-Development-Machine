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

# ---- Summary --------------------------------------------------------------

printf "\n%d passed, %d failed\n" "$pass" "$fail"
if (( fail > 0 )); then
  printf "Failed: %s\n" "${fail_names[*]}" >&2
  exit 1
fi
exit 0
