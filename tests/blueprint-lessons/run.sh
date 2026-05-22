#!/usr/bin/env bash
# run.sh — integration smoke tests for the blueprint-lessons stage-2 injection.
#
# Each test exits 0 on PASS and a unique non-zero on FAIL so partial-suite
# results stay actionable. Tests are additive: later tasks append blocks to
# this file under their own task headings.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="$TESTS_DIR/fixtures"

pass=0
fail=0
fail_names=()

ok()   { printf "\xe2\x9c\x93 %s\n" "$1"; pass=$((pass + 1)); }
ng()   { printf "\xe2\x9c\x97 %s\n   %s\n" "$1" "$2" >&2; fail=$((fail + 1)); fail_names+=("$1"); }

# ---- Task 1: schema -------------------------------------------------------

t="schema: valid frontmatter passes validation"
if "$REPO_ROOT/scripts/frontmatter.sh" validate \
   "$FIXTURES/schema-good/blueprint-lessons.md" blueprint-lessons >/dev/null 2>&1; then
  ok "$t"
else
  ng "$t" "expected validation to pass"
fi

t="schema: missing selected-count rejected"
if "$REPO_ROOT/scripts/frontmatter.sh" validate \
   "$FIXTURES/schema-bad-missing-count/blueprint-lessons.md" blueprint-lessons >/dev/null 2>&1; then
  ng "$t" "expected validation to fail; it passed"
else
  ok "$t"
fi

t="schema: invalid feature pattern rejected"
if "$REPO_ROOT/scripts/frontmatter.sh" validate \
   "$FIXTURES/schema-bad-feature/blueprint-lessons.md" blueprint-lessons >/dev/null 2>&1; then
  ng "$t" "expected validation to fail; it passed"
else
  ok "$t"
fi

# ---- Task 2: template init -----------------------------------------------

t="template: init renders valid frontmatter with required tokens"
init_tmpdir="$(mktemp -d)"
init_dest="$init_tmpdir/blueprint-lessons.md"
if MI_PLUGIN_ROOT="$REPO_ROOT" "$REPO_ROOT/scripts/frontmatter.sh" init blueprint-lessons \
     "$init_dest" \
     "FEATURE=payments" \
     "LESSONS_SOURCE_MTIME=!RAW!1716336000" \
     "SELECTED_COUNT=!RAW!0" >/dev/null 2>&1; then
  if MI_PLUGIN_ROOT="$REPO_ROOT" "$REPO_ROOT/scripts/frontmatter.sh" validate \
       "$init_dest" blueprint-lessons >/dev/null 2>&1; then
    ok "$t"
  else
    ng "$t" "init wrote a file that fails schema validation"
  fi
else
  ng "$t" "init command itself failed"
fi
rm -rf "$init_tmpdir"

t="template: ## Selected lessons body is literally empty after init"
init_tmpdir="$(mktemp -d)"
init_dest="$init_tmpdir/blueprint-lessons.md"
MI_PLUGIN_ROOT="$REPO_ROOT" "$REPO_ROOT/scripts/frontmatter.sh" init blueprint-lessons \
  "$init_dest" \
  "FEATURE=payments" \
  "LESSONS_SOURCE_MTIME=!RAW!1716336000" \
  "SELECTED_COUNT=!RAW!0" >/dev/null 2>&1
# Extract everything after the `## Selected lessons` heading. Body must be
# whitespace-only.
body="$(awk '/^## Selected lessons$/{flag=1; next} flag' "$init_dest")"
if [[ -z "${body//[[:space:]]/}" ]]; then
  ok "$t"
else
  ng "$t" "expected empty body, found: $body"
fi
rm -rf "$init_tmpdir"

# ---- Summary --------------------------------------------------------------

printf "\n%d passed, %d failed\n" "$pass" "$fail"
if (( fail > 0 )); then
  printf "Failed: %s\n" "${fail_names[*]}" >&2
  exit 1
fi
exit 0
