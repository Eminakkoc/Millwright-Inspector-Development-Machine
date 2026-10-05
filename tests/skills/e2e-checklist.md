# skills-across-workflow — manual end-to-end checklist (mi-sample)

Run one full cycle in the mi-sample project with the 1.12.0 plugin. Tick each line.

- [ ] Journal names `web-images` (catalog skill) and an MCP server for one feature.
- [ ] Stage 1: `summary.md` has `## Requested skills` with a `web-images` line and the MCP server line.
- [ ] Stage 2: `config.md` has `web-images` under `## Catalog suggestions` (`requested: journal`) and at least one `requested: no` suggestion; no `## Rules`.
- [ ] Stage-2 hand-off lists the MCP server as "not a skill — set it up yourself before /mi-continue".
- [ ] Approve gate with auto mode on and the feature branch missing: `auto.sh create-branch` creates it while `.claude/catalog.lock.json` is tracked.
- [ ] Decline one `requested: no` suggestion: it disappears from `config.md`.
- [ ] An unrelated file staged before `/mi-continue` is still staged afterwards and absent from the `chore(skills): install … from catalog` commit.
- [ ] The install commit is older than `progress.md`'s `base-commit` (`git merge-base --is-ancestor <install-sha> <base-commit>`).
- [ ] `primer.md` has `## Skills for this work (from config.md)` (and the review section when review skills exist).
- [ ] The plan's tasks carry `**Skills:**` / `**Review skills:**` lines; the stage-5 hand-off prints the `skills: N of M …` line.
- [ ] `/mi-update-blueprint "scope shifted"` leaves the auto block byte-identical.
- [ ] `/mi-analyze-review` on a PR from the feature branch uses the feature's review skills; on a PR from another branch it uses the inventory-based pick.
