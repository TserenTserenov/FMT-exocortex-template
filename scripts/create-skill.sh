#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# create-skill.sh — создать scaffold нового скилла IWE (SKILL.md v2)
# see DP.SC.153, DP.ROLE.057
#
# Использование:
#   bash create-skill.sh <skill-id> [--layer L1|L3] [--owner-role R6] [--skills-dir <path>]
#
# После создания:
#   1. Заполнить SKILL.md v2 (обещание, алгоритм, режим отказа)
#   2. bash validate-skill.sh <skill-id>
#   3. Smoke-test
#   4. Если L1 → bash skill-promote.sh ...

set -uo pipefail

IWE="${IWE_WORKSPACE:-$HOME/IWE}"
SKILLS_DIR="${IWE}/.claude/skills"
layer="L3"
owner_role=""
skill_id=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skills-dir) SKILLS_DIR="$2"; shift 2 ;;
        --layer)      layer="$2"; shift 2 ;;
        --owner-role) owner_role="$2"; shift 2 ;;
        -*)           echo "Неизвестный флаг: $1" >&2; exit 1 ;;
        *)            [[ -z "$skill_id" ]] && skill_id="$1" || { echo "Лишний аргумент: $1" >&2; exit 1; }; shift ;;
    esac
done

if [[ -z "$skill_id" ]]; then
    echo "Использование: $0 <skill-id> [--layer L1|L3] [--owner-role R#] [--skills-dir <path>]" >&2
    exit 1
fi

# Валидация skill-id: kebab-case, только строчные
if ! echo "$skill_id" | grep -qE '^[a-z][a-z0-9-]*$'; then
    echo "❌ skill-id должен быть kebab-case (строчные буквы, цифры, дефис): $skill_id" >&2
    exit 1
fi

# Валидация layer
if [[ "$layer" != "L1" && "$layer" != "L3" ]]; then
    echo "❌ --layer должен быть L1 или L3 (получено: $layer)" >&2
    exit 1
fi

# Проверить что скилл не существует
skill_dir="${SKILLS_DIR}/${skill_id}"
if [[ -d "$skill_dir" ]]; then
    echo "❌ Скилл уже существует: $skill_dir" >&2
    echo "   Выберите другой id или используйте существующий скилл." >&2
    exit 1
fi

# Проверить дубликат имени в skills-catalog.yaml
catalog="${IWE}/.claude/skills-catalog.yaml"
if [[ -f "$catalog" ]]; then
    if grep -q "^  - id: ${skill_id}$" "$catalog" 2>/dev/null; then
        echo "❌ Скилл '$skill_id' уже в каталоге. Выберите другой id." >&2
        exit 1
    fi
fi

# Создать директорию и SKILL.md v2
mkdir -p "$skill_dir"

# Опциональная строка owner_role
owner_line=""
[[ -n "$owner_role" ]] && owner_line="
owner_role: ${owner_role}               # роль-носитель скилла"

cat > "${skill_dir}/SKILL.md" <<SKILLEOF
---
# see DP.SC.153, DP.ROLE.057
name: ${skill_id}
description: "TODO: одна строка — что делает скилл"
version: 1.0.0
layer: ${layer}
status: active${owner_line}
triggers:
  slash: [/${skill_id}]
  phrases: []
# depends_on: []
---

# /${skill_id} — TODO: Название скилла

> **Роль:** TODO: [R# Название]
> **Триггер:** TODO: [когда вызывается]
> **Service Clause:** DP.SC.153

## Обещание (контракт)

**Вход:** TODO
**Выход:** TODO
**Инвариант:** TODO

## Алгоритм

### Шаг 1. TODO

TODO

## Режим отказа

| Сценарий | Поведение |
|---------|-----------|
| TODO | TODO |
SKILLEOF

echo "✅ Скилл создан: ${skill_dir}/SKILL.md"
echo ""
echo "Следующие шаги:"
echo "  1. Заполнить SKILL.md (description, обещание, алгоритм, режим отказа)"
echo "  2. bash validate-skill.sh ${skill_id}"
echo "  3. Smoke-test: вызвать /${skill_id} и убедиться что работает"
echo "  4. Если скилл входит в стратегические/фасилитационные категории — добавить id в RECALL_SKILLS hindsight_trigger.py для LLM-retain"
if [[ "$layer" == "L1" ]]; then
    FMT_DIR="${IWE_TEMPLATE:-${IWE}/FMT-exocortex-template}"
    echo "  4. bash ${FMT_DIR}/scripts/skill-promote.sh ${skill_dir}/"
fi
