#!/usr/bin/env bash
# blueprint-review.sh — helpers for /mi-blueprint-review and friends.
# See docs/blueprints-review/plan.md.
#
# Subcommands:
#   resolve-tool <agent>          # → MCP tool name for the agent argument
#   enumerate <file>              # (added in Task 1.4)
#   parse-findings <file>         # (added in Task 1.5)
#   alloc-final-id <file>         # (added in Task 1.5)

set -euo pipefail

usage() {
  sed -n '2,11p' "$0"
}

cmd="${1:-}"
[[ -n "$cmd" ]] || { usage >&2; exit 64; }
shift

case "$cmd" in
  resolve-tool)
    agent="${1:-}"
    [[ -n "$agent" ]] || { echo "usage: $0 resolve-tool <agent>" >&2; exit 64; }
    case "$agent" in
      codex)
        # MCP tool name verified in Phase 0 Task 0.2. Replace if Phase 0 found a
        # different name.
        echo "mcp__codex__codex"
        ;;
      *)
        echo "error: agent '$agent' is not supported. Supported: codex" >&2
        exit 1
        ;;
    esac
    ;;

  enumerate)
    file="${1:-}"
    items_path="${2:-}"
    [[ -n "$file" && -n "$items_path" ]] || { echo "usage: $0 enumerate <file> <items.json>" >&2; exit 64; }
    [[ -f "$file" ]] || { echo "error: file not found: $file" >&2; exit 1; }
    [[ -f "$items_path" ]] || { echo "error: items file not found: $items_path" >&2; exit 1; }

    python3 - "$file" "$items_path" <<'PYEOF'
import sys, json, re

file_path, items_path = sys.argv[1], sys.argv[2]
with open(file_path, "rb") as f:
    raw = f.read()

# Strip leading YAML frontmatter (--- ... ---) from the body so offsets are
# 0-indexed into the body, not the file.
m = re.match(rb'^---\n.*?\n---\n', raw, re.DOTALL)
body_start = m.end() if m else 0
body = raw[body_start:]

with open(items_path) as f:
    items = json.load(f)

# Pre-scan: for each unique anchor_line, list every byte offset where it occurs
# in the body (exact substring match).
occurrences = {}  # anchor_line -> [offset, offset, ...]
for it in items:
    anchor = it["anchor_line"].encode("utf-8")
    if anchor in occurrences:
        continue
    offs = []
    start = 0
    while True:
        idx = body.find(anchor, start)
        if idx < 0:
            break
        offs.append(idx)
        start = idx + 1
    occurrences[anchor] = offs

# Resolve each item to a byte offset by indexing into its anchor's occurrence list.
resolved = []
errors = []
for it in items:
    anchor = it["anchor_line"].encode("utf-8")
    idx = int(it.get("occurrence_index", 1)) - 1
    offs = occurrences.get(anchor, [])
    if idx < 0 or idx >= len(offs):
        errors.append(f"item {it['id']}: anchor_line not found at occurrence_index {it.get('occurrence_index', 1)} "
                      f"(only {len(offs)} occurrence(s) in file)")
        continue
    start_offset = offs[idx]
    resolved.append({"id": it["id"], "start_offset": start_offset, "anchor": anchor})

# Compute end offsets by walking forward to the next anchor / `^## ` heading / EOF.
resolved.sort(key=lambda r: r["start_offset"])
heading_re = re.compile(rb'(?m)^## ')

descriptors = []
for i, r in enumerate(resolved):
    start = r["start_offset"]
    next_anchor_offset = resolved[i + 1]["start_offset"] if i + 1 < len(resolved) else len(body)
    h = heading_re.search(body, start + len(r["anchor"]))
    next_heading_offset = h.start() if h else len(body)
    end_offset = min(next_anchor_offset, next_heading_offset)
    region = body[start:end_offset]
    # Sanity check: region must start with anchor.
    if not region.startswith(r["anchor"]):
        errors.append(f"item {r['id']}: computed region does not start with anchor_line — script bug or stale offset")
        continue
    descriptors.append({
        "id": r["id"],
        "start_offset": r["start_offset"],
        "end_offset": end_offset,
        "original_region": region.decode("utf-8"),
    })

result = {"descriptors": descriptors, "errors": errors}
print(json.dumps(result, ensure_ascii=False, indent=2))
sys.exit(0 if not errors else 2)
PYEOF
    ;;

  parse-findings)
    file="${1:-}"
    [[ -n "$file" && -f "$file" ]] || { echo "usage: $0 parse-findings <file>" >&2; exit 64; }
    python3 - "$file" <<'PYEOF'
import sys, re, json
with open(sys.argv[1]) as f:
    text = f.read()
# Each block: <!-- REVIEW-FINDING\n     id: F-001\n     severity: high\n     ... \n-->
pattern = re.compile(r'<!--\s*REVIEW-FINDING\s*(.*?)\s*-->', re.DOTALL)
out = []
for m in pattern.finditer(text):
    body = m.group(1)
    fields = {}
    for line in body.splitlines():
        if ':' in line:
            k, _, v = line.partition(':')
            fields[k.strip()] = v.strip()
    out.append(fields)
print(json.dumps(out, indent=2))
PYEOF
    ;;

  alloc-final-id)
    file="${1:-}"
    [[ -n "$file" && -f "$file" ]] || { echo "usage: $0 alloc-final-id <file>" >&2; exit 64; }
    python3 - "$file" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f:
    text = f.read()
ns = [int(m.group(1)) for m in re.finditer(r'\bid:\s*F-(\d+)\b', text)]
print(f"F-{(max(ns) + 1) if ns else 1:03d}")
PYEOF
    ;;

  *)
    echo "error: unknown subcommand '$cmd'" >&2
    usage >&2
    exit 64
    ;;
esac
