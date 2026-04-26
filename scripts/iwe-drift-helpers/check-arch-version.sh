#!/usr/bin/env bash
# check-arch-version.sh — детектор рассогласования ARCH-версий и downstream `derived_from:` якорей
# Owner: WP-217 (механизм sync). Активирован WP-263 (child) после WP-253 Ф1 ArchGate.
# Принцип: детектор отчитывается, не правит (см. iwe-drift.sh:11).
#
# Что делает:
#   1. Сканирует PACK-*/pack/*/02-domain-entities/DP.ARCH.*.md → извлекает (id, version) из frontmatter.
#   2. Сканирует PACK-*/**/*.md и DS-my-strategy/inbox/*.md → ищет `derived_from:` якоря с DP.ARCH.NNN@vX.Y.
#   3. Сравнивает: если downstream ссылается на версию, отличную от current → DRIFT.
#   4. Печатает markdown-отчёт.
#
# Usage:
#   bash check-arch-version.sh                    # полный отчёт
#   bash check-arch-version.sh --critical-only    # только drift (без OK)
#   IWE_ROOT=/path bash check-arch-version.sh     # альтернативный корень
#
# Не зависит от iwe-drift.sh — может быть запущен отдельно. Когда iwe-drift.sh научится
# диспатчить `check: script:...` пары, он будет вызывать этот скрипт автоматически.

set -eu

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
MODE="${MODE:-all}"

while [ $# -gt 0 ]; do
    case "$1" in
        --critical-only) MODE="critical"; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# //; s/^#//' | head -25
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Извлечь version из frontmatter ARCH-документа.
# Возвращает нормализованную версию (v1 → v1.0; v2.3 → v2.3) или "?" если не нашли.
extract_arch_version() {
    local file="$1"
    local v
    v=$(awk '
        /^---$/ { fm++; if (fm == 2) exit }
        fm == 1 && /^version:/ {
            sub(/^version:[[:space:]]*/, "")
            sub(/[[:space:]]+$/, "")
            print
            exit
        }
    ' "$file")
    if [ -z "$v" ]; then
        echo "?"
        return
    fi
    # Нормализация: v1 → v1.0, оставить v2.3 как есть
    case "$v" in
        v[0-9]) echo "${v}.0" ;;
        *) echo "$v" ;;
    esac
}

# Извлечь id из frontmatter
extract_arch_id() {
    local file="$1"
    awk '
        /^---$/ { fm++; if (fm == 2) exit }
        fm == 1 && /^id:/ {
            sub(/^id:[[:space:]]*/, "")
            sub(/[[:space:]]+$/, "")
            print
            exit
        }
    ' "$file"
}

# Нормализовать версию из downstream-якоря (@v1 → v1.0)
normalize_ver() {
    local v="$1"
    case "$v" in
        v[0-9]) echo "${v}.0" ;;
        *) echo "$v" ;;
    esac
}

# Шаг 1: построить таблицу current_version по ARCH-документам
TMP_ARCH=$(mktemp)
TMP_DRIFT=$(mktemp)
TMP_OK=$(mktemp)
trap 'rm -f "$TMP_ARCH" "$TMP_DRIFT" "$TMP_OK"' EXIT

ARCH_GLOB="$IWE_ROOT/PACK-*/pack/*/02-domain-entities/DP.ARCH.*.md"
for f in $ARCH_GLOB; do
    [ -f "$f" ] || continue
    id=$(extract_arch_id "$f")
    ver=$(extract_arch_version "$f")
    # id может быть "DP.ARCH.004" или "DP.ARCH.004-decisions" — оба валидны
    [ -z "$id" ] && continue
    printf "%s\t%s\t%s\n" "$id" "$ver" "$f" >> "$TMP_ARCH"
done

# Шаг 2: пройти downstream-документы и найти якоря
# Глобы: PACK + DS-my-strategy/inbox
DOWNSTREAM_DIRS=(
    "$IWE_ROOT/PACK-digital-platform"
    "$IWE_ROOT/PACK-personal"
    "$IWE_ROOT/PACK-MIM"
    "$IWE_ROOT/DS-my-strategy/inbox"
)

drift_count=0
ok_count=0
unknown_count=0
missing_arch_version=0

for dir in "${DOWNSTREAM_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    # Все .md с derived_from в frontmatter
    while IFS= read -r downstream_file; do
        # Извлечь все DP.ARCH.NNN@vX.Y якоря из frontmatter (первые 30 строк файла достаточно)
        # Поддержка одиночной ссылки и списка [DP.ARCH.004@v2.3, DP.ARCH.005@v1]
        anchors=$(awk '
            /^---$/ { fm++; if (fm == 2) exit }
            fm == 1 && /derived_from:/ { capture = 1 }
            capture && /DP\.ARCH\./ {
                # извлечь все DP.ARCH.NNN[-suffix]@vX(.Y) совпадения из строки
                while (match($0, /DP\.ARCH\.[0-9]+(-[a-z0-9-]+)?@v[0-9]+(\.[0-9]+)?/)) {
                    print substr($0, RSTART, RLENGTH)
                    $0 = substr($0, RSTART + RLENGTH)
                }
            }
            capture && /^[a-z_]+:/ && !/derived_from:/ { capture = 0 }
        ' "$downstream_file")

        [ -z "$anchors" ] && continue

        while IFS= read -r anchor; do
            [ -z "$anchor" ] && continue
            arch_id="${anchor%@*}"
            arch_ver_raw="${anchor#*@}"
            arch_ver=$(normalize_ver "$arch_ver_raw")

            # Найти current version для arch_id
            current=$(awk -F'\t' -v id="$arch_id" '$1 == id { print $2; exit }' "$TMP_ARCH")

            relpath="${downstream_file#$IWE_ROOT/}"

            if [ -z "$current" ]; then
                printf "| %s | %s | unknown | UNKNOWN | ARCH-документ %s не найден |\n" \
                    "$relpath" "$arch_id@$arch_ver_raw" "$arch_id" >> "$TMP_DRIFT"
                unknown_count=$((unknown_count + 1))
            elif [ "$current" = "?" ]; then
                printf "| %s | %s | %s | NO-VERSION | ARCH без явного `version:` |\n" \
                    "$relpath" "$arch_id@$arch_ver_raw" "$current" >> "$TMP_DRIFT"
                missing_arch_version=$((missing_arch_version + 1))
            elif [ "$arch_ver" = "$current" ]; then
                printf "| %s | %s | %s | OK | — |\n" \
                    "$relpath" "$arch_id@$arch_ver_raw" "$current" >> "$TMP_OK"
                ok_count=$((ok_count + 1))
            else
                printf "| %s | %s | %s | DRIFT | downstream отстаёт |\n" \
                    "$relpath" "$arch_id@$arch_ver_raw" "$current" >> "$TMP_DRIFT"
                drift_count=$((drift_count + 1))
            fi
        done <<< "$anchors"
    done < <(grep -rl "^derived_from:" "$dir" 2>/dev/null | grep '\.md$' || true)
done

# Шаг 3: вывод
echo "## ARCH-version drift report ($(date +%Y-%m-%d))"
echo ""
echo "Source: WP-263 child WP-217. Manifest pair: \`arch-version-drift\`."
echo ""

# Реестр найденных ARCH
echo "### ARCH-документы (current versions)"
echo ""
echo "| ID | version | файл |"
echo "|---|---|---|"
while IFS=$'\t' read -r id ver file; do
    relpath="${file#$IWE_ROOT/}"
    printf "| %s | %s | %s |\n" "$id" "$ver" "$relpath"
done < "$TMP_ARCH"
echo ""

# Drift / unknown / missing-version
if [ -s "$TMP_DRIFT" ]; then
    echo "### Drift (требует sync)"
    echo ""
    echo "| downstream | anchor | current | статус | комментарий |"
    echo "|---|---|---|---|---|"
    cat "$TMP_DRIFT"
    echo ""
fi

# OK — только в полном режиме
if [ "$MODE" != "critical" ] && [ -s "$TMP_OK" ]; then
    echo "### OK (синхронизировано)"
    echo ""
    echo "| downstream | anchor | current | статус | комментарий |"
    echo "|---|---|---|---|---|"
    cat "$TMP_OK"
    echo ""
fi

# Сводка
echo "### Сводка"
echo ""
echo "- ✅ OK: $ok_count"
echo "- ⚠️ DRIFT: $drift_count"
echo "- ❓ UNKNOWN (ARCH не найден): $unknown_count"
echo "- ⚠️ NO-VERSION (ARCH без \`version:\`): $missing_arch_version"

if [ "$drift_count" -gt 0 ] || [ "$missing_arch_version" -gt 0 ]; then
    exit 2
fi
