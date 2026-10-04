#!/usr/bin/env bash
# run.sh — tests for scripts/skills.sh (skills-across-workflow, SKL-001/005/012).
#
# Each test prints PASS/FAIL; the suite exits 1 if any test failed. Every test
# runs in a sandbox git repo with its own HOME and a stub `catalog` on PATH, so
# the real ~/.claude and the real catalog CLI are never read.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$REPO_ROOT/tests/skills/fixtures"
S="$REPO_ROOT/scripts/skills.sh"

pass=0
fail=0
fail_names=()

ok() { printf "\xe2\x9c\x93 %s\n" "$1"; pass=$((pass + 1)); }
ng() { printf "\xe2\x9c\x97 %s\n   %s\n" "$1" "$2" >&2; fail=$((fail + 1)); fail_names+=("$1"); }

SANDBOXES=()
cleanup() {
  local s
  for s in ${SANDBOXES[@]+"${SANDBOXES[@]}"}; do
    [[ -n "$s" && -d "$s" ]] && rm -rf "$s"
  done
}
trap cleanup EXIT

# A PATH with python3 and git but without the real catalog CLI.
BASE_PATH="$(dirname "$(command -v python3)"):$(dirname "$(command -v git)"):/usr/bin:/bin"

# make_sandbox — git repo + data root + fake HOME + stub bin dir (empty).
# Layout: $sb/repo (cwd for every command), $sb/home, $sb/bin, $sb/catalog-data.
make_sandbox() {
  local sb
  sb="$(cd "$(mktemp -d)" && pwd -P)"
  SANDBOXES+=("$sb")
  mkdir -p "$sb/repo" "$sb/home/.claude" "$sb/bin" "$sb/catalog-data"
  (cd "$sb/repo" && git init -q -b main && git config user.email t@t && git config user.name t \
     && echo seed > README.md && git add README.md && git commit -qm seed)
  printf '%s' "$sb"
}

# install_stub_catalog <sb> — `catalog list --json` prints catalog-data/list.json;
# `--bundles` prints catalog-data/bundles.json, or exits 1 when that file is absent.
install_stub_catalog() {
  cat > "$1/bin/catalog" <<'EOF'
#!/usr/bin/env bash
d="$(dirname "$0")/../catalog-data"
if [[ "$*" == "list --json --bundles" ]]; then
  [[ -f "$d/bundles.json" ]] || { echo "unknown option --bundles" >&2; exit 1; }
  cat "$d/bundles.json"; exit 0
fi
[[ "$*" == "list --json" ]] && { cat "$d/list.json"; exit 0; }
exit 1
EOF
  chmod +x "$1/bin/catalog"
}

# run_in <sb> <cmd...> — cwd = repo, isolated HOME/PATH, data root in the repo.
run_in() {
  local sb="$1"; shift
  (cd "$sb/repo" && env -u CLAUDE_PLUGIN_ROOT HOME="$sb/home" PATH="$sb/bin:$BASE_PATH" \
     MI_DATA_ROOT="$sb/repo/millwright-inspector" "$@")
}

write_skill() { # <dir> <description>
  mkdir -p "$1"
  printf -- '---\nname: %s\ndescription: %s\n---\n\n# body\n' "$(basename "$1")" "$2" > "$1/SKILL.md"
}

CATALOG_FLAT='{
  "web-images": {"kind": "skill", "scope": "project", "description": "Optimise images for the web", "requires": ["imgtool", "some-rule"]},
  "alpha": {"kind": "skill", "scope": "project", "description": "catalog copy of alpha"},
  "uskill": {"kind": "skill", "scope": "user", "description": "user-scope skill"},
  "some-rule": {"kind": "rule", "scope": "project", "description": "a rule"},
  "figma-mcp": {"kind": "mcp", "scope": "project", "description": "an MCP server"},
  "imgtool": {"kind": "tool", "scope": "user", "bin": "imgtool-bin", "description": "a CLI"}
}'

# inventory_sandbox — project skill alpha, personal skill (must never appear),
# plugin skills via settings precedence + installed_plugins.json, a broken lock
# entry, and the flat stub catalog.
inventory_sandbox() {
  local sb
  sb="$(make_sandbox)"
  write_skill "$sb/repo/.claude/skills/alpha" "Alpha project skill"
  write_skill "$sb/home/.claude/skills/personal-one" "Personal skill"
  write_skill "$sb/plugins/plug-old/skills/x" "old copy of x"
  write_skill "$sb/plugins/plug-new/skills/x" "Plugin skill x"
  write_skill "$sb/plugins/plug2/skills/y" "Plugin skill y"
  cat > "$sb/home/.claude/settings.json" <<'EOF'
{"enabledPlugins": {"plug@m": true, "plug2@m": true}}
EOF
  cat > "$sb/repo/.claude/settings.local.json" <<'EOF'
{"enabledPlugins": {"plug2@m": false}}
EOF
  mkdir -p "$sb/home/.claude/plugins"
  cat > "$sb/home/.claude/plugins/installed_plugins.json" <<EOF
{"version": 2, "plugins": {
  "plug@m": [{"scope": "user", "installPath": "$sb/plugins/plug-old"},
             {"scope": "project", "projectPath": "$sb/repo", "installPath": "$sb/plugins/plug-new"}],
  "plug2@m": [{"scope": "user", "installPath": "$sb/plugins/plug2"}]
}}
EOF
  cat > "$sb/repo/.claude/catalog.lock.json" <<'EOF'
{"version": 1, "items": {
  "alpha": {"kind": "skill", "files": [".claude/skills/alpha"]},
  "gone": {"kind": "skill", "files": [".claude/skills/gone"]}
}}
EOF
  printf '%s\n' "$CATALOG_FLAT" > "$sb/catalog-data/list.json"
  install_stub_catalog "$sb"
  printf '%s' "$sb"
}

row_for() { printf '%s\n' "$1" | awk -F'\t' -v n="$2" '$1 == n'; }

# ---- inventory -----------------------------------------------------------------
sb="$(inventory_sandbox)"
out="$(run_in "$sb" "$S" inventory 2>"$sb/err")"; rc=$?

t="inventory exits 0 and prints six-column TSV"
bad="$(printf '%s\n' "$out" | awk -F'\t' 'NF != 6' | head -1)"
if [[ $rc -eq 0 && -n "$out" && -z "$bad" ]]; then ok "$t"; else ng "$t" "rc=$rc bad=[$bad]"; fi

t="inventory lists the project skill with a project-relative path"
if [[ "$(row_for "$out" alpha)" == "$(printf 'alpha\tskill\tproject\tAlpha project skill\t.claude/skills/alpha/SKILL.md\t-')" ]]; then ok "$t"
else ng "$t" "got [$(row_for "$out" alpha)]"; fi

t="inventory never lists personal ~/.claude/skills"
if [[ -z "$(row_for "$out" personal-one)" ]]; then ok "$t"; else ng "$t" "personal skill listed"; fi

t="inventory lists enabled plugin skills from this project's install record"
if [[ "$(row_for "$out" plug:x)" == "$(printf 'plug:x\tskill\tplugin:plug\tPlugin skill x\t%s\t-' "$sb/plugins/plug-new/skills/x/SKILL.md")" ]]; then ok "$t"
else ng "$t" "got [$(row_for "$out" plug:x)]"; fi

t="inventory honours enabledPlugins precedence (project-local false wins)"
if [[ -z "$(row_for "$out" plug2:y)" ]]; then ok "$t"; else ng "$t" "plug2:y listed"; fi

t="inventory reports a lock entry with missing files as broken"
if [[ "$(row_for "$out" gone | cut -f2,3)" == "$(printf 'broken\tcatalog')" ]]; then ok "$t"
else ng "$t" "got [$(row_for "$out" gone)]"; fi

t="inventory lists only project-scope catalog skills not already installed"
names="$(printf '%s\n' "$out" | awk -F'\t' '$2 == "catalog-skill" {print $1}' | tr '\n' ' ')"
if [[ "$names" == "web-images " ]]; then ok "$t"; else ng "$t" "catalog-skill rows: [$names]"; fi

t="inventory needs lists the missing tool and the unlocked rule"
if [[ "$(row_for "$out" web-images | cut -f6)" == "imgtool,some-rule" ]]; then ok "$t"
else ng "$t" "got [$(row_for "$out" web-images | cut -f6)]"; fi

t="inventory needs is - once the tool is on PATH and the rule is locked"
printf '#!/bin/sh\n' > "$sb/bin/imgtool-bin"; chmod +x "$sb/bin/imgtool-bin"
printf '{"version": 1, "items": {"some-rule": {"kind": "rule", "files": [".claude/rules/some-rule.md"]}}}\n' \
  > "$sb/home/.claude/catalog.lock.json"
got="$(run_in "$sb" "$S" inventory 2>/dev/null | awk -F'\t' '$1 == "web-images" {print $6}')"
if [[ "$got" == "-" ]]; then ok "$t"; else ng "$t" "got [$got]"; fi

t="inventory accepts the .items-wrapped catalog form"
printf '{"items": %s}\n' "$CATALOG_FLAT" > "$sb/catalog-data/list.json"
got="$(run_in "$sb" "$S" inventory 2>/dev/null | awk -F'\t' '$2 == "catalog-skill" {print $1}')"
if [[ "$got" == "web-images" ]]; then ok "$t"; else ng "$t" "got [$got]"; fi

t="inventory --installed skips the catalog and prints no note"
got="$(run_in "$sb" "$S" inventory --installed 2>"$sb/err2" | awk -F'\t' '$2 == "catalog-skill"')"
if [[ -z "$got" && ! -s "$sb/err2" ]]; then ok "$t"; else ng "$t" "rows=[$got] err=[$(cat "$sb/err2")]"; fi

t="inventory without catalog prints one stderr note and exits 0"
rm "$sb/bin/catalog"
got="$(run_in "$sb" "$S" inventory 2>"$sb/err3")"; rc=$?
if [[ $rc -eq 0 && -n "$(row_for "$got" alpha)" \
      && "$(cat "$sb/err3")" == "catalog CLI not found — catalog suggestions skipped" ]]; then ok "$t"
else ng "$t" "rc=$rc err=[$(cat "$sb/err3")]"; fi

t="inventory cuts descriptions at 200 characters"
sb2="$(make_sandbox)"
write_skill "$sb2/repo/.claude/skills/long" "$(printf 'x%.0s' $(seq 1 250))"
got="$(run_in "$sb2" "$S" inventory --installed | awk -F'\t' '$1 == "long" {print length($4)}')"
if [[ "$got" == "200" ]]; then ok "$t"; else ng "$t" "length=$got"; fi

t="inventory in an empty project prints nothing and exits 0"
sb3="$(make_sandbox)"
got="$(run_in "$sb3" "$S" inventory --installed)"; rc=$?
if [[ $rc -eq 0 && -z "$got" ]]; then ok "$t"; else ng "$t" "rc=$rc out=[$got]"; fi

# ---- lookup --------------------------------------------------------------------
sb="$(inventory_sandbox)"
printf '{"mix": {"description": "mixed", "items": ["web-images", "some-rule", "figma-mcp", "ghost"]}}\n' \
  > "$sb/catalog-data/bundles.json"

t="lookup expands a bundle mixing a skill, a rule, an MCP server and an unknown name"
got="$(run_in "$sb" "$S" lookup bundle:mix)"
exp="$(printf 'web-images\tskill\tproject\tmix\nsome-rule\trule\tproject\tmix\nfigma-mcp\tmcp\tproject\tmix\nghost\tunknown\t-\tmix')"
if [[ "$got" == "$exp" ]]; then ok "$t"; else ng "$t" "got [$got]"; fi

t="lookup reports scope for a user-scope skill and unknown for unlisted names"
got="$(run_in "$sb" "$S" lookup uskill nope)"
exp="$(printf 'uskill\tskill\tuser\t-\nnope\tunknown\t-\t-')"
if [[ "$got" == "$exp" ]]; then ok "$t"; else ng "$t" "got [$got]"; fi

t="lookup treats a bundle as unknown when --bundles is unsupported"
rm "$sb/catalog-data/bundles.json"
got="$(run_in "$sb" "$S" lookup bundle:mix web-images)"
exp="$(printf 'bundle:mix\tunknown\t-\t-\nweb-images\tskill\tproject\t-')"
if [[ "$got" == "$exp" ]]; then ok "$t"; else ng "$t" "got [$got]"; fi

t="lookup without catalog prints one note and every name as unknown"
rm "$sb/bin/catalog"
got="$(run_in "$sb" "$S" lookup web-images bundle:mix 2>"$sb/err")"; rc=$?
exp="$(printf 'web-images\tunknown\t-\t-\nbundle:mix\tunknown\t-\t-')"
if [[ $rc -eq 0 && "$got" == "$exp" \
      && "$(cat "$sb/err")" == "catalog CLI not found — catalog suggestions skipped" ]]; then ok "$t"
else ng "$t" "rc=$rc got=[$got] err=[$(cat "$sb/err")]"; fi

# ---- brief / entries -----------------------------------------------------------
# feature_sandbox <config-fixture> — sandbox whose feature "feat" has that config.md.
feature_sandbox() {
  local sb cur
  sb="$(make_sandbox)"
  cur="$sb/repo/millwright-inspector/workflow-stream/feat/blueprints/current"
  mkdir -p "$cur"
  cp "$FIX/$1" "$cur/config.md"
  printf '%s' "$sb"
}
cfg_of() { printf '%s/repo/millwright-inspector/workflow-stream/feat/blueprints/current/config.md' "$1"; }

sb="$(feature_sandbox brief-config.md)"

t="brief implement lists only Skills entries tagged implement, with absolute paths"
got="$(run_in "$sb" "$S" brief feat implement)"
exp="$(printf '## Skills for this work (from config.md)\n\nLoad each skill with the `Skill` tool (`Skill <name>`); if that fails, Read the file at its path.\n\n- vercel:nextjs — App Router pages — /opt/plugins/vercel/skills/nextjs/SKILL.md\n- web-images — image pipeline — %s/repo/.claude/skills/web-images/SKILL.md' "$sb")"
if [[ "$got" == "$exp" ]]; then ok "$t"; else ng "$t" "got [$got]"; fi

t="brief review uses the review heading and the review-tagged entries"
got="$(run_in "$sb" "$S" brief feat review)"
exp="$(printf '## Skills for reviewing this work\n\nLoad each skill with the `Skill` tool (`Skill <name>`); if that fails, Read the file at its path.\n\n- vercel:nextjs — App Router pages — /opt/plugins/vercel/skills/nextjs/SKILL.md\n- a11y-review — accessibility checks — %s/repo/.claude/skills/a11y-review/SKILL.md' "$sb")"
if [[ "$got" == "$exp" ]]; then ok "$t"; else ng "$t" "got [$got]"; fi

t="entries matches brief entry for entry (name TAB abs-path)"
for tag in implement review; do
  from_brief="$(run_in "$sb" "$S" brief feat "$tag" | sed -n 's/^- \([^ ]*\) — .* — \(.*\)$/\1\t\2/p')"
  from_entries="$(run_in "$sb" "$S" entries feat "$tag")"
  [[ "$from_brief" == "$from_entries" && -n "$from_entries" ]] || { ng "$t" "$tag: brief=[$from_brief] entries=[$from_entries]"; continue 2; }
done
ok "$t"

t="brief and entries ignore Load on demand and Catalog suggestions"
got="$(run_in "$sb" "$S" entries feat implement | cut -f1 | tr '\n' ' ')"
if [[ "$got" == "vercel:nextjs web-images " ]]; then ok "$t"; else ng "$t" "got [$got]"; fi

t="brief and suggestions tolerate loose entry formatting (hyphen, no spaces, tab indent)"
sb="$(feature_sandbox brief-config.md)"
printf -- '---\nid: 00000000-0000-4000-8000-000000000001\nrequirements-id: 00000000-0000-4000-8000-000000000002\n---\n\n<!-- auto:start -->\n\n## Skills\n\n- web-images - image pipeline\n  stages:implement;skill:web-images;path:.claude/skills/web-images/SKILL.md\n- a11y-review \xe2\x80\x94 accessibility\n\tstages: review ;skill: a11y-review; path: /abs/a11y/SKILL.md\n\n## Load on demand\n\n## Catalog suggestions\n\n- agent-browser - e2e checks\n  stages:review;requested:no;install:catalog add agent-browser\n\n<!-- auto:end -->\n' > "$(cfg_of "$sb")"
impl="$(run_in "$sb" "$S" entries feat implement | cut -f1)"
rev="$(run_in "$sb" "$S" entries feat review | cut -f1)"
sug="$(run_in "$sb" "$S" suggestions feat | cut -f1,2,5)"
if [[ "$impl" == "web-images" && "$rev" == "a11y-review" && "$sug" == "$(printf 'agent-browser\tno\te2e checks')" ]]; then ok "$t"
else ng "$t" "impl=[$impl] rev=[$rev] sug=[$sug]"; fi

t="brief prints nothing for a pre-1.11.0 config (no stages:/skill:)"
sb="$(feature_sandbox old-config.md)"
got="$(run_in "$sb" "$S" brief feat implement)$(run_in "$sb" "$S" entries feat review)"; rc=$?
if [[ $rc -eq 0 && -z "$got" ]]; then ok "$t"; else ng "$t" "got [$got]"; fi

t="brief prints nothing and exits 0 when the feature has no config.md"
got="$(run_in "$sb" "$S" brief no-such-feature review)"; rc=$?
if [[ $rc -eq 0 && -z "$got" ]]; then ok "$t"; else ng "$t" "rc=$rc got [$got]"; fi

t="brief, entries and suggestions exit non-zero when the feature is empty"
bad=""
run_in "$sb" "$S" brief "" implement >/dev/null 2>&1 && bad+=" brief"
run_in "$sb" "$S" entries "" review >/dev/null 2>&1 && bad+=" entries"
run_in "$sb" "$S" suggestions "" >/dev/null 2>&1 && bad+=" suggestions"
if [[ -z "$bad" ]]; then ok "$t"; else ng "$t" "exited 0:$bad"; fi

t="brief rejects an unknown tag"
if run_in "$sb" "$S" brief feat deploy >/dev/null 2>&1; then ng "$t" "accepted 'deploy'"; else ok "$t"; fi

# ---- suggestions ---------------------------------------------------------------
sb="$(feature_sandbox gate-config.md)"

t="suggestions lists every catalog suggestion as TSV"
got="$(run_in "$sb" "$S" suggestions feat | head -2)"
exp="$(printf 'j-one\tjournal\timplement\tcatalog add j-one\tnamed in the journal\no-one\tno\treview\tcatalog add o-one\tuseful for tests')"
if [[ "$got" == "$exp" ]]; then ok "$t"; else ng "$t" "got [$got]"; fi

t="suggestions prints nothing once the gate has emptied the section"
cp "$FIX/gate-after-retry.md" "$(cfg_of "$sb")"
got="$(run_in "$sb" "$S" suggestions feat)"; rc=$?
if [[ $rc -eq 0 && -z "$got" ]]; then ok "$t"; else ng "$t" "rc=$rc got [$got]"; fi

t="suggestions prints nothing for a pre-1.11.0 config or a missing feature"
sb="$(feature_sandbox old-config.md)"
got="$(run_in "$sb" "$S" suggestions feat)$(run_in "$sb" "$S" suggestions nope)"; rc=$?
if [[ $rc -eq 0 && -z "$got" ]]; then ok "$t"; else ng "$t" "got [$got]"; fi

# ---- catalog-files -------------------------------------------------------------
t="catalog-files lists new/changed skill files and the lock file only"
sb="$(make_sandbox)"
write_skill "$sb/repo/.claude/skills/old" "already committed"
printf '{"version": 1, "items": {"old": {"kind": "skill", "files": [".claude/skills/old"]}}}\n' \
  > "$sb/repo/.claude/catalog.lock.json"
(cd "$sb/repo" && git add .claude && git commit -qm "seed skills")
write_skill "$sb/repo/.claude/skills/web-images" "new"
mkdir -p "$sb/repo/.claude/skills/web-images/refs" && echo ref > "$sb/repo/.claude/skills/web-images/refs/a.md"
printf '{"version": 1, "items": {"old": {"kind": "skill", "files": [".claude/skills/old"]}, "web-images": {"kind": "skill", "files": [".claude/skills/web-images"]}}}\n' \
  > "$sb/repo/.claude/catalog.lock.json"
echo unrelated > "$sb/repo/.claude/notes.md"
echo staged > "$sb/repo/other.txt" && (cd "$sb/repo" && git add other.txt)
got="$(run_in "$sb" "$S" catalog-files)"
exp="$(printf '.claude/catalog.lock.json\n.claude/skills/web-images/SKILL.md\n.claude/skills/web-images/refs/a.md')"
if [[ "$got" == "$exp" ]]; then ok "$t"; else ng "$t" "got [$got]"; fi

t="catalog-files prints nothing without a lock file"
sb="$(make_sandbox)"
got="$(run_in "$sb" "$S" catalog-files)"; rc=$?
if [[ $rc -eq 0 && -z "$got" ]]; then ok "$t"; else ng "$t" "rc=$rc got [$got]"; fi

# ---- apply-installs round trip (Approve Step 1.5 rewrite rules) -----------------
sb="$(feature_sandbox gate-config.md)"
cfg="$(cfg_of "$sb")"

t="apply-installs: install, decline, failed optional, failed journal + stop"
run_in "$sb" "$S" apply-installs feat --installed j-one,o-one --declined o-two --failed o-three,j-two --stop
if diff -u "$FIX/gate-after-stop.md" "$cfg" >"$sb/d1"; then ok "$t"; else ng "$t" "$(head -20 "$sb/d1")"; fi

t="apply-installs: the retry installs the kept journal entry and empties suggestions"
run_in "$sb" "$S" apply-installs feat --installed j-two
if diff -u "$FIX/gate-after-retry.md" "$cfg" >"$sb/d2"; then ok "$t"; else ng "$t" "$(head -20 "$sb/d2")"; fi

t="apply-installs: a repeat run with the same arguments is a no-op"
run_in "$sb" "$S" apply-installs feat --installed j-two
if diff -q "$FIX/gate-after-retry.md" "$cfg" >/dev/null; then ok "$t"; else ng "$t" "file changed on repeat"; fi

t="apply-installs: a failed journal install without --stop is deleted"
sb="$(feature_sandbox gate-config.md)"
cfg="$(cfg_of "$sb")"
run_in "$sb" "$S" apply-installs feat --installed j-one,o-one --declined o-two,o-three --failed j-two
if ! grep -q 'j-two' "$cfg" && ! awk '/^## Catalog suggestions/{f=1;next} /^<!-- auto:end/{f=0} f && /^- /' "$cfg" | grep -q .; then ok "$t"
else ng "$t" "$(sed -n '/auto:start/,/auto:end/p' "$cfg")"; fi

t="apply-installs: text outside the auto block is untouched"
before="$(sed -n '/<!-- auto:end -->/,$p' "$FIX/gate-config.md")"
after="$(sed -n '/<!-- auto:end -->/,$p' "$cfg")"
if [[ "$before" == "$after" ]]; then ok "$t"; else ng "$t" "tail differs"; fi

t="apply-installs: refuses a config without auto markers"
sb="$(feature_sandbox gate-config.md)"
cfg="$(cfg_of "$sb")"
grep -v 'auto:' "$FIX/gate-config.md" > "$cfg"
if run_in "$sb" "$S" apply-installs feat --installed j-one >/dev/null 2>&1; then ng "$t" "accepted"; else ok "$t"; fi

t="apply-installs: a list flag never swallows --stop (failed journal entry is kept)"
sb="$(feature_sandbox gate-config.md)"
cfg="$(cfg_of "$sb")"
run_in "$sb" "$S" apply-installs feat --installed j-one --failed j-two --declined --stop
if awk '/^## Catalog suggestions/{f=1;next} /^<!-- auto:end/{f=0} f' "$cfg" | grep -q 'j-two'; then ok "$t"
else ng "$t" "$(sed -n '/auto:start/,/auto:end/p' "$cfg")"; fi

t="apply-installs: a stray positional argument fails cleanly and leaves config.md unchanged"
sb="$(feature_sandbox gate-config.md)"
cfg="$(cfg_of "$sb")"
cp "$cfg" "$sb/before-stray"
out="$(run_in "$sb" "$S" apply-installs feat j-one 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$out" != *Traceback* ]] && diff -q "$sb/before-stray" "$cfg" >/dev/null; then ok "$t"
else ng "$t" "rc=$rc out=[$out]"; fi

# ---- summary -------------------------------------------------------------------
echo
echo "skills: $pass passed, $fail failed"
if (( fail > 0 )); then
  printf '  failed: %s\n' "${fail_names[@]}" >&2
  exit 1
fi
