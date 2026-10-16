"""Batch-reviewer command guard — the Python half of guard-batch-reviewer.sh.

Reads the PreToolUse(Bash) hook event as JSON on stdin (never as one command-line
argument: Windows caps a command line at 32,767 characters, and the batch
reviewer's own heredoc prompts exceed that). argv[1] is this hook's plugin root.

Exit 0 allows the command; exit 2 blocks it, with the reason on stderr. See
guard-batch-reviewer.sh for the one command shape blueprint-batch-reviewer may run.
"""
import json
import os
import re
import sys

raw = sys.stdin.read()
plugin_root = sys.argv[1] if len(sys.argv) > 1 else ""
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


def win_path(p):
    # Git Bash spells C:/x as /c/x, which Windows Python does not treat as
    # absolute (os.path.isabs is False for it from Python 3.13). Other systems
    # keep the path as is: there /c/x is a real path.
    if os.name == "nt":
        m = re.match(r"^/([A-Za-z])(/.*)?$", p)
        if m:
            return m.group(1).upper() + ":" + (m.group(2) or "/")
    return p


command = (event.get("tool_input") or {}).get("command", "")
lines = command.rstrip("\n").split("\n")

# The wrapper path is bare, or quoted (then it may contain spaces).
head = re.fullmatch(
    r"""\s*(?:"(?P<dq>[^"]+)"|'(?P<sq>[^']+)'|(?P<bare>[^\s"']+))"""
    r"""\s+(?:open|reply)"""
    r"""(?:\s+--(?:backend|effort|thread)(?:=|\s+)[A-Za-z0-9._-]+)*"""
    r"""\s+<<-?\s*'(?P<delim>[A-Za-z_][A-Za-z0-9_]*)'\s*""",
    lines[0],
)
if not head:
    deny("first line is not a codex-review.sh open|reply call ending in a quoted heredoc")

PLUGIN_NAME = "millwright-inspector-development-machine"


def is_plugin_wrapper(p):
    # The hook runs from the installed plugin, but the orchestrator may have
    # resolved the plugin root to a source checkout (§8.14 step 2) and handed the
    # reviewer that copy's wrapper. Accept codex-review.sh from any real install
    # of this plugin: <root>/scripts/codex-review.sh where <root>'s plugin.json
    # names this plugin. The reviewer cannot create files, so it cannot fake one.
    real = os.path.realpath(p)
    scripts_dir = os.path.dirname(real)
    if os.path.basename(real) != "codex-review.sh" or os.path.basename(scripts_dir) != "scripts":
        return False
    if not os.path.isfile(real):
        return False
    manifest = os.path.join(os.path.dirname(scripts_dir), ".claude-plugin", "plugin.json")
    try:
        with open(manifest, encoding="utf-8") as fh:
            return json.load(fh).get("name") == PLUGIN_NAME
    except (OSError, ValueError, AttributeError):
        return False


plugin_root = win_path(plugin_root)
path = head.group("dq") or head.group("sq") or head.group("bare")
path = path.replace("${CLAUDE_PLUGIN_ROOT}", plugin_root).replace("$CLAUDE_PLUGIN_ROOT", plugin_root)
path = win_path(path)
if "$" in path or not os.path.isabs(path):
    deny(f"script path {path!r} must be absolute")
expected = os.path.join(plugin_root, "scripts", "codex-review.sh") if plugin_root else ""
if not (expected and os.path.realpath(path) == os.path.realpath(expected)) and not is_plugin_wrapper(path):
    deny(f"script path {path!r} is not this plugin's codex-review.sh")

delim = head.group("delim")
body = lines[1:]
if not body or body[-1].strip() != delim:
    deny("the heredoc delimiter must be the last line")
if any(l.strip() == delim for l in body[:-1]):
    deny("the heredoc delimiter appears inside the prompt body — pick a different delimiter")

sys.exit(0)
