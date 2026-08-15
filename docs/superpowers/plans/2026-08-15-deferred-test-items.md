# Deferred Test Items Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a manual-test scenario that cannot be run during an individual feature's own workflow be carried forward, deliberately and visibly, to the cycle's whole-feature test — instead of being failed, skipped, or forgotten.

**Architecture:** A new `deferred-tests.md` artifact under the feature-test folder's `test/` child, written by a new `defer` disposition in the ordinary manual-test run and read by the whole-feature plan generator at a reserved merge anchor. Integrity is enforced by a new `deferred` verdict counter plus two completion gates — one blocking on the feature-test entry, one report-only on ordinary features.

**Tech Stack:** Bash 3.2 (macOS default) + Python 3 for parsing, JSON-Schema (draft-07) YAML under `schemas/`, markdown templates under `templates/`, markdown command recipes under `commands/`, bash assertion suites under `tests/<name>/run.sh`.

**Spec:** `docs/superpowers/specs/2026-08-15-deferred-test-items-design.md` (commit `e4e24e0`)

## Global Constraints

Every task's requirements implicitly include this section.

- **Branch:** `feat/mi-run/feature-test-workflow`. Commit per task; do not push.
- **Zero-deferral cycles must behave byte-identically to today** — every prompt string, every render, every gate. This is the most-tested property in the plan.
- **The feature-test folder keeps exactly two children** — `implementation/` and `test/`. Never a third. Never a `blueprints/`.
- **`deferred-tests.md` is never rotated into history.** It lives in `test/`, which is feature-permanent.
- **A deferral is never a finding.** `scripts/review.sh` is not modified by any task in this plan.
- **The scenario-id grammar is byte-identical.** No new prefix, no reserved letter range, no new frontmatter field on `manual-test-plan.md` or `manual-test-results.md`.
- **Counter identity:** `passed + failed + skipped + deferred == total` at every recompute site.
- **Portability:** POSIX/BSD, must run on macOS. No GNU-only flags.

### Shell traps — these produce silent wrong answers, not crashes

Verified empirically in this repo; prose-grep tests cannot catch any of them. Every task that writes bash must respect all five.

1. **`frontmatter.sh get` / `mi_fm_get` exit 0 and print the literal string `null` for an absent field.** Never test presence by exit code. Test the value: `[[ -n "$x" && "$x" != "null" ]]`.
2. **A pipeline's exit status is the *last* command's, not the interesting one's,** unless `pipefail` is set. Never guard on a piped command's status. Resolving a *value* through `| head -1` is fine.
3. **`sed`'s `\+` is a GNU extension.** BSD/macOS sed matches nothing and prints empty. Use `\([0-9][0-9]*\)`, or prefer Python.
4. **A branch or loop body whose last command is a false `&&`-list returns 1** and can abort the enclosing `$( )` under `set -e`. Always use `if …; then …; fi`, never a bare `[[ … ]] && x=1` as the last statement of a block.
5. **Each fenced bash block in a command file is a separate invocation with no shared shell state.** Never carry a flag across blocks. Either re-derive it at the consumption site or default it there (`"${ft_mode:-0}"`) — and never default a feature-enabling flag to "off", because that silently disables the feature.

Also: an empty array expanded as `"${a[@]}"` under `set -u` aborts on bash 3.2. Guard on `${#a[@]}` first.

### One refinement to the spec, made here

Spec § 1.5 says `deferred-tests.sh upsert` reads `Action`/`Expected` from stdin. This plan uses `--action` / `--expected` flags instead. Two blobs cannot share one stdin without a sentinel-delimited payload, and the caller is an LLM following a recipe — flags are unambiguous where a sentinel format is not. Bash argv carries embedded newlines fine.

Spec § 2.1 defines `offer_defer` as a value computed once at run start. This plan makes it `deferred-tests.sh offer-defer <feature>`, a script predicate, because trap 5 above means a value computed in one fenced block is simply absent in the next — and the safe default for a missing flag ("off") would silently disable the whole feature.

---

## File Structure

**Created:**

| File | Responsibility |
| --- | --- |
| `schemas/deferred-tests.schema.yaml` | Frontmatter contract for the artifact |
| `templates/deferred-tests.md.tmpl` | Artifact skeleton + body-shape documentation |
| `scripts/deferred-tests.sh` | All artifact mutation and the `offer-defer` predicate |
| `tests/deferred-test-items/run.sh` | Assertion suite for DTI-001..008 |

**Modified:**

| File | Change |
| --- | --- |
| `scripts/blueprints.sh` | `deferred-tests-path` subcommand + usage string |
| `commands/mi-continue.md` | Row A `ensure` arg fix; stage-1.5 creation; Gate 1 on both finalization paths |
| `commands/mi-manual-test-run.md` | `defer` disposition at 7 sites; commit path; counter; attribution line; Gate 2 |
| `commands/mi-manual-test-plan.md` | Merge at the anchor; generated-plan vocabulary prose |
| `commands/mi-complete-workflow.md` | Gate 2's ordinary-feature stage-8 preflight wording |
| `schemas/manual-test-results.schema.yaml` | `deferred` counter, optional with default 0 |
| `templates/manual-test-results.md.tmpl` | `deferred: 0` |
| `templates/manual-test-plan.md.tmpl` | Conditional `defer` in the vocabulary line |
| `docs/millwright-inspector-project.md` | §§ 3.4.1, 6.4, 7.3, 7.4, script table |

**Task dependency order.** 1 → 2 gate everything (the artifact and its helper). 3 is independent (a one-line repair) and can run any time. 4 depends on 2. 5 (counter) must precede 6 (disposition), because the commit path recomputes counts. 7 depends on 2. 8 depends on 2 and 7 (it reads `Merged as:`). 9 depends on 5. 10 depends on all.

---

## Task 1: The `deferred-tests` artifact — schema, template, path resolver

Implements DTI-001 (registration + location). Delivers a file that `frontmatter.sh` can render and validate, and a resolver that finds it.

**Files:**
- Create: `schemas/deferred-tests.schema.yaml`
- Create: `templates/deferred-tests.md.tmpl`
- Modify: `scripts/blueprints.sh` (add subcommand before the `*)` case at line ~608; extend the usage string at line ~609)
- Create: `tests/deferred-test-items/run.sh`
- Modify: `docs/millwright-inspector-project.md` (script table row for `blueprints.sh`)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `blueprints.sh deferred-tests-path <feature>` → prints `<data_root>/workflow-stream/<feature>/test/deferred-tests.md`
  - Template kind name `deferred-tests`, taking substitutions `FEATURE_TEST`, `QUEST_SLUG`, `CREATED_AT` (`UUID` is auto-filled by `frontmatter.sh init`)

- [ ] **Step 1: Write the failing test**

Create `tests/deferred-test-items/run.sh`:

```bash
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
if "$BP" bogus-subcommand 2>&1 | grep -q 'deferred-tests-path'; then
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
```

Then `chmod +x tests/deferred-test-items/run.sh`.

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/deferred-test-items/run.sh`
Expected: FAIL — `deferred-tests-path` is not a known subcommand, and the template does not exist.

- [ ] **Step 3: Write the schema**

Create `schemas/deferred-tests.schema.yaml`:

```yaml
$schema: "http://json-schema.org/draft-07/schema#"
$id: millwright-inspector-development-machine/deferred-tests.schema.yaml
title: workflow-stream/<ft-name>/test/deferred-tests.md frontmatter
description: >
  Carried-forward manual-test scenarios for a cycle's whole-feature test
  entry. Written by /mi-manual-test-run when the inspector answers `defer`
  during an ordinary feature's manual-test run; read by
  /mi-manual-test-plan's feature-test render path, which merges every entry
  into `## 3. Test scenarios` above the `<!-- deferred-merge-point -->`
  anchor.

  Body holds one `### <originating-feature>/<originating-scenario> — <title>`
  block per entry under `## Deferred scenarios`; this schema validates
  frontmatter shape only. The composite heading key is the entry's identity —
  what the upsert matches on and what the merge matches on.

  Lifecycle: created at stage 1.5 alongside the feature-test folder, lives in
  `test/` which is feature-permanent, and is never rotated into history.

  No resolution counters live here. Whether an entry has been answered is
  derived at gate time from the feature-test entry's manual-test-results.md,
  so it can never go stale.

type: object
additionalProperties: false
required:
  - id
  - feature-test
  - quest-slug
  - created-at

properties:
  id:
    type: string
    pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"
    description: UUID for cross-references; minted via scripts/uuid.sh.

  feature-test:
    type: string
    minLength: 1
    pattern: "^[a-z0-9][a-z0-9-]*$"
    description: >
      The feature-test entry that owns this file; mirrors the
      workflow-stream/<name>/ folder holding it.

  quest-slug:
    type: string
    minLength: 1
    description: >
      Slug of the quest cycle this file belongs to. Deferrals are
      cycle-scoped; the slug makes a stale file from a prior cycle
      identifiable by inspection.

  created-at:
    type: string
    minLength: 1
    description: ISO-8601 timestamp captured at stage-1.5 creation.
```

- [ ] **Step 4: Write the template**

Create `templates/deferred-tests.md.tmpl`:

```markdown
---
id: {{UUID}}
feature-test: {{FEATURE_TEST}}
quest-slug: {{QUEST_SLUG}}
created-at: {{CREATED_AT}}
---

# Deferred test items — {{FEATURE_TEST}}

Manual-test scenarios carried forward from this cycle's ordinary features to the
whole-feature test. An entry lands here when the inspector answers `defer` during an
ordinary feature's `/mi-manual-test-run`, because the behaviour under test depends on a
feature later in the queue.

`/mi-manual-test-plan`'s feature-test render path merges every entry below into
`## 3. Test scenarios`, immediately above the `<!-- deferred-merge-point -->` anchor, and
writes the assigned scenario id back into that entry's `Merged as:` field.

<!--
ENTRY SHAPE — one block per entry, all of them under `## Deferred scenarios` below.

The heading is the entry's identity: `<originating-feature>` and `<originating-scenario>`
joined by `/`. That composite key is what makes the upsert idempotent and what the merge
matches on. There is no separate numbering to renumber when an entry is removed.

  ### payments/B.2 — refund shows in the audit trail

  - **Originating feature:** payments
  - **Originating scenario:** B.2
  - **Action:** |
      1. Sign in as an admin and open order #1001
      2. Issue a full refund
  - **Expected:** |
      - The refund appears in the audit trail within 5s
      - The entry names the acting admin
  - **Reason:** the audit-log feature ships later in this cycle
  - **Deferred at:** "2026-08-15T10:22:11Z"
  - **Merged as:** A.7

`Action`, `Expected`, and `Reason` are copied out of the originating plan at defer time,
never referenced — an entry must be runnable weeks later by someone who never opens the
originating workflow.

`Merged as:` is blank until the whole-feature plan is generated. It is the machine-checkable
link the completion gate reads: an entry whose `Merged as:` id has no verdict block in the
feature-test entry's manual-test-results.md blocks completion.

TWO LAYOUT RULES, both load-bearing for the parser in scripts/deferred-tests.sh:

  1. This comment sits ABOVE `## Deferred scenarios`, never inside it. Every parser scopes
     itself to that section, so anything above the heading is invisible to them.
  2. The example above is indented two spaces so its `###` is not at column 0. Belt and
     braces: even if this block were moved into the section, the example would still not
     be counted as a real entry.

Undo either one and a freshly-rendered file reports one phantom entry, which would block
the feature-test entry's completion forever.
-->

## Deferred scenarios

(populated by `/mi-manual-test-run` when the inspector answers `defer`)
```

- [ ] **Step 5: Add the path resolver**

In `scripts/blueprints.sh`, insert immediately after the `manual-test-results-path)` case block (before `manual-test-plan-rotate)`):

```bash
  deferred-tests-path)
    feature="${1:?feature required}"
    echo "$(mi_test_dir "$feature")/deferred-tests.md"
    ;;
```

Then extend the usage string in the `*)` case to include `deferred-tests-path`:

```bash
    echo "usage: blueprints.sh {ensure-current|rotate|resume-partial|preserve-inspector-sections|check-current|branch-status|manual-test-plan-path|manual-test-results-path|deferred-tests-path|manual-test-plan-rotate|manual-test-results-rotate-only} ..." >&2
```

- [ ] **Step 6: Update the script table in the project doc**

In `docs/millwright-inspector-project.md`, the `blueprints.sh` row of the script table: add `deferred-tests-path` to its subcommand list, after `manual-test-results-path`.

- [ ] **Step 7: Run the tests**

Run: `tests/deferred-test-items/run.sh`
Expected: PASS — 0 failed.

- [ ] **Step 8: Commit**

```bash
git add schemas/deferred-tests.schema.yaml templates/deferred-tests.md.tmpl \
        scripts/blueprints.sh tests/deferred-test-items/run.sh \
        docs/millwright-inspector-project.md
git commit -m "feat(deferred-test-items): add the deferred-tests artifact and path resolver (DTI-001)"
```

---

## Task 2: `scripts/deferred-tests.sh` — the artifact helper

Implements DTI-001 (mutation). Delivers every read and write path the rest of the plan calls, plus the `offer-defer` predicate that replaces the spec's cross-block flag.

**Files:**
- Create: `scripts/deferred-tests.sh`
- Modify: `tests/deferred-test-items/run.sh` (append a Task 2 section before `# ---- Summary`)
- Modify: `docs/millwright-inspector-project.md` (add a script-table row)

**Interfaces:**
- Consumes: `blueprints.sh deferred-tests-path <feature>` (Task 1); template kind `deferred-tests` (Task 1).
- Produces:
  - `deferred-tests.sh path <ft>` → resolved path
  - `deferred-tests.sh count <ft>` → integer; `0` when the file is absent
  - `deferred-tests.sh upsert <ft> --feature <f> --scenario <s> --title <t> --reason <r> --action <a> --expected <e> [--deferred-at <ts>]` → idempotent by `<f>/<s>`; auto-creates the file; preserves an existing entry's `Merged as:`
  - `deferred-tests.sh list <ft>` → TSV rows `<feature>\t<scenario>\t<merged-as>\t<title>`
  - `deferred-tests.sh set-merged-as <ft> <f> <s> <id>` → writes the back-reference
  - `deferred-tests.sh remove <ft> <f> <s>` → drops one entry; exit 3 if absent
  - `deferred-tests.sh offer-defer <active-feature>` → exit 0 if `defer` should be offered, exit 1 otherwise

- [ ] **Step 1: Write the failing test**

Append to `tests/deferred-test-items/run.sh`, immediately before the `# ---- Summary` block:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/deferred-test-items/run.sh`
Expected: FAIL — `scripts/deferred-tests.sh` does not exist.

- [ ] **Step 3: Write the helper**

Create `scripts/deferred-tests.sh`:

```bash
#!/usr/bin/env bash
# deferred-tests.sh — manage <ft>/test/deferred-tests.md, the carried-forward
# manual-test scenarios a cycle's whole-feature test must still run.
#
# Writers: /mi-manual-test-run (upsert, on a `defer` verdict) and
# /mi-manual-test-plan (set-merged-as, during the feature-test render).
# Readers: /mi-manual-test-plan (merge) and /mi-continue (the completion gate).
#
# Entry identity is the composite key <originating-feature>/<originating-scenario>,
# carried in the block heading. There is no separate numbering.
#
# Self-validation: every mutating subcommand runs frontmatter.sh validate after
# the write — the PostToolUse write-hook only fires on Edit/Write tool calls, so
# a script-written artifact must validate inline.
#
# Usage:
#   deferred-tests.sh path <ft>
#   deferred-tests.sh count <ft>
#   deferred-tests.sh list <ft>
#   deferred-tests.sh upsert <ft> --feature <f> --scenario <s> --title <t>
#                               --reason <r> --action <a> --expected <e>
#                               [--deferred-at <iso8601>]
#   deferred-tests.sh set-merged-as <ft> <f> <s> <scenario-id>
#   deferred-tests.sh remove <ft> <f> <s>
#   deferred-tests.sh offer-defer <active-feature>

set -euo pipefail
source "$(dirname "$0")/internal/common.sh"

dt_file() {
  "${MI_PLUGIN_ROOT}/scripts/blueprints.sh" deferred-tests-path "${1:?feature-test name required}"
}

dt_validate() {
  "${MI_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$1" deferred-tests >/dev/null
}

# PARSING CONTRACT — every Python block below repeats these three lines:
#
#   sec  = re.search(r'(?m)^## Deferred scenarios[ \t]*$', content)
#   rest = content[sec.end():] ; nxt = re.search(r'(?m)^## ', rest)
#   sec_start, sec_end = sec.end(), sec.end() + (nxt.start() if nxt else len(rest))
#
# Scoping to that section is load-bearing, not tidiness: the template's
# entry-shape comment sits ABOVE the heading and contains a worked example with
# a `###` line. An unscoped whole-file scan counts it as a real entry, so a
# freshly rendered file reports one phantom deferral — which would block the
# feature-test entry's completion forever. The idiom is repeated inline rather
# than factored out because each block is a quoted heredoc: a shell variable
# would not expand inside it.

# Render the artifact when it does not exist yet. Idempotent.
dt_ensure() {
  local ft dest slug
  ft="$1"
  dest="$(dt_file "$ft")"
  if [[ -f "$dest" ]]; then
    printf '%s' "$dest"
    return 0
  fi
  slug="$(mi_active_quest_slug 2>/dev/null || true)"
  if [[ -z "$slug" || "$slug" == "null" ]]; then
    mi_die "deferred-tests: no active quest cycle; cannot create $dest"
  fi
  "${MI_PLUGIN_ROOT}/scripts/frontmatter.sh" init deferred-tests "$dest" \
    "FEATURE_TEST=$ft" \
    "QUEST_SLUG=$slug" \
    "CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null
  printf '%s' "$dest"
}

cmd="${1:-}"; shift || true

case "$cmd" in
  path)
    dt_file "${1:?feature-test name required}"
    ;;

  ensure)
    dt_ensure "${1:?feature-test name required}"
    ;;

  count)
    ft="${1:?feature-test name required}"
    dest="$(dt_file "$ft")"
    if [[ ! -f "$dest" ]]; then
      echo 0
      exit 0
    fi
    python3 - "$dest" <<'PYEOF'
import re, sys
with open(sys.argv[1]) as f:
    content = f.read()
sec = re.search(r'(?m)^## Deferred scenarios[ \t]*$', content)
if not sec:
    print(0)
    sys.exit(0)
rest = content[sec.end():]
nxt = re.search(r'(?m)^## ', rest)
window = rest[:nxt.start()] if nxt else rest
print(len(re.findall(r'(?m)^### [^/\s]+/[^\s]+ — ', window)))
PYEOF
    ;;

  list)
    ft="${1:?feature-test name required}"
    dest="$(dt_file "$ft")"
    if [[ ! -f "$dest" ]]; then
      exit 0
    fi
    python3 - "$dest" <<'PYEOF'
import re, sys
with open(sys.argv[1]) as f:
    content = f.read()
sec = re.search(r'(?m)^## Deferred scenarios[ \t]*$', content)
if not sec:
    sys.exit(0)
rest = content[sec.end():]
nxt = re.search(r'(?m)^## ', rest)
window = rest[:nxt.start()] if nxt else rest
HEAD = re.compile(r'(?m)^### ([^/\s]+)/([^\s]+) — (.*)$')
for m in HEAD.finditer(window):
    feature, scenario, title = m.group(1), m.group(2), m.group(3).strip()
    # Block runs to the next ### / ## heading or the end of the section.
    tail = window[m.end():]
    nb = re.search(r'(?m)^(###|##) ', tail)
    block = tail[:nb.start()] if nb else tail
    mm = re.search(r'(?m)^- \*\*Merged as:\*\*[ \t]*(.*)$', block)
    merged = mm.group(1).strip() if mm else ''
    print('\t'.join([feature, scenario, merged, title]))
PYEOF
    ;;

  upsert)
    ft="${1:?feature-test name required}"; shift
    feature=""; scenario=""; title=""; reason=""; action=""; expected=""; deferred_at=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --feature)     [[ $# -ge 2 ]] || mi_die "upsert: --feature requires a value";     feature="$2"; shift 2 ;;
        --feature=*)   feature="${1#--feature=}"; shift ;;
        --scenario)    [[ $# -ge 2 ]] || mi_die "upsert: --scenario requires a value";    scenario="$2"; shift 2 ;;
        --scenario=*)  scenario="${1#--scenario=}"; shift ;;
        --title)       [[ $# -ge 2 ]] || mi_die "upsert: --title requires a value";       title="$2"; shift 2 ;;
        --title=*)     title="${1#--title=}"; shift ;;
        --reason)      [[ $# -ge 2 ]] || mi_die "upsert: --reason requires a value";      reason="$2"; shift 2 ;;
        --reason=*)    reason="${1#--reason=}"; shift ;;
        --action)      [[ $# -ge 2 ]] || mi_die "upsert: --action requires a value";      action="$2"; shift 2 ;;
        --action=*)    action="${1#--action=}"; shift ;;
        --expected)    [[ $# -ge 2 ]] || mi_die "upsert: --expected requires a value";    expected="$2"; shift 2 ;;
        --expected=*)  expected="${1#--expected=}"; shift ;;
        --deferred-at) [[ $# -ge 2 ]] || mi_die "upsert: --deferred-at requires a value"; deferred_at="$2"; shift 2 ;;
        --deferred-at=*) deferred_at="${1#--deferred-at=}"; shift ;;
        *) mi_die "upsert: unknown argument: $1" ;;
      esac
    done
    [[ -n "$feature" ]]  || mi_die "upsert: --feature is required"
    [[ -n "$scenario" ]] || mi_die "upsert: --scenario is required"
    [[ -n "$title" ]]    || mi_die "upsert: --title is required"
    [[ -n "$reason" ]]   || mi_die "upsert: --reason is required (an entry without one is not runnable later)"
    if [[ -z "$deferred_at" ]]; then
      deferred_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fi
    dest="$(dt_ensure "$ft")"
    python3 - "$dest" "$feature" "$scenario" "$title" "$reason" "$action" "$expected" "$deferred_at" <<'PYEOF'
import re, sys
path, feature, scenario, title, reason, action, expected, deferred_at = sys.argv[1:9]

with open(path) as f:
    content = f.read()

key_head = f"### {feature}/{scenario} — "
HEAD = re.compile(r'(?m)^### [^/\s]+/[^\s]+ — ')

# Scope to the `## Deferred scenarios` section — see the PARSING CONTRACT note
# above the case statement. Offsets below are absolute so the splice is direct.
sec = re.search(r'(?m)^## Deferred scenarios[ \t]*$', content)
if not sec:
    sys.stderr.write(f"error: '## Deferred scenarios' heading not found in {path}\n")
    sys.exit(1)
_rest = content[sec.end():]
_nxt = re.search(r'(?m)^## ', _rest)
sec_start = sec.end()
sec_end = sec_start + (_nxt.start() if _nxt else len(_rest))
window = content[sec_start:sec_end]

# Find an existing block with this key and keep its Merged as value.
existing = None
merged_as = ''
for m in HEAD.finditer(window):
    if window[m.start():m.start() + len(key_head)] == key_head:
        abs_start = sec_start + m.start()
        tail = window[m.start() + 1:]
        nb = re.search(r'(?m)^(###|##) ', tail)
        abs_end = abs_start + 1 + (nb.start() if nb else len(tail))
        existing = (abs_start, abs_end)
        old = content[abs_start:abs_end]
        mm = re.search(r'(?m)^- \*\*Merged as:\*\*[ \t]*(.*)$', old)
        if mm:
            merged_as = mm.group(1).strip()
        break

def scalar(text):
    """Four-space-indent a multi-line value for a YAML-ish block scalar."""
    lines = text.rstrip('\n').split('\n')
    return '\n'.join(('    ' + ln) if ln.strip() else '' for ln in lines)

block = (
    f"{key_head}{title}\n"
    f"\n"
    f"- **Originating feature:** {feature}\n"
    f"- **Originating scenario:** {scenario}\n"
    f"- **Action:** |\n{scalar(action)}\n"
    f"- **Expected:** |\n{scalar(expected)}\n"
    f"- **Reason:** {reason}\n"
    f'- **Deferred at:** "{deferred_at}"\n'
    f"- **Merged as:** {merged_as}\n"
    f"\n"
)

if existing:
    content = content[:existing[0]] + block + content[existing[1]:]
else:
    # Append at the end of the `## Deferred scenarios` section.
    content = content[:sec_end].rstrip('\n') + '\n\n' + block + content[sec_end:]

with open(path, 'w') as f:
    f.write(content)
PYEOF
    dt_validate "$dest"
    mi_info "deferred: $feature/$scenario → $(basename "$dest")"
    ;;

  set-merged-as)
    ft="${1:?feature-test name required}"
    feature="${2:?originating feature required}"
    scenario="${3:?originating scenario required}"
    merged="${4:?merged scenario id required}"
    dest="$(dt_file "$ft")"
    [[ -f "$dest" ]] || mi_die "set-merged-as: $dest not found"
    python3 - "$dest" "$feature" "$scenario" "$merged" <<'PYEOF'
import re, sys
path, feature, scenario, merged = sys.argv[1:5]
with open(path) as f:
    content = f.read()
# Scope to the `## Deferred scenarios` section — see the PARSING CONTRACT note.
sec = re.search(r'(?m)^## Deferred scenarios[ \t]*$', content)
if not sec:
    sys.stderr.write(f"error: '## Deferred scenarios' heading not found in {path}\n")
    sys.exit(3)
_rest = content[sec.end():]
_nxt = re.search(r'(?m)^## ', _rest)
sec_start = sec.end()
sec_end = sec_start + (_nxt.start() if _nxt else len(_rest))
window = content[sec_start:sec_end]
key_head = f"### {feature}/{scenario} — "
m = re.search(r'(?m)^' + re.escape(key_head), window)
if not m:
    sys.stderr.write(f"error: no entry {feature}/{scenario} in {path}\n")
    sys.exit(3)
start = sec_start + m.start()
tail = window[m.start() + 1:]
nb = re.search(r'(?m)^(###|##) ', tail)
end = start + 1 + (nb.start() if nb else len(tail))
block = content[start:end]
new_block, n = re.subn(r'(?m)^- \*\*Merged as:\*\*[ \t]*.*$',
                       f'- **Merged as:** {merged}', block)
if n == 0:
    sys.stderr.write(f"error: entry {feature}/{scenario} has no 'Merged as:' line\n")
    sys.exit(3)
with open(path, 'w') as f:
    f.write(content[:start] + new_block + content[end:])
PYEOF
    dt_validate "$dest"
    ;;

  remove)
    ft="${1:?feature-test name required}"
    feature="${2:?originating feature required}"
    scenario="${3:?originating scenario required}"
    dest="$(dt_file "$ft")"
    [[ -f "$dest" ]] || mi_die "remove: $dest not found"
    python3 - "$dest" "$feature" "$scenario" <<'PYEOF'
import re, sys
path, feature, scenario = sys.argv[1:4]
with open(path) as f:
    content = f.read()
# Scope to the `## Deferred scenarios` section — see the PARSING CONTRACT note.
sec = re.search(r'(?m)^## Deferred scenarios[ \t]*$', content)
if not sec:
    sys.stderr.write(f"error: '## Deferred scenarios' heading not found in {path}\n")
    sys.exit(3)
_rest = content[sec.end():]
_nxt = re.search(r'(?m)^## ', _rest)
sec_start = sec.end()
sec_end = sec_start + (_nxt.start() if _nxt else len(_rest))
window = content[sec_start:sec_end]
key_head = f"### {feature}/{scenario} — "
m = re.search(r'(?m)^' + re.escape(key_head), window)
if not m:
    sys.stderr.write(f"error: no entry {feature}/{scenario} in {path}\n")
    sys.exit(3)
start = sec_start + m.start()
tail = window[m.start() + 1:]
nb = re.search(r'(?m)^(###|##) ', tail)
end = start + 1 + (nb.start() if nb else len(tail))
with open(path, 'w') as f:
    f.write(content[:start] + content[end:])
PYEOF
    dt_validate "$dest"
    ;;

  offer-defer)
    # Exit 0 when `defer` should be offered for <active-feature>, else exit 1.
    #
    # This is a script predicate rather than a shell variable on purpose: each
    # fenced bash block in a command file is a separate invocation with no
    # shared state, and a flag defaulted to "off" at a consumption site would
    # silently disable the disposition. Any block can call this in one line.
    active="${1:?active feature name required}"
    # `| head -1 | cut -f1` resolves a value, not a guard — safe without pipefail.
    ft_status="$("${MI_PLUGIN_ROOT}/scripts/todo.sh" feature-test-status 2>/dev/null | head -1 | cut -f1 || true)"
    if [[ "$ft_status" != "ready" && "$ft_status" != "selected" ]]; then
      # `none` (no entry this cycle, e.g. a single-feature cycle) or `blocked`
      # (entry exists in frontmatter but was never enqueued, so no folder was
      # created at stage 1.5). Either way there is no destination.
      exit 1
    fi
    if "${MI_PLUGIN_ROOT}/scripts/todo.sh" is-feature-test "$active" >/dev/null 2>&1; then
      # The feature-test entry's own run. It is terminal — nothing to defer into.
      exit 1
    fi
    exit 0
    ;;

  *)
    echo "usage: deferred-tests.sh {path|ensure|count|list|upsert|set-merged-as|remove|offer-defer} ..." >&2
    exit 2
    ;;
esac
```

Then `chmod +x scripts/deferred-tests.sh`.

- [ ] **Step 4: Run the tests**

Run: `tests/deferred-test-items/run.sh`
Expected: PASS — 0 failed.

- [ ] **Step 5: Add the script-table row**

In `docs/millwright-inspector-project.md`'s script table, add a row after the `blueprints.sh` row:

```markdown
| `deferred-tests.sh` | Manage `<ft-name>/test/deferred-tests.md`, the carried-forward manual-test scenarios. Subcommands: `path`, `ensure`, `count`, `list`, `upsert` (idempotent by the `<originating-feature>/<originating-scenario>` composite key; preserves an existing `Merged as:`), `set-merged-as`, `remove`, `offer-defer <feature>` (read-only predicate; exit 0 when `defer` should be offered for that feature, exit 1 otherwise). |
```

- [ ] **Step 6: Commit**

```bash
git add scripts/deferred-tests.sh tests/deferred-test-items/run.sh \
        docs/millwright-inspector-project.md
git commit -m "feat(deferred-test-items): add deferred-tests.sh helper and offer-defer predicate (DTI-001)"
```

---

## Task 3: Repair the Row A `folder-id.sh ensure` argument

Spec Approach, defect 1. Independent of every other task; no dependencies. `folder-id.sh ensure` takes a **folder path** — `_fid_ensure` opens with `[[ -d "$folder" ]] || mi_die "folder not found: $folder"` — but the Feature-test entry sequence passes a bare feature name, so the call dies. Task 4 cannot claim Row A stays idempotent until this is fixed.

**Files:**
- Modify: `commands/mi-continue.md` (Feature-test entry sequence, step 3, ~line 205)
- Modify: `tests/deferred-test-items/run.sh`
- Modify: `docs/millwright-inspector-project.md` (§ 7.4 Row A description)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks; Task 4 relies on the corrected call being present.

- [ ] **Step 1: Write the failing test**

Append to `tests/deferred-test-items/run.sh` before `# ---- Summary`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/deferred-test-items/run.sh`
Expected: FAIL on the first two assertions — the bare-name call is still in `mi-continue.md`. The third should already PASS (it pins the defect's premise).

- [ ] **Step 3: Fix the call**

In `commands/mi-continue.md`, the Feature-test entry sequence step 3. Replace:

```markdown
3. **Folder marker. NO `ensure-current`** — this folder has no `blueprints/`.

   ```bash
   $CLAUDE_PLUGIN_ROOT/scripts/folder-id.sh ensure "$ft_feature"
   ```
```

with:

```markdown
3. **Folder marker. NO `ensure-current`** — this folder has no `blueprints/`.

   `folder-id.sh ensure` takes a **folder path**, not a feature name — `_fid_ensure`
   opens with `[[ -d "$folder" ]] || mi_die "folder not found: $folder"`. Passing a bare
   name dies.

   ```bash
   data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
   $CLAUDE_PLUGIN_ROOT/scripts/folder-id.sh ensure "$data_root/workflow-stream/$ft_feature"
   ```

   Idempotent: `ensure` returns the existing id when `id.md` is already present, which is
   the normal case once stage 1.5 has created the folder (§ 3.4.1).
```

- [ ] **Step 4: Run the tests**

Run: `tests/deferred-test-items/run.sh`
Expected: PASS — 0 failed.

- [ ] **Step 5: Update § 7.4 in the project doc**

In `docs/millwright-inspector-project.md`, the Row A / Feature-test entry sequence description that mentions `folder-id.sh ensure`: state that it is called with the resolved folder path.

- [ ] **Step 6: Commit**

```bash
git add commands/mi-continue.md tests/deferred-test-items/run.sh \
        docs/millwright-inspector-project.md
git commit -m "fix(mi-continue): pass a folder path to folder-id.sh ensure in the feature-test sequence"
```

---

## Task 4: Stage-1.5 early creation of the feature-test folder

Implements DTI-002, including defect 2 (the missing `link-feature` call). Delivers the folder, its `id.md`, its cycle link, and an empty `deferred-tests.md` — all before any ordinary feature's manual-test run can defer into it.

**Files:**
- Modify: `commands/mi-continue.md` (Pre-flight Step 2A item 3.5, after the `enqueue`)
- Modify: `tests/deferred-test-items/run.sh`
- Modify: `commands/mi-abort-workflow.md` (retry-semantics section)
- Modify: `docs/millwright-inspector-project.md` (§ 3.4.1 and § 7.3)

**Interfaces:**
- Consumes: `deferred-tests.sh ensure <ft>` (Task 2); the corrected `ensure` call (Task 3).
- Produces: the invariant that `<ft>/test/deferred-tests.md` exists from stage 1.5 onward, which Tasks 6 and 8 rely on.

- [ ] **Step 1: Write the failing test**

Append to `tests/deferred-test-items/run.sh` before `# ---- Summary`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/deferred-test-items/run.sh`
Expected: FAIL on the three prose assertions and on `creation renders deferred-tests.md` only if Task 2 was skipped. The behavioural shape assertions should pass (they exercise the sequence directly).

- [ ] **Step 3: Add the creation block to `mi-continue.md`**

In `commands/mi-continue.md`, Pre-flight Step 2A item 3.5, immediately after the guarded `progress.sh enqueue "$ft_name"` call, add:

```markdown
   **Create the feature-test folder now (DTI-002).** The entry is confirmed and queued, so
   its folder comes into existence here — not at `/mi-run` name derivation, and not lazily
   on the first deferral. Deferrals happen during ordinary features, which by construction
   run before this entry is ever activated, so `deferred-tests.md` must be writable long
   before Row A fires.

   ```bash
   data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
   ft_dir="$data_root/workflow-stream/$ft_name"
   mkdir -p "$ft_dir/implementation" "$ft_dir/test"
   $CLAUDE_PLUGIN_ROOT/scripts/folder-id.sh ensure "$ft_dir" >/dev/null
   $CLAUDE_PLUGIN_ROOT/scripts/folder-id.sh link-feature "$ft_name"
   $CLAUDE_PLUGIN_ROOT/scripts/deferred-tests.sh ensure "$ft_name" >/dev/null
   ```

   Every step is idempotent: `mkdir -p` no-ops, `ensure` returns the existing id, and
   `deferred-tests.sh ensure` returns the existing path without re-rendering — so a
   re-entrant Step 2A can never truncate parked entries.

   **No `blueprints/`.** That omission is the whole point of the abbreviated shape
   (§ 3.4.1) and creating the folder early does not change it.

   **The `link-feature` call is load-bearing, not housekeeping.** Its only other caller is
   `blueprints.sh ensure-current`, which § 3.4.1 forbids against a feature-test folder — so
   without this line the folder is never linked into the cycle's `reference.md`. On a later
   cycle `feature-lineage-check` then reports `unknown: … no quest cycle references it` and
   exits 4, `derive-feature-test-name` reads any non-zero as "candidate taken", and the
   entry silently renames itself to `<name>-2`. Early creation makes the folder always
   present, which turns that latent rename into a certain one unless this call is here.
```

- [ ] **Step 4: Run the tests**

Run: `tests/deferred-test-items/run.sh`
Expected: PASS — 0 failed.

- [ ] **Step 5: Update § 3.4.1 of the project doc**

In `docs/millwright-inspector-project.md` § 3.4.1, add `deferred-tests.md` to the `test/` child in the folder tree:

```
└── test/
    ├── manual-test-plan.md
    ├── manual-test-results.md
    ├── deferred-tests.md
    ├── manual-test-plan.history/
    └── manual-test-results.history/
```

Then add, immediately after the tree:

```markdown
**Creation timing.** The folder is created at **stage 1.5**, at the point in `/mi-continue`
Pre-flight Step 2A item 3.5 where the feature-test entry is confirmed and enqueued — not at
`/mi-run` name derivation, and not lazily. Creation makes `implementation/`, `test/`, the
`id.md` marker, the `reference.md` link, and an empty `deferred-tests.md`. It is fully
idempotent and never truncates parked entries.

This timing exists because `deferred-tests.md` receives writes during *ordinary* features'
manual-test runs, which by construction all finish before this entry is activated.

**The timing change makes none of the four operations below reachable.** The folder gains
`implementation/` and `test/` earlier than before; it still never gains a `blueprints/`, so
every row of the table stands exactly as written.
```

- [ ] **Step 6: Update § 7.3 of the project doc**

In the stage-8 feature-test substitution discussion, add:

```markdown
Early folder creation (§ 3.4.1) adds **no fifth step** to this table. The entry performs no
blueprint rotation and no archive move, and nothing Branch III reads depends on when the
folder appeared.
```

- [ ] **Step 7: Document abort behaviour**

In `commands/mi-abort-workflow.md`, in the retry-semantics section for `test/`, add:

```markdown
- **`deferred-tests.md` survives both abort shapes.** Aborting an *ordinary* feature targets
  `workflow-stream/$active_feature/implementation` and never touches the feature-test
  folder, so entries parked from that feature stay put. Aborting the *feature-test entry*
  deletes only its `implementation/` and preserves `test/` with the rest of the
  feature-permanent artifacts.

  Entries parked by a feature that was later aborted are **preserved, not auto-pruned**: on
  retry, re-deferring the same scenario upserts the same composite key and produces no
  duplicate, and an entry that is never re-deferred still merges as a runnable scenario.
  Over-inclusive rather than lossy is the correct direction here. Use
  `deferred-tests.sh remove <ft> <feature> <scenario>` when an entry is known to be obsolete.
```

- [ ] **Step 8: Commit**

```bash
git add commands/mi-continue.md commands/mi-abort-workflow.md \
        tests/deferred-test-items/run.sh docs/millwright-inspector-project.md
git commit -m "feat(deferred-test-items): create the feature-test folder at stage 1.5 (DTI-002)"
```

---

## Task 5: The `deferred` verdict counter

Implements DTI-004. Must land before Task 6 — the per-scenario commit path recomputes counters, so the disposition cannot be written until there is somewhere to tally it.

**Files:**
- Modify: `schemas/manual-test-results.schema.yaml`
- Modify: `templates/manual-test-results.md.tmpl`
- Modify: `commands/mi-manual-test-run.md` (Step 4.1, Step 3.4, Branch C; three roll-up strings)
- Modify: `tests/deferred-test-items/run.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: frontmatter key `deferred` (integer, optional, default 0) on `manual-test-results.md`, read by Task 9's Gate 2.

- [ ] **Step 1: Write the failing test**

Append to `tests/deferred-test-items/run.sh` before `# ---- Summary`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/deferred-test-items/run.sh`
Expected: FAIL — the schema has no `deferred` property.

- [ ] **Step 3: Add the schema property**

In `schemas/manual-test-results.schema.yaml`, after the `skipped:` property block, add:

```yaml
  deferred:
    type: integer
    minimum: 0
    default: 0
    description: >
      Count of scenarios the inspector deferred to this cycle's whole-feature
      test. Optional with a default so results files rendered before this key
      existed stay valid — a reader that sees no key reads 0. Deferred
      scenarios remain inside `total`: they are plan scenarios that were
      reached and dispositioned, unlike `INS-<n>` inspector-added checks,
      which stay outside every counter.
```

**Do not add `deferred` to `required:`** — that would invalidate every already-rendered results file on disk.

- [ ] **Step 4: Add the template key**

In `templates/manual-test-results.md.tmpl`, after `skipped: 0`, add `deferred: 0`.

Also extend the body comment's verdict-bullet documentation so `Verdict:` reads
`pass | fail | skip | defer`.

- [ ] **Step 5: Update the three recompute sites**

In `commands/mi-manual-test-run.md`:

**Step 4.1** — change `Recompute pass/fail/skip counts from the verdict blocks.` to:

```markdown
Recompute `passed` / `failed` / `skipped` / `deferred` counts from the verdict blocks.
The identity `passed + failed + skipped + deferred == total` must hold — deferred
scenarios stay **inside** `total`.
```

**Step 3.4** — change `Recompute `passed`/`failed`/`skipped` counts from the full set of verdict blocks.` to:

```markdown
Recompute `passed`/`failed`/`skipped`/`deferred` counts from the full set of verdict
blocks; `passed + failed + skipped + deferred == total` must hold.
```

and in the same step's commit-unit sentence, change `render blocks in plan order, recompute counts` to `render blocks in plan order, recompute all four counts`.

**Branch C** — in the bulk-skip convergence description, add `deferred` alongside the other three counters wherever they are enumerated.

- [ ] **Step 6: Update the three roll-up strings**

In `commands/mi-manual-test-run.md`:

- Step 4.1 autonomous roll-up: `"Autonomous manual test complete: <passed>/<total> passed, <failed> failed, <skipped> skipped, <deferred> deferred."`
- Step 4.2 auto-seed prompt first line: `Manual test complete: <passed>/<total> passed, <failed> failed, <skipped> skipped, <deferred> deferred.`
- Branch B messages: add `, <deferred> deferred` to the same breakdown.

- [ ] **Step 7: Run the tests**

Run: `tests/deferred-test-items/run.sh`
Expected: PASS — 0 failed.

- [ ] **Step 8: Run the existing suites for regressions**

Run: `tests/feature-test-workflow/run.sh && tests/feature-test-entry/run.sh && tests/lint/run.sh`
Expected: all PASS. If `feature-test-workflow` asserts an exact roll-up string, update that assertion to the four-term form in the same commit.

- [ ] **Step 9: Commit**

```bash
git add schemas/manual-test-results.schema.yaml templates/manual-test-results.md.tmpl \
        commands/mi-manual-test-run.md tests/deferred-test-items/run.sh \
        tests/feature-test-workflow/run.sh
git commit -m "feat(deferred-test-items): add the deferred verdict counter (DTI-004)"
```

---

## Task 6: The `defer` disposition and its offer predicate

Implements DTI-003 and DTI-008. Delivers the producer end: the inspector can park a scenario, and it lands in `deferred-tests.md`.

**Files:**
- Modify: `commands/mi-manual-test-run.md` (overview; 3.2a/3.3a; 3.2c/3.3c; 3.3b; 3.4; guided env-up announcement)
- Modify: `templates/manual-test-plan.md.tmpl`
- Modify: `commands/mi-manual-test-plan.md` (generated-plan prose)
- Modify: `tests/deferred-test-items/run.sh`

**Interfaces:**
- Consumes: `deferred-tests.sh offer-defer <feature>` and `deferred-tests.sh upsert …` (Task 2); the `deferred` counter (Task 5).
- Produces: verdict value `defer` in `manual-test-results.md` blocks, read by Task 9's Gate 2.

- [ ] **Step 1: Write the failing test**

Append to `tests/deferred-test-items/run.sh` before `# ---- Summary`:

```bash
# ---- Task 6: the defer disposition -----------------------------------------

MI_MTP="$REPO_ROOT/commands/mi-manual-test-plan.md"
MTP_TMPL="$REPO_ROOT/templates/manual-test-plan.md.tmpl"

# seed_todo_ft <sandbox> <ft-name|""> — todo-list.md with or without a feature-test entry.
seed_todo_ft() {
  local sandbox ftline
  sandbox="$1"
  if [[ -n "$2" ]]; then ftline="feature-test: $2"; else ftline=""; fi
  cat > "$sandbox/quest/2026-08-15-demo/todo-list.md" <<EOF
---
id: 66666666-6666-4666-8666-666666666666
related-features: [payments, audit-log]
description: Seed cycle.
$ftline
---

# Todo list

## payments

- [x] (emin) IMPLEMENTED — PAY-001: ship payments.

## audit-log

- [x] (emin) IMPLEMENTED — AUD-001: ship audit log.
EOF
}

t="offer-defer is true for an ordinary feature in a multi-feature cycle"
sandbox="$(make_sandbox)"; seed_todo_ft "$sandbox" payments-feature-test
if MI_DATA_ROOT="$sandbox" "$DT" offer-defer payments >/dev/null 2>&1; then
  ok "$t"
else
  ng "$t" "offer-defer refused for an ordinary feature"
fi

t="offer-defer is false in a single-feature cycle (DTI-008)"
sandbox="$(make_sandbox)"; seed_todo_ft "$sandbox" ""
if MI_DATA_ROOT="$sandbox" "$DT" offer-defer payments >/dev/null 2>&1; then
  ng "$t" "offer-defer allowed a defer with no feature-test destination"
else
  ok "$t"
fi

t="offer-defer is false for the feature-test entry's own run"
sandbox="$(make_sandbox)"; seed_todo_ft "$sandbox" payments-feature-test
if MI_DATA_ROOT="$sandbox" "$DT" offer-defer payments-feature-test >/dev/null 2>&1; then
  ng "$t" "offer-defer allowed a defer during the terminal entry's own run"
else
  ok "$t"
fi

t="the runner computes offer_defer via the script predicate, not a carried flag"
if grep -q 'deferred-tests.sh offer-defer\|deferred-tests.sh" offer-defer' "$MI_MTR"; then
  ok "$t"
else
  ng "$t" "mi-manual-test-run.md does not call the offer-defer predicate"
fi

t="all three inspector-facing prompt sites offer defer"
n="$(grep -c '`defer <reason>`' "$MI_MTR")"
if [[ "$n" -ge 3 ]]; then
  ok "$t"
else
  ng "$t" "expected >=3 '\`defer <reason>\`' prompt mentions, found $n"
fi

t="autonomous mode explicitly never defers"
if grep -qi 'autonomous.*never.*defer\|no `defer` verdict in autonomous' "$MI_MTR"; then
  ok "$t"
else
  ng "$t" "mi-manual-test-run.md does not state that autonomous mode never defers"
fi

t="the runner states defer never falls into the fail or skip branch"
if grep -q 'never falls into the `fail` or `skip`' "$MI_MTR"; then
  ok "$t"
else
  ng "$t" "the fail/skip parsing guard is not stated"
fi

t="the runner states a deferred scenario seeds no IR"
if grep -q 'never spawns an `IR-NNN`\|never spawns an IR-NNN' "$MI_MTR"; then
  ok "$t"
else
  ng "$t" "the no-auto-seed guarantee is not stated"
fi

t="the plan template gates the defer vocabulary on the predicate"
if grep -q 'defer' "$MTP_TMPL"; then
  ok "$t"
else
  ng "$t" "manual-test-plan.md.tmpl never mentions defer"
fi

t="the plan generator prose gates the defer vocabulary"
if grep -q 'offer-defer' "$MI_MTP"; then
  ok "$t"
else
  ng "$t" "mi-manual-test-plan.md does not gate the vocabulary on offer-defer"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/deferred-test-items/run.sh`
Expected: the three `offer-defer` behavioural tests PASS (Task 2 shipped them); the seven prose assertions FAIL.

- [ ] **Step 3: Add the predicate call and vocabulary to the runner**

In `commands/mi-manual-test-run.md`, in the Branch A flow just before Step 3, add:

```markdown
##### Step 2.9 — Resolve the defer offer (DTI-003 / DTI-008)

```bash
if $CLAUDE_PLUGIN_ROOT/scripts/deferred-tests.sh offer-defer "$active_feature" >/dev/null 2>&1; then
  offer_defer=1
  ft_name="$($CLAUDE_PLUGIN_ROOT/scripts/todo.sh feature-test-status | head -1 | cut -f2)"
else
  offer_defer=0
  ft_name=""
fi
```

**Re-run this snippet in every block that renders the verdict vocabulary.** Each fenced
bash block is a separate invocation with no shared shell state, so `offer_defer` does not
survive from one block to the next — and defaulting it to `0` at a consumption site would
silently disable the disposition rather than fail loudly. The predicate is cheap: two
read-only `todo.sh` calls, no file writes.

`offer-defer` exits 0 only when the cycle has a feature-test entry in `ready`/`selected`
state **and** the active feature is not that entry. A single-feature cycle fails the first
clause (DTI-008); the feature-test entry's own terminal run fails the second. When it exits
1, every prompt string below is byte-identical to what shipped before this feature.
```

Then, at each of the three inspector-facing prompt sites, render the vocabulary line
conditionally. In **3.2c guided**, replace:

```
Reply `pass`, `fail <what you saw>`, `skip <why>`, or `pause`.
```

with:

```
Reply `pass`, `fail <what you saw>`, `skip <why>`, `defer <reason>` (only when
offer_defer=1), or `pause`.
```

In **3.3a interactive**, replace the reply list with:

```markdown
Wait for the inspector's reply, one of: `pass`, `fail <observation>`, `skip <reason>`,
`defer <reason>` (offered only when `offer_defer=1`), `pause`.
```

In **3.3c guided**, extend the same vocabulary sentence identically.

In **3.3b autonomous**, add after the existing `skip` bullet:

```markdown
There is **no `defer` verdict in autonomous mode** — autonomous mode never defers, in any
cycle shape. Deferral is inspector-driven by design: the journal frames it as "I can tell
the agent to defer a manual test item". An autonomous run that genuinely cannot exercise a
scenario already has the attempt-backed `skip` path above, whose bar is stricter than a
defer reason would be. This is stated rather than left implicit because the autonomous
branch matches on the same verdict strings the inspector-facing prompts render.
```

- [ ] **Step 4: Add the `defer` commit path**

In `commands/mi-manual-test-run.md`, rename the § 3.4 heading to
`##### 3.4 On `pass` / `fail` / `skip` / `defer`` and add these bullets after the
existing count-recompute bullet:

```markdown
- **On `defer <reason>` (requires `offer_defer=1`).** The reason is mandatory — an entry
  without one is not runnable later. A bare `defer` re-prompts rather than recording an
  empty reason.

  Write the verdict block with `Verdict: defer` and the reason as `Observation:`, keeping
  the existing five-bullet contract and order; `Seeded:` stays `false` and is never
  flipped. In the **same** commit unit, park the scenario:

  ```bash
  $CLAUDE_PLUGIN_ROOT/scripts/deferred-tests.sh upsert "$ft_name" \
    --feature "$active_feature" \
    --scenario "$THIS_ID" \
    --title "$scenario_title" \
    --reason "$defer_reason" \
    --action "$scenario_action" \
    --expected "$scenario_expected"
  ```

  One disposition, one commit unit — a crash between a results write and a deferred-tests
  write would otherwise leave the two files disagreeing. `upsert` is idempotent on the
  `<feature>/<scenario>` composite key, so re-deferring the same scenario updates the one
  entry and the existing verdict-already-committed crash recovery (3.1) stays correct. It
  also preserves any `Merged as:` already written by a prior plan generation.

- **A `defer` reply never falls into the `fail` or `skip` parsing branch.** This is the
  single most important behavioural guard in the disposition: a defer is neither a failure
  nor an abandonment.

- Echo shape: `<ID> ⏸ deferred: <reason>`.
```

In § 4.2's auto-seed section, add:

```markdown
**A deferred scenario never spawns an `IR-NNN`.** It does not enter the failed set, so the
`<failed>` count above excludes it and the per-scenario family-inspection loop never sees
it. `review.sh upsert-manual-test-failure` is unchanged by this feature.
```

- [ ] **Step 5: Update the remaining four vocabulary sites**

- `commands/mi-manual-test-run.md` **overview section**: add `defer` to the dispositions
  list with the note "offered only when the cycle has a feature-test entry and the active
  feature is not it".
- `commands/mi-manual-test-run.md` **guided env-up announcement**: same conditional mention.
- `templates/manual-test-plan.md.tmpl`: in the reply-vocabulary line, add
  `` `defer <reason>` (multi-feature cycles only, and never during the feature-test entry's own run) ``.
- `commands/mi-manual-test-plan.md` **generated-plan prose**: state that the rendered plan
  advertises `defer` only when `deferred-tests.sh offer-defer "$active_feature"` exits 0, so
  a generated plan never advertises a vocabulary the runner will not accept.

- [ ] **Step 6: Run the tests**

Run: `tests/deferred-test-items/run.sh`
Expected: PASS — 0 failed.

- [ ] **Step 7: Commit**

```bash
git add commands/mi-manual-test-run.md commands/mi-manual-test-plan.md \
        templates/manual-test-plan.md.tmpl tests/deferred-test-items/run.sh
git commit -m "feat(deferred-test-items): add the defer disposition and offer predicate (DTI-003, DTI-008)"
```

---

## Task 7: The merge and attribution

Implements DTI-005 and DTI-006. Delivers the consumer end: parked entries appear in the whole-feature plan, still identifiable.

**Files:**
- Modify: `commands/mi-manual-test-plan.md` (Step 5, `ft_mode=1` render path)
- Modify: `commands/mi-manual-test-run.md` (Step 3.4 attribution line)
- Modify: `tests/deferred-test-items/run.sh`
- Modify: `docs/millwright-inspector-project.md` (§ 6.4)

**Interfaces:**
- Consumes: `deferred-tests.sh list <ft>` and `set-merged-as` (Task 2).
- Produces: the `Merged as:` back-reference populated on every entry, which Task 8's gate reads.

- [ ] **Step 1: Write the failing test**

Append to `tests/deferred-test-items/run.sh` before `# ---- Summary`:

```bash
# ---- Task 7: merge and attribution -----------------------------------------

t="the merge anchor's exact text is still pinned in the plan generator"
if grep -q '<!-- deferred-merge-point -->' "$MI_MTP"; then
  ok "$t"
else
  ng "$t" "the deferred-merge-point anchor text was changed or removed"
fi

t="the anchor is documented as the last line of section 3"
if grep -q 'End `## 3. Test scenarios` with exactly this line' "$MI_MTP"; then
  ok "$t"
else
  ng "$t" "the anchor's position contract is no longer stated"
fi

t="the plan generator lists deferred-tests as a derivation input"
if grep -q 'deferred-tests' "$MI_MTP"; then
  ok "$t"
else
  ng "$t" "mi-manual-test-plan.md never mentions deferred-tests"
fi

t="the merge inserts above the anchor, not below"
if grep -q 'immediately above' "$MI_MTP"; then
  ok "$t"
else
  ng "$t" "insertion position relative to the anchor is not stated"
fi

t="the merge writes the Merged as back-reference"
if grep -q 'set-merged-as' "$MI_MTP"; then
  ok "$t"
else
  ng "$t" "the plan generator never calls set-merged-as"
fi

t="an empty deferred-tests produces an unchanged render (stated contract)"
if grep -q 'zero deferred entries\|empty `deferred-tests.md`' "$MI_MTP"; then
  ok "$t"
else
  ng "$t" "the zero-deferral no-op contract is not stated"
fi

t="attribution marker format is pinned in the plan generator"
if grep -q '\[deferred from ' "$MI_MTP"; then
  ok "$t"
else
  ng "$t" "the [deferred from <feature>] marker is not specified"
fi

t="the results side emits the attribution line"
if grep -q '\[deferred from ' "$MI_MTR"; then
  ok "$t"
else
  ng "$t" "mi-manual-test-run.md Step 3.4 does not emit the attribution line"
fi

t="the parser is documented to tolerate a non-bullet line before the bullets"
if grep -q 'non-bullet line' "$MI_MTR"; then
  ok "$t"
else
  ng "$t" "the parser-tolerance contract for the attribution line is not stated"
fi

t="the id grammar is explicitly unchanged"
if grep -q 'id grammar\|scenario-id grammar' "$MI_MTP"; then
  ok "$t"
else
  ng "$t" "the byte-identical id-grammar guarantee is not restated at the merge"
fi

# Behavioural: list -> set-merged-as round-trip is what the merge performs.
t="merge round-trip populates Merged as for every entry"
sandbox="$(make_sandbox)"; seed_dt "$sandbox" >/dev/null
add_entry "$sandbox" payments B.2 "refund audit"
add_entry "$sandbox" checkout A.4 "cart survives expiry"
i=0
while IFS=$'\t' read -r f s m ttl; do
  [[ -z "$f" ]] && continue
  i=$((i + 1))
  MI_DATA_ROOT="$sandbox" "$DT" set-merged-as payments-feature-test "$f" "$s" "C.$i" >/dev/null 2>&1
done < <(MI_DATA_ROOT="$sandbox" "$DT" list payments-feature-test 2>/dev/null)
blanks="$(MI_DATA_ROOT="$sandbox" "$DT" list payments-feature-test 2>/dev/null | cut -f3 | grep -c '^$' || true)"
if [[ "$i" == "2" && "$blanks" == "0" ]]; then
  ok "$t"
else
  ng "$t" "processed $i entries, $blanks still have a blank Merged as"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/deferred-test-items/run.sh`
Expected: FAIL on the merge-prose assertions; the round-trip test PASSes (Task 2 shipped the primitives).

- [ ] **Step 3: Add the merge to the plan generator**

In `commands/mi-manual-test-plan.md`, replace the **Merge anchor for `DTI-005`** block with:

```markdown
**Merge anchor and the merge itself (`DTI-005`).** End `## 3. Test scenarios` with exactly
this line:

```markdown
<!-- deferred-merge-point -->
```

The anchor is matched as a literal string. It keeps its exact text and its exact position —
last line of § 3, immediately before `## 4. Coverage notes` — on **every** feature-test
render, including renders with zero deferred entries, because a later deferral plus
regeneration must still find it.

`deferred-tests.md` joins `todo.sh list IMPLEMENTED` and the union range as a derivation
input for this render path. Read the entries:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/deferred-tests.sh list "$active_feature"
```

Each TSV row is `<originating-feature>\t<originating-scenario>\t<merged-as>\t<title>`.

Render every entry as a scenario, in its own lettered group(s) continuing the plan's
existing lettering, inserted **immediately above** the anchor. Take each scenario's `Action`
and `Expected` from the entry's own block — the entries are self-contained precisely so this
render needs nothing from the originating workflow.

**Attribution (`DTI-006`).** The scenario title carries the marker:

```markdown
### C.1 — [deferred from payments] refund shows in the audit trail
```

Nothing else changes: no new id prefix, no reserved letter range, no new frontmatter field.
The **scenario-id grammar stays byte-identical**, so neither the runner's one-to-one
id↔verdict-block keying nor `review.sh`'s `seed-id` construction
(`manual-test:<seed-family-id>:<scenario-id>`) sees anything new.

After assigning each entry its scenario id, write the back-reference:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/deferred-tests.sh set-merged-as \
  "$active_feature" "$orig_feature" "$orig_scenario" "$new_scenario_id"
```

That field is what makes the completion gate machine-checkable (`/mi-continue`, DTI-007)
without touching the plan's or the results' own contracts.

**With zero deferred entries the render is unchanged from today** — no group is inserted,
the anchor still emits, and `set-merged-as` is never called.
```

- [ ] **Step 4: Add the results-side attribution line**

In `commands/mi-manual-test-run.md` § 3.4, add:

```markdown
- **Carried-forward scenarios (`DTI-006`).** When the scenario's plan title begins with a
  `[deferred from <feature>]` marker, emit that marker as its own line directly under the
  `### <SCENARIO_ID> — <VERDICT>` heading and above the bullets, which keep their contract
  verbatim:

  ```markdown
  ### C.1 — pass

  [deferred from payments]

  - **Verdict:** pass
  - **Observation:** …
  ```

  **The verdict-block parser must tolerate a non-bullet line between the heading and the
  first bullet.** It reads by bullet key within the block window, so it already does — this
  makes that tolerance a contract rather than an accident. The block boundary
  (`^### <id> — ` to the next `^### `/`^## `/EOF) and the five bullet keys are unchanged.
```

- [ ] **Step 5: Update § 6.4 of the project doc**

In the abbreviated-pipeline step table's derivation notes, add:

```markdown
Step 2's whole-feature test plan takes a third derivation input: the feature-test entry's
`test/deferred-tests.md`, whose entries are merged into `## 3. Test scenarios` above the
`<!-- deferred-merge-point -->` anchor (DTI-005).
```

- [ ] **Step 6: Run the tests**

Run: `tests/deferred-test-items/run.sh && tests/feature-test-workflow/run.sh`
Expected: both PASS — 0 failed in the new suite.

- [ ] **Step 7: Commit**

```bash
git add commands/mi-manual-test-plan.md commands/mi-manual-test-run.md \
        tests/deferred-test-items/run.sh docs/millwright-inspector-project.md
git commit -m "feat(deferred-test-items): merge parked scenarios into the whole-feature plan (DTI-005, DTI-006)"
```

---

## Task 8: Gate 1 — the blocking completion gate

Implements DTI-007's first gate. Delivers the guarantee that the feature-test entry cannot finalize while a parked scenario has no verdict.

**Files:**
- Modify: `commands/mi-continue.md` (Inspector Handler `advance-to 5 7`; Review-Resume Handler `advance-to 6 7`)
- Create: `scripts/deferred-tests.sh` addition — `unresolved` subcommand
- Modify: `tests/deferred-test-items/run.sh`

**Interfaces:**
- Consumes: `deferred-tests.sh list <ft>` (Task 2); populated `Merged as:` (Task 7).
- Produces: `deferred-tests.sh unresolved <ft> <results-path>` → prints one TSV row `<feature>\t<scenario>\t<merged-as>\t<title>` per unresolved entry; exit 0 always (an empty result means "nothing blocks").

- [ ] **Step 1: Write the failing test**

Append to `tests/deferred-test-items/run.sh` before `# ---- Summary`:

```bash
# ---- Task 8: Gate 1 (blocking) ---------------------------------------------

# mk_results <path> <scenario-id:verdict> ... — minimal results file.
mk_results() {
  local path="$1"; shift
  cat > "$path" <<'EOF'
---
id: 22222222-2222-4222-8222-222222222222
feature: payments-feature-test
plan-id: 33333333-3333-4333-8333-333333333333
seed-family-id: 44444444-4444-4444-8444-444444444444
generated-in-activation: 55555555-5555-4555-8555-555555555555
state: complete
current-scenario: null
total: 2
passed: 1
failed: 0
skipped: 0
deferred: 0
started-at: "2026-08-15T09:00:00Z"
finished-at: "2026-08-15T10:00:00Z"
---

# Manual test results

## Per-scenario verdicts
EOF
  local pair id verdict
  for pair in "$@"; do
    id="${pair%%:*}"; verdict="${pair##*:}"
    cat >> "$path" <<EOF

### $id — $verdict

- **Verdict:** $verdict
- **Observation:** n/a
- **Recorded at:** "2026-08-15T09:30:00Z"
- **Seeded:** false
- **Cited as IR-NNN:**
EOF
  done
}

setup_gate_case() {
  # $1 sandbox, $2 merged-as for payments/B.2, $3.. verdict pairs
  local sandbox merged
  sandbox="$1"; merged="$2"; shift 2
  seed_dt "$sandbox" >/dev/null
  add_entry "$sandbox" payments B.2 "refund audit"
  if [[ -n "$merged" ]]; then
    MI_DATA_ROOT="$sandbox" "$DT" set-merged-as payments-feature-test payments B.2 "$merged" >/dev/null 2>&1
  fi
  mk_results "$sandbox/results.md" "$@"
}

t="gate: an entry whose merged scenario has no verdict is unresolved"
sandbox="$(make_sandbox)"; setup_gate_case "$sandbox" C.1 "A.1:pass"
n="$(MI_DATA_ROOT="$sandbox" "$DT" unresolved payments-feature-test "$sandbox/results.md" 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "$n" == "1" ]]; then ok "$t"; else ng "$t" "want 1 unresolved, got $n"; fi

t="gate: a pass verdict resolves the entry"
sandbox="$(make_sandbox)"; setup_gate_case "$sandbox" C.1 "C.1:pass"
n="$(MI_DATA_ROOT="$sandbox" "$DT" unresolved payments-feature-test "$sandbox/results.md" 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "$n" == "0" ]]; then ok "$t"; else ng "$t" "want 0 unresolved, got $n"; fi

t="gate: a fail verdict resolves the entry"
sandbox="$(make_sandbox)"; setup_gate_case "$sandbox" C.1 "C.1:fail"
n="$(MI_DATA_ROOT="$sandbox" "$DT" unresolved payments-feature-test "$sandbox/results.md" 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "$n" == "0" ]]; then ok "$t"; else ng "$t" "want 0 unresolved, got $n"; fi

t="gate: a skip verdict resolves the entry"
sandbox="$(make_sandbox)"; setup_gate_case "$sandbox" C.1 "C.1:skip"
n="$(MI_DATA_ROOT="$sandbox" "$DT" unresolved payments-feature-test "$sandbox/results.md" 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "$n" == "0" ]]; then ok "$t"; else ng "$t" "skip must resolve — want 0 unresolved, got $n"; fi

t="gate: a blank Merged as is unresolved (fails closed)"
sandbox="$(make_sandbox)"; setup_gate_case "$sandbox" "" "C.1:pass"
n="$(MI_DATA_ROOT="$sandbox" "$DT" unresolved payments-feature-test "$sandbox/results.md" 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "$n" == "1" ]]; then ok "$t"; else ng "$t" "a blank Merged as must fail closed — got $n"; fi

t="gate: zero deferred entries means nothing blocks"
sandbox="$(make_sandbox)"; seed_dt "$sandbox" >/dev/null
mk_results "$sandbox/results.md" "A.1:pass"
n="$(MI_DATA_ROOT="$sandbox" "$DT" unresolved payments-feature-test "$sandbox/results.md" 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "$n" == "0" ]]; then ok "$t"; else ng "$t" "want 0, got $n"; fi

t="gate: an absent results file leaves every entry unresolved"
sandbox="$(make_sandbox)"; setup_gate_case "$sandbox" C.1 "C.1:pass"
n="$(MI_DATA_ROOT="$sandbox" "$DT" unresolved payments-feature-test "$sandbox/nope.md" 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "$n" == "1" ]]; then ok "$t"; else ng "$t" "want 1 unresolved for a missing results file, got $n"; fi

t="mi-continue gates the Inspector Handler's advance-to 5 7"
if grep -q 'deferred-tests.sh unresolved\|deferred-tests.sh" unresolved' "$MI_CONTINUE"; then
  ok "$t"
else
  ng "$t" "mi-continue.md never calls the unresolved gate"
fi

t="mi-continue states the gate is not inside generic advance-to"
if grep -q 'not inside generic `advance-to`\|Not inside generic' "$MI_CONTINUE"; then
  ok "$t"
else
  ng "$t" "the gate-placement rationale is not stated"
fi

t="mi-continue states the existing open-findings block is not replaced"
if grep -q 'not replaced' "$MI_CONTINUE"; then
  ok "$t"
else
  ng "$t" "the additive-AND contract with the findings block is not stated"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/deferred-test-items/run.sh`
Expected: FAIL — `unresolved` is not a subcommand.

- [ ] **Step 3: Add the `unresolved` subcommand**

In `scripts/deferred-tests.sh`, add before the `offer-defer)` case:

```bash
  unresolved)
    # Print one TSV row per deferred entry that has no verdict in the
    # feature-test entry's manual-test-results.md. Empty output = nothing
    # blocks. Always exits 0 — the caller decides what to do with the rows.
    #
    # Resolution rule (DTI-007): pass / fail / skip all resolve. The gate
    # catches ABSENT verdicts, not abandoned ones — a skip already carries a
    # mandatory reason, and the autonomous pre-finalize skip audit
    # (mi-manual-test-run.md Step 4.1) already refuses convenience skips.
    # A blank `Merged as:` fails closed.
    ft="${1:?feature-test name required}"
    results="${2:?results-file path required}"
    dest="$(dt_file "$ft")"
    if [[ ! -f "$dest" ]]; then
      exit 0
    fi
    python3 - "$dest" "$results" <<'PYEOF'
import os, re, sys
dt_path, results_path = sys.argv[1], sys.argv[2]

verdicts = set()
if os.path.isfile(results_path):
    with open(results_path) as f:
        rc = f.read()
    # Scope to `## Per-scenario verdicts` — `## Inspector-added checks` blocks
    # are not verdicts and must never resolve a deferred entry.
    sec = re.search(r'(?m)^## Per-scenario verdicts[ \t]*$', rc)
    if sec:
        rest = rc[sec.end():]
        nxt = re.search(r'(?m)^## ', rest)
        window = rest[:nxt.start()] if nxt else rest
        for m in re.finditer(r'(?m)^### (\S+) — (\S+)\s*$', window):
            if m.group(2) in ('pass', 'fail', 'skip'):
                verdicts.add(m.group(1))

with open(dt_path) as f:
    dc = f.read()
# Scope to the `## Deferred scenarios` section — see the PARSING CONTRACT note.
dsec = re.search(r'(?m)^## Deferred scenarios[ \t]*$', dc)
if not dsec:
    sys.exit(0)
drest = dc[dsec.end():]
dnxt = re.search(r'(?m)^## ', drest)
window = drest[:dnxt.start()] if dnxt else drest
HEAD = re.compile(r'(?m)^### ([^/\s]+)/([^\s]+) — (.*)$')
for m in HEAD.finditer(window):
    feature, scenario, title = m.group(1), m.group(2), m.group(3).strip()
    tail = window[m.end():]
    nb = re.search(r'(?m)^(###|##) ', tail)
    block = tail[:nb.start()] if nb else tail
    mm = re.search(r'(?m)^- \*\*Merged as:\*\*[ \t]*(.*)$', block)
    merged = mm.group(1).strip() if mm else ''
    if not merged or merged not in verdicts:
        print('\t'.join([feature, scenario, merged, title]))
PYEOF
    ;;
```

Also add `unresolved` to the usage string.

- [ ] **Step 4: Add the gate to both finalization paths**

In `commands/mi-continue.md`, add a shared block referenced by both handlers. Insert before
the Inspector Handler's Step 3a `advance-to` call:

```markdown
##### Deferred-scenario completion gate (DTI-007, Gate 1)

Runs on **both** shipped entries into finalization — the Inspector Handler's
no-open-findings `advance-to 5 7` here, and the Review-Resume Handler's `advance-to 6 7`
below. It is deliberately **not inside generic `advance-to`**: putting it there would alter
behaviour for cycles that carry no feature-test entry at all, whereas placing it on both
handler paths guarantees neither branch bypasses it while leaving `advance-to`'s contract
untouched.

The existing open-findings block is **not replaced** — this is a second, independent
`AND`-condition beside it.

```bash
if $CLAUDE_PLUGIN_ROOT/scripts/todo.sh is-feature-test "$active_feature" >/dev/null 2>&1; then
  results_path="$($CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh manual-test-results-path "$active_feature")"
  unresolved="$($CLAUDE_PLUGIN_ROOT/scripts/deferred-tests.sh unresolved "$active_feature" "$results_path")"
else
  unresolved=""
fi
```

If `unresolved` is non-empty, **stop** — do not advance. Print one line per row:

> Cannot finalize `<active_feature>` — N deferred scenario(s) have no verdict:
>   `<feature>/<scenario>` → `<merged-as or "(not merged)">`  (`<title>`)
>
> Run `/mi-manual-test-run` to complete them, or drop an obsolete entry with
> `deferred-tests.sh remove <ft> <feature> <scenario>`.

If `unresolved` is empty, proceed to the `advance-to` unchanged. **A cycle with zero
deferred entries takes this path always**, so its behaviour is byte-identical to today.

`pass`, `fail`, and `skip` all resolve an entry; the gate catches *absent* verdicts, not
abandoned ones.
```

Then add a one-line reference at the Review-Resume Handler's Step 2.6, before its
`advance-to 6 7`:

```markdown
**Run the deferred-scenario completion gate first** (the Inspector Handler's block above,
verbatim — same predicate, same refusal). Only advance when it reports nothing unresolved.
```

- [ ] **Step 5: Run the tests**

Run: `tests/deferred-test-items/run.sh`
Expected: PASS — 0 failed.

- [ ] **Step 6: Commit**

```bash
git add scripts/deferred-tests.sh commands/mi-continue.md tests/deferred-test-items/run.sh
git commit -m "feat(deferred-test-items): block feature-test finalization on unresolved deferrals (DTI-007)"
```

---

## Task 9: Gate 2 — the report-only ordinary-feature check

Implements DTI-007's second gate. Delivers honest reporting without ever blocking.

**Files:**
- Modify: `commands/mi-manual-test-run.md` (§ 4.8 hand-off message)
- Modify: `commands/mi-complete-workflow.md` (ordinary-feature stage-8 preflight)
- Modify: `tests/deferred-test-items/run.sh`

**Interfaces:**
- Consumes: the `deferred` counter (Task 5).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Write the failing test**

Append to `tests/deferred-test-items/run.sh` before `# ---- Summary`:

```bash
# ---- Task 9: Gate 2 (report-only) ------------------------------------------

MI_CW="$REPO_ROOT/commands/mi-complete-workflow.md"

t="the hand-off message reports deferred scenarios"
if grep -q 'deferred to the whole-feature test' "$MI_MTR"; then
  ok "$t"
else
  ng "$t" "mi-manual-test-run.md 4.8 does not report deferred scenarios"
fi

t="the ordinary-feature stage-8 preflight reads the deferred counter"
if grep -q 'deferred' "$MI_CW"; then
  ok "$t"
else
  ng "$t" "mi-complete-workflow.md never mentions the deferred counter"
fi

t="Gate 2 is explicitly report-only and never blocks"
if grep -qi 'never block' "$MI_CW"; then
  ok "$t"
else
  ng "$t" "the never-blocks contract is not stated in mi-complete-workflow.md"
fi

t="the runner states the ordinary feature is not fully tested while carrying deferrals"
if grep -q 'not.*fully tested\|never described as fully tested' "$MI_MTR"; then
  ok "$t"
else
  ng "$t" "the fully-tested wording rule is not stated"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/deferred-test-items/run.sh`
Expected: FAIL — none of the four strings exist yet.

- [ ] **Step 3: Update the hand-off message**

In `commands/mi-manual-test-run.md` § 4.8, add after the existing hand-off block:

```markdown
**When `deferred > 0` (DTI-007, Gate 2 — report-only).** Replace any fully-tested claim in
the hand-off with an honest breakdown that names the deferrals:

```
Manual test done: <passed>/<total> passed, <failed> failed, <skipped> skipped,
<deferred> deferred to the whole-feature test.
```

This feature is **not described as fully tested** while it carries a deferred scenario. The
check is **report-only**: it changes wording only and never blocks this feature's stage-8
completion or its promotion to `IMPLEMENTED`. Those scenarios are resolved later, at the
feature-test entry, whose own gate (`/mi-continue`, Gate 1) is the blocking one. Blocking
here would deadlock the cycle, because the entry that resolves them runs last.
```

- [ ] **Step 4: Update the stage-8 preflight**

In `commands/mi-complete-workflow.md`, in the ordinary-feature preflight, add:

```markdown
**Deferred-scenario reporting (DTI-007, Gate 2 — report-only).** Read the `deferred`
counter from the feature's `test/manual-test-results.md` when the file exists:

```bash
results_path="$($CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh manual-test-results-path "$active_feature")"
deferred_n=0
if [[ -f "$results_path" ]]; then
  deferred_n="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$results_path" deferred 2>/dev/null || echo 0)"
  if [[ -z "$deferred_n" || "$deferred_n" == "null" ]]; then
    deferred_n=0
  fi
fi
```

`frontmatter.sh get` exits 0 and prints the literal string `null` for an absent field, so
the value is tested rather than the exit code — a results file rendered before the counter
existed reads as 0.

When `deferred_n > 0`, say so in the completion summary — "completed; N scenario(s)
deferred to the whole-feature test" — instead of describing the feature as fully tested.
**This never blocks completion** and never affects the `IMPLEMENTED` promotion; the
blocking gate lives on the feature-test entry (`/mi-continue`, Gate 1).
```

- [ ] **Step 5: Run the tests**

Run: `tests/deferred-test-items/run.sh`
Expected: PASS — 0 failed.

- [ ] **Step 6: Commit**

```bash
git add commands/mi-manual-test-run.md commands/mi-complete-workflow.md \
        tests/deferred-test-items/run.sh
git commit -m "feat(deferred-test-items): report deferrals on ordinary features without blocking (DTI-007)"
```

---

## Task 10: End-to-end integration and full-suite verification

Delivers proof that the whole pipe works together — defer → merge → verdict → gate clears — and that nothing else regressed.

**Files:**
- Modify: `tests/deferred-test-items/run.sh`

**Interfaces:**
- Consumes: everything.
- Produces: nothing.

- [ ] **Step 1: Write the end-to-end test**

Append to `tests/deferred-test-items/run.sh` before `# ---- Summary`:

```bash
# ---- Task 10: end-to-end ---------------------------------------------------

t="e2e: defer -> merge -> verdict clears the gate"
sandbox="$(make_sandbox)"
seed_todo_ft "$sandbox" payments-feature-test
create_ft_folder "$sandbox" payments-feature-test

# 1. Two ordinary features each defer one scenario.
MI_DATA_ROOT="$sandbox" "$DT" upsert payments-feature-test \
  --feature payments --scenario B.2 --title "refund shows in the audit trail" \
  --reason "audit-log ships later" \
  --action "1. Issue a refund on order #1001" \
  --expected "- The refund appears in the audit trail" \
  --deferred-at "2026-08-15T10:00:00Z" >/dev/null 2>&1
MI_DATA_ROOT="$sandbox" "$DT" upsert payments-feature-test \
  --feature checkout --scenario A.4 --title "cart survives a session expiry" \
  --reason "session feature ships later" \
  --action "1. Expire the session" \
  --expected "- The cart is intact" \
  --deferred-at "2026-08-15T10:05:00Z" >/dev/null 2>&1

# 2. The whole-feature plan generation assigns ids (list -> set-merged-as).
i=0
while IFS=$'\t' read -r f s m ttl; do
  [[ -z "$f" ]] && continue
  i=$((i + 1))
  MI_DATA_ROOT="$sandbox" "$DT" set-merged-as payments-feature-test "$f" "$s" "C.$i" >/dev/null 2>&1
done < <(MI_DATA_ROOT="$sandbox" "$DT" list payments-feature-test 2>/dev/null)

# 3. Before the run, both are unresolved.
res="$sandbox/workflow-stream/payments-feature-test/test/manual-test-results.md"
mk_results "$res" "A.1:pass"
before="$(MI_DATA_ROOT="$sandbox" "$DT" unresolved payments-feature-test "$res" | sed '/^$/d' | wc -l | tr -d ' ')"

# 4. The whole-feature run gives both a verdict (one pass, one skip).
mk_results "$res" "A.1:pass" "C.1:pass" "C.2:skip"
after="$(MI_DATA_ROOT="$sandbox" "$DT" unresolved payments-feature-test "$res" | sed '/^$/d' | wc -l | tr -d ' ')"

if [[ "$before" == "2" && "$after" == "0" ]]; then
  ok "$t"
else
  ng "$t" "unresolved before=$before (want 2), after=$after (want 0)"
fi

t="e2e: the artifact still validates after the full round-trip"
if "$FM" validate \
     "$sandbox/workflow-stream/payments-feature-test/test/deferred-tests.md" \
     deferred-tests >/dev/null 2>&1; then
  ok "$t"
else
  ng "$t" "deferred-tests.md no longer validates after the e2e round-trip"
fi

t="e2e: inspector-added INS blocks never resolve a deferred entry"
sandbox="$(make_sandbox)"
seed_dt "$sandbox" >/dev/null
add_entry "$sandbox" payments B.2 "refund audit"
MI_DATA_ROOT="$sandbox" "$DT" set-merged-as payments-feature-test payments B.2 C.1 >/dev/null 2>&1
res="$sandbox/results.md"
mk_results "$res" "A.1:pass"
cat >> "$res" <<'EOF'

## Inspector-added checks

### C.1 — pass

- **Verdict:** pass
- **Observation:** an ad-hoc check that happens to share the id
- **Recorded at:** "2026-08-15T09:45:00Z"
EOF
n="$(MI_DATA_ROOT="$sandbox" "$DT" unresolved payments-feature-test "$res" | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "$n" == "1" ]]; then
  ok "$t"
else
  ng "$t" "an INS block outside '## Per-scenario verdicts' wrongly resolved the entry"
fi
```

- [ ] **Step 2: Run the new suite**

Run: `tests/deferred-test-items/run.sh`
Expected: PASS — 0 failed.

- [ ] **Step 3: Run every suite for regressions**

Run each and confirm PASS:

```bash
tests/lint/run.sh
tests/feature-test-entry/run.sh
tests/feature-test-workflow/run.sh
tests/blueprint-lessons/run.sh
tests/blueprint-review/run.sh
tests/bundle/run.sh
tests/deferred-test-items/run.sh
```

Expected: all exit 0. Any failure is a regression introduced by this feature — fix it before committing, do not adjust the assertion unless the assertion itself encoded a string this feature legitimately changed (the roll-up breakdowns in Task 5 are the only expected case).

- [ ] **Step 4: Verify the shell snippets actually run**

The trap list in Global Constraints produces silent wrong answers, not crashes, so a green
suite proves nothing about them. Execute each bash snippet this plan added to a command
file, against a sandbox, and confirm it produces the intended value:

```bash
# Task 4's creation block
# Task 6's Step 2.9 offer_defer resolution
# Task 8's gate block
# Task 9's deferred_n read (confirm it yields 0, not the string "null")
```

Expected: each produces the documented value. Specifically confirm `deferred_n` is `0` — not
`null` — for a results file with no `deferred` key.

- [ ] **Step 5: Commit**

```bash
git add tests/deferred-test-items/run.sh
git commit -m "test(deferred-test-items): add end-to-end coverage for the defer pipeline"
```

---

## Self-Review

**Spec coverage.** Every spec section maps to a task:

| Spec section | Task |
| --- | --- |
| Approach defect 1 (`ensure` arg) | 3 |
| Approach defect 2 (`link-feature`) | 4 |
| § 1.1–1.4 artifact, location, schema, body | 1 |
| § 1.5 the helper | 2 |
| § 2.1 offer predicate | 2 (predicate), 6 (use) |
| § 2.2 the disposition | 6 |
| § 2.3 commit path | 6 |
| § 2.4 auto-seed untouched | 6 |
| § 2.5 the counter | 5 |
| § 2.6 stale-key edge case | documented in the template + spec; no code (by design) |
| § 3.1–3.3 creation and five consumers | 4 |
| § 3.4 aborted originating features | 4 (abort doc + `remove` from Task 2) |
| § 4.1 the merge | 7 |
| § 4.2 attribution | 7 |
| § 4.3 Gate 1 | 8 |
| § 4.4 Gate 2 | 9 |
| § 4.5 out of scope | no task — deliberate |
| § 5 project-doc updates | distributed: § 3.4.1 + § 7.3 → 4; § 6.4 → 7; § 7.4 → 3; script table → 1, 2 |
| § Testing | every task, consolidated in 10 |

No gaps.

**Placeholder scan.** No "TBD", no "similar to Task N", no "add error handling". Every code
step carries the literal content. The one place the plan says "documented in the template"
(§ 2.6) is a deliberate no-code outcome the spec itself specifies, not a deferred step.

**Type consistency.** Checked across tasks:

- `deferred-tests.sh` subcommand names are identical everywhere they appear: `path`,
  `ensure`, `count`, `list`, `upsert`, `set-merged-as`, `remove`, `unresolved`,
  `offer-defer`. Task 2's usage string is amended by Task 8 to add `unresolved`.
- The composite key is `<originating-feature>/<originating-scenario>` in the schema, the
  template, the helper's regexes, and every test.
- The bullet key is `- **Merged as:**` in the template, `upsert`, `list`, `set-merged-as`,
  and `unresolved`.
- The counter key is `deferred` in the schema, the template, all three recompute sites, all
  three roll-ups, and Gate 2's read.
- The attribution marker is `[deferred from <feature>]` in the plan render and the results
  render.
- `blueprints.sh deferred-tests-path` is the single path source; `deferred-tests.sh` never
  builds the path itself.

**Two defects found and fixed while reviewing:**

1. **`ensure` was internal-only.** Task 4's creation block calls `deferred-tests.sh ensure`
   as a subcommand, but Task 2 originally exposed it only as a shell function. It is now in
   the `case` and the usage string.

2. **Phantom-entry parse (the serious one).** The template's entry-shape comment contains a
   worked example with a real `### payments/B.2 — …` line, and the parsers originally
   scanned the whole file. A freshly rendered, empty artifact would therefore report **one
   entry instead of zero** — and because Gate 1 blocks on any entry lacking a verdict, every
   multi-feature cycle would have been unable to finalize its feature-test entry, in exactly
   the case where nothing was ever deferred. Three fixes, layered:
   - the comment moved **above** `## Deferred scenarios`;
   - all six parsers (`count`, `list`, `upsert`, `set-merged-as`, `remove`, `unresolved`)
     scoped to that section;
   - the example indented two spaces so its `###` is not at column 0.

   Four assertions in Task 2 pin all three layers, including one that fails if a future edit
   moves the comment back inside the section.

   This is the class of bug the Global Constraints warn about: it produces a silent wrong
   answer, not a crash, and every assertion written against a *populated* file would still
   have passed.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-08-15-deferred-test-items.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
