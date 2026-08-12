#!/usr/bin/env bash
# validate-frontmatter.sh — validate a workflow .md file's frontmatter against a schema.
# Tries ajv-cli for deep JSON Schema validation; falls back to yq-based structural checks.
#
# Usage: validate-frontmatter.sh <file> <schema-name>
#   <schema-name> is the basename of schemas/<schema-name>.schema.yaml (e.g., "progress").

set -euo pipefail
source "$(dirname "$0")/common.sh"

file="${1:?file required}"
schema_name="${2:?schema name required}"
schema="${MI_PLUGIN_ROOT}/schemas/${schema_name}.schema.yaml"

[[ -f "$file" ]] || mi_die "file not found: $file"
[[ -f "$schema" ]] || mi_die "schema not found: $schema"

# Extract frontmatter as JSON to a tempfile.
# Note: ajv-cli requires the .json extension on both schema and data files,
# otherwise it tries to parse them as something else and errors with
# "Unexpected token ':'" — so we create tempfiles with .json suffix.
tmp_fm="$(mktemp).json"
tmp_schema_json="$(mktemp).json"
trap 'rm -f "$tmp_fm" "$tmp_schema_json"' EXIT

python3 - "$file" "$tmp_fm" <<'PYEOF'
import sys, re, json, yaml, datetime
src, dest = sys.argv[1], sys.argv[2]
with open(src) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---', content, re.DOTALL)
if not m:
    print(f'error: {src} has no frontmatter', file=sys.stderr)
    sys.exit(1)
fm = yaml.safe_load(m.group(1)) or {}

# YAML 1.1 auto-types unquoted ISO-8601 scalars as date/datetime objects, which
# json.dump cannot serialize — an unquoted `started-at: 2026-08-11T12:34:56Z`
# used to abort this script with a raw `TypeError: Object of type datetime is
# not JSON serializable` traceback instead of producing a validation verdict.
# Every schema that declares such a field declares it `type: string`, so the
# file is technically wrong; but a crash is the worst way to say so. Serialize
# date-likes back to ISO-8601 text (validation proceeds normally) and warn once
# per offending path so the unquoted write that produced it stays visible.
# Write-side fix belongs in the producer: `mi_render_template` already quotes
# via `yaml_scalar`; hand-written frontmatter must quote the value itself.
drifted = []

def deiso(node, path='$'):
    if isinstance(node, dict):
        return {k: deiso(v, f'{path}.{k}') for k, v in node.items()}
    if isinstance(node, list):
        return [deiso(v, f'{path}[{i}]') for i, v in enumerate(node)]
    # datetime.datetime is a subclass of datetime.date — this covers both,
    # plus bare `time` values.
    if isinstance(node, (datetime.date, datetime.time)):
        drifted.append(path)
        return node.isoformat()
    return node

fm = deiso(fm)
if drifted:
    print(
        f"warning: {src} has unquoted YAML date/datetime frontmatter values "
        f"({', '.join(drifted)}); validated as ISO-8601 strings. Quote them at "
        f"the write site.",
        file=sys.stderr,
    )
with open(dest, 'w') as o:
    json.dump(fm, o)
PYEOF

python3 - "$schema" "$tmp_schema_json" <<'PYEOF'
import sys, json, yaml
src, dest = sys.argv[1], sys.argv[2]
with open(src) as f:
    s = yaml.safe_load(f)
with open(dest, 'w') as o:
    json.dump(s, o)
PYEOF

# Try ajv-cli first for full JSON Schema validation.
if command -v ajv >/dev/null 2>&1; then
  if ajv validate -s "$tmp_schema_json" -d "$tmp_fm" --strict=false >/dev/null 2>&1; then
    mi_info "✓ $file frontmatter valid (ajv, schema=$schema_name)"
    exit 0
  else
    echo "error: $file frontmatter failed schema validation (schema=$schema_name)" >&2
    ajv validate -s "$tmp_schema_json" -d "$tmp_fm" --strict=false >&2 || true
    exit 1
  fi
fi

# Fallback: Python jsonschema module if available.
if python3 -c "import jsonschema" >/dev/null 2>&1; then
  if python3 - "$tmp_schema_json" "$tmp_fm" <<'PYEOF' >&2
import sys, json, jsonschema
schema = json.load(open(sys.argv[1]))
data = json.load(open(sys.argv[2]))
try:
    jsonschema.validate(data, schema)
except jsonschema.ValidationError as e:
    print(f"  • {e.message} (at {list(e.path)})", file=sys.stderr)
    sys.exit(1)
PYEOF
  then
    mi_info "✓ $file frontmatter valid (jsonschema, schema=$schema_name)"
    exit 0
  else
    echo "error: $file frontmatter failed schema validation (schema=$schema_name)" >&2
    exit 1
  fi
fi

# Last fallback: structural check — required fields present, no obvious type mismatches.
mi_info "ajv and python3-jsonschema both unavailable; using structural fallback for $file"
required_fields="$(python3 -c "
import json, sys
s = json.load(open('$tmp_schema_json'))
print(' '.join(s.get('required', [])))
")"
missing=()
for field in $required_fields; do
  val="$(mi_fm_get "$file" "$field" 2>/dev/null || true)"
  if [[ -z "$val" || "$val" == "null" ]]; then
    missing+=("$field")
  fi
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "error: $file missing required frontmatter fields: ${missing[*]}" >&2
  exit 1
fi
mi_info "✓ $file frontmatter structurally valid (fallback, schema=$schema_name)"
