#!/usr/bin/env bash
# run.sh — every fenced bash block in commands/*.md and agents/*.md parses
# under `bash -n`, and every $CLAUDE_PLUGIN_ROOT in commands/ is quoted (1.13.0).
#
# The command prose is the program Claude runs, and nothing else checks that it
# still parses: an `if …; then` whose body is only comments, or a heredoc with an
# apostrophe inside $( ) (bash 3.2 cannot parse either), shipped unnoticed. The
# fence extraction and <placeholder> substitution are copied from v2's
# tests/shell-portability/run.sh (MIDM 2.0.1), `bash -n` part only.
#
# The quoting check keeps a plugin root with a space (C:/Users/John Smith/…)
# one word: in ```bash fences and in inline code spans that hold a command or
# path, an unquoted $CLAUDE_PLUGIN_ROOT outside double quotes fails.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

pass=0
fail=0
fail_names=()

ok() { printf "\xe2\x9c\x93 %s\n" "$1"; pass=$((pass + 1)); }
ng() { printf "\xe2\x9c\x97 %s\n   %s\n" "$1" "$2" >&2; fail=$((fail + 1)); fail_names+=("$1"); }

TMP_PARENT="$(mktemp -d)"
trap 'rm -rf "$TMP_PARENT"' EXIT
FENCES="$TMP_PARENT/fences"
mkdir -p "$FENCES"

# Written to a file, not fed as a heredoc inside $( ): bash 3.2 cannot parse a
# heredoc body with an unbalanced quote or parenthesis inside a command
# substitution, and these regexes have both.
LINT_PY="$TMP_PARENT/lint.py"
cat > "$LINT_PY" <<'PYEOF'
import os, re, sys

out_dir, paths = sys.argv[1], sys.argv[2:]
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
for path in paths:
    name = os.path.basename(path)
    lines = open(path, encoding="utf-8").read().split("\n")
    i = 0
    while i < len(lines):
        m = fence_open.match(lines[i])
        if m:
            indent, start = len(m.group(1)), i + 1
            body = []
            i += 1
            while i < len(lines) and not fence_close.match(lines[i]):
                raw = lines[i]
                body.append(raw[indent:] if raw[:indent].strip() == "" else raw)
                i += 1
            i += 1
            text = "\n".join(body)
            with open(os.path.join(out_dir, f"{name}__L{start}.sh"), "w", encoding="utf-8") as f:
                f.write(placeholder.sub("X", text) + "\n")
            if "/commands/" in path:
                for off in unquoted(text):
                    print(f"unquoted\t{name}:{start + 1 + text.count(chr(10), 0, off)}")
            continue
        if "/commands/" in path:
            for sm in span.finditer(lines[i]):
                s = sm.group(1)
                if "CLAUDE_PLUGIN_ROOT" in s and not VAR.fullmatch(s.strip()) and unquoted(s):
                    print(f"unquoted\t{name}:{i + 1}")
        i += 1
PYEOF
lint_out="$("$REPO_ROOT/scripts/py.sh" "$LINT_PY" "$FENCES" "$REPO_ROOT"/commands/*.md "$REPO_ROOT"/agents/*.md)" \
  || { echo "fence extraction failed" >&2; exit 1; }

n_fences="$(find "$FENCES" -name '*.sh' | wc -l | tr -d ' ')"
t="fences: all $n_fences parse under bash -n ($(bash --version | head -1 | cut -c1-40))"
bad=""
for f in "$FENCES"/*.sh; do
  if ! err="$(bash -n "$f" 2>&1)"; then
    bad="$bad"$'\n'"   $(basename "$f" .sh): $(printf '%s' "$err" | head -1)"
  fi
done
if [[ "$n_fences" -gt 0 && -z "$bad" ]]; then ok "$t"; else ng "$t" "${bad:- no fences found}"; fi

t="commands: every \$CLAUDE_PLUGIN_ROOT in a fence or command span is double-quoted"
found="$(printf '%s\n' "$lint_out" | awk -F'\t' '$1 == "unquoted" { print "   " $2 }')"
if [[ -z "$found" ]]; then ok "$t"; else ng "$t" "$(printf '\n%s' "$found")"; fi

printf "\n%d passed, %d failed\n" "$pass" "$fail"
if (( fail > 0 )); then
  printf "Failed: %s\n" "${fail_names[*]}" >&2
  exit 1
fi
exit 0
