# Reviewer fixtures

Inputs for `reviewer-checks.sh`, which runs the real `conventions-reviewer`
against each case. Each case has:

- `base/` — committed before `base-commit` (the skill or rule under `.claude/`).
- `change/` — committed after it: the feature's changed code.
- `decisions.md` (optional) — copied to `workflow-stream/feat/decisions.md`.

Every skill under `base/.claude/skills/` is listed in `config.md` as a
review-stage skill. Rules under `base/.claude/rules/` are found by prepare.

| case | entry | expected |
| --- | --- | --- |
| `violation` | skill `no-var` | 1 finding at `src/x.js:2` quoting "Never declare variables with var." |
| `clean` | skill `semi` | `Result: clean`, 0 findings |
| `decision` | skill `no-var` + a decision allowing line 2 | no finding for line 2 |
| `not-checkable` | rule `context7` | `1 entries not checkable` |
