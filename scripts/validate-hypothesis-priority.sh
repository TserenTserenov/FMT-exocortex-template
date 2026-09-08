#!/usr/bin/env bash
# validate-hypothesis-priority.sh — проверка поля p= в записях журнала гипотез
# see memory/lpf-hypothesis-log.md «Шкала приоритета»
#
# Проверяет, что каждый машинный контракт вида
#   <!-- h id=H-NNN p=<value> due=... status=... -->
# использует значение p= из допустимого множества (П1, П2, П3, П4).
# Не проверяет остальные поля контракта — только приоритет.
#
# Граница парсера (cold-context review): контракт ищется через
# `[^>]*-->` — это ломается, если ЛЮБОЕ поле содержит буквальную подстроку
# "-->" (парсинг обрежется на этом внутреннем совпадении раньше настоящего
# терминатора). Сейчас недостижимо: грамматика контракта (см.
# «События и машинный контракт» в lpf-hypothesis-log.md) — только плоские
# key=value без свободного текста. Если контракт когда-нибудь получит
# текстовое поле (например note=/reason=) — эта граница станет реальной.
#
# Использование:
#   bash validate-hypothesis-priority.sh <path-to-hypothesis-log-file>
#
# Exit 0 = все найденные значения p= допустимы (или контрактов в файле нет)
# Exit 1 = найдено хотя бы одно недопустимое значение p=

set -euo pipefail

file="${1:-}"
if [[ -z "$file" ]]; then
    echo "Использование: $0 <path-to-hypothesis-log-file>" >&2
    exit 1
fi
if [[ ! -f "$file" ]]; then
    echo "❌ Файл не найден: $file" >&2
    exit 1
fi

VALID_VALUES=("П1" "П2" "П3" "П4")

is_valid() {
    local value="$1"
    for v in "${VALID_VALUES[@]}"; do
        [[ "$value" == "$v" ]] && return 0
    done
    return 1
}

errors=0
contracts_found=0

while IFS= read -r line; do
    [[ "$line" =~ p=([^[:space:]\-]*) ]] || continue
    contracts_found=$((contracts_found + 1))
    value="${BASH_REMATCH[1]}"
    if [[ -z "$value" ]]; then
        echo "  ❌ пустое значение p= в строке: $line" >&2
        errors=$((errors + 1))
        continue
    fi
    if ! is_valid "$value"; then
        echo "  ❌ недопустимое значение p=$value (допустимы: ${VALID_VALUES[*]}) в строке: $line" >&2
        errors=$((errors + 1))
    fi
done < <(grep -oE '<!--\s*h\s+id=[^>]*-->' "$file")

if (( contracts_found == 0 )); then
    echo "  ℹ️  контрактов с полем p= в файле не найдено"
    exit 0
fi

if (( errors > 0 )); then
    echo "❌ найдено $errors недопустимых значений приоритета из $contracts_found контрактов" >&2
    exit 1
fi

echo "✅ все $contracts_found значений приоритета допустимы"
exit 0
