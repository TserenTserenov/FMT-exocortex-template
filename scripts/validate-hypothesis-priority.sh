#!/usr/bin/env bash
# validate-hypothesis-priority.sh — validation of field p= in hypothesis log entries
# see memory/lpf-hypothesis-log.md «Priority scale»
#
# Verifies, that every machine contract of the form
#   <!-- h id=H-NNN p=<value> due=... status=... -->
# uses a value of p= from the allowed set p= from the allowed set (P1, P2, P3, P4).
# Does not validate the remaining contract fields — priority only.
#
# Parser boundary (cold-context review): the contract is located via
# `[^>]*-->` — this breaks, if ANY field contains the literal substring
# "-->" (parsing will be cut short at that inner match before the actual
# terminator). Currently unreachable: contract grammar (see.
# «Events and machine contract» in lpf-hypothesis-log.md) — flat only
# key=value without free-form text. If the contract ever-gains
# a text field (for example note=/reason=) — this boundary will become real.
#
# Usage:
#   bash validate-hypothesis-priority.sh <path-to-hypothesis-log-file>
#
# Exit 0 = all found values p= are valid (or no contracts found in file)
# Exit 1 = at least one invalid value found p=

set -euo pipefail

file="${1:-}"
if [[ -z "$file" ]]; then
    echo "Usage: $0 <path-to-hypothesis-log-file>" >&2
    exit 1
fi
if [[ ! -f "$file" ]]; then
    echo "❌ File not found: $file" >&2
    exit 1
fi

VALID_VALUES=("P1" "P2" "P3" "P4")

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
        echo "  ❌ empty value p= on line: $line" >&2
        errors=$((errors + 1))
        continue
    fi
    if ! is_valid "$value"; then
        echo "  ❌ invalid value p=$value (valid values: ${VALID_VALUES[*]}) on line: $line" >&2
        errors=$((errors + 1))
    fi
done < <(grep -oE '<!--\s*h\s+id=[^>]*-->' "$file")

if (( contracts_found == 0 )); then
    echo "  ℹ️  contracts with field p= not found in file"
    exit 0
fi

if (( errors > 0 )); then
    echo "❌ found $errors invalid priority values out of $contracts_found contracts" >&2
    exit 1
fi

echo "✅ all $contracts_found priority values are valid"
exit 0
