#!/usr/bin/env bash
# run.sh — integration smoke tests for the v1.4 blueprint review refit.
#
# Each test exits 0 on PASS and a unique non-zero on FAIL so partial-suite
# results stay actionable. Tests are additive: later tasks append blocks
# under their own task headings.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="$TESTS_DIR/fixtures"

pass=0
fail=0
fail_names=()

ok() { printf "\xe2\x9c\x93 %s\n" "$1"; pass=$((pass + 1)); }
ng() { printf "\xe2\x9c\x97 %s\n   %s\n" "$1" "$2" >&2; fail=$((fail + 1)); fail_names+=("$1"); }

# ---- Task 2: review-history schema ----------------------------------------

t="schema: valid review-history frontmatter passes"
if "$REPO_ROOT/scripts/frontmatter.sh" validate \
   "$FIXTURES/schema-good/review-history.md" review-history >/dev/null 2>&1; then
  ok "$t"
else
  ng "$t" "expected validation to pass"
fi

t="schema: missing last-finding-id rejected"
if "$REPO_ROOT/scripts/frontmatter.sh" validate \
   "$FIXTURES/schema-bad-missing-counter/review-history.md" review-history >/dev/null 2>&1; then
  ng "$t" "expected validation to fail; it passed"
else
  ok "$t"
fi

t="schema: non-integer finding-count-total rejected"
if "$REPO_ROOT/scripts/frontmatter.sh" validate \
   "$FIXTURES/schema-bad-counts/review-history.md" review-history >/dev/null 2>&1; then
  ng "$t" "expected validation to fail; it passed"
else
  ok "$t"
fi

# ---- Task 3: init template ------------------------------------------------

t="template: init produces a schema-valid file"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if "$REPO_ROOT/scripts/frontmatter.sh" init review-history "$tmp/review-history.md" \
   ID=$(uuidgen | tr 'A-Z' 'a-z') \
   FEATURE=test-feat \
   REQUIREMENTS_ID=$(uuidgen | tr 'A-Z' 'a-z') \
   LAST_FINDING_ID=F-000 \
   FINDING_COUNT_TOTAL='!RAW!0' \
   FINDING_COUNT_UNRESOLVED='!RAW!0' \
   LAST_REVIEW_AT=2026-05-23T00:00:00Z \
   >/dev/null 2>&1; then
  if "$REPO_ROOT/scripts/frontmatter.sh" validate "$tmp/review-history.md" review-history >/dev/null 2>&1; then
    ok "$t"
  else
    ng "$t" "init produced an invalid file"
  fi
else
  ng "$t" "init invocation failed"
fi

t="template: body contains expected heading"
if grep -q "^# Review history" "$tmp/review-history.md" 2>/dev/null; then
  ok "$t"
else
  ng "$t" "missing '# Review history' heading"
fi

# ---- Summary --------------------------------------------------------------

printf "\n--- summary: %d pass, %d fail ---\n" "$pass" "$fail"
[[ ${#fail_names[@]} -eq 0 ]] || { printf "failed:\n%s\n" "$(printf '  - %s\n' "${fail_names[@]}")"; exit 1; }
exit 0
