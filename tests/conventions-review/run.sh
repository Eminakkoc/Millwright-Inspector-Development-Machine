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
