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

sb="$(ingest_sandbox)"; STYLE="$sb/.claude/rules/style.md"; FORMS="$sb/.claude/skills/forms/SKILL.md"
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
exp="conventions review: 3 findings added (forms: 2, style: 1), 9 dropped, 0 entries not checkable — forms hit the 10-finding cap; run /mi-conventions-review again after fixing"
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
sb="$(ingest_sandbox)"; STYLE="$sb/.claude/rules/style.md"; FORMS="$sb/.claude/skills/forms/SKILL.md"
out="$(run_in "$sb" "$CR" prepare feat 2>&1)"; state="$(state_of "$out")"
si="$(idx_of "$state" style)"; fi_="$(idx_of "$state" forms)"
reply "$state/reply-$si.md" "style (rule)" findings no \
  "$(blk 'src/a.ts:3' minor fix '"See ref.md for more."' "$STYLE" 'pointer sentence')"
reply "$state/reply-$fi_.md" "forms (skill)" findings no \
  "$(blk 'src/a.ts:3' minor fix '"Validate input with zod."' "$FORMS" 'same line')"
got="$(run_in "$sb" "$CR" ingest feat 2>&1 | tail -1)"
[[ "$got" == "conventions review: 2 findings added (forms: 1, style: 1), 0 dropped, 0 entries not checkable" ]] \
  && ok "$t" || ng "$t" "got: $got"

t="ingest: a missing or unparseable reply fails and writes nothing"
sb="$(ingest_sandbox)"; STYLE="$sb/.claude/rules/style.md"; FORMS="$sb/.claude/skills/forms/SKILL.md"
out="$(run_in "$sb" "$CR" prepare feat 2>&1)"; state="$(state_of "$out")"
si="$(idx_of "$state" style)"; fi_="$(idx_of "$state" forms)"
reply "$state/reply-$si.md" "style (rule)" findings no \
  "$(blk 'src/a.ts:3' minor fix '"See ref.md for more."' "$STYLE" 'would be added')"
printf 'Sorry, I could not do this.\n' > "$state/reply-$fi_.md"
RMD="$sb/millwright-inspector/workflow-stream/feat/implementation/inspector-review.md"
if run_in "$sb" "$CR" ingest feat >/dev/null 2>&1; then ng "$t" "exited 0"
elif grep -q '^### IR-[0-9]' "$RMD"; then ng "$t" "a finding was written"
elif [[ ! -d "$state" ]]; then ng "$t" "run folder deleted on failure"
else ok "$t"; fi

t="ingest: a not-checkable reply counts the entry"
reply "$state/reply-$fi_.md" "forms (skill)" not-checkable no
printf 'reason: about how Claude works\n' >> "$state/reply-$fi_.md"
got="$(run_in "$sb" "$CR" ingest feat 2>&1 | tail -1)"
[[ "$got" == "conventions review: 1 findings added (style: 1), 0 dropped, 1 entries not checkable" ]] \
  && ok "$t" || ng "$t" "got: $got"

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

# ---- summary -----------------------------------------------------------------
echo
echo "conventions-review: $pass passed, $fail failed"
if (( fail > 0 )); then
  printf '  - %s\n' "${fail_names[@]}" >&2
  exit 1
fi
