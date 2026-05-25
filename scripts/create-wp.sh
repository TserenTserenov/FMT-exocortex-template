#!/usr/bin/env bash
# routing: helper  skill=wp-new  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# create-wp.sh — атомарное создание РП в 4 местах (inbox, REGISTRY, WeekPlan, Linear)
# see DP.M.010, DP.ROLE.037
# see DP.M.010, DP.ROLE.037
#
# Использование:
#   bash create-wp.sh --title "Название" --budget 5h --priority P3 [--slug slug] [--repo "репо"] [--related "WP-150:dependency,WP-167:продукт"]
#   bash create-wp.sh --title "Название" --budget 5h --priority P3 --no-consent-check
#
# Предусловие: consent state file должен существовать:
#   touch /IWE/.claude/state/wp-consent-{N}
#
# Совместимость: bash 3.2+ (macOS), bash 4+ (Linux)

set -uo pipefail

IWE="${IWE_ROOT:-$HOME/IWE}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
STRATEGY="$IWE/$GOV_REPO"
REGISTRY="$STRATEGY/docs/WP-REGISTRY.md"
INBOX="$STRATEGY/inbox"
STATE_DIR="$IWE/.claude/state"

# --- Параметры ---
TITLE=""
BUDGET=""
PRIORITY="P3"
SLUG=""
REPO=""
RELATED=""
SKIP_CONSENT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)    TITLE="$2";    shift 2 ;;
    --budget)   BUDGET="$2";   shift 2 ;;
    --priority) PRIORITY="$2"; shift 2 ;;
    --slug)     SLUG="$2";     shift 2 ;;
    --repo)     REPO="$2";     shift 2 ;;
    --related)  RELATED="$2";  shift 2 ;;
    --no-consent-check) SKIP_CONSENT=1; shift ;;
    *) echo "Неизвестный флаг: $1" >&2; exit 1 ;;
  esac
done

# --- Валидация ---
if [[ -z "$TITLE" || -z "$BUDGET" ]]; then
  echo "Использование: $0 --title \"Название\" --budget 5h [--priority P3] [--slug slug] [--repo репо] [--related \"WP-NNN:тип\"]" >&2
  exit 1
fi

# --- Найти следующий номер WP ---
WP_NUM=$(python3 - "$REGISTRY" <<'PYEOF' 2>/dev/null
import sys, re
registry = sys.argv[1]
max_num = 0
try:
    with open(registry, "r", encoding="utf-8") as f:
        for line in f:
            # Ищем строки вида | 297 | или | ~~297~~ |
            m = re.match(r"^\|\s*~*(\d+)~*\s*\|", line)
            if m:
                n = int(m.group(1))
                if n > max_num:
                    max_num = n
except Exception as e:
    print(0, file=sys.stderr)
print(max_num + 1)
PYEOF
)

if [[ -z "$WP_NUM" || "$WP_NUM" -le 0 ]]; then
  echo "❌ Не удалось определить следующий номер WP из REGISTRY" >&2
  exit 1
fi

echo "📋 Следующий номер WP: $WP_NUM"

# --- Проверка consent ---
CONSENT_FILE="$STATE_DIR/wp-consent-${WP_NUM}"
if [[ "$SKIP_CONSENT" -eq 0 ]]; then
  if [[ ! -f "$CONSENT_FILE" ]]; then
    echo "🚫 WP Gate: нет согласия пользователя на создание WP-${WP_NUM}" >&2
    echo "   Создайте consent file и повторите:" >&2
    echo "   touch $CONSENT_FILE" >&2
    exit 1
  fi
  echo "✅ Consent: $CONSENT_FILE"
fi

# --- Дата ---
TODAY=$(date +%Y-%m-%d)

# --- Slug из title (если не задан) ---
if [[ -z "$SLUG" ]]; then
  SLUG=$(echo "$TITLE" | python3 -c "
import sys, re, unicodedata
s = sys.stdin.read().strip().lower()
# Транслитерация кириллицы
tr = {
  'а':'a','б':'b','в':'v','г':'g','д':'d','е':'e','ё':'yo','ж':'zh',
  'з':'z','и':'i','й':'j','к':'k','л':'l','м':'m','н':'n','о':'o',
  'п':'p','р':'r','с':'s','т':'t','у':'u','ф':'f','х':'kh','ц':'ts',
  'ч':'ch','ш':'sh','щ':'shch','ъ':'','ы':'y','ь':'','э':'e','ю':'yu','я':'ya'
}
result = ''
for c in s:
    result += tr.get(c, c)
result = re.sub(r'[^a-z0-9]+', '-', result)
result = result.strip('-')[:40]
print(result)
" 2>/dev/null || echo "wp-$(echo "$TITLE" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | cut -c1-30)")
fi

WP_FILE="$INBOX/WP-${WP_NUM}-${SLUG}.md"

echo "🚀 Создаю WP-${WP_NUM}: $TITLE"
echo "   Файл: inbox/WP-${WP_NUM}-${SLUG}.md"
echo "   Бюджет: $BUDGET | Приоритет: $PRIORITY"

# --- Сформировать строки таблицы связок ---
RELATED_ROWS="| — | — | — | нет связок |"
if [[ -n "$RELATED" ]]; then
  RELATED_ROWS=""
  IFS=',' read -ra REL_ITEMS <<< "$RELATED"
  for rel_item in "${REL_ITEMS[@]}"; do
    rel_item="${rel_item# }"
    rel_wp="${rel_item%%:*}"
    rel_type="${rel_item#*:}"
    [[ "$rel_wp" == "$rel_type" ]] && rel_type="—"
    RELATED_ROWS+="| ${rel_wp} | 🟡 | ${rel_type} | — |
"
  done
fi

# --- Шаг 1: context file ---
echo ""
echo "1/4 context file..."

cat > "$WP_FILE" <<WPEOF
---
wp: ${WP_NUM}
title: "${TITLE}"
status: pending
priority: ${PRIORITY}
budget: ${BUDGET}
created: ${TODAY}
last_session: ${TODAY}
related: []
---

# WP-${WP_NUM}: ${TITLE}

## Проблема

[Описать неудовлетворённость / проблему, которую решает этот РП]

## Артефакт

[Конкретный результат — существительное-артефакт с критериями]

## Связки с РП

| РП | Сила | Тип | Что передаётся |
|----|------|-----|----------------|
${RELATED_ROWS}

## Фазы реализации

### Ф1 — [Название фазы] (~?h)

- [ ] ...

## Что узнали

[Заполняется при сессиях]

## Осталось

**Что пробовали:** не начат
**Что узнали:** —
  → memory: не нужно
**Что дальше:**
- [ ] Открыть сессию, прочитать задачу, составить план
**Следующий шаг:** Открыть сессию — прочитать задачу, составить план
**Контекст для следующей сессии:** РП только создан, нет контекста
WPEOF

echo "   ✅ $WP_FILE"

# --- Шаг 2: WP-REGISTRY.md ---
echo "2/4 WP-REGISTRY.md..."

python3 - "$REGISTRY" "$WP_NUM" "$PRIORITY" "$TITLE" "$REPO" "$BUDGET" "$GOV_REPO" <<'PYEOF'
import sys
registry_path, wp_num, priority, title, repo, budget, gov_repo = sys.argv[1:8]

with open(registry_path, "r", encoding="utf-8") as f:
    lines = f.readlines()

# Найти строку-разделитель после заголовка таблицы (|---|---|...)
insert_at = None
for i, line in enumerate(lines):
    if line.strip().startswith("|---") and i > 0 and lines[i-1].strip().startswith("| #"):
        insert_at = i + 1
        break

if insert_at is None:
    print("❌ Не найден заголовок таблицы REGISTRY", file=sys.stderr)
    sys.exit(1)

repo_cell = repo if repo else "{}/inbox/WP-{}-*.md".format(gov_repo, wp_num)
new_row = "| {} | {} | **{}** | ⏳ | {} | {} |\n".format(
    wp_num, priority, title, repo_cell, budget
)
lines.insert(insert_at, new_row)

with open(registry_path, "w", encoding="utf-8") as f:
    f.writelines(lines)

print("   ✅ REGISTRY: строка {} добавлена".format(wp_num))
PYEOF

# --- Шаг 3: WeekPlan ---
echo "3/4 WeekPlan..."

WEEKPLAN=$(find "$STRATEGY/current" -maxdepth 1 -name "WeekPlan W*.md" 2>/dev/null | sort -r | head -1)

if [[ -n "$WEEKPLAN" ]]; then
  python3 - "$WEEKPLAN" "$WP_NUM" "$TITLE" "$PRIORITY" "$BUDGET" "$GOV_REPO" <<'PYEOF'
import sys, re
weekplan_path, wp_num, title, priority, budget, gov_repo = sys.argv[1:7]

# Маппинг приоритета → светофор
flag_map = {"P1": "🔴", "P2": "🟡", "P3": "🟢", "P4": "⚪", "P5": "⚪"}
flag = flag_map.get(priority, "⚪")

with open(weekplan_path, "r", encoding="utf-8") as f:
    content = f.read()

# Найти "Бюджет итого" строку и вставить перед ней
anchor = "**Бюджет итого:**"
# Убрать часы из budget для поля h
h_val = re.sub(r"[^0-9\-]", "", budget) or "?"

new_row = "| {} | {} | **{}** — [описание] | {} | pending | W{} | {} |\n".format(
    flag, wp_num, title, h_val,
    re.search(r"W(\d+)", weekplan_path).group(1) if re.search(r"W(\d+)", weekplan_path) else "?",
    gov_repo + "/inbox"
)

if anchor in content:
    content = content.replace(anchor, new_row + anchor)
    with open(weekplan_path, "w", encoding="utf-8") as f:
        f.write(content)
    print("   ✅ WeekPlan: строка WP-{} добавлена".format(wp_num))
else:
    print("   ⚠️  WeekPlan: якорь 'Бюджет итого' не найден — добавить вручную", file=sys.stderr)
PYEOF
else
  echo "   ⚠️  WeekPlan не найден в current/ — добавить вручную" >&2
fi

# --- Шаг 4: Linear ---
echo "4/4 Linear: создать issue вручную или через MCP (create-wp.sh не имеет MCP доступа)"
echo "   ℹ️  Запустить после скрипта: Linear MCP → create_issue title='WP-${WP_NUM} ${TITLE}' teamId=TSR"

# --- Удалить consent file ---
if [[ "$SKIP_CONSENT" -eq 0 && -f "$CONSENT_FILE" ]]; then
  rm -f "$CONSENT_FILE"
  echo ""
  echo "🗑  Consent file удалён: $CONSENT_FILE"
fi

echo ""
echo "✅ WP-${WP_NUM} создан: $TITLE"
echo "   context: inbox/WP-${WP_NUM}-${SLUG}.md"
echo "   Следующий шаг: заполнить «Проблема», «Артефакт», «Фазы» в context file"
echo "   Не забыть: Linear issue + (если ≥3h) Strategy.md маппинг"
