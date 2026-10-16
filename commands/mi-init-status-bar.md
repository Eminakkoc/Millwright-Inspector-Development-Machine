---
description: Wire the mi-workflow status line. Writes a wrapper script with the plugin's absolute path and points statusLine at it. Default target is .claude/settings.local.json (machine-local, not committed). Idempotent. Flags --user, --project-shared, --plugin-root.
---

# mi-init-status-bar

**Runtime bootstrap.** Every `$CLAUDE_PLUGIN_ROOT` reference in this command's Bash blocks assumes a resolved plugin root; Claude Code does not inject the env var into Bash subshells. If it is empty in your shell, apply the canonical resolver (`docs/millwright-inspector-project.md` §8.14; reference implementation: `mi-continue.md` Step 1a) before the first Bash block: (1) inherited env var when it points at a working install, (2) `$PWD` when it is this plugin's source repo, (3) the `installPath` from `~/.claude/plugins/installed_plugins.json` — then export it, persist it to the per-cwd tempfile, and prepend the recovery one-liner to every subsequent Bash block. Refuse with an environmental diagnostic if none resolve.

**Running blocks.** Run each fenced `bash` block with the Bash tool (never the PowerShell tool), as written, in one call. Don't wrap a block in `bash -c`, `sh -c`, `zsh -c` or `eval`: Claude Code can't check a wrapped script, so it may stop for permission, and an unattended session denies it. The blocks run the same in bash and zsh; if one fails on shell syntax, stop and report it as a plugin bug instead of working around it.

Wires the mi-workflow status line into the inspector's Claude Code settings. After this command runs, the bottom bar in Claude Code will show the current workflow stage on the next interaction (no session restart needed).

**Why a separate command.** Claude Code's `statusLine` is a per-machine setting, not something a plugin manifest can ship. Worse, the docs confirm `$CLAUDE_PLUGIN_ROOT` is **not** expanded inside `statusLine.command` — so we cannot just write `"$CLAUDE_PLUGIN_ROOT/scripts/info-bar.sh"` and call it done. This command resolves the plugin's absolute path at install time, writes a small wrapper that exec's the renderer, and points `settings.json` at that wrapper. Idempotent — safe to run any time on any machine.

The default target is `.claude/settings.local.json` (project-scoped, machine-local, not committed). Flags retarget elsewhere; see [Flags](#flags) below.

## Execution

### Step 1 — Parse flags

Accept the following arguments. If conflicting flags are passed (e.g. `--user --project-shared`), error out before doing anything.

- (no flag) — write to `<project_dir>/.claude/mi-stage-info-bar.sh` and `<project_dir>/.claude/settings.local.json`.
- `--user` — write to `~/.claude/mi-stage-info-bar.sh` and `~/.claude/settings.json`.
- `--project-shared` — write to `<project_dir>/.claude/mi-stage-info-bar.sh` and `<project_dir>/.claude/settings.json` (the **committed** project settings file). Warns about the machine-specific wrapper path; requires explicit confirmation.
- `--plugin-root <abs>` — manual override for plugin-root resolution (escape hatch for unusual installs).

Set `wrapper_dir`, `settings_file`, and `mode` (`local` | `user` | `shared`) based on the flag.

### Step 2 — Resolve the absolute plugin root

Capture the plugin's filesystem path at install time. Try in order:

1. **`$CLAUDE_PLUGIN_ROOT`** — set by Claude Code while a slash command is running. This is the high-confidence path; the docs' "no expansion in `statusLine.command`" limitation applies only to status-line invocation, not to slash commands.
2. **`--plugin-root <abs>`** — if the inspector passed this flag, use it verbatim (after verifying `<abs>/scripts/info-bar.sh` exists).
3. **`installPath` from `~/.claude/plugins/installed_plugins.json`** — the same tool-free lookup as `mi-continue.md` Step 1a: the exact v1 key (never the `@millwright-inspector-v2` marketplace), no Python or yq.

   ```bash
   plugin_root="$(sed -n '/"millwright-inspector-development-machine@millwright-inspector"[[:space:]]*:/,/]/s/^[[:space:]]*"installPath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*$/\1/p' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null | head -1 | sed 's/\\\\/\//g')"
   ```

Whichever source answered, normalize the result on Git Bash (Windows spells it `/c/…`, `C:/…` or `C:\…`) before it is baked into the wrapper:

```bash
if [[ -n "$plugin_root" ]] && command -v cygpath >/dev/null 2>&1; then
  plugin_root="$(cygpath -m "$plugin_root")"
fi
```

If all three fail, print:

```
✗ Cannot resolve the plugin's absolute path.
  Re-run /mi-init-status-bar from a Claude Code session with the plugin loaded,
  or pass --plugin-root <abs-path-to-plugin-root>.
```

…and exit. Do not write anything.

Verify `${plugin_root}/scripts/info-bar.sh` exists and is executable; if not, error out the same way.

Then capture the Python the plugin resolves on this machine (`python3`, or on Windows `python` / `py -3`). The status line runs outside any Claude Code session, so the wrapper has to carry it:

```bash
py_cmd="$("$plugin_root/scripts/py.sh" -c 'import os; print(os.environ["MI_PY_CMD"])')"
```

If this fails (no Python 3.8+), stop and point the inspector at `/mi-doctor`.

### Step 3 — Pick wrapper and settings paths

Resolve `project_dir` from the current working directory (the same project root `/mi-init` operates against). The exact paths depend on the mode chosen in Step 1:

| mode    | wrapper                                    | settings file                        |
| ------- | ------------------------------------------ | ------------------------------------ |
| local   | `<project_dir>/.claude/mi-stage-info-bar.sh` | `<project_dir>/.claude/settings.local.json` |
| user    | `~/.claude/mi-stage-info-bar.sh`           | `~/.claude/settings.json`            |
| shared  | `<project_dir>/.claude/mi-stage-info-bar.sh` | `<project_dir>/.claude/settings.json`       |

Create the parent directory (`mkdir -p`) if missing.

For `mode=shared`, **before doing anything**, print this warning and require an explicit `y`:

```
⚠ --project-shared writes to .claude/settings.json (committed) and bakes a
  machine-specific absolute path into the wrapper script:

    plugin_root="$plugin_root"

  Collaborators who clone this repo will get a broken status line unless
  every machine has the plugin at the same path, or each member runs
  /mi-init-status-bar themselves.

  Continue? (y/N)
```

If the answer is anything other than `y`/`Y`, exit without writing.

### Step 4 — Write the wrapper script

Render this template, with `<plugin_root>` replaced by the absolute path resolved in Step 2 and `<py_cmd>` by the Python command captured there:

```bash
#!/usr/bin/env bash
# mi-stage-info-bar.sh — generated by /mi-init-status-bar.
# DO NOT edit by hand; rerun /mi-init-status-bar to regenerate.
#
# Wraps the mi-workflow status-line renderer with an absolute plugin
# path (Claude Code does not expand $CLAUDE_PLUGIN_ROOT in
# statusLine.command). If the captured plugin path no longer exists
# (marketplace upgrade moved the plugin), the wrapper falls back to the
# current install recorded in ~/.claude/plugins/installed_plugins.json.
# Silent on miss — Claude Code prints the script's output verbatim, so
# leaking a diagnostic into the status line is worse than printing
# nothing.

set -euo pipefail

plugin_root="<plugin_root>"

# The Python this machine resolved at install time (python3, python or
# py -3). info-bar.sh runs it; the status line has no session to inherit it from.
export MI_PY_CMD="<py_cmd>"

# Fast path: captured root still valid.
if [[ -x "$plugin_root/scripts/info-bar.sh" ]]; then
  exec "$plugin_root/scripts/info-bar.sh"
fi

# Fallback: the current v1 install (exact key, never the v2 marketplace).
resolved="$(sed -n '/"millwright-inspector-development-machine@millwright-inspector"[[:space:]]*:/,/]/s/^[[:space:]]*"installPath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*$/\1/p' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null | head -1 | sed 's/\\\\/\//g' || true)"

if [[ -n "$resolved" && -x "$resolved/scripts/info-bar.sh" ]]; then
  exec "$resolved/scripts/info-bar.sh"
fi

# Plugin missing — silently render empty.
echo ""
exit 0
```

Atomic write:

```bash
tmp="$(mktemp "${wrapper_dir}/.mi-stage-info-bar.XXXXXX")"
# ...write rendered template to $tmp...
chmod 0755 "$tmp"
mv "$tmp" "${wrapper_dir}/mi-stage-info-bar.sh"
```

### Step 5 — Update the settings file

Read the chosen `settings_file` (treat as `{}` if absent) and inspect its `statusLine` field. The command written since 1.13.0 is `bash "<absolute path to wrapper>"`: Windows cannot start a bare `.sh` path, and a path with spaces needs the quotes. Every earlier install wrote the bare wrapper path. Paths compare the way `mi_path_eq` does — on Windows, `/c/…`, `C:/…` and `C:\…` match, ignoring case.

- **`statusLine.command` is already `bash "<wrapper>"`** → print `✓ status line already wired` and skip the write.
- **`statusLine.command` is the bare wrapper path** (written before 1.13.0) → rewrite it to the `bash "<wrapper>"` form without asking — it is this command's own entry — and print `✓ status line updated to the bash "<wrapper>" form`.
- **`statusLine` exists but points elsewhere** → show the existing value and ask:

  ```
  An existing statusLine is configured:

    type:    <existing.type>
    command: <existing.command>

  (o)verwrite with mi-workflow status line
  (k)eep existing (skip wiring)
  (p)rint snippet to wire manually

  Choice [k]:
  ```

  - `o` → overwrite (re-run the block below with a third argument, `overwrite`).
  - `k` → exit without writing.
  - `p` → print the JSON snippet for manual merging:

    ```json
    {
      "statusLine": {
        "type": "command",
        "command": "bash \"<absolute path to wrapper>\""
      }
    }
    ```

    …and exit.
- **`statusLine` is absent** → write the block.

One `py.sh` call decides and writes, so the rest of `settings.json` is preserved and non-ASCII text in it survives (UTF-8 on every OS). It prints `already-wired`, `updated-bare`, or `wrote`, or — exit 3 — `other` followed by the existing `type` and `command` lines for the prompt above:

```bash
"$CLAUDE_PLUGIN_ROOT/scripts/py.sh" -S -I - "$settings_file" "$wrapper_path" "${settings_mode:-auto}" <<'PYEOF'
import json, os, re, sys, tempfile
settings_file, wrapper_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(settings_file, encoding="utf-8") as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
except json.JSONDecodeError as e:
    sys.stderr.write(f"settings file is not valid JSON: {e}\n")
    sys.exit(1)
if not isinstance(data, dict):
    sys.stderr.write("settings file root is not a JSON object\n")
    sys.exit(1)

def norm(p):
    # mi_path_eq semantics: `/` separators everywhere; on Windows /c/x == C:/x
    # and case is ignored.
    p = p.strip().replace("\\", "/")
    if os.name == "nt":
        m = re.match(r"^/([A-Za-z])(/.*)?$", p)
        if m:
            p = m.group(1) + ":" + (m.group(2) or "/")
        p = p.lower()
    return p

line = data.get("statusLine")
cmd = line.get("command") if isinstance(line, dict) else None
cmd = cmd if isinstance(cmd, str) else None
quoted = re.fullmatch(r'\s*bash\s+"([^"]+)"\s*', cmd or "")
if mode != "overwrite":
    if quoted and norm(quoted.group(1)) == norm(wrapper_path):
        print("already-wired")
        sys.exit(0)
    bare = cmd is not None and norm(cmd) == norm(wrapper_path)
    if line is not None and not bare:
        print("other")
        print("type:    %s" % (line.get("type") if isinstance(line, dict) else line))
        print("command: %s" % cmd)
        sys.exit(3)
    result = "updated-bare" if bare else "wrote"
else:
    result = "wrote"

data["statusLine"] = {"type": "command", "command": 'bash "%s"' % wrapper_path}
parent = os.path.dirname(os.path.abspath(settings_file))
fd, tmp = tempfile.mkstemp(prefix=".mi-settings.", dir=parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, settings_file)
except Exception:
    os.unlink(tmp)
    raise
print(result)
PYEOF
```

If the settings file is malformed JSON, do **not** try to repair it. Print the parse error and ask the inspector to fix it manually:

```
✗ <settings_file> is not valid JSON: <error>
  Fix the file (or delete it to start fresh) and rerun /mi-init-status-bar.
```

### Step 6 — Print the reload-behavior note

```
✓ wrote wrapper       → <abs path to wrapper>
✓ wrote statusLine    → <abs path to settings file>

The bar will appear on your next interaction with Claude Code (no restart
needed). If it doesn't show up after the next message, check that the
wrapper is executable and that the plugin path baked into it still exists.
```

## Flags

| Flag                 | Wrapper destination                          | Settings destination                    | Notes                                                |
| -------------------- | -------------------------------------------- | --------------------------------------- | ---------------------------------------------------- |
| (none)               | `<project>/.claude/mi-stage-info-bar.sh`     | `<project>/.claude/settings.local.json` | Machine-local. Default. Not committed.               |
| `--user`             | `~/.claude/mi-stage-info-bar.sh`             | `~/.claude/settings.json`               | Per-user. Applies to every project on this machine.  |
| `--project-shared`   | `<project>/.claude/mi-stage-info-bar.sh`     | `<project>/.claude/settings.json`       | Committed. Warns about machine-specific wrapper path. |
| `--plugin-root <abs>` | (orthogonal) overrides plugin-root resolution. | (orthogonal)                            | Escape hatch for installs outside `~/.claude/plugins/`. |

## Notes

- Idempotent — safe to run any time. Detects "already wired" and "points elsewhere" cases without clobbering.
- Re-run after a marketplace plugin upgrade if the wrapper's fallback scan can't find the new install (e.g. the plugin moved outside `~/.claude/plugins/`). The fast path uses the path captured at the most recent run.
- Outside an mi-workspace, the wrapper still produces empty output (the renderer's data-root probe handles this), so wiring `--user` is safe even on machines where some projects don't use this plugin.
