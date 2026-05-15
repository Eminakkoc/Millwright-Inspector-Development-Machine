#!/usr/bin/env bash
# blueprints.sh — manage workflow-stream/<feature>/blueprints/.
#
# Usage:
#   blueprints.sh ensure-current <feature>       # create blueprints/current/ + diagrams/,
#                                                # mint the feature folder's id.md, and link
#                                                # it into the active quest's reference.md
#   blueprints.sh rotate <feature> \
#     --reason-kind <kind> \
#     --reason-summary <text>                    # move current/ into history/v[N+1]/;
#                                                # write reason.md; prints N+1.
#                                                # Resumable: if a v[K].partial/
#                                                # exists with the same reason kind,
#                                                # resume it instead of starting a fresh
#                                                # rotation. Forward path publishes via
#                                                # .partial.tmp → .partial → vN so a
#                                                # session break never strands current/
#                                                # contents in an unidentified partial.
#                                                # Refuses on multiple partials, on
#                                                # finalized vN/ missing reason.md, and
#                                                # on partials whose kind doesn't match.
#   blueprints.sh resume-partial <feature> \
#     --expected-kind <kind>                     # Resume the unique partial under
#                                                # history/ when its reason.kind matches
#                                                # --expected-kind. Errors on missing
#                                                # partial, multiple partials, kind
#                                                # mismatch, or unrecoverable shapes.
#                                                # Used by /mi-update-blueprint and
#                                                # /mi-complete-workflow when their
#                                                # top-of-command branches detect a
#                                                # resumable partial that matches the
#                                                # caller's intent.
#   blueprints.sh preserve-inspector-sections \
#     <feature> <from-version>                   # copy ## GIT BRANCH and
#                                                # ## Inspector Additions bodies from
#                                                # history/v<from-version>/config.md
#                                                # into current/config.md (headings
#                                                # stay; only bodies are replaced).
#                                                # Idempotent. Use after rotate +
#                                                # regenerate to keep inspector-authored
#                                                # sections alive across rotations.
#   blueprints.sh check-current [--require-primer] <feature>
#                                                # Inspect blueprints/current/<feature>/
#                                                # for completeness. Returns:
#                                                #   0 — complete (requirements.md valid,
#                                                #       config.md valid, diagrams/README.md
#                                                #       valid + requirements-id matches,
#                                                #       at least one use-case-*.puml).
#                                                #       With --require-primer: also primer.md
#                                                #       valid + requirements-id matches.
#                                                #   1 — empty (req AND config both missing
#                                                #       AND diagrams/ missing or scaffold-only).
#                                                #       Missing primer in --require-primer mode
#                                                #       does NOT promote empty to partial.
#                                                #   2 — partial (anything in between, including
#                                                #       --require-primer + missing/invalid primer).
#                                                # Sequence and structural diagrams are NOT
#                                                # required here; the spec calls them conditional.
#                                                # The inspector verifies flow coverage at the
#                                                # stage-2 review gate.
#   blueprints.sh branch-status <feature>        # Inspect config.md's ## GIT BRANCH section.
#                                                # Prints one of:
#                                                #   set    — exactly one non-trunk branch
#                                                #   unset  — section empty or absent
#                                                #   trunk  — exactly one branch but it's main/master
#                                                #   multi  — two or more candidate branches
#                                                # Used by /mi-plan-implementation for branch
#                                                # validation; check-current does not gate on it.
#
# Valid --reason-kind values:
#   completion | spec-update | re-spec-cascade | re-plan-cascade | manual
# See schemas/reason.schema.yaml for the authoritative enum.

set -euo pipefail
source "$(dirname "$0")/internal/common.sh"

cmd="${1:-}"; shift || true

case "$cmd" in
  ensure-current)
    feature="${1:?feature required}"
    current="$(mi_blueprints_current "$feature")"
    mkdir -p "$current/diagrams"
    # Mint the feature folder's id.md (if missing) and link its ID into the
    # active quest's reference.md. Best-effort: a folder-id failure must not
    # block blueprint scaffolding, and link-feature is idempotent so the
    # repeated ensure-current calls across a feature's lifecycle are safe.
    "${MI_PLUGIN_ROOT}/scripts/folder-id.sh" link-feature "$feature" \
      || mi_info "folder-id link-feature failed for $feature (continuing)"
    mi_info "ensured $current and $current/diagrams"
    ;;

  rotate)
    feature="${1:?feature required}"; shift
    reason_kind=""
    reason_summary=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --reason-kind)
          reason_kind="${2:?--reason-kind requires a value}"
          shift 2
          ;;
        --reason-summary)
          reason_summary="${2:?--reason-summary requires a value}"
          shift 2
          ;;
        *)
          mi_die "unknown flag: $1"
          ;;
      esac
    done
    [[ -n "$reason_kind" ]] || mi_die "--reason-kind is required (see schemas/reason.schema.yaml for valid values)"
    [[ -n "$reason_summary" ]] || mi_die "--reason-summary is required (one-line explanation of the rotation)"

    current="$(mi_blueprints_current "$feature")"
    history="$(mi_blueprints_history "$feature")"
    [[ -d "$current" ]] || mi_die "blueprints/current not found for feature=$feature"
    mkdir -p "$history"

    # Preflight: scan finalized vN/ directories. Any finalized v[K] missing
    # reason.md is the old-format interrupted shape (pre-resumability); refuse
    # to proceed until an inspector repairs it. We must not guess the reason
    # kind of an unidentified finalized rotation, nor count it as a safe parent.
    shopt -s nullglob
    finalized_max=0
    finalized_count=0
    for d in "$history"/v[0-9]*; do
      [[ "$d" == *.partial || "$d" == *.partial.tmp ]] && continue
      base="${d##*/v}"
      [[ "$base" =~ ^[0-9]+$ ]] || continue
      if [[ ! -f "$d/reason.md" ]]; then
        shopt -u nullglob
        mi_die "rotate: finalized history directory $d is missing reason.md (old-format interrupted rotation; manual repair required before any new rotation can proceed)"
      fi
      finalized_count=$((finalized_count + 1))
      if [[ $base -gt $finalized_max ]]; then
        finalized_max=$base
      fi
    done

    # Collect partial directories of both shapes.
    partials=()
    tmp_partials=()
    for d in "$history"/v[0-9]*.partial; do
      partials[${#partials[@]}]="$d"
    done
    for d in "$history"/v[0-9]*.partial.tmp; do
      tmp_partials[${#tmp_partials[@]}]="$d"
    done
    shopt -u nullglob

    # Cross-product STOP: total partial count > 1 is ambiguous regardless of K
    # or shape. The forward path only ever creates .partial.tmp for the current
    # next_n, so two-or-more partials means a previously-interrupted recovery
    # left orphans — refuse loudly instead of guessing which to resume.
    total_partials=$((${#partials[@]} + ${#tmp_partials[@]}))
    if [[ $total_partials -gt 1 ]]; then
      msg="rotate: ambiguous recovery state — $total_partials partial directories under $history. Manual reconciliation required."
      for p in "${partials[@]}"; do msg+="
  - $p"; done
      for p in "${tmp_partials[@]}"; do msg+="
  - $p"; done
      mi_die "$msg"
    fi

    # Exactly one .partial: kind-matched recovery.
    if [[ ${#partials[@]} -eq 1 ]]; then
      partial="${partials[0]}"
      partial_K="${partial##*/v}"; partial_K="${partial_K%.partial}"
      reason_file="$partial/reason.md"
      if [[ ! -f "$reason_file" ]]; then
        if [[ -z "$(ls -A "$partial" 2>/dev/null)" ]]; then
          # Empty + missing reason → safe to remove (no artifacts moved yet).
          rmdir "$partial"
          mi_info "rotate: removed empty partial $partial (no reason.md, no contents)"
        else
          mi_die "rotate: partial directory $partial has artifacts but no reason.md (old/unknown partial; manual cleanup required)"
        fi
      else
        partial_kind="$(mi_fm_get "$reason_file" kind 2>/dev/null || echo "")"
        if [[ "$partial_kind" != "$reason_kind" ]]; then
          mi_die "rotate: partial $partial has reason.kind='$partial_kind' but requested --reason-kind='$reason_kind' (different commands cannot share a partial; finish or abandon the existing partial first)"
        fi
        # Resume: move any remaining current/* into vK.partial/, rename → vK.
        shopt -s dotglob nullglob
        for entry in "$current"/*; do
          mv "$entry" "$partial/"
        done
        shopt -u dotglob nullglob
        mv "$partial" "$history/v${partial_K}"
        mkdir -p "$current"
        mi_info "rotate: resumed v${partial_K}.partial → v${partial_K} (kind=$reason_kind)"
        echo "$partial_K"
        exit 0
      fi
    fi

    # Exactly one .partial.tmp: empty/reason-only is safe to remove; otherwise
    # STOP (this shape is unreachable under the new forward path beyond the
    # post-reason-write window, so unexpected contents indicate state corruption).
    if [[ ${#tmp_partials[@]} -eq 1 ]]; then
      tmp_partial="${tmp_partials[0]}"
      contents="$(ls -A "$tmp_partial" 2>/dev/null)"
      if [[ -z "$contents" || "$contents" == "reason.md" ]]; then
        rm -rf "$tmp_partial"
        mi_info "rotate: removed unpublished temp $tmp_partial (empty or reason-only)"
      else
        mi_die "rotate: unpublished temp $tmp_partial has unexpected contents (manual cleanup required); contents: $contents"
      fi
    fi

    # Forward path: pick next_n from finalized versions only.
    next_n=$((finalized_max + 1))

    # Step 1: mkdir v[next_n].partial.tmp.
    tmp_dest="$history/v${next_n}.partial.tmp"
    mkdir "$tmp_dest"

    # Step 2: write + validate reason.md inside .partial.tmp.
    triggered_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    "${MI_PLUGIN_ROOT}/scripts/frontmatter.sh" init reason "$tmp_dest/reason.md" \
      "KIND=$reason_kind" \
      "TRIGGERED_AT=$triggered_at" \
      "SUMMARY=$reason_summary" >/dev/null

    # Step 3: atomic rename .partial.tmp → .partial (publishes recoverable intent).
    partial_dest="$history/v${next_n}.partial"
    mv "$tmp_dest" "$partial_dest"

    # Step 4: move current/* into v[next_n].partial/.
    shopt -s dotglob nullglob
    for entry in "$current"/*; do
      mv "$entry" "$partial_dest/"
    done
    shopt -u dotglob nullglob

    # Step 5: atomic rename .partial → vN (finalizes the rotation).
    final_dest="$history/v${next_n}"
    mv "$partial_dest" "$final_dest"

    # Step 6: recreate empty current/ (next stage's launcher fills it).
    mkdir -p "$current"

    mi_info "rotated blueprints/current to history/v${next_n} (kind=$reason_kind)"
    echo "$next_n"
    ;;

  resume-partial)
    feature="${1:?feature required}"; shift
    expected_kind=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --expected-kind)
          expected_kind="${2:?--expected-kind requires a value}"
          shift 2
          ;;
        *)
          mi_die "unknown flag: $1"
          ;;
      esac
    done
    [[ -n "$expected_kind" ]] || mi_die "--expected-kind is required (one of: completion, spec-update, re-spec-cascade, re-plan-cascade, manual)"

    current="$(mi_blueprints_current "$feature")"
    history="$(mi_blueprints_history "$feature")"
    [[ -d "$history" ]] || mi_die "resume-partial: history directory not found for feature=$feature"

    shopt -s nullglob
    partials=()
    tmp_partials=()
    for d in "$history"/v[0-9]*.partial; do
      partials[${#partials[@]}]="$d"
    done
    for d in "$history"/v[0-9]*.partial.tmp; do
      tmp_partials[${#tmp_partials[@]}]="$d"
    done
    shopt -u nullglob

    total_partials=$((${#partials[@]} + ${#tmp_partials[@]}))
    if [[ $total_partials -eq 0 ]]; then
      mi_die "resume-partial: no partial directory found under $history"
    fi
    if [[ $total_partials -gt 1 ]]; then
      mi_die "resume-partial: multiple partial directories under $history (count: $total_partials); manual reconciliation required"
    fi

    if [[ ${#tmp_partials[@]} -eq 1 ]]; then
      tmp_partial="${tmp_partials[0]}"
      contents="$(ls -A "$tmp_partial" 2>/dev/null)"
      if [[ -z "$contents" || "$contents" == "reason.md" ]]; then
        rm -rf "$tmp_partial"
        mi_info "resume-partial: removed unpublished temp $tmp_partial (empty or reason-only); no published partial to resume"
        exit 0
      fi
      mi_die "resume-partial: unpublished temp $tmp_partial has unexpected contents (manual cleanup required); contents: $contents"
    fi

    partial="${partials[0]}"
    partial_K="${partial##*/v}"; partial_K="${partial_K%.partial}"
    reason_file="$partial/reason.md"
    if [[ ! -f "$reason_file" ]]; then
      if [[ -z "$(ls -A "$partial" 2>/dev/null)" ]]; then
        rmdir "$partial"
        mi_die "resume-partial: removed empty partial $partial (no reason.md); nothing to resume"
      fi
      mi_die "resume-partial: partial $partial has artifacts but no reason.md (old/unknown partial; manual cleanup required)"
    fi
    partial_kind="$(mi_fm_get "$reason_file" kind 2>/dev/null || echo "")"
    if [[ "$partial_kind" != "$expected_kind" ]]; then
      mi_die "resume-partial: partial $partial has reason.kind='$partial_kind' but caller expected '$expected_kind' (refuse to resume; another command owns this partial)"
    fi

    # Move any remaining current/* into vK.partial/, then atomic rename → vK.
    shopt -s dotglob nullglob
    for entry in "$current"/*; do
      mv "$entry" "$partial/"
    done
    shopt -u dotglob nullglob
    mv "$partial" "$history/v${partial_K}"
    mkdir -p "$current"
    mi_info "resume-partial: v${partial_K}.partial → v${partial_K} (kind=$expected_kind)"
    echo "$partial_K"
    ;;

  preserve-inspector-sections)
    feature="${1:?feature required}"
    from_version="${2:?from-version required (numeric, e.g. 3 for history/v3/)}"
    src="$(mi_blueprints_history "$feature")/v${from_version}/config.md"
    dest="$(mi_blueprints_current "$feature")/config.md"
    [[ -f "$src" ]]  || mi_die "history config.md not found: $src"
    [[ -f "$dest" ]] || mi_die "current config.md not found: $dest (regenerate before invoking preserve-inspector-sections)"

    python3 - "$src" "$dest" <<'PYEOF'
import sys, re
src_path, dest_path = sys.argv[1:3]
with open(src_path) as f:
    src = f.read()
with open(dest_path) as f:
    dest = f.read()

def extract_section(text, heading):
    """Return the body under `heading` (everything from the line after the heading
    up to the next `## ` heading or EOF). None if heading is absent."""
    pat = re.compile(rf'^{re.escape(heading)}[ \t]*\n', re.MULTILINE)
    m = pat.search(text)
    if not m:
        return None
    start = m.end()
    nxt = re.search(r'^## ', text[start:], re.MULTILINE)
    end = start + nxt.start() if nxt else len(text)
    return text[start:end].rstrip('\n') + '\n'

def replace_section(text, heading, new_body):
    """Replace the body under `heading` with `new_body`. Heading line is preserved.
    Returns text unchanged if heading is missing in `text`."""
    pat = re.compile(
        rf'(^{re.escape(heading)}[ \t]*\n)(.*?)(?=^## |\Z)',
        re.DOTALL | re.MULTILINE,
    )
    m = pat.search(text)
    if not m:
        return text
    return text[:m.end(1)] + new_body + ('\n' if not new_body.endswith('\n\n') else '') + text[m.end(2):]

preserved = []
for heading in ('## GIT BRANCH', '## Inspector Additions'):
    body = extract_section(src, heading)
    if body is None:
        continue
    new_dest = replace_section(dest, heading, body)
    if new_dest != dest:
        preserved.append(heading)
        dest = new_dest

with open(dest_path, 'w') as f:
    f.write(dest)
sys.stderr.write(f"preserved {len(preserved)} section(s) from {src_path} → {dest_path}: {', '.join(preserved) or 'none'}\n")
PYEOF
    ;;

  check-current)
    require_primer=0
    if [[ "${1:-}" == "--require-primer" ]]; then
      require_primer=1
      shift
    fi
    feature="${1:?feature required}"
    current="$(mi_blueprints_current "$feature")"
    python3 - "$current" "$require_primer" "$MI_PLUGIN_ROOT" <<'PYEOF'
import os, re, glob, subprocess, sys, yaml

current, require_primer_str, plugin_root = sys.argv[1], sys.argv[2], sys.argv[3]
require_primer = require_primer_str == "1"

def fm_field(path, field):
    if not os.path.isfile(path):
        return None
    try:
        with open(path) as f:
            content = f.read()
    except OSError:
        return None
    m = re.match(r'^---\n(.*?)\n---\n', content, re.DOTALL)
    if not m:
        return None
    try:
        fm = yaml.safe_load(m.group(1)) or {}
    except yaml.YAMLError:
        return None
    return fm.get(field) if isinstance(fm, dict) else None

def has_non_placeholder_body(path):
    """A body has substance if at least one line is non-blank, not an HTML
    comment, and not a frontmatter delimiter."""
    try:
        with open(path) as f:
            content = f.read()
    except OSError:
        return False
    m = re.match(r'^---\n.*?\n---\n(.*)$', content, re.DOTALL)
    body = m.group(1) if m else content
    in_block_comment = False
    for line in body.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        # Track <!-- ... --> comments that may span lines.
        if in_block_comment:
            if '-->' in stripped:
                in_block_comment = False
            continue
        if stripped.startswith('<!--'):
            if '-->' not in stripped:
                in_block_comment = True
            continue
        # Markdown headings count as substance (a real body has at least one
        # heading or paragraph). A pure frontmatter file would have only blank
        # / comment lines below the closing '---'.
        return True
    return False

def validates(path, schema):
    if not os.path.isfile(path):
        return False
    r = subprocess.run(
        [f"{plugin_root}/scripts/internal/validate-frontmatter.sh", path, schema],
        capture_output=True
    )
    return r.returncode == 0

if not os.path.isdir(current):
    sys.exit(1)

req            = os.path.join(current, "requirements.md")
cfg            = os.path.join(current, "config.md")
diagrams_dir   = os.path.join(current, "diagrams")
diagrams_rmd   = os.path.join(diagrams_dir, "README.md")
primer         = os.path.join(current, "primer.md")

req_present  = os.path.isfile(req)
cfg_present  = os.path.isfile(cfg)
ddir_present = os.path.isdir(diagrams_dir)
drmd_present = os.path.isfile(diagrams_rmd)
use_cases    = sorted(glob.glob(os.path.join(diagrams_dir, "use-case-*.puml"))) if ddir_present else []

# Empty: req AND cfg both missing AND diagrams/ missing or scaffold-only
# (no README, no use-case puml).
diagrams_scaffold_only = ddir_present and not drmd_present and not use_cases
diagrams_missing       = not ddir_present
if not req_present and not cfg_present and (diagrams_missing or diagrams_scaffold_only):
    sys.exit(1)

# Complete-core: requirements + config + diagrams/README + at least one use-case puml,
# all valid, with the README's requirements-id matching requirements.md's id.
req_id = fm_field(req, "id") if req_present else None

req_complete = req_present and validates(req, "requirements") and has_non_placeholder_body(req)
cfg_complete = cfg_present and validates(cfg, "config") and has_non_placeholder_body(cfg)

drmd_complete = False
if drmd_present and req_id:
    if validates(diagrams_rmd, "diagrams-readme-blueprint"):
        if fm_field(diagrams_rmd, "requirements-id") == req_id:
            drmd_complete = True

diagrams_complete = ddir_present and drmd_complete and len(use_cases) >= 1

core_complete = req_complete and cfg_complete and diagrams_complete

if not require_primer:
    sys.exit(0 if core_complete else 2)

# --require-primer mode: also need primer.md valid + requirements-id match + body.
primer_complete = False
if os.path.isfile(primer) and req_id:
    if validates(primer, "primer"):
        if fm_field(primer, "requirements-id") == req_id and has_non_placeholder_body(primer):
            primer_complete = True

sys.exit(0 if core_complete and primer_complete else 2)
PYEOF
    ;;

  branch-status)
    feature="${1:?feature required}"
    cfg="$(mi_blueprints_current "$feature")/config.md"
    if [[ ! -f "$cfg" ]]; then
      echo "unset"
      exit 0
    fi
    python3 - "$cfg" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
# Find the ## GIT BRANCH section body (everything from heading to next ## or EOF).
m = re.search(r'^## GIT BRANCH[ \t]*\n(.*?)(?=^## |\Z)', content, re.DOTALL | re.MULTILINE)
if not m:
    print("unset")
    sys.exit(0)
section = m.group(1)
# Strip HTML comments (greedy, multi-line capable).
section = re.sub(r'<!--.*?-->', '', section, flags=re.DOTALL)
candidates = []
for raw in section.splitlines():
    line = raw.strip()
    if not line:
        continue
    if line.startswith('-'):
        continue
    candidates.append(line)
if not candidates:
    print("unset")
elif len(candidates) == 1:
    branch = candidates[0]
    print("trunk" if branch in ("main", "master") else "set")
else:
    print("multi")
PYEOF
    ;;

  manual-test-plan-path)
    feature="${1:?feature required}"
    echo "$(mi_test_dir "$feature")/manual-test-plan.md"
    ;;

  manual-test-results-path)
    feature="${1:?feature required}"
    echo "$(mi_test_dir "$feature")/manual-test-results.md"
    ;;

  manual-test-plan-rotate)
    # Move the current manual-test-plan.md (and manual-test-results.md, if present)
    # into manual-test-plan.history/<UTC-timestamp>/. Called by /mi-manual-test-plan
    # on regeneration (--force or direct `y` when an existing plan was found) and
    # by --discard-existing. The caller is responsible for preserving the prior
    # plan's `seed-family-id` BEFORE invoking this helper unless --new-seed-family
    # was explicitly requested.
    feature="${1:?feature required}"
    test_dir="$(mi_test_dir "$feature")"
    # mkdir -p makes the rotate safe even when test/ has not been created yet
    # (e.g., rotate is the first subcommand to touch the folder after a fresh
    # feature activation). The plan.history directory is created on demand below.
    mkdir -p "$test_dir"
    plan_file="$test_dir/manual-test-plan.md"
    results_file="$test_dir/manual-test-results.md"
    history_dir="$test_dir/manual-test-plan.history"
    if [[ ! -f "$plan_file" && ! -f "$results_file" ]]; then
      mi_die "manual-test-plan-rotate: no manual-test-plan.md or manual-test-results.md to rotate at $test_dir"
    fi
    timestamp="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
    target="$history_dir/$timestamp"
    mkdir -p "$target"
    if [[ -f "$plan_file" ]]; then
      mv "$plan_file" "$target/manual-test-plan.md"
    fi
    if [[ -f "$results_file" ]]; then
      mv "$results_file" "$target/manual-test-results.md"
    fi
    mi_info "rotated manual-test artifacts → $target"
    echo "$target"
    ;;

  manual-test-results-rotate-only)
    # Move ONLY the current manual-test-results.md into
    # manual-test-results.history/<UTC-timestamp>/manual-test-results.md.
    # Leaves manual-test-plan.md and manual-test-plan.history/ untouched.
    # Used by /mi-manual-test-plan Step 1 and /mi-manual-test-run Branch A
    # to auto-rotate a prior-activation results file out of the way at the
    # start of a new cycle (see docs/manual-testing-folder/plan.md § 4.1).
    # Non-fatal when the file is absent (prints info to stderr, exits 0).
    feature="${1:?feature required}"
    test_dir="$(mi_test_dir "$feature")"
    results_file="$test_dir/manual-test-results.md"
    if [[ ! -f "$results_file" ]]; then
      mi_info "no manual-test-results.md to rotate at $test_dir"
      exit 0
    fi
    history_dir="$test_dir/manual-test-results.history"
    timestamp="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
    target="$history_dir/$timestamp"
    mkdir -p "$target"
    mv "$results_file" "$target/manual-test-results.md"
    mi_info "rotated manual-test-results.md → $target"
    echo "$target"
    ;;

  *)
    echo "usage: blueprints.sh {ensure-current|rotate|resume-partial|preserve-inspector-sections|check-current|branch-status|manual-test-plan-path|manual-test-results-path|manual-test-plan-rotate|manual-test-results-rotate-only} ..." >&2
    exit 2
    ;;
esac
