#!/usr/bin/env bash
# folder-id.sh — manage folder-identity markers (id.md) and the per-cycle
# quest reference table (reference.md).
#
# Each journal topic folder and each workflow-stream feature folder carries an
# id.md whose frontmatter `id` is a stable UUID identifying the *folder*
# itself — so links survive the folder being renamed or moved. A quest cycle's
# reference.md records these IDs to connect journal -> quest -> workflow-stream:
# reading reference.md from a quest folder, you can reach every journal folder
# the cycle was built from and every feature folder it produced.
#
# Usage:
#   folder-id.sh ensure <folder>
#       Print the folder's ID. Mints <folder>/id.md if missing. Idempotent.
#
#   folder-id.sh get <folder>
#       Print the folder's ID. Errors if <folder>/id.md is missing.
#
#   folder-id.sh resolve <id>
#       Print the path of the journal or workflow-stream folder whose id.md
#       carries <id>. Errors if no folder matches.
#
#   folder-id.sh list
#       Print "<id>  <folder>" for every journal and feature folder that has
#       an id.md. Diagnostic helper.
#
#   folder-id.sh init-reference <journal-folder> [<journal-folder> ...]
#       Ensure an id.md in each named journal folder (direct children of
#       journal/), then write reference.md into the active quest cycle's
#       subfolder with those journal IDs recorded. feature-refs starts empty.
#       Called by /mi-run at stage 1.
#
#   folder-id.sh link-feature <feature>
#       Ensure workflow-stream/<feature>/id.md, then append its ID to the
#       active quest's reference.md (frontmatter feature-refs array + a body
#       bullet under "## Workflow-stream features"). Idempotent. Emits a
#       warning and ensures only the id.md when there is no active quest or
#       its reference.md is missing (e.g. a cycle predating folder-linking).
#       Called by blueprints.sh ensure-current at stage 2.

set -euo pipefail
source "$(dirname "$0")/internal/common.sh"

# Print the id from <folder>/id.md. Returns non-zero if the marker is absent.
_fid_read() {
  local idfile="$1/id.md"
  [[ -f "$idfile" ]] || return 1
  mi_fm_get "$idfile" id
}

# Print the id for <folder>, minting <folder>/id.md from the folder-id
# template when it does not yet exist. Idempotent.
_fid_ensure() {
  local folder="$1"
  [[ -d "$folder" ]] || mi_die "folder not found: $folder"
  local idfile="$folder/id.md"
  if [[ -f "$idfile" ]]; then
    mi_fm_get "$idfile" id
    return 0
  fi
  # frontmatter.sh init auto-generates the UUID and validates against
  # schemas/folder-id.schema.yaml.
  "${MI_PLUGIN_ROOT}/scripts/frontmatter.sh" init folder-id "$idfile" >/dev/null
  mi_fm_get "$idfile" id
}

cmd="${1:-}"; shift || true

case "$cmd" in
  ensure)
    folder="${1:?folder required}"
    _fid_ensure "$folder"
    ;;

  get)
    folder="${1:?folder required}"
    _fid_read "$folder" || mi_die "no id.md in $folder"
    ;;

  resolve)
    want="${1:?id required}"
    found=""
    # journal/<folder>/id.md and workflow-stream/<feature>/id.md are both at
    # depth 2 below their respective roots.
    for base in "$(mi_journal_dir)" "$(mi_stream_dir)"; do
      [[ -d "$base" ]] || continue
      while IFS= read -r idfile; do
        got="$(mi_fm_get "$idfile" id 2>/dev/null || true)"
        if [[ "$got" == "$want" ]]; then
          found="$(dirname "$idfile")"
          break 2
        fi
      done < <(find "$base" -mindepth 2 -maxdepth 2 -name id.md -type f 2>/dev/null)
    done
    [[ -n "$found" ]] || mi_die "no folder found with id=$want"
    printf '%s\n' "$found"
    ;;

  list)
    for base in "$(mi_journal_dir)" "$(mi_stream_dir)"; do
      [[ -d "$base" ]] || continue
      while IFS= read -r idfile; do
        got="$(mi_fm_get "$idfile" id 2>/dev/null || echo '?')"
        printf '%s  %s\n' "$got" "$(dirname "$idfile")"
      done < <(find "$base" -mindepth 2 -maxdepth 2 -name id.md -type f 2>/dev/null | sort)
    done
    ;;

  init-reference)
    [[ $# -gt 0 ]] || mi_die "init-reference: at least one journal folder required"
    quest_dir="$(mi_quest_active_dir)"
    ref="$quest_dir/reference.md"
    [[ ! -f "$ref" ]] || mi_die "reference.md already exists: $ref"
    journal_root="$(mi_journal_dir)"
    refs=()
    bullets=""
    for folder in "$@"; do
      jpath="$journal_root/$folder"
      [[ -d "$jpath" ]] || mi_die "journal folder not found: $jpath"
      jid="$(_fid_ensure "$jpath")"
      refs+=("$jid")
      bullets+="- ${jid} — journal/${folder}"$'\n'
    done
    refs_csv="$(IFS=,; echo "${refs[*]}")"
    "${MI_PLUGIN_ROOT}/scripts/frontmatter.sh" init reference "$ref" \
      "JOURNAL_REFS=${refs_csv}" "JOURNAL_BULLETS=${bullets%$'\n'}" >/dev/null
    mi_info "wrote $ref (${#refs[@]} journal ref(s))"
    ;;

  link-feature)
    feature="${1:?feature required}"
    fdir="$(mi_feature_dir "$feature")"
    [[ -d "$fdir" ]] || mi_die "feature folder not found: $fdir"
    fid="$(_fid_ensure "$fdir")"

    # Best-effort append to the active quest's reference.md. A missing
    # active quest or reference.md is not an error — the id.md still got
    # minted, which is the part blueprint setup depends on.
    quest_dir="$(mi_quest_active_dir 2>/dev/null || true)"
    if [[ -z "$quest_dir" ]]; then
      mi_info "link-feature: no active quest; ensured ${fdir}/id.md only"
      exit 0
    fi
    ref="$quest_dir/reference.md"
    if [[ ! -f "$ref" ]]; then
      mi_info "link-feature: $ref missing (cycle predates folder-linking); ensured ${fdir}/id.md only"
      exit 0
    fi

    python3 - "$ref" "$fid" "$feature" <<'PYEOF'
import sys, re, yaml
ref, fid, feature = sys.argv[1:]
with open(ref) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
if not m:
    sys.stderr.write(f"link-feature: {ref} has no frontmatter\n")
    sys.exit(1)
fm = yaml.safe_load(m.group(1)) or {}
body = m.group(2)
refs = fm.get('feature-refs') or []
if fid in refs:
    sys.exit(0)  # idempotent — already linked
refs.append(fid)
fm['feature-refs'] = refs
# "## Workflow-stream features" is the last section of reference.md, so a
# bullet appended at end-of-file lands under that heading.
body = body.rstrip() + f"\n- {fid} — workflow-stream/{feature}\n"
new = ("---\n"
       + yaml.safe_dump(fm, default_flow_style=False, sort_keys=False, allow_unicode=True).rstrip()
       + "\n---\n" + body)
with open(ref, 'w') as f:
    f.write(new)
PYEOF
    mi_info "linked feature '$feature' (id=$fid) into $ref"
    ;;

  *)
    echo "usage: folder-id.sh {ensure|get|resolve|list|init-reference|link-feature} ..." >&2
    exit 2
    ;;
esac
