#!/usr/bin/env bash
# routing: helper  skill=week-close  called-by=sonnet
# see DP.SC.159, DP.ROLE.059
# archive-done-wp.sh — атомарная архивация завершённого РП
# see DP.M.010, DP.SC.033 (WP-297)
#
# Шаги:
#   1. Найти inbox/WP-{N}-*.md по номеру
#   2. Обновить frontmatter: status → done
#   3. git mv inbox/ → archive/wp-contexts/
#
# Использование:
#   bash archive-done-wp.sh <WP_NUM> [IWE_ROOT]
#
# Совместимость: bash 3.2+ (macOS), bash 4+ (Linux)

set -uo pipefail

WP_NUM="${1:-}"
IWE="${2:-${IWE_ROOT:-$HOME/IWE}}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
INBOX="$IWE/$GOV_REPO/inbox"
ARCHIVE="$IWE/$GOV_REPO/archive/wp-contexts"
STRATEGY_REPO="$IWE/$GOV_REPO"

if [[ -z "$WP_NUM" ]]; then
  echo "Использование: $0 <WP_NUM> [IWE_ROOT]" >&2
  exit 1
fi

# Убрать префикс WP- если передали
WP_NUM="${WP_NUM#WP-}"

# Найти файл
WP_FILE=$(find "$INBOX" -maxdepth 1 -name "WP-${WP_NUM}-*.md" 2>/dev/null | head -1)

if [[ -z "$WP_FILE" ]]; then
  echo "❌ WP-${WP_NUM}: файл не найден в $INBOX" >&2
  exit 1
fi

FILENAME=$(basename "$WP_FILE")
ARCHIVE_TARGET="$ARCHIVE/$FILENAME"

echo "📦 Архивирую WP-${WP_NUM}: $FILENAME"

# 1. Обновить frontmatter status → done
# Ищем первый фронтматтер (между --- и ---)
TMP=$(mktemp)
python3 - "$WP_FILE" "$TMP" <<'PYEOF'
import sys, re

src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", encoding="utf-8") as f:
    content = f.read()

# Заменить status: in_progress | status: active → status: done
# Только внутри первого frontmatter блока
lines = content.split("\n")
in_fm = False
fm_closed = False
new_lines = []
for line in lines:
    if line.strip() == "---" and not fm_closed:
        if not in_fm:
            in_fm = True
        else:
            in_fm = False
            fm_closed = True
        new_lines.append(line)
        continue
    if in_fm and re.match(r"^status:\s*(in_progress|active)\s*$", line):
        line = "status: done"
    new_lines.append(line)

with open(dst, "w", encoding="utf-8") as f:
    f.write("\n".join(new_lines))
print("ok")
PYEOF

if [[ $? -ne 0 ]]; then
  echo "❌ Ошибка обновления frontmatter" >&2
  rm -f "$TMP"
  exit 1
fi

# Проверить что статус изменился
if ! grep -q "^status: done" "$TMP" 2>/dev/null; then
  echo "⚠️  frontmatter status уже done или не найден — продолжаю"
fi

cp "$TMP" "$WP_FILE"
rm -f "$TMP"

# 2. git mv (из STRATEGY_REPO)
if ! git -C "$STRATEGY_REPO" mv "inbox/$FILENAME" "archive/wp-contexts/$FILENAME" 2>/dev/null; then
  echo "⚠️  git mv не удался — пробую обычный mv"
  mkdir -p "$ARCHIVE"
  mv "$WP_FILE" "$ARCHIVE_TARGET"
fi

echo "✅ WP-${WP_NUM} → archive/wp-contexts/$FILENAME"
echo "   Следующий шаг: обновить WP-REGISTRY.md + коммит"

# ОПТ-7: уведомление related.enables
ENABLES=$(python3 - "$ARCHIVE_TARGET" "$WP_NUM" <<'PYEOF'
import sys, re

archive_file, closed_wp = sys.argv[1], sys.argv[2]
enables = []
try:
    with open(archive_file, "r", encoding="utf-8") as f:
        content = f.read()
    # Найти frontmatter (между первыми ---)
    fm_match = re.match(r"^---\n(.*?)\n---", content, re.DOTALL)
    if not fm_match:
        sys.exit(0)
    fm = fm_match.group(1)
    # Найти блоки - wp: N / relation: enables
    # YAML-like поиск без yaml-парсера (bash 3.2 совместимость)
    blocks = re.split(r"\n\s*-\s+", fm)
    for block in blocks:
        if re.search(r"relation:\s*enables", block):
            m = re.search(r"wp:\s*(\d+)", block)
            if m:
                enables.append(m.group(1))
except Exception:
    pass

for n in enables:
    print(n)
PYEOF
)

if [[ -n "$ENABLES" ]]; then
  echo ""
  echo "🔓 WP-${WP_NUM} закрыт → разблокированы РП (relation: enables):"
  while IFS= read -r wp_n; do
    echo "   → WP-${wp_n} (проверьте: был ли blocked_by WP-${WP_NUM}?)"
  done <<< "$ENABLES"
fi
