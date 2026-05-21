#!/usr/bin/env bash
# blueprint-review.sh — helpers for /mi-blueprint-review and friends.
# See docs/blueprints-review/plan.md.
#
# Subcommands:
#   resolve-tool <agent>          # → MCP tool name for the agent argument
#   enumerate <file> <items.json> # (added in Task 1.4)
#   parse-findings <file>         # (added in Task 1.5)
#   alloc-final-id <file>         # (added in Task 1.5)
#   diff-drift <req> <sum> <todo> <feature>  # (added in Task 5.2)

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
        exit 64
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
with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
    text = f.read()
# Each block: <!-- REVIEW-FINDING\n     id: F-001\n     severity: high\n     ... \n-->
pattern = re.compile(r'<!--\s*REVIEW-FINDING\s*(.*?)\s*-->', re.DOTALL)
out = []
for m in pattern.finditer(text):
    body = m.group(1)
    fields = {}
    lines = body.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if ':' not in stripped:
            i += 1
            continue
        key, _, val = stripped.partition(':')
        key = key.strip()
        val = val.strip()
        if val == '|':
            # Collect subsequent lines as a multi-line scalar.
            # Stop when the next line is itself a "key: ..." form.
            block_lines = []
            i += 1
            while i < len(lines):
                next_line = lines[i]
                next_stripped = next_line.strip()
                # If this looks like a new top-level key, stop.
                if re.match(r'^[a-zA-Z_-]+:', next_stripped):
                    break
                block_lines.append(next_stripped)
                i += 1
            fields[key] = '\n'.join(block_lines).strip()
        else:
            fields[key] = val
            i += 1
    out.append(fields)
print(json.dumps(out, indent=2))
PYEOF
    ;;

  alloc-final-id)
    file="${1:-}"
    [[ -n "$file" && -f "$file" ]] || { echo "usage: $0 alloc-final-id <file>" >&2; exit 64; }
    python3 - "$file" <<'PYEOF'
import sys, re
with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
    raw = f.read()
m = re.match(r'^---\n.*?\n---\n', raw, re.DOTALL)
body = raw[m.end():] if m else raw
ns = [int(m.group(1)) for m in re.finditer(r'\bid:\s*F-(\d+)\b', body)]
print(f"F-{(max(ns) + 1) if ns else 1:03d}")
PYEOF
    ;;

  diff-drift)
    requirements="${1:-}"
    summary="${2:-}"
    todo="${3:-}"
    feature="${4:-}"
    [[ -n "$requirements" && -n "$summary" && -n "$todo" && -n "$feature" ]] || {
      echo "usage: $0 diff-drift <requirements.md> <summary.md> <todo-list.md> <feature>" >&2
      exit 64
    }
    python3 - "$requirements" "$summary" "$todo" "$feature" <<'PYEOF'
import sys, re
req, summary, todo, feature = sys.argv[1:]

def read(p):
    try:
        with open(p, encoding="utf-8", errors="replace") as f: return f.read()
    except FileNotFoundError:
        return ""

req_text = read(req)
sum_text = read(summary)
todo_text = read(todo)

# Extract item ids from requirements.md's Goals section.
req_goals = re.search(r'^## Goals \(this cycle\).*?(?=^## |\Z)', req_text, re.DOTALL | re.MULTILINE)
goal_items = []
if req_goals:
    for m in re.finditer(r'\*\*([A-Z]+-\d+)\*\*\s*[—\-:]\s*(.+?)(?=\n\s*-|\n##|\Z)', req_goals.group(0), re.DOTALL):
        goal_items.append((m.group(1), m.group(2).strip().splitlines()[0]))

# For each goal item id, check if its one-line description is present in
# summary.md (active feature section) and todo-list.md.
drift = []
sum_section = re.search(rf'^## Feature: {re.escape(feature)}.*?(?=^## |\Z)', sum_text, re.DOTALL | re.MULTILINE)
for id_, desc in goal_items:
    short = desc[:60]
    first_word = short.split()[0] if short.split() else ""
    if sum_section and first_word and first_word not in sum_section.group(0):
        drift.append(f"  - {id_}: requirements.md mentions \"{short}…\" — not found in summary.md's feature section")
    # Scope the first-word check to the specific line containing this item id,
    # not the whole todo file — avoids false negatives from word collisions
    # across unrelated items.
    todo_line = ""
    for line in todo_text.splitlines():
        if id_ in line:
            todo_line = line
            break
    if todo_line and first_word and first_word not in todo_line:
        drift.append(f"  - {id_}: requirements.md description differs from todo-list.md description")

print("\n".join(drift))
PYEOF
    ;;

  *)
    echo "error: unknown subcommand '$cmd'" >&2
    usage >&2
    exit 64
    ;;
esac
