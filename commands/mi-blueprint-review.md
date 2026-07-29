---
description: Orchestrate a token-reduced blueprint review (v1.5) — Phase A (preflight + summary build) → B (enumerate) → C (per-batch parallel review) → D (single consistency pass) → E (scope-expansion gate) → F (persist to review-history.md) → G (report). Every phase is recorded in a deterministic phase ledger; Phase G renders it as a table and FAILS if any mandatory phase was skipped. Uses the codex MCP tools — round-1 tool + -reply for rounds 2+; names resolved at Step 1 (unprefixed or plugin-prefixed depending on how the server is registered). See docs/blueprint-review-token-reduction/plan.md.
---

# /mi-blueprint-review

**Runtime bootstrap.** Every `$CLAUDE_PLUGIN_ROOT` reference in this command's Bash blocks assumes a resolved plugin root; Claude Code does not inject the env var into Bash subshells. If it is empty in your shell, apply the canonical resolver (`docs/millwright-inspector-project.md` §8.14; reference implementation: `mi-continue.md` Step 1a) before the first Bash block: (1) inherited env var when it points at a working install, (2) `$PWD` when it is this plugin's source repo, (3) the `installPath` from `~/.claude/plugins/installed_plugins.json` — then export it, persist it to the per-cwd tempfile, and prepend the recovery one-liner to every subsequent Bash block. Refuse with an environmental diagnostic if none resolve.

## Usage

```
/mi-blueprint-review <agent> <file-path>
                     [--auto-iter N] [--batch-size N] [--scope <heading>]
                     [--reasoning-effort <low|medium|high>] [--concurrency N]
                     [--max-items N] [--reference-file <path>]
```

| Param | Default | Meaning |
| --- | --- | --- |
| `<agent>` | (required) | Reviewer agent name. Currently `codex`. |
| `<file-path>` | (required) | Markdown file. Edits in place. |
| `--auto-iter N` | 5 | Per-batch / per-consistency-pass round budget. `1` = find-only (no fix step). |
| `--batch-size N` | 3 | Items per batch in Phase C. |
| `--scope <heading>` | (none) | Restrict Phase B enumeration to items under `## <heading>` only. |
| `--reasoning-effort R` | medium | Round-1 codex effort (via `config.model_reasoning_effort`). Locked per session; rounds 2+ inherit it. |
| `--concurrency N` | 3 | Maximum Phase C batches dispatched in parallel codex sessions per wave. |
| `--max-items N` | 35 | Hard cap on Phase B descriptor count. Above this, the orchestrator refuses and tells the inspector to split the file or use `/mi-blueprint-review-item` on a subset. |
| `--reference-file <path>` | (none) | Optional manifest file (`type: blueprint-review-context` in frontmatter, `references:` list of paths). The manifest's body is injected as **trusted inspector-authored review guidance** ("Review brief") and each linked artifact is injected as **strict read-only data** in an envelope ("Reference material"). Not repeatable — list multi-artifact reference sets inside one manifest's `references:` field. See `docs/blueprint-rv-context/report.md`. |

## Preconditions

- Reviewer's MCP server reachable (`/mi-doctor`).
- The codex reply tool available under either spelling — `mcp__codex__codex-reply` (user/project-registered server) or `mcp__plugin_millwright-inspector-development-machine_codex__codex-reply` (plugin-registered server; see Step 1's tool-name resolution). Session behavior verified at Phase 0 (`docs/blueprint-review-token-reduction/phase-0-findings.md`). If unavailable, sub-agents fall back to stateless mode automatically.
- File exists and is writable.

## Phase progression contract (READ BEFORE EXECUTING)

Phases run in order: **A → B → C → D → E → F → G**. Every phase is mandatory. Allowed early exits:

| Phase | Allowed skip | NOT allowed |
| --- | --- | --- |
| A — preflight | (none) | Skipping at all. |
| B — enumeration | `enumerate` exits 2 → abort orchestrator. | Skipping. |
| C — per-batch review | Descriptor count == 0 → skip C, proceed to D. | Skipping for cost / time / "items look fine." |
| D — consistency | (none) | Skipping because C found nothing / count was 0. |
| E — scope-expansion gate | 0 expanding findings → mark `skipped --findings 0`. | Skipping while expanding findings exist — that either grows the spec without consent or loses a real gap. |
| F — persist | (none) | Skipping; even if no findings, `last-review-at` updates. |
| G — final report | (none) | Skipping. |

Announce each phase as you enter it (one short line: `Phase X — <name> — starting`).

### Enforcement — the phase ledger (NOT optional)

Your own judgment is **not** authorized to skip Phase C, Phase D, or Phase E. "Items look
fine", "cost", "time", "C found nothing so D is redundant", "the expanding findings are
obviously good ideas" are all forbidden rationales. That last one is specifically
forbidden: whether a proposed mechanism is a good idea is exactly the judgment Phase E
reserves for the inspector. To make skipping impossible to hide, this command is backed by a
**deterministic phase ledger** owned by `scripts/blueprint-review.sh`:

1. **Step 1 initializes** the ledger for this run (`ledger init`).
2. **Every phase records itself** the instant it runs, via
   `ledger mark <file> <PHASE> <status> [--findings N] [--note "…"]`. Mark
   `running` when you enter the phase and `done` when it completes.
3. **Phase G renders** the ledger as the final table via `ledger render`. Render
   **exits 3** — a hard failure under `set -euo pipefail` — if any mandatory phase
   was never marked `done` (C may be `skipped` only when Phase B enumerated 0
   items; E only when it recorded `--findings 0`; F may be `skipped` only when the
   file is not under `blueprints/current/`).

**Contract:** the table you show the inspector is the *verbatim* stdout of
`ledger render`. You may NOT hand-author it, and you may NOT report the review as
successful while `ledger render` exits non-zero. Phase E is enforced the same way
Phase C is: `skipped` counts as sanctioned only when it was marked with
`--findings 0`. If it exits non-zero, a mandatory
phase did not run: go back, execute the missing phase(s) for real, mark them, and
re-run `ledger render` until it exits 0.

## Execution

### Step 1 — Validate inputs and resolve constants

```bash
set -euo pipefail
agent="${1:-}"
file="${2:-}"
auto_iter=5
batch_size=3
scope=""
reasoning_effort="medium"
concurrency=3
max_items=35
reference_file=""
i=3
while [[ $i -le $# ]]; do
  arg="${!i}"
  case "$arg" in
    --auto-iter=*)        auto_iter="${arg#--auto-iter=}" ;;
    --auto-iter)          ((i++)); auto_iter="${!i}" ;;
    --batch-size=*)       batch_size="${arg#--batch-size=}" ;;
    --batch-size)         ((i++)); batch_size="${!i}" ;;
    --scope=*)            scope="${arg#--scope=}" ;;
    --scope)              ((i++)); scope="${!i}" ;;
    --reasoning-effort=*) reasoning_effort="${arg#--reasoning-effort=}" ;;
    --reasoning-effort)   ((i++)); reasoning_effort="${!i}" ;;
    --concurrency=*)      concurrency="${arg#--concurrency=}" ;;
    --concurrency)        ((i++)); concurrency="${!i}" ;;
    --max-items=*)        max_items="${arg#--max-items=}" ;;
    --max-items)          ((i++)); max_items="${!i}" ;;
    --reference-file=*)   reference_file="${arg#--reference-file=}" ;;
    --reference-file)     ((i++)); reference_file="${!i}" ;;
  esac
  ((i++))
done

[[ -n "$agent" && -n "$file" ]] || {
  echo "usage: /mi-blueprint-review <agent> <file> [--auto-iter N] [--batch-size N] [--scope X] [--reasoning-effort R] [--concurrency N] [--max-items N] [--reference-file <path>]" >&2
  exit 64
}
[[ "$auto_iter" =~ ^[1-9][0-9]*$ ]]   || { echo "error: --auto-iter must be positive integer" >&2; exit 64; }
[[ "$batch_size" =~ ^[1-9][0-9]*$ ]]  || { echo "error: --batch-size must be positive integer" >&2; exit 64; }
[[ "$concurrency" =~ ^[1-9][0-9]*$ ]] || { echo "error: --concurrency must be positive integer" >&2; exit 64; }
[[ "$max_items" =~ ^[1-9][0-9]*$ ]]   || { echo "error: --max-items must be positive integer" >&2; exit 64; }
[[ "$reasoning_effort" =~ ^(low|medium|high)$ ]] || { echo "error: --reasoning-effort must be low|medium|high" >&2; exit 64; }
[[ -f "$file" && -w "$file" ]] || { echo "error: file not found or not writable: $file" >&2; exit 1; }
[[ -z "$reference_file" || -r "$reference_file" ]] || { echo "error: --reference-file path not readable: $reference_file" >&2; exit 64; }

reviewer_tool="$($CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh resolve-tool "$agent")" || exit 1
reviewer_reply_tool="mcp__${agent}__${agent}-reply"   # v1.5 convention; matches Phase 0 finding
MAX_ITEMS_PER_REVIEW="$max_items"

# Initialize the phase ledger for this run. Every phase marks itself; Phase G
# renders it and fails if any mandatory phase was skipped. The ledger path is
# derived from "$file" internally, so every later bash block resolves the same
# ledger without threading a variable across invocations.
"$CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh" ledger init "$file"
```

**Tool-name resolution (environment-dependent — do this before any codex call).** `resolve-tool` prints the unprefixed candidate (`mcp__codex__codex`), which is correct when the codex MCP server is registered at user/project level. When the server comes from this plugin's `plugin.json` (typical marketplace install), the session exposes the tools **plugin-prefixed** instead: `mcp__plugin_millwright-inspector-development-machine_codex__codex` / `mcp__plugin_millwright-inspector-development-machine_codex__codex-reply`. Check your actual tool inventory (ToolSearch for `codex` if not loaded): if the unprefixed pair is absent and the prefixed pair exists, reassign `reviewer_tool` / `reviewer_reply_tool` to the prefixed spellings. If **neither** spelling exists, refuse: `error: codex MCP tools not reachable under either name (mcp__codex__codex or mcp__plugin_millwright-inspector-development-machine_codex__codex) — run /mi-doctor.` The resolved values flow into every direct call below and into every sub-agent spawn input (`reviewer_tool_name` / `reviewer_reply_tool_name`) — the sub-agents call whatever names they are handed, so resolving here fixes the whole run.

### Step 2 — Phase A: preflight + summary build **(MANDATORY)**

Announce: `Phase A — preflight — starting`.

**A.1 — Resolve `review-history.md` sibling.** If the file sits inside `*/blueprints/current/`, lazily init the sibling artifact:

```bash
file_dir="$(cd "$(dirname "$file")" && pwd)"
review_history=""
if [[ "$file_dir" == */blueprints/current ]]; then
  review_history="$file_dir/review-history.md"
  if [[ ! -f "$review_history" ]]; then
    feature="$(basename "$(cd "$file_dir/../.." && pwd)")"
    req_id="$("$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" get "$file" id 2>/dev/null || echo null)"
    "$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh" init review-history "$review_history" \
      ID="$(uuidgen | tr 'A-Z' 'a-z')" \
      FEATURE="$feature" \
      REQUIREMENTS_ID="${req_id:-null}" \
      LAST_FINDING_ID=F-000 \
      FINDING_COUNT_TOTAL='!RAW!0' \
      FINDING_COUNT_UNRESOLVED='!RAW!0' \
      LAST_REVIEW_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
fi
```

If the file is not under `blueprints/current/`, `review_history` stays empty and Phase F is silently skipped at Step 6.

**A.2 — Resolve `lessons_block`.** Identical to v1.2.x sibling-detection (only fires when the file's grandparent contains `implementation/blueprint-lessons.md` with `selected-count > 0`). See `commands/mi-apply-impact.md` Pre-Step A for the producer side.

**A.3 — Build `file_metadata_brief`** in main (a small markdown block sent into every codex session opener):

```
- Feature: <feature slug>
- File: <basename of $file>
- Items in scope: <comma-separated ids from Phase B enumeration>
- Sections: <comma-separated top-level ## headings>
- Glossary: <comma-separated bolded-term sample, up to 10 unique>
```

The items + sections + glossary list is built deterministically after Phase B completes (since enumeration drives the items list). For Phase D's spawn, this block is finalized before Step 5.

**A.4 — Build `history_summary` for consistency scope** if `review_history` is non-empty:

```bash
history_summary_consistency=""
if [[ -n "$review_history" && -f "$review_history" ]]; then
  history_summary_consistency="$("$CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh" \
    build-summary "$review_history" consistency 2>/dev/null || echo "")"
fi
```

Per-batch summaries are built in Step 4 once each batch's scope IDs are known.

**A.5 — Build `reference_block` from `--reference-file` (when supplied).** The reference block is a two-section markdown string with `## Review brief` (manifest body, outside envelopes — trusted inspector guidance) and `## Reference material` (linked artifacts each wrapped in `MI-REFERENCE` envelopes — strict data). It is threaded into the Phase C batch sub-agent + Phase D consistency sub-agent spawn inputs. **Phase B's enumeration call does NOT receive it** — codex would otherwise enumerate item anchors inside reference content, breaking the descriptor count. See `docs/blueprint-rv-context/report.md` §3.3.

```bash
reference_block=""
if [[ -n "$reference_file" ]]; then
  reference_block="$("$CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh" \
    build-reference-block "$file" "$reference_file")" || exit $?
fi
```

`build-reference-block` exits 64 on validation failure (manifest not found, wrong `type:` sentinel, malformed YAML, target self-reference, manifest == target). Failures propagate — the review aborts so the inspector can fix the manifest. Missing linked artifacts within a valid manifest are logged to stderr and silently skipped (graceful degradation, matches the auto-fire flow's "non-blocking gate" property).

**A.6 — Capture the size baseline** so Phase E and Phase G can report how much this run grew the spec. Each Bash block is a fresh subshell, so the value goes in the ledger rather than a shell variable:

```bash
"$CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh" ledger meta "$file" set size_baseline \
  "$("$CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh" size-stat "$file")"
```

`size-stat` prints `<body-lines> <items> <bytes>` with frontmatter and `REVIEW-FINDING` blocks excluded, so the number tracks spec growth rather than review-annotation churn.

**A.7 — Record Phase A in the ledger** (do this once A.1–A.6 have completed):

```bash
"$CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh" ledger mark "$file" A done \
  --note "preflight complete${review_history:+ (history: $(basename "$review_history"))}"
```

### Step 3 — Phase B: item enumeration **(MANDATORY)**

Announce: `Phase B — enumeration — starting`.
Record entry: `blueprint-review.sh ledger mark "$file" B running`.

Render `templates/blueprint-reviewer-prompt-enumerate.md.tmpl` (unchanged from v1.2.x) — substitute `{{SCOPE_INSTRUCTION}}` and `{{SCOPE_EMPTY_HINT}}` according to whether `--scope` was passed (same logic as v1.2.x orchestrator).

Call the resolved reviewer tool (`$reviewer_tool`) directly from main (one-shot; no sub-agent) with `sandbox="read-only"`, `approval-policy="never"`, `config={"model_reasoning_effort": "$reasoning_effort"}`. Discard the returned `threadId` — enumeration is single-call.

Parse the fenced ```json ... ``` array; pass to `scripts/blueprint-review.sh enumerate <file> <items.json>` for deterministic descriptor computation.

- If `enumerate` exits 2 → surface its `errors` array + abort.
- If descriptor count > `MAX_ITEMS_PER_REVIEW` → print refusal: `"File has N items, exceeds cap of ${MAX_ITEMS_PER_REVIEW}. Split across cycles, raise --max-items, or use /mi-blueprint-review-item on a subset."` + stop.
- If count == 0 → Phase C is legitimately empty: mark it skipped, then jump to Step 5 (Phase D still runs).

Record the descriptor count into the ledger — this count is what Phase G's `ledger render` checks Phase C against, so it MUST reflect the true enumeration result:

```bash
"$CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh" ledger mark "$file" B done \
  --findings "$descriptor_count" --note "$descriptor_count descriptors enumerated"

# Count == 0 is the ONLY sanctioned way to skip Phase C. Record it explicitly.
if [[ "$descriptor_count" -eq 0 ]]; then
  "$CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh" ledger mark "$file" C skipped \
    --note "0 descriptors — nothing to review per-item"
fi
```

### Step 4 — Phase C: per-batch review **(MANDATORY when descriptor count ≥ 1)**

Announce: `Phase C — per-item review — starting (N descriptors, batch size B, concurrency C)`.
Record entry: `blueprint-review.sh ledger mark "$file" C running`.

You **MUST** spawn a `blueprint-batch-reviewer` sub-agent for every batch of `batch_size` descriptors. Cost / time / "items look fine" are not valid reasons to skip — Phase C catches single-item ambiguities the whole-file Phase D pass under-weights. (Reaching this step at all means Phase B enumerated ≥ 1 descriptor; the ledger already recorded that count, and Phase G's `ledger render` will fail the whole review if Phase C is not marked `done` here.)

```python
# pseudocode for the orchestrator's batched-wave dispatcher
descriptors = sorted(descriptors, key=lambda d: d["start_offset"])
batches = [descriptors[i:i+batch_size] for i in range(0, len(descriptors), batch_size)]

for wave_start in range(0, len(batches), concurrency):
    wave = batches[wave_start : wave_start + concurrency]
    
    # Build per-batch summaries before dispatching the wave.
    spawn_inputs = []
    for b_idx, batch in enumerate(wave):
        scope_ids = [d["id"] for d in batch]
        history_summary_batch = ""
        if review_history:
            args = " ".join(f"--scope-id {sid}" for sid in scope_ids)
            history_summary_batch = sh(
                f'{plugin_root}/scripts/blueprint-review.sh build-summary {review_history} batch {args}'
            )
        spawn_inputs.append({
            "batch_id": f"B{wave_start + b_idx + 1}",
            "items": batch,                       # [{item_id, original_region}, ...]
            "max_iterations": auto_iter,
            "agent": agent,
            "reviewer_tool_name": reviewer_tool,
            "reviewer_reply_tool_name": reviewer_reply_tool,
            "reasoning_effort": reasoning_effort,
            "sub_agent_instance_id": f"T{wave_start + b_idx + 1}",
            "history_summary": history_summary_batch,
            "file_metadata_brief": file_metadata_brief,
            "lessons_block": "",                  # always empty for batch reviewer (spec §8.1.3)
            "reference_block": reference_block,   # from Phase A.5; may be empty
        })
    
    # Dispatch ALL spawn_inputs in this wave as parallel Agent calls in ONE message.
    payloads = parallel_dispatch(spawn_inputs, sub_agent_type="...:blueprint-batch-reviewer")
    
    # Flatten + serialize write-back in main.
    flat = []
    for p in payloads:
        flat.extend(p["items"])
    flat.sort(key=lambda it: original_offset_of(it["item_id"]))
    
    for it in flat:
        # Rewrite tmp-ids T<instance>-<n> to final F-NNN before applying.
        next_id = sh(f"scripts/blueprint-review.sh alloc-final-id {file}").strip()
        rewritten = rewrite_tmp_ids(it["new_region"], starting_at=next_id)
        try:
            Edit(file_path=file, old_string=it["original_region"], new_string=rewritten)
        except ExactMatchFailure:
            # Re-enumerate this item from current file state; re-spawn as single-item batch.
            new_d = re_enumerate_single_item(file, it["item_id"])
            new_payload = spawn_single_item_batch(new_d, ...)
            Edit(file_path=file,
                 old_string=new_payload["items"][0]["original_region"],
                 new_string=new_payload["items"][0]["new_region"])
        validate_frontmatter_unchanged(file)
```

When all waves complete, record Phase C — set `--findings` to the number of `<!-- REVIEW-FINDING -->` blocks the batch reviewers emitted this phase (0 is a valid, honest count):

```bash
"$CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh" ledger mark "$file" C done \
  --findings "$phase_c_finding_count" \
  --note "$num_batches batches, size $batch_size, concurrency $concurrency"
```

Then proceed to Step 5.

### Step 5 — Phase D: consistency loop **(MANDATORY — runs even when descriptor count was 0)**

Announce: `Phase D — consistency — starting`.
Record entry: `blueprint-review.sh ledger mark "$file" D running`.

Spawn one `blueprint-consistency-reviewer` sub-agent. Parameters:

```
file_path = $file
max_iterations = $auto_iter
agent = $agent
reviewer_tool_name = $reviewer_tool
reviewer_reply_tool_name = $reviewer_reply_tool
reasoning_effort = $reasoning_effort
lessons_block = (from A.2)
history_summary = history_summary_consistency (from A.4)
file_metadata_brief = (from A.3, updated after Phase B with item-ids in scope)
reference_block = $reference_block (from A.5; may be empty)
```

On `success` / `partial` / `blocked`: continue to Step 6 (Phase F) regardless. Phase F persists whatever findings the file ended up with. On `partial` with `reason: max-iter`: surface a y/n prompt: `"<B>B/<C>C/<H>H/<M>M consistency findings remain after <K> rounds — run another loop? (y/n)"` (drop the zero-count severities from the string). On `y`: re-spawn the sub-agent with the file's current state. On `n`: continue.

Once the loop resolves (whichever terminal outcome), record Phase D — set `--findings` to the number of consistency findings that remain inline:

```bash
"$CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh" ledger mark "$file" D done \
  --findings "$phase_d_finding_count" --note "$consistency_outcome after $consistency_rounds round(s)"
```

### Step 5.5 — Phase E: scope-expansion gate **(MANDATORY)**

Announce: `Phase E — scope-expansion gate — starting`.
Record entry: `blueprint-review.sh ledger mark "$file" E running`.

**Why this phase exists.** The fixer applies `clarifying` fixes automatically but is forbidden from applying `expanding` ones — fixes that would have the implementer build something the spec does not contain today. Without a gate, those either get silently applied (the spec grows a little more on every review run until it no longer matches what the inspector asked for) or get silently discarded (a real gap is lost). Phase E is where a human decides, once, per run.

**E.1 — Collect the expanding findings.**

```bash
expanding_json="$("$CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh" parse-findings "$file" \
  | python3 -c 'import sys,json; print(json.dumps([f for f in json.load(sys.stdin) if f.get("scope-impact")=="expanding"]))')"
expanding_count="$(python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' <<<"$expanding_json")"
```

If `expanding_count == 0`, there is nothing to gate — record the sanctioned skip and go to Step 6:

```bash
"$CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh" ledger mark "$file" E skipped \
  --findings 0 --note "no scope-expanding findings"
```

(`ledger render` accepts `E skipped` **only** with `--findings 0`. Skipping it while expanding findings exist fails the run — the same enforcement shape as Phase C.)

**E.2 — Present them compactly.** One block, not one prompt per finding. For each expanding finding print exactly one line:

```
<F-NNN> [<severity>, <target>] would add: <the mechanism, in ≤ 12 words>
    why: <the finding, one line>
```

Then the growth line, from the Phase A baseline (`ledger meta … get size_baseline`) versus the current `size-stat`:

```
requirements.md this run: <lines_before> → <lines_after> lines (<+N>), <items_before> → <items_after> items.
Applying all <N> expanding findings would add roughly <M> more lines of scope.
```

**E.3 — Ask once:**

```
<N> findings propose adding NEW mechanism to this blueprint that isn't there today.
These were NOT applied — the review deliberately stops here so scope stays yours.

Reply:
  none          — apply nothing (default). The findings stay inline as comments and are
                  recorded as declined, so future reviews won't re-propose them.
  all           — apply every proposal above.
  F-003 F-007   — apply just these; the rest are recorded as declined.
  keep F-003    — apply nothing now, but leave the listed ones open for next time
                  (neither applied nor declined).
```

**E.4 — Apply the approved subset, in main, serially.** For each approved id: apply its `suggested-fix` to the file with `Edit`, then remove that `REVIEW-FINDING` block. Apply the smallest edit that satisfies the fix — the inspector approved the mechanism described on that one line, not a redesign of the item. Re-validate frontmatter after each edit (`last-finding-id` may change only via `alloc-final-id`).

For each **declined** id: leave the `REVIEW-FINDING` block inline and add it to the Phase F persist input with `status: deferred` plus a `deferred_reason` (the inspector's words when they gave a reason; otherwise `"inspector declined at the scope-expansion gate"`). This is what stops the regrowth loop: `build-summary` renders declined findings into every future reviewer session under a "DECLINED BY THE INSPECTOR — do NOT re-raise" heading, so the next run does not rediscover and re-apply the same mechanism.

For each `keep` id: leave the block inline and persist it as `still-present` — undecided, so it comes back next run.

**E.5 — Non-interactive safety.** If the inspector cannot be prompted (no TTY, unattended run), apply **nothing** and record every expanding finding as `still-present`, not `deferred` — silence is not consent, and it is also not refusal. Note it: `"Phase E: <N> expanding findings left unapplied (non-interactive run) — re-run and answer the gate, or apply them by hand."` The safe direction is always "don't grow the file."

```bash
"$CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh" ledger mark "$file" E done \
  --findings "$expanding_count" --note "$approved_count applied, $declined_count declined, $kept_count kept open"
```

### Step 6 — Phase F: persist to review-history.md **(MANDATORY when `review_history` is set)**

Announce: `Phase F — persist — starting`.

Collect every `<!-- REVIEW-FINDING -->` block currently in the file via `scripts/blueprint-review.sh parse-findings`. Compare against existing `## F-NNN` sections in `review-history.md` (parse with grep / awk):

| In file? | In history? | Action |
| --- | --- | --- |
| yes | no | emit `status: new` entry with full body (`severity`, `scope_impact`, `phase`, `target`, `finding`, `suggested_fix` — all snake_case to match the v1.5 reviewer template contract; `persist-findings` reads `suggested_fix`) |
| yes | yes | **declined at Phase E** → emit `status: deferred` with `deferred_reason`. This is the entry that stops the next run re-proposing the same mechanism; without it the gate only holds for one run |
| yes | yes | emit `status: still-present` entry (just timestamp bump; persist-findings is a no-op for these since status doesn't change, but the script still updates `last-review-at`) |
| no | yes (with `last-status: still-present` or `refined`) | emit `status: dropped` entry — the finding's `REVIEW-FINDING` block was removed from the spec body (fixer resolved it, OR inspector manually deleted it without a `resolved_by_change` note) |
| no | yes (with `last-status: resolved` or `dropped`) | no entry (no state change needed) |

Pipe the JSON array to `scripts/blueprint-review.sh persist-findings`:

```bash
echo "$findings_json" > "/tmp/mi-persist-input.$$.json"
"$CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh" persist-findings "$review_history" "/tmp/mi-persist-input.$$.json"
rm -f "/tmp/mi-persist-input.$$.json"
"$CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh" ledger mark "$file" F done \
  --findings "$persisted_count" --note "persisted to $(basename "$review_history")"
```

If `review_history` is empty (file not under `blueprints/current/`), skip Phase F — inline findings stay in the file with no history record. This is the ONLY sanctioned Phase F skip, so record it so the ledger stays honest:

```bash
"$CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh" ledger mark "$file" F skipped \
  --note "file not under blueprints/current/ — no review-history sibling"
```

### Step 7 — Phase G: final report **(MANDATORY)**

Announce: `Phase G — final report — starting`.
Record entry: `blueprint-review.sh ledger mark "$file" G running`.

**G.1 — Render the phase-ledger table (REQUIRED, and it is the gate).** Run:

```bash
"$CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh" ledger render "$file"
render_rc=$?
```

Show the table stdout to the inspector **verbatim** — it is the mandated "each phase, did it run, did it find anything" report. Do NOT hand-author or paraphrase it.

- If `render_rc == 0`: every mandatory phase ran. Continue to G.2.
- If `render_rc == 3`: the table names a mandatory phase that was NOT run (e.g. Phase C or Phase D). **Stop. Do not report success.** Go back and actually execute the missing phase(s) per Steps 4/5, mark them (`ledger mark`), then re-run `ledger render` until it exits 0. Skipping the phase and editing the ledger by hand is a contract violation.

**G.2 — Summarize inline findings.** Inspect the file's final `<!-- REVIEW-FINDING -->` block count + severity breakdown (via `scripts/blueprint-review.sh parse-findings`). Print:

- `"No findings remain (Success)"` — if nothing at a reportable severity remains inline.
- Otherwise: `"<B>B/<C>C/<H>H/<M>M remain inline in <file>; <N> findings recorded in <review_history>"` — drop the zero-count severities from the string, and omit the second clause if `review_history` is empty.

**Escalate blockers and criticals explicitly.** When any `blocker` or `critical` block remains inline, follow the count line with one line per such finding — `<F-NNN> [<severity>, <target>]: <first line of finding>` — and this sentence: `"Blocker/critical findings mean the blueprint is not implementable as written; resolve them before advancing past stage 2."` They are still not a hard gate (this command never blocks the workflow), but they must not be buried in a count.

**G.2b — Report the growth.** Compare the Phase A baseline against the file's current state and print one line, always — a run that changed nothing should say so:

```bash
before="$("$CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh" ledger meta "$file" get size_baseline)"
after="$("$CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh" size-stat "$file")"
```

Render as `"Spec size: <lines_before> → <lines_after> lines (<±N>), <items_before> → <items_after> items."` followed, when Phase E declined or kept anything, by `"<D> scope-expanding proposal(s) declined and recorded — future reviews won't re-raise them; <K> left open."`

This line is the feedback loop that makes creeping growth visible run over run. If lines grew by more than ~15% while Phase E applied nothing, say so plainly: `"Note: the spec grew <N>% from clarifying fixes alone — worth checking that the review is sharpening the requirements rather than padding them."`

**G.3 — Mark Phase G done + cleanup:**

```bash
"$CLAUDE_PLUGIN_ROOT/scripts/blueprint-review.sh" ledger mark "$file" G done --note "report rendered"
rm -f /tmp/mi-*.$$.*
```

The ledger file itself lives under `$TMPDIR` keyed by the reviewed file's path; it is left in place (harmless) and reset by the next run's `ledger init`.

## Notes

- **Severity vocabulary (v1.6.8).** Findings carry `blocker | critical | high | medium`. There is no `low` — the reviewer templates declare it out of scope and both reviewer sub-agents drop any `low` entry that arrives anyway (reported as `dropped-low: N` in their return). Blocks carrying `severity: low` from a pre-v1.6.8 run are left alone in place and still parse; they are simply never created again.
- **Scope-expansion gate (v1.6.10).** Reviewer findings carry `scope_impact: clarifying | expanding`. The fixer auto-applies only `clarifying` fixes; `expanding` ones — those that would have the implementer build something the spec does not contain today — are never applied automatically. Phase E shows them to the inspector once, applies only what they approve, and records the rest as `deferred` in `review-history.md` so future runs do not re-propose them. This is what keeps `requirements.md` from growing a little more on every review.
- **Shipped-code regression is in scope.** Both reviewer passes check every item against already-shipped behavior — see the "Shipped-code regression check" section in `templates/blueprint-reviewer-prompt-batch.md.tmpl` (per item) and `…-consistency.md.tmpl` (file-wide). The evidence comes from the item's own `**Shipped-code impact:**` bullet and the grounding report injected via `--reference-file`.
- This command does NOT mutate `progress.md` or any quest file. It is workflow-neutral when invoked manually. Stage-2 auto-invocation is wired in `commands/mi-apply-impact.md` (see Step B.5).
- All file writes happen in main (Step 4 write-back loop, Step 5 sub-agent direct writes, Step 6 persist). Sub-agents read but never write the spec file (batch reviewer is structurally read-only; consistency reviewer is serial-safe).
- Session-expiry behavior: if `codex-reply` errors with `Session not found for thread_id`, the affected sub-agent re-issues that round as a fresh `reviewer_tool_name` call (full prompt cost for one round; subsequent rounds continue on the new session).

## See also

- `docs/blueprint-review-token-reduction/plan.md` — v1.5 design.
- `docs/blueprints-review/plan.md` — v1.2.x prior art (item enumeration, canonical region descriptor, `alloc-final-id` semantics unchanged).
- `commands/mi-blueprint-review-consistency.md`, `commands/mi-blueprint-review-item.md` — standalone variants.
