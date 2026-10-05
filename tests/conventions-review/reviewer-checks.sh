#!/usr/bin/env bash
# reviewer-checks.sh — opt-in CVR-008 reviewer-judgement checks. Not part of
# run.sh: each case spawns the real conventions-reviewer through `claude -p`,
# which costs tokens and needs a logged-in claude CLI.
#
# For each case under fixtures/ (see fixtures/README.md): build a sandbox repo,
# run `conventions-review.sh prepare`, run the reviewer headless per entry with
# the same spawn prompt /mi-conventions-review uses, save the reply as
# reply-<idx>.md, run `ingest`, and assert loosely on the outcome.
#
# Usage: tests/conventions-review/reviewer-checks.sh [case...]
#   MI_CONVENTIONS_REVIEW_MODEL  reviewer model (default sonnet)
#   KEEP=1                       keep the sandboxes and print their paths
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$REPO_ROOT/tests/conventions-review/fixtures"
P="$REPO_ROOT/scripts/progress.sh"
CR="$REPO_ROOT/scripts/conventions-review.sh"
AGENT="$REPO_ROOT/agents/conventions-reviewer.md"
MODEL="${MI_CONVENTIONS_REVIEW_MODEL:-sonnet}"
UUID1="11111111-1111-4111-8111-111111111111"
UUID2="22222222-2222-4222-8222-222222222222"

command -v claude >/dev/null || { echo "error: claude CLI not on PATH" >&2; exit 2; }

pass=0
fail=0
fail_names=()
ok() { printf "\xe2\x9c\x93 %s\n" "$1"; pass=$((pass + 1)); }
ng() { printf "\xe2\x9c\x97 %s\n   %s\n" "$1" "$2" >&2; fail=$((fail + 1)); fail_names+=("$1"); }

SANDBOXES=()
cleanup() {
  local s
  if [[ "${KEEP:-}" == 1 ]]; then
    for s in ${SANDBOXES[@]+"${SANDBOXES[@]}"}; do echo "kept: $s"; done
    return
  fi
  for s in ${SANDBOXES[@]+"${SANDBOXES[@]}"}; do
    [[ -n "$s" && -d "$s" ]] && rm -rf "$s"
  done
}
trap cleanup EXIT

run_in() {
  local sb="$1"; shift
  (cd "$sb" && env -u CLAUDE_PLUGIN_ROOT MI_DATA_ROOT="$sb/millwright-inspector" "$@")
}

commit_all() {
  (cd "$1" && git add -A -- . ':(exclude)millwright-inspector' && git commit -qm "$2")
}

# case_sandbox <case> — repo whose base commit holds fixtures/<case>/base and
# whose feature commit holds fixtures/<case>/change; feature "feat" active at
# stage 5, review-tagged skills listed in config.md, decisions.md copied.
# Sets SB (not printed: a $(...) subshell would lose the SANDBOXES entry).
case_sandbox() {
  local c="$FIX/$1" sb dr slug cur skills="" s
  sb="$(cd "$(mktemp -d)" && pwd -P)"
  SANDBOXES+=("$sb")
  dr="$sb/millwright-inspector"
  slug="2026-10-05-demo"
  cur="$dr/workflow-stream/feat/blueprints/current"
  mkdir -p "$dr/quest/$slug" "$cur"
  printf -- '---\nslug: %s\nstarted: "2026-10-05"\njournal-folders: [demo]\nstatus: active\n---\n\n# Active quest pointer\n' \
    "$slug" > "$dr/quest/active.md"
  printf -- '---\nid: %s\n---\n\n# Requirements\n' "$UUID2" > "$cur/requirements.md"
  cp -R "$c/base/." "$sb/"
  (cd "$sb" && git init -q -b main && git config user.email t@t && git config user.name t) >/dev/null
  commit_all "$sb" base
  run_in "$sb" "$P" init "$UUID1" feat >/dev/null 2>&1
  run_in "$sb" "$P" activate >/dev/null 2>&1
  run_in "$sb" "$P" set "current-stage=5" "sub-flow=none" \
    "base-commit=$(cd "$sb" && git rev-parse HEAD)" >/dev/null 2>&1
  cp -R "$c/change/." "$sb/"
  commit_all "$sb" feature-work
  for s in "$sb"/.claude/skills/*/; do
    [[ -d "$s" ]] || continue
    s="$(basename "$s")"
    skills+="- $s — $s"$'\n'"  stages: review; skill: $s; path: .claude/skills/$s/SKILL.md"$'\n'
  done
  printf -- '---\nid: %s\nrequirements-id: %s\n---\n\n<!-- auto:start -->\n\n## Skills\n\n%s\n## Load on demand\n\n<!-- auto:end -->\n' \
    "33333333-3333-4333-8333-333333333333" "$UUID2" "$skills" > "$cur/config.md"
  [[ -f "$c/decisions.md" ]] && cp "$c/decisions.md" "$dr/workflow-stream/feat/decisions.md"
  run_in "$sb" "$REPO_ROOT/scripts/review.sh" init feat >/dev/null 2>&1
  SB="$sb"
}

# review_case <case> — prepare, one headless reviewer per entry, ingest.
# Prints the ingest report line; leaves the replies in $sb/replies/.
review_case() {
  local sb="$1" out state snap idx name kind path boundary decisions="" prompt
  out="$(run_in "$sb" "$CR" prepare feat 2>&1)" || { echo "prepare failed: $out"; return 1; }
  state="$(sed -n 's/^state: //p' <<<"$out")"
  [[ -n "$state" ]] || { echo "prepare printed no state: $out"; return 1; }
  snap="${state%.state}"
  [[ -f "$sb/millwright-inspector/workflow-stream/feat/decisions.md" ]] \
    && decisions="Decisions:       $sb/millwright-inspector/workflow-stream/feat/decisions.md"
  mkdir -p "$sb/replies"
  while IFS=$'\t' read -r idx name kind path boundary; do
    prompt="Review the \"feat\" feature's changed code against one $kind.

Entry:           $name ($kind)
Entry file:      $path
Source boundary: $boundary
Snapshot folder: $snap
Ranges file:     $state/entry-$idx.ranges
$decisions

Follow agents/conventions-reviewer.md: report only inside the ranges, quote the
exact sentence broken, at most 10 findings. Your whole final reply is the return
contract — Entry / Result / More, then ### F-n blocks."
    (cd "$sb" && claude -p --safe-mode --output-format text \
       --append-system-prompt "$(awk 'n >= 2 { print } /^---$/ { n++ }' "$AGENT")" \
       --tools "Read,Grep" --allowedTools "Read Grep" --permission-mode dontAsk \
       --model "$MODEL" --effort high <<<"$prompt" > "$state/reply-$idx.md" 2>"$state/claude-$idx.err") \
      || { echo "claude -p failed for $name: $(tail -3 "$state/claude-$idx.err")"; return 1; }
    cp "$state/reply-$idx.md" "$sb/replies/$name.md"
  done < "$state/entries.tsv"
  run_in "$sb" "$CR" ingest feat 2>&1 | tail -1
}

review_md() { printf '%s' "$1/millwright-inspector/workflow-stream/feat/implementation/inspector-review.md"; }

cases=("$@")
[[ ${#cases[@]} -gt 0 ]] || cases=(violation clean decision not-checkable)

for c in "${cases[@]}"; do
  [[ -d "$FIX/$c" ]] || { ng "$c" "no fixture at $FIX/$c"; continue; }
  case_sandbox "$c"; sb="$SB"
  got="$(review_case "$sb")"
  rm="$(review_md "$sb")"
  case "$c" in
    violation)
      t="violation: 1 finding at src/x.js:2 quoting the skill sentence"
      if [[ "$got" == "conventions review: 1 findings added (no-var: 1),"* ]] \
         && grep -q 'file: src/x.js:2$' "$rm" \
         && grep -qF 'quote: "Never declare variables with var."' "$rm"; then ok "$t"
      else ng "$t" "report: $got"; fi
      ;;
    clean)
      t="clean: Result: clean, no findings"
      if grep -q '^Result: clean' "$sb/replies/semi.md" \
         && [[ "$got" == "conventions review: 0 findings added,"* ]]; then ok "$t"
      else ng "$t" "report: $got | reply: $(head -3 "$sb/replies/semi.md" | tr '\n' ' ')"; fi
      ;;
    decision)
      t="decision: a recorded decision suppresses the line-2 finding"
      if [[ "$got" == "conventions review: "*" findings added"* ]] \
         && ! grep -qE '^- file: src/x\.js:([0-9]+,)*2(,|$)' "$sb/replies/no-var.md" \
         && ! grep -qE 'file: src/x\.js:([0-9]+,)*2(,[0-9]+)*$' "$rm"; then ok "$t"
      else ng "$t" "report: $got"; fi
      ;;
    not-checkable)
      t="not-checkable: a Context7-style rule counts as not checkable"
      if [[ "$got" == *", 1 entries not checkable"* ]]; then ok "$t"
      else ng "$t" "report: $got"; fi
      ;;
    *) ng "$c" "no assertion for this case" ;;
  esac
done

echo
echo "reviewer-checks: $pass passed, $fail failed"
if (( fail > 0 )); then
  printf '  - %s\n' "${fail_names[@]}" >&2
  exit 1
fi
