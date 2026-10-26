#!/usr/bin/env bash
# test_issue_1349_backup_dir.sh — a configured backup_dir works on any OS
# (issue #1349): backup-icloud.sh writes the archive there, iwe-backup-check
# checks its freshness, and "no archives yet" is a warning, not a critical —
# a critical would forbid week-close 7b, the only step that creates the first
# archive. The iCloud mount check applies only to a target inside iCloud Drive.
# `uname -s` is faked through PATH; HOME is a throwaway directory.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BACKUP="$ROOT/scripts/backup-icloud.sh"
CHECK="$ROOT/scripts/iwe-backup-check.sh"

FAIL=0
pass() { echo "  ✅ PASS: $*"; }
fail() { echo "  ❌ FAIL: $*"; FAIL=$((FAIL + 1)); }

# Resolve the real user site-packages before HOME is swapped (same trap as #1342).
PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null)}"
export PYTHONUSERBASE

TMP="$(mktemp -d)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
WS="$TMP/ws"
mkdir -p "$TMP/linux" "$TMP/darwin" "$TMP/home" "$WS/DS-strategy"

REAL_UNAME="$(command -v uname)"
for os in Linux Darwin; do
    dir="$TMP/$(echo "$os" | tr '[:upper:]' '[:lower:]')"
    printf '#!/bin/sh\n[ "${1:-}" = "-s" ] && { echo %s; exit 0; }\nexec %s "$@"\n' "$os" "$REAL_UNAME" > "$dir/uname"
    chmod +x "$dir/uname"
done

# Workspace content: one file that must be archived and one per tar exclude.
echo keep > "$WS/keep.txt"
for d in .git node_modules .venv sub/__pycache__ _backups .claude/worktrees .iwe-runtime/isolated-worktrees; do
    mkdir -p "$WS/$d" && echo x > "$WS/$d/excluded.txt"
done
echo x > "$WS/.DS_Store"

run() {  # run OS SCRIPT ARGS... — OS is linux|darwin
    local os="$1"; shift
    HOME="$TMP/home" PATH="$TMP/$os:$PATH" WORKSPACE_DIR="$WS" IWE_ROOT="$WS" \
        IWE_WORKSPACE="$WS" IWE_GOVERNANCE_REPO=DS-strategy bash "$@"
}
section1() { sed -n '/^## 1\./,/^## 2\./p' "$1"; }
set_backup_dir() { printf 'backup_dir: "%s"\n' "$1" > "$WS/params.yaml"; }

# --- Linux + backup_dir, nothing backed up yet: warning, not critical ---------
BDIR="$TMP/backups/IWE"          # not created yet — the first backup makes it
set_backup_dir "$BDIR"
run linux "$CHECK" --root "$WS" > "$TMP/c1.out" 2>&1
if section1 "$TMP/c1.out" | grep -q 'пока нет' && ! section1 "$TMP/c1.out" | grep -q '❌'; then
    pass "Linux + backup_dir without archives → warning, no critical"
else
    fail "no-archives case on Linux: $(section1 "$TMP/c1.out" | tr '\n' ' ')"
fi
if section1 "$TMP/c1.out" | grep -q 'iCloud'; then
    fail "iCloud wording for a non-iCloud backup_dir: $(section1 "$TMP/c1.out" | tr '\n' ' ')"
else
    pass "no iCloud wording for a non-iCloud backup_dir"
fi

# --- Linux + backup_dir: backup-icloud.sh creates the archive ----------------
RC=0
run linux "$BACKUP" > "$TMP/b1.out" 2>&1 || RC=$?
ARCHIVE="$(find "$BDIR" -maxdepth 1 -name 'IWE-backup-*.tar.gz' 2>/dev/null | head -1)"
if [ "$RC" -eq 0 ] && [ -n "$ARCHIVE" ]; then
    pass "Linux + backup_dir → backup-icloud.sh exit 0, archive in backup_dir"
else
    fail "backup-icloud.sh rc=$RC archive='${ARCHIVE}': $(tr '\n' ' ' < "$TMP/b1.out")"
fi

# The exclude flags must work with this tar (bsdtar on macOS, GNU tar in CI).
if [ -n "$ARCHIVE" ]; then
    tar -tzf "$ARCHIVE" > "$TMP/list.txt"
    if grep -q '^ws/keep.txt$' "$TMP/list.txt" && ! grep -q 'excluded.txt\|\.DS_Store' "$TMP/list.txt"; then
        pass "archive has workspace files and none of the excluded paths ($(tar --version 2>/dev/null | head -1))"
    else
        fail "tar excludes not applied: $(tr '\n' ' ' < "$TMP/list.txt")"
    fi
fi

run linux "$CHECK" --root "$WS" > "$TMP/c2.out" 2>&1
if section1 "$TMP/c2.out" | grep -q 'Бэкап свежий' && ! section1 "$TMP/c2.out" | grep -q '❌'; then
    pass "iwe-backup-check sees the fresh archive in backup_dir, no critical"
else
    fail "check after backup: $(section1 "$TMP/c2.out" | tr '\n' ' ')"
fi

# --- archive older than 14 days stays critical -------------------------------
[ -n "$ARCHIVE" ] && touch -t 202001010000 "$ARCHIVE"
run linux "$CHECK" --root "$WS" > "$TMP/c3.out" 2>&1
if section1 "$TMP/c3.out" | grep -q '❌ Последний бэкап старше'; then
    pass "stale archive in backup_dir → critical"
else
    fail "stale archive not critical: $(section1 "$TMP/c3.out" | tr '\n' ' ')"
fi
rm -f "$BDIR"/IWE-backup-*.tar.gz

# --- target not writable → critical (skipped as root: chmod has no effect) ---
if [ "$(id -u)" -ne 0 ]; then
    chmod 555 "$BDIR"
    run linux "$CHECK" --root "$WS" > "$TMP/c4.out" 2>&1
    if section1 "$TMP/c4.out" | grep -q '❌.*недоступна для записи'; then
        pass "read-only backup_dir → critical"
    else
        fail "read-only backup_dir not critical: $(section1 "$TMP/c4.out" | tr '\n' ' ')"
    fi
    RC=0
    run linux "$BACKUP" > "$TMP/b4.out" 2>&1 || RC=$?
    if [ "$RC" -ne 0 ] && grep -q 'Не удалось создать архив' "$TMP/b4.out"; then
        pass "backup-icloud.sh into a read-only backup_dir fails with a message"
    else
        fail "backup into read-only dir rc=$RC: $(tr '\n' ' ' < "$TMP/b4.out")"
    fi
    # Missing target whose nearest existing parent is read-only (unmounted volume).
    set_backup_dir "$BDIR/missing/deeper"
    run linux "$CHECK" --root "$WS" > "$TMP/c5.out" 2>&1
    if section1 "$TMP/c5.out" | grep -q '❌.*не может быть создана'; then
        pass "missing backup_dir under a read-only parent → critical"
    else
        fail "uncreatable backup_dir not critical: $(section1 "$TMP/c5.out" | tr '\n' ' ')"
    fi
    chmod 755 "$BDIR"
else
    echo "  ⏭  SKIP: read-only target cases (running as root)"
fi

# --- --no-icloud keeps disabling the section ---------------------------------
set_backup_dir "$BDIR"
run linux "$CHECK" --root "$WS" --no-icloud > "$TMP/c6.out" 2>&1
if section1 "$TMP/c6.out" | grep -q 'Пропущено (--no-icloud)' && ! section1 "$TMP/c6.out" | grep -q 'пока нет'; then
    pass "--no-icloud disables the archive section"
else
    fail "--no-icloud: $(section1 "$TMP/c6.out" | tr '\n' ' ')"
fi

# --- no backup_dir on Linux → plain N/A, backup refuses ----------------------
printf '# no backup_dir\n' > "$WS/params.yaml"
run linux "$CHECK" --root "$WS" > "$TMP/c7.out" 2>&1
if section1 "$TMP/c7.out" | grep -q 'N/A (платформа: linux' && ! section1 "$TMP/c7.out" | grep -q '❌\|⚠️'; then
    pass "without backup_dir on Linux the section is a plain N/A"
else
    fail "no-backup_dir section on Linux: $(section1 "$TMP/c7.out" | tr '\n' ' ')"
fi
RC=0
run linux "$BACKUP" > "$TMP/b7.out" 2>&1 || RC=$?
if [ "$RC" -ne 0 ] && grep -q 'Цель бэкапа не задана' "$TMP/b7.out"; then
    pass "backup-icloud.sh without any target refuses with a message"
else
    fail "no-target backup rc=$RC: $(tr '\n' ' ' < "$TMP/b7.out")"
fi

# --- macOS + backup_dir outside iCloud: no iCloud mount check ----------------
# The fake HOME has no ~/Library/Mobile Documents, i.e. iCloud Drive is off.
MDIR="$TMP/mac-backups"
set_backup_dir "$MDIR"
RC=0
run darwin "$BACKUP" > "$TMP/b8.out" 2>&1 || RC=$?
if [ "$RC" -eq 0 ] && [ -n "$(find "$MDIR" -maxdepth 1 -name 'IWE-backup-*.tar.gz' 2>/dev/null)" ]; then
    pass "macOS + backup_dir outside iCloud → archive created without iCloud Drive"
else
    fail "macOS backup_dir outside iCloud rc=$RC: $(tr '\n' ' ' < "$TMP/b8.out")"
fi
run darwin "$CHECK" --root "$WS" > "$TMP/c8.out" 2>&1
if section1 "$TMP/c8.out" | grep -q 'Бэкап свежий' && ! section1 "$TMP/c8.out" | grep -q 'iCloud'; then
    pass "macOS check of a backup_dir outside iCloud ignores the missing iCloud root"
else
    fail "macOS check outside iCloud: $(section1 "$TMP/c8.out" | tr '\n' ' ')"
fi

# --- macOS iCloud default with iCloud Drive off: mount check still fires -----
printf '# no backup_dir\n' > "$WS/params.yaml"
RC=0
run darwin "$BACKUP" > "$TMP/b9.out" 2>&1 || RC=$?
if [ "$RC" -ne 0 ] && grep -q 'iCloud Drive не найден' "$TMP/b9.out"; then
    pass "macOS iCloud default without iCloud Drive → backup refuses"
else
    fail "iCloud default without iCloud rc=$RC: $(tr '\n' ' ' < "$TMP/b9.out")"
fi
run darwin "$CHECK" --root "$WS" > "$TMP/c9.out" 2>&1
if section1 "$TMP/c9.out" | grep -q '❌.*iCloud.*не найден'; then
    pass "macOS iCloud default without iCloud Drive → critical"
else
    fail "iCloud default without iCloud not critical: $(section1 "$TMP/c9.out" | tr '\n' ' ')"
fi

# --- macOS iCloud default, iCloud Drive on, first week: warning --------------
mkdir -p "$TMP/home/Library/Mobile Documents/com~apple~CloudDocs"
run darwin "$CHECK" --root "$WS" > "$TMP/c10.out" 2>&1
if section1 "$TMP/c10.out" | grep -q 'пока нет' && ! section1 "$TMP/c10.out" | grep -q '❌'; then
    pass "macOS iCloud default before the first backup → warning, no critical"
else
    fail "first week on iCloud default: $(section1 "$TMP/c10.out" | tr '\n' ' ')"
fi

# --- backup_dir inside the workspace: the archive must not contain itself ----
INNER="$WS/backups-inside"
set_backup_dir "$INNER"
RC=0
run linux "$BACKUP" > "$TMP/b-inner.out" 2>&1 || RC=$?
INNER_ARCHIVE="$(find "$INNER" -maxdepth 1 -name 'IWE-backup-*.tar.gz' 2>/dev/null | head -1)"
if [ "$RC" -eq 0 ] && [ -n "$INNER_ARCHIVE" ] && ! tar -tzf "$INNER_ARCHIVE" | grep -q 'backups-inside'; then
    pass "backup_dir inside the workspace is excluded from its own archive"
else
    fail "in-workspace backup_dir: rc=$RC, archive='${INNER_ARCHIVE}', self-included=$( [ -n "$INNER_ARCHIVE" ] && tar -tzf "$INNER_ARCHIVE" | grep -c 'backups-inside' )"
fi

[ "$FAIL" -eq 0 ] && echo "PASS: issue #1349 backup_dir on any OS" || { echo "FAIL: issue #1349 has $FAIL violation(s)"; exit 1; }
