#!/usr/bin/env bash
# ingest.sh — convert non-text journal files to sibling .md.
#
# Usage:
#   ingest.sh                              # folder mode — all subfolders under journal/
#   ingest.sh <subfolder>                  # folder mode — one subfolder
#   ingest.sh --dry-run [<subfolder>]      # folder mode, no writes
#   ingest.sh --force   [<subfolder>]      # folder mode, re-convert even if up-to-date
#   ingest.sh --file <path>                # single-file mode — dispatch by extension
#   ingest.sh --stub <path>                # single-file mode — force stub (skip docling)
#
# In folder mode, every supported file under each subfolder is enumerated
# and dispatched by extension:
#
#   Documents (.pdf .docx .pptx .xlsx .html) — run docling with
#   --image-export-mode referenced. The text lands as markdown; every
#   extracted figure is moved into a dedicated <stem>.images/ subfolder
#   with references in the .md rewritten to match. The millwright reads
#   the .md, follows references, and opens each PNG via its native vision
#   capability during stage 1/2.
#
#   Standalone images (.png .jpg .jpeg .webp .tiff .tif) — skip docling
#   (its default image pipeline base64-wraps pixels and handles UI
#   screenshots / diagrams poorly). Generate a stub .md referencing the
#   original file; the millwright reads the stub, then opens the image
#   natively.
#
# In --file mode the same dispatch applies to a single file.
#
# In --stub mode the file gets a stub .md regardless of extension. This
# is the path /mi-run uses when the inspector chose "native read" for a
# small PDF (Claude Code's Read tool parses PDFs ≤ 20 pages natively,
# so docling preprocessing is optional).
#
# In every case originals are preserved, and frontmatter is stamped
# on the generated .md so stage-1 validation passes.
#
# Enumeration excludes *.images/ subfolders so figures docling extracted
# from a PDF can't be mistaken for inspector-supplied inputs on re-runs.
#
# Idempotency: an up-to-date sibling .md is skipped unless --force is
# passed. When --force re-processes a document, its <stem>.images/
# subfolder is cleared first.

set -uo pipefail
source "$(dirname "$0")/internal/common.sh"

dry_run=0
force=0
folder_arg=""
mode="folder"   # folder | file | stub
single_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  dry_run=1; shift ;;
    --force)    force=1; shift ;;
    --file)
      mode="file"
      single_file="${2:-}"
      [[ -n "$single_file" ]] || mi_die "--file requires a path argument"
      shift 2
      ;;
    --stub)
      mode="stub"
      single_file="${2:-}"
      [[ -n "$single_file" ]] || mi_die "--stub requires a path argument"
      shift 2
      ;;
    -h|--help)
      sed -n '2,44p' "$0"
      exit 0
      ;;
    --*)
      mi_die "unknown flag: $1"
      ;;
    *)
      [[ -z "$folder_arg" ]] || mi_die "only one subfolder argument is supported"
      folder_arg="$1"
      shift
      ;;
  esac
done

journal_root="$(mi_journal_dir)"
[[ -d "$journal_root" ]] || mi_die "journal directory not found: $journal_root. Run /mi-init first."

# Extension groups. Case-insensitive matching is applied when we enumerate.
doc_exts=(pdf docx pptx xlsx html)
img_exts=(png jpg jpeg webp tiff tif)

converted=0
skipped=0
failed=0
declare -a failed_paths=()

lower_ext() {
  local e="${1##*.}"
  printf '%s' "$e" | tr '[:upper:]' '[:lower:]'
}

should_skip_existing() {
  local src="$1" dst="$2"
  [[ -f "$dst" && $force -eq 0 && ! "$src" -nt "$dst" ]]
}

frontmatter_block() {
  # Prints a frontmatter block on stdout.
  # Args: <source-basename> [<extra-field: value> ...]
  local src_basename="$1"; shift
  local date_str
  date_str="$(date +%Y-%m-%d)"
  echo "---"
  echo "contributors:"
  echo "  - docling"
  echo "date: $date_str"
  echo "source: $src_basename"
  for field in "$@"; do
    echo "$field"
  done
  echo "---"
  echo
}

ingest_document() {
  # Run docling with referenced-image export; move images into a
  # <stem>.images/ subfolder; rewrite refs in the .md to match.
  command -v docling >/dev/null 2>&1 || mi_die "docling not found on PATH. Install via \`pipx install docling\` or \`python3 -m pip install --user docling\`, then re-run. See /mi-doctor for details."

  local src="$1"
  local stem="${src%.*}"
  local dst="${stem}.md"
  local images_dir="${stem}.images"
  local rel="${src#"$journal_root"/}"
  local images_dir_basename
  images_dir_basename="$(basename "$images_dir")"

  if should_skip_existing "$src" "$dst"; then
    skipped=$((skipped + 1))
    mi_info "skip (up-to-date): $rel"
    return 0
  fi

  if (( dry_run )); then
    mi_info "would convert (doc): $rel  ->  ${dst#"$journal_root"/}"
    return 0
  fi

  mi_info "converting (doc): $rel"

  local tmpdir
  tmpdir="$(mktemp -d)"

  if ! docling --to md --image-export-mode referenced --output "$tmpdir" "$src" >/dev/null 2>"$tmpdir/.err"; then
    mi_info "error: docling failed on $rel"
    mi_info "$(head -3 "$tmpdir/.err" 2>/dev/null || true)"
    rm -rf "$tmpdir"
    failed=$((failed + 1))
    failed_paths+=("$rel")
    return 1
  fi

  local produced
  produced="$tmpdir/$(basename "$stem").md"
  if [[ ! -f "$produced" ]]; then
    produced="$(find "$tmpdir" -maxdepth 2 -type f -name '*.md' | head -1)"
  fi
  if [[ -z "$produced" || ! -f "$produced" ]]; then
    mi_info "error: docling produced no .md for $rel"
    rm -rf "$tmpdir"
    failed=$((failed + 1))
    failed_paths+=("$rel")
    return 1
  fi

  rm -rf "$images_dir"

  local images_moved=0
  local -a image_names=()
  while IFS= read -r -d '' asset; do
    [[ "$asset" == *.md ]] && continue
    [[ "$(basename "$asset")" == ".err" ]] && continue
    if (( images_moved == 0 )); then
      mkdir -p "$images_dir"
    fi
    mv "$asset" "$images_dir/"
    image_names+=("$(basename "$asset")")
    images_moved=$((images_moved + 1))
  done < <(find "$tmpdir" -maxdepth 2 -type f -print0 2>/dev/null)

  local rewritten="$tmpdir/__rewritten.md"
  if (( images_moved > 0 )); then
    python3 - "$produced" "$rewritten" "$images_dir_basename" "${image_names[@]}" <<'PYEOF'
import re, sys
src, dst, subfolder, *names = sys.argv[1:]
with open(src, 'r', encoding='utf-8') as f:
    body = f.read()
for name in names:
    pattern = r'\]\((?:\./)?(?!{prefix}/){name}\)'.format(
        prefix=re.escape(subfolder),
        name=re.escape(name),
    )
    body = re.sub(pattern, f']({subfolder}/{name})', body)
with open(dst, 'w', encoding='utf-8') as f:
    f.write(body)
PYEOF
  else
    cp "$produced" "$rewritten"
  fi

  {
    frontmatter_block "$(basename "$src")" "kind: document"
    cat "$rewritten"
  } > "$dst"

  rm -rf "$tmpdir"
  converted=$((converted + 1))
  if (( images_moved > 0 )); then
    mi_info "  extracted $images_moved image(s) into $(basename "$images_dir")/"
  fi
  return 0
}

write_stub() {
  # Generate a stub .md referencing the original file. Called for images
  # (always) and for PDFs / other documents when --stub was requested.
  local src="$1"
  local stem="${src%.*}"
  local dst="${stem}.md"
  local rel="${src#"$journal_root"/}"
  local src_basename
  src_basename="$(basename "$src")"
  local ext
  ext="$(lower_ext "$src")"

  if should_skip_existing "$src" "$dst"; then
    skipped=$((skipped + 1))
    mi_info "skip (up-to-date): $rel"
    return 0
  fi

  if (( dry_run )); then
    mi_info "would stub: $rel  ->  ${dst#"$journal_root"/}"
    return 0
  fi

  mi_info "stub: $rel"

  # Tailor the stub body to what the millwright should do with the file.
  case "$ext" in
    png|jpg|jpeg|webp|tiff|tif)
      {
        frontmatter_block "$src_basename" "kind: image"
        cat <<STUB
# Image resource: \`$src_basename\`

Claude reads this image directly via its native vision capability. No
text extraction was performed at ingest time — docling's default image
pipeline handles standalone captures poorly (especially UI screenshots
and diagrams), so it is deliberately skipped here.

![]($src_basename)

When processing this journal entry during stage 1 or stage 2, the
millwright will open the image file and extract whatever labels,
values, diagram structure, or visual context are relevant to the
active feature.
STUB
      } > "$dst"
      ;;
    pdf)
      {
        frontmatter_block "$src_basename" "kind: document-native"
        cat <<STUB
# Document resource: \`$src_basename\`

Claude Code's \`Read\` tool parses this PDF natively (up to 20 pages per
call). The inspector chose native reading over docling ingestion for
this file — appropriate for short text-heavy PDFs where docling's
preprocessing overhead isn't justified.

Original file: \`$src_basename\`

When processing this journal entry during stage 1 or stage 2, the
millwright should open \`$src_basename\` directly via the \`Read\` tool
and extract whatever is relevant to the active feature. For PDFs over
20 pages, use the \`pages\` parameter to chunk (\`pages: "1-20"\`,
\`"21-40"\`, …). If any page range fails to parse, fall back to
\`/mi-ingest --file <path>\` to run docling and regenerate this
companion.
STUB
      } > "$dst"
      ;;
    *)
      {
        frontmatter_block "$src_basename" "kind: document-native"
        cat <<STUB
# Document resource: \`$src_basename\`

The inspector chose native reading over docling ingestion for this
file. NOTE: Claude Code's \`Read\` tool does NOT support \`.docx\`,
\`.pptx\`, or \`.xlsx\` — if \`$src_basename\` is one of those formats,
this stub is a dead end. Re-run \`/mi-ingest --file <path>\` on it to
process via docling, or remove the file from the journal folder.

Original file: \`$src_basename\`
STUB
      } > "$dst"
      ;;
  esac

  converted=$((converted + 1))
  return 0
}

dispatch_by_extension() {
  # Auto-pick docling or stub based on extension.
  local src="$1"
  local ext
  ext="$(lower_ext "$src")"
  case "$ext" in
    pdf|docx|pptx|xlsx|html)    ingest_document "$src" || return 1 ;;
    png|jpg|jpeg|webp|tiff|tif) write_stub "$src" || return 1 ;;
    *) mi_info "skip (unsupported): ${src#"$journal_root"/}" ;;
  esac
}

# ---------- single-file modes ----------
if [[ "$mode" == "file" || "$mode" == "stub" ]]; then
  [[ -f "$single_file" ]] || mi_die "file not found: $single_file"
  # Accept either an absolute path (assumed under journal_root) or a
  # relative path resolved against the CWD.
  if [[ "$single_file" != /* ]]; then
    single_file="$(cd "$(dirname "$single_file")" && pwd)/$(basename "$single_file")"
  fi
  if [[ "$mode" == "file" ]]; then
    dispatch_by_extension "$single_file" || true
  else
    write_stub "$single_file" || true
  fi
  echo
  echo "ingest summary: converted=$converted  skipped=$skipped  failed=$failed"
  (( failed == 0 )) || { echo "failed files:"; printf '  - %s\n' "${failed_paths[@]}"; exit 1; }
  exit 0
fi

# ---------- folder mode ----------
folders=()
if [[ -n "$folder_arg" ]]; then
  target="$journal_root/$folder_arg"
  [[ -d "$target" ]] || mi_die "journal subfolder not found: $target"
  folders+=("$target")
else
  while IFS= read -r -d '' d; do
    folders+=("$d")
  done < <(find "$journal_root" -mindepth 1 -maxdepth 1 -type d -print0)
fi

[[ ${#folders[@]} -gt 0 ]] || mi_die "no journal subfolders to process (journal/ is empty)"

sources=()
for folder in "${folders[@]}"; do
  for ext in "${doc_exts[@]}" "${img_exts[@]}"; do
    while IFS= read -r -d '' src; do
      sources+=("$src")
    done < <(find "$folder" -type f -iname "*.${ext}" -not -path "*/*.images/*" -print0)
  done
done

for src in "${sources[@]}"; do
  dispatch_by_extension "$src" || true
done

echo
echo "ingest summary: converted=$converted  skipped=$skipped  failed=$failed"
if (( failed > 0 )); then
  echo "failed files:"
  printf '  - %s\n' "${failed_paths[@]}"
  exit 1
fi
exit 0
