#!/usr/bin/env bash
# test_changelog_append_blank_lines.sh — changelog-append.sh не копит пустые
# строки перед [Unreleased] (WP-7, чистка шаблона 2026-11-01).
#
# Корень: скрипт удалял старый блок [Unreleased], но оставлял пустую строку,
# стоявшую перед ним, и добавлял свою — каждый запуск прибавлял одну строку.
# К ноябрю 2026 в CHANGELOG.md их накопилось 125.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
SCRIPT="$ROOT/scripts/changelog-append.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; fail=1; }

blanks_before_unreleased() {
    awk '/^## \[Unreleased\]/ { found = 1; exit } /^$/ { run++; next } { run = 0 } END { print (found ? run : -1) }' "$1"
}

make_repo() {
    local repo="$1" changelog="$2"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email test@example.invalid
    git -C "$repo" config user.name test
    printf '%b' "$changelog" > "$repo/CHANGELOG.md"
    git -C "$repo" add CHANGELOG.md
    git -C "$repo" commit -qm 'init'
    git -C "$repo" commit -q --allow-empty -m 'fix: something'
}

run_append() {
    IWE_TEMPLATE="$1" bash "$SCRIPT" >/dev/null 2>&1
}

# 1. Повторные запуски держат ровно одну пустую строку перед [Unreleased].
R1="$TMP/repeat"
make_repo "$R1" '# Changelog\n\nIntro.\n\n## [0.1.0] — 2026-01-01\n\n- old\n'
for i in 1 2 3; do
    run_append "$R1"
    n=$(blanks_before_unreleased "$R1/CHANGELOG.md")
    if [ "$n" = "1" ]; then
        pass "запуск $i: одна пустая строка перед [Unreleased]"
    else
        fail "запуск $i: перед [Unreleased] $n пустых строк, ожидалась 1"
    fi
done

# 2. Уже накопленный хвост пустых строк схлопывается до одной.
R2="$TMP/accumulated"
make_repo "$R2" '# Changelog\n\nIntro.\n\n\n\n\n\n## [Unreleased]\n\n- stale\n\n## [0.1.0] — 2026-01-01\n\n- old\n'
run_append "$R2"
n=$(blanks_before_unreleased "$R2/CHANGELOG.md")
if [ "$n" = "1" ]; then
    pass "накопленные пустые строки схлопнуты до одной"
else
    fail "накопленные пустые строки не схлопнуты: $n"
fi

# 3. Шапка и версии не потеряны.
if grep -q '^Intro\.$' "$R2/CHANGELOG.md" && grep -q '^## \[0\.1\.0\]' "$R2/CHANGELOG.md" \
   && ! grep -q -- '- stale' "$R2/CHANGELOG.md"; then
    pass "шапка и прошлая версия на месте, старый [Unreleased] заменён"
else
    fail "содержимое CHANGELOG.md повреждено"
fi

# 4. Ветка без именованных версий тоже не копит пустые строки.
R3="$TMP/no-versions"
make_repo "$R3" '# Changelog\n\nIntro.\n\n\n'
run_append "$R3"
run_append "$R3"
n=$(blanks_before_unreleased "$R3/CHANGELOG.md")
if [ "$n" = "1" ]; then
    pass "без именованных версий: одна пустая строка"
else
    fail "без именованных версий: $n пустых строк, ожидалась 1"
fi

exit "$fail"
