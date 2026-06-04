#!/usr/bin/env bash
# routing: migration  one-time=true
# see DP.SC.159, DP.ROLE.059
# memory-migrate.sh — добавление отсутствующих frontmatter-полей (WP-217 Ф10.2/Ф10.4)
#
# Добавляет поля schema_version/horizon/domains/status/owner в существующие файлы.
# НЕ перезаписывает поля, которые уже есть.
# Определяет type/horizon/domains автоматически по имени файла.
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../.claude/lib/iwe-env-bootstrap.sh" || exit 1
MEMORY_DIR="$IWE_ROOT/memory"
DRY_RUN=0
ALL=0
FROM_VER=""
TO_VER=""
TARGET=""
EXCLUDE="MEMORY.md"

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

get_field() {
    local file="$1" field="$2"
    awk '/^---/{f++} f==1 && /^'"$field"':/{gsub(/^[^:]+: */,""); gsub(/^["'"'"']|["'"'"']$/,""); print; exit}' "$file"
}

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
    new_valid_from="${cur_valid_from:-$(date +%Y-%m-%d)}"

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
    # Читаем тело файла (без frontmatter)
    body=$(awk '/^---/{f++; next} f>=2{print}' "$file")

    # Существующие поля frontmatter (без ---)
    existing_fm=$(awk '/^---/{f++; next} f==1{print}' "$file")

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
if [ $ALL -eq 1 ]; then
    changed=0; skipped=0; ok=0
    for f in $(find "$MEMORY_DIR/" -maxdepth 1 -name "*.md" | sort); do
        [ -f "$f" ] || continue
        n=$(basename "$f"); skip=0
        for exc in $EXCLUDE; do [ "$n" = "$exc" ] && skip=1 && break; done
        [ $skip -eq 1 ] && continue
        result=$(migrate_file "$f" 2>&1)
        echo "$result"
        echo "$result" | grep -q "^DONE" && changed=$((changed+1)) || true
        echo "$result" | grep -q "^OK"   && ok=$((ok+1)) || true
        echo "$result" | grep -q "^SKIP" && skipped=$((skipped+1)) || true
    done
    echo ""
    [ $DRY_RUN -eq 1 ] && echo "Dry-run завершён" || echo "Итог: изменено=$changed, уже полные=$ok, пропущено=$skipped"
elif [ -n "$TARGET" ]; then
    migrate_file "$TARGET"
else
    echo "Укажите файл или --all" >&2
    exit 1
fi
