#!/usr/bin/env bash
# Regression coverage (FMT #1010 / WP-7 Ф225): the author-content scan of
# validate-template.sh must not read local runtime directories. Backups that
# skill-promote and update.sh leave next to replaced files (.backups/) hold
# copies of other people's files; before this fix they failed check [1/5] for
# ever on a live checkout, and the DS-ai-systems pre-commit (which validates
# such a checkout) blocked every commit. Tracked template files stay scanned.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
REPO="$TEST_ROOT/repo"
TOKEN="DS-my""-strategy"

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

git clone --quiet --no-hardlinks "$ROOT" "$REPO"
cp "$ROOT/setup/validate-template.sh" "$REPO/setup/validate-template.sh"

run_pristine() { (cd "$REPO" && bash setup/validate-template.sh --mode=pristine . 2>&1); }

# 1. an untracked backup with an author name does not fail check [1/5]
mkdir -p "$REPO/.backups/skill-promote/old-20260101/skill"
printf 'Журнал: %s и Tseren\n' "$TOKEN" > "$REPO/.backups/skill-promote/old-20260101/skill/SKILL.md"
out=$(run_pristine)
if grep -qF '[1/5] Author-specific content... PASS' <<<"$out"; then
    pass "author name inside .backups/ is not scanned"
else
    fail_test "check [1/5] failed on a local backup: $(grep -F '[1/5]' <<<"$out")"
fi

# 2. the same text in a tracked template file still fails
printf 'governance_repo: %s\n' "$TOKEN" > "$REPO/extensions/issue-backups-probe.yml"
git -C "$REPO" add -- extensions/issue-backups-probe.yml
out=$(run_pristine)
if grep -qF '[1/5] Author-specific content... FAIL' <<<"$out" || grep -qF "$TOKEN" <<<"$out"; then
    pass "a tracked file with the same text is still reported"
else
    fail_test "tracked author content was not reported: $(grep -F '[1/5]' <<<"$out")"
fi

exit $fail
