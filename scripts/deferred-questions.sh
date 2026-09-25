#!/usr/bin/env bash
# deferred-questions.sh — manage implementation/deferred-questions.md (1.9.0).
#
# Usage:
#   deferred-questions.sh path <feature>
#   deferred-questions.sh init <feature>
#   deferred-questions.sh add <feature> <question> <assumed>        # prints DQ-NNN
#   deferred-questions.sh answer <feature> <DQ-NNN> <answer> [--needs-finding]
#   deferred-questions.sh list-open <feature>                       # TSV: id, question
#   deferred-questions.sh list-needs-finding <feature>              # TSV: id, question, answer
#   deferred-questions.sh set-follow-up <feature> <DQ-NNN> <IR-NNN>
#
# Values are flattened to a single line. Entries are `## DQ-NNN` headings with
# digits; the template's example uses `DQ-NNN` inside an HTML comment, so the
# parser (which requires \d{3}) never counts it.

set -euo pipefail
source "$(dirname "$0")/internal/common.sh"

dq_file() { echo "$(mi_impl_dir "${1:?feature required}")/deferred-questions.md"; }

dq_init() {
  local f; f="$(dq_file "$1")"
  if [[ ! -f "$f" ]]; then
    mkdir -p "$(dirname "$f")"
    "${MI_PLUGIN_ROOT}/scripts/frontmatter.sh" init deferred-questions "$f" "FEATURE=$1" >/dev/null 2>&1 \
      || mi_die "could not render $f"
  fi
  printf '%s' "$f"
}

# dq_py <file> <op> [args...] — all parsing/mutation in one place.
dq_py() {
  python3 - "$@" <<'PYEOF'
import re, sys
path, op, *args = sys.argv[1:]
content = open(path).read()
ENTRY = re.compile(r'(?ms)^## (DQ-\d{3})[ \t]*\n(.*?)(?=^## |\Z)')
def one(s): return ' '.join(str(s).split())
def fields(body):
    return {k: v.strip() for k, v in re.findall(r'(?m)^- ([a-z-]+):[ \t]*(.*)$', body)}
entries = [(m, fields(m.group(2))) for m in ENTRY.finditer(content)]
def set_fields(dq, updates):
    global content
    for m, f in entries:
        if m.group(1) == dq:
            body = m.group(2)
            for k, v in updates.items():
                body = re.sub(rf'(?m)^- {k}:.*$', lambda _: f'- {k}: {v}'.rstrip(), body)
            content = content[:m.start(2)] + body + content[m.end(2):]
            open(path, 'w').write(content)
            return
    sys.stderr.write(f"error: {dq} not found\n"); sys.exit(1)
if op == 'add':
    q, a = one(args[0]), one(args[1])
    n = max([int(m.group(1)[3:]) for m, _ in entries] or [0]) + 1
    dq = f"DQ-{n:03d}"
    block = (f"\n## {dq}\n- question: {q}\n- assumed: {a}\n- status: open\n"
             f"- answer:\n- needs-finding: false\n- follow-up:\n")
    open(path, 'w').write(content.rstrip('\n') + '\n' + block)
    print(dq)
elif op == 'answer':
    dq, ans, nf = args[0], one(args[1]), args[2]
    set_fields(dq, {'status': 'answered', 'answer': ans, 'needs-finding': nf})
elif op == 'set-follow-up':
    set_fields(args[0], {'follow-up': args[1]})
elif op == 'list-open':
    for m, f in entries:
        if f.get('status') == 'open':
            print(f"{m.group(1)}\t{f.get('question','')}")
elif op == 'list-needs-finding':
    for m, f in entries:
        if f.get('needs-finding') == 'true' and not f.get('follow-up'):
            print(f"{m.group(1)}\t{f.get('question','')}\t{f.get('answer','')}")
PYEOF
}

cmd="${1:-}"; shift || true
case "$cmd" in
  path) dq_file "${1:?feature required}" ;;
  init) dq_init "${1:?feature required}"; echo ;;
  add)
    f="$(dq_init "${1:?feature required}")"
    dq_py "$f" add "${2:?question required}" "${3:?assumed required}"
    ;;
  answer)
    feature="${1:?feature required}"; dq="${2:?DQ id required}"; ans="${3:?answer required}"
    nf=false; [[ "${4:-}" == "--needs-finding" ]] && nf=true
    f="$(dq_file "$feature")"; [[ -f "$f" ]] || mi_die "no deferred questions for $feature"
    dq_py "$f" answer "$dq" "$ans" "$nf"
    ;;
  set-follow-up)
    f="$(dq_file "${1:?feature required}")"; [[ -f "$f" ]] || mi_die "no deferred questions for $1"
    dq_py "$f" set-follow-up "${2:?DQ id required}" "${3:?IR id required}"
    ;;
  list-open|list-needs-finding)
    f="$(dq_file "${1:?feature required}")"
    [[ -f "$f" ]] || exit 0
    dq_py "$f" "$cmd"
    ;;
  *)
    echo "usage: deferred-questions.sh {path|init|add|answer|list-open|list-needs-finding|set-follow-up} ..." >&2
    exit 2
    ;;
esac
