#!/usr/bin/env bash
# routing: helper  called-by=day-close  deterministic=true
# see DP.SC.159, DP.ROLE.059
# archive-done-wp.sh — atomic archiving of a completed WP
# see DP.M.010, DP.SC.033 (WP-297)
# see WP-5 (phase "Transfer completeness check before archiving inbox/WP-N",
# 2026-07-10) — rewritten for the WP-434 folder convention + hooked up
# check-wp-transfer-completeness.sh
#
# Steps:
#   1. Find inbox/WP-{N}/WP-{N}.md (WP-434 folder convention);
#      fallback — the legacy flat inbox/WP-{N}-*.md.
#   2. Run check-wp-transfer-completeness.sh (warn-not-block).
#   3. Update frontmatter: status → done.
#   4. git mv the folder (or file) inbox/ → archive/wp-contexts/.
#
# Usage:
#   bash archive-done-wp.sh <WP_NUM> [IWE_ROOT]
#
# Compatibility: bash 3.2+ (macOS), bash 4+ (Linux)

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
# hence exit 4 and not 1 (memory/protocol-open.md reads exit 1 as "WP not found").
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

# WP-044, 044, wp-044 and 44 are one and the same WP (#954): from here on we work with the bare number,
# and take the folder name from the card that was actually found.
if ! WP_NUM=$(wp_num_normalize "$WP_NUM"); then
  echo "❌ Некорректный номер РП: '$1' — используйте число или WP-N" >&2
  exit 1
fi

# issue #298: wp-list.py is the single place where the two-format layout is encoded
# (WP-434 folder + legacy flat) — this script used to implement
# the same search separately (WP_FILE_FOLDER/WP_FILE_FLAT). Fallback to the old glob logic if
# wp-list.py has not yet been delivered to this installation (transition period).
# issue #954: the folder card is searched by both spellings — WP-044/ (how
# create-wp.sh creates it) and the old WP-44/ — and the path that actually exists is taken. Previously
# the path was assembled from the number "as entered" (WP-44/), the comparison with wp-list.py's answer
# failed, and the folder card was taken for a flat file.
WP_LIST_SCRIPT="$SCRIPT_DIR/wp-list.py"
WP_CARD=$(wp_num_card_path "$INBOX" "$WP_NUM" || true)
if [[ -z "$WP_CARD" ]] && [[ -f "$WP_LIST_SCRIPT" ]]; then
  WP_CARD=$(python3 "$WP_LIST_SCRIPT" --list-cards --source inbox --fields wp,card --format tsv \
    --governance-repo "$GOV_REPO" --iwe-root "$IWE" 2>/dev/null \
    | awk -F'\t' -v n="$WP_NUM" '$1==n {print $2; exit}')
fi
if [[ -z "$WP_CARD" ]] && [[ ! -f "$WP_LIST_SCRIPT" ]]; then
  # Fallback: the old direct glob logic (wp-list.py is absent on this installation).
  WP_CARD=$(find "$INBOX" -maxdepth 1 \( -name "WP-${WP_NUM}-*.md" -o -name "WP-$(wp_num_padded "$WP_NUM")-*.md" \) 2>/dev/null | head -1)
fi

if [[ -z "$WP_CARD" ]]; then
  echo "❌ WP-${WP_NUM}: не найден ни inbox/WP-$(wp_num_padded "$WP_NUM")/, ни плоский inbox/WP-${WP_NUM}-*.md" >&2
  exit 1
fi
WP_FILE="$WP_CARD"
FILENAME=$(basename "$WP_FILE")
CARD_DIR=$(dirname "$WP_FILE")

# WP-434 folder convention — by path structure, not by string comparison: the card lies
# in the folder inbox/WP-<N>/ and is named the same as the folder.
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

# Transfer completeness check (warn-not-block) — WP-5, 2026-07-10
if [[ -x "$CHECK_SCRIPT" ]]; then
  bash "$CHECK_SCRIPT" "$WP_NUM" "$IWE" || true
fi

# Guard (issue #224, issue #280): create-wp.sh no longer creates an archive stub
# when registering a WP (issue #280 option A) — the branch below remains for the case of
# stubs left over from old WPs created before this fix, and for the case of
# a repeated/manual run of this same script. We overwrite only the pending
# placeholder itself, not an accidentally already filled §Closure. The check is BEFORE
# editing the inbox file — otherwise on refusal the inbox stays touched (frontmatter
# already rewritten) while the archive is not: the smoke test of 2026-07-05 caught exactly this
# order as a bug.
if [[ -e "$ARCHIVE_TARGET" ]]; then
  STUB_FILE="$ARCHIVE_TARGET"
  [[ -d "$ARCHIVE_TARGET" ]] && STUB_FILE="$ARCHIVE_TARGET/$(basename "$ARCHIVE_TARGET").md"
  if [[ ! -f "$STUB_FILE" ]] || ! grep -q "^status: pending" "$STUB_FILE" 2>/dev/null; then
    echo "❌ $ARCHIVE_TARGET уже существует и не помечен status: pending — не перезаписываю, проверьте вручную" >&2
    exit 1
  fi
  # This is a pending placeholder — safe to free the path for git mv.
  rm -rf "$ARCHIVE_TARGET"
fi

# 1. Update frontmatter status → done
# We look for the first frontmatter (between --- and ---)
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

# Check that the status changed
if ! grep -q "^status: done" "$TMP" 2>/dev/null; then
  echo "⚠️  frontmatter status уже done или не найден — продолжаю"
fi

cp "$TMP" "$WP_FILE"
rm -f "$TMP"

# 2. git mv (from STRATEGY_REPO); -f — see the guard comment above (issue #224)
if ! git -C "$STRATEGY_REPO" mv -f "$MOVE_SRC" "$MOVE_DST" 2>/dev/null; then
  echo "⚠️  git mv -f не удался — пробую обычный mv + ручной re-stage"
  # issue #954: the mkdir/mv return code used to be unchecked, and the success line was printed
  # even when nothing was moved. Now an honest refusal: nonzero code, without "✅".
  # status: done is already written in the card (this is true about the WP) — we do not roll it back, but name
  # where it stayed and how to move it by hand.
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

# OPT-7: related.enables notification
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
