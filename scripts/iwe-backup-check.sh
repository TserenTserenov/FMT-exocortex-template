#!/usr/bin/env bash
# routing: helper  skill=day-close  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# iwe-backup-check.sh — Проверка здоровья системы резервного копирования IWE
#
# WP-317 supplement, 2026-05-18.
#
# ═══════════════════════════════════════════════════════════════════════════════
# ОБЕЩАНИЕ
# ═══════════════════════════════════════════════════════════════════════════════
# За ≤3 секунды проверить 3 уровня резервирования IWE и выдать markdown-отчёт:
#   1. iCloud-бэкапы (основной оффлайн-канал)
#   2. Локальные копии .backups/ (legacy / fallback)
#   3. Git-hygiene (удалённые репо на GitHub как живой backup-код)
#
# Verdict: ✅ / ⚠️ / ❌ с конкретным списком действий.
# Скрипт ТОЛЬКО детектит. Никаких автофиксов, никаких write-операций в git.
#
# ═══════════════════════════════════════════════════════════════════════════════
# СЦЕНАРИИ ИСПОЛЬЗОВАНИЯ
# ═══════════════════════════════════════════════════════════════════════════════
# 1. Ручная сверка перед Week Close (step 7a в week-close протоколе).
#    bash ~/IWE/scripts/iwe-backup-check.sh
#
# 2. Ежедневный healthcheck через launchd / cron (macOS).
#    Добавить в crontab: 0 9 * * * bash $HOME/IWE/scripts/iwe-backup-check.sh
#
# 3. Интеграция в iwe-audit.sh (future): вызов как подпроцесс для раздела Backup.
#
# 4. Pre-backup gate: запускать ПЕРЕД backup-icloud.sh, чтобы убедиться что
#    нет грязных репо, которые не попадут в архив.
#
# ═══════════════════════════════════════════════════════════════════════════════
# ЗАВИСИМОСТИ
# ═══════════════════════════════════════════════════════════════════════════════
#   bash, git, stat, date, find, du, wc, cut, sort (всё POSIX / macOS-совместимо)
#   Платформа: macOS (требуется iCloud Drive). На Linux — iCloud-секция будет N/A.
#
# ═══════════════════════════════════════════════════════════════════════════════
# USAGE
# ═══════════════════════════════════════════════════════════════════════════════
#   bash iwe-backup-check.sh [OPTIONS]
#
# OPTIONS:
#   --root PATH         Корень IWE (default: $HOME/IWE)
#   --warn-days N       Порог "предупреждения" для бэкапа в днях (default: 7)
#   --critical-days N   Порог "критично" для бэкапа в днях (default: 14)
#   --no-icloud         Пропустить проверку iCloud (Linux / headless)
#   -h, --help          Показать эту справку
#
# EXIT CODES:
#   0 — всё ОК (backup свежий, git чистый)
#   1 — warnings (backup 7–14 дней, или ≤2 dirty repos, или stale .backups/)
#   2 — critical (backup >14 дней, или нет iCloud, или >2 dirty repos)
#
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ---------- Конфигурация ----------
IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
WARN_DAYS=7
CRITICAL_DAYS=14
CHECK_ICLOUD=1

# ---------- Аргументы ----------
while [ $# -gt 0 ]; do
    case "$1" in
        --root) IWE_ROOT="$2"; shift 2 ;;
        --warn-days) WARN_DAYS="$2"; shift 2 ;;
        --critical-days) CRITICAL_DAYS="$2"; shift 2 ;;
        --no-icloud) CHECK_ICLOUD=0; shift ;;
        -h|--help) sed -n '/^# ═══/,/^# ═══/p' "$0" | sed 's/^# //'; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [ ! -d "$IWE_ROOT" ]; then
    echo "❌ IWE_ROOT not found: $IWE_ROOT" >&2
    exit 2
fi

# ---------- Helpers ----------
now_epoch=$(date +%s)
WARN_SEC=$((WARN_DAYS * 86400))
CRIT_SEC=$((CRITICAL_DAYS * 86400))

pass()  { printf "✅ %s\n" "$*"; }
warn()  { printf "⚠️  %s\n" "$*"; }
crit()  { printf "❌ %s\n" "$*"; }
info()  { printf "ℹ️  %s\n" "$*"; }

# macOS stat: -f %m (mtime epoch). Linux: -c %Y.
stat_mtime() {
    if stat -f %m "$1" >/dev/null 2>&1; then
        stat -f %m "$1"
    else
        stat -c %Y "$1"
    fi
}

# ---------- Состояние ----------
EXIT_CODE=0
WARNINGS=0
CRITICALS=0

# ---------- Раздел 1: iCloud-бэкапы ----------

if [ "$CHECK_ICLOUD" -eq 1 ]; then
    ICLOUD_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs/IWE-backups"

    echo "## 1. iCloud-бэкапы"
    echo ""

    if [ ! -d "$ICLOUD_DIR" ]; then
        crit "Директория iCloud не найдена: $ICLOUD_DIR"
        CRITICALS=$((CRITICALS + 1))
    else
        # Последний архив
        LATEST=$(find "$ICLOUD_DIR" -maxdepth 1 -name 'IWE-backup-*.tar.gz' -type f 2>/dev/null | sort | tail -1)
        TOTAL_ARCHIVES=$(find "$ICLOUD_DIR" -maxdepth 1 -name 'IWE-backup-*.tar.gz' -type f 2>/dev/null | wc -l | tr -d ' ')

        if [ -z "$LATEST" ]; then
            crit "Архивы IWE-backup-*.tar.gz не найдены в iCloud"
            CRITICALS=$((CRITICALS + 1))
        else
            LATEST_NAME=$(basename "$LATEST")
            LATEST_SIZE=$(du -sh "$LATEST" 2>/dev/null | cut -f1)
            LATEST_MTIME=$(stat_mtime "$LATEST")
            AGE_SEC=$((now_epoch - LATEST_MTIME))
            AGE_DAYS=$((AGE_SEC / 86400))

            echo "| Метрика | Значение |"
            echo "|---|---|"
            echo "| Последний архив | \`$LATEST_NAME\` |"
            echo "| Размер | $LATEST_SIZE |"
            echo "| Возраст | ${AGE_DAYS}d |"
            echo "| Всего архивов | $TOTAL_ARCHIVES |"
            echo ""

            if [ "$AGE_SEC" -gt "$CRIT_SEC" ]; then
                crit "Последний бэкап старше $CRITICAL_DAYS дней (${AGE_DAYS}d)"
                CRITICALS=$((CRITICALS + 1))
            elif [ "$AGE_SEC" -gt "$WARN_SEC" ]; then
                warn "Последний бэкап старше $WARN_DAYS дней (${AGE_DAYS}d)"
                WARNINGS=$((WARNINGS + 1))
            else
                pass "Бэкап свежий (${AGE_DAYS}d ≤ $WARN_DAYS d)"
            fi

            if [ "$TOTAL_ARCHIVES" -lt 2 ]; then
                warn "В iCloud только $TOTAL_ARCHIVES архив(а) — ротация может быть нарушена"
                WARNINGS=$((WARNINGS + 1))
            else
                pass "Ротация: $TOTAL_ARCHIVES архив(а)"
            fi
        fi
    fi
    echo ""
else
    echo "## 1. iCloud-бэкапы"
    echo ""
    info "Пропущено (--no-icloud)"
    echo ""
fi

# ---------- Раздел 2: Локальные .backups/ ----------

LOCAL_BACKUP_DIR="$IWE_ROOT/.backups"

echo "## 2. Локальные .backups/"
echo ""

if [ ! -d "$LOCAL_BACKUP_DIR" ]; then
    info "Директория .backups/ отсутствует — legacy-канал не используется"
else
    BACKUP_FOLDERS=$(find "$LOCAL_BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
    if [ -z "$BACKUP_FOLDERS" ]; then
        info ".backups/ существует, но пуста — OK"
    else
        FOLDER_COUNT=$(echo "$BACKUP_FOLDERS" | wc -l | tr -d ' ')
        echo "| Папка | Дата | Размер |"
        echo "|---|---|---|"
        while IFS= read -r folder; do
            name=$(basename "$folder")
            mtime=$(stat_mtime "$folder")
            age_days=$(((now_epoch - mtime) / 86400))
            size=$(du -sh "$folder" 2>/dev/null | cut -f1)
            printf "| \`%s\` | %sd | %s |\n" "$name" "$age_days" "$size"
        done <<< "$BACKUP_FOLDERS"
        echo ""

        # Проверим, есть ли очень старые (>30 дней)
        STALE=0
        while IFS= read -r folder; do
            mtime=$(stat_mtime "$folder")
            age_days=$(((now_epoch - mtime) / 86400))
            if [ "$age_days" -gt 30 ]; then
                STALE=$((STALE + 1))
            fi
        done <<< "$BACKUP_FOLDERS"

        if [ "$STALE" -gt 0 ]; then
            warn "$STALE папок старше 30 дней — рекомендуется очистка"
            WARNINGS=$((WARNINGS + 1))
        else
            pass "Все локальные копии ≤30 дней"
        fi
    fi
fi
echo ""

# ---------- Раздел 3: Git-hygiene ----------

echo "## 3. Git-hygiene (24 репо)"
echo ""

DIRTY_COUNT=0
UNPUSHED_COUNT=0
echo "| Репо | Uncommitted | Unpushed |"
echo "|---|---|---|"

for gitdir in $(find "$IWE_ROOT" -maxdepth 2 -name ".git" -type d 2>/dev/null); do
    repo_dir=$(dirname "$gitdir")
    repo_name=$(basename "$repo_dir")

    # Пропускаем node_modules / .venv вложенные .git
    if echo "$repo_dir" | grep -qE '(node_modules|\.venv)'; then
        continue
    fi

    uncommitted="0"
    unpushed="0"

    if [ -n "$(git -C "$repo_dir" status --short 2>/dev/null)" ]; then
        uncommitted="$(git -C "$repo_dir" status --short 2>/dev/null | wc -l | tr -d ' ')"
        DIRTY_COUNT=$((DIRTY_COUNT + 1))
    fi

    ahead=$(git -C "$repo_dir" rev-list --count HEAD@{upstream}..HEAD 2>/dev/null || echo 0)
    if [ "$ahead" -gt 0 ]; then
        unpushed="$ahead"
        UNPUSHED_COUNT=$((UNPUSHED_COUNT + 1))
    fi

    if [ "$uncommitted" != "0" ] || [ "$unpushed" != "0" ]; then
        printf "| \`%s\` | %s | %s |\n" "$repo_name" "$uncommitted" "$unpushed"
    fi
done
echo ""

if [ "$DIRTY_COUNT" -eq 0 ] && [ "$UNPUSHED_COUNT" -eq 0 ]; then
    pass "Все репо чистые (0 uncommitted, 0 unpushed)"
else
    if [ "$DIRTY_COUNT" -gt 0 ]; then
        warn "$DIRTY_COUNT репо с незакоммиченными изменениями"
        WARNINGS=$((WARNINGS + 1))
    fi
    if [ "$UNPUSHED_COUNT" -gt 0 ]; then
        warn "$UNPUSHED_COUNT репо с незапушенными коммитами"
        WARNINGS=$((WARNINGS + 1))
    fi
    if [ "$DIRTY_COUNT" -gt 2 ]; then
        crit "Слишком много грязных репо ($DIRTY_COUNT > 2)"
        CRITICALS=$((CRITICALS + 1))
    fi
fi
echo ""

# ---------- Итог ----------

echo "---"
echo ""
echo "## Verdict"
echo ""

if [ "$CRITICALS" -gt 0 ]; then
    echo "❌ **Critical:** $CRITICALS  |  ⚠️ **Warnings:** $WARNINGS"
    echo ""
    echo "**Действия:**"
    echo "1. Запустить \`bash $IWE_ROOT/scripts/backup-icloud.sh\` если бэкап устарел"
    echo "2. Закоммитить / запушить изменения в грязных репо"
    echo "3. Проверить iCloud Drive в System Settings если директория не найдена"
    EXIT_CODE=2
elif [ "$WARNINGS" -gt 0 ]; then
    echo "⚠️ **Warnings:** $WARNINGS  |  Critical: 0"
    echo ""
    echo "**Рекомендации:**"
    echo "- При следующем Week Close выполнить \`check-dirty-repos\` + \`backup-icloud.sh\`"
    echo "- Очистить \`.backups/\` если там stale-папки"
    EXIT_CODE=1
else
    echo "✅ **Всё ОК.** Backup свежий, git чистый, ротация работает."
    EXIT_CODE=0
fi

exit "$EXIT_CODE"
