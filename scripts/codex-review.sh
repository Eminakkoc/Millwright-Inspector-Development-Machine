#!/usr/bin/env bash
# codex-review.sh — headless codex reviewer transport for the blueprint-review
# sub-agents. Replaces the codex MCP server (`codex mcp-server`), which codex-cli
# removed in 0.154.0 (openai/codex#42993). See CHANGELOG 1.8.0.
#
# Subcommands:
#   open  --effort <low|medium|high>                 # round 1: new read-only session
#   reply --thread <id> [--effort <low|medium|high>] # rounds 2+: resume that session
#   check                                            # exit 0 iff codex exec is usable
#
# `open` and `reply` read the prompt from STDIN and print ONE JSON object to stdout:
#   {"threadId": "<uuid>", "content": "<reviewer's final message>"}
# — the same two fields the codex MCP tools returned, so callers parse `content`
# exactly as before and pass `threadId` back to `reply`.
#
# Exit codes: 0 ok · 1 codex failed (log tail on stderr) · 3 session not found
# (thread expired or unknown — re-open with a full round-1 prompt) · 64 usage ·
# 69 codex CLI missing or lacks `exec`.
#
# Every session runs with sandbox read-only and approval policy never: the
# reviewer can read the workspace but never write to it or prompt for approval.

set -euo pipefail

usage() {
  sed -n '2,19p' "$0"
}

die_usage() { echo "error: $*" >&2; exit 64; }

cmd="${1:-}"
[[ -n "$cmd" ]] || { usage >&2; exit 64; }
shift

require_codex() {
  command -v codex >/dev/null 2>&1 || { echo "error: codex CLI not found on PATH — run /mi-doctor" >&2; exit 69; }
  codex exec --help >/dev/null 2>&1 || { echo "error: installed codex CLI has no 'exec' subcommand — upgrade codex" >&2; exit 69; }
}

effort=""
thread=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --effort)   effort="${2:-}"; shift 2 ;;
    --effort=*) effort="${1#--effort=}"; shift ;;
    --thread)   thread="${2:-}"; shift 2 ;;
    --thread=*) thread="${1#--thread=}"; shift ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done
[[ -z "$effort" || "$effort" =~ ^(low|medium|high)$ ]] || die_usage "--effort must be low|medium|high"

case "$cmd" in
  check)
    require_codex
    exit 0
    ;;
  open)
    [[ -n "$effort" ]] || die_usage "open requires --effort <low|medium|high>"
    ;;
  reply)
    [[ -n "$thread" ]] || die_usage "reply requires --thread <id>"
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac

require_codex

work="$(mktemp -d "${TMPDIR:-/tmp}/mi-codex-review.XXXXXX")"
trap 'rm -rf "$work"' EXIT

cat > "$work/prompt.md"
[[ -s "$work/prompt.md" ]] || die_usage "empty prompt on stdin"

common=(--json --skip-git-repo-check
        -c 'sandbox_mode="read-only"'
        -c 'approval_policy="never"'
        -o "$work/last-message.txt")
[[ -n "$effort" ]] && common+=(-c "model_reasoning_effort=\"$effort\"")

set +e
if [[ "$cmd" == "open" ]]; then
  codex exec "${common[@]}" - < "$work/prompt.md" \
    > "$work/events.jsonl" 2> "$work/stderr.log"
else
  codex exec resume "${common[@]}" "$thread" - < "$work/prompt.md" \
    > "$work/events.jsonl" 2> "$work/stderr.log"
fi
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  if grep -qiE 'no rollout found|session not found|thread not found' "$work/events.jsonl" "$work/stderr.log"; then
    echo "error: session not found for thread_id $thread" >&2
    exit 3
  fi
  echo "error: codex exec failed (exit $rc)" >&2
  tail -n 20 "$work/events.jsonl" "$work/stderr.log" >&2
  exit 1
fi

python3 - "$work/events.jsonl" "$work/last-message.txt" "$thread" <<'PYEOF'
import json, sys

events_path, message_path, fallback_thread = sys.argv[1], sys.argv[2], sys.argv[3]

thread_id = ""
with open(events_path, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("type") == "thread.started" and ev.get("thread_id"):
            thread_id = ev["thread_id"]
            break
thread_id = thread_id or fallback_thread
if not thread_id:
    sys.exit("error: codex emitted no thread.started event")

try:
    with open(message_path, encoding="utf-8") as f:
        content = f.read()
except FileNotFoundError:
    sys.exit("error: codex produced no final message")

json.dump({"threadId": thread_id, "content": content}, sys.stdout)
sys.stdout.write("\n")
PYEOF
