# Changelog

## 1.0.0 — Rename: "overseer" → "inspector"

**Breaking.** The plugin has been renamed throughout. The reviewer role is now
the *inspector* (previously *overseer*), and the `mo-` command prefix is now
`mi-`. This is a clean break: there are no compatibility shims, aliases, or
migration prompts.

### What changed

- **Plugin identity.** Marketplace name `millwright-overseer` →
  `millwright-inspector`; plugin name `millwright-overseer-development-machine`
  → `millwright-inspector-development-machine`.
- **Commands.** Every `/mo-*` command is now `/mi-*` (e.g. `/mo-run` →
  `/mi-run`, `/mo-init` → `/mi-init`).
- **Data root.** The default workflow data folder is now `millwright-inspector/`
  (was `millwright-overseer/`). There is no fallback to the old folder.
- **Runtime files.** The `progress.md` field `overseer-review-completed` is now
  `inspector-review-completed`; the `config.md` section header
  `## Overseer Additions` is now `## Inspector Additions`; the review file
  `implementation/overseer-review.md` is now `implementation/inspector-review.md`;
  the PR-review report field `overseer-notes` is now `inspector-notes`.
- **Environment / internals.** `MO_DATA_ROOT`/`MO_PLUGIN_ROOT` →
  `MI_DATA_ROOT`/`MI_PLUGIN_ROOT`; internal `mo_*` bash helpers → `mi_*`; the
  `mo:` status prefix and `mo:sync-marker` comment → `mi:`; the status-bar
  wrapper `.claude/mo-stage-info-bar.sh` → `.claude/mi-stage-info-bar.sh`.
  (`CLAUDE_PLUGIN_ROOT` is provided by the Claude Code runtime and is
  unchanged.)

The new plugin does not read or migrate old `millwright-overseer/` data, and
the frontmatter hook rejects writes to the legacy `overseer-review.md` path.

### Migration for existing users

1. Uninstall the old plugin: `/plugin uninstall millwright-overseer-development-machine`
2. Remove the old marketplace: `/plugin marketplace remove millwright-overseer`
3. Re-add the marketplace: `/plugin marketplace add <repo>`
4. Install the new plugin: `/plugin install millwright-inspector-development-machine@millwright-inspector`
5. Start fresh with a `millwright-inspector/` data root.

To carry forward in-flight data, `mv millwright-overseer millwright-inspector`
manually and hand-edit any `progress.md` and `config.md` so the field and
section-header names match the new schema — the plugin will not migrate them
and will reject malformed files.

Status-bar users re-run `/mi-init-status-bar` after upgrading.

### New home

The plugin now lives at a new repository:
https://github.com/Eminakkoc/Millwright-Inspector-Development-Machine
The `marketplace.json` `homepage` field points there.
