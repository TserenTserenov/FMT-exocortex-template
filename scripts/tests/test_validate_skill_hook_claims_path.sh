#!/usr/bin/env bash
# Regression coverage (WP-617 Ф4, 08.11): check [9/9] of validate-template.sh
# ("SKILL.md hook-claims are registered") must judge only the text of a
# SKILL.md line, never the path of the file. Before the fix the hook/verb
# filters ran over "path:line:text": a checkout under "…hardening…" (contains
# "deni") with a skill under "…/hooks/…" failed on a line that claimed nothing.
# A path with a colon is covered too: splitting the record on ":" (cut/awk)
# would read part of the path as text again.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALIDATOR="$ROOT/setup/validate-template.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

# A minimal template: one unregistered hook, settings.json without it, and a
# SKILL.md at $2 (relative to the template) with the line $3.
make_template() {
    local tpl=$1 skill_rel=$2 line=$3
    mkdir -p "$tpl/.claude/hooks" "$tpl/$(dirname "$skill_rel")"
    printf '#!/bin/bash\nexit 0\n' > "$tpl/.claude/hooks/probe-guard.sh"
    printf '{"hooks": {}}\n' > "$tpl/.claude/settings.json"
    printf '# Skill\n\n%s\n' "$line" > "$tpl/$skill_rel"
}

# Prints the [9/9] verdict line and the detail lines after it.
check9() {
    bash "$VALIDATOR" "$1" 2>&1 | sed -n '/^\[9\/9\]/,/^$/p'
}

# 1. Path carries "hardening" and "hooks"; the text names the hook but claims
#    nothing → no finding.
T1="$TEST_ROOT/wp-hardening-copy"
make_template "$T1" ".claude/skills/hooks-notes/SKILL.md" 'See probe-guard.sh for details.'
out=$(check9 "$T1")
if grep -q 'PASS' <<<"$out"; then
    pass "path with hooks/hardening alone does not trigger [9/9]"
else
    fail_test "false alarm from the path: $out"
fi

# 2. Same path, the text claims protection ("hook … denied") → one finding,
#    and the finding names the file.
T2="$TEST_ROOT/wp-hardening-claim"
make_template "$T2" ".claude/skills/hooks-notes/SKILL.md" 'The probe-guard.sh hook: writes are denied.'
out=$(check9 "$T2")
if grep -q 'FAIL' <<<"$out" && grep -qF "$T2/.claude/skills/hooks-notes/SKILL.md:3:" <<<"$out"; then
    pass "a real claim is reported with its file and line"
else
    fail_test "real claim not reported with its file: $out"
fi

# 3. Path with a colon, clean text → no finding (cut -d: / awk -F: would fail).
T3="$TEST_ROOT/dir:hooks-denied"
make_template "$T3" ".claude/skills/x:hook-deny/SKILL.md" 'See probe-guard.sh for details.'
out=$(check9 "$T3")
if grep -q 'PASS' <<<"$out"; then
    pass "a colon in the path does not leak the path into the text filters"
else
    fail_test "false alarm from a path with a colon: $out"
fi

# 4. Colons inside the text are kept → the claim is still found.
T4="$TEST_ROOT/plain"
make_template "$T4" ".claude/skills/notes/SKILL.md" 'probe-guard.sh hook: denied extra:colon'
out=$(check9 "$T4")
if grep -q 'FAIL' <<<"$out"; then
    pass "a claim with colons in the text is still reported"
else
    fail_test "claim with colons in the text was missed: $out"
fi

# 5. No .claude/skills at all → [9/9] still gives a verdict and the validator
#    reaches its summary (a failing find must not end the run silently).
T5="$TEST_ROOT/no-skills"
make_template "$T5" "docs/README.md" 'nothing'
full=$(bash "$VALIDATOR" "$T5" 2>&1)
if grep -q '^\[9/9\].*PASS' <<<"$full" && grep -q '^=== ' <<<"$(tail -1 <<<"$full")"; then
    pass "a template without skills/ still gets a [9/9] verdict and a summary"
else
    fail_test "validator stopped without a verdict: $(tail -2 <<<"$full")"
fi

exit $fail
