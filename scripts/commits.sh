#!/usr/bin/env bash
#
# commits.sh — git-range queries for the active feature's base-commit..HEAD.
#
# CACHE CONTRACTS (Phase 6.2 of the context-optimization plan).
# This script hosts two cache-freshness checks. Each declares an output enum;
# every call site MUST handle every value in the declared enum.
#
#   change-summary-fresh <feature>
#     Output: exit-code only (0=fresh, 1=stale, 2=missing).
#     Cache key: (base-commit, head, feature-id) — see
#       `docs/context optimization/recommendations.md` § "Cache Key
#       Specifications" → `change-summary.md`.
#     Call sites must branch on all three exits. Treating exit !=0 as a
#     single "regenerate" path is acceptable IF the regeneration logic
#     handles both stale (overwrite) and missing (initialize from template)
#     correctly. See `commands/mi-generate-implementation-diagrams.md`
#     Step 2 / Step 2a for the canonical caller.
#
#   diagrams-fresh <feature>
#     Output: stdout enum + exit code.
#       Stdout: one of `fresh | stale | skipped | missing`.
#       Exit:   0 for fresh/stale/skipped.
#               1 for missing.
#     `missing` means only "no .puml set and no skip marker" — this
#     subcommand cannot tell a never-generated feature from a partial run,
#     because nothing creates implementation/diagrams/ before the generator
#     does. What that state MEANS is the caller's call, and the two canonical
#     callers read it differently on purpose:
#       - `mi-generate-implementation-diagrams` Step 1.5 (and therefore
#         `/mi-draw-diagrams`, which dispatches into it) treats it as
#         "nothing to reuse" and generates. Every first-ever stage-4 run of
#         a feature lands here; aborting instead would deadlock, since the
#         only documented recovery re-enters the same command.
#       - `mi-continue` Review-Resume Step 2.5 treats it as an invariant
#         violation and surfaces a diagnostic — read AFTER stage 4, it means
#         stage 4 claimed success and left nothing behind.
#     So the exit code is a routing hint, not a verdict: do not hard-code
#     "exit 1 ⇒ refuse to generate" at a new call site.
#     Cache key: (base-commit, latest-commit-touching-implementation/diagrams/).
#     Call sites must handle all four enum values. Forgetting one — e.g.,
#     treating `skipped` as `missing` — silently breaks the skip-recovery
#     contract. See `commands/mi-generate-implementation-diagrams.md`
#     Step 1.5 and `commands/mi-continue.md` Review-Resume Step 2.5 for
#     canonical four-way switches.
#
# Discipline rule: no new cache may be added to this script without an
# entry in this contract block AND in `recommendations.md` § "Cache Key
# Specifications". Bad cache invalidation produces incorrect workflow
# decisions (worse than re-doing the work).
# commits.sh — query and format the commit range base-commit..HEAD.
#
# Usage:
#   commits.sh list <feature>                # prints "<sha> <msg>" one per line
#   commits.sh yaml <feature>                # prints YAML list: [{sha, msg}, ...] (ready to paste into requirements.md)
#   commits.sh populate-requirements <feature>
#                                            # writes the YAML list into requirements.md's `commits:` field
#   commits.sh changed-files <feature>       # prints "<status>\t<adds>\t<dels>\t<path>" one per line
#                                            # status ∈ {A,M,D,R,C}; adds/dels are "-" for binary diffs.
#                                            # Renamed/copied paths normalize numstat brace syntax
#                                            # (`dir/{old => new}/file`) back to the post-rename path
#                                            # so renamed text files carry valid line stats. Used by
#                                            # mi-generate-implementation-diagrams and
#                                            # /mi-update-blueprint to bound their codebase reads.
#   commits.sh change-summary-fresh <feature>
#                                            # exit 0 if implementation/change-summary.md exists with
#                                            #   frontmatter base-commit + head matching the current
#                                            #   base..HEAD (cache hit — caller can reuse);
#                                            # exit 1 if it exists but is stale (cache miss — regenerate);
#                                            # exit 2 if the file is missing (no cache — generate fresh).
#                                            # No output; the caller branches on the exit code.
#   commits.sh feature-test-range <ft-feature>
#       Union commit range across every finished ordinary feature. Read-only.
#       exit 3 unreachable | 4 nothing contributed | 5 diverged bases.
#   commits.sh populate-feature-test <ft-feature>
#       Stage-8 commits list into the entry's change-summary frontmatter.
#
# Manual regression checks (run from a throwaway repo with `progress.sh init`
# + `progress.sh activate` + `progress.sh set base-commit=<sha>` already done;
# see `scripts/progress.sh` for the helper signatures):
#
#   # `yaml` should emit one entry per commit (regression for the
#   # heredoc-shadowed-stdin bug).
#   commits.sh yaml <feature>
#
#   # `changed-files` should report real adds/dels for renamed text files
#   # (regression for the numstat brace-expansion bug).
#   git mv old.txt new.txt && echo more >> new.txt && git commit -am rename
#   commits.sh changed-files <feature>   # expect: R\t<adds>\t<dels>\tnew.txt
#
#   # change-summary frontmatter should validate when the SHA happens to be
#   # all-numeric (regression for the YAML int-coercion bug):
#   frontmatter.sh init change-summary /tmp/x.md \
#     REQUIREMENTS_ID=11111111-1111-4111-8111-111111111111 \
#     FEATURE=alpha BASE_COMMIT=abcdef1 HEAD=1234567
#   frontmatter.sh validate /tmp/x.md change-summary

set -euo pipefail
source "$(dirname "$0")/internal/common.sh"

cmd="${1:-}"; shift || true

get_range() {
  local base
  base="$(mi_fm_get "$(mi_progress_file)" '.active.base-commit')"
  [[ -n "$base" && "$base" != "null" ]] || mi_die "base-commit not set in progress.md (no active feature, or stage < 3)"
  echo "${base}..HEAD"
}

case "$cmd" in
  list)
    feature="${1:?feature required}"
    range="$(get_range)"
    git log --pretty=format:'%H %s' "$range"
    echo
    ;;

  yaml)
    feature="${1:?feature required}"
    range="$(get_range)"
    # Run git log inside Python so the heredoc-as-script doesn't shadow stdin —
    # the same pattern populate-requirements uses.
    python3 - "$range" <<'PYEOF'
import sys, subprocess, yaml
rng = sys.argv[1]
log = subprocess.check_output(['git', 'log', '--pretty=format:%H\t%s', rng], text=True)
shas = []
for line in log.splitlines():
    if not line.strip():
        continue
    sha, msg = line.split('\t', 1)
    shas.append({'sha': sha, 'msg': msg})
print(yaml.safe_dump(shas, default_flow_style=False, sort_keys=False), end='')
PYEOF
    ;;

  populate-requirements)
    feature="${1:?feature required}"
    requirements_file="$(mi_blueprints_current "$feature")/requirements.md"
    [[ -f "$requirements_file" ]] || mi_die "requirements.md not found"
    range="$(get_range)"
    python3 - "$requirements_file" "$range" <<'PYEOF'
import sys, subprocess, re, yaml
path, rng = sys.argv[1], sys.argv[2]
log = subprocess.check_output(['git', 'log', '--pretty=format:%H\t%s', rng], text=True)
commits = []
for line in log.splitlines():
    if not line.strip(): continue
    sha, msg = line.split('\t', 1)
    commits.append({'sha': sha, 'msg': msg})
with open(path) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
fm = yaml.safe_load(m.group(1)) or {}
fm['commits'] = commits
with open(path, 'w') as f:
    f.write('---\n')
    f.write(yaml.safe_dump(fm, default_flow_style=False, sort_keys=False))
    f.write('---\n')
    f.write(m.group(2))
print(f'mi: populated {len(commits)} commits into {path}', file=sys.stderr)
PYEOF
    "${MI_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$requirements_file" requirements >/dev/null
    ;;

  changed-files)
    feature="${1:?feature required}"
    range="$(get_range)"
    base="${range%..*}"
    python3 - "$base" <<'PYEOF'
import re, sys, subprocess
base = sys.argv[1]
ns = subprocess.check_output(['git', 'diff', '--name-status', f'{base}..HEAD'], text=True)
nu = subprocess.check_output(['git', 'diff', '--numstat', f'{base}..HEAD'], text=True)

# name-status emits one of: "A\tpath", "M\tpath", "D\tpath", "Rxxx\told\tnew", "Cxxx\told\tnew".
status = {}
for line in ns.splitlines():
    if not line.strip():
        continue
    parts = line.split('\t')
    s = parts[0][0]  # first char: A/M/D/R/C
    path = parts[2] if s in ('R', 'C') else parts[1]
    status[path] = s

# numstat brace expansion: "dir/{a => b}/file" → ("dir/a/file", "dir/b/file").
# Used for rename/copy paths so we can match numstat lines back to the new path
# that name-status records.
brace_re = re.compile(r'\{([^{}]*) => ([^{}]*)\}')

def expand_brace(p):
    m = brace_re.search(p)
    if not m:
        return p, p
    old, new = m.group(1), m.group(2)
    old_path = brace_re.sub(old, p, count=1)
    new_path = brace_re.sub(new, p, count=1)
    # Collapse double slashes from empty segments (e.g. "{ => dir}/x" → "/dir/x").
    old_path = re.sub(r'/+', '/', old_path).strip('/')
    new_path = re.sub(r'/+', '/', new_path).strip('/')
    return old_path, new_path

# numstat emits "adds\tdels\tpath"; "-" for both on binary diffs.
stats = {}
for line in nu.splitlines():
    if not line.strip():
        continue
    parts = line.split('\t')
    if len(parts) < 3:
        continue
    adds, dels = parts[0], parts[1]
    raw_path = '\t'.join(parts[2:])  # numstat may emit "adds\tdels\told\tnew" for renames without -M
    if '\t' in raw_path:
        # Old-style numstat rename: "adds\tdels\told\tnew". The new path is what
        # name-status reports.
        old_path, new_path = raw_path.split('\t', 1)
        stats[new_path] = (adds, dels)
        stats[old_path] = (adds, dels)
    elif ' => ' in raw_path:
        old_path, new_path = expand_brace(raw_path)
        stats[new_path] = (adds, dels)
        stats[old_path] = (adds, dels)
    else:
        stats[raw_path] = (adds, dels)

for path, s in sorted(status.items()):
    a, d = stats.get(path, ('-', '-'))
    print(f'{s}\t{a}\t{d}\t{path}')
PYEOF
    ;;

  change-summary-fresh)
    feature="${1:?feature required}"
    summary_file="$(mi_impl_dir "$feature")/change-summary.md"
    if [[ ! -f "$summary_file" ]]; then
      exit 2
    fi
    cur_base="$(mi_fm_get "$(mi_progress_file)" '.active.base-commit')"
    cur_head="$(git rev-parse HEAD)"
    cached_base="$(mi_fm_get "$summary_file" base-commit 2>/dev/null || echo "")"
    cached_head="$(mi_fm_get "$summary_file" head 2>/dev/null || echo "")"
    if [[ "$cur_base" == "$cached_base" && "$cur_head" == "$cached_head" ]]; then
      exit 0
    fi
    exit 1
    ;;

  changed-files-only)
    # Phase 6.5 of the context-optimization plan: extract just the
    # `## Changed files` section body from `implementation/change-summary.md`,
    # without any of the surrounding analysis sections (`## Detected
    # entrypoints`, `## Suspected flows`, `## Omitted from analysis`, frontmatter).
    # Used by stages 4, 6, 8 when the consumer only needs the file index
    # (e.g., deciding which diagrams to refresh) and re-running `git diff`
    # would burn cache. Returns the body of the section as-is — caller is
    # responsible for parsing if they need structured fields.
    #
    # If change-summary.md does not exist or is stale, this command does NOT
    # auto-regenerate — the caller is expected to gate via `change-summary-fresh`
    # first. A stale or missing summary surfaces as exit 2 (so it can't be
    # silently confused with a fresh empty index).
    feature="${1:?feature required}"
    summary_file="$(mi_impl_dir "$feature")/change-summary.md"
    if [[ ! -f "$summary_file" ]]; then
      echo "changed-files-only: $summary_file not found (run change-summary-fresh first to gate)" >&2
      exit 2
    fi
    python3 - "$summary_file" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
m = re.search(r'(?:^|\n)## Changed files\s*\n(.*?)(?=\n## |\Z)', content, re.DOTALL)
if not m:
    sys.stderr.write(f"changed-files-only: no `## Changed files` section in {path}\n")
    sys.exit(1)
print(m.group(1).strip())
PYEOF
    ;;

  diagrams-fresh)
    # Multi-state freshness output for implementation/diagrams/. Prints one of
    # `fresh|stale|skipped|missing` to stdout. Exit codes:
    #   0 — for `fresh`, `stale`, `skipped`
    #   1 — for `missing` (routing hint only; whether it means "generate from
    #       scratch" or "invariant violation" depends on the caller — see the
    #       contract block at the top of this file)
    #
    # Cache key for `stale` detection: (base-commit,
    #   latest-commit-touching-implementation/diagrams/).
    # See `docs/context optimization/recommendations.md` § "Cache Key
    # Specifications" → `diagrams-fresh` for the canonical contract.
    feature="${1:?feature required}"
    diagrams_dir="$(mi_impl_dir "$feature")/diagrams"
    skipped="$(mi_fm_get "$(mi_progress_file)" '.active.implementation-diagrams-skipped' 2>/dev/null || echo 'false')"

    if [[ "$skipped" == "true" ]]; then
      # Invariant: when skipped=true the directory must NOT exist. /mi-draw-diagrams
      # removes the directory FIRST, then sets the marker, so a crash in between
      # leaves skipped=false (default) AND no directory → falls into the missing
      # branch below. Surface a diagnostic if both are true (invariant violation).
      if [[ -d "$diagrams_dir" ]] && [[ -n "$(find "$diagrams_dir" -maxdepth 1 -name '*.puml' -print -quit 2>/dev/null)" ]]; then
        echo "missing"
        echo "diagrams-fresh: invariant violation — implementation-diagrams-skipped=true but $diagrams_dir contains .puml files. Recover via /mi-draw-diagrams (will offer regeneration)." >&2
        exit 1
      fi
      echo "skipped"
      exit 0
    fi

    # skipped=false → check for actual .puml files
    if [[ ! -d "$diagrams_dir" ]] || [[ -z "$(find "$diagrams_dir" -maxdepth 1 -name '*.puml' -print -quit 2>/dev/null)" ]]; then
      echo "missing"
      exit 1
    fi

    # Directory exists with .puml files. Compute freshness against the most
    # recent commit that touched the diagrams directory.
    base_commit="$(mi_fm_get "$(mi_progress_file)" '.active.base-commit' 2>/dev/null || echo '')"
    if [[ -z "$base_commit" || "$base_commit" == "null" ]]; then
      # No base-commit yet (pre-stage-3) — can't compute freshness; treat as stale.
      echo "stale"
      exit 0
    fi

    last_diagram_commit="$(git log -1 --format=%H -- "$diagrams_dir" 2>/dev/null || echo '')"
    if [[ -z "$last_diagram_commit" ]]; then
      # Diagrams not committed yet — count from base.
      new_since_diagrams="$(git rev-list --count "${base_commit}..HEAD" 2>/dev/null || echo 0)"
    else
      new_since_diagrams="$(git rev-list --count "${last_diagram_commit}..HEAD" 2>/dev/null || echo 0)"
    fi

    if [[ "$new_since_diagrams" == "0" ]]; then
      echo "fresh"
    else
      echo "stale"
    fi
    exit 0
    ;;

  feature-test-range)
    # Union commit range for a feature-test entry: the earliest base-commit
    # across every finished ordinary feature, through HEAD. Read-only.
    #
    # stdout line 1:  <union_base>\t<head>
    # then:           contributor\t<feat>\t<base>\t<head>
    #                 omitted\t<feat>
    # exit 3 = a finished feature's head is unreachable from HEAD
    # exit 4 = nothing contributed commits
    # exit 5 = bases diverged; no single earliest exists
    feature="${1:?feature required}"
    python3 - "$(mi_data_root)" "$(mi_progress_file)" "$feature" <<'PYEOF'
import os, re, sys, subprocess, yaml

data_root, progress_path, ft_feature = sys.argv[1], sys.argv[2], sys.argv[3]

def frontmatter(path):
    try:
        with open(path) as f:
            text = f.read()
    except OSError:
        return None
    m = re.match(r'^---\n(.*?)\n---\n', text, re.DOTALL)
    return (yaml.safe_load(m.group(1)) or {}) if m else None

prog = frontmatter(progress_path) or {}
completed = [c for c in (prog.get('completed') or []) if c != ft_feature]

def latest_change_summary(feat):
    """Newest finalized history version carrying an archived change-summary."""
    hist = os.path.join(data_root, 'workflow-stream', feat, 'blueprints', 'history')
    if not os.path.isdir(hist):
        return None
    versions = []
    for entry in os.listdir(hist):
        m = re.fullmatch(r'v(\d+)', entry)
        if m:
            versions.append((int(m.group(1)), entry))
    for _, entry in sorted(versions, reverse=True):
        path = os.path.join(hist, entry, 'implementation', 'change-summary.md')
        if os.path.isfile(path):
            return path
    return None

def is_ancestor(a, b):
    return subprocess.call(
        ['git', 'merge-base', '--is-ancestor', a, b],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0

head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()

contributors, omitted, unreachable = [], [], []
for feat in completed:
    cs = latest_change_summary(feat)
    if cs is None:
        omitted.append(feat)
        continue
    data = frontmatter(cs) or {}
    base, feat_head = data.get('base-commit'), data.get('head')
    if not base or not feat_head:
        omitted.append(feat)
        continue
    if not is_ancestor(feat_head, head):
        unreachable.append(feat)
        continue
    contributors.append((feat, base, feat_head))

if unreachable:
    sys.stderr.write(
        "error: feature-test-range: these finished features are not reachable "
        "from HEAD: " + ", ".join(unreachable) + "\n"
        "       The combined test cannot draw a picture that omits them. Merge "
        "or rebase so every feature's work is visible from one checkout, then "
        "re-run.\n")
    sys.exit(3)

if not contributors:
    sys.stderr.write(
        "error: feature-test-range: no finished feature contributed commits "
        "(all omitted: " + ", ".join(omitted) + "). There is no assembled "
        "implementation to test.\n")
    sys.exit(4)

bases = [b for _, b, _ in contributors]
earliest = None
for candidate in bases:
    if all(candidate == other or is_ancestor(candidate, other) for other in bases):
        earliest = candidate
        break

if earliest is None:
    sys.stderr.write(
        "error: feature-test-range: the finished features' base commits are "
        "diverged; no single earliest base exists. A contiguous <base>..HEAD "
        "range is the contract every downstream consumer is written against. "
        "Merge the lines together, then re-run.\n")
    sys.exit(5)

print(f"{earliest}\t{head}")
for feat, base, feat_head in contributors:
    print(f"contributor\t{feat}\t{base}\t{feat_head}")
for feat in omitted:
    print(f"omitted\t{feat}")
PYEOF
    ;;

  populate-feature-test)
    # Stage-8 commits list for a feature-test entry, which has no
    # requirements.md to carry it. Deliberately separate from
    # populate-requirements: that path runs for every ordinary completion and
    # must not grow feature-test branching.
    feature="${1:?feature required}"
    summary_file="$(mi_impl_dir "$feature")/change-summary.md"
    [[ -f "$summary_file" ]] || mi_die "populate-feature-test: $summary_file not found (run the diagram pass first)"
    range_line="$("${MI_PLUGIN_ROOT}/scripts/commits.sh" feature-test-range "$feature" | head -1)" || exit $?
    union_base="$(printf '%s' "$range_line" | cut -f1)"
    union_head="$(printf '%s' "$range_line" | cut -f2)"
    python3 - "$summary_file" "${union_base}..${union_head}" <<'PYEOF'
import sys, subprocess, re, yaml
path, rng = sys.argv[1], sys.argv[2]
log = subprocess.check_output(['git', 'log', '--pretty=format:%H\t%s', rng], text=True)
commits = []
for line in log.splitlines():
    if not line.strip():
        continue
    sha, msg = line.split('\t', 1)
    commits.append({'sha': sha, 'msg': msg})
with open(path) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
fm = yaml.safe_load(m.group(1)) or {}
fm['commits'] = commits
with open(path, 'w') as f:
    f.write('---\n')
    f.write(yaml.safe_dump(fm, default_flow_style=False, sort_keys=False))
    f.write('---\n')
    f.write(m.group(2))
print(f'mi: populated {len(commits)} commits into {path}', file=sys.stderr)
PYEOF
    "${MI_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$summary_file" change-summary >/dev/null
    ;;

  *)
    echo "usage: commits.sh {list|yaml|populate-requirements|changed-files|changed-files-only|change-summary-fresh|diagrams-fresh|feature-test-range} ..." >&2
    exit 2
    ;;
esac
