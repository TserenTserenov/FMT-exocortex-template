#!/usr/bin/env bash
# Regression coverage (WP-617 Ф4, 09.11) for two text filters of
# setup/validate-template.sh that looked at the wrong thing:
#   [1/5] the docs/adr/ exemption ran `grep -v 'docs/adr/'` over the whole
#         "path:line:text" record, so a line in ANY file that merely mentioned
#         docs/adr/ escaped the author-content check;
#   [9/9] the enforcement-verb list held a bare "deni", so "hardening" read as
#         "denies".
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALIDATOR="$ROOT/setup/validate-template.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

# Split so that this file itself does not trip check [1/5] of the template.
AUTHOR_WORD="aist_pilot""_bot"

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

# Prints the verdict line of check $2 ("1/5", "9/9") for template $1.
verdict() {
    bash "$VALIDATOR" "$1" 2>&1 | grep -F "[$2]" | head -1
}

# A template with file $2 (relative) holding the line $3.
make_file_template() {
    local tpl=$1 rel=$2 line=$3
    mkdir -p "$tpl/$(dirname "$rel")"
    printf '# Doc\n\n%s\n' "$line" > "$tpl/$rel"
}

# A template with one unregistered hook and a SKILL.md line $2.
make_skill_template() {
    local tpl=$1 line=$2
    mkdir -p "$tpl/.claude/hooks" "$tpl/.claude/skills/notes"
    printf '#!/bin/bash\nexit 0\n' > "$tpl/.claude/hooks/probe-check.sh"
    printf '{"hooks": {}}\n' > "$tpl/.claude/settings.json"
    printf '# Skill\n\n%s\n' "$line" > "$tpl/.claude/skills/notes/SKILL.md"
}

# 1. [1/5]: a file outside docs/adr/ that mentions docs/adr/ in its text and
#    carries an author word is still reported.
T1="$TEST_ROOT/adr-mention"
make_file_template "$T1" "docs/guide.md" "See docs/adr/001.md; bot $AUTHOR_WORD"
out=$(verdict "$T1" "1/5")
if grep -q 'FAIL' <<<"$out"; then
    pass "a text mention of docs/adr/ no longer hides an author word"
else
    fail_test "author word in docs/guide.md was missed: $out"
fi

# 2. [1/5]: the exemption itself still holds for files under docs/adr/.
T2="$TEST_ROOT/adr-file"
make_file_template "$T2" "docs/adr/001.md" "Historical install: bot $AUTHOR_WORD"
out=$(verdict "$T2" "1/5")
if grep -q 'PASS' <<<"$out"; then
    pass "files under docs/adr/ stay exempt"
else
    fail_test "docs/adr/ file was reported: $out"
fi

# 2a. Same, with the template path given with trailing slashes.
out=$(verdict "$T2//" "1/5")
if grep -q 'PASS' <<<"$out"; then
    pass "a trailing slash on the template path keeps the docs/adr/ exemption"
else
    fail_test "trailing slash broke the docs/adr/ exemption: $out"
fi

# 3. [9/9]: "hardening" next to a hook name is not an enforcement claim.
T3="$TEST_ROOT/hardening"
make_skill_template "$T3" 'The probe-check.sh hook: hardening notes.'
out=$(verdict "$T3" "9/9")
if grep -q 'PASS' <<<"$out"; then
    pass "\"hardening\" is not read as \"denies\""
else
    fail_test "false claim from \"hardening\": $out"
fi

# 4. [9/9]: every form of "deny" still counts as a claim.
for phrase in 'denies writes' 'writes are Denied' 'deny on write' 'denial of writes'; do
    T4="$TEST_ROOT/deny-${phrase// /-}"
    make_skill_template "$T4" "The probe-check.sh hook: $phrase."
    out=$(verdict "$T4" "9/9")
    if grep -q 'FAIL' <<<"$out"; then
        pass "\"$phrase\" is reported as a claim"
    else
        fail_test "\"$phrase\" was not reported: $out"
    fi
done

exit $fail
