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

# ---- Task 2: derive-feature-test-name -------------------------------------

t="derive: base case appends -feature-test to the first feature"
sandbox="$(make_quest)"
out="$(MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/folder-id.sh" \
       derive-feature-test-name payments audit-log 2>/dev/null || true)"
if [[ "$out" == "payments-feature-test" ]]; then
  ok "$t"
else
  ng "$t" "expected 'payments-feature-test', got '$out'"
fi

t="derive: collision with an ordinary feature name appends an ordinal"
sandbox="$(make_quest)"
out="$(MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/folder-id.sh" \
       derive-feature-test-name payments payments-feature-test 2>/dev/null || true)"
if [[ "$out" == "payments-feature-test-2" ]]; then
  ok "$t"
else
  ng "$t" "expected 'payments-feature-test-2', got '$out'"
fi

t="derive: an ordinal retry emits a rename note on stderr"
sandbox="$(make_quest)"
err="$(MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/folder-id.sh" \
       derive-feature-test-name payments payments-feature-test 2>&1 >/dev/null || true)"
if [[ "$err" == *"payments-feature-test-2"* ]]; then
  ok "$t"
else
  ng "$t" "stderr did not mention the replacement name: '$err'"
fi

t="derive: the base case emits no rename note"
sandbox="$(make_quest)"
err="$(MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/folder-id.sh" \
       derive-feature-test-name payments audit-log 2>&1 >/dev/null || true)"
if [[ -z "$err" ]]; then
  ok "$t"
else
  ng "$t" "expected empty stderr, got '$err'"
fi

t="derive: refuses fewer than two ordinary features (FTQ-007 guard)"
sandbox="$(make_quest)"
if MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/folder-id.sh" \
   derive-feature-test-name payments >/dev/null 2>&1; then
  ng "$t" "single-feature invocation was accepted — FTQ-007 violation would be silent"
else
  ok "$t"
fi

t="derive: lineage collision with an existing feature folder appends an ordinal"
sandbox="$(make_quest)"
mkdir -p "$sandbox/workflow-stream/payments-feature-test"
cat > "$sandbox/workflow-stream/payments-feature-test/id.md" <<'EOF'
---
id: 55555555-5555-4555-8555-555555555555
kind: feature
---

# Folder id
EOF
out="$(MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/folder-id.sh" \
       derive-feature-test-name payments audit-log 2>/dev/null || true)"
if [[ "$out" == "payments-feature-test-2" ]]; then
  ok "$t"
else
  ng "$t" "expected 'payments-feature-test-2' after lineage collision, got '$out'"
fi

# ---- Task 3: set-state --assignee -----------------------------------------

# seed_todo <sandbox> — write a two-section todo-list.md with a feature-test
# section into the sandbox's active cycle. Body only; frontmatter is minimal
# but schema-valid.
seed_todo() {
  local sandbox="$1"
  cat > "$(quest_dir "$sandbox")/todo-list.md" <<'EOF'
---
id: 66666666-6666-4666-8666-666666666666
related-features: [payments, audit-log, payments-feature-test]
description: Seed cycle for feature-test tests.
feature-test: payments-feature-test
---

# Todo list

## payments

- [ ] TODO — PAY-001: first payment item
- [ ] TODO — PAY-002: second payment item

## audit-log

- [ ] TODO — AUD-001: first audit item

## payments-feature-test

- [ ] TODO — FT-001: test the whole feature implementation
EOF
}

t="set-state --assignee: sets the tag on a previously unassigned line"
sandbox="$(make_quest)"; seed_todo "$sandbox"
MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/todo.sh" \
  set-state FT-001 PENDING --assignee emin >/dev/null 2>&1
line="$(grep -- 'FT-001' "$(quest_dir "$sandbox")/todo-list.md")"
if [[ "$line" == "- [x] (emin) PENDING — FT-001: test the whole feature implementation" ]]; then
  ok "$t"
else
  ng "$t" "unexpected line: '$line'"
fi

t="set-state --assignee: overrides an existing assignee"
sandbox="$(make_quest)"; seed_todo "$sandbox"
MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/todo.sh" \
  set-state FT-001 PENDING --assignee alice >/dev/null 2>&1
MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/todo.sh" \
  set-state FT-001 PENDING --assignee bob >/dev/null 2>&1
line="$(grep -- 'FT-001' "$(quest_dir "$sandbox")/todo-list.md")"
if [[ "$line" == *"(bob)"* ]]; then
  ok "$t"
else
  ng "$t" "expected assignee bob, got: '$line'"
fi

t="set-state without --assignee preserves the existing tag (unchanged behaviour)"
sandbox="$(make_quest)"; seed_todo "$sandbox"
MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/todo.sh" \
  set-state PAY-001 PENDING --assignee emin >/dev/null 2>&1
MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/todo.sh" \
  set-state PAY-001 IMPLEMENTING >/dev/null 2>&1
line="$(grep -- 'PAY-001' "$(quest_dir "$sandbox")/todo-list.md")"
if [[ "$line" == "- [x] (emin) IMPLEMENTING — PAY-001: first payment item" ]]; then
  ok "$t"
else
  ng "$t" "unexpected line: '$line'"
fi

t="set-state without --assignee on an unassigned line stays unassigned"
sandbox="$(make_quest)"; seed_todo "$sandbox"
MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/todo.sh" \
  set-state PAY-002 IMPLEMENTING >/dev/null 2>&1
line="$(grep -- 'PAY-002' "$(quest_dir "$sandbox")/todo-list.md")"
if [[ "$line" == "- [x] IMPLEMENTING — PAY-002: second payment item" ]]; then
  ok "$t"
else
  ng "$t" "unexpected line: '$line'"
fi

t="set-state: unknown flag is refused"
sandbox="$(make_quest)"; seed_todo "$sandbox"
if MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/todo.sh" \
   set-state PAY-001 PENDING --bogus x >/dev/null 2>&1; then
  ng "$t" "unknown flag was accepted"
else
  ok "$t"
fi

# ---- Task 4: pend-selected stdout -----------------------------------------

t="pend-selected: emits one TSV row per promoted item, in document order"
sandbox="$(make_quest)"
cat > "$(quest_dir "$sandbox")/todo-list.md" <<'EOF'
---
id: 77777777-7777-4777-8777-777777777777
related-features: [payments, audit-log]
description: Two marked items with different assignees.
---

# Todo list

## payments

- [x] (alice) TODO — PAY-001: first payment item

## audit-log

- [x] (bob) TODO — AUD-001: first audit item
EOF
out="$(MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/todo.sh" pend-selected 2>/dev/null)"
expected="$(printf 'PAY-001\talice\nAUD-001\tbob')"
if [[ "$out" == "$expected" ]]; then
  ok "$t"
else
  ng "$t" "expected '$expected', got '$out'"
fi

t="pend-selected: stderr summary line is unchanged"
sandbox="$(make_quest)"
cat > "$(quest_dir "$sandbox")/todo-list.md" <<'EOF'
---
id: 88888888-8888-4888-8888-888888888888
related-features: [payments]
description: One marked item.
---

# Todo list

## payments

- [x] (alice) TODO — PAY-001: first payment item
EOF
err="$(MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/todo.sh" pend-selected 2>&1 >/dev/null)"
if [[ "$err" == *"transitioned 1 inspector-selected items from TODO to PENDING"* ]]; then
  ok "$t"
else
  ng "$t" "stderr summary changed: '$err'"
fi

t="pend-selected: emits no rows when nothing was marked"
sandbox="$(make_quest)"
cat > "$(quest_dir "$sandbox")/todo-list.md" <<'EOF'
---
id: 99999999-9999-4999-8999-999999999999
related-features: [payments]
description: Nothing marked.
---

# Todo list

## payments

- [ ] TODO — PAY-001: first payment item
EOF
out="$(MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/todo.sh" pend-selected 2>/dev/null)"
if [[ -z "$out" ]]; then
  ok "$t"
else
  ng "$t" "expected empty stdout, got '$out'"
fi

t="pend-selected: still refuses a marked item with no assignee"
sandbox="$(make_quest)"
cat > "$(quest_dir "$sandbox")/todo-list.md" <<'EOF'
---
id: aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
related-features: [payments]
description: Marked but unassigned.
---

# Todo list

## payments

- [x] TODO — PAY-001: first payment item
EOF
if MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/todo.sh" pend-selected >/dev/null 2>&1; then
  ng "$t" "unassigned marked item was accepted"
else
  ok "$t"
fi

# ---- Task 5: feature-test-status ------------------------------------------

# ft_status <sandbox> — print the status row.
ft_status() { MI_DATA_ROOT="$1" "$REPO_ROOT/scripts/todo.sh" feature-test-status 2>/dev/null; }
# field <row> <n> — extract the nth tab-separated field.
field() { printf '%s' "$1" | cut -f"$2"; }

t="feature-test-status: 'none' when the frontmatter field is absent"
sandbox="$(make_quest)"
cat > "$(quest_dir "$sandbox")/todo-list.md" <<'EOF'
---
id: bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
related-features: [payments]
description: Single-feature cycle.
---

# Todo list

## payments

- [ ] TODO — PAY-001: first payment item
EOF
row="$(ft_status "$sandbox")"
if [[ "$(field "$row" 1)" == "none" ]]; then
  ok "$t"
else
  ng "$t" "expected 'none', got '$(field "$row" 1)'"
fi

t="feature-test-status: 'blocked' with a count while ordinary [ ] items remain"
sandbox="$(make_quest)"; seed_todo "$sandbox"
row="$(ft_status "$sandbox")"
if [[ "$(field "$row" 1)" == "blocked" && "$(field "$row" 4)" == "3" ]]; then
  ok "$t"
else
  ng "$t" "expected 'blocked' with count 3, got '$(field "$row" 1)'/'$(field "$row" 4)'"
fi

t="feature-test-status: reports the ft name and item id"
sandbox="$(make_quest)"; seed_todo "$sandbox"
row="$(ft_status "$sandbox")"
if [[ "$(field "$row" 2)" == "payments-feature-test" && "$(field "$row" 3)" == "FT-001" ]]; then
  ok "$t"
else
  ng "$t" "expected name/id 'payments-feature-test'/'FT-001', got '$(field "$row" 2)'/'$(field "$row" 3)'"
fi

t="feature-test-status: 'ready' once every ordinary item is selected"
sandbox="$(make_quest)"; seed_todo "$sandbox"
for id in PAY-001 PAY-002 AUD-001; do
  MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/todo.sh" \
    set-state "$id" PENDING --assignee emin >/dev/null 2>&1
done
row="$(ft_status "$sandbox")"
if [[ "$(field "$row" 1)" == "ready" && "$(field "$row" 4)" == "0" ]]; then
  ok "$t"
else
  ng "$t" "expected 'ready' with count 0, got '$(field "$row" 1)'/'$(field "$row" 4)'"
fi

t="feature-test-status: CANCELED resolves an item (escape hatch)"
sandbox="$(make_quest)"; seed_todo "$sandbox"
MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/todo.sh" \
  set-state PAY-001 PENDING --assignee emin >/dev/null 2>&1
MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/todo.sh" \
  set-state PAY-002 CANCELED --assignee emin >/dev/null 2>&1
MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/todo.sh" \
  set-state AUD-001 CANCELED --assignee emin >/dev/null 2>&1
row="$(ft_status "$sandbox")"
if [[ "$(field "$row" 1)" == "ready" ]]; then
  ok "$t"
else
  ng "$t" "CANCELED did not resolve items; got '$(field "$row" 1)'"
fi

t="feature-test-status: 'premature' when marked by hand while items remain"
sandbox="$(make_quest)"; seed_todo "$sandbox"
MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/todo.sh" \
  set-state FT-001 PENDING --assignee emin >/dev/null 2>&1
row="$(ft_status "$sandbox")"
if [[ "$(field "$row" 1)" == "premature" ]]; then
  ok "$t"
else
  ng "$t" "expected 'premature', got '$(field "$row" 1)'"
fi

t="feature-test-status: 'selected' once promoted with no ordinary items left"
sandbox="$(make_quest)"; seed_todo "$sandbox"
for id in PAY-001 PAY-002 AUD-001 FT-001; do
  MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/todo.sh" \
    set-state "$id" PENDING --assignee emin >/dev/null 2>&1
done
row="$(ft_status "$sandbox")"
if [[ "$(field "$row" 1)" == "selected" ]]; then
  ok "$t"
else
  ng "$t" "expected 'selected', got '$(field "$row" 1)'"
fi

t="feature-test-status: fallback assignee is the last [x] ordinary line"
sandbox="$(make_quest)"; seed_todo "$sandbox"
MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/todo.sh" \
  set-state PAY-001 PENDING --assignee alice >/dev/null 2>&1
MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/todo.sh" \
  set-state AUD-001 PENDING --assignee bob >/dev/null 2>&1
row="$(ft_status "$sandbox")"
if [[ "$(field "$row" 5)" == "bob" ]]; then
  ok "$t"
else
  ng "$t" "expected fallback 'bob', got '$(field "$row" 5)'"
fi

t="feature-test-status: writes no files"
sandbox="$(make_quest)"; seed_todo "$sandbox"
before="$(shasum -a 256 "$(quest_dir "$sandbox")/todo-list.md" | cut -d' ' -f1)"
ft_status "$sandbox" >/dev/null
after="$(shasum -a 256 "$(quest_dir "$sandbox")/todo-list.md" | cut -d' ' -f1)"
if [[ "$before" == "$after" ]]; then
  ok "$t"
else
  ng "$t" "todo-list.md was modified by a read-only predicate"
fi

# ---- Task 6: check-feature-test-pin ---------------------------------------

t="check-pin: exits 0 when the feature-test entry is last"
if "$REPO_ROOT/scripts/progress.sh" check-feature-test-pin \
   payments-feature-test payments audit-log payments-feature-test >/dev/null 2>&1; then
  ok "$t"
else
  ng "$t" "rejected a correctly pinned order"
fi

t="check-pin: exits 0 when the feature-test entry is absent from the order"
if "$REPO_ROOT/scripts/progress.sh" check-feature-test-pin \
   payments-feature-test payments audit-log >/dev/null 2>&1; then
  ok "$t"
else
  ng "$t" "rejected an order that contains nothing to pin"
fi

t="check-pin: exits 3 when the feature-test entry is not last"
"$REPO_ROOT/scripts/progress.sh" check-feature-test-pin \
  payments-feature-test payments payments-feature-test audit-log >/dev/null 2>&1
rc=$?
if [[ "$rc" -eq 3 ]]; then
  ok "$t"
else
  ng "$t" "expected exit 3, got $rc"
fi

t="check-pin: names the displacing feature in its error message"
err="$("$REPO_ROOT/scripts/progress.sh" check-feature-test-pin \
       payments-feature-test payments payments-feature-test audit-log 2>&1 >/dev/null || true)"
if [[ "$err" == *"audit-log"* ]]; then
  ok "$t"
else
  ng "$t" "error did not name the displacing feature: '$err'"
fi

t="check-pin: writes nothing to stdout on success"
out="$("$REPO_ROOT/scripts/progress.sh" check-feature-test-pin \
       payments-feature-test payments payments-feature-test 2>/dev/null || true)"
if [[ -z "$out" ]]; then
  ok "$t"
else
  ng "$t" "expected empty stdout, got '$out'"
fi

t="check-pin: refuses an empty order"
if "$REPO_ROOT/scripts/progress.sh" check-feature-test-pin \
   payments-feature-test >/dev/null 2>&1; then
  ng "$t" "empty order was accepted"
else
  ok "$t"
fi

# ---- Task 7: mi-run stage-1 emission --------------------------------------

MI_RUN="$REPO_ROOT/commands/mi-run.md"

t="mi-run: Step 3 calls derive-feature-test-name"
if grep -q 'derive-feature-test-name' "$MI_RUN"; then
  ok "$t"
else
  ng "$t" "mi-run.md never invokes derive-feature-test-name"
fi

t="mi-run: gates emission on two-or-more ordinary features"
if grep -qE 'count\(ordinary features\) >= 2|>= 2 ordinary features|two or more' "$MI_RUN"; then
  ok "$t"
else
  ng "$t" "mi-run.md does not state the >= 2 gate"
fi

t="mi-run: writes the feature-test frontmatter field via frontmatter.sh set"
if grep -qF 'feature-test "$ft_name"' "$MI_RUN"; then
  ok "$t"
else
  ng "$t" "mi-run.md does not set the feature-test field"
fi

t="mi-run: emits the FT-001 item"
if grep -q 'FT-001: test the whole feature implementation' "$MI_RUN"; then
  ok "$t"
else
  ng "$t" "mi-run.md does not show the FT-001 item line"
fi

t="mi-run: documents the FT prefix fallback"
if grep -qE 'FT2-001' "$MI_RUN"; then
  ok "$t"
else
  ng "$t" "mi-run.md does not document the FT2-001 prefix fallback"
fi

t="mi-run: Step 5 withholds the feature-test name from progress.sh init"
if grep -qE 'only the ordinary features|ordinary features only' "$MI_RUN"; then
  ok "$t"
else
  ng "$t" "mi-run.md Step 5 does not say the feature-test name is withheld from init"
fi

t="mi-run: hand-off tells the inspector not to mark the entry"
if grep -qE 'leave this item unmarked|must not be marked|do not mark' "$MI_RUN"; then
  ok "$t"
else
  ng "$t" "mi-run.md hand-off does not tell the inspector to leave the entry alone"
fi

t="mi-run: documents the CANCELED escape hatch"
if grep -q 'set-state <id> CANCELED' "$MI_RUN"; then
  ok "$t"
else
  ng "$t" "mi-run.md does not document the cancel escape hatch"
fi

t="mi-run: states single-feature cycles emit nothing (FTQ-007)"
if grep -qE 'single-feature cycle .*(no|nothing)|exactly one feature.*no feature-test' "$MI_RUN"; then
  ok "$t"
else
  ng "$t" "mi-run.md does not state the single-feature no-op"
fi

# ---- Task 8: mi-continue stage-1.5 ----------------------------------------

MI_CONT="$REPO_ROOT/commands/mi-continue.md"

t="mi-continue: Step 2A calls feature-test-status"
if grep -q 'feature-test-status' "$MI_CONT"; then
  ok "$t"
else
  ng "$t" "mi-continue.md never invokes feature-test-status"
fi

t="mi-continue: promotes with set-state --assignee"
if grep -qE 'set-state .*PENDING --assignee' "$MI_CONT"; then
  ok "$t"
else
  ng "$t" "mi-continue.md does not promote the entry with an inherited assignee"
fi

t="mi-continue: reverts a prematurely marked entry"
if grep -q 'premature' "$MI_CONT"; then
  ok "$t"
else
  ng "$t" "mi-continue.md does not handle the premature status"
fi

t="mi-continue: appends the entry via progress.sh enqueue"
if grep -qE 'enqueue "\$ft_name"' "$MI_CONT"; then
  ok "$t"
else
  ng "$t" "mi-continue.md does not enqueue the feature-test name"
fi

t="mi-continue: excludes the entry from the mid-cycle ordinary enqueue"
if grep -qE 'excluding .*ft_name|exclude .*ft_name' "$MI_CONT"; then
  ok "$t"
else
  ng "$t" "mi-continue.md does not exclude ft_name from the ordinary enqueue"
fi

t="mi-continue: validates the pin in both Step 2A and Step 2B"
n="$(grep -c 'check-feature-test-pin' "$MI_CONT")"
if [[ "$n" -ge 2 ]]; then
  ok "$t"
else
  ng "$t" "expected >=2 check-feature-test-pin call sites, found $n"
fi

t="mi-continue: excludes the entry from dependency analysis"
if grep -qE 'ft_name.*dependency-mapper|dependency-mapper.*ft_name' "$MI_CONT"; then
  ok "$t"
else
  ng "$t" "mi-continue.md does not exclude ft_name from dependency analysis"
fi

t="mi-continue: records the pin rationale in queue-rationale.md"
if grep -q 'pinned last' "$MI_CONT"; then
  ok "$t"
else
  ng "$t" "mi-continue.md does not record the pin rationale"
fi

t="mi-continue: documents the Row A ordering invariant"
if grep -qE 'Row A.*feature-test|feature-test.*Row A' "$MI_CONT"; then
  ok "$t"
else
  ng "$t" "mi-continue.md does not tie the feature-test entry to the Row A invariant"
fi

# ---- Task 9: canonical project doc ----------------------------------------

PROJ="$REPO_ROOT/docs/millwright-inspector-project.md"

t="project doc: todo.sh table lists feature-test-status"
if grep -qE '`todo\.sh`.*feature-test-status|feature-test-status.*todo\.sh' "$PROJ"; then
  ok "$t"
else
  ng "$t" "todo.sh subcommand table does not list feature-test-status"
fi

t="project doc: folder-id.sh table lists derive-feature-test-name"
if grep -q 'derive-feature-test-name' "$PROJ"; then
  ok "$t"
else
  ng "$t" "folder-id.sh subcommand table does not list derive-feature-test-name"
fi

t="project doc: progress.sh reference lists check-feature-test-pin"
if grep -q 'check-feature-test-pin' "$PROJ"; then
  ok "$t"
else
  ng "$t" "progress.sh reference does not list check-feature-test-pin"
fi

t="project doc: set-state --assignee is documented"
if grep -q 'set-state .*--assignee' "$PROJ"; then
  ok "$t"
else
  ng "$t" "set-state --assignee is undocumented"
fi

t="project doc: schemas section records the feature-test property"
if grep -q 'feature-test' "$PROJ"; then
  ok "$t"
else
  ng "$t" "the feature-test property is not recorded anywhere in the project doc"
fi

t="project doc: stage-1.5 sub-state A describes the auto-select"
if grep -qE 'auto-select|auto-selected' "$PROJ"; then
  ok "$t"
else
  ng "$t" "stage-1.5 text does not describe the auto-select"
fi

t="project doc: records that reorder's contract is unchanged"
if grep -qE "reorder.*(unchanged|contract stays|permutation-only)" "$PROJ"; then
  ok "$t"
else
  ng "$t" "project doc does not state that reorder's contract is unchanged"
fi

# ---- Summary --------------------------------------------------------------

printf "\n%d passed, %d failed\n" "$pass" "$fail"
if (( fail > 0 )); then
  printf "Failed: %s\n" "${fail_names[*]}" >&2
  exit 1
fi
exit 0
