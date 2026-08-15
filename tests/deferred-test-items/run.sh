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

# ---- Task 2: the helper ----------------------------------------------------

# seed_dt <sandbox> — render an empty deferred-tests.md. Prints its path.
seed_dt() {
  local sandbox dest
  sandbox="$1"
  dest="$sandbox/workflow-stream/payments-feature-test/test/deferred-tests.md"
  MI_DATA_ROOT="$sandbox" "$FM" init deferred-tests "$dest" \
    "FEATURE_TEST=payments-feature-test" \
    "QUEST_SLUG=2026-08-15-demo" \
    "CREATED_AT=2026-08-15T09:04:00Z" >/dev/null 2>&1
  printf '%s' "$dest"
}

# add_entry <sandbox> <feature> <scenario> <title>
add_entry() {
  MI_DATA_ROOT="$1" "$DT" upsert payments-feature-test \
    --feature "$2" --scenario "$3" --title "$4" \
    --reason "depends on a later feature" \
    --action "1. Do the thing" \
    --expected "- The thing happened" \
    --deferred-at "2026-08-15T10:22:11Z" >/dev/null 2>&1
}

t="count returns 0 when the file is absent"
sandbox="$(make_sandbox)"
got="$(MI_DATA_ROOT="$sandbox" "$DT" count payments-feature-test 2>&1)"
if [[ "$got" == "0" ]]; then ok "$t"; else ng "$t" "want 0, got '$got'"; fi

t="count returns 0 for a freshly rendered (empty) file"
# Regression pin: the template's entry-shape comment contains a worked example
# with a `###` line. An unscoped parser counts it as a real entry, and a phantom
# deferral would block the feature-test entry's completion forever.
sandbox="$(make_sandbox)"; seed_dt "$sandbox" >/dev/null
got="$(MI_DATA_ROOT="$sandbox" "$DT" count payments-feature-test 2>&1)"
if [[ "$got" == "0" ]]; then
  ok "$t"
else
  ng "$t" "want 0 for an empty artifact, got '$got' — the template's example is being parsed as an entry"
fi

t="list emits nothing for a freshly rendered (empty) file"
n="$(MI_DATA_ROOT="$sandbox" "$DT" list payments-feature-test 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "$n" == "0" ]]; then
  ok "$t"
else
  ng "$t" "want 0 rows for an empty artifact, got $n"
fi

t="the template's example heading is not at column 0"
if grep -qE '^### payments/B\.2' "$REPO_ROOT/templates/deferred-tests.md.tmpl"; then
  ng "$t" "the entry-shape example is at column 0 — indent it two spaces (belt-and-braces for the scoped parser)"
else
  ok "$t"
fi

t="the template's entry-shape comment sits above the Deferred scenarios heading"
cmt="$(grep -n 'ENTRY SHAPE' "$REPO_ROOT/templates/deferred-tests.md.tmpl" | head -1 | cut -d: -f1)"
hdg="$(grep -n '^## Deferred scenarios$' "$REPO_ROOT/templates/deferred-tests.md.tmpl" | head -1 | cut -d: -f1)"
if [[ -n "$cmt" && -n "$hdg" && "$cmt" -lt "$hdg" ]]; then
  ok "$t"
else
  ng "$t" "the comment must precede the heading (comment line=$cmt, heading line=$hdg)"
fi

t="upsert auto-creates the file when absent"
sandbox="$(make_sandbox)"
add_entry "$sandbox" payments B.2 "refund shows in the audit trail"
if [[ -f "$sandbox/workflow-stream/payments-feature-test/test/deferred-tests.md" ]]; then
  ok "$t"
else
  ng "$t" "upsert did not create the artifact"
fi

t="upsert twice on the same key produces one entry"
sandbox="$(make_sandbox)"; seed_dt "$sandbox" >/dev/null
add_entry "$sandbox" payments B.2 "first title"
add_entry "$sandbox" payments B.2 "second title"
got="$(MI_DATA_ROOT="$sandbox" "$DT" count payments-feature-test 2>&1)"
if [[ "$got" == "1" ]]; then ok "$t"; else ng "$t" "want 1 entry, got '$got'"; fi

t="upsert replaces the block rather than appending"
if MI_DATA_ROOT="$sandbox" "$DT" list payments-feature-test 2>/dev/null | grep -q 'second title' \
   && ! MI_DATA_ROOT="$sandbox" "$DT" list payments-feature-test 2>/dev/null | grep -q 'first title'; then
  ok "$t"
else
  ng "$t" "the replaced title is missing or the old one survived"
fi

t="upsert on two different keys produces two entries"
sandbox="$(make_sandbox)"; seed_dt "$sandbox" >/dev/null
add_entry "$sandbox" payments B.2 "refund audit"
add_entry "$sandbox" checkout A.4 "cart survives expiry"
got="$(MI_DATA_ROOT="$sandbox" "$DT" count payments-feature-test 2>&1)"
if [[ "$got" == "2" ]]; then ok "$t"; else ng "$t" "want 2, got '$got'"; fi

t="list emits TSV feature/scenario/merged-as/title"
row="$(MI_DATA_ROOT="$sandbox" "$DT" list payments-feature-test 2>/dev/null | head -1)"
f1="$(printf '%s' "$row" | cut -f1)"
f2="$(printf '%s' "$row" | cut -f2)"
f4="$(printf '%s' "$row" | cut -f4)"
if [[ "$f1" == "payments" && "$f2" == "B.2" && "$f4" == "refund audit" ]]; then
  ok "$t"
else
  ng "$t" "unexpected row: $(printf '%s' "$row" | tr '\t' '|')"
fi

t="merged-as is empty before the merge"
f3="$(printf '%s' "$row" | cut -f3)"
if [[ -z "$f3" ]]; then ok "$t"; else ng "$t" "want empty, got '$f3'"; fi

t="set-merged-as writes the back-reference"
MI_DATA_ROOT="$sandbox" "$DT" set-merged-as payments-feature-test payments B.2 C.1 >/dev/null 2>&1
f3="$(MI_DATA_ROOT="$sandbox" "$DT" list payments-feature-test 2>/dev/null | grep '^payments' | cut -f3)"
if [[ "$f3" == "C.1" ]]; then ok "$t"; else ng "$t" "want C.1, got '$f3'"; fi

t="re-deferring preserves an existing Merged as"
add_entry "$sandbox" payments B.2 "refund audit revised"
f3="$(MI_DATA_ROOT="$sandbox" "$DT" list payments-feature-test 2>/dev/null | grep '^payments' | cut -f3)"
if [[ "$f3" == "C.1" ]]; then
  ok "$t"
else
  ng "$t" "re-defer wiped the merge back-reference (want C.1, got '$f3')"
fi

t="remove drops exactly one entry"
MI_DATA_ROOT="$sandbox" "$DT" remove payments-feature-test payments B.2 >/dev/null 2>&1
got="$(MI_DATA_ROOT="$sandbox" "$DT" count payments-feature-test 2>&1)"
if [[ "$got" == "1" ]]; then ok "$t"; else ng "$t" "want 1 remaining, got '$got'"; fi

t="remove on a missing entry exits non-zero"
if MI_DATA_ROOT="$sandbox" "$DT" remove payments-feature-test payments B.2 >/dev/null 2>&1; then
  ng "$t" "remove succeeded on an absent entry"
else
  ok "$t"
fi

t="upsert output validates against the schema"
if "$FM" validate \
     "$sandbox/workflow-stream/payments-feature-test/test/deferred-tests.md" \
     deferred-tests >/dev/null 2>&1; then
  ok "$t"
else
  ng "$t" "the file no longer validates after mutation"
fi

t="multi-line action round-trips through the block scalar"
sandbox="$(make_sandbox)"; seed_dt "$sandbox" >/dev/null
MI_DATA_ROOT="$sandbox" "$DT" upsert payments-feature-test \
  --feature payments --scenario B.2 --title "multi" \
  --reason "later feature" \
  --action "1. First step
2. Second step" \
  --expected "- One
- Two" \
  --deferred-at "2026-08-15T10:22:11Z" >/dev/null 2>&1
dest="$sandbox/workflow-stream/payments-feature-test/test/deferred-tests.md"
if grep -q '^    2. Second step$' "$dest"; then
  ok "$t"
else
  ng "$t" "multi-line action was not indented into the block scalar"
fi

# ---- Task 3: Row A ensure-argument repair ----------------------------------

MI_CONTINUE="$REPO_ROOT/commands/mi-continue.md"

t="folder-id.sh ensure is invoked with a folder path, not a bare feature name"
if grep -qE 'folder-id\.sh" ensure "\$data_root/workflow-stream/\$ft_feature"|folder-id\.sh ensure "\$data_root/workflow-stream/\$ft_feature"' "$MI_CONTINUE"; then
  ok "$t"
else
  ng "$t" "mi-continue.md still passes a bare feature name to folder-id.sh ensure"
fi

t="no bare 'folder-id.sh ensure \"\$ft_feature\"' call survives"
if grep -qE 'folder-id\.sh ensure "\$ft_feature"' "$MI_CONTINUE"; then
  ng "$t" "the defective bare-name call is still present"
else
  ok "$t"
fi

t="folder-id.sh ensure dies on a bare feature name (the behaviour being guarded)"
sandbox="$(make_sandbox)"
if MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/folder-id.sh" ensure payments-feature-test >/dev/null 2>&1; then
  ng "$t" "ensure unexpectedly accepted a bare name — re-check the repair's premise"
else
  ok "$t"
fi

# ---- Task 4: stage-1.5 early creation --------------------------------------

# Behavioural: the creation sequence itself, run against a sandbox exactly as
# the recipe specifies it.
create_ft_folder() {
  local sandbox ft dir
  sandbox="$1"; ft="$2"
  dir="$sandbox/workflow-stream/$ft"
  mkdir -p "$dir/implementation" "$dir/test"
  MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/folder-id.sh" ensure "$dir" >/dev/null 2>&1
  MI_DATA_ROOT="$sandbox" "$DT" ensure "$ft" >/dev/null 2>&1
}

t="creation produces implementation/ and test/ and no blueprints/"
sandbox="$(make_sandbox)"
create_ft_folder "$sandbox" payments-feature-test
d="$sandbox/workflow-stream/payments-feature-test"
if [[ -d "$d/implementation" && -d "$d/test" && ! -d "$d/blueprints" ]]; then
  ok "$t"
else
  ng "$t" "wrong shape: implementation=$([[ -d $d/implementation ]] && echo y || echo n) test=$([[ -d $d/test ]] && echo y || echo n) blueprints=$([[ -d $d/blueprints ]] && echo y || echo n)"
fi

t="creation mints id.md"
if [[ -f "$d/id.md" ]]; then ok "$t"; else ng "$t" "id.md was not minted"; fi

t="creation renders deferred-tests.md"
if [[ -f "$d/test/deferred-tests.md" ]]; then ok "$t"; else ng "$t" "deferred-tests.md absent"; fi

t="re-running creation does not truncate a populated deferred-tests.md"
add_entry "$sandbox" payments B.2 "refund audit"
before="$(MI_DATA_ROOT="$sandbox" "$DT" count payments-feature-test)"
create_ft_folder "$sandbox" payments-feature-test
after="$(MI_DATA_ROOT="$sandbox" "$DT" count payments-feature-test)"
if [[ "$before" == "1" && "$after" == "1" ]]; then
  ok "$t"
else
  ng "$t" "entry count changed across a re-run: $before -> $after"
fi

t="aborting an ordinary feature leaves deferred-tests.md intact"
mkdir -p "$sandbox/workflow-stream/payments/implementation"
echo "review notes" > "$sandbox/workflow-stream/payments/implementation/inspector-review.md"
rm -rf "$sandbox/workflow-stream/payments/implementation"
after="$(MI_DATA_ROOT="$sandbox" "$DT" count payments-feature-test)"
if [[ "$after" == "1" ]]; then
  ok "$t"
else
  ng "$t" "an ordinary feature's implementation/ removal disturbed the entry count"
fi

# Prose: the recipe must carry the creation block and the link-feature call.
t="mi-continue.md Step 2A creates the feature-test folder at stage 1.5"
if grep -q 'deferred-tests.sh" ensure\|deferred-tests.sh ensure' "$MI_CONTINUE"; then
  ok "$t"
else
  ng "$t" "no stage-1.5 deferred-tests ensure call in mi-continue.md"
fi

t="mi-continue.md stage-1.5 creation calls link-feature"
if grep -q 'folder-id.sh link-feature' "$MI_CONTINUE"; then
  ok "$t"
else
  ng "$t" "link-feature is never called — derive-feature-test-name will rename the entry on a later cycle"
fi

t="project doc 3.4.1 documents deferred-tests.md under test/"
if grep -q 'deferred-tests.md' "$REPO_ROOT/docs/millwright-inspector-project.md"; then
  ok "$t"
else
  ng "$t" "3.4.1 folder tree does not list deferred-tests.md"
fi

# ---- Task 5: the deferred counter ------------------------------------------

MTR_SCHEMA="$REPO_ROOT/schemas/manual-test-results.schema.yaml"
MTR_TMPL="$REPO_ROOT/templates/manual-test-results.md.tmpl"
MI_MTR="$REPO_ROOT/commands/mi-manual-test-run.md"

t="results schema declares a deferred counter"
if grep -qE '^  deferred:' "$MTR_SCHEMA"; then
  ok "$t"
else
  ng "$t" "no 'deferred:' property in manual-test-results.schema.yaml"
fi

t="deferred is optional (absent from required:)"
if awk '/^required:/{f=1;next} /^[a-z]/{f=0} f' "$MTR_SCHEMA" | grep -q 'deferred'; then
  ng "$t" "deferred was added to required: — this invalidates every already-rendered results file"
else
  ok "$t"
fi

t="deferred declares default 0"
if awk '/^  deferred:/{f=1;next} /^  [a-z]/{f=0} f' "$MTR_SCHEMA" | grep -q 'default: 0'; then
  ok "$t"
else
  ng "$t" "deferred has no 'default: 0'"
fi

t="a results file WITHOUT deferred still validates"
sandbox="$(make_sandbox)"
old="$sandbox/old-results.md"
cat > "$old" <<'EOF'
---
id: 22222222-2222-4222-8222-222222222222
feature: payments
plan-id: 33333333-3333-4333-8333-333333333333
seed-family-id: 44444444-4444-4444-8444-444444444444
generated-in-activation: 55555555-5555-4555-8555-555555555555
state: in-progress
current-scenario: null
total: 3
passed: 0
failed: 0
skipped: 0
started-at: "2026-08-15T09:00:00Z"
finished-at: null
---

# old
EOF
if "$FM" validate "$old" manual-test-results >/dev/null 2>&1; then
  ok "$t"
else
  ng "$t" "back-compat broken: a pre-existing results file no longer validates"
fi

t="a results file WITH deferred validates"
new="$sandbox/new-results.md"
sed 's/^skipped: 0$/skipped: 0\ndeferred: 1/' "$old" > "$new"
if "$FM" validate "$new" manual-test-results >/dev/null 2>&1; then
  ok "$t"
else
  ng "$t" "schema rejects the new deferred key"
fi

t="results template carries deferred: 0"
if grep -q '^deferred: 0$' "$MTR_TMPL"; then
  ok "$t"
else
  ng "$t" "manual-test-results.md.tmpl does not render deferred: 0"
fi

t="the counter identity is stated in the runner"
if grep -q 'passed + failed + skipped + deferred == total' "$MI_MTR"; then
  ok "$t"
else
  ng "$t" "the four-term counter identity is not written down in mi-manual-test-run.md"
fi

t="all three recompute sites mention deferred"
n="$(grep -c 'deferred' "$MI_MTR")"
if [[ "$n" -ge 6 ]]; then
  ok "$t"
else
  ng "$t" "expected >=6 'deferred' mentions across recompute sites and roll-ups, found $n"
fi

# ---- Summary --------------------------------------------------------------

printf "\n%d passed, %d failed\n" "$pass" "$fail"
if (( fail > 0 )); then
  printf "Failed: %s\n" "${fail_names[*]}" >&2
  exit 1
fi
exit 0
