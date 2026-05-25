#!/usr/bin/env bash
# routing: helper  skill=audit-installation  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# memory-validate.sh — валидация frontmatter memory/*.md (WP-217 Ф10.2)
#
# Проверяет: наличие frontmatter, обязательные поля, допустимые значения,
# инварианты (superseded → superseded_by, schema_version = 1).
#
# Usage:
#   bash scripts/memory-validate.sh                     # все memory/*.md
#   bash scripts/memory-validate.sh memory/file.md      # один файл
#   bash scripts/memory-validate.sh --dir PATH          # другая директория
#   bash scripts/memory-validate.sh --quiet             # только FAIL строки
#
# Exit code: 0 = все OK, 1 = есть нарушения.
# Spec: memory/memory-lifecycle-spec.md §3 (WP-217 Ф10.1)

set -eu

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
MEMORY_DIR="$IWE_ROOT/memory"
QUIET=0
TARGET=""

# Файлы-исключения (индексы, не memory-объекты)
EXCLUDE="MEMORY.md"

REQUIRED_FIELDS="name description type horizon domains status valid_from owner schema_version"
VALID_TYPES="user feedback project reference lesson protocol"
VALID_HORIZONS="hot warm cold archive"
VALID_STATUSES="active dormant superseded archived"

while [ $# -gt 0 ]; do
    case "$1" in
        --dir)    MEMORY_DIR="$2"; shift 2 ;;
        --quiet)  QUIET=1; shift ;;
        -h|--help)
            grep '^#' "$0" | head -15
            exit 0
            ;;
        *.md) TARGET="$1"; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Извлечь значение поля из frontmatter файла
get_field() {
    local file="$1" field="$2"
    awk '/^---/{f++} f==1 && /^'"$field"':/{gsub(/^[^:]+: */,""); gsub(/^["'"'"']|["'"'"']$/,""); print; exit}' "$file"
}

# Проверить наличие frontmatter
has_frontmatter() {
    local file="$1"
    head -1 "$file" | grep -q '^---$'
}

validate_file() {
    local file="$1"
    local errors=0
    local errs=""

    # Проверка 1: наличие frontmatter
    if ! has_frontmatter "$file"; then
        errs="$errs\n  ❌ нет frontmatter (файл должен начинаться с ---)"
        errors=$((errors + 1))
        # Без frontmatter дальше не проверяем
        printf "FAIL %s%b\n" "$file" "$errs"
        return 1
    fi

    # Проверка 2: все обязательные поля присутствуют
    for field in $REQUIRED_FIELDS; do
        val=$(get_field "$file" "$field")
        if [ -z "$val" ]; then
            errs="$errs\n  ❌ отсутствует обязательное поле: $field"
            errors=$((errors + 1))
        fi
    done

    # Проверка 3: допустимые значения type
    type_val=$(get_field "$file" "type")
    if [ -n "$type_val" ]; then
        valid=0
        for t in $VALID_TYPES; do
            [ "$type_val" = "$t" ] && valid=1 && break
        done
        if [ $valid -eq 0 ]; then
            errs="$errs\n  ❌ недопустимое type='$type_val' (допустимо: $VALID_TYPES)"
            errors=$((errors + 1))
        fi
    fi

    # Проверка 4: допустимые значения horizon
    horizon_val=$(get_field "$file" "horizon")
    if [ -n "$horizon_val" ]; then
        valid=0
        for h in $VALID_HORIZONS; do
            [ "$horizon_val" = "$h" ] && valid=1 && break
        done
        if [ $valid -eq 0 ]; then
            errs="$errs\n  ❌ недопустимое horizon='$horizon_val' (допустимо: $VALID_HORIZONS)"
            errors=$((errors + 1))
        fi
    fi

    # Проверка 5: допустимые значения status
    status_val=$(get_field "$file" "status")
    if [ -n "$status_val" ]; then
        valid=0
        for s in $VALID_STATUSES; do
            [ "$status_val" = "$s" ] && valid=1 && break
        done
        if [ $valid -eq 0 ]; then
            errs="$errs\n  ❌ недопустимое status='$status_val' (допустимо: $VALID_STATUSES)"
            errors=$((errors + 1))
        fi
    fi

    # Проверка 6: valid_from формат YYYY-MM-DD
    valid_from=$(get_field "$file" "valid_from")
    if [ -n "$valid_from" ]; then
        if ! echo "$valid_from" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
            errs="$errs\n  ❌ valid_from='$valid_from' не соответствует формату YYYY-MM-DD"
            errors=$((errors + 1))
        fi
    fi

    # Проверка 7: инвариант superseded → superseded_by обязателен
    if [ "$status_val" = "superseded" ]; then
        superseded_by=$(get_field "$file" "superseded_by")
        if [ -z "$superseded_by" ]; then
            errs="$errs\n  ❌ status=superseded но поле superseded_by отсутствует"
            errors=$((errors + 1))
        fi
    fi

    # Проверка 8: schema_version = 1
    schema_ver=$(get_field "$file" "schema_version")
    if [ -n "$schema_ver" ] && [ "$schema_ver" != "1" ]; then
        errs="$errs\n  ⚠️  schema_version=$schema_ver (текущая=1, нужна миграция через memory-migrate.sh)"
    fi

    if [ $errors -eq 0 ]; then
        [ $QUIET -eq 0 ] && printf "OK   %s\n" "$file"
        return 0
    else
        printf "FAIL %s%b\n" "$file" "$errs"
        return 1
    fi
}

# Основной цикл
total=0
failed=0

if [ -n "$TARGET" ]; then
    files="$TARGET"
else
    files=$(find "$MEMORY_DIR/" -maxdepth 1 -name "*.md" | sort)
fi

for f in $files; do
    [ -f "$f" ] || continue
    # Пропустить файлы-исключения (индексы)
    name=$(basename "$f")
    skip=0
    for exc in $EXCLUDE; do [ "$name" = "$exc" ] && skip=1 && break; done
    [ $skip -eq 1 ] && continue
    total=$((total + 1))
    validate_file "$f" || failed=$((failed + 1))
done

echo ""
echo "Итог: $((total - failed))/$total файлов OK$([ $failed -gt 0 ] && echo ", $failed нарушений" || true)"

[ $failed -eq 0 ] && exit 0 || exit 1
