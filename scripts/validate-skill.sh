#!/usr/bin/env bash
# routing: helper  skill=audit-installation  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# validate-skill.sh — валидация SKILL.md v2 (pre-promote checklist)
# see DP.SC.153, DP.ROLE.057
#
# Проверяет:
#   - Обязательные поля frontmatter (name, description, version, layer, status, triggers)
#   - Формат semver для version
#   - Допустимые значения layer (L1|L3) и status (active|experimental|deprecated)
#   - Наличие хотя бы одного slash-триггера
#   - depends_on ссылается на существующие скиллы (предупреждение, не блокер)
#
# Использование:
#   bash validate-skill.sh <skill-id> [--skills-dir <path>]
#
# Exit 0 = OK, Exit 1 = ошибка валидации

set -uo pipefail

IWE="${IWE_WORKSPACE:-$HOME/IWE}"
SKILLS_DIR="${IWE}/.claude/skills"
skill_id=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skills-dir) SKILLS_DIR="$2"; shift 2 ;;
        -*)           echo "Неизвестный флаг: $1" >&2; exit 1 ;;
        *)            [[ -z "$skill_id" ]] && skill_id="$1" || { echo "Лишний аргумент: $1" >&2; exit 1; }; shift ;;
    esac
done

if [[ -z "$skill_id" ]]; then
    echo "Использование: $0 <skill-id> [--skills-dir <path>]" >&2
    exit 1
fi

skill_md="${SKILLS_DIR}/${skill_id}/SKILL.md"
if [[ ! -f "$skill_md" ]]; then
    echo "❌ SKILL.md не найден: $skill_md" >&2
    exit 1
fi

errors=0
warnings=0

fail() { echo "  ❌ $*"; (( errors++ )) || true; }
warn() { echo "  ⚠️  $*"; (( warnings++ )) || true; }
ok()   { echo "  ✅ $*"; }

echo "🔍 Валидация скилла: $skill_id"
echo "   Файл: $skill_md"
echo ""

# ── 1. Наличие frontmatter ──────────────────────────────────────────────────
if ! head -1 "$skill_md" | grep -q "^---"; then
    fail "Отсутствует frontmatter (файл не начинается с ---)"
    echo ""
    echo "📊 Итого: ошибок=$errors, предупреждений=$warnings"
    exit 1
fi

# Вспомогательная функция: получить значение поля из frontmatter
get_field() {
    local field="$1"
    sed -n "/^---$/,/^---$/p" "$skill_md" 2>/dev/null \
      | grep "^${field}:" \
      | head -1 \
      | sed "s/^${field}: *//" \
      | sed 's/^"\(.*\)"$/\1/' \
      | sed "s/^'\(.*\)'$/\1/" \
      | tr -d '\r'
}

# ── 2. Обязательные поля ────────────────────────────────────────────────────
name_val=$(get_field "name")
if [[ -z "$name_val" ]]; then
    fail "Поле 'name' отсутствует или пусто"
else
    ok "name: $name_val"
fi

desc_val=$(get_field "description")
if [[ -z "$desc_val" ]]; then
    fail "Поле 'description' отсутствует или пусто"
elif echo "$desc_val" | grep -qi "TODO"; then
    fail "description содержит TODO-заглушку: $desc_val"
else
    ok "description: ${desc_val:0:60}..."
fi

version_val=$(get_field "version")
if [[ -z "$version_val" ]]; then
    fail "Поле 'version' отсутствует"
elif ! echo "$version_val" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    fail "version не semver: '$version_val' (ожидается X.Y.Z)"
else
    ok "version: $version_val"
fi

layer_val=$(get_field "layer")
if [[ -z "$layer_val" ]]; then
    fail "Поле 'layer' отсутствует"
elif [[ "$layer_val" != "L1" && "$layer_val" != "L3" ]]; then
    fail "layer должен быть L1 или L3 (получено: '$layer_val')"
else
    ok "layer: $layer_val"
fi

status_val=$(get_field "status")
if [[ -z "$status_val" ]]; then
    fail "Поле 'status' отсутствует"
elif [[ "$status_val" != "active" && "$status_val" != "experimental" && "$status_val" != "deprecated" ]]; then
    fail "status должен быть active|experimental|deprecated (получено: '$status_val')"
else
    ok "status: $status_val"
fi

# ── 3. triggers ─────────────────────────────────────────────────────────────
if ! sed -n "/^---$/,/^---$/p" "$skill_md" | grep "^triggers:" > /dev/null; then
    fail "Поле 'triggers' отсутствует"
else
    slash_val=$(sed -n '/^triggers:/,/^[a-z]/p' "$skill_md" \
        | grep "slash:" \
        | sed 's/.*slash: *\[//;s/\].*//' \
        | tr -d ' ')
    if [[ -z "$slash_val" || "$slash_val" == "" ]]; then
        fail "triggers.slash пуст — нужен хотя бы один slash-триггер (напр. [/${skill_id}])"
    else
        ok "triggers.slash: [$slash_val]"
    fi
fi

# ── 4. Проверка depends_on (предупреждение) ─────────────────────────────────
catalog="${IWE}/.claude/skills-catalog.yaml"
depends_line=$(grep "^depends_on:" "$skill_md" 2>/dev/null | head -1 || echo "")
if [[ -n "$depends_line" ]] && [[ "$depends_line" != "# depends_on: []" ]]; then
    deps=$(echo "$depends_line" | sed 's/^depends_on: *//;s/\[//;s/\]//;s/,/ /g')
    for dep in $deps; do
        dep=$(echo "$dep" | tr -d ' ')
        [[ -z "$dep" ]] && continue
        if [[ -f "$catalog" ]]; then
            if ! grep -q "^  - id: ${dep}$" "$catalog" 2>/dev/null; then
                warn "depends_on: скилл '${dep}' не найден в skills-catalog.yaml"
            else
                ok "depends_on: ${dep} ✓ (в каталоге)"
            fi
        else
            warn "depends_on: skills-catalog.yaml не найден — пропуск проверки"
        fi
    done
fi

# ── 5. Проверка TODO-заглушек в теле ────────────────────────────────────────
todo_count=$(grep -c "^TODO\b\|^\*\*.*TODO\|: TODO$" "$skill_md" 2>/dev/null) || todo_count=0
if [[ "$todo_count" -gt 0 ]]; then
    warn "В теле SKILL.md найдено TODO-заглушек: $todo_count (рекомендуется заполнить перед promote)"
fi

# ── 6. Deprecated без sunset ────────────────────────────────────────────────
if [[ "$status_val" == "deprecated" ]]; then
    sunset_val=$(get_field "sunset")
    if [[ -z "$sunset_val" ]]; then
        warn "status: deprecated без поля 'sunset:' — рекомендуется указать дату удаления"
    fi
fi

# ── Итог ────────────────────────────────────────────────────────────────────
echo ""
echo "📊 Итого: ошибок=$errors, предупреждений=$warnings"

if [[ $errors -gt 0 ]]; then
    echo "❌ Скилл НЕ прошёл валидацию — исправьте ошибки перед promote"
    exit 1
else
    echo "✅ Скилл прошёл валидацию"
    if [[ $warnings -gt 0 ]]; then
        echo "   (${warnings} предупреждений — не блокируют promote, но рекомендуется исправить)"
    fi
    exit 0
fi
