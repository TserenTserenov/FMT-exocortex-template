#!/bin/bash
# WP-529 Ф245 step 1: every command in update.sh that writes, moves, deletes or
# changes permissions (or runs an outside script that does) must belong to a
# block that setup/update-write-sites.tsv classifies. The registry is what the
# future rollback plan and executor are built from; a write nobody classified
# is a write the rollback cannot undo.
#
# Blocks are keyed by enclosing function (fn:NAME) or by the "Step N" header
# at the top level (top:Step N), so the registry survives edits that only shift
# line numbers. Usage: test-update-write-sites.sh [--list]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATE_SH="${UPDATE_SH:-$SCRIPT_DIR/update.sh}"
REGISTRY="${WRITE_SITES_REGISTRY:-$SCRIPT_DIR/setup/update-write-sites.tsv}"

PY=$(command -v python3 || command -v python || true)
if [ -z "$PY" ]; then
    echo "SKIP: python is required to scan update.sh"
    exit 0
fi

SCAN=$(mktemp)
NEG_DIR=$(mktemp -d)
trap 'rm -f "$SCAN"; rm -rf "$NEG_DIR"' EXIT
cat > "$SCAN" <<'PYEOF'
import collections
import re
import sys

update_path, registry_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(update_path, encoding="utf-8").read().split("\n")

FUNC = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{")
STEP = re.compile(r"^#\s*(?:===\s*)?Step\s+([0-9]+[a-z]?)\b")
# Commands that change files. Run on the line with quoted text blanked out, so a
# word inside an echo message is not mistaken for a command.
WRITE = re.compile(
    r"(?<![\w./-])(?:cp|mv|rm|rmdir|mkdir|chmod|ln|tee|touch|install)\s"
    r"|(?<![0-9&>])>>?\s*[\"$./~]"
    r"|:\s*>\s*[\"$]"
    r"|sed\s+-i|perl\s+-i|launchctl|crontab|systemctl"
    r"|git\s+(?:-C\s+\S+\s+)?(?:config|merge|reset|checkout)"
    r"|open\([^)]*,\s*['\"][wa]")
# Outside scripts and tools update.sh runs; they write on their own.
OUTSIDE = re.compile(
    r"(?:\bbash|\bpython3?|\"\$\w*python\w*\"|\"\$applier\")\s+\"[^\"]*\.(?:sh|py)\""
    r"|\bbash\s+\"\$\w+\""
    r"|\"\$SCRIPT_DIR/roles/\$role/install\.sh\"")


def block_of(lines):
    fn, step, out = None, "preamble", []
    for i, line in enumerate(lines, 1):
        m = FUNC.match(line)
        if m:
            fn = m.group(1)
        elif line.startswith("}"):
            fn = None
        s = STEP.match(line)
        if s and fn is None:
            step = "Step " + s.group(1)
        if re.match(r"\s*#", line):
            continue
        if re.match(r"\s*(?:echo|printf)\b", line) and not re.search(r">>?\s*[\"$]", line):
            continue
        blanked = re.sub(r"\"[^\"]*\"|'[^']*'", '""', line)
        blanked = re.sub(r"2>\s*&1|2>\s*/dev/null|>\s*/dev/null|>&\d|<<-?\s*'?\w+'?", "", blanked)
        if WRITE.search(blanked) or OUTSIDE.search(line):
            out.append((("fn:" + fn) if fn else ("top:" + step), i))
    return out


hits = collections.OrderedDict()
for key, lineno in block_of(src):
    hits.setdefault(key, []).append(lineno)

if mode == "--list":
    for key, nums in hits.items():
        print("%s\t%d\t%d-%d" % (key, len(nums), nums[0], nums[-1]))
    sys.exit(0)

VALID_CLASSES = {"A", "B", "C", "H", "R", "T"}
registry = {}
bad = []
for n, raw in enumerate(open(registry_path, encoding="utf-8").read().split("\n"), 1):
    if not raw.strip() or raw.startswith("#"):
        continue
    cols = raw.split("\t")
    if len(cols) != 4 or cols[1] not in VALID_CLASSES or not cols[2].strip() or not cols[3].strip():
        bad.append("registry line %d malformed: %r" % (n, raw[:60]))
        continue
    if cols[0] in registry:
        bad.append("registry line %d duplicates block %s" % (n, cols[0]))
    registry[cols[0]] = cols

missing = sorted(set(hits) - set(registry))
stale = sorted(set(registry) - set(hits))
for key in missing:
    bad.append("unclassified write block %s (lines %s)" % (key, ",".join(map(str, hits[key][:6]))))
for key in stale:
    bad.append("registry block %s has no write commands in update.sh any more" % key)

if bad:
    print("FAIL: %d problem(s)" % len(bad))
    for line in bad:
        print("  - " + line)
    sys.exit(1)
by_class = collections.Counter(registry[k][1] for k in registry)
print("PASS: %d blocks, %d write commands, all classified (%s)" % (
    len(hits), sum(len(v) for v in hits.values()),
    ", ".join("%s=%d" % (c, by_class[c]) for c in sorted(by_class))))
PYEOF

"$PY" -I "$SCAN" "$UPDATE_SH" "$REGISTRY" "${1:-}"
rc=$?
if [ "$rc" -ne 0 ] || [ "${1:-}" = "--list" ]; then
    exit "$rc"
fi

# The check must also fail when it should: a write block nobody classified, and
# a registry row for a block that no longer exists.
fail=0
grep -v '^fn:repair_pass' "$REGISTRY" > "$NEG_DIR/missing.tsv"
if out=$("$PY" -I "$SCAN" "$UPDATE_SH" "$NEG_DIR/missing.tsv" "" 2>&1); then
    echo "FAIL: dropping fn:repair_pass from the registry was not detected"; fail=1
elif ! printf '%s' "$out" | grep -q 'unclassified write block fn:repair_pass'; then
    echo "FAIL: missing-row case failed for another reason: $out"; fail=1
fi
{ cat "$REGISTRY"; printf 'fn:no_such_block\tA\tplan\tstale row\n'; } > "$NEG_DIR/stale.tsv"
if out=$("$PY" -I "$SCAN" "$UPDATE_SH" "$NEG_DIR/stale.tsv" "" 2>&1); then
    echo "FAIL: a stale registry row was not detected"; fail=1
elif ! printf '%s' "$out" | grep -q 'fn:no_such_block has no write commands'; then
    echo "FAIL: stale-row case failed for another reason: $out"; fail=1
fi
cp "$UPDATE_SH" "$NEG_DIR/update.sh"
# shellcheck disable=SC2016  # the sample function body must stay literal
printf '\nnew_unclassified_writer() {\n    cp "$1" "$2"\n}\n' >> "$NEG_DIR/update.sh"
if out=$("$PY" -I "$SCAN" "$NEG_DIR/update.sh" "$REGISTRY" "" 2>&1); then
    echo "FAIL: a new function with cp was not detected"; fail=1
elif ! printf '%s' "$out" | grep -q 'unclassified write block fn:new_unclassified_writer'; then
    echo "FAIL: new-function case failed for another reason: $out"; fail=1
fi
[ "$fail" -eq 0 ] && echo "PASS: negative cases detected (missing row, stale row, new unclassified function)"
exit "$fail"
