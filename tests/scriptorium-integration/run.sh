#!/usr/bin/env bash
# run.sh — tests for the scriptorium integration (INT-001..005):
#   - mi-run Step 2's scriptorium task.md detection fence (bash and zsh)
#   - folder-id.sh free-name, the scriptorium rename rule
#   - ingest.sh scriptorium/<topic> folder mode
#
# Each test prints ✓/✗; the suite exits 1 if any test failed.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

pass=0
fail=0

ok() { printf "\xe2\x9c\x93 %s\n" "$1"; pass=$((pass + 1)); }
ng() { printf "\xe2\x9c\x97 %s\n   %s\n" "$1" "$2" >&2; fail=$((fail + 1)); }

SANDBOXES=()
cleanup() {
  local s
  for s in ${SANDBOXES[@]+"${SANDBOXES[@]}"}; do
    [[ -n "$s" && -d "$s" ]] && rm -rf "$s"
  done
}
trap cleanup EXIT

# new_sandbox — an empty data root; pwd -P sidesteps macOS /var -> /private/var.
new_sandbox() {
  local s
  s="$(cd "$(mktemp -d)" && pwd -P)"
  SANDBOXES+=("$s")
  printf '%s' "$s"
}

# published <file> <heading>... — a task.md as /mi-scriptorium publishes it.
published() {
  local f="$1" h
  shift
  mkdir -p "$(dirname "$f")"
  {
    printf -- '---\nsource: scriptorium\ncontributors:\n  - emin\ndate: 2026-11-12\n---\n\n'
    printf '## Goal\n\nShip it.\n\n## Cross-cutting constraints\n\n## Out-of-scope\n\n'
    for h in "$@"; do
      printf '## Feature: %s\n\nBody of %s.\n\n' "$h" "$h"
    done
  } > "$f"
}

# ---- mi-run Step 2: scriptorium task.md detection -------------------------

fence="$(awk '/^\*\*Scriptorium `task.md` detection/{f=1} f&&/^```bash$/{c=1;next} c&&/^```$/{exit} c' \
  "$REPO_ROOT/commands/mi-run.md")"

t="mi-run: the detection fence exists"
if [[ -n "$fence" && "$fence" == *'<folder1> [<folder2> ...]'* ]]; then
  ok "$t"
else
  ng "$t" "no bash fence after **Scriptorium \`task.md\` detection.** in commands/mi-run.md"
fi

dr="$(new_sandbox)"
published "$dr/journal/payments/task.md" stripe-webhooks 'refunds  '
published "$dr/journal/payments/sub/task.md" nested-is-ignored
published "$dr/journal/billing/task.md" refunds invoices
mkdir -p "$dr/journal/notes"
printf -- '---\ncontributors: [a]\ndate: 2026-11-12\n---\n\n## Feature: plain-thing\n' \
  > "$dr/journal/notes/task.md"

# detect <shell> <folders> — run the fence with the folder list substituted.
detect() {
  local script="$dr/detect.sh"
  printf '%s\n' "${fence//<folder1> \[<folder2> ...\]/$2}" > "$script"
  (cd "$dr" && env MI_DATA_ROOT="$dr" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$1" "$script" 2>&1)
}

tab="$(printf '\t')"
shells=(bash)
if command -v zsh >/dev/null 2>&1; then
  shells+=(zsh)
fi
for sh in "${shells[@]}"; do
  t="mi-run detection [$sh]: no marker → no rows (a plain task.md is journal content)"
  out="$(detect "$sh" notes)"
  if [[ -z "${out//[[:space:]]/}" ]]; then
    ok "$t"
  else
    ng "$t" "expected no output, got: $out"
  fi

  t="mi-run detection [$sh]: headings verbatim, in file order, trailing spaces trimmed"
  out="$(detect "$sh" 'payments notes')"
  want="stripe-webhooks${tab}payments/task.md
refunds${tab}payments/task.md"
  if [[ "$out" == "$want" ]]; then
    ok "$t"
  else
    ng "$t" "got: $out"
  fi

  t="mi-run detection [$sh]: several topics in selected-folder order; a shared name is a duplicate"
  out="$(detect "$sh" 'billing payments')"
  if [[ "$(printf '%s\n' "$out" | head -1)" == "refunds${tab}billing/task.md" \
     && "$out" == *"duplicate: refunds in billing/task.md and payments/task.md"* ]]; then
    ok "$t"
  else
    ng "$t" "got: $out"
  fi
done

# ---- folder-id.sh free-name ---------------------------------------------

fdr="$(new_sandbox)"
mkdir -p "$fdr/quest/2026-11-12-payments" "$fdr/workflow-stream/refunds"
cat > "$fdr/quest/active.md" <<'EOF'
---
slug: 2026-11-12-payments
started: "2026-11-12"
journal-folders: [payments]
status: active
---
EOF

free_name() { MI_DATA_ROOT="$fdr" "$REPO_ROOT/scripts/folder-id.sh" free-name "$@" 2>/dev/null; }

t="free-name: a free stem is returned unchanged"
out="$(free_name stripe-webhooks refunds-x)"
if [[ "$out" == "stripe-webhooks" ]]; then ok "$t"; else ng "$t" "got '$out'"; fi

t="free-name: a stem whose folder fails the gate gets the first ordinal from 2"
out="$(free_name refunds stripe-webhooks)"
if [[ "$out" == "refunds-2" ]]; then ok "$t"; else ng "$t" "got '$out'"; fi

t="free-name: an ordinal another cycle feature already uses is skipped"
out="$(free_name refunds stripe-webhooks refunds-2)"
if [[ "$out" == "refunds-3" ]]; then ok "$t"; else ng "$t" "got '$out'"; fi

t="free-name: no stem is a usage error"
if MI_DATA_ROOT="$fdr" "$REPO_ROOT/scripts/folder-id.sh" free-name >/dev/null 2>&1; then
  ng "$t" "exited 0 without a stem"
else
  ok "$t"
fi

t="mi-run: Step 3 renames a scriptorium feature with free-name"
if grep -q 'folder-id.sh" free-name "<scriptorium-feature>"' "$REPO_ROOT/commands/mi-run.md"; then
  ok "$t"
else
  ng "$t" "commands/mi-run.md does not call free-name with the task.md heading as the stem"
fi

# ---- ingest.sh scriptorium/<topic> ----------------------------------------

idr="$(new_sandbox)"
bin="$(new_sandbox)"
printf '#!/bin/sh\nexit 0\n' > "$bin/docling"   # dry runs never call it
chmod +x "$bin/docling"
for f in scriptorium/payments/contract.pdf scriptorium/payments/shot.png \
         scriptorium/payments/notes/n.docx scriptorium/payments/v2-notes/keep.pdf \
         scriptorium/payments/v1/old.docx scriptorium/payments/v12/z.pdf \
         scriptorium/payments/.scratch/s.pdf scriptorium/payments/contract.images/p.png \
         journal/specs/a.pdf journal/scriptorium/j.pdf; do
  mkdir -p "$idr/$(dirname "$f")"
  : > "$idr/$f"
done
mkdir -p "$idr/scriptorium/empty"

ingest() { (export PATH="$bin:$PATH" MI_DATA_ROOT="$idr"; "$REPO_ROOT/scripts/ingest.sh" "$@" 2>&1); }

out="$(ingest scriptorium/payments --dry-run)"
t="ingest: a topic lists its files, relative to scriptorium/"
if [[ "$out" == *"payments/contract.pdf"* && "$out" == *"payments/shot.png"* \
   && "$out" == *"payments/notes/n.docx"* && "$out" == *"payments/v2-notes/keep.pdf"* \
   && "$out" != *"$idr"* ]]; then
  ok "$t"
else
  ng "$t" "got: $out"
fi

t="ingest: a topic scan skips v<N>/, .scratch/ and *.images/"
if [[ "$out" != *"v1/"* && "$out" != *"v12/"* && "$out" != *".scratch/"* && "$out" != *".images/"* ]]; then
  ok "$t"
else
  ng "$t" "got: $out"
fi

t="ingest: an unknown topic fails with 'scriptorium topic not found'"
out="$(ingest scriptorium/nope --dry-run)"
if [[ "$out" == *"scriptorium topic not found"* ]]; then ok "$t"; else ng "$t" "got: $out"; fi

t="ingest: a bare 'scriptorium' still means the journal folder"
out="$(ingest scriptorium --dry-run)"
if [[ "$out" == *"scriptorium/j.pdf"* && "$out" != *"contract.pdf"* ]]; then ok "$t"; else ng "$t" "got: $out"; fi

t="ingest: a bare run scans journal/ only"
out="$(ingest --dry-run)"
if [[ "$out" == *"specs/a.pdf"* && "$out" != *"contract.pdf"* ]]; then ok "$t"; else ng "$t" "got: $out"; fi

t="ingest: a folder with no supported files prints the summary line (bash 3.2 empty array)"
out="$(ingest scriptorium/empty --dry-run)"
if [[ "$out" == *"converted=0  skipped=0  failed=0"* ]]; then ok "$t"; else ng "$t" "got: $out"; fi

echo
echo "scriptorium-integration: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
