#!/usr/bin/env bash
# Regression coverage for issue #530 staged self-scan false positives.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TMP_ROOT"' EXIT
STANDARD_PREFIX="/opt""/homebrew"
READLINK_F="readlink"" -f"

pass_count=0

pass() {
    echo "  ✅ PASS: $*"
    pass_count=$((pass_count + 1))
}

fail() {
    echo "  ❌ FAIL: $*" >&2
    exit 1
}

new_fixture() {
    local name="$1"
    local target="$TMP_ROOT/$name"
    git clone --quiet --no-hardlinks "$ROOT" "$target"
    cp "$ROOT/setup/validate-template.sh" "$target/setup/validate-template.sh"
    cp "$ROOT/.githooks/pre-commit" "$target/.githooks/pre-commit"
    printf '%s\n' "$target"
}

echo "--- staged standard Homebrew documentation exceptions ---"
allowed=$(new_fixture allowed-docs)
for path in README.md docs/PLATFORM-COMPAT.md .github/workflows/validate-template.yml; do
    printf '\n# issue-530 documented standard path: %s/bin\n' "$STANDARD_PREFIX" >> "$allowed/$path"
    git -C "$allowed" add -- "$path"
done
if allowed_output=$(cd "$allowed" && bash setup/validate-template.sh --mode=staged . 2>&1); then
    pass "README, PLATFORM-COMPAT and workflow are path-scoped exceptions"
else
    echo "$allowed_output" >&2
    fail "documented standard Homebrew paths still block staged validation"
fi

blocked=$(new_fixture blocked-doc)
printf 'Unsafe executable: %s/bin/private-tool\n' "$STANDARD_PREFIX" > "$blocked/docs/unsafe-homebrew.md"
git -C "$blocked" add -- docs/unsafe-homebrew.md
if blocked_output=$(cd "$blocked" && bash setup/validate-template.sh --mode=staged . 2>&1); then
    fail "ordinary staged document bypassed the standard Homebrew path guard"
elif printf '%s' "$blocked_output" | grep -q "Hardcoded $STANDARD_PREFIX paths.*FAIL"; then
    pass "ordinary staged document remains blocked"
else
    echo "$blocked_output" >&2
    fail "negative control failed for an unrelated reason"
fi

echo "--- pre-commit portability checker self-exclusion ---"
self_scan=$(new_fixture checker-self)
printf '\n# issue-530 staged self-scan probe\n' >> "$self_scan/scripts/check-platform-compat.sh"
git -C "$self_scan" add -- scripts/check-platform-compat.sh
if self_output=$(cd "$self_scan" && bash .githooks/pre-commit 2>&1); then
    pass "canonical checker does not scan its own rule literals"
else
    echo "$self_output" >&2
    fail "canonical checker is still blocked by its own patterns"
fi

ordinary=$(new_fixture ordinary-script)
printf '\n%s /tmp >/dev/null\n' "$READLINK_F" >> "$ordinary/scripts/test-route-task.sh"
git -C "$ordinary" add -- scripts/test-route-task.sh
if ordinary_output=$(cd "$ordinary" && bash .githooks/pre-commit 2>&1); then
    fail "ordinary shell file bypassed the $READLINK_F guard"
elif printf '%s' "$ordinary_output" | grep -q 'File: scripts/test-route-task.sh'; then
    pass "ordinary shell file remains blocked by exact-path guard"
else
    echo "$ordinary_output" >&2
    fail "ordinary shell negative control failed before portability classification"
fi

echo "issue-530 staged self-scan: $pass_count checks passed"
