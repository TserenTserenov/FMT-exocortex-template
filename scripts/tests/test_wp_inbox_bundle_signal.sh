#!/usr/bin/env bash
# Regression coverage for the WP inbound mailbox signal in wp-sync-bundle.sh
# (WP-5 Ф69): entries with status «новое» in inbox/WP-N/INBOX.md become an
# inbox_unprocessed drift signal and switch the bundle to the non-trivial
# branch even with zero related WPs; «учтено» entries are not shown.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
BUNDLE="$ROOT/.claude/scripts/wp-sync-bundle.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

GOV="$TMP/ws/governance"
mkdir -p "$GOV/docs" "$GOV/inbox/WP-7"
: > "$GOV/docs/WP-REGISTRY.md"
printf -- '---\nwp: 7\nstatus: in_progress\n---\n# WP-7\n' > "$GOV/inbox/WP-7/WP-7.md"

run_bundle() {
    env -u IWE_SCRIPTS IWE_WORKSPACE="$TMP/ws" IWE_GOVERNANCE_REPO=governance bash "$BUNDLE" WP-7 2>/dev/null
}

# --- 1. No mailbox: section present, no signal, simple branch.
out=$(run_bundle)
if printf '%s' "$out" | grep -q 'Нет неразобранных записей' && ! printf '%s' "$out" | grep -q 'inbox_unprocessed'; then
    pass "no INBOX.md: no signal"
else
    fail_test "no INBOX.md: expected empty mailbox section without signal: $out"
fi

# --- 2. One «новое» and one «учтено» entry.
cat > "$GOV/inbox/WP-7/INBOX.md" <<'EOF'
# Входящие

## И-1 · 2026-11-02 · из РП-9 · новое
- Выжимка: первая

## И-2 · 2026-11-02 · из РП-9 · учтено
- Выжимка: вторая
EOF
out=$(run_bundle)
if printf '%s' "$out" | grep -q 'Неразобранных записей: 1'; then
    pass "counts only «новое» entries"
else
    fail_test "expected 1 unprocessed entry: $out"
fi
if printf '%s' "$out" | grep -q 'Выжимка: первая' && ! printf '%s' "$out" | grep -q 'Выжимка: вторая'; then
    pass "shows the «новое» entry body, hides «учтено»"
else
    fail_test "wrong entry bodies in mailbox section: $out"
fi
if printf '%s' "$out" | grep -q 'DRIFT: inbox_unprocessed — 1 записей'; then
    pass "inbox_unprocessed drift signal emitted"
else
    fail_test "inbox_unprocessed drift signal missing: $out"
fi
if printf '%s' "$out" | grep -q 'Нетривиальный случай\*\* (0 связанных, 1 drift'; then
    pass "non-trivial branch with zero related WPs"
else
    fail_test "expected non-trivial branch: $out"
fi

[ "$fail" -eq 0 ] && echo "test_wp_inbox_bundle_signal: ALL PASS" || echo "test_wp_inbox_bundle_signal: FAILURES ABOVE"
exit "$fail"
