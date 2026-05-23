#!/usr/bin/env bash
# doctor.sh — check millwright-inspector-development-machine dependencies and emit a structured report.
#
# Usage:
#   doctor.sh                      # full check, JSON output, exit 0|1|2
#   doctor.sh --preflight          # fast check of required deps only; exit 0 if all ok, 1 if any missing
#   doctor.sh --format=human       # human-readable summary (for interactive use)
#
# Exit codes:
#   0 — all required deps present (may have warnings for optional)
#   1 — optional deps missing (warnings only)
#   2 — required deps missing (errors)

set -uo pipefail
source "$(dirname "$0")/internal/common.sh"

format="json"
preflight=0
for arg in "$@"; do
  case "$arg" in
    --preflight)     preflight=1 ;;
    --format=human)  format="human" ;;
    --format=json)   format="json" ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
  esac
done

# ---------- OS detection ---------------------------------------------------
os="unknown"
case "$(uname -s)" in
  Darwin) os="darwin" ;;
  Linux)
    if [[ -r /etc/os-release ]]; then
      . /etc/os-release
      case "${ID:-}" in
        ubuntu|debian) os="linux-apt" ;;
        arch|manjaro)  os="linux-pacman" ;;
        fedora|rhel|centos) os="linux-dnf" ;;
        alpine)        os="linux-apk" ;;
        *)             os="linux-generic" ;;
      esac
    else
      os="linux-generic"
    fi
    ;;
  MINGW*|MSYS*|CYGWIN*) os="windows" ;;
esac

# ---------- Check primitives ----------------------------------------------
results=()        # array of JSON objects
worst_severity=0  # 0=ok, 1=warn, 2=error

record() {
  # record <name> <kind: cli|pymod|plugin|env> <required: true|false> <present: true|false> <version> <install_hints_json>
  local name="$1" kind="$2" required="$3" present="$4" version="$5" hints="$6"
  local severity=0
  if [[ "$present" == "false" ]]; then
    if [[ "$required" == "true" ]]; then severity=2; else severity=1; fi
  fi
  (( severity > worst_severity )) && worst_severity=$severity

  # Produce a JSON object.
  local json
  json=$(python3 - "$name" "$kind" "$required" "$present" "$version" "$hints" "$severity" <<'PYEOF'
import sys, json
name, kind, req, pres, version, hints_json, sev = sys.argv[1:]
print(json.dumps({
    "name": name,
    "kind": kind,
    "required": req == "true",
    "present": pres == "true",
    "version": version,
    "install_hints": json.loads(hints_json) if hints_json.strip() else {},
    "severity": {0:"ok",1:"warn",2:"error"}[int(sev)],
}))
PYEOF
)
  results+=("$json")
}

check_cli() {
  # check_cli <binary> <required> <hints_json>
  local bin="$1" required="$2" hints="$3"
  if command -v "$bin" >/dev/null 2>&1; then
    local version
    version="$("$bin" --version 2>&1 | head -1 | tr '\n' ' ' | sed 's/"/\\"/g' || echo "unknown")"
    record "$bin" cli "$required" true "$version" "$hints"
  else
    record "$bin" cli "$required" false "" "$hints"
  fi
}

check_pymod() {
  # check_pymod <module> <required> <hints_json>
  local mod="$1" required="$2" hints="$3"
  if python3 -c "import $mod" >/dev/null 2>&1; then
    local version
    version="$(python3 -c "import $mod; print(getattr($mod, '__version__', 'unknown'))" 2>/dev/null || echo "unknown")"
    record "$mod" pymod "$required" true "$version" "$hints"
  else
    record "$mod" pymod "$required" false "" "$hints"
  fi
}

check_skill_local_or_plugin() {
  # Checks whether either the superpowers plugin is installed, OR a local skill at .claude/skills/<name>/SKILL.md exists.
  local name="$1" required="$2"
  local present="false" location=""

  # Local project skill?
  if [[ -f ".claude/skills/${name}/SKILL.md" ]]; then
    present="true"; location="local: .claude/skills/${name}"
  fi
  # Agent/user-scope plugins often land in ~/.claude/plugins/cache/<marketplace>/superpowers/**
  # Path depth: cache/<marketplace>/<plugin>/skills/<skill>/SKILL.md is typically 6 levels under
  # the cache root; allow a bit of headroom (-maxdepth 8) in case marketplaces add an extra layer.
  if find "${HOME}/.claude/plugins/cache" -maxdepth 8 -name "SKILL.md" -path "*/superpowers/*${name}/*" 2>/dev/null | grep -q .; then
    present="true"; [[ -z "$location" ]] && location="plugin: superpowers"
  fi

  # kind=plugin hints are instructions, not Bash-runnable commands. mi-doctor.md renders
  # these verbatim and asks the inspector to run them inside the Claude Code session.
  local hints='{"any":"Run inside Claude Code: `/plugin marketplace add <superpowers-source>` then `/plugin install superpowers@<marketplace>`. Alternatively, copy a SKILL.md into `.claude/skills/'"$name"'/`. Re-run /mi-doctor after installing."}'
  record "$name" plugin "$required" "$present" "$location" "$hints"
}

check_repo_file() {
  # check_repo_file <name> <relative-path> <required>
  # Records present=true (severity=ok) when "$MI_PLUGIN_ROOT/$relpath" exists,
  # present=false otherwise. install_hints is empty (these are repo artifacts;
  # the operator fixes them via the manual-testing implementation, not via apt/brew).
  local name="$1" relpath="$2" required="$3"
  local target="${MI_PLUGIN_ROOT}/$relpath"
  if [[ -e "$target" ]]; then
    record "$name" env "$required" true "$relpath" '{}'
  else
    record "$name" env "$required" false "" "$(printf '{"any": "missing %s — implement docs/manual-testing/plan.md or restore from git history"}' "$relpath")"
  fi
}

check_review_sh_subcommand() {
  # check_review_sh_subcommand <subcommand> <required>
  # Probes `review.sh <sub> --help` (no `--help` is implemented, so we instead
  # run the subcommand with deliberately invalid args and look for a usage line
  # naming the subcommand). Cheaper alternative: grep the script source for the
  # case label, which is what we do here — same signal, no side effects.
  local sub="$1" required="$2"
  if grep -qE "^  ${sub}\\)" "${MI_PLUGIN_ROOT}/scripts/review.sh" 2>/dev/null; then
    record "review.sh:${sub}" env "$required" true "scripts/review.sh" '{}'
  else
    record "review.sh:${sub}" env "$required" false "" "$(printf '{"any": "review.sh missing subcommand %s — implement docs/manual-testing/plan.md § 3.7"}' "$sub")"
  fi
}

check_progress_schema_field() {
  # check_progress_schema_field <name> <pattern> <required>
  # Greps schemas/progress.schema.yaml for <pattern>. Used to verify the
  # manual-testing additions landed (sub-flow enum value, manual-test-state
  # field, manual-test-failure-policy field). Each is recorded separately so
  # the operator knows which piece is missing on partial updates.
  local name="$1" pattern="$2" required="$3"
  if grep -qE "$pattern" "${MI_PLUGIN_ROOT}/schemas/progress.schema.yaml" 2>/dev/null; then
    record "$name" env "$required" true "schemas/progress.schema.yaml" '{}'
  else
    record "$name" env "$required" false "" "$(printf '{"any": "schemas/progress.schema.yaml missing %s — implement docs/manual-testing/plan.md § 1.2-1.3"}' "$name")"
  fi
}

check_review_sh_field_re() {
  # check_review_sh_field_re — verifies FIELD_RE recognizes `source` and `seed-id`.
  # This is the highest-risk silent-failure: without the extension, canonicalize
  # corrupts auto-seeded blocks (the `source` and `seed-id` lines look like
  # freeform paragraphs and break IR_HEAD_RE boundaries).
  if grep -qE "severity\|scope\|status\|source\|seed-id\|details\|fix-note" "${MI_PLUGIN_ROOT}/scripts/review.sh" 2>/dev/null; then
    record "review.sh:FIELD_RE" env true true "extended" '{}'
  else
    record "review.sh:FIELD_RE" env true false "" '{"any": "review.sh FIELD_RE missing source/seed-id extension — implement docs/manual-testing/plan.md § 3.7.3 (canonicalize will silently corrupt auto-seeded blocks without it)"}'
  fi
}

check_env_git_repo() {
  # `--is-inside-work-tree` returns true even on a freshly-initialized repo
  # with zero commits, where HEAD is unborn. Stage 3+ uses
  # `git rev-parse HEAD` and `git log <base>..HEAD`, both of which fail in
  # that state, so the preflight must require a verifiable HEAD too.
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    record "git-repo" env true false "" '{"any":"run `git init` and make an initial commit"}'
    return
  fi
  if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
    # Inside a work tree but HEAD is unborn — repo has no commits.
    record "git-repo" env true false "(no commits yet — HEAD is unborn)" '{"any":"create an initial commit (e.g. `git commit --allow-empty -m \"chore: initial commit\"`); the workflow needs a HEAD that downstream stages can diff against"}'
    return
  fi
  record "git-repo" env true true "$(git rev-parse --abbrev-ref HEAD)" '{"any":"run `git init` and make an initial commit"}'
}

# ---------- Hint builders -------------------------------------------------
hints_yq() {
  cat <<'JSON'
{
  "darwin": "brew install yq",
  "linux-apt": "sudo snap install yq  # or: sudo add-apt-repository ppa:rmescandon/yq && sudo apt update && sudo apt install yq",
  "linux-pacman": "sudo pacman -S go-yq",
  "linux-dnf": "sudo dnf install yq  # or: go install github.com/mikefarah/yq/v4@latest",
  "linux-apk": "sudo apk add yq",
  "linux-generic": "go install github.com/mikefarah/yq/v4@latest",
  "windows": "winget install MikeFarah.yq",
  "any": "curl -L https://github.com/mikefarah/yq/releases/latest/download/yq_$(uname -s | tr A-Z a-z)_amd64 -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq"
}
JSON
}

hints_plantuml_mcp() {
  cat <<'JSON'
{
  "any": "npm install -g plantuml-mcp-server",
  "note": "requires Node.js and a Java runtime (PlantUML dep). On macOS: `brew install node openjdk`. On Debian/Ubuntu: `sudo apt install nodejs npm default-jre`."
}
JSON
}

hints_python3() {
  cat <<'JSON'
{
  "darwin": "brew install python3",
  "linux-apt": "sudo apt install python3",
  "linux-pacman": "sudo pacman -S python",
  "linux-dnf": "sudo dnf install python3",
  "any": "install Python 3.8+ from https://www.python.org/downloads/"
}
JSON
}

hints_pyyaml() {
  cat <<'JSON'
{
  "any": "python3 -m pip install --user pyyaml",
  "note": "if pip is missing: `python3 -m ensurepip --user`"
}
JSON
}

hints_ajv() {
  cat <<'JSON'
{
  "any": "npm install -g ajv-cli",
  "note": "optional — enables deep JSON Schema validation. Falls back to python3-jsonschema or yq if absent."
}
JSON
}

hints_jsonschema() {
  cat <<'JSON'
{
  "any": "python3 -m pip install --user jsonschema",
  "note": "optional — secondary fallback for schema validation when ajv-cli is absent."
}
JSON
}

hints_rtk() {
  cat <<'JSON'
{
  "darwin": "brew install rtk && rtk init -g",
  "any": "https://github.com/rtk-ai/rtk  (install binary, then run `rtk init -g` to register the Claude Code pre-tool-use hook)",
  "note": "optional — filters verbose shell output (git diff, test runs, etc.) before Claude sees it. Large token savings in /mi-review, /mi-generate-implementation-diagrams, and the brainstorming chain."
}
JSON
}

hints_docling() {
  cat <<'JSON'
{
  "darwin": "pipx install docling  # or: python3 -m pip install --user docling",
  "linux-apt": "pipx install docling  # or: python3 -m pip install --user docling  (may need `sudo apt install pipx` first)",
  "linux-pacman": "pipx install docling  # or: python3 -m pip install --user docling",
  "linux-dnf": "pipx install docling  # or: python3 -m pip install --user docling",
  "any": "pipx install docling  # or: python3 -m pip install --user docling",
  "note": "optional — enables /mi-ingest, which converts non-text journal files (.pdf, .docx, .pptx, .xlsx, images) into sibling .md so /mi-run can consume them. Skip if your journal folder will only ever contain .md and .txt. Pulls ML dependencies (torch, transformers); the first `docling <file>` may download a few hundred MB of models."
}
JSON
}

hints_git() {
  cat <<'JSON'
{
  "darwin": "brew install git",
  "linux-apt": "sudo apt install git",
  "linux-pacman": "sudo pacman -S git",
  "linux-dnf": "sudo dnf install git",
  "any": "https://git-scm.com/downloads"
}
JSON
}

hints_gh() {
  cat <<'JSON'
{
  "darwin": "brew install gh",
  "linux-apt": "sudo apt install gh",
  "linux-pacman": "sudo pacman -S github-cli",
  "linux-dnf": "sudo dnf install gh",
  "any": "https://cli.github.com/  — then run `gh auth login`",
  "note": "optional — required only for /mi-analyze-review (PR-review analysis). After installing, authenticate with `gh auth login`."
}
JSON
}

hints_codex() {
  cat <<'JSON'
{
  "darwin": "brew install codex",
  "linux": "see https://github.com/openai/codex"
}
JSON
}

# ---------- Run checks ----------------------------------------------------

# REQUIRED
check_cli git true       "$(hints_git)"
check_cli python3 true   "$(hints_python3)"
check_cli yq true        "$(hints_yq)"
check_pymod yaml true    "$(hints_pyyaml)"
check_cli plantuml-mcp-server true "$(hints_plantuml_mcp)"
check_env_git_repo

# Either uuidgen or python3 satisfies UUID generation; python3 is already checked.
if command -v uuidgen >/dev/null 2>&1; then
  record uuidgen cli false true "$(uuidgen 2>/dev/null | head -c 8 || echo ok)" '{}'
fi

# OPTIONAL
check_cli ajv false      "$(hints_ajv)"
check_pymod jsonschema false "$(hints_jsonschema)"

# OPTIONAL — gh (GitHub CLI) powers /mi-analyze-review (PR-review analysis).
# Not needed for the core 8-stage workflow; safe to omit if you never analyze
# PR reviews. /mi-analyze-review does its own gh preflight + auth check.
check_cli gh false "$(hints_gh)"

# OPTIONAL companions — token-reduction tools that our commands auto-detect and use
# when present. Never required; missing = normal operation.
check_cli rtk false              "$(hints_rtk)"

# OPTIONAL ingest — docling powers /mi-ingest (non-text journal files → sibling .md).
# Safe to omit for text-only journals.
check_cli docling false "$(hints_docling)"

# OPTIONAL — codex CLI + mcp-server subcommand (used by blueprint-review commands).
# Missing codex disables stage-2 auto-review but the rest of the workflow is unaffected.
#
# v1.4 token-reduction refit (docs/blueprint-review-token-reduction/plan.md) additionally
# depends on the mcp__codex__codex-reply tool for session continuation. That tool was
# introduced in codex-cli 0.130.0. Older codex versions still work — the sub-agents fall
# back to stateless mode (each round = fresh codex call, ~60% reduction instead of ~95%) —
# but the doctor probe surfaces an informational note when the version is too old to
# benefit from session continuation.
if command -v codex >/dev/null 2>&1; then
  codex_version="$(codex --version 2>/dev/null | head -1 || echo 'unknown')"
  if codex mcp-server --help >/dev/null 2>&1; then
    # Try to extract the numeric version (e.g., "codex-cli 0.133.0" → "0.133.0") and gate
    # on >= 0.130.0 for codex-reply availability. If parsing fails, assume modern.
    codex_num="$(echo "$codex_version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    codex_reply_note=""
    if [[ -n "$codex_num" ]]; then
      if printf '%s\n%s\n' "0.130.0" "$codex_num" | sort -V -C 2>/dev/null; then
        codex_reply_note=" (codex-reply available)"
      else
        codex_reply_note=" (codex-reply unavailable; v1.4 review falls back to stateless mode — upgrade to 0.130.0+ for ~95% token reduction)"
      fi
    fi
    record "codex" cli false true "${codex_version}${codex_reply_note}" '{}'
  else
    # Binary exists but the mcp-server subcommand is missing — this CLI is too
    # old / wrong build.
    record "codex" cli false false "$codex_version (no mcp-server)" "$(hints_codex)"
  fi
else
  record "codex" cli false false "" "$(hints_codex)"
fi

# REQUIRED skills — stage 3 of the workflow hands off to brainstorming → writing-plans →
# executing-plans / subagent-driven-development → finishing-a-development-branch. Each must
# be available either via the superpowers plugin OR a local `.claude/skills/<name>/SKILL.md`.
for s in brainstorming writing-plans executing-plans subagent-driven-development finishing-a-development-branch; do
  check_skill_local_or_plugin "$s" true
done

# REQUIRED manual-testing feature artifacts (stage-5 sub-flow per docs/manual-testing/plan.md).
# These are repo artifacts the manual-testing implementation creates; they must be present for
# /mi-manual-test-plan and /mi-manual-test-run to function. Missing pieces surface as clear
# named checks rather than as cryptic runtime errors.
check_repo_file "templates/manual-test-plan.md.tmpl"      "templates/manual-test-plan.md.tmpl"     true
check_repo_file "templates/manual-test-results.md.tmpl"   "templates/manual-test-results.md.tmpl"  true
check_repo_file "schemas/manual-test-plan.schema.yaml"    "schemas/manual-test-plan.schema.yaml"   true
check_repo_file "schemas/manual-test-results.schema.yaml" "schemas/manual-test-results.schema.yaml" true

# Verify progress.schema.yaml carries the manual-testing additions (each grepped separately so
# partial updates surface clearly).
check_progress_schema_field "schema:sub-flow=manual-testing"   "manual-testing"             true
check_progress_schema_field "schema:manual-test-state"          "^          manual-test-state:"          true
check_progress_schema_field "schema:manual-test-failure-policy" "^          manual-test-failure-policy:" true
# activation-id field on active block — cross-activation discriminator for the
# stage-5 manual-test results-rotation guard (docs/manual-testing-folder/plan.md § 4.3).
check_progress_schema_field "schema:activation-id"              "^          activation-id:"              true

# Verify review.sh has the new subcommands and the FIELD_RE extension.
check_review_sh_subcommand upsert-manual-test-failure true
check_review_sh_subcommand find-by-seed-id            true
check_review_sh_subcommand find-by-seed-id-family     true
check_review_sh_field_re

# Verify blueprints.sh has the manual-test path resolvers and rotate.
for sub in manual-test-plan-path manual-test-results-path manual-test-plan-rotate manual-test-results-rotate-only; do
  if grep -qE "^  ${sub}\\)" "${MI_PLUGIN_ROOT}/scripts/blueprints.sh" 2>/dev/null; then
    record "blueprints.sh:${sub}" env true true "scripts/blueprints.sh" '{}'
  else
    record "blueprints.sh:${sub}" env true false "" "$(printf '{"any": "blueprints.sh missing subcommand %s — implement docs/manual-testing/plan.md § 3.6"}' "$sub")"
  fi
done

# ---------- Preflight short-circuit --------------------------------------
if (( preflight )); then
  # Preflight: exit 0 iff all required deps are present (worst_severity < 2).
  if (( worst_severity >= 2 )); then
    echo "millwright-inspector-development-machine preflight: required dependencies missing. Run /mi-doctor for details." >&2
    exit 1
  fi
  exit 0
fi

# ---------- Emit report ---------------------------------------------------
if [[ "$format" == "human" ]]; then
  echo "millwright-inspector-development-machine dependency report (os=$os)"
  echo "-----------------------------------"
  for r in "${results[@]}"; do
    python3 - "$r" <<'PYEOF'
import sys, json
r = json.loads(sys.argv[1])
sym = {"ok":"✓", "warn":"⚠", "error":"✗"}[r["severity"]]
req = "required" if r["required"] else "optional"
ver = f" ({r['version']})" if r['present'] and r['version'] else ""
print(f"  {sym} {r['name']}{ver}  [{req}]")
PYEOF
  done
  case "$worst_severity" in
    0) echo; echo "All required dependencies present." ;;
    1) echo; echo "Required OK. Some optional deps missing — run in JSON mode for install hints." ;;
    2) echo; echo "Required dependencies missing. See JSON output (--format=json) for install hints." ;;
  esac
else
  python3 - "$os" "$worst_severity" "${results[@]}" <<'PYEOF'
import sys, json
os_name = sys.argv[1]
severity = int(sys.argv[2])
checks = [json.loads(x) for x in sys.argv[3:]]
summary = {"ok":"all required dependencies present","warn":"required ok; some optional missing","error":"required dependencies missing"}[
    ["ok","warn","error"][severity]
]
print(json.dumps({"os": os_name, "status": ["ok","warn","error"][severity], "summary": summary, "checks": checks}, indent=2))
PYEOF
fi

exit $worst_severity
