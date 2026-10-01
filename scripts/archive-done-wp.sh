#!/usr/bin/env bash
# routing: helper  called-by=day-close  deterministic=true
# see DP.SC.159, DP.ROLE.059
# archive-done-wp.sh — атомарная архивация завершённого РП
# see DP.M.010, DP.SC.033 (WP-297)
# see WP-5 (фаза «Проверка полноты переноса перед архивацией inbox/WP-N»,
# 2026-07-10) — переписан под папочную конвенцию WP-434 + подключён
# check-wp-transfer-completeness.sh
#
# Шаги:
#   1. Найти inbox/WP-{N}/WP-{N}.md (папочная конвенция WP-434);
#      fallback — устаревший плоский inbox/WP-{N}-*.md.
#   2. Прогнать check-wp-transfer-completeness.sh (warn-not-block).
#   3. Обновить frontmatter: status → done.
#   4. git mv папку (или файл) inbox/ → archive/wp-contexts/.
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
# check-wp-transfer-completeness.sh lives next to this script — resolve relative to
# self so both the root copy and the promoted template copy find their own sibling.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/check-wp-transfer-completeness.sh"

_WPN_ROOT_UP=".."
_WPN_OPTIONAL=""
# >>> wp-num locate
# Find scripts/lib/wp-num.sh (issue #954) from THIS file's own location with symlinks
# resolved, never from IWE_WORKSPACE / IWE_ROOT / STRATEGY_DIR: callers point those at
# fixtures. Candidates, in order: lib/ next to the file, <root>/scripts/lib, the template
# clone next to a delivered workspace (<root>/FMT-exocortex-template), the explicit
# IWE_TEMPLATE. <root> is _WPN_ROOT_UP above the file's directory (set by each consumer
# just above this block: the only per-file difference, checked by test_issue_954_locate.sh).
# The library is mandatory: not finding it is an installation error, not "WP not found",
# hence exit 4 and not 1 (memory/protocol-open.md reads exit 1 as "РП не найден").
# A consumer that must keep working without the library (session-guard: its hypothesis gate
# warns and checks the exact card names, it never blocks a session over a missing library)
# sets _WPN_OPTIONAL=1 next to _WPN_ROOT_UP: WP_NUM_LIB then stays empty and nothing is sourced.
_wpn_src="${BASH_SOURCE[0]}"
_wpn_hops=0
while [ -L "$_wpn_src" ] && [ "$_wpn_hops" -lt 40 ]; do
  _wpn_link="$(readlink "$_wpn_src")"
  case "$_wpn_link" in
    /*) _wpn_src="$_wpn_link" ;;
    *) _wpn_src="$(dirname "$_wpn_src")/$_wpn_link" ;;
  esac
  _wpn_hops=$((_wpn_hops + 1))
done
_wpn_dir="$(cd -P "$(dirname "$_wpn_src")" && pwd)"
_wpn_root="$(cd -P "$_wpn_dir/$_WPN_ROOT_UP" && pwd)"
WP_NUM_LIB=""
for _wpn_cand in "$_wpn_dir/lib/wp-num.sh" \
                 "$_wpn_root/scripts/lib/wp-num.sh" \
                 "$_wpn_root/FMT-exocortex-template/scripts/lib/wp-num.sh" \
                 ${IWE_TEMPLATE:+"$IWE_TEMPLATE/scripts/lib/wp-num.sh"}; do
  if [ -r "$_wpn_cand" ]; then
    WP_NUM_LIB="$_wpn_cand"
    break
  fi
done
if [ -z "$WP_NUM_LIB" ] && [ -z "${_WPN_OPTIONAL:-}" ]; then
  echo "❌ wp-num.sh не найден (ошибка установки, это не «РП не найден»): нужен scripts/lib/wp-num.sh. Искал: ${_wpn_dir}/lib, ${_wpn_root}/scripts/lib, ${_wpn_root}/FMT-exocortex-template/scripts/lib, IWE_TEMPLATE=${IWE_TEMPLATE:-не задана}. Обновите шаблон: bash update.sh" >&2
  exit 4
fi
if [ -n "$WP_NUM_LIB" ]; then
  # shellcheck source=/dev/null
  . "$WP_NUM_LIB"
fi
# <<< wp-num locate

if [[ -z "$WP_NUM" ]]; then
  echo "Использование: $0 <WP_NUM> [IWE_ROOT]" >&2
  exit 1
fi

# WP-044, 044, wp-044 и 44 — один и тот же РП (#954): дальше работаем с голым числом,
# а имя папки берём у реально найденной карточки.
if ! WP_NUM=$(wp_num_normalize "$WP_NUM"); then
  echo "❌ Некорректный номер РП: '$1' — используйте число или WP-N" >&2
  exit 1
fi

# issue #298: wp-list.py — единая точка, где закодирована двуформатная раскладка
# (папочная WP-434 + устаревшая плоская) — этот скрипт раньше отдельно реализовывал
# тот же поиск (WP_FILE_FOLDER/WP_FILE_FLAT). Fallback на старую glob-логику, если
# wp-list.py ещё не доставлен на этой установке (переходный период).
# issue #954: папочная карточка ищется по обоим написаниям — WP-044/ (так её заводит
# create-wp.sh) и старому WP-44/ — и берётся путь, который реально существует. Раньше
# путь собирался из номера «как введён» (WP-44/), сравнение с ответом wp-list.py не
# проходило, и папочная карточка принималась за плоский файл.
WP_LIST_SCRIPT="$SCRIPT_DIR/wp-list.py"
WP_CARD=$(wp_num_card_path "$INBOX" "$WP_NUM" || true)
if [[ -z "$WP_CARD" ]] && [[ -f "$WP_LIST_SCRIPT" ]]; then
  WP_CARD=$(python3 "$WP_LIST_SCRIPT" --list-cards --source inbox --fields wp,card --format tsv \
    --governance-repo "$GOV_REPO" --iwe-root "$IWE" 2>/dev/null \
    | awk -F'\t' -v n="$WP_NUM" '$1==n {print $2; exit}')
fi
if [[ -z "$WP_CARD" ]] && [[ ! -f "$WP_LIST_SCRIPT" ]]; then
  # Fallback: старая прямая glob-логика (wp-list.py отсутствует на этой установке).
  WP_CARD=$(find "$INBOX" -maxdepth 1 \( -name "WP-${WP_NUM}-*.md" -o -name "WP-$(wp_num_padded "$WP_NUM")-*.md" \) 2>/dev/null | head -1)
fi

if [[ -z "$WP_CARD" ]]; then
  echo "❌ WP-${WP_NUM}: не найден ни inbox/WP-$(wp_num_padded "$WP_NUM")/, ни плоский inbox/WP-${WP_NUM}-*.md" >&2
  exit 1
fi
WP_FILE="$WP_CARD"
FILENAME=$(basename "$WP_FILE")
CARD_DIR=$(dirname "$WP_FILE")

# Папочная конвенция WP-434 — по устройству пути, не по сравнению строк: карточка лежит
# в папке inbox/WP-<N>/ и называется так же, как папка.
if [[ "$FILENAME" == "$(basename "$CARD_DIR").md" ]] && [[ "$(dirname "$CARD_DIR")" -ef "$INBOX" ]]; then
  MODE="folder"
  FOLDER_NAME=$(basename "$CARD_DIR")
else
  MODE="flat"
  echo "⚠️  WP-${WP_NUM}: найден только устаревший плоский файл (не папочная конвенция WP-434)" >&2
fi

if [[ "$MODE" == "folder" ]]; then
  ARCHIVE_TARGET="$ARCHIVE/$FOLDER_NAME"
  MOVE_SRC="inbox/$FOLDER_NAME"
  MOVE_DST="archive/wp-contexts/$FOLDER_NAME"
else
  ARCHIVE_TARGET="$ARCHIVE/$FILENAME"
  MOVE_SRC="inbox/$FILENAME"
  MOVE_DST="archive/wp-contexts/$FILENAME"
fi

echo "📦 Архивирую WP-${WP_NUM} ($MODE): $FILENAME"

# Проверка полноты переноса (warn-not-block) — WP-5, 2026-07-10
if [[ -x "$CHECK_SCRIPT" ]]; then
  bash "$CHECK_SCRIPT" "$WP_NUM" "$IWE" || true
fi

# Guard (issue #224, issue #280): create-wp.sh больше не создаёт archive-stub
# при заведении РП (issue #280 вариант А) — ветка ниже остаётся на случай
# stub'ов, оставшихся от старых РП, заведённых до этого фикса, и на случай
# повторного/ручного запуска этого же скрипта. Перезаписываем только саму
# pending-заготовку, не случайный уже-заполненный §Закрытие. Проверка ДО
# правки inbox-файла — иначе при отказе inbox остаётся тронутым (frontmatter
# уже переписан), а archive нет: смоук-тест 2026-07-05 поймал именно этот
# порядок как баг.
if [[ -e "$ARCHIVE_TARGET" ]]; then
  STUB_FILE="$ARCHIVE_TARGET"
  [[ -d "$ARCHIVE_TARGET" ]] && STUB_FILE="$ARCHIVE_TARGET/$(basename "$ARCHIVE_TARGET").md"
  if [[ ! -f "$STUB_FILE" ]] || ! grep -q "^status: pending" "$STUB_FILE" 2>/dev/null; then
    echo "❌ $ARCHIVE_TARGET уже существует и не помечен status: pending — не перезаписываю, проверьте вручную" >&2
    exit 1
  fi
  # Это pending-заготовка — безопасно освободить путь под git mv.
  rm -rf "$ARCHIVE_TARGET"
fi

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

# 2. git mv (из STRATEGY_REPO); -f — см. guard-комментарий выше (issue #224)
if ! git -C "$STRATEGY_REPO" mv -f "$MOVE_SRC" "$MOVE_DST" 2>/dev/null; then
  echo "⚠️  git mv -f не удался — пробую обычный mv + ручной re-stage"
  # issue #954: код возврата mkdir/mv раньше не проверялся, и строка успеха печаталась,
  # даже когда ничего не перенесено. Теперь честный отказ: ненулевой код, без «✅».
  # status: done в карточке уже записан (это правда о РП) — не откатываем, а называем,
  # где она осталась и как перенести руками.
  if ! mkdir -p "$(dirname "$STRATEGY_REPO/$MOVE_DST")" || ! mv "$STRATEGY_REPO/$MOVE_SRC" "$STRATEGY_REPO/$MOVE_DST"; then
    echo "❌ WP-${WP_NUM}: не удалось перенести $MOVE_SRC → $MOVE_DST; карточка осталась в $MOVE_SRC (status: done уже записан). Перенесите вручную: git -C $STRATEGY_REPO mv $MOVE_SRC $MOVE_DST" >&2
    exit 1
  fi
  git -C "$STRATEGY_REPO" add "$MOVE_DST" 2>/dev/null
  if [[ "$MODE" == "folder" ]]; then
    git -C "$STRATEGY_REPO" rm -r --cached "$MOVE_SRC" 2>/dev/null
  else
    git -C "$STRATEGY_REPO" rm --cached "$MOVE_SRC" 2>/dev/null
  fi
fi

echo "✅ WP-${WP_NUM} → $MOVE_DST"
echo "   Следующий шаг: сверить WP-REGISTRY.md (если статус там ещё не done) + коммит"

# ОПТ-7: уведомление related.enables
ARCHIVED_FILE="$STRATEGY_REPO/$MOVE_DST"
[[ "$MODE" == "folder" ]] && ARCHIVED_FILE="$STRATEGY_REPO/$MOVE_DST/$FOLDER_NAME.md"

ENABLES=$(python3 - "$ARCHIVED_FILE" "$WP_NUM" <<'PYEOF'
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
