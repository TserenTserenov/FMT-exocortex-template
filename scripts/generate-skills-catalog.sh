#!/usr/bin/env bash
# routing: helper  skill=extend  called-by=script
# see DP.SC.159, DP.ROLE.059
# generate-skills-catalog.sh — генератор skills-catalog.yaml
# see DP.SC.153
#
# Парсит все .claude/skills/*/SKILL.md → строит skills-catalog.yaml с:
#   - метаданными из frontmatter (name, description, version, layer, status, triggers, depends_on)
#   - вычисляемым invoked_by (из protocol-*.md + других SKILL.md + CLAUDE.md)
#
# Использование:
#   bash generate-skills-catalog.sh [--skills-dir <path>] [--output <path>] [--dry-run]

set -uo pipefail

IWE="${IWE_WORKSPACE:-$HOME/IWE}"
SKILLS_DIR="${IWE}/.claude/skills"
PROTOCOLS_DIR="${IWE}/memory"
OUTPUT="${IWE}/.claude/skills-catalog.yaml"
dry_run=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skills-dir) SKILLS_DIR="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --dry-run) dry_run=true; shift ;;
        *) echo "Неизвестный флаг: $1" >&2; exit 1 ;;
    esac
done

log() { echo "$*" >&2; }

# Извлечь значение поля из YAML frontmatter (первое вхождение)
get_field() {
    local file="$1" field="$2"
    sed -n "/^---$/,/^---$/p" "$file" 2>/dev/null \
      | grep "^${field}:" \
      | head -1 \
      | sed "s/^${field}: *//" \
      | sed 's/^"\(.*\)"$/\1/' \
      | sed "s/^'\(.*\)'$/\1/"
}

# Извлечь список (slash или phrases) из triggers блока
get_triggers_slash() {
    local file="$1"
    # Ищем triggers.slash как inline список [/skill]
    sed -n '/^triggers:/,/^[a-z]/p' "$file" 2>/dev/null \
      | grep "slash:" \
      | sed 's/.*slash: *\[//;s/\].*//' \
      | tr ',' '\n' \
      | sed 's/^ *//;s/ *$//;s/^\/\?/\//' \
      | grep -v '^$' || true
}

# Собрать все файлы где упоминается скилл (для invoked_by)
build_invoked_by() {
    local skill_name="$1"
    local callers=""
    # Ищем /skill-name в protocol-*.md и CLAUDE.md
    local search_files=""
    [[ -d "$PROTOCOLS_DIR" ]] && search_files+=" $(find "$PROTOCOLS_DIR" -name "protocol-*.md" 2>/dev/null)"
    [[ -f "${IWE}/CLAUDE.md" ]] && search_files+=" ${IWE}/CLAUDE.md"
    # Ищем в других SKILL.md (depends_on)
    [[ -d "$SKILLS_DIR" ]] && search_files+=" $(find "$SKILLS_DIR" -name "SKILL.md" 2>/dev/null)"

    for f in $search_files; do
        [[ -f "$f" ]] || continue
        if grep -q "/${skill_name}\b\|depends_on:.*${skill_name}" "$f" 2>/dev/null; then
            caller=$(basename "$(dirname "$f")")
            # Для protocol-*.md берём имя файла
            [[ "$f" == *"protocol-"* ]] && caller=$(basename "$f" .md)
            [[ "$f" == *"CLAUDE.md"* ]] && caller="CLAUDE.md"
            callers+="    - ${caller}\n"
        fi
    done
    echo -e "$callers"
}

log "🔍 Сканирую скиллы в: $SKILLS_DIR"

# Начало YAML
catalog_content="# skills-catalog.yaml — автогенерировано generate-skills-catalog.sh
# see DP.SC.153
# НЕ редактировать вручную — перегенерировать через generate-skills-catalog.sh
#
generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
skills_dir: ${SKILLS_DIR}

skills:"

skill_count=0
warn_count=0

for skill_dir in "$SKILLS_DIR"/*/; do
    [[ -d "$skill_dir" ]] || continue
    skill_id=$(basename "$skill_dir")
    [[ "$skill_id" == "_template" ]] && continue  # пропустить шаблон

    skill_md="${skill_dir}SKILL.md"
    if [[ ! -f "$skill_md" ]]; then
        log "  ⚠️  [$skill_id] SKILL.md не найден — пропускаю"
        (( warn_count++ )) || true
        continue
    fi

    name=$(get_field "$skill_md" "name")
    description=$(get_field "$skill_md" "description")
    version=$(get_field "$skill_md" "version")
    layer=$(get_field "$skill_md" "layer")
    status_val=$(get_field "$skill_md" "status")
    depends_raw=$(grep "^depends_on:" "$skill_md" 2>/dev/null | head -1 | sed 's/^depends_on: *//' || echo "[]")

    # Дефолты для отсутствующих полей
    [[ -z "$name" ]] && name="$skill_id" && log "  ⚠️  [$skill_id] name не найден, используем id"
    [[ -z "$version" ]] && version="0.0.0" && log "  ⚠️  [$skill_id] version не найден"
    [[ -z "$layer" ]] && layer="unknown" && log "  ⚠️  [$skill_id] layer не найден"
    [[ -z "$status_val" ]] && status_val="active"

    # triggers.slash
    slash_triggers=$(get_triggers_slash "$skill_md")
    slash_yaml=""
    if [[ -n "$slash_triggers" ]]; then
        slash_yaml="      slash:"$'\n'
        while IFS= read -r t; do
            [[ -n "$t" ]] && slash_yaml+="        - ${t}"$'\n'
        done <<< "$slash_triggers"
    fi

    # invoked_by (вычисляемое)
    invoked_by=$(build_invoked_by "$skill_id")

    catalog_content+="
  - id: ${skill_id}
    name: \"${name}\"
    description: \"${description}\"
    version: ${version}
    layer: ${layer}
    status: ${status_val}
    triggers:"

    if [[ -n "$slash_yaml" ]]; then
        catalog_content+="
${slash_yaml%$'\n'}"
    else
        catalog_content+="
      slash: []"
    fi

    catalog_content+="
    depends_on: ${depends_raw}"

    if [[ -n "$invoked_by" ]]; then
        catalog_content+="
    invoked_by:
${invoked_by%$'\n'}"
    else
        catalog_content+="
    invoked_by: []"
    fi

    (( skill_count++ )) || true
done

log ""
log "📊 Итого: ${skill_count} скиллов, ${warn_count} предупреждений"

if $dry_run; then
    log "--- dry-run: skills-catalog.yaml ---"
    echo "$catalog_content"
    exit 0
fi

echo "$catalog_content" > "$OUTPUT"
log "✅ Каталог записан: $OUTPUT"
