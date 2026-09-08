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
# Использование: bash scripts/check-seed-drift.sh [--fix] [FMT_DIR]
#
# issue #347: сторож печатал инструкцию «скопировать вручную, сохранив маркерную
# строку» — ручной шаг после каждой правки исходника, и именно он не выполнялся:
# снимок отставал на три фикса подряд. --fix выполняет ту же операцию сам.

set -uo pipefail

FIX=false
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --fix) FIX=true ;;
        *)     ARGS+=("$arg") ;;
    esac
done

FMT_DIR="${ARGS[0]:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
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
        if $FIX; then
            # Marker goes back on line 2, right after the shebang — the same place the
            # convention above expects it and the same place grep -vF strips it from.
            # Built in a temp file first: redirecting straight into "$f" truncates the
            # snapshot before anything is read, so a failure would leave it empty while
            # the script still printed FIXED and returned 0.
            tmp_snapshot="${f}.new.$$"
            if { head -1 "$src"; printf '%s\n' "$MARKER"; tail -n +2 "$src"; } > "$tmp_snapshot" \
               && diff -q <(grep -vF "$MARKER" "$tmp_snapshot") "$src" >/dev/null 2>&1; then
                # Preserve the snapshot's own executable bit, not the source's: a
                # sourced library is 644 in scripts/ but 755 in seed/, and copying the
                # source's mode silently stripped +x there (caught by the repo's
                # pre-commit executable-bit guard).
                [ -x "$f" ] && chmod +x "$tmp_snapshot"
                mv "$tmp_snapshot" "$f"
                echo "FIXED: seed/strategy/scripts/$rel пересобран из scripts/$rel"
            else
                rm -f "$tmp_snapshot"
                echo "FAIL: не удалось пересобрать seed/strategy/scripts/$rel — снимок оставлен без изменений"
                fail=1
            fi
        else
            echo "FAIL: seed/strategy/scripts/$rel разошёлся с scripts/$rel"
            echo "  diff:"
            diff <(grep -vF "$MARKER" "$f") "$src" | head -20 | sed 's/^/    /'
            echo "  Фикс: bash scripts/check-seed-drift.sh --fix"
            fail=1
        fi
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
