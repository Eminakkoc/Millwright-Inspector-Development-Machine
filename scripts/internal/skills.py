#!/usr/bin/env python3
"""skills.py — the parsing half of scripts/skills.sh (1.11.0).

Called only by skills.sh, which handles argument checks. Every subcommand
prints nothing and exits 0 when nothing matches.

Spec: docs/superpowers/specs/2026-10-04-skills-across-workflow-design.md
"""
import glob
import json
import os
import shutil
import subprocess
import sys

CATALOG_MISSING = "catalog CLI not found — catalog suggestions skipped"
AUTO_START = "<!-- auto:start"
AUTO_END = "<!-- auto:end -->"


# ---------- shared helpers --------------------------------------------------

def repo_root():
    try:
        out = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, check=True)
        return out.stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return os.getcwd()


def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def flat(text, limit=None):
    text = " ".join(str(text).split())
    return text[:limit] if limit else text


def skill_description(skill_md):
    """description: from SKILL.md frontmatter (single line or folded block)."""
    try:
        with open(skill_md) as f:
            lines = f.read().split("\n")
    except OSError:
        return ""
    if not lines or lines[0].strip() != "---":
        return ""
    for i in range(1, len(lines)):
        line = lines[i]
        if line.strip() == "---":
            return ""
        if line.startswith("description:"):
            value = line[len("description:"):].strip()
            if value in ("", "|", ">", "|-", ">-"):
                parts = []
                for nxt in lines[i + 1:]:
                    if nxt.startswith((" ", "\t")):
                        parts.append(nxt.strip())
                    else:
                        break
                value = " ".join(parts)
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            return value
    return ""


def run_catalog(args):
    """Return (ok, parsed-json). ok=None when catalog is not on PATH."""
    if shutil.which("catalog") is None:
        return None, None
    try:
        out = subprocess.run(["catalog"] + args, capture_output=True,
                             text=True, check=True)
        return True, json.loads(out.stdout)
    except (subprocess.CalledProcessError, ValueError):
        return False, None


def catalog_items(data):
    """Accept the flat {name: {...}} map and the .items-wrapped form."""
    if not isinstance(data, dict):
        return {}
    inner = data.get("items")
    if isinstance(inner, dict) and inner and all(
            isinstance(v, dict) and "kind" in v for v in inner.values()):
        return inner
    return {k: v for k, v in data.items() if isinstance(v, dict)}


# ---------- config.md auto block ---------------------------------------------

def auto_block_span(lines):
    start = end = None
    for i, line in enumerate(lines):
        if start is None and line.lstrip().startswith(AUTO_START):
            start = i
        elif start is not None and line.strip() == AUTO_END:
            end = i
            break
    return start, end


def parse_sections(lines, start, end):
    """{heading: [entry, ...]} for the lines strictly between start and end.

    An entry is {name, reason, fields, lines: [i, ...]}. HTML comments are
    skipped, so template placeholders never parse as entries.
    """
    sections, order = {}, []
    current, entry, in_comment = None, None, False
    for i in range(start + 1, end):
        line = lines[i]
        stripped = line.strip()
        if in_comment:
            if "-->" in stripped:
                in_comment = False
            continue
        if stripped.startswith("<!--"):
            in_comment = "-->" not in stripped
            continue
        if line.startswith("## "):
            current = line[3:].strip()
            sections[current] = []
            order.append((current, i))
            entry = None
            continue
        if current is None:
            continue
        if line.startswith("- "):
            head = line[2:]
            name, _, reason = head.partition(" — ")
            entry = {"name": name.strip(), "reason": reason.strip(),
                     "fields": {}, "lines": [i]}
            sections[current].append(entry)
            continue
        if entry is not None and line.startswith("  ") and stripped:
            for part in stripped.split("; "):
                key, sep, value = part.partition(": ")
                if sep:
                    entry["fields"][key.strip()] = value.strip()
            entry["lines"].append(i)
            entry = None
            continue
        if stripped:
            entry = None
    return sections, order


def read_config(path):
    try:
        with open(path) as f:
            text = f.read()
    except OSError:
        return None, None, None, None
    lines = text.split("\n")
    start, end = auto_block_span(lines)
    if start is None or end is None:
        return lines, None, None, None
    sections, order = parse_sections(lines, start, end)
    return lines, (start, end), sections, order


def stage_entries(config, tag):
    _, span, sections, _ = read_config(config)
    if span is None:
        return []
    root = repo_root()
    out = []
    for e in sections.get("Skills", []):
        f = e["fields"]
        stages = [s.strip() for s in f.get("stages", "").split(",")]
        if tag not in stages or not f.get("skill") or not f.get("path"):
            continue
        path = f["path"]
        if not os.path.isabs(path):
            path = os.path.join(root, path)
        out.append((f["skill"], e["reason"], path))
    return out


def cmd_brief(config, tag):
    entries = stage_entries(config, tag)
    if not entries:
        return
    heading = ("## Skills for this work (from config.md)" if tag == "implement"
               else "## Skills for reviewing this work")
    print(heading)
    print()
    print("Load each skill with the `Skill` tool (`Skill <name>`); "
          "if that fails, Read the file at its path.")
    print()
    for name, reason, path in entries:
        print("- %s — %s — %s" % (name, reason, path) if reason
              else "- %s — %s" % (name, path))


def cmd_entries(config, tag):
    for name, _, path in stage_entries(config, tag):
        print("%s\t%s" % (name, path))


def cmd_suggestions(config):
    _, span, sections, _ = read_config(config)
    if span is None:
        return
    for e in sections.get("Catalog suggestions", []):
        f = e["fields"]
        print("\t".join([e["name"], f.get("requested", "no"), f.get("stages", "-"),
                         f.get("install", "catalog add %s" % e["name"]), e["reason"] or "-"]))


def cmd_apply_installs(config, installed, declined, failed, stop):
    lines, span, sections, order = read_config(config)
    if lines is None:
        sys.exit("error: config.md not found: %s" % config)
    if span is None:
        sys.exit("error: no auto block in %s" % config)
    suggestions = sections.get("Catalog suggestions", [])
    skills = sections.get("Skills", [])
    have = {e["fields"].get("skill") or e["name"] for e in skills}

    drop, new_entries = set(), []
    for e in suggestions:
        name, f = e["name"], e["fields"]
        if name in installed:
            drop.update(e["lines"])
            if name not in have:
                stages = f.get("stages", "implement")
                head = "- %s — %s" % (name, e["reason"]) if e["reason"] else "- %s" % name
                new_entries.append([
                    head,
                    "  stages: %s; skill: %s; path: .claude/skills/%s/SKILL.md; "
                    "origin: catalog-installed" % (stages, name, name)])
                have.add(name)
        elif name in declined:
            drop.update(e["lines"])
        elif name in failed:
            if f.get("requested") == "journal" and stop:
                continue
            drop.update(e["lines"])
    if not drop and not new_entries:
        return

    # Insert after the last non-blank line of ## Skills (before its successor).
    skills_at = dict(order).get("Skills")
    if skills_at is None:
        sys.exit("error: auto block has no ## Skills section: %s" % config)
    later = [i for _, i in order if i > skills_at]
    stop_at = later[0] if later else span[1]
    pos = skills_at + 1
    for i in range(skills_at + 1, stop_at):
        if lines[i].strip():
            pos = i + 1
    entry_lines = {i for e in skills for i in e["lines"]}
    insert = []
    if new_entries:
        if (pos - 1) not in entry_lines:
            insert.append("")
        for block in new_entries:
            insert.extend(block)

    out = []
    for i, line in enumerate(lines):
        if i == pos:
            out.extend(insert)
        if i not in drop:
            out.append(line)
    # Deleting entries can leave stacked blank lines; collapse them, but only
    # inside the auto block so the rest of the file stays byte-identical.
    start, end = auto_block_span(out)
    block = []
    for line in out[start:end + 1]:
        if not line.strip() and block and not block[-1].strip():
            continue
        block.append(line)
    out = out[:start] + block + out[end + 1:]
    with open(config, "w") as f:
        f.write("\n".join(out))


# ---------- inventory / lookup / catalog-files ----------------------------

def project_skills(root):
    rows = []
    for md in sorted(glob.glob(os.path.join(root, ".claude", "skills", "*", "SKILL.md"))):
        name = os.path.basename(os.path.dirname(md))
        rows.append((name, "skill", "project", flat(skill_description(md), 200),
                     os.path.relpath(md, root), "-"))
    return rows


def enabled_plugins(root):
    merged = {}
    for path in (os.path.expanduser("~/.claude/settings.json"),
                 os.path.join(root, ".claude", "settings.json"),
                 os.path.join(root, ".claude", "settings.local.json")):
        data = load_json(path)
        if isinstance(data, dict) and isinstance(data.get("enabledPlugins"), dict):
            merged.update(data["enabledPlugins"])
    return [k for k, v in merged.items() if v is True]


def plugin_install_path(key, root):
    data = load_json(os.path.expanduser("~/.claude/plugins/installed_plugins.json"))
    records = ((data or {}).get("plugins") or {}).get(key) or []
    real = os.path.realpath(root)
    for r in records:
        if r.get("projectPath") and os.path.realpath(r["projectPath"]) == real:
            return r.get("installPath")
    for r in records:
        if r.get("scope") == "user":
            return r.get("installPath")
    return None


def plugin_skills(root):
    rows = []
    for key in sorted(enabled_plugins(root)):
        install = plugin_install_path(key, root)
        if not install:
            continue
        plugin = key.split("@", 1)[0]
        for md in sorted(glob.glob(os.path.join(install, "skills", "*", "SKILL.md"))):
            skill = os.path.basename(os.path.dirname(md))
            rows.append(("%s:%s" % (plugin, skill), "skill", "plugin:%s" % plugin,
                         flat(skill_description(md), 200), md, "-"))
    return rows


def lock_items(path):
    data = load_json(path)
    items = (data or {}).get("items") if isinstance(data, dict) else None
    return items if isinstance(items, dict) else {}


def broken_rows(root, known):
    rows = []
    for name, item in sorted(lock_items(os.path.join(root, ".claude", "catalog.lock.json")).items()):
        if item.get("kind") != "skill" or name in known:
            continue
        files = item.get("files") or []
        if files and all(os.path.exists(os.path.join(root, f)) for f in files):
            continue
        rows.append((name, "broken", "catalog",
                     "lock-file entry with missing files — repair: catalog add %s --force" % name,
                     files[0] if files else "-", "-"))
    return rows


def missing_needs(row, cat, root):
    project_lock = lock_items(os.path.join(root, ".claude", "catalog.lock.json"))
    user_lock = lock_items(os.path.expanduser("~/.claude/catalog.lock.json"))
    missing = []
    for req in row.get("requires") or []:
        dep = cat.get(req) or {}
        kind = dep.get("kind")
        if kind == "skill":
            continue
        if kind == "tool":
            if shutil.which(dep.get("bin") or req) is None:
                missing.append(req)
        elif req not in project_lock and req not in user_lock:
            missing.append(req)
    return ",".join(missing) if missing else "-"


def cmd_inventory(installed_only):
    root = repo_root()
    rows = project_skills(root) + plugin_skills(root)
    known = {r[0] for r in rows}
    rows += broken_rows(root, known)
    known = {r[0] for r in rows}
    if not installed_only:
        ok, data = run_catalog(["list", "--json"])
        if ok is None:
            print(CATALOG_MISSING, file=sys.stderr)
        elif ok:
            cat = catalog_items(data)
            for name in sorted(cat):
                row = cat[name]
                if row.get("kind") != "skill" or row.get("scope") != "project" or name in known:
                    continue
                rows.append((name, "catalog-skill", "catalog",
                             flat(row.get("description", ""), 200), "-",
                             missing_needs(row, cat, root)))
    for r in rows:
        print("\t".join(r))


def cmd_lookup(names):
    ok, data = run_catalog(["list", "--json"])
    if ok is None:
        print(CATALOG_MISSING, file=sys.stderr)
    cat = catalog_items(data) if ok else {}
    bundles = None
    for arg in names:
        if arg.startswith("bundle:"):
            if bundles is None:
                b_ok, b_data = run_catalog(["list", "--json", "--bundles"]) if ok else (False, None)
                bundles = b_data if b_ok and isinstance(b_data, dict) else {}
            bname = arg[len("bundle:"):]
            bundle = bundles.get(bname)
            if not isinstance(bundle, dict):
                print("%s\tunknown\t-\t-" % arg)
                continue
            for item in bundle.get("items") or []:
                row = cat.get(item)
                if row:
                    print("%s\t%s\t%s\t%s" % (item, row.get("kind", "-"), row.get("scope", "-"), bname))
                else:
                    print("%s\tunknown\t-\t%s" % (item, bname))
            continue
        row = cat.get(arg)
        if row:
            print("%s\t%s\t%s\t-" % (arg, row.get("kind", "-"), row.get("scope", "-")))
        else:
            print("%s\tunknown\t-\t-" % arg)


def cmd_catalog_files():
    root = repo_root()
    lock_rel = os.path.join(".claude", "catalog.lock.json")
    if not os.path.exists(os.path.join(root, lock_rel)):
        return
    try:
        out = subprocess.run(["git", "-C", root, "status", "--porcelain",
                              "--untracked-files=all", "--", ".claude"],
                             capture_output=True, text=True, check=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return
    changed = []
    for line in out.split("\n"):
        if len(line) < 4:
            continue
        path = line[3:]
        if " -> " in path:
            path = path.split(" -> ", 1)[1]
        changed.append(path.strip('"'))
    prefixes = []
    for item in lock_items(os.path.join(root, lock_rel)).values():
        if item.get("kind") == "skill":
            prefixes.extend(f.rstrip("/") for f in item.get("files") or [])
    picked = set()
    for path in changed:
        if path == lock_rel or any(path == p or path.startswith(p + "/") for p in prefixes):
            picked.add(path)
    for path in sorted(picked):
        print(path)


def main(argv):
    cmd = argv[0]
    if cmd == "inventory":
        cmd_inventory("--installed" in argv[1:])
    elif cmd == "lookup":
        cmd_lookup(argv[1:])
    elif cmd == "brief":
        cmd_brief(argv[1], argv[2])
    elif cmd == "entries":
        cmd_entries(argv[1], argv[2])
    elif cmd == "suggestions":
        cmd_suggestions(argv[1])
    elif cmd == "catalog-files":
        cmd_catalog_files()
    elif cmd == "apply-installs":
        config, installed, declined, failed, stop = argv[1], set(), set(), set(), False
        rest = argv[2:]
        i = 0
        while i < len(rest):
            opt = rest[i]
            if opt == "--stop":
                stop = True
                i += 1
                continue
            vals = {v for v in (rest[i + 1] if i + 1 < len(rest) else "").split(",") if v}
            {"--installed": installed, "--declined": declined, "--failed": failed}[opt].update(vals)
            i += 2
        cmd_apply_installs(config, installed, declined, failed, stop)


if __name__ == "__main__":
    main(sys.argv[1:])
