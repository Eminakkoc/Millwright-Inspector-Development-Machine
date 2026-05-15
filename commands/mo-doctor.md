---
description: Check all millwright-overseer-development-machine dependencies (CLI tools, Python modules, skills, MCP server). Report status and offer to install anything missing after overseer approval.
---

# mo-doctor

**Run this first, before any other `/mo-*` command.** Verifies that every dependency the workflow needs is present on the overseer's machine. If something is missing, the millwright proposes install commands and runs them only after explicit approval.

## Execution

### Step 1 — Run the detection script

```bash
$CLAUDE_PLUGIN_ROOT/scripts/doctor.sh --format=json
```

Capture the JSON output and parse it. The JSON has this shape:

```json
{
  "os": "darwin" | "linux-apt" | "linux-pacman" | "linux-dnf" | "linux-apk" | "linux-generic" | "windows" | "unknown",
  "status": "ok" | "warn" | "error",
  "summary": "...",
  "checks": [
    {
      "name": "yq",
      "kind": "cli" | "pymod" | "plugin" | "env",
      "required": true,
      "present": false,
      "version": "",
      "install_hints": {
        "darwin": "brew install yq",
        "linux-apt": "...",
        "any": "..."
      },
      "severity": "ok" | "warn" | "error"
    },
    ...
  ]
}
```

### Step 2 — Present the report

Print a human-friendly summary to the overseer. Group by severity:

- **✓ present** — already installed (one short line each, collapsed).
- **✗ required, missing** — must be installed before the workflow runs.
- **⚠ optional, missing** — recommended but not blocking.

Example output:

```
millwright-overseer-development-machine dependency report (os=darwin)

Required — present:
  ✓ git (2.50.1)
  ✓ python3 (3.11.5)
  ✓ plantuml-mcp-server
  ✓ git-repo (on branch feat/payments)

Required — MISSING:
  ✗ yq
  ✗ pyyaml

Optional — missing:
  ⚠ ajv-cli (falls back to python jsonschema)
  ⚠ python-jsonschema (falls back to yq structural check)
  ⚠ gh (GitHub CLI — required only for /mo-analyze-review PR-review analysis)

Skills (optional — at least one source required):
  ✓ brainstorming (local: .claude/skills/brainstorming)
  ✓ writing-plans (local: .claude/skills/writing-plans)
  ✓ executing-plans (local: .claude/skills/executing-plans)
  ✓ subagent-driven-development (local: .claude/skills/subagent-driven-development)
  ✓ finishing-a-development-branch (local: .claude/skills/finishing-a-development-branch)

Manual-testing feature (stage-5 sub-flow):
  ✓ templates/manual-test-plan.md.tmpl
  ✓ templates/manual-test-results.md.tmpl
  ✓ schemas/manual-test-plan.schema.yaml
  ✓ schemas/manual-test-results.schema.yaml
  ✓ schema:sub-flow=manual-testing
  ✓ schema:manual-test-state
  ✓ schema:manual-test-failure-policy
  ✓ review.sh:upsert-manual-test-failure
  ✓ review.sh:find-by-seed-id
  ✓ review.sh:find-by-seed-id-family
  ✓ review.sh:FIELD_RE (extended with source/seed-id)
  ✓ blueprints.sh:manual-test-plan-path
  ✓ blueprints.sh:manual-test-results-path
  ✓ blueprints.sh:manual-test-plan-rotate
```

The "Manual-testing feature" group records the artifacts and script subcommands that `/mo-manual-test-plan` and `/mo-manual-test-run` depend on (per `docs/manual-testing/plan.md` § 3.8). Detection is in `scripts/doctor.sh`; this command does not duplicate the logic — it only renders the JSON `record` output. Missing items here surface as clear named checks instead of cryptic runtime errors at first invocation. The highest-risk silent-failure is `review.sh:FIELD_RE` — without the `source`/`seed-id` extension, `canonicalize` would corrupt auto-seeded blocks (the new fields would look like freeform paragraphs and break IR_HEAD_RE boundaries).

### Step 3 — If `status == "ok"` — done

> "All required dependencies present. You can run `/mo-run <folder1> [<folder2> ...]` to start the workflow."

Exit.

### Step 4 — If required deps are missing — propose installs

For each check where `present == false` and `required == true`, split by `kind`:

- **`kind ∈ {cli, pymod}`** — shell-installable. The millwright can run these via `Bash` after approval.
- **`kind == "plugin"`** — Claude Code plugin or skill (e.g., superpowers brainstorming/writing-plans). **Cannot be installed from Bash** — Claude Code's `/plugin` commands only run inside a session. The millwright renders the hint verbatim and asks the overseer to run the slash commands themselves.
- **`kind == "env"`** — environmental (e.g., git-repo not initialized). Handle case by case; usually a one-line instruction.

For each selected dep, look up `install_hints[os]` (falling back to `install_hints["any"]`). If neither exists, flag the dep as "manual install — no automated hint available".

Present the proposed commands to the overseer, **grouped into a Bash block and a slash-command block** so the overseer knows which ones the millwright will run vs. which they must run themselves:

```
Proposed install commands (os=darwin):

Bash-runnable (with your approval):

  # yq (required):
  brew install yq

  # pyyaml (required):
  python3 -m pip install --user pyyaml

Slash commands — please run these yourself in this Claude Code session:

  # brainstorming, writing-plans, executing-plans, subagent-driven-development,
  # finishing-a-development-branch (all required; ship together with the superpowers plugin):
  /plugin marketplace add <superpowers-source>
  /plugin install superpowers@<marketplace>

  # (Alternative per-skill: drop a SKILL.md into .claude/skills/<name>/.)

Shall I run the Bash block now? (y / n / select)
  y       — run all Bash commands
  n       — skip; you'll install manually
  select  — pick which Bash commands to run interactively
```

If there are **only** plugin-kind missing deps and nothing Bash-runnable, skip the `(y/n/select)` prompt — there's nothing for the millwright to execute. Just display the slash-command block and ask the overseer to run them, then re-run `/mo-doctor`.

### Step 5 — Run approved installs

Based on the overseer's response to the Bash-block prompt:

- **`y`** — run each Bash install command in order. After each, report success/failure and continue.
- **`n`** — report the commands and exit.
- **`select`** — iterate through Bash-runnable missing deps; for each one ask "install <name>? (y/n)" and run only if yes.

When running commands that use `sudo`, surface this explicitly to the overseer and get a second confirmation:

> "This command requires sudo: `sudo apt install yq`. Proceed? (y/n)"

After all approved Bash installs complete, re-run doctor to confirm:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/doctor.sh --format=json
```

Then evaluate the result:

- **`status == "ok"`** — tell the overseer:

  > "All required dependencies now present. You can run `/mo-run <folder1> [<folder2> ...]` to start the workflow."

- **`status == "error"` with only plugin-kind deps missing** — the overseer still needs to run the slash commands. Remind them:

  > "Bash installs complete. Still missing plugin-kind deps — please run the slash commands above in this session, then re-run /mo-doctor."

- **`status == "error"` with other kinds still missing** — list what's still missing and let the overseer decide next steps.

### Step 6 — Offer to install optional deps

If required deps are satisfied but optional deps are missing, offer them as a secondary prompt:

> "All required deps present. Some optional deps are missing:
>
> ⚠ ajv-cli — enables deep JSON Schema validation (falls back to python jsonschema / yq)
> ⚠ python-jsonschema — secondary validation fallback
>
> Install these too? (y/n)"

Only install if the overseer explicitly approves.

## Safety

- **Never install packages without overseer approval.** Every command is shown and confirmed before execution.
- **Never run destructive commands** (`rm`, `reset`, etc.) — doctor only installs.
- **Do not modify shell profiles** (`.bashrc`, `.zshrc`) automatically. If an install hint adds to PATH, prompt the overseer to source the file themselves.
- **Respect CI environments.** If `CI=true` or `GITHUB_ACTIONS=true` in the environment, skip the interactive prompts and just report status — do not attempt installs.

## Notes

- The doctor script is safe to run repeatedly. It has no side effects; only the install commands you approve mutate the system.
- If a dep detection is wrong (e.g., the binary is installed under a different name or in a non-standard location), flag it to the overseer rather than forcing an install. The overseer can set aliases / PATH and re-run `/mo-doctor` to verify.
