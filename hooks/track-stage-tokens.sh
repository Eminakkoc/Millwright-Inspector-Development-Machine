#!/usr/bin/env bash
# track-stage-tokens.sh — PostToolUse(Bash) hook for millwright-overseer-development-machine.
#
# Reads the tool-call JSON on stdin, classifies the bash command as a stage
# transition (or anchor / no-op), then:
#   - For row-writing triggers: sums tokens across the assistant turns
#     since the last advance, appends a new row to the per-cycle sidecar
#     (`quest/<active-slug>/.stage-tokens.json`) and a full-detail NDJSON
#     record to the per-cycle usage log (`quest/<active-slug>/usage.log`).
#   - For anchor triggers: updates sidecar metadata for status-line display
#     (current_feature, current_stage) without writing a row.
#   - For everything else: exits silently.
#
# The status-line script (scripts/info-bar.sh) reads the sidecar and prints
# one line for Claude Code's bottom bar. The usage log is the append-only
# audit trail consumed by the overseer via direct `jq` queries.
#
# Wiring: hooks/hooks.json registers this on PostToolUse with matcher Bash.
# Plugin hooks merge with user-level .claude/settings.json hooks (both fire),
# so users keep their own hooks alongside this one.
#
# Design reference: docs/info-bar/plan.md (full).
# Manual-test sub-flow: docs/manual-testing/plan.md (the "5-mt" row label).

set -euo pipefail

# Read the entire stdin payload (the tool-call JSON).
hook_input="$(cat)"

# Resolve plugin root and source common.sh for mo_data_root etc. We support
# both invocation by Claude Code (with $CLAUDE_PLUGIN_ROOT set) and direct
# testing (compute from this script's path).
plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
if [[ -z "$plugin_root" ]]; then
  plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
# shellcheck disable=SC1091
source "${plugin_root}/scripts/internal/common.sh"

# Extract tool_name + tool_input.command + transcript_path + session_id + cwd
# from the hook input JSON. Claude Code passes:
#   tool_name        : "Bash" (filtered by the manifest matcher, but we double-check)
#   tool_input.command : the literal command string
#   transcript_path  : absolute path to the main session's JSONL transcript
#   session_id       : main-session UUID
#   cwd              : the main session's working directory at the time of the
#                      tool call. CRITICAL — Claude Code does NOT inherit $PWD
#                      into hook subprocesses; without this field, mo_data_root
#                      resolves wrong and the hook silently exits because
#                      quest/active.md isn't found at $PWD/millwright-overseer.
hook_fields="$(printf '%s' "$hook_input" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = d.get("tool_input") or {}
print(d.get("tool_name") or "")
print(ti.get("command") or "")
print(d.get("transcript_path") or "")
print(d.get("session_id") or "")
print(d.get("cwd") or "")
' 2>/dev/null || true)"

# IFS-safe parse of the five newline-separated fields.
{ IFS= read -r tool_name; IFS= read -r command; IFS= read -r transcript_path; IFS= read -r session_id; IFS= read -r session_cwd; } <<< "$hook_fields" || true

# Defensive: only act on Bash tool calls. The matcher should filter, but a
# manual test invocation might not.
[[ "$tool_name" == "Bash" ]] || exit 0
[[ -n "$command" ]] || exit 0

# Anchor the hook's working directory to the user's session, NOT whatever
# Claude Code launched the hook with. mo_data_root reads $PWD; without this
# cd, the hook resolves data_root to a stale location (the plugin install
# dir, $HOME, or whatever Claude Code's hook subprocess inherits) and then
# silently exits because quest/active.md isn't there. Falls back to whatever
# $PWD already is if `cwd` is missing from the payload — back-compat for
# older Claude Code versions that may not include it.
if [[ -n "$session_cwd" && -d "$session_cwd" ]]; then
  cd "$session_cwd" || exit 0
fi

# ------------------------------------------------------------------------
# Trigger classification.
#
# We match commands using regex. The patterns are anchored on the script
# basename + subcommand so a parent shell wrapper (e.g., `time progress.sh
# advance 2`) still matches. `progress.sh set ...` is field-value-pair
# matched in any order.
# ------------------------------------------------------------------------

# Returns one of:
#   ROW <stage-label> <attribution-mode>
#     attribution-mode ∈ active|completed-last|null
#   ANCHOR_FEATURE             — set sidecar.current_feature = active.feature
#   ANCHOR_STAGE_5MT           — set sidecar.current_stage = "5-mt", do NOT write row
#   SKIP                       — silent no-op
#
# Manual-test pattern matching: progress.sh set accepts multiple field=value
# pairs; we look for both required pairs in any order.
classify_trigger() {
  local cmd="$1"

  # quest.sh start — anchor (no-op for token attribution; cycle folder created here).
  if [[ "$cmd" =~ quest\.sh[[:space:]]+start([[:space:]]|$) ]]; then
    echo "SKIP"; return
  fi

  # progress.sh activate <feature> — anchor; update current_feature.
  if [[ "$cmd" =~ progress\.sh[[:space:]]+activate([[:space:]]|$) ]]; then
    echo "ANCHOR_FEATURE"; return
  fi

  # progress.sh init ... — row, stage "1", feature null.
  if [[ "$cmd" =~ progress\.sh[[:space:]]+init([[:space:]]|$) ]]; then
    echo "ROW 1 null"; return
  fi

  # progress.sh reorder ... — row, stage "1.5", feature null.
  if [[ "$cmd" =~ progress\.sh[[:space:]]+reorder([[:space:]]|$) ]]; then
    echo "ROW 1.5 null"; return
  fi

  # progress.sh advance N — row, stage "N", feature active.
  if [[ "$cmd" =~ progress\.sh[[:space:]]+advance[[:space:]]+([0-9]+) ]]; then
    local stage="${BASH_REMATCH[1]}"
    echo "ROW ${stage} active"; return
  fi

  # progress.sh advance-to FROM TO — collapsed transitions.
  if [[ "$cmd" =~ progress\.sh[[:space:]]+advance-to[[:space:]]+([0-9]+)[[:space:]]+([0-9]+) ]]; then
    local from="${BASH_REMATCH[1]}"; local to="${BASH_REMATCH[2]}"
    if [[ "$from" == "3" && "$to" == "5" ]]; then
      echo "ROW 3+4 active"; return
    elif [[ "$from" == "5" && "$to" == "7" ]]; then
      echo "ROW 5 active"; return
    elif [[ "$from" == "6" && "$to" == "7" ]]; then
      echo "ROW 6 active"; return
    fi
    # Other advance-to combinations don't exist in the workflow today.
    echo "SKIP"; return
  fi

  # progress.sh finish — row, stage "8", feature completed[-1] (post-state read).
  if [[ "$cmd" =~ progress\.sh[[:space:]]+finish([[:space:]]|$) ]]; then
    echo "ROW 8 completed-last"; return
  fi

  # progress.sh set ... — only the manual-test patterns are stage transitions.
  # NB: macOS bash 3.2 does NOT support \b in =~ regex; use explicit space/end anchors.
  if [[ "$cmd" =~ progress\.sh[[:space:]]+set([[:space:]]|$) ]]; then
    # Manual-test EXIT (row "5-mt"): both sub-flow=none AND manual-test-state=complete.
    if [[ "$cmd" =~ (^|[[:space:]])sub-flow=none([[:space:]]|$) ]] && \
       [[ "$cmd" =~ (^|[[:space:]])manual-test-state=complete([[:space:]]|$) ]]; then
      echo "ROW 5-mt active"; return
    fi
    # Manual-test ENTRY (anchor): both sub-flow=manual-testing AND manual-test-state=running.
    if [[ "$cmd" =~ (^|[[:space:]])sub-flow=manual-testing([[:space:]]|$) ]] && \
       [[ "$cmd" =~ (^|[[:space:]])manual-test-state=running([[:space:]]|$) ]]; then
      echo "ANCHOR_STAGE_5MT"; return
    fi
    # Other progress.sh set invocations are intra-stage state writes — silent no-op.
    echo "SKIP"; return
  fi

  echo "SKIP"
}

trigger="$(classify_trigger "$command")"
trigger_kind="${trigger%% *}"

case "$trigger_kind" in
  SKIP) exit 0 ;;
  ROW|ANCHOR_FEATURE|ANCHOR_STAGE_5MT) ;;
  *) exit 0 ;;
esac

# ------------------------------------------------------------------------
# Resolve the active cycle's quest dir. If no active cycle, exit silently
# (e.g., the hook fired from another repo, or before quest.sh start ran).
# ------------------------------------------------------------------------
quest_dir="$("${plugin_root}/scripts/quest.sh" dir 2>/dev/null || true)"
[[ -n "$quest_dir" && -d "$quest_dir" ]] || exit 0

sidecar="${quest_dir}/.stage-tokens.json"
usage_log="${quest_dir}/usage.log"

# ------------------------------------------------------------------------
# Resolve feature attribution.
#   active        — read progress.md `active.feature`
#   completed-last — read progress.md `completed[-1]` (used post-`finish`)
#   null          — leave null
# ------------------------------------------------------------------------
resolve_feature() {
  local mode="$1"
  case "$mode" in
    null) echo "" ;;
    active)
      "${plugin_root}/scripts/progress.sh" get-active 2>/dev/null || true
      ;;
    completed-last)
      python3 - <<'PYEOF'
import os, sys, re, yaml
quest_dir = os.environ.get("QUEST_DIR_FOR_HOOK", "")
path = os.path.join(quest_dir, "progress.md")
if not os.path.isfile(path):
    sys.exit(0)
with open(path) as f:
    content = f.read()
m = re.match(r"^---\n(.*?)\n---\n", content, re.DOTALL)
if not m: sys.exit(0)
fm = yaml.safe_load(m.group(1)) or {}
done = fm.get("completed") or []
print(done[-1] if done else "")
PYEOF
      ;;
  esac
}

# ------------------------------------------------------------------------
# Anchor handling — update sidecar metadata, no row write.
# ------------------------------------------------------------------------
init_sidecar_if_missing() {
  if [[ ! -f "$sidecar" ]]; then
    local cycle_slug
    cycle_slug="$(basename "$quest_dir")"
    python3 - "$sidecar" "$cycle_slug" "$session_id" <<'PYEOF'
import json, sys, os
path, slug, session = sys.argv[1:4]
data = {
    "cycle_slug": slug,
    "session_id": session,
    "current_stage": None,
    "current_feature": None,
    "current_stage_tokens": 0,
    "up_to_that_point_tokens": 0,
    "last_advance_at": None,
    "stages": [],
}
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
os.rename(tmp, path)
PYEOF
  fi
}

if [[ "$trigger_kind" == "ANCHOR_FEATURE" ]]; then
  init_sidecar_if_missing
  feature="$("${plugin_root}/scripts/progress.sh" get-active 2>/dev/null || true)"
  [[ -n "$feature" && "$feature" != "null" ]] || exit 0
  python3 - "$sidecar" "$feature" <<'PYEOF'
import json, os, sys
path, feature = sys.argv[1], sys.argv[2]
with open(path) as f:
    d = json.load(f)
d["current_feature"] = feature
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2)
os.rename(tmp, path)
PYEOF
  exit 0
fi

if [[ "$trigger_kind" == "ANCHOR_STAGE_5MT" ]]; then
  init_sidecar_if_missing
  python3 - "$sidecar" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
with open(path) as f:
    d = json.load(f)
d["current_stage"] = "5-mt"
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2)
os.rename(tmp, path)
PYEOF
  exit 0
fi

# ------------------------------------------------------------------------
# Row-writing path.
# ------------------------------------------------------------------------
# Parse "ROW <stage> <attribution-mode>"
read -r _ stage_label attribution_mode <<< "$trigger"

export QUEST_DIR_FOR_HOOK="$quest_dir"
feature="$(resolve_feature "$attribution_mode")"
# Normalize empty / "null" to empty.
if [[ -z "${feature:-}" || "$feature" == "null" ]]; then
  feature=""
fi

# Sidecar must exist by this point unless this is the very first stage. For
# stage-1 triggers (init, reorder, feature null), self-init.
init_sidecar_if_missing

# Locate the transcript. Prefer the path Claude Code passed; fall back to a
# computed path if the hook payload lacks it.
if [[ -z "$transcript_path" || ! -f "$transcript_path" ]]; then
  if [[ -n "$session_id" ]]; then
    project_hash="$(echo "$plugin_root" | tr '/.' '-')"
    project_hash="${project_hash#-}"
    candidate="${HOME}/.claude/projects/-${project_hash}/${session_id}.jsonl"
    if [[ -f "$candidate" ]]; then transcript_path="$candidate"; fi
  fi
fi

# Sum tokens between last_advance_at and now from the transcript. We use
# python3 so we can do timezone-safe ISO parsing and proper JSONL streaming.
# Write through a temp file to avoid bash heredoc-inside-$() parsing fragility.
metrics_tmp="$(mktemp)"
trap 'rm -f "$metrics_tmp"' EXIT
python3 - "$sidecar" "$transcript_path" > "$metrics_tmp" <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone

sidecar_path, transcript_path = sys.argv[1], sys.argv[2]

with open(sidecar_path) as f:
    sidecar = json.load(f)
last_advance = sidecar.get("last_advance_at")

def parse_ts(s):
    if not s: return None
    s = s.replace("Z", "+00:00") if s.endswith("Z") else s
    try:
        return datetime.fromisoformat(s)
    except Exception:
        return None

lo = parse_ts(last_advance)

input_tokens = output_tokens = cache_creation = cache_read = 0
main_context_size = 0  # most recent assistant turn's input-side total

def take_record(rec):
    global input_tokens, output_tokens, cache_creation, cache_read, main_context_size
    if rec.get("type") != "assistant":
        return
    if rec.get("isSidechain") is True:
        return  # sidechain (sub-agent) turns are aggregated separately by sub-context discovery
    ts = parse_ts(rec.get("timestamp"))
    if lo is not None and ts is not None and ts <= lo:
        return
    msg = rec.get("message") or {}
    usage = msg.get("usage") or {}
    in_t = int(usage.get("input_tokens") or 0)
    out_t = int(usage.get("output_tokens") or 0)
    cc_t = int(usage.get("cache_creation_input_tokens") or 0)
    cr_t = int(usage.get("cache_read_input_tokens") or 0)
    input_tokens   += in_t
    output_tokens  += out_t
    cache_creation += cc_t
    cache_read     += cr_t
    main_context_size = in_t + cc_t + cr_t  # last seen wins; this becomes the most-recent

if transcript_path and os.path.isfile(transcript_path):
    with open(transcript_path) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            take_record(rec)

total = input_tokens + output_tokens + cache_creation + cache_read
print(json.dumps({
    "input": input_tokens,
    "output": output_tokens,
    "cache_creation": cache_creation,
    "cache_read": cache_read,
    "total": total,
    "main_context_size": main_context_size,
}))
PYEOF
metrics="$(cat "$metrics_tmp")"

# Now write the sidecar update + append the usage-log NDJSON record.
python3 - \
  "$sidecar" "$usage_log" "$stage_label" "${feature}" \
  "$metrics" "$session_id" "${transcript_path:-}" <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone

sidecar_path, log_path, stage, feature_arg, metrics_json, session_id, transcript_path = sys.argv[1:8]
metrics = json.loads(metrics_json)

feature = feature_arg if feature_arg else None

now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# --- Sidecar update ---
with open(sidecar_path) as f:
    d = json.load(f)
if not d.get("session_id"):
    d["session_id"] = session_id
total = metrics["total"]
new_row = {
    "stage": stage,
    "feature": feature,
    "tokens": total,
    "completed_at": now,
}
d["stages"].append(new_row)
d["current_stage"] = stage
d["current_feature"] = feature
d["current_stage_tokens"] = total
d["up_to_that_point_tokens"] = sum(int(s.get("tokens") or 0) for s in d["stages"])
d["last_advance_at"] = now
tmp = sidecar_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2)
os.rename(tmp, sidecar_path)

# --- Usage log append ---
log_record = {
    "ts": now,
    "stage": stage,
    "feature": feature,
    "tokens": {
        "input": metrics["input"],
        "output": metrics["output"],
        "cache_creation": metrics["cache_creation"],
        "cache_read": metrics["cache_read"],
        "total": metrics["total"],
    },
    "context": {
        "main": metrics["main_context_size"],
        "sub": [],  # sub-context discovery deferred — see plan § 3 "Sub-context discovery"
    },
    "schema_version": 1,
}
# Sub-context discovery: best-effort scan of the project's transcript dir for
# sidechain JSONLs whose mtime falls in the stage window. Failures are
# isolated — if any of this throws, fall back to "sub": [] + sub_discovery_failed.
try:
    if transcript_path and os.path.isfile(transcript_path):
        proj_dir = os.path.dirname(transcript_path)
        # last_advance_at may have just been overwritten above; recompute from the
        # PRIOR row's completed_at (i.e., second-to-last in d["stages"]).
        prior_row = d["stages"][-2] if len(d["stages"]) >= 2 else None
        prior_ts = prior_row.get("completed_at") if prior_row else None
        def parse_ts(s):
            if not s: return None
            s = s.replace("Z", "+00:00") if s.endswith("Z") else s
            try: return datetime.fromisoformat(s)
            except Exception: return None
        lo = parse_ts(prior_ts)
        hi = datetime.now(timezone.utc)
        own_session = os.path.basename(transcript_path)
        subs = []
        for entry in os.listdir(proj_dir):
            if not entry.endswith(".jsonl"): continue
            if entry == own_session: continue
            full = os.path.join(proj_dir, entry)
            try:
                mtime = datetime.fromtimestamp(os.path.getmtime(full), tz=timezone.utc)
            except Exception:
                continue
            if lo is not None and mtime < lo: continue
            if mtime > hi: continue  # future-dated, skip
            # Aggregate this sidechain's tokens.
            sub_in = sub_out = sub_cc = sub_cr = 0
            sub_last_ctx = 0
            sub_session_id = entry[:-len(".jsonl")]
            sub_started_at = None
            sub_kind = "unknown"
            try:
                with open(full) as sf:
                    for line in sf:
                        line = line.strip()
                        if not line: continue
                        try: rec = json.loads(line)
                        except Exception: continue
                        if rec.get("isSidechain") is True:
                            sub_kind = "subagent"
                        if sub_started_at is None:
                            sub_started_at = rec.get("timestamp")
                        if rec.get("type") != "assistant": continue
                        msg = rec.get("message") or {}
                        usage = msg.get("usage") or {}
                        in_t = int(usage.get("input_tokens") or 0)
                        out_t = int(usage.get("output_tokens") or 0)
                        cc_t = int(usage.get("cache_creation_input_tokens") or 0)
                        cr_t = int(usage.get("cache_read_input_tokens") or 0)
                        sub_in += in_t; sub_out += out_t
                        sub_cc += cc_t; sub_cr += cr_t
                        sub_last_ctx = in_t + cc_t + cr_t
            except Exception:
                continue
            sub_total = sub_in + sub_out + sub_cc + sub_cr
            if sub_total == 0:
                continue
            subs.append({
                "session_id": sub_session_id,
                "kind": sub_kind,
                "started_at": sub_started_at,
                "tokens_total": sub_total,
                "context_size": sub_last_ctx,
            })
        log_record["context"]["sub"] = subs
except Exception:
    log_record["sub_discovery_failed"] = True

with open(log_path, "a") as f:
    f.write(json.dumps(log_record) + "\n")
PYEOF

# Optional one-line confirmation to stderr (visible in chat as a note).
# Use stderr so it doesn't pollute the bash command's stdout for the model.
echo "mo · stage ${stage_label} ✓ recorded" >&2
exit 0
