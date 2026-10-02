#!/usr/bin/env bash
# Regression coverage for issue #882: memory/MEMORY.md told every agent to
# offer only solutions scoring ">=8" on a six-characteristic ЭМОГСС scale,
# while CLAUDE.md §5 and the archgate skill (v3.1) use seven characteristics
# (ЭМОГССБ) and a conjunctive veto filter with no aggregate score. Both files
# load into every session, so the agent had to pick a rule. The same retired
# scale also survived in checklists.md, protocol-work.md, sota-reference.md,
# ONTOLOGY.md, LEARNING-PATH.md and USE-CASES.md.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

# Retired scale markers anywhere in the shipped tree: the aggregate threshold,
# a numeric ">=8" next to ArchGate/АрхГейт/ЭМОГСС, and the six-letter acronym
# (ЭМОГСС not followed by the seventh letter Б). CHANGELOG.md and docs/adr/
# keep historical scores on purpose; this test file names the markers itself.
retired=$(grep -rInE \
    -e '56/70' \
    -e '([Пп]орог|АрхГейт|ArchGate|ЭМОГССБ|ЭМОГСС)[^.]{0,25}(≥|>=) ?8([^0-9.%]|\.([^0-9]|$)|$)' \
    -e '(≥|>=) ?8([^0-9.%]|\.([^0-9]|$)|$)[^.]{0,20}(АрхГейт|ArchGate|ЭМОГСС)' \
    -e 'ЭМОГСС([^Б]|$)' \
    --exclude-dir=.git --exclude-dir=adr --exclude=CHANGELOG.md \
    --exclude=test_issue_882_archgate_scale.sh \
    "$ROOT" 2>/dev/null || true)
if [ -z "$retired" ]; then
    pass "no retired ArchGate scale (56/70, '>=8', six-letter ЭМОГСС) left in the shipped tree"
else
    fail_test "retired ArchGate scale still present:"
    printf '%s\n' "$retired" | sed "s#$ROOT/##" | sed 's/^/      /' >&2
fi

memory_rule=$(grep -m1 '^3\. \*\*ArchGate' "$ROOT/memory/MEMORY.md" 2>/dev/null || true)
if [ -z "$memory_rule" ]; then
    fail_test "memory/MEMORY.md has no '3. **ArchGate' blocking rule"
else
    if printf '%s\n' "$memory_rule" | grep -q 'ЭМОГССБ' \
        && printf '%s\n' "$memory_rule" | grep -q '/archgate' \
        && printf '%s\n' "$memory_rule" | grep -q 'без агрегатного балла'; then
        pass "MEMORY.md ArchGate rule points at /archgate, seven characteristics (ЭМОГССБ), no aggregate score"
    else
        fail_test "MEMORY.md ArchGate rule does not name /archgate, ЭМОГССБ and 'без агрегатного балла': $memory_rule"
    fi
    if printf '%s\n' "$memory_rule" | grep -q '≥'; then
        fail_test "MEMORY.md ArchGate rule reintroduces a numeric threshold: $memory_rule"
    else
        pass "MEMORY.md ArchGate rule has no numeric threshold (matches CLAUDE.md §5)"
    fi
fi

checklist_rule=$(grep -m1 'Никогда не предлагай тактические заплатки' "$ROOT/memory/checklists.md" 2>/dev/null || true)
if [ -n "$checklist_rule" ] && printf '%s\n' "$checklist_rule" | grep -q '/archgate' && ! printf '%s\n' "$checklist_rule" | grep -q '≥'; then
    pass "checklists.md stop rule defers to the /archgate verdict, no count of weak characteristics"
else
    fail_test "checklists.md stop rule missing, does not defer to /archgate, or keeps a numeric threshold: $checklist_rule"
fi

if grep -A3 'Автотриггер: после АрхГейта' "$ROOT/memory/protocol-work.md" | grep -q 'вердикт «проходит АрхГейт»'; then
    pass "protocol-work.md auto-trigger keys on the 'проходит АрхГейт' verdict, not a score"
else
    fail_test "protocol-work.md auto-trigger after ArchGate no longer keys on the 'проходит АрхГейт' verdict"
fi

if [ "$fail" -eq 0 ]; then
    echo "✅ test_issue_882_archgate_scale: all checks passed"
fi
exit "$fail"
