"""Shared top-level field writer for progress.md frontmatter.

Used by `progress.sh set-top` and `progress.sh finish --set` so both apply the
same parsing, protected-field refusal and duplicate check (spec §2.2).
"""
import sys

import yaml

# Fields owned by other progress.sh subcommands; never writable via field=value.
PROTECTED = {'active', 'queue', 'completed', 'id', 'todo-list-id'}


def _fail(cmd, msg):
    sys.stderr.write(f"error: progress.sh {cmd}: {msg}\n")
    sys.exit(1)


def apply_top_sets(fm, kvs, cmd):
    """Apply `field=value` pairs to the top-level mapping `fm` in place.

    Values are YAML-parsed so booleans, numbers and lists land typed. Exits 1
    with an `error: progress.sh <cmd>: ...` message on a malformed pair, a
    protected or `active.*` field, or a field repeated in `kvs`.
    """
    seen = set()
    for kv in kvs:
        if '=' not in kv:
            _fail(cmd, f"invalid field=value: {kv!r}")
        field, value = kv.split('=', 1)
        if field in PROTECTED or field.startswith('active.'):
            _fail(cmd, f"{field} is managed by other subcommands and cannot be set here")
        if field in seen:
            _fail(cmd, f"duplicate field {field!r} in args")
        seen.add(field)
        try:
            parsed = yaml.safe_load(value)
        except yaml.YAMLError:
            parsed = value
        fm[field] = parsed
