#!/usr/bin/env bash
# run.sh — tests for the deferred-test-items feature (DTI-001..008).
#
# Each test prints PASS/FAIL; the suite exits 1 if any test failed.
# Tests are additive: later tasks append blocks under their own task headings.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

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

# make_sandbox — data root with one active quest cycle. Prints its path.
make_sandbox() {
  local sandbox slug
  sandbox="$(mktemp -d)"
  slug="2026-08-15-demo"
  mkdir -p "$sandbox/quest/$slug"
  cat > "$sandbox/quest/active.md" <<EOF
---
slug: $slug
started: "2026-08-15"
journal-folders: [demo]
status: active
---

# Active quest pointer
EOF
  SANDBOXES+=("$sandbox")
  printf '%s' "$sandbox"
}

DT="$REPO_ROOT/scripts/deferred-tests.sh"
BP="$REPO_ROOT/scripts/blueprints.sh"
FM="$REPO_ROOT/scripts/frontmatter.sh"

# ---- Task 1: artifact registration ----------------------------------------

t="blueprints.sh deferred-tests-path resolves under test/"
sandbox="$(make_sandbox)"
got="$(MI_DATA_ROOT="$sandbox" "$BP" deferred-tests-path payments-feature-test 2>&1)"
want="$sandbox/workflow-stream/payments-feature-test/test/deferred-tests.md"
if [[ "$got" == "$want" ]]; then
  ok "$t"
else
  ng "$t" "want $want, got $got"
fi

t="blueprints.sh usage string lists deferred-tests-path"
usage_output="$("$BP" bogus-subcommand 2>&1)"
if [[ "$usage_output" == *deferred-tests-path* ]]; then
  ok "$t"
else
  ng "$t" "usage string does not mention deferred-tests-path"
fi

t="frontmatter.sh init deferred-tests renders and validates"
sandbox="$(make_sandbox)"
dest="$sandbox/workflow-stream/payments-feature-test/test/deferred-tests.md"
if MI_DATA_ROOT="$sandbox" "$FM" init deferred-tests "$dest" \
     "FEATURE_TEST=payments-feature-test" \
     "QUEST_SLUG=2026-08-15-demo" \
     "CREATED_AT=2026-08-15T09:04:00Z" >/dev/null 2>&1; then
  ok "$t"
else
  ng "$t" "init failed (init self-validates, so this covers validate too)"
fi

t="rendered deferred-tests.md leaves no unsubstituted placeholders"
if [[ -f "$dest" ]] && ! grep -q '{{' "$dest"; then
  ok "$t"
else
  ng "$t" "file missing or contains a literal {{TOKEN}}"
fi

t="rendered deferred-tests.md has the Deferred scenarios heading"
if [[ -f "$dest" ]] && grep -q '^## Deferred scenarios$' "$dest"; then
  ok "$t"
else
  ng "$t" "## Deferred scenarios heading absent"
fi

t="schema rejects an unknown frontmatter key"
sandbox="$(make_sandbox)"
bad="$sandbox/bad.md"
mkdir -p "$(dirname "$bad")"
cat > "$bad" <<'EOF'
---
id: 11111111-1111-4111-8111-111111111111
feature-test: payments-feature-test
quest-slug: 2026-08-15-demo
created-at: "2026-08-15T09:04:00Z"
bogus: nope
---

# x
EOF
if "$FM" validate "$bad" deferred-tests >/dev/null 2>&1; then
  ng "$t" "validate accepted an unknown key (additionalProperties must be false)"
else
  ok "$t"
fi

# ---- Summary --------------------------------------------------------------

printf "\n%d passed, %d failed\n" "$pass" "$fail"
if (( fail > 0 )); then
  printf "Failed: %s\n" "${fail_names[*]}" >&2
  exit 1
fi
exit 0
