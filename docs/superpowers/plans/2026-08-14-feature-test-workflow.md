# Feature-Test Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give a cycle's terminal feature-test entry its own five-step abbreviated pipeline — complete-feature diagrams, whole-feature test plan, manual run, inspector review, findings resolution — with no blueprint, planning, or implementation stage.

**Architecture:** The pipeline introduces no new state values. A dispatcher fork in `commands/mi-continue.md` activates the entry, runs an unpersisted diagram pass over a union commit range, and jumps straight to `current-stage=5`; everything from there is the ordinary machinery on ordinary conditions. Where the pipeline needs blueprint material it borrows from the completed ordinary features' archived `blueprints/history/v[N]/`. Two shared shell predicates (`todo.sh is-feature-test`, `commits.sh feature-test-range`) keep identity and range derivation out of duplicated command prose.

**Tech Stack:** Bash 3.2 (macOS default) + embedded Python 3 for YAML work, JSON Schema draft-07 (`schemas/*.yaml`), Claude Code command prose (`commands/*.md`). Tests are plain bash suites under `tests/<feature>/run.sh`.

**Spec:** `docs/superpowers/specs/2026-08-14-feature-test-workflow-design.md` (commit `b9a2393`)

## Global Constraints

- **Ordinary features must behave byte-identically to today.** Every change is a branch taken *before* an existing code path, never an edit to it. `progress.sh activate` stays byte-identical. FTW-006 requires an explicit regression check (Task 13).
- **Branch:** `feat/mi-run/feature-test-workflow`. **base-commit:** `1feb5cb12438446df055d722289a8632bbf8edb5`.
- **Bash 3.2 compatible.** No `declare -A`, no `${var,,}`, no `mapfile`. Array expansion uses the `${arr[@]+"${arr[@]}"}` idiom (see `tests/feature-test-entry/run.sh:21`).
- **POSIX/BSD portable.** Commands must run on macOS. GNU-only flags (`cat -A`, `sed -i` without an argument, `grep -P`) are defects even when the logic is right.
- **`progress.schema.yaml` is never edited.** The pipeline introduces no new state values.
- **No new dispatcher rows.** Both dispatcher changes are conditions evaluated ahead of an existing row's body.
- **Scope:** goals FTW-001 … FTW-009 only. Sibling features `feature-test-queue-entry` (complete) and `deferred-test-items` (queued) are out of scope — this feature owns only the merge *anchor* for `DTI-005`.
- **Commit after every task.** Run `bash tests/feature-test-workflow/run.sh` before each commit; it must be green.

## File Structure

| File | Responsibility | Task |
| --- | --- | --- |
| `tests/feature-test-workflow/run.sh` | Whole suite for FTW-001…009; additive per task | 1 (created), all |
| `scripts/todo.sh` | `is-feature-test` identity predicate | 1 |
| `scripts/progress.sh` | `advance-to` whitelist gains `2→5` | 2 |
| `schemas/change-summary.schema.yaml` | `requirements-ids`, `commits`, `oneOf` gate | 3 |
| `schemas/manual-test-plan.schema.yaml` | `requirements-ids`, `oneOf` gate | 3 |
| `scripts/review.sh` | `sync-refs` tolerates the plural field | 3 |
| `scripts/commits.sh` | `feature-test-range`, `populate-feature-test` | 4, 5 |
| `commands/mi-continue.md` | Row A entry branch + `2 \| any` recovery branch | 6 |
| `commands/mi-apply-impact.md` | Refusal guard | 7 |
| `commands/mi-generate-implementation-diagrams.md` | Union-range diagram path | 8 |
| `commands/mi-manual-test-plan.md` | Whole-feature derivation path + merge anchor | 9 |
| `commands/mi-complete-workflow.md` | Stage-8 substitution path | 10 |
| `commands/mi-abort-workflow.md` | Guidance-text branch | 11 |
| `commands/mi-resume-workflow.md`, `scripts/info-bar.sh` | Abbreviated-step naming | 12 |
| `docs/millwright-inspector-project.md` | §3.4, §6, §7.3, §7.4, §8 | 13 |

---

### Task 1: `todo.sh is-feature-test` + test harness

The identity predicate every later task calls. Eight call sites would otherwise re-parse `todo-list.md` with their own regex.

**Files:**
- Create: `tests/feature-test-workflow/run.sh`
- Modify: `scripts/todo.sh:419-424` (add subcommand before the `*)` catch-all; update the usage line)

**Interfaces:**
- Produces: `todo.sh is-feature-test <name>` — exit `0` when `<name>` equals the active cycle's `todo-list.md` frontmatter `feature-test:` value, exit `1` otherwise (absent field, absent file, no active cycle, or a different name). Writes nothing to stdout or stderr. Never dies: callers use it directly in `if`.

- [ ] **Step 1: Write the failing test**

Create `tests/feature-test-workflow/run.sh`:

```bash
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

# ---- Summary --------------------------------------------------------------

printf "\n%d passed, %d failed\n" "$pass" "$fail"
if (( fail > 0 )); then
  printf "Failed: %s\n" "${fail_names[*]}" >&2
  exit 1
fi
exit 0
```

Then `chmod +x tests/feature-test-workflow/run.sh`.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: FAIL — the four exit-0/exit-1 cases fail because `todo.sh` exits `2` (unknown subcommand) for every invocation.

- [ ] **Step 3: Add the subcommand**

In `scripts/todo.sh`, insert immediately before the `*)` catch-all case (currently line 421):

```bash
  is-feature-test)
    # Read-only identity predicate: does <name> match this cycle's declared
    # feature-test entry? Exit 0 = yes, 1 = no. Never dies — callers use it
    # directly in `if`, so a missing cycle or file is "no", not an error.
    name="${1:?feature name required}"
    file="$(todo_file 2>/dev/null || true)"
    [[ -n "$file" && -f "$file" ]] || exit 1
    python3 - "$file" "$name" <<'PYEOF'
import sys, re, yaml
path, name = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        content = f.read()
except OSError:
    sys.exit(1)
m = re.match(r'^---\n(.*?)\n---\n', content, re.DOTALL)
fm = (yaml.safe_load(m.group(1)) or {}) if m else {}
ft = fm.get('feature-test')
sys.exit(0 if ft and ft == name else 1)
PYEOF
    ;;
```

Update the usage line (currently line 422) to:

```bash
    echo "usage: todo.sh {set-state|bulk-transition|pend-selected|list|add|feature-test-status|is-feature-test} ..." >&2
```

And add to the header comment block near line 44:

```bash
#   todo.sh is-feature-test <name>  # read-only predicate. Exit 0 when <name> is
#                                   # this cycle's declared feature-test entry,
#                                   # exit 1 otherwise. Silent on both streams.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: PASS — `6 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add tests/feature-test-workflow/run.sh scripts/todo.sh
git commit -m "feat(todo): add is-feature-test identity predicate

Single shared predicate for the abbreviated feature-test pipeline; eight
call sites would otherwise re-parse todo-list.md with their own regex.
Read-only and never dies, so callers can use it directly in \`if\`."
```

---

### Task 2: `progress.sh advance-to` gains `2→5`

The whitelist is `3-5|5-7|6-7`. The dispatcher fork needs `2→5` so a session break cannot strand the entry mid-transition.

**Files:**
- Modify: `scripts/progress.sh:666-672` (whitelist case + diagnostic), `scripts/progress.sh:40-50` (usage header)
- Test: `tests/feature-test-workflow/run.sh`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `progress.sh advance-to 2 5 [--set field=value]...` accepted. All other non-whitelisted pairs still refused with exit non-zero.

- [ ] **Step 1: Write the failing test**

Append to `tests/feature-test-workflow/run.sh`, immediately before the `# ---- Summary` block:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: FAIL on the three `2→5` cases with "stage transition 2 → 5 not in whitelist".

- [ ] **Step 3: Widen the whitelist**

In `scripts/progress.sh`, replace the case block at line 666:

```bash
    case "${expected}-${target}" in
      2-5|3-5|5-7|6-7) ;;
      *)
        mi_die "advance-to: stage transition ${expected} → ${target} not in whitelist (allowed: 2→5, 3→5, 5→7, 6→7). Adjacent transitions use 'advance'."
        ;;
    esac
```

Extend the comment directly above it (line 660-665) with the new pair's rationale:

```bash
    # Stage-pair whitelist: only these skip-transitions are legal. Adjacent
    # transitions must use `advance` (which catches typo'd targets via the
    # off-by-one check). The whitelist exists so the dispatcher's intentional
    # skips (2→5 for a feature-test entry, whose abbreviated pipeline has no
    # blueprint or planning stage; 3→5 after stage-4 collapses into the Resume
    # Handler; 5→7 on the no-findings approve path; 6→7 on the review-resume
    # finalize path) can't be confused with arbitrary stage jumps.
```

Update the usage header at line 43 to read `(2→5, 3→5, 5→7, 6→7)`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: PASS — `11 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/progress.sh tests/feature-test-workflow/run.sh
git commit -m "feat(progress): allow the 2->5 skip transition

A feature-test entry has no blueprint-approval or planning stage, so its
dispatcher fork advances straight from activation to inspector review.
Mirrors the existing advance-to 3 5 idiom so a session break cannot strand
the entry mid-transition. The three existing pairs are untouched."
```

---

### Task 3: Schemas take a list of requirements ids

A feature-test entry is framed against *every* finished feature's requirements, not one. Both schemas hard-require a single `requirements-id` today.

**Files:**
- Modify: `schemas/change-summary.schema.yaml`, `schemas/manual-test-plan.schema.yaml`
- Modify: `scripts/review.sh` (`sync-refs` — tolerate the plural field)
- Create: `tests/feature-test-workflow/fixtures/cs-ordinary/change-summary.md`, `.../cs-feature-test/change-summary.md`, `.../cs-both/change-summary.md`, `.../cs-neither/change-summary.md`, `.../mtp-ordinary/manual-test-plan.md`, `.../mtp-feature-test/manual-test-plan.md`

**Interfaces:**
- Produces: both schemas accept **exactly one** of `requirements-id` (string) or `requirements-ids` (array of ≥1 UUIDs). `change-summary` additionally accepts an optional `commits` array of `{sha, msg}` objects, consumed by Task 5.

- [ ] **Step 1: Write the failing test**

Create the six fixtures. `tests/feature-test-workflow/fixtures/cs-ordinary/change-summary.md`:

```markdown
---
id: 11111111-1111-4111-8111-111111111111
requirements-id: 22222222-2222-4222-8222-222222222222
feature: payments
base-commit: 6f83e6557beefd113793867f8919fca5d677b07a
head: 1feb5cb12438446df055d722289a8632bbf8edb5
---

# Change summary — payments
```

`.../cs-feature-test/change-summary.md`:

```markdown
---
id: 33333333-3333-4333-8333-333333333333
requirements-ids:
- 22222222-2222-4222-8222-222222222222
- 44444444-4444-4444-8444-444444444444
feature: payments-feature-test
base-commit: 6f83e6557beefd113793867f8919fca5d677b07a
head: 1feb5cb12438446df055d722289a8632bbf8edb5
commits:
- sha: 1feb5cb12438446df055d722289a8632bbf8edb5
  msg: 'fix: close the final review wave'
---

# Change summary — payments-feature-test
```

`.../cs-both/change-summary.md` — same as `cs-feature-test` but with a
`requirements-id: 22222222-2222-4222-8222-222222222222` line added alongside the plural.
`.../cs-neither/change-summary.md` — same as `cs-feature-test` with the whole
`requirements-ids` block deleted and no singular added.

`.../mtp-ordinary/manual-test-plan.md`:

```markdown
---
id: 55555555-5555-4555-8555-555555555555
seed-family-id: 66666666-6666-4666-8666-666666666666
feature: payments
generated-from-base-commit: 6f83e6557beefd113793867f8919fca5d677b07a
generated-from-head: 1feb5cb12438446df055d722289a8632bbf8edb5
generated-against-run-root: /tmp/demo
generated-in-activation: 77777777-7777-4777-8777-777777777777
requirements-id: 22222222-2222-4222-8222-222222222222
---

# Manual test plan — payments
```

`.../mtp-feature-test/manual-test-plan.md` — same, with `feature: payments-feature-test`
and `requirements-id` replaced by:

```yaml
requirements-ids:
- 22222222-2222-4222-8222-222222222222
- 44444444-4444-4444-8444-444444444444
```

Append the test block before `# ---- Summary`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: FAIL — the two plural fixtures are rejected (`additionalProperties`/`required`), and `cs-neither` is *accepted* only after the singular becomes optional, so it fails once too.

- [ ] **Step 3: Edit both schemas**

In `schemas/change-summary.schema.yaml`, remove `- requirements-id` from `required`, leaving:

```yaml
required:
  - id
  - feature
  - base-commit
  - head

oneOf:
  - required: [requirements-id]
  - required: [requirements-ids]
```

`oneOf` gives exactly-one semantics on its own: a document carrying both matches *both* branches, which `oneOf` rejects. Then add under `properties`, beside the existing `requirements-id`:

```yaml
  requirements-ids:
    type: array
    minItems: 1
    items:
      type: string
      pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"
    description: >
      Ordered UUIDs of every finished ordinary feature's archived
      requirements.md, for a feature-test entry — which has no blueprint of
      its own and is framed against all of them rather than one. Mutually
      exclusive with `requirements-id`; ordinary features keep the singular.
  commits:
    type: array
    description: >
      Commit list for a feature-test entry, written at stage 8 by
      `commits.sh populate-feature-test`. Ordinary features carry this on
      requirements.md instead; a feature-test entry has no requirements.md,
      so its change-summary is the home for the audit record.
    items:
      type: object
      additionalProperties: false
      required: [sha, msg]
      properties:
        sha:
          type: string
          pattern: "^[0-9a-f]{7,40}$"
        msg:
          type: string
```

`additionalProperties: false` stays — both new fields are declared under `properties`, so the constraint is satisfied without weakening it.

Apply the same `required` / `oneOf` / `requirements-ids` change to
`schemas/manual-test-plan.schema.yaml` (no `commits` field there).

- [ ] **Step 4: Make `review.sh sync-refs` tolerate the plural field**

Find the `sync-refs` re-point of `change-summary.requirements-id` in `scripts/review.sh` and guard it so a plural-field file is left alone rather than crashing or growing a second field:

```bash
    # A feature-test entry carries `requirements-ids` (plural) and has no
    # blueprint to rotate, so sync-refs can never legitimately re-point it.
    # Skip rather than write a singular field alongside the plural — that
    # would produce a file the oneOf gate rejects.
    if "${MI_PLUGIN_ROOT}/scripts/frontmatter.sh" get "$cs_file" requirements-ids >/dev/null 2>&1; then
      mi_info "sync-refs: $cs_file carries requirements-ids (feature-test entry); leaving it unchanged"
    else
      # ... existing singular re-point, unchanged ...
    fi
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: PASS — `17 passed, 0 failed`.

- [ ] **Step 6: Verify no shipped file regressed**

Run:

```bash
git ls-files 'millwright-inspector/*' \
  | grep -E '/(change-summary|manual-test-plan)\.md$' \
  | while IFS= read -r f; do
      scripts/frontmatter.sh validate "$f" \
        "$(basename "$f" .md)" >/dev/null 2>&1 || echo "REGRESSED: $f"
    done
echo "sweep done"
```

Expected: `sweep done` with no `REGRESSED:` lines.

- [ ] **Step 7: Commit**

```bash
git add schemas/change-summary.schema.yaml schemas/manual-test-plan.schema.yaml \
        scripts/review.sh tests/feature-test-workflow/
git commit -m "feat(schemas): accept a list of requirements ids for feature-test entries

A feature-test entry has no requirements.md of its own — it is framed
against every finished feature's requirements. Both schemas now take
exactly one of requirements-id (ordinary, unchanged) or requirements-ids
(plural). change-summary also gains an optional commits array, since a
feature-test entry has no requirements.md to carry its stage-8 commit list.

sync-refs skips a plural-field change-summary rather than writing a
singular alongside it, which the oneOf gate would reject."
```

---

### Task 4: `commits.sh feature-test-range`

The union commit range, with all three gates. Shared by the diagram pass (Task 8) and stage 8 (Task 5), so it lives in a script rather than duplicated prose.

**Files:**
- Modify: `scripts/commits.sh` (new subcommand + usage header)
- Test: `tests/feature-test-workflow/run.sh`

**Interfaces:**
- Consumes: `progress.md` `completed` list; each finished feature's latest `blueprints/history/v[N]/implementation/change-summary.md` frontmatter (`base-commit`, `head`).
- Produces: `commits.sh feature-test-range <ft-feature>`. On success, stdout line 1 is `<union_base>\t<head>`; subsequent lines are `contributor\t<feat>\t<base>\t<head>` and `omitted\t<feat>`. Exit `3` = a finished feature's head is unreachable from HEAD; exit `4` = nothing contributed; exit `5` = bases diverged, no single earliest.

- [ ] **Step 1: Write the failing test**

Append before `# ---- Summary`:

```bash
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
( cd "$repo" && git checkout -q -b side c1 && echo x > x.txt && git add x.txt && git commit -q -m orphan ) >/dev/null 2>&1
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: FAIL — every case fails; `commits.sh` exits non-zero on the unknown subcommand.

- [ ] **Step 3: Add the subcommand**

In `scripts/commits.sh`, insert a new case before the usage catch-all:

```bash
  feature-test-range)
    # Union commit range for a feature-test entry: the earliest base-commit
    # across every finished ordinary feature, through HEAD. Read-only.
    #
    # stdout line 1:  <union_base>\t<head>
    # then:           contributor\t<feat>\t<base>\t<head>
    #                 omitted\t<feat>
    # exit 3 = a finished feature's head is unreachable from HEAD
    # exit 4 = nothing contributed commits
    # exit 5 = bases diverged; no single earliest exists
    feature="${1:?feature required}"
    python3 - "$(mi_data_root)" "$(mi_progress_file)" "$feature" <<'PYEOF'
import os, re, sys, subprocess, yaml

data_root, progress_path, ft_feature = sys.argv[1], sys.argv[2], sys.argv[3]

def frontmatter(path):
    try:
        with open(path) as f:
            text = f.read()
    except OSError:
        return None
    m = re.match(r'^---\n(.*?)\n---\n', text, re.DOTALL)
    return (yaml.safe_load(m.group(1)) or {}) if m else None

prog = frontmatter(progress_path) or {}
completed = [c for c in (prog.get('completed') or []) if c != ft_feature]

def latest_change_summary(feat):
    """Newest finalized history version carrying an archived change-summary."""
    hist = os.path.join(data_root, 'workflow-stream', feat, 'blueprints', 'history')
    if not os.path.isdir(hist):
        return None
    versions = []
    for entry in os.listdir(hist):
        m = re.fullmatch(r'v(\d+)', entry)
        if m:
            versions.append((int(m.group(1)), entry))
    for _, entry in sorted(versions, reverse=True):
        path = os.path.join(hist, entry, 'implementation', 'change-summary.md')
        if os.path.isfile(path):
            return path
    return None

def is_ancestor(a, b):
    return subprocess.call(
        ['git', 'merge-base', '--is-ancestor', a, b],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0

head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()

contributors, omitted, unreachable = [], [], []
for feat in completed:
    cs = latest_change_summary(feat)
    if cs is None:
        omitted.append(feat)
        continue
    data = frontmatter(cs) or {}
    base, feat_head = data.get('base-commit'), data.get('head')
    if not base or not feat_head:
        omitted.append(feat)
        continue
    if not is_ancestor(feat_head, head):
        unreachable.append(feat)
        continue
    contributors.append((feat, base, feat_head))

if unreachable:
    sys.stderr.write(
        "error: feature-test-range: these finished features are not reachable "
        "from HEAD: " + ", ".join(unreachable) + "\n"
        "       The combined test cannot draw a picture that omits them. Merge "
        "or rebase so every feature's work is visible from one checkout, then "
        "re-run.\n")
    sys.exit(3)

if not contributors:
    sys.stderr.write(
        "error: feature-test-range: no finished feature contributed commits "
        "(all omitted: " + ", ".join(omitted) + "). There is no assembled "
        "implementation to test.\n")
    sys.exit(4)

bases = [b for _, b, _ in contributors]
earliest = None
for candidate in bases:
    if all(candidate == other or is_ancestor(candidate, other) for other in bases):
        earliest = candidate
        break

if earliest is None:
    sys.stderr.write(
        "error: feature-test-range: the finished features' base commits are "
        "diverged; no single earliest base exists. A contiguous <base>..HEAD "
        "range is the contract every downstream consumer is written against. "
        "Merge the lines together, then re-run.\n")
    sys.exit(5)

print(f"{earliest}\t{head}")
for feat, base, feat_head in contributors:
    print(f"contributor\t{feat}\t{base}\t{feat_head}")
for feat in omitted:
    print(f"omitted\t{feat}")
PYEOF
    ;;
```

Add to the usage header comment near the top of the file:

```bash
#   commits.sh feature-test-range <ft-feature>
#       Union commit range across every finished ordinary feature. Read-only.
#       exit 3 unreachable | 4 nothing contributed | 5 diverged bases.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: PASS — `25 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/commits.sh tests/feature-test-workflow/run.sh
git commit -m "feat(commits): derive the feature-test union commit range

Earliest base-commit across every finished ordinary feature, through HEAD,
sourced from each feature's archived change-summary (progress.md does not
retain base-commit after finish).

Three gates, each with its own exit code rather than a silent partial
result: a finished feature unreachable from HEAD refuses (3), nothing
contributing refuses (4), diverged bases refuse (5). A zero-commit
direct-empty feature is omitted and reported, not fatal."
```

---

### Task 5: `commits.sh populate-feature-test`

Stage 8's commits list for an entry with no `requirements.md` to carry it.

**Files:**
- Modify: `scripts/commits.sh` (new subcommand + usage header)
- Test: `tests/feature-test-workflow/run.sh`

**Interfaces:**
- Consumes: `commits.sh feature-test-range` (Task 4); the `commits` schema field (Task 3).
- Produces: `commits.sh populate-feature-test <ft-feature>` — writes `commits: [{sha, msg}, …]` into `workflow-stream/<ft-feature>/implementation/change-summary.md` frontmatter and re-validates. `populate-requirements` is untouched.

- [ ] **Step 1: Write the failing test**

Append before `# ---- Summary`:

```bash
# ---- Task 5: populate-feature-test ----------------------------------------

# seed_ft_change_summary <sandbox> <base> <head> — the live change-summary the
# diagram pass writes for the entry.
seed_ft_change_summary() {
  local dir="$1/workflow-stream/payments-feature-test/implementation"
  mkdir -p "$dir"
  cat > "$dir/change-summary.md" <<EOF
---
id: 33333333-3333-4333-8333-333333333333
requirements-ids:
- 22222222-2222-4222-8222-222222222222
feature: payments-feature-test
base-commit: $2
head: $3
---

# Change summary — payments-feature-test
EOF
}

t="populate-feature-test: writes one commits entry per commit in the union range"
repo="$(make_git_repo)"; sandbox="$(make_quest)"; seed_todo "$sandbox"
c1="$(sha_of "$repo" c1)"; c2="$(sha_of "$repo" c2)"; c4="$(sha_of "$repo" c4)"
seed_history "$sandbox" payments "$c1" "$c2"
seed_completed "$sandbox" payments
seed_ft_change_summary "$sandbox" "$c1" "$c4"
( cd "$repo" && MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/commits.sh" \
    populate-feature-test payments-feature-test ) >/dev/null 2>&1
n="$(grep -c '^- sha: ' "$sandbox/workflow-stream/payments-feature-test/implementation/change-summary.md")"
if [[ "$n" == "3" ]]; then
  ok "$t"
else
  ng "$t" "expected 3 commits (c2..c4), got $n"
fi

t="populate-feature-test: the written file still validates"
if "$REPO_ROOT/scripts/frontmatter.sh" validate \
   "$sandbox/workflow-stream/payments-feature-test/implementation/change-summary.md" \
   change-summary >/dev/null 2>&1; then
  ok "$t"
else
  ng "$t" "populated change-summary failed schema validation"
fi

t="populate-feature-test: preserves requirements-ids"
if grep -q '^requirements-ids:' \
   "$sandbox/workflow-stream/payments-feature-test/implementation/change-summary.md"; then
  ok "$t"
else
  ng "$t" "requirements-ids was dropped by the populate write"
fi

t="populate-feature-test: refuses when the change-summary is absent"
repo="$(make_git_repo)"; sandbox="$(make_quest)"; seed_todo "$sandbox"
c1="$(sha_of "$repo" c1)"; c2="$(sha_of "$repo" c2)"
seed_history "$sandbox" payments "$c1" "$c2"
seed_completed "$sandbox" payments
if ( cd "$repo" && MI_DATA_ROOT="$sandbox" "$REPO_ROOT/scripts/commits.sh" \
     populate-feature-test payments-feature-test ) >/dev/null 2>&1; then
  ng "$t" "accepted a missing change-summary"
else
  ok "$t"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: FAIL — unknown subcommand.

- [ ] **Step 3: Add the subcommand**

In `scripts/commits.sh`, immediately after the `feature-test-range` case:

```bash
  populate-feature-test)
    # Stage-8 commits list for a feature-test entry, which has no
    # requirements.md to carry it. Deliberately separate from
    # populate-requirements: that path runs for every ordinary completion and
    # must not grow feature-test branching.
    feature="${1:?feature required}"
    summary_file="$(mi_impl_dir "$feature")/change-summary.md"
    [[ -f "$summary_file" ]] || mi_die "populate-feature-test: $summary_file not found (run the diagram pass first)"
    range_line="$("${MI_PLUGIN_ROOT}/scripts/commits.sh" feature-test-range "$feature" | head -1)" || exit $?
    union_base="$(printf '%s' "$range_line" | cut -f1)"
    union_head="$(printf '%s' "$range_line" | cut -f2)"
    python3 - "$summary_file" "${union_base}..${union_head}" <<'PYEOF'
import sys, subprocess, re, yaml
path, rng = sys.argv[1], sys.argv[2]
log = subprocess.check_output(['git', 'log', '--pretty=format:%H\t%s', rng], text=True)
commits = []
for line in log.splitlines():
    if not line.strip():
        continue
    sha, msg = line.split('\t', 1)
    commits.append({'sha': sha, 'msg': msg})
with open(path) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
fm = yaml.safe_load(m.group(1)) or {}
fm['commits'] = commits
with open(path, 'w') as f:
    f.write('---\n')
    f.write(yaml.safe_dump(fm, default_flow_style=False, sort_keys=False))
    f.write('---\n')
    f.write(m.group(2))
print(f'mi: populated {len(commits)} commits into {path}', file=sys.stderr)
PYEOF
    "${MI_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$summary_file" change-summary >/dev/null
    ;;
```

Add the usage-header line:

```bash
#   commits.sh populate-feature-test <ft-feature>
#       Stage-8 commits list into the entry's change-summary frontmatter.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: PASS — `29 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/commits.sh tests/feature-test-workflow/run.sh
git commit -m "feat(commits): populate the feature-test commit list at stage 8

Writes the union range's commits into the entry's own change-summary,
since it has no requirements.md. Kept separate from populate-requirements,
which every ordinary completion calls and must stay unbranched."
```

---

### Task 6: The dispatcher fork (`commands/mi-continue.md`)

The heart of FTW-006. Two branches, both conditions evaluated ahead of an existing row's body.

**Files:**
- Modify: `commands/mi-continue.md` — Row A (dispatch table, ~line 118 area) and the `2 | any` active row / Approve Handler entry (~line 200 area)
- Test: `tests/feature-test-workflow/run.sh`

**Interfaces:**
- Consumes: `todo.sh is-feature-test` (Task 1), `progress.sh advance-to 2 5` (Task 2), `commits.sh feature-test-range` (Task 4).
- Produces: a feature-test entry reaches `current-stage=5, sub-flow=none, implementation-completed=true, base-commit=<union_base>` with `implementation/diagrams/` populated and `inspector-review.md` initialized.

- [ ] **Step 1: Write the failing test**

Append before `# ---- Summary`:

```bash
# ---- Task 6: mi-continue dispatcher fork ----------------------------------

MI_CONT="$REPO_ROOT/commands/mi-continue.md"

t="mi-continue: Row A branches on the identity predicate"
if grep -q 'is-feature-test' "$MI_CONT"; then
  ok "$t"
else
  ng "$t" "mi-continue.md never calls todo.sh is-feature-test"
fi

t="mi-continue: the fork never calls blueprints.sh ensure-current"
if grep -qE 'never calls .*ensure-current' "$MI_CONT"; then
  ok "$t"
else
  ng "$t" "mi-continue.md does not state that the fork skips ensure-current"
fi

t="mi-continue: the fork resolves the union range"
if grep -q 'feature-test-range' "$MI_CONT"; then
  ok "$t"
else
  ng "$t" "mi-continue.md does not resolve the union range"
fi

t="mi-continue: the fork advances with advance-to 2 5"
if grep -qE 'advance-to 2 5' "$MI_CONT"; then
  ok "$t"
else
  ng "$t" "mi-continue.md does not use the atomic 2->5 transition"
fi

t="mi-continue: the 2->5 write sets implementation-completed"
if grep -qE 'advance-to 2 5.*implementation-completed|implementation-completed=true' "$MI_CONT"; then
  ok "$t"
else
  ng "$t" "the fork does not set implementation-completed — resume-workflow would report state corruption"
fi

t="mi-continue: both the entry branch and the recovery branch exist"
n="$(grep -c 'is-feature-test' "$MI_CONT")"
if [[ "$n" -ge 2 ]]; then
  ok "$t"
else
  ng "$t" "expected >=2 is-feature-test call sites (Row A + recovery), found $n"
fi

t="mi-continue: states that ordinary features are unaffected"
if grep -qE 'falls through to today|unchanged for ordinary|ordinary features are unaffected|byte-identical' "$MI_CONT"; then
  ok "$t"
else
  ng "$t" "mi-continue.md does not record the ordinary-feature invariant at the fork"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: FAIL on all seven — `mi-continue.md` has no feature-test branch yet.

- [ ] **Step 3: Add the shared sequence and the Row A branch**

In `commands/mi-continue.md`, immediately after the Pre-flight dispatch table, add a new section:

````markdown
### Feature-test entry sequence (shared by Row A and the `2 | any` recovery branch)

Runs when the active — or about-to-be-active — feature is the cycle's feature-test entry.
It replaces stages 2 and 3 entirely: no blueprint is generated, approved, or planned.

**This sequence never calls `blueprints.sh ensure-current`.** That single omission is what
separates it from an ordinary activation, and it is why the branch cannot delegate to
`/mi-apply-impact` — see `docs/superpowers/specs/2026-08-14-feature-test-workflow-design.md`
§1.2.

```bash
# 1. Resolve and verify the union range BEFORE any mutation. Exit 3/4/5 are
#    refusals with their own diagnostics — relay and stop; nothing was written.
if ! range_line="$($CLAUDE_PLUGIN_ROOT/scripts/commits.sh feature-test-range "$ft_feature" 2>&1 | head -1)"; then
  echo "$range_line" >&2
  exit 1
fi
union_base="$(printf '%s' "$range_line" | cut -f1)"

# 2. Folder marker. NO ensure-current — this folder has no blueprints/.
$CLAUDE_PLUGIN_ROOT/scripts/folder-id.sh ensure "$ft_feature"

# 3. Pin the union base so the shipped freshness caches
#    (commits.sh change-summary-fresh / diagrams-fresh) work unchanged —
#    both key on .active.base-commit and HEAD.
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "base-commit=$union_base"
```

4. **Run the complete-feature diagram pass** — invoke `/mi-generate-implementation-diagrams`,
   which auto-detects the feature-test path (see that command's Step 1.5).

5. **Initialize the findings skeleton** (idempotent — `review.sh init` refuses to overwrite):

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
ov_file="$data_root/workflow-stream/$ft_feature/implementation/inspector-review.md"
[[ -f "$ov_file" ]] || $CLAUDE_PLUGIN_ROOT/scripts/review.sh init "$ft_feature"
```

6. **Atomic advance into the review step:**

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh advance-to 2 5 \
  --set sub-flow=none \
  --set implementation-completed=true
```

`implementation-completed=true` is **load-bearing, not cosmetic**. `/mi-resume-workflow`'s
Step 4 invariant asserts that any feature at stage ≥ 5 has it set; without it, every
`/mi-resume-workflow` on a feature-test entry would report "State corruption detected" and
recommend `/mi-abort-workflow`. It is also true on its face: the implementation is
complete — that is the premise of running a combined test at all.

7. **Hand off at stage 5** with the manual-test prompt, exactly as the stage-3 Resume
   Handler's Step 7 does. Answering `y` auto-fires `/mi-manual-test-plan --from-resume`,
   which takes its own feature-test derivation path.

**Not resumable.** An interruption before step 6 leaves the entry at stage 2 and the pass
re-runs from scratch on the next `/mi-continue`. Acceptable: the pass is idempotent and
derives entirely from committed state.
````

Then add the branch to **Row A**. In the Pre-flight dispatch table's Row A handler
description, replace the bare auto-fire with:

````markdown
| **Row A — between features:** … | Resolve `queue[0]`. If `todo.sh is-feature-test "$next"` exits 0, run `progress.sh activate` and then the **Feature-test entry sequence** above. Otherwise auto-fire `/mi-apply-impact` (unchanged). |
````

and add underneath the table:

````markdown
**Row A's feature-test branch.** `progress.sh activate` is called directly and stays
**byte-identical** — it keeps writing `current-stage=2` for every feature without
exception. Only the step *after* activation differs:

```bash
next="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh queue-remaining | sed '/^$/d' | head -1)"
if $CLAUDE_PLUGIN_ROOT/scripts/todo.sh is-feature-test "$next"; then
  ft_feature="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh activate)"
  # → run the Feature-test entry sequence above, then stop.
else
  # Ordinary feature: falls through to today's path, byte-identical.
  /mi-apply-impact
fi
```

For any feature that is not the cycle's feature-test entry, `is-feature-test` exits 1 and
control falls through to today's auto-fire unchanged. Ordinary features are unaffected.
````

- [ ] **Step 4: Add the `2 | any` recovery branch**

In the Active-cases dispatch table, change the stage-2 row to:

````markdown
| 2 | (any) | `todo.sh is-feature-test "$active_feature"` → **Feature-test entry sequence** (recovery re-entry). Otherwise → **Approve Handler** |
````

and add a note directly beneath the table:

````markdown
**Why the stage-2 row needs the branch too.** Two states park a feature-test entry at
`current-stage=2`: `/mi-abort-workflow` with no flag (`progress.sh reset` sets stage 2),
and a session break between activation and `advance-to 2 5`. Both re-enter here, and both
want the same idempotent sequence. Ordinary features still reach the Approve Handler on
exactly today's condition.
````

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: PASS — `36 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add commands/mi-continue.md tests/feature-test-workflow/run.sh
git commit -m "feat(mi-continue): route the feature-test entry to its own pipeline

Row A activates the entry directly and runs the diagram pass, then jumps
to stage 5 via advance-to 2 5; the stage-2 row carries the same sequence
as a recovery re-entry after abort or a session break. progress.sh
activate stays byte-identical and ordinary features fall through to
today's /mi-apply-impact auto-fire unchanged.

The 2->5 write sets implementation-completed=true: mi-resume-workflow's
invariant asserts it for any feature at stage >= 5, so omitting it would
make every resume report state corruption."
```

---

### Task 7: `/mi-apply-impact` refusal guard

Row A's fork means the command is never fired for a feature-test entry on the forward path. A manual invocation would still create the forbidden blueprint.

**Files:**
- Modify: `commands/mi-apply-impact.md:40-50` (top of Step 1, before the activation branch)
- Test: `tests/feature-test-workflow/run.sh`

**Interfaces:** Consumes `todo.sh is-feature-test` (Task 1).

- [ ] **Step 1: Write the failing test**

```bash
# ---- Task 7: mi-apply-impact refusal guard --------------------------------

MI_AI="$REPO_ROOT/commands/mi-apply-impact.md"

t="mi-apply-impact: guards on the identity predicate"
if grep -q 'is-feature-test' "$MI_AI"; then
  ok "$t"
else
  ng "$t" "mi-apply-impact.md has no feature-test guard"
fi

t="mi-apply-impact: the guard refuses before activating or ensuring current/"
if grep -qE 'before .*(activation|activate)|no activation, no ensure-current' "$MI_AI"; then
  ok "$t"
else
  ng "$t" "the guard does not state that it precedes activation"
fi

t="mi-apply-impact: the refusal points at /mi-continue"
if grep -q 'Type /mi-continue instead' "$MI_AI"; then
  ok "$t"
else
  ng "$t" "the refusal does not name the right command"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: FAIL on all three.

- [ ] **Step 3: Add the guard**

In `commands/mi-apply-impact.md`, insert immediately before the `active_feature_pre=` block at Step 1:

````markdown
**Feature-test guard (runs first — before activation, before `ensure-current`).**
A feature-test entry has no blueprint stage and its folder deliberately carries no
`blueprints/` (`FTW-002`). On the forward path `/mi-continue`'s Row A never fires this
command for such an entry; this guard closes the manual-invocation hole, where
`blueprints.sh ensure-current` would otherwise create the folder the design forbids.

```bash
# Guard the queue-head on a fresh run, and the active feature on a re-entry.
guard_candidate="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get-active 2>/dev/null || echo 'null')"
if [[ "$guard_candidate" == "null" || -z "$guard_candidate" ]]; then
  guard_candidate="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh queue-remaining 2>/dev/null | sed '/^$/d' | head -1)"
fi
if [[ -n "$guard_candidate" ]] && $CLAUDE_PLUGIN_ROOT/scripts/todo.sh is-feature-test "$guard_candidate"; then
  echo "error: '$guard_candidate' is this cycle's feature-test entry. It has no blueprint stage, and this command would create the blueprints/ folder its design forbids." >&2
  echo "       Type /mi-continue instead — the dispatcher routes it into the abbreviated pipeline (diagrams → test plan → run → review → resolution)." >&2
  exit 1
fi
```

No activation, no `ensure-current`, no state mutation — the guard refuses with
`progress.md` byte-identical. For every ordinary feature `is-feature-test` exits 1 and the
command proceeds exactly as today.
````

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: PASS — `39 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add commands/mi-apply-impact.md tests/feature-test-workflow/run.sh
git commit -m "feat(mi-apply-impact): refuse to blueprint a feature-test entry

Closes the manual-invocation hole: the forward path never fires this
command for the entry, but a hand-typed /mi-apply-impact would run
ensure-current and create the blueprints/ folder FTW-002 forbids. The
guard runs before activation, so it refuses with progress.md unchanged."
```

---

### Task 8: Complete-feature diagram pass (FTW-003)

**Files:**
- Modify: `commands/mi-generate-implementation-diagrams.md` — Step 1 (dest), Step 1.5 (mode detect), Step 2.1 (inputs), the sub-agent prompt's Phase 2 and Phase 3
- Test: `tests/feature-test-workflow/run.sh`

**Interfaces:** Consumes `todo.sh is-feature-test`, `commits.sh feature-test-range`. Produces `implementation/diagrams/` + `implementation/change-summary.md` carrying `requirements-ids`.

- [ ] **Step 1: Write the failing test**

```bash
# ---- Task 8: complete-feature diagrams ------------------------------------

MI_DIAG="$REPO_ROOT/commands/mi-generate-implementation-diagrams.md"

t="diagrams: detects the feature-test path"
if grep -q 'is-feature-test' "$MI_DIAG"; then
  ok "$t"
else
  ng "$t" "the command never detects a feature-test invocation"
fi

t="diagrams: uses the union range for a feature-test invocation"
if grep -q 'feature-test-range' "$MI_DIAG"; then
  ok "$t"
else
  ng "$t" "the command does not resolve the union range"
fi

t="diagrams: writes requirements-ids (plural) for a feature-test entry"
if grep -q 'requirements-ids' "$MI_DIAG"; then
  ok "$t"
else
  ng "$t" "the command does not write the plural requirements reference"
fi

t="diagrams: seeds from the ordinary features' archived blueprint diagrams"
if grep -qE 'history/v\[N\]/diagrams|archived .*blueprint diagram' "$MI_DIAG"; then
  ok "$t"
else
  ng "$t" "seeding source for a feature-test invocation is unstated"
fi

t="diagrams: states the larger cross-feature budget"
if grep -qE 'up to 5' "$MI_DIAG"; then
  ok "$t"
else
  ng "$t" "the enlarged sequence budget is not stated"
fi

t="diagrams: rejects sequences that redraw a single feature's own flow"
if grep -qE 'cross feature boundaries|must cross feature|re-draws one feature' "$MI_DIAG"; then
  ok "$t"
else
  ng "$t" "the cross-feature-only rule is not stated"
fi

t="diagrams: ordinary single-feature scoping is preserved"
if grep -qiE 'ordinary invocations are unchanged' "$MI_DIAG"; then
  ok "$t"
else
  ng "$t" "the ordinary-invocation invariant is not recorded"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: FAIL on all seven.

- [ ] **Step 3: Add the feature-test path**

In `commands/mi-generate-implementation-diagrams.md`, insert a new **Step 1.4 — Invocation
mode** between Step 1 and Step 1.5:

````markdown
### Step 1.4 — Invocation mode (ordinary vs. feature-test)

```bash
if $CLAUDE_PLUGIN_ROOT/scripts/todo.sh is-feature-test "$active_feature"; then
  ft_mode=1
  range_line="$($CLAUDE_PLUGIN_ROOT/scripts/commits.sh feature-test-range "$active_feature" | head -1)"
  union_base="$(printf '%s' "$range_line" | cut -f1)"
else
  ft_mode=0
fi
```

Auto-detected rather than flag-driven so it cannot be forgotten by a caller. **An ordinary
feature never matches**, so the single-feature path below — including its freshness
short-circuit and its affected-subjects derivation — is unreachable from the feature-test
code and its behaviour is unchanged.

When `ft_mode=1`, `base-commit` was already pinned to `union_base` by the caller
(`/mi-continue`'s feature-test sequence), so Step 1.5's `diagrams-fresh` and Step 2.1's
`change-summary-fresh` both work **unchanged** — they key on `.active.base-commit` and HEAD.
````

In **Step 2.1**, replace the `requirements_id` resolution with a mode branch:

````markdown
```bash
if [[ "$ft_mode" == "1" ]]; then
  # A feature-test entry has no requirements.md — it is framed against every
  # finished feature's. Collect their archived ids in queue order.
  requirements_ids="$($CLAUDE_PLUGIN_ROOT/scripts/commits.sh feature-test-range "$active_feature" \
    | awk -F'\t' '$1=="contributor" {print $2}' \
    | while IFS= read -r feat; do
        hist="$data_root/workflow-stream/$feat/blueprints/history"
        v="$(ls -d "$hist"/v[0-9]* 2>/dev/null | grep -vE '\.partial' | sed -n 's|.*/v\([0-9]\+\)$|\1|p' | sort -n | tail -1)"
        [[ -n "$v" ]] && $CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$hist/v$v/requirements.md" id
      done)"
else
  requirements_file="$data_root/workflow-stream/$active_feature/blueprints/current/requirements.md"
  requirements_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$requirements_file" id)"
fi
```
````

In **Step 2.2**, when `ft_mode=1`, init the change-summary with `REQUIREMENTS_IDS` instead of
`REQUIREMENTS_ID` (a YAML list), and record every `omitted` feature from
`feature-test-range` under the body's `## Omitted from analysis` so a zero-commit feature's
absence is visible.

In the **sub-agent prompt**, add a feature-test block:

````markdown
**When this is a feature-test invocation** (`ft_mode=1`, passed as `feature_test: true`):

- **Range.** `<union_base>..HEAD` spans every finished ordinary feature, not one feature's
  own work.
- **Seeding (Phase 2).** There is no `blueprints/current/diagrams` for this folder — it has
  no blueprint by design. Seed instead from each **ordinary** feature's archived stage-2
  set at `workflow-stream/<feat>/blueprints/history/v[N]/diagrams/*.puml` (newest finalized
  `v[N]`). A subject with no commits in the union range stays seeded and is tagged
  `seeded-only` against the feature it came from.
- **Budget (Phase 3).** 1 combined `use-case-<ft-feature>.puml`, **up to 5**
  `sequence-<flow>.puml`, **up to 2** structural. Larger than an ordinary feature's
  1 / 2–3 / ≤1 because the subject is larger.
- **Sequences must cross feature boundaries.** A sequence that re-draws one feature's own
  internal flow is rejected — that diagram already exists in that feature's history, and
  redrawing it adds pages without adding information. Draw the seams: where one feature's
  output becomes another's input, shared state, and handoffs.
- **Attribution.** In `## Changed files`, label each area with the feature that contributed
  it, so the framing can name the seams.
````

Finally, add a one-line invariant note near the top of Step 1.5:

````markdown
**Ordinary invocations are unchanged.** When `ft_mode=0` every branch below behaves exactly
as it did before the feature-test path existed, including the `fresh` short-circuit.
````

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: PASS — `46 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add commands/mi-generate-implementation-diagrams.md tests/feature-test-workflow/run.sh
git commit -m "feat(diagrams): frame the complete feature for a feature-test entry

Auto-detected union-range mode: spans every finished ordinary feature
instead of one commit range, seeds from their archived stage-2 diagrams
(this folder has no blueprint), and carries requirements-ids. Budget rises
to 1 use-case / <=5 sequences / <=2 structural, and sequences must cross
feature boundaries — redrawing one feature's own flow duplicates a diagram
that already exists in its history.

Ordinary invocations never match the predicate and are unchanged."
```

---

### Task 9: Whole-feature test plan (FTW-004)

**Files:**
- Modify: `commands/mi-manual-test-plan.md` — Step 1.5 (freshness gate), Step 3 (inputs), Step 5 (derivation + merge anchor)
- Test: `tests/feature-test-workflow/run.sh`

**Interfaces:** Consumes `todo.sh is-feature-test`, `todo.sh list IMPLEMENTED`, `todo.sh feature-test-status`. Produces `test/manual-test-plan.md` with `requirements-ids` and a `<!-- deferred-merge-point -->` anchor.

- [ ] **Step 1: Write the failing test**

```bash
# ---- Task 9: whole-feature test plan --------------------------------------

MI_MTP="$REPO_ROOT/commands/mi-manual-test-plan.md"

t="test plan: detects the feature-test path"
if grep -q 'is-feature-test' "$MI_MTP"; then
  ok "$t"
else
  ng "$t" "no feature-test derivation path"
fi

t="test plan: derives scenarios from IMPLEMENTED items"
if grep -qE 'list IMPLEMENTED' "$MI_MTP"; then
  ok "$t"
else
  ng "$t" "the derivation does not read IMPLEMENTED items"
fi

t="test plan: excludes unselected TODO items from scope"
if grep -qE 'never built|out of scope.*TODO|\[ \] TODO.*out of scope' "$MI_MTP"; then
  ok "$t"
else
  ng "$t" "FTW-009 scope rule is unstated"
fi

t="test plan: excludes the feature-test item from its own inputs"
if grep -qE 'excludes itself|its own input set|excluding the feature-test item' "$MI_MTP"; then
  ok "$t"
else
  ng "$t" "the self-exclusion rule is unstated"
fi

t="test plan: cross-feature scenarios dominate"
if grep -qE 'in combination|cross-feature scenarios dominate' "$MI_MTP"; then
  ok "$t"
else
  ng "$t" "the cross-feature priority is unstated"
fi

t="test plan: emits the deferred merge anchor for DTI-005"
if grep -q 'deferred-merge-point' "$MI_MTP"; then
  ok "$t"
else
  ng "$t" "the merge anchor is missing"
fi

t="test plan: freshness gate compares the id LIST for a feature-test entry"
if grep -q 'requirements-ids' "$MI_MTP"; then
  ok "$t"
else
  ng "$t" "the freshness gate does not handle the plural field"
fi

t="test plan: restates the macOS portability rule"
if grep -qE 'BSD|POSIX|macOS' "$MI_MTP"; then
  ok "$t"
else
  ng "$t" "portability constraint absent"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: FAIL on the seven feature-test cases (the portability one may already pass).

- [ ] **Step 3: Add the derivation path**

In `commands/mi-manual-test-plan.md`, add mode detection at the top of Step 1:

```bash
if $CLAUDE_PLUGIN_ROOT/scripts/todo.sh is-feature-test "$active_feature"; then
  ft_mode=1
else
  ft_mode=0
fi
```

In **Step 1.5**, branch the mismatch computation:

````markdown
When `ft_mode=1` the entry has no `requirements.md`; the plan carries `requirements-ids`
(plural). Staleness means **the cycle's finished set changed** since the plan was written:

```bash
if [[ "$ft_mode" == "1" ]]; then
  plan_req_ids="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$plan_path" requirements-ids | tr -d ' ' | sort)"
  current_req_ids="$($CLAUDE_PLUGIN_ROOT/scripts/commits.sh feature-test-range "$active_feature" \
    | awk -F'\t' '$1=="contributor" {print $2}' \
    | while IFS= read -r feat; do
        hist="$data_root/workflow-stream/$feat/blueprints/history"
        v="$(ls -d "$hist"/v[0-9]* 2>/dev/null | grep -vE '\.partial' | sed -n 's|.*/v\([0-9]\+\)$|\1|p' | sort -n | tail -1)"
        [[ -n "$v" ]] && $CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$hist/v$v/requirements.md" id
      done | sort)"
  mismatch=0
  [[ "$plan_req_ids" != "$current_req_ids" || "$plan_base_commit" != "$current_base_commit" ]] && mismatch=1
fi
```
````

In **Step 3**, add the input substitution table:

````markdown
**Feature-test input substitutions (`ft_mode=1`).** The entry owns no blueprint; it borrows
from the finished features' archived `blueprints/history/v[N]/`:

| Ordinary input | Feature-test substitute |
| --- | --- |
| `blueprints/current/requirements.md` | each finished feature's `history/v[N]/requirements.md` |
| `blueprints/current/config.md` | the **union** of the finished features' `history/v[N]/config.md` — merge Prerequisites, services, and env vars, de-duplicated |
| `implementation/change-summary.md` | the entry's own, over the union range |

The change-summary freshness gate, RUN_ROOT resolution, and the §4.1 results auto-rotation
all work unchanged, because `base-commit` is the union base.
````

In **Step 5**, add the derivation rules and the anchor:

````markdown
**Feature-test derivation (`ft_mode=1`).** Scenarios are derived, never transcribed — the
entry's todo item says only "test the whole feature implementation".

Inputs, in priority order:

1. `todo.sh list IMPLEMENTED` — everything that actually shipped this cycle, **excluding
   the feature-test item itself** (its id is field 3 of `todo.sh feature-test-status`).
2. The implementation itself, over the union range. **Where the implementation and the
   stated intent disagree, the implementation is what gets tested.**

Items the inspector left as `[ ] TODO` were **never built** and are out of scope — a
partially-selected cycle produces a plan covering only what shipped.

**Cross-feature scenarios dominate.** A scenario that merely re-runs one feature's existing
case is the exception and carries a one-line justification, because those already ran
during that feature's own workflow — repeating them wholesale reproduces the exact gap this
entry exists to close. Prioritise the seams: one feature's output becoming another's input,
shared state, ordering, and interactions no single-feature plan could have covered.

**Portability.** Every command must be POSIX/BSD-portable and run on macOS. GNU-only flags
(`cat -A`, `grep -P`, `sed -i` with no argument) are defects in the plan even when the
underlying code is correct.

**Merge anchor for `DTI-005`.** End `## 3. Test scenarios` with exactly this line:

```markdown
<!-- deferred-merge-point -->
```

The sibling `deferred-test-items` feature inserts carried-forward scenario groups
immediately above it. A stable anchor, independent of scenario lettering, needing no schema
change. This feature owns the anchor only — never the merge.
````

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: PASS — `54 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add commands/mi-manual-test-plan.md tests/feature-test-workflow/run.sh
git commit -m "feat(manual-test-plan): derive a whole-feature plan for the entry

New derivation path: scenarios from the cycle's IMPLEMENTED items and the
implementation, borrowing requirements and config from the finished
features' archived history. Cross-feature scenarios dominate; re-running
one feature's own case needs a justification, since it already ran.

Freshness for the entry compares the requirements-id LIST, so a feature
finishing after the plan was written marks it stale. Ends the scenarios
section with a deferred-merge-point anchor for DTI-005.

The single-feature path and the schema its output validates against are
unchanged."
```

---

### Task 10: Stage-8 substitution (FTW-007)

**Files:**
- Modify: `commands/mi-complete-workflow.md` — Steps 3, 3.5, 4, 5
- Test: `tests/feature-test-workflow/run.sh`

**Interfaces:** Consumes `todo.sh is-feature-test`, `commits.sh populate-feature-test` (Task 5).

- [ ] **Step 1: Write the failing test**

```bash
# ---- Task 10: stage-8 substitution ----------------------------------------

MI_CW="$REPO_ROOT/commands/mi-complete-workflow.md"

t="stage 8: branches on the identity predicate"
if grep -q 'is-feature-test' "$MI_CW"; then
  ok "$t"
else
  ng "$t" "no feature-test branch at stage 8"
fi

t="stage 8: commits come from populate-feature-test"
if grep -q 'populate-feature-test' "$MI_CW"; then
  ok "$t"
else
  ng "$t" "the substituted commits source is missing"
fi

t="stage 8: skips the check-current preflight for the entry"
if grep -qE 'check-current.*skip|skip.*check-current' "$MI_CW"; then
  ok "$t"
else
  ng "$t" "the preflight skip is unstated"
fi

t="stage 8: skips rotation and the implementation archive move"
if grep -qE 'no rotation|rotation .*skipped|permanent in place' "$MI_CW"; then
  ok "$t"
else
  ng "$t" "rotation/archive skip is unstated"
fi

t="stage 8: keeps lessons distillation from the entry's own evidence"
if grep -qE 'manual-test-results.*inspector-review|highest-value lesson source|working together' "$MI_CW"; then
  ok "$t"
else
  ng "$t" "lessons substitution is unstated"
fi

t="stage 8: reuses the existing queue-empty closure"
if grep -qE 'existing .*closure|closure .*unmodified|no second completion path' "$MI_CW"; then
  ok "$t"
else
  ng "$t" "the single-closure invariant is unrecorded"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: FAIL on all six.

- [ ] **Step 3: Add the substitution path**

In `commands/mi-complete-workflow.md`, add mode detection at the end of Step 0:

```bash
if $CLAUDE_PLUGIN_ROOT/scripts/todo.sh is-feature-test "$active_feature"; then
  ft_mode=1
else
  ft_mode=0
fi
```

Add the contract table after Branch III's description:

````markdown
**Feature-test entries take a substituted Branch III.** Of the four blueprint-dependent
steps, two are kept from a different source and two are skipped:

| Step | Ordinary | Feature-test (`ft_mode=1`) |
| --- | --- | --- |
| 2 — IMPLEMENTING → IMPLEMENTED | runs | runs (its own item) |
| 3 — commits list | `commits.sh populate-requirements` → `requirements.md` | `commits.sh populate-feature-test` → the entry's `change-summary.md` |
| 3.5 — lessons distillation | evidence keyed by requirements id | evidence = the entry's `inspector-review.md` + `test/manual-test-results.md` |
| 4 — `check-current --require-primer` preflight | must return 0 | **skipped** — nothing to assert without a blueprint, and it would only block closure |
| 4 — `blueprints.sh rotate` | runs | **skipped** |
| 5 — `implementation/` archive move | runs | **skipped** — permanent in place (`FTW-002`) |
| 6 — `progress.sh finish` | runs | runs |
| 7 — housekeeping | runs | runs |

Lessons distillation is deliberately **kept**: the whole-feature test is the only point in
the cycle that observes the features working *together*, which makes it the highest-value
lesson source in the run. Its `source_prefix` uses the entry's `change-summary.md` `id` in
place of a requirements id, preserving the re-append fence.

**Step 0 needs no change.** `current/requirements.md` is always absent for this folder and
there is no history, so `latest_reason_kind` returns empty, Branch II does not match, and
control reaches Branch III correctly.
````

Guard each affected step:

```bash
# Step 3
if [[ "$ft_mode" == "1" ]]; then
  $CLAUDE_PLUGIN_ROOT/scripts/commits.sh populate-feature-test "$active_feature"
else
  $CLAUDE_PLUGIN_ROOT/scripts/commits.sh populate-requirements "$active_feature"
fi

# Step 4 — preflight + rotate
if [[ "$ft_mode" == "0" ]]; then
  # ... existing check-current --require-primer preflight and blueprints.sh rotate ...
fi

# Step 5 — archive move
if [[ "$ft_mode" == "0" ]]; then
  # ... existing implementation/ archive loop ...
fi
```

And add to Step 7:

````markdown
**The closure itself is the shipped one, unmodified.** No second completion path is
introduced: the feature-test entry reaches the same `todo_count == 0` → `quest.sh end`
branch every final feature reaches. Because the entry is pinned last, its completion is
what empties the queue, so the cycle closes in one pass.
````

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: PASS — `60 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add commands/mi-complete-workflow.md tests/feature-test-workflow/run.sh
git commit -m "feat(mi-complete-workflow): substituted stage 8 for a feature-test entry

Commits and lessons are kept but re-sourced (union range; the entry's own
review and manual-test results); the check-current preflight, blueprint
rotation, and the implementation archive move are skipped, since the
folder has no blueprint and both its children are permanent.

The queue-empty closure is reused unmodified — one completion path, not
two that can diverge."
```

---

### Task 11: Abort and retry guidance (FTW-008)

Almost entirely a documentation task: the shipped abort mechanism already does the right thing.

**Files:**
- Modify: `commands/mi-abort-workflow.md` — Step 2 confirmation text, Step 6 report
- Test: `tests/feature-test-workflow/run.sh`

- [ ] **Step 1: Write the failing test**

```bash
# ---- Task 11: abort guidance ----------------------------------------------

MI_AB="$REPO_ROOT/commands/mi-abort-workflow.md"

t="abort: branches its guidance on the identity predicate"
if grep -q 'is-feature-test' "$MI_AB"; then
  ok "$t"
else
  ng "$t" "abort guidance does not branch for a feature-test entry"
fi

t="abort: tells a feature-test entry to re-run the diagram pass, not a blueprint"
if grep -qE 'diagram pass|re-run the diagram' "$MI_AB"; then
  ok "$t"
else
  ng "$t" "post-abort guidance still points at blueprint/planning recovery"
fi

t="abort: records that the plan is preserved and results do not carry forward"
if grep -qE 'results .*(rotated|do not carry forward)' "$MI_AB"; then
  ok "$t"
else
  ng "$t" "retry semantics for test/ are unstated"
fi

t="abort: no new abort mechanism is introduced"
if grep -q 'need no new abort mechanism' "$MI_AB"; then
  ok "$t"
else
  ng "$t" "the reuse invariant is unrecorded"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: FAIL on the first three.

- [ ] **Step 3: Branch the guidance**

In `commands/mi-abort-workflow.md`, add after Step 1:

```bash
if $CLAUDE_PLUGIN_ROOT/scripts/todo.sh is-feature-test "$active_feature"; then
  ft_mode=1
else
  ft_mode=0
fi
```

In Step 2's confirmation block, replace the stage-2 reset line with:

```bash
if [[ "$ft_mode" == "1" ]]; then
  echo "  - reset progress.md to the combined test's first step (the complete-feature diagram pass)"
else
  echo "  - reset progress.md to a fresh stage-2 state (active.feature + active.branch preserved for retry)"
fi
```

Add the explanatory block:

````markdown
**Feature-test entries need no new abort mechanism.** The no-flag path runs
`progress.sh reset`, which sets `current-stage=2` — and for a feature-test entry stage 2
*is* the diagram pass (`/mi-continue`'s recovery branch). The reset lands on the pipeline's
genuine first step, so only the guidance text branches.

Retry semantics for `test/`:

- **`manual-test-plan.md` is preserved.** It derives from the cycle's `IMPLEMENTED` items,
  the deferred entries, and committed code — none of which an abort changes — so
  regenerating it would reproduce nearly the same file at real cost.
- **`manual-test-results.md` does not carry forward.** This needs no new code:
  `progress.sh reset` mints a fresh `activation-id`, and `/mi-manual-test-plan`'s §4.1
  cross-activation guard then rotates the stale results into
  `manual-test-results.history/` on the next invocation. Carrying partial verdicts forward
  is how a scenario silently counts as passed without anyone re-running it.
````

Replace Step 6's no-flag report with a branch:

````markdown
- **(no flag), feature-test entry**: `> "Combined test aborted. '$active_feature' is back at its first step. Type /mi-continue to re-run the complete-feature diagram pass and regenerate the test plan. The existing manual-test plan is preserved; the previous run's results will be rotated into history on the next plan invocation."`
- **(no flag), ordinary feature**: unchanged.
````

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: PASS — `64 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add commands/mi-abort-workflow.md tests/feature-test-workflow/run.sh
git commit -m "docs(mi-abort-workflow): branch post-abort guidance for the entry

The shipped reset already lands a feature-test entry on its genuine first
step (stage 2 is the diagram pass), and the existing cross-activation
guard already rotates stale results, so only the guidance text changes —
no new abort mechanism."
```

---

### Task 12: Reporting surfaces (FTW-006 acceptance criterion)

**Files:**
- Modify: `commands/mi-resume-workflow.md` (Step 3 table), `scripts/info-bar.sh` (`render_active`)
- Test: `tests/feature-test-workflow/run.sh`

**Interfaces:** Consumes `todo.sh is-feature-test`. Derivation is **confined to these two surfaces**.

- [ ] **Step 1: Write the failing test**

```bash
# ---- Task 12: reporting ----------------------------------------------------

MI_RW="$REPO_ROOT/commands/mi-resume-workflow.md"
INFO_BAR="$REPO_ROOT/scripts/info-bar.sh"

t="resume: names the abbreviated steps"
if grep -qE 'combined test|abbreviated pipeline' "$MI_RW"; then
  ok "$t"
else
  ng "$t" "resume-workflow does not name the abbreviated steps"
fi

t="resume: derives identity from the feature name"
if grep -q 'is-feature-test' "$MI_RW"; then
  ok "$t"
else
  ng "$t" "resume-workflow does not derive feature-test identity"
fi

t="resume: stage-5 invariant tolerates the entry"
if grep -q 'feature-test entry too' "$MI_RW"; then
  ok "$t"
else
  ng "$t" "the stage>=5 invariant does not account for the entry"
fi

t="info-bar: renders feature-test step names"
if grep -q 'feature-test' "$INFO_BAR"; then
  ok "$t"
else
  ng "$t" "info-bar has no feature-test naming"
fi

t="info-bar: separates the two stage-5 steps by manual-test-state"
if grep -q 'manual-test-state' "$INFO_BAR"; then
  ok "$t"
else
  ng "$t" "info-bar cannot distinguish the plan step from the review step"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: FAIL on all five.

- [ ] **Step 3: Update `mi-resume-workflow.md`**

Add after Step 2's state reads:

```bash
if $CLAUDE_PLUGIN_ROOT/scripts/todo.sh is-feature-test "$active_feature"; then
  ft_mode=1
else
  ft_mode=0
fi
```

Add a feature-test recommendation table after the existing Step 3 table:

````markdown
**When `ft_mode=1`, use this table instead** — the entry runs the abbreviated pipeline, and
naming its steps after the ordinary stages would mislead:

| Stage | Sub-flow / state | Step name | Recommendation |
| --- | --- | --- | --- |
| 2 | any | combined test — drawing implementation diagrams | `/mi-continue` (re-runs the diagram pass; idempotent) |
| 5 | `none`, `manual-test-state=none` | combined test — test plan | `/mi-continue`, or `/mi-manual-test-plan` directly |
| 5 | `manual-testing` | combined test — manual run | `/mi-continue` (Manual-Test-Resume Handler) |
| 5 | `none`, `manual-test-state ∈ {complete, skipped}` | combined test — inspector review | Write findings, then `/mi-continue` |
| 6 | `reviewing` | combined test — findings resolution | `/mi-continue` when the session returns |
| 7 | — | combined test — finalizing | `/mi-complete-workflow` |

The two stage-5 rows are separated by `manual-test-state`, **not** by whether a plan file
exists: an inspector who declines the plan reaches the review step with
`manual-test-state=skipped` and no file on disk, and keying on file presence would report
them as still owing a plan.

**Never recommend `/mi-apply-impact` or `/mi-plan-implementation` for a feature-test
entry** — it has no blueprint or planning stage, and `/mi-apply-impact` refuses outright.
````

Amend Step 4's invariant:

````markdown
- If `stage ≥ 5`, then `implementation-completed` must be `true`. This holds for a
  feature-test entry too: `/mi-continue`'s fork sets it in the same atomic write as
  `advance-to 2 5`, precisely so this invariant keeps its meaning rather than needing an
  exemption.
````

- [ ] **Step 4: Update `scripts/info-bar.sh`**

Add a feature-test step map beside `STAGE_NAMES` (after line 43):

```python
FT_STEP_NAMES = {
    2: "combined test · diagrams",
    5: "combined test · review",
    6: "combined test · resolution",
    7: "combined test · finalizing",
}
FT_STAGE5_PLAN = "combined test · test plan"
FT_STAGE5_RUN = "combined test · manual run"
```

Replace `render_active` (line 104) with:

```python
def render_active(feature, stage, ft_name=None, sub_flow=None, mt_state=None):
    if ft_name and feature == ft_name:
        if stage == 5:
            if sub_flow == "manual-testing":
                name = FT_STAGE5_RUN
            elif mt_state in ("complete", "skipped"):
                name = FT_STEP_NAMES[5]
            else:
                name = FT_STAGE5_PLAN
        else:
            name = FT_STEP_NAMES.get(stage, "unknown")
        return f"mi-workflow · {truncate(feature)} · {name}"
    name = STAGE_NAMES.get(stage, "unknown")
    return f"mi-workflow · {truncate(feature)} · Stage {stage} · {name}"
```

At the call site (line 175), read the extra fields — `read_frontmatter_block` and
`yaml_top_level` already exist, so this is three lines:

```python
todo_block = read_frontmatter_block(os.path.join(quest_dir, "todo-list.md"))
ft_name = yaml_top_level(todo_block, "feature-test") if todo_block else None
sub_flow = yaml_nested(progress_block, "active", "sub-flow")
mt_state = yaml_nested(progress_block, "active", "manual-test-state")
print(render_active(nested_feature, stage, ft_name, sub_flow, mt_state))
```

The status bar must never crash the terminal: every read here already degrades to `None`
via `read_frontmatter_block`'s `OSError` guard, and `render_active` treats a `None`
`ft_name` as "ordinary feature".

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: PASS — `69 passed, 0 failed`.

- [ ] **Step 6: Verify the status bar still renders an ordinary feature**

Run:

```bash
printf '{"workspace":{"project_dir":"%s"}}' "$PWD" | bash scripts/info-bar.sh
```

Expected: a `mi-workflow · feature-test-workflow · Stage 3 · …` line (this cycle's active
feature is ordinary, so the ordinary format must be used), and no traceback.

- [ ] **Step 7: Commit**

```bash
git add commands/mi-resume-workflow.md scripts/info-bar.sh tests/feature-test-workflow/run.sh
git commit -m "feat(reporting): name the abbreviated pipeline's steps

No persisted field marks the abbreviated pipeline, so resume-workflow and
the status bar derive identity from the feature name. Confined to these
two surfaces. The two stage-5 steps are separated by manual-test-state,
not plan-file presence — declining the plan leaves no file but is past
that step."
```

---

### Task 13: Canonical project doc + ordinary-feature regression sweep

The written contracts (FTW-001, FTW-002, FTW-009) and the explicit regression check FTW-006 asks for.

**Files:**
- Modify: `docs/millwright-inspector-project.md` §3.4 (~line 415-475), §6, §7.3 (~line 1069), §7.4 (~line 1092-1107), §8 (~line 1713)
- Test: `tests/feature-test-workflow/run.sh`

- [ ] **Step 1: Write the failing test**

```bash
# ---- Task 13: canonical project doc + regression --------------------------

PROJ="$REPO_ROOT/docs/millwright-inspector-project.md"

t="project doc: documents the feature-test folder layout"
if grep -qE 'feature-test/' "$PROJ"; then
  ok "$t"
else
  ng "$t" "the feature-test folder shape is undocumented"
fi

t="project doc: states the deliberate absence of blueprints/"
if grep -qE 'deliberately omits .*blueprints|no .*blueprints/.*by design' "$PROJ"; then
  ok "$t"
else
  ng "$t" "the intentional blueprints/ absence is not stated"
fi

t="project doc: defines the abbreviated pipeline's five steps"
if grep -qE 'abbreviated pipeline' "$PROJ"; then
  ok "$t"
else
  ng "$t" "the abbreviated pipeline is undefined"
fi

t="project doc: states which ordinary stages are skipped"
if grep -qE 'stages 2 and 3 are skipped|skips stages 2 and 3' "$PROJ"; then
  ok "$t"
else
  ng "$t" "the skipped stages are unstated"
fi

t="project doc: records the derivation scope rule"
if grep -qE 'IMPLEMENTED.*contribute' "$PROJ"; then
  ok "$t"
else
  ng "$t" "FTW-009 scope rule is unrecorded"
fi

t="project doc: records the stage-8 substitution"
if grep -q 'populate-feature-test' "$PROJ"; then
  ok "$t"
else
  ng "$t" "stage-8 substitution is unrecorded"
fi

t="project doc: todo.sh table lists is-feature-test"
if grep -q 'is-feature-test' "$PROJ"; then
  ok "$t"
else
  ng "$t" "is-feature-test is missing from the script reference"
fi

t="project doc: advance-to whitelist records 2->5"
if grep -qE 'advance-to.*2→5|2→5, 3→5' "$PROJ"; then
  ok "$t"
else
  ng "$t" "the widened whitelist is unrecorded"
fi

t="project doc: the ordinary 8-stage dispatch table is still intact"
if grep -qE '\| 3 \| any \|' "$PROJ" && grep -qE '\| 6 \| .reviewing. \|' "$PROJ"; then
  ok "$t"
else
  ng "$t" "an ordinary dispatch row was damaged"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: FAIL on the first eight; the ninth (intactness) passes and must keep passing.

- [ ] **Step 3: Update §3.4 — folder layout**

Add after the four-regions list, the folder tree and forbidden-operations table from spec
§2.1/§2.2, including: both children are permanent, no archive move at completion, the same
`id.md` marker as every feature folder, and the accepted consequence that a re-run
overwrites rather than versions.

- [ ] **Step 4: Update §6 — the abbreviated pipeline**

Add a new subsection defining the five steps and the stage mapping from spec §1.6, stating
explicitly that **stages 2 and 3 are skipped**, that no new `current-stage` or `sub-flow`
value is introduced, and that `progress.schema.yaml` therefore needs no edit. **Leave the
ordinary 8-stage narrative and its dispatch table intact and unedited.**

- [ ] **Step 5: Update §7.3, §7.4, §8**

- **§7.3** — the stage-8 substitution table (spec §4.2).
- **§7.4** — qualify the line at 1092. It currently reads "The feature-test entry adds **no
  new dispatcher rows**". That stays true and gains: "Row A and the `2 | any` row each
  carry a branch evaluated ahead of their existing body; the rows themselves, their order,
  and their match conditions for every other feature are unchanged."
- **§8** — add `is-feature-test` to the `todo.sh` row, `feature-test-range` and
  `populate-feature-test` to the `commits.sh` row, and update the `progress.sh` row's
  `advance-to` description to `2→5, 3→5, 5→7, 6→7`.

- [ ] **Step 6: Run the ordinary-feature regression check (FTW-006's explicit ask)**

Verify against the real repo state that an ordinary feature is untouched:

```bash
# 1. The identity predicate must not match this cycle's ordinary features.
scripts/todo.sh is-feature-test feature-test-workflow && echo "REGRESSION: ordinary feature matched" || echo "ok: ordinary feature does not match"
scripts/todo.sh is-feature-test deferred-test-items && echo "REGRESSION: ordinary feature matched" || echo "ok: ordinary feature does not match"

# 2. Every shipped artifact still validates.
bash tests/feature-test-entry/run.sh
bash tests/blueprint-lessons/run.sh
bash tests/blueprint-review/run.sh
bash tests/bundle/run.sh
bash tests/lint/run.sh

# 3. This feature's own suite.
bash tests/feature-test-workflow/run.sh
```

Expected: both `ok:` lines, and every suite exits 0. **Any failure here blocks the task** —
it means an ordinary path changed behaviour.

- [ ] **Step 7: Run test to verify it passes**

Run: `bash tests/feature-test-workflow/run.sh`
Expected: PASS — `78 passed, 0 failed`.

- [ ] **Step 8: Commit**

```bash
git add docs/millwright-inspector-project.md tests/feature-test-workflow/run.sh
git commit -m "docs: record the abbreviated feature-test pipeline in the project spec

Adds the folder layout and its forbidden operations (3.4), the five-step
pipeline and stage mapping (6), the stage-8 substitution (7.3), the two
dispatcher branches (7.4), and the new script subcommands (8).

The ordinary 8-stage narrative and its dispatch table are intact and
unedited, and the full test suite passes for every sibling feature."
```

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: §1.1 → Task 1; §1.2/§1.3/§1.4 → Task 6; §1.5/§1.6 → Tasks 12, 13; §2.1/§2.2 → Task 13; §2.3 → Task 3; §2.4 → Tasks 9, 13; §3.1 → Task 4; §3.2 → Task 8; §4.1 → Task 9; §4.2 → Tasks 5, 10; §4.3 → Task 11; §5 → Task 13. The spec's Testing list is distributed: `is-feature-test` (Task 1), `advance-to` (Task 2), schema round-trip (Task 3), union-range gates (Task 4), ordinary regression (Task 13 Step 6), end-to-end (deferred — see below).

**Goal coverage.** FTW-001 → Tasks 6, 13. FTW-002 → Task 13. FTW-003 → Tasks 4, 8. FTW-004 → Task 9. FTW-005 → consumed, not extended; asserted by Task 9's tests and Task 13's regression sweep. FTW-006 → Tasks 1, 2, 6, 7, 12, 13. FTW-007 → Tasks 5, 10. FTW-008 → Task 11. FTW-009 → Tasks 9, 13.

**Type consistency.** `todo.sh is-feature-test <name>` → exit 0/1, used identically in Tasks 6, 7, 8, 9, 10, 11, 12. `commits.sh feature-test-range <feature>` → line 1 `<base>\t<head>`, then `contributor\t…` / `omitted\t…`; consumed with the same `awk -F'\t' '$1=="contributor" {print $2}'` idiom in Tasks 5, 8, 9. `ft_mode` is the local flag name in every command that branches. `requirements-ids` is spelled the same in the schemas (Task 3), the diagram writer (Task 8), and the freshness gate (Task 9).

**Known deferral.** The spec's end-to-end verification ("a two-feature cycle driven to the feature-test entry") is **not** a plan task. It needs a cycle whose `todo-list.md` declares a feature-test entry, and this cycle's own does not (`todo.sh feature-test-status` reports `none` — it was scaffolded before `feature-test-queue-entry` shipped). It is genuinely inspector-driven work for the stage-5 manual test plan, not an automated suite, and it is called out here so it is not mistaken for an oversight.
