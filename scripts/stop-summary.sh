#!/usr/bin/env bash
# stop-summary.sh — the one-sentence summary, in numbers, that ends the two
# stops every feature makes (1.15.0): the stage-2 blueprint stop and the
# stage-5 inspector review stop. Printed in auto and manual mode alike, as
# the stop message's last line.
#
# Usage:
#   stop-summary.sh blueprint   # requirements reviewed, findings fixed / open,
#                               # scope proposals declined, skills waiting
#   stop-summary.sh review      # commits, test verdicts, findings waiting /
#                               # fixed, deferred questions and deferred tests
#
# Prints one `**Summary:** …` line for the active feature, or nothing when no
# feature is active (and for `blueprint` on the cycle's feature-test entry,
# which has no blueprint). Read-only. Exits 0 whatever it finds: a missing or
# unreadable file only drops its clause, so the summary never blocks a stop.
#
# Sources: progress.md and todo-list.md (stage, position in the queue);
# requirements.md's inline REVIEW-FINDING blocks and review-history.md
# (`last-review-items` / `last-review-fixed`, written by persist-findings, and
# `last-status: deferred` sections); skills.sh suggestions; inspector-review.md;
# deferred-questions.md; manual-test-results.md (this activation's only);
# deferred-tests.sh unresolved; `git rev-list --count base-commit..HEAD`.

set -uo pipefail
source "$(dirname "$0")/internal/common.sh"

kind="${1:-}"
[[ "$kind" == blueprint || "$kind" == review ]] || {
  echo "usage: stop-summary.sh {blueprint|review}" >&2
  exit 2
}
S="$MI_PLUGIN_ROOT/scripts"

feature="$("$S/progress.sh" get-active 2>/dev/null)" || exit 0
[[ -n "$feature" && "$feature" != null ]] || exit 0
progress="$(mi_progress_file 2>/dev/null)" || exit 0
todo="$(dirname "$progress")/todo-list.md"

skills="" commits="" unresolved_tests=0
if [[ "$kind" == blueprint ]]; then
  skills="$("$S/skills.sh" suggestions "$feature" 2>/dev/null || true)"
else
  base="$("$S/progress.sh" get base-commit 2>/dev/null || true)"
  [[ -n "$base" && "$base" != null ]] && commits="$(git rev-list --count "$base..HEAD" 2>/dev/null || true)"
  results="$("$S/blueprints.sh" manual-test-results-path "$feature" 2>/dev/null || true)"
  if "$S/todo.sh" is-feature-test "$feature" >/dev/null 2>&1; then
    unresolved_tests="$("$S/deferred-tests.sh" unresolved "$feature" "$results" 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
  fi
fi

mi_py - "$kind" "$feature" "$progress" "$todo" "$(mi_blueprints_current "$feature")" \
  "$(mi_impl_dir "$feature")" "${results:-}" "$skills" "$commits" "${unresolved_tests:-0}" <<'PYEOF' || true
import os, re, sys
import yaml

(kind, feature, progress_path, todo_path, current_dir, impl_dir, results_path,
 skills, commits, unresolved_tests) = sys.argv[1:11]

def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except (OSError, TypeError):
        return ""

def frontmatter(text):
    m = re.match(r"^---\s*\n(.*?)\n---\s*(?:\n|$)", text, re.DOTALL)
    if not m:
        return {}
    try:
        fm = yaml.safe_load(m.group(1))
    except yaml.YAMLError:
        return {}
    return fm if isinstance(fm, dict) else {}

def count(n, word, plural=None):
    return f"{n} {word if n == 1 else (plural or word + 's')}"

def join(clauses):
    if len(clauses) == 1:
        return clauses[0]
    return ", ".join(clauses[:-1]) + ", and " + clauses[-1]

progress = frontmatter(read(progress_path))
active = progress.get("active") or {}
ft_name = frontmatter(read(todo_path)).get("feature-test")
is_ft = bool(ft_name) and feature == ft_name
if kind == "blueprint" and is_ft:
    sys.exit(0)

done = [f for f in (progress.get("completed") or []) if f != ft_name]
left = [f for f in (progress.get("queue") or []) if f != ft_name]
if is_ft:
    where = f"the whole-cycle test after {count(len(done), 'finished feature')}"
else:
    where = f"feature {len(done) + 1} of {len(done) + 1 + len(left)}"

SEVERITIES = ("blocker", "critical", "high", "medium", "low")

def blueprint():
    req = read(os.path.join(current_dir, "requirements.md"))
    history_text = read(os.path.join(current_dir, "review-history.md"))
    history = frontmatter(history_text)
    declined = set()
    for m in re.finditer(r"(?ms)^## (F-\d+)\s*\n(.*?)(?=^## |\Z)", history_text):
        if re.search(r"(?m)^- last-status:\s*deferred\s*$", m.group(2)):
            declined.add(m.group(1))
    # Inline blocks stay in requirements.md whether open, kept or declined at
    # the scope gate; the declined ones are decided, so they are not open.
    open_by = {}
    for m in re.finditer(r"<!--\s*REVIEW-FINDING\s*(.*?)\s*-->", req, re.DOTALL):
        fid = re.search(r"(?m)^\s*id:\s*(\S+)", m.group(1))
        if fid and fid.group(1) in declined:
            continue
        sev = re.search(r"(?m)^\s*severity:\s*(\S+)", m.group(1))
        sev = sev.group(1) if sev else "unrated"
        open_by[sev] = open_by.get(sev, 0) + 1
    n_open = sum(open_by.values())

    clauses = []
    items, fixed = history.get("last-review-items"), history.get("last-review-fixed")
    if isinstance(items, int) and isinstance(fixed, int):
        clauses.append(f"the review checked {count(items, 'requirement')} and fixed {count(fixed, 'finding')}")
    elif not history.get("finding-count-total"):
        clauses.append("no blueprint review is recorded")
    if n_open:
        order = [s for s in SEVERITIES if s in open_by] + sorted(s for s in open_by if s not in SEVERITIES)
        breakdown = ", ".join(f"{open_by[s]} {s}" for s in order)
        clauses.append(f"{count(n_open, 'finding')} {'is' if n_open == 1 else 'are'} still open ({breakdown})")
    else:
        clauses.append("0 findings are open")
    if declined:
        n = len(declined)
        clauses.append(f"{count(n, 'scope proposal')} {'was' if n == 1 else 'were'} declined")
    waiting = sum(1 for row in skills.splitlines() if row.split("\t")[1:2] == ["no"])
    if waiting:
        clauses.append(f"{count(waiting, 'suggested skill')} {'is' if waiting == 1 else 'are'} waiting for your OK")
    if not n_open and not waiting:
        clauses.append("nothing needs your decision")
    return f"Stage 2 of 8 (blueprint) for `{feature}`, {where}: {join(clauses)}."

SOURCES = (("manual-test", "from a failed test", "from the failed tests"),
           ("conventions-review", "from the conventions review", "from the conventions review"),
           ("deferred-question", "from a deferred question", "from deferred questions"))

def review():
    clauses = []
    if commits.isdigit():
        clauses.append(count(int(commits), "commit"))

    results = frontmatter(read(results_path)) if results_path else {}
    failed = 0
    if (results.get("state") == "complete" and results.get("generated-in-activation")
            and results.get("generated-in-activation") == active.get("activation-id")):
        total = results.get("total") or 0
        passed, failed = results.get("passed") or 0, results.get("failed") or 0
        skipped, deferred = results.get("skipped") or 0, results.get("deferred") or 0
        if passed == total:
            clauses.append(f"{passed} of {count(total, 'test scenario')} passed")
        else:
            parts = [f"{passed} passed"] + [f"{n} {label}" for n, label in (
                (failed, "failed"), (skipped, "skipped"),
                (deferred, "deferred to the whole-cycle test")) if n]
            clauses.append(f"{count(total, 'test scenario')} run ({', '.join(parts)})")
    elif active.get("manual-test-state") == "skipped":
        clauses.append("manual testing skipped")
    else:
        clauses.append("no manual test run yet")

    findings = {"open": [], "fixed": 0, "wontfix": 0}
    for m in re.finditer(r"(?ms)^### (IR-\d{3}) —.*?(?=^### |^## |\Z)", read(os.path.join(impl_dir, "inspector-review.md"))):
        status = re.search(r"(?m)^- status:\s*(\S+)", m.group(0))
        source = re.search(r"(?m)^- source:\s*(\S+)", m.group(0))
        status = status.group(1) if status else "open"
        if status == "open":
            findings["open"].append(source.group(1) if source else "")
        elif status in ("fixed", "wontfix"):
            findings[status] += 1
    n_open = len(findings["open"])

    dq = []
    for m in re.finditer(r"(?ms)^## DQ-\d{3}[ \t]*\n(.*?)(?=^## |\Z)",
                         read(os.path.join(impl_dir, "deferred-questions.md"))):
        status = re.search(r"(?m)^- status:[ \t]*(\S+)", m.group(1))
        dq.append(status.group(1) if status else "open")
    dq_open = dq.count("open")
    tests_left = int(unresolved_tests) if unresolved_tests.isdigit() else 0

    if not (n_open or dq_open or tests_left or failed):
        if dq:
            clauses.append(f"{len(dq) - dq_open} of {count(len(dq), 'deferred question')} answered")
        done_what = "the whole-cycle test" if is_ft else "the feature"
        clauses.append(f"0 findings are open, so an empty review completes {done_what}")
        return f"Stage 5 of 8 (inspector review) for `{feature}`, {where}: {join(clauses)}."

    if n_open:
        parts = []
        for source, one, many in SOURCES:
            n = findings["open"].count(source)
            if n:
                parts.append(f"{n} {one if n == 1 else many}")
        n_you = sum(1 for s in findings["open"] if s not in [x[0] for x in SOURCES])
        if n_you:
            parts.append(f"{n_you} written by you")
        clauses.append(f"{count(n_open, 'finding')} waiting ({', '.join(parts)})")
    else:
        clauses.append("0 findings open")
    if n_open or findings["fixed"]:
        clauses.append(f"{findings['fixed']} fixed so far")
    if findings["wontfix"]:
        clauses.append(f"{findings['wontfix']} marked won't fix")
    if dq:
        if dq_open:
            clauses.append(f"{dq_open} of {count(len(dq), 'deferred question')} still open")
        else:
            clauses.append(f"{len(dq)} of {count(len(dq), 'deferred question')} answered")
    if tests_left:
        clauses.append(f"{count(tests_left, 'deferred test scenario')} from earlier features still "
                       f"{'needs' if tests_left == 1 else 'need'} a verdict")
    return f"Stage 5 of 8 (inspector review) for `{feature}`, {where}: {join(clauses)}."

try:
    print("**Summary:** " + (blueprint() if kind == "blueprint" else review()))
except Exception as e:  # a summary must never break the stop it ends
    sys.stderr.write(f"stop-summary: no summary ({type(e).__name__}: {e})\n")
PYEOF
exit 0
