#!/usr/bin/env bash
# common.sh — shared helpers sourced by every millwright-inspector-development-machine script.
# Not meant to be executed directly.

set -euo pipefail

# Plugin root. Prefer $CLAUDE_PLUGIN_ROOT (set by Claude Code when commands run),
# fall back to discovering from this script's location for standalone invocation.
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
  MI_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
else
  MI_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
export MI_PLUGIN_ROOT

# Data root. Precedence (each step short-circuits if it produces a value):
#
# 1. $MI_DATA_ROOT — explicit per-invocation override. Set by command wrappers,
#    by the user in their shell, or by integration scripts. Highest precedence
#    because it is intentional and per-invocation.
#
# 2. $CLAUDE_PLUGIN_USER_CONFIG_data_root — set by the Claude Code plugin
#    runtime when the user configures `userConfig.data_root` at install time
#    (see plugin.json). The convention `CLAUDE_PLUGIN_USER_CONFIG_<key>` is
#    the documented Claude Code plugin pattern for exposing user config to
#    subprocess scripts. If your runtime does not set this var, `MI_DATA_ROOT`
#    or the default is used instead.
#
# 3. ./millwright-inspector relative to the current working directory
#    (default when nothing else is set).
#
# Resolved values may be relative or absolute. They are concatenated with the
# absolute project working directory when a relative value is returned, so
# every call site can rely on the result being absolute.
mi_data_root() {
  if [[ -n "${MI_DATA_ROOT:-}" ]]; then
    _mi_data_root_resolve "$MI_DATA_ROOT"
    return
  fi
  if [[ -n "${CLAUDE_PLUGIN_USER_CONFIG_data_root:-}" ]]; then
    _mi_data_root_resolve "$CLAUDE_PLUGIN_USER_CONFIG_data_root"
    return
  fi
  echo "${PWD}/millwright-inspector"
}

# Resolve a possibly-relative data root to an absolute path. Internal helper.
_mi_data_root_resolve() {
  local val="$1"
  if [[ "$val" = /* ]]; then
    echo "$val"
  else
    echo "${PWD}/${val}"
  fi
}

# Print the basename of the data root — used by the validate-on-write hook
# to test whether a Write/Edit landed under the configured workspace folder.
# Falls back to "millwright-inspector" when nothing is set.
mi_data_root_segment() {
  basename "$(mi_data_root)"
}

# Paths the millwright-inspector-development-machine operates on — always resolve via these helpers.
#
# The quest folder is now per-cycle: each /mi-run creates a fresh subfolder
# under quest/ named after the journal folders + date (the "slug"), and a
# top-level quest/active.md pointer file records which slug is currently
# active. Historical quest folders are preserved across cycles so PMs can
# query past task lists, summaries, and queue rationales.
mi_quest_dir()             { echo "$(mi_data_root)/quest"; }
mi_quest_active_pointer()  { echo "$(mi_quest_dir)/active.md"; }
mi_journal_dir()           { echo "$(mi_data_root)/journal"; }
mi_stream_dir()            { echo "$(mi_data_root)/workflow-stream"; }
mi_feature_dir()           { echo "$(mi_stream_dir)/$1"; }
mi_blueprints_current(){ echo "$(mi_feature_dir "$1")/blueprints/current"; }
mi_blueprints_history(){ echo "$(mi_feature_dir "$1")/blueprints/history"; }
mi_impl_dir()          { echo "$(mi_feature_dir "$1")/implementation"; }
mi_test_dir()          { echo "$(mi_feature_dir "$1")/test"; }

# Active-quest helpers — resolve through quest/active.md.
#
# mi_active_quest_slug — print the active slug to stdout. Exit 0 if active,
# non-zero if no active cycle (slug missing, null, or pointer absent).
mi_active_quest_slug() {
  local pointer
  pointer="$(mi_quest_active_pointer)"
  [[ -f "$pointer" ]] || return 1
  local slug
  slug="$(mi_fm_get "$pointer" slug 2>/dev/null || true)"
  [[ -n "$slug" && "$slug" != "null" && "$slug" != "~" ]] || return 1
  printf '%s' "$slug"
}

# Path of the active quest's subfolder. Errors if no cycle is active.
mi_quest_active_dir() {
  local slug
  slug="$(mi_active_quest_slug)" || mi_die "no active quest cycle (run /mi-run to start one)"
  echo "$(mi_quest_dir)/${slug}"
}

# Path of <name>.md inside the active quest folder. Errors if no cycle is active.
# Usage: mi_quest_active_file todo-list  ->  <data>/quest/<slug>/todo-list.md
mi_quest_active_file() {
  local name="${1:?name required}"
  echo "$(mi_quest_active_dir)/${name}.md"
}

# Path of progress.md for the active quest. Errors if no cycle is active.
mi_progress_file() { mi_quest_active_file progress; }

# Compute the canonical quest slug from a journal-folder list.
# Format: YYYY-MM-DD-<kebab1>+<kebab2>+...  with a 3-char hash suffix on
# collision (when quest/<slug>/ already exists). Each input folder is
# kebab-normalized via the same rules as scripts/todo.sh.
# Derive the feature-test entry's base name from the ACTIVE cycle's journal
# folders: each folder kebab-normalized, joined with '-'.
#
# This is deliberately NOT the quest slug. The slug is
# `YYYY-MM-DD-<kebab-joined-with-+>` plus an optional 3-hex collision suffix;
# its '+' join is rejected by the `^[a-z0-9][a-z0-9-]*$` feature-name pattern
# that 13 schemas enforce, and its date prefix carries no meaning in a feature
# name. What survives here is the slug's semantic part only — the journal
# folder(s) the cycle was built from — which is what the quest folder is named
# after. Keep the kebab() below in sync with mi_quest_compute_slug's.
mi_quest_feature_test_base() {
  local pointer
  pointer="$(mi_quest_active_pointer)"
  [[ -f "$pointer" ]] || mi_die "mi_quest_feature_test_base: no active quest pointer at $pointer"
  python3 - "$pointer" <<'PYEOF'
import re, sys, yaml
with open(sys.argv[1]) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n', content, re.DOTALL)
fm = (yaml.safe_load(m.group(1)) or {}) if m else {}
folders = fm.get('journal-folders') or []

def kebab(s):
    s = str(s).strip().lower()
    s = re.sub(r'[\s_]+', '-', s)
    s = re.sub(r'[^a-z0-9-]', '', s)
    s = re.sub(r'-+', '-', s).strip('-')
    return s

parts = [kebab(f) for f in folders if kebab(f)]
if not parts:
    sys.stderr.write('error: active quest declares no usable journal-folders; '
                     'cannot derive a feature-test base name\n')
    sys.exit(1)
print('-'.join(parts))
PYEOF
}

mi_quest_compute_slug() {
  [[ $# -gt 0 ]] || mi_die "mi_quest_compute_slug: at least one journal folder required"
  python3 - "$(mi_quest_dir)" "$@" <<'PYEOF'
import os, re, sys, hashlib, time
quest_root, *folders = sys.argv[1:]
def kebab(s):
    s = s.strip().lower()
    s = re.sub(r'[\s_]+', '-', s)
    s = re.sub(r'[^a-z0-9-]', '', s)
    s = re.sub(r'-+', '-', s).strip('-')
    return s
date_part = time.strftime('%Y-%m-%d')
slugs = [kebab(f) for f in folders if kebab(f)]
if not slugs:
    sys.stderr.write('error: journal folder names produced empty slug after kebab normalization\n')
    sys.exit(1)
base = f"{date_part}-{'+'.join(slugs)}"
candidate = base
if not os.path.isdir(os.path.join(quest_root, candidate)):
    print(candidate)
    sys.exit(0)
# Collision — derive a deterministic short suffix from the existing folder
# count + a microsecond salt so two parallel runs in the same instant don't
# pick the same suffix.
salt = f"{time.time_ns()}-{os.getpid()}".encode()
suffix = hashlib.sha256(salt).hexdigest()[:3]
while True:
    candidate = f"{base}-{suffix}"
    if not os.path.isdir(os.path.join(quest_root, candidate)):
        print(candidate)
        sys.exit(0)
    salt = (salt + b'.').strip()
    suffix = hashlib.sha256(salt + str(time.time_ns()).encode()).hexdigest()[:3]
PYEOF
}

# yq wrapper — all reads/writes must go through these helpers so a future
# replacement of yq with another YAML tool is a single-file change.
mi_require_yq() {
  if ! command -v yq >/dev/null 2>&1; then
    echo "error: yq is required (install via 'brew install yq' or equivalent)" >&2
    exit 2
  fi
}

# Read a frontmatter field from a markdown file.
# Usage: mi_fm_get <file> <field>
mi_fm_get() {
  mi_require_yq
  local file="$1" field="$2"
  # Accept either bare field names ("queue") or fully-qualified yq
  # paths (".queue[0]", ".active.feature", ".queue[]"). Strip a leading
  # dot if present so we never produce a "..<path>" that yq would reject
  # as "invalid input text".
  [[ "$field" == .* ]] && field="${field#.}"
  # Extract the frontmatter block, then yq the field.
  awk '/^---$/{c++; next} c==1' "$file" | yq eval ".${field}" -
}

# Set a frontmatter field in-place.
# Usage: mi_fm_set <file> <field> <value>
# Value is treated as a YAML literal (strings need to be quoted by the caller).
mi_fm_set() {
  mi_require_yq
  local file="$1" field="$2" value="$3"
  local tmp
  tmp="$(mktemp)"
  # Split frontmatter from body, edit frontmatter, restitch.
  awk 'BEGIN{c=0} /^---$/{c++; print; next} c==1{print > "/tmp/mi_fm_head"} c>1{print > "/tmp/mi_fm_body"}' "$file" >/dev/null 2>&1 || true
  # Simpler approach: use yq's frontmatter-aware mode via a pre/post split.
  python3 - "$file" "$field" "$value" <<'PYEOF' > "$tmp"
import sys, re, yaml
path, field, value = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
if not m:
    print(content, end='')
    sys.exit(0)
fm = yaml.safe_load(m.group(1)) or {}
# Coerce obvious scalar types from the CLI string.
try:
    parsed = yaml.safe_load(value)
except yaml.YAMLError:
    parsed = value
fm[field] = parsed
print('---')
print(yaml.safe_dump(fm, default_flow_style=False, sort_keys=False).rstrip())
print('---')
print(m.group(2), end='')
PYEOF
  mv "$tmp" "$file"
}

# Render a template by substituting {{TOKEN}} placeholders.
# Usage: mi_render_template <template-path> <dest-path> KEY1=VAL1 KEY2=VAL2 ...
#
# Substitutions that land inside the YAML frontmatter block are encoded as
# YAML scalars — i.e. quoted whenever the raw value contains characters that
# YAML would otherwise reinterpret (`:`, `#`, `[`, `]`, `{`, `}`, leading
# `-`/`?`/`!`, etc.). Without this, a free-form value like
# `summary=foo: bar # broken` would write a frontmatter line that fails YAML
# parsing the next time the file is read.
#
# Two ways callers can opt out of the auto-quoting:
#   1. Wrap the placeholder in YAML flow brackets in the template
#      (e.g. `features: [{{FEATURES}}]`) — values inside `[...]`/`{...}`
#      are not rewritten because the template author has already chosen
#      a flow context, and the caller is expected to pass a comma-separated
#      list of pre-validated tokens (the existing kebab-case feature pattern).
#   2. Pass the value with a leading `!RAW!` sentinel — `KEY=!RAW!literal yaml`.
#      The sentinel is stripped and the rest is interpolated verbatim. Use
#      this for values that already encode valid YAML (e.g. `null`, an
#      explicit array literal). Reserved for internal callers.
#
# Substitutions outside the frontmatter (in the body) are always literal.
mi_render_template() {
  local tmpl="$1" dest="$2"; shift 2
  mkdir -p "$(dirname "$dest")"
  python3 - "$tmpl" "$dest" "$@" <<'PYEOF'
import re, sys, yaml
tmpl_path, dest_path, *kvs = sys.argv[1:]
with open(tmpl_path) as f:
    content = f.read()

# Split frontmatter from body so we only YAML-escape inside frontmatter.
m = re.match(r'^(---\n.*?\n---)(.*)$', content, re.DOTALL)
if m:
    fm, body = m.group(1), m.group(2)
else:
    fm, body = '', content

def yaml_scalar(value):
    """Render a Python value as a YAML scalar suitable for inline placement.
    Quotes only when needed."""
    # Use yaml.safe_dump's representation of the value, then strip the
    # trailing newline. default_flow_style=True keeps it on one line.
    out = yaml.safe_dump(value, default_flow_style=True, allow_unicode=True).rstrip()
    # safe_dump wraps a single string in `... '\n` form; trim the
    # document-end marker if it appears.
    if out.endswith('\n...'):
        out = out[:-4].rstrip()
    return out

for kv in kvs:
    if '=' not in kv:
        continue
    key, val = kv.split('=', 1)
    placeholder = '{{' + key + '}}'

    # !RAW! sentinel: caller has provided literal YAML; emit verbatim.
    if val.startswith('!RAW!'):
        literal = val[5:]
        fm = fm.replace(placeholder, literal)
        body = body.replace(placeholder, literal)
        continue

    # In the body, always literal.
    body = body.replace(placeholder, val)

    # In the frontmatter, replace each occurrence one at a time so we can
    # detect whether the placeholder sits inside a YAML flow container
    # ([...] or {...}) and skip auto-quoting in that case.
    while placeholder in fm:
        idx = fm.index(placeholder)
        # Walk backwards to find the opening of any nearest flow container.
        depth_sq = depth_cu = 0
        in_flow = False
        for i in range(idx - 1, -1, -1):
            ch = fm[i]
            if ch == '\n':
                break
            if ch == ']': depth_sq += 1
            elif ch == '[':
                if depth_sq == 0: in_flow = True; break
                depth_sq -= 1
            elif ch == '}': depth_cu += 1
            elif ch == '{':
                if depth_cu == 0: in_flow = True; break
                depth_cu -= 1
        if in_flow:
            replacement = val
        else:
            replacement = yaml_scalar(val)
        fm = fm[:idx] + replacement + fm[idx + len(placeholder):]

# Fail loudly on any unsubstituted {{TOKEN}} placeholder — a leaked
# placeholder means a caller forgot a KEY=VAL pair, and downstream readers
# would treat the literal `{{...}}` as real content.
leftover = sorted(set(re.findall(r'\{\{[A-Z][A-Z0-9_]*\}\}', fm + body)))
if leftover:
    sys.stderr.write(
        f"error: {dest_path} still has unsubstituted template placeholders: "
        f"{', '.join(leftover)}\n"
    )
    sys.exit(1)

with open(dest_path, 'w') as f:
    f.write(fm + body)
PYEOF
}

# Verify that the current working tree is the one that activated the
# currently-active feature. Refuses with a clear message otherwise.
#
# When the active block is null, or when the fingerprint fields aren't
# present (cycle activated before the worktree-fingerprint change shipped),
# the function is a no-op so old in-flight cycles keep working. Once a
# cycle is re-activated (next /mi-apply-impact), the fingerprint is
# captured and the guard becomes active.
#
# Compares three things, in order of strength:
#   1. git-common-dir — must match the current worktree's common dir.
#      Mismatch means we're in a different repository entirely.
#   2. git-worktree-dir — distinguishes sibling worktrees of the same repo.
#      Mismatch means the same repo but a different `git worktree add`.
#   3. worktree-path — the literal $PWD. Falls back to this when the git
#      dirs are unavailable (rare; would mean the user moved their git dir).
#
# Exits non-zero with a guidance message on mismatch.
mi_assert_worktree_match() {
  local progress
  progress="$(mi_progress_file 2>/dev/null || true)"
  [[ -n "$progress" && -f "$progress" ]] || return 0

  local active
  active="$(mi_fm_get "$progress" active 2>/dev/null || echo "null")"
  [[ "$active" == "null" || -z "$active" ]] && return 0

  local recorded_path recorded_common recorded_wtdir
  recorded_path="$(mi_fm_get "$progress" .active.worktree-path 2>/dev/null || echo "null")"
  recorded_common="$(mi_fm_get "$progress" .active.git-common-dir 2>/dev/null || echo "null")"
  recorded_wtdir="$(mi_fm_get "$progress" .active.git-worktree-dir 2>/dev/null || echo "null")"

  # Pre-fingerprint cycle (activated before this change shipped). Skip the
  # guard so old cycles can finish; new cycles get the fingerprint at activate.
  if [[ "$recorded_path" == "null" && "$recorded_common" == "null" && "$recorded_wtdir" == "null" ]]; then
    return 0
  fi

  local current_common="" current_wtdir=""
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    current_common="$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd)"
    current_wtdir="$(cd "$(git rev-parse --git-dir)" 2>/dev/null && pwd)"
  fi

  local feature
  feature="$(mi_fm_get "$progress" .active.feature 2>/dev/null || echo "?")"

  # Strongest signal: git worktree dir mismatch. This catches sibling
  # `git worktree add` checkouts of the same repo.
  if [[ -n "$current_wtdir" && "$recorded_wtdir" != "null" && "$current_wtdir" != "$recorded_wtdir" ]]; then
    mi_die "worktree mismatch: active feature '${feature}' was activated from
       worktree:   ${recorded_path}
       git-dir:    ${recorded_wtdir}
  but this command is running in
       worktree:   ${PWD}
       git-dir:    ${current_wtdir}

  Two git worktrees appear to share the same data_root. Run mi-workflow
  commands for this active feature only from the worktree that activated
  it, or set MI_DATA_ROOT to a per-worktree path before retrying."
  fi

  # Different repository entirely.
  if [[ -n "$current_common" && "$recorded_common" != "null" && "$current_common" != "$recorded_common" ]]; then
    mi_die "repository mismatch: active feature '${feature}' belongs to
       repo:       ${recorded_common}
  but this command is running in
       repo:       ${current_common}

  This data_root is being used by a different repository. Use a separate
  data_root for this repository (set MI_DATA_ROOT or userConfig.data_root)."
  fi

  # Path-only fallback when git wasn't usable for the comparison.
  if [[ -z "$current_wtdir" && "$recorded_path" != "null" && "$PWD" != "$recorded_path" ]]; then
    mi_die "worktree mismatch: active feature '${feature}' was activated from ${recorded_path}, but this command is running from ${PWD}."
  fi
}

# Abort with a message on stderr and non-zero exit.
mi_die() {
  echo "error: $*" >&2
  exit 1
}

# Pretty-print info to stderr (keeps stdout clean for command output).
mi_info() {
  echo "mi: $*" >&2
}
