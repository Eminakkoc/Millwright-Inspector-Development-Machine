#!/usr/bin/env bash
# capture-fixture.sh — snapshot a prompt block from the base commit (1.8.1)
# into tests/auto-mode/fixtures/prompts-off/<site>.txt.
set -euo pipefail
BASE=6ce0cba
site="${1:?site}"; file="${2:?file}"; first="${3:?first-line literal}"; last="${4:?last-line literal}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$root/tests/auto-mode/fixtures/prompts-off/$site.txt"
git -C "$root" show "$BASE:$file" | python3 -c '
import sys
first, last, out = sys.argv[1], sys.argv[2], sys.argv[3]
lines = sys.stdin.read().split("\n")
try:
    i = next(n for n, l in enumerate(lines) if first in l)
    j = next(n for n in range(i, len(lines)) if last in lines[n])
except StopIteration:
    sys.exit("capture-fixture: literal not found")
if j - i + 1 > 60:
    sys.exit("capture-fixture: range too long (%d lines)" % (j - i + 1))
open(out, "w").write("\n".join(lines[i:j + 1]) + "\n")
' "$first" "$last" "$out"
echo "captured $out"
