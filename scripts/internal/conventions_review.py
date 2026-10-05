#!/usr/bin/env python3
"""conventions_review.py — logic behind scripts/conventions-review.sh.

Spec: docs/superpowers/specs/2026-10-05-conventions-review-design.md
"""
import os
import re
import shutil
import subprocess
import sys

import yaml

GITIGNORE = "*\n!.gitignore\n"


def die(msg):
    sys.stderr.write("error: %s\n" % msg)
    sys.exit(1)


# ---- rule selection -----------------------------------------------------------

def find_rules(rules_dir):
    """Every *.md under rules_dir at any depth, following symlinks (cycle-safe)."""
    out, seen = [], set()
    for dirpath, dirnames, filenames in os.walk(rules_dir, followlinks=True):
        real = os.path.realpath(dirpath)
        if real in seen:
            dirnames[:] = []
            continue
        seen.add(real)
        dirnames.sort()
        for fn in sorted(filenames):
            if fn.endswith(".md"):
                out.append(os.path.join(dirpath, fn))
    return sorted(out)


def rule_patterns(path):
    """paths: frontmatter as a list of patterns, or None (= applies to all).

    A YAML list or a comma-separated string (Claude Code docs). Missing, empty
    or malformed frontmatter means the rule applies to every file.
    """
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return None
    m = re.match(r"^---\n(.*?)\n---\s*(?:\n|$)", text, re.DOTALL)
    if not m:
        return None
    try:
        fm = yaml.safe_load(m.group(1)) or {}
    except yaml.YAMLError:
        return None
    raw = fm.get("paths") if isinstance(fm, dict) else None
    if isinstance(raw, str):
        items = raw.split(",")
    elif isinstance(raw, list):
        items = [str(x) for x in raw]
    else:
        return None
    pats = [p.strip() for p in items if p and p.strip()]
    return pats or None


def expand_braces(pat):
    m = re.search(r"\{([^{}]*)\}", pat)
    if not m:
        return [pat]
    out = []
    for alt in m.group(1).split(","):
        out.extend(expand_braces(pat[:m.start()] + alt + pat[m.end():]))
    return out


def glob_regex(pat):
    """`*` never crosses `/`; `**` matches zero or more folders."""
    if pat.startswith("./"):
        pat = pat[2:]
    pat = pat.lstrip("/")
    out, i = "", 0
    while i < len(pat):
        if pat.startswith("**/", i):
            out += "(?:.*/)?"
            i += 3
        elif pat.startswith("**", i):
            out += ".*"
            i += 2
        elif pat[i] == "*":
            out += "[^/]*"
            i += 1
        elif pat[i] == "?":
            out += "[^/]"
            i += 1
        else:
            out += re.escape(pat[i])
            i += 1
    return re.compile(out + r"\Z")


def matches(patterns, path):
    return any(glob_regex(p).match(path) for pat in patterns for p in expand_braces(pat))


# ---- prepare ------------------------------------------------------------------

def clean_run_root(root):
    os.makedirs(root, exist_ok=True)
    for name in os.listdir(root):
        if name == ".gitignore":
            continue
        p = os.path.join(root, name)
        if os.path.isdir(p) and not os.path.islink(p):
            shutil.rmtree(p)
        else:
            os.remove(p)
    with open(os.path.join(root, ".gitignore"), "w") as f:
        f.write(GITIGNORE)


def cmd_prepare(top, head, data_root, feature):
    run_root = os.path.join(top, "tmp", "conventions-review")
    clean_run_root(run_root)

    dr = os.path.relpath(os.path.realpath(data_root), os.path.realpath(top))
    inside = not dr.startswith("..")
    ranges = {}
    for row in os.environ.get("CVR_LINES", "").splitlines():
        if "\t" not in row:
            continue
        path, rng = row.rsplit("\t", 1)
        if inside and (dr == "." or path == dr or path.startswith(dr + "/")):
            continue
        ranges.setdefault(path, []).append(rng)
    covered = list(ranges)

    entries = []  # (name, kind, abs path, boundary, files)
    if covered:
        for row in os.environ.get("CVR_SKILLS", "").splitlines():
            if "\t" not in row:
                continue
            name, path = row.split("\t", 1)
            boundary = path if os.path.isdir(path) else os.path.dirname(path)
            entries.append((name, "skill", path, boundary, covered))
        rules_dir = os.path.join(top, ".claude", "rules")
        if os.path.isdir(rules_dir):
            for rule in find_rules(rules_dir):
                pats = rule_patterns(rule)
                files = covered if pats is None else [f for f in covered if matches(pats, f)]
                if files:
                    name = os.path.relpath(rule, rules_dir)[:-3]
                    entries.append((name, "rule", rule, rule, files))

    if not entries:
        print("conventions review: nothing to check")
        return

    snap = os.path.join(run_root, head)
    for f in covered:
        blob = subprocess.check_output(["git", "-C", top, "cat-file", "blob", "%s:%s" % (head, f)])
        dest = os.path.join(snap, f)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as out:
            out.write(blob)

    state = snap + ".state"
    os.makedirs(state)
    with open(os.path.join(state, "entries.tsv"), "w") as tsv:
        for idx, (name, kind, path, boundary, files) in enumerate(entries, 1):
            tsv.write("%d\t%s\t%s\t%s\t%s\n" % (idx, name, kind, path, boundary))
            with open(os.path.join(state, "entry-%d.ranges" % idx), "w") as rf:
                for f in files:
                    for rng in ranges[f]:
                        rf.write("%s\t%s\n" % (f, rng))
    with open(os.path.join(state, "meta"), "w") as meta:
        meta.write("feature=%s\nreview-head=%s\nsnapshot=%s\n" % (feature, head, snap))

    print("conventions review: %d reviewers (%s)" % (len(entries), ", ".join(e[0] for e in entries)))
    print("state: %s" % state)


def main(argv):
    if len(argv) < 2:
        die("usage: conventions_review.py prepare|ingest ...")
    if argv[1] == "prepare" and len(argv) == 6:
        cmd_prepare(*argv[2:])
    elif argv[1] == "ingest" and len(argv) == 5:
        raise SystemExit("ingest: not implemented")
    else:
        die("bad arguments: %s" % " ".join(argv[1:]))


if __name__ == "__main__":
    main(sys.argv)
