#!/usr/bin/env bash
# run.sh — end-to-end smoke test (1.13.0, Windows support).
#
# Runs the sequence every cycle starts with, against a throwaway git repo:
# /mi-init's scaffolding fence → quest.sh start → progress.sh init →
# progress.sh activate → progress.sh set → frontmatter.sh get. Then checks
# the value round-trips and that no file the plugin wrote holds a CR byte.
# On Windows this is what WIN-02 (CRLF frontmatter reads back as null) and
# WIN-03 (the worktree guard compares C:/… with /c/…) broke.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

pass=0
fail=0
fail_names=()

ok() { printf "\xe2\x9c\x93 %s\n" "$1"; pass=$((pass + 1)); }
ng() { printf "\xe2\x9c\x97 %s\n   %s\n" "$1" "$2" >&2; fail=$((fail + 1)); fail_names+=("$1"); }

sb="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$sb"' EXIT
(cd "$sb" && git init -q && git config user.email t@t && git config user.name t \
   && echo seed > README.md && git add README.md && git commit -qm seed)

# Every step runs from the sandbox, with the data root at its default.
run() { (cd "$sb" && env -u MI_DATA_ROOT -u CLAUDE_PLUGIN_USER_CONFIG_data_root CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$@"); }
dr="$sb/millwright-inspector"

t="/mi-init scaffolding fence runs"
fence="$(awk '/^### Step 5 — Scaffold/{f=1} f&&/^```bash$/{c=1;next} c&&/^```$/{exit} c' "$REPO_ROOT/commands/mi-init.md")"
if [[ -n "$fence" ]] && run bash -c "$fence" >/dev/null 2>&1 \
   && [[ -d "$dr/quest" && -f "$dr/quest/active.md" && -f "$dr/.gitattributes" ]]; then
  ok "$t"
else
  ng "$t" "scaffolding fence failed or left no quest/active.md / .gitattributes"
fi

t="cycle starts, activates and takes a set"
mkdir -p "$dr/journal/smoke"
slug="2026-01-01-smoke"
if run "$REPO_ROOT/scripts/quest.sh" start "$slug" smoke >/dev/null 2>&1 \
   && run "$REPO_ROOT/scripts/progress.sh" init "$(run "$REPO_ROOT/scripts/uuid.sh")" smoke-feature >/dev/null 2>&1 \
   && run "$REPO_ROOT/scripts/progress.sh" activate >/dev/null 2>&1 \
   && run "$REPO_ROOT/scripts/progress.sh" set "sub-flow=resuming" >/dev/null 2>&1; then
  ok "$t"
else
  ng "$t" "quest.sh start / progress.sh init / activate / set failed"
fi

t="frontmatter.sh get round-trips the value"
got="$(run "$REPO_ROOT/scripts/frontmatter.sh" get "$dr/quest/$slug/progress.md" .active.sub-flow 2>/dev/null)"
active="$(run "$REPO_ROOT/scripts/progress.sh" get-active 2>/dev/null)"
if [[ "$got" == "resuming" && "$active" == "smoke-feature" ]]; then
  ok "$t"
else
  ng "$t" "sub-flow='$got' (want resuming), active='$active' (want smoke-feature)"
fi

t="no file under the data root holds a CR byte"
cr_files="$(grep -rl $'\r' "$dr" 2>/dev/null || true)"
if [[ -z "$cr_files" ]]; then
  ok "$t"
else
  ng "$t" "CR found in: $cr_files"
fi

# Simulated Windows with no cygpath on PATH (IR-001..003): sourcing common.sh
# must not abort, and MI_BASH falls back to $BASH. Skipped on real Windows,
# where Git Bash always ships cygpath and `ln -s` copies instead of linking.
t="common.sh sources on simulated Windows without cygpath"
case "${OSTYPE:-}" in
  msys*|cygwin*) ok "$t (skipped on Windows)" ;;
  *)
    fb="$sb/fakebin"; mkdir -p "$fb"
    for c in dirname tr sed cat; do ln -s "$(command -v "$c")" "$fb/$c"; done
    printf '#!/bin/sh\nexit 0\n' > "$fb/python3"; chmod +x "$fb/python3"
    got="$(env -u MI_PY_CMD -u MI_BASH PATH="$fb" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$BASH" -c \
      'OSTYPE=msys; source "$1/scripts/internal/common.sh"; printf "%s|%s|%s\n" "$MI_IS_WINDOWS" "$MI_PY_CMD" "$MI_BASH"' \
      _ "$REPO_ROOT" 2>&1)"
    if [[ "$got" == "1|python3|$BASH" ]]; then
      ok "$t"
    else
      ng "$t" "got '$got' (want '1|python3|$BASH')"
    fi
    ;;
esac

printf "\n%d passed, %d failed\n" "$pass" "$fail"
if (( fail > 0 )); then
  printf "Failed: %s\n" "${fail_names[*]}" >&2
  exit 1
fi
exit 0
