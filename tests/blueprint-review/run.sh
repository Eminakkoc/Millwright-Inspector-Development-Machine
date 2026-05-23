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

# ---- Task 4: hook validation ----------------------------------------------

# The hook reads JSON from stdin (Claude Code's tool-input shape) and gates on
# the file path containing the configured data-root segment (default
# `millwright-inspector`). We construct a path that satisfies both conditions.

t="hook: review-history.md path triggers schema validation"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/millwright-inspector/workflow-stream/test-feat/blueprints/current"
cp "$FIXTURES/schema-bad-counts/review-history.md" \
   "$tmp/millwright-inspector/workflow-stream/test-feat/blueprints/current/review-history.md"
target="$tmp/millwright-inspector/workflow-stream/test-feat/blueprints/current/review-history.md"
hook_json="$(printf '{"tool_input":{"file_path":"%s"}}' "$target")"
if CLAUDE_PLUGIN_ROOT="$REPO_ROOT" printf '%s' "$hook_json" \
   | bash "$REPO_ROOT/hooks/validate-on-write.sh" >/dev/null 2>&1; then
  ng "$t" "expected hook to block on bad review-history; it passed"
else
  ok "$t"
fi

t="hook: review-history.md outside data-root is no-op"
mkdir -p "$tmp/not-mi-root/blueprints/current"
cp "$FIXTURES/schema-bad-counts/review-history.md" \
   "$tmp/not-mi-root/blueprints/current/review-history.md"
outside_target="$tmp/not-mi-root/blueprints/current/review-history.md"
hook_json2="$(printf '{"tool_input":{"file_path":"%s"}}' "$outside_target")"
if CLAUDE_PLUGIN_ROOT="$REPO_ROOT" printf '%s' "$hook_json2" \
   | bash "$REPO_ROOT/hooks/validate-on-write.sh" >/dev/null 2>&1; then
  ok "$t"
else
  ng "$t" "expected hook to skip non-data-root paths"
fi

# ---- Task 5: build-summary ------------------------------------------------

t="build-summary: empty history returns empty output"
out="$("$REPO_ROOT/scripts/blueprint-review.sh" build-summary \
       "$FIXTURES/summary-empty/review-history.md" consistency 2>/dev/null || true)"
if [[ -z "$out" ]]; then ok "$t"; else ng "$t" "expected empty, got: $out"; fi

t="build-summary: unresolved-only renders all unresolved"
out="$("$REPO_ROOT/scripts/blueprint-review.sh" build-summary \
       "$FIXTURES/summary-unresolved-only/review-history.md" consistency 2>/dev/null)"
if grep -q "F-001" <<<"$out" && grep -q "F-002" <<<"$out" && grep -q "Currently unresolved" <<<"$out"; then
  ok "$t"
else
  ng "$t" "missing expected ids or heading"
fi

t="build-summary: mixed renders both unresolved and resolved sections"
out="$("$REPO_ROOT/scripts/blueprint-review.sh" build-summary \
       "$FIXTURES/summary-mixed/review-history.md" consistency 2>/dev/null)"
if grep -q "Currently unresolved" <<<"$out" \
   && grep -q "Recently resolved" <<<"$out" \
   && grep -q "F-002" <<<"$out" \
   && grep -q "F-001" <<<"$out"; then
  ok "$t"
else
  ng "$t" "missing one of the expected sections / ids"
fi

t="build-summary: batch filter scopes to named items"
out="$("$REPO_ROOT/scripts/blueprint-review.sh" build-summary \
       "$FIXTURES/summary-mixed/review-history.md" batch \
       --scope-id PAY-001 --scope-id PAY-002 2>/dev/null)"
# PAY-003 finding should be filtered out; PAY-001 + PAY-002 + file-level kept.
if ! grep -q "F-003" <<<"$out" \
   && grep -q "F-001" <<<"$out" \
   && grep -q "F-002" <<<"$out"; then
  ok "$t"
else
  ng "$t" "expected F-001/F-002/F-004 kept, F-003 filtered"
fi

t="build-summary: oversize history truncates to budget"
out="$("$REPO_ROOT/scripts/blueprint-review.sh" build-summary \
       "$FIXTURES/summary-oversize/review-history.md" consistency 2>/dev/null)"
# Rough check: output stays under 8000 characters (~1500 tokens × ~5 chars/token + scaffold)
if [[ ${#out} -lt 8000 ]]; then ok "$t"; else ng "$t" "exceeded 8000 chars (${#out})"; fi

# ---- Task 6: persist-findings ---------------------------------------------

t="persist: append new finding bumps last-finding-id"
tmp_p="$(mktemp -d)"
trap 'rm -rf "$tmp_p"' EXIT
cp "$FIXTURES/summary-mixed/review-history.md" "$tmp_p/h.md"
"$REPO_ROOT/scripts/blueprint-review.sh" persist-findings "$tmp_p/h.md" \
   "$FIXTURES/persist-input.json" >/dev/null 2>&1
lid="$("$REPO_ROOT/scripts/frontmatter.sh" get "$tmp_p/h.md" last-finding-id 2>/dev/null)"
if [[ "$lid" == "F-005" ]]; then ok "$t"; else ng "$t" "expected F-005 got $lid"; fi

t="persist: status update flips F-002 to resolved"
# awk extracts the F-002 section (between '## F-002' and the next '## ' heading)
section_002="$(awk '/^## F-002/{flag=1;next} /^## /{flag=0} flag' "$tmp_p/h.md")"
if grep -q 'last-status: resolved' <<<"$section_002"; then
  ok "$t"
else
  ng "$t" "F-002 not marked resolved"
fi

t="persist: dropped status flips F-001 to dropped (was resolved)"
section_001="$(awk '/^## F-001/{flag=1;next} /^## /{flag=0} flag' "$tmp_p/h.md")"
if grep -q 'last-status: dropped' <<<"$section_001"; then
  ok "$t"
else
  ng "$t" "F-001 not marked dropped"
fi

t="persist: finding-count-total recomputed"
total="$("$REPO_ROOT/scripts/frontmatter.sh" get "$tmp_p/h.md" finding-count-total 2>/dev/null)"
if [[ "$total" == "5" ]]; then ok "$t"; else ng "$t" "expected 5 got $total"; fi

t="persist: finding-count-unresolved recomputed"
unr="$("$REPO_ROOT/scripts/frontmatter.sh" get "$tmp_p/h.md" finding-count-unresolved 2>/dev/null)"
if [[ "$unr" == "2" ]]; then ok "$t"; else ng "$t" "expected 2 got $unr"; fi

# ---- Summary --------------------------------------------------------------

printf "\n--- summary: %d pass, %d fail ---\n" "$pass" "$fail"
[[ ${#fail_names[@]} -eq 0 ]] || { printf "failed:\n%s\n" "$(printf '  - %s\n' "${fail_names[@]}")"; exit 1; }
exit 0
