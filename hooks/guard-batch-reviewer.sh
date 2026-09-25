#!/usr/bin/env bash
# guard-batch-reviewer.sh — PreToolUse(Bash) hook (v1.8.0).
#
# blueprint-batch-reviewer is structurally read-only. It needs Bash only to reach
# codex through scripts/codex-review.sh, and plugin agents cannot carry their own
# hooks or scoped Bash rules. So this plugin-level hook fires for every Bash call,
# ignores every caller except that agent, and admits exactly one command shape:
#
#   <plugin>/scripts/codex-review.sh open|reply [--effort X] [--thread Y] <<'DELIM'
#   ...prompt body (quoted heredoc — never expanded)...
#   DELIM
#
# Anything else from that agent is blocked (exit 2; stderr goes back to the agent).

set -euo pipefail

input="$(cat)"

python3 - "$input" "${CLAUDE_PLUGIN_ROOT:-}" <<'PYEOF'
import json, os, re, sys

raw, plugin_root = sys.argv[1], sys.argv[2]
try:
    event = json.loads(raw)
except ValueError:
    sys.exit(0)

if not str(event.get("agent_type", "")).endswith("blueprint-batch-reviewer"):
    sys.exit(0)
if event.get("tool_name") != "Bash":
    sys.exit(0)

def deny(why):
    sys.stderr.write(
        "blocked: blueprint-batch-reviewer may only run "
        "`<plugin>/scripts/codex-review.sh open|reply ... <<'DELIM'` with a quoted "
        f"heredoc prompt ({why}).\n"
    )
    sys.exit(2)

command = (event.get("tool_input") or {}).get("command", "")
lines = command.rstrip("\n").split("\n")

head = re.fullmatch(
    r"""\s*(["']?)(?P<path>[^\s"']+)\1"""
    r"""\s+(?:open|reply)"""
    r"""(?:\s+--(?:effort|thread)(?:=|\s+)[A-Za-z0-9._-]+)*"""
    r"""\s+<<-?\s*'(?P<delim>[A-Za-z_][A-Za-z0-9_]*)'\s*""",
    lines[0],
)
if not head:
    deny("first line is not a codex-review.sh open|reply call ending in a quoted heredoc")

path = head.group("path").replace("$CLAUDE_PLUGIN_ROOT", plugin_root).replace("${CLAUDE_PLUGIN_ROOT}", plugin_root)
expected = os.path.join(plugin_root, "scripts", "codex-review.sh") if plugin_root else ""
if not expected or os.path.realpath(path) != os.path.realpath(expected):
    deny(f"script path {path!r} is not this plugin's codex-review.sh")

delim = head.group("delim")
body = lines[1:]
if not body or body[-1].strip() != delim:
    deny("the heredoc delimiter must be the last line")
if any(l.strip() == delim for l in body[:-1]):
    deny("the heredoc delimiter appears inside the prompt body — pick a different delimiter")

sys.exit(0)
PYEOF
