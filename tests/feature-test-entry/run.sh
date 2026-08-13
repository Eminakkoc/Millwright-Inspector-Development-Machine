#!/usr/bin/env bash
# run.sh — integration tests for the feature-test queue entry (FTQ-001..008).
#
# Each test exits 0 on PASS and the suite exits 1 if any test failed.
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

# make_quest — create a sandbox data root with one active quest cycle.
# Prints the sandbox path on stdout. Callers pass MI_DATA_ROOT="$sandbox"
# to any script under test.
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

# quest_dir <sandbox> — path of the active cycle folder inside a sandbox.
quest_dir() { printf '%s/quest/2026-08-14-demo' "$1"; }

# ---- Task 1: schema -------------------------------------------------------

t="schema: todo-list with a valid feature-test field passes"
if "$REPO_ROOT/scripts/frontmatter.sh" validate \
   "$FIXTURES/schema-good/todo-list.md" todo-list >/dev/null 2>&1; then
  ok "$t"
else
  ng "$t" "valid feature-test field was rejected"
fi

t="schema: todo-list with a non-kebab feature-test value fails"
if "$REPO_ROOT/scripts/frontmatter.sh" validate \
   "$FIXTURES/schema-bad-pattern/todo-list.md" todo-list >/dev/null 2>&1; then
  ng "$t" "non-kebab feature-test value was accepted"
else
  ok "$t"
fi

t="schema: todo-list without a feature-test field still passes (back-compat)"
if "$REPO_ROOT/scripts/frontmatter.sh" validate \
   "$FIXTURES/schema-absent/todo-list.md" todo-list >/dev/null 2>&1; then
  ok "$t"
else
  ng "$t" "absent feature-test field was rejected — breaks every existing cycle file"
fi

t="schema: summary with a valid feature-test field passes"
if "$REPO_ROOT/scripts/frontmatter.sh" validate \
   "$FIXTURES/schema-good-summary/summary.md" summary >/dev/null 2>&1; then
  ok "$t"
else
  ng "$t" "valid feature-test field was rejected on summary"
fi

# ---- Summary --------------------------------------------------------------

printf "\n%d passed, %d failed\n" "$pass" "$fail"
if (( fail > 0 )); then
  printf "Failed: %s\n" "${fail_names[*]}" >&2
  exit 1
fi
exit 0
