#!/usr/bin/env bash
# routing: utility  deterministic=true
# check-seed-drift.sh — seed/strategy/scripts/ снапшоты не разъехались с scripts/
#
# Найдено WP-5 (2026-07-22, Ubuntu-audit П3): seed-копии day-open-pipeline.sh/
# day-open-scaffold.sh расходились с scripts/ на сотни строк без предупреждения —
# новый пользователь получал старый пайплайн (падал на анти-чит проверке
# «Горлышко недели», архивация после Checks вместо до). Синхронизация ручная
# (script-promote.sh не пишет в seed/), драйфит молча.
#
# Конвенция: файл в seed/, помеченный строкой "# SNAPSHOT — synced manually
# via script-promote.sh from FMT-exocortex-template/scripts/. Do not edit here
# directly." — обязан быть побайтово идентичен scripts/<basename> после
# вычитания этой одной маркерной строки. Файл без маркера — не проверяется
# (не претендует на синхронность, напр. seed-only скрипты).
#
# Использование: bash scripts/check-seed-drift.sh [FMT_DIR]

set -uo pipefail

FMT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SEED_DIR="$FMT_DIR/seed/strategy/scripts"
SCRIPTS_DIR="$FMT_DIR/scripts"
MARKER="# SNAPSHOT — synced manually via script-promote.sh from FMT-exocortex-template/scripts/. Do not edit here directly."

if [ ! -d "$SEED_DIR" ]; then
    echo "SKIP: $SEED_DIR не найден"
    exit 0
fi

fail=0
checked=0
while IFS= read -r -d '' f; do
    rel="${f#"$SEED_DIR"/}"
    if ! grep -qF "$MARKER" "$f"; then
        continue
    fi
    src="$SCRIPTS_DIR/$rel"
    if [ ! -f "$src" ]; then
        echo "FAIL: $rel помечен SNAPSHOT, но scripts/$rel отсутствует"
        fail=1
        continue
    fi
    checked=$((checked + 1))
    if ! diff -q <(grep -vF "$MARKER" "$f") "$src" >/dev/null 2>&1; then
        echo "FAIL: seed/strategy/scripts/$rel разошёлся с scripts/$rel"
        echo "  diff:"
        diff <(grep -vF "$MARKER" "$f") "$src" | head -20 | sed 's/^/    /'
        echo "  Фикс: скопировать scripts/$rel в seed/strategy/scripts/$rel"
        echo "        (сохранив маркерную строку после shebang/в начале файла)."
        fail=1
    fi
done < <(find "$SEED_DIR" -type f -print0)

if [ "$checked" -eq 0 ]; then
    echo "SKIP: ни один файл в $SEED_DIR не несёт маркер SNAPSHOT"
    exit 0
fi

if [ "$fail" -eq 0 ]; then
    echo "PASS: $checked seed-снапшот(ов) синхронизированы со scripts/"
fi
exit $fail
