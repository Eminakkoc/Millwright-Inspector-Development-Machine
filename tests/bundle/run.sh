#!/usr/bin/env bash
# run.sh — golden-fixture test harness for scripts/bundle.sh.
#
# Each fixture lives at tests/bundle/fixtures/<name>/ and is one of two
# flavors:
#
#   Success fixture:
#     input/                — snapshot of millwright-overseer/ data tree
#     expected.md           — bundle output, byte-equal after timestamp norm
#     [expected-stdout.txt] — optional, defaults to "<scrubbed>" check
#     [invoke-from]         — optional, override cwd; supports
#                             {{SANDBOX}} and {{REPO_ROOT}}
#
#   Refusal fixture:
#     input/                — snapshot (or empty for refusal-no-cycle)
#     expected-exit.txt     — expected non-zero exit code, e.g. "2"
#     expected-stderr.txt   — expected stderr contents (substring-match)
#     [invoke-from]         — optional, as above
#
# Placeholders in the fixture's progress.md (and any other file) are
# substituted at runtime:
#   {{WORKTREE_PATH}}     → absolute path to the per-test sandbox
#   {{GIT_COMMON_DIR}}    → $sandbox/.git
#   {{GIT_WORKTREE_DIR}}  → $sandbox/.git
#   {{HEAD_SHA}}          → live `git rev-parse HEAD` after the seed commit
#
# Timestamp normalization: every YYYY-MM-DD HH:MM:SS ±HHMM the script
# would emit (in §5.18 footer + final stdout line) is replaced with the
# literal string `<TIMESTAMP>` before the equality check.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="$TESTS_DIR/fixtures"

BUNDLE_SH="$REPO_ROOT/scripts/bundle.sh"
[[ -x "$BUNDLE_SH" ]] || { echo "bundle.sh missing or not executable: $BUNDLE_SH" >&2; exit 1; }

if [[ ! -d "$FIXTURES" ]]; then
  echo "no fixtures directory: $FIXTURES" >&2
  exit 1
fi

# Allow `run.sh <fixture-name>` to run a single fixture.
selected_fixture="${1:-}"

pass=0
fail=0
fail_names=()

# Replace non-deterministic content with stable tokens before comparison:
#   YYYY-MM-DD HH:MM:SS ±HHMM  → <TIMESTAMP>   (footer human time)
#   YYYYMMDD-HHMMSS[-pid]      → <TS>          (bundle filename timestamp)
#   40-char hex (a git SHA)    → <SHA>         (live HEAD changes per run)
#
# Stays in pure sed because the runner already feeds stdin — adding python3
# heredoc here would collide stdin between the heredoc and the data pipe.
normalize() {
  sed -E \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [+-][0-9]{4}/<TIMESTAMP>/g' \
    -e 's/[0-9]{8}-[0-9]{6}(-[0-9]+)?/<TS>/g' \
    -e 's/[0-9a-f]{40}/<SHA>/g'
}

run_fixture() {
  local name="$1"
  local dir="$FIXTURES/$name"
  local input="$dir/input"

  local sandbox
  sandbox="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$sandbox'" RETURN

  if [[ -d "$input" ]]; then
    cp -R "$input/." "$sandbox/"
  fi

  # Seed git so check-worktree and git rev-parse HEAD work. If the input has
  # no committable content (refusal-no-cycle), still init+commit something.
  (
    cd "$sandbox"
    git init -q
    git config user.email "test@bundle"
    git config user.name "bundle test"
    if [[ -z "$(ls -A 2>/dev/null)" ]]; then
      echo "fixture seed" > .seed
    fi
    git add -A
    git commit -q -m "fixture" || true
  )
  local head_sha
  head_sha="$(cd "$sandbox" && git rev-parse HEAD 2>/dev/null || echo "0000000000000000000000000000000000000000")"

  # Substitute placeholders in any .md (or other text) file in the sandbox.
  while IFS= read -r -d '' f; do
    sed -i.bak \
      -e "s|{{WORKTREE_PATH}}|$sandbox|g" \
      -e "s|{{GIT_COMMON_DIR}}|$sandbox/.git|g" \
      -e "s|{{GIT_WORKTREE_DIR}}|$sandbox/.git|g" \
      -e "s|{{HEAD_SHA}}|$head_sha|g" \
      "$f"
    rm -f "$f.bak"
  done < <(find "$sandbox" -type f \( -name '*.md' -o -name '*.txt' -o -name '*.yaml' -o -name '*.yml' \) -print0)

  # Determine cwd for invocation.
  local cwd="$sandbox"
  if [[ -f "$dir/invoke-from" ]]; then
    local raw
    raw="$(cat "$dir/invoke-from")"
    raw="${raw//\{\{SANDBOX\}\}/$sandbox}"
    raw="${raw//\{\{REPO_ROOT\}\}/$REPO_ROOT}"
    raw="${raw//$'\n'/}"
    cwd="$raw"
    mkdir -p "$cwd"
  fi

  # Run bundle.sh, capturing stdout and stderr separately.
  local out_file="$sandbox/.actual.stdout"
  local err_file="$sandbox/.actual.stderr"
  local exit_code=0
  (
    cd "$cwd"
    MO_DATA_ROOT="$sandbox/millwright-overseer" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
      "$BUNDLE_SH" export
  ) >"$out_file" 2>"$err_file" || exit_code=$?

  # ---- Refusal-fixture path ------------------------------------------------
  if [[ -f "$dir/expected-exit.txt" ]]; then
    local expected_exit
    expected_exit="$(cat "$dir/expected-exit.txt" | tr -d '[:space:]')"
    if [[ "$exit_code" != "$expected_exit" ]]; then
      echo "✗ $name (expected exit $expected_exit, got $exit_code)"
      echo "  stderr: $(head -1 "$err_file")"
      fail=$((fail + 1)); fail_names+=("$name")
      return
    fi
    if [[ -f "$dir/expected-stderr.txt" ]]; then
      local needle
      needle="$(cat "$dir/expected-stderr.txt")"
      if ! grep -qF -- "$needle" "$err_file"; then
        echo "✗ $name (stderr did not contain expected substring)"
        echo "  expected substring: $needle"
        echo "  actual stderr: $(cat "$err_file")"
        fail=$((fail + 1)); fail_names+=("$name")
        return
      fi
    fi
    # Also assert no bundle file leaked.
    if find "$sandbox" -path "*/tmp/bundles/*.md" -type f 2>/dev/null | grep -q .; then
      echo "✗ $name (a bundle was written despite refusal)"
      fail=$((fail + 1)); fail_names+=("$name")
      return
    fi
    echo "✓ $name (refused as expected, exit=$exit_code)"
    pass=$((pass + 1))
    return
  fi

  # ---- Success-fixture path ------------------------------------------------
  if [[ "$exit_code" -ne 0 ]]; then
    echo "✗ $name (exited $exit_code)"
    echo "  stderr: $(cat "$err_file")"
    fail=$((fail + 1)); fail_names+=("$name")
    return
  fi

  # Find the bundle file.
  local bundle_path
  bundle_path="$(find "$sandbox" -path "*/tmp/bundles/*-stage*.md" -type f | head -1)"
  if [[ -z "$bundle_path" ]]; then
    echo "✗ $name (no bundle produced)"
    fail=$((fail + 1)); fail_names+=("$name")
    return
  fi

  if [[ ! -f "$dir/expected.md" ]]; then
    echo "  $name (no expected.md; capturing actual)"
    normalize <"$bundle_path" > "$dir/expected.md"
    echo "✓ $name (captured baseline)"
    pass=$((pass + 1))
    return
  fi

  local actual_norm expected_norm
  actual_norm="$(normalize <"$bundle_path")"
  expected_norm="$(cat "$dir/expected.md")"

  if [[ "$actual_norm" == "$expected_norm" ]]; then
    echo "✓ $name"
    pass=$((pass + 1))
  else
    echo "✗ $name"
    diff -u <(echo "$expected_norm") <(echo "$actual_norm") | head -40 | sed 's/^/  /'
    fail=$((fail + 1)); fail_names+=("$name")
  fi
}

# Iterate fixtures.
shopt -s nullglob
for fixture_dir in "$FIXTURES"/*/; do
  name="$(basename "$fixture_dir")"
  if [[ -n "$selected_fixture" && "$name" != "$selected_fixture" ]]; then
    continue
  fi
  run_fixture "$name"
done

# Summary.
echo ""
total=$((pass + fail))
echo "$pass / $total passed"
if [[ $fail -gt 0 ]]; then
  echo "failed: ${fail_names[*]}"
  exit 1
fi
exit 0
