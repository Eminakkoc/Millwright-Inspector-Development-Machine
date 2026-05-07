---
description: Wire the mo-workflow status line. Writes a wrapper script with the plugin's absolute path and points statusLine at it. Default target is .claude/settings.local.json (machine-local, not committed). Idempotent. Flags --user, --project-shared, --plugin-root.
---

# mo-init-status-bar

Wires the mo-workflow status line into the overseer's Claude Code settings. After this command runs, the bottom bar in Claude Code will show the current workflow stage on the next interaction (no session restart needed).

**Why a separate command.** Claude Code's `statusLine` is a per-machine setting, not something a plugin manifest can ship. Worse, the docs confirm `$CLAUDE_PLUGIN_ROOT` is **not** expanded inside `statusLine.command` — so we cannot just write `"$CLAUDE_PLUGIN_ROOT/scripts/info-bar.sh"` and call it done. This command resolves the plugin's absolute path at install time, writes a small wrapper that exec's the renderer, and points `settings.json` at that wrapper. Idempotent — safe to run any time on any machine.

The default target is `.claude/settings.local.json` (project-scoped, machine-local, not committed). Flags retarget elsewhere; see [Flags](#flags) below.

## Execution

### Step 1 — Parse flags

Accept the following arguments. If conflicting flags are passed (e.g. `--user --project-shared`), error out before doing anything.

- (no flag) — write to `<project_dir>/.claude/mo-stage-info-bar.sh` and `<project_dir>/.claude/settings.local.json`.
- `--user` — write to `~/.claude/mo-stage-info-bar.sh` and `~/.claude/settings.json`.
- `--project-shared` — write to `<project_dir>/.claude/mo-stage-info-bar.sh` and `<project_dir>/.claude/settings.json` (the **committed** project settings file). Warns about the machine-specific wrapper path; requires explicit confirmation.
- `--plugin-root <abs>` — manual override for plugin-root resolution (escape hatch for unusual installs).

Set `wrapper_dir`, `settings_file`, and `mode` (`local` | `user` | `shared`) based on the flag.

### Step 2 — Resolve the absolute plugin root

Capture the plugin's filesystem path at install time. Try in order:

1. **`$CLAUDE_PLUGIN_ROOT`** — set by Claude Code while a slash command is running. This is the high-confidence path; the docs' "no expansion in `statusLine.command`" limitation applies only to status-line invocation, not to slash commands.
2. **`--plugin-root <abs>`** — if the overseer passed this flag, use it verbatim (after verifying `<abs>/scripts/info-bar.sh` exists).
3. **Fallback scan of `~/.claude/plugins/`**:

   ```bash
   plugin_root="$(python3 -S -I - <<'PYEOF'
   import glob, json, os
   root = os.path.expanduser("~/.claude/plugins")
   best = None  # (mtime, plugin_root)
   for p in glob.iglob(os.path.join(root, "**", ".claude-plugin", "plugin.json"), recursive=True):
       try:
           if json.load(open(p)).get("name") != "millwright-overseer-development-machine":
               continue
           pr = os.path.dirname(os.path.dirname(p))
           if not os.access(os.path.join(pr, "scripts", "info-bar.sh"), os.X_OK):
               continue
           m = os.path.getmtime(p)
           if best is None or m > best[0]:
               best = (m, pr)
       except Exception:
           continue
   if best:
       print(best[1])
   PYEOF
   )"
   ```

If all three fail, print:

```
✗ Cannot resolve the plugin's absolute path.
  Re-run /mo-init-status-bar from a Claude Code session with the plugin loaded,
  or pass --plugin-root <abs-path-to-plugin-root>.
```

…and exit. Do not write anything.

Verify `${plugin_root}/scripts/info-bar.sh` exists and is executable; if not, error out the same way.

### Step 3 — Pick wrapper and settings paths

Resolve `project_dir` from the current working directory (the same project root `/mo-init` operates against). The exact paths depend on the mode chosen in Step 1:

| mode    | wrapper                                    | settings file                        |
| ------- | ------------------------------------------ | ------------------------------------ |
| local   | `<project_dir>/.claude/mo-stage-info-bar.sh` | `<project_dir>/.claude/settings.local.json` |
| user    | `~/.claude/mo-stage-info-bar.sh`           | `~/.claude/settings.json`            |
| shared  | `<project_dir>/.claude/mo-stage-info-bar.sh` | `<project_dir>/.claude/settings.json`       |

Create the parent directory (`mkdir -p`) if missing.

For `mode=shared`, **before doing anything**, print this warning and require an explicit `y`:

```
⚠ --project-shared writes to .claude/settings.json (committed) and bakes a
  machine-specific absolute path into the wrapper script:

    plugin_root="$plugin_root"

  Collaborators who clone this repo will get a broken status line unless
  every machine has the plugin at the same path, or each member runs
  /mo-init-status-bar themselves.

  Continue? (y/N)
```

If the answer is anything other than `y`/`Y`, exit without writing.

### Step 4 — Write the wrapper script

Render this template, with `<plugin_root>` replaced by the absolute path resolved in Step 2:

```bash
#!/usr/bin/env bash
# mo-stage-info-bar.sh — generated by /mo-init-status-bar.
# DO NOT edit by hand; rerun /mo-init-status-bar to regenerate.
#
# Wraps the mo-workflow status-line renderer with an absolute plugin
# path (Claude Code does not expand $CLAUDE_PLUGIN_ROOT in
# statusLine.command). If the captured plugin path no longer exists
# (marketplace upgrade moved the plugin), the wrapper falls back to
# scanning ~/.claude/plugins/ for the most recently modified install.
# Silent on miss — Claude Code prints the script's output verbatim, so
# leaking a diagnostic into the status line is worse than printing
# nothing.

set -euo pipefail

plugin_root="<plugin_root>"

# Fast path: captured root still valid.
if [[ -x "$plugin_root/scripts/info-bar.sh" ]]; then
  exec "$plugin_root/scripts/info-bar.sh"
fi

# Fallback: scan user-cache plugin tree for a current install.
resolved="$(python3 -S -I - "$HOME/.claude/plugins" <<'PY' 2>/dev/null || true
import glob, json, os, sys
root = sys.argv[1]
best = None
for p in glob.iglob(os.path.join(root, "**", ".claude-plugin", "plugin.json"), recursive=True):
    try:
        if json.load(open(p)).get("name") != "millwright-overseer-development-machine":
            continue
        pr = os.path.dirname(os.path.dirname(p))
        if not os.access(os.path.join(pr, "scripts", "info-bar.sh"), os.X_OK):
            continue
        m = os.path.getmtime(p)
        if best is None or m > best[0]:
            best = (m, pr)
    except Exception:
        continue
if best:
    print(best[1])
PY
)"

if [[ -n "$resolved" && -x "$resolved/scripts/info-bar.sh" ]]; then
  exec "$resolved/scripts/info-bar.sh"
fi

# Plugin missing — silently render empty.
echo ""
exit 0
```

Atomic write:

```bash
tmp="$(mktemp "${wrapper_dir}/.mo-stage-info-bar.XXXXXX")"
# ...write rendered template to $tmp...
chmod 0755 "$tmp"
mv "$tmp" "${wrapper_dir}/mo-stage-info-bar.sh"
```

### Step 5 — Update the settings file

Read the chosen `settings_file` (treat as `{}` if absent). Inspect the existing `statusLine` field:

- **`statusLine.command` already equals our wrapper's absolute path** → print `✓ status line already wired` and skip the write.
- **`statusLine` exists but points elsewhere** → show the existing value and ask:

  ```
  An existing statusLine is configured:

    type:    <existing.type>
    command: <existing.command>

  (o)verwrite with mo-workflow status line
  (k)eep existing (skip wiring)
  (p)rint snippet to wire manually

  Choice [k]:
  ```

  - `o` → overwrite.
  - `k` → exit without writing.
  - `p` → print the JSON snippet for manual merging:

    ```json
    {
      "statusLine": {
        "type": "command",
        "command": "<absolute path to wrapper>"
      }
    }
    ```

    …and exit.
- **`statusLine` is absent** → write the block.

When writing, use a single `python3` invocation so the rest of `settings.json` is preserved untouched:

```bash
python3 -S -I - "$settings_file" "$wrapper_path" <<'PYEOF'
import json, os, sys, tempfile
settings_file, wrapper_path = sys.argv[1], sys.argv[2]
try:
    with open(settings_file) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
except json.JSONDecodeError as e:
    sys.stderr.write(f"settings file is not valid JSON: {e}\n")
    sys.exit(1)
if not isinstance(data, dict):
    sys.stderr.write("settings file root is not a JSON object\n")
    sys.exit(1)
data["statusLine"] = {"type": "command", "command": wrapper_path}
parent = os.path.dirname(os.path.abspath(settings_file))
fd, tmp = tempfile.mkstemp(prefix=".mo-settings.", dir=parent)
try:
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, settings_file)
except Exception:
    os.unlink(tmp)
    raise
PYEOF
```

If the settings file is malformed JSON, do **not** try to repair it. Print the parse error and ask the overseer to fix it manually:

```
✗ <settings_file> is not valid JSON: <error>
  Fix the file (or delete it to start fresh) and rerun /mo-init-status-bar.
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
| (none)               | `<project>/.claude/mo-stage-info-bar.sh`     | `<project>/.claude/settings.local.json` | Machine-local. Default. Not committed.               |
| `--user`             | `~/.claude/mo-stage-info-bar.sh`             | `~/.claude/settings.json`               | Per-user. Applies to every project on this machine.  |
| `--project-shared`   | `<project>/.claude/mo-stage-info-bar.sh`     | `<project>/.claude/settings.json`       | Committed. Warns about machine-specific wrapper path. |
| `--plugin-root <abs>` | (orthogonal) overrides plugin-root resolution. | (orthogonal)                            | Escape hatch for installs outside `~/.claude/plugins/`. |

## Notes

- Idempotent — safe to run any time. Detects "already wired" and "points elsewhere" cases without clobbering.
- Re-run after a marketplace plugin upgrade if the wrapper's fallback scan can't find the new install (e.g. the plugin moved outside `~/.claude/plugins/`). The fast path uses the path captured at the most recent run.
- Outside an mo-workspace, the wrapper still produces empty output (the renderer's data-root probe handles this), so wiring `--user` is safe even on machines where some projects don't use this plugin.
