#!/usr/bin/env bash
# routing: helper  skill=audit-installation  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# memory-validate.sh — validate frontmatter of memory/*.md (WP-217 Phase 10.2)
#
# Checks: frontmatter presence, required fields, allowed values,
# invariants (superseded → superseded_by, schema_version = 1).
#
# Usage:
#   bash scripts/memory-validate.sh                     # all memory/*.md
#   bash scripts/memory-validate.sh memory/file.md      # one file
#   bash scripts/memory-validate.sh --dir PATH          # another directory
#   bash scripts/memory-validate.sh --quiet             # FAIL lines only
#
# Exit code: 0 = all OK, 1 = there are violations.
# Spec: memory/memory-lifecycle-spec.md §3 (WP-217 Phase 10.1)

set -eu

# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
# NOTE: iwe-env-bootstrap.sh reassigns SCRIPT_DIR to its OWN location (via its
# BASH_SOURCE[0]) as a side effect of being sourced — save ours first so the
# frontmatter.sh source below still resolves relative to THIS script (issue #229).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MEMORY_VALIDATE_DIR="$SCRIPT_DIR"
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
source "$_MEMORY_VALIDATE_DIR/../.claude/lib/frontmatter.sh" || exit 1
MEMORY_DIR="$IWE_ROOT/memory"
QUIET=0
TARGET=""

# Exclusion files (indexes, not memory objects)
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

# Check for frontmatter presence
has_frontmatter() {
    local file="$1"
    head -1 "$file" | grep -q '^---$'
}

validate_file() {
    local file="$1"
    local errors=0
    local errs=""

    # Check 1: frontmatter presence
    if ! has_frontmatter "$file"; then
        errs="$errs\n  ❌ нет frontmatter (файл должен начинаться с ---)"
        errors=$((errors + 1))
        # Without frontmatter we do not check further
        printf "FAIL %s%b\n" "$file" "$errs"
        return 1
    fi

    # Check 2: all required fields are present
    for field in $REQUIRED_FIELDS; do
        val=$(get_field "$file" "$field")
        if [ -z "$val" ]; then
            errs="$errs\n  ❌ отсутствует обязательное поле: $field"
            errors=$((errors + 1))
        fi
    done

    # Check 2b (#513): the canonical form is flat. A nested metadata:
    # (written by the Claude Code system instruction, cannot be forbidden) is read by
    # a single reader; a conflict «one key in both forms with different
    # values» is an error, silent priority is forbidden.
    if awk '/^---/{f++; next} f!=1{next} /^metadata:[ \t\r]*$/{found=1; exit} END{exit !found}' "$file"; then
        for field in $REQUIRED_FIELDS; do
            flat=$(awk '/^---/{f++; next} f!=1{next} /^'"$field"':/{gsub(/^[^:]+: */,""); gsub(/["'"'"']/,""); print; exit}' "$file")
            nested=$(awk '/^---/{f++; next} f!=1{next} /^metadata:[ \t\r]*$/{m=1; next} m && /^[^ \t]/{m=0} m && /^[ \t]+'"$field"':/{gsub(/^[ \t]*[^:]+: */,""); gsub(/["'"'"']/,""); print; exit}' "$file")
            if [ -n "$flat" ] && [ -n "$nested" ] && [ "$flat" != "$nested" ]; then
                errs="$errs\n  ❌ конфликт форм: '$field' задан и плоско ('$flat'), и в metadata: ('$nested')"
                errors=$((errors + 1))
            fi
        done
        [ "${QUIET:-0}" -eq 0 ] && echo "  ℹ️  $file: вложенная форма metadata: (канонична плоская — spec §3); reader нормализует, перезапись сериализует плоско"
    fi

    # Check 3: allowed values of type
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

    # Check 4: allowed values of horizon
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

    # Check 5: allowed values of status
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

    # Check 6: valid_from format YYYY-MM-DD
    valid_from=$(get_field "$file" "valid_from")
    if [ -n "$valid_from" ]; then
        if ! echo "$valid_from" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
            errs="$errs\n  ❌ valid_from='$valid_from' не соответствует формату YYYY-MM-DD"
            errors=$((errors + 1))
        fi
    fi

    # Check 7: invariant superseded → superseded_by is mandatory
    if [ "$status_val" = "superseded" ]; then
        superseded_by=$(get_field "$file" "superseded_by")
        if [ -z "$superseded_by" ]; then
            errs="$errs\n  ❌ status=superseded но поле superseded_by отсутствует"
            errors=$((errors + 1))
        fi
    fi

    # Check 8: schema_version = 1
    schema_ver=$(get_field "$file" "schema_version")
    if [ -n "$schema_ver" ] && [ "$schema_ver" != "1" ]; then
        errs="$errs\n  ⚠️  schema_version=$schema_ver (текущая=1, нужна миграция через memory-migrate.sh)"
    fi

    # Check 9 (issue #736, design session with Codex): type=lesson without review_at
    # or without a generalization to future behavior is a chronicle of a single incident,
    # not a systemic lesson. We stop writing such a file at creation time,
    # without relying on later cleanup (spec §3 invariants).
    if [ "$type_val" = "lesson" ]; then
        review_at=$(get_field "$file" "review_at")
        if [ -z "$review_at" ]; then
            errs="$errs\n  ❌ type=lesson но поле review_at отсутствует (spec §3)"
            errors=$((errors + 1))
        elif ! echo "$review_at" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
            errs="$errs\n  ❌ review_at='$review_at' не соответствует формату YYYY-MM-DD"
            errors=$((errors + 1))
        fi
        if ! grep -qE '\*\*(Как применять|How to apply):\*\*' "$file"; then
            errs="$errs\n  ❌ type=lesson но в тексте нет маркера **Как применять:** / **How to apply:** (spec §3)"
            errors=$((errors + 1))
        fi
    fi

    if [ $errors -eq 0 ]; then
        [ $QUIET -eq 0 ] && printf "OK   %s\n" "$file"
        return 0
    else
        printf "FAIL %s%b\n" "$file" "$errs"
        return 1
    fi
}

# Main loop
total=0
failed=0

if [ -n "$TARGET" ]; then
    files="$TARGET"
else
    files=$(find "$MEMORY_DIR/" -maxdepth 1 -name "*.md" | sort)
fi

for f in $files; do
    [ -f "$f" ] || continue
    # Skip exclusion files (indexes)
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
