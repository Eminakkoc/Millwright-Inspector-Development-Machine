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

GITIGNORE = "*\n"


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
        if path.startswith("docs/superpowers/"):
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


# ---- ingest -------------------------------------------------------------------

import hashlib
import textwrap

FIELDS = ("file", "severity", "scope", "quote", "source", "summary", "details")
FIELD_RE = re.compile(r"^- (file|severity|scope|quote|source|summary|details):[ \t]*(.*)$")
QUOTE_PAIRS = {'"': '"', "'": "'", "“": "”", "‘": "’", "`": "`"}


class ParseError(Exception):
    pass


def norm(text):
    return re.sub(r"\s+", " ", text).strip()


def strip_quotes(s):
    s = s.strip()
    if len(s) >= 2 and s[0] in QUOTE_PAIRS and s[-1] == QUOTE_PAIRS[s[0]]:
        return s[1:-1].strip()
    return s


def parse_block(body):
    fields, cur = {}, None
    for line in body.splitlines():
        m = FIELD_RE.match(line)
        if m:
            cur, val = m.group(1), m.group(2)
            fields[cur] = [] if (cur == "details" and val.strip() in ("|", "|-", ">")) else [val]
        elif cur and (line[:1] in (" ", "\t") or not line.strip()):
            fields[cur].append(line)
    out = {}
    for key, vals in fields.items():
        if key == "details":
            out[key] = textwrap.dedent("\n".join(vals)).strip()
        else:
            out[key] = " ".join(v.strip() for v in vals if v.strip())
    return out


def parse_reply(text):
    entry = re.search(r"(?m)^Entry:\s*\S", text)
    result = re.search(r"(?m)^Result:\s*(findings|clean|not-checkable)\s*$", text)
    more = re.search(r"(?m)^More:\s*(yes|no)\s*$", text)
    if not (entry and result and more):
        raise ParseError("reply lacks the Entry/Result/More header")
    blocks = re.split(r"(?m)^### F-\d+\s*$", text)[1:]
    if result.group(1) == "findings" and not blocks:
        raise ParseError("Result: findings without any ### F-n block")
    return result.group(1), more.group(1) == "yes", [parse_block(b) for b in blocks]


def load_ranges(path):
    out = {}
    with open(path) as f:
        for row in f:
            row = row.rstrip("\n")
            if "\t" not in row:
                continue
            p, rng = row.rsplit("\t", 1)
            a, b = rng.split("-")
            out.setdefault(p, []).append((int(a), int(b)))
    return out


def snapshot_lines(snap, rel):
    try:
        data = open(os.path.join(snap, rel), "rb").read()
    except OSError:
        return 0
    if not data:
        return 0
    return data.count(b"\n") + (0 if data.endswith(b"\n") else 1)


def inside(path, boundary, kind):
    p, b = os.path.realpath(path), os.path.realpath(boundary)
    return p == b if kind == "rule" else (p == b or p.startswith(b + os.sep))


def validate(top, snap, kind, boundary, ranges, f):
    """Return (rel_file, kept_lines, quote, source_abs) or None to drop."""
    if any(not f.get(k) for k in FIELDS):
        return None
    if f["severity"] not in ("minor", "major") or f["scope"] not in ("fix", "re-implement"):
        return None
    quote = strip_quotes(f["quote"])
    if not quote:
        return None
    source = f["source"].strip().strip("`")
    source = source if os.path.isabs(source) else os.path.join(top, source)
    if not os.path.isfile(source) or not inside(source, boundary, kind):
        return None
    if norm(quote) not in norm(open(source, encoding="utf-8", errors="replace").read()):
        return None
    m = re.match(r"^(.+?):(\d+(?:\s*,\s*\d+)*)$", f["file"].strip().strip("`").strip())
    if not m:
        return None
    rel = m.group(1)
    rel = rel[2:] if rel.startswith("./") else rel
    if rel not in ranges:
        return None
    n = snapshot_lines(snap, rel)
    keep = []
    for ln in (int(x) for x in re.split(r"\s*,\s*", m.group(2))):
        if 1 <= ln <= n and any(a <= ln <= b for a, b in ranges[rel]) and ln not in keep:
            keep.append(ln)
    if not keep:
        return None
    return rel, keep, quote, source


def family(review_sh, feature, seed):
    out = subprocess.run([review_sh, "find-by-seed-id-family", feature, seed],
                         capture_output=True, text=True, check=True).stdout
    return [r.split("\t") for r in out.splitlines() if r.count("\t") == 2]


def next_seed(seed, rows):
    """None to skip; else the seed-id to write."""
    if any(status in ("open", "wontfix") for _, _, status in rows):
        return None
    if not rows:
        return seed
    top_n = 0
    for _, sid, _ in rows:
        m = re.match(re.escape(seed) + r":r(\d+)$", sid)
        if m:
            top_n = max(top_n, int(m.group(1)))
    return "%s:r%d" % (seed, top_n + 1)


def cmd_ingest(top, state, feature):
    review_sh = os.environ["CVR_REVIEW_SH"]
    meta = dict(l.rstrip("\n").split("=", 1) for l in open(os.path.join(state, "meta")) if "=" in l)
    if meta.get("feature") != feature:
        die("run belongs to %s, not %s" % (meta.get("feature"), feature))
    snap = meta["snapshot"]
    entries = [l.rstrip("\n").split("\t") for l in open(os.path.join(state, "entries.tsv")) if l.strip()]

    # Pass 1 — parse every reply; write nothing on any failure.
    parsed = []
    for idx, name, kind, path, boundary in entries:
        reply = os.path.join(state, "reply-%s.md" % idx)
        try:
            text = open(reply, encoding="utf-8", errors="replace").read()
            result, more, blocks = parse_reply(text)
        except OSError:
            die("%s: no reply saved at %s" % (name, reply))
        except ParseError as e:
            die("%s: %s" % (name, e))
        m = re.search(r"(?m)^Entry:\s*(.*?)\s*$", text)
        got = re.sub(r"\s*\(.*$", "", m.group(1)).strip() if m else ""
        if got != name:
            die("%s: reply is for %s" % (name, got))
        if result != "findings":
            blocks = []
        parsed.append((idx, name, kind, boundary, result, more, blocks))

    # Pass 2 — validate, dedupe, write.
    added, dropped, not_checkable, capped = {}, 0, 0, []
    for idx, name, kind, boundary, result, more, blocks in parsed:
        if result == "not-checkable":
            not_checkable += 1
            continue
        if more:
            capped.append(name)
        ranges = load_ranges(os.path.join(state, "entry-%s.ranges" % idx))
        for f in blocks:
            v = validate(top, snap, kind, boundary, ranges, f)
            if v is None:
                dropped += 1
                continue
            rel, keep, quote, source = v
            digest = hashlib.sha1(norm(quote).encode("utf-8")).hexdigest()[:8]
            seed = next_seed("conventions:%s:%s:%s" % (name, rel, digest),
                             family(review_sh, feature, "conventions:%s:%s:%s" % (name, rel, digest)))
            if seed is None:
                continue
            details = "%s\n\nquote: \"%s\"\nsource: %s\nfile: %s:%s\n" % (
                f["details"], quote, os.path.relpath(source, top), rel, ",".join(map(str, keep)))
            subprocess.run([review_sh, "add", feature, f["severity"], f["scope"],
                            "%s: %s" % (name, f["summary"]),
                            "--source", "conventions-review", "--seed-id", seed],
                           input=details, text=True, check=True, stdout=subprocess.DEVNULL)
            added[name] = added.get(name, 0) + 1

    total = sum(added.values())
    line = "conventions review: %d findings added" % total
    if total:
        line += " (%s)" % ", ".join("%s: %d" % (n, c) for n, c in added.items())
    line += ", %d dropped, %d entries not checkable" % (dropped, not_checkable)
    if capped:
        line += " — %s hit the 10-finding cap; run /mi-conventions-review again after fixing" % ", ".join(capped)
    print(line)


def main(argv):
    if len(argv) < 2:
        die("usage: conventions_review.py prepare|ingest ...")
    if argv[1] == "prepare" and len(argv) == 6:
        cmd_prepare(*argv[2:])
    elif argv[1] == "ingest" and len(argv) == 5:
        cmd_ingest(*argv[2:])
    else:
        die("bad arguments: %s" % " ".join(argv[1:]))


if __name__ == "__main__":
    main(sys.argv)
