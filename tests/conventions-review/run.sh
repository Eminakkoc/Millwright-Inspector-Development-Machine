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

t="changed-lines: an added line starting with '++ ' is not mistaken for a file header"
sb3="$(make_sandbox)"
(cd "$sb3" && seq 1 10 > pp.txt) && commit_all "$sb3" pp
run_in "$sb3" "$P" set "base-commit=$(head_of "$sb3")" >/dev/null 2>&1
(cd "$sb3" && seq 1 10 | sed '2s/.*/++ x/' | sed '8s/.*/eight/' > pp.txt) && commit_all "$sb3" pp-change
got="$(run_in "$sb3" "$C" changed-lines feat "$(head_of "$sb3")")"
[[ "$got" == $'pp.txt\t2-2\npp.txt\t8-8' ]] && ok "$t" || ng "$t" "got: $got"

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

t="prepare: a failing changed-lines (bad base-commit) stops the step, not 'nothing to check'"
sbb="$(prep_sandbox)"
run_in "$sbb" "$P" set "base-commit=deadbeef" >/dev/null 2>&1
got="$(run_in "$sbb" "$CR" prepare feat 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$got" != *"nothing to check"* ]]; then ok "$t"; else ng "$t" "rc=$rc got: $got"; fi

# ---- summary -----------------------------------------------------------------
echo
echo "conventions-review: $pass passed, $fail failed"
if (( fail > 0 )); then
  printf '  - %s\n' "${fail_names[@]}" >&2
  exit 1
fi
