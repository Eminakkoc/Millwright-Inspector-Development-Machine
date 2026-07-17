---
description: Manually add, cancel, or change state on items in the active quest cycle's todo-list.md (lives under quest/<active-slug>/). Thin wrapper around todo.sh with state-machine safety.
argument-hint: "add <feature> <state> <assignee> <item-id> <description> | cancel <item-id> | set-state <item-id> <state>"
---

# mi-update-todo-list

**Runtime bootstrap.** Every `$CLAUDE_PLUGIN_ROOT` reference in this command's Bash blocks assumes a resolved plugin root; Claude Code does not inject the env var into Bash subshells. If it is empty in your shell, apply the canonical resolver (`docs/millwright-inspector-project.md` §8.14; reference implementation: `mi-continue.md` Step 1a) before the first Bash block: (1) inherited env var when it points at a working install, (2) `$PWD` when it is this plugin's source repo, (3) the `installPath` from `~/.claude/plugins/installed_plugins.json` — then export it, persist it to the per-cwd tempfile, and prepend the recovery one-liner to every subsequent Bash block. Refuse with an environmental diagnostic if none resolve.

Inspector-triggered edits to the active quest cycle's `todo-list.md` (lives under `quest/<active-slug>/`; resolve the path via `scripts/quest.sh dir`). Thin dispatcher over `todo.sh` that enforces the state machine and refuses states that must only be written by automated stages (`PENDING` by stage-1.5's `pend-selected`; `IMPLEMENTED` by `mi-complete-workflow`).

Independent of `/mi-update-blueprint` — this command does **not** rotate or regenerate blueprints, does **not** alter `progress.md`, and is safe to invoke at any time.

## Invocation

```
/mi-update-todo-list add <feature> <state> <assignee> <item-id> <description>
/mi-update-todo-list cancel <item-id>
/mi-update-todo-list set-state <item-id> <state>
```

Valid `<state>` values:

- **`TODO`** — queues the item for a future cycle (won't be picked up until the next `mi-run` → `mi-apply-impact` with that feature).
- **`IMPLEMENTING`** — pulls the item into the currently-active cycle; stage 8 will flip it to `IMPLEMENTED` alongside the other in-flight items.
- **`CANCELED`** — removes the item from scope; stage 8 leaves it as-is (no transition to `IMPLEMENTED`).

Refused states for manual writes:

- **`PENDING`** — only stage-1.5's `pend-selected` writes this; manual PENDING breaks the state-transition audit trail.
- **`IMPLEMENTED`** — only `mi-complete-workflow` writes this on clean stage-8 exit; manual IMPLEMENTED breaks the commits-linkage invariant.

## Execution

Parse `$ARGUMENTS` to extract the subcommand and its args, then dispatch to `todo.sh`. Relay any non-zero exit and its stderr to the inspector verbatim.

### `add <feature> <state> <assignee> <item-id> <description>`

```bash
$CLAUDE_PLUGIN_ROOT/scripts/todo.sh add "<feature>" "<state>" "<assignee>" "<item-id>" "<description>"
```

`todo.sh add` refuses `PENDING` / `IMPLEMENTED` and enforces item-id uniqueness. If the feature's `## <feature>` section doesn't exist yet, it's created at the end of the file.

### `cancel <item-id>`

```bash
$CLAUDE_PLUGIN_ROOT/scripts/todo.sh set-state "<item-id>" CANCELED
```

Convenience alias for `set-state <id> CANCELED`. Does not rotate the blueprint — if the cancellation represents a scope change that should also update `requirements.md`, follow up with `/mi-update-blueprint <reason>`.

### `set-state <item-id> <state>`

```bash
$CLAUDE_PLUGIN_ROOT/scripts/todo.sh set-state "<item-id>" "<state>"
```

Before dispatching, validate `<state>` against the refused-states list above:

- If `<state>` is `PENDING`, respond: *"Refused: PENDING is only written by stage-1.5's pend-selected. If you're adding a new item to the current cycle, use `add <feature> IMPLEMENTING <assignee> <item-id> <description>` instead."*
- If `<state>` is `IMPLEMENTED`, respond: *"Refused: IMPLEMENTED is only written by mi-complete-workflow on clean stage-8 exit. Manual IMPLEMENTED breaks the commits-linkage invariant."*
- Otherwise proceed with the `todo.sh set-state` call.

## Report

After a successful dispatch, confirm the change to the inspector with the script's stderr line (e.g., `"added PAY-003 as [IMPLEMENTING] under ## payments"`) plus a reminder when scope changed:

> "Item `<id>` now `<state>`. Reminder: this does not touch `blueprints/current/` — if this change should be reflected in `requirements.md` / `config.md` / diagrams, run `/mi-update-blueprint <reason>`."

Omit the reminder for `TODO` additions (which belong to future cycles, not the active blueprint).

## Notes

- Subcommands never cascade. The command edits only the active cycle's `todo-list.md`.
- The frontmatter validation hook (`hooks/validate-on-write.sh`) re-validates `todo-list.md`'s frontmatter on every write; malformed edits are rejected automatically.
- For rename / description-rewording, edit the file manually — the state machine doesn't care about the description text, only the state word and assignee tag.
