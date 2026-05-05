#!/bin/bash
# template-sync.sh — синхронизация CLAUDE.md из авторского IWE в FMT-exocortex-template
#
# Flow: $IWE_WORKSPACE/CLAUDE.md → placeholder sub → strip §9 авторское → FMT/CLAUDE.md
#
# Использование:
#   ./template-sync.sh            # синхронизировать
#   ./template-sync.sh --dry-run  # показать diff без записи
#   ./template-sync.sh --check    # проверить drift (exit 0 = OK, exit 1 = drift)

set -euo pipefail

IWE="${IWE_WORKSPACE:-$HOME/IWE}"
FMT_DIR="${IWE_TEMPLATE:-$IWE/FMT-exocortex-template}"
SRC="$IWE/CLAUDE.md"
FMT="$FMT_DIR/CLAUDE.md"

# Авторское имя governance-репо (из env, обязательно) → template default
GOV_REPO_AUTHOR="${IWE_GOVERNANCE_REPO:?IWE_GOVERNANCE_REPO must be set (your governance repo name, e.g. DS-strategy)}"
GOV_REPO_TMPL="DS-strategy"

# Граница §9 (авторское — не идёт в шаблон)
AUTHOR_SECTION="^## 9\. Авторское"

dry_run=false
check_only=false
case "${1:-}" in
    --dry-run) dry_run=true ;;
    --check)   check_only=true ;;
    "") ;;
    *) echo "Usage: $0 [--dry-run|--check]" >&2; exit 1 ;;
esac

# 1. Извлечь §1-§8 из runtime (до границы §9)
l18=$(awk "/$AUTHOR_SECTION/{exit} {print}" "$SRC")

# 2. Применить placeholder-подстановки
l18_tmpl=$(printf '%s' "$l18" \
    | sed "s|$HOME|{{HOME_DIR}}|g" \
    | sed "s|~/IWE|{{HOME_DIR}}/IWE|g" \
    | sed "s|$GOV_REPO_AUTHOR|$GOV_REPO_TMPL|g")

# 3. Взять §9 из FMT без изменений (шаблонная версия, не авторская)
l9=$(awk "/$AUTHOR_SECTION/{found=1} found{print}" "$FMT")

# 4. Собрать результат
result="${l18_tmpl}
${l9}"

if $check_only; then
    if diff <(printf '%s\n' "$result") "$FMT" > /dev/null 2>&1; then
        echo "OK: FMT/CLAUDE.md синхронен с runtime"
        exit 0
    else
        echo "DRIFT: FMT/CLAUDE.md не синхронен с runtime"
        diff <(printf '%s\n' "$result") "$FMT" || true
        exit 1
    fi
fi

if $dry_run; then
    diff <(printf '%s\n' "$result") "$FMT" || true
    exit 0
fi

printf '%s\n' "$result" > "$FMT"
echo "✅ Синхронизировано: CLAUDE.md → FMT/CLAUDE.md"
echo "Следующий шаг:"
echo "  cd $FMT_DIR && git diff CLAUDE.md && git add CLAUDE.md && git commit"
