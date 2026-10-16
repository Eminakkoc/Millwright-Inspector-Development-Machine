#!/usr/bin/env bash
# run.sh — command blocks run the same in bash and zsh (1.13.0).
#
# Claude Code's Bash tool runs the user's shell: zsh on a default Mac, bash on
# most Linux, Git Bash on Windows. When a block broke in zsh, Claude re-ran it
# inside `bash -c`, and Claude Code's removal check stopped one such call for
# permission; unattended, it was denied. These checks keep every fenced bash
# block in commands/*.md and agents/*.md runnable in bash 3.2, bash 5 and zsh,
# run the blocks this release rewrote in both shells, and test the script
# entry points those blocks now use. See docs/millwright-inspector-project.md
# §8.14 "Running blocks in any shell". Ported from MIDM 2.0.1 (33a045a); the
# v2-only set-queue checks are left out, and the quoting check from the former
# tests/fence-lint suite lives here: every $CLAUDE_PLUGIN_ROOT in commands/ is
# double-quoted, so a plugin root with a space (C:/Users/John Smith/…) stays
# one word.
#
# Each check prints ✓/✗; the suite exits 1 if any failed. zsh-only checks are
# skipped (and say so) when zsh is not installed.
set -uo pipefail

# Every script finds its siblings through MI_PLUGIN_ROOT, which prefers
# $CLAUDE_PLUGIN_ROOT — unset it so every call runs this checkout.
unset CLAUDE_PLUGIN_ROOT
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
S="$REPO_ROOT/scripts"
CMD="$REPO_ROOT/commands"
PY="$S/py.sh"
SLUG=2026-10-16-demo

pass=0
fail=0
fail_names=()

ok() { printf "\xe2\x9c\x93 %s\n" "$1"; pass=$((pass + 1)); }
ng() { printf "\xe2\x9c\x97 %s\n   %s\n" "$1" "$2" >&2; fail=$((fail + 1)); fail_names+=("$1"); }
skip() { printf -- "- %s (skipped: %s)\n" "$1" "$2"; }

TMP_PARENT="$(mktemp -d)"
trap 'rm -rf "$TMP_PARENT"' EXIT

SHELLS="bash"
if command -v zsh >/dev/null 2>&1; then SHELLS="bash zsh"; fi

# ---- Lint over every fenced bash block ------------------------------------

FENCES="$TMP_PARENT/fences"
mkdir -p "$FENCES"
# Written to a file, not fed as a heredoc inside $( ): bash 3.2 cannot parse a
# heredoc body with an unbalanced quote or parenthesis inside a command
# substitution, and these regexes have both.
LINT_PY="$TMP_PARENT/lint.py"
cat > "$LINT_PY" <<'PYEOF'
import os, re, sys

out_dir, paths = sys.argv[1], sys.argv[2:]
checks = {
    "bash-only": [
        (re.compile(r"\bshopt\b"), "shopt"),
        (re.compile(r"\$\{!"), "${!…} indirect expansion"),
        (re.compile(r"\b(declare|typeset|local)\s+-[a-zA-Z]*[An]"), "associative array or nameref"),
        (re.compile(r"\b(mapfile|readarray)\b"), "mapfile/readarray"),
        (re.compile(r"\bread\s+(-[a-zA-Z]+\s+)*-[a-zA-Z]*a"), "read -a"),
        (re.compile(r"\bPIPESTATUS\b"), "PIPESTATUS"),
    ],
    "recursive-rm": [(re.compile(r"(^|[\s;&|(])rm\s+(-[a-zA-Z]*[rR])"), "rm -r")],
    "shell-wrapper": [(re.compile(r"(^|[\s;&|(`])(bash|sh|zsh)\s+-[a-zA-Z]*c\b"), "bash -c / sh -c / zsh -c")],
}
split_marker = re.compile(r"shellcheck\s+disable=.*\bSC(2086|2206|2207)\b")
fence_open = re.compile(r"^(\s*)```bash\s*$")
fence_close = re.compile(r"^\s*```\s*$")
# A <placeholder> the agent fills in; never a heredoc (<<) or a redirect.
placeholder = re.compile(r"(?<![<\w$])<([A-Za-z][A-Za-z0-9 _./:-]*)>(?!>)")

VAR = re.compile(r"\$\{?CLAUDE_PLUGIN_ROOT(?::-)?\}?")
HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def unquoted(text):
    """Offsets of $CLAUDE_PLUGIN_ROOT outside double quotes in shell text."""
    found, stack, i, n, heredocs = [], ["top"], 0, len(text), []
    while i < n:
        ctx, ch = stack[-1], text[i]
        if ch == "\n" and heredocs and ctx in ("top", "sub"):
            i += 1
            for delim in heredocs:
                while i < n:
                    j = text.find("\n", i)
                    line = text[i:] if j < 0 else text[i:j]
                    i = n if j < 0 else j + 1
                    if line.strip() == delim:
                        break
            heredocs = []
            continue
        if ctx == "sq":
            if ch == "'":
                stack.pop()
            i += 1
            continue
        if ctx == "dq":
            if ch == "\\":
                i += 2; continue
            if text.startswith("$(", i):
                stack.append("sub"); i += 2; continue
            if ch == '"':
                stack.pop()
            i += 1
            continue
        if ch == "\\":
            i += 2; continue
        if ch == "#" and (i == 0 or text[i - 1] in " \t\n;|&("):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if ch == "'":
            stack.append("sq"); i += 1; continue
        if ch == '"':
            stack.append("dq"); i += 1; continue
        if text.startswith("$(", i) and not text.startswith("$((", i):
            stack.append("sub"); i += 2; continue
        if ch == ")" and ctx == "sub":
            stack.pop(); i += 1; continue
        m = HEREDOC.match(text, i)
        if m:
            heredocs.append(m.group(2)); i = m.end(); continue
        if VAR.match(text, i):
            found.append(i)
        i += 1
    return found


span = re.compile(r"`([^`\n]+)`")
missing_note = []
for path in paths:
    name = os.path.basename(path)
    text = open(path, encoding="utf-8").read()
    lines = text.split("\n")
    n_fences = 0
    i = 0
    while i < len(lines):
        m = fence_open.match(lines[i])
        if not m:
            if "/commands/" in path:
                for sm in span.finditer(lines[i]):
                    s = sm.group(1)
                    if "CLAUDE_PLUGIN_ROOT" in s and not VAR.fullmatch(s.strip()) and unquoted(s):
                        print(f"unquoted\t{name}:{i + 1}\t{s}")
            i += 1
            continue
        indent, start = len(m.group(1)), i + 1
        body = []
        i += 1
        while i < len(lines) and not fence_close.match(lines[i]):
            raw = lines[i]
            body.append(raw[indent:] if raw[:indent].strip() == "" else raw)
            i += 1
        i += 1
        n_fences += 1
        for k, line in enumerate(body):
            where = f"{name}:{start + k + 1}"
            if split_marker.search(line):
                print(f"word-splitting\t{where}\t{line.strip()}")
            if line.lstrip().startswith("#"):
                continue
            for category, rules in checks.items():
                for rx, label in rules:
                    if rx.search(line):
                        print(f"{category}\t{where}\t{label}: {line.strip()}")
        fence_text = "\n".join(body)
        if "/commands/" in path:
            for off in unquoted(fence_text):
                print(f"unquoted\t{name}:{start + 1 + fence_text.count(chr(10), 0, off)}\t$CLAUDE_PLUGIN_ROOT outside double quotes")
        with open(os.path.join(out_dir, f"{name}__L{start}.sh"), "w", encoding="utf-8") as f:
            f.write(placeholder.sub("X", fence_text) + "\n")
    if "/commands/" in path and n_fences and "**Running blocks.**" not in text:
        missing_note.append(name)
for name in missing_note:
    print(f"missing-note\t{name}\tno **Running blocks.** note")
PYEOF
lint_out="$("$PY" "$LINT_PY" "$FENCES" "$CMD"/*.md "$REPO_ROOT"/agents/*.md)" \
  || { echo "fence extraction failed" >&2; exit 1; }

lint_report() { # <category> <label>
  local found
  found="$(printf '%s\n' "$lint_out" | awk -F'\t' -v c="$1" '$1 == c { print "   " $2 "  " $3 }')"
  if [[ -z "$found" ]]; then ok "$2"; else ng "$2" "$(printf '\n%s' "$found")"; fi
}
lint_report bash-only "fences: no bash-only syntax (shopt, \${!x}, declare -A, mapfile, read -a, PIPESTATUS)"
lint_report word-splitting "fences: no word-splitting reliance (shellcheck SC2086/SC2206/SC2207 disables)"
lint_report recursive-rm "fences: no recursive rm (blueprints.sh clear-* owns folder deletes)"
lint_report shell-wrapper "fences: no bash -c / sh -c / zsh -c"
lint_report missing-note "commands: every command with bash fences carries the Running blocks note"
lint_report unquoted "commands: every \$CLAUDE_PLUGIN_ROOT in a fence or command span is double-quoted"

n_fences="$(find "$FENCES" -name '*.sh' | wc -l | tr -d ' ')"
for sh in $SHELLS; do
  bad=""
  for f in "$FENCES"/*.sh; do
    if ! err="$("$sh" -n "$f" 2>&1)"; then
      bad="$bad"$'\n'"   $(basename "$f" .sh): $(printf '%s' "$err" | head -1)"
    fi
  done
  t="fences: all $n_fences parse under $sh -n ($("$sh" --version 2>/dev/null | head -1 | cut -c1-40))"
  if [[ -z "$bad" ]]; then ok "$t"; else ng "$t" "$bad"; fi
done
if [[ "$SHELLS" == "bash" ]]; then skip "fences: parse under zsh -n" "zsh not installed"; fi

# ---- Helpers for running real block text -----------------------------------

# snippet <file> <start-regex> <end-regex> — the lines from the first match of
# <start-regex> up to, not including, the next line matching <end-regex>.
snippet() {
  "$PY" - "$@" <<'PYEOF'
import re, sys
path, start, end = sys.argv[1:4]
lines = open(path, encoding="utf-8").read().split("\n")
i = next(i for i, l in enumerate(lines) if re.search(start, l))
out = []
for line in lines[i:]:
    if out and re.search(end, line):
        break
    out.append(line)
print("\n".join(out))
PYEOF
}

# in_shell <shell> <script-file> — run it; sets RC and OUT (stdout + stderr).
in_shell() {
  OUT="$("$1" "$2" 2>&1)"
  RC=$?
}

# new_root — a data root with one active cycle.
new_root() {
  local r
  r="$(mktemp -d "$TMP_PARENT/root.XXXXXX")"
  mkdir -p "$r/quest/$SLUG"
  cat > "$r/quest/active.md" <<EOF
---
slug: $SLUG
started: "2026-10-16T00:00:00Z"
journal-folders: [demo]
status: active
---

# Active quest pointer
EOF
  printf '%s' "$r"
}

# ---- Argument parsing blocks, run in every shell ----------------------------

UB="$(snippet "$CMD/mi-update-blueprint.md" '^reason_kind="manual"' '^```')"
ub_case() { # <label> <arguments text> <expected "force|kind|summary" or "FAIL">
  local sh f
  for sh in $SHELLS; do
    f="$TMP_PARENT/ub-$sh.sh"
    printf '%s\nprintf "%%s|%%s|%%s\\n" "$force_regen" "$reason_kind" "$reason_summary"\n' \
      "${UB//\$ARGUMENTS/$2}" > "$f"
    in_shell "$sh" "$f"
    t="mi-update-blueprint args ($sh): $1"
    if [[ "$3" == "FAIL" ]]; then
      if (( RC != 0 )); then ok "$t"; else ng "$t" "expected a failure, got: $OUT"; fi
    elif (( RC == 0 )) && [[ "$OUT" == "$3" ]]; then ok "$t"; else ng "$t" "rc=$RC out=$OUT"; fi
  done
}
ub_case "--force-regen and a reason" "--force-regen fix the schema" "1|manual|fix the schema"
ub_case "--reason-kind <kind>" "--reason-kind spec-update new spec" "0|spec-update|new spec"
ub_case "--reason-kind=<kind>" "--reason-kind=spec-update x" "0|spec-update|x"
ub_case "no reason summary fails" "--force-regen" "FAIL"
ub_case "--reason-kind without a value fails" "--reason-kind" "FAIL"

BR_PARSE="$(snippet "$CMD/mi-blueprint-review.md" '^agent="\$\{1:-\}"' '^\[\[ -n "\$agent" && -n "\$file" \]\]')"
br_case() { # <label> <set -- arguments> <expected or FAIL>
  local sh f
  for sh in $SHELLS; do
    f="$TMP_PARENT/br-$sh.sh"
    printf 'set -euo pipefail\nset -- %s\n%s\nprintf "%%s|%%s|%%s|%%s|%%s|%%s|%%s\\n" "$agent" "$file" "$scope" "$auto_iter" "$batch_size" "$reference_file" "$reasoning_effort"\n' \
      "$2" "$BR_PARSE" > "$f"
    in_shell "$sh" "$f"
    t="mi-blueprint-review args ($sh): $1"
    if [[ "$3" == "FAIL" ]]; then
      if (( RC != 0 )); then ok "$t"; else ng "$t" "expected a failure, got: $OUT"; fi
    elif (( RC == 0 )) && [[ "$OUT" == "$3" ]]; then ok "$t"; else ng "$t" "rc=$RC out=$OUT"; fi
  done
}
br_case "flags with and without =, a value with spaces" \
  'codex /tmp/req.md --scope "Goals (this cycle)" --auto-iter 3 --reference-file=/tmp/ctx.md --batch-size 4' \
  "codex|/tmp/req.md|Goals (this cycle)|3|4|/tmp/ctx.md|medium"
br_case "defaults with only agent and file" "claude /tmp/req.md" "claude|/tmp/req.md||5|3||medium"
br_case "a value flag at the end without a value fails" "codex /tmp/req.md --scope" "FAIL"

BC_PARSE="$(snippet "$CMD/mi-blueprint-review-consistency.md" '^agent="\$\{1:-\}"' '^\[\[ -n "\$agent" && -n "\$file" \]\]')"
for sh in $SHELLS; do
  f="$TMP_PARENT/bc-$sh.sh"
  printf 'set -euo pipefail\nset -- codex /tmp/f.md --reasoning-effort high --auto-iter=2\n%s\nprintf "%%s|%%s|%%s|%%s\\n" "$agent" "$file" "$reasoning_effort" "$auto_iter"\n' \
    "$BC_PARSE" > "$f"
  in_shell "$sh" "$f"
  t="mi-blueprint-review-consistency args ($sh): both flag forms"
  if (( RC == 0 )) && [[ "$OUT" == "codex|/tmp/f.md|high|2" ]]; then ok "$t"; else ng "$t" "rc=$RC out=$OUT"; fi
done

BI_PARSE="$(snippet "$CMD/mi-blueprint-review-item.md" '^# Parse --auto-iter / --reasoning-effort' '^\[\[ "\$auto_iter" =~')"
bi_case() { # <label> <set -- arguments> <expected or FAIL>
  local sh f
  for sh in $SHELLS; do
    f="$TMP_PARENT/bi-$sh.sh"
    printf 'set -euo pipefail\nauto_iter=5\nreasoning_effort=medium\nset -- %s\n%s\nprintf "%%s|%%s\\n" "$auto_iter" "$reasoning_effort"\n' \
      "$2" "$BI_PARSE" > "$f"
    in_shell "$sh" "$f"
    t="mi-blueprint-review-item flags ($sh): $1"
    if [[ "$3" == "FAIL" ]]; then
      if (( RC != 0 )); then ok "$t"; else ng "$t" "expected a failure, got: $OUT"; fi
    elif (( RC == 0 )) && [[ "$OUT" == "$3" ]]; then ok "$t"; else ng "$t" "rc=$RC out=$OUT"; fi
  done
}
bi_case "flags anywhere in argv" "codex /tmp/f.md:X-1 --auto-iter 4 --reasoning-effort=high" "4|high"
bi_case "content mode keeps the defaults" "codex some requirement text" "5|medium"
bi_case "a trailing flag without a value fails" "codex /tmp/f.md:X-1 --auto-iter" "FAIL"

# ---- mi-run Step 2.5 size blocks, run in every shell ------------------------

jr="$(mktemp -d "$TMP_PARENT/journal-root.XXXXXX")"
mkdir -p "$jr/journal/big" "$jr/journal/many-small" "$jr/journal/few-big"
for n in 1 2 3 4 5 6; do
  head -c 8000 /dev/zero | tr '\0' 'a' > "$jr/journal/big/n$n.md"
  printf 'x\n' > "$jr/journal/many-small/n$n.md"
done
for n in 1 2 3; do head -c 20000 /dev/zero | tr '\0' 'b' > "$jr/journal/few-big/n$n.md"; done
SIZE_BLOCK="$(snippet "$CMD/mi-run.md" '^total_bytes=0$' '^```')"
TALLY_BLOCK="$(snippet "$CMD/mi-run.md" '^oversize_folders="\$\($' '^```')"
for sh in $SHELLS; do
  f="$TMP_PARENT/run-$sh.sh"
  printf 'data_root=%q\nfiles=( "$data_root"/journal/*/*.md )\n%s\n%s\n' "$jr" "$SIZE_BLOCK" "$TALLY_BLOCK" > "$f"
  in_shell "$sh" "$f"
  t="mi-run Step 2.5 ($sh): byte total and the >5 files / >40 KB folder tally"
  if (( RC == 0 )) && [[ "$OUT" == *"total: 108012 B across 15 file(s)"* ]] && [[ "$(printf '%s\n' "$OUT" | tail -1)" == "big" ]]; then
    ok "$t"
  else
    ng "$t" "rc=$RC out=$(printf '%s' "$OUT" | tail -3)"
  fi
done

# ---- blueprints.sh clear-current / clear-implementation ---------------------

feature_root() { # <root> <feature> — a feature folder with current/ and implementation/
  local fd="$1/workflow-stream/$2"
  mkdir -p "$fd/blueprints/current/diagrams" "$fd/implementation/diagrams" "$fd/test"
  printf 'r\n' > "$fd/blueprints/current/requirements.md"
  printf 'h\n' > "$fd/blueprints/current/.hidden"
  printf 'p\n' > "$fd/blueprints/current/diagrams/use-case-x.puml"
  printf 'rh\n' > "$fd/blueprints/current/review-history.md"
  for n in inspector-review.md review-context.md change-summary.md grounding-report.md blueprint-lessons.md notes.md; do
    printf 'x\n' > "$fd/implementation/$n"
  done
  printf 'd\n' > "$fd/implementation/diagrams/a.puml"
  printf 't\n' > "$fd/test/manual-test-plan.md"
}

root="$(new_root)"; feature_root "$root" feat
MI_DATA_ROOT="$root" "$S/blueprints.sh" clear-current feat >/dev/null 2>&1
rc=$?
cur="$root/workflow-stream/feat/blueprints/current"
t="clear-current: empties current/, hidden files and review-history.md included, and keeps the folder"
if (( rc == 0 )) && [[ -d "$cur" && -z "$(ls -A "$cur")" ]]; then ok "$t"; else ng "$t" "rc=$rc left: $(ls -A "$cur" 2>&1 | tr '\n' ' ')"; fi
t="clear-current: leaves implementation/ and test/ alone"
if [[ -f "$root/workflow-stream/feat/implementation/grounding-report.md" && -f "$root/workflow-stream/feat/test/manual-test-plan.md" ]]; then ok "$t"; else ng "$t" "a sibling folder lost files"; fi

root="$(new_root)"
MI_DATA_ROOT="$root" "$S/blueprints.sh" clear-current nofeature >/dev/null 2>&1
rc=$?
t="clear-current: a missing current/ is nothing to clear (exit 0)"
if (( rc == 0 )); then ok "$t"; else ng "$t" "rc=$rc"; fi

root="$(new_root)"; feature_root "$root" feat
for bad in "" "." ".." "feat/../feat" "a/b"; do
  MI_DATA_ROOT="$root" "$S/blueprints.sh" clear-current "$bad" >/dev/null 2>&1
  rc=$?
  t="clear-current: refuses the feature name '$bad'"
  if (( rc != 0 )) && [[ -f "$root/workflow-stream/feat/blueprints/current/requirements.md" ]]; then ok "$t"; else ng "$t" "rc=$rc"; fi
done

root="$(new_root)"; feature_root "$root" feat
impl="$root/workflow-stream/feat/implementation"
MI_DATA_ROOT="$root" "$S/blueprints.sh" clear-implementation feat diagrams grounding-report.md blueprint-lessons.md >/dev/null 2>&1
rc=$?
t="clear-implementation: removes exactly the named entries"
if (( rc == 0 )) && [[ ! -e "$impl/diagrams" && ! -e "$impl/grounding-report.md" && ! -e "$impl/blueprint-lessons.md" ]] \
   && [[ -f "$impl/inspector-review.md" && -f "$impl/notes.md" && -f "$root/workflow-stream/feat/test/manual-test-plan.md" ]]; then
  ok "$t"
else
  ng "$t" "rc=$rc left: $(ls -A "$impl" | tr '\n' ' ')"
fi

root="$(new_root)"; feature_root "$root" feat
impl="$root/workflow-stream/feat/implementation"
for bad in notes.md ../test test diagrams/a.puml; do
  MI_DATA_ROOT="$root" "$S/blueprints.sh" clear-implementation feat diagrams "$bad" >/dev/null 2>&1
  rc=$?
  t="clear-implementation: refuses '$bad' before removing anything"
  if (( rc != 0 )) && [[ -f "$impl/diagrams/a.puml" && -f "$impl/notes.md" && -f "$root/workflow-stream/feat/test/manual-test-plan.md" ]]; then ok "$t"; else ng "$t" "rc=$rc"; fi
done
MI_DATA_ROOT="$root" "$S/blueprints.sh" clear-implementation feat >/dev/null 2>&1
rc=$?
t="clear-implementation: refuses an empty name list"
if (( rc != 0 )); then ok "$t"; else ng "$t" "rc=$rc"; fi
MI_DATA_ROOT="$root" "$S/blueprints.sh" clear-implementation nofeature diagrams >/dev/null 2>&1
rc=$?
t="clear-implementation: a missing implementation/ is nothing to clear (exit 0)"
if (( rc == 0 )); then ok "$t"; else ng "$t" "rc=$rc"; fi

# ---- persist-findings - and the Phase F line ---------------------------------

PF_LINE="$(grep -F 'persist-findings "$review_history" -' "$CMD/mi-blueprint-review.md" | head -1)"
for sh in $SHELLS; do
  h="$TMP_PARENT/history-$sh.md"
  cp "$REPO_ROOT/tests/blueprint-review/fixtures/summary-mixed/review-history.md" "$h"
  f="$TMP_PARENT/pf-$sh.sh"
  {
    printf 'CLAUDE_PLUGIN_ROOT=%q\nreview_history=%q\n' "$REPO_ROOT" "$h"
    # A JSON string holding a \n escape: zsh's echo would turn it into a raw line break.
    printf '%s\n' "findings_json='[{\"status\": \"new\", \"severity\": \"medium\", \"scope_impact\": \"clarifying\", \"phase\": \"item\", \"target\": \"X-1\", \"cycle_slug\": \"s\", \"iter\": 1, \"finding\": \"line one\\nline two\", \"suggested_fix\": \"fix it\"}]'"
    printf '%s\n' "$PF_LINE"
  } > "$f"
  in_shell "$sh" "$f"
  t="mi-blueprint-review Phase F ($sh): findings JSON with a \\n escape persists through stdin"
  if (( RC == 0 )) && grep -q '^## F-005' "$h" && grep -q 'line one' "$h" && grep -q 'line two' "$h"; then ok "$t"; else ng "$t" "rc=$RC out=$OUT"; fi
done

# ---- Windows: LF checkouts and hook paths with spaces --------------------------

t=".gitattributes: scripts and command files check out with LF"
attrs="$(git -C "$REPO_ROOT" check-attr eol -- scripts/blueprints.sh commands/mi-continue.md templates 2>/dev/null)"
if [[ "$(printf '%s\n' "$attrs" | grep -c ': eol: lf$')" == "3" ]]; then ok "$t"; else ng "$t" "$attrs"; fi

t="hooks.json: every hook runs as bash \"\${CLAUDE_PLUGIN_ROOT}/hooks/…\" (paths with spaces)"
HOOKS_PY="$TMP_PARENT/hooks.py"
cat > "$HOOKS_PY" <<'PYEOF'
import json, re, sys
bad = []
for event, groups in json.load(open(sys.argv[1])).get("hooks", {}).items():
    for g in groups:
        for h in g.get("hooks", []):
            cmd = h.get("command", "")
            if "CLAUDE_PLUGIN_ROOT" in cmd and not re.fullmatch(r'bash "\$\{?CLAUDE_PLUGIN_ROOT\}?/hooks/[^"]+"(\s.*)?', cmd):
                bad.append(f"{event}: {cmd}")
print("\n".join(bad))
PYEOF
bad="$("$PY" "$HOOKS_PY" "$REPO_ROOT/hooks/hooks.json")"
if [[ -z "$bad" ]]; then ok "$t"; else ng "$t" "$bad"; fi

# ---- Summary ------------------------------------------------------------------

echo
echo "$pass passed, $fail failed"
if (( fail > 0 )); then
  printf '  failed: %s\n' "${fail_names[@]}"
  exit 1
fi
