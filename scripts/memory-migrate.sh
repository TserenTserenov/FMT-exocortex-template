#!/usr/bin/env bash
# routing: migration  one-time=true
# see DP.SC.159, DP.ROLE.059
# memory-migrate.sh — добавление отсутствующих frontmatter-полей (WP-217 Ф10.2/Ф10.4)
#
# Добавляет поля schema_version/horizon/domains/status/owner в существующие файлы.
# НЕ перезаписывает поля, которые уже есть.
# Определяет type/horizon/domains автоматически по имени файла.
# issue #1147: присвоение horizon: hot проверяется против бюджета HOT
# (≤150 строк суммарно, memory-lifecycle-spec.md §4) ДО любой записи — при
# превышении миграция останавливается со списком кандидатов, ничего не пишет;
# valid_from берётся из metadata.modified / mtime файла, не из даты запуска.
#
# Usage:
#   bash scripts/memory-migrate.sh memory/file.md         # один файл
#   bash scripts/memory-migrate.sh --all                  # все memory/*.md
#   bash scripts/memory-migrate.sh --dry-run --all        # показать без изменений
#   bash scripts/memory-migrate.sh --from 1 --to 2 file   # будущая миграция схем
#
# Spec: memory/memory-lifecycle-spec.md §8 (WP-217 Ф10.1)

set -eu

# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
# NOTE: iwe-env-bootstrap.sh reassigns SCRIPT_DIR to its OWN location (via its
# BASH_SOURCE[0]) as a side effect of being sourced — save ours first so the
# frontmatter.sh source below still resolves relative to THIS script (issue #229).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MEMORY_MIGRATE_DIR="$SCRIPT_DIR"
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
# issue #658: was a private get_field() unaware of the `metadata:`-nested
# frontmatter dialect (issue #281) — every already-nested scalar field
# (type/horizon/status/owner/valid_from/...) read back as empty, which made
# the migration below think the field was missing and propose a filename-
# guessed flat duplicate on top of the real value. Sourcing the shared
# reader fixes scalar fields. issue #1147: `domains:` as a columnar YAML
# list (`- item` lines) is parsed by frontmatter.sh too, so a nested
# columnar list no longer triggers a flat duplicate either.
source "$_MEMORY_MIGRATE_DIR/../.claude/lib/frontmatter.sh" || exit 1
MEMORY_DIR="$IWE_ROOT/memory"
DRY_RUN=0
ALL=0
FROM_VER=""
TO_VER=""
TARGET=""
EXCLUDE="MEMORY.md"

# issue #1147: бюджет HOT — memory-lifecycle-spec.md §4 (ось 2: horizon)
# ограничивает суммарный размер тел всех hot-файлов 150 строками. Миграция
# обязана проверять бюджет ДО записи, а не раздувать HOT по имени файла.
HOT_LIMIT_LINES=150

# Строки тела файла (после закрывающего ---) — то, что реально грузится.
# f<2: строка "---" ВНУТРИ тела (горизонтальный разделитель markdown) не
# считается разделителем frontmatter и не выпадает из подсчёта (cold-review).
body_lines() {
    awk '/^---/ && f<2{f++; next} f>=2{print}' "$1" | wc -l | tr -d ' '
}

# Сумма строк тел всех файлов с horizon: hot в MEMORY_DIR (читаем факт,
# не заявку): горизонт — из frontmatter, строки — из тела файла.
hot_total_lines() {
    local total=0 f n skip exc
    for f in "$MEMORY_DIR"/*.md; do
        [ -f "$f" ] || continue
        n=$(basename "$f"); skip=0
        for exc in $EXCLUDE; do [ "$n" = "$exc" ] && skip=1 && break; done
        [ $skip -eq 1 ] && continue
        [ "$(get_field "$f" "horizon")" = "hot" ] || continue
        total=$((total + $(body_lines "$f")))
    done
    echo "$total"
}

# Строгая проверка YYYY-MM-DD без привязки к диалекту date (GNU -d / BSD -j).
validate_ymd() {
    date -d "$1" >/dev/null 2>&1 && return 0
    date -j -f "%Y-%m-%d" "$1" >/dev/null 2>&1 && return 0
    return 1
}

# issue #1147: valid_from = дата появления факта, не дата запуска миграции.
# Цепочка: metadata.modified (нормализация к YYYY-MM-DD) → mtime файла →
# сегодня. Невалидное значение не подставляем — идём по цепочке дальше.
infer_valid_from() {
    local file="$1" v
    v=$(get_field "$file" "modified" 2>/dev/null || true)
    v=$(printf '%s' "$v" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 || true)
    if [ -n "$v" ] && validate_ymd "$v"; then echo "$v"; return 0; fi
    # mtime: GNU stat -c, затем BSD stat -f (порядок как в canon-dirty-snapshot.sh)
    v=$(stat -c %y "$file" 2>/dev/null | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)
    [ -n "$v" ] || v=$(stat -f %Sm -t %Y-%m-%d "$file" 2>/dev/null || true)
    if [ -n "$v" ] && validate_ymd "$v"; then echo "$v"; return 0; fi
    date +%Y-%m-%d
}

while [ $# -gt 0 ]; do
    case "$1" in
        --all)      ALL=1; shift ;;
        --dry-run)  DRY_RUN=1; shift ;;
        --from)     FROM_VER="$2"; shift 2 ;;
        --to)       TO_VER="$2"; shift 2 ;;
        --dir)      MEMORY_DIR="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | head -18
            exit 0
            ;;
        *.md) TARGET="$1"; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

has_frontmatter() {
    head -1 "$1" | grep -q '^---$'
}

# Сгенерировать name из имени файла
infer_name() {
    local name="$1"
    local stem="${name%.md}"
    case "$stem" in
        feedback_behaviour*)    echo "Обратная связь: поведение агента" ;;
        feedback_architecture*) echo "Обратная связь: архитектура и код" ;;
        feedback_writing*)      echo "Обратная связь: написание и публикации" ;;
        feedback_governance*)   echo "Обратная связь: управление" ;;
        feedback_neon*)         echo "Урок: Neon pooler и LISTEN/NOTIFY" ;;
        feedback_railway*)      echo "Урок: Railway — создание проектов" ;;
        feedback_quantum*)      echo "Урок: триггер Quantum-like анализа" ;;
        feedback_*)
            local short="${stem#feedback_}"
            short="${short//_/ }"
            echo "Обратная связь: $short"
            ;;
        project_*)
            local short="${stem#project_}"
            short="${short//_/ }"
            echo "Проект: $short"
            ;;
        reference_*)
            local short="${stem#reference_}"
            short="${short//_/ }"
            echo "Справочник: $short"
            ;;
        user_*)
            local short="${stem#user_}"
            short="${short//_/ }"
            echo "Профиль: $short"
            ;;
        lessons_*)
            local short="${stem#lessons_}"
            short="${short//_/ }"
            echo "Уроки: $short"
            ;;
        protocol-*)
            local short="${stem#protocol-}"
            short="${short//-/ }"
            echo "Протокол: $short"
            ;;
        *-spec)
            local short="${stem%-spec}"
            echo "Спецификация: $short"
            ;;
        *)
            echo "${stem//_/ }"
            ;;
    esac
}

# Сгенерировать description из имени файла
infer_description() {
    local stem="${1%.md}"
    case "$stem" in
        feedback_*) echo "Правила обратной связи — руководство для следующих сессий" ;;
        project_*)  echo "Контекст проектной инициативы — цели, состояние, решения" ;;
        reference_*) echo "Ссылочная информация по внешней системе или ресурсу" ;;
        user_*)     echo "Профиль пользователя — для персонализации взаимодействия" ;;
        lessons_*)  echo "Накопленные уроки по теме — паттерны и анти-паттерны" ;;
        protocol-*) echo "Протокол ОРЗ — пошаговые инструкции для ритуала" ;;
        *-spec*)    echo "Спецификация — формальное описание системы или протокола" ;;
        *)          echo "Операционный файл памяти IWE" ;;
    esac
}

# Определить type по имени файла
infer_type() {
    local name="$1"
    case "$name" in
        feedback_*)  echo "feedback" ;;
        project_*)   echo "project" ;;
        reference_*) echo "reference" ;;
        user_*)      echo "user" ;;
        lessons_*)   echo "lesson" ;;
        protocol-*)  echo "protocol" ;;
        *-spec.md)   echo "protocol" ;;
        r-questionnaire*|t-checklist*|checklists*|templates-*|dry-run*) echo "protocol" ;;
        *)           echo "reference" ;;
    esac
}

# Определить horizon по type
infer_horizon() {
    local type="$1" name="$2"
    case "$type" in
        user)     echo "hot" ;;
        feedback)
            # Активные feedback → hot, архивные → warm
            case "$name" in
                *_archive*) echo "warm" ;;
                *)           echo "hot" ;;
            esac
            ;;
        project)  echo "warm" ;;
        reference) echo "warm" ;;
        lesson)   echo "warm" ;;
        protocol) echo "warm" ;;
        *)        echo "warm" ;;
    esac
}

# Определить domains по имени файла
infer_domains() {
    local name="$1"
    case "$name" in
        feedback_behaviour*)   echo "[behaviour]" ;;
        feedback_architecture*) echo "[architecture]" ;;
        feedback_writing*)     echo "[writing]" ;;
        feedback_governance*)  echo "[protocol]" ;;
        feedback_neon*|feedback_railway*|feedback_cloudflare*) echo "[infrastructure]" ;;
        feedback_*cutover*|feedback_*release*|feedback_*deploy*) echo "[architecture, infrastructure]" ;;
        feedback_*)            echo "[behaviour]" ;;
        project_*)             echo "[project-iwe]" ;;
        reference_neon*)       echo "[infrastructure, neon]" ;;
        reference_railway*)    echo "[infrastructure, railway]" ;;
        reference_cloudflare*) echo "[infrastructure, cloudflare]" ;;
        reference_github*)     echo "[infrastructure, git]" ;;
        reference_ory*)        echo "[infrastructure]" ;;
        reference_*)           echo "[reference]" ;;
        user_*)                echo "[user-profile]" ;;
        lessons_infra*)        echo "[infrastructure]" ;;
        lessons_tools*)        echo "[infrastructure]" ;;
        lessons_*)             echo "[behaviour]" ;;
        protocol-*)            echo "[protocol]" ;;
        *-spec.md)             echo "[protocol, memory]" ;;
        *)                     echo "[reference]" ;;
    esac
}

migrate_file() {
    local file="$1"
    local name
    name=$(basename "$file")

    if ! has_frontmatter "$file"; then
        echo "SKIP $name — нет frontmatter, сначала добавить вручную" >&2
        return 1
    fi

    # Собираем текущие поля
    cur_type=$(get_field "$file" "type")
    cur_horizon=$(get_field "$file" "horizon")
    cur_domains=$(get_field "$file" "domains")
    cur_status=$(get_field "$file" "status")
    cur_owner=$(get_field "$file" "owner")
    cur_schema=$(get_field "$file" "schema_version")
    cur_name=$(get_field "$file" "name")
    cur_desc=$(get_field "$file" "description")
    cur_valid_from=$(get_field "$file" "valid_from")

    # Определяем defaults
    new_type="${cur_type:-$(infer_type "$name")}"
    new_horizon="${cur_horizon:-$(infer_horizon "$new_type" "$name")}"
    new_domains="${cur_domains:-$(infer_domains "$name")}"
    new_status="${cur_status:-active}"
    new_owner="${cur_owner:-user}"
    new_schema="${cur_schema:-1}"
    new_name="${cur_name:-$(infer_name "$name")}"
    new_desc="${cur_desc:-$(infer_description "$name")}"
    new_valid_from="${cur_valid_from:-$(infer_valid_from "$file")}"

    # issue #1147: присвоение hot проверяется против бюджета ДО записи
    # (одиночный файл и проход записи --all проходят одну и ту же проверку;
    # сумма уже мигрированных в этом прогоне учитывается, т.к. hot_total_lines
    # читает файлы заново). Отказ = ничего не записано.
    if [ -z "$cur_horizon" ] && [ "$new_horizon" = "hot" ]; then
        hot_now=$(hot_total_lines)
        projected=$((hot_now + $(body_lines "$file")))
        if [ "$projected" -gt "$HOT_LIMIT_LINES" ]; then
            echo "REFUSE $name — horizon: hot вывел бы HOT за лимит $HOT_LIMIT_LINES строк (сейчас $hot_now, стало бы $projected; memory-lifecycle-spec.md §4). Понизьте горизонт файла или сократите существующие HOT." >&2
            return 1
        fi
    fi

    # Если ничего добавлять не нужно — пропускаем
    if [ -n "$cur_type" ] && [ -n "$cur_horizon" ] && [ -n "$cur_domains" ] \
       && [ -n "$cur_status" ] && [ -n "$cur_owner" ] && [ -n "$cur_schema" ] \
       && [ -n "$cur_name" ] && [ -n "$cur_desc" ] && [ -n "$cur_valid_from" ]; then
        echo "OK   $name — уже полный frontmatter"
        return 0
    fi

    if [ $DRY_RUN -eq 1 ]; then
        echo "DRY  $name"
        [ -z "$cur_type" ]       && echo "     + type: $new_type"
        [ -z "$cur_horizon" ]    && echo "     + horizon: $new_horizon"
        [ -z "$cur_domains" ]    && echo "     + domains: $new_domains"
        [ -z "$cur_status" ]     && echo "     + status: $new_status"
        [ -z "$cur_owner" ]      && echo "     + owner: $new_owner"
        [ -z "$cur_schema" ]     && echo "     + schema_version: $new_schema"
        [ -z "$cur_name" ]       && echo "     + name: $new_name"
        [ -z "$cur_desc" ]       && echo "     + description: $new_desc"
        [ -z "$cur_valid_from" ] && echo "     + valid_from: $new_valid_from"
        return 0
    fi

    # Построить новый frontmatter
    # Читаем тело файла (без frontmatter); f<2: строка "---" внутри тела —
    # не разделитель, такие строки не должны выпадать из файла (cold-review).
    body=$(awk '/^---/ && f<2{f++; next} f>=2{print}' "$file")

    # Существующие поля frontmatter (без ---)
    existing_fm=$(awk '/^---/ && f<2{f++; next} f==1{print}' "$file")

    # Добавляем отсутствующие поля в конец frontmatter
    additions=""
    [ -z "$cur_type" ]       && additions="$additions\ntype: $new_type"
    [ -z "$cur_horizon" ]    && additions="$additions\nhorizon: $new_horizon"
    [ -z "$cur_domains" ]    && additions="$additions\ndomains: $new_domains"
    [ -z "$cur_status" ]     && additions="$additions\nstatus: $new_status"
    [ -z "$cur_owner" ]      && additions="$additions\nowner: $new_owner"
    [ -z "$cur_schema" ]     && additions="$additions\nschema_version: $new_schema"
    [ -z "$cur_name" ]       && additions="$additions\nname: \"$new_name\""
    [ -z "$cur_desc" ]       && additions="$additions\ndescription: \"$new_desc\""
    [ -z "$cur_valid_from" ] && additions="$additions\nvalid_from: $new_valid_from"

    # Записываем обновлённый файл
    {
        echo "---"
        echo "$existing_fm"
        printf "%b" "$additions"
        echo ""
        echo "---"
        printf "%s" "$body"
    } > "$file"

    echo "DONE $name"
}

# Основной цикл
# cold-review #1147 (раунд 3): два одновременных запуска могли оба увидеть
# запас бюджета HOT и переписывать одни файлы через `> "$file"` — риск порчи,
# не только превышения бюджета. Общий mkdir-замок на весь прогон (проверка
# бюджета + запись). Замок НИКОГДА не удаляется автоматически: любая схема
# «проверить staleness, затем rm» оставляет окно, где сносится чужой свежий
# замок (та же находка, что в protocol-stop-gate #1184). Занят → отказ с
# инструкцией ручной очистки; свой замок снимает только trap EXIT создателя.
MIGRATE_LOCK="$MEMORY_DIR/.migrate.lock"
if ! mkdir "$MIGRATE_LOCK" 2>/dev/null; then
    lock_pid=$(cat "$MIGRATE_LOCK/pid" 2>/dev/null || true)
    echo "ОТКАЗ: другой запуск memory-migrate держит замок $MIGRATE_LOCK (pid ${lock_pid:-неизвестен})." >&2
    echo "Если тот запуск упал — проверьте, что процесс не жив (kill -0 ${lock_pid:-PID}), и удалите каталог замка вручную." >&2
    exit 1
fi
echo "$$" > "$MIGRATE_LOCK/pid" 2>/dev/null || true
trap 'rm -rf "$MIGRATE_LOCK" 2>/dev/null || true' EXIT

if [ $ALL -eq 1 ]; then
    # Проход 1 (без записи, issue #1147): бюджет HOT проверяется на ВСЕМ наборе
    # до любой записи — иначе отказ на середине дал бы частичную миграцию.
    # Сумма = строки тел существующих hot-файлов + строки тел файлов, которым
    # эта миграция присвоит hot (horizon отсутствует и infer_horizon = hot).
    hot_base=$(hot_total_lines)
    cand_lines=0
    candidates=""
    # Имена с пробелами/переносами не должны пропадать: обход через NUL
    # (process substitution, не pipeline — иначе счётчики в subshell).
    while IFS= read -r -d '' f; do
        [ -f "$f" ] || continue
        n=$(basename "$f"); skip=0
        for exc in $EXCLUDE; do [ "$n" = "$exc" ] && skip=1 && break; done
        [ $skip -eq 1 ] && continue
        has_frontmatter "$f" || continue
        [ -z "$(get_field "$f" "horizon")" ] || continue
        cand_type=$(get_field "$f" "type")
        [ -n "$cand_type" ] || cand_type=$(infer_type "$n")
        [ "$(infer_horizon "$cand_type" "$n")" = "hot" ] || continue
        candidates="$candidates  $n\n"
        cand_lines=$((cand_lines + $(body_lines "$f")))
    done < <(find "$MEMORY_DIR/" -maxdepth 1 -name "*.md" -print0)
    projected_total=$((hot_base + cand_lines))
    if [ "$projected_total" -gt "$HOT_LIMIT_LINES" ]; then
        echo "СТОП: миграция выводит HOT за лимит $HOT_LIMIT_LINES строк (memory-lifecycle-spec.md §4)." >&2
        echo "Сейчас в HOT: $hot_base строк; кандидаты добавили бы $cand_lines (итого $projected_total). Ничего не записано." >&2
        echo "Кандидаты на hot — понизьте горизонт или сократите файлы, затем повторите:" >&2
        printf "%b" "$candidates" >&2
        exit 1
    fi

    changed=0; skipped=0; ok=0
    while IFS= read -r -d '' f; do
        [ -f "$f" ] || continue
        n=$(basename "$f"); skip=0
        for exc in $EXCLUDE; do [ "$n" = "$exc" ] && skip=1 && break; done
        [ $skip -eq 1 ] && continue
        result=$(migrate_file "$f" 2>&1)
        echo "$result"
        echo "$result" | grep -q "^DONE" && changed=$((changed+1)) || true
        echo "$result" | grep -q "^OK"   && ok=$((ok+1)) || true
        echo "$result" | grep -q "^SKIP" && skipped=$((skipped+1)) || true
    done < <(find "$MEMORY_DIR/" -maxdepth 1 -name "*.md" -print0)
    echo ""
    [ $DRY_RUN -eq 1 ] && echo "Dry-run завершён" || echo "Итог: изменено=$changed, уже полные=$ok, пропущено=$skipped"
elif [ -n "$TARGET" ]; then
    migrate_file "$TARGET"
else
    echo "Укажите файл или --all" >&2
    exit 1
fi
