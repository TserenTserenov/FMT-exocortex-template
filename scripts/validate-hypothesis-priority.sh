#!/usr/bin/env bash
# validate-hypothesis-priority.sh — check of the p= field in hypothesis log entries
# see memory/lpf-hypothesis-log.md «Шкала приоритета»
#
# Checks that every machine contract of the form
#   <!-- h id=H-NNN p=<value> due=... status=... -->
# uses a p= value from the allowed set (П1, П2, П3, П4).
# Does not check the other contract fields — only priority.
#
# Parser boundary (cold-context review): the contract is searched via
# `[^>]*-->` — this breaks if ANY field contains the literal substring
# "-->" (parsing would cut at this inner match before the real
# terminator). Currently unreachable: the contract grammar (see
# «События и машинный контракт» in lpf-hypothesis-log.md) is only flat
# key=value without free text. If the contract ever gets
# a text field (e.g. note=/reason=) — this boundary becomes real.
#
# Usage:
#   bash validate-hypothesis-priority.sh <path-to-hypothesis-log-file>
#
# Exit 0 = all found p= values are valid (or there are no contracts in the file)
# Exit 1 = at least one invalid p= value found

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
