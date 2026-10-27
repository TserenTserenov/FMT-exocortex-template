#!/usr/bin/env bash
# routing: helper  skill=week-close  called-by=sonnet  deterministic=true
# see DP.SC.159, DP.ROLE.059
# iwe-backup-check.sh — Проверка здоровья системы резервного копирования IWE
#
# WP-317 supplement, 2026-05-18.
#
# ═══════════════════════════════════════════════════════════════════════════════
# ОБЕЩАНИЕ
# ═══════════════════════════════════════════════════════════════════════════════
# За ≤3 секунды проверить 4 уровня резервирования IWE и выдать markdown-отчёт:
#   1. Архивы бэкапа (основной оффлайн-канал: backup_dir из params.yaml
#      на любой ОС либо iCloud Drive на macOS по умолчанию)
#   2. Локальные копии .backups/ (legacy / fallback)
#   3. Git-hygiene (удалённые репо на GitHub как живой backup-код)
#   4. Runtime-каталоги агентов вне ${HOME}/IWE (WP-7 Ф233а) — покрытие
#      источников из iwe-backup-sources.yaml: что существует, что
#      пропущено (с явной причиной), сколько весит.
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
#   Платформа: любая ОС с заданной целью бэкапа (backup_dir в params.yaml);
#   без него — iCloud Drive на macOS, на других ОС секция архивов будет N/A.
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
#   --no-icloud         Пропустить проверку архивов бэкапа (headless / свой бэкап)
#   --reset-baseline    Установить baseline (число файлов в архиве) для проверки
#                       целостности ротации. Требует локально доступный (не
#                       iCloud-заглушку) архив. Коммитит + пушит baseline-файл.
#   -h, --help          Показать эту справку
#
# EXIT CODES:
#   0 — всё ОК (backup свежий, git чистый)
#   1 — warnings (backup 7–14 дней, или ≤2 dirty repos, или stale .backups/)
#   2 — critical (backup >14 дней, или цель бэкапа недоступна, или >2 dirty repos)
#
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# Load unified environment: IWE_OS, IWE_ROOT, IWE_ICLOUD_BACKUP_DIR, etc.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1

# ---------- Конфигурация ----------
WARN_DAYS=7
CRITICAL_DAYS=14
MODE="check"
# The archive section runs whenever a backup target is set: the macOS iCloud
# default or backup_dir on any OS (issue #1349). --no-icloud disables it.
[ -n "$IWE_ICLOUD_BACKUP_DIR" ] && CHECK_ARCHIVES=1 || CHECK_ARCHIVES=0

# The backup contract (WP-7 F267 stage 2): an EXPLICIT backup_engine decides which kind
# of freshness is checked, so a healthy restic install is not accused over missing tar
# archives and the other way round. An unset key keeps the old behaviour (both checked).
# shellcheck source=lib/iwe-capabilities.sh
source "$SCRIPT_DIR/lib/iwe-capabilities.sh" || exit 1
BACKUP_ENGINE="$(cap_backup_engine)"
ENGINE_EXPLICIT=0
cap_backup_engine_explicit && ENGINE_EXPLICIT=1
ARCHIVES_SKIP_REASON=""
if [ "$ENGINE_EXPLICIT" -eq 1 ] && [ "$BACKUP_ENGINE" = restic ]; then
    CHECK_ARCHIVES=0
    ARCHIVES_SKIP_REASON="движок бэкапа restic (backup_engine в params.yaml)"
fi

# ---------- Аргументы ----------
while [ $# -gt 0 ]; do
    case "$1" in
        --root) IWE_ROOT="$2"; shift 2 ;;
        --warn-days) WARN_DAYS="$2"; shift 2 ;;
        --critical-days) CRITICAL_DAYS="$2"; shift 2 ;;
        --no-icloud) CHECK_ARCHIVES=0; shift ;;
        --reset-baseline) MODE="reset-baseline"; shift ;;
        -h|--help) sed -n '/^# ═══/,/^[^#]/p' "$0" | sed -e '/^[^#]/d' -e 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [ ! -d "$IWE_ROOT" ]; then
    echo "❌ IWE_ROOT not found: $IWE_ROOT" >&2
    exit 2
fi

# Baseline — локальный runtime-счётчик, не пилот-читаемый артефакт и не в git
# (2026-07-20: current/ зарезервирована под ежедневное чтение пилотом). Путь
# абсолютный, от IWE_ROOT (не от SCRIPT_DIR — тот перезаписывается
# iwe-env-bootstrap.sh на своё расположение при source выше; вычислен ПОСЛЕ
# парсинга аргументов, чтобы --root учитывался).
REPO_DIR="${IWE_DS_MY_STRATEGY:-$IWE_ROOT/${IWE_GOVERNANCE_REPO:-DS-strategy}}"
BASELINE_FILE="$REPO_DIR/.state/backup-baseline.json"
BASELINE_THRESHOLD_PCT=80
ICLOUD_DIR="$IWE_ICLOUD_BACKUP_DIR"

# ---------- Helpers ----------
now_epoch=$(date +%s)
WARN_SEC=$((WARN_DAYS * 86400))
CRIT_SEC=$((CRITICAL_DAYS * 86400))

pass()  { printf "✅ %s\n" "$*"; }
warn()  { printf "⚠️  %s\n" "$*"; }
crit()  { printf "❌ %s\n" "$*"; }
info()  { printf "ℹ️  %s\n" "$*"; }

# GNU stat: -c %Y (mtime epoch) is tried FIRST: GNU `stat -f` means "file system status" and
# succeeds with several lines of output (#1010 F14). BSD/macOS stat rejects -c and falls to -f %m.
stat_mtime() {
    if stat -c %Y "$1" >/dev/null 2>&1; then
        stat -c %Y "$1"
    else
        stat -f %m "$1"
    fi
}

# Последний архив IWE-backup-*.tar.gz в цели бэкапа (пусто, если директории/архивов нет)
find_latest_icloud_archive() {
    [ -d "$ICLOUD_DIR" ] || return 0
    find "$ICLOUD_DIR" -maxdepth 1 -name 'IWE-backup-*.tar.gz' -type f 2>/dev/null | sort | tail -1
}

# du -k возвращает 0 для iCloud-заглушки (Optimize Mac Storage — файл не
# скачан локально). Отличаем "заглушка" от "реально пустой/битый файл".
archive_local_size_kb() {
    du -k "$1" 2>/dev/null | cut -f1
}

# Установка baseline: сколько файлов "нормально" содержит архив ротации.
# Требует локально доступный (не заглушку) архив. Идемпотентна — повторный
# вызов без изменений сообщает об этом и завершается штатно (ход 20 BAK1).
reset_baseline() {
    local latest size_kb file_count existing_count

    latest=$(find_latest_icloud_archive)
    if [ -z "$latest" ]; then
        crit "Нет архива IWE-backup-*.tar.gz в $ICLOUD_DIR — нечего использовать как baseline"
        return 2
    fi

    size_kb=$(archive_local_size_kb "$latest")
    if [ -z "$size_kb" ] || [ "$size_kb" -eq 0 ]; then
        crit "Архив $(basename "$latest") — iCloud-заглушка (0 KB локально). Принудительно скачайте файл (открыть в Finder) и повторите --reset-baseline"
        return 2
    fi

    if ! tar -tzf "$latest" >/dev/null 2>&1; then
        crit "Архив $(basename "$latest") повреждён — tar -tzf провалился, baseline не установлен"
        return 2
    fi

    file_count=$(tar -tzf "$latest" 2>/dev/null | wc -l | tr -d '[:space:]')

    if [ -f "$BASELINE_FILE" ]; then
        existing_count=$(python3 -c "import json; print(json.load(open('$BASELINE_FILE'))['file_count'])" 2>/dev/null || echo "")
        if [ "$existing_count" = "$file_count" ]; then
            info "Baseline не изменился ($file_count файлов) — обновление не требуется"
            return 0
        fi
    fi

    mkdir -p "$(dirname "$BASELINE_FILE")"
    if ! python3 -c "import json, datetime; json.dump({'file_count': $file_count, 'baseline_date': datetime.date.today().isoformat()}, open('$BASELINE_FILE', 'w'), indent=2)"; then
        crit "Не удалось записать baseline-файл $BASELINE_FILE"
        return 1
    fi

    pass "Baseline установлен: $file_count файлов ($(basename "$latest")), записан в $BASELINE_FILE"
    return 0
}

if [ "$MODE" = "reset-baseline" ]; then
    reset_baseline
    exit $?
fi

# ---------- Состояние ----------
EXIT_CODE=0
WARNINGS=0
CRITICALS=0

# ---------- Раздел 1: Архивы бэкапа ----------

# Writable = a probe file can be created and removed in the directory: this
# catches read-only mounts and root-owned mount points of an unplugged volume.
dir_writable() {
    local probe
    probe=$(mktemp "$1/.iwe-backup-check.XXXXXX" 2>/dev/null) || return 1
    rm -f "$probe"
}

# Nearest existing ancestor of a target that has not been created yet.
nearest_existing_dir() {
    local d="$1"
    while [ ! -d "$d" ]; do d=$(dirname "$d"); done
    printf '%s\n' "$d"
}

if [ "$BACKUP_ENGINE" = invalid ]; then
    warn "Недопустимое значение backup_engine в params.yaml: допустимо tar или restic. iwe-backup.sh не запустит бэкап, пока значение не исправлено"
    WARNINGS=$((WARNINGS + 1))
fi
if [ "$BACKUP_ENGINE" = restic ] && [ -n "$(cap_backup_dir_param)" ]; then
    info "backup_dir относится к архивам tar и для restic не используется: restic пишет в защитное хранилище ~/.iwe-backup/protect-repo"
fi

echo "## 1. Архивы бэкапа"
echo ""

if [ "$CHECK_ARCHIVES" -eq 1 ]; then
    # iCloud wording and the mount check only for a target inside iCloud Drive;
    # backup_dir elsewhere is an ordinary directory on any OS (issue #1349).
    if iwe_path_inside "$ICLOUD_DIR" "$IWE_ICLOUD_ROOT"; then
        TARGET_IS_ICLOUD=1
        TARGET_LABEL="Директория iCloud"
    else
        TARGET_IS_ICLOUD=0
        TARGET_LABEL="Папка бэкапа (backup_dir)"
    fi
    info "Цель бэкапа: $ICLOUD_DIR"

    # TARGET_STATE: ready (exists, writable) | creatable (missing, the first
    # backup-icloud.sh run will mkdir it) | broken (critical).
    TARGET_STATE=broken
    if [ "$TARGET_IS_ICLOUD" -eq 1 ] && [ ! -d "$IWE_ICLOUD_ROOT" ]; then
        crit "iCloud Drive не найден ($IWE_ICLOUD_ROOT) — включите iCloud Drive в System Settings"
    elif [ -d "$ICLOUD_DIR" ]; then
        if dir_writable "$ICLOUD_DIR"; then
            TARGET_STATE=ready
        else
            crit "$TARGET_LABEL недоступна для записи: $ICLOUD_DIR (том не подключён или только для чтения)"
        fi
    else
        TARGET_PARENT=$(nearest_existing_dir "$ICLOUD_DIR")
        if dir_writable "$TARGET_PARENT"; then
            TARGET_STATE=creatable
        else
            crit "$TARGET_LABEL не найдена и не может быть создана: $ICLOUD_DIR (нет записи в $TARGET_PARENT — том не подключён?)"
        fi
    fi
    [ "$TARGET_STATE" = broken ] && CRITICALS=$((CRITICALS + 1))

    LATEST=""
    [ "$TARGET_STATE" = ready ] && LATEST=$(find_latest_icloud_archive)

    if [ "$TARGET_STATE" != broken ] && [ -z "$LATEST" ]; then
        # A fresh install has no archive yet; making this critical would forbid
        # week-close 7b, the only step that creates the first one.
        warn "Архивов IWE-backup-*.tar.gz пока нет в $ICLOUD_DIR — первый бэкап создаст шаг 7b закрытия недели (backup-icloud.sh)"
        WARNINGS=$((WARNINGS + 1))
    elif [ -n "$LATEST" ]; then
        TOTAL_ARCHIVES=$(find "$ICLOUD_DIR" -maxdepth 1 -name 'IWE-backup-*.tar.gz' -type f 2>/dev/null | wc -l | tr -d ' ')
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
            warn "В цели бэкапа только $TOTAL_ARCHIVES архив(а) — ротация может быть нарушена"
            WARNINGS=$((WARNINGS + 1))
        else
            pass "Ротация: $TOTAL_ARCHIVES архив(а)"
        fi

        # du -k == 0 inside iCloud → a stub (Optimize Mac Storage, not downloaded
        # locally): integrity and file count cannot be checked there — N/A, not
        # an error (ход 22 BAK1). Outside iCloud a 0 KB archive is just broken,
        # so it goes through the smoke test below.
        LATEST_SIZE_KB=$(archive_local_size_kb "$LATEST")
        if [ "$TARGET_IS_ICLOUD" -eq 1 ] && { [ -z "$LATEST_SIZE_KB" ] || [ "$LATEST_SIZE_KB" -eq 0 ]; }; then
            info "Архив — iCloud-заглушка (не скачан локально): smoke-тест и сравнение с baseline пропущены"
        else
            if tar -tzf "$LATEST" >/dev/null 2>&1; then
                pass "Smoke-тест целостности архива (tar -tzf) — OK"
            else
                crit "Архив повреждён — tar -tzf провалился"
                CRITICALS=$((CRITICALS + 1))
            fi

            if [ ! -f "$BASELINE_FILE" ]; then
                info "Baseline не установлен — запустите: $0 --reset-baseline"
            else
                BASELINE_COUNT=$(python3 -c "import json; print(json.load(open('$BASELINE_FILE'))['file_count'])" 2>/dev/null || echo "")
                BASELINE_DATE=$(python3 -c "import json; print(json.load(open('$BASELINE_FILE'))['baseline_date'])" 2>/dev/null || echo "")
                if [ -z "$BASELINE_COUNT" ]; then
                    warn "Baseline-файл повреждён ($BASELINE_FILE) — запустите --reset-baseline"
                    WARNINGS=$((WARNINGS + 1))
                else
                    CURRENT_COUNT=$(tar -tzf "$LATEST" 2>/dev/null | wc -l | tr -d '[:space:]')
                    THRESHOLD_COUNT=$(( BASELINE_COUNT * BASELINE_THRESHOLD_PCT / 100 ))
                    if [ "$CURRENT_COUNT" -lt "$THRESHOLD_COUNT" ]; then
                        crit "Архив содержит $CURRENT_COUNT файлов — меньше $BASELINE_THRESHOLD_PCT% от baseline ($BASELINE_COUNT, установлен $BASELINE_DATE)"
                        CRITICALS=$((CRITICALS + 1))
                    else
                        pass "Архив: $CURRENT_COUNT файлов (≥$BASELINE_THRESHOLD_PCT% от baseline $BASELINE_COUNT, установлен $BASELINE_DATE)"
                    fi
                fi
            fi
        fi
    fi
elif [ -n "$ARCHIVES_SKIP_REASON" ]; then
    info "Архивы tar не проверяются: $ARCHIVES_SKIP_REASON"
elif [ -n "$ICLOUD_DIR" ]; then
    info "Пропущено (--no-icloud): архивы в $ICLOUD_DIR не проверяются"
else
    info "N/A (платформа: $IWE_OS — iCloud доступен только на macOS; свой путь для встроенного бэкапа задаётся backup_dir в params.yaml)"
fi
echo ""

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
            # Archives update.sh keeps on purpose (retired files, replaced
            # publishers) are not stale clutter: never nag about them.
            case "$(basename "$folder")" in deprecated|ds-publish-pre-update) continue ;; esac
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

# ---------- Раздел 4: Runtime-каталоги агентов (WP-7 Ф233а) ----------

echo "## 4. Runtime-каталоги агентов вне \`\$HOME/IWE\`"
echo ""

SOURCES_FILE="$SCRIPT_DIR/iwe-backup-sources.yaml"
SOURCES_OVERRIDE="$HOME/.iwe-backup-sources.local.yaml"

if [ ! -f "$SOURCES_FILE" ]; then
    info "Файл дефолтов не найден ($SOURCES_FILE) — раздел пропущен"
    echo ""
else
    # python3 выдаёт один TSV-ряд на источник: tier, path, exists(0/1), note.
    # Разбор YAML — здесь, не в bash: избегаем ручного парсинга
    # структурированного формата (P9) и пишем ряд раз. Размер НЕ считаем
    # здесь: `du -sh` на крупных источниках (например ~/IWE целиком, сотни
    # ГБ) занимает минуты и ломает заявленное «≤3 секунды» этого скрипта
    # (найдено живым прогоном при реализации, WP-7 Ф233а) — для статуса
    # покрытия размер не нужен, только факт наличия.
    # Only the workspace itself is mandatory: other tier0 sources exist only if
    # that agent / credential helper is installed (issue #1351). An entry may
    # say `optional: true`; a local override with the same expanded path
    # replaces the default entry, but can never make the workspace optional.
    # WORKSPACE_ROOT is passed explicitly — IWE_ROOT may come from --root.
    SOURCES_TSV=$(HOME="$HOME" WORKSPACE_ROOT="$IWE_ROOT" SOURCES_FILE="$SOURCES_FILE" SOURCES_OVERRIDE="$SOURCES_OVERRIDE" python3 <<'PYEOF'
import os
import yaml

home = os.environ["HOME"]
workspace = os.path.realpath(os.environ["WORKSPACE_ROOT"])


def load(path):
    if not os.path.isfile(path):
        return {}
    with open(path) as f:
        return yaml.safe_load(f) or {}


defaults = load(os.environ["SOURCES_FILE"])
override = load(os.environ["SOURCES_OVERRIDE"])

if defaults.get("schema_version") != 1:
    import sys
    print(f"unsupported schema_version: {defaults.get('schema_version')!r}", file=sys.stderr)
    sys.exit(1)

tiers = ["tier0_unique", "tier1_scheduled", "tier2_optional"]
sources = {}
for layer in (defaults, override):
    for tier in tiers:
        for entry in layer.get(tier) or []:
            raw_path = entry.get("path") or ""
            if not raw_path:
                continue
            path = os.path.realpath(
                raw_path.replace("${HOME}", home).replace("${WORKSPACE_DIR}", workspace)
            )
            if path == workspace:
                tier = "tier0_unique"
            sources[path] = (tier, entry)
for path, (tier, entry) in sources.items():
    optional = bool(entry.get("optional")) and path != workspace
    note = entry.get("note", "")
    print(f"{tier}\t{path}\t{int(os.path.exists(path))}\t{int(optional)}\t{note}")
PYEOF
) || SOURCES_TSV=""

    if [ -z "$SOURCES_TSV" ]; then
        warn "Не удалось разобрать $SOURCES_FILE (пустой вывод или ошибка python3) — проверьте PyYAML (python3 -c 'import yaml')"
        WARNINGS=$((WARNINGS + 1))
    else
        MISSING_TIER0=0
        echo "| Tier | Путь | Статус | Примечание |"
        echo "|---|---|---|---|"
        while IFS=$'\t' read -r tier path exists optional note; do
            [ -z "$tier" ] && continue
            if [ "$exists" = "1" ]; then
                printf "| %s | \`%s\` | есть | %s |\n" "$tier" "$path" "${note:--}"
            elif [ "$tier" = "tier0_unique" ] && [ "$optional" = "0" ]; then
                printf "| %s | \`%s\` | НЕ НАЙДЕНО (обязательный) | %s |\n" "$tier" "$path" "${note:--}"
                MISSING_TIER0=$((MISSING_TIER0 + 1))
            else
                printf "| %s | \`%s\` | пропущено (не существует) | %s |\n" "$tier" "$path" "${note:--}"
            fi
        done <<< "$SOURCES_TSV"
        echo ""

        if [ "$MISSING_TIER0" -gt 0 ]; then
            crit "$MISSING_TIER0 обязательный(х) источник(а) уровня tier0 (невосстановимые данные) не найдено — проверьте путь или override"
            CRITICALS=$((CRITICALS + 1))
        else
            pass "Обязательные tier0-источники (невосстановимые данные) присутствуют на диске"
        fi
    fi
    echo ""
fi

# ---------- Раздел 5: Свежесть регулярного бэкапа (WP-7 Ф237в) ----------

echo "## 5. Регулярный зашифрованный бэкап (restic)"
echo ""

PROTECT_REPO_DIR="$HOME/.iwe-backup/protect-repo"
PROTECT_KEY_FILE="$HOME/.iwe-backup/protect-repo.key"
FRESHNESS_CRIT_HOURS=48

if [ "$ENGINE_EXPLICIT" -eq 1 ] && [ "$BACKUP_ENGINE" = tar ]; then
    info "Движок бэкапа tar (backup_engine в params.yaml): свежесть снимков restic не проверяется"
elif ! command -v restic >/dev/null 2>&1; then
    info "restic не установлен — регулярный бэкап (iwe-backup-run.sh) не настроен"
elif [ ! -d "$PROTECT_REPO_DIR" ]; then
    info "Хранилище $PROTECT_REPO_DIR ещё не создано — запустите scripts/iwe-backup-run.sh хотя бы раз"
else
    # Возраст считаем в python3: restic отдаёт ISO8601 с реальным offset
    # (например +03:00) — bash/date-разбор без учёта offset (найдено живым
    # прогоном: naive "взять часть до точки" давало отрицательный возраст,
    # т.к. локальное время интерпретировалось как UTC).
    #
    # stderr restic (не python3) НЕ глушим: поломанный/отсутствующий ключ,
    # устаревший lock или битый репозиторий дают ненулевой код restic с
    # пустым stdout — тогда python ветка "snapshots=[]" ложно репортует
    # «бэкап ни разу не выполнялся» вместо настоящей причины (нужен другой
    # ремонт: ключ/репозиторий, не повторный запуск) — найдено холодным
    # ревью. Сохраняем вывод restic отдельно и показываем его при пустом
    # результате, если он непуст.
    RESTIC_SNAPSHOTS_ERR="$(mktemp)"
    SNAPSHOTS_JSON=$(RESTIC_REPOSITORY="$PROTECT_REPO_DIR" RESTIC_PASSWORD_FILE="$PROTECT_KEY_FILE" \
        restic snapshots --tag scheduled --json 2>"$RESTIC_SNAPSHOTS_ERR") || true
    AGE_HOURS=$(printf '%s' "$SNAPSHOTS_JSON" | python3 -c '
import datetime
import json
import sys

try:
    snapshots = json.load(sys.stdin)
except json.JSONDecodeError:
    snapshots = []
if not snapshots:
    sys.exit(1)
latest = max(datetime.datetime.fromisoformat(s["time"]) for s in snapshots)
age = datetime.datetime.now(datetime.timezone.utc) - latest
print(int(age.total_seconds() // 3600))
' 2>/dev/null) || AGE_HOURS=""

    if [ -z "$AGE_HOURS" ]; then
        if [ -s "$RESTIC_SNAPSHOTS_ERR" ]; then
            crit "restic snapshots завершился с ошибкой — хранилище/ключ требуют проверки, не просто «запустить бэкап»"
            cat "$RESTIC_SNAPSHOTS_ERR" >&2
            CRITICALS=$((CRITICALS + 1))
        else
            warn "Ни одного снимка с тегом scheduled не найдено — регулярный бэкап ни разу не выполнялся"
            WARNINGS=$((WARNINGS + 1))
        fi
    elif [ "$AGE_HOURS" -gt "$FRESHNESS_CRIT_HOURS" ]; then
        crit "Последний регулярный снимок старше ${FRESHNESS_CRIT_HOURS}ч (${AGE_HOURS}ч назад) — расписание не выполняется"
        CRITICALS=$((CRITICALS + 1))
    else
        pass "Последний регулярный снимок ${AGE_HOURS}ч назад (≤ ${FRESHNESS_CRIT_HOURS}ч)"
    fi
    rm -f "$RESTIC_SNAPSHOTS_ERR"
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
    echo "1. Запустить \`bash $IWE_ROOT/scripts/iwe-backup.sh\` (выбирает движок по backup_engine) если бэкап устарел"
    echo "2. Закоммитить / запушить изменения в грязных репо"
    echo "3. Проверить, что цель бэкапа доступна: iCloud Drive в System Settings или подключённый том для backup_dir"
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
