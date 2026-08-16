# Feature-Test Queue Entry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a multi-feature quest cycle emit one extra `todo-list.md` section holding a single "test the whole feature implementation" item, auto-selected once the ordinary selection is settled and pinned last in the queue.

**Architecture:** Hybrid. The three predicates that must be deterministic — name derivation, the auto-select trigger, and the queue pin — become script subcommands (`folder-id.sh derive-feature-test-name`, `todo.sh feature-test-status`, `progress.sh check-feature-test-pin`). Content-shaped work (section emission, `summary.md` prose, hand-off wording) stays in the command markdown. Two existing contracts gain additive changes: `todo.sh set-state --assignee` and `todo.sh pend-selected` stdout.

**Tech Stack:** Bash 3.2 (macOS system bash — no `${arr[-1]}`, no `mapfile`, no associative arrays), embedded `python3` heredocs, `yq` via `scripts/internal/common.sh`, JSON-Schema-in-YAML under `schemas/`.

**Spec:** `docs/superpowers/specs/2026-08-14-feature-test-queue-entry-design.md` (commit `a51bd1e`)

## Global Constraints

- **Branch:** `feat/mi-run/feature-test-queue-entry`. Base commit `6f83e6557beefd113793867f8919fca5d677b07a`.
- **Bash 3.2 compatibility is mandatory.** The system bash on the target machine is `GNU bash 3.2.57`. Use `${arr[$(( ${#arr[@]} - 1 ))]}` for last-element access, never `${arr[-1]}`.
- **All scripts run under `set -euo pipefail`.** A bare `[[ ... ]] && cmd` as the last statement of a loop body or function will abort the script when the test is false. Use `if ... then ... fi`.
- **Every script sources `scripts/internal/common.sh`** via `source "$(dirname "$0")/internal/common.sh"` and uses `mi_die` / `mi_info` for diagnostics. Errors go to stderr; machine-readable output goes to stdout.
- **Single-feature cycles must stay byte-identical.** Any code path added for this feature is gated on `count(ordinary features) >= 2` or on the presence of the `feature-test` frontmatter field. This is FTQ-007 and is asserted by tests.
- **`feature-test` is an optional schema property.** Absence is valid and meaningful; every pre-existing cycle file must continue to validate untouched.
- **Item id:** `FT-001`, with the *prefix* falling back to `FT2-001`, `FT3-001`, … when `FT` is already taken by an ordinary feature in the same cycle.
- **Tests:** `tests/feature-test-entry/run.sh`, following the `ok()` / `ng()` convention in `tests/blueprint-lessons/run.sh`. Exit 0 on all-pass, 1 on any failure. Tests are additive — each task appends its own `# ---- Task N ----` block.

---

### Task 1: Test harness + `feature-test` schema property

**Files:**
- Create: `tests/feature-test-entry/run.sh`
- Create: `tests/feature-test-entry/fixtures/schema-good/todo-list.md`
- Create: `tests/feature-test-entry/fixtures/schema-bad-pattern/todo-list.md`
- Create: `tests/feature-test-entry/fixtures/schema-absent/todo-list.md`
- Create: `tests/feature-test-entry/fixtures/schema-good-summary/summary.md`
- Modify: `schemas/todo-list.schema.yaml`
- Modify: `schemas/summary.schema.yaml`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `tests/feature-test-entry/run.sh` with the `ok()`/`ng()` helpers and a `make_quest()` sandbox helper that every later task reuses. `make_quest` prints a sandbox path; callers set `MI_DATA_ROOT="$sandbox"` when invoking scripts.

- [ ] **Step 1: Write the failing test**

Create `tests/feature-test-entry/fixtures/schema-good/todo-list.md`:

```markdown
---
id: 11111111-1111-4111-8111-111111111111
related-features: [payments, audit-log, payments-feature-test]
description: Two ordinary features plus a feature-test entry.
feature-test: payments-feature-test
---

# Todo list
```

Create `tests/feature-test-entry/fixtures/schema-bad-pattern/todo-list.md`:

```markdown
---
id: 22222222-2222-4222-8222-222222222222
related-features: [payments, audit-log]
description: feature-test value violates the kebab-case pattern.
feature-test: Payments Feature Test
---

# Todo list
```

Create `tests/feature-test-entry/fixtures/schema-absent/todo-list.md`:

```markdown
---
id: 33333333-3333-4333-8333-333333333333
related-features: [payments]
description: Single-feature cycle — no feature-test field.
---

# Todo list
```

Create `tests/feature-test-entry/fixtures/schema-good-summary/summary.md`:

```markdown
---
id: 44444444-4444-4444-8444-444444444444
todo-list-id: 11111111-1111-4111-8111-111111111111
features: [payments, audit-log, payments-feature-test]
keywords: [stripe, audit]
description: Digest with a feature-test entry.
feature-test: payments-feature-test
---

# Summary
```

Create `tests/feature-test-entry/run.sh`:

```bash
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
```

Then: `chmod +x tests/feature-test-entry/run.sh`

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/feature-test-entry/run.sh`
Expected: FAIL — `schema: todo-list with a valid feature-test field passes` and the summary case fail, because `additionalProperties: false` rejects the unknown `feature-test` key. The bad-pattern and absent cases pass incidentally.

- [ ] **Step 3: Add the property to both schemas**

In `schemas/todo-list.schema.yaml`, append under `properties:` (after `description:`):

```yaml
  feature-test:
    type: string
    pattern: "^[a-z0-9][a-z0-9-]*$"
    description: >
      The derived feature-test entry's name, when this cycle has one. Absent on
      single-feature cycles and on cycles generated before this field existed.
      When present it MUST also appear in related-features. Written by
      /mi-run at stage 1 via `frontmatter.sh set`, never templated.
```

In `schemas/summary.schema.yaml`, append under `properties:` (after `description:`):

```yaml
  feature-test:
    type: string
    pattern: "^[a-z0-9][a-z0-9-]*$"
    description: >
      The derived feature-test entry's name, when this cycle has one. Absent on
      single-feature cycles and on cycles generated before this field existed.
      When present it MUST also appear in features and have a matching
      `## Feature: <name>` body section.
```

Do **not** add either name to the `required:` array.

- [ ] **Step 4: Run test to verify it passes**

Run: `tests/feature-test-entry/run.sh`
Expected: PASS — `4 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add tests/feature-test-entry schemas/todo-list.schema.yaml schemas/summary.schema.yaml
git commit -m "feat(schema): optional feature-test property on todo-list and summary"
```

---

### Task 2: `folder-id.sh derive-feature-test-name`

**Files:**
- Modify: `scripts/folder-id.sh` (add a case branch before the `*)` usage branch)
- Modify: `tests/feature-test-entry/run.sh` (append a Task 2 block)

**Interfaces:**
- Consumes: `folder-id.sh feature-lineage-check <name>` (existing; exit 0 = safe to use).
- Produces: `folder-id.sh derive-feature-test-name <feature1> <feature2> [...]` — prints the derived name on stdout, exit 0. Prints a rename note on stderr when an ordinal was needed. Exits non-zero with a message when given fewer than two arguments. Task 7 calls this from `commands/mi-run.md`.

- [ ] **Step 1: Write the failing test**

Append to `tests/feature-test-entry/run.sh`, immediately before the `# ---- Summary ----` block:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/feature-test-entry/run.sh`
Expected: FAIL — all six Task 2 tests fail; the subcommand falls through to the `*)` usage branch and exits 2 with empty stdout.

- [ ] **Step 3: Write minimal implementation**

In `scripts/folder-id.sh`, add this case branch immediately before the final `*)` usage branch:

```bash
  derive-feature-test-name)
    # Derive the cycle's feature-test entry name from its final ordered
    # ordinary feature list. Second-pass uniqueness gate: the candidate must
    # differ from every ordinary name AND pass feature-lineage-check, with an
    # ordinal retry on either failure.
    if [[ $# -lt 2 ]]; then
      mi_die "derive-feature-test-name: at least two ordinary feature names required (a single-feature cycle emits no feature-test entry — FTQ-007)"
    fi
    base="${1}-feature-test"
    candidate="$base"
    ordinal=1
    while :; do
      taken=0
      for f in "$@"; do
        if [[ "$f" == "$candidate" ]]; then
          taken=1
          break
        fi
      done
      if [[ "$taken" -eq 0 ]]; then
        if "$0" feature-lineage-check "$candidate" >/dev/null 2>&1; then
          break
        fi
      fi
      ordinal=$((ordinal + 1))
      if [[ "$ordinal" -gt 99 ]]; then
        mi_die "derive-feature-test-name: exhausted ordinals 2..99 for base '$base'"
      fi
      candidate="${base}-${ordinal}"
    done
    if [[ "$candidate" != "$base" ]]; then
      echo "note: feature-test name '$base' was taken; using '$candidate'" >&2
    fi
    echo "$candidate"
    ;;
```

Also add the subcommand to the usage line in the `*)` branch and to the file's header comment block.

- [ ] **Step 4: Run test to verify it passes**

Run: `tests/feature-test-entry/run.sh`
Expected: PASS — `10 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add scripts/folder-id.sh tests/feature-test-entry/run.sh
git commit -m "feat(folder-id): derive-feature-test-name with second-pass uniqueness gate"
```

---

### Task 3: `todo.sh set-state --assignee`

**Files:**
- Modify: `scripts/todo.sh:50-80` (the `set-state)` branch)
- Modify: `tests/feature-test-entry/run.sh` (append a Task 3 block)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `todo.sh set-state <item-id> <state> [--assignee <name>]`. With the flag, the written line carries `(<name>)`; without it, the existing assignee is preserved and output is byte-identical to today. Task 8 calls this from `commands/mi-continue.md`.

- [ ] **Step 1: Write the failing test**

Append to `tests/feature-test-entry/run.sh` before the `# ---- Summary ----` block:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/feature-test-entry/run.sh`
Expected: FAIL — the two `--assignee` tests and the unknown-flag test fail (the flag is currently ignored as a stray positional). The two no-flag tests pass, confirming today's behaviour.

- [ ] **Step 3: Write minimal implementation**

In `scripts/todo.sh`, replace the head of the `set-state)` branch:

```bash
  set-state)
    item_id="${1:?item-id required}"
    new_state="${2:?new-state required}"
    shift 2
    assignee_override=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --assignee)   assignee_override="${2:?--assignee requires a value}"; shift 2 ;;
        --assignee=*) assignee_override="${1#*=}"; shift ;;
        *)            mi_die "set-state: unknown argument: $1" ;;
      esac
    done
    file="$(todo_file)"
    [[ -f "$file" ]] || mi_die "todo-list.md not found"
    python3 - "$file" "$item_id" "$new_state" "$assignee_override" <<'PYEOF'
```

Then in the heredoc body, change the argv unpack and the assignee resolution:

```python
import sys, re
path, item_id, new_state, assignee_override = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
)
```

```python
        assignee = assignee_override or m.group(2)
```

Everything else in that branch is unchanged. Update the usage comment at the top of the file:

```bash
#   todo.sh set-state <item-id> <TODO|PENDING|IMPLEMENTING|IMPLEMENTED|CANCELED>
#                                 [--assignee <name>]
#                                 # --assignee sets the (assignee) tag; omitted, the
#                                 # existing tag is preserved verbatim (unchanged behaviour).
```

- [ ] **Step 4: Run test to verify it passes**

Run: `tests/feature-test-entry/run.sh`
Expected: PASS — `15 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add scripts/todo.sh tests/feature-test-entry/run.sh
git commit -m "feat(todo): set-state --assignee flag"
```

---

### Task 4: `todo.sh pend-selected` stdout TSV

**Files:**
- Modify: `scripts/todo.sh:144-186` (the `pend-selected)` branch)
- Modify: `tests/feature-test-entry/run.sh` (append a Task 4 block)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `todo.sh pend-selected` now writes one `<item-id>\t<assignee>` row per promoted item to **stdout**, in document order. Its stderr summary line and its exit codes are unchanged. Task 8 reads the last row to inherit an assignee.

- [ ] **Step 1: Write the failing test**

Append to `tests/feature-test-entry/run.sh` before the `# ---- Summary ----` block:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/feature-test-entry/run.sh`
Expected: FAIL — the first test fails (stdout is currently empty). The other three pass, pinning the behaviour that must not change.

- [ ] **Step 3: Write minimal implementation**

In `scripts/todo.sh`, inside the `pend-selected)` heredoc, replace the second-pass block:

```python
# Second pass: rewrite with (assignee) preserved, recording promoted items.
promoted = []
def _sub(m):
    prefix, assignee, rest = m.group(1), m.group(2), m.group(3)
    promoted.append((rest.split(':', 1)[0].strip(), assignee))
    return f'{prefix}[x] ({assignee}) PENDING — {rest}'
new_content, count = pattern.subn(_sub, content)
with open(path, 'w') as f:
    f.write(new_content)
for item_id, assignee in promoted:
    print(f'{item_id}\t{assignee}')
print(f'mi: transitioned {count} inspector-selected items from TODO to PENDING', file=sys.stderr)
```

Update the usage comment at the top of the file:

```bash
#   todo.sh pend-selected         # transform inspector-marked [xX] TODO items to [x] PENDING
#                                 # (fails if any selected item lacks an assignee).
#                                 # stdout: one `<item-id>\t<assignee>` row per promoted
#                                 # item, in document order.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `tests/feature-test-entry/run.sh`
Expected: PASS — `19 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add scripts/todo.sh tests/feature-test-entry/run.sh
git commit -m "feat(todo): pend-selected reports promoted items on stdout"
```

---

### Task 5: `todo.sh feature-test-status`

**Files:**
- Modify: `scripts/todo.sh` (add a case branch before the `*)` usage branch)
- Modify: `tests/feature-test-entry/run.sh` (append a Task 5 block)

**Interfaces:**
- Consumes: the `feature-test` frontmatter property from Task 1.
- Produces: `todo.sh feature-test-status` — read-only, writes no files. Prints one TSV row to stdout: `<status>\t<ft-name>\t<ft-item-id>\t<blocking-count>\t<fallback-assignee>`. `status` ∈ `none | blocked | ready | premature | selected`. Task 8 branches on the first field and consumes fields 2, 3, and 5.

- [ ] **Step 1: Write the failing test**

Append to `tests/feature-test-entry/run.sh` before the `# ---- Summary ----` block:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/feature-test-entry/run.sh`
Expected: FAIL — all nine Task 5 tests fail; the subcommand hits the `*)` usage branch and prints nothing to stdout.

- [ ] **Step 3: Write minimal implementation**

In `scripts/todo.sh`, add this case branch immediately before the final `*)` usage branch:

```bash
  feature-test-status)
    file="$(todo_file)"
    [[ -f "$file" ]] || mi_die "todo-list.md not found"
    python3 - "$file" <<'PYEOF'
import sys, re, yaml

path = sys.argv[1]
with open(path) as f:
    content = f.read()

m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
fm = (yaml.safe_load(m.group(1)) or {}) if m else {}
body = m.group(2) if m else content
ft_name = fm.get('feature-test')

def kebab(s):
    s = s.strip().lower()
    s = re.sub(r'[\s_]+', '-', s)
    s = re.sub(r'[^a-z0-9-]', '', s)
    s = re.sub(r'-+', '-', s).strip('-')
    return s

def emit_none():
    print('none\t\t\t0\t')
    sys.exit(0)

if not ft_name:
    emit_none()

target = kebab(ft_name)
item_pat = re.compile(
    r'^\s*-\s+\[([ xX])\]\s+(?:\(([^)]+)\)\s+)?'
    r'(?:TODO|PENDING|IMPLEMENTING|IMPLEMENTED|CANCELED)\s+—\s+([A-Z0-9-]+)'
)

section = None
ft_item_id = ''
ft_checked = False
blocking = 0
fallback_assignee = ''

for line in body.split('\n'):
    if line.startswith('## '):
        section = kebab(line[3:])
        continue
    mm = item_pat.match(line)
    if not mm:
        continue
    checked = mm.group(1) in ('x', 'X')
    assignee = mm.group(2) or ''
    item_id = mm.group(3)
    if section == target:
        ft_item_id = item_id
        ft_checked = checked
    elif not checked:
        blocking += 1
    else:
        fallback_assignee = assignee

if not ft_item_id:
    # Field present but no matching section/item — a hand-edited file. Warn and
    # report `none` so callers no-op rather than stalling the cycle.
    sys.stderr.write(
        f"warning: feature-test '{ft_name}' is declared in frontmatter but no "
        f"matching section with an item was found; reporting status=none\n"
    )
    emit_none()

if ft_checked:
    status = 'premature' if blocking else 'selected'
else:
    status = 'blocked' if blocking else 'ready'

print(f'{status}\t{ft_name}\t{ft_item_id}\t{blocking}\t{fallback_assignee}')
PYEOF
    ;;
```

Add the subcommand to the `*)` usage line and to the file's header comment:

```bash
#   todo.sh feature-test-status   # read-only predicate. Prints one TSV row:
#                                 #   <status>\t<ft-name>\t<ft-item-id>\t<blocking-count>\t<fallback-assignee>
#                                 # status ∈ none|blocked|ready|premature|selected.
#                                 # "unselected" means checkbox `[ ]`; every [x] state
#                                 # (including CANCELED) resolves an item.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `tests/feature-test-entry/run.sh`
Expected: PASS — `28 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add scripts/todo.sh tests/feature-test-entry/run.sh
git commit -m "feat(todo): feature-test-status auto-select trigger predicate"
```

---

### Task 6: `progress.sh check-feature-test-pin`

**Files:**
- Modify: `scripts/progress.sh` (add a case branch before the `*)` usage branch)
- Modify: `tests/feature-test-entry/run.sh` (append a Task 6 block)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `progress.sh check-feature-test-pin <ft-name> <feature1> [<feature2> ...]` — exit 0 when `ft-name` is absent from the order or is its last element; exit 3 otherwise. Diagnostics on stderr only; no stdout, no writes. Task 8 calls it from both `commands/mi-continue.md` Step 2A and Step 2B.

- [ ] **Step 1: Write the failing test**

Append to `tests/feature-test-entry/run.sh` before the `# ---- Summary ----` block:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/feature-test-entry/run.sh`
Expected: FAIL — the three positive tests and the message test fail; the subcommand hits the `*)` usage branch and exits 2 rather than 0 or 3.

- [ ] **Step 3: Write minimal implementation**

In `scripts/progress.sh`, add this case branch immediately before the final `*)` usage branch. It reads no files — the order is supplied by the caller, so it works equally on a proposed order and on a persisted one:

```bash
  check-feature-test-pin)
    ft_name="${1:?feature-test name required}"
    shift
    [[ $# -gt 0 ]] || mi_die "check-feature-test-pin: at least one feature in the order required"
    order=("$@")
    found=0
    for f in "${order[@]}"; do
      if [[ "$f" == "$ft_name" ]]; then
        found=1
      fi
    done
    if [[ "$found" -eq 0 ]]; then
      echo "mi: '$ft_name' is not in the given order; nothing to pin" >&2
      exit 0
    fi
    last="${order[$(( ${#order[@]} - 1 ))]}"
    if [[ "$last" == "$ft_name" ]]; then
      echo "mi: pin OK — '$ft_name' is last" >&2
      exit 0
    fi
    echo "error: '$ft_name' must be last in the queue order, but '$last' is." >&2
    echo "       The feature-test entry exercises the assembled result of every ordinary" >&2
    echo "       feature in this cycle, so it cannot run before them. This is a structural" >&2
    echo "       constraint, not a priority judgement." >&2
    echo "       Given order: ${order[*]}" >&2
    exit 3
    ;;
```

Add to the usage header comment:

```bash
#   progress.sh check-feature-test-pin <ft-name> <feature1> [<feature2> ...]
#                                            # stage-1.5 validation. Exit 0 when <ft-name>
#                                            # is absent from the order or is its last
#                                            # element; exit 3 otherwise. Reads no files and
#                                            # writes nothing — `reorder`'s permutation-only
#                                            # contract is deliberately left unchanged.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `tests/feature-test-entry/run.sh`
Expected: PASS — `34 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add scripts/progress.sh tests/feature-test-entry/run.sh
git commit -m "feat(progress): check-feature-test-pin queue-order validator"
```

---

### Task 7: Stage-1 emission in `commands/mi-run.md`

**Files:**
- Modify: `commands/mi-run.md:345-380` (Step 3), `:381-407` (Step 4), `:408-415` (Step 5), `:416-434` (Step 6)
- Modify: `tests/feature-test-entry/run.sh` (append a Task 7 block)

**Interfaces:**
- Consumes: `folder-id.sh derive-feature-test-name` (Task 2); the `feature-test` schema property (Task 1); `frontmatter.sh set` (existing).
- Produces: a `todo-list.md` whose frontmatter carries `feature-test: <name>` and whose body ends with a `## <name>` section holding exactly one `FT-001` item; a matching `summary.md`. Task 8 consumes both.

This task edits command prose, not code, so its tests are structural greps in the style of `tests/blueprint-lessons/run.sh`'s Task-14 check.

- [ ] **Step 1: Write the failing test**

Append to `tests/feature-test-entry/run.sh` before the `# ---- Summary ----` block:

```bash
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
if grep -qE 'frontmatter\.sh" set .*feature-test|frontmatter\.sh set .*feature-test' "$MI_RUN"; then
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/feature-test-entry/run.sh`
Expected: FAIL — all nine Task 7 tests fail; `commands/mi-run.md` has no feature-test content yet.

- [ ] **Step 3: Edit the command prose**

In **Step 3** of `commands/mi-run.md`, after the paragraph beginning "The final (possibly renamed) names are the ones written everywhere downstream", insert:

````markdown
**Feature-test entry (multi-feature cycles only).** When `count(ordinary features) >= 2` — evaluated **after** the uniqueness gate above has settled every rename, so the derived name is built from final names — this cycle also carries a terminal whole-feature test entry. Derive its name:

```bash
ft_name="$($CLAUDE_PLUGIN_ROOT/scripts/folder-id.sh derive-feature-test-name "${final_features[@]}")"
```

`derive-feature-test-name` appends `-feature-test` to the first feature in the final ordered list and runs the same second-pass uniqueness gate ordinary names get (differ from every ordinary name; pass `feature-lineage-check`), appending `-2`, `-3`, … until both pass. It prints a rename note on stderr when an ordinal was needed — Step 6 must surface it. A single-feature cycle never calls it: `count == 1` emits no feature-test section, no `## Feature:` section, no queue entry, and no folder, producing a byte-identical `todo-list.md` to today.

Pass `ft_name` **last** in `FEATURES`, then record it in frontmatter after `init`:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init todo-list \
  "$quest_dir/todo-list.md" \
  "FEATURES=payments,audit-log,payments-feature-test" \
  "DESCRIPTION=Add Stripe webhooks and a tamper-evident audit trail."
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh set \
  "$quest_dir/todo-list.md" feature-test "$ft_name"
```

The field is set post-`init` rather than templated so a single-feature cycle's file is untouched — an unsubstituted `{{FEATURE_TEST}}` would leave either a literal token or an empty value, and both fail the schema pattern.

**The name is frozen once written.** It derives from the **stage-1** ordered feature list and is then fixed in `todo-list.md`, `summary.md`, and the feature folder name. A stage-1.5 reorder that changes which feature comes first must **not** re-derive it — re-deriving would rename a feature folder mid-cycle and strand its artifacts. Downstream readers take the name from the `feature-test:` frontmatter field, never by re-computing it.

Emit the ordinary sections first and the feature-test section **last**, holding exactly one item:

```markdown
## payments-feature-test

Covers the assembled result of every feature above. Auto-selected by the millwright once
every ordinary item is either selected or cancelled — leave this item unmarked. To drop an
ordinary item you do not want this cycle, cancel it (`todo.sh set-state <id> CANCELED`)
rather than leaving it unmarked.

- [ ] TODO — FT-001: test the whole feature implementation
```

The item carries **no assignee** — stage 1.5 inherits one from whoever completes the selection. Its id is `FT-001`; when an ordinary feature in this cycle already uses the `FT` prefix, fall back on the prefix — `FT2-001`, `FT3-001`, … — keeping the `-001` numbering ordinary ids use.
````

In **Step 4**, after the numbered list of body sections, insert:

````markdown
**Feature-test section (multi-feature cycles only).** When Step 3 emitted a feature-test entry, pass the same `ft_name` last in `FEATURES` and mirror the field:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh set \
  "$quest_dir/summary.md" feature-test "$ft_name"
```

Add `## Feature: <ft_name>` as the **last** `## Feature:` section (before `## Sources`). It describes **what** the whole-feature test must cover — synthesized from `## Cross-cutting constraints` plus the union of the ordinary features' acceptance hints. Do **not** enumerate test scenarios: stage 1 has journal content rather than an implementation, so scenarios written here would be guesses that the feature-test workflow later contradicts when it derives a real plan from shipped code, leaving two disagreeing definitions with the stale one in the file the inspector reads first. Add one matching `## In plain terms` bullet.
````

In **Step 5**, after the existing paragraph, insert:

```markdown
Pass **only the ordinary features** here. The feature-test name is deliberately withheld from `progress.sh init`: selection is unknown at stage 1, so the entry is appended later by `progress.sh enqueue` at the stage-1.5 moment its auto-select condition fires.
```

In **Step 6**, append to the hand-off message block:

```markdown
When the cycle carries a feature-test entry, append this to the hand-off message:

> "This cycle has more than one feature, so `todo-list.md` also carries a terminal **`<ft_name>`** section with a single item: *test the whole feature implementation*. **Leave that item unmarked** — I select it automatically once every ordinary item is either selected or cancelled, and it is pinned last in the queue. If there's an ordinary item you don't want this cycle, cancel it (`todo.sh set-state <id> CANCELED`) rather than leaving it unmarked, otherwise the whole-feature test never becomes selectable."

When `derive-feature-test-name` printed a rename note, append one more line in the same shape as the per-feature rename notes above.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `tests/feature-test-entry/run.sh`
Expected: PASS — `43 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add commands/mi-run.md tests/feature-test-entry/run.sh
git commit -m "feat(mi-run): emit the feature-test section on multi-feature cycles"
```

---

### Task 8: Stage-1.5 trigger and pin in `commands/mi-continue.md`

**Files:**
- Modify: `commands/mi-continue.md` (Pre-flight Step 2A items 1–5; Pre-flight Step 2B item 2)
- Modify: `tests/feature-test-entry/run.sh` (append a Task 8 block)

**Interfaces:**
- Consumes: `todo.sh feature-test-status` (Task 5), `todo.sh set-state --assignee` (Task 3), `todo.sh pend-selected` stdout (Task 4), `progress.sh check-feature-test-pin` (Task 6), `progress.sh enqueue` (existing).
- Produces: the completed stage-1.5 behaviour. No later task consumes it.

- [ ] **Step 1: Write the failing test**

Append to `tests/feature-test-entry/run.sh` before the `# ---- Summary ----` block:

```bash
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
if grep -qE 'dependency-mapper.*ft_name|ft_name.*dependency analysis|excluded from the dependency' "$MI_CONT"; then
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/feature-test-entry/run.sh`
Expected: FAIL — all nine Task 8 tests fail; `commands/mi-continue.md` has no feature-test content yet.

- [ ] **Step 3: Edit the command prose**

In **Pre-flight Step 2A**, replace item 1 ("Promote the marked items") with:

````markdown
1. **Promote the marked items.**
   ```bash
   $CLAUDE_PLUGIN_ROOT/scripts/progress.sh queue-remaining >/dev/null  # confirms progress.md exists
   promoted="$($CLAUDE_PLUGIN_ROOT/scripts/todo.sh pend-selected)"
   ```
   `pend-selected` rejects any `[x] TODO` line missing an `(assignee)` tag — relay the offenders to the inspector, ask for assignee names, and stop. The inspector fixes the file and re-types `/mi-continue`.

   Its **stdout** carries one `<item-id>\t<assignee>` row per promoted item, in document order; `$promoted` holds them for item 1.5 below.
````

Immediately after item 1, insert a new item:

````markdown
1.5. **Evaluate the feature-test entry (multi-feature cycles only).**

   ```bash
   ft_row="$($CLAUDE_PLUGIN_ROOT/scripts/todo.sh feature-test-status)"
   ft_status="$(printf '%s' "$ft_row" | cut -f1)"
   ft_name="$(printf '%s' "$ft_row" | cut -f2)"
   ft_item_id="$(printf '%s' "$ft_row" | cut -f3)"
   ft_fallback_assignee="$(printf '%s' "$ft_row" | cut -f5)"
   ```

   Branch on `$ft_status`:

   - **`none`** — no feature-test entry in this cycle (single-feature, or a cycle predating the field). Do nothing.
   - **`blocked`** — ordinary `[ ]` items remain. Do nothing, and say nothing about the entry; the hand-off text already explained it.
   - **`ready`** — every ordinary item is now selected or cancelled. Inherit the assignee from the **last** row of `$promoted` (that is, the last one in document order on the pass that completed the selection); when `$promoted` is empty — a re-run after an interrupted session — fall back to `$ft_fallback_assignee`. If both are empty (only reachable by hand-editing, since `pend-selected` and `todo.sh add` both enforce the tag), **ask the inspector for a name** rather than promoting untagged: an untagged `[x]` line would fail the assignee invariant every later `pend-selected` re-checks.

     ```bash
     $CLAUDE_PLUGIN_ROOT/scripts/todo.sh set-state "$ft_item_id" PENDING --assignee "$inherited_assignee"
     ```

   - **`premature`** — the inspector marked the entry by hand while ordinary items remain, and `pend-selected` promoted it early. Revert it (their `(assignee)` tag is preserved, leaving `- [ ] (emin) TODO — …`) and explain:

     ```bash
     $CLAUDE_PLUGIN_ROOT/scripts/todo.sh set-state "$ft_item_id" TODO
     ```

     > "`<ft_name>` is auto-managed — I've unmarked it. It selects itself once every ordinary item is selected or cancelled, and it's pinned last in the queue."

   - **`selected`** — already promoted on an earlier pass. Do nothing here; item 3.5 still checks whether it needs queueing.
````

In item 3, in the `queue_count == 0` mid-cycle branch, append to the `enqueue` paragraph:

```markdown
Pass **only ordinary feature names** here, **excluding `$ft_name`** — the feature-test entry is appended separately by item 3.5 so it lands last in both the initial and the mid-cycle branch.
```

Immediately after item 3, insert:

````markdown
3.5. **Append the feature-test entry to the queue.** Runs when item 1.5 promoted, or when `$ft_status` is `selected` and the name is not yet queued:

   ```bash
   if [[ -n "${ft_name:-}" && "$ft_status" != "none" && "$ft_status" != "blocked" && "$ft_status" != "premature" ]]; then
     if ! $CLAUDE_PLUGIN_ROOT/scripts/progress.sh queue-remaining | grep -qx "$ft_name"; then
       $CLAUDE_PLUGIN_ROOT/scripts/progress.sh enqueue "$ft_name"
     fi
   fi
   ```

   The guard matters: `enqueue` **errors** on a duplicate rather than no-opping, so a `/mi-continue` re-run after a session break would abort here without it. Splitting this from the promotion in item 1.5 is what guarantees last position in both branches — the initial cycle skips item 3's `enqueue` entirely, while the mid-cycle branch enqueues ordinary features first.
````

In item 4 (dependency signals), add at the top of the step:

```markdown
**Exclude `$ft_name` from every part of this step** — from the journal-only proposal, from the ambiguity heuristic, and from the feature list passed to the `dependency-mapper` sub-agent. The feature-test entry has no code to scan and its position is fixed by the pin, so including it would spend sub-agent reads searching for a feature that does not exist yet.
```

In item 5 (propose the prioritized order), append:

````markdown
When the cycle carries a feature-test entry, append `$ft_name` **last** to the proposal, then assert the pin before printing:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh check-feature-test-pin "$ft_name" "${proposed_order[@]}"
```

Show it in the numbered list with a one-line note that it is pinned and cannot be moved.
````

In item 6 (mid-cycle draft batch), append:

```markdown
When the batch introduced the feature-test entry, record the pin under `### Notes`:

> `<ft_name>` is pinned last — it exercises the assembled result of every ordinary feature in this cycle, so it cannot run before them. This is a structural constraint, not a priority judgement; an order placing it earlier is refused at stage 1.5.
```

In **Pre-flight Step 2B**, after item 2's permutation validation, insert:

````markdown
   **Pin validation.** When the cycle carries a feature-test entry, the confirmed order must keep it last:

   ```bash
   ft_name="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$quest_dir/todo-list.md" feature-test 2>/dev/null || echo '')"
   if [[ -n "$ft_name" && "$ft_name" != "null" ]]; then
     $CLAUDE_PLUGIN_ROOT/scripts/progress.sh check-feature-test-pin "$ft_name" "${confirmed_order[@]}"
   fi
   ```

   On exit 3, relay the message and ask the inspector to retype the order — the same shape as the malformed-order path above. The check reads no files, so it is equally valid against a proposed order and a persisted one.

   Read `ft_name` from frontmatter as shown — **never re-derive it here.** The name was frozen at stage 1 from the stage-1 feature order; a confirmed order that puts a different feature first does not change it, and re-deriving would rename a feature folder mid-cycle and strand its artifacts.
````

In Step 2B item 3's load-bearing-invariant note, append:

```markdown
When the cycle carries a feature-test entry, `queue-rationale.features` ends with it — which is exactly what keeps **Row A** satisfied, since the confirmed order (and therefore `progress.queue`) ends with it too. This is the invariant that breaks first if anyone moves the item-3.5 `enqueue` out of Step 2A into Step 2B: the name would be missing from the queue when `features:` is written, Row A would mismatch, and the workflow would stall between features.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `tests/feature-test-entry/run.sh`
Expected: PASS — `52 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add commands/mi-continue.md tests/feature-test-entry/run.sh
git commit -m "feat(mi-continue): auto-select and pin the feature-test entry at stage 1.5"
```

---

### Task 9: Canonical project-doc updates

**Files:**
- Modify: `docs/millwright-inspector-project.md` (§3.3; the assignee invariant near line 382; stage-1.5 sub-state text near lines 754–760; the dispatcher table near line 1069; the `todo.sh` and `folder-id.sh` subcommand tables near lines 1688–1689; the `progress.sh` reference; §8.3)
- Modify: `tests/feature-test-entry/run.sh` (append a Task 9 block)

**Interfaces:**
- Consumes: every subcommand and behaviour from Tasks 1–8.
- Produces: nothing consumed by later tasks. This is the last task.

- [ ] **Step 1: Write the failing test**

Append to `tests/feature-test-entry/run.sh` before the `# ---- Summary ----` block:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/feature-test-entry/run.sh`
Expected: FAIL — all seven Task 9 tests fail; the project doc has no feature-test content.

- [ ] **Step 3: Edit the project doc**

Make these seven edits:

1. **§3.3 (the quest folder)** — after the `todo-list.md` description, add:

   > **Feature-test section.** A cycle distilling to two or more features also carries a terminal `## <first-feature>-feature-test` section holding exactly one item (`FT-001: test the whole feature implementation`). It is named in the file's optional `feature-test:` frontmatter field, emitted last, and **auto-selected by the millwright** at stage 1.5 rather than marked by the inspector. A single-feature cycle emits none of this — that feature's own workflow already tests it end to end.

2. **Assignee invariant (~line 382)** — append:

   > The one exception is the feature-test item, which stage 1 emits unassigned and stage 1.5 promotes with an assignee **inherited** from the last item selected on the pass that completed the selection (`todo.sh set-state <id> PENDING --assignee <name>`). The invariant itself is unchanged: the line still carries a tag by the time it is `[x]`.

3. **Stage-1.5 sub-state A (~lines 754–760)** — extend the sentence describing sub-state A:

   > …runs `todo.sh pend-selected` (whose stdout reports the promoted `<item-id>\t<assignee>` rows), evaluates `todo.sh feature-test-status` and promotes the feature-test entry when it reports `ready` (reverting it when it reports `premature`), groups PENDING items by feature, repopulates the queue via `progress.sh enqueue` if mid-cycle, appends the feature-test entry last via a separate `enqueue`, derives…

   And sub-state B:

   > …validates the confirmed order with `progress.sh check-feature-test-pin` when the cycle carries a feature-test entry, writes `queue-rationale.md`, runs `progress.sh reorder`, and auto-fires `/mi-apply-impact`.

4. **Dispatcher table (~line 1069)** — add a note beneath the table:

   > The feature-test entry adds **no new dispatcher rows**: it rides the existing Step 2A / Step 2B rows. Row A's ordering invariant (`queue-rationale.features − completed == queue`, in order) continues to hold because the confirmed order — and therefore both `features:` and `queue` — ends with the pinned name.

5. **`todo.sh` table (~line 1688)** — replace the subcommand list:

   > Subcommands: `set-state` (optional `--assignee`), `bulk-transition` (optional `--feature`), `pend-selected` (reports promoted `<item-id>\t<assignee>` rows on stdout), `list <state>`, `add`, `feature-test-status`. Enforces the state machine and assignee invariants.

6. **`folder-id.sh` table (~line 1689)** — replace the subcommand list:

   > Subcommands: `ensure`, `get`, `resolve <id>`, `list`, `init-reference`, `link-feature`, `feature-lineage-check`, `derive-feature-test-name`.

7. **`progress.sh` reference and §8.3** — add to the `progress.sh` subcommand reference:

   > `check-feature-test-pin <ft-name> <order...>` — stage-1.5 validation; exit 0 when the name is absent from the order or is its last element, exit 3 otherwise. Reads no files. Deliberately separate from `reorder`, whose permutation-only contract is **unchanged** — a guard inside `reorder` would alter behaviour for cycles that carry no feature-test entry at all.

   And to §8.3 (schemas):

   > `todo-list` and `summary` both carry an optional `feature-test` property (kebab-case string). Absent on single-feature cycles and on cycles generated before the field existed; when present it must also appear in `related-features` / `features`.

- [ ] **Step 4: Run test to verify it passes**

Run: `tests/feature-test-entry/run.sh`
Expected: PASS — `59 passed, 0 failed`

Also run the repo's other suites to confirm nothing regressed:

Run: `tests/lint/run.sh && tests/blueprint-lessons/run.sh && tests/bundle/run.sh`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add docs/millwright-inspector-project.md tests/feature-test-entry/run.sh
git commit -m "docs: record the feature-test queue entry in the canonical project spec"
```

---

## Verification

After Task 9, confirm the full picture:

```bash
tests/feature-test-entry/run.sh
tests/lint/run.sh
tests/blueprint-lessons/run.sh
tests/bundle/run.sh
git log --oneline 6f83e6557beefd113793867f8919fca5d677b07a..HEAD
```

Expected: `59 passed, 0 failed` on the new suite, all three existing suites green, and nine commits on `feat/mi-run/feature-test-queue-entry`.
