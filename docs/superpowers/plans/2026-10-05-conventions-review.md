# Conventions Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After implementation, check the changed code against the feature's review-tagged skills and path-matched rules with one read-only reviewer per entry, and land validated findings in `inspector-review.md` as `source: conventions-review`.

**Architecture:** A new helper `scripts/conventions-review.sh` (bash wrapper) + `scripts/internal/conventions_review.py` (logic) with two subcommands: `prepare` (gate, snapshot, entry selection, run state) and `ingest` (parse all replies, validate, dedupe, write via `review.sh add`, report). A thin command `commands/mi-conventions-review.md` drives prepare → reviewer spawns → ingest; `/mi-continue` Resume Step 6.5 runs it. `commits.sh changed-lines` supplies the line ranges.

**Tech Stack:** bash, Python 3 (+ PyYAML, already a plugin dependency), git, Claude Code agent/command markdown.

**Spec:** `docs/superpowers/specs/2026-10-05-conventions-review-design.md` (read it; item-level acceptance criteria are in `millwright-inspector/workflow-stream/conventions-review/blueprints/current/requirements.md`).

## Global Constraints

- Branch `feat/conventions-review` only. No worktree, no branch switch, no push, no merge into `main`.
- Never change `scripts/review.sh`, `scripts/skills.sh`, or `get_range` in `scripts/commits.sh`. Existing `commits.sh` subcommands keep their output byte for byte.
- Every new prose bash block binds `active_feature` itself via `progress.sh get-active` and stops on an empty / `null` value (lesson L-001).
- Run every test suite as `env -u CLAUDE_PLUGIN_ROOT bash tests/<suite>/run.sh` — the suites must exercise the repo scripts, not the installed plugin.
- Reviewer agent frontmatter is exactly `model: sonnet`, `effort: high`, `tools: [Read, Grep]`.
- Model override: `${MI_CONVENTIONS_REVIEW_MODEL:-sonnet}`. At most 3 reviewers per wave, each wave in one message.
- Finding severity ∈ {minor, major}; scope ∈ {fix, re-implement}. Never `blocker`.
- Seed-id: `conventions:<entry>:<file>:<first 8 hex of sha1(normalized quote, UTF-8, no trailing newline)>`, regressions `:r<N>`.
- Report line: `conventions review: N findings added (<entry>: n, …), M dropped, K entries not checkable`; cap note `— <entries> hit the 10-finding cap; run /mi-conventions-review again after fixing`.
- Fixed messages: `conventions review: nothing to check`, `conventions review: not run on the feature-test entry — it tests behaviour, not conventions`, `conventions review: failed — <error>`, `conventions review: N reviewers (<names>)`.
- Snapshot root `tmp/conventions-review/` with a self-ignoring `.gitignore` whose body is exactly `*\n!.gitignore\n`. Never touch `tmp/bundles/`.
- Release version `1.12.0`.

## Review Focus

1. A changed file whose path contains a space — `changed-lines`, the snapshot and the `file:` citation must all handle it (test in Task 1 and Task 3).
2. A reviewer citing `` `./src/a.ts:4` `` (leading `./`, backticks) or a quote wrapped in curly quotes — normalized, not dropped (test in Task 3).
3. A rule with malformed frontmatter, `paths: []`, or `paths:` as a comma string — must not crash `prepare`; empty/malformed means "applies to all" (test in Task 2).
4. A binary file in the change set — no hunks, so it is never covered and never snapshotted (test in Task 1).
5. `ingest` run twice in a row, or after a crash mid-write — never duplicates a finding (test in Task 3).

---

### Task 1: `commits.sh changed-lines` + suite scaffold (CVR-001)

**Files:**
- Modify: `scripts/commits.sh` (usage block near line 55; new case arm after `changed-files)`)
- Create: `tests/conventions-review/run.sh`

**Interfaces:**
- Produces: `commits.sh changed-lines <feature> <review-head>` → stdout rows `path<TAB>start-end`. Test helpers `make_sandbox`, `run_in`, `commit_all`, `ok`, `ng` reused by Tasks 2–6.

- [ ] **Step 1: Create the suite with the sandbox helpers and the failing tests**

`tests/conventions-review/run.sh` (make it executable):

```bash
#!/usr/bin/env bash
# run.sh — tests for the conventions-review feature (CVR-001..009).
#
# Each test prints PASS/FAIL; the suite exits 1 if any test failed. Tests run in
# sandbox git repos with their own data root; repo scripts are called by path.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$REPO_ROOT/tests/conventions-review/fixtures"
P="$REPO_ROOT/scripts/progress.sh"
C="$REPO_ROOT/scripts/commits.sh"
CR="$REPO_ROOT/scripts/conventions-review.sh"
R="$REPO_ROOT/scripts/review.sh"
UUID1="11111111-1111-4111-8111-111111111111"
UUID2="22222222-2222-4222-8222-222222222222"

pass=0
fail=0
fail_names=()
ok() { printf "\xe2\x9c\x93 %s\n" "$1"; pass=$((pass + 1)); }
ng() { printf "\xe2\x9c\x97 %s\n   %s\n" "$1" "$2" >&2; fail=$((fail + 1)); fail_names+=("$1"); }

SANDBOXES=()
cleanup() {
  local s
  for s in ${SANDBOXES[@]+"${SANDBOXES[@]}"}; do
    [[ -n "$s" && -d "$s" ]] && rm -rf "$s"
  done
}
trap cleanup EXIT

# run_in <sb> <cmd...> — cwd = repo, data root inside it, installed plugin hidden.
run_in() {
  local sb="$1"; shift
  (cd "$sb" && env -u CLAUDE_PLUGIN_ROOT MI_DATA_ROOT="$sb/millwright-inspector" "$@")
}

# make_sandbox — git repo with a seed commit; quest cycle with feature "feat"
# active, base-commit = seed commit, stage 5 / sub-flow none; requirements.md
# carries an id so review.sh init works.
make_sandbox() {
  local sb dr slug
  sb="$(cd "$(mktemp -d)" && pwd -P)"
  SANDBOXES+=("$sb")
  dr="$sb/millwright-inspector"
  slug="2026-10-05-demo"
  mkdir -p "$dr/quest/$slug" "$dr/workflow-stream/feat/blueprints/current"
  printf -- '---\nslug: %s\nstarted: "2026-10-05"\njournal-folders: [demo]\nstatus: active\n---\n\n# Active quest pointer\n' \
    "$slug" > "$dr/quest/active.md"
  printf -- '---\nid: %s\n---\n\n# Requirements\n' "$UUID2" \
    > "$dr/workflow-stream/feat/blueprints/current/requirements.md"
  (cd "$sb" && git init -q -b main && git config user.email t@t && git config user.name t \
     && printf 'seed\n' > README.md && git add README.md && git commit -qm seed)
  run_in "$sb" "$P" init "$UUID1" feat >/dev/null 2>&1
  run_in "$sb" "$P" activate >/dev/null 2>&1
  run_in "$sb" "$P" set "current-stage=5" "sub-flow=none" \
    "base-commit=$(cd "$sb" && git rev-parse HEAD)" >/dev/null 2>&1
  printf '%s' "$sb"
}

# commit_all <sb> <msg> — commit every change outside the data root.
commit_all() {
  (cd "$1" && git add -A -- . ':(exclude)millwright-inspector' && git commit -qm "$2")
}

head_of() { (cd "$1" && git rev-parse HEAD); }

# ---- Task 1: commits.sh changed-lines ------------------------------------------

sb="$(make_sandbox)"
(cd "$sb" && seq 1 20 > keep.txt && seq 1 5 > empty-me.txt && seq 1 3 > gone.txt \
   && seq 1 4 > old-name.txt && printf 'a\nb\n' > 'sp ace.txt' && git add -A -- . ':(exclude)millwright-inspector' \
   && git commit -qm base-files)
run_in "$sb" "$P" set "base-commit=$(head_of "$sb")" >/dev/null 2>&1
(cd "$sb" \
  && seq 1 20 | sed '5s/.*/five/' | sed '12d' > keep.txt \
  && printf 'x\ny\n' > added.txt \
  && : > empty-me.txt \
  && git rm -q gone.txt \
  && git mv old-name.txt new-name.txt \
  && printf 'a\nb\nc\n' > 'sp ace.txt' \
  && printf '\x89PNG\r\n\x1a\n\x00\x01' > pic.png)
commit_all "$sb" changes
got="$(run_in "$sb" "$C" changed-lines feat "$(head_of "$sb")" | sort)"
exp="$(printf 'added.txt\t1-2\nkeep.txt\t11-12\nkeep.txt\t5-5\nnew-name.txt\t1-4\nsp ace.txt\t3-3\n' | sort)"

t="changed-lines: added, changed, deletion-only, emptied, deleted, moved, spaced and binary files"
[[ "$got" == "$exp" ]] && ok "$t" || ng "$t" "got:
$got
expected:
$exp"

t="changed-lines: uses <review-head>, not HEAD"
first_head="$(head_of "$sb")"
(cd "$sb" && printf 'late\n' >> added.txt) && commit_all "$sb" late
got="$(run_in "$sb" "$C" changed-lines feat "$first_head" | grep '^added.txt')"
[[ "$got" == $'added.txt\t1-2' ]] && ok "$t" || ng "$t" "got: $got"

t="changed-lines: deletion at the top of a file gives 1-1"
sb2="$(make_sandbox)"
(cd "$sb2" && seq 1 3 > top.txt) && commit_all "$sb2" top
run_in "$sb2" "$P" set "base-commit=$(head_of "$sb2")" >/dev/null 2>&1
(cd "$sb2" && printf '2\n3\n' > top.txt) && commit_all "$sb2" drop-first
got="$(run_in "$sb2" "$C" changed-lines feat "$(head_of "$sb2")")"
[[ "$got" == $'top.txt\t1-1' ]] && ok "$t" || ng "$t" "got: $got"

t="changed-lines: deletion at the end of a file clamps to the last line"
(cd "$sb2" && printf '2\n' > top.txt) && commit_all "$sb2" drop-last
run_in "$sb2" "$P" set "base-commit=$(cd "$sb2" && git rev-parse HEAD~1)" >/dev/null 2>&1
got="$(run_in "$sb2" "$C" changed-lines feat "$(head_of "$sb2")")"
[[ "$got" == $'top.txt\t1-1' ]] && ok "$t" || ng "$t" "got: $got"

t="changed-lines: empty feature or review-head fails with a usage error"
if run_in "$sb2" "$C" changed-lines "" HEAD >/dev/null 2>&1 \
   || run_in "$sb2" "$C" changed-lines feat "" >/dev/null 2>&1; then
  ng "$t" "exited 0"
else
  ok "$t"
fi

# ---- summary -----------------------------------------------------------------
echo
echo "conventions-review: $pass passed, $fail failed"
if (( fail > 0 )); then
  printf '  - %s\n' "${fail_names[@]}" >&2
  exit 1
fi
```

New tasks append their test blocks **above** the `# ---- summary` line.

Expected rows, derived: `keep.txt` line 5 changed → `5-5`; old line 12 deleted → deletion after new line 11 → `11-12`; `empty-me.txt` emptied → nothing; `gone.txt` deleted → nothing; move shows as fully added → `new-name.txt 1-4`; `sp ace.txt` → `3-3`; `pic.png` binary → no hunk → nothing.

- [ ] **Step 2: Run the suite to verify it fails**

Run: `env -u CLAUDE_PLUGIN_ROOT bash tests/conventions-review/run.sh`
Expected: FAIL — `changed-lines` is an unknown subcommand.

- [ ] **Step 3: Implement `changed-lines`**

In `scripts/commits.sh`, add to the usage block after the `changed-files` entry:

```bash
#   commits.sh changed-lines <feature> <review-head>
#                                            # prints "<path>\t<start>-<end>" per block of added or
#                                            # changed lines in base-commit..<review-head>, from the
#                                            # hunk headers of `git diff -U0 --no-renames`. A
#                                            # deletion-only hunk prints the surviving neighbour
#                                            # lines (c-(c+1), clamped to the file); a deleted or
#                                            # emptied file prints nothing; a moved file is fully
#                                            # added. Used by scripts/conventions-review.sh.
```

Add the case arm right after the `changed-files)` arm's closing `;;`:

```bash
  changed-lines)
    feature="${1:?feature required}"
    review_head="${2:?review-head required}"
    range="$(get_range)"
    base="${range%..*}"
    python3 - "$base" "$review_head" <<'PYEOF'
import re, subprocess, sys
base, head = sys.argv[1], sys.argv[2]
diff = subprocess.check_output(
    ['git', '-c', 'core.quotePath=false', 'diff', '-U0', '--no-renames', '--no-color',
     '--no-ext-diff', f'{base}..{head}'], text=True, errors='surrogateescape')
HUNK = re.compile(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@')
counts = {}

def line_count(path):
    try:
        blob = subprocess.check_output(['git', 'cat-file', 'blob', f'{head}:{path}'],
                                       stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        return 0
    if not blob:
        return 0
    return blob.count(b'\n') + (0 if blob.endswith(b'\n') else 1)

path = None
for line in diff.splitlines():
    if line.startswith('+++ '):
        target = line[4:].rstrip('\t')
        path = None if target == '/dev/null' else (target[2:] if target.startswith('b/') else target)
        continue
    m = HUNK.match(line)
    if not m or path is None:
        continue
    c = int(m.group(1))
    d = 1 if m.group(2) is None else int(m.group(2))
    if d > 0:
        print(f'{path}\t{c}-{c + d - 1}')
        continue
    if path not in counts:
        counts[path] = line_count(path)
    n = counts[path]
    if n == 0:
        continue
    lo, hi = max(c, 1), min(c + 1, n)
    print(f'{path}\t{min(lo, hi)}-{hi}')
PYEOF
    ;;
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `env -u CLAUDE_PLUGIN_ROOT bash tests/conventions-review/run.sh`
Expected: all Task 1 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/commits.sh tests/conventions-review/run.sh
git commit -m "feat(commits): changed-lines subcommand for per-hunk line ranges (CVR-001)"
```

---

### Task 2: `conventions-review.sh prepare` (CVR-003, script part)

**Files:**
- Create: `scripts/conventions-review.sh`, `scripts/internal/conventions_review.py`
- Modify: `tests/conventions-review/run.sh`

**Interfaces:**
- Consumes: `commits.sh changed-lines` (Task 1); `skills.sh entries <feature> review` → `name<TAB>abs-path`; `todo.sh is-feature-test <name>` (exit 0 = yes); `progress.sh get-active|get current-stage|get sub-flow`; `mi_data_root`.
- Produces:
  - `conventions-review.sh prepare <feature>` → stdout either one fixed line (`nothing to check`, feature-test not-run) or `conventions review: N reviewers (<names>)` + `state: <abs state dir>`; exit 1 + stderr reason on refusal.
  - Run folder `tmp/conventions-review/<review-head>/` (snapshot) and `tmp/conventions-review/<review-head>.state/` holding `entries.tsv` (`idx\tname\tkind\tabs-path\tboundary`, idx from 1), `entry-<idx>.ranges` (`path\tstart-end`), `meta` (`feature=…`, `review-head=…`, `snapshot=…`).

- [ ] **Step 1: Append the failing tests**

Add a rule-writing helper and the tests above `# ---- summary`:

```bash
# ---- Task 2: prepare ------------------------------------------------------------

# write_rule <sb> <rel-path-under-.claude/rules> <frontmatter-or-empty>
write_rule() {
  mkdir -p "$(dirname "$1/.claude/rules/$2")"
  if [[ -n "$3" ]]; then
    printf -- '---\n%s\n---\n\n# rule\n\nUse tabs.\n' "$3" > "$1/.claude/rules/$2"
  else
    printf '# rule\n\nUse tabs.\n' > "$1/.claude/rules/$2"
  fi
}

# prep_sandbox — sandbox with src/api/order.ts and docs/a.md changed after base.
prep_sandbox() {
  local sb; sb="$(make_sandbox)"
  (cd "$sb" && mkdir -p src/api src/ui docs && printf 'one\n' > src/api/order.ts \
     && printf 'x\n' > docs/a.md) && commit_all "$sb" feature-work
  printf '%s' "$sb"
}

state_of() { sed -n 's/^state: //p' <<<"$1"; }

t="prepare: no skills and no rules prints nothing to check"
sb="$(prep_sandbox)"
got="$(run_in "$sb" "$CR" prepare feat 2>&1)"
[[ "$got" == "conventions review: nothing to check" ]] && ok "$t" || ng "$t" "got: $got"

t="prepare: refuses at stage 2"
run_in "$sb" "$P" set "current-stage=2" >/dev/null 2>&1
if run_in "$sb" "$CR" prepare feat >/dev/null 2>&1; then ng "$t" "exited 0"; else ok "$t"; fi

t="prepare: stage 3 needs sub-flow=resuming"
run_in "$sb" "$P" set "current-stage=3" "sub-flow=chain-in-progress" >/dev/null 2>&1
if run_in "$sb" "$CR" prepare feat >/dev/null 2>&1; then ng "$t" "exited 0 at chain-in-progress"; else
  run_in "$sb" "$P" set "sub-flow=resuming" >/dev/null 2>&1
  got="$(run_in "$sb" "$CR" prepare feat 2>&1)"
  [[ "$got" == "conventions review: nothing to check" ]] && ok "$t" || ng "$t" "resuming got: $got"
fi

t="prepare: empty feature is a usage error"
if run_in "$sb" "$CR" prepare "" >/dev/null 2>&1; then ng "$t" "exited 0"; else ok "$t"; fi

t="prepare: feature-test entry prints the not-run line and writes nothing"
sbf="$(prep_sandbox)"
printf -- '---\nid: %s\nfeature-test: feat\n---\n\n# Todo\n' "$UUID1" \
  > "$sbf/millwright-inspector/quest/2026-10-05-demo/todo-list.md"
write_rule "$sbf" always.md ""
got="$(run_in "$sbf" "$CR" prepare feat 2>&1)"
if [[ "$got" == "conventions review: not run on the feature-test entry — it tests behaviour, not conventions" \
      && ! -e "$sbf/tmp/conventions-review" ]]; then ok "$t"; else ng "$t" "got: $got"; fi

t="prepare: rule paths filtering — nested, symlinked, comma string, braces, *, **, malformed, empty list"
sb="$(prep_sandbox)"
write_rule "$sb" always.md ""
write_rule "$sb" backend/api.md 'paths:
  - "src/api/**"'
write_rule "$sb" comma.md 'paths: "lib/**, docs/*.md"'
write_rule "$sb" brace.md 'paths: ["src/**/*.{ts,tsx}"]'
write_rule "$sb" star.md 'paths: ["src/*.ts"]'
write_rule "$sb" zero.md 'paths: ["src/api/**/order.ts"]'
write_rule "$sb" nomatch.md 'paths: ["web/**"]'
write_rule "$sb" broken.md 'paths: [unclosed'
write_rule "$sb" empty.md 'paths: []'
mkdir -p "$sb/shared-rules" && printf '# linked\n' > "$sb/shared-rules/linked.md"
ln -s "$sb/shared-rules" "$sb/.claude/rules/shared"
out="$(run_in "$sb" "$CR" prepare feat 2>&1)"
state="$(state_of "$out")"
names="$(cut -f2 "$state/entries.tsv" 2>/dev/null | sort | tr '\n' ' ')"
exp="always backend/api brace broken comma empty shared/linked zero "
[[ "$names" == "$exp" ]] && ok "$t" || ng "$t" "entries: $names
out: $out"

t="prepare: a scoped rule's ranges file lists only its matching files"
idx="$(awk -F'\t' '$2=="backend/api"{print $1}' "$state/entries.tsv")"
got="$(cut -f1 "$state/entry-$idx.ranges" | sort -u | tr '\n' ' ')"
[[ "$got" == "src/api/order.ts " ]] && ok "$t" || ng "$t" "got: $got"

t="prepare: summary line names every reviewer"
[[ "$(head -1 <<<"$out")" == "conventions review: 8 reviewers ("*")" ]] && ok "$t" || ng "$t" "got: $out"

t="prepare: the data root is never covered"
mkdir -p "$sb/millwright-inspector/workflow-stream/feat/implementation"
printf 'x\n' > "$sb/millwright-inspector/workflow-stream/feat/implementation/note.md"
(cd "$sb" && git add -f millwright-inspector/workflow-stream/feat/implementation/note.md && git commit -qm data)
out="$(run_in "$sb" "$CR" prepare feat 2>&1)"; state="$(state_of "$out")"
if grep -q 'millwright-inspector/' "$state"/entry-*.ranges; then ng "$t" "data-root path covered"; else ok "$t"; fi

t="prepare: skill entries come from skills.sh with the folder as boundary"
sbs="$(prep_sandbox)"
mkdir -p "$sbs/.claude/skills/react-forms"
printf -- '---\nname: react-forms\ndescription: d\n---\n\nValidate input with zod.\n' > "$sbs/.claude/skills/react-forms/SKILL.md"
cur="$sbs/millwright-inspector/workflow-stream/feat/blueprints/current"
printf -- '---\nid: %s\nrequirements-id: %s\n---\n\n<!-- auto:start -->\n\n## Skills\n\n- react-forms — forms\n  stages: review; skill: react-forms; path: .claude/skills/react-forms/SKILL.md\n\n## Load on demand\n\n<!-- auto:end -->\n' \
  "33333333-3333-4333-8333-333333333333" "$UUID2" > "$cur/config.md"
out="$(run_in "$sbs" "$CR" prepare feat 2>&1)"; state="$(state_of "$out")"
got="$(awk -F'\t' '{print $2"|"$3"|"$5}' "$state/entries.tsv")"
[[ "$got" == "react-forms|skill|$sbs/.claude/skills/react-forms" ]] && ok "$t" || ng "$t" "got: $got
out: $out"

t="prepare: snapshot is the committed blob — uncommitted edits do not leak in"
printf 'DIRTY\n' > "$sbs/src/api/order.ts"
out="$(run_in "$sbs" "$CR" prepare feat 2>&1)"; state="$(state_of "$out")"
snap="$(sed -n 's/^snapshot=//p' "$state/meta")"
[[ "$(cat "$snap/src/api/order.ts")" == "one" ]] && ok "$t" || ng "$t" "snapshot: $(cat "$snap/src/api/order.ts")"
(cd "$sbs" && git checkout -q -- src/api/order.ts)

t="prepare: export-ignore and export-subst files match git cat-file blob byte for byte"
(cd "$sbs" && printf 'src/api/ign.ts export-ignore\nsrc/api/subst.ts export-subst\n' > .gitattributes \
   && printf 'ignored\n' > src/api/ign.ts && printf '$Format:%%H$\n' > src/api/subst.ts) \
  && commit_all "$sbs" attrs
out="$(run_in "$sbs" "$CR" prepare feat 2>&1)"; state="$(state_of "$out")"
snap="$(sed -n 's/^snapshot=//p' "$state/meta")"; h="$(head_of "$sbs")"
if cmp -s "$snap/src/api/ign.ts" <(cd "$sbs" && git cat-file blob "$h:src/api/ign.ts") \
   && cmp -s "$snap/src/api/subst.ts" <(cd "$sbs" && git cat-file blob "$h:src/api/subst.ts"); then ok "$t"
else ng "$t" "snapshot differs from cat-file blob"; fi

t="prepare: a changed root .gitignore lands in the snapshot without touching the run root's"
(cd "$sbs" && printf 'node_modules\n' > .gitignore) && commit_all "$sbs" gi
out="$(run_in "$sbs" "$CR" prepare feat 2>&1)"; state="$(state_of "$out")"
snap="$(sed -n 's/^snapshot=//p' "$state/meta")"
if [[ "$(cat "$snap/.gitignore")" == "node_modules" \
      && "$(cat "$sbs/tmp/conventions-review/.gitignore")" == $'*\n!.gitignore' ]]; then ok "$t"
else ng "$t" "snapshot or run-root .gitignore wrong"; fi

t="prepare: stale runs are cleared and tmp/bundles is untouched"
mkdir -p "$sbs/tmp/bundles" && printf 'keep\n' > "$sbs/tmp/bundles/x.md"
mkdir -p "$sbs/tmp/conventions-review/deadbeef.state"
run_in "$sbs" "$CR" prepare feat >/dev/null 2>&1
if [[ ! -e "$sbs/tmp/conventions-review/deadbeef.state" && -f "$sbs/tmp/bundles/x.md" ]]; then ok "$t"
else ng "$t" "stale run kept or bundles touched"; fi
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `env -u CLAUDE_PLUGIN_ROOT bash tests/conventions-review/run.sh`
Expected: Task 2 tests FAIL (`conventions-review.sh` does not exist).

- [ ] **Step 3: Write the bash wrapper**

`scripts/conventions-review.sh` (executable):

```bash
#!/usr/bin/env bash
# conventions-review.sh — helper for /mi-conventions-review (1.12.0). Main runs
# `prepare`, spawns one conventions-reviewer per entry, saves each final reply to
# <state>/reply-<idx>.md, then runs `ingest`. Logic lives in
# internal/conventions_review.py; this wrapper checks state and resolves paths.
#
# Spec: docs/superpowers/specs/2026-10-05-conventions-review-design.md
#
# Usage:
#   conventions-review.sh prepare <feature>
#       Gate (stage 3 + sub-flow resuming, or stage 5/6), feature-test no-op,
#       snapshot of changed files at review-head, entry selection, run state.
#       Prints "conventions review: nothing to check", the feature-test line, or
#       "conventions review: N reviewers (<names>)" + "state: <dir>".
#   conventions-review.sh ingest <feature>
#       Parses every reply of the current run (writes nothing if one is missing
#       or unparseable), validates, dedupes and writes findings via review.sh
#       add, prints the report line, appends one ledger row, deletes the run.
set -euo pipefail
source "$(dirname "$0")/internal/common.sh"

PY="$(dirname "$0")/internal/conventions_review.py"
S="${MI_PLUGIN_ROOT}/scripts"
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

cmd="${1:-}"; shift || true

require_active() {
  local active
  active="$("$S/progress.sh" get-active 2>/dev/null || echo null)"
  [[ "$active" == "$1" ]] || mi_die "'$1' is not the active feature (active: $active)"
}

case "$cmd" in
  prepare)
    [[ $# -eq 1 && -n "$1" ]] || usage
    feature="$1"
    require_active "$feature"
    stage="$("$S/progress.sh" get current-stage)"
    sub="$("$S/progress.sh" get sub-flow)"
    case "$stage/$sub" in
      3/resuming|5/*|6/*) ;;
      *) mi_die "conventions review runs from the stage-3 Resume Handler or at stage 5/6 (now: stage $stage, sub-flow $sub)" ;;
    esac
    if "$S/todo.sh" is-feature-test "$feature"; then
      echo "conventions review: not run on the feature-test entry — it tests behaviour, not conventions"
      exit 0
    fi
    top="$(git rev-parse --show-toplevel)"
    review_head="$(git rev-parse HEAD)"
    CVR_LINES="$("$S/commits.sh" changed-lines "$feature" "$review_head")" \
    CVR_SKILLS="$("$S/skills.sh" entries "$feature" review)" \
      python3 "$PY" prepare "$top" "$review_head" "$(mi_data_root)" "$feature"
    ;;
  ingest)
    [[ $# -eq 1 && -n "$1" ]] || usage
    feature="$1"
    require_active "$feature"
    review_md="$(mi_impl_dir "$feature")/inspector-review.md"
    [[ -f "$review_md" ]] || mi_die "inspector-review.md not found: $review_md"
    top="$(git rev-parse --show-toplevel)"
    shopt -s nullglob
    states=("$top"/tmp/conventions-review/*.state)
    shopt -u nullglob
    [[ ${#states[@]} -eq 1 ]] || mi_die "expected one run under tmp/conventions-review/, found ${#states[@]} — run prepare first"
    state="${states[0]}"
    report="$(CVR_REVIEW_SH="$S/review.sh" python3 "$PY" ingest "$top" "$state" "$feature")"
    printf '%s\n' "$report"
    stage="$("$S/progress.sh" get current-stage 2>/dev/null || echo -)"
    "$S/ledger.sh" append "$stage" "/mi-conventions-review" "$(wc -l < "$state/entries.tsv" | tr -d ' ') reviewer replies" \
      small sub-agent "$report" >/dev/null 2>&1 || echo "warning: ledger append failed" >&2
    rm -rf "${state%.state}" "$state"
    ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
```

- [ ] **Step 4: Write the Python `prepare`**

`scripts/internal/conventions_review.py` (the `ingest` half comes in Task 3; leave its dispatch branch raising `SystemExit("ingest: not implemented")` for now):

```python
#!/usr/bin/env python3
"""conventions_review.py — logic behind scripts/conventions-review.sh.

Spec: docs/superpowers/specs/2026-10-05-conventions-review-design.md
"""
import os
import re
import shutil
import subprocess
import sys

import yaml

GITIGNORE = "*\n!.gitignore\n"


def die(msg):
    sys.stderr.write("error: %s\n" % msg)
    sys.exit(1)


# ---- rule selection -----------------------------------------------------------

def find_rules(rules_dir):
    """Every *.md under rules_dir at any depth, following symlinks (cycle-safe)."""
    out, seen = [], set()
    for dirpath, dirnames, filenames in os.walk(rules_dir, followlinks=True):
        real = os.path.realpath(dirpath)
        if real in seen:
            dirnames[:] = []
            continue
        seen.add(real)
        dirnames.sort()
        for fn in sorted(filenames):
            if fn.endswith(".md"):
                out.append(os.path.join(dirpath, fn))
    return sorted(out)


def rule_patterns(path):
    """paths: frontmatter as a list of patterns, or None (= applies to all).

    A YAML list or a comma-separated string (Claude Code docs). Missing, empty
    or malformed frontmatter means the rule applies to every file.
    """
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return None
    m = re.match(r"^---\n(.*?)\n---\s*(?:\n|$)", text, re.DOTALL)
    if not m:
        return None
    try:
        fm = yaml.safe_load(m.group(1)) or {}
    except yaml.YAMLError:
        return None
    raw = fm.get("paths") if isinstance(fm, dict) else None
    if isinstance(raw, str):
        items = raw.split(",")
    elif isinstance(raw, list):
        items = [str(x) for x in raw]
    else:
        return None
    pats = [p.strip() for p in items if p and p.strip()]
    return pats or None


def expand_braces(pat):
    m = re.search(r"\{([^{}]*)\}", pat)
    if not m:
        return [pat]
    out = []
    for alt in m.group(1).split(","):
        out.extend(expand_braces(pat[:m.start()] + alt + pat[m.end():]))
    return out


def glob_regex(pat):
    """`*` never crosses `/`; `**` matches zero or more folders."""
    if pat.startswith("./"):
        pat = pat[2:]
    pat = pat.lstrip("/")
    out, i = "", 0
    while i < len(pat):
        if pat.startswith("**/", i):
            out += "(?:.*/)?"
            i += 3
        elif pat.startswith("**", i):
            out += ".*"
            i += 2
        elif pat[i] == "*":
            out += "[^/]*"
            i += 1
        elif pat[i] == "?":
            out += "[^/]"
            i += 1
        else:
            out += re.escape(pat[i])
            i += 1
    return re.compile(out + r"\Z")


def matches(patterns, path):
    return any(glob_regex(p).match(path) for pat in patterns for p in expand_braces(pat))


# ---- prepare ------------------------------------------------------------------

def clean_run_root(root):
    os.makedirs(root, exist_ok=True)
    for name in os.listdir(root):
        if name == ".gitignore":
            continue
        p = os.path.join(root, name)
        if os.path.isdir(p) and not os.path.islink(p):
            shutil.rmtree(p)
        else:
            os.remove(p)
    with open(os.path.join(root, ".gitignore"), "w") as f:
        f.write(GITIGNORE)


def cmd_prepare(top, head, data_root, feature):
    run_root = os.path.join(top, "tmp", "conventions-review")
    clean_run_root(run_root)

    dr = os.path.relpath(os.path.realpath(data_root), os.path.realpath(top))
    inside = not dr.startswith("..")
    ranges = {}
    for row in os.environ.get("CVR_LINES", "").splitlines():
        if "\t" not in row:
            continue
        path, rng = row.rsplit("\t", 1)
        if inside and (dr == "." or path == dr or path.startswith(dr + "/")):
            continue
        ranges.setdefault(path, []).append(rng)
    covered = list(ranges)

    entries = []  # (name, kind, abs path, boundary, files)
    if covered:
        for row in os.environ.get("CVR_SKILLS", "").splitlines():
            if "\t" not in row:
                continue
            name, path = row.split("\t", 1)
            boundary = path if os.path.isdir(path) else os.path.dirname(path)
            entries.append((name, "skill", path, boundary, covered))
        rules_dir = os.path.join(top, ".claude", "rules")
        if os.path.isdir(rules_dir):
            for rule in find_rules(rules_dir):
                pats = rule_patterns(rule)
                files = covered if pats is None else [f for f in covered if matches(pats, f)]
                if files:
                    name = os.path.relpath(rule, rules_dir)[:-3]
                    entries.append((name, "rule", rule, rule, files))

    if not entries:
        print("conventions review: nothing to check")
        return

    snap = os.path.join(run_root, head)
    for f in covered:
        blob = subprocess.check_output(["git", "-C", top, "cat-file", "blob", "%s:%s" % (head, f)])
        dest = os.path.join(snap, f)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as out:
            out.write(blob)

    state = snap + ".state"
    os.makedirs(state)
    with open(os.path.join(state, "entries.tsv"), "w") as tsv:
        for idx, (name, kind, path, boundary, files) in enumerate(entries, 1):
            tsv.write("%d\t%s\t%s\t%s\t%s\n" % (idx, name, kind, path, boundary))
            with open(os.path.join(state, "entry-%d.ranges" % idx), "w") as rf:
                for f in files:
                    for rng in ranges[f]:
                        rf.write("%s\t%s\n" % (f, rng))
    with open(os.path.join(state, "meta"), "w") as meta:
        meta.write("feature=%s\nreview-head=%s\nsnapshot=%s\n" % (feature, head, snap))

    print("conventions review: %d reviewers (%s)" % (len(entries), ", ".join(e[0] for e in entries)))
    print("state: %s" % state)


def main(argv):
    if len(argv) < 2:
        die("usage: conventions_review.py prepare|ingest ...")
    if argv[1] == "prepare" and len(argv) == 6:
        cmd_prepare(*argv[2:])
    elif argv[1] == "ingest" and len(argv) == 5:
        raise SystemExit("ingest: not implemented")
    else:
        die("bad arguments: %s" % " ".join(argv[1:]))


if __name__ == "__main__":
    main(sys.argv)
```

- [ ] **Step 5: Run the suite; all Task 1–2 tests pass**

Run: `env -u CLAUDE_PLUGIN_ROOT bash tests/conventions-review/run.sh`
Expected: PASS. If `skills.sh entries` prints nothing for the skill test, check the fixture `config.md` against `tests/skills/fixtures/*config.md` and fix the **fixture**, not `skills.sh`.

- [ ] **Step 6: Commit**

```bash
git add scripts/conventions-review.sh scripts/internal/conventions_review.py tests/conventions-review/run.sh
git commit -m "feat(conventions-review): prepare — gate, snapshot, skill and rule selection (CVR-003)"
```

---

### Task 3: `conventions-review.sh ingest` (CVR-004)

**Files:**
- Modify: `scripts/internal/conventions_review.py`
- Create: `tests/conventions-review/fixtures/` (reply files written inline by the tests are fine; no fixture files required)
- Modify: `tests/conventions-review/run.sh`

**Interfaces:**
- Consumes: run state from Task 2; `review.sh find-by-seed-id-family <feature> <base>` → rows `IR-NNN\t<seed-id>\t<status>`; `review.sh add <feature> <severity> <scope> <summary> --source conventions-review --seed-id <id>` with details on stdin (prints the IR id).
- Produces: `conventions-review.sh ingest <feature>` → last stdout line = report line; exit 1 + stderr `<entry>: <reason>` when a reply is missing/unparseable (nothing written).

- [ ] **Step 1: Append the failing tests**

```bash
# ---- Task 3: ingest -------------------------------------------------------------

# ingest_sandbox — one rule "style" (no paths:) + one skill "forms"; src/a.ts
# lines 1-4 exist at base, the feature changes lines 3-4 and adds b.ts.
# Leaves the run prepared and prints the state dir.
ingest_sandbox() {
  local sb cur
  sb="$(make_sandbox)"
  (cd "$sb" && mkdir -p src && printf 'l1\nl2\nl3\nl4\n' > src/a.ts) && commit_all "$sb" base-a
  run_in "$sb" "$P" set "base-commit=$(head_of "$sb")" >/dev/null 2>&1
  (cd "$sb" && printf 'l1\nl2\nNEW3\nNEW4\n' > src/a.ts && printf 'b1\nb2\n' > 'src/b c.ts') && commit_all "$sb" work
  mkdir -p "$sb/.claude/rules" "$sb/.claude/skills/forms/ref"
  printf '# Style\n\nUse tabs for   indentation\nin every file.\nSee ref.md for more.\n' > "$sb/.claude/rules/style.md"
  printf -- '---\nname: forms\ndescription: d\n---\n\nValidate input with zod.\nRead ref/schemas.md for schemas.\n' \
    > "$sb/.claude/skills/forms/SKILL.md"
  printf 'Schemas live in one file.\n' > "$sb/.claude/skills/forms/ref/schemas.md"
  printf 'outside text\n' > "$sb/outside.md"
  cur="$sb/millwright-inspector/workflow-stream/feat/blueprints/current"
  printf -- '---\nid: %s\nrequirements-id: %s\n---\n\n<!-- auto:start -->\n\n## Skills\n\n- forms — forms\n  stages: review; skill: forms; path: .claude/skills/forms/SKILL.md\n\n## Load on demand\n\n<!-- auto:end -->\n' \
    "33333333-3333-4333-8333-333333333333" "$UUID2" > "$cur/config.md"
  run_in "$sb" "$R" init feat >/dev/null 2>&1
  printf '%s' "$sb"
}

idx_of() { awk -F'\t' -v n="$2" '$2==n{print $1}' "$1/entries.tsv"; }

# reply <file> <entry-line> <result> <more> [block...] — each block is the body
# after "### F-n" (already formatted "- key: value" lines).
reply() {
  local f="$1" entry="$2" result="$3" more="$4"; shift 4
  { printf 'Entry: %s\nResult: %s\nMore: %s\n' "$entry" "$result" "$more"
    local n=1 b
    for b in "$@"; do printf '\n### F-%d\n%s\n' "$n" "$b"; n=$((n + 1)); done
  } > "$f"
}

blk() { # file sev scope quote source summary
  printf -- '- file: %s\n- severity: %s\n- scope: %s\n- quote: %s\n- source: %s\n- summary: %s\n- details: |\n    why it matters\n' \
    "$1" "$2" "$3" "$4" "$5" "$6"
}

sb="$(ingest_sandbox)"
out="$(run_in "$sb" "$CR" prepare feat 2>&1)"; state="$(state_of "$out")"
si="$(idx_of "$state" style)"; fi_="$(idx_of "$state" forms)"
STYLE="$sb/.claude/rules/style.md"; FORMS="$sb/.claude/skills/forms/SKILL.md"
reply "$state/reply-$si.md" "style (rule)" findings no \
  "$(blk 'src/a.ts:3,1' minor fix '"Use tabs for indentation in every file."' "$STYLE" 'trimmed + wrapped quote')" \
  "$(blk 'src/a.ts:3' minor fix '' "$STYLE" 'missing quote')" \
  "$(blk 'src/a.ts:3' minor fix '"Use spaces."' "$STYLE" 'made-up quote')" \
  "$(blk 'src/a.ts:3' minor fix '"outside text"' "$sb/outside.md" 'source outside entry')" \
  "$(blk 'README.md:1' minor fix '"See ref.md for more."' "$STYLE" 'file outside change set')" \
  "$(blk 'src/a.ts:3' blocker fix '"See ref.md for more."' "$STYLE" 'blocker severity')" \
  "$(blk 'src/a.ts:1' minor fix '"See ref.md for more."' "$STYLE" 'pre-base line')" \
  "$(blk 'src/a.ts:99' minor fix '"See ref.md for more."' "$STYLE" 'past end of file')" \
  "$(blk 'src/a.ts' minor fix '"See ref.md for more."' "$STYLE" 'no line number')"
reply "$state/reply-$fi_.md" "forms (skill)" findings yes \
  "$(blk '`./src/a.ts:4`' major re-implement '“Validate input with zod.”' "$FORMS" 'backticked file, curly quote')" \
  "$(blk 'src/b c.ts:2' minor fix '"Schemas live in one file."' "$sb/.claude/skills/forms/ref/schemas.md" 'linked ref inside folder')" \
  "$(blk 'src/a.ts:3' minor fix '"Use tabs for indentation in every file."' "$STYLE" 'rule quote from a skill entry')"
got="$(run_in "$sb" "$CR" ingest feat 2>&1 | tail -1)"

t="ingest: report counts added, dropped, cap note"
exp="conventions review: 3 findings added (style: 1, forms: 2), 9 dropped, 0 entries not checkable — forms hit the 10-finding cap; run /mi-conventions-review again after fixing"
[[ "$got" == "$exp" ]] && ok "$t" || ng "$t" "got: $got"

RMD="$sb/millwright-inspector/workflow-stream/feat/implementation/inspector-review.md"
t="ingest: a finding citing a changed and an old line keeps only the changed line"
grep -q 'file: src/a.ts:3$' "$RMD" && ok "$t" || ng "$t" "$(grep -n 'file:' "$RMD")"

t="ingest: findings carry source conventions-review and the conventions seed-id"
sha="$(printf '%s' 'Use tabs for indentation in every file.' | shasum -a 1 | cut -c1-8)"
grep -q "seed-id: conventions:style:src/a.ts:$sha" "$RMD" && grep -q 'source: conventions-review' "$RMD" \
  && ok "$t" || ng "$t" "seed-id or source missing"

t="ingest: spaced path and backticked ./ citation are kept"
grep -q 'file: src/b c.ts:2' "$RMD" && grep -q 'file: src/a.ts:4' "$RMD" && ok "$t" || ng "$t" "$(grep 'file:' "$RMD")"

t="ingest: the run folder is deleted after success"
[[ ! -e "$state" && ! -e "${state%.state}" ]] && ok "$t" || ng "$t" "run folder left behind"

t="ingest: a second run with the same replies adds nothing (also after a line shift)"
(cd "$sb" && printf 'top\nl1\nl2\nNEW3\nNEW4\n' > src/a.ts) && commit_all "$sb" shift
out="$(run_in "$sb" "$CR" prepare feat 2>&1)"; state="$(state_of "$out")"
si="$(idx_of "$state" style)"; fi_="$(idx_of "$state" forms)"
reply "$state/reply-$si.md" "style (rule)" findings no \
  "$(blk 'src/a.ts:4' minor fix '"Use tabs for indentation in every file."' "$STYLE" 'moved')"
reply "$state/reply-$fi_.md" "forms (skill)" clean no
before="$(grep -c '^### IR-' "$RMD")"
got="$(run_in "$sb" "$CR" ingest feat 2>&1 | tail -1)"
after="$(grep -c '^### IR-' "$RMD")"
[[ "$before" == "$after" && "$got" == "conventions review: 0 findings added, 0 dropped, 0 entries not checkable" ]] \
  && ok "$t" || ng "$t" "before=$before after=$after got: $got"

t="ingest: a fixed finding reported again returns as :r1; wontfix stays skipped"
ir_style="$(grep -B8 "seed-id: conventions:style:src/a.ts:$sha\$" "$RMD" | sed -n 's/^### \(IR-[0-9]*\).*/\1/p' | tail -1)"
ir_forms="$(grep -B8 'seed-id: conventions:forms:src/a.ts:' "$RMD" | sed -n 's/^### \(IR-[0-9]*\).*/\1/p' | tail -1)"
run_in "$sb" "$R" set-status feat "$ir_style" fixed >/dev/null 2>&1
run_in "$sb" "$R" set-status feat "$ir_forms" wontfix >/dev/null 2>&1
out="$(run_in "$sb" "$CR" prepare feat 2>&1)"; state="$(state_of "$out")"
si="$(idx_of "$state" style)"; fi_="$(idx_of "$state" forms)"
reply "$state/reply-$si.md" "style (rule)" findings no \
  "$(blk 'src/a.ts:4' minor fix '"Use tabs for indentation in every file."' "$STYLE" 'again')"
reply "$state/reply-$fi_.md" "forms (skill)" findings no \
  "$(blk 'src/a.ts:5' major fix '"Validate input with zod."' "$FORMS" 'again')"
run_in "$sb" "$CR" ingest feat >/dev/null 2>&1
if grep -q "seed-id: conventions:style:src/a.ts:$sha:r1" "$RMD" \
   && [[ "$(grep -c 'seed-id: conventions:forms:src/a.ts:' "$RMD")" == "1" ]]; then ok "$t"
else ng "$t" "$(grep 'seed-id' "$RMD")"; fi

t="ingest: two entries citing one line give two findings; not-checkable is counted"
sb="$(ingest_sandbox)"
out="$(run_in "$sb" "$CR" prepare feat 2>&1)"; state="$(state_of "$out")"
si="$(idx_of "$state" style)"; fi_="$(idx_of "$state" forms)"
reply "$state/reply-$si.md" "style (rule)" findings no \
  "$(blk 'src/a.ts:3' minor fix '"See ref.md for more."' "$STYLE" 'pointer sentence')"
reply "$state/reply-$fi_.md" "forms (skill)" findings no \
  "$(blk 'src/a.ts:3' minor fix '"Validate input with zod."' "$FORMS" 'same line')"
got="$(run_in "$sb" "$CR" ingest feat 2>&1 | tail -1)"
[[ "$got" == "conventions review: 2 findings added (style: 1, forms: 1), 0 dropped, 0 entries not checkable" ]] \
  && ok "$t" || ng "$t" "got: $got"

t="ingest: a missing or unparseable reply fails and writes nothing"
sb="$(ingest_sandbox)"
out="$(run_in "$sb" "$CR" prepare feat 2>&1)"; state="$(state_of "$out")"
si="$(idx_of "$state" style)"; fi_="$(idx_of "$state" forms)"
reply "$state/reply-$si.md" "style (rule)" findings no \
  "$(blk 'src/a.ts:3' minor fix '"See ref.md for more."' "$STYLE" 'would be added')"
printf 'Sorry, I could not do this.\n' > "$state/reply-$fi_.md"
RMD="$sb/millwright-inspector/workflow-stream/feat/implementation/inspector-review.md"
if run_in "$sb" "$CR" ingest feat >/dev/null 2>&1; then ng "$t" "exited 0"
elif grep -q '^### IR-' "$RMD"; then ng "$t" "a finding was written"
elif [[ ! -d "$state" ]]; then ng "$t" "run folder deleted on failure"
else ok "$t"; fi

t="ingest: a not-checkable reply counts the entry"
reply "$state/reply-$fi_.md" "forms (skill)" not-checkable no
printf 'reason: about how Claude works\n' >> "$state/reply-$fi_.md"
got="$(run_in "$sb" "$CR" ingest feat 2>&1 | tail -1)"
[[ "$got" == "conventions review: 1 findings added (style: 1), 0 dropped, 1 entries not checkable" ]] \
  && ok "$t" || ng "$t" "got: $got"
```

Drop count for the first scenario: style has 9 blocks — 1 kept (`src/a.ts:3,1` is trimmed to line 3, not dropped) and 8 dropped (missing quote, made-up quote, source outside entry, file outside change set, blocker, pre-base line, past end of file, no line number). Forms has 3 — 2 kept, 1 dropped (its third block quotes the style rule, outside the forms folder). Total: 3 added, 9 dropped.

Also append the eighth blueprint drop case — a rule finding on a file outside its `paths:`:

```bash
t="ingest: a rule finding on a file outside its paths: is dropped"
sb="$(ingest_sandbox)"
printf -- '---\npaths: ["src/b*"]\n---\n\nKeep it short.\n' > "$sb/.claude/rules/scoped.md"
out="$(run_in "$sb" "$CR" prepare feat 2>&1)"; state="$(state_of "$out")"
while IFS=$'\t' read -r idx name kind _ _; do
  if [[ "$name" == "scoped" ]]; then
    reply "$state/reply-$idx.md" "scoped (rule)" findings no \
      "$(blk 'src/a.ts:3' minor fix '"Keep it short."' "$sb/.claude/rules/scoped.md" 'outside paths')"
  else
    reply "$state/reply-$idx.md" "$name ($kind)" clean no
  fi
done < "$state/entries.tsv"
got="$(run_in "$sb" "$CR" ingest feat 2>&1 | tail -1)"
[[ "$got" == "conventions review: 0 findings added, 1 dropped, 0 entries not checkable" ]] \
  && ok "$t" || ng "$t" "got: $got"
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `env -u CLAUDE_PLUGIN_ROOT bash tests/conventions-review/run.sh`
Expected: Task 3 tests FAIL with `ingest: not implemented`.

- [ ] **Step 3: Implement `ingest`**

Add to `scripts/internal/conventions_review.py` (above `main`) and replace the `ingest` branch in `main` with `cmd_ingest(*argv[2:])`:

```python
# ---- ingest -------------------------------------------------------------------

import hashlib
import textwrap

FIELDS = ("file", "severity", "scope", "quote", "source", "summary", "details")
FIELD_RE = re.compile(r"^- (file|severity|scope|quote|source|summary|details):[ \t]*(.*)$")
QUOTE_PAIRS = {'"': '"', "'": "'", "“": "”", "‘": "’", "`": "`"}


class ParseError(Exception):
    pass


def norm(text):
    return re.sub(r"\s+", " ", text).strip()


def strip_quotes(s):
    s = s.strip()
    if len(s) >= 2 and s[0] in QUOTE_PAIRS and s[-1] == QUOTE_PAIRS[s[0]]:
        return s[1:-1].strip()
    return s


def parse_block(body):
    fields, cur = {}, None
    for line in body.splitlines():
        m = FIELD_RE.match(line)
        if m:
            cur, val = m.group(1), m.group(2)
            fields[cur] = [] if (cur == "details" and val.strip() in ("|", "|-", ">")) else [val]
        elif cur and (line[:1] in (" ", "\t") or not line.strip()):
            fields[cur].append(line)
    out = {}
    for key, vals in fields.items():
        if key == "details":
            out[key] = textwrap.dedent("\n".join(vals)).strip()
        else:
            out[key] = " ".join(v.strip() for v in vals if v.strip())
    return out


def parse_reply(text):
    entry = re.search(r"(?m)^Entry:\s*\S", text)
    result = re.search(r"(?m)^Result:\s*(findings|clean|not-checkable)\s*$", text)
    more = re.search(r"(?m)^More:\s*(yes|no)\s*$", text)
    if not (entry and result and more):
        raise ParseError("reply lacks the Entry/Result/More header")
    blocks = re.split(r"(?m)^### F-\d+\s*$", text)[1:]
    if result.group(1) == "findings" and not blocks:
        raise ParseError("Result: findings without any ### F-n block")
    return result.group(1), more.group(1) == "yes", [parse_block(b) for b in blocks]


def load_ranges(path):
    out = {}
    with open(path) as f:
        for row in f:
            row = row.rstrip("\n")
            if "\t" not in row:
                continue
            p, rng = row.rsplit("\t", 1)
            a, b = rng.split("-")
            out.setdefault(p, []).append((int(a), int(b)))
    return out


def snapshot_lines(snap, rel):
    try:
        data = open(os.path.join(snap, rel), "rb").read()
    except OSError:
        return 0
    if not data:
        return 0
    return data.count(b"\n") + (0 if data.endswith(b"\n") else 1)


def inside(path, boundary, kind):
    p, b = os.path.realpath(path), os.path.realpath(boundary)
    return p == b if kind == "rule" else (p == b or p.startswith(b + os.sep))


def validate(top, snap, kind, boundary, ranges, f):
    """Return (rel_file, kept_lines, quote, source_abs) or None to drop."""
    if any(not f.get(k) for k in FIELDS):
        return None
    if f["severity"] not in ("minor", "major") or f["scope"] not in ("fix", "re-implement"):
        return None
    quote = strip_quotes(f["quote"])
    if not quote:
        return None
    source = f["source"].strip().strip("`")
    source = source if os.path.isabs(source) else os.path.join(top, source)
    if not os.path.isfile(source) or not inside(source, boundary, kind):
        return None
    if norm(quote) not in norm(open(source, encoding="utf-8", errors="replace").read()):
        return None
    m = re.match(r"^(.+?):(\d+(?:\s*,\s*\d+)*)$", f["file"].strip().strip("`").strip())
    if not m:
        return None
    rel = m.group(1)
    rel = rel[2:] if rel.startswith("./") else rel
    if rel not in ranges:
        return None
    n = snapshot_lines(snap, rel)
    keep = []
    for ln in (int(x) for x in re.split(r"\s*,\s*", m.group(2))):
        if 1 <= ln <= n and any(a <= ln <= b for a, b in ranges[rel]) and ln not in keep:
            keep.append(ln)
    if not keep:
        return None
    return rel, keep, quote, source


def family(review_sh, feature, seed):
    out = subprocess.run([review_sh, "find-by-seed-id-family", feature, seed],
                         capture_output=True, text=True, check=True).stdout
    return [r.split("\t") for r in out.splitlines() if r.count("\t") == 2]


def next_seed(seed, rows):
    """None to skip; else the seed-id to write."""
    if any(status in ("open", "wontfix") for _, _, status in rows):
        return None
    if not rows:
        return seed
    top_n = 0
    for _, sid, _ in rows:
        m = re.match(re.escape(seed) + r":r(\d+)$", sid)
        if m:
            top_n = max(top_n, int(m.group(1)))
    return "%s:r%d" % (seed, top_n + 1)


def cmd_ingest(top, state, feature):
    review_sh = os.environ["CVR_REVIEW_SH"]
    meta = dict(l.rstrip("\n").split("=", 1) for l in open(os.path.join(state, "meta")) if "=" in l)
    if meta.get("feature") != feature:
        die("run belongs to %s, not %s" % (meta.get("feature"), feature))
    snap = meta["snapshot"]
    entries = [l.rstrip("\n").split("\t") for l in open(os.path.join(state, "entries.tsv")) if l.strip()]

    # Pass 1 — parse every reply; write nothing on any failure.
    parsed = []
    for idx, name, kind, path, boundary in entries:
        reply = os.path.join(state, "reply-%s.md" % idx)
        try:
            text = open(reply, encoding="utf-8", errors="replace").read()
            result, more, blocks = parse_reply(text)
        except OSError:
            die("%s: no reply saved at %s" % (name, reply))
        except ParseError as e:
            die("%s: %s" % (name, e))
        parsed.append((idx, name, kind, boundary, result, more, blocks))

    # Pass 2 — validate, dedupe, write.
    added, dropped, not_checkable, capped = {}, 0, 0, []
    for idx, name, kind, boundary, result, more, blocks in parsed:
        if result == "not-checkable":
            not_checkable += 1
            continue
        if more:
            capped.append(name)
        ranges = load_ranges(os.path.join(state, "entry-%s.ranges" % idx))
        for f in blocks:
            v = validate(top, snap, kind, boundary, ranges, f)
            if v is None:
                dropped += 1
                continue
            rel, keep, quote, source = v
            digest = hashlib.sha1(norm(quote).encode("utf-8")).hexdigest()[:8]
            seed = next_seed("conventions:%s:%s:%s" % (name, rel, digest),
                             family(review_sh, feature, "conventions:%s:%s:%s" % (name, rel, digest)))
            if seed is None:
                continue
            details = "%s\n\nquote: \"%s\"\nsource: %s\nfile: %s:%s\n" % (
                f["details"], quote, os.path.relpath(source, top), rel, ",".join(map(str, keep)))
            subprocess.run([review_sh, "add", feature, f["severity"], f["scope"],
                            "%s: %s" % (name, f["summary"]),
                            "--source", "conventions-review", "--seed-id", seed],
                           input=details, text=True, check=True, stdout=subprocess.DEVNULL)
            added[name] = added.get(name, 0) + 1

    total = sum(added.values())
    line = "conventions review: %d findings added" % total
    if total:
        line += " (%s)" % ", ".join("%s: %d" % (n, c) for n, c in added.items())
    line += ", %d dropped, %d entries not checkable" % (dropped, not_checkable)
    if capped:
        line += " — %s hit the 10-finding cap; run /mi-conventions-review again after fixing" % ", ".join(capped)
    print(line)
```

`review.sh add` stores the piped details indented under `- details: |` (checked: `    file: src/a.ts:3`), so the tests' unanchored greps match inside the block. Do not change `review.sh`.

- [ ] **Step 4: Run the suite; all Task 1–3 tests pass**

Run: `env -u CLAUDE_PLUGIN_ROOT bash tests/conventions-review/run.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/internal/conventions_review.py tests/conventions-review/run.sh
git commit -m "feat(conventions-review): ingest — validate, dedupe by seed-id, write findings (CVR-004)"
```

---

### Task 4: Reviewer agent `agents/conventions-reviewer.md` (CVR-002)

**Files:**
- Create: `agents/conventions-reviewer.md`
- Modify: `tests/conventions-review/run.sh`

**Interfaces:**
- Consumes: spawn inputs listed below (built by Task 5's command).
- Produces: subagent type `millwright-inspector-development-machine:conventions-reviewer`; final reply in the return contract parsed by Task 3.

- [ ] **Step 1: Append the failing static test**

```bash
# ---- Task 4: reviewer agent -----------------------------------------------------

AG="$REPO_ROOT/agents/conventions-reviewer.md"
t="agent: frontmatter is exactly model sonnet, effort high, tools [Read, Grep]"
fm="$(sed -n '2,/^---$/p' "$AG" 2>/dev/null)"
if grep -qx 'model: sonnet' <<<"$fm" && grep -qx 'effort: high' <<<"$fm" \
   && grep -qx 'tools: \[Read, Grep\]' <<<"$fm" && grep -qx 'name: conventions-reviewer' <<<"$fm"; then ok "$t"
else ng "$t" "frontmatter: $fm"; fi

t="agent: body states the return contract and the 10-finding cap"
if grep -qF 'Result: findings | clean | not-checkable' "$AG" && grep -qF 'More: yes | no' "$AG" \
   && grep -qF 'At most 10 findings' "$AG"; then ok "$t"; else ng "$t" "contract text missing"; fi
```

- [ ] **Step 2: Run to verify it fails** — `env -u CLAUDE_PLUGIN_ROOT bash tests/conventions-review/run.sh`; expected FAIL (file missing).

- [ ] **Step 3: Write the agent**

`agents/conventions-reviewer.md`:

````markdown
---
name: conventions-reviewer
description: Read-only conventions reviewer. Spawned by /mi-conventions-review (and /mi-continue Resume Step 6.5 through it), one per skill or rule. Checks the feature's changed lines against that one entry and returns findings that each quote the exact sentence broken. Never edits anything.
model: sonnet
effort: high
tools: [Read, Grep]
---

You are a fresh sub-agent spawned by `/mi-conventions-review`. You review the
code one feature changed against **one** skill or rule and report where the
changed code breaks it. You can only read; you change nothing.

## Inputs (in your spawn prompt)

- the feature name;
- the snapshot folder — the changed files exactly as committed at the review head;
- the ranges file — `path<TAB>start-end` rows: the only lines you may report on;
- the entry: name, kind (`skill` or `rule`), absolute path, and source boundary
  (a skill's folder, or the rule file itself);
- the `decisions.md` path, when the feature has one;
- the return contract (below).

## Rules

1. Read the entry file, and the files it links to that bear on the changed code.
   Quote only sentences from files inside the source boundary. When a requirement
   comes from a linked file outside the boundary, quote the entry's sentence that
   points to it, and put the linked path and its sentence in `details`.
2. Read the changed files from the snapshot folder only, and cite paths relative
   to it (they equal repo-relative paths). You may read other project files for
   context; never cite them.
3. Report only lines inside the ranges file. A range around a deletion stands for
   the code that was removed.
4. If `decisions.md` records a decision that explicitly allows what the code does,
   do not report it.
5. One finding per quoted sentence per file; list every offending line in it.
6. At most 10 findings, most important first. If there were more, say `More: yes`.

Severity is `minor` or `major` (never `blocker`). Scope is `fix` for a local patch
or `re-implement` when the fix restructures the changed code.

Use `not-checkable` only when the entry has no requirement that can be checked
from code (for example a rule about how Claude works, such as "fetch docs through
Context7"); give one line of reason and no findings. A mixed entry is checked
against its code-checkable requirements.

## Return contract

Your whole final reply is exactly this shape. It is deliberately **not** the
standard sub-agent return shape — main parses these fields and drops any finding
that does not match them.

```
Entry: <name> (<skill|rule>)
Result: findings | clean | not-checkable
More: yes | no

### F-1
- file: <snapshot-relative path>:<line>[,<line>...]
- severity: minor | major
- scope: fix | re-implement
- quote: "<exact sentence from the entry file or a file inside its boundary>"
- source: <path of the file the quote is from>
- summary: <one line>
- details: |
    what the code does, what the skill or rule asks for, the suggested change
```

Copy the quote exactly — main checks it against `source` and drops a finding
whose quote is not there.
````

- [ ] **Step 4: Run the suite; Task 4 tests pass.**

- [ ] **Step 5: Commit**

```bash
git add agents/conventions-reviewer.md tests/conventions-review/run.sh
git commit -m "feat(agents): read-only conventions-reviewer sub-agent (CVR-002)"
```

---

### Task 5: Command `commands/mi-conventions-review.md` + lint and doc wiring (CVR-003 prose, CVR-006 part)

**Files:**
- Create: `commands/mi-conventions-review.md`
- Modify: `tests/lint/run.sh` (`DELEGATING_COMMANDS`, line ~104)
- Modify: `docs/millwright-inspector-project.md` (agent table; `commits.sh` subcommand row)
- Modify: `tests/conventions-review/run.sh`

**Interfaces:**
- Consumes: `conventions-review.sh prepare|ingest` (Tasks 2–3); agent type from Task 4.
- Produces: `/mi-conventions-review` whose final output line is either a fixed message, the report line, or `conventions review: failed — <error>`. Task 6 relies on that last line.

- [ ] **Step 1: Append the failing block-extraction test**

```bash
# ---- Task 5: command prose blocks -----------------------------------------------

CMD="$REPO_ROOT/commands/mi-conventions-review.md"
# extract_blocks <md> <dir> — writes each ```bash block to <dir>/block-N.sh.
extract_blocks() {
  python3 - "$1" "$2" <<'PYEOF'
import re, sys, os
text = open(sys.argv[1]).read()
for i, b in enumerate(re.findall(r'```bash\n(.*?)```', text, re.DOTALL), 1):
    open(os.path.join(sys.argv[2], 'block-%d.sh' % i), 'w').write(b)
PYEOF
}

t="command: every bash block recovers active_feature itself (L-001)"
sb="$(prep_sandbox)"
bd="$(mktemp -d)"; SANDBOXES+=("$bd"); extract_blocks "$CMD" "$bd"
bad=""
for b in "$bd"/block-*.sh; do
  grep -q 'progress.sh" get-active' "$b" || bad+=" $(basename "$b")"
done
[[ -z "$bad" && -e "$bd/block-1.sh" ]] && ok "$t" || ng "$t" "blocks without get-active:$bad"

t="command: prepare block runs with active_feature unset"
got="$(cd "$sb" && env -u active_feature CLAUDE_PLUGIN_ROOT="$REPO_ROOT" MI_DATA_ROOT="$sb/millwright-inspector" bash "$bd/block-1.sh" 2>&1)"
grep -q 'conventions review: nothing to check' <<<"$got" && grep -q '^model: sonnet$' <<<"$got" \
  && ok "$t" || ng "$t" "got: $got"

t="command: every block fails cleanly with no active feature"
run_in "$sb" "$P" set "current-stage=5" >/dev/null 2>&1
python3 - "$sb/millwright-inspector/quest/2026-10-05-demo/progress.md" <<'PYEOF'
import re, sys
p = sys.argv[1]; s = open(p).read()
s = re.sub(r'(?ms)^active:\n(?:  .*\n)+', 'active: null\n', s, count=1)
open(p, 'w').write(s)
PYEOF
bad=""
for b in "$bd"/block-*.sh; do
  got="$(cd "$sb" && env -u active_feature CLAUDE_PLUGIN_ROOT="$REPO_ROOT" MI_DATA_ROOT="$sb/millwright-inspector" bash "$b" 2>&1)"; rc=$?
  { [[ $rc -ne 0 ]] && grep -q 'conventions review: failed — no active feature' <<<"$got"; } || bad+=" $(basename "$b")"
done
[[ -z "$bad" ]] && ok "$t" || ng "$t" "blocks:$bad"

t="command: delegation contract names conventions-reviewer and the lint registers it"
grep -q '^\*\*Delegation contract.\*\*.*conventions-reviewer' "$CMD" \
  && grep -q 'mi-conventions-review' "$REPO_ROOT/tests/lint/run.sh" && ok "$t" || ng "$t" "missing"
```

(If the `active: null` rewrite does not match the real `progress.md` layout, open a sandbox `progress.md` and adjust the regex — the goal is `progress.sh get-active` printing `null`.)

- [ ] **Step 2: Run to verify the new tests fail.**

- [ ] **Step 3: Write the command**

`commands/mi-conventions-review.md`:

````markdown
---
description: Check the active feature's changed code against its review-tagged skills and path-matched rules — one read-only conventions-reviewer per entry — and add validated findings to inspector-review.md (source conventions-review). Auto-run by /mi-continue Resume Step 6.5; run it by hand at stage 5 or 6.
---

# mi-conventions-review

**Delegation contract.** This command REQUIRES the sub-agents listed below; §8.13's main-read budget forbids main from doing their work itself. **Invoking `/mi-conventions-review` (directly, or through `/mi-continue` Resume Step 6.5) IS the user requesting them** — Claude Code's default "do not call the Agent tool unless the user requested it" (and any stricter house rule layered on it) does not reach a sub-agent this command names at the step that names it, so spawn them without asking for extra confirmation. The default still holds everywhere else: never spawn a sub-agent this command does not name, and never invent fan-out beyond the waves below. If a named delegation genuinely cannot run (type unavailable, harness refusal), say so and stop — never silently do its work in main. Sub-agents: `conventions-reviewer` (Step 2 — one per skill or rule entry, at most 3 per wave). Canonical rule: `docs/millwright-inspector-project.md` §8.15.

**Runtime bootstrap.** Resolve `$CLAUDE_PLUGIN_ROOT` per `docs/millwright-inspector-project.md` §8.14 (reference implementation: `mi-continue.md` Step 1a) before running any Bash block.

No arguments. Runs at stage 3 inside `/mi-continue`'s Resume Handler (`sub-flow=resuming`), or at stage 5 or 6. Main never reads the diff, `config.md`, or a rule body — `scripts/conventions-review.sh` selects entries and validates findings.

## Step 1 — Prepare

```bash
active_feature="$("$CLAUDE_PLUGIN_ROOT/scripts/progress.sh" get-active 2>/dev/null || true)"
if [[ -z "$active_feature" || "$active_feature" == "null" ]]; then
  echo "conventions review: failed — no active feature" >&2
  exit 1
fi
"$CLAUDE_PLUGIN_ROOT/scripts/conventions-review.sh" prepare "$active_feature"
echo "model: ${MI_CONVENTIONS_REVIEW_MODEL:-sonnet}"
```

- Exit non-zero → print `conventions review: failed — <its stderr line>` and stop.
- `conventions review: nothing to check` or the feature-test line → relay it and stop. Both are success.
- Otherwise relay the `conventions review: N reviewers (…)` line and keep the printed `state:` directory and `model:` value for Step 2.

## Step 2 — Spawn reviewers

Read `<state>/entries.tsv` (`idx`, `name`, `kind`, `abs-path`, `boundary`). For each row spawn `subagent_type: millwright-inspector-development-machine:conventions-reviewer` with the Agent `model` parameter set to the printed `model:` value. Send **at most 3 spawns per message** (one wave); start the next wave when the previous one has returned. Spawn prompt:

```
Review the "<active_feature>" feature's changed code against one <kind>.

Entry:           <name> (<kind>)
Entry file:      <abs-path>
Source boundary: <boundary>
Snapshot folder: <snapshot — the state path without the trailing ".state">
Ranges file:     <state>/entry-<idx>.ranges
Decisions:       <data root>/workflow-stream/<active_feature>/decisions.md   (omit this line when the file does not exist)

Follow agents/conventions-reviewer.md: report only inside the ranges, quote the
exact sentence broken, at most 10 findings. Your whole final reply is the return
contract — Entry / Result / More, then ### F-n blocks.
```

As each reviewer returns, save its final reply **verbatim** with the Write tool to `<state>/reply-<idx>.md`. Do not summarize, reformat or judge it — `ingest` validates.

If a spawn errors, or the agent type is unavailable, print `conventions review: failed — <error>` and stop. Nothing has been written; the next run starts over.

## Step 3 — Ingest

```bash
active_feature="$("$CLAUDE_PLUGIN_ROOT/scripts/progress.sh" get-active 2>/dev/null || true)"
if [[ -z "$active_feature" || "$active_feature" == "null" ]]; then
  echo "conventions review: failed — no active feature" >&2
  exit 1
fi
"$CLAUDE_PLUGIN_ROOT/scripts/conventions-review.sh" ingest "$active_feature"
```

- Exit non-zero → print `conventions review: failed — <its stderr line>` and stop. No finding was written; the run folder is kept for inspection and the next run clears it.
- Exit 0 → relay the last stdout line (the report line) as this command's final line.
````

- [ ] **Step 4: Register the command in the lint suite and the project doc**

In `tests/lint/run.sh`, add `mi-conventions-review` to the `DELEGATING_COMMANDS=(` array (keep its existing ordering style). In `docs/millwright-inspector-project.md`: add a `conventions-reviewer` row to the agent table (model `sonnet`, effort `high`, spawned by `/mi-conventions-review`), and add `changed-lines` to the `commits.sh` subcommand row. Find both with `grep -n 'lessons-filter\|changed-files' docs/millwright-inspector-project.md`.

- [ ] **Step 5: Run the suites**

Run: `env -u CLAUDE_PLUGIN_ROOT bash tests/conventions-review/run.sh && env -u CLAUDE_PLUGIN_ROOT bash tests/lint/run.sh`
Expected: both PASS.

- [ ] **Step 6: Commit**

```bash
git add commands/mi-conventions-review.md tests/lint/run.sh docs/millwright-inspector-project.md tests/conventions-review/run.sh
git commit -m "feat(commands): /mi-conventions-review driver + lint and doc wiring (CVR-003, CVR-006)"
```

---

### Task 6: `/mi-continue` Resume Step 6.5 and the stage-5 report line (CVR-005)

**Files:**
- Modify: `commands/mi-continue.md` (Delegation contract line 9; new section between `### Resume Step 6` and `### Resume Step 7` near line 1335; Step 7 report text)
- Modify: `tests/conventions-review/run.sh`

**Interfaces:**
- Consumes: `/mi-conventions-review` final line (Task 5).
- Produces: nothing new for later tasks.

- [ ] **Step 1: Append the failing tests**

```bash
# ---- Task 6: mi-continue Resume Step 6.5 ---------------------------------------

MC="$REPO_ROOT/commands/mi-continue.md"
t="mi-continue: Resume Step 6.5 sits between Step 6 and Step 7"
python3 - "$MC" <<'PYEOF' && ok "$t" || ng "$t" "order wrong or step missing"
import sys
s = open(sys.argv[1]).read()
a, b, c = s.find('### Resume Step 6 '), s.find('### Resume Step 6.5'), s.find('### Resume Step 7')
sys.exit(0 if -1 < a < b < c else 1)
PYEOF

t="mi-continue: Step 6.5 runs /mi-conventions-review and stops before Step 7 on failure"
sec="$(sed -n '/^### Resume Step 6.5/,/^### Resume Step 7/p' "$MC")"
grep -qF '/mi-conventions-review' <<<"$sec" && grep -qF 'conventions review: failed —' <<<"$sec" \
  && grep -qi 'stop' <<<"$sec" && ok "$t" || ng "$t" "section: $sec"

t="mi-continue: Step 7 prints the conventions report line before the hand-off"
sec7="$(sed -n '/^### Resume Step 7/,/^\*\*When `skipped=false`/p' "$MC")"
grep -qF 'conventions review:' <<<"$sec7" && ok "$t" || ng "$t" "no report line in Step 7"

t="mi-continue: delegation contract lists conventions-reviewer"
sed -n '9p' "$MC" | grep -qF 'conventions-reviewer' && ok "$t" || ng "$t" "line 9 lacks it"
```

- [ ] **Step 2: Run to verify they fail.**

- [ ] **Step 3: Edit `commands/mi-continue.md`**

(a) In the Delegation contract (line 9), after `` `review-iteration-runner` (via `/mi-review`)`` add: `` and `conventions-reviewer` (via `/mi-conventions-review`, Resume Step 6.5)`` — keep the sentence grammatical (adjust the existing "and" before `review-iteration-runner` to a comma).

(b) Insert before `### Resume Step 7`:

```markdown
### Resume Step 6.5 — Conventions review

Run `/mi-conventions-review` now, in every mode (auto mode on or off), with no prompt. It is a prose command: follow it to completion in this turn, including its reviewer spawns.

- If its last line is `conventions review: failed — <error>`, print that line and **stop**. Do not run Step 7: the feature stays at stage 3, and the next `/mi-continue` re-runs this handler (Step 5 diagrams are freshness-cached, Step 6 is idempotent, findings already written are skipped by seed-id).
- Otherwise keep its last line — `conventions review: nothing to check`, the report line, or the feature-test line — for Step 7.

Diagrams rendered at Step 5 are not re-rendered here; stage 6's Review-Resume diagram refresh covers fixes made later.
```

(c) In Step 7, directly after the skills-report paragraph `(The block recomputes … does not move their auto-answer lines.)`, add:

```markdown
**Conventions report.** Print the line kept at Resume Step 6.5 (for example `conventions review: 2 findings added (react-forms: 2), 0 dropped, 0 entries not checkable`) right after the skills line, outside the blockquotes below. It never moves their auto-answer lines.
```

- [ ] **Step 4: Run the suites**

Run: `env -u CLAUDE_PLUGIN_ROOT bash tests/conventions-review/run.sh && env -u CLAUDE_PLUGIN_ROOT bash tests/lint/run.sh && env -u CLAUDE_PLUGIN_ROOT bash tests/auto-mode/run.sh`
Expected: all PASS. If an auto-mode fixture compares Step 7 text verbatim, the new paragraph must sit outside the fixture's quoted span — move the paragraph, never edit the fixture.

- [ ] **Step 5: Commit**

```bash
git add commands/mi-continue.md tests/conventions-review/run.sh
git commit -m "feat(mi-continue): Resume Step 6.5 runs the conventions review before stage 5 (CVR-005)"
```

---

### Task 7: Fixers' contradicting-findings rule + template source (CVR-007, CVR-006 rest)

**Files:**
- Modify: `agents/review-iteration-runner.md:17`
- Modify: `commands/mi-review.md` (Step 3a.2.4 spawn prompt near line 362; Step 3b item 4 near line 503)
- Modify: `templates/inspector-review.md.tmpl:27-37`
- Modify: `tests/conventions-review/run.sh`

- [ ] **Step 1: Append the failing tests**

```bash
# ---- Task 7: fixer rule + template ----------------------------------------------

RULE='If two open findings ask for opposite things, fix neither. Leave both `open` and name them as `Needs inspector: IR-x vs IR-y — <one line>`.'
t="fixer rule: present in the runner, the 3a.2.4 spawn prompt and Step 3b"
n_runner="$(grep -cF "$RULE" "$REPO_ROOT/agents/review-iteration-runner.md")"
n_review="$(grep -cF "$RULE" "$REPO_ROOT/commands/mi-review.md")"
[[ "$n_runner" -ge 1 && "$n_review" -ge 2 ]] && ok "$t" || ng "$t" "runner=$n_runner mi-review=$n_review"

t="template: conventions-review source and seed-id documented"
TM="$REPO_ROOT/templates/inspector-review.md.tmpl"
grep -qF 'conventions-review' "$TM" && grep -qF 'conventions:<entry>:<file>:<sha8>[:r<N>]' "$TM" \
  && ok "$t" || ng "$t" "missing"

t="fixer rule: approve-guard refuses while a contradicting pair is open"
sb="$(make_sandbox)"
run_in "$sb" "$R" init feat >/dev/null 2>&1
printf 'a\n' | run_in "$sb" "$R" add feat minor fix "use named exports" >/dev/null 2>&1
printf 'b\n' | run_in "$sb" "$R" add feat minor fix "use default exports" >/dev/null 2>&1
if run_in "$sb" "$REPO_ROOT/scripts/auto.sh" approve-guard feat >/dev/null 2>&1; then ng "$t" "guard passed"; else ok "$t"; fi
```

- [ ] **Step 2: Run to verify the first two fail** (the approve-guard test already passes — it pins existing behaviour the rule relies on).

- [ ] **Step 3: Add the rule**

The rule text, verbatim (`$RULE` above):

> If two open findings ask for opposite things, fix neither. Leave both `open` and name them as `Needs inspector: IR-x vs IR-y — <one line>`.

- `agents/review-iteration-runner.md`: new bullet right after the `- One-iteration discipline: …` bullet: `- Contradicting findings: <rule> Put the line under \`Findings / risks\` in your return.` — the rule sentence verbatim inside it.
- `commands/mi-review.md` Step 3a.2.4: in the runner spawn-prompt template, next to its one-iteration instruction, add the rule sentence verbatim followed by `Put that line under Findings / risks.`
- `commands/mi-review.md` Step 3b: new item after item 4 (`**One-iteration discipline:** …`): `**Contradicting findings:** <rule> Say it in your end-of-iteration summary.` Renumber following items if they are numbered.

- [ ] **Step 4: Template**

In `templates/inspector-review.md.tmpl`, after the `manual-test` `seed-id:` lines (27–30), add:

```
- source:   conventions-review    ← set by /mi-conventions-review on the findings it adds
- seed-id:  conventions:<entry>:<file>:<sha8>[:r<N>]
                                  ← paired with source: conventions-review; lets re-runs skip
                                    findings already open or wontfix
```

and reword line 37's "are auto-emitted by `/mi-manual-test-run` and read by `/mi-manual-test-run --seed-only`" to: "are auto-emitted by `/mi-manual-test-run` (`manual-test`) and `/mi-conventions-review` (`conventions-review`), and read by the same command on re-runs for idempotent seeding; never edit them by hand." Frontmatter and skeleton body unchanged.

- [ ] **Step 5: Run** `env -u CLAUDE_PLUGIN_ROOT bash tests/conventions-review/run.sh && env -u CLAUDE_PLUGIN_ROOT bash tests/lint/run.sh` — PASS.

- [ ] **Step 6: Commit**

```bash
git add agents/review-iteration-runner.md commands/mi-review.md templates/inspector-review.md.tmpl tests/conventions-review/run.sh
git commit -m "feat(review): contradicting-findings rule for fixers; document conventions-review source (CVR-007, CVR-006)"
```

---

### Task 8: Release 1.12.0 (CVR-009)

**Files:**
- Modify: `.claude-plugin/plugin.json`, `CHANGELOG.md`
- Modify: `tests/conventions-review/run.sh`

- [ ] **Step 1: Append the failing test**

```bash
# ---- Task 8: release -------------------------------------------------------------

t="release: plugin.json is 1.12.0 and the changelog leads with it"
v="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$REPO_ROOT/.claude-plugin/plugin.json")"
top="$(grep -m1 '^## ' "$REPO_ROOT/CHANGELOG.md")"
[[ "$v" == "1.12.0" && "$top" == *"1.12.0"* ]] && ok "$t" || ng "$t" "version=$v top=$top"
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Bump and write the entry**

Set `"version": "1.12.0"` in `.claude-plugin/plugin.json`. Add a `CHANGELOG.md` entry at the top, matching the 1.11.0 entry's heading format (`grep -n '^## ' CHANGELOG.md | head -2`), titled "Conventions review after implementation", covering: the `conventions-reviewer` agent (Sonnet / high effort, override with `MI_CONVENTIONS_REVIEW_MODEL`); `/mi-conventions-review`; `/mi-continue` Resume Step 6.5 and the stage-5 report line; `commits.sh changed-lines`; `scripts/conventions-review.sh`; the `conventions-review` finding source; the fixers' contradicting-findings rule; and the note "Features already in flight when you upgrade run Step 6.5 at their next stage 3 → 5 transition."

Then run `grep -rn '1\.11\.0' --include='*.json' --include='*.md' --include='*.sh' . | grep -v CHANGELOG.md | grep -v docs/superpowers | grep -v millwright-inspector/` and confirm no remaining hit names 1.11.0 as the **current** version (historical "added in 1.11.0" mentions stay).

- [ ] **Step 4: Run all suites**

Run: `for s in conventions-review lint auto-mode skills; do env -u CLAUDE_PLUGIN_ROOT bash tests/$s/run.sh >/dev/null 2>&1 && echo "$s ok" || echo "$s FAIL"; done`
Expected: four `ok`.

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin/plugin.json CHANGELOG.md tests/conventions-review/run.sh
git commit -m "chore(release): 1.12.0 — conventions review after implementation (CVR-009)"
```

---

### Task 9: Live reviewer fixture checks (CVR-008 manual part — controller runs this)

Not a sub-agent implementation task: the controller runs it after Task 8, because it spawns real reviewers. The installed plugin (1.10.0) does not have the `conventions-reviewer` type, so spawn a `general-purpose` agent with `model: sonnet`, pasting `agents/conventions-reviewer.md`'s body as its instructions plus the Task 5 spawn prompt.

- [ ] **Step 1:** In a scratch sandbox (as `ingest_sandbox` builds), add a skill saying "Validate input with zod." and a changed `src/api/order.ts` route that skips validation; run `prepare`, spawn, save the reply, run `ingest`. Expected: one finding citing the exact line with the exact quote.
- [ ] **Step 2:** Same with a second skill the code follows → `Result: clean`.
- [ ] **Step 3:** Add a `decisions.md` bullet allowing the pattern → no finding.
- [ ] **Step 4:** A rule "Fetch library docs through Context7." → `not-checkable`.
- [ ] **Step 5:** Record results in the end-of-session report. Spawn-failure recovery, the mi-sample end-to-end run and the Sonnet-vs-Opus check need 1.12.0 installed; record them as a deferred question (`deferred-questions.sh add`) instead of installing mid-cycle.
