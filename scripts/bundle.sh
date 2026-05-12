#!/usr/bin/env bash
# bundle.sh — export self-contained agent-handoff briefs for the active feature.
#
# Triggered by /mo-export-bundle. Reads the workflow's canonical files
# (requirements / config / decisions / grounding-report / summary /
# todo-list / change-summary / manual-test-* / overseer-review), strips
# frontmatter and HTML scaffolding, mechanically scrubs workflow file
# paths and bare workflow .md filenames out of body text, structures the
# result under task-neutral section headers, and writes a single .md
# file under tmp/bundles/.
#
# Design reference: docs/bundle/plan.md (v3, rounds 1–8 of review).
# Section structure: §5.1–§5.18.
#
# Usage:
#   bundle.sh export
#
# Pre-flight checks (in order):
#   1. quest.sh current  — there must be an active cycle.
#   2. progress.sh get-active  — there must be an active feature.
#   3. progress.sh check-worktree  — current worktree must match the
#      worktree-path recorded in progress.md.active.
#
# Each refused state exits non-zero with a message on stderr.
#
# This script does NOT synthesize prose. It extracts and reformats.
# See docs/bundle/plan.md §2 (Principles) for the full contract.

set -euo pipefail
source "$(dirname "$0")/internal/common.sh"

cmd="${1:-}"; shift || true

case "$cmd" in
  export) ;;
  *)
    echo "usage: bundle.sh export" >&2
    exit 2
    ;;
esac

# ---------------------------------------------------------------- preconditions

# 1. Active cycle?
if ! "$MO_PLUGIN_ROOT/scripts/quest.sh" current >/dev/null 2>&1; then
  echo "Refused: no active cycle. Run /mo-init and /mo-run first." >&2
  exit 2
fi

# 2. Active feature?
feature="$("$MO_PLUGIN_ROOT/scripts/progress.sh" get-active 2>/dev/null || echo "null")"
if [[ -z "$feature" || "$feature" == "null" ]]; then
  echo "Refused: no active feature. Advance to stage 2 first (run /mo-continue or /mo-apply-impact)." >&2
  exit 2
fi

# 3. Active worktree fingerprint matches?
if ! "$MO_PLUGIN_ROOT/scripts/progress.sh" check-worktree >/dev/null 2>&1; then
  echo "Refused: invoked from a different worktree than the one that owns the active feature. Switch to the recorded worktree-path and re-run." >&2
  exit 2
fi

# 4. Read everything else we need.
data_root="$("$MO_PLUGIN_ROOT/scripts/data-root.sh")"
stage="$("$MO_PLUGIN_ROOT/scripts/progress.sh" get current-stage)"
branch="$("$MO_PLUGIN_ROOT/scripts/progress.sh" get branch 2>/dev/null || echo "")"
base_commit="$("$MO_PLUGIN_ROOT/scripts/progress.sh" get base-commit 2>/dev/null || echo "")"
worktree_path="$("$MO_PLUGIN_ROOT/scripts/progress.sh" get worktree-path)"
slug_dir="$("$MO_PLUGIN_ROOT/scripts/quest.sh" dir)"

# ------------------------------------------------------------- output anchoring

# Pin every subsequent fs/git operation to the recorded worktree.
# Without this, a slash-command invoked from a sibling worktree or shifted
# cwd would write the bundle into the wrong repo and stale-check the wrong HEAD.
cd "$worktree_path"

# Compute output path with single-retry pid suffix on second-resolution collision.
ts="$(date +%Y%m%d-%H%M%S)"
out="tmp/bundles/${feature}-stage${stage}-${ts}.md"
mkdir -p tmp/bundles
if [[ -e "$out" ]]; then
  out="tmp/bundles/${feature}-stage${stage}-${ts}-$$.md"
fi

# Self-containing gitignore: makes tmp/bundles/ ignore itself in any host repo,
# regardless of whether the project's root .gitignore covers tmp/.
gitignore="tmp/bundles/.gitignore"
gitignore_body=$'*\n!.gitignore\n'
if [[ ! -f "$gitignore" ]] || [[ "$(cat "$gitignore")" != "$gitignore_body" ]]; then
  printf '%s' "$gitignore_body" > "$gitignore"
fi

# Capture live HEAD for §5.14 staleness comparison. cd above already pinned cwd
# to the recorded worktree, so this hits the correct repo unconditionally.
head_sha="$(git rev-parse HEAD 2>/dev/null || echo "")"

# ----------------------------------------------------------------- compose

# Source paths (some may not exist yet — Python checks each).
requirements_md="$data_root/workflow-stream/$feature/blueprints/current/requirements.md"
config_md="$data_root/workflow-stream/$feature/blueprints/current/config.md"
decisions_md="$data_root/workflow-stream/$feature/decisions.md"
grounding_md="$data_root/workflow-stream/$feature/implementation/grounding-report.md"
change_summary_md="$data_root/workflow-stream/$feature/implementation/change-summary.md"
manual_plan_md="$data_root/workflow-stream/$feature/test/manual-test-plan.md"
manual_results_md="$data_root/workflow-stream/$feature/test/manual-test-results.md"
overseer_review_md="$data_root/workflow-stream/$feature/implementation/overseer-review.md"
summary_md="$slug_dir/summary.md"
todo_list_md="$slug_dir/todo-list.md"

# ISO-ish human-readable timestamp for the §5.18 footer.
human_ts="$(date '+%Y-%m-%d %H:%M:%S %z')"

python3 - \
  "$out" \
  "$feature" \
  "$stage" \
  "$human_ts" \
  "$base_commit" \
  "$head_sha" \
  "$requirements_md" \
  "$config_md" \
  "$decisions_md" \
  "$grounding_md" \
  "$change_summary_md" \
  "$manual_plan_md" \
  "$manual_results_md" \
  "$overseer_review_md" \
  "$summary_md" \
  "$todo_list_md" \
<<'PYEOF'
import os
import re
import sys

import yaml

(
    OUT_PATH,
    FEATURE,
    STAGE_STR,
    HUMAN_TS,
    ACTIVE_BASE,
    ACTIVE_HEAD,
    REQUIREMENTS_MD,
    CONFIG_MD,
    DECISIONS_MD,
    GROUNDING_MD,
    CHANGE_SUMMARY_MD,
    MANUAL_PLAN_MD,
    MANUAL_RESULTS_MD,
    OVERSEER_REVIEW_MD,
    SUMMARY_MD,
    TODO_LIST_MD,
) = sys.argv[1:17]

try:
    STAGE = int(STAGE_STR)
except (TypeError, ValueError):
    STAGE = -1

# ===========================================================================
# §8.2 helpers — chrome stripping + body scrubbing + section extraction
# ===========================================================================

def read_file(path):
    """Return file contents as text, or '' if missing/unreadable."""
    if not path or not os.path.isfile(path):
        return ""
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def strip_frontmatter(text):
    """Remove a leading ---\\n…\\n--- block. Returns the body (frontmatter dropped)."""
    if not text:
        return ""
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n?", text, re.DOTALL)
    return text[m.end():] if m else text


def parse_frontmatter(text):
    """Return the parsed YAML frontmatter as a dict, or {} if absent/invalid."""
    if not text:
        return {}
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n?", text, re.DOTALL)
    if not m:
        return {}
    try:
        data = yaml.safe_load(m.group(1)) or {}
        return data if isinstance(data, dict) else {}
    except yaml.YAMLError:
        return {}


def strip_html_comments(text):
    """Remove every <!-- … --> span (multi-line capable)."""
    if not text:
        return ""
    return re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL)


# Lines that are pure template scaffolding (placeholders that survive the
# template-render pass but are not real content). Conservative — only literal
# strings are matched, not anything that *contains* angle brackets.
_PLACEHOLDER_LINE_RES = [
    re.compile(r"^\s*-?\s*\*\*YYYY-MM-DD\*\*"),
    re.compile(r"^\s*<.*>\s*$"),  # entire line is angle-bracketed placeholder
]


def strip_template_placeholders(text):
    out = []
    for line in text.splitlines():
        if any(p.match(line) for p in _PLACEHOLDER_LINE_RES):
            continue
        out.append(line)
    return "\n".join(out)


def normalize_blanks(text):
    """Collapse runs of blank lines and trim leading/trailing whitespace."""
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip("\n")


# Body-scrub table — canonical regex/replacement set per §8.2.
# Order matters: longer/more-specific patterns run first so they win against
# the bare-filename pattern when the filename is part of a workflow path.
BODY_SCRUB_TABLE = [
    # Workflow-relative path prefixes (no overlap with typical project layouts).
    (re.compile(r"\bworkflow-stream/[A-Za-z0-9_./-]+"),               "<internal path>"),
    (re.compile(r"\bquest/[A-Za-z0-9_./-]+"),                         "<internal path>"),
    (re.compile(r"\bblueprints/current/[A-Za-z0-9_./-]+"),            "<internal path>"),
    (re.compile(r"\bblueprints/history/v\d+/[A-Za-z0-9_./-]+"),       "<internal path>"),
    # Workflow files when referenced under their typical implementation/ prefix.
    # Tightened from "any .md under implementation/" to known workflow files
    # only — so legitimate project files like implementation/CartService.ts
    # or implementation/MyProjectDoc.md pass through unchanged.
    (re.compile(
        r"\bimplementation/(?:grounding-report|change-summary|"
        r"manual-test-plan|manual-test-results|review-context|"
        r"overseer-review)\.md\b"
    ),                                                                "<an internal record>"),
    # Manual-test artifacts under their new feature-permanent test/ prefix
    # (the implementation/ entry above stays so legacy bundles referencing
    # archived-history paths still scrub correctly).
    (re.compile(
        r"\btest/(?:manual-test-plan|manual-test-results)\.md\b"
    ),                                                                "<an internal record>"),
    # Bare workflow .md filenames anywhere — catches references without a
    # recognized prefix (e.g., a decision bullet that says "see decisions.md").
    (re.compile(
        r"\b(?:progress|requirements|config|decisions|summary|"
        r"todo-list|change-summary|grounding-report|overseer-review|"
        r"review-context|primer|manual-test-plan|"
        r"manual-test-results)\.md\b"
    ),                                                                "<an internal record>"),
]


def scrub_body_paths(text):
    """Apply BODY_SCRUB_TABLE in order. Pure substitution, not synthesis."""
    if not text:
        return ""
    for pattern, replacement in BODY_SCRUB_TABLE:
        text = pattern.sub(replacement, text)
    return text


def clean_body(text):
    """Run the universal body contract: strip chrome, then scrub paths."""
    return scrub_body_paths(
        normalize_blanks(
            strip_template_placeholders(
                strip_html_comments(strip_frontmatter(text))
            )
        )
    )


def extract_section(text, heading_text, level=2):
    """Return the body under a `## <heading_text>` heading until the next
    same-or-higher-level heading, or EOF. Returns '' if not found."""
    if not text:
        return ""
    # Match the exact heading line; allow trailing whitespace.
    hash_marks = "#" * level
    pattern = re.compile(
        r"^" + re.escape(hash_marks) + r"\s+" + re.escape(heading_text) + r"\s*$",
        re.MULTILINE,
    )
    m = pattern.search(text)
    if not m:
        return ""
    start = m.end()
    # Find the next heading at the same level or higher.
    rest = text[start:]
    # Acceptable sibling-or-parent: ^#{1..level} <space>
    next_re = re.compile(r"^#{1," + str(level) + r"}\s", re.MULTILINE)
    n = next_re.search(rest)
    body = rest if n is None else rest[: n.start()]
    return body.strip("\n")


# Real-bullet detection: a line that is "- <something>" where <something> is
# not a pure template placeholder. Used by §5.11 emptiness detection.
_BULLET_RE = re.compile(r"^\s*-\s+(\S.*)$")
_BULLET_PLACEHOLDER_RES = [
    re.compile(r"^\*\*YYYY-MM-DD\*\*"),
    re.compile(r"^<.*>$"),  # entire bullet body is angle-bracketed placeholder
]


def count_real_bullets(text):
    if not text:
        return 0
    n = 0
    for line in text.splitlines():
        m = _BULLET_RE.match(line)
        if not m:
            continue
        body = m.group(1).strip()
        if any(p.match(body) for p in _BULLET_PLACEHOLDER_RES):
            continue
        n += 1
    return n


# ===========================================================================
# Section emitters (§5.1–§5.18)
# ===========================================================================

def emit_prompt_block(feature):
    """§5.1 — top prompt block, always emitted. Slug verbatim per round-7."""
    return (
        f"# {feature} — agent handoff brief\n"
        "\n"
        "> You are picking up work on a software feature. This document is\n"
        "> self-contained: every fact you need to act is below. Do not assume\n"
        "> access to files, repositories, or systems referenced inside any\n"
        "> quoted material — only the prose in this brief is reliable.\n"
        ">\n"
        "> This brief was *extracted* from project planning records, not\n"
        "> rewritten. Internal file paths and record names have been replaced\n"
        "> with placeholders (`<internal path>`, `<an internal record>`); if\n"
        "> you see those, you do not have access to what they refer to — ask\n"
        "> the human if it matters.\n"
        ">\n"
        "> Some bullets may still use technical phrasing or refer to roles or\n"
        "> tooling from the originating system. Read such phrasing charitably\n"
        "> as natural language; nothing in this brief depends on you knowing\n"
        "> what those terms mean.\n"
        ">\n"
        "> If you need to inspect specific code, diffs, or diagrams, ask the\n"
        "> human who shared this brief; this document does not include them.\n"
        ">\n"
        "> If you are asked to review the work, focus on the \"Requirements\n"
        "> and constraints\", \"Out of scope\", and \"Open review findings\"\n"
        "> sections. If you are asked to continue the work, focus on \"What\n"
        "> the next agent should do\".\n"
    )


def emit_custom_instructions(config_text):
    """§5.2 — config.md → ## Overseer Additions. Heading replaced."""
    body = extract_section(strip_html_comments(strip_frontmatter(config_text)),
                           "Overseer Additions")
    body = scrub_body_paths(normalize_blanks(strip_template_placeholders(body)))
    if not body.strip():
        return ""
    return "## Custom project instructions\n\n" + body + "\n"


def emit_project_wide_constraints(summary_text):
    """§5.3 — summary.md → ## Cross-cutting constraints."""
    body = extract_section(strip_html_comments(strip_frontmatter(summary_text)),
                           "Cross-cutting constraints")
    body = scrub_body_paths(normalize_blanks(strip_template_placeholders(body)))
    if not body.strip():
        return ""
    return "## Project-wide constraints\n\n" + body + "\n"


def emit_feature_background(summary_text, feature):
    """§5.4 — summary.md → ## Feature: <active_feature>."""
    body = extract_section(strip_html_comments(strip_frontmatter(summary_text)),
                           f"Feature: {feature}")
    body = scrub_body_paths(normalize_blanks(strip_template_placeholders(body)))
    if not body.strip():
        return ""
    return "## Feature background\n\n" + body + "\n"


def emit_implementation_rules(config_text):
    """§5.5 — config.md → ## Rules. Strip the `; path: …` suffix per entry."""
    body = extract_section(strip_html_comments(strip_frontmatter(config_text)),
                           "Rules")
    body = strip_template_placeholders(body)
    out_lines = []
    for line in body.splitlines():
        if not line.strip():
            continue
        # Match a bullet, drop the trailing "; path: ..." if present.
        m = re.match(r"^(\s*-\s+.*?)(\s*;\s*path:\s*\.claude/rules/[^\s]+)?\s*$", line)
        if m:
            cleaned = m.group(1).rstrip()
            out_lines.append(cleaned)
        else:
            out_lines.append(line)
    body = scrub_body_paths(normalize_blanks("\n".join(out_lines)))
    if not body.strip():
        return ""
    return "## Implementation rules to follow\n\n" + body + "\n"


def emit_objective(requirements_text):
    """§5.6 — first paragraph of requirements.md body. Omit if no leading paragraph."""
    body = strip_html_comments(strip_frontmatter(requirements_text))
    # Drop the leading `# Requirements — <feature>` H1 if present.
    body = re.sub(r"^#\s+Requirements\s+—.*?\n", "", body, count=1)
    body = strip_template_placeholders(body).strip("\n")
    if not body:
        return ""
    # First paragraph = lines until first blank line OR first heading.
    para_lines = []
    for line in body.splitlines():
        if not line.strip():
            break
        if line.lstrip().startswith("#"):
            break
        para_lines.append(line)
    if not para_lines:
        return ""
    para = scrub_body_paths("\n".join(para_lines).strip())
    if not para:
        return ""
    return "## Objective\n\n" + para + "\n"


def parse_todo_list_feature_section(todo_text, feature):
    """Return [(item_id, state, description), ...] for the active feature.

    Real todo-list.md format (per `templates/todo-list.md.tmpl`):
        - [x] (assignee) <STATE> — <ITEM-ID>: <description>
    where <STATE> is one of TODO / PENDING / IMPLEMENTING / IMPLEMENTED /
    CANCELED. The state word is bare (not bracketed); the leading `[ ]` /
    `[x]` is the selection checkbox. Parser is permissive — best-effort if
    the format drifts.
    """
    rows = []
    section = extract_section(strip_html_comments(strip_frontmatter(todo_text)),
                              feature)
    if not section:
        return rows
    # State word followed by em-dash or hyphen-dash (the bullet's description
    # separator). Anchored on the dash so we don't false-match the word
    # appearing inside the description text.
    state_re = re.compile(
        r"\b(PENDING|IMPLEMENTING|CANCELED|IMPLEMENTED|TODO)\b\s*[—-]"
    )
    id_re = re.compile(r"\b([A-Z][A-Z0-9]+-\d+)\b")
    for line in section.splitlines():
        if not line.lstrip().startswith("-"):
            continue
        sm = state_re.search(line)
        im = id_re.search(line)
        if not im:
            continue
        item_id = im.group(1)
        state = sm.group(1) if sm else ""
        # Description = everything after the item-id, stripped of leading
        # punctuation that introduces it (`:` or `—` typically).
        tail = line[im.end():].lstrip(" —-:|")
        # Drop a trailing assignee tag like "(@alice)" if it landed at the end.
        tail = re.sub(r"\s*\(@[^)]+\)\s*$", "", tail).rstrip()
        rows.append((item_id, state, tail))
    return rows


def emit_scope(requirements_text, todo_text, feature):
    """§5.7 — dual-source: requirements.md → todo-item-ids ∪ todo-list IMPLEMENTING.

    Deduplicate by id (source 1 first, source 2 second). Drop CANCELED.
    """
    fm = parse_frontmatter(requirements_text)
    src1_ids = []
    raw_ids = fm.get("todo-item-ids") if fm else None
    if isinstance(raw_ids, list):
        for x in raw_ids:
            s = str(x).strip()
            if s:
                src1_ids.append(s)
    rows = parse_todo_list_feature_section(todo_text, feature)
    by_id = {item_id: (state, desc) for item_id, state, desc in rows}
    src2_ids = [item_id for item_id, state, _ in rows if state == "IMPLEMENTING"]

    # Union with order: source 1 first preserving frontmatter order, then any
    # source 2 ids not already in source 1, preserving todo-list order.
    seen = set()
    ordered = []
    for x in src1_ids + src2_ids:
        if x in seen:
            continue
        seen.add(x)
        ordered.append(x)

    bullets = []
    for item_id in ordered:
        info = by_id.get(item_id)
        if info is None:
            bullets.append(f"- (item {item_id}) — description not found in todo list.")
            continue
        state, desc = info
        if state == "CANCELED":
            continue  # explicit removal from active scope
        if not desc:
            desc = "(no description recorded)"
        bullets.append(f"- {desc} (item {item_id}).")

    body = scrub_body_paths("\n".join(bullets).strip())
    if not body:
        return ""
    return "## Scope in this session\n\n" + body + "\n"


def emit_requirements(requirements_text):
    """§5.8 — requirements.md → ## Goals (this cycle). Drop the workflow heading."""
    body = extract_section(strip_html_comments(strip_frontmatter(requirements_text)),
                           "Goals (this cycle)")
    body = scrub_body_paths(normalize_blanks(strip_template_placeholders(body)))
    if not body.strip():
        return ""
    return "## Requirements and constraints\n\n" + body + "\n"


def emit_planned(requirements_text):
    """§5.9 — requirements.md → ## Planned (future cycles)."""
    body = extract_section(strip_html_comments(strip_frontmatter(requirements_text)),
                           "Planned (future cycles)")
    body = scrub_body_paths(normalize_blanks(strip_template_placeholders(body)))
    if not body.strip():
        return ""
    return (
        "## Planned for future work\n\n"
        "The implementation must keep architectural room for the following "
        "items, which will be delivered in later cycles (not in this session):\n\n"
        + body + "\n"
    )


def emit_out_of_scope(requirements_text):
    """§5.10 — requirements.md → ## Non-goals (out of scope)."""
    body = extract_section(strip_html_comments(strip_frontmatter(requirements_text)),
                           "Non-goals (out of scope)")
    body = scrub_body_paths(normalize_blanks(strip_template_placeholders(body)))
    if not body.strip():
        return ""
    return "## Out of scope\n\n" + body + "\n"


def _keep_bullets_only(text):
    """Return only top-level bullets and their indented continuation lines.

    Drops any prose paragraph, file-purpose preamble, or explanatory text
    that appears between bullets. A "continuation" is any line that starts
    with whitespace AND immediately follows a bullet or another continuation.
    """
    if not text:
        return ""
    out = []
    in_bullet = False
    for line in text.splitlines():
        stripped = line.lstrip()
        if not stripped:
            # Blank line: terminate the current bullet group.
            if in_bullet:
                out.append("")
            in_bullet = False
            continue
        if stripped.startswith("-"):
            out.append(line)
            in_bullet = True
            continue
        if in_bullet and (line.startswith(" ") or line.startswith("\t")):
            out.append(line)
            continue
        # Non-bullet, non-continuation line — drop it (preamble or stray prose).
        in_bullet = False
    return "\n".join(out)


def emit_decisions(decisions_text):
    """§5.11 — decisions.md, real-bullet count gate, drop stage section headings.

    Filters to bullets only — the template ships with a descriptive preamble
    paragraph that explains the file's purpose to internal readers; that
    prose has no value to the receiving agent.
    """
    body = strip_html_comments(strip_frontmatter(decisions_text))
    # Drop the leading `# Decisions — <feature>` H1 if present.
    body = re.sub(r"^#\s+Decisions\s+—.*?\n", "", body, count=1)
    # Drop every `## Stage <N> — …` heading line (keep the bullets under it).
    body = re.sub(r"^##\s+Stage\s+\d+\s+—.*?\n", "", body, flags=re.MULTILINE)
    body = strip_template_placeholders(body)
    body = _keep_bullets_only(body)
    if count_real_bullets(body) == 0:
        return ""
    body = scrub_body_paths(normalize_blanks(body))
    return "## Decisions already made\n\n" + body + "\n"


def emit_existing_system(grounding_text):
    """§5.12 — grounding-report.md, per-item bullets verbatim, no aggregation."""
    body = strip_html_comments(strip_frontmatter(grounding_text))
    body = re.sub(r"^#\s+Codebase-grounding\s+report.*?\n", "", body, count=1)
    body = strip_template_placeholders(body)

    per_item = extract_section(body, "Per-item findings")
    overall = extract_section(body, "Overall seam summary")

    out_blocks = []

    # Per-item: split on `### <ITEM-ID> — <description>` sub-headings.
    if per_item.strip():
        chunks = re.split(r"^###\s+", per_item, flags=re.MULTILINE)
        for chunk in chunks:
            chunk = chunk.strip()
            if not chunk:
                continue
            # First line is the heading text "<ITEM-ID> — <description>".
            head, _, rest = chunk.partition("\n")
            head = head.strip()
            rest = rest.strip()
            if not rest:
                continue
            out_blocks.append(f"- **Item {head}**\n" + _indent_bullets(rest))

    if overall.strip():
        out_blocks.append("- **Overall:**\n" + _indent_bullets(overall.strip()))

    if not out_blocks:
        return ""

    body = scrub_body_paths("\n\n".join(out_blocks))
    return (
        "## Existing system context\n\n"
        "The implementation builds on the following pre-existing parts of the "
        "codebase:\n\n"
        + body + "\n"
    )


def _indent_bullets(text):
    """Indent every non-empty line by two spaces (sub-bullet under a parent)."""
    return "\n".join(("  " + line) if line.strip() else "" for line in text.splitlines())


def _change_summary_range(change_text):
    """Return (recorded_base, recorded_head) from change-summary.md frontmatter."""
    fm = parse_frontmatter(change_text)
    return (fm.get("base-commit", "") or "", fm.get("head", "") or "")


def emit_implementation_summary(change_text):
    """§5.13 — change-summary.md → ## Detected entrypoints + ## Suspected flows."""
    base = strip_html_comments(strip_frontmatter(change_text))
    entrypoints = extract_section(base, "Detected entrypoints").strip()
    flows = extract_section(base, "Suspected flows").strip()

    parts = []
    if entrypoints:
        parts.append("**Entrypoints introduced or modified**\n\n" + entrypoints)
    if flows:
        parts.append("**End-to-end flows**\n\n" + flows)
    if not parts:
        return ""
    body = scrub_body_paths(normalize_blanks("\n\n".join(parts)))
    return "## Implementation summary\n\n" + body + "\n"


def _split_changed_files(section_body):
    """Return (annotated, unannotated) lists of (path_with_counts, purpose)."""
    annotated = []
    unannotated = []
    if not section_body:
        return annotated, unannotated
    # Match a top-level bullet that looks like a file row. The change-summary
    # template formats rows as either:
    #   - <path> (+adds/-dels): <purpose>
    #   - <status> <path> (+adds/-dels): <purpose>
    # Some authors group under area sub-bullets — we still pick rows that
    # contain a "(+adds/-dels)" marker.
    row_re = re.compile(r"^\s*-\s+(.*?\([+-]?\d+/[+-]?\d+\))(\s*:\s*(.+))?\s*$")
    for line in section_body.splitlines():
        m = row_re.match(line)
        if not m:
            continue
        head = m.group(1).strip()
        purpose = (m.group(3) or "").strip()
        if purpose:
            annotated.append((head, purpose))
        else:
            unannotated.append(head)
    return annotated, unannotated


def emit_changed_areas(change_text, active_base, active_head):
    """§5.14 — annotated/unannotated split + staleness warning."""
    if not change_text.strip():
        return ""
    body = strip_html_comments(strip_frontmatter(change_text))
    section = extract_section(body, "Changed files")
    annotated, unannotated = _split_changed_files(section)
    if not annotated and not unannotated:
        return ""

    rec_base, rec_head = _change_summary_range(change_text)
    stale = (rec_base and active_base and rec_base != active_base) or \
            (rec_head and active_head and rec_head != active_head)

    parts = ["## Changed areas\n"]
    if stale:
        parts.append(
            f"> ⚠ The change summary below was generated for an earlier commit "
            f"range and may not reflect the latest commits. Recorded range: "
            f"`{rec_base}..{rec_head}`. Current range: `{active_base}..{active_head}`.\n"
        )

    if annotated:
        for head, purpose in annotated:
            parts.append(f"- {head}: {purpose}.")
    if unannotated:
        if annotated:
            parts.append("")
        parts.append(
            "Changed but purpose not annotated. Ask the human if these matter "
            "for your task:\n"
        )
        for head in unannotated:
            parts.append(f"- {head}")

    body = scrub_body_paths(normalize_blanks("\n".join(parts)))
    return body + "\n"


def emit_tests(plan_text, results_text):
    """§5.15 — manual-test-plan / manual-test-results, optional and independent."""
    plan_body = strip_html_comments(strip_frontmatter(plan_text)).strip()
    results_body = strip_html_comments(strip_frontmatter(results_text)).strip()
    if not plan_body and not results_body:
        return ""
    parts = ["## Tests run / manual checks\n"]
    if plan_body:
        parts.append("**Planned manual checks**\n\n" + plan_body)
    if results_body:
        if plan_body:
            parts.append("")
        parts.append("**Results**\n\n" + results_body)
    body = scrub_body_paths(normalize_blanks("\n\n".join(parts)))
    return body + "\n"


def _split_findings_block(review_body):
    """Return (preamble_dropped_body) — strips the workflow pre-amble.

    The pre-amble is everything before `## Implementation Review`; if the
    heading is absent, the whole file is treated as preamble (no findings).
    """
    m = re.search(r"^##\s+Implementation Review\s*$", review_body, re.MULTILINE)
    if not m:
        return ""
    return review_body[m.end():].strip("\n")


def _parse_ir_blocks(under_review):
    """Yield (summary, severity, scope, status, details) for each IR-NNN block."""
    # Split by "### IR-..." headings.
    parts = re.split(r"^###\s+", under_review, flags=re.MULTILINE)
    for chunk in parts:
        chunk = chunk.strip()
        if not chunk.startswith("IR-"):
            continue
        # First line: "IR-NNN — <summary>"
        head, _, rest = chunk.partition("\n")
        head = head.strip()
        m = re.match(r"^IR-\d+\s+—\s*(.*)$", head)
        summary = m.group(1).strip() if m else head
        # Parse the YAML-style key:value lines until "details:" or end.
        severity = scope = status = details = ""
        in_details = False
        details_lines = []
        for line in rest.splitlines():
            if in_details:
                # details: | block continues until a non-indented line.
                if line and not line.startswith((" ", "\t")):
                    in_details = False
                else:
                    details_lines.append(line.lstrip())
                    continue
            stripped = line.strip()
            if not stripped:
                continue
            if not stripped.startswith("-"):
                continue
            kv = re.match(r"^-\s+(\w[\w-]*)\s*:\s*(.*)$", stripped)
            if not kv:
                continue
            key, value = kv.group(1), kv.group(2).strip()
            if key == "severity":
                severity = value
            elif key == "scope":
                scope = value
            elif key == "status":
                status = value
            elif key == "details":
                if value == "|":
                    in_details = True
                else:
                    details = value
        if details_lines and not details:
            details = "\n".join(details_lines).strip()
        yield summary, severity, scope, status, details


def _freeform_paragraphs(under_review):
    """Yield freeform paragraphs (text not part of any ### IR-NNN block)."""
    # Drop everything from the first "### IR-" heading onward — only keep
    # text before any IR-NNN sub-block.
    parts = re.split(r"^###\s+IR-", under_review, maxsplit=1, flags=re.MULTILINE)
    head = parts[0]
    text = head.strip()
    if not text:
        return
    # Split on blank lines.
    for para in re.split(r"\n\s*\n", text):
        para = para.strip()
        if para:
            yield para


def emit_open_findings(review_text):
    """§5.16 — overseer-review.md, gate on (open IR OR freeform), keep scope:."""
    body = strip_html_comments(strip_frontmatter(review_text))
    under = _split_findings_block(body)
    if not under:
        return ""

    structured_bullets = []
    has_real_scope = False
    for summary, severity, scope, status, details in _parse_ir_blocks(under):
        if status != "open":
            continue
        # Build the bullet body: details first, then "Recommended action".
        det = details.strip()
        sev = severity.strip() or "unspecified"
        if scope:
            action = scope
            has_real_scope = True
        else:
            action = "not specified"
        line = f"- **{summary}** ({sev}): {det} — Recommended action: {action}."
        structured_bullets.append(line)

    freeform_bullets = []
    for para in _freeform_paragraphs(under):
        # Skip stuff that is only whitespace or only a heading marker.
        if para.lstrip().startswith("###") or para.lstrip().startswith("##"):
            continue
        freeform_bullets.append(f"- *(unclassified)*: {para.replace(chr(10), ' ')}")

    if not structured_bullets and not freeform_bullets:
        return ""

    parts = ["## Open review findings\n"]
    parts.extend(structured_bullets)
    if structured_bullets and freeform_bullets:
        parts.append("")
    parts.extend(freeform_bullets)

    if has_real_scope:
        parts.append("")
        parts.append(
            "> _**Action labels.** \"fix\" = patch existing code, smallest "
            "change. \"re-implement\" = redo the implementation against the "
            "existing plan and spec. \"re-plan\" = revise the plan, then "
            "re-implement. \"re-spec\" = revise the spec/design, then re-plan "
            "and re-implement._"
        )

    body = scrub_body_paths(normalize_blanks("\n".join(parts)))
    return body + "\n"


# §5.17 stage→action paragraph
_ACTION_TABLE = {
    2: "Review the requirements above and continue implementing the listed scope. Surface clarifying questions before writing code.",
    3: "Review the requirements above and continue implementing the listed scope. Surface clarifying questions before writing code.",
    4: "Review the implementation against the requirements. Note discrepancies under 'Open review findings' format.",
    5: "Review the implementation against the requirements. Note discrepancies under 'Open review findings' format.",
    6: "Address the open review findings in priority order (blockers first). For each, propose the smallest change that resolves the finding without expanding scope.",
    7: "The cycle is wrapping up. Validate that every open finding is closed and the changed areas match the requirements.",
    8: "The cycle is wrapping up. Validate that every open finding is closed and the changed areas match the requirements.",
}


def emit_action_paragraph(stage):
    line = _ACTION_TABLE.get(stage, "Continue this work in whatever direction the human guides you.")
    return "## What the next agent should do\n\n" + line + "\n"


# §5.18 stage→phase label
_PHASE_TABLE = {
    2: "during planning",
    3: "during implementation",
    4: "post-implementation, before review",
    5: "post-implementation, before review",
    6: "during review",
    7: "review complete, finalizing",
    8: "review complete, finalizing",
}


def phase_label(stage):
    return _PHASE_TABLE.get(stage, "in progress")


def emit_sources_footer(feature, stage, human_ts):
    return (
        "---\n"
        "\n"
        "> _This brief was extracted from project planning and review records "
        f"for feature **{feature}** **{phase_label(stage)}** on "
        f"**{human_ts}**. The originals (not included): planning records, "
        "codebase-context audit, change index, manual verification plan and "
        "results, and any open review findings. The brief above is an "
        "extract; the originals remain authoritative._\n"
    )


# ===========================================================================
# Compose
# ===========================================================================

requirements_text = read_file(REQUIREMENTS_MD)
config_text = read_file(CONFIG_MD)
decisions_text = read_file(DECISIONS_MD)
grounding_text = read_file(GROUNDING_MD)
change_text = read_file(CHANGE_SUMMARY_MD)
plan_text = read_file(MANUAL_PLAN_MD)
results_text = read_file(MANUAL_RESULTS_MD)
review_text = read_file(OVERSEER_REVIEW_MD)
summary_text = read_file(SUMMARY_MD)
todo_text = read_file(TODO_LIST_MD)

sections = []
sections.append(emit_prompt_block(FEATURE))                                 # §5.1
sections.append(emit_custom_instructions(config_text))                       # §5.2
sections.append(emit_project_wide_constraints(summary_text))                 # §5.3
sections.append(emit_feature_background(summary_text, FEATURE))              # §5.4
sections.append(emit_implementation_rules(config_text))                      # §5.5
sections.append(emit_objective(requirements_text))                           # §5.6
sections.append(emit_scope(requirements_text, todo_text, FEATURE))           # §5.7
sections.append(emit_requirements(requirements_text))                        # §5.8
sections.append(emit_planned(requirements_text))                             # §5.9
sections.append(emit_out_of_scope(requirements_text))                        # §5.10
sections.append(emit_decisions(decisions_text))                              # §5.11
sections.append(emit_existing_system(grounding_text))                        # §5.12
sections.append(emit_implementation_summary(change_text))                    # §5.13
sections.append(emit_changed_areas(change_text, ACTIVE_BASE, ACTIVE_HEAD))   # §5.14
sections.append(emit_tests(plan_text, results_text))                         # §5.15
sections.append(emit_open_findings(review_text))                             # §5.16
sections.append(emit_action_paragraph(STAGE))                                # §5.17
sections.append(emit_sources_footer(FEATURE, STAGE, HUMAN_TS))               # §5.18

bundle = "\n".join(s for s in sections if s).strip("\n") + "\n"

with open(OUT_PATH, "w", encoding="utf-8") as f:
    f.write(bundle)
PYEOF

# Final report.
size_bytes="$(wc -c < "$out" | tr -d ' ')"
size_kb="$(awk "BEGIN { printf \"%.1f\", $size_bytes / 1024 }")"
tokens_est=$(( size_bytes / 4 ))
printf 'Wrote %s (%s KB, ~%s tokens)\n' "$out" "$size_kb" "$tokens_est"
printf 'Tip: open it in your editor, or `cat` it to copy into another session.\n'
