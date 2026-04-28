#!/usr/bin/env bash
# iwe-audit.sh — оркестратор аудита инсталляции IWE
#
# WP-265 Ф2, 2026-04-26.
# Service Clause: PACK-verification/.../08-service-clauses/VR.SC.005-installation-audit.md
#
# РОЛЬ: R8 Синхронизатор — собирает 3 детерминированных раздела
# (Inventory, L1 drift, DS-strategy) и формирует markdown-отчёт.
# Раздел 4 (MCP healthcheck) и verdict в роли VR.R.002 Аудитор —
# зона скилла-обёртки `/audit-installation`, не этого скрипта.
#
# Принцип «детектор отчитывается, оператор делает» (см. iwe-drift.sh:7-11):
# скрипт ТОЛЬКО детектит и пишет markdown. Никаких автофиксов.
#
# Usage:
#   bash iwe-audit.sh                  # полный отчёт
#   bash iwe-audit.sh --critical       # передать --critical в iwe-drift.sh
#   bash iwe-audit.sh --root PATH      # указать $IWE_ROOT (default: $HOME/IWE)
#   bash iwe-audit.sh -h | --help
#
# Exit code:
#   0 — всё ОК
#   1 — warnings (отсутствует ≤2 опциональных файла)
#   2 — критичные gaps (≥1 обязательного файла нет)
#
# Требования: bash, git, stat, awk (POSIX). Без внешних зависимостей.
# macOS-совместимо (stat -f vs stat -c — детектится в runtime).

set -eu

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
DRIFT_CRITICAL=""

while [ $# -gt 0 ]; do
    case "$1" in
        --critical) DRIFT_CRITICAL="--critical"; shift ;;
        --root) IWE_ROOT="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | head -28
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [ ! -d "$IWE_ROOT" ]; then
    echo "IWE_ROOT not found: $IWE_ROOT" >&2
    exit 2
fi

# ---------- Helpers ----------

# Проверка существования файла/директории/симлинка с разрешением симлинков.
# Возвращает 0 если есть (любой тип), 1 иначе.
exists_any() {
    local p="$1"
    [ -e "$p" ] || [ -L "$p" ]
}

# Печать строки таблицы для inventory.
# Аргументы: путь (относительно IWE_ROOT), required (1/0), note
emit_inventory_row() {
    local rel="$1"
    local required="$2"
    local note="${3:-}"
    local abs="$IWE_ROOT/$rel"
    local status

    if exists_any "$abs"; then
        status="✅"
        if [ -L "$abs" ] && [ -z "$note" ]; then
            note="symlink"
        fi
        FOUND=$((FOUND + 1))
    else
        if [ "$required" = "1" ]; then
            status="❌"
            CRITICAL_MISSING=$((CRITICAL_MISSING + 1))
        else
            status="⚠️"
            OPTIONAL_MISSING=$((OPTIONAL_MISSING + 1))
        fi
    fi
    TOTAL=$((TOTAL + 1))
    printf "| \`%s\` | %s | %s |\n" "$rel" "$status" "$note"
}

# ---------- Заголовок ----------

NOW=$(date '+%Y-%m-%d %H:%M')
echo "# IWE Installation Audit — $NOW"
echo ""
echo "_Root:_ \`$IWE_ROOT\`"
echo ""

# ---------- Раздел 1: Inventory ----------

echo "## 1. Inventory (структура файлов)"
echo ""
echo "| Файл | Статус | Примечание |"
echo "|---|---|---|"

TOTAL=0
FOUND=0
CRITICAL_MISSING=0
OPTIONAL_MISSING=0

# CLAUDE.md — обязателен
emit_inventory_row "CLAUDE.md" 1 ""

# MEMORY.md — обязателен; может быть симлинком на auto-memory
# В этой инсталляции MEMORY.md живёт в memory/ — проверяем оба варианта
if exists_any "$IWE_ROOT/MEMORY.md"; then
    emit_inventory_row "MEMORY.md" 1 ""
elif exists_any "$IWE_ROOT/memory/MEMORY.md"; then
    # MEMORY.md в memory/ — это auto-memory layout
    TOTAL=$((TOTAL + 1))
    FOUND=$((FOUND + 1))
    printf "| \`%s\` | %s | %s |\n" "MEMORY.md" "✅" "в memory/MEMORY.md (auto-memory layout)"
else
    TOTAL=$((TOTAL + 1))
    CRITICAL_MISSING=$((CRITICAL_MISSING + 1))
    printf "| \`%s\` | %s | %s |\n" "MEMORY.md" "❌" "не найден ни в корне, ни в memory/"
fi

# .claude/sync-manifest.yaml — обязателен (источник для iwe-drift)
emit_inventory_row ".claude/sync-manifest.yaml" 1 ""

# Правила
emit_inventory_row ".claude/rules/distinctions.md" 1 ""
emit_inventory_row ".claude/rules/formatting.md" 1 ""

# Скиллы (минимум day-open / day-close)
emit_inventory_row ".claude/skills/day-open/SKILL.md" 1 ""
emit_inventory_row ".claude/skills/day-close/SKILL.md" 1 ""

# Протоколы
emit_inventory_row "memory/protocol-open.md" 1 ""
emit_inventory_row "memory/protocol-work.md" 1 ""
emit_inventory_row "memory/protocol-close.md" 1 ""

# Скрипты
# update.sh ЖИВЁТ ТОЛЬКО в FMT-exocortex-template/update.sh для всех режимов
# (он сам резолвит SCRIPT_DIR=FMT-template, WORKSPACE_DIR=parent). Никогда не
# пропагируется в workspace/scripts/. Аналогично iwe-drift.sh: для user-mode
# живёт только в FMT-template/scripts/, в author-mode дублируется в workspace/scripts/.
AUTHOR_MODE=0
if [ -f "$IWE_ROOT/params.yaml" ] && grep -qE "^author_mode:[[:space:]]*true" "$IWE_ROOT/params.yaml"; then
    AUTHOR_MODE=1
fi

# update.sh — всегда в FMT-template (для обоих режимов)
TOTAL=$((TOTAL + 1))
if exists_any "$IWE_ROOT/FMT-exocortex-template/update.sh"; then
    FOUND=$((FOUND + 1))
    printf "| \`%s\` | %s | %s |\n" "FMT-exocortex-template/update.sh" "✅" "self-update запускается отсюда"
else
    CRITICAL_MISSING=$((CRITICAL_MISSING + 1))
    printf "| \`%s\` | %s | %s |\n" "FMT-exocortex-template/update.sh" "❌" "не найден — обновления невозможны"
fi

# iwe-drift.sh: проверяем оба возможных места (user-mode → только FMT-template, author-mode → оба)
TOTAL=$((TOTAL + 1))
DRIFT_FMT="$IWE_ROOT/FMT-exocortex-template/scripts/iwe-drift.sh"
DRIFT_WS="$IWE_ROOT/scripts/iwe-drift.sh"
if exists_any "$DRIFT_FMT"; then
    FOUND=$((FOUND + 1))
    if [ "$AUTHOR_MODE" = "1" ] && exists_any "$DRIFT_WS"; then
        printf "| \`%s\` | %s | %s |\n" "scripts/iwe-drift.sh" "✅" "author_mode: workspace + FMT (template-sync экспортирует workspace → FMT)"
    else
        printf "| \`%s\` | %s | %s |\n" "scripts/iwe-drift.sh" "✅" "FMT-exocortex-template/scripts/iwe-drift.sh (source-of-truth для user-mode)"
    fi
elif exists_any "$DRIFT_WS"; then
    FOUND=$((FOUND + 1))
    printf "| \`%s\` | %s | %s |\n" "scripts/iwe-drift.sh" "⚠️" "только в workspace/scripts/ (FMT-template отсутствует)"
else
    CRITICAL_MISSING=$((CRITICAL_MISSING + 1))
    printf "| \`%s\` | %s | %s |\n" "scripts/iwe-drift.sh" "❌" "не найден ни в FMT-template, ни в workspace"
fi

# params.yaml — конфиг
emit_inventory_row "params.yaml" 1 ""

# DS-strategy — директория с .git
DS_DIR="$IWE_ROOT/DS-strategy"
TOTAL=$((TOTAL + 1))
if [ -d "$DS_DIR" ]; then
    if [ -d "$DS_DIR/.git" ]; then
        FOUND=$((FOUND + 1))
        printf "| \`%s\` | %s | %s |\n" "DS-strategy/" "✅" "git-репо (is_git=true)"
    else
        OPTIONAL_MISSING=$((OPTIONAL_MISSING + 1))
        printf "| \`%s\` | %s | %s |\n" "DS-strategy/" "⚠️" "директория есть, но не git-репо"
    fi
else
    CRITICAL_MISSING=$((CRITICAL_MISSING + 1))
    printf "| \`%s\` | %s | %s |\n" "DS-strategy/" "❌" "директория не найдена"
fi

echo ""
echo "**coverage:** $FOUND/$TOTAL (отсутствует: критичных=$CRITICAL_MISSING, опциональных=$OPTIONAL_MISSING)"
echo ""

# ---------- Раздел 2: L1 drift ----------

echo "## 2. L1 drift (платформа vs FMT)"
echo ""

# Ищем iwe-drift.sh: предпочитаем workspace (author-mode source-of-truth), фоллбэк на FMT-template (user-mode).
DRIFT_SCRIPT="$IWE_ROOT/scripts/iwe-drift.sh"
if [ ! -f "$DRIFT_SCRIPT" ] && [ -f "$IWE_ROOT/FMT-exocortex-template/scripts/iwe-drift.sh" ]; then
    DRIFT_SCRIPT="$IWE_ROOT/FMT-exocortex-template/scripts/iwe-drift.sh"
fi
if [ -f "$DRIFT_SCRIPT" ]; then
    # Не валим весь скрипт если iwe-drift падает — set -eu выключаем точечно
    set +e
    if [ -n "$DRIFT_CRITICAL" ]; then
        bash "$DRIFT_SCRIPT" --critical
        DRIFT_RC=$?
    else
        bash "$DRIFT_SCRIPT"
        DRIFT_RC=$?
    fi
    set -e
    if [ $DRIFT_RC -ne 0 ]; then
        echo ""
        echo "_iwe-drift.sh exit code: $DRIFT_RC_"
    fi
else
    echo "❌ \`scripts/iwe-drift.sh\` не найден — drift-сверка пропущена"
fi
echo ""

# ---------- Раздел 3: DS-strategy ----------

echo "## 3. DS-strategy"
echo ""

if [ ! -d "$DS_DIR/.git" ]; then
    echo "❌ \`DS-strategy\` не git-репо (или директория отсутствует)"
else
    set +e
    DS_STATUS=$(git -C "$DS_DIR" status --short 2>&1)
    DS_STATUS_RC=$?
    set -e

    if [ $DS_STATUS_RC -ne 0 ]; then
        echo "⚠️ \`git status\` упал (rc=$DS_STATUS_RC):"
        echo ""
        echo '```'
        echo "$DS_STATUS"
        echo '```'
    else
        if [ -z "$DS_STATUS" ]; then
            DS_CHANGES_COUNT=0
        else
            DS_CHANGES_COUNT=$(printf '%s\n' "$DS_STATUS" | wc -l | tr -d ' ')
        fi
        echo "**Uncommitted changes:** $DS_CHANGES_COUNT"
        if [ "$DS_CHANGES_COUNT" -gt 0 ]; then
            echo ""
            echo '```'
            # Показываем не больше 30 строк, чтобы не раздувать отчёт
            printf '%s\n' "$DS_STATUS" | head -30
            if [ "$DS_CHANGES_COUNT" -gt 30 ]; then
                echo "... (ещё $((DS_CHANGES_COUNT - 30)) строк)"
            fi
            echo '```'
        fi
    fi

    echo ""
    echo "### Diff с FMT-strategy-template"
    echo ""

    # Шаблон ищется в двух местах:
    # (1) {{WORKSPACE_DIR}}/FMT-strategy-template/ — отдельная директория (авторская)
    # (2) {{WORKSPACE_DIR}}/FMT-exocortex-template/templates/strategy-skeleton/ — внутри FMT (приезжает через update.sh)
    FMT_DIR="$IWE_ROOT/FMT-strategy-template"
    if [ ! -d "$FMT_DIR" ] && [ -d "$IWE_ROOT/FMT-exocortex-template/templates/strategy-skeleton" ]; then
        FMT_DIR="$IWE_ROOT/FMT-exocortex-template/templates/strategy-skeleton"
    fi
    if [ ! -d "$FMT_DIR" ]; then
        echo "_N/A — шаблон не найден ни в \`FMT-strategy-template/\`, ни в \`FMT-exocortex-template/templates/strategy-skeleton/\`._"
    else
        echo "_Источник шаблона: \`${FMT_DIR#$IWE_ROOT/}\`_"
        echo ""
        set +e
        FMT_DIFF=$(diff -rq "$DS_DIR/" "$FMT_DIR/" 2>&1)
        FMT_DIFF_RC=$?
        set -e

        if [ -z "$FMT_DIFF" ]; then
            echo "_Нет файловых различий._"
        else
            FMT_DIFF_COUNT=$(printf '%s\n' "$FMT_DIFF" | wc -l | tr -d ' ')
            echo "**Различий (файловый уровень):** $FMT_DIFF_COUNT (показаны топ-30)"
            echo ""
            echo '```'
            printf '%s\n' "$FMT_DIFF" | head -30
            if [ "$FMT_DIFF_COUNT" -gt 30 ]; then
                echo "... (ещё $((FMT_DIFF_COUNT - 30)) строк)"
            fi
            echo '```'
        fi
    fi
fi

echo ""

# ---------- Раздел 4: User customizations (L3) ----------
#
# L3 живёт в 3-х местах: extensions/, params.yaml (отличия от skeleton),
# AUTHOR-ONLY зоны в .claude/rules/distinctions.md.
# Цель — показать, что после restore личные кастомизации на месте.
# Это **информационная** секция: отсутствие L3 ≠ failure (новый пилот ещё
# ничего не настроил). Verdict выносит Аудитор содержательно.

echo "## 4. User customizations (L3)"
echo ""

# 4a. extensions/
EXT_DIR="$IWE_ROOT/extensions"
echo "### Extensions"
echo ""
if [ ! -d "$EXT_DIR" ]; then
    echo "_extensions/ директория отсутствует — расширения не настроены_"
else
    set +e
    EXT_FILES=$(find "$EXT_DIR" -maxdepth 1 -type f -name "*.md" ! -name "README.md" 2>/dev/null | sort)
    set -e
    if [ -z "$EXT_FILES" ]; then
        echo "_В extensions/ только README — пользовательских хуков нет_"
    else
        EXT_COUNT=$(printf '%s\n' "$EXT_FILES" | wc -l | tr -d ' ')
        echo "**Найдено хуков:** $EXT_COUNT"
        echo ""
        echo "| Hook | Размер |"
        echo "|---|---|"
        printf '%s\n' "$EXT_FILES" | while read -r ext_file; do
            ext_name=$(basename "$ext_file")
            ext_size=$(wc -l < "$ext_file" | tr -d ' ')
            printf "| \`%s\` | %s строк |\n" "$ext_name" "$ext_size"
        done
    fi
fi
echo ""

# 4b. params.yaml — отличия от skeleton
echo "### params.yaml — отличия от шаблона"
echo ""
PARAMS_USER="$IWE_ROOT/params.yaml"
PARAMS_TEMPLATE="$IWE_ROOT/FMT-exocortex-template/params.yaml"
if [ ! -f "$PARAMS_USER" ]; then
    echo "_params.yaml не найден — конфигурация не инициализирована_"
elif [ ! -f "$PARAMS_TEMPLATE" ]; then
    echo "_FMT-exocortex-template/params.yaml не найден — сравнение невозможно_"
else
    set +e
    # Игнорируем комментарии и пустые строки при сравнении
    PARAMS_DIFF=$(diff <(grep -vE '^\s*(#|$)' "$PARAMS_TEMPLATE" | sort) \
                       <(grep -vE '^\s*(#|$)' "$PARAMS_USER" | sort) 2>&1)
    set -e
    if [ -z "$PARAMS_DIFF" ]; then
        echo "_Полное совпадение со skeleton._"
    else
        PARAMS_DIFF_LINES=$(printf '%s\n' "$PARAMS_DIFF" | wc -l | tr -d ' ')
        echo "**Отличий:** $PARAMS_DIFF_LINES строк (показаны топ-15)"
        echo ""
        echo '```diff'
        printf '%s\n' "$PARAMS_DIFF" | head -15
        echo '```'
    fi
fi
echo ""

# 4c. AUTHOR-ONLY зоны в distinctions.md
echo "### AUTHOR-ONLY зоны"
echo ""
DIST_FILE="$IWE_ROOT/.claude/rules/distinctions.md"
if [ ! -f "$DIST_FILE" ]; then
    echo "_distinctions.md не найден_"
else
    # Считаем строки внутри блоков <!-- AUTHOR-ONLY --> ... <!-- /AUTHOR-ONLY -->
    # ИЛИ под заголовком "## Различения (авторские" (текущая авторская конвенция)
    # grep -c возвращает rc=1 при 0 матчей, что в связке с || echo даёт "0\n0"
    set +e
    AUTHOR_HEADER=$(grep -c "^## Различения (авторские" "$DIST_FILE" 2>/dev/null)
    AUTHOR_BLOCKS=$(grep -c "<!-- AUTHOR-ONLY" "$DIST_FILE" 2>/dev/null)
    set -e
    [ -z "$AUTHOR_HEADER" ] && AUTHOR_HEADER=0
    [ -z "$AUTHOR_BLOCKS" ] && AUTHOR_BLOCKS=0
    if [ "$AUTHOR_HEADER" -eq 0 ] && [ "$AUTHOR_BLOCKS" -eq 0 ]; then
        echo "_Авторских/L3-различений не найдено (нормально для нового пилота)_"
    else
        echo "✅ Найдены маркеры L3:"
        [ "$AUTHOR_HEADER" -gt 0 ] && echo "- секция \`## Различения (авторские)\` присутствует"
        [ "$AUTHOR_BLOCKS" -gt 0 ] && echo "- блоков \`<!-- AUTHOR-ONLY -->\`: $AUTHOR_BLOCKS"
    fi
fi
echo ""

# ---------- Раздел 5: Update prerequisites ----------
#
# Проверяем предусловия успешного запуска update.sh, не запуская его сам.
# Цель — диагностировать «почему update упадёт» ДО запуска (Q7 РП-265).
# Не failure для всего аудита: отсутствие prereq → ⚠️ warning, пилот сам решает.

echo "## 5. Update prerequisites"
echo ""

UPD_WARN=0
UPD_FAIL=0

echo "### Бинарники"
echo ""
echo "| Бинарник | Статус | Путь |"
echo "|---|---|---|"
for bin in git curl python3; do
    set +e
    BIN_PATH=$(command -v "$bin" 2>/dev/null)
    set -e
    if [ -n "$BIN_PATH" ]; then
        printf "| \`%s\` | ✅ | %s |\n" "$bin" "$BIN_PATH"
    else
        printf "| \`%s\` | ❌ | — |\n" "$bin"
        UPD_FAIL=$((UPD_FAIL + 1))
    fi
done
echo ""

echo "### Конфигурация (.exocortex.env)"
echo ""
# WP-273: setup.sh ≥0.7.0 сохраняет .exocortex.env в $IWE_ROOT/, не в $HOME/
if [ -f "$IWE_ROOT/.exocortex.env" ]; then
    ENV_FILE="$IWE_ROOT/.exocortex.env"
else
    ENV_FILE="$HOME/.exocortex.env"  # legacy: installs before setup.sh ≥0.7.0
fi
if [ ! -f "$ENV_FILE" ]; then
    if [ "$AUTHOR_MODE" = "1" ]; then
        echo "ℹ️ \`.exocortex.env\` не нужен в author_mode (плейсхолдеры подставляются template-sync.sh, не update.sh)."
    else
        echo "❌ Файл \`.exocortex.env\` отсутствует — update.sh не сможет подставить плейсхолдеры. Решение: запустить \`bash $IWE_ROOT/setup.sh\`."
        UPD_FAIL=$((UPD_FAIL + 1))
    fi
else
    set +e
    GH_USER=$(grep -E "^GITHUB_USER=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
    set -e
    if [ -z "$GH_USER" ] || [ "$GH_USER" = "{{GITHUB_USER}}" ]; then
        echo "⚠️ \`GITHUB_USER\` пуст или = плейсхолдер. Решение: отредактировать \`~/.exocortex.env\`, проставить логин."
        UPD_WARN=$((UPD_WARN + 1))
    else
        echo "✅ \`GITHUB_USER=$GH_USER\` заполнен"
    fi
fi
echo ""

echo "### Состояние FMT-exocortex-template"
echo ""
FMT_TPL="$IWE_ROOT/FMT-exocortex-template"
if [ ! -d "$FMT_TPL" ]; then
    echo "⚠️ \`FMT-exocortex-template/\` отсутствует — update.sh склонирует при первом запуске. Если update уже запускался и не получилось, проверь интернет до GitHub."
    UPD_WARN=$((UPD_WARN + 1))
elif [ ! -d "$FMT_TPL/.git" ]; then
    echo "❌ \`FMT-exocortex-template/\` есть, но не git-репо — update.sh не сможет fetch/pull. Решение: переклонировать."
    UPD_FAIL=$((UPD_FAIL + 1))
else
    set +e
    FMT_DIRTY=$(git -C "$FMT_TPL" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    FMT_BRANCH=$(git -C "$FMT_TPL" branch --show-current 2>/dev/null)
    set -e
    if [ "$FMT_DIRTY" -gt 0 ]; then
        echo "⚠️ \`FMT-exocortex-template/\` имеет $FMT_DIRTY uncommitted changes (ветка \`$FMT_BRANCH\`) — update может конфликтовать. Решение: \`git -C FMT-exocortex-template stash\` или коммит."
        UPD_WARN=$((UPD_WARN + 1))
    else
        echo "✅ \`FMT-exocortex-template/\` чистый (ветка \`$FMT_BRANCH\`)"
    fi
fi
echo ""

if [ $UPD_FAIL -gt 0 ]; then
    echo "**Вердикт раздела:** ❌ $UPD_FAIL критичных предусловия не выполнены — \`update.sh\` упадёт без них."
elif [ $UPD_WARN -gt 0 ]; then
    echo "**Вердикт раздела:** ⚠️ $UPD_WARN предупреждений — \`update.sh\` может частично сработать, но проверь рекомендации выше."
else
    echo "**Вердикт раздела:** ✅ всё готово к \`update.sh\`."
fi
echo ""

# Учёт в итоговом exit code: critical-fail в update prereq поднимает CRITICAL_MISSING
if [ $UPD_FAIL -gt 0 ]; then
    CRITICAL_MISSING=$((CRITICAL_MISSING + UPD_FAIL))
fi
if [ $UPD_WARN -gt 0 ]; then
    OPTIONAL_MISSING=$((OPTIONAL_MISSING + UPD_WARN))
fi

# ---------- Exit code ----------

# 2 = критичные gaps; 1 = warnings; 0 = ОК
if [ $CRITICAL_MISSING -ge 1 ]; then
    exit 2
fi
if [ $OPTIONAL_MISSING -gt 0 ]; then
    exit 1
fi
exit 0
