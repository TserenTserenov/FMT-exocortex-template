#!/usr/bin/env bash
# routing: helper  skill=notify-update,validate-template
# changelog-diff-lines.sh — извлекает добавленные строки CHANGELOG.md за
# диапазон коммитов, с опциональным фильтром по бирке [security].
#
# Единая логика для .github/workflows/notify-security.yml (push) и
# validate-template.yml (push + pull_request) — WP-7 Ф62 п.4. Выделена из
# трёх независимых копий, найденных code review 13.08.2026 (DP.SC.172 P2:
# третье повторение → функция); там же найден баг дублирования — голый
# `grep '\[security\]'` матчил подстроку где угодно в тексте коммита, не
# только позицию бирки-префикса (ложные "🔒 срочно"-алерты на коммитах вида
# "fix: drop obsolete [security]-only migration shim").
#
# Использование:
#   bash changelog-diff-lines.sh <base-sha|""> [--security-only]
#
# base-sha пустой или все нули → нет валидной base (initial push/новая
# ветка): берём весь верхний блок CHANGELOG.md (до следующего "## [").

set -uo pipefail

FMT_DIR="${IWE_TEMPLATE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CHANGELOG="$FMT_DIR/CHANGELOG.md"
base="${1:-}"
security_only=false
[[ "${2:-}" == "--security-only" ]] && security_only=true

if [[ ! -f "$CHANGELOG" ]]; then
    echo "ERROR: CHANGELOG.md is missing: $CHANGELOG" >&2
    exit 1
fi

if [[ -z "$base" || "$base" == "0000000000000000000000000000000000000000" ]]; then
    if ! lines=$(awk '/^## \[/{n++} n==1' "$CHANGELOG"); then
        echo "ERROR: CHANGELOG.md extraction failed" >&2
        exit 1
    fi
else
    if ! diff_output=$(git -C "$FMT_DIR" diff --unified=0 "$base"..HEAD -- CHANGELOG.md 2>&1); then
        echo "ERROR: git diff failed (base=$base): $diff_output" >&2
        exit 1
    fi
    if ! lines=$(printf '%s\n' "$diff_output" | awk '
        substr($0, 1, 1) == "+" && substr($0, 1, 3) != "+++" { print substr($0, 2) }
    '); then
        echo "ERROR: CHANGELOG diff parsing failed" >&2
        exit 1
    fi
fi

if $security_only; then
    # Якорим на позицию бирки-префикса ("- [security] "), не голую подстроку.
    if ! lines=$(printf '%s\n' "$lines" | awk '/^- \[security\] /'); then
        echo "ERROR: CHANGELOG security filter failed" >&2
        exit 1
    fi
fi

printf '%s\n' "$lines"
