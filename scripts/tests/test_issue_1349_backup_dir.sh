#!/usr/bin/env bash
# test_issue_1349_backup_dir.sh — outside macOS a configured backup_dir used to
# be read and then silently ignored: backup-icloud.sh refused with an iCloud
# message and iwe-backup-check printed "N/A". Both must now say that the
# built-in backup does not run on this OS and point to the supported way out
# (issue #1349). Without backup_dir the check stays a plain N/A.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

FAIL=0
pass() { echo "  ✅ PASS: $*"; }
fail() { echo "  ❌ FAIL: $*"; FAIL=$((FAIL + 1)); }

PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null)}"
export PYTHONUSERBASE

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/ws/DS-strategy"
REAL_UNAME="$(command -v uname)"
printf '#!/bin/sh\n[ "${1:-}" = "-s" ] && { echo Linux; exit 0; }\nexec %s "$@"\n' "$REAL_UNAME" > "$TMP/bin/uname"
chmod +x "$TMP/bin/uname"

run() {  # run SCRIPT ARGS... with a Linux uname and the test workspace
    HOME="$TMP/home" PATH="$TMP/bin:$PATH" WORKSPACE_DIR="$TMP/ws" IWE_ROOT="$TMP/ws" \
        IWE_WORKSPACE="$TMP/ws" IWE_GOVERNANCE_REPO=DS-strategy bash "$@"
}

printf 'backup_dir: "%s/backups"\n' "$TMP" > "$TMP/ws/params.yaml"
run "$ROOT/scripts/iwe-backup-check.sh" --root "$TMP/ws" > "$TMP/check.out" 2>&1
if grep -q 'backup_dir задан' "$TMP/check.out" && grep -q 'backup_enabled: false' "$TMP/check.out"; then
    pass "iwe-backup-check warns that the built-in backup does not run on Linux"
else
    fail "iwe-backup-check is silent about backup_dir on Linux: $(sed -n '/## 1\./,/## 2\./p' "$TMP/check.out" | tr '\n' ' ')"
fi

RC=0
run "$ROOT/scripts/backup-icloud.sh" > "$TMP/run.out" 2>&1 || RC=$?
if [ "$RC" -ne 0 ] && grep -q 'backup_dir задан' "$TMP/run.out"; then
    pass "backup-icloud.sh refuses with the backup_dir explanation"
else
    fail "backup-icloud.sh rc=$RC without the backup_dir explanation: $(tr '\n' ' ' < "$TMP/run.out")"
fi

printf '# no backup_dir\n' > "$TMP/ws/params.yaml"
run "$ROOT/scripts/iwe-backup-check.sh" --root "$TMP/ws" > "$TMP/check2.out" 2>&1
if grep -q 'N/A (платформа: linux' "$TMP/check2.out" && ! grep -q 'backup_dir задан' "$TMP/check2.out"; then
    pass "without backup_dir the check stays a plain N/A"
else
    fail "without backup_dir the section changed: $(sed -n '/## 1\./,/## 2\./p' "$TMP/check2.out" | tr '\n' ' ')"
fi

[ "$FAIL" -eq 0 ] && echo "PASS: issue #1349 backup_dir outside macOS" || { echo "FAIL: issue #1349 has $FAIL violation(s)"; exit 1; }
