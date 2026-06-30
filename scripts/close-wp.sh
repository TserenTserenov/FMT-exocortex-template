#!/usr/bin/env bash
# routing: helper  skill=wp-close  called-by=agent
# Закрытие РП: зачёркивает строку в REGISTRY, дописывает ## Закрытие в archive/wp-contexts/
# see DP.SC.159, DP.ROLE.037
#
# Использование:
#   bash close-wp.sh --wp 374 --summary "Итог: AR.3+AR.4 готовы, 39 тестов PASS"
#   bash close-wp.sh --wp 374 --summary "..." --reason "Завершены все фазы"
#
# Совместимость: bash 3.2+ (macOS), bash 4+ (Linux)

set -uo pipefail

IWE="${IWE_ROOT:-$HOME/IWE}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
STRATEGY="$IWE/$GOV_REPO"
REGISTRY="$STRATEGY/docs/WP-REGISTRY.md"
ARCHIVE_DIR="$STRATEGY/archive/wp-contexts"

WP_NUM=""
SUMMARY=""
REASON=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wp)      WP_NUM="$2";   shift 2 ;;
    --summary) SUMMARY="$2";  shift 2 ;;
    --reason)  REASON="$2";   shift 2 ;;
    *) echo "Неизвестный флаг: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$WP_NUM" ]]; then
  echo "Использование: $0 --wp NNN --summary \"Итог\" [--reason \"Причина\"]" >&2
  exit 1
fi

TODAY=$(date +%Y-%m-%d)

# --- Шаг 1: зачеркнуть строку в REGISTRY ---
echo "1/3 Обновляю REGISTRY..."

python3 - "$REGISTRY" "$WP_NUM" <<'PYEOF'
import sys, re
registry_path, wp_num = sys.argv[1], sys.argv[2]

with open(registry_path, "r", encoding="utf-8") as f:
    lines = f.readlines()

changed = False
for i, line in enumerate(lines):
    # Ищем строку с данным номером WP (активную — без ~~NNN~~)
    m = re.match(r"^(\|\s*)(\*\*)?(" + re.escape(wp_num) + r")(\*\*)?(\s*\|)", line)
    pipe_pos = line.find("|", 1)
    if m and (pipe_pos == -1 or "~~" not in line[:pipe_pos]):
        # Зачеркнуть все поля: | N | P | Название | ... |
        # Паттерн: разбить по | и обернуть каждую ячейку в ~~...~~ (кроме эмодзи-статуса)
        def strikethrough_cell(cell):
            stripped = cell.strip()
            # Не трогать: пустые, эмодзи-статусы (✅ ↗️ 📦 ⏳), разделители ---
            if not stripped or stripped in ("✅", "↗️", "📦", "⏳", "🔄"):
                return " " + stripped + " "
            # Убрать существующие ** вокруг содержимого
            stripped = re.sub(r"^\*\*(.+)\*\*$", r"\1", stripped)
            # Убрать лишние closure-notes ВНУТРИ ~~ (если были)
            # Очистить: всё после ~~ — closed или ~~ (подробности
            stripped = re.sub(r"~~(.+?)~~\s*(?:—\s*closed\b.*|—\s*Ф\d[^$]*|\((?:peer-session|PHASE)[^)]*\).*)?$",
                              r"~~\1~~", stripped, flags=re.DOTALL)
            if stripped.startswith("~~") and stripped.endswith("~~"):
                return " " + stripped + " "
            # Удалить closure-notes из имени
            clean = re.sub(r"\s*—\s*closed\b.*$", "", stripped, flags=re.DOTALL)
            clean = re.sub(r"\s*—\s*closed-partial\b.*$", "", clean, flags=re.DOTALL)
            clean = re.sub(r"\s*—\s*Ф\d[^|]*$", "", clean, flags=re.DOTALL)
            clean = re.sub(r"\s*\((?:peer-session|PHASE\d|backlinks)[^)]*\).*$", "", clean, flags=re.DOTALL)
            clean = clean.strip()
            if clean:
                return " ~~" + clean + "~~ "
            return " " + stripped + " "

        parts = line.rstrip("\n").split("|")
        new_parts = []
        for j, part in enumerate(parts):
            if j == 0 or j == len(parts) - 1:
                new_parts.append(part)
            else:
                new_parts.append(strikethrough_cell(part))
        lines[i] = "|".join(new_parts) + "\n"
        changed = True
        break

if not changed:
    print(f"   ⚠️  Строка WP-{wp_num} не найдена или уже зачёркнута", file=sys.stderr)
    sys.exit(0)

with open(registry_path, "w", encoding="utf-8") as f:
    f.writelines(lines)

print(f"   ✅ REGISTRY: WP-{wp_num} зачёркнут")
PYEOF

# --- Шаг 2: найти или создать archive/wp-contexts файл ---
echo "2/3 Дописываю archive/wp-contexts..."

mkdir -p "$ARCHIVE_DIR"

# Ищем существующий файл для этого WP
CONTEXT_FILE=$(find "$ARCHIVE_DIR" -name "WP-${WP_NUM}-*.md" 2>/dev/null | sort | head -1)

if [[ -z "$CONTEXT_FILE" ]]; then
  # Создать новый файл с минимальной структурой
  # Определить slug из REGISTRY
  SLUG=$(python3 - "$REGISTRY" "$WP_NUM" <<'PYEOF2'
import sys, re
registry_path, wp_num = sys.argv[1], sys.argv[2]
with open(registry_path, "r", encoding="utf-8") as f:
    for line in f:
        # Ищем строку с этим WP (теперь уже зачёркнутую)
        if re.search(r"~~" + re.escape(wp_num) + r"~~", line):
            # Извлечь название из колонки имени (3-я колонка)
            parts = line.split("|")
            if len(parts) >= 4:
                name = parts[3].strip().strip("~").strip("*").strip()
                # Сделать slug
                slug = re.sub(r"[^a-zа-яёА-ЯЁ0-9\s-]", "", name.lower())
                slug = re.sub(r"\s+", "-", slug.strip())[:40].strip("-")
                print(slug or "context")
                sys.exit(0)
print("context")
PYEOF2
  )
  CONTEXT_FILE="$ARCHIVE_DIR/WP-${WP_NUM}-${SLUG}.md"
  cat > "$CONTEXT_FILE" <<CTXEOF
---
wp: ${WP_NUM}
created: ${TODAY}
---

# WP-${WP_NUM} — Контекст

CTXEOF
  echo "   ✅ Создан новый файл: $(basename "$CONTEXT_FILE")"
fi

# Определить язык файла (русский если есть кириллица в заголовках)
LANG_HEADER="## Закрытие"
if python3 -c "
import sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    content = f.read()
# Если большинство заголовков на английском
import re
en_headers = len(re.findall(r'^## [A-Z]', content, re.MULTILINE))
ru_headers = len(re.findall(r'^## [А-Я]', content, re.MULTILINE))
sys.exit(0 if ru_headers >= en_headers else 1)
" "$CONTEXT_FILE" 2>/dev/null; then
  LANG_HEADER="## Закрытие"
else
  LANG_HEADER="## Closure"
fi

# Проверить, есть ли уже секция Закрытие/Closure
if grep -q "^## Закрытие\|^## Closure" "$CONTEXT_FILE" 2>/dev/null; then
  echo "   ℹ️  Секция '${LANG_HEADER}' уже есть, дописываю..."
  # Дописать к существующей секции
  python3 - "$CONTEXT_FILE" "$TODAY" "$SUMMARY" "$REASON" <<'PYEOF3'
import sys
path, today, summary, reason = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()
addition = f"\n**Дата:** {today}"
if summary:
    addition += f"\n**Итог:** {summary}"
if reason:
    addition += f"\n**Причина закрытия:** {reason}"
addition += "\n"
import re
content = re.sub(r"(^## (?:Закрытие|Closure).*?)(\n^## )", addition + r"\2", content,
                 count=1, flags=re.MULTILINE | re.DOTALL)
if addition not in content:
    content = content.rstrip() + addition
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("   ✅ Дописано в существующую секцию")
PYEOF3
else
  # Дописать секцию в конец файла
  {
    echo ""
    echo "${LANG_HEADER}"
    echo ""
    echo "**Дата:** ${TODAY}"
    [[ -n "$SUMMARY" ]] && echo "**Итог:** ${SUMMARY}"
    [[ -n "$REASON" ]] && echo "**Причина закрытия:** ${REASON}"
    echo ""
  } >> "$CONTEXT_FILE"
  echo "   ✅ Добавлена секция '${LANG_HEADER}'"
fi

# --- Шаг 3: обновить статус в inbox/WP-NNN*.md ---
echo "3/3 Обновляю inbox/WP-${WP_NUM}..."

INBOX_FILE=$(find "$STRATEGY/inbox" -maxdepth 2 -name "WP-${WP_NUM}.md" -o -name "WP-${WP_NUM}-*.md" 2>/dev/null | grep -v "^$STRATEGY/inbox/WP-${WP_NUM}/" | sort | head -1)

if [[ -n "$INBOX_FILE" ]]; then
  python3 - "$INBOX_FILE" "$TODAY" <<'PYEOF4'
import sys, re
path, today = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()
# Обновить status: в frontmatter
content = re.sub(r"^(status:\s*).*$", r"\1done", content, count=1, flags=re.MULTILINE)
# Добавить closed_date если нет
if "closed_date:" not in content:
    content = re.sub(r"^(created:.*\n)", r"\1closed_date: " + today + "\n", content,
                     count=1, flags=re.MULTILINE)
else:
    content = re.sub(r"^(closed_date:\s*).*$", r"\1" + today, content,
                     count=1, flags=re.MULTILINE)
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print(f"   ✅ inbox: status=done, closed_date={today}")
PYEOF4
else
  echo "   ⚠️  inbox/WP-${WP_NUM}*.md не найден — обновить вручную"
fi

echo ""
echo "✅ WP-${WP_NUM} закрыт"
echo "   Контекст: $(basename "${CONTEXT_FILE}")"
echo "   Следующий шаг: git add + commit оба файла"
