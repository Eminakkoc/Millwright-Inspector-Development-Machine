#!/usr/bin/env bash
# info-bar.sh — Claude Code statusLine renderer for the mi-workflow.
#
# Pull-only. Reads stdin JSON (Claude Code's status-line payload), anchors
# to workspace.project_dir, parses quest/active.md + progress.md once via
# a single python3 invocation, prints one line. No state, no writes, no
# logs. Always exits 0 even on error — Claude Code surfaces stderr from a
# failing statusLine command and that would visually break the prompt.
#
# Hot-path budget: ≤100ms typical (macOS python3 cold-start dominates).
# To stay there, the script avoids:
#   - mi_fm_get / scripts/internal/common.sh sourcing (mi_fm_get shells
#     to yq per field — would be 3 yq processes)
#   - quest.sh subshells
#   - pyyaml import (~30ms; not needed for the few keys we look up —
#     the hand-rolled parser below handles the schema directly)
#   - a second python3 invocation for stdin JSON parsing (kept inline in
#     the single python3 call below)
# Python is invoked with `-S -I` to skip site initialization and isolate
# from user-site packages, which shaves ~35ms off cold-start vs vanilla.
#
# Wired at install time by /mi-init-status-bar via a generated wrapper at
# .claude/mi-stage-info-bar.sh that exec's this script. Do NOT wire
# .claude/settings.json directly to this file with $CLAUDE_PLUGIN_ROOT —
# the docs confirm Claude Code does not expand that variable inside
# statusLine.command.
#
# Design reference: docs/stage-info-bar/plan.md.

set -euo pipefail

exec python3 -S -I -c '
import json, os, re, sys

STAGE_NAMES = {
    2: "blueprint",
    3: "implementation",
    4: "impl-resumed",
    5: "inspector-review",
    6: "review-session",
    7: "review-completed",
    8: "finalizing",
}

TRUNC_LIMIT = 24
TRUNC_KEEP = 22


def fail_empty():
    print("")
    sys.exit(0)


def truncate(s):
    if not s:
        return ""
    return s[:TRUNC_KEEP] + "…" if len(s) > TRUNC_LIMIT else s


def read_frontmatter_block(path):
    """Return YAML frontmatter (between the first two `---` lines) or None."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return None
    m = re.match(r"^---\s*\n(.*?)\n---\s*(?:\n|$)", text, re.DOTALL)
    return m.group(1) if m else None


def yaml_top_level(block, key):
    """RHS of `<key>: <rhs>` at column 0, or None. RHS may be empty."""
    pat = re.compile(r"^" + re.escape(key) + r":\s*(.*?)\s*$", re.MULTILINE)
    m = pat.search(block)
    return m.group(1) if m else None


def yaml_nested(block, parent, child):
    """RHS of `<child>:` indented under `<parent>:`, or None."""
    in_block = False
    pat_parent = re.compile(r"^" + re.escape(parent) + r":\s*$")
    pat_child = re.compile(r"^\s+" + re.escape(child) + r":\s*(.*?)\s*$")
    for line in block.splitlines():
        if not in_block:
            if pat_parent.match(line):
                in_block = True
        else:
            if line and not line.startswith((" ", "\t")):
                return None
            m = pat_child.match(line)
            if m:
                return m.group(1)
    return None


def render_idle():
    return "mi-workflow · idle"


def render_cycle(slug):
    return f"mi-workflow · cycle {truncate(slug)} · Stage 1 · quest generated"


def render_active(feature, stage):
    name = STAGE_NAMES.get(stage, "unknown")
    return f"mi-workflow · {truncate(feature)} · Stage {stage} · {name}"


def render_unreadable(slug):
    return f"mi-workflow · {truncate(slug)} · progress.md unreadable"


# 1. Read stdin payload.
try:
    payload = json.load(sys.stdin)
except Exception:
    fail_empty()

ws = payload.get("workspace") or {}
project_dir = ws.get("project_dir") or payload.get("cwd") or ""
if not project_dir or not os.path.isdir(project_dir):
    fail_empty()

# 2. Resolve data_root (mirrors mi_data_root, anchored to project_dir).
env = os.environ
data_root = (
    env.get("MI_DATA_ROOT")
    or env.get("CLAUDE_PLUGIN_USER_CONFIG_data_root")
    or os.path.join(project_dir, "millwright-inspector")
)
if not os.path.isabs(data_root):
    data_root = os.path.join(project_dir, data_root)

# 3. Workspace marker.
active_path = os.path.join(data_root, "quest", "active.md")
if not os.path.isfile(active_path):
    fail_empty()

# 4. Parse quest/active.md frontmatter.
active_block = read_frontmatter_block(active_path)
if active_block is None:
    print(render_idle()); sys.exit(0)

status = yaml_top_level(active_block, "status")
slug = yaml_top_level(active_block, "slug")
if status != "active" or not slug or slug in ("null", "~"):
    print(render_idle()); sys.exit(0)

# 5. Parse quest/<slug>/progress.md frontmatter.
progress_path = os.path.join(data_root, "quest", slug, "progress.md")
if not os.path.isfile(progress_path):
    print(render_cycle(slug)); sys.exit(0)

progress_block = read_frontmatter_block(progress_path)
if progress_block is None:
    print(render_unreadable(slug)); sys.exit(0)

active_top = yaml_top_level(progress_block, "active")
nested_feature = yaml_nested(progress_block, "active", "feature")
nested_stage = yaml_nested(progress_block, "active", "current-stage")

# active=null cases: literal null/~, or no nested block at all.
if (active_top in ("null", "~")) or (active_top == "" and nested_feature is None and nested_stage is None):
    print(render_cycle(slug)); sys.exit(0)

# Block exists but is missing required fields → corrupt.
if not nested_feature or nested_stage is None:
    print(render_unreadable(slug)); sys.exit(0)

try:
    stage = int(nested_stage)
except ValueError:
    print(render_unreadable(slug)); sys.exit(0)

print(render_active(nested_feature, stage))
'
